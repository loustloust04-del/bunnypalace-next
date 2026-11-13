import XCTest
@testable import 记忆花园

/// #093 工具抽屉（plan-tool-drawer §4）
@MainActor
final class ToolDrawerTests: XCTestCase {

    /// setLevel 同时写新键和旧键，跑完都还原（原来没有就删掉）
    private let permKeys = [PermissionDomain.toolsMaster, .fileLibrary].flatMap { [$0.storageKey, $0.legacy.key] }
    private var savedPerm: [Any?] = []

    override func setUp() async throws {
        savedPerm = permKeys.map { UserDefaults.standard.object(forKey: $0) }
        PermissionCenter.setDefaultLevel(.bypass, for: .toolsMaster)
        PermissionCenter.setDefaultLevel(.bypass, for: .fileLibrary)
    }

    override func tearDown() async throws {
        for (k, v) in zip(permKeys, savedPerm) {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    private func ctx(_ drawer: ToolDrawerState = .defaults, profileId: String? = "p1", deferMCP: Bool = false) -> ToolGateContext {
        ToolGateContext(family: .openAI, deferMCP: deferMCP, profileId: profileId, drawer: drawer)
    }

    private func drawer(_ pairs: [(String, ToolDrawerMode)], profileId: String? = nil) -> ToolDrawerState {
        var s = ToolDrawerState.defaults
        for (n, m) in pairs { s.set(m, for: n, profileId: profileId) }
        return s
    }

    private func names(_ defs: [ToolDefinition]) -> Set<String> { Set(defs.map(\.name)) }

    // MARK: 注册表

    func testDefaultDrawerKeepsPreDrawerPartition() {
        let c = ctx()
        let enabled = ToolRegistry.all.filter { $0.enabledIf(c) }.map(\.definition.name)
        XCTAssertEqual(ToolRegistry.enabledDefinitions(c).map(\.name), enabled, "默认态 = 只看上游门")
        XCTAssertEqual(ToolRegistry.inlineDefinitions(c).map(\.name), enabled.filter { !ToolRegistry.defaultTuckedNames.contains($0) })
        XCTAssertEqual(ToolRegistry.tuckedDefinitions(c).map(\.name), enabled.filter { ToolRegistry.defaultTuckedNames.contains($0) })
    }

    /// C2/C3 v2 第 4 段：提整理方向的工具默认直接给（粟粟 10-22），C3 关着就没有
    func testWikiSuggestIsInlineByDefaultBehindC3Gate() {
        let name = WikiSuggestTool.toolName
        XCTAssertEqual(ToolRegistry.defaultMode(name), .inline)
        XCTAssertTrue(names(ToolRegistry.inlineDefinitions(ctx())).contains(name))
        XCTAssertEqual(ToolRegistry.availability(of: name, ctx()), true)
        XCTAssertEqual(ToolDrawerCatalog.item(named: name)?.gate, .memoryWriter(.c3))
    }

    func testOffRemovesEverywhereAndAvailabilityRefuses() {
        let c = ctx(drawer([(FileLibraryTools.Name.write.rawValue, .off), (OCRImageTool.toolName, .off)]))
        for n in [FileLibraryTools.Name.write.rawValue, OCRImageTool.toolName] {
            XCTAssertFalse(names(ToolRegistry.enabledDefinitions(c)).contains(n), n)
            XCTAssertFalse(names(ToolRegistry.inlineDefinitions(c)).contains(n), n)
            XCTAssertFalse(names(ToolRegistry.tuckedDefinitions(c)).contains(n), n)
            XCTAssertEqual(ToolRegistry.availability(of: n, c), false, n)
        }
        XCTAssertTrue(names(ToolRegistry.inlineDefinitions(c)).contains(FileLibraryTools.Name.read.rawValue), "同组别的不受影响")
    }

    func testDrawerCannotOverrideUpstreamGate() {
        PermissionCenter.setDefaultLevel(.notAllowed, for: .fileLibrary)
        let c = ctx(drawer([(FileLibraryTools.Name.delete.rawValue, .inline)]))
        XCTAssertFalse(names(ToolRegistry.enabledDefinitions(c)).contains(FileLibraryTools.Name.delete.rawValue), "抽屉只收窄")
        XCTAssertEqual(ToolRegistry.availability(of: FileLibraryTools.Name.delete.rawValue, c), false)
    }

    func testUserTuckedToolGoesToMoreToolsWithBlurb() throws {
        let write = FileLibraryTools.Name.write.rawValue
        let c = ctx(drawer([(write, .tucked)]))
        XCTAssertTrue(names(ToolRegistry.tuckedDefinitions(c)).contains(write))
        XCTAssertFalse(names(ToolRegistry.inlineDefinitions(c)).contains(write))
        XCTAssertEqual(ToolRegistry.availability(of: write, c), true, "收起照样能用")
        XCTAssertTrue(MetaTools.names.isSubset(of: names(ToolRegistry.inlineDefinitions(c))))
        let def = try XCTUnwrap(ToolRegistry.tuckedDefinitions(c).first { $0.name == write })
        XCTAssertNil(ToolRegistry.tuckedBlurbs[write], "fs_write 没手写 blurb")
        XCTAssertEqual(ToolRegistry.blurb(for: def), ToolRegistry.firstSentence(def.description))
        XCTAssertFalse(ToolRegistry.blurb(for: def).contains("。"), "只取第一句")
        let listed = MetaTools.search(query: "", catalog: [], builtins: ToolRegistry.tuckedDefinitions(c))
        XCTAssertTrue(listed.contains("· \(write) — \(ToolRegistry.blurb(for: def))"), listed)
    }

    func testFirstSentenceCut() {
        XCTAssertEqual(ToolRegistry.firstSentence("读文件。参数 path。"), "读文件")
        XCTAssertEqual(ToolRegistry.firstSentence("第一行\n第二行"), "第一行")
        XCTAssertEqual(ToolRegistry.firstSentence(String(repeating: "字", count: 70)), String(repeating: "字", count: 60) + "…")
        XCTAssertEqual(ToolRegistry.firstSentence(""), "")
    }

    func testDefaultTuckedCanBeMadeInline() {
        let del = FileLibraryTools.Name.delete.rawValue
        let c = ctx(drawer([(del, .inline)]))
        XCTAssertTrue(names(ToolRegistry.inlineDefinitions(c)).contains(del))
        XCTAssertFalse(names(ToolRegistry.tuckedDefinitions(c)).contains(del))
    }

    func testMetaToolsVanishWhenNothingTuckedAndNoDefer() {
        let allOff = drawer(ToolRegistry.defaultTuckedNames.map { ($0, ToolDrawerMode.off) })
        XCTAssertTrue(ToolRegistry.tuckedDefinitions(ctx(allOff)).isEmpty)
        XCTAssertTrue(names(ToolRegistry.enabledDefinitions(ctx(allOff))).isDisjoint(with: MetaTools.names), "没有收起的 → 不发元工具")
        XCTAssertTrue(MetaTools.names.isSubset(of: names(ToolRegistry.enabledDefinitions(ctx(allOff, deferMCP: true)))), "MCP defer 照旧发")
        // 元工具本身不吃抽屉
        var metaOff = ToolDrawerState.defaults
        metaOff.set(.off, for: MetaTools.invokeName, profileId: nil)
        XCTAssertTrue(names(ToolRegistry.enabledDefinitions(ctx(metaOff))).contains(MetaTools.invokeName))
    }

    func testFloorOverrideAppliesOnlyToThatFloor() {
        let write = FileLibraryTools.Name.write.rawValue
        let s = drawer([(write, .off)], profileId: "p1")
        XCTAssertFalse(names(ToolRegistry.enabledDefinitions(ctx(s, profileId: "p1"))).contains(write))
        XCTAssertTrue(names(ToolRegistry.enabledDefinitions(ctx(s, profileId: "p2"))).contains(write))
    }

    func testServerWebSearchOnlyOnOff() {
        XCTAssertTrue(ToolRegistry.serverWebSearchOn(ctx()))
        XCTAssertFalse(ToolRegistry.serverWebSearchOn(ctx(drawer([(ToolRegistry.serverWebSearchName, .off)]))))
        XCTAssertFalse(ToolRegistry.serverWebSearchOn(ctx(drawer([(ToolRegistry.serverWebSearchName, .off)]), profileId: "p1")),
                       "楼层没覆盖 → 跟随全局（全局关了）")
        XCTAssertTrue(ToolRegistry.serverWebSearchOn(ctx(drawer([(ToolRegistry.serverWebSearchName, .off)], profileId: "p1"), profileId: "p2")))
        XCTAssertTrue(ConversationViewModel.toolUnavailableMessage(name: "fs_write").contains("工具抽屉"))
    }

    // MARK: 给人看的目录

    func testCatalogCoversRegistryExceptHiddenApp() {
        let catalog = ToolDrawerCatalog.items
        let names = Set(catalog.map(\.name))
        XCTAssertEqual(names.count, catalog.count, "目录里没有重名")
        var registry = Set(ToolRegistry.all.map(\.definition.name))
        #if PERSONAL_APPS
        registry.remove(DeathScaleAITool.toolName)
        XCTAssertFalse(names.contains(DeathScaleAITool.toolName), "隐藏子应用不进抽屉")
        #endif
        XCTAssertEqual(names, registry.union([ToolRegistry.serverWebSearchName]), "注册表每个工具都在抽屉里（+ 服务端搜索）")
        for item in catalog {
            XCTAssertFalse(item.summary.isEmpty, item.name)
            XCTAssertFalse(ToolDrawerCatalog.gateLabel(item.gate).isEmpty, item.name)
        }
        XCTAssertFalse(ToolDrawerCatalog.item(named: MetaTools.invokeName)!.canToggle, "元工具只读")
        XCTAssertFalse(ToolDrawerCatalog.item(named: ToolRegistry.serverWebSearchName)!.canTuck, "服务端搜索不能收起")
        XCTAssertTrue(ToolDrawerCatalog.item(named: FileLibraryTools.Name.delete.rawValue)!.canTuck)
    }

    func testCatalogSummaryUsesNameVariables() {
        let item = ToolDrawerCatalog.item(named: NotifyTool.toolName)!
        let text = ToolDrawerCatalog.summary(item, assistantName: "阿花", userName: "小草")
        XCTAssertTrue(text.contains("阿花") && text.contains("小草"), text)
        for item in ToolDrawerCatalog.items {
            let rendered = ToolDrawerCatalog.summary(item, assistantName: "A", userName: "U")
            XCTAssertFalse(rendered.contains("{char}") || rendered.contains("{user}"), item.name)
        }
    }

    // MARK: 缓存提示（工具签名）

    func testSignatureIgnoresOrderAndFlagsAnyChange() {
        let a: [[String: Any]] = [["name": "fs_read"], ["type": "function", "function": ["name": "ask_user"]], ["type": "web_search_20250305", "name": "web_search"]]
        let offered: Set<String> = ["fs_read", "ask_user", "ocr_image", "device_info"]   // clientToolNames 不含服务端 web_search
        let sig = ToolSignature(tools: a, offered: offered)
        XCTAssertEqual(sig.tools, ["ask_user", "fs_read", "web_search"], "按名字排")
        XCTAssertEqual(sig.catalog, ["device_info", "ocr_image"], "清单外调得到的")
        XCTAssertEqual(sig, ToolSignature(tools: a.reversed(), offered: offered))
        XCTAssertFalse(ToolDrawerStore.cacheBreaks(sent: sig, next: sig), "一样 → 不提示")
        XCTAssertFalse(ToolDrawerStore.cacheBreaks(sent: nil, next: sig), "没有上次记录（重启后）→ 不提示")
        XCTAssertTrue(ToolDrawerStore.cacheBreaks(sent: sig, next: ToolSignature(tools: Array(a.dropFirst()), offered: offered)), "关一个")
        XCTAssertTrue(ToolDrawerStore.cacheBreaks(sent: sig, next: ToolSignature(tools: a, offered: offered.subtracting(["ocr_image"]))), "收起的变了")
        XCTAssertTrue(ToolDrawerStore.cacheBreaks(sent: sig, next: ToolSignature(tools: a, offered: offered.union(["mcp_x"]))),
                      "收进目录的 MCP 变了（astra #5）")
    }

    func testRecordSentIsPerConversationInMemory() throws {
        let suite = "ToolDrawerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ToolDrawerStore(defaults: defaults)
        let sig = ToolSignature(tools: [["name": "fs_read"]], offered: ["fs_read"])
        store.recordSent(conversationId: "c1", signature: sig)
        XCTAssertEqual(store.sentSignature(conversationId: "c1"), sig)
        XCTAssertNil(store.sentSignature(conversationId: "c2"))
        XCTAssertNil(ToolDrawerStore(defaults: defaults).sentSignature(conversationId: "c1"), "不落盘")
    }

    func testPreviewCountsAndRoughTokens() {
        let tools: [[String: Any]] = [["name": "fs_read", "description": "读文件"], ["name": "tool_invoke", "description": "调"]]
        let p = ToolDrawerPreview(tools: tools, systemHint: "〔更多工具〕……", tucked: ["ocr_image"],
                                  offered: ["fs_read", "tool_invoke", "ocr_image"], absentReason: nil, modelName: "m")
        XCTAssertEqual(p.signature.catalog, ["ocr_image"])
        XCTAssertEqual(p.toolCount, 2)
        XCTAssertEqual(p.tuckedCount, 1)
        XCTAssertGreaterThan(p.definitionTokens, 0)
        XCTAssertGreaterThan(p.hintTokens, 0)
        let none = ToolDrawerPreview(tools: nil, systemHint: "", tucked: [], offered: nil, absentReason: .masterOff, modelName: "m")
        XCTAssertEqual(none.toolCount + none.definitionTokens + none.hintTokens, 0)
    }

    // MARK: 数据层

    func testFloorOverrideBeatsGlobalAndResetFollowsGlobal() {
        var s = ToolDrawerState.defaults
        XCTAssertNil(s.override("fs_write", profileId: "p1"), "没改过 = 用注册表默认")
        s.set(.off, for: "fs_write", profileId: nil)
        XCTAssertEqual(s.override("fs_write", profileId: "p1"), .off, "楼层没改过跟随全局")
        XCTAssertEqual(s.override("fs_write", profileId: nil), .off)
        s.set(.tucked, for: "fs_write", profileId: "p1")
        XCTAssertEqual(s.override("fs_write", profileId: "p1"), .tucked, "本楼层覆盖优先")
        XCTAssertEqual(s.override("fs_write", profileId: "p2"), .off, "别的楼层不受影响")
        XCTAssertEqual(s.floorOverride("fs_write", profileId: "p1"), .tucked)
        s.set(nil, for: "fs_write", profileId: "p1")
        XCTAssertEqual(s.override("fs_write", profileId: "p1"), .off, "恢复跟随全局")
        XCTAssertNil(s.floors["p1"], "楼层空了整条删掉")
        s.set(nil, for: "fs_write", profileId: nil)
        XCTAssertEqual(s, .defaults)
    }

    func testJSONRoundTripAndUnknownValuesIgnored() throws {
        var s = ToolDrawerState.defaults
        s.set(.off, for: "fs_write", profileId: nil)
        s.set(.inline, for: "fs_delete", profileId: "p1")
        XCTAssertEqual(ToolDrawerState.decoded(s.encoded()), s)
        let raw = #"{"global":{"fs_write":"off","gone_tool":"off","fs_read":"sideways"},"floors":{"p1":{"x":"nope"},"p2":{"fs_read":"tucked"}}}"#
        let d = ToolDrawerState.decoded(Data(raw.utf8))
        XCTAssertEqual(d.global, ["fs_write": .off, "gone_tool": .off], "不认识的档位丢掉；不认识的名字留着无害（解析时查不到它）")
        XCTAssertNil(d.floors["p1"], "整楼层都是坏值 → 不留空壳")
        XCTAssertEqual(d.floors["p2"], ["fs_read": .tucked])
        XCTAssertEqual(ToolDrawerState.decoded(Data("not json".utf8)), .defaults)
        XCTAssertEqual(ToolDrawerState.decoded(nil), .defaults)
    }

    func testStorePersistsAndReloads() throws {
        let suite = "ToolDrawerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ToolDrawerStore(defaults: defaults)
        XCTAssertEqual(store.state, .defaults)
        let v0 = store.version
        store.update { $0.set(.off, for: "fs_write", profileId: nil) }
        XCTAssertEqual(store.version, v0 + 1)
        store.update { $0.set(.off, for: "fs_write", profileId: nil) }
        XCTAssertEqual(store.version, v0 + 1, "没变不加版本")
        XCTAssertEqual(ToolDrawerStore(defaults: defaults).state.global["fs_write"], .off, "写回 defaults")
        store.update { $0 = .defaults }
        XCTAssertNil(defaults.object(forKey: ToolDrawerStore.defaultsKey), "回到默认就删键")
        defaults.set(#"{"global":{"recall":"off"},"floors":{}}"#.data(using: .utf8), forKey: ToolDrawerStore.defaultsKey)
        store.reload()
        XCTAssertEqual(store.state.global["recall"], .off)
    }
}
