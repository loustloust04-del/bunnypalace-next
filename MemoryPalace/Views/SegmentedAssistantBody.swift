// 流式重写 Phase 4 / Contract 4 D9=a 落地。
// segmented assistant 消息 = MessageSegmentsView + 末尾 StreamingTextView（流式 turn 时）。
// 持 @StateObject source；BubbleView wrapper 调用，articleModeBody 的 segmented 分支用。
// 两端可用：mac 自 ms0911 L4 起 segmented assistant 也走这里（D6=c 流式部分推翻）。
import SwiftUI

struct SegmentedAssistantBody: View {
    let node: MessageNode
    let viewModel: ConversationViewModel
    let conversationId: String
    let segments: [MessageSegment]
    let selectedFont: String
    let fontScale: Double
    let lineSpacingScale: Double
    let paragraphSpacingScale: Double
    let regexScripts: [RegexScript]
    /// 浮条「引用」通道（CC/导入对话的 segmented 正文也要能选段引用——粟粟报"有的 session 不能引用"）
    var onQuoteText: ((String) -> Void)? = nil

    @StateObject private var source: StreamingMarkdownSource

    init(
        node: MessageNode,
        viewModel: ConversationViewModel,
        conversationId: String,
        segments: [MessageSegment],
        selectedFont: String,
        fontScale: Double,
        lineSpacingScale: Double,
        paragraphSpacingScale: Double,
        regexScripts: [RegexScript],
        onQuoteText: ((String) -> Void)? = nil
    ) {
        self.node = node
        self.viewModel = viewModel
        self.conversationId = conversationId
        self.segments = segments
        self.selectedFont = selectedFont
        self.fontScale = fontScale
        self.lineSpacingScale = lineSpacingScale
        self.paragraphSpacingScale = paragraphSpacingScale
        self.regexScripts = regexScripts
        self.onQuoteText = onQuoteText

        let capturedVM = viewModel
        let capturedNodeId = node.id
        let capturedConvId = conversationId
        let capturedScripts = regexScripts   // R9c-A N5：值类型数组，捕获不涉及循环引用
        _source = StateObject(wrappedValue: StreamingMarkdownSource(
            vm: capturedVM,
            conversationId: capturedConvId,
            nodeId: capturedNodeId,
            renderSnapshot: { [weak capturedVM] in
                // N5：尾巴快照与定稿 .text 段同一个显示加工（正则），完成落段后不再内容跳变
                SegmentDisplayText.apply(scripts: capturedScripts, to: capturedVM?.streamingText ?? "")
            }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MessageSegmentsView(
                segments: segments,
                selectedFont: selectedFont,
                fontScale: fontScale,
                lineSpacingScale: lineSpacingScale,
                paragraphSpacingScale: paragraphSpacingScale,
                regexScripts: regexScripts,
                profileId: node.profileId,
                nodeId: node.id,
                isStreaming: viewModel.isNodeStreaming(nodeId: node.id, conversationId: conversationId),
                onQuoteText: onQuoteText,
                toolNode: node,
                suppressTrailingError: true
            )
            // D9=a tail：流式 turn 中（含 tool 间隙）+ 是当前 turn 节点 → 末尾追加 fork 渲染
            if viewModel.isNodeStreaming(nodeId: node.id, conversationId: conversationId) {
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
