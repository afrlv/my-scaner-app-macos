import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AfrlvScaner

/// Живой тест на реальном сканере. Запуск: TEST_RUNNER_AFRLV_LIVE_SCANNER=1 xcodebuild test ...
@MainActor
final class ScannerServiceLiveTests: XCTestCase {
    private func savePNG(_ image: CGImage, name: String) throws {
        let dir = URL(fileURLWithPath: "/tmp/afrlv-live", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func timed<T>(_ title: String, _ body: () async throws -> T) async throws -> T {
        let start = ContinuousClock.now
        let result = try await body()
        print("LIVE \(title): \(ContinuousClock.now - start)")
        return result
    }

    func testLiveScan() async throws {
        guard ProcessInfo.processInfo.environment["AFRLV_LIVE_SCANNER"] == "1" else {
            throw XCTSkip("Задайте AFRLV_LIVE_SCANNER=1 для живого теста")
        }
        let service = ScannerService()
        service.start()
        addTeardownBlock { await service.shutdown() }

        var found: ScannerInfo?
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let deli = service.scanners.first(where: { $0.name.contains("Deli") }) {
                found = deli
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        if found == nil { found = service.scanners.first }
        let info = try XCTUnwrap(found, "Сканер не найден за 20 с, state=\(service.state)")
        print("LIVE scanners: \(service.scanners)")

        try await timed("select \(info.name)") { await service.select(info.id) }
        XCTAssertEqual(service.state, .ready, "state после select")
        let caps = try XCTUnwrap(service.capabilities)
        print("LIVE capabilities: \(caps)")

        let preview = try await timed("preview") { try await service.preview() }
        print("LIVE preview: \(preview.width)x\(preview.height), bands=\(service.scanBandCount), firstBand=\(String(describing: service.firstBandDelay))")
        try savePNG(preview, name: "preview.png")
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), 1600)
        XCTAssertEqual(
            Double(preview.width) / Double(preview.height), caps.glassSizeMM.width / caps.glassSizeMM.height,
            accuracy: 0.02)

        let area = CGRect(x: 10, y: 10, width: 100, height: 60)
        let color = try await timed("scan color") { try await service.scan(areaMM: area, dpi: 150, mode: .color) }
        print("LIVE scan color: \(color.width)x\(color.height), path=\(String(describing: service.lastTransferPath)), bands=\(service.scanBandCount)")
        try savePNG(color, name: "scan_color.png")

        let gray = try await timed("scan gray") { try await service.scan(areaMM: area, dpi: 150, mode: .gray) }
        print("LIVE scan gray: \(gray.width)x\(gray.height), path=\(String(describing: service.lastTransferPath)), bands=\(service.scanBandCount)")
        try savePNG(gray, name: "scan_gray.png")

        for image in [color, gray] {
            XCTAssertEqual(Double(image.width), 591, accuracy: 591 * 0.03)
            XCTAssertEqual(Double(image.height), 354, accuracy: 354 * 0.03)
        }
        // Всё стекло, серый 300 dpi: именно тут раньше съезжали строки
        let full = CGRect(origin: .zero, size: caps.glassSizeMM)
        let big = try await timed("scan gray full 300") { try await service.scan(areaMM: full, dpi: 300, mode: .gray) }
        print("LIVE gray full: \(big.width)x\(big.height), bands=\(service.scanBandCount)")
        try savePNG(big, name: "gray_full.png")
        XCTAssertEqual(big.width, ScanGeometry.mmToPixels(caps.glassSizeMM.width, dpi: 300))
        XCTAssertEqual(big.height, ScanGeometry.mmToPixels(caps.glassSizeMM.height, dpi: 300))
        print("LIVE diagnostics: \(service.diagnostics)")
        XCTAssertEqual(service.state, .ready)
    }
}
