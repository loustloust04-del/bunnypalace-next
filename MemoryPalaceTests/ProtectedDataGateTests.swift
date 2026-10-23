import XCTest
import SwiftData
@testable import 记忆花园

/// #024 启动闸门：只有数据保护拒绝（EPERM）才算锁着；新装没库、库可读都照常启动
final class ProtectedDataGateTests: XCTestCase {
    func testMissingStoreIsNotLocked() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate-missing-\(UUID().uuidString).store")
        XCTAssertFalse(ProtectedDataGate.isLocked(url))
    }

    func testReadableStoreIsNotLocked() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate-readable-\(UUID().uuidString).store")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(ProtectedDataGate.isLocked(url))
    }

    func testStorePathMatchesContainerURL() {
        XCTAssertEqual(ProfileManager.unifiedStorePath, ProfileManager.unifiedStoreURL)
    }

    // MARK: - loadProfiles 读失败不覆盖

    private func tempRoot() throws -> (URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-blobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "gate-\(UUID().uuidString)"
        return (root, UserDefaults(suiteName: suite)!)
    }

    func testAbsentProfilesSeedsAndSaves() throws {
        let (root, defaults) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = ProfileManager.loadProfiles(root: root, defaults: defaults)
        XCTAssertEqual(loaded.map(\.id), Profile.seedProfiles.map(\.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: BlobStore.path(forKey: "savedProfiles", root: root).path))
    }

    func testUndecodableProfilesAreNotOverwritten() throws {
        let (root, defaults) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = BlobStore.path(forKey: "savedProfiles", root: root)
        let garbage = Data("not json".utf8)
        try garbage.write(to: url)
        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        XCTAssertNotNil(loaded.error, "解码失败也要带 error，管理器才会只读")
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    /// 普通文件读不了但能被 atomic 替换：旧实现会拿 seed 覆盖，新实现必须原样留着
    func testUnreadableProfilesAreNotOverwritten() throws {
        let (root, defaults) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = BlobStore.path(forKey: "savedProfiles", root: root)
        let original = Data("[\"她的楼层\"]".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        _ = ProfileManager.loadProfiles(root: root, defaults: defaults)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testPermissionDeniedIsNotTreatedAsDataProtection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate-eacces-\(UUID().uuidString).store")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        XCTAssertFalse(ProtectedDataGate.isLocked(url))
    }

    func testSeedWrittenOnFirstLaunchDecodesBack() throws {
        let (root, defaults) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = ProfileManager.loadProfiles(root: root, defaults: defaults)
        let saved = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root)))
        XCTAssertEqual(saved.map(\.id), Profile.seedProfiles.map(\.id))
    }

    // MARK: - #037 一次加载的成败带给管理器

    private func herFloors() -> [Profile] {
        [Profile(id: "her-a", name: "甲", emoji: "", description: "", userName: "你", assistantName: "助手"),
         Profile(id: "her-b", name: "乙", emoji: "", description: "", userName: "你", assistantName: "助手")]
    }

    private func manager(_ loaded: (profiles: [Profile], error: Error?), root: URL, defaults: UserDefaults) throws -> ProfileManager {
        let schema = Schema([Conversation.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        return ProfileManager(container: container, profiles: loaded.profiles, currentProfile: loaded.profiles[0], loadError: loaded.error,
                              root: root, defaults: defaults, sideEffectsEnabled: false)
    }

    /// 旧实现：loadProfiles 读失败给 seed，管理器复读成功不设错误 → 一保存就拿 seed 覆盖她的列表
    func testFailedFirstLoadStaysReadOnlyEvenIfFileBecomesReadable() throws {
        let (root, defaults) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = BlobStore.path(forKey: "savedProfiles", root: root)
        let original = try JSONEncoder().encode(herFloors())
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let posix = (loaded.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError
        XCTAssertEqual(posix?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(posix?.code, Int(EACCES))
        XCTAssertEqual(loaded.profiles.map(\.id), Profile.seedProfiles.map(\.id))
        // 此刻文件已能读通（旧实现管理器复读就是读到这个，于是不进只读）
        XCTAssertEqual(try JSONDecoder().decode([Profile].self, from: Data(contentsOf: url)).map(\.id), ["her-a", "her-b"])

        let pm = try manager(loaded, root: root, defaults: defaults)
        XCTAssertTrue(pm.isReadOnly)
        XCTAssertThrowsError(try pm.persistNew(Profile(id: "new", name: "新", emoji: "", description: "", userName: "你", assistantName: "助手")))
        var seed = pm.profiles[0]
        seed.name = "改名"
        pm.updateProfile(seed)
        XCTAssertEqual(pm.profiles[0].name, Profile.seedProfiles[0].name, "只读时连内存都不改")
        XCTAssertFalse(pm.updateProfilesPersisting([seed]))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    /// seed 楼层指着共享内置模板，只读期间编辑人设不能落到模板上
    func testBlockedPresetManagerDoesNotSave() throws {
        let (root, defaults) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let presets = PresetManager(root: root, defaults: defaults)
        presets.blockWrites(CocoaError(.fileReadNoPermission))
        var template = try XCTUnwrap(presets.preset(byId: Preset.balanced.id))
        template.prompts[0].content = "只读期间的编辑"
        presets.save(template)
        XCTAssertThrowsError(try presets.persistNew(Preset(id: "x", name: "x")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BlobStore.path(forKey: "savedPresets", root: root).path))
    }

    func testTrustedLoadCanSave() throws {
        let (root, defaults) = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = BlobStore.path(forKey: "savedProfiles", root: root)
        try JSONEncoder().encode(herFloors()).write(to: url)
        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        XCTAssertNil(loaded.error)
        let pm = try manager(loaded, root: root, defaults: defaults)
        XCTAssertFalse(pm.isReadOnly)
        try pm.persistNew(Profile(id: "new", name: "新", emoji: "", description: "", userName: "你", assistantName: "助手"))
        XCTAssertEqual(try JSONDecoder().decode([Profile].self, from: Data(contentsOf: url)).map(\.id), ["her-a", "her-b", "new"])
    }

    /// 上级目录不可搜索：fileExists 是 false，旧实现当「不存在」返回 nil
    func testUnsearchableDirectoryThrowsInsteadOfAbsent() throws {
        let (root, defaults) = try tempRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let url = BlobStore.path(forKey: "savedProfiles", root: root)
        let original = try JSONEncoder().encode(herFloors())
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        XCTAssertThrowsError(try BlobStore.read(forKey: "savedProfiles", root: root, defaults: defaults))
        XCTAssertNotNil(ProfileManager.loadProfilesChecked(root: root, defaults: defaults).error)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
