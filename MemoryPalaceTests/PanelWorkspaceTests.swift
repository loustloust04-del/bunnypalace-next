import XCTest
@testable import 记忆花园

/// 命名工作区（plan-panel-ps 阶段 1）：存 / 切 / 重置 / 出厂 / 删 / 改名 / 封顶，全走注入的 suite
@MainActor
final class PanelWorkspaceTests: XCTestCase {
    static let suiteName = "xctest-panel-workspace"
    var defaults: UserDefaults!
    var layout: IPadPanelLayout!
    var store: PanelWorkspaceStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        layout = IPadPanelLayout(defaults: defaults)
        layout.shellMetrics = MacShellMetrics(defaults: defaults)
        store = PanelWorkspaceStore(layout: layout, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func arrangeWriting() {
        layout.leftShown = true
        layout.leftWidth = 300
        layout.open("a"); layout.open("b")
        layout.selectedTool = "a"
        layout.toolWidth = 400
    }

    /// 存 → 改乱 → 切回：整份原样回来，且当前指向它
    func testSaveMutateActivateRestores() {
        arrangeWriting()
        let saved = layout.snapshot()
        let w = store.saveCurrent(as: "写代码")
        XCTAssertEqual(store.activeId, w?.id)
        layout.leftShown = false
        layout.close("a")
        layout.toolWidth = 300
        layout.mode = .floating
        store.activate(w!.id)
        // 层级按读档语义重排（开着的对话窗到最前，同重启），其余逐字段相等
        var now = layout.snapshot(), expected = saved
        now.zOrder = nil; expected.zOrder = nil
        XCTAssertEqual(now, expected)
        XCTAssertEqual(layout.zOrder.last, IPadPanelLayout.convWindowId)
        XCTAssertTrue(layout.leftShown)
        XCTAssertEqual(layout.tabs, ["a", "b"])
        XCTAssertEqual(layout.currentTab, "a")
    }

    /// 两份来回切
    func testSwitchBetweenTwo() {
        arrangeWriting()
        let a = store.saveCurrent(as: "A")!
        layout.leftShown = false
        layout.close("b")
        let b = store.saveCurrent(as: "B")!
        store.activate(a.id)
        XCTAssertEqual(layout.openTools, ["a", "b"])
        XCTAssertTrue(layout.leftShown)
        store.activate(b.id)
        XCTAssertEqual(layout.openTools, ["a"])
        XCTAssertFalse(layout.leftShown)
        XCTAssertEqual(store.activeId, b.id)
    }

    /// 切过去之后的改动不回写；重置 = 回到存的样子
    func testResetActiveRevertsEdits() {
        arrangeWriting()
        let w = store.saveCurrent(as: "A")!
        layout.leftWidth = 420
        XCTAssertEqual(store.active?.snapshot.leftWidth, 300, "改动不自动回写")
        store.resetActive()
        XCTAssertEqual(layout.leftWidth, 300)
        XCTAssertEqual(store.activeId, w.id)
    }

    /// 更新 = 用此刻覆盖
    func testUpdateOverwrites() {
        arrangeWriting()
        let w = store.saveCurrent(as: "A")!
        layout.leftWidth = 420
        store.update(w.id)
        layout.leftWidth = 260
        store.resetActive()
        XCTAssertEqual(layout.leftWidth, 420)
    }

    /// 同名 = 覆盖那一份，不新增
    func testSameNameOverwrites() {
        arrangeWriting()
        let first = store.saveCurrent(as: "A")!
        layout.leftWidth = 410
        let second = store.saveCurrent(as: "  A ")!
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].snapshot.leftWidth, 410)
    }

    func testEmptyNameRejected() {
        XCTAssertNil(store.saveCurrent(as: "   "))
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    func testLimit() {
        for i in 0..<PanelWorkspaceStore.limit { XCTAssertNotNil(store.saveCurrent(as: "w\(i)")) }
        XCTAssertNil(store.saveCurrent(as: "one more"))
        XCTAssertNotNil(store.saveCurrent(as: "w0"), "满了也能覆盖已有的")
        XCTAssertEqual(store.workspaces.count, PanelWorkspaceStore.limit)
    }

    /// 出厂：开着的工具不关，全部收回 tab 组；不再属于任何一份
    func testRestoreFactoryKeepsToolsAsTabs() {
        arrangeWriting()
        layout.detach("a", in: CGSize(width: 1600, height: 900))
        _ = store.saveCurrent(as: "A")
        layout.mode = .floating
        store.restoreFactory()
        XCTAssertNil(store.activeId)
        XCTAssertEqual(layout.mode, .docked)
        XCTAssertEqual(layout.openTools, ["a", "b"])
        XCTAssertEqual(layout.tabs, ["a", "b"])
        XCTAssertTrue(layout.detached.isEmpty)
        XCTAssertFalse(layout.leftShown)
        XCTAssertEqual(layout.toolWidth, 360)
    }

    /// 没有当前的时候「重置」= 出厂
    func testResetWithoutActiveIsFactory() {
        arrangeWriting()
        store.resetActive()
        XCTAssertFalse(layout.leftShown)
        XCTAssertEqual(layout.leftWidth, 320)
    }

    func testDeleteActiveClearsActive() {
        let w = store.saveCurrent(as: "A")!
        store.delete(w.id)
        XCTAssertNil(store.activeId)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    func testRenameRejectsDuplicate() {
        let a = store.saveCurrent(as: "A")!
        _ = store.saveCurrent(as: "B")
        store.rename(a.id, to: "B")
        XCTAssertEqual(store.workspaces.first { $0.id == a.id }?.name, "A")
        store.rename(a.id, to: "C")
        XCTAssertEqual(store.workspaces.first { $0.id == a.id }?.name, "C")
    }

    /// 重启读回：工作区表、当前、以及切过去后的布局存档
    func testPersistsAcrossInstances() {
        arrangeWriting()
        let w = store.saveCurrent(as: "A")!
        layout.leftShown = false
        store.activate(w.id)
        let layout2 = IPadPanelLayout(defaults: defaults)
        let store2 = PanelWorkspaceStore(layout: layout2, defaults: defaults)
        XCTAssertEqual(store2.workspaces.map(\.name), ["A"])
        XCTAssertEqual(store2.activeId, w.id)
        XCTAssertTrue(layout2.leftShown, "apply 之后布局存档也落了盘")
    }

    /// 坏档不崩
    func testCorruptArchive() {
        defaults.set(Data("nope".utf8), forKey: "panel.workspaces.v1")
        let s = PanelWorkspaceStore(layout: layout, defaults: defaults)
        XCTAssertTrue(s.workspaces.isEmpty)
        XCTAssertNil(s.activeId)
    }

    /// 读档不回写存档；apply 只写一次
    func testLoadDoesNotRewriteArchive() {
        arrangeWriting()
        let before = defaults.data(forKey: "ipad.panel.layout.v2")
        _ = IPadPanelLayout(defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: "ipad.panel.layout.v2"), before)
    }
}
