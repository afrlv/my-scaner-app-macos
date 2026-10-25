import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ExportError: Error, LocalizedError {
    case noPages
    case encodingFailed
    case destinationFailed(URL)
    case verificationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .noPages: "Нет страниц для сохранения"
        case .encodingFailed: "Не удалось закодировать изображение"
        case .destinationFailed(let url): "Не удалось записать файл \(url.lastPathComponent)"
        case .verificationFailed(let url): "Файл \(url.lastPathComponent) записан с ошибкой"
        }
    }
}

enum FileNaming {
    static func baseName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "scan_" + formatter.string(from: date)
    }

    static func uniqueURL(folder: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var index = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)_\(index)").appendingPathExtension(ext)
            index += 1
        }
        return url
    }
}

enum Exporter {
    /// Временное имя в той же папке, чтобы переименование было атомарным.
    private static func temporaryURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    }

    private static func commit(_ temp: URL, to url: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            throw ExportError.destinationFailed(url)
        }
    }

    /// Ч/Б (и серый из 1 бита) кладутся в PDF без JPEG-перекомпрессии.
    private static func isLossless(_ page: ScannedPage) -> Bool {
        page.colorMode == .bw || (page.colorMode == .gray && page.image.bitsPerComponent == 1)
    }

    static func writePDF(pages: [ScannedPage], to url: URL, jpegQuality: CGFloat = 0.85) throws {
        guard !pages.isEmpty else { throw ExportError.noPages }
        let temp = temporaryURL(for: url)
        do {
            try renderPDF(pages: pages, to: temp, jpegQuality: jpegQuality)
            guard let doc = PDFDocument(url: temp), doc.pageCount == pages.count else {
                throw ExportError.verificationFailed(url)
            }
            try commit(temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func renderPDF(pages: [ScannedPage], to url: URL, jpegQuality: CGFloat) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw ExportError.destinationFailed(url) }
        var firstBox = CGRect.zero
        guard let pdf = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else {
            throw ExportError.destinationFailed(url)
        }
        for page in pages {
            let rotated = ImageOps.rotate(page.image, quarterTurns: page.quarterTurns)
            let drawable = isLossless(page) ? rotated : try recompressed(rotated, quality: jpegQuality)
            let dpi = CGFloat(max(page.dpi, 1))
            var box = CGRect(
                x: 0, y: 0,
                width: CGFloat(rotated.width) / dpi * 72,
                height: CGFloat(rotated.height) / dpi * 72)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            pdf.beginPDFPage(info as CFDictionary)
            pdf.draw(drawable, in: box)
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    static func writeJPEG(page: ScannedPage, to url: URL, quality: CGFloat = 0.85) throws {
        let image = ImageOps.rotate(page.image, quarterTurns: page.quarterTurns)
        let data = try jpegData(image, dpi: page.dpi, quality: quality)
        let temp = temporaryURL(for: url)
        do {
            do {
                try data.write(to: temp)
            } catch {
                throw ExportError.destinationFailed(url)
            }
            try commit(temp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    @discardableResult
    static func save(
        pages: [ScannedPage], format: OutputFormat, split: SplitMode, folder: URL, date: Date
    ) throws -> [URL] {
        guard !pages.isEmpty else { throw ExportError.noPages }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.destinationFailed(folder)
        }
        let base = FileNaming.baseName(date: date)
        var urls: [URL] = []

        func name(_ index: Int) -> String { pages.count == 1 ? base : "\(base)_\(index + 1)" }

        do {
            switch (format, split) {
            case (.pdf, .singleFile):
                let url = FileNaming.uniqueURL(folder: folder, base: base, ext: "pdf")
                try writePDF(pages: pages, to: url)
                urls.append(url)
            case (.pdf, .separateFiles):
                for (index, page) in pages.enumerated() {
                    let url = FileNaming.uniqueURL(folder: folder, base: name(index), ext: "pdf")
                    try writePDF(pages: [page], to: url)
                    urls.append(url)
                }
            case (.jpeg, _):
                for (index, page) in pages.enumerated() {
                    let url = FileNaming.uniqueURL(folder: folder, base: name(index), ext: "jpg")
                    try writeJPEG(page: page, to: url)
                    urls.append(url)
                }
            }
        } catch {
            // Не оставляем частично сохранённый набор файлов.
            for url in urls { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return urls
    }

    private static func jpegData(_ image: CGImage, dpi: Int?, quality: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.encodingFailed
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let dpi {
            props[kCGImagePropertyDPIWidth] = dpi
            props[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodingFailed }
        return data as Data
    }

    private static func recompressed(_ image: CGImage, quality: CGFloat) throws -> CGImage {
        let data = try jpegData(image, dpi: nil, quality: quality)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ExportError.encodingFailed }
        return decoded
    }
}
