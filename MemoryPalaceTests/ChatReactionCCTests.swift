import XCTest
import SwiftData
@testable import 记忆花园

/// plan-cc-reactions-1105 第 1 步：CC 对话里她贴表情 → 马上单独发一帧给 CC（不建她的泡），CC 忙就等这轮收口。
/// 注入 defaults suite + 假 task 抓帧，不碰真 hub / 真库
@MainActor
final class ChatReactionCCTests: XCTestCase {
    private var std: UserDefaults!
    private var stdName: String!
    private var prefix: String!
    private var session: URLSession!
    private var primary: CCBridgeWebSocketClient!
    private var wire: CCHubRoutingTests.Wire!
    private var harness: PromptRealPathHarness?
    private var savedDeliver: ((String) -> ChatReactionTrigger.Outcome)?
    private var savedRetry: Duration = .seconds(2)

    override func setUp() async throws {
        try await super.setUp()
        stdName = "ChatReactionCCTests.std.\(UUID().uuidString)"
        std = UserDefaults(suiteName: stdName)!
        prefix = "ChatReactionCCTests.hub.\(UUID().uuidString)."
        session = URLSession(configuration: .ephemeral)
        savedDeliver = ChatReactionTrigger.shared.deliver
        savedRetry = ChatReactionTrigger.shared.retryDelay
    }

    override func tearDown() async throws {
        if let cid = harness?.viewModel.selectedConversation?.id { ChatReactionTrigger.shared.cancel(conversationId: cid) }
        ChatReactionTrigger.shared.deliver = savedDeliver
        ChatReactionTrigger.shared.retryDelay = savedRetry
        CCSessionPhaseStore.shared.onTurnSettled = nil
        harness?.viewModel.cancelAssistantTurn(context: harness!.context)
        await harness?.tearDown()
        harness = nil
        primary?.disconnect()
        primary?.setTransmitHookForTesting(nil)
        session.invalidateAndCancel()
        std.removePersistentDomain(forName: stdName)
        try await super.tearDown()
    }

    // MARK: - 夹具

    private struct Fixture {
        let h: PromptRealPathHarness
        let cc: ProviderModel
        let conversation: Conversation
        let outbox: ChatCardEventOutbox
        let store: ChatReactionStore
        var vm: ConversationViewModel { h.viewModel }
    }

    private func make(bubble: Bool = true, connect: Bool = true) async throws -> Fixture {
        let h = try await PromptRealPathHarness.make(.init(name: "cc-reaction", profileId: "xctest-ccreact-\(UUID().uuidString)",
                                                          memoryEnabled: false, voiceHint: false, memoryFixtures: false,
                                                          bubbleMode: bubble))
        harness = h
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-reaction")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.ccBridgeSessionName = "mp-cc-xtest"
        conversation.selectedModelId = cc.id
        h.viewModel.ccSentLedger = CCSentHubLedger(defaults: std)
        h.viewModel.ccOriginLedger = CCChatOriginLedger(defaults: std)
        let p = CCBridgeWebSocketClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: std, transportOffMain: false)
        primary = p
        wire = CCHubRoutingTests.Wire()
        wire.install(on: p)
        let r = CCHubRegistry(primary: p, standard: std, suitePrefix: prefix, secrets: CCHubRegistryTests.FakeSecrets(),
                              originDefaults: std) { id, d in CCBridgeWebSocketClient(hubId: id, defaults: d, transportOffMain: false) }
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = r
        if connect { await open(p) }
        let outbox = ChatCardEventOutbox(defaults: std)
        let store = ChatReactionStore(defaults: std)
        h.viewModel.cardEventOutbox = outbox
        h.viewModel.reactionStore = store
        return Fixture(h: h, cc: cc, conversation: conversation, outbox: outbox, store: store)
    }

    private func open(_ client: CCBridgeWebSocketClient) async {
        let u = URL(string: "ws://127.0.0.1:9/cc")!
        let task = session.webSocketTask(with: u)
        client.adoptTaskForTesting(task, url: u)
        client.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        let connected = await waitFor { client.isConnected && client.currentTaskForTesting === task }
        XCTAssertTrue(connected)
        client.handleIncoming(#"{"type":"hello"}"#, source: task)
        let verified = await waitFor { client.identityVerifiedForTesting }
        XCTAssertTrue(verified)
    }

    @discardableResult
    private func waitFor(timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return cond()
    }

    private func pause(_ ms: UInt64 = 200) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    /// 她给 a2 贴一个（不经 trigger：测试自己调 triggerReactionReply）
    private func react(_ f: Fixture, _ emoji: String = "❤️", trigger: ChatReactionTrigger? = nil) throws {
        let a2 = try XCTUnwrap(f.vm.currentPath.last)
        f.store.toggle(emoji, on: ChatReactionTarget(node: a2), outbox: f.outbox, trigger: trigger)
    }

    private func trigger(_ f: Fixture) -> ChatReactionTrigger.Outcome {
        f.vm.triggerReactionReply(model: f.cc, profile: f.h.profile, preset: f.h.preset,
                                  providerManager: f.h.providerManager, context: f.h.context)
    }

    private func phase(_ f: Fixture, _ p: CCSessionPhase.Phase, updated: Date = Date()) {
        let frame: [String: Any] = ["session_name": "mp-cc-xtest", "chat_id": f.conversation.id, "phase": p.rawValue,
                                    "updated_unix": updated.timeIntervalSince1970]
        CCSessionPhaseStore.shared.apply(CCSessionPhase(frame: frame)!, hubId: CCBridgeWebSocketClient.primaryHubId)
    }

    /// 同 ContentView 的接线
    private func wireSettle(_ f: Fixture) {
        CCSessionPhaseStore.shared.onTurnSettled = { [weak vm = f.vm] chatId, hubId, at in
            vm?.ccTurnSettled(chatId: chatId, hubId: hubId, settledAt: at)
        }
    }

    /// 同 CardFlowView.registerReactionTrigger（不看输入框）
    private func wireDeliver(_ f: Fixture, retry: Duration) {
        ChatReactionTrigger.shared.retryDelay = retry
        ChatReactionTrigger.shared.deliver = { [weak vm = f.vm, h = f.h, cc = f.cc] cid in
            guard let vm, vm.selectedConversation?.id == cid else { return .unsupported }
            return vm.triggerReactionReply(model: cc, profile: h.profile, preset: h.preset,
                                           providerManager: h.providerManager, context: h.context)
        }
    }

    // MARK: - T1.1 / T1.2 / T1.3 贴了就发

    func testReactionSendsOneFrameWithEventContentAndNoUserBubble() async throws {
        let f = try await make()
        let pathBefore = f.vm.currentPath.map(\.id)
        let leafBefore = f.conversation.currentNodeId
        let nodesBefore = try f.h.context.fetchCount(FetchDescriptor<MessageNode>())
        try react(f)
        let expected = ChatCardEventPrompt.turnContent(f.outbox.events(for: f.conversation.id))
        XCTAssertEqual(trigger(f), .sent)
        await waitFor { self.wire.sent("send").count == 1 }
        let frame = try XCTUnwrap(wire.sent("send").first)
        XCTAssertEqual(frame["content"] as? String, expected)
        XCTAssertTrue(expected.hasPrefix("[附带事件]"))
        XCTAssertTrue((frame["message_id"] as? String)?.hasPrefix("react-") == true)
        XCTAssertEqual(frame["session_name"] as? String, "mp-cc-xtest")
        XCTAssertEqual(frame["chat_id"] as? String, f.conversation.id)
        // T1.2
        XCTAssertTrue(f.outbox.events(for: f.conversation.id).isEmpty, "整箱取走")
        XCTAssertNotNil(f.vm.ccWaitingSince[f.conversation.id], "等待泡挂上")
        // T1.3
        XCTAssertEqual(f.vm.currentPath.map(\.id), pathBefore, "不建她的泡")
        XCTAssertEqual(f.conversation.currentNodeId, leafBefore)
        XCTAssertEqual(try f.h.context.fetchCount(FetchDescriptor<MessageNode>()), nodesBefore)
    }

    // MARK: - T1.4 / T1.5 忙就等

    func testWaitingForReplyIsBusyAndLeavesOutboxAlone() async throws {
        let f = try await make()
        f.vm.ccWaitingSince[f.conversation.id] = Date()
        try react(f)
        XCTAssertEqual(trigger(f), .busy)
        await pause()
        XCTAssertTrue(wire.sent("send").isEmpty)
        XCTAssertEqual(f.outbox.events(for: f.conversation.id).count, 1, "箱子不动")
    }

    func testWorkingOrWaitingPhaseIsBusy() async throws {
        let f = try await make()
        try react(f)
        phase(f, .working)
        XCTAssertEqual(trigger(f), .busy)
        phase(f, .waiting)
        XCTAssertEqual(trigger(f), .busy, "CC 在等她回答问题：也等")
        phase(f, .done)
        XCTAssertEqual(trigger(f), .sent)
        await waitFor { self.wire.sent("send").count == 1 }
        XCTAssertEqual(wire.sent("send").count, 1)
    }

    // MARK: - T1.6 阶段收口立刻发（不靠 2 秒轮询）

    func testDonePhaseClearsWaitingAndDeliversImmediately() async throws {
        let f = try await make()
        wireSettle(f)
        wireDeliver(f, retry: .seconds(60))
        let oldStamp = Date().addingTimeInterval(-5)
        f.vm.ccWaitingSince[f.conversation.id] = oldStamp
        f.vm.ccWaitingHub[f.conversation.id] = CCBridgeWebSocketClient.primaryHubId
        phase(f, .working)
        try react(f, trigger: .shared)
        await waitFor { ChatReactionTrigger.shared.isPending(f.conversation.id) }
        await pause()
        XCTAssertTrue(wire.sent("send").isEmpty, "CC 在跑：不发")
        phase(f, .done)
        let sent = await waitFor(timeout: 1) { self.wire.sent("send").count == 1 }
        XCTAssertTrue(sent, "收口立刻发（轮询隔 60 秒，能发出来只可能是 turnDidEnd）")
        let stamp = try XCTUnwrap(f.vm.ccWaitingSince[f.conversation.id])
        XCTAssertGreaterThan(stamp, oldStamp, "旧等待泡被清掉，现在挂的是表情这轮的")
    }

    // MARK: - T1.7 旧的 done 帧不清新等待泡

    func testStaleDoneFrameDoesNotClearNewerWaiting() async throws {
        let f = try await make()
        wireSettle(f)
        phase(f, .working)
        let stamp = Date()
        f.vm.ccWaitingSince[f.conversation.id] = stamp
        f.vm.ccWaitingHub[f.conversation.id] = CCBridgeWebSocketClient.primaryHubId
        phase(f, .done, updated: stamp.addingTimeInterval(-10))
        XCTAssertEqual(f.vm.ccWaitingSince[f.conversation.id], stamp)
        phase(f, .working)
        phase(f, .done, updated: stamp.addingTimeInterval(1))
        XCTAssertNil(f.vm.ccWaitingSince[f.conversation.id], "新的 done 帧照清")
    }

    // MARK: - T1.8 没有阶段帧：回复落地补投

    func testReplyLandingWithoutPhaseFramesDeliversWaitingReaction() async throws {
        let f = try await make()
        f.vm.ccReplySettleGrace = 0
        wireDeliver(f, retry: .seconds(60))
        f.vm.ccWaitingSince[f.conversation.id] = Date()
        try react(f, trigger: .shared)
        await waitFor { ChatReactionTrigger.shared.isPending(f.conversation.id) }
        await pause()
        XCTAssertTrue(wire.sent("send").isEmpty)
        f.vm.insertProactiveAssistantMessage(chatId: f.conversation.id, content: "好", ccMessageId: "m-\(UUID().uuidString)",
                                             context: f.h.context)
        let sent = await waitFor(timeout: 1) { self.wire.sent("send").count == 1 }
        XCTAssertTrue(sent, "回复落地 → turnDidEnd → 立刻再投")
    }

    /// V1：老 hub 下 CC 忙时塞进去的消息会并进当前轮 → 回复落地后 3 秒内也算忙；有阶段帧就以阶段为准
    func testReplyGraceOnlyAppliesWithoutPhaseFrames() async throws {
        let f = try await make()
        f.vm.insertProactiveAssistantMessage(chatId: f.conversation.id, content: "第一段", ccMessageId: "m-\(UUID().uuidString)",
                                             context: f.h.context)
        XCTAssertTrue(f.vm.isCCTurnBusy(f.conversation), "刚落地一段、没有阶段帧：再等 3 秒")
        XCTAssertFalse(f.vm.isCCTurnBusy(f.conversation, now: Date().addingTimeInterval(4)))
        phase(f, .done)
        XCTAssertFalse(f.vm.isCCTurnBusy(f.conversation), "有阶段帧：done 就是空闲")
    }

    // MARK: - T1.9 / T1.10 守门

    func testDisconnectedIsUnsupportedSilently() async throws {
        let f = try await make(connect: false)
        try react(f)
        XCTAssertEqual(trigger(f), .unsupported)
        await pause()
        XCTAssertTrue(wire.frames.isEmpty)
        XCTAssertEqual(f.outbox.events(for: f.conversation.id).count, 1, "留在箱里跟下一条走")
        XCTAssertNil(f.vm.transientNotice, "不弹提示条")
        XCTAssertNil(f.vm.ccWaitingSince[f.conversation.id])
    }

    func testArticleModeCCIsUnsupported() async throws {
        let f = try await make(bubble: false)
        try react(f)
        XCTAssertEqual(trigger(f), .unsupported)
        await pause()
        XCTAssertTrue(wire.sent("send").isEmpty)
        XCTAssertEqual(f.outbox.events(for: f.conversation.id).count, 1)
    }

    func testNoSessionNameIsUnsupported() async throws {
        let f = try await make()
        f.conversation.ccBridgeSessionName = nil
        try react(f)
        XCTAssertEqual(trigger(f), .unsupported)
        XCTAssertEqual(f.outbox.events(for: f.conversation.id).count, 1)
    }
}
