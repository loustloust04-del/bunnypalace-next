import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 手动 Rewrite / Undo（A2 一段一段原地重写 + A3 重压）：只换字，段盖的范围 / 水位线 / 尾段不动；没写成的原样保留；重写前的版本能退回
final class SummaryRewriteTests: XCTestCase {

    private let pid = "xctest-summary-rewrite"
    private let cid = "conv-rewrite-0001"
    private var root: URL!
    private var versions: FileVersionStore!
    private var saved: [String: Any?] = [:]
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        MemoryWriteLog.flush()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("summary-rewrite-\(UUID().uuidString)", isDirectory: true)
        root = tmp.appendingPathComponent("memory", isDirectory: true)
        versions = FileVersionStore(root: tmp.appendingPathComponent("versions", isDirectory: true))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for k in ["mem_master", "mem_content_summary", "mem_write_a3", "mem_trigger_a2", MemoryStartDay.key] {
            saved[k] = UserDefaults.standard.object(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_content_summary")
        UserDefaults.standard.set(true, forKey: "mem_write_a3")
        UserDefaults.standard.removeObject(forKey: "mem_trigger_a2")
        UserDefaults.standard.removeObject(forKey: MemoryStartDay.key)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    override func tearDown() {
        MemoryWriteLog.flush()
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - 夹具：12 条消息，3 段正式 + 1 段尾段，各盖 3 条

    private var messages: [SessionSegmentWriter.Message] {
        (0..<12).map { .init(id: "n\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "云桥城第\($0)句", date: base.addingTimeInterval(TimeInterval($0 * 60))) }
    }

    private func segment(_ k: Int, tail: Bool = false) -> SessionSegment {
        SessionSegment(kind: tail ? .closeout : .rolling, title: "旧标题\(k)", start: base.addingTimeInterval(TimeInterval(k * 180)),
                       end: base.addingTimeInterval(TimeInterval(k * 180 + 120)), from: k * 3, to: k * 3 + 3, lastNodeId: "n\(k * 3 + 2)",
                       story: "旧经过\(k)", quotes: "岚舟：「旧\(k)」", pending: "旧待续\(k)", keywords: ["旧词\(k)"], isTail: tail,
                       format: SessionSegment.currentFormat)
    }

    @discardableResult
    private func seed() throws -> SessionSummary {
        let s = SessionSummary(conversationId: cid, title: "林栖的窗口", compressedCount: 9,
                               segments: [segment(0), segment(1), segment(2), segment(3, tail: true)], updatedAt: base)
        try SessionSummaryStore.save(s, memoryRoot: root)
        return try XCTUnwrap(SessionSummaryStore.load(conversationId: cid, memoryRoot: root))
    }

    private func a2Reply(_ n: Int) -> String { "标题：新标题\(n)\n【经过】新经过\(n)\n【原话】岚舟：「新\(n)」\n【关键词】新词\(n)\n【待续】新待续\(n)" }
    private let a3Reply = "标题：新窗口总结\n【走向】从北门转到南门\n【原话】岚舟：「走」\n【关键词】北门"

    /// calls 记每次喂给写手的 user 内容；a2 = 第 n 次 A2 调用回什么（nil = 写手跳过）
    private final class Calls: @unchecked Sendable {
        var a2: [String] = []
        var a3: [String] = []
    }

    private func input(_ calls: Calls, a2: @escaping (Int) throws -> String? = { _ in nil }, a3: String? = nil,
                       messages: [SessionSegmentWriter.Message]? = nil) -> SummaryRewrite.Input {
        let root = root!
        return SummaryRewrite.Input(
            conversationId: cid, title: "林栖的窗口", messages: messages ?? self.messages, profileId: pid, persona: "",
            speakers: .init(userName: "岚舟", assistantName: "星砚"), memoryRoot: root, a2Model: "模型甲", a3Model: "模型乙", versions: versions,
            callers: { writer in
                { _, user in
                    if writer == .window { calls.a3.append(user); return a3 }
                    calls.a2.append(user)
                    return try a2(calls.a2.count)
                }
            },
            saveA2: { try SessionSummaryStore.save($0, memoryRoot: root) })
    }

    private func load() throws -> SessionSummary { try XCTUnwrap(SessionSummaryStore.load(conversationId: cid, memoryRoot: root)) }

    private func logNotes() -> [MemoryWriteLog.Entry] {
        MemoryWriteLog.flush()
        return MemoryWriteLog.entries(memoryRoot: root)
    }

    /// 除了写出来的字，段的身份一样没变
    private func assertSameShape(_ a: SessionSegment, _ b: SessionSegment, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.kind, b.kind, file: file, line: line)
        XCTAssertEqual(a.from, b.from, file: file, line: line)
        XCTAssertEqual(a.to, b.to, file: file, line: line)
        XCTAssertEqual(a.lastNodeId, b.lastNodeId, file: file, line: line)
        XCTAssertEqual(a.start, b.start, file: file, line: line)
        XCTAssertEqual(a.end, b.end, file: file, line: line)
        XCTAssertEqual(a.isTail, b.isTail, file: file, line: line)
        XCTAssertEqual(a.pending, b.pending, "段里的待续留旧的", file: file, line: line)
    }

    // MARK: - 这一段盖哪几条

    func testRangeFindsSegmentOnCurrentPath() {
        let ids = messages.map(\.id), dates = messages.map(\.date)
        XCTAssertEqual(SummaryRewrite.range(of: segment(1), pathIds: ids, dates: dates), 3..<6)
        // 前面插进来两条（下标漂了）：末尾按 id、开头按时间还认得
        let shifted = ["x0", "x1"] + ids, shiftedDates: [Date?] = [base.addingTimeInterval(-200), base.addingTimeInterval(-100)] + dates
        XCTAssertEqual(SummaryRewrite.range(of: segment(1), pathIds: shifted, dates: shiftedDates), 5..<8)
        // 切了分支：最后一条不在路径上
        XCTAssertNil(SummaryRewrite.range(of: segment(1), pathIds: Array(ids.prefix(5)), dates: Array(dates.prefix(5))))
        // 开头那条被删了：范围对不上，不重写
        var cut = ids, cutDates = dates
        cut.remove(at: 3); cutDates.remove(at: 3)
        XCTAssertNil(SummaryRewrite.range(of: segment(1), pathIds: cut, dates: cutDates))
        // 改造前的第 0 段、老收尾段不能重写
        var legacy = segment(0); legacy.kind = .legacy
        XCTAssertFalse(SummaryRewrite.rewritable(legacy))
        var oldCloseout = segment(0); oldCloseout.kind = .closeout
        XCTAssertFalse(SummaryRewrite.rewritable(oldCloseout))
        XCTAssertTrue(SummaryRewrite.rewritable(segment(3, tail: true)))
    }

    // MARK: - 只重写中间一段

    func testRewriteOneMiddleSegmentKeepsEverythingElse() async throws {
        let before = try seed()
        let calls = Calls()
        let report = await SummaryRewrite.perform(.segment(lastNodeId: "n5"), input(calls, a2: { self.a2Reply($0) }))
        XCTAssertEqual(report, .init(segments: 1, planned: 1, unmatched: 0, a3: false, stop: .done))
        XCTAssertEqual(calls.a2.count, 1)
        XCTAssertTrue(calls.a2[0].contains("上一段「旧标题0」全文"), "带着前一段全文写")
        XCTAssertTrue(calls.a2[0].contains("云桥城第3句") && calls.a2[0].contains("云桥城第5句"))
        XCTAssertFalse(calls.a2[0].contains("云桥城第2句") || calls.a2[0].contains("云桥城第6句"), "只给它盖的那三条")
        XCTAssertTrue(calls.a3.isEmpty, "只重写一段不动 A3")

        let after = try load()
        XCTAssertEqual(after.compressedCount, before.compressedCount)
        XCTAssertEqual(after.segments.count, 4)
        XCTAssertEqual(after.segments[0], before.segments[0])
        XCTAssertEqual(after.segments[2], before.segments[2])
        XCTAssertEqual(after.segments[3], before.segments[3])
        XCTAssertEqual(after.segments[1].title, "新标题1")
        XCTAssertEqual(after.segments[1].story, "新经过1")
        XCTAssertEqual(after.segments[1].keywords, ["新词1"])
        assertSameShape(after.segments[1], before.segments[1])
        XCTAssertEqual(SessionSummaryStore.resumeIndex(SessionCloseout.coverage(after), pathIds: messages.map(\.id)),
                       SessionSummaryStore.resumeIndex(SessionCloseout.coverage(before), pathIds: messages.map(\.id)), "水位线没动")

        let list = try await versions.versions(key: SummaryRewrite.versionKey(.context, conversationId: cid, profileId: pid))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].actor, "Rewrite · 模型甲")
        let entry = try XCTUnwrap(logNotes().first { $0.note.hasPrefix("Rewrite · ") })
        XCTAssertEqual(entry.writer, MemoryWriterID.a2.code)
        XCTAssertEqual(entry.model, "模型甲")
        XCTAssertTrue(entry.note.contains("林栖的窗口") && entry.note.contains("第 2 段") && entry.note.contains("新标题1"))
    }

    // MARK: - 整个窗口：一段接一段，后一段带着前一段新写的全文；然后 A3

    func testRewriteWindowChainsSegmentsThenA3() async throws {
        let before = try seed()
        let oldWindow = SessionSummary(conversationId: cid, title: "林栖的窗口", compressedCount: 9, segments: [
            SessionSegment(kind: .window, title: "旧窗口总结", start: base, end: base.addingTimeInterval(660), from: 0, to: 12, lastNodeId: "n11",
                           story: "旧走向", quotes: "", pending: "", format: SessionSegment.currentFormat)
        ], updatedAt: base, closedThrough: "n11")
        try WindowSummaryStore.save(oldWindow, in: root)
        let calls = Calls()
        var seen: [String] = []
        let report = await SummaryRewrite.perform(.window, input(calls, a2: { self.a2Reply($0) }, a3: a3Reply)) { seen.append($0) }
        XCTAssertEqual(report, .init(segments: 4, planned: 4, unmatched: 0, a3: true, stop: .done))
        XCTAssertEqual(calls.a2.count, 4)
        XCTAssertTrue(calls.a2[0].contains("这是这个窗口记下的第一段"))
        XCTAssertTrue(calls.a2[1].contains("上一段「新标题1」全文") && calls.a2[1].contains("新经过1"), "接的是刚重写的那段")
        XCTAssertTrue(calls.a2[3].contains("上一段「新标题3」全文"))
        XCTAssertEqual(seen.last, "A3 窗口总结")

        let after = try load()
        XCTAssertEqual(after.compressedCount, 9)
        for i in 0..<4 {
            XCTAssertEqual(after.segments[i].title, "新标题\(i + 1)")
            assertSameShape(after.segments[i], before.segments[i])
        }
        XCTAssertTrue(after.segments[3].isTail)
        XCTAssertEqual(calls.a3.count, 1)
        XCTAssertTrue(calls.a3[0].contains("新标题2"), "A3 用重写后的 A2")
        let w = try XCTUnwrap(WindowSummaryStore.load(conversationId: cid, memoryRoot: root))
        XCTAssertEqual(w.segments.map(\.title), ["新窗口总结"])
        XCTAssertEqual(w.closedThrough, "n11")
        let a3Versions = try await versions.versions(key: SummaryRewrite.versionKey(.window, conversationId: cid, profileId: pid))
        XCTAssertEqual(a3Versions.map(\.actor), ["Rewrite · 模型乙", "A3 写手"])
        XCTAssertEqual(SummaryRewrite.summary(report), "Rewrite 完成：A2 写好 4 / 4 段，A3 写好。不满意可以 Undo")
    }

    // MARK: - 没写成的原样保留

    func testFailureMidwayKeepsOldFromThere() async throws {
        let before = try seed()
        let calls = Calls()
        // 第二段两次都写不出合格格式 → 抛格式错
        let report = await SummaryRewrite.perform(.window, input(calls, a2: { $0 == 1 ? self.a2Reply(1) : "乱写一气" }, a3: a3Reply))
        XCTAssertEqual(report.segments, 1)
        guard case .failed = report.stop else { return XCTFail("要是出错停下") }
        XCTAssertTrue(calls.a3.isEmpty, "A2 没写完不接着写 A3")
        let after = try load()
        XCTAssertEqual(after.segments[0].title, "新标题1")
        XCTAssertEqual(Array(after.segments[1...]), Array(before.segments[1...]), "没写成的那段和后面的原样")
        XCTAssertNil(WindowSummaryStore.load(conversationId: cid, memoryRoot: root))
        XCTAssertTrue(logNotes().contains { !$0.ok && $0.note.contains("没写成，原样保留") })
    }

    func testSkippedWriterChangesNothing() async throws {
        let before = try seed()
        let report = await SummaryRewrite.perform(.segment(lastNodeId: "n5"), input(Calls()))
        XCTAssertEqual(report.stop, .skipped("模型没回内容"))
        XCTAssertEqual(try load(), before)
        let list = try await versions.versions(key: SummaryRewrite.versionKey(.context, conversationId: cid, profileId: pid))
        XCTAssertTrue(list.isEmpty, "什么都没改就不记版本")
    }

    func testSegmentOffPathIsLeftAlone() async throws {
        let before = try seed()
        let calls = Calls()
        // 主线上 n5 没了（切过分支）：第 2 段对不上，别的照写
        let path = messages.filter { $0.id != "n5" }
        let report = await SummaryRewrite.perform(.window, input(calls, a2: { self.a2Reply($0) }, messages: path))
        XCTAssertEqual(report.unmatched, 1)
        XCTAssertEqual(report.segments, 3)
        XCTAssertEqual(try load().segments[1], before.segments[1])
    }

    func testSwitchOffRefuses() async throws {
        try seed()
        var off = input(Calls(), a2: { _ in XCTFail("关着不该调模型"); return nil })
        off.a2On = false
        let report = await SummaryRewrite.perform(.segment(lastNodeId: "n5"), off)
        guard case .off = report.stop else { return XCTFail("要是关着") }
    }

    // MARK: - Undo

    func testUndoPutsOldTextBackAndKeepsLaterSegments() async throws {
        let before = try seed()
        _ = await SummaryRewrite.perform(.window, input(Calls(), a2: { self.a2Reply($0) }))
        // 重写之后后台写手又换了尾段、接了一段正式段
        var grown = try load()
        grown.segments.removeLast()
        grown.segments.append(SessionSegment(kind: .rolling, title: "后来的一段", start: base.addingTimeInterval(540), end: base.addingTimeInterval(840),
                                             from: 9, to: 15, lastNodeId: "n14", story: "后来", quotes: "", pending: "", format: SessionSegment.currentFormat))
        grown.compressedCount = 15
        try SessionSummaryStore.save(grown, memoryRoot: root)

        let key = SummaryRewrite.versionKey(.context, conversationId: cid, profileId: pid)
        let recorded = try await versions.versions(key: key)
        let target = try XCTUnwrap(SummaryRewrite.undoTarget(recorded))
        let content = try await versions.content(key: key, id: target.id)
        let text = try XCTUnwrap(content)
        let root = root!
        let said = await SummaryRewrite.restore(.context, versionText: text, what: "Undo", conversationId: cid, profileId: pid, memoryRoot: root,
                                                versions: versions, saveA2: { try SessionSummaryStore.save($0, memoryRoot: root) })
        XCTAssertEqual(said, "Undo 完成：A2 上下文摘要退回了 3 段")
        let after = try load()
        XCTAssertEqual(Array(after.segments[0..<3]), Array(before.segments[0..<3]))
        XCTAssertEqual(after.segments[3].title, "后来的一段", "之后新写的段不动")
        XCTAssertEqual(after.compressedCount, 15, "水位照现在的")
        let list = try await versions.versions(key: key)
        XCTAssertEqual(list.first?.source, .restore)
        XCTAssertNil(SummaryRewrite.undoTarget(list), "退过了就没有第二次")
        XCTAssertTrue(logNotes().contains { $0.note.hasPrefix("Undo · ") && $0.writer == MemoryWriterID.a2.code })
    }

    func testMergedA3KeepsCurrentMarks() {
        func window(_ title: String, closed: String) -> SessionSummary {
            SessionSummary(conversationId: cid, title: "林栖的窗口", compressedCount: 0, segments: [
                SessionSegment(kind: .window, title: title, start: base, end: base, from: 0, to: 12, lastNodeId: closed, story: title + "走向",
                               quotes: "", pending: "", format: SessionSegment.currentFormat)
            ], updatedAt: base, closedThrough: closed)
        }
        let merged = SummaryRewrite.merged(current: window("新的", closed: "n11"), old: window("旧的", closed: "n8"), writer: .window)
        XCTAssertEqual(merged?.summary.segments[0].title, "旧的")
        XCTAssertEqual(merged?.summary.closedThrough, "n11", "写到哪照现在的")
        XCTAssertEqual(merged?.summary.segments[0].lastNodeId, "n11")
        XCTAssertNil(SummaryRewrite.merged(current: window("一样", closed: "n11"), old: window("一样", closed: "n11"), writer: .window))
    }

    func testConfirmTextNamesModels() {
        let ask = SummaryRewriteAsk(target: .window, conversationId: cid, windowTitle: "林栖的窗口", segmentCount: 4)
        let text = SummaryRewriteAsk.text(ask, a2Model: "模型甲", a3Model: "模型乙")
        XCTAssertTrue(text.contains("4 段") && text.contains("模型甲") && text.contains("模型乙") && text.contains("Undo"))
    }

    // MARK: - 占位：和后台写手抢同一个窗口

    func testExclusiveRefusesWhileWindowIsBusy() async {
        let closeout = SessionCloseout()
        let outer = await closeout.exclusive(cid, job: "Rewrite") { () -> String? in
            await closeout.exclusive(self.cid, job: "Rewrite") { "不该进来" }
        }
        XCTAssertEqual(outer, .some(nil), "占着的时候第二个进不来，也不排队")
        let again = await closeout.exclusive(cid, job: "Rewrite") { "放开了" }
        XCTAssertEqual(again, "放开了")
        let other = await closeout.exclusive(cid, job: "Rewrite") { () -> String? in
            await closeout.exclusive("conv-other-0001", job: "Rewrite") { "别的窗口不挡" }
        }
        XCTAssertEqual(other, .some("别的窗口不挡"))
    }

    // MARK: - 日志两处

    /// A2 软检查那行带上真去调的模型名（调模型的那一层报上来）
    func testSoftCheckLogCarriesCalledModel() async throws {
        let root = root!
        let longTitle = "标题：这是一个明显超过十五个字的上下文摘要标题\n【经过】接着聊\n【原话】岚舟：「嗯」\n【关键词】北门"
        let seg = try await MemoryWriteLog.metered {
            try await SessionSegmentWriter.write(
                .init(messages: Array(self.messages.prefix(3)), kind: .rolling, from: 0, persona: "", speakers: .init(userName: "岚舟", assistantName: "星砚"),
                      previous: nil, profileId: self.pid, windowTitle: "林栖的窗口", memoryRoot: root),
                caller: { _, _ in
                    MemoryWriteLog.noteModel("模型丙")
                    return longTitle
                })
        }
        XCTAssertNotNil(seg)
        let entry = try XCTUnwrap(logNotes().first { $0.note.hasPrefix("A2 软检查") })
        XCTAssertEqual(entry.model, "模型丙")
    }

    /// 日切写到一半被拦下：写入日志有一行说停在第几份、被什么拦下；同一处同一个原因不重复记
    func testDailySkipIsLoggedOnce() async throws {
        let c = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(c)
        // 固定在同一个记忆日里（不跨 05:00），「现在」= 两天后
        let t = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 10))!
        for i in 0..<60 {
            let node = MessageNode(id: "d\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "第\(i)条", contentType: "text",
                                   createTime: t.addingTimeInterval(TimeInterval(i * 60)), parentId: i == 0 ? nil : "d\(i - 1)",
                                   childrenIds: i + 1 < 60 ? ["d\(i + 1)"] : [], conversationId: "conv-daily-skip", profileId: pid)
            if i % 2 == 1 { node.ccMessageId = "m\(i)" }
            context.insert(node)
        }
        let conversation = Conversation(id: "conv-daily-skip", title: "云桥城", createTime: t, updateTime: t.addingTimeInterval(3600), currentNodeId: "d59", profileId: pid)
        conversation.ccBridgeSessionName = "mp-cc-test"
        context.insert(conversation)
        try context.save()
        let ctx = SessionCloseout.Context(profile: Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "岚舟", assistantName: "星砚"),
                                          model: ProviderModel(credentialId: "x", modelId: "m", name: "模型甲"))
        let closeout = SessionCloseout()
        let blocked: SessionSegmentWriter.Caller = { _, _ in
            MemoryWriteLog.noteSkip("写入预算用完")
            return nil
        }
        for _ in 0..<2 {
            let r = await closeout.compressCC(conversationId: "conv-daily-skip", ctx: ctx, container: c, providerManager: ProviderManager(),
                                              now: t.addingTimeInterval(2 * 86400), caller: blocked)
            XCTAssertEqual(r, .retry(at: nil))
        }
        MemoryWriteLog.flush()
        let lines = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { $0.note.contains("被拦下") }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.note, "《云桥城》这次要写 1 份，写到第 1 份被拦下：写入预算用完（下次巡检接着写）")
        XCTAssertEqual(lines.first?.model, "模型甲")
        XCTAssertEqual(lines.first?.ok, false)
    }
}
