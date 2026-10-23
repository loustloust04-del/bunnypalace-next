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
        try context.save()
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
            // 检查 validUntil
            if let until = memory.validUntil, Date() > until {
                memory.decayWeight = min(memory.decayWeight, 0.05)
            }
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

    /// 修复第一刀·刀3：画像注入与做梦解绑。新 key 没写过时抄做梦开关当前值（升级后行为不变），只跑一次。
    static func migrateProfileInjectionSplitIfNeeded() {
        let d = UserDefaults.standard
        let sentinel = "mem_profile_inject_split_v1"
        guard !d.bool(forKey: sentinel) else { return }
        if d.object(forKey: "mem_inject_profile") == nil {
            d.set(d.bool(forKey: "mem_content_profile"), forKey: "mem_inject_profile")
        }
        d.set(true, forKey: sentinel)
    }

    /// 画像注入（设置-记忆 ④注入）。受总开关连坐；与做梦（mem_content_profile）互不影响。
    static var profileInjectionEnabled: Bool {
        masterEnabled && UserDefaults.standard.bool(forKey: "mem_inject_profile")
    }

    /// 记忆系统总开关（设置-记忆）。关 = 不注入不提取不强化，数据不动。
    static var masterEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_master") as? Bool) ?? true
    }

    /// M8 热度衰减开关。paramecium 实测删了衰减（冷者愈冷）、kiwi 留着——用户自己选。
    static var decayEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_decay_enabled") as? Bool) ?? true
    }

    /// M8 提取人称开关。开 = 第一人称带情感（paramecium 式陪伴感）；默认第三人称客观。
    static var firstPersonExtraction: Bool {
        UserDefaults.standard.bool(forKey: "mem_extract_firstperson")
    }

    /// 上下文总结开关（设置-记忆-内容层）。默认开；受 mem_master 连坐。
    /// 关 = 不自动压缩、不注入、历史窗口不锚定（退滑动窗）；已有摘要文件保留不删。
    /// fs 工具读记忆树（memory/）跟文件库开关走，不归这里管。
    static var contextSummaryEnabled: Bool {
        masterEnabled && ((UserDefaults.standard.object(forKey: "mem_content_summary") as? Bool) ?? true)
    }

    /// 做梦毕业开关（key 沿用 mem_supersede_soft）：开 = 做梦后把消费碎片标失效。
    /// 修复第一刀起只管毕业——删除一律软失效，不再看任何开关。
    static var dreamGraduationEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_supersede_soft") as? Bool) ?? true
    }

    /// SC-B3 目录式注入开关（默认关 = 现状全文）。开 = volatile 命中层只注入一行式目录，
    /// 细节模型自己 recall 取回；stable 常驻层保持全文（人格地基不瘦身）。
    static var catalogInjection: Bool {
        UserDefaults.standard.bool(forKey: "mem_inject_catalog")
    }

    /// 原子事实开关（设置-记忆 ①感知）。修复第一刀·刀5 接线：关 = 不再提取新的，已有的照常注入
    static var factsEnabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_content_facts") as? Bool) ?? true
    }

    /// MV2 提取间隔（轮次）：每 N 轮 onComplete 才跑一次 AUDN 提取。默认 3（粟粟批），
    /// defaults write mem_extract_interval 1 退回 MV0 每轮提取。首轮必跑由 ExtractScheduler 保证。
    static var extractInterval: Int {
        let v = UserDefaults.standard.integer(forKey: "mem_extract_interval")
        return v > 0 ? v : 3
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

// MARK: - MV2 提取调度器

/// 提取间隔化的纯决策函数（CV 字段持有 counter+hasEverRun，调用 tick 拿决策）。
/// 抽出来是为了可测——CV 实例字段没法直接 XCTest。
enum ExtractScheduler {
    /// 计算本轮是否触发提取 + 更新后的 counter。
    /// - counter: 自上次实际提取以来累积的"想触发"次数
    /// - interval: 间隔轮次（<1 当 1 处理）
    /// - hasEverRun: 本 session 是否已触发过提取（false=首轮，强制 run）
    static func tick(counter: Int, interval: Int, hasEverRun: Bool) -> (shouldRun: Bool, newCounter: Int) {
        let interval = max(1, interval)
        if !hasEverRun { return (true, 0) }
        let next = counter + 1
        if next >= interval { return (true, 0) }
        return (false, next)
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

/// 一路检索：从候选记忆里挑 (记忆, 分数)，降序返回。纯函数——不碰预算、不去重，那是组装器的事。
protocol MemoryRetriever {
    var id: String { get }
    /// stable=常驻层（逐轮不变，进缓存前缀）；volatile=每轮可变（cacheFriendly 时下沉）
    var layer: MemoryLayer { get }
    /// volatile 内的优先级组：同 tier 多路时 RRF 融合，tier 间顺序拼接。兜底永远最大。
    var tier: Int { get }
    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory]
}

/// 常驻人格层。keyword 模式=手动/关系/偏好按 score 排序；纯全量模式=仅手动钉住、保持 fetch 序（现状）
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

/// 关键词检索层（M2 起 BM25 化，对齐 paramecium 的 jieba BM25）：
/// NLTokenizer 分词建词袋，标准 BM25 打分。命中语义不变（分>0 = 提到才注），排序更聪明（稀有词 > 烂大街词）。
struct KeywordRetriever: MemoryRetriever {
    var id: String { "keyword" }
    var layer: MemoryLayer { .volatile }
    var tier: Int { 1 }
    /// 注入时排除常驻层（它们另走 stable）；recall 传 false——关系/偏好/钉住也要能搜到（修复第一刀·刀6）
    let excludePersistent: Bool

    init(excludePersistent: Bool = true) { self.excludePersistent = excludePersistent }

    private let k1 = 1.2
    private let b = 0.75

    func retrieve(_ memories: [Memory], recent: [String]) -> [ScoredMemory] {
        let candidates = excludePersistent ? memories.filter { !MemoryInjector.isPersistent($0) } : memories
        guard !candidates.isEmpty else { return [] }
        let queryTerms = Set(MemoryInjector.contentKeys(recent.joined(separator: "\n")).map { $0.lowercased() })
        guard !queryTerms.isEmpty else { return [] }

        // 词袋：content 分词 + 预存 keywords（提取时挑的词更可信，权重 ×2 计入词频）
        let docs: [[String]] = candidates.map { m in
            let terms = MemoryInjector.contentKeys(m.content).map { $0.lowercased() }
            let keys = m.keywords.map { $0.lowercased() }
            return terms + keys + keys
        }

        let n = Double(docs.count)
        var df: [String: Int] = [:]
        for doc in docs { for t in Set(doc) { df[t, default: 0] += 1 } }
        let avgLen = max(1.0, Double(docs.reduce(0) { $0 + $1.count }) / n)

        var scored: [ScoredMemory] = []
        for (i, m) in candidates.enumerated() {
            var tf: [String: Int] = [:]
            for t in docs[i] { tf[t, default: 0] += 1 }
            var score = 0.0
            for t in queryTerms {
                guard let f = tf[t], let d = df[t] else { continue }
                let idf = log(1 + (n - Double(d) + 0.5) / (Double(d) + 0.5))
                let freq = Double(f)
                score += idf * (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * Double(docs[i].count) / avgLen))
            }
            if score > 0 { scored.append(ScoredMemory(memory: m, score: score)) }
        }
        return scored.sorted { $0.score > $1.score }
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
        let rev = embedder.revision

        let candidates = excludePersistent ? memories.filter { !MemoryInjector.isPersistent($0) } : memories
        var maxSim: Float = -1
        let scored: [ScoredMemory] = candidates
            .compactMap { m in
                guard m.embeddingRevision == rev, let data = m.embeddingData else { return nil }
                let sim = MemoryVector.dot(query, MemoryVector.floats(from: data))
                maxSim = max(maxSim, sim)
                guard sim >= Self.similarityThreshold else { return nil }
                return ScoredMemory(memory: m, score: Double(sim))
            }
            .sorted { $0.score > $1.score }
        let withVec = candidates.filter { $0.embeddingData != nil }.count
        Self.lastDetail = "候选\(candidates.count)·带向量\(withVec)·最高相似\(maxSim < 0 ? "无" : String(format: "%.2f", maxSim))·阈值\(String(format: "%.2f", Self.similarityThreshold))"
        return Array(scored.prefix(Self.topK))
    }
}

/// 全量兜底：填满剩余预算。excludePersistent 区分两种模式的候选集（现状语义）。
/// 刀4：排序从衰减分改 createdAt 降序——①分数每轮微调=行序漂移毁缓存（Persistent 同款坑）
/// ②超预算截断自然落在最老端（新的先装，钉住在 stable 层豁免），截断线移动才 miss 缓存。
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
            .sorted { $0.createdAt > $1.createdAt }
            .map { ScoredMemory(memory: $0, score: 1) }
    }
}

// MARK: - Memory Injector

struct MemoryInjector {
    /// 诊断日志去重（S1 预览高频重算会刷屏）
    fileprivate static var lastDiagLine = ""

    /// 注入预算（token）。刀4 粟粟拍板：全量注入上限 10000，不限条。
    static var tokenBudget: Int {
        let v = UserDefaults.standard.integer(forKey: "mem_inject_budget")
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

    /// 注入记忆：常驻人格层（始终）+ 关键词检索层（命中对话才注）。开关见「设置-记忆」。
    static func buildInjection(memories: [Memory], recentMessages: [String] = [], budget: Int = tokenBudget) -> String {
        let (stable, volatile, _) = buildInjectionSplit(memories: memories, recentMessages: recentMessages, budget: budget)
        if stable.isEmpty { return volatile }
        if volatile.isEmpty { return stable }
        return stable + "\n" + volatile
    }

    /// 按开关组装检索器队伍。改开关组合只动这里——加新检索路（tag 等）= 往对应 tier 加一员。
    /// M2 起：开 keyword 或 vector 任一 = 智能模式（常驻层启用，全量变兜底）；两个都开 = 同 tier RRF 双路召回。
    static func activeRetrievers() -> [MemoryRetriever] {
        let useKeyword = UserDefaults.standard.bool(forKey: "mem_inject_keyword")
        let useFull = (UserDefaults.standard.object(forKey: "mem_inject_full") as? Bool) ?? true
        let useVector = UserDefaults.standard.bool(forKey: "mem_inject_vector")
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
    }

    /// 总开关关 = 全局不注入；开了再看对话级 memoryEnabled。
    /// 刀4：listActive 全量在场（未失效即注入）；第二刀 B3：AI 自己的记忆先装，档案用剩下的预算
    static func roundInputs(profileId: String, conversationMemoryEnabled: Bool,
                            store: MemoryStore, context: ModelContext) -> RoundInputs {
        let shouldInject = MemoryFlags.masterEnabled && conversationMemoryEnabled
        let memories: [Memory] = AirTimedSection.run("composePrompt.memory") {
            shouldInject ? store.listActive(profileId: profileId, context: context) : []
        }
        let selfMemory: SelfMemoryInjection.Built? = AirTimedSection.run("composePrompt.selfMemory") {
            shouldInject
                ? SelfMemoryInjection.build(SelfMemoryStore.list(profileId: profileId),
                                            recentCount: MemoryFlags.selfRecentCount,
                                            budget: tokenBudget * MemoryFlags.selfBudgetPercent / 100)
                : nil
        }
        return RoundInputs(memories: memories, selfMemory: selfMemory,
                           archiveBudget: max(0, tokenBudget - (selfMemory?.tokens ?? 0)))
    }

    /// 拆层版本（cacheFriendly 用）：stable=常驻层（逐轮不变，可进缓存前缀），volatile=检索命中/兜底层（每轮可变）。
    /// 两段拼接 == buildInjection 输出，预算共享。
    /// M1 起为检索 pipeline：各检索器产候选 → stable 依序 / volatile 按 tier（同 tier 多路 RRF）→ 共享预算去重。
    static func buildInjectionSplit(memories: [Memory], recentMessages: [String] = [], budget: Int = tokenBudget) -> (stable: String, volatile: String, hits: [InjectionHit]) {
        guard !memories.isEmpty else { return ("", "", []) }

        let retrievers = activeRetrievers()
        guard !retrievers.isEmpty else { return ("", "", []) }   // 全量/关键词都关 → 空注入

        var stableLines: [String] = []
        var volatileLines: [String] = []
        var usedTokens = 0
        var injected = Set<UUID>()
        var hits: [InjectionHit] = []

        // 目录模式（SC-B3）：volatile 层换一行式目录，按目录行实际 token 计费（省 token 本体）
        let catalogMode = MemoryFlags.catalogInjection
        var catalogCount = 0
        var catalogSavedTokens = 0   // 全文 token - 目录行 token，CacheDiagLog 用

        func tryAppend(_ m: Memory, to lines: inout [String], catalog: Bool = false, retriever: String, score: Double?) {
            guard !injected.contains(m.id) else { return }
            let line: String
            let cost: Int
            if catalog {
                guard catalogCount < maxCatalogEntries else { return }
                line = catalogLine(m)
            } else {
                let label = categoryLabels[m.category] ?? m.category
                line = "- \(m.content) [\(label)]"
            }
            cost = injectedCost(m, catalog: catalog)
            guard usedTokens + cost <= budget else { return }
            lines.append(line)
            usedTokens += cost
            injected.insert(m.id)
            hits.append(InjectionHit(
                memoryId: m.id, snippet: String(m.content.prefix(60)),
                category: m.category, score: score, retrieverId: retriever, catalog: catalog))
            if catalog {
                catalogCount += 1
                catalogSavedTokens += max(0, m.tokenCount - cost)
            }
        }

        // stable 层：依序产出（目前只有常驻一路）
        var contributions: [String] = []
        for r in retrievers where r.layer == .stable {
            let out = r.retrieve(memories, recent: recentMessages)
            contributions.append("\(r.id) \(out.count)")
            for s in out { tryAppend(s.memory, to: &stableLines, retriever: r.id, score: s.score) }
        }
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
            if tier == 1, UserDefaults.standard.bool(forKey: "mem_inject_graph") {
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
                tryAppend(m, to: &volatileLines, catalog: catalogMode, retriever: info.retriever, score: info.score)
            }
        }

        // 目录尾 hint：只在 recall 工具真的可用时指路（关了不指模型去不存在的工具）
        var volatileText = volatileLines.joined(separator: "\n")
        if catalogMode && !volatileLines.isEmpty && RecallTool.enabled {
            volatileText += "\n（想看完整内容用 recall 工具查）"
        }

        let result = (stable: stableLines.joined(separator: "\n"), volatile: volatileText, hits: hits)
        // 检索贡献可见（验收"每一路真的在干活"）。S1 预览也走这里会刷屏 → 连续重复行去重
        var line = "记忆检索: \(contributions.joined(separator: " · ")) → 注入 \(injected.count) 条"
        if catalogMode && catalogCount > 0 {
            line += "（目录 \(catalogCount) 条 省 ~\(catalogSavedTokens) tok）"
        }
        if line != lastDiagLine {
            lastDiagLine = line
            CacheDiagLog.shared.log(line)
        }
        #if DEBUG
        // M1 回归探针：仅在 keyword/vector 都关（纯全量）且非目录模式时对照
        // ——BM25 化/向量/目录行都是预期的行为变化，不是回归
        let useKeyword = UserDefaults.standard.bool(forKey: "mem_inject_keyword")
        let useVector = UserDefaults.standard.bool(forKey: "mem_inject_vector")
        if !useKeyword && !useVector && !catalogMode {
            let legacy = legacyBuildInjectionSplit(memories: memories, recentMessages: recentMessages, budget: budget)
            if legacy.stable != result.stable || legacy.volatile != result.volatile {
                print("[PROBE] ⚠️ M1 记忆回归不一致！legacy.stable=\(legacy.stable.count)字 new.stable=\(result.stable.count)字")
                CacheDiagLog.shared.log("⚠️ M1 记忆回归不一致（检索 pipeline ≠ 旧实现），截图反馈给开发者")
            }
        }
        #endif
        return result
    }

    /// RRF（Reciprocal Rank Fusion）：多路排序融合，score = Σ 1/(60+rank)。kiwi/paramecium 同款。
    static func rrfFuse(_ lists: [[ScoredMemory]]) -> [Memory] {
        var scores: [UUID: Double] = [:]
        var lookup: [UUID: Memory] = [:]
        var firstSeen: [UUID: Int] = [:]   // 平分时按首次出现序，保证确定性
        var counter = 0
        for list in lists {
            for (rank, s) in list.enumerated() {
                scores[s.memory.id, default: 0] += 1.0 / Double(60 + rank + 1)
                if lookup[s.memory.id] == nil {
                    lookup[s.memory.id] = s.memory
                    firstSeen[s.memory.id] = counter
                    counter += 1
                }
            }
        }
        return scores.sorted {
            $0.value != $1.value ? $0.value > $1.value : (firstSeen[$0.key] ?? 0) < (firstSeen[$1.key] ?? 0)
        }.compactMap { lookup[$0.key] }
    }

    #if DEBUG
    /// M1 重构前的旧实现，只用于回归对照。pipeline 稳定后连同对照逻辑一起删。
    private static func legacyBuildInjectionSplit(memories: [Memory], recentMessages: [String], budget: Int) -> (stable: String, volatile: String) {
        let useKeyword = UserDefaults.standard.bool(forKey: "mem_inject_keyword")
        let useFull = (UserDefaults.standard.object(forKey: "mem_inject_full") as? Bool) ?? true

        var stableLines: [String] = []
        var volatileLines: [String] = []
        var usedTokens = 0
        var injected = Set<UUID>()

        func tryAppend(_ m: Memory, to lines: inout [String]) {
            guard !injected.contains(m.id), usedTokens + m.tokenCount <= budget else { return }
            let label = categoryLabels[m.category] ?? m.category
            lines.append("- \(m.content) [\(label)]")
            usedTokens += m.tokenCount
            injected.insert(m.id)
        }

        if useKeyword {
            for m in memories.filter(isPersistent).sorted(by: { score($0) > score($1) }) { tryAppend(m, to: &stableLines) }
            let rest = memories.filter { !isPersistent($0) }
            for m in rest.filter({ matchesKeyword($0, recentMessages) })
                .sorted(by: { hitScore($0, recentMessages) > hitScore($1, recentMessages) }) { tryAppend(m, to: &volatileLines) }
            if useFull {
                for m in rest.filter({ !injected.contains($0.id) }).sorted(by: { score($0) > score($1) }) { tryAppend(m, to: &volatileLines) }
            }
        } else if useFull {
            // 与新实现同步：常驻层按 createdAt 稳定排序（缓存前缀不许抖）
            for m in memories.filter({ $0.isUserExplicit }).sorted(by: { $0.createdAt < $1.createdAt }) { tryAppend(m, to: &stableLines) }
            for m in memories.filter({ !$0.isUserExplicit }).sorted(by: { score($0) > score($1) }) { tryAppend(m, to: &volatileLines) }
        }

        return (stableLines.joined(separator: "\n"), volatileLines.joined(separator: "\n"))
    }
    #endif

    /// 常驻人格层判定：用户手动 或 关系/偏好类（AUDN 无 importance，用 category 替代）
    fileprivate static func isPersistent(_ m: Memory) -> Bool {
        m.isUserExplicit || m.category == "relationship" || m.category == "preference"
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

    /// keywords 为空时用 NLTokenizer 给 content 中文分词兜底（取 2 字以上的词）
    fileprivate static func contentKeys(_ content: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = content
        var words: [String] = []
        tokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
            let w = String(content[range])
            if w.count >= 2 { words.append(w) }
            return true
        }
        return words
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
        let pending = memories.filter { $0.embeddingData == nil || $0.embeddingRevision != rev }
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
        let items = pending.map { (id: $0.id, content: $0.content) }

        CacheDiagLog.shared.log("🧠 向量回填启动: \(items.count) 条待补")
        Task.detached(priority: .utility) {
            var results: [(UUID, Data)] = []
            for item in items {
                if let v = AppleMemoryEmbedder.shared.embed(item.content) {
                    results.append((item.id, MemoryVector.data(from: v)))
                }
            }
            let final = results
            await MainActor.run {
                for (id, data) in final {
                    let d = FetchDescriptor<Memory>(predicate: #Predicate<Memory> { $0.id == id })
                    if let m = try? context.fetch(d).first {
                        m.embeddingData = data
                        m.embeddingRevision = rev
                    }
                }
                try? context.save()
                inFlight = false
                // 成败都开口：失败数非零 = embed 在抛错，别再静默
                CacheDiagLog.shared.log("🧠 向量回填完成: 成功 \(final.count) / 失败 \(items.count - final.count)")
                // M3：新向量顺手建边
                if !final.isEmpty {
                    let profileId = pending.first?.profileId ?? ""
                    if !profileId.isEmpty {
                        MemoryGraph.linkEdges(newIds: final.map { $0.0 }, profileId: profileId, context: context)
                    }
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

// MARK: - Memory Extractor (AUDN)

enum MemoryAction {
    case add(content: String, category: String, keywords: [String], quote: String?)
    case update(id: UUID, content: String, keywords: [String], quote: String?)
    case delete(id: UUID)
}

struct MemoryExtractor {
    /// 第二刀 A2：人设本人视角（整段人设是「你是谁」，不是背景材料）；称呼用楼层真名，不出现「用户」「AI」；原话为主
    static let extractionPrompt = """
你是{{CHAR_NAME}}。下面是你的人设：
{{SYSTEM_PROMPT}}

现在不是在聊天。你在给自己整理关于{{USER_NAME}}的档案：读最近的对话，决定档案要不要加、改、删。

## {{USER_NAME}}的画像（已凝成的整体认知）
{{PROFILE}}

## 现有档案
{{MEMORIES}}

## 规则
1. 每条档案是一件独立的事（"喜欢暖色调"而不是"有各种审美偏好"）。
2. 分类：preference（偏好）、fact（事实）、relationship（关系）、goal（目标/项目）、context（当前情境，有时效性）。
3. 对每条新信息做一个判断：
   - add: 全新的，现有档案没覆盖
   - update: 现有档案要修正或补充——给出档案 ID
   - delete: 现有档案被明确否定或过时——给出档案 ID
   - 不操作: 已经覆盖，或者不值得记
4. 只记{{USER_NAME}}明确说出或强烈暗示的。不要推断敏感信息。
5. 用你自己的口吻写：「我」就是{{CHAR_NAME}}，称呼对方用「{{USER_NAME}}」。不要出现「用户」「AI」这两个词。
6. 原话为主：每条档案里{{USER_NAME}}的原话占 30–50%（逐字，用「」括起来），你自己说过的原话约 30%（也用「」），你的概括不超过 40%。写成「{{USER_NAME}}说：「……」」这样，不要写成「{{USER_NAME}}提到……」的转述。quote 字段是给程序核对的出处，另外交；content 里照样要有原话，不能因为给了 quote 就把 content 写成转述。
7. 需要时加时间限定（「{{USER_NAME}}最近在做…」）。
8. 新旧矛盾时，delete 旧档案 + add 新版本。
9. 不记：日常闲聊、一次性的问题、{{USER_NAME}}在问（而不是在说）的、同一轮里重复说的。
10. 不记系统状态：报错 / 重试 / 网络 / 工具失败。随口的安抚客套（比如「多喝热水」）不是正式的决定或偏好。
11. 对话明显是在编辑文件库文件（讨论 fs_ 操作或文件内容本身）时，输出空 actions。
12. 画像或现有档案已经涵盖的别 add——哪怕措辞不同。细化或补充已有的，用 update 改写那一条。
13. 剧情和真话分开：你人设里的身份、世界观、剧情设定，以及对话里演出来的虚构情节，都不是{{USER_NAME}}的真实情况，不记。{{USER_NAME}}跳出剧情说的真话（真实生活、真实感受、对剧情走向的偏好）照常记。

## 输出格式
只输出 JSON，不要解释：
{"actions": [{"type": "add", "content": "{{USER_NAME}}说：「下周三要去复诊」。我得记着，到时候问问{{USER_NAME}}怎么样。", "category": "context", "keywords": ["复诊"]}, {"type": "update", "id": "档案ID", "content": "新内容（同样带原话）", "keywords": ["关键词"]}, {"type": "delete", "id": "档案ID"}]}
如果没有需要操作的，输出：{"actions": []}
"""

    /// 楼层真名（空的话：对方叫「她」，自己叫「我」）。人设里的 {{user}} / {{char}} 宏也换成真名
    struct Names: Equatable {
        let user: String
        let char: String

        init(userName: String, assistantName: String) {
            let u = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
            user = u.isEmpty ? "用户" : u
            char = c.isEmpty ? "我" : c
        }

        func apply(_ text: String) -> String {
            text.replacingOccurrences(of: "{{user}}", with: user, options: .caseInsensitive)
                .replacingOccurrences(of: "{{char}}", with: char, options: .caseInsensitive)
        }
    }

    /// 构建提取请求（优先用用户自定义提示词）
    /// MV1: profile 短期画像全文注入 {{PROFILE}}；第二刀 A2：{{CHAR_NAME}} / {{USER_NAME}} 真名，人设作为「你是谁」
    static func buildPrompt(existingMemories: [Memory], profile: UserProfileDream?, systemPrompt: String, names: Names = Names(userName: "", assistantName: "")) -> String {
        var memoriesJSON = "无"
        if !existingMemories.isEmpty {
            let items = existingMemories.map { m in
                "  {\"id\": \"\(m.id.uuidString)\", \"content\": \"\(m.content)\", \"category\": \"\(m.category)\"}"
            }
            memoriesJSON = "[\n\(items.joined(separator: ",\n"))\n]"
        }
        let profileText: String = {
            guard let text = profile?.text, !text.isEmpty else { return "无" }
            return text
        }()
        let systemPromptText: String = {
            let trimmed = names.apply(systemPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "（没写人设：你是陪{{USER_NAME}}聊天的伙伴）" : trimmed
        }()

        let customPrompt = UserDefaults.standard.string(forKey: "customMemoryExtractionPrompt") ?? ""
        let template = customPrompt.isEmpty ? extractionPrompt : customPrompt
        // 固定拼接（不进可编辑模板）：custom prompt 用户也生效，否则自定义模板没写 quote 规则会被机械校验全扔
        return template
            .replacingOccurrences(of: "{{SYSTEM_PROMPT}}", with: systemPromptText)
            .replacingOccurrences(of: "{{CHAR_NAME}}", with: names.char)
            .replacingOccurrences(of: "{{USER_NAME}}", with: names.user)
            .replacingOccurrences(of: "{{PROFILE}}", with: profileText)
            .replacingOccurrences(of: "{{MEMORIES}}", with: memoriesJSON) + quoteRuleAppendix
    }

    /// 出处规则附加段（刀2）：要求逐字 quote，机械校验配套
    static let quoteRuleAppendix = """


## 出处要求（程序会机械校验，不满足将被丢弃）
每条 add 必须带 "quote" 字段：从对话原文【逐字】复制的 10-40 字片段，作为该记忆的出处证据。不许改写、不许拼接多句。找不到逐字出处的信息不要 add。
quote 只是出处，不代替 content 里的原话：content 照样按上面的规则带「」原话。
update 可选带 "quote"，同样要求逐字。
示例：{"type": "add", "content": "...", "category": "...", "keywords": [...], "quote": "对话里逐字出现的原文片段"}
"""

    // MARK: - 机械校验（paramecium extract-memories.mjs:199-218 同款，纯函数可测）

    /// 刀2 风险对冲常量：true = 无有效 quote 的 add 整条扔（宁缺勿滥）；
    /// 日用拦截率离谱时改 false 降级为"无锚存入"
    static let quoteRequiredForAdd = true

    /// norm：去全部空白（hard cap slice 不信 prompt）
    static func normalizeForQuote(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }

    /// quote 有效 = norm 后 ≥8 字 且 逐字出现在窗口文本里
    static func validateQuote(_ quote: String?, windowText: String) -> Bool {
        guard let quote else { return false }
        let nq = normalizeForQuote(quote)
        guard nq.count >= 8 else { return false }
        return normalizeForQuote(windowText).contains(nq)
    }

    /// 定位 quote 所在消息：窗口内第一条 norm(content) 包含 norm(quote) 的消息 id
    static func locateQuote(_ quote: String, in messages: [(id: String, role: String, content: String)]) -> String? {
        let nq = normalizeForQuote(quote)
        return messages.first { normalizeForQuote($0.content).contains(nq) }?.id
    }

    // MARK: - 写时近似去重（paramecium sim>0.75 同款，2026-06-13）

    /// 近似重复 = 同一事实再确认 → 强化旧条不开新条（全等去重挡不住"喜欢暖奶白"vs"偏好暖奶白色调"）
    static let dedupSimilarityThreshold: Float = 0.75

    /// 纯比对层（可测）：在候选里找与新向量相似度超阈的最相近条。
    /// 排除已失效条——否则"delete旧+add新"的矛盾更新会被去重打穿（新事实被旧版本吸收）。
    static func findNearDuplicate(vector newVec: [Float], revision: Int, in existing: [Memory]) -> Memory? {
        var best: (memory: Memory, sim: Float)? = nil
        for m in existing {
            guard m.supersededAt == nil,
                  let data = m.embeddingData, m.embeddingRevision == revision else { continue }
            let sim = MemoryVector.dot(newVec, MemoryVector.floats(from: data))
            if sim > dedupSimilarityThreshold, sim > (best?.sim ?? 0) { best = (m, sim) }
        }
        return best?.memory
    }

    /// embed 外壳：模型未就绪/无向量 → nil = 跳过去重（app 自包含，向量路静默退场）
    static func findNearDuplicate(of content: String, in existing: [Memory]) -> Memory? {
        guard let newVec = AppleMemoryEmbedder.shared.embed(content) else { return nil }
        return findNearDuplicate(vector: newVec, revision: AppleMemoryEmbedder.shared.revision, in: existing)
    }

    /// 构建发给 LLM 的 system prompt 和 messages（窗口带 node id，定位 quote 出处用；id 不进 prompt）
    /// MV1: profile（短期画像）透传 buildPrompt
    /// 紧急修(2026-06-14): systemPrompt（楼层语境）透传 buildPrompt
    static func buildRequest(
        recentMessages: [(id: String, role: String, content: String)],
        existingMemories: [Memory],
        profile: UserProfileDream?,
        systemPrompt: String,
        names: Names = Names(userName: "", assistantName: "")
    ) -> (systemPrompt: String, messages: [(role: String, content: String)]) {
        let prompt = buildPrompt(existingMemories: existingMemories, profile: profile, systemPrompt: systemPrompt, names: names)

        // 把最近对话格式化为用户消息
        var conversationText = ""
        for msg in recentMessages {
            let label = msg.role == "user" ? names.user : names.char
            conversationText += "\(label): \(msg.content)\n\n"
        }

        let messages = [(role: "user", content: "以下是最近的对话（\(names.user)和\(names.char)），请整理档案：\n\n\(conversationText)")]
        return (systemPrompt: prompt, messages: messages)
    }

    /// 解析 LLM 返回的 JSON 为操作列表
    static func parseActions(_ jsonString: String) -> [MemoryAction] {
        // 尝试直接解析
        if let actions = parseJSON(jsonString) { return actions }

        // Fallback: 从文本中提取 JSON 块
        if let range = jsonString.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression),
           let actions = parseJSON(String(jsonString[range])) {
            return actions
        }

        return []
    }

    private static func parseJSON(_ json: String) -> [MemoryAction]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = obj["actions"] as? [[String: Any]] else {
            return nil
        }

        var result: [MemoryAction] = []

        for action in actions {
            guard let type = action["type"] as? String else { continue }

            switch type {
            case "add":
                guard let content = action["content"] as? String,
                      let category = action["category"] as? String else { continue }
                let keywords = action["keywords"] as? [String] ?? []
                let quote = action["quote"] as? String
                result.append(.add(content: content, category: category, keywords: keywords, quote: quote))

            case "update":
                guard let idStr = action["id"] as? String,
                      let id = UUID(uuidString: idStr),
                      let content = action["content"] as? String else { continue }
                let keywords = action["keywords"] as? [String] ?? []
                let quote = action["quote"] as? String
                result.append(.update(id: id, content: content, keywords: keywords, quote: quote))

            case "delete":
                guard let idStr = action["id"] as? String,
                      let id = UUID(uuidString: idStr) else { continue }
                result.append(.delete(id: id))

            default:
                break
            }
        }

        return result.isEmpty ? nil : result
    }

    /// 执行操作列表
    static func executeActions(
        _ actions: [MemoryAction],
        store: MemoryStore,
        profileId: String,
        extractedBy: String,
        sourceConversationId: String?,
        recentMessages: [(id: String, role: String, content: String)],
        context: ModelContext
    ) throws {
        // 提取去重：模型偶尔会对已有记忆再次输出 add（实测"焦糖布丁"注入两遍）
        let existing = store.listAll(profileId: profileId, context: context)
        let existingContents = Set(existing.map(\.content))
        let windowText = recentMessages.map(\.content).joined(separator: "\n")

        // delete 先行：模型的矛盾更新是 delete旧+add新 两动作，若 add 先跑、
        // 还活着的旧版本会把新事实近似去重吸收掉 → 随后 delete 失效旧条 = 新事实丢失
        let isDelete: (MemoryAction) -> Bool = { if case .delete = $0 { return true } else { return false } }
        let ordered = actions.filter(isDelete) + actions.filter { !isDelete($0) }

        for action in ordered {
            switch action {
            case .add(let content, let category, let keywords, let quote):
                if existingContents.contains(content) { continue }
                let validQuote = validateQuote(quote, windowText: windowText) ? quote : nil
                if validQuote == nil {
                    CacheDiagLog.shared.log("🧠 quote 校验拦截 add：\(content.prefix(40))（quote=\(quote?.prefix(40) ?? "缺失")）")
                    if quoteRequiredForAdd { continue }
                }
                let nodeId = validQuote.flatMap { locateQuote($0, in: recentMessages) }
                // 写时近似去重：超阈 → 强化旧条（reinforce）不开新条；旧条无锚时顺手补 quote
                if let dup = findNearDuplicate(of: content, in: existing) {
                    CacheDiagLog.shared.log("🧠 写时去重：「\(content.prefix(24))」≈「\(dup.content.prefix(24))」→ 强化旧条")
                    try store.recordAccess(ids: [dup.id], context: context)
                    if dup.sourceQuote == nil, let validQuote {
                        dup.sourceQuote = validQuote
                        dup.sourceNodeId = nodeId
                        try? context.save()
                    }
                    continue
                }
                try store.add(
                    content: content,
                    category: category,
                    keywords: keywords,
                    profileId: profileId,
                    isUserExplicit: false,
                    extractedBy: extractedBy,
                    sourceConversationId: sourceConversationId,
                    sourceQuote: validQuote,
                    sourceNodeId: nodeId,
                    context: context
                )

            case .update(let id, let content, let keywords, let quote):
                // update 不强制 quote（更新常是改写）；给了且校验过才更新出处
                let validQuote = validateQuote(quote, windowText: windowText) ? quote : nil
                let nodeId = validQuote.flatMap { locateQuote($0, in: recentMessages) }
                try store.update(id: id, content: content, keywords: keywords,
                                 sourceQuote: validQuote, sourceNodeId: nodeId, context: context)

            case .delete(let id):
                // 钉住记忆神圣不可侵犯（软硬两种模式都不动）
                if let target = existing.first(where: { $0.id == id }), target.isUserExplicit {
                    CacheDiagLog.shared.log("🧠 拒绝失效钉住记忆：\(target.content.prefix(40))")
                    continue
                }
                // 修复第一刀：AI 的删除永远是软失效（可复活），真删只留给用户在面板对已失效条再删
                try store.supersede(id: id, context: context)
            }
        }
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

    static func recordOK(_ kind: Kind, profileId: String, modelName: String) {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: key(kind, "ok", profileId))
        d.set(0, forKey: key(kind, "streak", profileId))
        d.set(modelName, forKey: key(kind, "model", profileId))
    }

    static func recordError(_ kind: Kind, profileId: String, message: String, modelName: String) {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: key(kind, "err", profileId))
        d.set(String(message.prefix(200)), forKey: key(kind, "errmsg", profileId))
        d.set(failStreak(kind, profileId: profileId) + 1, forKey: key(kind, "streak", profileId))
        d.set(modelName, forKey: key(kind, "model", profileId))
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
