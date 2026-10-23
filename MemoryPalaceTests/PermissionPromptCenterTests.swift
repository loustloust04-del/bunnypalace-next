import XCTest
@testable import 记忆花园

/// T6b 查 codex BUG-9（「点了允许却收到超时」）时钉下来的行为锚。
///
/// 这里**不测 30s 超时本身**（测一次要挂 30 秒）；测的是围着它的三条不变量：
/// 挂起中的卡是哪一张、id 不串、答过/超时后的迟到点击必须落空而不是误伤下一张。
@MainActor
final class PermissionPromptCenterTests: XCTestCase {

    /// 不用 `.shared`：单测跑在宿主 app 里，根视图上的 `PermissionPromptHost` 会真的
    /// 把卡弹出来并回调 `markPresented`（探针实证），「还没 present」的前提在 shared 上立不住
    private let center = PermissionPromptCenter(isolatedForTesting: true)

    override func tearDown() async throws {
        // 别把挂起的卡漏给下一条测试
        if let r = center.pendingRequest { center.respond(to: r.id, allowed: false) }
        PermissionPromptCenter.answerTimeout = 30
        PermissionPromptCenter.presentationTimeout = 60
    }

    /// 轮询等 pendingRequest 变成期望状态（await 让出主 actor，让被测的 decide 跑起来）
    private func waitForPending(_ predicate: () -> Bool, _ what: String) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("等不到：\(what)")
    }

    /// 第二张卡**排队**，不覆盖第一张（覆盖会丢掉第一张的 continuation = 工具循环永久挂起）
    func testSecondRequestQueuesInsteadOfClobbering() async {
        let first = Task { await center.decide(.shell, detail: "$ echo a") }
        await waitForPending({ self.center.pendingRequest != nil }, "第一张卡挂起")
        let firstId = center.pendingRequest?.id
        XCTAssertEqual(center.pendingRequest?.detail, "$ echo a")

        let second = Task { await center.decide(.shell, detail: "$ echo b") }
        // 给第二个 decide 跑一会儿：它应该卡在排队循环里，挂起的仍是第一张
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(center.pendingRequest?.id, firstId, "第二张不许覆盖第一张")

        center.respond(to: firstId!, allowed: true)
        let d1 = await first.value
        XCTAssertEqual(d1, .allowed)

        await waitForPending({ self.center.pendingRequest?.detail == "$ echo b" }, "第二张接上")
        center.respond(to: center.pendingRequest!.id, allowed: false)
        let d2 = await second.value
        XCTAssertEqual(d2, .denied, "两张卡的结果不许串")
    }

    /// 迟到的点击（卡已被超时清掉 / 已答过）必须落空——**不能**误伤当时挂着的另一张卡。
    /// 这条是 BUG-9 的安全网：用户点了一张已经结清的卡时，别把下一张一起答了。
    func testStaleRespondDoesNotAffectCurrentCard() async {
        let first = Task { await center.decide(.shell, detail: "$ first") }
        await waitForPending({ self.center.pendingRequest != nil }, "第一张卡挂起")
        let staleId = center.pendingRequest!.id
        center.respond(to: staleId, allowed: true)
        let d1 = await first.value
        XCTAssertEqual(d1, .allowed)

        let second = Task { await center.decide(.fileLibrary) }
        await waitForPending({ self.center.pendingRequest != nil }, "第二张卡挂起")
        let liveId = center.pendingRequest!.id
        XCTAssertNotEqual(liveId, staleId)

        center.respond(to: staleId, allowed: true)          // 迟到点击
        XCTAssertEqual(center.pendingRequest?.id, liveId, "迟到点击不许结清当前这张")

        center.respond(to: liveId, allowed: false)
        let d2 = await second.value
        XCTAssertEqual(d2, .denied)
        XCTAssertNil(center.pendingRequest)
    }
}

// MARK: - T6c ①：计时从卡片真的 present 才起

extension PermissionPromptCenterTests {

    /// **卡没露脸就不该烧作答时间**：作答表 0.2s，但不 `markPresented`——
    /// 等 0.6s（三倍）卡必须还挂着；`markPresented` 之后才开始烧，这时才超时。
    /// 旧逻辑（从 decide 起表）在这条上会在 0.2s 就 timedOut。
    func testAnswerClockDoesNotRunBeforePresented() async {
        PermissionPromptCenter.answerTimeout = 0.2
        PermissionPromptCenter.presentationTimeout = 30   // 兜底表这条测试里别插手

        let task = Task { await center.decide(.shell, detail: "$ 慢慢弹") }
        await waitForPending({ self.center.pendingRequest != nil }, "卡挂起")
        let id = center.pendingRequest!.id

        try? await Task.sleep(nanoseconds: 600_000_000)   // 3× answerTimeout
        XCTAssertEqual(center.pendingRequest?.id, id, "还没 present，作答表不许起跑")

        center.markPresented(id)                          // 卡这会儿才真上屏
        let decision = await task.value
        XCTAssertEqual(decision, .timedOut, "露脸之后才开始烧 0.2s，然后超时")
    }

    /// **兜底**：卡永远 present 不出来（被别的 sheet 挡死 / 宿主没挂上）也要收口，
    /// 不能让工具循环永久挂着
    func testFallsBackToTimeoutWhenNeverPresented() async {
        PermissionPromptCenter.presentationTimeout = 0.3
        PermissionPromptCenter.answerTimeout = 30         // 作答表故意设很长，收口只能来自兜底

        let started = Date()
        let decision = await center.decide(.fileLibrary)
        XCTAssertEqual(decision, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "该由兜底表收口，不是等作答表")
        XCTAssertNil(center.pendingRequest)
    }

    /// 露脸之后正常点允许：兜底表不许回头把它判超时
    func testPresentedThenAllowedIsNotClobberedByFallback() async {
        PermissionPromptCenter.presentationTimeout = 0.3
        PermissionPromptCenter.answerTimeout = 30

        let task = Task { await center.decide(.shell, detail: "$ ok") }
        await waitForPending({ self.center.pendingRequest != nil }, "卡挂起")
        let id = center.pendingRequest!.id
        center.markPresented(id)
        center.respond(to: id, allowed: true)

        let decision = await task.value
        XCTAssertEqual(decision, .allowed)
        try? await Task.sleep(nanoseconds: 500_000_000)   // 熬过兜底表
        XCTAssertNil(center.pendingRequest, "兜底表不许把已结清的卡再动一次")
    }
}
