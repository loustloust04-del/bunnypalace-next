import SwiftData
import XCTest
@testable import 记忆花园

/// 把 `Page2Apps.defaults` 换到一次性 suite（真 prefs 不碰）；`RightPanelToolManager(defaults:)` 传同一个
final class Page2AppsSandbox {
    let defaults: UserDefaults
    private let name = "xctest-page2apps-\(UUID().uuidString)"
    private let previous: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        previous = Page2Apps.defaults
        Page2Apps.defaults = defaults
    }

    func leave() {
        Page2Apps.defaults = previous
        defaults.removePersistentDomain(forName: name)
    }

    /// 写一份默认存档：内置表，`changes` 里的 id 改开关
    func storeDefaults(_ changes: [String: Bool]) {
        let tools = RightPanelToolManager.builtInTools.map { t -> RightPanelTool in
            var t = t
            if let on = changes[t.id] { t.isEnabled = on; t.isPinned = on }
            return t
        }
        defaults.set(try! JSONEncoder().encode(tools), forKey: RightPanelToolManager.storageKey)
    }
}

/// atrium P3⑥0：App 装卸按层的解析 / 存取 / 写入口 / 读缓存 + manager 默认与生效分开（plan-atrium-p3-page2 §2.5）
@MainActor
final class Page2AppFloorsTests: XCTestCase {

    private var sandbox: Page2AppsSandbox!
    private let a = "xctest-app-floor-a"
    private let b = "xctest-app-floor-b"

    override func setUp() {
        super.setUp()
        sandbox = Page2AppsSandbox()
    }

    override func tearDown() {
        sandbox.leave()
        super.tearDown()
    }

    // MARK: 解析

    func testEmptyFloorsFollowDefault() {
        XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey))
        XCTAssertTrue(Page2Apps.isInstalled("fileLibrary", profileId: a), "没存过 = 内置表：文件库开")
        XCTAssertFalse(Page2Apps.isInstalled("prompt", profileId: a), "内置表默认关的照旧关")
        sandbox.storeDefaults(["fileLibrary": false])
        XCTAssertFalse(Page2Apps.isInstalled("fileLibrary", profileId: a), "层空 = 跟默认存档")
        XCTAssertFalse(Page2Apps.isInstalled("no-such-app", profileId: a), "认不出的 id = 没装")
    }

    func testFloorOverridesBothWays() {
        sandbox.storeDefaults(["prompt": false])
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        Page2Apps.setFloor(true, for: "prompt", profileId: a)
        XCTAssertFalse(Page2Apps.isInstalled("fileLibrary", profileId: a), "层卸")
        XCTAssertTrue(Page2Apps.isInstalled("prompt", profileId: a), "层装")
        XCTAssertTrue(Page2Apps.isInstalled("fileLibrary", profileId: b), "别的层不串")
        XCTAssertFalse(Page2Apps.isInstalled("prompt", profileId: b))
    }

    func testNilOrUnknownProfileFollowsDefault() {
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        XCTAssertTrue(Page2Apps.isInstalled("fileLibrary", profileId: nil))
        XCTAssertTrue(Page2Apps.isInstalled("fileLibrary", profileId: "xctest-gone-floor"))
    }

    func testUnknownToolIdKeptThroughRoundTrip() {
        let floors = Page2AppFloors(floors: [a: ["topicBox": false, "fileLibrary": true]])
        sandbox.defaults.set(floors.encoded(), forKey: Page2Apps.floorsKey)
        Page2Apps.setFloor(false, for: "twitter", profileId: a)
        let saved = Page2AppFloors.decoded(sandbox.defaults.data(forKey: Page2Apps.floorsKey))
        XCTAssertEqual(saved?.stored("topicBox", profileId: a), false, "这个包认不认识话题盒都原样留着")
        XCTAssertEqual(saved?.stored("twitter", profileId: a), false)
    }

    func testCorruptJSONReadsEmptyAndRefusesWrites() {
        let junk = Data("{not json".utf8)
        sandbox.storeDefaults(["fileLibrary": false])
        sandbox.defaults.set(junk, forKey: Page2Apps.floorsKey)
        XCTAssertEqual(Page2Apps.floors(), Page2AppFloors(), "读当空")
        XCTAssertFalse(Page2Apps.isInstalled("fileLibrary", profileId: a), "空 = 跟默认")
        Page2Apps.setFloor(true, for: "fileLibrary", profileId: a)
        Page2Apps.clearAll(profileId: a)
        Page2Apps.copyFloor(from: a, to: b)
        XCTAssertEqual(sandbox.defaults.data(forKey: Page2Apps.floorsKey), junk, "三个写入口都不覆盖")
    }

    // MARK: 写入口

    func testSetFloorEqualToDefaultStoresNil() {
        Page2Apps.setFloor(true, for: "fileLibrary", profileId: a)
        XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey), "和默认一样 = 不存，键也不建")
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        XCTAssertEqual(Page2Apps.floors().stored("fileLibrary", profileId: a), false)
        Page2Apps.setFloor(nil, for: "fileLibrary", profileId: a)
        XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey), "层空了删整层，全空删键")
    }

    func testClearCopyOverrides() {
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        Page2Apps.setFloor(false, for: "twitter", profileId: a)
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: b)
        XCTAssertEqual(Page2Apps.overrides("fileLibrary"), [a: false, b: false])
        XCTAssertEqual(Page2Apps.overrides("twitter"), [a: false])

        Page2Apps.copyFloor(from: a, to: "xctest-app-floor-new")
        XCTAssertEqual(Page2Apps.floors().floors["xctest-app-floor-new"], Page2Apps.floors().floors[a])
        Page2Apps.copyFloor(from: "xctest-app-floor-plain", to: "xctest-app-floor-new2")
        XCTAssertNil(Page2Apps.floors().floors["xctest-app-floor-new2"], "来源跟默认 → 新层也空")

        Page2Apps.clearAll(profileId: a)
        XCTAssertNil(Page2Apps.floors().floors[a])
        XCTAssertEqual(Page2Apps.overrides("fileLibrary"), [b: false, "xctest-app-floor-new": false])

        var v = Page2Apps.floors()
        v.clear(toolId: "fileLibrary")
        XCTAssertEqual(v.floors, ["xctest-app-floor-new": ["twitter": false]], "按 App 清，层空了删层")
    }

    func testCacheFollowsDefaultsChanges() {
        XCTAssertTrue(Page2Apps.isInstalled("twitter", profileId: a))
        sandbox.defaults.set(Page2AppFloors(floors: [a: ["twitter": false]]).encoded(), forKey: Page2Apps.floorsKey)
        XCTAssertFalse(Page2Apps.isInstalled("twitter", profileId: a), "外部直接改层键，下一次读就是新值")
        sandbox.storeDefaults(["twitter": false])
        XCTAssertFalse(Page2Apps.isInstalled("twitter", profileId: b), "默认存档改了也一样")
        sandbox.storeDefaults(["twitter": true])
        XCTAssertTrue(Page2Apps.isInstalled("twitter", profileId: b))
    }

    // MARK: RightPanelToolManager：默认 / 生效分开（plan §6-1）

    func testFloorWriteNeverTouchesRightPanelToolsBytes() throws {
        let tm = RightPanelToolManager(defaults: sandbox.defaults)
        tm.setEnabled("prompt", true, target: .defaults)   // 先有一份存档
        let before = try XCTUnwrap(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey))
        tm.activeProfileId = a

        tm.setEnabled("fileLibrary", false, target: .floor(a))

        XCTAssertEqual(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey), before, "层写不改默认存档字节")
        XCTAssertFalse(tm.pinnedTools.contains { $0.id == "fileLibrary" }, "当前层生效值卸了")
        XCTAssertEqual(Page2Apps.floors().stored("fileLibrary", profileId: a), false)

        // 当前层有覆盖时再改默认：persist 只编码默认那份，A 层的「卸了文件库」不会写成所有人的
        tm.setEnabled("browser", false, target: .defaults)
        let saved = RightPanelToolManager.decodedTools(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey))
        XCTAssertEqual(saved.first { $0.id == "fileLibrary" }?.isEnabled, true)
        XCTAssertEqual(saved.first { $0.id == "browser" }?.isEnabled, false)
        XCTAssertTrue(RightPanelToolManager(defaults: sandbox.defaults).pinnedTools.contains { $0.id == "fileLibrary" },
                      "重新读盘的新实例（没有层）文件库还在")
    }

    func testActiveProfileSwitchesEffectiveTools() {
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        Page2Apps.setFloor(true, for: "prompt", profileId: b)
        let tm = RightPanelToolManager(defaults: sandbox.defaults)
        let defaultPinned = tm.pinnedTools.map(\.id)
        XCTAssertTrue(defaultPinned.contains("fileLibrary"))
        XCTAssertFalse(defaultPinned.contains("prompt"), "没设层 = 默认")

        tm.activeProfileId = a
        XCTAssertFalse(tm.pinnedTools.contains { $0.id == "fileLibrary" })
        XCTAssertEqual(tm.tool(byId: "fileLibrary")?.isEnabled, false)
        XCTAssertEqual(tm.allToolsSorted.map(\.id), RightPanelToolManager(defaults: sandbox.defaults).allToolsSorted.map(\.id), "顺序只有默认一份")

        tm.activeProfileId = b
        XCTAssertTrue(tm.pinnedTools.contains { $0.id == "fileLibrary" })
        XCTAssertTrue(tm.pinnedTools.contains { $0.id == "prompt" })

        tm.activeProfileId = "xctest-app-floor-plain"
        XCTAssertEqual(tm.pinnedTools.map(\.id), defaultPinned)
    }

    func testDefaultsWriteReachesFloorsWithoutOverride() {
        let tm = RightPanelToolManager(defaults: sandbox.defaults)
        tm.activeProfileId = a
        tm.setEnabled("browser", true, target: .floor(a))   // 和默认一样 → 不存
        XCTAssertNil(Page2Apps.floors().floors[a])
        tm.setEnabled("browser", false, target: .floor(a))
        tm.setEnabled("browser", true, target: .defaults)
        XCTAssertFalse(tm.pinnedTools.contains { $0.id == "browser" }, "A 单独卸过：默认再开也不跟")

        tm.setEnabled("twitter", false, target: .defaults)
        XCTAssertFalse(tm.pinnedTools.contains { $0.id == "twitter" }, "A 没单独改推特：跟着默认关")
        tm.activeProfileId = b
        XCTAssertTrue(tm.pinnedTools.contains { $0.id == "browser" })
        XCTAssertFalse(tm.pinnedTools.contains { $0.id == "twitter" })
    }

    func testExternalFloorChangeRecomputes() {
        let tm = RightPanelToolManager(defaults: sandbox.defaults)
        tm.activeProfileId = a
        XCTAssertTrue(tm.pinnedTools.contains { $0.id == "fileLibrary" })
        // 备份恢复那样直接写键（主线程同步发 didChangeNotification）
        sandbox.defaults.set(Page2AppFloors(floors: [a: ["fileLibrary": false]]).encoded(), forKey: Page2Apps.floorsKey)
        XCTAssertFalse(tm.pinnedTools.contains { $0.id == "fileLibrary" })
        sandbox.defaults.removeObject(forKey: Page2Apps.floorsKey)
        XCTAssertTrue(tm.pinnedTools.contains { $0.id == "fileLibrary" })
    }

    func testEmptyFloorsMeansEffectiveEqualsStored() {
        sandbox.storeDefaults(["fileLibrary": false, "prompt": true])
        let tm = RightPanelToolManager(defaults: sandbox.defaults)
        let stored = RightPanelToolManager.decodedTools(sandbox.defaults.data(forKey: RightPanelToolManager.storageKey))
        for pid in [nil, a, b] as [String?] {
            tm.activeProfileId = pid
            XCTAssertEqual(tm.tools, stored, "层恒空：生效值和默认存档逐项一样（⑥0 零变化）")
        }
        for t in stored {
            XCTAssertEqual(Page2Apps.isInstalled(t.id, profileId: a), t.isEnabled, t.id)
        }
    }

    // MARK: ProfileManager：激活 / 删层 / 新建复制

    private func floor(_ id: String) -> Profile {
        Profile(id: id, name: "\(id) 名", emoji: "", description: "", userName: "你", assistantName: id)
    }

    private func withProfileManager(_ floors: [Profile], tm: RightPanelToolManager? = nil,
                                    _ body: (ProfileManager) throws -> Void) throws {
        let perm = PermissionSandbox()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Page2AppFloorsTests-\(UUID().uuidString)", isDirectory: true)
        let drawerSuite = "xctest-page2apps-drawer-\(UUID().uuidString)"
        defer {
            perm.leave()
            UserDefaults(suiteName: drawerSuite)?.removePersistentDomain(forName: drawerSuite)
            try? FileManager.default.removeItem(at: root)
        }
        let drawer = ToolDrawerStore(defaults: try XCTUnwrap(UserDefaults(suiteName: drawerSuite)))
        let schema = Schema([Conversation.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let m = ProfileManager(container: container, profiles: floors, currentProfile: floors[0], loadError: nil,
                               root: root, defaults: sandbox.defaults, sideEffectsEnabled: false,
                               themeManager: ThemeManager(defaults: sandbox.defaults), toolDrawer: drawer, toolManager: tm)
        try m.persistNew(floors)
        try body(m)
    }

    func testMirrorCurrentSetsActiveProfile() throws {
        let tm = RightPanelToolManager(defaults: sandbox.defaults)
        try withProfileManager([floor(a), floor(b)], tm: tm) { m in
            XCTAssertEqual(tm.activeProfileId, a, "init 里的 mirrorCurrent 就设上")
            m.mirrorCurrent(floor(b))
            XCTAssertEqual(tm.activeProfileId, b)
        }
    }

    func testDeleteProfileClearsAppFloor() throws {
        try withProfileManager([floor(a), floor(b)]) { m in
            Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
            Page2Apps.setFloor(false, for: "twitter", profileId: b)
            m.deleteProfile(floor(b), deleteData: false)
            XCTAssertNil(Page2Apps.floors().floors[b], "删掉的人单独装卸的清掉")
            XCTAssertEqual(Page2Apps.floors().stored("fileLibrary", profileId: a), false, "别人的不动")
        }
    }

    func testRemoveLegacyXiaoyaFloorClearsAppFloor() throws {
        try withProfileManager([floor(a), floor(Profile.xiaoyaId)]) { m in
            Page2Apps.setFloor(false, for: "fileLibrary", profileId: Profile.xiaoyaId)
            XCTAssertTrue(m.removeLegacyXiaoyaFloor())
            XCTAssertNil(sandbox.defaults.data(forKey: Page2Apps.floorsKey), "层全空了键也删了")
        }
    }

    func testDeleteWithoutAppFloorWritesNothing() throws {
        try withProfileManager([floor(a), floor(b)]) { m in
            m.deleteProfile(floor(b), deleteData: false)
            XCTAssertNil(sandbox.defaults.object(forKey: Page2Apps.floorsKey))
        }
    }

    func testCopyDeviceFloorSettingsCopiesOnlyAppOverrides() throws {
        try withProfileManager([floor(a), floor(b)]) { m in
            Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
            m.copyDeviceFloorSettings(from: a, to: "xctest-app-floor-new")
            XCTAssertEqual(Page2Apps.floors().floors["xctest-app-floor-new"], ["fileLibrary": false])
            XCTAssertFalse(Page2Apps.isInstalled("fileLibrary", profileId: "xctest-app-floor-new"))
            m.copyDeviceFloorSettings(from: b, to: "xctest-app-floor-new2")
            XCTAssertNil(Page2Apps.floors().floors["xctest-app-floor-new2"], "来源跟默认 → 新层也空")
        }
    }

    func testAddProfileDoesNotCopyAppFloor() throws {
        try withProfileManager([floor(a)]) { m in
            Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
            let card = floor("xctest-app-floor-card")
            m.addProfile(card)
            XCTAssertNil(Page2Apps.floors().floors[card.id])
            XCTAssertTrue(Page2Apps.isInstalled("fileLibrary", profileId: card.id))
        }
    }

    // MARK: 主屏摆法按层（P3⑥b）：删层删文件夹、新建复制层文件

    private func withHomeDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Page2HomeFloors-\(UUID().uuidString)", isDirectory: true)
        let previous = Page2HomeStore.storageDirectory
        Page2HomeStore.storageDirectory = dir
        Page2HomeStore.dropInstances()
        defer {
            Page2HomeStore.storageDirectory = previous
            Page2HomeStore.dropInstances()
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("default".utf8).write(to: Page2HomeStore.defaultURL)
        try body(dir)
    }

    private func writeHome(_ text: String, for profileId: String) throws {
        try FileManager.default.createDirectory(at: Page2HomeStore.floorDirectory(profileId), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: Page2HomeStore.floorURL(profileId))
    }

    func testDeleteProfileRemovesHomeLayoutFolder() throws {
        try withHomeDirectory { _ in
            try writeHome("A", for: a)
            try writeHome("B", for: b)
            try withProfileManager([floor(a), floor(b)]) { m in
                m.deleteProfile(floor(b), deleteData: false)
                XCTAssertFalse(FileManager.default.fileExists(atPath: Page2HomeStore.floorDirectory(b).path), "删掉的人的主屏文件夹整个删")
                XCTAssertEqual(try Data(contentsOf: Page2HomeStore.floorURL(a)), Data("A".utf8), "别人的不动")
                XCTAssertEqual(try Data(contentsOf: Page2HomeStore.defaultURL), Data("default".utf8), "默认主屏不动")
            }
        }
    }

    func testCopyDeviceFloorSettingsCopiesHomeLayoutFileOnlyWhenSourceHasOne() throws {
        try withHomeDirectory { _ in
            try writeHome("A", for: a)
            try withProfileManager([floor(a), floor(b)]) { m in
                m.copyDeviceFloorSettings(from: a, to: "xctest-home-new")
                XCTAssertEqual(try Data(contentsOf: Page2HomeStore.floorURL("xctest-home-new")), Data("A".utf8), "新建抄当前这个人的主屏")
                m.copyDeviceFloorSettings(from: b, to: "xctest-home-new2")
                XCTAssertFalse(FileManager.default.fileExists(atPath: Page2HomeStore.floorDirectory("xctest-home-new2").path), "来源跟默认 → 新人也跟默认")
                let card = floor("xctest-home-card")
                m.addProfile(card)
                XCTAssertFalse(FileManager.default.fileExists(atPath: Page2HomeStore.floorDirectory(card.id).path), "卡建 / 领养不抄")
                XCTAssertEqual(try Data(contentsOf: Page2HomeStore.defaultURL), Data("default".utf8))
            }
        }
    }

    // MARK: 备份往返

    func testBackupRoundTripKeepsAppFloorBytes() throws {
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a)
        Page2Apps.setFloor(true, for: "prompt", profileId: b)
        let bytes = try XCTUnwrap(sandbox.defaults.data(forKey: Page2Apps.floorsKey))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Page2AppFloorsBackup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try GlobalExporter.exportDeviceFloorFiles(to: dir, from: sandbox.defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("page2_app_floors.json").path))

        let dstName = "xctest-page2apps-restore-\(UUID().uuidString)"
        let dst = try XCTUnwrap(UserDefaults(suiteName: dstName))
        defer { dst.removePersistentDomain(forName: dstName) }
        try PendingImportApplier.restoreDeviceFloorFiles(from: dir, into: dst)
        XCTAssertEqual(dst.data(forKey: Page2Apps.floorsKey), bytes, "字节相同")

        // 老备份没这个文件 → 本机不动
        let oldDir = dir.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let local = Page2AppFloors(floors: [a: ["twitter": false]]).encoded()
        dst.set(local, forKey: Page2Apps.floorsKey)
        try PendingImportApplier.restoreDeviceFloorFiles(from: oldDir, into: dst)
        XCTAssertEqual(dst.data(forKey: Page2Apps.floorsKey), local)
    }
}
