import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// v4-1 §五：收尾 = A2 尾段 + 窗口总结；格式两次不合格不存、记健康状态、30 分钟冷却；收尾不再往 sessions/ 写收尾段。
/// c2c3-v2 第 7 段起 A4 一天一条另走 `TimelineDaily`，收尾不写时间轴
final class SessionCloseoutQueueTests: XCTestCase {

    let pid = "xctest-closeout-queue"
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        MemoryWriteLog.flush()
        PendingStore.forget(profileId: pid)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        for k in ["mem_master", "mem_content_summary", "mem_content_timeline", "mem_write_a3", MemoryStartDay.key, "mem_content_facts",
                  "mem_trigger_a2", "mem_trigger_a2_idle", "mem_trigger_a3", "mem_trigger_a3_rounds", "mem_trigger_a3_idle",
                  "mem_trigger_a4", "mem_trigger_a4_idle"] {
            saved[k] = UserDefaults.standard.object(forKey: k)
        }
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(true, forKey: "mem_content_summary")
        UserDefaults.standard.set(true, forKey: "mem_content_timeline")
        UserDefaults.standard.set(true, forKey: "mem_write_a3")
        UserDefaults.standard.set(true, forKey: "mem_content_facts")
        UserDefaults.standard.removeObject(forKey: MemoryStartDay.key)
        for k in ["mem_trigger_a2", "mem_trigger_a2_idle", "mem_trigger_a3", "mem_trigger_a3_rounds", "mem_trigger_a3_idle",
                  "mem_trigger_a4", "mem_trigger_a4_idle"] { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        MemoryWriteLog.flush()
        for (k, v) in saved { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        PendingStore.forget(profileId: pid)
        UserDefaults.standard.removeObject(forKey: PendingStore.migratedKey(profileId: pid))
        UserDefaults.standard.removeObject(forKey: TimelineDaily.backupKey(pid))
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

    private let goodWindow = "标题：一段\n【走向】转向北门\n【原话】粟粟：「嗯」\n【关键词】北门"
    private let goodTail = "标题：一段\n【经过】接着聊\n【原话】粟粟：「嗯」"

    private func reply(_ system: String) -> String { kind(system) == "window" ? goodWindow : goodTail }

    /// 哪一个写手：A3 窗口总结 / A2 尾段（v5 D1）
    private func kind(_ system: String) -> String {
        system.contains("「窗口总结」") ? "window" : "tail"
    }

    private func item(_ n: Int) -> SessionCloseout.Candidate {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 10))!
        let msgs = (0..<n).map { SessionSegmentWriter.Message(id: "n\($0)", role: $0 % 2 == 0 ? "user" : "assistant", content: "x",
                                                             date: base.addingTimeInterval(TimeInterval($0) * 60)) }
        return .init(conversationId: "conv-q-0001", title: "Q", messages: msgs)
    }

    /// 车头 10-22「待续在哪儿产生就在哪儿保全」：A4 关着；尾段写出待续 → 存段那一刻就进了待续本子；
    /// 后来尾段被整段重写、新尾段不再有这句，本子里照样在
    func testTailPendingSavedAtWriteEvenWithA4Off() async throws {
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        let closeout = SessionCloseout()
        var tailReply = "标题：尾段\n【经过】接着聊\n【原话】粟粟：「嗯」\n【待续】周三问结果"
        _ = await closeout.closeout(item(6), ctx: ctx) { system, _ in self.kind(system) == "tail" ? tailReply : self.goodWindow }
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.map(\.text), ["周三问结果"], "存段时就搬了，不等 A4")
        tailReply = "标题：尾段重写\n【经过】又聊了\n【原话】粟粟：「好」\n【待续】无"
        _ = await closeout.closeout(item(8), ctx: ctx) { system, _ in self.kind(system) == "tail" ? tailReply : self.goodWindow }
        XCTAssertEqual(SessionSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.last?.pending, "", "尾段被覆盖了")
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.map(\.text), ["周三问结果"], "本子里照样在")
    }

    /// 搬不成（本子有一行认不出）→ 记进待补；本子修好后下一次存段一起补上，不丢
    func testTailPendingRetriedAfterFailure() async throws {
        let url = PendingStore.fileURL(root: FileLibraryStore.memoryRoot(profileId: pid))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((PendingStore.render([]) + "\n- 坏行").utf8).write(to: url)
        let closeout = SessionCloseout()
        var tailReply = "标题：尾段\n【经过】接着聊\n【原话】粟粟：「嗯」\n【待续】周三问结果"
        _ = await closeout.closeout(item(6), ctx: ctx) { system, _ in self.kind(system) == "tail" ? tailReply : self.goodWindow }
        XCTAssertEqual(try PendingStore.retryQueueStrict(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).flatMap(\.texts), ["周三问结果"], "记进待补")
        try Data(PendingStore.render([]).utf8).write(to: url)
        tailReply = "标题：尾段重写\n【经过】又聊了\n【原话】粟粟：「好」\n【待续】无"
        _ = await closeout.closeout(item(8), ctx: ctx) { system, _ in self.kind(system) == "tail" ? tailReply : self.goodWindow }
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.map(\.text), ["周三问结果"], "下一次存段补上")
        XCTAssertTrue(try PendingStore.retryQueueStrict(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).isEmpty)
    }

    private var sessionsDir: URL { SessionSummaryStore.dir(root: FileLibraryStore.memoryRoot(profileId: pid)) }

    private func oldTail(pending: String) throws {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 10))!
        let seg = SessionSegment(kind: .closeout, title: "升级前的尾段", start: base, end: base.addingTimeInterval(300), from: 0, to: 6,
                                 lastNodeId: "n5", story: "旧", quotes: "", pending: pending, isTail: true)
        try SessionSummaryStore.save(SessionSummary(conversationId: "conv-q-0001", title: "Q", compressedCount: 0, segments: [seg],
                                                    updatedAt: base), in: sessionsDir)
    }

    private let tailWithout = "标题：尾段重写\n【经过】又聊了\n【原话】粟粟：「好」\n【待续】无"

    /// astra 四轮 #1：升级前写的尾段里有待续、还没进本子；升级后第一次收尾写了新尾段（不带这句）——覆盖之前先把旧的保全了
    func testOldTailPendingPreservedBeforeOverwrite() async throws {
        try oldTail(pending: "周三问结果")
        _ = await SessionCloseout().closeout(item(8), ctx: ctx) { system, _ in self.kind(system) == "tail" ? self.tailWithout : self.goodWindow }
        XCTAssertEqual(SessionSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.last?.title, "尾段重写")
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.map(\.text), ["周三问结果"])
    }

    /// astra 四轮 #1 #2：pending/ 写不进去（本子、待补都落不了盘）→ A2 文件不覆盖，这次收尾记失败
    func testA2NotOverwrittenWhenPendingUnwritable() async throws {
        try oldTail(pending: "周三问结果")
        let file = try XCTUnwrap(SessionSummaryStore.fileURL(conversationId: "conv-q-0001", in: sessionsDir))
        let before = try Data(contentsOf: file)
        let pending = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent(PendingStore.folder)
        try Data("挡路".utf8).write(to: pending)   // pending 是个文件：建不了目录，本子和待补都写不进去
        _ = await SessionCloseout().closeout(item(8), ctx: ctx) { system, _ in self.kind(system) == "tail" ? self.tailWithout : self.goodWindow }
        XCTAssertEqual(try Data(contentsOf: file), before, "旧尾段原样，待续还在它里面")
        XCTAssertGreaterThan(MemoryHealthStore.status(.context, profileId: pid).failStreak, 0, "这次尾段记失败")
    }

    /// astra 四轮 #4：旧本子里老条目搬进来的「买药」她改成「买感冒药」并标了做完（还没有原文哈希）；升级后先发生 A2 存段、
    /// 尾段里又有「买药」——先迁老待续、补身份再导入，不会多出一条 open
    func testEditedOldBookItemNotDuplicatedOnA2Save() async throws {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9))!
        try TimelineStore.seedLegacy(TimelineEntry(start: base, end: base.addingTimeInterval(600), conversationId: "conv-q-0001", title: "Q",
                                                   text: "- 话题", pending: "买药", day: "2026-10-10", lastNodeId: "old-anchor"),
                                     in: TimelineStore.dir(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        try PendingStore.mutate(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) {
            $0 = [PendingItem(id: "p0001", text: "买感冒药", state: .done, conversationId: "conv-q-0001", day: "2026-10-10", anchor: "old-anchor")]
        }
        let reply = "标题：尾段\n【经过】接着聊\n【原话】粟粟：「嗯」\n【待续】买药"
        _ = await SessionCloseout().closeout(item(6), ctx: ctx) { system, _ in self.kind(system) == "tail" ? reply : self.goodWindow }
        let items = try XCTUnwrap(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertEqual(items.map(\.text), ["买感冒药"])
        XCTAssertEqual(items[0].state, .done)
        XCTAssertTrue(PendingStore.isLegacyDone(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
    }

    /// astra 四轮 #5：记过名字、但那份备份已经没了 → 改本子之前重做
    func testStaleBackupNameIsRedone() async throws {
        UserDefaults.standard.set("A4日级前-早就删了", forKey: TimelineDaily.backupKey(pid))
        let reply = "标题：尾段\n【经过】接着聊\n【原话】粟粟：「嗯」\n【待续】周三问结果"
        _ = await SessionCloseout().closeout(item(6), ctx: ctx) { system, _ in self.kind(system) == "tail" ? reply : self.goodWindow }
        let name = try XCTUnwrap(UserDefaults.standard.string(forKey: TimelineDaily.backupKey(pid)))
        XCTAssertNotEqual(name, "A4日级前-早就删了")
        XCTAssertTrue(TimelineDaily.backupValid(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), profileId: pid, defaults: .standard))
        XCTAssertEqual(PendingStore.load(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.map(\.text), ["周三问结果"])
    }

    /// v5 D1 / D2：A2 开着先把尾段收进 sessions/（整段重写），再把整个窗口重压成 A3；收尾不写时间轴
    func testWindowWrittenTailIntoSessionsNoTimeline() async throws {
        var calls: [String] = []
        let closeout = SessionCloseout()
        let stop = await closeout.closeout(item(), ctx: ctx) { system, _ in
            calls.append(self.kind(system))
            return self.reply(system)
        }
        XCTAssertFalse(stop)
        XCTAssertEqual(calls, ["tail", "window"], "尾段 / 窗口总结两种调用，没有时间轴")
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-q-0001", in: root)?.closedThrough, "n5")
        XCTAssertTrue(TimelineStore.months(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).isEmpty, "收尾不再写 A4")
        XCTAssertEqual(SessionSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.map(\.isTail), [true],
                       "尾段收进 A2（sessions/）")
        XCTAssertNotNil(MemoryHealthStore.status(.summary, profileId: pid).lastOK)
    }

    func testFormatFailureCoolsDown() async throws {
        var calls: [String] = []
        let closeout = SessionCloseout()
        let caller: SessionSegmentWriter.Caller = { system, _ in
            calls.append(self.kind(system))
            return self.kind(system) == "window" ? "（想了很久）……想到了" : self.goodTail
        }
        _ = await closeout.closeout(item(), ctx: ctx, caller: caller)
        XCTAssertEqual(calls, ["tail", "window", "window"], "窗口总结重写一次")
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        XCTAssertNil(WindowSummaryStore.load(conversationId: "conv-q-0001", in: root), "不合格不存")
        XCTAssertEqual(MemoryHealthStore.status(.summary, profileId: pid).failStreak, 1)
        XCTAssertEqual(MemoryHealthWarning.text(profileId: pid), nil, "一次失败还不亮")

        calls = []
        _ = await closeout.closeout(item(), ctx: ctx, caller: caller)
        XCTAssertEqual(calls, [], "尾段已经写到最后一条；窗口总结 30 分钟内不再试")
    }

    /// astra #8：等模型时来了新消息——覆盖判断用盖到的那条消息的时间（不是写文件那一刻），下次巡检照样挑它
    func testNewMessageDuringModelCallIsPickedUpNextSweep() async throws {
        let it = item()
        let lastCovered = try XCTUnwrap(it.messages.last?.date)
        var newMessageAt: Date?
        _ = await SessionCloseout().closeout(it, ctx: ctx) { system, _ in
            newMessageAt = Date()   // 模型还没回，她又发了一条：对话 updateTime 挪到现在
            return self.reply(system)
        }
        let w = try XCTUnwrap(WindowSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        let covered = w.updatedAt
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

    /// v5 · 0.1：关着 compress 不跑、不记失败（补跑闭包也走 compress）
    func testCompressSkipsWhenOff() async throws {
        UserDefaults.standard.set(false, forKey: "mem_master")
        var calls = 0
        let r = try await SessionCloseout().compress(messages: item().messages, oldCount: 4, conversationId: "conv-q-0001", title: "Q",
                                                     ctx: ctx) { _, _ in calls += 1; throw URLError(.badServerResponse) }
        XCTAssertNil(r)
        XCTAssertEqual(calls, 0, "总开关关着不调模型")
        XCTAssertEqual(MemoryHealthStore.status(.context, profileId: pid).failStreak, 0, "不记失败")
        UserDefaults.standard.set(true, forKey: "mem_master")
        UserDefaults.standard.set(false, forKey: "mem_content_summary")
        _ = try await SessionCloseout().compress(messages: item().messages, oldCount: 4, conversationId: "conv-q-0001", title: "Q",
                                                 ctx: ctx) { _, _ in calls += 1; return nil }
        XCTAssertEqual(calls, 0, "这一项关着也不跑")
    }

    func testSwitchesQ3() {
        UserDefaults.standard.set(false, forKey: "mem_content_summary")
        XCTAssertTrue(SessionCloseout.closeoutEnabled, "A3 开着就收尾")
        UserDefaults.standard.set(false, forKey: "mem_write_a3")   // v5：A3 单独一个开关
        XCTAssertFalse(SessionCloseout.closeoutEnabled, "A3 关了就不收尾（A4 另外按天拼）")
        XCTAssertTrue(SessionCloseout.timelineEnabled)
        XCTAssertEqual(WindowSummaryListLayout.queueNote(masterOn: true, a3On: false, queueEmpty: false), "A3 窗口总结关着，窗口收尾不跑")
    }

    // MARK: - astra v5 裁决

    /// astra #1：等模型时关了总开关——回来的结果不落盘、后面的不再调、不记失败
    func testSwitchOffDuringCallStopsWithoutFailure() async throws {
        var calls: [String] = []
        let stop = await SessionCloseout().closeout(item(), ctx: ctx) { system, _ in
            calls.append(self.kind(system))
            UserDefaults.standard.set(false, forKey: "mem_master")
            return self.reply(system)
        }
        XCTAssertFalse(stop)
        XCTAssertEqual(calls, ["tail"], "关了以后一次都不再调")
        XCTAssertNil(SessionSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.first, "尾段不落盘")
        XCTAssertNil(WindowSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        for kind in [MemoryHealthStore.Kind.context, .summary, .timeline] {
            XCTAssertEqual(MemoryHealthStore.status(kind, profileId: pid).failStreak, 0, "\(kind) 不记失败")
        }
    }

    /// astra #1：A3 格式不对、重写前她关了 A3 → 不重写、不记失败
    func testSwitchOffBeforeRetryNotCounted() async throws {
        UserDefaults.standard.set(false, forKey: "mem_content_summary")
        var calls: [String] = []
        _ = await SessionCloseout().closeout(item(), ctx: ctx) { system, _ in
            calls.append(self.kind(system))
            UserDefaults.standard.set(false, forKey: "mem_write_a3")
            return "不合格"
        }
        XCTAssertEqual(calls, ["window"], "A3 不再重写一次")
        XCTAssertEqual(MemoryHealthStore.status(.summary, profileId: pid).failStreak, 0)
    }

    /// astra #2：巡检手里的快照旧了（「现在写」已经写到更后面）→ 窗口总结 / 尾段都不倒退
    func testStaleSnapshotDoesNotOverwriteNewer() async throws {
        let it = item()
        let later = try XCTUnwrap(it.messages.last?.date).addingTimeInterval(600)
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        let newer = SessionSummary(conversationId: "conv-q-0001", title: "Q", compressedCount: 0,
                                   segments: [SessionSegment(kind: .closeout, title: "新", start: later, end: later, from: 0, to: 8,
                                                             lastNodeId: "n7", story: "新的", quotes: "", pending: "")],
                                   updatedAt: later, closedThrough: "n7")
        try WindowSummaryStore.save(newer, in: root)
        var tail = SessionSegment(kind: .closeout, title: "新尾段", start: later, end: later, from: 0, to: 8, lastNodeId: "n7",
                                  story: "新的", quotes: "", pending: "")
        tail.isTail = true
        try SessionSummaryStore.save(SessionSummary(conversationId: "conv-q-0001", title: "Q", compressedCount: 0, segments: [tail],
                                                    updatedAt: later), memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        var calls = 0
        _ = await SessionCloseout().closeout(it, ctx: ctx) { system, _ in calls += 1; return self.reply(system) }
        XCTAssertEqual(calls, 0, "不调模型")
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-q-0001", in: root)?.closedThrough, "n7", "不倒退")
        XCTAssertEqual(SessionSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.last?.lastNodeId, "n7")

        XCTAssertFalse(SessionCloseout.wouldRegress(mark: "n3", markDate: later, snapshot: it.messages), "在路径上 = 不靠后")
        XCTAssertFalse(SessionCloseout.wouldRegress(mark: "gone", markDate: .distantPast, snapshot: it.messages), "切过分支、更早")
        XCTAssertTrue(SessionCloseout.wouldRegress(mark: "n7", markDate: later, snapshot: it.messages))
    }

    /// astra #2：占到窗口后按当前路径重读——巡检开头拿的 6 条快照旧了，实际已经 8 条，写到第 8 条
    @MainActor
    func testCloseoutReloadsCurrentPathAfterClaim() async throws {
        UserDefaults.standard.set(false, forKey: "mem_content_summary")
        let c = try container([("conv-q-0001", "n", 8, false)])
        let stop = await SessionCloseout().closeout(item(), ctx: ctx, container: c) { _ in { _, _ in self.goodWindow } }
        XCTAssertFalse(stop)
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.closedThrough, "n7")
    }

    /// astra #7：A2「只手动」/ 冷却中，A3 收尾不自动写尾段（直接压原文）；「现在写」照写
    func testA2ManualOnlySkipsTailUnlessManual() async throws {
        UserDefaults.standard.set(MemoryTriggerMode.manual.rawValue, forKey: "mem_trigger_a2")
        var calls: [String] = []
        let caller: SessionSegmentWriter.Caller = { system, _ in
            calls.append(self.kind(system))
            return self.reply(system)
        }
        _ = await SessionCloseout().closeout(item(), ctx: ctx, caller: caller)
        XCTAssertEqual(calls, ["window"], "不写尾段")
        XCTAssertNil(SessionSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.first)

        try FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        calls = []
        var manual = ctx
        manual.manual = true
        _ = await SessionCloseout().closeout(item(), ctx: manual, caller: caller)
        XCTAssertEqual(calls, ["tail", "window"], "手动照写尾段")

        XCTAssertFalse(SessionCloseout.writesTail(manual: false, a2On: true, a2Mode: .idle, a2Cooling: true), "冷却中不写")
        XCTAssertTrue(SessionCloseout.writesTail(manual: false, a2On: true, a2Mode: .rounds, a2Cooling: false))
        XCTAssertFalse(SessionCloseout.writesTail(manual: true, a2On: false, a2Mode: .rounds, a2Cooling: false), "A2 关着不写")
    }

    /// astra #9：A2「停 N 分钟」到点后预算拦下 / 出错 → 快照留着（出错退避 30 分钟）；写成了才出队
    @MainActor
    func testIdleCompressKeptUntilWritten() async throws {
        UserDefaults.standard.set(MemoryTriggerMode.idle.rawValue, forKey: "mem_trigger_a2")
        UserDefaults.standard.set(1, forKey: "mem_trigger_a2_idle")
        let closeout = SessionCloseout()
        let pm = ProviderManager()
        let msgs = item().messages
        let t0 = Date().addingTimeInterval(-3600)
        await closeout.noteIdleCompress(conversationId: "conv-q-0001", messages: msgs, oldCount: 4, title: "Q", ctx: ctx, now: t0)
        var calls = 0
        await closeout.runIdleCompress(providerManager: pm, now: Date()) { _, _ in { _, _ in calls += 1; return nil } }
        var pending = await closeout.idleCompressPending
        XCTAssertEqual(pending, ["conv-q-0001"], "预算拦下：留着")
        XCTAssertEqual(calls, 1)

        await closeout.runIdleCompress(providerManager: pm, now: Date()) { _, _ in { _, _ in calls += 1; throw URLError(.badServerResponse) } }
        pending = await closeout.idleCompressPending
        XCTAssertEqual(pending, ["conv-q-0001"], "出错：留着")
        XCTAssertEqual(calls, 2)
        await closeout.runIdleCompress(providerManager: pm, now: Date()) { _, _ in { _, _ in calls += 1; return self.goodTail } }
        XCTAssertEqual(calls, 2, "出错后退避，下次巡检不立刻再打")

        await closeout.runIdleCompress(providerManager: pm, now: Date().addingTimeInterval(SessionCloseout.formatCooldown + 1)) { _, _ in
            { _, _ in calls += 1; return self.goodTail }
        }
        pending = await closeout.idleCompressPending
        XCTAssertEqual(pending, [], "写成了才出队")
        XCTAssertEqual(SessionSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.compressedCount, 4)
    }

    /// astra #6 / #10：CC 窗口「现在写」写 A2（A2 只手动、A3 关着也写）；后台占着 → 说忙，不排队
    @MainActor
    func testCloseoutNowWritesCCContextAndReportsBusy() async throws {
        UserDefaults.standard.set(MemoryTriggerMode.manual.rawValue, forKey: "mem_trigger_a2")
        UserDefaults.standard.set(false, forKey: "mem_write_a3")
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        let c = try container([("conv-cc-q", "c", 60, true)])
        let pm = ProviderManager()
        let closeout = SessionCloseout()

        let gate = AsyncGate()
        async let holding = closeout.compress(messages: item().messages, oldCount: 4, conversationId: "conv-cc-q", title: "t", ctx: ctx) { _, _ in
            await gate.wait()
            return nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let busy = await closeout.closeoutNow(conversationId: "conv-cc-q", ctx: ctx, container: c, providerManager: pm) { _ in
            { _, _ in XCTFail("占着不该调模型"); return nil }
        }
        XCTAssertTrue(busy.busy)
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: busy), "📝 后台正在写这个窗口，稍后再点")
        await gate.open()
        _ = try await holding

        let r = await closeout.closeoutNow(conversationId: "conv-cc-q", ctx: ctx, container: c, providerManager: pm, now: Date().addingTimeInterval(86400)) { _ in
            { _, _ in self.goodTail }
        }
        XCTAssertEqual(r.context, 1, "60 条写成一段 A2")
        XCTAssertFalse(r.busy)
        XCTAssertEqual(ConversationViewModel.writeNowSummary(a2Segments: 0, result: r), "📝 写好了：A2 1 段")
    }

    /// astra #11：A 窗口巡检时 B 刚回完一轮——补跑带上 B（「每 N 回合」只看刚回完的那个）
    @MainActor
    func testMergedSweepKeepsNewActiveWindow() async throws {
        UserDefaults.standard.set(false, forKey: "mem_content_summary")
        UserDefaults.standard.set(MemoryTriggerMode.rounds.rawValue, forKey: "mem_trigger_a3")
        UserDefaults.standard.set(1, forKey: "mem_trigger_a3_rounds")
        let c = try container([("conv-a-0001", "a", 6, false), ("conv-b-0001", "b", 6, false)])
        let pm = ProviderManager()
        let closeout = SessionCloseout()
        let gate = AsyncGate()
        async let first: Void = closeout.sweep(ctx: ctx, container: c, providerManager: pm, activeConversationId: "conv-a-0001") { _ in
            { _, _ in await gate.wait(); return self.goodWindow }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        await closeout.sweep(ctx: ctx, container: c, providerManager: pm, activeConversationId: "conv-b-0001") { _ in { _, _ in self.goodWindow } }
        XCTAssertNil(WindowSummaryStore.load(conversationId: "conv-b-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)), "正在巡检：先攒着")
        await gate.open()
        await first
        XCTAssertNotNil(WindowSummaryStore.load(conversationId: "conv-a-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-b-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.closedThrough, "b5", "补跑消费了 B")
    }

    // MARK: - 短窗口（规格 5½，粟粟 10-16）：≤5 条不写 A2 尾段 / A3；「现在写」不受影响

    func testSkipsSummaryThreshold() {
        XCTAssertEqual(MemoryMigration.shortWindowMax, 5, "和三代搬迁同一个门槛")
        XCTAssertTrue(SessionCloseout.skipsSummary(messageCount: 0))
        XCTAssertTrue(SessionCloseout.skipsSummary(messageCount: 5))
        XCTAssertFalse(SessionCloseout.skipsSummary(messageCount: 6))
    }

    /// 巡检队列：5 条的窗口整个不进队列（没有要写的）；6 条排 A3
    func testShortWindowNotQueued() throws {
        let c = try container([("conv-short-02", "s", 5, false), ("conv-long-002", "l", 6, false)])
        let q = SessionCloseout.queue(profileId: pid, source: SwiftDataConversationSource(container: c), now: Date().addingTimeInterval(86400), force: nil, includeWaiting: false)
        XCTAssertEqual(q.map(\.conversationId), ["conv-long-002"])
        XCTAssertEqual(q.first?.writers, [.window])
        let waiting = SessionCloseout.queue(profileId: pid, source: SwiftDataConversationSource(container: c), now: Date(), force: nil, includeWaiting: true)
        XCTAssertEqual(waiting.map(\.conversationId), ["conv-long-002"], "「正在记」也不显示短窗口的 A3 在等")
    }

    /// 「现在写」不经队列：3 条的窗口照写 A2 尾段 / A3（A4 由 `SessionCloseoutTrigger.writeNow` 接着按天拼）
    @MainActor
    func testCloseoutNowWritesShortWindow() async throws {
        let c = try container([("conv-short-03", "s", 3, false)])
        var calls: [String] = []
        _ = await SessionCloseout().closeoutNow(conversationId: "conv-short-03", ctx: ctx, container: c, providerManager: ProviderManager(),
                                                now: Date().addingTimeInterval(86400)) { _ in
            { system, _ in
                calls.append(self.kind(system))
                return self.reply(system)
            }
        }
        XCTAssertTrue(calls.contains("window"), "现在写：短窗口照写 A3")
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-short-03", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.closedThrough, "s2")
    }

    /// 10-16 astra #8：排队时 6 条（A3 到点），执行前主线变成 5 条——按实际路径再判：不写 A2 尾段 / A3；
    /// 「现在写」（manual）照写
    @MainActor
    func testShortWindowRecheckedAtExecution() async throws {
        let c = try container([("conv-q-0001", "n", 5, false)])
        var calls: [String] = []
        let callers: (SessionCloseout.Writer) -> SessionSegmentWriter.Caller = { _ in
            { system, _ in
                calls.append(self.kind(system))
                return self.reply(system)
            }
        }
        let queued = item()
        XCTAssertEqual(queued.messages.count, 6)
        XCTAssertEqual(queued.writers, [.window], "排队时 6 条：A3 到点")
        let stop = await SessionCloseout().closeout(queued, ctx: ctx, container: c, callers: callers)
        XCTAssertFalse(stop)
        XCTAssertEqual(calls, [], "执行时只剩 5 条：A2 尾段 / A3 不写")
        XCTAssertNil(WindowSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertNil(SessionSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.segments.first, "尾段也不写")

        calls = []
        var manual = ctx
        manual.manual = true
        _ = await SessionCloseout().closeout(queued, ctx: manual, container: c, callers: callers)
        XCTAssertTrue(calls.contains("window"), "现在写：照写 A3")
        XCTAssertEqual(WindowSummaryStore.load(conversationId: "conv-q-0001", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.closedThrough, "n4")
    }

    /// astra #8：CC 回复落地和 API 那条路一样喊巡检（A3 收尾；A4 一天一条也挂在巡检后面）
    func testCCLandingRequestsCloseout() {
        XCTAssertEqual(SessionCloseoutTrigger.ccLandingRequests(memoryEnabled: true), [.contextSummary, .closeout, .fragments])
        UserDefaults.standard.set(false, forKey: "mem_write_a3")
        XCTAssertEqual(SessionCloseoutTrigger.ccLandingRequests(memoryEnabled: true), [.contextSummary, .closeout, .fragments],
                       "只开 A4 也喊（巡检后面拼 A4）")
        UserDefaults.standard.set(false, forKey: "mem_content_timeline")
        XCTAssertEqual(SessionCloseoutTrigger.ccLandingRequests(memoryEnabled: true), [.contextSummary, .fragments], "A3 / A4 都关不喊巡检")
        XCTAssertEqual(SessionCloseoutTrigger.ccLandingRequests(memoryEnabled: false), [], "这个对话不参与记忆")
    }

    /// 对话：每个 (id, 节点前缀, 条数, 是不是 CC)；消息从 1 小时前起每分钟一条，updateTime = 现在
    private func container(_ convs: [(id: String, prefix: String, count: Int, cc: Bool)]) throws -> ModelContainer {
        let c = try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(c)
        let t = Date().addingTimeInterval(-3600)
        for conv in convs {
            for i in 0..<conv.count {
                let id = "\(conv.prefix)\(i)"
                let node = MessageNode(id: id, role: i % 2 == 0 ? "user" : "assistant", content: "第\(i)条", contentType: "text",
                                       createTime: t.addingTimeInterval(TimeInterval(i * 60)), parentId: i == 0 ? nil : "\(conv.prefix)\(i - 1)",
                                       childrenIds: i + 1 < conv.count ? ["\(conv.prefix)\(i + 1)"] : [], conversationId: conv.id, profileId: pid)
                if conv.cc && i % 2 == 1 { node.ccMessageId = "m\(i)" }
                context.insert(node)
            }
            let conversation = Conversation(id: conv.id, title: conv.id, createTime: t, updateTime: Date(),
                                            currentNodeId: "\(conv.prefix)\(conv.count - 1)", profileId: pid)
            if conv.cc { conversation.ccBridgeSessionName = "mp-cc-test" }
            context.insert(conversation)
        }
        try context.save()
        return c
    }

    // MARK: - 10-16 搬迁等日常写手：有上限、可取消

    /// 一个一直不回的写手占住窗口（被取消才退）；started 在它第一次被调时兑现
    private func hangingWriter(on closeout: SessionCloseout, started: XCTestExpectation) -> Task<Bool, Never> {
        started.assertForOverFulfill = false
        let ctx = ctx, item = item()
        return Task {
            await closeout.closeout(item, ctx: ctx) { _, _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            }
        }
    }

    func testWaitUntilIdleTimesOutNamesWriterAndCancelsPromptly() async throws {
        let closeout = SessionCloseout()
        let started = expectation(description: "写手开工")
        let writer = hangingWriter(on: closeout, started: started)
        await fulfillment(of: [started], timeout: 5)

        let timedOut = await closeout.waitUntilIdle(timeout: 0.3)
        XCTAssertEqual(timedOut, .timedOut(["收尾 · conv-q-0"]), "等够了返回、说得出谁在写")

        let waiting = Task { await closeout.waitUntilIdle(timeout: 30) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let t0 = Date()
        waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "取消立刻返回，不空转")

        writer.cancel()
        _ = await writer.value
        let idle = await closeout.waitUntilIdle(timeout: 1)
        XCTAssertEqual(idle, .idle, "写手退了就不用等")
    }

    /// astra #1：没人在写时取消也认——不进 body，日常写手放开、资格还回去
    @MainActor
    func testCancelWithNobodyWritingNeverEntersBody() async {
        let closeout = SessionCloseout()
        let idle = await Task { () -> SessionCloseout.IdleWait in
            withUnsafeCurrentTask { $0?.cancel() }
            return await closeout.waitUntilIdle(timeout: 30)
        }.value
        XCTAssertEqual(idle, .cancelled)

        final class Flag { var ran = false }
        let flag = Flag()
        let gate = MemoryMaintenance.shared
        let r = await Task { () -> Result<String, MemoryMaintenance.Refusal> in
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.exclusive("搬迁") { () async -> String in flag.ran = true; return "不该跑" }
        }.value
        XCTAssertEqual(r, .failure(.cancelled))
        XCTAssertFalse(flag.ran)
        XCTAssertNil(gate.holder)
        let regenerating = await SessionCloseout.shared.regenerating
        XCTAssertFalse(regenerating)
    }

    @MainActor
    func testMaintenanceGateReleasesOnWriterTimeoutAndCancel() async throws {
        let started = expectation(description: "写手开工")
        let writer = hangingWriter(on: SessionCloseout.shared, started: started)
        await fulfillment(of: [started], timeout: 5)
        let gate = MemoryMaintenance.shared

        var ran = false
        let busy = await gate.exclusive("搬迁", idleTimeout: 0.3) { () async -> String in ran = true; return "不该跑" }
        guard case .failure(.writersBusy(let jobs)) = busy else { return XCTFail("\(busy)") }
        XCTAssertTrue(jobs.contains("收尾 · conv-q-0"), "\(jobs)")
        XCTAssertTrue(MemoryMaintenance.Refusal.writersBusy(jobs).text.hasPrefix("后台还有记忆任务在写（"))
        XCTAssertFalse(ran, "等不到不进 body")
        XCTAssertNil(gate.holder)
        var regenerating = await SessionCloseout.shared.regenerating
        XCTAssertFalse(regenerating, "超时也放开日常写手")

        let waiting = Task { await gate.exclusive("搬迁", idleTimeout: 30) { () async -> String in "不该跑" } }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(gate.holder, "搬迁")
        let t0 = Date()
        waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertEqual(cancelled, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertNil(gate.holder, "停下以后还能再点")
        regenerating = await SessionCloseout.shared.regenerating
        XCTAssertFalse(regenerating, "停下也放开日常写手")

        writer.cancel()
        _ = await writer.value
    }

    /// P2：关参与窗手动压缩不写 A2，提示说清原因（真跑到 VM 入口，不是只断言值）
    /// `manualCompressContext` 没有注入假写手的口子；闸在开 `Task.detached` 之前同步返回，提示文案就是行为证据——
    /// 之前那条 `SessionSummaryStore.load == nil` 判别不了（真写也是异步，断言那一刻本来就为 nil），已删
    @MainActor
    func testManualCompressSkipsWhenWindowNotParticipating() throws {
        let vm = ConversationViewModel()
        let conv = Conversation(id: "closeout-off-window", title: "T", createTime: Date(), updateTime: Date(), currentNodeId: "")
        conv.profileId = pid
        conv.memoryEnabled = false
        vm.selectedConversation = conv
        vm.currentPath = (0..<10).map { i in
            MessageNode(id: "off-n\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "x\(i)", contentType: "text",
                        createTime: nil, parentId: nil, childrenIds: [], conversationId: conv.id, profileId: pid)
        }
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克")
        vm.manualCompressContext(contextDepth: 2, profile: profile,
                                 model: ProviderModel(credentialId: "x", modelId: "m", name: "m"),
                                 providerManager: ProviderManager())
        XCTAssertEqual(vm.transientNotice?.text, "📝 本窗不参与记忆，不写上下文摘要",
                       "关参与窗在进写手之前就返回（不加闸这里会是「📝 压缩中…」）")
    }

    /// P2-r2 建议 5：关参与窗点「现在写」→ 开头就说清，不再跑 A2/A3/A4 后报「都写到最新了」
    @MainActor
    func testWriteMemoryNowSaysWindowNotParticipating() {
        let vm = ConversationViewModel()
        let conv = Conversation(id: "closeout-write-now-off", title: "T", createTime: Date(), updateTime: Date(), currentNodeId: "")
        conv.profileId = pid
        conv.memoryEnabled = false
        vm.selectedConversation = conv
        vm.currentPath = (0..<4).map { i in
            MessageNode(id: "write-now-n\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "x\(i)", contentType: "text",
                        createTime: nil, parentId: nil, childrenIds: [], conversationId: conv.id, profileId: pid)
        }
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克")
        vm.writeMemoryNow(contextDepth: 2, profile: profile,
                          model: ProviderModel(credentialId: "x", modelId: "m", name: "m"), providerManager: ProviderManager())
        XCTAssertEqual(vm.transientNotice?.text, "📝 本窗不参与记忆，不写")
    }

    /// P2-r2 必修 2：入队时开参与，之后关参与 → 到点复查后出队，假写手零调用、没有新段
    @MainActor
    func testIdleCompressSkipsWindowTurnedOffWhileQueued() async throws {
        UserDefaults.standard.set(MemoryTriggerMode.idle.rawValue, forKey: "mem_trigger_a2")
        UserDefaults.standard.set(1, forKey: "mem_trigger_a2_idle")
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        // 两条 id 前 8 个字符必须不同：SessionSummaryStore 按前 8 位找段文件（conv-off / conv-on）
        for (id, enabled) in [("conv-off-idle", false), ("conv-on-idle", true)] {
            let conv = Conversation(id: id, title: "T", createTime: Date(), updateTime: Date(), currentNodeId: "")
            conv.profileId = pid
            conv.memoryEnabled = enabled
            context.insert(conv)
        }
        try context.save()

        let closeout = SessionCloseout()
        let pm = ProviderManager()
        let t0 = Date().addingTimeInterval(-3600)
        for id in ["conv-off-idle", "conv-on-idle"] {
            await closeout.noteIdleCompress(conversationId: id, messages: item().messages, oldCount: 4, title: "T", ctx: ctx, now: t0)
        }
        var calls: [String] = []
        await closeout.runIdleCompress(providerManager: pm, now: Date(), container: container) { _, cid in
            { _, _ in calls.append(cid); return self.goodTail }
        }
        XCTAssertEqual(calls, ["conv-on-idle"], "关参与窗不调模型；开参与的照写")
        let pending = await closeout.idleCompressPending
        XCTAssertTrue(pending.isEmpty, "关参与窗直接出队")
        XCTAssertNil(SessionSummaryStore.load(conversationId: "conv-off-idle", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)),
                     "关参与窗没有新段")
        XCTAssertEqual(SessionSummaryStore.load(conversationId: "conv-on-idle", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.compressedCount, 4)
    }

    /// P2-r2 建议 4：API 回合入口——关参与窗不入 idle 队列；开参与照常入队
    @MainActor
    func testAPITurnQueuesIdleOnlyForParticipatingWindow() async throws {
        UserDefaults.standard.set(MemoryTriggerMode.idle.rawValue, forKey: "mem_trigger_a2")
        UserDefaults.standard.set(1, forKey: "mem_trigger_a2_idle")
        let vm = ConversationViewModel()
        let profile = Profile(id: pid, name: "T", emoji: "🧪", description: "", userName: "粟粟", assistantName: "小克")
        let model = ProviderModel(credentialId: "x", modelId: "m", name: "m")
        func turn(_ id: String) -> Conversation {
            let conv = Conversation(id: id, title: "T", createTime: Date(), updateTime: Date(), currentNodeId: "")
            conv.profileId = pid
            vm.currentPath = (0..<6).map { i in
                MessageNode(id: "\(id)-n\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "x\(i)", contentType: "text",
                            createTime: nil, parentId: nil, childrenIds: [], conversationId: id, profileId: pid)
            }
            return conv
        }

        let on = turn("api-idle-on")
        vm.triggerContextSummaryIfNeeded(conversation: on, conversationId: on.id, conversationTitle: on.title,
                                         profile: profile, contextDepth: 2, model: model, providerManager: ProviderManager())
        let queued = await waitFor { await SessionCloseout.shared.idleCompressPending.contains(on.id) }
        XCTAssertTrue(queued, "开参与：API 回合入队")

        let off = turn("api-idle-off")
        off.memoryEnabled = false
        vm.triggerContextSummaryIfNeeded(conversation: off, conversationId: off.id, conversationTitle: off.title,
                                         profile: profile, contextDepth: 2, model: model, providerManager: ProviderManager())
        try? await Task.sleep(nanoseconds: 300_000_000)   // 若漏闸，入队是 Task.detached，这点时间足够跑一遍
        let pending = await SessionCloseout.shared.idleCompressPending
        XCTAssertFalse(pending.contains(off.id), "关参与：不入队")
        XCTAssertTrue(pending.contains(on.id), "另一条不受影响")

        // 清掉共享队列，免得留给下一个测试
        UserDefaults.standard.set(MemoryTriggerMode.manual.rawValue, forKey: "mem_trigger_a2")
        await SessionCloseout.shared.runIdleCompress(providerManager: ProviderManager(), now: Date())
    }

    // MARK: - P2-d：占到窗口后复查本窗参与（补跑不再绕过「本窗关参与」）

    /// A2：窗口被别的写手占着时关参与 → 释放后补跑复查，不写、不调模型（真值表「本窗关参与 · A2 写 = 否」）
    @MainActor
    func testCompressRetrySkipsWhenWindowTurnedOffWhileBusy() async throws {
        let c = try container([("cq-a2-off", "o", 6, false)])
        var ctx = ctx
        ctx.container = c
        let closeout = SessionCloseout()
        let gate = AsyncGate()
        var held = 0
        var retryCalls = 0
        async let holding = closeout.compress(messages: item().messages, oldCount: 4, conversationId: "cq-a2-off", title: "t",
                                             ctx: ctx) { _, _ in
            held += 1
            await gate.wait()
            return nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let queued = try await closeout.compress(messages: item().messages, oldCount: 4, conversationId: "cq-a2-off", title: "t",
                                                ctx: ctx) { _, _ in
            retryCalls += 1
            return self.goodTail
        }
        XCTAssertNil(queued, "被占：进了补跑")
        XCTAssertEqual(held, 1, "占位那次调了一次")

        try setMemoryEnabled(false, conversationId: "cq-a2-off", in: c)
        let start = Date()
        await gate.open()
        _ = try await holding

        let bailed = await waitFor(5) {
            CacheDiagLog.shared.entries.contains {
                $0.time >= start && $0.text.contains("上下文摘要: 窗口已关参与") && $0.text.contains("cq-a2-off")
            }
        }
        XCTAssertTrue(bailed, "补跑跑到复查后放弃")
        XCTAssertEqual(retryCalls, 0, "补跑不调模型")
        XCTAssertNil(SessionSummaryStore.load(conversationId: "cq-a2-off", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
    }

    /// A3：同形状走收尾——候选是巡检时 `memoryEnabled` 的快照，释放后补跑要复查
    @MainActor
    func testCloseoutRetrySkipsWhenWindowTurnedOffWhileBusy() async throws {
        let c = try container([("cq-a3-off", "o", 6, false)])
        let closeout = SessionCloseout()
        let gate = AsyncGate()
        async let holding = closeout.compress(messages: item().messages, oldCount: 4, conversationId: "cq-a3-off", title: "t",
                                             ctx: ctx) { _, _ in
            await gate.wait()
            return nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        var calls: [String] = []
        let queued = SessionCloseout.Candidate(conversationId: "cq-a3-off", title: "T", messages: item().messages)
        let stop = await closeout.closeout(queued, ctx: ctx, container: c) { _ in
            { system, _ in calls.append(self.kind(system)); return self.reply(system) }
        }
        XCTAssertFalse(stop, "被占：不写也不是断网")

        // 窗口开关 / 回收站本来由 `currentPath` / `source.window` 兜住，本条测的是占到窗口后新复查的提前退出（日志 + 不调模型 + 不落盘）
        try setMemoryEnabled(false, conversationId: "cq-a3-off", in: c)
        let start = Date()
        await gate.open()
        _ = try await holding

        let bailed = await waitFor(5) {
            CacheDiagLog.shared.entries.contains {
                $0.time >= start && $0.text.contains("收尾: 窗口已关参与") && $0.text.contains("cq-a3-off")
            }
        }
        XCTAssertTrue(bailed, "补跑跑到复查后放弃")
        XCTAssertEqual(calls, [], "补跑不调模型")
        XCTAssertNil(WindowSummaryStore.load(conversationId: "cq-a3-off", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
        XCTAssertNil(SessionSummaryStore.load(conversationId: "cq-a3-off", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)))
    }

    /// 对照：没关参与时补跑照写（别把补跑整个弄死）
    @MainActor
    func testCompressRetryWritesWhenWindowKeepsParticipating() async throws {
        let c = try container([("cq-a2-on-", "o", 6, false)])
        var ctx = ctx
        ctx.container = c
        let closeout = SessionCloseout()
        let gate = AsyncGate()
        var retryCalls = 0
        async let holding = closeout.compress(messages: item().messages, oldCount: 4, conversationId: "cq-a2-on-", title: "t",
                                             ctx: ctx) { _, _ in
            await gate.wait()
            return nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await closeout.compress(messages: item().messages, oldCount: 4, conversationId: "cq-a2-on-", title: "t",
                                        ctx: ctx) { _, _ in
            retryCalls += 1
            return self.goodTail
        }
        await gate.open()
        _ = try await holding

        let written = await waitFor { SessionSummaryStore.load(conversationId: "cq-a2-on-", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid))?.compressedCount == 4 }
        XCTAssertTrue(written, "开参与：补跑照写")
        XCTAssertEqual(retryCalls, 1)
    }

    @MainActor
    func testCloseoutRetryWritesWhenWindowKeepsParticipating() async throws {
        let c = try container([("cq-a3-on-", "o", 6, false)])
        let closeout = SessionCloseout()
        let gate = AsyncGate()
        async let holding = closeout.compress(messages: item().messages, oldCount: 4, conversationId: "cq-a3-on-", title: "t",
                                             ctx: ctx) { _, _ in
            await gate.wait()
            return nil
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        var calls: [String] = []
        let queued = SessionCloseout.Candidate(conversationId: "cq-a3-on-", title: "T", messages: item().messages)
        _ = await closeout.closeout(queued, ctx: ctx, container: c) { _ in
            { system, _ in calls.append(self.kind(system)); return self.reply(system) }
        }
        await gate.open()
        _ = try await holding

        let written = await waitFor { WindowSummaryStore.load(conversationId: "cq-a3-on-", memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) != nil }
        XCTAssertTrue(written, "开参与：补跑照写 A3")
        XCTAssertTrue(calls.contains("window"))
    }

    /// 改窗口参与开关并落盘（补跑复查读的就是库里的当前值）
    @MainActor
    private func setMemoryEnabled(_ enabled: Bool, conversationId: String, in container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let pid0 = pid, cid = conversationId
        let conv = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate {
            $0.profileId == pid0 && $0.id == cid
        })).first
        conv?.memoryEnabled = enabled
        try context.save()
    }

    /// 轮询到条件成立（入队走 Task.detached，需要等它跑）
    @MainActor
    private func waitFor(_ deadline: TimeInterval = 2, _ check: @MainActor () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if await check() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}
