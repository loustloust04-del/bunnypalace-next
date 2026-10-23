import XCTest
import SwiftData
@testable import 记忆花园

/// ⑤b 正则页：全局存储 / 阶段 ↔ 旧 flags / 深度 ↔ maxDepth / 分组 / 测试区与生产同引擎
final class RegexLibraryTests: XCTestCase {

    private func rule(_ id: String, find: String = "/X/g", replace: String = "", placement: [Int] = [1, 2],
                      display: Bool = false, send: Bool = false, disabled: Bool = false) -> RegexScript {
        var s = RegexScript()
        s.id = id
        s.scriptName = id
        s.findRegex = find
        s.replaceString = replace
        s.placement = placement
        s.markdownOnly = display
        s.promptOnly = send
        s.disabled = disabled
        return s
    }

    private func profile(id: String = "floor", rules: [RegexScript] = []) -> Profile {
        var p = Profile(id: id, name: "河岸", emoji: "🧪", description: "", userName: "禾禾", assistantName: "小岚")
        p.regexScripts = rules
        return p
    }

    private func preset(rules: [RegexScript]) -> Preset {
        var p = Preset(name: "河岸叙事")
        p.regexScripts = rules
        return p
    }

    private func card(boundTo profileId: String?, consent: CharacterCard.ExtensionConsent, rules: [RegexScript]) -> CharacterCard {
        var c = CharacterCard(name: "白石", description: "", personality: "", scenario: "", firstMes: "")
        c.linkedProfileId = profileId
        c.bindingState = profileId == nil ? .unbound : .active
        c.extensionConsent = consent
        c.regexScripts = rules
        return c
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "RegexLibraryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: - 全局存储

    func testGlobalStoreMissingKeyIsEmptyAndRoundTripsInOrder() throws {
        try withDefaults { defaults in
            let store = GlobalRegexStore(defaults: defaults)
            XCTAssertEqual(store.scripts, [])
            XCTAssertNil(defaults.data(forKey: "globalRegexScripts_v1"))
            try store.save([rule("g2"), rule("g1")])
            XCTAssertEqual(store.scripts.map(\.id), ["g2", "g1"])
            XCTAssertNotNil(defaults.data(forKey: GlobalRegexStore.storageKey))
            XCTAssertEqual(GlobalRegexStore(defaults: defaults).scripts, [rule("g2"), rule("g1")])
        }
    }

    func testCorruptGlobalStoreRefusesOverwrite() throws {
        try withDefaults { defaults in
            let garbage = Data("不是 JSON".utf8)
            defaults.set(garbage, forKey: GlobalRegexStore.storageKey)
            let store = GlobalRegexStore(defaults: defaults)
            XCTAssertEqual(store.scripts, [])
            XCTAssertThrowsError(try store.save([rule("g")]))
            XCTAssertEqual(defaults.data(forKey: GlobalRegexStore.storageKey), garbage)
        }
    }

    func testGlobalRulesEnterPipelineFirst() throws {
        try withDefaults { defaults in
            let store = GlobalRegexStore(defaults: defaults)
            try store.save([rule("g1"), rule("g2")])
            let prof = profile(rules: [rule("old")])
            let pre = preset(rules: [rule("p1")])
            let bound = card(boundTo: prof.id, consent: .allowed, rules: [rule("c1")])
            let resolved = RegexPipeline.resolve(global: store.scripts, profile: prof, preset: pre, cards: [bound])
            XCTAssertEqual(resolved.map(\.script.id), ["g1", "g2", "p1", "c1"])
            XCTAssertEqual(resolved.first?.source, .global)
            XCTAssertEqual(RegexPipeline.scripts(profile: prof, preset: pre, cards: [bound], global: store.scripts).map(\.id),
                           ["g1", "g2", "p1", "c1"])
            // 没绑卡：全局仍排第一，楼层旧规则殿后
            XCTAssertEqual(RegexPipeline.scripts(profile: prof, preset: nil, cards: [], global: store.scripts).map(\.id),
                           ["g1", "g2", "old"])
        }
    }

    // MARK: - 阶段 ↔ 旧 flags

    func testPhaseFlagMappingRoundTripsLegalCombos() throws {
        let legal: [(Set<RegexPhase>, Bool, Bool)] = [
            ([.display], true, false), ([.send], false, true), ([.input], false, false), ([.display, .send], true, true),
        ]
        for (phases, markdownOnly, promptOnly) in legal {
            let flags = try RegexLibrary.flags(for: phases).get()
            XCTAssertEqual(flags.markdownOnly, markdownOnly, "\(phases)")
            XCTAssertEqual(flags.promptOnly, promptOnly, "\(phases)")
            XCTAssertEqual(rule("r", display: flags.markdownOnly, send: flags.promptOnly).phases, phases)
        }
    }

    func testPhaseFlagMappingRejectsUnsupportedCombos() {
        for phases: Set<RegexPhase> in [[.display, .input], [.send, .input], [.display, .send, .input]] {
            guard case .failure(let error) = RegexLibrary.flags(for: phases) else { return XCTFail("\(phases) 不该通过") }
            XCTAssertEqual(error, .unsupported)
            XCTAssertEqual(error.message, "这个组合暂时不支持")
        }
        guard case .failure(let error) = RegexLibrary.flags(for: []) else { return XCTFail("空阶段不该通过") }
        XCTAssertEqual(error, .empty)
    }

    // MARK: - 深度 ↔ maxDepth

    func testRecentCountMapsToMaxDepth() {
        XCTAssertNil(RegexLibrary.recentCount(maxDepth: nil))
        XCTAssertNil(RegexLibrary.recentCount(maxDepth: -1))
        XCTAssertEqual(RegexLibrary.recentCount(maxDepth: 0), 1)
        XCTAssertEqual(RegexLibrary.recentCount(maxDepth: 5), 6)
        XCTAssertNil(RegexLibrary.maxDepth(recentCount: nil))
        XCTAssertNil(RegexLibrary.maxDepth(recentCount: 0))
        XCTAssertEqual(RegexLibrary.maxDepth(recentCount: 1), 0)
        XCTAssertEqual(RegexLibrary.maxDepth(recentCount: 6), 5)
        // 最近 6 条 = 深度 0…5：第 6 条（深度 5）还改，第 7 条（深度 6）不改
        var r = rule("d", send: true)
        r.maxDepth = RegexLibrary.maxDepth(recentCount: 6)
        XCTAssertEqual(RegexPipeline.eligible([r], phase: .send, placement: 2, depth: 5).count, 1)
        XCTAssertEqual(RegexPipeline.eligible([r], phase: .send, placement: 2, depth: 6).count, 0)
    }

    // MARK: - 不执行的 placement / 分组

    func testUnsupportedPlacementsFlagged() {
        XCTAssertFalse(RegexLibrary.hasUnsupportedPlacement(rule("a", placement: [1, 2, 5])))
        for p in [0, 3, 4, 6] {
            XCTAssertTrue(RegexLibrary.hasUnsupportedPlacement(rule("b", placement: [2, p])), "placement \(p)")
        }
    }

    func testGroupsFollowPipelineOwners() {
        let prof = profile(rules: [rule("old")])
        let pre = preset(rules: [rule("p1")])
        let bound = card(boundTo: prof.id, consent: .unknown, rules: [rule("c1"), rule("c2")])
        let withCard = RegexLibrary.groups(global: [rule("g1"), rule("g2")], profile: prof, preset: pre,
                                           cards: [card(boundTo: nil, consent: .allowed, rules: [rule("x")]), bound])
        XCTAssertEqual(withCard.map(\.owner), [.global, .preset(id: pre.id), .card(id: bound.id)])
        XCTAssertEqual(withCard.map(\.title), ["全局 · 2 条", "预设 · 河岸叙事 · 1 条", "角色卡 · 白石 · 2 条"])
        XCTAssertFalse(withCard[2].cardAllowed)
        XCTAssertEqual(withCard[2].rules.map(\.id), ["c1", "c2"])

        let noCard = RegexLibrary.groups(global: [], profile: prof, preset: nil, cards: [])
        XCTAssertEqual(noCard.map(\.owner), [.global, .profile(id: prof.id)])
        XCTAssertEqual(noCard.map(\.title), ["全局 · 0 条", "楼层 · 河岸 · 1 条"])
        XCTAssertTrue(noCard[1].cardAllowed)
    }

    // MARK: - 测试区与生产同引擎

    func testPreviewMatchesProductionPipeline() {
        let rules = [
            rule("display", find: "/（旁白：([^）]+)）/g", replace: "「$1」", placement: [2], display: true),
            rule("send", find: "/\\s+$/gm", replace: "", placement: [1, 2], send: true),
            rule("input", find: "/旁白/g", replace: "{{user}}", placement: [1]),
            rule("both", find: "/(好)+/g", replace: "{{match}}!", placement: [1, 2], display: true, send: true),
        ]
        let text = "（旁白：河水慢慢流过去。） {{char}} 好好  "
        for r in rules {
            let phase: RegexPhase = r.phases.contains(.display) ? .display : (r.phases.contains(.send) ? .send : .input)
            for placement in [1, 2] {
                let production = RegexPipeline.run([r], text: text, phase: phase, placement: placement,
                                                   userName: "禾禾", charName: "小岚")
                XCTAssertEqual(RegexLibrary.preview(r, text: text, placement: placement, userName: "禾禾", charName: "小岚"),
                               production, "\(r.id) @ \(placement)")
            }
        }
        XCTAssertEqual(RegexLibrary.preview(rules[0], text: "（旁白：河水慢慢流过去。）", placement: 2), "「河水慢慢流过去。」")
        // 关着的规则也能试；结果等于它开着时生产链的结果
        var off = rules[0]
        off.disabled = true
        XCTAssertEqual(RegexLibrary.preview(off, text: text, placement: 2),
                       RegexPipeline.run([rules[0]], text: text, phase: .display, placement: 2))
        // placement 不含所选消息：原样
        XCTAssertEqual(RegexLibrary.preview(rules[0], text: text, placement: 1), text)
    }

    func testCompileErrorUsesEngineParser() {
        XCTAssertNotNil(RegexEngine.compileError(for: rule("bad", find: "/(未闭合/g")))
        XCTAssertNil(RegexEngine.compileError(for: rule("ok", find: "/a+/gi")))
        XCTAssertNil(RegexEngine.compileError(for: rule("empty", find: "")))
        var macro = rule("macro", find: "/{{char}}/g")
        macro.substituteRegex = 1
        XCTAssertNil(RegexEngine.compileError(for: macro, userName: "禾禾", charName: "小岚"))
    }
}

// MARK: - owner 写回

@MainActor
final class RegexLibraryOwnerTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let container: ModelContainer
        let global: GlobalRegexStore
        let cards: CharacterCardManager
        let profiles: ProfileManager
        let presets: PresetManager
        let store: RegexOwnerStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "RegexLibraryOwnerTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let schema = Schema([Conversation.self, MessageNode.self, WorldBook.self])
            container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            global = GlobalRegexStore(defaults: defaults)
            cards = CharacterCardManager(root: root.appendingPathComponent("cards"), defaults: defaults)
            var floor = Profile(id: "floor", name: "楼层", emoji: "", description: "", userName: "你", assistantName: "助手")
            floor.regexScripts = [Self.rule("old")]
            profiles = ProfileManager(container: container, profiles: [floor], currentProfile: floor, loadError: nil,
                                      root: root.appendingPathComponent("blobs"), defaults: defaults, sideEffectsEnabled: false)
            presets = PresetManager(root: root.appendingPathComponent("blobs"), defaults: defaults)
            profiles.characterCardManager = cards
            store = RegexOwnerStore(global: global, presets: presets, cards: cards, profiles: profiles)
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        static func rule(_ id: String, find: String = "/X/g") -> RegexScript {
            var s = RegexScript()
            s.id = id
            s.scriptName = id
            s.findRegex = find
            return s
        }
    }

    func testWriteBackLandsInEachOwner() throws {
        let f = try Fixture(); defer { f.clean() }
        // 全局
        try f.store.upsert(Fixture.rule("g"), in: .global)
        XCTAssertEqual(GlobalRegexStore(defaults: f.defaults).scripts.map(\.id), ["g"])
        // 预设实例
        var instance = Preset(name: "实例")
        instance.id = "inst"
        instance.ownerProfileId = "floor"
        try f.presets.persistNew(instance)
        try f.store.upsert(Fixture.rule("p"), in: .preset(id: "inst"))
        XCTAssertEqual(PresetManager(root: f.root.appendingPathComponent("blobs"), defaults: f.defaults).preset(byId: "inst")?.regexScripts.map(\.id), ["p"])
        // 卡
        var card = CharacterCard(name: "白石", description: "", personality: "", scenario: "", firstMes: "")
        card.regexScripts = [Fixture.rule("c")]
        try f.cards.add(card)
        try f.store.upsert(Fixture.rule("c", find: "/改过/g"), in: .card(id: card.id))
        let reloaded = CharacterCardManager(root: f.root.appendingPathComponent("cards"), defaults: f.defaults)
        XCTAssertEqual(reloaded.cards.first?.regexScripts.map(\.findRegex), ["/改过/g"])
        // 楼层旧规则
        try f.store.upsert(Fixture.rule("old", find: "/新/g"), in: .profile(id: "floor"))
        try f.store.upsert(Fixture.rule("added"), in: .profile(id: "floor"))
        XCTAssertEqual(f.profiles.profiles.first?.regexScripts.map(\.id), ["old", "added"])
        XCTAssertEqual(f.profiles.currentProfile.regexScripts.first?.findRegex, "/新/g")
        // 删除 + 开关
        try f.store.setEnabled(false, ruleId: "old", in: .profile(id: "floor"))
        XCTAssertEqual(f.profiles.currentProfile.regexScripts.first?.disabled, true)
        try f.store.delete(ruleId: "g", in: .global)
        try f.store.delete(ruleId: "p", in: .preset(id: "inst"))
        try f.store.delete(ruleId: "added", in: .profile(id: "floor"))
        XCTAssertEqual(f.global.scripts, [])
        XCTAssertEqual(f.presets.preset(byId: "inst")?.regexScripts, [])
        XCTAssertEqual(f.profiles.currentProfile.regexScripts.map(\.id), ["old"])
        XCTAssertThrowsError(try f.store.upsert(Fixture.rule("x"), in: .preset(id: "missing")))
    }

    func testCardSelfEditKeepsConsentDefaultUpdateStillResets() throws {
        let f = try Fixture(); defer { f.clean() }
        var card = CharacterCard(name: "白石", description: "", personality: "", scenario: "", firstMes: "")
        card.regexScripts = [Fixture.rule("c1"), Fixture.rule("c2")]
        try f.cards.add(card)
        try f.store.setConsent(.allowed, cardId: card.id)
        XCTAssertEqual(f.cards.cards[0].extensionConsent, .allowed)
        // 正则页自己改：规则变了，许可不动
        try f.store.upsert(Fixture.rule("c1", find: "/改/g"), in: .card(id: card.id))
        try f.store.setEnabled(false, ruleId: "c2", in: .card(id: card.id))
        try f.store.delete(ruleId: "c1", in: .card(id: card.id))
        XCTAssertEqual(f.cards.cards[0].extensionConsent, .allowed)
        XCTAssertEqual(f.cards.cards[0].regexScripts.map(\.id), ["c2"])
        XCTAssertEqual(f.cards.cards[0].regexScripts.first?.disabled, true)
        // 停用 = deferred；别的入口（默认 update）换了规则仍打回 unknown
        try f.store.setConsent(.deferred, cardId: card.id)
        XCTAssertEqual(f.cards.cards[0].extensionConsent, .deferred)
        var replaced = f.cards.cards[0]
        replaced.regexScripts = [Fixture.rule("外来")]
        try f.cards.update(replaced)
        XCTAssertEqual(f.cards.cards[0].extensionConsent, .unknown)
    }
}
