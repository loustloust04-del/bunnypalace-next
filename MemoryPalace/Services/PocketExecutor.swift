import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class PocketExecutor: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = PocketExecutor()

    private var webView: WKWebView?

    private func ensureWebView() -> WKWebView {
        if let webView { attachIfNeeded(webView); return webView }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: configuration)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsLinkPreview = false
        wv.customUserAgent = WebUserAgent.platformDefault
        self.webView = wv
        attachIfNeeded(wv)
        return wv
    }

    private func attachIfNeeded(_ wv: WKWebView) {
        guard wv.superview == nil else { return }
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.first?.windows.first else { return }
        window.insertSubview(wv, at: 0)
        #else
        NSApp.windows.first?.contentView?.addSubview(wv, positioned: .below, relativeTo: nil)
        #endif
    }

    func execute(_ cmd: [String: Any]) {
        guard let id = cmd["id"] as? String,
              let action = cmd["action"] as? String else { return }

        let wv = ensureWebView()

        switch action {
        case "ping":
            reply(id: id, ok: true, result: "pong")

        case "goto":
            if let s = cmd["url"] as? String, let url = URL(string: s) {
                wv.load(URLRequest(url: url))
                reply(id: id, ok: true, result: "loading")
            } else {
                reply(id: id, ok: false, error: "bad url")
            }

        case "js":
            if let js = (cmd["js"] as? String) ?? (cmd["code"] as? String) {
                wv.evaluateJavaScript(js) { [weak self] value, error in
                    if let error {
                        self?.reply(id: id, ok: false, error: error.localizedDescription)
                    } else {
                        self?.reply(id: id, ok: true, result: String(describing: value ?? ""))
                    }
                }
            } else {
                reply(id: id, ok: false, error: "no js")
            }

        case "html":
            wv.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] value, _ in
                self?.reply(id: id, ok: true, result: value as? String ?? "")
            }

        case "screenshot":
            let cfg = WKSnapshotConfiguration()
            wv.takeSnapshot(with: cfg) { [weak self] image, error in
                #if os(macOS)
                if let image,
                   let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    self?.reply(id: id, ok: true, result: "data:image/png;base64," + png.base64EncodedString())
                } else {
                    self?.reply(id: id, ok: false, error: error?.localizedDescription ?? "snapshot failed")
                }
                #else
                if let png = image?.pngData() {
                    self?.reply(id: id, ok: true, result: "data:image/png;base64," + png.base64EncodedString())
                } else {
                    self?.reply(id: id, ok: false, error: error?.localizedDescription ?? "snapshot failed")
                }
                #endif
            }

        default:
            reply(id: id, ok: false, error: "unknown action")
        }
    }

    private func reply(id: String, ok: Bool, result: String? = nil, error: String? = nil) {
        var obj: [String: Any] = ["type": "pocket_result", "id": id, "ok": ok]
        if let result { obj["result"] = result }
        if let error { obj["error"] = error }
        CCBridgeWebSocketClient.shared.send(obj) { _ in }
    }

    // MARK: - WKUIDelegate noop（离屏不弹 alert）

    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                             defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }
}
