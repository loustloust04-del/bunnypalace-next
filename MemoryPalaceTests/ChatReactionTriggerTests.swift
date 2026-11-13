import XCTest
import SwiftData
@testable import 记忆花园

/// 10-29 贴表情立刻生效 + AI 用 ```react 给她贴表情（plan-bubble-feedback-1029 §5）
@MainActor
final class ChatReactionTriggerTests: XCTestCase {

    // MARK: - 立刻发（10-30 去防抖）

    func testEachTapDeliversImmediatelyAndCancelStopsIt() async throws {
        let trigger = ChatReactionTrigger()
        var delivered: [String] = []
        trigger.deliver = { delivered.append($0); return .sent }
        trigger.schedule(conversationId: "c")
        try await waitUntil(within: 0.5) { delivered == ["c"] }
        XCTAssertFalse(trigger.isPending("c"))
        trigger.schedule(conversationId: "c")
        try await waitUntil(within: 0.5) { delivered == ["c", "c"] }

        trigger.schedule(conversationId: "c")
        trigger.cancel(conversationId: "c")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(delivered, ["c", "c"])
    }

    func testBusyRetriesUntilSent() async throws {
        let trigger = ChatReactionTrigger()
        trigger.retryDelay = .milliseconds(50)
        var outcomes: [ChatReactionTrigger.Outcome] = [.busy, .busy, .sent]
        var calls = 0
        trigger.deliver = { _ in calls += 1; return outcomes.removeFirst() }
        trigger.schedule(conversationId: "c")
        try await waitUntil(within: 0.5) { calls == 1 }
        try await waitUntil { calls == 3 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls, 3, "发出去以后不再重试")
    }

    func testTypingAndNothingPendingDoNotRetry() async throws {
        let trigger = ChatReactionTrigger()
        trigger.retryDelay = .milliseconds(30)
        var calls = 0
        trigger.deliver = { _ in calls += 1; return calls == 1 ? .typing : .nothingPending }
        trigger.schedule(conversationId: "c")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls, 1, "她在打字：不单独发、也不重试，表情跟她那条走")
    }

    // MARK: - 正在生成：回完就发（10-31 去 30 秒上限）

    func testBusyBeyondOldCapStillSendsWhenTurnEnds() async throws {
        let trigger = ChatReactionTrigger()
        trigger.retryDelay = .milliseconds(5)
        var generating = true
        var calls = 0
        var sent: [String] = []
        trigger.deliver = { cid in
            calls += 1
            if generating { return .busy }
            sent.append(cid)
            return .sent
        }
        trigger.schedule(conversationId: "c")
        try await waitUntil { calls > 20 }   // 原来 15 次（30 秒）就放弃
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(trigger.isPending("c"), "还在等")
        generating = false
        trigger.turnDidEnd()
        try await waitUntil(within: 0.5) { sent == ["c"] }
        let settled = calls
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, settled, "发出去以后不再轮询")
        XCTAssertFalse(trigger.isPending("c"))
    }

    func testTurnDidEndDeliversWithoutWaitingForPoll() async throws {
        let trigger = ChatReactionTrigger()
        trigger.retryDelay = .seconds(60)
        var generating = true
        var sent: [String] = []
        trigger.deliver = { cid in
            if generating { return .busy }
            sent.append(cid)
            return .sent
        }
        trigger.schedule(conversationId: "c")
        try await waitUntil(within: 0.5) { trigger.isPending("c") }
        trigger.turnDidEnd()   // 还在生成时收口通知（别的对话那轮结束）：照样 busy，继续等
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(sent.isEmpty)
        generating = false
        trigger.turnDidEnd()
        try await waitUntil(within: 0.5) { sent == ["c"] }
    }

    func testSwitchingConversationWhileWaitingNeverSendsToWrongConversation() async throws {
        let trigger = ChatReactionTrigger()
        trigger.retryDelay = .milliseconds(10)
        var selected = "a"
        var generating = true
        var asked: [String] = []
        var sent: [String] = []
        trigger.deliver = { cid in   // 同 CardFlowView.registerReactionTrigger：不是当前对话 = unsupported
            asked.append(cid)
            guard selected == cid else { return .unsupported }
            if generating { return .busy }
            sent.append(cid)
            return .sent
        }
        trigger.schedule(conversationId: "a")
        try await waitUntil { asked.count >= 3 }
        selected = "b"
        generating = false
        trigger.turnDidEnd()
        try await waitUntil(within: 0.5) { !trigger.isPending("a") }
        XCTAssertTrue(sent.isEmpty, "换了对话：不发，留在 a 的箱里")
        XCTAssertFalse(asked.contains("b"))
        let count = asked.count
        selected = "a"
        trigger.turnDidEnd()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(asked.count, count, "等待已结束，切回来也不自己补发（随她下一条走）")
        XCTAssertTrue(sent.isEmpty)
    }

    /// 防抖为零：界面上贴一下（store.toggle 走真触发器）就立刻起一轮；撤掉不触发
    func testTapReactionStartsTurnImmediately() async throws {
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Self.sse("收到")) }
        try server.start()
        defer { server.stop() }
        try await withHarness(bubble: true, server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let trigger = ChatReactionTrigger()
            trigger.deliver = { _ in
                vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                        providerManager: h.providerManager, context: h.context)
            }
            let a2 = try XCTUnwrap(vm.currentPath.last)
            let target = ChatReactionTarget(node: a2)
            store.toggle("❤️", on: target, outbox: outbox, trigger: trigger)
            XCTAssertFalse(outbox.events(for: a2.conversationId).isEmpty)
            try await waitUntil(within: 0.5) { outbox.events(for: a2.conversationId).isEmpty }   // 点了就被这一轮取走
            try await waitUntil { !vm.assistantTurnInFlight }
            XCTAssertEqual(vm.currentPath.last?.content, "收到")
            XCTAssertEqual(server.requestBodies.count, 1)

            store.toggle("❤️", on: target, outbox: outbox, trigger: trigger)   // 撤掉
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(server.requestBodies.count, 1, "撤销不触发")
            XCTAssertEqual(outbox.events(for: a2.conversationId).map(\.text), ["收回了对你那条「回复二」的 ❤️"])
        }
    }

    // MARK: - 解析

    func testParseStripAndTarget() throws {
        let text = "好呀\n\n```react\n👍\n```\n\n晚安"
        XCTAssertEqual(ChatReactionIntent.parse(text), [.init(emoji: "👍", hint: "")])
        XCTAssertEqual(ChatReactionIntent.strip(text), "好呀\n\n晚安")
        XCTAssertEqual(ChatReactionIntent.parse("```react\n❤️ 第一条\n```"), [.init(emoji: "❤️", hint: "第一条")])
        XCTAssertEqual(ChatReactionIntent.parse("```react\n不是表情\n```"), [])
        XCTAssertEqual(ChatReactionIntent.strip("```react\n👩🏽‍💻\n```"), "")
        XCTAssertEqual(ChatReactionIntent.parse("```react\n👩🏽‍💻\n```").first?.emoji, "👩🏽‍💻")

        func node(_ id: String, _ role: String, _ content: String) -> MessageNode {
            MessageNode(id: id, role: role, content: content, contentType: "text", createTime: Date(),
                        parentId: nil, childrenIds: [], conversationId: "c", profileId: "p")
        }
        // 回复自己的祖先链，新 → 旧
        let ancestors = [node("u2", "user", "想出去走走"), node("a1", "assistant", "辛苦"), node("u1", "user", "今天把事情都做完了")]
        XCTAssertEqual(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: ""), among: ancestors)?.id, "u2")
        XCTAssertEqual(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: "今天 把事情"), among: ancestors)?.id, "u1")
        XCTAssertNil(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: "对不上"), among: ancestors), "对不上就不贴")
    }

    // MARK: - 只贴不打字也能发（mock provider，真管线）

    func testReactionOnlyTriggersOneBubbleTurnAndStaysInHistory() async throws {
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Self.sse("收到你的小心心")) }
        try server.start()
        defer { server.stop() }
        try await withHarness(bubble: true, server: server) { h, model, outbox, store in
            let vm = h.viewModel
            let a2 = try XCTUnwrap(vm.currentPath.last)
            store.toggle("❤️", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
            XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                   providerManager: h.providerManager, context: h.context), .sent)
            XCTAssertTrue(outbox.events(for: a2.conversationId).isEmpty, "箱子被这一轮取走")
            try await waitUntil { !vm.assistantTurnInFlight }
            let reply = try XCTUnwrap(vm.currentPath.last)
            XCTAssertEqual(reply.role, "assistant")
            XCTAssertEqual(reply.content, "收到你的小心心")
            XCTAssertEqual(reply.parentId, a2.id, "没有新建用户泡，直接接在 AI 那条后面")
            XCTAssertEqual(reply.cardEvents.map(\.text), ["对你那条「回复二」回了 ❤️"])

            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(server.requestBodies.last)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let last = try XCTUnwrap(messages.last)
            XCTAssertEqual(last["role"] as? String, "user")
            XCTAssertTrue(Self.text(of: last).contains("[附带事件]\n- 对你那条「回复二」回了 ❤️"), "\(Self.text(of: last))")
            XCTAssertTrue((messages.first.map(Self.text(of:)) ?? "").contains("<气泡对话>"), "气泡对话 system 带表情说明")

            // 落地后历史：这轮回复前面补回同一条「[附带事件]」
            let history = vm.buildAPIMessages()
            let idx = try XCTUnwrap(history.firstIndex { $0.id == reply.id })
            XCTAssertEqual(history[idx - 1].role, "user")
            XCTAssertEqual(history[idx - 1].content, ChatCardEventPrompt.turnContent(reply.cardEvents))
        }
    }

    func testArticleConversationAndRetractionDoNotTrigger() async throws {
        try await withHarness(bubble: false, server: nil) { h, model, outbox, store in
            let a2 = try XCTUnwrap(h.viewModel.currentPath.last)
            store.toggle("❤️", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
            XCTAssertEqual(h.viewModel.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                            providerManager: h.providerManager, context: h.context), .unsupported)
            XCTAssertEqual(outbox.events(for: a2.conversationId).count, 1, "文章对话照旧留在箱里随下一条")
        }
        try await withHarness(bubble: true, server: nil) { h, model, outbox, store in
            let a2 = try XCTUnwrap(h.viewModel.currentPath.last)
            outbox.add("收回了对你那条「回复二」的 ❤️", conversationId: a2.conversationId, key: "reaction:\(a2.id):❤️")
            XCTAssertEqual(h.viewModel.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                            providerManager: h.providerManager, context: h.context), .nothingPending)
            _ = store
        }
    }

    // MARK: - AI 贴表情

    func testAssistantReactBlockIsStrippedAndPlacedOnUserMessage() async throws {
        let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Self.sse("好呀，晚安\n\n```react\n👍\n```")) }
        try server.start()
        defer { server.stop() }
        try await withHarness(bubble: true, server: server) { h, model, outbox, store in
            let vm = h.viewModel
            XCTAssertTrue(vm.sendMessage("那我去睡啦", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { !vm.assistantTurnInFlight }
            let reply = try XCTUnwrap(vm.currentPath.last)
            let user = try XCTUnwrap(vm.currentPath.dropLast().last)
            XCTAssertEqual(reply.content, "好呀，晚安", "块不显示")
            XCTAssertEqual(store.aiReactions(for: ChatReactionTarget(node: user, blockIndex: 0, blockText: user.content)), ["👍"])
            XCTAssertTrue(store.reactions(for: ChatReactionTarget(node: user, blockIndex: 0, blockText: user.content)).isEmpty,
                          "AI 贴的和她自己点的分开存")
            XCTAssertEqual(outbox.events(for: user.conversationId).map(\.text), ["你给 ta 那条「那我去睡啦」回了 👍"],
                           "记一笔，下轮模型知道自己贴过")
            XCTAssertFalse(outbox.events(for: user.conversationId).contains(where: ChatReactionStore.isAddEvent),
                           "AI 自己贴的不触发新一轮")
        }
    }

    /// 10-30：AI 贴表情的那笔捎带卡不显示（输入框上方 / 发出去的用户泡 📎 都看不见），但照旧跟下一条带给模型
    func testAssistantReactionNoteHiddenButStillSentToModel() async throws {
        let replies = [Self.sse("好呀\n\n```react\n👍\n```"), Self.sse("嗯")]
        let server = try ScriptedHTTPServer { i, _ in (200, "text/event-stream", replies[min(i, 1)]) }
        try server.start()
        defer { server.stop() }
        try await withHarness(bubble: true, server: server) { h, model, outbox, _ in
            let vm = h.viewModel
            XCTAssertTrue(vm.sendMessage("那我去睡啦", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { !vm.assistantTurnInFlight }
            let cid = try XCTUnwrap(vm.selectedConversation?.id)
            XCTAssertEqual(outbox.events(for: cid).map(\.text), ["你给 ta 那条「那我去睡啦」回了 👍"])
            XCTAssertTrue(outbox.visibleEvents(for: cid).isEmpty, "捎带卡区域不显示 AI 贴表情的记录")

            XCTAssertTrue(vm.sendMessage("晚安", model: model, profile: h.profile, preset: h.preset,
                                         providerManager: h.providerManager, context: h.context))
            try await waitUntil { !vm.assistantTurnInFlight && server.requestBodies.count == 2 }
            XCTAssertTrue(outbox.events(for: cid).isEmpty, "整箱被这条取走")
            let user = try XCTUnwrap(vm.currentPath.dropLast().last)
            XCTAssertEqual(user.content, "晚安")
            XCTAssertEqual(user.cardEvents.map(\.text), ["你给 ta 那条「那我去睡啦」回了 👍"], "drain 出来挂在这条上")
            XCTAssertTrue(user.visibleCardEvents.isEmpty, "用户泡上的 📎 也不显示它")

            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(server.requestBodies.last)) as? [String: Any])
            let last = try XCTUnwrap((body["messages"] as? [[String: Any]])?.last)
            XCTAssertTrue(Self.text(of: last).contains("[附带事件]\n- 你给 ta 那条「那我去睡啦」回了 👍"), "\(Self.text(of: last))")
        }
    }

    // MARK: - 空回复不留空泡

    func testSilentReactionTurnLeavesNoBubbleAndKeepsEvents() async throws {
        for (label, reply) in [("只贴表情", "```react\n❤️\n```"), ("什么都不写", "")] {
            let server = try ScriptedHTTPServer { _, _ in (200, "text/event-stream", Self.sse(reply)) }
            try server.start()
            defer { server.stop() }
            try await withHarness(bubble: true, server: server) { h, model, outbox, store in
                let vm = h.viewModel
                let a2 = try XCTUnwrap(vm.currentPath.last)
                let u2 = try XCTUnwrap(vm.currentPath.dropLast().last)
                let pathCount = vm.currentPath.count
                store.toggle("😂", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
                XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                                       providerManager: h.providerManager, context: h.context), .sent)
                try await waitUntil { !vm.assistantTurnInFlight }
                XCTAssertEqual(vm.currentPath.count, pathCount, "\(label)：不留空泡")
                XCTAssertEqual(vm.currentPath.last?.id, a2.id)
                XCTAssertTrue(a2.childrenIds.isEmpty, "\(label)：占位节点撤干净，不留空分支")
                XCTAssertEqual(vm.selectedConversation?.currentNodeId, a2.id)
                let texts = outbox.events(for: a2.conversationId).map(\.text)
                XCTAssertEqual(texts.first, "对你那条「回复二」回了 😂", "\(label)：触发事件放回箱里随下一条")
                if reply.isEmpty {
                    XCTAssertEqual(texts.count, 1)
                } else {
                    XCTAssertEqual(store.aiReactions(for: ChatReactionTarget(node: u2, blockIndex: 0, blockText: u2.content)), ["❤️"])
                    XCTAssertEqual(texts.last, "你给 ta 那条「第二条」回了 ❤️")
                }
            }
        }
    }

    // MARK: - 工具

    static func sse(_ text: String) -> Data {
        guard !text.isEmpty else { return Data("data: [DONE]\n\n".utf8) }
        let content = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return Data("data: {\"choices\":[{\"delta\":{\"content\":\(content)}}]}\n\ndata: [DONE]\n\n".utf8)
    }

    static func text(of message: [String: Any]) -> String {
        if let s = message["content"] as? String { return s }
        let parts = message["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private func withHarness(bubble: Bool, server: ScriptedHTTPServer?,
                             run: (PromptRealPathHarness, ProviderModel, ChatCardEventOutbox, ChatReactionStore) async throws -> Void) async throws {
        let h = try await PromptRealPathHarness.make(.init(name: "reaction", memoryEnabled: false, voiceHint: false,
                                                          memoryFixtures: false, bubbleMode: bubble))
        h.overrideDefault("imageTranscriptionEnabled", false)
        h.overrideDefault(PermissionDomain.fileLibrary.storageKey, PermissionLevel.notAllowed.rawValue)
        let suite = "ChatReactionTriggerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = ChatCardEventOutbox(defaults: defaults)
        let store = ChatReactionStore(defaults: defaults)
        h.viewModel.cardEventOutbox = outbox
        h.viewModel.reactionStore = store
        var model = h.model
        var extra: String?
        if let server {
            let id = "xctest-reaction-\(UUID().uuidString)"
            model = ProviderModel(credentialId: id, modelId: "gpt-4o", name: "Reaction Test")
            h.providerManager.addCredential(APICredential(id: id, name: "Reaction Test", emoji: "",
                                                          type: .openaiCompatible, baseURL: server.baseURL, models: [model],
                                                          toolsSupported: false))
            h.providerManager.setApiKey("test-key", for: id)
            h.viewModel.selectedConversation?.selectedModelId = model.id
            extra = id
        }
        defer { if let extra { h.providerManager.removeCredential(id: extra) } }
        do {
            try await run(h, model, outbox, store)
            h.viewModel.cancelAssistantTurn(context: h.context)
            await h.tearDown()
        } catch {
            h.viewModel.cancelAssistantTurn(context: h.context)
            await h.tearDown()
            throw error
        }
    }

    private func waitUntil(within seconds: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("没等到预期状态")
        throw URLError(.timedOut)
    }
}
