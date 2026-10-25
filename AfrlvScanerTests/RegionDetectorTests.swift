import XCTest
@testable import AfrlvScaner

final class RegionDetectorTests: XCTestCase {
    func testDetectsTwoRegionsOnMockScene() async throws {
        let glass = MockScene.glassSizeMM
        let image = try XCTUnwrap(MockScene.render(areaMM: CGRect(origin: .zero, size: glass), dpi: 75))
        let regions = await RegionDetector.detect(in: image, glassMM: glass)
        XCTAssertEqual(regions.count, 2, "\(regions)")
        guard regions.count == 2 else { return }
        let expected = [MockScene.sheetMM, MockScene.photoMM]
        for (region, exp) in zip(regions, expected) {
            XCTAssertEqual(region.minX, exp.minX - 2, accuracy: 5)
            XCTAssertEqual(region.minY, exp.minY - 2, accuracy: 5)
            XCTAssertEqual(region.maxX, exp.maxX + 2, accuracy: 5)
            XCTAssertEqual(region.maxY, exp.maxY + 2, accuracy: 5)
        }
    }

    func testFallbackFindsTwoRegions() throws {
        let glass = MockScene.glassSizeMM
        let image = try XCTUnwrap(MockScene.render(areaMM: CGRect(origin: .zero, size: glass), dpi: 75))
        let boxes = RegionDetector.fallbackBoxesForTesting(in: image, glassMM: glass)
        XCTAssertEqual(boxes.count, 2, "\(boxes)")
    }

    func testEmptyGlassReturnsNothing() async throws {
        let glass = MockScene.glassSizeMM
        let ctx = try XCTUnwrap(ImageOps.makeContext(width: 640, height: 880))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 880))
        let image = try XCTUnwrap(ctx.makeImage())
        let regions = await RegionDetector.detect(in: image, glassMM: glass)
        XCTAssertEqual(regions, [])
    }

    func testDetectsOnDownscaledNonProportionalPreview() async throws {
        let glass = MockScene.glassSizeMM
        let source = try XCTUnwrap(MockScene.render(areaMM: CGRect(origin: .zero, size: glass), dpi: 150))
        let ctx = try XCTUnwrap(ImageOps.makeContext(width: 1163, height: 1600))
        ctx.interpolationQuality = .medium
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: 1163, height: 1600))
        let image = try XCTUnwrap(ctx.makeImage())
        let regions = await RegionDetector.detect(in: image, glassMM: glass)
        XCTAssertEqual(regions.count, 2, "\(regions)")
        guard regions.count == 2 else { return }
        for (region, exp) in zip(regions, [MockScene.sheetMM, MockScene.photoMM]) {
            XCTAssertEqual(region.minX, exp.minX - 2, accuracy: 5)
            XCTAssertEqual(region.maxY, exp.maxY + 2, accuracy: 5)
        }
    }

    func testNearDuplicateBoxesCollapse() {
        let a = CGRect(x: 20, y: 20, width: 100, height: 80)
        let b = a.offsetBy(dx: 0.2, dy: 0.2)
        let collapsed = RegionDetector.collapseDuplicates([a, b])
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(RegionDetector.collapseDuplicates([b, a]), collapsed)

        // Все края в пределах 3 мм, но не вложены в строгом смысле
        let c = CGRect(x: 21, y: 19, width: 98, height: 83)
        XCTAssertEqual(RegionDetector.collapseDuplicates([a, c]).count, 1)

        let far = CGRect(x: 150, y: 150, width: 40, height: 40)
        XCTAssertEqual(RegionDetector.collapseDuplicates([a, b, far]).count, 2)
    }

    func testPerformance() throws {
        let glass = MockScene.glassSizeMM
        let image = try XCTUnwrap(MockScene.render(areaMM: CGRect(origin: .zero, size: glass), dpi: 75))
        let start = Date()
        _ = RegionDetector.detectSync(in: image, glassMM: glass)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
