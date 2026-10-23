#if os(iOS)
import Foundation
import GameController

// Portions adapted from rootshell (MIT, Copyright (c) 2026 Rootshell LLC, Kit Knox) — see THIRD_PARTY_LICENSES.md
/// 外接键盘在不在（物料表 §10.1）。
///
/// 判定式照抄 rootshell：
/// ```
/// 显示条 = 没有外接键盘 || 软键盘实际可见
/// ```
/// 也就是「外接键盘 + 软键盘不可见」时把条收起来 —— 那种场景所有键都能从实体键盘敲，
/// 屏幕上再压一条只是挡地方。rootshell 有个「接了外键也显示条」的设置项，**先不做**（plan §C7）。
///
/// 主检测源是 `GCKeyboard.coalesced != nil`：启动读一次，之后靠连接/断开通知维护。
///
/// 只在主线程用（键盘通知 handler 里），不加 `@MainActor` 是为了让 UIView 的 `@objc`
/// 通知 handler 能直接调，不用到处套 `MainActor.assumeIsolated`。
final class TerminalHardwareKeyboard {
    static let shared = TerminalHardwareKeyboard()

    /// 软键盘「算可见」的高度门槛。低于它的多半只是 accessory/工具条那点高度，
    /// 不是真的软键盘（物料表 §10.1）。
    static let softwareKeyboardMinHeight: CGFloat = 120

    private(set) var isConnected: Bool

    private init() {
        isConnected = GCKeyboard.coalesced != nil
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.isConnected = true
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.isConnected = false
        }
    }

    /// 键盘 frame 更新时再 poll 一次，补掉漏掉的通知（rootshell 同款保险，物料表 §10.1）
    func refresh() {
        isConnected = GCKeyboard.coalesced != nil
    }

    /// 条该不该显示。`visibleKeyboardHeight` = 窗口底边到键盘顶边的距离。
    func shouldShowToolbar(visibleKeyboardHeight: CGFloat) -> Bool {
        refresh()
        if !isConnected { return true }
        return visibleKeyboardHeight > Self.softwareKeyboardMinHeight
    }
}
#endif
