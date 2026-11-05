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

    /// reply：调用方给的结果发送口（A1 R2 R1-5）——绑定命令来源的那条连接，所有结果（含 JS / 截图的异步回调）都只经它回；
    /// 来源连接没了它自己只记诊断不发，这里不碰「当前连接」
    func execute(_ cmd: [String: Any], reply send: @escaping ([String: Any]) -> Void) {
        guard let id = cmd["id"] as? String,
              let action = cmd["action"] as? String else { return }
        let reply = { (ok: Bool, result: String?, error: String?) in send(Self.resultFrame(id: id, ok: ok, result: result, error: error)) }

        let wv = ensureWebView()

        switch action {
        case "ping":
            reply(true, "pong", nil)

        case "goto":
            if let s = cmd["url"] as? String, let url = URL(string: s) {
                wv.load(URLRequest(url: url))
                reply(true, "loading", nil)
            } else {
                reply(false, nil, "bad url")
            }

        case "js":
            if let js = (cmd["js"] as? String) ?? (cmd["code"] as? String) {
                wv.evaluateJavaScript(js) { value, error in
                    if let error {
                        reply(false, nil, error.localizedDescription)
                    } else {
                        reply(true, String(describing: value ?? ""), nil)
                    }
                }
            } else {
                reply(false, nil, "no js")
            }

        case "html":
            wv.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                reply(true, value as? String ?? "", nil)
            }

        case "screenshot":
            let cfg = WKSnapshotConfiguration()
            wv.takeSnapshot(with: cfg) { image, error in
                #if os(macOS)
                if let image,
                   let tiffData = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    reply(true, "data:image/png;base64," + png.base64EncodedString(), nil)
                } else {
                    reply(false, nil, error?.localizedDescription ?? "snapshot failed")
                }
                #else
                if let png = image?.pngData() {
                    reply(true, "data:image/png;base64," + png.base64EncodedString(), nil)
                } else {
                    reply(false, nil, error?.localizedDescription ?? "snapshot failed")
                }
                #endif
            }

        default:
            reply(false, nil, "unknown action")
        }
    }

    nonisolated private static func resultFrame(id: String, ok: Bool, result: String?, error: String?) -> [String: Any] {
        var obj: [String: Any] = ["type": "pocket_result", "id": id, "ok": ok]
        if let result { obj["result"] = result }
        if let error { obj["error"] = error }
        return obj
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
