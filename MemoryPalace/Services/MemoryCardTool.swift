import MemoryCore
import Foundation
import SwiftData

/// 助手对记忆条目的手（粟粟 11-14「把每个记忆都暴露接口」）：加 / 改 / 删 / 恢复 / 钉 / 取消钉。
/// 读和搜不在这里：`recall` 搜得到卡（带 memory_id），`fs_search / fs_read` 读得到 `memory/cards/`（`MemoryCardFolder`）。
/// 权限 = 「记忆条目」域三档（`PermissionDomain.memoryCards`，每次询问 = 一笔一问），闸在工具循环头；
/// 每一笔走 `MemoryAuditLog` 留痕（操作人 = 助手名），她在记忆日志里能 Undo。不改库结构
enum MemoryCardTool {
    static let toolName = "memory_card"

    enum Action: String, CaseIterable {
        case add, edit, delete, restore, pin, unpin

        /// 记进日志、回给模型的动作名
        var done: String {
            switch self {
            case .add: return "加好了"
            case .edit: return "改好了"
            case .delete: return "删了"
            case .restore: return "放回来了"
            case .pin: return "钉住了"
            case .unpin: return "取消钉住了"
            }
        }
    }

    /// 记忆总开关开着才给；本窗「记忆参与」和权限档位在注册表 / 执行处另查
    static var enabled: Bool { MemoryFlags.masterEnabled }

    static let toolDescription = """
    记忆条目：从聊天里一条条记下来的事实（关于对方、关于你、你们之间的事），每条一句话。用这个工具自己动这些条目：add 新加一条；edit 改一条（只传要改的那几项）；delete 删一条（进已删除，还能恢复）；restore 把删掉的放回来；pin 钉住（之后每轮都带着）；unpin 取消钉住。除 add 外都要给 id：recall 搜到的 memory_id，或 fs_search / fs_read 在 memory/cards/ 里看到的那份文件的路径。正文写成不看上下文也读得懂的一句完整的话，用名字，不用「我 / 你 / 他」，例：「岚舟每周三去槐序巷皮影作坊学雕皮影」。发现哪条记错了、过时了就改或删，不要另加一条意思相反的。每一笔对方都看得到、能撤回；对方可能要先点允许才生效，被拒绝了就照实说，不要再试。也可以不用这个工具，直接用 fs_write / fs_edit / fs_delete 改 memory/cards/ 下那一条的文件，是同一回事。
    """

    private static let properties: [String: Any] = [
        "action": ["type": "string", "enum": Action.allCases.map(\.rawValue),
                   "description": "add = 新加；edit = 改；delete = 删（能恢复）；restore = 把删掉的放回来；pin = 钉住；unpin = 取消钉住"] as [String: Any],
        "id": ["type": "string", "description": "要动哪一条：recall 给的 memory_id，或 memory/cards/ 里那份文件的路径。除 add 外必填"] as [String: Any],
        "content": ["type": "string", "description": "正文，一句完整的话。add 必填；edit 时给了就整句换掉"] as [String: Any],
        "subject": ["type": "string", "description": "这一条说的是谁 / 什么，写名字，如「岚舟」"] as [String: Any],
        "speaker": ["type": "string", "enum": FragmentPool.speakers,
                    "description": "这件事是谁说的：用户自述 = 对方自己说的；AI 观察 = 你看出来的；AI 承诺 = 你答应过的"] as [String: Any],
        "tags": ["type": "array", "items": ["type": "string"], "description": "几个短标签，如 [\"皮影\", \"周三\"]；edit 时给了就整组换掉"] as [String: Any],
        "importance": ["type": "integer", "description": "1–5，越大越容易被想起来"] as [String: Any],
        "confidence": ["type": "integer", "description": "0–100，这件事有多确定"] as [String: Any],
        "pin": ["type": "boolean", "description": "只在 add 时用：加的同时钉住"] as [String: Any],
        "reason": ["type": "string", "description": "一句话：为什么动这一条（记进日志给对方看）"] as [String: Any],
    ]

    static var definition: ToolDefinition {
        ToolDefinition(name: toolName, description: toolDescription, properties: properties, required: ["action"])
    }

    /// 进工具提示「〔我的记忆〕」那一段的一行（`SelfMemoryTool.systemHint` 拼）
    static let hintLine = "- 从聊天里记下的记忆条目（一条一句事实）：加、改、删、钉用 memory_card，或直接改 memory/cards/ 下那一条的文件；找的时候用 recall，或 fs_search / fs_read 翻 memory/cards/。"

    struct Result: Equatable {
        let text: String
        let isError: Bool
    }

    /// 日志里的操作人：这层楼助手的名字（空的写「助手」）
    static func actorName(_ assistantName: String) -> String {
        MemoryAudit.cleaned(assistantName) ?? "助手"
    }

    // MARK: - 找卡

    enum Lookup: Equatable {
        case found(UUID)
        case missing
        /// 给的是开头几位，对上了不止一张
        case ambiguous(Int)
    }

    /// `id` 可以是完整编号、开头至少 8 位、或 `memory/cards/…/3f2a9c1b.md` 这样的路径（取文件名；老的 `.txt` 结尾也认）
    static func lookup(_ raw: String, in ids: [UUID]) -> Lookup {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = token.split(separator: "/").last { token = String(last) }
        token = token.lowercased()
        for ext in [MemoryCardFolder.fileExtension, ".txt"] where token.hasSuffix(ext) { token = String(token.dropLast(ext.count)) }
        if let id = UUID(uuidString: token) { return ids.contains(id) ? .found(id) : .missing }
        guard token.count >= 8, token.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return .missing }
        let matches = ids.filter { $0.uuidString.lowercased().hasPrefix(token) }
        switch matches.count {
        case 0: return .missing
        case 1: return .found(matches[0])
        default: return .ambiguous(matches.count)
        }
    }

    private static func args(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private static func int(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    /// 询问卡上多出的一行：要动的那张现在写的是什么（add 没有这一行，正文就在参数里）
    @MainActor
    static func permissionDetail(argumentsJSON: String, profileId: String, context: ModelContext) -> String? {
        let a = args(argumentsJSON)
        guard let action = (a["action"] as? String).flatMap(Action.init(rawValue:)), action != .add else { return nil }
        let raw = (a["id"] as? String) ?? ""
        let all = SwiftDataMemoryStore().listAll(profileId: profileId, context: context)
        guard case .found(let id) = lookup(raw, in: all.map(\.id)), let m = all.first(where: { $0.id == id }) else {
            return "没找到这条记忆条目：\(raw)"
        }
        let about = MemoryAudit.cleaned(m.subject).map { "（About \($0)）" } ?? ""
        return "这条记忆条目现在写的是：「\(m.content)」\(about)"
    }

    // MARK: - 执行

    /// add 出来的条目的出处：触发这一轮的那条用户消息（Edit 页据此显示原话、跳回对话）
    struct Source: Sendable {
        let nodeId: String
        let text: String
    }

    /// 这条助手回复是回哪条用户消息的：顺着父节点往上，跳过夹在中间的工具 / 系统节点；
    /// 上面先碰到的是另一条助手消息（续写这类，没有用户消息触发）= 没有出处
    @MainActor
    static func source(of assistantNode: MessageNode, context: ModelContext) -> Source? {
        var next = assistantNode.parentId
        for _ in 0..<16 {
            guard let id = next else { return nil }
            var descriptor = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let node = try? context.fetch(descriptor).first, node.role != "assistant" else { return nil }
            if node.role == "user" { return Source(nodeId: node.id, text: node.content) }
            next = node.parentId
        }
        return nil
    }

    /// 在主线程跑（改的是界面那份 context）。`memoryEnabled` = 这场对话的「记忆参与」；`actor` = 助手名；
    /// `via` = 记进日志的来处（聊天里 = `viaChat`，CC 那头 = `viaCC`）；`source` = add 的出处（聊天里给，CC 那头没有对话节点不给）
    @MainActor
    static func execute(inputJSON: String, profileId: String, conversationId: String?, memoryEnabled: Bool, actor: String,
                        via: String = MemoryAuditLog.viaChat, source: Source? = nil, context: ModelContext, now: Date = Date()) -> Result {
        guard enabled else { return Result(text: "记忆总开关关着，记忆条目现在动不了", isError: true) }
        guard memoryEnabled else { return Result(text: "这场对话关了记忆参与，不能动记忆条目", isError: true) }
        let a = args(inputJSON)
        guard let action = (a["action"] as? String).flatMap(Action.init(rawValue:)) else {
            return Result(text: "action 只能是 \(Action.allCases.map(\.rawValue).joined(separator: " / "))", isError: true)
        }
        let store = SwiftDataMemoryStore()
        let all = store.listAll(profileId: profileId, context: context)
        let reason = MemoryAudit.cleaned(a["reason"] as? String)
        let who = actorName(actor)

        if action == .add {
            guard let content = MemoryAudit.cleaned(a["content"] as? String) else {
                return Result(text: "add 要给非空的 content", isError: true)
            }
            if let same = all.first(where: { $0.supersededAt == nil && $0.content == content }) {
                return Result(text: "已经有一条一样的了（id \(short(same.id))），没有再加", isError: false)
            }
            let m = store.insertUnsaved(content: content, category: MemoryCardFolder.plainCategory,
                                        keywords: MemoryAudit.cleanedTags(a["tags"] as? [String] ?? []), profileId: profileId,
                                        isUserExplicit: a["pin"] as? Bool ?? false, extractedBy: toolName,
                                        sourceConversationId: conversationId, sourceQuote: source.flatMap { MemoryEntryLine.quote($0.text) },
                                        sourceNodeId: source?.nodeId, context: context)
            // 和写手写的卡同一种：有发生日（进得了对话、整理得到）；她允许过才落的库，直接算批过。不记「她亲手改过」
            m.occurredDay = MemoryDay.key(now)
            m.subject = MemoryAudit.cleaned(a["subject"] as? String)
            m.speaker = speaker(a["speaker"])
            m.importance = int(a["importance"]).map { min(max($0, 1), 5) }
            m.confidence = int(a["confidence"]).map { min(max($0, 0), 100) }
            m.createdAt = now
            m.updatedAt = now
            m.reviewedAt = now
            do { try context.save() } catch {
                context.delete(m)
                return Result(text: "写入失败：\(error.localizedDescription)", isError: true)
            }
            log([MemoryAuditLog.added(m, now: now)], action: .add, actor: who, via: via, reason: reason, profileId: profileId, now: now)
            return Result(text: "\(action.done)：「\(content)」（id \(short(m.id))）。对方能在记忆日志里撤回", isError: false)
        }

        let raw = (a["id"] as? String) ?? ""
        let found = lookup(raw, in: all.map(\.id))
        if case .ambiguous(let n) = found { return Result(text: "「\(raw)」对上了 \(n) 条记忆条目，给完整的 id", isError: true) }
        guard case .found(let id) = found, let m = all.first(where: { $0.id == id }) else {
            return Result(text: "没找到这条记忆条目：\(raw)。先用 recall 搜，或 fs_search 在 memory/cards/ 里找，拿到 id 再来", isError: true)
        }
        let before = MemoryAuditLog.CardState(m)
        switch action {
        case .add:
            break
        case .edit:
            guard m.supersededAt == nil else { return Result(text: "这条已经删了，要改先 restore", isError: true) }
            if a["content"] != nil {
                guard let content = MemoryAudit.cleaned(a["content"] as? String) else { return Result(text: "content 不能是空的；不要这条就用 delete", isError: true) }
                if content != m.content {
                    m.content = content
                    m.tokenCount = Memory.estimateTokens(content)
                    m.embeddingData = nil
                }
            }
            if a["subject"] != nil { m.subject = MemoryAudit.cleaned(a["subject"] as? String) }
            if a["speaker"] != nil { m.speaker = speaker(a["speaker"]) }
            if let tags = a["tags"] as? [String] { m.keywords = MemoryAudit.cleanedTags(tags) }
            if let v = int(a["importance"]) { m.importance = min(max(v, 1), 5) }
            if let v = int(a["confidence"]) { m.confidence = min(max(v, 0), 100) }
            guard MemoryAuditLog.CardState(m) != before else { return Result(text: "没有变化：给的和这条现在的一样", isError: false) }
            // 她允许过的改动 = 这张她看过了，算批过；不记「她亲手改过」，置信度不自动变
            m.updatedAt = now
            m.reviewedAt = now
        case .delete:
            guard m.supersededAt == nil else { return Result(text: "这条已经在已删除里了", isError: false) }
            MemoryAudit.trash([m], now: now)
        case .restore:
            guard m.supersededAt != nil else { return Result(text: "这条没被删，不用放回", isError: false) }
            MemoryAudit.restore([m])
            m.updatedAt = now
        case .pin, .unpin:
            guard m.supersededAt == nil else { return Result(text: "这条已经删了，要钉先 restore", isError: true) }
            let pin = action == .pin
            guard m.isUserExplicit != pin else { return Result(text: pin ? "这条本来就钉着" : "这条本来就没钉", isError: false) }
            m.isUserExplicit = pin
            if pin { m.decayWeight = 1.0 }
            m.updatedAt = now
        }
        do { try context.save() } catch {
            before.apply(to: m)
            return Result(text: "写入失败：\(error.localizedDescription)", isError: true)
        }
        log([(m.id, before, MemoryAuditLog.CardState(m), nil)], action: nil, actor: who, via: via, reason: reason, profileId: profileId, now: now)
        return Result(text: "\(action.done)：「\(m.lineText)」（id \(short(m.id))）。对方能在记忆日志里撤回", isError: false)
    }

    private static func speaker(_ value: Any?) -> String? {
        guard let s = MemoryAudit.cleaned(value as? String), FragmentPool.speakers.contains(s) else { return nil }
        return s
    }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    /// 存成了才记一笔；记不进文件不拦操作（那一笔撤不回，同整理台）。记完通知界面刷新
    @MainActor
    private static func log(_ changes: [(card: UUID, before: MemoryAuditLog.CardState, after: MemoryAuditLog.CardState?, full: MemoryAuditLog.FullCard?)],
                            action: MemoryAuditLog.Action?, actor: String, via: String, reason: String?, profileId: String, now: Date) {
        if let entry = MemoryAuditLog.entry(changes, actor: actor, note: reason, action: action, via: via, now: now) {
            try? MemoryAuditLog.append(entry, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }
}
