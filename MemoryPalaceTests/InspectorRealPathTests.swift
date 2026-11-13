import MemoryCore
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
        h.overrideDefault(RecallTuningStore.storageKey, try JSONEncoder().encode([h.profile.id: RecallTestTuning.make()]))
        return h
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), description)
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

    /// ⑤-1 P2-b r2：来源窗已删 / 关参与的碎片不进实发；预览 = 实发。
    /// 走真实 VM → composePrompt 接线（单测只测 `roundInputs`，删掉这里任何一处传参都得红）
    func testHiddenSourceWindowFragmentsNeverReachSend() async throws {
        let h = try await make(PromptScenario(name: "hidden-source-windows"))
        // 走「触发关」的全量注入路径（非钉住碎片才会进 X 来源）；trigger 开时由 recall 选择，
        // 与这段要测的过滤接线无关
        var tuning = RecallTestTuning.make()
        tuning.archiveTriggerEnabled = false
        h.overrideDefault(RecallTuningStore.storageKey, try JSONEncoder().encode([h.profile.id: tuning]))
        func window(_ id: String, enabled: Bool = true, trashed: Bool = false) {
            let c = Conversation(id: id, title: "窗口\(id)", createTime: Date(timeIntervalSince1970: 1),
                                 updateTime: Date(timeIntervalSince1970: 1), currentNodeId: "", provider: "api",
                                 profileId: h.profile.id)
            c.memoryEnabled = enabled
            c.isTrashed = trashed
            h.context.insert(c)
        }
        window("xctest-source-open")
        window("xctest-source-off", enabled: false)
        window("xctest-source-trash", trashed: true)
        let store = SwiftDataMemoryStore()
        for (content, source) in [("开着的来源窗碎片", "xctest-source-open"),
                                  ("关参与的来源窗碎片", "xctest-source-off"),
                                  ("回收站的来源窗碎片", "xctest-source-trash")] {
            let m = try store.add(content: content, category: "event", keywords: [], profileId: h.profile.id,
                                  isUserExplicit: false, extractedBy: "t", sourceConversationId: source, context: h.context)
            m.occurredDay = "2026-11-01"
            m.reviewedAt = Date()
        }
        try h.context.save()
        // 前两轮发送留下的 recall 回执（user / assistant 节点都可能有）会带旧 tuning（trigger 开）覆盖本场景设置
        for node in h.viewModel.currentPath { node.recallReceipt = nil }
        try h.context.save()

        let turn = try preview(h)
        let previewBody = try XCTUnwrap(turn.requestBody(providerManager: h.providerManager), "预览没出 body")
        let sent = try await h.regenerateCapturingBody()
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent), "预览 body ≠ 实发 body")

        for body in [previewBody, sent] {
            let text = try h.canonical(body)
            XCTAssertTrue(text.contains("开着的来源窗碎片"), "开着的来源窗碎片照带")
            XCTAssertFalse(text.contains("关参与的来源窗碎片"), "关参与来源窗的碎片不带")
            XCTAssertFalse(text.contains("回收站的来源窗碎片"), "回收站来源窗的碎片不带")
        }
        // 门控快照：挡掉的条数进账（关参与 + 回收站各一条候选），预览 = 实发
        XCTAssertEqual(turn.delivery.gate.hiddenFragments, 2, "被来源窗挡掉的碎片候选")
        XCTAssertEqual(turn.delivery.gate.hiddenTimeline, 0)
        let assistant = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertEqual(assistant.recallReceipt?.delivery?.gate, turn.delivery.gate, "实发回执同口径")
    }

    /// P2-b：检查器带的那份 delivery = 实发写进回执的那份（send / preview 同一个 `MemoryDelivery.build`）
    func testPreviewDeliveryEqualsSendDelivery() async throws {
        let h = try await make(PromptScenario(name: "delivery-preview"))
        let turn = try preview(h)
        let before = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        _ = try await h.regenerateCapturingBody()
        let regenerated = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "assistant" })
        XCTAssertNotEqual(regenerated.id, before.id)
        let receipt = try XCTUnwrap(regenerated.recallReceipt)
        XCTAssertEqual(turn.delivery, receipt.delivery, "预览 delivery ≠ 实发 delivery")
        XCTAssertFalse(turn.delivery.items.isEmpty, "这场景至少有时间轴 / A2 / 碎片")
        XCTAssertTrue(turn.delivery.gate.participates)
    }

    /// 直接读 A2 的生产输入；C2 当前消费同一输入并只排除 agentOrigin，保持写手算法不变。
    func testRecallInjectionNeverEntersA2OrC2ExtractionInput() async throws {
        let h = try await make(PromptScenario(name: "recall-extraction-input", memoryFixtures: false))
        let users = h.viewModel.currentPath.filter { $0.role == "user" }
        try XCTUnwrap(users.first).content = "星砚今天在云桥城"
        try XCTUnwrap(users.last).content = "星砚想聊林栖周末在云桥城的安排"
        // 原节点已换成新文本，不复用搭夹具时「第二条」的失败发送决策。
        for user in users { user.recallReceipt = nil }
        let assistant = try XCTUnwrap(h.viewModel.currentPath.first { $0.role == "assistant" })
        assistant.content = "岚舟的真实答复"
        assistant.setSegments([
            .toolUse(id: "recall-smoke", name: RecallTool.toolName, inputJSON: #"{"query":"工具参数专属：林栖"}"#, integrationName: nil, iconName: nil),
            .toolResult(toolUseId: "recall-smoke", text: "工具原文专属：林栖旧资料", isError: false, integrationName: nil),
            .text("岚舟的真实答复")
        ])
        h.a2.content = "岚舟自主任务专属消息"
        h.a2.agentOrigin = "recall-smoke-agent"
        try h.context.save()
        try await h.seedWiki([WikiPage(path: "人/林栖", hook: "记忆钩子专属：云桥城朋友",
                                       title: "林栖", now: "记忆载荷专属：周末约定")])
        let warmed = try await WikiInjectionCache.shared.warm(h.profile.id, WikiInjectionCache.source(profileId: h.profile.id))
        let original = PromptAssembler.historyNodes(h.viewModel.currentPath)
            .filter { $0.role == "user" || $0.role == "assistant" }.map { ($0.id, $0.content) }
        for cache in [false, true] {
            var preset = h.preset
            preset.sampling.cacheFriendly = cache
            for idx in preset.prompts.indices where preset.prompts[idx].id == PromptSlot.memoryInjectionId {
                preset.prompts[idx].role = "user"
                preset.prompts[idx].injectionPosition = .absolute
                preset.prompts[idx].injectionDepth = 0
            }
            let composed = h.viewModel.composePrompt(profile: h.profile, preset: preset, excludingNodeId: nil,
                                                      context: h.context, globalEntries: [], fileLibraryHint: nil,
                                                      mode: .preview, warmedWiki: warmed)
            XCTAssertTrue(composed.segments.contains { $0.source == .memory && $0.content.contains("记忆载荷专属") },
                          "先证明本轮真的组装了记忆，不以空注入通过不回流测试")
            let a2 = h.viewModel.sessionMessages()
            let agentIds = Set(h.viewModel.currentPath.filter { $0.agentOrigin != nil }.map(\.id))
            // 与 extractMemoriesIfNeeded 的现有 C2 入口完全相同，不启动写手或模型。
            let c2 = a2.filter { !agentIds.contains($0.id) }
            XCTAssertEqual(a2.map(\.id), original.map(\.0))
            XCTAssertEqual(c2.map(\.id), original.map(\.0).filter { !agentIds.contains($0) })
            XCTAssertTrue(a2.contains { $0.id == h.a2.id })
            XCTAssertFalse(c2.contains { $0.id == h.a2.id })
            XCTAssertEqual(a2.first { $0.id == assistant.id }?.content, "[调用了 recall]\n岚舟的真实答复")
            XCTAssertEqual(c2.first { $0.id == assistant.id }?.content, "[调用了 recall]\n岚舟的真实答复")
            for input in [a2, c2] {
                let text = input.map(\.content).joined(separator: "\n")
                XCTAssertTrue(text.contains("星砚想聊林栖周末在云桥城的安排"))
                XCTAssertTrue(text.contains("岚舟的真实答复"))
                XCTAssertTrue(text.contains("[调用了 recall"), "工具只保留生产中性动作")
                for excluded in ["记忆载荷专属", "记忆钩子专属", "工具原文专属", "工具参数专属"] {
                    XCTAssertFalse(text.contains(excluded), excluded)
                }
            }
            XCTAssertEqual(PromptAssembler.historyNodes(h.viewModel.currentPath)
                .filter { $0.role == "user" || $0.role == "assistant" }.map(\.content), original.map(\.1), "出口组装不改写真实节点")
        }
    }

    /// 走真实 VM → router → provider.sendStreaming → RequestBodyTap，而非仅对 buildRequestBody 的替代输入断言。
    func testRecallMemoryIsSystemOnActualSendAcrossCacheRolesAndProviders() async throws {
        for provider in [ProviderType.openaiCompatible, .anthropic] {
            for cache in [false, true] {
                let h = try await make(PromptScenario(name: "recall-real-wire-\(provider)-\(cache)",
                                                      profileId: "xctest-recall-wire", providerType: provider,
                                                      cacheFriendly: cache, memoryFixtures: false))
                try await h.seedWiki([WikiPage(path: "人/林栖", hook: "岚舟记忆钩子专属",
                                               title: "林栖", now: "云桥城记忆载荷专属")])
                var worldBook = WorldBookEntry()
                worldBook.keys = ["林栖"]
                worldBook.content = "星砚世界书动态专属"
                h.viewModel.globalWorldBookEntries = [worldBook]
                for role in ["user", "assistant"] {
                    for depth in [0, 1] {
                        var preset = h.preset
                        for index in preset.prompts.indices where preset.prompts[index].id == PromptSlot.memoryInjectionId {
                            preset.prompts[index].role = role
                            preset.prompts[index].injectionPosition = .absolute
                            preset.prompts[index].injectionDepth = depth
                        }
                        var captured: [String: Any]?
                        RequestBodyTap.handler = { captured = $0 }
                        let submitted = h.viewModel.sendMessage("星砚想聊林栖在云桥城的安排", model: h.model,
                                                                profile: h.profile, preset: preset,
                                                                providerManager: h.providerManager, context: h.context)
                        XCTAssertTrue(submitted)
                        await waitUntil("provider 未构造真实发送 body") { captured != nil }
                        h.viewModel.cancelAssistantTurn(context: h.context)
                        await h.waitForTurn()
                        RequestBodyTap.handler = nil
                        let body = try XCTUnwrap(captured, "真实发送没有构造 body")
                        func text(_ message: [String: Any]) -> String {
                            if let content = message["content"] as? String { return content }
                            return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        }
                        let messages = body["messages"] as? [[String: Any]] ?? []
                        let topSystem = (body["system"] as? String)
                            ?? (body["system"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        let system = ([topSystem] + messages.filter { $0["role"] as? String == "system" }.map(text)).joined(separator: "\n")
                        let nonSystem = messages.filter { $0["role"] as? String != "system" }.map(text).joined(separator: "\n")
                        for payload in ["[[人/林栖]]", "岚舟记忆钩子专属", "云桥城记忆载荷专属"] {
                            XCTAssertTrue(system.contains(payload), "provider=\(provider), cache=\(cache), role=\(role), depth=\(depth)：\(payload)")
                            XCTAssertFalse(nonSystem.contains(payload), payload)
                        }
                        if cache {
                            XCTAssertTrue(nonSystem.contains(worldBook.content), "世界书仍走非记忆动态策略")
                            XCTAssertFalse(system.contains(worldBook.content))
                        }
                        let persisted = h.viewModel.currentPath.map(\.content).joined(separator: "\n")
                        XCTAssertFalse(persisted.contains("岚舟记忆钩子专属"))
                        XCTAssertFalse(persisted.contains("云桥城记忆载荷专属"))
                    }
                }
                await h.tearDown()
                harness = nil
            }
        }
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

    /// v4-1 §六：发送时记账 = 插槽文字里实际出现的那几行；当前窗口还在窗口里的时间轴条目、老收尾段、和窗口重叠的段都不注；
    /// 同一个窗口的待续只带一次。预览不记账。c2c3-v2 第 7 段：夹具是老条目——今天、昨天的老条目逐条带（旧格式），
    /// 第 3 天往前没有主调的带一行旧格式；记账键 = 一天「日期」+ 老条目「日期|窗口」；待续单独一段、带窗口编号
    func testSendRecordsExactlyWhatIsInjected() async throws {
        let h = try await make(PromptScenario(name: "L"))
        let conv = try XCTUnwrap(h.viewModel.selectedConversation).id
        MemoryInjectionMeter.clear(profileId: h.profile.id)   // 搭夹具时发过两轮（那时还没放记忆文件）
        _ = try preview(h)
        XCTAssertNil(MemoryInjectionMeter.load(profileId: h.profile.id), "预览不记账")
        // 回执归新回复自己的节点；请求失败时占位节点会被删掉，所以在建 body 那一刻取（= 组装时算好的那份）
        var captured: [String: Any]?
        var capturedRecord: MemoryInjectionRecord?
        RequestBodyTap.handler = { body in
            captured = body
            capturedRecord = h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt?.injectionRecord
        }
        defer { RequestBodyTap.handler = nil }
        h.viewModel.regenerate(assistantNodeId: h.a2.id, model: h.model, profile: h.profile,
                               preset: h.preset, providerManager: h.providerManager, context: h.context)
        let deadline = Date().addingTimeInterval(5)
        while captured == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        await h.waitForTurn()
        let sent = try XCTUnwrap(captured, "实发没有建 body")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: sent), as: UTF8.self)
            .replacingOccurrences(of: "\\n", with: "\n")
        let rec = try XCTUnwrap(capturedRecord)
        XCTAssertNil(MemoryInjectionMeter.load(profileId: h.profile.id), "没有有效响应，Meter 还不该写")
        let other = PromptRealPathHarness.otherWindowId
        XCTAssertEqual(rec.timelineKeys, ["2026-10-08", "2026-10-09", "2026-10-10", "2026-10-10|\(other)"])
        XCTAssertEqual(rec.contextKeys, ["\(conv.prefix(8))|\(PromptRealPathHarness.goneNodeId)"])
        XCTAssertTrue(text.contains("[时间轴]") && text.contains("[上下文摘要]"))
        XCTAssertTrue(text.contains("聊了团子的体检") && text.contains("本窗口早先聊的") && text.contains("给团子买了猫粮；停在挑罐头 conv xctest-o"))
        XCTAssertTrue(text.contains("[待续]") && text.contains("conv xctest-o：周末问团子吃不吃"))
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
            return h.a2.recallReceipt?.injectionRecord?.timelineKeys
        }
        XCTAssertEqual(send(h.preset)?.count, 4, "插槽开着：三天的行 + 10 号那条老条目都记")
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

    /// #094：记忆表里学到「不收采样组 / stream_options、键名要 max_completion_tokens」→ 预览和实发都照着剥，整份相等
    func testLearnedParamsAppliedToPreviewAndSend() async throws {
        let h = try await make(PromptScenario(name: "G1-openai-full"))
        let baseURL = try XCTUnwrap(h.providerManager.provider(for: h.model)?.baseURL)
        ParamAdaptStore.shared.learn(
            providerType: .openaiCompatible, baseURL: baseURL, modelId: h.model.modelId,
            adding: .init(groups: [ParamCompat.Group.sampling, ParamCompat.Group.streamOptions], maxTokensKey: "max_completion_tokens"),
            rawError: "xctest")
        defer { ParamAdaptStore.shared.remove(key: ParamAdaptStore.key(providerType: .openaiCompatible, baseURL: baseURL, modelId: h.model.modelId)) }

        let turn = try preview(h)
        let previewBody = try XCTUnwrap(turn.requestBody(providerManager: h.providerManager))
        let sent = try await h.regenerateCapturingBody()
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent))
        for body in [previewBody, sent] {
            XCTAssertNil(body["temperature"])
            XCTAssertNil(body["top_p"])
            XCTAssertNil(body["stream_options"])
            XCTAssertNil(body["max_tokens"])
            XCTAssertNotNil(body["max_completion_tokens"])
        }
    }

    // MARK: #093 工具抽屉

    /// 抽屉关一个（fs_write）、收一个（roll_dice）、本楼层覆盖一个（remember 关）；历史 a1 调过 fs_write / roll_dice → 预览 = 实发
    private func drawerScenario(historyCall: String) async throws -> (h: PromptRealPathHarness, preview: [String: Any], sent: [String: Any]) {
        let h = try await make(PromptScenario(name: "D-drawer-\(historyCall)"))
        ToolDrawerStore.shared.update {   // 夹具已清成默认，tearDown 还原 toolDrawer.v1 并重读
            $0.set(.off, for: FileLibraryTools.Name.write.rawValue, profileId: nil)
            $0.set(.tucked, for: DiceTool.toolName, profileId: nil)
            $0.set(.off, for: SelfMemoryTool.rememberName, profileId: h.profile.id)
        }
        let a1 = try XCTUnwrap(h.viewModel.currentPath.first { $0.role == "assistant" })
        a1.setSegments([.toolUse(id: "call_d1", name: historyCall, inputJSON: #"{"path":"x.md","content":"y"}"#, integrationName: nil, iconName: nil),
                        .toolResult(toolUseId: "call_d1", text: "ok", isError: false, integrationName: nil),
                        .text("回复一")])
        try h.context.save()
        let turn = try preview(h)
        let previewBody = try XCTUnwrap(turn.requestBody(providerManager: h.providerManager))
        let sent = try await h.regenerateCapturingBody()
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent), "抽屉改过：预览 body ≠ 实发 body")
        // 抽屉页顶部数字（previewTools）和实发记下的工具签名同源
        let drawerPreview = try XCTUnwrap(h.viewModel.previewTools(providerManager: h.providerManager, profileModelId: nil, globalModelId: nil))
        let convId = try XCTUnwrap(h.viewModel.selectedConversation?.id)
        XCTAssertEqual(drawerPreview.signature, ToolDrawerStore.shared.sentSignature(conversationId: convId))
        XCTAssertEqual(drawerPreview.toolCount, (sent["tools"] as? [Any])?.count)
        XCTAssertEqual(drawerPreview.tuckedCount, turn.tuckedTools.count)
        return (h, previewBody, sent)
    }

    private func toolNames(_ body: [String: Any]) -> Set<String> {
        ToolReplay.clientToolNames(body["tools"] as? [[String: Any]])
    }

    private func historyCallNames(_ body: [String: Any]) -> [String] {
        ((body["messages"] as? [[String: Any]]) ?? []).flatMap { m in
            ((m["tool_calls"] as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }
    }

    func testDrawerOffToolInHistoryFallsBackToTextInPreviewAndSend() async throws {
        let (h, _, sent) = try await drawerScenario(historyCall: FileLibraryTools.Name.write.rawValue)
        let names = toolNames(sent)
        XCTAssertFalse(names.contains(FileLibraryTools.Name.write.rawValue), "关了的不发")
        XCTAssertFalse(names.contains(DiceTool.toolName), "收起的不在清单")
        XCTAssertFalse(names.contains(SelfMemoryTool.rememberName), "本楼层关了")
        XCTAssertTrue(names.contains(MetaTools.invokeName))
        XCTAssertTrue(names.contains(FileLibraryTools.Name.read.rawValue))
        XCTAssertEqual(historyCallNames(sent), [], "关掉的 fs_write 不包成 tool_invoke 发")
        let text = try h.canonical(sent)
        XCTAssertTrue(text.contains("〔系统记录"), "那条退纯文字 + 系统记录")
        XCTAssertTrue(text.contains("- \(DiceTool.toolName) — "), "收起的进〔更多工具〕")
    }

    func testDrawerTuckedToolInHistoryRewrappedInPreviewAndSend() async throws {
        let (_, _, sent) = try await drawerScenario(historyCall: DiceTool.toolName)
        XCTAssertEqual(historyCallNames(sent), [MetaTools.invokeName], "收起的照 #089 规矩包回 tool_invoke")
    }

    // MARK: 工具关了，说明也不带（粟粟 10-15：哪个工具关了就不带那一串提示词；卡片段选 A）

    private static let toolHintMarkers = ["<文件库>", "<设备>", "<命令>", "〔更多工具〕", "〔回忆〕", "〔我的记忆〕", "〔当前能用的工具〕",
                                          "[聊天卡片]", "## MCP 外部工具", "〔外部工具〕", "〔到点提醒〕"]

    private func toolsOffScenario(_ name: String, configure: (PromptRealPathHarness) -> Void) async throws -> (h: PromptRealPathHarness, sent: [String: Any]) {
        let h = try await make(PromptScenario(name: name))
        configure(h)
        let turn = try preview(h)
        let previewBody = try XCTUnwrap(turn.requestBody(providerManager: h.providerManager))
        let sent = try await h.regenerateCapturingBody()
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent), "\(name)：预览 body ≠ 实发 body")
        return (h, sent)
    }

    private func drawerAllOff(except kept: Set<String> = []) {
        ToolDrawerStore.shared.update { state in
            for item in ToolDrawerCatalog.items where !kept.contains(item.name) { state.set(.off, for: item.name, profileId: nil) }
            for name in kept { state.set(.inline, for: name, profileId: nil) }
        }
    }

    func testDrawerAllOffRetainsOnlyTurnStatus() async throws {
        let (_, sent) = try await toolsOffScenario("T-drawer-all-off") { _ in drawerAllOff() }
        XCTAssertEqual(toolNames(sent), [TurnStatusTool.toolName])
    }

    /// atrium P3⑤0：健康手账约定段（文件库段里）按这个对话所在的层读体重档位——默认不允许、本层允许才带；
    /// 别的层单独允许不影响这一层。预览 = 实发同一份组装，这里只看预览
    func testHealthLogHintFollowsFloor() async throws {
        let h = try await make(PromptScenario(name: "perm-floor-health-hint", voiceHint: false, memoryFixtures: false))
        h.context.insert(WeightEntry(profileId: h.profile.id, date: Date(), weightKg: 52.0))
        try h.context.save()
        XCTAssertEqual(PermissionCenter.defaultLevel(.healthWeight), .notAllowed)
        func hasHint() throws -> Bool {
            let body = try XCTUnwrap(try preview(h).requestBody(providerManager: h.providerManager))
            return try h.canonical(body).contains("```health-log")
        }
        XCTAssertFalse(try hasHint(), "默认不允许")
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: "xctest-perm-other-floor")
        XCTAssertFalse(try hasHint(), "别的层允许不串过来")
        PermissionCenter.setFloorLevel(.bypass, for: .healthWeight, profileId: h.profile.id)
        XCTAssertTrue(try hasHint(), "本层单独允许")
    }

    func testToolsMasterOffSendsNoToolHints() async throws {
        let (h, sent) = try await toolsOffScenario("T-master-off") {
            $0.overrideDefault(PermissionDomain.toolsMaster.storageKey, PermissionLevel.notAllowed.rawValue)
        }
        XCTAssertNil(sent["tools"])
        let text = try h.canonical(sent)
        for marker in Self.toolHintMarkers { XCTAssertFalse(text.contains(marker), "总开关关了还带着 \(marker)") }
    }

    func testOnlySelectedDrawerToolsAndTurnStatusAreSent() async throws {
        let kept: Set<String> = [FileLibraryTools.Name.read.rawValue, OCRImageTool.toolName]
        let (_, sent) = try await toolsOffScenario("T-two-tools") { _ in drawerAllOff(except: kept) }
        XCTAssertEqual(toolNames(sent), kept.union([TurnStatusTool.toolName]))
    }

    /// card_guide 开着、roll_dice / ask_user 关着：卡片目录还在，但不再提那两个工具
    func testCardIndexDropsSentencesForOffTools() async throws {
        let (h, sent) = try await toolsOffScenario("T-card-no-dice") { _ in
            ToolDrawerStore.shared.update {
                $0.set(.off, for: DiceTool.toolName, profileId: nil)
                $0.set(.off, for: AskUserTool.toolName, profileId: nil)
            }
        }
        let text = try h.canonical(sent)
        XCTAssertTrue(text.contains("[聊天卡片]"))
        XCTAssertFalse(text.contains(DiceTool.toolName))
        XCTAssertFalse(text.contains(AskUserTool.toolName))
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

    func testWikiNewTopicIgnoresPreviousTopicAndSyntheticMessages() async throws {
        let h = try await make(PromptScenario(name: "wiki-synthetic"))
        let oldest = try XCTUnwrap(h.viewModel.currentPath.first { $0.role == "user" })
        oldest.content = "岚舟刚才提到云桥城"
        let latest = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        latest.content = "星砚想了解林栖的周末安排"
        // 这些真实消息替换了 harness 的短句，不能复用原来短句的已存决策。
        for node in h.viewModel.currentPath { node.recallReceipt = nil }
        h.a2.content = "<think>思考专属词</think>[thinking]思考专属词[/thinking]岚舟回复二"
        try await h.seedWiki([
            WikiPage(path: "人/林栖", title: "林栖", now: "本轮真实用户消息命中。"),
            WikiPage(path: "主题/云桥城", title: "云桥城", now: "旧话题不该触发。"),
            WikiPage(path: "主题/占位", triggers: ["你的下一条消息"], title: "占位", now: "占位文案不该触发。"),
            WikiPage(path: "主题/卡片", triggers: ["卡片里有新动作"], title: "卡片", now: "卡片文案不该触发。"),
            WikiPage(path: "主题/思考", triggers: ["思考专属词"], title: "思考", now: "思考文案不该触发。"),
        ])
        let warmed = try await WikiInjectionCache.shared.warm(h.profile.id, WikiInjectionCache.source(profileId: h.profile.id))
        for cacheFriendly in [false, true] {
            var preset = h.preset
            preset.sampling.cacheFriendly = cacheFriendly
            for mode in [ConversationViewModel.ComposeMode.preview, .send] {
                let prompt = h.viewModel.composePrompt(profile: h.profile, preset: preset, excludingNodeId: nil,
                                                       context: h.context, globalEntries: [], fileLibraryHint: nil, mode: mode,
                                                       warmedWiki: mode == .send ? warmed : nil)
                let text = prompt.segments.map(\.content).joined(separator: "\n")
                XCTAssertEqual(prompt.recallDecision.gateReason, .search)
                XCTAssertEqual(prompt.recallDecision.selected.map(\.source.path), ["人/林栖"])
                XCTAssertTrue(text.contains("现在：本轮真实用户消息命中。"), "补合成 user 不能覆盖本轮真实用户查询")
                XCTAssertFalse(text.contains("现在：旧话题不该触发。"), "新话题下界不回扫倒数第四条")
                XCTAssertFalse(text.contains("现在：占位文案不该触发。"))
                XCTAssertFalse(text.contains("现在：卡片文案不该触发。"))
                XCTAssertFalse(text.contains("现在：思考文案不该触发。"))
            }
        }
    }

    func testRegenerateWarmsInvalidatedWikiBeforeRequest() async throws {
        let h = try await make(PromptScenario(name: "wiki-regenerate", cacheFriendly: true))
        try await h.seedWiki([WikiPage(path: "人/林栖", title: "林栖", now: "在云桥城筹备合成展览。")])
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        user.content = "星砚想聊林栖在云桥城的安排"
        let warmed = try await WikiInjectionCache.shared.warm(h.profile.id, WikiInjectionCache.source(profileId: h.profile.id))
        var tuning = RecallTestTuning.make()
        tuning.maximumPages = 2
        let anchor = conversation.recallState.branchAnchor.isEmpty ? conversation.id : conversation.recallState.branchAnchor
        let prior = RecallSelection.prepare(
            profile: h.profile, conversationId: conversation.id, turnId: user.id, branchAnchor: anchor,
            text: user.content, state: .init(), existingDecision: nil,
            inputs: .init(memories: [], selfMemory: nil, archiveBudget: 5_000, wiki: warmed.snapshot),
            recentMessages: [user.content], now: MemoryClock.now, tuning: tuning).decision
        XCTAssertEqual(prior.selected.map(\.source.path), ["人/林栖"])
        user.recallReceipt = RecallTurnReceipt(decision: prior)
        h.a2.recallReceipt = RecallTurnReceipt(decision: prior)
        try h.context.save()

        let wiki = await Task.detached { WikiStore(profileId: h.profile.id) }.value
        try wiki.save(WikiPage(path: "主题/云桥城", hook: "岚舟新增目录标记", title: "云桥城", now: "重生成不应新增选页。"))
        try wiki.rebuildAllIndexes()
        var captured: [String: Any]?
        var freshWhenRequestBuilt = false
        var replayDecision: RecallTurnDecision?
        RequestBodyTap.handler = {
            captured = $0
            freshWhenRequestBuilt = WikiInjectionCache.shared.isFresh(h.profile.id)
            replayDecision = h.viewModel.currentPath.last { $0.role == "assistant" }?.recallReceipt?.decision
        }
        defer { RequestBodyTap.handler = nil }
        h.viewModel.regenerate(assistantNodeId: h.a2.id, model: h.model, profile: h.profile, preset: h.preset,
                               providerManager: h.providerManager, context: h.context)
        await h.waitForTurn()
        let text = try h.canonical(XCTUnwrap(captured))
        XCTAssertTrue(freshWhenRequestBuilt, "请求组装前必须 warm 被作废的 wiki")
        XCTAssertTrue(text.contains("[C 档案 · 索引]"))
        XCTAssertTrue(text.contains("岚舟新增目录标记"), "根索引使用刚 warm 的新快照")
        XCTAssertTrue(text.contains("现在：在云桥城筹备合成展览。"), "同版原选页仍可复用")
        XCTAssertFalse(text.contains("现在：重生成不应新增选页。"), "重生成不因新索引重搜同轮")
        let replay = try XCTUnwrap(replayDecision)
        XCTAssertEqual(replay.origin, .continuation)
        XCTAssertEqual(replay.turnId, prior.turnId)
        XCTAssertEqual(replay.selected, prior.selected)
        XCTAssertEqual(replay.tuning, tuning)
    }

    func testEditResendWarmsInvalidatedWikiBeforeRequest() async throws {
        let h = try await make(PromptScenario(name: "wiki-edit", cacheFriendly: true))
        try await h.seedWiki([])
        let wiki = await Task.detached { WikiStore(profileId: h.profile.id) }.value
        try wiki.save(WikiPage(path: "主题/月光书店", title: "月光书店", now: "编辑重发用的新页。"))
        try wiki.rebuildAllIndexes()
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        var captured: [String: Any]?
        RequestBodyTap.handler = { captured = $0 }
        defer { RequestBodyTap.handler = nil }
        XCTAssertTrue(h.viewModel.editAndResend(user.id, newText: "去月光书店", isEdit: true,
                                               model: h.model, profile: h.profile, preset: h.preset,
                                               providerManager: h.providerManager, context: h.context))
        await h.waitForTurn()
        let text = try h.canonical(XCTUnwrap(captured))
        XCTAssertTrue(text.contains("现在：编辑重发用的新页。"))
    }

    private final class WikiWarmGate: @unchecked Sendable {
        let root: URL
        let entered: XCTestExpectation
        private let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var firstRead = true

        init(root: URL, entered: XCTestExpectation) {
            self.root = root
            self.entered = entered
        }

        func source() -> WikiStore {
            lock.lock()
            let shouldBlock = firstRead
            firstRead = false
            lock.unlock()
            if shouldBlock {
                entered.fulfill()
                release.wait()
            }
            return WikiStore(root: root)
        }

        func open() { release.signal() }
    }

    private enum PreparingEntry: Equatable { case send, regenerate, edit }
    private enum PreparingExit: Equatable { case stop, floor, conversation, branch, branchMap, search }

    private func beginPreparation(_ entry: PreparingEntry, _ h: PromptRealPathHarness) throws {
        switch entry {
        case .send:
            XCTAssertTrue(h.viewModel.sendMessage("被取消的正文", model: h.model, profile: h.profile, preset: h.preset,
                                                  providerManager: h.providerManager, context: h.context))
        case .regenerate:
            h.viewModel.regenerate(assistantNodeId: h.a2.id, model: h.model, profile: h.profile, preset: h.preset,
                                   providerManager: h.providerManager, context: h.context)
        case .edit:
            let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
            XCTAssertTrue(h.viewModel.editAndResend(user.id, newText: "被取消的编辑正文", isEdit: true,
                                                    model: h.model, profile: h.profile, preset: h.preset,
                                                    providerManager: h.providerManager, context: h.context))
        }
    }

    private func assertWarmCancellation(entry: PreparingEntry, exit: PreparingExit) async throws {
        let h = try await make(PromptScenario(name: "wiki-blocked-\(entry)-\(exit)"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        defer {
            if exit == .floor || exit == .conversation {
                AttachmentStore.deleteConversationAttachments(conversationId: conversation.id, profileId: h.profile.id)
            }
        }
        let parentId = try XCTUnwrap(h.a2.parentId)
        let originalUser = try XCTUnwrap(h.viewModel.currentPath.first { $0.id == parentId })
        let switchParentId: String
        if entry == .edit {
            switchParentId = try XCTUnwrap(originalUser.parentId)
        } else {
            switchParentId = parentId
        }
        var branchTargetId: String?
        if [.branch, .branchMap, .search].contains(exit), entry != .edit {
            let sibling = MessageNode(id: UUID().uuidString, role: "assistant", content: "另一分支", contentType: "text",
                                      createTime: Date(), parentId: parentId, childrenIds: [],
                                      conversationId: conversation.id, profileId: h.profile.id)
            branchTargetId = sibling.id
            h.context.insert(sibling)
            let parent = try XCTUnwrap(h.viewModel.currentPath.first { $0.id == parentId })
            parent.childrenIds.append(sibling.id)
            try h.context.save()
            h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { WikiStore(root: root) })
            h.viewModel.loadConversation(conversation, context: h.context)
            while h.viewModel.isLoading { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        let entered = expectation(description: "先确认本轮已经进入 warm")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        var requests: [[String: Any]] = []
        RequestBodyTap.handler = { requests.append($0) }
        defer { RequestBodyTap.handler = nil }
        try beginPreparation(entry, h)
        await fulfillment(of: [entered], timeout: 3)
        let preparations = h.viewModel.promptPreparationTasksForTesting
        XCTAssertEqual(preparations.count, 1)
        let placeholderId = try XCTUnwrap(h.viewModel.currentPath.last?.id)
        switch exit {
        case .stop:
            h.viewModel.cancelAssistantTurn(context: h.context)
        case .floor:
            NotificationCenter.default.post(name: .profileWillSwitch, object: nil)
        case .conversation:
            h.viewModel.startDraftConversation(profileId: h.profile.id, fresh: true)
        case .branch:
            h.viewModel.switchBranch(at: switchParentId, to: entry == .edit ? 0 : 1)
        case .branchMap:
            h.viewModel.navigateToNodeFast(nodeId: try XCTUnwrap(branchTargetId))
        case .search:
            h.viewModel.navigateToSearchResult(nodeId: try XCTUnwrap(branchTargetId), conversation: conversation, context: h.context)
        }
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        XCTAssertNil(h.viewModel.activeConversationId)
        let nodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        XCTAssertFalse(nodes.contains { $0.id == placeholderId }, "只移除本轮尚未发出的空占位")
        XCTAssertTrue(requests.isEmpty)
        if exit == .conversation || exit == .branch {
            h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { WikiStore(root: root) })
            XCTAssertTrue(h.viewModel.sendMessage("切换后的新发送", model: h.model, profile: h.profile, preset: h.preset,
                                                  providerManager: h.providerManager, context: h.context))
            let newPreparations = h.viewModel.promptPreparationTasksForTesting
            gate.open()
            for task in preparations { await task.value }
            for task in newPreparations { await task.value }
            await h.waitForTurn()
            XCTAssertEqual(requests.count, 1, "旧 warm 退出不能清掉新一轮")
            XCTAssertTrue(try h.canonical(XCTUnwrap(requests.first)).contains("切换后的新发送"))
        } else {
            gate.open()
            for task in preparations { await task.value }
            XCTAssertTrue(requests.isEmpty, "停止或切楼层后即使 source 解阻也不能发出请求")
        }
    }

    func testSendStopsAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .send, exit: .stop) }
    func testRegenerateStopsAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .regenerate, exit: .stop) }
    func testEditStopsAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .edit, exit: .stop) }
    func testSendFloorSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .send, exit: .floor) }
    func testRegenerateFloorSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .regenerate, exit: .floor) }
    func testEditFloorSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .edit, exit: .floor) }
    func testSendConversationSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .send, exit: .conversation) }
    func testRegenerateConversationSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .regenerate, exit: .conversation) }
    func testEditConversationSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .edit, exit: .conversation) }
    func testSendBranchSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .send, exit: .branch) }
    func testRegenerateBranchSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .regenerate, exit: .branch) }
    func testEditBranchSwitchAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .edit, exit: .branch) }
    func testSendBranchMapNavigationAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .send, exit: .branchMap) }
    func testSendSearchNavigationAfterEnteringWarm() async throws { try await assertWarmCancellation(entry: .send, exit: .search) }

    private func assertAskCancellation(entry: PreparingEntry) async throws {
        let h = try await make(PromptScenario(name: "wiki-ask-stop-\(entry)"))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.permGrantsRaw = ""
        h.overrideDefault(PermissionDomain.images.storageKey, PermissionLevel.askOnce.rawValue)
        let center = PermissionPromptCenter(isolatedForTesting: true)
        h.viewModel.injectionPermissionCenter = center
        defer {
            if let request = center.pendingRequest { center.respond(to: request.id, allowed: false) }
        }
        var requests = 0
        RequestBodyTap.handler = { _ in requests += 1 }
        defer { RequestBodyTap.handler = nil }
        try beginPreparation(entry, h)
        let deadline = Date().addingTimeInterval(3)
        while center.pendingRequest == nil && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(center.pendingRequest?.domain, .images)
        let tasks = h.viewModel.promptPreparationTasksForTesting
        XCTAssertEqual(tasks.count, 1)
        h.viewModel.cancelAssistantTurn(context: h.context)
        for task in tasks { await task.value }
        XCTAssertNil(center.pendingRequest)
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        XCTAssertNil(h.viewModel.activeConversationId)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(conversation.permGrantsRaw, "", "取消不是拒绝，不应写入旧授权")
    }

    func testSendStopCancelsAskBeforeWarm() async throws { try await assertAskCancellation(entry: .send) }
    func testRegenerateStopCancelsAskBeforeWarm() async throws { try await assertAskCancellation(entry: .regenerate) }
    func testEditStopCancelsAskBeforeWarm() async throws { try await assertAskCancellation(entry: .edit) }

    func testWarmTimeoutFailsSendWithoutBuildingRequest() async throws {
        let h = try await make(PromptScenario(name: "wiki-warm-timeout"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "warm 已阻塞")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        var requests = 0
        RequestBodyTap.handler = { _ in requests += 1 }
        defer { RequestBodyTap.handler = nil }
        try beginPreparation(.send, h)
        await fulfillment(of: [entered], timeout: 3)
        for task in h.viewModel.promptPreparationTasksForTesting { await task.value }
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        XCTAssertNil(h.viewModel.activeConversationId)
        XCTAssertTrue(h.viewModel.currentPath.last?.content.contains("发送失败") == true)
    }

    @MainActor
    private final class CCWire {
        let client: CCBridgeWebSocketClient
        private let suite = "InspectorCCWire.\(UUID().uuidString)"
        private let session = URLSession(configuration: .ephemeral)
        private(set) var frames: [[String: Any]] = []
        var onSend: (() -> Void)?

        init() {
            client = CCBridgeWebSocketClient(dedupDefaults: UserDefaults(suiteName: suite)!, transportOffMain: false)
            client.setTransmitHookForTesting { [weak self] _, text, completion in
                DispatchQueue.main.async {
                    if let frame = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                       let type = frame["type"] as? String, type == "send" || type == "command" {
                        self?.frames.append(frame)
                        self?.onSend?()
                    }
                    completion(nil)
                }
            }
            let url = URL(string: "ws://127.0.0.1:9/cc")!
            let task = session.webSocketTask(with: url)
            client.adoptTaskForTesting(task, url: url)
            client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        }

        func waitUntilConnected() async throws {
            let deadline = Date().addingTimeInterval(3)
            while !client.isConnected && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(client.isConnected)
        }

        func close() {
            client.disconnect()
            client.setTransmitHookForTesting(nil)
            session.invalidateAndCancel()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    func testCCSendPersistsNoInjectionReceiptAndMeterAgrees() async throws {
        let h = try await make(PromptScenario(name: "recall-cc-receipt", profileId: "xctest-岚舟-\(UUID().uuidString)",
                                              voiceHint: false, memoryFixtures: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-receipt")
        let wire = CCWire()
        defer { wire.close(); MemoryInjectionMeter.clear(profileId: h.profile.id) }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        XCTAssertTrue(h.viewModel.sendMessage("林栖在云桥城的地图计划怎样了？", model: cc, profile: h.profile,
                                              preset: h.preset, providerManager: h.providerManager, context: h.context))
        await waitUntil("CC send frame must be handed to its transport") { wire.frames.count == 1 }
        let user = try XCTUnwrap(h.viewModel.currentPath.last { $0.role == "user" })
        try h.context.save()
        let readback = ModelContext(h.context.container)
        let id = user.id
        let persisted = try XCTUnwrap(readback.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertNil(try XCTUnwrap(persisted.recallReceipt).injectionRecord)
        let meter = try XCTUnwrap(MemoryInjectionMeter.load(profileId: h.profile.id))
        XCTAssertEqual(meter.viaCCBridge, true)
        XCTAssertEqual(meter.tokens, 0)
        XCTAssertEqual(meter.hitCount, 0)
    }

    func testCCColdCacheDoubleSendSerializesAppendWarmAssemblyAndFrames() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-double", voiceHint: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-double")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "第一条 CC 已进入 warm")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        XCTAssertTrue(h.viewModel.sendMessage("CC 第一条", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        let firstId = try XCTUnwrap(h.viewModel.currentPath.last?.id)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(h.viewModel.sendMessage("CC 第二条", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertEqual(h.viewModel.currentPath.last?.id, firstId, "前一条 WS 前不 append 下一条")
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        XCTAssertNil(h.viewModel.activeConversationId)
        XCTAssertTrue(wire.frames.isEmpty)
        let sent = expectation(description: "两条 CC send 帧")
        sent.expectedFulfillmentCount = 2
        wire.onSend = { sent.fulfill() }
        gate.open()
        await fulfillment(of: [sent], timeout: 3)
        let second = try XCTUnwrap(h.viewModel.currentPath.last)
        XCTAssertNotEqual(second.id, firstId)
        XCTAssertEqual(second.parentId, firstId)
        XCTAssertEqual(wire.frames.map { $0["message_id"] as? String }, [firstId, second.id])
        XCTAssertEqual(wire.frames.map { $0["chat_id"] as? String }, [conversation.id, conversation.id])
        XCTAssertEqual(wire.frames.map { $0["content"] as? String }, ["CC 第一条", "CC 第二条"])
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
    }

    func testCCWarmQueuePrecedesAPIAskAndStopLeavesNoOrphan() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-api-ask-order", voiceHint: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-api-ask-order")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        conversation.permGrantsRaw = ""
        h.overrideDefault(PermissionDomain.images.storageKey, PermissionLevel.askOnce.rawValue)
        let center = PermissionPromptCenter(isolatedForTesting: true)
        h.viewModel.injectionPermissionCenter = center
        defer {
            if let request = center.pendingRequest { center.respond(to: request.id, allowed: false) }
        }
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "CC 第一条 warm 阻塞")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        var requests = 0
        RequestBodyTap.handler = { _ in requests += 1 }
        defer { RequestBodyTap.handler = nil }
        XCTAssertTrue(h.viewModel.sendMessage("CC 第一条先发", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        let firstId = try XCTUnwrap(h.viewModel.currentPath.last?.id)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(h.viewModel.sendMessage("CC 第二条再发", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertTrue(h.viewModel.sendMessage("API 最后询问", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertEqual(h.viewModel.currentPath.last?.id, firstId, "CC preparation 前不追加后续 CC 或 API 占位")
        XCTAssertNil(center.pendingRequest)
        XCTAssertTrue(wire.frames.isEmpty)
        XCTAssertEqual(requests, 0)

        let sent = expectation(description: "两条 CC 先按顺序发出")
        sent.expectedFulfillmentCount = 2
        wire.onSend = { sent.fulfill() }
        gate.open()
        await fulfillment(of: [sent], timeout: 3)
        await waitUntil("前两条 CC 后才出现 API 权限卡") { center.pendingRequest != nil }
        XCTAssertEqual(center.pendingRequest?.domain, .images)
        XCTAssertEqual(wire.frames.map { $0["content"] as? String }, ["CC 第一条先发", "CC 第二条再发"])
        let beforeStop = try h.context.fetch(FetchDescriptor<MessageNode>())
        let second = try XCTUnwrap(beforeStop.first { $0.content == "CC 第二条再发" })
        let apiUser = try XCTUnwrap(beforeStop.first { $0.content == "API 最后询问" })
        let placeholder = try XCTUnwrap(h.viewModel.currentPath.last)
        let placeholderId = placeholder.id
        XCTAssertEqual(second.parentId, firstId)
        XCTAssertEqual(apiUser.parentId, second.id)
        XCTAssertEqual(placeholder.parentId, apiUser.id)
        XCTAssertEqual(wire.frames.map { $0["message_id"] as? String }, [firstId, second.id])
        let tasks = h.viewModel.promptPreparationTasksForTesting
        h.viewModel.cancelAssistantTurn(context: h.context)
        for task in tasks { await task.value }
        XCTAssertNil(center.pendingRequest)
        XCTAssertEqual(requests, 0, "停止询问不构建 API 请求")
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, apiUser.id)
        XCTAssertEqual(conversation.currentNodeId, apiUser.id)
        let nodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        XCTAssertFalse(nodes.contains { $0.id == placeholderId })
        for node in nodes {
            if let parentId = node.parentId {
                let parent = try XCTUnwrap(nodes.first { $0.id == parentId })
                XCTAssertTrue(parent.childrenIds.contains(node.id), "父节点应保留有效孩子链接")
            }
            for childId in node.childrenIds {
                XCTAssertTrue(nodes.contains { $0.id == childId && $0.parentId == node.id }, "不能留下孤儿或悬空孩子")
            }
        }
    }

    func testStoppingPreparationKeepsPlaceholderWithExistingChild() async throws {
        let h = try await make(PromptScenario(name: "wiki-stop-parent-with-child", voiceHint: false))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-stop-parent-child")
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        conversation.permGrantsRaw = ""
        h.overrideDefault(PermissionDomain.images.storageKey, PermissionLevel.askOnce.rawValue)
        let center = PermissionPromptCenter(isolatedForTesting: true)
        h.viewModel.injectionPermissionCenter = center
        defer {
            if let request = center.pendingRequest { center.respond(to: request.id, allowed: false) }
        }
        XCTAssertTrue(h.viewModel.sendMessage("等待权限", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await waitUntil("API 停在权限卡") { center.pendingRequest != nil }
        let placeholder = try XCTUnwrap(h.viewModel.currentPath.last)
        let placeholderId = placeholder.id
        let child = MessageNode(id: UUID().uuidString, role: "user", content: "已经挂上的孩子", contentType: "text",
                                createTime: Date(), parentId: placeholderId, childrenIds: [],
                                conversationId: conversation.id, profileId: h.profile.id)
        h.context.insert(child)
        let leaf = MessageNode(id: UUID().uuidString, role: "assistant", content: "孩子之后的叶子", contentType: "text",
                               createTime: Date(), parentId: child.id, childrenIds: [],
                               conversationId: conversation.id, profileId: h.profile.id)
        h.context.insert(leaf)
        // 旧竞态可能只来得及写 parentId；取消也必须保住这条关系。
        try h.context.save()
        XCTAssertTrue(h.viewModel.sendMessage("取消后接到已有叶子", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertEqual(h.viewModel.pendingSends.count, 1)
        conversation.memoryEnabled = false
        let sent = expectation(description: "修复路径之后排水")
        wire.onSend = { sent.fulfill() }
        let tasks = h.viewModel.promptPreparationTasksForTesting
        h.viewModel.cancelAssistantTurn(context: h.context)
        for task in tasks { await task.value }
        await fulfillment(of: [sent], timeout: 3)
        let nodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        let kept = try XCTUnwrap(nodes.first { $0.id == placeholderId })
        XCTAssertTrue(kept.content.contains("发送失败"))
        XCTAssertEqual(nodes.first { $0.id == child.id }?.parentId, kept.id)
        let next = try XCTUnwrap(nodes.first { $0.content == "取消后接到已有叶子" })
        XCTAssertEqual(next.parentId, leaf.id)
        XCTAssertTrue(h.viewModel.currentPath.contains { $0.id == child.id })
        XCTAssertTrue(h.viewModel.currentPath.contains { $0.id == leaf.id })
        XCTAssertEqual(wire.frames.map { $0["message_id"] as? String }, [next.id])
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
    }

    func testSearchReloadDefersPendingSendUntilTreeApplies() async throws {
        let h = try await make(PromptScenario(name: "wiki-search-load-pending", voiceHint: false))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let originalTailId = h.a2.id
        let originalPathIds = h.viewModel.currentPath.map(\.id)
        let searchTargetId = try XCTUnwrap(h.viewModel.currentPath.first?.id)
        let originalNodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        let originalIds = Set(originalNodes.map(\.id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "重生成 warm 阻塞")
        let warmGate = WikiWarmGate(root: root, entered: entered)
        defer { warmGate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { warmGate.source() })
        let sent = expectation(description: "树应用后排队正文才发出")
        var requests: [[String: Any]] = []
        RequestBodyTap.handler = { requests.append($0); sent.fulfill() }
        defer { RequestBodyTap.handler = nil }
        h.viewModel.regenerate(assistantNodeId: originalTailId, model: h.model, profile: h.profile, preset: h.preset,
                               providerManager: h.providerManager, context: h.context)
        await fulfillment(of: [entered], timeout: 3)
        let oldTasks = h.viewModel.promptPreparationTasksForTesting
        XCTAssertTrue(h.viewModel.sendMessage("搜索加载后补发", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertEqual(h.viewModel.pendingSends.count, 1)
        let loadGate = DispatchSemaphore(value: 0)
        defer { loadGate.signal() }
        h.viewModel.testNextLoadBuildGate = loadGate
        h.viewModel.navigateToSearchResult(nodeId: searchTargetId, conversation: conversation, context: h.context)
        warmGate.open()
        for task in oldTasks { await task.value }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(h.viewModel.isLoading)
        XCTAssertEqual(h.viewModel.currentPath.map(\.id), originalPathIds)
        XCTAssertEqual(h.viewModel.pendingSends.count, 1)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<MessageNode>()).map(\.id)), originalIds,
                       "树未应用时不建 user 或 assistant 节点")

        loadGate.signal()
        await fulfillment(of: [sent], timeout: 5)
        await h.waitForTurn()
        XCTAssertFalse(h.viewModel.isLoading)
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
        XCTAssertEqual(requests.count, 1)
        let nodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        let user = try XCTUnwrap(nodes.first { $0.content == "搜索加载后补发" })
        XCTAssertEqual(user.parentId, originalTailId, "恢复原树后接到原尾节点而非隐形根")
        let originalTail = try XCTUnwrap(nodes.first { $0.id == originalTailId })
        XCTAssertTrue(originalTail.childrenIds.contains(user.id))
        XCTAssertTrue(h.viewModel.currentPath.contains { $0.id == user.id })
        XCTAssertTrue(try h.canonical(XCTUnwrap(requests.first)).contains("搜索加载后补发"))
        XCTAssertTrue(originalIds.isSubset(of: Set(nodes.map(\.id))))
    }

    private func assertCCFastNavigationDrainsPending(branchMap: Bool) async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-fast-navigation-\(branchMap)", voiceHint: false))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let parentId = try XCTUnwrap(h.a2.parentId)
        let parent = try XCTUnwrap(h.viewModel.currentPath.first { $0.id == parentId })
        let sibling = MessageNode(id: UUID().uuidString, role: "assistant", content: "快切分支", contentType: "text",
                                  createTime: Date(), parentId: parentId, childrenIds: [],
                                  conversationId: conversation.id, profileId: h.profile.id)
        let leaf = MessageNode(id: UUID().uuidString, role: "user", content: "快切分支末尾", contentType: "text",
                               createTime: Date(), parentId: sibling.id, childrenIds: [],
                               conversationId: conversation.id, profileId: h.profile.id)
        sibling.childrenIds = [leaf.id]
        parent.childrenIds.append(sibling.id)
        h.context.insert(sibling)
        h.context.insert(leaf)
        try h.context.save()
        h.viewModel.loadConversation(conversation, context: h.context)
        await waitUntil("准备好两条分支") { !h.viewModel.isLoading }
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-fast-navigation")
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "CC 进入预热")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        XCTAssertTrue(h.viewModel.sendMessage("切支前的 CC", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await fulfillment(of: [entered], timeout: 3)
        let tasks = h.viewModel.promptPreparationTasksForTesting
        XCTAssertTrue(h.viewModel.sendMessage("快切之后补发", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertEqual(h.viewModel.pendingSends.count, 1)
        let sent = expectation(description: "快速导航自己唤醒排水")
        var requests: [[String: Any]] = []
        RequestBodyTap.handler = { requests.append($0); sent.fulfill() }
        defer { RequestBodyTap.handler = nil }
        conversation.memoryEnabled = false
        if branchMap {
            h.viewModel.navigateToNodeFast(nodeId: sibling.id)
        } else {
            h.viewModel.switchBranch(at: parentId, to: parent.childrenIds.count - 1)
        }
        gate.open()
        for task in tasks { await task.value }
        await fulfillment(of: [sent], timeout: 3)
        await h.waitForTurn()
        let next = try XCTUnwrap(h.context.fetch(FetchDescriptor<MessageNode>()).first { $0.content == "快切之后补发" })
        XCTAssertEqual(next.parentId, leaf.id)
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
        XCTAssertTrue(wire.frames.isEmpty, "被取消的预热不能再发送 CC")
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(try h.canonical(XCTUnwrap(requests.first)).contains("快切分支末尾"))
    }

    func testCCWarmBranchSwitchDrainsPendingOnNewBranch() async throws {
        try await assertCCFastNavigationDrainsPending(branchMap: false)
    }

    func testCCWarmBranchMapNavigationDrainsPendingOnNewBranch() async throws {
        try await assertCCFastNavigationDrainsPending(branchMap: true)
    }

    private func assertMixedSendFIFO(regenerate: Bool) async throws {
        let h = try await make(PromptScenario(name: "wiki-mixed-fifo-\(regenerate)", voiceHint: false))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        let originalUser = try XCTUnwrap(h.viewModel.currentPath.first { $0.id == h.a2.parentId })
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-mixed-fifo")
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "CC 首条占用准备期")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        let sent = expectation(description: "三个发送动作按入队顺序完成")
        sent.expectedFulfillmentCount = 3
        var order: [String] = []
        wire.onSend = {
            order.append(wire.frames.last?["content"] as? String ?? "")
            sent.fulfill()
        }
        RequestBodyTap.handler = { _ in order.append("普通先入队"); sent.fulfill() }
        defer { RequestBodyTap.handler = nil }
        XCTAssertTrue(h.viewModel.sendMessage("CC 首条预热", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        let firstId = try XCTUnwrap(h.viewModel.currentPath.last?.id)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(h.viewModel.sendMessage("普通先入队", model: regenerate ? h.model : cc,
                                              profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        if regenerate {
            h.viewModel.regenerate(assistantNodeId: h.a2.id, model: cc, profile: h.profile, preset: h.preset,
                                   providerManager: h.providerManager, context: h.context)
        } else {
            XCTAssertTrue(h.viewModel.editAndResend(originalUser.id, newText: "编辑后入队", isEdit: true,
                                                    model: cc, profile: h.profile, preset: h.preset,
                                                    providerManager: h.providerManager, context: h.context))
        }
        gate.open()
        await fulfillment(of: [sent], timeout: 5)
        await h.waitForTurn()
        for task in h.viewModel.promptPreparationTasksForTesting { await task.value }
        XCTAssertEqual(order, ["CC 首条预热", "普通先入队", regenerate ? originalUser.content : "编辑后入队"])
        let nodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        let ordinary = try XCTUnwrap(nodes.first { $0.content == "普通先入队" })
        XCTAssertEqual(ordinary.parentId, firstId, "普通发送不能被后入队的切支动作挪到另一分支")
        if regenerate {
            XCTAssertEqual(conversation.currentNodeId, originalUser.id)
            XCTAssertEqual(wire.frames.last?["message_id"] as? String, originalUser.id)
        } else {
            let edited = try XCTUnwrap(nodes.first { $0.content == "编辑后入队" })
            XCTAssertEqual(edited.parentId, originalUser.parentId)
            XCTAssertEqual(conversation.currentNodeId, edited.id)
        }
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
    }

    func testCCWarmOrdinaryAPISendPrecedesRegenerate() async throws {
        try await assertMixedSendFIFO(regenerate: true)
    }

    func testCCWarmOrdinaryCCSendPrecedesEditResend() async throws {
        try await assertMixedSendFIFO(regenerate: false)
    }

    private func assertTreeReadFailureKeepsPending(mainFetch: Bool) async throws {
        let h = try await make(PromptScenario(name: "wiki-tree-fetch-failure-\(mainFetch)", voiceHint: false))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let originalPath = h.viewModel.currentPath.map(\.id)
        let originalIds = Set(try h.context.fetch(FetchDescriptor<MessageNode>()).map(\.id))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        h.viewModel.testNextLoadBuildGate = gate
        h.viewModel.testNextLoadBuildFailure = !mainFetch
        h.viewModel.testNextLoadApplyFailure = mainFetch
        var requests: [[String: Any]] = []
        RequestBodyTap.handler = { requests.append($0) }
        defer { RequestBodyTap.handler = nil }
        h.viewModel.loadConversation(conversation, context: h.context)
        XCTAssertTrue(h.viewModel.sendMessage("读取成功后才发送", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        let queuedId = try XCTUnwrap(h.viewModel.pendingSends.first?.id)
        gate.signal()
        await waitUntil("失败应退出加载并提示") { !h.viewModel.isLoading }
        h.viewModel.cancelAssistantTurn(context: h.context)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(h.viewModel.pendingSends.map(\.id), [queuedId])
        XCTAssertEqual(h.viewModel.currentPath.map(\.id), originalPath)
        XCTAssertEqual(Set(try h.context.fetch(FetchDescriptor<MessageNode>()).map(\.id)), originalIds)
        XCTAssertNotNil(h.viewModel.transientNotice)
        let sent = expectation(description: "重试真实树成功才排水")
        RequestBodyTap.handler = { requests.append($0); sent.fulfill() }
        h.viewModel.loadConversation(conversation, context: h.context)
        await fulfillment(of: [sent], timeout: 5)
        await h.waitForTurn()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
        let next = try XCTUnwrap(h.context.fetch(FetchDescriptor<MessageNode>()).first { $0.content == "读取成功后才发送" })
        XCTAssertEqual(next.parentId, originalPath.last)
    }

    func testBackgroundTreeReadFailureKeepsOldTreeAndPending() async throws {
        try await assertTreeReadFailureKeepsPending(mainFetch: false)
    }

    func testMainTreeReadFailureKeepsOldTreeAndPending() async throws {
        try await assertTreeReadFailureKeepsPending(mainFetch: true)
    }

    func testAPITurnDrainsCCThenCCThenAPIAndSurvivesReload() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-api-queue", voiceHint: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-api-queue")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "API 已进入 warm")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        var requests: [[String: Any]] = []
        var order: [String] = []
        let sent = expectation(description: "API、CC、CC、API 全部依次发出")
        sent.expectedFulfillmentCount = 4
        RequestBodyTap.handler = {
            requests.append($0)
            order.append(requests.count == 1 ? "API 首轮" : "API 尾轮")
            sent.fulfill()
        }
        defer { RequestBodyTap.handler = nil }
        wire.onSend = {
            order.append(wire.frames.last?["content"] as? String ?? "")
            sent.fulfill()
        }

        XCTAssertTrue(h.viewModel.sendMessage("API 首轮", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        let apiAssistantId = try XCTUnwrap(h.viewModel.currentPath.last?.id)
        await fulfillment(of: [entered], timeout: 3)
        for text in ["CC 队列一", "CC 队列二"] {
            XCTAssertTrue(h.viewModel.sendMessage(text, model: cc, profile: h.profile, preset: h.preset,
                                                  providerManager: h.providerManager, context: h.context))
        }
        XCTAssertTrue(h.viewModel.sendMessage("API 尾轮", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertEqual(h.viewModel.pendingSends.count, 3)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, apiAssistantId)
        XCTAssertTrue(wire.frames.isEmpty)
        XCTAssertTrue(requests.isEmpty)

        gate.open()
        await fulfillment(of: [sent], timeout: 5)
        await h.waitForTurn()
        for task in h.viewModel.promptPreparationTasksForTesting { await task.value }
        XCTAssertEqual(order, ["API 首轮", "CC 队列一", "CC 队列二", "API 尾轮"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
        let nodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        let firstCC = try XCTUnwrap(nodes.first { $0.content == "CC 队列一" })
        let secondCC = try XCTUnwrap(nodes.first { $0.content == "CC 队列二" })
        let apiUser = try XCTUnwrap(nodes.first { $0.content == "API 尾轮" })
        XCTAssertEqual(firstCC.parentId, apiAssistantId)
        XCTAssertEqual(secondCC.parentId, firstCC.id)
        XCTAssertEqual(apiUser.parentId, secondCC.id)
        XCTAssertEqual(wire.frames.map { $0["message_id"] as? String }, [firstCC.id, secondCC.id])
        let tailBody = try h.canonical(XCTUnwrap(requests.last))
        XCTAssertTrue(tailBody.contains("CC 队列一") && tailBody.contains("CC 队列二") && tailBody.contains("API 尾轮"))
        try h.context.save()   // 后台加载用独立 context；内存夹具显式提交最后一轮。
        h.viewModel.loadConversation(conversation, context: h.context)
        await waitUntil("重载应完成") { !h.viewModel.isLoading }
        XCTAssertTrue(h.viewModel.currentPath.contains { $0.id == firstCC.id })
        XCTAssertTrue(h.viewModel.currentPath.contains { $0.id == secondCC.id })
        XCTAssertTrue(h.viewModel.currentPath.contains { $0.id == apiUser.id })
        XCTAssertEqual(wire.frames.map { $0["content"] as? String }, ["CC 队列一", "CC 队列二"])
    }

    func testConversationSwitchRestoresQueuedCCAndMarksAppendedCCUnsent() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-abort-draft", voiceHint: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-abort-draft")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        defer { AttachmentStore.deleteConversationAttachments(conversationId: conversation.id, profileId: h.profile.id) }
        conversation.currentStyleId = ""
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "第一条 CC 已进入 warm")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        XCTAssertTrue(h.viewModel.sendMessage("CC 第一条", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        let firstId = try XCTUnwrap(h.viewModel.currentPath.last?.id)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(h.viewModel.sendMessage("CC 第二条回草稿", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        let tasks = h.viewModel.promptPreparationTasksForTesting

        h.viewModel.startDraftConversation(profileId: h.profile.id, fresh: true)
        gate.open()
        for task in tasks { await task.value }
        XCTAssertEqual(conversation.draftText, "CC 第二条回草稿")
        let nodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        XCTAssertFalse(nodes.contains { $0.content == "CC 第二条回草稿" && $0.role == "user" })
        XCTAssertFalse(nodes.contains { $0.parentId == firstId && $0.role == "system" }, "未发送状态不写进消息树")
        let status = try XCTUnwrap(wire.client.sendTracker.store.entry(firstId))
        XCTAssertEqual(status.state, .failed)
        XCTAssertFalse(status.retryable)
        XCTAssertFalse(status.canRetry)
        XCTAssertTrue(status.visibleReason?.contains("未发送") == true)
        h.viewModel.loadConversation(conversation, context: h.context)
        await waitUntil("回到原对话应完成加载") { !h.viewModel.isLoading }
        XCTAssertTrue(h.viewModel.currentPath.contains { $0.id == firstId })
        XCTAssertTrue(wire.client.sendTracker.store.entry(firstId) === status, "同一 client 重载后保留气泡失败状态")
        XCTAssertTrue(wire.frames.isEmpty)
    }

    func testCCWarmFailureDrainsQueuedSlashAndAPI() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-failure-drain", voiceHint: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-failure-drain")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "CC warm 阻塞到超时")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        XCTAssertTrue(h.viewModel.sendMessage("超时的 CC", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        let ccId = try XCTUnwrap(h.viewModel.currentPath.last?.id)
        await fulfillment(of: [entered], timeout: 3)
        conversation.memoryEnabled = false
        let sent = expectation(description: "失败后继续发斜杠和 API")
        sent.expectedFulfillmentCount = 2
        var order: [String] = []
        wire.onSend = { order.append("slash"); sent.fulfill() }
        RequestBodyTap.handler = { _ in order.append("API"); sent.fulfill() }
        defer { RequestBodyTap.handler = nil }
        XCTAssertTrue(h.viewModel.sendMessage("/clear", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertTrue(h.viewModel.sendMessage("失败后继续 API", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await fulfillment(of: [sent], timeout: 10)
        await h.waitForTurn()
        XCTAssertEqual(order, ["slash", "API"])
        XCTAssertEqual(wire.frames.map { $0["type"] as? String }, ["command"])
        XCTAssertEqual(wire.client.sendTracker.store.entry(ccId)?.state, .failed)
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
        XCTAssertTrue(h.viewModel.currentPath.contains { $0.content == "失败后继续 API" })
    }

    func testCCSlashCommandWaitsForEarlierCCMessage() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-slash-order", voiceHint: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-slash-order")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "普通 CC 已进入 warm")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        XCTAssertTrue(h.viewModel.sendMessage("先普通消息", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(h.viewModel.sendMessage("/clear", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertTrue(wire.frames.isEmpty)
        let sent = expectation(description: "普通消息和命令按序发出")
        sent.expectedFulfillmentCount = 2
        wire.onSend = { sent.fulfill() }
        gate.open()
        await fulfillment(of: [sent], timeout: 3)
        XCTAssertEqual(wire.frames.map { $0["type"] as? String }, ["send", "command"])
        XCTAssertEqual(wire.frames.map { $0["content"] as? String }, ["先普通消息", "/clear"])
    }

    func testCCSendDoesNotResolveAskOncePermissionCard() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-no-ask", voiceHint: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-no-ask")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        conversation.permGrantsRaw = ""
        h.overrideDefault(PermissionDomain.images.storageKey, PermissionLevel.askOnce.rawValue)
        let center = PermissionPromptCenter(isolatedForTesting: true)
        h.viewModel.injectionPermissionCenter = center
        defer {
            if let request = center.pendingRequest { center.respond(to: request.id, allowed: false) }
        }
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { WikiStore(root: root) })
        let sent = expectation(description: "CC 不弹权限卡直接发送")
        wire.onSend = { sent.fulfill() }
        XCTAssertTrue(h.viewModel.sendMessage("CC 不问权限", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await fulfillment(of: [sent], timeout: 3)
        XCTAssertNil(center.pendingRequest)
        XCTAssertEqual(wire.frames.first?["content"] as? String, "CC 不问权限")
    }

    func testConversationMemoryOffSkipsWikiWarmAndSendsImmediately() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-memory-off", voiceHint: false))
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-memory-off")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.currentStyleId = ""
        conversation.memoryEnabled = false
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let warmAttempted = expectation(description: "对话记忆关闭时不应 warm")
        warmAttempted.isInverted = true
        let gate = WikiWarmGate(root: root, entered: warmAttempted)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        let sent = expectation(description: "跳过 warm 立即发出")
        wire.onSend = { sent.fulfill() }
        XCTAssertTrue(h.viewModel.sendMessage("记忆关闭也立即发", model: cc, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await fulfillment(of: [sent], timeout: 1)
        await fulfillment(of: [warmAttempted], timeout: 0.2)
        XCTAssertEqual(wire.frames.first?["content"] as? String, "记忆关闭也立即发")
    }

    func testFloorSwitchRestoresAttachmentsFromEveryPendingSend() async throws {
        let h = try await make(PromptScenario(name: "wiki-pending-attachments"))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        defer { AttachmentStore.deleteConversationAttachments(conversationId: conversation.id, profileId: h.profile.id) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "首轮 API 已进入 warm")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        XCTAssertTrue(h.viewModel.sendMessage("阻塞首轮", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        await fulfillment(of: [entered], timeout: 3)
        let first = PendingChatAttachment.text(name: "一.txt", typeDescription: "文本", extractedText: "一",
                                               byteCount: 1, fileData: Data("1".utf8))
        let second = PendingChatAttachment.text(name: "二.txt", typeDescription: "文本", extractedText: "二",
                                                byteCount: 1, fileData: Data("2".utf8))
        XCTAssertTrue(h.viewModel.sendMessage("排队一", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context, attachments: [first]))
        XCTAssertTrue(h.viewModel.sendMessage("排队二", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context, attachments: [second]))
        XCTAssertEqual(h.viewModel.pendingSends.count, 2)
        let tasks = h.viewModel.promptPreparationTasksForTesting
        NotificationCenter.default.post(name: .profileWillSwitch, object: nil)
        gate.open()
        for task in tasks { await task.value }
        XCTAssertTrue(conversation.draftText.contains("排队一") && conversation.draftText.contains("排队二"))
        let data = try XCTUnwrap(conversation.draftAttachmentsData)
        let restored = try JSONDecoder().decode([PendingChatAttachment].self, from: data)
        XCTAssertEqual(restored.map(\.name), ["一.txt", "二.txt"])
    }

    func testRegenerateStopRestoresOriginalAssistantSelection() async throws {
        let h = try await make(PromptScenario(name: "wiki-regenerate-restore"))
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        let originalPath = h.viewModel.currentPath
        XCTAssertEqual(originalPath.map(\.role), ["user", "assistant", "user", "assistant"])
        let originalIds = originalPath.map(\.id)
        let originalContents = originalPath.map(\.content)
        let firstAssistant = try XCTUnwrap(originalPath.first { $0.role == "assistant" })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "重新生成已进入 warm")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        h.viewModel.regenerate(assistantNodeId: firstAssistant.id, model: h.model, profile: h.profile, preset: h.preset,
                               providerManager: h.providerManager, context: h.context)
        await fulfillment(of: [entered], timeout: 3)
        let placeholderId = try XCTUnwrap(h.viewModel.currentPath.last?.id)
        XCTAssertNotEqual(placeholderId, firstAssistant.id)
        let tasks = h.viewModel.promptPreparationTasksForTesting
        h.viewModel.cancelAssistantTurn(context: h.context)
        gate.open()
        for task in tasks { await task.value }
        XCTAssertEqual(h.viewModel.displayLeafIdForTesting, h.a2.id)
        XCTAssertEqual(conversation.currentNodeId, h.a2.id)
        XCTAssertEqual(h.viewModel.currentPath.last?.id, h.a2.id)
        XCTAssertEqual(h.viewModel.currentPath.last?.content, "回复二")
        XCTAssertEqual(h.viewModel.currentPath.map(\.id), originalIds, "停止历史轮次重生成后恢复完整 u1/a1/u2/a2")
        XCTAssertEqual(h.viewModel.currentPath.map(\.content), originalContents)
        let nodes = try h.context.fetch(FetchDescriptor<MessageNode>())
        XCTAssertTrue(nodes.contains { $0.id == h.a2.id && $0.content == "回复二" })
        XCTAssertFalse(nodes.contains { $0.id == placeholderId })
        for original in originalPath {
            XCTAssertTrue(nodes.contains { $0.id == original.id && $0.content == original.content })
        }
    }

    func testOtherConversationStreamingFinishDoesNotCancelCCWarm() async throws {
        let h = try await make(PromptScenario(name: "wiki-cc-other-finish", voiceHint: false))
        let oldId = try XCTUnwrap(h.viewModel.selectedConversation?.id)
        defer { AttachmentStore.deleteConversationAttachments(conversationId: oldId, profileId: h.profile.id) }
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-other")
        let wire = CCWire()
        defer { wire.close() }
        try await wire.waitUntilConnected()
        h.viewModel.ccBridgeClient = wire.client
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "CC 冷缓存 source 阻塞")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        let blockedCache = WikiInjectionCache(source: { gate.source() })
        blockedCache.prefetch(profileId: h.profile.id)
        await fulfillment(of: [entered], timeout: 3)
        let apiFinished = expectation(description: "另一对话真实 streaming 出错收口")
        let observer = NotificationCenter.default.addObserver(forName: .assistantTurnDidFinish, object: nil, queue: .main) { note in
            if note.userInfo?["conversationId"] as? String == oldId { apiFinished.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var ccNodeId: String?
        var ccConversationId: String?
        RequestBodyTap.handler = { _ in
            RequestBodyTap.handler = nil
            h.viewModel.wikiInjectionCache = blockedCache
            h.viewModel.startDraftConversation(profileId: h.profile.id, fresh: true)
            ccConversationId = h.viewModel.selectedConversation?.id
            XCTAssertTrue(h.viewModel.sendMessage("CC 不受另一流收口影响", model: cc, profile: h.profile, preset: h.preset,
                                                  providerManager: h.providerManager, context: h.context))
            ccNodeId = h.viewModel.currentPath.last?.id
        }
        defer { RequestBodyTap.handler = nil }
        h.viewModel.regenerate(assistantNodeId: h.a2.id, model: h.model, profile: h.profile, preset: h.preset,
                               providerManager: h.providerManager, context: h.context)
        await fulfillment(of: [apiFinished], timeout: 5)
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
        XCTAssertNil(h.viewModel.activeConversationId)
        XCTAssertTrue(wire.frames.isEmpty)
        let sent = expectation(description: "CC 仍按自己的请求发送")
        wire.onSend = { sent.fulfill() }
        gate.open()
        await fulfillment(of: [sent], timeout: 3)
        XCTAssertEqual(wire.frames.count, 1)
        XCTAssertEqual(wire.frames.first?["message_id"] as? String, ccNodeId)
        XCTAssertEqual(wire.frames.first?["chat_id"] as? String, ccConversationId)
        XCTAssertEqual(wire.frames.first?["content"] as? String, "CC 不受另一流收口影响")
    }

    func testStoppingPreparationDrainsPendingWithoutOldCleanupTouchingNewTurn() async throws {
        let h = try await make(PromptScenario(name: "wiki-stop-drain"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "第一条准备停在 warm")
        let gate = WikiWarmGate(root: root, entered: entered)
        defer { gate.open() }
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { gate.source() })
        var requests: [[String: Any]] = []
        RequestBodyTap.handler = { requests.append($0) }
        defer { RequestBodyTap.handler = nil }
        try beginPreparation(.send, h)
        await fulfillment(of: [entered], timeout: 3)
        let oldTasks = h.viewModel.promptPreparationTasksForTesting
        XCTAssertTrue(h.viewModel.sendMessage("排队的新一轮", model: h.model, profile: h.profile, preset: h.preset,
                                              providerManager: h.providerManager, context: h.context))
        XCTAssertEqual(h.viewModel.pendingSends.count, 1)
        h.viewModel.wikiInjectionCache = WikiInjectionCache(source: { WikiStore(root: root) })
        h.viewModel.cancelAssistantTurn(context: h.context)
        gate.open()
        for task in oldTasks { await task.value }
        let sent = expectation(description: "取消准备后自动补发队列")
        if requests.isEmpty {
            RequestBodyTap.handler = { requests.append($0); sent.fulfill() }
            await fulfillment(of: [sent], timeout: 3)
        }
        await h.waitForTurn()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(try h.canonical(XCTUnwrap(requests.first)).contains("排队的新一轮"))
        XCTAssertTrue(h.viewModel.pendingSends.isEmpty)
        XCTAssertFalse(h.viewModel.assistantTurnInFlight)
    }

    // MARK: - thinking 回传（plan-thinking §5 / §3.4）

    func testG8PreviewEqualsSend() async throws {
        try await assertPreviewEqualsSend(PromptScenario(name: "G8-opus-default-thinking", providerType: .anthropic,
                                                         modelId: "claude-opus-5-5", thinkingDisplay: .inline))
    }

    /// 思考过程「隐藏」：预览和实发都不发 display（同一个 builder）
    func testThinkingHiddenPreviewEqualsSendWithoutDisplay() async throws {
        let h = try await make(PromptScenario(name: "G8-hidden", providerType: .anthropic, modelId: "claude-opus-5-5", thinkingDisplay: .hidden))
        let previewBody = try XCTUnwrap(try preview(h).requestBody(providerManager: h.providerManager))
        let sent = try await h.regenerateCapturingBody()
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent))
        let thinking = try XCTUnwrap(sent["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertNil(thinking["display"])
    }

    /// 历史节点带着原生思考段（普通回复只挂思考段、工具节点夹着思考段）：历史一个字节不变（Q1-A）= 和 G8 金样相同
    func testHistoryThinkingSegmentsNeverSent() async throws {
        let h = try await make(PromptScenario(name: "G8-history", providerType: .anthropic, modelId: "claude-opus-5-5", thinkingDisplay: .inline))
        let a1 = try XCTUnwrap(h.viewModel.currentPath.first { $0.role == "assistant" })
        a1.setSegments([.text(a1.content), .thinking(text: "历史里的思考", signature: "sig-history"),
                        .thinking(text: "", signature: nil, redactedData: "ENC")])
        try h.context.save()
        let previewBody = try XCTUnwrap(try preview(h).requestBody(providerManager: h.providerManager))
        let sent = try await h.regenerateCapturingBody()
        XCTAssertEqual(try h.canonical(previewBody), try h.canonical(sent))
        let text = try h.canonical(sent, droppingTools: true)
        XCTAssertFalse(text.contains("sig-history") || text.contains("历史里的思考") || text.contains("ENC"))
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/prompt-golden/G8-opus-default-thinking.json")
        XCTAssertEqual(text, try String(contentsOf: golden, encoding: .utf8), "历史带思考段时实发和金样逐字节相同")
    }
}
