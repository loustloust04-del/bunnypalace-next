import SwiftUI
import WebKit
#if DEBUG
import os.log
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 本地模式（设置页根开关）：网页预览等 Web 功能的联网总闸。
/// ON（默认）= 严格禁网（artifact 预览维持 CSP 封锁，现状）；OFF = 解锁联网预览能力（W1 落地后生效）。
/// AI 对话 API、CC bridge、MCP 连接不归它管。
enum LocalMode {
    static let key = "localModeEnabled"
    static var isOn: Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
    }
}

struct WebViewHost: View {
    let htmlResourceName: String
    var payload: [String: Any] = [:]
    var editorDocument: MarkdownWebEditorReplacement? = nil
    /// 卡库第二批 B2：注册 `mp-card://lib/`（内置 jQuery / lodash / Font Awesome），卡聊天的网页用
    var servesCardLibrary = false
    /// iOS：页面加载完摘掉 WKWebView 键盘上方自带的 ↑ ↓ ✓ 表单条（md 编辑器用自己的浮条）。默认不动
    var hidesKeyboardAccessory = false
    var onMessage: (WebViewBridgeMessage) -> Void = { _ in }

    var body: some View {
        PlatformWebViewHost(
            htmlResourceName: htmlResourceName,
            payload: payload,
            editorDocument: editorDocument,
            servesCardLibrary: servesCardLibrary,
            hidesKeyboardAccessory: hidesKeyboardAccessory,
            onMessage: onMessage
        )
    }
}

struct WebViewBridgeMessage {
    let type: String
    let content: String?
    let href: String?
    let message: String?
    let title: String?
    let target: String?
    let revision: Int?
    let count: Int?
    let index: Int?
    /// 原始 body（网页卡 cardRequest 交给 HTMLCardBridgeSession 自己解析）
    let raw: [String: Any]
    /// 回一条给壳（window.memoryPalaceNative.receive）；coordinator 收消息时填
    var reply: (([String: Any]) -> Void)?

    init?(body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else {
            return nil
        }
        self.raw = dict
        self.type = type
        self.content = dict["content"] as? String
        self.href = dict["href"] as? String
        self.message = dict["message"] as? String
        self.title = dict["title"] as? String
        self.target = dict["target"] as? String
        self.revision = dict["revision"] as? Int
        self.count = dict["count"] as? Int
        self.index = dict["index"] as? Int
    }
}

func openExternalWebViewLink(_ href: String?) {
    guard let href,
          let url = URL(string: href),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto"].contains(scheme) else {
        return
    }

    #if os(macOS)
    guard CodingSessionResume.handoffError == nil else { return }
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

#if os(macOS)
private struct PlatformWebViewHost: NSViewRepresentable {
    let htmlResourceName: String
    let payload: [String: Any]
    let editorDocument: MarkdownWebEditorReplacement?
    let servesCardLibrary: Bool
    let hidesKeyboardAccessory: Bool
    let onMessage: (WebViewBridgeMessage) -> Void

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(onMessage: onMessage)
    }

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.send(document: editorDocument, to: webView)
        context.coordinator.send(payload: payload, to: webView)
    }
}
#else
private struct PlatformWebViewHost: UIViewRepresentable {
    let htmlResourceName: String
    let payload: [String: Any]
    let editorDocument: MarkdownWebEditorReplacement?
    let servesCardLibrary: Bool
    let hidesKeyboardAccessory: Bool
    let onMessage: (WebViewBridgeMessage) -> Void

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(onMessage: onMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.send(document: editorDocument, to: webView)
        context.coordinator.send(payload: payload, to: webView)
    }
}

#if os(iOS)
private final class MarkdownEditorWebView: WKWebView {
    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.contentInset != .zero { scrollView.contentInset = .zero }
        if scrollView.contentOffset != .zero { scrollView.setContentOffset(.zero, animated: false) }
    }
}
#endif
#endif

private extension PlatformWebViewHost {
    func makeWebView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "memoryPalace")
        #if DEBUG
        let probeEnabled = htmlResourceName == "markdown-editor"
            && ProcessInfo.processInfo.environment["MP_EDITOR_PROBE"] == "1"
        if probeEnabled {
            userContentController.addUserScript(WKUserScript(
                source: "window.__mpEditorProbeEnabled = true;",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        #endif

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if servesCardLibrary {
            // 只回 lib/ 白名单（不登记任何 document token）；handler 由 coordinator 持有
            let handler = HTMLEmbedSchemeHandler()
            context.coordinator.cardLibrary = handler
            configuration.setURLSchemeHandler(handler, forURLScheme: HTMLEmbedSchemeHandler.scheme)
        }

        #if os(iOS)
        let webView = htmlResourceName == "markdown-editor"
            ? MarkdownEditorWebView(frame: .zero, configuration: configuration)
            : WKWebView(frame: .zero, configuration: configuration)
        if htmlResourceName == "markdown-editor" {
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        }
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.hidesKeyboardAccessory = hidesKeyboardAccessory
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.disablesSystemEditingGestures = htmlResourceName == "markdown-editor"
        #endif
        #if DEBUG
        if probeEnabled {
            context.coordinator.editorProbe = EditorDebugProbe(webView: webView)
        }
        #endif

        if let url = Bundle.main.url(forResource: htmlResourceName, withExtension: "html", subdirectory: "Web")
            ?? Bundle.main.url(forResource: htmlResourceName, withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            context.coordinator.onMessage(WebViewBridgeMessage(
                body: [
                    "type": "error",
                    "message": "找不到 Web 资源：\(htmlResourceName).html"
                ]
            )!)
        }
        return webView
    }
}

#if DEBUG
private final class EditorDebugProbe {
    private static let log = OSLog(subsystem: "com.susu.MemoryPalace.editor-probe", category: "viewport-history")
    private weak var webView: WKWebView?
    private let instance = UUID().uuidString
    private var observations: [NSKeyValueObservation] = []
    #if os(iOS)
    private var keyboardObservers: [NSObjectProtocol] = []
    #endif

    init(webView: WKWebView) {
        self.webView = webView
        observations.append(webView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.record(event: "native.webViewBounds")
        })
        #if os(iOS)
        let scrollView = webView.scrollView
        observations.append(scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.record(event: "native.contentOffset")
        })
        observations.append(scrollView.observe(\.contentInset, options: [.new]) { [weak self] _, _ in
            self?.record(event: "native.contentInset")
        })
        observations.append(scrollView.observe(\.adjustedContentInset, options: [.new]) { [weak self] _, _ in
            self?.record(event: "native.adjustedContentInset")
        })
        observations.append(scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.record(event: "native.scrollViewBounds")
        })
        for name in [
            UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification
        ] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.record(event: "native.\(note.name.rawValue)")
            })
        }
        #endif
        record(event: "native.start")
    }

    deinit {
        #if os(iOS)
        for observer in keyboardObservers { NotificationCenter.default.removeObserver(observer) }
        #endif
    }

    func record(event: String, javaScript: [String: Any]? = nil) {
        guard let webView else { return }
        let frame = webView.frame
        var sample: [String: Any] = [
            "event": event,
            "instance": instance,
            "nativeTimeMs": Date().timeIntervalSince1970 * 1000,
            "nativeUptimeMs": ProcessInfo.processInfo.systemUptime * 1000,
            "webViewFrame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        ]
        #if os(iOS)
        let scrollView = webView.scrollView
        let inset = scrollView.contentInset
        let adjusted = scrollView.adjustedContentInset
        sample["contentOffset"] = ["x": scrollView.contentOffset.x, "y": scrollView.contentOffset.y]
        sample["contentInset"] = ["top": inset.top, "left": inset.left, "bottom": inset.bottom, "right": inset.right]
        sample["adjustedContentInset"] = ["top": adjusted.top, "left": adjusted.left, "bottom": adjusted.bottom, "right": adjusted.right]
        sample["scrollViewBounds"] = ["width": scrollView.bounds.width, "height": scrollView.bounds.height]
        #endif
        if let javaScript { sample["js"] = javaScript }
        guard let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        os_log("%{public}@", log: Self.log, type: .info, json)
    }
}
#endif

private final class WebViewCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onMessage: (WebViewBridgeMessage) -> Void
    weak var webView: WKWebView?
    var cardLibrary: HTMLEmbedSchemeHandler?
    var hidesKeyboardAccessory = false
    #if os(iOS)
    var disablesSystemEditingGestures = false
    #endif
    #if DEBUG
    var editorProbe: EditorDebugProbe?
    #endif
    private var latestPayloadJSON: String?
    private var pendingPayloadJSON: String?
    private var latestDocumentRevision: Int?
    private var pendingDocumentJSON: String?
    private var isReady = false

    init(onMessage: @escaping (WebViewBridgeMessage) -> Void) {
        self.onMessage = onMessage
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // 卡库 ⑦：handler 对所有 frame 可见，预览壳里的 iframe 能直接 postMessage 到这里——只认主 frame（壳自己）
        guard message.name == "memoryPalace",
              message.frameInfo.isMainFrame,
              var bridgeMessage = WebViewBridgeMessage(body: message.body) else {
            return
        }
        #if DEBUG
        if bridgeMessage.type == "editorProbe" {
            editorProbe?.record(event: "javascript", javaScript: bridgeMessage.raw)
            return
        }
        #endif
        bridgeMessage.reply = { [weak self] payload in
            if self == nil { cardBridgeLog.info("reply dropped: coordinator gone") }
            self?.evaluate(payload)
        }

        if bridgeMessage.type == "ready" {
            isReady = true
            if let pendingDocumentJSON {
                self.pendingDocumentJSON = nil
                send(json: pendingDocumentJSON, to: webView)
            }
            if let pendingPayloadJSON {
                self.pendingPayloadJSON = nil
                send(json: pendingPayloadJSON, to: webView)
            }
        }

        onMessage(bridgeMessage)
    }

    func send(document: MarkdownWebEditorReplacement?, to webView: WKWebView) {
        guard let document, document.nativeRevision != latestDocumentRevision else { return }
        let payload: [String: Any] = [
            "type": "replaceDocument",
            "content": document.content,
            "nativeRevision": document.nativeRevision
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        latestDocumentRevision = document.nativeRevision
        if isReady {
            send(json: json, to: webView)
        } else {
            pendingDocumentJSON = json
        }
    }

    func send(payload: [String: Any], to webView: WKWebView) {
        // 键排序：同一份内容每次排出来的 JSON 要一样，否则 SwiftUI 每次重绘都被当成新内容、网页整页重载
        // （网页卡弹确认框时重绘，页面重载把等回复的 Promise 丢了——research-chat-cards §13 模拟器实测）
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8),
              json != latestPayloadJSON else {
            return
        }

        latestPayloadJSON = json
        if isReady {
            send(json: json, to: webView)
        } else {
            pendingPayloadJSON = json
        }
    }

    /// 单发一条（不走 payload 去重、不碰待发配置或正文操作）
    private func evaluate(_ payload: [String: Any]) {
        if !isReady || webView == nil { cardBridgeLog.info("evaluate dropped ready=\(self.isReady) webView=\(self.webView != nil)") }
        guard isReady, let webView, JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.memoryPalaceNative && window.memoryPalaceNative.receive(\(json));") { _, error in
            if let error { cardBridgeLog.info("evaluate failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func send(json: String, to webView: WKWebView?) {
        guard let webView else { return }
        webView.evaluateJavaScript("window.memoryPalaceNative && window.memoryPalaceNative.receive(\(json));") { [weak self] _, error in
            guard let error else { return }
            self?.onMessage(WebViewBridgeMessage(
                body: [
                    "type": "error",
                    "message": "WebView 通信失败：\(error.localizedDescription)"
                ]
            )!)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if isAllowedLocalNavigation(url) {
            decisionHandler(.allow)
            return
        }

        // 只有用户真点了链接才外开系统浏览器；meta refresh / 脚本驱动跳转一律静默拦截
        if navigationAction.navigationType == .linkActivated {
            onMessage(WebViewBridgeMessage(
                body: [
                    "type": "openLink",
                    "href": url.absoluteString
                ]
            )!)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if os(iOS)
        // WKContentView 页面起来才在（Page2ChatWebView 同款时机）
        if hidesKeyboardAccessory { webView.disableKeyboardInputAccessory() }
        if disablesSystemEditingGestures { webView.disableSystemEditingGestures() }
        #endif
    }

    private func isAllowedLocalNavigation(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        guard let scheme = url.scheme?.lowercased() else { return true }
        return ["about", "data", "blob"].contains(scheme)
    }
}
