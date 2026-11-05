import XCTest
import SwiftData
@testable import 记忆花园

/// v5 §三【开窗口】：按编号一行一勾、每一轮生效；新键没写过 = 今天的值（默认下逐字不变）；写不写只看写入那一行
final class OpenWindowInjectionTests: XCTestCase {

    private var suite = ""
    private var d: UserDefaults!
    private let pid = "xctest-open-window"
    private let standardKeys = ["mem_master", "mem_content_summary", "mem_content_timeline",
                                MemoryOpenWindow.a2Key, MemoryOpenWindow.a4Key, MemoryOpenWindow.b4Key, MemoryOpenWindow.cKey]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        suite = "xctest-open-window-\(UUID().uuidString)"
        d = UserDefaults(suiteName: suite)!
        for k in standardKeys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: "mem_master")
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    func testUnwrittenKeysFollowTodaysSwitches() {
        XCTAssertTrue(MemoryOpenWindow.isChecked(.a2, defaults: d))
        d.set(false, forKey: "mem_content_summary")
        d.set(false, forKey: "mem_content_timeline")
        XCTAssertFalse(MemoryOpenWindow.isChecked(.a2, defaults: d), "没写过 = 读 mem_content_summary")
        XCTAssertFalse(MemoryOpenWindow.isChecked(.a4, defaults: d), "没写过 = 读 mem_content_timeline")
        XCTAssertTrue(MemoryOpenWindow.isChecked(.b4, defaults: d))
        XCTAssertFalse(MemoryOpenWindow.isChecked(.c, defaults: d), "C 没写过 = 不勾（粟粟 10-16：等 C3 整理好再开）")
    }

    /// C 改过的人不动：键里写过 true / false 各自照旧
    func testArchiveCheckWrittenValueKept() {
        d.set(true, forKey: MemoryOpenWindow.cKey)
        XCTAssertTrue(MemoryOpenWindow.isChecked(.c, defaults: d), "勾过的照旧勾着")
        d.set(false, forKey: MemoryOpenWindow.cKey)
        XCTAssertFalse(MemoryOpenWindow.isChecked(.c, defaults: d), "取消过的照旧不勾")
    }

    func testMigrationFreezesThenIndependent() {
        d.set(false, forKey: "mem_content_summary")
        MemoryFlags.migrateV5SplitIfNeeded(defaults: d)
        XCTAssertEqual(d.object(forKey: "mem_write_a3") as? Bool, false, "A3 写跟拆开前一样")
        XCTAssertEqual(d.object(forKey: MemoryOpenWindow.a2Key) as? Bool, false)
        XCTAssertEqual(d.object(forKey: MemoryOpenWindow.a4Key) as? Bool, true)
        // 之后各管各的：写入开回来不影响勾
        d.set(true, forKey: "mem_content_summary")
        XCTAssertFalse(MemoryOpenWindow.isChecked(.a2, defaults: d))
        // 只跑一次
        d.removeObject(forKey: "mem_write_a3")
        MemoryFlags.migrateV5SplitIfNeeded(defaults: d)
        XCTAssertNil(d.object(forKey: "mem_write_a3"))
    }

    func testMasterGates() {
        d.set(true, forKey: MemoryOpenWindow.cKey)
        XCTAssertTrue(MemoryOpenWindow.injects(.c, defaults: d))
        d.set(false, forKey: "mem_master")
        XCTAssertFalse(MemoryOpenWindow.injects(.c, defaults: d))
    }

    func testWriteOffDoesNotStopInjection() {
        UserDefaults.standard.set(false, forKey: "mem_content_summary")
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.a2Key)
        XCTAssertFalse(MemoryFlags.contextSummaryEnabled, "A2 不写")
        XCTAssertTrue(MemoryFlags.contextSummaryInjected, "已经写下的照样带")
    }

    @MainActor
    func testArchiveCheckGatesRoundInputs() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = SwiftDataMemoryStore()
        try store.add(content: "喜欢暖奶白", category: "preference", keywords: [], profileId: pid, isUserExplicit: true,
                      extractedBy: "t", sourceConversationId: nil, context: context)
        UserDefaults.standard.removeObject(forKey: MemoryOpenWindow.cKey)
        XCTAssertTrue(MemoryInjector.roundInputs(profileId: pid, conversationMemoryEnabled: true, store: store, context: context).memories.isEmpty,
                      "没写过 = C 不勾 = 档案不带（钉住的也不带，⧫3）")
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        XCTAssertEqual(MemoryInjector.roundInputs(profileId: pid, conversationMemoryEnabled: true, store: store, context: context).memories.count, 1,
                       "勾上才带")
        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.cKey)
        XCTAssertTrue(MemoryInjector.roundInputs(profileId: pid, conversationMemoryEnabled: true, store: store, context: context).memories.isEmpty,
                      "C 不勾 = 档案不带")
    }

    func testTimelineCheckGatesSlot() throws {
        let dir = TimelineStore.dir(profileId: pid)
        let now = Date()
        let e = TimelineEntry(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), conversationId: "conv-ow-1",
                              title: "T", text: "- 聊了一件事", pending: "", day: MemoryDay.key(now.addingTimeInterval(-3600)), lastNodeId: "n1")
        try TimelineStore.seedLegacy(e, in: dir)
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        UserDefaults.standard.removeObject(forKey: MemoryOpenWindow.a4Key)
        XCTAssertTrue(CalendarInjection.timelineSlot(profileId: pid, now: now).units.contains { $0.key.hasSuffix("|conv-ow-1") })
        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.a4Key)
        XCTAssertTrue(CalendarInjection.timelineSlot(profileId: pid, now: now).units.isEmpty, "A4 不勾 = 不带")
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.a4Key)
        XCTAssertTrue(CalendarInjection.timelineSlot(profileId: pid, now: now).units.contains { $0.key.hasSuffix("|conv-ow-1") }, "A4 不写了，已经写下的照样带")
    }
}
