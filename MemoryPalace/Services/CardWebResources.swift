import Foundation

// 卡库第二批 B1 / B2（plan-card-library-batch2）：卡里网页的静态识别 + 联网白名单 + 内置库。
// 纯逻辑（只依赖 Foundation），Page2 子文档（HTMLEmbed）和原生预览壳（HTMLPreviewWebView）共用。

/// 卡里的开场是不是「前端」：照酒馆助手 is_frontend.ts（含 `html>` / `<head>` / `<body`），另加 `<script`
enum CardFrontendDetector {
    static func isFrontend(_ text: String) -> Bool {
        text.range(of: "<script", options: .caseInsensitive) != nil
            || ["html>", "<head>", "<body"].contains { text.contains($0) }
    }
}

/// 本批不支持、静态扫描就能认出来的功能（角色页「用到了还不支持的」）
enum CardUnsupportedFeature: String, CaseIterable {
    case mvu = "MVU 变量框架"
    case worldBook = "世界书"
    case audio = "音频"
    case generate = "生成（generate）"
    case remoteScript = "远程脚本"
}

enum CardFeatureScanner {
    private static func regex(_ p: String, ignoringCase: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: ignoringCase ? [.caseInsensitive] : [])
    }

    /// API 名区分大小写（免得正文里写「MVU.」也算）；import / script 标签不分
    private static let patterns: [(CardUnsupportedFeature, NSRegularExpression)] = [
        (.mvu, regex(#"\bMvu\.|waitGlobalInitialized|MagVarUpdate"#)),
        (.worldBook, regex(#"\b\w*(?:Lorebook|Worldbook)\w*\s*\("#)),
        (.audio, regex(#"\b(?:audioEnable|audioImport|audioMode|audioPlay|audioSelect|playAudio|pauseAudio|getAudioList|replaceAudioList|appendAudioList|getAudioSettings|setAudioSettings|getCurrentAudio)\s*\("#)),
        (.generate, regex(#"(?:TavernHelper\.|(?<![\w$.]))generate(?:Raw)?\s*\("#)),
        (.remoteScript, regex(#"\bimport\s*(?:[\w${},*\s]+\bfrom\s*)?\(?\s*['"]https?://"#, ignoringCase: true)),
    ]
    private static let scriptSrc = regex(#"<script\b[^>]*?\bsrc\s*=\s*["']?((?:https?:)?//[^"'\s>]+)"#, ignoringCase: true)

    /// 卡文本（后台脚本 + 开场 + 正则替换模板）里用到的不支持功能，按固定顺序
    static func scan(_ texts: [String]) -> [CardUnsupportedFeature] {
        var found = Set<CardUnsupportedFeature>()
        for text in texts where !text.isEmpty {
            let ns = text as NSString
            let all = NSRange(location: 0, length: ns.length)
            for (feature, re) in patterns where !found.contains(feature) && re.firstMatch(in: text, range: all) != nil {
                found.insert(feature)
            }
            // 外链脚本：内置库能接住的（改写成 mp-card://lib/）不算
            if !found.contains(.remoteScript) {
                for m in scriptSrc.matches(in: text, range: all) where CardWebLibrary.localPath(forRemote: ns.substring(with: m.range(at: 1))) == nil {
                    found.insert(.remoteScript)
                    break
                }
            }
        }
        return CardUnsupportedFeature.allCases.filter(found.contains)
    }

    /// 运行时垫片报的不支持 API 名 → 能归类的归类，其余原样
    static func label(runtime name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("lorebook") || lower.contains("worldbook") { return CardUnsupportedFeature.worldBook.rawValue }
        if lower.contains("audio") { return CardUnsupportedFeature.audio.rawValue }
        if name == "generate" || name == "generateRaw" { return CardUnsupportedFeature.generate.rawValue }
        if name == "waitGlobalInitialized" || name == "initializeGlobal" || name.hasPrefix("Mvu") { return CardUnsupportedFeature.mvu.rawValue }
        return name
    }

    /// 静态扫描 ∪ 运行时记录：归类的按固定顺序在前，其余按名字
    static func describe(static found: [CardUnsupportedFeature], runtime: Set<String>) -> [String] {
        let labels = Set(found.map(\.rawValue)).union(runtime.map(label(runtime:)))
        let known = CardUnsupportedFeature.allCases.map(\.rawValue).filter(labels.contains)
        return known + labels.subtracting(known).sorted()
    }
}

/// 白名单（只对已许可的卡、只放 font / style / img）。以后加域名改这张表
enum CardWebWhitelist {
    static let font = ["fonts.googleapis.com", "fonts.gstatic.com", "fontsapi.zeoseven.com", "fontsapi-storage.zeoseven.com"]
    static let style = ["fonts.googleapis.com", "cdnjs.cloudflare.com", "cdn.jsdelivr.net", "fontsapi.zeoseven.com"]
    static let image = ["files.catbox.moe", "i.imgur.com", "s41.ax1x.com", "i.ibb.co", "i.postimg.cc", "images.unsplash.com", "picsum.photos",
                             "fastly.picsum.photos"]   // picsum.photos 会 302 到这里

    static func sources(_ hosts: [String]) -> String { hosts.map { "https://\($0)" }.joined(separator: " ") }
}

/// 子文档里被 CSP 挡掉的一个外部资源（只记 http(s)；内联脚本 / mp-card / data 不算「外部资源」）
struct CardBlockedResource: Hashable {
    enum Kind: String {
        case script, style, font, image, media, connect, frame, other
        var label: String {
            switch self {
            case .script: "脚本"
            case .style: "样式"
            case .font: "字体"
            case .image: "图片"
            case .media: "媒体"
            case .connect: "联网"
            case .frame: "网页"
            case .other: "其他"
            }
        }
    }

    let url: String
    let host: String
    let kind: Kind

    /// 子文档上报的「违规指令 被挡地址」
    static func parse(_ report: String) -> CardBlockedResource? {
        let parts = report.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let url = URL(string: parts[1].trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let d = parts[0].lowercased()
        let kind: Kind = d.hasPrefix("script") ? .script : d.hasPrefix("style") ? .style : d.hasPrefix("font") ? .font
            : d.hasPrefix("img") ? .image : d.hasPrefix("media") ? .media : d.hasPrefix("connect") ? .connect
            : (d.hasPrefix("frame") || d.hasPrefix("child")) ? .frame : .other
        return CardBlockedResource(url: url.absoluteString, host: host, kind: kind)
    }

    /// 弹层列表：同域名同类型只列一行
    static func rows(_ items: [CardBlockedResource]) -> [(host: String, kind: Kind)] {
        var seen = Set<String>()
        return items.compactMap { seen.insert("\($0.host)|\($0.kind.rawValue)").inserted ? ($0.host, $0.kind) : nil }
    }

    static let footnote = "只允许白名单里的字体、图标和图片；网上的脚本不加载。"
    static let notAllowedNote = "这张卡还没启用，白名单里的也先挡着。"
    static let localModeNote = "本地模式开着，白名单里的也先挡着。"
}

/// 打进 app 的常用库（jQuery / lodash / Font Awesome Free），经 `mp-card://lib/<名>@<版本>/<路径>` 提供。
/// 只回这份固定白名单里的文件；卡里指向常见 CDN 的 `<script src>` / `<link href>` 拼子文档时改写成这里的地址
enum CardWebLibrary {
    struct File: Equatable {
        let resource: String
        let ext: String
        let contentType: String
    }

    static let jquery = "jquery@3.5.1"
    static let lodash = "lodash@4.17.23"
    static let fontAwesome = "fontawesome-free@6.5.2"

    /// lib/ 之后的路径 → bundle 资源（Resources/CardLib，打包后在 bundle 根）
    static let files: [String: File] = {
        let js = "text/javascript; charset=utf-8", css = "text/css; charset=utf-8"
        return [
            "\(jquery)/jquery.min.js": File(resource: "cardlib-jquery-3.5.1.min", ext: "js", contentType: js),
            "\(lodash)/lodash.min.js": File(resource: "cardlib-lodash-4.17.23.min", ext: "js", contentType: js),
            "\(fontAwesome)/css/all.min.css": File(resource: "cardlib-fontawesome-6.5.2-all.min", ext: "css", contentType: css),
            "\(fontAwesome)/css/fontawesome.min.css": File(resource: "cardlib-fontawesome-6.5.2-fontawesome.min", ext: "css", contentType: css),
            "\(fontAwesome)/css/solid.min.css": File(resource: "cardlib-fontawesome-6.5.2-solid.min", ext: "css", contentType: css),
            "\(fontAwesome)/css/brands.min.css": File(resource: "cardlib-fontawesome-6.5.2-brands.min", ext: "css", contentType: css),
            "\(fontAwesome)/webfonts/fa-solid-900.woff2": File(resource: "cardlib-fa-solid-900", ext: "woff2", contentType: "font/woff2"),
            "\(fontAwesome)/webfonts/fa-brands-400.woff2": File(resource: "cardlib-fa-brands-400", ext: "woff2", contentType: "font/woff2"),
        ]
    }()

    static func url(_ path: String) -> String { "mp-card://lib/\(path)" }

    /// 酒馆助手给每个消息 iframe 先装好 Font Awesome / jQuery / lodash（`third_party_message.html` + `predefine.js`），
    /// 不少卡直接用 `$` / `_` / `fa-` 图标、自己不写 `<script src>`（B8 矩阵实测）。卡聊天的子文档照样先装上：
    /// 只用内置库（本地，不联网）；脚本只在交互模式（静态段 script-src 只有 nonce，装了也不跑）
    static func preload(scripts: Bool) -> String {
        var out = "<link rel=\"stylesheet\" href=\"\(url("\(fontAwesome)/css/all.min.css"))\">\n"
        if scripts {
            // crossorigin：lib 回 ACAO *，卡在 jQuery 回调里抛的错才不会被抹成「Script error.」
            out += "<script src=\"\(url("\(jquery)/jquery.min.js"))\" crossorigin=\"anonymous\"></script>\n"
                + "<script src=\"\(url("\(lodash)/lodash.min.js"))\" crossorigin=\"anonymous\"></script>\n"
        }
        return out
    }

    /// `mp-card://lib/<白名单路径>`：多一个字符都不认（不带 query / fragment / 用户名 / 端口）
    static func file(for url: URL?) -> File? {
        guard let url, url.scheme?.lowercased() == "mp-card", url.host == "lib",
              url.query == nil, url.fragment == nil, url.user == nil, url.port == nil else { return nil }
        let path = String(url.path.dropFirst())
        guard url.path.hasPrefix("/"), !path.contains(".."), !path.contains("//") else { return nil }
        return files[path]
    }

    /// 读 bundle 里的文件（找不到 = nil，handler 回失败）
    static func bundleData(_ file: File) -> Data? {
        let url = Bundle.main.url(forResource: file.resource, withExtension: file.ext)
            ?? Bundle.main.url(forResource: file.resource, withExtension: file.ext, subdirectory: "CardLib")
        return url.flatMap { try? Data(contentsOf: $0) }
    }

    // MARK: CDN 改写

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    private static let jsdelivr = #"(?:cdn|testingcf)\.jsdelivr\.net"#
    /// (正则, 目标路径)；目标里的 $1 = Font Awesome 的 css 名
    private static let cdnRules: [(NSRegularExpression, String)] = [
        (regex(#"^code\.jquery\.com/jquery(?:-[\w.]+?)?(?:\.slim)?(?:\.min)?\.js$"#), "\(jquery)/jquery.min.js"),
        (regex(#"^cdnjs\.cloudflare\.com/ajax/libs/jquery/[^/]+/jquery(?:\.slim)?(?:\.min)?\.js$"#), "\(jquery)/jquery.min.js"),
        (regex("^\(jsdelivr)" + #"/npm/jquery(?:@[^/]+)?(?:/dist/jquery(?:\.slim)?(?:\.min)?\.js)?/?$"#), "\(jquery)/jquery.min.js"),
        (regex(#"^cdnjs\.cloudflare\.com/ajax/libs/lodash\.js/[^/]+/lodash(?:\.min)?\.js$"#), "\(lodash)/lodash.min.js"),
        (regex("^\(jsdelivr)" + #"/npm/lodash(?:@[^/]+)?(?:/lodash(?:\.min)?\.js)?/?$"#), "\(lodash)/lodash.min.js"),
        (regex(#"^cdnjs\.cloudflare\.com/ajax/libs/font-awesome/[^/]+/css/([\w.-]+?)(?:\.min)?\.css$"#), "fa"),
        (regex("^\(jsdelivr)" + #"/npm/@fortawesome/fontawesome-free(?:@[^/]+)?/css/([\w.-]+?)(?:\.min)?\.css$"#), "fa"),
    ]

    /// 常见 CDN 地址 → lib/ 之后的本地路径；不是这三个库（或 FA 的 JS 版）= nil，按规则被挡
    static func localPath(forRemote raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        for prefix in ["https://", "http://", "//"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        guard !s.isEmpty, !s.hasPrefix("/") else { return nil }
        let ns = s as NSString
        for (re, target) in cdnRules {
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            guard target == "fa" else { return target }
            // 版本对不上一律用内置的 6.x；拆开的三份照名给，其余（all / regular / v4 的 font-awesome / shims）给 all
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            let css = ["fontawesome", "solid", "brands"].contains(name) ? name : "all"
            return "\(fontAwesome)/css/\(css).min.css"
        }
        return nil
    }

    private static let tagRegex = regex(#"<(script|link)\b[^>]*>"#)
    private static let attrRegex = regex(#"\s(src|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let sriRegex = regex(#"\s(?:integrity|crossorigin)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?"#)

    /// 只在拼子文档时调：返回改写后的副本，卡原文 / 消息原文不动。
    /// 改写的标签去掉 integrity / crossorigin（内容换成了本地副本，SRI 对不上会被拒）
    static func rewrite(_ html: String) -> String {
        guard html.range(of: "<script", options: .caseInsensitive) != nil || html.range(of: "<link", options: .caseInsensitive) != nil else { return html }
        let ns = html as NSString
        let out = NSMutableString(string: html)
        for tag in tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let tagText = ns.substring(with: tag.range)
            let tns = tagText as NSString
            let want = ns.substring(with: tag.range(at: 1)).lowercased() == "script" ? "src" : "href"
            guard let attr = attrRegex.matches(in: tagText, range: NSRange(location: 0, length: tns.length))
                    .first(where: { tns.substring(with: $0.range(at: 1)).lowercased() == want }) else { continue }
            let valueRange = [2, 3, 4].map { attr.range(at: $0) }.first { $0.location != NSNotFound } ?? attr.range(at: 2)
            guard valueRange.location != NSNotFound, let local = localPath(forRemote: tns.substring(with: valueRange)) else { continue }
            let replaced = tns.replacingCharacters(in: attr.range, with: " \(want)=\"\(url(local))\"")
            let cleaned = sriRegex.stringByReplacingMatches(in: replaced, range: NSRange(location: 0, length: (replaced as NSString).length), withTemplate: "")
            out.replaceCharacters(in: tag.range, with: cleaned)
        }
        return out as String
    }
}
