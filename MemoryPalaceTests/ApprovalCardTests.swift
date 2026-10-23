import XCTest
@testable import 记忆花园

/// 审批卡（粟粟 10-03：按推荐——卡在对话底部、只有跑命令能改、卡在眼前不超时）
@MainActor
final class ApprovalCardTests: XCTestCase {

    // MARK: - 决定 → 放行 / 拒绝 / 记不记进对话授权

    func testDecisionOutcomes() {
        let args = #"{"command":"ls"}"#
        XCTAssertEqual(PermissionGate.outcome(.allowed, domain: .shell, originalArgs: args).gate, .proceed(args))
        XCTAssertEqual(PermissionGate.outcome(.allowed, domain: .shell, originalArgs: args).record, true, "本对话都允许：记下")
        XCTAssertEqual(PermissionGate.outcome(.allowedOnce, domain: .shell, originalArgs: args).record, nil, "允许这一次：不记")
        XCTAssertEqual(PermissionGate.outcome(.modified(#"{"command":"ls -a"}"#), domain: .shell, originalArgs: args).gate,
                       .proceed(#"{"command":"ls -a"}"#), "改过的命令照改过的执行")
        guard case .deny(let text) = PermissionGate.outcome(.deniedOnce, domain: .shell, originalArgs: args).gate else { return XCTFail() }
        XCTAssertTrue(text.hasPrefix("permission_denied"))
        XCTAssertEqual(PermissionGate.outcome(.deniedOnce, domain: .shell, originalArgs: args).record, nil, "卡上点拒绝：只拒这一次")
        XCTAssertEqual(PermissionGate.outcome(.denied, domain: .shell, originalArgs: args).record, false, "老弹窗的拒绝照旧记下")
        XCTAssertEqual(PermissionGate.outcome(.timedOut, domain: .shell, originalArgs: args).record, nil)
    }

    func testModifiedCommandIsToldToModel() {
        guard case .deny = PermissionGate.outcome(.modified("not json"), domain: .shell, originalArgs: "{}").gate else {
            return XCTFail("改坏了的参数不执行")
        }
    }

    // MARK: - 卡上显示什么

    func testPreviewForCommand() {
        let p = ApprovalPreview(toolName: "run_command", argumentsJSON: #"{"command":"rm -rf build\nls","cwd":"/tmp"}"#)
        XCTAssertEqual(p.command, "rm -rf build\nls", "完整命令，不截断")
        XCTAssertEqual(p.rows.map(\.label), ["cwd"], "命令单独显示，其余参数列出来")
        XCTAssertTrue(p.canEditCommand)
    }

    func testPreviewForOtherTools() {
        let long = String(repeating: "长", count: 300)
        let p = ApprovalPreview(toolName: "fs_write", argumentsJSON: "{\"path\":\"a.md\",\"content\":\"\(long)\",\"n\":3,\"opts\":{\"x\":1}}")
        XCTAssertNil(p.command)
        XCTAssertFalse(p.canEditCommand, "这次只有跑命令能改")
        XCTAssertEqual(p.rows.map(\.label), ["content", "n", "opts", "path"])
        XCTAssertEqual(p.rows.first { $0.label == "path" }?.value, "a.md")
        XCTAssertEqual(p.rows.first { $0.label == "n" }?.value, "3")
        XCTAssertTrue(p.rows.first { $0.label == "content" }!.value.hasSuffix("…"), "长值截断，完整参数另看")
        XCTAssertEqual(p.rows.first { $0.label == "content" }!.value.count, 161)
    }

    func testReplacingCommand() {
        let json = ApprovalPreview.replacingCommand(in: #"{"command":"ls","cwd":"/tmp"}"#, with: "ls -la")
        let obj = try? JSONSerialization.jsonObject(with: Data((json ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(obj?["command"] as? String, "ls -la")
        XCTAssertEqual(obj?["cwd"] as? String, "/tmp", "别的参数不动")
    }

    // MARK: - 卡在对话里显示（不弹窗、不超时）

    private func center() -> PermissionPromptCenter { PermissionPromptCenter(isolatedForTesting: true) }

    func testInlineWhenConversationVisibleAndNoTimeout() async {
        let c = center()
        let oldAnswer = PermissionPromptCenter.answerTimeout, oldPresent = PermissionPromptCenter.presentationTimeout
        PermissionPromptCenter.answerTimeout = 0.05; PermissionPromptCenter.presentationTimeout = 0.05
        defer { PermissionPromptCenter.answerTimeout = oldAnswer; PermissionPromptCenter.presentationTimeout = oldPresent }
        c.visibleConversationId = "conv"
        let task = Task { await c.decide(.shell, detail: nil, approval: .init(conversationId: "conv", toolName: "run_command", argumentsJSON: "{}", conversationGrant: true)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.pendingRequest?.inline, true)
        c.markPresentedInline(c.pendingRequest!.id)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(c.pendingRequest, "卡在眼前：不超时")
        c.respond(to: c.pendingRequest!.id, decision: .allowedOnce)
        let decision = await task.value
        XCTAssertEqual(decision, .allowedOnce)
    }

    func testNotVisibleFallsBackToSheet() async {
        let c = center()
        c.visibleConversationId = "other"
        let task = Task { await c.decide(.shell, detail: nil, approval: .init(conversationId: "conv", toolName: "run_command", argumentsJSON: "{}", conversationGrant: true)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.pendingRequest?.inline, false, "不在这个对话：照旧弹窗")
        c.respond(to: c.pendingRequest!.id, allowed: false)
        _ = await task.value
    }

    func testLeavingConversationTurnsInlineIntoSheet() async {
        let c = center()
        c.visibleConversationId = "conv"
        let task = Task { await c.decide(.shell, detail: nil, approval: .init(conversationId: "conv", toolName: "x", argumentsJSON: "{}", conversationGrant: true)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.pendingRequest?.inline, true)
        c.visibleConversationId = nil
        XCTAssertEqual(c.pendingRequest?.inline, false, "离开对话：改成弹窗，不让工具挂死")
        c.respond(to: c.pendingRequest!.id, allowed: false)
        _ = await task.value
    }

    func testStopCancelsPendingAsDenyOnce() async {
        let c = center()
        c.visibleConversationId = "conv"
        let task = Task { await c.decide(.shell, detail: nil, approval: .init(conversationId: "conv", toolName: "x", argumentsJSON: "{}", conversationGrant: true)) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        c.cancel(conversationId: "conv")
        let decision = await task.value
        XCTAssertEqual(decision, .deniedOnce, "停止 / 切楼层：算拒绝这一次")
        XCTAssertNil(c.pendingRequest)
    }
}
