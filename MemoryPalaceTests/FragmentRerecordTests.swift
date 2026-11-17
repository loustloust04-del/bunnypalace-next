import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 对话 ⋯「重新记这个窗口」：水位挪回起点、一批接一批跑到追上、被拦下停在批次边界、接着跑、确认框的字。
/// 假 caller，不调模型；对话全虚构
final class FragmentRerecordTests: XCTestCase {
    private let pid = "xctest-fragment-rerecord"
    private let cid = "conv-rerecord"
    private let names = MemoryExtractor.Names(userName: "岚舟", assistantName: "星砚")
    private let t0: TimeInterval = 1_790_000_000

    private var savedSwitches: [(String, Any?)] = []

    override func setUp() {
        super.setUp()
        savedSwitches = ["mem_master", "mem_content_facts"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for (key, _) in savedSwitches { UserDefaults.standard.set(true, forKey: key) }
    }

    override func tearDown() {
        for (key, value) in savedSwitches {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func tempDefaults() -> UserDefaults {
        let suite = "xctest-fragment-rerecord-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    /// 一条主线：第 k 句，隔一小时一条；chars = 每条多长
    private func window(_ count: Int, chars: Int = 12) throws -> ModelContainer {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(Conversation(id: cid, title: "模型船", createTime: Date(timeIntervalSince1970: t0),
                                    updateTime: Date(timeIntervalSince1970: t0), currentNodeId: "n\(count - 1)", profileId: pid))
        try append(count, from: 0, chars: chars, context: context)
        return container
    }

    private func append(_ count: Int, from: Int, chars: Int, context: ModelContext) throws {
        for k in from..<(from + count) {
            let head = "第\(k)句"
            context.insert(MessageNode(id: "n\(k)", role: k % 2 == 0 ? "user" : "assistant",
                                       content: head + String(repeating: "长", count: max(0, chars - head.count)), contentType: "text",
                                       createTime: Date(timeIntervalSince1970: t0 + TimeInterval(k * 3600)),
                                       parentId: k == 0 ? nil : "n\(k - 1)", childrenIds: k == from + count - 1 ? [] : ["n\(k + 1)"],
                                       conversationId: cid, profileId: pid))
        }
        try context.save()
    }

    /// dreams 默认关：这里测的是写手那一圈（认领 / 水位 / 续跑）；写完接「C2 整理」的那一条另测（`testDreamRunsAfterEachBatch…`）
    private func makeJob(_ container: ModelContainer, watch: FragmentWatch, every: Int = 30, dreams: Bool = false,
                     caller: @escaping SessionSegmentWriter.Caller) -> FragmentBatch.Job {
        FragmentBatch.Job(conversationId: cid, profileId: pid, names: names, caller: caller, local: false, modelName: "测试模型",
                          fallbackNote: nil, whole: true, every: every, container: container, watch: watch, dreams: dreams)
    }

    private actor Calls {
        var users: [String] = []
        func next(_ user: String) -> Int {
            users.append(user)
            return users.count - 1
        }
    }

    private func card(_ n: Int) -> String {
        #"[{"subject":"岚舟","type":"fact","origin":"said","content":"第 \#(n) 次交的卡。","msgs":[1]}]"#
    }

    /// 这次调用的新对话：几条、第一条是第几句
    private func span(_ user: String) -> (count: Int, first: String) {
        let tail = user.components(separatedBy: "## 新对话（#1–#").last ?? ""
        let count = Int(tail.prefix { $0.isNumber }) ?? -1
        let first = tail.components(separatedBy: "\n").first { $0.hasPrefix("#1 ") } ?? ""
        return (count, String(first.components(separatedBy: "：").last?.prefix { $0 != "长" } ?? ""))
    }

    private func ids(_ n: Int) -> (ids: [String], dates: [Date?]) {
        ((0..<n).map { "n\($0)" }, (0..<n).map { Date(timeIntervalSince1970: t0 + TimeInterval($0 * 3600)) })
    }

    func testRewindMovesTheWatermarkBackAndDueClaimsFromThere() async {
        let defaults = tempDefaults()
        let watch = FragmentWatch(defaults: defaults)
        let p = ids(100)
        let sizes = Array(repeating: 100, count: 100)
        let first = await watch.due(conversationId: cid, pathIds: p.ids, dates: p.dates, threshold: 40, sizes: sizes, maxChars: 4000)
        XCTAssertNil(first, "第一次见这个窗口：水位直接放在最后一条")
        var backlog = await watch.backlog(conversationId: cid, pathIds: p.ids)
        XCTAssertEqual(backlog, 0)

        var moved = await watch.rewind(conversationId: cid, pathIds: p.ids, dates: p.dates, start: 30)
        XCTAssertTrue(moved)
        backlog = await watch.backlog(conversationId: cid, pathIds: p.ids)
        XCTAssertEqual(backlog, 70)
        let middle = await watch.due(conversationId: cid, pathIds: p.ids, dates: p.dates, threshold: 40, sizes: sizes, maxChars: 4000)
        XCTAssertEqual(middle?.range, 30..<70, "从起点那条开始认领一批")
        moved = await watch.rewind(conversationId: cid, pathIds: p.ids, dates: p.dates, start: 0)
        XCTAssertFalse(moved, "这个窗口正有一截在跑：不挪")
        await watch.release(conversationId: cid, token: middle!.token)

        moved = await watch.rewind(conversationId: cid, pathIds: p.ids, dates: p.dates, start: 0)
        XCTAssertTrue(moved)
        backlog = await watch.backlog(conversationId: cid, pathIds: p.ids)
        XCTAssertEqual(backlog, 100, "起点就是第一条：水位放在第一条之前")
        let head = await watch.due(conversationId: cid, pathIds: p.ids, dates: p.dates, threshold: 40, sizes: sizes, maxChars: 4000)
        XCTAssertEqual(head?.range, 0..<40)
        await watch.commit(conversationId: cid, token: head!.token)
        let next = await watch.due(conversationId: cid, pathIds: p.ids, dates: p.dates, threshold: 40, sizes: sizes, maxChars: 4000)
        XCTAssertEqual(next?.range, 40..<80, "提交后接着下一批")
        await watch.release(conversationId: cid, token: next!.token)

        let reopened = FragmentWatch(defaults: defaults)
        let redoing = await reopened.isRedoing(conversationId: cid)
        XCTAssertTrue(redoing, "没追上之前重启 app 也记得在重新记")
        backlog = await reopened.backlog(conversationId: cid, pathIds: p.ids)
        XCTAssertEqual(backlog, 60)
        await reopened.endRedo(conversationId: cid)
        let ended = await FragmentWatch(defaults: defaults).isRedoing(conversationId: cid)
        XCTAssertFalse(ended)

        let unseen = await FragmentWatch(defaults: tempDefaults()).backlog(conversationId: cid, pathIds: p.ids)
        XCTAssertNil(unseen, "没见过的窗口没有水位")
    }

    func testPlanCountsBatchesTheSameWayTheWriterClaimsThem() {
        let dates = ids(75).dates
        let big = Array(repeating: 2000, count: 75)
        let whole = FragmentRerecord.plan(dates: dates, sizes: big, startDay: nil, every: 30)
        XCTAssertEqual([whole.start, whole.messages, whole.batches, whole.chars], [0, 75, 3, 150_000], "30 + 30 + 尾巴 15")
        XCTAssertFalse(whole.resumed)
        XCTAssertEqual(whole.from, dates[0])
        let later = FragmentRerecord.plan(dates: dates, sizes: big, startDay: Date(timeIntervalSince1970: t0 + 20.5 * 3600), every: 30)
        XCTAssertEqual([later.start, later.messages, later.batches], [21, 54, 2], "起点以后 54 条：30 + 尾巴 24")
        let resumed = FragmentRerecord.plan(dates: dates, sizes: big, startDay: nil, every: 30, resumeAt: 60)
        XCTAssertEqual([resumed.start, resumed.messages, resumed.batches], [60, 15, 1])
        XCTAssertTrue(resumed.resumed)
        let short = FragmentRerecord.plan(dates: dates, sizes: big, startDay: Date(timeIntervalSince1970: t0 + 70.5 * 3600), every: 30)
        XCTAssertEqual([short.start, short.messages, short.batches], [71, 4, 0], "不到 10 条：一批都没有")
        let none = FragmentRerecord.plan(dates: dates, sizes: big, startDay: .distantFuture, every: 30)
        XCTAssertEqual([none.start, none.messages, none.batches], [75, 0, 0])
    }

    func testRunsBatchAfterBatchUntilCaughtUpIncludingTheTail() async throws {
        let container = try window(75, chars: 2000)
        let watch = FragmentWatch(defaults: tempDefaults())
        let seeded = await watch.due(conversationId: cid, pathIds: ids(75).ids, dates: ids(75).dates, threshold: 30)
        XCTAssertNil(seeded, "装新版之前聊的：水位在最后一条，自动那条路一条都不会记")
        let calls = Calls()
        let job = makeJob(container, watch: watch) { _, user in self.card(await calls.next(user)) }
        let plan = FragmentRerecord.plan(dates: ids(75).dates, sizes: Array(repeating: 2000, count: 75), startDay: nil, every: 30)
        var progress: [String] = []
        let report = await FragmentRerecord.begin(job, plan: plan, startDay: nil) { batch, of in progress.append("\(batch)/\(of)") }

        XCTAssertEqual(report, .init(batches: 3, added: 3, stop: .caughtUp))
        XCTAssertEqual(progress, ["1/3", "2/3", "3/3"])
        let users = await calls.users
        XCTAssertEqual(users.count, 6, "每批写一次、核对一次")
        XCTAssertEqual([0, 2, 4].map { span(users[$0]).count }, [30, 30, 15], "两批整的 + 不够一批但满 10 条的尾巴")
        XCTAssertEqual([0, 2, 4].map { span(users[$0]).first }, ["第0句", "第30句", "第60句"], "没设起点：从窗口第一条开始，一批接一批")
        XCTAssertTrue(users[0].contains("## 已记的卡\n\n（空）") && users[0].contains("不要记）\n\n（没有）"))
        XCTAssertTrue(users[2].contains("- 岚舟：第 1 次交的卡。"), "第二批带着第一批记下的卡")
        XCTAssertFalse(users[2].contains("不要记）\n\n（没有）"), "第二批带前文")
        XCTAssertTrue(users[1].contains("## 你刚交的这一批"))
        let backlog = await watch.backlog(conversationId: cid, pathIds: ids(75).ids)
        XCTAssertEqual(backlog, 0)
        let redoing = await watch.isRedoing(conversationId: cid)
        XCTAssertFalse(redoing, "追上了就不算在重新记")
        let stored = SwiftDataMemoryStore().listAll(profileId: pid, context: ModelContext(container))
        XCTAssertEqual(Set(stored.map(\.content)), ["第 1 次交的卡。", "第 3 次交的卡。", "第 5 次交的卡。"], "落库的是核对后的那份")
        XCTAssertEqual(Set(stored.compactMap(\.sourceConversationId)), [cid])
        MemoryWriteLog.flush()
        let notes = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { $0.writer == "C2" }.map(\.note)
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes.contains { $0.contains("重新记 · 第 2 / 3 批") && $0.contains("写 + 核对") }, "写入记录里看得到第几批")
    }

    func testShortLeftoverIsNotWritten() async throws {
        let container = try window(65, chars: 2000)
        let watch = FragmentWatch(defaults: tempDefaults())
        let calls = Calls()
        let job = makeJob(container, watch: watch) { _, user in self.card(await calls.next(user)) }
        let plan = FragmentRerecord.plan(dates: ids(65).dates, sizes: Array(repeating: 2000, count: 65), startDay: nil, every: 30)
        XCTAssertEqual(plan.batches, 2)
        let report = await FragmentRerecord.begin(job, plan: plan, startDay: nil)
        XCTAssertEqual(report, .init(batches: 2, added: 2, stop: .caughtUp))
        let backlog = await watch.backlog(conversationId: cid, pathIds: ids(65).ids)
        XCTAssertEqual(backlog, 5, "最后 5 条不到 10 条，留给以后攒够了再写")
    }

    func testStartDaySkipsEarlierMessages() async throws {
        let container = try window(50)
        let watch = FragmentWatch(defaults: tempDefaults())
        let calls = Calls()
        let job = makeJob(container, watch: watch) { _, user in self.card(await calls.next(user)) }
        let startDay = Date(timeIntervalSince1970: t0 + 20.5 * 3600)
        let plan = FragmentRerecord.plan(dates: ids(50).dates, sizes: Array(repeating: 12, count: 50), startDay: startDay, every: 30)
        XCTAssertEqual([plan.start, plan.batches], [21, 1])
        let report = await FragmentRerecord.begin(job, plan: plan, startDay: startDay)
        XCTAssertEqual(report, .init(batches: 1, added: 1, stop: .caughtUp))
        let users = await calls.users
        XCTAssertEqual(span(users[0]).count, 29, "字数装得下：起点之后的一次全带上")
        XCTAssertEqual(span(users[0]).first, "第21句", "起点那天之后的第一条")
        XCTAssertTrue(users[0].contains("#0 ") && users[0].contains("第20句"), "起点以前的只当前文看")
    }

    func testStopsAtTheBatchBoundaryWhenBlockedAndResumesFromThere() async throws {
        let container = try window(75, chars: 2000)
        let watch = FragmentWatch(defaults: tempDefaults())
        let calls = Calls()
        // 第一批两次调用照常；第二批开头就被拦下（写入预算用完 = caller 回 nil）
        let blocked = makeJob(container, watch: watch) { _, user in
            let n = await calls.next(user)
            return n < 2 ? self.card(n) : nil
        }
        let sizes = Array(repeating: 2000, count: 75)
        let plan = FragmentRerecord.plan(dates: ids(75).dates, sizes: sizes, startDay: nil, every: 30)
        let stopped = await FragmentRerecord.begin(blocked, plan: plan, startDay: nil)
        XCTAssertEqual(stopped, .init(batches: 1, added: 1, stop: .skipped))
        var backlog = await watch.backlog(conversationId: cid, pathIds: ids(75).ids)
        XCTAssertEqual(backlog, 45, "水位停在写完的那一批后面")
        var redoing = await watch.isRedoing(conversationId: cid)
        XCTAssertTrue(redoing)
        let held = await watch.claimed(conversationId: cid)
        XCTAssertFalse(held, "没写成的那批认领放回了")

        let again = Calls()
        let open = makeJob(container, watch: watch) { _, user in self.card(10 + (await again.next(user))) }
        let resume = FragmentRerecord.plan(dates: ids(75).dates, sizes: sizes, startDay: nil, every: 30, resumeAt: 75 - (backlog ?? 0))
        XCTAssertEqual([resume.start, resume.batches], [30, 2])
        let finished = await FragmentRerecord.begin(open, plan: resume, startDay: nil)
        XCTAssertEqual(finished, .init(batches: 2, added: 2, stop: .caughtUp))
        let users = await again.users
        XCTAssertEqual(span(users[0]).first, "第30句", "接着跑：不回到起点")
        XCTAssertTrue(users[0].contains("- 岚舟：第 1 次交的卡。"), "上次记下的照常当已记的卡")
        backlog = await watch.backlog(conversationId: cid, pathIds: ids(75).ids)
        XCTAssertEqual(backlog, 0)
        redoing = await watch.isRedoing(conversationId: cid)
        XCTAssertFalse(redoing)
        let stored = SwiftDataMemoryStore().listAll(profileId: pid, context: ModelContext(container))
        XCTAssertEqual(stored.count, 3)
    }

    /// 有一批两次都不是合格 JSON：停在这批前面（水位不动、记了失败、不接着试后面的）；
    /// 自动那条路要等冷却，她再点不用等，接着从这一批跑
    func testFormatFailureStopsBeforeThatBatchAndTappingAgainResumesRightAway() async throws {
        let container = try window(75, chars: 2000)
        let watch = FragmentWatch(defaults: tempDefaults())
        let calls = Calls()
        let broken = makeJob(container, watch: watch) { _, user in
            let n = await calls.next(user)
            return n < 2 ? self.card(n) : "我想想"
        }
        let sizes = Array(repeating: 2000, count: 75)
        let plan = FragmentRerecord.plan(dates: ids(75).dates, sizes: sizes, startDay: nil, every: 30)
        let stopped = await FragmentRerecord.begin(broken, plan: plan, startDay: nil)
        XCTAssertEqual(stopped, .init(batches: 1, added: 1, stop: .failed))
        XCTAssertTrue(FragmentRerecord.summary(stopped).contains("再点接着记"))
        let count = await calls.users.count
        XCTAssertEqual(count, 4, "第二批写一次、格式重写一次就停")
        let backlog = await watch.backlog(conversationId: cid, pathIds: ids(75).ids)
        XCTAssertEqual(backlog, 45, "水位停在写完的那一批后面")
        let auto = await watch.due(conversationId: cid, pathIds: ids(75).ids, dates: ids(75).dates, threshold: 30, sizes: sizes)
        XCTAssertNil(auto, "冷却里自动那条路不认领")

        let again = Calls()
        let open = makeJob(container, watch: watch) { _, user in self.card(10 + (await again.next(user))) }
        let resume = FragmentRerecord.plan(dates: ids(75).dates, sizes: sizes, startDay: nil, every: 30, resumeAt: 30)
        let finished = await FragmentRerecord.begin(open, plan: resume, startDay: nil)
        XCTAssertEqual(finished, .init(batches: 2, added: 2, stop: .caughtUp))
        let users = await again.users
        XCTAssertEqual(users.first.map { span($0).first }, "第30句", "接着从没写成的那一批跑")
    }

    func testMessagesArrivingWhileItRunsAreQueuedBehind() async throws {
        let container = try window(75, chars: 2000)
        let watch = FragmentWatch(defaults: tempDefaults())
        let calls = Calls()
        let job = makeJob(container, watch: watch) { _, user in
            let n = await calls.next(user)
            if n == 0 {
                // 第一批还在写的时候她又聊了 12 条
                let context = ModelContext(container)
                try self.append(12, from: 75, chars: 2000, context: context)
                let wanted = self.cid
                let conv = try XCTUnwrap(try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == wanted })).first)
                let last = try XCTUnwrap(try context.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "n74" })).first)
                last.childrenIds = ["n75"]
                conv.currentNodeId = "n86"
                try context.save()
            }
            return self.card(n)
        }
        let plan = FragmentRerecord.plan(dates: ids(75).dates, sizes: Array(repeating: 2000, count: 75), startDay: nil, every: 30)
        let report = await FragmentRerecord.begin(job, plan: plan, startDay: nil)
        XCTAssertEqual(report, .init(batches: 3, added: 3, stop: .caughtUp))
        let users = await calls.users
        XCTAssertEqual([0, 2, 4].map { span(users[$0]).count }, [30, 30, 27], "新来的排在后面，跟着尾巴一起记")
        let backlog = await watch.backlog(conversationId: cid, pathIds: ids(87).ids)
        XCTAssertEqual(backlog, 0)
    }

    func testBusyWindowAndMissingWindowStopWithoutTouchingAnything() async throws {
        let container = try window(40)
        let watch = FragmentWatch(defaults: tempDefaults())
        let p = ids(40)
        _ = await watch.rewind(conversationId: cid, pathIds: p.ids, dates: p.dates, start: 0)
        let auto = await watch.due(conversationId: cid, pathIds: p.ids, dates: p.dates, threshold: 30)
        XCTAssertNotNil(auto, "自动那条路先认领了一批")
        let calls = Calls()
        let job = makeJob(container, watch: watch) { _, user in self.card(await calls.next(user)) }
        let plan = FragmentRerecord.plan(dates: p.dates, sizes: Array(repeating: 12, count: 40), startDay: nil, every: 30)
        let fresh = await FragmentRerecord.begin(job, plan: plan, startDay: nil)
        XCTAssertEqual(fresh.stop, .busy, "正有一截在跑：不挪水位、不跑")
        let waiting = await FragmentRerecord.run(job, total: 1, pause: .milliseconds(1), maxWaits: 2)
        XCTAssertEqual(waiting, .init(batches: 0, added: 0, stop: .busy), "等不到它交回就先停下")
        let count = await calls.users.count
        XCTAssertEqual(count, 0)
        let holds = await watch.holds(conversationId: cid, token: auto!.token)
        XCTAssertTrue(holds, "别人的认领没被动")

        let other = FragmentBatch.Job(conversationId: "conv-nowhere", profileId: pid, names: names, caller: job.caller, local: false,
                                      modelName: "测试模型", fallbackNote: nil, whole: true, every: 30, container: container, watch: watch, dreams: false)
        let gone = await FragmentRerecord.begin(other, plan: plan, startDay: nil)
        XCTAssertEqual(gone.stop, .gone)
    }

    /// 写成一批就接「C2 整理」：写 → 核对 → 做梦，下一批开写时看到的是上一批做完梦之后的样子（删掉的不再当「已记的卡」）
    func testDreamRunsAfterEachBatchAndTheNextBatchSeesItsResult() async throws {
        let container = try window(75, chars: 2000)
        let watch = FragmentWatch(defaults: tempDefaults())
        _ = await watch.due(conversationId: cid, pathIds: ids(75).ids, dates: ids(75).dates, threshold: 30)
        let calls = Calls()
        let job = makeJob(container, watch: watch, dreams: true) { system, user in
            let n = await calls.next(user)
            guard system.hasPrefix("你在核对一批刚写好的记忆条目") else { return self.card(n) }
            // 第二批的那张判删，别的留下
            return n == 5 ? #"{"verdicts":[{"card":"N1","verdict":"drop","reason":"not_fact","why":"第二批这张不值得长期记"}]}"#
                          : #"{"verdicts":[{"card":"N1","verdict":"keep","why":"留下"}]}"#
        }
        let plan = FragmentRerecord.plan(dates: ids(75).dates, sizes: Array(repeating: 2000, count: 75), startDay: nil, every: 30)
        let report = await FragmentRerecord.begin(job, plan: plan, startDay: nil)

        XCTAssertEqual(report, .init(batches: 3, added: 3, stop: .caughtUp), "做梦删了一张不改写手那头的数")
        let users = await calls.users
        XCTAssertEqual(users.map { $0.hasPrefix("这段对话所在的窗口叫") ? "梦" : "写" }, ["写", "写", "梦", "写", "写", "梦", "写", "写", "梦"],
                       "每批：写一次、核对一次、做梦一次，做完才写下一批")
        XCTAssertTrue(users[2].contains("## 新卡（N1–N1，每张给一个结论）\n\n[N1] 第 1 次交的卡。") && users[2].contains("## 原文（#1–#30）"),
                      "做梦看的是这一批的原文和刚落库的那张")
        XCTAssertTrue(users[5].contains("[E1] 第 1 次交的卡。"), "第二批做梦时，第一批留下的那张是「已有的卡」")
        XCTAssertTrue(users[6].contains("- 岚舟：第 1 次交的卡。") && !users[6].contains("第 4 次交的卡"), "第三批开写时，第二批被删的那张已经不在「已记的卡」里")
        let stored = SwiftDataMemoryStore().listAll(profileId: pid, context: ModelContext(container))
        XCTAssertEqual(Set(stored.filter { $0.supersededAt == nil }.map(\.content)), ["第 1 次交的卡。", "第 7 次交的卡。"])
        XCTAssertEqual(stored.filter { $0.supersededAt != nil }.map(\.content), ["第 4 次交的卡。"])
        MemoryWriteLog.flush()
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        let dreams = MemoryWriteLog.entries(memoryRoot: root).filter { $0.dream != nil }
        XCTAssertEqual(Set(dreams.map(\.note)), ["Keep 1 · 重新记 · 第 1 / 3 批", "Drop 1 · 重新记 · 第 2 / 3 批", "Keep 1 · 重新记 · 第 3 / 3 批"])
        let audit = MemoryAuditLog.load(memoryRoot: root)
        XCTAssertEqual(audit.map(\.actor), [FragmentDream.actor])
        XCTAssertEqual(audit.first?.note, "第二批这张不值得长期记")
    }

    func testConfirmTextSaysWhatWillHappen() {
        let dates = ids(75).dates
        let plan = FragmentRerecord.plan(dates: dates, sizes: Array(repeating: 2000, count: 75), startDay: nil, every: 30)
        let day = MemoryStartDay.format(dates[0]!)
        let open = FragmentRerecord.confirmText(plan, startDay: nil, cost: 0.42, budget: 3)
        XCTAssertTrue(open.canRun)
        XCTAssertEqual(open.text, """
        没设「记忆从哪天开始」，从这个窗口第一条（\(day)）起，有 75 条要读，大约分 3 批，每批调两次模型（写一次、核对一次）。
        估计花 $0.42 左右，写入预算还剩 $3.00，够。
        这个窗口已有的记忆条目不动。以前这个窗口记过又被删掉的事，可能会再出现。
        """)
        let dreaming = FragmentRerecord.confirmText(plan, startDay: nil, cost: 0.42, budget: 3, dream: true)
        XCTAssertEqual(dreaming.text, """
        没设「记忆从哪天开始」，从这个窗口第一条（\(day)）起，有 75 条要读，大约分 3 批，每批调三次模型（写一次、核对一次、写完自动整理一次）。
        估计花 $0.42 左右，写入预算还剩 $3.00，够。
        新条目里和已有的说同一件事的会并进去，已有的那条可能跟着改（记忆日志里每一笔能 Undo）。以前这个窗口记过又被删掉的事，可能会再出现。
        """)
        let plain = FragmentRerecord.estimatedUsage(plan), more = FragmentRerecord.estimatedUsage(plan, dream: true)
        XCTAssertEqual(more.input - plain.input, plan.chars + plan.batches * (FragmentVerdict.Limits().maxResidentChars + 6_000), "做梦那一次也算进估价")
        XCTAssertEqual(more.output - plain.output, plan.batches * 3_000)
        let tight = FragmentRerecord.confirmText(plan, startDay: dates[0], cost: 0.42, budget: 0.1)
        XCTAssertTrue(tight.canRun)
        XCTAssertTrue(tight.text.hasPrefix("从「记忆从哪天开始」之后的第一条（\(day)）起，有 75 条要读"))
        XCTAssertTrue(tight.text.contains("写入预算只剩 $0.10，不够：写到预算用完会停下，下次再点接着记。"))
        XCTAssertTrue(FragmentRerecord.confirmText(plan, startDay: nil, cost: 0.004, budget: nil).text.contains("估计花不到 $0.01；写入预算没开，不限。"))
        XCTAssertTrue(FragmentRerecord.confirmText(plan, startDay: nil, cost: nil, budget: nil).text.contains("这个模型没标价，估不出花多少"))
        let out = FragmentRerecord.confirmText(plan, startDay: nil, cost: 0.42, budget: 0)
        XCTAssertFalse(out.canRun)
        XCTAssertTrue(out.text.hasPrefix("写入预算已经用完"))
        let resumed = FragmentRerecord.plan(dates: dates, sizes: Array(repeating: 2000, count: 75), startDay: nil, every: 30, resumeAt: 30)
        XCTAssertTrue(FragmentRerecord.confirmText(resumed, startDay: nil, cost: nil, budget: nil).text.hasPrefix("接着上次没记完的：从 "))
        let short = FragmentRerecord.plan(dates: dates, sizes: Array(repeating: 2000, count: 75), startDay: nil, every: 30, resumeAt: 70)
        XCTAssertFalse(FragmentRerecord.confirmText(short, startDay: nil, cost: nil, budget: nil).canRun)

        XCTAssertEqual(FragmentRerecord.summary(.init(batches: 3, added: 12, stop: .caughtUp)), "📝 重新记完了：写完 3 批、记下 12 条")
        XCTAssertEqual(FragmentRerecord.summary(.init(batches: 1, added: 4, stop: .skipped), budgetOut: true),
                       "📝 写入预算用完，停下了（写完 1 批、记下 4 条）。下次再点接着记")
        XCTAssertTrue(FragmentRerecord.summary(.init(batches: 0, added: 0, stop: .failed)).contains("一批都没写"))
    }
}
