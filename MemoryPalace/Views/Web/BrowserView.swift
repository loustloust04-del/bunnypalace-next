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

    var body: some View {
        Group {
        if let url = currentURL {
            EmbeddedBrowser(initialURL: url, onHome: { currentURL = nil })
        } else {
            BrowserBlankHome { url in
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

/// page2 内嵌浏览器：上方 toolbar（主页 + 前后退 + 地址栏 + 刷新）+ 下方 WKWebView
private struct EmbeddedBrowser: View {
    let initialURL: URL
    var onHome: () -> Void

    @StateObject private var controller = MiniBrowserController()
    @State private var addressText: String = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            BrowserWebView(initialURL: initialURL, controller: controller)
        }
        // 学 CC 终端的卡片观感：22pt continuous 圆角 + 上下 10pt 留白看圆角
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 10)
        .padding(.bottom, 10)
        .onAppear {
            addressText = initialURL.absoluteString
            #if os(iOS)
            // 隐藏键盘上方的 ⌃⌄✓ input accessory bar——清 WKContentView 的 inputAssistantItem groups
            // WKContentView 是 lazy 创建（首次 input focus 才出），用 0.5s 延迟 + onChange title 多次尝试兜底
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                hideWebViewInputAccessory()
            }
            #endif
        }
        .onChange(of: controller.title) { _, _ in
            // 加载完成后用真实 URL 同步地址栏（除非用户正在输入）
            if !addressFocused, let url = controller.webView?.url?.absoluteString {
                addressText = url
            }
            // 页面切换后兜底再清一次 inputAssistantItem（X 等 SPA 可能换 input 实例）
            #if os(iOS)
            hideWebViewInputAccessory()
            #endif
        }
        #if os(iOS)
        // page2 外壳的导航钮先退网页（plan-page2-app-shell §2.5）
        .onChange(of: controller.canGoBack, initial: true) { _, canGoBack in
            Page2AppBackRegistry.shared.update("browser", canGoBack: canGoBack) { controller.goBack() }
        }
        #endif
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
                    #if os(iOS)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .submitLabel(.go)
                    #endif
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
                controller.reload()
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

    #if os(iOS)
    /// 干掉键盘上方 ⌃⌄✓ accessory bar——动态 subclass WKContentView override inputAccessoryView
    /// 同时清 inputAssistantItem 双 group（双保险）
    private func hideWebViewInputAccessory() {
        guard let webView = controller.webView else { return }
        webView.disableKeyboardInputAccessory()
        if let contentView = webView.scrollView.subviews.first(where: {
            String(describing: type(of: $0)).contains("WKContent")
        }) {
            contentView.inputAssistantItem.leadingBarButtonGroups = []
            contentView.inputAssistantItem.trailingBarButtonGroups = []
        }
    }
    #endif
}

/// 浏览器空白主页：URL 输入栏 + 5 站快捷 + 最近访问
private struct BrowserBlankHome: View {
    var onPick: (URL) -> Void

    @State private var customURL: String = ""
    @State private var history: [BrowsingHistoryEntry] = []
    /// 该 host 在 default datastore 里的 cookie 数 — 让粟粟一眼看到"这站我登录过 vs 没登"
    @State private var cookieByHost: [String: Int] = [:]

    struct QuickSite: Identifiable {
        let id: String
        let name: String
        let urlStr: String
        let symbol: String
        var url: URL? { URL(string: urlStr) }
    }

    private let quickSites: [QuickSite] = [
        QuickSite(id: "zhihu", name: "知乎", urlStr: "https://www.zhihu.com", symbol: "questionmark.bubble.fill"),
        QuickSite(id: "douban", name: "豆瓣", urlStr: "https://www.douban.com", symbol: "books.vertical.fill"),
        QuickSite(id: "x", name: "X", urlStr: "https://x.com", symbol: "xmark"),
        QuickSite(id: "weibo", name: "微博", urlStr: "https://m.weibo.cn", symbol: "w.circle.fill"),
        QuickSite(id: "xhs", name: "小红书", urlStr: "https://www.xiaohongshu.com", symbol: "r.circle.fill"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                urlBar
                quickSection
                if !history.isEmpty { recentSection }
                Spacer(minLength: 40)
            }
        }
        .toolPageBackground()
        .task {
            history = BrowsingHistoryStore.load()
            await loadCookieMap()
        }
    }

    /// 拉所有 cookie 按 host 聚合（host 后缀去 leading dot）。每开一次空白页拉一次。
    @MainActor
    private func loadCookieMap() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        var map: [String: Int] = [:]
        for c in all {
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            map[d, default: 0] += 1
        }
        cookieByHost = map
    }

    /// 查给定 URL 对应 host 的 cookie 数（后缀子域匹配）
    private func cookieCount(for urlStr: String) -> Int {
        guard let host = URL(string: urlStr)?.host?.lowercased() else { return 0 }
        // 后缀子域匹配：example.com 命中 example.com 和 *.example.com
        var max = 0
        for (d, n) in cookieByHost {
            if host == d || host.hasSuffix("." + d) {
                max += n
            }
        }
        return max
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.branchIndicator.opacity(0.7))
            Text("输入网址开始浏览")
                .font(.system(size: Theme.F.body))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.top, 40)
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted)
            TextField("https://...", text: $customURL)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                #if os(iOS)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                #endif
                .onSubmit { tryOpenCustom() }
            if let _ = normalizedURL(customURL) {
                Button {
                    tryOpenCustom()
                } label: {
                    Text("打开")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.mainBg)
        )
        .padding(.horizontal, 20)
    }

    private var quickSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("常用")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted.opacity(0.7))
                .padding(.horizontal, 20)
            HStack(spacing: 12) {
                ForEach(quickSites) { site in
                    Button {
                        if let u = site.url { onPick(u) }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: site.symbol)
                                .font(.system(size: 18))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Theme.mainBg))
                            Text(site.name)
                                .font(.system(size: 10))
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近访问")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted.opacity(0.7))
                Spacer()
                if history.count > 0 {
                    Button("清空") {
                        BrowsingHistoryStore.clear()
                        history = []
                    }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(history.prefix(10)) { entry in
                    Button {
                        if let u = URL(string: entry.url) { onPick(u) }
                    } label: {
                        historyRow(entry)
                    }
                    .buttonStyle(.plain)
                    if entry.id != history.prefix(10).last?.id {
                        Divider().padding(.leading, 44).opacity(0.4)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.mainBg))
            .padding(.horizontal, 20)
        }
    }

    private func historyRow(_ entry: BrowsingHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.url : entry.title)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(entry.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            // 登录态指示：cookie >0 显示小绿锁；==0 不显示
            let n = cookieCount(for: entry.url)
            if n > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 9))
                    Text("\(n)")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(Theme.branchIndicator.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func tryOpenCustom() {
        if let u = normalizedURL(customURL) { onPick(u) }
    }

    private func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.contains(".") else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }
}
