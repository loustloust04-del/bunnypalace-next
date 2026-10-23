import XCTest
import PDFKit
@testable import 记忆花园

/// CR-7 P1.5：OCR 页缓存——真跑 Vision 识别 + jsonl 落盘 + 缓存命中。
final class OCRStoreTests: XCTestCase {
    static let pid = "xctest-cr7-ocr"
    static let book = "ocr测试书"

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: BookStore.booksRoot(profileId: Self.pid).deletingLastPathComponent())
        super.tearDown()
    }

    /// 造一页画着大号英文的 PDF（无文本层——纯绘制位图式路径，Vision 只能靠 OCR 认）。
    private func makeScannedPage(text: String) -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 48),
            .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: 60, y: 400)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)!
    }

    func testRecognizeCachesAndHitsOnSecondCall() async throws {
        let doc = makeScannedPage(text: "HELLO OCR WORLD")

        let lines = await OCRStore.shared.pageLines(
            safeName: Self.book, profileId: Self.pid, page: 1, document: doc)
        XCTAssertFalse(lines.isEmpty, "Vision 应识别出绘制文本")
        let joined = lines.map(\.text).joined(separator: " ").uppercased()
        XCTAssertTrue(joined.contains("HELLO"), "识别内容含 HELLO，实际：\(joined)")

        // bbox 在 cropBox point 范围内
        let b = lines[0].bbox
        XCTAssertEqual(b.count, 4)
        XCTAssertTrue(b[0] >= 0 && b[0] + b[2] <= 612.5, "x 范围合法：\(b)")
        XCTAssertTrue(b[1] >= 0 && b[1] + b[3] <= 792.5, "y 范围合法：\(b)")

        // 缓存文件落盘
        let cacheURL = OCRStore.cacheURL(safeName: Self.book, profileId: Self.pid, page: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        // 二次调用走缓存：改写缓存内容为哨兵，返回哨兵即证明没有重新 OCR
        let sentinel = #"{"text":"CACHED-SENTINEL","bbox":[1,2,3,4]}"# + "\n"
        try sentinel.write(to: cacheURL, atomically: true, encoding: .utf8)
        let cached = await OCRStore.shared.pageText(
            safeName: Self.book, profileId: Self.pid, page: 1, document: doc)
        XCTAssertEqual(cached, "CACHED-SENTINEL")
    }

    func testPageTextJoinsLines() async {
        let doc = makeScannedPage(text: "SINGLE LINE")
        let text = await OCRStore.shared.pageText(
            safeName: Self.book, profileId: Self.pid, page: 2, document: doc)
        // 页码 2 不存在于单页文档 → 空串（越界安全）
        XCTAssertEqual(text, "")
    }
}
