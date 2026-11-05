import XCTest
import SwiftData
@testable import 记忆花园

/// 10-16 改向（plan-onboarding-xiaoya-impl §10-2）：P2 版本自动种过的小芽楼层（id xiaoya）启动时静默移除。
/// 临时 BlobStore + 内存偏好，不碰真实楼层列表
@MainActor
final class XiaoyaFloorMigrationTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var container: ModelContainer!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xiaoya-floor-migration-\(UUID().uuidString)")
        suite = "XiaoyaFloorMigrationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let schema = Schema([Conversation.self, MessageNode.self])
        container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var blobs: URL { root.appendingPathComponent("blobs") }

    /// P2 版本种的那层（照当时的 Profile.xiaoyaFloor）
    private let legacyFloor = Profile(id: Profile.xiaoyaId, name: "小芽", emoji: "🌱", description: "小芽住在这里",
                                      userName: "你", assistantName: "小芽", createdAt: Date(timeIntervalSince1970: 0))

    private func ta(_ id: String, _ name: String) -> Profile {
        Profile(id: id, name: name, emoji: "🎭", description: "", userName: "粟粟", assistantName: name)
    }

    /// 照启动的读法：列表从临时 BlobStore 读，读坏就带 loadError（只读）
    private func manager(_ profiles: [Profile]? = nil, currentId: String? = nil) throws -> ProfileManager {
        if let profiles { try BlobStore.set(try JSONEncoder().encode(profiles), forKey: "savedProfiles", root: blobs) }
        let loaded = ProfileManager.loadProfilesChecked(root: blobs, defaults: defaults)
        let current = loaded.profiles.first { $0.id == currentId } ?? loaded.profiles[0]
        return ProfileManager(container: container, profiles: loaded.profiles, currentProfile: current, loadError: loaded.error,
                              root: blobs, defaults: defaults, sideEffectsEnabled: false)
    }

    private func storedIds() -> [String] {
        ProfileManager.loadProfilesChecked(root: blobs, defaults: defaults).profiles.map(\.id)
    }

    func testRemovesFloorKeepsCurrentAndOrder() throws {
        let pm = try manager([legacyFloor, ta("a", "澪"), ta("b", "阿澄")], currentId: "b")
        XCTAssertTrue(pm.removeLegacyXiaoyaFloor())
        XCTAssertEqual(pm.profiles.map(\.id), ["a", "b"])
        XCTAssertEqual(storedIds(), ["a", "b"], "落盘")
        XCTAssertEqual(pm.currentProfile.id, "b", "当前楼层不是它就不动")
        XCTAssertNil(defaults.string(forKey: "lastProfileId"))
        // 幂等
        XCTAssertFalse(pm.removeLegacyXiaoyaFloor())
        XCTAssertEqual(storedIds(), ["a", "b"])
    }

    func testCurrentXiaoyaMovesToFirstRemaining() throws {
        let pm = try manager([legacyFloor, ta("a", "澪"), ta("b", "阿澄")], currentId: Profile.xiaoyaId)
        XCTAssertTrue(pm.removeLegacyXiaoyaFloor())
        XCTAssertEqual(pm.currentProfile.id, "a")
        XCTAssertEqual(defaults.string(forKey: "lastProfileId"), "a")
        XCTAssertEqual(defaults.string(forKey: "userName"), "粟粟")
        XCTAssertEqual(defaults.string(forKey: "assistantName"), "澪")
    }

    /// P5 新装只种过 [小芽]：移完是空的 → 种回对话空间，落在它上面
    func testOnlyXiaoyaReseedsWorkspace() throws {
        let pm = try manager([legacyFloor], currentId: Profile.xiaoyaId)
        XCTAssertTrue(pm.removeLegacyXiaoyaFloor())
        XCTAssertEqual(pm.profiles.map(\.id), Profile.seedProfiles.map(\.id))
        XCTAssertEqual(storedIds(), Profile.seedProfiles.map(\.id))
        XCTAssertEqual(pm.currentProfile.id, Profile.seedProfiles[0].id)
        XCTAssertEqual(defaults.string(forKey: "lastProfileId"), Profile.seedProfiles[0].id)
    }

    /// 按 id 认：她自己建的同名「小芽」楼层不动
    func testSameNameTaFloorIsKept() throws {
        let pm = try manager([ta("a", "澪"), legacyFloor, ta("mine", "小芽")], currentId: "mine")
        XCTAssertTrue(pm.removeLegacyXiaoyaFloor())
        XCTAssertEqual(pm.profiles.map(\.id), ["a", "mine"])
        XCTAssertEqual(pm.currentProfile.id, "mine")
    }

    func testCleansLegacyKeys() throws {
        defaults.set("a", forKey: "xiaoya.targetProfileId")
        defaults.set(true, forKey: "xiaoya.movedInV1")
        let pm = try manager([legacyFloor, ta("a", "澪")], currentId: "a")
        pm.removeLegacyXiaoyaFloor()
        XCTAssertNil(defaults.object(forKey: "xiaoya.targetProfileId"))
        XCTAssertNil(defaults.object(forKey: "xiaoya.movedInV1"))
    }

    /// 没有小芽楼层（没装过 P2 版本 / 已经移过）：列表不写，旧键照清
    func testNoFloorLeavesListAlone() throws {
        defaults.set("a", forKey: "xiaoya.targetProfileId")
        let pm = try manager([ta("a", "澪")], currentId: "a")
        let before = try Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: blobs))
        XCTAssertFalse(pm.removeLegacyXiaoyaFloor())
        XCTAssertEqual(try Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: blobs)), before)
        XCTAssertNil(defaults.object(forKey: "xiaoya.targetProfileId"))
    }

    /// 列表读坏（只读）：什么都不动，下次启动再来
    func testReadOnlyDoesNothing() throws {
        defaults.set(Data("损坏 JSON".utf8), forKey: "savedProfiles")
        defaults.set(true, forKey: "xiaoya.movedInV1")
        let pm = try manager()
        XCTAssertTrue(pm.isReadOnly)
        XCTAssertFalse(pm.removeLegacyXiaoyaFloor())
        XCTAssertEqual(defaults.data(forKey: "savedProfiles"), Data("损坏 JSON".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BlobStore.path(forKey: "savedProfiles", root: blobs).path))
        XCTAssertTrue(defaults.bool(forKey: "xiaoya.movedInV1"), "只读时连旧键也不碰")
    }
}
