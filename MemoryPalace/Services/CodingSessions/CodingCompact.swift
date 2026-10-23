#if os(macOS)
import Foundation

/// 省 token 的转录渲染（Wake `render_compact`，给 AI 工具读）：只出 user / assistant 正文，工具调用折成一行，Meta（注入上下文）跳过并计数，
/// 压缩摘要保留为引用块，图片略去；按 seq 分页。`maxMessageChars` 是**整条消息**的预算：正文、thinking、工具行与工具输入输出共用一份——
/// 分页对本页首条消息不查总量（保证前进），单条消息自身必须有界，否则一轮上百次工具调用能撑爆对方上下文。
/// seq 与索引同源，搜索命中的 `code://session/<key>#<seq>` 直接对得上这里的 `[seq N]`。字符数一律按 Unicode 标量数（与 Wake `chars()` 同口径）
enum CodingCompact {
    struct Options: Equatable {
        /// 从该 seq 起（含）
        var fromSeq = 0
        /// 本页最多输出多少条消息（Meta 不计）
        var maxMessages = 60
        /// 本页正文字符上限（至少给出一条，超出即停并给 nextSeq）
        var maxChars = 20_000
        /// 单条消息正文字符上限，超出截断并标注
        var maxMessageChars = 4_000
        /// 带工具调用的输入 / 输出正文（默认只留一行名称加输入预览）
        var includeTools = false
        var includeThinking = false
    }

    struct Page: Equatable {
        var text: String
        /// 下一页起点 seq；nil = 已到主线末尾
        var nextSeq: Int?
        var rendered: Int
        /// 本页范围内被跳过的注入上下文（Meta）条数
        var skippedMeta: Int
        /// 本页首 / 末条消息的 seq（rendered = 0 时都是 nil）
        var firstSeq: Int?
        var lastSeq: Int?
    }

    /// 一条消息最多列多少条工具调用（pi 系把一整轮回复合成一条，里面可能上百次调用）；超出的只报条数
    static let maxToolLines = 40

    static func render(_ messages: [CodingMessage], _ o: Options) -> Page {
        var page = Page(text: "", nextSeq: nil, rendered: 0, skippedMeta: 0, firstSeq: nil, lastSeq: nil)
        var chars = 0
        for m in messages where m.seq >= o.fromSeq {
            if m.kind == .meta {
                page.skippedMeta += 1
                continue
            }
            let text = block(m, o)
            let count = text.unicodeScalars.count
            if page.rendered > 0 && (page.rendered >= o.maxMessages || chars + count > o.maxChars) {
                page.nextSeq = m.seq
                break
            }
            page.text += text
            chars += count
            page.rendered += 1
            if page.firstSeq == nil { page.firstSeq = m.seq }
            page.lastSeq = m.seq
        }
        return page
    }

    static func title(_ role: CodingRole) -> String {
        switch role {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }

    private static func block(_ m: CodingMessage, _ o: Options) -> String {
        let when = m.timestamp.map { " · " + CodingSessionExport.formatTime($0) } ?? ""
        var out = "### [seq \(m.seq)] \(title(m.role))\(when)\n"
        var budget = o.maxMessageChars
        if m.kind == .compactSummary {
            out += "> [compacted summary] " + spend(m.text, &budget).replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
            return out
        }
        // 正文优先于 thinking 拿预算，输出顺序仍是 thinking 在前
        let body = spend(m.text.trimmingCharacters(in: .whitespacesAndNewlines), &budget)
        var thinking: String?
        if o.includeThinking, let raw = m.thinking, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thinking = spend(raw, &budget)
        }
        if let thinking {
            out += "> [thinking] " + thinking.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
        }
        if !body.isEmpty {
            out += body + "\n\n"
        } else if m.toolCalls.isEmpty {
            out += "(empty)\n\n"
        }
        let images = max(m.imageCount, m.images.count)
        if images > 0 {
            out += "(\(images) image attachment\(images == 1 ? "" : "s") omitted)\n\n"
        }
        var shown = 0
        for call in m.toolCalls {
            let status = call.isError ? " ✗" : ""
            let line = "- 🔧 \(call.name)\(status): \(call.inputPreview)\n"
            let lineChars = line.unicodeScalars.count
            // 首条工具行无论如何给出（读者要知道这条消息动过工具），之后按预算
            if shown >= maxToolLines || (shown > 0 && lineChars > budget) { break }
            out += line
            budget = max(0, budget - lineChars)
            shown += 1
            if o.includeTools && budget > 0 {
                if let input = call.input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out += "  input:\n  ```\n\(indent(spend(input, &budget)))\n  ```\n"
                }
                if let output = call.output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out += "  output:\n  ```\n\(indent(spend(output, &budget)))\n  ```\n"
                }
            }
        }
        let hidden = m.toolCalls.count - shown
        if hidden > 0 { out += "- … \(hidden) more tool call\(hidden == 1 ? "" : "s") not shown\n" }
        if !m.toolCalls.isEmpty { out += "\n" }
        return out
    }

    /// 从消息预算里扣着截：按剩余预算截断，并把用掉的字符数（含截断标注）记账
    private static func spend(_ s: String, _ budget: inout Int) -> String {
        let clipped = clip(s, budget)
        budget = max(0, budget - clipped.unicodeScalars.count)
        return clipped
    }

    /// 按字符截断并标注（字节切会切坏 CJK）；字节数 ≤ max 时字符数必 ≤ max，先按字节放行
    static func clip(_ s: String, _ max: Int) -> String {
        if s.utf8.count <= max { return s }
        let scalars = s.unicodeScalars
        guard scalars.count > max else { return s }
        return String(String.UnicodeScalarView(scalars.prefix(max))) + "… [truncated]"
    }

    /// 每行前缩两格（Rust `lines()` 语义：末尾换行不产生空行，行尾 \r 去掉）
    private static func indent(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { "  " + ($0.hasSuffix("\r") ? String($0.dropLast()) : $0) }.joined(separator: "\n")
    }
}
#endif
