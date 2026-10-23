#if os(iOS)
import SwiftUI
import UIKit

/// 书摘卡的底图（plan-reading-study-3 §2）：花园纹样（生成）/ 公版名画（入库 10 张）/ 自己导入的图。
enum QuoteBackdrop: Hashable {
    case garden(Int)
    case painting(Int)
    case mine(URL)

    /// 卡片上的小字图注；自己的图不写
    var credit: String? {
        switch self {
        case .garden(let i): "花园 · \(QuoteArt.names[i % QuoteArt.count])"
        case .painting(let i): QuotePaintings.all[i % QuotePaintings.all.count].credit
        case .mine: nil
        }
    }
}

/// 底图来源（设置里选，⧫ 粟粟 09-25：默认花园纹样）
enum QuoteArtSource: String, CaseIterable {
    case garden, paintings, mine, mixed
    var title: String {
        switch self {
        case .garden: "花园纹样"
        case .paintings: "名画"
        case .mine: "我的图片"
        case .mixed: "全部混着来"
        }
    }

    /// 这次进书摘页用的底图池（打乱过）。「我的图片」还没导入时退回花园纹样。
    func pool(profileId: String, salt: Int) -> [QuoteBackdrop] {
        let garden = (0..<QuoteArt.count).map(QuoteBackdrop.garden)
        let paintings = QuotePaintings.all.indices.map(QuoteBackdrop.painting)
        let mine = MyQuoteImages.list(profileId: profileId).map(QuoteBackdrop.mine)
        let base: [QuoteBackdrop] = switch self {
        case .garden: garden
        case .paintings: paintings
        case .mine: mine.isEmpty ? garden : mine
        case .mixed: garden + paintings + mine
        }
        var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: salt))
        return base.shuffled(using: &rng)
    }
}

/// 入库的公版名画（来源 / 授权见 docs/quote-art-sources.json、THIRD_PARTY_LICENSES.md）
enum QuotePaintings {
    struct Painting {
        let asset: String
        let artist: String
        let title: String
        let year: String
        var credit: String { "\(artist)《\(title)》\(year)" }
    }

    static let all: [Painting] = [
        .init(asset: "QuoteArt01", artist: "Odilon Redon", title: "Ophelia among the Flowers", year: "c.1905"),
        .init(asset: "QuoteArt02", artist: "William Morris", title: "Strawberry Thief", year: "1883"),
        .init(asset: "QuoteArt03", artist: "William Morris", title: "Willow Bough", year: "1887"),
        .init(asset: "QuoteArt04", artist: "Vincent van Gogh", title: "Almond Blossom", year: "1890"),
        .init(asset: "QuoteArt05", artist: "Claude Monet", title: "Water Lilies", year: "1916–19"),
        .init(asset: "QuoteArt06", artist: "Pierre-Joseph Redouté", title: "Rosa Kamtschatica", year: "1817–24"),
        .init(asset: "QuoteArt07", artist: "Maria Sibylla Merian", title: "Banana Flower and Fruit", year: "1705"),
        .init(asset: "QuoteArt08", artist: "Henri Fantin-Latour", title: "Still Life with Flowers and Fruit", year: "1866"),
        .init(asset: "QuoteArt09", artist: "Gustav Klimt", title: "Farm Garden with Sunflowers", year: "c.1907"),
        .init(asset: "QuoteArt10", artist: "葛饰北斋", title: "桔梗与蜻蜓", year: "c.1833"),
    ]
}

/// 铺满的底图。图片同步解码（有缓存），这样 ImageRenderer 导出时也能直接画出来。
struct QuoteBackdropView: View {
    let backdrop: QuoteBackdrop

    /// 图片铺满要先垫一层「不参与撑大」的空底再 overlay：直接 `scaledToFill` 的图会把外层
    /// `.frame(maxWidth: .infinity)` 撑得比屏幕还宽，连带展签一起被裁（⧫ 09-26 实机截图）
    var body: some View {
        Color.clear
            .overlay {
                switch backdrop {
                case .garden(let i):
                    QuoteArt(variant: i)
                case .painting(let i):
                    Image(QuotePaintings.all[i % QuotePaintings.all.count].asset)
                        .resizable()
                        .scaledToFill()
                case .mine(let url):
                    if let img = MyQuoteImages.image(at: url) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        // iCloud 还没下完：先用花园纹样顶着
                        QuoteArt(variant: StudyPaper.stableHash(url.lastPathComponent) % QuoteArt.count)
                    }
                }
            }
            .clipped()
    }
}

/// 自己导入的书摘底图：放在文件库目录的「书摘底图」里，跟着 iCloud 同步（⧫ 粟粟 09-25）
enum MyQuoteImages {
    static let folderName = "书摘底图"
    private static let cache = NSCache<NSURL, UIImage>()

    static func folder(profileId: String) -> URL {
        let dir = FileLibraryStore.libraryRoot(profileId: profileId).appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 已下载好的图（按导入时间排）；顺手给 iCloud 占位文件触发下载
    static func list(profileId: String) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder(profileId: profileId),
                                                 includingPropertiesForKeys: [.creationDateKey])) ?? []
        var ready: [(URL, Date)] = []
        for url in items {
            if url.lastPathComponent.hasSuffix(".icloud") {
                try? fm.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased()) else { continue }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            ready.append((url, date))
        }
        return ready.sorted { $0.1 < $1.1 }.map(\.0)
    }

    static func image(at url: URL) -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }

    /// 长边缩到 1600、JPEG 0.85 存进去
    static func add(_ image: UIImage, profileId: String) throws {
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
        let url = folder(profileId: profileId).appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
    }

    static func remove(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        try? FileManager.default.removeItem(at: url)
    }
}

/// 可复现的打乱（同一个 salt 同一种顺序，导出图片时和屏幕上一致）
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
#endif
