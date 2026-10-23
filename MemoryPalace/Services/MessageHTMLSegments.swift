import Foundation

/// 消息正文里的一段：普通文本，或一段明确的 HTML（卡库 ⑦）。
struct MessageHTMLSegment: Equatable {
    enum Kind: String { case text, html }
    /// 同一条消息内按出现顺序编号（t0 / h0 / t1…）；runtime 按 消息 ID + 段 ID keyed 更新
    let id: String
    let kind: Kind
    let content: String
    /// HTML 段的内容指纹（稳定哈希，跨进程一致）；内容变了 iframe 才换。文本段为空串
    var key: String { kind == .html ? MessageHTMLSegments.stableHash(content) : "" }
}

/// 只识别**明确的** HTML，其余一律当文本（普通代码块、行内提到的标签、比较符号都不误认）：
/// 1. ```html（或 htm）围栏块；
/// 2. 语言为空 / text 的围栏块里带酒馆助手识别标记（`html>` / `<head>` / `<body`，同 JS-Slash-Runner `isFrontend`）；
/// 3. 围栏外、从行首开始的完整 HTML 文档：`<!doctype html` / `<html` / `<head>` / `<body` 起，到 `</html>`（没有则 `</body>`）止。
/// 未闭合（流式中）的围栏 / 文档保持文本，闭合后才成段。
enum MessageHTMLSegments {
    static let rendererVersion = 1

    /// nil = 正文里没有 HTML 段（调用方走原来的纯文本路径，零变化）
    static func split(_ text: String) -> [MessageHTMLSegment]? {
        guard mayContainHTML(text) else { return nil }
        let pieces = scan(text as NSString)
        guard !pieces.isEmpty else { return nil }
        let ns = text as NSString
        var out: [MessageHTMLSegment] = []
        var textCount = 0, htmlCount = 0, cursor = 0
        func addText(_ range: NSRange) {
            let s = ns.substring(with: range).trimmingCharacters(in: .newlines)
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            out.append(MessageHTMLSegment(id: "t\(textCount)", kind: .text, content: s))
            textCount += 1
        }
        for p in pieces {
            addText(NSRange(location: cursor, length: p.outer.location - cursor))
            out.append(MessageHTMLSegment(id: "h\(htmlCount)", kind: .html, content: ns.substring(with: p.content)))
            htmlCount += 1
            cursor = NSMaxRange(p.outer)
        }
        addText(NSRange(location: cursor, length: ns.length - cursor))
        return out
    }

    /// 原生聊天（Markdown 渲染器只把 ```html 交给网页卡）：围栏外的完整文档包成 ```html 围栏，
    /// 助手标记的无语言 / text 围栏改标 html；其余字节原样。没有 HTML 段时原样返回。
    static func markdownPromotingHTML(_ text: String) -> String {
        guard mayContainHTML(text) else { return text }
        let ns = text as NSString
        let pieces = scan(ns)
        guard pieces.contains(where: { $0.needsRewrite }) else { return text }
        var out = "", cursor = 0
        for p in pieces {
            out += ns.substring(with: NSRange(location: cursor, length: p.outer.location - cursor))
            let content = ns.substring(with: p.content)
            switch p.origin {
            case .fenced(let fence, let rewrite):
                if rewrite {
                    out += fence + "html\n" + content + "\n" + fence
                } else {
                    out += ns.substring(with: p.outer)
                }
            case .document:
                let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: content) + 1))
                out += fence + "html\n" + content + "\n" + fence + "\n"
            }
            cursor = NSMaxRange(p.outer)
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// FNV-1a 64 位，十六进制。Swift `Hasher` 每进程随机，不能当跨进程 / 测试可复现的键
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h &*= 0x100000001b3
        }
        return String(h, radix: 16)
    }

    // MARK: - 扫描

    private enum Origin {
        /// fence = 开围栏的那串 ``` / ~~~（带行首缩进）；rewrite = 助手标记块，原生侧要改标 html
        case fenced(fence: String, rewrite: Bool)
        case document
    }

    private struct Piece {
        /// 整块占的范围（围栏块含首尾围栏行）；段之间的文本 = 相邻 outer 之间的空隙
        let outer: NSRange
        let content: NSRange
        let origin: Origin
        var needsRewrite: Bool {
            switch origin {
            case .fenced(_, let rewrite): return rewrite
            case .document: return true
            }
        }
    }

    private static func mayContainHTML(_ text: String) -> Bool {
        text.range(of: "htm", options: .caseInsensitive) != nil
            || text.range(of: "<head", options: .caseInsensitive) != nil
            || text.range(of: "<body", options: .caseInsensitive) != nil
    }

    private struct Line {
        let range: NSRange       // 不含换行
        let full: NSRange        // 含换行
        let text: String
    }

    private static func lines(_ ns: NSString) -> [Line] {
        var result: [Line] = []
        var loc = 0
        while loc < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: loc, length: 0))
            let r = NSRange(location: start, length: contentsEnd - start)
            result.append(Line(range: r, full: NSRange(location: start, length: end - start), text: ns.substring(with: r)))
            loc = end
        }
        return result
    }

    /// 行首 ≤3 空格 + ≥3 个 ` 或 ~ ；返回（缩进+围栏串, 围栏字符, 长度, info）
    private static func fenceOpen(_ line: String) -> (prefix: String, char: Character, count: Int, info: String)? {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let c = rest.first, c == "`" || c == "~" else { return nil }
        let run = rest.prefix(while: { $0 == c })
        guard run.count >= 3 else { return nil }
        let info = String(rest.dropFirst(run.count))
        if c == "`", info.contains("`") { return nil }
        return (String(indent) + String(run), c, run.count, info.trimmingCharacters(in: .whitespaces))
    }

    private static func isFenceClose(_ line: String, char: Character, count: Int) -> Bool {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return false }
        let rest = line.dropFirst(indent.count)
        let run = rest.prefix(while: { $0 == char })
        guard run.count >= count else { return false }
        return rest.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static let plainLanguages: Set<String> = ["", "text", "txt", "plaintext"]

    /// 酒馆助手 isFrontend：`html>` / `<head>` / `<body`（这里不分大小写）
    private static func hasHelperMarker(_ s: String) -> Bool {
        s.range(of: "html>", options: .caseInsensitive) != nil
            || s.range(of: "<head>", options: .caseInsensitive) != nil
            || s.range(of: "<body", options: .caseInsensitive) != nil
    }

    /// 行首（去掉前导空白后）是不是文档起点
    private static func documentStart(_ line: String) -> Bool {
        let t = line.drop(while: { $0 == " " || $0 == "\t" }).lowercased()
        if t.hasPrefix("<!doctype html") || t.hasPrefix("<head>") { return true }
        for tag in ["<html", "<body", "<head"] where t.hasPrefix(tag) {
            let after = t.dropFirst(tag.count).first
            if after == nil || after == ">" || after == " " || after == "\t" || after == "/" { return true }
        }
        return false
    }

    private static func scan(_ ns: NSString) -> [Piece] {
        let ls = lines(ns)
        var pieces: [Piece] = []
        var i = 0
        while i < ls.count {
            let line = ls[i]
            if let open = fenceOpen(line.text) {
                guard let j = ls[(i + 1)...].firstIndex(where: { isFenceClose($0.text, char: open.char, count: open.count) }) else {
                    break   // 未闭合围栏：后面全在代码块里，当文本
                }
                let lang = open.info.split(separator: " ").first.map { $0.lowercased() } ?? ""
                let innerStart = i + 1 < j ? ls[i + 1].range.location : line.full.location + line.full.length
                let innerEnd = i + 1 < j ? NSMaxRange(ls[j - 1].range) : innerStart
                let inner = NSRange(location: innerStart, length: max(0, innerEnd - innerStart))
                let innerText = ns.substring(with: inner)
                let isHTML = lang == "html" || lang == "htm"
                let isHelper = !isHTML && plainLanguages.contains(lang) && hasHelperMarker(innerText)
                if isHTML || isHelper, !innerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let outer = NSRange(location: line.range.location, length: NSMaxRange(ls[j].range) - line.range.location)
                    pieces.append(Piece(outer: outer, content: inner, origin: .fenced(fence: open.prefix, rewrite: isHelper)))
                }
                i = j + 1
                continue
            }
            if documentStart(line.text) {
                let leading = line.text.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
                let start = line.range.location + leading
                let tail = NSRange(location: start, length: ns.length - start)
                var close = ns.range(of: "</html>", options: .caseInsensitive, range: tail)
                if close.location == NSNotFound { close = ns.range(of: "</body>", options: .caseInsensitive, range: tail) }
                if close.location != NSNotFound {
                    let end = NSMaxRange(close)
                    let r = NSRange(location: start, length: end - start)
                    pieces.append(Piece(outer: r, content: r, origin: .document))
                    // 结束标签所在行之后继续扫；同一行标签后面的字归下一段文本
                    guard let k = ls.firstIndex(where: { NSMaxRange($0.full) >= end }) else { break }
                    i = k + 1
                    continue
                }
            }
            i += 1
        }
        return pieces
    }

    private static func longestRun(of c: Character, in s: String) -> Int {
        var best = 0, cur = 0
        for ch in s {
            if ch == c { cur += 1; best = max(best, cur) } else { cur = 0 }
        }
        return best
    }
}
