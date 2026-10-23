import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 贴纸文件存储管理 — 图片存文件系统，不存 SwiftData
enum StickerFileManager {

    // MARK: - Image Cache

    /// 全局图片缓存（NSCache 自动在内存压力时驱逐，不需要手动管理）
    private static let imageCache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.countLimit = 200       // 最多 200 张
        cache.totalCostLimit = 50 * 1024 * 1024  // 50 MB
        return cache
    }()

    /// 缓存条目（包装 Data，NSCache 需要 class 类型）
    private final class CacheEntry {
        let data: Data
        init(_ data: Data) { self.data = data }
    }

    /// 带缓存的图片加载
    static func loadImageCached(path: String, profileId: String) -> Data? {
        let key = "\(profileId)/\(path)" as NSString
        if let entry = imageCache.object(forKey: key) {
            return entry.data
        }
        guard let data = loadImage(path: path, profileId: profileId) else { return nil }
        imageCache.setObject(CacheEntry(data), forKey: key, cost: data.count)
        return data
    }

    /// 清除指定贴纸的缓存
    static func evictCache(id: UUID, profileId: String) {
        let names = ["\(id.uuidString).png", "\(id.uuidString)_thumb.png"]
        for name in names {
            imageCache.removeObject(forKey: "\(profileId)/\(name)" as NSString)
        }
    }

    // MARK: - Directories

    /// 贴纸根目录: ~/Library/Application Support/MemoryPalace/stickers/{profileId}/
    static func stickerDirectory(profileId: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("stickers", isDirectory: true)
            .appendingPathComponent(profileId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Save

    /// 保存贴纸 PNG + 生成缩略图，返回 (imagePath, thumbnailPath) 相对文件名
    static func saveStickerImage(_ imageData: Data, id: UUID, profileId: String) throws -> (imagePath: String, thumbnailPath: String) {
        let dir = stickerDirectory(profileId: profileId)
        let imageName = "\(id.uuidString).png"
        let thumbName = "\(id.uuidString)_thumb.png"

        // 写入原尺寸 PNG
        let imageURL = dir.appendingPathComponent(imageName)
        try imageData.write(to: imageURL)

        // 生成缩略图（最大 200x200）
        let thumbData = generateThumbnail(from: imageData, maxSize: 200)
        let thumbURL = dir.appendingPathComponent(thumbName)
        try (thumbData ?? imageData).write(to: thumbURL)

        return (imageName, thumbName)
    }

    /// 保存原图（可选）
    static func saveOriginalImage(_ imageData: Data, id: UUID, profileId: String) throws -> String {
        let dir = stickerDirectory(profileId: profileId)
        let name = "\(id.uuidString)_original.png"
        let url = dir.appendingPathComponent(name)
        try imageData.write(to: url)
        return name
    }

    // MARK: - Load

    /// 加载贴纸图片
    static func loadImage(path: String, profileId: String) -> Data? {
        let url = stickerDirectory(profileId: profileId).appendingPathComponent(path)
        return try? Data(contentsOf: url)
    }

    /// 贴纸图片完整 URL
    static func imageURL(path: String, profileId: String) -> URL {
        stickerDirectory(profileId: profileId).appendingPathComponent(path)
    }

    // MARK: - Drawing（画稿：有它 = 能「继续画」）

    static func drawingURL(id: UUID, profileId: String) -> URL {
        stickerDirectory(profileId: profileId).appendingPathComponent("\(id.uuidString).mpdraw")
    }

    static func hasDrawing(id: UUID, profileId: String) -> Bool {
        FileManager.default.fileExists(atPath: drawingURL(id: id, profileId: profileId).path)
    }

    static func loadDrawing(id: UUID, profileId: String) -> DrawingDocument? {
        (try? Data(contentsOf: drawingURL(id: id, profileId: profileId))).flatMap(DrawingDocument.decode)
    }

    // MARK: - Delete

    /// 删除贴纸的所有文件
    static func deleteStickerFiles(id: UUID, profileId: String) {
        let dir = stickerDirectory(profileId: profileId)
        let names = [
            "\(id.uuidString).png",
            "\(id.uuidString)_thumb.png",
            "\(id.uuidString)_original.png",
            "\(id.uuidString).mpdraw",
        ]
        for name in names {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Thumbnail

    private static func generateThumbnail(from imageData: Data, maxSize: CGFloat) -> Data? {
        #if os(macOS)
        guard let image = NSImage(data: imageData),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return nil }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let ratio = min(maxSize / width, maxSize / height, 1.0)
        let newSize = NSSize(width: width * ratio, height: height * ratio)

        let thumbImage = NSImage(size: newSize)
        thumbImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSRect(origin: .zero, size: newSize).fill(using: .clear)
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1.0)
        thumbImage.unlockFocus()

        guard let thumbTiff = thumbImage.tiffRepresentation,
              let thumbBitmap = NSBitmapImageRep(data: thumbTiff) else { return nil }
        return thumbBitmap.representation(using: .png, properties: [:])
        #else
        guard let uiImage = UIImage(data: imageData) else { return nil }
        let width = uiImage.size.width
        let height = uiImage.size.height
        let ratio = min(maxSize / width, maxSize / height, 1.0)
        let newSize = CGSize(width: width * ratio, height: height * ratio)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        uiImage.draw(in: CGRect(origin: .zero, size: newSize))
        let thumb = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return thumb?.pngData()
        #endif
    }
}
