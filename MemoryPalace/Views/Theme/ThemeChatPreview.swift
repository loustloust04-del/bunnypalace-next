import SwiftUI

/// 主题的迷你聊天预览：真实主背景 + 背景图 + 用户气泡（`userText`）+ AI 气泡（`assistantText`）+ 链接色。
/// 一个组件三种尺寸（plan-theme-decouple M3.2，kimi 可选 2）：外观页「主题」行、主题列表行、颜色页 / 背景页顶部。
/// 三处画的是同一样东西，观感不会漂。
struct ThemeChatPreview: View {
    enum Size {
        /// 外观页入口行右侧 64×38
        case row
        /// 主题列表行 112×58
        case list
        /// 颜色页 / 背景页顶部，满宽 110
        case pinned
    }

    let tokenSet: ThemeTokenSet
    let scheme: ColorScheme
    var backgroundImageURL: URL? = nil
    var backgroundStyle: ThemeBackgroundStyle = ThemeBackgroundStyle()
    var size: Size = .list

    private struct Metrics {
        let width: CGFloat?
        let height: CGFloat
        let font: CGFloat
        let bubblePadH: CGFloat
        let bubblePadV: CGFloat
        let bubbleRadius: CGFloat
        let inset: CGFloat
        let spacing: CGFloat
        let corner: CGFloat
        let showsTime: Bool
    }

    private var metrics: Metrics {
        switch size {
        case .row:
            Metrics(width: 64, height: 38, font: 5.5, bubblePadH: 4, bubblePadV: 2, bubbleRadius: 5, inset: 4, spacing: 2, corner: 7, showsTime: false)
        case .list:
            Metrics(width: 112, height: 58, font: 7.5, bubblePadH: 5, bubblePadV: 3, bubbleRadius: 7, inset: 6, spacing: 3, corner: 10, showsTime: true)
        case .pinned:
            Metrics(width: nil, height: 110, font: 11, bubblePadH: 9, bubblePadV: 6, bubbleRadius: 11, inset: 12, spacing: 6, corner: 14, showsTime: true)
        }
    }

    private var userText: Color { (tokenSet.userText ?? tokenSet.textPrimary).color }
    private var assistantText: Color { (tokenSet.assistantText ?? tokenSet.textPrimary).color }
    /// 小尺寸一行放不下长句，短一点免得省略号吃掉「链接」
    private var assistantLine: String {
        switch (size, scheme) {
        case (.pinned, .dark): "深色也接上了，"
        case (.pinned, _): "浅色这边也会即时更新，"
        case (_, .dark): "深色也接上了，"
        case (_, _): "浅色也接上了，"
        }
    }

    var body: some View {
        let m = metrics
        VStack(alignment: .leading, spacing: m.spacing) {
            if m.showsTime {
                Text("14:02")
                    .font(.system(size: max(m.font - 1.5, 5)))
                    .foregroundColor(tokenSet.textMuted.color)
                    .frame(maxWidth: .infinity)
            }
            bubble(Text("这套背景舒服。").foregroundColor(userText), fill: tokenSet.userBubble.color, gradient: tokenSet.userBubbleGradient?.color, m: m)
                .frame(maxWidth: .infinity, alignment: .trailing)
            bubble(
                Text(assistantLine).foregroundColor(assistantText)
                    + Text("链接").foregroundColor(tokenSet.branchIndicator.color)
                    + Text(size == .pinned ? "在这。" : "。").foregroundColor(assistantText),
                fill: tokenSet.assistantBubble.color,
                m: m
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(m.inset)
        .frame(width: m.width, height: m.height, alignment: .top)
        .frame(maxWidth: m.width == nil ? .infinity : nil)
        .coordinateSpace(name: Self.previewSpace)   // 气泡渐变锚在预览区（不滚也能看出上下两色）
        .background(
            ThemeBackgroundView(
                fill: tokenSet.mainBg.color,
                imageURL: backgroundImageURL,
                scheme: scheme,
                backgroundStyle: backgroundStyle
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: m.corner))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let previewSpace = "themeChatPreview"

    private func bubble(_ text: Text, fill: Color, gradient: Color? = nil, m: Metrics) -> some View {
        text
            .font(.system(size: m.font))
            .lineLimit(1)
            .padding(.horizontal, m.bubblePadH)
            .padding(.vertical, m.bubblePadV)
            .background(
                UserBubbleFill(
                    shape: RoundedRectangle(cornerRadius: m.bubbleRadius),
                    base: fill,
                    gradient: gradient,
                    anchor: .named(Self.previewSpace)
                )
            )
    }
}
