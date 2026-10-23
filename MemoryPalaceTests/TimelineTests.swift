import XCTest
@testable import 记忆花园

/// M6 楼层日记特征测试：pendingDay 判定 / DailyFileStore 往返 / 注入开关口径。
final class TimelineTests: XCTestCase {

    let pid = "xctest-timeline"

    override func tearDown() {
        let floorDir = FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: floorDir)
        super.tearDown()
    }

    // MARK: - pendingDay（结算判定，candidates 按最近优先：昨天→7天前）

    let week = ["06-10", "06-09", "06-08", "06-07", "06-06", "06-05", "06-04"].map { "2026-\($0)" }

    func testNoActivityNothingPending() {
        XCTAssertNil(TimelineConsolidator.pendingDay(candidates: week, existing: [], active: []))
    }

    func testYesterdayActiveAndUnsettled() {
        XCTAssertEqual(TimelineConsolidator.pendingDay(candidates: week, existing: [], active: ["2026-06-10"]), "2026-06-10")
    }

    func testSettledDaysSkippedFindsOlderGap() {
        // 昨天已结，前天活跃未结 → 结前天
        let r = TimelineConsolidator.pendingDay(candidates: week, existing: ["2026-06-10"], active: ["2026-06-10", "2026-06-09"])
        XCTAssertEqual(r, "2026-06-09")
    }

    func testAllSettledNothingPending() {
        XCTAssertNil(TimelineConsolidator.pendingDay(candidates: week, existing: Set(week), active: Set(week)))
    }

    func testRecentPreferredOverOlder() {
        // 昨天和 5 天前都未结 → 先结昨天（candidates 序）
        let r = TimelineConsolidator.pendingDay(candidates: week, existing: [], active: ["2026-06-05", "2026-06-10"])
        XCTAssertEqual(r, "2026-06-10")
    }

    func testInactiveDaySkippedEvenIfUnsettled() {
        // 昨天无活动（即使未结）→ 跳到更早的活跃日
        let r = TimelineConsolidator.pendingDay(candidates: week, existing: [], active: ["2026-06-08"])
        XCTAssertEqual(r, "2026-06-08")
    }

    // MARK: - DailyFileStore

    func testSaveLoadRoundtripAndLatest() {
        let n1 = DailyNote(date: "2026-06-09", text: "前天的日记", sourceConversations: 2, sourceMessages: 0, updatedAt: Date())
        let n2 = DailyNote(date: "2026-06-10", text: "昨天的日记", sourceConversations: 3, sourceMessages: 0, updatedAt: Date())
        DailyFileStore.save(n1, profileId: pid)
        DailyFileStore.save(n2, profileId: pid)

        XCTAssertEqual(DailyFileStore.existingDates(profileId: pid), ["2026-06-09", "2026-06-10"])
        let loaded = DailyFileStore.load(date: "2026-06-09", profileId: pid)
        XCTAssertEqual(loaded?.text, "前天的日记")
        XCTAssertEqual(loaded?.sourceConversations, 2)
        XCTAssertEqual(DailyFileStore.latest(profileId: pid)?.date, "2026-06-10", "latest 取日期字典序最大")
    }

    func testDailyFilesVisibleInMemoryTree() {
        MainThreadIO.allowMainThreadInThisTest()   // #033：测试体直接调 store / 工具，测试自己站主线程
        DailyFileStore.save(DailyNote(date: "2026-06-10", text: "可被工具读到", sourceConversations: 1, sourceMessages: 0, updatedAt: Date()), profileId: pid)
        let paths = FileLibraryStore.memoryList(profileId: pid).map(\.path)
        XCTAssertTrue(paths.contains("memory/daily/2026-06-10.md"), "日记应在记忆树挂载里: \(paths)")
        let r = FileLibraryTools.execute(name: "fs_read", inputJSON: #"{"path": "memory/daily/2026-06-10.md"}"#, profileId: pid)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("可被工具读到"))
    }

    // MARK: - 注入开关口径

    func testInjectionTextGatedBySwitch() {
        let timelineKey = "mem_content_timeline"
        let saved = UserDefaults.standard.object(forKey: timelineKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: timelineKey) }
            else { UserDefaults.standard.removeObject(forKey: timelineKey) }
        }
        DailyFileStore.save(DailyNote(date: "2026-06-10", text: "日记内容", sourceConversations: 1, sourceMessages: 0, updatedAt: Date()), profileId: pid)

        UserDefaults.standard.set(false, forKey: timelineKey)
        XCTAssertNil(TimelineConsolidator.injectionText(profileId: pid), "开关关 = 不注入")

        UserDefaults.standard.set(true, forKey: timelineKey)
        let text = TimelineConsolidator.injectionText(profileId: pid)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("[时间轴·2026-06-10]") == true)
    }
}
