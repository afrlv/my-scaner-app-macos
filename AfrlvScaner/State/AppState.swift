import CoreGraphics
import Foundation
import Observation

/// Страница вместе с миниатюрой; нужна для передачи между потоками.
struct PageBundle: @unchecked Sendable {
    let page: ScannedPage
    let thumbnail: CGImage
}

enum Thumbnailer {
    static let maxSide = 200

    static func make(from image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let scale = CGFloat(maxSide) / CGFloat(longest)
        let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let ctx = ImageOps.makeContext(width: w, height: h) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

/// Что приложение делает прямо сейчас; покрывает весь путь операции, а не только работу сканера.
enum Activity: Equatable, Sendable {
    case idle, previewing, scanning, processing, saving
}

@MainActor
@Observable
final class AppState {
    let scanner: any ScannerControlling

    var preview: CGImage?
    var previewStale = false
    var regions: [ScanRegion] = []
    var selectedRegionID: UUID?
    /// Текущие области поставил детектор (а не пользователь вручную)
    private(set) var regionsAreAuto = false
    var pages: [ScannedPage] = []
    var thumbnails: [UUID: CGImage] = [:]
    var selectedPageID: UUID?
    /// Последний клик был по ленте страниц (для маршрутизации ⌫)
    var stripHasFocus = false

    var colorMode: ColorMode { didSet { defaults.set(colorMode.rawValue, forKey: "colorMode") } }
    var dpi: Int { didSet { defaults.set(dpi, forKey: "dpi") } }
    var format: OutputFormat { didSet { defaults.set(format.rawValue, forKey: "format") } }
    var split: SplitMode { didSet { defaults.set(split.rawValue, forKey: "split") } }

    var statusText = ""
    var statusIsError = false
    var lastSavedURLs: [URL] = []
    var lastScanDuration: TimeInterval?
    /// Область, которая сейчас сканируется (мм), для отрисовки частичного изображения
    var activeAreaMM: CGRect?
    private(set) var activity: Activity = .idle
    /// Хук для тестов: вызывается после экспорта, до очистки ленты.
    @ObservationIgnored var afterExportHook: (@MainActor () async -> Void)?
    var nextBaseName = FileNaming.baseName(date: Date())

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let outputFolderOverride: URL?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var knownGlass: CGSize?

    static let minRegionMM: CGFloat = 4

    init(
        scanner: any ScannerControlling = ScannerFactory.make(),
        defaults: UserDefaults = .standard,
        outputFolder: URL? = nil
    ) {
        self.scanner = scanner
        self.defaults = defaults
        self.outputFolderOverride = outputFolder
        colorMode = defaults.string(forKey: "colorMode").flatMap(ColorMode.init(rawValue:)) ?? .color
        let savedDPI = defaults.integer(forKey: "dpi")
        dpi = savedDPI > 0 ? savedDPI : 300
        format = defaults.string(forKey: "format").flatMap(OutputFormat.init(rawValue:)) ?? .pdf
        split = defaults.string(forKey: "split").flatMap(SplitMode.init(rawValue:)) ?? .singleFile
    }

    // MARK: - Производные значения

    var outputFolder: URL { outputFolderOverride ?? AppSettings.outputFolder }
    var capabilities: ScannerCapabilities? { scanner.capabilities }
    var glassSizeMM: CGSize { scanner.capabilities?.glassSizeMM ?? CGSize(width: 216, height: 297) }
    var isReady: Bool { scanner.state == .ready }
    var isSaving: Bool { activity == .saving }
    var scannerBusy: Bool {
        switch scanner.state {
        case .previewing, .scanning: true
        default: false
        }
    }
    var busy: Bool { activity != .idle || scannerBusy }
    var canPreview: Bool { isReady && activity == .idle }
    var canScan: Bool { isReady && activity == .idle }
    var canAutoDetect: Bool { preview != nil && activity == .idle && !scannerBusy }
    var canSave: Bool { !pages.isEmpty && !busy }

    /// Области, обрезанные по стеклу; пустые и меньше минимального размера отброшены.
    var effectiveRegionRects: [CGRect] {
        let glass = glassSizeMM
        return regions.map { ScanGeometry.clamp($0.rectMM, to: glass) }
            .filter { $0.width >= Self.minRegionMM && $0.height >= Self.minRegionMM }
    }

    var scanAreaMM: CGRect {
        let glass = CGRect(origin: .zero, size: glassSizeMM)
        guard let union = ScanGeometry.union(effectiveRegionRects) else { return glass }
        let clipped = ScanGeometry.clamp(union, to: glassSizeMM)
        return clipped.isEmpty ? glass : clipped
    }

    /// Текст статусной строки; ошибки сканера берутся из его состояния.
    var statusLine: (text: String, isError: Bool) {
        if case .error(let message) = scanner.state { return (message, true) }
        if !statusText.isEmpty { return (statusText, statusIsError) }
        switch scanner.state {
        case .searching: return ("Поиск сканеров…", false)
        case .noScanner: return ("Сканеры не найдены", false)
        case .connecting: return ("Подключение…", false)
        case .ready:
            let name = scanner.scanners.first { $0.id == scanner.selectedID }
            return ("\(name?.name ?? "Сканер") · готов", false)
        case .previewing: return ("Превью…", false)
        case .scanning: return ("Сканирование…", false)
        case .error(let message): return (message, true)
        }
    }

    /// Путь, показываемый справа в статусной строке
    var pathLabel: String {
        if let url = lastSavedURLs.first { return Self.abbreviate(url.path) }
        let ext = format == .pdf ? "pdf" : "jpg"
        return Self.abbreviate(outputFolder.appendingPathComponent(nextBaseName).appendingPathExtension(ext).path)
    }

    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Старт и выбор сканера

    func start() {
        guard syncTask == nil else { return }
        scanner.start()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncScanner()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Выбирает сканер, когда они появились, и подгоняет dpi под возможности.
    func syncScanner() async {
        if scanner.selectedID == nil, !scanner.scanners.isEmpty {
            let last = defaults.string(forKey: "lastScannerID")
            let id = scanner.scanners.first { $0.id == last }?.id ?? scanner.scanners[0].id
            await scanner.select(id)
        }
        if let id = scanner.selectedID, defaults.string(forKey: "lastScannerID") != id {
            defaults.set(id, forKey: "lastScannerID")
        }
        if let glass = scanner.capabilities?.glassSizeMM, glass != knownGlass {
            let hadGlass = knownGlass != nil
            knownGlass = glass
            glassDidChange(to: glass, markStale: hadGlass)
        }
        if let resolutions = scanner.capabilities?.resolutions, !resolutions.isEmpty, !resolutions.contains(dpi) {
            dpi = resolutions.min { abs($0 - dpi) < abs($1 - dpi) } ?? dpi
        }
    }

    func selectScanner(_ id: String) async {
        guard id != scanner.selectedID else { return }
        defaults.set(id, forKey: "lastScannerID")
        previewStale = true
        await scanner.select(id)
    }

    /// Новое стекло: области обрезаются, пустые и мельче минимума удаляются, превью устаревает.
    private func glassDidChange(to glass: CGSize, markStale: Bool) {
        regions = regions.compactMap { region in
            let rect = ScanGeometry.clamp(region.rectMM, to: glass)
            guard rect.width >= Self.minRegionMM, rect.height >= Self.minRegionMM else { return nil }
            var updated = region
            updated.rectMM = rect
            return updated
        }
        if let id = selectedRegionID, !regions.contains(where: { $0.id == id }) { selectedRegionID = nil }
        if markStale, preview != nil { previewStale = true }
    }

    /// «Переподключить» после ошибки сканера
    func reconnect() async {
        guard let id = scanner.selectedID else { return }
        setStatus("")
        await scanner.select(id)
    }

    // MARK: - Превью и поиск областей

    func preview() async {
        guard canPreview else { return }
        activity = .previewing
        defer { activity = .idle }
        let dpi = scanner.capabilities?.previewDPI ?? 75
        activeAreaMM = CGRect(origin: .zero, size: glassSizeMM)
        setStatus("Превью · \(dpi) dpi …")
        let started = ContinuousClock.now
        defer { activeAreaMM = nil }
        do {
            preview = try await scanner.preview()
            previewStale = false
            let ready = "Превью готово за \(Self.seconds(started.duration(to: .now)))"
            if let image = preview, regions.isEmpty || regionsAreAuto {
                activity = .processing
                await detectRegions(in: image, statusPrefix: "Превью готово · ", capitalize: false)
            } else {
                setStatus(ready)
            }
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    func autoDetect() async {
        guard canAutoDetect, let image = preview else { return }
        activity = .processing
        defer { activity = .idle }
        await detectRegions(in: image, statusPrefix: "", capitalize: true)
    }

    /// Общая часть автодетекта: заменяет области результатом детектора (вне главного потока).
    private func detectRegions(in image: CGImage, statusPrefix: String, capitalize: Bool) async {
        let found = await RegionDetector.detect(in: image, glassMM: glassSizeMM)
        regions = found.map { ScanRegion(rectMM: $0) }
        regionsAreAuto = true
        selectedRegionID = nil
        let text: String
        if found.isEmpty {
            text = capitalize ? "Объекты не найдены" : "объекты не найдены"
        } else {
            text = (capitalize ? "Найдено объектов: " : "найдено объектов: ") + "\(found.count)"
        }
        setStatus(statusPrefix + text)
    }

    // MARK: - Скан

    func scan() async {
        guard canScan else { return }
        activity = .scanning
        defer { activity = .idle }
        let regionRects = effectiveRegionRects
        let area = scanAreaMM
        let dpi = self.dpi
        let mode = colorMode
        activeAreaMM = area
        setStatus("Скан \(dpi) dpi …")
        let started = ContinuousClock.now
        defer { activeAreaMM = nil }
        do {
            let image = try await scanner.scan(areaMM: area, dpi: dpi, mode: mode)
            activity = .processing
            let bundles = await Task.detached(priority: .userInitiated) { () -> [PageBundle] in
                let crops = regionRects.isEmpty
                    ? [image]
                    : ImageOps.crop(image, regionsMM: regionRects, scanAreaMM: area)
                return crops.map {
                    PageBundle(
                        page: ScannedPage(image: $0, dpi: dpi, colorMode: mode),
                        thumbnail: Thumbnailer.make(from: $0))
                }
            }.value
            for bundle in bundles {
                pages.append(bundle.page)
                thumbnails[bundle.page.id] = bundle.thumbnail
            }
            if selectedPageID == nil { selectedPageID = bundles.last?.page.id }
            lastSavedURLs = []
            nextBaseName = FileNaming.baseName(date: Date())
            lastScanDuration = Self.timeInterval(started.duration(to: .now))
            setStatus("Скан \(dpi) dpi · один проход · страниц в сессии: \(pages.count)")
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    // MARK: - Сохранение

    func save() async {
        guard canSave else { return }
        activity = .saving
        defer { activity = .idle }
        let snapshot = pages
        let format = self.format
        let split = self.split
        let folder = outputFolder
        do {
            let urls = try await Task.detached(priority: .userInitiated) {
                try Exporter.save(pages: snapshot, format: format, split: split, folder: folder, date: Date())
            }.value
            await afterExportHook?()
            lastSavedURLs = urls
            let target = urls.count == 1 ? urls[0].path : folder.path
            let savedIDs = Set(snapshot.map(\.id))
            pages.removeAll { savedIDs.contains($0.id) }
            for id in savedIDs { thumbnails[id] = nil }
            if let selected = selectedPageID, savedIDs.contains(selected) { selectedPageID = pages.last?.id }
            if pages.isEmpty { stripHasFocus = false }
            setStatus("Сохранено: \(snapshot.count) стр. → \(Self.abbreviate(target))")
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    // MARK: - Страницы

    func deletePage(_ id: UUID) {
        guard activity != .saving else { return }
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: index)
        thumbnails[id] = nil
        if selectedPageID == id {
            selectedPageID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
        }
        if pages.isEmpty { stripHasFocus = false }
    }

    func rotatePage(_ id: UUID) {
        guard activity != .saving else { return }
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].quarterTurns += 1
        if let thumb = thumbnails[id] { thumbnails[id] = ImageOps.rotate(thumb, quarterTurns: 1) }
    }

    func movePage(from: Int, to: Int) {
        guard activity != .saving else { return }
        guard pages.indices.contains(from), pages.indices.contains(to), from != to else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: to)
    }

    func movePage(id: UUID, before targetID: UUID) {
        guard let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == targetID }), from != to
        else { return }
        movePage(from: from, to: to)
    }

    // MARK: - Области

    func addRegion(_ rect: CGRect) {
        let region = ScanRegion(rectMM: ScanGeometry.clamp(rect, to: glassSizeMM))
        regions.append(region)
        regionsAreAuto = false
        selectedRegionID = region.id
    }

    func updateRegion(_ id: UUID, rect: CGRect) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[index].rectMM = rect
        regionsAreAuto = false
    }

    func deleteRegion(_ id: UUID) {
        regions.removeAll { $0.id == id }
        regionsAreAuto = false
        if selectedRegionID == id { selectedRegionID = nil }
    }

    /// ⌫: страница, если последний клик был по ленте, иначе область
    func deleteSelection() {
        if stripHasFocus, let id = selectedPageID {
            deletePage(id)
        } else if let id = selectedRegionID {
            deleteRegion(id)
        }
    }

    // MARK: - Вспомогательное

    private func setStatus(_ text: String, error: Bool = false) {
        statusText = text
        statusIsError = error
    }

    private static func timeInterval(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func seconds(_ d: Duration) -> String {
        formatSeconds(timeInterval(d))
    }

    static func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", locale: Locale(identifier: "ru_RU"), value) + " с"
    }
}
