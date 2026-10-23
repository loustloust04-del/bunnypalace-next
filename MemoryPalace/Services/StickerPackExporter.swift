import Foundation
import SwiftData
import ZIPFoundation

/// 贴纸包导出：资产 + 画布布局 → .stickerpack（zip）
enum StickerPackExporter {

    struct AssetRecord: Codable {
        let id: String
        let name: String
        let assetType: String
        let imagePath: String
        let thumbnailPath: String
        let borderStyle: String
        let borderWidth: Double
        let noteContent: String?
        let noteStyle: String?
        let tags: [String]
        let createdAt: Date
    }

    struct PlacementRecord: Codable {
        let id: String
        let stickerAssetId: String?
        let conversationId: String
        let nearestMessageId: String?
        let positionX: Double
        let positionY: Double
        let rotation: Double
        let scale: Double
        let zIndex: Int
        let noteContent: String?
        let noteStyle: String?
        let placedAt: Date
    }

    struct PackManifest: Codable {
        var version: Int = 1
        var exportDate: Date
        let profileId: String
        let assets: [AssetRecord]
        let placements: [PlacementRecord]
    }

    /// 导出贴纸包，返回临时 zip 文件路径
    static func export(profileId: String, context: ModelContext) async throws -> URL {
        let pid = profileId

        // 查资产
        let assetDesc = FetchDescriptor<StickerAsset>(
            predicate: #Predicate<StickerAsset> { a in a.profileId == pid }
        )
        let assets = (try? context.fetch(assetDesc)) ?? []

        // 查布局
        let placedDesc = FetchDescriptor<PlacedSticker>(
            predicate: #Predicate<PlacedSticker> { s in s.profileId == pid }
        )
        let placed = (try? context.fetch(placedDesc)) ?? []

        // 序列化
        let assetRecords = assets.map { a in
            AssetRecord(id: a.id.uuidString, name: a.name, assetType: a.assetType,
                       imagePath: a.imagePath, thumbnailPath: a.thumbnailPath,
                       borderStyle: a.borderStyle, borderWidth: a.borderWidth,
                       noteContent: a.noteContent, noteStyle: a.noteStyle,
                       tags: a.tags, createdAt: a.createdAt)
        }
        let placementRecords = placed.map { s in
            PlacementRecord(id: s.id.uuidString, stickerAssetId: s.stickerAssetId?.uuidString,
                          conversationId: s.conversationId, nearestMessageId: s.nearestMessageId,
                          positionX: s.positionX, positionY: s.positionY,
                          rotation: s.rotation, scale: s.scale, zIndex: s.zIndex,
                          noteContent: s.noteContent, noteStyle: s.noteStyle,
                          placedAt: s.placedAt)
        }

        let manifest = PackManifest(exportDate: Date(), profileId: profileId, assets: assetRecords, placements: placementRecords)

        // 临时目录
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("stickerpack_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 写 manifest
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(manifest)
        try jsonData.write(to: tmpDir.appendingPathComponent("manifest.json"))

        // 复制图片文件
        let stickerDir = StickerFileManager.stickerDirectory(profileId: profileId)
        let imagesDir = tmpDir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        for asset in assets where !asset.isNote {
            for path in [asset.imagePath, asset.thumbnailPath] where !path.isEmpty {
                let src = stickerDir.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: imagesDir.appendingPathComponent(path))
                }
            }
        }

        // ZIPFoundation 打包（跨平台），shouldKeepParent: false 让 manifest.json 和 images/ 在 zip 根层
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("贴纸包_\(UUID().uuidString).stickerpack")
        try FileManager.default.zipItem(at: tmpDir, to: zipURL, shouldKeepParent: false)

        return zipURL
    }
}
