#if PERSONAL_APPS
#if os(iOS)
import Foundation
import CoreGraphics
import ImageIO

struct TutuWuPiece {
    let key: String
    let label: String
    let frame: CGRect
    let visible: Bool
    let z: Double
}

enum TutuWuError: Error {
    case resource(String)
    case metal(String)
    case viewport
}

struct TutuWuManifest: Decodable {
    struct Box: Decodable { let left: Double, top: Double, w: Double, h: Double, z: Double }
    struct Piece: Decodable { let key: String, label: String; let frame: Box; let visible: Bool }
    struct Paper: Decodable { let pile: [Float], ground: [Float], sheen: [Float], spec: [Float], glint: [Float]; let shin: Float }
    struct Candle: Decodable { let x: Double, y: Double, k: Double; let flames: [[Double]] }
    struct Raster: Decodable { let x: Double, y: Double, width: Double, height: Double }
    struct Output: Decodable { let file: String; let rasterFrame: Raster? }
    struct Mote: Decodable { let x: Double, y: Double, s: Double }
    let pieces: [Piece]
    let papers: [String: Paper]
    let candle: Candle
    let motes: [Mote]
    let outputs: [Output]
}

final class TutuWuAssets {
    let directory: URL
    let manifest: TutuWuManifest
    private(set) var images: [String: CGImage] = [:]
    var imageBytes: Int { images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height } }

    init(directory: URL) throws {
        self.directory = directory
        manifest = try JSONDecoder().decode(TutuWuManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    func image(_ name: String) throws -> CGImage {
        if let image = images[name] { return image }
        let url = directory.appendingPathComponent(name + ".png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw TutuWuError.resource(name)
        }
        images[name] = image
        return image
    }

    func releaseResources() { images.removeAll() }
}
#endif
#endif
