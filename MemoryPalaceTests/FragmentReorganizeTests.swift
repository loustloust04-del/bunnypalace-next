import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 手动「重新整理」（`FragmentReorganize`）：挑哪些卡、怎么分批、确认框的字、一批接一批走现有的「C2 整理」、
/// 停在批次边界和接着跑、格式不对的那批跳过后只补它。假 caller，不调模型；对话和卡全虚构
final class FragmentReorganizeTests: XCTestCase {
    private let pid = "xctest-fragment-reorganize"
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
        super.tearDown()
    }

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c2-reorganize-\(UUID().uuidString)")
        addTeardownBlock {
            MemoryWriteLog.flush()
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func tempDefaults(dream: Bool = true, review: Bool = true) -> UserDefaults {
        let suite = "xctest-fragment-reorganize-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        d.set(dream, forKey: FragmentDream.enabledKey)
        d.set(review, forKey: FragmentDream.reviewKey)
        return d
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// 一个窗口一条主线：节点 id = "{cid}-{k}"，每条 chars 个字，隔一小时一条。cc = 回复是从 CC 那条路落地的
    private func window(_ cid: String, title: String, count: Int, chars: Int = 2000, cc: Bool = false, in context: ModelContext) throws {
        context.insert(Conversation(id: cid, title: title, createTime: Date(timeIntervalSince1970: t0),
                                    updateTime: Date(timeIntervalSince1970: t0), currentNodeId: "\(cid)-\(count - 1)", profileId: pid))
        for k in 0..<count {
            let head = "\(title)第\(k)句"
            let node = MessageNode(id: "\(cid)-\(k)", role: k % 2 == 0 ? "user" : "assistant",
                                   content: head + String(repeating: "长", count: max(0, chars - head.count)), contentType: "text",
                                   createTime: Date(timeIntervalSince1970: t0 + TimeInterval(k * 3600)),
                                   parentId: k == 0 ? nil : "\(cid)-\(k - 1)", childrenIds: k == count - 1 ? [] : ["\(cid)-\(k + 1)"],
                                   conversationId: cid, profileId: pid)
            if cc, node.role == "assistant" { node.ccMessageId = "cc-\(k)" }
            context.insert(node)
        }
        try context.save()
    }

    /// 一张 C2 写的卡（Draft）。age 越大建得越早
    @discardableResult
    private func card(_ text: String, window: String?, node: String?, age: TimeInterval, fragment: Bool = true, in context: ModelContext) -> Memory {
        let m = Memory(content: text, category: "fact", keywords: [], profileId: pid, extractedBy: "测试", sourceConversationId: window)
        m.subject = "岚舟"
        m.speaker = "用户自述"
        m.sourceNodeId = node
        if fragment { m.occurredDay = "2026-11-01" }
        m.createdAt = Date().addingTimeInterval(-age)
        context.insert(m)
        return m
    }

    private actor Calls {
        var systems: [String] = []
        var users: [String] = []
        func next(_ system: String, _ user: String) -> Int {
            systems.append(system)
            users.append(user)
            return users.count
        }
    }

    /// 这次送去几张新卡
    private func newCount(_ user: String) -> Int {
        Int((user.components(separatedBy: "## 新卡（N1–N").last ?? "").prefix { $0.isNumber }) ?? 0
    }

    private func verdicts(_ user: String, _ verdict: String = #""verdict":"keep""#) -> String {
        let rows = (1...max(newCount(user), 1)).map { #"{"card":"N\#($0)",\#(verdict),"why":"岚舟亲口说的"}"# }
        return "{\"verdicts\":[\(rows.joined(separator: ","))]}"
    }

    private func job(_ container: ModelContainer, caller: @escaping SessionSegmentWriter.Caller, local: Bool = false,
                     resident: [FragmentVerdict.ResidentSection] = []) -> (String) async -> FragmentBatch.Job? {
        let pid = pid, names = names
        let watch = FragmentWatch(defaults: tempDefaults())
        return { cid in
            FragmentBatch.Job(conversationId: cid, profileId: pid, names: names, caller: caller, local: local, modelName: "测试模型",
                              fallbackNote: nil, whole: true, every: 30, container: container, watch: watch, resident: { resident })
        }
    }

    private func prepare(_ container: ModelContainer, defaults: UserDefaults, root: URL, budget: Double? = nil) -> FragmentReorganize.Prompt {
        FragmentReorganize.prepare(profileId: pid, host: UUID(), container: container, every: 30, defaults: defaults, memoryRoot: root,
                                   cost: { input, _ in Double(input) / 1_000_000 }, budget: budget)
    }

    // MARK: - 分批（纯函数）

    func testSpansFollowTheWritersCutAndShortLeftoverJoinsTheLastOne() {
        // 每条 2000 字、每满 30 条一批：30 条正好 6 万字
        XCTAssertEqual(FragmentReorganize.spans(sizes: Array(repeating: 2000, count: 75), every: 30), [0..<30, 30..<60, 60..<75])
        XCTAssertEqual(FragmentReorganize.spans(sizes: Array(repeating: 2000, count: 65), every: 30), [0..<30, 30..<65], "最后 5 条不够一批：并进前一截")
        XCTAssertEqual(FragmentReorganize.spans(sizes: Array(repeating: 2000, count: 6), every: 30), [0..<6], "整个窗口都不够一批：自己一截")
        XCTAssertEqual(FragmentReorganize.spans(sizes: [], every: 30), [])
    }

    func testCardsGoToTheSpanTheirSourceMessageIsInAndUnplacedOnesAreCounted() {
        let ids = (0..<75).map { "n\($0)" }
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        let cards = [FragmentReorganize.Card(id: a, conversationId: "w", nodeId: "n70"), .init(id: b, conversationId: "w", nodeId: "n5"),
                     .init(id: c, conversationId: "w", nodeId: "n2"), .init(id: d, conversationId: "w", nodeId: "不在主线上"),
                     .init(id: e, conversationId: "w", nodeId: nil)]
        let placed = FragmentReorganize.place(cards, pathIds: ids, sizes: Array(repeating: 2000, count: 75), every: 30)
        XCTAssertEqual(placed.batches, [.init(range: 0..<30, cards: [c, b]), .init(range: 60..<75, cards: [a])], "没有卡的那一截不出批；批里按出处先后")
        XCTAssertEqual(placed.missing, 2)
    }

    func testPlanGroupsByWindowAndCountsCardsWhoseSourceIsGone() {
        let cards = [FragmentReorganize.Card(id: UUID(), conversationId: "甲", nodeId: "a1"), .init(id: UUID(), conversationId: "乙", nodeId: "b40"),
                     .init(id: UUID(), conversationId: "甲", nodeId: "a12"), .init(id: UUID(), conversationId: nil, nodeId: "x"),
                     .init(id: UUID(), conversationId: "删了的窗口", nodeId: "z1"), .init(id: UUID(), conversationId: "乙", nodeId: "不在了"),
                     .init(id: UUID(), conversationId: "丙", nodeId: "也不在")]
        let plan = FragmentReorganize.plan(cards, resumed: false, every: 30) { cid in
            switch cid {
            case "甲": return ((0..<20).map { "a\($0)" }, Array(repeating: 100, count: 20))
            case "乙": return ((0..<75).map { "b\($0)" }, Array(repeating: 2000, count: 75))
            case "丙": return ((0..<20).map { "c\($0)" }, Array(repeating: 100, count: 20))
            default: return nil
            }
        }
        XCTAssertEqual(plan.windows.map(\.conversationId), ["甲", "乙"])
        XCTAssertEqual([plan.cards, plan.batches, plan.chars], [3, 2, 20 * 100 + 30 * 2000])
        XCTAssertEqual([plan.missing, plan.orphans], [4, 3], "没记来源窗口的、窗口没了的、整窗出处都不在的不进 windows；乙窗那张单算")
    }

    // MARK: - 能不能点、确认框、跑完那句

    func testBlockedSaysWhy() {
        XCTAssertNil(FragmentReorganize.blocked(master: true, facts: true, choice: ""))
        XCTAssertNil(FragmentReorganize.blocked(master: true, facts: true, choice: "某张卡上的云上模型"))
        XCTAssertEqual(FragmentReorganize.blocked(master: false, facts: true, choice: ""), "记忆总开关或 C2 原子事实关着，整理不了")
        XCTAssertEqual(FragmentReorganize.blocked(master: true, facts: false, choice: ""), "记忆总开关或 C2 原子事实关着，整理不了")
        XCTAssertEqual(FragmentReorganize.blocked(master: true, facts: true, choice: FragmentModelRoute.localPrefix + "任意一款"),
                       "C2 选的是本机模型，装不下整理要读的材料；换成云上模型才能整理")
    }

    func testConfirmTextSaysWhatWillHappen() {
        var plan = FragmentReorganize.Plan(windows: [.init(conversationId: "甲", cards: []), .init(conversationId: "乙", cards: [])],
                                           cards: 12, batches: 3, chars: 90_000)
        var confirm = FragmentReorganize.confirmText(plan, cost: 0.31, budget: 2, needsReview: true)
        XCTAssertTrue(confirm.canRun)
        XCTAssertEqual(confirm.text, """
        这一层有 12 条 Draft 记忆条目要整理，出自 2 个窗口，大约分 3 批，每批调一次模型。
        估计花 $0.31 左右，写入预算还剩 $2.00，够。
        删掉、并进已有的、改对直接生效，已有的条目可能跟着改（记忆日志里每一笔能 Undo）。留下的和拿不准的还在 Draft。
        """)

        plan.missing = 2
        plan.resumed = true
        confirm = FragmentReorganize.confirmText(plan, cost: 0.31, budget: 0.1, needsReview: false)
        XCTAssertEqual(confirm.text, """
        接着上次没整理完的：还有 12 条 Draft 记忆条目，出自 2 个窗口，大约分 3 批，每批调一次模型。
        另有 2 张出处找不到（来源窗口删了、不参与记忆，或那条消息不在了），跳过不整理。
        估计花 $0.31 左右，写入预算只剩 $0.10，不够：整理到预算用完会停下，下次再点接着整理。
        删掉、并进已有的、改对直接生效，已有的条目可能跟着改（记忆日志里每一笔能 Undo）。留下的直接算批过，只有拿不准的留在 Draft。
        """)
        XCTAssertTrue(FragmentReorganize.confirmText(plan, cost: nil, budget: nil, needsReview: true).text.contains("这个模型没标价，估不出花多少；写入预算没开，不限。"))

        confirm = FragmentReorganize.confirmText(plan, cost: 0.31, budget: 0, needsReview: true)
        XCTAssertFalse(confirm.canRun)
        XCTAssertTrue(confirm.text.hasPrefix("写入预算已经用完，现在整理不了。"))

        confirm = FragmentReorganize.confirmText(.init(), cost: nil, budget: nil, needsReview: true)
        XCTAssertEqual(confirm.text, "这一层没有还在 Draft 的记忆条目，没有要整理的。")
        XCTAssertFalse(confirm.canRun)
        confirm = FragmentReorganize.confirmText(.init(missing: 3, orphans: 3), cost: nil, budget: nil, needsReview: true)
        XCTAssertEqual(confirm.text, "没有能整理的：Draft 里的 3 张出处找不到（来源窗口删了、不参与记忆，或那条消息不在了），没法对着原文整理。")
        XCTAssertFalse(confirm.canRun)
    }

    func testSummarySaysWhatHappenedAndWhatToDoNext() {
        var report = FragmentReorganize.Report(batches: 3, counts: [.kept: 4, .dropped: 2, .merged: 1, .rewritten: 1, .unsure: 1], missing: 2)
        XCTAssertEqual(FragmentReorganize.summary(report), "整理完了，3 批：Keep 4 · Drop 2 · Merge 1 · Rewrite 1 · Unsure 1；跳过 2 张（出处找不到）")
        report.failed = 1
        XCTAssertEqual(FragmentReorganize.summary(report),
                       "整理完了，3 批：Keep 4 · Drop 2 · Merge 1 · Rewrite 1 · Unsure 1；跳过 2 张（出处找不到）；1 批模型没交出合格的结论，条目还在 Draft，再点只补这几批")
        report = .init(batches: 1, counts: [.approved: 2], stop: .stopped)
        XCTAssertEqual(FragmentReorganize.summary(report, needsReview: false), "停下了（整理了 1 批：Keep 2 · 留下的直接算批过）。再点接着整理剩下的")
        report.stop = .skipped
        XCTAssertEqual(FragmentReorganize.summary(report, budgetOut: true, needsReview: false),
                       "写入预算用完，停下了（整理了 1 批：Keep 2 · 留下的直接算批过）。调高预算后再点接着整理剩下的")
        XCTAssertTrue(FragmentReorganize.summary(report).hasPrefix("有一批没做成（预算闸拦下或模型没回），停下了"))
        XCTAssertEqual(FragmentReorganize.summary(.init(stop: .failed("断网或被打断"))),
                       "有一批出错了（断网或被打断），停下了（一批都没整理）。细节在记忆日志，再点接着整理剩下的")
        XCTAssertEqual(FragmentReorganize.summary(.init(stop: .background)), "app 进了后台，停下了（一批都没整理）。再点接着整理剩下的")
        XCTAssertTrue(FragmentReorganize.summary(.init(stop: .unavailable)).hasPrefix("现在整理不了，停下了"))
        XCTAssertEqual(FragmentReorganize.summary(.init(missing: 3)), "没有整理到条目；跳过 3 张（出处找不到）")
        XCTAssertEqual(FragmentReorganize.summary(.init(failed: 2)), "一批都没整理成；2 批模型没交出合格的结论，条目还在 Draft")
    }

    // MARK: - 跑：一批接一批走现有的「C2 整理」

    @MainActor
    func testOrganizesEveryDraftBatchByBatchThroughTheSameDream() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try window("船", title: "模型船", count: 75, in: context)
        try window("灯", title: "皮影灯", count: 12, chars: 40, cc: true, in: context)
        let early = card("桅杆用的是椴木。", window: "船", node: "船-5", age: 900, in: context)
        let mid = card("船帆打算染成靛蓝色。", window: "船", node: "船-40", age: 800, in: context)
        let late = card("今天说龙骨粘歪了。", window: "船", node: "船-70", age: 700, in: context)
        let lamp = card("槐序巷皮影作坊每周四开门。", window: "灯", node: "灯-3", age: 600, in: context)
        // 不当新卡的：她批过的、改过的、钉住的、改版前的老档案；出处找不到的三种
        let approved = card("养的鹦鹉叫栗羽。", window: "船", node: "船-6", age: 500, in: context)
        approved.reviewedAt = Date()
        let edited = card("船模放在北窗的架子上。", window: "船", node: "船-7", age: 400, in: context)
        edited.userEditedAt = Date()
        let pinned = card("做船模只用鱼胶。", window: "船", node: "船-8", age: 300, in: context)
        pinned.isUserExplicit = true
        card("喜欢吃酸的。", window: "船", node: "船-9", age: 200, fragment: false, in: context)
        let gone = card("旧窗口里记的事。", window: "删了的窗口", node: "x-1", age: 100, in: context)
        let offPath = card("出处那条不在主线上。", window: "船", node: "船-999", age: 90, in: context)
        let unknown = card("没记来源的卡。", window: nil, node: nil, age: 80, in: context)
        try context.save()

        let root = tempRoot()
        // 「写完自动整理一遍」关着也能手动跑；「要我批」关着 = 留下的直接算批过
        let defaults = tempDefaults(dream: false, review: false)
        let prompt = prepare(container, defaults: defaults, root: root, budget: 5)
        XCTAssertTrue(prompt.canRun)
        XCTAssertEqual([prompt.plan.cards, prompt.plan.windows.count, prompt.plan.batches, prompt.plan.missing], [4, 2, 4, 3])
        XCTAssertFalse(prompt.plan.resumed)
        XCTAssertTrue(prompt.text.hasPrefix("这一层有 4 条 Draft 记忆条目要整理，出自 2 个窗口，大约分 4 批，每批调一次模型。\n另有 3 张出处找不到"))

        let calls = Calls()
        let progress = Progress()
        let report = await FragmentReorganize.begin(prompt.plan, profileId: pid, every: 30, job: job(container, caller: { system, user in
            switch await calls.next(system, user) {
            case 1: return self.verdicts(user)
            case 2: return self.verdicts(user, #""verdict":"drop","reason":"not_fact""#)
            case 3: return self.verdicts(user, #""verdict":"rewrite","text":"龙骨粘歪过一次。""#)
            default: return self.verdicts(user, #""verdict":"unsure""#)
            }
        }, resident: [.init(title: "用户描述", text: "岚舟住在云桥城。")]), defaults: defaults, memoryRoot: root, progress: { batch, of in
            await progress.add(batch, of)
        })

        XCTAssertEqual(report, .init(batches: 4, counts: [.approved: 1, .dropped: 1, .rewrittenApproved: 1, .unsure: 1], missing: 3))
        let steps = await progress.steps
        XCTAssertEqual(steps, ["1/4", "2/4", "3/4", "4/4"])
        // 每批的原文是那张卡的出处所在的那一截；API 窗口带「聊天时本来就带着的内容」，CC 窗口不带
        let users = await calls.users, systems = await calls.systems
        XCTAssertEqual(users.count, 4)
        XCTAssertTrue(users[0].contains("这段对话所在的窗口叫「模型船」") && users[0].contains("## 原文（#1–#30）")
                      && users[0].contains("[N1] 桅杆用的是椴木。（关于：岚舟；标的是 岚舟 亲口说的；出自 #6）"))
        XCTAssertTrue(users[1].contains("模型船第30句") && users[1].contains("出自 #11）") && !users[1].contains("模型船第29句长"))
        XCTAssertTrue(users[2].contains("## 原文（#1–#15）") && users[2].contains("[N1] 今天说龙骨粘歪了。"))
        XCTAssertTrue(users[3].contains("这段对话所在的窗口叫「皮影灯」") && users[3].contains("## 原文（#1–#12）") && users[3].contains("出自 #4）"))
        XCTAssertTrue(systems[0].hasSuffix("### 用户描述\n岚舟住在云桥城。"))
        XCTAssertTrue(systems[3].hasSuffix("（没有）"), "CC 窗口：这一块传空")
        // 她批过 / 改过 / 钉住的是「已有的卡」，不是新卡；老档案不喂
        XCTAssertTrue(users[0].contains("## 新卡（N1–N1，每张给一个结论）"))
        XCTAssertFalse(users.contains { $0.contains("喜欢吃酸的") })

        // 落库：同自动那条路
        let main = container.mainContext
        func stored(_ m: Memory) throws -> Memory {
            let id = m.id
            return try XCTUnwrap(try main.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.id == id })).first)
        }
        XCTAssertNotNil(try stored(early).reviewedAt, "「要我批」关着：留下的直接算批过")
        XCTAssertNotNil(try stored(mid).supersededAt)
        XCTAssertEqual(try stored(late).content, "龙骨粘歪过一次。")
        XCTAssertNil(try stored(lamp).reviewedAt, "拿不准的留在 Draft")
        for untouched in [gone, offPath, unknown] {
            XCTAssertNil(try stored(untouched).supersededAt)
            XCTAssertNil(try stored(untouched).reviewedAt, "出处找不到的原样留着")
        }
        for mine in [approved, edited, pinned] { XCTAssertNil(try stored(mine).supersededAt) }

        // 记忆日志每批一行、点得开全文；审计日志每一笔能 Undo
        MemoryWriteLog.flush()
        let lines = MemoryWriteLog.entries(memoryRoot: root)
        XCTAssertEqual(Set(lines.map(\.note)), ["Keep 1 · 留下的直接算批过 · 手动整理 · 第 1 / 4 批", "Drop 1 · 手动整理 · 第 2 / 4 批",
                                                "Rewrite 1 · 留下的直接算批过 · 手动整理 · 第 3 / 4 批", "Unsure 1 · 手动整理 · 第 4 / 4 批"])
        let record = try XCTUnwrap(lines.first { $0.note.hasPrefix("Drop") }?.dream.flatMap { FragmentDreamRecord.load(id: $0, memoryRoot: root) })
        XCTAssertEqual(record.calls.first?.user, users[1])
        XCTAssertEqual(record.windowTitle, "模型船")
        let audit = MemoryAuditLog.load(memoryRoot: root)
        XCTAssertEqual(Set(audit.map(\.actor)), [FragmentDream.actor])
        XCTAssertEqual(audit.compactMap(\.label).sorted(), ["Drop", "Keep", "Rewrite"])
        let drop = try XCTUnwrap(audit.first { $0.label == "Drop" })
        XCTAssertEqual(MemoryAuditLog.undo(drop, profileId: pid, context: main).restored, 1)
        XCTAssertNil(try stored(mid).supersededAt)

        XCTAssertNil(FragmentReorganize.unfinishedSince(profileId: pid, defaults: defaults), "走到头了：记号清掉")
        XCTAssertEqual(FragmentReorganize.summary(report, needsReview: false),
                       "整理完了，4 批：Keep 1 · Drop 1 · Rewrite 1 · Unsure 1 · 留下的直接算批过；跳过 3 张（出处找不到）")
    }

    private actor Progress {
        var steps: [String] = []
        func add(_ batch: Int, _ of: Int) { steps.append("\(batch)/\(of)") }
    }

    // MARK: - 停在批次边界、再点接着跑

    @MainActor
    func testStopsBeforeTheBlockedBatchAndResumesWithWhatIsLeft() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try window("船", title: "模型船", count: 75, in: context)
        let first = card("桅杆用的是椴木。", window: "船", node: "船-5", age: 900, in: context)
        let second = card("船帆打算染成靛蓝色。", window: "船", node: "船-40", age: 800, in: context)
        let third = card("龙骨粘歪过一次。", window: "船", node: "船-70", age: 700, in: context)
        try context.save()
        let root = tempRoot(), defaults = tempDefaults()
        let main = container.mainContext
        func isDraft(_ m: Memory) throws -> Bool {
            let id = m.id
            let now = try XCTUnwrap(try main.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.id == id })).first)
            return FragmentReorganize.isDraft(now)
        }

        // 第二批被预算闸拦下（caller 回 nil）：停在它前面
        var plan = prepare(container, defaults: defaults, root: root).plan
        XCTAssertEqual([plan.cards, plan.batches], [3, 3])
        var calls = Calls()
        var report = await FragmentReorganize.begin(plan, profileId: pid, every: 30, job: job(container) { [calls] system, user in
            await calls.next(system, user) == 1 ? self.verdicts(user) : nil
        }, defaults: defaults, memoryRoot: root)
        XCTAssertEqual(report, .init(batches: 1, counts: [.kept: 1], stop: .skipped))
        XCTAssertNotNil(FragmentReorganize.unfinishedSince(profileId: pid, defaults: defaults))
        for m in [first, second, third] { XCTAssertTrue(try isDraft(m), "「要我批」开着：留下的也还在 Draft；没轮到的原样") }

        // 再点：只剩没下过结论的两张；这次她在第一批跑完后点了 Stop
        plan = prepare(container, defaults: defaults, root: root).plan
        XCTAssertTrue(plan.resumed)
        XCTAssertEqual([plan.cards, plan.batches], [2, 2])
        XCTAssertEqual(plan.windows.first?.cards.map(\.id), [second.id, third.id])
        calls = Calls()
        let flag = FragmentReorganize.StopFlag()
        report = await FragmentReorganize.begin(plan, profileId: pid, every: 30, job: job(container) { [calls] system, user in
            _ = await calls.next(system, user)
            flag.set()
            return self.verdicts(user)
        }, defaults: defaults, memoryRoot: root, shouldStop: { flag.isSet })
        XCTAssertEqual(report, .init(batches: 1, counts: [.kept: 1], stop: .stopped))
        var users = await calls.users
        XCTAssertTrue(users.count == 1 && users[0].contains("[N1] 船帆打算染成靛蓝色。"), "Stop 之后这一批跑完就停，不开下一批")

        // 进了后台：一批都不开
        plan = prepare(container, defaults: defaults, root: root).plan
        XCTAssertEqual(plan.windows.first?.cards.map(\.id), [third.id])
        report = await FragmentReorganize.begin(plan, profileId: pid, every: 30, job: job(container) { _, user in self.verdicts(user) },
                                                defaults: defaults, memoryRoot: root, inBackground: { true })
        XCTAssertEqual(report, .init(stop: .background))
        // 请求出错：停下并带上原因
        report = await FragmentReorganize.begin(plan, profileId: pid, every: 30, job: job(container) { _, _ in throw URLError(.notConnectedToInternet) },
                                                defaults: defaults, memoryRoot: root)
        XCTAssertEqual(report, .init(stop: .failed("断网或被打断")))
        // 这一轮成了本机模型：不做
        report = await FragmentReorganize.begin(plan, profileId: pid, every: 30, job: job(container, caller: { _, user in self.verdicts(user) }, local: true),
                                                defaults: defaults, memoryRoot: root)
        XCTAssertEqual(report, .init(stop: .unavailable))
        XCTAssertTrue(try isDraft(third))

        // 最后跑完：记号清掉，再点是新的一趟（三张都还在 Draft，全部重来）
        calls = Calls()
        report = await FragmentReorganize.begin(plan, profileId: pid, every: 30, job: job(container) { [calls] system, user in
            _ = await calls.next(system, user)
            return self.verdicts(user)
        }, defaults: defaults, memoryRoot: root)
        XCTAssertEqual(report, .init(batches: 1, counts: [.kept: 1]))
        users = await calls.users
        XCTAssertTrue(users[0].contains("[N1] 龙骨粘歪过一次。") && !users[0].contains("[N2]"), "前面下过结论的不再当新卡送")
        XCTAssertNil(FragmentReorganize.unfinishedSince(profileId: pid, defaults: defaults))
        plan = prepare(container, defaults: defaults, root: root).plan
        XCTAssertFalse(plan.resumed)
        XCTAssertEqual(plan.cards, 3)
    }

    @MainActor
    func testBatchTheModelGarblesIsSkippedAndTappingAgainRedoesOnlyThatOne() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try window("船", title: "模型船", count: 75, in: context)
        card("桅杆用的是椴木。", window: "船", node: "船-5", age: 900, in: context)
        let garbled = card("船帆打算染成靛蓝色。", window: "船", node: "船-40", age: 800, in: context)
        card("龙骨粘歪过一次。", window: "船", node: "船-70", age: 700, in: context)
        try context.save()
        let root = tempRoot(), defaults = tempDefaults()

        var plan = prepare(container, defaults: defaults, root: root).plan
        var report = await FragmentReorganize.begin(plan, profileId: pid, every: 30, job: job(container) { _, user in
            user.contains("[N1] 船帆打算染成靛蓝色。") ? "我想想" : self.verdicts(user)
        }, defaults: defaults, memoryRoot: root)
        XCTAssertEqual(report, .init(batches: 2, failed: 1, counts: [.kept: 2]), "格式两次都不对的那批跳过去，后面的照跑")
        XCTAssertNotNil(FragmentReorganize.unfinishedSince(profileId: pid, defaults: defaults), "有批没整理成：记号留着")

        plan = prepare(container, defaults: defaults, root: root).plan
        XCTAssertTrue(plan.resumed)
        XCTAssertEqual(plan.windows.first?.cards.map(\.id), [garbled.id], "再点只补那一批")
        // 补的那一趟还是一批都没成：记号清掉，下次从头来（不会一直只补这一批）
        report = await FragmentReorganize.begin(plan, profileId: pid, every: 30, job: job(container) { _, _ in "还是不会" },
                                                defaults: defaults, memoryRoot: root)
        XCTAssertEqual(report, .init(failed: 1))
        XCTAssertNil(FragmentReorganize.unfinishedSince(profileId: pid, defaults: defaults))
        XCTAssertEqual(prepare(container, defaults: defaults, root: root).plan.cards, 3)
    }

    func testNoDraftsMeansNothingToConfirm() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try window("船", title: "模型船", count: 12, chars: 40, in: context)
        card("做船模只用鱼胶。", window: "船", node: "船-2", age: 100, in: context).reviewedAt = Date()
        try context.save()
        let prompt = prepare(container, defaults: tempDefaults(), root: tempRoot())
        XCTAssertFalse(prompt.canRun)
        XCTAssertEqual(prompt.text, "这一层没有还在 Draft 的记忆条目，没有要整理的。")
    }
}
