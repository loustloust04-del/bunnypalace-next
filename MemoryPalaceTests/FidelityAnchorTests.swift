import XCTest
@testable import 记忆花园

/// CR-7 P3：AI 批注 quote → PDF 页 OCR 行锚定 + 章文本聚合。
final class FidelityAnchorTests: XCTestCase {
    static let pid = "xctest-cr7-p3"
    static let book = "锚定测试书"

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: BookStore.booksRoot(profileId: Self.pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func seedCache(page: Int, lines: [(String, Double)]) {
        // y 传入递减模拟阅读序；缓存文件直接写 jsonl
        let url = OCRStore.cacheURL(safeName: Self.book, profileId: Self.pid, page: page)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = lines.map { text, y in
            #"{"text":"\#(text)","bbox":[50,\#(y),300,20]}"#
        }.joined(separator: "\n")
        try? (body + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testAnchorHitsSingleLine() {
        seedCache(page: 42, lines: [("游戏设计师必须倾听", 500), ("体验才是真正的产物", 470)])
        let hit = AgentBookNoteWriter.fidelityAnchor(
            quote: "体验才是真正的产物", safeName: Self.book, aroundPage: 42, profileId: Self.pid)
        XCTAssertEqual(hit?.page, 42)
        XCTAssertEqual(hit?.rects.count, 1)
        XCTAssertEqual(hit?.rects[0][1], 470)
    }

    func testAnchorSpansTwoLinesAndToleratesWhitespace() {
        seedCache(page: 10, lines: [("设计师创造体验，", 500), ("而非游戏本身。", 470)])
        // AI 引用带空格/换行差异 → 归一化后仍命中，rects 覆盖两行
        let hit = AgentBookNoteWriter.fidelityAnchor(
            quote: "设计师创造体验， 而非游戏本身。", safeName: Self.book, aroundPage: 11, profileId: Self.pid)
        XCTAssertEqual(hit?.page, 10, "窗口 ±1 命中相邻页")
        XCTAssertEqual(hit?.rects.count, 2, "跨行 quote 覆盖两行 bbox")
    }

    func testAnchorAmbiguousOrMissingRejected() {
        seedCache(page: 5, lines: [("重复的句子在这里", 500), ("重复的句子在这里", 470)])
        XCTAssertNil(AgentBookNoteWriter.fidelityAnchor(
            quote: "重复的句子在这里", safeName: Self.book, aroundPage: 5, profileId: Self.pid), "多命中=歧义丢弃")
        XCTAssertNil(AgentBookNoteWriter.fidelityAnchor(
            quote: "书里根本没有这句话", safeName: Self.book, aroundPage: 5, profileId: Self.pid), "零命中丢弃")
    }

    func testChapterTextsAggregationWithPageMarkers() {
        let lines: [Int: [OCRStore.Line]] = [
            1: [OCRStore.Line(text: "封面文字", bbox: [0, 0, 10, 10])],
            2: [OCRStore.Line(text: "第一章开头", bbox: [0, 0, 10, 10])],
            3: [OCRStore.Line(text: "第一章第二页", bbox: [0, 0, 10, 10])],
        ]
        let chapters = [
            BookStore.ChapterMeta(no: 1, title: "封面", chars: 0),
            BookStore.ChapterMeta(no: 2, title: "第一章", chars: 0),
        ]
        let metas = BookOCRIndexer.writeChapterTexts(
            lines: lines, chapters: chapters, pageCount: 3,
            safeName: Self.book, profileId: Self.pid)

        let ch2 = BookStore.loadChapterText(safeName: Self.book, chapterNo: 2, profileId: Self.pid)
        XCTAssertTrue(ch2?.contains("[第 2 页]") == true, "页标记在")
        XCTAssertTrue(ch2?.contains("第一章第二页") == true, "章聚合含后续页")
        XCTAssertFalse(ch2?.contains("封面文字") == true, "不含上一章内容")
        XCTAssertGreaterThan(metas[1].chars, 0, "chars 填真值")
    }

    func testChapterTextsNoOutlineFallsBackToSegments() {
        let lines: [Int: [OCRStore.Line]] = Dictionary(uniqueKeysWithValues: (1...30).map {
            ($0, [OCRStore.Line(text: "第\($0)页", bbox: [0, 0, 10, 10])])
        })
        let metas = BookOCRIndexer.writeChapterTexts(
            lines: lines, chapters: [], pageCount: 30,
            safeName: Self.book, profileId: Self.pid)
        XCTAssertEqual(metas.count, 2, "30 页 → 2 段（25 页/段）")
        XCTAssertEqual(metas[1].no, 26)
        XCTAssertTrue(BookStore.loadChapterText(safeName: Self.book, chapterNo: 26, profileId: Self.pid)?
            .contains("第30页") == true)
    }
}
