import XCTest
import SwiftData
@testable import 记忆花园

/// 卡库 ③-4：有效身份三级取值 / 找不到退回 / 宏只展开副本 / 身份的书进有效集合 / Profile.personaId 缺键与备份往返。
/// 全部值模型 + 内存容器 + 临时目录，不碰真实存储。
@MainActor
final class PersonaContextTests: XCTestCase {

    private func persona(_ id: String, _ name: String, _ description: String = "", refs: [String] = []) -> UserPersona {
        UserPersona(id: id, name: name, description: description, worldSourceRefs: refs)
    }

    private func floor(personaId: String? = nil) -> Profile {
        var profile = Profile(id: "f1", name: "楼", emoji: "", description: "", userName: "禾禾", assistantName: "小岚",
                              systemPrompt: "你是{{char}}", userPersona: "楼层原身份")
        profile.personaId = personaId
        return profile
    }

    private func entry(_ content: String) -> WorldBookEntry {
        var entry = WorldBookEntry()
        entry.content = content
        entry.isConstant = true
        return entry
    }

    // MARK: - 三级取值与退回

    func testConversationThenFloorThenFloorText() {
        let a = persona("a", "阿禾", "身份A"), b = persona("b", "小禾", "身份B")
        let conversation = PersonaResolution.resolve(conversationPersonaId: "a", floorPersonaId: "b", personas: [a, b])
        XCTAssertEqual(conversation.level, .conversation)
        XCTAssertEqual(conversation.persona?.id, "a")
        XCTAssertEqual(conversation.notes, [])

        let floorLevel = PersonaResolution.resolve(conversationPersonaId: nil, floorPersonaId: "b", personas: [a, b])
        XCTAssertEqual(floorLevel.level, .floor)
        XCTAssertEqual(floorLevel.persona?.id, "b")

        let text = PersonaResolution.resolve(conversationPersonaId: nil, floorPersonaId: nil, personas: [a, b])
        XCTAssertEqual(text.level, .floorText)
        XCTAssertNil(text.persona)
        XCTAssertEqual(text.summary, "身份：楼层原本的身份")

        let empty = PersonaResolution.resolve(conversationPersonaId: "", floorPersonaId: "", personas: [a])
        XCTAssertEqual(empty.level, .floorText)
        XCTAssertEqual(empty.notes, [], "空串当没指定，不报找不到")
    }

    func testMissingPersonaFallsBackWithReason() {
        let b = persona("b", "小禾")
        let toFloor = PersonaResolution.resolve(conversationPersonaId: "gone-1234567", floorPersonaId: "b", personas: [b])
        XCTAssertEqual(toFloor.level, .floor)
        XCTAssertEqual(toFloor.notes.count, 1)
        XCTAssertTrue(toFloor.notes[0].contains("这个对话指定的身份找不到了"))
        XCTAssertTrue(toFloor.notes[0].contains("gone-123"))

        let toText = PersonaResolution.resolve(conversationPersonaId: "gone", floorPersonaId: "gone-too", personas: [b])
        XCTAssertEqual(toText.level, .floorText)
        XCTAssertEqual(toText.notes.count, 2)
        XCTAssertTrue(toText.notes[1].contains("楼层指定的身份找不到了"))
    }

    // MARK: - 套到楼层副本：名字 / 描述换，原楼层与原文不动

    func testAppliedCopyChangesOnlyNameAndDescription() {
        let profile = floor(personaId: "a")
        let resolution = PersonaResolution.resolve(conversationPersonaId: nil, floorPersonaId: "a", personas: [persona("a", "阿禾", "身份A")])
        let effective = resolution.applied(to: profile)
        XCTAssertEqual(effective.userName, "阿禾")
        XCTAssertEqual(effective.userPersona, "身份A")
        XCTAssertEqual(profile.userName, "禾禾", "楼层原有身份文本不动")
        XCTAssertEqual(profile.userPersona, "楼层原身份")
        var expected = profile
        expected.userName = "阿禾"
        expected.userPersona = "身份A"
        XCTAssertEqual(effective, expected, "别的字段一个不变")

        let nameless = PersonaResolution.resolve(conversationPersonaId: "n", floorPersonaId: nil, personas: [persona("n", "", "只有描述")])
        XCTAssertEqual(nameless.applied(to: profile).userName, "禾禾", "身份没名字沿用楼层名字")
        XCTAssertEqual(nameless.applied(to: profile).userPersona, "只有描述")
        XCTAssertNil(nameless.displayUserName)

        let none = PersonaResolution.resolve(conversationPersonaId: nil, floorPersonaId: nil, personas: [])
        XCTAssertEqual(none.applied(to: profile), profile)
    }

    func testUserMacroExpandsInCopyOnly() {
        let raw = "{{user}}，{{char}}在等你。{{User}}"
        let node = MessageNode(id: "n1", role: "assistant", content: raw, contentType: "text", createTime: nil,
                               parentId: nil, childrenIds: [], conversationId: "c1")
        let effective = PersonaResolution.resolve(conversationPersonaId: "a", floorPersonaId: nil,
                                                  personas: [persona("a", "阿禾")]).applied(to: floor())
        let names = EffectiveCharacterContext(profile: effective, defaults: UserDefaults(suiteName: "PersonaContextTests.\(UUID())")!)
        XCTAssertEqual(names.expand(node.content), "阿禾，小岚在等你。阿禾")
        XCTAssertEqual(node.content, raw, "消息原文不变")
        XCTAssertEqual(effective.systemPrompt, "你是{{char}}", "模板不变，展开只在发送副本")
    }

    // MARK: - 身份的书进有效集合

    func testPersonaBooksJoinEffectiveSetAndMissingAreReported() throws {
        let sharedRaw = Data("lore-v1".utf8)
        let current = WorldBook(name: "Lore", profileId: "f1", entries: [entry("本楼层 Lore")])
        current.rawJSONData = sharedRaw
        let copyElsewhere = WorldBook(name: "Lore", profileId: "f2", entries: [entry("别的楼层同一本 Lore")])
        copyElsewhere.rawJSONData = sharedRaw
        let otherFloor = WorldBook(name: "Diary", profileId: "f2", entries: [entry("别的楼层的身份书")])
        otherFloor.rawJSONData = Data("diary".utf8)
        let byId = [copyElsewhere.id: copyElsewhere, otherFloor.id: otherFloor]

        var disabled = GlobalWorldBook(name: "Persona", entries: [entry("身份全局书")], isEnabled: false)
        disabled.rawJSONData = Data("persona".utf8)
        let enabled = GlobalWorldBook(name: "Open", entries: [entry("开着的全局书")], isEnabled: true)
        var named = GlobalWorldBook(name: "Later", entries: [entry("后来导入的书")], isEnabled: false)
        named.rawJSONData = Data("later".utf8)
        var dupA = GlobalWorldBook(name: "Dup", entries: [entry("dupA")], isEnabled: false)
        dupA.rawJSONData = Data("dupA".utf8)
        var dupB = GlobalWorldBook(name: "Dup", entries: [entry("dupB")], isEnabled: false)
        dupB.rawJSONData = Data("dupB".utf8)
        let handMade = GlobalWorldBook(name: "Hand", entries: [entry("手写的同名书")], isEnabled: false)

        let refs = ["floor:\(copyElsewhere.id.uuidString)", "floor:\(otherFloor.id.uuidString)", "global:\(disabled.id)",
                    "global:\(enabled.id)", "global:gone", "floor:\(UUID().uuidString)", "name:Later", "name:Dup", "name:Nope",
                    "name:Hand", "weird"]
        let resolution = PersonaResolution.resolve(conversationPersonaId: "p", floorPersonaId: nil,
                                                   personas: [persona("p", "阿禾", "身份A", refs: refs)])
        let context = SendContextResolver.combine(
            profile: floor(), persona: resolution, floorBooks: [current], globalEntries: enabled.entries,
            globalBooks: [disabled, enabled, named, dupA, dupB, handMade],
            bookById: { byId[$0] }, booksNamed: { _ in [] })

        XCTAssertEqual(context.worldBooks.map(\.id), [current.id, otherFloor.id], "同内容副本只进一份；别的楼层的身份书进来")
        XCTAssertEqual(context.globalEntries.map(\.content), ["开着的全局书", "身份全局书", "后来导入的书"],
                       "开着的不重复；关着的按身份注入；name: 唯一已导入的书解析到")
        XCTAssertEqual(context.profile.userName, "阿禾")
        let notes = context.personaBookNotes.joined(separator: "\n")
        XCTAssertTrue(notes.contains("找不到了（全局 gone）"))
        XCTAssertTrue(notes.contains("找不到了（楼层"))
        XCTAssertTrue(notes.contains("「Dup」有 2 本同名内容不同"))
        XCTAssertTrue(notes.contains("「Nope」还没导入"))
        XCTAssertTrue(notes.contains("「Hand」还没导入"), "没原文的手写书不算已导入")
        XCTAssertTrue(notes.contains("认不出"))
        XCTAssertTrue(notes.contains("「Open」：已是开着的全局书"))
        XCTAssertEqual(context.inspectorLines.first, "身份：阿禾（这个对话指定）")
    }

    func testNoPersonaKeepsBooksExactly() {
        let book = WorldBook(name: "Lore", profileId: "f1", entries: [entry("x")])
        let resolution = PersonaResolution.resolve(conversationPersonaId: nil, floorPersonaId: nil, personas: [])
        let profile = floor()
        let context = SendContextResolver.combine(profile: profile, persona: resolution, floorBooks: [book], globalEntries: [entry("g")],
                                                  globalBooks: [], bookById: { _ in nil }, booksNamed: { _ in [] })
        XCTAssertEqual(context.worldBooks.map(\.id), [book.id])
        XCTAssertEqual(context.globalEntries.map(\.content), ["g"])
        XCTAssertEqual(context.profile, profile)
        XCTAssertEqual(context.personaBookNotes, [])
    }

    /// 走真 ModelContext：对话范围过滤、对话身份优先、别的楼层的身份书按 id 取到
    func testResolveWithStoreScopesBooksAndPicksConversationPersona() throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let floorWide = WorldBook(name: "楼层书", profileId: "f1", entries: [entry("楼层")])
        let thisChat = WorldBook(name: "本对话", profileId: "f1", entries: [entry("本对话")])
        thisChat.scopeConversationId = "c1"
        let otherChat = WorldBook(name: "别的对话", profileId: "f1", entries: [entry("别的对话")])
        otherChat.scopeConversationId = "c2"
        let personaBook = WorldBook(name: "身份书", profileId: "f9", entries: [entry("身份")])
        [floorWide, thisChat, otherChat, personaBook].forEach(context.insert)
        let conversation = Conversation(id: "c1", title: "t", createTime: Date(), updateTime: Date(), currentNodeId: "")
        conversation.personaId = "a"
        context.insert(conversation)
        try context.save()

        let personas = [persona("a", "阿禾", refs: ["floor:\(personaBook.id.uuidString)"]), persona("b", "楼层身份")]
        let resolved = SendContextResolver.resolve(profile: floor(personaId: "b"), conversation: conversation, context: context,
                                                   globalEntries: [], globalBooks: [], personas: personas)
        XCTAssertEqual(resolved.persona.level, .conversation)
        XCTAssertEqual(resolved.profile.userName, "阿禾")
        XCTAssertEqual(Set(resolved.worldBooks.map(\.name)), ["楼层书", "本对话", "身份书"])

        let noConversation = SendContextResolver.resolve(profile: floor(personaId: "b"), conversation: nil, context: context,
                                                         globalEntries: [], globalBooks: [], personas: personas)
        XCTAssertEqual(noConversation.persona.level, .floor)
        XCTAssertEqual(noConversation.profile.userName, "楼层身份")
        XCTAssertEqual(noConversation.worldBooks.map(\.name), ["楼层书"])
    }

    // MARK: - Profile.personaId：缺键 nil / 往返 / nil 不写键

    func testProfilePersonaIdDecodesMissingAsNilAndRoundTrips() throws {
        var profile = floor(personaId: "p-1")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertEqual(object["personaId"] as? String, "p-1")
        object.removeValue(forKey: "personaId")
        let old = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.personaId, "旧数据缺键读成 nil")

        profile.personaId = nil
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        XCTAssertNil(encoded["personaId"], "nil 不写键：旧楼层编码不变，导入首次 hash 照旧对得上")
    }

    /// 全量备份：savedProfiles → profiles.json（JSONSerialization 美化）→ 恢复写回（JSONSerialization 再序列化）→ 楼层管理器读
    func testProfilePersonaIdSurvivesFullBackupJSONPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("persona-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "PersonaContextTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = [floor(personaId: "p-1"), Profile(id: "f2", name: "无身份", emoji: "", description: "", userName: "你", assistantName: "助手")]

        let exported = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles)),
                                                  options: [.prettyPrinted, .sortedKeys])
        let restored = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: exported), options: [])
        try BlobStore.set(restored, forKey: "savedProfiles", root: dir)
        let loaded = ProfileManager.loadProfiles(root: dir, defaults: defaults)
        XCTAssertEqual(loaded.map(\.personaId), ["p-1", nil])
        XCTAssertEqual(loaded, profiles)
    }
}
