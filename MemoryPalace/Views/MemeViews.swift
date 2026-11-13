import ImageIO
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
typealias MemePlatformImage = UIImage
#else
import AppKit
typealias MemePlatformImage = NSImage
#endif

/// 表情包图片解码（后台）+ 缓存。动图在 iOS 拆帧（≤120 帧、边长 ≤ maxPixel），mac 交给 NSImageView 原生播放
enum MemeImageLoader {
    private static let cache: NSCache<NSString, MemePlatformImage> = {
        let c = NSCache<NSString, MemePlatformImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    static func cached(_ key: String) -> MemePlatformImage? { cache.object(forKey: key as NSString) }

    static func load(url: URL, maxPixel: Int, animated: Bool) async -> MemePlatformImage? {
        let key = "\(url.path)#\(maxPixel)#\(animated)"
        if let hit = cached(key) { return hit }
        let image = await Task.detached(priority: .userInitiated) { decode(url: url, maxPixel: maxPixel, animated: animated) }.value
        if let image { cache.setObject(image, forKey: key as NSString, cost: maxPixel * maxPixel * 4) }
        return image
    }

    private static func decode(url: URL, maxPixel: Int, animated: Bool) -> MemePlatformImage? {
        #if os(macOS)
        if animated { return NSImage(contentsOf: url) }
        #endif
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        let count = CGImageSourceGetCount(src)
        #if os(iOS)
        if animated, count > 1 {
            var frames: [UIImage] = []
            var duration: Double = 0
            for i in 0..<min(count, 120) {
                guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) else { continue }
                frames.append(UIImage(cgImage: cg))
                duration += frameDelay(src, i)
            }
            return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
        }
        #endif
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let dict = (props?[kCGImagePropertyGIFDictionary] ?? props?[kCGImagePropertyWebPDictionary]) as? [CFString: Any]
        let d = (dict?[kCGImagePropertyGIFUnclampedDelayTime] ?? dict?[kCGImagePropertyGIFDelayTime]
                 ?? dict?[kCGImagePropertyWebPUnclampedDelayTime] ?? dict?[kCGImagePropertyWebPDelayTime]) as? Double ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}

/// 显示一张表情包（会动 / 首帧），按比例塞进给定方盒
struct MemeImageView: View {
    let url: URL
    var maxPixel: Int = 384
    var animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: MemePlatformImage?

    private var plays: Bool { animated && !reduceMotion }

    var body: some View {
        Group {
            if let image {
                // 框贴着图的比例（不留透明边），外面 clipShape 的圆角才落在图的角上
                MemePlatformImageView(image: image)
                    .aspectRatio(image.size, contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: "\(url.path)#\(plays)") {
            image = await MemeImageLoader.load(url: url, maxPixel: maxPixel, animated: plays)
        }
    }
}

#if os(iOS)
private struct MemePlatformImageView: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        return v
    }
    func updateUIView(_ v: UIImageView, context: Context) {
        if v.image !== image { v.image = image }
    }
}
#else
private struct MemePlatformImageView: NSViewRepresentable {
    let image: NSImage
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image !== image { v.image = image }
    }
}
#endif

/// 消息里的表情包：无气泡无底，128pt 方盒；删了显示小灰字
struct MemeMessageView: View {
    let memeId: UUID
    @Query private var memes: [ChatMeme]

    static let side: CGFloat = 128

    init(memeId: UUID) {
        self.memeId = memeId
        _memes = Query(filter: #Predicate<ChatMeme> { $0.id == memeId })
    }

    @ViewBuilder var body: some View {
        if let meme = memes.first {
            MemeImageView(url: MemeStore.fileURL(meme.fileName, profileId: meme.profileId), animated: meme.isAnimated)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(width: Self.side, height: Self.side)
                .accessibilityLabel("表情包：\(meme.name)")
                .accessibilityIdentifier("meme-message")
        } else {
            Text("表情包已删除")
                .font(.system(size: 12))
                .foregroundColor(Theme.chat.textMuted)
                .padding(.vertical, 6)
        }
    }
}
