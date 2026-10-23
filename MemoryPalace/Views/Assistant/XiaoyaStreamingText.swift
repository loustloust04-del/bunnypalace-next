import SwiftUI
import SwiftStreamingMarkdown

// MARK: - 小芽流式中的正文（粟粟 09-27：学正文）
// 跟主聊天流式尾巴同一个 StreamingTextView：边出字边渲染 md、同字体字号字色；说完切 ChatMarkdownView 不跳。
// 每次这一行出现建一个 source（工具轮之间 streamingText 清空、行消失，下一轮重建）。

struct XiaoyaStreamingText: View {
    @StateObject private var source: XiaoyaStreamSource

    init(engine: AssistantEngine) {
        _source = StateObject(wrappedValue: XiaoyaStreamSource(engine: engine))
    }

    var body: some View {
        StreamingTextView(source: source)
            .onDisappear { source.finish() }
    }
}

/// engine.streamingText → 全文快照流（StreamedMarkdownSource 要的是「到目前为止的全文」，不是增量）
@MainActor
final class XiaoyaStreamSource: ObservableObject, StreamedMarkdownSource {
    let text: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private weak var engine: AssistantEngine?
    private var finished = false

    init(engine: AssistantEngine) {
        (text, continuation) = AsyncStream<String>.makeStream()
        self.engine = engine
        continuation.yield(engine.streamingText)
        observe()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        continuation.finish()
    }

    private func observe() {
        guard !finished else { return }
        withObservationTracking {
            _ = engine?.streamingText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.finished, let engine = self.engine else { return }
                if !engine.streamingText.isEmpty { self.continuation.yield(engine.streamingText) }
                self.observe()
            }
        }
    }
}
