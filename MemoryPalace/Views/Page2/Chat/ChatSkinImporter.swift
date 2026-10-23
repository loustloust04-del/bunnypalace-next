#if os(iOS)
import Foundation
import UIKit
import ZIPFoundation

/// `.ktheme` / `.mpskin` → 聊天皮肤 CSS。
///
/// 两种包**同一套解析器**：我们的格式就是 KakaoTalk 的超集（⧫ 粟粟拍板「抄人家的只换个名字」），
/// 所以 KakaoTalk 主题作者零成本给我们做主题，用户拿现成 .ktheme 改几行就能用。
/// 参考实现和对照实验见 `scripts/ktheme/ktheme2css.py` + `docs/design-refs/ktheme-import/`。
///
/// 包里那个 css **不是真 CSS**，是类 CSS 的私有 DSL：
/// 选择器是 `MessageCellStyle-Send` 这种组件名，属性是 `-ios-*`。
enum ChatSkinImporter {

    enum ImportError: LocalizedError {
        case notASkin, unsafePath(String), tooLarge(String), noStyle
        var errorDescription: String? {
            switch self {
            case .notASkin:        return "不是主题包（缺 KakaoTalkTheme.css / GardenTheme.css / theme.css）"
            case .unsafePath(let p): return "包里有非法路径：\(p)"
            case .tooLarge(let w):  return "包太大：\(w)"
            case .noStyle:          return "解析不出任何样式"
            }
        }
    }

    // 安全阈值（kimi 审查：只限压缩后大小 = zip bomb 能炸出几个 GB）
    private static let maxZipBytes = 20 * 1024 * 1024
    private static let maxUnpackedBytes = 60 * 1024 * 1024
    private static let maxFileCount = 200
    private static let maxSingleFile = 5 * 1024 * 1024
    private static let allowedExt: Set<String> = ["css", "png", "jpg", "jpeg", "gif", "webp",
                                                  "json", "ttf", "otf", "woff", "woff2"]

    struct Result { let name: String; let author: String; let source: String }

    /// 解包 → 校验 → 转成 CSS → 落到 ChatSkins/active/
    @discardableResult
    static func install(from url: URL) throws -> Result {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxZipBytes else { throw ImportError.tooLarge("\(size / 1024 / 1024)MB > 20MB") }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("skin_\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try unzipChecked(url, to: tmp)

        // 三个入口名都认：KakaoTalk 原版 / 我们自己的
        let cssName = ["KakaoTalkTheme.css", "GardenTheme.css", "theme.css"]
            .first { fm.fileExists(atPath: tmp.appendingPathComponent($0).path) }
        guard let cssName,
              let raw = try? String(contentsOf: tmp.appendingPathComponent(cssName), encoding: .utf8)
                ?? String(contentsOf: tmp.appendingPathComponent(cssName), encoding: .isoLatin1)
        else { throw ImportError.notASkin }

        let blocks = parse(raw)
        let imagesDir = tmp.appendingPathComponent("Images")
        var css = generate(blocks: blocks, imagesDir: imagesDir)

        // 手工覆盖层：真 CSS，原样追加，但掐掉 @import 和外链（CSP 再兜一层）
        if let extra = try? String(contentsOf: tmp.appendingPathComponent("extra.css"), encoding: .utf8) {
            css += "\n/* ---- extra.css ---- */\n" + sanitize(extra)
        }
        guard css.count > 40 else { throw ImportError.noStyle }

        // 落地
        let dst = ChatSkinStore.activeSkinDir
        try? fm.removeItem(at: dst)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        if fm.fileExists(atPath: imagesDir.path) {
            try? fm.copyItem(at: imagesDir, to: dst.appendingPathComponent("Images"))
        }
        for d in ["fonts", "Fonts"] where fm.fileExists(atPath: tmp.appendingPathComponent(d).path) {
            try? fm.copyItem(at: tmp.appendingPathComponent(d), to: dst.appendingPathComponent(d))
        }
        try css.write(to: dst.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)

        let man = blocks["ManifestStyle"] ?? [:]
        let result = Result(name: unquote(man["-kakaotalk-theme-name"] ?? man["-garden-theme-name"] ?? "未命名"),
                            author: unquote(man["-kakaotalk-author-name"] ?? man["-garden-author-name"] ?? ""),
                            source: cssName.hasPrefix("KakaoTalk") ? "kakaotalk" : "garden")
        let meta = ["name": result.name, "author": result.author, "source": result.source]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? d.write(to: dst.appendingPathComponent("manifest.json"))
        }
        KBProbe.log("[CSSCHAT] 皮肤导入成功: \(result.name) / \(result.author) (\(css.count) 字节)")
        ChatSkinStore.notifyChanged()
        return result
    }

    // MARK: - 解包（路径穿越 + zip bomb）

    private static func unzipChecked(_ zip: URL, to dst: URL) throws {
        let archive = try Archive(url: zip, accessMode: .read)
        // ⚠️ 用 standardized（纯字面）不用 standardizedFileURL：后者查磁盘，路径存在才剥 /private。
        // 真机 tmp 是 /private/var/…：root 已建会被剥、target 还没解出来不剥 → 前缀永远对不上，所有包都被拒
        let root = dst.standardized.path
        var total = 0, count = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            let path = entry.path
            // ⚠️ 现有的 StickerPackImporter 没有这一段（直接 unzipItem），别去抄它
            guard !path.hasPrefix("/"), !path.contains("..") else { throw ImportError.unsafePath(path) }
            let target = dst.appendingPathComponent(path).standardized
            guard target.path.hasPrefix(root + "/") else { throw ImportError.unsafePath(path) }
            let ext = (path as NSString).pathExtension.lowercased()
            guard allowedExt.contains(ext) else { continue }        // .js/.html 一律不解
            guard entry.uncompressedSize <= maxSingleFile else { throw ImportError.tooLarge(path) }
            total += Int(entry.uncompressedSize); count += 1
            guard total <= maxUnpackedBytes else { throw ImportError.tooLarge("解压后 > 60MB") }
            guard count <= maxFileCount else { throw ImportError.tooLarge("文件数 > 200") }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
        }
    }

    private static func sanitize(_ css: String) -> String {
        var s = css
        s = s.replacingOccurrences(of: #"@import[^;]*;"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"url\(\s*['"]?\s*(https?:)?//[^)]*\)"#,
                                   with: "none", options: .regularExpression)
        return s
    }

    // MARK: - DSL 解析

    private static func parse(_ css: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        let blockRe = try! NSRegularExpression(pattern: #"([A-Za-z][\w-]*)\s*\{([^}]*)\}"#)
        let declRe = try! NSRegularExpression(pattern: #"([-\w]+)\s*:\s*([^;]+);"#)
        let ns = css as NSString
        for m in blockRe.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            let bns = body as NSString
            var decls: [String: String] = [:]
            for d in declRe.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
                decls[bns.substring(with: d.range(at: 1)).trimmed] = bns.substring(with: d.range(at: 2)).trimmed
            }
            out[name] = decls
        }
        return out
    }

    private static func unquote(_ s: String) -> String {
        s.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// CSS 里写 'foo.png'，磁盘上可能是 foo@3x.png。返回 (文件名, scale)
    private static func imageRef(_ dir: URL, _ name: String) -> (String, CGFloat)? {
        let n = unquote(name)
        let stem = (n as NSString).deletingPathExtension
        let ext = (n as NSString).pathExtension
        for (suffix, scale) in [("@3x", CGFloat(3)), ("@2x", 2), ("", 1)] {
            let f = "\(stem)\(suffix).\(ext)"
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
                return (f, scale)
            }
        }
        return nil
    }

    private static func px(_ s: String) -> CGFloat? {
        let t = s.trimmed.replacingOccurrences(of: "px", with: "")
        return Double(t).map { CGFloat($0) }
    }

    // MARK: - 生成 CSS

    private static func generate(blocks: [String: [String: String]], imagesDir: URL) -> String {
        var out = ""
        let send = blocks["MessageCellStyle-Send"] ?? [:]
        let recv = blocks["MessageCellStyle-Receive"] ?? [:]
        let inp = blocks["InputBarStyle-Chat"] ?? [:]
        let main = blocks["MainViewStyle-Primary"] ?? [:]

        // 聊天背景
        if let bg = blocks["BackgroundStyle-ChatRoom"] {
            if let img = bg["-ios-background-image"], let (f, _) = imageRef(imagesDir, img) {
                out += "body{background:url('mp-asset://skin/Images/\(f)') center/cover no-repeat;}\n"
            } else if let c = bg["background-color"] {
                out += "body{background:\(c);}\n"
            }
        }

        // 气泡：01=首条 02=连续（相邻选择器实现，不用改 DOM）
        out += bubble(#".mp-msg[data-role="user"] .mp-body"#, send, imagesDir, group: false)
        out += bubble(#".mp-msg[data-role="assistant"] .mp-body"#, recv, imagesDir, group: false)
        out += bubble(#".mp-msg[data-role="user"] + .mp-msg[data-role="user"] .mp-body"#, send, imagesDir, group: true)
        out += bubble(#".mp-msg[data-role="assistant"] + .mp-msg[data-role="assistant"] .mp-body"#, recv, imagesDir, group: true)

        // 输入栏
        var vars: [String] = []
        if let v = inp["background-color"] { vars.append("--mp-input-bg:\(v)") }
        if let v = inp["-ios-send-normal-background-color"] { vars.append("--mp-send-bg:\(v)") }
        if let v = inp["-ios-send-normal-foreground-color"] { vars.append("--mp-send-ink:\(v)") }
        if let v = inp["-ios-button-normal-foreground-color"] { vars.append("--mp-attach-ink:\(v)") }

        // 自动推导（⧫ 选项①）：KakaoTalk 没有分支/思考/引用这些概念，
        // 用气泡文字色 + 强调色染一遍，不然它们跟主题打架
        let ink = main["-ios-text-color"] ?? recv["-ios-text-color"] ?? send["-ios-text-color"]
        let accent = inp["-ios-send-normal-background-color"] ?? inp["-ios-button-normal-foreground-color"]
        if let ink {
            vars += ["--mp-ink:\(ink)",
                     "--mp-ink-faint:color-mix(in srgb, \(ink) 52%, transparent)",
                     "--mp-meta-ink:color-mix(in srgb, \(ink) 60%, transparent)",
                     "--mp-branch-ink:color-mix(in srgb, \(ink) 62%, transparent)",
                     "--mp-thinking-ink:color-mix(in srgb, \(ink) 62%, transparent)",
                     "--mp-quote-ink:color-mix(in srgb, \(ink) 70%, transparent)",
                     "--mp-more-ink:color-mix(in srgb, \(ink) 50%, transparent)",
                     "--mp-hairline:color-mix(in srgb, \(ink) 14%, transparent)",
                     "--mp-field-ink:\(ink)", "--mp-tobottom-ink:\(ink)"]
        }
        if let accent {
            vars += ["--mp-accent:\(accent)", "--mp-quote-border:2px solid \(accent)",
                     "--mp-caret-ink:\(accent)"]
        }
        if let surface = inp["background-color"] {
            vars += ["--mp-att-file-bg:\(surface)", "--mp-chip-bg:\(surface)",
                     "--mp-tobottom-bg:\(surface)", "--mp-field-bg:\(surface)"]
        }
        if !vars.isEmpty { out += ":root{" + vars.joined(separator: ";") + ";}\n" }

        // 我们扩的块（⧫ 选项③）：同一套 DSL 风格，KakaoTalk 的解析器会忽略
        let extra: [(String, String, [(String, String)])] = [
            ("BranchIndicatorStyle", ".mp-branches", [("-ios-text-color", "color")]),
            ("ThinkingBlockStyle", ".mp-thinking", [("-ios-text-color", "color"), ("background-color", "background")]),
            ("QuoteStyle", ".mp-quote", [("-ios-text-color", "color"), ("background-color", "background")]),
            ("AttachmentStyle", #".mp-att[data-type="file"]"#, [("-ios-text-color", "color"), ("background-color", "background")]),
            ("TimestampStyle", ".mp-time", [("-ios-text-color", "color")]),
            ("NameStyle", ".mp-name", [("-ios-text-color", "color")]),
        ]
        for (block, sel, mapping) in extra {
            guard let d = blocks[block] else { continue }
            let decls = mapping.compactMap { k, prop in d[k].map { "\(prop):\($0)" } }
            if !decls.isEmpty { out += "\(sel){" + decls.joined(separator: ";") + ";}\n" }
        }
        return out
    }

    /// 九宫格：`'x.png' 27px 23px` 是 iOS `stretchableImage(leftCap, topCap)` 语义——
    /// 只给左/上，右下自动算，中间 1pt 拉伸。装饰角（Kitty 头、钻石心）全靠它不被拉变形。
    /// CSS 要三个属性配合：border-width=文字内距（定文字位置）、border-image-width=cap
    /// （定画多宽）、border-image-outset=两者差（把图向外扩，装饰才完整）。
    private static func bubble(_ selector: String, _ d: [String: String],
                               _ imagesDir: URL, group: Bool) -> String {
        let imgKey = group ? "-ios-group-background-image" : "-ios-background-image"
        guard let raw = d[imgKey] else { return "" }
        let parts = raw.split(separator: " ").map(String.init)
        guard let (file, scale) = imageRef(imagesDir, parts[0]) else { return "" }
        guard let img = UIImage(contentsOfFile: imagesDir.appendingPathComponent(file).path) else { return "" }
        let w = img.size.width * img.scale, h = img.size.height * img.scale   // 真实像素

        let capL = parts.count > 1 ? (px(parts[1]) ?? 0) : 0
        let capT = parts.count > 2 ? (px(parts[2]) ?? 0) : 0
        let L = capL * scale, T = capT * scale
        let R = w - L - scale, B = h - T - scale
        guard R > 0, B > 0 else { return "" }
        let capR = R / scale, capB = B / scale

        // -ios-title-edgeinsets: top left bottom right
        let eiKey = group ? "-ios-group-title-edgeinsets" : "-ios-title-edgeinsets"
        let ei = (d[eiKey] ?? "").split(separator: " ").compactMap { px(String($0)) }
        let (et, el, eb, er) = ei.count == 4 ? (ei[0], ei[1], ei[2], ei[3]) : (capT, capL, capB, capR)
        func o(_ cap: CGFloat, _ edge: CGFloat) -> CGFloat { max(0, cap - edge) }

        var rules = [
            "border-style:solid;border-color:transparent",
            "border-width:\(et)px \(er)px \(eb)px \(el)px",
            "border-image-source:url('mp-asset://skin/Images/\(file)')",
            "border-image-slice:\(fmt(T)) \(fmt(R)) \(fmt(B)) \(fmt(L)) fill",
            "border-image-width:\(fmt(capT))px \(fmt(capR))px \(fmt(capB))px \(fmt(capL))px",
            "border-image-outset:\(fmt(o(capT, et)))px \(fmt(o(capR, er)))px \(fmt(o(capB, eb)))px \(fmt(o(capL, el)))px",
            "border-radius:0;background:none;box-shadow:none",
        ]
        if let c = d["-ios-text-color"] { rules.append("color:\(c)") }
        return "\(selector){\n  " + rules.joined(separator: ";\n  ") + ";\n}\n"
    }

    private static func fmt(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
#endif
