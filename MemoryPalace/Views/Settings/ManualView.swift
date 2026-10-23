import SwiftUI

/// App 内说明书。页面是 `Resources/Web/manual.html`（`scripts/manual` 从 `manual/*.md` 构建的单文件），
/// 壳复用 `WebViewHost`。颜色 / 深浅 / 字号 / 平台 / lite-pro / 锚点全靠 payload 注入，
/// 页面不依赖 `prefers-color-scheme`（自定义主题 WebKit 不知道）。
struct ManualView: View {
    /// 打开时直接跳到的锚点（页 `name` 或 `name--小节`）。nil = 取设置搜索投递的锚点，再没有就首页。
    var anchor: String? = nil

    @AppStorage("fontScale") private var fontScale: Double = 1.2
    #if os(iOS)
    @AppStorage("settings.proMode") private var isPro = false
    #endif
    @State private var pendingAnchor: String?
    @State private var tookAnchor = false

    var body: some View {
        let manager = ThemeManager.shared
        let _ = manager.themeChangeID
        WebViewHost(htmlResourceName: "manual", payload: payload(manager), onMessage: handle)
            .background(Theme.mainBg)
            #if os(iOS)
            .navigationTitle("文档")
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                guard !tookAnchor else { return }
                tookAnchor = true
                pendingAnchor = anchor ?? SettingsSearchRouter.shared.takePending()
            }
    }

    private func payload(_ manager: ThemeManager) -> [String: Any] {
        let t = manager.currentTokenSet
        let colors: [String: String] = [
            "mainBg": t.mainBg.hexString,
            "sidebarBg": t.sidebarBg.hexString,
            "textPrimary": t.textPrimary.hexString,
            "textSecondary": t.textSecondary.hexString,
            "textMuted": t.textMuted.hexString,
            "accent": t.accent.hexString,
            "branchIndicator": t.branchIndicator.hexString,
            "danger": t.danger.hexString,
            "favorite": t.favorite.hexString,
        ]
        #if os(iOS)
        let platform = "ios"
        let pro = isPro
        #else
        let platform = "macos"
        let pro = true
        #endif
        var p: [String: Any] = [
            "colors": colors,
            "scheme": manager.activeScheme == .dark ? "dark" : "light",
            "fontScale": fontScale > 0 ? fontScale : 1.2,
            "platform": platform,
            "isPro": pro,
        ]
        if let pendingAnchor { p["anchor"] = pendingAnchor }
        return p
    }

    private func handle(_ message: WebViewBridgeMessage) {
        if message.type == "openLink" {
            openExternalWebViewLink(message.href)
        }
    }
}

#if os(macOS)
/// 菜单栏「帮助 › 记忆花园 帮助」。`openWindow` 只能在 View 环境里拿，所以包成 View 塞进 CommandGroup。
struct ManualHelpCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("记忆花园 帮助") { openWindow(id: "manual") }
            .keyboardShortcut("?", modifiers: .command)
    }
}
#endif
