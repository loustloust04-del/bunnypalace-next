import Observation
import SwiftData
import XCTest
@testable import 记忆花园

/// atrium P3④a：聊天主题按楼层存（`Profile.chatAppearance.themeId`），切层 / 改当前层时镜像进 ThemeManager.chatThemeId。
/// ④b：字体字号 / 气泡几何 / 行距段距 9 项按楼层存，迁移标记落了之后镜像进老 UserDefaults 键。
@MainActor
final class ChatAppearanceTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var theme: ThemeManager!
    private var manager: ProfileManager!
    private var darkId: String!
    private var lightId: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatAppearanceTests-\(UUID().uuidString)", isDirectory: true)
        suite = "ChatAppearanceTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        theme = ThemeManager(defaults: defaults)
        darkId = try XCTUnwrap(theme.saveThemeCopy(from: AppThemeDefinition.iMessageTheme.id, name: "A 的", select: false))
        lightId = try XCTUnwrap(theme.saveThemeCopy(from: AppThemeDefinition.defaultTheme.id, name: "B 的", select: false))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func floor(_ id: String, themeId: String?) -> Profile {
        var p = Profile(id: id, name: id, emoji: "", description: "", userName: "你", assistantName: id)
        if let themeId { p.chatAppearance = ChatAppearance(themeId: themeId) }
        return p
    }

    private func makeManager(_ floors: [Profile], current: Int = 0) throws -> ProfileManager {
        let schema = Schema([Conversation.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let m = ProfileManager(container: container, profiles: floors, currentProfile: floors[current], loadError: nil,
                               root: root, defaults: defaults, sideEffectsEnabled: false, themeManager: theme)
        try m.persistNew(floors)
        return m
    }

    private func saved() throws -> [Profile] {
        try JSONDecoder().decode([Profile].self, from: Data(contentsOf: BlobStore.path(forKey: "savedProfiles", root: root)))
    }

    // MARK: - 存储

    func testLegacyJSONWithoutKeyDecodesNilAndRoundTrips() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(floor("old", themeId: "x"))) as? [String: Any])
        json.removeValue(forKey: "chatAppearance")
        let legacy = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.chatAppearance)

        let withTheme = floor("new", themeId: darkId)
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(withTheme))
        XCTAssertEqual(decoded.chatAppearance?.themeId, darkId)
        // 空子结构（themeId 也没有）同样解得开
        let empty = try JSONDecoder().decode(ChatAppearance.self, from: Data("{}".utf8))
        XCTAssertNil(empty.themeId)
    }

    // MARK: - 镜像

    func testInitMirrorsCurrentFloor() throws {
        manager = try makeManager([floor("a", themeId: darkId), floor("b", themeId: nil)])
        XCTAssertEqual(theme.chatThemeId, darkId)
        XCTAssertEqual(theme.chatTheme.id, darkId)
    }

    func testSwitchMirrorsNewFloorAndTouches() throws {
        manager = try makeManager([floor("a", themeId: darkId), floor("b", themeId: lightId), floor("c", themeId: nil)])
        let before = theme.themeChangeID
        manager.switchTo(manager.profiles[1])
        XCTAssertEqual(theme.chatThemeId, lightId)
        XCTAssertNotEqual(theme.themeChangeID, before, "换了聊天主题必须 touch，否则 markdown 缓存串色")
        manager.switchTo(manager.profiles[2])
        XCTAssertNil(theme.chatThemeId)
        XCTAssertEqual(theme.chatTheme.id, theme.selectedThemeId, "nil = 跟随界面主题")
    }

    /// 镜像写在 currentProfile 赋值之前：新层重建的那一帧读到的就是新层的聊天主题
    func testMirrorHappensBeforeCurrentProfilePublishes() throws {
        manager = try makeManager([floor("a", themeId: darkId), floor("b", themeId: lightId)])
        final class Seen: @unchecked Sendable {
            let theme: ThemeManager
            var fired = false
            var chatThemeId: String?
            init(_ theme: ThemeManager) { self.theme = theme }
        }
        let seen = Seen(theme)
        withObservationTracking {
            _ = manager.currentProfile
        } onChange: {
            // onChange 在 willSet 里同步调：这时 currentProfile 还没换，镜像必须已经写好
            seen.fired = true
            seen.chatThemeId = seen.theme.chatThemeId
        }
        manager.switchTo(manager.profiles[1])
        XCTAssertTrue(seen.fired)
        XCTAssertEqual(seen.chatThemeId, lightId)
    }

    func testSetChatThemeOnCurrentMirrorsOnOtherOnlyWrites() throws {
        manager = try makeManager([floor("a", themeId: nil), floor("b", themeId: nil)])
        try manager.setChatTheme(darkId, profileId: "a")
        XCTAssertEqual(theme.chatThemeId, darkId)
        XCTAssertEqual(manager.currentProfile.chatAppearance?.themeId, darkId)

        try manager.setChatTheme(lightId, profileId: "b")
        XCTAssertEqual(theme.chatThemeId, darkId, "非当前层只写楼层不镜像")
        XCTAssertEqual(try saved().map { $0.chatAppearance?.themeId }, [darkId, lightId])

        try manager.setChatTheme(nil, profileId: "a")
        XCTAssertNil(theme.chatThemeId)
        XCTAssertThrowsError(try manager.setChatTheme(darkId, profileId: "nobody"))
    }

    func testRenameKeepsChatThemeMirror() throws {
        manager = try makeManager([floor("a", themeId: darkId)])
        try manager.renameCurrent(userName: "栗子", assistantName: "阿岚")
        XCTAssertEqual(defaults.string(forKey: "userName"), "栗子")
        XCTAssertEqual(theme.chatThemeId, darkId)
    }

    func testRemovingLegacyXiaoyaFloorMirrorsRemaining() throws {
        manager = try makeManager([floor(Profile.xiaoyaId, themeId: nil), floor("a", themeId: lightId)])
        XCTAssertNil(theme.chatThemeId)
        XCTAssertTrue(manager.removeLegacyXiaoyaFloor())
        XCTAssertEqual(manager.currentProfile.id, "a")
        XCTAssertEqual(theme.chatThemeId, lightId)
    }

    // MARK: - 在用名单 / 删主题

    func testProfilesUsingChatThemeCountsFollowersUnderInterfaceTheme() throws {
        manager = try makeManager([floor("a", themeId: darkId), floor("b", themeId: nil), floor("c", themeId: "gone"), floor("d", themeId: lightId)])
        XCTAssertEqual(manager.profiles(usingChatTheme: darkId).map(\.id), ["a"])
        XCTAssertEqual(manager.profiles(usingChatTheme: theme.selectedThemeId).map(\.id), ["b", "c"], "nil 和悬空都算界面主题")
        XCTAssertEqual(ThemeTarget.person("a").sharers(of: darkId, theme, manager), [])
        XCTAssertEqual(ThemeTarget.person("b").sharers(of: theme.selectedThemeId, theme, manager), ["c", "界面（宫殿默认）"])
        XCTAssertTrue(ThemeTarget.person("c").isFollowingInterface(theme, manager))
        XCTAssertFalse(ThemeTarget.person("d").isFollowingInterface(theme, manager))
    }

    func testForgetChatThemeClearsFloorsPersistsAndCurrentFallsBack() throws {
        manager = try makeManager([floor("a", themeId: darkId), floor("b", themeId: darkId), floor("c", themeId: lightId)])
        XCTAssertEqual(theme.chatThemeId, darkId)
        theme.deleteTheme(id: darkId)
        manager.forgetChatTheme(darkId)
        XCTAssertEqual(manager.profiles.map { $0.chatAppearance?.themeId }, [nil, nil, lightId])
        XCTAssertEqual(try saved().map { $0.chatAppearance?.themeId }, [nil, nil, lightId])
        XCTAssertNil(manager.currentProfile.chatAppearance?.themeId)
        XCTAssertNil(theme.chatThemeId)
        XCTAssertEqual(theme.chatTheme.id, theme.selectedThemeId)
    }

    // MARK: - 新建楼层复制

    func testCopyInheritedSettings() {
        var source = floor("src", themeId: darkId)
        source.preferredModel = "anthropic/claude-haiku"
        source.timeAwarenessEnabled = true
        source.voiceStability = 1
        source.voiceStyle = 0.3
        source.voiceSpeed = 0.9
        source.userName = "不该被带走"
        var created = Profile(name: "新层", emoji: "", description: "", userName: "你", assistantName: "")
        created.copyInheritedSettings(from: source)
        XCTAssertEqual(created.preferredModel, "anthropic/claude-haiku")
        XCTAssertTrue(created.timeAwarenessEnabled)
        XCTAssertEqual(VoiceTuning.current(for: created), VoiceTuning.current(for: source))
        XCTAssertEqual(created.chatAppearance, ChatAppearance(themeId: darkId))
        XCTAssertEqual(created.userName, "你")
        XCTAssertNotEqual(created.id, source.id)
    }

    // MARK: - ④b 字体字号 / 气泡几何

    private func layout(_ id: String, themeId: String? = nil, fontName: String? = nil, fontScale: Double? = nil,
                        bubbleSpacing: Double? = nil) -> Profile {
        var p = floor(id, themeId: themeId)
        p.chatAppearance = ChatAppearance(themeId: themeId, fontName: fontName, fontScale: fontScale, bubbleSpacing: bubbleSpacing)
        return p
    }

    /// 只数 9 个老键的写入（set / remove），别的键（称呼、lastProfileId）不算
    private final class CountingDefaults: UserDefaults {
        var writes: [String] = []
        private func note(_ key: String) { if ChatAppearance.legacyKeys.contains(key) { writes.append(key) } }
        override func set(_ value: Any?, forKey defaultName: String) { note(defaultName); super.set(value, forKey: defaultName) }
        override func set(_ value: Double, forKey defaultName: String) { note(defaultName); super.set(value, forKey: defaultName) }
        override func removeObject(forKey defaultName: String) { note(defaultName); super.removeObject(forKey: defaultName) }
    }

    func testMigrationCopiesSetKeysIntoEveryFloorOnce() {
        defaults.set("老字体", forKey: "selectedFont")
        defaults.set(1.5, forKey: "fontScale")
        defaults.set(4.0, forKey: "bubbleCornerRadius")
        let floors = [floor("a", themeId: nil), layout("b", themeId: darkId, fontScale: 0.9)]
        var persisted: [[Profile]] = []
        XCTAssertTrue(ChatAppearance.migrateGlobalToFloors(profiles: floors, defaults: defaults) { persisted.append($0); return true })
        XCTAssertTrue(defaults.bool(forKey: ChatAppearance.migratedKey))
        let out = try? XCTUnwrap(persisted.first)
        XCTAssertEqual(out?.map(\.id), ["a", "b"])
        XCTAssertEqual(out?[0].chatAppearance, ChatAppearance(fontName: "老字体", fontScale: 1.5, bubbleCornerRadius: 4))
        XCTAssertEqual(out?[1].chatAppearance, ChatAppearance(themeId: darkId, fontName: "老字体", fontScale: 0.9, bubbleCornerRadius: 4),
                       "themeId 留着；层上已有的值不被老键盖")
        XCTAssertNil(out?[0].chatAppearance?.lineSpacingScale, "没设过的老键留 nil")

        XCTAssertFalse(ChatAppearance.migrateGlobalToFloors(profiles: floors, defaults: defaults) { persisted.append($0); return true })
        XCTAssertEqual(persisted.count, 1, "只跑一次")
    }

    func testMigrationWithoutLegacyKeysOnlyMarks() {
        var calls = 0
        XCTAssertTrue(ChatAppearance.migrateGlobalToFloors(profiles: [floor("a", themeId: darkId)], defaults: defaults) { _ in calls += 1; return true })
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(defaults.bool(forKey: ChatAppearance.migratedKey))
    }

    func testMigrationPersistFailureLeavesMarkerUnset() {
        defaults.set(1.5, forKey: "fontScale")
        let floors = [floor("a", themeId: nil)]
        XCTAssertFalse(ChatAppearance.migrateGlobalToFloors(profiles: floors, defaults: defaults) { _ in false })
        XCTAssertFalse(defaults.bool(forKey: ChatAppearance.migratedKey), "落盘失败不落标记，下次启动重试")
        XCTAssertEqual(defaults.double(forKey: "fontScale"), 1.5, "老键不动")
        XCTAssertTrue(ChatAppearance.migrateGlobalToFloors(profiles: floors, defaults: defaults) { _ in true })
    }

    /// 迁移前（init 镜像早于启动迁移）：各层全 nil，镜像不能把老全局值删掉；只镜像聊天主题
    func testMirrorBeforeMarkerLeavesLegacyKeys() throws {
        defaults.set(1.5, forKey: "fontScale")
        defaults.set("老字体", forKey: "selectedFont")
        manager = try makeManager([floor("a", themeId: darkId), layout("b", fontScale: 0.8)])
        XCTAssertEqual(theme.chatThemeId, darkId)
        manager.switchTo(manager.profiles[1])
        XCTAssertNil(theme.chatThemeId)
        XCTAssertEqual(defaults.double(forKey: "fontScale"), 1.5)
        XCTAssertEqual(defaults.string(forKey: "selectedFont"), "老字体")
    }

    func testMirrorAfterMarkerWritesValuesAndRemovesNil() throws {
        defaults.set(true, forKey: ChatAppearance.migratedKey)
        defaults.set(1.5, forKey: "fontScale")
        defaults.set(20.0, forKey: "bubbleSpacing")
        defaults.set("老字体", forKey: "selectedFont")
        manager = try makeManager([layout("a", fontName: "Y", fontScale: 1.3), floor("b", themeId: nil)])
        XCTAssertEqual(defaults.double(forKey: "fontScale"), 1.3)
        XCTAssertEqual(defaults.string(forKey: "selectedFont"), "Y")
        XCTAssertNil(defaults.object(forKey: "bubbleSpacing"), "层上 nil → 删键，读侧默认值生效")
        manager.switchTo(manager.profiles[1])
        for key in ChatAppearance.legacyKeys { XCTAssertNil(defaults.object(forKey: key), key) }
    }

    func testMirrorSkipsUnchangedKeys() throws {
        let counting = try XCTUnwrap(CountingDefaults(suiteName: suite))
        counting.set(true, forKey: ChatAppearance.migratedKey)
        let a = ChatAppearance(themeId: darkId, fontName: "Y", fontScale: 1.3, bubbleSpacing: 20)
        ChatAppearance.mirror(a, into: counting, theme: theme)
        XCTAssertEqual(Set(counting.writes), ["selectedFont", "fontScale", "bubbleSpacing"], "没设过的键本来就没有，不用删")
        counting.writes = []
        ChatAppearance.mirror(a, into: counting, theme: theme)
        var other = a
        other.themeId = lightId
        ChatAppearance.mirror(other, into: counting, theme: theme)
        XCTAssertEqual(counting.writes, [], "值没变不写（换聊天主题不重写 9 个键）")
        other.bubbleSpacing = nil
        ChatAppearance.mirror(other, into: counting, theme: theme)
        XCTAssertEqual(Set(counting.writes), ["bubbleSpacing"])
    }

    func testUpdateChatAppearanceCurrentMirrorsOtherOnlyWrites() throws {
        defaults.set(true, forKey: ChatAppearance.migratedKey)
        manager = try makeManager([floor("a", themeId: darkId), floor("b", themeId: nil)])
        try manager.updateChatAppearance(profileId: "a") { $0.fontScale = 1.6 }
        XCTAssertEqual(defaults.double(forKey: "fontScale"), 1.6)
        XCTAssertEqual(manager.currentProfile.chatAppearance?.themeId, darkId, "只改这一项，主题不丢")
        try manager.updateChatAppearance(profileId: "b") { $0.fontScale = 0.7 }
        XCTAssertEqual(defaults.double(forKey: "fontScale"), 1.6, "非当前层只写楼层不镜像")
        XCTAssertEqual(try saved().map { $0.chatAppearance?.fontScale }, [1.6, 0.7])
        manager.switchTo(manager.profiles[1])
        XCTAssertEqual(defaults.double(forKey: "fontScale"), 0.7)
        try manager.updateChatAppearance(profileId: "b") { $0.resetLayout() }
        XCTAssertNil(defaults.object(forKey: "fontScale"), "恢复默认 = 删键")
        XCTAssertThrowsError(try manager.updateChatAppearance(profileId: "nobody") { $0.fontScale = 1 })
    }

    func testCopyInheritedSettingsCarriesLayout() {
        var source = layout("src", themeId: darkId, fontName: "Y", fontScale: 1.4, bubbleSpacing: 22)
        source.chatAppearance?.bubbleModeCornerRadius = 30
        source.chatAppearance?.lineSpacingScale = 1.1
        var created = Profile(name: "新层", emoji: "", description: "", userName: "你", assistantName: "")
        created.copyInheritedSettings(from: source)
        XCTAssertEqual(created.chatAppearance, source.chatAppearance)
    }
}
