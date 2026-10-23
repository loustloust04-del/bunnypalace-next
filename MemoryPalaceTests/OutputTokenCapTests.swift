import XCTest
import Network
@testable import 记忆花园

/// plan-output-token-cap：自动上限 / 显式发 / max_completion_tokens / thinking 另加 / 保险闸脱钩 / 越界重试 / 截断检测。
/// 测试宿主里 ModelCatalog 为空 → 模型上限一律查不到，「自动」= 16K 兜底。
final class OutputTokenCapTests: XCTestCase {

    private static let unknownModel = "xctest-unknown-model"

    private func sampling(_ maxTokens: Int, auto: Bool? = nil, effort: String = "auto") -> SamplingParams {
        var s = SamplingParams()
        s.maxTokens = maxTokens
        s.maxTokensAuto = auto
        s.reasoningEffort = effort
        return s
    }

    // MARK: - 自动判定 / visibleCap / budgetEstimate

    func testAutoFlagLegacyRule() {
        XCTAssertTrue(sampling(4096).isMaxTokensAuto)
        XCTAssertFalse(sampling(8192).isMaxTokensAuto)
        XCTAssertTrue(sampling(8192, auto: true).isMaxTokensAuto)
        XCTAssertFalse(sampling(4096, auto: false).isMaxTokensAuto)
    }

    func testVisibleCap() {
        XCTAssertEqual(OutputTokenCap.visibleCap(sampling(4096), limit: 128_000), 32_768)
        XCTAssertEqual(OutputTokenCap.visibleCap(sampling(4096), limit: 16_384), 16_384)
        XCTAssertEqual(OutputTokenCap.visibleCap(sampling(4096), limit: nil), 16_384)
        XCTAssertEqual(OutputTokenCap.visibleCap(sampling(8192), limit: 16_384), 8192)
        XCTAssertEqual(OutputTokenCap.visibleCap(sampling(200_000), limit: 128_000), 128_000)
        XCTAssertEqual(OutputTokenCap.visibleCap(sampling(50_000), limit: nil), 50_000)
    }

    func testResolvedIsAlwaysManualConcreteNumber() {
        let r = OutputTokenCap.resolved(sampling(4096), modelId: Self.unknownModel)
        XCTAssertEqual(r.maxTokens, 16_384)
        XCTAssertEqual(r.maxTokensAuto, false)
        XCTAssertEqual(OutputTokenCap.resolved(r, modelId: Self.unknownModel).maxTokens, 16_384, "解析两次结果不变")
    }

    func testBudgetEstimate() {
        XCTAssertEqual(OutputTokenCap.budgetEstimate(sampling(4096), modelId: Self.unknownModel), 4096)
        XCTAssertEqual(OutputTokenCap.budgetEstimate(sampling(1000), modelId: Self.unknownModel), 1000)
        XCTAssertEqual(OutputTokenCap.budgetEstimate(sampling(64), modelId: Self.unknownModel), 64)
    }

    // MARK: - anthropicLimits

    func testAnthropicLimits() {
        func check(_ visible: Int, _ effort: String, _ limit: Int?, _ total: Int, _ budget: Int?, line: UInt = #line) {
            let r = OutputTokenCap.anthropicLimits(visible: visible, effort: effort, limit: limit)
            XCTAssertEqual(r.maxTokens, total, line: line)
            XCTAssertEqual(r.thinkingBudget, budget, line: line)
        }
        check(32_768, "auto", nil, 32_768, nil)
        check(32_768, "low", nil, 33_792, 1024)
        check(32_768, "high", nil, 42_768, 10_000)
        check(32_768, "high", 40_000, 40_000, 10_000)
        check(2048, "high", nil, 12_048, 10_000)
        check(512, "low", 1200, 512, nil)
    }

    // MARK: - Codable 迁移

    func testLegacyPresetJSONDecodesWithNilFlag() throws {
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([Preset.balanced])) as? [[String: Any]])
        var s = try XCTUnwrap(legacy[0]["sampling"] as? [String: Any])
        s.removeValue(forKey: "maxTokensAuto")
        legacy[0]["sampling"] = s
        let decoded = try JSONDecoder().decode([Preset].self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded[0].sampling.maxTokensAuto)
        XCTAssertTrue(decoded[0].sampling.isMaxTokensAuto)
    }

    func testFlagRoundTripsAndOldDecoderIgnoresIt() throws {
        var preset = Preset.balanced
        preset.sampling.maxTokensAuto = false
        let data = try JSONEncoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: data).sampling.maxTokensAuto, false)

        struct OldSampling: Decodable { var maxTokens: Int; var temperature: Double }
        struct OldPreset: Decodable { var id: String; var sampling: OldSampling }
        let old = try JSONDecoder().decode(OldPreset.self, from: data)
        XCTAssertEqual(old.sampling.maxTokens, 4096)
    }

    // MARK: - OpenAI 请求 body

    func testMaxTokensKeyByHost() {
        XCTAssertEqual(OpenAICompatibleProvider.maxTokensKey(baseURL: "https://api.openai.com/v1"), "max_completion_tokens")
        XCTAssertEqual(OpenAICompatibleProvider.maxTokensKey(baseURL: "https://openrouter.ai/api/v1"), "max_tokens")
        XCTAssertEqual(OpenAICompatibleProvider.maxTokensKey(baseURL: "https://api.deepseek.com"), "max_tokens")
    }

    func testOpenAIBodyAlwaysSendsCapUnderRightKey() {
        let resolved = OutputTokenCap.resolved(sampling(4096), modelId: Self.unknownModel)
        let plain = OpenAICompatibleProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: "m", systemPrompt: nil, samplingParams: resolved)
        XCTAssertEqual(plain["max_tokens"] as? Int, 16_384)
        XCTAssertNil(plain["max_completion_tokens"])

        let manual4096 = OpenAICompatibleProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: "m", systemPrompt: nil, samplingParams: sampling(4096, auto: false))
        XCTAssertEqual(manual4096["max_tokens"] as? Int, 4096, "4096 不再是「不发」的暗号")

        let official = OpenAICompatibleProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: "gpt-5", systemPrompt: nil, samplingParams: resolved,
            maxTokensKey: "max_completion_tokens")
        XCTAssertEqual(official["max_completion_tokens"] as? Int, 16_384)
        XCTAssertNil(official["max_tokens"])
    }

    func testOrderedOverloadForwardsKeyAndTemperatureDrop() {
        let ordered = [PromptMessage(role: "user", content: "hi", source: .chatHistory, nodeId: nil, pinnedToSystemPrefix: false)]
        let body = OpenAICompatibleProvider.buildRequestBody(
            ordered: ordered, model: "o3", samplingParams: sampling(8192), interleavedSystem: true,
            maxTokensKey: "max_completion_tokens", dropTemperature: true)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 8192)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
    }

    // MARK: - N4：OpenAI 官方推理模型不发 temperature

    func testDropsSamplingTemperature() {
        let official = "https://api.openai.com/v1"
        XCTAssertTrue(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: official, model: "gpt-5", reasoningEffort: "auto"))
        XCTAssertTrue(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: official, model: "o3", reasoningEffort: "auto"))
        XCTAssertTrue(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: official, model: "o4-mini", reasoningEffort: "auto"))
        XCTAssertTrue(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: official, model: "gpt-6-sol", reasoningEffort: "auto"))
        XCTAssertFalse(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: official, model: "gpt-4o", reasoningEffort: "auto"))
        XCTAssertFalse(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: official, model: "gpt-4.1-mini", reasoningEffort: "auto"))
        XCTAssertTrue(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: official, model: "gpt-4o", reasoningEffort: "high"),
                      "推理档不是 none 时一律去掉（官方 latest-model 指南）")
        XCTAssertFalse(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-5", reasoningEffort: "high"))
        XCTAssertFalse(OpenAICompatibleProvider.dropsSamplingTemperature(baseURL: "https://api.deepseek.com", model: "deepseek-reasoner", reasoningEffort: "auto"))

        let body = OpenAICompatibleProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: "gpt-5", systemPrompt: nil, samplingParams: sampling(4096),
            dropTemperature: true)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["top_p"])
        let kept = OpenAICompatibleProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: "gpt-4o", systemPrompt: nil, samplingParams: sampling(4096))
        XCTAssertEqual(kept["temperature"] as? Double, 0.7)
    }

    func testCatalogTemperatureFlagWins() throws {
        let json = #"{"openai":{"id":"openai","models":{"gpt-5.4-mini":{"id":"gpt-5.4-mini","name":"m","temperature":true,"limit":{"output":128000}},"o3":{"id":"o3","name":"o","temperature":false}}}}"#
        let models = try ModelCatalog.parse(modelsDevJSON: Data(json.utf8))
        let index = ModelCatalog.buildIndex(models)
        XCTAssertEqual(ModelCatalog.lookup("gpt-5.4-mini", in: index)?.temperature, true)
        XCTAssertEqual(ModelCatalog.lookup("o3", in: index)?.temperature, false)
    }

    func testOldCatalogCacheWithoutTemperatureStillDecodes() throws {
        let legacy = #"{"id":"x","providerId":"p","name":"x","contextTokens":1,"outputTokens":2,"reasoning":false,"reasoningEfforts":[]}"#
        let m = try JSONDecoder().decode(CatalogModel.self, from: Data(legacy.utf8))
        XCTAssertNil(m.temperature)
    }

    // MARK: - Anthropic body

    func testAnthropicBodyAddsThinkingOnTopOfVisibleCap() {
        let high = OutputTokenCap.resolved(sampling(4096, effort: "high"), modelId: Self.unknownModel)
        let body = AnthropicProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: Self.unknownModel, systemPrompt: nil, samplingParams: high)
        XCTAssertEqual(body["max_tokens"] as? Int, 16_384 + 10_000)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 10_000)

        let auto = OutputTokenCap.resolved(sampling(4096), modelId: Self.unknownModel)
        let plain = AnthropicProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: Self.unknownModel, systemPrompt: nil, samplingParams: auto)
        XCTAssertEqual(plain["max_tokens"] as? Int, 16_384)
        XCTAssertNil(plain["thinking"])
        XCTAssertEqual(plain["temperature"] as? Double, 0.7)
    }
}

// MARK: - 路由：越界重试（N1）+ 检查器预览

extension OutputTokenCapTests {
    final class ScriptedHTTPServer {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "OutputTokenCapTests.ScriptedHTTPServer")
        private let lock = NSLock()
        private let respond: (Int, Data) -> (status: Int, contentType: String, body: Data)
        private var bodies: [Data] = []

        init(respond: @escaping (Int, Data) -> (status: Int, contentType: String, body: Data)) throws {
            self.respond = respond
            listener = try NWListener(using: .tcp, on: .any)
        }

        var baseURL: String { "http://127.0.0.1:\(listener.port!.rawValue)/v1" }

        var requestBodies: [Data] { lock.withLock { bodies } }

        func start() throws {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.receive(on: connection, accumulated: Data())
                connection.start(queue: self?.queue ?? .global())
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 2) == .success else { throw URLError(.timedOut) }
        }

        func stop() { listener.cancel() }

        private func receive(on connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                var accumulated = accumulated
                if let data { accumulated.append(data) }
                if let body = Self.completeBody(from: accumulated) {
                    let index = self.lock.withLock { () -> Int in
                        self.bodies.append(body)
                        return self.bodies.count - 1
                    }
                    let r = self.respond(index, body)
                    let reason = r.status == 200 ? "OK" : "Bad Request"
                    var response = Data("HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(r.body)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                } else if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, accumulated: accumulated)
                }
            }
        }

        private static func completeBody(from request: Data) -> Data? {
            guard let headerRange = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let header = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
            let length = header.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let start = headerRange.upperBound
            guard request.distance(from: start, to: request.endIndex) >= length else { return nil }
            return request.subdata(in: start..<(start + length))
        }
    }

    static let capError = Data(#"{"error":{"message":"max_tokens is too large: 16384. This model supports at most 8192 completion tokens."}}"#.utf8)

    static func sse(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n\n").utf8)
    }

    static let okText = sse([
        #"data: {"choices":[{"delta":{"content":"ok"}}]}"#,
        #"data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":1}}"#,
        "data: [DONE]",
    ])

    private func routerFixture(_ server: ScriptedHTTPServer) -> (ProviderManager, ProviderModel, String) {
        let credentialId = "xctest-cap-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: Self.unknownModel, name: "Cap Test")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "上限测试卡", emoji: "✂️", type: .openaiCompatible,
                                       baseURL: server.baseURL, models: [model], toolsSupported: true))
        pm.setApiKey("test-key", for: credentialId)
        return (pm, model, credentialId)
    }

    private func body(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    func testRouterRetriesOnceAt8192WhenCapRejected() async throws {
        let server = try ScriptedHTTPServer { index, _ in
            index == 0 ? (400, "application/json", Self.capError) : (200, "text/event-stream", Self.okText)
        }
        try server.start()
        defer { server.stop() }
        let (pm, model, credentialId) = routerFixture(server)
        defer { pm.removeCredential(id: credentialId) }

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).jsonl"))
        let done = expectation(description: "complete")
        var text = ""
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
            providerManager: pm, samplingParams: sampling(4096),
            onToken: { _ in }, onComplete: { t, _ in text = t; done.fulfill() },
            onError: { XCTFail("不该报错：\($0)"); done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(text, "ok")
        XCTAssertEqual(server.requestBodies.count, 2)
        XCTAssertEqual(try body(server.requestBodies[0])["max_tokens"] as? Int, 16_384)
        XCTAssertEqual(try body(server.requestBodies[1])["max_tokens"] as? Int, 8192)
        XCTAssertEqual(router.ledger.load().map(\.status), [.error, .ok], "失败的那次也记账")
    }

    @MainActor
    func testRouterGivesUpAfterOneRetryAndAddsHint() async throws {
        let server = try ScriptedHTTPServer { _, _ in (400, "application/json", Self.capError) }
        try server.start()
        defer { server.stop() }
        let (pm, model, credentialId) = routerFixture(server)
        defer { pm.removeCredential(id: credentialId) }

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).jsonl"))
        let done = expectation(description: "error")
        var message = ""
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
            providerManager: pm, samplingParams: sampling(4096),
            onToken: { _ in }, onComplete: { _, _ in XCTFail("不该成功"); done.fulfill() },
            onError: { message = $0; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(server.requestBodies.count, 2, "只重试一次")
        XCTAssertTrue(message.contains("max_tokens is too large"), "保留上游原文")
        XCTAssertTrue(message.contains("本次输出上限 8192"), message)
    }

    @MainActor
    func testRouterDoesNotRetryWhenCapAlreadySmall() async throws {
        let server = try ScriptedHTTPServer { _, _ in (400, "application/json", Self.capError) }
        try server.start()
        defer { server.stop() }
        let (pm, model, credentialId) = routerFixture(server)
        defer { pm.removeCredential(id: credentialId) }

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).jsonl"))
        let done = expectation(description: "error")
        var message = ""
        router.sendStreaming(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
            providerManager: pm, samplingParams: sampling(6000),
            onToken: { _ in }, onComplete: { _, _ in done.fulfill() },
            onError: { message = $0; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(server.requestBodies.count, 1)
        XCTAssertTrue(message.contains("本次输出上限 6000"), message)
    }

    @MainActor
    func testPreviewBodyMatchesResolvedCap() throws {
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Self.okText) }
        let (pm, model, credentialId) = routerFixture(server)
        defer { pm.removeCredential(id: credentialId) }
        let body = try XCTUnwrap(ProviderRouter.previewRequestBody(
            model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
            providerManager: pm, samplingParams: sampling(4096)))
        XCTAssertEqual(body["max_tokens"] as? Int, 16_384, "检查器显示的就是实发的解析后上限")
    }
}

// MARK: - 保险闸：按期望输出预估

extension OutputTokenCapTests {
    @MainActor
    func testPreCheckBudgetUsesExpectedOutputNotFullCap() throws {
        let store = GlobalBudgetStore.shared
        let snapshot = (enabled: store.enabled, isSet: store.isBudgetSet, budget: store.budgetUSD, spent: store.spentUSD)
        defer {
            store.setEnabled(snapshot.enabled)
            if snapshot.isSet { store.setBudgetUSD(snapshot.budget) } else { store.clearBudget() }
            store.resetSpent()
            store.commitSpend(snapshot.spent)
        }
        store.setEnabled(true)
        store.setBudgetUSD(10)
        store.resetSpent()
        store.commitSpend(9)

        let credentialId = "xctest-cap-budget-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: credentialId, modelId: "claude-opus-4-7", name: "Opus")
        let pm = ProviderManager()
        pm.addCredential(APICredential(id: credentialId, name: "闸测试卡", emoji: "🧪", type: .anthropic,
                                       baseURL: "http://127.0.0.1:9/v1", models: [model], toolsSupported: true))
        defer { pm.removeCredential(id: credentialId) }
        let profile = Profile(id: "xctest-cap-profile", name: "T", emoji: "🧪", description: "", userName: "U", assistantName: "A")
        let vm = ConversationViewModel()

        for (maxTokens, auto) in [(4096, Optional<Bool>.none), (64_000, Optional(false)), (8192, Optional(true))] {
            var preset = Preset.balanced
            preset.sampling.maxTokens = maxTokens
            preset.sampling.maxTokensAuto = auto
            XCTAssertTrue(vm.preCheckBudget(text: "hi", model: model, profile: profile, preset: preset, providerManager: pm),
                          "maxTokens=\(maxTokens) auto=\(String(describing: auto))：预估按 ≤4096 算（Opus 约 $0.31），已花 $9 / $10 应放行")
        }
    }
}

// MARK: - 阶段 2：截断识别

extension OutputTokenCapTests {
    static let truncatedToolStream = sse([
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"fs_read","arguments":"{\"path\":\"a.txt\"}"}}]}}]}"#,
        #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"fs_write","arguments":"{\"path\":\"b.html\",\"content\":\"<html"}}]}}]}"#,
        #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#,
        "data: [DONE]",
    ])

    @MainActor
    func testOpenAIStreamLengthMarksLastToolCallTruncated() async {
        let provider = OpenAICompatibleProvider()
        let got = expectation(description: "tools")
        var calls: [ToolCallBlock] = []
        provider.onToolCalls = { calls = $0; got.fulfill() }
        provider.processData(Self.truncatedToolStream)
        await fulfillment(of: [got], timeout: 2)
        XCTAssertEqual(calls.map(\.name), ["fs_read", "fs_write"])
        XCTAssertEqual(calls.map(\.truncated), [false, true])
        XCTAssertTrue(provider.hitOutputLimit)
    }

    @MainActor
    func testOpenAIStreamNormalStopLeavesCallsIntact() async {
        let provider = OpenAICompatibleProvider()
        let got = expectation(description: "tools")
        var calls: [ToolCallBlock] = []
        provider.onToolCalls = { calls = $0; got.fulfill() }
        let data = String(decoding: Self.truncatedToolStream, as: UTF8.self).replacingOccurrences(of: "\"length\"", with: "\"tool_calls\"")
        provider.processData(Data(data.utf8))
        await fulfillment(of: [got], timeout: 2)
        XCTAssertEqual(calls.map(\.truncated), [false, false])
        XCTAssertFalse(provider.hitOutputLimit)
    }

    @MainActor
    func testAnthropicStreamMaxTokensDeliversTruncatedToolInsteadOfDroppingIt() async {
        let provider = AnthropicProvider()
        let got = expectation(description: "tools")
        var calls: [ToolCallBlock] = []
        provider.onToolCalls = { calls = $0; got.fulfill() }
        provider.onComplete = { _, _ in XCTFail("max_tokens 截断的 tool_use 不能被静默丢掉走 onComplete") }
        let data = Self.sse([
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"fs_write","input":{}}}"#,
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"a.html\",\"content\":\"<ht"}}"#,
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":100}}"#,
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
        ])
        provider.processData(data)
        await fulfillment(of: [got], timeout: 2)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.truncated, true)
        XCTAssertTrue(provider.hitOutputLimit)
    }

    func testNonStreamBodiesDetectOutputLimit() throws {
        let openAI = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"","tool_calls":[{"id":"a","function":{"name":"fs_read","arguments":"{}"}},{"id":"b","function":{"name":"fs_write","arguments":"{\"pa"}}]}}]}"#.utf8)
        let r1 = try OpenAICompatibleProvider().parseNonStreamBody(openAI)
        XCTAssertTrue(r1.hitOutputLimit)
        XCTAssertEqual(r1.toolCalls.map(\.truncated), [false, true])

        let anthropic = Data(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"写"},{"type":"tool_use","id":"t1","name":"fs_write","input":{"path":"a"}}]}"#.utf8)
        let r2 = try AnthropicProvider().parseNonStreamBody(anthropic)
        XCTAssertTrue(r2.hitOutputLimit)
        XCTAssertEqual(r2.toolCalls.map(\.truncated), [true], "max_tokens 时保留 calls（以前被清空）")

        let normal = Data(#"{"stop_reason":"end_turn","content":[{"type":"tool_use","id":"t1","name":"fs_write","input":{}}]}"#.utf8)
        let r3 = try AnthropicProvider().parseNonStreamBody(normal)
        XCTAssertFalse(r3.hitOutputLimit)
        XCTAssertTrue(r3.toolCalls.isEmpty)
    }

    @MainActor
    func testRouterReportsTextReplyHitOutputLimit() async throws {
        let truncatedText = Self.sse([
            #"data: {"choices":[{"delta":{"content":"很长的讲解……"}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#,
            "data: [DONE]",
        ])
        let server = try ScriptedHTTPServer { index, _ in
            (200, "text/event-stream", index == 0 ? truncatedText : Self.okText)
        }
        try server.start()
        defer { server.stop() }
        let (pm, model, credentialId) = routerFixture(server)
        defer { pm.removeCredential(id: credentialId) }

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).jsonl"))
        for expected in [true, false] {
            let done = expectation(description: "complete")
            router.sendStreaming(
                model: model, messages: [(role: "user", content: "hi")], systemPrompt: nil,
                providerManager: pm, samplingParams: sampling(4096),
                onToken: { _ in }, onComplete: { _, _ in done.fulfill() }, onError: { XCTFail($0); done.fulfill() }
            )
            await fulfillment(of: [done], timeout: 5)
            XCTAssertEqual(router.lastReplyHitOutputLimit, expected)
            XCTAssertEqual(router.lastRequestedMaxTokens, 16_384)
        }
    }

    // MARK: - Opus 4.7+ / 5 系：temperature / top_p / top_k 一律 400「deprecated for this model」

    func testAnthropicAdaptiveModelsDropSamplingParams() {
        var s = sampling(8192, effort: "none")
        s.temperature = 0.7; s.topP = 0.97; s.topK = 40
        for model in ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-4-7"] {
            for effort in ["none", "high"] {
                s.reasoningEffort = effort
                let body = AnthropicProvider.buildRequestBody(
                    messages: [(role: "user", content: "hi")], model: model, systemPrompt: nil, samplingParams: s)
                XCTAssertNil(body["temperature"], "\(model) \(effort)")
                XCTAssertNil(body["top_p"], "\(model) \(effort)")
                XCTAssertNil(body["top_k"], "\(model) \(effort)")
            }
        }
        s.reasoningEffort = "none"
        let kept = AnthropicProvider.buildRequestBody(
            messages: [(role: "user", content: "hi")], model: "claude-sonnet-4-6", systemPrompt: nil, samplingParams: s)
        XCTAssertEqual(kept["temperature"] as? Double, 0.7)
        XCTAssertEqual(kept["top_k"] as? Int, 40)
    }

    func testModelNotFoundErrorIsReadable() {
        XCTAssertEqual(BaseChatProvider.readableError(type: "not_found_error", message: "model: claude-sonnet-4-5"),
                       "这个 key 用不了模型 claude-sonnet-4-5（已下线或没开通），换一个模型试试")
        XCTAssertEqual(BaseChatProvider.readableError(type: "invalid_request_error", message: "x"), "x")
    }
}
