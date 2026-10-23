import Foundation
import SwiftStreamingMarkdown

/// 气泡模式渲染前的 Markdown 简化（docs/research-bubble-md-simplify.md）。
/// 抹掉文档感格式，保留聊天感格式；只在渲染时调用，存储/复制/引用仍是原文。
/// - ATX 标题 `#`~`######` → 加粗正文
/// - 嵌套列表项去前导缩进 → 全部拍平到一级
/// - 分隔线 `---`/`***`/`___` 整行删除
/// - 围栏代码块内部不动（多反引号嵌套按 CommonMark 配对）；加粗/斜体/表格/行内代码/链接/引用块原样
enum BubbleMarkdownSimplifier {

    static func simplify(_ text: String) -> String {
        let text = MarkdownFenceNormalizer.normalize(text)   // 同长度嵌套围栏先推断改写
        var out: [String] = []
        var changed = false
        var fence = MarkdownFenceTracker()
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence.consume(line) {
                out.append(line)
                continue
            }
            if isThematicBreak(trimmed) {
                changed = true
                continue
            }
            if let title = headingText(trimmed) {
                changed = true
                if !title.isEmpty { out.append("**\(title)**") }
                continue
            }
            if line.first == " " || line.first == "\t", isListItem(trimmed) {
                changed = true
                out.append(trimmed)
                continue
            }
            out.append(line)
        }
        return changed ? out.joined(separator: "\n") : text
    }

    /// 整块 simplify 后为空（纯分隔线/空标题块）——调用方跳过该块，避免渲染出空气泡。
    static func isRenderEmpty(_ block: String) -> Bool {
        simplify(block).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// CommonMark 分隔线：同一字符（-/*/_）≥3 个，允许中间空格。表格分隔行含 `|` 不会匹配。
    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 }
            else if ch != " " { return false }
        }
        return count >= 3
    }

    /// ATX 标题正文：`## 标题` → `标题`。非标题（`#标签`、7 个 #）返回 nil。
    /// 剥行尾闭合井号串（`## 标题 ##`，CommonMark 要求闭合串前有空白，`C#` 不误伤），
    /// 剥行内已有 `**`（避免包一层后嵌套加粗炸格式）。
    private static func headingText(_ trimmed: String) -> String? {
        guard trimmed.first == "#" else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var body = rest.trimmingCharacters(in: .whitespaces)
        if body.hasSuffix("#") {
            var idx = body.endIndex
            while idx > body.startIndex, body[body.index(before: idx)] == "#" {
                idx = body.index(before: idx)
            }
            if idx == body.startIndex {
                body = ""
            } else if body[body.index(before: idx)] == " " || body[body.index(before: idx)] == "\t" {
                body = String(body[..<idx])
            }
        }
        return body.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 列表项：`- `/`* `/`+ ` 或 `1. `/`1) `（≤9 位数字）。`*斜体*` 无空格不匹配。
    private static func isListItem(_ trimmed: String) -> Bool {
        guard let first = trimmed.first else { return false }
        if "-*+".contains(first) {
            let after = trimmed.dropFirst()
            return after.first == " " || after.first == "\t"
        }
        guard first.isNumber else { return false }
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard digits.count <= 9 else { return false }
        var rest = trimmed.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return false }
        rest = rest.dropFirst()
        return rest.first == " " || rest.first == "\t"
    }
}
