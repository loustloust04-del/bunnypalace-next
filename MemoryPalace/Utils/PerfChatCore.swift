#if DEBUG || PERF_BENCH
import Foundation
import CoreGraphics

/// 聊天页 P0 测量的纯计量核心（docs/plan-chat-list-perf-p0.md 纵切 2）：只算不采，
/// 不碰 UIKit / SwiftData / 全局状态，macOS 单测直接跑；采样与执行在 PerfHarness / ChatListProbe。
/// 时间一律秒（CACurrentMediaTime 基准），出报告时再换 ms。
enum PerfChatCore {}

// MARK: - M1 显示钉死键（chatV1-r9；与协议 displayPins.keys 同源，py 单测抠这里比对）

extension PerfChatCore {
    enum PinType: String { case bool, double, string, data, theme }

    /// 模式键 chatBubbleMode 在前，其后是 M1 钉成粟粟 Air 值的显示设置（主题要连同定义与深浅色一起钉才生效）
    static let pinnedKeys: [(key: String, type: PinType)] = [
        ("chatBubbleMode", .bool),
        ("blurRadius", .double), ("bubbleModeCornerRadius", .double), ("bubblePaddingH", .double), ("bubblePaddingV", .double),
        ("bubbleSpacing", .double), ("fontScale", .double), ("lineSpacingScale", .double), ("paragraphSpacingScale", .double),
        ("gardenSceneEnabled", .bool), ("hideActionBar", .bool), ("showAvatar", .bool),
        ("selectedThemeId", .theme), ("themeDefinitions", .data), ("themeMode", .string),
    ]

    /// data 键的有效值：fnv:<FNV-1a 64 of bytes>（分析器对 argv 的 <data> 解码后同算）
    static func dataPin(_ d: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in d { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "fnv:" + String(format: "%016llx", h)
    }
}

// MARK: - 摘要（FNV-1a 64）

extension PerfChatCore {
    static func fnv1a64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// 有序字串列表的摘要；每段带长度前缀，拼接歧义（["ab","c"] 对 ["a","bc"]）不撞
    static func digest(_ parts: [String]) -> UInt64 {
        fnv1a64(parts.map { "\($0.utf8.count):\($0)" }.joined())
    }
}

// MARK: - 2.1 请求 / 挂载接纳 / 迟到（§4.1）

extension PerfChatCore {
    /// 加载请求对挂载代际的接纳：本请求 apply 之后的第一次新挂载被接纳并锁定；锁定后、就绪前再换代 = extraRemount
    struct MountAcceptance: Equatable {
        enum Verdict: Equatable { case beforeApply, accepted, extraRemount, afterReady }

        let baseGen: Int
        private(set) var applied = false
        private(set) var lockedGen: Int?
        /// R5 K-06：请求后、apply 前出现的最新挂载代际（不接纳，但 holds 要比对它）
        private(set) var preApplyGen: Int?
        private(set) var ready = false

        init(baseGen: Int) { self.baseGen = baseGen }

        mutating func noteApply() { applied = true }
        mutating func noteReady() { ready = true }

        mutating func noteMount(gen: Int) -> Verdict {
            if ready { return .afterReady }
            guard applied else {
                preApplyGen = gen
                return .beforeApply
            }
            guard lockedGen == nil else { return .extraRemount }
            lockedGen = gen
            return .accepted
        }

        /// 就绪条件 1 的挂载部分：已锁定则当前挂载必须是锁定那代；apply 后无新挂载但 apply 前有过，则必须仍是那代
        /// （R5 K-06）；请求以来都无新挂载则不限
        func holds(currentGen: Int) -> Bool { (lockedGen ?? preApplyGen).map { $0 == currentGen } ?? true }
    }

    enum LateVerdict: Equatable { case current, isolatedLate, lateOverwrite }

    /// 带旧 reqId 的 apply / parse / resync：只有落在当前请求 apply 之后且改了行序或 currentNodeId 才判 lateOverwrite。
    /// reqId 由测量台单调分配，事件 reqId ≥ 当前视为当前。
    static func classifyLate(eventReq: Int, currentReq: Int, afterCurrentApply: Bool,
                             changedRows: Bool, changedCurrentNode: Bool) -> LateVerdict {
        guard eventReq < currentReq else { return .current }
        return afterCurrentApply && (changedRows || changedCurrentNode) ? .lateOverwrite : .isolatedLate
    }

    /// 换代只看目标身份与测量台是否发了更新的同类请求；挂载代际不参与。Probe 身份 nil（换挂载空档）不算换代
    static func isSuperseded(target: (profile: String, conversation: String),
                             probe: (profile: String?, conversation: String?),
                             applied: Bool, newerSameKindIssued: Bool) -> Bool {
        if newerSameKindIssued { return true }
        guard applied, let p = probe.profile, let c = probe.conversation else { return false }
        return p != target.profile || c != target.conversation
    }
}

// MARK: - 2.1 三类操作的端点、先后与截止（§4.2）

extension PerfChatCore {
    enum OpKind: String { case load, traverse, turn }

    enum Endpoint: String, CaseIterable {
        case request
        case flipBegin = "flip.begin", flipEnd = "flip.end", applyEnd = "apply.end"
        case structuralReady, confirmed
        case coldUpEnd = "coldUp.end", returnDownEnd = "returnDown.end"
        case userJump = "userJump.receipt", firstProgress = "render.firstProgress"
        case providerComplete = "provider.complete", finishJump = "finishJump.receipt"
        case staticConsumed = "static.consumed"
    }

    struct Deadline: Equatable { let endpoint: Endpoint; let anchor: Endpoint; let seconds: Double }

    /// `before` 是偏序（a 不晚于 b）：flip 与 apply、userJump 与 firstProgress、finishJump 与 static.consumed
    /// （onComplete 同一事务里写 scrollToNodeId 与终稿，列表 onChange 与气泡 body 谁先求值不固定，mask 实测两种都有）的先后真实路径上不固定，不硬排
    struct OpSpec {
        let kind: OpKind
        let required: [Endpoint]
        let before: [(Endpoint, Endpoint)]
        let deadlines: [Deadline]

        static func load(flip: Bool, timeout: Double = 15) -> OpSpec {
            var req: [Endpoint] = [.request, .applyEnd, .structuralReady, .confirmed]
            var order: [(Endpoint, Endpoint)] = [(.request, .applyEnd), (.applyEnd, .structuralReady), (.structuralReady, .confirmed)]
            if flip {
                req.insert(contentsOf: [.flipBegin, .flipEnd], at: 1)
                order += [(.request, .flipBegin), (.flipBegin, .flipEnd), (.flipEnd, .structuralReady)]
            }
            return OpSpec(kind: .load, required: req, before: order,
                          deadlines: [Deadline(endpoint: .confirmed, anchor: .request, seconds: timeout)])
        }

        static func traverse(phaseTimeout: Double = 60) -> OpSpec {
            OpSpec(kind: .traverse, required: [.request, .coldUpEnd, .returnDownEnd],
                   before: [(.request, .coldUpEnd), (.coldUpEnd, .returnDownEnd)],
                   deadlines: [Deadline(endpoint: .coldUpEnd, anchor: .request, seconds: phaseTimeout),
                               Deadline(endpoint: .returnDownEnd, anchor: .coldUpEnd, seconds: phaseTimeout)])
        }

        static func turn(scriptDuration: Double) -> OpSpec {
            OpSpec(kind: .turn,
                   required: [.request, .userJump, .firstProgress, .providerComplete, .finishJump, .staticConsumed, .confirmed],
                   before: [(.request, .userJump), (.request, .firstProgress), (.userJump, .providerComplete),
                            (.firstProgress, .providerComplete), (.providerComplete, .finishJump),
                            (.providerComplete, .staticConsumed), (.finishJump, .confirmed), (.staticConsumed, .confirmed)],
                   deadlines: [Deadline(endpoint: .confirmed, anchor: .request, seconds: scriptDuration + 10)])
        }

        /// e 之后（传递闭包）必须出现的端点
        func successors(of e: Endpoint) -> Set<Endpoint> {
            var out: Set<Endpoint> = []
            var stack = [e]
            while let x = stack.popLast() {
                for (a, b) in before where a == x && !out.contains(b) { out.insert(b); stack.append(b) }
            }
            return out
        }
    }

    enum OpStatus: Equatable { case pending, complete, failed(Failure) }

    struct OpTracker {
        let spec: OpSpec
        let reqId: Int
        private(set) var times: [Endpoint: Double]

        init(spec: OpSpec, reqId: Int, t0: Double) {
            self.spec = spec
            self.reqId = reqId
            times = [.request: t0]
        }

        /// 重复登记取最后一次（structuralReady 取「持续到 confirmed 的最后一次成立」）
        mutating func record(_ e: Endpoint, at t: Double) { times[e] = t }

        /// 先查仪器（先后颠倒、缺登记而后继已到），再查截止（产品慢），不补零
        func evaluate(now: Double) -> OpStatus {
            for (a, b) in spec.before {
                if let ta = times[a], let tb = times[b], ta > tb {
                    return .failed(Failure(.nonMonotonic, "\(a.rawValue) > \(b.rawValue)"))
                }
            }
            for e in spec.required where times[e] == nil {
                if spec.successors(of: e).contains(where: { times[$0] != nil }) {
                    return .failed(Failure(.missingEndpoint, e.rawValue))
                }
            }
            for d in spec.deadlines {
                guard let anchor = times[d.anchor] else { continue }
                let limit = anchor + d.seconds
                if (times[d.endpoint] ?? now) > limit { return .failed(Failure(timeoutKind, d.endpoint.rawValue)) }
            }
            return spec.required.allSatisfy { times[$0] != nil } ? .complete : .pending
        }

        private var timeoutKind: FailureKind {
            switch spec.kind {
            case .load: .readyTimeout
            case .traverse: .traversalTimeCap
            case .turn: .turnTimeout
            }
        }
    }
}

// MARK: - 2.2 固定窗口与 busy（§4.3）

extension PerfChatCore {
    struct Interval: Equatable {
        let start: Double
        let end: Double
        var duration: Double { max(0, end - start) }
        func overlap(_ o: Interval) -> Double { max(0, min(end, o.end) - max(start, o.start)) }
        func intersection(_ o: Interval) -> Interval { Interval(start: max(start, o.start), end: max(max(start, o.start), min(end, o.end))) }
    }

    /// 主线程忙段（互不重叠）落在 w 里的总时长
    static func busy(_ segments: [Interval], in w: Interval) -> Double {
        segments.reduce(0) { $0 + $1.overlap(w) }
    }

    struct LoadWindows: Equatable {
        static let names = ["toApply", "toReady", "settle", "tail"]
        let t0: Double
        let applyEnd: Double
        let structuralReady: Double
        let confirmed: Double
        let tailEnd: Double

        init(t0: Double, applyEnd: Double, structuralReady: Double, confirmed: Double, tail: Double = 1.5) {
            self.t0 = t0
            self.applyEnd = applyEnd
            self.structuralReady = structuralReady
            self.confirmed = confirmed
            tailEnd = confirmed + tail
        }

        var isMonotonic: Bool { t0 <= applyEnd && applyEnd <= structuralReady && structuralReady <= confirmed }

        var windows: [(name: String, interval: Interval)] {
            let edges = [t0, applyEnd, structuralReady, confirmed, tailEnd]
            return Self.names.indices.map { (Self.names[$0], Interval(start: edges[$0], end: edges[$0 + 1])) }
        }

        var whole: Interval { Interval(start: t0, end: tailEnd) }
    }

    struct LoadBusy: Equatable {
        let fixed1s: Double
        let toStructural: Double
        let toConfirmed: Double
        let total: Double
        let windows: [String: Double]
        /// 窗口单调且各窗口 busy 之和 = [T0, 尾窗结束] 总忙（容差 0.1ms）；false = 仪器失败
        let sumHolds: Bool
    }

    static func loadBusy(segments: [Interval], windows w: LoadWindows) -> LoadBusy {
        var per: [String: Double] = [:]
        for (name, iv) in w.windows { per[name] = busy(segments, in: iv) }
        let total = busy(segments, in: w.whole)
        let sum = per.values.reduce(0, +)
        return LoadBusy(fixed1s: busy(segments, in: Interval(start: w.t0, end: w.t0 + 1)),
                        toStructural: busy(segments, in: Interval(start: w.t0, end: w.structuralReady)),
                        toConfirmed: busy(segments, in: Interval(start: w.t0, end: w.confirmed)),
                        total: total, windows: per,
                        sumHolds: w.isMonotonic && abs(sum - total) <= 0.0001)
    }

    /// 任务区间（loadSync / flip / resync#k）的 inclusive 忙，及其与每个窗口交集内的忙；任务与窗口不相加
    static func taskBusy(_ task: Interval, segments: [Interval], windows w: LoadWindows) -> (busy: Double, overlap: [String: Double]) {
        var per: [String: Double] = [:]
        for (name, iv) in w.windows { per[name] = busy(segments, in: task.intersection(iv)) }
        return (busy(segments, in: task), per)
    }
}

// MARK: - 2.3 帧回调间隔（§4.5）

extension PerfChatCore {
    struct FrameSample: Equatable {
        let arrival: Double
        let timestamp: Double
        let targetTimestamp: Double
    }

    struct FrameGaps: Equatable {
        /// ms/s
        let callbackGapExcess: Double
        let worstGapMs: Double
        let firstCallbackDelayMs: Double?
        let callbacks: Int
    }

    /// dtᵢ = 相邻 timestamp 差，expectedᵢ = 上一回调宣告的 targetTimestamp − timestamp（可变刷新率逐次取）。
    /// R5 C-05：窗口起点 → 首回调这一段也计入（加载最重的卡顿常落在这里）：有窗口前最后一个样本 `previous` 时，
    /// 超额 = 首回调 timestamp − max(start, previous 宣告的 targetTimestamp)，间隔 = 首回调 timestamp − max(start, previous.timestamp)；
    /// 没有就按首回调自己的宣告周期、从 start 起算。首回调延迟照旧另报。窗口末补未闭合尾间隔，expected 用最后一次宣告值。
    /// 窗口颠倒、窗口内 arrival / timestamp 回退、宣告目标早于自身 timestamp → 仪器失败（nonMonotonic），不钳零出数
    static func frameGaps(_ samples: [FrameSample], from start: Double, to end: Double,
                          previous: FrameSample? = nil) -> Result<FrameGaps, Failure> {
        guard start <= end else { return .failure(Failure(.nonMonotonic, "frame window end < start")) }
        let s = samples.filter { $0.arrival >= start && $0.arrival <= end }
        for (i, x) in s.enumerated() {
            if x.targetTimestamp <= x.timestamp { return .failure(Failure(.nonMonotonic, "frame[\(i)] target <= timestamp")) }
            if x.timestamp > end { return .failure(Failure(.nonMonotonic, "frame[\(i)] timestamp > window end")) }
            guard i > 0 else { continue }
            if x.arrival < s[i - 1].arrival { return .failure(Failure(.nonMonotonic, "frame[\(i)] arrival rollback")) }
            if x.timestamp <= s[i - 1].timestamp { return .failure(Failure(.nonMonotonic, "frame[\(i)] timestamp rollback")) }
        }
        var excess = 0.0, worst = 0.0
        func add(_ dt: Double, _ expected: Double) {
            excess += max(0, dt - expected)
            worst = max(worst, dt)
        }
        if let first = s.first {
            if let p = previous {
                let gap = first.timestamp - max(start, p.timestamp)
                excess += max(0, first.timestamp - max(start, p.targetTimestamp))
                worst = max(worst, gap)
            } else {
                add(first.timestamp - start, first.targetTimestamp - first.timestamp)
            }
        }
        for (p, c) in zip(s, s.dropFirst()) { add(c.timestamp - p.timestamp, p.targetTimestamp - p.timestamp) }
        if let last = s.last { add(end - last.timestamp, last.targetTimestamp - last.timestamp) }
        let duration = end - start
        return .success(FrameGaps(callbackGapExcess: duration > 0 ? 1000 * excess / duration : 0,
                                  worstGapMs: worst * 1000,
                                  firstCallbackDelayMs: s.first.map { ($0.arrival - start) * 1000 },
                                  callbacks: s.count))
    }
}

// MARK: - 2.4 有效消息视口成链 + 锚点稳定（§4.4 第 3、5 条）

extension PerfChatCore {
    struct Occlusion: Equatable {
        let bottom: CGFloat
        let top: CGFloat
        let keyboardPad: CGFloat
    }

    /// sv 可视矩形（window 坐标）扣掉实现声明的上下遮挡带与键盘垫块；扣没了返回 nil
    static func effectiveViewport(_ visible: CGRect, occlusion o: Occlusion) -> CGRect? {
        let top = visible.minY + o.top
        let bottom = visible.maxY - o.bottom - o.keyboardPad
        guard bottom > top else { return nil }
        return CGRect(x: visible.minX, y: top, width: visible.width, height: bottom - top)
    }

    enum ChainOutcome: Equatable {
        case complete([String])
        case missingRow(String)
        case gap(String, CGFloat)
        case noViewport
    }

    /// 从视觉底按 expected（旧→新）从新到旧成链：每行必须有 rect，与下方（首行即视口底）间隙 ∈ [0, 间距 + 1 物理像素]；
    /// 首行可越过视口底（被遮挡带盖住一截），但必须与视口相交。某行顶越过视口顶或到最旧行即成链
    static func messageChain(expected: [String], rects: [String: CGRect], viewport: CGRect?,
                             spacing: CGFloat, scale: CGFloat) -> ChainOutcome {
        guard let vp = viewport, vp.height > 0 else { return .noViewport }
        let tol = spacing + 1 / scale + 1e-6
        var edge = vp.maxY
        var chain: [String] = []
        for id in expected.reversed() {
            guard let r = rects[id] else { return .missingRow(id) }
            let gap = edge - r.maxY
            if chain.isEmpty {
                if gap > tol || r.minY >= vp.maxY { return .gap(id, gap) }
            } else if gap < -1e-6 || gap > tol {
                return .gap(id, gap)
            }
            chain.append(id)
            if r.minY <= vp.minY { break }
            edge = r.minY
        }
        return .complete(chain)
    }

    struct ChainRow: Equatable {
        let id: String
        let minY: CGFloat
        let maxY: CGFloat
    }

    /// R5 C-02：锚点稳定看链上**所有**行——id 序列不变、每行 minY / maxY 相邻两个样本的变化都 ≤ 1 物理像素，
    /// 连续 3 个样本（2 次相邻变化）= 稳。反转 / 非反转列表对称：链内任何一行还在长高都破坏签名
    /// （旧版只看视觉底行 maxY，反转列表里底行向上长、maxY 不动，基本空转）。
    /// 返回稳定连串的**第 1 个样本**时刻：structuralReady 回溯到几何落定那一帧，不再固定晚 2 帧
    struct ChainStability {
        let scale: CGFloat
        private var last: [ChainRow]?
        private var runStart: Double = 0
        private var runSamples = 0

        init(scale: CGFloat) { self.scale = scale }

        mutating func reset() {
            last = nil
            runSamples = 0
        }

        mutating func feed(_ rows: [ChainRow], at t: Double) -> Double? {
            let tol = 1 / scale + 1e-9
            if let l = last, !rows.isEmpty, l.count == rows.count,
               zip(l, rows).allSatisfy({ $0.id == $1.id && abs($0.minY - $1.minY) <= tol && abs($0.maxY - $1.maxY) <= tol }) {
                runSamples += 1
            } else {
                runSamples = 1
                runStart = t
            }
            last = rows
            return runSamples >= 3 ? runStart : nil
        }
    }

    /// R5 K-02 + C-02：结构就绪连串（ReadyGate 语义）。holds = 条件 1–4、6 本回调成立（不含锚点稳定）；
    /// stableSince = 链稳定连串起点；blockSinceLastTick = 上个回调之后有 >50ms 块结束、或此刻仍在块里——
    /// 块期间条件不可知，按间断重开：condAt = max(条件连续成立起点, 稳定起点)，块后起点 = 块后首个回调
    struct ReadyStreak: Equatable {
        private(set) var holdsSince: Double?
        private(set) var condAt: Double?
        private(set) var firstStructural: Double?
        private(set) var reopenCount = 0

        /// true = 本回调新开一段连串
        mutating func tick(now: Double, holds: Bool, stableSince: Double?, blockSinceLastTick: Bool) -> Bool {
            guard holds else {
                holdsSince = nil
                condAt = nil
                return false
            }
            if holdsSince == nil || blockSinceLastTick {
                holdsSince = now
                condAt = nil
            }
            guard let s = stableSince, let h = holdsSince else {
                condAt = nil
                return false
            }
            guard condAt == nil else { return false }
            let c = max(h, s)
            condAt = c
            if firstStructural == nil { firstStructural = c } else { reopenCount += 1 }
            return true
        }
    }

    struct MarkdownReceipt: Equatable {
        let digest: UInt64
        let cacheDims: String
        let kind: String
        let t: Double
    }

    /// R5 C-03：同一行（nodeId）有 asyncBegin、而同键（摘要 + cacheDims）其后没有 asyncEnd = 排版在途，不就绪。
    /// 不再只看 fixture 声明的必需异步集：没声明进必需集的长文同样挡住
    static func markdownPending(_ receipts: [MarkdownReceipt]) -> Bool {
        var open: [String: Int] = [:]
        for m in receipts {
            let key = "\(m.digest)|\(m.cacheDims)"
            if m.kind == "asyncBegin" {
                open[key, default: 0] += 1
            } else if m.kind == "asyncEnd", let n = open[key], n > 0 {
                open[key] = n - 1
            }
        }
        return open.values.contains { $0 > 0 }
    }
}

// MARK: - 2.5 失败四类（§4.6）

extension PerfChatCore {
    enum FailureClass: String { case correctness, instrument, productSlow, confounded }

    enum FailureKind: String, CaseIterable {
        case identityMismatch, crossFloorWrite, crossConversationWrite, unexpectedOutbound
        case fixtureCorrupt, restoreFailed, rowOrderMismatch, contentMismatch, navigationMismatch
        case extraRemount, lateOverwrite, engineMismatch, configMismatch
        case probeMissing, jsonMissing, jsonCorrupt, missingEndpoint, nonMonotonic, windowSumMismatch
        case thermalJump, interrupted
        case readyTimeout, traversalTimeCap, turnTimeout, streamLate, streamNotConverged
        case premiseBroken
        /// 纵切 6：provider 完成前渲染输入一次都没前进（流式期间不显示字）
        case streamNoProgress
        /// R6 C-05：深翻下一个检查点落在已实化下标区间内、探针却没登记它的 rect（驱动来回回找）——仪器，不判产品慢
        case probeMissedCheckpoint
        /// R7 C-07：渲染输入在片到达之前就已 ≥ 该片应有长度（应有长度加工链与产品不一致）——仪器
        case renderAheadOfSupply
        /// R7 C-04：离底锚点漂移超阈值（钉位没守住）——正确性
        case anchorDrift
        /// R7 C-05：在底跟随收尾时离底超阈值（跟随断了）——正确性
        case followLost

        var failureClass: FailureClass {
            switch self {
            case .identityMismatch, .crossFloorWrite, .crossConversationWrite, .unexpectedOutbound,
                 .fixtureCorrupt, .restoreFailed, .rowOrderMismatch, .contentMismatch, .navigationMismatch,
                 .extraRemount, .lateOverwrite, .engineMismatch, .configMismatch, .streamNoProgress, .anchorDrift, .followLost: .correctness
            case .probeMissing, .jsonMissing, .jsonCorrupt, .missingEndpoint, .nonMonotonic, .windowSumMismatch,
                 .thermalJump, .interrupted, .probeMissedCheckpoint, .renderAheadOfSupply: .instrument
            case .readyTimeout, .traversalTimeCap, .turnTimeout, .streamLate, .streamNotConverged: .productSlow
            case .premiseBroken: .confounded
            }
        }

        /// 外发与跨楼层写：进程内立即 finishRun、host 停整轮
        var stopsRunImmediately: Bool { self == .unexpectedOutbound || self == .crossFloorWrite }
    }

    struct Failure: Error, Equatable {
        let kind: FailureKind
        /// confounded 时写被禁用的派生解释名
        let detail: String
        init(_ kind: FailureKind, _ detail: String = "") {
            self.kind = kind
            self.detail = detail
        }
    }

    struct ArmVerdict: Equatable {
        var red = false
        var stopRun = false
        /// 同一仪器原因连续两个进程出现：先停下来修
        var stopToFix: FailureKind?
        var instrumentCount = 0
        var instrumentAllowed = 0
        var productSlowCount = 0
        var processes = 0
        var disabledDerivations: [String] = []
    }

    /// 一臂（一个核心分层）按进程顺序判：正确性一次即红；仪器 ≤ ⌊10% × 预排进程数⌋；产品慢照收只计数；confounded 只禁派生
    static func armVerdict(processes: [[Failure]], planned: Int) -> ArmVerdict {
        var v = ArmVerdict()
        v.processes = processes.count
        v.instrumentAllowed = planned / 10
        var previousInstrument: Set<FailureKind> = []
        for failures in processes {
            let instrument = Set(failures.map(\.kind).filter { $0.failureClass == .instrument })
            for f in failures {
                switch f.kind.failureClass {
                case .correctness:
                    v.red = true
                    if f.kind.stopsRunImmediately { v.stopRun = true }
                case .confounded:
                    if !v.disabledDerivations.contains(f.detail) { v.disabledDerivations.append(f.detail) }
                case .instrument, .productSlow:
                    break
                }
            }
            if !instrument.isEmpty { v.instrumentCount += 1 }
            if v.stopToFix == nil, let repeated = instrument.intersection(previousInstrument).sorted(by: { $0.rawValue < $1.rawValue }).first {
                v.stopToFix = repeated
            }
            if failures.contains(where: { $0.kind.failureClass == .productSlow }) { v.productSlowCount += 1 }
            previousInstrument = instrument
        }
        if v.instrumentCount > v.instrumentAllowed { v.red = true }
        return v
    }
}

// MARK: - 2.6 S 复原差异计划 + 指纹（§7.2–7.3）

extension PerfChatCore {
    struct NodeRecord: Equatable {
        let id: String
        var parentId: String?
        var childrenIds: [String]
        var content: String
        /// 进指纹不进复原计划（发送不改老节点角色）；D / L 的长文必须 assistant（§7.1）
        var role: String = ""
    }

    struct ConvRecord: Equatable {
        var currentNodeId: String?
        var updateTime: Date
        var nodeCount: Int
        var unreadCount: Int
        var title: String
        var memoryEnabled: Bool
        /// R4 C-09：真实发送会写的另外四个字段（种子值 nil / "" / "" / ""）；A / B 指纹按 §14-21 不含 branchSelectionData
        var branchSelectionData: Data? = nil
        var selectedModelId: String = ""
        var draftText: String = ""
        var permGrantsRaw: String = ""
    }

    enum NodeField: String, CaseIterable { case parentId, childrenIds, content }
    enum ConvField: String, CaseIterable {
        case currentNodeId, updateTime, nodeCount, unreadCount, title, memoryEnabled
        case branchSelectionData, selectedModelId, draftText, permGrantsRaw
    }

    struct RestorePlan: Equatable {
        var deleteIds: [String] = []
        /// 种子节点没了：只能判 fixture 损坏，不在复原里重建
        var missingSeedIds: [String] = []
        var nodeFixes: [String: Set<NodeField>] = [:]
        var convFields: Set<ConvField> = []
        var isNoop: Bool { deleteIds.isEmpty && missingSeedIds.isEmpty && nodeFixes.isEmpty && convFields.isEmpty }
    }

    static func restorePlan(seedNodes: [NodeRecord], seedConv: ConvRecord,
                            nodes: [NodeRecord], conv: ConvRecord) -> RestorePlan {
        var plan = RestorePlan()
        let seed = Dictionary(seedNodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = Set(nodes.map(\.id))
        for n in nodes {
            guard let s = seed[n.id] else { plan.deleteIds.append(n.id); continue }
            var f: Set<NodeField> = []
            if n.parentId != s.parentId { f.insert(.parentId) }
            if n.childrenIds != s.childrenIds { f.insert(.childrenIds) }
            if n.content != s.content { f.insert(.content) }
            if !f.isEmpty { plan.nodeFixes[n.id] = f }
        }
        plan.deleteIds.sort()
        plan.missingSeedIds = seedNodes.map(\.id).filter { !live.contains($0) }.sorted()
        if conv.currentNodeId != seedConv.currentNodeId { plan.convFields.insert(.currentNodeId) }
        if conv.updateTime != seedConv.updateTime { plan.convFields.insert(.updateTime) }
        if conv.nodeCount != seedConv.nodeCount { plan.convFields.insert(.nodeCount) }
        if conv.unreadCount != seedConv.unreadCount { plan.convFields.insert(.unreadCount) }
        if conv.title != seedConv.title { plan.convFields.insert(.title) }
        if conv.memoryEnabled != seedConv.memoryEnabled { plan.convFields.insert(.memoryEnabled) }
        if conv.branchSelectionData != seedConv.branchSelectionData { plan.convFields.insert(.branchSelectionData) }
        if conv.selectedModelId != seedConv.selectedModelId { plan.convFields.insert(.selectedModelId) }
        if conv.draftText != seedConv.draftText { plan.convFields.insert(.draftText) }
        if conv.permGrantsRaw != seedConv.permGrantsRaw { plan.convFields.insert(.permGrantsRaw) }
        return plan
    }

    /// 单个对话的指纹；节点按 id 排序后摘要，与 fetch 顺序无关
    struct ConvFingerprint: Equatable {
        let storedNodes: Int
        let idsDigest: UInt64
        let contentDigest: UInt64
        let relationDigest: UInt64
        let roleDigest: UInt64
        let currentNodeId: String?
        let nodeCount: Int
        let unreadCount: Int
        let updateTime: Double
        let title: String
        let memoryEnabled: Bool
        /// "-" = nil；"excluded" = 不进指纹（A / B，§14-21）；否则 base64
        let branchSelection: String
        let selectedModelId: String
        let draftText: String
        let permGrantsRaw: String

        init(nodes: [NodeRecord], conv: ConvRecord, includeBranchSelection: Bool = true) {
            let sorted = nodes.sorted { $0.id < $1.id }
            storedNodes = sorted.count
            idsDigest = PerfChatCore.digest(sorted.map(\.id))
            contentDigest = PerfChatCore.digest(sorted.map(\.content))
            relationDigest = PerfChatCore.digest(sorted.map { "\($0.id)<\($0.parentId ?? "-")>\($0.childrenIds.joined(separator: ","))" })
            roleDigest = PerfChatCore.digest(sorted.map(\.role))
            currentNodeId = conv.currentNodeId
            nodeCount = conv.nodeCount
            unreadCount = conv.unreadCount
            updateTime = conv.updateTime.timeIntervalSinceReferenceDate
            title = conv.title
            memoryEnabled = conv.memoryEnabled
            branchSelection = includeBranchSelection ? (conv.branchSelectionData?.base64EncodedString() ?? "-") : "excluded"
            selectedModelId = conv.selectedModelId
            draftText = conv.draftText
            permGrantsRaw = conv.permGrantsRaw
        }

        /// 进整轮 fixture 摘要的规范串（字段顺序固定）；发送字段是自由文本，按长度前缀摘要进串
        var canonical: String {
            [String(storedNodes), String(idsDigest, radix: 16), String(contentDigest, radix: 16), String(relationDigest, radix: 16),
             String(roleDigest, radix: 16), currentNodeId ?? "-", String(nodeCount), String(unreadCount),
             String(updateTime), title, memoryEnabled ? "1" : "0",
             String(PerfChatCore.digest([branchSelection, selectedModelId, draftText, permGrantsRaw]), radix: 16)].joined(separator: "|")
        }

        /// 不一致的字段名（报告用）
        func diff(_ o: ConvFingerprint) -> [String] {
            var out: [String] = []
            if storedNodes != o.storedNodes { out.append("storedNodes") }
            if idsDigest != o.idsDigest { out.append("ids") }
            if contentDigest != o.contentDigest { out.append("content") }
            if relationDigest != o.relationDigest { out.append("relation") }
            if roleDigest != o.roleDigest { out.append("role") }
            if currentNodeId != o.currentNodeId { out.append("currentNodeId") }
            if nodeCount != o.nodeCount { out.append("nodeCount") }
            if unreadCount != o.unreadCount { out.append("unreadCount") }
            if updateTime != o.updateTime { out.append("updateTime") }
            if title != o.title { out.append("title") }
            if memoryEnabled != o.memoryEnabled { out.append("memoryEnabled") }
            if branchSelection != o.branchSelection { out.append("branchSelectionData") }
            if selectedModelId != o.selectedModelId { out.append("selectedModelId") }
            if draftText != o.draftText { out.append("draftText") }
            if permGrantsRaw != o.permGrantsRaw { out.append("permGrantsRaw") }
            return out
        }
    }
}

// MARK: - 2.7 Probe 注册表 token 规则 + 墙钟锚定到达表

extension PerfChatCore {
    /// 注册 = 新挂载代际并成为当前；注销只在 current 仍是自己的 token 时清（旧挂载迟到的注销不清新注册）
    struct ProbeRegistry: Equatable {
        private(set) var current: UUID?
        private(set) var mountGen = 0

        mutating func register(_ token: UUID) -> Int {
            mountGen += 1
            current = token
            return mountGen
        }

        @discardableResult
        mutating func unregister(_ token: UUID) -> Bool {
            guard current == token else { return false }
            current = nil
            return true
        }
    }

    /// 脚本流到达表：offsets 是相对开播的计划时刻（非降序），每个 tick 投递所有计划时刻 ≤ now 的片。
    /// 慢 tick 让片成簇到达，但终片时刻只取决于墙钟，不被逐 tick 累积拉长
    struct ArrivalSchedule {
        let offsets: [Double]
        let anchor: Double
        private(set) var delivered = 0

        init(offsets: [Double], anchor: Double) {
            self.offsets = offsets
            self.anchor = anchor
        }

        var isFinished: Bool { delivered == offsets.count }

        mutating func due(at now: Double) -> Range<Int> {
            var end = delivered
            while end < offsets.count, anchor + offsets[end] <= now { end += 1 }
            let r = delivered..<end
            delivered = end
            return r
        }
    }
}

// MARK: - 纵切 3 · chatV1 fixture 生成器（§7.1）+ 楼层恢复 / 防呆判定（§3.3）

extension PerfChatCore {
    /// L / D / S 的内容全由这里确定性生成（固定日期、显式角色）：seed 按它写，复原与指纹按它核，
    /// 正文摘要表与 expectedRows 也从这里出，不从 VM / 库里读
    enum Fixture {
        struct Spec: Equatable {
            let key: String
            let convId: String
            let count: Int
            /// 长文位置（单段、无空行、>3200 字、开头 ⟦PERF:<id>⟧），一律 role = assistant
            let longIndices: [Int]
            let title: String
            let memoryEnabled: Bool
            /// M2 中长文位置（300–3000 字、多块 markdown、role = assistant）：≤ 3000 字首见走主线程同步解析（syncParseLimit）
            var mediumIndices: [Int] = []
        }

        static let L = Spec(key: "L", convId: "perf-flash-conv-L", count: 80, longIndices: [75, 79],
                            title: "[PERF] 长文对话 L（80）", memoryEnabled: true)
        static let D = Spec(key: "D", convId: "perf-flash-conv-D", count: 3000, longIndices: [501, 1501, 2501],
                            title: "[PERF] 深翻对话 D（3000）", memoryEnabled: true)
        /// S：memoryEnabled = false（字段默认 true）、标题非占位、无图、非草稿；场景前后复原
        static let S = Spec(key: "S", convId: "perf-flash-conv-S", count: 40, longIndices: [],
                            title: "[PERF] 流式对话 S（40）", memoryEnabled: false)
        /// M2（plan-chat-list-perf §1）：中长文对话，assistant 为主（每 4 条 3 条 assistant 中长文、1 条 user 短句），
        /// 全文化后首屏同步解析全文的成本层；只读不改，同 L 按 seed 楼层隔离 / 指纹
        static let M = Spec(key: "M", convId: "perf-flash-conv-M", count: 40, longIndices: [],
                            title: "[PERF] 中长文对话 M（40）", memoryEnabled: true, mediumIndices: (0..<40).filter { $0 % 4 != 0 })
        static let all = [L, D, S, M]
        static let mediumMinChars = 300
        static let mediumMaxChars = 2950
        /// R14-01（chatV1-r10）：M 最新一条 assistant 拉到约 6k 字（≤ ③ 门槛 6000：开 = 首见同步，关 = 异步空占位再长高）
        static let mediumSixKIndex = 39
        static let mediumSixKMaxChars = 5950
        /// 固定日期：S 的 updateTime 能逐位复原，重新 seed 指纹也不漂
        static let baseDate = Date(timeIntervalSince1970: 1_790_000_000)
        static let longMinChars = 3200

        static func nodeId(_ spec: Spec, _ i: Int) -> String { "\(spec.convId)-\(i)" }

        static func role(_ spec: Spec, _ i: Int) -> String {
            if spec.longIndices.contains(i) || spec.mediumIndices.contains(i) { return "assistant" }
            if !spec.mediumIndices.isEmpty { return "user" }
            return i % 2 == 0 ? "user" : "assistant"
        }

        static func content(_ spec: Spec, _ i: Int) -> String {
            if spec.longIndices.contains(i) { return longText(nodeId: nodeId(spec, i)) }
            if spec.mediumIndices.contains(i) { return mediumText(i) }
            return body(i)
        }

        static func createTime(_ spec: Spec, _ i: Int) -> Date { baseDate.addingTimeInterval(Double(i - spec.count) * 30) }

        /// 配比同 legacy PerfSeed：每 10 条 1 条代码块、2 条长段、其余短句（PerfSeed.body 也改调这里，逐字不变）
        static func body(_ i: Int) -> String {
            switch i % 10 {
            case 0:
                return "第 \(i) 条。看看这段实现：\n```swift\nfunc advance(_ c: Double, toward t: Double, dt: Double) -> Double {\n    min(t, c + max(1, (t - c) * (1 - exp(-dt / 0.1))))\n}\n```\n指数逼近的关键在 **response** 常数。"
            case 1, 2:
                return "第 \(i) 条。长段落：为了让测量贴近真实使用，这里放一段有一定长度的中文正文，会在气泡里换行成好几行。它包含一些 *强调*、`行内代码` 和列表：\n- 第一点，打开对话的首屏排版\n- 第二点，翻页时三页的重建\n- 第三点，冷启动到能打字的主线程工作\n最后一句收尾。"
            default:
                return "第 \(i) 条：一到两行的常规短句。"
            }
        }

        /// 单段、无换行：文章模式整条交一个渲染器、气泡模式 splitBlocks 按空行拆也只得一块，>3000 字必走异步排版（§7.1）
        static func longText(nodeId: String) -> String {
            var s = "⟦PERF:\(nodeId)⟧ 长文样本：这一整段没有空行，用来让气泡与展开模式把它当成一个块，超过同步排版阈值必须异步排好。"
            var k = 0
            while s.count <= longMinChars + 100 {
                k += 1
                s += "第 \(k) 句（\(nodeId)）：打开对话的首屏必须等这一块异步排版落地，**加粗**、*斜体* 和 `代码` 混在同一段里，不换行。"
            }
            return s
        }

        /// M2 中长文：目标长度按下标轮转 320 / 700 / 1200 / 1800 / 2400 / 2900 字，块型轮换（标题 / 段落含强调与行内代码 /
        /// 无序 / 有序列表 / 引用 / 代码块 / 表格），块间空行；不含链接、公式、剧透等会被正文加工链改写的语法
        static func mediumText(_ i: Int) -> String {
            let targets = [320, 700, 1200, 1800, 2400, 2900]
            let sixK = i == mediumSixKIndex
            let target = sixK ? mediumSixKMaxChars - 150 : targets[(i / 4 * 3 + i % 4) % targets.count]
            var blocks: [String] = ["## 第 \(i) 条 · 中长文样本"]
            var k = 0
            func joined() -> String { blocks.joined(separator: "\n\n") }
            while joined().count < target {
                k += 1
                let next: String
                switch (i + k) % 6 {
                case 0:
                    next = "第 \(k) 段：打开对话时这一整条要在首屏同步解析完，**加粗**、*斜体* 和 `行内代码` 混在同一段里，测的是全文化以后首见同步排版的成本，段落要足够长才会折成好几行。"
                case 1:
                    next = "- 要点 \(k).1：首屏同步解析\n- 要点 \(k).2：TextKit 排版与 UITextView 新建\n- 要点 \(k).3：建行时 LazyVStack 逐项实化"
                case 2:
                    next = "1. 第一步，请求加载\n2. 第二步，建树并应用到列表\n3. 第三步，首屏行成链、锚点稳定"
                case 3:
                    next = "> 引用 \(k)：中长文不走异步，首帧就是真高；这里放一句引用块，看块级样式的排版开销。"
                case 4:
                    next = "```swift\nfunc sample\(k)(_ x: Int) -> Int {\n    (0..<x).reduce(0, +)\n}\n```"
                default:
                    next = "| 项 | 值 |\n|---|---|\n| 段 \(k) | 表格块 |\n| 行数 | 两行 |"
                }
                if (joined() + "\n\n" + next).count > (sixK ? mediumSixKMaxChars : mediumMaxChars) { break }
                blocks.append(next)
            }
            return joined()
        }

        static func nodes(_ spec: Spec) -> [NodeRecord] {
            (0..<spec.count).map { i in
                NodeRecord(id: nodeId(spec, i), parentId: i == 0 ? nil : nodeId(spec, i - 1),
                           childrenIds: i == spec.count - 1 ? [] : [nodeId(spec, i + 1)],
                           content: content(spec, i), role: role(spec, i))
            }
        }

        /// seed 值：nodeCount = 可显示条数（全是有内容的 user / assistant），unreadCount = 0，加载本身不改指纹（§7.2）
        static func conv(_ spec: Spec) -> ConvRecord {
            ConvRecord(currentNodeId: nodeId(spec, spec.count - 1), updateTime: baseDate, nodeCount: spec.count,
                       unreadCount: 0, title: spec.title, memoryEnabled: spec.memoryEnabled)
        }

        /// 线性对话的有序行 ID（旧 → 新），seed 生成，不从 VM 读
        static func expectedRows(_ spec: Spec) -> [String] { (0..<spec.count).map { nodeId(spec, $0) } }

        static func fingerprint(_ spec: Spec) -> ConvFingerprint { ConvFingerprint(nodes: nodes(spec), conv: conv(spec)) }

        /// 正文摘要表（§5.2 比对用）：nodeId → FNV-1a 64
        static func bodyDigests(_ spec: Spec) -> [String: UInt64] {
            Dictionary(uniqueKeysWithValues: (0..<spec.count).map { (nodeId(spec, $0), fnv1a64(content(spec, $0))) })
        }

        /// fixture 配置（长文长度、标记格式、规格表），进整轮 fixture 摘要
        static var configCanonical: String {
            (["long>\(longMinChars)", "marker=⟦PERF:<id>⟧", "base=\(baseDate.timeIntervalSince1970)", "m6k=\(mediumSixKIndex):\(mediumSixKMaxChars)"]
                + all.map { "\($0.key):\($0.count):\($0.longIndices.map(String.init).joined(separator: ","))"
                    + ($0.mediumIndices.isEmpty ? "" : ":m\($0.mediumIndices.count)") }).joined(separator: ";")
        }
    }

    /// 整轮 fixture 摘要：按对话 key 排序的规范串 + 楼层对话数 + 配置
    static func fixtureDigest(_ perConv: [String: ConvFingerprint], benchConvs: Int) -> String {
        let parts = perConv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.canonical)" } + ["benchConvs=\(benchConvs)", Fixture.configCanonical]
        return "fx-" + String(digest(parts), radix: 16)
    }

    /// restore 进程：找不到原楼层 → 明确失败、不切、不删键；不许随便挑一个楼层（§3.3）
    enum FloorRestore: Equatable {
        case switchTo(String)
        /// 已在原楼层（或无键且不在 bench）：幂等收尾，只清键
        case stay
        case fail(String)
    }

    static func floorRestore(saved: String?, current: String, profiles: [String], bench: String) -> FloorRestore {
        guard let saved, !saved.isEmpty else {
            return current == bench ? .fail("restore: original profile key missing") : .stay
        }
        if saved == bench { return .fail("restore: saved original is the bench profile") }
        guard profiles.contains(saved) else { return .fail("restore: original profile missing") }
        return current == saved ? .stay : .switchTo(saved)
    }

    /// 正常启动（无任何测量角色）落在 bench：优先回记下的原楼层（并清键，等同一次 restore）；
    /// 键缺或原楼层不在了才退到第一个非 bench 楼层（保键留证）。返回 nil = 不动
    static func floorGuard(saved: String?, current: String, profiles: [String], bench: String) -> (target: String, clearKey: Bool)? {
        guard current == bench else { return nil }
        if let saved, saved != bench, profiles.contains(saved) { return (saved, true) }
        return profiles.first { $0 != bench }.map { ($0, false) }
    }
}

// MARK: - R4 修复（纵切 3 审，裁决 r4-impl3-rulings.md）

extension PerfChatCore {
    /// C-01：seed 时只要当前不在 bench，当前楼层就是原楼层的真相，覆盖（可能陈旧的）恢复键；已在 bench 上才沿用旧键
    static func seedOriginalKey(saved: String?, current: String, bench: String) -> String? {
        current != bench ? current : saved
    }

    /// C-02：L / D / S 只在 chatV1 协议的 seed 里种；legacy / launchV2 的 seed 不碰
    static func seedsChatV1Fixture(protocol p: String?) -> Bool { p == "chatV1" }

    /// C-06：误写清理扫节点 = 防呆 / seed 强制，或本 id 刚删到了误写对话（不然同 id 的节点成孤儿）
    static func scanStrayNodes(forced: Bool, strayConvs: Int) -> Bool { forced || strayConvs > 0 }

    /// C-10：跳过插入 = sentinel 为真且 L / D / S 都在；缺的逐个重插（先清同 id 残留），重插了就清基线重记
    struct FixtureInsertPlan: Equatable {
        let insert: [String]
        let resetBaseline: Bool
    }

    static func fixtureInsertPlan(sentinel: Bool, present: Set<String>, keys: [String] = Fixture.all.map(\.key)) -> FixtureInsertPlan {
        let missing = keys.filter { !present.contains($0) }
        if sentinel, missing.isEmpty { return FixtureInsertPlan(insert: [], resetBaseline: false) }
        return FixtureInsertPlan(insert: missing, resetBaseline: !missing.isEmpty)
    }

    /// C-04：搜索索引回填是否与本进程重叠（开跑或收尾任一刻在回填 = 该进程样本标记为回填中）
    static func indexBackfill(start: String, end: String) -> Bool { start == "building" || end == "building" }
}
// MARK: - R5 纵切 4 审余项（裁决 r5-impl4-rulings.md）

extension PerfChatCore {
    /// R5 C-07：跳转类（搜索）以目标行为锚成链——目标行必须与有效视口相交，向新（视觉下方）、向旧（视觉上方）
    /// 逐行接到视口边缘或列表端点，相邻间隙 ∈ [0, 间距 + 1 物理像素]；返回链（旧 → 新）。
    /// 贴底成链（messageChain）从最新行起算，跳到深处后最新行不在底部，只能判 gap，所以跳转要单独定义
    static func messageChainAround(anchor: String, expected: [String], rects: [String: CGRect], viewport: CGRect?,
                                   spacing: CGFloat, scale: CGFloat) -> ChainOutcome {
        guard let vp = viewport, vp.height > 0 else { return .noViewport }
        guard let i = expected.firstIndex(of: anchor) else { return .missingRow(anchor) }
        guard let r0 = rects[anchor] else { return .missingRow(anchor) }
        guard r0.intersects(vp) else { return .gap(anchor, r0.midY - vp.midY) }
        let tol = spacing + 1 / scale + 1e-6
        var older: [String] = []
        var edge = r0.minY
        var j = i - 1
        while edge > vp.minY, j >= 0 {
            let id = expected[j]
            guard let r = rects[id] else { return .missingRow(id) }
            let gap = edge - r.maxY
            if gap < -1e-6 || gap > tol { return .gap(id, gap) }
            older.append(id)
            edge = r.minY
            j -= 1
        }
        var newer: [String] = []
        edge = r0.maxY
        j = i + 1
        while edge < vp.maxY, j < expected.count {
            let id = expected[j]
            guard let r = rects[id] else { return .missingRow(id) }
            let gap = r.minY - edge
            if gap < -1e-6 || gap > tol { return .gap(id, gap) }
            newer.append(id)
            edge = r.maxY
            j += 1
        }
        return .complete(older.reversed() + [anchor] + newer)
    }

    /// R5 C-04：必需异步行的正文证据按 (摘要, cacheDims) 匹配——摘要 = fixture 预期渲染文本，cacheDims = 本行当前维度
    /// （该行最近一条回执的维度）。冷访要同键 asyncBegin → asyncEnd；热访接受同键命中，没命中照样要 async 对
    static func markdownEvidence(_ receipts: [MarkdownReceipt], expectedDigest: UInt64?, warm: Bool) -> Bool {
        guard let dims = receipts.last?.cacheDims else { return false }
        var begun = false
        for m in receipts where m.cacheDims == dims && (expectedDigest == nil || m.digest == expectedDigest) {
            switch m.kind {
            case "asyncBegin": begun = true
            case "asyncEnd": if begun { return true }
            // L1 ③（plan §3 L1 就绪合同）：长文首见同步解析 = 首帧即真身，冷访也算正文到位（不再有 async 回执）
            case "initSync": return true
            case "initHit", "taskHit": if warm { return true }
            default: break
            }
        }
        return false
    }

    /// R5 C-10：applied 快照的缓存键——revision 只作单调参考，另核行数 + 首末行 id + 身份（都是 O(1)）；
    /// revision 漏自增的写点改了路径时照样重算
    /// 首末行比对象身份（ObjectIdentifier），不读模型属性——body 里不新增观察依赖
    struct AppliedKey: Equatable {
        let revision: Int
        let count: Int
        let first: ObjectIdentifier?
        let last: ObjectIdentifier?
        let profileId: String?
        let conversationId: String?
    }

    /// R5 C-09 / K-07：行句柄 → 登记 id 的双向表。换 id（平台视图被复用到别的行）先清旧键，
    /// 不让两个 id 指向同一个句柄、拿到同一个 rect；离开窗口只清仍指向自己的键
    struct RowKeys<Handle: Hashable> {
        private(set) var byId: [String: Handle] = [:]
        private(set) var byHandle: [Handle: String] = [:]

        mutating func moved(_ h: Handle, id: String, inWindow: Bool) {
            if let old = byHandle[h], old != id || !inWindow {
                if byId[old] == h { byId[old] = nil }
                byHandle[h] = nil
            }
            guard !id.isEmpty else { return }
            if inWindow {
                if let prev = byId[id], prev != h { byHandle[prev] = nil }
                byId[id] = h
                byHandle[h] = id
            } else if byId[id] == h {
                byId[id] = nil
            }
        }

        mutating func drop(_ h: Handle) {
            guard let id = byHandle.removeValue(forKey: h) else { return }
            if byId[id] == h { byId[id] = nil }
        }
    }

    struct ApplyRecord: Equatable {
        let req: Int
        let t: Double
        let dropped: Bool
        let changedRows: Bool
    }

    /// R5 C-08 / K-03：A→B→A 冒烟判定（事后从 apply 日志算，不依赖当时有没有挂着 occurrence）。
    /// lastChanger = 最后一次**改写**行的 apply（§6.3 合同），断言用它；迟到 = 最终请求 t0 之后到达、req 更旧的 apply / 丢弃
    struct ABAVerdict: Equatable {
        let lastWriter: Int?
        let lastChanger: Int?
        let lateApplies: Int
        let lateChangingApplies: Int
        let lateDropped: Int
        /// 最后一次改写行的不是最终请求 = 导航错
        var navigationOK: Bool { lastChanger == nil || lastChanger == finalReq }
        let finalReq: Int
    }

    static func abaVerdict(_ log: [ApplyRecord], finalReq: Int, finalT0: Double) -> ABAVerdict {
        let written = log.filter { !$0.dropped }
        let late = log.filter { $0.req < finalReq && $0.t >= finalT0 }
        return ABAVerdict(lastWriter: written.last?.req, lastChanger: written.last(where: \.changedRows)?.req,
                          lateApplies: late.filter { !$0.dropped }.count,
                          lateChangingApplies: late.filter { !$0.dropped && $0.changedRows }.count,
                          lateDropped: late.filter(\.dropped).count, finalReq: finalReq)
    }
}

// MARK: - 纵切 5 深翻驱动（§6.5；协议 traverseFixture / 纵切 5 字段契约）

extension PerfChatCore {
    enum Traverse {
        /// 必经检查点 = 每第 every 条、全部长文、首末条（下标升序去重）；与协议 traverseFixture 同源
        static func checkpoints(count: Int, every: Int, long: [Int]) -> [Int] {
            Array(Set(stride(from: 0, to: count, by: every)).union([count - 1]).union(long.filter { $0 >= 0 && $0 < count })).sorted()
        }

        /// 下一个检查点相对有效视口的位置（沿行进方向）。older = coldUp：offset 增、行从视觉上方进来；
        /// newer = returnDown：offset 减、行从下方进来。enter / back = 行越过视口边进来一截（min(行高, 半视口)）要走的距离；
        /// 行没实化时按下标与已实化区间判前后（nil 距离）
        enum Relation: Equatable {
            case inView
            case ahead(enter: CGFloat?)
            case passed(back: CGFloat?)
            case noRows
        }

        static func relation(older: Bool, rect: CGRect?, index: Int, viewport vp: CGRect, realized: ClosedRange<Int>?) -> Relation {
            if let r = rect {
                if r.maxY > vp.minY, r.minY < vp.maxY { return .inView }
                let margin = min(r.height, vp.height / 2)
                let above = r.maxY <= vp.minY
                let dist = above ? vp.minY - r.maxY : r.minY - vp.maxY
                return above == older ? .ahead(enter: dist + margin) : .passed(back: dist + margin)
            }
            guard let range = realized else { return .noRows }
            if older { return index > range.upperBound ? .passed(back: nil) : .ahead(enter: nil) }
            return index < range.lowerBound ? .passed(back: nil) : .ahead(enter: nil)
        }

        /// free = 按名义步长走；capped = 为检查点截短（走到它刚好进视口）；seek = 越过了、往回找；hold = 视口里没行、原地等实化
        enum StepKind: String { case free, capped, seek, hold }

        struct Step: Equatable {
            /// 沿行进方向的位移（pt），负 = 回找
            let delta: CGFloat
            let kind: StepKind
        }

        /// 名义步长 = min(speed × dt, stepCapFrac × 有效视口高)；stepCap 关掉（测试钩子）只剩 speed × dt
        static func nominal(speed: Double, dt: Double, viewportHeight: CGFloat, stepCapFrac: Double, stepCap: Bool) -> CGFloat {
            let raw = CGFloat(max(0, speed * dt))
            return stepCap ? min(raw, CGFloat(stepCapFrac) * viewportHeight) : raw
        }

        /// 检查点约束（checkpointWait 关掉 = 测试钩子，一律按名义步长走）。回找距离未知（行没实化）时每帧最多退 seekCap
        /// （= stepCapFrac × 视口高，与 stepCap 开关无关）：否则名义步长很大时来回跨过同一行、永远找不到
        static func step(nominal: CGFloat, relation: Relation, checkpointWait: Bool, seekCap: CGFloat) -> Step {
            guard checkpointWait else { return Step(delta: nominal, kind: .free) }
            switch relation {
            case .inView, .ahead(enter: nil):
                return Step(delta: nominal, kind: .free)
            case .ahead(enter: let e?):
                return e < nominal ? Step(delta: max(0, e), kind: .capped) : Step(delta: nominal, kind: .free)
            case .passed(back: let b):
                return Step(delta: -min(nominal, b ?? seekCap), kind: .seek)
            case .noRows:
                return Step(delta: 0, kind: .hold)
            }
        }

        /// 计划检查点里本阶段没命中的（升序）
        static func missing(planned: [Int], hits: Set<Int>) -> [Int] { planned.filter { !hits.contains($0) } }

        /// R6 C-06：本帧写入的目标 offset——沿行进方向走 delta，钳在 [最新端, 最旧端估算] 之间。
        /// olderSign = 列表实现声明的「往更旧走」offset 符号（反转列表 +1、正向列表 −1）；最旧端估算落在最新端的反侧时按最新端算
        static func target(offset: CGFloat, delta: CGFloat, older: Bool, olderSign: CGFloat, newest: CGFloat, oldest: CGFloat) -> CGFloat {
            let s: CGFloat = olderSign < 0 ? -1 : 1
            let far = s > 0 ? max(newest, oldest) : min(newest, oldest)
            return min(max(offset + (older ? s : -s) * delta, min(newest, far)), max(newest, far))
        }

        /// R6 C-05 / C-09：遍历期间的仪器自检。检查点行已实化（下标落在已实化区间内）却没有 rect = 探针漏登记，
        /// 驱动会「前进—越过—回找」来回振荡到阶段超时、被记成产品慢；探针 / 视口 / 行连续缺失同理。两者都改判仪器
        struct Watch {
            static let unregisteredFrames = 30
            static let reversalLimit = 3
            static let blindSeconds = 2.0
            private var checkpoint: Int?
            private(set) var unregistered = 0
            private(set) var reversals = 0
            private var lastAhead: Bool?
            private var blindSince: Double?

            /// 每帧（有行时）喂一次：当前检查点、它的 relation、是否「在已实化区间内却无 rect」
            mutating func feed(checkpoint c: Int?, relation: Relation, unregisteredInRange: Bool) -> Failure? {
                if c != checkpoint {
                    checkpoint = c
                    unregistered = 0
                    reversals = 0
                    lastAhead = nil
                }
                guard let c else { return nil }
                if unregisteredInRange { unregistered += 1 }
                let ahead: Bool?
                switch relation {
                case .ahead: ahead = true
                case .passed: ahead = false
                case .inView, .noRows: ahead = nil
                }
                if let a = ahead {
                    if let l = lastAhead, l != a { reversals += 1 }
                    lastAhead = a
                }
                guard unregistered >= Self.unregisteredFrames || (unregistered > 0 && reversals >= Self.reversalLimit) else { return nil }
                return Failure(.probeMissedCheckpoint, "checkpoint #\(c) realized but unregistered (\(unregistered) frames, \(reversals) reversals)")
            }

            /// 探针、视口与行都在的帧：清掉缺失连串
            mutating func sighted() { blindSince = nil }

            /// 探针 / 视口 / 行缺失的帧：连续 blindSeconds 秒判仪器 probeMissing（不落到 timeCap）
            mutating func blind(at now: Double, _ what: String) -> Failure? {
                let since = blindSince ?? now
                blindSince = since
                guard now - since >= Self.blindSeconds else { return nil }
                return Failure(.probeMissing, "\(what) for \(String(format: "%.1f", now - since))s during traverse")
            }
        }

        /// R6 C-01：[from, to] 按 width 秒切箱（末箱不足 width 照报实长；to ≤ from 为空）
        static func bins(from a: Double, to b: Double, width: Double) -> [Interval] {
            guard b > a, width > 0 else { return [] }
            var out: [Interval] = []
            var s = a
            while s < b - 1e-9 {
                out.append(Interval(start: s, end: min(b, s + width)))
                s += width
            }
            return out
        }
    }
}

// MARK: - 纵切 6 流式：脚本资源 perf-stream-v1 + lint + turn 纯计量（§6.6）

extension PerfChatCore {
    /// 脚本流资源（§6.6）：终稿 ~2000 字（标题、列表、代码块、一段 >300 字不换行长段——增量渲染在同一块里持续生长），切片与相对到达时刻全确定性；
    /// 连续文本 turn：不调工具、不含 URL / 网页 / 卡片 / intent 围栏（§3.1 清点、§3.2 turn 收口广播），lint 挡住
    enum StreamScript {
        struct Script: Equatable {
            let id: String
            let slices: [String]
            /// 相对开播的计划到达时刻（秒，非降序）；终片之后同一 tick 调 onComplete
            let offsets: [Double]
            var final: String { slices.joined() }
            var duration: Double { offsets.last ?? 0 }
        }

        static let credentialId = "perf-scripted"
        static let userText = "[PERF] 流式脚本 turn：按固定格式写一篇说明，不要调用任何工具。"
        /// 首片延迟（模拟首 token 时间）+ 片长 / 片间隔循环表：长短交错、偶有 0.3s 停顿；到达表墙钟锚定（ArrivalSchedule）
        static let firstOffset = 0.4
        static let sliceChars = [6, 14, 22, 9, 30, 12, 18, 8]
        static let gaps = [0.05, 0.08, 0.04, 0.12, 0.06, 0.10, 0.07, 0.30]

        static let v1 = make(id: "stream-v1", text: finalTextV1)

        /// R14-03（chatV1-r10）：长终稿两档——7k（在 ③ 门槛 6000 与 L1c 上限 12000 之间）/ 15k（超过 L1c 上限）；片长 ×4 控时长
        static let v7k = make(id: "stream-v7k", text: longFinal(7000), sliceScale: 4)
        static let v15k = make(id: "stream-v15k", text: longFinal(15000), sliceScale: 4)

        static func script(_ modelId: String) -> Script? { [v1, v7k, v15k].first { $0.id == modelId } }

        /// v1 终稿后面续「续写第 k 段」直到 ≥ minChars（块间空行，同 lint 白名单）
        static func longFinal(_ minChars: Int) -> String {
            var text = finalTextV1
            var k = 0
            while text.count < minChars {
                k += 1
                text += "\n\n续写第 \(k) 段：终稿很长时流完那一刻静态分支首见就要排好整条，这一段只是把长度撑上去，**加粗**和 `行内代码` 混在里面，不换行。"
            }
            return text
        }

        static var finalTextV1: String {
            var long = "长段落："
            var k = 0
            while long.count <= 640 {
                k += 1
                long += "第 \(k) 句把流式正文写成一段不换行的长文，用来跨过文章模式三百字的折叠线，也让增量渲染在同一个块里持续生长，"
            }
            long += "这一段到此结束。"
            let list = (1...8).map { "- 第 \($0) 条要点：占位节点插入之后才开始喂字，第 \($0) 片之后渲染输入要跟上供给" }.joined(separator: "\n")
            let code = """
            ```swift
            func pace(shown: Int, target: Int, dt: Double, horizon: Double) -> Int {
                let backlog = target - shown
                guard backlog > 0 else { return shown }
                return shown + min(backlog, max(1, Int((Double(backlog) * dt / horizon).rounded(.up))))
            }
            ```
            """
            let explain = (1...3).map { "说明第 \($0) 段：供给进度看脚本每片的计划与实际到达，渲染输入进度看真正交给渲染器的长度，静态终稿消费看定稿后静态分支消费的正文摘要与折叠，三类证据分开记，不拿节拍器的输出当已显示。" }
                .joined(separator: "\n\n")
            let tail = (1...6).map { "收尾第 \($0) 段：结束时写回终稿、保存一次，再由收尾导航跳到助手这一条，静态分支按真实折叠规则消费终稿。" }
                .joined(separator: "\n\n")
            return ["# 流式测量样本 perf-stream-v1",
                    "这是一段脚本化的助手回复，用来在真实发送生命周期里测量流式渲染。它不经过网络，切片与到达时刻都是固定的，慢的那一臂会成簇到达而不是整体拉长。",
                    "## 要点", list, "## 代码", code, long, "## 说明", explain, "## 小结", tail].joined(separator: "\n\n")
        }

        /// 按字符（grapheme）切片，片长 / 间隔按循环表取；offsets[0] = firstOffset
        static func make(id: String, text: String, sliceScale: Int = 1) -> Script {
            var slices: [String] = []
            var offsets: [Double] = []
            var i = text.startIndex
            var k = 0
            var t = firstOffset
            while i < text.endIndex {
                let j = text.index(i, offsetBy: sliceChars[k % sliceChars.count] * sliceScale, limitedBy: text.endIndex) ?? text.endIndex
                slices.append(String(text[i..<j]))
                offsets.append((t * 1000).rounded() / 1000)
                t += gaps[k % gaps.count]
                k += 1
                i = j
            }
            return Script(id: id, slices: slices, offsets: offsets)
        }

        /// lint（§6.6 / §3.1 清点 / §3.2）：围栏语言只许白名单（挡 html / mermaid / card-* / voice / health-log / trade /
        /// anniversary / book-note / timer…）；不许 URL、HTML 标签、宏、思考标签。返回问题列表，空 = 通过
        static let fenceAllowlist: Set<String> = ["swift"]
        static func lint(_ text: String) -> [String] {
            var problems: [String] = []
            for line in text.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("```") || t.hasPrefix("~~~") else { continue }
                let lang = t.drop(while: { $0 == "`" || $0 == "~" }).trimmingCharacters(in: .whitespaces).lowercased()
                if !lang.isEmpty, !fenceAllowlist.contains(lang) { problems.append("fence \(lang)") }
            }
            let lower = text.lowercased()
            for needle in ["http://", "https://", "www.", "{{", "[thinking]", "[/thinking]", "](", "card-"] where lower.contains(needle) {
                problems.append("contains \(needle)")
            }
            if lower.range(of: "<[a-z!/]", options: .regularExpression) != nil { problems.append("html tag") }
            return problems
        }
    }

    /// turn 纯计量（§6.6 三类证据）：供给（脚本侧每片实际到达 + 该片之后渲染输入应有的长度）对渲染输入进度
    enum Turn {
        /// R7 阈值（协议 turnThresholds 同源；G0 A/A 前的先行值，冻结时由 A/A 标定后写进冻结文件）
        enum Thresholds {
            /// C-01：片到达后多久还没被渲染输入追上 = 晚到（产品慢）；删失片按删失下界比
            static let chunkLateS = 2.0
            /// C-01：窗口截止前 ≥ 这么久到达的片必须已追上，否则 = 未收敛（产品慢）
            static let convergeS = 1.0
            /// C-04：离底锚点漂移上限（pt）
            static let anchorDriftMaxPt = 2.0
            /// C-05：在底收尾（provider.complete 前最后一次采样）离底上限（pt）
            static let followEndMaxPt = 12.0
            /// C-04：离底期间离底距离下限（pt）= 产品在底阈值（|fromBottom| < 200 算在底）
            static let offBottomHeldMinPt = 200.0
            /// C-03：上移后流式行顶边留在有效视口内的最小高度（有效视口高的比例）
            static let shiftKeepFrac = 0.25
            /// §14-98：上移量 = 列表 scroll view 高（「屏」，与产品松手回底阈值 bounds.height / 2 同分母）× 0.75，明确越过半屏
            static let shiftScreenFrac = 0.75
            /// R7-10：收尾导航落定后助手行可见高 / min(行高, 有效视口高) 下限（anchor .center；在底时被底边夹住也应整段可见）
            static let finishVisibleMinFrac = 0.9
        }

        /// R7-10：行在有效视口里的可见比例（分母 = min(行高, 视口高)：比视口高的行只要求铺满视口）
        static func visibleFraction(rowMinY: Double, rowMaxY: Double, viewportMinY: Double, viewportMaxY: Double) -> Double {
            let visible = max(0, min(rowMaxY, viewportMaxY) - max(rowMinY, viewportMinY))
            let denom = min(rowMaxY - rowMinY, viewportMaxY - viewportMinY)
            return denom > 0 ? visible / denom : 0
        }

        /// §14-98（改 R7 C-03）：离底上移量固定 = shiftScreenFrac × 屏高（模拟手指上划过半屏后松手读历史）；上移后流式行顶边须落在
        /// 有效视口底上方 ≥ shiftKeepFrac × 有效视口高处（行留在视口里、继续生长），不够就返回 nil（等行再长）。keep = 上移后行顶到有效视口底的距离
        static func plannedShift(streamRowMinY: Double, viewportMaxY: Double, viewportHeight: Double, screenHeight: Double) -> (shift: Double, keep: Double)? {
            let shift = screenHeight * Thresholds.shiftScreenFrac
            let keep = viewportMaxY - (streamRowMinY + shift)
            return keep >= viewportHeight * Thresholds.shiftKeepFrac ? (shift, keep) : nil
        }

        struct Chunk: Equatable {
            let k: Int
            let arrival: Double
            let target: Int
            /// 到达 → 渲染输入首次 ≥ target（秒）；nil = 删失
            let latency: Double?
            /// 删失下界 = 可观察截止 − 到达（秒）
            let lowerBound: Double?
            /// 删失原因是可观察截止前流式行已不在（离底上移后不可观察），不是真晚到（K-01）
            let unobservable: Bool
        }

        struct ChunkStats: Equatable {
            let chunks: [Chunk]
            /// 渲染输入在该片到达之前就已 ≥ 应有长度：应有长度加工链与产品不一致 = 仪器（C-07）
            let aheadOfSupply: [Int]
            var measured: [Double] { chunks.compactMap(\.latency) }
            var censoredBounds: [Double] { chunks.filter { !$0.unobservable }.compactMap(\.lowerBound) }
            var censored: Int { censoredBounds.count }
            var censoredUnobservable: Int { chunks.filter(\.unobservable).count }
            /// 进分位数的样本：测得值 + 可观察删失下界（C-07，与 R3 A-02 同口径），不可观察的不进
            var values: [Double] { measured + censoredBounds }
            var late: [Chunk] { chunks.filter { !$0.unobservable && max($0.latency ?? 0, $0.lowerBound ?? 0) > Thresholds.chunkLateS } }
            var notConverged: [Chunk] { chunks.filter { !$0.unobservable && ($0.lowerBound ?? 0) >= Thresholds.convergeS } }
            /// p95 落在删失下界上（下界 ≥ 测得的 p95 值）：p95 是下界，不是测得值
            var p95IsLowerBound: Bool {
                guard let p = percentile(values, 0.95) else { return false }
                return censoredBounds.contains { $0 >= p }
            }
        }

        /// 片到达 → 渲染输入追上（§6.6 + R7 C-01 / C-02 / C-07 / K-01）。targets[k] = 第 k 片到达后渲染输入应有的长度（同一加工链），
        /// 只取让应有长度变长的片；只计到达在 [from, until) 的片（from 之前到达的片只抬高基线）；render = (t, chars) 升序。
        /// 可观察截止 horizon = min(until, lostAt)：lostAt = 流式行离开实化范围（之后渲染输入不再可观察）；
        /// 删失片在 horizon 前不足 convergeS 到达、且 lostAt 早于 until 的，记不可观察（不进分位、不判晚到 / 未收敛）
        static func chunks(arrivals: [Double], targets: [Int], render: [(t: Double, chars: Int)],
                           from: Double, until: Double, lostAt: Double? = nil) -> ChunkStats {
            let horizon = min(until, lostAt ?? until)
            var out: [Chunk] = []
            var ahead: [Int] = []
            var last = 0
            for (k, a) in arrivals.enumerated() where k < targets.count && targets[k] > last {
                last = targets[k]
                guard a >= from, a < until else { continue }
                if let hit = render.first(where: { $0.chars >= last && $0.t <= horizon }) {
                    if hit.t < a { ahead.append(k) }
                    out.append(Chunk(k: k, arrival: a, target: last, latency: max(0, hit.t - a), lowerBound: nil, unobservable: false))
                } else {
                    let unobservable = lostAt.map { $0 < until && horizon - a < Thresholds.convergeS } ?? false
                    out.append(Chunk(k: k, arrival: a, target: last, latency: nil, lowerBound: max(0, horizon - a), unobservable: unobservable))
                }
            }
            return ChunkStats(chunks: out, aheadOfSupply: ahead)
        }

        /// 渲染输入最长停滞（秒）：[from, to) 内「供给应有长度 > 渲染输入」且渲染输入没再增长的最长连续时长；
        /// supply = (到达时刻, 该片后渲染输入应有长度)，与 render 同一单位
        static func maxStall(supply: [(t: Double, chars: Int)], render: [(t: Double, chars: Int)], from: Double, to: Double) -> Double {
            let events = (supply.map { ($0.t, true, $0.chars) } + render.map { ($0.t, false, $0.chars) }).sorted { $0.0 < $1.0 }
            var s = 0, r = 0
            var start: Double?
            var worst = 0.0
            func close(_ t: Double) {
                if let a = start { worst = max(worst, min(t, to) - max(a, from)) }
                start = nil
            }
            for (t, isSupply, c) in events {
                if t >= to { break }
                if isSupply {
                    s = max(s, c)
                    if s > r, start == nil { start = t }
                } else if c > r {
                    close(t)
                    r = c
                    if s > r { start = t }
                }
            }
            close(to)
            return max(0, worst)
        }

        static func percentile(_ v: [Double], _ p: Double) -> Double? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted()
            return s[max(0, Int((p * Double(s.count)).rounded(.up)) - 1)]
        }
    }
}
#endif
