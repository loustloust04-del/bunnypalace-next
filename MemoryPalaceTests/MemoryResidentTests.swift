import MemoryCore
import XCTest
import SwiftData
import Observation
@testable import 记忆花园

/// 常驻记忆（plan-memory-audit-desk 第八½节）：规则取自实发的检索器、原因文字、这一轮带没带的灰字
final class MemoryResidentTests: XCTestCase {

    private let pid = "xctest-memory-resident"
    private let keys = ["mem_inject_keyword", "mem_inject_full", "mem_inject_vector", "mem_master",
                        MemoryOpenWindow.cKey, MemoryOpenWindow.b4Key, "mem_self_recent_count", "mem_inject_budget",
                        "mem_inject_catalog", "mem_content_convhistory", RecallTuningStore.storageKey, MemoryOpenWindowStore.storageKey]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }   // 默认：全量开、关键词 / 按意思找关
        RecallTuningStore.save(RecallTestTuning.make(), profileId: pid)
    }

    override func tearDown() {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        super.tearDown()
    }

    private func mem(_ content: String, category: String = "fact", pinned: Bool = false) -> Memory {
        Memory(content: content, category: category, profileId: pid, isUserExplicit: pinned)
    }

    private func selfMem(_ name: String, importance: Int = 3) -> SelfMemory {
        SelfMemory(slug: SelfMemoryStore.slugify(name), name: name, description: "关于\(name)", type: "user",
                   importance: importance, origin: "self", created: Date(), source: nil, superseded: nil, body: "正文")
    }

    // MARK: - 规则

    func testDefaultModeOnlyPinned() throws {
        let rule = try XCTUnwrap(MemoryResident.archiveRule())
        XCTAssertTrue(rule(mem("钉住的事实", pinned: true)))
        XCTAssertFalse(rule(mem("关系", category: "relationship")), "默认全量模式：关系不进常驻层（它在全量兜底里）")
        XCTAssertFalse(rule(mem("偏好", category: "preference")))
        XCTAssertFalse(rule(mem("事实")))
    }

    /// C3 ② 起按类别常驻停掉：开了关键词 / 按意思找也只有钉住的
    func testKeywordOrVectorStillOnlyPinned() throws {
        UserDefaults.standard.set(true, forKey: "mem_inject_keyword")
        let rule = try XCTUnwrap(MemoryResident.archiveRule())
        XCTAssertTrue(rule(mem("钉住", pinned: true)))
        XCTAssertFalse(rule(mem("关系", category: "relationship")))
        XCTAssertFalse(rule(mem("偏好", category: "preference")))
        XCTAssertFalse(rule(mem("事实")))
        UserDefaults.standard.set(false, forKey: "mem_inject_keyword")
        UserDefaults.standard.set(true, forKey: "mem_inject_vector")
        XCTAssertFalse(try XCTUnwrap(MemoryResident.archiveRule())(mem("关系", category: "relationship")), "按意思找同样")
    }

    func testAllRetrievalOffNothingResident() {
        UserDefaults.standard.set(false, forKey: "mem_inject_full")
        XCTAssertNil(MemoryResident.archiveRule(), "三个都关：一条都不带")
    }

    func testUnpinLeavesResident() throws {
        let rule = try XCTUnwrap(MemoryResident.archiveRule())
        let m = mem("钉住的", pinned: true)
        XCTAssertTrue(rule(m))
        MemoryPinPlan.apply([m])
        XCTAssertFalse(m.isUserExplicit)
        XCTAssertFalse(rule(m), "取消钉住后不再算常驻")
    }

    // MARK: - 原因

    func testReasonTexts() {
        XCTAssertEqual(MemoryResident.reason(mem("x", category: "relationship", pinned: true)), "你钉的")
        XCTAssertEqual(MemoryResident.reason(mem("x", category: "relationship")), "标成关系")
        XCTAssertEqual(MemoryResident.reason(mem("x", category: "preference")), "标成偏好")
        XCTAssertEqual(MemoryResident.reason(.five, assistant: "阿白"), "阿白的记忆 · 重要度 5")
        XCTAssertEqual(MemoryResident.reason(.recent, assistant: "阿白", recentCount: 3), "阿白的记忆 · 最近 3 条")
        UserDefaults.standard.set(7, forKey: "mem_self_recent_count")
        XCTAssertEqual(MemoryResident.reason(.recent, assistant: "阿白"), "阿白的记忆 · 最近 7 条", "N 跟着设置变")
    }

    // MARK: - 灰字

    func testGates() {
        let a = mem("钉住的", pinned: true), b = mem("也钉住", pinned: true)
        let five = selfMem("five", importance: 5), recent = selfMem("recent")
        let cands: [(memory: SelfMemory, reason: SelfMemoryInjection.Reason)] = [(five, .five), (recent, .recent)]
        func run(memoryOn: Bool = true, cChecked: Bool = true, injected: Set<UUID>, full: Set<String>?) -> MemoryResident.Summary {
            MemoryResident.compute(archive: [a, b], injectedIds: injected, selfCandidates: cands, fullSlugs: full,
                                   memoryOn: memoryOn, cChecked: cChecked, assistant: "阿白", recentCount: 5)
        }

        let ok = run(injected: [a.id, b.id], full: [five.slug, recent.slug])
        XCTAssertEqual(ok.archive.map(\.gate), [nil, nil], "带着的不写灰字")
        XCTAssertEqual(ok.selfRows.map(\.gate), [nil, nil])
        XCTAssertEqual(ok.selfRows.map(\.reason), ["阿白的记忆 · 重要度 5", "阿白的记忆 · 最近 5 条"])
        XCTAssertEqual(ok.count, 4)
        XCTAssertEqual(ok.grayCount, 0)

        let budget = run(injected: [a.id], full: [five.slug])
        XCTAssertEqual(budget.archive.map(\.gate), [nil, .overBudget])
        XCTAssertEqual(budget.selfRows.map(\.gate), [nil, .overBudget])
        XCTAssertEqual(budget.grayCount, 2)

        let cOff = run(cChecked: false, injected: [], full: [five.slug, recent.slug])
        XCTAssertEqual(cOff.archive.map(\.gate), [.archiveUnchecked, .archiveUnchecked])
        XCTAssertEqual(cOff.selfRows.map(\.gate), [nil, nil], "C 没勾不影响 B4")

        let b4Off = run(injected: [a.id, b.id], full: nil)
        XCTAssertEqual(b4Off.selfRows.map(\.gate), [.selfUnchecked, .selfUnchecked])

        let off = run(memoryOn: false, cChecked: false, injected: [], full: nil)
        XCTAssertEqual(off.archive.map(\.gate), [.memoryOff, .memoryOff], "记忆关着优先说这个")
        XCTAssertEqual(off.selfRows.map(\.gate), [.memoryOff, .memoryOff])

        XCTAssertEqual(MemoryResident.Gate.memoryOff.text, "记忆关着，现在不带")
        XCTAssertEqual(MemoryResident.Gate.archiveUnchecked.text, "C 没勾，现在不带")
        XCTAssertEqual(MemoryResident.Gate.selfUnchecked.text, "B4 没勾，现在不带")
        XCTAssertEqual(MemoryResident.Gate.overBudget.text, "超出注入预算，这一轮没带")
    }

    /// ⧫7：下半第二段标题按实际——只开全量注入时第二段也每一轮都带
    func testVolatileTitleFollowsRetrievers() {
        XCTAssertEqual(InjectionPreviewSections.volatileTitle(), "全量注入开着：预算内都带", "默认全量模式")
        UserDefaults.standard.set(true, forKey: "mem_inject_keyword")
        XCTAssertEqual(InjectionPreviewSections.volatileTitle(), "聊到相关话题才会想起的")
        UserDefaults.standard.set(false, forKey: "mem_inject_keyword")
        UserDefaults.standard.set(true, forKey: "mem_inject_vector")
        XCTAssertEqual(InjectionPreviewSections.volatileTitle(), "聊到相关话题才会想起的", "按意思找同样")
    }

    // MARK: - 走实发那几个函数

    @MainActor
    func testLoadUsesRealRoundInputs() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = SwiftDataMemoryStore()
        let pinned = try store.add(content: "钉住的一条", category: "fact", keywords: [], profileId: pid, isUserExplicit: true,
                                   extractedBy: "t", sourceConversationId: nil, context: context)
        let relation = try store.add(content: "关系条", category: "relationship", keywords: [], profileId: pid, isUserExplicit: false,
                                     extractedBy: "t", sourceConversationId: nil, context: context)
        relation.occurredDay = "2026-10-10"   // 碎片池里点过「留下」的才带（C3 ②）
        relation.reviewedAt = Date()
        try context.save()
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "阿青", assistantName: "阿白")

        func load(_ convOn: Bool) -> MemoryResident.Snapshot {
            MemoryResident.Snapshot(MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid, window: convOn),
                                                           container: container),
                                    memories: store.listAll(profileId: pid, context: context))
        }
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        let on = load(true)
        XCTAssertEqual(on.archive.map(\.memory.id), [pinned.id], "默认全量模式：只有钉住的算常驻")
        XCTAssertEqual(on.archive.first?.gate, nil)
        XCTAssertEqual(on.fullFallbackCount, 1, "关系条在全量兜底里，每一轮也带")
        XCTAssertTrue(on.stable.contains("[关于阿青]") && on.stable.contains("钉住的一条"))
        XCTAssertEqual(on.memoryCount, 2, "下半「共 N 条」：这一轮带的两条档案")

        UserDefaults.standard.removeObject(forKey: MemoryOpenWindow.cKey)
        let cOff = load(true)
        XCTAssertEqual(cOff.archive.map(\.memory.id), [pinned.id], "C 没勾：照样列")
        XCTAssertEqual(cOff.archive.first?.gate, .archiveUnchecked)
        XCTAssertEqual(cOff.fullFallbackCount, 0)

        let convOff = load(false)
        XCTAssertEqual(convOff.archive.first?.gate, .memoryOff)
    }

    /// ⑤-1 P2-b r2（kimi 必修 1）：检查器灰显兜底的 `listActive` 也过来源窗过滤——
    /// C 不勾时隐藏来源（已删 / 关参与窗）的碎片不列，钉住的照列（钉住豁免）；上下半预览都不带它
    @MainActor
    func testSummaryFallbackDropsHiddenSourceFragments() throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let window = Conversation(id: "resident-hidden-source", title: "隐藏窗", createTime: Date(timeIntervalSince1970: 1),
                                  updateTime: Date(timeIntervalSince1970: 1), currentNodeId: "", provider: "api", profileId: pid)
        window.memoryEnabled = false
        context.insert(window)
        let store = SwiftDataMemoryStore()
        let hidden = try store.add(content: "隐藏来源的碎片", category: "fact", keywords: [], profileId: pid,
                                   isUserExplicit: false, extractedBy: "t", sourceConversationId: window.id, context: context)
        hidden.occurredDay = "2026-10-10"
        hidden.reviewedAt = Date()
        let pinned = try store.add(content: "隐藏来源的钉住", category: "fact", keywords: [], profileId: pid,
                                   isUserExplicit: true, extractedBy: "t", sourceConversationId: window.id, context: context)
        try context.save()
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "阿青", assistantName: "阿白")
        UserDefaults.standard.removeObject(forKey: MemoryOpenWindow.cKey)
        MainThreadIO.allowMainThreadInThisTest()
        let s = MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid), container: container,
                                       selfMemories: [])
        XCTAssertEqual(s.archive.map(\.id), [pinned.id], "C 不勾：隐藏来源碎片不列，钉住的照列")
        XCTAssertEqual(s.archive.first?.gate, .archiveUnchecked)

        // C 勾着 = 真走 roundInputs：隐藏来源碎片不注，钉住的进 stable
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        let on = MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid), container: container,
                                        selfMemories: [])
        XCTAssertEqual(on.archive.map(\.id), [pinned.id])
        XCTAssertFalse(on.stable.contains("隐藏来源的碎片"))
        XCTAssertFalse(on.volatile.contains("隐藏来源的碎片"))
        XCTAssertTrue(on.stable.contains("隐藏来源的钉住"), "钉住的照带")
    }

    // MARK: - 10-16 astra 返修

    /// #2：开关键词检索后偏好挪去常驻页，普通列表不再列它，选择裁掉它、批量删碰不到
    func testRuleChangeClipsHiddenSelection() throws {
        let pinned = mem("钉住", pinned: true), pref = mem("偏好", category: "preference"), fact = mem("事实")
        let active = [pinned, pref, fact]
        func visible() -> Set<MemoryRowID> {
            Set(MemoryResident.panelListed(active, searching: false, rule: MemoryResident.archiveRule()).map { .archive($0.id) })
        }
        let selection: Set<MemoryRowID> = [.archive(pref.id), .archive(fact.id), .assistant("s")]
        XCTAssertEqual(MemoryRowID.clip(selection, to: visible().union([.assistant("s")])), selection, "默认：偏好在普通列表里")
        UserDefaults.standard.set(true, forKey: "mem_inject_keyword")
        XCTAssertEqual(MemoryRowID.clip(selection, to: visible().union([.assistant("s")])), selection,
                       "C3 ② 起开关键词检索偏好也不挪去常驻页")
        XCTAssertFalse(visible().contains(.archive(pinned.id)), "钉住的在常驻页")
        XCTAssertEqual(MemoryResident.panelListed(active, searching: true, rule: MemoryResident.archiveRule()).count, 3, "搜索时照旧全列")
    }

    /// #3：只收最新一次刷新；主线程复核掉后台算完后被删 / 取消钉住 / 彻底删的
    func testLoadTicketOnlyLatestAndRevalidate() {
        var t = MemoryResident.LoadTicket()
        let old = t.next(), new = t.next()
        XCTAssertFalse(t.isLatest(old), "旧结果晚到也不收")
        XCTAssertTrue(t.isLatest(new))

        let a = mem("a", pinned: true), b = mem("b", pinned: true), c = mem("c", pinned: true)
        let s = MemoryResident.compute(archive: [a, b, c], injectedIds: [a.id, b.id, c.id], selfCandidates: [], fullSlugs: nil,
                                       memoryOn: true, cChecked: true, assistant: "阿白", recentCount: 5)
        b.supersededAt = Date()
        MemoryPinPlan.apply([c])   // 取消钉住
        let checked = s.revalidated([a, b, c])
        XCTAssertEqual(checked.archive.map(\.id), [a.id])
        XCTAssertEqual(s.revalidated([b, c]).archive.map(\.id), [], "彻底删了（主线程找不到）也不列")
        let snap = MemoryResident.Snapshot(s, memories: [a, b, c])
        XCTAssertEqual(snap.archive.map(\.id), [a.id])
        XCTAssertEqual(snap.dropped, 2, "掉了行 = 下半预览也旧了，调用方再算一次")
    }

    /// #6：当前预设没开记忆插槽 → 全部灰字「预设没开记忆插槽」，下半预览空；记忆关着仍优先说那个
    func testSlotOffGatesAndEmptyPreview() throws {
        var preset = Preset.balanced
        XCTAssertTrue(MemoryResident.memorySlotOn(preset))
        let idx = try XCTUnwrap(preset.prompts.firstIndex { $0.id == PromptSlot.memoryInjectionId })
        preset.prompts[idx].isEnabled = false
        XCTAssertFalse(MemoryResident.memorySlotOn(preset), "插槽关了")
        preset.prompts[idx].isEnabled = true
        preset.prompts[idx].isMarker = false
        XCTAssertFalse(MemoryResident.memorySlotOn(preset), "改成普通插槽：组装不填记忆")

        let a = mem("钉住的", pinned: true)
        let five = selfMem("five", importance: 5)
        let off = MemoryResident.compute(archive: [a], injectedIds: [a.id], selfCandidates: [(five, .five)], fullSlugs: [five.slug],
                                         memoryOn: true, cChecked: true, assistant: "阿白", recentCount: 5, slotOn: false)
        XCTAssertEqual(off.archive.map(\.gate), [.slotOff])
        XCTAssertEqual(off.selfRows.map(\.gate), [.slotOff])
        XCTAssertEqual(MemoryResident.Gate.slotOff.text, "预设没开记忆插槽，现在不带")
        let both = MemoryResident.compute(archive: [a], injectedIds: [], selfCandidates: [], fullSlugs: nil,
                                          memoryOn: false, cChecked: true, assistant: "阿白", recentCount: 5, slotOn: false)
        XCTAssertEqual(both.archive.map(\.gate), [.memoryOff])
    }

    /// #6：插槽关 → 下半预览、共 N 条、全量兜底都空；工具尾注照实发过 droppingOffToolMentions
    @MainActor
    func testSummarySlotOffAndToolMentions() throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = SwiftDataMemoryStore()
        _ = try store.add(content: "钉住的一条", category: "fact", keywords: [], profileId: pid, isUserExplicit: true,
                          extractedBy: "t", sourceConversationId: nil, context: context)
        let fact = try store.add(content: "普通事实", category: "fact", keywords: [], profileId: pid, isUserExplicit: false,
                                 extractedBy: "t", sourceConversationId: nil, context: context)
        fact.occurredDay = "2026-10-10"   // 碎片池里点过「留下」的才带（C3 ②）
        fact.reviewedAt = Date()
        try context.save()
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "阿青", assistantName: "阿白")
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        MainThreadIO.allowMainThreadInThisTest()

        let slotOff = MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid, slot: false),
                                             container: container, selfMemories: [])
        XCTAssertEqual(slotOff.archive.map(\.gate), [.slotOff])
        XCTAssertEqual(slotOff.stable, "")
        XCTAssertEqual(slotOff.volatile, "")
        XCTAssertEqual(slotOff.memoryCount, 0)
        XCTAssertEqual(slotOff.fullFallbackCount, 0)

        UserDefaults.standard.set(true, forKey: "mem_inject_catalog")
        UserDefaults.standard.set(true, forKey: "mem_content_convhistory")
        let raw = MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid), container: container, selfMemories: [])
        XCTAssertTrue(raw.volatile.contains(MemoryInjector.recallCatalogHint), "不知道工具：尾注原样")
        let noRecall = MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid), container: container,
                                              selfMemories: [], availableTools: [])
        XCTAssertFalse(noRecall.volatile.contains(MemoryInjector.recallCatalogHint), "这一轮没有 recall：同实发去掉那句")
        let withRecall = MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid), container: container,
                                                selfMemories: [], availableTools: [RecallTool.toolName])
        XCTAssertEqual(withRecall.volatile, raw.volatile)
    }

    /// #7：注入设置快照，任一键变了就不一样
    func testSettingsStampChangesWithInjectionKeys() {
        let before = MemoryResident.settingsStamp()
        for key in MemoryResident.settingsKeys {
            let old = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.set(12345, forKey: key)
            XCTAssertNotEqual(MemoryResident.settingsStamp(), before, key)
            if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        XCTAssertEqual(MemoryResident.settingsStamp(), before)
    }

    // MARK: - C3 ② A6 / A7

    @MainActor
    func testWikiWindowTracksFourthMessageRevisionAndBranchIdentity() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-window-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root)
        for title in ["旧词", "新词"] {
            try wiki.save(WikiPage(path: "主题/\(title)", kind: .topic, triggers: [], hook: "提到时", title: title, now: "当前正文。"))
        }
        try wiki.rebuildAllIndexes()
        try await WikiInjectionCache.shared.warm(root.path) { wiki }
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.b4Key)
        MainThreadIO.allowMainThreadInThisTest()

        func node(_ id: String, _ role: String, _ content: String) -> MessageNode {
            MessageNode(id: id, role: role, content: content, contentType: "text", createTime: nil,
                        parentId: nil, childrenIds: [], conversationId: "resident-window", profileId: pid)
        }
        let real = [node("m1", "user", "窗口外"), node("m2", "user", "旧词"),
                    node("m3", "assistant", "<think>不扫描的思考</think>收到"),
                    node("m4", "user", "继续"), node("m5", "assistant", "好呀")]
        let synthetic = node("synthetic", "user", "新词")
        synthetic.isSyntheticRoot = true
        let hidden = node("hidden", "user", "新词")
        hidden.sourceVisibility = "hidden"
        let ignored = [synthetic, hidden, node("tool", "tool", "新词"), node("system", "system", "新词")]
        (real + ignored).forEach { context.insert($0) }
        try context.save()
        let vm = ConversationViewModel()
        vm.currentPath = real + ignored
        let before = vm.wikiScanWindow()
        let beforeKey = MemoryResident.wikiRevisions(in: vm.currentPath.map { ConversationMessage(scalar: $0) })
        XCTAssertEqual(before.map(\.id), ["m2", "m3", "m4", "m5"])
        XCTAssertEqual(before.map(\.content), ["旧词", "收到", "继续", "好呀"])
        let profile = Profile(id: pid, name: "T", emoji: "", description: "", userName: "阿青", assistantName: "阿白")
        func summary(_ window: [ConversationViewModel.WikiScanMessage]) -> MemoryResident.Summary {
            MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid), container: container, selfMemories: [],
                                   recentNodeIds: window.map(\.id), wikiStore: wiki)
        }
        XCTAssertEqual(summary(before).wiki?.hits.map(\.page.title), ["旧词"])
        real[0].content = "窗口外修改"
        hidden.content = "隐藏内容修改"
        XCTAssertEqual(vm.wikiScanWindow(), before, "窗口外 / 隐藏消息不导致本轮扫描变化")
        XCTAssertEqual(MemoryResident.wikiRevisions(in: vm.currentPath.map { ConversationMessage(scalar: $0) }), beforeKey)

        var ticket = MemoryResident.LoadTicket()
        let old = ticket.next()
        real[1].content = "新词"
        real[1].cardEditedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try context.save()
        let revised = vm.wikiScanWindow()
        XCTAssertEqual(revised.map(\.id), before.map(\.id), "原节点同长度编辑")
        XCTAssertNotEqual(revised, before)
        XCTAssertNotEqual(MemoryResident.wikiRevisions(in: vm.currentPath.map { ConversationMessage(scalar: $0) }), beforeKey, "同长度修订用现有编辑时间标量刷新")
        XCTAssertEqual(summary(revised).wiki?.hits.map(\.page.title), ["新词"], "第四条的内容修订立刻改变命中")
        let background = await MemoryResident.loadSummary(profile: profile, participation: .testValue(profileId: pid),
                                                          container: container,
                                                          selfMemories: [], recentNodeIds: revised.map(\.id), wikiStore: wiki)
        XCTAssertEqual(background.wiki?.hits.map(\.page.title), ["新词"], "后台独立 context 读取已保存修订，不传主 context 模型")
        let latest = ticket.next()
        XCTAssertFalse(ticket.isLatest(old))
        XCTAssertTrue(ticket.isLatest(latest))

        let sibling = node("m5-sibling", "assistant", real[4].content)
        context.insert(sibling)
        try context.save()
        vm.currentPath = Array(real.prefix(4)) + [sibling] + ignored
        let branch = vm.wikiScanWindow()
        XCTAssertEqual(branch.map(\.content), revised.map(\.content))
        XCTAssertNotEqual(branch, revised, "同文兄弟分支也靠 id 刷新")
        XCTAssertNotEqual(MemoryResident.wikiRevisions(in: vm.currentPath.map { ConversationMessage(scalar: $0) }).map(\.id), revised.map(\.id))
        XCTAssertEqual(vm.wikiScanWindow(excluding: sibling.id).map(\.id), ["m1", "m2", "m3", "m4"])
    }

    @MainActor
    func testWikiScanExcludesThinkingAcrossStoredRepresentations() throws {
        let user = MessageNode(id: "scan-user", role: "user", content: "<think>用户词</think>", contentType: "text",
                               createTime: nil, parentId: nil, childrenIds: [], conversationId: "scan")
        let assistant = MessageNode(id: "scan-assistant", role: "assistant", content: "", contentType: "text",
                                    createTime: nil, parentId: nil, childrenIds: [], conversationId: "scan")
        assistant.ccThinking = "隐藏词"
        let imported: [MessageSegment] = [.thinking(text: "隐藏词", signature: "sig"), .text("正文词")]
        let thinkingOnly: [MessageSegment] = [.thinking(text: "隐藏词", signature: nil),
                                              .thinking(text: "", signature: nil, redactedData: "隐藏词")]
        let cases: [(String, [MessageSegment]?, String)] = [
            ("<think>隐藏词</think>正文词", nil, "正文词"),
            (" \n<THINKING>隐藏词</THINKING>正文词", nil, "正文词"),
            ("[ThInKiNg]隐藏词[/ThInKiNg]正文词", nil, "正文词"),
            ("正文词[thinking]未闭合", nil, "正文词[thinking]未闭合"),
            ("正文词<thinking>未闭合", nil, "正文词<thinking>未闭合"),
            ("<think>未闭合正文词", nil, ""),
            ("<thinking>未闭合正文词", nil, ""),
            ("[thinking]未闭合正文词", nil, ""),
            ("<think>隐藏词</think>", nil, ""),
            ("过时副本", [.text("正文词"), .thinking(text: "隐藏词", signature: "sig")], "正文词"),
            (ClaudeImporter.flattenSegmentsForSearch(imported), imported, "正文词"),
            (ClaudeImporter.flattenSegmentsForSearch(thinkingOnly), thinkingOnly, ""),
        ]
        let wiki = WikiInjectionSnapshot(pages: ["用户词", "正文词", "隐藏词"].map {
            .init(path: "楼层/\($0)", title: $0, triggers: [], hook: "", now: "")
        })
        let vm = ConversationViewModel()
        vm.currentPath = [user, assistant]
        for (raw, segments, body) in cases {
            assistant.content = raw
            assistant.segmentsData = try segments.map { try JSONEncoder().encode($0) }
            let window = vm.wikiScanWindow()
            XCTAssertEqual(window.map(\.content), [user.content, body], raw)
            let hits = WikiInjection.hits(wiki, recent: window.map(\.content), excluding: [])
            XCTAssertEqual(hits.map(\.page.title), body.isEmpty ? ["用户词"] : ["正文词", "用户词"], raw)
        }
    }

    @MainActor
    func testWikiScanKeepsLiteralTagsAndFollowingTrigger() throws {
        let node = MessageNode(id: "literal", role: "assistant", content: "", contentType: "text",
                               createTime: nil, parentId: nil, childrenIds: [], conversationId: "literal")
        let vm = ConversationViewModel()
        vm.currentPath = [node]
        let wiki = WikiInjectionSnapshot(pages: [.init(path: "主题/正文词", title: "正文词", triggers: [], hook: "", now: "")])
        let literals = [
            "正文中间 <think>标签示例</think> 后面正文词",
            "行内 `<thinking>标签示例</thinking>` 后面正文词",
            "```xml\n<think>标签示例</think>\n```\n后面正文词",
            "~~~xml\n[thinking]标签示例[/thinking]\n~~~\n后面正文词",
            "行内 `[thinking]标签示例[/thinking]` 后面正文词",
            "正文[thinking]未闭合，后面正文词"
        ]
        for literal in literals {
            for structured in [false, true] {
                node.content = literal
                node.segmentsData = structured ? try JSONEncoder().encode([
                    MessageSegment.thinking(text: "不扫描", signature: nil), .text(literal)
                ]) : nil
                let content = vm.wikiScanWindow().map(\.content)
                XCTAssertEqual(content, [literal], "正文标签不是思考块：\(literal)")
                XCTAssertEqual(WikiInjection.hits(wiki, recent: content, excluding: []).map(\.page.title), ["正文词"])
            }
        }
        node.content = "过时副本"
        node.segmentsData = try JSONEncoder().encode([MessageSegment.text("<think>这是正文</think>正文词")])
        XCTAssertEqual(vm.wikiScanWindow().map(\.content), ["<think>这是正文</think>正文词"], "结构化 text 即正文，不再做标签清洗")
    }

    @MainActor
    func testWikiScanKeepsAttachmentCaptionsWithoutTextSegments() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let attachment = try PendingChatAttachment.image(name: "附件词", typeDescription: "图片", mimeType: "image/png", data: Data())
        let parts = ChatAttachmentPromptBuilder.userMessage(displayBase: "相机说明词", attachments: [attachment])
        let representations = try [
            JSONEncoder().encode(XCTUnwrap(parts.segments)),
            JSONEncoder().encode([MessageSegment.imageRef(name: "附件词", type: "image/png", path: "never-read.png")])
        ]
        let wiki = WikiInjectionSnapshot(pages: ["相机说明词", "附件词"].map {
            .init(path: "楼层/\($0)", title: $0, triggers: [], hook: "", now: "")
        })
        let vm = ConversationViewModel()
        for role in ["user", "assistant"] {
            for (index, segmentsData) in representations.enumerated() {
                let id = "caption-\(role)-\(index)"
                let node = MessageNode(id: id, role: role, content: parts.displayText, contentType: parts.contentType,
                                       createTime: nil, parentId: nil, childrenIds: [], conversationId: "caption")
                node.segmentsData = segmentsData
                context.insert(node)
                try context.save()
                vm.currentPath = [node]
                XCTAssertEqual(vm.wikiScanWindow().map(\.content), ["相机说明词"], "附件无 text 段时仍保留真实 caption")
                let background = await Task.detached {
                    MemoryResident.wikiMessages(nodeIds: [id], profileId: "",
                                                source: SwiftDataConversationSource(container: container))
                }.value
                XCTAssertEqual(background, ["相机说明词"])
                XCTAssertEqual(WikiInjection.hits(wiki, recent: background, excluding: []).map(\.page.title), ["相机说明词"],
                               "caption 触发，附件名和附件内容不触发")
            }
        }
    }

    @MainActor
    func testWikiWindowCountsEmptyBodiesBeforeExtraction() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let nodes = (1...5).map { index in
            MessageNode(id: "five-\(index)", role: index.isMultiple(of: 2) ? "assistant" : "user",
                        content: index == 1 ? "窗口外词" : "正文\(index)", contentType: "text",
                        createTime: Date(timeIntervalSince1970: Double(6 - index)), parentId: nil, childrenIds: [],
                        conversationId: "five")
        }
        nodes[1].segmentsData = try JSONEncoder().encode([MessageSegment.thinking(text: "窗口外词", signature: nil)])
        nodes[2].content = ""
        nodes[2].segmentsData = try JSONEncoder().encode([MessageSegment.image(name: "photo", type: "image/png", data: Data())])
        nodes.forEach { context.insert($0) }
        try context.save()
        let vm = ConversationViewModel()
        vm.currentPath = nodes
        let revisions = MemoryResident.wikiRevisions(in: nodes.map { ConversationMessage(scalar: $0) })
        XCTAssertEqual(revisions.map(\.id), ["five-2", "five-3", "five-4", "five-5"])
        XCTAssertEqual(vm.wikiScanWindow().map(\.content), ["", "", "正文4", "正文5"])
        let ids = revisions.map(\.id)
        let background = await Task.detached {
            MemoryResident.wikiMessages(nodeIds: ids, profileId: "",
                                        source: SwiftDataConversationSource(container: container))
        }.value
        XCTAssertEqual(background, ["", "", "正文4", "正文5"], "按传入 id 顺序，不按创建时间；空正文占格，不补第五条")
        let wiki = WikiInjectionSnapshot(pages: [.init(path: "主题/窗口外词", title: "窗口外词", triggers: [], hook: "", now: "")])
        XCTAssertTrue(WikiInjection.hits(wiki, recent: background, excluding: []).isEmpty)
    }

    @MainActor
    func testWikiRefreshRevisionsDoNotObserveExternalSegments() throws {
        let node = MessageNode(id: "revision", role: "assistant", content: "正文", contentType: "text",
                               createTime: nil, parentId: nil, childrenIds: [], conversationId: "revision")
        node.segmentsData = try JSONEncoder().encode([MessageSegment.text("正文")])
        let before = MemoryResident.wikiRevisions(in: [ConversationMessage(scalar: node)])
        node.content = "正文加长"
        XCTAssertNotEqual(MemoryResident.wikiRevisions(in: [ConversationMessage(scalar: node)]), before)
        node.ccEdited = true
        node.content = "甲乙"
        let firstCCEdit = MemoryResident.wikiRevisions(in: [ConversationMessage(scalar: node)])
        node.content = "丙丁"
        let secondCCEdit = MemoryResident.wikiRevisions(in: [ConversationMessage(scalar: node)])
        XCTAssertNotEqual(secondCCEdit, firstCCEdit)
        node.content = "戊己"
        XCTAssertNotEqual(MemoryResident.wikiRevisions(in: [ConversationMessage(scalar: node)]), secondCCEdit, "ccEdited 已为 true 后的同长度再编辑也要换刷新键")
        // 闭包里必须是生产刷新键的真实形状：标量转换 + wikiRevisions。
        // 全量转换（ConversationMessage.init）会读 segmentsData，末行的修改就会触发 onChange。
        withObservationTracking {
            _ = MemoryResident.wikiRevisions(in: [ConversationMessage(scalar: node)])
        } onChange: {
            XCTFail("刷新键不能观察、读取或解码外置 segmentsData")
        }
        node.segmentsData = Data("deliberately not JSON".utf8)
    }

    /// 反向：带分段的完整转换确实读 `segmentsData`，改它就触发观察。
    /// 证明上一条测试不是「闭包没观察任何节点属性」的恒绿。
    @MainActor
    func testWikiRevisionsFullConversionObservesExternalSegments() throws {
        let node = MessageNode(id: "revision-full", role: "assistant", content: "正文", contentType: "text",
                               createTime: nil, parentId: nil, childrenIds: [], conversationId: "revision")
        node.segmentsData = try JSONEncoder().encode([MessageSegment.text("正文")])
        let observed = expectation(description: "全量转换读取外置分段，修改 segmentsData 应触发观察")
        withObservationTracking {
            _ = MemoryResident.wikiRevisions(in: [ConversationMessage(node)])
        } onChange: {
            observed.fulfill()
        }
        node.segmentsData = Data("deliberately not JSON".utf8)
        wait(for: [observed], timeout: 1)
    }

    @MainActor
    func testEffectivePersonaRefreshKeyObservesStoreAndNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-persona-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UserPersonaStore(root: root)
        let floorPersona = UserPersona(id: "floor", name: "阿禾", description: "楼层身份")
        var conversationPersona = UserPersona(id: "conversation", name: "小禾", description: "对话身份")
        try store.add([floorPersona, conversationPersona])
        var profile = Profile(id: pid, name: "T", emoji: "", description: "", userName: "阿青", assistantName: "阿白")
        profile.personaId = floorPersona.id
        func key(_ conversationId: String? = "conversation") -> MemoryResident.IdentityKey {
            MemoryResident.IdentityKey(profile: profile, conversationPersonaId: conversationId, personas: store.personas)
        }
        let before = key()
        XCTAssertEqual(before.userName, "小禾")
        XCTAssertNotEqual(key(nil), before, "对话 personaId 改为跟随楼层")
        let observed = expectation(description: "身份库内容变化触发页面的观察")
        withObservationTracking {
            _ = key()
        } onChange: {
            observed.fulfill()
        }
        conversationPersona.description = "改写身份"
        try store.add([conversationPersona])
        wait(for: [observed], timeout: 1)
        XCTAssertNotEqual(key(), before, "同 id / 同长度描述修订也刷新")
        let descriptionChanged = key()
        conversationPersona.name = "小岚"
        try store.add([conversationPersona])
        XCTAssertNotEqual(key(), descriptionChanged, "有效用户名同长度改名")
        let userChanged = key()
        profile.assistantName = "阿宁"
        XCTAssertNotEqual(key(), userChanged, "助手名改变会改变自动排除词")
        let assistantChanged = key()
        profile.personaId = nil
        XCTAssertNotEqual(key(), assistantChanged, "楼层 personaId 也属于刷新键")
        profile.personaId = floorPersona.id
        try store.remove(ids: [conversationPersona.id])
        XCTAssertEqual(key().userName, "阿禾", "对话身份删除按现有规则回退楼层")
    }

    @MainActor
    func testAutomaticWikiHitIsNotGrayedWhenRootIndexIsUnchecked() async throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-y7-\(UUID().uuidString)")
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        defer { try? FileManager.default.removeItem(at: root) }
        try wiki.save(WikiPage(path: "主题/云桥城", title: "云桥城", now: "星砚与岚舟写生"))
        try wiki.rebuildAllIndexes()
        try await WikiInjectionCache.shared.warm(wiki.root.path) { wiki }
        var tuning = RecallTestTuning.make()
        tuning.archiveTriggerEnabled = true
        RecallTuningStore.save(tuning, profileId: pid)
        MemoryOpenWindowStore.save(.c, false, profileId: pid)
        let profile = Profile(id: pid, name: "星砚", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
        MainThreadIO.allowMainThreadInThisTest()
        let summary = MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid), container: container,
                                             selfMemories: [], recentMessages: ["云桥城"], wikiStore: wiki)
        XCTAssertEqual(summary.wiki?.hits.map(\.page.path), ["主题/云桥城"])
        XCTAssertNil(summary.wiki?.gate)
        let text = try XCTUnwrap(summary.wiki?.text)
        XCTAssertTrue(text.contains("没勾"))
        XCTAssertFalse(text.contains("0 行"))
    }

    @MainActor
    func testSummaryExcludesNamesFromSameResolvedProfileAsSend() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-persona-summary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root)
        for name in ["阿青", "阿禾", "小禾", "阿白"] {
            try wiki.save(WikiPage(path: "人/\(name)", kind: .person, triggers: [], hook: "提到时", title: name, now: "当前正文。"))
        }
        try wiki.rebuildAllIndexes()
        try await WikiInjectionCache.shared.warm(root.path) { wiki }
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)
        UserDefaults.standard.set(false, forKey: MemoryOpenWindow.b4Key)
        MainThreadIO.allowMainThreadInThisTest()
        var profile = Profile(id: pid, name: "T", emoji: "", description: "", userName: "阿青", assistantName: "阿白")
        profile.personaId = "floor"
        let personas = [UserPersona(id: "floor", name: "阿禾", description: "楼层身份"),
                        UserPersona(id: "conversation", name: "小禾", description: "对话身份")]
        let conversation = Conversation(id: "resident-persona", title: "T", createTime: Date(), updateTime: Date(), currentNodeId: "")
        conversation.profileId = pid
        conversation.personaId = "conversation"
        context.insert(conversation)
        try context.save()
        let recent = ["阿青 阿禾 小禾 阿白"]
        func summary() -> (SendContext, MemoryResident.Summary) {
            let resolved = SendContextResolver.resolve(profile: profile, conversation: conversation, context: context,
                                                        globalEntries: [], globalBooks: [], personas: personas)
            return (resolved, MemoryResident.summary(profile: resolved.profile, participation: .testValue(profileId: pid),
                                                     container: container, selfMemories: [], recentMessages: recent, wikiStore: wiki))
        }
        let (effective, on) = summary()
        XCTAssertEqual(effective.persona.level, .conversation)
        XCTAssertEqual(effective.profile.userName, "小禾")
        XCTAssertEqual(on.wiki?.hits.map(\.page.title), ["阿青", "阿禾"], "只排实发的对话用户名与助手名，不错排原楼层身份")
        let sent = PromptAssembler.memoryLayers(profile: effective.profile, selfMemory: nil, memories: [], recentMessages: recent,
                                                budget: nil, wiki: WikiInjectionCache.shared.snapshot(profileId: pid, store: wiki))
        XCTAssertEqual(on.wiki?.hits.map(\.word), sent.pages.map(\.word))

        conversation.personaId = nil
        XCTAssertEqual(summary().1.wiki?.hits.map(\.page.title), ["阿青", "小禾"], "跟随楼层身份时排楼层 persona 的名字")
        conversation.personaId = "missing"
        XCTAssertEqual(summary().1.wiki?.hits.map(\.page.title), ["阿青", "小禾"], "指定身份不存在也沿同一解析回退")
        profile.personaId = nil
        XCTAssertEqual(summary().1.wiki?.hits.map(\.page.title), ["阿禾", "小禾"], "两级身份都不存在用楼层原名")
        conversation.personaId = "conversation"
        profile.assistantName = "阿青"
        XCTAssertEqual(summary().1.wiki?.hits.map(\.page.title), ["阿禾", "阿白"], "助手改名后新名不触发，旧名恢复为普通触发词")
    }

    @MainActor
    func testWindowAllOffHidesB4ArchiveAndPinnedFromNextRoundSummary() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try wiki.save(WikiPage(path: "人/林栖", title: "林栖", now: "林栖在云桥城绘图"))
        try wiki.rebuildAllIndexes()
        _ = try await WikiInjectionCache.shared.warm(root.path) { wiki }
        let own = selfMem("星砚的航图", importance: 5)
        try SelfMemoryStore.save(own, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked)
        context.insert(mem("岚舟钉住的坐标", pinned: true))
        let fragment = mem("林栖留下的航线")
        fragment.occurredDay = "2026-11-01"
        fragment.reviewedAt = Date()
        context.insert(fragment)
        try context.save()
        UserDefaults.standard.set(true, forKey: "mem_master")
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        MemoryOpenWindowStore.save(.b4, true, profileId: pid)
        let profile = Profile(id: pid, name: "云桥城", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
        let baseline = await MemoryResident.loadSummary(profile: profile, participation: .testValue(profileId: pid),
                                                        container: container, recentNodeIds: [], wikiStore: wiki)
        XCTAssertTrue(baseline.stable.contains("星砚的航图"))
        XCTAssertTrue(baseline.stable.contains("岚舟钉住的坐标"))
        let off = await MemoryResident.loadSummary(profile: profile, participation: .testValue(profileId: pid, choices: .allOff),
                                                   container: container, wikiStore: wiki)
        XCTAssertEqual(off.stable, "")
        XCTAssertEqual(off.volatile, "")
        XCTAssertEqual(off.memoryCount, 0)
        XCTAssertNil(off.wiki?.indexCount)
        XCTAssertTrue(off.wiki?.hits.isEmpty == true)
        XCTAssertTrue(off.selfRows.allSatisfy { $0.gate == .selfUnchecked })
        XCTAssertTrue(off.archive.allSatisfy { $0.gate == .archiveUnchecked })
    }

    /// 记忆格 / 常驻页都走 loadSummary：读{助手}的记忆文件、组装注入在后台，主线程一次盘都不碰（对照：同步调用在主线程会碰）
    @MainActor
    func testLoadSummaryTouchesNoDiskOnMain() async throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "阿青", assistantName: "阿白")
        UserDefaults.standard.set(true, forKey: MemoryOpenWindow.cKey)

        MainThreadIO.allowMainThreadInThisTest()
        MainThreadIO.beginCounting()
        _ = MemoryResident.summary(profile: profile, participation: .testValue(profileId: pid), container: container)
        let onMain = MainThreadIO.endCounting()
        XCTAssertFalse(onMain.isEmpty, "对照：在主线程同步算会读{助手}的记忆文件")

        MainThreadIO.beginCounting()
        let s = await MemoryResident.loadSummary(profile: profile, participation: .testValue(profileId: pid), container: container)
        XCTAssertEqual(MainThreadIO.endCounting(), [:], "loadSummary：主线程不碰盘")
        XCTAssertEqual(s.count, 0)
    }

    /// plan §4：常驻页口径（`resolve(profileId:conversation:preset:)`）传本窗 choices 后，Z6 跟 choices 走，不跟楼层 C 勾
    @MainActor
    func testResidentPageSummaryFollowsWindowChoicesForArchive() async throws {
        let container = try ModelContainer(for: Memory.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resident-choices-\(UUID().uuidString)")
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        defer { try? FileManager.default.removeItem(at: root) }
        try wiki.save(WikiPage(path: "主题/云桥城", title: "云桥城", now: "星砚与岚舟写生"))
        try wiki.rebuildAllIndexes()
        _ = try await WikiInjectionCache.shared.warm(wiki.root.path) { wiki }
        MemoryOpenWindowStore.save(.c, true, profileId: pid)
        let profile = Profile(id: pid, name: "云桥城", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
        let conversation = Conversation(id: "resident-choices", title: "T", createTime: Date(), updateTime: Date(), currentNodeId: "")
        conversation.profileId = pid
        var choices = MemoryWindowChoices.allOff
        choices.archive = false
        conversation.memoryWindowChoices = choices

        MainThreadIO.allowMainThreadInThisTest()
        func summary() -> MemoryResident.Summary {
            MemoryResident.summary(profile: profile,
                                   participation: EffectiveMemoryParticipation.resolve(profileId: pid, conversation: conversation, preset: nil),
                                   container: container, selfMemories: [], wikiStore: wiki)
        }

        let off = summary()
        XCTAssertEqual(off.wiki?.gate, .archiveUnchecked, "C 勾着但本窗划掉档案：灰字说 C 没勾")
        XCTAssertNil(off.wiki?.indexCount, "本窗不勾档案：根索引不计数")

        choices.archive = true
        conversation.memoryWindowChoices = choices
        let on = summary()
        XCTAssertNil(on.wiki?.gate)
        XCTAssertEqual(on.wiki?.indexCount, 1)
    }

    /// 常驻页「上一轮实际注入」三级取数（plan-memory-receipt §2.4）：当前窗已生效的 assistant 回执 > CC 路由 user 回执 > 楼层账
    func testLastInjectionPrefersCurrentWindowReceipt() throws {
        let decision = RecallTurnDecision(turnId: "u1", branchAnchor: "resident-window", origin: .user, gateReason: .search,
                                          tuning: RecallTestTuning.make(), topicAnchor: "", selected: [], candidates: [],
                                          suppressions: [], ignored: [], thawed: [], stateAfterResponse: RecallConversationState())
        let gate = RecallGateSnapshot(off: nil, participates: true, triggerOff: false, legacy: false, choices: [:],
                                      a2Checked: false, hiddenFragments: 0, hiddenTimeline: 0)
        func node(_ id: String, _ role: String) -> MessageNode {
            MessageNode(id: id, role: role, content: "", contentType: "text", createTime: Date(timeIntervalSince1970: 10),
                        parentId: nil, childrenIds: [], conversationId: "resident-window", profileId: pid)
        }
        let ccDelivery = RecallDelivery(id: "cc", route: "ccBridge", items: [], gate: gate)
        var receipts: [String: RecallTurnReceipt] = [:]

        let ccUser = node("u-cc", "user")
        var cc = RecallTurnReceipt(decision: decision)
        cc.delivery = ccDelivery
        receipts[ccUser.id] = cc
        let fromCC = try XCTUnwrap(MemoryResident.lastInjection(in: [ccUser]) { receipts[$0.id] })
        XCTAssertEqual(fromCC.viaCCBridge, true, "没有回复回执：认 CC 路由")

        let user = node("u1", "user")
        let pendingReply = node("a1", "assistant")
        receipts[user.id] = RecallTurnReceipt(decision: decision)
        var notYet = RecallTurnReceipt(decision: decision)
        notYet.inheritedEffective = true
        notYet.injectionRecord = MemoryInjectionRecord(tokens: 1, stableCount: 0, hitCount: 0, at: Date(timeIntervalSince1970: 1))
        receipts[pendingReply.id] = notYet
        XCTAssertEqual(MemoryResident.lastInjection(in: [ccUser, user, pendingReply]) { receipts[$0.id] }?.viaCCBridge, true,
                       "只靠 inherited 生效的在途回复（自身没收到响应）不算上一轮")

        let reply = node("a2", "assistant")
        var effective = RecallTurnReceipt(decision: decision)
        effective.attempts = [RecallAttempt(id: "a2-attempt", status: .responded, receivedResponse: true)]
        effective.injectionRecord = MemoryInjectionRecord(tokens: 42, stableCount: 1, hitCount: 2,
                                                          at: Date(timeIntervalSince1970: 2), conversationId: "resident-window")
        receipts[reply.id] = effective
        let path = [ccUser, user, pendingReply, reply]
        let current = try XCTUnwrap(MemoryResident.lastInjection(in: path) { receipts[$0.id] })
        XCTAssertEqual(current.tokens, 42, "当前窗已生效的回执优先")
        XCTAssertEqual(current.hitCount, 2)
        XCTAssertEqual(current.conversationId, "resident-window")

        XCTAssertNil(MemoryResident.lastInjection(in: [node("u-x", "user")]) { receipts[$0.id] },
                     "都没有：调用方退回楼层账")
    }

    /// 同窗混用 API / CC 时倒序先遇到者胜（P3 r2 / Opus M1）：不能越过更晚的 CC 轮取更早的 API 轮
    func testLastInjectionPicksLatestOfAPIThenCC() throws {
        let decision = RecallTurnDecision(turnId: "u1", branchAnchor: "resident-window", origin: .user, gateReason: .search,
                                          tuning: RecallTestTuning.make(), topicAnchor: "", selected: [], candidates: [],
                                          suppressions: [], ignored: [], thawed: [], stateAfterResponse: RecallConversationState())
        let gate = RecallGateSnapshot(off: nil, participates: true, triggerOff: false, legacy: false, choices: [:],
                                      a2Checked: false, hiddenFragments: 0, hiddenTimeline: 0)
        func node(_ id: String, _ role: String) -> MessageNode {
            MessageNode(id: id, role: role, content: "", contentType: "text", createTime: Date(timeIntervalSince1970: 10),
                        parentId: nil, childrenIds: [], conversationId: "resident-window", profileId: pid)
        }
        func apiReceipt(tokens: Int) -> RecallTurnReceipt {
            var receipt = RecallTurnReceipt(decision: decision)
            receipt.attempts = [RecallAttempt(id: "attempt-\(tokens)", status: .responded, receivedResponse: true)]
            receipt.injectionRecord = MemoryInjectionRecord(tokens: tokens, stableCount: 1, hitCount: 1,
                                                            at: Date(timeIntervalSince1970: TimeInterval(tokens)))
            return receipt
        }
        var receipts: [String: RecallTurnReceipt] = [:]
        let apiUser = node("u-api", "user")
        let apiReply = node("a-api", "assistant")
        receipts[apiUser.id] = RecallTurnReceipt(decision: decision)
        receipts[apiReply.id] = apiReceipt(tokens: 21)

        let ccUser = node("u-cc", "user")
        var cc = RecallTurnReceipt(decision: decision)
        cc.delivery = RecallDelivery(id: "cc", route: "ccBridge", items: [], gate: gate)
        receipts[ccUser.id] = cc

        let ccWins = try XCTUnwrap(MemoryResident.lastInjection(in: [apiUser, apiReply, ccUser]) { receipts[$0.id] })
        XCTAssertEqual(ccWins.viaCCBridge, true, "先 API 后 CC：CC 是最近一轮")

        let apiUser2 = node("u-api-2", "user")
        let apiReply2 = node("a-api-2", "assistant")
        receipts[apiUser2.id] = RecallTurnReceipt(decision: decision)
        receipts[apiReply2.id] = apiReceipt(tokens: 33)
        let apiWins = try XCTUnwrap(MemoryResident.lastInjection(in: [apiUser, apiReply, ccUser, apiUser2, apiReply2]) {
            receipts[$0.id]
        })
        XCTAssertEqual(apiWins.tokens, 33, "CC 之后又来 API：API 回复是最近一轮")
        XCTAssertNil(apiWins.viaCCBridge)
    }
}
