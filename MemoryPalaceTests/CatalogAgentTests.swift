import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

/// 假后端：第 n 轮回什么由脚本定；nil = 一直不回（测停）
@MainActor
final class FakeCatalogBackend: AssistantBackend {
    var reply: @MainActor (Int, AssistantBackendRequest) -> AssistantBackendEvent?
    private(set) var requests: [AssistantBackendRequest] = []
    var tokens: @MainActor (Int) -> [String] = { _ in [] }
    private(set) var cancelled = false

    init(_ reply: @escaping @MainActor (Int, AssistantBackendRequest) -> AssistantBackendEvent?) {
        self.reply = reply
    }

    func run(_ request: AssistantBackendRequest, onEvent: @escaping @MainActor (AssistantBackendEvent) -> Void) {
        requests.append(request)
        guard let event = reply(requests.count, request) else { return }
        let body = tokens(requests.count)
        Task { @MainActor in
            for token in body { onEvent(.token(token)) }
            onEvent(event)
        }
    }

    func cancel() {
        cancelled = true
    }
}

@MainActor
enum CatalogTestKit {
    static let names = MemoryExtractor.Names(userName: "粟粟", assistantName: "小克")

    static func call(_ name: String, _ args: String, id: String = UUID().uuidString, truncated: Bool = false) -> ToolCallBlock {
        ToolCallBlock(id: id, name: name, argumentsJSON: args, truncated: truncated)
    }

    static func job(pid: String, root: URL, container: ModelContainer, caller: @escaping SessionSegmentWriter.Caller = { _, _ in nil },
                    backend: FakeCatalogBackend? = nil, maxTopics: Int = 8, maxRounds: Int = 10) -> CatalogJob {
        let fake = backend ?? FakeCatalogBackend { _, _ in .failed("没配后端") }
        return CatalogJob(profileId: pid, memoryRoot: root, container: container, names: names, floorPrompt: "", modelName: "假模型",
                          caller: caller, agentDeps: CatalogAgent.Deps(makeBackend: { fake }, gate: { _ in nil }),
                          maxTopics: maxTopics, maxRounds: maxRounds, embedder: CatalogFakeEmbedder.unavailable())
    }

    /// A4 时间轴夹具：一个窗口一条
    static func timeline(root: URL, conv: String, title: String, topics: [String], day: Int) throws {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 20))!
        let e = TimelineEntry(start: start, end: start.addingTimeInterval(1800), conversationId: conv, title: title,
                              text: topics.map { "- \($0)" }.joined(separator: "\n"), pending: "", day: MemoryDay.key(start))
        try TimelineStore.write([e], month: "2026-10", in: TimelineStore.dir(root: root))
    }
}

/// C3 手动 = 真 agent（plan-memory-c3-catalog 4.1b、todo 7b）：多轮查 → 交、轮数 / 字数封顶交「没整理完」、被预算拦停、停、提醒交
@MainActor
final class CatalogAgentTests: XCTestCase {

    private let pid = "xctest-catalog-agent"
    private var root: URL!
    private var gateCalls = 0

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-agent-\(UUID().uuidString)", isDirectory: true)
        gateCalls = 0
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
    }

    private let movie = CatalogFragment(id: UUID(), content: "一起看了电影", category: "fact", day: "2026-10-12")
    private let bread = CatalogFragment(id: UUID(), content: "喜欢面包", category: "preference", day: "2026-10-13")

    private func job(snapshot: [CatalogFragment]? = nil, maxRounds: Int = 10) -> CatalogAgent.Job {
        CatalogAgent.Job(topic: "电影", aliases: ["片子"], path: "事/电影", fragmentIds: [movie.id, bread.id], profileId: pid,
                         memoryRoot: root, names: CatalogTestKit.names, floorPrompt: "", snapshot: snapshot ?? [movie, bread],
                         modelName: "假模型", maxRounds: maxRounds, embedder: CatalogFakeEmbedder.unavailable())
    }

    private func agent(_ backend: FakeCatalogBackend, block: ((Int) -> String?)? = nil) -> CatalogAgent {
        CatalogAgent(deps: CatalogAgent.Deps(makeBackend: { backend }, gate: { [weak self] _ in
            await MainActor.run { self?.gateCalls += 1 }
            let n = await MainActor.run { self?.gateCalls ?? 0 }
            return block?(n)
        }))
    }

    private let submit = """
    {"items":[{"type":"new_page","path":"事/电影","kind":"事","title":"电影","hook":"她提到电影、看片的时候先看这页","now":"在追科幻片（自 2026-10 起）。",
      "records":[{"text":"2026-10-12 一起看了《星际穿越》","fragments":["f1"],"aline":[{"layer":"A4","window":"0001aaaa"}]},{"text":"没出处的一行"}]}]}
    """

    private func search(_ terms: String = "电影") -> AssistantBackendEvent {
        .toolCalls([CatalogTestKit.call("search_fragments", "{\"terms\":[\"\(terms)\"]}")])
    }

    // MARK: -

    func testManualOpeningUsesOnlySharedDomainPrincipleWithoutSeedSchema() {
        var j = job(snapshot: [])
        j.floorPrompt = "虚构底图：云桥城有夜航。"
        let content = CatalogAgent.opening(j, rootIndex: "", labels: [:])
        XCTAssertTrue(content.contains(CatalogPrompts.factDomainPrinciple))
        XCTAssertFalse(content.contains("fact_domain"))
        XCTAssertTrue(content.contains(j.floorPrompt))
    }

    func testMultiRoundSearchThenSubmit() async throws {
        try CatalogTestKit.timeline(root: root, conv: "0001aaaa-conv", title: "看片", topics: ["一起看了电影《星际穿越》"], day: 12)
        let backend = FakeCatalogBackend { [submit] n, _ in
            switch n {
            case 1: return .toolCalls([CatalogTestKit.call("search_aline", "{\"terms\":[\"电影\",\"片子\"]}")])
            case 2: return .toolCalls([CatalogTestKit.call("search_fragments", "{\"terms\":[\"电影\"]}"), CatalogTestKit.call("list_wiki", "")])
            default: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
            }
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(out.rounds, 3)
        XCTAssertFalse(out.incomplete)
        XCTAssertEqual(out.dropped, 1, "没出处的那行扔掉")
        XCTAssertEqual(gateCalls, 3, "每一轮发请求前都过闸")
        let item = try XCTUnwrap(out.items.first)
        guard case .newPage(let page) = item.change else { return XCTFail("应该是新开页") }
        XCTAssertEqual(page.records.count, 1)
        XCTAssertTrue(page.records[0].contains("出处：碎片 \(movie.id.uuidString.prefix(8).lowercased())；A4 2026-10-12《看片》"), page.records[0])
        XCTAssertEqual(item.cites.first?.windowId, "0001aaaa-conv", "只能引用搜过的窗口")
        XCTAssertEqual(item.fragmentIds, [movie.id], "分到却没引用的不挂（astra #7），留在池里")
        XCTAssertNil(item.covered)
        XCTAssertEqual(backend.requests[0].tools.count, 6)
        XCTAssertTrue(backend.requests[0].history[0].content.contains("【主题】电影（别名：片子）"))
        XCTAssertTrue(backend.requests[1].toolTurns[0].results[0].text.contains("星际穿越"))
        let fragmentLine = try XCTUnwrap(backend.requests[2].toolTurns[1].results[0].text.components(separatedBy: "\n").first { $0.hasPrefix("- f1 · ") })
        XCTAssertTrue(fragmentLine.hasPrefix("- f1 · 2026-10-12 · 没整理 · "))
        XCTAssertTrue(fragmentLine.hasSuffix(" · " + movie.content))
        XCTAssertTrue(backend.requests[2].toolTurns[1].results[1].text.contains("# C 档案"), "list_wiki 不给 path = 根索引")

        MemoryWriteLog.flush()
        let notes = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).map(\.note)
        XCTAssertTrue(notes.contains { $0.hasPrefix("整理「电影」第 1 轮：search_aline「电影」「片子」 ") }, "日志带搜索词：\(notes)")
        XCTAssertTrue(notes.contains { $0.hasPrefix("整理「电影」第 2 轮：search_fragments「电影」 ") && $0.contains("、list_wiki 根 ") }, "\(notes)")
    }

    private func runFiles() throws -> [URL] {
        let folder = root.appendingPathComponent("wiki", isDirectory: true)
            .appendingPathComponent(CatalogRunRecord.folderName, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    func testRunRecordPreservesEveryRoundFullTextParsingFeedbackAndLogLinks() async throws {
        let longFragment = CatalogFragment(id: UUID(), content: "电影" + String(repeating: "完整原料", count: 2000),
                                           category: "fact", day: "2026-10-12")
        let searchJSON = "{\"terms\":[\"电影\"],\"备注\":\"" + String(repeating: "参数原文", count: 2000) + "参数末尾\"}"
        let malformed = "坏参数开头```json\n" + String(repeating: "原文", count: 11_000) + "\n```坏参数末尾"
        let modelBody = "模型正文开头\n```\n" + String(repeating: "逐轮正文", count: 6000) + "\n```\n模型正文末尾"
        let finishedBody = "finished 的真正全文\n" + String(repeating: "最终提醒正文", count: 4000) + "\n真正全文末尾"
        let accepted = """
        {"items":[{"type":"new_page","path":"事/电影","kind":"事","title":"电影","records":[{"text":"一起看电影的完整记录","fragments":["f1"]}]}],"covered":["f2"],"reason":"面包已有页完整记录"}
        """
        let backend = FakeCatalogBackend { [allDropped] n, _ in
            switch n {
            case 1: return .toolCalls([CatalogTestKit.call("search_fragments", searchJSON, id: "search-full")])
            case 2: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, malformed, id: "bad-full")])
            case 3: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, accepted, id: "truncated-full", truncated: true)])
            case 4: return .finished(finishedBody)
            case 5: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, allDropped, id: "drop-full")])
            default: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, accepted, id: "accepted-full")])
            }
        }
        backend.tokens = { n in n == 4 ? ["不是 finished 全文的流式片段"] : [modelBody, "第 \(n) 轮正文收尾"] }
        let catalog = CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in nil }, roundCost: { _ in 0.0123 }))

        // 每一页最多修订一次、修订后那一份就是最后一份（第 9 段）：全部被扔放到最后，修订那一轮交上合格的
        let out = await catalog.run(job(snapshot: [movie, bread, longFragment], maxRounds: 7))

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(out.rounds, 6)
        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(out.items.first?.covered, [bread.id])
        XCTAssertEqual(backend.requests.count, 6)
        XCTAssertEqual(backend.requests.last?.tools.count, 1)
        let files = try runFiles()
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        let text = try String(contentsOf: file, encoding: .utf8)
        for round in [1, 2, 3, 5, 6] {
            XCTAssertTrue(text.contains(modelBody + "第 \(round) 轮正文收尾"), "第 \(round) 轮 toolCalls 使用本轮流式正文全文")
        }
        let definitions = try JSONSerialization.data(withJSONObject: backend.requests[0].tools, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        XCTAssertTrue(text.contains(String(decoding: definitions, as: UTF8.self)), "完整工具定义可见")
        var sources = CatalogSources()
        sources.addFragments([movie, bread, longFragment])
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        var parseError = ""
        XCTAssertNil(CatalogItems.parse(malformed, sources: sources, wiki: wiki) { parseError = $0 })
        XCTAssertFalse(parseError.isEmpty)
        XCTAssertTrue(text.contains(CatalogRunRecord.code(parseError)), "保留解析错误全文")
        let dropped = try XCTUnwrap(CatalogItems.parse(allDropped, sources: sources, wiki: wiki))
        for reason in dropped.dropReasons { XCTAssertTrue(text.contains(reason), "保留每条丢弃原因") }
        for fullText in [searchJSON, malformed, allDropped, accepted, modelBody, finishedBody] {
            XCTAssertTrue(text.contains(fullText), "运行记录不能使用草稿的截短正文")
        }
        XCTAssertFalse(text.contains("不是 finished 全文的流式片段"), "finished 必须使用终止事件的全文")
        XCTAssertTrue(text.contains("truncated：true"))
        XCTAssertTrue(text.contains("cost：0.0123"))
        XCTAssertTrue(text.contains("累计 toolChars：\(out.toolChars)"))
        XCTAssertTrue(text.contains("面包已有页完整记录"))
        XCTAssertTrue(text.contains(bread.id.uuidString), "解析后的 covered 保留实际碎片 ID")
        XCTAssertTrue(text.contains("一起看电影的完整记录"), "解析后的 items 保留全文")
        XCTAssertTrue(text.contains("parseError："))
        XCTAssertTrue(text.contains("dropReasons："))
        XCTAssertTrue(text.contains("isError：true"))
        for request in backend.requests {
            XCTAssertTrue(text.contains(request.system))
            for message in request.history { XCTAssertTrue(text.contains(message.content)) }
            for turn in request.toolTurns {
                for call in turn.calls { XCTAssertTrue(text.contains(call.argumentsJSON)) }
                for result in turn.results { XCTAssertTrue(text.contains(result.text), "完整记录实际回灌的回执及补充提醒") }
                for follow in turn.followUps {
                    XCTAssertTrue(text.contains(follow.reply) && text.contains(follow.note), "完整记录回执后只回的字和补的提醒")
                }
            }
        }
        let clipped = try XCTUnwrap(backend.requests[1].toolTurns.first?.results.first?.text)
        XCTAssertEqual(CatalogRunRecord.searchEvidence(in: text).reduce(0) { $0 + $1.searchedChars }, CatalogRetrieval.Limits.chars)
        XCTAssertTrue(clipped.hasSuffix(CatalogAgentTools.clipNote))
        XCTAssertTrue(text.contains(CatalogRunRecord.code(clipped)))
        XCTAssertTrue(backend.requests[2].toolTurns.last?.results.first?.text.contains("格式不对") == true)
        XCTAssertTrue(backend.requests[3].toolTurns.last?.results.first?.text.contains("输出太长被截断") == true)
        XCTAssertEqual(backend.requests[4].toolTurns.last?.followUps.map(\.reply), [finishedBody], "只回字那一轮的全文留在历史里")
        XCTAssertTrue(backend.requests[4].toolTurns.last?.followUps.last?.note.contains("你还没交") == true)
        XCTAssertFalse(backend.requests[4].toolTurns.last?.results.last?.text.contains("你还没交") == true, "提醒不拼在回执上")
        XCTAssertTrue(backend.requests[5].toolTurns.last?.results.first?.text.contains("全部被扔掉") == true)
        XCTAssertTrue(backend.requests[5].toolTurns.last?.results.last?.text.contains("轮数到顶") == true)
        MemoryWriteLog.flush()
        let entries = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { $0.run?.path == CatalogRunRecord.folderName + "/" + file.lastPathComponent }
        XCTAssertEqual(entries.count, 6)
        let links = try entries.map { try XCTUnwrap($0.run) }
        XCTAssertEqual(Set(links.map(\.path)).count, 1)
        XCTAssertEqual(Set(links.compactMap(\.anchor)).count, 6)
        for round in 1...6 {
            let entry = try XCTUnwrap(entries.first { $0.note.hasPrefix("整理「电影」第 \(round) 轮") })
            let anchor = try XCTUnwrap(entry.run?.anchor)
            XCTAssertTrue(text.contains("<a id=\"\(anchor)\"></a>\n\n## Agent「电影」第 \(round) 轮 · 系统提示与请求\n"))
        }
    }

    func testInjectedRunIsReusedByChildAgentsAndRoundLinksStayDistinct() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let record = CatalogRunRecord(wiki: wiki, topic: "同一次 session", kind: "测试 session")
        record.section("父级开场", body: "同一个运行记录")
        for topic in ["电影", "面包"] {
            let backend = FakeCatalogBackend { _, _ in
                .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[],\"reason\":\"已有页完整记录\"}")])
            }
            var input = job()
            input.topic = topic
            input.run = record
            let out = await agent(backend).run(input)
            XCTAssertEqual(out.stop, .submitted)
        }

        let files = try runFiles()
        XCTAssertEqual(files.map { $0.resolvingSymlinksInPath() }, [record.url.resolvingSymlinksInPath()], "子 agent 不另建文件")
        let text = try String(contentsOf: record.url, encoding: .utf8)
        XCTAssertTrue(text.contains("父级开场"))
        MemoryWriteLog.flush()
        let entries = MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).filter { $0.run?.path == record.relativePath }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.compactMap { $0.run?.anchor }).count, 2)
        for entry in entries {
            let topic = entry.note.contains("「电影」") ? "电影" : "面包"
            let anchor = try XCTUnwrap(entry.run?.anchor)
            XCTAssertTrue(text.contains("<a id=\"\(anchor)\"></a>\n\n## Agent「\(topic)」第 1 轮 · 系统提示与请求\n"))
        }
    }

    func testRunRecordSurvivesFailureAndRoundLimit() async throws {
        for (event, expected, ending) in [
            (AssistantBackendEvent.failed("真实错误全文"), CatalogAgent.Stop.failed("真实错误全文"), "异常：真实错误全文"),
            (.finished("没有提交的正文全文"), .gaveUp, "到顶未提交"),
        ] {
            let record = CatalogRunRecord(wiki: WikiStore(root: root.appendingPathComponent("wiki")), topic: "电影", kind: "退出测试")
            let backend = FakeCatalogBackend { _, _ in event }
            var input = job(maxRounds: 1)
            input.run = record

            let out = await agent(backend).run(input)

            XCTAssertEqual(out.stop, expected)
            let text = try String(contentsOf: record.url, encoding: .utf8)
            XCTAssertTrue(text.contains(ending), "返回前已 flush")
            XCTAssertTrue(text.contains("第 1 轮模型回复"))
        }
    }

    func testRoundCapForcesSubmitAndMarksIncomplete() async throws {
        let backend = FakeCatalogBackend { [submit] _, request in
            request.tools.count == 1 ? .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)]) : self.search()
        }

        let out = await agent(backend).run(job(maxRounds: 3))

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(out.rounds, 2, "收尾提前一轮（第 N-1 轮），最后一轮留给修订；交得干净就不再请求")
        XCTAssertEqual(backend.requests.count, 2, "总请求数不超过 N")
        XCTAssertEqual(gateCalls, 2, "收尾那次也过闸")
        XCTAssertTrue(out.incomplete)
        XCTAssertEqual(out.items.count, 1)
        let last = backend.requests[1]
        XCTAssertEqual(last.tools.count, 1, "第 N 轮只剩 submit_proposal")
        XCTAssertTrue(last.toolTurns.last?.results.last?.text.contains("轮数到顶") == true, "提醒接在最后一条工具结果后面")
    }

    func testCapReachedAndStillNoSubmitGivesUp() async {
        let backend = FakeCatalogBackend { n, _ in n <= 2 ? self.search() : .finished("我觉得够了") }

        let out = await agent(backend).run(job(maxRounds: 2))

        XCTAssertEqual(out.stop, .gaveUp)
        XCTAssertTrue(out.items.isEmpty, "一条都没交就不建提案")
        XCTAssertEqual(out.rounds, 2)
        XCTAssertEqual(backend.requests.count, 2)
        XCTAssertTrue(backend.requests[1].toolTurns.last?.results.last?.text.contains("轮数到顶") == true)
    }

    func testPlainReplyGetsReminded() async throws {
        let backend = FakeCatalogBackend { [submit] n, _ in
            n == 1 ? .finished("好的，我来整理") : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertFalse(out.incomplete, "被提醒才交的不算没整理完")
        XCTAssertEqual(backend.requests[1].history.map(\.role), ["user", "assistant", "user"])
        XCTAssertTrue(backend.requests[1].history.last?.content.contains("你还没交") == true)
    }

    /// 已有工具回合时只回了字：那段话按 assistant 留进历史、提醒另起一条 user，回执原样不拼提醒；四条线格式都一问一答交替、tool_use 配对不破
    func testPlainReplyAfterToolTurnKeptAsAssistantAndReminderIsOwnUserMessage() async throws {
        let backend = FakeCatalogBackend { [submit] n, _ in
            switch n {
            case 1: return self.search()
            case 2: return .finished("我先想想再交")
            default: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
            }
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(backend.requests.count, 3)
        let before = backend.requests[1], after = backend.requests[2]
        XCTAssertEqual(after.history.map(\.role), before.history.map(\.role), "有工具回合时回的字不进 history，接在回合后面")
        XCTAssertEqual(after.toolTurns.count, 1)
        XCTAssertEqual(after.toolTurns[0].results.map(\.text), before.toolTurns[0].results.map(\.text), "回执原样，不往上拼提醒")
        XCTAssertEqual(after.toolTurns[0].followUps.count, 1)
        let follow = try XCTUnwrap(after.toolTurns[0].followUps.first)
        XCTAssertEqual(follow.reply, "我先想想再交")
        XCTAssertTrue(follow.note.contains("你还没交"))
        let callId = after.toolTurns[0].calls[0].id

        let anthropic = AnthropicProvider.buildRequestBody(messages: after.history, model: "claude-haiku-4-5", systemPrompt: after.system,
                                                           samplingParams: nil, tools: after.tools, toolTurns: after.toolTurns)
        let messages = try XCTUnwrap(anthropic["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user"])
        let blocks = messages.map { $0["content"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(blocks[1].compactMap { $0["type"] as? String == "tool_use" ? $0["id"] as? String : nil }, [callId])
        XCTAssertEqual(blocks[2].compactMap { $0["tool_use_id"] as? String }, [callId], "tool_use 后面紧跟它的 tool_result")
        XCTAssertEqual(blocks[3].map { $0["text"] as? String }, ["我先想想再交"])
        XCTAssertEqual(blocks[4].map { $0["text"] as? String }, [follow.note])

        let openai = OpenAICompatibleProvider.buildRequestBody(messages: after.history, model: "m", systemPrompt: after.system,
                                                              samplingParams: nil, tools: after.tools, toolTurns: after.toolTurns)
        let wire = try XCTUnwrap(openai["messages"] as? [[String: Any]])
        XCTAssertEqual(wire.compactMap { $0["role"] as? String }, ["system", "user", "assistant", "tool", "assistant", "user"])
        XCTAssertEqual(wire[3]["tool_call_id"] as? String, callId)
        XCTAssertEqual(wire[4]["content"] as? String, "我先想想再交")
        XCTAssertEqual(wire[5]["content"] as? String, follow.note)

        let codex = ChatGPTOAuthProvider.buildRequestBody(messages: after.history, model: "m", systemPrompt: after.system,
                                                          samplingParams: nil, tools: after.tools, toolTurns: after.toolTurns)
        let input = try XCTUnwrap(codex["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { ($0["type"] as? String) ?? ($0["role"] as? String) ?? "" },
                       ["user", "function_call", "function_call_output", "assistant", "user"])

        XCTAssertEqual(LocalLLMService.chat(for: after).map { "\($0.role)" }, ["system", "user", "assistant", "tool", "assistant", "user"])
    }

    /// 没回字（空）的提醒：Anthropic 并进上一条 user（tool_result 后面跟一个 text 块），仍然交替；工具回合刚收完的收尾提醒照旧接在新回合最后一条结果后面、只接一次
    func testRemindShapes() throws {
        let call = ToolCallBlock(id: "c1", name: "read", argumentsJSON: "{}")
        var history: [(role: String, content: String)] = [(role: "user", content: "开场")]
        var turns = [ToolTurn(calls: [call], results: [ToolResultBlock(toolUseId: "c1", text: "原料", isError: false)])]
        CatalogAgent.remind("提醒一", history: &history, turns: &turns, reply: "")
        CatalogAgent.remind("提醒二", history: &history, turns: &turns, reply: "想想")
        XCTAssertEqual(turns[0].results[0].text, "原料")
        XCTAssertEqual(turns[0].followUps, [ToolFollowUp(reply: "", note: "提醒一"), ToolFollowUp(reply: "想想", note: "提醒二")])
        XCTAssertEqual(history.count, 1)
        let body = AnthropicProvider.buildRequestBody(messages: history, model: "claude-haiku-4-5", systemPrompt: nil, samplingParams: nil, toolTurns: turns)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual((messages[2]["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String }, ["tool_result", "text"])
        let openai = try XCTUnwrap(OpenAICompatibleProvider.buildRequestBody(messages: history, model: "m", systemPrompt: nil, samplingParams: nil,
                                                                             toolTurns: turns)["messages"] as? [[String: Any]])
        XCTAssertEqual(openai.compactMap { $0["role"] as? String }, ["user", "assistant", "tool", "user", "assistant", "user"])

        var fresh = [ToolTurn(calls: [call], results: [ToolResultBlock(toolUseId: "c1", text: "原料", isError: false)])]
        CatalogAgent.remind("收尾", history: &history, turns: &fresh, reply: nil)
        XCTAssertEqual(fresh[0].results[0].text, "原料\n\n收尾")
        XCTAssertTrue(fresh[0].followUps.isEmpty)
        CatalogAgent.remind("再收尾", history: &history, turns: &fresh, reply: nil)
        XCTAssertEqual(fresh[0].results[0].text, "原料\n\n收尾", "同一回合连调两次 nil 不叠第二条")
        XCTAssertTrue(fresh[0].followUps.isEmpty)
        XCTAssertEqual(history.count, 1)
        CatalogAgent.remind("又说了话", history: &history, turns: &fresh, reply: "嗯")
        XCTAssertEqual(fresh[0].results[0].text, "原料\n\n收尾", "同一条回执上不叠第二条提醒")
        XCTAssertEqual(fresh[0].followUps, [ToolFollowUp(reply: "嗯", note: "又说了话")])

        var none: [ToolTurn] = []
        var opening: [(role: String, content: String)] = [(role: "user", content: "开场")]
        CatalogAgent.remind("交", history: &opening, turns: &none, reply: "好的")
        XCTAssertEqual(opening.map(\.role), ["user", "assistant", "user"], "还没有工具回合：照旧进 history")
    }

    /// astra P3：签名 thinking / redacted → 两条工具回执 → 有字 / 空字 followUps → 下一工具回合，开缓存：第二次请求里第一次的消息逐字节是前缀
    /// （只有挪走的 cache_control 归一化），签名块、调用 id、回执正文原样
    func testCachePrefixStableAcrossSignedThinkingFollowUpsAndNextToolRound() throws {
        func use(_ id: String, _ path: String) -> [String: Any] { ["type": "tool_use", "id": id, "name": "read", "input": ["path": path]] }
        var first = ToolTurn(calls: [ToolCallBlock(id: "c1", name: "read", argumentsJSON: #"{"path":"a"}"#),
                                     ToolCallBlock(id: "c2", name: "read", argumentsJSON: #"{"path":"b"}"#)],
                             results: [ToolResultBlock(toolUseId: "c1", text: "原料 a", isError: false),
                                       ToolResultBlock(toolUseId: "c2", text: "原料 b", isError: true)],
                             assistantContent: [["type": "thinking", "thinking": "先读两份再说", "signature": "sig_first_round"],
                                                ["type": "redacted_thinking", "data": "red_payload_1"],
                                                ["type": "text", "text": "我读两份"], use("c1", "a"), use("c2", "b")], thinkingTokens: 30)
        first.text = "我读两份"
        first.followUps = [ToolFollowUp(reply: "我想想", note: "提醒一"), ToolFollowUp(reply: "", note: "提醒二")]
        let second = ToolTurn(calls: [ToolCallBlock(id: "c3", name: "read", argumentsJSON: #"{"path":"c"}"#)],
                              results: [ToolResultBlock(toolUseId: "c3", text: "原料 c", isError: false)],
                              assistantContent: [["type": "thinking", "thinking": "再读一份", "signature": "sig_second_round"], use("c3", "c")], thinkingTokens: 8)
        var sampling = SamplingParams()
        sampling.cacheFriendly = true
        sampling.reasoningEffort = "medium"
        let history = [(role: "user", content: "开场")]
        func body(_ turns: [ToolTurn]) throws -> (body: [String: Any], messages: [[String: Any]]) {
            let b = AnthropicProvider.buildRequestBody(messages: history, model: "claude-sonnet-4-5", systemPrompt: "系统", samplingParams: sampling,
                                                        tools: CatalogAgentTools.definitions(submitOnly: false), toolTurns: turns)
            return (b, try XCTUnwrap(b["messages"] as? [[String: Any]]))
        }
        func text(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
        }
        func stripped(_ m: [String: Any]) throws -> String {
            var msg = m
            msg["content"] = (m["content"] as? [[String: Any]])?.map { var b = $0; b.removeValue(forKey: "cache_control"); return b }
            return try text(msg)
        }

        let one = try body([first]), two = try body([first, second])

        XCTAssertNotNil(one.body["thinking"], "开了思考")
        for key in ["system", "tools", "thinking", "model"] {
            XCTAssertEqual(try one.body[key].map(text), try two.body[key].map(text), "顶层 \(key) 两次不同")
        }
        XCTAssertEqual(one.messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual(two.messages.count, one.messages.count + 2)
        let marked = try XCTUnwrap(one.messages.lastIndex { $0["role"] as? String == "assistant" })
        XCTAssertEqual(marked, 3, "第一次的缓存标在有字那条 assistant 上")
        for i in 0..<one.messages.count {
            if i == marked {
                XCTAssertNotNil((one.messages[i]["content"] as? [[String: Any]])?.last?["cache_control"])
                XCTAssertNil((two.messages[i]["content"] as? [[String: Any]])?.last?["cache_control"], "第二次挪到新一轮")
                XCTAssertEqual(try stripped(one.messages[i]), try stripped(two.messages[i]), "断点那条只差挪走的 cache_control")
            } else {
                XCTAssertEqual(try text(one.messages[i]), try text(two.messages[i]), "第 \(i) 条消息两次不同")
            }
        }
        let blocks = try XCTUnwrap(two.messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["thinking", "redacted_thinking", "text", "tool_use", "tool_use"])
        XCTAssertEqual(blocks[0]["signature"] as? String, "sig_first_round")
        XCTAssertEqual(blocks[1]["data"] as? String, "red_payload_1")
        XCTAssertEqual(blocks.compactMap { $0["id"] as? String }, ["c1", "c2"])
        let results = try XCTUnwrap(two.messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["tool_use_id"] as? String }, ["c1", "c2"])
        XCTAssertEqual(results.map { $0["content"] as? String }, ["原料 a", "原料 b"])
        XCTAssertEqual(results[1]["is_error"] as? Bool, true)
        XCTAssertEqual((two.messages[3]["content"] as? [[String: Any]])?.map { $0["text"] as? String }, ["我想想"])
        XCTAssertEqual((two.messages[4]["content"] as? [[String: Any]])?.map { $0["text"] as? String }, ["提醒一", "提醒二"], "空字的提醒并进这条 user")
        let next = try XCTUnwrap(two.messages[5]["content"] as? [[String: Any]])
        XCTAssertEqual(next.first?["signature"] as? String, "sig_second_round")
        XCTAssertEqual(next.last?["id"] as? String, "c3")
        XCTAssertNotNil(next.last?["cache_control"], "标挪到新一轮最后一个非思考块上，思考块不挂")
        XCTAssertNil(next.first?["cache_control"])
        XCTAssertEqual((two.messages[6]["content"] as? [[String: Any]])?.map { $0["tool_use_id"] as? String }, ["c3"])
    }

    func testBadSubmitFormatGetsAnotherRound() async throws {
        let backend = FakeCatalogBackend { [submit] n, _ in
            .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 1 ? "{\"pages\":[]}" : submit)])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.rounds, 2)
        XCTAssertEqual(out.items.count, 1)
        XCTAssertTrue(backend.requests[1].toolTurns[0].results[0].isError)
    }

    func testEmptyWithoutReasonRetriesAfterSearching() async {
        let backend = FakeCatalogBackend { [submit] n, _ in
            if n == 1 { return self.search() }
            return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 2 ? "{\"items\":[],\"reason\":\" \\n \"}" : submit)])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(out.rounds, 3)
        let retry = backend.requests[2].toolTurns.last?.results.first
        XCTAssertEqual(retry?.text, "你交了空的。如果查到的东西里确实没有值得进 wiki 的，用 reason 说明为什么；否则把查到的写成条目重交。")
        XCTAssertEqual(retry?.isError, true)
    }

    func testEmptyWithReasonEndsAndLogsReasonAndDraft() async throws {
        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? self.search() : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[],\"reason\":\"  已有页已完整记录  \"}")])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertEqual(backend.requests.count, 2)
        MemoryWriteLog.flush()
        let note = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first { $0.note.contains("交了 0 条：已有页已完整记录") }?.note)
        let files = try draftFiles()
        XCTAssertTrue(files.contains { note.contains($0.lastPathComponent) })
    }

    func testEmptyBeforeAnyToolResultsEndsWithoutRetry() async {
        let backend = FakeCatalogBackend { _, _ in .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[]}")]) }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertEqual(backend.requests.count, 1)
    }

    private let allDropped = """
    {"items":[{"type":"new_page","path":"其他/电影","kind":"事","title":"电影","records":[{"text":"没出处的记录"}]}]}
    """

    func testAllDroppedReturnsEveryParseReasonThenAcceptsRepair() async throws {
        let backend = FakeCatalogBackend { [submit, allDropped] n, _ in
            .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 1 ? allDropped : submit)])
        }
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        var sources = CatalogSources()
        sources.addFragments([movie, bread])
        let expected = try XCTUnwrap(CatalogItems.parse(allDropped, sources: sources, wiki: wiki))
        XCTAssertFalse(expected.dropReasons.isEmpty)

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(out.rounds, 2)
        let result = try XCTUnwrap(backend.requests[1].toolTurns.first?.results.first)
        XCTAssertTrue(result.isError)
        for reason in expected.dropReasons {
            XCTAssertTrue(result.text.contains(WikiStore.shown(reason, user: CatalogTestKit.names.user)), result.text)
        }
    }

    private let listy = """
    {"items":[{"type":"new_page","path":"事/电影","kind":"事","title":"电影","hook":"当她提到电影时先看这页","now":"- 在追科幻片（自 2026-10 起）",
      "records":[{"text":"2026-10-12 一起看了《星际穿越》","fragments":["f1"]}]}]}
    """

    /// 第 9 段：没过检查给一次重写（回执说哪项、在哪儿）；重写过了不留标记，还不过照样交、标明「重写了一次，还有没过的」
    func testHardCheckGetsOneRewriteThenFlagsStayIfStillFailing() async throws {
        let fixed = listy.replacingOccurrences(of: "\"- 在追科幻片（自 2026-10 起）\"", with: "\"在追科幻片（自 2026-10 起）。\"")
        XCTAssertNotEqual(fixed, listy)
        for (second, flagged) in [(fixed, false), (listy, true)] {
            let backend = FakeCatalogBackend { [listy] n, _ in .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 1 ? listy : second)]) }
            let out = await agent(backend).run(job())
            XCTAssertEqual(out.stop, .submitted)
            XCTAssertEqual(out.rounds, 2, "只给一次重写")
            let result = try XCTUnwrap(backend.requests[1].toolTurns.first?.results.first)
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.text.contains("items[0] 事/电影：") && result.text.contains("「- 在追科幻片（自 2026-10 起）」"), result.text)
            let item = try XCTUnwrap(out.items.first)
            XCTAssertEqual(item.checks?.isEmpty == false, flagged)
            XCTAssertEqual(out.revision, flagged ? "重写一次后仍有没过的" : "重写一次后通过")
            guard case .newPage(let page) = item.change else { return XCTFail() }
            XCTAssertEqual(page.now.hasPrefix("- "), flagged, "不改模型交的字")
        }
    }

    /// 修订用不了（出错 / 被预算拦下 / 交坏 / 截断 / 交上来的全被扔掉）都交第一稿，写明原因；不再多要一次。被拦照样往上报「被拦」
    func testUnusableRevisionDeliversTheFirstDraft() async throws {
        let cases: [(name: String, reply: AssistantBackendEvent, block: String?, revision: String)] = [
            ("出错", .failed("服务商 503"), nil, "那轮出错（服务商 503）"),
            ("被拦", .finished("不该到这"), "写入预算用完", "那轮被预算拦下（写入预算用完）"),
            ("交坏", .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "坏 JSON")]), nil, "那次格式不对"),
            ("截断", .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[", truncated: true)]), nil, "那次输出被截断"),
            ("交空", .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, allDropped)]), nil, "那次交的没有能用的内容"),
        ]
        for c in cases {
            let backend = FakeCatalogBackend { [listy] n, _ in n == 1 ? .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, listy)]) : c.reply }
            let base = gateCalls
            let out = await agent(backend, block: { n in n == base + 2 ? c.block : nil }).run(job())
            XCTAssertEqual(out.stop, c.block.map { .blocked($0) } ?? .submitted, c.name)
            XCTAssertLessThanOrEqual(backend.requests.count, 2, c.name)
            XCTAssertEqual(out.items.count, 1, c.name)
            XCTAssertTrue(out.items.first?.checks?.isEmpty == false, c.name)
            XCTAssertTrue(out.revision?.contains(c.revision) == true && out.revision?.hasSuffix("交的是第一稿") == true, "\(c.name)：\(out.revision ?? "nil")")
        }
    }

    /// 收不进页的内容和没过检查共用同一次修订：凑不出第三次提交
    func testUnappliedAndHardChecksShareOneRevision() async throws {
        let unknown = "{\"items\":[{\"type\":\"rewrite_records\",\"path\":\"事/电影\"}]}"
        let backend = FakeCatalogBackend { [listy] n, _ in .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 1 ? unknown : listy)]) }
        let out = await agent(backend).run(job())
        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(backend.requests.count, 2)
        XCTAssertTrue(backend.requests[1].toolTurns[0].results[0].text.contains("不支持的条目类型：rewrite_records"))
        XCTAssertTrue(out.items.first?.checks?.isEmpty == false)
        XCTAssertEqual(out.revision, "重写一次后仍有没过的")
    }

    /// 两次都只交了收不进页的内容：修订用完就交，不再要第三次
    func testUnappliedOnlyTwiceIsDeliveredWithoutAThirdRequest() async throws {
        let unknown = "{\"items\":[{\"type\":\"rewrite_records\",\"path\":\"事/电影\"}]}"
        let backend = FakeCatalogBackend { n, _ in n == 1 ? self.search() : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, unknown)]) }
        let out = await agent(backend).run(job())
        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(backend.requests.count, 3, "搜一次、交一次、修订一次")
        XCTAssertEqual(out.items, [])
        XCTAssertEqual(out.unapplied.map(\.page), ["事/电影"])
        XCTAssertEqual(out.revision, "重写一次后仍有没过的")
    }

    /// 十轮上限之内给修订留位置：收尾提前一轮，最后一轮还能修订
    func testRoundCapLeavesTheLastRoundForTheRevision() async throws {
        let fixed = listy.replacingOccurrences(of: "\"- 在追科幻片（自 2026-10 起）\"", with: "\"在追科幻片（自 2026-10 起）。\"")
        let backend = FakeCatalogBackend { [listy] n, request in
            request.tools.count == 1 ? .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 2 ? listy : fixed)]) : self.search()
        }
        let out = await agent(backend).run(job(maxRounds: 3))
        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(backend.requests.count, 3, "第 2 轮收尾交了没过的，第 3 轮修订")
        XCTAssertEqual(backend.requests[1].tools.count, 1)
        XCTAssertNil(out.items.first?.checks)
        XCTAssertEqual(out.revision, "重写一次后通过")
    }

    func testUnconsumedFieldReasonIsFedBackThenRepairAccepted() async throws {
        let bad = """
        {"items":[{"type":"new_page","path":"事/电影","title":"电影","judgment":"共存"}]}
        """
        let backend = FakeCatalogBackend { [submit, bad] n, _ in
            .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 1 ? bad : submit)])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(out.rounds, 2)
        let result = try XCTUnwrap(backend.requests[1].toolTurns.first?.results.first)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("type=new_page 不收 judgment 字段，改用 append / rewrite_now / link"), result.text)
    }

    func testTruncatedValidJSONIsNotAcceptedAndRetries() async {
        let backend = FakeCatalogBackend { [submit] n, _ in
            .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit, truncated: n == 1)])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(out.rounds, 2)
        XCTAssertEqual(backend.requests[1].toolTurns.first?.results.first?.text, "输出太长被截断了：少写几条（比如先交最重要的一两页），或者把记录写短")
        XCTAssertEqual(backend.requests[1].toolTurns.first?.results.first?.isError, true)
    }

    func testRepeatedTruncationStopsAtNWithoutAcceptingValidJSON() async throws {
        let backend = FakeCatalogBackend { [submit] _, _ in
            .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit, truncated: true)])
        }

        let out = await agent(backend).run(job(maxRounds: 3))

        XCTAssertEqual(out.stop, .gaveUp)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertEqual(out.rounds, 3)
        XCTAssertEqual(backend.requests.count, 3)
        XCTAssertEqual(try draftFiles().count, 3)
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.note.contains("最后一轮输出被截断") })
    }

    func testRejectedSubmitsAtRoundLimitNeverRequestAgain() async {
        let cases: [(String, Bool, CatalogAgent.Stop)] = [
            ("{\"items\":[]}", false, .submitted),
            (allDropped, false, .submitted),
            (submit, true, .gaveUp),
            ("坏 JSON", false, .gaveUp),
        ]
        for (raw, truncated, expected) in cases {
            let backend = FakeCatalogBackend { n, _ in
                n == 1 ? self.search() : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, raw, truncated: truncated)])
            }

            let out = await agent(backend).run(job(maxRounds: 2))

            XCTAssertEqual(out.stop, expected)
            XCTAssertTrue(out.items.isEmpty)
            XCTAssertEqual(out.rounds, 2)
            XCTAssertEqual(backend.requests.count, 2)
        }
    }

    func testLastRoundEmptySubmissionClosesAsSubmitted() async {
        let backend = FakeCatalogBackend { [submit] n, _ in
            switch n {
            case 1: return self.search()
            case 2: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[]}")])
            default: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
            }
        }

        let out = await agent(backend).run(job(maxRounds: 2))

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertEqual(out.rounds, 2)
        XCTAssertEqual(backend.requests.count, 2)
    }

    func testCoveredOnlyEmptySubmissionIsLegal() async {
        let backend = FakeCatalogBackend { [submit] n, _ in
            switch n {
            case 1: return self.search()
            case 2: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[],\"covered\":[\"f1\"]}")])
            default: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
            }
        }

        let out = await agent(backend).run(job(maxRounds: 4))

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(out.covered, [movie.id])
        XCTAssertEqual(out.rounds, 2)
        XCTAssertEqual(backend.requests.count, 2)
    }

    func testEmptyRepairStillAllowedAfterNoSubmitReminder() async {
        let backend = FakeCatalogBackend { [submit] n, _ in
            switch n {
            case 1: return self.search()
            case 2: return .finished("准备交")
            case 3: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[]}")])
            default: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
            }
        }

        let out = await agent(backend).run(job(maxRounds: 6))

        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(backend.requests.count, 4)
        XCTAssertEqual(backend.requests[3].tools.count, 1)
        XCTAssertTrue(backend.requests[3].toolTurns.last?.results.first?.text.contains("你交了空的") == true)
    }

    func testRepeatedEmptyOnlyGetsOneRepair() async {
        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? self.search() : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[]}")])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertEqual(backend.requests.count, 3)
    }

    func testRepeatedAllDroppedOnlyGetsOneRepair() async {
        let backend = FakeCatalogBackend { [allDropped] _, _ in
            .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, allDropped)])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertGreaterThan(out.dropped, 0)
        XCTAssertEqual(backend.requests.count, 2)
    }

    func testEmptyAndAllDroppedHaveIndependentRepairAllowance() async {
        let backend = FakeCatalogBackend { [submit, allDropped] n, _ in
            switch n {
            case 1: return self.search()
            case 2: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[]}")])
            case 3: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, allDropped)])
            default: return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
            }
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(backend.requests.count, 4)
        XCTAssertTrue(backend.requests[2].toolTurns.last?.results.first?.text.contains("你交了空的") == true)
        XCTAssertTrue(backend.requests[3].toolTurns.last?.results.first?.text.contains("全部被扔掉") == true)
    }

    /// 第 9 段：每一页最多修订一次——全部被扔打回过一次，之后交空就到此为止，不再要第三次
    func testAfterTheRevisionAnEmptySubmissionIsFinal() async {
        let backend = FakeCatalogBackend { [allDropped] n, _ in
            if n == 1 { return self.search() }
            return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 3 ? "{\"items\":[]}" : allDropped)])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertEqual(backend.requests.count, 3)
    }

    func testEmptyAllowanceIsNotResetByAllDroppedRepair() async {
        let backend = FakeCatalogBackend { [allDropped] n, _ in
            if n == 1 { return self.search() }
            return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, n == 3 ? allDropped : "{\"items\":[]}")])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertTrue(out.items.isEmpty)
        XCTAssertEqual(out.dropped, 0)
        XCTAssertEqual(backend.requests.count, 4)
    }

    private func draftFiles() throws -> [URL] {
        let folder = CatalogDrafts.folder(WikiStore(root: root.appendingPathComponent("wiki")))
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEverySubmitSavesRawAndTokenBodyWithoutSameRoundOverwrite() async throws {
        let backend = FakeCatalogBackend { [submit, allDropped] _, _ in
            .toolCalls([
                CatalogTestKit.call(CatalogAgentTools.submit, ""),
                CatalogTestKit.call(CatalogAgentTools.submit, "坏 JSON"),
                CatalogTestKit.call(CatalogAgentTools.submit, submit, truncated: true),
                CatalogTestKit.call(CatalogAgentTools.submit, allDropped),
                CatalogTestKit.call(CatalogAgentTools.submit, "{\"items\":[],\"reason\":\"已有页都写过了\"}"),
                CatalogTestKit.call(CatalogAgentTools.submit, submit),
            ])
        }
        backend.tokens = { _ in ["查到的正文", "第二段"] }
        var input = job(maxRounds: 1)
        input.topic = String(repeating: "长主题", count: 20) + "/不能进文件名"

        let out = await agent(backend).run(input)

        XCTAssertEqual(out.items.count, 1)
        let files = try draftFiles()
        XCTAssertEqual(files.count, 6)
        XCTAssertEqual(Set(files.map { $0.lastPathComponent.components(separatedBy: "-" + CatalogDrafts.safeName(input.topic)).first ?? "" }).count, 1, "同一次 run 共用草稿前缀")
        XCTAssertTrue(files.allSatisfy { $0.lastPathComponent.contains("-\(CatalogDrafts.safeName(input.topic))-submit-1") })
        let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(contents.allSatisfy { $0.contains("查到的正文第二段") })
        XCTAssertTrue(contents.contains { $0.contains("坏 JSON") })
        XCTAssertTrue(contents.contains { $0.contains(allDropped) })
        XCTAssertTrue(contents.contains { $0.contains(submit) })
        XCTAssertTrue(contents.contains { $0.contains("已有页都写过了") })
        XCTAssertTrue(contents.allSatisfy { $0.contains("argumentsJSON：") && $0.contains("正文：") && $0.contains("truncated：") })
        let truncated = try XCTUnwrap(contents.first { $0.contains("truncated：true") })
        XCTAssertTrue(truncated.contains("解析结果：跳过（truncated=true）"))
        XCTAssertTrue(truncated.contains("items：未知"))
        let malformed = try XCTUnwrap(contents.first { $0.contains("坏 JSON") })
        XCTAssertTrue(malformed.contains("解析结果：格式不合格"))
        let empty = try XCTUnwrap(contents.first { $0.contains("reason：已有页都写过了") })
        XCTAssertTrue(empty.contains("items：0\ndropped：0"))
        let successful = try XCTUnwrap(contents.first { $0.contains("truncated：false") && $0.contains("items：1") })
        XCTAssertTrue(successful.contains("dropped：1"))
        let rejected = try XCTUnwrap(contents.first { $0.contains(allDropped) })
        var sources = CatalogSources()
        sources.addFragments([movie, bread])
        let parsed = try XCTUnwrap(CatalogItems.parse(allDropped, sources: sources, wiki: WikiStore(root: root.appendingPathComponent("wiki"))))
        XCTAssertTrue(rejected.contains("items：0\ndropped：\(parsed.dropped)"))
        for reason in parsed.dropReasons { XCTAssertTrue(rejected.contains(reason), rejected) }
        MemoryWriteLog.flush()
        let note = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first { $0.note.contains("第 1 轮：") }?.note)
        for file in files { XCTAssertTrue(note.contains(file.lastPathComponent), note) }
    }

    func testOversizedRawSubmitIsBoundedInDraft() async throws {
        let raw = "原始参数开头" + String(repeating: "x", count: 21_000) + "原始参数尾部"
        let backend = FakeCatalogBackend { _, _ in .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, raw)]) }

        let out = await agent(backend).run(job(maxRounds: 1))

        XCTAssertEqual(out.stop, .gaveUp)
        let file = try XCTUnwrap(try draftFiles().first)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(String(raw.prefix(20_000))))
        XCTAssertFalse(text.contains("原始参数尾部"))
        XCTAssertLessThan(text.count, 21_000, "参数只保留前 20000 字，报告头尾不应再保留整份 raw")
        XCTAssertTrue(text.contains("【argumentsJSON 超过 20000 字符，已截断】"))
    }

    func testFeedbackBudgetStillHoldsWithManyCallsAndSubmitRepairs() async {
        let unknown = String(repeating: "不存在", count: 20)
        let backend = FakeCatalogBackend { [submit] n, _ in
            if n == 1 {
                return .toolCalls((0..<1000).map { CatalogTestKit.call(unknown, "{}", id: "unknown-\($0)") })
            }
            return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit, truncated: n == 2)])
        }

        let out = await agent(backend).run(job(maxRounds: 4))

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertEqual(out.items.count, 1)
        XCTAssertEqual(backend.requests.count, 3, "字数封顶后截断仍不能当正常提案接收")
        XCTAssertTrue(out.incomplete)
        XCTAssertLessThanOrEqual(out.toolChars, CatalogAgent.maxToolChars)
        XCTAssertEqual(backend.requests[1].tools.count, 1)
        XCTAssertEqual(backend.requests[2].tools.count, 1)
        for request in backend.requests {
            let fed = request.toolTurns.flatMap(\.results).reduce(0) { $0 + $1.text.count }
            XCTAssertLessThanOrEqual(fed, CatalogAgent.maxToolChars)
        }
    }

    func testBudgetBlockStopsBeforeRequest() async throws {
        let backend = FakeCatalogBackend { _, _ in self.search() }

        let out = await agent(backend, block: { $0 >= 2 ? "写入预算用完" : nil }).run(job())

        XCTAssertEqual(out.stop, .blocked("写入预算用完"))
        XCTAssertEqual(backend.requests.count, 1, "被拦的那一轮不发请求")
        XCTAssertTrue(out.items.isEmpty)

        let drafts = CatalogDrafts.folder(WikiStore(root: root.appendingPathComponent("wiki")))
        let names = try FileManager.default.contentsOfDirectory(atPath: drafts.path)
        let draft = try XCTUnwrap(names.first { $0.hasSuffix("电影-被拦.txt") }, "\(names)")
        let text = try String(contentsOf: drafts.appendingPathComponent(draft), encoding: .utf8)
        XCTAssertTrue(text.contains("第 2 轮被预算拦下（写入预算用完）"))
        XCTAssertTrue(text.contains("- search_fragments「电影」 · 参数 {\"terms\":[\"电影\"]} · 回 "), text)
        XCTAssertFalse(text.contains("一起看了电影"), "只记工具名、参数、字数，不存全文")
        MemoryWriteLog.flush()
        XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.note.hasPrefix("整理「电影」被预算拦下，第 2 轮") })
        let runFile = try XCTUnwrap(try runFiles().first)
        let runText = try String(contentsOf: runFile, encoding: .utf8)
        XCTAssertTrue(runText.contains("一起看了电影"), "被拦记录仍保留上一轮工具返回全文")
        let blockedEntry = try XCTUnwrap(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).first { $0.note.hasPrefix("整理「电影」被预算拦下，第 2 轮") })
        XCTAssertEqual(blockedEntry.run?.path, CatalogRunRecord.folderName + "/" + runFile.lastPathComponent)
        let anchor = try XCTUnwrap(blockedEntry.run?.anchor)
        XCTAssertTrue(runText.contains("<a id=\"\(anchor)\"></a>\n\n## Agent「电影」第 2 轮 · 系统提示与请求\n"))
    }

    /// astra 10-16 #1：read_wiki 读到的版本当基线；没读过的页用开工时那一版
    func testBaseVersionIsWhatTheAgentSaw() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let read = try wiki.save(WikiPage(path: "人/小慧", kind: .person, triggers: ["小慧"], hook: "h", title: "小慧"))
        let unread = try wiki.save(WikiPage(path: "人/阿杰", kind: .person, triggers: ["阿杰"], hook: "h", title: "阿杰"))
        let backend = FakeCatalogBackend { n, _ in
            if n == 1 { return .toolCalls([CatalogTestKit.call("read_wiki", "{\"path\":\"人/小慧\"}")]) }
            for path in ["人/小慧", "人/阿杰"] {
                var page = wiki.read(path)!
                page.now = "她手改了"
                _ = try? wiki.saveRaw(page.markdown, path: path)
            }
            return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, """
            {"items":[{"type":"append","path":"人/小慧","records":[{"text":"2026-10-12 一起看电影","fragments":["f1"]}]},
                      {"type":"retag","path":"人/阿杰","hook":"新钩子"}]}
            """)])
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.items.map(\.baseVersion), [read, unread])
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let store = WikiProposalStore(wiki: wiki)
        let p = WikiProposal(origin: .topic, createdAt: Date(), items: out.items)
        try store.save(p)
        let approved = try await WikiProposalReview.approve(p.id, store: store, profileId: pid, context: ModelContext(container))
        XCTAssertEqual(approved.items.map(\.state), [.stale, .stale], "生成期间页被改过：页已变")
    }

    func testToolCharsCapForcesSubmit() async throws {
        let cats = (0..<100).map { _ in CatalogFragment(id: UUID(), content: "nebula " + String(repeating: "喵", count: 1000), category: "fact", day: "2026-10-12") }
        let backend = FakeCatalogBackend { [submit] _, request in
            request.tools.count == 1 ? .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)]) : self.search("nebula")
        }

        let out = await agent(backend).run(job(snapshot: [movie, bread] + cats, maxRounds: 20))

        XCTAssertEqual(out.stop, .submitted)
        XCTAssertTrue(out.incomplete)
        XCTAssertLessThanOrEqual(out.toolChars, CatalogAgent.maxToolChars, "不超额（astra #8）")
        XCTAssertTrue(backend.requests[1].toolTurns[0].results[0].text.hasSuffix(CatalogAgentTools.clipNote))
        let final = try XCTUnwrap(backend.requests.last)
        let first = final.toolTurns[0].results[0].text
        let last = try XCTUnwrap(final.toolTurns.last?.results.last?.text)
        XCTAssertLessThan(last.count, first.count, "最后一次搜索按累计剩余额度截断")
        XCTAssertTrue(last.contains("字数到顶"))
        XCTAssertEqual(final.tools.count, 1, "到累计上限后只能交提案")
        let fed = final.toolTurns.flatMap(\.results).reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(fed, CatalogAgent.maxToolChars, "实际回灌的全部文本（结果 + 提醒）不超额")
    }

    func testCancelStopsWithoutMoreRequests() async throws {
        let backend = FakeCatalogBackend { n, _ in n == 1 ? self.search() : nil }
        let a = agent(backend)
        let run = Task { await a.run(job()) }
        for _ in 0..<200 where backend.requests.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(backend.requests.count, 2)

        a.cancel()
        let out = await run.value

        XCTAssertEqual(out.stop, .cancelled)
        XCTAssertTrue(backend.cancelled)
        XCTAssertEqual(backend.requests.count, 2)
        XCTAssertEqual(gateCalls, 2)
        let runFile = try XCTUnwrap(try runFiles().first)
        let text = try String(contentsOf: runFile, encoding: .utf8)
        XCTAssertTrue(text.contains("一起看了电影"))
        XCTAssertTrue(text.contains("第 2 轮 · 系统提示与请求"))
    }

    func testToolsReadOnlyErrors() async throws {
        let tools = CatalogAgentTools(wiki: WikiStore(root: root.appendingPathComponent("wiki")), memoryRoot: root, fragments: [movie],
                                      embedder: CatalogFakeEmbedder.unavailable())
        let noPage = await tools.execute(name: "read_wiki", argumentsJSON: "{\"path\":\"人/谁\"}", now: Date())
        XCTAssertTrue(noPage.isError)
        let noLayer = await tools.execute(name: "list_wiki", argumentsJSON: "{\"path\":\"主题/没有\"}", now: Date())
        XCTAssertTrue(noLayer.isError)
        let noWindow = await tools.execute(name: "read_aline", argumentsJSON: "{\"window\":\"ffffffff\"}", now: Date())
        XCTAssertTrue(noWindow.isError)
        let bad = await tools.execute(name: "write_wiki", argumentsJSON: "{}", now: Date())
        XCTAssertTrue(bad.isError, "没有写工具")
        let empty = await tools.execute(name: "search_fragments", argumentsJSON: "{\"terms\":[\"火山岩\"]}", now: Date())
        XCTAssertFalse(empty.isError)
        XCTAssertEqual(empty.receipt?.evidence().fragments, [])
        XCTAssertEqual(CatalogAgentTools.definitions(submitOnly: false).count, 6)
    }

    func testCatalogAnthropicRequestUsesEndpointToolSchema() async throws {
        let body = try await cloudBody(type: .anthropic, catalog: true)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let definitions = CatalogAgentTools.definitions(submitOnly: false)
        XCTAssertEqual(tools.count, definitions.count)
        for (tool, definition) in zip(tools, definitions) {
            let function = try XCTUnwrap(definition["function"] as? [String: Any])
            XCTAssertNil(tool["type"])
            XCTAssertNil(tool["function"])
            XCTAssertEqual(tool["name"] as? String, function["name"] as? String)
            XCTAssertEqual(tool["description"] as? String, function["description"] as? String)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(tool["input_schema"]), options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: XCTUnwrap(function["parameters"]), options: .sortedKeys))
        }
    }

    func testCatalogOpenAIRequestKeepsFunctionSchema() async throws {
        let body = try await cloudBody(type: .openaiCompatible, catalog: true)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(body["tools"]), options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: CatalogAgentTools.definitions(submitOnly: false), options: .sortedKeys))
    }

    func testAssistantAnthropicRequestUsesEndpointToolSchema() async throws {
        let body = try await cloudBody(type: .anthropic, catalog: false)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AssistantTools.definitions.count)
        for (tool, definition) in zip(tools, AssistantTools.definitions) {
            let function = try XCTUnwrap(definition["function"] as? [String: Any])
            XCTAssertNil(tool["type"])
            XCTAssertEqual(tool["name"] as? String, function["name"] as? String)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(tool["input_schema"]), options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: XCTUnwrap(function["parameters"]), options: .sortedKeys))
        }
    }

    func testAnthropicNativeToolsRemainUnchanged() throws {
        let native: [[String: Any]] = [
            ["name": "read", "description": "读", "input_schema": ["type": "object", "properties": [:]],
             "cache_control": ["type": "ephemeral"]],
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]
        ]
        let body = AnthropicProvider.buildRequestBody(messages: [("user", "电影")], model: "claude-sonnet-4-6",
                                                       systemPrompt: nil, samplingParams: nil, tools: native)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(body["tools"]), options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: native, options: .sortedKeys))
    }

    private func cloudBody(type: ProviderType, catalog: Bool) async throws -> [String: Any] {
        let h = try await PromptRealPathHarness.make(PromptScenario(name: "catalog-tools", providerType: type,
                                                                   memoryFixtures: false, modelId: "claude-sonnet-4-6"))
        let backend = AssistantCloudBackend(model: h.model, providerManager: h.providerManager)
        let built = expectation(description: "真实 provider 组好请求")
        var captured: [String: Any]?
        RequestBodyTap.handler = { body in
            guard captured == nil else { return }
            captured = body
            built.fulfill()
        }
        let agent = CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in nil }))
        let task: Task<Void, Never>?
        if catalog {
            let request = job()
            task = Task { _ = await agent.run(request) }
        } else {
            task = nil
            backend.run(.init(system: "测试", history: [("user", "电影")], tools: AssistantTools.definitions, toolTurns: [])) { _ in }
        }
        await fulfillment(of: [built], timeout: 5)
        RequestBodyTap.handler = nil
        agent.cancel()
        backend.cancel()
        await task?.value
        await h.tearDown()
        return try XCTUnwrap(captured)
    }

    // MARK: - 手动的两种跑法

    func testOrganizeTopicMakesOneTopicProposal() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let backend = FakeCatalogBackend { [submit] n, _ in
            n == 1 ? self.search() : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
        }
        let ctx = ModelContext(container)
        let m = Memory(content: "一起看了电影", category: "fact", profileId: pid)
        m.occurredDay = "2026-10-12"
        m.reviewedAt = Date()
        ctx.insert(m)
        try ctx.save()

        let session = CatalogSession(job: CatalogTestKit.job(pid: pid, root: root, container: container, backend: backend, maxRounds: 2))
        let report = await session.organizeTopic("电影")

        XCTAssertEqual(report.proposals, 1)
        XCTAssertEqual(report.incomplete, 1, "2 轮：第 2 轮就是收尾轮")
        let p = try XCTUnwrap(WikiProposalStore(wiki: WikiStore(root: root.appendingPathComponent("wiki"))).list().first)
        XCTAssertEqual(p.origin, .topic)
        XCTAssertEqual(p.title, "电影")
        XCTAssertTrue(p.incomplete)
        XCTAssertEqual(p.items.first?.fragmentIds, [m.id])
        XCTAssertEqual(p.request, .init(profileId: pid, text: "整理一个主题：电影"), "她说的这句话就是方向授权，记下来")
        XCTAssertNil(p.items.first { $0.change.direction != nil }, "不再出一个方向等她重复批")
        XCTAssertFalse(WikiStore(root: root.appendingPathComponent("wiki")).pageExists("事/电影"), "正文没批不落页")
    }

    /// 第 9 段：现在整理里第一个主题的修订被预算闸拦下——交第一稿，照样往上报「被拦」，后面的主题不再跑
    func testBudgetBlockDuringRevisionDeliversTheFirstDraftAndStopsLaterTopics() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        for (i, s) in ["周五去看剧", "剧散场下雨", "剧票丢了", "怕香菜", "香菜过敏", "香菜汤"].enumerated() {
            let m = Memory(content: s, category: "fact", profileId: pid)
            m.subject = i < 3 ? "剧场" : "香菜"
            m.occurredDay = "2026-10-1\(i)"
            m.reviewedAt = Date()
            ctx.insert(m)
        }
        try ctx.save()
        let backend = FakeCatalogBackend { _, _ in
            .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, """
            {"items":[{"type":"new_page","path":"主题/测试页","kind":"主题","title":"测试页","now":"- 列表行（自 2026-10 起）",
              "records":[{"text":"2026-10-10 去看剧","fragments":["f1"]}]}]}
            """)])
        }
        let base = gateCalls
        var job = CatalogTestKit.job(pid: pid, root: root, container: container, backend: backend)
        job.agentDeps = CatalogAgent.Deps(makeBackend: { backend }, gate: { [weak self] _ in
            await MainActor.run { self?.gateCalls += 1 }
            let n = await MainActor.run { self?.gateCalls ?? 0 }
            return n == base + 2 ? "预算用完" : nil
        })

        let report = await CatalogSession(job: job).organizeNow()

        XCTAssertEqual(backend.requests.count, 1, "修订那次被拦，后面的主题不再跑")
        XCTAssertEqual(report.blocked, "预算用完")
        XCTAssertTrue(report.summary.contains("被拦：预算用完"))
        let p = try XCTUnwrap(WikiProposalStore(wiki: WikiStore(root: root.appendingPathComponent("wiki"))).list().first)
        XCTAssertEqual(p.items.count, 1, "交了第一稿")
        XCTAssertTrue(p.revision?.contains("那轮被预算拦下（预算用完）") == true && p.revision?.hasSuffix("交的是第一稿") == true, p.revision ?? "nil")
    }

    func testOrganizeNowListsTopicsByCodeThenOneProposalPerTopic() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let ctx = ModelContext(container)
        var ids: [UUID] = []
        for (i, s) in ["周五去看剧", "剧散场下雨", "剧票丢了", "怕香菜"].enumerated() {
            let m = Memory(content: s, category: "fact", profileId: pid)
            m.subject = i < 3 ? "剧场" : "香菜"
            m.occurredDay = "2026-10-1\(i)"
            m.reviewedAt = Date()
            ctx.insert(m)
            ids.append(m.id)
        }
        try ctx.save()
        var modelCalls = 0
        let caller: SessionSegmentWriter.Caller = { _, _ in
            modelCalls += 1
            return nil
        }
        let backend = FakeCatalogBackend { _, request in
            XCTAssertTrue(request.history[0].content.contains("新主题 · 类：主题 · 建议路径：主题/剧场"))
            return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, """
            {"items":[{"type":"new_page","path":"主题/剧场","kind":"事","title":"剧场","records":[{"text":"2026-10-10 周五去看剧","fragments":["f1"]}]}],
             "covered":["f2"],"single":["f3","f4"]}
            """)])
        }

        let report = await CatalogSession(job: CatalogTestKit.job(pid: pid, root: root, container: container, caller: caller, backend: backend)).organizeNow()

        XCTAssertEqual(modelCalls, 0, "主题清单由代码按碎片标题列，不调分拣模型")
        XCTAssertEqual(backend.requests.count, 1, "香菜只有 1 条，不成主题")
        XCTAssertEqual(report.single, 1)
        XCTAssertEqual(report.proposals, 1)
        let p = try XCTUnwrap(WikiProposalStore(wiki: WikiStore(root: root.appendingPathComponent("wiki"))).list().first)
        XCTAssertEqual(p.origin, .manual)
        XCTAssertEqual(p.title, "剧场")
        XCTAssertEqual(p.request?.text, "现在整理")
        XCTAssertFalse(p.incomplete)
        XCTAssertEqual(p.items[0].fragmentIds, [ids[0]], "只挂明确引用的")
        XCTAssertEqual(p.items[0].covered, [ids[1]], "covered 挂在这页第一条上，批了才标")
        let rows = try ModelContext(container).fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(rows.first { $0.id == ids[2] }?.isSingleEnough, true, "分到这个主题的单条就够直接打标")
        XCTAssertNil(rows.first { $0.id == ids[3] }?.organizedAt, "没分到这个主题的不能被它判单条")
        XCTAssertNil(rows.first { $0.id == ids[1] }?.organizedAt, "covered 等正文批了才标")
    }

    /// 工具循环发出去的那份：提示词、历史、工具回执、工具定义里的 {{user}} 换成名字；模型自己的调用原样
    func testAgentRequestShownWithCurrentName() {
        let raw = #"{"path":"星砚/品味"}"#
        let call = CatalogTestKit.call("read_wiki", raw, id: "c1")
        let turn = ToolTurn(calls: [call], results: [ToolResultBlock(toolUseId: "c1", text: "- [[{{user}}/作息]] · 补充", isError: false)])
        let request = AssistantBackendRequest(system: "本人的页挂在 {{user}}/ 下", history: [(role: "user", content: "【这一页】{{user}}/品味")],
                                              tools: [["name": "submit_proposal", "enum": ["{{user}}/品味"]]], toolTurns: [turn])
        let shown = CatalogAgent.shown(request, user: "星砚")
        XCTAssertEqual(shown.system, "本人的页挂在 星砚/ 下")
        XCTAssertEqual(shown.history.map(\.content), ["【这一页】星砚/品味"])
        XCTAssertEqual(shown.toolTurns.first?.results.first?.text, "- [[星砚/作息]] · 补充")
        XCTAssertEqual(shown.toolTurns.first?.calls.first?.argumentsJSON, raw, "回放的是模型原样写的调用（它写的就是名字）")
        XCTAssertEqual(shown.tools.first?["enum"] as? [String], ["星砚/品味"])
    }

    /// 本人那组：模型照它看到的名字 read_wiki / 交条目 → 执行在 {{user}}/… 上；回合里存、回放的是模型原样的调用，
    /// 回执显示名字；每一轮发出去的前缀（system / 开场 / 前面的回合）逐字不变
    func testUserBranchToolCallsExecuteOnStoredPathAndReplayRaw() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let base = try wiki.save(WikiPage(path: "{{user}}/身体", kind: .user, triggers: ["过敏"], hook: "h", title: "身体", now: "花生过敏。",
                                          links: [.init(target: "{{user}}/作息", relation: .supplement, why: "")]))
        let read = CatalogTestKit.call("read_wiki", #"{"path":"粟粟/身体"}"#, id: "r1")
        let list = CatalogTestKit.call("list_wiki", #"{ "path" : "粟粟" }"#, id: "l1")
        let backend = FakeCatalogBackend { n, _ in
            switch n {
            case 1: return .toolCalls([read])
            case 2: return .toolCalls([list])
            default:
                return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit,
                    #"{"items":[{"type":"append","path":"粟粟/身体","records":[{"text":"2026-10-12 随身带药","fragments":["f1"]}]}]}"#)])
            }
        }

        let out = await agent(backend).run(job())

        XCTAssertEqual(out.items.compactMap(\.change.targetPath), ["{{user}}/身体"], "条目落回落盘路径")
        XCTAssertEqual(out.items.first?.baseVersion, base, "读到的就是 {{user}}/身体 那一页")
        XCTAssertEqual(backend.requests.count, 3)
        let second = backend.requests[1], third = backend.requests[2]
        XCTAssertEqual(second.toolTurns.first?.calls.first?.argumentsJSON, read.argumentsJSON, "回放模型原样的调用")
        let readResult = try XCTUnwrap(second.toolTurns.first?.results.first)
        XCTAssertFalse(readResult.isError, readResult.text)
        XCTAssertTrue(readResult.text.contains("[[粟粟/作息]]") && !readResult.text.contains("{{user}}"), readResult.text)
        let listResult = try XCTUnwrap(third.toolTurns.last?.results.first)
        XCTAssertFalse(listResult.isError, "空格写法的 path 也认成本人那组：\(listResult.text)")
        XCTAssertTrue(listResult.text.contains("粟粟/身体"), listResult.text)
        for r in backend.requests {
            XCTAssertFalse(([r.system] + r.history.map(\.content) + r.toolTurns.flatMap(\.results).map(\.text)).joined().contains("{{user}}"))
        }
        XCTAssertEqual(second.system, third.system)
        XCTAssertEqual(second.history.map(\.content), third.history.map(\.content))
        XCTAssertEqual(second.toolTurns.first?.calls.map(\.argumentsJSON), third.toolTurns.first?.calls.map(\.argumentsJSON), "前缀里的回合两轮逐字一样")
        XCTAssertEqual(second.toolTurns.first?.results.map(\.text), third.toolTurns.first?.results.map(\.text))
    }

    /// 签名思考：回放原样调用时 tool_use 的 input 对得上原内容块，思考块保留；拿还原过路径的参数回放就会被当成改过、思考被删（所以不能那样做）
    func testRawCallReplayKeepsSignedThinking() {
        let call = CatalogTestKit.call("read_wiki", #"{"path":"粟粟/身体"}"#, id: "r1")
        let content: [[String: Any]] = [["type": "tool_use", "id": "r1", "name": "read_wiki", "input": ["path": "粟粟/身体"]],
                                        ["type": "thinking", "thinking": "读完再想", "signature": "sig"]]
        var raw = ToolTurn(calls: [call], results: [ToolResultBlock(toolUseId: "r1", text: "x", isError: false)])
        raw.assistantContent = content
        XCTAssertTrue(AnthropicProvider.toolTurnAssistantContent(raw).contains { $0["type"] as? String == "thinking" })
        var executed = ToolTurn(calls: [CatalogTestKit.call("read_wiki", #"{"path":"{{user}}/身体"}"#, id: "r1")], results: raw.results)
        executed.assistantContent = content
        XCTAssertFalse(AnthropicProvider.toolTurnAssistantContent(executed).contains { $0["type"] as? String == "thinking" })
    }

    /// covered_page 写名字：还原成 {{user}} 后挂到读过的本人页，不挂到首条条目的页
    func testCoveredPageByNameAttachesToUserPage() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let mine = try wiki.save(WikiPage(path: "{{user}}/身体", kind: .user, title: "身体", now: "花生过敏。"))
        try wiki.save(WikiPage(path: "人/小慧", kind: .person, title: "小慧", now: "室友。"))
        let backend = FakeCatalogBackend { n, _ in
            switch n {
            case 1: return .toolCalls([CatalogTestKit.call("read_wiki", #"{"path":"粟粟/身体"}"#), CatalogTestKit.call("read_wiki", #"{"path":"人/小慧"}"#)])
            default:
                return .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit,
                    #"{"items":[{"type":"append","path":"人/小慧","records":[{"text":"2026-10-12 一起看电影","fragments":["f1"]}]}],"covered":["f2"],"covered_page":"粟粟/身体"}"#)])
            }
        }
        let out = await agent(backend).run(job())
        XCTAssertEqual(out.items.first { $0.change.targetPath == "人/小慧" }?.covered ?? [], [], "不挂到首条条目的页")
        let confirm = try XCTUnwrap(out.items.first { $0.change.targetPath == "{{user}}/身体" })
        XCTAssertEqual(confirm.covered, [bread.id])
        XCTAssertEqual(confirm.baseVersion, mine)
    }

    /// covered_page 点名了没读过的页：打回一次；改不对也不改挂到别的页
    func testUnresolvableCoveredPageIsRejectedNotMisattached() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try wiki.save(WikiPage(path: "人/小慧", kind: .person, title: "小慧", now: "室友。"))
        let submit = #"{"items":[{"type":"append","path":"人/小慧","records":[{"text":"2026-10-12 一起看电影","fragments":["f1"]}]}],"covered":["f2"],"covered_page":"粟粟/没读过"}"#
        let backend = FakeCatalogBackend { n, _ in
            n == 1 ? .toolCalls([CatalogTestKit.call("read_wiki", #"{"path":"人/小慧"}"#)]) : .toolCalls([CatalogTestKit.call(CatalogAgentTools.submit, submit)])
        }
        let out = await agent(backend).run(job())
        let rejected = try XCTUnwrap(backend.requests.dropFirst(2).first?.toolTurns.last?.results.first)
        XCTAssertTrue(rejected.isError, rejected.text)
        XCTAssertTrue(rejected.text.contains("covered_page「粟粟/没读过」"), "打回说清楚，回执里显示名字：\(rejected.text)")
        XCTAssertEqual(out.items.compactMap(\.change.targetPath), ["人/小慧"])
        XCTAssertEqual(out.items.first?.covered ?? [], [], "给了覆盖目标却解析不了：不静默改挂")
        XCTAssertFalse(out.items.contains { if case .confirmCovered = $0.change { return true } else { return false } })
    }

    /// 诊断尾部被截断：先按原规则救回正文，再还原路径，再校验（诊断截断不连累正文）
    func testTruncatedDiagnosticsStillRestoresBodyPaths() throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        var sources = CatalogSources()
        sources.addFragments([movie])
        let json = #"{"items":[{"type":"new_page","path":"粟粟/电影","kind":"用户","title":"电影","records":[{"text":"2026-10-12 一起看了电影","fragments":["f1"]}]}],"coverage":[{"input":"f1","at":"粟粟/电"#
        let parsed = try XCTUnwrap(CatalogItems.parse(json, sources: sources, wiki: wiki, truncated: true, user: CatalogTestKit.names.user))
        XCTAssertEqual(parsed.items.compactMap(\.change.targetPath), ["{{user}}/电影"])
        XCTAssertNil(CatalogItems.parse(json, sources: sources, wiki: wiki, truncated: true)?.items.first, "不给名字就不还原（名字路径不合法，被扔）")
    }
}
