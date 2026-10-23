import SwiftUI

private struct SystemDesktopKey: EnvironmentKey {
    static let defaultValue = false
}

private struct Page2ActiveKey: EnvironmentKey { static let defaultValue = true }
private struct Page2DateKey: EnvironmentKey { static let defaultValue = Date() }

extension EnvironmentValues {
    var isPage2Active: Bool {
        get { self[Page2ActiveKey.self] }
        set { self[Page2ActiveKey.self] = newValue }
    }
    var page2Date: Date {
        get { self[Page2DateKey.self] }
        set { self[Page2DateKey.self] = newValue }
    }

    var usesSystemDesktop: Bool {
        get { self[SystemDesktopKey.self] }
        set { self[SystemDesktopKey.self] = newValue }
    }
}

struct Page2LegacySurface: ViewModifier {
    @Environment(\.usesSystemDesktop) private var systemDesktop
    @Environment(\.pinnedOnDesktop) private var pinnedOnDesktop
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if systemDesktop {
            content.modifier(Page2WidgetSurface())
        } else { legacy(content) }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(pinnedOnDesktop ? Theme.sidebarBg.opacity(0.9) : Theme.mainBg))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.accent.opacity(0.55), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
