import XCTest
import ImageIO
@testable import 记忆花园

/// 卡库第二批 B7：PNG 导出三种情况、顶层镜像、删块（tEXt / iTXt / zTXt、大小写）、剥出图元数据、读回双校验、
/// 世界书 / 正则带不带、许可不进卡、解析器关键字大小写。全部临时目录 / 临时 suite，不碰 app 存储
@MainActor
final class CardPNGExportTests: XCTestCase {
    private var dir: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("b7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "CardPNGExportTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 夹具

    private func envelope(name: String = "岚", book: Bool = false, regex: [[String: Any]] = []) -> [String: Any] {
        var data: [String: Any] = [
            "name": name, "description": "旧描述", "personality": "安静", "scenario": "河边", "first_mes": "你来了。",
            "mes_example": "", "creator_notes": "作者的话", "system_prompt": "", "post_history_instructions": "",
            "tags": ["测试"], "creator": "小满", "character_version": "1.2", "alternate_greetings": ["又来了。"],
            "extensions": ["talkativeness": "0.7", "fav": false, "tavern_helper": ["variables": ["k": 1]], "regex_scripts": regex] as [String: Any],
        ]
        if book {
            data["character_book"] = ["name": "岚的书", "extensions": ["x": 1], "entries": [
                ["id": 0, "keys": ["河"], "content": "河很长", "enabled": true, "insertion_order": 100, "extensions": ["position": 0], "unknown": "留着"],
                ["id": 1, "keys": ["石"], "content": "石很白", "enabled": true, "insertion_order": 90],
            ]] as [String: Any]
        }
        return ["spec": "chara_card_v3", "spec_version": "3.0", "name": name, "description": "旧描述", "personality": "安静",
                "scenario": "河边", "first_mes": "你来了。", "mes_example": "", "creatorcomment": "作者的话", "tags": ["测试"],
                "talkativeness": "0.5", "fav": false, "create_date": "2026-1-1", "data": data]
    }

    private func pixelsPNG(width: Int = 24, height: Int = 36) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 3, y: 5, width: 7, height: 9))
        return TavernCardPNGWriter.encodePNG(ctx.makeImage()!)!
    }

    private func b64(_ object: [String: Any]) -> String {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).base64EncodedString()
    }

    private func iTXt(_ keyword: String, _ text: String) -> Data {
        PNGChunks.encode(type: "iTXt", body: Data(keyword.utf8) + Data([0, 0, 0, 0, 0]) + Data(text.utf8))
    }

    private func zTXt(_ keyword: String) -> Data {
        PNGChunks.encode(type: "zTXt", body: Data(keyword.utf8) + Data([0, 0]) + Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))
    }

    /// 在 IHDR 后、IEND 前各塞一些块
    private func assemble(_ png: Data, afterHeader: [Data] = [], beforeEnd: [Data]) -> Data {
        let chunks = PNGChunks.parse(png)!
        var out = Data(PNGChunks.signature)
        for chunk in chunks {
            if chunk.type == "IEND" { beforeEnd.forEach { out.append($0) } }
            out.append(PNGChunks.bytes(chunk, in: png))
            if chunk.type == "IHDR" { afterHeader.forEach { out.append($0) } }
        }
        return out
    }

    /// 酒馆导出的卡：tEXt chara（v2）+ tEXt ccv3，带 ComfyUI workflow 和 A1111 parameters
    private func tavernPNG(_ env: [String: Any], extra: [Data] = []) -> Data {
        var v2 = env; v2["spec"] = "chara_card_v2"; v2["spec_version"] = "2.0"
        return assemble(pixelsPNG(), afterHeader: [PNGChunks.textChunk(keyword: "workflow", text: "{\"nodes\":[]}")],
                        beforeEnd: extra + [iTXt("parameters", "steps: 20"),
                                            PNGChunks.textChunk(keyword: "chara", text: b64(v2)),
                                            PNGChunks.textChunk(keyword: "ccv3", text: b64(env))])
    }

    private func imported(_ png: Data) throws -> CharacterCard {
        let manager = CharacterCardManager(root: dir.appendingPathComponent("blobs"), libraryRoot: dir.appendingPathComponent("cardlibrary"), defaults: defaults)
        try manager.add(CharacterCard(from: TavernCard.parsePNG(data: png)))
        // 重开一次：原件已拆到文件，按需读
        return try XCTUnwrap(CharacterCardManager(root: dir.appendingPathComponent("blobs"), libraryRoot: dir.appendingPathComponent("cardlibrary"),
                                                  defaults: defaults).cards.last)
    }

    private func types(_ png: Data) -> [String] { PNGChunks.parse(png)!.map(\.type) }
    private func keywords(_ png: Data) -> [String] { PNGChunks.parse(png)!.compactMap { PNGChunks.keyword($0, in: png) } }
    private func nonText(_ png: Data) -> [Data] {
        PNGChunks.parse(png)!.filter { !["tEXt", "iTXt", "zTXt"].contains($0.type) }.map { PNGChunks.bytes($0, in: png) }
    }
    private func ccv3(_ png: Data) -> [String: Any]? { TavernCardPNGWriter.chunkObject(png, keyword: "ccv3") }

    // MARK: - ① 没改过：原字节

    func testUnchangedCardExportsOriginalBytes() throws {
        let png = tavernPNG(envelope())
        let card = try imported(png)
        XCTAssertNil(card.originals.inlineImage, "原 PNG 已拆到文件")
        let out = try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil)
        XCTAssertFalse(out.rewritten)
        XCTAssertEqual(out.source, .original)
        XCTAssertEqual(out.data, png, "逐字节相等（出图元数据也原样）")
        XCTAssertEqual(try TavernCardExport.json(card: card, edits: nil), card.rawJSONData, "JSON 也是原字节")
        XCTAssertEqual(try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: CardExportEdits()).data, png,
                       "空改动（开关开着但没有可带的）= 没改过")
    }

    func testUnchangedButOriginalPNGLostCardFallsBackToRewrite() throws {
        let card = try imported(tavernPNG(envelope()))
        let other = pixelsPNG(width: 10, height: 10)
        let out = try TavernCardExport.png(card: card, original: other, cover: nil, edits: nil)
        XCTAssertTrue(out.rewritten, "原图不是那份（sha 对不上）：照常写块")
        XCTAssertEqual(ccv3(out.data) as NSDictionary?, envelope() as NSDictionary, "没改过的 envelope 原样写进去")
    }

    // MARK: - ② 改过有原图

    func testEditedCardRewritesOnlyCardChunksBeforeIEND() throws {
        let png = tavernPNG(envelope())
        var card = try imported(png)
        card.description = "新描述"
        let out = try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil)
        XCTAssertTrue(out.rewritten)
        XCTAssertEqual(nonText(out.data), nonText(png), "IHDR / IDAT / IEND 字节不动")
        XCTAssertEqual(Array(types(out.data).suffix(3)), ["tEXt", "tEXt", "IEND"])
        XCTAssertEqual(Array(keywords(out.data).suffix(2)), ["chara", "ccv3"], "chara 在前、ccv3 在后，都在 IEND 前")
        let v3 = try XCTUnwrap(ccv3(out.data)), v2 = try XCTUnwrap(TavernCardPNGWriter.chunkObject(out.data, keyword: "chara"))
        XCTAssertEqual(v3["spec"] as? String, "chara_card_v3"); XCTAssertEqual(v3["spec_version"] as? String, "3.0")
        XCTAssertEqual(v2["spec"] as? String, "chara_card_v2"); XCTAssertEqual(v2["spec_version"] as? String, "2.0")
        XCTAssertEqual((v3["data"] as? [String: Any])?["description"] as? String, "新描述")
        var a = v3, b = v2
        for key in ["spec", "spec_version"] { a.removeValue(forKey: key); b.removeValue(forKey: key) }
        XCTAssertEqual(a as NSDictionary, b as NSDictionary, "两块去掉 spec 后内容相同")
        let ext = (v3["data"] as? [String: Any])?["extensions"] as? [String: Any]
        XCTAssertEqual((ext?["tavern_helper"] as? [String: Any])?["variables"] as? [String: Int], ["k": 1], "未知子树原样留")
        XCTAssertEqual(v3["create_date"] as? String, "2026-1-1", "顶层其他字段原样留")
    }

    func testCRCMatchesZlib() {
        // IEND 的 CRC 是固定值 AE426082
        XCTAssertEqual(PNGChunks.encode(type: "IEND", body: Data()), Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]))
    }

    func testMirrorFieldsFollowData() throws {
        var card = try imported(tavernPNG(envelope()))
        card.name = "岚二"
        card.description = "新描述"
        card.personality = "话多"
        card.scenario = "雨里"
        card.firstMes = "喂。"
        card.mesExample = "<START>"
        card.creatorNotes = "新的话"
        card.tags = ["a", "b"]
        let object = try XCTUnwrap(ccv3(TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil).data))
        XCTAssertEqual(object["name"] as? String, "岚二")
        XCTAssertEqual(object["description"] as? String, "新描述")
        XCTAssertEqual(object["personality"] as? String, "话多")
        XCTAssertEqual(object["scenario"] as? String, "雨里")
        XCTAssertEqual(object["first_mes"] as? String, "喂。")
        XCTAssertEqual(object["mes_example"] as? String, "<START>")
        XCTAssertEqual(object["creatorcomment"] as? String, "新的话")
        XCTAssertEqual(object["tags"] as? [String], ["a", "b"])
        XCTAssertEqual(object["talkativeness"] as? String, "0.7", "talkativeness 跟 data.extensions 走")
        XCTAssertEqual(object["fav"] as? Bool, false, "别的顶层字段不动")
        // JSON 导出同一份镜像
        let json = try JSONSerialization.jsonObject(with: TavernCardExport.json(card: card, edits: nil)) as? [String: Any]
        XCTAssertEqual(json?["name"] as? String, "岚二")
        XCTAssertEqual(json?["spec"] as? String, "chara_card_v3", "JSON 导出 spec 保持原样")
    }

    func testDeletesOldCardChunksOfAllTextTypesCaseInsensitive() throws {
        let env = envelope()
        let png = tavernPNG(env, extra: [PNGChunks.textChunk(keyword: "Chara", text: b64(env)), iTXt("CCV3", b64(env)), zTXt("chara"),
                                         PNGChunks.textChunk(keyword: "Comment", text: "留着")])
        let out = try TavernCardPNGWriter.write(env, into: png, stripGeneratorMetadata: false)
        let cardKeys = keywords(out).filter { ["chara", "ccv3"].contains($0.lowercased()) }
        XCTAssertEqual(cardKeys, ["chara", "ccv3"], "旧的 tEXt / iTXt / zTXt 卡块（不分大小写）全删，只剩新写的两块")
        XCTAssertTrue(keywords(out).contains("Comment"), "别的文字块留着")
        XCTAssertTrue(keywords(out).contains("workflow") && keywords(out).contains("parameters"), "不剥时出图元数据留着")
    }

    func testStripsGeneratorMetadataOnlyWhenEdited() throws {
        let png = tavernPNG(envelope(), extra: [PNGChunks.textChunk(keyword: "Workflow", text: "x"), iTXt("PARAMETERS", "y")])
        var card = try imported(png)
        XCTAssertEqual(try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil).data, png, "没改过原样带出")
        card.scenario = "改了"
        let out = try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil).data
        XCTAssertFalse(keywords(out).contains { ["workflow", "parameters"].contains($0.lowercased()) }, "改过：workflow / parameters（不分大小写）剥掉")
        XCTAssertEqual(nonText(out), nonText(png), "像素块不动")
    }

    // MARK: - ③ 没原图

    func testNoOriginalUsesCoverReencodedAsPNG() throws {
        var profile = Profile(name: "楼层岚", emoji: "🎭", description: "", userName: "你", assistantName: "岚", systemPrompt: "系统")
        let jpeg = NSMutableData()
        let dest = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(pixelsPNG(width: 40, height: 60) as CFData, nil)!, 0, nil)!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        profile.coverImageData = jpeg as Data
        let card = CharacterCard(profile: profile)
        let out = try TavernCardExport.png(card: card, original: nil, cover: profile.coverImageData, edits: nil)
        XCTAssertEqual(out.source, .cover)
        XCTAssertTrue(out.rewritten)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(out.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 40)
        let object = try XCTUnwrap(ccv3(out.data))
        XCTAssertEqual(object["name"] as? String, "楼层岚", "楼层卡：顶层镜像也写上")
        XCTAssertEqual((object["data"] as? [String: Any])?["system_prompt"] as? String, "系统")
        XCTAssertEqual(try TavernCard.parsePNG(data: out.data).name, "楼层岚")
    }

    func testNoImageAtAllDrawsDefaultFace() throws {
        let card = CharacterCard(from: try TavernCard.parseJSON(data: JSONSerialization.data(withJSONObject: envelope(name: "白石"))))
        let out = try TavernCardExport.png(card: card, original: nil, cover: nil, edits: nil)
        XCTAssertEqual(out.source, .generated)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(out.data as CFData, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 768)
        XCTAssertEqual(CardDefaultFace.png(name: "白石"), CardDefaultFace.png(name: "白石"), "同名卡面稳定")
        XCTAssertNotEqual(CardDefaultFace.png(name: "白石"), CardDefaultFace.png(name: "岚"))
        XCTAssertEqual(ccv3(out.data) as NSDictionary?, envelope(name: "白石") as NSDictionary, "JSON 卡没改过：envelope 原样写进新卡面")
    }

    // MARK: - 读回双校验

    func testVerifyCatchesMismatchAndTavernReaderRules() throws {
        let env = envelope()
        let out = try TavernCardPNGWriter.write(env, into: pixelsPNG(), stripGeneratorMetadata: false)
        XCTAssertNoThrow(try TavernCardPNGWriter.verify(out, envelope: env))
        XCTAssertThrowsError(try TavernCardPNGWriter.verify(out, envelope: envelope(name: "别人")))
        // 酒馆只读 tEXt：只有 iTXt 的卡它读不到，我们的解析器读得到
        let itxtOnly = assemble(pixelsPNG(), beforeEnd: [iTXt("ccv3", b64(env))])
        XCTAssertNil(TavernCardPNGWriter.tavernRead(itxtOnly))
        XCTAssertEqual(try TavernCard.parsePNG(data: itxtOnly).name, "岚")
        // ccv3 优先于 chara
        var v2 = env; v2["data"] = ["name": "旧名"]
        let both = assemble(pixelsPNG(), beforeEnd: [PNGChunks.textChunk(keyword: "chara", text: b64(v2)), PNGChunks.textChunk(keyword: "ccv3", text: b64(env))])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(TavernCardPNGWriter.tavernRead(both)).utf8)) as? NSDictionary, env as NSDictionary)
    }

    func testParserKeywordIsCaseInsensitive() throws {
        let env = envelope(name: "大写")
        var old = env; old["data"] = ["name": "chara 的"]
        let png = assemble(pixelsPNG(), beforeEnd: [PNGChunks.textChunk(keyword: "Chara", text: b64(old)), PNGChunks.textChunk(keyword: "CCV3", text: b64(env))])
        XCTAssertEqual(try TavernCard.parsePNG(data: png).name, "大写", "CCV3 / Chara 都认，ccv3 优先")
        let charaOnly = assemble(pixelsPNG(), beforeEnd: [PNGChunks.textChunk(keyword: "CHARA", text: b64(env))])
        XCTAssertEqual(try TavernCard.parsePNG(data: charaOnly).name, "大写")
    }

    // MARK: - 世界书 / 正则带不带

    private func floorBook(_ card: CharacterCard, edit: (inout [WorldBookEntry]) -> Void) throws -> CardExportEditsResolver.FloorBook {
        let report = try card.decodeWorldBook()
        var entries = report.entries
        edit(&entries)
        return .init(name: report.name ?? "岚的书", entries: entries, rawJSONData: report.rawJSONData)
    }

    func testIncludeOrExcludeEditedWorldBookAndRegex() throws {
        let regex: [[String: Any]] = [
            ["id": "r1", "scriptName": "一", "findRegex": "/a/g", "replaceString": "b", "placement": [2], "disabled": false, "markdownOnly": true,
             "promptOnly": false, "runOnEdit": true, "trimStrings": [], "substituteRegex": 0, "minDepth": NSNull(), "maxDepth": NSNull(), "未知": "留着"],
            ["scriptName": "二", "findRegex": "c", "replaceString": "d", "placement": [1]],
        ]
        var card = try imported(tavernPNG(envelope(book: true, regex: regex)))
        XCTAssertEqual(card.regexScripts.count, 2)
        // 没改：没有可带的
        let untouched = CardExportEditsResolver.make(card: card, floorBooks: [try floorBook(card) { _ in }])
        XCTAssertTrue(untouched.isEmpty && untouched.notes.isEmpty)

        card.regexScripts[0].replaceString = "B"
        card.regexScripts[1].disabled = true
        let book = try floorBook(card) { $0[1].content = "石很白，也很凉" }
        let edits = CardExportEditsResolver.make(card: card, floorBooks: [book, .init(name: "别的", entries: [], rawJSONData: nil)])
        XCTAssertNotNil(edits.characterBook)
        let scripts = try XCTUnwrap(edits.regexScripts)
        XCTAssertEqual(scripts[0]["replaceString"] as? String, "B")
        XCTAssertEqual(scripts[0]["未知"] as? String, "留着", "正则未知字段原样留")
        XCTAssertEqual(scripts[0]["id"] as? String, "r1")
        XCTAssertNil(scripts[1]["id"], "原文没 id 的不补 id（按位置对上）")
        XCTAssertEqual(scripts[1]["disabled"] as? Bool, true)
        XCTAssertNil(scripts[1]["markdownOnly"], "没改的缺省字段不补")

        // 带
        let withEdits = try XCTUnwrap(ccv3(TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: edits).data))
        let data = try XCTUnwrap(withEdits["data"] as? [String: Any])
        let entries = try XCTUnwrap((data["character_book"] as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertEqual(entries[1]["content"] as? String, "石很白，也很凉")
        XCTAssertEqual(entries[0]["unknown"] as? String, "留着", "条目未知字段原样留")
        XCTAssertEqual(((data["character_book"] as? [String: Any])?["extensions"] as? [String: Int]), ["x": 1], "书的未知子树留着")
        XCTAssertEqual(((data["extensions"] as? [String: Any])?["regex_scripts"] as? [[String: Any]])?.first?["replaceString"] as? String, "B")

        // 不带：卡里原来的
        card.description = "改个字段让它重写"
        let without = try XCTUnwrap(ccv3(TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil).data))
        let raw = try XCTUnwrap(envelope(book: true, regex: regex)["data"] as? [String: Any])
        XCTAssertEqual((without["data"] as? [String: Any])?["character_book"] as? NSDictionary, raw["character_book"] as? NSDictionary)
        XCTAssertEqual(((without["data"] as? [String: Any])?["extensions"] as? [String: Any])?["regex_scripts"] as? NSArray, regex as NSArray)
        // JSON 导出同口径
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: TavernCardExport.json(card: card, edits: edits)) as? [String: Any])
        XCTAssertEqual((((json["data"] as? [String: Any])?["character_book"] as? [String: Any])?["entries"] as? [[String: Any]])?[1]["content"] as? String,
                       "石很白，也很凉")
    }

    func testUnclearBookMappingFallsBackToCardOriginal() throws {
        let card = try imported(tavernPNG(envelope(book: true)))
        let book = try floorBook(card) { $0[0].content = "改了" }
        let twin = CardExportEditsResolver.make(card: card, floorBooks: [book, book])
        XCTAssertNil(twin.characterBook, "两本同源：分不清，不带")
        XCTAssertEqual(twin.notes.count, 1)
        let missing = CardExportEditsResolver.make(card: card, floorBooks: [])
        XCTAssertNil(missing.characterBook, "楼层里没有：不带")
        XCTAssertEqual(missing.notes.count, 1)
        XCTAssertTrue(CardExportEditsResolver.make(card: card, floorBooks: nil).notes.isEmpty, "没进过楼层：没有可带的，也不提示")
    }

    func testRemovedAndAddedRegexRules() {
        let original: [[String: Any]] = [["id": "a", "findRegex": "1", "x": 1], ["id": "b", "findRegex": "2"]]
        var kept = RegexScript(from: original[1])
        kept.replaceString = "新"
        var added = RegexScript()
        added.id = "c"
        added.findRegex = "3"
        let out = CardExportEditsResolver.regexOverlay([kept, added], original: original)
        XCTAssertEqual(out?.count, 2, "删掉的不写")
        XCTAssertEqual(out?[0]["id"] as? String, "b")
        XCTAssertEqual(out?[0]["replaceString"] as? String, "新")
        XCTAssertEqual(out?[1]["id"] as? String, "c")
        XCTAssertEqual(out?[1]["placement"] as? [Int], [2], "新的全写")
        XCTAssertNil(CardExportEditsResolver.regexOverlay(original.map(RegexScript.init(from:)), original: original), "一样 = nil")
    }

    // MARK: - 许可不进卡

    func testConsentNeverWrittenIntoCard() throws {
        var card = try imported(tavernPNG(envelope()))
        card.description = "改过"
        let plain = try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil).data
        card.extensionConsent = .allowed
        card.sendConsent = .allowed
        let consented = try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil).data
        XCTAssertEqual(plain, consented, "许可变了导出字节一样")
        let json = String(data: try TavernCardExport.json(card: card, edits: nil), encoding: .utf8) ?? ""
        let text = TavernCardPNGWriter.tavernRead(consented) ?? ""
        for key in ["sendConsent", "extensionConsent", "linkedProfileId", "bindingState"] {
            XCTAssertFalse(json.contains(key) || text.contains(key), "\(key) 不进卡")
        }
        // 没改过的卡，许可变了也还是原字节
        var untouched = try imported(tavernPNG(envelope()))
        let original = try XCTUnwrap(untouched.imageData)
        untouched.sendConsent = .denied
        XCTAssertEqual(try TavernCardExport.png(card: untouched, original: untouched.imageData, cover: nil, edits: nil).data, original)
    }

    func testCancelStopsExport() throws {
        let card = try imported(tavernPNG(envelope()))
        XCTAssertThrowsError(try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil, isCancelled: { true })) {
            XCTAssertEqual($0 as? TavernCardPNGWriter.Failure, .cancelled)
        }
        var seen: [Double] = []
        _ = try TavernCardExport.png(card: card, original: card.imageData, cover: nil, edits: nil, progress: { seen.append($0) })
        XCTAssertEqual(seen.last, 1)
    }
}
