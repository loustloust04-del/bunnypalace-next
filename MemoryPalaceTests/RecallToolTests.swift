import XCTest
@testable import 记忆花园

/// RecallTool 纯函数层特征测试（SC-B1）：窗口拼装/居中截断/结果组装/日期解析。
/// SwiftData 检索路径归手测（plan-recall-tool 验证清单）。
final class RecallToolTests: XCTestCase {

    private func msg(_ id: String, _ role: String, _ content: String) -> RecallTool.RecallMessage {
        RecallTool.RecallMessage(id: id, role: role, content: content, date: nil)
    }

    // MARK: - windowText（命中 ±1 邻居窗）

    func testWindowWithBothNeighbors() {
        let path = [msg("a", "user", "昨天的奶茶"), msg("b", "assistant", "乌龙轻乳茶很好喝"), msg("c", "user", "下次还点")]
        let text = RecallTool.windowText(path: path, hitIndex: 1, header: "[H]", query: "乌龙", userName: "禾禾", assistantName: "小岚", snippetLimit: 300)
        XCTAssertTrue(text.hasPrefix("[H]\n"))
        XCTAssertTrue(text.contains("禾禾: 昨天的奶茶"))
        XCTAssertTrue(text.contains("小岚: 乌龙轻乳茶很好喝"))
        XCTAssertTrue(text.contains("禾禾: 下次还点"))
    }

    func testWindowAtPathBoundaries() {
        let path = [msg("a", "user", "第一条"), msg("b", "assistant", "第二条")]
        let head = RecallTool.windowText(path: path, hitIndex: 0, header: "[H]", query: "第一", userName: "u", assistantName: "a", snippetLimit: 300)
        XCTAssertFalse(head.isEmpty)
        XCTAssertEqual(head.components(separatedBy: "\n").count, 3)   // header + 2 行（无上邻居）
        let tail = RecallTool.windowText(path: path, hitIndex: 1, header: "[H]", query: "第二", userName: "u", assistantName: "a", snippetLimit: 300)
        XCTAssertEqual(tail.components(separatedBy: "\n").count, 3)   // header + 2 行（无下邻居）
    }

    func testWindowInvalidIndexAndEmptyContent() {
        XCTAssertEqual(RecallTool.windowText(path: [], hitIndex: 0, header: "[H]", query: "x", userName: "u", assistantName: "a", snippetLimit: 300), "")
        let path = [msg("a", "user", "   "), msg("b", "assistant", "  \n ")]
        XCTAssertEqual(RecallTool.windowText(path: path, hitIndex: 0, header: "[H]", query: "x", userName: "u", assistantName: "a", snippetLimit: 300), "")
    }

    func testNeighborTruncatedHitCentered() {
        let long = String(repeating: "甲", count: 200) + "关键词" + String(repeating: "乙", count: 200)
        let path = [msg("a", "user", long), msg("b", "assistant", long)]
        let text = RecallTool.windowText(path: path, hitIndex: 1, header: "[H]", query: "关键词", userName: "u", assistantName: "a", snippetLimit: 100)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[1].hasPrefix("u: 甲"))               // 邻居前缀截断
        XCTAssertTrue(lines[1].hasSuffix("…"))
        XCTAssertTrue(lines[2].contains("关键词"))               // 命中行居中含关键词
    }

    // MARK: - centeredSnippet

    func testCenteredSnippetShortTextUnchanged() {
        XCTAssertEqual(RecallTool.centeredSnippet("短文本", keyword: "短", limit: 100), "短文本")
    }

    func testCenteredSnippetKeywordLate() {
        let text = String(repeating: "前", count: 500) + "目标词尾部"
        let snippet = RecallTool.centeredSnippet(text, keyword: "目标词", limit: 100)
        XCTAssertTrue(snippet.contains("目标词"))
        XCTAssertTrue(snippet.count <= 102)   // limit + 前后省略号
        XCTAssertTrue(snippet.hasPrefix("…"))
    }

    func testCenteredSnippetKeywordMissingFallsBackToPrefix() {
        let text = String(repeating: "字", count: 500)
        let snippet = RecallTool.centeredSnippet(text, keyword: "不存在", limit: 100)
        XCTAssertEqual(snippet.count, 101)    // 100 + 截断号
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testCenteredSnippetCaseInsensitive() {
        let text = String(repeating: "x", count: 400) + "HELLO world" + String(repeating: "y", count: 400)
        XCTAssertTrue(RecallTool.centeredSnippet(text, keyword: "hello", limit: 50).contains("HELLO"))
    }

    // MARK: - composeResult

    func testComposeEmptyGivesNotFound() {
        let text = RecallTool.composeResult(memoryLines: [], windows: [], totalLimit: 4000)
        XCTAssertTrue(text.contains("没有找到"))
    }

    func testComposeStatsLineAndSections() {
        let text = RecallTool.composeResult(memoryLines: ["- [d] m1"], windows: ["[w1]\nu: hi", "[w2]\na: yo"], totalLimit: 4000)
        XCTAssertTrue(text.hasPrefix("（原文 2 窗 · 记忆 1 条）"))
        XCTAssertTrue(text.contains("【相关记忆】"))
        XCTAssertTrue(text.contains("【对话原文】"))
    }

    func testComposeWindowsOnlyOmitsMemorySection() {
        let text = RecallTool.composeResult(memoryLines: [], windows: ["[w]\nu: hi"], totalLimit: 4000)
        XCTAssertFalse(text.contains("【相关记忆】"))
        XCTAssertTrue(text.contains("（原文 1 窗 · 记忆 0 条）"))
    }

    func testComposeClampsTotalLength() {
        let windows = (0..<10).map { "[w\($0)]\n" + String(repeating: "长", count: 800) }
        let text = RecallTool.composeResult(memoryLines: [], windows: windows, totalLimit: 4000)
        XCTAssertTrue(text.count < 4100)
        XCTAssertTrue(text.hasSuffix("…（结果过长已截断）"))
    }

    // MARK: - parseDay / inRange

    func testParseDayValidAndInvalid() {
        XCTAssertNotNil(RecallTool.parseDay("2026-06-12"))
        XCTAssertNil(RecallTool.parseDay("2026/06/12"))
        XCTAssertNil(RecallTool.parseDay("不是日期"))
        XCTAssertNil(RecallTool.parseDay(""))
        XCTAssertNil(RecallTool.parseDay(nil))
    }

    /// 刀6：before 不含当天（说明文字与代码一致）
    func testBeforeExcludesThatDay() throws {
        let r = try RecallTool.resolveRange(date: nil, after: "2026-09-29", before: "2026-09-30").get()
        let day29 = RecallTool.parseDay("2026-09-29")!
        let day30 = RecallTool.parseDay("2026-09-30")!
        XCTAssertTrue(RecallTool.inRange(day29.addingTimeInterval(23 * 3600), after: r.after, beforeExclusive: r.beforeExclusive))
        XCTAssertFalse(RecallTool.inRange(day30.addingTimeInterval(60), after: r.after, beforeExclusive: r.beforeExclusive), "09-30 的话不在 before=09-30 里")
    }

    func testDateIsSingleDay() throws {
        let r = try RecallTool.resolveRange(date: "2026-09-29", after: nil, before: nil).get()
        let day = RecallTool.parseDay("2026-09-29")!
        XCTAssertEqual(r.after, day)
        XCTAssertTrue(RecallTool.inRange(day.addingTimeInterval(86399), after: r.after, beforeExclusive: r.beforeExclusive))
        XCTAssertFalse(RecallTool.inRange(day.addingTimeInterval(86400), after: r.after, beforeExclusive: r.beforeExclusive))
    }

    func testRangeRejectsBadFormatAndInvertedBounds() {
        if case .success = RecallTool.resolveRange(date: "2026/09/29", after: nil, before: nil) { XCTFail("格式错要报错") }
        if case .success = RecallTool.resolveRange(date: nil, after: "2026-09-30", before: "2026-09-30") { XCTFail("before ≤ after 要报错") }
        if case .failure = RecallTool.resolveRange(date: nil, after: nil, before: nil) { XCTFail("都不给 = 不限") }
    }

    // MARK: - 刀6：按天浏览 / 头行注记

    func testBrowseEntryHeaderAndPickedLines() {
        let base = RecallTool.parseDay("2026-09-29")!.addingTimeInterval(10 * 3600)
        let msgs = (0..<5).map { i in
            RecallTool.RecallMessage(id: "\(i)", role: i % 2 == 0 ? "user" : "assistant",
                                     content: "第\(i)句", date: base.addingTimeInterval(TimeInterval(i * 600)))
        }
        let text = RecallTool.browseEntry(title: "剧场", convId: "abcdefgh1234", messages: msgs,
                                          userName: "禾禾", assistantName: "小克", lineLimit: 120)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "[2026-09-29 · 剧场 conv:abcdefgh] 5 条，10:00–10:40")
        XCTAssertEqual(Array(lines.dropFirst()), ["禾禾: 第0句", "小克: 第1句", "…", "禾禾: 第4句"])
    }

    func testComposeBrowseHeaderWithNotes() {
        let text = RecallTool.composeResult(memoryLines: [], windows: ["[a]", "[b]"], totalLimit: 4000,
                                            notes: ["已排除当前对话"], browse: true)
        XCTAssertTrue(text.hasPrefix("（翻到 2 个对话 · 记忆 0 条 · 已排除当前对话）"), text)
        XCTAssertTrue(text.contains("【那段时间的对话】"))
    }

    func testInRangeBoundsAndNilDate() {
        let after = RecallTool.parseDay("2026-06-01")!
        let before = RecallTool.parseDay("2026-06-10", endOfDay: true)!
        XCTAssertTrue(RecallTool.inRange(after, after: after, beforeExclusive: before))    // 下界含
        XCTAssertFalse(RecallTool.inRange(after.addingTimeInterval(-1), after: after, beforeExclusive: before))
        XCTAssertFalse(RecallTool.inRange(nil, after: nil, beforeExclusive: nil))          // 无时间戳的不进时间过滤结果
    }
}
