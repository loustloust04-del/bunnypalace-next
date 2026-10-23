import Foundation
import SwiftData

/// 贴纸库资产 — 图片贴纸或便签模板
@Model
final class StickerAsset {
    #if os(iOS)
    #Index<StickerAsset>([\.profileId, \.createdAt])
    #endif

    @Attribute(.unique) var id: UUID = UUID()
    var name: String = ""
    var assetType: String = "image"         // "image" | "note"

    // 图片贴纸字段
    var imagePath: String = ""              // 相对路径: "{id}.png"
    var thumbnailPath: String = ""          // 缩略图: "{id}_thumb.png"
    var originalImagePath: String?          // 原图（可选保留）
    var borderStyle: String = "none"        // BorderStyle.rawValue
    var borderWidth: Double = 8.0           // 描边宽度 pt
    var filterStyle: String = "none"        // FilterStyle.rawValue

    // 便签字段
    var noteContent: String?                // 便签文字
    var noteStyle: String?                  // "yellow_square", "pink_rounded", "glass", "torn_paper"

    var tags: [String] = []
    var createdAt: Date = Date()
    var profileId: String = ""              // 楼层隔离

    var isNote: Bool { assetType == "note" }

    /// 图片贴纸构造器
    init(
        name: String,
        imagePath: String,
        thumbnailPath: String,
        originalImagePath: String? = nil,
        borderStyle: String = "none",
        borderWidth: Double = 8.0,
        tags: [String] = [],
        profileId: String
    ) {
        self.assetType = "image"
        self.name = name
        self.imagePath = imagePath
        self.thumbnailPath = thumbnailPath
        self.originalImagePath = originalImagePath
        self.borderStyle = borderStyle
        self.borderWidth = borderWidth
        self.tags = tags
        self.profileId = profileId
    }

    /// 便签构造器
    init(
        noteContent: String,
        noteStyle: String,
        name: String = "",
        tags: [String] = [],
        profileId: String
    ) {
        self.assetType = "note"
        self.name = name.isEmpty ? String(noteContent.prefix(10)) : name
        self.noteContent = noteContent
        self.noteStyle = noteStyle
        self.tags = tags
        self.profileId = profileId
    }
}
