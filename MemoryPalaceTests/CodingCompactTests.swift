#if os(macOS)
import XCTest
@testable import 记忆花园

/// N5-a2：照抄 Wake `services/exporter.rs` 紧凑渲染 5 条单测
final class CodingCompactTests: XCTestCase {
    private func msg(_ seq: Int, _ role: CodingRole, _ kind: CodingMessageKind, _ text: String) -> CodingMessage {
        CodingMessage(seq: seq, role: role, kind: kind, text: text, truncated: false, timestamp: 1_754_042_400_000 + Int64(seq) * 1000)
    }

    private func transcript() -> [CodingMessage] {
        var tool = msg(2, .assistant, .text, "Let me edit the file.")
        tool.toolCalls.append(CodingToolCall(id: "t1", name: "Edit", inputPreview: "src/db.rs", input: #"{"path":"src/db.rs"}"#,
                                             output: "ok, 3 lines changed", isError: false))
        tool.thinking = "私下想一想"
        return [
            msg(0, .user, .text, "帮我实现二维码扫描登录"),
            msg(1, .user, .meta, "<system-reminder>injected</system-reminder>"),
            tool,
            msg(3, .assistant, .text, String(repeating: "很长的回答。", count: 50)),
            msg(4, .system, .compactSummary, "Conversation compacted"),
            msg(5, .user, .text, "继续"),
        ]
    }

    func testDefaultPageSkipsMetaAndKeepsToolNamesOnly() {
        let page = CodingCompact.render(transcript(), CodingCompact.Options())
        XCTAssertEqual(page.rendered, 5)
        XCTAssertEqual(page.skippedMeta, 1)
        XCTAssertNil(page.nextSeq)
        XCTAssertEqual(page.firstSeq, 0)
        XCTAssertEqual(page.lastSeq, 5)
        XCTAssertTrue(page.text.contains("### [seq 0] User"))
        XCTAssertFalse(page.text.contains("injected"))
        XCTAssertTrue(page.text.contains("🔧 Edit: src/db.rs"))
        XCTAssertFalse(page.text.contains("3 lines changed"), "工具输出默认不带")
        XCTAssertFalse(page.text.contains("私下想一想"), "thinking 默认不带")
        XCTAssertTrue(page.text.contains("> [compacted summary] Conversation compacted"))
    }

    func testIncludeFlagsAddToolIOAndThinking() {
        var o = CodingCompact.Options()
        o.includeTools = true
        o.includeThinking = true
        let page = CodingCompact.render(transcript(), o)
        XCTAssertTrue(page.text.contains("3 lines changed"))
        XCTAssertTrue(page.text.contains("[thinking] 私下想一想"))
    }

    func testPaginationByMessagesAndCharsHandsBackNextSeq() {
        var o = CodingCompact.Options()
        o.maxMessages = 2
        var page = CodingCompact.render(transcript(), o)
        XCTAssertEqual(page.rendered, 2)
        XCTAssertEqual(page.nextSeq, 3, "第三条非 Meta 消息的 seq")
        o = CodingCompact.Options()
        o.fromSeq = 3
        o.maxChars = 1
        page = CodingCompact.render(transcript(), o)
        XCTAssertEqual(page.rendered, 1, "字符上限再小也至少给一条")
        XCTAssertEqual(page.firstSeq, 3)
        XCTAssertEqual(page.lastSeq, 3)
        XCTAssertEqual(page.nextSeq, 4)
        o = CodingCompact.Options()
        o.fromSeq = 5
        page = CodingCompact.render(transcript(), o)
        XCTAssertEqual(page.rendered, 1)
        XCTAssertNil(page.nextSeq)
    }

    func testToolCallsShareTheMessageBudget() {
        var m = msg(7, .assistant, .text, "Running the whole suite.")
        for i in 0..<120 {
            let name = String(format: "cargo test --test case_%03d", i)
            m.toolCalls.append(CodingToolCall(id: "t\(i)", name: "Bash", inputPreview: name, input: name,
                                              output: String(repeating: "ok. 12 passed; 0 failed\n", count: 40), isError: false))
        }
        var o = CodingCompact.Options()
        o.maxMessageChars = 400
        o.includeTools = true
        var page = CodingCompact.render([m], o)
        let toolLines = page.text.components(separatedBy: "🔧").count - 1
        XCTAssertTrue(toolLines >= 1 && toolLines < 120, "\(toolLines) tool lines")
        XCTAssertTrue(page.text.contains("more tool calls not shown"), page.text)
        XCTAssertLessThan(page.text.unicodeScalars.count, 400 + 300, "block must stay near the per-message budget")
        // 预算充足时也不超过 maxToolLines 条
        o = CodingCompact.Options()
        o.maxMessageChars = 100_000
        page = CodingCompact.render([m], o)
        XCTAssertEqual(page.text.components(separatedBy: "🔧").count - 1, CodingCompact.maxToolLines)
        XCTAssertTrue(page.text.contains("80 more tool calls not shown"))
    }

    func testLongMessagesAreClippedOnCharBoundaries() {
        var o = CodingCompact.Options()
        o.maxMessageChars = 10
        let page = CodingCompact.render(transcript(), o)
        XCTAssertTrue(page.text.contains("很长的回答。很长的回… [truncated]"))
    }
}
#endif
