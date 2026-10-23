import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

// MARK: - 纪念日照片（plan-calendar-photos-todos §1.1 + astra #1 #12）
// ImageIO 压缩 / 读图，iOS 和 mac 共用。方向在缩略时烤进像素（WithTransform），输出不再带 EXIF 方向。

enum AnniversaryPhoto {
    /// 存盘长边
    static let storedMaxPixel = 1200
    /// 桌面小组件缩略图长边
    static let widgetMaxPixel = 400

    /// 任意图片数据（HEIC / JPEG / PNG…）→ 长边不超过 maxPixel 的 JPEG
    static func jpeg(from data: Data, maxPixel: Int = storedMaxPixel, quality: Double = 0.85) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = downsample(src, maxPixel: maxPixel) else { return nil }
        return encode(image, quality: quality)
    }

    /// 读图并缩到 maxPixel（显示用）
    static func image(at url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsample(src, maxPixel: maxPixel)
    }

    static func image(from data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(src, maxPixel: maxPixel)
    }

    /// 内容哈希前 8 位：照片文件名带它，换图后路径变（不可变文件）
    static func hash8(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func downsample(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
