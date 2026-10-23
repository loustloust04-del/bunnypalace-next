import XCTest
@testable import 记忆花园

/// 终端工具条键模型（plan §C1）：持久化 roundtrip / 主行容量溢出 / 老键迁移。
final class TerminalToolbarModelTests: XCTestCase {

    // MARK: - Roundtrip

    func testDefaultLayoutRoundtrip() throws {
        let layout = TerminalToolbarLayout.default
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(TerminalToolbarLayout.self, from: data)
        XCTAssertEqual(back, layout)
        XCTAssertEqual(back.mainRow.count, 10, "主行默认 10 键（物料表 §1.2）")
        XCTAssertEqual(back.drawerRows.count, 1)
    }

    func testDefaultDrawerHasAll28Symbols() {
        let ids = TerminalToolbarLayout.defaultDrawerRow
        let symbols = ids.filter { $0.kind == .symbol }
        XCTAssertEqual(symbols.count, 28, "符号 28 键全抄（粟粟批注 §五-8）")
        // 每个符号键都能给出字符和字节
        for id in symbols {
            XCTAssertNotNil(id.symbolCharacter, "\(id.rawValue) 没有显示字符")
            XCTAssertEqual(id.rawBytes?.count, 1, "\(id.rawValue) 应该是单字节")
        }
        XCTAssertTrue(ids.contains(.alt), "Alt 保留")
        XCTAssertTrue(ids.contains(.paste), "Paste 保留")
        XCTAssertTrue(ids.contains(.arrowUp), "四方向键默认在抽屉（任务书 C5）")
    }

    func testCmdAndRootshellOnlyActionsAreGone() {
        // 粟粟批注 §五-8：Cmd 和 rootshell 专属 8 个 action 剔除
        let raws = Set(TerminalKeyID.allCases.map(\.rawValue))
        for gone in ["cmd", "voiceAgent", "aiAgent", "brightnessBoost", "clipboardManager",
                     "toggleFullScreen", "toggleTabBar", "newConnection", "toggleMouseCapture"] {
            XCTAssertFalse(raws.contains(gone), "\(gone) 应该已剔除")
        }
    }

    func testCustomKeyRoundtripAllStepTypes() throws {
        let key = TerminalCustomKey(
            label: "部署",
            iconName: "shippingbox",
            sequence: [
                .text("git push"),
                .keyCombo(TerminalKeyCombo(modifiers: [.control], key: .letter("c"))),
                .keyCombo(TerminalKeyCombo(modifiers: [.alt, .shift], key: .special(.ret))),
                .keyCombo(TerminalKeyCombo(modifiers: [], key: .digit("7"))),
                .keyCombo(TerminalKeyCombo(modifiers: [], key: .symbol("$"))),
            ]
        )
        let data = try JSONEncoder().encode([key])
        let back = try JSONDecoder().decode([TerminalCustomKey].self, from: data)
        XCTAssertEqual(back, [key])
    }

    func testLayoutWithCustomSlotsAndHiddenKeysRoundtrip() throws {
        let uuid = UUID()
        let layout = TerminalToolbarLayout(
            mainRow: [.builtIn(.dismiss), .custom(uuid), .builtIn(.drawerToggle)],
            drawerRows: [[.builtIn(.slash)], [.custom(uuid)]],
            hiddenKeys: [.compose, .paste]
        )
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(TerminalToolbarLayout.self, from: data)
        XCTAssertEqual(back, layout)
        XCTAssertEqual(back.placedCustomIDs, [uuid])
        XCTAssertTrue(back.placedBuiltInIDs.contains(.slash))
    }

    func testDrawerRowsNeverEmpty() {
        let layout = TerminalToolbarLayout(mainRow: [], drawerRows: [])
        XCTAssertEqual(layout.drawerRows.count, 1, "至少保证一行抽屉")
    }

    // MARK: - 容量 / 溢出

    func testCapacityIsFloorOfWidthOverNormalWidth() {
        // 物料表 §9.3：Int(availableWidth / normalWidth)，不算 spacing、不看宽键
        XCTAssertEqual(TerminalToolbarCapacity.capacity(availableWidth: 393, normalWidth: 33), 11)
        XCTAssertEqual(TerminalToolbarCapacity.capacity(availableWidth: 330, normalWidth: 33), 10)
        XCTAssertEqual(TerminalToolbarCapacity.capacity(availableWidth: 200, normalWidth: 33), 6)
        XCTAssertEqual(TerminalToolbarCapacity.capacity(availableWidth: 0, normalWidth: 33), 1)
    }

    func testOverflowGoesToDrawerZeroHead() {
        let layout = TerminalToolbarLayout(
            mainRow: [.builtIn(.dismiss), .builtIn(.esc), .builtIn(.ctrl),
                      .builtIn(.drawerToggle), .builtIn(.shift), .builtIn(.tab)],
            drawerRows: [[.builtIn(.slash)]]
        )
        // capacity 4 → 主行留前 4（含 drawerToggle），shift/tab 溢出进 Drawer 0 头部
        let r = TerminalToolbarCapacity.resolve(layout: layout, availableWidth: 132, normalWidth: 33)
        XCTAssertEqual(r.capacity, 4)
        XCTAssertEqual(r.mainRow, [.builtIn(.dismiss), .builtIn(.esc),
                                   .builtIn(.ctrl), .builtIn(.drawerToggle)])
        XCTAssertEqual(r.drawerRows[0],
                       [.builtIn(.shift), .builtIn(.tab), .builtIn(.slash)],
                       "溢出插在 Drawer 0 最前面，原有内容顺延")
    }

    func testDrawerToggleForcedBackIntoMainRowDisplacingLastKey() {
        // drawerToggle 排在主行第 5 位，capacity 只有 4 → 它会被挤出去；
        // 但有抽屉内容 → 必须捞回来，顶掉主行最后一键（物料表 §1.4）
        let layout = TerminalToolbarLayout(
            mainRow: [.builtIn(.dismiss), .builtIn(.esc), .builtIn(.ctrl),
                      .builtIn(.shift), .builtIn(.drawerToggle)],
            drawerRows: [[.builtIn(.slash)]]
        )
        let r = TerminalToolbarCapacity.resolve(layout: layout, availableWidth: 132, normalWidth: 33)
        XCTAssertEqual(r.mainRow.last, .builtIn(.drawerToggle))
        XCTAssertEqual(r.mainRow.count, 4)
        XCTAssertEqual(r.drawerRows[0].first, .builtIn(.shift), "被顶掉的键进 Drawer 0 头部")
        XCTAssertFalse(r.drawerRows[0].contains(.builtIn(.drawerToggle)),
                       "toggle 不该同时留在抽屉里")
    }

    func testDrawerToggleNotForcedWhenHidden() {
        let layout = TerminalToolbarLayout(
            mainRow: [.builtIn(.dismiss), .builtIn(.esc)],
            drawerRows: [[.builtIn(.slash)]],
            hiddenKeys: [.drawerToggle]
        )
        let r = TerminalToolbarCapacity.resolve(layout: layout, availableWidth: 330, normalWidth: 33)
        XCTAssertFalse(r.mainRow.contains(.builtIn(.drawerToggle)),
                       "用户显式隐藏了就别强插")
    }

    func testDrawerToggleNotForcedWhenNoDrawerContent() {
        let layout = TerminalToolbarLayout(
            mainRow: [.builtIn(.dismiss), .builtIn(.esc)],
            drawerRows: [[]]
        )
        let r = TerminalToolbarCapacity.resolve(layout: layout, availableWidth: 330, normalWidth: 33)
        XCTAssertFalse(r.mainRow.contains(.builtIn(.drawerToggle)))
    }

    func testDefaultLayoutFitsIPhonePortrait() {
        // iPhone 竖屏 393pt 宽、normalWidth 33 → capacity 11 ≥ 主行 10，不该溢出
        let r = TerminalToolbarCapacity.resolve(layout: .default,
                                                availableWidth: 393, normalWidth: 33)
        XCTAssertEqual(r.mainRow.count, 10)
        XCTAssertEqual(r.drawerRows[0].count, TerminalToolbarLayout.defaultDrawerRow.count)
    }

    func testDrawerRenderableSkipsTogglesAndJoystick() {
        let row: [TerminalKeySlot] = [.builtIn(.slash), .builtIn(.drawerToggle),
                                      .builtIn(.arrowJoystick), .builtIn(.dash)]
        XCTAssertEqual(TerminalToolbarCapacity.drawerRenderable(row),
                       [.builtIn(.slash), .builtIn(.dash)])
    }

    // MARK: - 摇杆判向（物料表 §3.2）

    func testJoystickDeadZoneIs18pt() {
        XCTAssertNil(TerminalJoystickGeometry.direction(dx: 17, dy: 0), "死区内没有方向")
        XCTAssertNil(TerminalJoystickGeometry.direction(dx: 0, dy: 0))
        XCTAssertEqual(TerminalJoystickGeometry.direction(dx: 18, dy: 0), .right, "正好 18pt 出死区")
    }

    func testJoystickAxisSelection() {
        XCTAssertEqual(TerminalJoystickGeometry.direction(dx: 40, dy: 10), .right)
        XCTAssertEqual(TerminalJoystickGeometry.direction(dx: -40, dy: 10), .left)
        XCTAssertEqual(TerminalJoystickGeometry.direction(dx: 10, dy: 40), .down, "iOS 的 y 往下增")
        XCTAssertEqual(TerminalJoystickGeometry.direction(dx: 10, dy: -40), .up)
    }

    func testJoystickExactly45DegreesGoesVertical() {
        // rootshell 判的是 abs(dx) > abs(dy)（`>` 不是 `>=`），所以 45° 归垂直
        XCTAssertEqual(TerminalJoystickGeometry.direction(dx: 30, dy: 30), .down)
        XCTAssertEqual(TerminalJoystickGeometry.direction(dx: -30, dy: -30), .up)
    }

    // MARK: - 老键迁移

    private func makeDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func writeLegacy(_ keys: [(String, [UInt8])], to d: UserDefaults) throws {
        let legacy = keys.map { TerminalToolbarStore.LegacyTerminalKey(id: UUID(), label: $0.0, bytes: $0.1) }
        d.set(try JSONEncoder().encode(legacy), forKey: TerminalToolbarStore.Keys.legacyKeys)
    }

    func testMigrationSkipsKeysCoveredByBuiltIns() throws {
        let name = "tb-migrate-defaults"
        let d = makeDefaults(name)
        defer { d.removePersistentDomain(forName: name) }
        // 老默认 8 键原样没动过
        try writeLegacy([
            ("Esc", [0x1b]), ("⌃C", [0x03]), ("Tab", [0x09]), ("⇧Tab", [0x1b, 0x5b, 0x5a]),
            ("↑", [0x1b, 0x5b, 0x41]), ("↓", [0x1b, 0x5b, 0x42]),
            ("←", [0x1b, 0x5b, 0x44]), ("→", [0x1b, 0x5b, 0x43]),
        ], to: d)

        let migrated = TerminalToolbarStore.migrateLegacyKeys(from: d)
        XCTAssertEqual(migrated.map(\.label), ["⌃C"],
                       "Esc/Tab/⇧Tab/四方向新布局里都有内建键，只有 ⌃C 需要迁")
        XCTAssertEqual(migrated.first?.sequence, [.text("\u{03}")])
    }

    func testMigrationKeepsCustomKeysAndBytes() throws {
        let name = "tb-migrate-custom"
        let d = makeDefaults(name)
        defer { d.removePersistentDomain(forName: name) }
        try writeLegacy([
            ("Esc", [0x1b]),                      // 跳过
            ("⌃D", [0x04]),                       // 迁
            ("Home", [0x1b, 0x5b, 0x48]),         // 迁（新内建里没有 Home）
            ("清屏", [0x63, 0x6c, 0x65, 0x61, 0x72, 0x0d]),  // "clear\r"
        ], to: d)

        let migrated = TerminalToolbarStore.migrateLegacyKeys(from: d)
        XCTAssertEqual(migrated.map(\.label), ["⌃D", "Home", "清屏"])

        // 字节必须原样往返（< 0x80 的标量 UTF-8 编码就是它自己）
        func bytes(_ key: TerminalCustomKey) -> [UInt8] {
            guard case .text(let t) = key.sequence[0] else { return [] }
            return Array(t.utf8)
        }
        XCTAssertEqual(bytes(migrated[0]), [0x04])
        XCTAssertEqual(bytes(migrated[1]), [0x1b, 0x5b, 0x48])
        XCTAssertEqual(bytes(migrated[2]), [0x63, 0x6c, 0x65, 0x61, 0x72, 0x0d])
    }

    func testStoreMigratesIntoDrawerZeroTailOnFirstLaunch() throws {
        let name = "tb-migrate-store"
        let d = makeDefaults(name)
        defer { d.removePersistentDomain(forName: name) }
        try writeLegacy([("⌃C", [0x03]), ("⌃D", [0x04])], to: d)

        let store = TerminalToolbarStore(defaults: d)
        XCTAssertEqual(store.customKeys.map(\.label), ["⌃C", "⌃D"])
        let tail = store.layout.drawerRows[0].suffix(2)
        XCTAssertEqual(Array(tail), store.customKeys.map { TerminalKeySlot.custom($0.id) },
                       "迁移来的键排在 Drawer 0 末尾")

        // 第二次起动读的是已落盘的新布局，不该再迁一遍
        let again = TerminalToolbarStore(defaults: d)
        XCTAssertEqual(again.customKeys.count, 2)
        XCTAssertEqual(again.layout, store.layout)
    }

    func testStoreWithoutLegacyKeysGetsPlainDefault() {
        let name = "tb-migrate-none"
        let d = makeDefaults(name)
        defer { d.removePersistentDomain(forName: name) }
        let store = TerminalToolbarStore(defaults: d)
        XCTAssertEqual(store.layout, .default)
        XCTAssertTrue(store.customKeys.isEmpty)
        XCTAssertFalse(store.isCustomized)
    }

    // MARK: - 抽屉状态机（物料表 §6.1/§6.2）

    func testStackModeAddsOneRowPerTapThenCloses() {
        var s = TerminalDrawerState.closed
        s = s.advanced(mode: .stack, rowCount: 3)
        XCTAssertEqual(s, .stacked(count: 1))
        s = s.advanced(mode: .stack, rowCount: 3)
        XCTAssertEqual(s, .stacked(count: 2))
        s = s.advanced(mode: .stack, rowCount: 3)
        XCTAssertEqual(s, .stacked(count: 3))
        s = s.advanced(mode: .stack, rowCount: 3)
        XCTAssertEqual(s, .closed, "全部行显示完再按一次回 closed")
    }

    func testCycleModeShowsOneRowAtATime() {
        var s = TerminalDrawerState.closed
        s = s.advanced(mode: .cycle, rowCount: 3)
        XCTAssertEqual(s, .cycling(index: 0))
        s = s.advanced(mode: .cycle, rowCount: 3)
        XCTAssertEqual(s, .cycling(index: 1))
        s = s.advanced(mode: .cycle, rowCount: 3)
        XCTAssertEqual(s, .cycling(index: 2))
        s = s.advanced(mode: .cycle, rowCount: 3)
        XCTAssertEqual(s, .closed)
    }

    func testSwitchingModeWhileOpenClosesOnNextTap() {
        // 物料表 §6.2 末条：开着时改了模式，下一次按直接回 closed，不原地转模式
        XCTAssertEqual(TerminalDrawerState.stacked(count: 2).advanced(mode: .cycle, rowCount: 3), .closed)
        XCTAssertEqual(TerminalDrawerState.cycling(index: 1).advanced(mode: .stack, rowCount: 3), .closed)
    }

    func testStackedRowsRenderNewestOnTopWithRowZeroNextToMainRow() {
        // 从上到下的排列：index 2、1、0 —— Drawer 1（index 0）贴着主行
        XCTAssertEqual(TerminalDrawerState.stacked(count: 3).visibleRowIndices(rowCount: 3), [2, 1, 0])
        XCTAssertEqual(TerminalDrawerState.stacked(count: 1).visibleRowIndices(rowCount: 3), [0])
        XCTAssertEqual(TerminalDrawerState.closed.visibleRowIndices(rowCount: 3), [])
        XCTAssertEqual(TerminalDrawerState.cycling(index: 2).visibleRowIndices(rowCount: 3), [2])
    }

    func testDrawerStateClampsWhenRowCountShrinks() {
        XCTAssertEqual(TerminalDrawerState.stacked(count: 5).clamped(rowCount: 2), .stacked(count: 2))
        XCTAssertEqual(TerminalDrawerState.cycling(index: 4).clamped(rowCount: 2), .cycling(index: 1))
        XCTAssertEqual(TerminalDrawerState.closed.clamped(rowCount: 2), .closed)
    }

    func testDrawerRowCountMergesDroppedRowsIntoLastKeptRow() {
        let name = "tb-rows"
        let d = makeDefaults(name)
        defer { d.removePersistentDomain(forName: name) }
        let store = TerminalToolbarStore(defaults: d)
        store.setLayout(TerminalToolbarLayout(
            mainRow: [],
            drawerRows: [[.builtIn(.slash)], [.builtIn(.dash)], [.builtIn(.equals)]]
        ))
        store.setDrawerRowCount(2)
        XCTAssertEqual(store.layout.drawerRows.count, 2)
        XCTAssertEqual(store.layout.drawerRows[1], [.builtIn(.dash), .builtIn(.equals)],
                       "被删行的键并进最后一个保留行，不丢键（物料表 §6.1）")

        store.setDrawerRowCount(4)
        XCTAssertEqual(store.layout.drawerRows.count, 4)
        XCTAssertTrue(store.layout.drawerRows[2].isEmpty, "加行是追加空行")

        store.setDrawerRowCount(99)
        XCTAssertEqual(store.layout.drawerRows.count, 5, "上限 5 行")
        store.setDrawerRowCount(0)
        XCTAssertEqual(store.layout.drawerRows.count, 1, "下限 1 行")
    }

    func testDrawerToggleModeDefaultsToStackAndPersists() {
        let name = "tb-mode"
        let d = makeDefaults(name)
        defer { d.removePersistentDomain(forName: name) }
        let store = TerminalToolbarStore(defaults: d)
        XCTAssertEqual(store.drawerToggleMode, .stack, "缺省 stack（物料表 §6.2）")
        store.drawerToggleMode = .cycle
        XCTAssertEqual(TerminalToolbarStore(defaults: d).drawerToggleMode, .cycle)
    }

    func testResetKeepsCustomKeyDefinitions() throws {
        let name = "tb-reset"
        let d = makeDefaults(name)
        defer { d.removePersistentDomain(forName: name) }
        try writeLegacy([("⌃C", [0x03])], to: d)
        let store = TerminalToolbarStore(defaults: d)
        XCTAssertEqual(store.customKeys.count, 1)

        store.resetToDefaults()
        XCTAssertEqual(store.layout, .default, "布局回默认")
        XCTAssertEqual(store.customKeys.count, 1,
                       "自定义键定义保留 —— rootshell 的全删是 bug（物料表 §7.3），不抄")
    }
}
