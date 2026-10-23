#if DEBUG || PERF_BENCH
import XCTest
import CoreGraphics
@testable import 记忆花园

/// P0 测量纯计量核心（docs/plan-chat-list-perf-p0.md 纵切 2）
final class PerfChatCoreTests: XCTestCase {
    typealias C = PerfChatCore

    // MARK: M1 显示钉死键

    func testDisplayPinsTableAndDataDigest() {
        XCTAssertEqual(C.pinnedKeys.first?.key, "chatBubbleMode")
        XCTAssertEqual(Set(C.pinnedKeys.map(\.key)).count, C.pinnedKeys.count, "键不重复")
        XCTAssertEqual(C.pinnedKeys.count, 15, "模式键 + 12 个显示设置 + 主题定义 / 深浅色")
        XCTAssertEqual(C.dataPin(Data("a".utf8)), "fnv:af63dc4c8601ec8c", "FNV-1a 64 标准向量，与 chatv1.py fnv1a64_hex 同算法")
    }

    // MARK: 2.1 挂载接纳 / 迟到 / 换代

    func testMountAcceptedOnceAfterApplyThenLocked() {
        var m = C.MountAcceptance(baseGen: 4)
        XCTAssertEqual(m.noteMount(gen: 5), .beforeApply)
        XCTAssertTrue(m.holds(currentGen: 5))
        m.noteApply()
        XCTAssertTrue(m.holds(currentGen: 5), "apply 后无新挂载：不限")
        XCTAssertEqual(m.noteMount(gen: 6), .accepted)
        XCTAssertEqual(m.lockedGen, 6)
        XCTAssertTrue(m.holds(currentGen: 6))
        XCTAssertFalse(m.holds(currentGen: 5))
        XCTAssertEqual(m.noteMount(gen: 7), .extraRemount)
        XCTAssertEqual(m.lockedGen, 6, "锁定后不再换")
        m.noteReady()
        XCTAssertEqual(m.noteMount(gen: 8), .afterReady)
    }

    func testMountNoRemountIsFine() {
        var m = C.MountAcceptance(baseGen: 2)
        m.noteApply()
        m.noteReady()
        XCTAssertNil(m.lockedGen)
        XCTAssertTrue(m.holds(currentGen: 2))
    }

    func testLateClassification() {
        XCTAssertEqual(C.classifyLate(eventReq: 3, currentReq: 3, afterCurrentApply: true, changedRows: true, changedCurrentNode: true), .current)
        XCTAssertEqual(C.classifyLate(eventReq: 2, currentReq: 3, afterCurrentApply: false, changedRows: true, changedCurrentNode: true), .isolatedLate,
                       "当前 apply 之前的旧 apply 会被覆盖，只算已隔离")
        XCTAssertEqual(C.classifyLate(eventReq: 2, currentReq: 3, afterCurrentApply: true, changedRows: false, changedCurrentNode: false), .isolatedLate)
        XCTAssertEqual(C.classifyLate(eventReq: 1, currentReq: 3, afterCurrentApply: true, changedRows: true, changedCurrentNode: false), .lateOverwrite)
        XCTAssertEqual(C.classifyLate(eventReq: 1, currentReq: 3, afterCurrentApply: true, changedRows: false, changedCurrentNode: true), .lateOverwrite)
    }

    func testSupersededIgnoresMountAndNilProbe() {
        let target = (profile: "bench", conversation: "A")
        XCTAssertFalse(C.isSuperseded(target: target, probe: ("bench", "B"), applied: false, newerSameKindIssued: false),
                       "apply 前 Probe 还挂着上一个对话")
        XCTAssertFalse(C.isSuperseded(target: target, probe: (nil, nil), applied: true, newerSameKindIssued: false))
        XCTAssertFalse(C.isSuperseded(target: target, probe: ("bench", "A"), applied: true, newerSameKindIssued: false))
        XCTAssertTrue(C.isSuperseded(target: target, probe: ("bench", "B"), applied: true, newerSameKindIssued: false))
        XCTAssertTrue(C.isSuperseded(target: target, probe: ("other", "A"), applied: true, newerSameKindIssued: false))
        XCTAssertTrue(C.isSuperseded(target: target, probe: ("bench", "A"), applied: false, newerSameKindIssued: true))
    }

    // MARK: 2.1 状态机 / 截止

    func testLoadCompletesInOrder() {
        var t = C.OpTracker(spec: .load(flip: false), reqId: 1, t0: 10)
        XCTAssertEqual(t.evaluate(now: 10.1), .pending)
        t.record(.applyEnd, at: 10.2)
        t.record(.structuralReady, at: 10.5)
        XCTAssertEqual(t.evaluate(now: 10.6), .pending)
        t.record(.confirmed, at: 11.0)
        XCTAssertEqual(t.evaluate(now: 11.0), .complete)
    }

    func testLoadMissingEndpointIsInstrument() {
        var t = C.OpTracker(spec: .load(flip: false), reqId: 1, t0: 0)
        t.record(.structuralReady, at: 0.5)
        t.record(.confirmed, at: 1)
        XCTAssertEqual(t.evaluate(now: 1), .failed(C.Failure(.missingEndpoint, "apply.end")))
        XCTAssertEqual(C.FailureKind.missingEndpoint.failureClass, .instrument)
    }

    func testLoadTimeoutIsProductSlowNotZeroFilled() {
        var t = C.OpTracker(spec: .load(flip: false), reqId: 1, t0: 0)
        t.record(.applyEnd, at: 0.3)
        XCTAssertEqual(t.evaluate(now: 14.9), .pending)
        XCTAssertEqual(t.evaluate(now: 15.1), .failed(C.Failure(.readyTimeout, "confirmed")))
        XCTAssertEqual(C.FailureKind.readyTimeout.failureClass, .productSlow)
        t.record(.structuralReady, at: 15.5)
        t.record(.confirmed, at: 16)
        XCTAssertEqual(t.evaluate(now: 16), .failed(C.Failure(.readyTimeout, "confirmed")), "晚到的 confirmed 仍是超时")
    }

    func testFlipApplyOrderFreeButFlipBeforeReady() {
        var t = C.OpTracker(spec: .load(flip: true), reqId: 1, t0: 0)
        t.record(.flipBegin, at: 0.01)
        t.record(.applyEnd, at: 0.1)
        t.record(.flipEnd, at: 0.3)
        t.record(.structuralReady, at: 0.4)
        t.record(.confirmed, at: 0.9)
        XCTAssertEqual(t.evaluate(now: 1), .complete, "apply 落在翻页动画中途是正常路径")
        t.record(.flipEnd, at: 0.45)
        XCTAssertEqual(t.evaluate(now: 1), .failed(C.Failure(.nonMonotonic, "flip.end > structuralReady")))
    }

    func testTraversePhaseDeadlines() {
        var t = C.OpTracker(spec: .traverse(), reqId: 2, t0: 0)
        t.record(.coldUpEnd, at: 50)
        XCTAssertEqual(t.evaluate(now: 100), .pending, "回程从 coldUp 结束另计 60s")
        XCTAssertEqual(t.evaluate(now: 111), .failed(C.Failure(.traversalTimeCap, "returnDown.end")))
        var u = C.OpTracker(spec: .traverse(), reqId: 3, t0: 0)
        XCTAssertEqual(u.evaluate(now: 61), .failed(C.Failure(.traversalTimeCap, "coldUp.end")))
        u.record(.returnDownEnd, at: 70)
        XCTAssertEqual(u.evaluate(now: 71), .failed(C.Failure(.missingEndpoint, "coldUp.end")), "后继已到而前驱没登记：仪器优先")
    }

    func testTurnEndpointsAndDeadline() {
        var t = C.OpTracker(spec: .turn(scriptDuration: 5), reqId: 4, t0: 0)
        t.record(.firstProgress, at: 0.2)
        t.record(.userJump, at: 0.3)
        t.record(.providerComplete, at: 5.1)
        t.record(.finishJump, at: 5.3)
        t.record(.staticConsumed, at: 5.4)
        XCTAssertEqual(t.evaluate(now: 6), .pending)
        t.record(.confirmed, at: 6)
        XCTAssertEqual(t.evaluate(now: 6), .complete, "userJump 与 firstProgress 先后不限")
        var swapped = C.OpTracker(spec: .turn(scriptDuration: 5), reqId: 6, t0: 0)
        for (e, at) in [(C.Endpoint.firstProgress, 0.2), (.userJump, 0.3), (.providerComplete, 5.1), (.staticConsumed, 5.2), (.finishJump, 5.3), (.confirmed, 6)] {
            swapped.record(e, at: at)
        }
        XCTAssertEqual(swapped.evaluate(now: 6), .complete, "finishJump 与 static.consumed 同一事务，先后不限（mask 实测）")
        swapped.record(.staticConsumed, at: 5.0)
        XCTAssertEqual(swapped.evaluate(now: 6), .failed(C.Failure(.nonMonotonic, "provider.complete > static.consumed")))
        var slow = C.OpTracker(spec: .turn(scriptDuration: 5), reqId: 5, t0: 0)
        slow.record(.userJump, at: 0.1)
        XCTAssertEqual(slow.evaluate(now: 15.01), .failed(C.Failure(.turnTimeout, "confirmed")))
    }

    // MARK: 2.2 窗口 / busy

    private func seg(_ a: Double, _ b: Double) -> C.Interval { C.Interval(start: a, end: b) }

    func testWindowsSumEqualsTotalBusy() {
        let w = C.LoadWindows(t0: 0, applyEnd: 0.2, structuralReady: 0.6, confirmed: 1.1)
        let segs = [seg(-0.5, 0.05), seg(0.15, 0.25), seg(0.55, 0.7), seg(1.0, 1.2), seg(2.5, 3.0), seg(3.0, 3.5)]
        let b = C.loadBusy(segments: segs, windows: w)
        XCTAssertEqual(b.windows["toApply"]!, 0.10, accuracy: 1e-9)
        XCTAssertEqual(b.windows["toReady"]!, 0.10, accuracy: 1e-9)
        XCTAssertEqual(b.windows["settle"]!, 0.20, accuracy: 1e-9)
        XCTAssertEqual(b.windows["tail"]!, 0.10 + 0.10, accuracy: 1e-9, "尾窗 [1.1, 2.6)")
        XCTAssertEqual(b.total, b.windows.values.reduce(0, +), accuracy: 1e-12)
        XCTAssertTrue(b.sumHolds)
        XCTAssertEqual(b.fixed1s, 0.05 + 0.10 + 0.15 + 0.0, accuracy: 1e-9)
        XCTAssertEqual(b.toStructural, 0.05 + 0.10 + 0.05, accuracy: 1e-9)
        XCTAssertEqual(b.toConfirmed, 0.05 + 0.10 + 0.15 + 0.10, accuracy: 1e-9)
    }

    func testNonMonotonicWindowsFailSumCheck() {
        let w = C.LoadWindows(t0: 0, applyEnd: 0.8, structuralReady: 0.3, confirmed: 1.0)
        XCTAssertFalse(C.loadBusy(segments: [seg(0, 2)], windows: w).sumHolds)
    }

    func testTaskOverlapNotAdded() {
        let w = C.LoadWindows(t0: 0, applyEnd: 0.2, structuralReady: 0.6, confirmed: 1.0)
        let segs = [seg(0.1, 0.3), seg(0.5, 0.65)]
        let r = C.taskBusy(seg(0.15, 0.62), segments: segs, windows: w)
        XCTAssertEqual(r.busy, 0.15 + 0.12, accuracy: 1e-9)
        XCTAssertEqual(r.overlap["toApply"]!, 0.05, accuracy: 1e-9)
        XCTAssertEqual(r.overlap["toReady"]!, 0.10 + 0.10, accuracy: 1e-9)
        XCTAssertEqual(r.overlap["settle"]!, 0.02, accuracy: 1e-9)
        XCTAssertEqual(r.overlap["tail"]!, 0, accuracy: 1e-12)
    }

    // MARK: 2.3 帧

    private func steady(hz: Double, from: Double, to: Double) -> [C.FrameSample] {
        let p = 1 / hz
        return stride(from: from, through: to, by: p).map { C.FrameSample(arrival: $0 + 0.002, timestamp: $0, targetTimestamp: $0 + p) }
    }

    func testSteady60And120HzHaveNoExcess() throws {
        for hz in [60.0, 120.0] {
            let g = try C.frameGaps(steady(hz: hz, from: 0, to: 2), from: 0, to: 1).get()
            XCTAssertEqual(g.callbackGapExcess, 0, accuracy: 1e-6, "\(hz)Hz")
            XCTAssertEqual(g.worstGapMs, 1000 / hz, accuracy: 1e-6)
            XCTAssertEqual(g.firstCallbackDelayMs!, 2, accuracy: 1e-6)
        }
    }

    func testDroppedFrameExcessAt60Hz() throws {
        let p = 1.0 / 60
        var s = steady(hz: 60, from: 0, to: 1)
        s.removeAll { abs($0.timestamp - 30 * p) < 1e-9 }
        let g = try C.frameGaps(s, from: 0, to: 1).get()
        XCTAssertEqual(g.callbackGapExcess, p * 1000, accuracy: 1e-6)
        XCTAssertEqual(g.worstGapMs, 2 * p * 1000, accuracy: 1e-6)
    }

    func testVariableRefreshUsesAnnouncedDuration() throws {
        var s: [C.FrameSample] = []
        var t = 0.0
        for i in 0..<60 {
            let p = i < 30 ? 1.0 / 120 : 1.0 / 60
            s.append(C.FrameSample(arrival: t, timestamp: t, targetTimestamp: t + p))
            t += p
        }
        let g = try C.frameGaps(s, from: 0, to: t).get()
        XCTAssertEqual(g.callbackGapExcess, 0, accuracy: 1e-6, "120→60 降频按宣告值不算超额")
        s[45] = C.FrameSample(arrival: s[45].arrival, timestamp: s[45].timestamp, targetTimestamp: s[45].timestamp + 1.0 / 120)
        let h = try C.frameGaps(s, from: 0, to: t).get()
        XCTAssertEqual(h.callbackGapExcess, 1000 * (1.0 / 60 - 1.0 / 120) / t, accuracy: 1e-6, "宣告 120 却隔了 60 的一帧")
    }

    func testFirstCallbackAndUnclosedTail() throws {
        let p = 1.0 / 60
        let s = [C.FrameSample(arrival: 0.05, timestamp: 0.05, targetTimestamp: 0.05 + p),
                 C.FrameSample(arrival: 0.05 + p, timestamp: 0.05 + p, targetTimestamp: 0.05 + 2 * p)]
        let g = try C.frameGaps(s, from: 0, to: 0.2).get()
        XCTAssertEqual(g.firstCallbackDelayMs!, 50, accuracy: 1e-6)
        let tail = 0.2 - (0.05 + p)
        XCTAssertEqual(g.worstGapMs, tail * 1000, accuracy: 1e-6)
        XCTAssertEqual(g.callbackGapExcess, 1000 * ((0.05 - p) + (tail - p)) / 0.2, accuracy: 1e-6,
                       "R5 C-05：无前样本时首段从窗口起点按首回调宣告周期计入；尾间隔计入")
        XCTAssertNil(try C.frameGaps([], from: 0, to: 1).get().firstCallbackDelayMs)
    }

    func testFrameClockRollbackIsInstrumentFailure() {
        let p = 1.0 / 60
        var s = steady(hz: 60, from: 0, to: 1)
        s[20] = C.FrameSample(arrival: s[20].arrival, timestamp: s[18].timestamp, targetTimestamp: s[18].targetTimestamp)
        XCTAssertEqual(C.frameGaps(s, from: 0, to: 1), .failure(C.Failure(.nonMonotonic, "frame[20] timestamp rollback")))

        var a = steady(hz: 60, from: 0, to: 1)
        a[10] = C.FrameSample(arrival: a[8].arrival, timestamp: a[10].timestamp, targetTimestamp: a[10].targetTimestamp)
        XCTAssertEqual(C.frameGaps(a, from: 0, to: 1), .failure(C.Failure(.nonMonotonic, "frame[10] arrival rollback")))

        let late = [C.FrameSample(arrival: 0.5, timestamp: 0.9, targetTimestamp: 0.9 + p)]
        XCTAssertEqual(C.frameGaps(late, from: 0, to: 0.6), .failure(C.Failure(.nonMonotonic, "frame[0] timestamp > window end")),
                       "尾间隔不能从窗口末之后的时间戳起算")

        let badTarget = [C.FrameSample(arrival: 0.1, timestamp: 0.1, targetTimestamp: 0.09)]
        XCTAssertEqual(C.frameGaps(badTarget, from: 0, to: 1), .failure(C.Failure(.nonMonotonic, "frame[0] target <= timestamp")))

        XCTAssertEqual(C.frameGaps(steady(hz: 60, from: 0, to: 1), from: 1, to: 0), .failure(C.Failure(.nonMonotonic, "frame window end < start")))
        XCTAssertEqual(C.FailureKind.nonMonotonic.failureClass, .instrument)
    }

    // MARK: 2.4 有效视口成链 / 锚点

    private let scale: CGFloat = 3
    private let spacing: CGFloat = 12

    /// sv 在 window 中 (0,0,390,844)；旧页遮挡带 底 100 顶 150 → 有效视口 y ∈ [150, 744]
    private var viewport: CGRect? {
        C.effectiveViewport(CGRect(x: 0, y: 0, width: 390, height: 844), occlusion: C.Occlusion(bottom: 100, top: 150, keyboardPad: 0))
    }

    /// 从 bottom 往上按行高堆叠，行间距 gap
    private func stack(_ ids: [String], bottom: CGFloat, height: CGFloat, gap: CGFloat) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        var y = bottom
        for id in ids.reversed() {
            out[id] = CGRect(x: 0, y: y - height, width: 390, height: height)
            y -= height + gap
        }
        return out
    }

    func testEffectiveViewportSubtractsBandsAndKeyboard() {
        XCTAssertEqual(viewport, CGRect(x: 0, y: 150, width: 390, height: 594))
        let kb = C.effectiveViewport(CGRect(x: 0, y: 0, width: 390, height: 844), occlusion: C.Occlusion(bottom: 100, top: 150, keyboardPad: 300))
        XCTAssertEqual(kb?.maxY, 444)
        XCTAssertNil(C.effectiveViewport(CGRect(x: 0, y: 0, width: 390, height: 200), occlusion: C.Occlusion(bottom: 100, top: 150, keyboardPad: 0)))
    }

    func testChainCompleteWithDeclaredSpacing() {
        let ids = (0..<20).map { "n\($0)" }
        let rects = stack(ids, bottom: 744, height: 80, gap: spacing)
        guard case .complete(let chain) = C.messageChain(expected: ids, rects: rects, viewport: viewport, spacing: spacing, scale: scale) else {
            return XCTFail("应成链")
        }
        XCTAssertEqual(chain.first, "n19")
        XCTAssertEqual(chain.count, 7, "594 高视口，每行 92：第 7 行顶越过视口顶即停")
    }

    func testChainGapToleranceIsOnePhysicalPixel() {
        let ids = (0..<10).map { "n\($0)" }
        let ok = stack(ids, bottom: 744, height: 80, gap: spacing + 1 / scale)
        XCTAssertEqual(C.messageChain(expected: ids, rects: ok, viewport: viewport, spacing: spacing, scale: scale),
                       .complete(Array(ids.reversed().prefix(7))))
        let bad = stack(ids, bottom: 744, height: 80, gap: spacing + 2 / scale)
        guard case .gap(let id, _) = C.messageChain(expected: ids, rects: bad, viewport: viewport, spacing: spacing, scale: scale) else {
            return XCTFail("超 1 物理像素应断链")
        }
        XCTAssertEqual(id, "n8")
    }

    func testChainMissingRowOverlapAndBottom() {
        let ids = (0..<10).map { "n\($0)" }
        var rects = stack(ids, bottom: 744, height: 80, gap: spacing)
        rects["n7"] = nil
        XCTAssertEqual(C.messageChain(expected: ids, rects: rects, viewport: viewport, spacing: spacing, scale: scale), .missingRow("n7"))

        let overlap = stack(ids, bottom: 744, height: 80, gap: -1)
        guard case .gap("n8", _) = C.messageChain(expected: ids, rects: overlap, viewport: viewport, spacing: spacing, scale: scale) else {
            return XCTFail("重叠应断链")
        }

        let floating = stack(ids, bottom: 700, height: 80, gap: spacing)
        guard case .gap("n9", _) = C.messageChain(expected: ids, rects: floating, viewport: viewport, spacing: spacing, scale: scale) else {
            return XCTFail("最新行离视口底太远应断链")
        }

        let underBand = stack(ids, bottom: 790, height: 80, gap: spacing)
        guard case .complete = C.messageChain(expected: ids, rects: underBand, viewport: viewport, spacing: spacing, scale: scale) else {
            return XCTFail("最新行一截压在遮挡带下仍可成链")
        }

        let hidden = stack(ids, bottom: 900, height: 80, gap: spacing)
        guard case .gap("n9", _) = C.messageChain(expected: ids, rects: hidden, viewport: viewport, spacing: spacing, scale: scale) else {
            return XCTFail("最新行完全在视口外不算视觉底")
        }
        XCTAssertEqual(C.messageChain(expected: ids, rects: rects, viewport: nil, spacing: spacing, scale: scale), .noViewport)
    }

    func testChainShortConversationReachesOldest() {
        let ids = ["a", "b", "c"]
        let rects = stack(ids, bottom: 744, height: 60, gap: spacing)
        XCTAssertEqual(C.messageChain(expected: ids, rects: rects, viewport: viewport, spacing: spacing, scale: scale), .complete(["c", "b", "a"]))
    }

    func testChainIndependentOfOcclusionDeclaredZero() {
        let ids = (0..<20).map { "n\($0)" }
        let full = C.effectiveViewport(CGRect(x: 0, y: 0, width: 390, height: 844), occlusion: C.Occlusion(bottom: 0, top: 0, keyboardPad: 0))
        let rects = stack(ids, bottom: 844, height: 80, gap: spacing)
        guard case .complete = C.messageChain(expected: ids, rects: rects, viewport: full, spacing: spacing, scale: scale) else {
            return XCTFail("遮挡带声明为 0 仍可就绪")
        }
    }

    private func rows(_ spec: [(String, CGFloat, CGFloat)]) -> [C.ChainRow] { spec.map { C.ChainRow(id: $0.0, minY: $0.1, maxY: $0.2) } }

    func testChainStabilityOnePixelThreeSamplesBackdated() {
        var a = C.ChainStability(scale: 3)
        let base = rows([("n9", 664, 744), ("n8", 572, 652)])
        XCTAssertNil(a.feed(base, at: 1.0))
        XCTAssertNil(a.feed(rows([("n9", 664, 744 + 1.0 / 3), ("n8", 572, 652)]), at: 1.1))
        XCTAssertEqual(a.feed(base, at: 1.2), 1.0, "连续 3 样本、相邻变化 ≤ 1 物理像素：稳定起点回溯到第 1 个样本")
        XCTAssertEqual(a.feed(base, at: 1.3), 1.0, "连串延续，起点不变")
        XCTAssertNil(a.feed(rows([("n9", 664, 745), ("n8", 572, 652)]), at: 1.4), "超 1 物理像素重开")
        XCTAssertNil(a.feed(rows([("n9", 664, 745), ("n8", 572, 652)]), at: 1.5))
        XCTAssertEqual(a.feed(rows([("n9", 664, 745), ("n8", 572, 652)]), at: 1.6), 1.4)
        a.reset()
        XCTAssertNil(a.feed(base, at: 2.0), "reset 后从头数")
    }

    func testChainStabilitySeesUpperRowGrowthInReversedList() {
        // 反转列表：底行 maxY 被钉住，上面一行在长高（minY 往上走）——旧的「只看底行 maxY」会判稳
        var a = C.ChainStability(scale: 3)
        XCTAssertNil(a.feed(rows([("n9", 664, 744), ("n8", 540, 652)]), at: 0))
        XCTAssertNil(a.feed(rows([("n9", 664, 744), ("n8", 500, 652)]), at: 0.016))
        XCTAssertNil(a.feed(rows([("n9", 664, 744), ("n8", 460, 652)]), at: 0.033), "链内有行在长高 = 不稳")
        XCTAssertNil(a.feed(rows([("n9", 664, 744), ("n7", 460, 652)]), at: 0.05), "id 序列变了 = 重开")
        var b = C.ChainStability(scale: 2)
        _ = b.feed(rows([("x", 0, 10)]), at: 0)
        _ = b.feed(rows([("x", 0, 10.6)]), at: 1)
        XCTAssertNil(b.feed(rows([("x", 0, 10.6)]), at: 2), "@2x 容差 0.5pt")
        var empty = C.ChainStability(scale: 3)
        XCTAssertNil(empty.feed([], at: 0))
    }

    func testReadyStreakBackdatesAndRestartsAfterBlock() {
        var s = C.ReadyStreak()
        XCTAssertFalse(s.tick(now: 1.00, holds: true, stableSince: nil, blockSinceLastTick: false))
        XCTAssertNil(s.condAt)
        XCTAssertTrue(s.tick(now: 1.03, holds: true, stableSince: 0.99, blockSinceLastTick: false))
        XCTAssertEqual(s.condAt, 1.00, "condAt = max(条件起点 1.00, 稳定起点 0.99)")
        XCTAssertFalse(s.tick(now: 1.05, holds: true, stableSince: 0.99, blockSinceLastTick: false))
        XCTAssertEqual(s.condAt, 1.00)
        // K-02：两次回调之间夹了 >50ms 块 → 块后首个回调重开
        XCTAssertTrue(s.tick(now: 1.20, holds: true, stableSince: 0.99, blockSinceLastTick: true))
        XCTAssertEqual(s.condAt, 1.20, "structuralReady 推到块后首个回调")
        XCTAssertEqual(s.firstStructural, 1.00)
        XCTAssertEqual(s.reopenCount, 1)
        XCTAssertFalse(s.tick(now: 1.22, holds: false, stableSince: 0.99, blockSinceLastTick: false))
        XCTAssertNil(s.condAt)
        XCTAssertTrue(s.tick(now: 1.24, holds: true, stableSince: 1.18, blockSinceLastTick: false))
        XCTAssertEqual(s.condAt, 1.24, "条件断过：起点取重新成立那一刻，不回溯到断之前的稳定起点")
        XCTAssertEqual(s.reopenCount, 2)
    }

    func testMarkdownPendingPairsByDigestAndDims() {
        func r(_ d: UInt64, _ dims: String, _ k: String, _ t: Double) -> C.MarkdownReceipt { C.MarkdownReceipt(digest: d, cacheDims: dims, kind: k, t: t) }
        XCTAssertFalse(C.markdownPending([]))
        XCTAssertTrue(C.markdownPending([r(1, "a", "asyncBegin", 0)]), "开始了没结束 = 在途")
        XCTAssertFalse(C.markdownPending([r(1, "a", "asyncBegin", 0), r(1, "a", "asyncEnd", 1)]))
        XCTAssertTrue(C.markdownPending([r(1, "a", "asyncBegin", 0), r(2, "a", "asyncEnd", 1)]), "别的文本的结束不算")
        XCTAssertTrue(C.markdownPending([r(1, "a", "asyncBegin", 0), r(1, "b", "asyncEnd", 1)]), "别的维度的结束不算")
        XCTAssertFalse(C.markdownPending([r(1, "a", "asyncEnd", 0), r(1, "a", "initHit", 1)]), "孤立的结束不算在途")
        XCTAssertTrue(C.markdownPending([r(1, "a", "asyncBegin", 0), r(1, "a", "asyncEnd", 1), r(1, "a", "asyncBegin", 2)]))
    }

    // MARK: 2.5 失败四类

    func testEveryKindHasOneClass() {
        let classes = Dictionary(grouping: C.FailureKind.allCases, by: \.failureClass)
        XCTAssertEqual(Set(classes.keys), [.correctness, .instrument, .productSlow, .confounded])
        XCTAssertEqual(C.FailureKind.lateOverwrite.failureClass, .correctness)
        XCTAssertEqual(C.FailureKind.extraRemount.failureClass, .correctness)
        XCTAssertEqual(C.FailureKind.windowSumMismatch.failureClass, .instrument)
        XCTAssertEqual(Set(C.FailureKind.allCases.filter(\.stopsRunImmediately)), [.unexpectedOutbound, .crossFloorWrite])
    }

    func testInstrumentOneOf16PassesTwoIsRed() {
        var procs = Array(repeating: [C.Failure](), count: 16)
        procs[3] = [C.Failure(.jsonMissing)]
        let one = C.armVerdict(processes: procs, planned: 16)
        XCTAssertFalse(one.red)
        XCTAssertEqual(one.instrumentCount, 1)
        XCTAssertEqual(one.instrumentAllowed, 1)
        procs[9] = [C.Failure(.probeMissing)]
        let two = C.armVerdict(processes: procs, planned: 16)
        XCTAssertTrue(two.red)
        XCTAssertNil(two.stopToFix)
    }

    func testSameInstrumentCauseTwiceInARowStops() {
        var procs = Array(repeating: [C.Failure](), count: 32)
        procs[4] = [C.Failure(.thermalJump)]
        procs[5] = [C.Failure(.thermalJump), C.Failure(.readyTimeout)]
        let v = C.armVerdict(processes: procs, planned: 32)
        XCTAssertEqual(v.stopToFix, .thermalJump)
        XCTAssertFalse(v.red, "32 个里 2 个未超 10%，但同因连续两次要先停下修")
        XCTAssertEqual(v.productSlowCount, 1)
    }

    func testCorrectnessOnceRedAndOutboundStops() {
        var procs = Array(repeating: [C.Failure](), count: 16)
        procs[0] = [C.Failure(.rowOrderMismatch)]
        let r = C.armVerdict(processes: procs, planned: 16)
        XCTAssertTrue(r.red)
        XCTAssertFalse(r.stopRun)
        procs[1] = [C.Failure(.unexpectedOutbound)]
        XCTAssertTrue(C.armVerdict(processes: procs, planned: 16).stopRun)
    }

    func testProductSlowKeptAndConfoundedOnlyDisablesDerivation() {
        var procs = Array(repeating: [C.Failure](), count: 16)
        procs[2] = [C.Failure(.readyTimeout)]
        procs[7] = [C.Failure(.streamLate)]
        procs[8] = [C.Failure(.premiseBroken, "warmMinusInplace"), C.Failure(.premiseBroken, "warmMinusInplace")]
        let v = C.armVerdict(processes: procs, planned: 16)
        XCTAssertFalse(v.red)
        XCTAssertEqual(v.productSlowCount, 2)
        XCTAssertEqual(v.processes, 16)
        XCTAssertEqual(v.disabledDerivations, ["warmMinusInplace"])
    }

    // MARK: 2.6 S 复原差异 + 指纹

    private let seedTime = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func seedS() -> ([C.NodeRecord], C.ConvRecord) {
        let nodes = (0..<40).map { i in
            C.NodeRecord(id: "S-\(i)", parentId: i == 0 ? nil : "S-\(i - 1)", childrenIds: i == 39 ? [] : ["S-\(i + 1)"], content: "第 \(i) 条")
        }
        return (nodes, C.ConvRecord(currentNodeId: "S-39", updateTime: seedTime, nodeCount: 40, unreadCount: 0, title: "流式样本", memoryEnabled: false))
    }

    /// 模拟一次真实 sendMessage：插 user + placeholder、改父节点 children、改会话字段
    private func afterTurn() -> ([C.NodeRecord], C.ConvRecord) {
        var (nodes, conv) = seedS()
        nodes[39].childrenIds = ["u1"]
        nodes.append(C.NodeRecord(id: "u1", parentId: "S-39", childrenIds: ["a1"], content: "问"))
        nodes.append(C.NodeRecord(id: "a1", parentId: "u1", childrenIds: [], content: "答"))
        conv.currentNodeId = "a1"
        conv.updateTime = seedTime.addingTimeInterval(5)
        conv.nodeCount = 42
        return (nodes.shuffled(), conv)
    }

    private func apply(_ plan: C.RestorePlan, seed: [C.NodeRecord], seedConv: C.ConvRecord,
                       to nodes: [C.NodeRecord], conv: C.ConvRecord) -> ([C.NodeRecord], C.ConvRecord) {
        let bySeed = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
        let out = nodes.filter { !plan.deleteIds.contains($0.id) }.map { n -> C.NodeRecord in
            guard let f = plan.nodeFixes[n.id], let s = bySeed[n.id] else { return n }
            var m = n
            if f.contains(.parentId) { m.parentId = s.parentId }
            if f.contains(.childrenIds) { m.childrenIds = s.childrenIds }
            if f.contains(.content) { m.content = s.content }
            return m
        }
        return (out, plan.convFields.isEmpty ? conv : seedConv)
    }

    func testRestorePlanRecoversSeedFingerprint() {
        let (seed, seedConv) = seedS()
        let (nodes, conv) = afterTurn()
        let before = C.ConvFingerprint(nodes: nodes, conv: conv)
        let seedFP = C.ConvFingerprint(nodes: seed, conv: seedConv)
        XCTAssertEqual(Set(before.diff(seedFP)), ["storedNodes", "ids", "content", "relation", "role", "currentNodeId", "nodeCount", "updateTime"])

        let plan = C.restorePlan(seedNodes: seed, seedConv: seedConv, nodes: nodes, conv: conv)
        XCTAssertEqual(plan.deleteIds, ["a1", "u1"])
        XCTAssertEqual(plan.nodeFixes, ["S-39": [.childrenIds]])
        XCTAssertEqual(plan.convFields, [.currentNodeId, .updateTime, .nodeCount])
        XCTAssertTrue(plan.missingSeedIds.isEmpty)

        let (rn, rc) = apply(plan, seed: seed, seedConv: seedConv, to: nodes, conv: conv)
        XCTAssertEqual(C.ConvFingerprint(nodes: rn, conv: rc), seedFP)
        XCTAssertTrue(C.restorePlan(seedNodes: seed, seedConv: seedConv, nodes: rn, conv: rc).isNoop, "幂等：再跑一次无改动")
    }

    func testRestorePlanFieldsAndMissingSeed() {
        let (seed, seedConv) = seedS()
        var nodes = seed
        nodes[5].content = "被改"
        nodes[6].parentId = "S-0"
        nodes.remove(at: 10)
        var conv = seedConv
        conv.unreadCount = 3
        conv.title = "新标题"
        conv.memoryEnabled = true
        let plan = C.restorePlan(seedNodes: seed, seedConv: seedConv, nodes: nodes, conv: conv)
        XCTAssertEqual(plan.nodeFixes, ["S-5": [.content], "S-6": [.parentId]])
        XCTAssertEqual(plan.missingSeedIds, ["S-10"], "种子节点丢了只能判 fixture 损坏")
        XCTAssertEqual(plan.convFields, [.unreadCount, .title, .memoryEnabled])
    }

    func testFingerprintOrderIndependentAndSensitive() {
        let (seed, conv) = seedS()
        XCTAssertEqual(C.ConvFingerprint(nodes: seed, conv: conv), C.ConvFingerprint(nodes: seed.reversed(), conv: conv))
        var reordered = seed
        reordered[3].childrenIds = ["S-5"]
        XCTAssertEqual(C.ConvFingerprint(nodes: reordered, conv: conv).diff(C.ConvFingerprint(nodes: seed, conv: conv)), ["relation"])
    }

    func testDigestIsFNV1aAndLengthPrefixed() {
        XCTAssertEqual(C.fnv1a64(""), 0xcbf29ce484222325)
        XCTAssertEqual(C.fnv1a64("a"), 0xaf63dc4c8601ec8c)
        XCTAssertNotEqual(C.digest(["ab", "c"]), C.digest(["a", "bc"]))
    }

    // MARK: 2.7 注册表 token + 到达表

    func testLateUnregisterDoesNotClearNewRegistration() {
        var r = C.ProbeRegistry()
        let old = UUID(), new = UUID()
        XCTAssertEqual(r.register(old), 1)
        XCTAssertEqual(r.register(new), 2)
        XCTAssertFalse(r.unregister(old), "旧挂载迟到的注销")
        XCTAssertEqual(r.current, new)
        XCTAssertTrue(r.unregister(new))
        XCTAssertNil(r.current)
        XCTAssertEqual(r.register(old), 3, "再注册代际继续涨")
    }

    func testArrivalScheduleClustersOnSlowTickWithoutStretching() throws {
        let offsets = (0..<50).map { Double($0) * 0.04 }
        var s = C.ArrivalSchedule(offsets: offsets, anchor: 100)
        var ticks = Array(stride(from: 100.0, through: 103.0, by: 1.0 / 60))
        ticks.removeAll { $0 > 100.2 && $0 < 100.5 }
        var clusters: [Int] = []
        var finishedAt: Double?
        var delivered: [Int] = []
        for t in ticks {
            let r = s.due(at: t)
            delivered += Array(r)
            if !r.isEmpty { clusters.append(r.count) }
            if s.isFinished, finishedAt == nil { finishedAt = t }
        }
        XCTAssertEqual(delivered, Array(0..<50), "每片恰投一次、按序")
        XCTAssertGreaterThanOrEqual(clusters.max() ?? 0, 7, "300ms 卡顿后成簇到达")
        let end = try XCTUnwrap(finishedAt)
        XCTAssertLessThanOrEqual(end - 100, offsets.last! + 1.0 / 60 + 1e-9, "终片按墙钟，不被慢 tick 拉长")
        XCTAssertTrue(s.due(at: 200).isEmpty)
    }

    // MARK: 纵切 3 · fixture 生成器 / 指纹角色 / 楼层恢复与防呆

    func testFixtureSpecsRolesLongTextsAndRows() {
        let F = C.Fixture.self
        XCTAssertEqual(F.all.map(\.count), [80, 3000, 40, 40])
        for spec in F.all {
            let nodes = F.nodes(spec)
            XCTAssertEqual(Set(nodes.map(\.id)).count, spec.count, "\(spec.key) id 唯一")
            XCTAssertEqual(F.expectedRows(spec), nodes.map(\.id))
            XCTAssertNil(nodes[0].parentId)
            XCTAssertEqual(nodes.last?.childrenIds, [])
            XCTAssertEqual(F.conv(spec).currentNodeId, nodes.last?.id)
            XCTAssertEqual(F.conv(spec).nodeCount, spec.count)
            XCTAssertEqual(F.conv(spec).unreadCount, 0)
            for i in spec.longIndices {
                let n = nodes[i]
                XCTAssertEqual(n.role, "assistant", "\(spec.key) 长文 \(i) 必须 assistant（不靠奇偶）")
                XCTAssertGreaterThan(n.content.count, F.longMinChars)
                XCTAssertFalse(n.content.contains("\n"), "单段、无空行")
                XCTAssertTrue(n.content.hasPrefix("⟦PERF:\(n.id)⟧"))
                XCTAssertTrue(String(n.content.prefix(64)).contains("⟦PERF:\(n.id)⟧"), "标记在前 64 字内")
            }
            XCTAssertEqual(F.bodyDigests(spec)[nodes[0].id], C.fnv1a64(nodes[0].content))
        }
        XCTAssertEqual(F.L.longIndices, [75, 79], "L1 = 最后一条，L2 = 倒数第 5 条")
        // M2：中长文 300–3000 字（≤ 同步解析门槛）、assistant、多块 markdown；user 是短句
        let m = F.nodes(F.M)
        XCTAssertEqual(F.M.mediumIndices.count, 30)
        for i in F.M.mediumIndices {
            XCTAssertEqual(m[i].role, "assistant")
            let range = i == F.mediumSixKIndex ? 5000...F.mediumSixKMaxChars : F.mediumMinChars...F.mediumMaxChars   // r10：M-39 约 6k 字
            XCTAssertTrue(range.contains(m[i].content.count), "M-\(i) \(m[i].content.count) 字")
            XCTAssertTrue(m[i].content.contains("\n\n"), "多块")
        }
        let all = F.M.mediumIndices.map { m[$0].content }.joined()
        for mark in ["## ", "**", "- 要点", "1. 第一步", "> 引用", "```swift", "|---|"] { XCTAssertTrue(all.contains(mark), mark) }
        XCTAssertGreaterThan(F.M.mediumIndices.map { m[$0].content.count }.max() ?? 0, 2800)
        XCTAssertEqual(Set(m.indices).subtracting(F.M.mediumIndices).map { m[$0].role }, Array(repeating: "user", count: 10))
        XCTAssertEqual(m.last?.role, "assistant")
        XCTAssertEqual(F.nodes(F.L).last?.role, "assistant")
        XCTAssertFalse(F.S.memoryEnabled)
        XCTAssertEqual(Set(F.all.map(\.convId)).count, 4)
        XCTAssertEqual(F.fingerprint(F.D), F.fingerprint(F.D), "确定性：两次生成同指纹")
        XCTAssertTrue(F.body(10).hasPrefix("第 10 条。看看这段实现") && F.body(10).contains("```swift"), "配比按 i % 10（legacy PerfSeed.body 同源）")
        XCTAssertEqual(F.body(13), "第 13 条：一到两行的常规短句。")
    }

    func testFingerprintCatchesRoleChangeAndDigestCoversEveryConv() {
        let nodes = C.Fixture.nodes(C.Fixture.S)
        var flipped = nodes
        flipped[3].role = flipped[3].role == "user" ? "assistant" : "user"
        let conv = C.Fixture.conv(C.Fixture.S)
        XCTAssertEqual(C.ConvFingerprint(nodes: flipped, conv: conv).diff(C.ConvFingerprint(nodes: nodes, conv: conv)), ["role"])
        let base: [String: C.ConvFingerprint] = ["S": C.ConvFingerprint(nodes: nodes, conv: conv), "L": C.Fixture.fingerprint(C.Fixture.L)]
        let d0 = C.fixtureDigest(base, benchConvs: 155)
        XCTAssertTrue(d0.hasPrefix("fx-"))
        XCTAssertEqual(d0, C.fixtureDigest(base, benchConvs: 155))
        XCTAssertNotEqual(d0, C.fixtureDigest(base, benchConvs: 156), "楼层对话数进摘要")
        var moved = base
        moved["S"] = C.ConvFingerprint(nodes: flipped, conv: conv)
        XCTAssertNotEqual(d0, C.fixtureDigest(moved, benchConvs: 155))
    }

    func testRestoreFromSendLeftoversUsesGeneratorSeed() {
        let spec = C.Fixture.S
        var nodes = C.Fixture.nodes(spec)
        nodes[39].childrenIds = ["u1"]
        nodes += [C.NodeRecord(id: "u1", parentId: nodes[39].id, childrenIds: ["a1"], content: "hi", role: "user"),
                  C.NodeRecord(id: "a1", parentId: "u1", childrenIds: [], content: "reply", role: "assistant")]
        var conv = C.Fixture.conv(spec)
        conv.currentNodeId = "a1"; conv.nodeCount = 42; conv.updateTime = Date()
        let plan = C.restorePlan(seedNodes: C.Fixture.nodes(spec), seedConv: C.Fixture.conv(spec), nodes: nodes, conv: conv)
        XCTAssertEqual(plan.deleteIds, ["a1", "u1"])
        XCTAssertEqual(plan.nodeFixes, [nodes[39].id: [.childrenIds]])
        XCTAssertEqual(plan.convFields, [.currentNodeId, .nodeCount, .updateTime])
        XCTAssertTrue(plan.missingSeedIds.isEmpty)
    }

    func testFloorRestoreNeverPicksArbitraryProfile() {
        let ps = ["ghost-lily", "work", "perf-bench-profile"], b = "perf-bench-profile"
        XCTAssertEqual(C.floorRestore(saved: "work", current: b, profiles: ps, bench: b), .switchTo("work"))
        XCTAssertEqual(C.floorRestore(saved: "work", current: "work", profiles: ps, bench: b), .stay)
        XCTAssertEqual(C.floorRestore(saved: "gone", current: b, profiles: ps, bench: b), .fail("restore: original profile missing"))
        XCTAssertEqual(C.floorRestore(saved: nil, current: b, profiles: ps, bench: b), .fail("restore: original profile key missing"))
        XCTAssertEqual(C.floorRestore(saved: "", current: b, profiles: ps, bench: b), .fail("restore: original profile key missing"))
        XCTAssertEqual(C.floorRestore(saved: nil, current: "ghost-lily", profiles: ps, bench: b), .stay, "无键且已不在 bench：幂等")
        XCTAssertEqual(C.floorRestore(saved: b, current: b, profiles: ps, bench: b), .fail("restore: saved original is the bench profile"))
    }

    func testFloorGuardPrefersSavedOriginal() {
        let ps = ["ghost-lily", "work", "perf-bench-profile"], b = "perf-bench-profile"
        XCTAssertNil(C.floorGuard(saved: "work", current: "ghost-lily", profiles: ps, bench: b), "不在 bench 不动")
        XCTAssertEqual(C.floorGuard(saved: "work", current: b, profiles: ps, bench: b).map { [$0.target, "\($0.clearKey)"] }, ["work", "true"])
        XCTAssertEqual(C.floorGuard(saved: nil, current: b, profiles: ps, bench: b).map { [$0.target, "\($0.clearKey)"] }, ["ghost-lily", "false"])
        XCTAssertEqual(C.floorGuard(saved: "gone", current: b, profiles: ps, bench: b).map { [$0.target, "\($0.clearKey)"] }, ["ghost-lily", "false"], "原楼层不在：退到非 bench、保键留证")
        XCTAssertNil(C.floorGuard(saved: nil, current: b, profiles: [b], bench: b))
    }

    // MARK: R4 修复（纵切 3 审）

    func testC01SeedOverwritesStaleKeyUnlessOnBench() {
        let b = "perf-bench-profile"
        XCTAssertEqual(C.seedOriginalKey(saved: "stale-x", current: "ghost-lily", bench: b), "ghost-lily", "不在 bench：当前楼层覆盖陈旧键")
        XCTAssertEqual(C.seedOriginalKey(saved: nil, current: "ghost-lily", bench: b), "ghost-lily")
        XCTAssertEqual(C.seedOriginalKey(saved: "ghost-lily", current: b, bench: b), "ghost-lily", "已在 bench：沿用旧键")
        XCTAssertNil(C.seedOriginalKey(saved: nil, current: b, bench: b))
    }

    func testC02OnlyChatV1SeedPlantsFixture() {
        XCTAssertTrue(C.seedsChatV1Fixture(protocol: "chatV1"))
        XCTAssertFalse(C.seedsChatV1Fixture(protocol: nil), "legacy perf-run.sh seed")
        XCTAssertFalse(C.seedsChatV1Fixture(protocol: "launchV2"))
    }

    func testC06StrayNodesScannedWhenStrayConversationRemoved() {
        XCTAssertFalse(C.scanStrayNodes(forced: false, strayConvs: 0), "正常启动无误写：不做 20 万行扫描")
        XCTAssertTrue(C.scanStrayNodes(forced: false, strayConvs: 1), "删到误写对话：同 id 节点一起清，不留孤儿")
        XCTAssertTrue(C.scanStrayNodes(forced: true, strayConvs: 0))
    }

    func testC10InsertPlanHealsDeletedBenchFixture() {
        let all: Set<String> = ["L", "D", "S", "M"]
        XCTAssertEqual(C.fixtureInsertPlan(sentinel: true, present: all), .init(insert: [], resetBaseline: false))
        XCTAssertEqual(C.fixtureInsertPlan(sentinel: true, present: []), .init(insert: ["L", "D", "S", "M"], resetBaseline: true),
                       "楼层删过：sentinel 还在也要重插并重记基线")
        XCTAssertEqual(C.fixtureInsertPlan(sentinel: true, present: ["L", "S", "M"]), .init(insert: ["D"], resetBaseline: true), "只补缺的")
        XCTAssertEqual(C.fixtureInsertPlan(sentinel: false, present: []), .init(insert: ["L", "D", "S", "M"], resetBaseline: true))
        XCTAssertEqual(C.fixtureInsertPlan(sentinel: false, present: all), .init(insert: [], resetBaseline: false), "都在：不重复插")
    }

    func testC04IndexBackfillOverlap() {
        XCTAssertFalse(C.indexBackfill(start: "ready", end: "ready"))
        XCTAssertFalse(C.indexBackfill(start: "idle", end: "ready"), "延迟启动后只对账")
        XCTAssertTrue(C.indexBackfill(start: "building", end: "ready"))
        XCTAssertTrue(C.indexBackfill(start: "idle", end: "building"))
    }

    func testC09SendFieldsRestoredAndFingerprinted() {
        let spec = C.Fixture.S
        let seed = C.Fixture.nodes(spec), seedConv = C.Fixture.conv(spec)
        XCTAssertNil(seedConv.branchSelectionData)
        XCTAssertEqual([seedConv.selectedModelId, seedConv.draftText, seedConv.permGrantsRaw], ["", "", ""])
        var conv = seedConv
        conv.branchSelectionData = Data("{\"a\":\"b\"}".utf8)
        conv.selectedModelId = "perf-scripted/perf"
        conv.draftText = "草稿"
        conv.permGrantsRaw = "web:allow"
        let plan = C.restorePlan(seedNodes: seed, seedConv: seedConv, nodes: seed, conv: conv)
        XCTAssertEqual(plan.convFields, [.branchSelectionData, .selectedModelId, .draftText, .permGrantsRaw])
        let dirty = C.ConvFingerprint(nodes: seed, conv: conv), clean = C.Fixture.fingerprint(spec)
        XCTAssertEqual(dirty.diff(clean), ["branchSelectionData", "selectedModelId", "draftText", "permGrantsRaw"])
        XCTAssertNotEqual(dirty.canonical, clean.canonical, "发送残留进整轮摘要")
        let aDirty = C.ConvFingerprint(nodes: seed, conv: conv, includeBranchSelection: false)
        var onlyBranch = seedConv
        onlyBranch.branchSelectionData = conv.branchSelectionData
        XCTAssertEqual(C.ConvFingerprint(nodes: seed, conv: onlyBranch, includeBranchSelection: false),
                       C.ConvFingerprint(nodes: seed, conv: seedConv, includeBranchSelection: false), "A / B 不含选择表（§14-21）")
        XCTAssertEqual(aDirty.diff(C.ConvFingerprint(nodes: seed, conv: seedConv, includeBranchSelection: false)),
                       ["selectedModelId", "draftText", "permGrantsRaw"])
    }
    // MARK: R5 纵切 4 审余项

    func testK06PreApplyMountIsPinned() {
        var m = C.MountAcceptance(baseGen: 4)
        XCTAssertEqual(m.noteMount(gen: 5), .beforeApply)
        m.noteApply()
        XCTAssertTrue(m.holds(currentGen: 5))
        XCTAssertFalse(m.holds(currentGen: 4), "apply 前换过代、之后没接纳新挂载：当前必须仍是那代（旧版恒 true）")
        XCTAssertEqual(m.noteMount(gen: 6), .accepted)
        XCTAssertTrue(m.holds(currentGen: 6))
        XCTAssertFalse(m.holds(currentGen: 5))
    }

    func testC05LeadGapBeforeFirstCallbackCounted() throws {
        let p = 1.0 / 60
        // request 在 1.000；上一回调 0.990 宣告下一帧 1.0067，主线程卡到 1.100 才来首回调
        let prev = C.FrameSample(arrival: 0.990, timestamp: 0.990, targetTimestamp: 0.990 + p)
        var s = [C.FrameSample(arrival: 1.100, timestamp: 1.100, targetTimestamp: 1.100 + p)]
        s.append(C.FrameSample(arrival: 1.100 + p, timestamp: 1.100 + p, targetTimestamp: 1.100 + 2 * p))
        let end = 1.100 + p
        let g = try C.frameGaps(s, from: 1.0, to: end, previous: prev).get()
        XCTAssertEqual(g.worstGapMs, 100, accuracy: 1e-6, "首段间隔裁到 request：1.100 − 1.000")
        XCTAssertEqual(g.callbackGapExcess, 1000 * (1.100 - (0.990 + p)) / (end - 1.0), accuracy: 1e-6,
                       "超额 = 首回调 − max(request, 上一回调宣告目标)")
        XCTAssertEqual(g.firstCallbackDelayMs!, 100, accuracy: 1e-6)
        let steadyPrev = C.FrameSample(arrival: 0.995, timestamp: 0.995, targetTimestamp: 0.995 + p)
        let t = [C.FrameSample(arrival: 0.995 + p, timestamp: 0.995 + p, targetTimestamp: 0.995 + 2 * p)]
        let h = try C.frameGaps(t, from: 1.0, to: 0.995 + p, previous: steadyPrev).get()
        XCTAssertEqual(h.callbackGapExcess, 0, accuracy: 1e-9, "准点首回调不算超额")
    }

    func testC07ChainAroundDeepJumpTarget() {
        let ids = (0..<200).map { "n\($0)" }
        // 目标 n100 居中（视口 y ∈ [150, 744]，中心 447），行高 80、间距 12
        var rects: [String: CGRect] = [:]
        for i in 90...110 { rects["n\(i)"] = CGRect(x: 0, y: 407 + CGFloat(i - 100) * 92, width: 390, height: 80) }
        guard case .complete(let chain) = C.messageChainAround(anchor: "n100", expected: ids, rects: rects, viewport: viewport,
                                                               spacing: spacing, scale: scale) else { return XCTFail("应成链") }
        XCTAssertTrue(chain.contains("n100"))
        XCTAssertEqual(chain.first, "n97", "向旧接到视口顶")
        XCTAssertEqual(chain.last, "n103", "向新接到视口底（n103 底边越过视口底即止）")
        XCTAssertEqual(chain, chain.sorted { Int($0.dropFirst())! < Int($1.dropFirst())! }, "旧 → 新")
        // 贴底成链在同一几何下必断（最新行不在视口底）——这正是搜索冒烟要单独定义锚点的原因
        if case .complete = C.messageChain(expected: ids, rects: rects, viewport: viewport, spacing: spacing, scale: scale) {
            XCTFail("贴底规则不该对深处跳转成链")
        }
        var holed = rects
        holed["n102"] = nil
        XCTAssertEqual(C.messageChainAround(anchor: "n100", expected: ids, rects: holed, viewport: viewport, spacing: spacing, scale: scale),
                       .missingRow("n102"))
        var off = rects
        off["n100"] = CGRect(x: 0, y: 900, width: 390, height: 80)
        guard case .gap("n100", _) = C.messageChainAround(anchor: "n100", expected: ids, rects: off, viewport: viewport,
                                                          spacing: spacing, scale: scale) else { return XCTFail("目标不在视口 = 不成链") }
        let short = ["a", "b", "c"]
        let bottom = stack(short, bottom: 744, height: 60, gap: spacing)
        XCTAssertEqual(C.messageChainAround(anchor: "b", expected: short, rects: bottom, viewport: viewport, spacing: spacing, scale: scale),
                       .complete(["a", "b", "c"]), "列表端点即止")
    }

    func testC04MarkdownEvidenceMatchesDigestAndCurrentDims() {
        func r(_ d: UInt64, _ dims: String, _ k: String, _ t: Double) -> C.MarkdownReceipt { C.MarkdownReceipt(digest: d, cacheDims: dims, kind: k, t: t) }
        let cold = [r(9, "full", "asyncBegin", 0), r(9, "full", "asyncEnd", 1)]
        XCTAssertTrue(C.markdownEvidence(cold, expectedDigest: 9, warm: false))
        XCTAssertFalse(C.markdownEvidence(cold, expectedDigest: 7, warm: false), "别的正文（如截断文本）的回执不算")
        XCTAssertFalse(C.markdownEvidence(cold + [r(9, "dark", "initHit", 2)], expectedDigest: 9, warm: false),
                       "本行当前维度已变（最新回执是 dark）：旧维度的 async 对不算")
        XCTAssertTrue(C.markdownEvidence([r(9, "full", "initHit", 0)], expectedDigest: 9, warm: true))
        XCTAssertFalse(C.markdownEvidence([r(9, "full", "initHit", 0)], expectedDigest: 9, warm: false), "冷访命中不算")
        XCTAssertFalse(C.markdownEvidence([r(9, "full", "asyncEnd", 0)], expectedDigest: 9, warm: false), "只有结束没有开始")
        XCTAssertTrue(C.markdownEvidence([r(9, "full", "initSync", 0)], expectedDigest: 9, warm: false), "L1 ③：长文首见同步解析，冷访也算正文到位")
        XCTAssertFalse(C.markdownEvidence([r(7, "full", "initSync", 0)], expectedDigest: 9, warm: false), "别的正文的同步回执不算")
        XCTAssertFalse(C.markdownEvidence([], expectedDigest: 9, warm: true))
    }

    func testC10AppliedKeyCatchesUnbumpedWrite() {
        final class N {}
        let a = N(), b = N(), c = N()
        let k1 = C.AppliedKey(revision: 3, count: 2, first: ObjectIdentifier(a), last: ObjectIdentifier(b), profileId: "p", conversationId: "x")
        let same = C.AppliedKey(revision: 3, count: 2, first: ObjectIdentifier(a), last: ObjectIdentifier(b), profileId: "p", conversationId: "x")
        let appended = C.AppliedKey(revision: 3, count: 3, first: ObjectIdentifier(a), last: ObjectIdentifier(c), profileId: "p", conversationId: "x")
        let swappedTail = C.AppliedKey(revision: 3, count: 2, first: ObjectIdentifier(a), last: ObjectIdentifier(c), profileId: "p", conversationId: "x")
        XCTAssertEqual(k1, same)
        XCTAssertNotEqual(k1, appended, "revision 没自增、行数变了照样重算")
        XCTAssertNotEqual(k1, swappedTail, "末行换了照样重算")
    }

    func testC09RowKeysClearOldIdOnReuse() {
        var k = C.RowKeys<Int>()
        k.moved(1, id: "a", inWindow: true)
        k.moved(2, id: "b", inWindow: true)
        k.moved(1, id: "c", inWindow: true)
        XCTAssertNil(k.byId["a"], "句柄 1 换成 c：旧键 a 清掉，不再和 c 共用一个 rect")
        XCTAssertEqual(k.byId["c"], 1)
        XCTAssertEqual(k.byHandle[1], "c")
        k.moved(3, id: "b", inWindow: true)
        XCTAssertEqual(k.byId["b"], 3)
        XCTAssertNil(k.byHandle[2], "id 被别的句柄接手：旧句柄的反向键清掉")
        k.moved(2, id: "b", inWindow: false)
        XCTAssertEqual(k.byId["b"], 3, "旧句柄离窗不清别人的键")
        k.moved(3, id: "b", inWindow: false)
        XCTAssertNil(k.byId["b"])
        k.moved(1, id: "", inWindow: true)
        XCTAssertNil(k.byId["c"], "换成空 id：旧键照样清")
        k.moved(4, id: "d", inWindow: true)
        k.drop(4)
        XCTAssertNil(k.byId["d"])
    }

    func testC08ABAVerdictUsesLastRowChanger() {
        typealias R = C.ApplyRecord
        // plain + 延迟：B 被守卫丢掉，A2 改写行，迟到的 A1 写同一路径（不改行）
        let plain = [R(req: 3, t: 0.30, dropped: true, changedRows: false), R(req: 4, t: 0.35, dropped: false, changedRows: true),
                     R(req: 2, t: 0.70, dropped: false, changedRows: false)]
        let v = C.abaVerdict(plain, finalReq: 4, finalT0: 0.10)
        XCTAssertEqual(v.lastWriter, 2, "旧断言（最后写者）会误判红")
        XCTAssertEqual(v.lastChanger, 4)
        XCTAssertTrue(v.navigationOK)
        XCTAssertEqual(v.lateApplies, 1)
        XCTAssertEqual(v.lateChangingApplies, 0)
        XCTAssertEqual(v.lateDropped, 1)
        // 分支变体：迟到的临时分支浏览改写了行
        let branch = [R(req: 3, t: 0.30, dropped: false, changedRows: true), R(req: 2, t: 0.80, dropped: false, changedRows: true)]
        let w = C.abaVerdict(branch, finalReq: 3, finalT0: 0.05)
        XCTAssertEqual(w.lastChanger, 2)
        XCTAssertFalse(w.navigationOK)
        XCTAssertEqual(w.lateChangingApplies, 1)
        XCTAssertEqual(C.abaVerdict([R(req: 2, t: 0.01, dropped: false, changedRows: true)], finalReq: 3, finalT0: 0.05).lateApplies, 0,
                       "最终请求发出之前落地的旧 apply 不算迟到")
    }

    // MARK: 纵切 5 深翻驱动

    func testTraverseCheckpointsMatchProtocolFixture() {
        let d = C.Fixture.D
        let cps = C.Traverse.checkpoints(count: d.count, every: 100, long: d.longIndices)
        XCTAssertEqual(cps.count, 34)
        XCTAssertEqual(cps.first, 0)
        XCTAssertEqual(cps.last, 2999)
        XCTAssertTrue(Set([501, 1501, 2501, 2900]).isSubset(of: cps))
        XCTAssertEqual(cps, cps.sorted())
        XCTAssertEqual(C.Traverse.missing(planned: cps, hits: Set(cps).subtracting([1500, 1501])), [1500, 1501])
    }

    func testTraverseRelationBothDirections() {
        typealias T = C.Traverse
        let vp = CGRect(x: 0, y: 166, width: 390, height: 562)   // 视口 166…728
        let above = CGRect(x: 0, y: 40, width: 390, height: 100)  // 视觉上方（更旧）
        let below = CGRect(x: 0, y: 800, width: 390, height: 100)
        // 上行（older）：上方 = 前方，走 166−140 + 100（行高）进来；下方 = 已越过
        XCTAssertEqual(T.relation(older: true, rect: above, index: 5, viewport: vp, realized: 0...9), .ahead(enter: 126))
        XCTAssertEqual(T.relation(older: true, rect: below, index: 5, viewport: vp, realized: 0...9), .passed(back: 172))
        // 回程（newer）反过来
        XCTAssertEqual(T.relation(older: false, rect: below, index: 5, viewport: vp, realized: 0...9), .ahead(enter: 172))
        XCTAssertEqual(T.relation(older: false, rect: above, index: 5, viewport: vp, realized: 0...9), .passed(back: 126))
        XCTAssertEqual(T.relation(older: true, rect: CGRect(x: 0, y: 700, width: 390, height: 100), index: 5, viewport: vp, realized: nil), .inView)
        // 没实化：按下标与已实化区间判前后
        XCTAssertEqual(T.relation(older: true, rect: nil, index: 3, viewport: vp, realized: 10...30), .ahead(enter: nil))
        XCTAssertEqual(T.relation(older: true, rect: nil, index: 40, viewport: vp, realized: 10...30), .passed(back: nil))
        XCTAssertEqual(T.relation(older: false, rect: nil, index: 40, viewport: vp, realized: 10...30), .ahead(enter: nil))
        XCTAssertEqual(T.relation(older: false, rect: nil, index: 3, viewport: vp, realized: 10...30), .passed(back: nil))
        XCTAssertEqual(T.relation(older: false, rect: nil, index: 3, viewport: vp, realized: nil), .noRows)
        // 很高的行：进来一截只要半个视口
        let tall = CGRect(x: 0, y: -2000, width: 390, height: 2100)
        XCTAssertEqual(T.relation(older: true, rect: tall, index: 5, viewport: vp, realized: 0...9), .ahead(enter: 66 + 281))
    }

    func testTraverseStepCapsSeeksHoldsAndHooksDisable() {
        typealias T = C.Traverse
        // 名义步长：速度极高时被视口比例封顶；stepCap 关掉只剩 speed × dt
        XCTAssertEqual(T.nominal(speed: 12000, dt: 1.0 / 60, viewportHeight: 562, stepCapFrac: 0.8, stepCap: true), 200, accuracy: 1e-6)
        XCTAssertEqual(T.nominal(speed: 1_000_000, dt: 1.0 / 60, viewportHeight: 562, stepCapFrac: 0.8, stepCap: true), 449.6, accuracy: 1e-6)
        XCTAssertEqual(T.nominal(speed: 1_000_000, dt: 1.0 / 60, viewportHeight: 562, stepCapFrac: 0.8, stepCap: false), 16666.666, accuracy: 1e-2)
        XCTAssertEqual(T.step(nominal: 200, relation: .ahead(enter: 80), checkpointWait: true, seekCap: 449.6), T.Step(delta: 80, kind: .capped))
        XCTAssertEqual(T.step(nominal: 200, relation: .ahead(enter: 300), checkpointWait: true, seekCap: 449.6), T.Step(delta: 200, kind: .free))
        XCTAssertEqual(T.step(nominal: 200, relation: .ahead(enter: nil), checkpointWait: true, seekCap: 449.6), T.Step(delta: 200, kind: .free))
        XCTAssertEqual(T.step(nominal: 200, relation: .passed(back: 50), checkpointWait: true, seekCap: 449.6), T.Step(delta: -50, kind: .seek))
        XCTAssertEqual(T.step(nominal: 200, relation: .passed(back: nil), checkpointWait: true, seekCap: 449.6), T.Step(delta: -200, kind: .seek))
        XCTAssertEqual(T.step(nominal: 16000, relation: .passed(back: nil), checkpointWait: true, seekCap: 449.6), T.Step(delta: -449.6, kind: .seek),
                       "回找距离未知：每帧最多退 seekCap，不跟着名义步长来回跨")
        XCTAssertEqual(T.step(nominal: 200, relation: .noRows, checkpointWait: true, seekCap: 449.6), T.Step(delta: 0, kind: .hold))
        XCTAssertEqual(T.step(nominal: 200, relation: .inView, checkpointWait: true, seekCap: 449.6), T.Step(delta: 200, kind: .free))
        // 测试钩子：检查点约束关掉 → 越过了也不回找
        XCTAssertEqual(T.step(nominal: 200, relation: .passed(back: 50), checkpointWait: false, seekCap: 449.6), T.Step(delta: 200, kind: .free))
        XCTAssertEqual(T.step(nominal: 200, relation: .ahead(enter: 80), checkpointWait: false, seekCap: 449.6), T.Step(delta: 200, kind: .free))
    }

    /// 连续几何下：步长 < 视口高就不可能一步跨过任何一行（纯几何模拟，驱动按 relation → step 走）
    func testTraverseSimulationCoversEveryCheckpointAtAnySpeed() {
        typealias T = C.Traverse
        let vp = CGRect(x: 0, y: 166, width: 390, height: 562)
        let heights = (0..<3000).map { CGFloat([44, 44, 160, 44, 44, 44, 90, 44, 44, 44][$0 % 10]) }
        var top = [CGFloat](repeating: 0, count: 3000)   // 内容坐标：index 越小越靠上（更旧）
        for i in 1..<3000 { top[i] = top[i - 1] + heights[i - 1] + 31 }
        let cps = T.checkpoints(count: 3000, every: 100, long: [501, 1501, 2501])
        func run(speed: Double, wait: Bool, cap: Bool) -> [Int] {
            // scroll = 视口顶对应的内容 y；从底（最新行贴视口底）往上走到最旧行进视口
            var scroll = top[2999] + heights[2999] - vp.height
            var hits = Set<Int>()
            var frames = 0
            while !hits.contains(0), frames < 100_000 {
                frames += 1
                let visible = (0..<3000).filter { top[$0] < scroll + vp.height && top[$0] + heights[$0] > scroll }
                for i in visible where cps.contains(i) { hits.insert(i) }
                guard let next = cps.reversed().first(where: { !hits.contains($0) }) else { break }
                let rect = CGRect(x: 0, y: vp.minY + top[next] - scroll, width: 390, height: heights[next])
                let rel = abs(rect.midY - vp.midY) < 3000 ? T.relation(older: true, rect: rect, index: next, viewport: vp, realized: visible.first.map { $0...visible.last! })
                    : T.relation(older: true, rect: nil, index: next, viewport: vp, realized: visible.first.map { $0...visible.last! })
                let s = T.step(nominal: T.nominal(speed: speed, dt: 1.0 / 60, viewportHeight: vp.height, stepCapFrac: 0.8, stepCap: cap),
                               relation: rel, checkpointWait: wait, seekCap: 0.8 * vp.height)
                scroll = max(top[0] - 10, scroll - s.delta)   // older = 内容往下 = 视口顶往上
            }
            return T.missing(planned: cps, hits: hits)
        }
        XCTAssertEqual(run(speed: 12000, wait: true, cap: true), [])
        XCTAssertEqual(run(speed: 1_000_000, wait: true, cap: true), [], "极高速度：步长被封顶 + 检查点截步，覆盖仍全")
        XCTAssertEqual(run(speed: 1_000_000, wait: true, cap: false), [], "只关视口比例上限：越过的检查点回找")
        XCTAssertFalse(run(speed: 1_000_000, wait: false, cap: false).isEmpty, "两道约束都关：一步几万 pt，检查点必漏")
    }

    /// R6 C-05：检查点行已实化、探针却没登记它（UIKit 新页最易踩）。没有 Watch 时驱动「前进—越过—回找」来回振荡到阶段上限，
    /// 被记成产品慢 traversalTimeCap；有 Watch 时几十帧内判仪器 probeMissedCheckpoint
    func testR6C05UnregisteredCheckpointIsInstrumentNotTimeCap() {
        typealias T = C.Traverse
        let vp = CGRect(x: 0, y: 166, width: 390, height: 562)
        let heights = (0..<3000).map { CGFloat([44, 44, 160, 44, 44, 44, 90, 44, 44, 44][$0 % 10]) }
        var top = [CGFloat](repeating: 0, count: 3000)
        for i in 1..<3000 { top[i] = top[i - 1] + heights[i - 1] + 31 }
        let cps = T.checkpoints(count: 3000, every: 100, long: [501, 1501, 2501])
        let dropped = 2900   // 探针漏登记的行：照常实化、照常在视口里，只是 visibleRows 里没有
        func run(watching: Bool) -> (frames: Int, failure: C.Failure?, reachedOldest: Bool) {
            var scroll = top[2999] + heights[2999] - vp.height
            var hits = Set<Int>()
            var watch = T.Watch()
            let cap = 90 * 60   // 阶段上限 90s @60Hz
            for frame in 1...cap {
                let realizedAll = (0..<3000).filter { top[$0] < scroll + vp.height + 400 && top[$0] + heights[$0] > scroll - 400 }
                let probeRows = realizedAll.filter { $0 != dropped }
                for i in probeRows where cps.contains(i) && top[i] < scroll + vp.height && top[i] + heights[i] > scroll { hits.insert(i) }
                if hits.contains(0) { return (frame, nil, true) }
                guard let next = cps.reversed().first(where: { !hits.contains($0) }) else { return (frame, nil, true) }
                let realized = probeRows.first.map { $0...probeRows.last! }
                let rect = probeRows.contains(next) ? CGRect(x: 0, y: vp.minY + top[next] - scroll, width: 390, height: heights[next]) : nil
                let rel = T.relation(older: true, rect: rect, index: next, viewport: vp, realized: realized)
                if watching, let range = realized,
                   let f = watch.feed(checkpoint: next, relation: rel, unregisteredInRange: rect == nil && range.contains(next)) {
                    return (frame, f, false)
                }
                let s = T.step(nominal: T.nominal(speed: 12000, dt: 1.0 / 60, viewportHeight: vp.height, stepCapFrac: 0.8, stepCap: true),
                               relation: rel, checkpointWait: true, seekCap: 0.8 * vp.height)
                scroll = max(top[0] - 10, scroll - s.delta)
            }
            return (cap, nil, false)
        }
        let before = run(watching: false)
        XCTAssertEqual(before.frames, 90 * 60, "无 Watch：振荡到阶段上限 = 修前被记成产品慢 timeCap")
        XCTAssertFalse(before.reachedOldest)
        let after = run(watching: true)
        XCTAssertEqual(after.failure?.kind, .probeMissedCheckpoint)
        XCTAssertEqual(after.failure?.kind.failureClass, .instrument)
        XCTAssertLessThanOrEqual(after.frames, 120, "走到 #2900 约 45 帧，之后几次换向就判仪器，不空转到 timeCap")
        XCTAssertTrue(after.failure?.detail.contains("#2900") ?? false)
        // 正常几何（不漏登记）照旧全中、Watch 不误报
        var watch = T.Watch()
        XCTAssertNil(watch.feed(checkpoint: 100, relation: .ahead(enter: 80), unregisteredInRange: false))
        XCTAssertNil(watch.feed(checkpoint: 100, relation: .passed(back: 20), unregisteredInRange: false))
        XCTAssertNil(watch.feed(checkpoint: 100, relation: .ahead(enter: 5), unregisteredInRange: false))
        XCTAssertNil(watch.feed(checkpoint: 100, relation: .passed(back: 5), unregisteredInRange: false),
                     "有 rect 的来回（产品几何抖动）不归仪器，该超时就超时")
    }

    /// R6 C-09：探针 / 视口 / 行连续缺失 2s 判仪器 probeMissing；中间有一帧看见就重新计
    func testR6C09BlindForTwoSecondsIsInstrument() {
        var w = C.Traverse.Watch()
        XCTAssertNil(w.blind(at: 10.0, "probe nil"))
        XCTAssertNil(w.blind(at: 11.9, "probe nil"))
        w.sighted()
        XCTAssertNil(w.blind(at: 12.0, "probe nil"))
        let f = w.blind(at: 14.0, "probe nil")
        XCTAssertEqual(f?.kind, .probeMissing)
        XCTAssertEqual(f?.kind.failureClass, .instrument)
    }

    /// R6 C-06 / K-03：驱动目标 offset 只按探针声明的方向与两端算——反转（旧页）与正向（UIKit 非反转）对称
    func testR6C06TargetFollowsDeclaredOrientation() {
        typealias T = C.Traverse
        // 反转列表：更旧 = offset 增，底 = −100，最旧端估算 5000；与改前旧页公式逐值相同
        for (offset, delta, older) in [(CGFloat(0), CGFloat(200), true), (50, 200, false), (4900, 200, true), (-100, 0, true)] {
            let legacy = min(max(older ? offset + delta : offset - delta, -100), max(-100, 5000))
            XCTAssertEqual(T.target(offset: offset, delta: delta, older: older, olderSign: 1, newest: -100, oldest: 5000), legacy)
        }
        XCTAssertEqual(T.target(offset: 0, delta: 200, older: true, olderSign: 1, newest: -100, oldest: -300), -100, "估算最旧端落在底的反侧：按底钳")
        // 正向列表：更旧 = offset 减，最新端 = 5000（最大），最旧端 = −100
        XCTAssertEqual(T.target(offset: 1000, delta: 200, older: true, olderSign: -1, newest: 5000, oldest: -100), 800)
        XCTAssertEqual(T.target(offset: 4900, delta: 200, older: false, olderSign: -1, newest: 5000, oldest: -100), 5000)
        XCTAssertEqual(T.target(offset: 0, delta: 200, older: true, olderSign: -1, newest: 5000, oldest: -100), -100)
        XCTAssertEqual(T.target(offset: 1000, delta: -50, older: true, olderSign: -1, newest: 5000, oldest: -100), 1050, "回找（负 delta）反向")
    }

    /// R6 C-01：10s 分箱，末箱不足照报实长
    func testR6C01Bins() {
        let b = C.Traverse.bins(from: 100, to: 125, width: 10)
        XCTAssertEqual(b.map(\.start), [100, 110, 120])
        XCTAssertEqual(b.map(\.end), [110, 120, 125])
        XCTAssertEqual(C.Traverse.bins(from: 0, to: 20, width: 10).count, 2)
        XCTAssertTrue(C.Traverse.bins(from: 5, to: 5, width: 10).isEmpty)
    }

    // MARK: 纵切 6 · 脚本流资源 / lint / turn 纯计量（§6.6）

    func testStreamScriptMatchesProtocolAndIsDeterministic() throws {
        let s = C.StreamScript.v1
        XCTAssertEqual(s.slices.joined(), s.final)
        XCTAssertEqual(s.offsets.count, s.slices.count)
        XCTAssertEqual(s.offsets.first, C.StreamScript.firstOffset)
        XCTAssertEqual(s.offsets, s.offsets.sorted(), "到达表非降序")
        XCTAssertEqual(C.StreamScript.make(id: "stream-v1", text: C.StreamScript.finalTextV1), s, "确定性：重建逐位相同")
        XCTAssertTrue((1800...2300).contains(s.final.count), "终稿 ~2000 字")
        XCTAssertTrue(s.final.contains("# ") && s.final.contains("\n- ") && s.final.contains("```swift"))
        XCTAssertTrue(s.final.components(separatedBy: "\n").contains { $0.count > 300 }, "有一段 >300 字不换行长段（同一块内增量生长的样本）")
        // 与协议 streamScripts 同源（分析器按它核 app 自报的脚本身份）
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/perf/chatv1-protocol.json")
        let proto = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let want = try XCTUnwrap((proto["streamScripts"] as? [String: Any])?[s.id] as? [String: Any])
        XCTAssertEqual(want["slices"] as? Int, s.slices.count)
        XCTAssertEqual(want["chars"] as? Int, s.final.count)
        XCTAssertEqual(want["finalDigest"] as? String, String(format: "%016llx", C.fnv1a64(s.final)))
        XCTAssertEqual(want["durationMs"] as? Double, (s.duration * 1000).rounded())
        XCTAssertEqual(want["credentialId"] as? String, C.StreamScript.credentialId)
        XCTAssertEqual(C.StreamScript.script("stream-v1"), s)
        XCTAssertNil(C.StreamScript.script("stream-v2"))
        // r10：长终稿两档同源、lint 干净、长度落在 ③ 门槛 / L1c 上限两侧
        for (long, range) in [(C.StreamScript.v7k, 6001...12000), (C.StreamScript.v15k, 12001...20000)] {
            let w = try XCTUnwrap((proto["streamScripts"] as? [String: Any])?[long.id] as? [String: Any])
            XCTAssertEqual(w["slices"] as? Int, long.slices.count, long.id)
            XCTAssertEqual(w["chars"] as? Int, long.final.count, long.id)
            XCTAssertEqual(w["finalDigest"] as? String, String(format: "%016llx", C.fnv1a64(long.final)), long.id)
            XCTAssertEqual(w["durationMs"] as? Double, (long.duration * 1000).rounded(), long.id)
            XCTAssertTrue(range.contains(long.final.count), long.id)
            XCTAssertEqual(C.StreamScript.lint(long.final), [], long.id)
            XCTAssertEqual(C.StreamScript.script(long.id), long)
        }
    }

    func testStreamScriptLint() {
        XCTAssertEqual(C.StreamScript.lint(C.StreamScript.v1.final), [])
        let bad: [(String, String)] = [
            ("```html\n<div>x</div>\n```", "fence html"), ("```voice\nhi\n```", "fence voice"),
            ("```card-timer\n{}\n```", "fence card-timer"), ("```health-log\n{}\n```", "fence health-log"),
            ("~~~mermaid\ngraph\n~~~", "fence mermaid"), ("看 https://example.com", "contains https://"),
            ("www.example.com", "contains www."), ("你好 {{char}}", "contains {{"), ("[thinking]想[/thinking]", "contains [thinking]"),
            ("<img src=x>", "html tag"), ("[链接](x)", "contains ]("),
        ]
        for (text, problem) in bad {
            XCTAssertTrue(C.StreamScript.lint(text).contains(problem), "\(text) → \(C.StreamScript.lint(text))")
        }
        XCTAssertEqual(C.StreamScript.lint("```swift\nlet a = 1 < 2\n```"), [], "白名单围栏 + 比较号不是标签")
    }

    func testTurnSupplyToRenderAndStall() {
        // 三片：应有长度 10 / 10（不变，跳过）/ 30；渲染输入 0.05 到 12、0.30 到 30
        let lat = C.Turn.chunks(arrivals: [1.0, 1.1, 1.2], targets: [10, 10, 30], render: [(1.05, 12), (1.30, 30)], from: 0, until: 2)
        XCTAssertEqual(lat.measured.count, 2)
        XCTAssertEqual(lat.measured[0], 0.05, accuracy: 1e-9)
        XCTAssertEqual(lat.measured[1], 0.10, accuracy: 1e-9)
        XCTAssertEqual(lat.censored, 0)
        let cut = C.Turn.chunks(arrivals: [1.0, 1.2], targets: [10, 30], render: [(1.05, 12), (1.30, 30)], from: 0, until: 1.25)
        XCTAssertEqual(cut.measured.count, 1)
        XCTAssertEqual(cut.censored, 1, "截止前没跟上的片计删失")
        XCTAssertEqual(cut.values.count, 2, "R7 C-07：删失片按下界进分位（修前直接扔掉）")
        XCTAssertEqual(cut.censoredBounds[0], 0.05, accuracy: 1e-9, "下界 = 截止 − 到达")
        XCTAssertEqual(C.Turn.chunks(arrivals: [1.0], targets: [10], render: [], from: 0, until: 5).censored, 1)
        // 停滞：1.0 供给 10，渲染 1.4 才到 10；1.5 供给 30，渲染到截止 2.0 都停在 10
        let stall = C.Turn.maxStall(supply: [(1.0, 10), (1.5, 30)], render: [(1.4, 10)], from: 1.0, to: 2.0)
        XCTAssertEqual(stall, 0.5, accuracy: 1e-9)
        XCTAssertEqual(C.Turn.maxStall(supply: [(1.0, 10)], render: [(1.0, 10)], from: 1.0, to: 2.0), 0, accuracy: 1e-9)
        XCTAssertEqual(C.Turn.maxStall(supply: [(0.5, 10)], render: [], from: 1.0, to: 1.8), 0.8, accuracy: 1e-9, "起点前就落后：从窗口起算")
        XCTAssertEqual(C.Turn.percentile([3, 1, 2, 4], 0.5), 2)
        XCTAssertEqual(C.Turn.percentile([3, 1, 2, 4], 0.95), 4)
        XCTAssertNil(C.Turn.percentile([], 0.5))
    }

    /// R7 C-01：渲染输入停在中途（s6-1：201 / 1969 字停 12s）= 未收敛 + 晚到（产品慢）；末尾正常删失（截止前 < 1s 到达）不判
    func testTurnStalledRenderIsNotConvergedAndLate() {
        let arrivals = stride(from: 1.0, to: 13.0, by: 0.1).map { $0 }
        let targets = arrivals.indices.map { 15 * ($0 + 1) }
        let upTo201 = arrivals.indices.filter { targets[$0] <= 201 }.map { (t: arrivals[$0] + 0.2, chars: targets[$0]) }
        let stalled = C.Turn.chunks(arrivals: arrivals, targets: targets, render: upTo201, from: 0, until: 13.0)
        XCTAssertTrue(stalled.aheadOfSupply.isEmpty)
        XCTAssertFalse(stalled.notConverged.isEmpty)
        XCTAssertFalse(stalled.late.isEmpty)
        XCTAssertTrue(stalled.notConverged.allSatisfy { 13.0 - $0.arrival >= C.Turn.Thresholds.convergeS })
        XCTAssertTrue(stalled.p95IsLowerBound, "p95 落在删失下界上")
        XCTAssertGreaterThan(C.Turn.percentile(stalled.values, 0.95) ?? 0, 10, "删失下界压上 p95：慢臂不再占便宜")
        // 正常：渲染滞后 0.2s 追上，末片在截止前 0.15s 到达没追上 → 删失但不判
        let render = arrivals.indices.map { (t: arrivals[$0] + 0.2, chars: targets[$0]) }.filter { $0.t <= 13.05 }
        let ok = C.Turn.chunks(arrivals: arrivals, targets: targets, render: render, from: 0, until: 13.05)
        XCTAssertTrue(ok.notConverged.isEmpty && ok.late.isEmpty, "\(ok.notConverged.map(\.k)) / \(ok.late.map(\.k))")
        XCTAssertEqual(ok.censored, 1)
        XCTAssertFalse(ok.p95IsLowerBound)
    }

    /// R7 C-02：只计到达在 [from, until) 的片，from 之前的片只抬高基线；K-01：流式行离开视口后的删失不可观察，单列
    func testTurnWindowAndUnobservableCensoring() {
        let w = C.Turn.chunks(arrivals: [0.5, 1.5, 2.5], targets: [10, 20, 30], render: [(0.6, 10), (1.6, 20), (2.6, 30)], from: 1.0, until: 3.0)
        XCTAssertEqual(w.chunks.map(\.k), [1, 2], "上移前到达的片不进离底窗口")
        let lost = C.Turn.chunks(arrivals: [0.5, 1.5, 2.5], targets: [10, 20, 30], render: [], from: 0, until: 3.0, lostAt: 2.0)
        XCTAssertEqual(lost.chunks.map(\.unobservable), [false, true, true])
        XCTAssertEqual(lost.censored, 1)
        XCTAssertEqual(lost.censoredUnobservable, 2)
        XCTAssertEqual(lost.notConverged.map(\.k), [0], "离开视口 1.5s 前就到的片仍算真未收敛")
        XCTAssertEqual(lost.values.count, 1, "不可观察的不进分位")
    }

    /// R7 C-07：渲染输入先于片到达就 ≥ 应有长度 = 加工链不一致（仪器），不再静默夹成 0
    func testTurnRenderAheadOfSupplyAndThresholdsMatchProtocol() throws {
        let a = C.Turn.chunks(arrivals: [1.0], targets: [10], render: [(0.9, 12)], from: 0, until: 2)
        XCTAssertEqual(a.aheadOfSupply, [0])
        XCTAssertEqual(C.FailureKind.renderAheadOfSupply.failureClass, .instrument)
        XCTAssertEqual(C.FailureKind.streamLate.failureClass, .productSlow)
        XCTAssertEqual(C.FailureKind.streamNotConverged.failureClass, .productSlow)
        XCTAssertEqual(C.FailureKind.anchorDrift.failureClass, .correctness)
        XCTAssertEqual(C.FailureKind.followLost.failureClass, .correctness)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/perf/chatv1-protocol.json")
        let proto = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let th = try XCTUnwrap(proto["turnThresholds"] as? [String: Any])
        typealias T = C.Turn.Thresholds
        XCTAssertEqual(th["chunkLateS"] as? Double, T.chunkLateS)
        XCTAssertEqual(th["convergeS"] as? Double, T.convergeS)
        XCTAssertEqual(th["anchorDriftMaxPt"] as? Double, T.anchorDriftMaxPt)
        XCTAssertEqual(th["followEndMaxPt"] as? Double, T.followEndMaxPt)
        XCTAssertEqual(th["offBottomHeldMinPt"] as? Double, T.offBottomHeldMinPt)
        XCTAssertEqual(th["shiftKeepFrac"] as? Double, T.shiftKeepFrac)
        XCTAssertEqual(th["shiftScreenFrac"] as? Double, T.shiftScreenFrac)
        XCTAssertEqual(th["finishVisibleMinFrac"] as? Double, T.finishVisibleMinFrac)
    }

    /// R7-10：收尾落点可见比例，分母 = min(行高, 视口高)
    func testTurnFinishVisibleFraction() {
        XCTAssertEqual(C.Turn.visibleFraction(rowMinY: 200, rowMaxY: 500, viewportMinY: 100, viewportMaxY: 662), 1, accuracy: 1e-9)
        XCTAssertEqual(C.Turn.visibleFraction(rowMinY: 500, rowMaxY: 800, viewportMinY: 100, viewportMaxY: 662), 162.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(C.Turn.visibleFraction(rowMinY: 0, rowMaxY: 3000, viewportMinY: 100, viewportMaxY: 662), 1, accuracy: 1e-9, "比视口高的行铺满视口即可")
        XCTAssertEqual(C.Turn.visibleFraction(rowMinY: 700, rowMaxY: 900, viewportMinY: 100, viewportMaxY: 662), 0)
    }

    /// §14-98：离底上移固定 0.75 屏（屏 = scroll view 高 844，产品松手回底阈值 = 半屏 422）；上移后流式行顶边须在有效视口底上方 ≥ 0.25 视口高，不够就等行再长
    func testTurnPlannedShiftCrossesHalfScreenAndKeepsStreamRowInViewport() throws {
        // mask：有效视口 [100, 662]（高 562），屏 844 → 上移 633；流式行顶 −50 → 上移后行顶 583，离视口底 79 < 140.5：等
        XCTAssertNil(C.Turn.plannedShift(streamRowMinY: -50, viewportMaxY: 662, viewportHeight: 562, screenHeight: 844))
        let p = try XCTUnwrap(C.Turn.plannedShift(streamRowMinY: -120, viewportMaxY: 662, viewportHeight: 562, screenHeight: 844))
        XCTAssertEqual(p.shift, 633, accuracy: 1e-9)
        XCTAssertEqual(p.keep, 149, accuracy: 1e-9)
        XCTAssertGreaterThan(p.shift, 844 / 2, "越过产品松手回底阈值（半屏）")
        XCTAssertLessThan(-120 + p.shift, 662, "上移后行顶仍在有效视口内")
        XCTAssertGreaterThanOrEqual(p.keep, 562 * C.Turn.Thresholds.shiftKeepFrac)
    }

    func testTurnFailureClass() {
        XCTAssertEqual(C.FailureKind.streamNoProgress.failureClass, .correctness)
        XCTAssertEqual(C.FailureKind.turnTimeout.failureClass, .productSlow)
        // 墙钟锚定：脚本 13.8s 在每 tick 1s 的慢臂上终片时刻不拉长（成簇到达）
        let s = C.StreamScript.v1
        var sched = C.ArrivalSchedule(offsets: s.offsets, anchor: 0)
        var t = 0.0
        var lastTick = 0.0
        while !sched.isFinished { t += 1; if !sched.due(at: t).isEmpty { lastTick = t } }
        XCTAssertEqual(lastTick, s.duration.rounded(.up))
    }
}
#endif
