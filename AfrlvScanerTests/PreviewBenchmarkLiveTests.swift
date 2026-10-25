import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AfrlvScaner

@MainActor
final class PreviewBenchmarkLiveTests: XCTestCase {
    func testPreviewBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["AFRLV_BENCH"] == "1" else { throw XCTSkip("AFRLV_BENCH=1") }
        let service = ScannerService()
        service.start()
        addTeardownBlock { await service.shutdown() }
        let deadline = ContinuousClock.now + .seconds(30)
        while service.scanners.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(250)) }
        let info = try XCTUnwrap(service.scanners.first { $0.name.contains("Deli") } ?? service.scanners.first)
        let t0 = ContinuousClock.now
        if service.selectedID != info.id { await service.select(info.id) }
        let readyDeadline = ContinuousClock.now + .seconds(40)
        while service.state != .ready, ContinuousClock.now < readyDeadline { try await Task.sleep(for: .milliseconds(250)) }
        print("BENCH select: \(ContinuousClock.now - t0) state=\(service.state) diag=\(service.diagnostics)")
        let caps = try XCTUnwrap(service.capabilities)
        let full = CGRect(origin: .zero, size: caps.glassSizeMM)
        let runs: [(String, () async throws -> CGImage)] = [
            ("new preview", { try await service.preview() }),
            ("full gray 300", { try await service.scan(areaMM: full, dpi: 300, mode: .gray) }),
            ("full color 300", { try await service.scan(areaMM: full, dpi: 300, mode: .color) }),
        ]
        for (name, body) in runs {
            let start = ContinuousClock.now
            let image = try await body()
            print("BENCH \(name): \(ContinuousClock.now - start) \(image.width)x\(image.height) firstBand=\(String(describing: service.firstBandDelay)) path=\(String(describing: service.lastTransferPath))")
            let url = URL(fileURLWithPath: "/tmp/afrlv-live/bench_\(name.replacingOccurrences(of: " ", with: "_")).jpg")
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        print("BENCH diagnostics: \(service.diagnostics)")
    }
}
