import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 记忆实验台的执行器（plan-memory-lab §2 / §5）：一层编的楼（内存库 + 测试宿主临时家里的记忆根），模型是假的。
/// 守两件事：各开关真的改变放进提示词的东西；跑一句除了那条记录什么都不写。
@MainActor
final class MemoryLabRunnerTests: XCTestCase {
    private var pid = ""
    private var container: ModelContainer!
    private var memoryRoot: URL!
    private var pinnedId = UUID()
    private var parrotId = UUID()

    private let sentence = "林栖的皮影小店开了吗，雾岚还学门铃吗"

    override func setUp() async throws {
        try XCTSkipUnless(TestHostIsolation.active, "只在隔离的测试宿主里跑（要往家目录里建一层编的楼）")
        pid = "xctest-memory-lab-\(UUID().uuidString)"
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self, WorldBook.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        memoryRoot = FileLibraryStore.memoryRoot(profileId: pid)
        try seed()
    }

    override func tearDown() async throws {
        container = nil
        if let memoryRoot { try? FileManager.default.removeItem(at: memoryRoot.deletingLastPathComponent()) }
    }

    // MARK: - 编的楼

    private func seed() throws {
        let context = ModelContext(container)
        let now = Date()
        func memory(_ text: String, subject: String, pinned: Bool = false, approved: Bool = true) -> Memory {
            let m = Memory(content: text, category: "fact", profileId: pid, isUserExplicit: pinned, extractedBy: "fictional")
            m.subject = subject
            if !pinned { m.occurredDay = "2026-11-03" }
            m.reviewedAt = approved ? now : nil
            context.insert(m)
            return m
        }
        pinnedId = memory("岚舟不吃香菜。", subject: "岚舟", pinned: true).id
        _ = memory("每周五晚上去槐序巷皮影作坊上课。", subject: "岚舟")
        parrotId = memory("岚舟养的灰鹦鹉，会学门铃响。", subject: "雾岚").id
        _ = memory("栎川镇这两天降温了。", subject: "栎川镇", approved: false)

        // 上一个窗口：在花园里直接聊的一个窗口，两条消息
        let start = now.addingTimeInterval(-3600)
        context.insert(MessageNode(id: "lab-n1", role: "user", content: "雾岛的船票订好了", contentType: "text", createTime: start,
                                   parentId: nil, childrenIds: ["lab-n2"], conversationId: "lab-window", profileId: pid))
        context.insert(MessageNode(id: "lab-n2", role: "assistant", content: "那周末就出发", contentType: "text",
                                   createTime: start.addingTimeInterval(60), parentId: "lab-n1", childrenIds: [],
                                   conversationId: "lab-window", profileId: pid))
        let window = Conversation(id: "lab-window", title: "去雾岛", createTime: start, updateTime: start.addingTimeInterval(60),
                                  currentNodeId: "lab-n2", provider: "api", profileId: pid)
        window.lastRealChatAt = start.addingTimeInterval(60)
        context.insert(window)
        try context.save()

        try WikiStore(root: memoryRoot.appendingPathComponent("wiki", isDirectory: true))
            .save(WikiPage(path: "人/林栖", kind: .person, hook: "岚舟的皮影老师", title: "林栖", now: "林栖在云桥城开了一家皮影小店。"))
        try SelfMemoryStore.save(
            SelfMemory(slug: "xingyan-note", name: "星砚的备忘", description: "岚舟怕冷", type: "user", importance: 5, origin: "self",
                       created: now, source: nil, superseded: nil, body: "岚舟怕冷，降温要提醒她加衣服。"),
            memoryRoot: memoryRoot, checkPath: AppPaths.checked)
        let day = MemoryDay.key(MemoryClock.now)
        let item = TimelineDayRecord.Item(kind: .segment, conversationId: "lab-window", window: "去雾岛", title: "订了去雾岛的船票",
                                          start: start, end: start.addingTimeInterval(60), from: nil, to: nil)
        try TimelineStore.save(.init(days: [.init(date: day, headline: "准备去雾岛", items: [item])]),
                               month: String(day.prefix(7)), in: TimelineStore.dir(root: memoryRoot))
    }

    private var profile: Profile {
        Profile(id: pid, name: "星砚楼", emoji: "", description: "", userName: "岚舟", assistantName: "星砚")
    }

    private func runner(_ send: @escaping MemoryLabModelLoop.Send = { _, _ in .init(kind: .text("好。")) }) -> MemoryLabRunner {
        MemoryLabRunner(profile: profile, preset: .balanced, providers: ProviderManager(), container: container, send: send)
    }

    /// 全关的一组；每条测试只拨自己要看的那一项
    private func params(_ change: (inout MemoryLabParams) -> Void = { _ in }) -> MemoryLabParams {
        var p = MemoryLabParams(timeline: false, pending: false, selfMemory: false, rootIndex: false, previousWindow: false,
                                pinned: false, everyRound: false, tuning: RecallTestTuning.make(archiveTriggerEnabled: false),
                                recallTool: false, modelId: "none/none")
        change(&p)
        return p
    }

    private func prompt(_ record: MemoryLabRecord) -> String {
        (record.happened?.messages ?? []).map(\.content).joined(separator: "\n\n")
    }

    private func kinds(_ record: MemoryLabRecord) -> Set<String> {
        Set(record.happened?.receipt?.delivery?.items.map(\.kind) ?? [])
    }

    // MARK: - 各开关改变放进去的东西

    func testAllOffPutsNoMemoryIn() async throws {
        let record = try await runner().run(sentence, params: params())
        let text = prompt(record)
        for marker in ["不吃香菜", "皮影作坊", "灰鹦鹉", "栎川镇", "皮影小店。", "怕冷", "准备去雾岛", "船票订好了", WikiInjection.indexTitle] {
            XCTAssertFalse(text.contains(marker), "全关时不该有「\(marker)」")
        }
        XCTAssertTrue(text.contains(sentence), "那句话自己在")
        XCTAssertEqual(record.happened?.messages?.last?.role, "user")
        XCTAssertEqual(record.happened?.receipt?.delivery?.items, [])
        XCTAssertEqual(record.happened?.prompt?.segments, [], "记忆一样没放 = 和不带记忆一字不差")
        XCTAssertEqual(record.happened?.reply, "好。")
    }

    func testPinnedSwitch() async throws {
        let record = try await runner().run(sentence, params: params { $0.pinned = true })
        XCTAssertTrue(prompt(record).contains("岚舟不吃香菜。"))
        XCTAssertFalse(prompt(record).contains("灰鹦鹉"), "钉住的那一勾不带批过的原子事实")
        XCTAssertEqual(kinds(record), [RecallDeliveryItem.Kind.pinned])
        XCTAssertEqual(record.happened?.prompt?.segments?.map(\.source), [SegmentSource.memory.displayName])
        XCTAssertNil(record.happened?.prompt?.segments?.first?.without, "不带记忆时没有这一段")
        XCTAssertEqual(record.happened?.prompt?.everyRound?.contains("岚舟不吃香菜。"), true)
        XCTAssertEqual(record.happened?.prompt?.pushed, "")
    }

    func testSelfMemorySwitch() async throws {
        let record = try await runner().run(sentence, params: params { $0.selfMemory = true })
        XCTAssertTrue(prompt(record).contains("岚舟怕冷，降温要提醒她加衣服。"))
        XCTAssertEqual(kinds(record), [RecallDeliveryItem.Kind.selfMemory])
    }

    func testRootIndexSwitch() async throws {
        let record = try await runner().run(sentence, params: params { $0.rootIndex = true })
        XCTAssertTrue(prompt(record).contains(WikiInjection.indexTitle))
        XCTAssertFalse(prompt(record).contains("林栖在云桥城开了一家皮影小店。"), "只带目录，不带页的正文")
        XCTAssertEqual(kinds(record), [RecallDeliveryItem.Kind.rootIndex])
    }

    func testEveryRoundSwitchBringsApprovedFactsOnly() async throws {
        let record = try await runner().run("今天好累", params: params { $0.everyRound = true })
        let text = prompt(record)
        XCTAssertTrue(text.contains("每周五晚上去槐序巷皮影作坊上课。"))
        XCTAssertTrue(text.contains("岚舟养的灰鹦鹉，会学门铃响。"))
        XCTAssertFalse(text.contains("栎川镇这两天降温了"), "没批过的不带")
        XCTAssertFalse(text.contains("岚舟不吃香菜"), "钉住的听它自己那一勾")
        XCTAssertTrue(kinds(record).contains(RecallDeliveryItem.Kind.legacyFragment))
    }

    func testSystemPushBringsOnlyWhatTheSentenceTouches() async throws {
        let on = params { $0.systemPush = true }
        let record = try await runner().run(sentence, params: on)
        let text = prompt(record)
        XCTAssertTrue(text.contains("林栖在云桥城开了一家皮影小店。"), "点了页名的那一页")
        XCTAssertTrue(text.contains("岚舟养的灰鹦鹉，会学门铃响。"), "点了名字的那一条")
        XCTAssertFalse(text.contains("每周五晚上去槐序巷皮影作坊上课。"), "没聊到的那一条不推送")
        let decision = try XCTUnwrap(record.happened?.receipt?.decision)
        XCTAssertEqual(decision.gateReason, .search)
        XCTAssertEqual(Set(decision.selected.map(\.source.path)), ["人/林栖", parrotId.uuidString])
        XCTAssertTrue(kinds(record).isSuperset(of: [RecallDeliveryItem.Kind.page, RecallDeliveryItem.Kind.fragment]))
        XCTAssertEqual(record.happened?.prompt?.pushed?.contains("林栖在云桥城开了一家皮影小店。"), true)

        // 同一组参数，说一句不相干的：什么都不推送
        let other = try await runner().run("今天晚饭吃的汤面", params: on)
        XCTAssertFalse(prompt(other).contains("皮影小店。"))
        XCTAssertFalse(prompt(other).contains("灰鹦鹉"))
        XCTAssertEqual(other.happened?.receipt?.decision.selected, [])
    }

    func testTimelineSwitch() async throws {
        let record = try await runner().run(sentence, params: params { $0.timeline = true })
        XCTAssertTrue(prompt(record).contains("准备去雾岛"))
        XCTAssertTrue(kinds(record).contains(RecallDeliveryItem.Kind.timeline))
        XCTAssertEqual(record.happened?.prompt?.segments?.map(\.source), [SegmentSource.timeline.displayName])
    }

    func testPreviousWindowSwitch() async throws {
        let record = try await runner().run(sentence, params: params { $0.previousWindow = true })
        XCTAssertTrue(prompt(record).contains("雾岛的船票订好了"))
        XCTAssertTrue(prompt(record).contains("那周末就出发"))
        XCTAssertEqual(kinds(record), [RecallDeliveryItem.Kind.previousWindow])
    }

    // MARK: - 记录里有什么

    func testRecordCarriesEnvironmentParamsAndIsSaved() async throws {
        var chosen = params { $0.pinned = true; $0.systemPush = true; $0.recallTool = true }
        chosen.tuning.maximumPages = 5
        let lab = runner()
        let record = try await lab.run(sentence, params: chosen)
        XCTAssertEqual(record.input.text, sentence)
        XCTAssertEqual(record.environment?.profileId, pid)
        XCTAssertEqual(record.environment?.counts, .init(approvedFacts: 2, allFacts: 3, wikiPages: 1, pinned: 1))
        XCTAssertEqual(record.environment?.window, MemoryLabRecord.Environment.firstTurn)
        XCTAssertEqual(record.environment?.presetName, Preset.balanced.name)
        XCTAssertEqual(record.environment?.fingerprint?.count, 16)
        XCTAssertEqual(record.environment?.promptHash?.count, 16)
        XCTAssertEqual(record.params?.items?[MemoryLabRecord.Item.pinned], true)
        XCTAssertEqual(record.params?.items?[MemoryLabRecord.Item.timeline], false)
        XCTAssertEqual(record.params?.systemPush, true)
        XCTAssertEqual(record.params?.recallTool, true)
        XCTAssertEqual(record.params?.tuning?.maximumPages, 5)
        XCTAssertEqual(record.params?.differences, chosen.differences(from: lab.currentParams()))
        XCTAssertEqual(record.happened?.receipt?.delivery?.gate.choices["archive"], true, "推送开着 = 这个窗口的档案开着")
        XCTAssertEqual(record.happened?.receipt?.attempts.map(\.status), [.responded])
        XCTAssertEqual(record.happened?.missing?.isEmpty, false)
        XCTAssertEqual(record.sets, [])
        XCTAssertNil(record.judgment)

        let stored = await lab.records()
        XCTAssertEqual(stored, [record], "落盘的和回给页面的是同一条")
        let judged = try await lab.judge(record.id) { $0.verdict = .up }
        XCTAssertEqual(judged.judgment?.verdict, .up)
        let again = await lab.records()
        XCTAssertEqual(MemoryLabStore.summary(again), .init(count: 1, up: 1, down: 0))

        // 同一刻的记忆、同一组参数：指纹和提示词哈希不变
        let second = try await lab.run("今天晚饭吃的汤面", params: chosen)
        XCTAssertEqual(second.environment?.fingerprint, record.environment?.fingerprint)
        XCTAssertEqual(second.environment?.promptHash, record.environment?.promptHash)
    }

    /// 第三片的三个标记（这句话的键 / 在哪几份测试集里 / 算哪一组参数）只写进记录：
    /// 同一句、同一组参数，带不带它们，选中的记忆、每轮都带的清单、拼出来的有序消息逐字相等
    func testSentenceSetAndGroupMarkersDoNotChangeWhatIsSent() async throws {
        let chosen = params {
            $0.timeline = true; $0.selfMemory = true; $0.rootIndex = true; $0.previousWindow = true
            $0.pinned = true; $0.systemPush = true; $0.recallTool = true
        }
        let lab = runner()
        let plain = try await lab.run(sentence, params: chosen)
        let marked = try await lab.run(sentence, params: chosen, sentenceId: "s-parrot", sets: ["life", "close"], paramsId: "wide")

        XCTAssertNil(plain.sentenceId)
        XCTAssertNil(plain.paramsId)
        XCTAssertEqual(plain.sets, [])
        XCTAssertEqual(plain.paramsGroup, chosen.differences(from: lab.currentParams()).isEmpty ? MemoryLabParamSet.currentId : nil)
        XCTAssertEqual(marked.sentenceId, "s-parrot")
        XCTAssertEqual(marked.sets, ["life", "close"])
        XCTAssertEqual(marked.paramsId, "wide")
        XCTAssertEqual(marked.paramsGroup, "wide")

        XCTAssertFalse(plain.happened?.messages?.isEmpty ?? true)
        XCTAssertTrue(prompt(plain).contains("林栖在云桥城开了一家皮影小店。"), "这一组参数下确实放了记忆进去，比的不是空的")
        XCTAssertEqual(marked.happened?.messages, plain.happened?.messages, "发给模型的有序消息逐字相等")
        XCTAssertEqual(marked.happened?.prompt, plain.happened?.prompt)
        XCTAssertEqual(marked.happened?.receipt?.decision.selected, plain.happened?.receipt?.decision.selected)
        XCTAssertEqual(marked.happened?.receipt?.delivery, plain.happened?.receipt?.delivery)
        XCTAssertEqual(marked.params, plain.params)
        XCTAssertEqual(marked.environment, plain.environment)
        XCTAssertEqual(marked.happened?.missing, plain.happened?.missing)
        let stored = await lab.records()
        XCTAssertEqual(stored.first { $0.id == marked.id }, marked, "三样落了盘")
    }

    /// 调用方的 Task 被取消（离开页面 / 切楼层）不传进 `run`：这一句照样选记忆、问模型、落盘，和没取消时一字不差。
    /// （传进去的话 wiki 预热会抛取消、全文搜词会悄悄给空结果：推送的东西变样，或者存成一条出错记录）
    func testCancellingTheCallerDoesNotCorruptTheSentence() async throws {
        let chosen = params { $0.pinned = true; $0.rootIndex = true; $0.systemPush = true }
        let baseline = try await runner().run(sentence, params: chosen)
        XCTAssertTrue(prompt(baseline).contains("林栖在云桥城开了一家皮影小店。"))

        // 还没开始就已经取消了
        let lab = runner()
        let sentence = sentence
        let early = try await Task { () -> MemoryLabRecord in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await lab.run(sentence, params: chosen)
        }.value
        // 问模型问到一半时取消
        var task: Task<MemoryLabRecord, Error>?
        let asking = runner { _, _ in
            task?.cancel()
            return .init(kind: .text("开了。"))
        }
        task = Task { try await asking.run(sentence, params: chosen) }
        let midway = try await XCTUnwrap(task).value

        for (name, record) in [("开始前取消", early), ("问到一半取消", midway)] {
            XCTAssertNil(record.happened?.error, name)
            XCTAssertNotNil(record.happened?.reply, name)
            XCTAssertEqual(record.happened?.messages, baseline.happened?.messages, "\(name)：拼出来的有序消息和没取消时逐字相等")
            XCTAssertEqual(record.happened?.receipt?.decision.selected, baseline.happened?.receipt?.decision.selected, name)
            XCTAssertEqual(record.happened?.receipt?.attempts.map(\.status), [.responded], name)
        }
        let stored = await lab.records()
        XCTAssertEqual(Set(stored.map(\.id)), [baseline.id, early.id, midway.id], "三条都落了盘")
    }

    /// 主动翻：假模型调一次 recall，执行的是真的 `RecallTool`（翻这层编的楼），读回执进记录
    func testRecallRoundRunsTheRealToolAndLandsInTheReceipt() async throws {
        var asked = 0
        var offered: [Bool] = []
        let lab = runner { _, offer in
            asked += 1
            offered.append(offer)
            return asked == 1
                ? .init(kind: .toolCalls([ToolCallBlock(id: "call-1", name: RecallTool.toolName,
                                                        argumentsJSON: #"{"op":"wiki","layer":"index","folder":"人"}"#)]))
                : .init(kind: .text("林栖的店开了。"))
        }
        let record = try await lab.run(sentence, params: params { $0.recallTool = true })
        XCTAssertEqual(offered, [true, true])
        XCTAssertEqual(record.happened?.reply, "林栖的店开了。")
        let call = try XCTUnwrap(record.happened?.rounds?.first?.calls.first)
        XCTAssertEqual(call.isError, false, call.result ?? "")
        XCTAssertEqual(call.result?.contains("林栖"), true, "翻的是这层楼的 wiki 目录")
        let read = try XCTUnwrap(record.happened?.receipt?.reads.first)
        XCTAssertEqual(read.toolCallId, "call-1")
        XCTAssertEqual(read.layer, "wiki索引")
        XCTAssertEqual(read.turnId, record.id)
        XCTAssertEqual(record.happened?.usage?.requests, 2)
    }

    /// 模型回了空的：不当成一条回复存（页面上会是个空气泡），记成没问成；在一组参数下它不算跑过
    func testEmptyReplyIsRecordedAsNotAsked() async throws {
        let lab = runner { _, _ in .init(kind: .text("")) }
        let record = try await lab.run(sentence, params: params { $0.pinned = true }, sentenceId: "s1", sets: ["life"], paramsId: "wide")
        XCTAssertNil(record.happened?.reply)
        XCTAssertEqual(record.happened?.error, "模型回了空的")
        XCTAssertFalse(record.replied)
        XCTAssertEqual(record.happened?.receipt?.attempts.map(\.status), [.failed])
        XCTAssertTrue(prompt(record).contains("岚舟不吃香菜。"), "想起了什么那一半还在")
        let store = lab.store
        try store.save(MemoryLabSet(id: "life", name: "生活琐事", createdAt: Date(), items: [.init(sentenceId: "s1", text: sentence)]))
        XCTAssertEqual(store.runSummary(inSet: "life", paramsId: "wide"), .init(count: 1, notRun: 1, failed: 1), "重放会再问它")
    }

    func testModelFailureStillSavesTheRecord() async throws {
        let lab = runner { _, _ in .init(kind: .failed("401 没有钥匙")) }
        let record = try await lab.run(sentence, params: params { $0.pinned = true })
        XCTAssertNil(record.happened?.reply)
        XCTAssertEqual(record.happened?.error, "401 没有钥匙")
        XCTAssertTrue(prompt(record).contains("岚舟不吃香菜。"), "想起了什么那一半还在")
        XCTAssertEqual(record.happened?.receipt?.attempts.map(\.status), [.failed])
        let stored = await lab.records()
        XCTAssertEqual(stored, [record])
    }

    /// 不换假模型：找不到模型 / CC 桥都不往外发，记录照存
    func testUnusableModelsAreNotAsked() async throws {
        let providers = ProviderManager()
        let lab = MemoryLabRunner(profile: profile, preset: .balanced, providers: providers, container: container)
        let missing = try await lab.run(sentence, params: params { $0.modelId = "xctest-lab-nowhere/none" })
        XCTAssertEqual(missing.happened?.error?.contains("找不到这个模型"), true)
        XCTAssertNil(missing.happened?.receipt?.attempts.first, "没发出去就没有 attempt")

        let id = "xctest-lab-cc-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: "cc", name: "CC")
        providers.addCredential(APICredential(id: id, name: "编的 CC 桥", emoji: "", type: .ccBridge, baseURL: "http://127.0.0.1:9",
                                              extraHeaders: [:], models: [model], toolsSupported: true))
        addTeardownBlock { @MainActor in providers.removeCredential(id: id) }
        let bridged = try await lab.run(sentence, params: params { $0.modelId = model.id })
        XCTAssertEqual(bridged.happened?.error?.contains("Claude Code"), true)
        XCTAssertNil(bridged.happened?.reply)
        let stored = await lab.records()
        XCTAssertEqual(stored.count, 2)
    }

    // MARK: - 不写

    private struct MemoryRow: Equatable {
        let id: UUID
        let content: String
        let lastAccessedAt: Date
        let accessCount: Int
        let decayWeight: Double
        let updatedAt: Date
        let reviewedAt: Date?
        let supersededAt: Date?
    }

    private func memoryRows() throws -> [MemoryRow] {
        try ModelContext(container).fetch(FetchDescriptor<Memory>()).map {
            MemoryRow(id: $0.id, content: $0.content, lastAccessedAt: $0.lastAccessedAt, accessCount: $0.accessCount,
                      decayWeight: $0.decayWeight, updatedAt: $0.updatedAt, reviewedAt: $0.reviewedAt, supersededAt: $0.supersededAt)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func files() -> Set<String> {
        let base = memoryRoot.standardizedFileURL.path + "/"
        var out = Set<String>()
        let all = FileManager.default.enumerator(at: memoryRoot, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = all?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            out.insert(String(url.standardizedFileURL.path.dropFirst(base.count)))
        }
        return out
    }

    /// 全开着跑一句、助手还翻了一次命中记忆条目的 recall：
    /// 记忆条目的访问数 / 权重 / 访问时间不变，偏好一个键不多一个值不改，记忆根下只多了 lab/（和本来就会建的全文索引），没有新的对话和消息
    func testRunWritesNothingButTheRecord() async throws {
        var chosen = params {
            $0.timeline = true; $0.pending = true; $0.selfMemory = true; $0.rootIndex = true
            $0.previousWindow = true; $0.pinned = true; $0.everyRound = true; $0.systemPush = true; $0.recallTool = true
        }
        chosen.tuning.maximumPages = 7   // 和她存的不一样：不能被写回设置
        // 先让全文索引建好（真聊天本来就会建），再拍跑之前的样子
        _ = try await runner().run(sentence, params: params { $0.systemPush = true })
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)

        let rowsBefore = try memoryRows()
        let filesBefore = files()
        let defaultsBefore = NSDictionary(dictionary: UserDefaults.standard.dictionaryRepresentation())
        let context = ModelContext(container)
        let conversationsBefore = try context.fetchCount(FetchDescriptor<Conversation>())
        let nodesBefore = try context.fetchCount(FetchDescriptor<MessageNode>())

        var asked = 0
        var hit: [UUID] = []
        let lab = runner { _, _ in
            asked += 1
            return asked == 1
                ? .init(kind: .toolCalls([ToolCallBlock(id: "call-1", name: RecallTool.toolName,
                                                        argumentsJSON: #"{"op":"search","query":"灰鹦鹉 门铃","scope":"c"}"#)]))
                : .init(kind: .text("还学。"))
        }
        let record = try await lab.run(sentence, params: chosen)
        XCTAssertEqual(record.happened?.reply, "还学。")
        let call = try XCTUnwrap(record.happened?.rounds?.first?.calls.first)
        XCTAssertEqual(call.isError, false, call.result ?? "")
        hit = try memoryRows().filter { call.result?.contains($0.content) == true }.map(\.id)
        XCTAssertTrue(hit.contains(parrotId), "recall 确实翻到了那条记忆条目（真聊天在这里会给它加访问数）：\(call.result ?? "")")
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)

        XCTAssertEqual(try memoryRows(), rowsBefore, "Memory 行一个字段都没变")
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Conversation>()), conversationsBefore, "没有新的对话")
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<MessageNode>()), nodesBefore, "没有新的消息")

        let defaultsAfter = NSDictionary(dictionary: UserDefaults.standard.dictionaryRepresentation())
        // 比整个偏好字典，不是只查几个记忆键：实验台以后不管往哪个键写都会红。
        // 只放过 Apple 框架自己的命名空间：测试宿主是整个 app，它的 WebKit / AppKit 会在这几秒里自己往偏好里记东西
        // （WebKitJSC… / WebKitPrefersFullScreenDimming / 窗口位置），和实验台无关；app 自己的键没有一个用这些前缀
        let frameworkPrefixes = ["WebKit", "NS", "Apple", "com.apple."]
        let changed = Set((defaultsBefore.allKeys + defaultsAfter.allKeys).compactMap { $0 as? String }).filter { key in
            guard !frameworkPrefixes.contains(where: key.hasPrefix) else { return false }
            switch (defaultsBefore[key], defaultsAfter[key]) {
            case (nil, nil): return false
            case let (before?, after?): return !(before as AnyObject).isEqual(after)
            default: return true
            }
        }
        XCTAssertEqual(changed.sorted(), [], "偏好没多键、没改值（Apple 框架自己的键不算）")
        XCTAssertFalse(defaultsBefore.allKeys.compactMap { $0 as? String }.filter { !frameworkPrefixes.contains(where: $0.hasPrefix) }.isEmpty,
                       "比的那一堆里得有 app 自己的键，不然这条断言等于没比")
        XCTAssertNil(UserDefaults.standard.object(forKey: "mem_last_injection_\(pid)"), "没记「上一轮实际注入」")
        XCTAssertEqual(RecallTuningStore.load(profileId: pid), .defaults, "系统推送那一页的数没被写进她的设置")

        let added = files().subtracting(filesBefore)
        XCTAssertEqual(added, ["lab/records/\(record.id).json"], "记忆根下只多了这条记录")
        XCTAssertEqual(filesBefore.subtracting(files()), [], "没少东西")
        XCTAssertNil(MemoryWriteLog.entries(memoryRoot: memoryRoot).first, "没往记忆日志写")
    }

    // MARK: - 参数

    func testCurrentParamsOnlyReadsHerSettings() throws {
        let suite = "xctest-memory-lab-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // 没设过的楼层：推送默认开、每轮全带没勾、wiki 目录没勾
        let untouched = MemoryLabParams.current(profileId: pid, modelId: "card/model", defaults: defaults)
        XCTAssertEqual(untouched.systemPush, true)
        XCTAssertEqual(untouched.everyRound, false)
        XCTAssertEqual(untouched.rootIndex, false)
        XCTAssertEqual(untouched.tuning, .defaults)
        XCTAssertEqual(untouched.modelId, "card/model")
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("mem") || $0.hasPrefix("recall") }, [], "读一份不留痕")

        var tuning = RecallTuning.defaults
        tuning.archiveTriggerEnabled = false
        tuning.maximumPages = 5
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        MemoryOpenWindowStore.save(.c, true, profileId: pid, defaults: defaults)
        MemoryOpenWindowStore.save(.a4, false, profileId: pid, defaults: defaults)
        MemoryOpenWindow.setEveryRound(true, profileId: pid, defaults: defaults)
        MemoryWindowChoices.setDefault(.pinned, false, profileId: pid, defaults: defaults)
        let hers = MemoryLabParams.current(profileId: pid, modelId: "card/model", defaults: defaults)
        XCTAssertEqual(hers.systemPush, false)
        XCTAssertEqual(hers.tuning.maximumPages, 5)
        XCTAssertEqual(hers.rootIndex, true)
        XCTAssertEqual(hers.everyRound, true)
        XCTAssertEqual(hers.timeline, false)
        XCTAssertEqual(hers.pinned, false)
        XCTAssertEqual(hers.windowChoices, MemoryWindowChoices.defaults(profileId: pid, defaults: defaults), "和这时新开一个窗口纸条上的六项一样")
        XCTAssertEqual(hers.differences(from: hers), [])

        var lab = hers
        lab.systemPush = true
        lab.pinned = true
        lab.tuning.maximumFragments = 6
        lab.tuning.fullTextCoverageThreshold = 0.8
        lab.recallTool.toggle()
        lab.modelId = "card/other"
        typealias Item = MemoryLabRecord.Item
        XCTAssertEqual(lab.differences(from: hers), [
            .init(key: Item.pinned, settings: "false", lab: "true"),
            .init(key: Item.systemPush, settings: "false", lab: "true"),
            .init(key: Item.recallTool, settings: "\(hers.recallTool)", lab: "\(lab.recallTool)"),
            .init(key: Item.tuningPrefix + "maximumFragments", settings: "3", lab: "6"),
            .init(key: Item.tuningPrefix + "fullTextCoverageThreshold", settings: "0.6", lab: "0.8"),
            .init(key: Item.model, settings: "card/model", lab: "card/other"),
        ])
        XCTAssertEqual(MemoryLabParams.current(profileId: pid, modelId: "card/model", defaults: defaults), hers, "在台子上拨不改她的设置")
    }

    /// 三样有一样开着，新窗口的「档案」就开；记忆整个关掉那一份只差总开关
    func testParticipationFollowsNewWindowRule() {
        XCTAssertFalse(params().participation().cards)
        XCTAssertTrue(params { $0.rootIndex = true }.participation().archive)
        let pushed = params { $0.systemPush = true }.participation()
        XCTAssertTrue(pushed.pages)
        XCTAssertTrue(pushed.fullText)
        XCTAssertFalse(pushed.everyRound)
        XCTAssertTrue(params { $0.everyRound = true }.participation().everyRound)
        XCTAssertFalse(params { $0.previousWindow = true }.participation().isLegacy)
        XCTAssertTrue(params { $0.previousWindow = true }.participation().previousWindow)
        let off = params { $0.pinned = true; $0.timeline = true; $0.systemPush = true }.participation(memory: false)
        XCTAssertEqual(off.off, .master)
        XCTAssertFalse(off.pinned)
        XCTAssertFalse(off.timeline)
        XCTAssertFalse(off.pages)
    }

    // MARK: - lab/ 不给助手、文件库、CC 看

    func testLabFolderIsHiddenFromAssistantFileLibraryAndCC() async throws {
        let record = try await runner().run(sentence, params: params())
        let path = "memory/lab/records/\(record.id).json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryRoot.appendingPathComponent("lab/records/\(record.id).json").path))
        let pid = pid
        let (assistant, library, search) = await Task.detached {
            (FileLibraryStore.memoryList(profileId: pid).map(\.path), FileLibraryStore.memoryUIList(profileId: pid).map(\.path),
             FileLibraryStore.memorySearch("林栖", profileId: pid).map(\.path))
        }.value
        XCTAssertTrue(assistant.contains("memory/wiki/人/林栖.md"), "别的照列：\(assistant)")
        for (name, list) in [("助手的文件清单", assistant), ("文件库列表", library), ("助手的搜索", search)] {
            XCTAssertFalse(list.contains { $0.hasPrefix("memory/lab") }, "\(name)里不该有 lab/：\(list)")
        }
        XCTAssertTrue(FileLibraryTools.hiddenFromAssistant(path), "按路径直接读也不给")
        XCTAssertTrue(FileLibraryTools.hiddenFromAssistant("memory/Lab/records/x.json"))
        XCTAssertNil(FileLibraryStore.resolveMemory(path, profileId: pid))
        XCTAssertNotNil(GardenTree.exclusion(path), "带到电脑上给 CC 的那棵树只有 md / txt")
        XCTAssertFalse(FileLibraryTools.hiddenFromAssistant("memory/self/xingyan-note.md"))
    }
}
