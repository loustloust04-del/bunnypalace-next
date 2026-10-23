import XCTest
import SwiftData
@testable import 记忆花园

/// SC-B3 目录式注入特征测试。buildInjectionSplit 读 UserDefaults 开关，
/// setUp/tearDown 复原所有动过的 key，不污染其他用例。
final class CatalogInjectionTests: XCTestCase {

    let pid = "xctest-catalog"

    private let touchedKeys = [
        "mem_inject_catalog", "mem_inject_keyword", "mem_inject_vector",
        "mem_inject_full", "mem_content_convhistory",
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
        let m = Memory(content: content, category: category, keywords: keywords,
                       profileId: pid, isUserExplicit: pinned)
        return m
    }

    // MARK: - 开关关 = 现状逐字一致（回归锚）

    func testCatalogOffOutputUnchanged() {
        let mems = [makeMemory("用户喜欢暖奶白配色"), makeMemory("用户养了只猫", pinned: true)]
        let off = MemoryInjector.buildInjectionSplit(memories: mems, recentMessages: ["聊聊配色"])
        XCTAssertTrue(off.volatile.contains("用户喜欢暖奶白配色"), "开关关 = 全文行（现状）")
        XCTAssertFalse(off.volatile.contains("…"), "全文模式不截断")
        XCTAssertFalse(off.volatile.contains("recall"), "全文模式无 hint")
    }

    // MARK: - 开关开 = volatile 目录化，stable 全文

    func testCatalogOnVolatileBecomesCatalogStableStaysFull() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        let long = String(repeating: "这条记忆内容相当长要超过六十个字符的截断阈值才能看出目录行效果", count: 3)
        let mems = [makeMemory(long), makeMemory("钉住的全文记忆", pinned: true)]
        let r = MemoryInjector.buildInjectionSplit(memories: mems, recentMessages: ["随便聊"])
        XCTAssertTrue(r.stable.contains("钉住的全文记忆"), "stable 常驻层保持全文")
        XCTAssertTrue(r.volatile.contains("…"), "目录行 60 字截断")
        XCTAssertTrue(r.volatile.contains("·事实]"), "目录行带 [日期·分类]")
        XCTAssertFalse(r.volatile.contains(long), "全文不进 volatile")
    }

    // MARK: - 行计费：同预算装更多条

    func testCatalogBillsByLineFittingMoreEntries() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        // 每条全文 ~400 token（200 CJK 字 ×2），预算 1000：全文只装 2 条，目录行 ~50 token 能装更多
        let mems = (0..<8).map { i in
            makeMemory("第\(i)条" + String(repeating: "很长的记忆内容", count: 28))
        }
        let catalog = MemoryInjector.buildInjectionSplit(memories: mems, recentMessages: [], budget: 1000)
        let catalogLines = catalog.volatile.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }

        UserDefaults.standard.set(false, forKey: "mem_inject_catalog")
        let full = MemoryInjector.buildInjectionSplit(memories: mems, recentMessages: [], budget: 1000)
        let fullLines = full.volatile.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }

        XCTAssertGreaterThan(catalogLines.count, fullLines.count, "目录按行计费，同预算装更多条")
    }

    // MARK: - 修复第一刀·刀4：关键词模式下常驻层（关系/偏好）仍全文，命中层目录化

    func testKeywordModePersistentCategoriesStayFullText() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        UserDefaults.standard.set(true, forKey: "mem_inject_keyword")
        UserDefaults.standard.set(false, forKey: "mem_inject_full")
        let rel = makeMemory("我们是彼此最亲近的人，已经一起走过很长一段日子了，这是关系层的常驻记忆", category: "relationship")
        let fact = makeMemory(String(repeating: "用户正在做记忆宫殿这个项目，", count: 6))
        let r = MemoryInjector.buildInjectionSplit(memories: [rel, fact], recentMessages: ["今天聊聊记忆宫殿项目"])
        XCTAssertTrue(r.stable.contains(rel.content), "关系类走常驻层，全文")
        XCTAssertTrue(r.volatile.hasPrefix("- ["), "命中的事实类是目录行")
        XCTAssertFalse(r.volatile.contains(fact.content), "全文不进命中层")
    }

    // MARK: - 条数上限

    func testCatalogEntriesCapAt30() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        let mems = (0..<50).map { makeMemory("短记忆第\($0)条") }
        let r = MemoryInjector.buildInjectionSplit(memories: mems, recentMessages: [], budget: 100_000)
        let lines = r.volatile.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
        XCTAssertEqual(lines.count, MemoryInjector.maxCatalogEntries, "超出 maxCatalogEntries 截断")
    }

    // MARK: - recall hint 守卫

    func testHintPresentWhenRecallOn() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        let r = MemoryInjector.buildInjectionSplit(memories: [makeMemory("一条记忆")], recentMessages: [])
        XCTAssertTrue(r.volatile.contains("recall 工具"), "recall 默认开 → 目录尾带 hint")
    }

    func testHintAbsentWhenRecallOff() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        UserDefaults.standard.set(false, forKey: "mem_content_convhistory")
        let r = MemoryInjector.buildInjectionSplit(memories: [makeMemory("一条记忆")], recentMessages: [])
        XCTAssertFalse(r.volatile.contains("recall"), "recall 关 → 不指模型去不存在的工具")
    }

    func testEmptyVolatileNoOrphanHint() {
        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        // 只有钉住记忆 → 全进 stable，volatile 空 → 不留孤行 hint
        let r = MemoryInjector.buildInjectionSplit(memories: [makeMemory("钉住", pinned: true)], recentMessages: [])
        XCTAssertFalse(r.volatile.contains("recall"), "volatile 空不留孤行 hint")
    }

    // MARK: - MCP last-known-good 防缩守卫（SC-B5 批注3 小刀，顺挂本文件）

    func testToolGuardKeepsCacheOnEmptyRemote() {
        XCTAssertTrue(MCPProvider.shouldKeepCachedTools(remoteCount: 0, cachedCount: 5), "成功返回空列表 = 疑似抖动，保旧")
        XCTAssertFalse(MCPProvider.shouldKeepCachedTools(remoteCount: 0, cachedCount: 0), "本来就空，照常")
    }

    func testToolGuardKeepsCacheOnBigShrink() {
        XCTAssertTrue(MCPProvider.shouldKeepCachedTools(remoteCount: 4, cachedCount: 10), "缩水 >50% 保旧")
        XCTAssertFalse(MCPProvider.shouldKeepCachedTools(remoteCount: 5, cachedCount: 10), "恰好 50% 接受")
        XCTAssertFalse(MCPProvider.shouldKeepCachedTools(remoteCount: 12, cachedCount: 10), "增长照常接受")
    }
}
