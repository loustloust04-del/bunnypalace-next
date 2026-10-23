#if PERSONAL_APPS
#if DEBUG
import SwiftUI
import WebKit

// MARK: - 路线图网页（docs/plan-dev-subapp-v2.md P1-c-4）
// 4793 回的 HTML 已经注入了 docstate 垫片：页面的 localStorage 是内存版，改动经 `pmDoc` 这个 message handler 送出来，
// 这里原样交给 Store → pm_req POST /api/docstate 落盘。不走 HTMLPreviewWebView（那是 iframe srcdoc 壳，垫片的消息出不来）。

struct PMDocWebView {
    let html: String
    let onMessage: ([String: Any]) -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onMessage: ([String: Any]) -> Void
        var loaded: String?
        init(onMessage: @escaping ([String: Any]) -> Void) { self.onMessage = onMessage }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "pmDoc", let body = message.body as? [String: Any] else { return }
            onMessage(body)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

    fileprivate func make(_ c: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(c, name: "pmDoc")
        config.websiteDataStore = .nonPersistent()   // 状态以 4793 为准，本机不留
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        #endif
        return web
    }

    fileprivate func update(_ web: WKWebView, _ c: Coordinator) {
        c.onMessage = onMessage
        guard c.loaded != html else { return }
        c.loaded = html
        web.loadHTMLString(html, baseURL: nil)
    }

    fileprivate static func teardown(_ web: WKWebView) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "pmDoc")
    }
}

#if os(iOS)
extension PMDocWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { teardown(web) }
}
#else
extension PMDocWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context.coordinator) }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { teardown(web) }
}
#endif
#endif
#endif
