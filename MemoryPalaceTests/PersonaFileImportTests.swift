import XCTest
import SwiftData
@testable import 记忆花园

final class PersonaFileImportTests: XCTestCase {
    func testUTF8BOMIsRemoved() throws {
        let body = "# 设定\n你好，{{char}}。\n\n保留正文里的\u{FEFF}字符。"
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
        XCTAssertEqual(try PersonaFileImport.text(from: data), body)
    }

    func testNonUTF8Throws() {
        for data in [Data([0xFF, 0xFE, 0x61, 0x00]), Data([0xC3, 0x28]), Data([0xE4, 0xB8])] {
            XCTAssertThrowsError(try PersonaFileImport.text(from: data)) { error in
                guard case .notUTF8? = error as? PersonaFileImport.ImportError else {
                    return XCTFail("应拒绝非 UTF-8 数据：\(error)")
                }
            }
        }
    }

    func testEmptyAndWhitespaceOnlyThrow() {
        for text in ["", " \t", "\n\r\n\t \n", "\u{3000}\u{00A0}\n", "\u{FEFF}\n \t"] {
            XCTAssertThrowsError(try PersonaFileImport.text(from: Data(text.utf8))) { error in
                guard case .empty? = error as? PersonaFileImport.ImportError else {
                    return XCTFail("应拒绝空文本：\(error)")
                }
            }
        }
    }

    func testTrimsOnlyOuterBlankLinesAndPreservesMarkdownWhitespace() throws {
        let body = "  # 设定  \n\n\t\n    缩进代码\n结尾保留空格  \t"
        XCTAssertEqual(try PersonaFileImport.text(from: Data(" \t\n\n\(body)\n \t\n".utf8)), body)
        XCTAssertEqual(try PersonaFileImport.text(from: Data(body.utf8)), body)
    }

    func testCRLFAndInternalBlankLinesArePreserved() throws {
        let body = "\t# 设定  \r\n\r\n  \r\n正文\t"
        XCTAssertEqual(try PersonaFileImport.text(from: Data("\r\n \t\r\n\(body)\r\n \r\n".utf8)), body)
    }

    func testLargeTextIsNotTruncated() throws {
        let body = String(repeating: "# 设定\n\n    代码与 {{char}}\n", count: 20_000) + "末尾原文"
        XCTAssertEqual(try PersonaFileImport.text(from: Data(body.utf8)), body)
    }

    @MainActor
    func testExistingProfileIsUnchangedWithoutReplacementConfirmation() throws {
        var profile = Profile(id: "persona-import", name: "测试楼层", emoji: "", description: "", userName: "你", assistantName: "助手")
        profile.systemPrompt = "已有系统提示"
        profile.characterDescription = "保留助手设定"
        let original = profile
        let imported = try PersonaFileImport.text(from: Data("\n# 新系统提示\n\n完整正文\n".utf8))

        XCTAssertFalse(PersonaSettingsTab.applyPersonaFile(imported, to: &profile))
        XCTAssertEqual(profile, original, "未确认时不写任何楼层字段")

        XCTAssertTrue(PersonaSettingsTab.applyPersonaFile(imported, to: &profile, confirmedReplacement: true))
        var expected = original
        expected.systemPrompt = imported
        XCTAssertEqual(profile, expected, "确认后只替换系统提示，不追加、不改其他字段")
    }

    @MainActor
    func testEmptyProfileImportsWithoutConfirmation() {
        var profile = Profile(id: "persona-import-empty", name: "测试楼层", emoji: "", description: "", userName: "你", assistantName: "助手")
        profile.systemPrompt = ""
        var expected = profile
        expected.systemPrompt = "# 系统提示\n\n完整正文"
        XCTAssertTrue(PersonaSettingsTab.applyPersonaFile(expected.systemPrompt, to: &profile))
        XCTAssertEqual(profile, expected)
    }

    @MainActor
    private func withImportManagers(
        mainEnabled: Bool = true, systemPrompt: String = "旧系统提示",
        _ run: (ProfileManager, PresetManager, URL, UserDefaults) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PersonaFileImportTests-\(UUID().uuidString)")
        let suite = "PersonaFileImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let presets = PresetManager(root: root, defaults: defaults)
        var profile = Profile(id: "import-a", name: "测试甲", emoji: "", description: "", userName: "你", assistantName: "助手")
        profile.systemPrompt = systemPrompt
        var instance = presets.instantiate(templateId: Preset.balanced.id, for: profile.id)
        let index = try XCTUnwrap(instance.prompts.firstIndex { $0.id == PromptSlot.mainId })
        instance.prompts[index].content = "旧预设系统指令"
        instance.prompts[index].isEnabled = mainEnabled
        presets.save(instance)
        profile.presetId = instance.id
        let other = Profile(id: "import-b", name: "测试乙", emoji: "", description: "", userName: "你", assistantName: "助手")
        let schema = Schema([Conversation.self])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let profiles = ProfileManager(container: container, profiles: [profile, other], currentProfile: profile,
                                      loadError: nil, root: root, defaults: defaults, sideEffectsEnabled: false)
        try profiles.persistNew([profile, other])
        try run(profiles, presets, root, defaults)
    }

    private func presetSnapshot(_ presets: [Preset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(presets)
    }

    @MainActor
    func testEnabledMainSlotWaitsForChoiceWithoutWriting() throws {
        try withImportManagers { profiles, presets, root, _ in
            let original = profiles.profiles
            let originalPresets = try presetSnapshot(presets.presets)
            let profileData = try Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root))
            let presetData = try Data(contentsOf: BlobStore.path(forKey: "savedPresets", root: root))
            let result = try PersonaSettingsTab.applyPersonaImport("# 新人设", profileId: original[0].id,
                                                                  pm: profiles, psm: presets)
            guard case .needsConfirmation(let pending) = result else { return XCTFail("主槽有内容时应先等选择") }
            XCTAssertTrue(pending.mainSlotOverrides)
            XCTAssertEqual(pending.existingCharacterCount, original[0].systemPrompt.count)
            XCTAssertEqual(profiles.profiles, original)
            XCTAssertEqual(try presetSnapshot(presets.presets), originalPresets)
            XCTAssertEqual(try Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root)), profileData)
            XCTAssertEqual(try Data(contentsOf: BlobStore.path(forKey: "savedPresets", root: root)), presetData)
        }
    }

    @MainActor
    func testClearMainSlotAndImportPersistsBothChanges() throws {
        try withImportManagers { profiles, presets, root, defaults in
            let original = profiles.currentProfile
            let originalPreset = try XCTUnwrap(presets.preset(byId: original.presetId))
            let imported = "# 新系统提示\n\n完整人设正文"
            let result = try PersonaSettingsTab.applyPersonaImport(imported, profileId: original.id, action: .clearMainSlot,
                                                                  pm: profiles, psm: presets)
            guard case .imported(let overrides) = result else { return XCTFail("确认清槽后应一次导入") }
            XCTAssertFalse(overrides)
            var expected = original
            expected.systemPrompt = imported
            XCTAssertEqual(profiles.currentProfile, expected)
            XCTAssertEqual(ProfileManager.loadProfiles(root: root, defaults: defaults), profiles.profiles)
            let reloaded = try XCTUnwrap(PresetManager(root: root, defaults: defaults).preset(byId: original.presetId))
            var expectedPreset = originalPreset
            expectedPreset.prompts[try XCTUnwrap(expectedPreset.prompts.firstIndex { $0.id == PromptSlot.mainId })].content = ""
            XCTAssertEqual(try presetSnapshot([reloaded]), try presetSnapshot([expectedPreset]))
        }
    }

    @MainActor
    func testSystemPromptOnlyLeavesMainSlotUntouched() throws {
        try withImportManagers { profiles, presets, root, defaults in
            let original = profiles.currentProfile
            let originalPresets = try presetSnapshot(presets.presets)
            let presetData = try Data(contentsOf: BlobStore.path(forKey: "savedPresets", root: root))
            let result = try PersonaSettingsTab.applyPersonaImport("# 只写楼层", profileId: original.id, action: .systemPromptOnly,
                                                                  pm: profiles, psm: presets)
            guard case .imported(let overrides) = result else { return XCTFail("确认后应导入系统提示") }
            XCTAssertTrue(overrides)
            var expected = original
            expected.systemPrompt = "# 只写楼层"
            XCTAssertEqual(profiles.currentProfile, expected)
            XCTAssertEqual(ProfileManager.loadProfiles(root: root, defaults: defaults), profiles.profiles)
            XCTAssertEqual(try presetSnapshot(presets.presets), originalPresets)
            XCTAssertEqual(try Data(contentsOf: BlobStore.path(forKey: "savedPresets", root: root)), presetData)
        }
    }

    @MainActor
    func testDisabledMainSlotDoesNotOverrideOrRequireSlotChoice() throws {
        for previous in ["", "已有系统提示"] {
            try withImportManagers(mainEnabled: false, systemPrompt: previous) { profiles, presets, _, _ in
                let originalPresets = try presetSnapshot(presets.presets)
                let id = profiles.currentProfile.id
                var result = try PersonaSettingsTab.applyPersonaImport("# 导入正文", profileId: id, pm: profiles, psm: presets)
                if !previous.isEmpty {
                    guard case .needsConfirmation(let pending) = result else { return XCTFail("原系统提示非空仍需确认替换") }
                    XCTAssertFalse(pending.mainSlotOverrides)
                    XCTAssertEqual(profiles.currentProfile.systemPrompt, previous)
                    result = try PersonaSettingsTab.applyPersonaImport(pending.text, profileId: id, action: .systemPromptOnly,
                                                                     pm: profiles, psm: presets)
                }
                guard case .imported(let overrides) = result else { return XCTFail("关闭的主槽不应要求清槽") }
                XCTAssertFalse(overrides)
                XCTAssertEqual(profiles.currentProfile.systemPrompt, "# 导入正文")
                XCTAssertEqual(try presetSnapshot(presets.presets), originalPresets)
            }
        }
    }

    @MainActor
    func testConfirmationAfterFloorSwitchWritesNeitherStore() throws {
        try withImportManagers { profiles, presets, root, _ in
            let targetId = profiles.currentProfile.id
            _ = try PersonaSettingsTab.applyPersonaImport("# 新人设", profileId: targetId, pm: profiles, psm: presets)
            profiles.switchTo(try XCTUnwrap(profiles.profiles.last))
            let original = profiles.profiles
            let current = profiles.currentProfile
            let originalPresets = try presetSnapshot(presets.presets)
            let profileData = try Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root))
            let presetData = try Data(contentsOf: BlobStore.path(forKey: "savedPresets", root: root))
            for action in [PersonaSettingsTab.PersonaImportAction.clearMainSlot, .systemPromptOnly] {
                XCTAssertThrowsError(try PersonaSettingsTab.applyPersonaImport("# 新人设", profileId: targetId, action: action,
                                                                             pm: profiles, psm: presets)) { error in
                    guard case .profileChanged? = error as? PersonaSettingsTab.PersonaImportError else {
                        return XCTFail("切楼层后应拒绝导入：\(error)")
                    }
                }
            }
            XCTAssertEqual(profiles.profiles, original)
            XCTAssertEqual(profiles.currentProfile, current)
            XCTAssertEqual(try presetSnapshot(presets.presets), originalPresets)
            XCTAssertEqual(try Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root)), profileData)
            XCTAssertEqual(try Data(contentsOf: BlobStore.path(forKey: "savedPresets", root: root)), presetData)
        }
    }

    @MainActor
    func testConfirmationRereadsLatestProfileAndPresetInstance() throws {
        try withImportManagers { profiles, presets, _, _ in
            let original = profiles.currentProfile
            let oldPreset = try XCTUnwrap(presets.preset(byId: original.presetId))
            let result = try PersonaSettingsTab.applyPersonaImport("# 新人设", profileId: original.id, pm: profiles, psm: presets)
            guard case .needsConfirmation(let pending) = result else { return XCTFail("应先等确认") }
            var latestPreset = presets.instantiate(templateId: Preset.balanced.id, for: original.id)
            let index = try XCTUnwrap(latestPreset.prompts.firstIndex { $0.id == PromptSlot.mainId })
            var main = latestPreset.prompts.remove(at: index)
            main.content = "确认期间换到的新预设"
            latestPreset.prompts.append(main)
            presets.save(latestPreset)
            var latestProfile = original
            latestProfile.presetId = latestPreset.id
            latestProfile.characterDescription = "确认期间更新的助手设定"
            profiles.profiles[0] = latestProfile

            _ = try PersonaSettingsTab.applyPersonaImport(pending.text, profileId: pending.profileId, action: .clearMainSlot,
                                                         pm: profiles, psm: presets)
            latestProfile.systemPrompt = pending.text
            XCTAssertEqual(profiles.currentProfile, latestProfile)
            XCTAssertEqual(try presetSnapshot([XCTUnwrap(presets.preset(byId: oldPreset.id))]), try presetSnapshot([oldPreset]))
            let saved = try XCTUnwrap(presets.preset(byId: latestPreset.id))
            XCTAssertEqual(saved.prompts.first { $0.id == PromptSlot.mainId }?.content, "")
            XCTAssertEqual(saved.prompts.filter { $0.id != PromptSlot.mainId },
                           SlotOrder.normalized(latestPreset).prompts.filter { $0.id != PromptSlot.mainId })
        }
    }
}
