import MemoryCore
import SwiftData
import XCTest
@testable import 记忆花园

/// plan-floor-main-thread：每层一条 mainsession（建 / 复用 / 删不掉 / `/clear` 存档换新）、
/// 别的窗口〔状态〕里那几行（`WakeRecent.lines`）、`heartbeat_task` 的 notify 默认、老任务存档读得出
@MainActor
final class MainSessionTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var manager: ProfileManager!
    private var context: ModelContext!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MainSessionTests-\(UUID().uuidString)", isDirectory: true)
        suite = "MainSessionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let floor = Profile(id: "floor-a", name: "a", emoji: "", description: "", userName: "你", assistantName: "小岚")
        let schema = Schema([Conversation.self, MessageNode.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        manager = ProfileManager(container: container, profiles: [floor], currentProfile: floor, loadError: nil,
                                 root: root, defaults: defaults, sideEffectsEnabled: false, themeManager: ThemeManager(defaults: defaults))
        try manager.persistNew([floor])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func conversations() throws -> [Conversation] {
        try context.fetch(FetchDescriptor<Conversation>())
    }

    // MARK: mainsession

    func testEnsureCreatesOnceAndPinsAboveEverything() throws {
        let main = try XCTUnwrap(MainSession.ensure(profileId: "floor-a", profileManager: manager, context: context))
        XCTAssertEqual(main.title, "main session")
        XCTAssertTrue(MainSession.isMain(main))
        XCTAssertEqual(manager.profiles.first?.mainSessionId, main.id)
        XCTAssertEqual(MainSession.listTitle(main), "✦ main session")

        main.title = "mainsession"  // 11-17 前的老名字
        let again = try XCTUnwrap(MainSession.ensure(profileId: "floor-a", profileManager: manager, context: context))
        XCTAssertEqual(again.id, main.id, "第二次复用")
        XCTAssertEqual(again.title, "main session", "老名字改成带空格的")
        XCTAssertEqual(try conversations().count, 1)

        // 比真置顶的还靠前（列表按 pinnedAt 倒序）
        let pinned = Conversation(id: "p", title: "置顶的", createTime: .now, updateTime: .now, currentNodeId: "", provider: "api", profileId: "floor-a")
        pinned.pinnedAt = Date().addingTimeInterval(86400 * 3650)
        XCTAssertGreaterThan(try XCTUnwrap(main.pinnedAt), try XCTUnwrap(pinned.pinnedAt))
        XCTAssertFalse(MainSession.isMain(pinned))
    }

    func testTrashedMainSessionIsRecreated() throws {
        let main = try XCTUnwrap(MainSession.ensure(profileId: "floor-a", profileManager: manager, context: context))
        main.isTrashed = true
        let fresh = try XCTUnwrap(MainSession.ensure(profileId: "floor-a", profileManager: manager, context: context))
        XCTAssertNotEqual(fresh.id, main.id)
    }

    func testClearArchivesAndStartsFresh() throws {
        let main = try XCTUnwrap(MainSession.ensure(profileId: "floor-a", profileManager: manager, context: context))
        let day = Date(timeIntervalSince1970: 1_794_800_000)
        let fresh = try XCTUnwrap(MainSession.clear(main, profileManager: manager, context: context, now: day))
        XCTAssertNotEqual(fresh.id, main.id)
        XCTAssertTrue(MainSession.isMain(fresh))
        XCTAssertFalse(MainSession.isMain(main), "原来那条成了普通对话")
        XCTAssertNil(main.pinnedAt)
        XCTAssertTrue(main.title.hasPrefix("main session · 到 "), main.title)
        XCTAssertFalse(main.isTrashed, "存档，不删")
        XCTAssertEqual(manager.profiles.first?.mainSessionId, fresh.id)
        XCTAssertNil(MainSession.clear(main, profileManager: manager, context: context), "普通对话里 /clear 不认")
        XCTAssertTrue(MainSession.isClearCommand(" /CLEAR "))
        XCTAssertFalse(MainSession.isClearCommand("/clear 一下"))
    }

    func testOldProfileWithoutMainSessionDecodes() throws {
        let p = Profile(id: "x", name: "x", emoji: "", description: "", userName: "", assistantName: "")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        json.removeValue(forKey: "mainSessionId")
        XCTAssertNil(try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json)).mainSessionId)
    }

    // MARK: 别的窗口也知道（B）

    private func run(_ title: String, at: Date, summary: String?, delivered: String?, message: String? = "x", status: WakeRunStatus = .ok) -> WakeRun {
        var r = WakeRun(taskId: title, taskTitle: title, startedAt: at, endedAt: at, trigger: .scheduled, status: status, statusNote: nil)
        r.summary = summary
        r.message = message
        r.deliveredConversationId = delivered
        r.deliveredMessageId = delivered == nil ? nil : "n"
        return r
    }

    func testRecentLinesPickLast24HoursOkOnlyMaxThree() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 20))!
        let runs = [
            run("早报", at: now.addingTimeInterval(-3600 * 12), summary: "三件事：A、B、C", delivered: "main"),
            run("问考试", at: now.addingTimeInterval(-3600 * 13), summary: "她今天没提考试", delivered: nil, message: nil),
            run("坏了", at: now.addingTimeInterval(-3600 * 14), summary: nil, delivered: nil, status: .failed),
            run("老对话", at: now.addingTimeInterval(-3600 * 15), summary: "发回去了", delivered: "other"),
            run("第四个", at: now.addingTimeInterval(-3600 * 16), summary: "多出来的", delivered: "main"),
            run("太早", at: now.addingTimeInterval(-3600 * 30), summary: "昨天以前", delivered: "main"),
        ]
        let lines = WakeRecent.lines(runs, mainSessionId: "main", now: now, calendar: cal)
        XCTAssertEqual(lines.count, 4, lines.joined(separator: "\n"))
        XCTAssertTrue(lines[0].contains("main session"))
        XCTAssertEqual(lines[1], "- 今天 08:00「早报」：三件事：A、B、C")
        XCTAssertEqual(lines[2], "- 今天 07:00「问考试」：这次没发：她今天没提考试")
        XCTAssertEqual(lines[3], "- 今天 05:00「老对话」：发回去了（发在别的对话里）")
        XCTAssertTrue(WakeRecent.lines([], mainSessionId: nil, now: now).isEmpty, "没执行过就不带这段")
    }

    // MARK: 任务默认发 mainsession

    func testHeartbeatToolNotifyDefaultsToMainSession() {
        XCTAssertEqual(HeartbeatTaskTool.notify(nil, conversationId: "c"), .mainSession(push: true))
        XCTAssertEqual(HeartbeatTaskTool.notify("mainsession", conversationId: "c"), .mainSession(push: true))
        XCTAssertEqual(HeartbeatTaskTool.notify("conversation", conversationId: "c"), .conversation(id: "c", push: true))
        XCTAssertEqual(HeartbeatTaskTool.notify("heartbeat", conversationId: "c"), .heartbeatOnly)
    }

    func testOldTaskNotifyStillDecodes() throws {
        let old = WakeTask(title: "t", instruction: "i", schedule: .daily(hour: 8, minute: 0, weekdays: nil), createdBy: .user,
                           notify: .conversation(id: "c", push: false))
        let back = try JSONDecoder().decode(WakeTask.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(back.notify, .conversation(id: "c", push: false))
        XCTAssertNil(back.modelId)
        let main = WakeTask(title: "t", instruction: "i", schedule: .once(Date()), createdBy: .user, notify: .mainSession(push: true))
        XCTAssertEqual(try JSONDecoder().decode(WakeTask.self, from: JSONEncoder().encode(main)).notify, .mainSession(push: true))
    }
}
