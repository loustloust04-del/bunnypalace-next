#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// 网页应用全屏（plan-garden-webapps §3）：没有地址栏、没有浏览器栏，退出走 page2 外壳的手势。
/// 网址 `gardenapp://<id>/`（文件改名不变），每个应用一个 host = 一个源，存储用按 id 的数据仓，互不相通、删得干净
struct WebAppView: View {
    let toolID: String
    @State private var store = WebAppStore.shared

    var body: some View {
        if let id = WebAppStore.appID(fromToolID: toolID), store.app(id) != nil {
            WebAppWebView(appID: id, toolID: toolID, revision: store.revisions[id] ?? 0)
                .ignoresSafeArea()
                .task { await WebAppWebsiteData.sweepOnce() }
        } else {
            ContentUnavailableView("这个应用已经删掉了", systemImage: "app.dashed")
        }
    }
}

enum WebAppWebsiteData {
    static func store(for id: UUID) -> WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: id) }

    /// 删应用时连它存的东西一起删。网页进程还没退时整个数据仓删不掉（内容已清空，只剩 WebKit 的空壳）：
    /// 记下来，下次启动再删（只删这里记下的——浏览器多身份也是按 id 的数据仓，不能按「不认识」清）
    @MainActor
    static func remove(_ id: UUID) async {
        let store = store(for: id)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        do { try await WKWebsiteDataStore.remove(forIdentifier: id) } catch { pending.insert(id.uuidString) }
    }

    private static let pendingKey = "webapps.pendingStoreRemoval"
    private static var pending: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: pendingKey) ?? []) }
        set { UserDefaults.standard.set(newValue.isEmpty ? nil : Array(newValue).sorted(), forKey: pendingKey) }
    }

    @MainActor private static var swept = false

    /// 每次启动第一次打开网页应用时：上次没删掉的数据仓再删一次（那时它的网页进程早没了）
    @MainActor
    static func sweepOnce() async {
        guard !swept else { return }
        swept = true
        for raw in pending {
            guard let id = UUID(uuidString: raw) else { pending.remove(raw); continue }
            if (try? await WKWebsiteDataStore.remove(forIdentifier: id)) != nil { pending.remove(raw) }
        }
    }
}

private struct WebAppWebView: UIViewRepresentable {
    let appID: UUID
    let toolID: String
    /// 文件改过（编辑器 / AI / 回到某一版）：开着的网页重载；网址和数据仓不变，存的东西还在
    let revision: Int

    /// 点空白处收键盘：输入框有焦点、点的不是能点 / 能输入的东西、手指没滑（滚动不算）→ 失焦
    private static let tapOutsideBlur = """
    (() => {
      const editable = el => el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
      const keep = 'input,textarea,select,button,a,label,summary,[contenteditable],[role=button],[tabindex]';
      let start = null;
      document.addEventListener('touchstart', e => {
        const t = e.touches[0];
        start = e.touches.length === 1 ? { x: t.clientX, y: t.clientY, focused: document.activeElement } : null;
      }, { passive: true, capture: true });
      document.addEventListener('touchend', e => {
        const s = start; start = null;
        if (!s || !editable(s.focused) || document.activeElement !== s.focused) return;
        const t = e.changedTouches[0];
        if (Math.hypot(t.clientX - s.x, t.clientY - s.y) > 10) return;
        if (e.target.closest && e.target.closest(keep)) return;
        s.focused.blur();
      }, { passive: true, capture: true });
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(appID: appID, toolID: toolID, revision: revision) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.files, forURLScheme: WebAppSchemeHandler.scheme)
        config.websiteDataStore = WebAppWebsiteData.store(for: appID)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: Self.tapOutsideBlur, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = .systemBackground
        webView.isInspectable = true
        context.coordinator.watch(webView)
        Coordinator.hideInputAccessory(webView)
        webView.load(URLRequest(url: WebAppSchemeHandler.rootURL(appID)))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.revision != revision else { return }
        context.coordinator.revision = revision
        webView.load(URLRequest(url: WebAppSchemeHandler.rootURL(appID)))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        Page2AppBackRegistry.shared.update(coordinator.toolID, canGoBack: false) {}
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        let appID: UUID
        let toolID: String
        let files = WebAppSchemeHandler()
        var revision: Int
        private var backObservation: NSKeyValueObservation?

        init(appID: UUID, toolID: String, revision: Int) {
            self.appID = appID
            self.toolID = toolID
            self.revision = revision
        }

        /// page2 外壳的返回键：网页里能后退就后退，退到头交给外壳
        func watch(_ webView: WKWebView) {
            let toolID = toolID
            backObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak webView] view, _ in
                let canGoBack = view.canGoBack
                Task { @MainActor in
                    Page2AppBackRegistry.shared.update(toolID, canGoBack: canGoBack) { webView?.goBack() }
                }
            }
        }

        /// 输入框弹键盘时不要 ⌃⌄✓ 那条（同花园浏览器；内容视图换页可能重建，加载完再来一次）
        static func hideInputAccessory(_ webView: WKWebView) {
            webView.disableKeyboardInputAccessory()
            if let content = webView.scrollView.subviews.first(where: { String(describing: type(of: $0)).contains("WKContent") }) {
                content.inputAssistantItem.leadingBarButtonGroups = []
                content.inputAssistantItem.trailingBarButtonGroups = []
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Self.hideInputAccessory(webView)
        }

        private var appName: String {
            MainActor.assumeIsolated { WebAppStore.shared.app(appID)?.title } ?? WebAppHTML.fallbackTitle
        }

        // MARK: 跳转：自己的页面放行，外面的网页交给花园浏览器（应用自己不跳走）

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.cancel) }
            switch scheme {
            case WebAppSchemeHandler.scheme:
                decisionHandler(WebAppSchemeHandler.appID(of: url) == appID ? .allow : .cancel)
            case "about", "data", "blob":
                decisionHandler(.allow)
            case "http", "https":
                if action.targetFrame?.isMainFrame == false {
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                    openWebLink(url)
                }
            default:
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { openWebLink(url) }
            return nil
        }

        // MARK: alert / confirm / prompt（不接的话网页里点了没反应）

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
            let alert = UIAlertController(title: appName, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            present(alert, from: webView) { completionHandler() }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
            let alert = UIAlertController(title: appName, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
            present(alert, from: webView) { completionHandler(false) }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
            let alert = UIAlertController(title: appName, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "好", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text ?? "") })
            present(alert, from: webView) { completionHandler(nil) }
        }

        /// 没有能弹的地方就当场回（WebKit 要求回调必须调一次）
        private func present(_ alert: UIAlertController, from webView: WKWebView, otherwise: () -> Void) {
            var top = webView.window?.rootViewController
            while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
            guard let top else { return otherwise() }
            top.present(alert, animated: true)
        }
    }
}

/// `gardenapp://<应用 id>/` = 应用那个 html；`gardenapp://<应用 id>/<相对路径>` = 它所在文件夹（及子文件夹）里的文件，出不了这一层文件库。
/// 本地模式开着时给网页加 CSP，外网全挡（plan-garden-webapps §3）
final class WebAppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "gardenapp"

    static func rootURL(_ id: UUID) -> URL { URL(string: "\(scheme)://\(id.uuidString.lowercased())/")! }

    static func appID(of url: URL) -> UUID? { url.host().flatMap { UUID(uuidString: $0) } }

    static let offlinePolicy = "default-src gardenapp: data: blob: 'unsafe-inline' 'unsafe-eval'"

    /// WebKit 叫停了的请求：读完别再回
    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let id = Self.appID(of: url) else { return fail(task) }
        let relative = String(url.path.drop { $0 == "/" })
        Task { @MainActor in
            let store = WebAppStore.shared
            guard let main = await store.fileURL(id), let app = store.app(id), let profileId = store.profileId else { return finish(task, url: url, data: nil) }
            let folder = (app.path as NSString).deletingLastPathComponent
            let data = await Task.detached { () -> Data? in
                let file = relative.isEmpty ? main : FileLibraryStore.resolve(folder.isEmpty ? relative : "\(folder)/\(relative)", profileId: profileId)
                guard let file else { return nil }
                return await Self.read(file)
            }.value
            finish(task, url: url, data: data, ext: relative.isEmpty ? main.pathExtension : (relative as NSString).pathExtension)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    /// iCloud 收起的文件先触发下载，等最多 10 秒
    private static func read(_ url: URL) async -> Data? {
        for attempt in 0..<20 {
            if let data = try? Data(contentsOf: url) { return data }
            if attempt == 0, (try? FileManager.default.startDownloadingUbiquitousItem(at: url)) == nil { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func finish(_ task: any WKURLSchemeTask, url: URL, data: Data?, ext: String = "") {
        guard stopped.remove(ObjectIdentifier(task)) == nil else { return }
        guard let data else { return fail(task) }
        let mime = Self.mime(ext)
        var headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
        if mime.hasPrefix("text/html"), LocalMode.isOn { headers["Content-Security-Policy"] = Self.offlinePolicy }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"]) else { return }
        task.didReceive(response)
        task.didReceive(Data())
        task.didFinish()
    }

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
#endif
