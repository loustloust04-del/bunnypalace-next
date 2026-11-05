import XCTest
import SwiftData
@testable import 记忆花园

/// 小芽引导 v2（plan-onboarding-xiaoya-impl §11）：小白线挑头像 + 名字、默认头像继承、Tip 1 + tips.json、文案不说 page0/1/2、花园头像生成。
/// 全部走 XiaoyaScriptFixture 的临时目录 + 内存偏好，不碰真实 AssistantChat/ 和 Application Support
@MainActor
final class XiaoyaV2Tests: XCTestCase {
    private var f: XiaoyaScriptFixture!

    override func setUp() async throws { f = try XiaoyaScriptFixture() }
    override func tearDown() async throws { f.clean() }

    // MARK: 挑头像 + 名字（C）

    func testNewbiePicksFacesBeforeKeyAndWritesCurrentFloor() async throws {
        await f.start()
        await f.answer(.picked("newbie"))
        XCTAssertEqual(f.cardKinds, ["choice:newbie", "face:user"])
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.faceIntro))
        XCTAssertEqual(f.script.progress?.step, .newbieFace)

        await f.answerFaces(user: "栗子", ta: "阿梨")
        XCTAssertEqual(f.cardKinds, ["choice:newbie", "face:user", "face:ta", "keyForm"])
        XCTAssertTrue(f.engine.messages.contains { $0.isUser && $0.text == "叫我栗子" && $0.source == .script })
        XCTAssertTrue(f.engine.messages.contains { $0.isUser && $0.text == "Ta 就叫阿梨" && $0.source == .script })
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.faceUserNamed("栗子")))
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.faceTaIntro))
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.faceTaNamed("阿梨")))
        XCTAssertTrue(XiaoyaGlossary.plain(XiaoyaScriptLines.faceTaNamed("阿梨")).contains("这一层就是阿梨的楼层"), "挑完 Ta 顺带讲楼层（粟粟 10-16）")
        XCTAssertEqual(f.engine.stageState.status, "等你的钥匙")

        // 写当前楼层 + 默认称呼 / 默认头像；小芽自己的名字不动
        let floor = f.profiles.currentProfile
        XCTAssertTrue(f.atHome)
        XCTAssertEqual(floor.userName, "栗子")
        XCTAssertEqual(floor.assistantName, "阿梨")
        XCTAssertEqual(floor.userAvatarData, XiaoyaScriptFixture.fakeJPEG)
        XCTAssertEqual(floor.assistantAvatarData, XiaoyaScriptFixture.fakeJPEG)
        XCTAssertEqual(DefaultUserName.value(f.defaults), "栗子")
        XCTAssertEqual(f.avatarStore.load(), XiaoyaScriptFixture.fakeJPEG)
        XCTAssertEqual(AssistantPrompts.assistantName, "小芽")
        XCTAssertEqual(f.script.progress?.userName, "栗子")
        XCTAssertEqual(f.script.progress?.taFaceName, "阿梨")
        XCTAssertTrue(f.script.handoffNote().contains("称呼栗子"))
    }

    /// 粟粟 10-16：小芽这里改了称呼，之后设置 › 通用改就不生效——通用页只写了镜像键，楼层值（`{{user}}` 真相源）一直盖着
    func testSettingsRenameAfterFaceCardWinsEverywhere() async throws {
        await f.start()
        await f.answer(.picked("newbie"))
        await f.answerFaces(user: "栗子", ta: "阿梨")

        f.profiles.renameCurrent(userName: " 宝 ", assistantName: "阿洛")
        let floor = f.profiles.currentProfile
        XCTAssertEqual(floor.userName, "宝")
        XCTAssertEqual(floor.assistantName, "阿洛")
        XCTAssertEqual(f.defaults.string(forKey: "userName"), "宝", "镜像键跟着楼层")
        XCTAssertEqual(f.defaults.string(forKey: "assistantName"), "阿洛")
        XCTAssertEqual(EffectiveCharacterContext(profile: floor, defaults: f.defaults).expand("{{user}}/{{char}}"), "宝/阿洛")
        XCTAssertEqual(DefaultUserName.value(f.defaults), "宝")
        XCTAssertTrue(f.script.handoffNote().contains("称呼宝"), "小芽自己也改口，不再用剧本里的旧快照")
        XCTAssertFalse(f.script.handoffNote().contains("栗子"))

        // 同页改头像也走 updateProfile：名字不能被盖回去
        var avatar = f.profiles.currentProfile
        avatar.userAvatarData = Data("other".utf8)
        f.profiles.updateProfile(avatar)
        XCTAssertEqual(f.defaults.string(forKey: "userName"), "宝")

        // 空 = 不改
        f.profiles.renameCurrent(userName: "", assistantName: "  ")
        XCTAssertEqual(f.profiles.currentProfile.userName, "宝")
        XCTAssertEqual(f.profiles.currentProfile.assistantName, "阿洛")
        XCTAssertEqual(DefaultUserName.value(f.defaults), "宝")
    }

    func testFaceDefaultsKeepNamesButStillSetAvatars() async throws {
        await f.start()
        await f.answer(.picked("newbie"))
        await f.answerFaces(user: "", ta: "")
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.faceUserDefault))
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.faceTaDefault))
        XCTAssertTrue(f.engine.messages.contains { $0.isUser && $0.text == "先这样吧" })
        let floor = f.profiles.currentProfile
        XCTAssertEqual(floor.userName, Profile.seedProfiles[0].userName)
        XCTAssertEqual(floor.assistantName, Profile.seedProfiles[0].assistantName)
        XCTAssertEqual(floor.userAvatarData, XiaoyaScriptFixture.fakeJPEG, "头像默认第一个，照样写")
        XCTAssertEqual(DefaultUserName.value(f.defaults), "", "先叫「你」不写默认称呼")
        XCTAssertNil(f.script.progress?.userName)
        XCTAssertEqual(f.cardKinds.last, "keyForm")
    }

    func testPhotoFaceWritesPhotoAndOnlyFlagGoesToHistory() async throws {
        await f.start()
        await f.answer(.picked("newbie"))
        let photo = Data("photo-jpeg".utf8)
        await f.answer(.face(XiaoyaFaceAnswer(target: .user, avatar: nil, name: "宝", photo: photo)))
        XCTAssertEqual(f.profiles.currentProfile.userAvatarData, photo)
        XCTAssertEqual(f.avatarStore.load(), photo)
        // 图只在内存里交出去：history 里的答案不带图
        let answered = try XCTUnwrap(f.engine.messages.compactMap(\.card).first { if case .face = $0.card { true } else { false } })
        let json = String(decoding: try JSONEncoder().encode(answered), as: UTF8.self)
        XCTAssertFalse(json.contains("photo"))
        let back = try JSONDecoder().decode(XiaoyaCardState.self, from: Data(json.utf8))
        XCTAssertEqual(back.answer, .face(XiaoyaFaceAnswer(target: .user, avatar: nil, name: "宝")))
    }

    func testRelaunchResumesAtFaceCard() async throws {
        await f.start()
        await f.answer(.picked("newbie"))
        await f.answer(.face(XiaoyaFaceAnswer(target: .user, avatar: XiaoyaAvatarSeed(seed: 3, kind: "star"), name: "米粒")))
        await f.relaunch()
        XCTAssertEqual(f.script.progress?.step, .newbieTaFace)
        guard case .face(.ta)? = f.awaited?.card?.card else { return XCTFail("应该停在 Ta 的挑头像卡") }
        await f.answer(.face(XiaoyaFaceAnswer(target: .ta, avatar: XiaoyaAvatarSeed(seed: 4, kind: "letter"), name: "")))
        XCTAssertEqual(f.cardKinds.last, "keyForm")
    }

    func testOtherIdentitiesSkipFaceCards() async {
        await f.start()
        await f.answer(.picked("tech"))
        XCTAssertEqual(f.cardKinds, ["choice:newbie", "keyForm"], "只小白线出挑头像卡")
    }

    func testFaceCardsRoundTripAndUnknownTipKindIsUnsupported() throws {
        for card: XiaoyaCard in [.face(.user), .face(.ta), .tip(XiaoyaTipRef(number: 1, kind: .floors))] {
            let data = try JSONEncoder().encode(XiaoyaCardState(card: card))
            XCTAssertEqual(try JSONDecoder().decode(XiaoyaCardState.self, from: data).card, card)
        }
        let answer = XiaoyaCardAnswer.face(XiaoyaFaceAnswer(target: .ta, avatar: XiaoyaAvatarSeed(seed: 7, kind: "animal", species: "fox"), name: "阿梨"))
        XCTAssertEqual(try JSONDecoder().decode(XiaoyaCardAnswer.self, from: JSONEncoder().encode(answer)), answer)
        let future = try JSONDecoder().decode(XiaoyaCard.self, from: Data(#"{"kind":"tip","tip":{"number":2,"kind":"longPress"}}"#.utf8))
        XCTAssertEqual(future, .unsupported("tip"))
    }

    // MARK: 默认头像继承

    func testNewFloorsInheritDefaultAvatar() async throws {
        let jpeg = Data("default-avatar".utf8)
        f.avatarStore.save(jpeg)
        let ta = try f.factory.createTa(name: "阿洛", userName: "", who: "")
        XCTAssertEqual(ta.userAvatarData, jpeg, "起名建的 Ta 楼层带上默认头像")

        let imported = try f.importedCard(name: "月见坂 · 澪", book: false)
        let card = try f.cards.importFromFile(url: try XCTUnwrap(imported.fileURL))
        let made = try CharacterFloorService.makeFloor(card: card, presets: f.presets, userAvatar: jpeg)
        XCTAssertEqual(made.profile.userAvatarData, jpeg, "导卡楼层带上默认头像")
        XCTAssertNil(try CharacterFloorService.makeFloor(card: card, presets: f.presets).profile.userAvatarData)
    }

    func testDefaultAvatarIgnoresEmptyAndSurvivesReload() {
        let store = f.avatarStore
        XCTAssertNil(store.load())
        store.save(nil)
        store.save(Data())
        XCTAssertNil(store.load())
        store.save(Data("a".utf8))
        XCTAssertEqual(DefaultUserAvatar(fileURL: store.fileURL).load(), Data("a".utf8))
    }

    // MARK: Tip 1 + tips.json（A）

    private func tipRunner() -> XiaoyaScriptRunner {
        let dir = f.root.appendingPathComponent("AssistantChat", isDirectory: true)
        let runner = XiaoyaScriptRunner(store: XiaoyaScriptStore(directory: dir), defaults: f.defaults, pacing: .instant,
                                        pairSupported: true, tipsSupported: true)
        runner.bind(f.engine)
        runner.attach(world: f.world)
        return runner
    }

    func testEndSendsTipOneGroupAndRecordsItOnce() async throws {
        let runner = tipRunner()
        runner.start()
        await runner.idle()
        guard let identity = runner.progress?.awaitingMessageId else { return XCTFail("没在等分流卡") }
        runner.answer(identity, .picked("ghost"))
        await runner.idle()
        XCTAssertEqual(f.cardKinds, ["choice:newbie", "info", "tip:toDesk"], "v3：收尾只发 Tip 1.1")
        XCTAssertTrue(f.texts.contains(XiaoyaScriptLines.tipsIntro))
        XCTAssertNotNil(runner.progress?.finishedAt, "tip 在收尾之前发完")
        XCTAssertEqual(runner.tips.received.map(\.number), [1])
        XCTAssertEqual(runner.tips.unseenCount, 3, "1.2–1.4 进灯泡算未看")
        XCTAssertEqual(runner.tipPulse, 1, "一组只亮一次")
        let saved = XiaoyaTipStore(directory: f.root.appendingPathComponent("AssistantChat")).load()
        XCTAssertEqual(saved.received.map(\.number), [1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("AssistantChat/tips.json").path))

        // 重走一遍：tip 照发，但不算新收到
        runner.replay()
        await runner.idle()
        guard let again = runner.progress?.awaitingMessageId else { return XCTFail("重走没出分流卡") }
        runner.answer(again, .picked("ghost"))
        await runner.idle()
        XCTAssertEqual(runner.tipPulse, 1)
        XCTAssertEqual(runner.tips.received.count, 1)
    }

    func testQuietEndPostsTipCardsWithoutTalking() {
        var p = XiaoyaScriptProgress()
        p.step = .endQuiet
        let beats = XiaoyaScriptRunner.beats(for: p, pairSupported: true, tipsSupported: true)
        let tips = beats.filter { if case .card(.tip) = $0 { true } else { false } }
        XCTAssertEqual(tips, [.card(.tip(XiaoyaTipRef(number: 1, kind: .toDesk)))], "v3：只放 Tip 1.1")
        XCTAssertFalse(beats.contains(.say(XiaoyaScriptLines.tipsIntro)))
        guard case .effect(.finish(goToTa: true))? = beats.last else { return XCTFail("最后一拍是收尾") }
        p.step = .end
        XCTAssertFalse(XiaoyaScriptRunner.beats(for: p, pairSupported: false).contains { if case .card(.tip) = $0 { true } else { false } },
                       "mac 不发「怎么划」")
    }

    func testTipLogDedupesAndSurvivesCorruption() throws {
        var log = XiaoyaTipLog()
        XCTAssertTrue(log.record(1))
        XCTAssertFalse(log.record(1))
        XCTAssertTrue(log.record(2))
        XCTAssertEqual(log.sorted.map(\.number), [1, 2])
        let dir = f.root.appendingPathComponent("tips-test")
        let store = XiaoyaTipStore(directory: dir)
        store.save(log)
        XCTAssertEqual(store.load(), log)
        try Data("{broken".utf8).write(to: store.fileURL)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "坏文件挪开留底")
    }

    // MARK: 文案（§11-2：对用户不说 page0/1/2）

    private static let pageWord = try! NSRegularExpression(pattern: "page ?[012]", options: [.caseInsensitive])

    private func assertNoPageWord(_ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let range = NSRange(text.startIndex..., in: text)
        XCTAssertNil(Self.pageWord.firstMatch(in: text, range: range), "\(label) 里出现了 page 说法：\(text)", file: file, line: line)
    }

    func testScriptLinesNeverSayPageNumbers() throws {
        // 源文件里的每个字符串字面量（注释除外）
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MemoryPalace/Services/Assistant/XiaoyaScriptLines.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let literal = try NSRegularExpression(pattern: #""([^"\\\n]|\\.)*""#)
        var checked = 0
        for line in text.split(separator: "\n") {
            let code = line.components(separatedBy: "//").first ?? ""
            let s = String(code)
            for m in literal.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                assertNoPageWord((s as NSString).substring(with: m.range), "XiaoyaScriptLines.swift")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 50, "没读到台词表")

        // 拼出来的台词也过一遍
        for kind in XiaoyaTipKind.allCases {
            for strip in [true, false] {
                let copy = XiaoyaScriptLines.tip(kind, strip: strip)
                ([copy.title, copy.text] + copy.steps).forEach { assertNoPageWord($0, "tip \(kind)") }
            }
        }
        for id in ["newbie", "tavern", "companion", "tech", "ghost"] {
            XiaoyaScriptLines.todoItems(identity: id, ta: "阿洛", hasKey: false).forEach { assertNoPageWord($0, "todo \(id)") }
        }
        XCTAssertTrue(XiaoyaScriptLines.tip(.floors, strip: true).text.contains("一层住一个 Ta"))
        XCTAssertTrue(XiaoyaScriptLines.tipsIntro.contains("gardenOS"))
    }

    // MARK: 花园头像

    func testAvatarBatchIsStableAndMixed() {
        let a = GardenAvatar.batch(4242)
        XCTAssertEqual(a, GardenAvatar.batch(4242))
        XCTAssertNotEqual(a, GardenAvatar.batch(4243))
        XCTAssertEqual(a.count, 6)
        XCTAssertEqual(a.filter { $0.kind == "animal" }.count, 3)
        XCTAssertEqual(Set(a.compactMap(\.species)).count, 3, "三只小动物不重样")
        XCTAssertEqual(Set(a.map(\.kind)), ["flower", "animal", "letter", "star"])
        for seed in UInt32(1)...400 {
            let flower = GardenAvatar(XiaoyaAvatarSeed(seed: seed, kind: "flower"))
            XCTAssertFalse(GardenAvatar.greenBackgrounds.contains(flower.background), "薄荷底上不放点点花（绿茎）")
            XCTAssertTrue(GardenAvatar.backgrounds.contains(GardenAvatar(XiaoyaAvatarSeed(seed: seed, kind: "letter")).background))
        }
    }

    func testAvatarRendersSquareJPEG() throws {
        let data = try XCTUnwrap(GardenAvatar.jpeg(XiaoyaAvatarSeed(seed: 11, kind: "animal", species: "bunny")))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(image.pixelsWide, 512)
        XCTAssertEqual(image.pixelsHigh, 512)
    }
}
