#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation
import SwiftData
import UIKit

/// 脚本流 → 测量台的钩子入口（主线程上被调；PerfScriptedStream 只在严格测量角色下存在）
enum PerfChatV1Turn {
    static func notePlay(script: PerfChatCore.StreamScript.Script, anchor: Double) {
        MainActor.assumeIsolated { ChatV1Turn.active?.notePlay(script: script, anchor: anchor) }
    }

    static func noteSlice(_ k: Int, planned: Double, actual: Double, cumChars: Int) {
        MainActor.assumeIsolated { ChatV1Turn.active?.noteSlice(k, planned: planned, actual: actual, cumChars: cumChars) }
    }

    static func noteProviderComplete(at t: Double) {
        MainActor.assumeIsolated { ChatV1Turn.active?.noteProviderComplete(at: t) }
    }
}

/// 纵切 6 · S5 流式 turn（plan-chat-list-perf-p0 §6.6）：测量台调真实 `sendMessage`（模型 = perf-scripted / stream-v1），
/// 走真实生命周期（user 插入 → placeholder → 喂字 → onComplete 写终稿 + 保存 → 收尾导航）。断言拆两段：
/// 连续段（在底跟随 / 离底钉位）截止在 provider.complete；之后单验收尾导航回执与静态收敛。
/// 三类证据：供给（脚本侧）/ 渲染输入（§5.2 streamInput）/ 静态终稿消费（consumed）。run JSON 字段契约 = testdata/chatv1/turn-*.json
@MainActor
final class TurnOcc {
    typealias Core = PerfChatCore
    let offBottom: Bool
    let target: LoadOcc.Target
    let reqId: Int
    let t0: Double
    let script: Core.StreamScript.Script
    let article: Bool
    private(set) var tracker: Core.OpTracker
    private(set) var failures: [Core.Failure] = []
    private(set) var censoredAt: Double?
    private(set) var userId: String?
    private(set) var assistantId: String?
    private let jumpStart = PerfRenderLedger.jumps.count
    private let streamStart = PerfRenderLedger.streamInputs.count
    let pins0 = PerfChatV1.pins
    let glides0 = PerfChatV1.glides

    // 供给（脚本侧）
    private(set) var anchor: Double?
    private(set) var planned: [Double] = []
    private(set) var actual: [Double] = []
    private(set) var cumChars: [Int] = []
    private(set) var routerStreamingAtFirst: Bool?
    private var counts0: [String: Int] = [:]
    private(set) var counts: [String: Int] = [:]
    private(set) var providerComplete: Double?

    // 连续段
    private(set) var followT: [Double] = []
    private(set) var fromBottom: [Double] = []
    private(set) var shiftT: Double?
    private(set) var shiftPt: Double = 0
    private(set) var renderAtShift = 0
    /// 上移前本 turn 是否启动过回底滑入（在底跟随时它一直在跑；上移时经 beginScrub 让出）
    private(set) var glideStartedBeforeShift = false
    private var ticksSinceShift = 0
    private(set) var anchorId: String?
    private(set) var anchorMinY0: CGFloat = 0
    private(set) var anchorHeight: CGFloat = 0
    /// 锚点行跳出实化范围的时刻与漂移下界（之后不再采样）
    private(set) var anchorLostT: Double?
    private(set) var anchorLostLowerBound: Double?
    private(set) var chosenT: Double?
    private(set) var driftT: [Double] = []
    private(set) var drift: [Double] = []
    /// 上移后流式行第一次不在有效视口内（或已不实化）的时刻：之后渲染输入不可观察（文章 iOS onDisappear 收掉 source），K-01 据此分删失成因
    private(set) var streamRowLostT: Double?
    // R7 C-03 / C-04：上移量与上移后的流式行、离底距离
    private(set) var plannedShiftPt: Double = 0
    /// §14-98：列表 scroll view 高（「屏」）与上移后那一刻的离底距离（须 > 半屏 = 真松手也不回底跟随）
    private(set) var screenHeight: Double = 0
    private(set) var fromBottomAfterShift: Double?
    private(set) var keepPt: Double = 0
    private(set) var rowMinYBeforeShift: Double = 0
    private(set) var rowHeightAtShift: Double = 0
    private(set) var rowTopAfterShift: Double?
    private(set) var pinsAtShift = 0
    private(set) var rowT: [Double] = []
    private(set) var rowVisible: [Bool] = []
    private(set) var rowHeight: [Double?] = []
    private(set) var heldT: [Double] = []
    private(set) var heldFromBottom: [Double] = []
    private(set) var pinsAtComplete = 0

    // 收尾
    private(set) var finishJump: PerfRenderLedger.Jump?
    private(set) var finishInViewport = false
    private(set) var finalConsumed: PerfRenderLedger.Consumed?
    private(set) var finishVisibleFraction: Double?
    private(set) var consumedAfterComplete = 0
    private(set) var confirmed: Double?
    private var stability: Core.ChainStability
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var finished = false

    init(offBottom: Bool, target: LoadOcc.Target, reqId: Int, t0: Double, script: Core.StreamScript.Script) {
        self.offBottom = offBottom
        self.target = target
        self.reqId = reqId
        self.t0 = t0
        self.script = script
        article = !UserDefaults.standard.bool(forKey: "chatBubbleMode")
        tracker = Core.OpTracker(spec: .turn(scriptDuration: script.duration), reqId: reqId, t0: t0)
        stability = Core.ChainStability(scale: UIScreen.main.scale)
    }

    var deadline: Double { t0 + script.duration + 10 }

    /// sendMessage 返回后：currentPath 末两行 = 本 turn 新建的 user / placeholder 助手
    func noteSent(user: String, assistant: String) {
        userId = user
        assistantId = assistant
        sendProbe = ChatListProbe.current
    }

    // MARK: 脚本流事件

    func notePlay(script s: Core.StreamScript.Script, anchor a: Double) {
        guard anchor == nil else { return }
        anchor = a
    }

    func noteSlice(_ k: Int, planned p: Double, actual a: Double, cumChars c: Int) {
        if planned.isEmpty {
            routerStreamingAtFirst = PerfHarness.viewModel?.providerRouter.isStreaming
            counts0 = PerfCount.snapshot()
        }
        planned.append(p)
        actual.append(a)
        cumChars.append(c)
    }

    func noteProviderComplete(at t: Double) {
        guard providerComplete == nil else { return }
        providerComplete = t
        pinsAtComplete = PerfChatV1.pins
        tracker.record(.providerComplete, at: t)
        let diff = PerfCount.diff(from: counts0, to: PerfCount.snapshot())
        counts = Dictionary(uniqueKeysWithValues: ["cardFlowBody", "contentViewBody", "bubbleMake", "updatePages"].map { ($0, diff[$0] ?? 0) })
        // 连续段截止：发送段回执与渲染输入首进度必须在 provider 完成之前到（§6.6 两段断言的前一段）
        scanReceipts()
        if tracker.times[.userJump] == nil {
            fail(.navigationMismatch, "userJump: no scrolled receipt for user node before provider.complete")
        }
        if tracker.times[.firstProgress] == nil {
            fail(.streamNoProgress, "render input never progressed before provider.complete (\(cumChars.last ?? 0) chars supplied)")
        }
        if offBottom, anchorId == nil {
            fail(.configMismatch, "off-bottom anchor not chosen before provider.complete (render input \(renderChars(until: t)) chars at complete)")
        }
    }

    // MARK: 渲染账本读取（只读本 turn 起的增量）

    private func streamInputs() -> ArraySlice<PerfRenderLedger.StreamInput> {
        PerfRenderLedger.streamInputs.dropFirst(streamStart)
    }

    func renderSeries() -> [(t: Double, chars: Int)] {
        guard let a = assistantId else { return [] }
        return streamInputs().filter { $0.nodeId == a }.map { ($0.t, $0.chars) }
    }

    func renderChars(until t: Double) -> Int {
        guard let a = assistantId else { return 0 }
        return streamInputs().last(where: { $0.nodeId == a && $0.t <= t })?.chars ?? 0
    }

    // MARK: 逐帧

    func tick(_ now: Double) {
        guard !finished else { return }
        if now > deadline {
            censoredAt = now
            fail(.turnTimeout, "turn not confirmed within script \(Int(script.duration))s + 10s")
            finish()
            return
        }
        guard let aid = assistantId else { return }
        scanReceipts()
        guard !finished else { return }
        guard let probe = ChatListProbe.current, probe.conversationId == target.conv.id,
              let window = probe.scrollView?.window, let visible = probe.viewportRect(in: window),
              let vp = Core.effectiveViewport(visible, occlusion: probe.occlusion) else { return }
        var rects: [String: CGRect] = [:]
        for r in probe.visibleRows(in: window) { rects[r.id] = r.windowRect }
        if let pc = providerComplete {
            finishing(now: now, pc: pc, aid: aid, rects: rects, vp: vp)
        } else {
            continuous(now: now, probe: probe, rects: rects, vp: vp)
        }
    }

    /// 跳转回执（发送段 user / 收尾段助手）与渲染输入首进度：从账本增量里取，provider 完成那一刻也扫一次（不漏同帧到的）
    private func scanReceipts() {
        guard let uid = userId, let aid = assistantId else { return }
        for j in PerfRenderLedger.jumps.dropFirst(jumpStart) {
            if j.target == uid, tracker.times[.userJump] == nil {
                guard j.outcome == "scrolled" else { fail(.navigationMismatch, "userJump outcome \(j.outcome)"); return }
                tracker.record(.userJump, at: j.t)
            }
            if j.target == aid, finishJump == nil, let pc = providerComplete, j.t >= pc {
                finishJump = j
                if j.outcome == "scrolled" { tracker.record(.finishJump, at: j.t) }
            }
        }
        if tracker.times[.firstProgress] == nil, let first = streamInputs().first(where: { $0.nodeId == aid && $0.chars > 0 }) {
            tracker.record(.firstProgress, at: first.t)
        }
    }

    /// 连续段（§6.6）：在底 = 逐回调离底距离；离底 = 渲染输入满 200 字后上移到流式行顶边留在视口内（R7 C-03）、等 2 回调、选锚点、逐回调记锚点漂移与离底距离
    private func continuous(now: Double, probe: any ChatListProbing, rects: [String: CGRect], vp: CGRect) {
        guard let fp = tracker.times[.firstProgress] else { return }
        if !offBottom {
            guard let uj = tracker.times[.userJump], now >= max(fp, uj), let fb = probe.distanceFromBottom() else { return }
            followT.append(now)
            fromBottom.append(Double(fb))
            return
        }
        guard let aid = assistantId else { return }
        if shiftT == nil {
            let chars = renderChars(until: now)
            guard chars >= Self.shiftChars, let row = rects[aid] else { return }
            // §14-98：上移 0.75 屏（屏 = 列表 scroll view 高，产品松手回底阈值是它的一半），等流式行长到上移后行顶仍在有效视口底上方
            // ≥ 0.25 有效视口高（行留在视口里、渲染继续、生长真实发生、钉位补偿真被行使）
            guard let screen = probe.scrollView?.bounds.height, screen > 0,
                  let plan = Core.Turn.plannedShift(streamRowMinY: Double(row.minY), viewportMaxY: Double(vp.maxY),
                                                    viewportHeight: Double(vp.height), screenHeight: Double(screen)) else { return }
            // 在底跟随时回底滑入（glide）一直在跑：经探针「让出 → 写位置 → 停在历史松手、不回底」（R7 C-08，旧页 = beginScrub / endScrub(false)）
            let wasGliding = PerfChatV1.glides > glides0
            let moved = probe.scrollAwayFromBottom(by: CGFloat(plan.shift))
            glideStartedBeforeShift = wasGliding
            shiftT = now
            shiftPt = Double(moved)
            screenHeight = Double(screen)
            fromBottomAfterShift = probe.distanceFromBottom().map(Double.init)
            plannedShiftPt = plan.shift
            keepPt = plan.keep
            rowMinYBeforeShift = Double(row.minY)
            rowHeightAtShift = Double(row.height)
            renderAtShift = chars
            pinsAtShift = PerfChatV1.pins
            return
        }
        // 上移后流式行：每回调记是否仍在有效视口内与行高（生长量 = 末样本 − 上移时）；第一次不在 = 之后渲染输入不可观察（K-01）
        let row = rects[aid]
        let visible = row.map { $0.maxY > vp.minY && $0.minY < vp.maxY } ?? false
        rowT.append(now)
        rowVisible.append(visible)
        rowHeight.append(row.map { Double($0.height) })
        if rowTopAfterShift == nil, let r = row { rowTopAfterShift = Double(r.minY) }
        if streamRowLostT == nil, !visible { streamRowLostT = now }
        if anchorId == nil {
            ticksSinceShift += 1
            guard ticksSinceShift >= 2 else { return }
            // 完整在有效视口内的种子老行（不是本 turn 新建的两行），取最靠视口中线的
            let seeded = Set(target.expectedRows)
            let candidates = rects.filter { seeded.contains($0.key) && $0.value.minY >= vp.minY && $0.value.maxY <= vp.maxY }
            guard let pick = candidates.min(by: { abs($0.value.midY - vp.midY) < abs($1.value.midY - vp.midY) }) else { return }
            anchorId = pick.key
            anchorMinY0 = pick.value.minY
            anchorHeight = pick.value.height
            chosenT = now
            driftT.append(now)
            drift.append(0)
            return
        }
        // C-04：离底期间一直不在底（产品在底阈值 200）；被拉回 = 离底 op 悄悄变成在底场景，判配置错误
        if let fb = probe.distanceFromBottom() {
            heldT.append(now)
            heldFromBottom.append(Double(fb))
            if Double(fb) < Core.Turn.Thresholds.offBottomHeldMinPt {
                fail(.configMismatch, "offBottomNotHeld: fromBottom \(Int(fb))pt < \(Int(Core.Turn.Thresholds.offBottomHeldMinPt)) at +\(ChatV1Load.ms3(now - (chosenT ?? now)))ms after anchor")
                return
            }
        }
        guard let id = anchorId, anchorLostT == nil else { return }
        guard let r = rects[id] else {
            // 锚点行跳出了实化范围（如生长 Δ > 300 时产品不钉位，整段被推走）：漂移量测不到了，记下界 =
            // 它至少要越过有效视口边才会被拆掉（按选定时位置到上 / 下边的较近者），不再采样；不是探针故障
            anchorLostT = now
            let exitUp = anchorMinY0 + anchorHeight - vp.minY, exitDown = vp.maxY - anchorMinY0
            anchorLostLowerBound = max(drift.max() ?? 0, Double(min(exitUp, exitDown)))
            return
        }
        driftT.append(now)
        drift.append(Double(abs(r.minY - anchorMinY0)))
    }

    /// 收尾段：1s 内收尾导航回执（target = 助手、outcome = scrolled）且助手行进有效视口；静态终稿消费摘要；
    /// confirmed = 助手行几何连续 3 样本稳定 + 之后 500ms 无 >50ms 块
    private func finishing(now: Double, pc: Double, aid: String, rects: [String: CGRect], vp: CGRect) {
        guard let fj = finishJump, fj.outcome == "scrolled" else {
            if let fj = finishJump {
                fail(.navigationMismatch, "finishJump outcome \(fj.outcome) for assistant node")
            } else if now - pc > 1.0 {
                fail(.navigationMismatch, "finishJump: no scrolled receipt for assistant node within 1s of provider.complete")
            }
            return
        }
        let row = rects[aid]
        if let r = row, r.maxY > vp.minY, r.minY < vp.maxY {
            finishInViewport = true
        } else if !finishInViewport, now - fj.t > 1.0 {
            fail(.navigationMismatch, "finishJump: assistant row not in effective viewport within 1s of the receipt")
            return
        }
        if tracker.times[.staticConsumed] == nil, let c = PerfRenderLedger.consumed[aid], c.t >= pc, let d = c.digest {
            finalConsumed = c
            tracker.record(.staticConsumed, at: c.t)
            if d != Core.fnv1a64(script.final) {
                fail(.contentMismatch, "final consumed digest \(ChatV1Load.hex(d)) != script \(ChatV1Load.hex(Core.fnv1a64(script.final)))")
                return
            }
        }
        guard tracker.times[.staticConsumed] != nil, finishInViewport, let r = row else { stability.reset(); return }
        guard let since = stability.feed([Core.ChainRow(id: aid, minY: r.minY, maxY: r.maxY)], at: now) else { return }
        let quietFrom = max(since, MainBlockMonitor.splitLastBlockEnd(after: t0, now: now) ?? 0)
        if now - quietFrom >= 0.5 {
            // R7-10：回执只证明「被消费」；落定后再核落点——助手行可见比例（anchor .center；在底被底边夹住也应整段可见）
            let frac = Core.Turn.visibleFraction(rowMinY: Double(r.minY), rowMaxY: Double(r.maxY), viewportMinY: Double(vp.minY), viewportMaxY: Double(vp.maxY))
            finishVisibleFraction = frac
            if frac < Core.Turn.Thresholds.finishVisibleMinFrac {
                fail(.navigationMismatch, "finishJump landed with assistant row \(Int(frac * 100))% visible (< \(Int(Core.Turn.Thresholds.finishVisibleMinFrac * 100))%) after settling")
                return
            }
            // R7-11：收尾后助手节点每一次静态消费都必须 == 终稿（不只看最后一次）
            let want = Core.fnv1a64(script.final)
            let after = (PerfRenderLedger.consumedLog[aid] ?? []).filter { $0.t >= pc }
            consumedAfterComplete = after.count
            if let bad = after.first(where: { $0.digest != want }) {
                fail(.contentMismatch, "assistant consumed \(ChatV1Load.hex(bad.digest ?? 0)) at +\(ChatV1Load.ms3(bad.t - pc))ms after provider.complete (\(after.count) consumes), != script final")
                return
            }
            confirmed = now
            tracker.record(.confirmed, at: now)
            finish()
        }
    }

    static let shiftChars = 200

    /// 发送时的探针（R7 C-08：应有长度经探针按引擎算；报告时探针可能已注销，留一份弱引用兜底）
    weak var sendProbe: (any ChatListProbing)?

    /// 渲染输入「应有长度」：文章模式 = 正文快照（clean → 剥思考）长度；气泡模式 = 已完成块（末块不渲染）总长。不碰产品缓存
    func renderable(_ raw: String, article: Bool) -> Int? {
        (ChatListProbe.current ?? sendProbe)?.renderableLength(raw: raw, article: article)
    }

    func fail(_ kind: Core.FailureKind, _ detail: String) {
        failures.append(Core.Failure(kind, detail))
        if kind.failureClass == .correctness { finish() }
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
}

// MARK: - 编排与报告

@MainActor
enum ChatV1Turn {
    typealias Core = PerfChatCore
    static var active: TurnOcc?
    static let tailSeconds = 1.5
    /// R7-11：本 turn 新建节点 → 应落库内容摘要
    static var persistExpect: [String: UInt64] = [:]

    /// setup（经列表打开 S 落定 + 1.5s 尾窗）之后调；返回 occurrence 报告（字段契约 = testdata/chatv1/turn-*.json）
    static func run(op: String, target: LoadOcc.Target, prestate: String?) async -> [String: Any] {
        let offBottom = op == "streamOffBottom"
        if let bad = prestate ?? sendPrestate(target) {
            Driver.chatFail(.navigationMismatch, "prestate: \(bad)", occ: 1)
            return ["occ": 1, "target": "S", "status": "correctness"]
        }
        // R14-03：测量钩子 MP_PERF_STREAM_SCRIPT=stream-v7k / stream-v15k 选长终稿脚本（协议 streamScripts 同源）
        let script = PerfHarness.env["MP_PERF_STREAM_SCRIPT"].flatMap(Core.StreamScript.script) ?? Core.StreamScript.v1
        let lint = Core.StreamScript.lint(script.final)
        guard lint.isEmpty else {
            Driver.chatFail(.configMismatch, "stream script lint: \(lint.joined(separator: ", "))", occ: 1)
            return ["occ": 1, "target": "S", "status": "correctness"]
        }
        guard let vm = PerfHarness.viewModel, let ctx = PerfHarness.modelContext, let providers = PerfHarness.providers,
              let profile = PerfHarness.profiles?.currentProfile else {
            Driver.chatFail(.probeMissing, "turn: viewModel / context / providerManager / profile not registered", occ: 1)
            return ["occ": 1, "target": "S", "status": "instrument"]
        }
        let preset = PerfHarness.presets?.preset(byId: profile.presetId) ?? Preset.balanced
        // R7 K-02：应有长度加工链不含正则脚本（clean → 剥思考），bench 楼层 / preset 带正则 = 应有长度与产品不一致，开跑前挡住（fail-closed）
        let regexCount = profile.regexScripts.count + preset.regexScripts.count
        guard regexCount == 0 else {
            Driver.chatFail(.configMismatch, "bench profile / preset has \(regexCount) regex script(s): expected-length pipeline would diverge from the product", occ: 1)
            return ["occ": 1, "target": "S", "status": "correctness"]
        }
        let model = ProviderModel(credentialId: Core.StreamScript.credentialId, modelId: script.id, name: "[PERF] 脚本流")
        let occ = TurnOcc(offBottom: offBottom, target: target, reqId: ChatV1Load.issueReq(), t0: CACurrentMediaTime(), script: script)
        active = occ
        ChatV1Load.emit(.request, occ: 1)
        let sent = vm.sendMessage(Core.StreamScript.userText, model: model, profile: profile, preset: preset,
                                  providerManager: providers, context: ctx)
        let path = vm.currentPath
        guard sent, path.count >= 2, path[path.count - 2].role == "user", path[path.count - 1].role == "assistant" else {
            active = nil
            Driver.chatFail(.navigationMismatch, "sendMessage did not insert user + placeholder (sent \(sent))", occ: 1)
            return ["occ": 1, "target": "S", "status": "correctness"]
        }
        let aid = path[path.count - 1].id
        occ.noteSent(user: path[path.count - 2].id, assistant: aid)
        // R7-11：结束后 S 复原删本 turn 节点前核落库内容（user == 发送原文；provider 完成了的助手 == 脚本终稿），Driver.chatV1Finish 对账
        persistExpect = [path[path.count - 2].id: Core.fnv1a64(Core.StreamScript.userText)]
        // 观察集加上助手节点（静态终稿消费当场算摘要）；收尾导航不被消费的测试钩子点名它
        PerfRenderLedger.observed.insert(aid)
        if PerfHarness.testDropFinishJump { PerfRenderLedger.dropJumpTarget = aid }
        await occ.wait()
        if occ.providerComplete != nil { persistExpect[aid] = Core.fnv1a64(script.final) }
        // 收尾窗 [provider.complete, +1.5s] 要等满再出数
        if let pc = occ.providerComplete {
            let remaining = pc + tailSeconds - CACurrentMediaTime()
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }
        active = nil
        let r = report(occ)
        for f in occ.failures { Driver.chatFail(f.kind, f.detail, occ: 1) }
        return r
    }

    /// §6.1 前置（发送前才相关的那几条，§14-35 留到纵切 6）：草稿为空且不是草稿对话、无排队发送、无编辑 / 引用、timer outbox 无测试楼层事件
    private static func sendPrestate(_ target: LoadOcc.Target) -> String? {
        guard let vm = PerfHarness.viewModel else { return "no viewModel" }
        if vm.isDraftConversation { return "draft conversation" }
        if !(vm.selectedConversation?.draftText ?? "").isEmpty { return "draft text not empty" }
        if !vm.pendingSends.isEmpty { return "pending sends queued" }
        if vm.editingMessage != nil || vm.quotingPreview != nil { return "editing / quoting active" }
        if vm.selectedConversation?.id != target.conv.id { return "selected conversation is not S" }
        if TimerCardStore.shared.outbox.contains(where: { $0.conversationId.hasPrefix("perf-flash-conv-") }) { return "timer outbox has bench events" }
        return nil
    }

    // MARK: 报告（字段契约 = testdata/chatv1/turn-*.json）

    private static func report(_ o: TurnOcc) -> [String: Any] {
        if o.status == "ok", case .failed(let f) = o.tracker.evaluate(now: CACurrentMediaTime()) { o.fail(f.kind, "endpoints: \(f.detail)") }
        var out: [String: Any] = ["occ": 1, "target": "S", "cacheState": "cold", "ordinal": 1, "reqId": o.reqId]
        var ep: [String: Any] = [:]
        for (e, t) in o.tracker.times { ep[e.rawValue] = t }
        out["endpoints"] = ep
        if let c = o.censoredAt { out["censoredAtMs"] = ChatV1Load.ms3(c - o.t0) }
        let ms3 = ChatV1Load.ms3
        let segments = MainBlockMonitor.splitIntervals(now: CACurrentMediaTime())
        let samples = ChatV1Load.sampler.samples
        func frames(_ a: Double, _ b: Double) -> Core.FrameGaps? {
            let inWindow = samples.filter { $0.arrival >= a && $0.arrival <= b }
            let frameEnd = max(b, inWindow.last?.timestamp ?? b)   // §14-30：timestamp 领先送达 ≈2ms
            switch Core.frameGaps(inWindow, from: a, to: frameEnd, previous: samples.last(where: { $0.arrival < a })) {
            case .success(let g): return g
            case .failure(let f): o.fail(f.kind, "frameGaps: \(f.detail)"); return nil
            }
        }
        var metrics: [String: Any] = [:]
        var tailTextKit: [String: Any]?
        let render = o.renderSeries()
        let targets = (0..<o.cumChars.count).compactMap { k in
            o.renderable(o.script.slices[0...k].joined(), article: o.article)
        }
        if targets.count != o.cumChars.count { o.fail(.probeMissing, "renderable length: no probe at report time") }
        var progress: [String: Any] = [:]
        var timeline: [String: Any] = [:]
        if let pc = o.providerComplete {
            // R7 C-02：离底只取上移之后到达的片（上移前那段是在底的数，不进离底指标）；在底 = 开播起。截止都是 provider 完成，
            // 流式行上移后离开有效视口 = 之后不可观察（K-01：这类删失单列，不进分位、不判晚到）
            let from = o.offBottom ? (o.shiftT ?? pc) : o.t0
            let lost = o.offBottom ? o.streamRowLostT : nil
            let horizon = min(pc, lost ?? pc)
            metrics["progressWindowStartMs"] = ms3(from - o.t0)
            metrics["progressWindowEndMs"] = ms3(pc - o.t0)
            if let g = frames(o.t0, pc) {
                metrics["callbackGapExcess"] = (g.callbackGapExcess * 1000).rounded() / 1000
                metrics["worstGapMs"] = ms3(g.worstGapMs / 1000)
                metrics["callbacks"] = g.callbacks
            }
            let busy = Core.busy(segments, in: Core.Interval(start: o.t0, end: pc))
            metrics["busyMs"] = ms3(busy)
            metrics["busyRatio"] = pc > o.t0 ? ((busy / (pc - o.t0)) * 10_000).rounded() / 10_000 : 0
            let st = Core.Turn.chunks(arrivals: o.actual, targets: targets, render: render, from: from, until: pc, lostAt: lost)
            // C-07：删失片按删失下界进分位（与 R3 A-02 同口径）；下界压到 p95 上时标 p95IsLowerBound
            if let p50 = Core.Turn.percentile(st.values, 0.5), let p95 = Core.Turn.percentile(st.values, 0.95) {
                metrics["supplyToRenderP50Ms"] = ms3(p50)
                metrics["supplyToRenderP95Ms"] = ms3(p95)
                metrics["supplyToRenderMaxMs"] = ms3(st.values.max() ?? 0)
            }
            metrics["supplyToRenderN"] = st.values.count
            metrics["supplyToRenderCensored"] = st.censored
            metrics["supplyToRenderCensoredUnobservable"] = st.censoredUnobservable
            if let fp = o.tracker.times[.firstProgress] {
                let supply = zip(o.actual, targets).map { (t: $0, chars: $1) }
                metrics["maxRenderStallMs"] = ms3(Core.Turn.maxStall(supply: supply, render: render, from: max(fp, from), to: horizon))
            }
            progress = ["from": from, "until": pc, "lostAt": lost as Any? ?? NSNull(), "chunks": st.chunks.count,
                        "censored": st.censored, "censoredUnobservable": st.censoredUnobservable,
                        "late": st.late.map(\.k), "notConverged": st.notConverged.map(\.k), "aheadOfSupply": st.aheadOfSupply,
                        "p95IsLowerBound": st.p95IsLowerBound,
                        "lateS": Core.Turn.Thresholds.chunkLateS, "convergeS": Core.Turn.Thresholds.convergeS]
            // C-01：plan §6.6「片晚到 / 未收敛 → 产品慢」——中途卡住（渲染输入停在 N 字、供给继续）不再被放行
            if let c = st.notConverged.first {
                o.fail(.streamNotConverged, "\(st.notConverged.count) chunk(s) arrived ≥ \(Core.Turn.Thresholds.convergeS)s before the window end and never reached by render input "
                       + "(first k=\(c.k) target \(c.target) chars, render \(o.renderChars(until: horizon)) at \(ms3(horizon - o.t0))ms, lower bound \(ms3(c.lowerBound ?? 0))ms)")
            }
            if let c = st.late.first {
                o.fail(.streamLate, "\(st.late.count) chunk(s) later than \(Core.Turn.Thresholds.chunkLateS)s (first k=\(c.k): \(c.latency.map { "\(ms3($0))ms" } ?? "censored ≥ \(ms3(c.lowerBound ?? 0))ms"))")
            }
            if let k = st.aheadOfSupply.first {
                o.fail(.renderAheadOfSupply, "render input ≥ target before chunk k=\(k) arrived (\(st.aheadOfSupply.count) chunks): expected-length pipeline != product")
            }
            if o.status == "productSlow", o.censoredAt == nil { out["censoredAtMs"] = ms3(horizon - o.t0) }
            // R7 C-15：[request, provider.complete) 10s 分箱时间线（同 R6 深翻）：callbackGapExcess 同配置离散大、与忙比不单调，看形状不看均值
            let bins = Core.Traverse.bins(from: o.t0, to: pc, width: 10)
            let binGaps = bins.map { b -> Core.FrameGaps? in
                samples.contains { $0.arrival >= b.start && $0.arrival <= b.end } ? frames(b.start, b.end) : nil
            }
            timeline = ["binS": 10, "startMs": bins.map { ms3($0.start - o.t0) }, "endMs": bins.map { ms3($0.end - o.t0) },
                        "callbackGapExcess": binGaps.map { $0.map { ($0.callbackGapExcess * 1000).rounded() / 1000 } as Any? ?? NSNull() },
                        "busyRatio": bins.map { ((Core.busy(segments, in: $0) / ($0.end - $0.start)) * 10_000).rounded() / 10_000 },
                        "callbacks": binGaps.map { $0?.callbacks ?? 0 },
                        "thermal": bins.map { ChatV1Load.thermalState(at: $0.end) }]
            metrics["renderCharsAtComplete"] = o.renderChars(until: pc)
            metrics["supplyCharsAtComplete"] = o.cumChars.last ?? 0
            let tailEnd = pc + tailSeconds
            metrics["tailBusyMs"] = ms3(Core.busy(segments, in: Core.Interval(start: pc, end: tailEnd)))
            tailTextKit = PerfTextKit.summary(from: pc, to: tailEnd)   // R14-06：收尾段 TextKit 三类 + 入口 + 补池，查 +124 的去向
            if let g = frames(pc, tailEnd) { metrics["tailWorstGapMs"] = ms3(g.worstGapMs / 1000) }
        }
        var ev: [String: Any] = [
            "driver": o.offBottom ? "synthetic" : "scripted", "reqId": o.reqId,
            "nodes": ["userNodeId": o.userId ?? "", "assistantNodeId": o.assistantId ?? ""],
            "script": ["id": o.script.id, "slices": o.script.slices.count, "chars": o.script.final.count,
                       "finalDigest": ChatV1Load.hex(Core.fnv1a64(o.script.final)), "durationMs": ms3(o.script.duration),
                       "lint": Core.StreamScript.lint(o.script.final)],
            "supply": ["anchor": o.anchor ?? o.t0, "plannedT": o.planned, "actualT": o.actual, "cumChars": o.cumChars,
                       "renderTarget": targets],
            "renderInput": ["mode": o.article ? "article" : "bubble", "t": render.map(\.t), "chars": render.map(\.chars)],
            "routerStreaming": ["atFirstSlice": o.routerStreamingAtFirst ?? false, "updatePagesDuringStream": o.counts["updatePages"] ?? 0],
            "pins": PerfChatV1.pins - o.pins0, "glides": PerfChatV1.glides - o.glides0,
        ]
        // L1c / R12-04：流完翻回静态分支时这条助手消息的空占位段（>门槛字数才会有；测量钩子 MP_PERF_TEST_SYNC_LIMIT 压低门槛复现）
        let finishBlanks = PerfRenderLedger.blanks.filter { $0.nodeId == o.assistantId && $0.begin >= o.t0 }
        ev["blank"] = finishBlanks.map { b -> [String: Any] in
            ["nodeId": b.nodeId, "begin": b.begin, "end": b.end as Any? ?? NSNull(), "durMs": b.end.map { ms3($0 - b.begin) } as Any? ?? NSNull()]
        }
        metrics["finishBlankSegments"] = finishBlanks.count
        if let tailTextKit { ev["textkit"] = ["tail": tailTextKit] }
        if !progress.isEmpty { ev["progress"] = progress }   // provider 没完成（超时）就没有片窗口，缺项由分析器按 productSlow 放过
        if !timeline.isEmpty { ev["timeline"] = timeline }
        let slices = max(1, o.cumChars.count)
        ev["counts"] = ["slices": o.cumChars.count, "raw": o.counts,
                        "perSlice": o.counts.mapValues { (Double($0) / Double(slices) * 1000).rounded() / 1000 }] as [String: Any]
        if let uj = PerfRenderLedger.jumps.last(where: { $0.target == o.userId }) {
            ev["userJump"] = ["target": uj.target, "outcome": uj.outcome, "t": uj.t]
        }
        let fj = o.finishJump
        ev["finishJump"] = ["target": fj?.target as Any? ?? NSNull(), "outcome": fj?.outcome as Any? ?? NSNull(),
                            "t": fj?.t as Any? ?? NSNull(), "targetInViewport": o.finishInViewport,
                            "visibleFraction": o.finishVisibleFraction.map { ($0 * 1000).rounded() / 1000 } as Any? ?? NSNull()]
        if let c = o.finalConsumed, let d = c.digest {
            ev["final"] = ["nodeId": o.assistantId ?? "", "digest": ChatV1Load.hex(d), "mode": c.mode, "t": c.t,
                           "consumesAfterComplete": o.consumedAfterComplete]
        }
        typealias Th = Core.Turn.Thresholds
        let r3 = { (x: Double) in (x * 1000).rounded() / 1000 }
        if o.offBottom {
            let maxDrift = max(o.drift.max() ?? 0, o.anchorLostLowerBound ?? 0)
            if o.anchorLostT != nil { metrics["maxAnchorDriftCensored"] = true }
            metrics["maxAnchorDriftPt"] = r3(maxDrift)
            if let id = o.anchorId, let ct = o.chosenT, let st = o.shiftT {
                ev["anchor"] = ["nodeId": id, "shiftT": st, "shiftPt": r3(o.shiftPt), "renderCharsAtShift": o.renderAtShift, "chosenT": ct,
                                "glideStartedBeforeShift": o.glideStartedBeforeShift,
                                "lostT": o.anchorLostT as Any? ?? NSNull(),
                                "lostLowerBoundPt": o.anchorLostLowerBound.map(r3) as Any? ?? NSNull(),
                                "initialMinY": Double(o.anchorMinY0), "maxAnchorDriftPt": r3(maxDrift),
                                "endDriftPt": o.drift.last ?? 0,
                                "samples": ["t": o.driftT, "driftPt": o.drift.map(r3)],
                                "held": ["t": o.heldT, "fromBottomPt": o.heldFromBottom.map(r3)]] as [String: Any]
                // R7 C-03：上移后流式行仍在视口里、真的在长（生长量 = 上移后末样本行高 − 上移时）、钉位补偿真被行使
                let heights = o.rowHeight.compactMap { $0 }
                let growth = (heights.last ?? o.rowHeightAtShift) - o.rowHeightAtShift
                let pc = o.providerComplete ?? CACurrentMediaTime()
                ev["streamRow"] = ["plannedShiftPt": r3(o.plannedShiftPt), "keepPt": r3(o.keepPt), "minYBeforeShift": r3(o.rowMinYBeforeShift),
                                   "topAfterShift": o.rowTopAfterShift.map(r3) as Any? ?? NSNull(),
                                   "heightAtShiftPt": r3(o.rowHeightAtShift), "heightEndPt": r3(heights.last ?? o.rowHeightAtShift),
                                   "growthPt": r3(growth), "renderCharsAtShift": o.renderAtShift, "renderCharsAtComplete": o.renderChars(until: pc),
                                   "visibleSamples": o.rowVisible.filter { $0 }.count, "samples": o.rowVisible.count,
                                   "lostT": o.streamRowLostT as Any? ?? NSNull(), "pinsAfterShift": o.pinsAtComplete - o.pinsAtShift,
                                   "screenHeightPt": r3(o.screenHeight),
                                   "fromBottomAfterShiftPt": o.fromBottomAfterShift.map(r3) as Any? ?? NSNull(),
                                   "heightSamples": ["t": o.rowT, "heightPt": o.rowHeight.map { $0.map(r3) as Any? ?? NSNull() }],
                                   "growthEvents": growthEvents(from: st, until: pc)] as [String: Any]
                if let fb = o.fromBottomAfterShift, fb <= o.screenHeight / 2 {
                    o.fail(.configMismatch, "offBottomWithinHalfScreen: fromBottom \(r3(fb))pt after shift ≤ half screen \(r3(o.screenHeight / 2))pt: "
                           + "a real release here would glide back to the bottom (CardFlowView pollScrollSettled)")
                }
                if growth <= 0 {
                    o.fail(.configMismatch, "off-bottom stream row did not grow after shift (height \(r3(o.rowHeightAtShift)) → \(r3(heights.last ?? 0))pt, "
                           + "visible \(o.rowVisible.filter { $0 }.count)/\(o.rowVisible.count)): the anchor is not under growth pressure")
                }
                // C-03 诊断分段（R7-03 改法）：在底 [request, shiftT)、过渡 [shiftT, chosenT + 0.5s)、稳态 [chosenT + 0.5s, provider.complete)
                func seg(_ a: Double, _ b: Double) -> [String: Any] {
                    guard b > a else { return ["spanMs": 0, "callbackGapExcess": NSNull(), "worstGapMs": NSNull(), "busyRatio": NSNull()] }
                    let g = frames(a, b)
                    return ["spanMs": ms3(b - a), "callbackGapExcess": g.map { ($0.callbackGapExcess * 1000).rounded() / 1000 } as Any? ?? NSNull(),
                            "worstGapMs": g.map { ms3($0.worstGapMs / 1000) } as Any? ?? NSNull(),
                            "busyRatio": ((Core.busy(segments, in: Core.Interval(start: a, end: b)) / (b - a)) * 10_000).rounded() / 10_000]
                }
                let steady = min(pc, ct + 0.5)
                ev["segments"] = ["atBottom": seg(o.t0, st), "transition": seg(st, steady), "steady": seg(steady, pc)]
            }
            // C-04：离底锚点漂移超阈值（含跳出实化范围的下界）= 钉位没守住
            if o.anchorId != nil, maxDrift > Th.anchorDriftMaxPt {
                o.fail(.anchorDrift, "off-bottom anchor drifted \(r3(maxDrift))pt > \(Th.anchorDriftMaxPt)pt\(o.anchorLostT != nil ? " (left the realized range, lower bound)" : "")")
            }
        } else {
            let fb = o.fromBottom.map(r3)
            metrics["maxFromBottomPt"] = fb.max() ?? 0
            if !fb.isEmpty {
                ev["follow"] = ["maxFromBottomPt": fb.max() ?? 0, "endFromBottomPt": fb.last ?? 0,
                                "samples": ["t": o.followT, "fromBottomPt": fb]] as [String: Any]
            }
            // C-05：provider.complete 前最后一次采样仍离底超阈值 = 在底跟随断了（产品 cellGrew「在底」= fromBottom ≤ 12）
            if let end = fb.last, end > Th.followEndMaxPt {
                o.fail(.followLost, "at-bottom follow ended \(end)pt from bottom (> \(Th.followEndMaxPt)pt) at provider.complete")
            }
        }
        out["metrics"] = metrics
        out["evidence"] = ev
        out["status"] = o.status
        return out
    }
}
#endif

#if (DEBUG || PERF_BENCH) && os(iOS)
/// §14-102 离底诊断：[from, until) 内的 cell 生长事件（CardFlowView 钉位链每一次的去向）
@MainActor private func growthEvents(from: Double, until: Double) -> [String: Any] {
    let ev = PerfChatV1.growthEvents.filter { $0.t >= from && $0.t < until }
    return ["t": ev.map(\.t), "deltaPt": ev.map { ($0.delta * 1000).rounded() / 1000 }, "branch": ev.map(\.branch),
            "fromBottomPt": ev.map { $0.fromBottom.map { ($0 * 1000).rounded() / 1000 } as Any? ?? NSNull() },
            "cell": ev.map { $0.streaming ? "stream" : "other" }]
}
#endif
