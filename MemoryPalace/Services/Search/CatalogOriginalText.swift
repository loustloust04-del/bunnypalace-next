import MemoryCore
import Foundation

/// 编目专用正文；不改变搜索框或已有索引。必须在持有 node 的 ModelContext 内调用。
/// 正文口径已搬包（`MemoryCore.CatalogOriginalText`），这里只留 `MessageNode` 便利重载。
extension MemoryCore.CatalogOriginalText {
    static func body(of node: MessageNode) -> String {
        body(of: ConversationMessage(node))
    }
}

extension ConversationMessage {
    /// 完整转换：读 `segmentsData`（SwiftData 外部存储）并解码。
    /// 正文口径 / 后台取数（`wikiScanBody`、`CatalogOriginalText`）用它；
    /// 刷新键与扫描窗口筛选**不要**用（会扩大观察范围并在主线程解码整条路径的外置分段）。
    init(_ node: MessageNode) {
        self.init(node, includeSegments: true)
    }

    /// 标量转换：只读已驻内存的普通字段，**不访问 `segmentsData`**，`segments = nil`。
    /// `MemoryResident.WikiNodeRevision` 的契约：刷新只观察已驻内存的值；
    /// `MemoryResidentPage.refreshKey` 与 `ConversationViewModel.wikiScanWindow` 的筛选必须走这个。
    init(scalar node: MessageNode) {
        self.init(node, includeSegments: false)
    }

    private init(_ node: MessageNode, includeSegments: Bool) {
        self.init(
            id: node.id, conversationId: node.conversationId, role: node.role, content: node.content,
            // segmentsData 有值却解不开 = 空分段（正文口径返回 ""，不回退扁平 content）；
            // 值类型用 nil 表示「没有分段数据」，所以这里刻意保留非 nil。
            // 标量模式三元短路掉整段，连 `segmentsData` 这个属性都不读。
            segments: includeSegments
                ? (node.segmentsData == nil ? nil : (node.segments ?? []).map { segment in
                    switch segment {
                    case .text(let value): return .text(value)
                    case .thinking(let text, _, _): return .thinking(text)
                    case .audioRef: return .audioRef
                    default: return .other
                    }
                })
                : nil,
            contentType: node.contentType, createTime: node.createTime, parentId: node.parentId,
            childrenIds: node.childrenIds, isTrashed: node.isTrashed, isSyntheticRoot: node.isSyntheticRoot,
            sourceVisibility: node.sourceVisibility, ccMessageId: node.ccMessageId,
            cardEditedAt: node.cardEditedAt, ccEdited: node.ccEdited)
    }
}
