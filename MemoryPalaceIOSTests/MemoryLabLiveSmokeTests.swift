import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

// 记忆实验台真问模型的冒烟（plan-memory-lab §5.3）：走 app 里那条真路 `MemoryLabRunner.run`——
// 在一层编的楼上选记忆、拼提示词、真问模型、助手调 recall、回灌、回话、记录落盘。全是编的数据。
// TEST_RUNNER_MP_C3_LIVE_* 由 xcodebuild 转成宿主 MP_C3_LIVE_*（钥匙 / 模型 / 可选地址）；真实 key 只在出站时注入。
@MainActor
final class MemoryLabLiveSmokeTests: XCTestCase {
    private var providers: ProviderManager?
    private var credentialId: String?
    private var modelId = ""
    private var pid = ""
    private var container: ModelContainer!
    private var memoryRoot: URL?

    /// 小店的门牌只写在页的「记录」里：系统推送只带页的钩子和「现在」，要答上来得主动翻
    private let question = "用 recall 翻一下林栖那一页的记录：她的皮影小店在哪条巷子、几号？"

    override func setUp() async throws {
        guard let value = getenv("MP_C3_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_C3_LIVE_API_KEY，不访问真实端点")
        }
        guard let model = getenv("MP_C3_LIVE_MODEL"), !String(cString: model).isEmpty else {
            throw XCTSkip("必须注入 TEST_RUNNER_MP_C3_LIVE_MODEL，模型不写死")
        }
        modelId = String(cString: model)
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "MemoryLabLiveSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 300
        CatalogLiveAuthProtocol.key = String(cString: value)
        try CatalogLiveAuthProtocol.install()
        pid = "live-memory-lab-\(UUID().uuidString)"
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self, WorldBook.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        memoryRoot = FileLibraryStore.memoryRoot(profileId: pid)
        try seed()
    }

    override func tearDown() async throws {
        if let credentialId { providers?.removeCredential(id: credentialId) }
        providers = nil
        credentialId = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
        container = nil
        if let memoryRoot { try? FileManager.default.removeItem(at: memoryRoot.deletingLastPathComponent()) }
        memoryRoot = nil
    }

    private func makeProvider() -> (ProviderManager, ProviderModel) {
        let id = "xctest-memory-lab-live-\(UUID().uuidString)"
        credentialId = id
        let baseURL = getenv("MP_C3_LIVE_BASE_URL").map { String(cString: $0) } ?? "https://api.anthropic.com/v1"
        let model = ProviderModel(credentialId: id, modelId: modelId, name: modelId)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        providers = manager
        manager.addCredential(APICredential(id: id, name: "星砚楼 记忆实验台 live", emoji: "", type: .anthropic,
            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"], models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        return (manager, model)
    }

    private func seed() throws {
        let root = try XCTUnwrap(memoryRoot)
        let context = ModelContext(container)
        func memory(_ text: String, subject: String, pinned: Bool = false) {
            let m = Memory(content: text, category: "fact", profileId: pid, isUserExplicit: pinned, extractedBy: "fictional")
            m.subject = subject
            if !pinned { m.occurredDay = "2026-11-03" }
            m.reviewedAt = Date()
            context.insert(m)
        }
        memory("岚舟不吃香菜。", subject: "岚舟", pinned: true)
        memory("每周五晚上去槐序巷皮影作坊上课。", subject: "岚舟")
        memory("岚舟养的灰鹦鹉，会学门铃响。", subject: "雾岚")
        try context.save()
        try WikiStore(root: root.appendingPathComponent("wiki", isDirectory: true))
            .save(WikiPage(path: "人/林栖", kind: .person, hook: "岚舟的皮影老师", title: "林栖", now: "林栖在云桥城开了一家皮影小店。",
                           records: ["林栖的皮影小店在槐序巷十七号。", "林栖每周五晚上教岚舟刻皮影。"]))
    }

    private func params(model: ProviderModel, maximumRecallCalls: Int) -> MemoryLabParams {
        var tuning = RecallTuning.defaults
        tuning.archiveTriggerEnabled = true
        tuning.maximumRecallCalls = maximumRecallCalls
        return MemoryLabParams(timeline: false, pending: false, selfMemory: false, rootIndex: true, previousWindow: false,
                               pinned: true, everyRound: false, tuning: tuning, recallTool: true, modelId: model.id)
    }

    private struct Row: Equatable {
        let id: UUID
        let accessCount: Int
        let lastAccessedAt: Date
        let decayWeight: Double
    }

    private func rows() throws -> [Row] {
        try ModelContext(container).fetch(FetchDescriptor<Memory>())
            .map { Row(id: $0.id, accessCount: $0.accessCount, lastAccessedAt: $0.lastAccessedAt, decayWeight: $0.decayWeight) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func log(_ record: MemoryLabRecord) {
        let happened = record.happened
        print("[LAB-LIVE] model=\(modelId) 问了 \(happened?.usage?.requests ?? 0) 次 · 工具回合 \(happened?.rounds?.count ?? 0) · 读回执 \(happened?.receipt?.reads.count ?? 0)")
        for call in happened?.rounds?.flatMap(\.calls) ?? [] {
            print("[LAB-LIVE] \(call.name) \(call.arguments.prefix(160)) → \(call.isError == true ? "出错" : "成") \((call.result ?? "").prefix(120))")
        }
        print("[LAB-LIVE] 推送了：\(happened?.receipt?.decision.selected.map(\.source.path) ?? [])")
        print("[LAB-LIVE] 回复：\(CatalogLiveAuthProtocol.redacted(happened?.reply ?? "（没有）")) · 出错：\(CatalogLiveAuthProtocol.redacted(happened?.error ?? "无"))")
    }

    /// 说一句 → 系统推送带上聊到的页 → 助手主动翻至少一次（调用被执行、回包回灌）→ 拿到回复 → 记录落盘；记忆条目没被加访问数。
    /// 只断言合同，不断言模型的走法：它翻得对不对、回包是不是出错、最后答没答出门牌都不拦（11-16 😷：同一份代码两次跑，
    /// Haiku 一次按目录翻到了、一次自己编了个 target 被工具拒了）。走法只打出来给人看。
    func testOneSentenceRecallsAnswersAndIsSavedLive() async throws {
        let (manager, model) = makeProvider()
        let lab = MemoryLabRunner(profile: Profile(id: pid, name: "星砚楼", emoji: "", description: "", userName: "岚舟", assistantName: "星砚"),
                                  preset: .balanced, providers: manager, container: container)
        let before = try rows()
        let record = try await lab.run(question, params: params(model: model, maximumRecallCalls: 3))
        log(record)
        let happened = try XCTUnwrap(record.happened)
        XCTAssertNil(happened.error)
        let reply = try XCTUnwrap(happened.reply)
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "拿到回复")
        XCTAssertEqual(happened.receipt?.decision.selected.contains { $0.source.path == "人/林栖" }, true, "系统推送带上了聊到的那一页")
        XCTAssertEqual(happened.messages?.contains { $0.content.contains("岚舟不吃香菜。") }, true, "钉住的在提示词里")
        let calls = (happened.rounds ?? []).flatMap(\.calls).filter { $0.name == RecallTool.toolName }
        let reads = happened.receipt?.reads ?? []
        XCTAssertFalse(calls.isEmpty, "主动翻开着，至少调了一次 recall")
        XCTAssertTrue(calls.allSatisfy { $0.result?.isEmpty == false }, "每次调用都被执行并有回包（回包是不是出错不管）")
        XCTAssertEqual(Set(reads.map(\.toolCallId)), Set(calls.map(\.id)), "每次 recall 都记了读回执，进了记录")
        XCTAssertEqual(happened.usage?.requests, (happened.rounds?.count ?? 0) + 1, "每个工具回合之后都把回包回灌、再问了一次")
        XCTAssertLessThanOrEqual(happened.usage?.requests ?? 0, MemoryLabModelLoop.maximumRounds + 1, "工具回合不超过总上限")
        XCTAssertEqual(happened.receipt?.attempts.map(\.status), [.responded])
        // 走法（不拦）：门牌只在页的「记录」里，翻对了才答得上
        print("[LAB-LIVE] 走法：recall \(calls.count) 次，成 \(calls.filter { $0.isError == false }.count) 次；"
              + "答出门牌：\(reply.contains("十七") || reply.contains("17") ? "是" : "否")")

        let stored = await lab.records()
        XCTAssertEqual(stored, [record], "记录落盘，读回来一字不差")
        XCTAssertEqual(try rows(), before, "翻到的记忆条目没被加访问数")
        XCTAssertNil(UserDefaults.standard.object(forKey: "mem_last_injection_\(pid)"))
    }

    /// recall 上限设 1（同真聊天的收尾）：只有第一次调用被执行；之后再调的拿到的是「本轮 recall 已到 1 次…」那句回包，工具照给；
    /// 最后要么有非空的回复，要么有明确的出错原因——不许是「空回复却没出错」（11-16 😷：到上限就把工具收走时，Haiku 回过一段空的）。
    /// 模型翻没翻成、超没超上限、最后答了什么都不断言，只打出来。
    func testBeyondTheRecallLimitCallsGetLimitedAndTheSentenceEndsCleanlyLive() async throws {
        let (manager, model) = makeProvider()
        let lab = MemoryLabRunner(profile: Profile(id: pid, name: "星砚楼", emoji: "", description: "", userName: "岚舟", assistantName: "星砚"),
                                  preset: .balanced, providers: manager, container: container)
        let record = try await lab.run(question, params: params(model: model, maximumRecallCalls: 1))
        log(record)
        let happened = try XCTUnwrap(record.happened)
        let calls = (happened.rounds ?? []).flatMap(\.calls).filter { $0.name == RecallTool.toolName }
        let reads = happened.receipt?.reads ?? []
        XCTAssertFalse(calls.isEmpty, "主动翻开着，至少调了一次 recall")
        XCTAssertEqual(reads.map(\.toolCallId), calls.map(\.id), "每次调用都记了读回执")
        XCTAssertEqual(reads.first.map { $0.status != "limited" }, true, "第一次调用被执行了（成不成不管）")
        for (call, read) in zip(calls, reads).dropFirst() {
            XCTAssertEqual(read.status, "limited", "超出上限的调用不执行")
            XCTAssertEqual(call.isError, true)
            XCTAssertEqual(call.result?.contains("本轮 recall 已到 1 次"), true, "拿到的是到上限的那句回包：\(call.result ?? "")")
        }
        if let reply = happened.reply {
            XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "回复不是空的")
            XCTAssertNil(happened.error)
            XCTAssertEqual(happened.usage?.requests, (happened.rounds?.count ?? 0) + 1)
        } else {
            XCTAssertEqual(happened.error?.isEmpty, false, "没有回复就得有明确的出错原因")
        }
        XCTAssertTrue(record.replied || happened.error?.isEmpty == false, "不许是空回复却没出错")
        XCTAssertLessThanOrEqual(happened.rounds?.count ?? 0, MemoryLabModelLoop.maximumRounds)
        let stored = await lab.records()
        XCTAssertEqual(stored, [record], "不管怎么收的尾，记录都落了盘")
        print("[LAB-LIVE] 走法：recall \(calls.count) 次，其中到上限的 \(reads.filter { $0.status == "limited" }.count) 次；"
              + "工具回合 \(happened.rounds?.count ?? 0) 圈；最后：\(record.replied ? "有回复" : "没问成（\(happened.error ?? "")）")")
    }

    /// 重放一份两句的集子（plan-memory-lab-3 §4）：两句按顺序各真问一次模型，各出一条带 `sentenceId / paramsId / sets` 的记录；
    /// 再重放一次不重复跑（不多出记录 = 没再问模型）
    func testReplayingATwoSentenceSetLive() async throws {
        let (manager, model) = makeProvider()
        let lab = MemoryLabRunner(profile: Profile(id: pid, name: "星砚楼", emoji: "", description: "", userName: "岚舟", assistantName: "星砚"),
                                  preset: .balanced, providers: manager, container: container)
        let store = lab.store
        try store.save(MemoryLabSet(id: "live-set", name: "生活琐事", createdAt: Date(), items: [
            .init(sentenceId: "s-shop", text: "林栖的皮影小店开在哪座城？", addedAt: Date()),
            .init(sentenceId: "s-food", text: "我吃不吃香菜？只回吃或不吃。", addedAt: Date()),
        ]))
        // 这一组不主动翻：一句只问一次模型
        var chosen = params(model: model, maximumRecallCalls: 1)
        chosen.recallTool = false
        let group = try store.createParamSet(name: "不主动翻", params: lab.recorded(chosen))
        XCTAssertEqual(MemoryLabParams(recorded: store.paramSet(id: group.id)?.params), chosen, "存成一组再载入，参数一样")

        var seen: [Int] = []
        let produced = try await lab.replay(setId: "live-set", paramsId: group.id, params: chosen) { seen.append($0.done) }
        produced.forEach(log)
        XCTAssertEqual(produced.map(\.sentenceId), ["s-shop", "s-food"], "按集子里的顺序，两句都跑了")
        XCTAssertEqual(produced.map(\.paramsId), [group.id, group.id])
        XCTAssertEqual(produced.map(\.sets), [["live-set"], ["live-set"]])
        XCTAssertEqual(seen, [1, 2])
        for record in produced {
            XCTAssertNil(record.happened?.error)
            XCTAssertEqual(record.happened?.reply?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, false, "拿到回复")
            XCTAssertEqual(record.happened?.usage?.requests, 1, "不主动翻：一句问一次")
            XCTAssertEqual(record.happened?.rounds, [])
        }
        XCTAssertEqual(produced.first?.happened?.receipt?.decision.selected.contains { $0.source.path == "人/林栖" }, true,
                       "第一句点了页名，系统推送带上了那一页")
        XCTAssertEqual(produced.last?.happened?.messages?.contains { $0.content.contains("岚舟不吃香菜。") }, true, "钉住的在提示词里")
        XCTAssertEqual(store.entries(inSet: "live-set", paramsId: group.id).map(\.record?.id), produced.map(\.id), "落了盘，按这组取得到")
        XCTAssertEqual(store.runSummary(inSet: "live-set", paramsId: group.id), .init(count: 2, ran: 2, notRun: 0, unseen: 2))
        XCTAssertEqual(store.runSummary(inSet: "live-set", paramsId: MemoryLabParamSet.currentId).notRun, 2, "别的组下还是没跑过")

        let again = try await lab.replay(setId: "live-set", paramsId: group.id, params: chosen) { seen.append($0.done) }
        XCTAssertEqual(again, [], "再重放一次不重复跑")
        XCTAssertEqual(seen, [1, 2])
        let stored = await lab.records()
        XCTAssertEqual(stored.count, 2, "没多出记录")
    }
}
