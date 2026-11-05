import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class CatalogOriginalRetrievalTests: XCTestCase {
    private let pid = "catalog-p1-synthetic"
    private var root: URL!
    private var container: ModelContainer!
    private var now: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 20))! }
    private let originalBody = "我在写虚构作品《云桥城》，设定中每座桥每晚都会移位。"
    private let nodeId = "cloudbridge-original-node"
    private let conversationId = "cloudbridge-window"
    private var submit: String {
        "{\"items\":[{\"type\":\"new_page\",\"path\":\"楼层/主题/云桥城\",\"kind\":\"主题\",\"title\":\"云桥城\",\"records\":[{\"text\":\"虚构作品的桥每晚移位\",\"aline\":[{\"layer\":\"原文\",\"nodeId\":\"\(nodeId)\"}]}]}]}"
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-p1-\(UUID().uuidString)")
        let schema = Schema([Memory.self, Conversation.self, MessageNode.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(Conversation(id: conversationId, title: "编造创作窗口", createTime: now, updateTime: now,
                                    currentNodeId: nodeId, profileId: pid))
        context.insert(MessageNode(id: nodeId, role: "user", content: originalBody, contentType: "text", createTime: now,
                                   parentId: nil, childrenIds: [], conversationId: conversationId, profileId: pid))
        try context.save()
    }

    override func tearDown() async throws {
        RequestBodyTap.handler = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func source(index: SearchIndexStore? = nil) -> CatalogRetrieval.OriginalSearch {
        let container = container!
        let pid = pid
        return { terms, interval, cancel in
            await SearchService.catalogContent(terms: terms, profileId: pid, container: container, interval: interval, index: index, cancel: cancel)
        }
    }

    func testOnlyOriginalContainsWorkAndReachesAutomaticWriterWithStableMessageTarget() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let store = try SearchIndexStore.open(at: root.appendingPathComponent("search.sqlite"))
        try store.apply(upserts: [.init(nodeId: nodeId, conversationId: conversationId, profileId: pid, role: "user",
                                       created: now, trashed: false, body: originalBody, identifierKey: nil)], epoch: store.epoch)
        for index in [nil, store] {
            let material = await CatalogWriter.material(.init(path: "楼层/主题/云桥城", title: "云桥城", kind: .topic, existing: false),
                                                         fragments: [], floorPrompt: "", wiki: wiki, memoryRoot: root, now: now,
                                                         embedder: CatalogFakeEmbedder.unavailable(), originalSearch: source(index: index))
            var actual = ""
            let parsed = try await CatalogWriter.write(material, names: .init(userName: "{u}", assistantName: "{c}"), wiki: wiki,
                                                      caller: { [submit] _, user in actual = user; return submit }, drafts: nil)
            XCTAssertTrue(actual.contains(originalBody))
            XCTAssertTrue(actual.contains("nodeId=" + nodeId))
            let cite = try XCTUnwrap(parsed?.items.first?.cites.first)
            XCTAssertEqual(cite.layer, "原文")
            XCTAssertEqual(cite.nodeId, nodeId)
            XCTAssertEqual(cite.windowId, conversationId)
            XCTAssertEqual(cite.profileId, pid)
            let target = try XCTUnwrap(WikiProposalDisplay.messageTarget(for: cite, currentProfileId: pid))
            XCTAssertEqual(target.conversationId, conversationId)
            XCTAssertEqual(target.nodeId, nodeId)
            XCTAssertEqual(material.search.receipt.evidence().original, [originalBody])
            print("[P1 SMOKE] automatic original: index=\(index != nil), node=\(cite.nodeId!), body=\(material.search.receipt.bodyChars)")
        }
    }

    func testNamedTopicSessionUsesOriginalSearchAndPersistsNodeCite() async throws { try await sessionOriginal("topic") }
    func testDailySessionUsesOriginalSearchAndPersistsNodeCite() async throws { try await sessionOriginal("daily") }
    func testOrganizeNowSessionUsesOriginalSearchAndPersistsNodeCite() async throws { try await sessionOriginal("now") }

    private func sessionOriginal(_ mode: String) async throws {
        let context = ModelContext(container)
        for i in 0..<3 {
            let memory = Memory(content: "虚构创作讨论线索\(i)", category: "fact", profileId: pid)
            memory.subject = "云桥城"
            memory.occurredDay = "2026-10-18"
            memory.reviewedAt = now
            context.insert(memory)
        }
        try context.save()
        let backend = FakeCatalogBackend { [submit] round, _ in
            .toolCalls([round == 1 ? CatalogTestKit.call("search_aline", "{\"terms\":[\"云桥城\"]}")
                : CatalogTestKit.call(CatalogAgentTools.submit, submit)])
        }
        var actual = ""
        let caller: SessionSegmentWriter.Caller = { [submit] _, user in
            actual = user
            return submit
        }
        var job = CatalogTestKit.job(pid: pid, root: root, container: container, caller: caller, backend: backend)
        job.names = .init(userName: "{u}", assistantName: "{c}")
        let session = CatalogSession(job: job)
        let store = WikiProposalStore(wiki: .init(root: root.appendingPathComponent("wiki")))
        let report: CatalogRunReport
        switch mode {
        case "daily":
            _ = await session.daily(now: now)
            XCTAssertTrue(actual.isEmpty, "方向待批时不搜不写")
            let direction = try XCTUnwrap(store.list().first)
            try await WikiProposalReview.approve(direction.id, store: store, profileId: pid, context: ModelContext(container))
            report = await CatalogSession(job: job).directions(direction.id, now: now)
        case "now": report = await session.organizeNow(now: now)
        default: report = await session.organizeTopic("云桥城", now: now)
        }
        if mode != "daily" { actual = try XCTUnwrap(backend.requests.last?.toolTurns.first?.results.first?.text) }
        XCTAssertEqual(report.proposals, 1)
        XCTAssertTrue(actual.contains(originalBody))
        XCTAssertTrue(actual.contains(nodeId))
        let proposal = try XCTUnwrap(store.list().first { $0.items.contains { $0.change.direction == nil } })
        XCTAssertEqual(proposal.items.first?.cites.first?.nodeId, nodeId)
        print("[P1 SMOKE] \(mode) session: proposals=\(report.proposals), original node=\(nodeId) reached actual writer request")
    }

    func testSameSourceDeduplicatesBeforeSharedCorpusScoringAndWeightsBreakTies() throws {
        let node = SearchService.CatalogNode(profileId: pid, conversationId: conversationId, nodeId: nodeId, title: "窗口",
                                            created: now, role: "user", onMain: true, body: "solarship")
        let hit = CatalogALineReader.Hit(layer: .a2, conversationId: conversationId, title: "窗口", start: now, end: now,
                                         day: "2026-10-18", segment: 1, messages: 0..<1,
                                         parts: [.init(text: "solarship", isBody: true)], old: nil)
        let fragment = CatalogFragment(id: UUID(), content: "solarship", category: "fact", day: "2026-10-18")
        let result = CatalogRetrieval.Result(aline: .init(terms: ["solarship"], hits: [hit, hit], found: [.a2: 2]),
                                             fragments: [fragment, fragment], labels: [fragment.id: "f7"], vectorStatus: "命中", originals: [node, node])
        XCTAssertEqual(result.originals.map(\.nodeId), [nodeId])
        XCTAssertEqual(result.aline.hits, [hit])
        XCTAssertEqual(result.fragments.map(\.id), [fragment.id])
        XCTAssertEqual(result.receipt.bodies.map(\.kind), [.original, .aline, .fragment])
        let second = SearchService.CatalogNode(profileId: pid, conversationId: conversationId, nodeId: "second-node", title: node.title,
                                                created: now, role: "assistant", onMain: false, body: node.body)
        let tied = CatalogRetrieval.Result(aline: .init(terms: ["solarship"], hits: [], found: [:]), fragments: [], labels: [:],
                                           vectorStatus: "未检索", originals: [second, node])
        XCTAssertEqual(tied.originals.map(\.nodeId), ["second-node", nodeId])
    }

    func testBodyBudgetClipsByCharacterAndDoesNotRegisterUnseenTail() throws {
        let family = "👨‍👩‍👧‍👦"
        let first = CatalogFragment(id: UUID(), content: String(repeating: family, count: 6001), category: "fact", day: "2026-10-18")
        let tail = CatalogFragment(id: UUID(), content: "never-shown", category: "fact", day: "2026-10-18")
        let result = CatalogRetrieval.Result(aline: .init(terms: ["不存在的词"], hits: [], found: [:]), fragments: [first, tail],
                                             labels: [first.id: "f1", tail.id: "f2"], vectorStatus: "向量命中")
        XCTAssertEqual(result.receipt.evidence().fragments, [String(repeating: family, count: 6000)])
        var sources = CatalogSources()
        result.receipt.register(in: &sources)
        XCTAssertTrue(sources.fragments.isEmpty, "第一条只回灌了 6000 / 6001 个字，整条不登记")
        let start = try XCTUnwrap(result.receipt.bodies.first?.range.lowerBound)
        result.receipt.prefix(start).register(in: &sources)
        XCTAssertTrue(sources.fragments.isEmpty)
        result.receipt.prefix(start + 1).register(in: &sources)
        XCTAssertTrue(sources.fragments.isEmpty, "出现一个字不算给过")
    }

    func testAgentRejectsFragmentNotActuallyProvidedAfterTruncation() async throws {
        let first = CatalogFragment(id: UUID(), content: String(repeating: "solarship ", count: 100), category: "fact", day: "2026-10-18")
        let tail = CatalogFragment(id: UUID(), content: "solarship " + String(repeating: "background ", count: 2000), category: "fact", day: "2026-10-18")
        let submission = "{\"items\":[{\"type\":\"new_page\",\"path\":\"楼层/主题/船\",\"records\":[{\"text\":\"实际提供\",\"fragments\":[\"f1\"]},{\"text\":\"尾部未提供\",\"fragments\":[\"f2\"]}]}]}"
        let backend = FakeCatalogBackend { round, _ in
            .toolCalls([round == 1 ? CatalogTestKit.call("search_fragments", "{\"terms\":[\"solarship\"]}")
                : CatalogTestKit.call(CatalogAgentTools.submit, submission)])
        }
        let outcome = await CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in nil })).run(
            .init(topic: "船", profileId: pid, memoryRoot: root, names: .init(userName: "{u}", assistantName: "{c}"),
                  floorPrompt: "", snapshot: [first, tail], modelName: "假模型", embedder: CatalogFakeEmbedder.unavailable()))
        XCTAssertEqual(outcome.stop, .submitted)
        XCTAssertEqual(outcome.items.first?.fragmentIds, [first.id])
        XCTAssertEqual(outcome.dropped, 1)
        XCTAssertEqual(outcome.searchedChars, 6000)
        XCTAssertTrue(backend.requests.last!.toolTurns[0].results[0].text.contains("f2 ·"), "尾部那条只回灌了半截，引用它的行照样扔")
    }

    func testOldRunEvidenceDecodesWithoutOriginalField() throws {
        let json = "{\"aline\":[\"旧正文\"],\"fragments\":[],\"assigned\":[],\"vectorStatus\":\"未检索\"}"
        let evidence = try JSONDecoder().decode(CatalogSearchEvidence.self, from: Data(json.utf8))
        XCTAssertEqual(evidence.original, [])
        XCTAssertEqual(evidence.searchedChars, 3)
    }

    func testAnthropicToolChainCarriesOriginalNodeInActualRequest() async throws { try await providerChain(.anthropic) }
    func testOpenAIToolChainCarriesOriginalNodeInActualRequest() async throws { try await providerChain(.openaiCompatible) }

    private func providerChain(_ type: ProviderType) async throws {
        let h = try await PromptRealPathHarness.make(.init(name: "catalog-p1-wire", providerType: type, streamingMode: .off,
                                                          memoryFixtures: false, modelId: type == .anthropic ? "claude-sonnet-4-6" : "gpt-4o"))
        let searchArgs: [String: Any] = ["terms": ["云桥城"]]
        let submitArgs = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(submit.utf8)) as? [String: Any])
        let server = try OutputTokenCapTests.ScriptedHTTPServer { index, _ in
            let name = index == 0 ? "search_aline" : CatalogAgentTools.submit
            let args = index == 0 ? searchArgs : submitArgs
            let body: [String: Any]
            if type == .anthropic {
                body = ["id": "fake-anthropic-\(index)", "type": "message", "role": "assistant",
                        "content": [["type": "tool_use", "id": "call-\(index)", "name": name, "input": args]],
                        "stop_reason": "tool_use", "usage": ["input_tokens": 10, "output_tokens": 10]]
            } else {
                let json = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                body = ["id": "fake-openai-\(index)", "choices": [["index": 0, "message": ["role": "assistant", "content": "",
                         "tool_calls": [["id": "call-\(index)", "type": "function", "function": ["name": name, "arguments": json]]]],
                         "finish_reason": "tool_calls"]], "usage": ["prompt_tokens": 10, "completion_tokens": 10]]
            }
            return (200, "application/json", try! JSONSerialization.data(withJSONObject: body))
        }
        try server.start()
        defer { server.stop() }
        var credential = try XCTUnwrap(h.providerManager.credential(for: h.model))
        credential.baseURL = server.baseURL
        h.providerManager.updateCredential(credential)
        let backend = AssistantCloudBackend(model: h.model, providerManager: h.providerManager, usage: .init(kind: .catalog))
        let outcome = await CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in nil })).run(
            .init(topic: "云桥城", profileId: pid, memoryRoot: root, names: .init(userName: "{u}", assistantName: "{c}"),
                  floorPrompt: "", snapshot: [], modelName: "假provider", embedder: CatalogFakeEmbedder.unavailable(), originalSearch: source()))
        let bodies = try server.requestBodies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        backend.cancel()
        await h.tearDown()
        XCTAssertEqual(outcome.stop, .submitted)
        XCTAssertEqual(outcome.items.first?.cites.first?.nodeId, nodeId)
        XCTAssertEqual(bodies.count, 2)
        let messages = try XCTUnwrap(bodies.last?["messages"] as? [[String: Any]])
        if type == .anthropic {
            let blocks = messages.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }
            let use = try XCTUnwrap(blocks.first { $0["type"] as? String == "tool_use" })
            let result = try XCTUnwrap(blocks.first { $0["type"] as? String == "tool_result" })
            XCTAssertEqual(use["id"] as? String, result["tool_use_id"] as? String)
            let text = result["content"] as? String ?? ""
            XCTAssertTrue(text.contains(originalBody))
            XCTAssertTrue(text.contains(nodeId))
        } else {
            let call = try XCTUnwrap(messages.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }.first)
            let result = try XCTUnwrap(messages.first { $0["role"] as? String == "tool" })
            XCTAssertEqual(call["id"] as? String, result["tool_call_id"] as? String)
            let text = result["content"] as? String ?? ""
            XCTAssertTrue(text.contains(originalBody))
            XCTAssertTrue(text.contains(nodeId))
        }
        print("[P1 SMOKE] \(type): fake provider -> search -> actual wire tool result -> submitted node=\(nodeId), requests=\(bodies.count)")
    }
}
