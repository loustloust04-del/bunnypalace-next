import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 聊天正文按角色取字色（plan-theme-decouple M1）。`global` 是非聊天调用方（文件库预览 /
/// 单词笔记 / 交易笔记…）的默认，永远跟 `textPrimary`——她把 AI 字调红，那些页不该跟着红。
enum ChatTextRole: String {
    case global
    case user
    case assistant

    var color: Color {
        switch self {
        case .global: Theme.textPrimary
        case .user: Theme.userText
        case .assistant: Theme.assistantText
        }
    }
}

enum Theme {
    private static var currentTokens: ThemeTokenSet {
        ThemeManager.shared.currentTokenSet
    }

    static var mainBg: Color { currentTokens.mainBg.color }
    static var sidebarBg: Color { currentTokens.sidebarBg.color }
    static var userBubble: Color { currentTokens.userBubble.color }
    /// 你的气泡渐变第二色，nil = 单色（`ThemeTokenSet.userBubbleGradient`，画法见 `UserBubbleFill`）
    static var userBubbleGradient: Color? { currentTokens.userBubbleGradient?.color }
    static var assistantBubble: Color { currentTokens.assistantBubble.color }
    static var accent: Color { currentTokens.accent.color }
    static var textPrimary: Color { currentTokens.textPrimary.color }
    static var textSecondary: Color { currentTokens.textSecondary.color }
    static var textMuted: Color { currentTokens.textMuted.color }
    /// 聊天正文字色：没单独设过就跟 `textPrimary`（M1 跟随式，见 `ThemeTokenSet.userText`）
    static var userText: Color { (currentTokens.userText ?? currentTokens.textPrimary).color }
    static var assistantText: Color { (currentTokens.assistantText ?? currentTokens.textPrimary).color }
    static var favorite: Color { currentTokens.favorite.color }
    static var danger: Color { currentTokens.danger.color }
    static var branchIndicator: Color { currentTokens.branchIndicator.color }
    static var activeScheme: ColorScheme { ThemeManager.shared.activeScheme }

    #if os(macOS)
    static var platformMainBackgroundColor: NSColor { currentTokens.mainBg.platformColor }
    static var platformSidebarBackgroundColor: NSColor { currentTokens.sidebarBg.platformColor }
    #else
    static var platformMainBackgroundColor: UIColor { currentTokens.mainBg.platformColor }
    #endif

    static let bubbleCornerRadius: CGFloat = 16
    static let bubblePadding: CGFloat = 14
    static let bubbleSpacing: CGFloat = 6
    static let bubbleMaxWidthRatio: CGFloat = 0.75
    /// 正文栏 / 输入条的内容最大宽度。`.frame(maxWidth:)` 只夹不撑——iPhone 屏宽远小于它，
    /// 加了等于没加；iPad 与 macOS 宽窗下防止一行文字拉到 1000pt。
    ///
    /// 取值史：原是 macOS 分支里的硬编码 720（未经论证，只是「mac 一直在用」）。09-04 粟粟
    /// 拖 `docs/design-ipad-landscape.html` 的宽度滑块对比后，**iOS 端**定 600：
    /// - 720 → 每行 47 汉字（舒适区 25–40，偏长）、代码 82 列
    /// - 600 → 每行 41 汉字、代码 71 列、iPad 横屏两侧各让出 297pt 给悬浮面板
    /// 即用「代码块偶尔折行」换「中文更好读 + 横屏浮层更宽」。
    ///
    /// **macOS 留在 720**（粟粟 09-04：「我是说 iOS 版！这 0 个好处只有坏处」）——mac 窗口
    /// 能拉到 1500+，600 在那个尺度下只是把内容挤成一条。平板/手机是手持近距离阅读，
    /// 桌面是远距离大窗，本来就不该共用一个舒适宽度（同 `SettingsFont` 早有的两套字号）。
    ///
    /// iOS 端已做成设置项（设置-外观-iPad，粟粟 09-04「每个人 pad 不一样」），
    /// 下面的 600 降级为默认值。macOS 默认 720，由独立外观控制台调整。
    static let contentWidthKey = "appearance.ipadContentWidth"
    static let contentWidthDefault: CGFloat = 600

    #if os(macOS)
    static var contentMaxWidth: CGFloat { MacShellMetrics.shared[.contentWidth] }
    #else
    /// 读设置值；没设过或被写成 0 就回默认。**消费点要能实时跟着变**，靠的是
    /// `ContentView` 里那个同 key 的 @AppStorage 订阅——它一变就带着整棵 iOS 树重算，
    /// 各消费点这时重新读到新值（@AppStorage 的 declaration 本身就会订阅，
    /// 见 feedback_appstorage_dead_subscription 记的那个特性）。
    static var contentMaxWidth: CGFloat {
        let stored = UserDefaults.standard.double(forKey: contentWidthKey)
        return stored > 0 ? CGFloat(stored) : contentWidthDefault
    }
    #endif

    /// 宽屏悬浮面板形态的触发阈值：可用宽度 ≥ 此值 → 收起三页横滑，改用左右悬浮面板。
    /// 1100 的取法（粟粟 09-04 批）：iPad 竖屏 1032、iPhone 横屏 956 都不触发；
    /// iPad 横屏全触发（mini 1133 / 11" 1194 / 13" 1376）。
    /// 判据是**可用宽度**而非设备型号——Split View / Stage Manager 把窗口缩窄时
    /// 自动退回三页横滑，不需要额外分支。
    static let landscapePanelThreshold: CGFloat = 1100

    /// 横向滚动区要不要显示滚动条（plan-mac-pointer-model S1-8）。
    ///
    /// mac 显示、iOS 不显示：iOS 靠惯性和边缘弹跳暗示「右边还有」，mac 两样都没有，
    /// 不给滚动条就等于看不出这一条能滚（审计 §6.2：23 处横向滚动区**全部** `showsIndicators: false`）。
    /// macOS 默认是 overlay 滚动条（滚动时才浮现、不占布局）；只有系统设置选了「始终显示滚动条」
    /// 才会挤占宽度——那种情况下矮条（chip 行 26pt）会不会被挤，**要她目视**，挤了就单独退回 false。
    static var hScrollIndicators: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
    static let cardShadow = Color.black.opacity(0.04)
    static let cardShadowRadius: CGFloat = 3

    enum SettingsFont {
        #if os(iOS)
        static let sectionHeader: CGFloat = 16
        static let label: CGFloat = 15
        static let body: CGFloat = 14
        static let secondary: CGFloat = 13
        static let caption: CGFloat = 11
        static let badge: CGFloat = 11
        static let mono: CGFloat = 13
        #else
        static let sectionHeader: CGFloat = 13
        static let label: CGFloat = 12
        static let body: CGFloat = 11
        static let secondary: CGFloat = 10
        static let caption: CGFloat = 9
        static let badge: CGFloat = 8
        static let mono: CGFloat = 11
        #endif
    }

    // 全局别名，方便非设置页使用
    typealias F = SettingsFont

    #if os(iOS)
    static let optionRowVerticalPadding: CGFloat = 12
    static let optionRowSpacing: CGFloat = 2
    #else
    static let optionRowVerticalPadding: CGFloat = 6
    static let optionRowSpacing: CGFloat = 4
    #endif

    static var cream: Color { mainBg }
    static var paleBlue: Color { accent }
    static var softBlue: Color { branchIndicator }
    static var userCard: Color { userBubble }
    static var assistantCard: Color { assistantBubble }
    static let cardCornerRadius = bubbleCornerRadius
    static let cardPadding = bubblePadding
    static let cardSpacing = bubbleSpacing
}

// MARK: - Hex Color Extension
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
