import SwiftData
import XCTest
@testable import 记忆花园

/// atrium P3⑤a：人页权限真表 / 「我」= 默认 / 删层 · 新建 · 备份补洞（plan-atrium-p3-permissions §3.10）
@MainActor
final class PermissionPersonTableTests: XCTestCase {
    private var sandbox: PermissionSandbox!
    private var root: URL!
    private var drawerSuite: String!
    private var drawer: ToolDrawerStore!
    private let a = "xctest-person-a"
    private let b = "xctest-person-b"

    override func setUpWithError() throws {
        sandbox = PermissionSandbox()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PermissionPersonTableTests-\(UUID().uuidString)", isDirectory: true)
        drawerSuite = "xctest-perm-drawer-\(UUID().uuidString)"
        drawer = ToolDrawerStore(defaults: try XCTUnwrap(UserDefaults(suiteName: drawerSuite)))
    }

    override func tearDownWithError() throws {
        sandbox.leave()
        UserDefaults(suiteName: drawerSuite)?.removePersistentDomain(forName: drawerSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func floor(_ id: String) -> Profile {
        Profile(id: id, name: "\(id) 名", emoji: "", description: "", userName: "你", assistantName: id)
    }

    /// 删层清权限：ProfileManager 的 defaults 和 PermissionCenter.defaults 指同一个 suite（⑤0 复盘 ⑤a 风险最后一条）
    private func makeManager(_ floors: [Profile]) throws -> ProfileManager {
        let schema = Schema([Conversation.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let m = ProfileManager(container: container, profiles: floors, currentProfile: floors[0], loadError: nil,
                               root: root, defaults: sandbox.defaults, sideEffectsEnabled: false,
                               themeManager: ThemeManager(defaults: sandbox.defaults), toolDrawer: drawer)
        try m.persistNew(floors)
        return m
    }

    // MARK: 档位控件选项（§3.1）

    func testOptionsForDefaultsAreTheLevels() {
        let opts = PermissionLevelPicker.options(domain: .webSearch, target: .defaults, defaultLevel: .bypass)
        XCTAssertEqual(opts.map(\.choice), PermissionLevel.allCases.map { .level($0) })
        let two = PermissionLevelPicker.options(domain: .voiceProactive, target: .defaults, defaultLevel: .bypass, twoLevelsOnly: true)
        XCTAssertEqual(two.map(\.choice), [.level(.bypass), .level(.notAllowed)])
    }

    func testFloorOptionsFollowRow() {
        let opts = PermissionLevelPicker.options(domain: .webSearch, target: .floor(a), defaultLevel: .bypass)
        XCTAssertEqual(opts.map(\.choice), [.follow, .level(.bypass), .level(.askOnce), .level(.notAllowed)], "自由域可宽可严")
        XCTAssertEqual(opts.first?.title, "跟随默认 · 自动允许", "「跟随默认」带上现在的默认名")
        XCTAssertEqual(PermissionLevelPicker.options(domain: .images, target: .floor(a), defaultLevel: .notAllowed).first?.title,
                       "跟随默认 · 不允许")
    }

    func testStricterOnlyNeverOffersLooserLevels() {
        // shell 默认 askOnce：层上只能选不允许
        XCTAssertEqual(PermissionLevelPicker.options(domain: .shell, target: .floor(a), defaultLevel: .askOnce).map(\.choice),
                       [.follow, .level(.notAllowed)])
        // 默认已经最严：只剩「跟随」
        XCTAssertEqual(PermissionLevelPicker.options(domain: .shell, target: .floor(a), defaultLevel: .notAllowed).map(\.choice),
                       [.follow])
        XCTAssertEqual(PermissionLevelPicker.options(domain: .shell, target: .floor(a), defaultLevel: .bypass).map(\.choice),
                       [.follow, .level(.askOnce), .level(.notAllowed)])
    }

    func testGlobalOnlyHasNoFloorOptions() {
        for d in [PermissionDomain.toolsMaster, .pocket, .memory] {
            XCTAssertTrue(PermissionLevelPicker.options(domain: d, target: .floor(a), defaultLevel: .bypass).isEmpty, d.rawValue)
            XCTAssertFalse(PermissionLevelPicker.options(domain: d, target: .defaults, defaultLevel: .bypass).isEmpty, d.rawValue)
        }
    }

    func testCurrentChoice() {
        XCTAssertEqual(PermissionLevelPicker.currentChoice(domain: .webSearch, target: .floor(a), defaultLevel: .bypass), .follow)
        PermissionCenter.setFloorLevel(.notAllowed, for: .webSearch, profileId: a)
        XCTAssertEqual(PermissionLevelPicker.currentChoice(domain: .webSearch, target: .floor(a), defaultLevel: .bypass), .level(.notAllowed))
        XCTAssertEqual(PermissionLevelPicker.currentChoice(domain: .webSearch, target: .floor(b), defaultLevel: .bypass), .follow)
        XCTAssertEqual(PermissionLevelPicker.currentChoice(domain: .webSearch, target: .defaults, defaultLevel: .askOnce), .level(.askOnce))
        // 只能更严：默认追上来后生效的是默认，显示「跟随」，层值留着（plan §6-7）
        PermissionCenter.setFloorLevel(.notAllowed, for: .shell, profileId: a)
        PermissionCenter.setDefaultLevel(.notAllowed, for: .shell)
        XCTAssertEqual(PermissionLevelPicker.currentChoice(domain: .shell, target: .floor(a), defaultLevel: .notAllowed), .follow)
        XCTAssertEqual(PermissionCenter.floors().stored(.shell, profileId: a), .notAllowed)
    }

    // MARK: 「N 个人单独设了」（§3.3）

    func testOverridesCountOnlyExistingFloors() {
        PermissionCenter.setFloorLevel(.notAllowed, for: .images, profileId: a)
        PermissionCenter.setFloorLevel(.askOnce, for: .images, profileId: "xctest-gone-floor")
        PermissionCenter.setFloorLevel(.bypass, for: .webSearch, profileId: b)
        let rows = PermissionOverridesPage.entries(.images, profiles: [floor(a), floor(b)])
        XCTAssertEqual(rows.map(\.profile.id), [a], "已删层残留的不算，别的域的不算")
        XCTAssertEqual(rows.first?.level, .notAllowed)
        XCTAssertEqual(PermissionCenter.overrides(.images).count, 2, "底层照存，筛在调用方")
    }

    func testReadoutText() {
        XCTAssertEqual(PermissionLevelReadout.text(name: "云桥", level: .askOnce), "云桥：每次询问")
    }

    // MARK: 删层 / 新建复制（§3.6）

    func testDeleteProfileClearsPermissionFloorAndDrawer() throws {
        let m = try makeManager([floor(a), floor(b)])
        PermissionCenter.setFloorLevel(.notAllowed, for: .webSearch, profileId: b)
        PermissionCenter.setFloorLevel(.bypass, for: .images, profileId: a)
        drawer.update {
            $0.set(.off, for: "fs_read", profileId: b)
            $0.set(.tucked, for: "fs_read", profileId: a)
        }

        m.deleteProfile(floor(b), deleteData: false)

        XCTAssertNil(PermissionCenter.floors().floors[b], "删掉的人单独设的权限清掉")
        XCTAssertEqual(PermissionCenter.floors().stored(.images, profileId: a), .bypass, "别人的不动")
        XCTAssertNil(drawer.state.floors[b], "抽屉一起清")
        XCTAssertEqual(drawer.state.floorOverride("fs_read", profileId: a), .tucked)
        let saved = ToolDrawerState.decoded(UserDefaults(suiteName: drawerSuite)?.data(forKey: ToolDrawerStore.defaultsKey))
        XCTAssertNil(saved.floors[b], "落盘的抽屉也清了")
        XCTAssertEqual(saved.floorOverride("fs_read", profileId: a), .tucked)
    }

    func testRemoveLegacyXiaoyaFloorClearsItsDeviceSettings() throws {
        let m = try makeManager([floor(a), floor(Profile.xiaoyaId)])
        PermissionCenter.setFloorLevel(.notAllowed, for: .twitter, profileId: Profile.xiaoyaId)
        drawer.update { $0.set(.off, for: "fs_read", profileId: Profile.xiaoyaId) }

        XCTAssertTrue(m.removeLegacyXiaoyaFloor())

        XCTAssertNil(PermissionCenter.floors().floors[Profile.xiaoyaId])
        XCTAssertNil(drawer.state.floors[Profile.xiaoyaId])
        XCTAssertNil(sandbox.defaults.data(forKey: PermissionCenter.floorsKey), "层全空了键也删了")
    }

    func testDeleteWithoutFloorSettingsWritesNothing() throws {
        let m = try makeManager([floor(a), floor(b)])
        m.deleteProfile(floor(b), deleteData: false)
        XCTAssertNil(sandbox.defaults.object(forKey: PermissionCenter.floorsKey))
        XCTAssertNil(UserDefaults(suiteName: drawerSuite)?.object(forKey: ToolDrawerStore.defaultsKey))
    }

    func testCopyDeviceFloorSettingsCopiesOnlyOverrides() throws {
        let m = try makeManager([floor(a), floor(b)])
        PermissionCenter.setFloorLevel(.notAllowed, for: .webSearch, profileId: a)
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: a)
        drawer.update { $0.set(.tucked, for: "fs_read", profileId: a) }
        let fresh = "xctest-person-new"

        m.copyDeviceFloorSettings(from: a, to: fresh)

        XCTAssertEqual(PermissionCenter.floors().floors[fresh], PermissionCenter.floors().floors[a])
        XCTAssertEqual(PermissionCenter.level(.webSearch, profileId: fresh), .notAllowed)
        XCTAssertEqual(drawer.state.floorOverride("fs_read", profileId: fresh), .tucked)
        // 来源跟默认 → 新层也空
        let fresh2 = "xctest-person-new2"
        m.copyDeviceFloorSettings(from: b, to: fresh2)
        XCTAssertNil(PermissionCenter.floors().floors[fresh2])
        XCTAssertNil(drawer.state.floors[fresh2])
    }

    func testAddProfileDoesNotCopy() throws {
        let m = try makeManager([floor(a)])
        PermissionCenter.setFloorLevel(.notAllowed, for: .webSearch, profileId: a)
        drawer.update { $0.set(.off, for: "fs_read", profileId: a) }
        let card = floor("xctest-person-card")
        m.addProfile(card)   // 卡建 / 酒馆 / 领养走的入口，不复制
        XCTAssertNil(PermissionCenter.floors().floors[card.id])
        XCTAssertNil(drawer.state.floors[card.id])
        XCTAssertEqual(PermissionCenter.level(.webSearch, profileId: card.id), PermissionCenter.defaultLevel(.webSearch))
    }

    // MARK: 备份往返（§3.6）

    func testBackupRoundTripKeepsFloorSettings() throws {
        let src = sandbox.defaults
        PermissionCenter.setFloorLevel(.notAllowed, for: .webSearch, profileId: a)
        PermissionCenter.setFloorLevel(.askOnce, for: .images, profileId: b)
        let drawerData = ToolDrawerState(global: ["fs_read": .tucked], floors: [a: ["fs_write": .off]]).encoded()
        src.set(drawerData, forKey: ToolDrawerStore.defaultsKey)
        let permData = try XCTUnwrap(src.data(forKey: PermissionCenter.floorsKey))

        let dir = root.appendingPathComponent("userdefaults", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GlobalExporter.exportDeviceFloorFiles(to: dir, from: src)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("permission_floors.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tool_drawer.json").path))

        let dstName = "xctest-perm-restore-\(UUID().uuidString)"
        let dst = try XCTUnwrap(UserDefaults(suiteName: dstName))
        defer { dst.removePersistentDomain(forName: dstName) }
        try PendingImportApplier.restoreDeviceFloorFiles(from: dir, into: dst)

        XCTAssertEqual(dst.data(forKey: PermissionCenter.floorsKey), permData, "权限层字节相同")
        XCTAssertEqual(dst.data(forKey: ToolDrawerStore.defaultsKey), drawerData, "抽屉字节相同")
        XCTAssertEqual(PermissionFloors.decoded(dst.data(forKey: PermissionCenter.floorsKey)), PermissionCenter.floors())
    }

    func testOldBackupWithoutFilesLeavesLocalValues() throws {
        let dir = root.appendingPathComponent("userdefaults-old", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dstName = "xctest-perm-restore-\(UUID().uuidString)"
        let dst = try XCTUnwrap(UserDefaults(suiteName: dstName))
        defer { dst.removePersistentDomain(forName: dstName) }
        let local = PermissionFloors(floors: [a: ["webSearch": 2]]).encoded()
        dst.set(local, forKey: PermissionCenter.floorsKey)
        dst.set(Data("{\"floors\":{},\"global\":{\"fs_read\":\"off\"}}".utf8), forKey: ToolDrawerStore.defaultsKey)

        try PendingImportApplier.restoreDeviceFloorFiles(from: dir, into: dst)

        XCTAssertEqual(dst.data(forKey: PermissionCenter.floorsKey), local)
        XCTAssertEqual(dst.data(forKey: ToolDrawerStore.defaultsKey), Data("{\"floors\":{},\"global\":{\"fs_read\":\"off\"}}".utf8))
    }

    func testEmptyDeviceExportsNoFiles() throws {
        let dir = root.appendingPathComponent("userdefaults-empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try GlobalExporter.exportDeviceFloorFiles(to: dir, from: sandbox.defaults)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        XCTAssertEqual(GlobalExporter.deviceFloorFiles.map(\.udKey), [PermissionCenter.floorsKey, ToolDrawerStore.defaultsKey, Page2Apps.floorsKey])
    }

    // MARK: 拒绝文案（§3.8）/ 设置搜索（§3.9）

    func testAdjustHintIsPerPlatform() {
        #if os(macOS)
        XCTAssertEqual(PermissionCenter.adjustHint, "可以请用户到 设置 → 权限 → 这一层 调整。")
        #else
        XCTAssertEqual(PermissionCenter.adjustHint, "可以请用户到你的人页 › 权限 调整。")
        #endif
        let denied = PermissionGate.outcome(.denied, domain: .webSearch, originalArgs: "{}").gate
        XCTAssertEqual(denied, .deny("permission_denied：用户本次未允许「联网搜索」。\(PermissionCenter.adjustHint)"))
    }

    func testSearchLeavesSayDefaults() throws {
        let leaf = try XCTUnwrap(SettingsSearchEntry.leafEntries.first { $0.id == "leaf-perm-webSearch" })
        XCTAssertEqual(leaf.subtitle, "权限（默认）› AI 能做什么")
        XCTAssertTrue(leaf.keywords.contains("按人"))
        let page = try XCTUnwrap(SettingsSearchEntry.pageEntries.first { $0.id == "page-permissions" })
        XCTAssertTrue(page.keywords.contains("默认"))
    }
}
