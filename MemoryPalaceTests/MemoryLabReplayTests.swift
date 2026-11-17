import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 记忆实验台第三片的执行器部分（plan-memory-lab-3 §2 / §5）：重放（顺序 / 只补没跑的 / 整份重跑 / 取消 / 某句失败接着跑）、
/// 比较函数、参数存一组再载入。一层编的空楼，模型是假的。
@MainActor
final class MemoryLabReplayTests: XCTestCase {
    private var pid = ""
    private var container: ModelContainer!
    private var memoryRoot: URL!
    private var store: MemoryLabStore!

    override func setUp() async throws {
        try XCTSkipUnless(TestHostIsolation.active, "只在隔离的测试宿主里跑（要往家目录里建一层编的楼）")
        pid = "xctest-memory-lab-replay-\(UUID().uuidString)"
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self, WorldBook.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        memoryRoot = FileLibraryStore.memoryRoot(profileId: pid)
        store = MemoryLabStore(memoryRoot: memoryRoot)
    }

    override func tearDown() async throws {
        container = nil
        if let memoryRoot { try? FileManager.default.removeItem(at: memoryRoot.deletingLastPathComponent()) }
    }

    /// 假模型：记下问了几次；`reply` 按第几次问决定回什么
    private final class Model {
        var asked = 0
        var reply: (Int) -> MemoryLabModelLoop.Reply = { .init(kind: .text("第 \($0) 次的回复")) }
        var onAsk: (Int) -> Void = { _ in }

        var send: MemoryLabModelLoop.Send {
            { _, _ in
                self.asked += 1
                self.onAsk(self.asked)
                return self.reply(self.asked)
            }
        }
    }

    private func runner(_ model: Model) -> MemoryLabRunner {
        MemoryLabRunner(profile: Profile(id: pid, name: "星砚楼", emoji: "", description: "", userName: "岚舟", assistantName: "星砚"),
                        preset: .balanced, providers: ProviderManager(), container: container, send: model.send)
    }

    private var params: MemoryLabParams {
        MemoryLabParams(timeline: false, pending: false, selfMemory: false, rootIndex: false, previousWindow: false, pinned: true,
                        everyRound: false, tuning: RecallTestTuning.make(archiveTriggerEnabled: false), recallTool: false,
                        modelId: "none/none")
    }

    private let sentences = [("s-parrot", "雾岚还学门铃吗"), ("s-cold", "栎川镇降温了吗"), ("s-teacher", "林栖今天来过吗")]

    /// 一份三句的集子（顺序就是上面那样）；「另一份」里只有第一句
    private func seedSets() throws {
        try store.save(MemoryLabSet(id: "life", name: "生活琐事", createdAt: Date(),
                                    items: sentences.map { .init(sentenceId: $0.0, text: $0.1, addedAt: Date()) }))
        try store.save(MemoryLabSet(id: "close", name: "亲密对话", createdAt: Date().addingTimeInterval(1),
                                    items: [.init(sentenceId: "s-parrot", text: "雾岚还学门铃吗", addedAt: Date())]))
    }

    // MARK: - 重放

    func testReplayRunsMissingSentencesInSetOrderAndTagsTheRecords() async throws {
        try seedSets()
        let model = Model()
        let lab = runner(model)
        var seen: [MemoryLabReplayProgress] = []
        let produced = try await lab.replay(setId: "life", paramsId: "wide", params: params) { seen.append($0) }

        XCTAssertEqual(produced.map(\.input.text), sentences.map(\.1), "按集子里的顺序")
        XCTAssertEqual(produced.map(\.sentenceId), sentences.map(\.0))
        XCTAssertEqual(produced.map(\.paramsId), ["wide", "wide", "wide"])
        XCTAssertEqual(produced.map(\.sets), [["life", "close"], ["life"], ["life"]], "这句话在哪几份测试集里，照集子文件")
        XCTAssertEqual(produced.map { $0.happened?.reply }, ["第 1 次的回复", "第 2 次的回复", "第 3 次的回复"], "一句一句来，不并发")
        XCTAssertEqual(seen.map(\.done), [1, 2, 3])
        XCTAssertEqual(seen.map(\.total), [3, 3, 3])
        XCTAssertEqual(seen.map(\.sentenceId), sentences.map(\.0))
        XCTAssertEqual(seen.map(\.record), produced)
        let onDisk = await lab.records()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: onDisk.map { ($0.id, $0) }),
                       Dictionary(uniqueKeysWithValues: produced.map { ($0.id, $0) }), "回报进度时那条已经落盘")
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "wide"), .init(count: 3, ran: 3, notRun: 0, unseen: 3))
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: MemoryLabParamSet.currentId).notRun, 3, "别的组照样算没跑过")

        // 再点重放：一句不跑、不问模型
        let again = try await lab.replay(setId: "life", paramsId: "wide", params: params) { seen.append($0) }
        XCTAssertEqual(again, [])
        XCTAssertEqual(model.asked, 3)
        XCTAssertEqual(seen.count, 3)

        // 集子里后来多了一句：只补它
        var set = try XCTUnwrap(store.set(id: "life"))
        set.items?.append(.init(sentenceId: "s-class", text: "槐序巷的课改到周五了吗", addedAt: Date()))
        try store.save(set)
        let added = try await lab.replay(setId: "life", paramsId: "wide", params: params) { seen.append($0) }
        XCTAssertEqual(added.map(\.sentenceId), ["s-class"])
        XCTAssertEqual([seen.last?.done, seen.last?.total], [1, 1])
        XCTAssertEqual(model.asked, 4)

        // 整份重跑：四句都出新记录，旧的留着；牌堆取新的
        let rerun = try await lab.replay(setId: "life", paramsId: "wide", params: params, rerunAll: true)
        XCTAssertEqual(rerun.map(\.sentenceId), ["s-parrot", "s-cold", "s-teacher", "s-class"])
        XCTAssertTrue(Set(rerun.map(\.id)).isDisjoint(with: (produced + added).map(\.id)), "都是新记录")
        let all = await lab.records()
        XCTAssertEqual(all.count, 8, "旧的不删")
        XCTAssertEqual(store.entries(inSet: "life", paramsId: "wide").map(\.record?.id), rerun.map(\.id))

        // 没有这份集子：什么都不做
        let nothing = try await lab.replay(setId: "gone", paramsId: "wide", params: params)
        XCTAssertEqual(nothing, [])
        XCTAssertEqual(model.asked, 8)
    }

    /// 第二句正在问模型时点了停：这一句照样跑完、有回复、落了盘；第三句不再开始。再重放只补第三句
    func testCancelLetsTheCurrentSentenceFinishThenStops() async throws {
        try seedSets()
        let model = Model()
        let lab = runner(model)
        var task: Task<[MemoryLabRecord], Error>?
        model.onAsk = { asked in if asked == 2 { task?.cancel() } }
        final class Seen { var done: [Int] = [] }
        let seen = Seen()
        let params = params
        task = Task { try await lab.replay(setId: "life", paramsId: "wide", params: params) { seen.done.append($0.done) } }
        let produced = try await XCTUnwrap(task).value

        XCTAssertEqual(produced.map(\.sentenceId), ["s-parrot", "s-cold"])
        XCTAssertEqual(produced.last?.happened?.reply, "第 2 次的回复", "当前这句没被打断")
        XCTAssertNil(produced.last?.happened?.error)
        XCTAssertEqual(seen.done, [1, 2])
        XCTAssertEqual(model.asked, 2)
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "wide"), .init(count: 3, ran: 2, notRun: 1, unseen: 2), "已经落盘的留着")

        let rest = try await lab.replay(setId: "life", paramsId: "wide", params: params)
        XCTAssertEqual(rest.map(\.sentenceId), ["s-teacher"])
    }

    /// 还没开始就已经取消了：一句不跑
    func testCancelledBeforeStartRunsNothing() async throws {
        try seedSets()
        let model = Model()
        let lab = runner(model)
        let params = params
        let task = Task { () -> [MemoryLabRecord] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await lab.replay(setId: "life", paramsId: "wide", params: params)
        }
        let produced = try await task.value
        XCTAssertEqual(produced, [])
        XCTAssertEqual(model.asked, 0)
    }

    func testFailedSentenceIsRecordedAndReplayKeepsGoing() async throws {
        try seedSets()
        let model = Model()
        model.reply = { $0 == 2 ? .init(kind: .failed("401 没有钥匙")) : .init(kind: .text("第 \($0) 次的回复")) }
        let lab = runner(model)
        var seen: [Int] = []
        let produced = try await lab.replay(setId: "life", paramsId: MemoryLabParamSet.currentId, params: params) { seen.append($0.done) }
        XCTAssertEqual(produced.map(\.sentenceId), sentences.map(\.0), "失败的那句之后接着跑")
        XCTAssertEqual(produced.map { $0.happened?.error }, [nil, "401 没有钥匙", nil])
        XCTAssertEqual(produced.map { $0.happened?.reply }, ["第 1 次的回复", nil, "第 3 次的回复"])
        XCTAssertEqual(produced.map(\.paramsId), Array(repeating: MemoryLabParamSet.currentId, count: 3))
        XCTAssertEqual(seen, [1, 2, 3])
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: MemoryLabParamSet.currentId),
                       .init(count: 3, ran: 2, notRun: 1, failed: 1, unseen: 2), "没问成的那句不算跑过")
        XCTAssertEqual(store.entries(inSet: "life", paramsId: MemoryLabParamSet.currentId).map { $0.record?.happened?.error },
                       [nil, "401 没有钥匙", nil], "牌堆里照样看得到它和出错原因")

        // 再点重放：只补没问成的那一句（这回问成了），别的不再问
        let again = try await lab.replay(setId: "life", paramsId: MemoryLabParamSet.currentId, params: params) { seen.append($0.done) }
        XCTAssertEqual(again.map(\.sentenceId), ["s-cold"])
        XCTAssertEqual(again.first?.happened?.reply, "第 4 次的回复")
        XCTAssertEqual(seen, [1, 2, 3, 1])
        XCTAssertEqual(model.asked, 4)
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: MemoryLabParamSet.currentId), .init(count: 3, ran: 3, unseen: 3))
        let all = await lab.records()
        XCTAssertEqual(all.count, 4, "没问成的那条旧记录还在")
        let third = try await lab.replay(setId: "life", paramsId: MemoryLabParamSet.currentId, params: params)
        XCTAssertEqual(third, [])
        XCTAssertEqual(model.asked, 4)
    }

    /// 一直问不成（没钥匙）：每次重放都会再试这几句，不会卡成「都跑过了」
    func testSentencesThatNeverGetAReplyAreRetriedOnEveryReplay() async throws {
        try seedSets()
        let model = Model()
        model.reply = { _ in .init(kind: .failed("401 没有钥匙")) }
        let lab = runner(model)
        let first = try await lab.replay(setId: "life", paramsId: "wide", params: params)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "wide"), .init(count: 3, notRun: 3, failed: 3))
        let second = try await lab.replay(setId: "life", paramsId: "wide", params: params)
        XCTAssertEqual(second.map(\.sentenceId), sentences.map(\.0))
        XCTAssertEqual(model.asked, 6)
    }

    // MARK: - 存一组 / 载入一组

    func testParamsSurviveBeingSavedAsAGroup() throws {
        let lab = runner(Model())
        var chosen = params
        chosen.timeline = true
        chosen.systemPush = true
        chosen.tuning.maximumPages = 7
        chosen.tuning.fullTextCoverageThreshold = 0.75
        chosen.recallTool = true
        chosen.modelId = "card/haiku"
        XCTAssertEqual(MemoryLabParams(recorded: lab.recorded(chosen)), chosen, "存进记录再还原，一样")
        XCTAssertEqual(lab.recorded(chosen).differences, chosen.differences(from: lab.currentParams()))

        let group = try store.createParamSet(name: "多推几页", params: lab.recorded(chosen))
        XCTAssertNil(group.params?.differences)
        XCTAssertEqual(MemoryLabParams(recorded: store.paramSet(id: group.id)?.params), chosen, "存成一组再载入，一样")
        XCTAssertNil(MemoryLabParams(recorded: nil))
        XCTAssertNil(MemoryLabParams(recorded: .init(systemPush: true)), "没存那一页的数的旧记录还原不出来")
    }

    // MARK: - 比较

    private func item(_ kind: RecallSourceRef.Kind, _ path: String, version: String = "v1") -> RecallItem {
        RecallItem(source: .init(profileId: pid, conversationId: MemoryLabRunner.conversationId, kind: kind, path: path, version: version),
                   text: "\(path) 的正文 \(version)", identities: [path], tokenCost: 10)
    }

    private func record(_ id: String, pushed: [RecallItem], reads: [String] = [], reply: String?, error: String? = nil) -> MemoryLabRecord {
        var receipt = RecallTurnReceipt(decision: RecallTurnDecision(
            turnId: id, branchAnchor: MemoryLabRunner.conversationId, origin: .user, gateReason: .search, tuning: .defaults,
            topicAnchor: "", selected: pushed, candidates: pushed, suppressions: [], ignored: [], thawed: [],
            stateAfterResponse: RecallConversationState()))
        receipt.reads = reads.map { RecallReadReceipt(toolCallId: "call-\($0)", turnId: id, layer: "wiki页", target: $0) }
        return MemoryLabRecord(id: id, input: .init(text: "林栖的皮影小店开了吗", at: Date()),
                               happened: .init(receipt: receipt, reply: reply, error: error), sentenceId: "s1")
    }

    func testComparisonSplitsWhatWasPushed() {
        let here = record("wide-1", pushed: [item(.page, "人/林栖", version: "v2"), item(.fragment, "雾岚的条目"), item(.page, "地点/云桥城")],
                          reads: ["人/林栖"], reply: "开了，在槐序巷。")
        let there = record("current-1", pushed: [item(.page, "人/林栖", version: "v1"), item(.card, "雾岚的条目")], reply: "不记得了。")
        let compared = MemoryLabComparison.make(here: here, there: there)
        XCTAssertEqual(compared.both.map(\.source.path), ["人/林栖"], "同一页改过版本也算同一样")
        XCTAssertEqual(compared.both.first?.source.version, "v2", "给的是这边那一份")
        XCTAssertEqual(compared.here?.only.map(\.source.path), ["雾岚的条目", "地点/云桥城"], "顺序照这边推送的顺序")
        XCTAssertEqual(compared.there?.only.map(\.source.kind), [.card], "同名但不是同一种东西，不算同一样")
        XCTAssertEqual(compared.here?.reads.map(\.target), ["人/林栖"])
        XCTAssertEqual(compared.there?.reads, [])
        XCTAssertEqual(compared.here?.reply, "开了，在槐序巷。")
        XCTAssertEqual(compared.there?.reply, "不记得了。")
        XCTAssertEqual([compared.here?.recordId, compared.there?.recordId], ["wide-1", "current-1"])

        // 反过来比是镜像
        let mirrored = MemoryLabComparison.make(here: there, there: here)
        XCTAssertEqual(mirrored.here?.only, compared.there?.only)
        XCTAssertEqual(mirrored.there?.only, compared.here?.only)
        XCTAssertEqual(mirrored.both.first?.source.version, "v1")
    }

    func testComparisonSaysNotRunInsteadOfEmpty() {
        let here = record("wide-1", pushed: [item(.page, "人/林栖")], reply: nil, error: "401 没有钥匙")
        let alone = MemoryLabComparison.make(here: here, there: nil)
        XCTAssertNil(alone.there, "那边这句还没跑过")
        XCTAssertEqual(alone.here?.only.map(\.source.path), ["人/林栖"])
        XCTAssertEqual(alone.both, [])
        XCTAssertNil(alone.here?.reply)
        XCTAssertEqual(alone.here?.error, "401 没有钥匙", "没回话的那边给出错原因")

        // 跑过但什么都没推送、也没翻：那一边在，只是空的——和「没跑过」分得开
        let quiet = MemoryLabComparison.make(here: here, there: record("current-1", pushed: [], reply: "不记得了。"))
        XCTAssertEqual(quiet.there?.only, [])
        XCTAssertEqual(quiet.there?.reply, "不记得了。")
        XCTAssertNotNil(quiet.there)

        let neither = MemoryLabComparison.make(here: nil, there: nil)
        XCTAssertNil(neither.here)
        XCTAssertNil(neither.there)
        XCTAssertEqual(neither.both, [])
    }
}
