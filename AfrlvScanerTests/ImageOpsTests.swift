import XCTest
@testable import AfrlvScaner

final class ImageOpsTests: XCTestCase {
    /// 40x20: левая половина красная/зелёная (верх/низ), правая синяя/жёлтая
    private func quadrants() -> CGImage {
        let ctx = ImageOps.makeContext(width: 40, height: 20)!
        func fill(_ c: CGColor, _ r: CGRect) { ctx.setFillColor(c); ctx.fill(r) }
        // CGContext: y вверх, поэтому верх изображения — большие y
        fill(CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGRect(x: 0, y: 10, width: 20, height: 10))
        fill(CGColor(red: 0, green: 1, blue: 0, alpha: 1), CGRect(x: 0, y: 0, width: 20, height: 10))
        fill(CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGRect(x: 20, y: 10, width: 20, height: 10))
        fill(CGColor(red: 1, green: 1, blue: 0, alpha: 1), CGRect(x: 20, y: 0, width: 20, height: 10))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let ctx = ImageOps.makeContext(width: image.width, height: image.height)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + y * ctx.bytesPerRow + x * 4
        return [Int(p[0]), Int(p[1]), Int(p[2])]
    }

    private func assertColor(_ actual: [Int], _ expected: [Int], line: UInt = #line) {
        XCTAssertTrue(zip(actual, expected).allSatisfy { abs($0 - $1) <= 50 }, "\(actual) != \(expected)", line: line)
    }

    func testCropSizeAndContent() {
        let image = quadrants()
        let scan = CGRect(x: 0, y: 0, width: 40, height: 20)
        let crops = ImageOps.crop(
            image, regionsMM: [CGRect(x: 20, y: 10, width: 20, height: 10), CGRect(x: 0, y: 0, width: 20, height: 10)],
            scanAreaMM: scan)
        XCTAssertEqual(crops.count, 2)
        XCTAssertEqual(crops[0].width, 20)
        XCTAssertEqual(crops[0].height, 10)
        assertColor(pixel(crops[0], 5, 5), [255, 255, 0])
        assertColor(pixel(crops[1], 5, 5), [255, 0, 0])
    }

    func testCropScaledImage() {
        let image = quadrants()
        let crops = ImageOps.crop(
            image, regionsMM: [CGRect(x: 0, y: 0, width: 10, height: 5)],
            scanAreaMM: CGRect(x: 0, y: 0, width: 20, height: 10))
        XCTAssertEqual(crops.first?.width, 20)
        XCTAssertEqual(crops.first?.height, 10)
    }

    func testCropDoesNotRetainSource() {
        let image = quadrants()
        let crops = ImageOps.crop(
            image, regionsMM: [CGRect(x: 0, y: 0, width: 10, height: 5)],
            scanAreaMM: CGRect(x: 0, y: 0, width: 40, height: 20))
        let fragment = crops[0]
        XCTAssertEqual([fragment.width, fragment.height], [10, 5])
        let sourceBytes = image.bytesPerRow * image.height
        let length = CFDataGetLength(fragment.dataProvider!.data!)
        XCTAssertLessThanOrEqual(length, fragment.bytesPerRow * fragment.height)
        XCTAssertLessThan(length, sourceBytes / 4)
    }

    func testCropKeepsGray() {
        let gray = ImageOps.toGray(quadrants())
        let crops = ImageOps.crop(
            gray, regionsMM: [CGRect(x: 0, y: 0, width: 10, height: 5)],
            scanAreaMM: CGRect(x: 0, y: 0, width: 40, height: 20))
        XCTAssertEqual(crops[0].bitsPerPixel, 8)
        XCTAssertEqual(crops[0].colorSpace?.model, .monochrome)
    }

    func testRotate() {
        let image = quadrants()
        let r1 = ImageOps.rotate(image, quarterTurns: 1)
        XCTAssertEqual([r1.width, r1.height], [20, 40])
        // по часовой: левый верх (красный) -> правый верх
        assertColor(pixel(r1, 15, 5), [255, 0, 0])
        assertColor(pixel(r1, 5, 5), [0, 255, 0])
        assertColor(pixel(r1, 5, 35), [255, 255, 0])

        let r2 = ImageOps.rotate(image, quarterTurns: 2)
        XCTAssertEqual([r2.width, r2.height], [40, 20])
        assertColor(pixel(r2, 35, 15), [255, 0, 0])
        assertColor(pixel(r2, 5, 5), [255, 255, 0])

        let r3 = ImageOps.rotate(image, quarterTurns: 3)
        XCTAssertEqual([r3.width, r3.height], [20, 40])
        assertColor(pixel(r3, 5, 35), [255, 0, 0])
        assertColor(pixel(r3, 15, 5), [255, 255, 0])

        let r4 = ImageOps.rotate(image, quarterTurns: 4)
        XCTAssertEqual([r4.width, r4.height], [40, 20])
        XCTAssertEqual([ImageOps.rotate(image, quarterTurns: -1).width], [20])
    }

    func testGrayAndBW() {
        let image = quadrants()
        XCTAssertEqual(ImageOps.toGray(image).bitsPerPixel, 8)
        let bw = ImageOps.toBW(image)
        XCTAssertEqual(bw.width, 40)
        let ctx = ImageOps.makeContext(width: 40, height: 20, gray: true)!
        ctx.draw(bw, in: CGRect(x: 0, y: 0, width: 40, height: 20))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<20 { for x in 0..<40 { XCTAssertTrue(bytes[y * ctx.bytesPerRow + x] == 0 || bytes[y * ctx.bytesPerRow + x] == 255) } }
    }
}
