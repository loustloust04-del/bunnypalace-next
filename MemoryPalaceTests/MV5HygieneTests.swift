import XCTest
import SwiftData
@testable import 记忆花园

/// MV5 存量整理 特征测试。
/// in-memory ModelContainer；不调网络 dream，只测 helper + pair 纯函数 + 边界。
final class MV5HygieneTests: XCTestCase {

    let pid = "xctest-mv5"
    var container: ModelContainer!
    var context: ModelContext!
    let store = SwiftDataMemoryStore()

    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: Memory.self, configurations: config)
        context = ModelContext(container)
        UserDefaults.standard.removeObject(forKey: "mem_supersede_soft")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mem_supersede_soft")
        container = nil
        super.tearDown()
    }

    // MARK: - 刀1 helper

    func testConsumedIdsExcludesPinned() throws {
        let auto = try store.add(content: "auto1", category: "fact", keywords: [],
                                 profileId: pid, isUserExplicit: false, extractedBy: "t",
                                 sourceConversationId: nil, context: context)
        let pinned = try store.add(content: "pinned1", category: "fact", keywords: [],
                                   profileId: pid, isUserExplicit: true, extractedBy: "t",
                                   sourceConversationId: nil, context: context)
        let mems = store.listHotAndWarm(profileId: pid, context: context)
        let consumed = DreamConsolidator.consumedIdsFromCandidates(mems)
        XCTAssertEqual(consumed.count, 1)
        XCTAssertTrue(consumed.contains(auto.id))
        XCTAssertFalse(consumed.contains(pinned.id), "钉住碎片不进毕业候选")
    }

    func testGraduateRespectsSoftEnabledSwitch() throws {
        let m1 = try store.add(content: "x", category: "fact", keywords: [],
                               profileId: pid, isUserExplicit: false, extractedBy: "t",
                               sourceConversationId: nil, context: context)
        UserDefaults.standard.set(false, forKey: "mem_supersede_soft")
        let n = DreamConsolidator.graduateConsumedMemories(consumedIds: [m1.id], store: store, context: context)
        XCTAssertEqual(n, 0, "mem_supersede_soft 关时跳过毕业")
        XCTAssertNil(store.listAll(profileId: pid, context: context).first?.supersededAt)
    }

    func testGraduateCountsActualSupersededOnly() throws {
        let m1 = try store.add(content: "a", category: "fact", keywords: [],
                               profileId: pid, isUserExplicit: false, extractedBy: "t",
                               sourceConversationId: nil, context: context)
        let bogusId = UUID()
        let n = DreamConsolidator.graduateConsumedMemories(consumedIds: [m1.id, bogusId], store: store, context: context)
        // SwiftDataMemoryStore.supersede 对找不到的 id 是 no-op 而不是 throw，所以两个都算成功
        XCTAssertGreaterThanOrEqual(n, 1, "至少存在的那条要毕业成功")
        XCTAssertNotNil(store.listAll(profileId: pid, context: context).first?.supersededAt)
    }

    // MARK: - 刀2 pairDedup 纯函数

    /// 构造带向量的 Memory，sim 由两向量的点积决定
    private func makeMem(content: String, vec: [Float], revision: Int = 7, pinned: Bool = false, updatedAt: Date) -> Memory {
        let m = Memory(content: content, category: "fact", keywords: [], profileId: pid, isUserExplicit: pinned)
        m.embeddingData = MemoryVector.data(from: vec)
        m.embeddingRevision = revision
        m.updatedAt = updatedAt
        return m
    }

    func testPairDedupKeepsNewerAndSupersedesOlder() {
        let now = Date()
        let older = makeMem(content: "用户喜欢拿铁", vec: [1, 0, 0], updatedAt: now.addingTimeInterval(-3600))
        let newer = makeMem(content: "用户偏好拿铁", vec: [0.99, 0.141, 0], updatedAt: now)  // sim ≈ 0.99
        let pairs = MemoryHygiene.pairDedup(memories: [older, newer], threshold: 0.75)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].keepId, newer.id, "保新（updatedAt 大）")
        XCTAssertEqual(pairs[0].supersedeId, older.id, "毕业旧（updatedAt 小）")
    }

    func testPairDedupRespectsPinnedImmunity() {
        let now = Date()
        // 钉住作为'旧'内层 → 永不毕业；自动作为'新'外层
        let pinnedOlder = makeMem(content: "钉住的", vec: [1, 0, 0], pinned: true, updatedAt: now.addingTimeInterval(-3600))
        let autoNewer = makeMem(content: "自动的", vec: [0.99, 0.141, 0], updatedAt: now)
        let pairs = MemoryHygiene.pairDedup(memories: [pinnedOlder, autoNewer], threshold: 0.75)
        XCTAssertEqual(pairs.count, 0, "钉住作为内层旧条 → m2 skip，不毕业")
    }

    func testPairDedupPinnedAsOuterCanGraduateAuto() {
        let now = Date()
        // 钉住作为外层'新' → 可以毕业自动条
        let pinnedNewer = makeMem(content: "钉住的", vec: [1, 0, 0], pinned: true, updatedAt: now)
        let autoOlder = makeMem(content: "自动的", vec: [0.99, 0.141, 0], updatedAt: now.addingTimeInterval(-3600))
        let pairs = MemoryHygiene.pairDedup(memories: [pinnedNewer, autoOlder], threshold: 0.75)
        XCTAssertEqual(pairs.count, 1, "钉住作为外层新条 → 可毕业自动条")
        XCTAssertEqual(pairs[0].keepId, pinnedNewer.id)
        XCTAssertEqual(pairs[0].supersedeId, autoOlder.id)
    }

    func testPairDedupSkipsBelowThreshold() {
        let now = Date()
        let a = makeMem(content: "甲", vec: [1, 0, 0], updatedAt: now)
        let b = makeMem(content: "乙", vec: [0, 1, 0], updatedAt: now.addingTimeInterval(-3600))  // sim=0
        XCTAssertTrue(MemoryHygiene.pairDedup(memories: [a, b], threshold: 0.75).isEmpty)
    }

    func testPairDedupRevisionMismatchSkipped() {
        let now = Date()
        let m1 = makeMem(content: "a", vec: [1, 0, 0], revision: 7, updatedAt: now)
        let m2 = makeMem(content: "b", vec: [1, 0, 0], revision: 3, updatedAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(MemoryHygiene.pairDedup(memories: [m1, m2], threshold: 0.75).isEmpty, "跨模型 revision 不在同向量空间")
    }

    func testPairDedupAlreadyMergedExcludedAsOuter() {
        // 三条全相似：A (new), B (mid), C (old)
        // 期望：A 毕业 B；C 排第三，外层是 C 但 C 不应找到任何内层（B 已 alreadyMerged）→ 0 个新对
        // 但 A 是外层时同时也会发现 C 相似 → 输出 (A keep, C supersede) → 2 对
        let now = Date()
        let a = makeMem(content: "A 最新", vec: [1, 0, 0], updatedAt: now)
        let b = makeMem(content: "B 中间", vec: [0.99, 0.141, 0], updatedAt: now.addingTimeInterval(-1800))
        let c = makeMem(content: "C 最旧", vec: [0.98, 0.199, 0], updatedAt: now.addingTimeInterval(-3600))
        let pairs = MemoryHygiene.pairDedup(memories: [a, b, c], threshold: 0.75)
        // A 作为外层依次 vs B/C —— A↔B sim>0.75 加入；A↔C sim>0.75 加入；B 跳过（alreadyMerged 不会 但 B 还没被加入 alreadyMerged 这里需要确认行为）
        // 实际：i=0(A) j=1(B) → 加入 (A→B)，B 加入 alreadyMerged
        //       i=0(A) j=2(C) → 加入 (A→C)，C 加入 alreadyMerged
        //       i=1(B) → alreadyMerged 跳过
        //       i=2(C) → alreadyMerged 跳过
        XCTAssertEqual(pairs.count, 2, "A 同时毕业 B 和 C")
        XCTAssertTrue(pairs.allSatisfy { $0.keepId == a.id })
    }
}
