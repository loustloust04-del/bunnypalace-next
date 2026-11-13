import Foundation
import SwiftData

/// 表情包（plan-bubble-sticker-send）：点一下作为一条消息发出去；和拖到画布的 StickerAsset 是两套库
@Model
final class ChatMeme {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    /// 一句话描述，给 AI 看（〖表情包：名字——描述〗）
    var detail: String = ""
    /// 原文件名 "{id}.{ext}"，在 MemeStore.directory 下
    var fileName: String = ""
    var mimeType: String = "image/png"
    var isFavorite: Bool = false
    var lastSentAt: Date?
    var createdAt: Date = Date()
    var profileId: String = ""

    init(id: UUID = UUID(), name: String, detail: String = "", fileName: String, mimeType: String, profileId: String) {
        self.id = id
        self.name = name
        self.detail = detail
        self.fileName = fileName
        self.mimeType = mimeType
        self.profileId = profileId
    }

    var isAnimated: Bool { mimeType == "image/gif" || mimeType == "image/webp" }
}
