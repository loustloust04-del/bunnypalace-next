import XCTest
@testable import 记忆花园

/// #050 E10：酒馆 JSONL 解析回归（补 SillyTavernImportTests 没覆盖的格式边角）。样本全是编的。
final class SillyTavernRegressionTests: XCTestCase {

    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private let header: [String: Any] = ["user_name": "unused", "character_name": "unused", "chat_metadata": ["integrity": "x"]]

    private func msg(_ mes: String, user: Bool = false, name: String = "角色", date: Any = "2026-01-01T00:00:00.000Z",
                     extra: [String: Any]? = nil) -> [String: Any] {
        var m: [String: Any] = ["name": name, "is_user": user, "is_system": false, "send_date": date, "mes": mes]
        if let extra { m["extra"] = extra }
        return m
    }

    private func parse(_ text: String, requireHeader: Bool = true) -> SillyTavernParsedChat {
        SillyTavernChatParser.parse(Data(text.utf8), relativePath: "chats/a/a.jsonl", requireHeader: requireHeader)
    }

    func testCRLFBlankLinesBOMAndNoTrailingNewline() {
        let body = [line(header), "", line(msg("你好", user: true, name: "我")), "   ", line(msg("嗨"))].joined(separator: "\r\n")
        let chat = SillyTavernChatParser.parse(Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8), relativePath: "x.jsonl")
        XCTAssertEqual(chat.status, .ok)
        XCTAssertEqual(chat.messages.map(\.mes), ["你好", "嗨"])
        XCTAssertEqual(chat.messages.map(\.line), [3, 5], "行号按物理行算，空行也占号")
        XCTAssertEqual(chat.header?.userName, "unused", "unused 原样留，不当名字用也不丢")
        XCTAssertTrue(chat.badLines.isEmpty)
    }

    func testBadFirstLineDoesNotLoseHeader() {
        let chat = parse(["{oops", line(header), line(msg("嗨"))].joined(separator: "\n"))
        XCTAssertNotNil(chat.header)
        XCTAssertEqual(chat.status, .partial)
        XCTAssertEqual(chat.badLines, [SillyTavernBadLine(line: 1, reason: "JSON 坏了")])
        XCTAssertEqual(chat.messages.map(\.mes), ["嗨"])
    }

    func testTimestampFormats() throws {
        func date(_ v: Any) -> Date? { SillyTavernChatParser.parseDate(v) }
        XCTAssertEqual(date("2024-07-12T01:31:37Z"), Date(timeIntervalSince1970: 1_720_747_897))
        XCTAssertEqual(date("2024-07-12T01:31:37.123Z")?.timeIntervalSince1970 ?? 0, 1_720_747_897.123, accuracy: 0.001)
        XCTAssertEqual(date(NSNumber(value: 1_720_747_897_123.0))?.timeIntervalSince1970 ?? 0, 1_720_747_897.123, accuracy: 0.001)
        XCTAssertEqual(date("1720747897123")?.timeIntervalSince1970 ?? 0, 1_720_747_897.123, accuracy: 0.001, "纯数字字符串按毫秒")
        XCTAssertEqual(date("2024-07-12@01h31m37s123ms")?.timeIntervalSince1970 ?? 0, 1_720_747_897.123, accuracy: 0.001, "按 UTC")
        XCTAssertEqual(date("2024-07-12@01h31m37s"), Date(timeIntervalSince1970: 1_720_747_897))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let local = try XCTUnwrap(date("June 19, 2023 2:20pm"), "小写 pm 也认")
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: local)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2023, 6, 19, 14, 20], "没写时区按设备时区")
        XCTAssertNotNil(date("June 19, 2023 2:20 PM"))
        XCTAssertNil(date("昨天"))
        XCTAssertNil(date(NSNumber(value: true)))
    }

    func testSwipeEdgeValues() {
        var m1 = msg("b")
        m1["swipes"] = ["a", 5, "b"]
        m1["swipe_id"] = 1.5
        m1["swipe_info"] = [["send_date": "x"], NSNull()]
        var m2 = msg("c")
        m2["swipes"] = ["c"]
        let chat = parse([line(header), line(m1), line(m2)].joined(separator: "\n"))
        XCTAssertEqual(chat.messages[0].swipes, ["a", "", "b"], "不是字符串的候选变空串，个数不变")
        XCTAssertNil(chat.messages[0].swipeId, "浮点 swipe_id 当缺")
        XCTAssertEqual(chat.messages[0].swipeInfo.count, 2, "swipe_info 跟 swipes 数量不齐也原样留")
        XCTAssertNil(chat.messages[1].swipeId)

        let built = SwipeBranchBuilder.build(chat, idPrefix: "st-t", title: "t", fallbackDate: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(built.messageCount, 2)
        XCTAssertEqual(built.multiCandidateCount, 1)
    }

    func testGroupChatSpeakersAndToolInvocations() {
        var tool = msg("", name: "系统")
        tool["is_system"] = true
        tool["extra"] = ["tool_invocations": [["id": "t1", "name": "search", "parameters": "{}", "result": "ok"]]]
        let chat = parse([line(msg("我先说", name: "甲")), line(msg("我接着", name: "乙")), line(tool)].joined(separator: "\n"),
                         requireHeader: false)
        XCTAssertEqual(chat.status, .ok)
        XCTAssertNil(chat.header)
        XCTAssertEqual(chat.messages.map(\.name), ["甲", "乙", "系统"])
        XCTAssertEqual(chat.messages[2].visibility, .hidden, "工具调用消息照酒馆规矩是隐藏")
        let extra = String(data: chat.messages[2].extra ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(extra.contains("tool_invocations"), "工具调用原样留在 extra 里")
    }

    func testReasoningKeptInExtra() {
        let chat = parse([line(header), line(msg("答", extra: ["reasoning": "想了想", "reasoning_duration": 3]))].joined(separator: "\n"))
        let extra = String(data: chat.messages[0].extra ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(extra.contains("想了想"))
        XCTAssertEqual(chat.messages[0].mes, "答")
    }
}
