import XCTest
@testable import 记忆花园

/// atrium P4-a 的 iOS 那一半（mac 那一半在 MemoryPalaceTests/GardenOSSystemAppTests）：iOS 内置表里真有「设置」，
/// 恒装、lite 可见、小芽外观列表不含、设置搜索「gardenOS」「主屏」先到 gardenOS 设置
@MainActor
final class GardenOSSystemAppIOSTests: XCTestCase {
    private let id = RightPanelToolManager.gardenOSToolId

    func testBuiltInSettingsApp() throws {
        let tool = try XCTUnwrap(RightPanelToolManager.builtInTools.first { $0.id == id })
        XCTAssertEqual(tool.name, "设置")
        XCTAssertEqual(tool.icon, "gearshape")
        XCTAssertEqual(tool.order, 25)
        XCTAssertTrue(tool.isEnabled)
        XCTAssertEqual(RightPanelToolManager.builtInTools.filter { $0.order == 25 }.count, 1, "order 不撞号")
    }

    func testArchiveOffReadsOnAndPinned() throws {
        let name = "xctest-gardenos-ios-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let saved = RightPanelToolManager.builtInTools.map { t -> RightPanelTool in
            var t = t
            if t.id == id { t.isEnabled = false; t.isPinned = false }
            return t
        }
        defaults.set(try JSONEncoder().encode(saved), forKey: RightPanelToolManager.storageKey)
        let m = RightPanelToolManager(defaults: defaults)
        XCTAssertTrue(m.pinnedTools.contains { $0.id == id })
        XCTAssertTrue(RightPanelToolManager.liteVisibleToolIds.contains(id))
    }

    func testXiaoyaAppearanceListUnchanged() {
        let listed = RightPanelToolManager.builtInTools.filter { AssistantTools.isVisibleAppearanceTool($0.id) }.map(\.id)
        XCTAssertFalse(listed.contains(id))
    }

    /// P4-b：「壁纸」搜得到设置 App 那条；「子应用」改名「App 设置」
    func testWallpaperAndAppSettingsSearch() {
        XCTAssertTrue(SettingsSearchEntry.filtered(for: "壁纸").contains { $0.id == "leaf-gardenos-wallpaper" && $0.tab == .rightPanel })
        XCTAssertEqual(SettingsSearchEntry.pageEntries.first { $0.id == "page-subapps" }?.title, "App 设置")
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "子应用").first?.tab, .subApps)
    }

    /// P4-b 长按卸载：iOS 内置表里能卸的真 App 只写当前层；appearance.json 一个字节不动；「设置」拒写
    func testUninstallFromHomeLeavesAppearanceAndDefaults() throws {
        let name = "xctest-uninstall-ios-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = Page2Apps.defaults
        Page2Apps.defaults = defaults
        defer {
            Page2Apps.defaults = previous
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        defaults.set(try JSONEncoder().encode(RightPanelToolManager.builtInTools), forKey: RightPanelToolManager.storageKey)
        let rightPanel = defaults.data(forKey: RightPanelToolManager.storageKey)
        let appearanceURL = dir.appendingPathComponent("appearance.json")
        try JSONEncoder().encode(Page2AppearanceStore(directory: dir).value).write(to: appearanceURL)
        let appearance = try Data(contentsOf: appearanceURL)

        XCTAssertFalse(Page2Apps.canUninstallFromHome(id))
        Page2Apps.uninstallFromHome(id, profileId: "p")
        XCTAssertNil(defaults.object(forKey: Page2Apps.floorsKey))

        Page2Apps.uninstallFromHome("fileLibrary", profileId: "p")
        XCTAssertEqual(Page2Apps.floors().floors, ["p": ["fileLibrary": false]])
        XCTAssertEqual(defaults.data(forKey: RightPanelToolManager.storageKey), rightPanel)
        XCTAssertEqual(try Data(contentsOf: appearanceURL), appearance)
    }

    func testSearchLandsOnGardenOSSettings() {
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "gardenOS").first?.tab, .rightPanel)
        XCTAssertEqual(SettingsSearchEntry.filtered(for: "主屏").first?.tab, .rightPanel)
        XCTAssertEqual(SettingsSearchEntry.pageEntries.first { $0.id == "page-rightpanel" }?.title, "gardenOS 设置")
    }
}
