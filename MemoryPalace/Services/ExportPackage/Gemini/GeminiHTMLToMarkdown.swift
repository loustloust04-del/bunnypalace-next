import Foundation
import SwiftSoup

/// Gemini Takeout 回答 HTML（`safeHtmlItem[].html` / My Activity HTML）→ Markdown。
/// 真 DOM 解析，实体只解一次；script / style 等整块丢，链接只留 http(s)，图片只留「[图片]」字样；
/// 正文里的 Markdown 记号转义（原文是 HTML 文本，不该被当成链接 / 强调）。
enum GeminiHTMLToMarkdown {
    static func convert(_ html: String) -> String {
        guard let body = try? SwiftSoup.parseBodyFragment(html).body() else { return "" }
        return normalize(renderChildren(of: body, inPre: false))
    }

    static func convert(nodes: [Node]) -> String {
        normalize(nodes.map { render($0, inPre: false) }.joined())
    }

    private static let droppedTags: Set<String> = ["script", "style", "iframe", "noscript", "template", "object", "embed", "head", "title", "meta", "link"]
    private static let blockTags: Set<String> = ["p", "div", "section", "article", "header", "footer", "figure", "main", "aside", "nav", "details", "summary", "dl", "dd", "dt"]

    private static func renderChildren(of element: Element, inPre: Bool) -> String {
        element.getChildNodes().map { render($0, inPre: inPre) }.joined()
    }

    private static func render(_ node: Node, inPre: Bool) -> String {
        if let text = node as? TextNode {
            let raw = text.getWholeText()
            return inPre ? raw : escape(collapseWhitespace(raw))
        }
        guard let el = node as? Element else { return "" }
        let tag = el.tagName().lowercased()
        if droppedTags.contains(tag) { return "" }

        switch tag {
        case "br":
            return "\n"
        case "hr":
            return "\n\n---\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(tag.dropFirst()) ?? 1
            let inner = inline(renderChildren(of: el, inPre: false))
            return inner.isEmpty ? "" : "\n\n" + String(repeating: "#", count: level) + " " + inner + "\n\n"
        case "strong", "b":
            return wrap(renderChildren(of: el, inPre: inPre), "**")
        case "em", "i":
            return wrap(renderChildren(of: el, inPre: inPre), "*")
        case "s", "del", "strike":
            return wrap(renderChildren(of: el, inPre: inPre), "~~")
        case "code":
            if inPre { return rawText(el) }
            let code = rawText(el)
            guard !code.isEmpty else { return "" }
            let fence = String(repeating: "`", count: longestRun(of: "`", in: code) + 1)
            let pad = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
            return fence + pad + code + pad + fence
        case "pre":
            let code = rawText(el).trimmingCharacters(in: .newlines)
            let fence = String(repeating: "`", count: max(3, longestRun(of: "`", in: code) + 1))
            return "\n\n" + fence + codeLanguage(el) + "\n" + code + "\n" + fence + "\n\n"
        case "a":
            let label = inline(renderChildren(of: el, inPre: false))
            let href = (try? el.attr("href"))?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let url = URL(string: href), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return label }
            let target = href.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
            return "[" + (label.isEmpty ? escape(href) : label) + "](" + target + ")"
        case "img":
            let alt = ((try? el.attr("alt")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return alt.isEmpty ? "[图片]" : "[图片：\(escape(collapseWhitespace(alt)))]"
        case "ul", "ol":
            return "\n\n" + list(el, ordered: tag == "ol") + "\n\n"
        case "li":
            return "\n" + renderChildren(of: el, inPre: false) + "\n"
        case "blockquote":
            let inner = normalize(renderChildren(of: el, inPre: false))
            guard !inner.isEmpty else { return "" }
            return "\n\n" + inner.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "table":
            return "\n\n" + table(el) + "\n\n"
        default:
            let inner = renderChildren(of: el, inPre: inPre)
            if blockTags.contains(tag) {
                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? "" : "\n\n" + trimmed + "\n\n"
            }
            return inner
        }
    }

    private static func list(_ el: Element, ordered: Bool) -> String {
        // 编号夹在合理范围：start 给 Int.max 时 += 1 会溢出崩溃
        var index = min(max(Int((try? el.attr("start")) ?? "") ?? 1, 0), 999_999_999)
        var lines: [String] = []
        for child in el.children().array() where child.tagName().lowercased() == "li" {
            let marker = ordered ? "\(index). " : "- "
            index += 1
            let body = normalize(renderChildren(of: child, inPre: false))
            let indent = String(repeating: " ", count: marker.count)
            let itemLines = body.isEmpty ? [""] : body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (i, line) in itemLines.enumerated() {
                lines.append(i == 0 ? marker + line : (line.isEmpty ? "" : indent + line))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func table(_ el: Element) -> String {
        let rows = ((try? el.select("tr").array()) ?? []).map { row in
            row.children().array()
                .filter { ["th", "td"].contains($0.tagName().lowercased()) }
                .map { cell in inline(renderChildren(of: cell, inPre: false)).replacingOccurrences(of: "|", with: "\\|") }
        }.filter { !$0.isEmpty }
        guard let width = rows.map(\.count).max(), width > 0 else { return "" }
        func line(_ cells: [String]) -> String {
            "| " + (cells + Array(repeating: "", count: width - cells.count)).joined(separator: " | ") + " |"
        }
        var out = [line(rows[0]), "|" + Array(repeating: " --- |", count: width).joined()]
        out += rows.dropFirst().map(line)
        return out.joined(separator: "\n")
    }

    private static func codeLanguage(_ pre: Element) -> String {
        let classes = ((try? pre.select("code").first()?.className()) ?? nil) ?? ((try? pre.className()) ?? "")
        for cls in classes.split(separator: " ") {
            for prefix in ["language-", "lang-"] where cls.hasPrefix(prefix) {
                return String(cls.dropFirst(prefix.count))
            }
        }
        return ""
    }

    private static func rawText(_ node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        guard let el = node as? Element else { return "" }
        if el.tagName().lowercased() == "br" { return "\n" }
        if droppedTags.contains(el.tagName().lowercased()) { return "" }
        return el.getChildNodes().map(rawText).joined()
    }

    private static func wrap(_ inner: String, _ mark: String) -> String {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return inner }
        let lead = String(inner.prefix { $0 == " " }), trail = String(inner.reversed().prefix { $0 == " " })
        return lead + mark + trimmed + mark + trail
    }

    /// 转义会被渲染成格式的记号：`\` `` ` `` `*` `[` `]` 总转；`_` 只在词边界转（`snake_case` 本来就不强调，免得搜索文本里满是反斜杠）；
    /// `~~`、像标签 / 自动链接开头的 `<` 才转。行首 `#` `-` `1.` 这类块级记号没转（技术债）
    static func escape(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, ch) in chars.enumerated() {
            let prev = i > 0 ? chars[i - 1] : nil, next = i + 1 < chars.count ? chars[i + 1] : nil
            let escapeIt: Bool
            switch ch {
            case "\\", "`", "*", "[", "]": escapeIt = true
            case "_": escapeIt = !(prev.map(isWordChar) ?? false) || !(next.map(isWordChar) ?? false)
            case "~": escapeIt = next == "~" || prev == "~"
            case "<": escapeIt = next.map { $0.isLetter || "/!?".contains($0) } ?? false
            default: escapeIt = false
            }
            if escapeIt { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func inline(_ s: String) -> String {
        collapseWhitespace(s).trimmingCharacters(in: .whitespaces)
    }

    private static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in s {
            if ch.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    private static func longestRun(of c: Character, in s: String) -> Int {
        var best = 0, cur = 0
        for ch in s {
            cur = ch == c ? cur + 1 : 0
            best = max(best, cur)
        }
        return best
    }

    /// 行尾空白去掉、行首单个游离空格去掉（列表缩进保留）、3 个以上换行压成 2 个、首尾去空
    private static func normalize(_ s: String) -> String {
        var lines: [String] = []
        var blank = 0
        var inFence = false
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence {
                while line.last?.isWhitespace == true { line.removeLast() }
                if line.hasPrefix(" "), !line.hasPrefix("  ") { line.removeFirst() }
            }
            if line.isEmpty && !inFence {
                blank += 1
                if blank > 1 { continue }
            } else {
                blank = 0
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
