import XCTest
@testable import AfrlvScaner

/// Обёртка над MockScanner, считающая вызовы scan.
@MainActor
@Observable
final class CountingScanner: ScannerControlling {
    let inner = MockScanner(stepDelay: .milliseconds(1))
    private(set) var scanCalls: [CGRect] = []
    /// Подмена размера стекла (смена сканера)
    var glassOverride: CGSize?
    /// Если задано, preview отдаёт это изображение
    var previewOverride: CGImage?

    var scanners: [ScannerInfo] { inner.scanners }
    var selectedID: String? { inner.selectedID }
    var capabilities: ScannerCapabilities? {
        guard var caps = inner.capabilities else { return nil }
        if let glassOverride { caps.glassSizeMM = glassOverride }
        return caps
    }
    var state: ScannerState { inner.state }
    var partialImage: CGImage? { inner.partialImage }
    var progress: Double { inner.progress }

    func start() { inner.start() }
    func select(_ id: String) async { await inner.select(id) }
    func preview() async throws -> CGImage {
        let image = try await inner.preview()
        return previewOverride ?? image
    }
    func scan(areaMM: CGRect, dpi: Int, mode: ColorMode) async throws -> CGImage {
        scanCalls.append(areaMM)
        return try await inner.scan(areaMM: areaMM, dpi: dpi, mode: mode)
    }
}

@MainActor
final class AppStateTests: XCTestCase {
    private var folder: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var scanner: CountingScanner!
    private var app: AppState!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppStateTests-\(UUID().uuidString)")
        suiteName = "AppStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        scanner = CountingScanner()
        app = AppState(scanner: scanner, defaults: defaults, outputFolder: folder)
        app.start()
        for _ in 0..<200 where !app.isReady { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(app.isReady)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPreviewFillsImageAndResetsStale() async {
        app.previewStale = true
        await app.preview()
        XCTAssertNotNil(app.preview)
        XCTAssertFalse(app.previewStale)
    }

    func testScanWithoutRegionsAddsFullGlassPage() async throws {
        app.dpi = 150
        await app.scan()
        XCTAssertEqual(app.pages.count, 1)
        let image = app.pages[0].image
        XCTAssertEqual(image.width, ScanGeometry.mmToPixels(216, dpi: 150), accuracy: 2)
        XCTAssertEqual(image.height, ScanGeometry.mmToPixels(297, dpi: 150), accuracy: 2)
        XCTAssertNotNil(app.thumbnails[app.pages[0].id])
        XCTAssertEqual(max(app.thumbnails[app.pages[0].id]!.width, app.thumbnails[app.pages[0].id]!.height), 200)
        XCTAssertNotNil(app.lastScanDuration)
    }

    func testScanWithTwoRegionsSinglePassTwoPages() async throws {
        app.dpi = 150
        app.addRegion(MockScene.sheetMM)
        app.addRegion(MockScene.photoMM)
        await app.scan()
        XCTAssertEqual(scanner.scanCalls.count, 1)
        XCTAssertEqual(scanner.scanCalls[0], MockScene.sheetMM.union(MockScene.photoMM))
        XCTAssertEqual(app.pages.count, 2)
        for (page, mm) in zip(app.pages, [MockScene.sheetMM, MockScene.photoMM]) {
            XCTAssertEqual(page.image.width, ScanGeometry.mmToPixels(mm.width, dpi: 150), accuracy: 2)
            XCTAssertEqual(page.image.height, ScanGeometry.mmToPixels(mm.height, dpi: 150), accuracy: 2)
        }
        XCTAssertTrue(app.statusText.contains("страниц в сессии: 2"))
    }

    func testAutoDetectFindsTwoRegions() async {
        await app.preview()
        await app.autoDetect()
        XCTAssertEqual(app.regions.count, 2)
        XCTAssertTrue(app.statusText.contains("Найдено объектов: 2"))
    }

    private func manualRect() -> CGRect { CGRect(x: 20, y: 20, width: 40, height: 40) }

    func testPreviewAutoDetectsOnEmptyRegions() async {
        await app.preview()
        XCTAssertEqual(app.regions.count, 2)
        XCTAssertTrue(app.regionsAreAuto)
        XCTAssertNil(app.selectedRegionID)
        XCTAssertTrue(app.statusText.contains("Превью готово · найдено объектов: 2"))
        XCTAssertEqual(app.activity, .idle)
    }

    func testPreviewKeepsManualRegions() async {
        app.addRegion(manualRect())
        let before = app.regions
        await app.preview()
        XCTAssertEqual(app.regions, before)
        XCTAssertFalse(app.regionsAreAuto)
    }

    func testPreviewKeepsRegionsAfterManualEditOfAuto() async {
        await app.preview()
        await app.autoDetect()
        XCTAssertTrue(app.regionsAreAuto)
        let id = app.regions[0].id
        app.updateRegion(id, rect: manualRect())
        XCTAssertFalse(app.regionsAreAuto)
        let before = app.regions
        await app.preview()
        XCTAssertEqual(app.regions, before)
    }

    func testPreviewReplacesAutoRegions() async {
        await app.preview()
        await app.autoDetect()
        let oldIDs = app.regions.map(\.id)
        await app.preview()
        XCTAssertEqual(app.regions.count, 2)
        XCTAssertNotEqual(app.regions.map(\.id), oldIDs)
        XCTAssertTrue(app.regionsAreAuto)
    }

    func testPreviewWithNothingFoundClearsRegions() async {
        await app.preview()
        XCTAssertEqual(app.regions.count, 2)
        let ctx = ImageOps.makeContext(width: 100, height: 140)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 140))
        scanner.previewOverride = ctx.makeImage()
        await app.preview()
        XCTAssertTrue(app.regions.isEmpty)
        XCTAssertTrue(app.regionsAreAuto)
        XCTAssertTrue(app.statusText.contains("Превью готово · объекты не найдены"))
    }

    func testSaveWritesFilesAndClearsStrip() async throws {
        app.dpi = 75
        await app.scan()
        await app.scan()
        await app.save()
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(app.pages.isEmpty)
        XCTAssertTrue(app.thumbnails.isEmpty)
        XCTAssertEqual(app.lastSavedURLs.count, 1)
        XCTAssertTrue(app.statusText.hasPrefix("Сохранено: 2 стр."))
    }

    func testRotateDeleteMove() async throws {
        app.dpi = 75
        await app.scan()
        await app.scan()
        await app.scan()
        let ids = app.pages.map(\.id)
        let thumbBefore = app.thumbnails[ids[0]]!
        app.rotatePage(ids[0])
        XCTAssertEqual(app.pages[0].quarterTurns, 1)
        let thumbAfter = app.thumbnails[ids[0]]!
        XCTAssertEqual(thumbAfter.width, thumbBefore.height)
        XCTAssertEqual(thumbAfter.height, thumbBefore.width)

        app.movePage(from: 0, to: 2)
        XCTAssertEqual(app.pages.map(\.id), [ids[1], ids[2], ids[0]])
        app.movePage(id: ids[0], before: ids[1])
        XCTAssertEqual(app.pages.map(\.id), [ids[0], ids[1], ids[2]])

        app.deletePage(ids[1])
        XCTAssertEqual(app.pages.map(\.id), [ids[0], ids[2]])
        XCTAssertNil(app.thumbnails[ids[1]])
    }

    func testDeleteSelectionRouting() async {
        app.addRegion(CGRect(x: 10, y: 10, width: 50, height: 50))
        await app.scan()
        app.stripHasFocus = true
        app.deleteSelection()
        XCTAssertTrue(app.pages.isEmpty)
        XCTAssertEqual(app.regions.count, 1)
        app.stripHasFocus = false
        app.deleteSelection()
        XCTAssertTrue(app.regions.isEmpty)
    }

    // MARK: - Состояние операции

    private func waitForActivity(_ target: Activity) async {
        for _ in 0..<500 where app.activity != target { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func testDoubleScanCallsScannerOnce() async {
        app.dpi = 75
        let first = Task { await app.scan() }
        let second = Task { await app.scan() }
        await first.value
        await second.value
        XCTAssertEqual(scanner.scanCalls.count, 1)
        XCTAssertEqual(app.pages.count, 1)
        XCTAssertEqual(app.activity, .idle)
    }

    func testActivityCoversScanAndOtherCommandsAreRejected() async {
        app.dpi = 75
        await app.scan()
        let calls = scanner.scanCalls.count
        let task = Task { await app.scan() }
        await waitForActivity(.scanning)
        XCTAssertEqual(app.activity, .scanning)
        XCTAssertTrue(app.busy)
        await app.save()
        await app.preview()
        XCTAssertNil(app.preview)
        XCTAssertEqual(app.pages.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        await task.value
        XCTAssertEqual(scanner.scanCalls.count, calls + 1)
        XCTAssertEqual(app.pages.count, 2)
    }

    func testScanFillsColorMode() async {
        app.dpi = 75
        app.colorMode = .bw
        await app.scan()
        XCTAssertEqual(app.pages.first?.colorMode, .bw)
    }

    func testSaveKeepsPageAddedDuringSave() async throws {
        app.dpi = 75
        await app.scan()
        let extra = ScannedPage(image: app.pages[0].image, dpi: 75)
        app.afterExportHook = { [app] in
            guard let app else { return }
            app.pages.append(extra)
            app.thumbnails[extra.id] = app.thumbnails[app.pages[0].id]
            // Мутации существующих страниц во время сохранения запрещены
            app.rotatePage(app.pages[0].id)
            app.deletePage(app.pages[0].id)
            app.movePage(from: 0, to: 1)
        }
        await app.save()
        XCTAssertEqual(app.pages.map(\.id), [extra.id])
        XCTAssertNotNil(app.thumbnails[extra.id])
        XCTAssertEqual(app.pages[0].quarterTurns, 0)
        XCTAssertEqual(app.activity, .idle)
    }

    func testSaveFailureKeepsPages() async throws {
        let readOnly = FileManager.default.temporaryDirectory.appendingPathComponent("RO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            try? FileManager.default.removeItem(at: readOnly)
        }
        let failing = AppState(
            scanner: scanner, defaults: defaults, outputFolder: readOnly.appendingPathComponent("sub"))
        failing.dpi = 75
        await failing.scan()
        XCTAssertEqual(failing.pages.count, 1)
        await failing.save()
        XCTAssertEqual(failing.pages.count, 1)
        XCTAssertEqual(failing.thumbnails.count, 1)
        XCTAssertTrue(failing.statusIsError)
        XCTAssertEqual(failing.activity, .idle)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: readOnly.path).isEmpty)
    }

    // MARK: - Смена стекла

    func testGlassChangeClampsRegionsAndMarksStale() async {
        await app.syncScanner()
        await app.preview()
        app.regions = []  // убрать авто-области превью
        app.addRegion(CGRect(x: 10, y: 10, width: 50, height: 50))
        app.addRegion(CGRect(x: 150, y: 200, width: 60, height: 90))
        XCTAssertEqual(app.regions.count, 2)
        scanner.glassOverride = CGSize(width: 100, height: 100)
        await app.syncScanner()
        XCTAssertEqual(app.regions.count, 1)
        XCTAssertEqual(app.regions[0].rectMM, CGRect(x: 10, y: 10, width: 50, height: 50))
        XCTAssertTrue(app.previewStale)

        // Область, торчащая за новое стекло, обрезается
        app.regions[0].rectMM = CGRect(x: 80, y: 10, width: 50, height: 50)
        scanner.glassOverride = CGSize(width: 110, height: 100)
        await app.syncScanner()
        XCTAssertEqual(app.regions[0].rectMM, CGRect(x: 80, y: 10, width: 30, height: 50))
    }

    func testScanUsesClampedUnionAndCropsAgainstIt() async {
        app.dpi = 75
        // Область частично за стеклом (в обход addRegion)
        app.regions = [ScanRegion(rectMM: CGRect(x: 180, y: 250, width: 100, height: 100))]
        await app.scan()
        XCTAssertEqual(scanner.scanCalls, [CGRect(x: 180, y: 250, width: 36, height: 47)])
        XCTAssertEqual(app.pages.count, 1)
        XCTAssertEqual(app.pages[0].image.width, ScanGeometry.mmToPixels(36, dpi: 75), accuracy: 2)
        XCTAssertEqual(app.pages[0].image.height, ScanGeometry.mmToPixels(47, dpi: 75), accuracy: 2)
    }

    func testReconnectSelectsCurrentScanner() async {
        await app.reconnect()
        XCTAssertEqual(scanner.selectedID, "mock")
        XCTAssertTrue(app.isReady)
    }
}
