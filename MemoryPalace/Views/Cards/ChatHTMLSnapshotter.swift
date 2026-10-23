import CryptoKit
import SwiftUI
import WebKit

/// 聊天网页卡截图（research-chat-cards §7.2 / §7.4）。与文件库截图器分开：
/// 每 job 一个新 WebView、允许脚本、外部资源按本地模式分级、拦所有页面发起的跳转、6 秒上限、进程崩溃收口。
@MainActor
final class ChatHTMLSnapshotter: NSObject, WKNavigationDelegate {
    static let shared = ChatHTMLSnapshotter()
    static let maxHTMLBytes = 400_000
    static let deadline: TimeInterval = 6
    static let settle: TimeInterval = 1.2
    private static let renderSize = CGSize(width: 390, height: 520)

    enum Result: Equatable { case image(URL), failed }

    private struct Job {
        let key: String
        let html: String
        let offline: Bool
        var completions: [(Result) -> Void]
    }

    private var queue: [Job] = []
    private var current: Job?
    private var webView: WKWebView?
    private var loadedInitial = false
    private var token = 0

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/chat-html-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheKey(html: String, offline: Bool) -> String {
        let hash = SHA256.hash(data: Data(html.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(hash)-\(offline ? "off" : "on")"
    }

    static func cachedImage(key: String) -> URL? {
        let url = cacheDir.appendingPathComponent("\(key).png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func contentSecurityPolicy(offline: Bool) -> String {
        offline
            ? "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data:; connect-src 'none'; frame-src 'none'; form-action 'none';"
            : "default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; img-src https: data: blob:; font-src https: data:; media-src https: data:; connect-src 'none'; frame-src 'none'; form-action 'none';"
    }

    /// CSP meta 必须落在真正的 <head> 里（不在 head 的 CSP meta 会被忽略）：只认 `<head>` / `<head 属性>`，
    /// 且须在 `<body` 之前；否则在最前面补一个 `<head>`（终审 I3：`<header>` 曾被误当成 head）
    static func injectingCSP(into html: String, offline: Bool) -> String {
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy(offline: offline))\">"
        let bodyStart = html.range(of: "<body", options: .caseInsensitive)?.lowerBound ?? html.endIndex
        if let head = html.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]),
           head.lowerBound < bodyStart {
            var out = html
            out.insert(contentsOf: meta, at: head.upperBound)
            return out
        }
        return "<head>" + meta + "</head>" + html
    }

    func snapshot(html: String, completion: @escaping (Result) -> Void) {
        guard html.utf8.count <= Self.maxHTMLBytes else { completion(.failed); return }
        let offline = LocalMode.isOn
        let key = Self.cacheKey(html: html, offline: offline)
        if let hit = Self.cachedImage(key: key) { completion(.image(hit)); return }
        if current?.key == key { current?.completions.append(completion); return }
        if let i = queue.firstIndex(where: { $0.key == key }) { queue[i].completions.append(completion); return }
        queue.append(Job(key: key, html: html, offline: offline, completions: [completion]))
        startNext()
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        token += 1
        let myToken = token
        loadedInitial = false

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: Self.renderSize), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        Self.attachOffscreen(webView)

        webView.loadHTMLString(Self.injectingCSP(into: job.html, offline: job.offline), baseURL: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in
            guard let self, self.token == myToken else { return }
            self.finish(.failed)
        }
    }

    /// 只放行初次载入；页面发起的任何跳转 / 刷新 / 新窗口一律拦
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !loadedInitial, navigationAction.targetFrame?.isMainFrame == true {
            loadedInitial = true
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let myToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
            guard let self, self.token == myToken, let webView = self.webView else { return }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: Self.renderSize)
            webView.takeSnapshot(with: config) { image, _ in
                guard self.token == myToken, let job = self.current else { return }
                guard let image, let data = Self.pngData(image) else { self.finish(.failed); return }
                let url = Self.cacheDir.appendingPathComponent("\(job.key).png")
                self.finish((try? data.write(to: url, options: .atomic)) != nil ? .image(url) : .failed)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failed)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // 被自己拦下的跳转也会走这里：初次载入已放行时不算失败
        if !loadedInitial { finish(.failed) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failed)
    }

    private func finish(_ result: Result) {
        guard let job = current else { return }
        token += 1                                   // 作废本 job 的所有迟到回调
        current = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)    // 清掉仍在跑的脚本 / 定时器
        webView?.removeFromSuperview()
        webView = nil
        job.completions.forEach { $0(result) }
        startNext()
    }

    private static func attachOffscreen(_ webView: WKWebView) {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.windows.first else { return }
        window.insertSubview(webView, at: 0)
        #else
        NSApp.windows.first?.contentView?.addSubview(webView, positioned: .below, relativeTo: nil)
        #endif
    }

    #if os(iOS)
    private static func pngData(_ image: UIImage) -> Data? { image.pngData() }
    #else
    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    #endif
}
