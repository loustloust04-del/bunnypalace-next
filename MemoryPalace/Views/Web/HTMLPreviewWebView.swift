import SwiftUI

/// 卡库第二批 B2：原生聊天里卡聊天的网页走和 Page2 同一份策略（内置库 + 已许可才放白名单）。
/// B5/B6 附带：本地模式开着，调用方传 allowed = false（白名单全挡）+ localMode = true（弹层文案）
struct HTMLPreviewCard: Equatable {
    var allowed: Bool
    /// 静态段上报脚本的 nonce：调用方 @State 存住（每次 body 换新会让 payload 变、网页反复重载）
    var nonce: String
    /// 卡已许可但本地模式开着（白名单因此挡着）
    var localMode = false

    static func makeNonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

struct HTMLPreviewWebView: View {
    let content: String
    /// 卡库 ⑦：true = 静态显示（iframe sandbox=""，不跑脚本）；false = 交互（allow-scripts）
    var staticMode: Bool = false
    var backdrop: Color = Theme.mainBg
    /// W2：递增触发重注入 srcdoc（绕过 WebViewHost 的 payload 去重）
    var refreshToken: Int = 0
    var onPageTitle: ((String) -> Void)? = nil
    var onLoadingChanged: ((Bool) -> Void)? = nil
    /// W3：本地模式 OFF 时点链接进 mini browser；nil 或本地模式 ON 时外开系统浏览器
    var onOpenLink: ((URL) -> Void)? = nil
    /// 卡库第二批 B2：非 nil = 卡聊天的网页（html-preview-card 壳 + 子文档 meta CSP + CDN 改写 + 被挡资源上报）
    var card: HTMLPreviewCard? = nil
    /// 被 CSP 挡掉的资源（「违规指令 地址」，只有卡聊天有）
    var onBlocked: ((String) -> Void)? = nil
    /// research-chat-cards §13：本次运行的令牌，非 nil 才给卡片注入 window.mp（只在交互模式）
    var bridgeToken: String? = nil
    /// 卡片请求（壳已附上令牌）+ 回复通道
    var onCardRequest: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)? = nil

    @State private var isReady = false
    @State private var errorMessage: String?
    @State private var artifactErrors: [String] = []

    var body: some View {
        ZStack(alignment: .top) {
            // W1 联网渲染：本地模式关闭 → 放宽子资源 CSP 的 shell（fetch 仍封）；开 → 全封 shell。
            // 开关在 sheet 打开时生效（WebView 创建即定型，切开关重开预览即可）
            WebViewHost(
                htmlResourceName: card != nil ? "html-preview-card" : (LocalMode.isOn ? "html-preview" : "html-preview-online"),
                payload: payload,
                servesCardLibrary: card != nil,
                onMessage: handleMessage
            )

            if !artifactErrors.isEmpty {
                artifactErrorBar
            }

            if !isReady {
                VStack {
                    Spacer()
                    Text(errorMessage ?? "正在加载预览")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(errorMessage == nil ? Theme.textMuted : Theme.branchIndicator)
                        .padding(10)
                        .background(Theme.mainBg.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer()
                }
            }
        }
        .background(backdrop)
        .onChange(of: content) { _, _ in
            artifactErrors = []
        }
        .onChange(of: refreshToken) { _, _ in
            artifactErrors = []
            onLoadingChanged?(true)
        }
    }

    private var payload: [String: Any] {
        var p: [String: Any] = [
            "type": "setContent",
            "content": content,
            "mode": staticMode ? "static" : "interactive",
            "refreshToken": refreshToken,
            "bridgeToken": staticMode ? "" : (bridgeToken ?? "")
        ]
        if let card {
            p["content"] = CardWebLibrary.rewrite(content)    // 只改发给网页的副本，消息原文不动
            p["prelude"] = HTMLEmbedPolicy.nativeCardPrelude(mode: staticMode ? .staticView : .interactive,
                                                             nonce: card.nonce, allowed: card.allowed)
        }
        return p
    }

    private var artifactErrorBar: some View {
        HStack(spacing: 8) {
            Text(artifactErrors.joined(separator: " · "))
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.branchIndicator)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                artifactErrors = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Theme.F.caption, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.mainBg.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.accent)
                .frame(height: 1)
        }
    }

    private func handleMessage(_ message: WebViewBridgeMessage) {
        switch message.type {
        case "ready":
            isReady = true
            errorMessage = nil
        case "error":
            errorMessage = message.message ?? "预览加载失败"
        case "artifactError":
            let text = message.message ?? "脚本错误"
            if !artifactErrors.contains(text), artifactErrors.count < 3 {
                artifactErrors.append(text)
            }
        case "cspBlocked":
            if let text = message.message { onBlocked?(text) }
        case "pageTitle":
            onPageTitle?(message.title ?? "")
        case "pageLoaded":
            onLoadingChanged?(false)
        case "cardRequest":
            guard let onCardRequest, let reply = message.reply else { return }
            onCardRequest(message.raw, reply)
        case "openLink":
            if let onOpenLink, !LocalMode.isOn,
               let href = message.href, let url = URL(string: href),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                onOpenLink(url)
            } else {
                openExternalWebViewLink(message.href)
            }
        default:
            break
        }
    }
}
