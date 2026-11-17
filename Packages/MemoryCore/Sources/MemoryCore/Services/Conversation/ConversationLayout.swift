import Foundation

/// 打开一个对话时「走哪条路径、显示哪些节点」的全部纯计算（docs/plan-重构.md §3.7 第 4 步 4c）。
/// 入参是节点的轻量信息，不碰 SwiftData，后台线程和单测直接用；对话页只负责取数据和把结果套上去。
public enum ConversationLayout {
    public struct Node: Equatable {
        public var parentId: String?
        public var childrenIds: [String]
        public var role: String
        public var hasDisplayableContent: Bool
        public var isTrashed: Bool

        public init(parentId: String?, childrenIds: [String], role: String, hasDisplayableContent: Bool, isTrashed: Bool) {
            self.parentId = parentId
            self.childrenIds = childrenIds
            self.role = role
            self.hasDisplayableContent = hasDisplayableContent
            self.isTrashed = isTrashed
        }
    }

    public struct Result: Equatable {
        /// 有效孩子表（见 `BranchSelection.Resolution.children`）
        public var effectiveChildren: [String: [String]]
        public var rootId: String?
        /// 持久选择走出来的那条完整路径（主线），含不显示的节点
        public var mainPathIds: Set<String>
        /// 显示出来的节点，从根到末端
        public var visibleIds: [String]
        public var bubbledBranches: [String: String]
        /// 显示用的选择表和路径末端（搜索跳转时叠了「去目标」的选择，只在内存里）
        public var displaySelection: [String: String]
        public var displayLeafId: String?
        /// 修补后的持久选择表；`selectionChanged` = 需要写回
        public var persistedSelection: [String: String]
        public var selectionChanged: Bool
    }

    /// `legacyCurrentNodeId`：老对话没有选择表时，用它那条路径当选择。
    /// `browseTargetId`：搜索跳转要去的节点，不在库里就当没给
    public static func load(nodes: [String: Node], selection: [String: String], legacyCurrentNodeId: String,
                            browseTargetId: String?) -> Result {
        var links: [String: BranchSelection.Link] = [:]
        links.reserveCapacity(nodes.count)
        for (id, node) in nodes {
            links[id] = BranchSelection.Link(id: id, parentId: node.parentId, childrenIds: node.childrenIds)
        }
        // 选择只走这一个 resolver：持久选择表 → 旧 currentNodeId 路径 → 稳定序第一个。
        // 根是 currentNodeId 的顶层祖先（失效时取无父节点里 id 最小的，至少确定，见 docs/research-conversation-blank-bug.md）
        let persisted = BranchSelection.resolve(byId: links, selection: selection, legacyCurrentNodeId: legacyCurrentNodeId)
        let children = persisted.children

        var displaySelection = persisted.selection
        var displayPathIds = persisted.pathIds
        if let target = browseTargetId, links[target] != nil,
           let targetRoot = BranchSelection.trace(from: target, in: links).rootId {
            displaySelection = BranchSelection.selecting(
                target, in: persisted.selection,
                parentOf: { links[$0]?.parentId },
                childCount: { children[$0]?.count ?? 0 })
            displayPathIds = BranchSelection.walk(from: targetRoot, children: children,
                                                  selection: displaySelection, fallbackPath: Set(persisted.pathIds))
        }

        // 库里没有的节点跳过
        let display = DisplayPath.project(
            pathIds: displayPathIds.lazy.filter { nodes[$0] != nil },
            isDisplayable: { id in
                nodes[id].map { DisplayPath.isDisplayable(role: $0.role, hasDisplayableContent: $0.hasDisplayableContent,
                                                          isTrashed: $0.isTrashed) } ?? false
            },
            childCount: { children[$0]?.count ?? 0 })

        return Result(effectiveChildren: children, rootId: displayPathIds.first ?? persisted.rootId,
                      mainPathIds: Set(persisted.pathIds), visibleIds: display.visibleIds,
                      bubbledBranches: display.bubbledBranches, displaySelection: displaySelection,
                      displayLeafId: displayPathIds.last, persistedSelection: persisted.selection,
                      selectionChanged: persisted.changed)
    }
}
