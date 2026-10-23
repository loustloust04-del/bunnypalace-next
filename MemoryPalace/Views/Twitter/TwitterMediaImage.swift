import SwiftUI
import AVFoundation

/// 从磁盘读一张导入下来的图。存档不联网，所有图都在本地。
/// 解码放到后台，避免在 LazyVStack 滚动时同步解大图卡主线程。
/// 视频/动图（mp4）取第一帧当封面，叠一个播放标。
struct TwitterMediaImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    @State private var image: PlatformImage?
    @State private var failed = false

    private var isVideo: Bool { url?.pathExtension.lowercased() == "mp4" }

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                #else
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                #endif
            } else {
                Rectangle().fill(Theme.accent)
                    .overlay {
                        if failed {
                            Image(systemName: "photo").foregroundStyle(Theme.textMuted)
                        }
                    }
            }
        }
        .overlay {
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .allowsHitTesting(false)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { failed = true; return }
        let loaded: PlatformImage?
        if isVideo {
            loaded = await Self.posterFrame(of: url)
        } else {
            loaded = await Task.detached(priority: .utility) { () -> PlatformImage? in
                #if os(macOS)
                return NSImage(contentsOf: url)
                #else
                return UIImage(contentsOfFile: url.path)
                #endif
            }.value
        }
        image = loaded
        failed = loaded == nil
    }

    private static func posterFrame(of url: URL) async -> PlatformImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard let (cg, _) = try? await generator.image(at: .zero) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}
