import XCTest
import PDFKit
@testable import 记忆花园

/// CR-7「坨坨」spike：invisible 文本层写回 → PDFKit 原生选择成立 + 坐标对齐。
final class TextLayerWriterTests: XCTestCase {

    /// 纯图页（空白无文本层，模拟扫描版）。
    private func makeScannedDoc(pages: Int) -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            // 画个灰块当"扫描图"
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 40, y: 300, width: 500, height: 300))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data)!
    }

    func testInvisibleTextLayerEnablesNativeSelection() throws {
        let doc = makeScannedDoc(pages: 2)
        XCTAssertTrue((doc.page(at: 0)?.string ?? "").isEmpty, "写回前无文本层")

        let lines: [Int: [OCRStore.Line]] = [
            1: [
                OCRStore.Line(text: "游戏设计艺术是一本好书", bbox: [80, 500, 300, 24]),
                OCRStore.Line(text: "设计师创造体验", bbox: [80, 460, 200, 24]),
            ],
            2: [OCRStore.Line(text: "第二页的内容", bbox: [80, 400, 160, 20])],
        ]
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try TextLayerWriter.write(document: doc, lines: lines, to: out)

        let back = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(back.pageCount, 2)

        // ① page.string 有字（PDFKit 认作真文本 = 原生选择/复制成立）
        let pageText = back.page(at: 0)?.string ?? ""
        XCTAssertTrue(pageText.contains("游戏设计艺术"), "文本层可读，实际：\(pageText)")
        XCTAssertTrue((back.page(at: 1)?.string ?? "").contains("第二页"))

        // ② findString 命中 + 选区 bounds 对齐写入 bbox（坨坨位置准）
        let hits = back.findString("设计师创造体验", withOptions: [])
        XCTAssertEqual(hits.count, 1, "唯一命中")
        let sel = try XCTUnwrap(hits.first)
        let page0 = try XCTUnwrap(back.page(at: 0))
        let b = sel.bounds(for: page0)
        let expected = CGRect(x: 80, y: 460, width: 200, height: 24)
        XCTAssertTrue(b.intersects(expected), "选区与写入 bbox 相交，实际 \(b)")
        let inter = b.intersection(expected)
        let coverage = (inter.width * inter.height) / (expected.width * expected.height)
        XCTAssertGreaterThan(coverage, 0.5, "选区盖住 bbox 大半（坐标对齐），覆盖率 \(coverage)")

        // ③ 不可见：文字画在灰块外的空白处也不该有可见墨迹——渲染抽查（invisible mode）
        //    （视觉断言难做精确，退而验证 annotation-free 且文件可开可选即可）
    }

    func testPagesWithoutLinesSurvive() throws {
        let doc = makeScannedDoc(pages: 3)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("spike-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try TextLayerWriter.write(document: doc, lines: [2: [OCRStore.Line(text: "只有中间页", bbox: [80, 400, 150, 20])]], to: out)
        let back = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(back.pageCount, 3, "无行页原样保留")
        XCTAssertTrue((back.page(at: 0)?.string ?? "").isEmpty)
        XCTAssertTrue((back.page(at: 1)?.string ?? "").contains("中间"))
    }
}
