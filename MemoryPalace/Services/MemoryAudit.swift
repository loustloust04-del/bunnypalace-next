import MemoryCore
import Foundation
import SwiftData

/// 审计台（plan-memory-audit-desk 第五节）：档案一条一张卡，留 / 删 / 改字 / 改类别 / 批量。
/// 数据一次 `listAll` 在内存里筛（不写 optional 谓词：SwiftData optional 谓词查不到）。
/// 只做人手动作：不自动合并、不自动删、不自动标失效，不提示「可能重复」，不审 B4。
/// 动作只改对象，存盘 + 发 `.memoryDidChange` 由界面做（同 `MemoryDeletePlan`）
enum MemoryAudit {

    // MARK: - 状态

    enum State: CaseIterable {
        case unreviewed   // 没看过：活着、没留过
        case kept         // 留下：活着、留过（改字 / 改类别也算）
        case trashed      // 删了：所有已失效的（含以前做梦毕业 / 整理合并掉的）
    }

    static func state(of m: Memory) -> State {
        if m.supersededAt != nil { return .trashed }
        return m.reviewedAt == nil ? .unreviewed : .kept
    }

    // MARK: - 来源（第七节：不加来源字段，按 C2 必写的 occurredDay 认，见 `Memory.isFragment`；以后加「C3 整理结果」一档）

    enum Origin: CaseIterable {
        case all
        case legacyAtomic   // 改版前的原子档案
        case fragmentPool   // v5 碎片池
    }

    /// v5 碎片池（`occurredDay` / `importance` 等四个字段）合进 master 的时间 = `f6a3443a3` 2026-10-15 20:29:28 -0700；
    /// 在那之前库里不可能有 C2 写的条目，之前建的非碎片 = 改版前的原子档案
    static let fragmentPoolLandedAt = Date(timeIntervalSince1970: 1_792_121_368)

    /// 这条属于哪一档；nil = 10-15 之后手加 / 导入的，只在「全部」里
    static func origin(of m: Memory) -> Origin? {
        if m.isFragment { return .fragmentPool }
        return m.createdAt < fragmentPoolLandedAt ? .legacyAtomic : nil
    }

    // MARK: - 筛选

    enum DateRange: Equatable {
        case all, today, last7Days, last30Days
        case custom(from: Date, to: Date)   // 按日历日，两头都算
    }

    struct Filter: Equatable {
        var origin: Origin = .all
        var category: String? = nil         // nil = 全部
        var dateRange: DateRange = .all
        var conversationId: String? = nil   // nil = 全部窗口
    }

    static func matches(_ m: Memory, _ filter: Filter, now: Date, calendar: Calendar = .current) -> Bool {
        if filter.origin != .all, origin(of: m) != filter.origin { return false }
        if let c = filter.category, m.category != c { return false }
        if let cid = filter.conversationId, m.sourceConversationId != cid { return false }
        switch filter.dateRange {
        case .all: return true
        case .today: return m.createdAt >= MemoryDay.dayStart(now, calendar: calendar)
        case .last7Days: return m.createdAt >= now.addingTimeInterval(-7 * 86_400)
        case .last30Days: return m.createdAt >= now.addingTimeInterval(-30 * 86_400)
        case .custom(let from, let to):
            let lo = calendar.startOfDay(for: min(from, to))
            let hi = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to))) ?? max(from, to)
            return m.createdAt >= lo && m.createdAt < hi
        }
    }

    /// 某个状态下筛出来的，新→旧（按创建时间）
    static func apply(_ memories: [Memory], filter: Filter, state: State, now: Date = Date(), calendar: Calendar = .current) -> [Memory] {
        memories.filter { Self.state(of: $0) == state && matches($0, filter, now: now, calendar: calendar) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 牌堆（审计台卡片 plan 2.3）：压住的那张（`top`）只要还在这一段（「删了」= 已失效，另两段 = 活着）就放第一——
    /// 不管它改完还匹不匹配筛选 / 审没审过，按留 / 删才走；其余按 `rows`，去掉这一轮已经过掉的（`passed`）
    static func deck(rows: [Memory], all: [Memory], state: State, top: UUID?, passed: Set<UUID>) -> [Memory] {
        let rest = rows.filter { $0.id != top && !passed.contains($0.id) }
        guard let top, !passed.contains(top), let held = all.first(where: { $0.id == top }),
              (held.supersededAt != nil) == (state == .trashed) else { return rest }
        return [held] + rest
    }

    /// 审计台动作会改、撤回要核对的几个字段（10-17 astra #2 / #3）：存不成按动作前的放回原值；
    /// 撤回前拿「动作后」的逐一比（时间比精确值），别处又改过（窗口 B 拖了重要度 / 改了类别 / 又留了一遍）就对不上
    struct Fields: Equatable {
        let reviewedAt: Date?
        let supersededAt: Date?
        let updatedAt: Date
        let category: String
        let importance: Int?
        let userEditedAt: Date?

        init(_ m: Memory) {
            reviewedAt = m.reviewedAt
            supersededAt = m.supersededAt
            updatedAt = m.updatedAt
            category = m.category
            importance = m.importance
            userEditedAt = m.userEditedAt
        }

        /// 放回这几个值（只写不一样的）
        func apply(to m: Memory) {
            if m.reviewedAt != reviewedAt { m.reviewedAt = reviewedAt }
            if m.supersededAt != supersededAt { m.supersededAt = supersededAt }
            if m.updatedAt != updatedAt { m.updatedAt = updatedAt }
            if m.category != category { m.category = category }
            if m.importance != importance { m.importance = importance }
            if m.userEditedAt != userEditedAt { m.userEditedAt = userEditedAt }
        }
    }

    /// 牌堆「撤回上一张」（审计台卡片 plan 2.3，⧫7）：只记最近一次留 / 删 / 恢复 / 过（彻底删撤不回，不记）；
    /// 拖过的重要度、改过的类别当场就生效了，不撤
    struct Undo: Equatable {
        enum Kind: Equatable {
            case kept       // 留：放回没留之前
            case trashed    // 删：恢复
            case restored   // 「删了」里恢复：再删回去
            case passed     // 「留下」里过到下一张：不碰库，界面从「过掉的」里拿出来
        }
        let id: UUID
        let kind: Kind
        /// 动作前 / 动作后那几个字段（10-17 astra #2）；过不碰库，两个都是 nil
        var before: Fields? = nil
        var after: Fields? = nil
    }

    /// 撤得了吗：过的一直撤得了；动库的那几种要这张还在、字段和动作刚做完时一模一样（对不上 = 别处改过，界面把撤回行置灰）
    static func canUndo(_ u: Undo, in memories: [Memory]) -> Bool {
        if u.kind == .passed { return true }
        guard let after = u.after, let m = memories.first(where: { $0.id == u.id }) else { return false }
        return Fields(m) == after
    }

    /// 撤回动库的那几种：字段放回动作前的值；对不上就不动。返回动了没有（动了要存盘）
    @discardableResult
    static func undo(_ u: Undo, in memories: [Memory]) -> Bool {
        guard u.kind != .passed, canUndo(u, in: memories), let before = u.before,
              let m = memories.first(where: { $0.id == u.id }) else { return false }
        before.apply(to: m)
        return true
    }

    /// 牌堆按下的一下（10-17 astra #1）：按下那一刻的楼层、牌堆代次（换段 / 改筛选 / 切列表 / 切楼层 / 离开页面就 +1）、目标、动作
    struct DeckAction: Equatable {
        enum Kind: Equatable { case keep, trash, restore, pass, purge }
        let profileId: String
        let generation: Int
        let id: UUID
        let kind: Kind
    }

    /// 飞完提交前复核：楼层、代次都没变，目标按 id 重新查到、同楼层，且还在按下时那一边（留 / 删 / 过 = 活着，恢复 / 彻底删 = 已失效）；
    /// 任何一项对不上整个作废——不动库、不记过掉、不记撤回
    static func canCommit(_ a: DeckAction, profileId: String, generation: Int, target: Memory?) -> Bool {
        guard a.profileId == profileId, a.generation == generation,
              let m = target, m.id == a.id, m.profileId == a.profileId else { return false }
        switch a.kind {
        case .keep, .trash, .pass: return m.supersededAt == nil
        case .restore, .purge: return m.supersededAt != nil
        }
    }

    /// 状态三段上的数字（同一组筛选条件）
    static func counts(_ memories: [Memory], filter: Filter, now: Date = Date(), calendar: Calendar = .current) -> [State: Int] {
        var out: [State: Int] = [.unreviewed: 0, .kept: 0, .trashed: 0]
        for m in memories where matches(m, filter, now: now, calendar: calendar) { out[state(of: m), default: 0] += 1 }
        return out
    }

    /// 出现过的窗口，按条数多→少（同数按 id，顺序稳定）；没有来源窗口的不列
    static func windowCounts(_ memories: [Memory]) -> [(id: String, count: Int)] {
        var counts: [String: Int] = [:]
        for m in memories { if let cid = m.sourceConversationId { counts[cid, default: 0] += 1 } }
        return counts.map { (id: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }

    /// 窗口标题：按 id 集合一次取（不逐条 fetch）
    static func windowTitles(ids: Set<String>, profileId: String, source: any ConversationSource) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return (try? source.titles(profileId: profileId, ids: Array(ids))) ?? [:]
    }

    /// 卡上一行小字（plan-memory-c3-catalog 2.2，不算审计三态）：已整理进《页》/ 单条就够 / 整理时驳回；都没有 nil
    static func organizeNote(_ m: Memory) -> String? {
        if let page = m.organizedPage { return "已整理进《\(page.split(separator: "/").last.map(String.init) ?? page)》" }
        if m.isSingleEnough { return "单条就够" }
        if m.organizeRejectedAt != nil { return "整理时驳回" }
        return nil
    }

    // MARK: - 动作

    /// 留：从「没看过」挪到「留下」（已失效的不碰）
    static func keep(_ memories: [Memory], now: Date = Date()) {
        for m in memories where m.supersededAt == nil { m.reviewedAt = now }
    }

    /// 删 = 标失效（进已删除，可恢复）
    @discardableResult
    static func trash(_ memories: [Memory], now: Date = Date()) -> [UUID] {
        MemoryDeletePlan.moveToTrash(memories, now: now)
    }

    /// 恢复：不清 reviewedAt——没审过的恢复回「没看过」，留过的回「留下」
    static func restore(_ memories: [Memory]) {
        MemoryRevival.revive(memories.filter { $0.supersededAt != nil })
    }

    /// 彻底删：只删已失效的（活着的一条不碰）；按楼层读最新列表再按 id 找。返回删了几条
    @discardableResult
    static func purge(ids: Set<UUID>, profileId: String, context: ModelContext) -> Int {
        var n = 0
        for m in SwiftDataMemoryStore().listAll(profileId: profileId, context: context) where m.supersededAt != nil && ids.contains(m.id) {
            context.delete(m)
            n += 1
        }
        return n
    }

    /// 批量删确认框打开那一刻冻结的一批（10-16 astra #6）：确认框里的数字和真正删的共用这一份，执行时不重读集合
    struct TrashSnapshot: Equatable {
        let profileId: String
        let ids: Set<UUID>
    }

    static func snapshot(_ memories: [Memory], profileId: String) -> TrashSnapshot {
        TrashSnapshot(profileId: profileId, ids: Set(memories.map(\.id)))
    }

    /// 执行时只复核快照里的：还活着、同楼层；快照外的（等确认时新写进来的）一条不碰
    static func trashTargets(_ snapshot: TrashSnapshot, in memories: [Memory]) -> [Memory] {
        memories.filter { snapshot.ids.contains($0.id) && $0.profileId == snapshot.profileId && $0.supersededAt == nil }
    }

    /// 改类别：立刻生效，算「留」（⧫2）
    static func setCategory(_ m: Memory, _ category: String, now: Date = Date()) {
        m.category = category
        m.updatedAt = now
        m.reviewedAt = now
    }

    /// 改重要度（= 召回优先级，审计台卡片 plan ⧫2）：夹到 1–5，立刻生效，算「留」（同改类别）；已失效的不动，值没变不改。返回改了没有
    @discardableResult
    static func setImportance(_ m: Memory, _ value: Int, now: Date = Date()) -> Bool {
        let v = min(max(value, 1), 5)
        guard m.supersededAt == nil, m.importance != v else { return false }
        m.importance = v
        m.updatedAt = now
        m.reviewedAt = now
        return true
    }

    /// 改字：记「你改过」、算「留」（⧫2）；**不钉**（⧫1，和记忆 app「编辑记忆」不同）。空的不存
    @discardableResult
    static func editText(_ m: Memory, _ text: String, now: Date = Date()) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        m.content = content
        m.tokenCount = Memory.estimateTokens(content)
        m.embeddingData = nil   // 内容变了向量失效，MemoryEmbeddingBackfill 下轮自动重算
        m.updatedAt = now
        m.userEditedAt = now
        m.reviewedAt = now
        return true
    }

    // MARK: - 一次性横条「v5 碎片池有 N 条还没看过 · 全部删掉」（⧫6：只算这一版装上之前 C2 写的）

    static let cutoffKey = "mem_audit_cutoff"
    static let bannerDoneKey = "mem_audit_banner_done"

    /// 这一版第一次启动时记下截止点；以后不再改。返回截止点
    @discardableResult
    static func recordCutoffIfNeeded(defaults: UserDefaults = .standard, now: Date = Date()) -> Date {
        if let t = defaults.object(forKey: cutoffKey) as? Double { return Date(timeIntervalSince1970: t) }
        defaults.set(now.timeIntervalSince1970, forKey: cutoffKey)
        return now
    }

    static func cutoff(defaults: UserDefaults = .standard) -> Date? {
        (defaults.object(forKey: cutoffKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }

    /// 横条要删的那批：C2 写的、没看过、活着、截止点之前建的
    static func v5BannerTargets(_ memories: [Memory], cutoff: Date) -> [Memory] {
        memories.filter { $0.isFragment && state(of: $0) == .unreviewed && $0.createdAt < cutoff }
    }

    static func v5BannerCount(_ memories: [Memory], cutoff: Date) -> Int {
        v5BannerTargets(memories, cutoff: cutoff).count
    }
}
