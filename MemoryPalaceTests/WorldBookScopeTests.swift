import XCTest
@testable import 记忆花园

/// ⑥ 世界书页纯逻辑：四范围过滤、整本开关不参与扫描、条数上限 × token 预算、单条删除撤销、单书导出。
final class WorldBookScopeTests: XCTestCase {

    // MARK: - 夹具

    private func entry(_ content: String, order: Int = 100, constant: Bool = true) -> WorldBookEntry {
        var e = WorldBookEntry()
        e.content = content
        e.insertionOrder = order
        e.isConstant = constant
        return e
    }

    private func item(_ kind: WorldBookListItem.Kind, _ id: String, profile: String? = nil, conversation: String? = nil,
                      name: String? = nil, entries: [WorldBookEntry] = []) -> WorldBookListItem {
        WorldBookListItem(kind: kind, bookId: id, name: name ?? id, profileId: profile, conversationId: conversation,
                          entries: entries, isEnabled: true)
    }

    private var catalog: [WorldBookListItem] {
        [item(.global, "g1"),
         item(.floor, "a", profile: "p1"),
         item(.floor, "b", profile: "p1", conversation: "c1"),
         item(.floor, "c", profile: "p1", conversation: "c2"),
         item(.floor, "d", profile: "p2"),
         item(.floor, "e", profile: "p2", conversation: "c1")]
    }

    private func ids(_ items: [WorldBookListItem]) -> [String] { items.map(\.bookId) }

    private func resolved(_ order: Int, tokens: Int) -> ResolvedEntry {
        ResolvedEntry(content: "e\(order)", position: .afterCharDef, depth: 4, insertionOrder: order,
                      role: "system", tokenCount: tokens, isConstant: true)
    }

    // MARK: - 四范围

    func testAllListsEveryFloorAndGlobal() {
        let all = WorldBookLibrary.filter(catalog, scope: .all, currentProfileId: "p1", selectedConversationId: "c1")
        XCTAssertEqual(ids(all), ["g1", "a", "b", "c", "d", "e"], "全部 = 全局 + 所有楼层（跨楼层只浏览）")
    }

    func testGlobalScope() {
        XCTAssertEqual(ids(WorldBookLibrary.filter(catalog, scope: .global, currentProfileId: "p1", selectedConversationId: nil)), ["g1"])
    }

    func testFloorScopeIsCurrentFloorWithoutConversationBooks() {
        XCTAssertEqual(ids(WorldBookLibrary.filter(catalog, scope: .floor, currentProfileId: "p1", selectedConversationId: "c1")), ["a"])
        XCTAssertEqual(ids(WorldBookLibrary.filter(catalog, scope: .floor, currentProfileId: "p2", selectedConversationId: nil)), ["d"])
    }

    func testConversationScopeFollowsSelectedConversationOnCurrentFloor() {
        XCTAssertEqual(ids(WorldBookLibrary.filter(catalog, scope: .conversation, currentProfileId: "p1", selectedConversationId: "c1")), ["b"],
                       "只要当前楼层里绑定选中对话的书，别的楼层同 id 对话不算")
        XCTAssertEqual(ids(WorldBookLibrary.filter(catalog, scope: .conversation, currentProfileId: "p1", selectedConversationId: "c2")), ["c"])
    }

    func testConversationScopeEmptyAndDisabledWithoutSelection() {
        XCTAssertTrue(WorldBookLibrary.filter(catalog, scope: .conversation, currentProfileId: "p1", selectedConversationId: nil).isEmpty)
        XCTAssertFalse(WorldBookLibrary.isAvailable(.conversation, selectedConversationId: nil))
        XCTAssertTrue(WorldBookLibrary.isAvailable(.conversation, selectedConversationId: "c1"))
        for scope in [WorldBookScope.all, .global, .floor] {
            XCTAssertTrue(WorldBookLibrary.isAvailable(scope, selectedConversationId: nil))
        }
    }

    func testSearchMatchesBookNameOrEntryContent() {
        let items = [item(.floor, "x", profile: "p1", name: "长街手记", entries: [entry("河岸石屋")]),
                     item(.floor, "y", profile: "p1", name: "海风备忘", entries: [entry("灯塔")])]
        XCTAssertEqual(ids(WorldBookLibrary.search(items, keyword: "长街")), ["x"])
        XCTAssertEqual(ids(WorldBookLibrary.search(items, keyword: "灯塔")), ["y"])
        XCTAssertEqual(ids(WorldBookLibrary.search(items, keyword: nil)), ["x", "y"])
    }

    func testTargetIdsMatchDeepLinkFormat() {
        let uuid = UUID()
        let entryId = UUID()
        let floor = item(.floor, uuid.uuidString, profile: "p1")
        XCTAssertEqual(floor.id, "floor:\(uuid)")
        XCTAssertEqual(floor.entryTargetId(entryId), "floor:\(uuid):\(entryId)", "和小组件 / 搜索深链同一口径")
        let parsed = WorldBookLibrary.parseTarget("global:g1:\(entryId.uuidString)")
        XCTAssertEqual(parsed?.kind, .global)
        XCTAssertEqual(parsed?.bookId, "g1")
        XCTAssertEqual(parsed?.entryId, entryId)
        XCTAssertNil(WorldBookLibrary.parseTarget("memory:abc"))
    }

    // MARK: - 整本开关

    func testDisabledFloorBookSkippedByScanner() {
        let profile = Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                              systemPrompt: "", characterDescription: "")
        let on = WorldBook(name: "开着", profileId: "p1", entries: [entry("开着的书")])
        let off = WorldBook(name: "关着", profileId: "p1", entries: [entry("关掉的书")])
        off.isEnabled = false
        let result = WorldBookScanner.scan(worldBooks: [on, off], recentMessages: [], profile: profile)
        XCTAssertEqual(result.map(\.content), ["开着的书"])
        XCTAssertTrue(WorldBookScanner.scan(worldBooks: [off], recentMessages: [], profile: profile,
                                            globalEntries: []).isEmpty)
        XCTAssertTrue(WorldBook(name: "新书", profileId: "p1").isEnabled, "新书默认开")
    }

    // MARK: - 条数上限 × token 预算

    func testZeroLimitsKeepEverything() {
        let input = [resolved(10, tokens: 5), resolved(20, tokens: 50), resolved(30, tokens: 5)]
        XCTAssertEqual(WorldBookScanner.limited(input, maxEntries: 0, tokenBudget: 0).map(\.insertionOrder), [10, 20, 30])
    }

    func testMaxEntriesKeepsFirstByInsertionOrder() {
        let input = [resolved(10, tokens: 5), resolved(20, tokens: 5), resolved(30, tokens: 5)]
        XCTAssertEqual(WorldBookScanner.limited(input, maxEntries: 2, tokenBudget: 0).map(\.insertionOrder), [10, 20])
        XCTAssertEqual(WorldBookScanner.limited(input, maxEntries: 5, tokenBudget: 0).map(\.insertionOrder), [10, 20, 30])
    }

    func testCountThenTokenBothApply() {
        let input = [resolved(10, tokens: 5), resolved(20, tokens: 10), resolved(30, tokens: 3)]
        XCTAssertEqual(WorldBookScanner.limited(input, maxEntries: 0, tokenBudget: 8).map(\.insertionOrder), [10, 30],
                       "只有 token 预算：放不下的跳过，后面小的还能进")
        XCTAssertEqual(WorldBookScanner.limited(input, maxEntries: 2, tokenBudget: 8).map(\.insertionOrder), [10],
                       "先条数（留 10、20）后 token（20 放不下）")
    }

    func testScannerOrderFeedsLimitStably() {
        let profile = Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                              systemPrompt: "", characterDescription: "")
        let scanned = WorldBookScanner.scan(worldBooks: [], recentMessages: [], profile: profile,
                                            globalEntries: [entry("丙", order: 30), entry("甲", order: 10), entry("乙", order: 10)])
        XCTAssertEqual(WorldBookScanner.limited(scanned, maxEntries: 2, tokenBudget: 0).map(\.content), ["甲", "乙"],
                       "按 insertionOrder，同序保持原顺序")
    }

    func testAssemblerAppliesMaxEntries() {
        let key = CardLibraryPreferences.worldBookMaxEntriesKey
        let old = UserDefaults.standard.object(forKey: key)
        defer { if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let profile = Profile(name: "测试", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚",
                              systemPrompt: "系统指令", characterDescription: "角色设定")
        var preset = Preset(name: "t")
        preset.prompts = [
            PromptSlot(id: PromptSlot.mainId, name: "系统指令", role: "system", isSystemPrompt: true, isMarker: false, injectionOrder: 0),
            PromptSlot(id: PromptSlot.charDescriptionId, name: "助手设定", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 20),
            PromptSlot(id: PromptSlot.chatHistoryId, name: "对话历史", role: "system", isSystemPrompt: true, isMarker: true, injectionOrder: 60),
        ]
        let entries = [entry("第一条设定", order: 1), entry("第二条设定", order: 2), entry("第三条设定", order: 3)]
        func worldText() -> String {
            PromptAssembler.assembleTagged(preset: preset, profile: profile, memories: [], chatHistory: [("user", "你好")],
                                           worldBooks: [], globalEntries: entries).segments
                .filter { if case .worldBook = $0.source { return true } else { return false } }
                .map(\.content).joined(separator: "\n")
        }
        UserDefaults.standard.set(0, forKey: key)
        let unlimited = worldText()
        XCTAssertTrue(unlimited.contains("第三条设定"))
        UserDefaults.standard.set(2, forKey: key)
        let limited = worldText()
        XCTAssertTrue(limited.contains("第一条设定"))
        XCTAssertTrue(limited.contains("第二条设定"))
        XCTAssertFalse(limited.contains("第三条设定"), "超出条数上限的不注入")
    }

    // MARK: - 单条删除撤销

    func testDeleteThenUndoRestoresOriginalPositionAndToggle() {
        var middle = entry("中")
        middle.isEnabled = false
        let entries = [entry("前"), middle, entry("后")]
        guard let result = WorldBookLibrary.deleting(entries, entryId: middle.id, bookItemId: "floor:x") else { return XCTFail() }
        XCTAssertEqual(result.entries.map(\.content), ["前", "后"])
        XCTAssertEqual(result.deletion.index, 1)
        guard case .restored(let restored) = WorldBookLibrary.restoring(result.deletion, into: result.entries) else { return XCTFail() }
        XCTAssertEqual(restored.map(\.content), ["前", "中", "后"])
        XCTAssertFalse(restored[1].isEnabled, "原开关一起回来")
        XCTAssertEqual(restored, entries)
    }

    func testUndoClampsIndexWhenBookShrank() {
        let entries = [entry("一"), entry("二"), entry("三")]
        guard let result = WorldBookLibrary.deleting(entries, entryId: entries[2].id, bookItemId: "global:g") else { return XCTFail() }
        guard case .restored(let restored) = WorldBookLibrary.restoring(result.deletion, into: [entries[0]]) else { return XCTFail() }
        XCTAssertEqual(restored.map(\.content), ["一", "三"])
    }

    func testUndoConflicts() {
        let entries = [entry("一"), entry("二")]
        guard let result = WorldBookLibrary.deleting(entries, entryId: entries[0].id, bookItemId: "floor:x") else { return XCTFail() }
        if case .restored = WorldBookLibrary.restoring(result.deletion, into: nil) { XCTFail("书删了不能插回") }
        if case .restored = WorldBookLibrary.restoring(result.deletion, into: entries) { XCTFail("同 id 已在不能重复插") }
        XCTAssertNil(WorldBookLibrary.deleting(entries, entryId: UUID(), bookItemId: "floor:x"))
    }

    func testDisplayOrderIsStableByInsertionOrder() {
        let entries = [entry("丙", order: 30), entry("甲", order: 10), entry("乙", order: 10)]
        XCTAssertEqual(WorldBookLibrary.displayOrder(entries).map(\.content), ["甲", "乙", "丙"])
        XCTAssertEqual(entries.map(\.content), ["丙", "甲", "乙"], "只影响显示")
    }

    // MARK: - 单书导出

    private let worldInfoJSON = """
    {"name":"长街","extensions":{"keep":1},"entries":{"0":{"uid":0,"key":["河岸"],"keysecondary":[],"comment":"河岸石屋","content":"石屋在长街尽头","constant":false,"selective":true,"selectiveLogic":0,"order":20,"position":4,"disable":false,"depth":4,"scanDepth":null,"probability":100,"useProbability":true,"matchWholeWords":null,"caseSensitive":null,"cooldown":3},"1":{"uid":1,"key":["白石"],"comment":"白石","content":"白石的旧习惯","order":30,"position":1,"disable":false}}}
    """

    func testUneditedExportReturnsOriginalBytes() throws {
        let raw = Data(worldInfoJSON.utf8)
        let report = try WorldBookCodec.decodeImport(raw)
        let out = try WorldBookCodec.encodeExport(name: report.name ?? "", entries: report.entries, rawJSONData: report.rawJSONData)
        XCTAssertEqual(out, raw)
    }

    func testEditedExportOverlaysOnlyChangedFields() throws {
        let raw = Data(worldInfoJSON.utf8)
        var entries = try WorldBookCodec.decodeImport(raw).entries
        entries[0].content = "改过的正文"
        entries.remove(at: 1)
        let out = try WorldBookCodec.encodeExport(name: "长街", entries: entries, rawJSONData: raw)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual((root["extensions"] as? [String: Any])?["keep"] as? Int, 1, "书级未知字段保留")
        let dict = try XCTUnwrap(root["entries"] as? [String: [String: Any]])
        XCTAssertEqual(dict.count, 1, "删掉的条目不写")
        let first = try XCTUnwrap(dict["0"])
        XCTAssertEqual(first["content"] as? String, "改过的正文")
        XCTAssertEqual(first["cooldown"] as? Int, 3, "条目未知字段保留")
        XCTAssertTrue(first["matchWholeWords"] is NSNull, "没改的字段不被默认值覆盖")
        let again = try WorldBookCodec.decodeImport(out)
        XCTAssertEqual(again.entries.first?.content, "改过的正文")
        XCTAssertEqual(again.entries.first?.position, .atDepth)
        XCTAssertEqual(again.entries.first?.insertionOrder, 20)
    }

    func testExportWithoutRawWritesWorldInfo() throws {
        var e = entry("常驻设定", order: 5)
        e.keys = ["雨季"]
        let out = try WorldBookCodec.encodeExport(name: "新书", entries: [e], rawJSONData: nil)
        let report = try WorldBookCodec.decodeImport(out)
        XCTAssertEqual(report.name, "新书")
        XCTAssertEqual(report.entries.map(\.content), ["常驻设定"])
        XCTAssertEqual(report.entries.first?.keys, ["雨季"])
        XCTAssertEqual(report.entries.first?.insertionOrder, 5)
        XCTAssertEqual(report.entries.first?.isConstant, true)
    }
}
