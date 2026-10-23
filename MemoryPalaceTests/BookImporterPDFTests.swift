import XCTest
import SwiftData
import PDFKit
@testable import 记忆花园

/// CR-7 P1：PDF 导入——index 元数据 / 文本层检测 / 查重。
final class BookImporterPDFTests: XCTestCase {
    static let pid = "xctest-cr7-pdf"

    var container: ModelContainer!
    var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: BookEntry.self, configurations: config)
        context = ModelContext(container)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: BookStore.booksRoot(profileId: Self.pid).deletingLastPathComponent())
        container = nil
        super.tearDown()
    }

    /// Core Graphics 造 PDF：withText=true 用 CTLineDraw 真文本绘制（有文本层）；
    /// false 全空白页（模拟扫描版——无文本层）。
    private func makePDF(pages: Int, withText: Bool) -> URL {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            if withText {
                let attr = NSAttributedString(
                    string: "这是第 \(i + 1) 页的测试内容，足够长的一段文本用于文本层抽样检测通过阈值。This is page \(i + 1) with enough sample text.",
                    attributes: [.font: NSFont.systemFont(ofSize: 18)]
                )
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: 40, y: 400)
                CTLineDraw(line, ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cr7-test-\(UUID().uuidString).pdf")
        data.write(to: url, atomically: true)
        return url
    }

    func testImportPDFWithTextLayer() async throws {
        let url = makePDF(pages: 5, withText: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await BookImporter.importPDF(
            url: url, bookName: "文字版测试", profileId: Self.pid, context: context
        )
        XCTAssertEqual(result.totalChapters, 5, "PDF 语义 = 页数")

        let idx = BookStore.loadIndex(safeName: result.safeName, profileId: Self.pid)
        XCTAssertEqual(idx?.format, "pdf")
        XCTAssertEqual(idx?.totalChapters, 5)
        XCTAssertEqual(idx?.hasTextLayer, true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: BookStore.bookDir(safeName: result.safeName, profileId: Self.pid)
                .appendingPathComponent("book.pdf").path), "原文件拷入")
    }

    func testImportScannedPDFDetectsNoTextLayer() async throws {
        let url = makePDF(pages: 4, withText: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await BookImporter.importPDF(
            url: url, bookName: "扫描版测试", profileId: Self.pid, context: context
        )
        let idx = BookStore.loadIndex(safeName: result.safeName, profileId: Self.pid)
        XCTAssertEqual(idx?.hasTextLayer, false, "空白页 PDF 判扫描版")
    }

    func testImportDuplicateNameRejected() async throws {
        let url = makePDF(pages: 2, withText: true)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await BookImporter.importPDF(url: url, bookName: "重复书", profileId: Self.pid, context: context)
        do {
            _ = try await BookImporter.importPDF(url: url, bookName: "重复书", profileId: Self.pid, context: context)
            XCTFail("应拒绝重复导入")
        } catch {
            // 期望 duplicateName
        }
    }
}
