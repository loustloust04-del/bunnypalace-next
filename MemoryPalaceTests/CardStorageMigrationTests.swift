import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
@testable import 记忆花园

/// 卡库 ⑧c-4 存储搬家：三个大 key 迁进 BlobStore、楼层头像缩略图、卡原件拆文件。全部临时 suite / 临时目录，不碰 app 存储。
@MainActor
final class CardStorageMigrationTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("c4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "CardStorageMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private var blobs: URL { dir.appendingPathComponent("blobs") }
    private var library: URL { dir.appendingPathComponent("cardlibrary") }

    private func container() throws -> ModelContainer {
        let schema = Schema([Conversation.self, MessageNode.self, WorldBook.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    /// 合成图：opaque = 不透明 JPEG 判定；否则左上角透明
    private func png(width: Int, height: Int, opaque: Bool) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.6, green: 0.8, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !opaque { context.clear(CGRect(x: 0, y: 0, width: width / 4, height: height / 4)) }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func pixelSize(_ data: Data) -> (Int, Int, String) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int, CGImageSourceGetType(source)! as String)
    }

    private func cardJSON(_ name: String, scripts: Int = 0) -> Data {
        let helper: [String: Any] = ["scripts": (0..<scripts).map { ["id": "s\($0)"] }]
        return try! JSONSerialization.data(withJSONObject: ["spec": "chara_card_v2", "data": [
            "name": name, "first_mes": "你好", "extensions": ["tavern_helper": helper]]], options: [.sortedKeys])
    }

    // MARK: - A：三个 key 迁进 BlobStore

    func testThreeKeysMigrateIntoBlobsAndLegacyKeysAreRemoved() throws {
        let profiles = [Profile(id: "p1", name: "楼层一", emoji: "", description: "", userName: "你", assistantName: "助手")]
        let presets = [Preset(id: "t1", name: "模板")]
        let books = [GlobalWorldBook(id: "g1", name: "全局书")]
        let legacy: [String: Data] = ["savedProfiles": try JSONEncoder().encode(profiles),
                                      "savedPresets": try JSONEncoder().encode(presets),
                                      "globalWorldBooks": try JSONEncoder().encode(books)]
        for (key, data) in legacy { defaults.set(data, forKey: key) }

        XCTAssertEqual(ProfileManager.loadProfiles(root: blobs, defaults: defaults).map(\.id), ["p1"])
        XCTAssertNotNil(PresetManager(root: blobs, defaults: defaults).preset(byId: "t1"))
        XCTAssertEqual(GlobalWorldBookManager(root: blobs, defaults: defaults).books.map(\.id), ["g1"])
        for (key, data) in legacy {
            XCTAssertNil(defaults.object(forKey: key), "\(key) 旧 key 已删")
            XCTAssertEqual(try Data(contentsOf: blobs.appendingPathComponent(key)), data, "\(key) blob 与旧值逐字节一致")
        }
        // 再跑一次：空操作
        let before = try legacy.keys.map { try Data(contentsOf: blobs.appendingPathComponent($0)) }
        _ = ProfileManager.loadProfiles(root: blobs, defaults: defaults)
        _ = PresetManager(root: blobs, defaults: defaults)
        _ = GlobalWorldBookManager(root: blobs, defaults: defaults)
        XCTAssertEqual(try legacy.keys.map { try Data(contentsOf: blobs.appendingPathComponent($0)) }, before)
        // 写入走 blob，不回偏好
        let manager = PresetManager(root: blobs, defaults: defaults)
        try manager.persistNew(Preset(id: "t2", name: "新模板"))
        XCTAssertNil(defaults.object(forKey: "savedPresets"))
        XCTAssertNotNil(PresetManager(root: blobs, defaults: defaults).preset(byId: "t2"))
    }

    func testBlobWriteFailureKeepsLegacyKeyInUse() throws {
        let profiles = [Profile(id: "p1", name: "楼层一", emoji: "", description: "", userName: "你", assistantName: "助手")]
        let data = try JSONEncoder().encode(profiles)
        defaults.set(data, forKey: "savedProfiles")
        defaults.set(try JSONEncoder().encode([GlobalWorldBook(id: "g1", name: "书")]), forKey: "globalWorldBooks")
        // blobs 位置是普通文件：写 blob 必失败
        try Data("blocked".utf8).write(to: blobs)
        XCTAssertEqual(ProfileManager.loadProfiles(root: blobs, defaults: defaults).map(\.id), ["p1"], "照旧从偏好读")
        XCTAssertEqual(GlobalWorldBookManager(root: blobs, defaults: defaults).books.map(\.id), ["g1"])
        XCTAssertEqual(defaults.data(forKey: "savedProfiles"), data, "旧 key 原样保留")
        XCTAssertNotNil(defaults.data(forKey: "globalWorldBooks"))
        // 恢复可写后再读：迁移完成
        try FileManager.default.removeItem(at: blobs)
        XCTAssertEqual(ProfileManager.loadProfiles(root: blobs, defaults: defaults).map(\.id), ["p1"])
        XCTAssertNil(defaults.object(forKey: "savedProfiles"))
    }

    func testCorruptLegacyKeyIsNotMigratedAndBlocksWrites() throws {
        let corrupt = Data("损坏 JSON".utf8)
        defaults.set(corrupt, forKey: "savedPresets")
        let manager = PresetManager(root: blobs, defaults: defaults)
        XCTAssertThrowsError(try manager.persistNew(Preset(id: "x", name: "x")))
        XCTAssertEqual(defaults.data(forKey: "savedPresets"), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobs.appendingPathComponent("savedPresets").path))
    }

    func testStaleLegacyKeyNextToBlobIsCleared() throws {
        try BlobStore.set(try JSONEncoder().encode([GlobalWorldBook(id: "new", name: "新")]), forKey: "globalWorldBooks", root: blobs)
        defaults.set(try JSONEncoder().encode([GlobalWorldBook(id: "old", name: "旧")]), forKey: "globalWorldBooks")
        XCTAssertEqual(GlobalWorldBookManager(root: blobs, defaults: defaults).books.map(\.id), ["new"])
        XCTAssertNil(defaults.object(forKey: "globalWorldBooks"))
    }

    // MARK: - B：楼层头像缩略图

    func testFloorAvatarIsThumbnailAndKeepsTransparency() throws {
        let presets = PresetManager(root: blobs, defaults: defaults)
        var card = CharacterCard(from: try TavernCard.parseJSON(data: cardJSON("大图")))
        card.imageData = png(width: 1200, height: 1600, opaque: true)
        let floor = try CharacterFloorService.makeFloor(card: card, presets: presets).profile
        let (w, h, type) = pixelSize(try XCTUnwrap(floor.coverImageData))
        XCTAssertEqual(max(w, h), 512)
        XCTAssertEqual(type, UTType.jpeg.identifier)

        let thumb = try XCTUnwrap(CardImageThumbnail.make(from: png(width: 900, height: 600, opaque: false)))
        let (tw, _, ttype) = pixelSize(thumb)
        XCTAssertEqual(tw, 512)
        XCTAssertEqual(ttype, UTType.png.identifier, "有透明像素存 PNG")
        let small = try XCTUnwrap(CardImageThumbnail.make(from: png(width: 200, height: 100, opaque: true)))
        XCTAssertEqual(pixelSize(small).0, 200, "小图不放大")
    }

    // MARK: - C：卡原件拆文件

    func testLegacyInlineOriginalsAreSplitOnceAndStayEqual() throws {
        let image = png(width: 640, height: 960, opaque: true)
        var card = CharacterCard(from: try TavernCard.parseJSON(data: cardJSON("老卡", scripts: 2)))
        card.id = "legacy-card"
        card.imageData = image
        let raw = try XCTUnwrap(card.rawJSONData)
        // ⑧c-4 之前的 blob：原件内嵌、没有引用字段
        let legacyEncoder = JSONEncoder()
        legacyEncoder.userInfo[CharacterCard.legacyInlineEncoding] = true
        let legacyBlob = try legacyEncoder.encode([card])
        try BlobStore.set(legacyBlob, forKey: "savedCharacterCards", root: blobs)
        let legacyHash = ImportFingerprint.legacyCard(card)

        let manager = CharacterCardManager(root: blobs, libraryRoot: library, defaults: defaults)
        let loaded = try XCTUnwrap(manager.cards.first)
        let cards = library.appendingPathComponent("cards")
        XCTAssertEqual(try Data(contentsOf: cards.appendingPathComponent("legacy-card.png")), image)
        XCTAssertEqual(try Data(contentsOf: cards.appendingPathComponent("legacy-card.json")), raw)
        let blob = try Data(contentsOf: blobs.appendingPathComponent("savedCharacterCards"))
        let object = try XCTUnwrap((try JSONSerialization.jsonObject(with: blob) as? [[String: Any]])?.first)
        XCTAssertNil(object["imageData"])
        XCTAssertNil(object["rawJSONData"])
        XCTAssertEqual(object["imageFile"] as? String, "legacy-card.png")
        XCTAssertLessThan(blob.count, legacyBlob.count / 2)
        XCTAssertEqual(loaded, card, "内嵌和拆出的同一份原件相等")
        XCTAssertEqual(loaded.imageData, image)
        XCTAssertEqual(loaded.rawJSONData, raw)
        XCTAssertEqual(loaded.scriptCount, 2)
        XCTAssertNotNil(loaded.originals.thumbnail)
        XCTAssertLessThan(try XCTUnwrap(loaded.coverImageData).count, image.count)
        XCTAssertEqual(ImportFingerprint.legacyCard(loaded), legacyHash, "旧首次 hash 仍认得出没改过")
        XCTAssertTrue(manager.originalsPresent(loaded))

        // 再开一次：空操作
        _ = CharacterCardManager(root: blobs, libraryRoot: library, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: blobs.appendingPathComponent("savedCharacterCards")), blob)
        XCTAssertEqual(ImportFingerprint.of(CharacterCardManager(root: blobs, libraryRoot: library, defaults: defaults).cards[0]),
                       ImportFingerprint.of(loaded))
    }

    func testSplitFailureKeepsInlineBlobUntouched() throws {
        var card = CharacterCard(from: try TavernCard.parseJSON(data: cardJSON("老卡")))
        card.imageData = png(width: 64, height: 64, opaque: true)
        let encoder = JSONEncoder()
        encoder.userInfo[CharacterCard.legacyInlineEncoding] = true
        let legacyBlob = try encoder.encode([card])
        try BlobStore.set(legacyBlob, forKey: "savedCharacterCards", root: blobs)
        try Data("blocked".utf8).write(to: library)   // cardlibrary 是普通文件：原件写不进去
        let manager = CharacterCardManager(root: blobs, libraryRoot: library, defaults: defaults)
        XCTAssertEqual(manager.cards.first?.imageData, card.imageData, "照旧用内嵌原件")
        XCTAssertEqual(try Data(contentsOf: blobs.appendingPathComponent("savedCharacterCards")), legacyBlob, "blob 原样")
    }

    func testRemoveDeletesOriginalFilesAndOrphans() throws {
        let manager = CharacterCardManager(root: blobs, libraryRoot: library, defaults: defaults)
        var card = CharacterCard(from: try TavernCard.parseJSON(data: cardJSON("新卡")))
        card.imageData = png(width: 32, height: 32, opaque: true)
        try manager.add(card)
        let cards = library.appendingPathComponent("cards")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cards.path).sorted(), ["\(card.id).json", "\(card.id).png"])
        // 中断留下的孤儿原件（写了文件、blob 没写）下次写入时清掉
        try Data("orphan".utf8).write(to: cards.appendingPathComponent("ghost.png"))
        try manager.remove(ids: [card.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cards.path), [])
    }
}
