import XCTest
@testable import 记忆花园

/// 进度卡（粟粟 10-03「都按推荐」）：只显示工具循环里真实发生的事
final class TurnActivityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

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

    func testRoundIsClampedToMax() {
        var a = TurnActivity(maxRounds: 8)
        a.startRound(9)
        XCTAssertEqual(a.round, 8)
    }
}
