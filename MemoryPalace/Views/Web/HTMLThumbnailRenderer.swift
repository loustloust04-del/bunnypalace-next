import SwiftUI
import WebKit
import CryptoKit
#if os(macOS)
import AppKit
private typealias ThumbImage = NSImage
#else
import UIKit
private typealias ThumbImage = UIImage
#endif

/// 文件库 HTML 卡片缩略图：离屏 WKWebView 渲染一帧「这页长啥样」。
/// - JS 关闭（快照不跑脚本）；CSP 跟随本地模式（ON 时外网资源不参与快照）
/// - 串行队列复用一个 WKWebView；PNG 落盘缓存，key = 路径+mtime+本地模式
@MainActor
final class HTMLThumbnailRenderer: NSObject, WKNavigationDelegate {
    static let shared = HTMLThumbnailRenderer()

    private struct Job {
        let html: String
        let cacheKey: String
        let completion: (ThumbImage?) -> Void
    }

    private var queue: [Job] = []
    private var busy = false
    private var webView: WKWebView?
    private var currentJob: Job?

    private static let renderSize = CGSize(width: 320, height: 430)

    private static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace/html-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheKey(path: String, modifiedAt: Date) -> String {
        "\(path)|\(modifiedAt.timeIntervalSince1970)|\(LocalMode.isOn ? "off" : "on")line"
    }

    private static func cacheURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        return cacheDir.appendingPathComponent("\(hash).png")
    }

    fileprivate static func cached(for key: String) -> ThumbImage? {
        guard let data = try? Data(contentsOf: cacheURL(for: key)) else { return nil }
        return ThumbImage(data: data)
    }

    fileprivate func render(html: String, cacheKey: String, completion: @escaping (ThumbImage?) -> Void) {
        if let hit = Self.cached(for: cacheKey) {
            completion(hit)
            return
        }
        queue.append(Job(html: html, cacheKey: cacheKey, completion: completion))
        processNext()
    }

    private func processNext() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let job = queue.removeFirst()
        currentJob = job

        let webView = ensureWebView()
        // 快照里也守网络分级：本地模式 ON 注离线 CSP，OFF 放行子资源
        let csp = LocalMode.isOn
            ? "default-src 'none'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data:;"
            : "default-src 'none'; style-src 'unsafe-inline' https:; img-src https: data: blob:; font-src https: data:; media-src https: data:;"
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
        var html = job.html
        if let range = html.range(of: "<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: meta, at: range.upperBound)
        } else {
            html = meta + html
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func ensureWebView() -> WKWebView {
        if let webView { attachIfNeeded(webView); return webView }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: Self.renderSize), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        attachIfNeeded(webView)
        return webView
    }

    /// 离屏 WKWebView 不在窗口层级里可能不渲染；塞到 key window 最底层（被不透明界面完全盖住，不可见）
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 给 CSS/图片一点喘息再拍
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            self.takeSnapshot(webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishCurrent(nil)
    }

    private func takeSnapshot(_ webView: WKWebView) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: Self.renderSize)
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            Task { @MainActor in
                self?.finishCurrent(image)
            }
        }
    }

    private func finishCurrent(_ image: ThumbImage?) {
        if let job = currentJob {
            if let image {
                #if os(macOS)
                let data = (image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })?
                    .representation(using: .png, properties: [:])
                #else
                let data = image.pngData()
                #endif
                if let data { try? data.write(to: Self.cacheURL(for: job.cacheKey), options: .atomic) }
            }
            job.completion(image)
        }
        currentJob = nil
        busy = false
        if queue.isEmpty {
            webView?.removeFromSuperview()
        } else {
            processNext()
        }
    }
}

/// 文件库卡片的 HTML 快照视图：缓存命中即显示，否则先显示源码纸占位、渲染完替换
struct HTMLCardThumbView: View {
    let path: String
    let profileId: String
    let modifiedAt: Date
    let placeholder: AnyView

    @State private var image: ThumbImage?

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #else
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #endif
            } else {
                placeholder
            }
        }
        .task(id: HTMLThumbnailRenderer.cacheKey(path: path, modifiedAt: modifiedAt)) {
            let key = HTMLThumbnailRenderer.cacheKey(path: path, modifiedAt: modifiedAt)
            if let hit = HTMLThumbnailRenderer.cached(for: key) {
                image = hit
                return
            }
            guard let html = try? FileLibraryStore.read(path, profileId: profileId) else { return }
            HTMLThumbnailRenderer.shared.render(html: html, cacheKey: key) { rendered in
                image = rendered
            }
        }
    }
}
