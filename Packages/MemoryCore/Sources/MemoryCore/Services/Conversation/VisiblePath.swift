import Foundation

/// 主线路径的唯一口径（plan §2.2）：
/// `BranchSelection.resolve` 用**全量节点**（含已删）建树 → 按路径顺序过滤
/// `!isTrashed && !isSourceHidden && !isSyntheticRoot && role ∈ {user, assistant} && hasDisplayableContent`。
/// 不产正文；正文用 `CatalogOriginalText.body(of:)`。
public func visiblePath(window: ConversationWindow, nodes: [ConversationMessage]) -> [ConversationMessage] {
    let resolution = BranchSelection.resolve(
        links: nodes.map { .init(id: $0.id, parentId: $0.parentId, childrenIds: $0.childrenIds) },
        selection: BranchSelection.decode(window.branchSelection),
        legacyCurrentNodeId: window.currentNodeId)
    let lookup = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    return resolution.pathIds.compactMap { id -> ConversationMessage? in
        guard let node = lookup[id], !node.isTrashed, !node.isSourceHidden, !node.isSyntheticRoot,
              node.role == "user" || node.role == "assistant", node.hasDisplayableContent else { return nil }
        return node
    }
}
