import CoreGraphics
import XCTest

@testable import AfrlvScaner

final class BandAssemblerTests: XCTestCase {
    private func pixels(_ image: CGImage) -> [UInt8] {
        let ctx = ImageOps.makeContext(width: image.width, height: image.height)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: ctx.bytesPerRow * ctx.height))
    }

    func testRGBBandsOutOfOrderWithPadding() throws {
        // 4x4 RGB, bytesPerRow с выравниванием 16 (12 полезных + 4 мусора)
        let format = BandFormat(
            width: 4, height: 4, bitsPerPixel: 24, bitsPerComponent: 8, numComponents: 3, bigEndian: false)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        func band(rows: [UInt8]) -> Data {
            var d = Data()
            for v in rows {
                d.append(contentsOf: [UInt8](repeating: v, count: 12))
                d.append(contentsOf: [0xEE, 0xEE, 0xEE, 0xEE])
            }
            return d
        }
        XCTAssertEqual(asm.add(band(rows: [200, 250]), startRow: 2, numRows: 2, bytesPerRow: 16), 2)
        XCTAssertEqual(asm.add(band(rows: [10, 60]), startRow: 0, numRows: 2, bytesPerRow: 16), 2)
        XCTAssertEqual(asm.fraction, 1)
        let image = try XCTUnwrap(asm.makeImage())
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 4)
        let px = pixels(image)
        let rowBytes = px.count / 4
        for (row, value) in [10, 60, 200, 250].enumerated() {
            XCTAssertEqual(Int(px[row * rowBytes]), value, accuracy: 3)
        }
    }

    func testPartialImageHasReceivedRows() throws {
        let format = BandFormat(
            width: 8, height: 10, bitsPerPixel: 8, bitsPerComponent: 8, numComponents: 1, bigEndian: false)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        XCTAssertNil(asm.makeImage())
        asm.add(Data(repeating: 128, count: 8 * 3), startRow: 0, numRows: 3, bytesPerRow: 8)
        XCTAssertEqual(asm.makeImage()?.height, 3)
        XCTAssertEqual(asm.fraction, 0.3, accuracy: 1e-9)
    }

    func testBandBeyondImageIsClamped() throws {
        let format = BandFormat(
            width: 2, height: 2, bitsPerPixel: 8, bitsPerComponent: 8, numComponents: 1, bigEndian: false)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        XCTAssertEqual(asm.add(Data(repeating: 1, count: 6), startRow: 1, numRows: 3, bytesPerRow: 2), 1)
        XCTAssertEqual(asm.add(Data(repeating: 1, count: 6), startRow: 5, numRows: 3, bytesPerRow: 2), 0)
    }

    func testOneBitGray() throws {
        let format = BandFormat(
            width: 8, height: 2, bitsPerPixel: 1, bitsPerComponent: 1, numComponents: 1, bigEndian: false)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        // строка 0: все 1 (белые), строка 1: все 0 (чёрные)
        asm.add(Data([0xFF, 0x00]), startRow: 0, numRows: 2, bytesPerRow: 1)
        let image = try XCTUnwrap(asm.makeImage())
        XCTAssertEqual(image.bitsPerComponent, 1)
        let gray = ImageOps.toGray(image)
        let ctx = ImageOps.makeContext(width: 8, height: 2, gray: true)!
        ctx.draw(gray, in: CGRect(x: 0, y: 0, width: 8, height: 2))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(bytes[0], 255)
        XCTAssertEqual(bytes[ctx.bytesPerRow], 0)
    }

    func testSixteenBitGrayBigEndian() throws {
        let format = BandFormat(
            width: 2, height: 1, bitsPerPixel: 16, bitsPerComponent: 16, numComponents: 1, bigEndian: true)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        asm.add(Data([0xFF, 0xFF, 0x00, 0x00]), startRow: 0, numRows: 1, bytesPerRow: 4)
        let image = try XCTUnwrap(asm.makeImage())
        XCTAssertEqual(image.bitsPerComponent, 16)
        let ctx = ImageOps.makeContext(width: 2, height: 1, gray: true)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(bytes[0], 255)
        XCTAssertEqual(bytes[1], 0)
    }

    func testRGBXSkipsFourthByte() throws {
        let format = BandFormat(
            width: 2, height: 1, bitsPerPixel: 32, bitsPerComponent: 8, numComponents: 4, bigEndian: false)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        asm.add(Data([255, 0, 0, 0, 0, 255, 0, 0]), startRow: 0, numRows: 1, bytesPerRow: 8)
        let image = try XCTUnwrap(asm.makeImage())
        let px = pixels(image)
        XCTAssertEqual(px[0], 255, accuracy: 3)  // R первого пикселя
        XCTAssertEqual(px[3], 255)  // непрозрачный
        XCTAssertEqual(px[5], 255, accuracy: 3)  // G второго
    }

    func testInvalidFormatRejected() {
        let bad = BandFormat(
            width: 0, height: 5, bitsPerPixel: 8, bitsPerComponent: 8, numComponents: 1, bigEndian: false)
        XCTAssertNil(BandAssembler(format: bad))
        let odd = BandFormat(
            width: 2, height: 2, bitsPerPixel: 24, bitsPerComponent: 8, numComponents: 4, bigEndian: false)
        XCTAssertNil(BandAssembler(format: odd))
    }

    // MARK: Deli M1820W, серый 300 dpi

    /// Метаданные снятого на реальном Deli: 2550x3510, 8 bpp, 1 компонента, bytesPerRow 2552,
    /// полосы по 821 строке (buf 2 095 192 = 821*2552), последняя - 226 строк (576 752).
    /// Данные при этом плотные (шаг 2550) и строки переходят из полосы в полосу.
    private func deliStream(width: Int, height: Int, bpr: Int) -> [UInt8] {
        var stream = [UInt8](repeating: 0, count: height * bpr)
        var seed: UInt32 = 12345
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                // гладкий градиент + шум: соседние строки похожи, но не равны
                stream[y * width + x] = UInt8(truncatingIfNeeded: (x / 16 + y / 8) + Int(seed >> 28))
            }
        }
        return stream
    }

    func testDeliGrayPackedStreamWithAlignedBytesPerRow() throws {
        let width = 2550, height = 3510, bpr = 2552, bandRows = 821
        let format = BandFormat(
            width: width, height: height, bitsPerPixel: 8, bitsPerComponent: 8, numComponents: 1, bigEndian: false)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        let stream = deliStream(width: width, height: height, bpr: bpr)
        var start = 0
        while start < height {
            let rows = min(bandRows, height - start)
            let from = start * bpr
            let band = Data(stream[from..<(from + rows * bpr)])
            XCTAssertEqual(asm.add(band, startRow: start, numRows: rows, bytesPerRow: bpr), rows)
            if start == 0 { XCTAssertEqual(band.count, 2_095_192) }
            if rows == 226 { XCTAssertEqual(band.count, 576_752) }
            start += rows
        }
        XCTAssertEqual(asm.layout, .packed)
        XCTAssertTrue(asm.isComplete)
        let image = try XCTUnwrap(asm.makeImage())
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        XCTAssertEqual(image.bytesPerRow, width)
        // Пиксели совпадают с исходным плотным потоком (в том числе на стыках полос)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        for y in [0, 1, 820, 821, 822, 1642, 1643, 2463, 2464, 3284, 3509] {
            for x in [0, 1, 1275, 2548, 2549] {
                XCTAssertEqual(data[y * width + x], stream[y * width + x], "x=\(x) y=\(y)")
            }
        }
    }

    func testIncompleteCoverageIsNotComplete() throws {
        let format = BandFormat(
            width: 8, height: 10, bitsPerPixel: 8, bitsPerComponent: 8, numComponents: 1, bigEndian: false)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        asm.add(Data(repeating: 1, count: 8 * 4), startRow: 0, numRows: 4, bytesPerRow: 8)
        // дыра: строки 4..5 не пришли
        asm.add(Data(repeating: 2, count: 8 * 4), startRow: 6, numRows: 4, bytesPerRow: 8)
        XCTAssertFalse(asm.isComplete)
        XCTAssertEqual(asm.makeImage()?.height, 4)
        // полоса короче заявленной: покрытие считается по фактической длине
        var asm2 = try XCTUnwrap(BandAssembler(format: format))
        asm2.add(Data(repeating: 1, count: 8 * 5), startRow: 0, numRows: 10, bytesPerRow: 8)
        XCTAssertFalse(asm2.isComplete)
        asm2.add(Data(repeating: 1, count: 8 * 5), startRow: 5, numRows: 5, bytesPerRow: 8)
        XCTAssertTrue(asm2.isComplete)
    }

    func testThumbnailIsDownscaledAndCoversReceivedRows() throws {
        let format = BandFormat(
            width: 400, height: 800, bitsPerPixel: 8, bitsPerComponent: 8, numComponents: 1, bigEndian: false)
        var asm = try XCTUnwrap(BandAssembler(format: format))
        XCTAssertNil(asm.makeThumbnail(maxSide: 100))
        asm.add(Data(repeating: 100, count: 400 * 400), startRow: 0, numRows: 400, bytesPerRow: 400)
        let thumb = try XCTUnwrap(asm.makeThumbnail(maxSide: 100))
        XCTAssertEqual(thumb.width, 50)
        XCTAssertEqual(thumb.height, 50)
    }

    func testPipelineReturnsIncompleteError() async throws {
        let pipeline = ScanPipeline { _, _ in }
        let meta = BandMeta(
            fullWidth: 8, fullHeight: 10, bitsPerPixel: 8, numComponents: 1, bitsPerComponent: 8,
            bytesPerRow: 8, dataStartRow: 0, dataNumRows: 4, dataCount: 32, pixelDataType: 1,
            bigEndian: false, profilePath: nil)
        pipeline.addBand(Data(repeating: 9, count: 32), meta: meta)
        await pipeline.drain()
        let (result, snapshot) = await pipeline.result(mode: .gray, target: CGSize(width: 8, height: 10), maxSide: nil)
        XCTAssertEqual(snapshot.bands, 1)
        guard case .failure(let error) = result, case .incomplete = error else {
            return XCTFail("ожидалась ошибка incomplete, получили \(result)")
        }
        XCTAssertEqual(error.errorDescription, "Сканер передал неполное изображение")
    }

    func testDeviceUnits() {
        let cm = DeviceUnits(kind: .centimeters)
        XCTAssertEqual(cm.toUnit(100), 10, accuracy: 1e-9)
        XCTAssertEqual(cm.toMM(21.6), 216, accuracy: 1e-9)
        let inch = DeviceUnits(kind: .inches)
        XCTAssertEqual(inch.toUnit(25.4), 1, accuracy: 1e-9)
        let r = inch.rectToUnit(CGRect(x: 25.4, y: 50.8, width: 76.2, height: 25.4))
        XCTAssertEqual(r.minX, 1, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 2, accuracy: 1e-9)
        XCTAssertEqual(r.width, 3, accuracy: 1e-9)
        XCTAssertEqual(r.height, 1, accuracy: 1e-9)
    }
}
