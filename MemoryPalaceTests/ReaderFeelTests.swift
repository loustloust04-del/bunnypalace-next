import XCTest
import PDFKit
@testable import 记忆花园

/// F1-F2 阅读器体感包：书签读写/toggle + 全书搜索（txt / OCR 降级 / snippet）。
final class ReaderFeelTests: XCTestCase {
    static let pid = "xctest-reader-feel"
    static let book = "体感测试书"

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: BookStore.booksRoot(profileId: Self.pid).deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - F1 书签

    func testBookmarkToggleAndRoundTrip() {
        // 存
        XCTAssertTrue(BookStore.toggleBookmark(
            safeName: Self.book, profileId: Self.pid, chapter: 3, scrollRatio: 0.4, title: "第三章"))
        XCTAssertTrue(BookStore.toggleBookmark(
            safeName: Self.book, profileId: Self.pid, chapter: 1, scrollRatio: 0, title: "第一章"))

        let bms = BookStore.loadBookmarks(safeName: Self.book, profileId: Self.pid)
        XCTAssertEqual(bms.count, 2)
        XCTAssertEqual(bms.map(\.chapter), [1, 3], "按章排序")
        XCTAssertEqual(bms[1].scrollRatio, 0.4)

        // 同章再 toggle = 删
        XCTAssertFalse(BookStore.toggleBookmark(
            safeName: Self.book, profileId: Self.pid, chapter: 3, scrollRatio: 0.9, title: "x"))
        XCTAssertEqual(BookStore.loadBookmarks(safeName: Self.book, profileId: Self.pid).count, 1)
    }

    // MARK: - F2 搜索

    private func seedChapter(_ no: Int, text: String) {
        let url = BookStore.chapterURL(safeName: Self.book, chapterNo: no, profileId: Self.pid)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testSearchTxtHitsWithSnippets() {
        seedChapter(1, text: "开头的一段话。设计师创造体验，这是全书的核心论点。结尾还有别的。")
        seedChapter(2, text: "第二章没有关键词。")
        seedChapter(3, text: "体验又出现了一次。中间隔开一些字。体验再出现一次。体验第三次。体验第四次。")
        let chapters = [
            BookStore.ChapterMeta(no: 1, title: "第一章", chars: 0),
            BookStore.ChapterMeta(no: 2, title: "第二章", chars: 0),
            BookStore.ChapterMeta(no: 3, title: "第三章", chars: 0),
        ]
        let r = BookSearch.searchTxt(query: "体验", safeName: Self.book, profileId: Self.pid, chapters: chapters)
        XCTAssertEqual(r.hits.filter { $0.chapter == 1 }.count, 1)
        XCTAssertEqual(r.hits.filter { $0.chapter == 3 }.count, 3, "每章最多 3 条")
        XCTAssertTrue(r.hits[0].snippet.contains("设计师创造体验"), "带上下文：\(r.hits[0].snippet)")
        XCTAssertNil(r.coverage)
        XCTAssertTrue(BookSearch.searchTxt(query: "  ", safeName: Self.book, profileId: Self.pid, chapters: chapters).hits.isEmpty)
    }

    func testSnippetsEllipsisAndCaseInsensitive() {
        let long = String(repeating: "前", count: 50) + "Target词" + String(repeating: "后", count: 50)
        let s = BookSearch.snippets(of: "target词", in: long, limit: 2)
        XCTAssertEqual(s.count, 1)
        XCTAssertTrue(s[0].hasPrefix("…") && s[0].hasSuffix("…"), "两端截断加省略号：\(s[0])")
        XCTAssertTrue(s[0].contains("Target词"))
    }

    func testSearchPDFFallbackUsesOCRCacheWithCoverage() throws {
        // 无文本层 PDF：搜 OCR 缓存，报告覆盖页数
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0..<5 { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        let doc = try XCTUnwrap(PDFDocument(data: data as Data))

        // 只给第 2 页缓存
        let url = OCRStore.cacheURL(safeName: Self.book, profileId: Self.pid, page: 2)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"text":"倾听是设计师最重要的技能","bbox":[50,500,300,20]}"#.write(to: url, atomically: true, encoding: .utf8)

        let r = BookSearch.searchPDF(query: "倾听", document: doc, hasTextLayer: false,
                                     safeName: Self.book, profileId: Self.pid, chapters: [])
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(r.hits[0].chapter, 2)
        XCTAssertEqual(r.coverage, "已索引 1/5 页")
    }
}
