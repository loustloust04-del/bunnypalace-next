import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 推特子应用的震动反馈（粟粟 2026-09-24 要的）。轻重照推特：
/// 点赞/切 tab 轻、转帖/删除中、发出去和导完成功、失败报错。macOS 上什么都不做。
@MainActor
enum TwitterHaptics {
    static func tap() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func light() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func medium() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func failure() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

/// 复制原帖链接用。
enum TwitterClipboard {
    static func copy(_ url: URL) {
        #if os(iOS)
        UIPasteboard.general.url = url
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
    }
}
