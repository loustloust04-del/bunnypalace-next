import Foundation
import SwiftData

/// Claude 记忆 → 花园记忆（#043 plan §3.3a，D4）。不联网、不调模型：一段一条，之后园丁照常整理。
/// 记忆文件（memory_files，新版才有，量大）不进花园记忆，交给文件库（D4c）。
enum ClaudeMemoryImporter {
    /// 写进 `Memory.extractedBy`，记忆页能按来源认出来，再导一次靠它去重
    static let source = "claude-export"
    static let maxChunk = 600

    struct Parsed: Equatable {
        var conversationMemory: [String] = []
        /// (项目 uuid, 文本)
        var projectMemories: [ProjectMemory] = []
        var memoryFiles: [MemoryFile] = []
    }

    struct ProjectMemory: Equatable {
        let projectId: String
        let text: String
    }

    struct MemoryFile: Equatable {
        let path: String
        let content: String
    }

    struct Draft: Equatable {
        let content: String
        let category: String
    }

    /// 三种形状按键认：A/B 代数组、C 代对象、更老的「一行一条」数组（每行取 content / memory）。
    /// 返回认不出的文件名。
    static func parse(_ urls: [URL]) -> (Parsed, unrecognized: [String]) {
        var parsed = Parsed()
        var bad: [String] = []
        for url in urls {
            guard let data = try? ExportJSON.data(at: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                bad.append(url.lastPathComponent)
                continue
            }
            let rows: [Any] = (obj as? [Any]) ?? [obj]
            var understood = false
            for row in rows {
                guard let dict = row as? [String: Any] else { continue }
                var rowUnderstood = false
                if let text = dict["conversations_memory"] as? String {
                    parsed.conversationMemory.append(text)
                    rowUnderstood = true
                }
                if let projects = dict["project_memories"] as? [String: Any] {
                    for (id, value) in projects.sorted(by: { $0.key < $1.key }) {
                        if let text = value as? String { parsed.projectMemories.append(.init(projectId: id, text: text)) }
                    }
                    rowUnderstood = true
                }
                if let files = dict["memory_files"] as? [[String: Any]] {
                    for file in files {
                        guard let path = file["path"] as? String, let content = file["content"] as? String else { continue }
                        parsed.memoryFiles.append(.init(path: path, content: content))
                    }
                    rowUnderstood = true
                }
                if !rowUnderstood, let text = (dict["content"] as? String) ?? (dict["memory"] as? String) {
                    parsed.conversationMemory.append(text)
                    rowUnderstood = true
                }
                understood = understood || rowUnderstood
            }
            if !understood { bad.append(url.lastPathComponent) }
        }
        return (parsed, bad)
    }

    /// 拆成花园记忆草稿：按行一段一条，超长的按句切，不丢字；项目记忆加项目名前缀
    static func drafts(_ parsed: Parsed, projectNames: [String: String]) -> [Draft] {
        var out: [Draft] = []
        for text in parsed.conversationMemory {
            out += split(text).map { Draft(content: $0, category: "context") }
        }
        for memory in parsed.projectMemories {
            let name = projectNames[memory.projectId] ?? String(memory.projectId.prefix(8))
            out += split(memory.text).map { Draft(content: "（Claude 项目「\(name)」）\($0)", category: "context") }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.content).inserted }
    }

    static func split(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let para = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !para.isEmpty else { continue }
            out += chunk(para)
        }
        return out
    }

    /// 超过 maxChunk 字的段按句末标点切，单句还超长就硬切
    private static func chunk(_ para: String) -> [String] {
        guard para.count > maxChunk else { return [para] }
        var sentences: [String] = []
        var current = ""
        for ch in para {
            current.append(ch)
            if "。！？!?；;".contains(ch) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }

        var out: [String] = []
        var buffer = ""
        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            buffer = ""
        }
        for sentence in sentences {
            if buffer.count + sentence.count > maxChunk { flush() }
            if sentence.count > maxChunk {
                var rest = Substring(sentence)
                while rest.count > maxChunk {
                    buffer = String(rest.prefix(maxChunk))
                    flush()
                    rest = rest.dropFirst(maxChunk)
                }
                buffer = String(rest)
            } else {
                buffer += sentence
            }
        }
        flush()
        return out
    }

    /// 写进本楼层花园记忆。已有同来源同内容的跳过（再导一次不翻倍）；新建的每条记一行
    /// `createdMemory` 变更，撤回导入时删。不钉住（D4b）。
    /// `extractedBy`：来源标记，别的导入源（RikkaHub…）传自己的
    static func apply(_ drafts: [Draft], profileId: String, recordId: UUID, extractedBy: String = source,
                      context: ModelContext) throws -> (added: Int, existing: Int) {
        let pid = profileId, src = extractedBy
        let have = try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate {
            $0.profileId == pid && $0.extractedBy == src
        }))
        var known = Set(have.map(\.content))
        var added = 0, existing = 0
        for draft in drafts {
            guard known.insert(draft.content).inserted else {
                existing += 1
                continue
            }
            let memory = Memory(content: draft.content, category: draft.category, profileId: profileId,
                                isUserExplicit: false, extractedBy: extractedBy)
            context.insert(memory)
            // 记下导入时的原文：撤回时内容变了（园丁 / 你改过）就留着不删
            context.insert(ImportConversationChange(recordId: recordId, conversationId: memory.id.uuidString,
                                                    changeKind: .createdMemory,
                                                    beforeConversationData: Data(draft.content.utf8),
                                                    profileId: profileId))
            added += 1
        }
        try context.save()
        return (added, existing)
    }
}
