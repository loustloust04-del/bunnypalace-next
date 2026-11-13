import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// c2c3-v2 第 7 段：A4 一天一条跨窗口——只读已落盘的 A2 段，按段内消息时间列到碰到的每一个记忆日；四时段；
/// 同窗口连着的段合一项；没压缩的那截 / 短窗口列「N 条，没压缩」；主调只看标题、不带人设；显示和注入同一份字；
/// 老条目备份后按日重拼（成了的日子不重复调用、失败的日子原样、只有老收尾段的日子留老条目、旧待续不丢）
final class TimelineDailyTests: XCTestCase {

    private var root: URL!
    private let pid = "xctest-a4-daily"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("a4-daily-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "a4-daily-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        let d = UserDefaults.standard
        for kind in ["timeline"] {
            for field in ["ok", "err", "errmsg", "streak", "model"] { d.removeObject(forKey: "mem_health_\(kind)_\(field)_\(pid)") }
        }
    }

    private var dir: URL { TimelineStore.dir(root: root) }

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    /// 一个窗口：每个时间一条消息，id = prefix + 下标
    private func window(_ id: String, _ title: String, _ times: [Date], segments: [(Range<Int>, String)] = [],
                        kind: SessionSegment.Kind = .rolling, tail: Bool = false, pending: String = "") -> TimelineSkeleton.Window {
        let messages = times.enumerated().map { TimelineSkeleton.Message(id: "\(id)-\($0.offset)", date: $0.element) }
        let segs = segments.map { r, t in
            SessionSegment(kind: kind, title: t, start: times[r.lowerBound], end: times[r.upperBound - 1], from: r.lowerBound, to: r.upperBound,
                           lastNodeId: messages[r.upperBound - 1].id, story: "\(t)的经过", quotes: "", pending: pending, isTail: tail)
        }
        return .init(conversationId: id, title: title, messages: messages,
                     summary: segs.isEmpty ? nil : SessionSummary(conversationId: id, title: title, compressedCount: 0, segments: segs, updatedAt: Date()))
    }

    private func minutes(_ start: Date, _ n: Int, step: TimeInterval = 600) -> [Date] {
        (0..<n).map { start.addingTimeInterval(TimeInterval($0) * step) }
    }

    private final class Calls {
        var users: [String] = []
        var systems: [String] = []
    }

    private func caller(_ calls: Calls, headline: @escaping (String) -> String? = { "主调：" + ($0.components(separatedBy: "\n").first ?? "") }) -> SessionSegmentWriter.Caller {
        { system, user in
            calls.systems.append(system)
            calls.users.append(user)
            return headline(user).map { #"{"headline":"\#($0)","topics":["话题"]}"# }
        }
    }

    /// 假的读窗口：照真接线只给这段时间里有消息的窗口；窗口带的 A2 同时落到 sessions/（A4 扫文件变化、搬待续靠它）
    private func input(_ windows: [TimelineSkeleton.Window], _ calls: Calls, startDay: Date? = nil,
                       headline: @escaping (String) -> String? = { "主调：" + ($0.components(separatedBy: "\n").first ?? "") }) -> TimelineDaily.Input {
        let sessions = SessionSummaryStore.dir(root: root)
        for w in windows { if let s = w.summary { try? SessionSummaryStore.save(s, in: sessions) } }
        return TimelineDaily.Input(profileId: pid, memoryRoot: root, startDay: startDay, caller: caller(calls, headline: headline), modelName: "假模型",
                                   load: { interval in
                                       TimelineSkeleton.Source(windows: windows.filter { w in
                                           w.messages.contains { ($0.date ?? .distantPast) >= interval.start && ($0.date ?? .distantFuture) < interval.end }
                                       })
                                   }, pendingRoot: root, defaults: defaults)
    }

    // MARK: - 骨架

    /// 跨 00:00 不换日；跨 05:00 两天都列，第二天标「接前一天」、指针跳到这段在当天的第一条
    func testSegmentCrossingMidnightAndFiveAM() {
        let times = [date(10, 12, 23, 30), date(10, 13, 0, 30), date(10, 13, 4, 50), date(10, 13, 5, 10), date(10, 13, 6, 0)]
        let w = window("conv-a", "睡前", times, segments: [(0..<5, "聊到天亮")])
        let days = TimelineSkeleton.build([w], days: ["2026-10-12", "2026-10-13"])
        let d12 = days["2026-10-12"]!.items, d13 = days["2026-10-13"]!.items
        XCTAssertEqual(d12.count, 1, "23:30 和 00:30、04:50 都归 10-12")
        XCTAssertEqual(d12[0].from, "conv-a-0")
        XCTAssertEqual(d12[0].to, "conv-a-2")
        XCTAssertFalse(d12[0].continued)
        XCTAssertEqual(d12[0].period(), .evening)
        XCTAssertEqual(d13.count, 1)
        XCTAssertTrue(d13[0].continued, "后一天标接前一天")
        XCTAssertEqual(d13[0].from, "conv-a-3", "指针 = 这段在当天的第一条")
        XCTAssertEqual(d13[0].title, "聊到天亮", "A2 段本身不拆不改")
        XCTAssertEqual(days["2026-10-12"]!.titles, ["聊到天亮"])
        XCTAssertEqual(days["2026-10-13"]!.titles, ["聊到天亮"], "后一天的主调也拿这段标题写")
    }

    /// 一段跨三天：三天都列，后两天接前一天
    func testSegmentAcrossThreeDays() {
        let times = [date(10, 12, 20), date(10, 13, 9), date(10, 13, 21), date(10, 14, 10)]
        let w = window("conv-b", "长谈", times, segments: [(0..<4, "慢慢聊")])
        let days = TimelineSkeleton.build([w], days: ["2026-10-12", "2026-10-13", "2026-10-14"])
        XCTAssertEqual(days.keys.sorted(), ["2026-10-12", "2026-10-13", "2026-10-14"], "无空日")
        XCTAssertEqual(["2026-10-12", "2026-10-13", "2026-10-14"].map { days[$0]!.items.first!.continued }, [false, true, true])
        XCTAssertEqual(days["2026-10-13"]!.items.first?.from, "conv-b-1")
        XCTAssertEqual(days["2026-10-13"]!.items.first?.to, "conv-b-2")
    }

    func testFourPeriods() {
        XCTAssertEqual(TimelinePeriod.of(date(10, 12, 5)), .morning)
        XCTAssertEqual(TimelinePeriod.of(date(10, 12, 11, 59)), .morning)
        XCTAssertEqual(TimelinePeriod.of(date(10, 12, 12)), .afternoon)
        XCTAssertEqual(TimelinePeriod.of(date(10, 12, 18)), .evening)
        XCTAssertEqual(TimelinePeriod.of(date(10, 12, 23, 59)), .evening)
        XCTAssertEqual(TimelinePeriod.of(date(10, 13, 0)), .lateNight)
        XCTAssertEqual(TimelinePeriod.of(date(10, 13, 4, 59)), .lateNight)
        XCTAssertEqual(MemoryDay.key(date(10, 13, 4, 59)), "2026-10-12", "深夜归前一个记忆日")
    }

    /// 同窗口连着的段合一项；不连着的、跨时段的、两个窗口的不合
    func testMergeContiguousSameWindowSamePeriod() {
        let t = minutes(date(10, 12, 9), 8)
        let a = window("conv-a", "开发", t, segments: [(0..<2, "修报错"), (2..<4, "补单测"), (6..<8, "改文案")])
        let b = window("conv-b", "闲聊", minutes(date(10, 12, 9, 5), 2), segments: [(0..<2, "猫")])
        let noon = window("conv-c", "跨中午", [date(10, 12, 11, 40), date(10, 12, 11, 50), date(10, 12, 12, 10), date(10, 12, 12, 20)],
                          segments: [(0..<2, "上午那段"), (2..<4, "下午那段")])
        let day = TimelineSkeleton.build([a, b, noon], days: ["2026-10-12"])["2026-10-12"]!
        let titles = day.items.filter { $0.conversationId == "conv-a" }.map(\.title)
        XCTAssertEqual(titles.filter { $0.hasPrefix("修报错") }, ["修报错；补单测"], "连着的两段合一项")
        XCTAssertTrue(titles.contains("改文案"), "中间隔了没压缩的，不合")
        XCTAssertEqual(day.items.filter { $0.conversationId == "conv-b" }.map(\.title), ["猫"], "两个窗口不合")
        XCTAssertEqual(day.items.filter { $0.conversationId == "conv-c" }.map(\.title), ["上午那段", "下午那段"], "不跨时段")
        XCTAssertEqual(day.items.filter { $0.conversationId == "conv-a" && $0.kind == .uncompressed }.map(\.title), ["（2 条，没压缩）"])
        XCTAssertEqual(day.titles, ["修报错", "补单测", "猫", "改文案", "上午那段", "下午那段"], "主调喂的是这天碰到的各段标题，按时间先后")
    }

    /// 没写 A2 的短窗口（≤5 条）列一行「N 条，没压缩」，有稳定指针；老收尾段 / 第 0 段盖的不列
    func testShortWindowAndLegacyCoverage() {
        let short = window("conv-s", "一句话", [date(10, 12, 22), date(10, 12, 22, 1), date(10, 12, 22, 2)])
        let old = window("conv-o", "老窗口", minutes(date(10, 12, 14), 6), segments: [(0..<6, "老收尾")], kind: .closeout)
        let day = TimelineSkeleton.build([short, old], days: ["2026-10-12"])["2026-10-12"]!
        XCTAssertEqual(day.items.map(\.title), ["（3 条，没压缩）"])
        XCTAssertEqual(day.items.first?.kind, .short)
        XCTAssertEqual(day.items.first?.from, "conv-s-0")
        XCTAssertEqual(day.titles, [], "没有 A2 标题")
    }

    /// 车头裁定：尾段也算 A2——只用 API、没超窗（只有尾段、没有正式段）的日子也有项、也给主调标题；老收尾段照旧不算
    func testTailSegmentCountsAsA2() async {
        let api = window("conv-api", "只用 API", minutes(date(10, 12, 20), 10), segments: [(0..<10, "聊周末去爬山")], kind: .closeout, tail: true)
        let day = TimelineSkeleton.build([api], days: ["2026-10-12"])["2026-10-12"]!
        XCTAssertEqual(day.items.map(\.title), ["聊周末去爬山"])
        XCTAssertEqual(day.items.first?.kind, .segment)
        XCTAssertEqual(day.titles, ["聊周末去爬山"])
        let calls = Calls()
        let r = await TimelineDaily.perform(input([api], calls), now: date(10, 13, 9), force: false)
        XCTAssertEqual(r.written, ["2026-10-12"])
        XCTAssertEqual(calls.users, ["2026-10-12\n聊周末去爬山"], "主调输入有这天的尾段标题")
        XCTAssertNotNil(TimelineStore.day("2026-10-12", in: dir)?.headline, "聊过的日子不空着")
    }

    /// 车头裁定：待续来源换成 A2 段字段——拼日时由代码把当天碰到的 A2 段（含尾段）的 pending 搬进本子，锚点 = 段末条消息；
    /// 「无」/ 空的不搬；重拼、尾段重写成同一句、做完了以后再拼都不重复加；不调模型
    func testPendingHarvestedFromA2Segments() async throws {
        let t = minutes(date(10, 12, 9), 4)
        let a = window("conv-a", "开发", t, segments: [(0..<2, "修报错")], pending: "周三问结果\n- 买药")
        var b = window("conv-b", "闲聊", minutes(date(10, 12, 21), 3), segments: [(0..<3, "尾段")], kind: .closeout, tail: true, pending: "讲完那个故事")
        let none = window("conv-n", "没待续", minutes(date(10, 12, 15), 2), segments: [(0..<2, "无事")], pending: "无")
        let calls = Calls()
        let r = await TimelineDaily.perform(input([a, b, none], calls), now: date(10, 13, 9), force: false)
        XCTAssertEqual(r.pendingAdded, 3)
        var items = try XCTUnwrap(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root))
        XCTAssertEqual(Set(items.map(\.text)), ["周三问结果", "买药", "讲完那个故事"])
        XCTAssertEqual(items.first { $0.text == "周三问结果" }?.anchor, "conv-a-1", "锚点 = 段末条消息")
        XCTAssertEqual(items.first { $0.text == "讲完那个故事" }?.day, "2026-10-12")
        XCTAssertTrue(calls.systems.allSatisfy { $0 == TimelineWriter.systemPrompt }, "只有主调调用，搬待续不调模型")

        try PendingStore.mutate(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root) { list in
            if let i = list.firstIndex(where: { $0.text == "买药" }) { list[i].state = .done }
        }
        var s = b.summary!
        s.segments[0].lastNodeId = "conv-b-2"
        s.segments[0].title = "尾段重写了"
        b = .init(conversationId: b.conversationId, title: b.title, messages: b.messages, summary: s)
        let again = await TimelineDaily.perform(input([a, b, none], calls), now: date(10, 13, 9, 30), force: false)
        XCTAssertEqual(again.pendingAdded, 0, "同一句不再加，做完了的也不翻出来")
        items = try XCTUnwrap(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first { $0.text == "买药" }?.state, .done)
    }

    /// 车头裁定（方案 1）：A2 写手恢复写【待续】→ 落到段的 pending 字段 → A4 拼日时搬进待续本子；「无」不搬
    func testA2WrittenPendingFlowsIntoPendingStore() async throws {
        let times = minutes(date(10, 12, 9), 4)
        let messages = times.enumerated().map { SessionSegmentWriter.Message(id: "conv-w-\($0.offset)", role: $0.offset % 2 == 0 ? "user" : "assistant",
                                                                            content: "第\($0.offset)条", date: $0.element) }
        let speakers = SessionSegmentWriter.Speakers(userName: "岚舟", assistantName: "星砚")
        func write(_ range: Range<Int>, _ reply: String) async throws -> SessionSegment {
            let seg = try await SessionSegmentWriter.write(.init(messages: Array(messages[range]), kind: .rolling, from: range.lowerBound,
                                                                 persona: "", speakers: speakers, previous: nil)) { _, _ in reply }
            return try XCTUnwrap(seg)
        }
        let first = try await write(0..<2, "标题：修报错\n【经过】修了设置页\n【原话】岚舟：「先修这个」\n【待续】\n- 周三问结果\n- 买药")
        let second = try await write(2..<4, "标题：闲聊\n【经过】聊了天气\n【原话】我：「明天下雨」\n【待续】无")
        XCTAssertEqual(first.pending, "周三问结果\n买药", "待续落到段的 pending 字段")
        XCTAssertEqual(second.pending, "", "「无」= 没有")
        let summary = SessionSummary(conversationId: "conv-w", title: "开发", compressedCount: 4, segments: [first, second], updatedAt: Date())
        try SessionSummaryStore.save(summary, in: SessionSummaryStore.dir(root: root))
        let saved = try XCTUnwrap(SessionSummaryStore.load(conversationId: "conv-w", in: SessionSummaryStore.dir(root: root)))
        XCTAssertEqual(saved.segments.map(\.pending), ["周三问结果\n买药", ""], "存盘读回来一样（格式不变）")
        let w = TimelineSkeleton.Window(conversationId: "conv-w", title: "开发", messages: messages.map { .init(id: $0.id, date: $0.date) },
                                        summary: saved)
        let r = await TimelineDaily.perform(input([w], Calls()), now: date(10, 13, 9), force: false)
        XCTAssertEqual(r.pendingAdded, 2)
        let items = try XCTUnwrap(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root))
        XCTAssertEqual(items.map(\.text), ["周三问结果", "买药"])
        XCTAssertTrue(items.allSatisfy { $0.anchor == "conv-w-1" && $0.state == .open })
    }

    /// 段在当前分支上找不到（lastNodeId 不在主线）：按段自己的起止列、没有指针、记下来
    func testUnresolvedSegmentListedWithoutPointer() {
        var w = window("conv-u", "切过分支", minutes(date(10, 12, 15), 4), segments: [(0..<4, "别的分支")])
        var s = w.summary!
        s.segments[0].lastNodeId = "不在主线上"
        w = .init(conversationId: w.conversationId, title: w.title, messages: w.messages, summary: s)
        let day = TimelineSkeleton.build([w], days: ["2026-10-12"])["2026-10-12"]!
        XCTAssertEqual(day.unresolved, ["别的分支"])
        let item = day.items.first { $0.kind == .segment }
        XCTAssertNil(item?.from)
        XCTAssertEqual(item?.title, "别的分支")
    }

    // MARK: - 一趟（零 A2 压缩、主调、时机）

    /// 全程零 A2 压缩调用：sessions/ 一个字不动，模型只被问主调；没压缩的尾巴先列「没压缩」，A2 压完下次补上
    func testZeroA2CallsAndTailFilledAfterA2Compresses() async throws {
        let sessions = SessionSummaryStore.dir(root: root)
        let t = minutes(date(10, 12, 9), 8)
        var w = window("conv-a", "开发", t, segments: [(0..<4, "修报错")])
        try SessionSummaryStore.save(w.summary!, in: sessions)
        let before = try MemoryRegeneration.inventory(sessions)
        let calls = Calls()
        let now = date(10, 13, 9)
        let r1 = await TimelineDaily.perform(input([w], calls), now: now, force: false)
        XCTAssertEqual(try MemoryRegeneration.inventory(sessions), before, "A2 文件一字不动")
        XCTAssertEqual(calls.systems, [TimelineWriter.systemPrompt], "只调了一次，是主调")
        XCTAssertEqual(r1.written, ["2026-10-12"])
        let day1 = try XCTUnwrap(TimelineStore.day("2026-10-12", in: dir))
        XCTAssertEqual(day1.items.map(\.title), ["修报错", "（4 条，没压缩）"])
        XCTAssertEqual(day1.headline, "主调：2026-10-12")

        // A2 自己压完了后半截（不是 A4 触发的）：下次拼那天补上，标题变了才重调
        let r2 = await TimelineDaily.perform(input([w], calls), now: now, force: false)
        XCTAssertEqual(calls.users.count, 1, "标题没变不再调")
        XCTAssertEqual(r2.written, [])
        var s = w.summary!
        s.segments.append(SessionSegment(kind: .rolling, title: "补单测", start: t[4], end: t[7], from: 4, to: 8, lastNodeId: "conv-a-7",
                                         story: "", quotes: "", pending: ""))
        w = .init(conversationId: w.conversationId, title: w.title, messages: w.messages, summary: s)
        _ = await TimelineDaily.perform(input([w], calls), now: now, force: false)
        XCTAssertEqual(calls.users.count, 2)
        XCTAssertEqual(calls.users.last, "2026-10-12\n修报错\n补单测", "只喂日期 + 标题")
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir)?.items.map(\.title), ["修报错；补单测"])
    }

    /// 跨三天的段：三天各有主调，没有空日
    func testThreeDaysEachGetHeadline() async {
        let w = window("conv-b", "长谈", [date(10, 12, 20), date(10, 13, 9), date(10, 13, 21), date(10, 14, 10)], segments: [(0..<4, "慢慢聊")])
        let calls = Calls()
        let r = await TimelineDaily.perform(input([w], calls), now: date(10, 15, 9), force: false)
        XCTAssertEqual(r.written, ["2026-10-12", "2026-10-13", "2026-10-14"])
        for d in r.written { XCTAssertNotNil(TimelineStore.day(d, in: dir)?.headline, d) }
        XCTAssertEqual(calls.users.count, 3, "每天一次")
    }

    /// 主调超 40 字截掉；topics 坏了只丢 topics；模型没回 = 新日子存骨架标「还没有主调」、记失败；已有的日子不动
    func testHeadlineLimitTopicsAndFailures() async throws {
        let w = window("conv-a", "开发", minutes(date(10, 12, 9), 2), segments: [(0..<2, "修报错")])
        let long = String(repeating: "长", count: 50)
        let r = await TimelineDaily.perform(input([w], Calls(), headline: { _ in long }), now: date(10, 13, 9), force: false)
        XCTAssertEqual(r.failed, [:])
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir)?.headline?.count, 40)

        try FileManager.default.removeItem(at: dir)
        let bad: SessionSegmentWriter.Caller = { _, _ in #"{"headline":"一句","topics":"不是数组"}"# }
        var i = input([w], Calls())
        i.caller = bad
        _ = await TimelineDaily.perform(i, now: date(10, 13, 9), force: false)
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir)?.headline, "一句")
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir)?.topics, [])

        try FileManager.default.removeItem(at: dir)
        let none = await TimelineDaily.perform(input([w], Calls(), headline: { _ in nil }), now: date(10, 13, 9), force: false)
        XCTAssertNotNil(none.failed["2026-10-12"])
        XCTAssertNil(TimelineStore.day("2026-10-12", in: dir)?.headline, "骨架先存着，没有主调")
        XCTAssertFalse(TimelineStore.day("2026-10-12", in: dir)?.items.isEmpty ?? true)

        _ = await TimelineDaily.perform(input([w], Calls(), headline: { _ in "后来写成的" }), now: date(10, 13, 9), force: false)
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir)?.headline, "后来写成的", "下次巡检补上")
        try TimelineStore.mutateMonth("2026-10", in: dir) { $0.days[0].headline = "已经有的" }
        let failForce = await TimelineDaily.perform(input([w], Calls(), headline: { _ in nil }), now: date(10, 13, 9), modes: ["2026-10-12": .force], scan: false)
        XCTAssertNotNil(failForce.failed["2026-10-12"])
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir)?.headline, "已经有的", "写不成不拿骨架盖掉已有的")
    }

    /// 自动：今天（05:00 起）跑过就不跑；跑过以后 force（现在写）照跑、今天也拼
    func testRunsOncePerMemoryDayAndForceIncludesToday() async {
        let w = window("conv-a", "开发", minutes(date(10, 13, 9), 2), segments: [(0..<2, "今天的事")])
        let calls = Calls()
        let daily = TimelineDaily()
        let first = await daily.runDue(input([w], calls), now: date(10, 13, 20))
        XCTAssertNotNil(first)
        XCTAssertNil(TimelineStore.day("2026-10-13", in: dir), "自动不拼今天")
        let again = await daily.runDue(input([w], calls), now: date(10, 13, 21))
        XCTAssertNil(again, "同一个记忆日不再跑")
        let forced = await daily.runDue(input([w], calls), now: date(10, 13, 21), force: true)
        XCTAssertEqual(forced?.written, ["2026-10-13"])
        let nextDay = await daily.runDue(input([w], calls), now: date(10, 14, 5, 30))
        XCTAssertNotNil(nextDay, "过了 05:00 是新的一天")
    }

    // MARK: - 显示和注入同一份字

    private func record(_ day: String, headline: String?, items: [TimelineDayRecord.Item] = []) -> TimelineDayRecord {
        TimelineDayRecord(date: day, headline: headline, topics: [], items: items, source: "")
    }

    private func item(_ conv: String, _ title: String, _ start: Date, to: String) -> TimelineDayRecord.Item {
        .init(kind: .segment, conversationId: conv, window: "窗口\(conv)", title: title, start: start, end: start.addingTimeInterval(1800),
              from: to + "-from", to: to)
    }

    /// 今天算第 1 天：今天、昨天带主调 + 各时段；往前第 3–7 天只带主调；再往前不带
    func testTwoDaysFullThreeToSevenHeadlineOnly() {
        var records: [String: TimelineDayRecord] = [:]
        for d in 4...13 {
            let key = String(format: "2026-10-%02d", d)
            records[key] = record(key, headline: "第\(d)号的主调", items: [item("conv-\(d)", "第\(d)号的段", date(10, d, 10), to: "n\(d)")])
        }
        let inj = TimelineStore.injection(records: records, entries: [:], today: "2026-10-13", currentConversationId: "", windowIds: [],
                                          openPending: [:], days: 7)
        let text = inj.text!
        for d in 12...13 { XCTAssertTrue(text.contains("第\(d)号的段"), "\(d) 带各时段") }
        for d in 7...11 {
            XCTAssertTrue(text.contains("第\(d)号的主调"), "\(d) 带主调")
            XCTAssertFalse(text.contains("第\(d)号的段"), "\(d) 只带主调")
        }
        for d in 4...6 { XCTAssertFalse(text.contains("第\(d)号"), "\(d) 超过 7 天不带") }
        XCTAssertTrue(text.hasPrefix("[时间轴]"))
        XCTAssertLessThan(text.range(of: "第7号")!.lowerBound, text.range(of: "第13号")!.lowerBound, "按日期先后")
    }

    /// 界面那一行 = 注入那一行（主调、每一项、老条目）；当前窗口还在历史窗口里的项不注；待续单独一段
    func testDisplayAndInjectionShareText() {
        let r = record("2026-10-13", headline: "白天修报错", items: [
            item("conv-a", "修设置页报错", date(10, 13, 9), to: "a9"),
            item("conv-cur", "刚聊的", date(10, 13, 20), to: "h1"),
            .init(kind: .short, conversationId: "conv-s", window: "睡前", title: "（2 条，没压缩）", start: date(10, 14, 1), end: date(10, 14, 1, 5),
                  from: "s0", to: "s1"),
        ])
        let old = TimelineEntry(start: date(10, 13, 14), end: date(10, 13, 15), conversationId: "conv-old", title: "老窗口", text: "- 老话题",
                                pending: "", day: "2026-10-13", lastNodeId: "o1")
        let inj = TimelineStore.injection(records: ["2026-10-13": r], entries: ["2026-10-13": [old]], today: "2026-10-13",
                                          currentConversationId: "conv-cur", windowIds: ["h1"], openPending: ["conv-a": ["问结果"]], days: 7)
        let text = inj.text!
        XCTAssertTrue(text.contains(TimelineStore.headlineText(r)))
        for row in TimelineListLayout.rows(r) where row.item.conversationId != "conv-cur" {
            XCTAssertTrue(text.contains(TimelineStore.itemText(row.item)), TimelineStore.itemText(row.item))
        }
        XCTAssertFalse(text.contains("刚聊的"), "原文还在窗口里的不注")
        XCTAssertFalse(text.contains(TimelineStore.legacyText(old)), "这天有新主调：只用新的，老条目留在文件里不注")
        XCTAssertTrue(text.contains("[待续]") && text.contains("《窗口conv-a》conv conv-a：问结果"), "待续单独一段，带窗口编号，不跟在日条目后面")
        XCTAssertTrue(TimelineStore.itemText(r.items[0]).hasSuffix(" conv conv-a"), "界面和注入都带窗口短编号")
        XCTAssertEqual(inj.units.map(\.key), ["2026-10-13", "2026-10-13|conv-a|a9", "2026-10-13|conv-s|s1"])
        let noHeadline = TimelineStore.injection(records: ["2026-10-13": record("2026-10-13", headline: nil, items: r.items)],
                                                 entries: ["2026-10-13": [old]], today: "2026-10-13", currentConversationId: "", windowIds: [],
                                                 openPending: [:], days: 7)
        XCTAssertTrue(noHeadline.text?.contains(TimelineStore.legacyText(old)) == true, "这天没有新主调：老条目那一行照带")
        let groups = TimelineListLayout.group(records: [r], entries: [old])
        XCTAssertTrue(TimelineListLayout.foldsLegacy(groups[0]), "有新记录：老条目折在「旧格式」下面")
        XCTAssertFalse(TimelineListLayout.foldsLegacy(TimelineListLayout.group(records: [], entries: [old])[0]), "只有老条目：照旧列出来")
        for u in inj.units { XCTAssertTrue(text.contains(u.line)) }
        XCTAssertEqual(TimelineListLayout.rows(r).map(\.period), ["上午", "晚上", "深夜"], "换时段的那项带时段名")
    }

    // MARK: - 旧数据

    private func legacy(_ day: Int, _ conv: String, _ title: String, pending: String = "") -> TimelineEntry {
        TimelineEntry(start: date(10, day, 9), end: date(10, day, 10), conversationId: conv, title: title, text: "- \(title)的老话题",
                      pending: pending, day: String(format: "2026-10-%02d", day), lastNodeId: "\(conv)-x")
    }

    /// 备份失败 → 一个字不换（有老条目的月份整份不动），不调模型
    func testBackupFailureSwitchesNothing() async throws {
        try TimelineStore.seedLegacy(legacy(5, "conv-a", "开发"), in: dir)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("链接"), withDestinationURL: root)
        let url = dir.appendingPathComponent("2026-10.md")
        let before = try String(contentsOf: url, encoding: .utf8)
        let w = window("conv-a", "开发", minutes(date(10, 5, 9), 2), segments: [(0..<2, "修报错")])
        let calls = Calls()
        let r = await TimelineDaily.perform(input([w], calls), now: date(10, 13, 9), force: false)
        XCTAssertNotNil(r.blocked)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before)
        XCTAssertEqual(calls.users, [])
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).isEmpty)
    }

    /// 老数据：先备份（timeline/ + pending/，核过）；有 A2 的日子加一天一条，老条目一条不删；只有老收尾段的日子不碰；
    /// 失败的日子原样、留在待拼里；重入时成了的日子不再调用；旧待续迁进待续本子、注入照带
    func testMigrationByDay() async throws {
        try TimelineStore.seedLegacy(legacy(5, "conv-a", "开发"), in: dir)
        try TimelineStore.seedLegacy(legacy(6, "conv-a", "开发", pending: "周三问结果"), in: dir)
        try TimelineStore.seedLegacy(legacy(7, "conv-o", "老窗口"), in: dir)
        let a = window("conv-a", "开发", minutes(date(10, 5, 9), 2) + minutes(date(10, 6, 9), 2), segments: [(0..<2, "五号的段"), (2..<4, "六号的段")])
        let o = window("conv-o", "老窗口", minutes(date(10, 7, 9), 6), segments: [(0..<6, "老收尾")], kind: .closeout)
        let calls = Calls()
        let failSixth: (String) -> String? = { $0.hasPrefix("2026-10-06") ? nil : "主调" }
        let r1 = await TimelineDaily.perform(input([a, o], calls, headline: failSixth), now: date(10, 20, 9), force: false)

        let backup = try XCTUnwrap(r1.backup)
        XCTAssertTrue(backup.hasPrefix(TimelineDaily.backupPrefix))
        XCTAssertEqual(MemoryRegeneration.backups(memoryRoot: root).first?.lastPathComponent, backup, "进可恢复的备份列表")
        let manifest = try XCTUnwrap(MemoryRegeneration.manifest(of: MemoryRegeneration.backupRoot(memoryRoot: root).appendingPathComponent(backup)))
        XCTAssertEqual(manifest.covered, [TimelineStore.folder, PendingStore.folder])
        XCTAssertTrue(manifest.folders.contains(TimelineStore.folder))

        XCTAssertEqual(r1.written, ["2026-10-05"])
        XCTAssertNotNil(r1.failed["2026-10-06"])
        XCTAssertEqual(r1.keptLegacy, [], "只有老收尾段的日子没有 A2：不用拼，老条目照旧")
        XCTAssertNil(r1.failed["2026-10-07"])
        let m = TimelineStore.month("2026-10", in: dir)
        XCTAssertEqual(m.days.map(\.date), ["2026-10-05"])
        XCTAssertEqual(m.entries.map(\.dayKey).sorted(), ["2026-10-05", "2026-10-06", "2026-10-07"], "老条目一条不删")
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root)?.map(\.text), ["周三问结果"], "旧待续迁进待续本子")
        XCTAssertTrue(PendingStore.isLegacyDone(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root))
        XCTAssertEqual(TimelineSourceState.load(dir).dirty, ["2026-10-06"], "没写成的日子留在待拼里")

        let r2 = await TimelineDaily.perform(input([a, o], calls), now: date(10, 20, 9), force: false)
        XCTAssertEqual(calls.users.filter { $0.hasPrefix("2026-10-05") }.count, 1, "成了的日子不重复调用")
        XCTAssertEqual(r2.written, ["2026-10-06"], "失败的日子这次补上")
        XCTAssertNil(r2.backup, "备份过了不再备份")
        XCTAssertEqual(TimelineStore.month("2026-10", in: dir).entries.count, 3)
        XCTAssertEqual(TimelineSourceState.load(dir).dirty, [])

        let inj = TimelineStore.injection(records: ["2026-10-05": TimelineStore.day("2026-10-05", in: dir)!], entries: [:], today: "2026-10-06",
                                          currentConversationId: "", windowIds: [],
                                          openPending: PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root).map { items in
                                              Dictionary(grouping: items, by: \.conversationId).mapValues { $0.map(\.text) } }, days: 7)
        XCTAssertTrue(inj.text?.contains("周三问结果") == true, "待续照样注入")
    }

    /// 起点以前的老条目不碰
    func testLegacyBeforeStartDayKept() async {
        try? TimelineStore.seedLegacy(legacy(5, "conv-a", "开发"), in: dir)
        let a = window("conv-a", "开发", minutes(date(10, 5, 9), 2), segments: [(0..<2, "五号的段")])
        let r = await TimelineDaily.perform(input([a], Calls(), startDay: date(10, 6, 5)), now: date(10, 20, 9), force: false)
        XCTAssertEqual(r.written, [])
        XCTAssertEqual(TimelineStore.month("2026-10", in: dir).entries.count, 1)
    }

    // MARK: - 模型选择

    /// 没选过 = 本机轻巧款；本机没装 / 不支持 / 在后台退回提取模型并写清；选过的照旧
    func testModelRouteDefaultsLocalAndFallsBack() {
        let extract = ProviderModel(credentialId: "c", modelId: "extract", name: "提取模型")
        let other = ProviderModel(credentialId: "c", modelId: "other", name: "别的")
        func resolve(_ stored: String, installed: Bool = true, active: Bool = true, supported: Bool = true) -> FragmentModelRoute.Resolved {
            FragmentModelRoute.resolve(choice: TimelineModelRoute.choice(stored), memoryModel: extract, remoteModels: [other],
                                       localSupported: supported, appActive: active, localInstalled: { _ in installed })
        }
        XCTAssertEqual(resolve("").route, .local(modelId: AssistantLocalModel.light.id))
        XCTAssertEqual(resolve("", installed: false).route, .remote(extract))
        XCTAssertNotNil(resolve("", installed: false).fallbackNote)
        XCTAssertEqual(resolve("", active: false).route, .remote(extract))
        XCTAssertEqual(resolve("", supported: false).route, .remote(extract))
        XCTAssertEqual(resolve(other.id).route, .remote(other), "已有显式选择保留")
        XCTAssertEqual(resolve(FragmentModelRoute.extractChoice).route, .remote(extract))
    }

    // MARK: - 真实接线读窗口

    /// 读窗口：开着记忆参与、没进回收站、碰到这段时间的；带已落盘的 A2
    @MainActor
    func testWindowsLoaderReadsMainPathAndA2() throws {
        let c = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(c)
        func add(_ id: String, count: Int, at start: Date, memory: Bool = true) {
            for i in 0..<count {
                context.insert(MessageNode(id: "\(id)-\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "第\(i)条", contentType: "text",
                                           createTime: start.addingTimeInterval(TimeInterval(i * 60)), parentId: i == 0 ? nil : "\(id)-\(i - 1)",
                                           childrenIds: i + 1 < count ? ["\(id)-\(i + 1)"] : [], conversationId: id, profileId: pid))
            }
            let conv = Conversation(id: id, title: "窗口\(id)", createTime: start, updateTime: start.addingTimeInterval(TimeInterval(count * 60)),
                                    currentNodeId: "\(id)-\(count - 1)", profileId: pid)
            conv.memoryEnabled = memory
            context.insert(conv)
        }
        add("conv-in", count: 4, at: date(10, 12, 9))
        add("conv-off", count: 4, at: date(10, 12, 9), memory: false)
        add("conv-late", count: 4, at: date(10, 14, 9))
        try context.save()
        try SessionSummaryStore.save(SessionSummary(conversationId: "conv-in", title: "窗口conv-in", compressedCount: 0, segments: [
            SessionSegment(kind: .rolling, title: "段", start: date(10, 12, 9), end: date(10, 12, 9, 3), from: 0, to: 4, lastNodeId: "conv-in-3",
                           story: "", quotes: "", pending: "")], updatedAt: Date()), in: SessionSummaryStore.dir(root: root))
        let ws = TimelineDaily.windows(profileId: pid, source: SwiftDataConversationSource(container: c), memoryRoot: root,
                                       in: DateInterval(start: date(10, 12, 5), end: date(10, 13, 5)))
        XCTAssertNil(ws.error)
        XCTAssertEqual(ws.windows.map(\.conversationId), ["conv-in"])
        XCTAssertEqual(ws.windows.first?.messages.map(\.id), ["conv-in-0", "conv-in-1", "conv-in-2", "conv-in-3"])
        XCTAssertEqual(ws.windows.first?.summary?.segments.first?.title, "段")
    }

    // MARK: - 窗口总结页定位

    func testWindowSummaryAnchor() {
        let a2 = [
            SessionSegment(kind: .rolling, title: "修报错", start: date(10, 12, 9), end: date(10, 12, 10), from: 0, to: 4, lastNodeId: "x",
                           story: "", quotes: "", pending: ""),
            SessionSegment(kind: .rolling, title: "补单测", start: date(10, 12, 10, 30), end: date(10, 12, 11), from: 4, to: 8, lastNodeId: "y",
                           story: "", quotes: "", pending: ""),
        ]
        XCTAssertEqual(WindowSummaryReader.anchored(a2, .init(start: date(10, 12, 10, 40), title: "补单测")), 1)
        XCTAssertEqual(WindowSummaryReader.anchored(a2, .init(start: date(10, 12, 9), title: "修报错；补单测")), 0, "合并的项落在第一段")
        XCTAssertNil(WindowSummaryReader.anchored(a2, .init(start: date(10, 13, 9), title: "删了的段")), "找不到明确说")
        XCTAssertEqual(WindowSummaryReader.number(1, in: a2), 2, "段号现算，从 1 数")
    }

    // MARK: - astra 第 7 段返工（P1 / P2）

    private func with(_ w: TimelineSkeleton.Window, _ change: (inout SessionSummary) -> Void) -> TimelineSkeleton.Window {
        var s = w.summary!
        change(&s)
        return .init(conversationId: w.conversationId, title: w.title, messages: w.messages, summary: s)
    }

    private func pendingBytes() -> Data? { try? Data(contentsOf: PendingStore.fileURL(root: root)) }

    /// 车头 10-22：老条目一律不删——当前主线被 A2 整个盖住、切过分支（老条目记的是旧分支）、删过消息，都照样留着；新的一天一条并列，
    /// 列表里折在「旧格式」下面，注入这天有新主调就只用新的
    func testLegacyEntriesNeverRemoved() async throws {
        var old = legacy(5, "conv-a", "全盖住")
        old.lastNodeId = "旧分支上的消息"
        try TimelineStore.seedLegacy(old, in: dir)
        try TimelineStore.seedLegacy(legacy(5, "conv-d", "删过消息"), in: dir)
        let a = window("conv-a", "全盖住", minutes(date(10, 5, 9), 6), segments: [(0..<6, "当前分支")])
        let d = window("conv-d", "删过消息", minutes(date(10, 5, 15), 2), segments: [(0..<2, "剩下的两条")])
        let r = await TimelineDaily.perform(input([a, d], Calls()), now: date(10, 20, 9), force: false)
        XCTAssertEqual(r.written, ["2026-10-05"])
        XCTAssertEqual(Set(TimelineStore.month("2026-10", in: dir).entries.map(\.conversationId)), ["conv-a", "conv-d"], "一条不删")
        let day = try XCTUnwrap(TimelineStore.day("2026-10-05", in: dir))
        XCTAssertEqual(day.items.map(\.title), ["当前分支", "剩下的两条"])
        let month = TimelineStore.month("2026-10", in: dir)
        XCTAssertTrue(TimelineListLayout.foldsLegacy(TimelineListLayout.group(records: month.days, entries: month.entries)[0]))
        let inj = TimelineStore.injection(records: ["2026-10-05": day], entries: ["2026-10-05": month.entries], today: "2026-10-06",
                                          currentConversationId: "", windowIds: [], openPending: [:], days: 7)
        XCTAssertFalse(inj.text?.contains("旧格式") ?? true, "有新主调只注新的")
    }

    /// astra #2：备份没做成 → 待续本子一个字节不变（不先迁、不先搬）、月文件不变、不调模型
    func testBackupFailureLeavesPendingUntouched() async throws {
        try PendingStore.mutate(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root) { $0 = [PendingItem(id: "p1", text: "原有的一条", state: .open,
                                                                                    conversationId: "conv-z", day: "2026-10-01", anchor: nil)] }
        try TimelineStore.seedLegacy(legacy(5, "conv-a", "开发", pending: "老待续"), in: dir)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("链接"), withDestinationURL: root)
        let pendingBefore = try XCTUnwrap(pendingBytes())
        let monthBefore = try Data(contentsOf: dir.appendingPathComponent("2026-10.md"))
        let w = window("conv-a", "开发", minutes(date(10, 5, 9), 2), segments: [(0..<2, "修报错")], pending: "新待续")
        let calls = Calls()
        let r = await TimelineDaily.perform(input([w], calls), now: date(10, 20, 9), force: false)
        XCTAssertNotNil(r.blocked)
        XCTAssertEqual(r.pendingAdded, 0)
        XCTAssertEqual(pendingBytes(), pendingBefore, "待续本子不动")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("2026-10.md")), monthBefore)
        XCTAssertEqual(calls.users, [])
    }

    /// astra #2：待续本子有认不出的行 → 严格读停下：一行不丢（文件原样）、待续不搬、不标迁完；这批 A2 文件的指纹不记，下次重扫重搬；
    /// 老条目照旧不动，日记录照拼（不碰本子）；备份照做（是原始的）
    func testUnreadablePendingBlocksAndKeepsEveryLine() async throws {
        let url = PendingStore.fileURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = PendingStore.render([PendingItem(id: "p1", text: "认得的", state: .open, conversationId: "conv-z", day: "2026-10-01", anchor: nil)])
            + "\n- 手写的一行，没有机读注释"
        try Data(raw.utf8).write(to: url)
        try TimelineStore.seedLegacy(legacy(5, "conv-a", "开发", pending: "老待续"), in: dir)
        let w = window("conv-a", "开发", minutes(date(10, 5, 9), 2), segments: [(0..<2, "修报错")], pending: "新待续")
        let r = await TimelineDaily.perform(input([w], Calls()), now: date(10, 20, 9), force: false)
        XCTAssertNotNil(r.backup, "先备份原始的")
        XCTAssertTrue(r.blocked?.contains("待续没保全") == true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), raw, "一行不丢")
        XCTAssertEqual(TimelineStore.month("2026-10", in: dir).entries.map(\.conversationId), ["conv-a"], "老条目不动")
        XCTAssertEqual(r.written, ["2026-10-05"])
        XCTAssertTrue(TimelineSourceState.load(dir).files.isEmpty, "待续没搬成：文件指纹不记，下次重扫")
    }

    /// 旧安全性质用新入口补回：老条目的待续先进本子（严格读、标迁完），老条目原样；备份里是原始的（老条目 + 还没有本子）
    func testLegacyPendingMigratedAndBackupIsOriginal() async throws {
        try TimelineStore.seedLegacy(legacy(5, "conv-a", "开发", pending: "周三问结果"), in: dir)
        let w = window("conv-a", "开发", minutes(date(10, 5, 9), 2), segments: [(0..<2, "修报错")])
        let r = await TimelineDaily.perform(input([w], Calls()), now: date(10, 20, 9), force: false)
        XCTAssertEqual(r.written, ["2026-10-05"])
        XCTAssertEqual(TimelineStore.month("2026-10", in: dir).entries.map(\.pending), ["周三问结果"], "老条目原样")
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root)?.map(\.text), ["周三问结果"])
        let backup = MemoryRegeneration.backupRoot(memoryRoot: root).appendingPathComponent(try XCTUnwrap(r.backup))
        XCTAssertEqual(try TimelineStore.monthStrict("2026-10", in: TimelineStore.dir(root: backup)).entries.map(\.pending), ["周三问结果"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: PendingStore.fileURL(root: backup).path))
        // 迁完以后 A 线按本子：她标了做完，老条目那条不再当待续读到
        let items = try XCTUnwrap(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root))
        let entry = try XCTUnwrap(TimelineStore.month("2026-10", in: dir).entries.first)
        XCTAssertEqual(CatalogALineReader.a4Lines(entry, book: items).flatMap { $0.map(\.text) }.contains("周三问结果"), true)
        var done = items
        done[0].state = .done
        XCTAssertFalse(CatalogALineReader.a4Lines(entry, book: done).flatMap { $0.map(\.text) }.contains("周三问结果"), "做完了的不读")
        XCTAssertTrue(CatalogALineReader.a4Lines(entry, book: nil).flatMap { $0.map(\.text) }.contains("周三问结果"), "没迁完才读老字段")
    }

    /// astra #2：记着的备份要按清单核内容，被改过就不算，重新备份
    func testBackupValidChecksContent() async throws {
        try TimelineStore.seedLegacy(legacy(5, "conv-a", "开发"), in: dir)
        try TimelineStore.seedLegacy(legacy(6, "conv-b", "闲聊"), in: dir)
        let a = window("conv-a", "开发", minutes(date(10, 5, 9), 2), segments: [(0..<2, "五号")])
        let r1 = await TimelineDaily.perform(input([a], Calls()), now: date(10, 20, 9), force: false)
        let first = try XCTUnwrap(r1.backup)
        XCTAssertTrue(TimelineDaily.backupValid(input([], Calls())))
        let copy = MemoryRegeneration.backupRoot(memoryRoot: root).appendingPathComponent(first)
            .appendingPathComponent(TimelineStore.folder).appendingPathComponent("2026-10.md")
        try Data((try String(contentsOf: copy, encoding: .utf8) + "\n被改了").utf8).write(to: copy)
        XCTAssertFalse(TimelineDaily.backupValid(input([], Calls())), "内容对不上清单")
        let b = window("conv-b", "闲聊", minutes(date(10, 6, 9), 2), segments: [(0..<2, "六号")])
        let r2 = await TimelineDaily.perform(input([a, b], Calls()), now: date(10, 20, 9, 30), force: false)
        XCTAssertNotNil(r2.backup)
        XCTAssertNotEqual(r2.backup, first)
    }

    /// astra #3：A2 读不了（窗口标了错）/ 整体没读全 → 那天原样、记失败、不调模型；真实接线里坏文件 = 标错，不当「没有 A2」
    @MainActor
    func testSummaryReadFailureKeepsExistingDay() async throws {
        let w = window("conv-a", "开发", minutes(date(10, 12, 9), 2), segments: [(0..<2, "修报错")])
        _ = await TimelineDaily.perform(input([w], Calls()), now: date(10, 13, 9), force: false)
        let before = try XCTUnwrap(TimelineStore.day("2026-10-12", in: dir))
        let broken = TimelineSkeleton.Window(conversationId: "conv-a", title: "开发", messages: w.messages, summary: nil, summaryError: "坏了")
        let calls = Calls()
        let r = await TimelineDaily.perform(input([broken], calls), now: date(10, 13, 9), modes: ["2026-10-12": .force], scan: false)
        XCTAssertNotNil(r.failed["2026-10-12"])
        XCTAssertEqual(r.unread, ["2026-10-12"])
        XCTAssertEqual(calls.users, [])
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir), before)

        var i = input([w], calls)
        i.load = { _ in TimelineSkeleton.Source(windows: [], error: "取不出消息") }
        let all = await TimelineDaily.perform(i, now: date(10, 13, 9), force: false)
        XCTAssertEqual(all.unread.count, TimelineDaily.lookbackDays)
        XCTAssertEqual(calls.users, [])
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir), before)

        let c = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(c)
        for k in 0..<4 {
            context.insert(MessageNode(id: "conv-bad-\(k)", role: k % 2 == 0 ? "user" : "assistant", content: "第\(k)条", contentType: "text",
                                       createTime: date(10, 12, 9, k), parentId: k == 0 ? nil : "conv-bad-\(k - 1)",
                                       childrenIds: k < 3 ? ["conv-bad-\(k + 1)"] : [], conversationId: "conv-bad", profileId: pid))
        }
        context.insert(Conversation(id: "conv-bad", title: "坏文件", createTime: date(10, 12, 9), updateTime: date(10, 12, 9, 4),
                                    currentNodeId: "conv-bad-3", profileId: pid))
        try context.save()
        let sessions = SessionSummaryStore.dir(root: root)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("随便写的\n<!-- seg kind=rolling -->\n".utf8).write(to: sessions.appendingPathComponent("conv-bad-坏文件.md"))
        let src = TimelineDaily.windows(profileId: pid, source: SwiftDataConversationSource(container: c), memoryRoot: root, in: DateInterval(start: date(10, 12, 5), end: date(10, 13, 5)))
        XCTAssertNotNil(src.windows.first { $0.conversationId == "conv-bad" }?.summaryError)
    }

    /// astra #4：维护（搬迁 / 恢复）中途开始 → 在途那趟的提交作废、什么都不写（待续也不搬）；维护期间新的一趟不进、手动重写也不进
    func testMaintenanceInvalidatesInFlightAndBlocksNew() async throws {
        defer { TimelineDaily.gate.resume() }
        let w = window("conv-a", "开发", minutes(date(10, 12, 9), 2), segments: [(0..<2, "修报错")])
        var i = input([w], Calls())
        i.caller = { _, _ in
            TimelineDaily.gate.pause()
            return #"{"headline":"迟到的主调","topics":[]}"#
        }
        let r = await TimelineDaily.perform(i, now: date(10, 13, 9), force: false)
        XCTAssertTrue(r.invalidated)
        XCTAssertEqual(r.written, [])
        XCTAssertNil(TimelineStore.day("2026-10-12", in: dir), "作废了，不落盘")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TimelineSourceState.url(dir).path), "来源账也不记")

        let daily = TimelineDaily()
        let calls = Calls()
        let paused = await daily.runDue(input([w], calls), now: date(10, 13, 9), force: true)
        XCTAssertNil(paused)
        let again = await daily.regenerate(day: "2026-10-12", input([w], calls), now: date(10, 13, 9))
        XCTAssertNil(again)
        XCTAssertThrowsError(try TimelineDaily.ensurePendingMigrated(profileId: pid, memoryRoot: root, defaults: defaults), "维护中不迁")
        XCTAssertEqual(calls.users, [])

        // 搬待续那一步也在锁里看纪元：开始以后进了维护 → 一条不搬
        let p = window("conv-p", "待续", minutes(date(10, 12, 9), 2), segments: [(0..<2, "带待续")], pending: "待续一条")
        TimelineDaily.gate.resume()
        var j = input([p], calls)
        j.load = { _ in
            TimelineDaily.gate.pause()
            return TimelineSkeleton.Source(windows: [p])
        }
        let r2 = await TimelineDaily.perform(j, now: date(10, 13, 9), modes: ["2026-10-12": .daily], scan: true, eligible: { _ in true })
        XCTAssertTrue(r2.invalidated)
        XCTAssertEqual(r2.pendingAdded, 0)
        XCTAssertNil(pendingBytes())

        TimelineDaily.gate.resume()
        let after = await daily.runDue(input([w], calls), now: date(10, 13, 9))
        XCTAssertEqual(after?.written, ["2026-10-12"])
    }

    /// astra #9 / 二轮 #5：恢复了带 timeline/ 的备份 → 恢复前后出现过的日子和恢复那天以前的全部日子，自动都不碰（最近几天也不重拼、不调模型），
    /// 手动「重写这天」照写
    func testRestoreFreezesRestoredDays() async throws {
        try TimelineStore.seedLegacy(legacy(5, "conv-a", "开发"), in: dir)
        try TimelineStore.seedLegacy(legacy(6, "conv-a", "开发"), in: dir)
        let a = window("conv-a", "开发", minutes(date(10, 5, 9), 2) + minutes(date(10, 6, 9), 2), segments: [(0..<2, "五号"), (2..<4, "六号")])
        let calls = Calls()
        let r1 = await TimelineDaily.perform(input([a], calls), now: date(10, 7, 9), force: false)
        XCTAssertEqual(r1.written, ["2026-10-05", "2026-10-06"])
        let backup = MemoryRegeneration.backupRoot(memoryRoot: root).appendingPathComponent(try XCTUnwrap(r1.backup))
        try MemoryRegeneration.restore(backup: backup, memoryRoot: root, now: date(10, 7, 10), profileId: pid, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: TimelineDaily.frozenKey(pid)), ["0000-01-01", "2026-10-06"])
        XCTAssertEqual(TimelineStore.month("2026-10", in: dir).days, [], "恢复回来的是迁之前的")
        let n = calls.users.count
        let r2 = await TimelineDaily.perform(input([a], calls), now: date(10, 8, 9), force: false)
        XCTAssertEqual(r2.written, [], "最近几天里恢复过的日子也不自动重拼")
        XCTAssertEqual(calls.users.count, n)
        let manual = await TimelineDaily().regenerate(day: "2026-10-06", input([a], calls), now: date(10, 8, 9))
        XCTAssertEqual(manual?.written, ["2026-10-06"], "手动照写（只有老条目的日子，界面从老条目菜单 / 「重写某一天…」进）")
        XCTAssertEqual(TimelineListLayout.dayKey(picked: date(10, 6, 2)), "2026-10-06", "选日期：凌晨选的也算那一天")
        XCTAssertEqual(TimelineListLayout.dayKey(picked: date(10, 6, 23)), "2026-10-06")
    }

    /// astra 三轮 #3：今天的 A2 扫到了但今天不拼——留在待拼里；隔十多天再打开（今天早出了最近 7 天）照样补拼
    func testTodayStaysPendingUntilDue() async throws {
        let w = window("conv-t", "今天", minutes(date(10, 13, 9), 2), segments: [(0..<2, "今天的段")])
        let r1 = await TimelineDaily.perform(input([w], Calls()), now: date(10, 13, 20), force: false)
        XCTAssertEqual(r1.written, [])
        XCTAssertEqual(TimelineSourceState.load(dir).dirty, ["2026-10-13"], "还没到时候，留着")
        let r2 = await TimelineDaily.perform(input([w], Calls()), now: date(10, 24, 9), force: false)
        XCTAssertEqual(r2.written, ["2026-10-13"], "十一天后照样补")
        XCTAssertEqual(TimelineSourceState.load(dir).dirty, [])
    }

    /// astra 三轮 #3：起点往前挪 → 已登记的文件重新盘点：起点以前那段的待续补搬、那几天补拼
    func testStartMovedEarlierRescansSources() async throws {
        let w = window("conv-e", "早", minutes(date(10, 5, 9), 2), segments: [(0..<2, "五号的段")], pending: "早先的待续")
        let r1 = await TimelineDaily.perform(input([w], Calls(), startDay: date(10, 10, 5)), now: date(10, 20, 9), force: false)
        XCTAssertEqual(r1.written, [])
        XCTAssertNil(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root), "起点以前的段不搬")
        XCTAssertEqual(TimelineSourceState.load(dir).harvestedFrom, "2026-10-10")
        let r2 = await TimelineDaily.perform(input([w], Calls(), startDay: date(10, 1, 5)), now: date(10, 20, 9), force: false)
        XCTAssertEqual(r2.written, ["2026-10-05"], "补拼")
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root)?.map(\.text), ["早先的待续"], "补搬")
        XCTAssertEqual(TimelineSourceState.load(dir).harvestedFrom, "2026-10-01")
    }

    /// astra 四轮 #3：全量盘点时有个 A2 文件读不了 → 不算盘完；修好以后下一轮补搬
    func testFullHarvestNotDoneWhileAFileUnreadable() async throws {
        let a = window("conv-a", "好的", minutes(date(10, 12, 9), 2), segments: [(0..<2, "好段")], pending: "好的待续")
        let b = window("conv-b", "坏的", minutes(date(10, 12, 15), 2), segments: [(0..<2, "坏段")], pending: "坏文件里的待续")
        let i = input([a, b], Calls())
        let file = try XCTUnwrap(SessionSummaryStore.fileURL(conversationId: "conv-b", in: SessionSummaryStore.dir(root: root)))
        try Data("随便写的\n<!-- seg kind=rolling -->\n".utf8).write(to: file)
        let r1 = await TimelineDaily.perform(i, now: date(10, 13, 9), force: false)
        XCTAssertEqual(r1.sourceErrors.count, 1)
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root)?.map(\.text), ["好的待续"])
        XCTAssertNil(TimelineSourceState.load(dir).harvestedFrom, "有文件读不了，不记盘完")
        _ = await TimelineDaily.perform(input([a, b], Calls()), now: date(10, 13, 9, 30), force: false)
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root)?.map(\.text), ["好的待续", "坏文件里的待续"], "修好后补搬")
        XCTAssertEqual(TimelineSourceState.load(dir).harvestedFrom, "")
    }

    /// astra 二轮 #5：恢复一份空备份（当时还没有 timeline/，第一次因为搬待续才建的）→ 照样冻住，自动不再生成同一批记录、不再调模型
    func testEmptyBackupRestoreStillStopsAutoRebuild() async throws {
        let w = window("conv-a", "开发", minutes(date(10, 12, 9), 2), segments: [(0..<2, "修报错")], pending: "买药")
        let calls = Calls()
        let r1 = await TimelineDaily.perform(input([w], calls), now: date(10, 13, 9), force: false)
        XCTAssertEqual(r1.written, ["2026-10-12"])
        let name = try XCTUnwrap(r1.backup)
        let backup = MemoryRegeneration.backupRoot(memoryRoot: root).appendingPathComponent(name)
        XCTAssertFalse(MemoryRegeneration.manifest(of: backup)?.folders.contains(TimelineStore.folder) ?? true, "备份里没有时间轴")
        try MemoryRegeneration.restore(backup: backup, memoryRoot: root, now: date(10, 13, 10), profileId: pid, defaults: defaults)
        XCTAssertNil(TimelineStore.day("2026-10-12", in: dir), "恢复把日记录撤掉了")
        XCTAssertEqual(defaults.stringArray(forKey: TimelineDaily.frozenKey(pid)), ["0000-01-01", "2026-10-12"])
        let n = calls.users.count
        let r2 = await TimelineDaily.perform(input([w], calls), now: date(10, 14, 9), force: false)
        XCTAssertEqual(r2.written, [])
        XCTAssertEqual(calls.users.count, n, "不再调模型")
        XCTAssertNil(TimelineStore.day("2026-10-12", in: dir))
    }

    /// astra #5：日主调 / 话题是整天写的——有看不见的窗口就不给，只给看得见的项；一项都看不见整天不给（recall 走同一条）
    func testDayHeadlineHiddenWhenAnySourceHidden() throws {
        let r = TimelineDayRecord(date: "2026-10-12", headline: "白天修了报错", topics: ["报错"], items: [
            item("conv-a", "修设置页", date(10, 12, 9), to: "a1"), item("conv-b", "删掉的窗口聊的", date(10, 12, 15), to: "b1"),
        ], source: "")
        func text(_ v: Set<String>?) -> String { CatalogALineReader.dayParts(r, visible: v).map(\.text).joined() }
        XCTAssertTrue(text(nil).contains("白天修了报错"))
        XCTAssertTrue(text(["conv-a", "conv-b"]).contains("白天修了报错"))
        XCTAssertFalse(text(["conv-a"]).contains("白天修了报错"))
        XCTAssertFalse(text(["conv-a"]).contains("话题"))
        XCTAssertTrue(text(["conv-a"]).contains("修设置页"))
        XCTAssertFalse(text(["conv-a"]).contains("删掉的窗口聊的"))
        XCTAssertTrue(CatalogALineReader.dayParts(r, visible: []).isEmpty)

        try TimelineStore.mutateMonth("2026-10", in: dir) { $0.days = [r] }
        XCTAssertTrue(RecallTool.searchALine(terms: ["报错"], memoryRoot: root, conversationIds: ["conv-a"]).hits.allSatisfy {
            !$0.text.contains("白天修了报错")
        }, "限定别的窗口时召回不到整天的主调")
        XCTAssertTrue(RecallTool.searchALine(terms: ["白天修了报错"], memoryRoot: root, conversationIds: ["conv-c"]).hits.isEmpty)
        XCTAssertFalse(RecallTool.searchALine(terms: ["白天修了报错"], memoryRoot: root, conversationIds: ["conv-a", "conv-b"]).hits.isEmpty)
    }

    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        func enter() { lock.withLock { active += 1; peak = max(peak, active) } }
        func leave() { lock.withLock { active -= 1 } }
    }

    /// astra #6：同一层排队——在跑的时候来的自动（C3 那次）等它跑完再判（今天跑过 → 不跑），「现在写」等它跑完再跑；从不两趟同时调模型；
    /// 排完登记清掉，第二天照常跑
    func testQueueSerializesWaiters() async throws {
        let w = window("conv-a", "开发", minutes(date(10, 12, 9), 2) + minutes(date(10, 13, 9), 2), segments: [(0..<2, "昨天"), (2..<4, "今天")])
        let gauge = Gauge()
        var i = input([w], Calls())
        i.caller = { _, user in
            gauge.enter()
            try await Task.sleep(nanoseconds: 300_000_000)
            gauge.leave()
            return #"{"headline":"主调\#(user.prefix(10))","topics":[]}"#
        }
        let daily = TimelineDaily()
        let now = date(10, 13, 20)
        let first = Task { await daily.runDue(i, now: now) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let waiter = Task { await daily.runDue(i, now: now) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let manual = Task { await daily.runDue(i, now: now, force: true) }
        let r1 = await first.value, r2 = await waiter.value, r3 = await manual.value
        XCTAssertEqual(r1?.written, ["2026-10-12"])
        XCTAssertNil(r2, "等在途的跑完；今天跑过就不再跑")
        XCTAssertEqual(r3?.written, ["2026-10-13"], "现在写排在后面跑")
        XCTAssertEqual(gauge.peak, 1, "从不同时调模型")
        let next = await daily.runDue(i, now: date(10, 14, 6))
        XCTAssertNotNil(next, "排完登记清掉，不卡住")
    }

    /// astra #7 / 车头 10-22：进度只记「这一天的新记录写成了没有」——没写成的留在待拼里，写成了出队；老待续读不全（有月文件读不了）时
    /// 待续这一步停下、A2 文件指纹不记（下次重扫），日记录照拼（老条目反正不动）
    func testProgressOnlyTracksWrittenDays() async throws {
        try TimelineStore.seedLegacy(legacy(5, "conv-a", "开发"), in: dir)
        let bad = dir.appendingPathComponent("2026-09.md")
        try Data("<!-- entry 坏的 -->\n".utf8).write(to: bad)
        let a = window("conv-a", "开发", minutes(date(10, 5, 9), 2), segments: [(0..<2, "五号")])
        let r = await TimelineDaily.perform(input([a], Calls(), headline: { _ in nil }), now: date(10, 20, 9), force: false)
        XCTAssertTrue(r.blocked?.contains("待续没保全") == true)
        XCTAssertNotNil(r.failed["2026-10-05"])
        XCTAssertEqual(TimelineSourceState.load(dir).dirty, ["2026-10-05"], "没写成留着")
        XCTAssertTrue(TimelineSourceState.load(dir).files.isEmpty)
        XCTAssertEqual(try String(contentsOf: bad, encoding: .utf8), "<!-- entry 坏的 -->\n", "读不了的月文件原样")
        try FileManager.default.removeItem(at: bad)
        let r2 = await TimelineDaily.perform(input([a], Calls()), now: date(10, 20, 9), force: false)
        XCTAssertEqual(r2.written, ["2026-10-05"], "写成了")
        XCTAssertNil(r2.blocked)
        XCTAssertEqual(TimelineSourceState.load(dir).dirty, [], "出队")
        XCTAssertFalse(TimelineSourceState.load(dir).files.isEmpty)
        XCTAssertTrue(PendingStore.isLegacyDone(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root))
    }

    /// astra #8：一段 A2 很晚才落盘、盖到七天以前的日子：按 A2 文件变化标出来，那几天也补拼（起点以前的不碰），全程只有主调调用
    func testLateA2RebuildsOlderDays() async throws {
        let times = (1...10).map { date(10, $0, 9) }
        var w = window("conv-l", "慢窗口", times)
        let calls = Calls()
        let now = date(10, 11, 9)
        let r1 = await TimelineDaily.perform(input([w], calls, startDay: date(10, 2, 5)), now: now, force: false)
        XCTAssertEqual(r1.written, (4...10).map { String(format: "2026-10-%02d", $0) })
        XCTAssertNil(TimelineStore.day("2026-10-03", in: dir))
        w = window("conv-l", "慢窗口", times, segments: [(0..<10, "十天一段")])
        let r2 = await TimelineDaily.perform(input([w], calls, startDay: date(10, 2, 5)), now: now, force: false)
        XCTAssertEqual(r2.written, (2...10).map { String(format: "2026-10-%02d", $0) }, "七天以前的也补；起点以前的 10-01 不碰")
        XCTAssertNil(TimelineStore.day("2026-10-01", in: dir))
        XCTAssertEqual(TimelineStore.day("2026-10-02", in: dir)?.items.map(\.title), ["十天一段"])
        XCTAssertTrue(calls.systems.allSatisfy { $0 == TimelineWriter.systemPrompt })
        let r3 = await TimelineDaily.perform(input([w], calls, startDay: date(10, 2, 5)), now: now, force: false)
        XCTAssertEqual(r3.written, [], "补过的不再补")
    }

    /// astra 二轮 #3：十天前就结束的窗口（当时 A4 关着、没有时间轴），既不在最近几天也没有老条目——扫 A2 文件照样把它的待续搬进本子、
    /// 把那几天拼出来；假读窗口照真接线只给区间里的窗口
    func testOldWindowPendingAndDaysFoundBySourceScan() async throws {
        let w = window("conv-old", "十天前", minutes(date(10, 2, 20), 4), segments: [(0..<4, "那天的事")], pending: "回头问问")
        let recent = window("conv-new", "最近", minutes(date(10, 12, 9), 2), segments: [(0..<2, "昨天的事")])
        let calls = Calls()
        let r = await TimelineDaily.perform(input([w, recent], calls), now: date(10, 13, 9), force: false)
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root)?.map(\.text), ["回头问问"])
        XCTAssertEqual(r.written, ["2026-10-02", "2026-10-12"])
        XCTAssertEqual(TimelineStore.day("2026-10-02", in: dir)?.items.map(\.conversationId), ["conv-old"], "那天只读到它，区间外的窗口没混进来")
    }

    /// astra 二轮 #4：七天以前的一天新落了一段同标题的段（文件变了）→ 那天重拼、指针更新；标题指纹没变 → 不重调主调
    func testSameTitleNewSegmentRebuildsWithoutNewHeadline() async throws {
        let t = minutes(date(10, 2, 9), 2) + minutes(date(10, 2, 15), 2)
        var w = window("conv-a", "开发", t, segments: [(0..<2, "继续调试")])
        let calls = Calls()
        _ = await TimelineDaily.perform(input([w], calls), now: date(10, 20, 9), force: false)
        XCTAssertEqual(calls.users.count, 1)
        XCTAssertEqual(TimelineStore.day("2026-10-02", in: dir)?.items.filter { $0.kind == .segment }.count, 1)
        w = window("conv-a", "开发", t, segments: [(0..<2, "继续调试"), (2..<4, "继续调试")])
        let r = await TimelineDaily.perform(input([w], calls), now: date(10, 20, 9), force: false)
        XCTAssertEqual(r.written, ["2026-10-02"], "来源变了就重拼")
        XCTAssertEqual(calls.users.count, 1, "标题没变不重调主调")
        XCTAssertEqual(TimelineStore.day("2026-10-02", in: dir)?.items.filter { $0.kind == .segment }.map(\.to), ["conv-a-1", "conv-a-3"])
        XCTAssertEqual(TimelineStore.day("2026-10-02", in: dir)?.headline, "主调：2026-10-02")
    }

    /// astra 二轮 #7：搬进来的待续她改了字、标了做完；尾段后来重写（文件变了、同一句待续还在）→ 不再搬一遍
    func testEditedPendingNotHarvestedAgain() async throws {
        var w = window("conv-a", "开发", minutes(date(10, 12, 9), 3), segments: [(0..<3, "尾段")], kind: .closeout, tail: true, pending: "买药")
        _ = await TimelineDaily.perform(input([w], Calls()), now: date(10, 13, 9), force: false)
        try PendingStore.mutate(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root) { items in
            items[0].text = "买感冒药"
            items[0].state = .done
        }
        w = with(w) { $0.segments[0].title = "尾段重写了" }
        let r = await TimelineDaily.perform(input([w], Calls()), now: date(10, 13, 9, 30), force: false)
        XCTAssertEqual(r.pendingAdded, 0)
        let items = try XCTUnwrap(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid), memoryRoot: root))
        XCTAssertEqual(items.map(\.text), ["买感冒药"])
        XCTAssertEqual(items[0].state, .done)
    }

    private final class Counter: @unchecked Sendable {
        var local = 0
        var remote = 0
    }

    /// astra #10 #11：本机放不下完整输入就不走本机（不拿裁过的写）；本机报错 / 回来解析不了退到提取模型；主动取消 / 被打断不退
    func testLocalFallsBackToExtractModel() async throws {
        let w = window("conv-a", "开发", minutes(date(10, 12, 9), 2), segments: [(0..<2, "修报错")])
        let n = Counter()
        func run(_ ww: TimelineSkeleton.Window, _ localCall: @escaping SessionSegmentWriter.Caller) async -> TimelineDaily.Report {
            try? FileManager.default.removeItem(at: dir)
            var i = input([ww], Calls())
            i.caller = { s, u in n.local += 1; return try await localCall(s, u) }
            i.fallback = { _, _ in n.remote += 1; return #"{"headline":"提取模型写的","topics":[]}"# }
            return await TimelineDaily.perform(i, now: date(10, 13, 9), modes: ["2026-10-12": .daily], scan: false)
        }
        var r = await run(w) { _, _ in #"{"headline":"本机写的","topics":[]}"# }
        XCTAssertEqual([n.local, n.remote, r.fellBack], [1, 0, 0])
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir)?.headline, "本机写的")

        r = await run(w) { _, _ in throw MemoryWriterError.format("本机挂了") }
        XCTAssertEqual([n.local, n.remote, r.fellBack], [2, 1, 1])
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: dir)?.headline, "提取模型写的")

        r = await run(w) { _, _ in "<think>想了半天没想完" }
        XCTAssertEqual([n.local, n.remote, r.fellBack], [3, 2, 1])

        r = await run(w) { _, _ in throw CancellationError() }
        XCTAssertEqual([n.local, n.remote], [4, 2], "主动取消不退")
        XCTAssertNotNil(r.failed["2026-10-12"])

        r = await run(w) { _, _ in throw FragmentPoolError.interrupted }
        XCTAssertEqual([n.local, n.remote], [5, 2], "被停下 / 进后台不退")

        let long = (0..<3).map { "很长的标题\($0)" + String(repeating: "长", count: 2500) }
        let big = window("conv-b", "长", minutes(date(10, 12, 9), 6), segments: [(0..<2, long[0]), (2..<4, long[1]), (4..<6, long[2])])
        r = await run(big) { _, _ in #"{"headline":"本机写的","topics":[]}"# }
        XCTAssertEqual([n.local, n.remote, r.fellBack], [5, 3, 1], "放不下就不调本机")
        XCTAssertFalse(TimelineDaily.localFits(system: TimelineWriter.systemPrompt, user: TimelineWriter.userContent(date: "2026-10-12", titles: long)))
    }
}
