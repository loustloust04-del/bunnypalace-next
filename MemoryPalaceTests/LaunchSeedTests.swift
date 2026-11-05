import XCTest
@testable import 记忆花园

/// 首启种子（plan-onboarding-xiaoya-impl §10-3）：楼层列表真为空才种，种的是对话空间（小芽不再有自己的楼层）
final class LaunchSeedTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "LaunchSeedTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func savedIds() throws -> [String] {
        try JSONDecoder().decode([Profile].self, from: Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root))).map(\.id)
    }

    func testFreshInstallSeedsWorkspace() throws {
        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.profiles.map(\.id), Profile.seedProfiles.map(\.id))
        XCTAssertEqual(try savedIds(), Profile.seedProfiles.map(\.id))
        XCTAssertFalse(loaded.profiles.contains { $0.id == Profile.xiaoyaId })
    }

    /// 旧键真（UI 测试 / 测量台 `-onboardingCompletedV1 YES`）种的也一样
    func testLegacyFlagSeedsSame() throws {
        defaults.set(true, forKey: XiaoyaScriptRunner.legacyCompletedKey)
        XCTAssertEqual(ProfileManager.loadProfilesChecked(root: root, defaults: defaults).profiles.map(\.id), Profile.seedProfiles.map(\.id))
    }

    func testExistingListIsNotReseeded() throws {
        let hers = [Profile(id: "her", name: "她的楼层", emoji: "", description: "", userName: "你", assistantName: "助手")]
        try BlobStore.set(try JSONEncoder().encode(hers), forKey: "savedProfiles", root: root)
        XCTAssertEqual(ProfileManager.loadProfilesChecked(root: root, defaults: defaults).profiles.map(\.id), ["her"])
        XCTAssertNil(defaults.string(forKey: "lastProfileId"))
    }

    /// 只读兜底语义不变：内存里给 Profile.seedProfiles，不写文件
    func testUnreadableListKeepsReadOnlySeed() throws {
        let url = BlobStore.path(forKey: "savedProfiles", root: root)
        try Data("not json".utf8).write(to: url)
        let loaded = ProfileManager.loadProfilesChecked(root: root, defaults: defaults)
        XCTAssertNotNil(loaded.error)
        XCTAssertEqual(loaded.profiles.map(\.id), Profile.seedProfiles.map(\.id))
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
    }

    func testLibraryLooksEmptyEvidence() {
        func empty(credentials: [String] = [], cards: [String] = [CardSample.id], trusted: Bool = true, count: Int? = 0) -> Bool? {
            FreshInstallProbe.libraryLooksEmpty(credentialIds: credentials, cardIds: cards, cardsTrusted: trusted, conversationCount: { count })
        }
        XCTAssertEqual(empty(), true)
        XCTAssertEqual(empty(credentials: ["cc-bridge"]), true, "自动种的卡不算")
        XCTAssertEqual(empty(credentials: ["cred-1"]), false)
        XCTAssertEqual(empty(cards: ["card-1"]), false)
        XCTAssertEqual(empty(count: 3), false)
        XCTAssertNil(empty(count: nil))
        XCTAssertNil(empty(trusted: false))
    }
}
