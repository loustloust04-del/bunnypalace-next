import SwiftUI

/// mac 上让 sheet 认 Esc（plan-mac-pointer-model S1-5）。
///
/// macOS 的 SwiftUI `.sheet` **不会**自己响应 Esc——必须有一个 `.keyboardShortcut(.cancelAction)` 的按钮。
/// iOS 靠下滑关闭，不需要，所以整个 modifier 在 `#if os(macOS)` 里，iOS 侧原样返回。
///
/// 隐藏按钮的写法沿用项目既有范式（`CardFlowView` 的 ⌘F、`StickerCanvasLayer` 的 ⌘C/⌘V）：
/// `opacity(0)` + 零尺寸，**不要** `allowsHitTesting(false)`——那会连快捷键一起吞掉。
extension View {
    /// 让这个 sheet 的内容认 Esc。`action` 一般就是 `dismiss()`。
    func macEscapeToDismiss(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        return overlay(alignment: .topLeading) {
            Button("") { action() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        #else
        return self
        #endif
    }
}
