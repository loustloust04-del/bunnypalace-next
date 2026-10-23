import XCTest
import UniformTypeIdentifiers
@testable import 记忆花园

@MainActor
final class MacWorkspacePreferencesTests: XCTestCase {
    private func make() -> (UserDefaults, MacWorkspacePreferences, String) {
        let name = "test-mac-workspace-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, MacWorkspacePreferences(defaults: defaults), name)
    }

    func testDockDragTypeCannotBeMistakenForConversationText() {
        XCTAssertTrue(UTType.macDockEntry.conforms(to: .data))
        XCTAssertFalse(UTType.macDockEntry.conforms(to: .text))
        let declarations = Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]] ?? []
        XCTAssertTrue(declarations.contains { $0["UTTypeIdentifier"] as? String == UTType.macDockEntry.identifier })
    }

    func testDefaultsPreserveLegacyOrderWithoutWriting() {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        let before = defaults.dictionaryRepresentation()
        let entries = prefs.items(seed: ["b", "a", "b"])
        XCTAssertEqual(entries.compactMap(\.toolID), ["b", "a", "home", MacWorkspacePreferences.modeID])
        XCTAssertEqual(entries.filter { $0.kind == .divider }.count, 1)
        XCTAssertNil(prefs.dockItems)
        XCTAssertEqual(defaults.dictionaryRepresentation().count, before.count)
    }

    func testDefaultGroupsKeepExistingToolOrder() {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        let seed = ["fileLibrary", "calendar", "ccTerminal", "browser", "sticker", "health"]
        let entries = prefs.items(seed: seed)
        XCTAssertEqual(Array(entries.compactMap(\.toolID).prefix(seed.count)), seed)
        XCTAssertEqual(entries.filter { $0.kind == .divider }.count, 4)
        XCTAssertEqual(prefs.items(seed: seed), entries)
    }

    func testDividerAndToolsMoveToBothEdgesAndPersist() {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        let seed = ["a", "b", "c"]
        prefs.insertDivider(after: "tool:a", seed: seed)
        let divider = prefs.items(seed: seed)[1]
        XCTAssertEqual(divider.kind, .divider)
        prefs.move(divider.id, relativeTo: "tool:c", after: true, seed: seed)
        XCTAssertEqual(prefs.items(seed: seed).prefix(4).map(\.id), ["tool:a", "tool:b", "tool:c", divider.id])
        prefs.move("tool:a", relativeTo: nil, seed: seed)
        XCTAssertEqual(prefs.items(seed: seed).last?.id, "tool:a")
        prefs.move("tool:a", relativeTo: "tool:b", seed: seed)
        XCTAssertEqual(prefs.items(seed: seed).first?.id, "tool:a")
        XCTAssertEqual(MacWorkspacePreferences(defaults: defaults).items(seed: []), prefs.items(seed: seed))
    }

    func testRemovingEntryDoesNotChangeLegacySeedAndCanBeRestored() {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["a", "b"], forKey: "page2DockTools_v1")
        prefs.remove("tool:a", seed: ["a", "b"])
        XCTAssertFalse(prefs.items(seed: ["a", "b"]).contains { $0.toolID == "a" })
        XCTAssertEqual(defaults.stringArray(forKey: "page2DockTools_v1"), ["a", "b"])
        prefs.addTool("a", seed: ["a", "b"])
        XCTAssertEqual(prefs.items(seed: []).last?.toolID, "a")
        prefs.resetDock()
        XCTAssertEqual(prefs.items(seed: ["a", "b"]).first?.toolID, "a")
    }

    func testSettingsMoveKeepsDividerIdentityAndUnknownTools() {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        let seed = ["a", "missing-plugin", "b"]
        let original = prefs.items(seed: seed)
        prefs.move(from: IndexSet([0, 1]), to: original.count, seed: seed)
        let result = prefs.items(seed: [])
        XCTAssertEqual(Array(result.suffix(2)).compactMap(\.toolID), ["a", "missing-plugin"])
        XCTAssertEqual(Set(result.map(\.id)), Set(original.map(\.id)))
    }

    func testSelfDropIsNoOpAndCodeVisibilityPersistsSeparately() {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        prefs.move("tool:a", relativeTo: "tool:a", after: true, seed: ["a"])
        XCTAssertNil(prefs.dockItems)
        prefs.showCodingSessions = false
        let reloaded = MacWorkspacePreferences(defaults: defaults)
        XCTAssertFalse(reloaded.showCodingSessions)
        XCTAssertNil(reloaded.dockItems)
    }

    /// 左栏面板组「对话 | Code」：选中的 tab 跟 dock 存在同一份档里；Code 开关关掉 → 只剩「对话」、恢复也回「对话」
    func testLeftPanelTabPersistsAndFollowsCodeVisibility() {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(prefs.leftPanelTab, .chats)
        XCTAssertEqual(prefs.leftPanelTabs, [.chats, .code])
        prefs.leftPanelTab = .code
        var reloaded = MacWorkspacePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.leftPanelTab, .code)
        XCTAssertEqual(reloaded.restoredLeftPanelTab, .code)
        reloaded.showCodingSessions = false
        reloaded = MacWorkspacePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.leftPanelTabs, [.chats])
        XCTAssertEqual(reloaded.restoredLeftPanelTab, .chats)
        XCTAssertEqual(MacLeftPanelTab(panelID: MacLeftPanelTab.code.panelID), .code)
        XCTAssertNil(MacLeftPanelTab(panelID: "code"))
    }

    /// 菜单栏快看（research-magpie §2.6）：默认开；关掉存进同一份档；旧档没这个键时照默认开
    func testMenuBarExtraDefaultsOnAndPersists() throws {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(prefs.showMenuBarExtra)
        prefs.showMenuBarExtra = false
        XCTAssertFalse(MacWorkspacePreferences(defaults: defaults).showMenuBarExtra)
        prefs.showMenuBarExtra = true
        XCTAssertTrue(MacWorkspacePreferences(defaults: defaults).showMenuBarExtra)

        let legacy = try JSONSerialization.data(withJSONObject: ["showCodingSessions": true])
        defaults.set(legacy, forKey: "mac.workspace.preferences.v1")
        XCTAssertTrue(MacWorkspacePreferences(defaults: defaults).showMenuBarExtra)
    }

    func testUtilityButtonsAreAlsoRemovableAndMovable() {
        let (defaults, prefs, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        prefs.move("tool:home", relativeTo: "tool:a", seed: ["a"])
        XCTAssertEqual(prefs.items(seed: []).first?.toolID, "home")
        prefs.remove("tool:" + MacWorkspacePreferences.modeID, seed: ["a"])
        XCTAssertFalse(prefs.items(seed: []).contains { $0.toolID == MacWorkspacePreferences.modeID })
    }
}
