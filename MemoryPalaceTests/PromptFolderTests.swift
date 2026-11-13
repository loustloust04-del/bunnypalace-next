import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// C2/C3 v2 第 5 段：文件库「Prompt」与 Prompt 页同一份数据 + 楼层完整底图（全是虚构夹具，临时 BlobStore 根）
@MainActor
final class PromptFolderTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var presets: PresetManager!
    private var profiles: ProfileManager!
    private var floorA: Profile!
    private var floorB: Profile!

    private var blobs: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    private let tail = "尾部事实：《云桥城》灯塔的钥匙藏在第三层。"
    private let customId = "custom-cloudbridge"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptFolderTests-\(UUID().uuidString)")
        suite = "PromptFolderTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        presets = PresetManager(root: blobs, defaults: defaults)
        var a = Profile(id: "floor-a", name: "灯塔", emoji: "", description: "", userName: "阿禾", assistantName: "岚",
                        characterPersonality: "话少，爱看海图。", chatExamples: "{{user}}: 在吗\n{{char}}: 在。")
        var b = Profile(id: "floor-b", name: "云桥", emoji: "", description: "", userName: "小舟", assistantName: "砚")
        let instA = presets.instantiate(templateId: Preset.balanced.id, for: a.id)
        let instB = presets.instantiate(templateId: Preset.balanced.id, for: b.id)
        a.presetId = instA.id
        b.presetId = instB.id
        var edited = instA
        let custom = PromptSlot(id: customId, name: "自建·云桥城/航线", content: String(repeating: "航线记录。", count: 700) + tail)
        let insertAt = edited.prompts.firstIndex { $0.id == PromptSlot.chatHistoryId } ?? edited.prompts.count
        edited.prompts.insert(custom, at: insertAt)
        edited.prompts[edited.prompts.firstIndex { $0.id == PromptSlot.mainId }!].content = "你是{{char}}，陪{{user}}守灯塔。"
        try presets.persistNew(edited)
        try presets.persistNew(instB)
        let schema = Schema([Conversation.self, MessageNode.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        profiles = ProfileManager(container: container, profiles: [a, b], currentProfile: a, loadError: nil,
                                  root: blobs, defaults: defaults, sideEffectsEnabled: false)
        try profiles.persistNew([a, b])
        floorA = a
        floorB = b
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func entries(_ profile: Profile? = nil, presets: PresetManager? = nil, profiles: ProfileManager? = nil) -> [PromptFolder.Entry] {
        let pm = profiles ?? self.profiles!
        let p = pm.profiles.first { $0.id == (profile ?? floorA).id }!
        return PromptFolder.entries(profile: p, presets: (presets ?? self.presets).presets)
    }

    private func entry(_ slotId: String) throws -> PromptFolder.Entry {
        try XCTUnwrap(entries().first { $0.source == .slot(presetId: floorA.presetId, slotId: slotId) })
    }

    private func slot(_ slotId: String, in manager: PresetManager? = nil) -> PromptSlot? {
        (manager ?? presets).preset(byId: floorA.presetId)?.prompts.first { $0.id == slotId }
    }

    private func save(_ entry: PromptFolder.Entry, _ text: String, baseline: String? = nil) throws {
        try PromptFolder.save(entry.path, text: text, baseline: baseline ?? entry.content, profileId: floorA.id,
                              profiles: profiles, presets: presets)
    }

    // MARK: - 列表：顺序、自建槽、隔离

    func testCustomSlotOutsideFiveFieldsIsListedInPromptPageOrderWithFullTail() throws {
        let instance = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        let listed = entries().filter { if case .slot = $0.source { true } else { false } }
        XCTAssertEqual(listed.map(\.name), SlotOrder.ordered(instance.prompts).map(\.name))
        let custom = try entry(customId)
        XCTAssertGreaterThan(custom.content.count, 3000)
        XCTAssertTrue(custom.content.hasSuffix(tail))
        XCTAssertEqual(custom.name, "自建·云桥城/航线")
        XCTAssertTrue(entries().allSatisfy { FileLibraryDisplay.parentFolder($0.path) == PromptFolder.root
            || FileLibraryDisplay.parentFolder($0.path) == PromptFolder.fieldsFolder })
    }

    func testLibraryFolderSitsBesideMemoryAndKeepsSlotOrder() throws {
        var preset = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        preset.prompts.append(PromptSlot(id: "blank", name: "", content: "", isEnabled: false))
        try presets.persistNew(preset)
        let all = entries()
        let realFiles: [FileLibraryStore.FileMeta] = [.init(path: "笔记/航线.md", bytes: 1, modifiedAt: Date()),
                                                       .init(path: "prompt/真文件夹.md", bytes: 1, modifiedAt: Date())]
        var index = FileLibraryDisplay.folderIndex(realFiles)
        FileLibraryMemoryFolder.merge(FileLibraryMemoryFolder.folderIndex([]), into: &index)
        FileLibraryPromptFolder.merge(all, into: &index)
        index[""]?.folders.sort { $0.latest > $1.latest }
        FileLibraryPromptFolder.pinAfterMemory(&index)

        let roots = try XCTUnwrap(index[""]).folders.map(\.path)
        XCTAssertEqual(roots.firstIndex(of: PromptFolder.root), try XCTUnwrap(roots.firstIndex(of: FileLibraryMemoryFolder.root)) + 1)
        XCTAssertTrue(roots.contains("prompt"), "同名真文件夹不被虚拟根吞掉")
        let slotFiles = try XCTUnwrap(index[PromptFolder.root]).files.map(\.path)
        XCTAssertEqual(slotFiles, SlotOrder.ordered(preset.prompts).map { PromptFolder.path(for: .slot(presetId: preset.id, slotId: $0.id)) })
        XCTAssertEqual(index[PromptFolder.fieldsFolder]?.files.count, 2)

        let shown = FileLibraryPromptFolder.display(try entry(customId))
        XCTAssertEqual(shown.title, "自建·云桥城/航线")
        let blank = FileLibraryPromptFolder.display(try entry("blank"))
        XCTAssertEqual(blank.title, "")
        XCTAssertEqual(blank.summary, "未命名 · 已关闭 · （空）")
        XCTAssertTrue(FileLibraryPromptFolder.display(try entry(PromptSlot.chatHistoryId)).summary?.contains("自动填充") == true)
        XCTAssertEqual(blank.chips, ["未命名", "已关闭"], "卡片也带标记")
        XCTAssertEqual(FileLibraryPromptFolder.display(try entry(PromptSlot.chatHistoryId)).chips, ["自动填充"])
        XCTAssertEqual(FileLibraryPromptFolder.display(try entry(customId)).chips, [])
    }

    func testFloorFieldsFolderOnlyWhenFilledAndAfterSlots() throws {
        var index: [String: FileLibraryDisplay.FolderContents] = [:]
        FileLibraryPromptFolder.merge(entries(floorB), into: &index)
        XCTAssertEqual(index[PromptFolder.root]?.folders.map(\.path), [], "一个字段都没填就不出「楼层字段」")
        XCTAssertNil(index[PromptFolder.fieldsFolder])
        XCTAssertEqual(index[PromptFolder.root]?.files.count, entries(floorB).count)

        var filled: [String: FileLibraryDisplay.FolderContents] = [:]
        FileLibraryPromptFolder.merge(entries(), into: &filled)
        XCTAssertEqual(filled[PromptFolder.root]?.folders.map(\.path), [PromptFolder.fieldsFolder])
        XCTAssertEqual(filled[PromptFolder.root]?.folders.first?.fileCount, 2)
        XCTAssertTrue(FileLibraryPromptFolder.foldersAfterFiles(PromptFolder.root), "楼层字段排在所有插槽后面")
        XCTAssertFalse(FileLibraryPromptFolder.foldersAfterFiles(FileLibraryMemoryFolder.root))
        XCTAssertFalse(FileLibraryPromptFolder.foldersAfterFiles("笔记"))
    }

    func testPromptFolderChromeUsesDisplayNamesAndHidesSortAndCreate() throws {
        XCTAssertEqual(FileLibraryPromptFolder.breadcrumb(PromptFolder.root).map(\.name), ["文件库", "Prompt"])
        XCTAssertEqual(FileLibraryPromptFolder.breadcrumb(PromptFolder.fieldsFolder).map(\.name), ["文件库", "Prompt", "楼层字段"])
        XCTAssertEqual(FileLibraryPromptFolder.breadcrumb(PromptFolder.fieldsFolder).map(\.path), ["", PromptFolder.root, PromptFolder.fieldsFolder])
        XCTAssertEqual(FileLibraryPromptFolder.breadcrumb("笔记/航线").map(\.name), ["文件库", "笔记", "航线"])
        XCTAssertTrue(FileLibraryPromptFolder.isVirtualFolder(PromptFolder.root))
        XCTAssertTrue(FileLibraryPromptFolder.isVirtualFolder(PromptFolder.fieldsFolder))
        XCTAssertFalse(FileLibraryPromptFolder.isVirtualFolder(PromptFolder.root + "/真子文件夹"))
        XCTAssertFalse(FileLibraryPromptFolder.isVirtualFolder(""))

        let memory = try entry(PromptSlot.memoryInjectionId)
        XCTAssertEqual(memory.content, "")
        XCTAssertEqual(FileLibraryPromptFolder.readOnlyText(memory), "这一段发送时由系统自动填充。", "空的自动填充槽不留白页")
        var stored = memory
        stored.content = "槽里存的字"
        XCTAssertEqual(FileLibraryPromptFolder.readOnlyText(stored), "槽里存的字")
        XCTAssertEqual(FileLibraryPromptFolder.readOnlyText(try entry(PromptSlot.personaDescriptionId)), "", "可编辑的空槽不加说明")
    }

    func testFloorBAndSharedTemplateStayUntouched() throws {
        let templateBefore = try XCTUnwrap(presets.preset(byId: Preset.balanced.id)).prompts
        let floorBBefore = try XCTUnwrap(presets.preset(byId: floorB.presetId)).prompts
        try save(try entry(PromptSlot.mainId), "新的系统指令")
        try save(try entry(customId), "改过的自建槽")
        XCTAssertEqual(presets.preset(byId: Preset.balanced.id)?.prompts, templateBefore)
        XCTAssertEqual(presets.preset(byId: floorB.presetId)?.prompts, floorBBefore)
        XCTAssertEqual(profiles.profiles.first { $0.id == floorB.id }, floorB)
        XCTAssertFalse(entries(floorB).contains { $0.content.contains("改过的自建槽") })
    }

    // MARK: - 两边同源

    func testLibraryAndPromptPageEditTheSameInstanceAndSurviveReload() throws {
        try save(try entry(customId), "文件库改的：云桥城换了新航线。")
        XCTAssertEqual(slot(customId)?.content, "文件库改的：云桥城换了新航线。")

        // Prompt 页简单模式：草稿是打开时的旧快照，这次只改了后置提醒
        let opened = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        var drafts = PersonaSettingsTab.iOSSimpleDraftSnapshot(from: opened)
        try save(try entry(PromptSlot.mainId), "文件库改的系统指令")
        drafts[PromptSlot.jailbreakId] = "Prompt 页改的后置提醒"
        let result = PersonaSettingsTab.commitSimpleDrafts(drafts, dirty: [PromptSlot.jailbreakId], presetId: floorA.presetId, psm: presets)
        XCTAssertEqual(result.pending, [])
        XCTAssertNil(result.error)
        let saved = try XCTUnwrap(presets.preset(byId: floorA.presetId))

        XCTAssertEqual(try entry(PromptSlot.mainId).content, "文件库改的系统指令", "页面旧快照不能盖回文件库新改的槽")
        XCTAssertEqual(try entry(PromptSlot.jailbreakId).content, "Prompt 页改的后置提醒")

        let refreshed = PersonaSettingsTab.refreshedSimpleDrafts(["main": "旧", "jailbreak": "正在打"], dirty: ["jailbreak"], from: saved)
        XCTAssertEqual(refreshed["main"], "文件库改的系统指令")
        XCTAssertEqual(refreshed["jailbreak"], "正在打")

        let reloadedPresets = PresetManager(root: blobs, defaults: defaults)
        let reloadedProfiles = ProfileManager.loadProfilesChecked(root: blobs, defaults: defaults).profiles
        let reloadedA = try XCTUnwrap(reloadedProfiles.first { $0.id == floorA.id })
        XCTAssertEqual(PromptFolder.entries(profile: reloadedA, presets: reloadedPresets.presets), entries())
    }

    // MARK: - Prompt 页简单模式 / 插槽编辑页的保存会话

    func testSimpleModeKeepsDraftsWhenSaveFailsOrSlotIsGone() throws {
        var drafts = PersonaSettingsTab.iOSSimpleDraftSnapshot(from: try XCTUnwrap(presets.preset(byId: floorA.presetId)))
        drafts[PromptSlot.jailbreakId] = "写不下的后置提醒"
        presets.blockWrites(CocoaError(.fileWriteNoPermission))
        let failed = PersonaSettingsTab.commitSimpleDrafts(drafts, dirty: [PromptSlot.jailbreakId], presetId: floorA.presetId, psm: presets)
        XCTAssertEqual(failed.pending, [PromptSlot.jailbreakId], "写盘失败 dirty 留着，下次再存")
        XCTAssertNotNil(failed.error)
        XCTAssertNotEqual(slot(PromptSlot.jailbreakId)?.content, "写不下的后置提醒", "没写下去就不改内存")
        let refreshed = PersonaSettingsTab.refreshedSimpleDrafts(drafts, dirty: failed.pending,
                                                                 from: try XCTUnwrap(presets.preset(byId: floorA.presetId)))
        XCTAssertEqual(refreshed[PromptSlot.jailbreakId], "写不下的后置提醒", "刷新不替换没存上的草稿")

        let fresh = PresetManager(root: blobs, defaults: defaults)
        var preset = try XCTUnwrap(fresh.preset(byId: floorA.presetId))
        preset.prompts.removeAll { $0.id == PromptSlot.jailbreakId }
        try fresh.persistNew(preset)
        drafts[PromptSlot.mainId] = "这栏能存"
        let gone = PersonaSettingsTab.commitSimpleDrafts(drafts, dirty: [PromptSlot.jailbreakId, PromptSlot.mainId],
                                                         presetId: floorA.presetId, psm: fresh)
        XCTAssertEqual(gone.pending, [PromptSlot.jailbreakId], "槽没了那栏留着，别的栏照存")
        XCTAssertNotNil(gone.error)
        XCTAssertEqual(fresh.preset(byId: floorA.presetId)?.prompts.first { $0.id == PromptSlot.mainId }?.content, "这栏能存")
    }

    private func editSession(_ slotId: String) throws -> PromptSlotEdit {
        PromptSlotEdit(profileId: floorA.id, presetId: floorA.presetId, baseline: try XCTUnwrap(slot(slotId)))
    }

    private func commit(_ edit: PromptSlotEdit, name: String? = nil, content: String? = nil, depth: Int? = nil) throws {
        try edit.commit(name: name ?? edit.baseline.name, role: edit.baseline.role, content: content ?? edit.baseline.content,
                        depth: depth ?? edit.baseline.injectionDepth, profiles: profiles, presets: presets)
    }

    func testSlotEditPageCommitsOnlyChangedFieldsAndChecksContentConflict() throws {
        let edit = try editSession(customId)
        try save(try entry(customId), "文件库在编辑页开着时改的正文")
        try commit(edit, name: "只改了名字")
        XCTAssertEqual(slot(customId)?.name, "只改了名字")
        XCTAssertEqual(slot(customId)?.content, "文件库在编辑页开着时改的正文", "没改正文就不拿旧正文盖回去")

        XCTAssertThrowsError(try commit(edit, content: "编辑页改的正文")) {
            XCTAssertEqual($0 as? PromptFolder.SaveError, .conflict)
        }
        XCTAssertEqual(slot(customId)?.content, "文件库在编辑页开着时改的正文")

        let again = try editSession(customId)
        try commit(again, content: "编辑页改的正文", depth: 2)
        XCTAssertEqual(slot(customId)?.content, "编辑页改的正文")
        XCTAssertEqual(slot(customId)?.injectionDepth, 2)
    }

    func testSlotEditPageAfterReorderDeleteSwitchOrWriteFailureNeverHitsAnotherSlot() throws {
        let edit = try editSession(customId)
        var preset = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        preset.prompts = SlotOrder.moving(preset.prompts, slotId: customId, toIndex: 0)
        try presets.persistNew(preset)
        let others = try XCTUnwrap(presets.preset(byId: floorA.presetId)).prompts.filter { $0.id != customId }
        try commit(edit, content: "重排后照样改到这个槽")
        XCTAssertEqual(slot(customId)?.content, "重排后照样改到这个槽")
        XCTAssertEqual(try XCTUnwrap(presets.preset(byId: floorA.presetId)).prompts.filter { $0.id != customId }, others)

        let failing = try editSession(customId)
        presets.blockWrites(CocoaError(.fileWriteNoPermission))
        XCTAssertThrowsError(try commit(failing, content: "写不下"))
        XCTAssertEqual(slot(customId)?.content, "重排后照样改到这个槽", "失败不改内存")

        let fresh = PresetManager(root: blobs, defaults: defaults)
        let mainEdit = PromptSlotEdit(profileId: floorA.id, presetId: floorA.presetId,
                                      baseline: try XCTUnwrap(fresh.preset(byId: floorA.presetId)?.prompts.first { $0.id == PromptSlot.mainId }))
        let other = fresh.instantiate(templateId: Preset.balanced.id, for: floorA.id)
        var switched = try XCTUnwrap(profiles.profiles.first { $0.id == floorA.id })
        switched.presetId = other.id
        try profiles.updateProfileChecked(switched)
        let otherMain = fresh.preset(byId: other.id)?.prompts.first { $0.id == PromptSlot.mainId }
        XCTAssertThrowsError(try mainEdit.commit(name: "换预设后", role: "system", content: "旧会话", depth: 0, profiles: profiles, presets: fresh)) {
            XCTAssertEqual($0 as? PromptFolder.SaveError, .gone)
        }
        XCTAssertEqual(fresh.preset(byId: other.id)?.prompts.first { $0.id == PromptSlot.mainId }, otherMain, "同 id 的另一份实例不被改")

        switched.presetId = floorA.presetId
        try profiles.updateProfileChecked(switched)
        let deleted = PromptSlotEdit(profileId: floorA.id, presetId: floorA.presetId,
                                     baseline: try XCTUnwrap(fresh.preset(byId: floorA.presetId)?.prompts.first { $0.id == customId }))
        var removed = try XCTUnwrap(fresh.preset(byId: floorA.presetId))
        removed.prompts.removeAll { $0.id == customId }
        try fresh.persistNew(removed)
        XCTAssertThrowsError(try deleted.commit(name: "删了", role: "system", content: "删了", depth: 0, profiles: profiles, presets: fresh)) {
            XCTAssertEqual($0 as? PromptFolder.SaveError, .gone)
        }
        XCTAssertFalse(try XCTUnwrap(fresh.preset(byId: floorA.presetId)).prompts.contains { $0.name == "删了" || $0.content == "删了" })
    }

    // MARK: - 名字与身份

    func testDuplicateSlashEmptyNamesAndDisabledSlotsKeepStableIdentity() throws {
        var preset = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        preset.prompts.append(PromptSlot(id: "dup-1", name: "设定", content: "一号"))
        preset.prompts.append(PromptSlot(id: "dup-2", name: "设定", content: "二号"))
        preset.prompts.append(PromptSlot(id: "slash/id.v2", name: "a/b/../c", content: "斜杠"))
        preset.prompts.append(PromptSlot(id: "blank", name: "", content: "没名字"))
        preset.prompts.append(PromptSlot(id: "off", name: "关着的", content: "关着也列", isEnabled: false))
        try presets.persistNew(preset)

        let all = entries()
        XCTAssertEqual(Set(all.map(\.path)).count, all.count)
        for e in all {
            XCTAssertEqual(PromptFolder.source(of: e.path), e.source)
            XCTAssertTrue(FileLibraryDisplay.parentFolder(e.path) == PromptFolder.root || FileLibraryDisplay.parentFolder(e.path) == PromptFolder.fieldsFolder)
        }
        XCTAssertEqual(all.filter { $0.name == "设定" }.map(\.content), ["一号", "二号"])
        XCTAssertEqual(try entry("slash/id.v2").name, "a/b/../c")
        XCTAssertEqual(try entry("blank").name, "")
        XCTAssertEqual(try entry("off").isEnabled, false)
        XCTAssertEqual(try entry("off").content, "关着也列")

        let before = try entry("dup-2")
        try save(before, "二号改了")
        XCTAssertEqual(slot("dup-1")?.content, "一号")
        XCTAssertEqual(slot("dup-2")?.content, "二号改了")

        var renamed = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        renamed.prompts[renamed.prompts.firstIndex { $0.id == "dup-2" }!].name = "换了名字"
        try presets.persistNew(renamed)
        XCTAssertEqual(try entry("dup-2").path, before.path, "改名不改身份")
        XCTAssertEqual(try entry("dup-2").name, "换了名字")
    }

    // MARK: - marker / 楼层字段 / 非文字设置

    func testMarkerFilesExposeOnlyStoredContentAndAutoFilledAreReadOnly() throws {
        for id in [PromptSlot.timelineId, PromptSlot.worldInfoBeforeId, PromptSlot.worldInfoAfterId,
                   PromptSlot.chatHistoryId, PromptSlot.contextSummaryId, PromptSlot.userProfileId, PromptSlot.memoryInjectionId] {
            XCTAssertFalse(try entry(id).isEditable, id)
        }
        XCTAssertTrue(try entry(PromptSlot.dialogueExamplesId).isEditable)
        var stored = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        stored.prompts[stored.prompts.firstIndex { $0.id == PromptSlot.worldInfoBeforeId }!].content = "组装不读的世界书槽正文"
        try presets.persistNew(stored)
        XCTAssertThrowsError(try save(try entry(PromptSlot.timelineId), "改时间轴")) { XCTAssertEqual($0 as? PromptFolder.SaveError, .readOnly) }
        try commit(try editSession(PromptSlot.worldInfoBeforeId), name: "改名可以", content: "改正文不行")
        XCTAssertEqual(slot(PromptSlot.worldInfoBeforeId)?.content, "组装不读的世界书槽正文")
        XCTAssertEqual(slot(PromptSlot.worldInfoBeforeId)?.name, "改名可以", "自动填充槽只锁正文，名字照常改")
        let base = CatalogFloorBase.make(profile: floorA, presets: presets.presets, names: EffectiveCharacterContext(profile: floorA))
        XCTAssertFalse(base.text.contains("组装不读的世界书槽正文"), "底图不收自动填充槽的存储正文")

        let memory = try entry(PromptSlot.memoryInjectionId)
        XCTAssertEqual(memory.content, slot(PromptSlot.memoryInjectionId)?.content)
        XCTAssertFalse(memory.isEditable)
        XCTAssertThrowsError(try save(memory, "灌进去的记忆")) { XCTAssertEqual($0 as? PromptFolder.SaveError, .readOnly) }
        XCTAssertEqual(slot(PromptSlot.memoryInjectionId)?.content, memory.content)

        let persona = try entry(PromptSlot.personaDescriptionId)
        XCTAssertEqual(persona.content, "", "空 marker 不把楼层字段 / 格式模板灌进来")
        XCTAssertTrue(persona.isEditable)
        let instance = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        for e in entries() {
            XCTAssertFalse(e.content.contains(instance.characterFormat) || e.content.contains(instance.personaFormat)
                           || e.content.contains(instance.scenarioFormat))
        }
    }

    func testFloorFieldsMapRealProfileFieldsAndSaveThroughProfile() throws {
        let fields = entries().compactMap { e -> PromptFolder.Field? in if case .field(let f) = e.source { f } else { nil } }
        XCTAssertEqual(fields, [.characterPersonality, .chatExamples], "只列填过的字段")
        let personality = try XCTUnwrap(entries().first { $0.source == .field(.characterPersonality) })
        XCTAssertEqual(personality.name, "助手性格")
        XCTAssertEqual(personality.content, "话少，爱看海图。")

        try PromptFolder.save(personality.path, text: "话少，最近迷上了灯塔模型。", baseline: personality.content,
                              profileId: floorA.id, profiles: profiles, presets: presets)
        XCTAssertEqual(profiles.currentProfile.characterPersonality, "话少，最近迷上了灯塔模型。")
        let stored = ProfileManager.loadProfilesChecked(root: blobs, defaults: defaults).profiles
        XCTAssertEqual(stored.first { $0.id == floorA.id }?.characterPersonality, "话少，最近迷上了灯塔模型。")
        XCTAssertEqual(stored.map(\.id), [floorA.id, floorB.id], "楼层顺序不变")
    }

    func testSamplingAndSwitchesAreNotListedAsFiles() throws {
        let before = entries()
        var preset = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        preset.sampling.temperature = 1.3
        preset.sampling.maxTokens = 777
        preset.sampling.streaming = false
        preset.rawJSONData = Data("{\"temperature\":1.3}".utf8)
        try presets.persistNew(preset)
        XCTAssertEqual(entries(), before)
        let slotCount = SlotOrder.ordered(preset.prompts).count
        XCTAssertEqual(entries().count, slotCount + 2)
        XCTAssertFalse(entries().contains { $0.content.contains("1.3") || $0.content.contains("777") })
    }

    // MARK: - 旧引用 / 失败

    func testStaleReferenceAfterPresetSwitchOrSlotDeleteCannotEditAnotherSlot() throws {
        let oldMain = try entry(PromptSlot.mainId)
        let other = presets.instantiate(templateId: Preset.balanced.id, for: floorA.id)
        var switched = try XCTUnwrap(profiles.profiles.first { $0.id == floorA.id })
        switched.presetId = other.id
        try profiles.updateProfileChecked(switched)
        let otherMainBefore = presets.preset(byId: other.id)?.prompts.first { $0.id == PromptSlot.mainId }?.content
        XCTAssertThrowsError(try save(oldMain, "旧引用写进来")) { XCTAssertEqual($0 as? PromptFolder.SaveError, .gone) }
        XCTAssertEqual(presets.preset(byId: other.id)?.prompts.first { $0.id == PromptSlot.mainId }?.content, otherMainBefore)

        switched.presetId = floorA.presetId
        try profiles.updateProfileChecked(switched)
        let custom = try entry(customId)
        var preset = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        preset.prompts.removeAll { $0.id == customId }
        try presets.persistNew(preset)
        XCTAssertThrowsError(try save(custom, "删掉的槽")) { XCTAssertEqual($0 as? PromptFolder.SaveError, .gone) }
        XCTAssertFalse(presets.preset(byId: floorA.presetId)!.prompts.contains { $0.content == "删掉的槽" })
    }

    func testSaveFailureAndConflictDoNotPretendSuccess() throws {
        let custom = try entry(customId)
        XCTAssertThrowsError(try save(custom, "别处之后", baseline: "打开时不是这段")) {
            XCTAssertEqual($0 as? PromptFolder.SaveError, .conflict)
        }
        XCTAssertEqual(slot(customId)?.content, custom.content)

        presets.blockWrites(CocoaError(.fileWriteNoPermission))
        XCTAssertThrowsError(try save(custom, "写不下"))
        XCTAssertEqual(slot(customId)?.content, custom.content)
        XCTAssertEqual(PresetManager(root: blobs, defaults: defaults).preset(byId: floorA.presetId)?.prompts.first { $0.id == customId }?.content,
                       custom.content)

        let schema = Schema([Conversation.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let readOnly = ProfileManager(container: container, profiles: [floorA], currentProfile: floorA, loadError: CocoaError(.fileReadCorruptFile),
                                      root: blobs, defaults: defaults, sideEffectsEnabled: false)
        let personality = try XCTUnwrap(entries().first { $0.source == .field(.characterPersonality) })
        XCTAssertThrowsError(try PromptFolder.save(personality.path, text: "写不下", baseline: personality.content,
                                                   profileId: floorA.id, profiles: readOnly, presets: PresetManager(root: blobs, defaults: defaults)))
        XCTAssertEqual(readOnly.currentProfile.characterPersonality, floorA.characterPersonality)
    }

    // MARK: - 备份恢复

    /// 生产 GlobalExporter / PendingImportApplier 写死真实 BlobStore 根和 UserDefaults.standard，隔离环境调不了入口；
    /// 这里逐字照抄两边对 savedPresets / savedProfiles 的处理：导出 dumpUDDataAsJSON（pretty + sortedKeys 落 userdefaults/*.json），
    /// 恢复 applyStagingUserDefaults（jsonObject → data(withJSONObject:) → BlobStore.set）
    func testBackupRestoreRebuildsSameEntriesWithoutPromptCopies() throws {
        MainThreadIO.allowMainThreadInThisTest()
        let library = root.appendingPathComponent("library", isDirectory: true)
        FileLibraryStore.testRootOverride = library
        defer { FileLibraryStore.testRootOverride = nil }
        try save(try entry(customId), "恢复前的自建槽")
        try PromptFolder.save(PromptFolder.path(for: .field(.characterPersonality)), text: "恢复前的性格",
                              baseline: floorA.characterPersonality, profileId: floorA.id, profiles: profiles, presets: presets)

        let staging = root.appendingPathComponent("staging/userdefaults", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let mapping = [("savedProfiles", "profiles.json"), ("savedPresets", "presets.json")]
        for (key, file) in mapping {
            let raw = try XCTUnwrap(try BlobStore.read(forKey: key, root: blobs, defaults: defaults))
            let obj = try JSONSerialization.jsonObject(with: raw)
            try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent(file), options: .atomic)
        }
        let restoredRoot = root.appendingPathComponent("restored", isDirectory: true)
        for (key, file) in mapping {
            let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent(file)))
            try BlobStore.set(try JSONSerialization.data(withJSONObject: obj, options: []), forKey: key, root: restoredRoot)
        }

        let restoredPresets = PresetManager(root: restoredRoot, defaults: defaults)
        let restoredProfiles = ProfileManager.loadProfilesChecked(root: restoredRoot, defaults: defaults).profiles
        let restoredA = try XCTUnwrap(restoredProfiles.first { $0.id == floorA.id })
        let instance = try XCTUnwrap(PromptFolder.instance(profile: restoredA, presets: restoredPresets.presets))
        XCTAssertEqual(instance.id, floorA.presetId)
        XCTAssertEqual(instance.ownerProfileId, floorA.id)
        XCTAssertEqual(instance.sourceTemplateId, Preset.balanced.id)
        XCTAssertEqual(PromptFolder.entries(profile: restoredA, presets: restoredPresets.presets), entries())
        XCTAssertTrue(entries().contains { $0.content == "恢复前的自建槽" } && entries().contains { $0.content == "恢复前的性格" })

        let written = [blobs, restoredRoot, library].flatMap { dir in
            (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).map(\.path)
        }
        XCTAssertFalse(written.contains { $0.contains(PromptFolder.root) || $0.hasSuffix(".txt") }, "Prompt 不落任何虚拟副本")
        let blobFiles = (FileManager.default.enumerator(at: blobs, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .map(\.lastPathComponent)
        XCTAssertEqual(Set(blobFiles), ["savedPresets", "savedProfiles"])
    }

    // MARK: - 物理 .prompt 隔离

    func testPhysicalPromptPathsAreRejectedButExistingFilesStayReadable() throws {
        MainThreadIO.allowMainThreadInThisTest()
        let library = root.appendingPathComponent("library", isDirectory: true)
        FileLibraryStore.testRootOverride = library
        defer { FileLibraryStore.testRootOverride = nil }
        let pid = floorA.id
        let floor = FileLibraryStore.libraryRoot(profileId: pid)
        let legacy = floor.appendingPathComponent(".prompt/旧笔记.md")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "早就在的".write(to: legacy, atomically: true, encoding: .utf8)
        try FileLibraryStore.write("普通.md", content: "普通", profileId: pid)
        try FileManager.default.createSymbolicLink(at: floor.appendingPathComponent("链接"), withDestinationURL: floor.appendingPathComponent(".prompt"))

        for path in [".prompt/新.md", "./.prompt/新.md", ".PROMPT/新.md", "a/../.prompt/fields/characterPersonality.txt", "链接/绕进去.md"] {
            XCTAssertThrowsError(try FileLibraryStore.write(path, content: "x", profileId: pid), path)
            XCTAssertThrowsError(try FileLibraryStore.append(path, content: "x", profileId: pid), path)
            XCTAssertThrowsError(try FileLibraryStore.createIfAbsent(path, content: "x", profileId: pid), path)
        }
        XCTAssertThrowsError(try FileLibraryStore.writeData(".prompt/图.png", data: Data([1, 2]), profileId: pid))
        XCTAssertThrowsError(try FileLibraryStore.rename("普通.md", to: ".prompt/fields/characterPersonality.txt", profileId: pid))
        XCTAssertThrowsError(try FileLibraryStore.rename(".prompt/旧笔记.md", to: "搬出来.md", profileId: pid))
        XCTAssertThrowsError(try FileLibraryStore.edit(".prompt/旧笔记.md", oldString: "早就", newString: "改了", profileId: pid))
        XCTAssertThrowsError(try FileLibraryStore.delete(".prompt/旧笔记.md", profileId: pid))

        let tools: [(String, [String: String])] = [
            ("fs_write", ["path": "./.prompt/新.md", "content": "x"]),
            ("fs_append", ["path": ".prompt/新.md", "content": "x"]),
            ("fs_edit", ["path": ".prompt/旧笔记.md", "old_string": "早就", "new_string": "改了"]),
            ("fs_rename", ["old_path": "普通.md", "new_path": ".Prompt/x.md"]),
            ("fs_delete", ["path": ".prompt/旧笔记.md"]),
            ("fs_read", ["path": PromptFolder.path(for: .field(.characterPersonality))]),
        ]
        for (name, args) in tools {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            let result = FileLibraryTools.execute(name: name, inputJSON: json, profileId: pid)
            XCTAssertTrue(result.isError, name)
            XCTAssertEqual(result.text, FileLibraryAccess.promptDenial, name)
        }
        XCTAssertFalse(FileLibraryAccess.visible(".prompt/旧笔记.md", profileId: pid))
        XCTAssertFalse(FileLibraryAccess.listedVisible(".prompt/旧笔记.md", journalVisible: true))
        XCTAssertTrue(FileLibraryAccess.listedVisible("普通.md", journalVisible: false))

        XCTAssertEqual(try FileLibraryStore.read(".prompt/旧笔记.md", profileId: pid), "早就在的", "已有的真文件照样能读")
        XCTAssertEqual(try String(contentsOf: legacy, encoding: .utf8), "早就在的")
        XCTAssertFalse(FileManager.default.fileExists(atPath: floor.appendingPathComponent(".prompt/新.md").path))
        XCTAssertEqual(try FileLibraryStore.read("普通.md", profileId: pid), "普通")

        let listed = FileLibraryStore.list(profileId: pid)
        XCTAssertTrue(listed.contains { $0.path == ".prompt/旧笔记.md" })
        var index = FileLibraryDisplay.folderIndex(listed)
        FileLibraryPromptFolder.merge(entries(), into: &index)
        let promptFiles = try XCTUnwrap(index[PromptFolder.root]).files.map(\.path)
        XCTAssertTrue(promptFiles.contains(".prompt/旧笔记.md"), "真文件不被虚拟目录遮住")
        XCTAssertTrue(promptFiles.contains(try entry(customId).path))
        XCTAssertEqual(try XCTUnwrap(index[""]).folders.first { $0.path == PromptFolder.root }?.fileCount, entries().count + 1)
    }

    // MARK: - 完整底图

    func testFloorBaseDropsFieldsCoveredByExplicitSlotsAndKeepsSlotlessFields() throws {
        var preset = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        preset.prompts[preset.prompts.firstIndex { $0.id == PromptSlot.charDescriptionId }!].content = "岚是领航员。"
        let scenario = preset.prompts.firstIndex { $0.id == PromptSlot.scenarioId }!
        preset.prompts[scenario].content = "旧港口。"
        preset.prompts[scenario].isEnabled = false
        try presets.persistNew(preset)
        var a = try XCTUnwrap(profiles.profiles.first { $0.id == floorA.id })
        a.characterDescription = "岚是医生。"
        a.scenario = "新港口。"
        a.userPersona = "阿禾是看守。"
        try profiles.updateProfileChecked(a)

        let base = CatalogFloorBase.make(profile: a, presets: presets.presets, names: EffectiveCharacterContext(profile: a))
        let paths = base.sections.map(\.path)
        XCTAssertTrue(base.text.contains("岚是领航员。"))
        XCTAssertFalse(base.text.contains("岚是医生。"), "显式槽覆盖了的楼层字段不再收")
        XCTAssertFalse(paths.contains(PromptFolder.path(for: .field(.characterDescription))))
        XCTAssertFalse(paths.contains(PromptFolder.path(for: .field(.scenario))), "关着但填了字的槽也算覆盖")
        XCTAssertEqual(base.sections.first { $0.path == PromptFolder.path(for: .slot(presetId: a.presetId, slotId: PromptSlot.scenarioId)) }?.isEnabled, false)
        XCTAssertTrue(paths.contains(PromptFolder.path(for: .field(.userPersona))), "空槽照旧兜底")
        XCTAssertTrue(base.text.contains("话少，爱看海图。"), "没有独立槽的性格照旧完整保留")
    }

    func testRunnerFloorBaseIsFullUntruncatedAndKeepsSources() throws {
        var preset = try XCTUnwrap(presets.preset(byId: floorA.presetId))
        preset.prompts.append(PromptSlot(id: "off", name: "关着的", content: "关着的设定也算人填的", isEnabled: false))
        try presets.persistNew(preset)
        var a = try XCTUnwrap(profiles.profiles.first { $0.id == floorA.id })
        a.userPersona = "{{user}}是灯塔看守。"
        a.postInstructions = "回复别太长。"
        try profiles.updateProfileChecked(a)

        let runner = CatalogRunner(defaults: defaults)
        XCTAssertNil(runner.floorBase(profile: a))
        runner.attach(presetManager: presets)
        let base = try XCTUnwrap(runner.floorBase(profile: a))

        XCTAssertGreaterThan(base.text.count, CatalogFloorPrompt.maxChars)
        XCTAssertTrue(base.text.contains(tail))
        XCTAssertTrue(base.text.contains("你是岚，陪阿禾守灯塔。"), "名字宏展开")
        XCTAssertEqual(base.sections.first { $0.path == PromptFolder.path(for: .slot(presetId: a.presetId, slotId: "off")) }?.isEnabled, false)
        XCTAssertTrue(base.text.contains("关着的设定也算人填的"))

        let paths = base.sections.map(\.path)
        let personaAt = try XCTUnwrap(paths.firstIndex(of: PromptFolder.path(for: .field(.userPersona))))
        let customAt = try XCTUnwrap(paths.firstIndex(of: PromptFolder.path(for: .slot(presetId: a.presetId, slotId: customId))))
        XCTAssertLessThan(personaAt, customAt, "空的用户描述槽在原位退回楼层字段")
        XCTAssertEqual(base.sections[personaAt].text, "阿禾是灯塔看守。")
        let examples = try XCTUnwrap(base.sections.first { $0.path == PromptFolder.path(for: .field(.chatExamples)) })
        XCTAssertEqual(examples.text, "阿禾: 在吗\n岚: 在。")
        XCTAssertEqual(Array(paths.suffix(2)), [.characterPersonality, .postInstructions].map { PromptFolder.path(for: .field($0)) },
                       "没有独立槽的字段完整排在后面")
        let instance = try XCTUnwrap(presets.preset(byId: a.presetId))
        XCTAssertFalse(base.text.contains(instance.characterFormat))
        XCTAssertEqual(Set(paths).count, paths.count)
    }
}
