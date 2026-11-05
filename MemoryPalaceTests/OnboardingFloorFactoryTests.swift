import XCTest
import SwiftData
@testable import 记忆花园

/// 引导建 Ta 楼层（plan-onboarding-xiaoya-impl §4.3）：不切楼层；预设实例归属 Ta；charDescription 只在填了时写；
/// 世界书 / 预设导入落 Ta 楼层（当前楼层不是 Ta 时也对，H7）。全部临时目录 + 内存偏好
@MainActor
final class OnboardingFloorFactoryTests: XCTestCase {
    private var f: XiaoyaScriptFixture!

    override func setUp() async throws { f = try XiaoyaScriptFixture() }
    override func tearDown() async throws { f.clean() }

    func testCreateTaPublishesWithoutSwitchingAndOwnsInstance() throws {
        let ta = try f.factory.createTa(name: "阿洛", userName: "", who: "")
        XCTAssertTrue(f.atHome, "不切楼层")
        XCTAssertTrue(f.profiles.profiles.contains { $0.id == ta.id })
        XCTAssertEqual(ta.assistantName, "阿洛")
        XCTAssertEqual(ta.userName, "你", "没填称呼、也没默认称呼 → 你")
        let inst = try XCTUnwrap(f.presets.preset(byId: ta.presetId))
        XCTAssertEqual(inst.ownerProfileId, ta.id)
        let template = try XCTUnwrap(f.presets.preset(byId: try XCTUnwrap(inst.sourceTemplateId)))
        XCTAssertEqual(inst.prompts.first { $0.id == PromptSlot.charDescriptionId }?.content,
                       template.prompts.first { $0.id == PromptSlot.charDescriptionId }?.content, "没填「Ta 是谁」不动槽")
        // 落盘了：重读楼层列表还在
        let reloaded = ProfileManager.loadProfilesChecked(root: f.root.appendingPathComponent("blobs"), defaults: f.defaults)
        XCTAssertTrue(reloaded.profiles.contains { $0.id == ta.id })
    }

    func testCreateTaUsesDefaultNameAndWritesDescription() throws {
        DefaultUserName.set("宝", defaults: f.defaults)
        let ta = try f.factory.createTa(name: "阿洛", userName: "", who: "嘴硬心软")
        XCTAssertEqual(ta.userName, "宝")
        let inst = try XCTUnwrap(f.presets.preset(byId: ta.presetId))
        XCTAssertEqual(inst.prompts.first { $0.id == PromptSlot.charDescriptionId }?.content, "嘴硬心软")
        XCTAssertNotEqual(f.profiles.currentProfile.presetId, ta.presetId, "写的是 Ta 楼层的实例，不是当前楼层的")
    }

    /// sol #4：同一个 id 建第二次直接还已经落地的那层；上次只落了预设没落楼层留下的实例先清掉，不多一份
    func testCreateTaIsIdempotentById() throws {
        let first = try f.factory.createTa(id: "ta-1", name: "阿洛", userName: "", who: "")
        let again = try f.factory.createTa(id: "ta-1", name: "阿洛", userName: "", who: "")
        XCTAssertEqual(again, first)
        XCTAssertEqual(f.profiles.profiles.filter { $0.id == "ta-1" }.count, 1)
        XCTAssertEqual(f.presets.presets.filter { $0.ownerProfileId == "ta-1" }.count, 1)

        var orphan = Preset.balanced
        orphan.id = "orphan"
        orphan.ownerProfileId = "ta-2"
        try f.presets.persistNew(orphan)
        let ta2 = try f.factory.createTa(id: "ta-2", name: "小满", userName: "", who: "")
        XCTAssertEqual(f.presets.presets.filter { $0.ownerProfileId == "ta-2" }.map(\.id), [ta2.presetId])
        XCTAssertNil(f.presets.preset(byId: "orphan"))
    }

    /// sol #5：预设落不下就整个不建（不先发布楼层、不留内存预设），抛错让起名卡重试
    func testCreateTaThrowsWhenPresetCannotPersist() throws {
        f.presets.blockWrites(CocoaError(.fileReadCorruptFile))
        let before = f.profiles.profiles.map(\.id)
        XCTAssertThrowsError(try f.factory.createTa(name: "阿洛", userName: "", who: "嘴硬心软"))
        XCTAssertEqual(f.profiles.profiles.map(\.id), before)
        XCTAssertFalse(f.presets.presets.contains { $0.ownerProfileId != nil })
        let reloaded = ProfileManager.loadProfilesChecked(root: f.root.appendingPathComponent("blobs"), defaults: f.defaults)
        XCTAssertFalse(reloaded.profiles.contains { $0.name == "阿洛" }, "楼层列表也没落")
    }

    func testImportCardBuildsFloorWithoutSwitching() async throws {
        let card = try f.importedCard()
        let floor = try await f.factory.importCard(at: try XCTUnwrap(card.fileURL))
        XCTAssertTrue(f.atHome)
        XCTAssertEqual(floor.name, "月见坂 · 澪")
        XCTAssertEqual(f.cards.cards.count, 1)
        XCTAssertEqual(f.cards.cards[0].linkedProfileId, floor.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(card.fileURL).path), "临时拷贝用完删掉")
    }

    func testWorldBookLandsOnTaFloorWhileStandingOnXiaoya() throws {
        let ta = try f.factory.createTa(name: "阿洛", userName: "", who: "")
        let data = Data(#"{"name":"雨夜","entries":[{"uid":0,"key":["雨"],"content":"下雨天"}]}"#.utf8)
        let name = try f.factory.importWorldBook(data, fallbackName: "文件名", into: ta.id)
        XCTAssertEqual(name, "雨夜")
        let updated = try XCTUnwrap(f.profiles.profiles.first { $0.id == ta.id })
        XCTAssertEqual(updated.linkedWorldBookIDs.count, 1)
        let taId = ta.id
        let books = try ModelContext(f.container).fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == taId }))
        XCTAssertEqual(books.map(\.id.uuidString), updated.linkedWorldBookIDs)
        XCTAssertTrue(f.profiles.currentProfile.linkedWorldBookIDs.isEmpty, "小芽楼层不挂")
        XCTAssertThrowsError(try f.factory.importWorldBook(Data(#"{"entries":[]}"#.utf8), fallbackName: "空", into: ta.id))
        XCTAssertThrowsError(try f.factory.importWorldBook(data, fallbackName: "x", into: "nope"))
    }

    func testPresetLandsOnTaFloorAsItsOwnInstance() throws {
        let ta = try f.factory.createTa(name: "阿洛", userName: "", who: "")
        let xiaoyaPreset = f.profiles.currentProfile.presetId
        let raw = try JSONSerialization.data(withJSONObject: [
            "prompts": [["identifier": "main", "name": "main", "role": "system", "content": "新的主指令", "injection_depth": 0]],
        ])
        let imported = try f.factory.importPreset(raw, into: ta.id)
        let updated = try XCTUnwrap(f.profiles.profiles.first { $0.id == ta.id })
        let inst = try XCTUnwrap(f.presets.preset(byId: updated.presetId))
        XCTAssertEqual(inst.ownerProfileId, ta.id, "预设实例归属 Ta")
        XCTAssertEqual(f.presets.preset(byId: try XCTUnwrap(inst.sourceTemplateId))?.name, imported.name)
        XCTAssertEqual(f.profiles.currentProfile.presetId, xiaoyaPreset, "当前（小芽）楼层不动")
    }

    func testPresetWarningOnlyForCardFloorsWithSystemPrompt() async throws {
        let companion = try f.factory.createTa(name: "阿洛", userName: "", who: "")
        XCTAssertFalse(f.factory.presetReplacesCardPrompt(profileId: companion.id))
        let floor = try await f.factory.importCard(at: try XCTUnwrap(try f.importedCard().fileURL))
        XCTAssertTrue(f.factory.presetReplacesCardPrompt(profileId: floor.id))
    }
}
