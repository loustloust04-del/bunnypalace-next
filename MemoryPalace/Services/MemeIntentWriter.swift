import Foundation
import SwiftData

// MARK: - AI 发表情包（plan-AI表情包）
// 气泡对话的 system 前缀给一份名字清单 → AI 单写 ```meme 块 → 收口时换成独立一段 [meme:UUID]
// （存 UUID：她改名 / 同名新增不动旧消息）→ 气泡里那一块画成无底表情包；发回模型换成〖表情包：名字——描述〗。

enum MemeIntentWriter {
    static let blockTag = "```meme"
    static let enabledKey = "memeAIMaySend"

    /// 设置 › 贴纸 › 表情包「让 AI 也能发」，默认开
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: 教

    /// 气泡对话才调；开关关 / 本楼层没表情包 → nil
    static func promptHint(profileId: String, context: ModelContext) -> String? {
        guard enabled else { return nil }
        return hintText(names: library(profileId: profileId, context: context).map(\.name))
    }

    /// 只给名字（省 token）；按建库顺序、同名只列一次 → 库不变就逐字不变，吃 prompt 缓存
    static func hintText(names: [String]) -> String? {
        var seen = Set<String>()
        let list = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !list.isEmpty else { return nil }
        return """
        <表情包>
        你可以给 {{user}} 发表情包（像聊天软件里发一张表情图，单独成一条）。能用的：\(list.joined(separator: "、"))
        想发就在回复里单独写一个块，块里只写名字：
        ```meme
        名字
        ```
        偶尔用，别每句都发；只能用上面清单里的名字。
        </表情包>
        """
    }

    // MARK: 收口

    /// 两挂点共用（ContentView 收口订阅 + CVM CC 回复落地）。无块零成本；换完不含块 = 天然幂等
    static func processChatIntents(nodeId: String, context: ModelContext) {
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        guard let node = (try? context.fetch(nodeDesc))?.first, node.role == "assistant",
              node.content.contains(blockTag) || node.content.contains(bracketHead) else { return }
        let memes = library(profileId: node.profileId, context: context)
        let lookup: (String) -> UUID? = { pick(named: $0, in: memes)?.id }
        // 两容器（content + segments 的 .text，工具轮消息是同一文本两份）同步换，同 VoiceMessageWriter
        node.content = resolve(node.content, lookup: lookup)
        if var segs = node.segments {
            var changed = false
            for i in segs.indices {
                if case .text(let s) = segs[i] {
                    let r = resolve(s, lookup: lookup)
                    if r != s { segs[i] = .text(r); changed = true }
                }
            }
            if changed { node.setSegments(segs) }
        }
        try? context.save()
    }

    private static let bracketHead = "〖表情包："
    private static let fenceRegex = try! NSRegularExpression(pattern: "```meme[ \\t]*\\n?[ \\t]*([^`\\n]+?)[ \\t]*\\n?[ \\t]*```")
    /// 模型学历史写的：独占一段的〖表情包：名字〗/〖表情包：名字——描述〗
    private static let bracketRegex = try! NSRegularExpression(pattern: "(?m)^[ \\t]*〖表情包：([^〗\\n]+?)(?:——[^〗\\n]*)?〗[ \\t]*$")

    /// 块 → 独立一段记号；块里名字查不到 → 一行〖表情包：名字〗（不吞，她看得到 AI 想发啥）；〖〗写法查不到原样留着
    static func resolve(_ text: String, lookup: (String) -> UUID?) -> String {
        var out = replace(fenceRegex, in: text) { name in
            lookup(name).map(MemeToken.make) ?? MemeToken.promptText(name: name, detail: nil)
        }
        out = replace(bracketRegex, in: out) { name in lookup(name).map(MemeToken.make) }
        guard out != text else { return text }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 每个匹配换成「前后空行 + 替换文字」（自成一泡）；make 返回 nil = 不换
    private static func replace(_ regex: NSRegularExpression, in text: String, make: (String) -> String?) -> String {
        let ns = text as NSString
        var out = text
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard let replacement = make(name) else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: "\n\n\(replacement)\n\n")
        }
        return out
    }

    // MARK: 显示 / 发回模型

    /// 段落是还没换成记号的 meme 块 → 藏（流式中 + 收口换图前那一下，不让代码块闪）
    static func visible(_ block: String) -> String {
        block.trimmingCharacters(in: .whitespaces).hasPrefix(blockTag) ? "" : block
    }

    /// AI 回复里独立一段的记号 → 文字（发回模型带描述；复制 / 文章模式不带）
    static func textForm(_ content: String, detail: Bool, fetch: (UUID) -> ChatMeme?) -> String {
        guard content.contains("[meme:") else { return content }
        return content.components(separatedBy: "\n\n").map { para in
            guard let id = MemeToken.match(para) else { return para }
            let meme = fetch(id)
            return MemeToken.promptText(name: meme?.name, detail: detail ? meme?.detail : nil)
        }.joined(separator: "\n\n")
    }

    // MARK: 库

    private static func library(profileId: String, context: ModelContext) -> [ChatMeme] {
        let fd = FetchDescriptor<ChatMeme>(predicate: #Predicate { $0.profileId == profileId },
                                           sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(fd)) ?? []
    }

    /// 同名：她最近发过的那张优先，没发过就最早建的
    static func pick(named name: String, in memes: [ChatMeme]) -> ChatMeme? {
        memes.filter { $0.name == name }.min { a, b in
            switch (a.lastSentAt, b.lastSentAt) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.createdAt < b.createdAt
            }
        }
    }
}
