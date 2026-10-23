#if canImport(UIKit)
import UIKit

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 工具条尺寸表（物料表 §9.1 iPhone 两档全抄；iPad preset 不做 —— MP 无 iPad 场景，物料表 ASK4 裁决）。
///
/// 跟 rootshell 的一处差别：MP 的条是**玻璃药丸**（左右留边、圆角浮起，调性已拍），
/// rootshell 是通栏平条。所以在 rootshell 的 `toolbar.height` 之外多一层 `pillPadding`
/// 把药丸撑出来；行高/键高/键宽/圆角/字号全按表走。
struct TerminalToolbarSizes: Equatable {
    /// 一行的高度（主行和抽屉行同值）
    var rowHeight: CGFloat
    var buttonHeight: CGFloat
    var normalWidth: CGFloat
    var wideWidth: CGFloat
    var buttonCorner: CGFloat
    var fontSize: CGFloat
    var symbolSize: CGFloat
    /// 药丸相对整条的上下留白（MP 专有）
    var pillPadding: CGFloat
    /// 药丸左右留边（MP 专有）
    var pillInset: CGFloat
    var pillCorner: CGFloat
    /// 行内左右边距。iPhone 横屏 rootshell 用 6，竖屏 2（物料表 §9.5）
    var rowEdgePadding: CGFloat

    static let portrait = TerminalToolbarSizes(
        rowHeight: 44, buttonHeight: 38, normalWidth: 33, wideWidth: 48,
        buttonCorner: 10, fontSize: 15, symbolSize: 16,
        pillPadding: 4, pillInset: 8, pillCorner: 18, rowEdgePadding: 2
    )

    static let landscape = TerminalToolbarSizes(
        rowHeight: 38, buttonHeight: 32, normalWidth: 30, wideWidth: 44,
        buttonCorner: 9, fontSize: 14, symbolSize: 15,
        pillPadding: 4, pillInset: 8, pillCorner: 16, rowEdgePadding: 6
    )

    /// preset 选择：优先 trait collection 的 vertical size class（`.compact` = 横屏），
    /// 拿不到再看屏幕长宽比（物料表 §9.2）。
    static func resolve(for traits: UITraitCollection?, screenSize: CGSize) -> TerminalToolbarSizes {
        switch traits?.verticalSizeClass {
        case .compact: return .landscape
        case .regular: return .portrait
        default: return screenSize.width > screenSize.height ? .landscape : .portrait
        }
    }

    /// 整条高度（含药丸留白）。`drawerRows` = 当前展开的抽屉行数。
    func totalHeight(drawerRows: Int) -> CGFloat {
        rowHeight * CGFloat(1 + max(0, drawerRows)) + pillPadding * 2
    }
}
#endif
