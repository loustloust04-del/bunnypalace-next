import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 卡原件（卡库 ⑧c-4，docs/decision-card-library-storage.md C）：原 PNG / 原 JSON envelope 字节。
/// 落盘后在 `cardlibrary/cards/<卡id>.<ext>`，`savedCharacterCards` blob 只存文件名 + 内容 sha256；
/// 新建 / 改过 / 老数据内嵌的先放内存（inline），CharacterCardManager 写 blob 前拆到文件。
/// 相等只看内容 sha：内嵌和已拆出的同一份原件算相等；缩略图 / 脚本数是派生的，不参与比较。
struct CardOriginals: Hashable {
    var inlineImage: Data?
    var inlineRawJSON: Data?
    var imageFile: String?
    var rawJSONFile: String?
    var imageSHA256: String?
    var rawJSONSHA256: String?
    /// ≤512px 封面缩略图（存在 blob 里，卡墙不读原件）
    var thumbnail: Data?
    /// 原 JSON 拆出时记下的脚本数
    var scriptCount: Int?
    /// 脚本数缓存的算法版本（第二批 B1：认键值对数组形态、新键优先、文件夹展开 → 2）。
    /// blob 里版本对不上（含旧数据没这个键）的缓存解码时丢掉，CharacterCardManager 启动时重算一次写回
    static let scriptCountVersion = 2
    /// 文件所在目录：不编码，管理器读出 / 落盘时填
    var directory: URL?

    static func == (a: Self, b: Self) -> Bool {
        a.imageSHA256 == b.imageSHA256 && a.rawJSONSHA256 == b.rawJSONSHA256
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(imageSHA256)
        hasher.combine(rawJSONSHA256)
    }

    var hasInline: Bool { inlineImage != nil || inlineRawJSON != nil }

    func read(_ file: String?) -> Data? {
        guard let file, let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(file))
    }
}

/// `cardlibrary/cards/` 目录：写原件（原子写 + 回读校验 sha）、清掉没人引用的文件
struct CardOriginalStore {
    let directory: URL

    /// 和 blobs/ 同级的 cardlibrary/cards/（生产：Application Support/MemoryPalace/cardlibrary/cards）
    static func directory(blobRoot: URL?, libraryRoot: URL?) -> URL {
        let library = libraryRoot
            ?? blobRoot.map { $0.deletingLastPathComponent().appendingPathComponent("cardlibrary", isDirectory: true) }
            ?? CardLibraryStorage.defaultRoot
        return library.appendingPathComponent("cards", isDirectory: true)
    }

    enum Failure: LocalizedError {
        case verifyFailed(String)
        var errorDescription: String? {
            switch self { case .verifyFailed(let file): "卡原件写入后回读不一致：\(file)" }
        }
    }

    /// 内嵌原件写成文件；写入并回读校验都成功才换成引用（失败抛错，调用方保持原样）
    func externalize(_ value: CardOriginals, id: String, scriptCount: Int) throws -> CardOriginals {
        var next = value
        let stem = Self.safeStem(id)
        if let image = value.inlineImage {
            let name = "\(stem).\(Self.imageExtension(image))"
            let sha = try write(image, name: name)
            next.inlineImage = nil
            next.imageFile = name
            next.imageSHA256 = sha
            if next.thumbnail == nil { next.thumbnail = CardImageThumbnail.make(from: image) }
        }
        if let raw = value.inlineRawJSON {
            let name = "\(stem).json"
            let sha = try write(raw, name: name)
            next.inlineRawJSON = nil
            next.rawJSONFile = name
            next.rawJSONSHA256 = sha
            next.scriptCount = scriptCount
        }
        next.directory = directory
        return next
    }

    private func write(_ data: Data, name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try CardLibraryStorage.writeAtomically(data, to: url)
        let sha = CardLibraryStorage.sha256(data)
        guard CardLibraryStorage.sha256(try Data(contentsOf: url)) == sha else { throw Failure.verifyFailed(name) }
        return sha
    }

    func exists(_ file: String?) -> Bool {
        file.map { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) } ?? true
    }

    /// blob 写成功后调：删掉不再被任何卡引用的原件（删卡 / 撤回 / 中断留下的）
    func removeUnreferenced(keeping cards: [CharacterCard]) {
        let referenced = Set(cards.flatMap { [$0.originals.imageFile, $0.originals.rawJSONFile].compactMap { $0 } })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where !name.hasPrefix(".") && !referenced.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func safeStem(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
    }

    static func imageExtension(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.count >= 12, head[0...3] == [0x52, 0x49, 0x46, 0x46], head[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        return "img"
    }
}

/// 封面 / 楼层头像缩略图（⑧c-4 B）：长边 ≤512px；真有透明像素存 PNG，否则 JPEG。ImageIO，iOS / macOS 一套
enum CardImageThumbnail {
    static let maxPixel = 512

    static func make(from data: Data?) -> Data? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, max(w, h)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let transparent = hasTransparentPixels(image)
        let out = NSMutableData()
        let type = transparent ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, transparent ? nil : [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// 带 alpha 通道的 PNG 大多其实全不透明：画进 RGBA 位图逐像素看
    private static func hasTransparentPixels(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
    }
}
