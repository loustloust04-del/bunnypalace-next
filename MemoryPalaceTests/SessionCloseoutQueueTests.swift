import XCTest
@testable import 记忆花园

/// v4-1 §五：收尾 = 窗口总结 + 时间轴分开写、分开判；格式两次不合格不存、记健康状态、30 分钟冷却；收尾不再往 sessions/ 写收尾段
final class SessionCloseoutQueueTests: XCTestCase {

    let pid = "xctest-closeout-queue"
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in ["mem_master", "mem_content_summary", "mem_content_timeline", MemoryStartDay.key] {
            saved[k] = UserDefaults.standard.object(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_content_summary")
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        UserDefaults.standard.removeObject(forKey: MemoryStartDay.key)
    }

    override func tearDown() {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        let d = UserDefaults.standard
        for kind in ["extract", "dream", "summary", "context", "timeline"] {
            for field in ["ok", "err", "errmsg", "streak", "model"] { d.removeObject(forKey: "mem_health_\(kind)_\(field)_\(pid)") }
        }
        super.tearDown()
    }

    private var ctx: SessionCloseout.Context {
        SessionCloseout.Context(profile: Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克"),
                                model: ProviderModel(credentialId: "x", modelId: "m", name: "m"))
    }

    private func item() -> SessionCloseout.Candidate {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 10))!
        let msgs = (0..<6).map { SessionSegmentWriter.Message(id: "n\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "x",
                                                             date: base.addingTimeInterval(TimeInterval($0) * 60)) }
        return .init(conversationId: "conv-q-0001", title: "Q", messages: msgs)
    }

    private let goodWindow = "标题：一段\n【经过】接着聊\n【原话】粟粟：「嗯」"
    private let goodTimeline = "【话题】\n- 聊了一件事\n【待续】\n- 无"

    func testWindowAndTimelineWrittenSeparatelyNoCloseoutInSessions() async throws {
        var calls: [String] = []
        let closeout = SessionCloseout()
        let stop = await closeout.closeout(item(), ctx: ctx) { system, _ in
            let isTimeline = system.contains("「时间轴」")
            calls.append(isTimeline ? "timeline" : "window")
            return isTimeline ? self.goodTimeline : self.goodWindow
        }
        XCTAssertFalse(stop)
        XCTAssertEqual(calls, ["window", "timeline"], "两次调用、两种格式")
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-q-0001", in: root)?.closedThrough, "n5")
        XCTAssertEqual(TimelineStore.entry(day: "2026-10-11", conversationId: "conv-q-0001", in: TimelineStore.dir(root: root))?.topics, ["聊了一件事"])
        XCTAssertNil(SessionSummaryStore.load(conversationId: "conv-q-0001", profileId: pid), "收尾不再往 sessions/ 写收尾段")
        XCTAssertNotNil(MemoryHealthStore.status(.summary, profileId: pid).lastOK)
        XCTAssertNotNil(MemoryHealthStore.status(.timeline, profileId: pid).lastOK)
    }

    func testFormatFailureDoesNotBlockOtherAndCoolsDown() async throws {
        var calls: [String] = []
        let closeout = SessionCloseout()
        let caller: SessionSegmentWriter.Caller = { system, _ in
            let isTimeline = system.contains("「时间轴」")
            calls.append(isTimeline ? "timeline" : "window")
            return isTimeline ? "（想了很久）……想到了" : self.goodWindow
        }
        _ = await closeout.closeout(item(), ctx: ctx, caller: caller)
        XCTAssertEqual(calls, ["window", "timeline", "timeline"], "时间轴重写一次")
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        XCTAssertNotNil(WindowSummaryStore.load(conversationId: "conv-q-0001", in: root), "一个没过，不拦另一个")
        XCTAssertTrue(TimelineStore.months(profileId: pid).isEmpty, "不合格不存")
        XCTAssertEqual(MemoryHealthStore.status(.timeline, profileId: pid).failStreak, 1)
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), nil, "一次失败还不亮")

        calls = []
        _ = await closeout.closeout(item(), ctx: ctx, caller: caller)
        XCTAssertEqual(calls, [], "窗口总结已经写到最后一条；时间轴 30 分钟内不再试")
    }

    /// astra #8：等模型时来了新消息——覆盖判断用盖到的那条消息的时间（不是写文件那一刻），下次巡检照样挑它
    func testNewMessageDuringModelCallIsPickedUpNextSweep() async throws {
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        let it = item()
        let lastCovered = try XCTUnwrap(it.messages.last?.date)
        var newMessageAt: Date?
        _ = await SessionCloseout().closeout(it, ctx: ctx) { _, _ in
            newMessageAt = Date()   // 模型还没回，她又发了一条：对话 updateTime 挪到现在
            return self.goodWindow
        }
        let w = try XCTUnwrap(WindowSummaryStore.load(conversationId: "conv-q-0001", profileId: pid))
        let covered = SessionCloseout.coveredUntil(window: w, latest: nil, summaryOn: true, timelineOn: false)
        XCTAssertEqual(covered, lastCovered, "覆盖到快照里最后一条消息的时间")
        let update = try XCTUnwrap(newMessageAt)
        XCTAssertNotEqual(SessionCloseout.queueState(updateTime: update, coveredUntil: covered, lastMessageDate: update,
                                                     hasPending: true, now: update.addingTimeInterval(3600), force: false), .none,
                          "新消息没被当成已覆盖")
    }

    func testHealthWarningLines() {
        for _ in 0..<3 { MemoryHealthStore.recordError(.context, profileId: pid, message: "x", modelName: "m") }
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近写不成上下文摘要")
        MemoryHealthStore.recordOK(.context, profileId: pid, modelName: "m")
        for _ in 0..<3 { MemoryHealthStore.recordError(.timeline, profileId: pid, message: "x", modelName: "m") }
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), "最近写不成时间轴")
    }

    func testSwitchesQ3() {
        UserDefaults.standard.set(false, forKey: "mem_content_summary")
        XCTAssertTrue(SessionCloseout.closeoutEnabled, "时间轴开着就收尾")
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        XCTAssertFalse(SessionCloseout.closeoutEnabled, "两个都关就不收尾")
        XCTAssertEqual(WindowSummaryListLayout.queueNote(masterOn: true, summaryOn: false, timelineOn: false, queueEmpty: false),
                       "「上下文摘要和窗口总结」「时间轴」都关着，窗口收尾不跑")
        XCTAssertNil(WindowSummaryListLayout.queueNote(masterOn: true, summaryOn: false, timelineOn: true, queueEmpty: false))
    }
}
