import XCTest
@testable import 记忆花园

/// 进度卡（粟粟 10-03「都按推荐」）：只显示工具循环里真实发生的事
final class TurnActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testRunningToolHeadlineWithElapsedSeconds() {
        var a = TurnActivity(maxRounds: 8)
        a.startRound(2)
        a.observe(.toolUse(id: "c1", name: "search_web", inputJSON: "{}", integrationName: "联网搜索", iconName: "globe"), at: t0)
        XCTAssertEqual(a.running?.label, "联网搜索")
        XCTAssertEqual(a.running?.icon, "globe")
        XCTAssertEqual(a.headline(now: t0.addingTimeInterval(12)), "第 2/8 轮 · 正在用 联网搜索（12 秒）")
    }

    func testFinishedStepsKeepOkAndError() {
        var a = TurnActivity(maxRounds: 8)
        a.startRound(1)
        a.observe(.toolUse(id: "c1", name: "fs_read", inputJSON: "{}", integrationName: nil, iconName: nil), at: t0)
        a.observe(.toolResult(toolUseId: "c1", text: "ok", isError: false, integrationName: nil), at: t0)
        a.observe(.toolUse(id: "c2", name: "browse_url", inputJSON: "{}", integrationName: "网页阅读", iconName: "doc.text.magnifyingglass"), at: t0)
        a.observe(.toolResult(toolUseId: "c2", text: "404", isError: true, integrationName: "网页阅读"), at: t0)
        XCTAssertNil(a.running)
        XCTAssertEqual(a.steps.map(\.label), ["文件库", "网页阅读"], "fs_* 没有 integration 名，显示成文件库")
        XCTAssertEqual(a.steps.map(\.ok), [true, false])
        XCTAssertEqual(a.headline(now: t0), "第 1/8 轮 · 在想下一步")
    }

    func testDuplicateToolUseAndUnrelatedSegmentsIgnored() {
        var a = TurnActivity(maxRounds: 8)
        a.startRound(1)
        let use = MessageSegment.toolUse(id: "c1", name: "recall", inputJSON: "{}", integrationName: "回忆", iconName: "clock.arrow.circlepath")
        a.observe(use, at: t0)
        a.observe(use, at: t0.addingTimeInterval(5))   // 偏移回写 / 重放不重复记
        a.observe(.text("顺便说一句"), at: t0)
        a.observe(.toolResult(toolUseId: "nope", text: "", isError: false, integrationName: nil), at: t0)
        XCTAssertEqual(a.steps.count, 1)
        XCTAssertEqual(a.running?.startedAt, t0)
    }

    func testRefusedCallsShowToolNotReason() {
        var a = TurnActivity(maxRounds: 8)
        a.startRound(1)
        a.observe(.toolUse(id: "c1", name: "run_command", inputJSON: "{}", integrationName: "权限", iconName: "lock"), at: t0)
        a.observe(.toolResult(toolUseId: "c1", text: "拒绝", isError: true, integrationName: "权限"), at: t0)
        XCTAssertEqual(a.steps.first?.label, "run_command")
        XCTAssertEqual(a.steps.first?.ok, false)
    }

    func testBlockedReasonsWin() {
        var a = TurnActivity(maxRounds: 8)
        a.startRound(3)
        XCTAssertEqual(a.headline(now: t0, blocked: .approval("运行命令")), "第 3/8 轮 · 等你批准：运行命令")
        XCTAssertEqual(a.headline(now: t0, blocked: .question), "第 3/8 轮 · 等你回答")
    }

    func testElapsedFormatting() {
        XCTAssertEqual(TurnActivity.elapsed(59), "59 秒")
        XCTAssertEqual(TurnActivity.elapsed(61), "1 分 1 秒")
        XCTAssertEqual(TurnActivity.elapsed(-3), "0 秒")
    }

    func testRoundIsClampedToMax() {
        var a = TurnActivity(maxRounds: 8)
        a.startRound(9)
        XCTAssertEqual(a.round, 8)
    }
}
