import XCTest
import SwiftData
@testable import 记忆花园

/// perf-flash C2：顶栏 🌿 角标的计数快路径必须与分支图 sheet（collectAllBranches）同口径
@MainActor
final class BranchOffMainCountTests: XCTestCase {
    func testCountMatchesCollectAllBranches() async throws {
        let container = try ModelContainer(for: Conversation.self, MessageNode.self, FavoriteItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let pid = "test-branch-floor"
        let conv = Conversation(id: "branch-count", title: "fixture", createTime: Date(), updateTime: Date(),
                                currentNodeId: "m-19", profileId: pid)
        ctx.insert(conv)
        var children: [String: [String]] = [:]
        var nodes: [(id: String, role: String, parent: String?, trashed: Bool)] = []
        func add(_ id: String, _ role: String, _ parent: String?, trashed: Bool = false) {
            nodes.append((id, role, parent, trashed))
            if let parent { children[parent, default: []].append(id) }
        }
        for i in 0..<20 { add("m-\(i)", i % 2 == 0 ? "user" : "assistant", i == 0 ? nil : "m-\(i - 1)") }
        // 主线 5 处一级分支（3 节点），其中 b5 下再嵌套一条
        for f in [3, 7] {
            add("b\(f)-0", "user", "m-\(f)"); add("b\(f)-1", "assistant", "b\(f)-0"); add("b\(f)-2", "user", "b\(f)-1")
        }
        add("n7-0", "assistant", "b7-0")                     // 嵌套分支：b7-0 有两个孩子
        add("t11-0", "user", "m-11", trashed: true)          // 只有回收站节点的分支：不计
        add("s13-0", "system", "m-13")                       // 只有系统节点的分支：不计
        add("x15-0", "user", "m-15")                         // 同一锚点两条旁支
        add("y15-0", "user", "m-15")
        for n in nodes {
            let node = MessageNode(id: n.id, role: n.role, content: "c \(n.id)", contentType: "text", createTime: Date(),
                                   parentId: n.parent, childrenIds: children[n.id] ?? [], conversationId: conv.id, profileId: pid)
            node.isTrashed = n.trashed
            ctx.insert(node)
        }
        try ctx.save()
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        let vm = ConversationViewModel()
        vm.loadConversation(try XCTUnwrap(reader.fetch(FetchDescriptor<Conversation>()).first), context: reader)
        for _ in 0..<200 where vm.isLoading { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(vm.isLoading)
        let full = vm.collectAllBranches().count
        XCTAssertEqual(vm.branchOffMainCount(), full)
        XCTAssertEqual(full, 5)   // b3、b7、b7 内嵌套 n7、x15、y15
    }
}
