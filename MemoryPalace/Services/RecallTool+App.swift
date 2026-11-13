import MemoryCore
import Foundation
import SwiftData

/// `RecallTool` 的 app 面：工具 schema / 文案、`Memory` 表 L1 检索、以及把 app 实现接进包的注入面。
/// 读 sidebar 本体已搬包（`MemoryCore.Services.Recall`）。
extension RecallTool {
    static let toolName = "recall"
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_content_convhistory") as? Bool) ?? true
    }
    static let toolDescription = """
    recall 每次只翻一层，op 必填：date 看记忆日 A4 主调/事件；window 看指定窗口 A3 与 A2 段目录；segment 看指定 A2 段；messages 看同分支 [from_node_id,to_node_id_exclusive) 原文。search 必须给 query 与 scope:a|c：a 按 A4→A3→A2→原文，c 按 wiki页→卡L0→L1/碎片→原文，首个命中层即停。exact=true 仅 search，表示只搜原文；include_invalid 仅用于 scope=c 且非 exact 的 search，扩展软失效旧档案，不恢复私密/未批准/删除来源。wiki 必须给 layer:index|page|entry|original，依次翻索引、页、条目L1、原料L2，只有 original 读 L2。直接使用返回的结构化 target 下钻，不猜路径、段号或版本。长内容用同 op + cursor 续读，不改 cursor；过期请从父层重新定位。默认每次正文≤3000、总回包≤4000字符，以本轮楼层限额为准；本轮达到调用上限后，余下下一轮继续。日期 YYYY-MM-DD，以楼层当前时区的05:00为日界；date 与 after/before 互斥，after含当天、before不含，无before只读after当日。默认排除当前窗口，显式 conversation_id 可读当前窗；窗口可用全ID或唯一至少8位前缀。引用带日期/原话与出处，记忆不是最终事实。
    """

    private static let properties: [String: Any] = [
        "op": ["type": "string", "enum": ["date", "window", "segment", "messages", "search", "wiki"]],
        "date": ["type": "string", "description": "YYYY-MM-DD，记忆日05:00起；与after/before互斥"],
        "after": ["type": "string", "description": "含起始记忆日；无before只读当日"],
        "before": ["type": "string", "description": "不含终止记忆日，须同时给after"],
        "conversation_id": ["type": "string", "description": "窗口全ID或唯一至少8位前缀"],
        "segment": ["type": "integer", "minimum": 0],
        "from_node_id": ["type": "string"],
        "to_node_id_exclusive": ["type": "string"],
        "query": ["type": "string"],
        "scope": ["type": "string", "enum": ["a", "c"]],
        "exact": ["type": "boolean"],
        "include_invalid": ["type": "boolean"],
        "layer": ["type": "string", "enum": ["index", "page", "entry", "original"]],
        "folder": ["type": "string", "description": "仅wiki/index，本层公开文件夹；空为根索引"],
        "target": targetSchema,
        "cursor": ["type": "string", "description": "工具签发的版本化续读凭据；同op续读，不接受任意offset"],
    ]

    private static var targetSchema: [String: Any] {
        let string = ["type": "string"]
        let page: [String: Any] = ["type": "object", "properties": ["profile_id": string, "path": string, "version": string], "required": ["profile_id", "path"], "additionalProperties": false]
        let row: [String: Any] = ["type": "object", "properties": ["page": page, "ordinal": ["type": "integer"], "line_hash": string], "required": ["page", "ordinal", "line_hash"], "additionalProperties": false]
        let card: [String: Any] = ["type": "object", "properties": ["page": page, "path": string, "version": string], "required": ["page", "path", "version"], "additionalProperties": false]
        return ["type": "object", "properties": [
            "tree": ["type": "string", "enum": ["a", "c"]], "layer": string,
            "conversation_id": string, "segment": ["type": "integer", "minimum": 0],
            "directory_revision": string, "last_node_id": string, "from_node_id": string,
            "to_node_id_exclusive": string, "branch_anchor": string, "date": string,
            "page": page, "row": row, "card": card, "source": ["type": "object"],
            "memory_id": string, "source_version": string, "query": string, "scope": string,
        ], "required": ["tree", "layer"], "additionalProperties": false]
    }

    static var definition: ToolDefinition {
        ToolDefinition(name: toolName, description: toolDescription, properties: properties, required: ["op"])
    }

    static func weightByPriority(_ ranked: [Memory]) -> [Memory] { priorityOrder(ranked.map(\.recallPriority)).map { ranked[$0] } }
    private static func priorityOrder(_ priorities: [Int]) -> [Int] {
        let scores = priorities.enumerated().map { rank, priority in (1 + 0.1 * Double(priority - 3)) / Double(61 + rank) }
        return priorities.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
    }
    static func searchL1(query: String?, profileId: String, includeInvalid: Bool, after: Date?, beforeExclusive: Date?,
                         context: ModelContext, embedder: MemoryEmbedding = AppleMemoryEmbedder.shared) -> L1Result {
        let store = SwiftDataMemoryStore()
        let pool = includeInvalid ? store.listAll(profileId: profileId, context: context) : store.listActive(profileId: profileId, context: context)
        let snapshots = pool.map { memory in
            (document: MemoryRetrievalDocument(memory), hit: MemoryHit(id: memory.id, content: memory.content, category: memory.category,
                createdAt: memory.createdAt, invalid: memory.supersededAt != nil, priority: memory.recallPriority,
                sourceConversationId: memory.sourceConversationId, sourceNodeId: memory.sourceNodeId, isFragment: memory.isFragment))
        }
        var ranked: [MemoryHit]
        var vectorStatus: String?
        if let query {
            let result = MemoryRetrieval.search(query: query, documents: snapshots.map(\.document), embedder: embedder)
            var lookup: [UUID: MemoryHit] = [:]
            for snapshot in snapshots where lookup[snapshot.hit.id] == nil { lookup[snapshot.hit.id] = snapshot.hit }
            let hits = result.ids.compactMap { lookup[$0] }
            ranked = priorityOrder(hits.map(\.priority)).map { hits[$0] }
            vectorStatus = result.vectorStatus
        } else { ranked = snapshots.map(\.hit).sorted { $0.createdAt > $1.createdAt } }
        if after != nil || beforeExclusive != nil { ranked = ranked.filter { inRange($0.createdAt, after: after, beforeExclusive: beforeExclusive) } }
        return L1Result(hits: ranked, vectorStatus: vectorStatus)
    }


    /// 碎片出处：`Memory` 表里按编号唯一命中（原 `RecallTool+Wiki.wikiFragment` 的查询部分）。
    static func locateFragment(_ label: String, state: Cursor, context: ModelContext) throws
        -> (memoryId: String, content: String, conversationId: String, nodeId: String)? {
        let pid = state.profileId
        let matches = try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.profileId == pid }))
            .filter { CatalogSources.label($0.id) == label }
        guard matches.count == 1, let memory = matches.first,
              let cid = memory.sourceConversationId, let nodeId = memory.sourceNodeId else { return nil }
        return (memory.id.uuidString, memory.content, cid, nodeId)
    }

    /// wiki 当前源解析（原 `RecallWikiReader.original` 里 `WikiProposalSources.current` 那一段）。
    /// 生产恒为 `floorBase: nil`（原 Reader 从不设底图），测试显式传底图。
    static func wikiCurrentResolver(floorBase: CatalogFloorBase?) -> RecallEnvironment.ResolveCurrent {
        { card, wiki, profileId, memoryRoot in
            let needsTask = card.layer == "Prompt" || card.layer == CatalogSurvey.layer
            var task: CatalogSeedTask?
            if needsTask, (try? SafeWiki.folder([WikiStore.proposalsFolder], under: wiki.root, create: false)) != nil {
                task = CatalogSeedTaskStore(wiki: wiki).all().first {
                    $0.profileId == profileId && $0.materials.contains { $0.path == card.path && $0.version == card.version && $0.sourceContext == card.sourceContext }
                }
            }
            let current = WikiProposalSources.current(paths: [card.path], layers: [card.path: card.layer], task: task,
                floorBase: floorBase, memoryRoot: memoryRoot, wiki: wiki)[card.path]
            switch current {
            case .present(let value, let version):
                return RecallWikiCurrent(text: value, currentVersion: version,
                                         missing: version == card.version ? .currentSameVersion : .changed)
            case .empty: return RecallWikiCurrent(missing: .empty)
            case .missing: return RecallWikiCurrent(missing: card.layer == "Prompt" ? .slotDeleted : .fileMissing)
            case .resegmented: return RecallWikiCurrent(missing: .resegmented)
            case .contextChanged: return RecallWikiCurrent(missing: .contextChanged)
            case .legacySegmentation: return RecallWikiCurrent(missing: .legacySegmentation)
            case .unreadable(let why): return RecallWikiCurrent(missing: .unreadable(why))
            case nil: return nil
            }
        }
    }

    /// 包里的读侧需要 `Memory` 表 / 嵌入，刀 3 之前只在 app 实现；签名保持原样，测试直接调。
    static func l1Environment(container: ModelContainer, embedder: any MemoryEmbedding = AppleMemoryEmbedder.shared) -> RecallEnvironment {
        RecallEnvironment(
            searchL1: { query, profileId, includeInvalid, after, before in
                let context = ModelContext(container)
                context.autosaveEnabled = false
                return searchL1(query: query, profileId: profileId, includeInvalid: includeInvalid,
                                after: after, beforeExclusive: before, context: context, embedder: embedder)
            },
            locateFragment: { label, state in
                let context = ModelContext(container)
                context.autosaveEnabled = false
                return try RecallTool.locateFragment(label, state: state, context: context)
            },
            resolveCurrent: wikiCurrentResolver(floorBase: nil))
    }
}
