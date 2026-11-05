import XCTest
@testable import 记忆花园

/// v5 §五：复杂度滑条不存值——位置由写入开关算；拖一档 = 改一组开关；对不上 = 自定义
final class MemoryComplexityTests: XCTestCase {

    private var suite = ""
    private var d: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "xctest-mem-complexity-\(UUID().uuidString)"
        d = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFreshInstallIsMiddle() {
        XCTAssertEqual(MemoryComplexity.current(defaults: d), 2, "今天新装的默认 = 中")
        XCTAssertEqual(MemoryComplexity.summary(defaults: d), "中 · 开 5 项")
        XCTAssertTrue(MemoryWriterSettings.isOn(.a3, defaults: d))
        XCTAssertFalse(MemoryWriterSettings.isOn(.b1, defaults: d), "心声默认关")
    }

    func testLevelsTable() {
        XCTAssertEqual(MemoryComplexity.levels[0], [.a2])
        XCTAssertEqual(MemoryComplexity.levels[1], [.a2, .a4])
        XCTAssertEqual(MemoryComplexity.levels[2], [.a2, .a3, .a4, .b4, .c2])
        XCTAssertEqual(MemoryComplexity.levels[3], [.a2, .a3, .a4, .b1, .b4, .c2])
    }

    func testDragSetsSwitchesOnlyWriteOnes() {
        d.set(true, forKey: "mem_inject_catalog")
        MemoryComplexity.apply(0, defaults: d)
        XCTAssertEqual(MemoryComplexity.onSet(defaults: d), [.a2])
        XCTAssertEqual(d.object(forKey: "mem_content_timeline") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "mem_inject_catalog") as? Bool, true, "只动写入开关")
        MemoryComplexity.apply(3, defaults: d)
        XCTAssertEqual(MemoryComplexity.current(defaults: d), 3)
        XCTAssertEqual(d.object(forKey: "mem_content_heartvoice") as? Bool, true)
    }

    func testManualChangeShowsCustom() {
        MemoryComplexity.apply(2, defaults: d)
        MemoryWriterSettings.set(.a3, false, defaults: d)
        XCTAssertNil(MemoryComplexity.current(defaults: d))
        XCTAssertEqual(MemoryComplexity.summary(defaults: d), "自定义 · 开 4 项")
    }

    func testA3FollowsOldKeyUntilWritten() {
        d.set(false, forKey: "mem_content_summary")
        XCTAssertFalse(MemoryWriterSettings.isOn(.a3, defaults: d), "拆开前 A2 / A3 一个开关：没写过跟老键")
        MemoryWriterSettings.set(.a3, true, defaults: d)
        XCTAssertTrue(MemoryWriterSettings.isOn(.a3, defaults: d))
        XCTAssertFalse(MemoryWriterSettings.isOn(.a2, defaults: d), "拆开后各管各的")
    }

    func testMasterGatesWrites() {
        XCTAssertTrue(MemoryWriterSettings.writes(.b4, defaults: d))
        d.set(false, forKey: "mem_master")
        XCTAssertFalse(MemoryWriterSettings.writes(.b4, defaults: d))
    }
}
