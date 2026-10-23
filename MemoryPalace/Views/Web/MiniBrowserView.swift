import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 浏览历史（粟粟拍：历史留——自记 url+标题+时间；cookie/站点存储仍即焚，历史≠站点追踪）

struct BrowsingHistoryEntry: Codable, Identifiable {
    let id: UUID
    let url: String
    let title: String
    let date: Date
}

enum BrowsingHistoryStore {
    private static let maxEntries = 500

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("browsing-history.json")
    }

    static func load() -> [BrowsingHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([BrowsingHistoryEntry].self, from: data) else { return [] }
        return entries
    }

    /// 新条目插头部；与上一条同 url 则只更新标题（避免刷新刷出一串重复）
    static func append(url: String, title: String) {
        var entries = load()
        if let first = entries.first, first.url == url {
            entries[0] = BrowsingHistoryEntry(id: first.id, url: url, title: title, date: Date())
        } else {
            entries.insert(BrowsingHistoryEntry(id: UUID(), url: url, title: title, date: Date()), at: 0)
        }
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 浏览器控制器（representable 与 SwiftUI 条之间的桥）

@MainActor
final class MiniBrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var title = ""
    @Published var isLoading = true
    @Published var canGoBack = false
    @Published var canGoForward = false

    private var observations: [NSKeyValueObservation] = []

    weak var webView: WKWebView? {
        didSet { observeWebView() }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func load(_ url: URL) { webView?.load(URLRequest(url: url)) }

    /// 状态走 KVO 直连，不依赖 delegate 回调时机（SPA/pushState 也能跟上）
    private func observeWebView() {
        observations = []
        guard let webView else { return }
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                let v = wv.canGoBack
                Task { @MainActor in self?.canGoBack = v }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                let v = wv.canGoForward
                Task { @MainActor in self?.canGoForward = v }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                let v = wv.title ?? ""
                Task { @MainActor in self?.title = v }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                let v = wv.isLoading
                Task { @MainActor in self?.isLoading = v }
            }
        ]
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url?.absoluteString, url.hasPrefix("http") {
            BrowsingHistoryStore.append(url: url, title: webView.title ?? url)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "about", "data", "blob"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        // mailto/tel 等交给系统
        openExternalWebViewLink(url.absoluteString)
        decisionHandler(.cancel)
    }

    /// target=_blank / window.open → 当前 webview 里打开，不开新窗
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - WKWebView representable（与 app 零桥接：无 messageHandler、无注入；cookie 持久化共享）
// v2 Phase 3：datastore 切 `.default()` 解锁登录态——粟粟在这里登录知乎/豆瓣，
// InternalBrowser 离屏 browse_url 同域自动带 cookie。

struct BrowserWebView {
    let initialURL: URL
    let controller: MiniBrowserController

    @MainActor
    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = controller
        webView.uiDelegate = controller
        // satyricon §4：阻止 Universal Links 把用户踢出 app（点 zhihu/X 链接被踢去装原生 app 这种）
        webView.allowsLinkPreview = false
        // satyricon §8：UA 伪装真 Safari——X.com 等反爬站默认 WebView UA 缺 Version/N 字段会拒服务白屏
        webView.customUserAgent = WebUserAgent.platformDefault
        #if os(iOS)
        webView.allowsBackForwardNavigationGestures = true
        // 滑动 webview 自动收键盘（CC 终端同款）
        webView.scrollView.keyboardDismissMode = .onDrag
        #endif
        controller.webView = webView
        webView.load(URLRequest(url: initialURL))
        return webView
    }
}

#if os(macOS)
extension BrowserWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension BrowserWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

// MARK: - Mini Browser（W3：本地模式 OFF 时，预览里的链接在这里打开）

struct MiniBrowserView: View {
    let initialURL: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = MiniBrowserController()
    @State private var showHistory = false

    var body: some View {
        #if os(iOS)
        ZStack {
            Color.black.ignoresSafeArea()

            // 四边全出血：和 artifact 预览一致，页面 canvas 铺到灵动岛/home 条底下
            BrowserWebView(initialURL: initialURL, controller: controller)
                .ignoresSafeArea()

            // 顶部渐变遮罩：1:1 抄 page1 照片预览（0.88/150），白按钮对比度靠它
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.88), .black.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 150)
                .allowsHitTesting(false)
                Spacer()
            }
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 10) {
                    glassCircle("xmark") { dismiss() }
                    // 能后退就后退，第一页按后退=关浏览器回预览（Safari push 语义）
                    glassCircle("chevron.left") {
                        if controller.canGoBack { controller.goBack() } else { dismiss() }
                    }
                    glassCircle("chevron.right", disabled: !controller.canGoForward) { controller.goForward() }

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        if controller.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(controller.title.isEmpty ? initialURL.host() ?? "网页" : controller.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)

                    Spacer(minLength: 4)

                    glassCircle("arrow.clockwise") { controller.reload() }
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                    }
                }
                .compositingGroup()
                .padding(.horizontal, 12)
                .padding(.top, 12)

                Spacer()
            }
        }
        .sheet(isPresented: $showHistory) {
            BrowsingHistorySheet { url in
                controller.load(url)
            }
        }
        #else
        NavigationStack {
            BrowserWebView(initialURL: initialURL, controller: controller)
                .navigationTitle(controller.title.isEmpty ? (initialURL.host() ?? "网页") : controller.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                            .foregroundColor(Theme.textMuted)
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            if controller.canGoBack { controller.goBack() } else { dismiss() }
                        } label: { Image(systemName: "chevron.left") }
                        Button { controller.goForward() } label: { Image(systemName: "chevron.right") }
                            .disabled(!controller.canGoForward)
                        Button { controller.reload() } label: {
                            if controller.isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        Menu {
                            menuItems
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
        }
        .frame(width: 860, height: 680)
        .sheet(isPresented: $showHistory) {
            BrowsingHistorySheet { url in
                controller.load(url)
            }
        }
        #endif
    }

    @ViewBuilder
    private var menuItems: some View {
        Button {
            showHistory = true
        } label: {
            Label("历史", systemImage: "clock")
        }
        Button {
            if let url = controller.webView?.url {
                openExternalWebViewLink(url.absoluteString)
            }
        } label: {
            Label("在浏览器打开", systemImage: "safari")
        }
        Button {
            if let url = controller.webView?.url?.absoluteString {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                #else
                UIPasteboard.general.string = url
                #endif
            }
        } label: {
            Label("复制链接", systemImage: "link")
        }
    }

    #if os(iOS)
    private func glassCircle(_ icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(disabled ? 0.35 : 1))
                .frame(width: 38, height: 38)
                .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
        }
        .disabled(disabled)
    }
    #endif
}

// MARK: - 历史面板

private struct BrowsingHistorySheet: View {
    let onOpen: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries = BrowsingHistoryStore.load()

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    Text("还没有浏览记录")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(entries) { entry in
                        Button {
                            if let url = URL(string: entry.url) {
                                onOpen(url)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title.isEmpty ? entry.url : entry.title)
                                    .font(.system(size: Theme.F.body, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(entry.url)
                                        .font(.system(size: Theme.F.caption))
                                        .foregroundColor(Theme.textMuted)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(entry.date.formatted(.relative(presentation: .named)))
                                        .font(.system(size: Theme.F.caption))
                                        .foregroundColor(Theme.textMuted.opacity(0.7))
                                        .fixedSize()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.mainBg)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.mainBg)
            .navigationTitle("浏览历史")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空") {
                        BrowsingHistoryStore.clear()
                        entries = []
                    }
                    .foregroundColor(Theme.textMuted)
                    .disabled(entries.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 420)
        #endif
    }
}
