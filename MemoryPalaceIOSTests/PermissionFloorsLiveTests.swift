import SwiftData
import XCTest
@testable import 记忆花园

/// 11-10 iOS 真机 live（atrium P3⑤a：权限档位按人，人页能单独给某个人收紧 / 放宽 = 请求内容变了，10-17 规矩的 😷 真跑）：
/// 同一套默认，A 单独设、B 跟默认，各真发一条 Haiku。工具列表是 CVM toolInjection 算的，所以走 `previewTurn`
/// （和实发同一套取模型 / 取工具 / 组装），再 `ProviderRouter.sendStreaming` 真发；从 CatalogLiveAuthProtocol 转发前的请求体里看。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里换进请求头；日志只打布尔 / 计数，不打请求体。
@MainActor
final class PermissionFloorsLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialIds: [String] = []
    private var permSuite: String?
    private var previousPermDefaults: UserDefaults?
    private var container: ModelContainer?

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "PermissionFloorsLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
        try CatalogLiveAuthProtocol.install()
        // 档位换到一次性 suite：默认 / 层都写这里，不碰宿主的 perm.*
        let suite = "xctest-perm-live-\(UUID().uuidString)"
        permSuite = suite
        previousPermDefaults = PermissionCenter.defaults
        PermissionCenter.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        for id in credentialIds { manager?.removeCredential(id: id) }
        manager = nil
        credentialIds = []
        container = nil
        CatalogLiveAuthProtocol.onOutgoingBody = nil
        CatalogLiveAuthProtocol.uninstall()
        CatalogLiveAuthProtocol.key = nil
        CatalogLiveAuthProtocol.host = nil
        if let previousPermDefaults { PermissionCenter.defaults = previousPermDefaults }
        previousPermDefaults = nil
        if let permSuite { UserDefaults(suiteName: permSuite)?.removePersistentDomain(forName: permSuite) }
        permSuite = nil
    }

    private static let question = "只回答两个字：你好。不要调用任何工具。"
    private static let weightMarker = "今天体重 52.3 公斤"

    /// 默认 fileLibrary / webSearch 自动允许；A 两项单独设不允许、B 跟默认 → A 的请求没有 fs_* / web_search / <文件库>，B 都有
    func testFloorStricterThanDefaultDropsFileLibraryAndSearch() async throws {
        let env = try makeEnvironment()
        setDefaults(bypass: [.toolsMaster, .fileLibrary, .webSearch, .images])
        let a = person("A")
        let b = person("B")
        PermissionCenter.setFloorLevel(.notAllowed, for: .fileLibrary, profileId: a.id)
        PermissionCenter.setFloorLevel(.notAllowed, for: .webSearch, profileId: a.id)

        for (label, profile, expectOn) in [("A", a, false), ("B", b, true)] {
            let sent = try await primeAndSend(profile, preset: Preset.balanced, env: env)
            let toolNames = Self.toolNames(sent.body)
            let hasFs = toolNames.contains { $0.hasPrefix("fs_") }
            let hasSearch = toolNames.contains("web_search")
            let hasFileLib = Self.strings(sent.body).contains { $0.contains("<文件库>") }
            print("[PERM-LIVE-IOS] floor=\(label) hasFs=\(hasFs) hasSearch=\(hasSearch) hasFileLib=\(hasFileLib) tools=\(toolNames.count) requests=\(sent.requests) tokens=\(sent.tokens) chars=\(sent.chars)")
            XCTAssertEqual(hasFs, expectOn, "\(label)：fs_* 工具该跟这个人的文件库档位走")
            XCTAssertEqual(hasSearch, expectOn, "\(label)：服务端 web_search 该跟这个人的联网搜索档位走")
            XCTAssertEqual(hasFileLib, expectOn, "\(label)：system 里 <文件库> 说明该跟这个人的文件库档位走")
        }
    }

    /// 默认 healthWeight 不允许；A 单独设自动允许 → A 的请求有体重段，B 没有
    func testFloorLooserThanDefaultInjectsHealthWeight() async throws {
        let env = try makeEnvironment()
        setDefaults(bypass: [.toolsMaster, .fileLibrary, .images])
        let a = person("A")
        let b = person("B")
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: a.id)
        let context = ModelContext(env.container)
        for p in [a, b] { context.insert(WeightEntry(profileId: p.id, date: Date(), weightKg: 52.3)) }
        try context.save()
        var preset = Preset.balanced
        preset.prompts.insert(PromptSlot(id: "xctest-perm-live-health", name: "健康", role: "system", content: "健康：{{health}}",
                                         isSystemPrompt: false, injectionOrder: 5), at: 1)

        for (label, profile, expectOn) in [("A", a, true), ("B", b, false)] {
            let sent = try await primeAndSend(profile, preset: preset, env: env, context: context)
            let hasWeight = Self.strings(sent.body).contains { $0.contains(Self.weightMarker) }
            print("[PERM-LIVE-IOS] floor=\(label) hasWeight=\(hasWeight) requests=\(sent.requests) tokens=\(sent.tokens) chars=\(sent.chars)")
            XCTAssertEqual(hasWeight, expectOn, "\(label)：体重段该跟这个人的体重档位走")
        }
    }

    // MARK: - 夹具

    private struct Env {
        let container: ModelContainer
        let providers: ProviderManager
        let haiku: ProviderModel
        let dead: ProviderModel
    }

    private struct Sent {
        let body: Data
        let requests: Int
        let tokens: Int
        let chars: Int
    }

    private func makeEnvironment() throws -> Env {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        self.container = container
        let providers = ProviderManager()
        manager = providers
        let liveId = "xctest-perm-live-ios-\(UUID().uuidString)"
        let deadId = "xctest-perm-dead-ios-\(UUID().uuidString)"
        credentialIds += [liveId, deadId]
        let haiku = ProviderModel(credentialId: liveId, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        providers.addCredential(APICredential(
            id: liveId, name: "Perm Live iOS", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [haiku], toolsSupported: true))
        providers.setApiKey(CatalogLiveAuthProtocol.placeholder, for: liveId)
        // 只用来把用户那句话落进对话（发不出去、立刻失败），真发的是上面那张
        let dead = ProviderModel(credentialId: deadId, modelId: "dead", name: "dead")
        providers.addCredential(APICredential(id: deadId, name: "Perm Dead", emoji: "", type: .openaiCompatible,
                                              baseURL: "http://127.0.0.1:9", models: [dead], toolsSupported: false))
        providers.setApiKey("xctest-dead", for: deadId)
        return Env(container: container, providers: providers, haiku: haiku, dead: dead)
    }

    private func setDefaults(bypass: Set<PermissionDomain>) {
        for d in PermissionDomain.allCases {
            PermissionCenter.setDefaultLevel(bypass.contains(d) ? .bypass : .notAllowed, for: d)
        }
    }

    private func person(_ label: String) -> Profile {
        Profile(id: "xctest-perm-live-\(label)-\(UUID().uuidString)", name: "live \(label)", emoji: "", description: "",
                userName: "你", assistantName: "小测")
    }

    /// 用死卡把用户那句落进一个新对话 → 换 Haiku → previewTurn（排除那条失败的回复，= 重新生成的视角）→ 真发一次
    private func primeAndSend(_ profile: Profile, preset: Preset, env: Env, context: ModelContext? = nil) async throws -> Sent {
        let context = context ?? ModelContext(env.container)
        let vm = ConversationViewModel()
        vm.startDraftConversation(profileId: profile.id)
        XCTAssertTrue(vm.sendMessage(Self.question, model: env.dead, profile: profile, preset: preset,
                                     providerManager: env.providers, context: context))
        let deadline = Date().addingTimeInterval(60)
        while vm.assistantTurnInFlight, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let conversation = try XCTUnwrap(vm.selectedConversation)
        XCTAssertEqual(conversation.profileId, profile.id)
        let failed = try XCTUnwrap(vm.currentPath.last { $0.role == "assistant" })
        conversation.selectedModelId = env.haiku.id

        let preview = try XCTUnwrap(vm.previewTurn(profile: profile, preset: preset, providerManager: env.providers,
                                                   globalModelId: nil, context: context, excludingNodeId: failed.id))
        XCTAssertEqual(preview.model.id, env.haiku.id)
        let legacy = PromptMessage.legacyShape(preview.ordered)

        var bodies: [Data] = []
        CatalogLiveAuthProtocol.onOutgoingBody = { bodies.append($0) }
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-live-ios-\(UUID().uuidString).jsonl"))
        var tokens = 0
        var content = ""
        var failure: String?
        let done = expectation(description: "chat \(profile.name)")
        router.sendStreaming(
            model: env.haiku,
            messages: legacy.messages,
            systemPrompt: legacy.systemPrompt,
            providerManager: env.providers,
            samplingParams: preview.sampling,
            tools: preview.tools,
            ordered: preview.ordered,
            onToken: { _ in tokens += 1 },
            onComplete: { text, _ in content = text; done.fulfill() },
            onError: { message in failure = message; done.fulfill() },
            onToolCalls: { _, _ in failure = "模型调了工具（这条只该回话）"; done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 120)
        CatalogLiveAuthProtocol.onOutgoingBody = nil
        if let failure { XCTFail("\(profile.name) 流式失败：\(CatalogLiveAuthProtocol.redacted(failure))") }
        XCTAssertGreaterThan(tokens, 0, "\(profile.name) 要回话")
        XCTAssertFalse(content.isEmpty, "\(profile.name) 要回话")
        XCTAssertEqual(bodies.count, 1, "\(profile.name) 该只发出一个请求")
        return Sent(body: try XCTUnwrap(bodies.first), requests: bodies.count, tokens: tokens, chars: content.count)
    }

    private static func toolNames(_ body: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tools = json["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { $0["name"] as? String }
    }

    /// JSON 里中文可能原样也可能 \u 转义：解开再找
    private static func strings(_ body: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: body) else { return [String(decoding: body, as: UTF8.self)] }
        return flatten(json)
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
