import MemoryCore
import XCTest
@testable import 记忆花园

/// 11-12 iOS 真机 live（自唤醒：新的模型请求路径 = 小 pi AgentLoop → WakeModelCaller → AssistantCloudBackend 多轮工具回合，10-17 规矩的 😷 真跑）：
/// 合成任务 + 一个读虚构网页的假工具 → anthropic-official Haiku 真发，看它先调工具、再用 finish 交结果，
/// 执行记录里有这一步 / 来源 / 摘要 / 发给她的话，账本记 .wake。
/// key 由车头用 TEST_RUNNER_MP_STREAM_LIVE_API_KEY 注入，只在内存里经 CatalogLiveAuthProtocol 换进请求头
@MainActor
final class WakeLiveTests: XCTestCase {
    private var manager: ProviderManager?
    private var credentialId: String?

    override func setUp() async throws {
        guard let value = getenv("MP_STREAM_LIVE_API_KEY"), !String(cString: value).isEmpty else {
            throw XCTSkip("未注入 TEST_RUNNER_MP_STREAM_LIVE_API_KEY，不访问真实端点")
        }
        guard TestHostIsolation.active, TestHostIsolation.home != nil else {
            throw NSError(domain: "WakeLive", code: 1, userInfo: [NSLocalizedDescriptionKey: "必须使用隔离的 iOS XCTest 宿主"])
        }
        executionTimeAllowance = 600
        CatalogLiveAuthProtocol.key = String(cString: value)
        CatalogLiveAuthProtocol.host = "api.anthropic.com"
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

    func testLiveHaikuRunsWakeTaskWithToolThenFinishOnDevice() async throws {
        let manager = ProviderManager()
        self.manager = manager
        let id = "xctest-wake-live-ios-\(UUID().uuidString)"
        credentialId = id
        let model = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        manager.addCredential(APICredential(id: id, name: "Wake Live iOS", emoji: "", type: .anthropic,
                                            baseURL: "https://api.anthropic.com/v1",
                                            extraHeaders: ["anthropic-version": "2023-06-01"],
                                            models: [model], toolsSupported: true))
        manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)

        // 虚构网页：只有读了才知道「第七盏灯」
        let page = WakeTool(spec: AgentToolSpec(name: "browse_url", description: "读一个网页的正文",
                                                schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
                            label: "读网页", describe: { "读 \(WakeTools.shortURL(WakeTools.arg($0, "url")))" },
                            source: { args, _ in WakeTools.arg(args, "url").map { WakeSource(url: $0) } }) { _ in
            AgentToolOutput("雾湾灯塔日报：今晚守灯人贝洛·栖川点亮了第七盏备用灯，雾会在凌晨三点散开。")
        }
        let task = WakeTask(title: "灯塔日报", instruction: "读 https://fog-bay.invalid/daily 这一页，用一句话告诉她今晚亮的是第几盏灯。",
                            schedule: .daily(hour: 8, minute: 0, weekdays: nil), createdBy: .user, notify: .heartbeatOnly)
        let caller = WakeModelCaller(model: model, providerManager: manager, usage: UsageContext(kind: .wake, profileId: "xctest"))
        let profile = Profile(name: "测试", emoji: "🌫️", description: "", userName: "禾禾", assistantName: "小岚")
        let opening = WakePrompt.opening(task, profile: profile, tz: TimeZone(identifier: "Asia/Shanghai")!, withheld: [])
        let (run, _) = await WakeRunner.run(.init(task: task, trigger: .manual, system: WakePrompt.rules(profile), opening: opening,
                                                  tools: [page], caller: caller, maxRounds: 8, store: nil))
        print("[WAKE-LIVE-IOS] status=\(run.status.rawValue) rounds=\(run.rounds) steps=\(run.steps.map(\.action)) summary=\(run.summary ?? "-") message=\(run.message?.prefix(60) ?? "-") note=\(run.statusNote ?? "-")")
        XCTAssertEqual(run.status, .ok, run.statusNote ?? "")
        XCTAssertEqual(run.steps.first?.tool, "browse_url", "要先读那一页")
        XCTAssertEqual(run.sources.first?.url, "https://fog-bay.invalid/daily")
        let said = (run.summary ?? "") + (run.message ?? "")
        XCTAssertTrue(said.contains("七") || said.contains("7"), "要从页面里答出第七盏")
        XCTAssertGreaterThanOrEqual(run.rounds, 2)
    }

    private func haiku() -> ProviderModel {
        let manager = self.manager ?? ProviderManager()
        self.manager = manager
        let id = credentialId ?? "xctest-wake-live-ios-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: "claude-haiku-5-5", name: "claude-haiku-5-5")
        if credentialId == nil {
            credentialId = id
            manager.addCredential(APICredential(id: id, name: "Wake Live iOS", emoji: "", type: .anthropic,
                                                baseURL: "https://api.anthropic.com/v1",
                                                extraHeaders: ["anthropic-version": "2023-06-01"],
                                                models: [model], toolsSupported: true))
            manager.setApiKey(CatalogLiveAuthProtocol.placeholder, for: id)
        }
        return model
    }

    /// plan-floor-main-thread「先安静」：上次已经报过、这次一样 → 不填 message（这次不发）
    func testLiveHaikuStaysQuietWhenNothingNew() async throws {
        let model = haiku()
        let page = WakeTool(spec: AgentToolSpec(name: "browse_url", description: "读一个网页的正文",
                                                schema: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#),
                            label: "读网页", describe: { _ in "读网页" }, source: { _, _ in nil }) { _ in
            AgentToolOutput("雾湾灯塔日报：今晚还是第七盏备用灯，和昨晚一样。没有别的消息。")
        }
        var task = WakeTask(title: "灯塔日报", instruction: "读 https://fog-bay.invalid/daily，有新变化才告诉她。",
                            schedule: .daily(hour: 8, minute: 0, weekdays: nil), createdBy: .user, notify: .mainSession(push: true))
        task.note = "昨天已经告诉她是第七盏灯了。"
        let caller = WakeModelCaller(model: model, providerManager: try XCTUnwrap(manager), usage: UsageContext(kind: .wake, profileId: "xctest"))
        let profile = Profile(name: "测试", emoji: "🌫️", description: "", userName: "禾禾", assistantName: "小岚")
        let opening = WakePrompt.opening(task, profile: profile, tz: TimeZone(identifier: "Asia/Shanghai")!, withheld: [])
        let (run, _) = await WakeRunner.run(.init(task: task, trigger: .manual, system: WakePrompt.rules(profile), opening: opening,
                                                  tools: [page], caller: caller, maxRounds: 8, store: nil))
        print("[WAKE-LIVE-IOS] quiet: status=\(run.status.rawValue) summary=\(run.summary ?? "-") message=\(run.message?.prefix(60) ?? "-")")
        XCTAssertEqual(run.status, .ok, run.statusNote ?? "")
        XCTAssertNil(run.message, "和上次一样就不发")
    }

    /// plan-floor-main-thread B：别的窗口〔状态〕里带着最近醒来做的事，问它能答上
    func testLiveHaikuKnowsWhatItDidWhenAskedElsewhere() async throws {
        let model = haiku()
        let now = Date()
        var done = WakeRun(taskId: "t", taskTitle: "灯塔日报", startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-3500),
                           trigger: .scheduled, status: .ok, summary: "读了雾湾日报：今晚亮第七盏备用灯")
        done.deliveredConversationId = "main"
        done.deliveredMessageId = "n"
        let status = (["〔状态〕", ConversationViewModel.statusTimeLine(now: now)] + WakeRecent.lines([done], mainSessionId: "main", now: now)).joined(separator: "\n")
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("wake-live-recent-\(UUID().uuidString).jsonl"))
        var reply = ""
        var failure: String?
        let finished = expectation(description: "reply")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "\(status)\n\n你今天自己醒来做了什么呀？")],
            systemPrompt: "你是她的朋友小岚，在她的手机里。", providerManager: try XCTUnwrap(manager), samplingParams: SamplingParams(),
            onToken: { reply += $0 }, onComplete: { _, _ in finished.fulfill() },
            onError: { failure = $0; finished.fulfill() }, onToolCalls: { _, _ in finished.fulfill() })
        await fulfillment(of: [finished], timeout: 180)
        if let failure { return XCTFail(CatalogLiveAuthProtocol.redacted(failure)) }
        print("[WAKE-LIVE-IOS] recent reply: \(reply.prefix(160).replacingOccurrences(of: "\n", with: " "))")
        XCTAssertTrue(reply.contains("灯塔") || reply.contains("第七") || reply.contains("七盏"), "要答出醒来做的灯塔日报：\(reply.prefix(160))")
    }

    /// plan-floor-main-thread：聊天里让它建任务，不说发哪 → 默认 mainsession
    func testLiveHaikuCreatesTaskDefaultingToMainSession() async throws {
        let model = haiku()
        let profileId = "xctest-wake-main-\(UUID().uuidString)"
        let router = ProviderRouter()
        router.ledger = UsageLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("wake-live-create-\(UUID().uuidString).jsonl"))
        var calls: [ToolCallBlock] = []
        var failure: String?
        let finished = expectation(description: "tool")
        router.sendStreaming(
            model: model,
            messages: [(role: "user", content: "以后每天早上 8 点帮我看看雾湾灯塔日报（https://fog-bay.invalid/daily），有变化就告诉我。")],
            systemPrompt: "你是她的朋友小岚，在她的手机里，可以用工具。", providerManager: try XCTUnwrap(manager), samplingParams: SamplingParams(),
            tools: [HeartbeatTaskTool.definition].map(ToolSchemaRenderer.anthropic),
            onToken: { _ in }, onComplete: { _, _ in failure = "没调工具"; finished.fulfill() },
            onError: { failure = $0; finished.fulfill() }, onToolCalls: { blocks, _ in calls = blocks; finished.fulfill() })
        await fulfillment(of: [finished], timeout: 180)
        if let failure { return XCTFail(CatalogLiveAuthProtocol.redacted(failure)) }
        let call = try XCTUnwrap(calls.first { $0.name == HeartbeatTaskTool.name })
        print("[WAKE-LIVE-IOS] create: \(call.argumentsJSON.prefix(240))")
        let result = HeartbeatTaskTool.execute(inputJSON: call.argumentsJSON, profileId: profileId, conversationId: "chat-1")
        XCTAssertFalse(result.isError, result.text)
        let store = WakeEngine.shared.store(profileId: profileId)
        let task = try XCTUnwrap(store.tasks().first)
        XCTAssertEqual(task.notify, .mainSession(push: true), "没说发哪 → mainsession")
        try? store.deleteTask(task.id)
    }
}
