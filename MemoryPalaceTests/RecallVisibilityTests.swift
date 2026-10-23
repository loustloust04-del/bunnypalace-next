import XCTest
import SwiftData
@testable import 记忆花园

/// 召回可见性（recall-visibility）刀 1/2/4 测试。
/// buildInjectionSplit 读 UserDefaults 开关，setUp/tearDown 复原所有动过的 key。
final class RecallVisibilityTests: XCTestCase {

    let pid = "xctest-recall-vis"

    private let touchedKeys = [
        "mem_inject_catalog", "mem_inject_keyword", "mem_inject_vector",
        "mem_inject_full", "mem_inject_graph",
    ]

    override func setUp() {
        super.setUp()
        touchedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        touchedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func makeMemory(_ content: String, category: String = "fact",
                            pinned: Bool = false, keywords: [String] = []) -> Memory {
        Memory(content: content, category: category, keywords: keywords,
               profileId: pid, isUserExplicit: pinned)
    }

    // MARK: - 刀 1 · hits 与注入行严格同步

    func testHitsMatchInjectedLines() {
        let mems = [makeMemory("用户喜欢暖奶白配色"), makeMemory("用户养了只猫", pinned: true)]
        let r = MemoryInjector.buildInjectionSplit(memories: mems, recentMessages: ["聊聊配色"])
        let lineCount = (r.stable.isEmpty ? 0 : r.stable.components(separatedBy: "\n").count)
            + (r.volatile.isEmpty ? 0 : r.volatile.components(separatedBy: "\n").count)
        XCTAssertEqual(r.hits.count, lineCount, "hits 数 == 注入行数")
        XCTAssertEqual(Set(r.hits.map(\.memoryId)).count, r.hits.count, "hits 无重复")
    }

    func testHitsCarryRetrieverAndScore() {
        UserDefaults.standard.set(true, forKey: "mem_inject_keyword")
        let mems = [
            makeMemory("用户喜欢暖奶白配色", keywords: ["配色"]),
            makeMemory("钉住的记忆", pinned: true),
        ]
        let r = MemoryInjector.buildInjectionSplit(memories: mems, recentMessages: ["聊聊配色"])
        let persistent = r.hits.filter { $0.retrieverId == "persistent" }
        let keyword = r.hits.filter { $0.retrieverId == "keyword" }
        XCTAssertFalse(persistent.isEmpty, "常驻层 hit 带 persistent 标（S1 用）")
        XCTAssertEqual(keyword.count, 1, "关键词命中一条")
        XCTAssertNotNil(keyword.first?.score, "BM25 命中带分数")
        XCTAssertGreaterThan(keyword.first!.score!, 0)
    }

    func testHitsRespectBudgetTruncation() {
        let long = String(repeating: "很长的记忆内容", count: 30)
        let mems = (0..<20).map { makeMemory("\(long)-\($0)") }
        let r = MemoryInjector.buildInjectionSplit(memories: mems, recentMessages: [], budget: 300)
        let volatileLines = r.volatile.isEmpty ? 0 : r.volatile.components(separatedBy: "\n").count
        let stableLines = r.stable.isEmpty ? 0 : r.stable.components(separatedBy: "\n").count
        XCTAssertEqual(r.hits.count, volatileLines + stableLines, "预算截断后 hits 同步截断")
        XCTAssertLessThan(r.hits.count, 20, "预算确实截了")
    }

    func testCatalogModeMarksHits() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        let r = MemoryInjector.buildInjectionSplit(memories: [makeMemory("目录条")], recentMessages: [])
        let volatileHits = r.hits.filter { $0.retrieverId != "persistent" }
        XCTAssertFalse(volatileHits.isEmpty)
        XCTAssertTrue(volatileHits.allSatisfy(\.catalog), "目录模式 hit 标 catalog")
    }

    func testSnippetSelfContained() {
        let long = String(repeating: "字", count: 100)
        let r = MemoryInjector.buildInjectionSplit(memories: [makeMemory(long)], recentMessages: [])
        XCTAssertEqual(r.hits.first?.snippet.count, 60, "snippet 截 60 字自含")
    }

    func testEmptySwitchesReturnEmptyHits() {
        UserDefaults.standard.set(false, forKey: "mem_inject_full")
        let r = MemoryInjector.buildInjectionSplit(memories: [makeMemory("一条")], recentMessages: [])
        XCTAssertTrue(r.hits.isEmpty, "无检索器 = 无 hits")
    }

    // MARK: - 刀 1 · blob 编解码 roundtrip（落库格式）

    func testInjectionHitCodableRoundtrip() throws {
        let hit = InjectionHit(memoryId: UUID(), snippet: "片段", category: "preference",
                               score: 0.61, retrieverId: "vector", catalog: false, vote: -1)
        let data = try JSONEncoder().encode([hit])
        let back = try JSONDecoder().decode([InjectionHit].self, from: data)
        XCTAssertEqual(back, [hit])
    }

    func testInjectionHitDecodesLegacyBlobWithoutVote() throws {
        // 老 blob 无 vote 字段也要能解（前向兼容）
        let json = #"[{"memoryId":"\#(UUID().uuidString)","snippet":"s","category":"fact","retrieverId":"keyword","catalog":false}]"#
        let back = try JSONDecoder().decode([InjectionHit].self, from: Data(json.utf8))
        XCTAssertNil(back.first?.vote)
        XCTAssertNil(back.first?.score)
    }

    // MARK: - 刀 4 · applyFeedback（in-memory container）

    private func makeContext() -> (ModelContainer, ModelContext) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Memory.self, configurations: config)
        return (container, ModelContext(container))
    }

    private func insertMemory(_ context: ModelContext, pinned: Bool = false, weight: Double = 0.8) -> Memory {
        let m = makeMemory("反馈测试记忆", pinned: pinned)
        m.decayWeight = weight
        context.insert(m)
        try! context.save()
        return m
    }

    func testUpvoteReinforces() throws {
        let (container, context) = makeContext(); _ = container
        let store = SwiftDataMemoryStore()
        let m = insertMemory(context, weight: 0.5)
        let countBefore = m.accessCount
        try store.applyFeedback(id: m.id, vote: 1, previousVote: nil, context: context)
        XCTAssertEqual(m.decayWeight, 0.7, accuracy: 0.001, "👍 = +0.2")
        XCTAssertEqual(m.accessCount, countBefore + 1)
    }

    func testDownvoteLowersWeightAndClamps() throws {
        let (container, context) = makeContext(); _ = container
        let store = SwiftDataMemoryStore()
        let m = insertMemory(context, weight: 0.2)
        try store.applyFeedback(id: m.id, vote: -1, previousVote: nil, context: context)
        XCTAssertEqual(m.decayWeight, 0, accuracy: 0.001, "👎 = −0.3 clamp 0")
        XCTAssertEqual(m.feedbackDownCount, 1)
        XCTAssertNil(m.supersededAt, "一次 👎 不失效")
    }

    func testTwoDownvotesSupersede() throws {
        let (container, context) = makeContext(); _ = container
        let store = SwiftDataMemoryStore()
        let m = insertMemory(context)
        try store.applyFeedback(id: m.id, vote: -1, previousVote: nil, context: context)
        try store.applyFeedback(id: m.id, vote: -1, previousVote: nil, context: context)
        XCTAssertNotNil(m.supersededAt, "累计 2 次 👎 → 软失效")
    }

    func testPinnedMemoryExemptFromSupersede() throws {
        let (container, context) = makeContext(); _ = container
        let store = SwiftDataMemoryStore()
        let m = insertMemory(context, pinned: true)
        try store.applyFeedback(id: m.id, vote: -1, previousVote: nil, context: context)
        try store.applyFeedback(id: m.id, vote: -1, previousVote: nil, context: context)
        XCTAssertNil(m.supersededAt, "手动钉住的不许被踩死")
    }

    func testChangeVoteRollsBackSymmetrically() throws {
        let (container, context) = makeContext(); _ = container
        let store = SwiftDataMemoryStore()
        let m = insertMemory(context, weight: 0.5)
        try store.applyFeedback(id: m.id, vote: -1, previousVote: nil, context: context)      // 0.5 → 0.2
        try store.applyFeedback(id: m.id, vote: 1, previousVote: -1, context: context)        // 回滚 +0.3 → 0.5，再 👍 +0.2 → 0.7
        XCTAssertEqual(m.decayWeight, 0.7, accuracy: 0.001, "改投对称回滚")
        XCTAssertEqual(m.feedbackDownCount, 0)
    }

    func testChangeVoteUndoesFeedbackSupersede() throws {
        let (container, context) = makeContext(); _ = container
        let store = SwiftDataMemoryStore()
        let m = insertMemory(context)
        try store.applyFeedback(id: m.id, vote: -1, previousVote: nil, context: context)
        try store.applyFeedback(id: m.id, vote: -1, previousVote: nil, context: context)
        XCTAssertNotNil(m.supersededAt)
        try store.applyFeedback(id: m.id, vote: 1, previousVote: -1, context: context)
        XCTAssertNil(m.supersededAt, "误踩纠回：改投解除反馈触发的软失效")
    }
}
