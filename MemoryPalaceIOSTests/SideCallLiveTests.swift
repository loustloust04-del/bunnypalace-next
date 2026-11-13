import XCTest
@testable import 记忆花园

/// 11-07 iOS 真机 live（铲屎二期刀 4，10-17 规矩的 😷 真跑）：后台副调用 `router.sideCall` 撞到输出上限时带回截断标志。
/// 与 mac 那条（MemoryPalaceTests/SideCallLiveTests.swift）同款；副调用的 Anthropic 上限是 min(8192, 目录上限)，
/// 没有压低的口子，所以让模型写一段远超 8192 token 的虚构内容。
/// 刀 4 返修后卡默认「后台任务用流式」：这条走的是流式副调用（😷 上非流式 30 多秒会被掐，research-非流式长请求断线）。
/// key 由车头用 TEST_RUNNER_MP_SIDECALL_LIVE_API_KEY 注入，只在内存里经 CatalogLiveAuthProtocol 换进请求头；
/// 日志只打标志、字数和输出 token。
@MainActor
final class SideCallLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialId: String?

    override func setUp() async throws {
        guard let value = getenv("MP_SIDECALL_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_SIDECALL_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "SideCallLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        try CatalogLiveAuthProtocol.install()
    }

    override func tearDown() async throws {
        if let credentialId { manager?.removeCredential(id: credentialId) }
        manager = nil
        credentialId = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
    }

    func testLiveHaikuSideCallFlagsTruncationOnDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        let baseURL = env["MP_SIDECALL_LIVE_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://api.anthropic.com/v1"
        let modelName = env["MP_SIDECALL_LIVE_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude-haiku-5-5"
        let id = "xctest-sidecall-live-ios-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
        CatalogLiveAuthProtocol.host = URL(string: baseURL)?.host
        let manager = ProviderManager()
        self.manager = manager
        credentialId = id
        manager.addCredential(APICredential(id: id, name: "SideCall Live iOS", emoji: "", type: .anthropic,
                                            baseURL: baseURL, extraHeaders: ["anthropic-version": "2023-06-01"],
                                            models: [model], toolsSupported: false))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        XCTAssertEqual(manager.sideModel(ids: [model.id])?.id, model.id, "有 key 的 Anthropic 卡应当被挑中")

        let router = ProviderRouter(usageContext: UsageContext(kind: .topic))
        let short = try await router.sideCall(model: model, messages: [(role: "user", content: "只回答两个字：你好")],
                                              systemPrompt: nil, providerManager: manager)
        print("[SIDECALL-LIVE-IOS] short: hit=\(short.hitOutputLimit) chars=\(short.text.count) out=\(short.usage?.outputTokens ?? -1)")
        XCTAssertFalse(short.hitOutputLimit, "短回答不该标截断")

        let long = try await router.sideCall(
            model: model,
            messages: [(role: "user", content: "写一部虚构的长篇游记，主角叫星砚，至少三万字，按章节一直写下去，中途不要总结、不要停、不要问我要不要继续。")],
            systemPrompt: "你是小说作者。只输出正文。",
            providerManager: manager)
        print("[SIDECALL-LIVE-IOS] long(stream): hit=\(long.hitOutputLimit) chars=\(long.text.count) out=\(long.usage?.outputTokens ?? -1)")
        XCTAssertTrue(long.hitOutputLimit, "超过输出上限应当带回截断标志")
    }
}
