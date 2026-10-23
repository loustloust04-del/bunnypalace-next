#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation
import UIKit

/// 纵切 5 · 深翻 3000 条（plan-chat-list-perf-p0 §6.5）：deepSession = 一个遍历 session（coldUp 底 → 最旧端，returnDown 回底），
/// deepJump = 产品「滚到最旧 / 回底」收敛冒烟。驱动在 ChatV1Sampler 的 display-link 回调里逐帧程序化写 contentOffset
/// （driver = synthetic），位置递推：每帧读实际 offset 再走一步，钉位 / 估高修正自然吸收（参照 ChatPerfBench 的递推，那个文件 PERF 包不编）。
/// 每帧推进 ≤ min(speed × dt, stepCapFrac × 有效视口高)，下一个必经检查点已实化就截到它刚好进视口、越过了就回找、视口没行就原地等。
/// 判据只经 ChatListProbe 的行 window rect 与渲染账本；滚动几何（更旧方向、两端 offset、deepJump 入口）也只经探针（R6 C-06 / K-03），
/// 驱动不认识具体列表实现；run JSON 字段契约 = scripts/perf/testdata/chatv1/traverse-*.json
@MainActor
final class TraverseOcc {
    typealias Core = PerfChatCore
    typealias T = PerfChatCore.Traverse
    enum Mode { case session, jump }
    enum Phase: String { case coldUp, returnDown }

    struct Params {
        let speed: Double
        let stepCapFrac: Double
        let phaseCap: Double
        let checkpointWait: Bool
        let stepCap: Bool

        /// 标定值由块清单经 MP_PERF_DEEP_* 传入（缺省 = plan §6.5 默认）；两个开关只由测试钩子关（正式轮分析器判 configMismatch）
        static func fromEnv() -> Params {
            let e = PerfHarness.env
            return Params(speed: Double(e["MP_PERF_DEEP_SPEED"] ?? "") ?? 12000,
                          stepCapFrac: Double(e["MP_PERF_DEEP_STEPCAP"] ?? "") ?? 0.8,
                          phaseCap: Double(e["MP_PERF_DEEP_TIMECAP"] ?? "") ?? 60,
                          checkpointWait: e["MP_PERF_TEST_CHECKPOINT_WAIT"] != "0",
                          stepCap: e["MP_PERF_TEST_STEP_CAP"] != "0")
        }
    }

    /// 帧时长按上一帧的决定归类：free = 移动；capped / seek / hold = 检查点等待；endWait = 到了估算端点原地等
    enum FrameClass: String { case free, capped, seek, hold, endWait }

    /// R6 C-03 / C-08：阶段起止时的产品路径登记开销与 markdown 缓存查找计数（全局单调，做差）
    struct InlineSnapshot {
        let seconds: Double
        let calls: Int
        let mdHit: Int
        let mdMiss: Int
        static var now: InlineSnapshot {
            InlineSnapshot(seconds: PerfInlineCost.seconds, calls: PerfInlineCost.calls, mdHit: PerfInlineCost.mdHit, mdMiss: PerfInlineCost.mdMiss)
        }
    }

    final class PhaseStats {
        let phase: Phase
        let start: Double
        var end: Double?
        var distance: CGFloat = 0
        var visited = Set<Int>()
        /// R6 K-06：本阶段驱动收到的 display-link 回调数（含探针缺失早退的帧）
        var callbacks = 0
        /// R6 C-04：本阶段有效视口高最小值（分析器离线核步长上限）
        var viewportMin = CGFloat.infinity
        let inline0 = InlineSnapshot.now
        var inline1: InlineSnapshot?
        /// 探针诊断：行登记表（LazyVStack 留在窗口里的行 = 每帧扫描量）峰值
        var registryMax = 0
        var csChanges = 0
        var t: [Double] = []
        var requested: [Double] = []
        var actual: [Double] = []
        var hits: [Int: Double] = [:]
        var nextCheckpoint = 0

        init(_ phase: Phase, start: Double) {
            self.phase = phase
            self.start = start
        }
    }

    let mode: Mode
    let params: Params
    let target: LoadOcc.Target
    let reqId: Int
    let t0: Double
    let rows: [String]
    private let index: [String: Int]
    /// 检查点下标：升序（回程顺序）/ 降序（上行顺序）
    let checkpoints: [Int]
    private let checkpointsDesc: [Int]
    private let checkpointSet: Set<Int>
    let longIndices: [Int]
    private(set) var tracker: Core.OpTracker
    private(set) var phase: Phase = .coldUp
    private(set) var stats: [Phase: PhaseStats] = [:]
    private(set) var failures: [Core.Failure] = []
    private(set) var censoredAt: Double?
    private(set) var oldestId: String?
    private(set) var newestId: String?
    private(set) var longCaptures: [(id: String, phase: Phase, digestOK: Bool, consumedT: Double?)] = []
    private(set) var jump: [String: Double] = [:]
    private(set) var memoryBaseline: Double
    private(set) var memoryPeak: Double
    private(set) var memoryEnd: Double?
    let pins0: Int
    let glides0: Int
    private var nextMemory = 0.0
    private var lastTick: Double?
    private var lastClass: FrameClass?
    private var lastPhase: Phase = .coldUp
    /// 帧区间 [上一帧, 这一帧) 归上一帧的决定；报告时按阶段区间裁剪（阶段边界那帧不重复记）
    private(set) var spans: [(a: Double, b: Double, c: FrameClass)] = []
    /// 驱动写 offset 的调用区间：setContentOffset 里同步触发的产品滚动工作（LazyVStack 实化行等）算产品忙，不算探针自耗
    private(set) var writes: [Core.Interval] = []
    private var lastOffset: CGFloat?
    private var lastCS: CGFloat?
    private var stability: Core.ChainStability
    /// deepJump：目标端行在视口内且 offset 不变的连串起点
    private var quietSince: Double?
    private var bottomCalledAt: Double?
    /// R6 C-09：request 时的挂载代际；遍历中换代 = correctness/extraRemount
    let mountGen0: Int
    /// R6 C-05 / C-09：检查点漏登记、探针 / 视口 / 行连续缺失 → 仪器（不让驱动空转到 timeCap 记成产品慢）
    private var watch = Core.Traverse.Watch()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var finished = false

    init(mode: Mode, params: Params, target: LoadOcc.Target, reqId: Int, t0: Double) {
        self.mode = mode
        self.params = params
        self.target = target
        self.reqId = reqId
        self.t0 = t0
        rows = target.expectedRows
        index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, $0) })
        let f = Core.Fixture.D
        checkpoints = T.checkpoints(count: rows.count, every: 100, long: f.longIndices)
        checkpointsDesc = checkpoints.reversed()
        checkpointSet = Set(checkpoints)
        longIndices = f.longIndices
        tracker = Core.OpTracker(spec: .traverse(phaseTimeout: params.phaseCap), reqId: reqId, t0: t0)
        stability = Core.ChainStability(scale: UIScreen.main.scale)
        memoryBaseline = PerfHarness.footprintMiB()
        memoryPeak = memoryBaseline
        pins0 = PerfChatV1.pins
        glides0 = PerfChatV1.glides
        mountGen0 = ChatListProbe.mountGen
        stats[.coldUp] = PhaseStats(.coldUp, start: t0)
    }

    var endTime: Double { tracker.times[.returnDownEnd] ?? censoredAt ?? lastTick ?? t0 }

    // MARK: 逐帧

    func tick(_ now: Double) {
        guard !finished else { return }
        // 上一帧的决定管到这一帧（时长按阶段区间在报告时裁剪）；位移记在做决定的那个阶段
        let decided = lastPhase
        if let prev = lastTick, let c = lastClass { spans.append((prev, now, c)) }
        let dt = lastTick.map { now - $0 } ?? 0
        lastTick = now
        lastClass = .hold
        lastPhase = phase
        stats[phase]?.callbacks += 1
        let phaseStart = phase == .coldUp ? t0 : (tracker.times[.coldUpEnd] ?? t0)
        if now - phaseStart > params.phaseCap {
            censoredAt = now
            fail(.traversalTimeCap, "\(phase.rawValue) not reached within \(Int(params.phaseCap))s")
            finish()
            return
        }
        if now >= nextMemory {
            memoryPeak = max(memoryPeak, PerfHarness.footprintMiB())
            nextMemory = now + 0.25
        }
        if ChatListProbe.mountGen != mountGen0 {
            fail(.extraRemount, "list remounted during traverse (mountGen \(mountGen0) → \(ChatListProbe.mountGen))")
            return
        }
        guard let probe = ChatListProbe.current else { return blindFrame(now, "probe nil") }
        guard probe.conversationId == target.conv.id else {
            fail(.identityMismatch, "probe conversation \(probe.conversationId ?? "nil") != D during traverse")
            return
        }
        guard let sv = probe.scrollView, let window = sv.window, let visible = probe.viewportRect(in: window),
              let vp = Core.effectiveViewport(visible, occlusion: probe.occlusion), let st = stats[phase] else {
            return blindFrame(now, "scrollView / viewport unavailable")
        }
        st.viewportMin = min(st.viewportMin, vp.height)
        let offset = sv.contentOffset.y
        if let lo = lastOffset { stats[decided]?.distance += abs(offset - lo) }
        lastOffset = offset
        let cs = sv.contentSize.height
        if let c = lastCS, abs(c - cs) > 0.5 { st.csChanges += 1 }
        lastCS = cs

        // 行：实化区间、进视口的行、检查点命中（登记表 = LazyVStack 留在窗口里的行，O(实化行)）
        st.registryMax = max(st.registryMax, PerfRowRegistry.count)
        var rects: [String: CGRect] = [:]
        var realizedLo = Int.max, realizedHi = Int.min
        for r in probe.visibleRows(in: window) {
            guard let i = index[r.id] else { continue }
            rects[r.id] = r.windowRect
            realizedLo = min(realizedLo, i)
            realizedHi = max(realizedHi, i)
            guard r.windowRect.maxY > vp.minY, r.windowRect.minY < vp.maxY else { continue }
            st.visited.insert(i)
            if checkpointSet.contains(i), st.hits[i] == nil {
                st.hits[i] = now
                if longIndices.contains(i) { captureLong(i, phase: phase) }
            }
        }
        let realized = realizedLo <= realizedHi ? realizedLo...realizedHi : nil
        if realized == nil {
            if let f = watch.blind(at: now, "no registered rows in viewport") {
                fail(f.kind, f.detail)
                finish()
                return
            }
        } else {
            watch.sighted()
        }

        // 端点
        switch (mode, phase) {
        case (.session, .coldUp):
            if st.visited.contains(0) {
                endColdUp(at: now)
                record(st, now, offset, offset, .free)
                return
            }
        case (.session, .returnDown):
            if st.visited.contains(rows.count - 1), let e = chainStable(rects: rects, vp: vp, probe: probe, window: window, now: now) {
                tracker.record(.returnDownEnd, at: e.at)
                newestId = e.newest
                st.end = e.at
                record(st, now, offset, offset, .endWait)
                finish()
                return
            }
        case (.jump, _):
            jumpTick(st, now: now, offset: offset, probe: probe, rects: rects, vp: vp)
            return
        }

        // 驱动（session）：下一个没命中的检查点决定步长
        let older = phase == .coldUp
        let order = older ? checkpointsDesc : checkpoints
        while st.nextCheckpoint < order.count, st.hits[order[st.nextCheckpoint]] != nil { st.nextCheckpoint += 1 }
        let relation: T.Relation
        let next = st.nextCheckpoint < order.count ? order[st.nextCheckpoint] : nil
        if let c = next {
            relation = T.relation(older: older, rect: rects[rows[c]], index: c, viewport: vp, realized: realized)
        } else {
            relation = realized == nil ? .noRows : .inView
        }
        if let range = realized {
            let unregistered = next.map { rects[rows[$0]] == nil && range.contains($0) } ?? false
            if let f = watch.feed(checkpoint: next, relation: relation, unregisteredInRange: unregistered) {
                fail(f.kind, f.detail)
                finish()
                return
            }
        }
        guard let newest = probe.newestOffset(), let oldest = probe.oldestOffsetEstimate() else {
            return blindFrame(now, "list ends unavailable")
        }
        let nominal = T.nominal(speed: params.speed, dt: dt, viewportHeight: vp.height, stepCapFrac: params.stepCapFrac, stepCap: params.stepCap)
        let step = T.step(nominal: nominal, relation: relation, checkpointWait: params.checkpointWait,
                          seekCap: CGFloat(params.stepCapFrac) * vp.height)
        let target = T.target(offset: offset, delta: step.delta, older: older, olderSign: probe.olderOffsetSign, newest: newest, oldest: oldest)
        var cls = FrameClass(rawValue: step.kind.rawValue) ?? .free
        if step.delta > 0, abs(target - offset) < 0.5 { cls = .endWait }   // 顶到估算端点：等 LazyVStack 量完内容往外长
        if abs(target - offset) > 0.01 {
            let w0 = CACurrentMediaTime()
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: false)
            writes.append(Core.Interval(start: w0, end: CACurrentMediaTime()))
        }
        record(st, now, offset, target, cls)
    }

    /// 探针 / 视口 / 端点缺失的帧：记 hold；连续 Watch.blindSeconds 判仪器 probeMissing 并收尾
    private func blindFrame(_ now: Double, _ what: String) {
        guard let f = watch.blind(at: now, what) else { return }
        fail(f.kind, f.detail)
        finish()
    }

    private func record(_ st: PhaseStats, _ now: Double, _ actual: CGFloat, _ requested: CGFloat, _ cls: FrameClass) {
        st.t.append((now * 10_000).rounded() / 10_000)
        st.actual.append((Double(actual) * 10).rounded() / 10)
        st.requested.append((Double(requested) * 10).rounded() / 10)
        lastClass = cls
    }

    /// returnStart：回程阶段统计窗口起点（deepJump = 调 scrollToNewest 那一刻，不含 0.5s 收敛确认窗，R6 K-04 / C-11）
    private func endColdUp(at now: Double, returnStart: Double? = nil) {
        tracker.record(.coldUpEnd, at: now)
        oldestId = rows[0]
        stats[.coldUp]?.end = now
        stats[.coldUp]?.inline1 = .now
        stats[.returnDown] = PhaseStats(.returnDown, start: returnStart ?? now)
        phase = .returnDown
        stability.reset()
    }

    /// returnDown 端点：贴底成链（§4.4-3，最新行离视口底 ≤ 间距 + 1px）且整链稳定，回溯连串首样本（§14-51）
    private func chainStable(rects: [String: CGRect], vp: CGRect, probe: any ChatListProbing, window: UIWindow,
                             now: Double) -> (at: Double, newest: String)? {
        guard case .complete(let chain) = Core.messageChain(expected: rows, rects: rects, viewport: vp,
                                                            spacing: probe.declaredRowSpacing, scale: window.screen.scale) else {
            stability.reset()
            return nil
        }
        let sample = chain.compactMap { id in rects[id].map { Core.ChainRow(id: id, minY: $0.minY, maxY: $0.maxY) } }
        guard let since = stability.feed(sample, at: now), let newest = chain.first else { return nil }
        return (since, newest)
    }

    /// deepJump：不写 offset，只看产品滚动收敛——目标端行在有效视口内且 offset 连续 0.5s 不变（≤ 1 物理像素），取不变连串起点
    private func jumpTick(_ st: PhaseStats, now: Double, offset: CGFloat, probe: any ChatListProbing, rects: [String: CGRect], vp: CGRect) {
        let targetIndex = phase == .coldUp ? 0 : rows.count - 1
        let tol = 1 / UIScreen.main.scale + 1e-6
        let prev = st.actual.last.map { CGFloat($0) }
        record(st, now, offset, offset, .free)
        guard st.visited.contains(targetIndex), let r = rects[rows[targetIndex]], r.maxY > vp.minY, r.minY < vp.maxY,
              let p = prev, abs(offset - p) <= tol else {
            quietSince = nil
            return
        }
        if quietSince == nil { quietSince = st.t.dropLast().last ?? now }
        guard let q = quietSince, now - q >= 0.5 else { return }
        quietSince = nil
        if phase == .coldUp {
            jump["convergeOldestMs"] = (q - t0) * 1000
            jump["oldestOffsetErrorPt"] = Double(offset - (probe.oldestOffsetEstimate() ?? offset))
            jump["oldestTopGapPt"] = Double(r.minY - vp.minY)
            jump["confirmWindowMs"] = (now - q) * 1000
            endColdUp(at: q, returnStart: now)
            bottomCalledAt = now
            probe.scrollToNewest()
        } else {
            tracker.record(.returnDownEnd, at: q)
            newestId = rows[targetIndex]
            st.end = q
            jump["convergeBottomMs"] = (q - (bottomCalledAt ?? q)) * 1000
            jump["bottomOffsetErrorPt"] = Double(offset - (probe.newestOffset() ?? offset))
            jump["newestBottomGapPt"] = Double(vp.maxY - r.maxY)
            finish()
        }
    }

    /// D 长文进视口那刻的消费回执（§5.3）：摘要对 fixture；没有回执 = 探针缺登记（仪器），摘要不对 = 正文错（正确性）
    private func captureLong(_ i: Int, phase: Phase) {
        let id = rows[i]
        guard let c = PerfRenderLedger.consumed[id], let d = c.digest else {
            fail(.probeMissing, "long node \(id) entered viewport in \(phase.rawValue) without a consumed receipt")
            longCaptures.append((id, phase, false, nil))
            return
        }
        let ok = d == target.digests[id]
        if !ok { fail(.contentMismatch, "long node \(id) consumed digest != fixture (\(phase.rawValue))") }
        longCaptures.append((id, phase, ok, c.t))
    }

    func startJump() {
        ChatListProbe.current?.scrollToOldest()
    }

    func fail(_ kind: Core.FailureKind, _ detail: String) {
        failures.append(Core.Failure(kind, detail))
        if kind.failureClass == .correctness { finish() }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        if stats[phase]?.inline1 == nil { stats[phase]?.inline1 = .now }
        memoryEnd = PerfHarness.footprintMiB()
        memoryPeak = max(memoryPeak, memoryEnd ?? 0, memoryBaseline)
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }

    /// 两阶段各自没命中的检查点（deepSession；两端都到了才判）
    var missing: [Phase: [Int]] {
        guard mode == .session else { return [:] }
        var out: [Phase: [Int]] = [:]
        for (p, st) in stats {
            let m = T.missing(planned: checkpoints, hits: Set(st.hits.keys))
            if !m.isEmpty { out[p] = m }
        }
        return out
    }

    var status: String {
        if failures.contains(where: { $0.kind.failureClass == .correctness }) { return "correctness" }
        if failures.contains(where: { $0.kind.failureClass == .instrument }) { return "instrument" }
        if failures.contains(where: { $0.kind.failureClass == .productSlow }) { return "productSlow" }
        return "ok"
    }
}

// MARK: - 编排与报告

@MainActor
enum ChatV1Traverse {
    typealias Core = PerfChatCore
    static var active: TraverseOcc?

    /// setup（打开 D 落定 + 1.5s 尾窗）之后调；返回 occurrence 报告（字段契约 = traverse-*.json）
    static func run(op: String, target: LoadOcc.Target, prestate: String?) async -> [String: Any] {
        if let bad = prestate {
            Driver.chatFail(.navigationMismatch, "prestate: \(bad)", occ: 1)
            return ["occ": 1, "target": "D", "status": "correctness"]
        }
        let mode: TraverseOcc.Mode = op == "deepJump" ? .jump : .session
        let occ = TraverseOcc(mode: mode, params: .fromEnv(), target: target, reqId: ChatV1Load.issueReq(), t0: CACurrentMediaTime())
        // 观察集收窄到检查点（含长文）：只对它们当场算正文摘要，其余行只记 nodeId（§5.2；C-11 深翻前再看成本）
        PerfRenderLedger.observed = Set(occ.checkpoints.map { occ.rows[$0] })
        ChatV1Load.emit(.request, occ: 1)
        active = occ
        if mode == .jump { occ.startJump() }
        await occ.wait()
        active = nil
        let r = report(occ)
        for f in occ.failures { Driver.chatFail(f.kind, f.detail, occ: 1) }
        return r
    }

    private static func report(_ o: TraverseOcc) -> [String: Any] {
        let missing = o.missing
        let reached = o.tracker.times[.returnDownEnd] != nil
        if reached, !missing.isEmpty {
            let detail = missing.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) missing \($0.value.count)/\(o.checkpoints.count) \($0.value.prefix(4).map { o.rows[$0] })" }
            o.fail(.configMismatch, "uncovered: " + detail.joined(separator: "; "))
        }
        if o.status == "ok", case .failed(let f) = o.tracker.evaluate(now: CACurrentMediaTime()) { o.fail(f.kind, "endpoints: \(f.detail)") }
        // complete = 两端都到且检查点全中；没到端又没超时 = 仪器 / 正确性中止（R6 C-05 / C-09 后 instrument 也会提前收尾）
        let endReason: String = o.censoredAt != nil ? "timeCap" : (!reached ? "aborted" : (missing.isEmpty ? "complete" : "uncovered"))
        var out: [String: Any] = ["occ": 1, "target": "D", "cacheState": "cold", "ordinal": 1, "reqId": o.reqId, "driver": "synthetic"]
        var ep: [String: Any] = [:]
        for (e, t) in o.tracker.times { ep[e.rawValue] = t }
        out["endpoints"] = ep
        if let c = o.censoredAt { out["censoredAtMs"] = ChatV1Load.ms3(c - o.t0) }
        let end = o.endTime
        let segments = MainBlockMonitor.splitIntervals(now: CACurrentMediaTime())
        let samples = ChatV1Load.sampler.samples
        func frames(_ a: Double, _ b: Double) -> (gaps: Core.FrameGaps?, lead: Double) {
            let inWindow = samples.filter { $0.arrival >= a && $0.arrival <= b }
            guard !inWindow.isEmpty else { return (nil, 0) }   // R6 K-05：窗口里没有回调 = 不可测（null），不报 0
            let frameEnd = max(b, inWindow.last?.timestamp ?? b)   // §14-30：timestamp 领先送达 ≈2ms
            let lead = inWindow.map { $0.timestamp - $0.arrival }.max() ?? 0
            switch Core.frameGaps(inWindow, from: a, to: frameEnd, previous: samples.last(where: { $0.arrival < a })) {
            case .success(let g): return (g, lead)
            case .failure(let f): o.fail(f.kind, "frameGaps: \(f.detail)"); return (nil, lead)
            }
        }
        var metrics: [String: Any] = [:]
        let whole = frames(o.t0, end)
        if let g = whole.gaps {
            metrics["callbackGapExcess"] = (g.callbackGapExcess * 1000).rounded() / 1000
            metrics["worstGapMs"] = ChatV1Load.ms3(g.worstGapMs / 1000)
            metrics["callbacks"] = g.callbacks
        }
        metrics["timestampLeadMaxMs"] = ChatV1Load.ms3(whole.lead)
        let busy = Core.busy(segments, in: Core.Interval(start: o.t0, end: end))
        metrics["busyRatio"] = end > o.t0 ? ((busy / (end - o.t0)) * 10_000).rounded() / 10_000 : 0
        metrics["busyMs"] = ChatV1Load.ms3(busy)
        func gapAny(_ g: Core.FrameGaps?) -> Any { g.map { ($0.callbackGapExcess * 1000).rounded() / 1000 } as Any? ?? NSNull() }
        func ratio(_ busyS: Double, _ a: Double, _ b: Double) -> Any { b > a ? ((busyS / (b - a)) * 10_000).rounded() / 10_000 : NSNull() }
        // R6 C-01 / C-02：10s 分箱时间线（看形状不只看均值）+ 相位切换点前后 ±10s 对比
        let bins = Core.Traverse.bins(from: o.t0, to: end, width: 10)
        let binGaps = bins.map { frames($0.start, $0.end).gaps }
        let timeline: [String: Any] = [
            "binS": 10,
            "startMs": bins.map { ChatV1Load.ms3($0.start - o.t0) },
            "endMs": bins.map { ChatV1Load.ms3($0.end - o.t0) },
            "callbackGapExcess": binGaps.map(gapAny),
            "busyRatio": bins.map { ratio(Core.busy(segments, in: $0), $0.start, $0.end) },
            "callbacks": binGaps.map { $0?.callbacks ?? 0 },
            "thermal": bins.map { ChatV1Load.thermalState(at: $0.end) },
        ]
        func side(_ a: Double, _ b: Double) -> [String: Any] {
            guard b > a else { return ["spanMs": 0, "callbackGapExcess": NSNull(), "busyRatio": NSNull()] }
            return ["spanMs": ChatV1Load.ms3(b - a), "callbackGapExcess": gapAny(frames(a, b).gaps),
                    "busyRatio": ratio(Core.busy(segments, in: Core.Interval(start: a, end: b)), a, b)]
        }
        let switchAt = o.tracker.times[.coldUpEnd]
        let switchWindow: [String: Any] = [
            "halfS": 10,
            "atMs": switchAt.map { ChatV1Load.ms3($0 - o.t0) } as Any? ?? NSNull(),
            "before": switchAt.map { side(max(o.t0, $0 - 10), $0) } ?? side(0, 0),
            "after": switchAt.map { side($0, min(end, $0 + 10)) } ?? side(0, 0),
        ]
        var waitTotal = 0.0
        var phases: [String: Any] = [:]
        var visitedAll = Set<Int>()
        var csTotal = 0
        for p in [TraverseOcc.Phase.coldUp, .returnDown] {
            guard let st = o.stats[p] else { continue }
            let pe = st.end ?? end
            let wall = pe - st.start
            var ms: [TraverseOcc.FrameClass: Double] = [:]
            var frameCounts: [String: Int] = [:]
            for sp in o.spans {
                let ov = min(sp.b, pe) - max(sp.a, st.start)
                guard ov > 0 else { continue }
                ms[sp.c, default: 0] += ov
                frameCounts[sp.c.rawValue, default: 0] += 1
            }
            let wait = (ms[.capped] ?? 0) + (ms[.seek] ?? 0) + (ms[.hold] ?? 0)
            waitTotal += wait
            visitedAll.formUnion(st.visited)
            csTotal += st.csChanges
            let span = Core.Interval(start: st.start, end: pe)
            let pb = Core.busy(segments, in: span)
            let pf = frames(st.start, pe)
            let kpt = Double(st.distance) / 1000
            let i1 = st.inline1 ?? .now
            phases[p.rawValue] = [
                "direction": p == .coldUp ? "older" : "newer",
                "cacheState": p == .coldUp ? "cold" : "revisit",
                "distancePt": (Double(st.distance) * 10).rounded() / 10,
                "movingMs": ChatV1Load.ms3(ms[.free] ?? 0),
                "checkpointWaitMs": ChatV1Load.ms3(wait),
                "endWaitMs": ChatV1Load.ms3(ms[.endWait] ?? 0),
                "wallMs": ChatV1Load.ms3(wall),
                "rowsVisitedCount": st.visited.count,
                "idRange": st.visited.isEmpty ? NSNull() : [st.visited.min()!, st.visited.max()!] as Any,
                "csChanges": st.csChanges,
                "busyMs": ChatV1Load.ms3(pb),
                "busyRatio": wall > 0 ? ((pb / wall) * 10_000).rounded() / 10_000 : 0,
                // 回调总耗时扣掉写 offset 那一下（同步触发的产品滚动工作归产品忙，单报 writeMs）
                "probeSelfMs": ChatV1Load.ms3(max(0, Core.busy(ChatV1Load.sampler.selfIntervals, in: span) - Core.busy(o.writes, in: span))),
                "writeMs": ChatV1Load.ms3(Core.busy(o.writes, in: span)),
                "callbackGapExcess": gapAny(pf.gaps),
                "worstGapMs": pf.gaps.map { ChatV1Load.ms3($0.worstGapMs / 1000) } as Any? ?? NSNull(),
                // R6 C-07：按距离归一（两臂单程距离相同；等待帧不摊薄）
                "busyMsPerKPt": kpt > 0 ? ChatV1Load.ms3(pb / kpt) : NSNull(),
                "gapExcessMsPerKPt": kpt > 0 ? pf.gaps.map { ((($0.callbackGapExcess * wall) / kpt) * 1000).rounded() / 1000 } as Any? ?? NSNull() : NSNull(),
                // R6 C-04：本阶段有效视口高最小值，分析器离线核 max|Δactual| ≤ stepCapFrac × 它
                "viewportHeightPt": st.viewportMin.isFinite ? (Double(st.viewportMin) * 10).rounded() / 10 : NSNull(),
                // R6 C-03：MarkdownRenderCache 查找（init + task 各一次）命中 / 未命中；R6 C-08：回调外产品路径上的测量登记开销
                "mdCacheHit": i1.mdHit - st.inline0.mdHit,
                "mdCacheMiss": i1.mdMiss - st.inline0.mdMiss,
                "probeInlineMs": ChatV1Load.ms3(i1.seconds - st.inline0.seconds),
                "probeInlineCalls": i1.calls - st.inline0.calls,
                "frames": st.callbacks,
                "stepFrames": frameCounts,
                "hitsCount": st.hits.count,
                "registryMax": st.registryMax,
                "samples": ["t": st.t, "requested": st.requested, "actual": st.actual],
            ] as [String: Any]
        }
        if o.mode == .session { metrics["checkpointWaitMs"] = ChatV1Load.ms3(waitTotal) }
        out["metrics"] = metrics
        var ev: [String: Any] = [
            "driver": "synthetic", "reqId": o.reqId, "endReason": endReason,
            "ends": ["oldestId": o.oldestId as Any? ?? NSNull(), "newestId": o.newestId as Any? ?? NSNull()],
            "phases": phases, "rowsVisitedCount": visitedAll.count, "csChanges": csTotal,
            "pins": PerfChatV1.pins - o.pins0, "glides": PerfChatV1.glides - o.glides0,
            "memory": ["baselineMiB": o.memoryBaseline, "peakMiB": o.memoryPeak, "endMiB": o.memoryEnd ?? o.memoryPeak],
            "timeline": timeline, "switchWindow": switchWindow,
        ]
        switch o.mode {
        case .session:
            ev["params"] = ["speedPtPerS": o.params.speed, "stepCapFrac": o.params.stepCapFrac, "phaseTimeCapS": o.params.phaseCap,
                            "checkpointWait": o.params.checkpointWait, "stepCap": o.params.stepCap]
            var cps: [String: Any] = [:]
            for p in [TraverseOcc.Phase.coldUp, .returnDown] {
                var hits: [String: Double] = [:]
                for (i, t) in o.stats[p]?.hits ?? [:] { hits[o.rows[i]] = t }
                cps[p.rawValue] = hits
            }
            ev["checkpoints"] = cps
            ev["checkpointsPlanned"] = o.checkpoints.count
            ev["longNodes"] = o.longCaptures.map { c -> [String: Any] in
                let st = o.stats[c.phase]
                let a = st?.start ?? o.t0, b = st?.end ?? end
                let kinds = (PerfRenderLedger.markdownIndex[c.id] ?? []).compactMap { i -> String? in
                    let m = PerfRenderLedger.markdown[i]
                    return m.t >= a && m.t <= b ? m.kind : nil
                }
                return ["nodeId": c.id, "phase": c.phase.rawValue, "cacheState": c.phase == .coldUp ? "cold" : "revisit",
                        "digestOK": c.digestOK, "consumedT": c.consumedT as Any? ?? NSNull(), "kinds": kinds]
            }
        case .jump:
            // 两端都收敛才给完整 jump；超时的只给已有的（jumpPartial，不进契约），免得半截对象被当形状错
            let rounded = o.jump.mapValues { ($0 * 1000).rounded() / 1000 }
            ev[rounded.count == 7 ? "jump" : "jumpPartial"] = rounded
        }
        out["evidence"] = ev
        out["status"] = o.status
        return out
    }
}
#endif
