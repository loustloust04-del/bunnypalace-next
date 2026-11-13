import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class ProfileRenameTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var manager: ProfileManager!
    private var original: [Profile]!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileRenameTests-\(UUID().uuidString)", isDirectory: true)
        suite = "ProfileRenameTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        original = [
            Profile(id: "rename-a", name: "测试甲", emoji: "", description: "", userName: "你", assistantName: "助手"),
            Profile(id: "rename-b", name: "测试乙", emoji: "", description: "", userName: "小舟", assistantName: "砚")
        ]
        let schema = Schema([Conversation.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        manager = ProfileManager(container: container, profiles: original, currentProfile: original[0], loadError: nil,
                                 root: root, defaults: defaults, sideEffectsEnabled: false)
        try manager.persistNew(original)
        defaults.set("你", forKey: "userName")
        defaults.set("助手", forKey: "assistantName")
        DefaultUserName.set("旧默认", defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func saved() throws -> [Profile] {
        try JSONDecoder().decode([Profile].self, from: Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root)))
    }

    func testRenamePersistsCurrentFloorAndImmediatelyExpandsPrompt() throws {
        try manager.renameCurrent(userName: " 栗子\n", assistantName: " 阿岚 ")
        let floor = manager.currentProfile
        XCTAssertEqual(floor.userName, "栗子")
        XCTAssertEqual(floor.assistantName, "阿岚")
        XCTAssertEqual(floor.userPersona, "")
        XCTAssertNil(floor.personaId)
        XCTAssertEqual(manager.profiles, [floor, original[1]])
        XCTAssertEqual(try saved(), manager.profiles)
        XCTAssertEqual(defaults.string(forKey: "userName"), "栗子")
        XCTAssertEqual(defaults.string(forKey: "assistantName"), "阿岚")
        XCTAssertEqual(DefaultUserName.value(defaults), "栗子")
        XCTAssertEqual(EffectiveCharacterContext(profile: floor, defaults: defaults).expand("{{user}}/{{char}}"), "栗子/阿岚")
        let preset = Preset(id: "rename-prompt", name: "改名回归", prompts: [
            PromptSlot(id: PromptSlot.mainId, name: "主提示词", content: "{{char}}称呼{{user}}。")
        ])
        let prompt = PromptMessage.legacyShape(PromptAssembler.assembleOrdered(preset: preset, profile: floor, memories: [], chatHistory: []).messages)
        XCTAssertTrue(try XCTUnwrap(prompt.systemPrompt).contains("阿岚称呼栗子。"))

        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.profiles, manager.profiles)
        manager.switchTo(original[1])
        XCTAssertEqual(defaults.string(forKey: "userName"), "小舟")
        manager.switchTo(try XCTUnwrap(loaded.profiles.first))
        XCTAssertEqual(defaults.string(forKey: "userName"), "栗子")
        XCTAssertEqual(manager.currentProfile.userName, "栗子")
    }

    func testBlankNameKeepsExistingNameAndOtherFloor() throws {
        try manager.renameCurrent(userName: " \n", assistantName: "阿岚")
        XCTAssertEqual(manager.currentProfile.userName, "你")
        XCTAssertEqual(manager.currentProfile.assistantName, "阿岚")
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
        XCTAssertEqual(try saved(), [manager.currentProfile, original[1]])
        try manager.renameCurrent(userName: "", assistantName: "  ")
        XCTAssertEqual(try saved(), [manager.currentProfile, original[1]])
    }

    func testReadOnlyRenameReportsFailureWithoutChangingNamesOrDefaults() throws {
        manager = ProfileManager(container: manager.container, profiles: original, currentProfile: original[0],
                                 loadError: CocoaError(.fileReadNoPermission), root: root, defaults: defaults, sideEffectsEnabled: false)
        XCTAssertThrowsError(try manager.renameCurrent(userName: "栗子", assistantName: "阿岚")) { error in
            XCTAssertTrue(error is ProfileManager.ReadOnlyError)
        }
        XCTAssertEqual(manager.currentProfile, original[0])
        XCTAssertEqual(manager.profiles, original)
        XCTAssertEqual(try saved(), original)
        XCTAssertEqual(defaults.string(forKey: "userName"), "你")
        XCTAssertEqual(defaults.string(forKey: "assistantName"), "助手")
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
    }

    func testFailedWriteDoesNotPublishOrChangeDefaultName() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try manager.renameCurrent(userName: "栗子", assistantName: "阿岚")) { error in
            guard case .writeFailed? = error as? ProfileManager.SaveError else {
                return XCTFail("应返回写盘失败错误：\(error)")
            }
        }
        XCTAssertEqual(manager.currentProfile, original[0])
        XCTAssertEqual(manager.profiles, original)
        XCTAssertEqual(try saved(), original)
        XCTAssertEqual(defaults.string(forKey: "userName"), "你")
        XCTAssertEqual(defaults.string(forKey: "assistantName"), "助手")
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
        XCTAssertEqual(EffectiveCharacterContext(profile: manager.currentProfile, defaults: defaults).expand("{{user}}/{{char}}"), "你/助手")
    }

    func testNewFloorPublishRenameAndRestartKeepSameStoredProfile() throws {
        let created = Profile(id: "new-floor", name: "新建测试层", emoji: "", description: "", userName: "你", assistantName: "助手")
        manager.addProfile(created)
        XCTAssertEqual(manager.currentProfile, created)
        XCTAssertEqual(manager.profiles.first { $0.id == created.id }, created)
        var materialized = created
        materialized.presetId = "new-floor-preset"
        manager.updateProfile(materialized)
        XCTAssertEqual(manager.currentProfile, materialized)
        XCTAssertEqual(manager.profiles.first { $0.id == created.id }, materialized)

        try manager.renameCurrent(userName: "栗子", assistantName: "阿岚")
        let renamed = manager.currentProfile
        XCTAssertEqual(renamed.id, created.id)
        XCTAssertEqual(renamed.userName, "栗子")
        XCTAssertEqual(manager.profiles.first { $0.id == created.id }, renamed)
        XCTAssertEqual(try saved(), original + [renamed])

        defaults.set("过期镜像", forKey: "userName")
        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        XCTAssertNil(loaded.error)
        let current = try XCTUnwrap(loaded.profiles.first { $0.id == defaults.string(forKey: "lastProfileId") })
        let restarted = ProfileManager(container: manager.container, profiles: loaded.profiles, currentProfile: current,
                                       loadError: loaded.error, root: root, defaults: defaults, sideEffectsEnabled: false)
        XCTAssertEqual(restarted.currentProfile.userName, "栗子")
        XCTAssertEqual(restarted.profiles.first { $0.id == created.id }, restarted.currentProfile)
        XCTAssertEqual(EffectiveCharacterContext(profile: restarted.currentProfile, defaults: defaults).expand("{{user}}/{{char}}"), "栗子/阿岚")
        XCTAssertEqual(try saved(), original + [renamed])
    }

    func testMissingCurrentFloorReportsFailureWithoutChangingDefaultName() throws {
        manager.profiles.removeFirst()
        XCTAssertThrowsError(try manager.renameCurrent(userName: "栗子", assistantName: "阿岚")) { error in
            guard case .profileMissing? = error as? ProfileManager.SaveError else {
                return XCTFail("应返回楼层缺失错误：\(error)")
            }
        }
        XCTAssertEqual(manager.currentProfile, original[0])
        XCTAssertEqual(try saved(), original)
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
    }

    func testSameFloorEditRefreshesUntouchedUserNameBeforeSavingAssistantChange() throws {
        var draft = ProfileNameDraft()
        draft.refresh(profileId: manager.currentProfile.id, userName: "你", assistantName: "助手")
        draft.assistantName = "阿岚"
        var edited = manager.currentProfile
        edited.userName = "栗子"
        try ProfileEditorSheet.commitEdits(edited, profileManager: manager, presetManager: nil)

        draft.refresh(profileId: edited.id, userName: edited.userName, assistantName: edited.assistantName)
        XCTAssertEqual(draft.userName, "栗子")
        XCTAssertEqual(draft.assistantName, "阿岚")
        try draft.save(using: manager)
        XCTAssertEqual(manager.currentProfile.userName, "栗子")
        XCTAssertEqual(manager.currentProfile.assistantName, "阿岚")
        XCTAssertEqual(try saved(), [manager.currentProfile, original[1]])
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认", "未编辑用户名不能改默认称呼")
    }

    func testNameDraftKeepsEditedUserWhileRefreshingExternalAssistantChange() throws {
        var draft = ProfileNameDraft()
        draft.refresh(profileId: manager.currentProfile.id, userName: "你", assistantName: "助手")
        draft.userName = "本地名字"
        var edited = manager.currentProfile
        edited.userName = "外部名字"
        edited.assistantName = "外部助手"
        try manager.updateProfileChecked(edited)
        draft.refresh(profileId: edited.id, userName: edited.userName, assistantName: edited.assistantName)

        XCTAssertEqual(draft.userName, "本地名字")
        XCTAssertEqual(draft.assistantName, "外部助手")
        try draft.save(using: manager)
        XCTAssertEqual(manager.currentProfile.userName, "本地名字")
        XCTAssertEqual(manager.currentProfile.assistantName, "外部助手")
        XCTAssertEqual(try saved(), [manager.currentProfile, original[1]])
    }

    func testUnchangedWhitespaceDraftDoesNotRewriteDefaultName() throws {
        var draft = ProfileNameDraft()
        draft.refresh(profileId: manager.currentProfile.id, userName: "你", assistantName: "助手")
        draft.userName = " 你\n"
        draft.assistantName = " 助手 "
        let before = try Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root))
        try draft.save(using: manager)
        XCTAssertEqual(try Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root)), before)
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
    }

    func testChangingFloorsDropsOldNameDraftInsteadOfWritingItToAnotherFloor() throws {
        var draft = ProfileNameDraft()
        draft.refresh(profileId: manager.currentProfile.id, userName: "你", assistantName: "助手")
        draft.userName = "未保存名字"
        manager.switchTo(original[1])
        draft.refresh(profileId: original[1].id, userName: original[1].userName, assistantName: original[1].assistantName)
        try draft.save(using: manager)
        XCTAssertEqual(manager.currentProfile, original[1])
        XCTAssertEqual(try saved(), original)
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
    }

    func testFailedDraftSavePreservesEditsAndCanBeConfirmedAgain() throws {
        var draft = ProfileNameDraft()
        draft.refresh(profileId: manager.currentProfile.id, userName: "你", assistantName: "助手")
        draft.userName = "栗子"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try draft.save(using: manager))
        XCTAssertEqual(draft.userName, "栗子")
        XCTAssertEqual(manager.currentProfile, original[0])
        XCTAssertEqual(try saved(), original)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try draft.save(using: manager)
        XCTAssertEqual(manager.currentProfile.userName, "栗子")
        XCTAssertEqual(try saved().first?.userName, "栗子")
    }

    func testEmptyRenameOnReadOnlyFloorDoesNotAttemptSaving() throws {
        manager = ProfileManager(container: manager.container, profiles: original, currentProfile: original[0],
                                 loadError: CocoaError(.fileReadNoPermission), root: root, defaults: defaults, sideEffectsEnabled: false)
        try manager.renameCurrent(userName: " \n", assistantName: "\t")
        XCTAssertEqual(manager.currentProfile, original[0])
        XCTAssertEqual(manager.profiles, original)
        XCTAssertEqual(try saved(), original)
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
    }

    func testManagerInitializationRefreshesBothMirrorsFromCurrentFloor() throws {
        defaults.set("旧用户镜像", forKey: "userName")
        defaults.set("旧助手镜像", forKey: "assistantName")
        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        let current = try XCTUnwrap(loaded.profiles.first { $0.id == original[1].id })
        let restarted = ProfileManager(container: manager.container, profiles: loaded.profiles, currentProfile: current,
                                       loadError: loaded.error, root: root, defaults: defaults, sideEffectsEnabled: false)
        XCTAssertEqual(defaults.string(forKey: "userName"), "小舟")
        XCTAssertEqual(defaults.string(forKey: "assistantName"), "砚")
        XCTAssertEqual(restarted.currentProfile, original[1])
        XCTAssertEqual(try saved(), original)
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
    }

    func testFailedProfileLoadPreservesExistingMirrorsInsteadOfPublishingSeedNames() throws {
        defaults.set("栗子", forKey: "userName")
        defaults.set("阿岚", forKey: "assistantName")
        let path = BlobStore.path(forKey: "savedProfiles", root: root)
        let damaged = Data("unreadable profiles".utf8)
        try damaged.write(to: path)
        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        XCTAssertNotNil(loaded.error)
        let fallback = ProfileManager(container: manager.container, profiles: loaded.profiles, currentProfile: loaded.profiles[0],
                                      loadError: loaded.error, root: root, defaults: defaults, sideEffectsEnabled: false)
        XCTAssertTrue(fallback.isReadOnly)
        XCTAssertEqual(defaults.string(forKey: "userName"), "栗子")
        XCTAssertEqual(defaults.string(forKey: "assistantName"), "阿岚")
        XCTAssertEqual(try Data(contentsOf: path), damaged)
        XCTAssertEqual(DefaultUserName.value(defaults), "旧默认")
    }

    func testFloorEditorCommitsNamesAndPromptButFailedSaveChangesNeither() throws {
        let presets = PresetManager(root: root.appendingPathComponent("presets"), defaults: defaults)
        var floor = manager.currentProfile
        let preset = presets.instantiate(templateId: Preset.balanced.id, for: floor.id)
        floor.presetId = preset.id
        try manager.updateProfileChecked(floor)
        floor.userName = "栗子"
        floor.assistantName = "阿岚"
        floor.systemPrompt = "新的系统提示词"
        try ProfileEditorSheet.commitEdits(floor, profileManager: manager, presetManager: presets)
        XCTAssertEqual(manager.currentProfile, floor)
        XCTAssertEqual(try saved().first, floor)
        XCTAssertEqual(presets.preset(byId: preset.id)?.prompts.first { $0.id == PromptSlot.mainId }?.content, floor.systemPrompt)

        var failed = floor
        failed.userName = "不能假保存"
        failed.systemPrompt = "不能写进预设"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try ProfileEditorSheet.commitEdits(failed, profileManager: manager, presetManager: presets))
        XCTAssertEqual(manager.currentProfile, floor)
        XCTAssertEqual(try saved().first, floor)
        XCTAssertEqual(defaults.string(forKey: "userName"), "栗子")
        XCTAssertEqual(presets.preset(byId: preset.id)?.prompts.first { $0.id == PromptSlot.mainId }?.content, floor.systemPrompt)
    }
}
