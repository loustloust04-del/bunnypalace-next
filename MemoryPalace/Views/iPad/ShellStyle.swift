import SwiftUI

#if os(macOS)
import AppKit
enum ShellStyle {
    static let windowRadius: CGFloat = 19
    static let panelRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let chipRadius: CGFloat = 6
    static let tabRadius = controlRadius
    static let cellRadius = panelRadius
    static let iconSize: CGFloat = 13
    static let titleSize: CGFloat = 15
    static let bodySize: CGFloat = 13
    static let secondarySize: CGFloat = 11
    static let captionSize: CGFloat = 10   // 设置页脚注档（合流后 mac 认下 iOS 五档，caption 比 secondary 小一档）
    static let microSize: CGFloat = 10
    static let titleFont = Font.system(size: titleSize, weight: .semibold)
    static let labelFont = Font.system(size: bodySize, weight: .medium)
    static let bodyFont = Font.system(size: bodySize, weight: .medium)
    static let secondaryFont = Font.system(size: secondarySize)
    static let captionFont = Font.system(size: captionSize)
    static let microFont = Font.system(size: microSize)
    static let iconFont = Font.system(size: iconSize, weight: .medium)
    static let chipHeight: CGFloat = 26
    static let dockHit: CGFloat = 36
    static let headerButtonWidth: CGFloat = 30
    static let closeButtonWidth: CGFloat = 20
    static let controlGap: CGFloat = 4
    static let gripThickness: CGFloat = 3
    static let gripLength: CGFloat = 28
    static let shadowRadius: CGFloat = 12
    static var windowBackground: Color { Theme.mainBg }
    static var text: Color { Theme.textPrimary }
    static var secondaryText: Color { Theme.textSecondary }
    static var mutedText: Color { Theme.textSecondary.opacity(0.75) }
    static var shadow: Color { Color.black.opacity(0.06) }
    static let tabHeight: CGFloat = 34
    static let barHeight: CGFloat = 40
    static var paneInset: CGFloat { MacShellMetrics.shared[.paneInset] }
    static let cornerHit: CGFloat = 8
    static let edgeHit: CGFloat = 6
    static let hairlineWidth: CGFloat = 0.5
    static var background: Color { Theme.sidebarBg }
    /// 全屏（停靠）模式的「桌布」：整窗一个底色，面板 / dock 都平铺在它上面。
    /// **是 `background` 的别名，不是新色**（R-FS S1-5）——`TabbedToolPanel:66`、`returnStrip` 等
    /// 处已经在画 `background`，另立一色会让它们变成桌布上的补丁。
    static var field: Color { background }
    /// 壳层（列表 / 工具面板 / 停靠条）的底：窗口玻璃开 → 清空露窗底玻璃；关 → 和桌布同色（plan-mac-glass-chrome §1.1）
    @MainActor static var chrome: Color { MacGlass.shared.enabled ? .clear : background }
    /// 全屏模式里唯一浮起来的东西：正文卡
    static var card: Color { Theme.mainBg }
    static var tileGlyph: Color { Theme.branchIndicator }
    static var hairline: Color { Theme.textSecondary.opacity(0.25) }
    static var selection: Color { Theme.branchIndicator.opacity(0.18) }
    static var hover: Color { Theme.textSecondary.opacity(0.07) }
    static var pressed: Color { Theme.textSecondary.opacity(0.13) }
    static func controlFill(selected: Bool, hovered: Bool, pressed: Bool) -> Color {
        if selected { return Theme.branchIndicator.opacity(pressed ? 0.32 : (hovered ? 0.25 : 0.18)) }
        return pressed ? self.pressed : (hovered ? hover : .clear)
    }
    static let feedback = Animation.easeOut(duration: 0.15)
    static var structure: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .linear(duration: 0) : .spring(response: 0.34, dampingFraction: 0.86)
    }
    static let coordinateSpace = "macPanelWorkspace"
}

struct ShellDropHighlight: View {
    var active: Bool
    var radius: CGFloat = ShellStyle.tabRadius

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(ShellStyle.selection)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.branchIndicator, lineWidth: 1)
            }
            .opacity(active ? 1 : 0)
            .animation(ShellStyle.feedback, value: active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 「在这里新开一组」的投放线（PS 的蓝横线，我们用薄荷）：贴在组正文的上 / 下沿（底列横排时是左 / 右沿）
struct ShellDropBand: View {
    var horizontal = false

    var body: some View {
        Capsule()
            .fill(Theme.branchIndicator)
            .frame(width: horizontal ? 3 : nil, height: horizontal ? nil : 3)
            .padding(horizontal ? .vertical : .horizontal, 6)
            .padding(horizontal ? .horizontal : .vertical, 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 正文卡槽左 / 右 / 底沿「停到这一列」的投放带：一条半透明的竖条（底沿是横条）+ 薄荷边线
struct ShellDockEdgeBand: View {
    var horizontal = false

    var body: some View {
        RoundedRectangle(cornerRadius: ShellStyle.tabRadius, style: .continuous)
            .fill(ShellStyle.selection)
            .overlay {
                RoundedRectangle(cornerRadius: ShellStyle.tabRadius, style: .continuous)
                    .strokeBorder(Theme.branchIndicator, lineWidth: 1)
            }
            .frame(width: horizontal ? nil : CardDropZone.edgeBand, height: horizontal ? CardDropZone.bottomBand : nil)
            .padding(4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif

enum ShellMotion {
    static func feedback(_ iPadAnimation: Animation) -> Animation {
        #if os(macOS)
        ShellStyle.feedback
        #else
        iPadAnimation
        #endif
    }

    static func structure(_ iPadAnimation: Animation) -> Animation {
        #if os(macOS)
        ShellStyle.structure
        #else
        iPadAnimation
        #endif
    }
}
