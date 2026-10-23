import SwiftUI
import WebKit
import SwiftStreamingMarkdown

/// 图表全屏（plan-mermaid §1）：活 WKWebView 显示缓存的 SVG（矢量，双指缩放 / 拖动走 WebView 原生手势），
/// 右上「源码」切到代码视图、「完成」关闭。
struct MermaidFullScreenView: View {
    let code: String
    let svgURL: URL
    /// 图的底色（#RRGGBB，与截图同一主题）
    let background: String

    @Environment(\.dismiss) private var dismiss
    @State private var showingSource = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.mainBg.ignoresSafeArea()
                MermaidSVGWebView(svgURL: svgURL, background: background)
                    .ignoresSafeArea(edges: .bottom)
                    .opacity(showingSource ? 0 : 1)
                    .allowsHitTesting(!showingSource)
                if showingSource {
                    ScrollView([.vertical, .horizontal]) {
                        Text(code)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle(showingSource ? "源码" : "图表")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if showingSource {
                        Button {
                            PlatformClipboard.copyString(code)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("复制源码")
                    }
                    Button(showingSource ? "看图" : "源码") { showingSource.toggle() }
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 680)
        #endif
    }
}

/// 载 mermaid.html 的查看模式（#view，不载 mermaid 脚本），页面就绪后把 SVG 放进去。只放行初次载入。
@MainActor
final class MermaidSVGWebCoordinator: NSObject, WKNavigationDelegate {
    let svgURL: URL
    let background: String
    private var loadedInitial = false

    init(svgURL: URL, background: String) {
        self.svgURL = svgURL
        self.background = background
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #else
        webView.allowsMagnification = true
        #endif
        if let page = MermaidRenderer.pageURL, let url = URL(string: page.absoluteString + "#view") {
            webView.loadFileURL(url, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        return webView
    }

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
        let svg = (try? String(contentsOf: svgURL, encoding: .utf8)) ?? ""
        let background = background
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript("return window.mpShow(svg, bg)",
                                                       arguments: ["svg": svg, "bg": background],
                                                       in: nil, contentWorld: .page)
        }
    }
}

#if os(iOS)
struct MermaidSVGWebView: UIViewRepresentable {
    let svgURL: URL
    let background: String

    func makeCoordinator() -> MermaidSVGWebCoordinator {
        MermaidSVGWebCoordinator(svgURL: svgURL, background: background)
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#else
struct MermaidSVGWebView: NSViewRepresentable {
    let svgURL: URL
    let background: String

    func makeCoordinator() -> MermaidSVGWebCoordinator {
        MermaidSVGWebCoordinator(svgURL: svgURL, background: background)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#endif
