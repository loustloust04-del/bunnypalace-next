import XCTest
@testable import 记忆花园

/// 11-07 iOS 真机 live：真打 Haiku，把输出上限压到 5 token，确认「到输出上限」判成 ReplyOutcome.truncatedLength。
/// 与 mac 那条（MemoryPalaceTests/ReplyOutcomeLiveTests.swift）同款，但 iOS 测试 target 拿不到
/// PromptRealPathHarness，所以直接走 ProviderRouter，不走 ConversationViewModel。
/// key 由车头用 TEST_RUNNER_MP_OUTCOME_LIVE_API_KEY 注入，只在内存里经 CatalogLiveAuthProtocol 换进请求头；
/// 不进钥匙串以外的文件 / 日志，日志只打结局和正文前 20 字。
@MainActor
final class ReplyOutcomeLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialId: String?
    private var adaptKey: String?

    /// 5 个 token 数不完 1–100，上游必然 stop_reason=max_tokens
    private static let capTokens = 5
    private static let longPrompt = "从 1 数到 100，用中文数字，一个一个写出来"

    override func setUp() async throws {
        guard let value = getenv("MP_OUTCOME_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_OUTCOME_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "ReplyOutcomeLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        try CatalogLiveAuthProtocol.install()
    }

    override func tearDown() async throws {
        RequestBodyTap.handler = nil
        if let credentialId { manager?.removeCredential(id: credentialId) }
        manager = nil
        credentialId = nil
        if let adaptKey {
            ParamAdaptStore.shared.remove(key: adaptKey)
            self.adaptKey = nil
        }
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
    }

    func testLiveHaikuLengthTruncationOnDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = env["MP_OUTCOME_LIVE_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://api.anthropic.com/v1"
        let modelName = env["MP_OUTCOME_LIVE_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-haiku-5-5"
        let id = "xctest-outcome-live-ios-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        self.manager = manager
        credentialId = id
        manager.addCredential(APICredential(id: id, name: "Outcome Live iOS", emoji: "", type: .anthropic,
                                            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"],
                                            models: [model], toolsSupported: false))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        // Haiku 5.5 默认会想，且「默认」档要留 4096 余量：那一档会把实发 max_tokens 抬到 5 + 4096，压不到 5。
        // 把「不收思考参数」学进 ParamAdaptStore（生产里有这条学习路径，设置页能清），实发才是 5。
        let base = manager.provider(for: model)?.baseURL ?? baseURL
        let adaptKey = ParamAdaptStore.key(providerType: .anthropic, baseURL: base, modelId: modelName)
        self.adaptKey = adaptKey
        ParamAdaptStore.shared.learn(providerType: .anthropic, baseURL: base, modelId: modelName,
                                     adding: ParamCompat.Learned(groups: [ParamCompat.Group.reasoning]),
                                     rawError: "xctest: 把实发输出上限钉在 \(Self.capTokens) token")

        var sampling = SamplingParams()
        sampling.maxTokens = Self.capTokens
        sampling.maxTokensAuto = false

        var sentMaxTokens: Int?
        var sentThinking = false
        RequestBodyTap.handler = { body in
            sentMaxTokens = body["max_tokens"] as? Int
            sentThinking = body["thinking"] != nil || body["output_config"] != nil
        }

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-live-ios-\(UUID().uuidString).jsonl"))
        var content = ""
        var failure: String?
        let done = expectation(description: "complete")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: Self.longPrompt)],
            systemPrompt: nil,
            providerManager: manager,
            samplingParams: sampling,
            onToken: { _ in },
            onComplete: { text, _ in content = text; done.fulfill() },
            onError: { message in failure = message; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 120)

        print("[OUTCOME-LIVE-iOS] outcome=\(router.lastReplyOutcome.rawValue) "
            + "finish=\(router.lastFinishReason ?? "nil") "
            + "content前20字=\(CatalogLiveAuthProtocol.redacted(String(content.prefix(20))))")
        if let failure { XCTFail("真实端点失败（包括 HTTP 4xx）：\(CatalogLiveAuthProtocol.redacted(failure))") }
        XCTAssertEqual(sentMaxTokens, Self.capTokens, "实发输出上限必须是 5 token，思考余量不能把它抬起来")
        XCTAssertFalse(sentThinking, "学到不收思考参数后，请求体里不能再带 thinking / output_config")
        XCTAssertEqual(router.lastReplyOutcome, .truncatedLength)
        XCTAssertEqual(router.lastFinishReason, "max_tokens")
        XCTAssertFalse(content.contains("截断"), "提示文字不能进正文：\(content)")
        XCTAssertFalse(content.contains("⚠️"), "这一轮不能报错：\(content)")
    }
}
