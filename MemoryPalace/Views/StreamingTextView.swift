// 流式重写 Phase 4 / Contract 4 v3 D9=a：流式文本显示组件。
// Source ownership 在 BubbleView wrapper（@StateObject），本 view 只 @ObservedObject 引用。
// 用在两处（ms0911 L4 起两端可用）：
// - ArticleStreamingBody（文章模式 simple 流式正文）
// - SegmentedAssistantBody 末尾 tail（segmented post-tool）
//（气泡模式流式走块拆分 + StreamPacer，不经本组件）
import SwiftUI
import SwiftStreamingMarkdown

struct StreamingTextView<Source: ObservableObject & StreamedMarkdownSource>: View {
    @ObservedObject var source: Source
    @AppStorage("selectedFont") private var selectedFont: String = ""
    @AppStorage("fontScale") private var fontScale: Double = 1.2

    #if os(macOS)
    // L4：mac 流式 config 补「外观 › 排版」两滑杆（读法同 ChatMarkdownView mac renderConfig），
    // 否则定稿切回 ChatMarkdownView 时行距/段距跳变。声明包门防 dead 订阅；
    // 气泡模式行内由 BubbleModeRow 注入的 chatSpacingOverride 优先。
    @AppStorage("lineSpacingScale") private var lineSpacingScale: Double = 1.45
    @AppStorage("paragraphSpacingScale") private var paragraphSpacingScale: Double = 1.65
    @Environment(\.chatSpacingOverride) private var spacingOverride
    #endif

    var body: some View {
        #if os(iOS)
        StreamedMarkdownView(
            source: source,
            config: .memoryPalace(
                fontName: selectedFont,
                scale: CGFloat(fontScale),
                animated: true,
                textColor: ChatTextRole.assistant.color   // 流式尾巴永远是 AI 正文
            )
        )
        .chatCardRenderer(nodeId: nil, streaming: true)
        #else
        // iOS 分支逐字的 mac 版 + 两个 mac 专有排版参数（实参位 #if Swift 5.10 不支持，整段双份）
        StreamedMarkdownView(
            source: source,
            config: .memoryPalace(
                fontName: selectedFont,
                scale: CGFloat(fontScale),
                animated: true,
                lineSpacingScale: spacingOverride?.lineSpacing ?? lineSpacingScale,
                paragraphSpacingScale: spacingOverride?.paragraphSpacing ?? paragraphSpacingScale,
                textColor: ChatTextRole.assistant.color   // 流式尾巴永远是 AI 正文
            )
        )
        .chatCardRenderer(nodeId: nil, streaming: true)
        #endif
    }
}
