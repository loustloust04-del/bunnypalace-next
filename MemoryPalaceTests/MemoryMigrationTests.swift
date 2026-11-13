import MemoryCore
import XCTest
@testable import 记忆花园

/// plan-memory-migrate-3gen M2–M8 / B4：真跑一遍搬迁（假写手、测试楼层），三代各一个窗口 + 已经是新样子的一个。
/// c2c3-v2 第 7 段起搬迁不碰时间轴（A4 一天一条由 `TimelineDaily` 按日重拼）
final class MemoryMigrationTests: XCTestCase {

    let pid = "xctest-mig3"
    private var root: URL { FileLibraryStore.memoryRoot(profileId: pid) }
    private let cal = Calendar.current
    private let speakers = SessionSegmentWriter.Speakers(userName: "粟粟", assistantName: "小克")
    private var startDay: Date { date(10, 1, 5) }
    private var now: Date { date(10, 16, 21) }

    // 窗口编号前 8 位各不一样（文件名靠它）
    private let g1pre = "g1pre-01-aaaa", g1post = "g1post01-aaaa", g2cut = "g2cut-01-aaaa", g2v41 = "g2v41-01-aaaa", g3v5 = "g3v5-001-aaaa"

    override func setUpWithError() throws {
        cleanup()
    }

    override func tearDownWithError() throws {
        cleanup()
    }

    private func cleanup() {
        MemoryWriteLog.flush()
        PendingStore.forget(profileId: pid)
        UserDefaults.standard.removeObject(forKey: PendingStore.migratedKey(profileId: pid))
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    private func msgs(_ n: Int, from start: Date, prefix: String) -> [SessionSegmentWriter.Message] {
        (0..<n).map { .init(id: "\(prefix)\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "第\($0)条",
                            date: start.addingTimeInterval(TimeInterval($0) * 60)) }
    }

    private func seg(_ kind: SessionSegment.Kind, _ m: [SessionSegmentWriter.Message], _ r: Range<Int>, title: String,
                     pending: String = "", tail: Bool = false) -> SessionSegment {
        SessionSegment(kind: kind, title: title, start: m[r.lowerBound].date!, end: m[r.upperBound - 1].date!, from: r.lowerBound,
                       to: r.upperBound, lastNodeId: m[r.upperBound - 1].id, story: "老经过", quotes: "", pending: pending, isTail: tail)
    }

    // MARK: - 夹具

    private var sources: [String: MemoryRegeneration.Source] = [:]

    /// 第一代（起点以前 / 起点以后各一个）、第二代上半（第三刀）、第二代下半（v4-1 抄本）、第三代（v5）
    private func seedThreeGens() throws {
        let sessions = SessionSummaryStore.dir(root: root), tl = TimelineStore.dir(root: root)
        // 第一代 · 起点以前，只有 summaries/
        let a = msgs(10, from: date(9, 20, 9), prefix: "a")
        SummaryFileStore.save(ContextSummary(summary: "第一代老摘要 · 早", coveredCount: 10, updatedAt: date(9, 20, 12)),
                              conversationId: g1pre, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "早")
        // 第一代 · 起点以后还在聊
        let b = msgs(10, from: date(9, 20, 9), prefix: "b") + msgs(20, from: date(10, 5, 9), prefix: "c")
        SummaryFileStore.save(ContextSummary(summary: "第一代老摘要 · 晚", coveredCount: 10, updatedAt: date(9, 20, 12)),
                              conversationId: g1post, memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), conversationTitle: "晚")
        // 第二代上半：第三刀压缩段（带【待续】）+ 老收尾段；时间轴只有一条老格式
        let d = msgs(100, from: date(10, 3, 9), prefix: "d")
        try SessionSummaryStore.save(SessionSummary(conversationId: g2cut, title: "第三刀", compressedCount: 60,
                                                    segments: [seg(.rolling, d, 0..<60, title: "这个窗口……", pending: "仍未问到"),
                                                               seg(.closeout, d, 60..<80, title: "老收尾")],
                                                    updatedAt: date(10, 3, 12)), in: sessions)
        try TimelineStore.write([TimelineEntry(start: date(10, 3, 9), end: date(10, 3, 11), conversationId: g2cut, title: "第三刀",
                                               text: "老的一大段", pending: "")], month: "2026-10", in: tl)
        // 第二代下半：v4-1 抄本
        let e = msgs(80, from: date(10, 4, 9), prefix: "e")
        try SessionSummaryStore.save(SessionSummary(conversationId: g2v41, title: "抄本", compressedCount: 60,
                                                    segments: [seg(.rolling, e, 0..<60, title: "压缩")], updatedAt: date(10, 4, 12)), in: sessions)
        try WindowSummaryStore.save(SessionSummary(conversationId: g2v41, title: "抄本", compressedCount: 60,
                                                   segments: [seg(.rolling, e, 0..<60, title: "压缩"), seg(.closeout, e, 60..<80, title: "最后那截")],
                                                   updatedAt: e[79].date!, closedThrough: "e79"), in: root)
        try TimelineStore.seedLegacy(TimelineEntry(start: date(10, 4, 9), end: e[79].date!, conversationId: g2v41, title: "抄本", text: "- 话题",
                                               pending: "", day: "2026-10-04", lastNodeId: "e79"), in: tl)
        // 第三代：已经是新样子
        let f = msgs(80, from: date(10, 6, 9), prefix: "f")
        try SessionSummaryStore.save(SessionSummary(conversationId: g3v5, title: "新样子", compressedCount: 60,
                                                    segments: [seg(.rolling, f, 0..<60, title: "压缩"), seg(.closeout, f, 60..<80, title: "尾", tail: true)],
                                                    updatedAt: date(10, 6, 12)), in: sessions)
        try WindowSummaryStore.save(SessionSummary(conversationId: g3v5, title: "新样子", compressedCount: 60,
                                                   segments: [seg(.closeout, f, 0..<80, title: "整窗")], updatedAt: f[79].date!,
                                                   closedThrough: "f79"), in: root)
        try TimelineStore.seedLegacy(TimelineEntry(start: date(10, 6, 9), end: f[79].date!, conversationId: g3v5, title: "新样子", text: "- 话题",
                                               pending: "", day: "2026-10-06", lastNodeId: "f79"), in: tl)
        sources = [g1pre: .init(title: "早", messages: a, isCC: false), g1post: .init(title: "晚", messages: b, isCC: false),
                   g2cut: .init(title: "第三刀", messages: d, isCC: false), g2v41: .init(title: "抄本", messages: e, isCC: false),
                   g3v5: .init(title: "新样子", messages: f, isCC: false)]
    }

    /// 真实接线从库里查「起点以后动过的」；这里给起点以后还有消息的那几个（起点以前那个靠 summaries/ 找到）+ 单个测试加的
    private var extra: [String] = []
    private func candidates(_ scope: Date?) -> [String] { [g1post, g2cut, g2v41, g3v5] + extra }

    /// 再加一个 v4-1 抄本窗口（尾段 + A3），最后一条在 10 月 day 号
    private func addV41(_ id: String, title: String, day: Int) throws {
        let m = msgs(80, from: date(10, day, 9), prefix: "\(id.prefix(2))-")
        try SessionSummaryStore.save(SessionSummary(conversationId: id, title: title, compressedCount: 60,
                                                    segments: [seg(.rolling, m, 0..<60, title: "压缩")], updatedAt: date(10, day, 12)),
                                     in: SessionSummaryStore.dir(root: root))
        try TimelineStore.seedLegacy(TimelineEntry(start: m[0].date!, end: m[79].date!, conversationId: id, title: title, text: "- 话题",
                                               pending: "", day: "2026-10-\(String(format: "%02d", day))", lastNodeId: m[79].id),
                                 in: TimelineStore.dir(root: root))
        sources[id] = .init(title: title, messages: m, isCC: false)
        extra.append(id)
    }

    // MARK: - 假写手

    private final class Log {
        var calls: [(writer: SessionCloseout.Writer, kind: String, conv: String)] = []
    }

    enum Reply { case good, none, text(String) }

    private func kind(_ system: String) -> String {
        if system.contains("「窗口总结」") { return "window" }
        if system.contains("尾段") { return "tail" }
        return "context"
    }

    private let goodSegment = "标题：新段\n【经过】接着聊\n【原话】粟粟：「嗯」"

    private func writers(_ log: Log, _ answer: @escaping (String, String, Int) throws -> Reply = { _, _, _ in .good }) -> MemoryMigration.Writers {
        .init(persona: "", speakers: speakers) { writer, conv in
            { system, _ in
                let k = self.kind(system)
                log.calls.append((writer, k, conv))
                switch try answer(k, conv, log.calls.count) {
                case .good: return k == "window" ? "标题：新段\n【走向】转向北门\n【原话】粟粟：「嗯」\n【关键词】北门" : self.goodSegment
                case .none: return nil
                case .text(let t): return t
                }
            }
        }
    }

    private let price: MemoryMigration.Price = { _, input, output in Double(input + output) / 1_000_000 }

    /// at = 这一趟的时间（备份文件夹按秒命名，同一个测试里跑第二趟要换一个）
    private func run(_ w: MemoryMigration.Writers, at: Date? = nil, copy: MemoryRegeneration.FileOp = MemoryMigration.cancellableCopy,
                     fault: @escaping MemoryMigration.Fault = { _, _ in }, callTimeout: TimeInterval = MemoryMigration.callTimeout,
                     progress: @escaping (MemoryMigration.Progress) -> Void = { _ in }) async throws -> MemoryMigration.Report {
        try await MemoryMigration.run(profileId: pid, startDay: startDay, now: at ?? now, writers: w, price: price,
                                      candidates: candidates, source: { self.sources[$0] }, copy: copy, fault: fault,
                                      callTimeout: callTimeout, progress: progress)
    }

    private func survey() -> MemoryMigration.Survey {
        MemoryMigration.survey(profileId: pid, startDay: startDay, now: now, persona: "", speakers: speakers, price: price,
                               candidates: candidates, source: { self.sources[$0] })
    }

    // MARK: - 读盘

    private func a2(_ id: String) -> SessionSummary? { SessionSummaryStore.load(conversationId: id, in: SessionSummaryStore.dir(root: root)) }
    private func a3(_ id: String) -> SessionSummary? { WindowSummaryStore.load(conversationId: id, in: root) }
    private func entries(_ id: String) -> [TimelineEntry] {
        let tl = TimelineStore.dir(root: root)
        return TimelineStore.months(in: tl).flatMap { TimelineStore.entries(month: $0, in: tl) }.filter { $0.conversationId == id }
    }
    private func pending(_ id: String) -> [String] {
        PendingStore.forget(profileId: pid)
        return (PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) ?? []).filter { $0.conversationId == id }.map(\.text)
    }

    /// 一个窗口在盘上的全部样子（A2 / A3 文件原文 + 时间轴条目 + 待续）
    private func windowFiles(_ id: String) -> [String] {
        var out: [String] = []
        for dir in [SessionSummaryStore.dir(root: root), WindowSummaryStore.dir(root: root)] {
            if let url = SessionSummaryStore.fileURL(conversationId: id, in: dir) {
                out.append((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            } else {
                out.append("（没有）")
            }
        }
        out += entries(id).map { "\($0.dayKey)|\($0.text)|\($0.pending)" }
        out += pending(id)
        return out
    }

    private func snapshotFive() -> [String: String] {
        var out: [String: String] = [:]
        for f in MemoryMigration.folders {
            let dir = root.appendingPathComponent(f)
            for rel in ((try? MemoryRegeneration.inventory(dir)) ?? [:]).keys {
                out[f + "/" + rel] = try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)
            }
        }
        return out
    }

    private struct Injected: Error {}

    private func marker(_ id: String) throws -> MemoryMigration.Marker? { try MemoryMigration.loadMarker(id, memoryRoot: root) }

    // MARK: - 测

    func testCrossDayEstimateMatchesActualFormalAndTailCalls() async throws {
        for (kind, anchor) in [(MemoryMigration.Kind.a2Full, 30), (.tailA3, 0)] {
            let id = kind == .a2Full ? "crossformal-01" : "crosstail-01"
            let messages = msgs(20, from: date(10, 3, 4, 50), prefix: "a")
                + msgs(60, from: date(10, 4, 4, 30), prefix: "b")
            let old = SessionSummary(conversationId: id, title: "云桥城", compressedCount: anchor,
                                     segments: anchor == 0 ? [] : [seg(.rolling, messages, 0..<anchor, title: "旧段")], updatedAt: now)
            let state = MemoryMigration.State(a2: old, a2OnDisk: false, a3: nil)
            let source = MemoryRegeneration.Source(title: "云桥城", messages: messages, isCC: false)
            let plan = MemoryMigration.Plan(kind: kind)
            let estimate = MemoryMigration.estimateCalls(plan, state: state, source: source, scope: startDay, now: now,
                                                        persona: "", speakers: speakers)
            let log = Log()
            try await MemoryMigration.migrateWindow(id: id, source: source, state: state, plan: plan, scope: startDay, now: now,
                                                    profileId: pid, writers: writers(log), counter: .init())
            XCTAssertEqual(estimate.map(\.writer), log.calls.map(\.writer), "\(kind)")
            XCTAssertEqual(estimate.count, kind == .a2Full ? 5 : 4)
            let written = try XCTUnwrap(a2(id))
            XCTAssertTrue(written.segments.allSatisfy { MemoryDay.key($0.start) == MemoryDay.key($0.end) })
            XCTAssertEqual(written.segments.last?.lastNodeId, messages.last?.id)
        }
    }

    /// 三代各搬成 v5 的样子；各写手用自己的 caller（M5）；估的次数和真调的一样（M8）；结果写进备份（B4）
    func testThreeGenerationsMigrate() async throws {
        try seedThreeGens()
        let v5Before = windowFiles(g3v5)
        let s = survey()
        XCTAssertEqual(s.windows.map(\.id), [g1pre, g2cut, g2v41, g1post], "按最后一条消息先后")
        XCTAssertEqual(s.windows.map(\.plan), [.init(kind: .seedOnly), .init(kind: .a2Full), .init(kind: .tailA3), .init(kind: .tailA3)])
        XCTAssertEqual([s.tailA3, s.a2, s.seedOnly, s.skipped], [2, 1, 1, 1])
        XCTAssertEqual(s.windows.map(\.calls), [0, 3, 2, 2], "不再算时间轴的调用")
        XCTAssertEqual(s.displayCalls, 9, "7 × 1.15 往上取整")
        XCTAssertEqual(s.priciest.first?.id, g2cut)

        let log = Log()
        let report = try await run(writers(log))
        XCTAssertEqual(report.failures, [])
        XCTAssertNil(report.stopped)
        XCTAssertEqual(report.done, 4)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(log.calls.count, s.calls, "估算和实际调用次数一致")
        for c in log.calls {
            switch c.kind {
            case "context", "tail": XCTAssertEqual(c.writer, .context, "\(c)")
            default: XCTAssertEqual(c.writer, .window, "\(c)")
            }
        }

        // 第一代 · 起点以前：落成第 0 段，原文一字不改，不花钱
        XCTAssertEqual(a2(g1pre)?.segments.map(\.kind), [.legacy])
        XCTAssertEqual(a2(g1pre)?.segments.first?.story, "第一代老摘要 · 早")
        XCTAssertNil(a3(g1pre))
        // 第一代 · 起点以后：第 0 段 + 尾段；A3 一段；时间轴不补（交给 A4 一天一条）
        XCTAssertEqual(a2(g1post)?.segments.map(\.kind), [.legacy, .closeout])
        XCTAssertEqual(a2(g1post)?.segments.last?.isTail, true)
        XCTAssertEqual(a3(g1post)?.segments.count, 1)
        XCTAssertEqual(a3(g1post)?.closedThrough, "c19")
        XCTAssertEqual(entries(g1post), [])
        // 第三刀：老式段和老收尾段都没了，补成正式段 + 尾段；老格式时间轴原样、待续本子不动
        let cut = try XCTUnwrap(a2(g2cut))
        XCTAssertEqual(cut.segments.map(\.title), ["新段", "新段"])
        XCTAssertEqual(cut.segments.map(\.isTail), [false, true])
        XCTAssertTrue(cut.segments.allSatisfy { $0.pending.isEmpty }, "老式段的【待续】不搬")
        XCTAssertEqual(cut.compressedCount, 60)
        XCTAssertEqual(a3(g2cut)?.segments.count, 1)
        XCTAssertEqual(entries(g2cut).map(\.text), ["老的一大段"], "搬迁不碰时间轴")
        XCTAssertEqual(pending(g2cut), ["仍未问到"], "车头 10-22 先保全后覆盖：老式段被重写之前，它的【待续】先进本子")
        // v4-1 抄本：A2 多了尾段，A3 换成一段
        XCTAssertEqual(a2(g2v41)?.segments.map(\.isTail), [false, true])
        XCTAssertEqual(a3(g2v41)?.segments.map(\.from), [0])
        XCTAssertEqual(entries(g2v41).map(\.text), ["- 话题"], "已经有 v2 的时间轴不动")
        // v5：一个字不动
        XCTAssertEqual(windowFiles(g3v5), v5Before)

        // B4：结果在备份文件夹里，写清老段在哪
        let saved = try String(contentsOf: report.backup.appendingPathComponent(MemoryMigration.resultFileName), encoding: .utf8)
        XCTAssertEqual(saved, MemoryMigration.resultText(report))
        XCTAssertTrue(saved.contains("被换下来的老段、老抄本都在备份「\(report.backup.lastPathComponent)」里"))
        XCTAssertTrue(report.backup.lastPathComponent.hasPrefix(MemoryMigration.backupPrefix))
        XCTAssertEqual(MemoryRegeneration.manifest(of: report.backup)?.covered, MemoryMigration.folders)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: MemoryRegeneration.backupRoot(memoryRoot: root).path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("staging-") }, "暂存目录清掉")

        // 再点一次：都是新样子了，不调模型
        let again = Log()
        let second = try await run(writers(again), at: date(10, 16, 22))
        XCTAssertEqual(again.calls.count, 0)
        XCTAssertEqual(second.done, 0)
    }

    /// M6：一个窗口中途写坏（A3 两次格式都不对）→ 这个窗口一个字不改；后面的窗口照搬
    func testWindowFailureLeavesThatWindowUntouched() async throws {
        try seedThreeGens()
        let before = windowFiles(g2cut)
        let report = try await run(writers(Log()) { k, conv, _ in
            conv == self.g2cut && k == "window" ? .text("（想了很久）……") : .good
        })
        XCTAssertEqual(report.failures.count, 1, "失败应记入结果，不钉诊断措辞")
        XCTAssertTrue(report.failures[0].contains("窗口总结：格式不对"))
        XCTAssertTrue(report.failures[0].contains("原样留着"))
        XCTAssertEqual(windowFiles(g2cut), before, "A2 已经在内存里写好了也不提交")
        XCTAssertEqual(report.done, 3)
        XCTAssertEqual(a3(g2v41)?.segments.count, 1, "后面的窗口照搬")
    }

    /// M6：上次提交到一半被杀（A2 尾段已经换上、A3 还是 v4-1 抄本）→ 再跑分进要搬，只补 A3，不重写尾段
    func testHalfCommittedWindowCompletesOnRerun() async throws {
        try seedThreeGens()
        let e = try XCTUnwrap(sources[g2v41]).messages
        try SessionSummaryStore.save(SessionSummary(conversationId: g2v41, title: "抄本", compressedCount: 60,
                                                    segments: [seg(.rolling, e, 0..<60, title: "压缩"),
                                                               seg(.closeout, e, 60..<80, title: "已提交的尾段", tail: true)],
                                                    updatedAt: date(10, 16, 20)), in: SessionSummaryStore.dir(root: root))
        XCTAssertEqual(survey().windows.first { $0.id == g2v41 }?.plan, .init(kind: .tailA3))
        let log = Log()
        _ = try await run(writers(log))
        XCTAssertEqual(log.calls.filter { $0.conv == g2v41 }.map(\.kind), ["window"])
        XCTAssertEqual(a2(g2v41)?.segments.last?.title, "已提交的尾段")
        XCTAssertEqual(a3(g2v41)?.segments.count, 1)
    }

    /// M5：连着 3 个窗口写手跳过（预算闸 / 没回内容）→ 停，说是预算的事；这几个窗口原样
    func testThreeSkipsInARowStop() async throws {
        try seedThreeGens()
        let before = [g2cut, g2v41, g1post].map(windowFiles)
        let report = try await run(writers(Log()) { _, _, _ in .none })
        XCTAssertEqual(report.done, 1, "只有不花钱的第 0 段落了")
        XCTAssertEqual(report.failures.count, 3)
        XCTAssertTrue(report.failures.allSatisfy { $0.contains("被预算闸拦下或模型没回内容") })
        XCTAssertTrue(report.stopped?.contains("连着 3 个窗口被预算闸拦下或模型没回内容") == true, "\(report.stopped ?? "")")
        XCTAssertEqual([g2cut, g2v41, g1post].map(windowFiles), before)
    }

    /// M7：断网 → 停在当前窗口之前：前面搬好的留着，这个和后面的没动；再点一次只搬剩下的
    func testNetworkDropStopsAndResumes() async throws {
        try seedThreeGens()
        let before = [g2v41, g1post].map(windowFiles)
        let report = try await run(writers(Log()) { _, conv, _ in
            if conv == self.g2v41 { throw URLError(.notConnectedToInternet) }
            return .good
        })
        XCTAssertEqual(report.stopped, MemoryMigration.stopText(at: 3, name: "《抄本》", cancelled: false))
        XCTAssertEqual(report.done, 2)
        XCTAssertEqual(a3(g2cut)?.segments.count, 1, "前面搬好的留着")
        XCTAssertEqual([g2v41, g1post].map(windowFiles), before, "这个和后面的没动")

        let log = Log()
        let second = try await run(writers(log), at: date(10, 16, 22))
        XCTAssertEqual(Set(log.calls.map(\.conv)), [g2v41, g1post], "只搬剩下的")
        XCTAssertEqual(second.done, 2)
    }

    /// M7：〔停下〕= 取消任务：停在当前窗口之前
    func testStopButtonCancels() async throws {
        try seedThreeGens()
        let w = writers(Log()) { _, conv, _ in
            if conv == self.g2v41 {
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
            return .good
        }
        let report = try await Task { try await self.run(w) }.value
        XCTAssertEqual(report.stopped, MemoryMigration.stopText(at: 3, name: "《抄本》", cancelled: true))
        XCTAssertNil(a3(g1post), "后面的没动")
    }

    /// B1：备份核不上 → 抛错、一个字不改、不调模型
    func testBackupMismatchChangesNothing() async throws {
        try seedThreeGens()
        let before = snapshotFive()
        let log = Log()
        let truncating: MemoryRegeneration.FileOp = { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            if from.lastPathComponent == SessionSummaryStore.folder, let name = try FileManager.default.contentsOfDirectory(atPath: to.path).first {
                try Data("坏".utf8).write(to: to.appendingPathComponent(name))
            }
        }
        do {
            _ = try await run(writers(log), copy: truncating)
            XCTFail("备份核不上应该抛")
        } catch MemoryRegeneration.RegenError.backupMismatch {}
        XCTAssertEqual(snapshotFive(), before)
        XCTAssertEqual(log.calls.count, 0)
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).isEmpty)
    }

    // MARK: - astra 一轮（2026-10-16）

    /// #2：提交全做完、只差删标记时被杀（撤回也没做完）→ 标记留着；再点一次先按标记撤回，再从原样重搬
    func testHalfCommitMarkerIsRolledBackAndRedoneOnRerun() async throws {
        try seedThreeGens()
        let first = try await run(writers(Log()), fault: { id, step in
            if id == self.g2cut, step == "完成" || step == "撤回" { throw Injected() }
        })
        XCTAssertTrue(first.failures.contains { $0.hasPrefix("《第三刀》第 5 步 提交") && $0.contains("撤回也没做完") }, "\(first.failures)")
        let m = try XCTUnwrap(try marker(g2cut))
        XCTAssertTrue(m.a2Touched && m.a3Touched)
        XCTAssertTrue(m.months.isEmpty && m.addedPending.isEmpty, "不碰时间轴 / 待续")
        XCTAssertNotNil(survey().windows.first { $0.id == g2cut }, "有标记的窗口算要搬")

        let log = Log()
        let second = try await run(writers(log), at: date(10, 16, 22))
        XCTAssertEqual(second.failures, [])
        XCTAssertNil(try marker(g2cut))
        XCTAssertTrue(log.calls.contains { $0.conv == g2cut && $0.kind == "context" }, "撤回到原样再重搬（A2 从头补）")
        XCTAssertEqual(entries(g2cut).map(\.text), ["老的一大段"])
        XCTAssertEqual(a2(g2cut)?.segments.map(\.isTail), [false, true])
        XCTAssertEqual(a3(g2cut)?.segments.count, 1)
    }

    /// 改版前留下的「正在搬」标记（还记着时间轴月份和加进待续的）照样能撤：月份换回原来的条目、这次加的待续删掉，新的一天一条不丢
    func testOldMarkerWithTimelineIsStillRolledBack() async throws {
        try seedThreeGens()
        let tl = TimelineStore.dir(root: root)
        let original = TimelineEntry(start: date(10, 3, 9), end: date(10, 3, 11), conversationId: g2cut, title: "第三刀", text: "老的一大段", pending: "")
        try TimelineStore.mutateMonth("2026-10", in: tl) { m in
            m.entries = m.entries.filter { $0.conversationId != self.g2cut }
                + [TimelineEntry(start: date(10, 3, 9), end: date(10, 3, 11), conversationId: g2cut, title: "第三刀", text: "- 半成品",
                                 pending: "", day: "2026-10-03", lastNodeId: "d79")]
            m.days = [TimelineDayRecord(date: "2026-10-12", headline: "一句", items: [])]
        }
        let added = try PendingStore.add(["半成品加的"], conversationId: g2cut, day: "2026-10-03", anchor: nil, profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        var old = MemoryMigration.Marker(conversationId: g2cut)
        old.months = ["2026-10": TimelineStore.render([original], month: "2026-10")]
        old.addedPending = added.map { .init(id: $0.id, text: $0.text) }
        try MemoryMigration.saveMarker(old, memoryRoot: root)
        _ = try await run(writers(Log()))
        XCTAssertEqual(entries(g2cut).map(\.text), ["老的一大段"], "月份换回原来的条目")
        XCTAssertEqual(pending(g2cut), ["仍未问到"], "这次加的待续删掉；覆盖前保全的旧段待续留着（只增不减）")
        XCTAssertEqual(TimelineStore.day("2026-10-12", in: tl)?.headline, "一句", "新的一天一条原样")
        XCTAssertNil(try marker(g2cut))
    }

    /// #2：提交半路写盘失败 → 当场按标记撤回：已经换上的 A2 / A3 都回到原样，标记删掉
    func testCommitFailureRollsBackOnTheSpot() async throws {
        try seedThreeGens()
        let before = windowFiles(g2cut)
        let report = try await run(writers(Log()), fault: { id, step in
            if id == self.g2cut, step == "完成" { throw Injected() }
        })
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("《第三刀》第 5 步 提交") && $0.contains("已经撤回") }, "\(report.failures)")
        XCTAssertEqual(windowFiles(g2cut), before + ["仍未问到"], "A2 / A3 / 时间轴回到原样；覆盖前保全的旧段待续留在本子里（只增不减）")
        XCTAssertNil(try marker(g2cut))
        XCTAssertEqual(report.done, 3)
    }

    /// #3：要拿掉的老收尾段在主线上找不到（切过分支）→ 补不上，这个窗口不搬、列进没成
    func testUnlocatableOldSegmentWindowLeftAlone() async throws {
        try seedThreeGens()
        let id = "g2lost01-aaaa"
        let m = msgs(60, from: date(10, 7, 9), prefix: "l")
        var lost = seg(.closeout, m, 20..<40, title: "别的分支")
        lost.lastNodeId = "不在主线上"
        try SessionSummaryStore.save(SessionSummary(conversationId: id, title: "切过分支", compressedCount: 60,
                                                    segments: [seg(.rolling, m, 0..<20, title: "压缩"), lost, seg(.rolling, m, 40..<60, title: "压缩")],
                                                    updatedAt: date(10, 7, 12)), in: SessionSummaryStore.dir(root: root))
        sources[id] = .init(title: "切过分支", messages: m, isCC: false)
        extra.append(id)
        let before = windowFiles(id)
        XCTAssertTrue(survey().broken.contains { $0.hasPrefix("《切过分支》上下文摘要补不上") }, "\(survey().broken)")
        let report = try await run(writers(Log()))
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("《切过分支》上下文摘要补不上") }, "\(report.failures)")
        XCTAssertEqual(windowFiles(id), before)
    }

    /// 搬迁不碰时间轴：跨起点的、起点以后的老条目都原样
    func testMigrationLeavesTimelineAlone() async throws {
        try seedThreeGens()
        let cross = TimelineEntry(start: date(9, 30, 20), end: date(10, 3, 10), conversationId: g2cut, title: "第三刀", text: "跨起点的老条目", pending: "")
        try TimelineStore.seedLegacy(cross, in: TimelineStore.dir(root: root))
        _ = try await run(writers(Log()))
        XCTAssertEqual(Set(entries(g2cut).map(\.text)), ["跨起点的老条目", "老的一大段"])
    }

    /// #9：sessions/ 文件读得出但格式对不上 → 这个窗口不搬、原件一字不动、报路径
    func testCorruptA2FileIsNotOverwritten() async throws {
        try seedThreeGens()
        let url = try XCTUnwrap(SessionSummaryStore.fileURL(conversationId: g2v41, in: SessionSummaryStore.dir(root: root)))
        let bad = "---\nconversationId: \(g2v41)\ntitle: 抄本\n---\n<!-- seg kind=rolling from=0 to=60 -->\n段头丢了"
        try Data(bad.utf8).write(to: url)
        let report = try await run(writers(Log()))
        XCTAssertTrue(report.failures.contains { $0.hasPrefix("《抄本》格式对不上") && $0.contains(url.lastPathComponent) }, "\(report.failures)")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), bad)
        XCTAssertEqual(a3(g2v41)?.segments.count, 2, "A3 也没动")
        XCTAssertEqual(report.done, 3)
    }

    /// #9：时间轴月文件有一条认不出 → 搬迁不读不写时间轴，照搬；月文件一字不动
    func testCorruptTimelineMonthIsUntouched() async throws {
        try seedThreeGens()
        let url = TimelineStore.dir(root: root).appendingPathComponent("2026-10.md")
        let bad = try String(contentsOf: url, encoding: .utf8) + "\n\n## 坏条目\n<!-- entry start=2026-10-03T10:00:00Z -->\n没有窗口编号"
        try Data(bad.utf8).write(to: url)
        let report = try await run(writers(Log()))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), bad)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(a3(g2cut)?.segments.count, 1)
    }

    /// #12：最后一个窗口的最后一次调用回来以后点了停（写手不因取消抛错）→ 不提交，如实写停在哪
    func testStopAfterLastCallDoesNotCommit() async throws {
        try seedThreeGens()
        let before = windowFiles(g1post)
        // 10-16：每次调用套了超时（在子任务里跑），写手里取消「当前任务」只取消那个子任务——按〔停下〕的真路径取消整趟
        final class Handle { var task: Task<MemoryMigration.Report, Error>? }
        let handle = Handle()
        let w = writers(Log()) { k, conv, _ in
            if conv == self.g1post, k == "window" { handle.task?.cancel() }
            return .good
        }
        handle.task = Task { try await self.run(w) }
        let report = try await handle.task!.value
        XCTAssertEqual(report.stopped, MemoryMigration.stopText(at: 4, name: "《晚》", cancelled: true))
        XCTAssertEqual(windowFiles(g1post), before)
    }

    /// #14：被拦 / 格式不对 / 被拦 / 格式不对 / 被拦 —— 不是「连着 3 个被拦」，不停
    func testInterleavedFailuresAreNotInARow() async throws {
        try seedThreeGens()
        try addV41("x1v41-01-aaaa", title: "甲", day: 7)
        try addV41("x2v41-01-aaaa", title: "乙", day: 8)
        let bad = Reply.text("（想了很久）……")
        let pattern: [String: Reply] = [g2cut: .none, g2v41: bad, g1post: .none, "x1v41-01-aaaa": bad, "x2v41-01-aaaa": .none]
        let report = try await run(writers(Log()) { _, conv, _ in pattern[conv] ?? .good })
        XCTAssertNil(report.stopped, "\(report.stopped ?? "")")
        XCTAssertEqual(report.failures.count, 5)
    }

    // MARK: - 10-16 卡住修补

    /// 写手：conv 在 hang 里的那几个一直不回（被取消才退），别的照常
    private func hanging(_ hang: Set<String>) -> MemoryMigration.Writers {
        let good = writers(Log())
        return .init(persona: "", speakers: speakers) { writer, conv in
            let inner = good.caller(writer, conv)
            return { system, user in
                if hang.contains(conv) { try await Task.sleep(nanoseconds: 30_000_000_000) }
                return try await inner(system, user)
            }
        }
    }

    /// B：一次调用超时 → 这个窗口原样、算出错、接着搬下一个；结果文件写明哪个窗口超时
    func testCallTimeoutLeavesWindowAndMovesOn() async throws {
        try seedThreeGens()
        let before = windowFiles(g2cut)
        let t0 = Date()
        let report = try await run(hanging([g2cut]), callTimeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10, "超时就放手，不等那次调用回来")
        XCTAssertEqual(report.failures, ["《第三刀》第 2 步 上下文摘要：出错（模型 0.5 秒没回完，超时），这个窗口原样留着"])
        XCTAssertNil(report.stopped)
        XCTAssertEqual(windowFiles(g2cut), before)
        XCTAssertNil(try marker(g2cut), "没进提交，没有正在搬标记")
        XCTAssertEqual(report.done, 3)
        XCTAssertEqual(a3(g2v41)?.segments.count, 1, "下一个窗口照搬")
        let saved = try String(contentsOf: report.backup.appendingPathComponent(MemoryMigration.resultFileName), encoding: .utf8)
        XCTAssertTrue(saved.contains("《第三刀》第 2 步 上下文摘要：出错（模型 0.5 秒没回完，超时）"))
    }

    /// 10-16 手搬演练：注入 memoryRoot → A2 / A3、备份和结果文件全落在注入的根上（时间轴 / 待续本子不碰）；
    /// 这一层的真根一个文件不多，待续缓存和「迁移过」标记也不动
    func testInjectedMemoryRootLeavesLiveRootUntouched() async throws {
        let alt = FileManager.default.temporaryDirectory.appendingPathComponent("mig-inject-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: alt.deletingLastPathComponent()) }
        let d = msgs(100, from: date(10, 3, 9), prefix: "d")
        try SessionSummaryStore.save(SessionSummary(conversationId: g2cut, title: "第三刀", compressedCount: 60,
                                                    segments: [seg(.rolling, d, 0..<60, title: "这个窗口……", pending: "仍未问到"),
                                                               seg(.closeout, d, 60..<80, title: "老收尾")],
                                                    updatedAt: date(10, 3, 12)), in: SessionSummaryStore.dir(root: alt))
        try TimelineStore.write([TimelineEntry(start: date(10, 3, 9), end: date(10, 3, 11), conversationId: g2cut, title: "第三刀",
                                               text: "老的一大段", pending: "")], month: "2026-10", in: TimelineStore.dir(root: alt))
        sources = [g2cut: .init(title: "第三刀", messages: d, isCC: false)]
        let live = root
        let liveBefore = (try? FileManager.default.contentsOfDirectory(atPath: live.path)) ?? []

        let report = try await MemoryMigration.run(profileId: pid, startDay: startDay, now: now, writers: writers(Log()), price: price,
                                                   candidates: { _ in [self.g2cut] }, source: { self.sources[$0] }, memoryRoot: alt)

        XCTAssertEqual(report.done, 1)
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.backup.deletingLastPathComponent(), MemoryRegeneration.backupRoot(memoryRoot: alt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.backup.appendingPathComponent(MemoryMigration.resultFileName).path))
        let a2 = try XCTUnwrap(try SessionSummaryStore.loadStrict(conversationId: g2cut, in: SessionSummaryStore.dir(root: alt)))
        XCTAssertFalse(a2.segments.contains { $0.kind == .closeout && !$0.isTail }, "老收尾段拿掉了")
        XCTAssertEqual(try WindowSummaryStore.loadStrict(conversationId: g2cut, in: alt)?.segments.count, 1)
        let tl = TimelineStore.dir(root: alt)
        XCTAssertEqual(try TimelineStore.entriesStrict(month: "2026-10", in: tl).map(\.text), ["老的一大段"], "时间轴不碰")
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: alt, memoryRoot: alt)?.map(\.text), ["仍未问到"], "覆盖前保全的旧段待续落在注入的根上")

        MemoryWriteLog.flush()
        let log = alt.appendingPathComponent(MemoryWriteLog.folder).appendingPathComponent(MemoryWriteLog.fileName)
        XCTAssertTrue(MemoryWriteLog.decode(try Data(contentsOf: log)).contains { $0.note.hasPrefix("A2 软检查") })
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: live.path)) ?? [], liveBefore, "真根一个文件不多")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MemoryRegeneration.backupRoot(memoryRoot: live).path), "真根旁边没有备份")
        XCTAssertFalse(PendingStore.isMigrated(profileId: pid), "不记「迁移过」")
        XCTAssertNil(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)), "这一层的活本子还是没有")
    }

    /// 10-16 晚：单次调用总上限 120 → 300 秒（长窗口一截 60 条，Air 上 120 秒真超时过）
    func testDefaultCallTimeoutIsFiveMinutes() {
        XCTAssertEqual(MemoryMigration.callTimeout, 300)
        XCTAssertEqual(MemoryMigration.CallTimeout(seconds: MemoryMigration.callTimeout).errorDescription, "模型 300 秒没回完，超时")
    }

    /// B：超时算「出错」，连着 3 个就停
    func testCallTimeoutsCountAsErrorsInARow() async throws {
        try seedThreeGens()
        let report = try await run(hanging([g2cut, g2v41, g1post]), callTimeout: 0.3)
        XCTAssertEqual(report.stopped, "连着 3 个窗口出错，停在第 4 个。看看模型和网络，再点一次接着搬")
        XCTAssertEqual(report.failures.count, 3)
    }

    /// C：每次调用前进度行报一声这一步在写什么
    func testProgressReportsEachStep() async throws {
        try seedThreeGens()
        final class Steps { var all: [String] = [] }
        let steps = Steps()
        _ = try await run(writers(Log())) { p in if p.title == "第三刀" { steps.all.append(p.step) } }
        XCTAssertEqual(steps.all, ["", "写 A2 第 1 / 1 段", "写 A2 尾段", "压 A3"])
    }

    /// C（astra #4）：段号由分段循环报，格式不对重写那次标「（重试）」，不往下一段跳
    func testProgressRetryIsLabelledNotNextPart() async throws {
        try seedThreeGens()
        final class Steps { var all: [String] = []; var seen: [String: Int] = [:] }
        let steps = Steps()
        // 第三刀的 A2 第 1 段、A3 头一次都写坏，重写一次就好
        let w = writers(Log()) { k, conv, _ in
            guard conv == self.g2cut, k == "context" || k == "window" else { return .good }
            steps.seen[k, default: 0] += 1
            return steps.seen[k] == 1 ? .text("（想了很久）……") : .good
        }
        _ = try await run(w) { p in if p.title == "第三刀" { steps.all.append(p.step) } }
        XCTAssertEqual(steps.all, ["", "写 A2 第 1 / 1 段", "写 A2 第 1 / 1 段（重试）", "写 A2 尾段", "压 A3", "压 A3（重试）"])
    }

    /// astra #2：备份拷到一半点了停下 → 抛「备份没做完」，拷了一半的删掉，原文件一个字不改，不调模型
    func testStopDuringBackupLeavesNothing() async throws {
        try seedThreeGens()
        let before = snapshotFive()
        let log = Log()
        final class Handle { var task: Task<MemoryMigration.Report, Error>? }
        let handle = Handle()
        let copy: MemoryRegeneration.FileOp = { from, to in
            handle.task?.cancel()
            try MemoryMigration.cancellableCopy(from, to)
        }
        handle.task = Task { try await self.run(self.writers(log), copy: copy) }
        do {
            _ = try await handle.task!.value
            XCTFail("该抛停下")
        } catch {
            XCTAssertEqual(error as? MemoryMigration.StoppedBeforeBackup, MemoryMigration.StoppedBeforeBackup())
        }
        XCTAssertEqual(log.calls.count, 0)
        XCTAssertEqual(snapshotFive(), before)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: MemoryRegeneration.backupRoot(memoryRoot: root).path)) ?? []
        XCTAssertFalse(left.contains { $0.contains(MemoryMigration.backupPrefix) }, "\(left)")
    }

    /// astra #2：撤回上次的半成品时点了停下 → 正在撤的那个做完，剩下的标记留着，如实写；不清点不搬
    func testStopDuringRollbackFinishesCurrentOne() async throws {
        try seedThreeGens()
        try MemoryMigration.saveMarker(.init(conversationId: g2cut), memoryRoot: root)
        try MemoryMigration.saveMarker(.init(conversationId: g2v41), memoryRoot: root)
        let log = Log()
        final class Handle { var task: Task<MemoryMigration.Report, Error>? }
        let handle = Handle()
        handle.task = Task {
            try await self.run(self.writers(log), fault: { _, step in if step == "撤回" { handle.task?.cancel() } })
        }
        let report = try await handle.task!.value
        XCTAssertEqual(report.stopped, "点了停下：备份做完了，上次搬到一半的还有 1 个没撤回（下次点会先撤回），还没开始搬")
        XCTAssertNil(try marker(g2cut), "开始了的那个撤完")
        XCTAssertNotNil(try marker(g2v41), "没开始的留着下次撤")
        XCTAssertEqual(log.calls.count, 0)
        let saved = try String(contentsOf: report.backup.appendingPathComponent(MemoryMigration.resultFileName), encoding: .utf8)
        XCTAssertTrue(saved.contains("还没开始搬"))
    }

    /// astra #2：清点时点了停下 → 备份留着，如实写「还没开始搬」，不调模型
    func testStopDuringSurveyReportsBackupDone() async throws {
        try seedThreeGens()
        let before = snapshotFive()
        let log = Log()
        final class Handle { var task: Task<MemoryMigration.Report, Error>? }
        let handle = Handle()
        handle.task = Task {
            try await MemoryMigration.run(profileId: self.pid, startDay: self.startDay, now: self.now, writers: self.writers(log),
                                          price: self.price, candidates: { handle.task?.cancel(); return self.candidates($0) },
                                          source: { self.sources[$0] })
        }
        let report = try await handle.task!.value
        XCTAssertEqual(report.stopped, "点了停下：备份做完了，还没开始搬")
        XCTAssertEqual(report.done, 0)
        XCTAssertEqual(log.calls.count, 0)
        XCTAssertEqual(snapshotFive(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.backup.appendingPathComponent(MemoryMigration.resultFileName).path))
    }

    /// D：主线两边加起来不超过 5 条的窗口跳过不搬：不调模型、预估不算它，结果里计「太短跳过」
    func testShortWindowSkippedAndNotEstimated() async throws {
        try seedThreeGens()
        let base = survey()
        let tiny = "tiny-001-aaaa"
        sources[tiny] = .init(title: "一句话", messages: msgs(5, from: date(10, 9, 9), prefix: "t"), isCC: false)
        extra.append(tiny)
        let s = survey()
        XCTAssertEqual(s.short, 1)
        XCTAssertEqual(s.skipped, base.skipped, "不算进「已经是新样子」")
        XCTAssertFalse(s.windows.map(\.id).contains(tiny))
        XCTAssertEqual(s.calls, base.calls, "预估不算它")
        let text = MemoryMigration.confirmText(s, floor: "小克", models: [:], off: [], backupFolder: "x")
        XCTAssertTrue(text.contains("；1 个太短（不超过 5 条消息），跳过不搬；1 个已经是新样子，跳过。"), text)

        let log = Log()
        let report = try await run(writers(log))
        XCTAssertFalse(log.calls.contains { $0.conv == tiny }, "不花钱")
        XCTAssertEqual(report.short, 1)
        XCTAssertNil(a2(tiny))
        XCTAssertNil(a3(tiny))
        let saved = try String(contentsOf: report.backup.appendingPathComponent(MemoryMigration.resultFileName), encoding: .utf8)
        XCTAssertTrue(saved.contains("跳过 1 个，太短跳过 1 个。"), saved)
    }

    // MARK: - 给她看的字

    func testConfirmProgressResultTexts() throws {
        try seedThreeGens()
        let s = survey()
        let text = MemoryMigration.confirmText(s, floor: "小克", models: [.context: "X", .window: "Y", .timeline: "Z"], off: [.a2, .a3],
                                               backupFolder: "记忆备份/v5搬迁-<时间>/")
        XCTAssertTrue(text.hasPrefix("这一层「小克」：从 2026-10-01 起 3 个窗口要搬——2 个只要补尾段和重压窗口总结，1 个要补写上下文摘要；"
                                     + "另有 1 个只有老摘要的窗口，落成第 0 段（不花钱）；1 个已经是新样子，跳过。"), text)
        XCTAssertTrue(text.contains("大概 9 次模型调用"))
        XCTAssertTrue(text.contains("上下文摘要用「X」、窗口总结用「Y」的价"))
        XCTAssertTrue(text.contains("最贵的三个：《第三刀》"))
        XCTAssertTrue(text.contains("A2 / A3 关着：搬完以后不会自动跟上新消息，打开后才接着写。"))
        XCTAssertTrue(text.contains("先整份备份到「记忆备份/v5搬迁-<时间>/」"))
        XCTAssertEqual(MemoryMigration.progressText(.init(index: 12, total: 80, title: "色色", spent: 0.31, remaining: 530)),
                       "正在搬 12 / 80 ·《色色》· 已花 $0.31 · 还要约 9 分钟")
        XCTAssertEqual(MemoryMigration.progressText(.init(index: 3, total: 12, title: "色色", spent: 0.31, remaining: 530, step: "压 A3")),
                       "正在搬 3 / 12 ·《色色》· 压 A3 · 已花 $0.31 · 还要约 9 分钟")
        XCTAssertEqual(MemoryMigration.duration(5400), "1 小时 30 分")
        let r = MemoryMigration.Report(backup: URL(fileURLWithPath: "/x/v5搬迁-20261016-213000"), done: 77, skipped: 12, spent: 1.31,
                                       failures: ["《记忆梳理》第 4 步 窗口总结：格式不对（缺了【经过】），这个窗口原样留着"])
        XCTAssertTrue(MemoryMigration.resultText(r).hasPrefix("搬完了：成 77 个，没成 1 个，跳过 12 个。花了 $1.31。备份在 v5搬迁-20261016-213000。"))
    }
}
