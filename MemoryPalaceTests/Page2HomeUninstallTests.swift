import XCTest
@testable import 记忆花园

/// atrium P4-b §4.3 / §4.5：主屏长按「给 TA 卸载」只收紧、只写当前这一层的 `page2.apps.floors.v1`；
/// `rightPanelTools`、别的层、布局文件一个字节不动；系统 App / secret App / 没有楼层拒写；装回去 = 回到跟默认
@MainActor
final class Page2HomeUninstallTests: XCTestCase {

    private var sandbox: Page2AppsSandbox!
    private let a = "xctest-uninstall-a"
    private let b = "xctest-uninstall-b"

    override func setUp() {
        super.setUp()
        sandbox = Page2AppsSandbox()
        sandbox.storeDefaults([:])
    }

    override func tearDown() {
        sandbox.leave()
        super.tearDown()
    }

    /// 内置表里默认装着、能卸的一个（两端内置表不同，不写死）
    private func installedTool() throws -> String {
        try XCTUnwrap(RightPanelToolManager.builtInTools.first { $0.isEnabled && Page2Apps.canUninstallFromHome($0.id) }?.id)
    }

    func testUninstallWritesOnlyThisFloor() throws {
        let id = try installedTool()
        Page2Apps.setFloor(false, for: "calendar" == id ? "memory" : "calendar", profileId: b)
        let otherFloor = Page2Apps.floors().floors[b]
        let rightPanel = try XCTUnwrap(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey))
        let keysBefore = Set(sandbox.defaults.dictionaryRepresentation().keys)

        Page2Apps.uninstallFromHome(id, profileId: a)

        XCTAssertEqual(Page2Apps.floors().stored(id, profileId: a), false, "page2.apps.floors.v1[a][id] == false")
        XCTAssertFalse(Page2Apps.isInstalled(id, profileId: a))
        XCTAssertEqual(Page2Apps.floors().floors[b], otherFloor, "别的层不动")
        XCTAssertTrue(Page2Apps.isInstalled(id, profileId: b))
        XCTAssertTrue(Page2Apps.isInstalled(id, profileId: nil), "默认不动")
        XCTAssertEqual(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey), rightPanel, "`rightPanelTools` 一个字节不动")
        XCTAssertEqual(Set(sandbox.defaults.dictionaryRepresentation().keys), keysBefore, "只改已有的层键，不多写别的键")
    }

    func testUninstallFromEmptyFloorsWritesOnlyFloorsKey() throws {
        let id = try installedTool()
        XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey))
        let keysBefore = Set(sandbox.defaults.dictionaryRepresentation().keys)
        Page2Apps.uninstallFromHome(id, profileId: a)
        XCTAssertEqual(Set(sandbox.defaults.dictionaryRepresentation().keys), keysBefore.union([Page2Apps.floorsKey]))
        XCTAssertEqual(Page2Apps.floors().floors, [a: [id: false]])
    }

    func testReinstallReturnsToFollowingDefault() throws {
        let id = try installedTool()
        Page2Apps.uninstallFromHome(id, profileId: a)
        Page2Apps.setFloor(true, for: id, profileId: a)   // 设置 App / 人页装回来走的同一个写入口
        XCTAssertNil(Page2Apps.floors().stored(id, profileId: a), "和默认一样存成 nil = 跟随默认")
        XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey), "层空了整键删掉，一切复原")
        XCTAssertTrue(Page2Apps.isInstalled(id, profileId: a))
    }

    func testRefusesSystemSecretAndNoFloor() throws {
        for id in RightPanelToolManager.systemToolIds.union(RightPanelToolManager.secretToolIds) {
            XCTAssertFalse(Page2Apps.canUninstallFromHome(id), id)
            Page2Apps.uninstallFromHome(id, profileId: a)
        }
        Page2Apps.uninstallFromHome(try installedTool(), profileId: "")
        XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey), "全部拒写")
        XCTAssertTrue(Page2Apps.isInstalled(RightPanelToolManager.gardenOSToolId, profileId: a))
    }

    func testManagerHidesItOnThisFloorOnly() throws {
        let id = try installedTool()
        let m = RightPanelToolManager(defaults: sandbox.defaults)
        m.activeProfileId = a
        XCTAssertTrue(m.pinnedTools.contains { $0.id == id })
        Page2Apps.uninstallFromHome(id, profileId: a)
        XCTAssertFalse(m.pinnedTools.contains { $0.id == id }, "层键变了 manager 重算：主屏上隐身")
        XCTAssertNotNil(m.tool(byId: id), "隐身不除名")
        m.activeProfileId = b
        XCTAssertTrue(m.pinnedTools.contains { $0.id == id }, "换个人还在")
    }

    func testHomeLayoutFileUntouched() throws {
        let id = try installedTool()
        let name = "xctest-uninstall-home-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("home-layout-v1.json")
        let store = Page2HomeStore(defaults: defaults, fileURL: url)
        store.bootstrap(toolIDs: [id], dockIDs: [])
        let bytes = try Data(contentsOf: url)

        Page2Apps.uninstallFromHome(id, profileId: a)

        XCTAssertEqual(try Data(contentsOf: url), bytes, "布局文件一个字节不动")
        let reloaded = Page2HomeStore(defaults: defaults, fileURL: url)
        XCTAssertTrue(reloaded.layout.rootItems.contains { $0.toolID == id }, "图标还在布局里（隐身不除名）")
    }
}
