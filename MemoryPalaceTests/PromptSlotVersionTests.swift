import AppKit
import SwiftUI
import SwiftData
import WebKit
import XCTest
@testable import 记忆花园

@MainActor
final class PromptSlotVersionTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var presets: PresetManager!
    private var profiles: ProfileManager!
    private var editing: PromptSlotEditing!
    private var target: PromptSlotEditing.Target!
    private var inlineStore: FileVersionStore!
    private let slotId = PromptSlot.charDescriptionId
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptSlotVersionTests-\(UUID().uuidString)")
        suite = "PromptSlotVersionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: FileVersionHistory.enabledKey)
        presets = PresetManager(root: root.appendingPathComponent("blobs"), defaults: defaults)
        var floor = Profile(id: UUID().uuidString, name: "虚构灯塔", emoji: "", description: "", userName: "阿禾", assistantName: "岚")
        var preset = presets.instantiate(templateId: Preset.balanced.id, for: floor.id)
        floor.presetId = preset.id
        preset.prompts[preset.prompts.firstIndex { $0.id == slotId }!].content = "旧设定：守灯塔"
        try presets.persistNew(preset)
        let other = Profile(id: UUID().uuidString, name: "虚构云桥", emoji: "", description: "", userName: "小舟", assistantName: "砚")
        let schema = Schema([Conversation.self, MessageNode.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        profiles = ProfileManager(container: container, profiles: [floor, other], currentProfile: floor, loadError: nil,
                                  root: root.appendingPathComponent("blobs"), defaults: defaults, sideEffectsEnabled: false)
        inlineStore = FileVersionStore(root: root.appendingPathComponent("versions"))
        editing = PromptSlotEditing(store: inlineStore, defaults: defaults)
        target = try editing.open(profileId: floor.id, presetId: preset.id, slotId: slotId, label: "助手设定",
                                  profiles: profiles, presets: presets)
    }

    override func tearDown() async throws {
        for window in windows {
            window.contentView = nil
            window.toolbar = nil
            window.close()
        }
        windows.removeAll()
        try await FileVersionStore.shared.delete(key: target.versionKey)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var content: String? {
        presets.preset(byId: target.presetId)?.prompts.first { $0.id == slotId }?.content
    }

    private func setInline(_ text: String, slotId: String? = nil) throws {
        try editing.setInline(text, profileId: target.profileId, presetId: target.presetId, slotId: slotId ?? self.slotId,
                              profiles: profiles, presets: presets)
    }

    func testEditorManualSaveUpdatesSlotAndAdvancesBaseline() async throws {
        let sheet = editing.editor(target, profiles: profiles, presets: presets, onCancel: {})
        let (window, hosting) = host(sheet)
        defer { window.close() }
        try await waitUntil { try await FileVersionStore.shared.versions(key: self.target.versionKey).count == 1 }
        try await replaceText("新设定：研究海图", in: hosting, window: window)
        try await commandSave(window)
        try await waitUntil { self.content == "新设定：研究海图" }
        try await assertVersions(["新设定：研究海图", "旧设定：守灯塔"], sources: [.manualSave, .external])
        XCTAssertEqual(try sheet.reloadExternalContent().content, "新设定：研究海图")

        try await replaceText("继续编辑：修灯塔", in: hosting, window: window)
        try await commandSave(window)
        try await waitUntil { self.content == "继续编辑：修灯塔" }
        try await assertVersions(["继续编辑：修灯塔", "新设定：研究海图", "旧设定：守灯塔"], sources: [.manualSave, .manualSave, .external])
    }

    func testEditorOpensAsMarkdownWithLiveModeAndPlainTitle() throws {
        let sheet = editing.editor(target, profiles: profiles, presets: presets, onCancel: {})
        XCTAssertEqual(sheet.availableModes, [.live, .preview, .source])
        XCTAssertEqual(FileEditorKind(path: sheet.path).initialMode, .live)
        XCTAssertEqual(sheet.displayTitle, "助手设定")
        let (window, hosting) = host(sheet)
        defer { window.close() }
        XCTAssertEqual(window.title, "助手设定", "顶栏不露虚拟 path 的 .md")
        XCTAssertEqual(try XCTUnwrap(modePicker(in: hosting), diagnostics).selectedSegment, 0, "打开即实时模式")
    }

    func testInlineDebouncesToLatestContentWithoutCancelingAnotherSlot() async throws {
        try setInline("中间稿")
        try setInline("最终稿")
        try setInline("另一栏的用户描述", slotId: PromptSlot.personaDescriptionId)
        try await Task.sleep(for: .milliseconds(100))
        let early = try await inlineStore.versions(key: target.versionKey)
        XCTAssertEqual(early, [], "两秒内不能提前记中间稿")
        let otherKey = PromptSlotEditing.key(profileId: target.profileId, presetId: target.presetId, slotId: PromptSlot.personaDescriptionId)
        try await waitUntil {
            let a = try await self.inlineStore.versions(key: self.target.versionKey)
            let b = try await self.inlineStore.versions(key: otherKey)
            return a.count == 1 && b.count == 1
        }
        let versions = try await inlineStore.versions(key: target.versionKey)
        let latest = try XCTUnwrap(versions.first)
        let text = try await inlineStore.content(key: target.versionKey, id: latest.id)
        XCTAssertEqual(text, "最终稿")
        XCTAssertEqual(versions.map(\.source), [.autoSave])
        let otherVersions = try await inlineStore.versions(key: otherKey)
        let otherVersion = try XCTUnwrap(otherVersions.first)
        let otherText = try await inlineStore.content(key: otherKey, id: otherVersion.id)
        XCTAssertEqual(otherText, "另一栏的用户描述")
    }

    func testRestoredVersionSavesIntoSlotAndNextSaveUsesRestoredBaseline() async throws {
        let sheet = editing.editor(target, profiles: profiles, presets: presets, onCancel: {})
        let (window, hosting) = host(sheet)
        defer { window.close() }
        try await replaceText("新设定", in: hosting, window: window)
        try await commandSave(window)
        try await waitUntil("首次编辑写回插槽") { self.content == "新设定" }
        try await assertVersions(["新设定", "旧设定：守灯塔"], sources: [.manualSave, .external])
        // 恢复 UI 按钮在宿主里点不动，恢复动作由 FileVersionStoreTests / 文件库恢复测试覆盖。
        // restoreVersion 是 FileEditorSheet 的 private 方法；这里读旧版正文，再走实际编辑 / 手动保存路径。
        let versions = try await FileVersionStore.shared.versions(key: target.versionKey)
        let oldest = try XCTUnwrap(versions.last)
        let restored = try await FileVersionStore.shared.content(key: target.versionKey, id: oldest.id)
        try await replaceText(XCTUnwrap(restored), in: hosting, window: window)
        try await commandSave(window)
        try await waitUntil("恢复正文写回插槽") { self.content == "旧设定：守灯塔" }
        try await assertVersions(["旧设定：守灯塔", "新设定", "旧设定：守灯塔"], sources: [.manualSave, .manualSave, .external])
        XCTAssertEqual(try sheet.reloadExternalContent().content, "旧设定：守灯塔")
        try await replaceText("恢复后续写", in: hosting, window: window)
        try await commandSave(window)
        try await waitUntil("恢复后续写保存") { self.content == "恢复后续写" }
        try await assertVersions(["恢复后续写", "旧设定：守灯塔", "新设定", "旧设定：守灯塔"], sources: [.manualSave, .manualSave, .manualSave, .external])
    }

    func testExternalChangeConflictsWithoutOverwritingOrRecording() async throws {
        let sheet = editing.editor(target, profiles: profiles, presets: presets, onCancel: {})
        var external = try XCTUnwrap(presets.preset(byId: target.presetId))
        external.prompts[external.prompts.firstIndex { $0.id == slotId }!].content = "别处改过的设定"
        try presets.persistNew(external)
        do {
            try await XCTUnwrap(sheet.onSaveAsync)("旧窗口的修改", target.initialContent)
            XCTFail("旧基线必须拒存")
        } catch {
            XCTAssertEqual(error as? PromptSlotEditing.SaveError, .conflict)
        }
        XCTAssertEqual(content, "别处改过的设定")
        XCTAssertEqual(try sheet.reloadExternalContent().content, "别处改过的设定")
        let versions = try await FileVersionStore.shared.versions(key: target.versionKey)
        XCTAssertEqual(versions, [])
    }

    func testRecordingDisabledSkipsEditorAndInlineSnapshots() async throws {
        defaults.set(false, forKey: FileVersionHistory.enabledKey)
        let (window, hosting) = host(editing.editor(target, profiles: profiles, presets: presets, onCancel: {}))
        defer { window.close() }
        try await replaceText("开关关闭仍能保存", in: hosting, window: window)
        try await commandSave(window)
        try await waitUntil { self.content == "开关关闭仍能保存" }
        try setInline("关闭时的行内修改")
        try await Task.sleep(for: .milliseconds(2200))
        let manual = try await FileVersionStore.shared.versions(key: target.versionKey)
        let automatic = try await inlineStore.versions(key: target.versionKey)
        XCTAssertEqual(manual, [])
        XCTAssertEqual(automatic, [])
        XCTAssertEqual(content, "关闭时的行内修改")
    }

    func testTurningRecordingOffDuringDebounceDropsPendingSnapshot() async throws {
        try setInline("还没到两秒的修改")
        defaults.set(false, forKey: FileVersionHistory.enabledKey)
        try await Task.sleep(for: .milliseconds(2200))
        let versions = try await inlineStore.versions(key: target.versionKey)
        XCTAssertEqual(versions, [])
    }

    func testOldSheetRejectsSaveAfterProfileSwitch() async throws {
        let sheet = editing.editor(target, profiles: profiles, presets: presets, onCancel: {})
        profiles.currentProfile = profiles.profiles[1]
        do {
            try await XCTUnwrap(sheet.onSaveAsync)("不能串层", target.initialContent)
            XCTFail("切楼层后的旧窗口必须拒存")
        } catch {
            XCTAssertEqual(error as? PromptSlotEditing.SaveError, .profileChanged)
        }
        XCTAssertEqual(content, "旧设定：守灯塔")
        let versions = try await FileVersionStore.shared.versions(key: target.versionKey)
        XCTAssertEqual(versions, [])
    }

    func testOldSheetRejectsChangedPresetAndDeletedSlot() async throws {
        let sheet = editing.editor(target, profiles: profiles, presets: presets, onCancel: {})
        let original = profiles.currentProfile
        var changed = original
        changed.presetId = UUID().uuidString
        profiles.currentProfile = changed
        do {
            try await XCTUnwrap(sheet.onSaveAsync)("不能写旧预设", target.initialContent)
            XCTFail("换预设后的旧窗口必须拒存")
        } catch { XCTAssertEqual(error as? PromptFolder.SaveError, .gone) }
        profiles.currentProfile = original
        var preset = try XCTUnwrap(presets.preset(byId: target.presetId))
        preset.prompts.removeAll { $0.id == slotId }
        try presets.persistNew(preset)
        do {
            try await XCTUnwrap(sheet.onSaveAsync)("不能重建已删插槽", target.initialContent)
            XCTFail("已删插槽不能被旧窗口复活")
        } catch { XCTAssertEqual(error as? PromptFolder.SaveError, .gone) }
        XCTAssertNil(content)
    }

    private func assertVersions(_ expected: [String], sources: [FileVersionStore.Source]) async throws {
        try await waitUntil("版本落盘：\(expected)，来源：\(sources)") {
            try await FileVersionStore.shared.versions(key: self.target.versionKey).count == expected.count
        }
        let versions = try await FileVersionStore.shared.versions(key: target.versionKey)
        var contents: [String] = []
        for version in versions {
            let text = try await FileVersionStore.shared.content(key: target.versionKey, id: version.id)
            contents.append(try XCTUnwrap(text))
        }
        XCTAssertEqual(contents, expected)
        XCTAssertEqual(versions.map(\.source), sources)
    }

    private func host(_ sheet: FileEditorSheet) -> (NSWindow, NSView) {
        let hosting = NSHostingView(rootView: sheet.environment(profiles).environment(presets).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return text }
        for child in view.subviews {
            if let text = textView(in: child) { return text }
        }
        return nil
    }

    private func modePicker(in view: NSView) -> NSSegmentedControl? {
        if let picker = view as? NSSegmentedControl { return picker }
        for child in view.subviews {
            if let picker = modePicker(in: child) { return picker }
        }
        return nil
    }

    private func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews {
            if let web = webView(in: child) { return web }
        }
        return nil
    }

    /// 插槽编辑器按 markdown 打开（实时模式）；替换正文走源码模式的 NSTextView
    private func switchToSource(in view: NSView) async throws {
        try await waitUntil("实时编辑器就绪") {
            guard let web = self.webView(in: view) else { return false }
            return (try? await web.evaluateJavaScript("typeof view !== 'undefined' && view !== null")) as? Bool == true
        }
        let picker = try XCTUnwrap(modePicker(in: view), diagnostics)
        picker.selectedSegment = 2
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))
    }

    private func replaceText(_ text: String, in view: NSView, window: NSWindow) async throws {
        if textView(in: view) == nil { try await switchToSource(in: view) }
        try await waitUntil("可编辑文本视图就绪，准备替换为：\(text)") { self.textView(in: view) != nil }
        let source = try XCTUnwrap(textView(in: view), diagnostics)
        guard window.makeFirstResponder(source) else {
            XCTFail("正文替换无法聚焦；\(diagnostics)")
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        source.setSelectedRange(NSRange(location: 0, length: (source.string as NSString).length))
        source.insertText(text, replacementRange: source.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
    }

    private func commandSave(_ window: NSWindow) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "s",
                                                  charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        guard window.performKeyEquivalent(with: event) else {
            XCTFail("⌘S 未被编辑器处理；\(diagnostics)")
            throw CocoaError(.validationMissingMandatoryProperty)
        }
    }

    func testSimpleDraftCommitRecordsAutoSaveAndSurvivesReload() async throws {
        let recordingWasEnabled = UserDefaults.standard.object(forKey: FileVersionHistory.enabledKey) as? Bool
        UserDefaults.standard.set(true, forKey: FileVersionHistory.enabledKey)
        defer {
            if let recordingWasEnabled {
                UserDefaults.standard.set(recordingWasEnabled, forKey: FileVersionHistory.enabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FileVersionHistory.enabledKey)
            }
        }
        let preset = try XCTUnwrap(presets.preset(byId: target.presetId))
        var drafts = PersonaSettingsTab.iOSSimpleDraftSnapshot(from: preset)
        drafts[slotId] = "简单模式改的设定"
        let result = PersonaSettingsTab.commitSimpleDrafts(drafts, dirty: [slotId], presetId: preset.id, psm: presets)
        XCTAssertEqual(result.pending, [])
        XCTAssertNil(result.error)
        XCTAssertEqual(content, "简单模式改的设定")
        try await assertVersions(["简单模式改的设定"], sources: [.autoSave])
        let reloaded = PresetManager(root: root.appendingPathComponent("blobs"), defaults: defaults)
        XCTAssertEqual(reloaded.preset(byId: preset.id)?.prompts.first { $0.id == slotId }?.content, "简单模式改的设定")
    }

    func testWriteFailureDoesNotMutateSlotOrRecordVersion() async throws {
        let sheet = editing.editor(target, profiles: profiles, presets: presets, onCancel: {})
        presets.blockWrites(CocoaError(.fileWriteNoPermission))
        do {
            try await XCTUnwrap(sheet.onSaveAsync)("写不下", target.initialContent)
            XCTFail("写盘失败不能报成功")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
        }
        XCTAssertEqual(content, target.initialContent)
        let versions = try await FileVersionStore.shared.versions(key: target.versionKey)
        XCTAssertEqual(versions, [])
    }

    func testCopiedPresetKeepsItsOwnHistory() async throws {
        try setInline("原实例的修改")
        var copy = try XCTUnwrap(presets.preset(byId: target.presetId))
        copy.id = UUID().uuidString
        try presets.persistNew(copy)
        var floor = profiles.currentProfile
        floor.presetId = copy.id
        profiles.currentProfile = floor
        try editing.setInline("复制后的独立修改", profileId: floor.id, presetId: copy.id, slotId: slotId,
                              profiles: profiles, presets: presets)
        let copyKey = PromptSlotEditing.key(profileId: floor.id, presetId: copy.id, slotId: slotId)
        try await waitUntil {
            let original = try await self.inlineStore.versions(key: self.target.versionKey)
            let copied = try await self.inlineStore.versions(key: copyKey)
            return original.count == 1 && copied.count == 1
        }
        let originalVersions = try await inlineStore.versions(key: target.versionKey)
        let copyVersions = try await inlineStore.versions(key: copyKey)
        let originalVersion = try XCTUnwrap(originalVersions.first)
        let copyVersion = try XCTUnwrap(copyVersions.first)
        let originalText = try await inlineStore.content(key: target.versionKey, id: originalVersion.id)
        let copyText = try await inlineStore.content(key: copyKey, id: copyVersion.id)
        XCTAssertEqual(originalText, "原实例的修改")
        XCTAssertEqual(copyText, "复制后的独立修改")
    }


    private func viewClasses(in view: NSView) -> [String] {
        [view.className] + view.subviews.flatMap { viewClasses(in: $0) }
    }

    private var diagnostics: String {
        let hosts = windows.map { window in
            let classes = window.contentView.map { viewClasses(in: $0).joined(separator: ", ") } ?? "nil"
            let text = window.contentView.flatMap { textView(in: $0)?.string }
            return "窗口标题=\(window.title.debugDescription)，子视图类名=[\(classes)]，编辑器正文=\(String(reflecting: text))"
        }
        return hosts.joined(separator: "\n") + "\n当前插槽 content=\(String(reflecting: content))"
    }

    private func waitUntil(_ context: String = "插槽正文 / 版本落盘", file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        while clock.now < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待\(context)超时（硬上限 8 秒）；\(diagnostics)", file: file, line: line)
        throw CocoaError(.validationMissingMandatoryProperty)
    }
}
