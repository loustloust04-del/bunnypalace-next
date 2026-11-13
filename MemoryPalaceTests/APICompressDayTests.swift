import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

final class APICompressDayTests: XCTestCase {
    private let pid = "xctest-api-day"
    private let cid = "apiday01-window"
    private var saved: [(String, Any?)] = []
    private let good = "标题：定云桥城路线\n【经过】岚舟选了北门。\n【原话】岚舟：「北门。」\n【关键词】云桥城，北门\n【待续】无"

    override func setUp() {
        super.setUp()
        let keys = ["mem_master", "mem_content_summary", "mem_write_a3", MemoryStartDay.key, MemoryTriggers.modeKey(.a2)]
        saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_content_summary")
        UserDefaults.standard.set(false, forKey: "mem_write_a3")
        UserDefaults.standard.removeObject(forKey: MemoryStartDay.key)
        UserDefaults.standard.removeObject(forKey: MemoryTriggers.modeKey(.a2))
    }

    override func tearDown() {
        MemoryWriteLog.flush()
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func messages(_ dates: [Date]) -> [SessionSegmentWriter.Message] {
        dates.enumerated().map { .init(id: "n\($0.offset)", role: $0.offset % 2 == 0 ? "user" : "assistant", content: "云桥城第\($0.offset)条", date: $0.element) }
    }

    private func path(_ n: Int, start: Date) -> [SessionSegmentWriter.Message] {
        messages((0..<n).map { start.addingTimeInterval(Double($0 * 60)) })
    }

    private var empty: SessionSummary {
        SessionSummary(conversationId: cid, title: "云桥城", compressedCount: 0, segments: [], updatedAt: .distantPast)
    }

    private var ctx: SessionCloseout.Context {
        SessionCloseout.Context(profile: Profile(id: pid, name: "星砚", emoji: "T", description: "", userName: "岚舟", assistantName: "星砚"),
                               model: ProviderModel(credentialId: "fake", modelId: "fake", name: "fake"))
    }

    func testFiftyNineSixtyAndSixtyOneKeepChunkBoundaries() {
        for n in [59, 60, 61] {
            let m = path(n, start: date(4, 10))
            let plan = SessionCloseout.compressPlan(empty, pathIds: m.map(\.id), dates: m.map(\.date), oldCount: n)
            let expected = n <= 60 ? [0..<n] : [0..<60, 60..<61]
            XCTAssertEqual(SessionCloseout.contextParts(plan!.ranges, dates: m.map(\.date)), expected)
            XCTAssertEqual(SessionCloseout.apiDayRanges(empty, pathIds: m.map(\.id), dates: m.map(\.date), notBefore: 0, now: date(4, 18)), [])
            XCTAssertEqual(SessionCloseout.apiDayRanges(empty, pathIds: m.map(\.id), dates: m.map(\.date), notBefore: 0, now: date(5, 5)), expected)
        }
    }

    func testFirstDailyWriteCapsYesterdayAtLast150Messages() {
        let m = path(300, start: date(4, 10))
        XCTAssertEqual(SessionCloseout.apiDayRanges(empty, pathIds: m.map(\.id), dates: m.map(\.date), notBefore: 0, now: date(5, 9)),
                       [150..<210, 210..<270, 270..<300])
    }

    func testDailyWriteDoesNotResurrectHistoryBeforeFirstSegment() {
        let m = path(310, start: date(4, 10))
        var s = empty
        s.segments = [SessionSegment(kind: .rolling, title: "北门", start: m[150].date!, end: m[299].date!,
                                     from: 150, to: 300, lastNodeId: m[299].id, story: "北门", quotes: "", pending: "", format: 2)]
        XCTAssertEqual(SessionCloseout.apiDayRanges(s, pathIds: m.map(\.id), dates: m.map(\.date), notBefore: 0, now: date(5, 9)), [300..<310])
    }

    func testTailRetainsFirstSavedPartWhenSecondCallFails() async throws {
        struct Interrupted: Error {}
        let m = messages([date(5, 4, 57), date(5, 4, 58), date(5, 4, 59), date(5, 5), date(5, 5, 1), date(5, 5, 2)])
        var calls = 0
        do {
            _ = try await SessionCloseout.writeTail(context: empty, messages: m, notBefore: 0, persona: "", speakers: ctx.speakers,
                                                    profileId: pid, title: "云桥城", save: { try SessionCloseout.saveA2($0, profileId: self.pid) }) { _, _ in
                calls += 1
                if calls == 2 { throw Interrupted() }
                return self.good
            }
            XCTFail("第二段应中断")
        } catch is Interrupted {}
        let saved = try XCTUnwrap(SessionSummaryStore.load(conversationId: cid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertEqual(saved.segments.map { $0.from..<$0.to }, [0..<3])
        XCTAssertEqual(saved.segments.map(\.kind), [.rolling])
        XCTAssertEqual(saved.segments.map(\.isTail), [false])
        let resumed = try await SessionCloseout.writeTail(context: saved, messages: m, notBefore: 0, persona: "", speakers: ctx.speakers,
                                                         save: { try SessionCloseout.saveA2($0, profileId: self.pid) }) { _, _ in self.good }
        XCTAssertEqual(resumed?.segments.map { $0.from..<$0.to }, [0..<3, 3..<6])
    }

    func testCrossingFiveSplitsFormalCompressionAndTail() async throws {
        let m = messages([date(5, 4, 57), date(5, 4, 58), date(5, 4, 59), date(5, 5), date(5, 5, 1), date(5, 5, 2)])
        let anchor = try await SessionCloseout().compress(messages: m, oldCount: 6, conversationId: cid, title: "云桥城", ctx: ctx) { _, _ in self.good }
        XCTAssertEqual(anchor, 6)
        let written = try XCTUnwrap(SessionSummaryStore.load(conversationId: cid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertEqual(written.segments.map { $0.from..<$0.to }, [0..<3, 3..<6])
        XCTAssertEqual(written.segments.map(\.kind), [.rolling, .rolling])
        XCTAssertTrue(written.segments.allSatisfy { MemoryDay.key($0.start) == MemoryDay.key($0.end) })
        let tail = try await SessionCloseout.writeTail(context: empty, messages: m, notBefore: 0, persona: "", speakers: ctx.speakers, save: { _ in }) { _, _ in self.good }
        XCTAssertEqual(tail?.segments.map { $0.from..<$0.to }, [0..<3, 3..<6])
        XCTAssertEqual(tail?.segments.map(\.kind), [.rolling, .closeout])
        XCTAssertEqual(tail?.segments.map(\.isTail), [false, true])
    }

    func testDayRangesRespectBoundaryStartWatermarkAndShortWindow() {
        let m = path(10, start: date(5, 1))
        func ranges(_ s: SessionSummary = empty, notBefore: Int = 0, now: Date) -> [Range<Int>] {
            SessionCloseout.apiDayRanges(s, pathIds: m.map(\.id), dates: m.map(\.date), notBefore: notBefore, now: now)
        }
        XCTAssertEqual(ranges(now: date(5, 4, 59)), [])
        XCTAssertEqual(ranges(now: date(5, 5)), [0..<10])
        XCTAssertEqual(ranges(notBefore: 4, now: date(5, 9)), [4..<10])
        XCTAssertEqual(ranges(notBefore: 10, now: date(5, 9)), [])
        let short = Array(m.prefix(5))
        XCTAssertEqual(SessionCloseout.apiDayRanges(empty, pathIds: short.map(\.id), dates: short.map(\.date), notBefore: 0, now: date(5, 9)), [])
        let done = SessionSegment(kind: .rolling, title: "北门", start: m[0].date!, end: m[9].date!, from: 0, to: 10, lastNodeId: "n9", story: "北门", quotes: "", pending: "", format: 2)
        var s = empty
        s.segments = [done]
        XCTAssertEqual(ranges(s, now: date(5, 9)), [])
    }

    @MainActor
    private func container(_ m: [SessionSegmentWriter.Message], memoryEnabled: Bool = true) throws -> ModelContainer {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for (i, message) in m.enumerated() {
            context.insert(MessageNode(id: message.id, role: message.role, content: message.content, contentType: "text", createTime: message.date!,
                parentId: i == 0 ? nil : m[i - 1].id, childrenIds: i + 1 < m.count ? [m[i + 1].id] : [], conversationId: cid, profileId: pid))
        }
        let conv = Conversation(id: cid, title: "云桥城", createTime: m.first!.date!, updateTime: m.last!.date!, currentNodeId: m.last!.id, profileId: pid)
        conv.memoryEnabled = memoryEnabled
        context.insert(conv)
        try context.save()
        return container
    }

    @MainActor
    func testDailyExecutionReentryAndOverlapDoNotAdvanceSlidingAnchor() async throws {
        let m = path(10, start: date(5, 1))
        let container = try container(m)
        let closeout = SessionCloseout()
        let pm = ProviderManager()
        var calls = 0
        let caller: SessionSegmentWriter.Caller = { _, _ in calls += 1; return self.good }
        let first = await closeout.compressAPIDay(conversationId: cid, ctx: ctx, container: container, providerManager: pm, now: date(5, 9), caller: caller)
        XCTAssertEqual(first, .wrote)
        let second = await closeout.compressAPIDay(conversationId: cid, ctx: ctx, container: container, providerManager: pm, now: date(5, 10), caller: caller)
        XCTAssertEqual(second, .nothingToWrite)
        XCTAssertEqual(calls, 1)
        let s = try XCTUnwrap(SessionSummaryStore.load(conversationId: cid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertEqual(s.compressedCount, 0)
        XCTAssertEqual(s.segments.map(\.kind), [.rolling])
        XCTAssertEqual(SessionSummaryStore.injectableSegments(s.segments, windowIds: Set(m.map(\.id)), windowStart: 0), [])
        var withoutId = s.segments[0]
        withoutId.lastNodeId = nil
        XCTAssertEqual(SessionSummaryStore.injectableSegments([withoutId], windowIds: [], windowStart: 0), [])
        XCTAssertEqual(SessionSummaryStore.injectableSegments(s.segments, windowIds: [], windowStart: 10), s.segments)
        let anchor = try await closeout.compress(messages: m, oldCount: 6, conversationId: cid, title: "云桥城", ctx: ctx, caller: caller)
        XCTAssertEqual(anchor, 6, "真正超窗时才推进锚点，日切覆盖处不重写")
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testSweepActuallyFindsAPIWindowAndSkipsShortOrDisabled() async throws {
        let yesterday = MemoryDay.boundary(of: MemoryDay.dayStart(Date())).addingTimeInterval(-3600)
        let m = path(10, start: yesterday)
        let pm = ProviderManager()
        let closeout = SessionCloseout()
        let container = try container(m)
        let context = ModelContext(container)
        let conv = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        conv.ccBridgeSessionName = "stale-cc-session"
        try context.save()
        var calls = 0
        await closeout.sweep(ctx: ctx, container: container, providerManager: pm, callers: { _ in { _, _ in calls += 1; return self.good } })
        XCTAssertEqual(SessionSummaryStore.load(conversationId: cid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.map(\.lastNodeId), ["n9"])
        XCTAssertEqual(calls, 1)
        await closeout.sweep(ctx: ctx, container: container, providerManager: pm, callers: { _ in { _, _ in calls += 1; return self.good } })
        XCTAssertEqual(calls, 1)
        let short = await SessionCloseout().compressAPIDay(conversationId: cid, ctx: ctx, container: try self.container(Array(m.prefix(5))), providerManager: pm, now: date(5, 9), caller: { _, _ in XCTFail("短窗口不写"); return nil })
        XCTAssertEqual(short, .nothingToWrite)
        let disabled = await SessionCloseout().compressAPIDay(conversationId: cid, ctx: ctx, container: try self.container(m, memoryEnabled: false), providerManager: pm, now: date(5, 9), caller: { _, _ in XCTFail("关闭参与不写"); return nil })
        XCTAssertEqual(disabled, .nothingToWrite)
    }

    @MainActor
    func testSettledAPISweepDoesNotClaimOrFetchPathAfterMoreRepliesToday() async throws {
        let yesterday = MemoryDay.boundary(of: MemoryDay.dayStart(Date())).addingTimeInterval(-3600)
        let m = path(10, start: yesterday)
        let container = try container(m)
        let closeout = SessionCloseout()
        let pm = ProviderManager()
        var calls = 0
        let callers: (SessionCloseout.Writer) -> SessionSegmentWriter.Caller = { _ in { _, _ in calls += 1; return self.good } }
        await closeout.sweep(ctx: ctx, container: container, providerManager: pm, callers: callers)
        let first = await closeout.dailyWorkCounts
        XCTAssertEqual(first.claims, 1)
        XCTAssertEqual(first.pathFetches, 1)
        let context = ModelContext(container)
        let conv = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        var previous = m.last!.id
        for round in 0..<3 {
            let nodes = try context.fetch(FetchDescriptor<MessageNode>())
            for offset in 0..<2 {
                let id = "today-\(round)-\(offset)"
                if let parent = nodes.first(where: { $0.id == previous }) { parent.childrenIds = [id] }
                context.insert(MessageNode(id: id, role: offset == 0 ? "user" : "assistant", content: "今天接着聊",
                    contentType: "text", createTime: Date().addingTimeInterval(Double(round * 2 + offset)),
                    parentId: previous, childrenIds: offset == 0 ? ["today-\(round)-1"] : [], conversationId: cid, profileId: pid))
                previous = id
            }
            conv.currentNodeId = previous
            conv.updateTime = Date().addingTimeInterval(Double(round + 1))
            try context.save()
            await closeout.sweep(ctx: ctx, container: container, providerManager: pm, callers: callers)
        }
        let after = await closeout.dailyWorkCounts
        XCTAssertEqual(after.claims, first.claims)
        XCTAssertEqual(after.pathFetches, first.pathFetches)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(SessionSummaryStore.load(conversationId: cid, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.map(\.lastNodeId), ["n9"])
    }
}
