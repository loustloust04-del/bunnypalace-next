import MemoryCore
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
        /// 第几次请求回什么状态码（默认都是 200；thinking 回传 astra #1 用它模拟思考块被拒）
        private let status: (Int) -> Int
        /// 回完不关连接、Content-Length 报大：客户端一直等后续字节（测「停止」用）
        var holdOpen = false
        private(set) var requestBodies: [Data] = []
        private(set) var spentAtRequestStart: [Double] = []

        init(status: @escaping (Int) -> Int = { _ in 200 }, responseBuilder: @escaping (Int, Data) -> Data) throws {
            self.responseBuilder = responseBuilder
            self.status = status
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
            let code = status(index)
            let header = code == 200
                ? "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.count + (holdOpen ? 1_000_000 : 0))\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 \(code) Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            response.append(body)
            let hold = holdOpen
            connection.send(content: response, completion: .contentProcessed { _ in
                if !hold { connection.cancel() }
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
    private func makeToolLoopFixture(baseURL: String, maxTokens: Int = 4096, type: ProviderType = .openaiCompatible,
                                     modelId: String = "gpt-4o") throws -> ToolLoopFixture {
        let schema = ProfileManager.makeFullSchema()
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let credentialId = "xctest-tool-loop-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: modelId, name: "Tool Loop Test")
        let credential = APICredential(
            id: credentialId,
            name: "Tool Loop Test",
            emoji: "🧪",
            type: type,
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
        PermissionCenter.setDefaultLevel(.bypass, for: .toolsMaster)
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

    /// 中转兼容 R8（审查 #1）：中转往骰子调用里塞 `_call`——执行器收到过滤后的参数，聊天卡片 / 回给模型的调用记录照原样
    @MainActor
    func testRelayInjectedArgumentsNeverReachExecutor() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        var executed: [(name: String, args: String)] = []
        ConversationViewModel.executionArgsTap = { executed.append(($0, $1)) }
        defer { ConversationViewModel.executionArgsTap = nil }
        let raw = #"{"dice":"1d6","_call":"relay-injected"}"#
        let (server, node) = try await runOneToolRound(name: DiceTool.toolName, arguments: raw)
        XCTAssertEqual(executed.map(\.name), [DiceTool.toolName])
        let args = try XCTUnwrap(executed.first?.args)
        XCTAssertFalse(args.contains("_call"), args)
        XCTAssertTrue(args.contains("1d6"), args)
        let history = (node.segments ?? []).compactMap { seg -> String? in
            if case .toolUse(_, _, let input, _, _) = seg { return input }
            return nil
        }
        XCTAssertEqual(history, [raw], "聊天卡片 / 历史照原样")
        guard server.requestCount > 1 else { return XCTFail("没有第二轮") }
        let (call, result) = try toolMessage(server)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, raw, "回给模型的调用记录照原样")
        XCTAssertTrue(result.contains("card-dice"), result)
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

    /// #093 工具抽屉里关了：直接叫 / 经 tool_invoke 包着叫都不执行，回「没开」；第一轮清单里没有它
    @MainActor
    func testDrawerOffBuiltinIsRefusedDirectAndWrapped() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let saved = ToolDrawerStore.shared.state
        defer { ToolDrawerStore.shared.update { $0 = saved } }
        ToolDrawerStore.shared.update { $0 = .defaults; $0.set(.off, for: DiceTool.toolName, profileId: nil) }
        for (name, args) in [(DiceTool.toolName, #"{"dice":"1d6"}"#),
                             (MetaTools.invokeName, #"{"name":"roll_dice","arguments":{"dice":"1d6"}}"#)] {
            let (server, _) = try await runOneToolRound(name: name, arguments: args)
            guard server.requestCount > 1 else { return XCTFail("\(name)：没有第二轮") }
            XCTAssertEqual(try toolMessage(server).result, ConversationViewModel.toolUnavailableMessage(name: DiceTool.toolName), name)
            let firstTools = (try requestJSON(server, at: 0)["tools"] as? [[String: Any]] ?? [])
                .compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            XCTAssertFalse(firstTools.contains(DiceTool.toolName), name)
        }
    }

    /// 收起来的工具不进清单，〔更多工具〕段列出来；元工具在清单里；tool_search 搜得到收起来的内建
    @MainActor
    func testTuckedToolsLeaveTheListAndAppearInHint() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let restoreToolsMaster = snapshotToolsMaster()
        defer { restoreToolsMaster() }
        PermissionCenter.setDefaultLevel(.bypass, for: .toolsMaster)
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

    // MARK: - thinking 回传（plan-thinking §3.2 / §3.3 / §3.9）：真走工具循环，假服务器回 Anthropic SSE

    private typealias SSE = ThinkingStreamTests

    private static func anthropicReply(_ blocks: [[String: Any]], stop: String) -> Data {
        var out = SSE.event("message_start", ["message": ["usage": ["input_tokens": 50, "output_tokens": 0]]])
        for (i, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "thinking":
                out += SSE.start(i, ["type": "thinking", "thinking": "", "signature": ""])
                if let t = block["thinking"] as? String, !t.isEmpty { out += SSE.delta(i, ["type": "thinking_delta", "thinking": t]) }
                out += SSE.delta(i, ["type": "signature_delta", "signature": block["signature"] as? String ?? ""])
            case "text":
                out += SSE.start(i, ["type": "text", "text": ""]) + SSE.delta(i, ["type": "text_delta", "text": block["text"] as? String ?? ""])
            case "tool_use":
                out += SSE.start(i, ["type": "tool_use", "id": block["id"] ?? "", "name": block["name"] ?? "", "input": [String: Any]()])
                let json = try! JSONSerialization.data(withJSONObject: block["input"] ?? [String: Any](), options: [.sortedKeys])
                out += SSE.delta(i, ["type": "input_json_delta", "partial_json": String(decoding: json, as: UTF8.self)])
            default:
                out += SSE.start(i, block)
            }
            out += SSE.stop(i)
        }
        out += SSE.event("message_delta", ["delta": ["stop_reason": stop], "usage": ["output_tokens": 20]])
        out += SSE.event("message_stop", [:])
        return Data(out.utf8)
    }

    private static let firstTurnBlocks: [[String: Any]] = [
        ["type": "thinking", "thinking": "先想", "signature": "sig-0"],
        ["type": "text", "text": "我查一下"],
        ["type": "thinking", "thinking": "", "signature": "sig-progress"],
        ["type": "tool_use", "id": "toolu_1", "name": "fs_read", "input": ["path": "missing-thinking.txt"]],
    ]

    private func assistantBlocks(_ server: ToolLoopHTTPServer, at index: Int) throws -> [[String: Any]] {
        let messages = try XCTUnwrap(requestJSON(server, at: index)["messages"] as? [[String: Any]])
        return try XCTUnwrap(messages.last { ($0["role"] as? String) == "assistant" }?["content"] as? [[String: Any]])
    }

    @MainActor
    func testAnthropicToolLoopEchoesThisTurnsBlocksVerbatim() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { index, _ in
            index == 0 ? Self.anthropicReply(Self.firstTurnBlocks, stop: "tool_use")
                : Self.anthropicReply([["type": "thinking", "thinking": "收尾", "signature": "sig-1"], ["type": "text", "text": "好了"]], stop: "end_turn")
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL, type: .anthropic, modelId: "claude-opus-5-5")
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage("读一下", model: fixture.model, profile: fixture.profile, preset: fixture.preset,
                                                    providerManager: fixture.providerManager, context: fixture.context))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 2)
        guard server.requestCount == 2 else { return }
        let echoed = try assistantBlocks(server, at: 1)
        XCTAssertEqual(echoed.map { $0["type"] as? String }, ["thinking", "text", "thinking", "tool_use"], "这一次回复的块全部原样回传")
        XCTAssertEqual(echoed.first?["thinking"] as? String, "先想")
        XCTAssertEqual(echoed.first?["signature"] as? String, "sig-0")
        XCTAssertEqual(echoed.dropFirst().first?["text"] as? String, "我查一下")
        XCTAssertEqual(echoed.dropFirst(2).first?["signature"] as? String, "sig-progress")
        XCTAssertEqual((echoed.last?["input"] as? [String: Any])?["path"] as? String, "missing-thinking.txt")
        XCTAssertEqual((try requestJSON(server, at: 0)["thinking"] as? [String: Any])?["type"] as? String, "adaptive", "默认档显式 adaptive")

        let node = try assistantNode(in: fixture)
        let kinds = (node.segments ?? []).map { seg -> String in
            switch seg {
            case .thinking(let t, let sig, _): return "thinking:\(t):\(sig ?? "nil")"
            case .text(let t): return "text:\(t)"
            case .toolUse: return "toolUse"
            case .toolResult: return "toolResult"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["thinking:先想:sig-0", "text:我查一下", "thinking::sig-progress", "toolUse", "toolResult",
                               "thinking:收尾:sig-1", "text:好了"])
        XCTAssertEqual(node.content, "好了")
    }

    @MainActor
    func testAnthropicPlainReplyStoresThinkingOnlySegments() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { _, _ in
            Self.anthropicReply([["type": "thinking", "thinking": "想一下", "signature": "sig"], ["type": "text", "text": "正文"]], stop: "end_turn")
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL, type: .anthropic, modelId: "claude-opus-5-5")
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage("你好", model: fixture.model, profile: fixture.profile, preset: fixture.preset,
                                                    providerManager: fixture.providerManager, context: fixture.context))
        await waitForTurnToFinish(fixture.viewModel)

        let node = try assistantNode(in: fixture)
        XCTAssertEqual(node.content, "正文")
        XCTAssertEqual(node.contentType, "text", "普通回复不变成 segmented")
        XCTAssertEqual(node.segments, [.text("正文"), .thinking(text: "想一下", signature: "sig")], "astra #4：正文段在前")
        XCTAssertFalse(node.segments?.hasRenderableSegments ?? true)
        XCTAssertEqual(ChatCardIndex.visibleText(content: node.content, segments: node.segments), "正文")
    }

    // MARK: - 模型兼容 P0 阶段 3 审查 #2：只有思考、没正文的回复也落库（[DONE] / EOF / 报错 / 停止）

    private static let thinkingOnlyLine = "data: " + jsonLine(["choices": [["delta": ["reasoning_content": "想到一半"]]]])

    @MainActor
    private func runThinkingOnly(_ lines: [String], stop: Bool = false, check: (MessageNode) -> Void) async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let server = try ToolLoopHTTPServer { _, _ in Data((lines.joined(separator: "\n\n") + "\n\n").utf8) }
        server.holdOpen = stop
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL)
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage("你好", model: fixture.model, profile: fixture.profile, preset: fixture.preset,
                                                    providerManager: fixture.providerManager, context: fixture.context))
        if stop {
            let deadline = Date().addingTimeInterval(5)
            while fixture.viewModel.providerRouter.lastReasoning == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertNotNil(fixture.viewModel.providerRouter.lastReasoning, "停止前已收到思考")
            fixture.viewModel.cancelAssistantTurn(context: fixture.context)
        }
        await waitForTurnToFinish(fixture.viewModel)
        check(try assistantNode(in: fixture))
    }

    @MainActor
    func testThinkTagOnlyThenDoneStoresThinking() async throws {
        let tag = "data: " + Self.jsonLine(["choices": [["delta": ["content": "<think>想到一半"]]]])
        try await runThinkingOnly([tag, "data: [DONE]"]) { node in
            XCTAssertEqual(node.content, "")
            XCTAssertEqual(node.segments, [.text(""), .thinking(text: "想到一半", signature: nil)])
            XCTAssertEqual(node.segments?.attachedThinkingText, "想到一半")
        }
    }

    @MainActor
    func testThinkingOnlyEOFStoresThinkingWithError() async throws {
        try await runThinkingOnly([Self.thinkingOnlyLine]) { node in
            XCTAssertTrue(node.content.hasPrefix("⚠️ "), node.content)
            XCTAssertEqual(node.segments, [.text(node.content), .thinking(text: "想到一半", signature: nil)])
        }
    }

    @MainActor
    func testThinkingThenStreamErrorStoresThinkingWithError() async throws {
        let error = "data: " + Self.jsonLine(["error": ["message": "上游炸了"]])
        try await runThinkingOnly([Self.thinkingOnlyLine, error, "data: [DONE]"]) { node in
            XCTAssertTrue(node.content.hasPrefix("⚠️ "), node.content)
            XCTAssertEqual(node.segments, [.text(node.content), .thinking(text: "想到一半", signature: nil)])
        }
    }

    @MainActor
    func testThinkingOnlyThenStopStoresThinking() async throws {
        try await runThinkingOnly([Self.thinkingOnlyLine], stop: true) { node in
            XCTAssertEqual(node.content, "（已停止）")
            XCTAssertEqual(node.segments, [.text("（已停止）"), .thinking(text: "想到一半", signature: nil)])
        }
    }

    @MainActor
    func testAskUserResumeCarriesThisTurnsBlocks() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let ask: [String: Any] = ["questions": [["question": "选哪个？", "options": ["甲", "乙"]]]]
        let server = try ToolLoopHTTPServer { index, _ in
            index == 0
                ? Self.anthropicReply([["type": "thinking", "thinking": "要问", "signature": "sig-ask"],
                                       ["type": "tool_use", "id": "toolu_ask", "name": AskUserTool.toolName, "input": ask]], stop: "tool_use")
                : Self.anthropicReply([["type": "text", "text": "收到"]], stop: "end_turn")
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL, type: .anthropic, modelId: "claude-opus-5-5")
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage("问我", model: fixture.model, profile: fixture.profile, preset: fixture.preset,
                                                    providerManager: fixture.providerManager, context: fixture.context))
        let deadline = Date().addingTimeInterval(8)
        while fixture.viewModel.pendingUserQuestion == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(fixture.viewModel.pendingUserQuestion, "ask_user 暂停")
        XCTAssertEqual(fixture.viewModel.pendingUserQuestion?.assistantContent?.first?["signature"] as? String, "sig-ask")
        fixture.viewModel.recordUserAnswer(.options([0]), at: 0)
        fixture.viewModel.completeActiveAskCard()
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 2)
        guard server.requestCount == 2 else { return }
        let echoed = try assistantBlocks(server, at: 1)
        XCTAssertEqual(echoed.map { $0["type"] as? String }, ["thinking", "tool_use"], "恢复时拼上暂停那次回复的原样块")
        XCTAssertEqual(echoed.first?["signature"] as? String, "sig-ask")
    }

    /// 保险闸：签名是密文不计字；开思考时期望输出 = 4096 + 这一档余量（Q9-A）
    func testPreflightSkipsSignatureAndAddsThinkingHeadroom() throws {
        func request(_ body: [String: Any]) throws -> URLRequest {
            var r = URLRequest(url: URL(string: "http://127.0.0.1:9/v1/messages")!)
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            return r
        }
        func messages(signature: String) -> [[String: Any]] {
            [["role": "user", "content": "hi"],
             ["role": "assistant", "content": [["type": "thinking", "thinking": "想", "signature": signature],
                                               ["type": "tool_use", "id": "t", "name": "fs_read", "input": ["path": "a"]]]],
             ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "r"]]]]
        }
        let short = try XCTUnwrap(BudgetPreflight.estimate(try request(["model": "claude-opus-5-5", "max_tokens": 36864,
                                                                        "messages": messages(signature: "s")])))
        let long = try XCTUnwrap(BudgetPreflight.estimate(try request(["model": "claude-opus-5-5", "max_tokens": 36864,
                                                                       "messages": messages(signature: String(repeating: "A", count: 20_000))])))
        XCTAssertEqual(short.input, long.input, "签名长度不影响估算")
        XCTAssertEqual(short.output, 4096, "没开思考照旧 4096")
        let adaptive = try XCTUnwrap(BudgetPreflight.estimate(try request(["model": "claude-opus-5-5", "max_tokens": 36864,
                                                                           "thinking": ["type": "adaptive"], "messages": messages(signature: "s")])))
        XCTAssertEqual(adaptive.output, 4096 + 4096, "adaptive 没写档 = 官方默认档（opus 5.5 medium）")
        let high = try XCTUnwrap(BudgetPreflight.estimate(try request(["model": "claude-opus-5-5", "max_tokens": 64000,
                                                                       "thinking": ["type": "adaptive"], "output_config": ["effort": "high"],
                                                                       "messages": messages(signature: "s")])))
        XCTAssertEqual(high.output, 4096 + 10000)
        let budget = try XCTUnwrap(BudgetPreflight.estimate(try request(["model": "claude-sonnet-4-5", "max_tokens": 5000,
                                                                         "thinking": ["type": "enabled", "budget_tokens": 4096],
                                                                         "messages": messages(signature: "s")])))
        XCTAssertEqual(budget.output, 5000, "不超过 max_tokens")
    }

    // MARK: - thinking 回传 · astra 一轮

    private func toolAssistantTypes(_ server: ToolLoopHTTPServer, at index: Int) throws -> [[String]] {
        let messages = try XCTUnwrap(requestJSON(server, at: index)["messages"] as? [[String: Any]])
        return messages.compactMap { msg -> [String]? in
            guard msg["role"] as? String == "assistant", let blocks = msg["content"] as? [[String: Any]],
                  blocks.contains(where: { $0["type"] as? String == "tool_use" }) else { return nil }
            return blocks.compactMap { $0["type"] as? String }
        }
    }

    /// astra #1：思考块被拒、去块重发成功后模型接着调工具——下一轮不能把被拒的块再带回来，新那一轮的思考照带
    @MainActor
    func testStrippedThinkingStaysStrippedForRestOfLoop() async throws {
        let budget = isolateBudget()
        defer { restoreBudget(budget) }
        let rejected = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block"}}"#.utf8)
        let server = try ToolLoopHTTPServer(status: { $0 == 1 ? 400 : 200 }) { index, _ in
            switch index {
            case 0: return Self.anthropicReply([["type": "thinking", "thinking": "A", "signature": "sig-A"],
                                                ["type": "tool_use", "id": "toolu_1", "name": "fs_read", "input": ["path": "x1.txt"]]], stop: "tool_use")
            case 1: return rejected
            case 2: return Self.anthropicReply([["type": "thinking", "thinking": "B", "signature": "sig-B"],
                                                ["type": "tool_use", "id": "toolu_2", "name": "fs_read", "input": ["path": "x2.txt"]]], stop: "tool_use")
            default: return Self.anthropicReply([["type": "text", "text": "完"]], stop: "end_turn")
            }
        }
        try server.start()
        defer { server.stop() }
        let fixture = try makeToolLoopFixture(baseURL: server.baseURL, type: .anthropic, modelId: "claude-opus-5-5")
        defer { cleanUp(fixture) }

        XCTAssertTrue(fixture.viewModel.sendMessage("读两个", model: fixture.model, profile: fixture.profile, preset: fixture.preset,
                                                    providerManager: fixture.providerManager, context: fixture.context))
        await waitForTurnToFinish(fixture.viewModel)

        XCTAssertEqual(server.requestCount, 4)
        guard server.requestCount == 4 else { return }
        XCTAssertEqual(try toolAssistantTypes(server, at: 1), [["thinking", "tool_use"]], "第一次续轮原样带（被拒）")
        XCTAssertEqual(try toolAssistantTypes(server, at: 2), [["tool_use"]], "去块重发")
        XCTAssertEqual(try toolAssistantTypes(server, at: 3), [["tool_use"], ["thinking", "tool_use"]],
                       "再下一轮：被拒的那轮一直不带，重发后新生成的思考照带")
        let node = try assistantNode(in: fixture)
        XCTAssertEqual(node.content, "完")
    }

    /// astra #3：回传的思考块按输入计——知道 thinking_tokens 直接加；不知道的能官方计数就强制计、不能就按签名字数保守估
    @MainActor
    func testPreflightCountsEchoedThinking() async throws {
        let sig = String(repeating: "S", count: 4000)
        let content: [[String: Any]] = [["type": "thinking", "thinking": "", "signature": sig],
                                        ["type": "tool_use", "id": "t", "name": "fs_read", "input": ["path": "a"]]]
        let calls = [ToolCallBlock(id: "t", name: "fs_read", argumentsJSON: #"{"path":"a"}"#)]
        let results = [ToolResultBlock(toolUseId: "t", text: "r", isError: false)]
        let known = BudgetPreflight.EchoedThinking([ToolTurn(calls: calls, results: results, assistantContent: content, thinkingTokens: 50_000)])
        XCTAssertEqual(known, BudgetPreflight.EchoedThinking(knownTokens: 50_000))
        let unknown = BudgetPreflight.EchoedThinking([ToolTurn(calls: calls, results: results, assistantContent: content)])
        XCTAssertEqual(unknown, BudgetPreflight.EchoedThinking(unknownSignatureChars: 4000))
        XCTAssertEqual(unknown.conservativeTokens, 1000)
        XCTAssertEqual(BudgetPreflight.EchoedThinking([ToolTurn(calls: calls, results: results, assistantContent: content, thinkingTokens: 9)
            .droppingThinking()]), BudgetPreflight.EchoedThinking(), "去了块就不算")

        func request(_ url: String) -> URLRequest {
            var r = URLRequest(url: URL(string: url)!)
            r.httpBody = try! JSONSerialization.data(withJSONObject: [
                "model": "claude-opus-5-5", "max_tokens": 1000,
                "messages": [["role": "user", "content": "hi"], ["role": "assistant", "content": content],
                             ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "r"]]]],
            ] as [String: Any])
            return r
        }
        let far = BudgetPreflight.State(enabled: true, isBudgetSet: true, budgetUSD: 1000, spentUSD: 0)
        // 不支持官方计数的端点（中转）：已知 token 直接加、未知按签名字数保守估
        let relay = request("https://relay.example.com/v1/messages")
        let base = try XCTUnwrap(BudgetPreflight.immediateDecision(relay, state: { far })).estimatedCost
        let withKnown = try XCTUnwrap(BudgetPreflight.immediateDecision(relay, echoed: known, state: { far })).estimatedCost
        let withUnknown = try XCTUnwrap(BudgetPreflight.immediateDecision(relay, echoed: unknown, state: { far })).estimatedCost
        XCTAssertGreaterThan(withKnown, base)
        XCTAssertGreaterThan(withUnknown, base)
        XCTAssertGreaterThan(withKnown, withUnknown)

        // 官方端点：离额度很远也强制走 count_tokens（未知 token 时）
        final class Calls: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let calls2 = Calls()
        let counter = OfficialTokenCounter(fetch: { _ in
            calls2.lock.withLock { calls2.n += 1 }
            return Data(#"{"input_tokens":200000}"#.utf8)
        })
        let official = request("https://api.anthropic.com/v1/messages")
        _ = await BudgetPreflight.decision(official, counter: counter, state: { far })
        XCTAssertEqual(calls2.n, 0, "没回传思考、离额度远：照旧不计数")
        let exact = await BudgetPreflight.decision(official, counter: counter, echoed: unknown, state: { far })
        XCTAssertEqual(calls2.n, 1, "回传了不知道 token 数的思考：强制官方计数")
        XCTAssertGreaterThan(exact.estimatedCost, base, "按官方计数的 200000 输入算")
        let off = BudgetPreflight.State(enabled: false, isBudgetSet: true, budgetUSD: 1000, spentUSD: 0)
        _ = await BudgetPreflight.decision(official, counter: counter, echoed: unknown, state: { off })
        XCTAssertEqual(calls2.n, 1, "保险闸关着不多发计数请求")
    }
}
