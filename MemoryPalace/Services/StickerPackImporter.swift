import Foundation
import SwiftData
import ZIPFoundation

/// 贴纸包导入：.stickerpack → 资产 + 画布归位
enum StickerPackImporter {

    struct ImportResult {
        let assets: Int
        let placements: Int
    }

    /// 导入贴纸包，返回导入数量
    static func importPack(url: URL, profileId: String, context: ModelContext) async throws -> ImportResult {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // 解压到临时目录
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("stickerpack_import_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // ZIPFoundation 解压（跨平台）
        try FileManager.default.unzipItem(at: url, to: tmpDir)

        // 找 manifest.json（可能在子目录里）
        let manifestURL = findFile(named: "manifest.json", in: tmpDir)
        guard let manifestURL else {
            throw ImportError.noManifest
        }

        // 解析
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: StickerPackExporter.PackManifest
        do {
            manifest = try decoder.decode(StickerPackExporter.PackManifest.self, from: data)
        } catch {
            throw ImportError.decodeFailed(error.localizedDescription)
        }

        // images 目录
        let imagesDir = manifestURL.deletingLastPathComponent().appendingPathComponent("images")
        let stickerDir = StickerFileManager.stickerDirectory(profileId: profileId)

        // ID 映射：旧 UUID → 新 UUID
        var idMap: [String: UUID] = [:]

        // 导入资产
        var assetCount = 0
        for record in manifest.assets {
            let newId = UUID()
            idMap[record.id] = newId

            if record.assetType == "note" {
                let asset = StickerAsset(
                    noteContent: record.noteContent ?? "",
                    noteStyle: record.noteStyle ?? "yellow_square",
                    name: record.name,
                    tags: record.tags,
                    profileId: profileId
                )
                asset.id = newId
                context.insert(asset)
            } else {
                // 复制图片文件（用新 UUID 命名）
                let newImagePath = "\(newId.uuidString).png"
                let newThumbPath = "\(newId.uuidString)_thumb.png"

                if !record.imagePath.isEmpty {
                    let src = imagesDir.appendingPathComponent(record.imagePath)
                    let dst = stickerDir.appendingPathComponent(newImagePath)
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
                if !record.thumbnailPath.isEmpty {
                    let src = imagesDir.appendingPathComponent(record.thumbnailPath)
                    let dst = stickerDir.appendingPathComponent(newThumbPath)
                    try? FileManager.default.copyItem(at: src, to: dst)
                }

                let asset = StickerAsset(
                    name: record.name,
                    imagePath: newImagePath,
                    thumbnailPath: newThumbPath,
                    borderStyle: record.borderStyle,
                    borderWidth: record.borderWidth,
                    tags: record.tags,
                    profileId: profileId
                )
                asset.id = newId
                context.insert(asset)
            }
            assetCount += 1
        }

        // 导入布局（画布归位）
        var placementCount = 0
        for record in manifest.placements {
            let newAssetId: UUID? = record.stickerAssetId.flatMap { idMap[$0] }

            let sticker = PlacedSticker(
                stickerAssetId: newAssetId,
                conversationId: record.conversationId,
                nearestMessageId: record.nearestMessageId,
                positionX: record.positionX,
                positionY: record.positionY,
                rotation: record.rotation,
                scale: record.scale,
                zIndex: record.zIndex,
                noteContent: record.noteContent,
                noteStyle: record.noteStyle,
                profileId: profileId
            )
            context.insert(sticker)
            placementCount += 1
        }

        try context.save()
        return ImportResult(assets: assetCount, placements: placementCount)
    }

    // MARK: - Helpers

    private static func findFile(named name: String, in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        // 搜索子目录（zip 可能有一层包裹目录）
        if let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for item in contents {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    let sub = item.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: sub.path) { return sub }
                }
            }
        }
        return nil
    }

    enum ImportError: LocalizedError {
        case noManifest
        case unzipFailed(String)
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noManifest: return "贴纸包格式无效（找不到 manifest.json）"
            case .unzipFailed(let msg): return "解压失败：\(msg)"
            case .decodeFailed(let msg): return "解析失败：\(msg)"
            }
        }
    }
}
