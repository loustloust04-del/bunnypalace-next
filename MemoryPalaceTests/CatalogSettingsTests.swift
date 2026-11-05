import XCTest
@testable import 记忆花园

/// C3 设置（plan-memory-c3-catalog 4.3、todo 9）：写手转正、键默认值、夹范围、配置导出白名单、写入预算 / 账本、二级页路由、设置搜索
final class CatalogSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "xctest-catalog-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testC3IsARealBackgroundWriter() {
        XCTAssertFalse(MemoryWriterID.c3.isTodo)
        XCTAssertTrue(MemoryWriterID.c3.hasSwitch)
        XCTAssertTrue(MemoryWriterID.c3.isBackground)
        XCTAssertFalse(MemoryWriterID.c3.hasTrigger)
        XCTAssertNil(MemoryWriterID.c3.health, "没有健康种类，日志按编号记")
        XCTAssertEqual(MemoryWriterSettings.key(.c3), "mem_write_c3")
        XCTAssertEqual(MemoryWriterSettings.isOn(.c3, defaults: defaults), MemoryWriterSettings.isOn(.c2, defaults: defaults), "默认同 C2")
        XCTAssertTrue(MemoryWriterSettings.isOn(.c3, defaults: defaults))
        MemoryWriterSettings.set(.c3, false, defaults: defaults)
        XCTAssertFalse(MemoryWriterSettings.writes(.c3, defaults: defaults))
        XCTAssertFalse(MemoryWriterSettings.switchable.contains(.c3), "复杂度滑条不动 C3")
    }

    func testCatalogDefaultsAndClamp() {
        XCTAssertTrue(CatalogSettings.daily(defaults))
        XCTAssertEqual(CatalogSettings.maxTopics(defaults), 8)
        XCTAssertEqual(CatalogSettings.maxRounds(defaults), 10)
        defaults.set(false, forKey: CatalogSettings.dailyKey)
        defaults.set(100, forKey: CatalogSettings.maxTopicsKey)
        defaults.set(1, forKey: CatalogSettings.maxRoundsKey)
        XCTAssertFalse(CatalogSettings.daily(defaults))
        XCTAssertEqual(CatalogSettings.maxTopics(defaults), CatalogSettings.maxTopicsRange.upperBound)
        XCTAssertEqual(CatalogSettings.maxRounds(defaults), CatalogSettings.maxRoundsRange.lowerBound)
    }

    func testConfigSchemaWhitelist() {
        let entries = Dictionary(ConfigSchema.allScalarEntries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let expected: [(String, ConfigSchema.Kind)] = [
            ("mem_write_c3", .bool), ("mem_model_c3", .string), ("mem_c3_daily", .bool), ("mem_c3_max_topics", .int), ("mem_c3_agent_rounds", .int),
        ]
        for (key, kind) in expected {
            let e = entries[key]
            XCTAssertNotNil(e, key)
            XCTAssertEqual(e?.section, .memory, key)
            XCTAssertTrue(e.map { "\($0.kind)" == "\(kind)" } ?? false, key)
        }
        XCTAssertEqual(CatalogModelRoute.key, "mem_model_c3")
        XCTAssertEqual(CatalogSettings.dailyKey, "mem_c3_daily")
        XCTAssertEqual(CatalogSettings.maxTopicsKey, "mem_c3_max_topics")
        XCTAssertEqual(CatalogSettings.maxRoundsKey, "mem_c3_agent_rounds")
    }

    func testBudgetAndLedger() {
        XCTAssertTrue(WriteBudgetStore.kinds.contains(.catalog), "C3 算写入预算")
        XCTAssertEqual(UsageKind.catalog.label, "整理编目")
        XCTAssertEqual(MemoryWriterSpend.kind(.c3), .catalog)
        XCTAssertEqual(UsageKind(rawValue: "catalog"), .catalog)
    }

    func testRoutesAndSearch() {
        XCTAssertEqual(SettingsRoute.memoryWriter(.c3), .memoryWriterC3)
        XCTAssertEqual(SettingsRoute.memoryWriterC3.memoryWriterID, .c3)
        XCTAssertNil(SettingsRoute.memoryCatalogStopWords.memoryWriterID)
        let entry = SettingsSearchEntry.all.first { $0.anchor == "leaf-mem-w-c3" }
        XCTAssertNotNil(entry)
        for word in ["每天自动整理", "不触发的词", "手动整理最多几轮"] {
            XCTAssertTrue(entry?.keywords.contains(word) == true, word)
        }
        XCTAssertFalse(entry?.keywords.contains("还没做") == true)
        XCTAssertEqual(MemoryWriterID.c3.subtitle(assistant: "小克"), "碎片和聊天整理成 wiki 页，先过目再写")
    }
}
