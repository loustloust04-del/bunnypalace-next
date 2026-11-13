import XCTest
@testable import 记忆花园

/// A3 默认 24 小时，显式设置不覆盖；新建对话提前写仍按 12 小时。
final class WriterTriggerTests: XCTestCase {

    private let t0 = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!
    private var suite = ""
    private var d: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "xctest-writer-trigger-\(UUID().uuidString)"
        d = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func trigger(_ mode: MemoryTriggerMode, idleHours: Double = 12, rounds: Int = 30, onNew: Bool = true) -> SessionCloseout.Trigger {
        .init(mode: mode, idle: idleHours * 3600, rounds: rounds, onNew: onNew)
    }

    func testDefaults() {
        XCTAssertEqual(SessionCloseout.idleInterval, 24 * 3600)
        XCTAssertEqual(SessionCloseout.recentInterval, 12 * 3600, "Q-b：新建对话先写掉 12 小时内聊过的")
        XCTAssertEqual(MemoryTriggers.mode(.a2, defaults: d), .rounds, "A2 默认每 N 回合（= 今天）")
        XCTAssertEqual(MemoryTriggers.rounds(.a2, defaults: d), 5)
        XCTAssertEqual(MemoryTriggers.mode(.a3, defaults: d), .idle)
        XCTAssertEqual(MemoryTriggers.idleMinutes(.a3, defaults: d), 1440)
        XCTAssertEqual(MemoryTriggers.idleMinutes(.a4, defaults: d), 720)
        XCTAssertTrue(MemoryTriggers.closesOnNewConversation(.a4, defaults: d))
        d.set(7, forKey: "ctx_compress_interval")
        XCTAssertEqual(MemoryTriggers.rounds(.a2, defaults: d), 7, "A2 的回合数就是 Prompt 页那个键")
        let defaultTrigger = SessionCloseout.Trigger(mode: .idle, idle: MemoryTriggers.idle(.a3, defaults: d), rounds: 30, onNew: true)
        XCTAssertEqual(SessionCloseout.writerState(defaultTrigger, pending: 6, updateTime: t0, coveredUntil: nil,
            lastMessageDate: t0, now: t0.addingTimeInterval(13 * 3600), force: false), .waiting(until: t0.addingTimeInterval(24 * 3600)))
        d.set(720, forKey: MemoryTriggers.idleKey(.a3))
        XCTAssertEqual(MemoryTriggers.idleMinutes(.a3, defaults: d), 720, "显式设过的12h不被新默认覆盖")
    }

    func testIdleText() {
        XCTAssertEqual(MemoryTriggers.idleText(720), "12 小时")
        XCTAssertEqual(MemoryTriggers.idleText(90), "1 小时 30 分")
        XCTAssertEqual(MemoryTriggers.idleText(45), "45 分钟")
    }

    func testIdleWaitsTwelveHours() {
        let last = t0
        let s1 = SessionCloseout.writerState(trigger(.idle), pending: 10, updateTime: last, coveredUntil: nil, lastMessageDate: last,
                                             now: last.addingTimeInterval(3600), force: false)
        XCTAssertEqual(s1, .waiting(until: last.addingTimeInterval(12 * 3600)), "停了 1 小时还不写")
        let s2 = SessionCloseout.writerState(trigger(.idle), pending: 10, updateTime: last, coveredUntil: nil, lastMessageDate: last,
                                             now: last.addingTimeInterval(12 * 3600 + 1), force: false)
        XCTAssertEqual(s2, .due)
    }

    func testRoundsAndManual() {
        let last = t0
        XCTAssertEqual(SessionCloseout.writerState(trigger(.rounds, rounds: 5), pending: 9, updateTime: last, coveredUntil: nil,
                                                   lastMessageDate: last, now: last, force: false), .none, "不够 5 回合（10 条）")
        XCTAssertEqual(SessionCloseout.writerState(trigger(.rounds, rounds: 5), pending: 10, updateTime: last, coveredUntil: nil,
                                                   lastMessageDate: last, now: last, force: false), .due, "够了不等静默")
        XCTAssertEqual(SessionCloseout.writerState(trigger(.manual), pending: 500, updateTime: last, coveredUntil: nil,
                                                   lastMessageDate: last, now: last.addingTimeInterval(86400 * 3), force: true), .none,
                       "只手动：从不自动写，新建对话也不写")
        XCTAssertEqual(SessionCloseout.writerState(trigger(.idle), pending: 0, updateTime: last, coveredUntil: nil,
                                                   lastMessageDate: last, now: last.addingTimeInterval(86400), force: false), .none)
    }

    func testNewConversationFollowsOnNew() {
        let last = t0
        let now = last.addingTimeInterval(3 * 3600)
        XCTAssertEqual(SessionCloseout.writerState(trigger(.idle), pending: 4, updateTime: last, coveredUntil: nil,
                                                   lastMessageDate: last, now: now, force: true), .due, "3 小时前聊过：新建对话先写掉")
        XCTAssertEqual(SessionCloseout.writerState(trigger(.idle, onNew: false), pending: 4, updateTime: last, coveredUntil: nil,
                                                   lastMessageDate: last, now: now, force: true), .none, "关了「新建对话时先写掉」")
        XCTAssertEqual(SessionCloseout.writerState(trigger(.rounds, rounds: 30), pending: 4, updateTime: last, coveredUntil: nil,
                                                   lastMessageDate: last, now: now, force: true), .due)
    }

    func testCombinedOnlyDueWriters() {
        let until = t0.addingTimeInterval(100)
        let r = SessionCloseout.combined([.window: .due, .timeline: .waiting(until: until)])
        XCTAssertEqual(r.state, .due)
        XCTAssertEqual(r.due, [.window], "只写到点的那个")
        let w = SessionCloseout.combined([.window: .waiting(until: until.addingTimeInterval(50)), .timeline: .waiting(until: until)])
        XCTAssertEqual(w.state, .waiting(until: until))
        XCTAssertEqual(SessionCloseout.combined([.window: .none]).state, .none)
    }

    func testWindowPendingCount() {
        let ids = (0..<10).map { "n\($0)" }
        XCTAssertEqual(SessionCloseout.windowPendingCount(pathIds: ids, closedThrough: "n6", notBefore: 0), 3)
        XCTAssertEqual(SessionCloseout.windowPendingCount(pathIds: ids, closedThrough: nil, notBefore: 4), 6)
        XCTAssertEqual(SessionCloseout.windowPendingCount(pathIds: ids, closedThrough: "gone", notBefore: 0), 10, "切过分支：从头算")
    }

    func testWriteNowSummary() {
        var r = SessionCloseout.CloseoutResult()
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: r), "📝 没有要写的（都写到最新了）")
        r.tail = true
        r.timeline = 1
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: r), "📝 写好了：A2 1 段 · A4 1 天")
        r.window = true
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 2, result: r), "📝 写好了：A2 3 段 · A3 1 段 · A4 1 天")
    }

    /// astra #10：忙 / 失败 / 预算闸拦下 / 确实没新的，各说各的；CC 窗口的 A2 段数算进 A2（astra #6）
    func testWriteNowSummaryDistinguishesOutcomes() {
        var r = SessionCloseout.CloseoutResult()
        r.busy = true
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: r), "📝 后台正在写这个窗口，稍后再点")
        r = .init()
        r.failed = true
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: r), "📝 没写成，看记忆日志")
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, a2Failed: true, result: .init()), "📝 没写成，看记忆日志")
        r = .init()
        r.skipped = true
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: r), "📝 没写成：被预算闸拦下，或模型没回内容（手动不看写入预算）")
        r.context = 2
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: r), "📝 写好了：A2 2 段（有一项没写成）")
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: .init()), "📝 没有要写的（都写到最新了）")
    }
}
