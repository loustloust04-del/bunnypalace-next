import XCTest
@testable import 记忆花园

/// atrium P4-a（plan-atrium-p4-tool-settings §3.6）：gardenOS「设置」是系统 App——恒装、拒写、不进开关列表、小芽看不见；
/// 全新主屏 Dock 第一格是它，老存档 / 老布局文件一个字节不变。
/// mac 内置表里没有它（只进 iOS platformTools），所以这里用含它的内置表 / 存档直接喂；`systemToolIds` 两端同一份，过滤逻辑 mac 上能真跑。
@MainActor
final class GardenOSSystemAppTests: XCTestCase {

    private var sandbox: Page2AppsSandbox!
    private let a = "xctest-gardenos-a"
    private let b = "xctest-gardenos-b"
    private let id = RightPanelToolManager.gardenOSToolId

    private var settingsTool: RightPanelTool { RightPanelTool(id: id, name: "设置", icon: "gearshape", order: 25) }
    private var builtIns: [RightPanelTool] {
        [RightPanelTool(id: "calendar", name: "日历", icon: "calendar", order: 0),
         RightPanelTool(id: "fileLibrary", name: "文件库", icon: "folder.fill", order: 7),
         settingsTool]
    }

    override func setUp() {
        super.setUp()
        sandbox = Page2AppsSandbox()
    }

    override func tearDown() {
        sandbox.leave()
        super.tearDown()
    }

    func testIsSystemApp() {
        XCTAssertEqual(id, "gardenOS")
        XCTAssertEqual(RightPanelToolManager.systemToolIds, [id])
        XCTAssertTrue(RightPanelToolManager.secretToolIds.isDisjoint(with: RightPanelToolManager.systemToolIds))
        #if os(macOS)
        XCTAssertFalse(RightPanelToolManager.builtInTools.contains { $0.id == id }, "mac 不加 gardenOS")
        #endif
    }

    // MARK: 1. 恒开

    func testMergedForcesSystemAppOnEvenIfArchiveSaysOff() {
        var off = settingsTool
        off.isEnabled = false
        off.isPinned = false
        let saved = [RightPanelTool(id: "calendar", name: "日历", icon: "calendar", isEnabled: false, order: 0), off]
        let merged = RightPanelToolManager.merged(saved: saved, builtIns: builtIns)
        XCTAssertEqual(merged.first { $0.id == id }?.isEnabled, true, "存档写关也读成开")
        XCTAssertEqual(merged.first { $0.id == id }?.isPinned, true)
        XCTAssertEqual(merged.first { $0.id == "calendar" }?.isEnabled, false, "别的 App 的关照旧")

        let missing = RightPanelToolManager.merged(saved: [saved[0]], builtIns: builtIns)
        XCTAssertEqual(missing.first { $0.id == id }?.isEnabled, true, "老存档没有它：按内置补，开")
    }

    func testManagerKeepsSystemAppPinnedOnEveryFloor() {
        let floors = Page2AppFloors(floors: [a: [id: false]])
        sandbox.defaults.set(floors.encoded(), forKey: Page2Apps.floorsKey)
        let m = RightPanelToolManager(defaults: sandbox.defaults)
        m.setDefaultTools(RightPanelToolManager.merged(saved: builtIns, builtIns: builtIns))
        XCTAssertTrue(m.pinnedTools.contains { $0.id == id })
        m.activeProfileId = a
        XCTAssertTrue(m.pinnedTools.contains { $0.id == id }, "层里手写的「卸」也不生效")
        m.activeProfileId = b
        XCTAssertTrue(m.pinnedTools.contains { $0.id == id })
    }

    // MARK: 2. manager 写入口拒写

    func testSetEnabledRefusesSystemAppBothTargets() throws {
        sandbox.storeDefaults(["prompt": false])
        let before = try XCTUnwrap(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey))
        let m = RightPanelToolManager(defaults: sandbox.defaults)
        m.setDefaultTools(RightPanelToolManager.merged(saved: builtIns, builtIns: builtIns))
        m.setEnabled(id, false, target: .defaults)
        XCTAssertEqual(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey), before, "`rightPanelTools` 一个字节不动")
        XCTAssertEqual(m.tool(byId: id)?.isEnabled, true)
        m.setEnabled(id, false, target: .floor(a))
        XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey), "`page2.apps.floors.v1` 不写")
        XCTAssertEqual(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey), before)
    }

    // MARK: 3. Page2Apps 拒写 / 恒装

    func testPage2AppsRefusesAndAlwaysInstalled() {
        Page2Apps.setFloor(false, for: id, profileId: a)
        XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey), "拒写")
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        XCTAssertFalse(Page2Apps.isInstalled("fileLibrary", profileId: a), "别的 App 照常写")
        for pid in [a, b, nil] as [String?] {
            XCTAssertTrue(Page2Apps.isInstalled(id, profileId: pid))
        }
        XCTAssertTrue(Page2Apps.defaultInstalled(id))
        XCTAssertNil(Page2Apps.overrides(id)[a])

        let handWritten = Page2AppFloors(floors: [a: [id: false]])
        sandbox.defaults.set(handWritten.encoded(), forKey: Page2Apps.floorsKey)
        XCTAssertTrue(Page2Apps.isInstalled(id, profileId: a), "备份 / 手改出来的「卸」也读成装着")
    }

    // MARK: 4. lite

    func testLiteWhitelistHasSystemApp() {
        XCTAssertTrue(RightPanelToolManager.liteVisibleToolIds.contains(id))
    }

    // MARK: 5. 小芽 read_appearance 不列它（请求内容零变化）

    func testXiaoyaAppearanceSkipsSystemApp() {
        XCTAssertFalse(AssistantTools.isVisibleAppearanceTool(id))
        XCTAssertTrue(AssistantTools.isVisibleAppearanceTool("calendar"))
        let listed = RightPanelToolManager.builtInTools.filter { AssistantTools.isVisibleAppearanceTool($0.id) }.map(\.id)
        XCTAssertFalse(listed.contains(id))
        let withoutSystem = RightPanelToolManager.builtInTools.filter { !RightPanelToolManager.systemToolIds.contains($0.id) }
            .filter { AssistantTools.isVisibleAppearanceTool($0.id) }.map(\.id)
        XCTAssertEqual(listed, withoutSystem, "列给小芽的 = 加它之前那份")
    }

    // MARK: 6. 全新主屏 Dock

    func testBootstrapDock() {
        XCTAssertEqual(Page2HomeStore.bootstrapDock(["calendar", "memory", "worldBook", "cardLibrary"]),
                       [id, "calendar", "memory", "worldBook"], "pinned 前 4 → 设置 + 前 3")
        XCTAssertEqual(Page2HomeStore.bootstrapDock(["calendar", id, "memory"]), [id, "calendar", "memory"], "已含不重复")
        XCTAssertEqual(Page2HomeStore.bootstrapDock(["a", "b", "c", "d"]).count, 4, "老 Dock 4 个：第 4 个被挤掉")
        XCTAssertEqual(Page2HomeStore.bootstrapDock([]), [id])
    }

    func testFreshBootstrapPutsSettingsFirstInDock() throws {
        let (defaults, dir) = homeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Page2HomeStore(defaults: defaults, fileURL: dir.appendingPathComponent("home-layout-v1.json"))
        store.bootstrap(toolIDs: ["calendar", "memory", id], dockIDs: Page2HomeStore.bootstrapDock(["calendar", "memory", "vocab", "reading"]))
        XCTAssertEqual(store.layout.dockItems.compactMap(\.toolID), [id, "calendar", "memory", "vocab"])
    }

    // MARK: 零迁移

    func testOldRightPanelArchiveBytesUnchanged() throws {
        let old = [RightPanelTool(id: "calendar", name: "日历", icon: "calendar", isEnabled: false, order: 0)]
        let data = try JSONEncoder().encode(old)
        sandbox.defaults.set(data, forKey: RightPanelToolManager.storageKey)
        let m = RightPanelToolManager(defaults: sandbox.defaults)
        m.activeProfileId = a
        _ = m.pinnedTools
        _ = Page2Apps.isInstalled(id, profileId: a)
        _ = Page2Apps.defaultInstalled("calendar")
        XCTAssertEqual(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey), data, "读不写回")
    }

    func testOldHomeLayoutBytesUnchanged() throws {
        let (defaults, dir) = homeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaultURL = dir.appendingPathComponent("default.json")
        let old = Page2HomeStore(defaults: defaults, fileURL: defaultURL)
        old.bootstrap(toolIDs: ["calendar", "memory"], dockIDs: ["calendar", "memory", "vocab", "reading"])
        let bytes = try Data(contentsOf: defaultURL)

        let reloaded = Page2HomeStore(defaults: defaults, fileURL: defaultURL)
        reloaded.bootstrap(toolIDs: ["calendar", "memory", id], dockIDs: Page2HomeStore.bootstrapDock(["calendar", "memory", "vocab", "reading"]))
        XCTAssertEqual(try Data(contentsOf: defaultURL), bytes, "已有主屏：bootstrap 不动")
        XCTAssertFalse(reloaded.layout.dockItems.contains { $0.toolID == id })

        let floorURL = dir.appendingPathComponent("floor/home-layout-v1.json")
        let floor = Page2HomeStore(defaults: defaults, fileURL: floorURL, fallbackURL: defaultURL)
        floor.bootstrap(toolIDs: ["calendar", id], dockIDs: Page2HomeStore.bootstrapDock(["calendar"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: floorURL.path), "跟默认的人不因为 bootstrap 写层文件")
        XCTAssertEqual(try Data(contentsOf: defaultURL), bytes)
    }

    private func homeFixture() -> (UserDefaults, URL) {
        let name = "xctest-gardenos-home-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (defaults, dir)
    }
}
