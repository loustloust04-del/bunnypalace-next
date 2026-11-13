import XCTest
@testable import 记忆花园

/// 11-08 iOS 真机 live（atrium P3① 动了主对话模型解析：对话 → 这个人 → 全局，10-17 规矩的 😷 真跑）：
/// 同一张 anthropic-official 卡上挂 Haiku 和一个只当全局默认的诱饵模型；Profile.preferredModel 指 Haiku、对话没选模型、
/// 全局默认指诱饵 → resolveModel 必须落到这个人的 Haiku，再真发一条，用量账本那一行记的模型必须是 Haiku。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里经 CatalogLiveAuthProtocol 换进请求头；日志只打模型 id 和字数。
@MainActor
final class ResolveModelLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialIds: [String] = []

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "ResolveModelLive", code: 1,
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

    func testPersonModelWinsOverGlobalAndIsWhatGetsSent() async throws {
        let manager = ProviderManager()
        self.manager = manager
        let id = "xctest-resolve-live-ios-\(UUID().uuidString)"
        credentialIds.append(id)
        let haiku = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        // 诱饵只当全局默认，永远不该被发出去
        let decoy = ProviderModel(credentialId: id, modelId: "claude-sonnet-4-5", name: "decoy-global")
        manager.addCredential(APICredential(
            id: id, name: "Resolve Live iOS", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [decoy, haiku], toolsSupported: false))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        // 这个人选了 Haiku；对话没选；全局默认是诱饵
        var person = Profile(name: "live 人", emoji: "", description: "", userName: "你", assistantName: "小测")
        person.preferredModel = haiku.id
        let resolved = manager.resolveModel(conversationModelId: "", profileModelId: person.preferredModel, globalFallbackId: decoy.id)
        print("[RESOLVE-LIVE-IOS] resolved=\(resolved.id) person=\(person.preferredModel) global=\(decoy.id)")
        XCTAssertEqual(resolved.id, haiku.id, "对话没选模型时应落到这个人的模型，不是全局默认")

        // 对照：没选模型的人 → 全局默认
        let blank = Profile(name: "没选", emoji: "", description: "", userName: "你", assistantName: "")
        let viaGlobal = manager.resolveModel(conversationModelId: "", profileModelId: blank.preferredModel, globalFallbackId: decoy.id)
        XCTAssertEqual(viaGlobal.id, decoy.id, "人没选 → 全局默认")
        // 对照：对话自己选了 → 不受人影响
        let viaConversation = manager.resolveModel(conversationModelId: decoy.id, profileModelId: person.preferredModel, globalFallbackId: nil)
        XCTAssertEqual(viaConversation.id, decoy.id, "对话钉住的模型优先于人")

        // 真发一条：账本那一行记的模型必须是 Haiku
        let router = ProviderRouter()
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-live-ios-\(UUID().uuidString).jsonl")
        router.ledger = UsageLedger(fileURL: ledgerURL)
        var tokens = 0
        var content = ""
        var failure: String?
        let done = expectation(description: "chat via person model")
        router.sendStreaming(
            model: resolved,
            messages: [(role: "user", content: "只回答两个字：你好")],
            systemPrompt: nil,
            providerManager: manager,
            samplingParams: SamplingParams(),
            onToken: { _ in tokens += 1 },
            onComplete: { text, _ in content = text; done.fulfill() },
            onError: { message in failure = message; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 120)
        if let failure { XCTFail("主聊天流式失败：\(CatalogLiveAuthProtocol.redacted(failure))") }
        XCTAssertGreaterThan(tokens, 0)
        XCTAssertFalse(content.isEmpty)

        let records = router.ledger.load()
        let sent = records.map(\.model)
        print("[RESOLVE-LIVE-IOS] chat: tokens=\(tokens) chars=\(content.count) outcome=\(router.lastReplyOutcome.rawValue) ledgerModels=\(sent)")
        XCTAssertEqual(records.count, 1, "这一条该只记一行账")
        XCTAssertEqual(records.first?.model, haiku.modelId, "真发出去的必须是这个人的 Haiku")
        XCTAssertFalse(sent.contains(decoy.modelId), "全局默认的诱饵不该被发出去")
    }

    /// 11-09 P3 附 b（输入框切模型只写 `conversation.selectedModelId`，不再写全局 `selectedChatModel`）：
    /// 对话钉了 Haiku、人没选、全局默认是诱饵 → 真发出去的是 Haiku；发完全局键原封不动；另一个没钉的对话仍落到全局。
    /// 输入框那一行写入本身是 UI（CardFlowView.modelPickerContent onSelect），这里按它写完的状态起测。
    func testConversationPinnedModelIsSentAndGlobalStaysPut() async throws {
        let manager = ProviderManager()
        self.manager = manager
        let id = "xctest-resolve-live-ios-conv-\(UUID().uuidString)"
        credentialIds.append(id)
        let haiku = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        let decoy = ProviderModel(credentialId: id, modelId: "claude-sonnet-4-5", name: "decoy-global")
        manager.addCredential(APICredential(
            id: id, name: "Resolve Live iOS conv", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [decoy, haiku], toolsSupported: false))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        // 全局 🌞 = 诱饵（输入框改之前就这样，改完也该还是这样）
        let globalKey = "selectedChatModel"
        UserDefaults.standard.set(decoy.id, forKey: globalKey)
        defer { UserDefaults.standard.removeObject(forKey: globalKey) }
        let person = Profile(name: "没选", emoji: "", description: "", userName: "你", assistantName: "")

        // 这个对话被输入框切到了 Haiku
        let pinned = manager.resolveModel(conversationModelId: haiku.id, profileModelId: person.preferredModel,
                                          globalFallbackId: UserDefaults.standard.string(forKey: globalKey))
        XCTAssertEqual(pinned.id, haiku.id, "对话钉住的模型最优先")
        // 另一个没钉的对话
        let other = manager.resolveModel(conversationModelId: "", profileModelId: person.preferredModel,
                                         globalFallbackId: UserDefaults.standard.string(forKey: globalKey))
        XCTAssertEqual(other.id, decoy.id, "没钉的对话仍走全局默认")

        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-live-ios-conv-\(UUID().uuidString).jsonl"))
        var tokens = 0
        var content = ""
        var failure: String?
        let done = expectation(description: "chat via conversation model")
        router.sendStreaming(
            model: pinned,
            messages: [(role: "user", content: "只回答两个字：你好")],
            systemPrompt: nil,
            providerManager: manager,
            samplingParams: SamplingParams(),
            onToken: { _ in tokens += 1 },
            onComplete: { text, _ in content = text; done.fulfill() },
            onError: { message in failure = message; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 120)
        if let failure { XCTFail("对话层模型流式失败：\(CatalogLiveAuthProtocol.redacted(failure))") }
        XCTAssertGreaterThan(tokens, 0)
        XCTAssertFalse(content.isEmpty)

        let sent = router.ledger.load().map(\.model)
        let globalAfter = UserDefaults.standard.string(forKey: globalKey)
        print("[RESOLVE-LIVE-IOS] conv: pinned=\(pinned.id) other=\(other.id) ledgerModels=\(sent) globalUnchanged=\(globalAfter == decoy.id) tokens=\(tokens) chars=\(content.count) outcome=\(router.lastReplyOutcome.rawValue)")
        XCTAssertEqual(sent, [haiku.modelId], "真发出去的必须是这个对话钉的 Haiku，且只一行账")
        XCTAssertEqual(globalAfter, decoy.id, "发完全局默认不能被改")
    }
}
