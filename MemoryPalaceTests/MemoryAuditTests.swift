import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 审计台（plan-memory-audit-desk 第五节）：三种状态 × 四种筛选；留 / 删 / 恢复 / 彻底删 / 改字 / 改类别；横条只数截止点之前的 C2
final class MemoryAuditTests: XCTestCase {

    private let pid = "xctest-memory-audit"
    private let now = Date(timeIntervalSince1970: 1_792_800_000)   // 2026-10-23 前后，晚于碎片池上线
    private let day: TimeInterval = 86_400

    private func context() throws -> ModelContext {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    /// fragment = C2 写的（带 occurredDay，同 `FragmentPool.write`）
    private func mem(_ content: String, category: String = "fact", created: Date, fragment: Bool = false,
                     conv: String? = nil, reviewed: Bool = false, trashed: Bool = false) -> Memory {
        let m = Memory(content: content, category: category, profileId: pid, sourceConversationId: conv)
        m.createdAt = created
        if fragment {
            m.occurredDay = MemoryDay.key(created)
            m.importance = 3
        }
        if reviewed { m.reviewedAt = created }
        if trashed { m.supersededAt = created.addingTimeInterval(60) }
        return m
    }

    private var legacyTime: Date { MemoryAudit.fragmentPoolLandedAt.addingTimeInterval(-30 * day) }

    // MARK: - 状态 / 来源

    func testStates() {
        XCTAssertEqual(MemoryAudit.state(of: mem("a", created: now)), .unreviewed)
        XCTAssertEqual(MemoryAudit.state(of: mem("b", created: now, reviewed: true)), .kept)
        XCTAssertEqual(MemoryAudit.state(of: mem("c", created: now, reviewed: true, trashed: true)), .trashed, "失效优先：留过的删了也在「删了」")
        XCTAssertEqual(MemoryAudit.state(of: mem("d", created: now, trashed: true)), .trashed)
    }

    func testOrigin() {
        XCTAssertEqual(MemoryAudit.origin(of: mem("碎片", created: now, fragment: true)), .fragmentPool)
        XCTAssertEqual(MemoryAudit.origin(of: mem("老原子", created: legacyTime)), .legacyAtomic)
        XCTAssertNil(MemoryAudit.origin(of: mem("10-15 之后手加", created: now)), "上线后手加 / 导入的只在「全部」里")
    }

    /// C3 整理标记（plan-memory-c3-catalog 2.2）：卡上一行小字，不改审计三态
    func testOrganizeNote() {
        let plain = mem("没整理", created: now, fragment: true)
        XCTAssertNil(MemoryAudit.organizeNote(plain))

        let organized = mem("进了页", created: now, fragment: true)
        organized.organizedAt = now
        organized.organizedPage = "人/小慧"
        XCTAssertEqual(MemoryAudit.organizeNote(organized), "已整理进《小慧》")
        XCTAssertEqual(MemoryAudit.state(of: organized), .unreviewed)

        let single = mem("单条", created: now, fragment: true)
        single.organizedAt = now
        XCTAssertEqual(MemoryAudit.organizeNote(single), "单条就够")

        let rejected = mem("驳回", created: now, fragment: true, reviewed: true)
        rejected.organizeRejectedAt = now
        XCTAssertEqual(MemoryAudit.organizeNote(rejected), "整理时驳回")
        XCTAssertEqual(MemoryAudit.state(of: rejected), .kept)
    }

    /// 审计台谁都能拖重要度：老档案拖了还是老档案、不进「v5 碎片池 · 全部删掉」；碎片清掉重要度还是碎片
    func testImportanceDoesNotDecideOrigin() {
        let legacy = mem("老原子拖了重要度", created: legacyTime)
        legacy.importance = 5
        XCTAssertFalse(legacy.isFragment)
        XCTAssertEqual(MemoryAudit.origin(of: legacy), .legacyAtomic)
        XCTAssertTrue(MemoryAudit.v5BannerTargets([legacy], cutoff: now).isEmpty, "没审过的老档案拖了重要度也不进横条")

        let fragment = mem("碎片", created: now.addingTimeInterval(-day), fragment: true)
        fragment.importance = nil
        XCTAssertEqual(MemoryAudit.origin(of: fragment), .fragmentPool)
        XCTAssertEqual(MemoryAudit.v5BannerTargets([fragment], cutoff: now).map(\.content), ["碎片"])
    }

    // MARK: - 筛选

    func testFiltersCombineWithStates() {
        let ms = [
            mem("碎片-关系-今天-A", category: "relationship", created: now.addingTimeInterval(-3600), fragment: true, conv: "A"),
            mem("碎片-事实-3天前-A", created: now.addingTimeInterval(-3 * day), fragment: true, conv: "A", reviewed: true),
            mem("碎片-关系-20天前-B", category: "relationship", created: now.addingTimeInterval(-20 * day), fragment: true, conv: "B"),
            mem("老原子-关系-B", category: "relationship", created: legacyTime, conv: "B"),
            mem("老原子-偏好-删了", category: "preference", created: legacyTime, trashed: true),
            mem("手加-今天", created: now.addingTimeInterval(-60)),
        ]
        func names(_ f: MemoryAudit.Filter, _ s: MemoryAudit.State) -> [String] {
            MemoryAudit.apply(ms, filter: f, state: s, now: now).map(\.content)
        }
        XCTAssertEqual(names(.init(), .unreviewed), ["手加-今天", "碎片-关系-今天-A", "碎片-关系-20天前-B", "老原子-关系-B"], "新→旧")
        XCTAssertEqual(names(.init(), .kept), ["碎片-事实-3天前-A"])
        XCTAssertEqual(names(.init(), .trashed), ["老原子-偏好-删了"])

        XCTAssertEqual(names(.init(origin: .fragmentPool), .unreviewed), ["碎片-关系-今天-A", "碎片-关系-20天前-B"])
        XCTAssertEqual(names(.init(origin: .legacyAtomic), .unreviewed), ["老原子-关系-B"])
        XCTAssertEqual(names(.init(origin: .legacyAtomic), .trashed), ["老原子-偏好-删了"])
        XCTAssertEqual(names(.init(category: "relationship"), .unreviewed), ["碎片-关系-今天-A", "碎片-关系-20天前-B", "老原子-关系-B"])
        XCTAssertEqual(names(.init(dateRange: .last7Days), .unreviewed), ["手加-今天", "碎片-关系-今天-A"])
        XCTAssertEqual(names(.init(dateRange: .last30Days), .unreviewed), ["手加-今天", "碎片-关系-今天-A", "碎片-关系-20天前-B"])
        XCTAssertEqual(names(.init(dateRange: .last7Days), .kept), ["碎片-事实-3天前-A"])
        XCTAssertEqual(names(.init(conversationId: "B"), .unreviewed), ["碎片-关系-20天前-B", "老原子-关系-B"])
        XCTAssertEqual(names(.init(origin: .fragmentPool, category: "relationship", dateRange: .last7Days, conversationId: "A"), .unreviewed),
                       ["碎片-关系-今天-A"], "四种一起")
        XCTAssertEqual(names(.init(origin: .fragmentPool, category: "relationship", dateRange: .last7Days, conversationId: "B"), .unreviewed), [])

        let c = MemoryAudit.counts(ms, filter: .init(origin: .fragmentPool), now: now)
        XCTAssertEqual(c[.unreviewed], 2)
        XCTAssertEqual(c[.kept], 1)
        XCTAssertEqual(c[.trashed], 0)
    }

    func testTodayAndCustomDateRange() {
        let cal = Calendar.current
        let today = mem("今天", created: now)
        let yesterday = mem("昨天", created: cal.date(byAdding: .day, value: -1, to: now)!)
        let lastWeek = mem("十天前", created: cal.date(byAdding: .day, value: -10, to: now)!)
        let ms = [today, yesterday, lastWeek]
        let onlyToday = MemoryAudit.apply(ms, filter: .init(dateRange: .today), state: .unreviewed, now: now).map(\.content)
        XCTAssertEqual(onlyToday, MemoryDay.dayStart(now) <= now.addingTimeInterval(-day) ? ["今天", "昨天"] : ["今天"])
        let custom = MemoryAudit.Filter(dateRange: .custom(from: cal.date(byAdding: .day, value: -1, to: now)!, to: now))
        XCTAssertEqual(MemoryAudit.apply(ms, filter: custom, state: .unreviewed, now: now).map(\.content), ["今天", "昨天"], "两头的日子都算")
        let reversed = MemoryAudit.Filter(dateRange: .custom(from: now, to: cal.date(byAdding: .day, value: -10, to: now)!))
        XCTAssertEqual(MemoryAudit.apply(ms, filter: reversed, state: .unreviewed, now: now).count, 3, "从 / 到 反了也认")
    }

    func testWindowCountsAndTitles() throws {
        let ms = [mem("1", created: now, conv: "B"), mem("2", created: now, conv: "A"), mem("3", created: now, conv: "B"), mem("4", created: now)]
        XCTAssertEqual(MemoryAudit.windowCounts(ms).map(\.id), ["B", "A"], "条数多→少；没窗口的不列")
        XCTAssertEqual(MemoryAudit.windowCounts(ms).map(\.count), [2, 1])

        let ctx = try context()
        ctx.insert(Conversation(id: "A", title: "聊配色", createTime: now, updateTime: now, currentNodeId: "", profileId: pid))
        ctx.insert(Conversation(id: "B", title: "聊记忆", createTime: now, updateTime: now, currentNodeId: "", profileId: pid))
        ctx.insert(Conversation(id: "C", title: "别的楼层", createTime: now, updateTime: now, currentNodeId: "", profileId: "other"))
        try ctx.save()
        XCTAssertEqual(MemoryAudit.windowTitles(ids: ["A", "B", "C"], profileId: pid, source: SwiftDataConversationSource(container: ctx.container)), ["A": "聊配色", "B": "聊记忆"])
    }

    // MARK: - 动作

    func testKeepTrashRestore() {
        let a = mem("a", created: now), b = mem("b", created: now)
        MemoryAudit.keep([a], now: now)
        XCTAssertEqual(a.reviewedAt, now)
        XCTAssertEqual(MemoryAudit.state(of: a), .kept)

        XCTAssertEqual(MemoryAudit.trash([a, b], now: now).count, 2)
        XCTAssertNotNil(a.supersededAt)
        XCTAssertEqual(MemoryAudit.state(of: a), .trashed)
        MemoryAudit.keep([b], now: now)
        XCTAssertNil(b.reviewedAt, "已失效的不在「留」的范围里")

        MemoryAudit.restore([a, b])
        XCTAssertNil(a.supersededAt)
        XCTAssertEqual(MemoryAudit.state(of: a), .kept, "恢复不清 reviewedAt：留过的回「留下」")
        XCTAssertEqual(MemoryAudit.state(of: b), .unreviewed, "没审过的回「没看过」")
    }

    @MainActor
    func testPurgeOnlyTrashed() throws {
        let ctx = try context()
        let store = SwiftDataMemoryStore()
        let live = try store.add(content: "活着", category: "fact", keywords: [], profileId: pid, isUserExplicit: false,
                                 extractedBy: "t", sourceConversationId: nil, context: ctx)
        let dead = try store.add(content: "删了", category: "fact", keywords: [], profileId: pid, isUserExplicit: false,
                                 extractedBy: "t", sourceConversationId: nil, context: ctx)
        MemoryAudit.trash([dead], now: now)
        try ctx.save()
        XCTAssertEqual(MemoryAudit.purge(ids: [live.id, dead.id], profileId: pid, context: ctx), 1)
        try ctx.save()
        XCTAssertEqual(store.listAll(profileId: pid, context: ctx).map(\.content), ["活着"], "彻底删只对已失效的")
    }

    func testEditTextMarksEditedAndKeptButNotPinned() {
        let m = mem("原话", created: now)
        m.embeddingData = Data([1, 2, 3])
        XCTAssertFalse(MemoryAudit.editText(m, "   ", now: now), "空的不存")
        XCTAssertNil(m.userEditedAt)
        XCTAssertTrue(MemoryAudit.editText(m, "  改过的话  ", now: now))
        XCTAssertEqual(m.content, "改过的话")
        XCTAssertEqual(m.userEditedAt, now)
        XCTAssertEqual(m.reviewedAt, now, "改字算「留」（⧫2）")
        XCTAssertFalse(m.isUserExplicit, "审计台改字不钉（⧫1）")
        XCTAssertNil(m.embeddingData, "内容变了向量重算")
        XCTAssertEqual(m.tokenCount, Memory.estimateTokens("改过的话"))
    }

    func testSetCategoryMarksKept() {
        let m = mem("关系条", category: "relationship", created: now)
        MemoryAudit.setCategory(m, "fact", now: now)
        XCTAssertEqual(m.category, "fact")
        XCTAssertEqual(m.reviewedAt, now, "改类别算「留」（⧫2）")
        XCTAssertNil(m.userEditedAt, "改类别不算改字")
        XCTAssertEqual(MemoryAudit.state(of: m), .kept)
    }

    /// 拖重要度：夹 1–5、算「留」、没变不改；已失效的不动；老档案（没定）拖了也照样存
    func testSetImportance() {
        let legacy = mem("老档案", created: legacyTime)
        XCTAssertTrue(MemoryAudit.setImportance(legacy, 4, now: now))
        XCTAssertEqual(legacy.importance, 4)
        XCTAssertEqual(legacy.updatedAt, now)
        XCTAssertEqual(legacy.reviewedAt, now, "拖重要度算「留」（同改类别）")
        XCTAssertEqual(MemoryAudit.state(of: legacy), .kept)
        XCTAssertEqual(MemoryAudit.origin(of: legacy), .legacyAtomic, "来源不跟着变")

        let later = now.addingTimeInterval(60)
        XCTAssertFalse(MemoryAudit.setImportance(legacy, 4, now: later), "值没变不改")
        XCTAssertEqual(legacy.reviewedAt, now)
        XCTAssertTrue(MemoryAudit.setImportance(legacy, 9, now: later))
        XCTAssertEqual(legacy.importance, 5, "夹到 5")
        XCTAssertTrue(MemoryAudit.setImportance(legacy, -2, now: later))
        XCTAssertEqual(legacy.importance, 1, "夹到 1")

        let dead = mem("删了的", created: now, trashed: true)
        XCTAssertFalse(MemoryAudit.setImportance(dead, 5, now: now))
        XCTAssertNil(dead.importance)
        XCTAssertNil(dead.reviewedAt, "已失效的不动")
    }

    /// 改写手给的四项：subject / 标签去空白、空的当没有、标签去重保序；置信度夹 0–100、能清空；speaker 不认清单；算「留」不算改字
    func testSetTraitsNormalizesAndMarksKept() {
        let m = mem("麦芽怕打雷。", created: now, fragment: true)
        m.subject = "麦芽"
        m.speaker = "用户自述"
        m.keywords = ["日常", "会变"]
        m.confidence = 80
        XCTAssertFalse(MemoryAudit.setTraits(m, subject: "麦芽", speaker: "用户自述", keywords: ["日常", "会变"], confidence: 80, now: now), "没变不改")
        XCTAssertNil(m.reviewedAt)

        XCTAssertTrue(MemoryAudit.setTraits(m, subject: "  岚舟 ", speaker: "星砚转述", keywords: [" 宠物 ", "", "日常", "宠物", "  "], confidence: 140, now: now))
        XCTAssertEqual(m.subject, "岚舟")
        XCTAssertEqual(m.speaker, "星砚转述", "不在那三个词里的也原样存")
        XCTAssertEqual(m.keywords, ["宠物", "日常"], "去空白、去空、去重保序")
        XCTAssertEqual(m.confidence, 100, "夹到 100")
        XCTAssertEqual([m.updatedAt, m.reviewedAt], [now, now], "算「留」（同改类别）")
        XCTAssertNil(m.userEditedAt, "不算改字")
        XCTAssertEqual(m.content, "麦芽怕打雷。")

        let later = now.addingTimeInterval(60)
        XCTAssertTrue(MemoryAudit.setTraits(m, subject: " ", speaker: "", keywords: [" "], confidence: -3, now: later))
        XCTAssertNil(m.subject, "空的当没有")
        XCTAssertNil(m.speaker)
        XCTAssertEqual(m.keywords, [])
        XCTAssertEqual(m.confidence, 0, "夹到 0")
        XCTAssertTrue(MemoryAudit.setTraits(m, subject: nil, speaker: nil, keywords: [], confidence: nil, now: later))
        XCTAssertNil(m.confidence, "能清成空")
        XCTAssertFalse(MemoryAudit.setTraits(m, subject: "  ", speaker: nil, keywords: [""], confidence: nil, now: later), "规整完和卡上一样 = 没变")

        let dead = mem("删了的", created: now, trashed: true)
        XCTAssertFalse(MemoryAudit.setTraits(dead, subject: "岚舟", speaker: nil, keywords: ["日常"], confidence: 50, now: now))
        XCTAssertNil(dead.subject, "已失效的不动")
    }

    /// Edit 页一次交回：`Edit(memory)` 原样交回什么都不动（卡上本来不规整的老值也不顺手洗）；改哪项动哪项
    func testApplyEdit() {
        let m = mem("麦芽怕打雷。", created: now, fragment: true)
        m.subject = " 麦芽"
        m.keywords = ["日常", "日常"]
        m.confidence = 300
        XCTAssertFalse(MemoryAudit.apply(MemoryAudit.Edit(m), to: m, now: now), "原样交回不动")
        XCTAssertEqual([m.subject, m.keywords.joined(separator: ","), m.confidence.map(String.init)], [" 麦芽", "日常,日常", "300"])
        XCTAssertNil(m.reviewedAt)

        var edit = MemoryAudit.Edit(m)
        edit.text = "  "
        edit.subject = "岚舟"
        XCTAssertFalse(MemoryAudit.apply(edit, to: m, now: now), "空正文整个不存")
        XCTAssertEqual(m.subject, " 麦芽")

        edit = MemoryAudit.Edit(m)
        edit.text = "麦芽怕打雷，要抱着。"
        edit.category = "preference"
        edit.importance = 5
        edit.keywords = ["日常", "做法"]
        XCTAssertTrue(MemoryAudit.apply(edit, to: m, now: now))
        XCTAssertEqual([m.content, m.category], ["麦芽怕打雷，要抱着。", "preference"])
        XCTAssertEqual(m.importance, 5)
        XCTAssertEqual(m.keywords, ["日常", "做法"])
        XCTAssertEqual(m.subject, " 麦芽", "没改的那几项不动")
        XCTAssertEqual(m.confidence, 100, "她改过、没碰置信度 = 100")
        XCTAssertEqual([m.userEditedAt, m.reviewedAt], [now, now])

        edit = MemoryAudit.Edit(m)
        edit.confidence = nil
        XCTAssertTrue(MemoryAudit.apply(edit, to: m, now: now), "只改四项里的一项也算改了")
        XCTAssertNil(m.confidence)
    }

    /// 粟粟 11-13「如果人改过就confidence=100」：改了正文或任何一项就是 100；她同一次里亲手填了置信度的以她填的为准；
    /// 什么都没改不动；Approve / Delete / Restore 不算改过
    func testHandEditSetsConfidenceTo100() {
        func card(_ confidence: Int?) -> Memory {
            let m = mem("岚舟在云桥城学陶艺。", created: now, fragment: true)
            m.subject = "岚舟"
            m.speaker = "用户自述"
            m.keywords = ["陶艺"]
            m.confidence = confidence
            return m
        }
        /// 从卡上现在的值起一份草稿、改、存，返回存完的置信度
        func saved(_ m: Memory, _ change: (inout MemoryAudit.Edit) -> Void) -> Int? {
            var edit = MemoryAudit.Edit(m)
            change(&edit)
            MemoryAudit.apply(edit, to: m, now: now)
            return m.confidence
        }

        XCTAssertEqual(saved(card(60)) { _ in }, 60, "什么都没改不动")
        XCTAssertEqual(saved(card(60)) { $0.text = "岚舟在云桥城南岸学陶艺。" }, 100, "改正文")
        XCTAssertEqual(saved(card(60)) { $0.category = "preference" }, 100, "改类别")
        XCTAssertEqual(saved(card(60)) { $0.importance = 5 }, 100, "改重要度")
        XCTAssertEqual(saved(card(60)) { $0.subject = "星砚" }, 100, "改说的是谁")
        XCTAssertEqual(saved(card(60)) { $0.speaker = "AI 观察" }, 100, "改谁说的")
        XCTAssertEqual(saved(card(60)) { $0.keywords = ["陶艺", "日常"] }, 100, "改标签")
        XCTAssertEqual(saved(card(nil)) { $0.keywords = ["日常"] }, 100, "老卡没有置信度，她改了也是 100")
        XCTAssertEqual(saved(card(100)) { $0.text = "岚舟学陶艺。" }, 100)

        XCTAssertEqual(saved(card(60)) { $0.confidence = 85 }, 85, "只改置信度：她填多少是多少")
        XCTAssertEqual(saved(card(60)) { $0.text = "岚舟学陶艺。"; $0.confidence = 85 }, 85, "改了别的又亲手填了置信度：以她填的为准")
        XCTAssertEqual(saved(card(60)) { $0.category = "goal"; $0.importance = 1; $0.keywords = []; $0.confidence = 30 }, 30)
        XCTAssertEqual(saved(card(60)) { $0.text = "岚舟学陶艺。"; $0.confidence = 250 }, 100, "她填的照旧夹到 0–100")
        XCTAssertNil(saved(card(60)) { $0.text = "岚舟学陶艺。"; $0.confidence = nil }, "她亲手清空的照她的")
        XCTAssertEqual(saved(card(60)) { $0.text = "岚舟学陶艺。"; $0.confidence = 60 }, 100, "置信度和原来一样 = 没碰")

        let m = card(60)
        MemoryAudit.keep([m], now: now)
        MemoryAudit.trash([m], now: now)
        MemoryAudit.restore([m])
        XCTAssertEqual(m.confidence, 60, "Approve / Delete / Restore 不算改过")
        MemoryAudit.setCategory(m, m.category, now: now)
        XCTAssertTrue(MemoryAudit.editText(m, m.content, now: now))
        XCTAssertFalse(MemoryAudit.setImportance(m, 3, now: now))
        XCTAssertEqual(m.confidence, 60, "值没变的单项动作也不算")
        XCTAssertTrue(MemoryAudit.setTraits(m, subject: "岚舟", speaker: "用户自述", keywords: ["陶艺", "日常"], confidence: 60, now: now))
        XCTAssertEqual(m.confidence, 100, "不走 Edit 页、单改四项里别的也一样")

        let dead = card(60)
        dead.supersededAt = now
        XCTAssertEqual(saved(dead) { $0.text = "岚舟学陶艺。" }, 60, "已失效的整个不动")
    }

    // MARK: - 牌堆

    /// 压住的那张永远第一（改完不匹配筛选 / 已经算「留」也不走）；新写进来的排在它后面；过掉的不再出
    func testDeckHoldsTopAndSkipsPassed() {
        let a = mem("甲", created: now), b = mem("乙", created: now.addingTimeInterval(-60)), c = mem("丙", created: now.addingTimeInterval(-120))
        let all = [a, b, c]
        let rows = { MemoryAudit.apply(all, filter: MemoryAudit.Filter(), state: .unreviewed, now: self.now) }
        XCTAssertEqual(MemoryAudit.deck(rows: rows(), all: all, state: .unreviewed, top: nil, passed: []).map(\.content), ["甲", "乙", "丙"])

        // 压住乙后拖了重要度（算留，不在「没看过」里了）：还在第一
        MemoryAudit.setImportance(b, 5, now: now)
        XCTAssertEqual(MemoryAudit.deck(rows: rows(), all: all, state: .unreviewed, top: b.id, passed: []).map(\.content), ["乙", "甲", "丙"])

        // 后台新写进来一条（最新）：排在压住的后面
        let late = mem("新来的", created: now.addingTimeInterval(60))
        let all2 = all + [late]
        let rows2 = MemoryAudit.apply(all2, filter: MemoryAudit.Filter(), state: .unreviewed, now: now)
        XCTAssertEqual(MemoryAudit.deck(rows: rows2, all: all2, state: .unreviewed, top: b.id, passed: []).map(\.content), ["乙", "新来的", "甲", "丙"])

        // 过掉的不出；过掉的不再压住
        XCTAssertEqual(MemoryAudit.deck(rows: rows2, all: all2, state: .unreviewed, top: nil, passed: [late.id]).map(\.content), ["甲", "丙"])
        XCTAssertEqual(MemoryAudit.deck(rows: rows2, all: all2, state: .unreviewed, top: b.id, passed: [b.id]).map(\.content), ["新来的", "甲", "丙"])
    }

    /// Draft 里 Skip：这张原样留在 Draft（不算 Approve、一个字段不动），这一轮牌堆不再出；Undo 放回最上面；重置牌堆后又从头出
    func testDraftSkipLeavesCardInDraft() throws {
        let a = mem("甲", created: now), b = mem("乙", created: now.addingTimeInterval(-60))
        let all = [a, b]
        let rows = { MemoryAudit.apply(all, filter: MemoryAudit.Filter(), state: .unreviewed, now: self.now) }
        let ui = MemoryAuditViewState()
        ui.resetDeck(rows: rows())
        let deck = { MemoryAudit.deck(rows: rows(), all: all, state: .unreviewed, top: ui.topId, passed: ui.passed).map(\.content) }
        XCTAssertEqual(deck(), ["甲", "乙"])

        let before = MemoryAudit.Fields(a)
        let skip = MemoryAudit.DeckAction(profileId: a.profileId, generation: ui.deckGeneration, id: a.id, kind: .pass)
        XCTAssertTrue(MemoryAudit.canCommit(skip, profileId: a.profileId, generation: ui.deckGeneration, target: a))
        // 页面 commit(.pass) 做的三件事
        ui.passed.insert(a.id)
        ui.topId = nil
        ui.lastAction = MemoryAudit.Undo(id: a.id, kind: .passed)
        XCTAssertEqual(deck(), ["乙"], "跳过的这一轮不再出")
        XCTAssertEqual(MemoryAudit.Fields(a), before, "一个字段不动")
        XCTAssertEqual(MemoryAudit.state(of: a), .unreviewed, "还在 Draft，不算 Approve")
        XCTAssertEqual(rows().map(\.content), ["甲", "乙"], "List 里照旧看得到")

        // Undo（页面 undoTapped 的那一支）：从过掉的里拿出来、压回最上面，不碰库
        let u = try XCTUnwrap(ui.lastAction)
        XCTAssertTrue(MemoryAudit.canUndo(u, in: all))
        XCTAssertFalse(MemoryAudit.undo(u, in: all), "过掉的不碰库")
        ui.passed.remove(u.id)
        ui.lastAction = nil
        ui.topId = u.id
        XCTAssertEqual(deck(), ["甲", "乙"])

        // 两张都跳过 → 这一叠看完；换段回来（重置牌堆）又从头出
        ui.passed = [a.id, b.id]
        ui.topId = nil
        XCTAssertEqual(deck(), [])
        ui.resetDeck(rows: rows())
        XCTAssertEqual(deck(), ["甲", "乙"])
    }

    /// 压住的那张离开了这一段（别处删了 / 彻底删了 / 在「删了」里恢复了）就松开
    func testDeckReleasesTopThatLeftTheSegment() {
        let a = mem("甲", created: now), b = mem("乙", created: now.addingTimeInterval(-60))
        let rows = MemoryAudit.apply([a, b], filter: MemoryAudit.Filter(), state: .unreviewed, now: now)
        MemoryAudit.trash([a], now: now)
        XCTAssertEqual(MemoryAudit.deck(rows: rows, all: [a, b], state: .unreviewed, top: a.id, passed: []).map(\.content), ["乙"], "别处删了就松开")
        XCTAssertEqual(MemoryAudit.deck(rows: [b], all: [b], state: .unreviewed, top: a.id, passed: []).map(\.content), ["乙"], "彻底删了（不在库里）就松开")

        let dead = mem("删了的", created: now, trashed: true), dead2 = mem("删了的2", created: now.addingTimeInterval(-60), trashed: true)
        let trashed = MemoryAudit.apply([dead, dead2], filter: MemoryAudit.Filter(), state: .trashed, now: now)
        XCTAssertEqual(MemoryAudit.deck(rows: trashed, all: [dead, dead2], state: .trashed, top: dead2.id, passed: []).map(\.content), ["删了的2", "删了的"])
        MemoryAudit.restore([dead2])
        XCTAssertEqual(MemoryAudit.deck(rows: [dead], all: [dead, dead2], state: .trashed, top: dead2.id, passed: []).map(\.content), ["删了的"], "「删了」里恢复了就松开")
    }

    /// 牌堆的看法记在父级持有的 view state：默认只有「没看过」是牌堆；切楼层 clear() 全回默认
    func testViewStateDefaultsAndClear() {
        let ui = MemoryAuditViewState()
        XCTAssertEqual(ui.stackStates, [.unreviewed])
        ui.state = .kept
        ui.stackStates = [.unreviewed, .kept]
        ui.topId = UUID()
        ui.passed = [UUID()]
        ui.lastAction = MemoryAudit.Undo(id: UUID(), kind: .trashed)
        XCTAssertNil(ui.station, "默认停在审计台首页")
        ui.station = .wiki
        let gen = ui.deckGeneration
        ui.clear()
        XCTAssertEqual(ui.deckGeneration, gen + 1, "切楼层：飞着的那一下作废")
        XCTAssertNil(ui.station, "切楼层退回首页")
        XCTAssertEqual(ui.state, .unreviewed)
        XCTAssertEqual(ui.stackStates, [.unreviewed])
        XCTAssertNil(ui.topId)
        XCTAssertTrue(ui.passed.isEmpty)
        XCTAssertNil(ui.lastAction)
    }

    /// 审计台首页的台注册表（plan-memory-audit-home-trial 第二节）：首页照表画，不写死
    func testAuditStationRegistry() {
        let all = AuditStation.all
        XCTAssertEqual(all.map(\.id), [.desk, .wiki, .trial, .recall], "顺序：整理台、wiki、试写台、召回测试台")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "一个台只注册一次")
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        XCTAssertEqual(byId[.desk]?.name, "整理台", "卡片页改名整理台")
        XCTAssertEqual(byId[.desk]?.isOpen, true)
        XCTAssertNotNil(byId[.desk]?.pulse)
        XCTAssertEqual(byId[.wiki]?.isOpen, true)
        XCTAssertNotNil(byId[.wiki]?.pulse)
        XCTAssertEqual(byId[.trial]?.isOpen, false, "试写台第 ③ 段才点亮")
        XCTAssertEqual(byId[.recall]?.isOpen, true, "召回测试台已点亮")
        XCTAssertEqual(byId[.recall]?.placeholder, "")
        XCTAssertNotNil(byId[.recall]?.pulse)
        for s in all { XCTAssertFalse(s.name.isEmpty || s.icon.isEmpty, "\(s.id) 缺名字 / 图标") }
    }

    /// 方块现场数字：有数写数，没事写一句状态
    func testAuditStationPulses() {
        XCTAssertEqual(AuditStation.deskPulse(unreviewed: 12), AuditStationPulse(figure: "12", label: "Draft"), "11-15：方块只留数字「12 Draft」")
        XCTAssertEqual(AuditStation.deskPulse(unreviewed: 0), AuditStationPulse(figure: "0", label: "Draft"))
        XCTAssertEqual(AuditStation.wikiPulse(pending: 3, unread: 0, pages: 9), AuditStationPulse(figure: "3", label: "待批"))
        XCTAssertEqual(AuditStation.wikiPulse(pending: 3, unread: 2, pages: 9), AuditStationPulse(figure: "3", label: "待批 · 2 待阅"),
                       "两样都有就两样都写")
        XCTAssertEqual(AuditStation.wikiPulse(pending: 0, unread: 2, pages: 9), AuditStationPulse(figure: "2", label: "待阅"),
                       "只剩待阅：不说成待批（astra P3）")
        XCTAssertEqual(AuditStation.wikiPulse(pending: 0, unread: 0, pages: 9), AuditStationPulse(figure: nil, label: "9 页 · 没有待批"))
        XCTAssertEqual(AuditStation.wikiPulse(pending: 0, unread: 0, pages: 0), AuditStationPulse(figure: nil, label: "还没有页"))
    }

    /// 待批 = 还没批的条目；待阅 = 没收进页、还没点「知道了」的内容；点过的不算（存储接口 `pendingItemCount` 不动）
    func testProposalTallySplitsPendingAndUnread() {
        let change = WikiProposal.Change.appendRecords(path: "人/小慧", lines: ["a"])
        let stray = WikiProposal.Unapplied(page: nil, raw: "x", reason: "收不进", at: "items[0]")
        let a = WikiProposal(origin: .scheduled, createdAt: now, items: [
            WikiProposal.Item(state: .pending, change: change, baseVersion: nil),
            WikiProposal.Item(state: .approved, change: change, baseVersion: nil),
        ])
        var b = WikiProposal(origin: .topic, createdAt: now, items: [])
        b.unapplied = [stray, stray]
        var seen = WikiProposal(origin: .topic, createdAt: now, items: [])
        seen.unapplied = [stray]
        seen.unappliedSeenAt = now
        let t = AuditStation.proposalTally([a, b, seen])
        XCTAssertEqual(t.pending, 1)
        XCTAssertEqual(t.unread, 2)
    }

    /// 牌堆动作 + 记撤回（同页面 `commit`）：动作前 / 后的字段各拍一份
    private func act(_ m: Memory, _ kind: MemoryAudit.Undo.Kind, _ change: () -> Void) -> MemoryAudit.Undo {
        let before = MemoryAudit.Fields(m)
        change()
        return MemoryAudit.Undo(id: m.id, kind: kind, before: before, after: MemoryAudit.Fields(m))
    }

    /// 撤回上一张：留的回到原来的 reviewedAt、删的恢复、「删了」里恢复的再删回去；不在了不动；过掉的不碰库
    func testUndo() {
        let unseen = mem("没看过的", created: now)
        let keepU = act(unseen, .kept) { MemoryAudit.keep([unseen], now: now) }
        XCTAssertTrue(MemoryAudit.canUndo(keepU, in: [unseen]))
        XCTAssertTrue(MemoryAudit.undo(keepU, in: [unseen]))
        XCTAssertNil(unseen.reviewedAt)
        XCTAssertEqual(MemoryAudit.state(of: unseen), .unreviewed, "留的撤回 = 回到没看过")

        let kept = mem("留下的", created: now, reviewed: true)
        let keptAt = kept.reviewedAt, keptUpdated = kept.updatedAt
        let trashU = act(kept, .trashed) { MemoryAudit.trash([kept], now: now) }
        XCTAssertTrue(MemoryAudit.undo(trashU, in: [kept]))
        XCTAssertNil(kept.supersededAt)
        XCTAssertEqual(kept.reviewedAt, keptAt, "留下里删的撤回 = 回到留下")
        XCTAssertEqual(kept.updatedAt, keptUpdated, "字段放回动作前")

        let dead = mem("删了的", created: now, trashed: true)
        let deadAt = dead.supersededAt
        let restoreU = act(dead, .restored) { MemoryAudit.restore([dead]) }
        XCTAssertTrue(MemoryAudit.undo(restoreU, in: [dead]))
        XCTAssertEqual(dead.supersededAt, deadAt, "恢复的撤回 = 删回去（失效时间也回到原来的）")

        XCTAssertFalse(MemoryAudit.undo(trashU, in: [kept]), "撤过一次：字段已经不是动作后的，不再撤")
        XCTAssertFalse(MemoryAudit.canUndo(MemoryAudit.Undo(id: UUID(), kind: .trashed), in: [kept]), "没拍字段的不撤")
        XCTAssertFalse(MemoryAudit.undo(MemoryAudit.Undo(id: kept.id, kind: .trashed, before: trashU.before, after: MemoryAudit.Fields(kept)), in: []), "不在库里了")
        let pass = MemoryAudit.Undo(id: kept.id, kind: .passed)
        XCTAssertTrue(MemoryAudit.canUndo(pass, in: []), "过的一直撤得了（界面那边）")
        XCTAssertFalse(MemoryAudit.undo(pass, in: [kept]), "过掉的不碰库")
    }

    /// 撤回前和「动作后」逐字段比（10-17 astra #2）：别处又改过就对不上，不动（页面把撤回行置灰）
    func testUndoRefusesWhenChangedElsewhere() {
        // 窗口 A 恢复了一条没看过的，窗口 B 拖了重要度（算留）：撤回不能再把它删回去
        let a = mem("恢复后别处留了", created: now, trashed: true)
        let restoreU = act(a, .restored) { MemoryAudit.restore([a]) }
        MemoryAudit.setImportance(a, 4, now: now.addingTimeInterval(5))
        XCTAssertFalse(MemoryAudit.canUndo(restoreU, in: [a]))
        XCTAssertFalse(MemoryAudit.undo(restoreU, in: [a]))
        XCTAssertNil(a.supersededAt, "还活着")
        XCTAssertEqual(a.importance, 4)

        // 留了之后别处改了类别（reviewedAt 又被写成新时间）：撤回不能清掉后一次的 reviewedAt
        let b = mem("留了又改类别", created: now)
        let keepU = act(b, .kept) { MemoryAudit.keep([b], now: now) }
        let later = now.addingTimeInterval(30)
        MemoryAudit.setCategory(b, "goal", now: later)
        XCTAssertFalse(MemoryAudit.undo(keepU, in: [b]))
        XCTAssertEqual(b.reviewedAt, later)
        XCTAssertEqual(b.category, "goal")

        // 留了之后别处又留了一遍：只差 reviewedAt 的精确时间，也算对不上
        let c = mem("又留了一遍", created: now)
        let keepC = act(c, .kept) { MemoryAudit.keep([c], now: now) }
        MemoryAudit.keep([c], now: now.addingTimeInterval(1))
        XCTAssertFalse(MemoryAudit.canUndo(keepC, in: [c]))

        // 留了之后别处删了
        let d = mem("别处删了", created: now)
        let keepD = act(d, .kept) { MemoryAudit.keep([d], now: now) }
        MemoryAudit.trash([d], now: now)
        XCTAssertFalse(MemoryAudit.undo(keepD, in: [d]))
        XCTAssertEqual(d.reviewedAt, now)
    }

    /// 存不成按动作前的字段放回（10-17 astra #3）：卡回到原来那一边，重试成功后撤回的基线还是原来的「没看过」
    func testFieldsRestoreKeepsUndoBaseline() {
        let m = mem("存不成", created: now)
        let failed = MemoryAudit.Fields(m)
        MemoryAudit.keep([m], now: now)
        failed.apply(to: m)   // 存盘失败：放回原值
        XCTAssertNil(m.reviewedAt)
        XCTAssertEqual(MemoryAudit.state(of: m), .unreviewed, "回到没看过（牌堆压得住它）")

        let retry = act(m, .kept) { MemoryAudit.keep([m], now: now.addingTimeInterval(10)) }
        XCTAssertNil(retry.before?.reviewedAt, "重试的撤回基线没被失败那次污染")
        XCTAssertTrue(MemoryAudit.undo(retry, in: [m]))
        XCTAssertEqual(MemoryAudit.state(of: m), .unreviewed)

        let alive = mem("删存不成", created: now, reviewed: true)
        let before = MemoryAudit.Fields(alive)
        MemoryAudit.trash([alive], now: now)
        before.apply(to: alive)
        XCTAssertNil(alive.supersededAt, "删存不成：回到活着，卡会飞回来")
        XCTAssertEqual(MemoryAudit.Fields(alive), before)
    }

    /// 飞完提交前复核（10-17 astra #1）：楼层 / 代次 / 目标 / 那一边，任何一项对不上就作废
    func testDeckActionCommitCheck() {
        let live = mem("活着", created: now), dead = mem("删了", created: now, trashed: true)
        func a(_ m: Memory, _ k: MemoryAudit.DeckAction.Kind, gen: Int = 3) -> MemoryAudit.DeckAction {
            MemoryAudit.DeckAction(profileId: pid, generation: gen, id: m.id, kind: k)
        }
        for k in [MemoryAudit.DeckAction.Kind.keep, .trash, .pass] {
            XCTAssertTrue(MemoryAudit.canCommit(a(live, k), profileId: pid, generation: 3, target: live))
            XCTAssertFalse(MemoryAudit.canCommit(a(live, k), profileId: pid, generation: 3, target: nil), "目标没了")
        }
        for k in [MemoryAudit.DeckAction.Kind.restore, .purge] {
            XCTAssertTrue(MemoryAudit.canCommit(a(dead, k), profileId: pid, generation: 3, target: dead))
        }
        XCTAssertFalse(MemoryAudit.canCommit(a(live, .keep), profileId: pid, generation: 4, target: live), "飞的时候换了段 / 改了筛选")
        XCTAssertFalse(MemoryAudit.canCommit(a(live, .keep), profileId: "别的楼层", generation: 3, target: live), "切了楼层")
        XCTAssertFalse(MemoryAudit.canCommit(a(dead, .keep), profileId: pid, generation: 3, target: dead), "别处已经删了，不再留")
        XCTAssertFalse(MemoryAudit.canCommit(a(live, .restore), profileId: pid, generation: 3, target: live), "别处已经恢复了，不再恢复")
        XCTAssertFalse(MemoryAudit.canCommit(a(live, .keep), profileId: pid, generation: 3, target: dead), "查回来的不是这条")
        let other = Memory(content: "别楼", category: "fact", profileId: "别的楼层")
        XCTAssertFalse(MemoryAudit.canCommit(MemoryAudit.DeckAction(profileId: pid, generation: 3, id: other.id, kind: .keep),
                                             profileId: pid, generation: 3, target: other), "目标不在这层楼")
    }

    /// 重置牌堆按新条件直接压住首张（10-17 astra #4）：「全部」→「事实」后首张没变，也得压住——拖了重要度（算留）不会自己消失
    func testResetDeckPinsFirstEvenWhenUnchanged() {
        let a = mem("甲（事实，最新）", created: now), b = mem("乙（关系）", category: "relationship", created: now.addingTimeInterval(-60))
        let all = [a, b]
        let ui = MemoryAuditViewState()
        ui.resetDeck(rows: MemoryAudit.apply(all, filter: MemoryAudit.Filter(), state: .unreviewed, now: now))
        XCTAssertEqual(ui.topId, a.id)
        ui.passed = [b.id]
        ui.lastAction = MemoryAudit.Undo(id: b.id, kind: .passed)
        let gen = ui.deckGeneration

        var f = MemoryAudit.Filter()
        f.category = "fact"
        let rows = { MemoryAudit.apply(all, filter: f, state: .unreviewed, now: self.now) }
        ui.resetDeck(rows: rows())
        XCTAssertEqual(ui.topId, a.id, "首张没变也压住")
        XCTAssertEqual(ui.deckGeneration, gen + 1, "代次 +1：飞着的那一下作废")
        XCTAssertTrue(ui.passed.isEmpty)
        XCTAssertNil(ui.lastAction)

        MemoryAudit.setImportance(a, 5, now: now)
        XCTAssertEqual(MemoryAudit.deck(rows: rows(), all: all, state: .unreviewed, top: ui.topId, passed: ui.passed).first?.id, a.id,
                       "拖了重要度（算留）还在最上面")
        ui.resetDeck(rows: [])
        XCTAssertNil(ui.topId, "筛出来为零：没得压")
    }

    /// C3 ② 起常驻只认钉住：关系 / 偏好不再自动常驻；钉住的不管什么类别都常驻
    func testCategoryChangeAffectsPersistence() {
        let m = mem("关系条", category: "relationship", created: now)
        XCTAssertFalse(MemoryInjector.isPersistent(m), "按类别常驻停掉")
        m.isUserExplicit = true
        MemoryAudit.setCategory(m, "fact", now: now)
        XCTAssertTrue(MemoryInjector.isPersistent(m), "钉住的：类别改成事实也常驻")
    }

    // MARK: - 横条

    func testCutoffRecordedOnce() throws {
        let suite = "xctest-memory-audit-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertNil(MemoryAudit.cutoff(defaults: d))
        XCTAssertEqual(MemoryAudit.recordCutoffIfNeeded(defaults: d, now: now), now)
        XCTAssertEqual(MemoryAudit.recordCutoffIfNeeded(defaults: d, now: now.addingTimeInterval(day)), now, "第一次记下就不再改")
        XCTAssertEqual(MemoryAudit.cutoff(defaults: d), now)
    }

    func testBannerCountsOnlyUnreviewedFragmentsBeforeCutoff() {
        let cutoff = now
        let ms = [
            mem("截止前碎片", created: cutoff.addingTimeInterval(-day), fragment: true),
            mem("截止前碎片2", created: cutoff.addingTimeInterval(-2 * day), fragment: true),
            mem("截止后碎片", created: cutoff.addingTimeInterval(60), fragment: true),
            mem("截止前碎片-留过", created: cutoff.addingTimeInterval(-day), fragment: true, reviewed: true),
            mem("截止前碎片-删了", created: cutoff.addingTimeInterval(-day), fragment: true, trashed: true),
            mem("老原子", created: legacyTime),
            mem("截止前手加", created: cutoff.addingTimeInterval(-day)),
        ]
        XCTAssertEqual(MemoryAudit.v5BannerTargets(ms, cutoff: cutoff).map(\.content), ["截止前碎片", "截止前碎片2"])
        XCTAssertEqual(MemoryAudit.v5BannerCount(ms, cutoff: cutoff), 2)
    }

    // MARK: - 批量删快照（10-16 astra #6）

    /// 确认框打开时冻结目标 id：等确认期间新写进来的（快照外）不删；快照里已经被删 / 别的楼层的不碰；数字和执行共用快照
    @MainActor
    func testBatchTrashUsesFrozenSnapshot() throws {
        let ctx = try context()
        let store = SwiftDataMemoryStore()
        func add(_ content: String, profile: String) throws -> Memory {
            let m = try store.add(content: content, category: "fact", keywords: [], profileId: profile, isUserExplicit: false,
                                  extractedBy: "t", sourceConversationId: nil, context: ctx)
            m.importance = 3
            return m
        }
        let a = try add("甲", profile: pid), b = try add("乙", profile: pid), c = try add("丙", profile: pid)
        try ctx.save()
        let opened = store.listAll(profileId: pid, context: ctx).filter { MemoryAudit.state(of: $0) == .unreviewed }
        let snap = MemoryAudit.snapshot(opened, profileId: pid)
        XCTAssertEqual(snap.ids, [a.id, b.id, c.id])
        XCTAssertEqual(snap.ids.count, 3, "确认框里的数字 = 快照条数")

        // 确认框开着时：后台 C2 又写进一条；丙在别处被删了；别的楼层同 id 集合外的不相干
        let late = try add("新来的", profile: pid)
        MemoryAudit.trash([c], now: now)
        let other = try add("别的楼层", profile: "xctest-memory-audit-other")
        try ctx.save()

        let fresh = store.listAll(profileId: snap.profileId, context: ctx)
        let targets = MemoryAudit.trashTargets(snap, in: fresh)
        XCTAssertEqual(Set(targets.map(\.id)), [a.id, b.id], "只删快照里还活着的")
        MemoryAudit.trash(targets, now: now)
        try ctx.save()
        XCTAssertNil(late.supersededAt, "快照外新增的不删")
        XCTAssertNil(other.supersededAt)
        XCTAssertNotNil(a.supersededAt)
        XCTAssertNotNil(b.supersededAt)

        let crossFloor = MemoryAudit.TrashSnapshot(profileId: pid, ids: [other.id])
        XCTAssertTrue(MemoryAudit.trashTargets(crossFloor, in: [other]).isEmpty, "不是快照那层楼的不删")
    }

    /// 11-15：牌堆卡上的灰小字收进 chip（和详情页同一套写法）：没有的不出；标签最多三个，多的写 +N；类别当第一个标签、「事实」不出
    func testChipTexts() {
        XCTAssertEqual(MemoryChipText.about(" 麦芽 "), "About 麦芽")
        XCTAssertNil(MemoryChipText.about(" "))
        XCTAssertEqual(MemoryAuditTraits.fromChip("用户自述", assistant: "星砚"), "From you")
        XCTAssertEqual(MemoryAuditTraits.fromChip("AI 观察", assistant: "星砚"), "星砚 noticed")
        XCTAssertEqual(MemoryChipText.sure(80), "80% sure")
        XCTAssertNil(MemoryChipText.sure(nil))
        XCTAssertEqual(MemoryChipText.importance(3), "Importance 3")
        XCTAssertEqual(MemoryChipText.tags(MemoryAuditTraits.shownTags(category: "context", keywords: ["陶艺", "近况"])), "#近况 #陶艺",
                       "类别当第一个标签，同名的普通标签不再出一遍")
        XCTAssertEqual(MemoryChipText.tags(MemoryAuditTraits.shownTags(category: "fact", keywords: ["陶艺"])), "#陶艺", "「事实」不当标签显示")
        XCTAssertEqual(MemoryChipText.tags(["a", "b", "c", "d", "e"]), "#a #b #c +2")
        XCTAssertNil(MemoryChipText.tags([]))
    }

    /// 11-13：From 托盘四档的名字；助手名走变量
    func testFromLabels() {
        XCTAssertEqual(MemoryAuditTraits.from("用户自述", assistant: "星砚"), "You")
        XCTAssertEqual(MemoryAuditTraits.from("AI 观察", assistant: "星砚"), "星砚 noticed")
        XCTAssertEqual(MemoryAuditTraits.from("AI 承诺", assistant: "岚舟"), "岚舟 promised")
        XCTAssertNil(MemoryAuditTraits.from(" ", assistant: "星砚"))
        XCTAssertEqual(MemoryAuditTraits.from("星砚转述", assistant: "星砚"), "星砚转述", "不认得的原样")
        XCTAssertEqual(MemoryAuditTraits.fromChip("用户自述", assistant: "星砚"), "From you")
        XCTAssertEqual(MemoryAuditTraits.fromChip("AI 观察", assistant: "星砚"), "星砚 noticed")
    }

    /// 11-13「旧的五个类别也是标签一种」：只是显示层，「事实」不出；一张卡只显示一个类别
    func testCategoryShownAsTag() {
        XCTAssertEqual(MemoryAuditTraits.shownTags(category: "context", keywords: [" 陶艺", "近况", "日常"]), ["近况", "陶艺", "日常"])
        XCTAssertEqual(MemoryAuditTraits.shownTags(category: "fact", keywords: ["陶艺"]), ["陶艺"])
        XCTAssertEqual(MemoryAuditTraits.categoryKey(forTag: "偏好"), "preference")
        XCTAssertNil(MemoryAuditTraits.categoryKey(forTag: "事实"), "「事实」不当标签，加它就是普通标签")
        XCTAssertNil(MemoryAuditTraits.categoryKey(forTag: "陶艺"))

        // 加另一个类别名 = 换类别，标签不动
        let swapped = MemoryAuditEditPage.adding("#目标", to: ["陶艺"], category: "context")
        XCTAssertEqual(swapped.tags, ["陶艺"])
        XCTAssertEqual(swapped.category, "goal")
        let plain = MemoryAuditEditPage.adding("日常", to: ["陶艺"], category: "context")
        XCTAssertEqual(plain.tags, ["陶艺", "日常"])
        XCTAssertEqual(plain.category, "context")

        // 去掉类别标签 = 存回「事实」，同名的普通标签一起去掉
        let removed = MemoryAuditEditPage.removing("近况", from: ["陶艺", " 近况"], category: "context")
        XCTAssertEqual(removed.tags, ["陶艺"])
        XCTAssertEqual(removed.category, "fact")
        let removedTag = MemoryAuditEditPage.removing("陶艺", from: ["陶艺", "日常"], category: "context")
        XCTAssertEqual(removedTag.tags, ["日常"])
        XCTAssertEqual(removedTag.category, "context")
    }

    /// Tags 托盘候选：库里的在前，库里没出现过的另几个类别补在后面；卡上显示着的不出；打了字只留含这段字的
    func testTagSuggestionsIncludeCategories() {
        let pool = ["日常", "近况", "陶艺"]
        let all = MemoryAuditEditPage.tagSuggestions(pool, shown: ["近况"], typed: "")
        XCTAssertEqual(Array(all.prefix(2)), ["日常", "陶艺"])
        XCTAssertEqual(Set(all.dropFirst(2)), ["偏好", "关系", "目标"])
        XCTAssertFalse(all.contains("事实"))
        XCTAssertEqual(MemoryAuditEditPage.tagSuggestions(pool, shown: [], typed: "#陶"), ["陶艺"])
    }

    func testSubjectRankingAndSuggestions() {
        let a = mem("x", created: now); a.subject = "岚舟"
        let b = mem("x", created: now); b.subject = " 岚舟 "
        let c = mem("x", created: now); c.subject = "星砚"
        let d = mem("x", created: now, trashed: true); d.subject = "删掉的"
        let e = mem("x", created: now); e.subject = " "
        XCTAssertEqual(MemoryAuditEditPage.subjectRanking([a, b, c, d, e]), ["岚舟", "星砚"])
        XCTAssertEqual(MemoryAuditEditPage.subjectSuggestions(["岚舟", "星砚"], typed: "岚舟", original: "岚舟"), ["星砚"], "没改过：全给，去掉填着的")
        XCTAssertEqual(MemoryAuditEditPage.subjectSuggestions(["岚舟", "星砚"], typed: "星", original: "岚舟"), ["星砚"], "打了别的字：只留含这段字的")
    }

    // MARK: - Edit 页四项（11-13：About / From（原 Said by）/ Confidence / Tags 能改）

    /// 候选标签：只数活着的卡、一张卡同一个只算一次、去空白；多→少，同数按字排；取前 limit 个
    func testTagRankingCountsLiveCardsOnly() {
        func card(_ tags: [String], trashed: Bool = false) -> Memory {
            let m = mem("x", created: now, trashed: trashed)
            m.keywords = tags
            return m
        }
        let ms = [card(["麦芽", "云桥城"]), card([" 麦芽 ", "麦芽", "岚舟"]), card(["云桥城", "星砚"]),
                  card(["麦芽"]), card(["删掉的", "删掉的"], trashed: true), card(["", " "]), card(["删掉的"], trashed: true)]
        XCTAssertEqual(MemoryAuditEditPage.tagRanking(ms), ["麦芽", "云桥城", "岚舟", "星砚"])
        XCTAssertEqual(MemoryAuditEditPage.tagRanking(ms, limit: 2), ["麦芽", "云桥城"])
        XCTAssertEqual(MemoryAuditEditPage.tagRanking([]), [])

        // 11-13：类别当标签算（「事实」不算），和同名普通标签在一张卡上只算一次
        let ctx = card(["近况", "陶艺"])
        ctx.category = "context"
        let ctx2 = card([])
        ctx2.category = "context"
        XCTAssertEqual(MemoryAuditEditPage.tagRanking([ctx, ctx2, card(["陶艺"])]), ["近况", "陶艺"])
    }

    func testTagSuggestionsSkipTagsOnCard() {
        let pool = ["麦芽", "云桥城", "岚舟", "星砚"]
        XCTAssertEqual(MemoryAuditEditPage.suggestions(pool, excluding: [" 云桥城", "别的"]), ["麦芽", "岚舟", "星砚"])
        XCTAssertEqual(MemoryAuditEditPage.suggestions(pool, excluding: [], limit: 2), ["麦芽", "云桥城"])
        XCTAssertEqual(MemoryAuditEditPage.suggestions(pool, excluding: pool), [])
    }

    func testAddingTag() {
        XCTAssertEqual(MemoryAuditEditPage.adding(" 岚舟 ", to: ["麦芽"]), ["麦芽", "岚舟"])
        XCTAssertEqual(MemoryAuditEditPage.adding("##星砚", to: ["麦芽"]), ["麦芽", "星砚"], "打在前面的 # 去掉")
        XCTAssertEqual(MemoryAuditEditPage.adding("麦芽", to: [" 麦芽 "]), [" 麦芽 "], "已经有的不加，原数组原样")
        XCTAssertEqual(MemoryAuditEditPage.adding("  ", to: ["麦芽"]), ["麦芽"])
        XCTAssertEqual(MemoryAuditEditPage.adding("#", to: []), [])
    }

    func testSpeakerOptionsKeepUnknownValue() {
        let three: [String?] = [nil, "用户自述", "AI 观察", "AI 承诺"]
        XCTAssertEqual(MemoryAuditEditPage.speakerOptions(current: nil), three)
        XCTAssertEqual(MemoryAuditEditPage.speakerOptions(current: "AI 观察"), three)
        XCTAssertEqual(MemoryAuditEditPage.speakerOptions(current: " "), three)
        XCTAssertEqual(MemoryAuditEditPage.speakerOptions(current: "星砚转述"), three + ["星砚转述"], "不在三种里的原样多一项")
        XCTAssertEqual(MemoryAuditTraits.origin("星砚转述", assistant: "星砚"), "星砚转述")
    }

    func testConfidenceInput() {
        XCTAssertEqual(MemoryAuditEditPage.confidenceInput("8a5"), "85")
        XCTAssertEqual(MemoryAuditEditPage.confidenceInput("12345"), "123")
        XCTAssertEqual(MemoryAuditEditPage.confidenceInput("８５"), "", "全角数字不收")
        XCTAssertNil(MemoryAuditEditPage.confidence(from: ""))
        XCTAssertEqual(MemoryAuditEditPage.confidence(from: "085"), 85)
        XCTAssertEqual(MemoryAuditEditPage.confidence(from: "250"), 100)
        XCTAssertEqual(MemoryAuditEditPage.confidence(from: "0"), 0)
    }

    /// Edit 页什么都没碰：四项原样传回，卡不动；只改了标签：只动标签、算 Approve
    func testEditPageDraftRoundTrip() {
        let m = mem("岚舟住在云桥城", created: now)
        m.subject = "岚舟"
        m.speaker = "星砚转述"
        m.keywords = ["云桥城", " "]
        m.confidence = 70
        XCTAssertFalse(MemoryAudit.apply(MemoryAudit.Edit(m), to: m, now: now))

        var edit = MemoryAudit.Edit(m)
        edit.keywords = MemoryAuditEditPage.adding("麦芽", to: edit.keywords)
        XCTAssertTrue(MemoryAudit.apply(edit, to: m, now: now))
        XCTAssertEqual(m.keywords, ["云桥城", "麦芽"])
        XCTAssertEqual(m.speaker, "星砚转述", "不认得的 speaker 没碰")
        XCTAssertEqual(m.confidence, 100, "只加了一个标签也是她改过")
        XCTAssertNotNil(m.reviewedAt)
    }
}
