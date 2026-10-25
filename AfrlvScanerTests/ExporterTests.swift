import PDFKit
import XCTest
@testable import AfrlvScaner

final class ExporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AfrlvScanerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func page(widthMM: CGFloat = 210, heightMM: CGFloat = 297, dpi: Int = 150, turns: Int = 0) -> ScannedPage {
        let image = MockScene.render(areaMM: CGRect(x: 0, y: 0, width: widthMM, height: heightMM), dpi: dpi)!
        return ScannedPage(image: image, dpi: dpi, quarterTurns: turns)
    }

    func testBaseName() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 5; comps.hour = 7; comps.minute = 8; comps.second = 9
        let date = Calendar.current.date(from: comps)!
        XCTAssertEqual(FileNaming.baseName(date: date), "scan_2026-03-05_070809")
    }

    func testUniqueURL() throws {
        let first = FileNaming.uniqueURL(folder: folder, base: "a", ext: "pdf")
        XCTAssertEqual(first.lastPathComponent, "a.pdf")
        try Data().write(to: first)
        let second = FileNaming.uniqueURL(folder: folder, base: "a", ext: "pdf")
        XCTAssertEqual(second.lastPathComponent, "a_2.pdf")
        try Data().write(to: second)
        XCTAssertEqual(FileNaming.uniqueURL(folder: folder, base: "a", ext: "pdf").lastPathComponent, "a_3.pdf")
    }

    func testPDFThreePages() throws {
        let url = folder.appendingPathComponent("x.pdf")
        try Exporter.writePDF(pages: [page(), page(), page(turns: 1)], to: url)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(doc.pageCount, 3)
        let size = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertEqual(size.width, 595, accuracy: 2)
        XCTAssertEqual(size.height, 842, accuracy: 2)
        let rotated = try XCTUnwrap(doc.page(at: 2)).bounds(for: .mediaBox).size
        XCTAssertEqual(rotated.width, 842, accuracy: 2)
        XCTAssertEqual(rotated.height, 595, accuracy: 2)
    }

    func testPDFEmptyThrows() {
        XCTAssertThrowsError(try Exporter.writePDF(pages: [], to: folder.appendingPathComponent("e.pdf")))
    }

    func testJPEGRoundTrip() throws {
        let url = folder.appendingPathComponent("x.jpg")
        let p = page(widthMM: 50, heightMM: 30, dpi: 200)
        try Exporter.writeJPEG(page: p, to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, p.image.width)
        XCTAssertEqual(image.height, p.image.height)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyDPIWidth] as? Int, 200)
    }

    func testSaveModes() throws {
        let pages = [page(widthMM: 40, heightMM: 40, dpi: 75), page(widthMM: 40, heightMM: 40, dpi: 75), page(widthMM: 40, heightMM: 40, dpi: 75)]
        let date = Date()
        let sub = folder.appendingPathComponent("new/dir")

        let single = try Exporter.save(pages: pages, format: .pdf, split: .singleFile, folder: sub, date: date)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].pathExtension, "pdf")

        let separate = try Exporter.save(pages: pages, format: .pdf, split: .separateFiles, folder: sub, date: date)
        XCTAssertEqual(separate.map(\.lastPathComponent).sorted(), ["\(FileNaming.baseName(date: date))_\(1).pdf", "\(FileNaming.baseName(date: date))_2.pdf", "\(FileNaming.baseName(date: date))_3.pdf"].sorted())

        let jpegs = try Exporter.save(pages: pages, format: .jpeg, split: .singleFile, folder: sub, date: date)
        XCTAssertEqual(jpegs.count, 3)
        XCTAssertTrue(jpegs.allSatisfy { $0.pathExtension == "jpg" })

        let oneJPEG = try Exporter.save(pages: [pages[0]], format: .jpeg, split: .separateFiles, folder: folder.appendingPathComponent("one"), date: date)
        XCTAssertEqual(oneJPEG[0].lastPathComponent, "\(FileNaming.baseName(date: date)).jpg")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sub.path).count, 7)
    }

    func testPDFWithBWPageHasNoJPEG() throws {
        let color = page(widthMM: 40, heightMM: 40, dpi: 75)
        var bw = page(widthMM: 40, heightMM: 40, dpi: 75)
        bw.image = ImageOps.toBW(bw.image)
        bw.colorMode = .bw

        let bwURL = folder.appendingPathComponent("bw.pdf")
        try Exporter.writePDF(pages: [bw], to: bwURL)
        XCTAssertEqual(PDFDocument(url: bwURL)?.pageCount, 1)
        XCTAssertNil(try Data(contentsOf: bwURL).range(of: Data("DCTDecode".utf8)))

        let colorURL = folder.appendingPathComponent("color.pdf")
        try Exporter.writePDF(pages: [color], to: colorURL)
        XCTAssertNotNil(try Data(contentsOf: colorURL).range(of: Data("DCTDecode".utf8)))
    }

    func testNoTemporaryFilesLeft() throws {
        try Exporter.writePDF(pages: [page(widthMM: 40, heightMM: 40, dpi: 75)], to: folder.appendingPathComponent("a.pdf"))
        try Exporter.writeJPEG(page: page(widthMM: 40, heightMM: 40, dpi: 75), to: folder.appendingPathComponent("a.jpg"))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.sorted(), ["a.jpg", "a.pdf"])
    }

    func testWriteFailureThrowsAndLeavesNoFiles() throws {
        let readOnly = folder.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let p = page(widthMM: 40, heightMM: 40, dpi: 75)
        XCTAssertThrowsError(try Exporter.writePDF(pages: [p], to: readOnly.appendingPathComponent("x.pdf")))
        XCTAssertThrowsError(try Exporter.writeJPEG(page: p, to: readOnly.appendingPathComponent("x.jpg")))
        XCTAssertThrowsError(try Exporter.save(
            pages: [p], format: .pdf, split: .singleFile, folder: readOnly.appendingPathComponent("sub"), date: Date()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: readOnly.path).isEmpty)
    }

    func testMissingVolumeThrows() {
        let p = page(widthMM: 40, heightMM: 40, dpi: 75)
        XCTAssertThrowsError(try Exporter.save(
            pages: [p], format: .jpeg, split: .singleFile,
            folder: URL(fileURLWithPath: "/Volumes/__no_such_volume__/out"), date: Date()))
    }
}
