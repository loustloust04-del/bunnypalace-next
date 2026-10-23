import Foundation
import Observation
import WebKit

// 卡库 ⑦ 安全 HTML 内嵌（plan-card-library §5）：
// 消息里的 HTML 段 = 聊天宿主里的一个 iframe，文档走受控自定义 scheme `mp-card://document/<token>`
// （WKURLSchemeHandler 只回登记过的文档，响应自带独立 CSP），不用 srcdoc / Blob（会继承父 CSP 或绕开隔离）。
// iframe 静态 `sandbox=""`、交互 `sandbox="allow-scripts"`，永不 allow-same-origin；
// 子文档没有生成 / 变量 / 改消息 / 文件 / 密钥能力，和父页只有 ready / error / 外链请求三种窄消息。
// 第二批 B3（plan-card-library-batch2）：交互实例另加 call / result / event / snapshotUpdate（酒馆助手 API 子集，
// 原生校验链在 CardScriptGate）；两种模式都有 resize（自动高度）/ cspReport（被挡资源、用到的不支持 API）。
// 静态模式只放一段带 nonce 的量高度脚本，正文里的脚本仍不执行。

enum HTMLEmbedMode: String {
    case staticView = "static"
    case interactive
}

/// 一个 iframe 属于谁：楼层 / 对话 / 消息 / 段。token 只在这个身份下有效
struct HTMLEmbedIdentity: Hashable {
    let profileId: String
    let conversationId: String
    let nodeId: String
    let segmentId: String
    var segmentKey: String { "\(nodeId)|\(segmentId)" }
}

/// 第二批 B2 联网档位：非卡网页维持现状全断网；卡聊天多一个内置库（mp-card://lib/，本地、不联网），
/// 卡已许可再放 font / style / img 白名单（CardWebWhitelist）。script / connect / 表单 / 子 frame / 导航任何档都不放
enum HTMLEmbedNetwork: Equatable {
    case offline
    case card(allowed: Bool)
    /// B5/B6 附带：本地模式开着的卡聊天——只留内置库，白名单全挡（已许可也一样）
    case cardLocal

    var isCard: Bool { self != .offline }

    /// 「挡掉了 N 个」弹层多出的一句（已许可且联网 = 没有）
    var blockedNote: String {
        switch self {
        case .offline, .card(allowed: true): ""
        case .card(allowed: false): CardBlockedResource.notAllowedNote
        case .cardLocal: CardBlockedResource.localModeNote
        }
    }
}

enum HTMLEmbedPolicy {
    /// 单段上限；超了不挂 iframe，保高度提示
    static let maxBytes = 2_000_000

    /// 子文档独立 CSP：默认全拒（网络 / connect / 表单 / 子 frame / worker / base），
    /// 静态 script-src 'none'（带 nonce 时只放那一段量高度脚本）；交互只放子文档自己的内联脚本。
    /// B2：卡聊天 style / font（交互另加 script）多 `mp-card:`（CSP 管不到路径，靠 handler 只回 lib/ 白名单兜住）；
    /// 已许可的卡 style / img / font 再加白名单域名。静态段 script-src 永远只有 nonce
    static func contentSecurityPolicy(_ mode: HTMLEmbedMode, nonce: String? = nil, network: HTMLEmbedNetwork = .offline) -> String {
        let lib = network.isCard ? " mp-card:" : ""
        func hosts(_ list: [String]) -> String { network == .card(allowed: true) ? " " + CardWebWhitelist.sources(list) : "" }
        let script = mode == .interactive ? "'unsafe-inline'\(lib)" : (nonce.map { "'nonce-\($0)'" } ?? "'none'")
        return "default-src 'none'; script-src \(script); style-src 'unsafe-inline'\(lib)\(hosts(CardWebWhitelist.style)); "
            + "img-src data:\(hosts(CardWebWhitelist.image)); font-src data:\(lib)\(hosts(CardWebWhitelist.font)); media-src data:; "
            + "connect-src 'none'; form-action 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'"
    }

    /// 原生预览壳 html-preview-card.html 自己的 CSP（srcdoc 继承，是卡网页的上限；每段再由 nativeCardPrelude 的 meta 收窄）。
    /// 改这里要同步那份 html（WebKit harness / 测试比对）
    static let nativeCardShellPolicy = "default-src 'none'; script-src 'unsafe-inline' mp-card:; "
        + "style-src 'unsafe-inline' mp-card: \(CardWebWhitelist.sources(CardWebWhitelist.style)); "
        + "img-src data: \(CardWebWhitelist.sources(CardWebWhitelist.image)); "
        + "font-src data: mp-card: \(CardWebWhitelist.sources(CardWebWhitelist.font)); media-src data:; "
        + "connect-src 'none'; frame-src about:; form-action 'none'"

    /// 原生聊天里卡聊天的网页：塞在 srcdoc 最前面的 meta CSP（与 Page2 子文档同一份）+ 被挡资源上报脚本
    /// （带 nonce，静态段只有它能跑）。上报经壳转成 `cspBlocked` 给原生
    static func nativeCardPrelude(mode: HTMLEmbedMode, nonce: String, allowed: Bool) -> String {
        let csp = contentSecurityPolicy(mode, nonce: mode == .staticView ? nonce : nil, network: .card(allowed: allowed))
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">\n"
            + "<meta name=\"referrer\" content=\"no-referrer\">\n"
            + "<script nonce=\"\(nonce)\">(function(){var n=0;document.addEventListener(\"securitypolicyviolation\",function(e){"
            + "if(++n>50)return;try{parent.postMessage({__mpArtifact:true,type:\"cspBlocked\",text:(String(e.violatedDirective||\"\")"
            + "+\" \"+String(e.blockedURI||\"\")).slice(0,300)},\"*\")}catch(_){}});})();</script>\n"
    }

    /// 发给 iframe 的完整文档：响应头 CSP 之外再在文档最前面放一份 meta CSP（两份取交集，内容里再写 meta 只会更严）；
    /// 交互模式附带窄通道 + 酒馆助手垫片（消息带 token，父页按来源 window + token 校验）；静态模式有 nonce 时只带量高度脚本。
    /// B2：卡聊天把常见 CDN 的库地址改写成内置库（只改这份拼出来的文档，消息原文不动）
    static func document(content: String, mode: HTMLEmbedMode, token: String, nonce: String? = nil, bridge: HTMLEmbedBridge? = nil,
                         network: HTMLEmbedNetwork = .offline) -> String {
        let content = network.isCard ? CardWebLibrary.rewrite(content) : content
        var prelude = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy(mode, nonce: nonce, network: network))\">\n"
            + "<meta name=\"referrer\" content=\"no-referrer\">\n"
            + "<style>:where(body) { background: #ffffff; }</style>\n"
        if let css = bridge?.avatarCSS { prelude += "<style>\(css)</style>\n" }
        if network.isCard { prelude += CardWebLibrary.preload(scripts: mode == .interactive) }
        switch mode {
        case .interactive:
            let json = CardScriptShim.bridgeJSON(segmentId: bridge?.segmentId ?? "h0", snapshot: bridge?.snapshot)
            prelude += "<script>\n" + CardScriptShim.interactiveScript(token: token, bridgeJSON: json) + "\n</script>\n"
        case .staticView:
            if let nonce { prelude += "<script nonce=\"\(nonce)\">\n" + CardScriptShim.staticScript(token: token) + "\n</script>\n" }
        }
        if let m = content.range(of: #"^\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(content[..<m.upperBound]) + "\n" + prelude + String(content[m.upperBound...])
        }
        return prelude + content
    }
}

/// 子文档 prelude 里的原生数据：交互模式的快照（CardScriptSnapshot.build 输出）、头像类名样式
struct HTMLEmbedBridge: Equatable {
    var segmentId: String = "h0"
    var snapshot: String?
    var avatarCSS: String?
}

/// 第二批 B5：triggerSlash 落到宿主的那几样（Page2 Coordinator 接 VM / 卡库 / 半屏确认框；测试 / harness 换成假的）
struct CardSlashHost {
    /// 当前楼层绑定的卡；nil = 非卡聊天
    var card: () -> CardSlashGate.Card?
    /// `{{char}}` / `{{user}}`（有效身份）
    var names: () -> (char: String, user: String)
    /// 全应用有没有正在生成的回复（同一时刻只一个生成）
    var isGenerating: () -> Bool
    /// 第一次：弹半屏确认框；nil = 没选就关了
    var confirm: (CardSendConfirmation, @escaping (CardSendChoice?) -> Void) -> Void
    /// 写卡的 sendConsent（卡 id）
    var setConsent: (String, CardSendConsent) -> Void
    /// 执行一步；失败返回原因
    var perform: (CardSlashStep) -> CardScriptRejection?
}

struct HTMLEmbedEntry {
    let identity: HTMLEmbedIdentity
    let mode: HTMLEmbedMode
    let content: String
    var document: String
    /// 静态模式量高度脚本的 nonce（交互模式 nil）
    var nonce: String? = nil
    var network: HTMLEmbedNetwork = .offline
}

/// token → 登记文档。scheme handler 只回这里有的；iframe 销毁 / 离屏 / 切对话 / 后台 / 撤权都从这里注销
@MainActor
final class HTMLEmbedRegistry {
    private(set) var entries: [String: HTMLEmbedEntry] = [:]
    var count: Int { entries.count }

    func register(_ identity: HTMLEmbedIdentity, content: String, mode: HTMLEmbedMode, bridge: HTMLEmbedBridge? = nil,
                  network: HTMLEmbedNetwork = .offline) -> String {
        let token = UUID().uuidString.lowercased()
        let nonce = mode == .staticView ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : nil
        entries[token] = HTMLEmbedEntry(identity: identity, mode: mode, content: content,
                                        document: HTMLEmbedPolicy.document(content: content, mode: mode, token: token,
                                                                           nonce: nonce, bridge: bridge, network: network),
                                        nonce: nonce, network: network)
        return token
    }

    /// 快照变了：重拼文档（reloadIframe 拿到的是新快照）
    func refresh(_ token: String, bridge: HTMLEmbedBridge?) {
        guard var e = entries[token] else { return }
        e.document = HTMLEmbedPolicy.document(content: e.content, mode: e.mode, token: token, nonce: e.nonce, bridge: bridge,
                                              network: e.network)
        entries[token] = e
    }

    func entry(_ token: String) -> HTMLEmbedEntry? { entries[token] }

    /// 只注销身份对得上的（web 发来的 release 不能注销别的消息的 token）
    @discardableResult
    func unregister(_ token: String, nodeId: String? = nil, segmentId: String? = nil) -> HTMLEmbedEntry? {
        guard let e = entries[token] else { return nil }
        if let nodeId, e.identity.nodeId != nodeId { return nil }
        if let segmentId, e.identity.segmentId != segmentId { return nil }
        entries[token] = nil
        return e
    }

    func removeAll(where shouldRemove: (HTMLEmbedEntry) -> Bool = { _ in true }) {
        entries = entries.filter { !shouldRemove($0.value) }
    }
}

/// `mp-card://document/<token>`：只回登记过的文档，响应带该模式的 CSP；
/// B2：`mp-card://lib/<白名单路径>`：只回内置库那几个文件（CardWebLibrary.files）；其余一律失败
@MainActor
final class HTMLEmbedSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "mp-card"
    let registry = HTMLEmbedRegistry()
    /// 内置库文件的读法（生产读 bundle；harness / 测试换成读源码目录）
    var libraryData: (CardWebLibrary.File) -> Data? = CardWebLibrary.bundleData
    private var libraryCache: [String: Data] = [:]

    nonisolated static func url(token: String) -> String { "\(scheme)://document/\(token)" }

    nonisolated static func token(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == scheme, url.host == "document" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1, url.query == nil else { return nil }
        return String(parts[0])
    }

    /// lib/ 白名单文件的响应头：带 content-type；字体是 CORS 请求（子文档 opaque origin），要 ACAO *
    nonisolated static func libraryHeaders(_ file: CardWebLibrary.File, length: Int) -> [String: String] {
        ["Content-Type": file.contentType, "Content-Length": "\(length)", "Access-Control-Allow-Origin": "*",
         "X-Content-Type-Options": "nosniff", "Cache-Control": "max-age=86400"]
    }

    func libraryResponse(_ url: URL?) -> (headers: [String: String], data: Data)? {
        guard let file = CardWebLibrary.file(for: url) else { return nil }
        guard let data = libraryCache[file.resource] ?? libraryData(file) else { return nil }
        libraryCache[file.resource] = data
        return (Self.libraryHeaders(file, length: data.count), data)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        if task.request.url?.host == "lib" {
            guard let url = task.request.url, let lib = libraryResponse(url),
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: lib.headers) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(response)
            task.didReceive(lib.data)
            task.didFinish()
            return
        }
        guard let url = task.request.url, let token = Self.token(from: url), let entry = registry.entry(token),
              let data = entry.document.data(using: .utf8) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(data.count)",
            "Content-Security-Policy": HTMLEmbedPolicy.contentSecurityPolicy(entry.mode, nonce: entry.nonce, network: entry.network),
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "Cache-Control": "no-store",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }
        // 同步回完：start 里一次做完就不存在 stop 之后再回调的竞态
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// 原生主桥守门（审查 #4）：WK handler 对页面里所有 frame 可见，子 frame 能直接
/// `window.webkit.messageHandlers.<name>.postMessage`；只认主 frame + 受控主文档
enum HTMLEmbedBridgeGate {
    static func acceptsHostMessage(isMainFrame: Bool, frameURL: URL?, controlledDocument: URL) -> Bool {
        guard isMainFrame, let url = frameURL, url.isFileURL else { return false }
        return url.resolvingSymlinksInPath().path == controlledDocument.resolvingSymlinksInPath().path
    }

    /// 聊天宿主导航白名单：主 frame 只许受控主文档；子 frame 只许登记过的 mp-card 文档
    static func allowsNavigation(to url: URL?, isMainFrame: Bool, controlledDocument: URL,
                                 isRegistered: (String) -> Bool) -> Bool {
        guard let url else { return false }
        if isMainFrame {
            return acceptsHostMessage(isMainFrame: true, frameURL: url, controlledDocument: controlledDocument)
        }
        guard let token = HTMLEmbedSchemeHandler.token(from: url) else { return false }
        return isRegistered(token)
    }

    /// 用户点的外链：只放 http(s)
    static func externalLink(_ href: String?) -> URL? {
        guard let href, href.count <= 2048, let url = URL(string: href),
              let s = url.scheme?.lowercased(), s == "http" || s == "https", url.host?.isEmpty == false else { return nil }
        return url
    }
}

enum HTMLEmbedPermission {
    /// 当前楼层绑定的卡（与 RegexPipeline 同口径）；nil = 非卡聊天
    static func boundCard(profileId: String?, cards: [CharacterCard]) -> CharacterCard? {
        guard let profileId else { return nil }
        return cards.first { $0.linkedProfileId == profileId && $0.bindingState == .active }
    }

    /// B2：卡聊天走卡的联网档位（已许可才放白名单）；非卡 = 现状全断网。
    /// 本地模式开着：已许可的卡也只留内置库（白名单全挡）
    static func network(boundCard: CharacterCard?, localMode: Bool = false) -> HTMLEmbedNetwork {
        guard let card = boundCard else { return .offline }
        guard card.extensionConsent == .allowed else { return .card(allowed: false) }
        return localMode ? .cardLocal : .card(allowed: true)
    }

    /// nil = 可以运行交互；否则是给用户看的原因。
    /// 非卡聊天（AI 自己写的 HTML）照旧点「运行」就跑，不受总开关管；
    /// 卡聊天要总开关「允许卡里的网页运行脚本」开 + 这张卡已启用
    static func runDenial(allowWebScripts: Bool, boundCard: CharacterCard?) -> String? {
        guard let card = boundCard else { return nil }
        guard allowWebScripts else { return "网页脚本没开：卡库 → 设置 → 允许卡里的网页运行脚本" }
        if card.extensionConsent != .allowed {
            return "「\(card.name)」的扩展还没启用"
        }
        return nil
    }
}

/// 每个宿主最多 N 个可见静态实例（原生聊天用；Page2 在 runtime 里自己数）。超额的保高度占位，有空位再上
@Observable @MainActor
final class HTMLCardStaticSlots {
    static let native = HTMLCardStaticSlots(limit: 2)
    let limit: Int
    private(set) var holders: [String] = []

    init(limit: Int) { self.limit = limit }

    func acquire(_ key: String) -> Bool {
        if holders.contains(key) { return true }
        guard holders.count < limit else { return false }
        holders.append(key)
        return true
    }

    func release(_ key: String) { holders.removeAll { $0 == key } }
}

/// web → 原生的 HTML 段消息（chat-runtime.js 发，mpChat 桥协议 v1 的新增 case）
enum HTMLEmbedMessage: Equatable {
    case mount(nodeId: String, segmentId: String)
    case release(nodeId: String, segmentId: String, token: String)
    case run(nodeId: String, segmentId: String)
    case stop(nodeId: String, segmentId: String)
    /// 子文档经父页转来的窄消息：kind ∈ ready / error / openLink；text = 错误文字或链接
    case child(token: String, nodeId: String, segmentId: String, kind: String, text: String)
    /// 第二批 B3：交互实例调助手 API（args = JSON 文本，原生再按 schema 解析）
    case call(token: String, nodeId: String, segmentId: String, callId: String, method: String, args: String)
    /// 子页上报内容高度（原生夹到 120–2000pt 再回给父页）
    case resize(token: String, nodeId: String, segmentId: String, height: Double)
    /// 被挡的资源（kind = csp）/ 用到了还不支持的助手 API（kind = unsupported）：先只记下来、计数
    case cspReport(token: String, nodeId: String, segmentId: String, kind: String, text: String)

    init?(body: [String: Any]) {
        guard let type = body["type"] as? String else { return nil }
        func s(_ k: String, max: Int = 128) -> String? {
            guard let v = body[k] as? String, !v.isEmpty, v.count <= max else { return nil }
            return v
        }
        guard let nodeId = s("nodeId"), let segmentId = s("segmentId", max: 16) else { return nil }
        switch type {
        case "htmlMount": self = .mount(nodeId: nodeId, segmentId: segmentId)
        case "htmlRun": self = .run(nodeId: nodeId, segmentId: segmentId)
        case "htmlStop": self = .stop(nodeId: nodeId, segmentId: segmentId)
        case "htmlRelease":
            guard let token = s("token") else { return nil }
            self = .release(nodeId: nodeId, segmentId: segmentId, token: token)
        case "htmlChild":
            guard let token = s("token"), let kind = s("kind", max: 16),
                  ["ready", "error", "openLink"].contains(kind) else { return nil }
            let text = (body["text"] as? String).map { String($0.prefix(2048)) } ?? ""
            self = .child(token: token, nodeId: nodeId, segmentId: segmentId, kind: kind, text: text)
        case "htmlCall":
            guard let token = s("token"), let callId = s("callId", max: 64), let method = s("method", max: 64),
                  let args = body["args"] as? String else { return nil }
            self = .call(token: token, nodeId: nodeId, segmentId: segmentId, callId: callId, method: method, args: args)
        case "htmlResize":
            guard let token = s("token"), let h = (body["height"] as? NSNumber)?.doubleValue, h.isFinite else { return nil }
            self = .resize(token: token, nodeId: nodeId, segmentId: segmentId, height: h)
        case "htmlCSP":
            guard let token = s("token"), let kind = s("kind", max: 16), ["csp", "unsupported"].contains(kind) else { return nil }
            let text = (body["text"] as? String).map { String($0.prefix(300)) } ?? ""
            self = .cspReport(token: token, nodeId: nodeId, segmentId: segmentId, kind: kind, text: text)
        default: return nil
        }
    }
}

/// 一个聊天宿主（Page2 WKWebView）里的 HTML 段调度：token 发放 / 注销、唯一交互实例、撤权 / 后台释放。
/// 与平台无关，Page2 的 Coordinator 持有它，只负责把消息转进来、把 JS 交出去。
@MainActor
final class HTMLEmbedHost {
    let scheme = HTMLEmbedSchemeHandler()
    var registry: HTMLEmbedRegistry { scheme.registry }
    /// 执行 JS（Coordinator 接到 webView.evaluateJavaScript）
    var eval: (String) -> Void = { _ in }
    /// 用户点外链：宿主确认后再开（http(s) 已校验）
    var confirmOpenLink: (URL) -> Void = { _ in }
    var log: (String) -> Void = { _ in }
    /// 全应用唯一交互实例（HTMLCardRunCoordinator.shared.runningKey）的读写
    var activeKey: () -> String? = { nil }
    var setActiveKey: (String?) -> Void = { _ in }
    /// nil = 可以运行交互；变成非 nil 时正在跑的交互实例立刻销毁（关总开关 / 撤卡许可）
    var runDenial: String? = HTMLEmbedPermission.runDenial(allowWebScripts: false, boundCard: nil) {
        didSet { if runDenial != nil { stopInteractive() } }
    }
    /// B2 联网档位（卡聊天 / 卡许可变了）：已挂的 iframe 全按新 CSP 重挂，之前记的「挡掉了 N 个」作废重数
    var network: HTMLEmbedNetwork = .offline {
        didSet {
            guard network != oldValue else { return }
            for key in Array(blockedContent.keys) { clearBlocked(key, inWeb: true) }
            suspend()
            resume()
        }
    }

    private(set) var interactive: (key: String, token: String, identity: HTMLEmbedIdentity, origin: CardSlashGate.Origin)?

    // MARK: 第二批 B5 / B6

    /// B5：替你发消息的宿主一侧（Page2 接 VM / 卡库 / 确认框）；nil = 这个宿主不支持，triggerSlash 一律拒
    var slash: CardSlashHost?
    private var slashThrottle = CardSlashThrottle()
    /// 确认框开着：别的发消息调用先拒
    private(set) var awaitingSendConfirm = false
    /// B6：已许可的卡 + 总开关开（宿主按绑定卡 / runDenial 设）
    var autoRunEnabled = false
    private var autoRunState = CardAutoRun.State()
    /// 当前渲染窗口里的 HTML 段：段键 → (身份, 内容)
    private var sources: [String: (identity: HTMLEmbedIdentity, content: String)] = [:]

    // MARK: 第二批 B3 / B4：窄通道

    /// 子文档 prelude 数据（交互：快照 + 头像；静态：头像）
    var bridge: (HTMLEmbedIdentity, HTMLEmbedMode) -> HTMLEmbedBridge? = { _, _ in nil }
    /// 宿主眼下的楼层 / 对话（校验链第 3 步：身份与发起时一致）
    var currentScope: () -> (profileId: String, conversationId: String) = { ("", "") }
    /// 执行已过闸的请求；成功返回「要不要重渲染」（setChatMessages 的 refresh ≠ none）
    var execute: (CardScriptRequest, HTMLEmbedIdentity) -> Result<Bool, CardScriptRejection> = { _, _ in .failure(.methodNotAllowed("call")) }
    /// 写成功且要重渲染：宿主推一次更新（Page2：pushUpdate）
    var refreshAfterWrite: () -> Void = {}
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    var limiter = CardScriptRateLimiter()
    /// 运行时报告存哪（Page2 接 `.shared`，角色页读；测试 / harness 用自己的）
    var reportStore = HTMLEmbedRuntimeStore()
    /// 运行时报告（楼层 ID → 被挡资源 / 用到的不支持 API）：B2 卡片角落「挡掉了 N 个」、B1 角色页「用到了还不支持的」
    var runtimeReports: [String: HTMLEmbedRuntimeReport] { reportStore.reports }
    /// 段键 → 记被挡资源时那段的身份 + 内容 hash（内容变了 / 段没了 / 联网档位变了就清掉那段的记录）
    private var blockedContent: [String: (identity: HTMLEmbedIdentity, hash: Int)] = [:]

    /// 全量渲染（切对话 / 切分支 / 新消息）：整张表换掉，不在表里或内容变了的 token 注销
    func replaceSources(_ list: [(HTMLEmbedIdentity, String)]) {
        sources = Dictionary(list.map { ($0.0.segmentKey, (identity: $0.0, content: $0.1)) }, uniquingKeysWith: { a, _ in a })
        sweep()
    }

    /// 单条内容变化（patch）：只换这条消息的段
    func updateSources(nodeId: String, _ list: [(HTMLEmbedIdentity, String)]) {
        sources = sources.filter { $0.value.identity.nodeId != nodeId }
        for (id, content) in list { sources[id.segmentKey] = (id, content) }
        sweep()
    }

    private func sweep() {
        registry.removeAll { e in
            guard let src = sources[e.identity.segmentKey] else { return true }
            return src.identity != e.identity || src.content != e.content
        }
        if let i = interactive, registry.entry(i.token) == nil { dropInteractive(detachInWeb: false) }
        for (key, seen) in blockedContent where sources[key].map({ $0.content.hashValue != seen.hash }) ?? true {
            clearBlocked(key, inWeb: false)     // 段换了内容 web 那边整块重建，角标跟着没
        }
    }

    private func clearBlocked(_ key: String, inWeb: Bool) {
        guard let seen = blockedContent.removeValue(forKey: key) else { return }
        reportStore.reports[seen.identity.profileId]?.clearBlocked(segment: key)
        if inWeb {
            eval("window.mp && mp.htmlBlocked && mp.htmlBlocked(\(Self.js(seen.identity.nodeId)), \(Self.js(seen.identity.segmentId)), {\"count\":0})")
        }
    }

    func handle(_ msg: HTMLEmbedMessage) {
        switch msg {
        case .mount(let nodeId, let segmentId):
            guard let src = sources["\(nodeId)|\(segmentId)"] else { return }
            if interactive?.identity == src.identity { return }
            guard src.content.utf8.count <= HTMLEmbedPolicy.maxBytes else {
                notice(nodeId, segmentId, "网页太大，没有显示", blocked: true)
                return
            }
            let token = registry.register(src.identity, content: src.content, mode: .staticView,
                                          bridge: bridge(src.identity, .staticView), network: network)
            attach(src.identity, token: token, mode: .staticView)

        case .release(let nodeId, let segmentId, let token):
            registry.unregister(token, nodeId: nodeId, segmentId: segmentId)
            if interactive?.token == token { dropInteractive(detachInWeb: false) }

        case .run(let nodeId, let segmentId):
            run(nodeId: nodeId, segmentId: segmentId, origin: .user)

        case .stop(let nodeId, let segmentId):
            guard let i = interactive, i.identity.nodeId == nodeId, i.identity.segmentId == segmentId else { return }
            stopInteractive()

        case .child(let token, let nodeId, let segmentId, let kind, let text):
            guard let e = registry.entry(token), e.identity.nodeId == nodeId, e.identity.segmentId == segmentId,
                  e.mode == .interactive else {
                log("[HTMLEMBED] 丢弃来路不明的子文档消息 \(kind)")
                return
            }
            switch kind {
            case "openLink":
                guard let url = HTMLEmbedBridgeGate.externalLink(text) else { return }
                confirmOpenLink(url)
            case "error":
                log("[HTMLEMBED] 子文档错误 \(e.identity.segmentKey): \(text.prefix(200))")
            default:
                log("[HTMLEMBED] 子文档就绪 \(e.identity.segmentKey)")
            }

        case .call(let token, let nodeId, let segmentId, let callId, let method, let args):
            handleCall(token: token, nodeId: nodeId, segmentId: segmentId, callId: callId, method: method, args: args)

        case .resize(let token, let nodeId, let segmentId, let height):
            guard let e = registry.entry(token), e.identity.nodeId == nodeId, e.identity.segmentId == segmentId else { return }
            let h = CardScriptLimits.clampHeight(height)
            eval("window.mp && mp.htmlResize && mp.htmlResize(\(Self.js(nodeId)), \(Self.js(segmentId)), \(Self.js(token)), \(h))")

        case .cspReport(let token, let nodeId, let segmentId, let kind, let text):
            guard let e = registry.entry(token), e.identity.nodeId == nodeId, e.identity.segmentId == segmentId else { return }
            var r = runtimeReports[e.identity.profileId] ?? HTMLEmbedRuntimeReport()
            r.record(kind: kind, text: text, segment: e.identity.segmentKey)
            reportStore.reports[e.identity.profileId] = r
            log("[HTMLEMBED] \(kind == "csp" ? "挡掉" : "不支持") \(e.identity.segmentKey): \(text.prefix(120))")
            // B2：这段被挡的外部资源 → 卡片右下角「挡掉了 N 个」（未许可的卡也显示）
            guard kind == "csp", CardBlockedResource.parse(text) != nil,
                  let items = r.blockedBySegment[e.identity.segmentKey], !items.isEmpty else { return }
            blockedContent[e.identity.segmentKey] = (e.identity, e.content.hashValue)
            let rows = CardBlockedResource.rows(items).map { ["host": $0.host, "kind": $0.kind.label] }
            let info: [String: Any] = ["count": items.count, "rows": rows,
                                       "note": network.blockedNote,
                                       "footnote": CardBlockedResource.footnote]
            let json = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            eval("window.mp && mp.htmlBlocked && mp.htmlBlocked(\(Self.js(nodeId)), \(Self.js(segmentId)), \(json))")
        }
    }

    /// 校验链 → 执行 → 先推快照再回结果；要重渲染时之后再推一次宿主更新，本段被换掉了就按新内容重跑
    private func handleCall(token: String, nodeId: String, segmentId: String, callId: String, method: String, args: String) {
        let scope = currentScope()
        let entry = registry.entry(token)
        let input = CardScriptGate.Input(
            registered: entry.map { ($0.identity, $0.mode == .interactive) },
            claimedNodeId: nodeId, claimedSegmentId: segmentId,
            activeToken: interactive?.token, token: token,
            currentProfileId: scope.profileId, currentConversationId: scope.conversationId,
            runDenial: runDenial, method: method, args: args)
        let checked = CardScriptGate.check(input, limiter: &limiter, now: now())
        guard case .success(let request) = checked, let identity = entry?.identity else {
            if case .failure(let why) = checked {
                log("[HTMLEMBED] 拒绝 call \(method)：\(why.message)")
                if !why.isSilent { deliverResult(token: token, nodeId: nodeId, segmentId: segmentId, callId: callId, error: why.message) }
            }
            return
        }
        if case .triggerSlash(let command) = request {
            handleSlash(command, token: token, identity: identity, callId: callId)
            return
        }
        let origin = interactive?.origin ?? .user
        switch execute(request, identity) {
        case .failure(let why):
            log("[HTMLEMBED] call \(method) 没执行：\(why.message)")
            pushSnapshot()
            deliverResult(token: token, nodeId: nodeId, segmentId: segmentId, callId: callId, error: why.message)
        case .success(let needsRefresh):
            pushSnapshot()
            deliverResult(token: token, nodeId: nodeId, segmentId: segmentId, callId: callId, error: nil)
            guard needsRefresh else { return }
            refreshAfterWrite()
            // 改了本段所在的消息 → 段内容变了、旧实例已注销：按新内容重跑（同酒馆助手 refresh 重渲染该楼）
            if interactive == nil, sources[identity.segmentKey] != nil, runDenial == nil {
                run(nodeId: identity.nodeId, segmentId: identity.segmentId, origin: origin)
            }
        }
    }

    /// 进交互：user = 点了「运行」，auto = B6 自动运行最新一条
    private func run(nodeId: String, segmentId: String, origin: CardSlashGate.Origin) {
        guard let src = sources["\(nodeId)|\(segmentId)"] else { return }
        if let reason = runDenial {
            notice(nodeId, segmentId, reason)
            return
        }
        guard src.content.utf8.count <= HTMLEmbedPolicy.maxBytes else {
            notice(nodeId, segmentId, "网页太大，不能运行")
            return
        }
        stopInteractive()
        registry.removeAll { $0.identity == src.identity }   // 这段的静态 token 一并作废
        let token = registry.register(src.identity, content: src.content, mode: .interactive,
                                      bridge: bridge(src.identity, .interactive), network: network)
        let key = "page2|\(src.identity.segmentKey)|\(token)"
        interactive = (key, token, src.identity, origin)
        setActiveKey(key)                                   // 别处（原生卡 / 另一段）正在跑的会被挤掉
        attach(src.identity, token: token, mode: .interactive)
        log("[HTMLEMBED] 交互 \(src.identity.segmentKey)\(origin == .auto ? "（自动）" : "")")
    }

    /// B6：渲染 / 内容更新之后调（web 那边的段已经建好）。最新一条助手消息换了 → 它的第一个网页段自动跑，旧的降回静态
    func autoRunLatest(_ messages: [CardAutoRun.Message]) {
        let action = CardAutoRun.decide(messages, state: &autoRunState, enabled: autoRunEnabled && runDenial == nil,
                                        interactiveSegmentKey: interactive?.identity.segmentKey)
        switch action {
        case .none: break
        case .run(let nodeId, let segmentId): run(nodeId: nodeId, segmentId: segmentId, origin: .auto)
        case .stop: stopInteractive()
        }
    }

    // MARK: B5 triggerSlash

    /// 解析 → 放行判断（实例 / 卡 / 生成中 / 等确认 / 3 秒 / sendConsent）→ 直接跑、先弹确认、或降级成填输入框
    private func handleSlash(_ command: String, token: String, identity: HTMLEmbedIdentity, callId: String) {
        let reply: (Result<String, CardScriptRejection>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                deliverResult(token: token, nodeId: identity.nodeId, segmentId: identity.segmentId, callId: callId, error: nil, value: value)
            case .failure(let why):
                log("[HTMLEMBED] triggerSlash 没执行：\(why.message)")
                deliverResult(token: token, nodeId: identity.nodeId, segmentId: identity.segmentId, callId: callId, error: why.message)
            }
        }
        guard let slash else {
            reply(.failure(.refused("这里的网页不能用 triggerSlash")))
            return
        }
        let names = slash.names()
        let plan: CardSlashPlan
        switch CardSlash.plan(command, charName: names.char, userName: names.user) {
        case .failure(let why):
            if case .unsupported(let what) = why {      // 角色页「用到了还不支持的」
                var r = runtimeReports[identity.profileId] ?? HTMLEmbedRuntimeReport()
                r.record(kind: "unsupported", text: what)
                reportStore.reports[identity.profileId] = r
            }
            reply(.failure(why))
            return
        case .success(let p): plan = p
        }
        let card = slash.card()
        let input = CardSlashGate.Input(plan: plan, origin: interactive?.token == token ? interactive?.origin : nil, card: card,
                                        generating: slash.isGenerating(), awaitingConfirm: awaitingSendConfirm)
        switch CardSlashGate.decide(input, throttle: &slashThrottle, now: now()) {
        case .failure(let why):
            if CardSlashGate.notifies(why) { _ = slash.perform(.toast(why.message)) }   // 正在生成 / 等确认 / 太快：轻提示
            reply(.failure(why))
        case .success(.run(let steps)):
            reply(perform(steps).map { plan.result })
        case .success(.degrade(let steps)):
            reply(perform(steps).map { plan.result })
        case .success(.ask(let confirmation)):
            guard let card else { return }
            awaitingSendConfirm = true
            slash.confirm(confirmation) { [weak self] choice in
                guard let self else { return }
                awaitingSendConfirm = false
                guard let choice else {
                    reply(.failure(.refused("没有发送")))
                    return
                }
                let scope = currentScope()
                guard scope.profileId == identity.profileId, scope.conversationId == identity.conversationId else {
                    reply(.failure(.refused("对话已经换了，没有发送")))
                    return
                }
                switch choice {
                case .allowAlways:
                    slash.setConsent(card.id, .allowed)
                    reply(perform(plan.steps).map { plan.result })
                case .once:
                    reply(perform(plan.steps).map { plan.result })
                case .deny:
                    slash.setConsent(card.id, .denied)
                    reply(perform(plan.degradedSteps(cardName: card.name)).map { plan.result })
                }
            }
        }
    }

    private func perform(_ steps: [CardSlashStep]) -> Result<Void, CardScriptRejection> {
        for step in steps {
            if let why = slash?.perform(step) { return .failure(why) }
        }
        return .success(())
    }

    /// 原生事件 → 活跃交互实例（事件名 / 参数照 tavern_events），之后推一次新快照
    func emit(_ events: [CardScriptEvent]) {
        guard let i = interactive, !events.isEmpty else { return }
        for ev in events {
            deliver(i, payload: "{\"type\":\"event\",\"name\":\(Self.js(ev.name)),\"args\":\(ev.args)}")
        }
        pushSnapshot()
    }

    /// 快照重算后推给交互实例（同时更新登记的文档，reloadIframe 拿到新的）
    func pushSnapshot() {
        guard let i = interactive else { return }
        let b = bridge(i.identity, .interactive)
        registry.refresh(i.token, bridge: b)
        guard let snapshot = b?.snapshot else { return }
        deliver(i, payload: "{\"type\":\"snapshotUpdate\",\"snapshot\":\(snapshot)}")
    }

    private func deliverResult(token: String, nodeId: String, segmentId: String, callId: String, error: String?, value: String? = nil) {
        let tail = error.map { ",\"ok\":false,\"error\":\(Self.js($0))" } ?? (",\"ok\":true" + (value.map { ",\"value\":\(Self.js($0))" } ?? ""))
        deliver(nodeId: nodeId, segmentId: segmentId, token: token, payload: "{\"type\":\"result\",\"id\":\(Self.js(callId))\(tail)}")
    }

    private func deliver(_ i: (key: String, token: String, identity: HTMLEmbedIdentity, origin: CardSlashGate.Origin), payload: String) {
        deliver(nodeId: i.identity.nodeId, segmentId: i.identity.segmentId, token: i.token, payload: payload)
    }

    private func deliver(nodeId: String, segmentId: String, token: String, payload: String) {
        eval("window.mp && mp.htmlDeliver && mp.htmlDeliver(\(Self.js(nodeId)), \(Self.js(segmentId)), \(Self.js(token)), \(payload))")
    }

    /// 全局唯一交互实例被别处换掉了（原生卡或另一个宿主点了运行）
    func activeKeyChanged(_ key: String?) {
        guard let i = interactive, key != i.key else { return }
        dropInteractive(detachInWeb: true, releaseClaim: false)
    }

    func stopInteractive() {
        guard interactive != nil else { return }
        dropInteractive(detachInWeb: true)
    }

    /// 后台 / 内容进程重启 / 页面重载：全部 iframe 销毁、token 注销
    func suspend(inWeb: Bool = true) {
        registry.removeAll()
        if interactive != nil { dropInteractive(detachInWeb: false) }
        if inWeb { eval("window.mp && mp.htmlSuspend && mp.htmlSuspend()") }
    }

    func resume() { eval("window.mp && mp.htmlResume && mp.htmlResume()") }

    /// 宿主拆掉（离开 Page2 聊天）
    func teardown() {
        registry.removeAll()
        if interactive != nil { dropInteractive(detachInWeb: false) }
        sources = [:]
    }

    // MARK: -

    private func dropInteractive(detachInWeb: Bool, releaseClaim: Bool = true) {
        guard let i = interactive else { return }
        interactive = nil
        registry.unregister(i.token)
        limiter.forget(i.token)
        if releaseClaim, activeKey() == i.key { setActiveKey(nil) }
        if detachInWeb {
            eval("window.mp && mp.htmlDetach && mp.htmlDetach(\(Self.js(i.identity.nodeId)), \(Self.js(i.identity.segmentId)))")
        }
    }

    private func attach(_ id: HTMLEmbedIdentity, token: String, mode: HTMLEmbedMode) {
        let spec: [String: String] = ["token": token, "src": HTMLEmbedSchemeHandler.url(token: token), "mode": mode.rawValue]
        let json = (try? JSONSerialization.data(withJSONObject: spec)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        eval("window.mp && mp.htmlAttach && mp.htmlAttach(\(Self.js(id.nodeId)), \(Self.js(id.segmentId)), \(json))")
    }

    private func notice(_ nodeId: String, _ segmentId: String, _ text: String, blocked: Bool = false) {
        eval("window.mp && mp.htmlNotice && mp.htmlNotice(\(Self.js(nodeId)), \(Self.js(segmentId)), \(Self.js(text)), \(blocked))")
    }

    /// 字符串进 JS 走 JSON 编码（引号 / 换行 / U+2028 都安全）
    static func js(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

/// 一个楼层里卡网页的运行时记录（内存态）：被 CSP 挡掉的资源、用到了还不支持的助手 API。
/// B2 的「挡掉了 N 个外部资源」、B1 的「用到了还不支持的功能」从这里取
struct HTMLEmbedRuntimeReport: Equatable {
    private(set) var blockedCount = 0
    private(set) var blocked: [String] = []
    private(set) var unsupportedAPIs: Set<String> = []
    /// B2：段键 → 这段被挡的外部资源（按地址去重；iframe 重挂再报同一个不重复计数）
    private(set) var blockedBySegment: [String: [CardBlockedResource]] = [:]

    mutating func record(kind: String, text: String, segment: String? = nil) {
        if kind == "unsupported" {
            if unsupportedAPIs.count < 200 { unsupportedAPIs.insert(text) }
            return
        }
        // 内联脚本 / mp-card / data 之类不是「外部资源」（静态段正文脚本被 nonce 挡也会报），不计数
        guard let item = CardBlockedResource.parse(text) else { return }
        blockedCount += 1
        if blocked.count < 100, !blocked.contains(text) { blocked.append(text) }
        guard let segment else { return }
        var list = blockedBySegment[segment] ?? []
        if list.count < 100, !list.contains(where: { $0.url == item.url }) { list.append(item) }
        blockedBySegment[segment] = list
    }

    mutating func clearBlocked(segment: String) { blockedBySegment[segment] = nil }
}

/// 运行时报告的全局存放处（Page2 宿主写、角色页读）
@Observable @MainActor
final class HTMLEmbedRuntimeStore {
    static let shared = HTMLEmbedRuntimeStore()
    var reports: [String: HTMLEmbedRuntimeReport] = [:]
}
