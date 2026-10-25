import CoreGraphics
import Foundation
import ImageIO

/// Описание формата полос, как его сообщает ImageCaptureCore.
struct BandFormat: Equatable, Sendable {
    var width: Int
    var height: Int
    var bitsPerPixel: Int
    var bitsPerComponent: Int
    var numComponents: Int
    var bigEndian: Bool

    /// Число цветовых компонент (RGBX считается как 3)
    var colorComponents: Int { numComponents == 4 ? 3 : numComponents }
}

/// Метаданные одной полосы (для диагностики и сборки).
struct BandMeta: Equatable, Sendable, CustomStringConvertible {
    var fullWidth: Int
    var fullHeight: Int
    var bitsPerPixel: Int
    var numComponents: Int
    var bitsPerComponent: Int
    var bytesPerRow: Int
    var dataStartRow: Int
    var dataNumRows: Int
    var dataCount: Int
    var pixelDataType: UInt
    var bigEndian: Bool
    var profilePath: String?

    var format: BandFormat {
        BandFormat(
            width: fullWidth, height: fullHeight, bitsPerPixel: bitsPerPixel,
            bitsPerComponent: bitsPerComponent, numComponents: numComponents, bigEndian: bigEndian)
    }

    var description: String {
        "full \(fullWidth)x\(fullHeight) bpp \(bitsPerPixel) comps \(numComponents) bpc \(bitsPerComponent) "
            + "bpr \(bytesPerRow) startRow \(dataStartRow) numRows \(dataNumRows) buf \(dataCount) "
            + "pixelType \(pixelDataType) bigEndian \(bigEndian)"
    }
}

/// Сборка изображения из полос (без зависимостей от устройства).
///
/// Полосы кладутся в общий буфер по байтовому смещению `startRow * bytesPerRow` - так ImageCaptureCore
/// режет поток данных. Раскладка строк определяется по содержимому (см. `Layout`):
/// - `padded`: строки идут с шагом `bytesPerRow`, лишние байты в конце строки - выравнивание;
/// - `packed`: данные плотные (шаг = ширина), а `bytesPerRow` - лишь округлённое вверх значение.
///   Так отдаёт Deli M1820W для 8-бит серого: ширина 2550, bytesPerRow 2552, полоса 821*2552 байт,
///   но реально в ней лежит 821,64 строки по 2550 байт, и строки переходят из полосы в полосу.
struct BandAssembler {
    enum Layout: Equatable, Sendable { case padded, packed }

    let format: BandFormat
    let colorSpace: CGColorSpace
    /// Плотный размер строки (без выравнивания)
    let stride: Int
    /// bytesPerRow из первой полосы; 0 пока полос не было
    private(set) var pitch = 0
    private var buffer: [UInt8] = []
    /// Объединённые диапазоны принятых байт (отсортированы, не пересекаются)
    private var ranges: [Range<Int>] = []

    init?(format: BandFormat, colorSpace: CGColorSpace? = nil) {
        guard format.width > 0, format.height > 0, format.bitsPerPixel > 0,
            [1, 8, 16].contains(format.bitsPerComponent),
            [1, 3, 4].contains(format.numComponents)
        else { return nil }
        // 4 компоненты - RGB + пропускаемый байт (RGBX), так отдаёт AirScan
        guard format.bitsPerPixel == format.numComponents * format.bitsPerComponent,
            format.numComponents != 4 || format.bitsPerComponent >= 8
        else { return nil }
        let stride = (format.width * format.bitsPerPixel + 7) / 8
        let total = stride.multipliedReportingOverflow(by: format.height)
        guard !total.overflow, total.partialValue < 1 << 31 else { return nil }
        self.format = format
        self.stride = stride
        self.colorSpace = colorSpace ?? Self.defaultColorSpace(numComponents: format.colorComponents)
    }

    static func defaultColorSpace(numComponents: Int) -> CGColorSpace {
        if numComponents == 1 {
            return CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray()
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// ICC-профиль из файла, если он подходит по числу компонент; иначе sRGB / genericGray.
    static func colorSpace(numComponents: Int, profilePath: String?) -> CGColorSpace {
        if let path = profilePath, !path.isEmpty,
            let data = FileManager.default.contents(atPath: path),
            let space = CGColorSpace(iccData: data as CFData),
            space.numberOfComponents == numComponents
        {
            return space
        }
        return defaultColorSpace(numComponents: numComponents)
    }

    // MARK: Приём

    /// Принято байт всего
    var coveredBytes: Int { ranges.reduce(0) { $0 + $1.count } }

    /// Принято байт подряд от начала буфера
    private var prefixBytes: Int {
        if let first = ranges.first, first.lowerBound == 0 { return first.upperBound }
        return 0
    }

    /// Доля принятых данных, 0...1
    var fraction: Double {
        guard pitch > 0 else { return 0 }
        return min(1, Double(coveredBytes) / Double(format.height * pitch))
    }

    /// Копирует полосу в буфер по смещению `startRow * bytesPerRow`. Возвращает число принятых строк.
    @discardableResult
    mutating func add(_ data: Data, startRow: Int, numRows: Int, bytesPerRow: Int) -> Int {
        guard startRow >= 0, startRow < format.height, numRows > 0, bytesPerRow >= stride else { return 0 }
        if pitch == 0 {
            let total = bytesPerRow.multipliedReportingOverflow(by: format.height)
            guard !total.overflow, total.partialValue < 1 << 31 else { return 0 }
            pitch = bytesPerRow
            buffer = [UInt8](repeating: 0, count: total.partialValue)
        }
        guard bytesPerRow == pitch else { return 0 }
        let offset = startRow * pitch
        let count = min(data.count, numRows * pitch, buffer.count - offset)
        guard count > 0 else { return 0 }
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                (dst.baseAddress! + offset).copyMemory(from: src.baseAddress!, byteCount: count)
            }
        }
        cover(offset..<(offset + count))
        return min(numRows, (count + pitch - stride) / pitch, format.height - startRow)
    }

    private mutating func cover(_ new: Range<Int>) {
        var merged = new
        var result: [Range<Int>] = []
        for r in ranges {
            if r.upperBound < merged.lowerBound || r.lowerBound > merged.upperBound {
                result.append(r)
            } else {
                merged = min(r.lowerBound, merged.lowerBound)..<max(r.upperBound, merged.upperBound)
            }
        }
        result.append(merged)
        result.sort { $0.lowerBound < $1.lowerBound }
        ranges = result
    }

    // MARK: Раскладка

    /// Определяет раскладку по байтам выравнивания: при настоящем выравнивании они одинаковы в соседних
    /// строках (нули/константа), при плотных данных - это пиксели изображения и они различаются.
    var layout: Layout {
        guard pitch > stride else { return .padded }
        let rows = paddedRows
        guard rows >= 3 else { return .padded }
        let pad = pitch - stride
        let step = max(1, (rows - 1) / 128)
        var same = 0
        var total = 0
        buffer.withUnsafeBytes { raw in
            var r = 0
            while r + 1 < rows {
                let a = raw.baseAddress! + r * pitch + stride
                let b = raw.baseAddress! + (r + 1) * pitch + stride
                if memcmp(a, b, pad) == 0 { same += 1 }
                total += 1
                r += step
            }
        }
        return total > 0 && Double(same) / Double(total) < 0.9 ? .packed : .padded
    }

    /// Шаг строки в буфере для раскладки
    private func rowStride(_ layout: Layout) -> Int { layout == .packed ? stride : max(pitch, stride) }

    private var paddedRows: Int {
        let prefix = prefixBytes
        guard pitch > 0, prefix >= stride else { return 0 }
        return min(format.height, (prefix - stride) / pitch + 1)
    }

    /// Число полных строк, принятых подряд с начала изображения
    func validRows(layout: Layout) -> Int {
        switch layout {
        case .padded: paddedRows
        case .packed: min(format.height, prefixBytes / stride)
        }
    }

    var validRows: Int { validRows(layout: layout) }

    /// Все строки изображения получены (с учётом проверки длины данных)
    var isComplete: Bool { validRows >= format.height }

    // MARK: Изображение

    /// Изображение из первых `rows` строк (по умолчанию - всё принятое подряд).
    func makeImage(rows: Int? = nil) -> CGImage? {
        let layout = layout
        let count = min(rows ?? validRows(layout: layout), validRows(layout: layout))
        guard count > 0 else { return nil }
        let rowBytes = rowStride(layout)
        let data = Data(buffer[0..<min(buffer.count, rowBytes * count)])
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return cgImage(provider: provider, rows: count, bytesPerRow: rowBytes)
    }

    private func cgImage(provider: CGDataProvider, rows: Int, bytesPerRow: Int) -> CGImage? {
        var info: UInt32 = format.numComponents == 4
            ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.none.rawValue
        if format.bitsPerComponent == 16 {
            info |= format.bigEndian
                ? CGBitmapInfo.byteOrder16Big.rawValue : CGBitmapInfo.byteOrder16Little.rawValue
        }
        return CGImage(
            width: format.width, height: rows,
            bitsPerComponent: format.bitsPerComponent, bitsPerPixel: format.bitsPerPixel,
            bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Уменьшенная копия принятых строк (длинная сторона полного кадра не больше `maxSide`).
    /// Не копирует буфер: рисует прямо из него.
    func makeThumbnail(maxSide: Int) -> CGImage? {
        let layout = layout
        let rows = validRows(layout: layout)
        guard rows > 0 else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(format.width, format.height)))
        let tw = max(1, Int((Double(format.width) * scale).rounded()))
        let th = max(1, Int((Double(rows) * scale).rounded()))
        let rowBytes = rowStride(layout)
        let gray = format.colorComponents == 1
        guard let ctx = ImageOps.makeContext(width: tw, height: th, gray: gray) else { return nil }
        ctx.interpolationQuality = .medium
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress,
                let provider = CGDataProvider(
                    dataInfo: nil, data: base, size: min(raw.count, rowBytes * rows),
                    releaseData: { _, _, _ in }),
                let image = cgImage(provider: provider, rows: rows, bytesPerRow: rowBytes)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        }
        return ctx.makeImage()
    }
}

// MARK: - Завершающая обработка изображения (вне главного потока)

enum ImageFinishing {
    /// Если устройство отдало другое разрешение, приводим к размеру, ожидаемому для запрошенных dpi.
    static func resample(_ image: CGImage, to size: CGSize) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let dw = abs(image.width - w), dh = abs(image.height - h)
        guard dw > 1 || dh > 1 else { return image }
        return draw(image, width: w, height: h)
    }

    /// Уменьшает так, чтобы длинная сторона не превышала `maxSide`.
    static func downscale(_ image: CGImage, maxSide: Int) -> CGImage {
        let longSide = max(image.width, image.height)
        guard longSide > maxSide else { return image }
        let scale = Double(maxSide) / Double(longSide)
        return draw(
            image, width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded())))
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let gray = image.colorSpace?.model == .monochrome
        guard let ctx = ImageOps.makeContext(width: width, height: height, gray: gray) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// Приведение результата к запрошенному режиму (для эмулируемых и 1-битных).
    static func postprocess(_ image: CGImage, mode: ColorMode) -> CGImage {
        switch mode {
        case .color: return image
        case .gray:
            return image.colorSpace?.model == .monochrome && image.bitsPerComponent == 8
                ? image : ImageOps.toGray(image)
        case .bw: return ImageOps.toBW(image)
        }
    }
}

// MARK: - Конвейер приёма данных операции

/// Принимает полосы с главного потока и собирает изображение на последовательной фоновой очереди.
/// Порядок «полосы -> завершение» сохраняется: `drain()` встаёт в ту же очередь.
final class ScanPipeline: @unchecked Sendable {
    struct Snapshot: Sendable {
        var bands = 0
        var first: BandMeta?
        var last: BandMeta?
        var formatRejected = false
    }

    typealias Update = @Sendable (_ progress: Double, _ thumbnail: CGImage?) -> Void

    private let queue = DispatchQueue(label: "afrlv.scan.assemble", qos: .userInitiated)
    private let update: Update
    private let thumbnailSide: Int
    private let thumbnailInterval: Duration = .milliseconds(220)

    // Состояние - только на `queue`
    private var assembler: BandAssembler?
    private var fileImage: CGImage?
    private var snapshot = Snapshot()
    private var lastThumbnailAt: ContinuousClock.Instant?

    init(thumbnailSide: Int = 1000, update: @escaping Update) {
        self.thumbnailSide = thumbnailSide
        self.update = update
    }

    /// `data` должен быть уже скопирован (владеет им конвейер).
    func addBand(_ data: Data, meta: BandMeta) {
        queue.async { self.process(data, meta) }
    }

    func addFile(_ url: URL) {
        queue.async {
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                self.fileImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Возвращается, когда обработаны все ранее добавленные полосы/файлы.
    func drain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { c.resume() }
        }
    }

    /// Финальный результат. Только при полном покрытии строк; иначе `.incomplete`.
    /// `external` - готовое изображение (например, overview), минуя сборщик.
    func result(
        mode: ColorMode, target: CGSize?, maxSide: Int?, external: CGImage? = nil
    ) async -> (Result<CGImage, ScannerError>, Snapshot) {
        await withCheckedContinuation { (c: CheckedContinuation<(Result<CGImage, ScannerError>, Snapshot), Never>) in
            queue.async {
                c.resume(returning: (self.buildResult(mode, target, maxSide, external), self.snapshot))
            }
        }
    }

    private func process(_ data: Data, _ meta: BandMeta) {
        snapshot.bands += 1
        if snapshot.first == nil { snapshot.first = meta }
        snapshot.last = meta
        if assembler == nil, !snapshot.formatRejected {
            let space = BandAssembler.colorSpace(
                numComponents: meta.format.colorComponents, profilePath: meta.profilePath)
            assembler = BandAssembler(format: meta.format, colorSpace: space)
            snapshot.formatRejected = assembler == nil
        }
        assembler?.add(
            data, startRow: meta.dataStartRow, numRows: meta.dataNumRows, bytesPerRow: meta.bytesPerRow)
        var thumbnail: CGImage?
        let now = ContinuousClock.now
        if lastThumbnailAt.map({ now - $0 >= thumbnailInterval }) ?? true {
            lastThumbnailAt = now
            thumbnail = assembler?.makeThumbnail(maxSide: thumbnailSide)
        }
        update(assembler?.fraction ?? 0, thumbnail)
    }

    private func buildResult(
        _ mode: ColorMode, _ target: CGSize?, _ maxSide: Int?, _ external: CGImage?
    ) -> Result<CGImage, ScannerError> {
        var image: CGImage
        if let external {
            image = external
        } else if let assembler {
            guard assembler.isComplete else { return .failure(.incomplete) }
            guard let made = assembler.makeImage() else { return .failure(.emptyResult) }
            image = made
        } else if let fileImage {
            image = fileImage
        } else if snapshot.formatRejected {
            return .failure(.device("неподдерживаемый формат данных"))
        } else {
            return .failure(.emptyResult)
        }
        if let target { image = ImageFinishing.resample(image, to: target) }
        image = ImageFinishing.postprocess(image, mode: mode)
        if let maxSide { image = ImageFinishing.downscale(image, maxSide: maxSide) }
        return .success(image)
    }
}
