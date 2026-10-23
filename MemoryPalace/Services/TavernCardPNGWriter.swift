import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import zlib

// MARK: - PNG chunk（卡库第二批 B7，研究 §4.4）

/// PNG 块的读与拼：4B 长度 + 4B 类型 + 数据 + 4B CRC（zlib crc32，覆盖类型 + 数据）。只按字节切，不解压、不碰像素
enum PNGChunks {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    struct Chunk {
        let type: String
        /// 整块在原数据里的字节范围（含长度、类型、CRC）
        let range: Range<Int>
        /// 块数据的范围
        let body: Range<Int>
    }

    /// 签名不对、块被截断、没有 IEND 都返回 nil
    static func parse(_ data: Data) -> [Chunk]? {
        let base = data.startIndex
        guard data.count > 8, data.prefix(8).elementsEqual(signature) else { return nil }
        var chunks: [Chunk] = []
        var offset = 8
        while offset + 12 <= data.count {
            let p = base + offset
            let length = Int(UInt32(data[p]) << 24 | UInt32(data[p + 1]) << 16 | UInt32(data[p + 2]) << 8 | UInt32(data[p + 3]))
            let end = offset + 12 + length
            guard length >= 0, end <= data.count else { return nil }
            let type = String(bytes: data[(p + 4)..<(p + 8)], encoding: .isoLatin1) ?? ""
            chunks.append(Chunk(type: type, range: offset..<end, body: (offset + 8)..<(end - 4)))
            offset = end
            if type == "IEND" { return chunks }
        }
        return nil
    }

    /// tEXt / iTXt / zTXt 的关键字（第一个 0 之前，Latin-1）；别的块 nil
    static func keyword(_ chunk: Chunk, in data: Data) -> String? {
        guard ["tEXt", "iTXt", "zTXt"].contains(chunk.type) else { return nil }
        let body = data[(data.startIndex + chunk.body.lowerBound)..<(data.startIndex + chunk.body.upperBound)]
        guard let zero = body.firstIndex(of: 0) else { return nil }
        return String(bytes: body[body.startIndex..<zero], encoding: .isoLatin1)
    }

    /// tEXt 的正文（关键字和 0 之后，Latin-1）
    static func text(_ chunk: Chunk, in data: Data) -> String? {
        guard chunk.type == "tEXt" else { return nil }
        let body = data[(data.startIndex + chunk.body.lowerBound)..<(data.startIndex + chunk.body.upperBound)]
        guard let zero = body.firstIndex(of: 0) else { return nil }
        return String(bytes: body[body.index(after: zero)...], encoding: .isoLatin1)
    }

    static func bytes(_ chunk: Chunk, in data: Data) -> Data {
        data[(data.startIndex + chunk.range.lowerBound)..<(data.startIndex + chunk.range.upperBound)]
    }

    static func encode(type: String, body: Data) -> Data {
        var out = Data(capacity: body.count + 12)
        let length = UInt32(body.count)
        out.append(contentsOf: [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        let typeBytes = Data(type.utf8)
        out.append(typeBytes)
        out.append(body)
        var crc = typeBytes.withUnsafeBytes { zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        crc = body.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        let c = UInt32(crc)
        out.append(contentsOf: [UInt8(c >> 24), UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)])
        return out
    }

    /// tEXt：关键字 + 0 + 正文（base64 只有 ASCII）
    static func textChunk(keyword: String, text: String) -> Data {
        encode(type: "tEXt", body: Data(keyword.utf8) + Data([0]) + Data(text.utf8))
    }
}

// MARK: - 写卡

/// 酒馆 PNG 卡写入（照 `ST/src/character-card-parser.js` write）：删掉旧的 chara / ccv3（tEXt / iTXt / zTXt，关键字不分大小写），
/// IEND 前依次插 `tEXt chara`（spec v2）和 `tEXt ccv3`（spec v3），都是 base64 的 UTF-8 JSON。IHDR / IDAT / 其余块字节不动
enum TavernCardPNGWriter {
    enum Failure: LocalizedError, Equatable {
        case invalidPNG, imageEncode, cancelled, verify(String)
        var errorDescription: String? {
            switch self {
            case .invalidPNG: "卡面图片不是有效的 PNG"
            case .imageEncode: "卡面图片转 PNG 失败"
            case .cancelled: "已取消"
            case .verify(let what): "导出后读回核对不一致：\(what)"
            }
        }
    }

    static let cardKeywords: Set<String> = ["chara", "ccv3"]
    /// 出图工具元数据（ComfyUI workflow / A1111 parameters）：改过之后导出剥掉
    static let generatorKeywords: Set<String> = ["workflow", "parameters"]

    /// chara / ccv3 两份 JSON：同一份内容，只改 spec
    static func cardJSON(_ envelope: [String: Any], v3: Bool) throws -> Data {
        var object = envelope
        object["spec"] = v3 ? "chara_card_v3" : "chara_card_v2"
        object["spec_version"] = v3 ? "3.0" : "2.0"
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func write(_ envelope: [String: Any], into png: Data, stripGeneratorMetadata: Bool,
                      checkpoint: () throws -> Void = {}) throws -> Data {
        guard let chunks = PNGChunks.parse(png), chunks.last?.type == "IEND" else { throw Failure.invalidPNG }
        let v2 = try cardJSON(envelope, v3: false).base64EncodedString()
        try checkpoint()
        let v3 = try cardJSON(envelope, v3: true).base64EncodedString()
        try checkpoint()
        var out = Data(capacity: png.count + v2.utf8.count + v3.utf8.count + 64)
        out.append(contentsOf: PNGChunks.signature)
        for chunk in chunks {
            if let keyword = PNGChunks.keyword(chunk, in: png)?.lowercased(),
               cardKeywords.contains(keyword) || (stripGeneratorMetadata && generatorKeywords.contains(keyword)) { continue }
            if chunk.type == "IEND" {
                out.append(PNGChunks.textChunk(keyword: "chara", text: v2))
                out.append(PNGChunks.textChunk(keyword: "ccv3", text: v3))
            }
            out.append(PNGChunks.bytes(chunk, in: png))
        }
        return out
    }

    /// 酒馆读法（`character-card-parser.js` read）：只看 tEXt，ccv3 优先、其次 chara，关键字不分大小写，取第一个
    static func tavernRead(_ png: Data) -> String? {
        guard let chunks = PNGChunks.parse(png) else { return nil }
        let texts = chunks.filter { $0.type == "tEXt" }
        for wanted in ["ccv3", "chara"] {
            if let chunk = texts.first(where: { PNGChunks.keyword($0, in: png)?.lowercased() == wanted }),
               let text = PNGChunks.text(chunk, in: png) {
                return Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
        return nil
    }

    /// 指定关键字的 tEXt 解出来的 JSON 对象（只给核对用）
    static func chunkObject(_ png: Data, keyword: String) -> [String: Any]? {
        guard let chunks = PNGChunks.parse(png),
              let chunk = chunks.first(where: { $0.type == "tEXt" && PNGChunks.keyword($0, in: png)?.lowercased() == keyword }),
              let text = PNGChunks.text(chunk, in: png), let json = Data(base64Encoded: text) else { return nil }
        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    }

    /// 写完立刻读回：自己的解析器（ccv3）、酒馆读法、chara 块各比一遍
    static func verify(_ png: Data, envelope: [String: Any]) throws {
        let v3 = try JSONSerialization.jsonObject(with: cardJSON(envelope, v3: true)) as? NSDictionary
        let v2 = try JSONSerialization.jsonObject(with: cardJSON(envelope, v3: false)) as? NSDictionary
        guard let ours = try? TavernCard.parsePNG(data: png).rawJSONData,
              let object = try? JSONSerialization.jsonObject(with: ours) as? NSDictionary, object == v3 else { throw Failure.verify("记忆花园读法") }
        guard let st = tavernRead(png).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }),
              st == v3 else { throw Failure.verify("酒馆读法") }
        guard let chara = chunkObject(png, keyword: "chara").map({ $0 as NSDictionary }), chara == v2 else { throw Failure.verify("chara 块") }
    }

    /// 任意图片（楼层封面 / 头像缩略图 JPEG 等）经 ImageIO 重新编成 PNG；已是 PNG 也重编（去掉里面的旧文字块）
    static func encodePNG(_ image: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return encodePNG(cg)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

// MARK: - 导出（三种情况 + 世界书 / 正则带不带）

/// 我们这边改过的世界书 / 正则（导出小票「带上」开关打开时覆盖进 envelope）；nil = 不覆盖
struct CardExportEdits {
    var characterBook: [String: Any]?
    var regexScripts: [[String: Any]]?
    /// 判断不清、按「不带」处理的说明（世界书对不上等）
    var notes: [String] = []

    var isEmpty: Bool { characterBook == nil && regexScripts == nil }
}

enum TavernCardExport {
    enum ImageSource: Equatable { case original, cover, generated }

    struct Output {
        let data: Data
        let source: ImageSource
        /// false = 原 PNG 字节直出（没改过）
        let rewritten: Bool
    }

    /// 卡的 envelope：没改过（exportJSON 回原字节、没有要带的改动）changed = false，对象就是原文；
    /// 改过 = exportJSON 的结果 + 世界书 / 正则覆盖 + 顶层 V1 镜像同步
    static func envelope(card: CharacterCard, edits: CardExportEdits?) throws -> (object: [String: Any], changed: Bool) {
        let base = try card.exportJSON()
        guard var object = try JSONSerialization.jsonObject(with: base) as? [String: Any] else { throw TavernCardError.invalidJSON }
        let edits = edits.flatMap { $0.isEmpty ? nil : $0 }
        let changed = card.rawJSONData.map { $0 != base } ?? true || edits != nil
        guard changed else { return (object, false) }
        var data = object["data"] as? [String: Any] ?? [:]
        if let book = edits?.characterBook { data["character_book"] = book }
        if let regex = edits?.regexScripts {
            var extensions = data["extensions"] as? [String: Any] ?? [:]
            extensions["regex_scripts"] = regex
            data["extensions"] = extensions
        }
        object["data"] = data
        syncMirror(&object)
        return (object, true)
    }

    /// 顶层 V1 镜像跟 data.* 走（照 `ST/src/endpoints/characters.js` charaFormatData）
    static func syncMirror(_ object: inout [String: Any]) {
        let data = object["data"] as? [String: Any] ?? [:]
        for key in ["name", "description", "personality", "scenario", "first_mes", "mes_example"] {
            if let value = data[key] as? String { object[key] = value }
        }
        if let notes = data["creator_notes"] as? String { object["creatorcomment"] = notes }
        if let tags = data["tags"] as? [Any] { object["tags"] = tags }
        let extensions = data["extensions"] as? [String: Any] ?? [:]
        object["talkativeness"] = extensions["talkativeness"] ?? object["talkativeness"] ?? 0.5
    }

    /// 导出 JSON：没改过 = 原字节；改过 = 同一份 envelope（spec 保持原样）
    static func json(card: CharacterCard, edits: CardExportEdits?) throws -> Data {
        let (object, changed) = try envelope(card: card, edits: edits)
        guard changed else { return try card.exportJSON() }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// 导出 PNG。`original`：卡库卡的原 PNG（楼层卡 / JSON 卡传 nil）；`cover`：楼层封面或头像，没原图时用；都没有生成默认卡面
    static func png(card: CharacterCard, original: Data?, cover: Data?, edits: CardExportEdits?,
                    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> Output {
        func step(_ value: Double) throws {
            if isCancelled() { throw TavernCardPNGWriter.Failure.cancelled }
            progress(value)
        }
        try step(0.05)
        let (object, changed) = try envelope(card: card, edits: edits)
        try step(0.25)
        let originalIsPNG = original.map { PNGChunks.parse($0) != nil } ?? false
        // ① 没改过、原图还是落盘时那份、原图里的卡就是原文：原字节直出
        if !changed, let original, originalIsPNG,
           card.originals.imageSHA256.map({ $0 == CardLibraryStorage.sha256(original) }) ?? true,
           let embedded = TavernCardPNGWriter.tavernRead(original).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? NSDictionary }),
           embedded == object as NSDictionary {
            try step(1)
            return Output(data: original, source: .original, rewritten: false)
        }
        // ② 有原图：在原图上换块；③ 没原图：楼层封面 / 头像重编，都没有就画默认卡面
        let base: Data, source: ImageSource
        if let original, originalIsPNG {
            base = original; source = .original
        } else if let original, let encoded = TavernCardPNGWriter.encodePNG(original) {
            base = encoded; source = .original
        } else if let cover {
            guard let encoded = TavernCardPNGWriter.encodePNG(cover) else { throw TavernCardPNGWriter.Failure.imageEncode }
            base = encoded; source = .cover
        } else {
            let name = (object["data"] as? [String: Any])?["name"] as? String ?? card.name
            guard let face = CardDefaultFace.png(name: name) else { throw TavernCardPNGWriter.Failure.imageEncode }
            base = face; source = .generated
        }
        try step(0.4)
        let out = try TavernCardPNGWriter.write(object, into: base, stripGeneratorMetadata: changed && source == .original,
                                                checkpoint: { try step(0.6) })
        try step(0.8)
        try TavernCardPNGWriter.verify(out, envelope: object)
        try step(1)
        return Output(data: out, source: source, rewritten: true)
    }
}

// MARK: - 我们这边的世界书 / 正则 → 导出覆盖

enum CardExportEditsResolver {
    /// 楼层里的一本书（SwiftData 模型在主线程取成值再交过来）
    struct FloorBook {
        let name: String
        let entries: [WorldBookEntry]
        let rawJSONData: Data?
    }

    /// 世界书：这张卡绑的楼层里、原文和卡里 character_book 同源（rawJSONData 相同）的那一本，正好一本才认；
    /// 对不上（找不到 / 多本）记 note 按不带处理。没改过（overlay 回原文）不覆盖。正则：卡上的规则和原文比，改过才覆盖
    static func make(card: CharacterCard, floorBooks: [FloorBook]?) -> CardExportEdits {
        var edits = CardExportEdits()
        let raw = card.rawJSONData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if card.hasWorldBook, let floorBooks, let report = try? card.decodeWorldBook() {
            let same = floorBooks.filter { $0.rawJSONData == report.rawJSONData }
            if same.count == 1, let book = same.first {
                if let encoded = try? WorldBookCodec.encodeExport(name: book.name, entries: book.entries, rawJSONData: report.rawJSONData),
                   encoded != report.rawJSONData,
                   let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                    edits.characterBook = object
                }
            } else {
                edits.notes.append(same.isEmpty ? "楼层里找不到这张卡带进来的那本世界书，世界书按卡里原来的导出"
                                                : "楼层里有 \(same.count) 本和卡里同源的世界书，分不清是哪本，世界书按卡里原来的导出")
            }
        }
        let data = raw?["data"] as? [String: Any] ?? raw ?? [:]
        let original = (data["extensions"] as? [String: Any])?["regex_scripts"] as? [[String: Any]]
            ?? (raw?["extensions"] as? [String: Any])?["regex_scripts"] as? [[String: Any]] ?? []
        edits.regexScripts = regexOverlay(card.regexScripts, original: original)
        return edits
    }

    /// 正则只覆盖受支持字段：原文里有 id 的按 id 对，没 id 的按位置对（导入时 id 是现编的）；未知字段原样留，删掉的不写，新的全写。
    /// 和原文一样返回 nil
    static func regexOverlay(_ scripts: [RegexScript], original: [[String: Any]]) -> [[String: Any]]? {
        let parsed = original.map(RegexScript.init(from:))
        var used = Set<Int>()
        let matches: [Int?] = scripts.enumerated().map { index, script in
            let byId = original.indices.first { !used.contains($0) && (original[$0]["id"] as? String) == script.id }
            let byPosition = index < original.count && original[index]["id"] == nil && !used.contains(index) ? index : nil
            let match = byId ?? byPosition
            if let match { used.insert(match) }
            return match
        }
        func same(_ a: RegexScript, _ b: RegexScript) -> Bool { var a = a; a.id = b.id; return a == b }
        if scripts.count == original.count,
           scripts.indices.allSatisfy({ matches[$0] == $0 && same(scripts[$0], parsed[$0]) }) { return nil }
        return scripts.indices.map { index in
            let script = scripts[index]
            var dict = matches[index].map { original[$0] } ?? [:]
            let base = matches[index].map { parsed[$0] }
            func put<T: Equatable>(_ key: String, _ path: KeyPath<RegexScript, T>, _ value: Any) {
                if base.map({ $0[keyPath: path] != script[keyPath: path] }) ?? true { dict[key] = value }
            }
            if base == nil { dict["id"] = script.id }
            put("scriptName", \.scriptName, script.scriptName)
            put("findRegex", \.findRegex, script.findRegex)
            put("replaceString", \.replaceString, script.replaceString)
            put("trimStrings", \.trimStrings, script.trimStrings)
            put("placement", \.placement, script.placement)
            put("disabled", \.disabled, script.disabled)
            put("markdownOnly", \.markdownOnly, script.markdownOnly)
            put("promptOnly", \.promptOnly, script.promptOnly)
            put("runOnEdit", \.runOnEdit, script.runOnEdit)
            put("substituteRegex", \.substituteRegex, script.substituteRegex)
            put("minDepth", \.minDepth, script.minDepth.map { $0 as Any } ?? NSNull())
            put("maxDepth", \.maxDepth, script.maxDepth.map { $0 as Any } ?? NSNull())
            return dict
        }
    }
}

// MARK: - 默认卡面

/// 没有原图也没有楼层封面时的卡面：512×768，花园开屏页的语言——纸色渐变底、大小交替的珠串拱门、点点拼的花、点点金星，中间写名字。
/// 同一个名字画出来一样（按名字定随机种子）
enum CardDefaultFace {
    static let size = CGSize(width: 512, height: 768)

    static func png(name: String) -> Data? { image(name: name).flatMap(TavernCardPNGWriter.encodePNG) }

    static func image(name: String) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // 以左上为原点画（文字另外翻回来）
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        var rng = Seeded(name)

        let sky = [color(0xE4EDE7), color(0xF4F1E6), color(0xE9EFE2)]
        if let gradient = CGGradient(colorsSpace: space, colors: sky as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }

        // 珠串拱门：大小珠交替
        let bead = color(0x3A4A41, alpha: 0.62)
        let center = CGPoint(x: 256, y: 420), rx: CGFloat = 166, ry: CGFloat = 250
        let legBottom: CGFloat = 610
        var points: [CGPoint] = []
        var y = legBottom
        while y > center.y { points.append(CGPoint(x: center.x - rx, y: y)); y -= 12 }
        let steps = 44
        for i in 0...steps {
            let t = CGFloat.pi + CGFloat.pi * CGFloat(i) / CGFloat(steps)
            points.append(CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t)))
        }
        y = center.y + 12
        while y <= legBottom { points.append(CGPoint(x: center.x + rx, y: y)); y += 12 }
        for (i, p) in points.enumerated() { dot(ctx, p, i % 2 == 0 ? 3.4 : 2.0, bead) }

        // 地面一行细点
        var x: CGFloat = 40
        while x < 472 { dot(ctx, CGPoint(x: x, y: 640), 1.3, color(0x6F9A80, alpha: 0.45)); x += 9 }

        // 点点花：茎是点串，花头是一颗颗小圆点
        let petals = [0xD99AA5, 0xE3A9B0, 0xC98F9E, 0xB3A2CC, 0xD9A07F, 0x7FA58D]
        let stems = [62, 118, 176, 336, 394, 452] as [CGFloat]
        for (i, sx) in stems.enumerated() {
            let top = 540 + rng.next() * 70
            var sy: CGFloat = 642
            while sy > top { dot(ctx, CGPoint(x: sx, y: sy), 1.5, color(0x6F9A80, alpha: 0.85)); sy -= 6 }
            let hue = color(petals[(i + Int(rng.next() * 6)) % petals.count])
            let head = CGPoint(x: sx, y: top - 12)
            switch i % 3 {
            case 0: pompom(ctx, head, hue)
            case 1: clover(ctx, head, hue)
            default: bell(ctx, head, hue)
            }
        }

        // 右上点点金星
        star(ctx, CGPoint(x: 444, y: 74), scale: 2.2, color(0xB8954C))
        star(ctx, CGPoint(x: 82, y: 118), scale: 1.1, color(0xB8954C, alpha: 0.7))

        // 名字（衬线、字距拉开）+ 一行小字
        drawText(ctx, name, size: fitSize(name), kern: 10, color: color(0x34403A), centerY: 372, family: "Songti SC")
        drawText(ctx, "记忆花园 · 角色卡", size: 15, kern: 4, color: color(0x9AA39C), centerY: 448, family: "PingFang SC")
        return ctx.makeImage()
    }

    private static func fitSize(_ name: String) -> CGFloat {
        let count = max(1, name.count)
        return min(56, max(24, 300 / CGFloat(count)))
    }

    private static func color(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func dot(_ ctx: CGContext, _ p: CGPoint, _ r: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    private static func ring(_ ctx: CGContext, _ c: CGPoint, radius: CGFloat, count: Int, r: CGFloat, _ color: CGColor, phase: CGFloat = 0) {
        for i in 0..<count {
            let t = phase + 2 * .pi * CGFloat(i) / CGFloat(count)
            dot(ctx, CGPoint(x: c.x + radius * cos(t), y: c.y + radius * sin(t)), r, color)
        }
    }

    /// 花头放大一点，和 512×768 的卡面相称
    private static let bloom: CGFloat = 1.45

    /// 绒球：中心一颗 + 两圈
    private static func pompom(_ ctx: CGContext, _ c: CGPoint, _ color: CGColor) {
        let k = bloom
        dot(ctx, c, 3 * k, color)
        ring(ctx, c, radius: 7 * k, count: 7, r: 2.5 * k, color)
        ring(ctx, c, radius: 13 * k, count: 12, r: 1.9 * k, color, phase: 0.2)
    }

    /// 四叶：四个小圈
    private static func clover(_ ctx: CGContext, _ c: CGPoint, _ color: CGColor) {
        let k = bloom
        for (dx, dy) in [(0, -8), (8, 0), (0, 8), (-8, 0)] as [(CGFloat, CGFloat)] {
            let lobe = CGPoint(x: c.x + dx * k, y: c.y + dy * k)
            dot(ctx, lobe, 2.2 * k, color)
            ring(ctx, lobe, radius: 4.6 * k, count: 6, r: 1.5 * k, color)
        }
    }

    /// 铃铛：一排排往下变宽的点
    private static func bell(_ ctx: CGContext, _ c: CGPoint, _ color: CGColor) {
        let k = bloom
        for row in 0..<4 {
            let n = row + 2, width = (CGFloat(row) * 5 + 6) * k
            for i in 0..<n {
                let x = c.x - width / 2 + width * CGFloat(i) / CGFloat(max(1, n - 1))
                dot(ctx, CGPoint(x: x, y: c.y + (CGFloat(row) * 5.5 - 10) * k), (row == 3 ? 1.6 : 2.2) * k, color)
            }
        }
    }

    /// 四角星：中心 + 四个方向由大到小的点
    private static func star(_ ctx: CGContext, _ c: CGPoint, scale s: CGFloat, _ color: CGColor) {
        dot(ctx, c, 1.6 * s, color)
        for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] as [(CGFloat, CGFloat)] {
            for (d, r) in [(3.4, 1.1), (6.2, 0.8), (8.4, 0.55)] as [(CGFloat, CGFloat)] {
                dot(ctx, CGPoint(x: c.x + dx * d * s, y: c.y + dy * d * s), r * s, color)
            }
        }
    }

    private static func drawText(_ ctx: CGContext, _ text: String, size: CGFloat, kern: CGFloat, color: CGColor, centerY: CGFloat, family: String) {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color, kCTKernAttributeName: kern]
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetImageBounds(line, ctx)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) - Double(kern)
        ctx.saveGState()
        // 这里是翻过来的坐标：文字要再翻一次才正
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: (self.size.width - CGFloat(width)) / 2, y: centerY + bounds.height / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 名字定种子的小随机数（FNV-1a + xorshift），跨启动稳定
    private struct Seeded {
        var state: UInt64
        init(_ text: String) {
            var h: UInt64 = 0xCBF29CE484222325
            for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001B3 }
            state = h == 0 ? 1 : h
        }
        mutating func next() -> CGFloat {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return CGFloat(state % 10_000) / 10_000
        }
    }
}
