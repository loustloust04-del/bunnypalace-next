import XCTest
@testable import 记忆花园

/// 11-08 iOS 真机 live（atrium P3② 把「作息感知」从全局搬到楼层：开关决定〔时间〕块进不进提示词 = 请求内容变了，
/// 10-17 规矩的 😷 真跑）：同一个人、同一句话，开关开 / 关各真发一条 Haiku，
/// 从 CatalogLiveAuthProtocol 转发前的请求体里看〔时间〕块：开 → 有，关 → 没有；两条都要回话。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里换进请求头；日志只打布尔 / 计数，不打请求体。
@MainActor
final class TimeAwarenessLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialIds: [String] = []

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "TimeAwarenessLive", code: 1,
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
        CatalogLiveAuthProtocol.onOutgoingBody = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
    }

    private static let marker = "〔时间〕"

    func testFloorSwitchDecidesWhetherTimeBlockIsSent() async throws {
        let manager = ProviderManager()
        self.manager = manager
        let id = "xctest-timectx-live-ios-\(UUID().uuidString)"
        credentialIds.append(id)
        let haiku = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        manager.addCredential(APICredential(
            id: id, name: "TimeCtx Live iOS", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [haiku], toolsSupported: false))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        for enabled in [true, false] {
            var person = Profile(name: "live 人", emoji: "", description: "", userName: "你", assistantName: "小测")
            person.characterTimeZone = "Asia/Tokyo"
            person.timeAwarenessEnabled = enabled

            // 跟实发同一套组装：assembleOrdered → legacyShape（ConversationViewModel.assemblePrompt 的路径）
            let preset = Preset(name: "timectx-live")
            let assembled = PromptAssembler.assembleOrdered(
                preset: preset, profile: person, memories: [],
                chatHistory: [(role: "user", content: "只回答两个字：你好")])
            let legacy = PromptMessage.legacyShape(assembled.messages)
            let assembledHasBlock = assembled.messages.contains { $0.content.contains(Self.marker) }
            XCTAssertEqual(assembledHasBlock, enabled, "组装结果里〔时间〕块该跟这一层的开关走（enabled=\(enabled)）")

            var bodies: [Data] = []
            CatalogLiveAuthProtocol.onOutgoingBody = { bodies.append($0) }
            let router = ProviderRouter()
            router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("timectx-live-ios-\(UUID().uuidString).jsonl"))
            var tokens = 0
            var content = ""
            var failure: String?
            let done = expectation(description: "chat enabled=\(enabled)")
            router.sendStreaming(
                model: haiku,
                messages: legacy.messages,
                systemPrompt: legacy.systemPrompt,
                providerManager: manager,
                samplingParams: preset.sampling,
                ordered: assembled.messages,
                onToken: { _ in tokens += 1 },
                onComplete: { text, _ in content = text; done.fulfill() },
                onError: { message in failure = message; done.fulfill() }
            )
            await fulfillment(of: [done], timeout: 120)
            CatalogLiveAuthProtocol.onOutgoingBody = nil
            if let failure { XCTFail("enabled=\(enabled) 流式失败：\(CatalogLiveAuthProtocol.redacted(failure))") }
            XCTAssertGreaterThan(tokens, 0)
            XCTAssertFalse(content.isEmpty)

            XCTAssertEqual(bodies.count, 1, "enabled=\(enabled) 该只发出一个请求")
            let bodyHasBlock = bodies.contains { Self.containsMarker($0) }
            print("[TIMECTX-LIVE-IOS] enabled=\(enabled) assembledHasBlock=\(assembledHasBlock) bodyHasBlock=\(bodyHasBlock) requests=\(bodies.count) tokens=\(tokens) chars=\(content.count) outcome=\(router.lastReplyOutcome.rawValue)")
            XCTAssertEqual(bodyHasBlock, enabled, "真发出去的请求体里〔时间〕块该跟这一层的开关走（enabled=\(enabled)）")
        }
    }

    /// JSON 里中文可能原样也可能 \u 转义：解开再找
    private static func containsMarker(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            return String(decoding: body, as: UTF8.self).contains(marker)
        }
        return flatten(json).contains { $0.contains(marker) }
    }

    private static func flatten(_ any: Any) -> [String] {
        switch any {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(flatten)
        case let d as [String: Any]: return d.values.flatMap(flatten)
        default: return []
        }
    }
}
