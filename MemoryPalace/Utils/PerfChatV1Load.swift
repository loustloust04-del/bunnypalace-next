#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation
import SwiftData
import SwiftStreamingMarkdown
import UIKit
import os

/// 纵切 4 · 加载类 occurrence（plan-chat-list-perf-p0 §4 / §6.2–6.4 / §6.7）：S1 inplaceLoad、S3 openConv.v1、
/// 搜索跳转与 A→B→A 冒烟。产品侧插入点只经下面的 nonisolated 钩子报事件（全部在主线程上被调），
/// 判定与计量都在这里 + PerfChatCore；run JSON 字段以 scripts/perf/testdata/chatv1/load-complete.json 为准。
enum PerfChatV1 {
    nonisolated(unsafe) private static var pendingResyncTrigger = ""

    // MARK: 产品侧钩子（VM / PagingViewController / 注册表；调用方已判 strictMeasure）

    static func loadSync(req: Int, begin: Double, end: Double) {
        MainActor.assumeIsolated { ChatV1Load.active?.noteTask("loadSync", req: req, begin: begin, end: end) }
    }

    static func applyDropped(req: Int) {
        MainActor.assumeIsolated {
            ChatV1Load.applyLog.append(.init(req: req, t: CACurrentMediaTime(), dropped: true, changedRows: false))
            ChatV1Load.active?.noteDropped(req: req)
        }
    }

    static func applyDone(req: Int, begin: Double, end: Double, revision: Int, rowsBefore: [String], rowsAfter: [String],
                          nodeBefore: String?, nodeAfter: String?) {
        MainActor.assumeIsolated {
            ChatV1Load.applyLog.append(.init(req: req, t: end, dropped: false, changedRows: rowsBefore != rowsAfter))
            ChatV1Load.active?.noteApply(req: req, begin: begin, end: end, revision: revision,
                                         changedRows: rowsBefore != rowsAfter, changedNode: nodeBefore != nodeAfter)
        }
    }

    static func noteMount(_ gen: Int) {
        MainActor.assumeIsolated { ChatV1Load.active?.noteMount(gen) }
    }

    static func noteLate(_ kind: String) {
        MainActor.assumeIsolated { ChatV1Load.active?.noteLate(kind) }
    }

    static func flipBegin(to page: Int, animated: Bool) {
        MainActor.assumeIsolated { ChatV1Load.active?.noteFlipBegin(to: page, animated: animated) }
    }

    static func flipEnd() {
        MainActor.assumeIsolated { ChatV1Load.active?.noteFlipEnd() }
    }

    static func setResyncTrigger(_ t: String) { pendingResyncTrigger = t }

    static func takeResyncTrigger() -> String {
        defer { pendingResyncTrigger = "" }
        return pendingResyncTrigger.isEmpty ? "unknown" : pendingResyncTrigger
    }

    static func keyboardGeometry() -> [String: Double] {
        MainActor.assumeIsolated {
            let b = KeyboardInsetBridge.shared
            return ["extra": Double(b.extra), "barGrowth": Double(b.barGrowth), "containerTop": Double(b.containerTop)]
        }
    }

    static func resyncDone(req: Int, trigger: String, begin: Double, end: Double, before: [String: Double], after: [String: Double]) {
        MainActor.assumeIsolated {
            ChatV1Load.active?.noteResync(req: req, trigger: trigger, begin: begin, end: end, before: before, after: after)
        }
    }

    /// 纵切 5：cellGrew 钉位写 offset / 回底滑入真正启动（CardFlowView StreamScrollAnchor，主线程）；深翻报本 occurrence 的增量
    nonisolated(unsafe) private(set) static var pins = 0
    nonisolated(unsafe) private(set) static var glides = 0
    static func notePin() { pins += 1 }
    static func noteGlide() { glides += 1 }

    /// §14-102 离底诊断：CardFlowView cell 生长 → 钉位链每一次的去向（pinned / dropHuge / muted / outsideOlder / mountGuard / noWindow / noScrollView），
    /// 离底 turn 按 [shiftT, provider.complete) 取出报 growthEvents；环形上限 4000 条
    struct GrowthEvent {
        let t: Double
        let delta: Double
        let branch: String
        let fromBottom: Double?
        let streaming: Bool
    }
    nonisolated(unsafe) private(set) static var growthEvents: [GrowthEvent] = []
    static func noteGrowth(delta: CGFloat, branch: String, fromBottom: CGFloat?, streaming: Bool) {
        if growthEvents.count >= 4000 { growthEvents.removeFirst(1000) }
        growthEvents.append(GrowthEvent(t: CACurrentMediaTime(), delta: Double(delta), branch: branch,
                                        fromBottom: fromBottom.map(Double.init), streaming: streaming))
    }
}

/// display link：帧样本（含 targetTimestamp，§4.5）与结构就绪判据共用一个回调（A-16 合并采样）
final class ChatV1Sampler: NSObject {
    private var link: CADisplayLink?
    private(set) var samples: [PerfChatCore.FrameSample] = []
    /// Air 被动模式只递交时钟，不保存逐帧数组、不运行合成驱动或就绪检查。
    private let passiveFrame: ((PerfChatCore.FrameSample) -> Void)?
    init(passiveFrame: ((PerfChatCore.FrameSample) -> Void)? = nil) {
        self.passiveFrame = passiveFrame
        super.init()
    }

    @MainActor func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @MainActor func stop() { link?.invalidate(); link = nil }

    /// R5 C-06：探针每帧自身耗时（样本登记 + 就绪判定，含 hitTest），按窗口切分单报 probeSelfMs
    private(set) var selfIntervals: [PerfChatCore.Interval] = []

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let passiveFrame {
            passiveFrame(PerfChatCore.FrameSample(arrival: now, timestamp: l.timestamp, targetTimestamp: l.targetTimestamp))
            return
        }
        samples.append(PerfChatCore.FrameSample(arrival: now, timestamp: l.timestamp, targetTimestamp: l.targetTimestamp))
        MainActor.assumeIsolated {
            PerfRenderLedger.blankTick()      // M3：先记这一帧的空占位，再判就绪
            ChatV1Load.active?.tick(now)
            ChatV1Traverse.active?.tick(now)   // 纵切 5：深翻驱动与判据同一个回调（A-16 合并采样）
            ChatV1Turn.active?.tick(now)       // 纵切 6：流式 turn 的连续段采样 / 离底驱动 / 收尾判据
        }
        selfIntervals.append(PerfChatCore.Interval(start: now, end: CACurrentMediaTime()))
    }
}

// MARK: - M4 L1 取证：TextKit 排版分三类 + UITextView 池命中 / 新建（回调来自 SwiftStreamingMarkdown 的 MarkdownPerfProbe）

enum PerfTextKit {
    struct Pass { let kind: String; let b: Double; let e: Double }
    struct Vend { let reused: Bool; let b: Double; let e: Double }
    nonisolated(unsafe) private(set) static var passes: [Pass] = []
    nonisolated(unsafe) private(set) static var vends: [Vend] = []
    /// L1a：正文 / 几何入口（setContents / setAttr / frame / recycle / prewarm），与 passes 互斥（同一嵌套深度只报最外层）
    nonisolated(unsafe) private(set) static var spans: [Pass] = []

    /// 严格测量角色才挂回调（包里回调为 nil 时零行为）；全在主线程上被调
    static func install() {
        guard PerfHarness.strictMeasure, MarkdownPerfProbe.layout == nil else { return }
        MarkdownPerfProbe.layout = { kind, b, e in passes.append(Pass(kind: kind.rawValue, b: b, e: e)) }
        MarkdownPerfProbe.vend = { reused, b, e in vends.append(Vend(reused: reused, b: b, e: e)) }
        MarkdownPerfProbe.span = { kind, b, e in spans.append(Pass(kind: kind.rawValue, b: b, e: e)) }
    }

    /// [from, to] 内开始的：三类排版各 {n, ms}（主线程墙钟，最外层，不重叠）+ 池命中 / 新建与新建耗时
    static func summary(from: Double, to: Double) -> [String: Any] {
        var out: [String: Any] = [:]
        for kind in ["first", "firstGuess", "guess", "zeroToReal", "widthChanged", "other"] {
            let xs = passes.filter { $0.kind == kind && $0.b >= from && $0.b <= to }
            out[kind] = ["n": xs.count, "ms": ms3(xs.reduce(0) { $0 + $1.e - $1.b })]
        }
        let v = vends.filter { $0.b >= from && $0.b <= to }
        out["poolHit"] = v.filter(\.reused).count
        out["poolNew"] = v.filter { !$0.reused }.count
        out["poolNewMs"] = ms3(v.filter { !$0.reused }.reduce(0) { $0 + $1.e - $1.b })
        out["poolHitMs"] = ms3(v.filter(\.reused).reduce(0) { $0 + $1.e - $1.b })
        for kind in ["setContents", "setAttr", "frame", "recycle", "prewarm", "dismantle", "leaveWindow", "deinitView"] {
            let xs = spans.filter { $0.kind == kind && $0.b >= from && $0.b <= to }
            out[kind] = ["n": xs.count, "ms": ms3(xs.reduce(0) { $0 + $1.e - $1.b }), "maxMs": ms3(xs.map { $0.e - $0.b }.max() ?? 0)]
        }
        return out
    }

    private static func ms3(_ s: Double) -> Double { (s * 1_000_000).rounded() / 1000 }
}

// MARK: - 一个加载 occurrence 的状态机（§4.1–4.4）

@MainActor
final class LoadOcc {
    typealias Core = PerfChatCore
    struct Target {
        let key: String
        let conv: Conversation
        let expectedRows: [String]
        let digests: [String: UInt64]
        /// 本次首屏必需异步节点（§7.1 按模式声明）
        let requiredAsync: Set<String>
    }
    enum Kind { case inplace, open, search(node: String), setup }

    let occ: Int
    let target: Target
    let kind: Kind
    let reqId: Int
    let t0: Double
    let cacheState: String
    private(set) var tracker: Core.OpTracker
    private var mount: Core.MountAcceptance
    let mountGen0: Int
    private(set) var acceptedMountGen: Int?
    private(set) var extraRemount = false
    private(set) var applyRevision: Int?
    private var overwrittenAfterApply = false
    private(set) var late: [String: Int] = [:]
    private(set) var tasks: [(name: String, iv: Core.Interval)] = []
    private(set) var resyncs: [[String: Any]] = []
    private var resyncIntervals: [Core.Interval] = []
    private(set) var noAnimation = false
    private(set) var failures: [Core.Failure] = []
    private let markdownStart: Int
    private let jumpStart: Int

    // 结构就绪折叠（ReadyGate 语义：条件连续成立 + 其后 500ms 无 >50ms 块；R5 K-02 块后重开、C-02 链稳定回溯）
    private var streak = Core.ReadyStreak()
    private var lastTick: Double?
    var firstStructural: Double? { streak.firstStructural }
    var reopenCount: Int { streak.reopenCount }
    private(set) var structuralReady: Double?
    private(set) var confirmed: Double?
    private(set) var censoredAt: Double?
    private var stability: Core.ChainStability
    private var rowsRevision = -1
    private var rowsMatch = false
    private(set) var readyChain: [String] = []
    /// R14-04 测量钩子 MP_PERF_TEST_TAP_INPUT_MS：confirmed 后这么多 ms 聚焦输入框（tap），键盘停稳（shown）或超时
    var tapInput: (tap: Double, shown: Double?)?
    private(set) var readyConsumed: [(id: String, receipt: PerfRenderLedger.Consumed)] = []
    private(set) var readyOcclusion = Core.Occlusion(bottom: 0, top: 0, keyboardPad: 0)
    private(set) var readySpacing: CGFloat = 0
    private(set) var lastBlocker = "noApply"
    private(set) var jumpReceipt: PerfRenderLedger.Jump?
    private(set) var targetVisible = false
    /// R5 C-07：就绪时的跳转位置证据（离底距离、最新行是否可见、目标离视口中心）
    private(set) var jumpGeometry: [String: Any] = [:]
    /// 本请求自己的 apply 被 VM 守卫丢掉（不是迟到，R5 C-08）
    private(set) var ownApplyDropped = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var finished = false

    init(occ: Int, target: Target, kind: Kind, reqId: Int, t0: Double, cacheState: String) {
        self.occ = occ
        self.target = target
        self.kind = kind
        self.reqId = reqId
        self.t0 = t0
        self.cacheState = cacheState
        let flip: Bool = { if case .open = kind { return true }; return false }()
        tracker = Core.OpTracker(spec: .load(flip: flip), reqId: reqId, t0: t0)
        mountGen0 = ChatListProbe.mountGen
        mount = Core.MountAcceptance(baseGen: mountGen0)
        markdownStart = PerfRenderLedger.markdown.count
        jumpStart = PerfRenderLedger.jumps.count
        stability = Core.ChainStability(scale: UIScreen.main.scale)
    }

    var isFlip: Bool { if case .open = kind { return true }; return false }
    var applyEnd: Double? { tracker.times[.applyEnd] }

    // MARK: 事件

    func noteTask(_ name: String, req: Int, begin: Double, end: Double) {
        guard req == reqId else { return }
        tasks.append((name, Core.Interval(start: begin, end: end)))
    }

    func noteLate(_ k: String) { late[k, default: 0] += 1 }

    /// R5 C-08：VM 守卫丢弃按 req 分类——更旧的请求 = 迟到；本请求自己的 = ownApplyDropped（另报）
    func noteDropped(req: Int) {
        if req < reqId { late["applyDropped", default: 0] += 1 } else if req == reqId { ownApplyDropped += 1 }
    }

    func noteApply(req: Int, begin: Double, end: Double, revision: Int, changedRows: Bool, changedNode: Bool) {
        if req == reqId {
            tracker.record(.applyEnd, at: end)
            applyRevision = revision
            mount.noteApply()
            tasks.append(("apply", Core.Interval(start: begin, end: end)))
            ChatV1Load.emit(.apply, occ: occ)
            return
        }
        guard req < reqId else { return }
        late["apply", default: 0] += 1
        switch Core.classifyLate(eventReq: req, currentReq: reqId, afterCurrentApply: applyEnd != nil,
                                 changedRows: changedRows, changedCurrentNode: changedNode) {
        case .lateOverwrite:
            overwrittenAfterApply = true
            fail(.lateOverwrite, "apply req \(req) after current req \(reqId) apply changed rows/currentNode")
        case .isolatedLate, .current:
            break
        }
    }

    func noteMount(_ gen: Int) {
        switch mount.noteMount(gen: gen) {
        case .accepted: acceptedMountGen = gen
        case .extraRemount:
            extraRemount = true
            fail(.extraRemount, "mount \(gen) after locked \(acceptedMountGen ?? -1), before ready")
        case .beforeApply, .afterReady: break
        }
    }

    func noteFlipBegin(to page: Int, animated: Bool) {
        guard isFlip, page == 1, tracker.times[.flipBegin] == nil else { return }
        let now = CACurrentMediaTime()
        tracker.record(.flipBegin, at: now)
        if !animated {
            noAnimation = true
            tracker.record(.flipEnd, at: now)
        }
    }

    func noteFlipEnd() {
        guard isFlip, let b = tracker.times[.flipBegin], tracker.times[.flipEnd] == nil else { return }
        let now = CACurrentMediaTime()
        tracker.record(.flipEnd, at: now)
        tasks.append(("flip", Core.Interval(start: b, end: now)))
    }

    func noteResync(req: Int, trigger: String, begin: Double, end: Double, before: [String: Double], after: [String: Double]) {
        if req < reqId { late["resync", default: 0] += 1 }
        resyncs.append(["k": resyncs.count + 1, "trigger": trigger, "req": req, "geometryBefore": before, "geometryAfter": after,
                        "changed": before != after, "begin": begin, "end": end])
        resyncIntervals.append(Core.Interval(start: begin, end: end))
    }

    func fail(_ kind: Core.FailureKind, _ detail: String) {
        failures.append(Core.Failure(kind, detail))
        if kind.failureClass == .correctness { finish() }
    }

    // MARK: 逐帧判定（§4.4）

    func tick(_ now: Double) {
        guard !finished else { return }
        if now - t0 > ChatV1Load.readyTimeout {
            censoredAt = now
            fail(.readyTimeout, "structural ready not confirmed within \(Int(ChatV1Load.readyTimeout))s (last blocker: \(lastBlocker))")
            finish()
            return
        }
        if !ChatV1Load.probeSampling && now - t0 < ChatV1Load.samplingOffHold {
            lastTick = now
            return
        }
        // K-02：上个回调之后有 >50ms 块（或此刻仍在块里）= 条件不可知的间断，连串重开
        let blockSinceLastTick = lastTick.map { MainBlockMonitor.splitLastBlockEnd(after: $0, now: now) != nil } ?? false
        lastTick = now
        let e = evaluate(now)
        if streak.tick(now: now, holds: e.holds, stableSince: e.stableSince, blockSinceLastTick: blockSinceLastTick) {
            ChatV1Load.emit(.structural, occ: occ)
        }
        guard let c = streak.condAt else { return }
        let quietFrom = max(c, MainBlockMonitor.splitLastBlockEnd(after: t0, now: now) ?? 0)
        if now - quietFrom >= 0.5 {
            structuralReady = c
            confirmed = now
            tracker.record(.structuralReady, at: c)
            tracker.record(.confirmed, at: now)
            mount.noteReady()
            ChatV1Load.emit(.confirmed, occ: occ)
            finish()
        }
    }

    /// 条件 1–4、6 是否成立（holds）+ 链稳定连串起点（第 5 条，C-02）；不成立时记下第一条挡住的原因（超时报告用）
    private func evaluate(_ now: Double) -> (holds: Bool, stableSince: Double?) {
        func blocked(_ why: String) -> (holds: Bool, stableSince: Double?) { lastBlocker = why; stability.reset(); return (false, nil) }
        // 1 身份
        guard applyEnd != nil, let revNeeded = applyRevision else { return blocked("noApply") }
        guard !overwrittenAfterApply else { return blocked("overwritten") }
        guard let probe = ChatListProbe.current else { return blocked("noProbe") }
        guard probe.profileId == PerfHarness.profileId, probe.conversationId == target.conv.id else { return blocked("probeIdentity") }
        guard mount.holds(currentGen: probe.mountGen) else { return blocked("mountNotLocked") }
        // 2 行序（按 revision 缓存比对，不逐帧 O(N)）
        guard let snap = probe.appliedSnapshot, snap.revision >= revNeeded else { return blocked("revision") }
        if snap.revision != rowsRevision {
            rowsRevision = snap.revision
            rowsMatch = snap.ids == target.expectedRows
        }
        guard rowsMatch else { return blocked("rowOrder") }
        // 3 有效消息视口成链
        guard let sv = probe.scrollView, let window = sv.window, let visible = probe.viewportRect(in: window) else { return blocked("noWindow") }
        let occlusion = probe.occlusion
        let viewport = Core.effectiveViewport(visible, occlusion: occlusion)
        let rows = probe.visibleRows(in: window)
        var rects: [String: CGRect] = [:]
        for r in rows { rects[r.id] = r.windowRect }
        let chain: [String]
        let outcome: Core.ChainOutcome
        if case .search(let node) = kind {
            // R5 C-07：跳转后视口以目标行为锚成链（贴底成链从最新行起算，跳到深处必断）
            outcome = Core.messageChainAround(anchor: node, expected: target.expectedRows, rects: rects, viewport: viewport,
                                              spacing: probe.declaredRowSpacing, scale: window.screen.scale)
        } else {
            outcome = Core.messageChain(expected: target.expectedRows, rects: rects, viewport: viewport,
                                        spacing: probe.declaredRowSpacing, scale: window.screen.scale)
        }
        switch outcome {
        case .complete(let c): chain = c
        case .missingRow(let id): return blocked("chainMissing \(id)")
        case .gap(let id, let g): return blocked(String(format: "chainGap %@ %.1f", id, g))
        case .noViewport: return blocked("noViewport")
        }
        // 4 正文证据：消费回执摘要 == fixture 预计算；首屏必需异步节点有回执
        let ledger = PerfRenderLedger.consumed
        for id in chain {
            guard let c = ledger[id], c.t >= t0 else { return blocked("noConsumed \(id)") }
            guard let d = c.digest, d == target.digests[id] else { return blocked("digest \(id)") }
        }
        for id in chain where target.requiredAsync.contains(id) {
            // R5 C-04：按 (摘要 = fixture 预期正文, cacheDims = 本行当前维度) 匹配
            guard Core.markdownEvidence(markdownReceipts(of: id), expectedDigest: target.digests[id], warm: cacheState == "warm") else {
                return blocked("async \(id)")
            }
        }
        // C-03：链上任一行有在途异步排版（asyncBegin 无同键 asyncEnd）即不就绪，不只看 fixture 声明的必需集
        for id in chain where Core.markdownPending(markdownReceipts(of: id)) {
            return blocked("asyncPending \(id)")
        }
        // 搜索冒烟：跳转回执 + 目标行在有效视口内
        if case .search(let node) = kind {
            // R5 C-07 / K-05：只认 outcome == scrolled 的跳转回执
            guard let j = PerfRenderLedger.jumps.dropFirst(jumpStart).last(where: { $0.target == node && $0.t >= t0 && $0.outcome == "scrolled" }) else {
                return blocked("noJump")
            }
            jumpReceipt = j
            guard let vp = viewport, let r = rects[node], r.intersects(vp) else { return blocked("jumpTargetNotVisible") }
            targetVisible = true
            let newest = target.expectedRows.last.flatMap { rects[$0] }
            let fromBottom = sv.contentOffset.y + sv.adjustedContentInset.top
            jumpGeometry = ["offsetFromBottomPt": Double(fromBottom), "offsetFromBottomScreens": Double(fromBottom / max(1, vp.height)),
                            "newestRowVisible": newest.map { $0.intersects(vp) } ?? false,
                            "targetCenterOffsetPt": Double(r.midY - vp.midY),
                            "rowsFromBottom": target.expectedRows.count - 1 - (target.expectedRows.firstIndex(of: node) ?? 0)]
        }
        // 5 锚点稳定（C-02：链上所有行的 id 序列与 minY / maxY 连续两次相邻变化 ≤ 1 物理像素；起点回溯到连串首样本）
        let stableSince = stability.feed(chain.compactMap { id in rects[id].map { Core.ChainRow(id: id, minY: $0.minY, maxY: $0.maxY) } }, at: now)
        // 6 可交互：页落定 + 输入框命中；翻页类还要等翻页动画回执（flip.end 不晚于就绪）
        guard PerfHarness.paging?.perfSettledPage == 1, ChatV1Load.inputHit() else { lastBlocker = "notInteractive"; return (false, stableSince) }
        if isFlip, tracker.times[.flipEnd] == nil { lastBlocker = "flipEnd"; return (false, stableSince) }
        guard stableSince != nil else { lastBlocker = "anchorSettling"; return (true, nil) }
        readyChain = chain
        readyConsumed = chain.compactMap { id in ledger[id].map { (id, $0) } }
        readyOcclusion = occlusion
        readySpacing = probe.declaredRowSpacing
        return (true, stableSince)
    }

    /// 本 occurrence 自请求起、某一行的 markdown 回执（按 nodeId 索引，只查链上行）
    private func markdownReceipts(of id: String) -> [Core.MarkdownReceipt] {
        (PerfRenderLedger.markdownIndex[id] ?? []).compactMap { i in
            guard i >= markdownStart else { return nil }
            let m = PerfRenderLedger.markdown[i]
            return m.t >= t0 ? Core.MarkdownReceipt(digest: m.digest, cacheDims: m.cacheDims, kind: m.kind, t: m.t) : nil
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }

    var status: String {
        if failures.contains(where: { $0.kind.failureClass == .correctness }) { return "correctness" }
        if failures.contains(where: { $0.kind.failureClass == .instrument }) { return "instrument" }
        if failures.contains(where: { $0.kind.failureClass == .productSlow }) { return "productSlow" }
        return "ok"
    }

    /// 本 occurrence 自请求起的 markdown 回执（同键去重，保留首次时刻与次数）
    func markdownReceipts(until end: Double) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var index: [String: Int] = [:]
        for m in PerfRenderLedger.markdown.dropFirst(markdownStart) where m.t >= t0 && m.t <= end {
            let key = "\(m.nodeId)|\(m.digest)|\(m.cacheDims)|\(m.kind)|\(m.reqId)"
            if let i = index[key] { out[i]["n"] = (out[i]["n"] as? Int ?? 1) + 1; continue }
            index[key] = out.count
            out.append(["nodeId": m.nodeId, "digest": ChatV1Load.hex(m.digest), "cacheDims": m.cacheDims, "kind": m.kind,
                        "reqId": m.reqId, "t": m.t, "n": 1])
        }
        return out
    }

    func hasUnpairedAsync(until end: Double) -> Bool {
        var open: [String: Int] = [:]
        for m in PerfRenderLedger.markdown.dropFirst(markdownStart) where m.t >= t0 && m.t <= end {
            if m.kind == "asyncBegin" { open[m.nodeId, default: 0] += 1 }
            if m.kind == "asyncEnd", let n = open[m.nodeId], n > 0 { open[m.nodeId] = n - 1 }
        }
        return open.values.contains { $0 > 0 }
    }
}

// MARK: - 场景编排

@MainActor
enum ChatV1Load {
    typealias Core = PerfChatCore
    static let readyTimeout = 15.0
    static let tailSeconds = 1.5
    /// §9.3 探针 A/A：`MP_PERF_PROBE_SAMPLING=0` 关掉 request 起 1s 内的逐帧就绪判定（visibleRows / hitTest / 链判据），
    /// 1s 之后照常判（保留端点判据）；只比 fixed1s 证据，关闭时的 ready / confirmed 偏晚、不参与比较
    static let probeSampling = PerfHarness.env["MP_PERF_PROBE_SAMPLING"] != "0"
    static let samplingOffHold = 1.0
    static var active: LoadOcc?
    static var applyLog: [Core.ApplyRecord] = []
    static let sampler = ChatV1Sampler()
    private static var nextReq = 0
    private static var visited: Set<String> = []
    private static var occurrences: [[String: Any]] = []
    private static var mountedEngine: String?
    private static var lastOcc: LoadOcc?

    enum TraceEvent { case request, apply, structural, confirmed }

    static func emit(_ e: TraceEvent, occ: Int) {
        let run = PerfHarness.runId
        let s = PerfHarness.signposter
        switch e {
        case .request: s.emitEvent("ocRequest", "occ=\(occ, privacy: .public) run=\(run, privacy: .public)")
        case .apply: s.emitEvent("ocApply", "occ=\(occ, privacy: .public) run=\(run, privacy: .public)")
        case .structural: s.emitEvent("ocStruct", "occ=\(occ, privacy: .public) run=\(run, privacy: .public)")
        case .confirmed: s.emitEvent("ocConfirmed", "occ=\(occ, privacy: .public) run=\(run, privacy: .public)")
        }
    }

    static func hex(_ v: UInt64) -> String { String(format: "%016llx", v) }
    static func ms3(_ s: Double) -> Double { (s * 1_000_000).rounded() / 1000 }

    static func issueReq() -> Int {
        nextReq += 1
        PerfHarness.currentReqId = nextReq
        return nextReq
    }

    static func inputHit() -> Bool {
        guard let field = PerfHarness.inputField, let window = field.window else { return false }
        let center = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: window)
        let hit = window.hitTest(center, with: nil)
        return hit === field || hit?.isDescendant(of: field) == true
    }

    // MARK: 入口

    static func run(op: String) async {
        let traverseOps = ["deepSession", "deepJump"]
        let turnOps = ["streamAtBottom", "streamOffBottom"]
        let ops = ["inplaceLoad", "openConv.v1", "searchJumpBranch", "inplaceRapidABA"] + traverseOps + turnOps
        guard ops.contains(op) else {
            Driver.chatFail(.configMismatch, "op \(op) unknown")
            return
        }
        let requestedEngine = PerfHarness.env["MP_PERF_ENGINE"] ?? "swiftui"
        PerfTextKit.install()   // M4：setup 之前挂上，冷开第一遍就记到
        Driver.chatV1Extra["pinned"] = pinned()
        Driver.chatV1Extra["l1"] = MarkdownPerfProbe.l1Switches.merging(["syncLong": ChatL1Switch.syncLong, "prefill": ChatL1Switch.prefill]) { a, _ in a }   // L1 开关实际取值（ABBA 臂对账）
        Driver.chatV1Extra["config"] = configSummary()
        Driver.chatV1Extra["configDigest"] = "cfg-" + String(Core.digest(configSummary().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }), radix: 16)
        let thermalStart = PerfHarness.thermalName(), lowPowerStart = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalStartName = thermalStart
        let thermalT0 = CACurrentMediaTime()
        startThermalLog()
        let indexStart = searchIndexState()
        guard requestedEngine == "swiftui" else {
            Driver.chatFail(.engineMismatch, "engine unavailable: \(requestedEngine)")
            Driver.chatV1Extra["engine"] = ["requested": requestedEngine, "resolved": "swiftui", "mounted": "none"]
            return
        }
        guard let ctx = PerfHarness.modelContext,
              let targets = loadTargets(ctx, withD: traverseOps.contains(op), withS: turnOps.contains(op)) else {
            Driver.chatFail(.fixtureCorrupt, "chatV1 targets A / B / L / M\(traverseOps.contains(op) ? " / D" : "")\(turnOps.contains(op) ? " / S" : "") missing on bench profile")
            return
        }
        PerfHarness.signposter.emitEvent("ocAnchor", "run=\(PerfHarness.runId, privacy: .public) t=\(String(format: "%.6f", CACurrentMediaTime()), privacy: .public)")
        sampler.start()
        let ordinal = Int(PerfHarness.env["MP_PERF_ORDINAL"] ?? "1") ?? 1
        // M2：M（中长文）跟在 L 后面，与协议 ops.*.targets 同源
        let seq = ordinal % 2 == 1 ? ["A", "B", "L", "M", "A", "B", "L", "M"] : ["B", "A", "L", "M", "B", "A", "L", "M"]
        switch op {
        case "inplaceLoad":
            if await setup("L", targets, ctx) {
                for (i, key) in seq.enumerated() {
                    guard await occurrence(i + 1, targets[key]!, .inplace, ctx) else { break }
                }
            }
        case "openConv.v1":
            for (i, key) in seq.enumerated() {
                guard await occurrence(i + 1, targets[key]!, .open, ctx) else { break }
            }
        case "deepSession", "deepJump":
            // §6.5：一个进程 = 一个遍历 session；经列表打开 D 落定（setup，occ 0）+ 尾窗 1.5s 后开跑
            if await setup("D", targets, ctx) {
                occurrences.append(await ChatV1Traverse.run(op: op, target: targets["D"]!, prestate: prestate(1)))
            }
        case "streamAtBottom", "streamOffBottom":
            // §6.6：经列表打开 S 落定（setup，occ 0）+ 尾窗 1.5s 后调真实 sendMessage（S 复原在进程开跑前与 finishRun 各一次）
            if await setup("S", targets, ctx) {
                occurrences.append(await ChatV1Turn.run(op: op, target: targets["S"]!, prestate: prestate(1)))
            }
        case "searchJumpBranch":
            if await setup("A", targets, ctx), await occurrence(1, targets["B"]!, .search(node: searchNode), ctx),
               let screens = lastOcc?.jumpGeometry["offsetFromBottomScreens"] as? Double, screens < 3 {
                // R5 C-07：靶子离底不到 3 屏 = 冒烟空转（贴底时本来就可见）
                Driver.chatFail(.configMismatch, String(format: "search smoke vacuous: target %.1f screens from bottom (< 3)", screens), occ: 1)
            }
        default:
            if await setup("L", targets, ctx) { await rapidABA(targets, ctx) }
        }
        sampler.stop()
        let indexEnd = searchIndexState()
        Driver.chatV1Extra["engine"] = ["requested": requestedEngine, "resolved": "swiftui", "mounted": mountedEngine ?? "none"]
        Driver.chatV1Extra["device"] = ["model": Driver.deviceModel(), "os": UIDevice.current.systemVersion,
                                        "refreshRate": UIScreen.main.maximumFramesPerSecond,
                                        "thermalStart": thermalStart, "thermalEnd": PerfHarness.thermalName(),
                                        "thermalChanges": thermalChanges,
                                        // R7-12：op 开跑到第一次进 fair 的毫秒（A/A 看顺序效应：多早升温）；开跑即 fair = 0，没进过 = null
                                        "thermalFairAtMs": thermalStart == "fair" ? 0 : thermalChanges.first { $0["state"] as? String == "fair" }
                                            .flatMap { $0["t"] as? Double }.map { ChatV1Load.ms3($0 - thermalT0) } as Any? ?? NSNull(),
                                        "lowPowerStart": lowPowerStart, "lowPowerEnd": ProcessInfo.processInfo.isLowPowerModeEnabled,
                                        "indexBackfill": Core.indexBackfill(start: indexStart.status, end: indexEnd.status)]
        Driver.chatV1Extra["searchIndex"] = ["start": indexStart.report, "end": indexEnd.report]
        notePage2()
        Driver.chatV1Extra["occurrences"] = occurrences
        // L1 ①：整个进程的空闲预热（含启动 2s 后那一轮）次数 / 总时长 / 单片最长（单片 ≤ 4ms 才不成卡顿）
        Driver.chatV1Extra["prewarmAll"] = PerfTextKit.summary(from: 0, to: .greatestFiniteMagnitude)["prewarm"]
        if !PerfRenderLedger.zeroOcclusion.isEmpty { Driver.chatV1Extra["testZeroOcclusion"] = PerfRenderLedger.zeroOcclusion }
        Driver.chatV1Extra["resyncTotal"] = occurrences.reduce(0) { $0 + ((($1["evidence"] as? [String: Any])?["resync"] as? [Any])?.count ?? 0) }
    }

    /// B 的旁支节点（A→B→A 分支变体的临时浏览靶子）
    static let branchNode = "\(PerfHarness.convB)-side200-2"
    /// R5 C-07：搜索跳转靶子改到 B 主线深处（离底 199 行 ≫ 3 屏；fork 节点，旁支 fixture 不能加长——A / B 指纹要不变）
    static let searchNode = "\(PerfHarness.convB)-100"

    private static func loadTargets(_ ctx: ModelContext, withD: Bool, withS: Bool) -> [String: LoadOcc.Target]? {
        let pid = PerfHarness.profileId
        func conv(_ id: String) -> Conversation? {
            try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id && $0.profileId == pid })).first
        }
        let bubble = UserDefaults.standard.bool(forKey: "chatBubbleMode")
        let f = Core.Fixture.self
        guard let a = conv(PerfHarness.convA), let b = conv(PerfHarness.convB), let l = conv(f.L.convId), let m = conv(f.M.convId) else { return nil }
        let pathA = PerfSeed.pathA, pathB = PerfSeed.pathB
        func bodyDigests(_ path: [String], long: [String: String] = [:]) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: path.enumerated().map { i, id in (id, Core.fnv1a64(long[id] ?? f.body(i))) })
        }
        let bLongId = "\(PerfHarness.convB)-\(PerfSeed.longNodeIndex)"
        let bDigests = bodyDigests(pathB, long: [bLongId: PerfSeed.longMarkdown()])
        // §7.1：B-297 文章模式整条交一个 ChatMarkdownView（>3000 字走异步）；气泡模式按空行拆成小块都同步，空集
        let bAsync: Set<String> = bubble ? [] : [bLongId]
        // §7.1：L1 单段无空行，文章 / 气泡都是整条一块，恒必走异步
        let lAsync: Set<String> = [f.nodeId(f.L, f.L.count - 1)]
        var out: [String: LoadOcc.Target] = [
            "A": .init(key: "A", conv: a, expectedRows: pathA, digests: bodyDigests(pathA), requiredAsync: []),
            "B": .init(key: "B", conv: b, expectedRows: pathB, digests: bDigests, requiredAsync: bAsync),
            "L": .init(key: "L", conv: l, expectedRows: f.expectedRows(f.L), digests: f.bodyDigests(f.L), requiredAsync: lAsync),
            // M2：中长文全部 ≤ 3000 字，首见同步解析，必需异步集为空
            "M": .init(key: "M", conv: m, expectedRows: f.expectedRows(f.M), digests: f.bodyDigests(f.M), requiredAsync: []),
        ]
        if withD {
            // §7.1：D 的长文不进打开就绪（首屏必需异步 = 空集），在遍历命中时核 §5.3 回执
            guard let d = conv(f.D.convId) else { return nil }
            out["D"] = .init(key: "D", conv: d, expectedRows: f.expectedRows(f.D), digests: f.bodyDigests(f.D), requiredAsync: [])
        }
        if withS {
            guard let st = conv(f.S.convId) else { return nil }
            out["S"] = .init(key: "S", conv: st, expectedRows: f.expectedRows(f.S), digests: f.bodyDigests(f.S), requiredAsync: [])
        }
        return out
    }

    // MARK: 前置状态（§6.1）

    private static func prestate(_ page: Int) -> String? {
        guard let vm = PerfHarness.viewModel else { return "no viewModel" }
        if PerfHarness.profileAtLaunch != PerfHarness.profileId { return "not on bench profile" }
        if vm.scrollToNodeId != nil || vm.pendingScrollNodeId != nil { return "residual scroll target" }
        if vm.inConvSearchActive { return "in-conversation find active" }
        if KeyboardInsetBridge.shared.kbVisible { return "keyboard visible" }
        if vm.assistantTurnInFlight { return "turn in flight" }
        if PerfHarness.paging?.perfSettledPage != page { return "page not settled on \(page)" }
        return nil
    }

    private static func flipToList() async -> Bool {
        guard let p = PerfHarness.paging else { return false }
        if p.perfSettledPage != 0 { await p.perfDrive(to: 0, duration: 0.3) }
        return await waitFrames(timeout: 5) { p.perfSettledPage == 0 }
    }

    /// R14-04「打开长对话后 0.3–2s 点输入框」最小实现：confirmed + N ms（≈ 请求后 0.9–1.5s）聚焦输入框（先按真点击那样
    /// 记一次触摸时间给池的闲置门），等键盘停稳（kbVisible 且不在过渡）≤ 1.5s，停 200ms 后收起并等落稳，全在尾窗内
    static let tapInputDelay: Double? = PerfHarness.env["MP_PERF_TEST_TAP_INPUT_MS"].flatMap(Double.init).map { $0 / 1000 }

    private static func tapInputProbe(_ occ: LoadOcc, at time: Double) async {
        let wait = time - CACurrentMediaTime()
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        guard let field = PerfHarness.inputField else { return }
        let bridge = KeyboardInsetBridge.shared
        ChatParagraphPrewarm.lastTouchAt = ProcessInfo.processInfo.systemUptime
        let tap = CACurrentMediaTime()
        field.becomeFirstResponder()
        let up = await waitFrames(timeout: 1.5) { bridge.kbVisible && !bridge.kbTransitioning && bridge.extra > 0 }
        occ.tapInput = (tap, up ? CACurrentMediaTime() : nil)
        try? await Task.sleep(nanoseconds: 200_000_000)
        field.resignFirstResponder()
        _ = await waitFrames(timeout: 1.5) { !bridge.kbVisible && !bridge.kbTransitioning }
    }

    static func waitFrames(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while !condition() {
            if CACurrentMediaTime() >= deadline { return false }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in NextFrame.run { c.resume() } }
        }
        return true
    }

    /// setup：经列表打开落定，不进分母（occ 0，§6.2）
    private static func setup(_ key: String, _ targets: [String: LoadOcc.Target], _ ctx: ModelContext) async -> Bool {
        guard let t = targets[key], await flipToList(), let open = PerfHarness.openFromList else {
            Driver.chatFail(.probeMissing, "setup: paging / openFromList not registered", occ: 0)
            occurrences.append(["occ": 0, "target": key, "setup": true, "status": "instrument"])
            return false
        }
        PerfRenderLedger.observed = Set(t.expectedRows)
        let occ = LoadOcc(occ: 0, target: t, kind: .setup, reqId: issueReq(), t0: CACurrentMediaTime(), cacheState: cache(key))
        active = occ
        open(t.conv)
        await occ.wait()
        active = nil
        if mountedEngine == nil { mountedEngine = ChatListProbe.current?.implementation.rawValue }
        let ok = occ.status == "ok"
        occurrences.append(["occ": 0, "target": key, "setup": true, "status": occ.status])
        if !ok {
            Driver.chatFail(.probeMissing, "setup open \(key) failed: \(occ.failures.map { "\($0.kind.rawValue) \($0.detail)" }.joined(separator: "; "))", occ: 0)
        }
        try? await Task.sleep(nanoseconds: UInt64(tailSeconds * 1_000_000_000))
        return ok
    }

    private static func cache(_ key: String) -> String {
        defer { visited.insert(key) }
        return visited.contains(key) ? "warm" : "cold"
    }

    /// 一次正式 / 冒烟 occurrence；返回 false = 正确性失败，停本进程
    @discardableResult
    private static func occurrence(_ n: Int, _ t: LoadOcc.Target, _ kind: LoadOcc.Kind, _ ctx: ModelContext,
                                   checkPrestate: Bool = true) async -> Bool {
        if case .open = kind {
            guard await flipToList() else {
                Driver.chatFail(.probeMissing, "flip to list page timed out", occ: n)
                occurrences.append(["occ": n, "target": t.key, "status": "instrument"])
                return true
            }
        }
        if checkPrestate, let bad = prestate({ if case .open = kind { return 0 }; return 1 }()) {
            Driver.chatFail(.navigationMismatch, "prestate: \(bad)", occ: n)
            occurrences.append(["occ": n, "target": t.key, "status": "correctness"])
            return false
        }
        PerfRenderLedger.observed = Set(t.expectedRows)
        let cacheState = cache(t.key)
        let req = issueReq()
        let t0 = CACurrentMediaTime()
        let occ = LoadOcc(occ: n, target: t, kind: kind, reqId: req, t0: t0, cacheState: cacheState)
        active = occ
        emit(.request, occ: n)
        switch kind {
        case .inplace, .setup:
            PerfHarness.viewModel?.loadConversation(t.conv, context: ctx)
        case .open:
            PerfHarness.openFromList?(t.conv)
        case .search(let node):
            PerfHarness.viewModel?.navigateToSearchResult(nodeId: node, conversation: t.conv, context: ctx)
        }
        await occ.wait()
        // 尾窗 W_tail：confirmed 起 1.5s；产品慢 / 失败就地收
        let end = (occ.confirmed ?? CACurrentMediaTime()) + (occ.confirmed == nil ? 0 : tailSeconds)
        if let delay = tapInputDelay, let cf = occ.confirmed { await tapInputProbe(occ, at: cf + delay) }
        let remaining = end - CACurrentMediaTime()
        if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        // 在途异步排版等它落地再收（不进任何窗口，只为回执成对）
        _ = await waitFrames(timeout: 3) { !occ.hasUnpairedAsync(until: CACurrentMediaTime()) }
        active = nil
        lastOcc = occ
        if mountedEngine == nil { mountedEngine = ChatListProbe.current?.implementation.rawValue }
        occurrences.append(report(occ, tailEnd: end))
        for f in occ.failures {
            Driver.chatFail(f.kind, f.detail, occ: n)
        }
        return occ.status != "correctness"
    }

    /// §6.3 A→B→A：reqA1 → 50ms → reqB → 50ms → reqA2；判定挂在 reqA2 的 occurrence 上（前置状态在序列开头查）。
    /// R5 C-08 / K-03 测试钩子：`MP_PERF_TEST_APPLY_DELAY_MS` 让序列首个请求在后台多睡（强制迟到）——plain 变体
    /// 迟到的 A1 与 A2 写同一条路径，只能走到 isolatedLate；`MP_PERF_TEST_ABA_VARIANT=branch`：首个请求改成
    /// navigateToSearchResult(B 的旁支节点)（临时分支浏览，行不同），第二个 = plain B（判定挂在它上），同一对话 ID
    /// 过得了 VM 守卫、行又真变了 → 走到 lateOverwrite（§4.1 的产品洞，P0 只报）。断言用「最后一次改写行」的 apply
    private static func rapidABA(_ targets: [String: LoadOcc.Target], _ ctx: ModelContext) async {
        guard let vm = PerfHarness.viewModel, let a = targets["A"], let b = targets["B"] else { return }
        if let bad = prestate(1) {
            Driver.chatFail(.navigationMismatch, "prestate: \(bad)", occ: 1)
            occurrences.append(["occ": 1, "target": "A", "status": "correctness"])
            return
        }
        let branch = PerfHarness.env["MP_PERF_TEST_ABA_VARIANT"] == "branch"
        let logStart = applyLog.count
        var aba: [String: Any] = ["variant": branch ? "branch" : "plain", "testApplyDelayMs": PerfHarness.testApplyDelayMs]
        let first = issueReq()
        if PerfHarness.testApplyDelayMs > 0 { PerfHarness.testDelayApplyReq = first }
        aba["delayedReq"] = PerfHarness.testApplyDelayMs > 0 ? first : -1
        if branch {
            aba["reqBranch"] = first
            aba["branchNode"] = branchNode
            vm.navigateToSearchResult(nodeId: branchNode, conversation: b.conv, context: ctx)
        } else {
            aba["reqA1"] = first
            vm.loadConversation(a.conv, context: ctx)
            try? await Task.sleep(nanoseconds: 50_000_000)
            aba["reqB"] = issueReq()
            vm.loadConversation(b.conv, context: ctx)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let final = branch ? b : a
        let ok = await occurrence(1, final, .inplace, ctx, checkPrestate: false)
        guard let fo = lastOcc else { return }
        // 迟到的 apply 可能在 occurrence 收尾之后才落地：等到点名的那个请求有了 apply 记录（最多 3s）再算
        if PerfHarness.testApplyDelayMs > 0 {
            _ = await waitFrames(timeout: 3) { applyLog.dropFirst(logStart).contains { $0.req == first } }
        }
        let applies = Array(applyLog.dropFirst(logStart))
        let v = Core.abaVerdict(applies, finalReq: fo.reqId, finalT0: fo.t0)
        let rowsOK = PerfRenderLedger.applied?.ids == final.expectedRows
        let selectedOK = vm.selectedConversation?.id == final.conv.id
        aba["reqFinal"] = fo.reqId
        aba["applies"] = applies.map { ["req": $0.req, "t": $0.t, "dropped": $0.dropped, "changedRows": $0.changedRows] }
        aba["lastWriterReq"] = v.lastWriter ?? -1
        aba["lastRowChangingReq"] = v.lastChanger ?? -1
        aba["lateByLog"] = ["apply": v.lateApplies, "applyChangingRows": v.lateChangingApplies, "applyDropped": v.lateDropped]
        aba["finalSelectedTarget"] = selectedOK
        aba["finalRowsTarget"] = rowsOK
        aba["late"] = fo.late
        aba["lateOverwrite"] = fo.failures.contains { $0.kind == .lateOverwrite }
        if var last = occurrences.last {
            last["aba"] = aba
            occurrences[occurrences.count - 1] = last
        }
        guard ok else { return }
        if !selectedOK || !rowsOK { Driver.chatFail(.navigationMismatch, "A→B→A: final selected/rows not \(final.key)", occ: 1) }
        if !v.navigationOK {
            Driver.chatFail(.navigationMismatch, "A→B→A: last apply changing rows is req \(v.lastChanger ?? -1), not final req \(fo.reqId)", occ: 1)
        }
    }

    // MARK: 报告（字段契约 = testdata/chatv1/load-complete.json）

    private static func report(_ o: LoadOcc, tailEnd: Double) -> [String: Any] {
        var out: [String: Any] = ["occ": o.occ, "target": o.target.key, "cacheState": o.cacheState, "ordinal": o.occ,
                                  "reqId": o.reqId]
        if o.status == "ok", case .failed(let f) = o.tracker.evaluate(now: CACurrentMediaTime()) { o.fail(f.kind, "endpoints: \(f.detail)") }
        var ep: [String: Any] = [:]
        for (e, t) in o.tracker.times { ep[e.rawValue] = t }
        out["endpoints"] = ep
        if o.noAnimation { out["noAnimation"] = true }
        if let f = o.firstStructural { out["firstStructural"] = f }
        out["reopenCount"] = o.reopenCount
        if let c = o.censoredAt { out["censoredAtMs"] = ms3(c - o.t0); out["lastBlocker"] = o.lastBlocker }
        if case .search(let node) = o.kind {
            var search: [String: Any] = ["targetNode": node, "jumpOutcome": o.jumpReceipt?.outcome ?? "none",
                                         "jumpT": o.jumpReceipt?.t ?? NSNull(), "targetVisible": o.targetVisible]
            search.merge(o.jumpGeometry) { a, _ in a }
            out["search"] = search
        }
        // R5 C-01：忙段取 split 观察者（含布局 + CA 提交，plan §14-49）
        let segments = MainBlockMonitor.splitIntervals(now: CACurrentMediaTime())
        var evidence: [String: Any] = [
            "reqId": o.reqId, "ownApplyDropped": o.ownApplyDropped,
            "mount": ["mountGen0": o.mountGen0, "acceptedMountGen": o.acceptedMountGen as Any? ?? NSNull(), "extraRemount": o.extraRemount],
            "late": o.late,
            "markdown": o.markdownReceipts(until: tailEnd),
        ]
        // §9.3 探针 A/A 比较口径：[request, request + 1s] 固定窗（与就绪端点无关，开 / 关两种采样都可比）
        let f1 = Core.Interval(start: o.t0, end: o.t0 + 1)
        var fixed1s: [String: Any] = ["probeSampling": probeSampling, "busyMs": ms3(Core.busy(segments, in: f1)),
                                      "probeSelfMs": ms3(Core.busy(sampler.selfIntervals, in: f1)), "footprintEndMiB": PerfHarness.footprintMiB()]
        let f1Samples = sampler.samples.filter { $0.arrival >= f1.start && $0.arrival <= f1.end }
        if case .success(let g) = Core.frameGaps(f1Samples, from: f1.start, to: max(f1.end, f1Samples.last?.timestamp ?? f1.end),
                                                 previous: sampler.samples.last(where: { $0.arrival < f1.start })) {
            fixed1s["callbackGapExcess"] = (g.callbackGapExcess * 1000).rounded() / 1000
            fixed1s["worstGapMs"] = ms3(g.worstGapMs / 1000)
            fixed1s["callbacks"] = g.callbacks
        }
        evidence["fixed1s"] = fixed1s
        if let ti = o.tapInput {
            // 点输入框到键盘停稳：主线程忙、最差间隔（同 frameGaps 口径）、这一段里的补池片
            let tEnd = ti.shown ?? (ti.tap + 1.5)
            let win = sampler.samples.filter { $0.arrival >= ti.tap && $0.arrival <= tEnd }
            var tap: [String: Any] = ["afterRequestMs": ms3(ti.tap - o.t0), "kbShowMs": ti.shown.map { ms3($0 - ti.tap) } as Any? ?? NSNull(),
                                      "busyMs": ms3(Core.busy(segments, in: Core.Interval(start: ti.tap, end: tEnd))),
                                      "prewarm": PerfTextKit.summary(from: ti.tap, to: tEnd)["prewarm"] as Any? ?? NSNull()]
            if case .success(let g) = Core.frameGaps(win, from: ti.tap, to: tEnd, previous: sampler.samples.last(where: { $0.arrival < ti.tap })) {
                tap["worstGapMs"] = ms3(g.worstGapMs / 1000)
            }
            evidence["tapInput"] = tap
        }
        if let applyEnd = o.applyEnd, let sr = o.structuralReady, let cf = o.confirmed {
            let w = Core.LoadWindows(t0: o.t0, applyEnd: applyEnd, structuralReady: sr, confirmed: cf, tail: tailSeconds)
            let lb = Core.loadBusy(segments: segments, windows: w)
            if !lb.sumHolds { o.fail(.windowSumMismatch, "Σwindows != total") }
            var windows: [String: Any] = [:]
            // R5 C-06：探针自身耗时按窗口切分（在忙段之内，可从 busyMs 剔除对照）
            for (name, iv) in w.windows {
                windows["W_" + name] = ["busyMs": ms3(lb.windows[name] ?? 0), "probeSelfMs": ms3(Core.busy(sampler.selfIntervals, in: iv))]
            }
            out["windows"] = windows
            // R5 C-01 对照：legacy / launchV2 口径的 order 0 单观察者（漏布局 + CA 提交，§14-49），只报不用
            let o0 = Core.loadBusy(segments: MainBlockMonitor.segmentIntervals(now: CACurrentMediaTime()), windows: w)
            var order0: [String: Any] = ["busyFixed1sMs": ms3(o0.fixed1s), "busyToConfirmedMs": ms3(o0.toConfirmed)]
            for (n, v) in o0.windows { order0["W_" + n] = ms3(v) }
            evidence["busyOrder0"] = order0
            var metrics: [String: Any] = ["busyFixed1sMs": ms3(lb.fixed1s), "busyToStructuralMs": ms3(lb.toStructural),
                                          "busyToConfirmedMs": ms3(lb.toConfirmed), "busyTotalMs": ms3(lb.total)]
            // mask 实测：回调送达时 CADisplayLink.timestamp 可略领先 CACurrentMediaTime（系统提前派发），
            // 窗口末端取 max(confirmed, 窗内末回调 timestamp)，不把提前量当时钟回退；领先量单报
            let inWindow = sampler.samples.filter { $0.arrival >= o.t0 && $0.arrival <= cf }
            let frameEnd = max(cf, inWindow.last?.timestamp ?? cf)
            metrics["timestampLeadMaxMs"] = ms3(inWindow.map { $0.timestamp - $0.arrival }.max() ?? 0)
            // R5 C-05：request → 首回调这一段计入，用 request 前最后一个样本的宣告目标裁剪
            switch Core.frameGaps(inWindow, from: o.t0, to: frameEnd, previous: sampler.samples.last(where: { $0.arrival < o.t0 })) {
            case .success(let g):
                metrics["callbackGapExcess"] = (g.callbackGapExcess * 1000).rounded() / 1000
                metrics["worstGapMs"] = ms3(g.worstGapMs / 1000)
                metrics["firstCallbackDelayMs"] = g.firstCallbackDelayMs.map { ms3($0 / 1000) } as Any? ?? NSNull()
                metrics["callbacks"] = g.callbacks
            case .failure(let f):
                o.fail(f.kind, "frameGaps: \(f.detail)")
            }
            if let next = sampler.samples.first(where: { $0.arrival > sr }) { metrics["presentProxyMs"] = ms3(next.arrival - sr) }
            // M3：本 occurrence 自请求起开始的空占位段；空白帧 = 用户看得到的那部分（与有效视口相交）
            let blank = PerfRenderLedger.blanks.filter { $0.begin >= o.t0 && $0.begin <= tailEnd }
            // R12-03：按段判——结构就绪时在成链里的行、或空占位期间进过有效视口的行，只要出现过空占位段就记 1（主线程忙时没回调，按帧数会记成 0）
            let chainSet = Set(o.readyChain)
            func inChain(_ b: PerfRenderLedger.Blank) -> Bool { chainSet.contains(b.nodeId) || b.visibleFrames > 0 }
            evidence["blank"] = blank.map { b -> [String: Any] in
                ["nodeId": b.nodeId, "reqId": b.reqId, "begin": b.begin, "end": b.end as Any? ?? NSNull(), "frames": b.frames,
                 "visibleFrames": b.visibleFrames, "durMs": b.end.map { ms3($0 - b.begin) } as Any? ?? NSNull(), "inChain": inChain(b)]
            }
            metrics["blankRowFrames"] = blank.reduce(0) { $0 + $1.visibleFrames }
            metrics["blankChainSegments"] = blank.filter(inChain).count
            // R12-01（kimi）：墙钟维度——成链段 durMs 之和 / 最大（未收口的段按尾窗末算），块清单 blankDurMsGate 比最大段
            let chainDur = blank.filter(inChain).map { ms3(($0.end ?? tailEnd) - $0.begin) }
            metrics["blankChainDurMs"] = ms3(chainDur.reduce(0, +) / 1000)
            metrics["blankChainMaxDurMs"] = chainDur.max() ?? 0
            out["metrics"] = metrics
            // M4 L1 取证（诊断量，不进门）：到结构就绪 / 到尾窗末的 TextKit 三类排版与 UITextView 池
            evidence["textkit"] = ["toReady": PerfTextKit.summary(from: o.t0, to: sr), "total": PerfTextKit.summary(from: o.t0, to: tailEnd)]
            var tasks: [String: Any] = [:]
            let named = o.tasks + o.resyncIntervalsNamed
            for (name, iv) in named {
                let tb = Core.taskBusy(iv, segments: segments, windows: w)
                var overlap: [String: Double] = [:]
                for (k, v) in tb.overlap where v > 0 { overlap["W_" + k] = ms3(v) }
                tasks[name] = ["busyMs": ms3(tb.busy), "wallMs": ms3(iv.duration), "overlap": overlap] as [String: Any]
            }
            out["tasks"] = tasks
            evidence["resync"] = o.resyncs.map { r -> [String: Any] in
                var r = r
                if let b = r["begin"] as? Double, let e = r["end"] as? Double {
                    r["busyMs"] = ms3(Core.busy(segments, in: Core.Interval(start: b, end: e)))
                }
                return r
            }
            evidence["occlusion"] = ["bottomPt": Double(o.readyOcclusion.bottom), "topPt": Double(o.readyOcclusion.top),
                                     "keyboardPadPt": Double(o.readyOcclusion.keyboardPad)]
            evidence["rowSpacingPt"] = Double(o.readySpacing)
            evidence["consumed"] = o.readyConsumed.compactMap { id, c -> [String: Any]? in
                guard let d = c.digest else { return nil }
                return ["nodeId": id, "digest": hex(d), "mode": c.mode, "t": c.t]
            }
            evidence["chainRows"] = o.readyChain.count
        } else {
            evidence["resync"] = o.resyncs.map { r -> [String: Any] in
                var r = r
                if let b = r["begin"] as? Double, let e = r["end"] as? Double { r["busyMs"] = ms3(Core.busy(segments, in: Core.Interval(start: b, end: e))) }
                return r
            }
        }
        out["evidence"] = evidence
        out["status"] = o.status
        return out
    }

    // MARK: 运行级身份（§8.2）

    private static func pinned() -> [String: Any] {
        let d = UserDefaults.standard
        let argument = d.volatileDomain(forName: UserDefaults.argumentDomain)
        let persistent = Bundle.main.bundleIdentifier.flatMap { d.persistentDomain(forName: $0) } ?? [:]
        func yn(_ v: Any?) -> String {
            guard let v else { return "absent" }
            if let s = v as? String { return ["YES", "TRUE", "1"].contains(s.uppercased()) ? "YES" : "NO" }
            if let n = v as? NSNumber { return n.boolValue ? "YES" : "NO" }
            return "\(v)"
        }
        var out: [String: Any] = [:]
        for (key, type) in Core.pinnedKeys {
            let effective: Any
            switch type {
            case .bool: effective = d.bool(forKey: key) ? "YES" : "NO"
            case .double: effective = d.double(forKey: key)
            case .string: effective = d.string(forKey: key) ?? NSNull()
            case .data: effective = d.data(forKey: key).map(Core.dataPin) ?? NSNull()
            // M1：主题报 ThemeManager 解析后真正用上的 id（定义里没有这个 id 会回 default）
            case .theme: effective = ThemeManager.shared.selectedThemeId
            }
            var row: [String: Any] = ["effective": effective,
                                      "source": argument[key] != nil ? "argument" : (persistent[key] != nil ? "persistent" : "default"),
                                      "argType": argument[key].map { String(describing: Swift.type(of: $0)) } ?? "absent"]
            row["persistent"] = type == .bool ? yn(persistent[key]) : (persistent[key] is Data ? "<data>" : persistent[key].map { "\($0)" } ?? "absent")
            out[key] = row
        }
        return out
    }

    /// 配置摘要（不钉死但全轮一致，§8.2）：外观键 + 视口 / 缩放 / 深浅色 / 字号档 + 楼层 preset 与正则脚本条数
    private static func configSummary() -> [String: String] {
        let d = UserDefaults.standard
        var out: [String: String] = [:]
        for key in ["bubbleSpacing", "blurRadius", "gardenSceneEnabled", "bubbleCornerRadius", "bubblePaddingH", "bubblePaddingV",
                    "lineSpacingScale", "paragraphSpacingScale", "hideTimestamp", "hideRoleName", "hideActionBar", "showAvatar",
                    "bubbleModeCornerRadius", "selectedFont", "fontScale", "selectedThemeId", "chatBubbleMode", "themeMode"] {
            out[key] = d.object(forKey: key).map { "\($0)" } ?? "default"
        }
        out["themeDefinitions"] = d.data(forKey: "themeDefinitions").map(Core.dataPin) ?? "default"
        out["themeResolved"] = ThemeManager.shared.selectedThemeId
        let screen = UIScreen.main
        out["viewport"] = "\(Int(screen.bounds.width))x\(Int(screen.bounds.height))@\(screen.scale)"
        let traits = PerfHarness.paging?.view.window?.traitCollection
        out["style"] = "\(traits?.userInterfaceStyle.rawValue ?? -1)"
        out["contentSize"] = traits?.preferredContentSizeCategory.rawValue ?? "-"
        return out
    }

    /// R4 C-04：搜索索引状态（SearchIndexer 不写 SwiftData，但回填 / 对账在 utility 队列与测量窗口重叠）。
    /// 读 @Observable 的 state 在视图 body 之外，不建立订阅
    private static func searchIndexState() -> (status: String, report: [String: Any]) {
        let s = SearchIndexer.shared.state
        var out: [String: Any] = ["docCount": s.docCount]
        let status: String
        switch s.status {
        case .idle: status = "idle"
        case .building(let progress): status = "building"; out["progress"] = (progress * 1000).rounded() / 1000
        case .ready: status = "ready"
        case .failed(let error): status = "failed"; out["error"] = error
        }
        out["status"] = status
        return (status, out)
    }

    /// R4 C-11：page2 恢复出的网页类 app（WKWebView，网络在进程外，URLProtocol / 声明抑制都看不到）。
    /// 合成翻页会挂上 page2 根（scrollViewWillBeginDragging / scrollToPage → mountPendingPages），挂载只记录；
    /// 真正要封闭的是「后台没有恢复出任何 app」，有就判 configMismatch
    private static func notePage2() {
        let shell = Page2AppShell.shared
        Driver.chatV1Extra["page2"] = ["mounted": !(PerfHarness.paging?.perfPendingPages.contains(2) ?? true),
                                       "restored": shell.restored, "openApps": shell.stack.openApps] as [String: Any]
        if !shell.stack.openApps.isEmpty {
            Driver.chatFail(.configMismatch, "page2 restored apps \(shell.stack.openApps.joined(separator: ","))（§3.1：WKWebView 外发拦不到）")
        }
    }

    /// §14-57：进程内 thermal 变化时刻（起止另报）；分析器 nominal↔fair 只记，出现 serious / critical 才判 envChanged
    private(set) static var thermalChanges: [[String: Any]] = []
    /// R6 C-01：深翻 10s 分箱时间线按它 + thermalChanges 推每箱末的 thermal 状态
    private(set) static var thermalStartName = ""

    /// t 时刻的 thermal 状态（op 开跑时的状态 + 之后的变化序列）
    static func thermalState(at t: Double) -> String {
        var state = thermalStartName
        for c in thermalChanges {
            guard let ct = c["t"] as? Double, ct <= t, let st = c["state"] as? String else { continue }
            state = st
        }
        return state
    }
    private static var thermalObserver: NSObjectProtocol?

    private static func startThermalLog() {
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { thermalChanges.append(["t": CACurrentMediaTime(), "state": PerfHarness.thermalName()]) }
        }
    }
}

extension LoadOcc {
    var resyncIntervalsNamed: [(name: String, iv: PerfChatCore.Interval)] {
        resyncs.compactMap { r in
            guard let k = r["k"] as? Int, let b = r["begin"] as? Double, let e = r["end"] as? Double else { return nil }
            return ("resync#\(k)", PerfChatCore.Interval(start: b, end: e))
        }
    }
}
#endif
