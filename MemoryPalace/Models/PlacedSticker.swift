import Foundation
import SwiftData

/// 画布上的贴纸实例 — 贴在对话里的具体位置
/// 未来演化为通用 CanvasElement 的第一种类型
@Model
final class PlacedSticker {
    #if os(iOS)
    #Index<PlacedSticker>(
        [\.profileId, \.conversationId],
        [\.profileId, \.conversationId, \.zIndex]
    )
    #endif

    @Attribute(.unique) var id: UUID = UUID()
    var stickerAssetId: UUID?           // nil = 便签贴纸（无图片资产）
    var conversationId: String = ""
    var nearestMessageId: String?       // 自动计算的最近消息（搜索集成用）

    // 画布定位
    var positionX: Double = 0
    var positionY: Double = 0
    var rotation: Double = 0            // 角度（微歪）
    var scale: Double = 1.0
    var zIndex: Int = 0                 // 图层叠加顺序

    // 便签内容（NoteSticker）
    var noteContent: String?            // nil = 图片贴纸
    var noteStyle: String?              // "yellow_square", "pink_rounded", "glass", "torn_paper"

    // 状态
    var isLocked: Bool = false

    // 元数据
    var placedAt: Date = Date()
    var profileId: String = ""

    /// 是否为便签贴纸
    var isNote: Bool { noteContent != nil }

    init(
        stickerAssetId: UUID? = nil,
        conversationId: String,
        nearestMessageId: String? = nil,
        positionX: Double,
        positionY: Double,
        rotation: Double = Double.random(in: -3...3),
        scale: Double = 1.0,
        zIndex: Int = 0,
        noteContent: String? = nil,
        noteStyle: String? = nil,
        profileId: String
    ) {
        self.stickerAssetId = stickerAssetId
        self.conversationId = conversationId
        self.nearestMessageId = nearestMessageId
        self.positionX = positionX
        self.positionY = positionY
        self.rotation = rotation
        self.scale = scale
        self.zIndex = zIndex
        self.noteContent = noteContent
        self.noteStyle = noteStyle
        self.profileId = profileId
    }
}
