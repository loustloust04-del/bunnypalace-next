import XCTest
import SwiftData
@testable import 记忆花园

/// 刀4（plan-memory-usable）：全量在场特征测试。
/// 公理（research-memory-usable，粟粟已批）：注入资格 = 未 superseded；衰减不决定在场；
/// 预算 10000 不限条；排序 createdAt 稳定（缓存前缀）；超预算从最老端截断，钉住豁免。
final class MemoryFullPresenceTests: XCTestCase {

    var container: ModelContainer!
    var context: ModelContext!
    let pid = "xctest-full-presence"
    let store = SwiftDataMemoryStore()

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: Memory.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        // 全量模式 = keyword/vector 关（迁移后默认态）
        UserDefaults.standard.removeObject(forKey: "mem_inject_keyword")
        UserDefaults.standard.removeObject(forKey: "mem_inject_vector")
        UserDefaults.standard.removeObject(forKey: "mem_inject_full")
        UserDefaults.standard.removeObject(forKey: "mem_inject_catalog")
        UserDefaults.standard.removeObject(forKey: "mem_inject_budget")
    }

    override func tearDown() {
        for k in ["mem_fulltext_migrated_v1", "mem_inject_keyword", "mem_inject_vector", "mem_inject_budget"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        container = nil
        super.tearDown()
    }

    @discardableResult
    private func seed(_ content: String, weight: Double = 1.0, pinned: Bool = false,
                      superseded: Bool = false, createdAt: Date = Date()) -> Memory {
        let m = Memory(content: content, category: "fact", profileId: pid, isUserExplicit: pinned)
        m.decayWeight = weight
        m.createdAt = createdAt
        if superseded { m.supersededAt = Date() }
        context.insert(m)
        try! context.save()
        return m
    }

    // MARK: - listActive：在场资格与衰减解耦

    func testListActiveIncludesColdExcludesSuperseded() {
        seed("热记忆", weight: 1.0)
        seed("冷记忆", weight: 0.01)                    // 旧 listHot（≥0.3）会滤掉它
        seed("已失效", weight: 1.0, superseded: true)

        let active = store.listActive(profileId: pid, context: context)
        XCTAssertEqual(active.count, 2, "冷记忆也在场；superseded 排除")
        XCTAssertTrue(active.contains { $0.content == "冷记忆" }, "衰减权重不再决定在场资格")
        XCTAssertFalse(active.contains { $0.content == "已失效" })
    }

    // MARK: - 注入：冷记忆进 prompt + 顺序稳定

    func testColdMemoryInjectedUnderBudget() {
        seed("她在宿务学英语", weight: 0.01)
        let memories = store.listActive(profileId: pid, context: context)
        let (stable, volatilePart, _) = MemoryInjector.buildInjectionSplit(memories: memories, recentMessages: [])
        XCTAssertTrue((stable + volatilePart).contains("她在宿务学英语"), "冷记忆预算内必须注入")
    }

    func testInjectionOutputStableAcrossCalls() {
        for i in 0..<20 {
            seed("事实\(i)", weight: Double.random(in: 0.01...1.0),
                 createdAt: Date(timeIntervalSinceNow: -Double(i) * 3600))
        }
        let memories = store.listActive(profileId: pid, context: context)
        let a = MemoryInjector.buildInjectionSplit(memories: memories, recentMessages: [])
        let b = MemoryInjector.buildInjectionSplit(memories: memories, recentMessages: [])
        XCTAssertEqual(a.stable, b.stable)
        XCTAssertEqual(a.volatile, b.volatile, "同输入输出必须逐字节稳定（缓存前缀）")
    }

    func testBudgetTruncatesOldestFirstPinnedSurvives() {
        let old = Date(timeIntervalSinceNow: -86400 * 30)
        seed(String(repeating: "最老的一条内容", count: 20), createdAt: old)                       // 超长老条目
        seed("钉住的老条目", pinned: true, createdAt: Date(timeIntervalSinceNow: -86400 * 60))     // 更老但钉住
        seed("最新的条目", createdAt: Date())

        UserDefaults.standard.set(80, forKey: "mem_inject_budget")   // 逼截断
        defer { UserDefaults.standard.removeObject(forKey: "mem_inject_budget") }

        let memories = store.listActive(profileId: pid, context: context)
        let (stable, volatilePart, _) = MemoryInjector.buildInjectionSplit(memories: memories, recentMessages: [])
        let all = stable + volatilePart
        XCTAssertTrue(stable.contains("钉住的老条目"), "钉住在 stable 层豁免截断")
        XCTAssertTrue(all.contains("最新的条目"), "新条目优先保留")
        XCTAssertFalse(all.contains("最老的一条内容"), "超预算从最老端截断")
    }

    // MARK: - 预算默认 + 迁移

    func testDefaultBudgetIs10000() {
        XCTAssertEqual(MemoryInjector.tokenBudget, 10_000)
    }

    func testMigrationClearsLegacyKeysOnceAndIsIdempotent() {
        let d = UserDefaults.standard
        d.set(true, forKey: "mem_inject_keyword")
        d.set(true, forKey: "mem_inject_vector")
        d.set(2000, forKey: "mem_inject_budget")

        MemoryFlags.migrateFullPresenceIfNeeded()
        XCTAssertNil(d.object(forKey: "mem_inject_keyword"), "显式旧键清除（⧫③ 已批）")
        XCTAssertNil(d.object(forKey: "mem_inject_vector"))
        XCTAssertNil(d.object(forKey: "mem_inject_budget"), "旧预算 2000 清除，让 10000 生效")

        // 迁移后用户再显式开 = 新意愿，第二次跑不清
        d.set(true, forKey: "mem_inject_vector")
        MemoryFlags.migrateFullPresenceIfNeeded()
        XCTAssertEqual(d.object(forKey: "mem_inject_vector") as? Bool, true, "sentinel 防重跑，尊重新意愿")
    }

    func testMigrationKeepsCustomBudget() {
        let d = UserDefaults.standard
        d.set(5000, forKey: "mem_inject_budget")   // 非 2000 = 用户自定义过
        MemoryFlags.migrateFullPresenceIfNeeded()
        XCTAssertEqual(d.integer(forKey: "mem_inject_budget"), 5000, "自定义预算不动，只清旧默认 2000")
    }
}
