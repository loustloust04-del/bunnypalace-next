import Foundation
import WebKit

/// #059 ② 的纯逻辑：判断下载响应、跳转、落盘位置（不碰 WebKit，测试直接调）
enum ClaudeExportDownload {
    enum Failure: Equatable {
        /// 401 / 403、跳去登录页、拿回来是网页
        case notLoggedIn
        /// 404 / 410：链接用过了或过期
        case linkUsed
        case server(Int)
        case tooLarge
        case empty
        /// 不是 `https://claude.ai/export/…`，或跳去了非 https
        case refused
        /// 停在页面上时清单过了 24 小时
        case expired
        /// 只留错误码：系统的错误原文可能带着链接
        case network(Int)

        var message: String {
            switch self {
            case .notLoggedIn: "还没登录上"
            case .linkUsed: "下载失败（链接可能已经用过或过期）"
            case .server(let code): "下载失败（claude.ai 返回 \(code)）"
            case .tooLarge: "超过 4 GB，没下"
            case .empty: "下下来是空的"
            case .refused: "不是 claude.ai 的下载链接，没下"
            case .expired: "清单过期了，没下"
            case .network(let code): Self.networkMessage(code)
            }
        }

        private static func networkMessage(_ code: Int) -> String {
            switch code {
            case NSURLErrorNotConnectedToInternet: "下载失败：没联网"
            case NSURLErrorNetworkConnectionLost: "下载失败：网络断了"
            case NSURLErrorTimedOut: "下载失败：超时"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed: "下载失败：连不上服务器"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: "下载失败：安全连接失败"
            case NSURLErrorCannotWriteToFile, NSURLErrorCannotCreateFile: "下载失败：存不下（磁盘满了？）"
            default: "下载失败（错误码 \(code)）"
            }
        }
    }

    static func failure(for error: Error) -> Failure {
        .network((error as NSError).code)
    }

    /// 单包上限，沿用导入解包总预算
    static let maxBytes = Int64(ExportPackageScanner.limits.maxTotalBytes)
    static let loginURL = URL(string: "https://claude.ai/login")!

    /// 服务器回的头：nil = 可以下
    static func classify(_ response: URLResponse) -> Failure? {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: return .notLoggedIn
            case 404, 410: return .linkUsed
            default: return .server(http.statusCode)
            }
        }
        if response.mimeType?.lowercased() == "text/html" { return .notLoggedIn }
        if response.expectedContentLength > maxBytes { return .tooLarge }
        return nil
    }

    /// 下载途中的跳转：nil = 放行（导出包可能跳到存储服务的签名链接）
    static func redirectFailure(to url: URL?) -> Failure? {
        guard let url, url.scheme?.lowercased() == "https" else { return .refused }
        if url.host?.lowercased() == "claude.ai", url.path.hasPrefix("/login") { return .notLoggedIn }
        return nil
    }

    /// 落盘用清单里的文件名（清单解析时已限定单层 .zip），不信服务器给的名字
    static func destination(for package: ClaudeExportManifest.Package, in directory: URL) -> URL? {
        let name = package.filename
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        return url.lastPathComponent == name ? url : nil
    }
}

/// #059 ②：花园里登录 claude.ai，用同一个网页会话把清单里要导的包逐个下到临时目录。
/// 登录只在内存（`nonPersistent`），不和 AI 联网的登录（`.default()`）共用；`close()` 后丢掉（粟粟 10-10 D1–D3）
@MainActor
@Observable
final class ClaudeExportDownloader {
    enum Status: Equatable {
        case waiting
        case downloading(Double)
        case done
        case failed(ClaudeExportDownload.Failure)
    }

    private(set) var statuses: [String: Status] = [:]
    private(set) var isRunning = false
    /// 点过「开始下载」
    private(set) var hasStarted = false
    /// 下到一半发现没登录：登录页重新露出来，登好再点开始
    private(set) var needsLogin = false

    /// 临时目录用导入 staging 的前缀：App 被杀留下的，下次开导入页按 1 小时规则清掉
    let directory: URL
    let webView: WKWebView
    let packages: [ClaudeExportManifest.Package]
    @ObservationIgnored private let expiresAt: Date?

    @ObservationIgnored private var queue: [ClaudeExportManifest.Package] = []
    @ObservationIgnored private var current: (download: WKDownload, id: String, progress: NSKeyValueObservation)?
    @ObservationIgnored private var delegate: Delegate!
    @ObservationIgnored private var handedOff = false
    /// 关了就不再接 WebKit 迟到的回调（迟到的下载直接取消）
    @ObservationIgnored private var closed = false

    /// only：从预览进来时只下这次没选到的包（文件名）；nil = 要导的全下
    init(manifest: ClaudeExportManifest, only: Set<String>? = nil) {
        packages = manifest.packages.filter { $0.isNeeded && (only?.contains($0.filename) ?? true) }
        expiresAt = manifest.expiresAt
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(ExportPackageScanner.stagingPrefix)claude-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = WebUserAgent.platformDefault
        webView.allowsLinkPreview = false
        for package in packages { statuses[package.id] = .waiting }
        delegate = Delegate(owner: self)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.load(URLRequest(url: ClaudeExportDownload.loginURL))
    }

    /// 要导的包都有结果了（下好或失败）
    var isFinished: Bool {
        hasStarted && !isRunning && !needsLogin && packages.allSatisfy {
            switch statuses[$0.id] { case .done, .failed: true; default: false }
        }
    }

    var downloaded: [String] { packages.filter { statuses[$0.id] == .done }.map(\.filename) }
    var failed: [String] {
        packages.filter { if case .failed = statuses[$0.id] { true } else { false } }.map(\.filename)
    }

    func start() {
        guard !isRunning else { return }
        hasStarted = true
        needsLogin = false
        queue = packages.filter { statuses[$0.id] == .waiting }
        isRunning = true
        next()
    }

    /// 下好的交给导入（目录之后由 `ImportSession` 删）；目录里别的（失败留下的半截）先删掉
    func handOff() -> (directory: URL, files: [URL]) {
        handedOff = true
        let files = packages.filter { statuses[$0.id] == .done }
            .compactMap { ClaudeExportDownload.destination(for: $0, in: directory) }
        let keep = Set(files.map(\.lastPathComponent))
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        return (directory, files)
    }

    /// 关下载页：停下载、丢登录（内存里的 cookie 一起清）、没交出去的目录删掉
    func close() {
        closed = true
        queue = []
        if let current {
            current.progress.invalidate()
            current.download.cancel { _ in }
        }
        current = nil
        isRunning = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        if !handedOff {
            let dir = directory
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: dir) }
        }
    }

    private func next() {
        guard isRunning else { return }
        guard !queue.isEmpty else {
            isRunning = false
            return
        }
        let package = queue.removeFirst()
        guard ClaudeExportManifest.isDownloadURL(package.url) else {
            finish(package.id, .failed(.refused))
            return
        }
        if let expiresAt, Date() >= expiresAt {
            finish(package.id, .failed(.expired))
            return
        }
        statuses[package.id] = .downloading(0)
        webView.startDownload(using: URLRequest(url: package.url)) { [weak self] download in
            guard let self, !self.closed else {
                download.cancel { _ in }
                return
            }
            download.delegate = self.delegate
            let observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted, bytes = progress.completedUnitCount
                Task { @MainActor in self?.progressed(download, fraction, bytes) }
            }
            self.current = (download, package.id, observation)
        }
    }

    private func progressed(_ download: WKDownload, _ fraction: Double, _ bytes: Int64) {
        guard let current, current.download === download, statuses[current.id] != nil else { return }
        if bytes > ClaudeExportDownload.maxBytes {
            download.cancel { _ in }
            finish(current.id, .failed(.tooLarge))
            return
        }
        statuses[current.id] = .downloading(fraction)
    }

    /// 当前这个下完 / 失败：记状态、接着下一个。没登录就整体停下，剩下的回到等待
    private func finish(_ id: String, _ status: Status) {
        if let current, current.id == id {
            current.progress.invalidate()
            self.current = nil
        }
        if status == .failed(.notLoggedIn) {
            statuses[id] = .waiting
            queue = []
            isRunning = false
            needsLogin = true
            return
        }
        statuses[id] = status
        if case .failed = status, let package = packages.first(where: { $0.id == id }),
           let url = ClaudeExportDownload.destination(for: package, in: directory) {
            try? FileManager.default.removeItem(at: url)
        }
        // 等这次 WebKit 回调（可能正要取消这个下载）返回后再起下一个
        Task { @MainActor [weak self] in self?.next() }
    }

    fileprivate func destination(for download: WKDownload, response: URLResponse) -> URL? {
        guard let current, current.download === download,
              let package = packages.first(where: { $0.id == current.id }) else { return nil }
        if let failure = ClaudeExportDownload.classify(response) {
            finish(current.id, .failed(failure))
            return nil
        }
        guard let url = ClaudeExportDownload.destination(for: package, in: directory) else {
            finish(current.id, .failed(.refused))
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return url
    }

    fileprivate func redirect(_ download: WKDownload, to url: URL?) -> Bool {
        guard let current, current.download === download else { return false }
        if let failure = ClaudeExportDownload.redirectFailure(to: url) {
            finish(current.id, .failed(failure))
            return false
        }
        return true
    }

    fileprivate func finished(_ download: WKDownload) {
        guard let current, current.download === download,
              let package = packages.first(where: { $0.id == current.id }),
              let url = ClaudeExportDownload.destination(for: package, in: directory) else { return }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        finish(current.id, size == 0 ? .failed(.empty) : size > ClaudeExportDownload.maxBytes ? .failed(.tooLarge) : .done)
    }

    fileprivate func failed(_ download: WKDownload, _ error: Error) {
        guard let current, current.download === download else { return }
        finish(current.id, .failed(ClaudeExportDownload.failure(for: error)))
    }

    /// WebKit 回调转给下载器；登录页只放 https，不在页面里开新窗、不让页面自己触发下载
    private final class Delegate: NSObject, WKDownloadDelegate, WKNavigationDelegate, WKUIDelegate {
        weak var owner: ClaudeExportDownloader?

        init(owner: ClaudeExportDownloader) { self.owner = owner }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            MainActor.assumeIsolated { completionHandler(owner?.destination(for: download, response: response)) }
        }

        func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                      newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
            MainActor.assumeIsolated {
                decisionHandler(owner?.redirect(download, to: request.url) == true ? .allow : .cancel)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            MainActor.assumeIsolated { owner?.finished(download) }
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            MainActor.assumeIsolated { owner?.failed(download, error) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            decisionHandler(["https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, url.scheme?.lowercased() == "https" {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}
