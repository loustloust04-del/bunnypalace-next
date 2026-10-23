import SwiftUI

/// 设置页两端共用的度量表（plan-settings-merge §2.1）：页面写 `m.caption`，不写 `#if os`。
/// 五档是语义角色（iOS 16/15/14/13/11，mac 13/13/13/11/10），调用点自己加 `.weight` / `.monospaced()`。
struct SettingsMetrics {
    var sectionHeader: Font
    var label: Font
    var body: Font
    /// 行的主标题：iOS 一直是 body + semibold，mac（Tahoe 系统设置口径）是 body regular——两端字重不同，所以单独一档
    var rowTitle: Font
    /// 动作行标题（导出 / 导入这类按钮行）：iOS 是 body + medium，mac 行文字一律 regular（J2 显式压回来的）——同 rowTitle 的道理单独一档
    var action: Font
    /// label 档的行标题（CC 页「推送显示名」这类）：iOS 是 label + medium，mac 仍是行文字 regular——同上，第三档字重分叉（刀 3b 收口加）
    var rowLabel: Font
    var secondary: Font
    var caption: Font
    var mono: Font
    /// 收 `CGFloat` 的叶子（`DisclosureModeRow` / `StreamingModeRow` / `ThinkingPhrasePackPicker` / `LiquidMetalRingToggle` / `.custom(_, size:)` 字体预览）用这两个，与 body / secondary 同档同值——直写 `Theme.F` 在 mac 读的是 `SettingsFont` 表 11/10，不是本表（R6c I1）
    var bodySize: CGFloat
    var secondarySize: CGFloat
    var sectionHeaderColor: Color
    /// 页面自画卡的底色：iOS 是 `Theme.mainBg`（页底是 sidebarBg，卡才显得出来）；mac 页底就是 mainBg，卡要用 `ShellStyle.hover` 才有边界
    var cardFill: Color
    var cardPadding: CGFloat
    var rowSpacing: CGFloat
    var cardCorner: CGFloat

    static let iOS = SettingsMetrics(
        sectionHeader: .system(size: Theme.F.sectionHeader, weight: .semibold),
        label: .system(size: Theme.F.label),
        body: .system(size: Theme.F.body),
        rowTitle: .system(size: Theme.F.body, weight: .semibold),
        action: .system(size: Theme.F.body, weight: .medium),
        rowLabel: .system(size: Theme.F.label, weight: .medium),
        secondary: .system(size: Theme.F.secondary),
        caption: .system(size: Theme.F.caption),
        mono: .system(size: Theme.F.mono, design: .monospaced),
        bodySize: Theme.F.body,
        secondarySize: Theme.F.secondary,
        sectionHeaderColor: Theme.textPrimary,
        cardFill: Theme.mainBg,
        cardPadding: 12,
        rowSpacing: 8,
        cardCorner: 8
    )

    #if os(macOS)
    static var mac: SettingsMetrics {
        let s = MacMetricsOverride.sizes
        return SettingsMetrics(
            sectionHeader: .system(size: s.sectionHeader, weight: .semibold),
            label: .system(size: s.label, weight: .medium),
            body: .system(size: s.body),
            rowTitle: .system(size: s.body),
            action: .system(size: s.body),
            rowLabel: .system(size: s.label),   // 归 label 档（不是 body）：iOS 侧原式是 label+medium；mac 默认 label = body = 13，改 defaults 时跟 label 走
            secondary: .system(size: s.secondary),
            caption: .system(size: s.caption),
            mono: .system(size: s.secondary, design: .monospaced),
            bodySize: s.body,
            secondarySize: s.secondary,
            sectionHeaderColor: ShellStyle.text,
            cardFill: ShellStyle.hover,
            cardPadding: 14,
            rowSpacing: 10,
            cardCorner: ShellStyle.panelRadius
        )
    }
    #endif

    /// 环境默认值按平台取，独立入口（右栏 sheet 直开 `VocabSettingsTab` 之类）不注入也对
    static var platform: SettingsMetrics {
        #if os(macOS)
        mac
        #else
        iOS
        #endif
    }
}

#if os(macOS)
/// mac 五档字号可配（粟粟：数字最好能自己改）。
/// `defaults write com.susu.MemoryPalace settings.metrics.mac.caption -float 11`，下次创建设置窗生效；缺键 / ≤0 / 非有限数回默认。
enum MacMetricsOverride {
    struct Sizes {
        var sectionHeader: CGFloat
        var label: CGFloat
        var body: CGFloat
        var secondary: CGFloat
        var caption: CGFloat
    }

    static let defaults = Sizes(sectionHeader: 13, label: 13, body: 13, secondary: 11, caption: 10)

    static var sizes: Sizes {
        func read(_ key: String, _ fallback: CGFloat) -> CGFloat {
            let v = UserDefaults.standard.double(forKey: "settings.metrics.mac.\(key)")
            return v.isFinite && v > 0 ? CGFloat(v) : fallback
        }
        return Sizes(
            sectionHeader: read("sectionHeader", defaults.sectionHeader),
            label: read("label", defaults.label),
            body: read("body", defaults.body),
            secondary: read("secondary", defaults.secondary),
            caption: read("caption", defaults.caption)
        )
    }
}
#endif

extension EnvironmentValues {
    @Entry var settingsMetrics: SettingsMetrics = .platform
}
