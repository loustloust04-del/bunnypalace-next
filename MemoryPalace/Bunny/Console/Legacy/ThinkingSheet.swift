#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
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
    @AppStorage("thinkingSheetMode") private var sheetMode = false
    @State private var expanded = false
    @State private var showSheet = false
    /// 词卡来源跳转带来的闪词（打开时高亮 1.8s）。
    @State private var flashWord: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if sheetMode {
                    showSheet = true
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded && !sheetMode ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundColor(Theme.textMuted.opacity(0.7))
                // Hit testing must not add visible space above or below the header.
                .contentShape(.interaction, Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)

            if expanded && !sheetMode {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showSheet, onDismiss: { flashWord = nil }) {
            BunnyLegacyThinkingSheet(text: text, nodeId: nodeId, flashWord: flashWord, profileId: profileId)
        }
        .onReceive(NotificationCenter.default.publisher(for: VocabCollector.openThinkingNotification)) { notif in
            // 词卡出处跳回：nodeId 匹配的这份 Disclosure 认领弹窗（消息已被导航滚进视口）
            guard let nid = notif.userInfo?["nodeId"] as? String, nid == nodeId else { return }
            flashWord = notif.userInfo?["highlightWord"] as? String
            showSheet = true
        }
    }
}

/// 仿官端「Thought process」页：把手 + 左上关闭圆钮 + 居中标题 + 正文滚动。
struct BunnyLegacyThinkingSheet: View {
    let text: String
    var nodeId: String? = nil
    /// 词卡来源跳转：打开即高亮这个词 1.8s（fork 划线层动态更新支持闪烁）。
    var flashWord: String? = nil
    var profileId: String = ""
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedFont") private var selectedFont = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 官端原味英文标题（粟粟点名；小灰字微标签英文例外条款同源）
                Text("Thought process")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                HStack {
                    #if os(iOS)
                    GlassBackButton(systemImage: "xmark") { dismiss() }
                    #else
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.accent.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    #endif
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            ScrollView {
                Group {
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
                    Text(text)
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textPrimary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .background(Theme.mainBg)
        #if os(iOS)
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }
}
#endif
