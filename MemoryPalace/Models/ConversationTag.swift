import Foundation
import SwiftData

/// 对话标签 — 用户可自定义，多对多关联到 Conversation（通过 FavoriteItem join）
@Model
final class ConversationTag {
    #if os(iOS)
    #Index<ConversationTag>(
        [\.profileId],
        [\.profileId, \.order]
    )
    #endif

    @Attribute(.unique) var id: String = UUID().uuidString
    /// 楼层隔离
    var profileId: String = ""
    var name: String
    var emoji: String = "🏷"
    var order: Int = 0
    var createTime: Date = Date()
    /// 文件夹图标：SF Symbol 名；非空时优先于 emoji
    var symbol: String = ""
    /// 图标色（"#RRGGBB"），只配 symbol 用；空 = 默认灰
    var colorHex: String = ""
    /// 文件夹说明：这个文件夹里的 API 对话都会带上（CC 对话暂不注入）
    var instructions: String = ""

    init(name: String, emoji: String = "🏷", order: Int = 0, profileId: String = "") {
        self.id = UUID().uuidString
        self.name = name
        self.emoji = emoji
        self.order = order
        self.profileId = profileId
    }
}

/// Conversation ↔ ConversationTag 的 join item，也兼容收藏单条 bubble
@Model
final class FavoriteItem {
    #if os(iOS)
    #Index<FavoriteItem>(
        [\.profileId],
        [\.profileId, \.conversationId]
    )
    #endif

    @Attribute(.unique) var id: String = UUID().uuidString
    /// 楼层隔离
    var profileId: String = ""
    var nodeId: String?                    // if favoriting a single bubble
    var conversationId: String = ""        // always set (默认值用于 lightweight migration)
    var tagId: String = ""                 // which tag it belongs to (新字段，T0 refactor 时 folderId→tagId)
    var contentPreview: String = ""        // first ~100 chars for display
    var createTime: Date = Date()

    init(nodeId: String? = nil, conversationId: String, tagId: String, contentPreview: String, profileId: String) {
        self.id = UUID().uuidString
        self.nodeId = nodeId
        self.conversationId = conversationId
        self.tagId = tagId
        self.contentPreview = contentPreview
        self.profileId = profileId
    }
}
