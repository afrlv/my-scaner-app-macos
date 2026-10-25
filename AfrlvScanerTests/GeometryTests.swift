import XCTest
@testable import AfrlvScaner

final class GeometryTests: XCTestCase {
    func testMMToPixels() {
        XCTAssertEqual(ScanGeometry.mmToPixels(25.4, dpi: 300), 300)
        XCTAssertEqual(ScanGeometry.mmToPixels(210, dpi: 150), 1240)
        XCTAssertEqual(ScanGeometry.mmToPixels(0, dpi: 600), 0)
    }

    func testUnion() {
        XCTAssertNil(ScanGeometry.union([]))
        let u = ScanGeometry.union([CGRect(x: 10, y: 10, width: 5, height: 5), CGRect(x: 0, y: 20, width: 5, height: 5)])
        XCTAssertEqual(u, CGRect(x: 0, y: 10, width: 15, height: 15))
    }

    func testClamp() {
        let glass = CGSize(width: 216, height: 297)
        XCTAssertEqual(
            ScanGeometry.clamp(CGRect(x: -10, y: 290, width: 50, height: 50), to: glass),
            CGRect(x: 0, y: 290, width: 40, height: 7))
        XCTAssertEqual(
            ScanGeometry.clamp(CGRect(x: 50, y: 50, width: -20, height: -20), to: glass),
            CGRect(x: 30, y: 30, width: 20, height: 20))
        XCTAssertEqual(ScanGeometry.clamp(CGRect(x: 300, y: 0, width: 10, height: 10), to: glass), .zero)
    }

    func testPixelRectProportional() {
        let scan = CGRect(x: 0, y: 0, width: 100, height: 200)
        let r = ScanGeometry.pixelRect(
            of: CGRect(x: 10, y: 20, width: 30, height: 40), inScanAreaMM: scan, imageSize: CGSize(width: 200, height: 400))
        XCTAssertEqual(r, CGRect(x: 20, y: 40, width: 60, height: 80))
    }

    func testPixelRectNonProportionalAndOffset() {
        let scan = CGRect(x: 50, y: 100, width: 100, height: 100)
        let r = ScanGeometry.pixelRect(
            of: CGRect(x: 60, y: 110, width: 20, height: 40), inScanAreaMM: scan, imageSize: CGSize(width: 101, height: 203))
        XCTAssertEqual(r, CGRect(x: 10, y: 20, width: 20, height: 81))
    }

    func testPixelRectAtEdgeIsClipped() {
        let scan = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r = ScanGeometry.pixelRect(
            of: CGRect(x: 90, y: 90, width: 30, height: 30), inScanAreaMM: scan, imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(r, CGRect(x: 90, y: 90, width: 10, height: 10))
        let outside = ScanGeometry.pixelRect(
            of: CGRect(x: 200, y: 200, width: 5, height: 5), inScanAreaMM: scan, imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(outside, .zero)
    }

    func testViewMMRoundTrip() {
        let view = CGSize(width: 432, height: 594)
        let glass = CGSize(width: 216, height: 297)
        let mm = ScanGeometry.viewToMM(CGPoint(x: 216, y: 297), viewSize: view, glass: glass)
        XCTAssertEqual(mm, CGPoint(x: 108, y: 148.5))
        let back = ScanGeometry.mmToView(mm, viewSize: view, glass: glass)
        XCTAssertEqual(back.x, 216, accuracy: 1e-9)
        XCTAssertEqual(back.y, 297, accuracy: 1e-9)
    }
}
