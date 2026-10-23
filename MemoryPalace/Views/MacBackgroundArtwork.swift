#if os(macOS)
import SwiftUI
import ImageIO

struct MacBackgroundArtwork: View {
    let url: URL
    @State private var image: CGImage?
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let image, loadedURL == url {
                Image(decorative: image, scale: 1).resizable()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let result = await MacBackgroundImageCache.shared.image(at: url)
            guard !Task.isCancelled else { return }
            image = result
            loadedURL = url
        }
    }
}

private actor MacBackgroundImageCache {
    static let shared = MacBackgroundImageCache()
    private struct Entry {
        let modified: Date?
        let fileSize: Int?
        let image: CGImage
        var used: Date
        var cost: Int { image.bytesPerRow * image.height }
    }
    private var entries: [URL: Entry] = [:]
    private let budget = 96 * 1024 * 1024

    func image(at url: URL) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let version = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if var entry = entries[url], entry.modified == version?.contentModificationDate, entry.fileSize == version?.fileSize {
            entry.used = Date()
            entries[url] = entry
            return entry.image
        }
        entries[url] = nil
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 6144,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        let entry = Entry(modified: version?.contentModificationDate, fileSize: version?.fileSize, image: image, used: Date())
        if entry.cost <= budget {
            while entries.values.reduce(0, { $0 + $1.cost }) + entry.cost > budget {
                guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { break }
                entries[oldest] = nil
            }
            entries[url] = entry
        }
        return image
    }
}
#endif
