import XCTest
import SwiftData
@testable import 记忆花园

/// plan-cc-reactions-1105 第 3 步：mac 气泡右键菜单「回应」子菜单（12 个表情，已贴的打勾，点了走 ChatReactionStore.toggle）
@MainActor
final class MacReactionMenuTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suite = "MacReactionMenuTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private let target = ChatReactionTarget(nodeId: "n1", conversationId: "c1", snippet: "晚安啦", isAssistant: true, blockIndex: 0)

    // MARK: - T3.1

    func testItemsListTwelveEmojisAndMarkPicked() {
        let store = ChatReactionStore(defaults: defaults)
        let outbox = ChatCardEventOutbox(defaults: defaults)
        let items = MacReactionMenu.items(target: target, store: store)
        XCTAssertEqual(items.map(\.emoji), ChatReactionStore.emojis)
        XCTAssertTrue(items.allSatisfy { !$0.selected })

        MacReactionMenu.pick("❤️", target: target, store: store, outbox: outbox, trigger: nil)
        XCTAssertEqual(store.reactions(for: target), ["❤️"])
        XCTAssertEqual(outbox.events(for: "c1").map(\.text), ["对你那条「晚安啦」回了 ❤️"])
        let after = MacReactionMenu.items(target: target, store: store)
        XCTAssertEqual(after.filter(\.selected).map(\.emoji), ["❤️"], "已贴的打勾")

        MacReactionMenu.pick("❤️", target: target, store: store, outbox: outbox, trigger: nil)
        XCTAssertTrue(store.reactions(for: target).isEmpty, "再点一次撤掉")
        XCTAssertTrue(outbox.events(for: "c1").isEmpty, "还没发出去：箱里那条一起撤")
    }

    // MARK: - T3.2 CC 对话：点一项走第 1 步的发送

    func testPickOnCCConversationSendsReactionFrame() async throws {
        let h = try await PromptRealPathHarness.make(.init(name: "mac-reaction-menu", profileId: "xctest-macreact-\(UUID().uuidString)",
                                                          memoryEnabled: false, voiceHint: false, memoryFixtures: false,
                                                          bubbleMode: true))
        let savedDeliver = ChatReactionTrigger.shared.deliver
        let session = URLSession(configuration: .ephemeral)
        let p = CCBridgeWebSocketClient(hubId: CCBridgeWebSocketClient.primaryHubId, defaults: defaults, transportOffMain: false)
        defer {
            ChatReactionTrigger.shared.deliver = savedDeliver
            p.disconnect()
            p.setTransmitHookForTesting(nil)
            session.invalidateAndCancel()
        }
        let cc = h.addCard(type: .ccBridge, modelId: "xctest-cc-macmenu")
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.ccBridgeSessionName = "mp-cc-xtest"
        h.viewModel.ccSentLedger = CCSentHubLedger(defaults: defaults)
        h.viewModel.ccOriginLedger = CCChatOriginLedger(defaults: defaults)
        let wire = CCHubRoutingTests.Wire()
        wire.install(on: p)
        h.viewModel.ccBridgeClient = p
        h.viewModel.ccHubRegistry = CCHubRegistry(primary: p, standard: defaults, suitePrefix: "MacReactionMenuTests.hub.\(UUID().uuidString).",
                                                  secrets: CCHubRegistryTests.FakeSecrets(), originDefaults: defaults) { id, d in
            CCBridgeWebSocketClient(hubId: id, defaults: d, transportOffMain: false)
        }
        let u = URL(string: "ws://127.0.0.1:9/cc")!
        let task = session.webSocketTask(with: u)
        p.adoptTaskForTesting(task, url: u)
        p.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        try await waitUntil { p.isConnected }
        p.handleIncoming(#"{"type":"hello"}"#, source: task)
        try await waitUntil { p.identityVerifiedForTesting }
        let outbox = ChatCardEventOutbox(defaults: defaults)
        let store = ChatReactionStore(defaults: defaults)
        h.viewModel.cardEventOutbox = outbox
        h.viewModel.reactionStore = store
        ChatReactionTrigger.shared.deliver = { [weak vm = h.viewModel] cid in
            guard let vm, vm.selectedConversation?.id == cid else { return .unsupported }
            return vm.triggerReactionReply(model: cc, profile: h.profile, preset: h.preset,
                                           providerManager: h.providerManager, context: h.context)
        }
        let a2 = try XCTUnwrap(h.viewModel.currentPath.last)
        let blockTarget = ChatReactionTarget(node: a2, blockIndex: 0, blockText: a2.content)
        MacReactionMenu.pick("👍", target: blockTarget, store: store, outbox: outbox, trigger: .shared)
        try await waitUntil { wire.sent("send").count == 1 }
        XCTAssertTrue((wire.sent("send").first?["content"] as? String)?.contains("回了 👍") == true)
        XCTAssertTrue(outbox.events(for: conversation.id).isEmpty)
        h.viewModel.cancelAssistantTurn(context: h.context)
        await h.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("没等到预期状态")
        throw URLError(.timedOut)
    }
}
