#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 消息下方的缩略图排（104 px、10 px 圆角，Wake DESIGN §对话阅读面）。顺序同源内容块，统一排在正文下面
/// （Wake 按 text_offset 插进正文中间，plan §2.5 的偏离）；放得下就平铺，放不下横向滚
struct CodingImageStrip: View {
    let images: [CodingImage]
    var onOpen: (CodingImage) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) { row }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            ForEach(images.indices, id: \.self) { i in
                CodingImageThumb(image: images[i])
                    .onTapGesture { onOpen(images[i]) }
            }
        }
    }
}

struct CodingImageThumb: View {
    let image: CodingImage
    @State private var thumbnail: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.5))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                    Text(image.formatLabel)
                        .font(.system(size: Theme.F.caption))
                }
                .foregroundColor(Theme.textMuted)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help("\(image.formatLabel) · \(CodingImageRender.byteLabel(image.data.count))")
        .task(id: image.data.count) {
            let data = image.data
            let box = await Task.detached(priority: .utility) { CodingImageRender.thumbnail(data, maxPixel: 208) }.value
            if let box {
                thumbnail = NSImage(cgImage: box.image, size: .zero)
            } else if let fallback = NSImage(data: data) {
                thumbnail = fallback
            } else {
                failed = true
            }
        }
    }
}

enum CodingImageRender {
    struct Box: @unchecked Sendable {
        let image: CGImage
    }

    /// ImageIO 缩略图（不解整张原图）；ImageIO 不认的格式（SVG）回 nil，交给 NSImage
    static func thumbnail(_ data: Data, maxPixel: Int) -> Box? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Box(image: image)
    }

    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    static func byteLabel(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

struct CodingImagePreviewItem: Identifiable {
    let id = UUID()
    let image: CodingImage
    let suggestedName: String
}

/// 暗色遮罩预览：按原始宽高比、绝不放大超过源尺寸；胶囊给格式 / 尺寸 / 大小 + 复制 / 存图 / 关闭（esc）；点遮罩关
struct CodingImagePreview: View {
    let item: CodingImagePreviewItem
    var onClose: () -> Void

    @State private var nsImage: NSImage?
    @State private var pixels: CGSize?
    @State private var loaded = false
    @State private var note: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            VStack(spacing: 14) {
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: nsImage.size.width, maxHeight: nsImage.size.height)
                } else if loaded {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 36))
                        Text("这个格式没法直接预览，可以存下来用别的 app 打开")
                            .font(.system(size: Theme.F.body))
                    }
                    .foregroundColor(.white.opacity(0.75))
                }
                capsule
                if let note {
                    Text(note)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            nsImage = NSImage(data: item.image.data)
            pixels = CodingImageRender.pixelSize(item.image.data)
            loaded = true
        }
    }

    private var info: String {
        var parts = [item.image.formatLabel]
        if let pixels { parts.append("\(Int(pixels.width))×\(Int(pixels.height))") }
        parts.append(CodingImageRender.byteLabel(item.image.data.count))
        return parts.joined(separator: " · ")
    }

    private var capsule: some View {
        HStack(spacing: 14) {
            Text(info)
                .foregroundColor(.white.opacity(0.8))
                .monospacedDigit()
            Button("复制", action: copy)
            Button("存图…") {
                note = CodingSessionLibrary.shared.saveImage(item.image, suggestedName: item.suggestedName)
            }
            Button("关闭", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .font(.system(size: Theme.F.caption, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.14)))
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let nsImage {
            pasteboard.writeObjects([nsImage])
        } else {
            let type = UTType(mimeType: item.image.mediaType)?.identifier ?? UTType.data.identifier
            pasteboard.setData(item.image.data, forType: NSPasteboard.PasteboardType(type))
        }
        note = "已复制"
    }
}
#endif
