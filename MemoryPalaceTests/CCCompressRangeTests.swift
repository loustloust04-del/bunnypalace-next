import XCTest
import SwiftData
@testable import 记忆花园

/// v4-1 §四：CC 楼层的上下文摘要触发——水位线之后先按天切再按 60 条切；满 60 写、跨过 05:00 写、今天没满的尾巴留着
final class CCCompressRangeTests: XCTestCase {

    private func date(_ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: mi))!
    }

    /// n 条消息，从 start 起每分钟一条
    private func path(_ n: Int, from start: Date) -> (ids: [String], dates: [Date?]) {
        ((0..<n).map { "n\($0)" }, (0..<n).map { start.addingTimeInterval(TimeInterval($0) * 60) })
    }

    private let empty = SessionSummary(conversationId: "c", title: "", compressedCount: 0, segments: [], updatedAt: .distantPast)

    func testFiftyNineTodayWaitsSixtyWrites() {
        let now = date(11, 18)
        let p59 = path(59, from: date(11, 10))
        XCTAssertEqual(SessionCloseout.ccCompressRanges(empty, pathIds: p59.ids, dates: p59.dates, notBefore: 0, now: now), [], "59 条不写")
        let p60 = path(60, from: date(11, 10))
        XCTAssertEqual(SessionCloseout.ccCompressRanges(empty, pathIds: p60.ids, dates: p60.dates, notBefore: 0, now: now), [0..<60], "满 60 写")
        let p130 = path(130, from: date(11, 10))
        XCTAssertEqual(SessionCloseout.ccCompressRanges(empty, pathIds: p130.ids, dates: p130.dates, notBefore: 0, now: now), [0..<60, 60..<120],
                       "今天没满 60 的尾巴留着")
    }

    func testCrossingFiveOClockWritesYesterday() {
        // 10-10 22:00 起 30 条（昨天），10-11 09:00 起 20 条（今天）
        let y = path(30, from: date(10, 22)), t = path(20, from: date(11, 9))
        let ids = y.ids + t.ids.map { "t" + $0 }, dates = y.dates + t.dates
        XCTAssertEqual(SessionCloseout.ccCompressRanges(empty, pathIds: ids, dates: dates, notBefore: 0, now: date(11, 12)), [0..<30],
                       "跨天只写昨天那截")
    }

    func testPersonAwayPastFiveStillWrites() {
        // 凌晨聊完（10-11 01:00 起 10 条，归 10-10），早上 09:00 回来还没新消息：那截照样写
        let p = path(10, from: date(11, 1))
        XCTAssertEqual(SessionCloseout.ccCompressRanges(empty, pathIds: p.ids, dates: p.dates, notBefore: 0, now: date(11, 4, 59)), [], "05:00 前还算今天")
        XCTAssertEqual(SessionCloseout.ccCompressRanges(empty, pathIds: p.ids, dates: p.dates, notBefore: 0, now: date(11, 9)), [0..<10])
    }

    func testResumesAfterWatermarkAndRespectsStartDay() {
        let p = path(90, from: date(10, 10))
        let seg = SessionSegment(kind: .rolling, title: "压缩段", start: date(10, 10), end: date(10, 10, 30), from: 0, to: 30,
                                 lastNodeId: "n29", story: "", quotes: "", pending: "")
        let s = SessionSummary(conversationId: "c", title: "", compressedCount: 0, segments: [seg], updatedAt: .distantPast)
        XCTAssertEqual(SessionCloseout.ccCompressRanges(s, pathIds: p.ids, dates: p.dates, notBefore: 0, now: date(11, 9)), [30..<90],
                       "从水位线（最后一段）接着写，昨天的整截写，按 60 切")
        XCTAssertEqual(SessionCloseout.ccCompressRanges(empty, pathIds: p.ids, dates: p.dates, notBefore: 80, now: date(11, 9)), [80..<90],
                       "不早于记忆起点")
    }

    /// 防重入：同一个窗口同时进来两次只跑一遍，第二次等第一次写完再补
    func testSameWindowTwiceRunsOnce() async throws {
        let msgs = (0..<10).map { SessionSegmentWriter.Message(id: "n\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "x", date: date(11, 10, $0)) }
        let pid = "xctest-cc-reentry"
        defer { try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()) }
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克")
        let ctx = SessionCloseout.Context(profile: profile, model: ProviderModel(credentialId: "x", modelId: "m", name: "m"))
        let gate = AsyncGate()
        var calls = 0
        let caller: SessionSegmentWriter.Caller = { _, _ in
            calls += 1
            await gate.wait()
            return "标题：一段\n【经过】接着聊\n【原话】粟粟：「嗯」"
        }
        let closeout = SessionCloseout()
        async let first = closeout.compress(messages: msgs, oldCount: 6, conversationId: "conv-re", title: "t", ctx: ctx, caller: caller)
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = try await closeout.compress(messages: msgs, oldCount: 6, conversationId: "conv-re", title: "t", ctx: ctx, caller: caller)
        XCTAssertNil(second, "占不到：这次不跑")
        await gate.open()
        let r = try await first
        XCTAssertEqual(r, 6)
        XCTAssertEqual(calls, 1, "同时进来两次只跑了一遍")
        // 补跑那次看到的是写完的状态：锚点已经到了，不再调模型
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(SessionSummaryStore.load(conversationId: "conv-re", profileId: pid)?.segments.count, 1)
    }
}

/// astra #9：compressCC 返回明确结果——失败 / 冷却不能被巡检当成「今天查过了」
final class CCCompressResultTests: XCTestCase {

    let pid = "xctest-cc-result"
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in ["mem_master", "mem_content_summary", MemoryStartDay.key] { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_content_summary")
        UserDefaults.standard.removeObject(forKey: MemoryStartDay.key)
    }

    override func tearDown() {
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        let d = UserDefaults.standard
        for field in ["ok", "err", "errmsg", "streak", "model"] { d.removeObject(forKey: "mem_health_context_\(field)_\(pid)") }
        super.tearDown()
    }

    /// 一个 CC 窗口：60 条，最后一条 assistant 带 ccMessageId
    private func container(cc: Bool = true) throws -> ModelContainer {
        let c = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(c)
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9))!
        for i in 0..<60 {
            let node = MessageNode(id: "cc-n\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "第\(i)条", contentType: "text",
                                   createTime: t.addingTimeInterval(TimeInterval(i * 60)), parentId: i == 0 ? nil : "cc-n\(i - 1)",
                                   childrenIds: i + 1 < 60 ? ["cc-n\(i + 1)"] : [], conversationId: "conv-cc-0001", profileId: pid)
            if cc && i % 2 == 1 { node.ccMessageId = "m\(i)" }
            context.insert(node)
        }
        let conv = Conversation(id: "conv-cc-0001", title: "CC", createTime: t, updateTime: t.addingTimeInterval(3600),
                                currentNodeId: "cc-n59", profileId: pid)
        conv.ccBridgeSessionName = "mp-cc-test"
        context.insert(conv)
        try context.save()
        return c
    }

    private var ctx: SessionCloseout.Context {
        SessionCloseout.Context(profile: Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克"),
                                model: ProviderModel(credentialId: "x", modelId: "m", name: "m"))
    }

    @MainActor
    func testResults() async throws {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
        let closeout = SessionCloseout()
        let pm = ProviderManager()
        let notCC = await closeout.compressCC(conversationId: "conv-cc-0001", ctx: ctx, container: try container(cc: false),
                                              providerManager: pm, now: now, caller: { _, _ in XCTFail("不是 CC 窗口不该调模型"); return nil })
        XCTAssertEqual(notCC, .nothingToWrite)

        let c = try container()
        var calls = 0
        let bad: SessionSegmentWriter.Caller = { _, _ in calls += 1; return "（想了很久）……想到了" }
        let failed = await closeout.compressCC(conversationId: "conv-cc-0001", ctx: ctx, container: c, providerManager: pm, now: now, caller: bad)
        guard case .retry(let at) = failed, let at else { return XCTFail("格式失败应该给重试时间：\(failed)") }
        XCTAssertFalse(failed.settled, "失败不能记成「今天查过了」")
        XCTAssertGreaterThan(at, Date().addingTimeInterval(25 * 60))
        XCTAssertEqual(calls, 2)
        let cooling = await closeout.compressCC(conversationId: "conv-cc-0001", ctx: ctx, container: c, providerManager: pm, now: now, caller: bad)
        XCTAssertEqual(cooling, .retry(at: at), "冷却中：不调模型，告诉巡检什么时候再查")
        XCTAssertEqual(calls, 2)

        let good = await SessionCloseout().compressCC(conversationId: "conv-cc-0001", ctx: ctx, container: c, providerManager: pm, now: now,
                                                      caller: { _, _ in "标题：一段\n【经过】接着聊\n【原话】粟粟：「嗯」" })
        XCTAssertEqual(good, .wrote)
        XCTAssertTrue(good.settled)
        let again = await SessionCloseout().compressCC(conversationId: "conv-cc-0001", ctx: ctx, container: c, providerManager: pm, now: now,
                                                       caller: { _, _ in XCTFail("已经写到头了"); return nil })
        XCTAssertEqual(again, .nothingToWrite)
    }
}

/// 测试用：一扇门，开了才放行
actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
