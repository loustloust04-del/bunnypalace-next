import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 内置离屏 WKWebView，给 AI 用：load(URL) → didFinish → 注入 Readability.js + Turndown.js + extract.js → 返回 Markdown。
///
/// 抄 `HTMLThumbnailRenderer` 的离屏 + 串行队列 + 复用单例 pattern：
/// - @MainActor singleton
/// - 队列 + busy 串行（避免并发 load 把 webView 状态搞乱）
/// - attachIfNeeded 塞窗口最底层（不可见但参与渲染）
/// - 完成回调后 loadHTMLString("") 释放当前页内容（不持久占内存）
///
/// 差异点：
/// - JS 必须开（要跑 Readability + Turndown）
/// - datastore 用 nonPersistent（Phase 3 改 persistent 解锁登录态）
/// - 超时 8s（hard-coded）
/// - urlGate 钩子留 Phase 3 黑白名单
@MainActor
final class InternalBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = InternalBrowser()

    /// Phase 3 黑白名单：两段守卫——先查 scheme，再查 WebSearchSettings 黑名单。
    /// 返回 .ok / .reject(理由)。
    @MainActor
    static func gate(_ url: URL) -> GateResult {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            return .reject("仅支持 http/https，收到 \(scheme.isEmpty ? "无 scheme" : scheme)")
        }
        if WebSearchSettings.shared.isBlocked(host: url.host) {
            return .reject("域名 \(url.host ?? "") 在黑名单（设置 → API → 联网搜索 → 黑名单）")
        }
        return .ok
    }

    enum GateResult { case ok, reject(String) }

    struct ExtractedPage {
        let title: String
        let byline: String?
        let markdown: String
        let length: Int          // 原始正文字符数（Markdown 之前）
        let excerpt: String?     // Readability 自带摘要
        let truncated: Bool      // markdown 是否被截断
        let usedCookies: Int     // 该 host 在 default datastore 里的 cookie 数（>0 = 登录态读）
    }

    enum BrowseError: LocalizedError {
        case gateBlocked(String)
        case timeout
        case loadFailed(String)
        case noArticle(title: String, url: String)
        case extractFailed(String)
        case scriptMissing(String)

        var errorDescription: String? {
            switch self {
            case .gateBlocked(let reason): return "URL 不允许访问：\(reason)"
            case .timeout: return "加载超时（8s）"
            case .loadFailed(let msg): return "加载失败：\(msg)"
            case .noArticle(let title, _): return "无可读正文（可能是 SPA / 资源页 / 重定向页）\(title.isEmpty ? "" : "·\(title)")"
            case .extractFailed(let msg): return "正文抽取失败：\(msg)"
            case .scriptMissing(let name): return "缺少脚本资源：\(name)"
            }
        }
    }

    private struct Job {
        let url: URL
        let timeout: TimeInterval
        let completion: (Result<ExtractedPage, Error>) -> Void
    }

    private var queue: [Job] = []
    private var busy = false
    private var webView: WKWebView?
    private var currentJob: Job?
    private var timeoutTask: Task<Void, Never>?

    /// 单次返回 Markdown 上限 8000 字（约 2000 token），plan-web-access-v2-phase1 锁定
    private static let markdownLimit = 8000

    /// async 入口
    func read(url: URL, timeout: TimeInterval = 8.0) async throws -> ExtractedPage {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ExtractedPage, Error>) in
            let job = Job(url: url, timeout: timeout) { result in
                cont.resume(with: result)
            }
            queue.append(job)
            processNext()
        }
    }

    // MARK: - 队列调度

    private func processNext() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        currentJob = job

        switch Self.gate(job.url) {
        case .ok: break
        case .reject(let reason):
            finishCurrent(.failure(BrowseError.gateBlocked(reason)))
            return
        }

        let webView = ensureWebView()
        // 启动超时
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(job.timeout * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                guard self.currentJob?.url == job.url else { return }   // 已完成则忽略
                self.webView?.stopLoading()
                self.finishCurrent(.failure(BrowseError.timeout))
            }
        }
        webView.load(URLRequest(url: job.url))
    }

    // MARK: - WebView 配置

    private func ensureWebView() -> WKWebView {
        if let webView { attachIfNeeded(webView); return webView }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // v2 Phase 3：用 default datastore 解锁登录态——和 MiniBrowserView 共享 cookie，
        // 用户在 MiniBrowser 登录知乎/豆瓣等，InternalBrowser 调 browse_url 同域自动带 cookie
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
        webView.navigationDelegate = self
        // satyricon §4：阻止 Universal Links 把流量踢到原生 app
        webView.allowsLinkPreview = false
        // satyricon §7：离屏 WebView 遇 JS alert/confirm/prompt 会卡住等 UI 响应——给个 noop delegate 自动放行
        webView.uiDelegate = self
        // satyricon §8：UA 伪装真 Safari（X.com 等反爬站默认 WebView UA 缺 Version/N 字段会拒服务白屏）
        webView.customUserAgent = WebUserAgent.platformDefault
        self.webView = webView
        attachIfNeeded(webView)
        return webView
    }

    private func attachIfNeeded(_ webView: WKWebView) {
        guard webView.superview == nil else { return }
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.windows.first else { return }
        window.insertSubview(webView, at: 0)
        #else
        NSApp.windows.first?.contentView?.addSubview(webView, positioned: .below, relativeTo: nil)
        #endif
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            // 给 SPA/iframe 一点喘息再抽——非阻塞 ~600ms（HTMLThumbnailRenderer 用 450ms 拍图，抽正文留多一点）
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.runExtraction(in: webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.finishCurrent(.failure(BrowseError.loadFailed(error.localizedDescription))) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.finishCurrent(.failure(BrowseError.loadFailed(error.localizedDescription))) }
    }

    // MARK: - WKUIDelegate noop（离屏 WebView 不能弹 UI，自动放行所有 JS 弹窗）
    // satyricon §7：alert→放行 / confirm→false / prompt→nil

    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }

    // MARK: - 抽 Markdown

    private func runExtraction(in webView: WKWebView) {
        guard currentJob != nil else { return }
        guard let readability = Self.loadScript(named: "readability.min"),
              let turndown = Self.loadScript(named: "turndown.min"),
              let extractGlue = Self.loadScript(named: "extract") else {
            finishCurrent(.failure(BrowseError.scriptMissing("readability.min.js / turndown.min.js / extract.js")))
            return
        }
        let combined = readability + "\n;" + turndown + "\n;" + extractGlue
        webView.evaluateJavaScript(combined) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.finishCurrent(.failure(BrowseError.extractFailed(error.localizedDescription)))
                    return
                }
                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.finishCurrent(.failure(BrowseError.extractFailed("脚本未返回有效 JSON")))
                    return
                }
                if let err = dict["error"] as? String {
                    if err.hasPrefix("no-article") {
                        let title = dict["title"] as? String ?? ""
                        let url = self.currentJob?.url.absoluteString ?? ""
                        self.finishCurrent(.failure(BrowseError.noArticle(title: title, url: url)))
                    } else {
                        self.finishCurrent(.failure(BrowseError.extractFailed(err)))
                    }
                    return
                }
                let rawMD = dict["markdown"] as? String ?? ""
                let length = dict["length"] as? Int ?? rawMD.count
                let (truncated, md) = Self.truncateIfNeeded(rawMD)
                let host = self.currentJob?.url.host ?? ""
                // 查该 host 在 default datastore 里的 cookie 数（登录态指示）
                let cookieStore = WKWebsiteDataStore.default().httpCookieStore
                cookieStore.getAllCookies { cookies in
                    let count = cookies.filter { c in
                        let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                        return host == d || host.hasSuffix("." + d)
                    }.count
                    Task { @MainActor in
                        let page = ExtractedPage(
                            title: dict["title"] as? String ?? "",
                            byline: dict["byline"] as? String,
                            markdown: md,
                            length: length,
                            excerpt: dict["excerpt"] as? String,
                            truncated: truncated,
                            usedCookies: count
                        )
                        self.finishCurrent(.success(page))
                    }
                }
            }
        }
    }

    private static func truncateIfNeeded(_ md: String) -> (Bool, String) {
        guard md.count > markdownLimit else { return (false, md) }
        let trimmed = String(md.prefix(markdownLimit))
        return (true, trimmed + "\n\n…（正文截断，原始 \(md.count) 字符；如需后续段落，可二次 browse_url 同一 URL 或后续 Phase 加 offset 参数）")
    }

    // MARK: - 收尾

    private func finishCurrent(_ result: Result<ExtractedPage, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let job = currentJob { job.completion(result) }
        currentJob = nil
        busy = false
        // 释放当前页内容（避免占内存 / 后续 readback）
        webView?.loadHTMLString("", baseURL: nil)
        if queue.isEmpty {
            webView?.removeFromSuperview()
        } else {
            processNext()
        }
    }

    // MARK: - 脚本加载

    private static func loadScript(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "ReaderScripts")
            ?? Bundle.main.url(forResource: name, withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
