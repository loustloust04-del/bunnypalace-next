import SwiftUI
import WebKit

/// #059 ②：下载页里的 claude.ai 登录页，显示 `ClaudeExportDownloader` 自己的 web view（登录只在它的内存会话里）
struct ClaudeLoginWebView {
    let webView: WKWebView
}

#if os(macOS)
extension ClaudeLoginWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension ClaudeLoginWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
