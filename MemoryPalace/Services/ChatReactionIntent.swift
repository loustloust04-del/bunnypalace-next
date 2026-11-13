import MemoryCore
import Foundation

/// AI 给她的消息贴表情：```react 意向协议（照 ```voice，零新工具，CC 和不支持工具的模型都能用）。
///
/// AI 在回复里写 ```react 块（第一行一个 emoji，可选空格后跟目标消息开头几个字）；回合收口时从正文删掉、
/// 贴到她那条消息上。只在气泡对话里教（`promptHint`），也只在气泡对话里处理。
enum ChatReactionIntent {
    static let blockTag = "```react"

    struct Intent: Equatable {
        let emoji: String
        /// 目标消息开头几个字；空 = 她最近一条
        let hint: String
    }

    /// 只在气泡对话的能力提示槽里加（文件库 / 语音同槽，过 applyMacros）
    static let promptHint = """
    <气泡对话>
    这是即时聊天式的对话。{{user}} 给你的消息贴表情时会立刻叫你一次（消息是「[附带事件]」开头）：想回就回一两句，也可以只贴个表情，觉得不用回就什么都不写。
    你也能给 {{user}} 的消息贴表情（像 iMessage 长按回应，表情挂在 ta 那条消息角上；正文里直接写 emoji 只是另发了一条消息）。要贴就在回复里单独写：
    ```react
    ❤️
    ```
    默认贴在 ta 最近一条消息上；要贴更早的，在表情后空一格写那条消息开头几个字。一次最多一个，这个块不会显示出来。
    </气泡对话>
    """

    /// 找到的协议块（按行号，左闭右开）。三种：
    /// - complete：```react / 一行内容 / ``` 收尾；
    /// - cutClose：收尾 fence 只写出 0–2 个反引号就到结尾了（输出截断 / 停止）——内容合法照样算数；
    /// - unclosed：内容那行还没写完就到结尾了，已写出的内容是空的或像「emoji[ 提示]」的开头。
    /// 开头 fence 认 ```react 后跟空格 / tab / \r；内容只认 emoji 规则。不合格的一律不算协议块，原样留着
    private enum Kind { case complete, cutClose, unclosed }

    private struct Found {
        let lines: Range<Int>
        let kind: Kind
        let intent: Intent?
    }

    private static func bare(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    private static func isOpenFence(_ line: String) -> Bool {
        let b = bare(line)
        return b.hasPrefix(blockTag) && b.dropFirst(blockTag.count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func closeText(_ line: String) -> String {
        var b = Substring(bare(line))
        while let last = b.last, last == " " || last == "\t" { b = b.dropLast() }
        return String(b)
    }

    private static func scan(_ lines: [String]) -> [Found] {
        var found: [Found] = []
        var i = 0
        let last = lines.count - 1
        while i <= last {
            guard isOpenFence(lines[i]) else { i += 1; continue }
            guard i < last else { found.append(Found(lines: i..<i + 1, kind: .unclosed, intent: nil)); break }
            let body = bare(lines[i + 1])
            if i + 1 == last {
                if body.isEmpty || looksLikeIntentStart(body) {
                    found.append(Found(lines: i..<i + 2, kind: .unclosed, intent: nil))
                }
                break
            }
            let close = closeText(lines[i + 2])
            if close == "```" {
                if let intent = intent(from: body) { found.append(Found(lines: i..<i + 3, kind: .complete, intent: intent)) }
                i += 3
                continue
            }
            if i + 2 == last, close.isEmpty || close == "`" || close == "``" {
                if let intent = intent(from: body) {
                    found.append(Found(lines: i..<i + 3, kind: .cutClose, intent: intent))
                } else if body.isEmpty {
                    found.append(Found(lines: i..<i + 3, kind: .unclosed, intent: nil))
                }
                break
            }
            i += 1
        }
        return found
    }

    /// 去掉选中的块，返回剩下的正文和这些块里的意向
    private static func remove(_ text: String, kinds: Set<Kind>) -> (text: String, intents: [Intent]) {
        guard text.contains(blockTag) else { return (text, []) }
        let lines = text.components(separatedBy: "\n")
        let picked = scan(lines).filter { kinds.contains($0.kind) }
        guard !picked.isEmpty else { return (text, []) }
        var drop = Set<Int>()
        for block in picked { drop.formUnion(block.lines) }
        var out = lines.indices.filter { !drop.contains($0) }.map { lines[$0] }.joined(separator: "\n")
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), picked.compactMap(\.intent))
    }

    static func parse(_ text: String) -> [Intent] {
        guard text.contains(blockTag) else { return [] }
        return scan(text.components(separatedBy: "\n")).compactMap(\.intent)
    }

    /// 只删合格的块（含收尾 fence 被截断的）；不合格的原样留着；块留下的连续空行压成一个
    static func strip(_ text: String) -> String {
        remove(text, kinds: [.complete, .cutClose]).text
    }

    /// 收口时（含用户停止、输出被截断）：末尾内容还没写完的 react 块丢掉（普通 React 代码不动）
    static func dropUnclosedTail(_ text: String) -> String {
        remove(text, kinds: [.unclosed]).text
    }

    /// 收口：三种块都去掉，返回剩下的正文和要贴的意向
    static func settle(_ text: String) -> (text: String, intents: [Intent]) {
        remove(text, kinds: [.complete, .cutClose, .unclosed])
    }

    /// 流式显示单个已写完的段落：三种块都藏起来（不让标记闪一下）
    static func streamingVisible(_ text: String) -> String {
        remove(text, kinds: [.complete, .cutClose, .unclosed]).text
    }

    /// 块里那一行：一个 emoji，可选再跟一个空格和提示文字
    private static func intent(from line: String) -> Intent? {
        guard let first = line.first, isEmoji(first) else { return nil }
        let rest = line.dropFirst()
        if rest.isEmpty { return Intent(emoji: String(first), hint: "") }
        guard rest.first == " " else { return nil }
        let hint = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return Intent(emoji: String(first), hint: hint)
    }

    /// 还没写完的内容行像不像表情协议：emoji 开头（可能只写出半个 emoji），后面没字或空一格接提示
    private static func looksLikeIntentStart(_ line: String) -> Bool {
        guard let first = line.first, let scalar = first.unicodeScalars.first,
              scalar.value > 0x7F, scalar.properties.isEmoji else { return false }
        let rest = line.dropFirst()
        return rest.isEmpty || rest.first == " "
    }

    static func isEmoji(_ c: Character) -> Bool {
        let scalars = c.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        return scalars.count > 1 && (scalars.first?.properties.isEmoji ?? false)
    }

    /// 从 content 和 segments 的 .text 段同步删块（两份副本，同 VoiceMessageWriter）；末尾没写完的块一并丢掉。返回解析出的意向
    static func consume(_ node: MessageNode) -> [Intent] {
        let fromContent = settle(node.content)
        var intents = fromContent.intents
        if node.content.contains(blockTag) { node.content = fromContent.text }
        if var segs = node.segments, segs.contains(where: { if case .text(let s) = $0 { return s.contains(blockTag) }; return false }) {
            var segIntents: [Intent] = []
            segs = segs.compactMap { seg in
                guard case .text(let s) = seg, s.contains(blockTag) else { return seg }
                let settled = settle(s)
                segIntents += settled.intents
                return settled.text.isEmpty ? nil : .text(settled.text)
            }
            if intents.isEmpty { intents = segIntents }
            node.setSegments(segs)
        }
        return intents
    }

    /// 贴到哪条：在这条回复自己的祖先链里（新 → 旧）找她的消息。
    /// 没提示文字 = 最近一条；提示正好是某条的节点 id（CC 照抄 `<channel>` 的 message_id）就是那条，不限条数；
    /// 否则只按「消息开头」在最近 20 条里匹配，第一条对上的就是；一条都对不上 = 不贴（nil）
    static func target(for intent: Intent, among ancestorsNewestFirst: [MessageNode]) -> MessageNode? {
        let all = ancestorsNewestFirst.filter {
            $0.role == "user" && !$0.isSyntheticRoot && !$0.isSourceHidden && !$0.isTrashed
        }
        let key = normalized(intent.hint)
        guard !key.isEmpty else { return all.first }
        if let exact = all.first(where: { $0.id.caseInsensitiveCompare(intent.hint) == .orderedSame }) { return exact }
        return all.prefix(20).first { normalized($0.content).hasPrefix(key) }
    }

    private static func normalized(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && !$0.isNewline && $0 != "…" && $0 != "「" && $0 != "」" })
    }

    /// 收口后什么都看不见：正文空，没有工具 / 附件 / 非空文字段（思考段不算）
    static func isSilent(_ node: MessageNode) -> Bool {
        let text = ContentCleaner.extractThinking(from: node.content).content
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !(node.segments ?? []).contains { seg in
            switch seg {
            case .thinking, .flag: return false
            case .text(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return true
            }
        }
    }
}
