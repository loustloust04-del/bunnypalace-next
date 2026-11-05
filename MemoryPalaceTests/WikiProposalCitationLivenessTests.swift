import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class WikiProposalCitationLivenessTests: XCTestCase {
    private let pid = "citation-synthetic-floor"

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let conversation: Conversation
        let node: MessageNode
        let cite: WikiProposal.Cite
        let target: WikiProposalDisplay.MessageTarget
    }

    private enum Invalidation: CaseIterable {
        case nodeTrashed, nodeDeleted, windowTrashed, windowDeleted
        case nodeWrongFloor, nodeWrongWindow, windowWrongFloor
        case hidden, uiSystem, synthetic, systemRole, toolRole, emptyBody
    }

    private func fixture() throws -> Fixture {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let conversation = Conversation(id: "citation-window", title: "虚构创作", createTime: Date(), updateTime: Date(),
                                        currentNodeId: "cited-node", profileId: pid)
        let node = MessageNode(id: "cited-node", role: "user", content: "虚构的云桥城", contentType: "text", createTime: Date(),
                               parentId: nil, childrenIds: [], conversationId: conversation.id, profileId: pid)
        context.insert(conversation)
        context.insert(node)
        try context.save()
        let cite = WikiProposal.Cite(layer: "原文", windowId: conversation.id, profileId: pid,
                                     nodeId: node.id, role: node.role, onMain: true)
        let target = try XCTUnwrap(WikiProposalDisplay.messageTarget(for: cite, currentProfileId: pid))
        return Fixture(container: container, context: context, conversation: conversation, node: node, cite: cite, target: target)
    }

    private func invalidate(_ kind: Invalidation, fixture: Fixture) throws {
        switch kind {
        case .nodeTrashed: fixture.node.isTrashed = true
        case .nodeDeleted: fixture.context.delete(fixture.node)
        case .windowTrashed: fixture.conversation.isTrashed = true
        case .windowDeleted: fixture.context.delete(fixture.conversation)
        case .nodeWrongFloor: fixture.node.profileId = "another-floor"
        case .nodeWrongWindow: fixture.node.conversationId = "another-window"
        case .windowWrongFloor: fixture.conversation.profileId = "another-floor"
        case .hidden: fixture.node.sourceVisibility = "hidden"
        case .uiSystem: fixture.node.sourceVisibility = "uiSystem"
        case .synthetic: fixture.node.isSyntheticRoot = true
        case .systemRole: fixture.node.role = "system"
        case .toolRole: fixture.node.role = "tool"
        case .emptyBody: fixture.node.content = ""
        }
        try fixture.context.save()
    }

    private func loadedTargets(_ fixture: Fixture) -> Set<WikiProposalDisplay.MessageTarget> {
        WikiProposalDisplay.liveMessageTargets(for: [fixture.cite], currentProfileId: pid,
                                               context: ModelContext(fixture.container))
    }

    func testLoadingRejectsMissingDeletedOrInvisibleOriginals() throws {
        for kind in Invalidation.allCases {
            let f = try fixture()
            try invalidate(kind, fixture: f)
            let targets = loadedTargets(f)
            XCTAssertFalse(targets.contains(f.target), "加载时不得提供跳转箭头：\(kind)")
            let label = WikiProposalDisplay.citeText(f.cite, titles: [:], originalAvailable: targets.contains(f.target))
            XCTAssertTrue(label.contains("原消息已删除 / 不可定位"), "\(kind)")
            let vm = ConversationViewModel()
            XCTAssertFalse(WikiProposalDisplay.navigateToMessage(f.target, currentProfileId: pid,
                                                                container: f.container, viewModel: vm), "\(kind)")
            XCTAssertNil(vm.selectedConversation, "\(kind)")
            XCTAssertNil(vm.highlightedNodeId, "\(kind)")
            XCTAssertNil(vm.transientNotice, "失效节点不能误报已切换到分支：\(kind)")
        }
    }

    func testClickRefetchRejectsInvalidationAfterLoadingWithoutNavigating() throws {
        for kind in Invalidation.allCases {
            let f = try fixture()
            var targets = loadedTargets(f)
            XCTAssertTrue(targets.contains(f.target), "先加载有效出处：\(kind)")
            // 保留加载时的 context 和目标，模拟页面已显示箭头后发生删除 / 隐藏。
            try invalidate(kind, fixture: f)
            let vm = ConversationViewModel()
            let previous = Conversation(id: "previous-window", title: "另一个虚构窗口", createTime: Date(), updateTime: Date(),
                                        currentNodeId: "previous-node", profileId: pid)
            vm.selectedConversation = previous
            vm.highlightedNodeId = "previous-highlight"
            vm.scrollToNodeId = "previous-scroll"
            let notice = TransientNotice("原有提示")
            vm.transientNotice = notice
            let navigated = WikiProposalDisplay.navigateToMessage(f.target, currentProfileId: pid,
                                                                   container: f.container, viewModel: vm)
            if !navigated { targets.remove(f.target) }
            XCTAssertFalse(navigated, "点击时必须复核当前存储：\(kind)")
            XCTAssertFalse(targets.contains(f.target), "与 UI 相同：失败后去掉箭头：\(kind)")
            XCTAssertEqual(vm.selectedConversation?.id, previous.id, "\(kind)")
            XCTAssertEqual(vm.highlightedNodeId, "previous-highlight", "\(kind)")
            XCTAssertEqual(vm.scrollToNodeId, "previous-scroll", "\(kind)")
            XCTAssertNil(vm.pendingScrollNodeId, "\(kind)")
            XCTAssertFalse(vm.isLoading, "不得开始加载失效窗口：\(kind)")
            XCTAssertEqual(vm.transientNotice, notice, "不得误提示已切换到分支：\(kind)")
        }
    }

    func testWrongCurrentFloorAndIncompleteCitationCannotLocateOriginal() throws {
        let f = try fixture()
        XCTAssertTrue(WikiProposalDisplay.liveMessageTargets(for: [f.cite], currentProfileId: "another-floor",
                                                            context: ModelContext(f.container)).isEmpty)
        let vm = ConversationViewModel()
        XCTAssertFalse(WikiProposalDisplay.navigateToMessage(f.target, currentProfileId: "another-floor",
                                                            container: f.container, viewModel: vm))
        var missingNode = f.cite
        missingNode.nodeId = nil
        var missingWindow = f.cite
        missingWindow.windowId = nil
        XCTAssertTrue(WikiProposalDisplay.liveMessageTargets(for: [missingNode, missingWindow], currentProfileId: pid,
                                                            context: ModelContext(f.container)).isEmpty)
        XCTAssertNil(vm.selectedConversation)
        XCTAssertNil(vm.transientNotice)
    }

    func testMainPathOriginalNavigatesAndHighlightsActualNode() async throws {
        let f = try fixture()
        XCTAssertTrue(loadedTargets(f).contains(f.target))
        let vm = ConversationViewModel()
        XCTAssertTrue(WikiProposalDisplay.navigateToMessage(f.target, currentProfileId: pid,
                                                           container: f.container, viewModel: vm))
        try await waitForNavigation(vm, nodeId: f.target.nodeId)
        XCTAssertEqual(vm.selectedConversation?.id, f.target.conversationId)
        XCTAssertEqual(vm.currentPath.map(\.id), [f.target.nodeId])
        XCTAssertNil(vm.transientNotice, "有效主线原文不应提示切分支")
    }

    func testBranchSelectionChangedAfterLoadingStillNavigatesByNode() async throws {
        let f = try fixture()
        let root = MessageNode(id: "synthetic-root", role: "system", content: "", contentType: "text", createTime: Date(),
                               parentId: nil, childrenIds: [f.node.id, "other-branch"], conversationId: f.conversation.id, profileId: pid)
        root.isSyntheticRoot = true
        f.node.parentId = root.id
        f.node.role = "assistant"
        f.context.insert(root)
        f.context.insert(MessageNode(id: "other-branch", role: "assistant", content: "另一个虚构分支", contentType: "text",
                                    createTime: Date(), parentId: root.id, childrenIds: [], conversationId: f.conversation.id, profileId: pid))
        f.conversation.branchSelectionData = BranchSelection.encode([root.id: f.node.id])
        try f.context.save()
        XCTAssertTrue(loadedTargets(f).contains(f.target))
        // 加载之后换支，不是原消息失效。引用里的 onMain 不再代表当前主支线。
        f.conversation.branchSelectionData = BranchSelection.encode([root.id: "other-branch"])
        f.conversation.currentNodeId = "other-branch"
        try f.context.save()
        XCTAssertTrue(loadedTargets(f).contains(f.target))
        let vm = ConversationViewModel()
        XCTAssertTrue(WikiProposalDisplay.navigateToMessage(f.target, currentProfileId: pid,
                                                           container: f.container, viewModel: vm))
        try await waitForNavigation(vm, nodeId: f.target.nodeId)
        XCTAssertEqual(vm.selectedConversation?.id, f.target.conversationId)
        XCTAssertEqual(vm.currentPath.map(\.id), [f.target.nodeId])
        XCTAssertEqual(vm.transientNotice?.text, "已切换到分支", "仅仍存在的支线节点交给既有导航")
        let reader = ModelContext(f.container)
        let persisted = try XCTUnwrap(reader.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(persisted.currentNodeId, "other-branch")
        XCTAssertEqual(BranchSelection.decode(persisted.branchSelectionData), [root.id: "other-branch"], "临时定位不改持久分支选择")
    }

    func testLegacyALineCitationDoesNotBecomeAnOriginalTargetOrUnavailableLabel() throws {
        let f = try fixture()
        let cite = WikiProposal.Cite(layer: "A2", windowId: f.conversation.id, segment: 2)
        XCTAssertNil(WikiProposalDisplay.messageTarget(for: cite, currentProfileId: pid))
        XCTAssertTrue(WikiProposalDisplay.liveMessageTargets(for: [cite], currentProfileId: pid,
                                                            context: ModelContext(f.container)).isEmpty)
        let text = WikiProposalDisplay.citeText(cite, titles: [f.conversation.id: "虚构创作"], originalAvailable: false)
        XCTAssertTrue(text.contains("虚构创作"))
        XCTAssertTrue(text.contains("第 2 段"))
        XCTAssertFalse(text.contains("原消息已删除 / 不可定位"), "旧 A 线仍由原窗口概览路径处理")
    }

    private func waitForNavigation(_ vm: ConversationViewModel, nodeId: String) async throws {
        for _ in 0..<200 {
            if !vm.isLoading && vm.highlightedNodeId == nodeId { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.highlightedNodeId, nodeId)
        XCTAssertEqual(vm.scrollToNodeId, nodeId)
    }
}
