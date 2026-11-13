import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// v5 §三【开窗口】：按编号一行一勾、每一轮生效；新键没写过 = 今天的值（默认下逐字不变）；写不写只看写入那一行
final class OpenWindowInjectionTests: XCTestCase {

    private var suite = ""
    private var d: UserDefaults!
    private let pid = "xctest-open-window"
    private let standardKeys = ["mem_master", "mem_content_summary", "mem_content_timeline",
                                MemoryOpenWindow.a2Key, MemoryOpenWindow.a4Key, MemoryOpenWindow.b4Key, MemoryOpenWindow.cKey,
                                MemoryOpenWindowStore.storageKey, RecallTuningStore.storageKey]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        suite = "xctest-open-window-\(UUID().uuidString)"
        d = UserDefaults(suiteName: suite)!
        for k in standardKeys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.removeObject(forKey: MemoryOpenWindowStore.storageKey)
        UserDefaults.standard.removeObject(forKey: RecallTuningStore.storageKey)
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
        XCTAssertTrue(EffectiveMemoryParticipation.resolve(profileId: pid, conversation: nil, preset: nil, defaults: d).archive)
        d.set(false, forKey: "mem_master")
        XCTAssertFalse(EffectiveMemoryParticipation.resolve(profileId: pid, conversation: nil, preset: nil, defaults: d).archive)
    }

    func testProfileChecksOverrideOnlyWrittenItemsAndKeepGlobalFallbackLive() throws {
        d.set(false, forKey: MemoryOpenWindow.a2Key)
        d.set(true, forKey: MemoryOpenWindow.cKey)
        XCTAssertFalse(MemoryOpenWindow.isChecked(.a2, profileId: "first", defaults: d))
        XCTAssertTrue(MemoryOpenWindow.isChecked(.c, profileId: "first", defaults: d))
        XCTAssertNil(d.data(forKey: MemoryOpenWindowStore.storageKey))
        MemoryOpenWindowStore.save(.a2, true, profileId: "first", defaults: d)
        MemoryOpenWindowStore.save(.c, false, profileId: "first", defaults: d)
        MemoryOpenWindowStore.save(.b4, false, profileId: "second", defaults: d)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(MemoryOpenWindow.isChecked(.a2, profileId: "first", defaults: reopened))
        XCTAssertFalse(MemoryOpenWindow.isChecked(.c, profileId: "first", defaults: reopened))
        XCTAssertFalse(MemoryOpenWindow.isChecked(.a2, profileId: "second", defaults: reopened))
        XCTAssertTrue(MemoryOpenWindow.isChecked(.c, profileId: "second", defaults: reopened))
        XCTAssertFalse(MemoryOpenWindow.isChecked(.b4, profileId: "second", defaults: reopened))
        XCTAssertTrue(MemoryOpenWindow.isChecked(.b4, profileId: "first", defaults: reopened))
        d.set(true, forKey: MemoryOpenWindow.a2Key)
        XCTAssertTrue(MemoryOpenWindow.isChecked(.a2, profileId: "second", defaults: d))
        d.set(false, forKey: "mem_master")
        XCTAssertFalse(EffectiveMemoryParticipation.resolve(profileId: "first", conversation: nil, preset: nil, defaults: d).a2Summary)
        XCTAssertEqual(d.object(forKey: MemoryOpenWindow.cKey) as? Bool, true)
    }

    @MainActor
    func testRootAndTriggerIndependentlyLoadWikiAndFloorChecksGateB4() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let wiki = WikiInjectionSnapshot(indexLines: ["- [[人/林栖]] 林栖"],
                                        pages: [.init(path: "人/林栖", title: "林栖", triggers: [], hook: "", now: "合成资料")])
        let warmed = WikiInjectionCache.WarmedSnapshot(generation: 0, snapshot: wiki)
        func inputs() -> MemoryInjector.RoundInputs {
            MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid),
                                       store: SwiftDataMemoryStore(), context: context, warmedWiki: warmed, useCachedWiki: false)
        }
        MemoryOpenWindowStore.save(.b4, false, profileId: pid)
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        let rootOnly = inputs()
        XCTAssertEqual(rootOnly.wiki?.indexLines, wiki.indexLines)
        XCTAssertEqual(rootOnly.wiki?.pages, [])
        XCTAssertNil(rootOnly.selfMemory)
        MemoryOpenWindowStore.save(.c, false, profileId: pid)
        RecallTuningStore.save(RecallTestTuning.make(), profileId: pid)
        let triggerOnly = inputs()
        XCTAssertEqual(triggerOnly.wiki?.indexLines, [])
        XCTAssertEqual(triggerOnly.wiki?.pages, wiki.pages)
        RecallTuningStore.reset(profileId: pid)
        XCTAssertNil(inputs().wiki)
    }

    func testWriteOffDoesNotStopInjection() {
        UserDefaults.standard.set(false, forKey: "mem_content_summary")
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.a2Key)
        XCTAssertFalse(MemoryFlags.contextSummaryEnabled, "A2 不写")
        XCTAssertTrue(EffectiveMemoryParticipation.resolve(profileId: pid, conversation: nil, preset: nil).a2Summary, "已经写下的照样带")
    }

    @MainActor
    func testArchiveCheckGatesRoundInputs() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = SwiftDataMemoryStore()
        try store.add(content: "喜欢暖奶白", category: "preference", keywords: [], profileId: pid, isUserExplicit: true,
                      extractedBy: "t", sourceConversationId: nil, context: context)
        UserDefaults.standard.removeObject(forKey: MemoryOpenWindow.cKey)
        XCTAssertTrue(MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid),
                                                 store: store, context: context).memories.isEmpty,
                      "没写过 = C 不勾 = 档案不带（钉住的也不带，⧫3）")
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        XCTAssertEqual(MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid),
                                                  store: store, context: context).memories.count, 1,
                       "勾上才带")
        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.cKey)
        XCTAssertTrue(MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid),
                                                 store: store, context: context).memories.isEmpty,
                      "C 不勾 = 档案不带")
    }

    func testTimelineCheckGatesSlot() throws {
        let dir = TimelineStore.dir(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        let now = Date()
        let e = TimelineEntry(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800), conversationId: "conv-ow-1",
                              title: "T", text: "- 聊了一件事", pending: "", day: MemoryDay.key(now.addingTimeInterval(-3600)), lastNodeId: "n1")
        try TimelineStore.seedLegacy(e, in: dir)
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        UserDefaults.standard.removeObject(forKey: MemoryOpenWindow.a4Key)
        XCTAssertTrue(CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid)).units.contains { $0.key.hasSuffix("|conv-ow-1") })
        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.a4Key)
        XCTAssertTrue(CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid)).units.isEmpty, "A4 不勾 = 不带")
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.a4Key)
        XCTAssertTrue(CalendarInjection.timelineSlot(profileId: pid, now: now, participation: .testValue(profileId: pid)).units.contains { $0.key.hasSuffix("|conv-ow-1") }, "A4 不写了，已经写下的照样带")
    }

    // MARK: - ⑤-1 P2-b 来源窗过滤（R-1）

    /// X 碎片按来源窗挡：已删 / 关参与窗的碎片不带；来源窗不存在（隐藏集语义）和没有来源的照带
    @MainActor
    func testHiddenSourceWindowsDropOnlyTheirFragments() throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        func window(_ id: String, enabled: Bool = true, trashed: Bool = false) {
            let c = Conversation(id: id, title: "窗口\(id)", createTime: Date(timeIntervalSince1970: 1),
                                 updateTime: Date(timeIntervalSince1970: 1), currentNodeId: "", provider: "api", profileId: pid)
            c.memoryEnabled = enabled
            c.isTrashed = trashed
            context.insert(c)
        }
        window("conv-open")
        window("conv-off", enabled: false)
        window("conv-trash", trashed: true)
        try context.save()
        let store = SwiftDataMemoryStore()
        for (text, source) in [("开着的窗的碎片", "conv-open"), ("关参与窗的碎片", "conv-off"),
                               ("回收站窗的碎片", "conv-trash"), ("来源窗没了的碎片", "conv-gone"),
                               ("没有来源的碎片", nil)] {
            let m = try store.add(content: text, category: "event", keywords: [], profileId: pid, isUserExplicit: false,
                                  extractedBy: "t", sourceConversationId: source, context: context)
            m.occurredDay = "2026-11-01"
            m.reviewedAt = Date()
        }
        // 钉住豁免（plan-memory-participation §2.2）：她亲手钉的是更晚、更强的意愿，来源窗隐藏也照带
        let pinned = try store.add(content: "隐藏窗里钉住的碎片", category: "fact", keywords: [], profileId: pid,
                                   isUserExplicit: true, extractedBy: "t", sourceConversationId: "conv-off", context: context)
        pinned.occurredDay = "2026-11-01"
        try context.save()
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        let hidden = EffectiveMemoryParticipation.hiddenSources(profileId: pid, context: context)
        XCTAssertEqual(hidden, ["conv-off", "conv-trash"])
        let inputs = MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid),
                                                store: store, context: context, useCachedWiki: false,
                                                hiddenSources: hidden)
        XCTAssertEqual(Set(inputs.memories.map(\.content)),
                       ["开着的窗的碎片", "来源窗没了的碎片", "没有来源的碎片", "隐藏窗里钉住的碎片"],
                       "只有已删 / 关参与窗的碎片被挡；钉住的照带")
        XCTAssertEqual(inputs.hiddenSources, hidden)
        XCTAssertEqual(MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid),
                                                  store: store, context: context, useCachedWiki: false).memories.count, 6,
                       "不传隐藏集（默认空）= 不过滤")
    }

    /// P2-a：被来源窗挡掉的碎片条数在同一趟 roundInputs filter 里数；钉住豁免、勾关 / 参与关不数
    @MainActor
    func testRoundInputsCountsHiddenFragmentsNotPinned() throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        func window(_ id: String, enabled: Bool = true, trashed: Bool = false) {
            let c = Conversation(id: id, title: "窗口\(id)", createTime: Date(timeIntervalSince1970: 1),
                                 updateTime: Date(timeIntervalSince1970: 1), currentNodeId: "", provider: "api", profileId: pid)
            c.memoryEnabled = enabled
            c.isTrashed = trashed
            context.insert(c)
        }
        window("p2-open")
        window("p2-off", enabled: false)
        window("p2-trash", trashed: true)
        let store = SwiftDataMemoryStore()
        for (text, source) in [("开着的窗的碎片", "p2-open"), ("关参与窗的碎片", "p2-off"),
                               ("回收站窗的碎片", "p2-trash"), ("来源窗没了的碎片", "p2-gone")] {
            let m = try store.add(content: text, category: "event", keywords: [], profileId: pid, isUserExplicit: false,
                                  extractedBy: "t", sourceConversationId: source, context: context)
            m.occurredDay = "2026-11-01"
            m.reviewedAt = Date()
        }
        let pinned = try store.add(content: "隐藏窗里钉住的碎片", category: "fact", keywords: [], profileId: pid,
                                   isUserExplicit: true, extractedBy: "t", sourceConversationId: "p2-off", context: context)
        pinned.occurredDay = "2026-11-01"
        try context.save()
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        let hidden = EffectiveMemoryParticipation.hiddenSources(profileId: pid, context: context)

        let inputs = MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid),
                                                store: store, context: context, useCachedWiki: false,
                                                hiddenSources: hidden)
        XCTAssertEqual(inputs.hiddenFragmentCount, 2, "关参与窗 + 回收站窗各一条；钉住的豁免、来源窗没了的照带")
        XCTAssertEqual(inputs.memories.count, 3)
        XCTAssertEqual(MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid),
                                                  store: store, context: context, useCachedWiki: false).hiddenFragmentCount, 0,
                       "不传隐藏集 = 不过滤 = 不数")
        XCTAssertEqual(MemoryInjector.roundInputs(profileId: pid, participation: .testValue(profileId: pid, window: false),
                                                  store: store, context: context, useCachedWiki: false,
                                                  hiddenSources: hidden).hiddenFragmentCount, 0,
                       "本窗关参与：碎片候选都不列，不数")
    }

    /// 时间轴行和待续也按来源窗挡；一天一条的主调行不按窗挡
    func testTimelineSlotDropsHiddenWindowRowsAndPending() throws {
        let now = Date()
        let day = MemoryDay.key(now)
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        try? FileManager.default.removeItem(at: root)
        PendingStore.forget(profileId: pid)
        defer {
            PendingStore.forget(profileId: pid)
            UserDefaults.standard.removeObject(forKey: PendingStore.migratedKey(profileId: pid))
        }
        let kept = TimelineDayRecord.Item(kind: .segment, conversationId: "conv-kept", window: "开着的窗",
                                          title: "排了展位", start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600),
                                          from: "a", to: "b", continued: false)
        let hidden = TimelineDayRecord.Item(kind: .segment, conversationId: "conv-off", window: "关参与窗",
                                            title: "收了展位", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800),
                                            from: "c", to: "d", continued: false)
        try TimelineStore.save(.init(days: [TimelineDayRecord(date: day, headline: "今天的主调", topics: [],
                                                              items: [kept, hidden], source: "t")], entries: []),
                               month: String(day.prefix(7)), in: TimelineStore.dir(root: root))
        try PendingStore.add(["把展位清单写完"], conversationId: "conv-kept", day: day, anchor: nil, profileId: pid,
                             floorMemoryRoot: root)
        try PendingStore.add(["给关闭的那扇窗收尾"], conversationId: "conv-off", day: day, anchor: nil, profileId: pid,
                             floorMemoryRoot: root)
        XCTAssertNotNil(PendingStore.openByConversationCached(profileId: pid, floorMemoryRoot: root)?["conv-off"],
                        "前置：两条待续都在缓存里")
        let text = try XCTUnwrap(CalendarInjection.timelineSlot(profileId: pid, now: now,
                                                                participation: .testValue(profileId: pid),
                                                                hiddenSources: ["conv-off"]).timeline)
        XCTAssertTrue(text.contains("把展位清单写完"))
        XCTAssertFalse(text.contains("给关闭的那扇窗收尾"), "关参与窗的待续不带")
        XCTAssertTrue(text.contains("开着的窗"))
        XCTAssertFalse(text.contains("关参与窗"), "关参与窗的时间轴项不带")
        XCTAssertTrue(text.contains("今天的主调"), "主调行整天聚合，不按窗挡")
    }
}
