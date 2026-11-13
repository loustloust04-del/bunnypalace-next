import SwiftData
import XCTest
@testable import 记忆花园

/// 11-10 iOS 真机 live（atrium P3⑥a「主屏有 = 授权」：这个人没装的 App，连着的 AI 能力对 TA 关掉 = 请求内容变了，10-17 规矩的 😷 真跑）：
/// 同一套默认档位，A 单独卸 App、B 跟默认，各真发一条 Haiku。夹具照 `PermissionFloorsLiveTests`：死卡落一句 → 换 Haiku →
/// `previewTurn`（和实发同一套取工具 / 组装）→ `ProviderRouter.sendStreaming` 真发；从 CatalogLiveAuthProtocol 转发前的请求体里看。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里换进请求头；日志只打布尔 / 计数，不打请求体。
@MainActor
final class Page2AppGateLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialIds: [String] = []
    private var permSuite: String?
    private var appsSuite: String?
    private var previousPermDefaults: UserDefaults?
    private var previousAppsDefaults: UserDefaults?
    private var container: ModelContainer?

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "Page2AppGateLive", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
        try CatalogLiveAuthProtocol.install()
        // 档位 / App 装卸都换到一次性 suite：不碰宿主的 perm.* / rightPanelTools / page2.apps.floors.v1
        let perm = "xctest-page2-live-perm-\(UUID().uuidString)"
        permSuite = perm
        previousPermDefaults = PermissionCenter.defaults
        PermissionCenter.defaults = try XCTUnwrap(UserDefaults(suiteName: perm))
        let apps = "xctest-page2-live-apps-\(UUID().uuidString)"
        appsSuite = apps
        previousAppsDefaults = Page2Apps.defaults
        Page2Apps.defaults = try XCTUnwrap(UserDefaults(suiteName: apps))   // 空 = 内置表：文件库 / 推特 / 健康都装着
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
        if let previousAppsDefaults { Page2Apps.defaults = previousAppsDefaults }
        previousAppsDefaults = nil
        if let appsSuite { UserDefaults(suiteName: appsSuite)?.removePersistentDomain(forName: appsSuite) }
        appsSuite = nil
    }

    private static let question = "只回答两个字：你好。不要调用任何工具。"
    private static let weightMarker = "今天体重 52.3 公斤"

    /// 默认 fileLibrary / twitter 自动允许、App 全装；A 卸文件库 + 推特、B 跟默认 →
    /// A 的请求没有 fs_* / local_twitter（直接给的工具和〔更多工具〕目录都没有）/ <文件库>，B 都有
    func testUninstalledAppDropsFileLibraryAndTwitter() async throws {
        let env = try makeEnvironment()
        setDefaults(bypass: [.toolsMaster, .fileLibrary, .twitter, .images])
        let a = person("A")
        let b = person("B")
        Page2Apps.setFloor(false, for: "fileLibrary", profileId: a.id)
        Page2Apps.setFloor(false, for: "twitter", profileId: a.id)
        XCTAssertEqual(PermissionCenter.level(.fileLibrary, profileId: a.id), .notAllowed)
        XCTAssertEqual(PermissionCenter.level(.twitter, profileId: b.id), .bypass)

        for (label, profile, expectOn) in [("A", a, false), ("B", b, true)] {
            let sent = try await primeAndSend(profile, preset: Preset.balanced, env: env)
            let toolNames = Self.toolNames(sent.body)
            let strings = Self.strings(sent.body)
            let hasFs = toolNames.contains { $0.hasPrefix("fs_") }
            // local_twitter 默认收在〔更多工具〕：直接给的工具里或 system 目录里出现都算有
            let hasTwitter = toolNames.contains(TwitterAITool.toolName) || strings.contains { $0.contains(TwitterAITool.toolName) }
            let hasFileLib = strings.contains { $0.contains("<文件库>") }
            print("[PAGE2-LIVE-IOS] floor=\(label) hasFs=\(hasFs) hasTwitter=\(hasTwitter) hasFileLib=\(hasFileLib) tools=\(toolNames.count) requests=\(sent.requests) tokens=\(sent.tokens) chars=\(sent.chars)")
            XCTAssertEqual(hasFs, expectOn, "\(label)：fs_* 工具该跟这个人装没装文件库走")
            XCTAssertEqual(hasTwitter, expectOn, "\(label)：local_twitter 该跟这个人装没装推特走")
            XCTAssertEqual(hasFileLib, expectOn, "\(label)：system 里 <文件库> 说明该跟这个人装没装文件库走")
        }
    }

    /// 默认 healthWeight 不允许；A、B 层档位都单独放宽成自动允许，A 再卸健康 App → A 没有体重段（门压过层档位），B 有
    func testUninstalledHealthAppDropsWeightEvenIfFloorAllows() async throws {
        let env = try makeEnvironment()
        setDefaults(bypass: [.toolsMaster, .fileLibrary, .images])
        let a = person("A")
        let b = person("B")
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: a.id)
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: b.id)
        Page2Apps.setFloor(false, for: "health", profileId: a.id)
        let context = ModelContext(env.container)
        for p in [a, b] { context.insert(WeightEntry(profileId: p.id, date: Date(), weightKg: 52.3)) }
        try context.save()
        var preset = Preset.balanced
        preset.prompts.insert(PromptSlot(id: "xctest-page2-live-health", name: "健康", role: "system", content: "健康：{{health}}",
                                         isSystemPrompt: false, injectionOrder: 5), at: 1)

        for (label, profile, expectOn) in [("A", a, false), ("B", b, true)] {
            let sent = try await primeAndSend(profile, preset: preset, env: env, context: context)
            let hasWeight = Self.strings(sent.body).contains { $0.contains(Self.weightMarker) }
            print("[PAGE2-LIVE-IOS] floor=\(label) hasWeight=\(hasWeight) requests=\(sent.requests) tokens=\(sent.tokens) chars=\(sent.chars)")
            XCTAssertEqual(hasWeight, expectOn, "\(label)：体重段该跟这个人装没装健康 App 走（档位都允许）")
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
        let liveId = "xctest-page2-live-ios-\(UUID().uuidString)"
        let deadId = "xctest-page2-dead-ios-\(UUID().uuidString)"
        credentialIds += [liveId, deadId]
        let haiku = ProviderModel(credentialId: liveId, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        providers.addCredential(APICredential(
            id: liveId, name: "Page2 Live iOS", emoji: "", type: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            extraHeaders: ["anthropic-version": "2023-06-01"],
            models: [haiku], toolsSupported: true))
        providers.setApiKey(CatalogLiveAuthProtocol.placeholder, for: liveId)
        // 只用来把用户那句话落进对话（发不出去、立刻失败），真发的是上面那张
        let dead = ProviderModel(credentialId: deadId, modelId: "dead", name: "dead")
        providers.addCredential(APICredential(id: deadId, name: "Page2 Dead", emoji: "", type: .openaiCompatible,
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
        Profile(id: "xctest-page2-live-\(label)-\(UUID().uuidString)", name: "live \(label)", emoji: "", description: "",
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
            .appendingPathComponent("page2-live-ios-\(UUID().uuidString).jsonl"))
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
