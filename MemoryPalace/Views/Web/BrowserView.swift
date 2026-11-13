import SwiftUI
import WebKit

/// page2 浏览器 tool 主体。专为 page2 内嵌设计——不 ignoresSafeArea、地址栏可编辑、自家轻工具栏。
/// 学 CCTerminalPanelView 同款风格——填 panelContent 区域、dock 不动、不浮窗。
///
/// 状态机：currentURL == nil → 空白页 / != nil → 浏览态（工具栏 + WebView）
/// 切走 tool 再切回浏览器 SwiftUI state 重建自动回空白页。
/// 历史靠 BrowsingHistoryStore（MiniBrowserController.didFinish 自动写）
struct BrowserView: View {
    @Environment(RightPanelNavigator.self) private var desktopNavigator: RightPanelNavigator?
    @State private var currentURL: URL? = nil
    /// 当前身份（plan-garden-browser-identities §3）：记住上次用的
    @State private var identity = BrowserIdentityStore.current()

    var body: some View {
        Group {
        if let url = currentURL {
            #if os(iOS)
            GardenBrowserView(initialURL: url, embedded: true, identity: identity, onSwitchIdentity: { other, at in
                BrowserIdentityStore.setCurrent(other.id)
                identity = other
                currentURL = at
            }, onClose: { currentURL = nil })
            // 换身份 = 换一个 webView（数据仓建 webView 时就定了）
            .id(identity.id)
            #else
            EmbeddedBrowser(initialURL: url, identity: identity, onHome: { currentURL = nil })
                .id(identity.id)
            #endif
        } else {
            BrowserHome(identity: $identity) { url in
                currentURL = url
            }
        }
        }
        .onAppear { consumeDesktopTarget() }
        .onChange(of: desktopNavigator?.pendingTarget) { _, _ in consumeDesktopTarget() }
    }

    private func consumeDesktopTarget() {
        guard let target = desktopNavigator?.pendingTarget, target.tool == "browser" else { return }
        desktopNavigator?.pendingTarget = nil
        guard let url = URL(string: target.id), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        currentURL = url
    }
}

#if os(macOS)
/// page2 内嵌浏览器（mac）：上方 toolbar（主页 + 前后退 + 地址栏 + 刷新）+ 下方 WKWebView。iOS 用 GardenBrowserView(embedded:)
private struct EmbeddedBrowser: View {
    let initialURL: URL
    let identity: BrowserIdentity
    var onHome: () -> Void

    @StateObject private var controller = MiniBrowserController()
    @State private var addressText: String = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            BrowserWebView(initialURL: initialURL, controller: controller, identity: identity)
        }
        // 学 CC 终端的卡片观感：22pt continuous 圆角 + 上下 10pt 留白看圆角
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 10)
        .padding(.bottom, 10)
        .onAppear {
            addressText = initialURL.absoluteString
        }
        .onChange(of: controller.title) { _, _ in
            // 加载完成后用真实 URL 同步地址栏（除非用户正在输入）
            if !addressFocused, let url = controller.webView?.url?.absoluteString {
                addressText = url
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button {
                onHome()
            } label: {
                Image(systemName: "house.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("回主页")

            Button {
                controller.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(controller.canGoBack ? Theme.textSecondary : Theme.textMuted.opacity(0.4))
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canGoBack)

            Button {
                controller.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(controller.canGoForward ? Theme.textSecondary : Theme.textMuted.opacity(0.4))
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canGoForward)

            // 地址栏（可编辑）
            HStack(spacing: 6) {
                if controller.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
                TextField("网址", text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .focused($addressFocused)
                    .onSubmit {
                        if let url = normalizedURL(addressText) {
                            controller.load(url)
                            addressFocused = false
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.mainBg))

            Button {
                if controller.isLoading { controller.stopLoading() } else { controller.reload() }
            } label: {
                Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help(controller.isLoading ? "停止" : "刷新")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.mainBg)   // 暖奶白——跟外层 sidebarBg 浅灰薄荷有色差，圆角才看得见
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }

    private func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // 含 . 当 URL；否则当搜索词（暂不实现搜索，require URL）
        guard s.contains(".") else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }
}
#endif
