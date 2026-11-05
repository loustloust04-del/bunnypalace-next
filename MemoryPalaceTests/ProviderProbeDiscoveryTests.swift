import XCTest
@testable import 记忆花园

/// plan-provider-presets 阶段 2：/models 宽容解析 + 种子清单 + 元数据旁表。全部走 URLProtocol 桩，不出网。
final class ProviderProbeDiscoveryTests: XCTestCase {
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
        nonisolated(unsafe) static var seen: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Stub.seen.append(request)
            let url = request.url!
            let (code, body) = Stub.routes[url.absoluteString] ?? (404, "<html>not found</html>")
            let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var session: URLSession!
    private var hints: ModelHints!
    private var hintsDir: URL!
    private let key = "sk-test-000"

    /// OpenRouter `GET /api/v1/models` 的形状：按 openrouter.ai/docs/api-reference/list-available-models 文档字段构造，不是抓的真响应
    private let openRouterSample = #"""
    {"data":[
      {"id":"openai/gpt-4o","canonical_slug":"openai/gpt-4o","name":"OpenAI: GPT-4o","created":1715558400,
       "description":"GPT-4o","context_length":128000,
       "architecture":{"modality":"text+image->text","input_modalities":["text","image","file"],"output_modalities":["text"],"tokenizer":"GPT","instruct_type":null},
       "pricing":{"prompt":"0.0000025","completion":"0.00001","request":"0","image":"0"},
       "top_provider":{"context_length":128000,"max_completion_tokens":16384,"is_moderated":true},
       "per_request_limits":null,"supported_parameters":["tools","temperature"]},
      {"id":"deepseek/deepseek-chat","canonical_slug":"deepseek/deepseek-chat","name":"DeepSeek: DeepSeek V3","created":1735241320,
       "description":"DeepSeek V3","context_length":163840,
       "architecture":{"modality":"text->text","input_modalities":["text"],"output_modalities":["text"],"tokenizer":"DeepSeek","instruct_type":null},
       "pricing":{"prompt":"0.0000003","completion":"0.00000088","request":"0","image":"0"},
       "top_provider":{"context_length":163840,"max_completion_tokens":null,"is_moderated":false},
       "per_request_limits":null,"supported_parameters":["tools"]},
      {"id":"openai/text-embedding-3-small","name":"OpenAI: Text Embedding 3 Small","context_length":8192,
       "architecture":{"input_modalities":["text"],"output_modalities":["embeddings"]}}
    ]}
    """#

    override func setUp() {
        super.setUp()
        Stub.routes = [:]
        Stub.seen = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        session = URLSession(configuration: config)
        hintsDir = FileManager.default.temporaryDirectory.appendingPathComponent("hints-\(UUID().uuidString)", isDirectory: true)
        hints = ModelHints(fileURL: hintsDir.appendingPathComponent("model-hints.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: hintsDir)
        super.tearDown()
    }

    private func card(_ base: String, _ type: ProviderType = .openaiCompatible, preset: String? = nil, region: String? = nil) -> APICredential {
        APICredential(id: "card-1", name: "t", emoji: "🧪", presetId: preset, type: type, baseURL: base, regionId: region)
    }

    private func ids(_ json: String) -> [String]? {
        ProviderProbe.parseModelList(Data(json.utf8))?.map(\.id)
    }

    /// 两种格式都有的套餐区域 + 不问 /models 的区域
    private let testPreset = APIProvider(
        id: "t-plan", name: "T", group: .domestic,
        regions: [
            PresetRegion(id: "payg", name: "按量", endpoints: [.openaiCompatible: "https://api.t.example/v1",
                                                            .anthropic: "https://api.t.example/anthropic/v1"]),
            PresetRegion(id: "plan", name: "套餐", endpoints: [.openaiCompatible: "https://plan.t.example/v2",
                                                            .anthropic: "https://plan.t.example/anthropic/v1"],
                         listsModels: false, seedModelIds: ["plan-a", "plan-b"]),
        ],
        defaultProtocol: .openaiCompatible)

    private func lookup(_ id: String?) -> APIProvider? { id == testPreset.id ? testPreset : nil }

    // MARK: 解析

    func testWrappersAndBareArray() {
        XCTAssertEqual(ids(#"[{"id":"a"},{"id":"b"}]"#), ["a", "b"])
        for key in ["data", "models", "result", "items"] {
            XCTAssertEqual(ids(#"{"\#(key)":[{"id":"m-\#(key)"}]}"#), ["m-\(key)"], key)
        }
        XCTAssertEqual(ids(#"{"object":"list","data":[]}"#), [])
        XCTAssertEqual(ids(#"{"error":{"message":"x"}}"#), [])
        XCTAssertNil(ids("<html>oops</html>"))
    }

    func testStringAndObjectItems() {
        XCTAssertEqual(ids(#"{"models":["glm-5"," kimi-k3 ",""]}"#), ["glm-5", "kimi-k3"])
        XCTAssertEqual(ids(#"{"data":[{"model":"by-model"},{"name":"by-name"},{"id":"by-id","model":"x","name":"y"},{"object":"model"}]}"#),
                       ["by-model", "by-name", "by-id"])
    }

    func testDisplayNameFallsBackToName() {
        let listed = ProviderProbe.parseModelList(Data(#"""
        {"data":[{"id":"a","display_name":"A 显示","name":"A 名"},{"id":"b","name":"B 名"},{"name":"c"},"d"]}
        """#.utf8))!
        XCTAssertEqual(listed.map(\.displayName), ["A 显示", "B 名", nil, nil])
    }

    func testContextAndModalities() {
        let listed = ProviderProbe.parseModelList(Data(#"""
        {"data":[
          {"id":"or","context_length":128000,"architecture":{"input_modalities":["text","image"]}},
          {"id":"flat","context_window":200000,"input_modalities":["text"]},
          {"id":"both","context_length":1,"context_window":2},
          {"id":"bare"}
        ]}
        """#.utf8))!
        XCTAssertEqual(listed[0].hint, ModelHint(contextTokens: 128000, inputModalities: ["text", "image"]))
        XCTAssertEqual(listed[1].hint, ModelHint(contextTokens: 200000, inputModalities: ["text"]))
        XCTAssertEqual(listed[2].hint?.contextTokens, 1)
        XCTAssertNil(listed[3].hint)
    }

    /// 审查 #3：首选字段是 JSON null（NSNull）时轮到备选字段，上下文和模态都是
    func testNullPreferredFieldsFallBackToAlternates() {
        let listed = ProviderProbe.parseModelList(Data(#"""
        {"data":[{"id":"m","context_length":null,"context_window":262144,
                  "architecture":{"input_modalities":null},"input_modalities":["text","image"]}]}
        """#.utf8))!
        XCTAssertEqual(listed.first?.hint, ModelHint(contextTokens: 262144, inputModalities: ["text", "image"]))
    }

    // MARK: 拉模型

    func testOpenRouterSampleFiltersNonChatAndRecordsHints() async {
        Stub.routes["https://openrouter.ai/api/v1/models"] = (200, openRouterSample)
        let r = await ProviderProbe.fetchModels(draft: card("https://openrouter.ai/api/v1", preset: "openrouter"),
                                                key: key, session: session, hints: hints)
        guard case .success(let models) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(models.map(\.modelId), ["deepseek/deepseek-chat", "openai/gpt-4o"])
        XCTAssertEqual(models.map(\.name), ["DeepSeek: DeepSeek V3", "OpenAI: GPT-4o"])
        XCTAssertTrue(models.allSatisfy { $0.credentialId == "card-1" })
        XCTAssertEqual(Stub.seen.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-000")
        XCTAssertEqual(hints.hint(credentialId: "card-1", modelId: "openai/gpt-4o"),
                       ModelHint(contextTokens: 128000, inputModalities: ["text", "image", "file"]))
        XCTAssertNil(hints.hint(credentialId: "card-1", modelId: "openai/text-embedding-3-small"))

        let reread = ModelHints(fileURL: hints.fileURL)
        XCTAssertEqual(reread.hint(credentialId: "card-1", modelId: "deepseek/deepseek-chat")?.contextTokens, 163840, "落盘后能读回")
    }

    /// 审查 #1：草稿卡拉模型只把元数据交回页面，不按临时 id 写旁表（保存时按真实卡 id 写）
    func testDraftFetchReturnsHintsWithoutWriting() async {
        Stub.routes["https://relay.test/v1/models"] = (200, #"{"data":[{"id":"a","context_length":10}]}"#)
        let draftId = "draft-\(UUID().uuidString)"
        let draft = APICredential(id: draftId, name: "t", emoji: "🧪", type: .openaiCompatible, baseURL: "https://relay.test/v1")
        let r = await ProviderProbe.discoverModels(draft: draft, key: key, session: session)
        guard case .success(let found) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(found.models.map(\.modelId), ["a"])
        XCTAssertEqual(found.hints, ["a": ModelHint(contextTokens: 10, inputModalities: nil)])
        _ = await ProviderProbe.fetchModels(draft: draft, key: key, session: session)
        XCTAssertNil(ModelHints.shared.hint(credentialId: draftId, modelId: "a"), "没给旁表就不写")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hints.fileURL.path))
    }

    func testRefetchReplacesCardHints() async {
        Stub.routes["https://relay.test/v1/models"] = (200, #"{"data":[{"id":"a","context_length":10},{"id":"b","context_length":20}]}"#)
        _ = await ProviderProbe.fetchModels(draft: card("https://relay.test/v1"), key: key, session: session, hints: hints)
        Stub.routes["https://relay.test/v1/models"] = (200, #"{"data":[{"id":"a","context_length":11},{"id":"b"}]}"#)
        _ = await ProviderProbe.fetchModels(draft: card("https://relay.test/v1"), key: key, session: session, hints: hints)
        XCTAssertEqual(hints.hint(credentialId: "card-1", modelId: "a")?.contextTokens, 11)
        XCTAssertNil(hints.hint(credentialId: "card-1", modelId: "b"))
    }

    func testBareArrayResponseFetches() async {
        Stub.routes["https://relay.test/v1/models"] = (200, #"["zz","aa","text-embedding-x"]"#)
        let r = await ProviderProbe.fetchModels(draft: card("https://relay.test/v1"), key: key, session: session, hints: hints)
        guard case .success(let models) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(models.map(\.modelId), ["aa", "zz"])
    }

    func testNonJSONIsFailure() async {
        Stub.routes["https://relay.test/v1/models"] = (200, "<html>ok</html>")
        let r = await ProviderProbe.fetchModels(draft: card("https://relay.test/v1"), key: key, session: session, hints: hints)
        guard case .failure(let err as ProviderProbe.Failure) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(err.message.contains("不是 JSON"), err.message)
    }

    func testRegionWithoutModelListReturnsSeedsWithoutRequest() async {
        let r = await ProviderProbe.fetchModels(draft: card("https://plan.t.example/v2", preset: "t-plan", region: "plan"),
                                                key: key, session: session, hints: hints, presetLookup: lookup)
        guard case .success(let models) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(models.map(\.modelId), ["plan-a", "plan-b"])
        XCTAssertTrue(models.allSatisfy { $0.credentialId == "card-1" })
        XCTAssertEqual(Stub.seen.count, 0)

        let byURL = await ProviderProbe.fetchModels(draft: card("https://plan.t.example/anthropic/v1", .anthropic, preset: "t-plan"),
                                                    key: key, session: session, hints: hints, presetLookup: lookup)
        guard case .success(let seeds) = byURL else { return XCTFail("\(byURL)") }
        XCTAssertEqual(seeds.map(\.modelId), ["plan-a", "plan-b"], "老卡没 regionId，按地址反查到套餐区域")
        XCTAssertEqual(Stub.seen.count, 0)
    }

    func testAnthropicCardListsFromRegionOpenAIBase() async {
        Stub.routes["https://api.t.example/v1/models"] = (200, #"{"data":[{"id":"t-1"}]}"#)
        let r = await ProviderProbe.fetchModels(draft: card("https://api.t.example/anthropic/v1", .anthropic, preset: "t-plan", region: "payg"),
                                                key: key, session: session, hints: hints, presetLookup: lookup)
        guard case .success(let models) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(models.map(\.modelId), ["t-1"])
        XCTAssertEqual(Stub.seen.map { $0.url!.absoluteString }, ["https://api.t.example/v1/models"])
        XCTAssertEqual(Stub.seen[0].value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-000")
        XCTAssertNil(Stub.seen[0].value(forHTTPHeaderField: "x-api-key"))
    }

    func testAnthropicOnlyRegionKeepsAnthropicEndpointAndHeaders() async {
        Stub.routes["https://api.anthropic.com/v1/models"] = (200, #"{"data":[{"type":"model","id":"claude-x","display_name":"Claude X"}],"has_more":false}"#)
        let r = await ProviderProbe.fetchModels(draft: card("https://api.anthropic.com/v1", .anthropic, preset: "anthropic"),
                                                key: key, session: session, hints: hints)
        guard case .success(let models) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(models.map(\.name), ["Claude X"])
        XCTAssertEqual(Stub.seen[0].value(forHTTPHeaderField: "x-api-key"), "sk-test-000")
        XCTAssertEqual(Stub.seen[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testOwnBaseURLCardIgnoresRegion() async {
        Stub.routes["https://my-relay.test/v1/models"] = (200, #"{"data":[{"id":"own"}]}"#)
        let r = await ProviderProbe.fetchModels(draft: card("https://my-relay.test/v1", .anthropic, preset: "t-plan", region: "plan"),
                                                key: key, session: session, hints: hints, presetLookup: lookup)
        guard case .success(let models) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(models.map(\.modelId), ["own"], "地址自己改过：不回种子、不改打区域地址")
        XCTAssertEqual(Stub.seen.map { $0.url!.absoluteString }, ["https://my-relay.test/v1/models"])
        XCTAssertEqual(Stub.seen[0].value(forHTTPHeaderField: "x-api-key"), "sk-test-000")
    }
}
