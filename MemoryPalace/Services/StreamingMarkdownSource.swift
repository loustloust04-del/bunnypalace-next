// 流式重写 Phase 4 / Contract 1+2+3+6 v3：把 ConversationViewModel.streamingText
// 桥成 SwiftStreamingMarkdown 库要求的 AsyncStream<String>。
// 详见 docs/design-streaming-lifecycle.md v3。
//
// 关键设计：
// - @MainActor + ObservableObject（@StateObject 强制 + closure 主 actor 安全）
// - 三元 (conversationId, nodeId, assistantTurnInFlight) check 防串扰/cancel 后空 yield/楼层残留
// - withObservationTracking 单次 trigger 在 onChange 内重新注册（latest-only delivery）
// - init 内立即 yield 一次 snapshot（fork .task remount 时不空白）
// - finish() 显式关 continuation（fork controller.end() 只 cancel parser task 不 finish source）
//
// L5（plan-stream-fade-l5）paced 模式：transform 在 pacer 上游——
//   vm.streamingText —(observe)→ renderSnapshot()=正文快照 → pacer.push —30Hz→ yield pacer.shown
// pacer 只见加工后的正文（T2b 放 raw 的 thinking 人质/非前缀重放问题结构性消失）；
// yield 直接放 shown 不二次 transform。init 用 pacer.seed 铺满当前快照——remount 不整篇重打。
import Foundation
import SwiftUI
import Observation
import SwiftStreamingMarkdown
@MainActor
final class StreamingMarkdownSource: ObservableObject, StreamedMarkdownSource {
    let text: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let pacer: StreamPacer?
    private weak var vm: ConversationViewModel?
    private let conversationId: String
    private let nodeId: String
    private let renderSnapshot: @MainActor () -> String
    private var finished = false
    #if DEBUG
    private var pushCount = 0
    private var yieldCount = 0
    #endif

    init(
        vm: ConversationViewModel,
        conversationId: String,
        nodeId: String,
        paced: Bool = false,
        renderSnapshot: @escaping @MainActor () -> String
    ) {
        var cont: AsyncStream<String>.Continuation!
        self.text = AsyncStream { cont = $0 }
        self.continuation = cont
        self.pacer = paced ? StreamPacer() : nil
        self.vm = vm
        self.conversationId = conversationId
        self.nodeId = nodeId
        self.renderSnapshot = renderSnapshot

        // 初始 replay：fork .task 启动时立即拿到当前 snapshot（防空白）
        // Task 包一下避免 init 内同步 yield 时机不对
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            if let pacer = self.pacer {
                let snapshot = renderSnapshot()
                pacer.seed(snapshot)
                #if DEBUG
                print("[PACED2] seed len=\(snapshot.count)")
                #endif
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure { PerfRenderLedger.noteStreamInput(nodeId: self.nodeId, chars: pacer.shown.count, mode: "article") }   // perf P0 §5.2 streamInput
                #endif
                self.continuation.yield(pacer.shown)
                self.observeRawPaced()
                self.observeShown()
            } else {
                self.continuation.yield(renderSnapshot())
                self.observe()
            }
        }
    }

    /// 显式 finish—— BubbleView.onDisappear 调。fork controller.end() 不会 finish source。
    /// paced：一并停 pacer 节拍（timer 闭包自灭是兜底，正路仍是这里）。
    func finish() {
        guard !finished else { return }
        finished = true
        pacer?.end()
        continuation.finish()
    }

    /// withObservationTracking 单次 trigger。yield 后必须重新注册。
    /// guard 三元失败时不 yield 但要 re-register（下次 vm.streamingText 变化时再 check）。
    private func observe() {
        guard !finished else { return }
        withObservationTracking {
            _ = self.vm?.streamingText  // 注册依赖
        } onChange: { [weak self] in
            // onChange 在触发线程同步调；hop main 做 SwiftData/VM 状态读取
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                if let vm = self.vm,
                   vm.isNodeStreaming(nodeId: self.nodeId, conversationId: self.conversationId) {
                    self.continuation.yield(self.renderSnapshot())
                }
                // 不 yield 时也要 re-register，下次 streamingText 变化时还能 check
                self.observe()
            }
        }
    }

    /// paced 上游：vm.streamingText 变化 → 加工成正文快照喂 pacer（三元 check 同 observe）。
    private func observeRawPaced() {
        guard !finished else { return }
        withObservationTracking {
            _ = self.vm?.streamingText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                if let vm = self.vm, let pacer = self.pacer,
                   vm.isNodeStreaming(nodeId: self.nodeId, conversationId: self.conversationId) {
                    let snapshot = self.renderSnapshot()
                    pacer.push(snapshot)
                    #if DEBUG
                    self.pushCount += 1
                    if self.pushCount <= 3 || self.pushCount % 20 == 0 {
                        print("[PACED2] push #\(self.pushCount) len=\(snapshot.count) shown=\(pacer.shown.count)")
                    }
                    #endif
                }
                self.observeRawPaced()
            }
        }
    }

    /// paced 下游：pacer.shown 30Hz 放字 → 直接 yield（无二次 transform）。
    private func observeShown() {
        guard !finished, let pacer else { return }
        withObservationTracking {
            _ = pacer.shown
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.finished, let pacer = self.pacer else { return }
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure { PerfRenderLedger.noteStreamInput(nodeId: self.nodeId, chars: pacer.shown.count, mode: "article") }   // perf P0 §5.2 streamInput
                #endif
                self.continuation.yield(pacer.shown)
                #if DEBUG
                self.yieldCount += 1
                if self.yieldCount <= 3 || self.yieldCount % 30 == 0 {
                    print("[PACED2] yield #\(self.yieldCount) len=\(pacer.shown.count)")
                }
                #endif
                self.observeShown()
            }
        }
    }

    deinit {
        // deinit 在任意线程；不能调 main-actor finish()。直接 finish continuation。
        // pacer timer 由闭包内 weak-self 自灭兜底（StreamPacer.push）。
        if !finished {
            continuation.finish()
        }
    }
}
