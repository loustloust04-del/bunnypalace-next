import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 群聊正文：一段已拆好的块（`BubbleModeRow.splitBlocks`）→ NSAttributedString，给 UIKit 气泡里的 UITextView。
/// 支持：`**粗**` / `*斜*` `_斜_` / `` `行内代码` `` / `[文字](链接)` + 裸链接 / `- ` `* ` `1. ` 列表（悬挂缩进）/
/// ``` 围栏代码块 / `#` 标题（加粗，只大一点）/ `> 引用`（小一号灰字 + 缩进，竖线由气泡画）/ `@handle`（群成员才高亮）。
/// 表格 / 公式 / HTML 原样显示。
/// 跨平台只为了能在 mac 测试宿主上跑单测，界面只在 iOS 用。
enum GroupMarkdownRenderer {
    #if canImport(UIKit)
    typealias MDFont = UIFont
    typealias MDColor = UIColor
    #else
    typealias MDFont = NSFont
    typealias MDColor = NSColor
    #endif

    struct Style {
        var font: MDFont
        var textColor: MDColor
        /// @成员 / 链接色（`Theme.branchIndicator`）
        var accentColor: MDColor
        /// 行内代码 / 代码块浅底
        var codeBackground: MDColor
        var lineSpacing: CGFloat
        /// `>` 引用段的字色（对方 `Theme.textMuted`）
        var quoteColor: MDColor
    }

    /// 标记代码区（裸链接 / @ 高亮跳过这里）
    static let codeKey = NSAttributedString.Key("mp.groupCode")
    /// 标记引用段：气泡按它的行框在左侧画 2pt 竖线
    static let quoteKey = NSAttributedString.Key("mp.groupQuote")
    /// 引用段缩进（竖线 2pt + 间隔）
    static let quoteIndent: CGFloat = 10

    /// 全是 `>` 行的段落并进下一段：回复的 `> 名字：原话\n\n正文` 不拆成两个泡
    static func mergingQuoteBlocks(_ blocks: [String]) -> [String] {
        var out: [String] = []
        for block in blocks {
            if let last = out.last, isQuoteBlock(last) {
                out[out.count - 1] = last + "\n" + block
            } else {
                out.append(block)
            }
        }
        return out
    }

    private static func isQuoteBlock(_ block: String) -> Bool {
        block.components(separatedBy: "\n").allSatisfy { quoteBody($0.trimmingCharacters(in: .whitespaces)) != nil }
    }

    // MARK: - 入口

    /// 对方消息：先由调用方过 `BubbleMarkdownSimplifier.simplify`，再转这里
    static func render(_ block: String, style: Style, handles: Set<String>) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var fenceMarker: String?
        var codeLines: [String] = []
        var first = true

        func newline() {
            if !first { out.append(NSAttributedString(string: "\n", attributes: baseAttributes(style))) }
            first = false
        }
        func flushCode() {
            newline()
            out.append(codeBlock(codeLines.joined(separator: "\n"), style: style))
            codeLines.removeAll()
        }

        for line in block.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fenceMarker {
                if trimmed.hasPrefix(marker), trimmed.allSatisfy({ $0 == marker.first }) {
                    fenceMarker = nil
                    flushCode()
                } else {
                    codeLines.append(line)
                }
                continue
            }
            if let marker = openingFence(trimmed) {
                fenceMarker = marker
                continue
            }
            newline()
            out.append(renderLine(line, trimmed: trimmed, style: style))
        }
        // 没闭合的围栏：剩下的照代码块显示
        if fenceMarker != nil { flushCode() }

        linkifyBareURLs(out, style: style)
        highlightMentions(out, style: style, handles: handles)
        return out
    }

    /// 自己的消息：和气泡模式「你」的气泡一样是纯文本，只把 @成员 标出来；回复带的 `>` 引用行照引用段显示
    static func plain(_ text: String, style: Style, handles: Set<String>) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n", attributes: baseAttributes(style))) }
            if let body = quoteBody(line.trimmingCharacters(in: .whitespaces)) {
                out.append(quote(NSAttributedString(string: body, attributes: baseAttributes(quoteStyle(style))), style: style))
            } else {
                out.append(NSAttributedString(string: line, attributes: baseAttributes(style)))
            }
        }
        highlightMentions(out, style: style, handles: handles)
        return out
    }

    // MARK: - 块级

    private static func openingFence(_ trimmed: String) -> String? {
        for ch in ["`", "~"] {
            let run = trimmed.prefix(while: { String($0) == ch })
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func renderLine(_ line: String, trimmed: String, style: Style) -> NSAttributedString {
        if let body = quoteBody(trimmed) {
            return quote(inline(body, style: quoteStyle(style), traits: Traits()), style: style)
        }
        if let (level, body) = heading(trimmed) {
            let scale: CGFloat = level <= 2 ? 1.08 : 1.04
            return inline(body, style: style, traits: Traits(bold: true, sizeScale: scale))
        }
        if let (marker, body) = listItem(trimmed) {
            let piece = NSMutableAttributedString(string: marker + "\t", attributes: baseAttributes(style))
            piece.append(inline(body, style: style, traits: Traits()))
            let indent = ceil((marker as NSString).size(withAttributes: [.font: style.font]).width + style.font.pointSize * 0.5)
            let para = paragraph(style)
            para.headIndent = indent
            para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            para.defaultTabInterval = indent
            piece.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: piece.length))
            return piece
        }
        return inline(line, style: style, traits: Traits())
    }

    /// `> 引用` / `>引用` / `>> 嵌套` → 引用正文（嵌套拍平成一层）
    private static func quoteBody(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix(">") else { return nil }
        return String(trimmed.drop(while: { $0 == ">" || $0 == " " }))
    }

    /// 引用段：小一号、灰字（由 `quoteStyle` 给），整段缩进 `quoteIndent`，打 `quoteKey`
    private static func quote(_ body: NSAttributedString, style: Style) -> NSAttributedString {
        let piece = NSMutableAttributedString(attributedString: body)
        let para = paragraph(quoteStyle(style))
        para.firstLineHeadIndent = quoteIndent
        para.headIndent = quoteIndent
        para.paragraphSpacing = 2
        let range = NSRange(location: 0, length: piece.length)
        piece.addAttributes([.paragraphStyle: para, quoteKey: true], range: range)
        return piece
    }

    private static func quoteStyle(_ style: Style) -> Style {
        var quoted = style
        quoted.font = style.font.withSize(style.font.pointSize * 0.9)
        quoted.textColor = style.quoteColor
        quoted.lineSpacing = min(style.lineSpacing, 3)
        return quoted
    }

    /// `# 标题` → (级别, 正文)；`#标签`、7 个 # 不算
    private static func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard let space = rest.first, space == " " || space == "\t" else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    /// `- 项` / `* 项` / `+ 项` → ("•", 项)；`1. 项` / `1) 项` → ("1.", 项)
    private static func listItem(_ trimmed: String) -> (String, String)? {
        guard let first = trimmed.first else { return nil }
        if "-*+".contains(first) {
            let after = trimmed.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            return ("•", after.trimmingCharacters(in: .whitespaces))
        }
        let digits = trimmed.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...9).contains(digits.count) else { return nil }
        var rest = trimmed.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " || rest.first == "\t" else { return nil }
        return ("\(digits).", rest.trimmingCharacters(in: .whitespaces))
    }

    private static func codeBlock(_ code: String, style: Style) -> NSAttributedString {
        let para = paragraph(style)
        para.lineSpacing = 2
        return NSAttributedString(string: code, attributes: [
            .font: MDFont.monospacedSystemFont(ofSize: style.font.pointSize * 0.88, weight: .regular),
            .foregroundColor: style.textColor,
            .backgroundColor: style.codeBackground,
            .paragraphStyle: para,
            codeKey: true,
        ])
    }

    // MARK: - 行内

    private struct Traits {
        var bold = false
        var italic = false
        var sizeScale: CGFloat = 1
        var link: URL?
    }

    private static func inline(_ text: String, style: Style, traits: Traits) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let chars = Array(text)
        var buffer = ""
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(NSAttributedString(string: buffer, attributes: attributes(style, traits)))
            buffer = ""
        }
        func isWordChar(_ index: Int) -> Bool {
            index >= 0 && index < chars.count && (chars[index].isLetter || chars[index].isNumber)
        }

        while i < chars.count {
            let c = chars[i]
            // 反斜杠转义标点
            if c == "\\", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                buffer.append(chars[i + 1])
                i += 2
                continue
            }
            // 行内代码：同长度反引号配对
            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                if let close = findRun(chars, of: "`", length: run, from: i + run) {
                    var code = String(chars[(i + run)..<close])
                    if code.count >= 2, code.first == " ", code.last == " " { code = String(code.dropFirst().dropLast()) }
                    flush()
                    var attrs = attributes(style, traits)
                    attrs[.font] = MDFont.monospacedSystemFont(ofSize: style.font.pointSize * traits.sizeScale * 0.88, weight: .regular)
                    attrs[.backgroundColor] = style.codeBackground
                    attrs[codeKey] = true
                    out.append(NSAttributedString(string: code, attributes: attrs))
                    i = close + run
                } else {
                    buffer.append(String(repeating: "`", count: run))
                    i += run
                }
                continue
            }
            // 粗体 ** / __
            if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] == c,
               i + 2 < chars.count, !chars[i + 2].isWhitespace,
               c == "*" || !isWordChar(i - 1),
               let close = findDouble(chars, c, from: i + 2) {
                flush()
                var t = traits
                t.bold = true
                out.append(inline(String(chars[(i + 2)..<close]), style: style, traits: t))
                i = close + 2
                continue
            }
            // 斜体 * / _（`_` 不吃单词中间的下划线：snake_case）
            if (c == "*" || c == "_"), i + 1 < chars.count, !chars[i + 1].isWhitespace,
               c == "*" || !isWordChar(i - 1),
               let close = findSingle(chars, c, from: i + 1) {
                flush()
                var t = traits
                t.italic = true
                out.append(inline(String(chars[(i + 1)..<close]), style: style, traits: t))
                i = close + 1
                continue
            }
            // [文字](链接)
            if c == "[", let closeBracket = chars[(i + 1)...].firstIndex(of: "]"),
               closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
               let closeParen = chars[(closeBracket + 2)...].firstIndex(of: ")"),
               let url = URL(string: String(chars[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)),
               url.scheme != nil {
                flush()
                var t = traits
                t.link = url
                out.append(inline(String(chars[(i + 1)..<closeBracket]), style: style, traits: t))
                i = closeParen + 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    private static func findRun(_ chars: [Character], of ch: Character, length: Int, from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            guard chars[j] == ch else { j += 1; continue }
            var run = 0
            while j + run < chars.count, chars[j + run] == ch { run += 1 }
            if run == length { return j }
            j += run
        }
        return nil
    }

    /// 闭合的 `**` / `__`：前一个字符不是空白，且不是空内容
    private static func findDouble(_ chars: [Character], _ ch: Character, from start: Int) -> Int? {
        var j = start + 1
        while j + 1 < chars.count {
            if chars[j] == ch, chars[j + 1] == ch, !chars[j - 1].isWhitespace {
                if ch == "_", j + 2 < chars.count, chars[j + 2].isLetter || chars[j + 2].isNumber { j += 1; continue }
                return j
            }
            j += 1
        }
        return nil
    }

    /// 闭合的单个 `*` / `_`：跳过成对的 `**`（斜体里套粗体）
    private static func findSingle(_ chars: [Character], _ ch: Character, from start: Int) -> Int? {
        var j = start + 1
        while j < chars.count {
            if chars[j] == ch {
                if j + 1 < chars.count, chars[j + 1] == ch {
                    j += 2
                    continue
                }
                if !chars[j - 1].isWhitespace {
                    if ch == "_", j + 1 < chars.count, chars[j + 1].isLetter || chars[j + 1].isNumber { j += 1; continue }
                    return j
                }
            }
            j += 1
        }
        return nil
    }

    // MARK: - 后处理：裸链接 / @成员

    private static let urlRegex = try? NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'*+,;=%]+"#)

    private static func linkifyBareURLs(_ out: NSMutableAttributedString, style: Style) {
        guard let urlRegex else { return }
        let string = out.string as NSString
        for match in urlRegex.matches(in: out.string, range: NSRange(location: 0, length: string.length)) {
            var range = match.range
            // 句末标点不算链接
            while range.length > 0, ".,;:!?".contains(string.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))) {
                range.length -= 1
            }
            guard range.length > 0, !overlapsCodeOrLink(out, range),
                  let url = URL(string: string.substring(with: range)) else { continue }
            out.addAttributes([.link: url, .foregroundColor: style.accentColor], range: range)
        }
    }

    private static func highlightMentions(_ out: NSMutableAttributedString, style: Style, handles: Set<String>) {
        guard !handles.isEmpty else { return }
        let text = out.string
        var searchStart = text.startIndex
        while let at = text[searchStart...].firstIndex(of: "@") {
            var end = text.index(after: at)
            while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" || text[end] == "-" {
                end = text.index(after: end)
            }
            let handle = String(text[text.index(after: at)..<end])
            let range = NSRange(at..<end, in: text)
            if handles.contains(handle), !overlapsCodeOrLink(out, range) {
                let current = out.attribute(.font, at: range.location, effectiveRange: nil) as? MDFont ?? style.font
                out.addAttributes([.foregroundColor: style.accentColor, .font: semibold(current)], range: range)
            }
            searchStart = end > at ? end : text.index(after: at)
        }
    }

    private static func overlapsCodeOrLink(_ out: NSAttributedString, _ range: NSRange) -> Bool {
        var hit = false
        out.enumerateAttributes(in: range) { attrs, _, stop in
            if attrs[codeKey] != nil || attrs[.link] != nil { hit = true; stop.pointee = true }
        }
        return hit
    }

    // MARK: - 字体 / 属性

    private static func paragraph(_ style: Style) -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = style.lineSpacing
        return para
    }

    private static func baseAttributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        [.font: style.font, .foregroundColor: style.textColor, .paragraphStyle: paragraph(style)]
    }

    private static func attributes(_ style: Style, _ traits: Traits) -> [NSAttributedString.Key: Any] {
        var attrs = baseAttributes(style)
        var font = traits.sizeScale == 1 ? style.font : style.font.withSize(style.font.pointSize * traits.sizeScale)
        if traits.bold { font = semibold(font) }
        attrs[.font] = font
        if traits.italic { attrs.merge(italicAttributes(font)) { $1 } }
        if let link = traits.link {
            attrs[.link] = link
            attrs[.foregroundColor] = style.accentColor
        }
        return attrs
    }

    /// 斜体属性：有斜体变体用变体，没有（中文字体大多如此）就倾斜
    static func italicAttributes(_ font: MDFont) -> [NSAttributedString.Key: Any] {
        if let italic = withTraits(font, italic: true) { return [.font: italic] }
        return [.font: font, .obliqueness: 0.18]
    }

    /// 系统字体用 semibold（和气泡模式 markdown 的粗体同一档）；自定义字体找同族粗体，找不到保持原样
    static func semibold(_ font: MDFont) -> MDFont {
        if font.fontName.hasPrefix(".") {
            let semibold = MDFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            return isItalic(font) ? (withTraits(semibold, italic: true) ?? semibold) : semibold
        }
        return withTraits(font, bold: true) ?? font
    }

    static func isBold(_ font: MDFont) -> Bool {
        #if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
            || ((font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0) >= UIFont.Weight.semibold.rawValue
        #else
        font.fontDescriptor.symbolicTraits.contains(.bold)
            || ((font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0) >= NSFont.Weight.semibold.rawValue
        #endif
    }

    static func isItalic(_ font: MDFont) -> Bool {
        #if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #else
        font.fontDescriptor.symbolicTraits.contains(.italic)
        #endif
    }

    /// 同族变体；系统找不到时会退回原字体（名字不变），这里当作没有
    private static func withTraits(_ font: MDFont, bold: Bool = false, italic: Bool = false) -> MDFont? {
        #if canImport(UIKit)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return nil }
        let variant = UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        guard let variant = NSFont(descriptor: descriptor, size: font.pointSize) else { return nil }
        #endif
        return variant.fontName != font.fontName ? variant : nil
    }
}
