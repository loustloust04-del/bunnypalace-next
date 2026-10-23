// L2-T2（plan-stream-render-l2-t2 / D10=b 补课）：article mode simple 流式正文接 fork 增量渲染。
// BubbleView article 分支流式时渲此组件，替换「pacer.shown → 全文 ChatMarkdownView 30Hz 重进」：
// - thinking 实时：仍读 vm.streamingText 解析（D10=b 蓝图「thinking 段不动」）——本 wrapper
//   每 token 重算，但范围只有 thinking 条 + StreamingTextView 外壳，不含 markdown parse/diff
// - 正文：StreamingMarkdownSource 整体 yield，加工链搬进 snapshot 闭包（clean 有 NSCache
//   同 key 命中，与 body 侧共享），库内增量渲染；流式节奏=pacer 匀速放字（L5，粟粟 09-10 批）
// 两端可用：mac 自 ms0911 L4 起同走流式（D6=c 流式部分推翻，plan §9 第 5 条）。
import SwiftUI

struct ArticleStreamingBody: View {
    let node: MessageNode
    let viewModel: ConversationViewModel
    let conversationId: String
    let regexScripts: [RegexScript]

    @AppStorage("ccShowThinking") private var showCCThinking = true
    @StateObject private var source: StreamingMarkdownSource

    init(
        node: MessageNode,
        viewModel: ConversationViewModel,
        conversationId: String,
        regexScripts: [RegexScript]
    ) {
        self.node = node
        self.viewModel = viewModel
        self.conversationId = conversationId
        self.regexScripts = regexScripts

        let capturedVM = viewModel
        let capturedNodeId = node.id
        let capturedScripts = regexScripts
        _source = StateObject(wrappedValue: StreamingMarkdownSource(
            vm: capturedVM,
            conversationId: conversationId,
            nodeId: capturedNodeId,
            paced: true,   // L5：正文快照进 pacer 匀速放字（plan-stream-fade-l5）
            renderSnapshot: { [weak capturedVM] in
                Self.renderableBody(from: capturedVM?.streamingText ?? "",
                                    nodeId: capturedNodeId, scripts: capturedScripts)
            }
        ))
    }

    /// 加工链（原 articleModeBody 流式分支同款）：clean → 剥 thinking → 正则脚本。
    private static func renderableBody(from raw: String, nodeId: String, scripts: [RegexScript]) -> String {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.testBlankStream { return "" }   // 测试钩子（perf P0 §6.6 反作弊）：流式期间不显示字 → 连续进度断言必须判红
        if let cap = PerfHarness.testStallStream, raw.count > cap {   // 测试钩子（R7 C-01 反例）：渲染停在前 N 字 → 未收敛 / 晚到必须判出
            return renderableBody(from: String(raw.prefix(cap)), nodeId: nodeId, scripts: scripts)
        }
        #endif
        let cleaned = ContentCleaner.clean(raw, cacheKey: "\(nodeId)_\(raw.count)")
        let content = ContentCleaner.extractThinking(from: cleaned).content
        guard !scripts.isEmpty else { return content }
        return RegexEngine.apply(scripts: scripts, text: content, messagePlacement: 2, isMarkdown: true)
    }

    var body: some View {
        let raw = viewModel.streamingText
        let cleaned = ContentCleaner.clean(raw, cacheKey: "\(node.id)_\(raw.count)")
        let extracted = ContentCleaner.extractThinking(from: cleaned)
        VStack(alignment: .leading, spacing: 8) {
            if let thinking = extracted.thinking ?? (showCCThinking ? node.ccThinking : nil), !thinking.isEmpty {
                ThinkingDisclosure(text: thinking, nodeId: node.id, profileId: node.profileId)
            }
            if extracted.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TypingDotsView()
            } else {
                StreamingTextView(source: source)
            }
        }
        #if os(iOS)
        .onDisappear { source.finish() }
        #else
        // R9c-A N3：mac 离屏 ≠ 结束——还在流式就不 finish（source 继续观察，回屏接着长）；
        // 离屏期间 turn 结束由 onChange 收尾；视图真销毁有 source deinit 兜底关 continuation。
        .onDisappear {
            if !viewModel.isNodeStreaming(nodeId: node.id, conversationId: conversationId) {
                source.finish()
            }
        }
        .onChange(of: viewModel.isNodeStreaming(nodeId: node.id, conversationId: conversationId)) { _, streaming in
            if !streaming { source.finish() }
        }
        #endif
    }
}
