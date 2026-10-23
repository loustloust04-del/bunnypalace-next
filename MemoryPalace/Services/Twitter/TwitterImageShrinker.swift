import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 存头像/横幅前把相册原图缩小转 JPEG。
/// 走 ImageIO 缩略图接口：不整张解码进内存，iOS/macOS 一套代码。
enum TwitterImageShrinker {
    static let avatarPixel = 400
    static let bannerPixel = 1500
    /// 发推配图：推特自己也是长边 2048 左右
    static let postPixel = 2048

    /// 长边缩到 `maxPixel` 以内（小图不放大），按 EXIF 方向转正。读不出来返回 nil。
    static func jpeg(from data: Data, maxPixel: Int, quality: Double = 0.85) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return nil }

        // 缩略图接口不保证不放大，自己夹一下
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, max(w, h)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
