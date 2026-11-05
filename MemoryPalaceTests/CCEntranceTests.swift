import XCTest
import SwiftData
@testable import 记忆花园

/// CC 入场弹泡特征测试：场景 B 标记规则 + 泡长自适应节奏（plan-cc-bubble-entrance）。
final class CCEntranceTests: XCTestCase {

    // MARK: - entranceNodeIds（场景 B 标记）

    private func p(_ items: [(String, String)]) -> [(role: String, id: String)] {
        items.map { (role: $0.0, id: $0.1) }
    }

    func testTailAssistantsWithinUnread() {
        let path = p([("user", "u1"), ("assistant", "a1"), ("assistant", "a2"), ("assistant", "a3")])
        XCTAssertEqual(ConversationViewModel.entranceNodeIds(path: path, unread: 2, cap: 3),
                       ["a3", "a2"], "unread=2 只取尾部最后 2 条")
    }

    func testUnreadExceedsCapClampsToThree() {
        let path = p([("assistant", "a1"), ("assistant", "a2"), ("assistant", "a3"),
                      ("assistant", "a4"), ("assistant", "a5")])
        XCTAssertEqual(ConversationViewModel.entranceNodeIds(path: path, unread: 5, cap: 3),
                       ["a5", "a4", "a3"], "未读积压只弹最近 cap 条")
    }

    func testTailIsUserYieldsEmpty() {
        let path = p([("assistant", "a1"), ("user", "u1")])
        XCTAssertTrue(ConversationViewModel.entranceNodeIds(path: path, unread: 2, cap: 3).isEmpty,
                      "尾部不是 assistant（用户已回过/怪态）不弹")
    }

    func testZeroUnreadYieldsEmpty() {
        let path = p([("assistant", "a1")])
        XCTAssertTrue(ConversationViewModel.entranceNodeIds(path: path, unread: 0, cap: 3).isEmpty)
    }

    func testUnreadLargerThanTailRunStopsAtRunBoundary() {
        let path = p([("user", "u1"), ("assistant", "a1"), ("assistant", "a2")])
        XCTAssertEqual(ConversationViewModel.entranceNodeIds(path: path, unread: 3, cap: 3),
                       ["a2", "a1"], "连续段只有 2 条时到段界即止，不越过 user")
    }

    // MARK: - entranceDelay（泡长自适应节奏）

    func testShortBlockFastPop() {
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 20, isFirst: false), 0.23, accuracy: 0.001)
    }

    func testLongBlockSlowerPop() {
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 100, isFirst: false), 0.55, accuracy: 0.001)
    }

    func testVeryLongBlockClampedAtCeiling() {
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 300, isFirst: false), 0.7, accuracy: 0.001)
    }

    func testFirstPopHasDotsBeat() {
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 10, isFirst: true), 0.4, accuracy: 0.001,
                       "首泡前至少 0.4s dots 前奏")
        XCTAssertEqual(BubbleModeRow.entranceDelay(forBlockLength: 200, isFirst: true), 0.7, accuracy: 0.001,
                       "首块很长时取自适应值（>0.4）")
    }

    @MainActor
    func testDisabledPopPreservesLiveArrivalAndExplicitEnableRestoresEntrance() async throws {
        XCTAssertTrue(TestHostIsolation.active)
        guard TestHostIsolation.active else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: BubblePopTuning.enabledKey) as? Bool
        defer { defaults.set(saved, forKey: BubblePopTuning.enabledKey) }
        defaults.removeObject(forKey: BubblePopTuning.enabledKey)
        let (context, conversation, vm) = try fixture(assistantCount: 0)
        vm.loadConversation(conversation, context: context)
        try await waitForLoad(vm)
        vm.markPop("disabled-send")
        vm.insertProactiveAssistantMessage(chatId: conversation.id, content: "Immediate reply",
                                          ccMessageId: "disabled-arrival", context: context)
        XCTAssertEqual(vm.currentPath.map(\.content), ["Question", "Immediate reply"])
        XCTAssertTrue(vm.popNodeIds.isEmpty)
        XCTAssertTrue(vm.pendingEntranceNodeIds.isEmpty)

        defaults.set(true, forKey: BubblePopTuning.enabledKey)
        vm.markPop("enabled-send")
        vm.insertProactiveAssistantMessage(chatId: conversation.id, content: "Animated reply",
                                          ccMessageId: "enabled-arrival", context: context)
        let last = try XCTUnwrap(vm.currentPath.last)
        XCTAssertEqual(last.content, "Animated reply")
        XCTAssertEqual(vm.popNodeIds, ["enabled-send"])
        XCTAssertEqual(vm.pendingEntranceNodeIds, [last.id])
    }

    @MainActor
    func testDisabledUnreadEntranceStillMarksReadAndCannotReplayOnReenable() async throws {
        XCTAssertTrue(TestHostIsolation.active)
        guard TestHostIsolation.active else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: BubblePopTuning.enabledKey) as? Bool
        defer { defaults.set(saved, forKey: BubblePopTuning.enabledKey) }
        defaults.set(false, forKey: BubblePopTuning.enabledKey)
        let (context, conversation, vm) = try fixture(assistantCount: 2)
        vm.loadConversation(conversation, context: context)
        try await waitForLoad(vm)
        XCTAssertEqual(vm.currentPath.map(\.content), ["Question", "Reply 0", "Reply 1"])
        XCTAssertEqual(conversation.unreadCount, 0)
        XCTAssertTrue(vm.pendingEntranceNodeIds.isEmpty)

        defaults.set(true, forKey: BubblePopTuning.enabledKey)
        vm.loadConversation(conversation, context: context)
        try await waitForLoad(vm)
        XCTAssertTrue(vm.pendingEntranceNodeIds.isEmpty, "重开开关不能补弹已读消息")
        conversation.unreadCount = 2
        vm.loadConversation(conversation, context: context)
        try await waitForLoad(vm)
        XCTAssertEqual(vm.pendingEntranceNodeIds, Set(vm.currentPath.suffix(2).map(\.id)))
        XCTAssertEqual(conversation.unreadCount, 0)
    }

    @MainActor
    func testSwitchChangingDuringBackgroundLoadDiscardsEntranceSnapshot() async throws {
        XCTAssertTrue(TestHostIsolation.active)
        guard TestHostIsolation.active else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: BubblePopTuning.enabledKey) as? Bool
        defer { defaults.set(saved, forKey: BubblePopTuning.enabledKey) }
        for initial in [true, false] {
            let (context, conversation, vm) = try fixture(assistantCount: 2)
            defaults.set(initial, forKey: BubblePopTuning.enabledKey)
            vm.loadConversation(conversation, context: context)
            // 与load同一主线程调用栈，保证开关变化早于后台树回主线程apply。
            defaults.set(!initial, forKey: BubblePopTuning.enabledKey)
            try await waitForLoad(vm)
            XCTAssertEqual(vm.currentPath.map(\.content), ["Question", "Reply 0", "Reply 1"])
            XCTAssertTrue(vm.pendingEntranceNodeIds.isEmpty)
            defaults.set(true, forKey: BubblePopTuning.enabledKey)
            vm.loadConversation(conversation, context: context)
            try await waitForLoad(vm)
            XCTAssertTrue(vm.pendingEntranceNodeIds.isEmpty, "被丢弃的快照不能留到下一次apply")
        }
    }

    @MainActor
    private func fixture(assistantCount: Int) throws -> (ModelContext, Conversation, ConversationViewModel) {
        let container = try ModelContainer(for: ProfileManager.makeFullSchema(),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let id = UUID().uuidString
        var parent = MessageNode(id: "\(id)-u", role: "user", content: "Question", contentType: "text",
                                 createTime: Date(timeIntervalSince1970: 1), parentId: nil, childrenIds: [],
                                 conversationId: id, profileId: "cc-pop-tests")
        context.insert(parent)
        for index in 0..<assistantCount {
            let node = MessageNode(id: "\(id)-a\(index)", role: "assistant", content: "Reply \(index)", contentType: "text",
                                   createTime: Date(timeIntervalSince1970: Double(index + 2)),
                                   parentId: parent.id, childrenIds: [], conversationId: id, profileId: "cc-pop-tests")
            parent.childrenIds = [node.id]
            context.insert(node)
            parent = node
        }
        let conversation = Conversation(id: id, title: "弹泡回归", createTime: Date(), updateTime: Date(),
                                        currentNodeId: parent.id, profileId: "cc-pop-tests")
        conversation.unreadCount = assistantCount
        context.insert(conversation)
        try context.save()
        return (context, conversation, ConversationViewModel())
    }

    @MainActor
    private func waitForLoad(_ vm: ConversationViewModel) async throws {
        for _ in 0..<200 {
            if !vm.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(vm.isLoading)
    }
}
