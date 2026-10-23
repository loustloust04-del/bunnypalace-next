import XCTest
@testable import 记忆花园

/// v4-1 §九：重新生成（假写手、临时目录当测试楼层）——备份逐字一致、中途失败原件不动、回滚逐字一致
final class MemoryRegenerationTests: XCTestCase {

    private var floor: URL!
    private var root: URL { floor.appendingPathComponent("memory", isDirectory: true) }
    private let cal = Calendar.current

    override func setUpWithError() throws {
        floor = FileManager.default.temporaryDirectory.appendingPathComponent("xctest-regen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: floor)
    }

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    /// 一个窗口：10-09 晚上 3 条 + 10-10 上午 3 条
    private func messages() -> [SessionSegmentWriter.Message] {
        [date(10, 9, 21), date(10, 9, 22), date(10, 9, 23), date(10, 10, 9), date(10, 10, 10), date(10, 10, 11)].enumerated().map { i, d in
            .init(id: "n\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "第\(i)条", date: d)
        }
    }

    /// 写坏的老数据：sessions/ 里一段收尾段（带待续）、时间轴 9 月文件里一条 10 月的老条目（第三刀的毛病）
    private func seedBroken() throws {
        let closeout = SessionSegment(kind: .closeout, title: "这个窗口……", start: date(10, 9, 21), end: date(10, 10, 11), from: 0, to: 6,
                                      lastNodeId: "n5", story: "这个窗口聊了很多", quotes: "", pending: "仍未问到")
        try SessionSummaryStore.save(SessionSummary(conversationId: "conv-live-0001", title: "色色", compressedCount: 0,
                                                    segments: [closeout], updatedAt: date(10, 10, 12)),
                                     in: SessionSummaryStore.dir(root: root))
        let tl = TimelineStore.dir(root: root)
        try TimelineStore.write([TimelineEntry(start: date(10, 9, 21), end: date(10, 10, 11), conversationId: "conv-live-0001",
                                               title: "色色", text: "（想了很久）……想到了", pending: "仍未问到")], month: "2026-09", in: tl)
        try TimelineStore.write([TimelineEntry(start: date(10, 2, 0, 30), end: date(10, 2, 1), conversationId: "conv-gone-0001",
                                               title: "删掉的", text: "凌晨聊的", pending: "")], month: "2026-10", in: tl)
    }

    private struct Boom: Error {}

    /// 假写手：按提示词认是哪种写手，给合格的输出；failOn = 第几次调用抛错
    private func writers(failOn: Int? = nil) -> MemoryRegeneration.Writers {
        var n = 0
        return .init(persona: "你是小克。", speakers: .init(userName: "粟粟", assistantName: "小克")) { system, _ in
            n += 1
            if n == failOn { throw Boom() }
            if system.contains("「时间轴」") { return "【话题】\n- 第\(n)次写的话题\n【待续】\n- 无" }
            return "标题：第\(n)段\n【经过】接着聊\n【原话】粟粟：「嗯」"
        }
    }

    private func snapshot() -> [String: String] {
        var out: [String: String] = [:]
        for f in MemoryRegeneration.folders {
            let dir = root.appendingPathComponent(f)
            for (rel, _) in MemoryRegeneration.fileSizes(dir) {
                out[f + rel] = try? String(contentsOf: dir.appendingPathComponent(String(rel.dropFirst())), encoding: .utf8)
            }
        }
        return out
    }

    private func source(_ id: String) -> MemoryRegeneration.Source? {
        id == "conv-live-0001" ? .init(title: "色色", messages: messages(), isCC: false) : nil
    }

    func testBackupIsByteIdenticalAndRewriteFollowsNewRules() async throws {
        try seedBroken()
        let before = snapshot()
        let report = try await MemoryRegeneration.run(memoryRoot: root, startDay: date(10, 1, 5), now: date(10, 11, 12),
                                                      writers: writers(), legacySeed: { _ in nil }, source: { self.source($0) })
        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.windows, 1)
        // 备份和原件逐字一致
        for (path, text) in before {
            let backed = try String(contentsOf: report.backup.appendingPathComponent(path), encoding: .utf8)
            XCTAssertEqual(backed, text, path)
        }
        XCTAssertTrue(report.backup.path.contains("记忆备份/v4-1-"))
        XCTAssertFalse(report.backup.path.contains("/memory/"), "备份放在 memory/ 旁边，不在里面")

        // 上下文摘要：老收尾段拿掉了（API 窗口原来没有压缩段、锚点 0 → 不写新的，只剩收尾段的文件整个拿掉）
        XCTAssertNil(SessionSummaryStore.load(conversationId: "conv-live-0001", in: SessionSummaryStore.dir(root: root)))
        // 窗口总结：一份，最后那段写到最后一条
        let w = try XCTUnwrap(WindowSummaryStore.load(conversationId: "conv-live-0001", in: root))
        XCTAssertEqual(w.closedThrough, "n5")
        XCTAssertEqual(w.segments.map(\.kind), [.closeout])
        // 时间轴：按天切成 10-09、10-10 两条，进 10 月文件；9 月里那条老的写成了就不放回
        let tl = TimelineStore.dir(root: root)
        let oct = TimelineStore.entries(month: "2026-10", in: tl)
        XCTAssertEqual(oct.filter { $0.conversationId == "conv-live-0001" }.map(\.day), ["2026-10-09", "2026-10-10"])
        XCTAssertTrue(TimelineStore.entries(month: "2026-09", in: tl).isEmpty)
        XCTAssertEqual(oct.filter { $0.conversationId == "conv-gone-0001" }.count, 1, "删掉的窗口：旧条目原样保留")
        // 暂存目录清掉了
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: MemoryRegeneration.backupRoot(memoryRoot: root).path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("staging-") })
    }

    func testWriterThrowsMidwayLeavesOriginalsUntouched() async throws {
        try seedBroken()
        let before = snapshot()
        do {
            _ = try await MemoryRegeneration.run(memoryRoot: root, startDay: date(10, 1, 5), now: date(10, 11, 12),
                                                 writers: writers(failOn: 2), legacySeed: { _ in nil }, source: { self.source($0) })
            XCTFail("写手抛错应该整个停下")
        } catch is Boom {}
        XCTAssertEqual(snapshot(), before, "原件一字不动")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: MemoryRegeneration.backupRoot(memoryRoot: root).path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("staging-") }, "暂存目录被清掉")
    }

    func testFormatFailureIsReportedAndOldEntryKept() async throws {
        try seedBroken()
        let bad = MemoryRegeneration.Writers(persona: "", speakers: .init(userName: "粟粟", assistantName: "小克")) { system, _ in
            system.contains("「时间轴」") ? "（想了很久）……想到了" : "标题：一段\n【经过】接着聊\n【原话】粟粟：「嗯」"
        }
        let report = try await MemoryRegeneration.run(memoryRoot: root, startDay: date(10, 1, 5), now: date(10, 11, 12),
                                                      writers: bad, legacySeed: { _ in nil }, source: { self.source($0) })
        XCTAssertEqual(report.failures.count, 1, "第一天就没写成：停下，后面的天不写（astra #3）：\(report.failures)")
        XCTAssertTrue(report.failures.allSatisfy { $0.contains("时间轴") && $0.contains("格式不对") })
        let tl = TimelineStore.dir(root: root)
        let all = TimelineStore.months(in: tl).flatMap { TimelineStore.entries(month: $0, in: tl) }
        XCTAssertEqual(all.filter { $0.conversationId == "conv-live-0001" }.map(\.text), ["（想了很久）……想到了"], "没写成的那天留着旧的")
    }

    // MARK: - astra 一轮

    private func msgs(_ n: Int, from start: Date, prefix: String = "n") -> [SessionSegmentWriter.Message] {
        (0..<n).map { .init(id: "\(prefix)\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "第\($0)条",
                            date: start.addingTimeInterval(TimeInterval($0) * 60)) }
    }

    /// #1：原覆盖 [0,300) 全在范围里 → 重建整段 [0,300)，不套首次补写的 150 条上限；CC 分支同样从头建
    func testRebuildsFullOriginalCoverage() {
        let m = msgs(400, from: date(10, 5, 9))
        let seg = SessionSegment(kind: .rolling, title: "老压缩", start: date(10, 5, 9), end: m[299].date!, from: 0, to: 300,
                                 lastNodeId: "n299", story: "", quotes: "", pending: "仍未")
        let old = SessionSummary(conversationId: "c", title: "t", compressedCount: 300, segments: [seg], updatedAt: date(10, 6, 0))
        let api = MemoryRegeneration.work(old: old, source: .init(title: "t", messages: m, isCC: false), scopeStart: date(10, 1, 5), now: date(10, 11, 12))
        XCTAssertEqual(api.contextParts.first?.lowerBound, 0)
        XCTAssertEqual(api.contextParts.last?.upperBound, 300)
        XCTAssertEqual(api.contextParts.reduce(0) { $0 + $1.count }, 300, "[0,300) 全部重建")
        let cc = MemoryRegeneration.work(old: old, source: .init(title: "t", messages: m, isCC: true), scopeStart: date(10, 1, 5), now: date(10, 11, 12))
        XCTAssertEqual(cc.contextParts.first?.lowerBound, 0, "CC 也从头建")
        XCTAssertEqual(cc.contextParts.reduce(0) { $0 + $1.count }, 400, "那天已经过去：整截都写")
    }

    /// #2：上下文摘要有一截没写成 → 这个窗口的上下文摘要文件原样保留（水位不超过真写到的地方）
    func testContextFailureKeepsOriginalFile() async throws {
        let m = msgs(130, from: date(10, 5, 9))
        let seg = SessionSegment(kind: .rolling, title: "老压缩", start: date(10, 5, 9), end: m[119].date!, from: 0, to: 120,
                                 lastNodeId: "n119", story: "老经过", quotes: "", pending: "仍未")
        let original = SessionSummary(conversationId: "conv-ctx-0001", title: "窗", compressedCount: 120, segments: [seg], updatedAt: date(10, 6, 0))
        try SessionSummaryStore.save(original, in: SessionSummaryStore.dir(root: root))
        var contextCalls = 0
        let writers = MemoryRegeneration.Writers(persona: "", speakers: .init(userName: "粟粟", assistantName: "小克")) { system, _ in
            if system.contains("「时间轴」") { return "【话题】\n- 话题\n【待续】\n- 无" }
            if system.contains("「上下文摘要」") {
                contextCalls += 1
                return contextCalls == 1 ? "标题：第一截\n【经过】好\n【原话】粟粟：「嗯」" : "（想了很久）……想到了"
            }
            return "标题：最后\n【经过】好\n【原话】粟粟：「嗯」"
        }
        let report = try await MemoryRegeneration.run(memoryRoot: root, startDay: date(10, 1, 5), now: date(10, 11, 12), writers: writers,
                                                      legacySeed: { _ in nil },
                                                      source: { $0 == "conv-ctx-0001" ? .init(title: "窗", messages: m, isCC: false) : nil })
        XCTAssertTrue(report.failures.contains { $0.contains("上下文摘要") }, "\(report.failures)")
        let after = try XCTUnwrap(SessionSummaryStore.load(conversationId: "conv-ctx-0001", in: SessionSummaryStore.dir(root: root)))
        XCTAssertEqual(after.segments, original.segments, "整份保留原文件，不留半截")
        XCTAssertEqual(after.compressedCount, 120)
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-ctx-0001", in: root)?.segments.first?.title, "老压缩", "窗口总结抄的是原上下文摘要")
    }

    /// #3：一天三份，第二份没写成 → 这天撤回、留旧条目，后面的天不写；放回的老 v2 改成老格式，水位停在最后写成的那天
    func testTimelineStopsAtFirstFailedDay() async throws {
        let a = msgs(3, from: date(10, 8, 20), prefix: "a")
        let b = msgs(180, from: date(10, 9, 9), prefix: "b")
        let c = msgs(2, from: date(10, 10, 9), prefix: "c")
        let all = a + b + c
        let tl = TimelineStore.dir(root: root)
        let oldB = TimelineEntry(start: date(10, 9, 9), end: date(10, 9, 12), conversationId: "conv-tl-0001", title: "窗", text: "B 的老条目", pending: "")
        let oldC = TimelineEntry(start: date(10, 10, 9), end: date(10, 10, 10), conversationId: "conv-tl-0001", title: "窗", text: "- C 的老 v2",
                                 pending: "", day: "2026-10-10", lastNodeId: "c1")
        try TimelineStore.write([oldB, oldC], month: "2026-10", in: tl)
        var timelineCalls = 0
        let writers = MemoryRegeneration.Writers(persona: "", speakers: .init(userName: "粟粟", assistantName: "小克")) { system, _ in
            guard system.contains("「时间轴」") else { return "标题：一段\n【经过】好\n【原话】粟粟：「嗯」" }
            timelineCalls += 1
            // 第 1 次 = A；第 2 次 = B 第一份；第 3、4 次 = B 第二份（连重写一起都不合格）
            return (3...4).contains(timelineCalls) ? "（想了很久）……想到了" : "【话题】\n- 第\(timelineCalls)次\n【待续】\n- 无"
        }
        let report = try await MemoryRegeneration.run(memoryRoot: root, startDay: date(10, 1, 5), now: date(10, 11, 12), writers: writers,
                                                      legacySeed: { _ in nil },
                                                      source: { $0 == "conv-tl-0001" ? .init(title: "窗", messages: all, isCC: false) : nil })
        XCTAssertEqual(timelineCalls, 4, "B 失败就停，C 不写")
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("2026-10-09"))
        let entries = TimelineStore.entries(month: "2026-10", in: tl).filter { $0.conversationId == "conv-tl-0001" }
        XCTAssertEqual(entries.filter { $0.day != nil }.map(\.day), ["2026-10-08"], "只有写成的 A 是新条目")
        XCTAssertEqual(Set(entries.filter { $0.day == nil }.map(\.text)), ["B 的老条目", "- C 的老 v2"], "没写成的那天和后面的天留旧的")
        let latest = TimelineStore.latest(conversationId: "conv-tl-0001", v2Only: true, in: tl)
        XCTAssertEqual(latest?.lastNodeId, "a2", "水位停在 A：日常收尾从 B 接着补")
        XCTAssertEqual(SessionCloseout.timelineStart(pathIds: all.map(\.id), dates: all.map(\.date), latest: latest, legacyLast: nil, notBefore: 0), 3)
    }

    private struct InjectedFailure: Error {}

    /// #4：替换中途装新目录失败 → 旧目录挪回来，原件一字不动；暂存目录留着
    func testSwapFailureMovesOldBack() async throws {
        try seedBroken()
        let before = snapshot()
        let failingMove: MemoryRegeneration.FileOp = { from, to in
            if from.path.contains("/staging-"), to.lastPathComponent == SessionSummaryStore.folder, !from.lastPathComponent.hasPrefix("old-") {
                throw InjectedFailure()
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
        do {
            _ = try await MemoryRegeneration.run(memoryRoot: root, startDay: date(10, 1, 5), now: date(10, 11, 12), writers: writers(),
                                                 legacySeed: { _ in nil }, source: { self.source($0) }, move: failingMove)
            XCTFail("应该抛")
        } catch is InjectedFailure {}
        XCTAssertEqual(snapshot(), before, "已经换上的 timeline 撤回、挪开的 sessions 挪回")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: MemoryRegeneration.backupRoot(memoryRoot: root).path)) ?? []
        XCTAssertTrue(leftovers.contains { $0.hasPrefix("staging-") }, "替换开始后失败：暂存目录留着备查")
    }

    /// #4：恢复时拷贝失败 → 拷了一半的删掉，挪开的挪回来，不发布「回滚前」
    func testRestoreCopyFailureMovesCurrentBack() throws {
        try seedBroken()
        let backup = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-test")
        try TimelineStore.write([], month: "2026-11", in: TimelineStore.dir(root: root))   // 现在的和备份不一样
        let current = snapshot()
        let failingCopy: MemoryRegeneration.FileOp = { from, to in
            if from.lastPathComponent == SessionSummaryStore.folder { throw InjectedFailure() }
            try FileManager.default.copyItem(at: from, to: to)
        }
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: backup, memoryRoot: root, now: date(10, 11, 13), copy: failingCopy))
        XCTAssertEqual(snapshot(), current, "现在的文件原样回来")
        XCTAssertFalse(MemoryRegeneration.backups(memoryRoot: root).contains { $0.lastPathComponent.hasPrefix("回滚前-") })
    }

    /// #5：拷到一半的备份不列、不让恢复；清单分得清「原本没有」和「没拷完」
    func testHalfBackupIsNotListedOrRestorable() throws {
        try seedBroken()
        let failingCopy: MemoryRegeneration.FileOp = { from, to in
            if from.lastPathComponent == SessionSummaryStore.folder { throw InjectedFailure() }
            try FileManager.default.copyItem(at: from, to: to)
        }
        XCTAssertThrowsError(try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-half", copy: failingCopy))
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).isEmpty, "没拷完的不列")
        let backupRoot = MemoryRegeneration.backupRoot(memoryRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent("v4-1-half").path), "没拷完不发布正式名字")

        // 手搭一份没清单的
        let fake = backupRoot.appendingPathComponent("v4-1-fake", isDirectory: true)
        try FileManager.default.createDirectory(at: fake.appendingPathComponent("timeline"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: fake, memoryRoot: root, now: date(10, 11, 13))) {
            XCTAssertEqual($0 as? MemoryRegeneration.RegenError, .incompleteBackup("没有完成清单，可能拷到一半"))
        }

        // 正常备份：windows/ 原本没有 → 清单里没有它，恢复后也没有
        let good = try MemoryRegeneration.makeBackup(memoryRoot: root, name: "v4-1-good")
        XCTAssertEqual(MemoryRegeneration.manifest(of: good)?.folders, [TimelineStore.folder, SessionSummaryStore.folder])
        XCTAssertEqual(MemoryRegeneration.backups(memoryRoot: root).map(\.lastPathComponent), ["v4-1-good"])
        // 清单里有、备份里却没有 → 拒绝
        try FileManager.default.removeItem(at: good.appendingPathComponent(SessionSummaryStore.folder))
        XCTAssertThrowsError(try MemoryRegeneration.restore(backup: good, memoryRoot: root, now: date(10, 11, 13)))
    }

    func testRestoreMatchesBackup() async throws {
        try seedBroken()
        let before = snapshot()
        let report = try await MemoryRegeneration.run(memoryRoot: root, startDay: date(10, 1, 5), now: date(10, 11, 12),
                                                      writers: writers(), legacySeed: { _ in nil }, source: { self.source($0) })
        XCTAssertNotEqual(snapshot(), before)
        try MemoryRegeneration.restore(backup: report.backup, memoryRoot: root, now: date(10, 11, 13))
        XCTAssertEqual(snapshot(), before, "回滚后和备份逐字一致")
        XCTAssertTrue(MemoryRegeneration.backups(memoryRoot: root).contains { $0.lastPathComponent.hasPrefix("回滚前-") })
    }

    /// 锚点曾因老收尾段盖住窗外只推不写：重写时按 compressedCount 补上下文摘要，不然窗外那截没人总结
    func testAnchorOnlyWindowGetsContextRewritten() throws {
        let closeout = SessionSegment(kind: .closeout, title: "老收尾", start: date(10, 9, 21), end: date(10, 10, 11), from: 0, to: 6,
                                      lastNodeId: "n5", story: "", quotes: "", pending: "")
        let old = SessionSummary(conversationId: "conv-live-0001", title: "色色", compressedCount: 4, segments: [closeout], updatedAt: date(10, 10, 12))
        let w = MemoryRegeneration.work(old: old, source: try XCTUnwrap(source("conv-live-0001")), scopeStart: date(10, 1, 5), now: date(10, 11, 12))
        XCTAssertEqual(w.contextParts, [0..<4])
        XCTAssertTrue(w.keep.segments.isEmpty, "老收尾段拿掉")
        XCTAssertEqual(w.timelineParts, [0..<3, 3..<6], "时间轴按天切")
    }

    func testEstimateCountsWindowsAndCalls() throws {
        try seedBroken()
        let e = MemoryRegeneration.estimate(startDay: date(10, 1, 5), memoryRoot: root, now: date(10, 11, 12)) { self.source($0) }
        XCTAssertEqual(e.windows, 1)
        XCTAssertEqual(e.goneWindows, 1)
        XCTAssertEqual(e.calls, 3, "窗口总结 1 + 时间轴两天各 1")
    }
}
