import MemoryCore
import XCTest
@testable import 记忆花园

/// plan-wake-heartbeat：聊天工具的时间解析、模型调用口的回合拼接、人话时间
final class WakeAppTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    func testParseScheduleDailyWeeklyOnce() throws {
        guard case .success(.daily(8, 30, nil)) = HeartbeatTaskTool.parseSchedule(["repeat": "daily", "time": "08:30"], tz: tz) else {
            return XCTFail("daily")
        }
        // 人话 1 = 周一 … 7 = 周日 → Calendar 2 … 1
        guard case .success(.daily(9, 0, let days)) = HeartbeatTaskTool.parseSchedule(["repeat": "weekly", "time": "9:00", "weekdays": [1, 5, 7]], tz: tz) else {
            return XCTFail("weekly")
        }
        XCTAssertEqual(days, [1, 2, 6])
        if case .success = HeartbeatTaskTool.parseSchedule(["repeat": "weekly", "time": "09:00", "weekdays": []], tz: tz) { XCTFail("weekly 没有星期几") }
        if case .success = HeartbeatTaskTool.parseSchedule(["repeat": "daily", "time": "25:00"], tz: tz) { XCTFail("25 点") }

        let now = Date(timeIntervalSince1970: 1_794_500_000)
        let f = DateFormatter()
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let tomorrow = f.string(from: now.addingTimeInterval(86400))
        guard case .success(.once(let at)) = HeartbeatTaskTool.parseSchedule(["repeat": "once", "at": tomorrow], tz: tz, now: now) else {
            return XCTFail("once")
        }
        XCTAssertEqual(at.timeIntervalSince(now), 86400, accuracy: 60)
        if case .success = HeartbeatTaskTool.parseSchedule(["repeat": "once", "at": f.string(from: now.addingTimeInterval(-3600))], tz: tz, now: now) {
            XCTFail("过去的时间")
        }
        if case .success = HeartbeatTaskTool.parseSchedule(["repeat": "once", "at": f.string(from: now.addingTimeInterval(40 * 86400))], tz: tz, now: now) {
            XCTFail("超过 30 天")
        }
    }

    func testScheduleText() {
        XCTAssertEqual(WakeText.schedule(.daily(hour: 8, minute: 0, weekdays: nil), tz: tz), "每天 08:00")
        XCTAssertEqual(WakeText.schedule(.daily(hour: 21, minute: 5, weekdays: [1, 2, 6]), tz: tz), "每周一、五、日 21:05")
    }

    /// 第一条 user 进历史；带调用的 assistant + 结果 = 一个 ToolTurn（思考块按第一个调用 id 带回去）；
    /// 之后没调工具的回话 + 提醒挂到前一个 ToolTurn 的 followUps
    func testWireTurns() {
        let turns: [AgentTurn] = [
            .user("醒来做早报"),
            .assistant(text: "先搜", calls: [AgentToolCall(id: "c1", name: "search_web", arguments: #"{"query":"x"}"#)], reasoning: nil),
            .toolResults([AgentToolResult(callId: "c1", content: "结果")]),
            .assistant(text: "我觉得够了", calls: [], reasoning: nil),
            .user("你没调工具。做完了就用 finish 交结果"),
        ]
        let extras = ["c1": AssistantTurnExtras(assistantContent: [["type": "thinking", "thinking": "t", "signature": "s"]], thinkingTokens: 3, reasoning: nil)]
        let (history, toolTurns) = WakeModelCaller.wire(turns, extras: extras)
        XCTAssertEqual(history.map(\.role), ["user"])
        XCTAssertEqual(history.first?.content, "醒来做早报")
        XCTAssertEqual(toolTurns.count, 1)
        XCTAssertEqual(toolTurns[0].calls.map(\.id), ["c1"])
        XCTAssertEqual(toolTurns[0].results.map(\.text), ["结果"])
        XCTAssertEqual(toolTurns[0].text, "先搜")
        XCTAssertEqual(toolTurns[0].assistantContent?.first?["signature"] as? String, "s")
        XCTAssertEqual(toolTurns[0].followUps, [ToolFollowUp(reply: "我觉得够了", note: "你没调工具。做完了就用 finish 交结果")])
    }

    func testRenderSchemaBothFamilies() {
        let spec = AgentToolSpec(name: "finish", description: "交", schema: #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"]}"#)
        let anthropic = WakeModelCaller.render(spec, anthropic: true)
        XCTAssertEqual(anthropic["name"] as? String, "finish")
        XCTAssertEqual((anthropic["input_schema"] as? [String: Any])?["required"] as? [String], ["summary"])
        let openAI = WakeModelCaller.render(spec, anthropic: false)
        XCTAssertEqual((openAI["function"] as? [String: Any])?["name"] as? String, "finish")
    }

    func testBrowserPageSource() {
        #if os(iOS)
        let s = WakeTools.pageSource("点了「登录」。现在这页：OpenAI 博客　https://openai.com/blog")
        XCTAssertEqual(s, WakeSource(url: "https://openai.com/blog", title: "OpenAI 博客"))
        #endif
        XCTAssertEqual(WakeTools.shortURL("https://www.example.com/a"), "example.com/a")
    }
}
