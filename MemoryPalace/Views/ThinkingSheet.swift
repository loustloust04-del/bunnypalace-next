import SwiftUI

/// 思考过程的统一展示入口（文章模式 DisclosureGroup / 气泡模式 ThinkingBubble /
/// segmented ThinkingBlockView 三处共用）：
/// 「思考过程弹出显示」开关关 = 原地折叠展开（原行为）；开 = 弹官端式 sheet。
struct ThinkingDisclosure: View {
    var label: String = "思考过程"
    let text: String
    /// 划线/收生词锚（sheet 正文用聊天同款渲染器）；nil = sheet 正文纯文本
    var nodeId: String? = nil
    var profileId: String = ""
    /// 小模型一句话总结（plan-thinking-branch）；nil = 还没有，先用思考原文第一句顶着
    var summary: String? = nil
    /// 行出现时要不要补总结（只有文章模式静态体传；流式中 / 工具分段不传）
    var onNeedSummary: (() -> Void)? = nil
    @AppStorage("fontScale") private var fontScale = 1.2
    /// 跟正文走（正文 13.5 × 字号缩放，MarkdownConfig），略小一点
    private var labelSize: CGFloat { 13.5 * (fontScale > 0 ? fontScale : 1.2) * 0.95 }
    @AppStorage(DisclosureKind.thinking.key) private var modeRaw = DisclosureKind.thinking.migratedDefault.rawValue
    private var mode: DisclosureMode { DisclosureMode(rawValue: modeRaw) ?? .inline }
    private var sheetMode: Bool { mode == .sheet }
    @State private var expanded = false
    @State private var showSheet = false
    /// 词卡来源跳转带来的闪词（打开时高亮 1.8s）。
    @State private var flashWord: String? = nil

    var body: some View {
        if mode != .hidden { disclosure }
    }

    private var headline: String {
        if let summary, !summary.isEmpty { return summary }
        return ThinkingSummarizer.firstSentence(text) ?? label
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                #if os(iOS)
                UISelectionFeedbackGenerator().selectionChanged()
                #endif
                if sheetMode {
                    showSheet = true
                } else {
                    expanded.toggle()   // 反转列表里展开动画 vs 同帧钉住必错一帧，不做动画（plan-stream-follow-controller §三.7）
                }
            } label: {
                // 学官端「Thought process」行（粟粟 09-27 截图）：左小图标 + 总结 + ›，整行比正文淡一档、字号接近正文、上下留足
                HStack(spacing: 10) {
                    // 显式给棕灰：tint nil 走 .foregroundColor(nil) 会重置成系统黑，不继承下面的 textMuted（粟粟 10-03「不要黑色。棕灰」）
                    AppIconView(name: "ri-history", size: labelSize * 0.9, tint: Theme.textMuted)
                    Text(headline)
                        .font(.system(size: labelSize))
                        .lineLimit(1)
                    Image(systemName: expanded && !sheetMode ? "chevron.down" : "chevron.right")
                        .font(.system(size: labelSize * 0.72, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundColor(Theme.textMuted)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label)：\(headline)")

            if expanded && !sheetMode {
                Text(text)
                    .font(.system(size: labelSize * 0.92))
                    .lineSpacing(labelSize * 0.5)
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.textPrimary.opacity(0.09)).frame(width: 2)
                    }
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if summary == nil { onNeedSummary?() } }
        .sheet(isPresented: $showSheet, onDismiss: { flashWord = nil }) {
            ThinkingSheet(text: text, nodeId: nodeId, flashWord: flashWord, profileId: profileId)
        }
        .onReceive(NotificationCenter.default.publisher(for: VocabCollector.openThinkingNotification)) { notif in
            // 词卡出处跳回：nodeId 匹配的这份 Disclosure 认领弹窗（消息已被导航滚进视口）
            guard let nid = notif.userInfo?["nodeId"] as? String, nid == nodeId else { return }
            flashWord = notif.userInfo?["highlightWord"] as? String
            showSheet = true
        }
    }
}

/// 仿官端「Thought process」页（壳见 DisclosureSheet）。
struct ThinkingSheet: View {
    let text: String
    var nodeId: String? = nil
    /// 词卡来源跳转：打开即高亮这个词 1.8s（fork 划线层动态更新支持闪烁）。
    var flashWord: String? = nil
    var profileId: String = ""
    @AppStorage("selectedFont") private var selectedFont = ""
    #if os(macOS)
    // 字号跟设置走（面 3.1 ⧫7）；行距/段距由 ChatMarkdownView 在 mac 自读（与 CardFlowView 同 key），这里不订阅
    @AppStorage("fontScale") private var fontScale = 1.2
    #endif

    var body: some View {
        // 官端原味英文标题（粟粟点名；小灰字微标签英文例外条款同源）
        DisclosureSheet(title: "Thought process") {
            #if os(iOS)
            // 聊天正文同款渲染器：划词收生词 + 划线浮条。锚 = 合成锚 thinking:<nodeId>
            //（vocab:/vocabnote: 先例——thinking 划线不与正文划线混锚，收藏页对查不到
            // node 的锚 compactMap 安全跳过）
            ChatMarkdownView(
                text: text,
                fontName: selectedFont,
                nodeId: nodeId.map { "thinking:\($0)" },
                profileId: profileId,
                flashQuote: flashWord
            )
            #else
            // ms0911：mac 也走同一渲染器（MarkdownUI 退出聊天正文）；mac 思考表字号跟设置走，
            // iOS 不传 scale 吃默认 1.2（既有现象，见 plan-mac-selection §6）
            ChatMarkdownView(
                text: text,
                fontName: selectedFont,
                scale: CGFloat(fontScale > 0 ? fontScale : 1.0),
                nodeId: nodeId.map { "thinking:\($0)" },
                profileId: profileId,
                flashQuote: flashWord
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            // R9b N2：气泡模式在 BubbleModeRow 根注入了固定排版覆盖，会顺 environment 漏进
            // 思考表 sheet——这里清回 nil，思考表照旧读全局滑杆（L3b 裁决）
            .environment(\.chatSpacingOverride, nil)
            #endif
        }
    }
}
