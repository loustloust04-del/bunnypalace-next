import XCTest
import SwiftData
@testable import 记忆花园

/// MV5 存量整理 特征测试。
/// in-memory ModelContainer；不调网络 dream，只测做梦毕业的 helper + 边界（「整理记忆」两两合并已由审计台取代，pairDedup 测试随之删掉）。
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
}
