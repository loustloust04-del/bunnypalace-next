import XCTest
import SwiftData
@testable import 记忆花园

/// 检查器预览 == 实发（plan-inspector-real-path §5.4/5.5）：同一次运行里先 previewTurn、再「重新生成」抓实发 body，整份相等（含 tools）。
@MainActor
final class InspectorRealPathTests: XCTestCase {

    private var harness: PromptRealPathHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    private func make(_ s: PromptScenario) async throws -> PromptRealPathHarness {
        let h = try await PromptRealPathHarness.make(s)
        harness = h
        return h
    }

    private func preview(_ h: PromptRealPathHarness, globalModelId: String? = nil) throws -> TurnPreview {
        try XCTUnwrap(h.viewModel.previewTurn(profile: h.profile, preset: h.preset, providerManager: h.providerManager,
                                               globalModelId: globalModelId, context: h.context, excludingNodeId: h.a2.id))
    }

    private func assertPreviewEqualsSend(_ s: PromptScenario) async throws {
        let h = try await make(s)
        let turn = try preview(h)
        XCTAssertEqual(turn.model.id, h.model.id)
        let previewBody = try XCTUnwrap(turn.requestBody(providerManager: h.providerManager), "\(s.name)：预览没出 body")
        let sent = try await h.regenerateCapturingBody()
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent), "\(s.name)：预览 body ≠ 实发 body")
    }

    func testG1PreviewEqualsSend() async throws {
        try await assertPreviewEqualsSend(PromptScenario(name: "G1-openai-full"))
    }

    func testG2PreviewEqualsSend() async throws {
        try await assertPreviewEqualsSend(PromptScenario(name: "G2-memory-off", memoryEnabled: false))
    }

    func testG3PreviewEqualsSend() async throws {
        try await assertPreviewEqualsSend(PromptScenario(name: "G3-cache-friendly", cacheFriendly: true))
    }

    func testG4PreviewEqualsSend() async throws {
        try await assertPreviewEqualsSend(PromptScenario(name: "G4-anthropic-blacklisted", providerType: .anthropic,
                                                         cacheFriendly: true, anthropicBlacklisted: true))
    }

    func testG5PreviewEqualsSend() async throws {
        try await assertPreviewEqualsSend(PromptScenario(name: "G5-non-streaming", streamingMode: .off))
    }

    func testG6PreviewEqualsSend() async throws {
        try await assertPreviewEqualsSend(PromptScenario(name: "G6-health-askonce-allowed", healthWeightAskOnceAllowed: true))
    }

    /// P1（本 bug）：对话钉了 OpenAI 兼容卡、全局指向 CC 卡 → 预览跟对话卡走，工具数 = 实发
    func testP1ConversationModelBeatsGlobal() async throws {
        let h = try await make(PromptScenario(name: "P1"))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc")
        let turn = try preview(h, globalModelId: cc.id)
        XCTAssertEqual(turn.model.id, h.model.id)
        XCTAssertNil(turn.toolsAbsentReason)
        let toolCount = try XCTUnwrap(turn.tools).count
        XCTAssertGreaterThan(toolCount, 0)
        let previewBody = try XCTUnwrap(turn.requestBody(providerManager: h.providerManager))
        let sent = try await h.regenerateCapturingBody()
        XCTAssertEqual((sent["tools"] as? [Any])?.count, toolCount)
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent))
    }

    /// P2：卡上关了工具调用 → 预览无工具、原因 = 卡关了；实发 body 也没有 tools
    func testP2CardToolsOff() async throws {
        let h = try await make(PromptScenario(name: "P2", cardToolsSupported: false))
        let turn = try preview(h)
        XCTAssertNil(turn.tools)
        XCTAssertEqual(turn.toolsAbsentReason, .cardToolsOff)
        let previewBody = try XCTUnwrap(turn.requestBody(providerManager: h.providerManager))
        let sent = try await h.regenerateCapturingBody()
        XCTAssertNil(sent["tools"])
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent))
    }

    /// v4-1 §六：发送时记账 = 插槽文字里实际出现的那几条；当前窗口还在窗口里的时间轴条目、老收尾段、和窗口重叠的段都不注；
    /// 同一个窗口的待续只带一次。预览不记账
    func testSendRecordsExactlyWhatIsInjected() async throws {
        let h = try await make(PromptScenario(name: "L"))
        let conv = try XCTUnwrap(h.viewModel.selectedConversation).id
        MemoryInjectionMeter.clear(profileId: h.profile.id)   // 搭夹具时发过两轮（那时还没放记忆文件）
        _ = try preview(h)
        XCTAssertNil(MemoryInjectionMeter.load(profileId: h.profile.id), "预览不记账")
        let sent = try await h.regenerateCapturingBody()
        let text = String(decoding: try JSONSerialization.data(withJSONObject: sent), as: UTF8.self)
            .replacingOccurrences(of: "\\n", with: "\n")
        let rec = try XCTUnwrap(MemoryInjectionMeter.load(profileId: h.profile.id))
        let other = PromptRealPathHarness.otherWindowId
        XCTAssertEqual(rec.timelineKeys, ["2026-10-08|\(other)", "2026-10-09|\(conv)", "2026-10-10|\(other)"])
        XCTAssertEqual(rec.contextKeys, ["\(conv.prefix(8))|\(PromptRealPathHarness.goneNodeId)"])
        XCTAssertTrue(text.contains("[时间轴]") && text.contains("[上下文摘要]"))
        XCTAssertTrue(text.contains("聊了团子的体检") && text.contains("本窗口早先聊的") && text.contains("给团子买了猫粮；停在挑罐头（待续：周末问团子吃不吃）"))
        XCTAssertTrue(text.contains("挤出视野的一段的经过"))
        XCTAssertFalse(text.contains("不该注入") || text.contains("不该出现的待续"), "和窗口原文重复的不注")
        XCTAssertFalse(text.contains("旧待续"), "同一个窗口待续只带在最新那条后面")
    }

    /// astra #11：时间轴插槽关了 / 预设里没有时间轴插槽 → 组装出来没有时间轴段，记账一条都不记
    func testTimelineLedgerFollowsAssembledSegments() async throws {
        let h = try await make(PromptScenario(name: "L2"))
        func send(_ preset: Preset) -> [String]? {
            MemoryInjectionMeter.clear(profileId: h.profile.id)
            let composed = h.viewModel.composePrompt(profile: h.profile, preset: preset, excludingNodeId: h.a2.id, context: h.context,
                                                     globalEntries: h.viewModel.globalWorldBookEntries, fileLibraryHint: nil, mode: .send)
            XCTAssertEqual(composed.segments.contains { $0.source == .timeline }, preset.prompts.contains { $0.id == PromptSlot.timelineId && $0.isEnabled })
            return MemoryInjectionMeter.load(profileId: h.profile.id)?.timelineKeys
        }
        XCTAssertEqual(send(h.preset)?.count, 3, "插槽开着：三条都记")
        var disabled = h.preset
        disabled.prompts = disabled.prompts.map { var p = $0; if p.id == PromptSlot.timelineId { p.isEnabled = false }; return p }
        XCTAssertEqual(send(disabled), [], "插槽关了：不记")
        var missing = h.preset
        missing.prompts.removeAll { $0.id == PromptSlot.timelineId }
        XCTAssertEqual(send(missing), [], "预设里没有插槽：不记")
    }

    /// P3：没有对话（设置页入口）→ nil，不编数字
    func testP3NoConversation() throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let profile = Profile(id: "xctest-inspector-none", name: "Test", emoji: "🧪", description: "",
                              userName: "User", assistantName: "Assistant")
        XCTAssertNil(ConversationViewModel().previewTurn(profile: profile, preset: .balanced, providerManager: ProviderManager(),
                                                         globalModelId: nil, context: ModelContext(container)))
    }

    /// 5.5：预览不写库、不钉模型、不写授权 / CC session、不启动向量回填
    func testPreviewHasNoSideEffects() async throws {
        let h = try await make(PromptScenario(name: "S"))
        h.overrideDefault("mem_inject_vector", true)
        let conv = try XCTUnwrap(h.viewModel.selectedConversation)
        conv.selectedModelId = ""
        try h.context.save()
        let before = (conv.selectedModelId, conv.permGrantsRaw, conv.ccBridgeSessionName)
        let start = Date()

        let turn = try preview(h, globalModelId: h.model.id)
        XCTAssertEqual(turn.model.id, h.model.id, "对话没钉模型时退全局")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(h.context.hasChanges)
        XCTAssertEqual(conv.selectedModelId, before.0, "预览不把模型钉到对话")
        XCTAssertEqual(conv.permGrantsRaw, before.1)
        XCTAssertEqual(conv.ccBridgeSessionName, before.2)
        XCTAssertFalse(CacheDiagLog.shared.entries.contains { $0.time >= start && $0.text.contains("向量回填启动") })
    }

    /// #089 P0-c：网络层存下的那份 = provider 实发的 body（检查器默认显示它）
    func testSentRequestStoreHoldsActualSentBody() async throws {
        let h = try await make(PromptScenario(name: "G4-anthropic-blacklisted", providerType: .anthropic,
                                              cacheFriendly: true, anthropicBlacklisted: true))
        let sent = try await h.regenerateCapturingBody()
        let convId = try XCTUnwrap(h.viewModel.selectedConversation?.id)
        let stored = await SentRequestStore.shared.latest(conversationId: convId)
        let first = try XCTUnwrap(stored?.requests.first, "发出去没存")
        XCTAssertEqual(first.round, 0)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(first.body.utf8)) as? [String: Any])
        XCTAssertEqual(try h.canonical(parsed), try h.canonical(sent))
    }

    /// #089 P0-a：还没打字时预览（当前路径以 assistant 结尾），最后一条补占位用户消息，不以 assistant 结尾
    func testPreviewWithoutNewMessageEndsWithPlaceholderUser() async throws {
        let h = try await make(PromptScenario(name: "G1-openai-full"))
        let turn = try XCTUnwrap(h.viewModel.previewTurn(profile: h.profile, preset: h.preset, providerManager: h.providerManager,
                                                          globalModelId: nil, context: h.context))
        // 钉进 system 前缀的段（文件库等）排在序列尾，发出去在 system 里，不算消息
        let last = try XCTUnwrap(turn.ordered.last { !$0.pinnedToSystemPrefix && $0.role != "system" })
        XCTAssertEqual(last.role, "user")
        XCTAssertTrue(last.content.contains(ConversationViewModel.previewNextUserPlaceholder), last.content)
        let body = try XCTUnwrap(turn.requestBody(providerManager: h.providerManager))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["role"] as? String, "user")
    }
}
