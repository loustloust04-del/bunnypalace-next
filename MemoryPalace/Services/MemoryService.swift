import MemoryCore
import Foundation
import SwiftData
import NaturalLanguage

// MARK: - Memory Store Protocol

protocol MemoryStore {
    // CRUD
    @discardableResult
    func add(content: String, category: String, keywords: [String],
             profileId: String, isUserExplicit: Bool, extractedBy: String,
             sourceConversationId: String?, sourceQuote: String?, sourceNodeId: String?,
             context: ModelContext) throws -> Memory
    /// 同 `add` 但只插入不存：调用方把别的字段赋好后自己存一次（C2 写库，10-16 astra #5）
    func insertUnsaved(content: String, category: String, keywords: [String],
                       profileId: String, isUserExplicit: Bool, extractedBy: String,
                       sourceConversationId: String?, sourceQuote: String?, sourceNodeId: String?,
                       context: ModelContext) -> Memory
    func update(id: UUID, content: String, keywords: [String],
                sourceQuote: String?, sourceNodeId: String?, context: ModelContext) throws
    func delete(id: UUID, context: ModelContext) throws
    func supersede(id: UUID, context: ModelContext) throws

    // 查询
    func listHot(profileId: String, context: ModelContext) -> [Memory]
    func listHotAndWarm(profileId: String, context: ModelContext) -> [Memory]
    func listActive(profileId: String, context: ModelContext) -> [Memory]
    func listAll(profileId: String, context: ModelContext) -> [Memory]

    // 生命周期
    func recordAccess(ids: [UUID], context: ModelContext) throws
    func applyDecay(profileId: String, context: ModelContext) throws

    // 召回卡片相关性反馈
    func applyFeedback(id: UUID, vote: Int, previousVote: Int?, context: ModelContext) throws
}

// 旧签名便利重载：手动添加/编辑（设置 › 记忆的 mac 条目区等）不带出处，走 nil
extension MemoryStore {
    @discardableResult
    func add(content: String, category: String, keywords: [String],
             profileId: String, isUserExplicit: Bool, extractedBy: String,
             sourceConversationId: String?, context: ModelContext) throws -> Memory {
        try add(content: content, category: category, keywords: keywords,
                profileId: profileId, isUserExplicit: isUserExplicit, extractedBy: extractedBy,
                sourceConversationId: sourceConversationId, sourceQuote: nil, sourceNodeId: nil,
                context: context)
    }

    func update(id: UUID, content: String, keywords: [String], context: ModelContext) throws {
        try update(id: id, content: content, keywords: keywords,
                   sourceQuote: nil, sourceNodeId: nil, context: context)
    }
}

// MARK: - SwiftData Memory Store

struct SwiftDataMemoryStore: MemoryStore {

    @discardableResult
    func add(content: String, category: String, keywords: [String],
             profileId: String, isUserExplicit: Bool, extractedBy: String,
             sourceConversationId: String?, sourceQuote: String?, sourceNodeId: String?,
             context: ModelContext) throws -> Memory {
        let memory = insertUnsaved(content: content, category: category, keywords: keywords, profileId: profileId,
                                   isUserExplicit: isUserExplicit, extractedBy: extractedBy, sourceConversationId: sourceConversationId,
                                   sourceQuote: sourceQuote, sourceNodeId: sourceNodeId, context: context)
        try context.save()
        return memory
    }

    func insertUnsaved(content: String, category: String, keywords: [String],
                       profileId: String, isUserExplicit: Bool, extractedBy: String,
                       sourceConversationId: String?, sourceQuote: String?, sourceNodeId: String?,
                       context: ModelContext) -> Memory {
        let memory = Memory(
            content: content,
            category: category,
            keywords: keywords,
            profileId: profileId,
            isUserExplicit: isUserExplicit,
            extractedBy: extractedBy,
            sourceConversationId: sourceConversationId
        )
        memory.sourceQuote = sourceQuote
        memory.sourceNodeId = sourceNodeId
        context.insert(memory)
        return memory
    }

    func update(id: UUID, content: String, keywords: [String],
                sourceQuote: String?, sourceNodeId: String?, context: ModelContext) throws {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.id == id }
        )
        guard let memory = try context.fetch(descriptor).first else { return }
        memory.content = content
        memory.keywords = keywords
        memory.tokenCount = Memory.estimateTokens(content)
        memory.updatedAt = Date()
        memory.userEditedAt = memory.updatedAt   // 只有召回卡片 / mac 条目区两个界面在调 = 人手改的
        // 出处只在有新校验通过的 quote 时覆盖（nil = 保留原始出处不动）
        if let sourceQuote {
            memory.sourceQuote = sourceQuote
            memory.sourceNodeId = sourceNodeId
        }
        try context.save()
    }

    func supersede(id: UUID, context: ModelContext) throws {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.id == id }
        )
        guard let memory = try context.fetch(descriptor).first else { return }
        memory.supersededAt = Date()
        memory.updatedAt = Date()
        try context.save()
    }

    func delete(id: UUID, context: ModelContext) throws {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.id == id }
        )
        if let memory = try context.fetch(descriptor).first {
            context.delete(memory)
            try context.save()
        }
    }

    func listHot(profileId: String, context: ModelContext) -> [Memory] {
        let hotThreshold = 0.3
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in
                m.profileId == profileId && (m.isUserExplicit == true || m.decayWeight >= hotThreshold)
            },
            sortBy: [SortDescriptor(\Memory.decayWeight, order: .reverse)]
        )
        // supersededAt 内存层过滤（不进 predicate——SwiftData optional 谓词静默匹配不到）
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.supersededAt == nil }
    }

    func listHotAndWarm(profileId: String, context: ModelContext) -> [Memory] {
        let warmThreshold = 0.05
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in
                m.profileId == profileId && (m.isUserExplicit == true || m.decayWeight >= warmThreshold)
            },
            sortBy: [SortDescriptor(\Memory.decayWeight, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.supersededAt == nil }
    }

    /// 刀4（plan-memory-usable）：全量在场——注入资格 = 未 superseded，不再按衰减权重过滤。
    /// "在场"与衰减解耦；44 条量级塞得进 10000 token 预算，检索管线只活在 recall 工具里。
    func listActive(profileId: String, context: ModelContext) -> [Memory] {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.profileId == profileId },
            sortBy: [SortDescriptor(\Memory.createdAt, order: .forward)]
        )
        // supersededAt 内存层过滤（不进 predicate——SwiftData optional 谓词静默匹配不到）
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.supersededAt == nil }
    }

    func listAll(profileId: String, context: ModelContext) -> [Memory] {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.profileId == profileId },
            sortBy: [SortDescriptor(\Memory.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func recordAccess(ids: [UUID], context: ModelContext) throws {
        for id in ids {
            let descriptor = FetchDescriptor<Memory>(
                predicate: #Predicate<Memory> { m in m.id == id }
            )
            if let memory = try context.fetch(descriptor).first {
                DecayEngine.reinforce(memory)
            }
        }
        try context.save()
    }

    func applyDecay(profileId: String, context: ModelContext) throws {
        let all = listAll(profileId: profileId, context: context)
        DecayEngine.applyDecay(memories: all)
        try context.save()
    }

    /// 召回卡片 👍/👎。只调排序权重不做硬过滤（M8 教训：防"冷者愈冷"恶性循环）。
    /// - 👍 = reinforce（+0.2 / accessCount+1，与 recall 命中同款强化信号）
    /// - 👎 = decayWeight −0.3（clamp 0）+ feedbackDownCount+1；累计 ≥2 → 软失效（isUserExplicit 豁免，面板可复活）
    /// - previousVote 非 nil = 改投，先对称回滚旧票再施新票；回滚 👎 使计数落回 <2 时解除本机制打的软失效
    func applyFeedback(id: UUID, vote: Int, previousVote: Int?, context: ModelContext) throws {
        let descriptor = FetchDescriptor<Memory>(
            predicate: #Predicate<Memory> { m in m.id == id }
        )
        guard let memory = try context.fetch(descriptor).first else { return }
        let before = memory.decayWeight

        if let prev = previousVote, prev != vote {
            if prev > 0 {
                memory.decayWeight = max(0, memory.decayWeight - 0.2)
                memory.accessCount = max(0, memory.accessCount - 1)
            } else if prev < 0 {
                memory.decayWeight = min(1.0, memory.decayWeight + 0.3)
                memory.feedbackDownCount = max(0, memory.feedbackDownCount - 1)
                if memory.feedbackDownCount < 2, memory.supersededAt != nil {
                    memory.supersededAt = nil   // 误踩纠回：解除反馈触发的软失效
                }
            }
        }

        if vote > 0 {
            DecayEngine.reinforce(memory)
        } else if vote < 0 {
            memory.decayWeight = max(0, memory.decayWeight - 0.3)
            memory.feedbackDownCount += 1
            if memory.feedbackDownCount >= 2, !memory.isUserExplicit, memory.supersededAt == nil {
                memory.supersededAt = Date()
            }
        }
        memory.updatedAt = Date()
        try context.save()

        let arrow = vote > 0 ? "👍" : "👎"
        CacheDiagLog.shared.log("记忆反馈: \(arrow) \(memory.id.uuidString.prefix(8)) w\(String(format: "%.2f", before))→\(String(format: "%.2f", memory.decayWeight)) down=\(memory.feedbackDownCount)\(memory.supersededAt != nil ? " · 已失效" : "")")
    }
}

// MARK: - Decay Engine

enum MemoryTier: String, Hashable {
    case hot    // 自动注入
    case warm   // 可搜索，不自动注入
    case cold   // 归档
}

struct DecayEngine {
    /// 计算记忆当前有效权重（惰性计算，不写入）
    static func effectiveWeight(_ memory: Memory) -> Double {
        guard !memory.isUserExplicit else { return 1.0 }
        // M8 衰减开关关 = 不随时间降温
        guard MemoryFlags.decayEnabled else { return memory.decayWeight }
        let days = Date().timeIntervalSince(memory.lastAccessedAt) / 86400
        return memory.decayWeight * exp(-0.1 * days)
    }

    /// 访问时强化
    static func reinforce(_ memory: Memory) {
        memory.decayWeight = min(1.0, memory.decayWeight + 0.2)
        memory.lastAccessedAt = Date()
        memory.accessCount += 1
    }

    /// 批量衰减：将 effectiveWeight 写回 decayWeight
    static func applyDecay(memories: [Memory]) {
        guard MemoryFlags.decayEnabled else { return }   // M8
        for memory in memories {
            guard !memory.isUserExplicit else { continue }
            memory.decayWeight = effectiveWeight(memory)
            memory.lastAccessedAt = Date()
        }
    }

    /// 温区分类
    static func tier(_ memory: Memory) -> MemoryTier {
        let w = effectiveWeight(memory)
        if memory.isUserExplicit || w >= 0.3 { return .hot }
        if w >= 0.05 { return .warm }
        return .cold
    }
}

// MARK: - 档案排序（第二刀 A1：不分冷热）

enum MemoryArchiveOrder {
    /// 活着的：钉住在前，其余按创建时间新→旧；已失效的单列，按失效时间新→旧
    static func split(_ memories: [Memory]) -> (active: [Memory], superseded: [Memory]) {
        let active = memories.filter { $0.supersededAt == nil }.sorted {
            $0.isUserExplicit != $1.isUserExplicit ? $0.isUserExplicit : $0.createdAt > $1.createdAt
        }
        let superseded = memories.filter { $0.supersededAt != nil }.sorted {
            ($0.supersededAt ?? .distantPast) > ($1.supersededAt ?? .distantPast)
        }
        return (active, superseded)
    }
}

/// 档案「删除」分两种：活着的标失效（可恢复，直接做）；已失效的再删 = 永久删除（必须先确认）
enum MemoryDeletePlan {
    struct Plan: Equatable {
        let supersede: [UUID]
        let purge: [UUID]
        var needsConfirm: Bool { !purge.isEmpty }
    }

    static func plan(_ memories: [Memory]) -> Plan {
        Plan(supersede: memories.filter { $0.supersededAt == nil }.map(\.id),
             purge: memories.filter { $0.supersededAt != nil }.map(\.id))
    }

    /// 确认弹窗标题：混选时一次说清两部分各几条
    static func confirmTitle(_ plan: Plan) -> String {
        plan.supersede.isEmpty
            ? "永久删除 \(plan.purge.count) 条已失效的记忆？"
            : "\(plan.supersede.count) 条移到已失效（可恢复），\(plan.purge.count) 条已失效的永久删除？"
    }

    static func confirmButton(_ plan: Plan) -> String {
        "永久删除 \(plan.purge.count) 条，不能恢复"
    }

    /// 主列表「删除」：只把活着的移到已删除；已删除的一条不碰（彻底删除只在「已删除」里做）
    @discardableResult
    static func moveToTrash(_ memories: [Memory], now: Date = Date()) -> [UUID] {
        let live = memories.filter { $0.supersededAt == nil }
        for m in live {
            m.supersededAt = now
            m.updatedAt = now
        }
        return live.map(\.id)
    }

    /// 「已删除」里彻底删除的确认标题（单条 / 多条两种说法）
    static func purgeTitle(_ count: Int) -> String {
        count == 1 ? "彻底删除这条记忆？" : "彻底删除 \(count) 条记忆？"
    }
}

/// 多选「钉住」：选中的全都钉着 = 这次是取消钉住
enum MemoryPinPlan {
    static func unpins(_ selected: [Memory]) -> Bool {
        !selected.isEmpty && selected.allSatisfy(\.isUserExplicit)
    }

    static func apply(_ selected: [Memory], now: Date = Date()) {
        let pin = !unpins(selected)
        for m in selected {
            m.isUserExplicit = pin
            if pin { m.decayWeight = 1.0 }
            m.updatedAt = now
        }
    }
}

// MARK: - Memory Flags

enum MemoryFlags {
    /// 刀4（plan-memory-usable，⧫③ 已批"清键"）：一次性迁移到全量在场——
    /// 清掉设备上显式写过的检索开关旧值（keyword/vector 退出注入决策）和旧预算 2000
    /// （让新默认 10000 生效）。守卫 sentinel 防重跑；用户此后再改开关是新的显式意愿，尊重。
    static func migrateFullPresenceIfNeeded() {
        let d = UserDefaults.standard
        let sentinel = "mem_fulltext_migrated_v1"
        guard !d.bool(forKey: sentinel) else { return }
        d.removeObject(forKey: "mem_inject_keyword")
        d.removeObject(forKey: "mem_inject_vector")
        if d.integer(forKey: "mem_inject_budget") == 2000 {
            d.removeObject(forKey: "mem_inject_budget")
        }
        d.set(true, forKey: sentinel)
    }

    /// 记忆系统总开关（设置-记忆）。关 = 不注入不提取不强化，数据不动。
    static var masterEnabled: Bool {
        (MemoryReadEnvironment.defaults.object(forKey: "mem_master") as? Bool) ?? true
    }

    /// M8 热度衰减开关。paramecium 实测删了衰减（冷者愈冷）、kiwi 留着——用户自己选。
    static var decayEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_decay_enabled") as? Bool) ?? true
    }

    /// M8 提取人称开关。开 = 第一人称带情感（paramecium 式陪伴感）；默认第三人称客观。
    static var firstPersonExtraction: Bool {
        UserDefaults.standard.bool(forKey: "mem_extract_firstperson")
    }

    /// A2 上下文摘要写不写（设置-记忆-写入 A2）。默认开；受 mem_master 连坐。v5 起只管写：
    /// fs 工具读记忆树（memory/）跟文件库开关走，不归这里管。
    static var contextSummaryEnabled: Bool {
        masterEnabled && ((UserDefaults.standard.object(forKey: "mem_content_summary") as? Bool) ?? true)
    }

    /// A3 窗口总结写不写（v5 拆开；没写过跟老键）
    static var windowSummaryEnabled: Bool { MemoryWriterSettings.writes(.a3) }

    /// 做梦毕业开关（key 沿用 mem_supersede_soft）：开 = 做梦后把消费碎片标失效。
    /// 修复第一刀起只管毕业——删除一律软失效，不再看任何开关。
    static var dreamGraduationEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_supersede_soft") as? Bool) ?? true
    }

    /// SC-B3 目录式注入开关（默认关 = 现状全文）。开 = volatile 命中层只注入一行式目录，
    /// 细节模型自己 recall 取回；stable 常驻层保持全文（人格地基不瘦身）。
    static var catalogInjection: Bool {
        MemoryReadEnvironment.defaults.bool(forKey: "mem_inject_catalog")
    }

    /// 原子事实开关（设置-记忆 ①感知）。修复第一刀·刀5 接线：关 = 不再提取新的，已有的照常注入
    static var factsEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_content_facts") as? Bool) ?? true
    }

    // 第二刀：AI 自己的记忆（memory/self/）几个可调限制——设置 → 记忆 → 高级；默认值粟粟 10-03 批
    /// 每轮常驻全文的「最近几条」（五级的另算，全部全文）
    static var selfRecentCount: Int { positive("mem_self_recent_count", 5) }
    /// 自己主动记的每日上限（她让记的不算）
    static var selfDailyLimit: Int { positive("mem_self_daily_limit", 12) }
    /// 每条正文字数上限
    static var selfBodyLimit: Int { positive("mem_self_body_limit", 800) }
    /// 我的记忆最多占注入预算的百分比（100 = 先装、不设上限，档案用剩下的）
    static var selfBudgetPercent: Int { min(100, positive("mem_self_budget_percent", 100)) }

    private static func positive(_ key: String, _ fallback: Int) -> Int {
        let v = UserDefaults.standard.integer(forKey: key)
        return v > 0 ? v : fallback
    }
}

// MARK: - Retrieval Pipeline（M1：多检索器融合，向量/tag 的地基）

enum MemoryLayer { case stable, volatile }

struct ScoredMemory {
    let memory: Memory
    let score: Double
}

/// 本轮注入命中的结构化记录（召回卡片 + S1 检查器用）。
/// snippet 自含，卡片渲染不回查库；score 是各路原始分（vector=余弦 / keyword=BM25 / fallback=衰减权重），graph 邻居无分。
struct InjectionHit: Codable, Equatable {
    let memoryId: UUID
    let snippet: String
    let category: String
    let score: Double?
    let retrieverId: String   // "persistent" | "keyword" | "vector" | "graph" | "fullFallback"
    let catalog: Bool
    var vote: Int? = nil      // 用户反馈：+1 / -1 / nil（存进 MessageNode blob，防重复投）
}

/// 实际拼进 volatile 的一段（P2 账的旁录口径，plan-memory-receipt §2.2）：文本就是拼进 `lines` 的那一块。
struct InjectedVolatileLine: Equatable {
    /// nil = 内层过期提醒（不是某条记忆的行）
    let memoryId: UUID?
    let text: String
    /// 仅过期提醒：它点名的那几条钉住项
    let expiredIds: [UUID]
}

/// `buildInjectionSplit` 的产出；`volatileLines` = 拼进 `volatile` 的每行，顺序 = wire 顺序（提醒在最前）。
struct InjectionSplit {
    let stable: String
    let volatile: String
    let hits: [InjectionHit]
    var volatileLines: [InjectedVolatileLine] = []
}

/// 一路检索：从候选记忆里挑 (记忆, 分数)，降序返回。纯函数——不碰预算、不去重，那是组装器的事。
protocol MemoryRetriever {
    var id: String { get }
    /// stable=常驻层（逐轮不变，进缓存前缀）；volatile=每轮可变（cacheFriendly 时下沉）
    var layer: MemoryLayer { get }
    /// volatile 内的优先级组：同 tier 多路时 RRF 融合，tier 间顺序拼接。兜底永远最大。
    var tier: Int { get }
    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory]
}

/// 常驻人格层：只有钉住的（`isPersistent`，两种模式一样），按创建时间排
struct PersistentRetriever: MemoryRetriever {
    let explicitOnly: Bool
    var id: String { "persistent" }
    var layer: MemoryLayer { .stable }
    var tier: Int { 0 }
    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        // 常驻层全员注入，排序只影响行序——必须按创建时间（永恒稳定）。
        // 按权重排的话 reinforce/衰减每轮微调分数，行序随时翻面 → system 前缀变 → 缓存无声全废（实测踩过）
        let base = explicitOnly
            ? memories.filter { $0.isUserExplicit }
            : memories.filter(MemoryInjector.isPersistent)
        return base.sorted { $0.createdAt < $1.createdAt }.map { ScoredMemory(memory: $0, score: 1) }
    }
}

struct MemoryRetrievalDocument: Sendable {
    let id: UUID
    let profileId: String
    let content: String
    let keywords: [String]
    var embeddingData: Data?
    var embeddingRevision: Int?

    init(id: UUID, profileId: String = "", content: String, keywords: [String], embeddingData: Data? = nil, embeddingRevision: Int? = nil) {
        self.id = id
        self.profileId = profileId
        self.content = content
        self.keywords = keywords
        self.embeddingData = embeddingData
        self.embeddingRevision = embeddingRevision
    }

    init(_ memory: Memory) {
        self.init(id: memory.id, profileId: memory.profileId, content: memory.content, keywords: memory.keywords,
                  embeddingData: memory.embeddingData, embeddingRevision: memory.embeddingRevision)
    }

    func hasValidVector(revision: Int) -> Bool {
        embeddingRevision == revision && embeddingData.map {
            !$0.isEmpty && $0.count.isMultiple(of: MemoryLayout<Float>.stride)
        } == true
    }
}

enum MemoryRankFusion {
    static func fuse<Key: Hashable>(_ lists: [[Key]], cancel: CatalogCancel? = nil) -> [Key] {
        var scores: [Key: Double] = [:]
        var firstSeen: [Key: Int] = [:]
        for list in lists {
            var seen = Set<Key>()
            for (rank, id) in list.enumerated() where seen.insert(id).inserted {
                if cancel?.isCancelled == true { return [] }
                scores[id, default: 0] += 1.0 / Double(61 + rank)
                if firstSeen[id] == nil { firstSeen[id] = firstSeen.count }
            }
        }
        if cancel?.isCancelled == true { return [] }
        return scores.sorted {
            $0.value != $1.value ? $0.value > $1.value : firstSeen[$0.key]! < firstSeen[$1.key]!
        }.map(\.key)
    }
}

enum MemoryRetrieval {
    struct Result: Sendable {
        let ids: [UUID]
        let vectorStatus: String
        let failedCount: Int
        let validVectorCount: Int
    }

    static func search(query: String, documents: [MemoryRetrievalDocument],
                       embedder: MemoryEmbedding = AppleMemoryEmbedder.shared, cancel: CatalogCancel? = nil) -> Result {
        func cancelled() -> Result { Result(ids: [], vectorStatus: "已取消", failedCount: 0, validVectorCount: 0) }
        var seen = Set<UUID>()
        var unique: [MemoryRetrievalDocument] = []
        var documentsForScoring: [[String]] = []
        for document in documents where seen.insert(document.id).inserted {
            guard cancel?.isCancelled != true else { return cancelled() }
            unique.append(document)
            documentsForScoring.append(MemoryBM25.document(content: document.content, keywords: document.keywords))
        }
        let scores = MemoryBM25.scores(documents: documentsForScoring, query: query, cancel: cancel)
        guard cancel?.isCancelled != true else { return cancelled() }
        let keywordIds = unique.indices.filter { scores[$0] > 0 }.sorted {
            scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1
        }.map { unique[$0].id }
        let validCount = unique.reduce(0) { $0 + ($1.hasValidVector(revision: embedder.revision) ? 1 : 0) }
        let failedCount = unique.count - validCount
        guard cancel?.isCancelled != true else { return cancelled() }
        guard embedder.isReady else {
            return Result(ids: keywordIds, vectorStatus: "向量不可用（模型未就绪）",
                          failedCount: failedCount, validVectorCount: validCount)
        }
        guard !unique.isEmpty else {
            return Result(ids: [], vectorStatus: "向量命中 0 条", failedCount: 0, validVectorCount: 0)
        }
        let encoded = embedder.embed(query)
        guard cancel?.isCancelled != true else { return cancelled() }
        guard let vector = encoded else {
            return Result(ids: keywordIds, vectorStatus: "向量不可用（查询编码失败）",
                          failedCount: failedCount, validVectorCount: validCount)
        }
        guard cancel?.isCancelled != true else { return cancelled() }
        guard validCount > 0 else {
            return Result(ids: keywordIds, vectorStatus: "向量不可用（\(failedCount) 条没算出来）",
                          failedCount: failedCount, validVectorCount: 0)
        }
        let ranked = VectorRetriever.rank(unique, query: vector, revision: embedder.revision, cancel: cancel)
        guard cancel?.isCancelled != true else { return cancelled() }
        let status = failedCount > 0
            ? "向量部分不可用（\(failedCount) 条没算出来），命中 \(ranked.scores.count) 条"
            : "向量命中 \(ranked.scores.count) 条"
        return Result(ids: MemoryRankFusion.fuse([keywordIds, ranked.scores.map(\.id)], cancel: cancel),
                      vectorStatus: status, failedCount: failedCount, validVectorCount: validCount)
    }
}

/// 关键词检索复用共享 BM25：汉字段按相邻双字评分，短段须含齐，长段按当前候选的 df 抑制常见词。
/// 关键词计两份；只有通过相同词面门槛的正分候选才参加排序。
struct KeywordRetriever: MemoryRetriever {
    var id: String { "keyword" }
    var layer: MemoryLayer { .volatile }
    var tier: Int { 1 }
    /// 注入时排除常驻层（它们另走 stable）；recall 传 false——关系/偏好/钉住也要能搜到（修复第一刀·刀6）
    let excludePersistent: Bool

    init(excludePersistent: Bool = true) { self.excludePersistent = excludePersistent }

    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        let candidates = excludePersistent ? memories.filter { !MemoryInjector.isPersistent($0) } : memories
        let scores = MemoryBM25.scores(documents: candidates.map {
            MemoryBM25.document(content: $0.content, keywords: $0.keywords)
        }, query: recent.joined(separator: "\n"))
        return candidates.indices.filter { scores[$0] > 0 }.sorted {
            scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1
        }.map { ScoredMemory(memory: candidates[$0], score: scores[$0]) }
    }
}

/// 向量语义检索层（M2）：query=最近对话尾部句向量，对候选逐条余弦，阈值+topK。
/// 模型资产未就绪 → 静默返回空并触发下载（绝不打断聊天）。
struct VectorRetriever: MemoryRetriever {
    var id: String { "vector" }
    var layer: MemoryLayer { .volatile }
    var tier: Int { 1 }
    /// 同 KeywordRetriever.excludePersistent
    let excludePersistent: Bool

    init(excludePersistent: Bool = true) { self.excludePersistent = excludePersistent }

    /// 实测校准（2026-06-11）：Apple 模型分数尺度偏低——"甜品店橱窗"vs"喜欢蛋糕"只给 0.40。
    /// 0.5 抓不到真相关；0.35 起步，等无关对照组的基线数据再精调
    static let similarityThreshold: Float = 0.35
    static let topK = 20

    /// 最近一次检索的内幕（诊断日志用：抓空时知道断在哪环、差多少）
    static var lastDetail = ""

    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        let embedder = AppleMemoryEmbedder.shared
        guard embedder.isReady else {
            embedder.requestAssetsIfNeeded()
            Self.lastDetail = "模型:\(embedder.assetState.rawValue)"
            return []
        }
        let queryText = String(recent.suffix(4).joined(separator: "\n").suffix(300))
        guard let query = embedder.embed(queryText) else {
            Self.lastDetail = "query embed 失败"
            return []
        }
        let candidates = excludePersistent ? memories.filter { !MemoryInjector.isPersistent($0) } : memories
        var lookup: [UUID: Memory] = [:]
        var documents: [MemoryRetrievalDocument] = []
        for memory in candidates where lookup[memory.id] == nil {
            lookup[memory.id] = memory
            documents.append(MemoryRetrievalDocument(memory))
        }
        let ranked = Self.rank(documents, query: query, revision: embedder.revision)
        Self.lastDetail = ranked.detail
        return ranked.scores.compactMap { hit in
            lookup[hit.id].map { ScoredMemory(memory: $0, score: hit.score) }
        }
    }

    static func rank(_ documents: [MemoryRetrievalDocument], query: [Float], revision: Int, cancel: CatalogCancel? = nil)
        -> (scores: [(id: UUID, score: Double)], detail: String) {
        // 两个调用入口均已按 UUID 去重，BM25 与向量不重复建立候选副本。
        var maxSim: Float = -1
        var scores: [(index: Int, id: UUID, score: Double)] = []
        for (index, document) in documents.enumerated() {
            if cancel?.isCancelled == true { return ([], "已取消") }
            guard document.hasValidVector(revision: revision), let data = document.embeddingData else { continue }
            let similarity = MemoryVector.dot(query, MemoryVector.floats(from: data))
            maxSim = max(maxSim, similarity)
            if similarity >= similarityThreshold {
                scores.append((index, document.id, Double(similarity)))
            }
        }
        if cancel?.isCancelled == true { return ([], "已取消") }
        scores.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        let withVec = documents.reduce(0) { $0 + ($1.embeddingData == nil ? 0 : 1) }
        let detail = "候选\(documents.count)·带向量\(withVec)·最高相似\(maxSim < 0 ? "无" : String(format: "%.2f", maxSim))·阈值\(String(format: "%.2f", similarityThreshold))"
        return (scores.prefix(topK).map { (id: $0.id, score: $0.score) }, detail)
    }
}

/// 全量兜底：填满剩余预算。excludePersistent 区分两种模式的候选集（现状语义）。
/// 刀4：排序从衰减分改 createdAt 降序——①分数每轮微调=行序漂移毁缓存（Persistent 同款坑）
/// ②超预算截断自然落在最老端（新的先装，钉住在 stable 层豁免），截断线移动才 miss 缓存。
/// 审计台卡片 ⧫6：先按召回优先级（重要度，没定 = 3）高→低，同优先级再新→旧——装不下先丢重要度低的；
/// 优先级只在她拖重要度时变，不逐轮漂移；全没定时和原来的顺序一样
struct FullFallbackRetriever: MemoryRetriever {
    let excludePersistent: Bool   // true=keyword 模式（排除常驻层）；false=纯全量（排除手动钉住）
    var id: String { "fullFallback" }
    var layer: MemoryLayer { .volatile }
    var tier: Int { 99 }
    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        let candidates = excludePersistent
            ? memories.filter { !MemoryInjector.isPersistent($0) }
            : memories.filter { !$0.isUserExplicit }
        return candidates
            .sorted { $0.recallPriority != $1.recallPriority ? $0.recallPriority > $1.recallPriority : $0.createdAt > $1.createdAt }
            .map { ScoredMemory(memory: $0, score: 1) }
    }
}

// MARK: - Memory Injector

struct MemoryInjector {
    /// 目录模式尾巴的 recall 指路；这一轮 recall 没下发时组装层整句去掉（PromptAssembler.droppingOffToolMentions）
    static let recallCatalogHint = "\n（想看完整内容用 recall 工具查）"
    /// 诊断日志去重（S1 预览高频重算会刷屏）
    fileprivate static var lastDiagLine = ""

    /// 注入预算（token）。刀4 粟粟拍板：全量注入上限 10000，不限条。
    static var tokenBudget: Int {
        let v = MemoryReadEnvironment.defaults.integer(forKey: "mem_inject_budget")
        return v > 0 ? v : 10_000
    }

    /// 分类标签中文映射
    private static let categoryLabels: [String: String] = [
        "preference": "偏好",
        "fact": "事实",
        "relationship": "关系",
        "goal": "目标",
        "context": "情境",
    ]

    // MARK: - 目录模式（SC-B3）

    /// 目录条数上限（粟粟批注：按行计费后召回面变大，超出截断）
    static let maxCatalogEntries = 30

    private static let catalogDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    /// 一条记忆进注入的计费 token（全文 = tokenCount；目录 = 目录行实测）。设置页实际注入量复用这条
    static func injectedCost(_ m: Memory, catalog: Bool) -> Int {
        catalog ? Memory.estimateTokens(catalogLine(m)) : m.tokenCount
    }

    /// 目录行：与 recall L1 行格式同族（[日期·分类]），模型见目录 → recall 能对上
    static func catalogLine(_ m: Memory) -> String {
        let label = categoryLabels[m.category] ?? m.category
        let snippet = m.content.count > 60 ? String(m.content.prefix(60)) + "…" : m.content
        return "- [\(catalogDateFormatter.string(from: m.createdAt))·\(label)] \(snippet)"
    }

    /// One rendered source block, shared by fresh selection and zero-search Active Set retention.
    static func injectionPayload(_ m: Memory, stable: Bool, catalog: Bool, now: Date) -> (text: String, cost: Int) {
        let validity = stable && m.isUserExplicit
            ? m.validUntil.map { "（有效到 \(MemoryDay.key($0.addingTimeInterval(-1)))）" } ?? "" : ""
        let expired = !stable && WikiInjection.isExpired(m, now: now) ? "（已过期）" : ""
        let label = categoryLabels[m.category] ?? m.category
        let text = (catalog ? catalogLine(m) : "- \(m.content)\(validity) [\(label)]") + expired
        let cost = injectedCost(m, catalog: catalog) + (validity.isEmpty ? 0 : Memory.estimateTokens(validity))
            + (expired.isEmpty ? 0 : Memory.estimateTokens(expired))
        return (text, cost)
    }

    static func expiredPinnedReminder(_ memories: [Memory], budget: Int) -> (text: String, cost: Int) {
        let title = "[已过期的钉住项]"
        var lines: [String] = []
        var used = 0
        for memory in memories {
            let snippet = String(memory.content.prefix(40)).replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            let line = "- \(snippet)（已过期）"
            let cost = Memory.estimateTokens(line) + (lines.isEmpty ? Memory.estimateTokens(title + "\n") : 0)
            guard used + cost <= budget else { continue }
            lines.append(line)
            used += cost
        }
        return (lines.isEmpty ? "" : title + "\n" + lines.joined(separator: "\n"), used)
    }

    /// 注入记忆：常驻人格层（始终）+ 关键词检索层（命中对话才注）。开关见「设置-记忆」。
    static func buildInjection(memories: [Memory], recentMessages: [String] = [], budget: Int = tokenBudget) -> String {
        let split = buildInjectionSplit(memories: memories, recentMessages: recentMessages, budget: budget)
        if split.stable.isEmpty { return split.volatile }
        if split.volatile.isEmpty { return split.stable }
        return split.stable + "\n" + split.volatile
    }

    /// 按开关组装检索器队伍。改开关组合只动这里——加新检索路（tag 等）= 往对应 tier 加一员。
    /// M2 起：开 keyword 或 vector 任一 = 智能模式（常驻层启用，全量变兜底）；两个都开 = 同 tier RRF 双路召回。
    static func activeRetrievers() -> [MemoryRetriever] {
        let useKeyword = MemoryReadEnvironment.defaults.bool(forKey: "mem_inject_keyword")
        let useFull = (MemoryReadEnvironment.defaults.object(forKey: "mem_inject_full") as? Bool) ?? true
        let useVector = MemoryReadEnvironment.defaults.bool(forKey: "mem_inject_vector")
        if useKeyword || useVector {
            var list: [MemoryRetriever] = [PersistentRetriever(explicitOnly: false)]
            if useKeyword { list.append(KeywordRetriever()) }
            if useVector { list.append(VectorRetriever()) }
            if useFull { list.append(FullFallbackRetriever(excludePersistent: true)) }
            return list
        } else if useFull {
            return [PersistentRetriever(explicitOnly: true), FullFallbackRetriever(excludePersistent: false)]
        }
        return []
    }

    /// 一轮要注入的记忆原料。实发 `composePrompt` 和记忆面板「下一轮会想起什么」预览都只走这里（预览 = 实发）
    struct RoundInputs {
        let memories: [Memory]
        let selfMemory: SelfMemoryInjection.Built?
        let archiveBudget: Int
        /// C 勾着时的 wiki 快照（根索引 + 触发词扫描用）；C 没勾 / 记忆关着 = nil
        var wiki: WikiInjectionSnapshot? = nil
        var fullText: RecallFullTextCandidates? = nil
        /// 段④：这一轮带不带档案根索引（本窗 Z6）。nil = 手搭的旧输入，照开窗口页「档案」那一勾
        var rootIndex: Bool? = nil
        /// 本窗冻结的上窗（Z7 开、参与着、源窗复核过才有）；单独按 tokenBudget 渲染，不扣档案预算。
        var previousWindow: PreviousWindowSnapshot? = nil
        /// 来源窗隐藏集（`isTrashed || !memoryEnabled`，plan-memory-participation §2.4）：碎片按来源窗挡；空 = 不过滤
        var hiddenSources: Set<String> = []
        /// 候选数：勾着却被来源窗挡掉的碎片条数（同一趟 filter 里数；勾关 / 参与关恒 0）
        var hiddenFragmentCount: Int = 0
    }

    /// C 那一勾带哪些档案（plan-memory-c3-catalog 第六节）：她钉住的照带；其余只带碎片池里审计台点过「留下」的，
    /// 没看过的、10 月前的旧原子档案都不带
    static func isInjectable(_ m: Memory) -> Bool {
        m.supersededAt == nil && (m.isUserExplicit || (m.isFragment && m.reviewedAt != nil))
    }

    /// 来源窗过滤（plan-memory-participation §2.2）：来源窗已删 / 关参与的不带；钉住（她亲手钉 / 改过）豁免——
    /// 那是更晚、更强的意愿。来源窗不存在 / `sourceConversationId` 为 nil / 空串都照带（隐藏集语义）。
    /// 实发 `roundInputs` 和检查器 `MemoryResident.summary` 的灰显兜底共用这一条。
    static func passesSourceWindow(_ m: Memory, hidden: Set<String>) -> Bool {
        m.isUserExplicit || !(m.sourceConversationId.map(hidden.contains) ?? false)
    }

    /// 这一轮带不带只读 `EffectiveMemoryParticipation`（一处算、处处传，plan-memory-participation §2.3）。
    /// 刀4：listActive 全量在场（未失效即注入）；第二刀 B3：AI 自己的记忆先装，档案用剩下的预算
    static func roundInputs(profileId: String, participation: EffectiveMemoryParticipation,
                            store: MemoryStore, context: ModelContext, wikiStore: WikiStore? = nil,
                            warmedWiki: WikiInjectionCache.WarmedSnapshot? = nil,
                            useCachedWiki: Bool = true,
                            previousWindow: PreviousWindowSnapshot? = nil,
                            hiddenSources: Set<String> = []) -> RoundInputs {
        // v5【开窗口】：B4 / C 各一勾（默认开 = 今天）；段④ 钉住单独一勾
        let cOn = participation.archive
        let pinnedOn = participation.pinned
        let triggerOn = participation.pages
        // 来源窗已删 / 关参与的碎片不带；钉住的豁免（来源窗不存在的照带——plan-memory-participation §2.1 / §2.2）
        // 挡掉的条数在同一趟 filter 里数（账的候选口径，plan-memory-receipt §2.1）
        var hiddenFragmentCount = 0
        let memories: [Memory] = AirTimedSection.run("composePrompt.memory") {
            guard cOn || pinnedOn else { return [] }
            return store.listActive(profileId: profileId, context: context).filter {
                guard isInjectable($0), $0.isUserExplicit ? pinnedOn : cOn else { return false }
                if passesSourceWindow($0, hidden: hiddenSources) { return true }
                hiddenFragmentCount += 1
                return false
            }
        }
        var wiki = cOn || triggerOn ? (warmedWiki?.snapshot ?? (useCachedWiki
            ? WikiInjectionCache.shared.snapshot(profileId: profileId, store: wikiStore) : nil)) : nil
        if !cOn { wiki?.indexLines = [] }
        if !triggerOn { wiki?.pages = [] }
        let selfMemory: SelfMemoryInjection.Built? = AirTimedSection.run("composePrompt.selfMemory") {
            participation.selfMemory
                ? SelfMemoryInjection.build(SelfMemoryStore.list(memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId), checkPath: AppPaths.checked),
                                            recentCount: MemoryFlags.selfRecentCount,
                                            budget: tokenBudget * MemoryFlags.selfBudgetPercent / 100)
                : nil
        }
        return RoundInputs(memories: memories, selfMemory: selfMemory,
                           archiveBudget: max(0, tokenBudget - (selfMemory?.tokens ?? 0)), wiki: wiki,
                           fullText: participation.fullText ? warmedWiki?.fullText : nil, rootIndex: cOn,
                           previousWindow: participation.previousWindow ? previousWindow : nil, hiddenSources: hiddenSources,
                           hiddenFragmentCount: hiddenFragmentCount)
    }

    /// 拆层版本（cacheFriendly 用）：stable=常驻层（逐轮不变，可进缓存前缀），volatile=检索命中/兜底层（每轮可变）。
    /// 两段拼接 == buildInjection 输出，预算共享。
    /// M1 起为检索 pipeline：各检索器产候选 → stable 依序 / volatile 按 tier（同 tier 多路 RRF）→ 共享预算去重。
    static func buildInjectionSplit(memories: [Memory], recentMessages: [String] = [], budget: Int = tokenBudget,
                                    now: Date = MemoryClock.now) -> InjectionSplit {
        guard !memories.isEmpty else { return InjectionSplit(stable: "", volatile: "", hits: []) }

        let retrievers = activeRetrievers()
        guard !retrievers.isEmpty else { return InjectionSplit(stable: "", volatile: "", hits: []) }   // 全量/关键词都关 → 空注入

        var stableLines: [String] = []
        var volatileLines: [String] = []
        var usedTokens = 0
        var injected = Set<UUID>()
        var hits: [InjectionHit] = []
        var expiredPinned: [Memory] = []
        // 拼进 volatile 的每行旁录（拼接同一处 append）；返回值按 wire 顺序收
        var volatileUnits: [InjectedVolatileLine] = []

        // 目录模式（SC-B3）：volatile 层换一行式目录，按目录行实际 token 计费（省 token 本体）
        let catalogMode = MemoryFlags.catalogInjection
        var catalogCount = 0
        var catalogSavedTokens = 0   // 全文 token - 目录行 token，CacheDiagLog 用

        @discardableResult
        func tryAppend(_ m: Memory, to lines: inout [String], stable: Bool = false, catalog: Bool = false, retriever: String, score: Double?) -> String? {
            guard !injected.contains(m.id) else { return nil }
            if catalog { guard catalogCount < maxCatalogEntries else { return nil } }
            let payload = injectionPayload(m, stable: stable, catalog: catalog, now: now)
            let cost = payload.cost
            guard usedTokens + cost <= budget else { return nil }
            lines.append(payload.text)
            if stable, m.isUserExplicit, WikiInjection.isExpired(m, now: now) { expiredPinned.append(m) }
            usedTokens += cost
            injected.insert(m.id)
            hits.append(InjectionHit(
                memoryId: m.id, snippet: String(m.content.prefix(60)),
                category: m.category, score: score, retrieverId: retriever, catalog: catalog))
            if catalog {
                catalogCount += 1
                catalogSavedTokens += max(0, m.tokenCount - cost)
            }
            return payload.text
        }

        // stable 层：依序产出（目前只有常驻一路）
        var contributions: [String] = []
        for r in retrievers where r.layer == .stable {
            let out = r.retrieve(memories, recent: recentMessages)
            contributions.append("\(r.id) \(out.count)")
            for s in out { tryAppend(s.memory, to: &stableLines, stable: true, retriever: r.id, score: s.score) }
        }
        let expiredReminder = expiredPinnedReminder(expiredPinned, budget: max(0, budget - usedTokens))
        usedTokens += expiredReminder.cost
        // volatile 层：tier 升序；同 tier 单路直通，多路 RRF 融合（keyword+vector 双路召回）
        let volatileRetrievers = retrievers.filter { $0.layer == .volatile }
        // 命中元数据（展示分）：各路原始分，多路命中同条时 vector 优先（余弦可解释）
        var meta: [UUID: (retriever: String, score: Double?)] = [:]
        for tier in Set(volatileRetrievers.map(\.tier)).sorted() {
            let group = volatileRetrievers.filter { $0.tier == tier }
            let outputs = group.map { r -> [ScoredMemory] in
                let out = r.retrieve(memories, recent: recentMessages)
                if r.id == "vector" {
                    // 成败都带内幕：抓空知道断哪环差多少，抓到知道分数（阈值校准用）
                    contributions.append("vector \(out.count)[\(VectorRetriever.lastDetail)]")
                } else {
                    contributions.append("\(r.id) \(out.count)")
                }
                return out
            }
            for (r, out) in zip(group, outputs) {
                for s in out where meta[s.memory.id] == nil || (r.id == "vector" && meta[s.memory.id]?.retriever != "vector") {
                    meta[s.memory.id] = (r.id, s.score)
                }
            }
            var ranked: [Memory] = outputs.count == 1 ? outputs[0].map(\.memory) : rrfFuse(outputs)
            // M3 一跳扩展：命中记忆的邻居打折跟进（排在命中之后 = 自然折扣）
            if tier == 1, MemoryReadEnvironment.defaults.bool(forKey: "mem_inject_graph") {
                let byId = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
                var present = Set(ranked.map(\.id)).union(injected)
                var neighbors: [Memory] = []
                for m in ranked {
                    for rid in m.relatedIds {
                        guard let n = byId[rid], !present.contains(n.id), !MemoryInjector.isPersistent(n) else { continue }
                        neighbors.append(n)
                        present.insert(n.id)
                    }
                }
                if !neighbors.isEmpty {
                    ranked += neighbors
                    contributions.append("graph \(neighbors.count)")
                    for n in neighbors where meta[n.id] == nil { meta[n.id] = ("graph", nil) }
                }
            }
            for m in ranked {
                let info = meta[m.id] ?? (retriever: group.first?.id ?? "fullFallback", score: nil)
                if let text = tryAppend(m, to: &volatileLines, catalog: catalogMode, retriever: info.retriever, score: info.score) {
                    volatileUnits.append(InjectedVolatileLine(memoryId: m.id, text: text, expiredIds: []))
                }
            }
        }

        // 目录尾 hint：只在 recall 工具真的可用时指路（关了不指模型去不存在的工具）
        var volatileText = volatileLines.joined(separator: "\n")
        if catalogMode && !volatileLines.isEmpty && RecallTool.enabled {
            volatileText += Self.recallCatalogHint
        }
        if !expiredReminder.text.isEmpty {
            volatileText = volatileText.isEmpty ? expiredReminder.text : expiredReminder.text + "\n\n" + volatileText
            volatileUnits.insert(InjectedVolatileLine(memoryId: nil, text: expiredReminder.text,
                                                      expiredIds: expiredPinned.map(\.id)), at: 0)
        }

        let result = InjectionSplit(stable: stableLines.joined(separator: "\n"), volatile: volatileText, hits: hits,
                                    volatileLines: volatileUnits)
        if MemoryReadEnvironment.preferences != nil { return result }
        // 检索贡献可见（验收"每一路真的在干活"）。S1 预览也走这里会刷屏 → 连续重复行去重
        var line = "记忆检索: \(contributions.joined(separator: " · ")) → 注入 \(injected.count) 条"
        if catalogMode && catalogCount > 0 {
            line += "（目录 \(catalogCount) 条 省 ~\(catalogSavedTokens) tok）"
        }
        if line != lastDiagLine {
            lastDiagLine = line
            CacheDiagLog.shared.log(line)
        }
        return result
    }

    /// RRF（Reciprocal Rank Fusion）：多路排序融合，score = Σ 1/(60+rank)。kiwi/paramecium 同款。
    static func rrfFuse(_ lists: [[ScoredMemory]]) -> [Memory] {
        var lookup: [UUID: Memory] = [:]
        for list in lists {
            for hit in list where lookup[hit.memory.id] == nil { lookup[hit.memory.id] = hit.memory }
        }
        return MemoryRankFusion.fuse(lists.map { $0.map { $0.memory.id } }).compactMap { lookup[$0] }
    }


    /// 常驻人格层判定：只有她亲手钉住的（C3 ② 起按类别（关系 / 偏好）自动常驻的那批停掉）
    static func isPersistent(_ m: Memory) -> Bool {
        m.isUserExplicit
    }

    /// keywords（空则 content 分词兜底）是否命中最近对话
    fileprivate static func matchesKeyword(_ m: Memory, _ messages: [String]) -> Bool {
        let haystack = messages.joined(separator: "\n").lowercased()
        guard !haystack.isEmpty else { return false }
        let keys = m.keywords.isEmpty ? contentKeys(m.content) : m.keywords
        return keys.contains { !$0.isEmpty && haystack.contains($0.lowercased()) }
    }

    /// 命中相关度：命中关键词数 × 衰减权重
    fileprivate static func hitScore(_ m: Memory, _ messages: [String]) -> Double {
        let haystack = messages.joined(separator: "\n").lowercased()
        let keys = m.keywords.isEmpty ? contentKeys(m.content) : m.keywords
        let hits = keys.filter { !$0.isEmpty && haystack.contains($0.lowercased()) }.count
        return Double(hits) * DecayEngine.effectiveWeight(m)
    }

    /// keywords 为空时沿用共享词面 token 兜底；汉字用相邻双字，不生成单字。
    fileprivate static func contentKeys(_ content: String) -> [String] {
        MemoryBM25.tokens(content)
    }

    /// 拼接到 system prompt
    static func inject(systemPrompt: String?, memories: [Memory]) -> String? {
        let injection = buildInjection(memories: memories)
        let base = systemPrompt ?? ""

        guard !injection.isEmpty else {
            return base.isEmpty ? nil : base
        }

        let block = "[关于用户]\n\(injection)"

        if base.isEmpty {
            return block
        }
        return "\(base)\n\n\(block)"
    }

    /// 打分：decayWeight × log(1 + accessCount)
    fileprivate static func score(_ memory: Memory) -> Double {
        DecayEngine.effectiveWeight(memory) * log(1.0 + Double(memory.accessCount))
    }
}

// MARK: - Embedding Backfill（M2：新记忆/旧存量/模型升级后的向量补算）

enum MemoryEmbeddingBackfill {
    private static let lock = NSLock()
    private static var _inFlight = false
    static var edgesSweepDone = false
    private static var inFlight: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _inFlight }
        set { lock.lock(); defer { lock.unlock() }; _inFlight = newValue }
    }

    struct Result: Sendable {
        let documents: [MemoryRetrievalDocument]
        let failedCount: Int
        let validVectorCount: Int
    }

    static func fill(_ documents: [MemoryRetrievalDocument], embedder: MemoryEmbedding, cancel: CatalogCancel? = nil) -> Result {
        let revision = embedder.revision
        let ready = embedder.isReady
        var filled: [UUID: MemoryRetrievalDocument] = [:]
        var results: [MemoryRetrievalDocument] = []
        for document in documents {
            guard cancel?.isCancelled != true else { break }
            if let existing = filled[document.id] { results.append(existing); continue }
            var result = document
            if ready, !document.hasValidVector(revision: revision),
               let vector = embedder.embed(document.content) {
                result.embeddingData = MemoryVector.data(from: vector)
                result.embeddingRevision = revision
            }
            guard cancel?.isCancelled != true else { break }
            filled[document.id] = result
            results.append(result)
        }
        let validCount = filled.values.reduce(0) { $0 + ($1.hasValidVector(revision: revision) ? 1 : 0) }
        return Result(documents: results, failedCount: filled.count - validCount, validVectorCount: validCount)
    }

    /// 编码期间原记录可能已改字、移楼、撤销或删除；不把旧快照的向量写回。
    @discardableResult
    static func persist(_ documents: [MemoryRetrievalDocument], container: ModelContainer, revision: Int,
                        isEligible: (Memory) -> Bool = { $0.supersededAt == nil }, cancel: CatalogCancel? = nil) throws -> [UUID] {
        try cancel?.check()
        var seen = Set<UUID>()
        var written: [UUID] = []
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for document in documents where seen.insert(document.id).inserted && document.hasValidVector(revision: revision) {
            try cancel?.check()
            let id = document.id
            let descriptor = FetchDescriptor<Memory>(predicate: #Predicate { $0.id == id })
            guard let row = try context.fetch(descriptor).first,
                  row.content == document.content, row.profileId == document.profileId,
                  isEligible(row) else { continue }
            guard row.embeddingData != document.embeddingData || row.embeddingRevision != document.embeddingRevision else { continue }
            row.embeddingData = document.embeddingData
            row.embeddingRevision = document.embeddingRevision
            written.append(id)
        }
        try cancel?.check()
        if context.hasChanges { try context.save() }
        return written
    }

    /// 给缺向量（或 revision 过期）的记忆补算。fire-and-forget，无事可做时零开销。
    /// 注入 fetch 处每轮调一次：新提取的记忆下一轮就有向量。
    static func run(memories: [Memory], context: ModelContext) {
        guard UserDefaults.standard.bool(forKey: "mem_inject_vector") else { return }
        let embedder = AppleMemoryEmbedder.shared
        guard embedder.isReady else {
            embedder.requestAssetsIfNeeded()
            return
        }
        guard !inFlight else { return }
        let rev = embedder.revision
        let pending = memories.filter { $0.supersededAt == nil && !MemoryRetrievalDocument($0).hasValidVector(revision: rev) }
        // M3 存量边扫描（每次启动一次）：M2 时期已 embed 但没建过边的
        if !edgesSweepDone {
            edgesSweepDone = true
            let edgeless = memories.filter { $0.embeddingData != nil && $0.relatedIds.isEmpty }.map(\.id)
            if !edgeless.isEmpty, let pid = memories.first?.profileId {
                Task { @MainActor in
                    MemoryGraph.linkEdges(newIds: edgeless, profileId: pid, context: context)
                }
            }
        }
        guard !pending.isEmpty else { return }
        inFlight = true
        let items = pending.map { MemoryRetrievalDocument($0) }
        let container = context.container

        CacheDiagLog.shared.log("🧠 向量回填启动: \(items.count) 条待补")
        Task.detached(priority: .utility) {
            let result = fill(items, embedder: embedder)
            let written: [UUID]
            do {
                written = try persist(result.documents, container: container, revision: rev)
            } catch {
                CacheDiagLog.shared.log("🧠 向量回填保存失败：\(error.localizedDescription)")
                written = []
            }
            await MainActor.run {
                inFlight = false
                // 成败都开口：失败数非零 = embed 在抛错，别再静默
                CacheDiagLog.shared.log("🧠 向量回填完成: 成功 \(result.validVectorCount) / 失败 \(result.failedCount)")
                // M3：只给实际写回的新向量顺手建边，读取同样使用新 context。
                let graphContext = ModelContext(container)
                let writtenIds = Set(written)
                let profiles = Dictionary(grouping: items.filter { writtenIds.contains($0.id) }, by: \.profileId)
                for (profileId, documents) in profiles {
                    MemoryGraph.linkEdges(newIds: documents.map(\.id), profileId: profileId, context: graphContext)
                }
            }
        }
    }
}

// MARK: - Memory Graph（M3：向量建边 + 一跳扩展）

enum MemoryGraph {
    static let edgeThreshold: Float = 0.6   // 比检索阈值严：边要更可信
    static let duplicateThreshold: Float = 0.95
    static let maxEdges = 5

    /// 给指定记忆建边（embed 完成后顺手跑）。对称写两边，每节点上限 5，疑似重复单独报。
    @MainActor
    static func linkEdges(newIds: [UUID], profileId: String, context: ModelContext) {
        let store = SwiftDataMemoryStore()
        let all = store.listHotAndWarm(profileId: profileId, context: context).filter { $0.embeddingData != nil }
        guard all.count > 1 else { return }
        var vecs: [UUID: [Float]] = [:]
        for m in all { vecs[m.id] = MemoryVector.floats(from: m.embeddingData!) }

        var built = 0
        for id in newIds {
            guard let m = all.first(where: { $0.id == id }), let v = vecs[id] else { continue }
            var scored: [(other: Memory, sim: Float)] = []
            for other in all where other.id != id {
                guard other.embeddingRevision == m.embeddingRevision, let ov = vecs[other.id] else { continue }
                let sim = MemoryVector.dot(v, ov)
                if sim >= edgeThreshold { scored.append((other, sim)) }
            }
            scored.sort { $0.sim > $1.sim }
            for (other, sim) in scored.prefix(maxEdges) {
                if !m.relatedIds.contains(other.id), m.relatedIds.count < maxEdges {
                    m.relatedIds.append(other.id)
                }
                if !other.relatedIds.contains(m.id), other.relatedIds.count < maxEdges {
                    other.relatedIds.append(m.id)
                }
                built += 1
                if sim >= duplicateThreshold {
                    CacheDiagLog.shared.log("🕸 图谱: ⚠️ 疑似重复 「\(m.content.prefix(12))」≈「\(other.content.prefix(12))」(\(String(format: "%.2f", sim)))")
                } else {
                    CacheDiagLog.shared.log("🕸 图谱: 「\(m.content.prefix(10))」↔「\(other.content.prefix(10))」(\(String(format: "%.2f", sim)))")
                }
            }
        }
        if built > 0 { try? context.save() }
    }
}

// MARK: - 记忆健康状态（plan-memory-usable 刀1）

/// 提取/做梦的生死可见：持久化最近成功/失败，设置页常驻展示。
/// 此前失败只有转瞬胶囊 + DEBUG print——提取模型不可达静默死 11 天无人知（report-记忆现状-2026-07-07）。
enum MemoryHealthStore {
    /// summary = 写窗口总结（key 沿用）；context = 写上下文摘要；timeline = 写时间轴（v4-1 Q8 三行）
    enum Kind: String { case extract, dream, summary, context, timeline }

    struct Status {
        var lastOK: Date?
        var lastError: Date?
        var lastErrorMessage: String?
        var failStreak: Int
        var modelName: String?
        /// 红点条件：连续失败 ≥3 次
        var needsAttention: Bool { failStreak >= 3 }
    }

    private static func key(_ kind: Kind, _ field: String, _ profileId: String) -> String {
        "mem_health_\(kind.rawValue)_\(field)_\(profileId)"
    }

    /// 这一项现在写不写（总开关 && 这一项）。关着 = 灰字「关着，没在写」，不亮红、计数不清（v5 · 0.1）
    static func isOn(_ kind: Kind) -> Bool {
        guard MemoryFlags.masterEnabled else { return false }
        switch kind {
        case .extract: return MemoryFlags.factsEnabled
        case .dream: return UserDefaults.standard.bool(forKey: "mem_content_profile")
        case .context: return MemoryFlags.contextSummaryEnabled
        case .summary: return MemoryFlags.windowSummaryEnabled
        case .timeline: return TimelineConsolidator.enabled
        }
    }

    /// note = 这次写了什么（记忆日志那条的说明）；A2 / A3 / A4 / C2 成败都在这里顺手记一条日志（v5 §十一）
    /// rejected = C2 这次拒收了几张（「本周拒收 N 次」从日志里数）
    static func recordOK(_ kind: Kind, profileId: String, modelName: String, note: String = "写好了", rejected: Int? = nil) {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: key(kind, "ok", profileId))
        d.set(0, forKey: key(kind, "streak", profileId))
        d.set(modelName, forKey: key(kind, "model", profileId))
        MemoryWriteLog.record(kind, profileId: profileId, ok: true, note: note, model: modelName, rejected: rejected, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
    }

    static func recordError(_ kind: Kind, profileId: String, message: String, modelName: String, rejected: Int? = nil) {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: key(kind, "err", profileId))
        d.set(String(message.prefix(200)), forKey: key(kind, "errmsg", profileId))
        let streak = failStreak(kind, profileId: profileId) + 1
        d.set(streak, forKey: key(kind, "streak", profileId))
        d.set(modelName, forKey: key(kind, "model", profileId))
        MemoryWriteLog.record(kind, profileId: profileId, ok: false, note: String(message.prefix(200)), model: modelName, rejected: rejected, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        // needsAttention 由假变真：小芽横幅喊一声（plan-status-panel §7.7）
        if streak == 3 {
            DispatchQueue.main.async { XiaoyaNoticeCenter.shared.noteMemoryFailing(kind, profileId: profileId, streak: streak) }
        }
    }

    static func failStreak(_ kind: Kind, profileId: String) -> Int {
        UserDefaults.standard.integer(forKey: key(kind, "streak", profileId))
    }

    static func status(_ kind: Kind, profileId: String) -> Status {
        let d = UserDefaults.standard
        let ok = d.double(forKey: key(kind, "ok", profileId))
        let err = d.double(forKey: key(kind, "err", profileId))
        return Status(
            lastOK: ok > 0 ? Date(timeIntervalSince1970: ok) : nil,
            lastError: err > 0 ? Date(timeIntervalSince1970: err) : nil,
            lastErrorMessage: d.string(forKey: key(kind, "errmsg", profileId)),
            failStreak: d.integer(forKey: key(kind, "streak", profileId)),
            modelName: d.string(forKey: key(kind, "model", profileId))
        )
    }
}
