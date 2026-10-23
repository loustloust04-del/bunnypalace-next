import XCTest
import SwiftData
@testable import 记忆花园

/// 真正走 CC 消息落地 / edit 接线，不只测试 CallSession 的注入面。
@MainActor
final class CCCallReplyRoutingTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ConversationViewModel!
    private var events: [(String, String, Bool)] = []
    private let convId = "xctest-cc-call"

    override func setUp() async throws {
        container = try ModelContainer(for: ProfileManager.makeFullSchema(),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let root = MessageNode(id: "user-1", role: "user", content: "你好", contentType: "text",
                               createTime: Date(), parentId: nil, childrenIds: [],
                               conversationId: convId, profileId: "xctest-cc-call")
        let conv = Conversation(id: convId, title: "通话回归", createTime: Date(), updateTime: Date(),
                                currentNodeId: root.id, profileId: root.profileId)
        context.insert(root); context.insert(conv)
        try context.save()
        vm = ConversationViewModel()
        vm.loadConversation(conv, context: context)
        for _ in 0..<200 {
            if !vm.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(vm.isLoading)
        events = []
        vm.callReplyCanTrack = { request, conv in request == "user-1" && conv == self.convId }
        vm.callStreamHook = { [weak self] event, nodeId, _ in
            if case .externalReply(let text, let meta) = event {
                self?.events.append((nodeId, text, meta.streaming))
            }
        }
    }

    override func tearDown() async throws {
        vm.callStreamHook = nil
        vm.callReplyCanTrack = nil
        vm = nil; context = nil; container = nil
    }

    func testPlainReplyRoutesOnceAndDedupStillHolds() {
        insert("我在呢。", ccId: "cc-1", request: "user-1")
        insert("我在呢。", ccId: "cc-1", request: "user-1")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.1, "我在呢。")
        XCTAssertEqual(events.first?.2, false)
    }

    func testStreamingPlaceholderOnlySpeaksOnFinalEdit() {
        insert("", ccId: "cc-stream", request: "user-1", streaming: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.2, true)
        vm.applyCCEdit(chatId: convId, ccMessageId: "cc-stream", content: "正在写", streaming: true, context: context)
        XCTAssertEqual(events.count, 1)
        vm.applyCCEdit(chatId: convId, ccMessageId: "cc-stream", content: "写完了。", context: context)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.1, "写完了。")
        XCTAssertEqual(events.last?.2, false)
        vm.applyCCEdit(chatId: convId, ccMessageId: "cc-stream", content: "后来编辑过。", context: context)
        XCTAssertEqual(events.count, 2, "普通后续编辑不重新念")
    }

    func testOldOrUncorrelatedMessageDoesNotRouteToCall() {
        insert("旧回复。", ccId: "old", request: "previous-user")
        vm.insertProactiveAssistantMessage(chatId: convId, content: "主动消息。", ccMessageId: "proactive", context: context)
        XCTAssertTrue(events.isEmpty)
    }

    func testDetachDropsPendingFinalEdit() {
        insert("", ccId: "cc-stream", request: "user-1", streaming: true)
        vm.clearCallReplyTracking()
        vm.applyCCEdit(chatId: convId, ccMessageId: "cc-stream", content: "挂断后写完。", context: context)
        XCTAssertEqual(events.count, 1)
    }

    private func insert(_ text: String, ccId: String, request: String, streaming: Bool = false) {
        vm.insertProactiveAssistantMessage(chatId: convId, content: text, ccMessageId: ccId,
                                          callReply: CCCallReply(requestId: request, streaming: streaming), context: context)
    }
}
