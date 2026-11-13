import XCTest
import SwiftData
@testable import 记忆花园

/// plan-cc-reactions-1105 2b：CC 回复落地时剥 ```react 块、把表情贴到她的消息上；只贴表情的回复不建节点、后续 thinking 丢掉
@MainActor
final class ChatReactionCCLandingTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var harness: PromptRealPathHarness?

    override func setUp() async throws {
        try await super.setUp()
        suite = "ChatReactionCCLandingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        harness?.viewModel.cancelAssistantTurn(context: harness!.context)
        await harness?.tearDown()
        harness = nil
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private struct Fixture {
        let h: PromptRealPathHarness
        let conversation: Conversation
        let outbox: ChatCardEventOutbox
        let store: ChatReactionStore
        let u1: MessageNode
        let u2: MessageNode
        let a2: MessageNode
        var vm: ConversationViewModel { h.viewModel }
    }

    private func make(bubble: Bool = true) async throws -> Fixture {
        let h = try await PromptRealPathHarness.make(.init(name: "cc-react-landing", profileId: "xctest-ccland-\(UUID().uuidString)",
                                                          memoryEnabled: false, voiceHint: false, memoryFixtures: false,
                                                          bubbleMode: bubble))
        harness = h
        let conversation = try XCTUnwrap(h.viewModel.selectedConversation)
        conversation.ccBridgeSessionName = "mp-cc-xtest"
        let outbox = ChatCardEventOutbox(defaults: defaults)
        let store = ChatReactionStore(defaults: defaults)
        h.viewModel.cardEventOutbox = outbox
        h.viewModel.reactionStore = store
        h.viewModel.ccReactOnlyReplies = CCReactOnlyReplies(defaults: defaults)
        let users = h.viewModel.currentPath.filter { $0.role == "user" }
        return Fixture(h: h, conversation: conversation, outbox: outbox, store: store,
                       u1: try XCTUnwrap(users.first), u2: try XCTUnwrap(users.last), a2: try XCTUnwrap(h.viewModel.currentPath.last))
    }

    private func land(_ f: Fixture, _ content: String, id: String = "m-\(UUID().uuidString)", fileData: Data? = nil) {
        f.vm.insertProactiveAssistantMessage(chatId: f.conversation.id, content: content, fileData: fileData, fileName: "a.txt",
                                             mime: "text/plain", ccMessageId: id, context: f.h.context)
    }

    private func ai(_ f: Fixture, _ node: MessageNode) -> [String] {
        f.store.aiReactions(for: ChatReactionTarget(node: node, blockIndex: 0, blockText: node.content))
    }

    private func assistantCount(_ f: Fixture) throws -> Int {
        let cid = f.conversation.id
        return try f.h.context.fetchCount(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == cid && $0.role == "assistant" }))
    }

    private func node(_ id: String, user: Bool = true) -> MessageNode {
        MessageNode(id: id, role: user ? "user" : "assistant", content: "消息 \(id)", contentType: "text", createTime: Date(),
                    parentId: nil, childrenIds: [], conversationId: "c", profileId: "p")
    }

    // MARK: - T2b.1 按 id 找

    func testTargetMatchesExactNodeIdBeyondTwentyAndKeepsPrefixMatching() {
        let ancestors = (0..<30).map { node("N-\($0)") } + [node("A-1", user: false)]
        let old = ancestors[25]
        XCTAssertEqual(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: old.id), among: ancestors)?.id, old.id,
                       "id 精确匹配不受前 20 条限制")
        XCTAssertEqual(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: old.id.lowercased()), among: ancestors)?.id, old.id)
        XCTAssertNil(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: "A-1"), among: ancestors), "AI 自己的不算")
        XCTAssertEqual(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: "消息 N-4"), among: ancestors)?.id, "N-4", "开头匹配照旧")
        XCTAssertNil(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: "消息 N-25"), among: ancestors), "开头匹配仍只看前 20 条")
        XCTAssertEqual(ChatReactionIntent.target(for: .init(emoji: "❤️", hint: ""), among: ancestors)?.id, "N-0")
    }

    // MARK: - T2b.2 / T2b.10 正文 + 块

    func testReplyWithTextAndBlockStripsAndReactsLatestMessage() async throws {
        let f = try await make()
        land(f, "晚安\n\n```react\n❤️\n```")
        let reply = try XCTUnwrap(f.vm.currentPath.last)
        XCTAssertEqual(reply.role, "assistant")
        XCTAssertEqual(reply.content, "晚安")
        XCTAssertEqual(ai(f, f.u2), ["❤️"])
        XCTAssertTrue(ai(f, f.u1).isEmpty)
        XCTAssertFalse(f.outbox.events(for: f.conversation.id).contains { $0.key?.hasPrefix("ai-reaction:") == true },
                       "CC 的转录里留着块，不往箱里记「你给 ta…」")
    }

    // MARK: - T2b.3 / T2b.4 / T2b.5 只有块

    func testReactOnlyReplyBuildsNoNodeAndDropsLaterThinking() async throws {
        let f = try await make()
        f.vm.ccWaitingSince[f.conversation.id] = Date()
        let pathBefore = f.vm.currentPath.map(\.id)
        let assistantsBefore = try assistantCount(f)
        let unreadBefore = f.conversation.unreadCount
        let id = "m-\(UUID().uuidString)"
        land(f, "```react\n❤️\n```", id: id)
        XCTAssertEqual(f.vm.currentPath.map(\.id), pathBefore, "不建节点")
        XCTAssertEqual(try assistantCount(f), assistantsBefore)
        XCTAssertEqual(ai(f, f.u2), ["❤️"])
        XCTAssertEqual(f.conversation.unreadCount, unreadBefore)
        XCTAssertNil(f.vm.ccWaitingSince[f.conversation.id], "等待泡照清")
        XCTAssertTrue(f.vm.ccReactOnlyReplies.contains(id))

        // T2b.4
        f.vm.applyCCThinking(chatId: f.conversation.id, ccMessageId: id, content: "思考", context: f.h.context)
        XCTAssertNil(f.a2.ccThinking, "不退到上一条 CC 回复上")

        // T2b.5 重启后（新 VM、同一份存储）迟到的 thinking 照样丢
        let fresh = ConversationViewModel()
        fresh.ccReactOnlyReplies = CCReactOnlyReplies(defaults: defaults)
        fresh.applyCCThinking(chatId: f.conversation.id, ccMessageId: id, content: "思考", context: f.h.context)
        XCTAssertNil(f.a2.ccThinking)
    }

    func testReactOnlyLedgerKeepsNewest200() {
        let ledger = CCReactOnlyReplies(defaults: defaults)
        for i in 0..<205 { ledger.insert("r\(i)") }
        XCTAssertFalse(ledger.contains("r0"))
        XCTAssertFalse(ledger.contains("r4"))
        XCTAssertTrue(ledger.contains("r5"))
        XCTAssertTrue(CCReactOnlyReplies(defaults: defaults).contains("r204"), "持久化")
    }

    // MARK: - T2b.6 / T2b.7 指定目标

    func testHintWithNodeIdReactsThatEarlierMessage() async throws {
        let f = try await make()
        land(f, "记得\n\n```react\n👍 \(f.u1.id)\n```")
        XCTAssertEqual(ai(f, f.u1), ["👍"])
        XCTAssertTrue(ai(f, f.u2).isEmpty)
        XCTAssertEqual(f.vm.currentPath.last?.content, "记得")
    }

    func testUnmatchedHintStripsButDoesNotReact() async throws {
        let f = try await make()
        land(f, "嗯\n\n```react\n👍 没有这条\n```")
        XCTAssertEqual(f.vm.currentPath.last?.content, "嗯")
        XCTAssertTrue(ai(f, f.u1).isEmpty && ai(f, f.u2).isEmpty)
        XCTAssertTrue(BreadcrumbLog.shared.entries.last?.text.contains("CC 贴表情") == true)
    }

    // MARK: - T2b.8 / T2b.9 守门

    func testReplayedReactOnlyReplyIsIdempotent() async throws {
        let f = try await make()
        let pathBefore = f.vm.currentPath.map(\.id)
        let id = "m-\(UUID().uuidString)"
        land(f, "```react\n❤️\n```", id: id)
        f.vm.ccWaitingSince[f.conversation.id] = Date()
        land(f, "```react\n❤️\n```", id: id)
        XCTAssertEqual(ai(f, f.u2), ["❤️"])
        XCTAssertEqual(f.vm.currentPath.map(\.id), pathBefore)
        XCTAssertNotNil(f.vm.ccWaitingSince[f.conversation.id], "回放的旧回复不清新的等待泡")
    }

    func testMultiLineReactCodeIsKept() async throws {
        let f = try await make()
        let code = "示例：\n\n```react\nconst App = () => <div>❤️</div>\nexport default App\n```"
        land(f, code)
        XCTAssertEqual(f.vm.currentPath.last?.content, code)
        XCTAssertTrue(ai(f, f.u2).isEmpty)
    }

    // MARK: - T2b.11 文章模式

    func testArticleModeAlsoStripsAndRecords() async throws {
        let f = try await make(bubble: false)
        land(f, "好\n\n```react\n🎉\n```")
        XCTAssertEqual(f.vm.currentPath.last?.content, "好")
        XCTAssertEqual(ai(f, f.u2), ["🎉"])
    }

    // MARK: - T2b.12 / T2b.13 edit 帧

    func testStreamingEditHidesBlock() async throws {
        let f = try await make()
        let id = "m-\(UUID().uuidString)"
        land(f, "好", id: id)
        f.vm.applyCCEdit(chatId: f.conversation.id, ccMessageId: id, content: "好\n\n```react\n👍", streaming: true, context: f.h.context)
        XCTAssertEqual(f.vm.currentPath.last?.content, "好")
        XCTAssertTrue(ai(f, f.u2).isEmpty, "中间态不贴")
    }

    func testFinalEditStripsAndReactsOrRollsBack() async throws {
        let f = try await make()
        let id = "m-\(UUID().uuidString)"
        land(f, "好", id: id)
        f.vm.applyCCEdit(chatId: f.conversation.id, ccMessageId: id, content: "好的\n\n```react\n👍\n```", context: f.h.context)
        XCTAssertEqual(f.vm.currentPath.last?.content, "好的")
        XCTAssertEqual(ai(f, f.u2), ["👍"])

        let id2 = "m-\(UUID().uuidString)"
        land(f, "…", id: id2)
        let pathWith = f.vm.currentPath.map(\.id)
        f.vm.applyCCEdit(chatId: f.conversation.id, ccMessageId: id2, content: "```react\n❤️\n```", context: f.h.context)
        XCTAssertEqual(f.vm.currentPath.map(\.id), Array(pathWith.dropLast()), "只剩块：撤掉节点")
        XCTAssertTrue(f.vm.ccReactOnlyReplies.contains(id2))
        let reply1 = try XCTUnwrap(f.vm.currentPath.last)
        XCTAssertEqual(reply1.ccMessageId, id)
        XCTAssertEqual(ai(f, f.u2), ["👍", "❤️"], "撤掉的那条的祖先里她最近一条还是 u2")
    }

    // MARK: - T2b.14 和别的块共存

    func testReactStrippedOtherBlocksKept() async throws {
        let f = try await make()
        land(f, "听这个\n\n```voice\n晚安呀\n```\n\n```react\n❤️\n```")
        let reply = try XCTUnwrap(f.vm.currentPath.last)
        XCTAssertTrue(reply.content.contains("```voice"))
        XCTAssertFalse(reply.content.contains("```react"))
        XCTAssertEqual(ai(f, f.u2), ["❤️"])
    }

    // MARK: - 只贴表情但带了文件：照建节点

    func testReactOnlyWithFileStillBuildsNode() async throws {
        let f = try await make()
        land(f, "```react\n❤️\n```", fileData: Data("x".utf8))
        let reply = try XCTUnwrap(f.vm.currentPath.last)
        XCTAssertEqual(reply.role, "assistant")
        XCTAssertEqual(reply.content, "")
        XCTAssertEqual(ai(f, f.u2), ["❤️"])
    }
}
