#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation
import QuartzCore
import Observation

/// 纵切 6 · 脚本流（plan-chat-list-perf-p0 §6.6）：严格测量角色下 `ProviderRouter.sendStreaming` 把凭据 `perf-scripted`
/// 交给它（在 provider 查找与 Router 陷阱之前）。主线程 display link 按墙钟锚定到达表投递切片（`ArrivalSchedule`：慢 tick 成簇、
/// 终片时刻不被拉长），末片之后同一 tick：`isStreaming = false` → `onComplete(终稿, nil)`（与真 provider 同序，不延迟）。
/// 不回调 onToolCalls、不记用量账本、不碰网络。`isStreaming` 可观察，进 Router.isStreaming 的 OR 链，
/// 让 ContentView 流式跳过 updatePages 与真 provider 一致。对象只在严格角色下由 Router 创建
@Observable
final class PerfScriptedStream {
    private(set) var isStreaming = false

    @ObservationIgnored private var ticker: Ticker?
    @ObservationIgnored private var schedule: PerfChatCore.ArrivalSchedule?
    @ObservationIgnored private(set) var script: PerfChatCore.StreamScript.Script?
    @ObservationIgnored private var onToken: ((String) -> Void)?
    @ObservationIgnored private var onComplete: ((String, TokenUsage?) -> Void)?
    @ObservationIgnored private var cum = 0

    func play(modelId: String, onToken: @escaping (String) -> Void, onComplete: @escaping (String, TokenUsage?) -> Void,
              onError: @escaping (String) -> Void) {
        guard let s = PerfChatCore.StreamScript.script(modelId) else {
            onError("[PERF] 未知脚本 \(modelId)")
            return
        }
        guard !isStreaming else {
            onError("[PERF] 脚本流已在播")
            return
        }
        script = s
        self.onToken = onToken
        self.onComplete = onComplete
        cum = 0
        let anchor = CACurrentMediaTime()
        schedule = PerfChatCore.ArrivalSchedule(offsets: s.offsets, anchor: anchor)
        isStreaming = true
        PerfChatV1Turn.notePlay(script: s, anchor: anchor)
        let t = Ticker(self)
        ticker = t
        t.start()
    }

    fileprivate func tick() {
        guard var sched = schedule, let s = script else { return }
        let now = CACurrentMediaTime()
        let due = sched.due(at: now)
        schedule = sched
        for k in due {
            let slice = s.slices[k]
            cum += slice.count
            onToken?(slice)
            PerfChatV1Turn.noteSlice(k, planned: sched.anchor + s.offsets[k], actual: now, cumChars: cum)
        }
        guard sched.isFinished else { return }
        ticker?.stop()
        ticker = nil
        schedule = nil
        let complete = onComplete
        onToken = nil
        onComplete = nil
        isStreaming = false
        PerfChatV1Turn.noteProviderComplete(at: CACurrentMediaTime())
        complete?(s.final, nil)
    }

    /// R7-14：Router.cancel（停止生成 / 切楼层等）——停 ticker、置 isStreaming = false、不再回调 onToken / onComplete（同真 provider 取消）
    func stop() {
        ticker?.stop()
        ticker = nil
        schedule = nil
        onToken = nil
        onComplete = nil
        isStreaming = false
    }

    /// CADisplayLink 强持有 target：中间人弱引用脚本流，播完 invalidate
    private final class Ticker: NSObject {
        weak var owner: PerfScriptedStream?
        private var link: CADisplayLink?

        init(_ owner: PerfScriptedStream) { self.owner = owner }

        func start() {
            let l = CADisplayLink(target: self, selector: #selector(fire))
            l.add(to: .main, forMode: .common)
            link = l
        }

        func stop() { link?.invalidate(); link = nil }

        @objc private func fire() {
            guard let owner else { stop(); return }
            owner.tick()
        }
    }
}
#endif
