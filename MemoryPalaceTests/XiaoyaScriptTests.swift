import XCTest
import SwiftData
@testable import 记忆花园

/// 引导剧本测试台：临时目录（history.json / script.json / 楼层 / 卡库 / 预设）+ 内存偏好 + 零延迟节奏。
/// 不碰真实 AssistantChat/、真实楼层列表；钥匙不走 CredentialCommitter（直接答 .keySaved），不碰钥匙串
@MainActor
final class XiaoyaScriptFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let container: ModelContainer
    let profiles: ProfileManager
    let presets: PresetManager
    let cards: CharacterCardManager
    let factory: OnboardingFloorFactory
    /// 默认头像落在临时目录（不碰真实 Application Support）
    let avatarStore: DefaultUserAvatar
    var engine: AssistantEngine
    var pushCount = 0
    var activeModel: String? = "gpt-4o-mini"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xiaoya-script-\(UUID().uuidString)")
        suite = "XiaoyaScriptTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let schema = Schema([Conversation.self, MessageNode.self, WorldBook.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let blobs = root.appendingPathComponent("blobs")
        let home = Profile.seedProfiles[0]
        profiles = ProfileManager(container: container, profiles: [home], currentProfile: home, loadError: nil,
                                  root: blobs, defaults: defaults, sideEffectsEnabled: false)
        presets = PresetManager(root: blobs, defaults: defaults)
        cards = CharacterCardManager(root: root.appendingPathComponent("cards"), defaults: defaults)
        profiles.characterCardManager = cards
        avatarStore = DefaultUserAvatar(fileURL: root.appendingPathComponent("default-user-avatar.jpg"))
        factory = OnboardingFloorFactory(profiles: profiles, presets: presets, cards: cards, defaults: defaults, avatar: avatarStore)
        engine = Self.makeEngine(root: root, defaults: defaults)
    }

    static func makeEngine(root: URL, defaults: UserDefaults) -> AssistantEngine {
        let chat = root.appendingPathComponent("AssistantChat", isDirectory: true)
        return AssistantEngine(store: AssistantChatStore(fileURL: chat.appendingPathComponent("history.json")),
                               ledger: AssistantLedger(fileURL: chat.appendingPathComponent("ledger.json")),
                               packDefaults: defaults, scriptPacing: .instant)
    }

    /// 还在原来那层（引导建的 Ta 楼层不自动切过去）
    var atHome: Bool { profiles.currentProfile.id == Profile.seedProfiles[0].id }

    var scriptFile: URL { root.appendingPathComponent("AssistantChat/script.json") }
    var historyStore: AssistantChatStore { AssistantChatStore(fileURL: root.appendingPathComponent("AssistantChat/history.json")) }
    var scriptStore: XiaoyaScriptStore { XiaoyaScriptStore(directory: root.appendingPathComponent("AssistantChat")) }

    /// 模拟被杀后重开：按 history.json + script.json 重建引擎（旧引擎的延迟写盘随它一起作废）
    func relaunch() async {
        engine = Self.makeEngine(root: root, defaults: defaults)
        script.attach(world: world)
        await script.idle()
    }

    var world: XiaoyaScriptWorld {
        XiaoyaScriptWorld(
            importCard: { [factory] card in try await factory.importCard(at: try XCTUnwrap(card.fileURL)) },
            createTa: { [factory] in try factory.createTa(id: $1, name: $0.taName, userName: $0.userName, who: $0.who) },
            goTo: { [profiles] id in if let p = profiles.profiles.first(where: { $0.id == id }) { profiles.switchTo(p) } },
            requestPush: { [weak self] in self?.pushCount += 1 },
            activeModelName: { [weak self] in self?.activeModel },
            setDefaultUserName: { [defaults] in DefaultUserName.set($0, defaults: defaults) },
            // 头像不走 ImageRenderer（另有测试），种子换成一段假 JPEG
            applyFace: { [factory] in factory.applyFace($0, avatarJPEG: $0.photo ?? ($0.avatar == nil ? nil : Self.fakeJPEG)) })
    }

    static let fakeJPEG = Data("fake-jpeg".utf8)

    /// 小白线分流后的两张挑头像 + 名字卡：你叫栗子，Ta 叫阿梨
    func answerFaces(user: String = "栗子", ta: String = "阿梨") async {
        await answer(.face(XiaoyaFaceAnswer(target: .user, avatar: XiaoyaAvatarSeed(seed: 8, kind: "animal", species: "cat"), name: user)))
        await answer(.face(XiaoyaFaceAnswer(target: .ta, avatar: XiaoyaAvatarSeed(seed: 9, kind: "flower"), name: ta)))
    }

    func clean() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    var script: XiaoyaScriptRunner { engine.script }

    func start() async {
        script.attach(world: world)
        script.start()
        await script.idle()
    }

    /// 剧本正在等的那张卡
    var awaited: AssistantChatMessage? {
        guard let id = script.progress?.awaitingMessageId else { return nil }
        return engine.messages.first { $0.id == id }
    }

    func answer(_ answer: XiaoyaCardAnswer, file: StaticString = #filePath, line: UInt = #line) async {
        guard let id = script.progress?.awaitingMessageId else {
            XCTFail("剧本没在等卡（step=\(String(describing: script.progress?.step))）", file: file, line: line)
            return
        }
        script.answer(id, answer)
        await script.idle()
    }

    func answer(card message: AssistantChatMessage?, _ answer: XiaoyaCardAnswer) async {
        guard let message else { return XCTFail("没有这张卡") }
        script.answer(message.id, answer)
        await script.idle()
    }

    /// 卡的种类序列（看剧本出了哪些卡）
    var cardKinds: [String] {
        engine.messages.compactMap(\.card).map { state in
            switch state.card {
            case .choice(let p): return "choice:" + (p.options.first?.id ?? "")
            case .keyForm: return "keyForm"
            case .importCard: return "importCard"
            case .nameForm: return "nameForm"
            case .floorExit: return "floorExit"
            case .goTa: return "goTa"
            case .pair: return "pair"
            case .todo: return "todo"
            case .info: return "info"
            case .makeTa: return "makeTa"
            case .face(let target): return "face:" + target.rawValue
            case .tip(let ref): return "tip:" + ref.kind.rawValue
            case .survey: return "survey"
            case .unsupported: return "unsupported"
            }
        }
    }

    var texts: [String] { engine.messages.map(\.text) }

    static let saved = XiaoyaCardAnswer.keySaved(XiaoyaKeySaved(credentialId: "cred-test", providerName: "OpenAI", modelId: "gpt-4o-mini"))

    /// 一张临时 V2 角色卡（.json），走导卡卡同一个读法（拷进临时目录 + 摘要）
    func importedCard(name: String = "月见坂 · 澪", book: Bool = true) throws -> XiaoyaImportedCard {
        var data: [String: Any] = ["name": name, "first_mes": "雨下了一整天。", "alternate_greetings": ["你总算来了。"],
                                   "system_prompt": "你是澪"]
        if book { data["character_book"] = ["name": "书", "entries": [["keys": ["雨"], "content": "下雨天", "enabled": true]]] }
        let raw = try JSONSerialization.data(withJSONObject: ["spec": "chara_card_v2", "spec_version": "2.0", "data": data])
        let url = root.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try raw.write(to: url)
        switch XiaoyaImportCardView.load(url) {
        case .success(let card): return card
        case .failure(let why): throw NSError(domain: "xiaoya", code: 1, userInfo: [NSLocalizedDescriptionKey: why.message])
        }
    }
}

@MainActor
final class XiaoyaScriptTests: XCTestCase {
    private var f: XiaoyaScriptFixture!

    override func setUp() async throws { f = try XiaoyaScriptFixture() }
    override func tearDown() async throws { f.clean() }

    // MARK: 开场 + 分流

    func testOpenSaysThreeLinesThenIdentityCardAndLocksInput() async {
        await f.start()
        XCTAssertEqual(f.texts.prefix(3).map { $0 }, XiaoyaScriptLines.open)
        XCTAssertEqual(f.cardKinds, ["choice:newbie"])
        XCTAssertTrue(f.engine.messages.allSatisfy { $0.source == .script })
        XCTAssertTrue(f.script.locksInput)
        XCTAssertEqual(f.script.inputPlaceholder, "照着上面的卡片回答就好～")
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "started")
        XCTAssertEqual(f.engine.stageState.mood, .smirk)
    }

    // MARK: 小白

    func testNewbieWithKeyTalksThenEnds() async throws {
        await f.start()
        await f.answer(.picked("newbie"))
        XCTAssertEqual(f.defaults.string(forKey: "onboardingIdentity"), "newbie")
        XCTAssertEqual(f.defaults.object(forKey: "settings.proMode") as? Bool, false)
        XCTAssertTrue(f.engine.messages.contains { $0.isUser && $0.text == "我是小白" && $0.source == .script })
        XCTAssertEqual(f.cardKinds.last, "face:user", "小白先挑头像 + 名字（§11-7）")
        await f.answerFaces()
        XCTAssertEqual(f.cardKinds.last, "keyForm")
        XCTAssertEqual(f.engine.stageState.status, "等你的钥匙")

        await f.answer(XiaoyaScriptFixture.saved)
        let handoff = try XCTUnwrap(f.engine.messages.first { $0.source == .handoff })
        XCTAssertEqual(handoff.text, "钥匙接好了 · 从这里起小芽用 gpt-4o-mini 说话")
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.keyWorks(model: "gpt-4o-mini")))
        XCTAssertFalse(f.script.locksInput, "钥匙存好就放开输入框")
        XCTAssertTrue(f.script.awaitingTalk)
        XCTAssertEqual(f.script.suggestions, XiaoyaScriptLines.newbieSuggestions)
        XCTAssertEqual(f.script.inputPlaceholder, "随便说点什么…")

        // 真 AI 回完一句（这里不发网络：她说的那句 + 回复手动塞，再报「回完了」）
        f.engine.messages.append(AssistantChatMessage(isUser: true, text: "你好呀"))
        f.engine.messages.append(AssistantChatMessage(isUser: false, text: "你好～"))
        f.script.replyFinished()
        await f.script.idle()
        XCTAssertEqual(f.texts.last, XiaoyaCard.choice(.wantTa).prompt)
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.newbieAfterTalk))

        await f.answer(.picked("no"))
        XCTAssertTrue(f.texts.contains("先跟你聊着"))
        XCTAssertEqual(f.cardKinds, ["choice:newbie", "face:user", "face:ta", "keyForm", "choice:yes", "todo", "makeTa", "info"])
        XCTAssertNotNil(f.script.progress?.finishedAt)
        XCTAssertFalse(f.script.isActive)
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "done")
        XCTAssertTrue(f.defaults.bool(forKey: XiaoyaScriptRunner.legacyCompletedKey), "end 后旧引导标记也为真（降级不再弹六页）")
        XCTAssertEqual(f.pushCount, 1)
        XCTAssertEqual(f.engine.stageState.mood, .love)
        guard case .todo(let items)? = f.engine.messages.compactMap(\.card).first(where: { if case .todo = $0.card { true } else { false } })?.card else {
            return XCTFail("没有待办卡")
        }
        XCTAssertEqual(items, XiaoyaScriptLines.todoItems(identity: "newbie", ta: nil, hasKey: true))
    }

    func testNewbieWithoutKeyGoesStraightToEnd() async {
        await f.start()
        await f.answer(.picked("newbie"))
        await f.answerFaces()
        await f.answer(.skipped)
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.keySkipped))
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.newbieNoKey))
        XCTAssertFalse(f.texts.contains(XiaoyaScriptLines.newbieTalk), "没钥匙的小白不试聊")
        XCTAssertEqual(f.cardKinds, ["choice:newbie", "face:user", "face:ta", "keyForm", "todo", "makeTa", "info"])
        XCTAssertNil(f.engine.messages.first { $0.source == .handoff })
        XCTAssertEqual(f.script.progress?.keySkipped, true)
        XCTAssertFalse(f.script.isActive)
        XCTAssertFalse(f.script.locksInput, "走完了放开（召回 chips / 关键词还能配钥匙）")
        let todo = f.engine.messages.compactMap(\.card).compactMap { state -> [String]? in
            if case .todo(let items) = state.card { return items } else { return nil }
        }.first
        XCTAssertEqual(todo?.first, XiaoyaScriptLines.todoNoKey)
    }

    func testNewbieWantsTaGoesToCompanionFromNewbie() async {
        await f.start()
        await f.answer(.picked("newbie"))
        await f.answerFaces()
        await f.answer(XiaoyaScriptFixture.saved)
        f.script.replyFinished()
        await f.script.idle()
        await f.answer(.picked("yes"))
        XCTAssertTrue(f.texts.contains("好，建一个 Ta"))
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.companionAskFromNewbie))
        XCTAssertEqual(f.cardKinds.last, "nameForm")
    }

    // MARK: 保持神秘

    func testGhostSkipsKeyAndFinishes() async {
        await f.start()
        await f.answer(.picked("ghost"))
        XCTAssertFalse(f.cardKinds.contains("keyForm"), "ghost 不出钥匙卡")
        XCTAssertEqual(f.cardKinds, ["choice:newbie", "info"])
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.ghost[1]))
        XCTAssertEqual(f.defaults.string(forKey: "onboardingIdentity"), "ghost")
        XCTAssertEqual(f.defaults.object(forKey: "settings.proMode") as? Bool, true)
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "done")
        XCTAssertTrue(f.defaults.bool(forKey: XiaoyaScriptRunner.legacyCompletedKey))
        XCTAssertEqual(f.pushCount, 1)
        XCTAssertFalse(f.script.isActive)
    }

    // MARK: 酒馆

    func testTavernImportBuildsFloorWithoutSwitchingThenStayAndGo() async throws {
        await f.start()
        await f.answer(.picked("tavern"))
        XCTAssertEqual(f.defaults.object(forKey: "settings.proMode") as? Bool, true)
        await f.answer(.skipped)
        XCTAssertEqual(f.cardKinds.last, "importCard")
        let card = try f.importedCard()
        await f.answer(.imported(card))

        let ta = try XCTUnwrap(f.profiles.profiles.first { $0.name == "月见坂 · 澪" })
        XCTAssertTrue(f.atHome, "建楼层不自动切")
        XCTAssertEqual(f.script.progress?.taProfileId, ta.id)
        XCTAssertEqual(f.cards.cards.first?.linkedProfileId, ta.id)
        guard case .floorExit(let payload)? = f.awaited?.card?.card else { return XCTFail("没出新楼层卡") }
        XCTAssertEqual(payload.ta.profileId, ta.id)
        XCTAssertEqual(payload.extras, [.worldBook, .preset])
        XCTAssertEqual(payload.meta, "开场白已就位 · 世界书 1 条已挂上 · 用卡自带的系统指令")

        await f.answer(.floor(.stay))
        XCTAssertTrue(f.texts.contains("继续问我"))
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.tavernStay(ta.name)))
        XCTAssertEqual(f.cardKinds.suffix(3), ["todo", "goTa", "info"])
        XCTAssertFalse(f.script.isActive)
        XCTAssertTrue(f.atHome)

        // 出口卡「去找 X」才切；点几次切几次，不记答案
        let goTa = f.engine.messages.last { if case .goTa = $0.card?.card { true } else { false } }
        await f.answer(card: goTa, .floor(.go))
        XCTAssertEqual(f.profiles.currentProfile.id, ta.id)
        XCTAssertNil(f.engine.messages.first { $0.id == goTa?.id }?.card?.answer)
    }

    func testTavernGoFinishesFirstThenSwitches() async throws {
        await f.start()
        await f.answer(.picked("tavern"))
        await f.answer(XiaoyaScriptFixture.saved)
        await f.answer(.imported(try f.importedCard()))
        let taId = try XCTUnwrap(f.script.progress?.taProfileId)
        await f.answer(.floor(.go))
        XCTAssertEqual(f.profiles.currentProfile.id, taId)
        XCTAssertFalse(f.cardKinds.contains("goTa"), "点了去找就不再出出口卡")
        XCTAssertNotNil(f.script.progress?.finishedAt, "切楼层之前 script.json 已经是 done")
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "done")
    }

    // MARK: 长期陪伴

    func testCompanionNamesTaWritesDefaultNameAndDescription() async throws {
        await f.start()
        await f.answer(.picked("companion"))
        XCTAssertEqual(f.defaults.object(forKey: "settings.proMode") as? Bool, false)
        await f.answer(XiaoyaScriptFixture.saved)
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.companionAsk))
        await f.answer(.named(XiaoyaNameAnswer(taName: "阿洛", userName: "粟粟", who: "嘴硬心软")))

        XCTAssertTrue(f.texts.contains("Ta 叫阿洛，叫我粟粟"))
        XCTAssertTrue(f.texts.contains("阿洛……好名字。"))
        let ta = try XCTUnwrap(f.profiles.profiles.first { $0.name == "阿洛" })
        XCTAssertEqual(ta.assistantName, "阿洛")
        XCTAssertEqual(ta.userName, "粟粟")
        XCTAssertTrue(f.atHome, "不自动切")
        XCTAssertEqual(DefaultUserName.value(f.defaults), "粟粟")
        let inst = try XCTUnwrap(f.presets.preset(byId: ta.presetId))
        XCTAssertEqual(inst.ownerProfileId, ta.id)
        XCTAssertEqual(inst.prompts.first { $0.id == PromptSlot.charDescriptionId }?.content, "嘴硬心软")

        await f.answer(.floor(.go))
        XCTAssertEqual(f.profiles.currentProfile.id, ta.id)
        XCTAssertFalse(f.script.isActive)
        let todo = f.engine.messages.compactMap(\.card).compactMap { state -> [String]? in
            if case .todo(let items) = state.card { return items } else { return nil }
        }.first
        XCTAssertEqual(todo?.first, "跟阿洛说一件关于你的事——阿洛会记住")
    }

    // MARK: 技术

    /// 测试宿主是 mac（§5.3）：不问有没有 Mac，问要不要连手机；要 → 只指路到设置，不出扫码卡（iOS 走 techPair，见下）
    func testTechOnMacAsksPhoneAndOnlyPointsToSettings() async {
        await f.start()
        await f.answer(.picked("tech"))
        await f.answer(XiaoyaScriptFixture.saved)
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.techGuide))
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.techAskPhone))
        XCTAssertFalse(f.texts.contains(XiaoyaScriptLines.techAskMac))
        XCTAssertEqual(f.texts.last, XiaoyaCard.choice(.wantPhone).prompt)
        await f.answer(.picked("yes"))
        XCTAssertTrue(f.texts.contains("要，连手机"))
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.techPhoneGuide))
        XCTAssertEqual(f.script.progress?.hasMac, true)
        XCTAssertFalse(f.cardKinds.contains("pair"))
        XCTAssertFalse(f.script.isActive)
    }

    func testTechOnMacDeclinePhoneEndsWithoutGuide() async {
        await f.start()
        await f.answer(.picked("tech"))
        await f.answer(XiaoyaScriptFixture.saved)
        await f.answer(.picked("no"))
        XCTAssertTrue(f.texts.contains("先不用"))
        XCTAssertFalse(f.texts.contains(XiaoyaScriptLines.techPhoneGuide))
        XCTAssertFalse(f.script.isActive)
    }

    func testTechBeatsAskMacOnIOS() {
        var p = XiaoyaScriptProgress()
        p.step = .tech
        XCTAssertEqual(XiaoyaScriptRunner.beats(for: p, pairSupported: true).last, .card(.choice(.hasMac)))
        XCTAssertEqual(XiaoyaScriptRunner.beats(for: p, pairSupported: false).last, .card(.choice(.wantPhone)))
    }

    // MARK: 设置重走（§7-5）

    func testReplayAddsDividerKeepsHistoryAndRestartsAtIdentityCard() async throws {
        await f.start()
        await f.answer(.picked("ghost"))
        XCTAssertFalse(f.script.isActive)
        let before = f.engine.messages
        f.defaults.set(false, forKey: "settings.proMode")
        f.script.replay()
        await f.script.idle()
        XCTAssertEqual(Array(f.engine.messages.prefix(before.count)), before, "历史不清")
        let divider = try XCTUnwrap(f.engine.messages.first { $0.source == .divider })
        XCTAssertEqual(divider.text, XiaoyaScriptLines.replayDivider)
        XCTAssertEqual(f.engine.messages.last?.card?.card, .choice(.identity), "分隔线之后直接是分流卡")
        XCTAssertEqual(f.engine.messages.count, before.count + 2)
        XCTAssertTrue(f.script.isActive)
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "done", "重走不把键改回 started")
        XCTAssertEqual(f.defaults.object(forKey: "settings.proMode") as? Bool, false, "没重选园丁类型不动 proMode")
        XCTAssertFalse(f.engine.wireHistory().contains { $0.content == XiaoyaScriptLines.replayDivider }, "分隔线不进模型历史")

        await f.answer(.picked("tavern"))
        XCTAssertEqual(f.defaults.object(forKey: "settings.proMode") as? Bool, true, "重选了才重写")
        XCTAssertEqual(f.cardKinds.last, "keyForm")
    }

    func testTechPairBeatsOnIOS() {
        var p = XiaoyaScriptProgress()
        p.step = .techPair
        XCTAssertEqual(XiaoyaScriptRunner.beats(for: p, pairSupported: true), [.card(.pair)])
    }

    // MARK: 重建后接着走（H6）

    func testRebuiltEngineResumesAtUnansweredCard() async throws {
        await f.start()
        await f.answer(.picked("tavern"))
        let keyCardId = try XCTUnwrap(f.awaited?.id)
        AssistantChatStore(fileURL: f.root.appendingPathComponent("AssistantChat/history.json")).save(f.engine.messages)

        f.engine = XiaoyaScriptFixture.makeEngine(root: f.root, defaults: f.defaults)
        XCTAssertEqual(f.script.progress?.step, .keyIntro)
        f.script.attach(world: f.world)
        await f.script.idle()
        XCTAssertEqual(f.script.progress?.awaitingMessageId, keyCardId, "原地等那张没答的卡，不重出")
        XCTAssertEqual(f.cardKinds.filter { $0 == "keyForm" }.count, 1)
        XCTAssertTrue(f.script.locksInput)

        await f.answer(.skipped)
        XCTAssertEqual(f.cardKinds.last, "importCard")
    }

    func testRebuiltEngineRepostsCardLostWithHistory() async throws {
        await f.start()
        // history.json 没来得及写（0.5 s 合并）就被杀：新引擎读到空历史
        f.engine = XiaoyaScriptFixture.makeEngine(root: f.root, defaults: f.defaults)
        XCTAssertTrue(f.engine.messages.isEmpty)
        f.script.attach(world: f.world)
        await f.script.idle()
        XCTAssertEqual(f.cardKinds, ["choice:newbie"])
        XCTAssertNotNil(f.awaited)
    }

    /// sol #2：新楼层出口卡出了、script.json 记着在等它，但 history.json 没来得及写这张卡就被杀——重开要按记下的 Ta 重出这张卡，
    /// 不重建楼层；跳过钥匙的这条线输入框也不能一直锁着
    func testRebuiltEngineRepostsLostFloorExitCard() async throws {
        for identity in ["companion", "tavern"] {
            f.clean()
            f = try XiaoyaScriptFixture()
            await f.start()
            await f.answer(.picked(identity))
            await f.answer(.skipped)
            if identity == "companion" {
                await f.answer(.named(XiaoyaNameAnswer(taName: "阿洛")))
            } else {
                await f.answer(.imported(try f.importedCard()))
            }
            guard case .floorExit(let before)? = f.awaited?.card?.card else { return XCTFail("\(identity) 没出新楼层卡") }
            let floorCount = f.profiles.profiles.count
            f.historyStore.save(f.engine.messages.filter { if case .floorExit = $0.card?.card { false } else { true } })

            await f.relaunch()
            guard case .floorExit(let after)? = f.awaited?.card?.card else { return XCTFail("\(identity) 重开后没重出出口卡") }
            XCTAssertEqual(after, before, "\(identity)：按 script.json 记的 Ta 重拼")
            XCTAssertEqual(f.profiles.profiles.count, floorCount, "\(identity)：不重建楼层")
            XCTAssertEqual(f.cardKinds.filter { $0 == "floorExit" }.count, 1)
            XCTAssertTrue(f.script.locksInput, "还在引导里、钥匙跳过了：照旧锁着，但有卡可答")

            await f.answer(.floor(.stay))
            XCTAssertFalse(f.script.isActive, "\(identity)：答了出口卡能走完")
            XCTAssertFalse(f.script.locksInput)
        }
    }

    /// sol #3：iPhone 技术线停在扫码卡，备份恢复到 mac（mac 画不出扫码卡）→ 改走 mac 的「连手机只指路」再收尾
    func testIPhoneProgressOnPairCardMovesToPhoneGuideOnMac() async throws {
        try XCTSkipIf(XiaoyaScriptRunner.platformPairs, "测试宿主是 mac 才有意义")
        var p = XiaoyaScriptProgress()
        p.identity = "tech"
        p.keySkipped = true
        p.hasMac = true
        p.step = .techPair
        p.emitted = 1
        let pair = AssistantChatMessage(isUser: false, text: XiaoyaCard.pair.prompt, source: .script, card: XiaoyaCardState(card: .pair))
        p.awaitingMessageId = pair.id
        f.scriptStore.save(p)
        f.historyStore.save([pair])
        f.defaults.set("started", forKey: XiaoyaScriptRunner.onboardingKey)

        await f.relaunch()
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.techPhoneGuide))
        XCTAssertFalse(f.script.isActive, "走到收尾，不停在答不了的扫码卡")
        XCTAssertFalse(f.script.locksInput)
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "done")
    }

    func testResumableKeepsAnswerableWaits() {
        let cardId = UUID()
        var p = XiaoyaScriptProgress()
        p.step = .techPair
        p.emitted = 1
        p.awaitingMessageId = cardId
        XCTAssertEqual(XiaoyaScriptRunner.resumable(p, messageIds: [cardId], pairSupported: true), p, "iPhone 上扫码卡还在：原地等")
        var lost = p
        lost.emitted = 0
        lost.awaitingMessageId = nil
        XCTAssertEqual(XiaoyaScriptRunner.resumable(p, messageIds: [], pairSupported: true), lost, "卡丢了：退一拍重出")
        let onMac = XiaoyaScriptRunner.resumable(p, messageIds: [cardId], pairSupported: false)
        XCTAssertEqual(onMac.step, .techPhone, "mac 上不留答不了的扫码卡")
        XCTAssertEqual(onMac.emitted, 0)

        var exit = XiaoyaScriptProgress()
        exit.step = .companionExit
        exit.emitted = 1
        exit.awaitingMessageId = cardId
        XCTAssertEqual(XiaoyaScriptRunner.resumable(exit, messageIds: [cardId], pairSupported: false), exit)
        XCTAssertEqual(XiaoyaScriptRunner.resumable(exit, messageIds: [], pairSupported: false).emitted, 0, "出口卡丢了也重出")
        var old = exit
        old.step = .companionDone
        old.emitted = 3
        XCTAssertEqual(XiaoyaScriptRunner.resumable(old, messageIds: [cardId], pairSupported: false), exit, "升级前停在旧出口卡上的：挪到新节点接着等")

        var talk = XiaoyaScriptProgress()
        talk.step = .newbieTalk
        talk.emitted = 2
        XCTAssertEqual(XiaoyaScriptRunner.resumable(talk, messageIds: [], pairSupported: false), talk, "等她说话不是等卡")
    }

    /// sol #4：起名后楼层已落地、但剧本没来得及记下就被杀——重开按 script.json 里先定好的楼层 id 复用，不多建一个阿洛
    func testBuildTaResumesWithStableFloorId() async throws {
        let built = try f.factory.createTa(id: "ta-fixed", name: "阿洛", userName: "", who: "嘴硬心软")
        var p = XiaoyaScriptProgress()
        p.identity = "companion"
        p.keySkipped = true
        p.step = .companionDone
        p.pendingName = XiaoyaNameAnswer(taName: "阿洛", who: "嘴硬心软")
        p.pendingTaId = "ta-fixed"
        f.scriptStore.save(p)
        f.defaults.set("started", forKey: XiaoyaScriptRunner.onboardingKey)

        await f.relaunch()
        XCTAssertEqual(f.profiles.profiles.filter { $0.name == "阿洛" }.map(\.id), ["ta-fixed"])
        XCTAssertEqual(f.presets.presets.filter { $0.ownerProfileId == "ta-fixed" }.map(\.id), [built.presetId], "预设实例也只一份")
        XCTAssertEqual(f.script.progress?.taProfileId, "ta-fixed")
        XCTAssertNil(f.script.progress?.pendingTaId)
        guard case .floorExit(let payload)? = f.awaited?.card?.card else { return XCTFail("没出新楼层卡") }
        XCTAssertEqual(payload.ta.profileId, "ta-fixed")
    }

    func testBuildTaRecordsFloorIdBeforeBuilding() async throws {
        var idAtBuild: String?
        var recordedAtBuild: String?
        await f.start()
        await f.answer(.picked("companion"))
        await f.answer(.skipped)
        var world = f.world
        let real = world.createTa
        let store = f.scriptStore
        world.createTa = { answer, id in
            idAtBuild = id
            recordedAtBuild = store.load()?.pendingTaId
            return try real(answer, id)
        }
        f.script.attach(world: world)
        await f.answer(.named(XiaoyaNameAnswer(taName: "阿洛")))
        XCTAssertNotNil(idAtBuild)
        XCTAssertEqual(recordedAtBuild, idAtBuild, "建之前 id 已经写进 script.json")
        XCTAssertEqual(f.script.progress?.taProfileId, idAtBuild)
    }

    /// sol #5：预设存不下（预设库读坏）→ 不宣布建好了，楼层不落，重出起名卡可以再试
    func testBuildTaFailsWhenPresetCannotPersist() async throws {
        await f.start()
        await f.answer(.picked("companion"))
        await f.answer(.skipped)
        f.presets.blockWrites(CocoaError(.fileReadCorruptFile))
        await f.answer(.named(XiaoyaNameAnswer(taName: "阿洛", who: "嘴硬心软")))
        XCTAssertFalse(f.profiles.profiles.contains { $0.name == "阿洛" }, "楼层不落")
        XCTAssertFalse(f.presets.presets.contains { $0.ownerProfileId != nil }, "内存里也没有半截预设")
        XCTAssertFalse(f.texts.contains("阿洛……好名字。"))
        XCTAssertTrue(f.texts.contains { $0.hasPrefix("没建成：") })
        XCTAssertEqual(f.cardKinds.last, "nameForm", "重出起名卡")
        XCTAssertEqual(f.awaited?.card?.card, .nameForm)
        XCTAssertNil(f.script.progress?.pendingTaId)
        XCTAssertNil(f.script.progress?.pendingName)
    }

    /// sol #6：新设备已自动开了引导（started），又恢复了另一台走完引导的备份（script.json 已收尾）→ 启动对齐成 done
    func testReconcileFinishedBackup() async throws {
        await f.start()
        await f.answer(.picked("ghost"))
        XCTAssertNotNil(f.script.progress?.finishedAt)
        f.defaults.set("started", forKey: XiaoyaScriptRunner.onboardingKey)
        f.defaults.set(false, forKey: XiaoyaScriptRunner.legacyCompletedKey)
        let store = f.scriptStore
        XiaoyaScriptRunner.reconcileFinished(defaults: f.defaults) { store.load() }
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "done")
        XCTAssertTrue(f.defaults.bool(forKey: XiaoyaScriptRunner.legacyCompletedKey))
        XCTAssertTrue(PushGate.requestsAtLaunch(f.defaults))

        // 没走完 / 没有剧本：不动
        f.defaults.set("started", forKey: XiaoyaScriptRunner.onboardingKey)
        XiaoyaScriptRunner.reconcileFinished(defaults: f.defaults) { XiaoyaScriptProgress() }
        XiaoyaScriptRunner.reconcileFinished(defaults: f.defaults) { nil }
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "started")

        // 重走中（done + 没收尾）、老用户（upgraded）：不碰
        f.script.replay()
        await f.script.idle()
        f.defaults.set("done", forKey: XiaoyaScriptRunner.onboardingKey)
        XiaoyaScriptRunner.reconcileFinished(defaults: f.defaults) { store.load() }
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "done")
        XCTAssertTrue(f.script.isActive, "重走照常")
        f.defaults.set("upgraded", forKey: XiaoyaScriptRunner.onboardingKey)
        f.defaults.set(false, forKey: XiaoyaScriptRunner.legacyCompletedKey)
        var finished = XiaoyaScriptProgress()
        finished.finishedAt = Date()
        XiaoyaScriptRunner.reconcileFinished(defaults: f.defaults) { finished }
        XCTAssertEqual(f.defaults.string(forKey: XiaoyaScriptRunner.onboardingKey), "upgraded")
        XCTAssertFalse(f.defaults.bool(forKey: XiaoyaScriptRunner.legacyCompletedKey))
    }

    func testScriptJSONHasNoKeyAndRoundTrips() async throws {
        await f.start()
        await f.answer(.picked("companion"))
        let raw = try String(contentsOf: f.scriptFile, encoding: .utf8)
        XCTAssertFalse(raw.contains("sk-"))
        let decoded = try JSONDecoder().decode(XiaoyaScriptProgress.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded, f.script.progress)
        // 新版节点这版不认识：当走完了，不卡住
        let future = try JSONDecoder().decode(XiaoyaScriptProgress.self, from: Data(#"{"step":"someFutureNode"}"#.utf8))
        XCTAssertNotNil(future.finishedAt)
    }

    // MARK: 打字插队

    func testUserTypingWhileCardOpenDoesNotReorderScript() async throws {
        await f.start()
        await f.answer(.picked("tavern"))
        await f.answer(XiaoyaScriptFixture.saved)
        // 卡没答时她跟真 AI 聊了一句（插在卡下面）
        f.engine.messages.append(AssistantChatMessage(isUser: true, text: "先问个别的"))
        f.engine.messages.append(AssistantChatMessage(isUser: false, text: "好呀"))
        await f.answer(.imported(try f.importedCard()))
        let chatIndex = try XCTUnwrap(f.engine.messages.firstIndex { $0.text == "好呀" })
        let doneIndex = try XCTUnwrap(f.engine.messages.firstIndex { $0.text == XiaoyaScriptLines.tavernDone })
        XCTAssertGreaterThan(doneIndex, chatIndex, "剧本下一句接在末尾")
    }

    // MARK: 召回关键词（§7-4）

    func testRecallKeywordsPostCardsLocally() async {
        f.script.attach(world: f.world)
        XCTAssertFalse(f.script.intercept("配钥匙呀"), "只认整句")
        XCTAssertTrue(f.script.intercept("配钥匙"))
        await f.script.idle()
        XCTAssertEqual(f.engine.messages.first?.text, "配钥匙")
        XCTAssertEqual(f.engine.messages.first?.source, .script)
        XCTAssertEqual(f.cardKinds, ["keyForm"])
        XCTAssertTrue(f.script.intercept("建一个 Ta"))
        XCTAssertTrue(f.script.intercept("导卡"))
        XCTAssertTrue(f.script.intercept("连电脑"))
        await f.script.idle()
        XCTAssertEqual(f.cardKinds, ["keyForm", "nameForm", "importCard"], "mac 上「连电脑」只指路")
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.recallPairMac))
        XCTAssertTrue(f.script.showsRecallChips, "没在走引导就给召回 chips")
    }

    func testRecallNameCardBuildsTaAndNotesIt() async throws {
        await f.start()
        await f.answer(.picked("ghost"))
        XCTAssertTrue(f.script.intercept("建一个 Ta"))
        await f.script.idle()
        let nameCard = f.engine.messages.last { $0.card?.card == .nameForm }
        await f.answer(card: nameCard, .named(XiaoyaNameAnswer(taName: "阿洛")))
        let ta = try XCTUnwrap(f.profiles.profiles.first { $0.name == "阿洛" })
        XCTAssertTrue(f.atHome)
        XCTAssertEqual(f.script.progress?.taName, "阿洛")
        XCTAssertEqual(ta.userName, "你")
        guard case .floorExit(let payload)? = f.engine.messages.last?.card?.card else { return XCTFail("没出新楼层卡") }
        XCTAssertEqual(payload.ta.profileId, ta.id)
    }

    func testStaleChoiceCardOutsideScriptIsIgnored() async {
        await f.start()
        let identity = f.awaited
        f.script.start()   // DEBUG 从头放：上一张分流卡没答
        await f.script.idle()
        await f.answer(card: identity, .picked("tech"))
        XCTAssertNil(f.engine.messages.first { $0.id == identity?.id }?.card?.answer, "不是剧本在等的分流卡，不收")
        XCTAssertNil(f.defaults.string(forKey: "onboardingIdentity"))
    }

    // MARK: 关于你在帮的人（§7-1）

    func testAboutUserLayer() async throws {
        XCTAssertNil(f.script.aboutUser(taFloors: []))
        await f.start()
        await f.answer(.picked("tech"))
        await f.answer(XiaoyaScriptFixture.saved)
        await f.answer(.picked("no"))
        let about = try XCTUnwrap(f.script.aboutUser(taFloors: ["澪", "阿洛"]))
        XCTAssertTrue(about.contains("园丁类型：技术用户"))
        // 测试宿主是 mac：人就在 Mac 上（§5.3），不连手机也记成有 Mac
        XCTAssertTrue(about.contains("有 Mac"))
        XCTAssertFalse(about.contains("没有 Mac"))
        XCTAssertTrue(about.contains("Ta 的楼层：澪、阿洛"))
        XCTAssertTrue(AssistantPrompts.systemPrompt(about: about).contains("===== 关于你在帮的人 ====="))
        XCTAssertFalse(AssistantPrompts.systemPrompt().contains("关于你在帮的人"))
    }

    func testScriptedMoodYieldsToBusyAndFeedback() {
        var state = XiaoyaStageState(base: .idle, scripted: .init(mood: .love, status: "搞定啦"))
        XCTAssertEqual(state.mood, .love)
        XCTAssertEqual(state.status, "搞定啦")
        state.base = .thinking
        XCTAssertEqual(state.mood, .huh)
        state.base = .idle
        state.feedback = .approved
        XCTAssertEqual(state.mood, .love)
        XCTAssertEqual(state.status, "改好了")
    }

    func testTodoItemsReplaceTaName() {
        XCTAssertEqual(XiaoyaScriptLines.todoItems(identity: "tavern", ta: "Tara", hasKey: true).first, "去找Tara说第一句（开场白已经在等你）")
        XCTAssertEqual(XiaoyaScriptLines.todoItems(identity: "companion", ta: nil, hasKey: false).count, 4)
    }
}
