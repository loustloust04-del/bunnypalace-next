import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class CharacterFloorServiceTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let container: ModelContainer
        let cards: CharacterCardManager
        let profiles: ProfileManager
        let presets: PresetManager
        let service: CharacterFloorService

        init(corruptedKey: String? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "CharacterFloorServiceTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            if let corruptedKey { defaults.set(Data("损坏 JSON".utf8), forKey: corruptedKey) }
            let schema = Schema([Conversation.self, MessageNode.self, WorldBook.self])
            container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            cards = CharacterCardManager(root: root.appendingPathComponent("cards"), defaults: defaults)
            let initial = Profile(id: "original", name: "原楼层", emoji: "", description: "", userName: "你", assistantName: "助手")
            // 楼层列表损坏的错误来自启动那次加载（#037：管理器不再自己复读）
            let loadError = corruptedKey == "savedProfiles"
                ? ProfileManager.loadProfilesChecked(root: root.appendingPathComponent("blobs"), defaults: defaults).error : nil
            profiles = ProfileManager(container: container, profiles: [initial], currentProfile: initial, loadError: loadError,
                                      root: root.appendingPathComponent("blobs"), defaults: defaults, sideEffectsEnabled: false)
            presets = PresetManager(root: root.appendingPathComponent("blobs"), defaults: defaults)
            profiles.characterCardManager = cards
            service = CharacterFloorService(cards: cards, profiles: profiles, presets: presets)
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func card(greetings: [String] = [" 开场\r\n ", "备选", "备选"], book: Bool = false) throws -> CharacterCard {
            var data: [String: Any] = ["name": "测试角色", "first_mes": greetings.first ?? "",
                                       "alternate_greetings": Array(greetings.dropFirst())]
            if book { data["character_book"] = ["name": "书", "entries": [["keys": ["词"], "content": "内容", "enabled": true]]] }
            let raw = try JSONSerialization.data(withJSONObject: ["spec": "chara_card_v2", "spec_version": "2.0", "data": data])
            let value = CharacterCard(from: try TavernCard.parseJSON(data: raw))
            try cards.add(value)
            return value
        }

        func conversations(_ profileId: String) throws -> [Conversation] {
            try ModelContext(container).fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == profileId }))
        }
    }

    func testFirstEntryCreatesOneFloorNoChatAndReusesStaleCard() async throws {
        let f = try Fixture(); defer { f.clean() }
        let card = try f.card(book: true)
        let first = try await f.service.enter(card: card)
        let second = try await f.service.enter(card: card)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(f.profiles.profiles.count, 2)
        XCTAssertEqual(f.profiles.currentProfile.id, first.id)
        XCTAssertTrue(try f.conversations(first.id).isEmpty)
        XCTAssertEqual(f.cards.cards[0].bindingState, .active)
        XCTAssertEqual(f.cards.cards[0].linkedProfileId, first.id)
        let pid = first.id
        let context = ModelContext(f.container)
        let books = try context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == pid }))
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(first.linkedWorldBookIDs, books.map { $0.id.uuidString })
        XCTAssertEqual(f.presets.presets.filter { $0.ownerProfileId == first.id }.count, 1)
        let restored = CharacterCardManager(root: f.root.appendingPathComponent("cards"), defaults: f.defaults)
        XCTAssertEqual(restored.cards[0].linkedProfileId, first.id)
    }

    func testDoubleEntrySharesInFlightTask() async throws {
        let f = try Fixture(); defer { f.clean() }
        let card = try f.card()
        async let first = f.service.enter(card: card)
        async let second = f.service.enter(card: card)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(f.profiles.profiles.count, 2)
        XCTAssertTrue(try f.conversations(a.id).isEmpty)
    }

    func testDeletingFloorMarksMissingAndDoesNotRecreate() async throws {
        let f = try Fixture(); defer { f.clean() }
        let card = try f.card()
        let profile = try await f.service.enter(card: card)
        f.profiles.deleteProfile(profile, deleteData: false)
        XCTAssertEqual(f.cards.cards[0].bindingState, .missing)
        do { _ = try await f.service.enter(card: card); XCTFail("不能重建") }
        catch { XCTAssertEqual(error.localizedDescription, "这个楼层已经不在了") }
        XCTAssertEqual(f.profiles.profiles.count, 1)
    }

    func testDanglingActiveBindingIsSavedAsMissing() async throws {
        let f = try Fixture(); defer { f.clean() }
        var card = try f.card()
        card.bindingState = .active
        card.linkedProfileId = "deleted"
        try f.cards.update(card)
        do { _ = try await f.service.enter(card: card); XCTFail("不能重建") } catch {}
        XCTAssertEqual(f.cards.cards[0].bindingState, .missing)
        XCTAssertEqual(f.profiles.profiles.count, 1)
    }

    /// #037：楼层列表读坏（内存是 seed）时，绑定楼层不在列表里≠楼层没了，不能把卡标成 missing
    func testReadOnlyProfilesDoNotMarkActiveCardMissing() async throws {
        let f = try Fixture(corruptedKey: "savedProfiles"); defer { f.clean() }
        XCTAssertTrue(f.profiles.isReadOnly)
        var card = try f.card()
        card.bindingState = .active
        card.linkedProfileId = "her-real-floor"
        try f.cards.update(card)
        do { _ = try await f.service.enter(card: card); XCTFail("只读必须拒绝") }
        catch { XCTAssertTrue(error is ProfileManager.ReadOnlyError, "\(error)") }
        XCTAssertEqual(f.cards.cards[0].bindingState, .active)
        XCTAssertEqual(f.cards.cards[0].linkedProfileId, "her-real-floor")
        let reloaded = CharacterCardManager(root: f.root.appendingPathComponent("cards"), defaults: f.defaults)
        XCTAssertEqual(reloaded.cards.first?.bindingState, .active, "盘上也没被标 missing")
    }

    func testCardSaveFailureRollsBackFloorBookAndPreset() async throws {
        let f = try Fixture(); defer { f.clean() }
        let card = try f.card(book: true)
        let path = f.root.appendingPathComponent("cards")
        try FileManager.default.removeItem(at: path)
        try Data("阻止写入".utf8).write(to: path)
        do { _ = try await f.service.enter(card: card); XCTFail("必须抛错") } catch {}
        XCTAssertEqual(f.profiles.profiles.map(\.id), ["original"])
        XCTAssertEqual(f.profiles.currentProfile.id, "original")
        XCTAssertEqual(f.cards.cards[0].bindingState, .unbound)
        XCTAssertNil(f.cards.cards[0].linkedProfileId)
        XCTAssertTrue(f.presets.presets.allSatisfy { $0.ownerProfileId == nil })
        let stored = try XCTUnwrap(BlobStore.read(forKey: "savedProfiles", root: f.root.appendingPathComponent("blobs"), defaults: f.defaults))
        XCTAssertEqual(try JSONDecoder().decode([Profile].self, from: stored).map(\.id), ["original"])
        // 按 profileId 查新增范围，测试也不扫描真实库。
        let original = "original"
        XCTAssertEqual(try ModelContext(f.container).fetchCount(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId != original })), 0)
    }

    func testPresetAndProfileStorageErrorsLeaveNoPublishedFloor() async throws {
        for corruptedKey in ["savedPresets", "savedProfiles"] {
            let f = try Fixture(corruptedKey: corruptedKey); defer { f.clean() }
            let card = try f.card(book: true)
            do { _ = try await f.service.enter(card: card); XCTFail("必须抛错") } catch {}
            XCTAssertEqual(f.profiles.profiles.map(\.id), ["original"])
            XCTAssertEqual(f.profiles.currentProfile.id, "original")
            XCTAssertEqual(f.cards.cards[0].bindingState, .unbound)
            XCTAssertTrue(f.presets.presets.allSatisfy { $0.ownerProfileId == nil })
            let original = "original"
            XCTAssertEqual(try ModelContext(f.container).fetchCount(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId != original })), 0)
        }
    }

    func testPresetOverridesRespectForbiddenAndBlankValues() async throws {
        let f = try Fixture(); defer { f.clean() }
        var template = Preset.balanced
        let main = try XCTUnwrap(template.prompts.firstIndex { $0.id == PromptSlot.mainId })
        template.prompts[main].content = "模板主指令"
        template.prompts[main].forbidOverrides = true
        f.presets.save(template)
        var card = try f.card()
        card.systemPrompt = "卡主指令"
        card.postHistoryInstructions = " \r\n"
        try f.cards.update(card)
        let profile = try await f.service.enter(card: card)
        let instance = try XCTUnwrap(f.presets.preset(byId: profile.presetId))
        XCTAssertEqual(instance.prompts[main].content, "模板主指令")
        XCTAssertEqual(instance.prompts.first { $0.id == PromptSlot.jailbreakId }?.content,
                       template.prompts.first { $0.id == PromptSlot.jailbreakId }?.content)
    }

    func testPersistNewDoesNotPublishOrSwitchDefaults() throws {
        let f = try Fixture(); defer { f.clean() }
        let value = Profile(id: "new", name: "新", emoji: "", description: "", userName: "你", assistantName: "角色")
        try f.profiles.persistNew(value)
        XCTAssertEqual(f.profiles.profiles.map(\.id), ["original"])
        XCTAssertEqual(f.profiles.currentProfile.id, "original")
        XCTAssertNil(f.defaults.string(forKey: "lastProfileId"))
        f.profiles.publish(value, activate: false)
        XCTAssertEqual(f.profiles.profiles.count, 2)
        XCTAssertEqual(f.profiles.currentProfile.id, "original")
    }

    func testLegacyCardDefaultsAndDoesNotMatchLegacyName() throws {
        let card = try JSONDecoder().decode(CharacterCard.self, from: Data(#"{"id":"old","name":"同名"}"#.utf8))
        XCTAssertEqual(card.bindingState, .unbound)
        XCTAssertEqual(card.extensionConsent, .unknown)
        XCTAssertNil(card.linkedProfileId)
        XCTAssertNil(card.archivedAt)
        var profile = Profile(id: "p", name: "同名", emoji: "", description: "", userName: "你", assistantName: "助手")
        profile.characterCardID = card.name
        XCTAssertEqual(CharacterWallItem.make(cards: [card], profiles: [profile]).map(\.id), ["old", "floor:p"])
    }

    func testOpeningTreesZeroOneThreeAndRepeatedBody() throws {
        for values in [[], [" 单条\r\n "], [" 开场 ", "重复", "重复"]] as [[String]] {
            let (conversation, nodes) = CharacterFloorService.makeChat(title: "角色", greetings: values, profileId: "p")
            XCTAssertEqual(conversation.nodeCount, values.count)
            XCTAssertTrue(nodes.allSatisfy { $0.profileId == "p" && $0.conversationId == conversation.id })
            if values.isEmpty {
                XCTAssertTrue(nodes.isEmpty)
                XCTAssertTrue(conversation.currentNodeId.isEmpty)
                continue
            }
            let root = try XCTUnwrap(nodes.first)
            XCTAssertTrue(root.isSyntheticRoot)
            XCTAssertEqual(root.role, "system")
            XCTAssertEqual(root.content, "")
            XCTAssertFalse(root.hasDisplayableContent)
            XCTAssertEqual(PromptAssembler.historyNodes(nodes).map(\.content), values)
            let children = Array(nodes.dropFirst())
            XCTAssertEqual(children.map(\.content), values)
            XCTAssertEqual(root.childrenIds, children.map(\.id))
            XCTAssertEqual(Set(children.map(\.id)).count, values.count)
            XCTAssertTrue(children.allSatisfy { $0.parentId == root.id && $0.role == "assistant" })
            XCTAssertEqual(conversation.currentNodeId, children[0].id)
            XCTAssertEqual(ConversationViewModel.computeMainPathSet(nodes: nodes, currentNodeId: conversation.currentNodeId), [children[0].id])
            XCTAssertEqual(FullNodeDocument(model: root).toNodeModel().isSyntheticRoot, true)
        }
    }

    func testBlankPrimaryUsesFirstNonblankAlternateWithoutTrimming() async throws {
        let f = try Fixture(); defer { f.clean() }
        let card = try f.card(greetings: [" \r\n", "", " 备选\r\n ", "备选"])
        let profile = try await f.service.enter(card: card)
        let conversation = try f.service.newChat(card: card)
        let pid = profile.id
        let cid = conversation.id
        let nodes = try ModelContext(f.container).fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.profileId == pid && $0.conversationId == cid }))
        XCTAssertEqual(nodes.first { $0.id == conversation.currentNodeId }?.content, " 备选\r\n ")
        XCTAssertEqual(try f.conversations(pid).count, 1)
        XCTAssertEqual(nodes.count, 3)
    }

    func testWallHasBoundCardAndUnboundFloorAndArchiveKeepsBinding() throws {
        var card = try JSONDecoder().decode(CharacterCard.self, from: Data(#"{"id":"card","name":"同名"}"#.utf8))
        card.bindingState = .active
        card.linkedProfileId = "original"
        let original = Profile(id: "original", name: card.name, emoji: "", description: "", userName: "你", assistantName: "助手")
        let extra = Profile(id: "extra", name: card.name, emoji: "", description: "", userName: "你", assistantName: "助手")
        let profiles = [original, extra]
        XCTAssertEqual(CharacterWallItem.make(cards: [card], profiles: profiles).map(\.id), [card.id, "floor:extra"])
        card.archivedAt = Date()
        XCTAssertEqual(CharacterWallItem.make(cards: [card], profiles: profiles).map(\.id), ["floor:extra"])
    }

    func testScriptsNewKeyWinsConsentResetAndBodyEditKeepsConsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CharacterConsentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let cards = CharacterCardManager(root: root, libraryRoot: root.appendingPathComponent("cardlibrary"), defaults: defaults)
        let raw = Data(#"{"data":{"name":"角色","extensions":{"tavern_helper":{"scripts":[{"id":"a"}]},"TavernHelper_scripts":[{"id":"b"}]}}}"#.utf8)
        var card = CharacterCard(from: try TavernCard.parseJSON(data: raw))
        // 有新键 tavern_helper 就不看旧键 TavernHelper_scripts（照酒馆助手）
        XCTAssertEqual(card.scriptCount, 1)
        card.extensionConsent = .allowed
        try cards.add(card)
        card.description = "只改描述"
        try cards.update(card)
        XCTAssertEqual(cards.cards[0].extensionConsent, .allowed)
        card.rawJSONData = Data(#"{"data":{"name":"角色","extensions":{"tavern_helper":{"scripts":[{"id":"changed"}]}}}}"#.utf8)
        try cards.update(card)
        XCTAssertEqual(cards.cards[0].extensionConsent, .unknown)
    }
    func testGreetingFilteringKeepsOrderAndExactText() throws {
        var card = try JSONDecoder().decode(CharacterCard.self, from: Data(#"{"name":"角色"}"#.utf8))
        card.firstMes = " \r\n"
        card.alternateGreetings = ["", " 第一条\r\n ", "重复", "重复", "\t"]
        XCTAssertEqual(card.greetings, [" 第一条\r\n ", "重复", "重复"])
    }

}
