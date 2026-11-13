import XCTest
@testable import 记忆花园

/// 11-08 iOS 真机 live（铲屎二期刀 6 A-32 动了 SSELineDecoder，10-17 规矩的 😷 真跑）：
/// Anthropic 原生和 OpenAI 兼容两种格式，各跑一条主聊天流式 + 一条副调用流式，都拿 anthropic-official 官方端点。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里经 CatalogLiveAuthProtocol 换进请求头；
/// 日志只打格式、字数和输出 token。
@MainActor
final class StreamFormatLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialIds: [String] = []

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "StreamFormatLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
        try CatalogLiveAuthProtocol.install()
    }

    override func tearDown() async throws {
        for id in credentialIds { manager?.removeCredential(id: id) }
        manager = nil
        credentialIds = []
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
    }

    func testLiveHaikuStreamingBothFormatsOnDevice() async throws {
        let manager = ProviderManager()
        self.manager = manager
        for type in [ProviderType.anthropic, .openaiCompatible] {
            let id = "xctest-stream-live-ios-\(type.rawValue)-\(UUID().uuidString)"
            let model = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
            credentialIds.append(id)
            manager.addCredential(APICredential(
                id: id, name: "Stream Live iOS \(type.rawValue)", emoji: "", type: type,
                baseURL: "https://api.anthropic.com/v1",
                extraHeaders: type == .anthropic ? ["anthropic-version": "2023-06-01"] : [:],
                models: [model], toolsSupported: false))
            manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

            let router = ProviderRouter()
            router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("stream-live-ios-\(UUID().uuidString).jsonl"))
            var tokens = 0
            var content = ""
            var failure: String?
            let done = expectation(description: "chat \(type.rawValue)")
            router.sendStreaming(
                model: model,
                messages: [(role: "user", content: "用一句话介绍月亮，不超过三十个字")],
                systemPrompt: nil,
                providerManager: manager,
                samplingParams: SamplingParams(),
                onToken: { _ in tokens += 1 },
                onComplete: { text, _ in content = text; done.fulfill() },
                onError: { message in failure = message; done.fulfill() }
            )
            await fulfillment(of: [done], timeout: 120)
            print("[STREAM-LIVE-IOS] \(type.rawValue) chat: tokens=\(tokens) chars=\(content.count) outcome=\(router.lastReplyOutcome.rawValue)")
            if let failure { XCTFail("\(type.rawValue) 主聊天流式失败：\(CatalogLiveAuthProtocol.redacted(failure))") }
            XCTAssertGreaterThan(tokens, 0, "\(type.rawValue) 应当是一段段流式吐出来的")
            XCTAssertFalse(content.isEmpty, "\(type.rawValue) 主聊天正文不能为空")

            let side = try await ProviderRouter(usageContext: UsageContext(kind: .topic)).sideCall(
                model: model, messages: [(role: "user", content: "只回答两个字：你好")],
                systemPrompt: nil, providerManager: manager)
            print("[STREAM-LIVE-IOS] \(type.rawValue) side: hit=\(side.hitOutputLimit) chars=\(side.text.count) out=\(side.usage?.outputTokens ?? -1)")
            XCTAssertFalse(side.text.isEmpty, "\(type.rawValue) 副调用正文不能为空")
            XCTAssertFalse(side.hitOutputLimit)
        }
    }

    /// 11-10 铲屎·小 bug L-B12：search_web 失败时回填给模型的文字先脱敏。这里把脱敏后的那段当工具结果的文字发给 Haiku，
    /// 看它照常接得住（不是走真的 tool_result 块——搜索服务在测试宿主里没配）。
    func testLiveHaikuAcceptsRedactedSearchFailureText() async throws {
        let manager = ProviderManager()
        self.manager = manager
        let id = "xctest-search-fail-live-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        credentialIds.append(id)
        manager.addCredential(APICredential(
            id: id, name: "Search Fail Live iOS", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1", extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [model], toolsSupported: false))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        let fake = "sk-fake-0000000000000000"
        let failure = WebSearchToolService.failureText(
            WebSearchProviderError.http(401, #"{"error":"invalid key \#(fake)","url":"https://api.example.com/search?api_key=\#(fake)"}"#),
            apiKey: fake)
        XCTAssertFalse(failure.contains(fake))

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("search-fail-live-ios-\(UUID().uuidString).jsonl"))
        var content = ""
        var error: String?
        let done = expectation(description: "chat")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "search_web 工具返回了下面这段。用一句话告诉我搜索成功了没有：\n\(failure)")],
            systemPrompt: nil,
            providerManager: manager,
            samplingParams: SamplingParams(),
            onToken: { _ in },
            onComplete: { text, _ in content = text; done.fulfill() },
            onError: { message in error = message; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 120)
        print("[STREAM-LIVE-IOS] search-fail: failureChars=\(failure.count) replyChars=\(content.count) outcome=\(router.lastReplyOutcome.rawValue)")
        if let error { XCTFail("失败：\(CatalogLiveAuthProtocol.redacted(error))") }
        XCTAssertFalse(content.isEmpty)
    }
}
