import MemoryCore
import XCTest
@testable import 记忆花园

final class A3RewriteTests: XCTestCase {
    private var root: URL!
    private var suite = ""
    private var defaults: UserDefaults!
    private let pid = "xctest-a3-rewrite"
    private let time = Date(timeIntervalSince1970: 1_790_000_000)
    private let speakers = SessionSegmentWriter.Speakers(userName: "岚舟", assistantName: "星砚")
    private let good = "标题：定北门路线\n【走向】从找地图转到定北门路线。\n【原话】岚舟：「北门。」\n【关键词】云桥城，北门"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("a3-rewrite-\(UUID().uuidString)/memory")
        suite = MemoryBenchLocalExecutor.preferencesSuite(named: "a3-rewrite-\(UUID().uuidString)")
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        MemoryBenchLocalExecutor.removePreferences(defaults, suite: suite)
        super.tearDown()
    }

    private func segment(_ index: Int = 0, format: Int = 2, kind: SessionSegment.Kind = .rolling) -> SessionSegment {
        SessionSegment(kind: kind, title: "路线\(index)", start: time, end: time.addingTimeInterval(300),
            from: 0, to: 6, lastNodeId: "n5", story: "经过独有\(index)", quotes: "岚舟：「引文\(index)。」",
            pending: "不传入的待续", keywords: format >= 2 ? ["关键词\(index)"] : [], format: format)
    }

    private func summary(_ cid: String, _ segments: [SessionSegment]) -> SessionSummary {
        .init(conversationId: cid, title: "云桥城", compressedCount: 6, segments: segments, updatedAt: time, closedThrough: "n5")
    }

    private func messages(_ count: Int = 6) -> [SessionSegmentWriter.Message] {
        (0..<count).map { .init(id: "n\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "原文\($0)",
                              date: time.addingTimeInterval(Double($0 * 60))) }
    }

    private func write(_ raw: String, segments: [SessionSegment] = [], speakers: SessionSegmentWriter.Speakers? = nil,
                       observe: (String, String) -> Void = { _, _ in }) async throws -> SessionSegment? {
        try await WindowSummaryWriter.write(title: "云桥城", segments: segments, rawTail: messages(), persona: "虚构人设",
            speakers: speakers ?? self.speakers, start: time, end: time.addingTimeInterval(300), to: 6, lastNodeId: "n5", profileId: pid, memoryRoot: root) {
                system, user in observe(system, user); return raw
            }
    }

    func testFourBlocksWriteDiskReadAndVersionedCatalog() async throws {
        let result = try await write(good)
        let part = try XCTUnwrap(result)
        XCTAssertEqual(part.kind, .window)
        XCTAssertEqual(part.format, 2)
        XCTAssertEqual(part.story, "从找地图转到定北门路线。")
        XCTAssertEqual(part.quotes, "岚舟：「北门。」")
        XCTAssertEqual(part.keywords, ["云桥城", "北门"])
        XCTAssertEqual(part.pending, "")
        try WindowSummaryStore.save(summary("a3round0-window", [part]), in: root)
        let back = try XCTUnwrap(try WindowSummaryStore.loadStrict(conversationId: "a3round0-window", in: root))
        XCTAssertEqual(back.segments, [part])
        let window = await CatalogALineReader.readWindow("a3round0-window", memoryRoot: root)
        let text = try XCTUnwrap(window).a3
            .map { CatalogALineReader.segmentText($0) }
        XCTAssertTrue(try XCTUnwrap(text).contains("【走向】从找地图转到定北门路线。"))
        XCTAssertTrue(try XCTUnwrap(text).contains("【关键词】云桥城，北门"))
    }

    func testSegmentCountDrivesActualRequestsAtEveryTierBoundary() async throws {
        for (count, length, quotes) in [(0, "≤300 字", "1 句"), (4, "≤300 字", "1 句"), (5, "≤500 字", "2–3 句"),
                                       (8, "≤500 字", "2–3 句"), (9, "500–800 字", "2–3 句"),
                                       (20, "500–800 字", "2–3 句"), (21, "800–1200 字", "2–3 句")] {
            let result = try await write(good, segments: (0..<count).map { segment($0) }) { system, _ in
                XCTAssertTrue(system.contains("本窗口共 \(count) 段，\(length)"), system)
                XCTAssertTrue(system.contains("本窗口 \(quotes)"))
            }
            XCTAssertEqual(result?.kind, .window)
        }
    }

    func testEightSegmentsKeepStoryNineKeepQuotesKeywordsAndRawTail() {
        for count in [8, 9] {
            var segments = (0..<count).map { segment($0) }
            segments[0] = segment(0, format: 1)
            let text = WindowSummaryWriter.userContent(title: "云桥城", segments: segments, rawTail: messages(1), speakers: speakers)
            XCTAssertTrue(text.contains("窗口「云桥城」（共 \(count) 段）"))
            XCTAssertTrue(text.contains("〔\(count)〕路线\(count - 1)"))
            XCTAssertEqual(text.contains("经过独有"), count == 8)
            XCTAssertEqual(text.contains("【关键词】关键词1"), count == 9)
            XCTAssertFalse(text.contains("关键词0"), "老段没有关键词也能读")
            XCTAssertTrue(text.contains("【原话】岚舟：「引文0。」"))
            XCTAssertTrue(text.contains("上下文摘要之后的对话：\n\n岚舟：原文0"))
            XCTAssertFalse(text.contains("不传入的待续"))
        }
        let legacy = WindowSummaryWriter.userContent(title: "旧", segments: [segment(kind: .legacy)], rawTail: [], speakers: speakers)
        XCTAssertTrue(legacy.contains("〔改造前的累计摘要〕\n经过独有0"))
    }

    func testMissingOrEmptyBlocksAndUserAddressesRetryOnceThenRefuse() async throws {
        let missing = [good.replacingOccurrences(of: "标题：", with: "名称："),
                       good.replacingOccurrences(of: "【走向】", with: "【经过】"),
                       good.replacingOccurrences(of: "【原话】", with: "【引文】"),
                       good.replacingOccurrences(of: "【关键词】", with: "【词】"),
                       good.replacingOccurrences(of: "\n【原话】", with: "【原话】"),
                       good.replacingOccurrences(of: "\n【关键词】", with: "【关键词】"),
                       good.replacingOccurrences(of: "从找地图转到定北门路线。", with: ""),
                       good.replacingOccurrences(of: "岚舟：「北门。」", with: " \n ")]
        let addresses = ["用户今天说走北门。", "我告诉用户走北门。", "用户说明天取地图。"].map {
            good.replacingOccurrences(of: "从找地图转到定北门路线。", with: $0)
        }
        for text in missing + addresses {
            var calls = 0
            do {
                _ = try await write(text) { _, _ in calls += 1 }
                XCTFail("硬检查不能存：\(text)")
            } catch MemoryWriterError.format {}
            XCTAssertEqual(calls, 2)
        }
        var calls = 0
        let recovered = try await WindowSummaryWriter.write(title: "云桥城", segments: [], rawTail: [], persona: "", speakers: speakers,
            start: time, end: time, to: 6, lastNodeId: "n5") { _, _ in calls += 1; return calls == 1 ? "缺块" : self.good }
        XCTAssertEqual(recovered?.story, "从找地图转到定北门路线。")
        XCTAssertEqual(calls, 2)
        for text in ["整理用户画像和AI模型接口。", "整理助手说明和用户说明书。", "岚舟说「AI说明天来」。"] {
            XCTAssertNil(WindowSummaryWriter.formatProblem(good.replacingOccurrences(of: "从找地图转到定北门路线。", with: text), speakers: speakers))
        }
        XCTAssertNil(WindowSummaryWriter.formatProblem(good.replacingOccurrences(of: "云桥城，北门", with: "AI说话风格，用户研究"), speakers: speakers),
                     "关键词是搜索术语，不把关键词当人物称呼硬拦")
    }

    func testModelAddressesOnlyLogUnlessTheyAreTheFloorName() async throws {
        for name in ["AI", "助手"] {
            for body in ["\(name)今天说走北门。", "我告诉\(name)走北门。", "\(name)说明天取地图。"] {
                let raw = good.replacingOccurrences(of: "从找地图转到定北门路线。", with: body)
                var calls = 0
                let written = try await write(raw) { _, _ in calls += 1 }
                XCTAssertEqual(written?.story, body)
                XCTAssertEqual(calls, 1)
            }
        }
        MemoryWriteLog.flush()
        let notes = MemoryWriteLog.decode(try Data(contentsOf: root.appendingPathComponent("log/写入日志.jsonl"))).map(\.note)
        for name in ["AI", "助手"] {
            XCTAssertTrue(notes.contains { $0.hasPrefix("A3 软检查") && $0.contains("不要用「\(name)」") })
        }
        let defaultFloor = SessionSegmentWriter.Speakers(userName: "你", assistantName: "助手")
        let raw = good.replacingOccurrences(of: "从找地图转到定北门路线。", with: "我告诉AI走北门。")
            .replacingOccurrences(of: "岚舟：「北门。」", with: "助手：「北门。」")
        var calls = 0
        let written = try await write(raw, speakers: defaultFloor) { _, _ in calls += 1 }
        XCTAssertEqual(written?.quotes, "助手：「北门。」")
        XCTAssertEqual(calls, 1)
        let problems = WindowSummaryWriter.softProblems(SessionSegmentWriter.parse(raw), segmentCount: 0, speakers: defaultFloor)
        XCTAssertTrue(problems.contains { $0.contains("不要用「AI」") })
        XCTAssertFalse(problems.contains { $0.contains("不要用「助手」") })
        let userFloor = SessionSegmentWriter.Speakers(userName: "用户", assistantName: "AI")
        let named = good.replacingOccurrences(of: "从找地图转到定北门路线。", with: "用户告诉AI走北门。")
        let accepted = try await write(named, speakers: userFloor)
        XCTAssertEqual(accepted?.story, "用户告诉AI走北门。")
        XCTAssertEqual(WindowSummaryWriter.softProblems(SessionSegmentWriter.parse(named), segmentCount: 0, speakers: userFloor), [])
    }

    func testSoftChecksLogWithoutRetryTruncateAndOnlyInspectStoryForPending() async throws {
        let bad = "标题：\(String(repeating: "城", count: 21))\n【走向】然后转北门，之后留待续TODO下次。\n【原话】岚舟：「甲。」\n我：「乙。」\n【关键词】讨论,甲,乙,丙,丁,戊,己,庚,辛,壬,癸"
        var calls = 0
        let written = try await write(bad) { _, _ in calls += 1 }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(written?.keywords, ["讨论", "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬"])
        MemoryWriteLog.flush()
        let url = root.appendingPathComponent("log/写入日志.jsonl")
        let notes = MemoryWriteLog.decode(try Data(contentsOf: url)).map(\.note)
        for issue in ["标题超过", "关键词超过", "关键词含通用词", "原话2句", "连接词", "含待续"] {
            XCTAssertTrue(notes.contains { $0.hasPrefix("A3 软检查") && $0.contains(issue) }, issue)
        }
        let quoted = SessionSegmentWriter.parse(good.replacingOccurrences(of: "北门。", with: "下次再玩TODO待续。"))
        XCTAssertFalse(WindowSummaryWriter.softProblems(quoted, segmentCount: 4, speakers: speakers).contains { $0.contains("含待续") })
        for count in [4, 5, 8, 9, 20, 21] {
            let range = WindowSummaryWriter.storyRange(segmentCount: count)
            for length in Set([range.lowerBound, range.upperBound]) {
                var output = SessionSegmentWriter.parse(good)
                output.story = String(repeating: "城", count: length)
                XCTAssertFalse(WindowSummaryWriter.softProblems(output, segmentCount: count, speakers: speakers).contains { $0.contains("出档") })
                output.story = String(repeating: "城", count: range.upperBound + 1)
                XCTAssertTrue(WindowSummaryWriter.softProblems(output, segmentCount: count, speakers: speakers).contains { $0.contains("出档") })
            }
        }
    }

    private func seed(_ cid: String, format: Int = 1, kind: SessionSegment.Kind = .closeout, parts: Int = 1) throws {
        try WindowSummaryStore.save(summary(cid, [segment(format: format, kind: kind)]), in: root)
        try SessionSummaryStore.save(summary(cid, (0..<parts).map { segment($0) }), in: SessionSummaryStore.dir(root: root))
    }

    private func bytes(_ cid: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(SessionSummaryStore.fileURL(conversationId: cid, in: WindowSummaryStore.dir(root: root))))
    }

    private func run(startDay: Date? = nil, copy: MemoryRegeneration.FileOp = MemoryRegeneration.copy,
                     write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
                     source: ((String) -> MemoryRegeneration.Source?)? = nil,
                     caller: @escaping (String) -> SessionSegmentWriter.Caller) async throws -> WindowSummaryRewrite.Report {
        try await WindowSummaryRewrite.run(profileId: pid, memoryRoot: root, persona: "", speakers: speakers, startDay: startDay,
            modelName: "离线", now: time, defaults: defaults, copy: copy, write: write,
            source: source ?? { _ in .init(title: "云桥城", messages: self.messages(), isCC: false) }, caller: caller)
    }

    func testRewriteSelectsOnlyOldBacksUpWindowsSkipsShortAndLeavesFailedBytes() async throws {
        try seed("a3old001-window", parts: 9)
        try seed("a3new001-window", format: 2, kind: .window)
        try seed("a3kind01-window", format: 2)
        try seed("a3fail01-window")
        try seed("a3short1-window")
        let originals = try ["a3old001-window", "a3new001-window", "a3kind01-window", "a3fail01-window", "a3short1-window"]
            .reduce(into: [String: Data]()) { $0[$1] = try bytes($1) }
        let a2dir = SessionSummaryStore.dir(root: root)
        let a2file = try XCTUnwrap(SessionSummaryStore.fileURL(conversationId: "a3old001-window", in: a2dir))
        let a2before = try Data(contentsOf: a2file)
        let source: (String) -> MemoryRegeneration.Source? = { cid in
            .init(title: "云桥城", messages: self.messages(cid.contains("short") ? 5 : 6), isCC: false)
        }
        XCTAssertEqual(WindowSummaryRewrite.survey(memoryRoot: root, startDay: nil, source: source), .init(windows: 3, longWindows: 1))
        var called: [String] = []
        let result = try await run(source: source) { cid in
            { _, user in
                called.append(cid)
                let running = await MainActor.run { SessionCloseoutStatus.shared.runningConversationId }
                XCTAssertEqual(running, cid)
                if cid.contains("fail") { throw URLError(.badServerResponse) }
                if cid.contains("old") { XCTAssertFalse(user.contains("经过独有")); XCTAssertTrue(user.contains("关键词1")) }
                return self.good
            }
        }
        XCTAssertEqual(result, .init(written: 2, skipped: 1, failed: 1, cancelled: false))
        XCTAssertEqual(Set(called), ["a3old001-window", "a3kind01-window", "a3fail01-window"])
        for cid in ["a3new001-window", "a3fail01-window", "a3short1-window"] { XCTAssertEqual(try bytes(cid), originals[cid]) }
        for cid in ["a3old001-window", "a3kind01-window"] {
            XCTAssertEqual(try WindowSummaryStore.loadStrict(conversationId: cid, in: root)?.segments.first?.kind, .window)
            XCTAssertEqual(try WindowSummaryStore.loadStrict(conversationId: cid, in: root)?.segments.first?.format, 2)
        }
        XCTAssertEqual(try Data(contentsOf: a2file), a2before)
        let backup = try XCTUnwrap(MemoryRegeneration.backups(memoryRoot: root).first)
        let manifest = try XCTUnwrap(MemoryRegeneration.manifest(of: backup))
        XCTAssertEqual(manifest.coveredFolders, ["windows"])
        _ = try MemoryRegeneration.verify(backup, manifest)
        for (cid, before) in originals {
            let file = try XCTUnwrap(SessionSummaryStore.fileURL(conversationId: cid, in: backup.appendingPathComponent("windows")))
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
        XCTAssertTrue(try XCTUnwrap(WindowSummaryRewrite.lastText(profileId: pid, defaults: defaults)).contains("2 个窗口"))
        XCTAssertEqual(defaults.dictionary(forKey: WindowSummaryRewrite.lastKey(pid))?["time"] as? Date, time)
        let running = await MainActor.run { SessionCloseoutStatus.shared.runningConversationId }
        XCTAssertNil(running)
    }

    func testSurveyExcludesShortUnavailableAndBeforeStartLikeExecution() async throws {
        for cid in ["a3short0-window", "a3before-window", "a3mixed0-window", "a3after0-window", "a3absent-window"] {
            try seed(cid, parts: cid == "a3before-window" || cid == "a3mixed0-window" ? 9 : 1)
        }
        let start = MemoryDay.boundary(of: time).addingTimeInterval(86400)
        let source: (String) -> MemoryRegeneration.Source? = { cid in
            guard cid != "a3absent-window" else { return nil }
            var messages = self.messages(cid == "a3short0-window" ? 5 : 6)
            if cid != "a3before-window" {
                messages = messages.enumerated().map { index, message in
                    .init(id: message.id, role: message.role, content: message.content,
                          date: start.addingTimeInterval(cid == "a3mixed0-window" && index < 3 ? -60 : 60))
                }
            }
            return .init(title: "云桥城", messages: messages, isCC: false)
        }
        XCTAssertEqual(WindowSummaryRewrite.survey(memoryRoot: root, startDay: start, source: source), .init(windows: 2, longWindows: 1))
        var called: [String] = []
        let result = try await run(startDay: start, source: source) { cid in
            { _, _ in called.append(cid); return self.good }
        }
        XCTAssertEqual(Set(called), ["a3mixed0-window", "a3after0-window"])
        XCTAssertEqual(result, .init(written: 2, skipped: 3, failed: 0, cancelled: false))
    }

    func testEmptyOutputLeavesWindowAndLogsActualFailure() async throws {
        try seed("a3empty0-window")
        let before = try bytes("a3empty0-window")
        let result = try await run { _ in { _, _ in nil } }
        XCTAssertEqual(result, .init(written: 0, skipped: 0, failed: 1, cancelled: false))
        XCTAssertEqual(try bytes("a3empty0-window"), before)
        MemoryWriteLog.flush()
        let notes = MemoryWriteLog.decode(try Data(contentsOf: root.appendingPathComponent("log/写入日志.jsonl"))).map(\.note)
        XCTAssertTrue(notes.contains { $0.contains("空输出") && $0.contains("原样保留") })
        XCTAssertFalse(notes.contains { $0.contains("预算拦下") })
    }

    func testBackupFailureDoesNotFetchSourceCallModelOrModifyWindow() async throws {
        try seed("a3failbk-window")
        let before = try bytes("a3failbk-window")
        do {
            _ = try await run(copy: { _, _ in throw URLError(.cannotWriteToFile) }, source: { _ in XCTFail("备份失败不能读原文"); return nil }) { _ in
                { _, _ in XCTFail("备份失败不能调模型"); return self.good }
            }
            XCTFail("备份应失败")
        } catch {}
        XCTAssertEqual(try bytes("a3failbk-window"), before)
        XCTAssertNil(WindowSummaryRewrite.lastText(profileId: pid, defaults: defaults))
    }

    func testWriteFailureAfterConversationRenamePreservesOldFilenameAndBytes() async throws {
        let cid = "a3disk01-window"
        try seed(cid)
        let original = try XCTUnwrap(SessionSummaryStore.fileURL(conversationId: cid, in: WindowSummaryStore.dir(root: root)))
        let before = try Data(contentsOf: original)
        let report = try await run(write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            source: { _ in .init(title: "改名后的窗口", messages: self.messages(), isCC: false) }) { _ in
                { _, _ in self.good }
            }
        XCTAssertEqual(report, .init(written: 0, skipped: 0, failed: 1, cancelled: false))
        XCTAssertEqual(SessionSummaryStore.fileURL(conversationId: cid, in: WindowSummaryStore.dir(root: root)), original)
        XCTAssertEqual(try Data(contentsOf: original), before)
        XCTAssertEqual(try WindowSummaryStore.loadStrict(conversationId: cid, in: root)?.title, "云桥城")
    }

    func testCancellationDuringModelDoesNotSaveOrStartNextWindow() async throws {
        try seed("a3cancel-window")
        try seed("a3next01-window")
        let before = try bytes("a3cancel-window"), next = try bytes("a3next01-window")
        let started = expectation(description: "模型开始")
        let task = Task {
            try await self.run { cid in
                { _, _ in
                    XCTAssertEqual(cid, "a3cancel-window")
                    started.fulfill()
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch { throw URLError(.cancelled) }
                    return self.good
                }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result, .init(written: 0, skipped: 0, failed: 0, cancelled: true))
        XCTAssertEqual(try bytes("a3cancel-window"), before)
        XCTAssertEqual(try bytes("a3next01-window"), next)
    }

    @MainActor
    func testJobRejectsReentryAndBecomesAvailableAfterCancel() async throws {
        let job = WindowSummaryRewriteJob()
        let started = expectation(description: "任务开始")
        XCTAssertTrue(job.start(profileId: pid) {
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch {}
            return "已停下"
        })
        let task = try XCTUnwrap(job.task)
        XCTAssertFalse(job.start(profileId: "another") { XCTFail("不允许重入"); return "错误" })
        await fulfillment(of: [started], timeout: 5)
        job.cancel()
        await task.value
        XCTAssertNil(job.task)
        XCTAssertEqual(job.note, "已停下")
        XCTAssertTrue(job.start(profileId: pid) { "结束" })
        await job.task?.value
    }

    func testCancelledBeforeBackupLogsResultWithoutCopyingOrCallingModel() async throws {
        try seed("a3precan-window")
        let before = try bytes("a3precan-window")
        let result = try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.run(copy: { _, _ in XCTFail("已取消不能备份") },
                source: { _ in XCTFail("已取消不能读原文"); return nil }) { _ in
                    { _, _ in XCTFail("已取消不能调模型"); return nil }
                }
        }.value
        XCTAssertEqual(result, .init(written: 0, skipped: 0, failed: 0, cancelled: true))
        XCTAssertEqual(try bytes("a3precan-window"), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MemoryRegeneration.backupRoot(memoryRoot: root).path))
        XCTAssertNil(WindowSummaryRewrite.lastText(profileId: pid, defaults: defaults))
        MemoryWriteLog.flush()
        let log = try Data(contentsOf: root.appendingPathComponent("log/写入日志.jsonl"))
        XCTAssertTrue(MemoryWriteLog.decode(log).contains { $0.note.contains("已停下") })
    }

    @MainActor
    func testRewriteAppearsInQueueWithoutNewMessagesAndOnlyOnItsFloor() async {
        let model = MemorySessionsModel()
        await SessionCloseoutStatus.set(running: "a3idle01-window", profileId: pid, title: "云桥城")
        XCTAssertEqual(model.displayedQueue(profileId: pid).map(\.conversationId), ["a3idle01-window"])
        XCTAssertEqual(model.displayedQueue(profileId: pid).first?.title, "云桥城")
        XCTAssertEqual(model.displayedQueue(profileId: "other"), [])
        await SessionCloseoutStatus.set(running: nil)
        XCTAssertEqual(model.displayedQueue(profileId: pid), [])
    }
}
