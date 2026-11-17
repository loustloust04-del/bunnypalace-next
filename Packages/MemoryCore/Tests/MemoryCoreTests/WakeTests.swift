import XCTest
@testable import MemoryCore

/// plan-wake-heartbeat H1：下次时间、护栏、存取修剪、跑一次（脚本化假模型）
final class WakeClockTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testDailyNextToday_thenTomorrow() {
        let s = WakeSettings()
        let daily = WakeSchedule.daily(hour: 9, minute: 30, weekdays: nil)
        XCTAssertEqual(WakeClock.next(daily, after: at(2026, 11, 12, 8), timeZone: tz, settings: s), at(2026, 11, 12, 9, 30))
        XCTAssertEqual(WakeClock.next(daily, after: at(2026, 11, 12, 9, 30), timeZone: tz, settings: s), at(2026, 11, 13, 9, 30))
    }

    func testDailyWeekdays() {
        // 2026-11-12 是周四（weekday 5）；只要周一（2）→ 11-16
        let s = WakeSettings()
        let monday = WakeSchedule.daily(hour: 9, minute: 0, weekdays: [2])
        XCTAssertEqual(WakeClock.next(monday, after: at(2026, 11, 12, 10), timeZone: tz, settings: s), at(2026, 11, 16, 9))
    }

    func testQuietHoursMoveToEnd() {
        let s = WakeSettings(quietStart: 0, quietEnd: 8)
        let early = WakeSchedule.daily(hour: 6, minute: 0, weekdays: nil)
        XCTAssertEqual(WakeClock.next(early, after: at(2026, 11, 12, 1), timeZone: tz, settings: s), at(2026, 11, 12, 8))
        // 跨午夜的安静时段 23 → 7：23:30 挪到第二天 7 点
        let late = WakeSettings(quietStart: 23, quietEnd: 7)
        XCTAssertEqual(WakeClock.next(.once(at(2026, 11, 12, 23, 30)), after: at(2026, 11, 12, 20), timeZone: tz, settings: late),
                       at(2026, 11, 13, 7))
        XCTAssertFalse(WakeClock.inQuiet(at(2026, 11, 12, 12), calendar: cal, settings: WakeSettings(quietStart: 0, quietEnd: 0)))
    }

    func testOncePastIsNil() {
        XCTAssertNil(WakeClock.next(.once(at(2026, 11, 12, 9)), after: at(2026, 11, 12, 10), timeZone: tz, settings: WakeSettings()))
    }

    func testDueScheduledCatchUpMissed() {
        var task = WakeTask(title: "早报", instruction: "x", schedule: .daily(hour: 8, minute: 0, weekdays: nil),
                            createdBy: .user, notify: .heartbeatOnly, nextRunAt: at(2026, 11, 12, 8))
        XCTAssertEqual(WakeClock.due(task, now: at(2026, 11, 12, 7, 59)), .notYet)
        XCTAssertEqual(WakeClock.due(task, now: at(2026, 11, 12, 8, 1)), .run(.scheduled))
        XCTAssertEqual(WakeClock.due(task, now: at(2026, 11, 12, 13)), .run(.catchUp))
        XCTAssertEqual(WakeClock.due(task, now: at(2026, 11, 12, 21)), .missed)
        task.enabled = false
        XCTAssertEqual(WakeClock.due(task, now: at(2026, 11, 12, 8, 1)), .notYet)
    }

    func testGuard() {
        let now = at(2026, 11, 12, 9)
        let on = WakeSettings(enabled: true)
        XCTAssertEqual(WakeGuard.decide(now: now, .init(settings: WakeSettings(), personEnabled: true, runsToday: 0, lastUserMessageAt: nil, typing: false)),
                       .hold("总开关关着"))
        XCTAssertEqual(WakeGuard.decide(now: now, .init(settings: on, personEnabled: true, runsToday: 10, lastUserMessageAt: nil, typing: false)),
                       .hold("今天已经醒了 10 次，到上限了"))
        XCTAssertEqual(WakeGuard.decide(now: now, .init(settings: on, personEnabled: true, runsToday: 0, lastUserMessageAt: now.addingTimeInterval(-300), typing: false)),
                       .wait(until: now.addingTimeInterval(900)))
        XCTAssertEqual(WakeGuard.decide(now: now, .init(settings: on, personEnabled: true, runsToday: 0, lastUserMessageAt: now.addingTimeInterval(-3600), typing: false)), .go)
        // 她点的「现在跑一次」不管开关
        XCTAssertEqual(WakeGuard.decide(now: now, .init(settings: WakeSettings(), personEnabled: false, runsToday: 99, lastUserMessageAt: now, typing: true, manual: true)), .go)
    }
}

final class WakeStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testTasksRoundTripAndRunsPrune() throws {
        let store = WakeStore(memoryRoot: root)
        let task = WakeTask(title: "早报", instruction: "汇总", schedule: .daily(hour: 8, minute: 0, weekdays: [2, 3]),
                            createdBy: .ai(conversationId: "c1"), notify: .conversation(id: "c1", push: true),
                            createdAt: Date(timeIntervalSince1970: 1_794_500_000))
        try store.upsert(task)
        XCTAssertEqual(store.tasks(), [task])

        let now = Date()
        let fresh = WakeRun(taskId: task.id, taskTitle: task.title, startedAt: now, trigger: .manual, status: .ok)
        let old = WakeRun(taskId: task.id, taskTitle: task.title, startedAt: now.addingTimeInterval(-70 * 86400), trigger: .scheduled, status: .ok)
        try store.save(fresh)
        try store.save(old)
        _ = try store.saveShot(Data([1, 2, 3]), runId: old.id, index: 1)
        XCTAssertEqual(store.runs(taskId: task.id).map(\.id), [fresh.id, old.id])
        store.prune(now: now)
        XCTAssertEqual(store.runs().map(\.id), [fresh.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.shotURL(runId: old.id, name: "1.jpg").path))

        try store.deleteTask(task.id)
        XCTAssertTrue(store.tasks().isEmpty)
    }
}

final class WakeRunnerTests: XCTestCase {
    /// 假模型：先搜索、再读一页、留一句给下次、最后 finish
    func testRunRecordsStepsSourcesAndFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wake-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script: [AgentStep] = [
            AgentStep(calls: [AgentToolCall(id: "1", name: "search_web", arguments: #"{"query":"AI news"}"#)]),
            AgentStep(calls: [AgentToolCall(id: "2", name: "browse_url", arguments: #"{"url":"https://example.com/a"}"#)]),
            AgentStep(calls: [AgentToolCall(id: "3", name: WakeRunner.noteName, arguments: #"{"note":"今天报过 A"}"#),
                              AgentToolCall(id: "4", name: WakeRunner.finishName, arguments: #"{"summary":"早报做好了","message":"今天一件事：A"}"#)]),
        ]
        let counter = Counter()
        let caller = ClosureToolModelCaller { _, _, _ in script[await counter.next()] }
        let search = WakeTool(spec: AgentToolSpec(name: "search_web", description: "", schema: "{}"), label: "搜索",
                              describe: { _ in "搜索「AI news」" }) { _ in AgentToolOutput("1. A — https://example.com/a") }
        let browse = WakeTool(spec: AgentToolSpec(name: "browse_url", description: "", schema: "{}"), label: "读网页",
                              describe: { _ in "读 example.com/a" },
                              source: { _, _ in WakeSource(url: "https://example.com/a", title: "A") },
                              snapshot: { Data([0xFF, 0xD8]) }) { _ in AgentToolOutput("A 的正文") }
        let task = WakeTask(title: "早报", instruction: "汇总", schedule: .daily(hour: 8, minute: 0, weekdays: nil),
                            createdBy: .user, notify: .heartbeatOnly)
        let store = WakeStore(memoryRoot: root)
        let (run, note) = await WakeRunner.run(.init(task: task, trigger: .manual, system: "s", opening: "o",
                                                     tools: [search, browse], withheld: ["calendar_create"], caller: caller,
                                                     maxRounds: 20, store: store))
        XCTAssertEqual(run.status, .ok)
        XCTAssertEqual(run.summary, "早报做好了")
        XCTAssertEqual(run.message, "今天一件事：A")
        XCTAssertEqual(note, "今天报过 A")
        XCTAssertEqual(run.steps.map(\.action), ["搜索「AI news」", "读 example.com/a"])
        XCTAssertEqual(run.sources, [WakeSource(url: "https://example.com/a", title: "A")])
        XCTAssertEqual(run.tools.map(\.label), ["搜索", "读网页"])
        XCTAssertEqual(run.withheldTools, ["calendar_create"])
        XCTAssertEqual(run.rounds, 3)
        let shot = try XCTUnwrap(run.steps[1].shot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.shotURL(runId: run.id, name: shot).path))
        XCTAssertNil(run.steps[0].shot)
    }

    /// 不 finish 就到轮数上限 = 失败，原因写清
    func testNoFinishIsFailure() async {
        let caller = ClosureToolModelCaller { _, _, _ in AgentStep(calls: [AgentToolCall(id: UUID().uuidString, name: "search_web", arguments: "{}")]) }
        let search = WakeTool(spec: AgentToolSpec(name: "search_web", description: "", schema: "{}"), label: "搜索",
                              describe: { _ in "搜索" }) { _ in AgentToolOutput("没结果") }
        let task = WakeTask(title: "t", instruction: "x", schedule: .once(Date()), createdBy: .user, notify: .heartbeatOnly)
        let (run, _) = await WakeRunner.run(.init(task: task, trigger: .manual, system: "s", opening: "o", tools: [search],
                                                  caller: caller, maxRounds: 5, store: nil))
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.statusNote, "到轮数上限还没交结果")
        XCTAssertNil(run.summary)
    }
}

private actor Counter {
    private var i = 0
    func next() -> Int {
        defer { i += 1 }
        return i
    }
}
