import XCTest
import SwiftData
import Network
@testable import 记忆花园

/// BUG-1（codex QA）：全新安装第一条消息就被自己的保险闸拦死。
///
/// 根因不是「新 provider 继承了开关」——预算是**全局**的（`GlobalBudgetStore` 类注释：
/// 所有 provider 汇总一份总账），压根没有 per-provider 继承这回事。真正是两条撞在一起：
///   1. `enabled` 默认 true（粟粟决策：保险闸默认开）
///   2. `budgetUSD` = `UserDefaults.double(forKey:)`，**key 不存在也返回 0**
/// 而闸门把 `budget <= 0` 判成「未拨款一律拦截」→ 装完就全拦。
///
/// 修法：把「从未拨过款」和「明确填了 0」分开（`GlobalBudgetStore.isBudgetSet`）。
/// T6c（粟粟 08-27 拍）：从未拨款不是「不限」，是**按默认 10 美元计闸**。
final class BudgetGateTests: XCTestCase {

    private final class NonStreamToolProvider: BaseChatProvider {
        override func parseNonStreamBody(_ data: Data) throws -> NonStreamResult {
            NonStreamResult(
                text: "",
                toolCalls: [ToolCallBlock(id: "nonstream", name: "fs_read", argumentsJSON: #"{"path":"a.txt"}"#)],
                usage: TokenUsage(inputTokens: 31, outputTokens: 7)
            )
        }
    }

    private final class ToolLoopHTTPServer {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "BudgetGateTests.ToolLoopHTTPServer")
        private let lock = NSLock()
        private let responseBuilder: (Int, Data) -> Data
        private(set) var requestBodies: [Data] = []
        private(set) var spentAtRequestStart: [Double] = []

        init(responseBuilder: @escaping (Int, Data) -> Data) throws {
            self.responseBuilder = responseBuilder
            listener = try NWListener(using: .tcp, on: .any)
        }

        var baseURL: String {
            "http://127.0.0.1:\(listener.port!.rawValue)/v1"
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requestBodies.count
        }

        func start() throws {
            let ready = DispatchSemaphore(value: 0)
            var startError: Error?
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    ready.signal()
                case .failed(let error):
                    startError = error
                    ready.signal()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.receive(on: connection, accumulated: Data())
                connection.start(queue: self?.queue ?? .global())
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 2) == .success else {
                throw URLError(.timedOut)
            }
            if let startError { throw startError }
        }

        func stop() {
            listener.cancel()
        }

        private func receive(on connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                var accumulated = accumulated
                if let data { accumulated.append(data) }
                if let body = Self.completeBody(from: accumulated) {
                    self.respond(on: connection, requestBody: body)
                } else if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, accumulated: accumulated)
                }
            }
        }

        private static func completeBody(from request: Data) -> Data? {
            let separator = Data("\r\n\r\n".utf8)
            guard let headerRange = request.range(of: separator) else { return nil }
            let headerData = request[..<headerRange.lowerBound]
            let header = String(decoding: headerData, as: UTF8.self)
            let contentLength = header
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let bodyStart = headerRange.upperBound
            guard request.distance(from: bodyStart, to: request.endIndex) >= contentLength else { return nil }
            return request.subdata(in: bodyStart..<(bodyStart + contentLength))
        }

        private func respond(on connection: NWConnection, requestBody: Data) {
            lock.lock()
            let index = requestBodies.count
            requestBodies.append(requestBody)
            spentAtRequestStart.append(GlobalBudgetStore.shared.spentUSD)
            lock.unlock()

            let body = responseBuilder(index, requestBody)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private struct BudgetSnapshot {
        let enabled: Bool
        let isBudgetSet: Bool
        let budgetUSD: Double
        let spentUSD: Double
    }

    private struct ToolLoopFixture {
        let container: ModelContainer
        let context: ModelContext
        let viewModel: ConversationViewModel
        let providerManager: ProviderManager
        let model: ProviderModel
        let profile: Profile
        let preset: Preset
        let conversationId: String
        let credentialId: String
    }

    private func isolateBudget(limit: Double = 100) -> BudgetSnapshot {
        let store = GlobalBudgetStore.shared
        let snapshot = BudgetSnapshot(
            enabled: store.enabled,
            isBudgetSet: store.isBudgetSet,
            budgetUSD: store.budgetUSD,
            spentUSD: store.spentUSD
        )
        store.setEnabled(true)
        store.setBudgetUSD(limit)
        store.resetSpent()
        return snapshot
    }

    private func restoreBudget(_ snapshot: BudgetSnapshot) {
        let store = GlobalBudgetStore.shared
        store.setEnabled(snapshot.enabled)
        if snapshot.isBudgetSet {
            store.setBudgetUSD(snapshot.budgetUSD)
        } else {
            store.clearBudget()
        }
        store.resetSpent()
        store.commitSpend(snapshot.spentUSD)
    }

    @MainActor
    private func makeToolLoopFixture(baseURL: String, maxTokens: Int = 4096) throws -> ToolLoopFixture {
        let schema = ProfileManager.makeFullSchema()
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let credentialId = "xctest-tool-loop-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "gpt-4o", name: "Tool Loop Test")
        let credential = APICredential(
            id: credentialId,
            name: "Tool Loop Test",
            emoji: "🧪",
            type: .openaiCompatible,
            baseURL: baseURL,
            models: [model],
            toolsSupported: true
        )
        let providerManager = ProviderManager()
        providerManager.addCredential(credential)
        providerManager.setApiKey("test-key", for: credentialId)

        let profile = Profile(
            id: "xctest-tool-loop-profile",
            name: "Test",
            emoji: "🧪",
            description: "",
            userName: "User",
            assistantName: "Assistant"
        )
        var preset = Preset.balanced
        preset.sampling.maxTokens = maxTokens
        preset.prompts = preset.prompts.map { slot in
            var slot = slot
            if slot.id == PromptSlot.mainId { slot.content = "Answer briefly." }
            return slot
        }

        let viewModel = ConversationViewModel()
        viewModel.startDraftConversation(profileId: profile.id)
        let conversationId = try XCTUnwrap(viewModel.selectedConversation?.id)
        viewModel.selectedConversation?.memoryEnabled = false

        return ToolLoopFixture(
            container: container,
            context: context,
            viewModel: viewModel,
            providerManager: providerManager,
            model: model,
            profile: profile,
            preset: preset,
            conversationId: conversationId,
            credentialId: credentialId
        )
    }

    private func cleanUp(_ fixture: ToolLoopFixture) {
        fixture.providerManager.removeCredential(id: fixture.credentialId)
    }

    @MainActor
    private func waitForTurnToFinish(_ viewModel: ConversationViewModel, timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.assistantTurnInFlight, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(viewModel.assistantTurnInFlight, "tool loop did not finish before timeout")
    }

    private func assistantNode(in fixture: ToolLoopFixture) throws -> MessageNode {
        let conversationId = fixture.conversationId
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate { $0.conversationId == conversationId }
        )
        return try XCTUnwrap(try fixture.context.fetch(descriptor).first { $0.role == "assistant" })
    }

    private static func jsonLine(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func openAIToolResponse(index: Int, usage: TokenUsage?) -> Data {
        let arguments = "{\"path\":\"missing-\(index).txt\"}"
        let toolChunk: [String: Any] = [
            "choices": [[
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call-\(index)",
                        "function": ["name": "fs_read", "arguments": arguments],
                    ]],
                ],
            ]],
        ]
        var lines = ["data: \(jsonLine(toolChunk))"]
        if let usage {
            lines.append("data: \(jsonLine(["choices": [], "usage": ["prompt_tokens": usage.inputTokens, "completion_tokens": usage.outputTokens]]))")
        }
        lines.append("data: [DONE]")
        return Data((lines.joined(separator: "\n") + "\n\n").utf8)
    }

    private static func openAIToolCallResponse(index: Int, name: String, arguments: String) -> Data {
        let toolChunk: [String: Any] = [
            "choices": [[
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call-\(index)",
                        "function": ["name": name, "arguments": arguments],
                    ]],
                ],
            ]],
        ]
        return Data((["data: \(jsonLine(toolChunk))", "data: [DONE]"].joined(separator: "\n") + "\n\n").utf8)
    }

    private static func openAIFinalResponse(_ text: String, usage: TokenUsage) -> Data {
        let textChunk: [String: Any] = ["choices": [["delta": ["content": text]]]]
        let usageChunk: [String: Any] = [
            "choices": [],
            "usage": ["prompt_tokens": usage.inputTokens, "completion_tokens": usage.outputTokens],
        ]
        return Data(([
            "data: \(jsonLine(textChunk))",
            "data: \(jsonLine(usageChunk))",
            "data: [DONE]",
        ].joined(separator: "\n") + "\n\n").utf8)
    }

    private func requestJSON(_ server: ToolLoopHTTPServer, at index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: server.requestBodies[index]) as? [String: Any])
    }

    private func textSegments(_ node: MessageNode) -> [String] {
        (node.segments ?? []).compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }
    }

    private func toolResultCount(_ node: MessageNode) -> Int {
        (node.segments ?? []).filter {
            if case .toolResult = $0 { return true }
            return false
        }.count
    }

    /// B4 工具结果外置（plan-B4 D5）：非 fs_read 的大结果在 loop 收口点被截——下一轮请求里的 tool content
    /// 只带头 2000 行 + 续读尾注，全文在 tool-results/，气泡 seg 与回灌同文本。
    @MainActor
    func testOversizedToolResultIsOffloadedBeforeNextRound() async throws {
        // #033：夹具写盘 / 末尾核存档是测试自己站主线程，豁免；中间的真实发送 + 工具循环不豁免（R2 sol I1）
        MainThreadIO.allowMainThreadInThisTest()
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            if index == 0 {
                return Self.openAIToolCallResponse(index: 0, name: "fs_search", arguments: #"{"keyword":"needle"}"#)
            }
            return Self.openAIFinalResponse("done", usage: TokenUsage(inputTokens: 10, outputTokens: 2))
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL)
        defer { cleanUp(fixture) }
        let profileId = fixture.profile.id
        try FileLibraryStore.write("b4-big.txt", content: (1...3000).map { "needle \($0)" }.joined(separator: "\n"), profileId: profileId)
        defer {
            try? FileLibraryStore.delete("b4-big.txt", profileId: profileId)
            try? FileManager.default.removeItem(at: FileLibraryStore.toolResultsRoot(profileId: profileId))
        }

        MainThreadIO.allowMainThreadInThisTest(false)
        XCTAssertTrue(fixture.viewModel.sendMessage(
            "search",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)
        MainThreadIO.allowMainThreadInThisTest()

        XCTAssertEqual(server.requestCount, 2)
        let messages = try XCTUnwrap(requestJSON(server, at: 1)["messages"] as? [[String: Any]])
        let toolMessage = try XCTUnwrap(messages.last { ($0["role"] as? String) == "tool" })
        let content = try XCTUnwrap(toolMessage["content"] as? String)
        XCTAssertTrue(content.contains("[已截断：显示第 1–2000 行 / 共 3000 行（2000 行上限）"), content.suffix(300).description)
        XCTAssertLessThanOrEqual(ToolResultOffload.splitLines(content).count, 2003, "回灌只带头 2000 行 + 尾注")
        let path = try XCTUnwrap(ToolResultOffload.embeddedPath(in: content))
        XCTAssertEqual(ToolResultOffload.splitLines(try FileLibraryStore.toolResultRead(path, profileId: profileId)).count, 3000, "全文在存档里")

        let node = try assistantNode(in: fixture)
        let segText = (node.segments ?? []).compactMap { seg -> String? in
            if case .toolResult(_, let t, _, _) = seg { return t }
            return nil
        }.first
        XCTAssertEqual(segText, content, "气泡里的 seg 与回灌同一份文本")
    }

    /// 全新安装：闸门开着、从未拨款 → 按默认 10 计闸，第一条消息**放行**
    func testFreshInstallUsesDefaultBudgetInsteadOfBlocking() {
        XCTAssertEqual(GlobalBudgetStore.defaultBudgetUSD, 10, "粟粟 08-27 拍的默认额度")
        let gate = BudgetCalculator.gate(
            enabled: true, isBudgetSet: false, budgetUSD: 0, spentUSD: 0, estimatedCost: 0.01
        )
        XCTAssertEqual(gate, .ok, "装完第一条消息不能被自己的保险闸拦死")
    }

    /// 从未拨款**不是不限**：花超默认 10 照样拦，报的额度是 10 不是 0
    func testNeverFundedStillBlocksPastDefaultBudget() {
        XCTAssertEqual(
            BudgetCalculator.gate(enabled: true, isBudgetSet: false, budgetUSD: 0, spentUSD: 9.95, estimatedCost: 0.1),
            .blocked(spent: 9.95, budget: 10)
        )
        if case .warning(_, _, let budget) = BudgetCalculator.gate(
            enabled: true, isBudgetSet: false, budgetUSD: 0, spentUSD: 8.5, estimatedCost: 0.1
        ) {
            XCTAssertEqual(budget, 10, "警告文案里报的也得是有效额度 10")
        } else {
            XCTFail("过 80% 该 warning")
        }
    }

    /// 用户改过就按用户的——填的数**压过**默认 10，两个方向都要
    func testUserSetBudgetOverridesDefault() {
        // 填得比默认小：3 块钱花掉 2.9 就该拦（若还按 10 算会误放行）
        XCTAssertEqual(
            BudgetCalculator.gate(enabled: true, isBudgetSet: true, budgetUSD: 3, spentUSD: 2.9, estimatedCost: 0.2),
            .blocked(spent: 2.9, budget: 3)
        )
        // 填得比默认大：50 块钱花掉 20 该放行（若还按 10 算会误拦）
        XCTAssertEqual(
            BudgetCalculator.gate(enabled: true, isBudgetSet: true, budgetUSD: 50, spentUSD: 20, estimatedCost: 0.5),
            .ok
        )
    }

    /// **明确**填 0 = 「全停」，照拦（这条不能被上一条顺手放掉）
    func testExplicitZeroBudgetStillBlocks() {
        let gate = BudgetCalculator.gate(
            enabled: true, isBudgetSet: true, budgetUSD: 0, spentUSD: 0, estimatedCost: 0.01
        )
        XCTAssertEqual(gate, .blocked(spent: 0, budget: 0))
    }

    /// 拨了款照常计闸：没超放行、过 80% 警告、超了拦
    func testFundedBudgetStillGates() {
        XCTAssertEqual(
            BudgetCalculator.gate(enabled: true, isBudgetSet: true, budgetUSD: 10, spentUSD: 1, estimatedCost: 0.5),
            .ok
        )
        if case .warning = BudgetCalculator.gate(
            enabled: true, isBudgetSet: true, budgetUSD: 10, spentUSD: 8.5, estimatedCost: 0.1
        ) {} else {
            XCTFail("过 80% 该 warning")
        }
        XCTAssertEqual(
            BudgetCalculator.gate(enabled: true, isBudgetSet: true, budgetUSD: 10, spentUSD: 9.9, estimatedCost: 0.2),
            .blocked(spent: 9.9, budget: 10)
        )
    }

    /// 开关关掉一律放行，跟拨没拨款无关
    func testDisabledSwitchAlwaysPasses() {
        XCTAssertEqual(
            BudgetCalculator.gate(enabled: false, isBudgetSet: true, budgetUSD: 0, spentUSD: 999, estimatedCost: 1),
            .disabled
        )
    }

    // MARK: - 工具轮 usage 终止路径

    @MainActor
    func testNonStreamToolTerminationRetainsUsage() async {
        let provider = NonStreamToolProvider()
        provider.rawBody = Data("{}".utf8)
        let callback = expectation(description: "non-stream tool callback")
        provider.onToolCalls = { _ in callback.fulfill() }

        provider.handleNonStreamBody()

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(provider.finalUsage, TokenUsage(inputTokens: 31, outputTokens: 7))
    }

    @MainActor
    func testOpenAIStreamToolTerminationRetainsUsage() async {
        let provider = OpenAICompatibleProvider()
        let callback = expectation(description: "OpenAI tool callback")
        provider.onToolCalls = { _ in callback.fulfill() }

        provider.processData(Self.openAIToolResponse(index: 0, usage: TokenUsage(inputTokens: 41, outputTokens: 9)))

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(provider.finalUsage, TokenUsage(inputTokens: 41, outputTokens: 9))
    }

    @MainActor
    func testAnthropicStreamToolTerminationRetainsUsage() async {
        let provider = AnthropicProvider()
        let callback = expectation(description: "Anthropic tool callback")
        provider.onToolCalls = { _ in callback.fulfill() }
        let stream = """
        event: message_start
        data: {"message":{"usage":{"input_tokens":53,"output_tokens":0}}}
        event: content_block_start
        data: {"index":0,"content_block":{"type":"tool_use","id":"anthropic","name":"fs_read"}}
        event: content_block_delta
        data: {"index":0,"delta":{"partial_json":"{\\"path\\":\\"a.txt\\"}"}}
        event: message_delta
        data: {"delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":11}}
        event: message_stop
        data: {}

        """

        provider.processData(Data(stream.utf8))

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(provider.finalUsage, TokenUsage(inputTokens: 53, outputTokens: 11))
    }

    @MainActor
    func testChatGPTOAuthRouterTerminationRetainsUsage() async {
        let provider = ChatGPTOAuthProvider()
        let callback = expectation(description: "ChatGPT OAuth tool callback")
        provider.onToolCalls = { _ in callback.fulfill() }
        let stream = "data: {\"type\":\"response.function_call.added\",\"item\":{\"id\":\"oauth-item\",\"call_id\":\"oauth-call\",\"name\":\"fs_read\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":67,\"output_tokens\":13}}}\n\n"

        provider.processData(Data(stream.utf8))

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(provider.finalUsage, TokenUsage(inputTokens: 67, outputTokens: 13))
    }

    @MainActor
    func testChatGPTOAuthRouterForwardsToolUsageOnceAndSuppressesTrailingComplete() async throws {
        let response = "data: {\"type\":\"response.function_call.added\",\"item\":{\"id\":\"oauth-item\",\"call_id\":\"oauth-call\",\"name\":\"fs_read\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":71,\"output_tokens\":17}}}\n\ndata: [DONE]\n\n"
        let server = try ToolLoopHTTPServer { _, _ in Data(response.utf8) }
        try server.start()
        defer { server.stop() }

        let credentialId = "xctest-oauth-router-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "gpt-test", name: "OAuth Router Test")
        let credential = APICredential(
            id: credentialId,
            name: "OAuth Router Test",
            emoji: "🔐",
            type: .chatgptOAuth,
            baseURL: server.baseURL,
            models: [model],
            toolsSupported: true
        )
        let providerManager = ProviderManager()
        providerManager.addCredential(credential)
        providerManager.setOAuthToken(
            OAuthTokenSet(accessToken: "test-token", refreshToken: "refresh", expiresAt: Date().timeIntervalSince1970 + 3600),
            for: credentialId
        )
        defer { providerManager.removeCredential(id: credentialId) }

        let callback = expectation(description: "router tool callback")
        var receivedUsage: TokenUsage?
        var completeCount = 0
        ProviderRouter().sendStreaming(
            model: model,
            messages: [(role: "user", content: "use tool")],
            systemPrompt: nil,
            providerManager: providerManager,
            onToken: { _ in },
            onComplete: { _, _ in completeCount += 1 },
            onError: { XCTFail($0) },
            onToolCalls: { _, usage in
                receivedUsage = usage
                callback.fulfill()
            }
        )

        await fulfillment(of: [callback], timeout: 2)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(receivedUsage, TokenUsage(inputTokens: 71, outputTokens: 17))
        XCTAssertEqual(completeCount, 0, "tool-call 已是本请求终止事件，后续 [DONE] 不能再走 onComplete 重复记账")
    }

    /// 非 OAuth 三条触发点（非流式整包 / OpenAI 流式 / Anthropic 流式）共用 router 里同一个
    /// `forwardedToolCalls` 适配器（读 provider.finalUsage）。这条锁的是那个适配器真把 usage 交出去。
    @MainActor
    func testOpenAIRouterForwardsToolUsageToCallback() async throws {
        let server = try ToolLoopHTTPServer { _, _ in
            Self.openAIToolResponse(index: 0, usage: TokenUsage(inputTokens: 83, outputTokens: 19))
        }
        try server.start()
        defer { server.stop() }

        let credentialId = "xctest-oai-router-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "gpt-4o", name: "OAI Router Test")
        let credential = APICredential(
            id: credentialId,
            name: "OAI Router Test",
            emoji: "🧪",
            type: .openaiCompatible,
            baseURL: server.baseURL,
            models: [model],
            toolsSupported: true
        )
        let providerManager = ProviderManager()
        providerManager.addCredential(credential)
        providerManager.setApiKey("test-key", for: credentialId)
        defer { providerManager.removeCredential(id: credentialId) }

        let callback = expectation(description: "openai router tool callback")
        var receivedUsage: TokenUsage?
        let router = ProviderRouter()
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "use tool")],
            systemPrompt: nil,
            providerManager: providerManager,
            onToken: { _ in },
            onComplete: { _, _ in XCTFail("有 tool_call 时不该走 onComplete") },
            onError: { XCTFail($0) },
            onToolCalls: { _, usage in
                receivedUsage = usage
                callback.fulfill()
            }
        )

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(receivedUsage?.inputTokens, 83)
        XCTAssertEqual(receivedUsage?.outputTokens, 19)
        XCTAssertNil(receivedUsage?.cacheReadTokens)
        XCTAssertNil(receivedUsage?.cacheWriteTokens)
        XCTAssertNil(receivedUsage?.cacheWrite1hTokens)
        XCTAssertNil(receivedUsage?.reasoningTokens)
        XCTAssertNil(receivedUsage?.webSearches)
        XCTAssertNil(receivedUsage?.reportedCostUSD)
        XCTAssertNil(receivedUsage?.responseId)
        XCTAssertEqual(receivedUsage?.completeness, .complete)
        XCTAssertEqual(receivedUsage?.ledgerSpendRecorded, true, "Router 已记账，调用方不能重复扣费")
    }

    // MARK: - 工具轮记账与 gate

    @MainActor
    func testThreeToolRoundsCommitEveryRequestUsingEstimateWhenUsageMissing() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            if index < 3 {
                return Self.openAIToolResponse(index: index, usage: nil)
            }
            return Self.openAIFinalResponse("final", usage: TokenUsage(inputTokens: 101, outputTokens: 17))
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL)
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage(
            "run tools",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 4, "3 次中间工具请求 + 1 次最终请求")
        let checkpoints = server.spentAtRequestStart
        XCTAssertEqual(checkpoints.count, 4)
        XCTAssertGreaterThan(checkpoints[1], checkpoints[0], "第 1 次工具请求缺 usage 也要用估算值扣费")
        XCTAssertGreaterThan(checkpoints[2], checkpoints[1], "第 2 次工具请求要独立扣费")
        XCTAssertGreaterThan(checkpoints[3], checkpoints[2], "第 3 次工具请求要独立扣费")
        XCTAssertGreaterThan(GlobalBudgetStore.shared.spentUSD, checkpoints[3], "最终请求是第 4 次扣费")
    }

    /// provider 实例跨轮复用（router 的 openAIProvider 是存储属性）。缺 usage 的那一轮必须按
    /// **本轮**估算扣（⧫ 宁可多扣），绝不能把上一轮的真实 usage 再算一遍。
    @MainActor
    func testMissingUsageRoundChargesEstimateNotPreviousRoundUsage() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            switch index {
            case 0: return Self.openAIToolResponse(index: index, usage: TokenUsage(inputTokens: 100, outputTokens: 10))
            case 1: return Self.openAIToolResponse(index: index, usage: nil)
            default: return Self.openAIFinalResponse("final", usage: TokenUsage(inputTokens: 130, outputTokens: 21))
            }
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL)
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage(
            "two tool rounds",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 3)
        let checkpoints = server.spentAtRequestStart
        XCTAssertEqual(checkpoints.count, 3)
        // 第 0 轮有 usage：按 (100,10) 精算，gpt-4o = $0.00035
        let round0 = checkpoints[1] - checkpoints[0]
        XCTAssertEqual(round0, 100.0 / 1_000_000 * 2.5 + 10.0 / 1_000_000 * 10, accuracy: 1e-9)
        // 第 1 轮没 usage：按本轮估算扣（output 按 maxTokens 4096 上限估 → 至少 $0.04），
        // 不是把第 0 轮那 $0.00035 再记一遍
        let round1 = checkpoints[2] - checkpoints[1]
        XCTAssertGreaterThan(round1, 4096.0 / 1_000_000 * 10, "缺 usage 要按本轮估算扣，不能沿用上一轮 usage")
    }

    @MainActor
    func testBudgetBlockBeforeSecondToolRoundPreservesResultsAndRunsGatedSummary() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            if index == 0 {
                GlobalBudgetStore.shared.setBudgetUSD(0.035)
                return Self.openAIToolResponse(index: index, usage: TokenUsage(inputTokens: 100, outputTokens: 10))
            }
            return Self.openAIFinalResponse("已根据现有结果收尾", usage: TokenUsage(inputTokens: 120, outputTokens: 20))
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL, maxTokens: 4096)
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage(
            "run one tool then summarize",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 2, "第 2 个请求只能是低预算收尾，不能继续工具循环")
        guard server.requestBodies.count > 1 else { return }
        let summaryRequest = try requestJSON(server, at: 1)
        XCTAssertNil(summaryRequest["tools"], "收尾请求不再下发工具")
        XCTAssertEqual(summaryRequest["max_tokens"] as? Int, 512, "收尾 gate 估算 512 token，实际请求也必须限制为 512")
        let summaryBody = String(decoding: server.requestBodies[1], as: UTF8.self)
        XCTAssertTrue(summaryBody.contains("基于已有工具结果"), "收尾请求要明确要求基于已有结果回答")
        let node = try assistantNode(in: fixture)
        XCTAssertEqual(toolResultCount(node), 1, "已执行的工具结果必须保留")
        XCTAssertTrue(textSegments(node).contains { $0.contains("预算不足") }, "节点上要有可见的停止原因")
    }

    @MainActor
    func testBudgetBlockEndsDirectlyWhenSummaryAlsoCannotFit() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            if index == 0 {
                GlobalBudgetStore.shared.setBudgetUSD(0)
            }
            return Self.openAIToolResponse(index: index, usage: TokenUsage(inputTokens: 100, outputTokens: 10))
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL)
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage(
            "run one tool",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 1, "收尾请求也过不了 gate 时不能再花钱")
        let node = try assistantNode(in: fixture)
        XCTAssertEqual(toolResultCount(node), 1)
        XCTAssertTrue(textSegments(node).contains { $0.contains("预算不足") })
        XCTAssertNotNil(fixture.viewModel.budgetBlockedMessage)
    }

    @MainActor
    func testToolRoundLimitExecutesEightBatchesAndUsesNinthRequestOnlyToDetectLimit() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            Self.openAIToolResponse(index: index, usage: TokenUsage(inputTokens: 20 + index, outputTokens: 5))
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL, maxTokens: 64)
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage(
            "keep calling tools",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 9, "8 轮工具后需要第 9 次模型请求确认是否收尾")
        let node = try assistantNode(in: fixture)
        XCTAssertEqual(toolResultCount(node), 8, "文案说 8 轮就只能真正执行 8 批工具")
        XCTAssertTrue(textSegments(node).contains { $0.contains("工具调用达到上限 8 轮") })
    }
}

// MARK: - 用量账本（research-magpie 2.1）：router 是所有聊天请求的汇合点，每个请求落一条

extension BudgetGateTests {
    private func ledgerFixture(_ server: ToolLoopHTTPServer) -> (ProviderManager, ProviderModel, String) {
        let credentialId = "xctest-ledger-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "gpt-4o", name: "Ledger Test")
        let providerManager = ProviderManager()
        providerManager.addCredential(APICredential(
            id: credentialId, name: "账本测试卡", emoji: "📒", type: .openaiCompatible,
            baseURL: server.baseURL, models: [model], toolsSupported: true
        ))
        providerManager.setApiKey("test-key", for: credentialId)
        return (providerManager, model, credentialId)
    }

    @MainActor
    func testRouterAppendsLedgerRecordForToolRoundAndFinal() async throws {
        let server = try ToolLoopHTTPServer { index, _ in
            index == 0
                ? Self.openAIToolResponse(index: 0, usage: TokenUsage(inputTokens: 83, outputTokens: 19))
                : Self.openAIFinalResponse("done", usage: TokenUsage(inputTokens: 120, outputTokens: 30))
        }
        try server.start()
        defer { server.stop() }
        let (providerManager, model, credentialId) = ledgerFixture(server)
        defer { providerManager.removeCredential(id: credentialId) }

        let ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).jsonl"))
        let router = ProviderRouter(usageContext: UsageContext(kind: .chat, conversationId: "conv-9", profileId: "p-9"))
        router.ledger = ledger

        for round in 0..<2 {
            let done = expectation(description: "round \(round)")
            router.sendStreaming(
                model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
                providerManager: providerManager,
                onToken: { _ in }, onComplete: { _, _ in done.fulfill() }, onError: { XCTFail($0) },
                onToolCalls: { _, _ in done.fulfill() }
            )
            await fulfillment(of: [done], timeout: 3)
        }

        let records = ledger.load()
        XCTAssertEqual(records.count, 2, "工具轮和最终轮各记一条")
        XCTAssertEqual(records.map(\.input), [83, 120])
        XCTAssertEqual(records.map(\.output), [19, 30])
        XCTAssertEqual(records.first?.kind, .chat)
        XCTAssertEqual(records.first?.conversationId, "conv-9")
        XCTAssertEqual(records.first?.profileId, "p-9")
        XCTAssertEqual(records.first?.providerId, credentialId)
        XCTAssertEqual(records.first?.providerName, "账本测试卡")
        XCTAssertEqual(records.first?.model, "gpt-4o")
        XCTAssertTrue(records.allSatisfy { $0.status == .ok })
    }

    @MainActor
    func testRouterRecordsErrorsAndNonStreamingCalls() async throws {
        let server = try ToolLoopHTTPServer { _, _ in Data("not json".utf8) }
        try server.start()
        defer { server.stop() }
        let (providerManager, model, credentialId) = ledgerFixture(server)
        defer { providerManager.removeCredential(id: credentialId) }

        let ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).jsonl"))
        let router = ProviderRouter(usageContext: UsageContext(kind: .dream, profileId: "p-1"))
        router.ledger = ledger
        _ = try? await router.sendNonStreaming(model: model, messages: [(role: "user", content: "hi")],
                                               systemPrompt: nil, providerManager: providerManager)
        let records = ledger.load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.status, .error)
        XCTAssertEqual(records.first?.kind, .dream)
    }

    @MainActor
    func testOpenAIStreamParsesReasoningTokens() async {
        let provider = OpenAICompatibleProvider()
        let callback = expectation(description: "tool callback")
        provider.onToolCalls = { _ in callback.fulfill() }
        var data = Self.openAIToolResponse(index: 0, usage: nil)
        let usageLine = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":40,\"completion_tokens_details\":{\"reasoning_tokens\":25}}}\n\n"
        data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "data: [DONE]", with: usageLine + "data: [DONE]").utf8)
        provider.processData(data)
        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(provider.finalUsage?.reasoningTokens, 25)
    }
}

// MARK: - 输出上限截断（plan-output-token-cap 2-7）

extension BudgetGateTests {
    private static func openAITruncatedToolResponse(index: Int) -> Data {
        let toolChunk: [String: Any] = [
            "choices": [[
                "delta": [
                    "tool_calls": [[
                        "index": 0,
                        "id": "call-\(index)",
                        "function": ["name": "fs_write", "arguments": "{\"path\":\"xctest-trunc-\(index).html\",\"content\":\"<html"],
                    ]],
                ],
            ]],
        ]
        let finishChunk: [String: Any] = ["choices": [["delta": [String: Any](), "finish_reason": "length"]]]
        return Data((["data: \(jsonLine(toolChunk))", "data: \(jsonLine(finishChunk))", "data: [DONE]"].joined(separator: "\n") + "\n\n").utf8)
    }

    @MainActor
    func testTruncatedToolCallIsNotExecutedAndTellsModelToSplit() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            index == 0
                ? Self.openAITruncatedToolResponse(index: index)
                : Self.openAIFinalResponse("改成分段写了", usage: TokenUsage(inputTokens: 10, outputTokens: 2))
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL)
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage(
            "write a long html",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 2)
        guard server.requestBodies.count > 1 else { return }
        let secondBody = String(decoding: server.requestBodies[1], as: UTF8.self)
        XCTAssertTrue(secondBody.contains("写到一半被截断"), "回灌给模型的是输出上限说明")
        XCTAssertTrue(secondBody.contains("16384"), "说明里带本轮实际上限（测试宿主自动档 = 16K）")
        let node = try assistantNode(in: fixture)
        let results = (node.segments ?? []).compactMap { seg -> String? in
            if case .toolResult(_, let text, _, _) = seg { return text }
            return nil
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.first?.contains("输出上限") == true)
        XCTAssertFalse(results.first?.contains("不是合法 JSON") == true, "在 preflight 之前就拦下，不回通用的 JSON 错误")
    }

    @MainActor
    func testTwoConsecutiveTruncatedRoundsStopTheLoop() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in Self.openAITruncatedToolResponse(index: index) }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL)
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage(
            "write a long html",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 2, "连续 2 轮截断就停，不空转到 8 轮")
        let node = try assistantNode(in: fixture)
        XCTAssertEqual(toolResultCount(node), 1)
        XCTAssertTrue(textSegments(node).contains { $0.contains("连续 2 轮工具参数超过输出上限") })
    }

    @MainActor
    func testBudgetSummaryStaysAt512ForExplicitAutoPreset() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            if index == 0 {
                GlobalBudgetStore.shared.setBudgetUSD(0.035)
                return Self.openAIToolResponse(index: index, usage: TokenUsage(inputTokens: 100, outputTokens: 10))
            }
            return Self.openAIFinalResponse("收尾", usage: TokenUsage(inputTokens: 120, outputTokens: 20))
        }
        try server.start()
        defer { server.stop() }
        var fixture = try makeToolLoopFixture(baseURL: server.baseURL, maxTokens: 8192)
        defer { cleanUp(fixture) }
        var preset = fixture.preset
        preset.sampling.maxTokensAuto = true
        fixture = ToolLoopFixture(container: fixture.container, context: fixture.context, viewModel: fixture.viewModel,
                                  providerManager: fixture.providerManager, model: fixture.model, profile: fixture.profile,
                                  preset: preset, conversationId: fixture.conversationId, credentialId: fixture.credentialId)

        XCTAssertTrue(fixture.viewModel.sendMessage(
            "run one tool then summarize",
            model: fixture.model,
            profile: fixture.profile,
            preset: fixture.preset,
            providerManager: fixture.providerManager,
            context: fixture.context
        ))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 2)
        guard server.requestBodies.count > 1 else { return }
        XCTAssertEqual(try requestJSON(server, at: 0)["max_tokens"] as? Int, 16_384, "自动档首轮按兜底 16K 实发")
        XCTAssertEqual(try requestJSON(server, at: 1)["max_tokens"] as? Int, 512, "自动档预设的收尾也必须限制为 512")
    }
}

// MARK: - #069 收进「更多工具」的内建工具：整条 tool loop（复用上面的假服务 / 夹具）

extension BudgetGateTests {

    @MainActor
    private func runOneToolRound(name: String, arguments: String) async throws -> (server: ToolLoopHTTPServer, node: MessageNode) {
        let server = try ToolLoopHTTPServer { index, _ in
            index == 0
                ? Self.openAIToolCallResponse(index: 0, name: name, arguments: arguments)
                : Self.openAIFinalResponse("好", usage: TokenUsage(inputTokens: 10, outputTokens: 2))
        }
        try server.start()
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL)
        defer { cleanUp(fixture) }
        XCTAssertTrue(fixture.viewModel.sendMessage("go", model: fixture.model, profile: fixture.profile, preset: fixture.preset,
                                                    providerManager: fixture.providerManager, context: fixture.context))
        await waitForTurnToFinish(fixture.viewModel)
        server.stop()
        return (server, try assistantNode(in: fixture))
    }

    /// 改工具总开关前快照新旧两个键，返回还原闭包（setLevel 两个都写）
    private func snapshotToolsMaster() -> () -> Void {
        let keys = [PermissionDomain.toolsMaster.storageKey, PermissionDomain.toolsMaster.legacy.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        return {
            for (k, v) in zip(keys, saved) {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }
    }

    private func toolMessage(_ server: ToolLoopHTTPServer) throws -> (call: [String: Any], result: String) {
        let messages = try XCTUnwrap(requestJSON(server, at: 1)["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.last { ($0["role"] as? String) == "assistant" })
        let call = try XCTUnwrap((assistant["tool_calls"] as? [[String: Any]])?.first)
        let tool = try XCTUnwrap(messages.last { ($0["role"] as? String) == "tool" })
        return (call, try XCTUnwrap(tool["content"] as? String))
    }

    /// 包着调收起来的工具：执行真工具、卡片显示真工具；回给模型的调用记录仍是 tool_invoke
    @MainActor
    func testInvokeWrappedTuckedToolRunsRealTool() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let restoreToolsMaster = snapshotToolsMaster()
        defer { restoreToolsMaster() }
        PermissionCenter.setLevel(.bypass, for: .toolsMaster)
        let (server, node) = try await runOneToolRound(name: MetaTools.invokeName,
                                                       arguments: #"{"name":"device_info","arguments":{"kind":"storage"}}"#)
        XCTAssertEqual(server.requestCount, 2)
        guard server.requestCount > 1 else { return }
        let (call, result) = try toolMessage(server)
        XCTAssertEqual((call["function"] as? [String: Any])?["name"] as? String, MetaTools.invokeName, "协议记录保持原样")
        XCTAssertFalse(result.contains("找不到工具"), result)
        let useNames = (node.segments ?? []).compactMap { seg -> String? in
            if case .toolUse(_, let name, _, _, _) = seg { return name }
            return nil
        }
        XCTAssertEqual(useNames, [DeviceInfoTool.toolName], "聊天卡片显示真工具")
    }

    @MainActor
    func testInvokeWrappedWithNonObjectArgumentsIsRejected() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let (server, _) = try await runOneToolRound(name: MetaTools.invokeName,
                                                    arguments: #"{"name":"device_info","arguments":"storage"}"#)
        guard server.requestCount > 1 else { return XCTFail("没有第二轮") }
        XCTAssertTrue(try toolMessage(server).result.contains("arguments 要是一个对象"))
    }

    /// 常用工具不许包着调：tool_invoke(recall) 回说明、不执行
    @MainActor
    func testInvokeWrappingInlineToolIsRefused() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let (server, _) = try await runOneToolRound(name: MetaTools.invokeName,
                                                    arguments: #"{"name":"recall","arguments":{"query":"复诊"}}"#)
        guard server.requestCount > 1 else { return XCTFail("没有第二轮") }
        XCTAssertTrue(try toolMessage(server).result.contains("不在「更多工具」里"))
    }

    /// 执行前复查：记忆总开关关着，照着历史直接叫 remember 不执行
    @MainActor
    func testDirectCallToDisabledBuiltinIsRefused() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let d = UserDefaults.standard
        let saved = d.object(forKey: "mem_master")
        d.set(false, forKey: "mem_master")
        defer { if let saved { d.set(saved, forKey: "mem_master") } else { d.removeObject(forKey: "mem_master") } }
        let (server, _) = try await runOneToolRound(name: SelfMemoryTool.rememberName,
                                                    arguments: #"{"name":"x","description":"x","body":"x"}"#)
        guard server.requestCount > 1 else { return XCTFail("没有第二轮") }
        XCTAssertEqual(try toolMessage(server).result, ConversationViewModel.toolUnavailableMessage(name: SelfMemoryTool.rememberName))
        let firstTools = (try requestJSON(server, at: 0)["tools"] as? [[String: Any]] ?? [])
            .compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertFalse(firstTools.contains(SelfMemoryTool.rememberName))
    }

    /// 收起来的工具不进清单，〔更多工具〕段列出来；元工具在清单里；tool_search 搜得到收起来的内建
    @MainActor
    func testTuckedToolsLeaveTheListAndAppearInHint() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let restoreToolsMaster = snapshotToolsMaster()
        defer { restoreToolsMaster() }
        PermissionCenter.setLevel(.bypass, for: .toolsMaster)
        let (server, _) = try await runOneToolRound(name: MetaTools.searchName, arguments: #"{"query":"图片"}"#)
        guard server.requestCount > 1 else { return XCTFail("没有第二轮") }
        let first = try requestJSON(server, at: 0)
        let names = (first["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertFalse(names.contains(DeviceInfoTool.toolName))
        XCTAssertFalse(names.contains(OCRImageTool.toolName))
        XCTAssertTrue(names.contains(MetaTools.invokeName))
        let system = ((first["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(system.contains("〔更多工具〕"))
        XCTAssertTrue(system.contains("- device_info — "))
        XCTAssertTrue(try toolMessage(server).result.contains("ocr_image"))
    }
}

extension BudgetGateTests {
    @MainActor
    func testOfficialCounterOnlyNearRemainingBudget() {
        XCTAssertTrue(BudgetPreflight.shouldRefine(enabled: true, budget: 10, spent: 8, estimated: 1.5))
        XCTAssertTrue(BudgetPreflight.shouldRefine(enabled: true, budget: 10, spent: 8, estimated: 2.5))
        XCTAssertFalse(BudgetPreflight.shouldRefine(enabled: true, budget: 10, spent: 8, estimated: 1.49))
        XCTAssertFalse(BudgetPreflight.shouldRefine(enabled: true, budget: 10, spent: 8, estimated: 2.51))
        XCTAssertFalse(BudgetPreflight.shouldRefine(enabled: false, budget: 10, spent: 8, estimated: 2))
        XCTAssertFalse(BudgetPreflight.shouldRefine(enabled: true, budget: 0, spent: 0, estimated: 0))
    }

    func testOfficialCountRequestKeepsInputAndFallsBackOnFailure() async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.setValue("Bearer fixture-not-a-key", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"model":"gpt-6.1-sol","messages":[{"role":"system","content":"规则"},{"role":"user","content":"问题"}],"max_tokens":20,"stream":true}"#.utf8)
        let counted = try XCTUnwrap(OfficialTokenCounter.request(from: request))
        XCTAssertEqual(counted.timeoutInterval, 2)
        XCTAssertEqual(counted.url?.path, "/v1/responses/input_tokens")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: counted.httpBody!) as? [String: Any])
        XCTAssertEqual((payload["input"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(payload["stream"])
        let success = await OfficialTokenCounter(fetch: { _ in Data(#"{"input_tokens":12}"#.utf8) }).count(request)
        XCTAssertEqual(success, 12)
        let failure = await OfficialTokenCounter(fetch: { _ in throw URLError(.timedOut) }).count(request)
        XCTAssertNil(failure)
        request.url = URL(string: "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertNil(OfficialTokenCounter.request(from: request))
        request.url = URL(string: "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(OfficialTokenCounter.request(from: request)?.url?.path, "/v1/messages/count_tokens")
    }
}
