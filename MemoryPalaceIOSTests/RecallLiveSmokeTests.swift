import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class RecallLiveSmokeTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var providers: ProviderManager?
    private var credentialId: String?
    private var backend: AssistantCloudBackend?
    private var profileId = ""
    private var conversationId = ""
    private var nodeIds: [String] = []
    private var longText = ""
    private let originalKeyword = "云桥城航图原料"
    // Haiku 每条链平均绕路 1–2 次；生产熔断走 tuning.maximumRecallCalls。
    private let maximumRecallCalls = 8

    private struct Observation {
        let input: RecallTool.Input
        let result: RecallTool.ExecResult
        var layer: String? { input.layer ?? input.target?.layer }
    }
    private struct Evidence: Codable {
        var tools: [String] = []
        var toolUses: [String] = []
        var failures: [String] = []
        var finalAnswer: String? = nil
    }
    private var evidence = Evidence()

    override func setUp() async throws {
        guard let value = getenv("MP_C3_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_C3_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "RecallLiveSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        try CatalogLiveAuthProtocol.install()
        profileId = UUID().uuidString
        conversationId = UUID().uuidString
        nodeIds = (0..<12).map { _ in UUID().uuidString }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: profileId))
        defaults.set(true, forKey: "mem_master")
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        try seed()
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        CatalogRecallIndexer.shared.ensure(profileId: profileId, wiki: wiki)
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: profileId)
    }

    override func tearDown() async throws {
        RequestBodyTap.handler = nil
        backend?.cancel()
        backend = nil
        if let credentialId { providers?.removeCredential(id: credentialId) }
        providers = nil
        credentialId = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
        if !profileId.isEmpty {
            defaults?.removePersistentDomain(forName: profileId)
            CatalogRecallIndexer.shared.deleteProfile(profileId)
            try? await CatalogRecallIndexer.shared.waitUntilIdle(profileId: profileId)
        }
        container = nil
        defaults = nil
        if let root {
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where !(file.lastPathComponent.hasPrefix("recall-live-") && file.pathExtension == "json") {
                try FileManager.default.removeItem(at: file)
            }
        }
        root = nil
    }

    func testDateThenWindowThenSegmentThenMessagesLive() async throws {
        let observations = try await run("2026-10-31 那天我们聊了什么，把原话找出来")
        let ops = observations.map(\.input.op)
        assertOrdered([.date, .window, .segment, .messages], in: ops)
        assertNoFabricatedIds(observations)
        let messages = try XCTUnwrap(observations.last { $0.input.op == .messages })
        XCTAssertFalse(messages.result.isError, messages.result.text)
    }

    /// 只断言工具合同：`search a` 命中且不报错、下钻/读原文的 target 或显式定位值来自 search a 的结果、
    /// `search c` 可选（出现时必须晚于 search a）。不断言走法——11-05 与 11-10 live 都是 Haiku
    /// `search a` 命中后直接读原文、跳过 c（或先 c 再读原文），工具合同 0 错、回答正确却挂测试；
    /// 走法属于模型自由，合同才是测试要守的东西。
    func testSearchScopeAReadsOriginalAndOptionalScopeCLive() async throws {
        let observations = try await run("搜一下『航图』，先翻对话记忆再翻档案，把命中的那条原文读出来")
        let a = try XCTUnwrap(observations.firstIndex { $0.input.op == .search && $0.input.scope == "a" },
                              "必须至少调用一次 search a")
        XCTAssertFalse(observations[a].result.isError, observations[a].result.text)
        for observation in observations where observation.input.op == .search {
            XCTAssertFalse(observation.result.isError, observation.result.text)
        }
        if let c = observations.firstIndex(where: { $0.input.op == .search && $0.input.scope == "c" }) {
            XCTAssertLessThan(a, c, "search c 若出现必须在首个 search a 之后")
            XCTAssertFalse(observations[c].result.isError, observations[c].result.text)
        }
        assertNoFabricatedIds(observations)
        let readIndex = try XCTUnwrap(observations.indices.last { $0 > a && observations[$0].input.op == .messages },
                                      "search a 之后必须读取原文")
        XCTAssertFalse(observations[readIndex].result.isError, observations[readIndex].result.text)
        let drilled = observations.indices.contains { index in
            guard index > a, index <= readIndex else { return false }
            let input = observations[index].input
            guard input.op == .window || input.op == .segment || input.op == .messages || input.op == .date else { return false }
            let issued = observations[a..<index]
                .filter { $0.input.op == .search && $0.input.scope == "a" }
                .flatMap(\.result.targets)
            if let target = input.target, issued.contains(target) { return true }
            return issued.contains { target in
                (input.date != nil && input.date == target.date)
                    || (input.conversationId != nil && input.conversationId == target.conversationId)
            }
        }
        XCTAssertTrue(drilled, "search a 之后、读原文之前（含 search c 之后的）至少一次下钻的 target 或显式定位值必须来自此前 search a 的结果")
    }

    func testWikiIndexPageEntryOriginalLive() async throws {
        let observations = try await run("在档案索引里找星砚那一页，把她那页记录的原文读出来")
        let wiki = observations.filter { $0.input.op == .wiki }
        assertOrdered(["index", "page", "entry", "original"], in: wiki.filter { !$0.result.isError }.compactMap(\.layer))
        for rejected in wiki where rejected.result.isError {
            XCTAssertFalse(rejected.result.text.contains(originalKeyword), rejected.result.text)
            let firstLine = rejected.result.text.components(separatedBy: "\n")[0]
            XCTAssertTrue(firstLine.contains("entry") || firstLine.contains("从父层重新定位"), rejected.result.text)
        }
        let original = try XCTUnwrap(wiki.last { $0.layer == "original" })
        XCTAssertFalse(original.result.isError, original.result.text)
        XCTAssertTrue(original.result.text.contains(originalKeyword), original.result.text)
    }

    func testCursorContinuationLive() async throws {
        let observations = try await run("把那条最长的消息完整读出来（conversation_id=\(conversationId)）")
        let messages = observations.filter { $0.input.op == .messages }
        XCTAssertGreaterThanOrEqual(messages.count, 2)
        guard messages.count >= 2 else { return }
        let cursor = try XCTUnwrap(messages[0].result.cursor)
        XCTAssertEqual(messages[1].input.cursor.map(RecallTool.normalizeCursor), cursor, "cursor 规范化后必须逐字节一致")
        var collected = ""
        var previous: String?
        for (index, observation) in messages.enumerated() {
            XCTAssertFalse(observation.result.isError, observation.result.text)
            if index > 0 { XCTAssertEqual(observation.input.cursor.map(RecallTool.normalizeCursor), previous) }
            collected += messageBody(observation.result.text)
            previous = observation.result.cursor
        }
        XCTAssertNil(previous, "最长消息必须读到结束，不能只拿到第一页就总结")
        XCTAssertEqual(collected, longText, "各页原文拼接必须无缺字、无重复、无其他消息")
    }

    func testInjectedPageSurvivesRecallMissLive() async throws {
        let observations = try await run("雾岚航图盒里放了什么？先搜一下『雾桥』，没有的话按你已知道的回答。",
            system: """
            先按问题要求调用 recall，最后直接回答问题。

            [[人/雾岚]] 雾岚
            钩子：云桥城的航图保管人
            现在：雾岚的航图盒里放着琉璃纸鹤和银叶罗盘。
            """)
        let miss = try XCTUnwrap(observations.first {
            !$0.result.isError && $0.input.op == .search && $0.input.query?.contains("雾桥") == true
        })
        XCTAssertFalse(miss.result.isError, miss.result.text)
        XCTAssertTrue(miss.result.text.components(separatedBy: "\n")[0].contains("本次 0 条"), miss.result.text)
        XCTAssertTrue(miss.result.text.contains("没有找到"), miss.result.text)
        let answer = try XCTUnwrap(evidence.finalAnswer)
        XCTAssertTrue(answer.contains("琉璃纸鹤"), answer)
        XCTAssertTrue(answer.contains("银叶罗盘"), answer)
    }

    private func assertNoFabricatedIds(_ observations: [Observation], file: StaticString = #filePath, line: UInt = #line) {
        for (index, observation) in observations.enumerated() {
            let input = observation.input
            guard input.op == .window || input.op == .segment || input.op == .messages else { continue }
            let previous = observations[..<index]
            let targetIsKnown = input.target.map { target in
                previous.contains { $0.result.targets.contains(target) }
            } ?? true
            let id = input.target?.conversationId ?? input.conversationId
            let idIsKnown = id.map { id in
                previous.contains { observation in
                    observation.result.targets.contains { target in
                        guard let issued = target.conversationId else { return false }
                        return issued == id || (id.count >= 8 && issued.hasPrefix(id))
                    }
                }
            } ?? true
            if observation.result.isError {
                if !targetIsKnown || !idIsKnown {
                    let firstLine = observation.result.text.components(separatedBy: "\n")[0]
                    XCTAssertTrue(firstLine.contains("本次 0 条"), observation.result.text, file: file, line: line)
                    XCTAssertTrue(observation.result.targets.isEmpty, "被拒读不得签发 target", file: file, line: line)
                    XCTAssertNil(observation.result.cursor, "被拒读不得签发 cursor", file: file, line: line)
                }
                continue
            }
            if let target = input.target {
                XCTAssertTrue(targetIsKnown,
                              "target 必须原样来自之前的结果：\(RecallTool.json(target))", file: file, line: line)
            }
            if let id {
                XCTAssertTrue(idIsKnown, "conversation_id 必须来自之前结果的 target：\(id)", file: file, line: line)
            }
        }
    }

    private func assertOrdered<T: Equatable>(_ expected: [T], in actual: [T], file: StaticString = #filePath, line: UInt = #line) {
        var next = 0
        for value in actual where next < expected.count {
            if value == expected[next] { next += 1 }
        }
        XCTAssertEqual(next, expected.count, "分层导航顺序不符：\(actual)", file: file, line: line)
    }

    private func messageBody(_ text: String) -> String {
        let content = text.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
            .components(separatedBy: "cursor: ")[0].replacingOccurrences(of: "（该消息未完）\n", with: "")
        return content.hasSuffix("\n") ? String(content.dropLast()) : content
    }

    private func run(_ user: String, system: String = "只能通过 recall 工具查，查到为止，最后一句话总结。") async throws -> [Observation] {
        let (manager, model) = try makeProvider()
        let backend = AssistantCloudBackend(model: model, providerManager: manager,
                                            usage: UsageContext(kind: .assistant, profileId: profileId))
        self.backend = backend
        evidence = Evidence()
        RequestBodyTap.handler = { [weak self] body in
            guard let self else { return }
            self.evidence.tools.append(Self.redacted(Self.json(body["tools"] ?? [])))
        }
        var turns: [ToolTurn] = []
        var observations: [Observation] = []
        var finished = false
        do {
            for _ in 0...maximumRecallCalls {
                let request = AssistantBackendRequest(system: system,
                    history: [(role: "user", content: user)], tools: [ToolSchemaRenderer.anthropic(RecallTool.definition)], toolTurns: turns)
                let event: AssistantBackendEvent = await withCheckedContinuation { continuation in
                    backend.run(request) { event in
                        if case .token = event { return }
                        continuation.resume(returning: event)
                    }
                }
                switch event {
                case .toolCalls(let calls):
                    let raw = backend.lastTurnExtras?.assistantContent?.filter { $0["type"] as? String == "tool_use" }
                        ?? calls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input_json": $0.argumentsJSON] }
                    evidence.toolUses += raw.map { Self.redacted(Self.json($0)) }
                    guard !calls.isEmpty, observations.count + calls.count <= maximumRecallCalls else {
                        throw NSError(domain: "RecallLiveSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "真实工具循环超过 \(maximumRecallCalls) 次调用或返回空调用"])
                    }
                    var results: [ToolResultBlock] = []
                    for call in calls {
                        XCTAssertEqual(call.name, RecallTool.toolName)
                        let result = await RecallTool.execute(inputJSON: call.argumentsJSON, profileId: profileId,
                            currentConversationId: nil, userName: "岚舟", assistantName: "星砚",
                            source: SwiftDataConversationSource(container: container),
                            memoryRoot: root, defaults: defaults,
                            environment: RecallTool.l1Environment(container: container, embedder: KeywordOnlyEmbedder()))
                        var logged = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any]
                            ?? ["raw": call.argumentsJSON]
                        if let cursor = logged["cursor"] as? String { logged["cursor"] = String(cursor.prefix(20)) }
                        print("[RECALL-LIVE] op=\(logged["op"] as? String ?? "<invalid>") args=\(Self.redacted(Self.json(logged))) first=\(result.text.components(separatedBy: "\n")[0]) isError=\(result.isError)")
                        let input = try RecallTool.decoder.decode(RecallTool.Input.self, from: Data(call.argumentsJSON.utf8))
                        observations.append(Observation(input: input, result: result))
                        results.append(ToolResultBlock(toolUseId: call.id, text: result.text, isError: result.isError))
                    }
                    turns.append(ToolTurn(calls: calls, results: results, assistantContent: backend.lastTurnExtras?.assistantContent,
                                          thinkingTokens: backend.lastTurnExtras?.thinkingTokens))
                case .finished(let text):
                    print("[RECALL-LIVE] finished=\(Self.redacted(text))")
                    evidence.finalAnswer = text
                    finished = true
                case .failed(let message):
                    evidence.failures.append(Self.redacted(message))
                    XCTFail("真实端点失败（包括 HTTP 4xx）：\(Self.redacted(message))")
                    finished = true
                case .token: break
                }
                if finished { break }
            }
            XCTAssertTrue(finished, "真实工具循环必须收到终止事件")
            XCTAssertEqual(evidence.failures, [], "不允许任何 AssistantBackendEvent.failed，包括 HTTP 4xx")
            try saveEvidence()
            return observations
        } catch {
            try saveEvidence()
            throw error
        }
    }

    private func saveEvidence() throws {
        RequestBodyTap.handler = nil
        let caseName = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.last ?? "case"
        let url = root.appendingPathComponent("recall-live-\(caseName).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = Self.redacted(String(decoding: try encoder.encode(evidence), as: UTF8.self))
        try Data(text.utf8).write(to: url, options: .atomic)
        print("[RECALL-LIVE] evidence=\(url.path)")
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
    private static func redacted(_ text: String) -> String {
        CatalogLiveAuthProtocol.redacted(text).replacingOccurrences(of: #"sk-[A-Za-z0-9_-]+"#, with: "[REDACTED]", options: .regularExpression)
    }

    private func makeProvider() throws -> (ProviderManager, ProviderModel) {
        guard let modelValue = getenv("MP_C3_LIVE_MODEL"), !String(cString: modelValue).isEmpty else {
            throw XCTSkip("必须注入 TEST_RUNNER_MP_C3_LIVE_MODEL，模型不写死")
        }
        let id = "xctest-recall-live-\(UUID().uuidString)"
        credentialId = id
        let baseURL = getenv("MP_C3_LIVE_BASE_URL").map { String(cString: $0) } ?? "https://api.anthropic.com/v1"
        let modelId = String(cString: modelValue)
        let model = ProviderModel(credentialId: id, modelId: modelId, name: modelId)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        providers = manager
        manager.addCredential(APICredential(id: id, name: "Recall live test", emoji: "", type: .anthropic,
            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"], models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        return (manager, model)
    }

    private func seed() throws {
        let start = try XCTUnwrap(RecallTool.parseDay("2026-10-31")).addingTimeInterval(3600)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        longText = (0..<3600).map { String(UnicodeScalar(0x4E00 + $0)!) }.joined() + "👩🏽‍🚀"
        for index in 0..<12 {
            let text = index == 0 ? longText : "岚舟和星砚在云桥城与林栖整理航图，第\(index)条。"
            context.insert(MessageNode(id: nodeIds[index], role: index % 2 == 0 ? "user" : "assistant", content: text,
                contentType: "text", createTime: start.addingTimeInterval(Double(index * 60)),
                parentId: index == 0 ? nil : nodeIds[index - 1], childrenIds: index + 1 < 12 ? [nodeIds[index + 1]] : [],
                conversationId: conversationId, profileId: profileId))
        }
        context.insert(Conversation(id: conversationId, title: "云桥城", createTime: start, updateTime: start.addingTimeInterval(720),
                                    currentNodeId: nodeIds[11], profileId: profileId))
        try context.save()
        func segment(_ from: Int, _ to: Int, kind: SessionSegment.Kind, title: String, story: String) -> SessionSegment {
            SessionSegment(kind: kind, title: title, start: start.addingTimeInterval(Double(from * 60)),
                end: start.addingTimeInterval(Double((to - 1) * 60)), from: from, to: to, lastNodeId: nodeIds[to - 1],
                story: story, quotes: "", pending: "")
        }
        try SessionSummaryStore.save(.init(conversationId: conversationId, title: "云桥城", compressedCount: 12,
            segments: [segment(0, 1, kind: .rolling, title: "最长消息", story: "岚舟的最长一条消息，原话需通过消息范围分块读取。"),
                       segment(1, 12, kind: .rolling, title: "航图", story: "岚舟、星砚和林栖整理云桥城航图。")], updatedAt: start),
            in: SessionSummaryStore.dir(root: root))
        try WindowSummaryStore.save(.init(conversationId: conversationId, title: "云桥城", compressedCount: 12,
            segments: [segment(0, 12, kind: .closeout, title: "云桥城", story: "第一段是一条最长的消息；第二段是航图讨论。按目录翻段，再读原话。")],
            updatedAt: start, closedThrough: nodeIds[11]), in: root)
        let item = TimelineDayRecord.Item(kind: .segment, conversationId: conversationId, window: "云桥城", title: "岚舟和星砚讨论航图",
                                          start: start, end: start.addingTimeInterval(660), from: nil, to: nil)
        try TimelineStore.save(.init(days: [.init(date: "2026-10-31", headline: "云桥城航图", items: [item])]),
                               month: "2026-10", in: TimelineStore.dir(root: root))
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        let card = SeedNoteCard(path: "memory/cc/星砚.md", version: "v1", name: "星砚", layer: "CC", title: "星砚的航图",
            gist: "星砚和岚舟在云桥城画航图。", mentions: [], aboutUser: false, group: "人", when: [], model: "fictional",
            madeAt: start, run: .init(path: ".runs/fictional.md"))
        let cards = SeedNoteStore(wiki: wiki)
        try cards.saveOriginal(path: card.path, version: card.version, text: originalKeyword + "：岚舟、星砚和林栖共同画好航图。", sourceContext: nil)
        try cards.save(card)
        try wiki.save(WikiPage(path: "人/星砚", kind: .person, hook: "星砚的云桥城航图", title: "星砚", now: "星砚正在云桥城画航图。",
            records: ["星砚的航图记录（\(card.path)）", "林栖和岚舟一起看航图。"], entries: [card.path + "|v1"]))
    }
}

private struct KeywordOnlyEmbedder: MemoryEmbedding {
    var isReady: Bool { false }
    var revision: Int { 0 }
    func embed(_ text: String) -> [Float]? { nil }
}
