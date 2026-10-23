import XCTest
import SwiftData
@testable import 记忆花园

/// docs/bug-branch-late-apply-overwrite.md：同一对话 A→B→A 快速连发加载，较早请求的后台结果晚到不得覆盖最新请求
@MainActor
final class ConversationLoadGenerationTests: XCTestCase {
    private func makeFixture() throws -> (ModelContext, Conversation) {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let pid = "test-load-generation"
        let conv = Conversation(id: "load-gen", title: "fixture", createTime: Date(), updateTime: Date(),
                                currentNodeId: "O1", provider: "sillytavern", profileId: pid)
        ctx.insert(conv)
        let root = MessageNode(id: "S", role: "system", content: "", contentType: "text", createTime: Date(),
                               parentId: nil, childrenIds: ["O1", "O2", "O3"], conversationId: conv.id, profileId: pid)
        root.isSyntheticRoot = true
        ctx.insert(root)
        for id in ["O1", "O2", "O3"] {
            ctx.insert(MessageNode(id: id, role: "assistant", content: "开场 \(id)", contentType: "text",
                                   createTime: Date(), parentId: "S", childrenIds: [], conversationId: conv.id, profileId: pid))
        }
        try ctx.save()
        return (ctx, conv)
    }

    private func waitLoaded(_ vm: ConversationViewModel) async throws {
        for _ in 0..<200 where vm.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(vm.isLoading)
    }

    func testLateEarlierLoadDoesNotOverwriteLatest() async throws {
        let (ctx, conv) = try makeFixture()
        let vm = ConversationViewModel()
        vm.loadConversation(conv, context: ctx)
        try await waitLoaded(vm)
        XCTAssertEqual(vm.currentPath.map(\.id), ["O1"])

        // A1：临时浏览 O3（带跳转目标），后台建树强制晚到 600ms
        vm.testNextLoadBuildDelay = 0.6
        vm.pendingScrollNodeId = "O3"
        vm.loadConversation(conv, context: ctx, scrollTargetNodeId: "O3")
        // B：临时浏览 O2；A2：回主线
        vm.loadConversation(conv, context: ctx, scrollTargetNodeId: "O2")
        vm.loadConversation(conv, context: ctx)
        try await waitLoaded(vm)
        XCTAssertEqual(vm.currentPath.map(\.id), ["O1"])

        // 等 A1 的迟到结果回到主线程
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(vm.currentPath.map(\.id), ["O1"], "迟到的 A1 不得把行改回 O3")
        XCTAssertEqual(vm.branchSelection["S"], "O1")
        XCTAssertEqual(vm.branchInfoMap.keys.sorted(), ["O1"], "分支标记跟着 A2 的行，不是 A1 的 O3")
        XCTAssertEqual(vm.branchInfoMap["O1"]?.currentIndex, 0)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.scrollToNodeId, "被顶掉的请求的跳转目标跟着丢")
        XCTAssertNil(vm.highlightedNodeId)
        XCTAssertNil(vm.pendingScrollNodeId)
    }

    func testLatestJumpStillApplies() async throws {
        let (ctx, conv) = try makeFixture()
        let vm = ConversationViewModel()
        vm.testNextLoadBuildDelay = 0.3
        vm.loadConversation(conv, context: ctx)
        vm.pendingScrollNodeId = "O3"
        vm.loadConversation(conv, context: ctx, scrollTargetNodeId: "O3")
        try await waitLoaded(vm)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(vm.currentPath.map(\.id), ["O3"])
        XCTAssertEqual(vm.scrollToNodeId, "O3")
        XCTAssertEqual(vm.highlightedNodeId, "O3")
    }

    /// R11-01：Page2 css 聊天盯 currentPath，列表被清空那刻补发一单不带目标的加载。
    /// 补发条件必须是 needsInitialLoad（有在途加载就不补），否则用户那单带的跳转被代号顶掉
    func testPage2StyleColdLoadDoesNotSupersedeJump() async throws {
        let (ctx, conv) = try makeFixture()
        let vm = ConversationViewModel()
        vm.selectedConversation = conv
        XCTAssertTrue(vm.needsInitialLoad, "冷启动：选中了对话但从没加载过")

        let probe = ReloadProbe()
        func observe() {
            withObservationTracking { _ = vm.currentPath } onChange: {
                Task { @MainActor in
                    guard probe.observing else { return }
                    if vm.needsInitialLoad, let c = vm.selectedConversation {
                        probe.reloads += 1
                        vm.loadConversation(c, context: ctx)
                    }
                    observe()
                }
            }
        }
        observe()
        vm.loadConversation(conv, context: ctx)
        try await waitLoaded(vm)
        XCTAssertEqual(vm.currentPath.map(\.id), ["O1"])

        // 搜索点主线消息：navigateToSearchResult 的主线分支 = 设 pending 再 plain 加载
        vm.pendingScrollNodeId = "O1"
        vm.loadConversation(conv, context: ctx)
        try await waitLoaded(vm)
        try await Task.sleep(for: .milliseconds(300))
        probe.observing = false
        XCTAssertEqual(probe.reloads, 0, "有在途加载时不补发")
        XCTAssertEqual(vm.currentPath.map(\.id), ["O1"])
        XCTAssertEqual(vm.scrollToNodeId, "O1", "跳转没被补发的加载顶掉")
        XCTAssertEqual(vm.highlightedNodeId, "O1")
    }

    /// R11-02：apply 已落、跳转还没派发时被更新的请求顶掉 → 跳转跟着丢（二次派发核代号）
    func testJumpDispatchDroppedWhenSupersededAfterApply() async throws {
        let (ctx, conv) = try makeFixture()
        let vm = ConversationViewModel()
        vm.loadConversation(conv, context: ctx)
        try await waitLoaded(vm)

        vm.pendingScrollNodeId = "O3"
        vm.loadConversation(conv, context: ctx, scrollTargetNodeId: "O3")
        // apply 里 isLoading = false 同步触发；排在 apply 末尾的跳转派发之前发一单 plain 加载
        withObservationTracking { _ = vm.isLoading } onChange: {
            DispatchQueue.main.async { vm.loadConversation(conv, context: ctx) }
        }
        for _ in 0..<200 where vm.scrollToNodeId == nil && vm.currentPath.map(\.id) != ["O1"] {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await waitLoaded(vm)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(vm.currentPath.map(\.id), ["O1"])
        XCTAssertNil(vm.scrollToNodeId, "被顶掉的 O3 跳转不派发")
        XCTAssertNil(vm.highlightedNodeId)
    }

    /// 加载在途时删除当前对话（selection 置空）：最新那单被对话守卫丢弃，isLoading 也得清
    func testDeletingCurrentConversationWhileLoadingClearsLoading() async throws {
        let (ctx, conv) = try makeFixture()
        let vm = ConversationViewModel()
        vm.testNextLoadBuildDelay = 0.3
        vm.loadConversation(conv, context: ctx)
        XCTAssertTrue(vm.isLoading)
        vm.softDeleteConversation(conv)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(vm.selectedConversation)
        XCTAssertFalse(vm.isLoading, "不再卡「加载中」")
        XCTAssertTrue(vm.currentPath.isEmpty)
    }
}

@MainActor
private final class ReloadProbe {
    var observing = true
    var reloads = 0
}
