import XCTest
@testable import 记忆花园

final class WorldBookCodecTests: XCTestCase {
    private func scan(_ entries: [WorldBookEntry], text: String = "主词") -> [ResolvedEntry] {
        let profile = Profile(name: "测试", emoji: "", description: "", userName: "用户", assistantName: "角色")
        return WorldBookScanner.scan(worldBooks: [], recentMessages: [text], profile: profile, globalEntries: entries)
    }

    func testWorldInfoObjectMapsFalseZeroAndAllFields() throws {
        let raw = Data(#"{"name":"独立书","entries":{"0":{"uid":0,"key":["主词"],"keysecondary":["次词"],"disable":true,"order":0,"position":0,"depth":0,"scanDepth":0,"selectiveLogic":0,"probability":0,"useProbability":false,"matchWholeWords":false,"caseSensitive":false,"constant":true,"comment":"备注","content":"a\nb","selective":false}}}"#.utf8)
        let report = try WorldBookCodec.decodeWorldInfo(raw)
        let entry = try XCTUnwrap(report.entries.first)
        XCTAssertEqual(report.rawJSONData, raw)
        XCTAssertEqual(entry.keys, ["主词"])
        XCTAssertEqual(entry.secondaryKeys, ["次词"])
        XCTAssertFalse(entry.isEnabled)
        XCTAssertEqual(entry.insertionOrder, 0)
        XCTAssertEqual(entry.position, .beforeCharDef)
        XCTAssertEqual(entry.depth, 0)
        XCTAssertEqual(entry.scanDepth, 0)
        XCTAssertEqual(entry.selectiveLogic, .andAny)
        XCTAssertEqual(entry.probability, 0)
        XCTAssertEqual(entry.useProbability, false)
        XCTAssertEqual(entry.selectiveEnabled, false)
        XCTAssertFalse(entry.matchWholeWords)
        XCTAssertFalse(entry.caseSensitive)
        XCTAssertTrue(entry.isConstant)
        XCTAssertEqual(entry.comment, "备注")
        XCTAssertEqual(entry.content, "a\nb")
        XCTAssertEqual(report.unsupportedEntryCount, 0)
        XCTAssertTrue(scan([entry]).isEmpty)
    }

    func testWorldInfoNonDefaultMatchingAndLogic() throws {
        for logic in 0...3 {
            let raw = Data("""
            {"entries":[{"key":["Word"],"keysecondary":["Other"],"disable":false,"order":27,
              "depth":6,"scanDepth":5,"selectiveLogic":\(logic),"probability":37,"useProbability":true,
              "matchWholeWords":true,"caseSensitive":true,"constant":false,"selective":true}]}
            """.utf8)
            let entry = try XCTUnwrap(WorldBookCodec.decodeWorldInfo(raw).entries.first)
            XCTAssertTrue(entry.isEnabled)
            XCTAssertEqual(entry.insertionOrder, 27)
            XCTAssertEqual(entry.depth, 6)
            XCTAssertEqual(entry.scanDepth, 5)
            XCTAssertEqual(entry.selectiveLogic.rawValue, logic)
            XCTAssertEqual(entry.probability, 37)
            XCTAssertEqual(entry.useProbability, true)
            XCTAssertEqual(entry.selectiveEnabled, true)
            XCTAssertTrue(entry.matchWholeWords)
            XCTAssertTrue(entry.caseSensitive)
            XCTAssertFalse(entry.isConstant)
        }
    }

    func testWorldInfoArrayAllSevenPositions() throws {
        let raw = Data(("{\"entries\":[" + (0...6).map { "{\"position\":\($0),\"constant\":true,\"content\":\"\($0)\"}" }.joined(separator: ",") + "]}").utf8)
        let report = try WorldBookCodec.decodeWorldInfo(raw)
        XCTAssertEqual(report.entries.map(\.position.rawValue), Array(0...6))
        XCTAssertEqual(scan(report.entries).count, 7)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testUnknownPositionKeepsRawReportsAndDoesNotInjectAfterReload() throws {
        let raw = Data(#"{"entries":[{"position":99,"constant":true,"content":"禁止注入","cooldown":5}]}"#.utf8)
        let report = try WorldBookCodec.decodeWorldInfo(raw)
        XCTAssertEqual(report.unsupportedEntryCount, 1)
        XCTAssertTrue(report.issues.contains { $0.field == "position" })
        XCTAssertTrue(report.issues.contains { $0.field == "cooldown" })
        XCTAssertEqual(report.summary, "导入 1 条；1 条用了还不支持的设置（冷却、分组、递归等），这些设置已保留但不生效")
        let entries = try JSONDecoder().decode([WorldBookEntry].self, from: JSONEncoder().encode(report.entries))
        let entryRaw = try XCTUnwrap(entries.first?.rawJSONData)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: entryRaw) as? [String: Any])?["position"] as? Int, 99)
        XCTAssertTrue(scan(entries).isEmpty)
    }

    /// 酒馆每条都带全套默认字段，默认值不算「不支持」；extensions 镜像不重复报
    func testDefaultTavernFieldsAreNotReported() throws {
        let raw = Data(#"{"entries":{"0":{"key":["a"],"content":"x","position":0,"cooldown":null,"sticky":0,"delay":null,"group":"","groupWeight":100,"groupOverride":false,"useGroupScoring":null,"role":null,"vectorized":false,"addMemo":true,"preventRecursion":true,"excludeRecursion":false,"delayUntilRecursion":false,"matchPersonaDescription":false,"characterFilter":{"isExclude":false,"names":[],"tags":[]},"extensions":{"position":0,"probability":100,"group_weight":100,"prevent_recursion":true,"display_index":0}}}}"#.utf8)
        let report = try WorldBookCodec.decodeWorldInfo(raw)
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.summary, "导入 1 条")
        let sticky = try WorldBookCodec.decodeWorldInfo(Data(#"{"entries":[{"key":["a"],"content":"x","sticky":3,"group":"天气"}]}"#.utf8))
        XCTAssertEqual(Set(sticky.issues.map(\.field)), ["sticky", "group"])
    }

    func testMissingDepthDiffersFromExplicitZero() throws {
        let report = try WorldBookCodec.decodeWorldInfo(Data(#"{"entries":[{}, {"depth":0,"scanDepth":0}]}"#.utf8))
        XCTAssertNil(report.entries[0].depth)
        XCTAssertNil(report.entries[0].scanDepth)
        XCTAssertEqual(report.entries[1].depth, 0)
        XCTAssertEqual(report.entries[1].scanDepth, 0)
        let restored = try JSONDecoder().decode([WorldBookEntry].self, from: JSONEncoder().encode(report.entries))
        XCTAssertNil(restored[0].depth)
        XCTAssertEqual(restored[1].depth, 0)
    }

    func testSelectiveAndProbabilityExplicitOffPreserveLegacyNilBehavior() throws {
        let raw = Data(#"{"entries":[{"key":["主词"],"keysecondary":["不存在"],"selective":false,"probability":0,"useProbability":false,"content":"命中"}]}"#.utf8)
        var entry = try XCTUnwrap(WorldBookCodec.decodeWorldInfo(raw).entries.first)
        XCTAssertEqual(scan([entry]).map(\.content), ["命中"])
        entry.selectiveEnabled = nil
        XCTAssertTrue(scan([entry]).isEmpty)
        entry.selectiveEnabled = false
        entry.useProbability = nil
        XCTAssertTrue(scan([entry]).isEmpty)
        entry.probability = 100
        XCTAssertEqual(scan([entry]).count, 1)
    }

    func testCharacterBookExtensionsAndFallback() throws {
        let raw = Data(#"{"entries":[{"keys":["主词"],"secondary_keys":["次词"],"enabled":false,"insertion_order":0,"position":"before_char","selective":false,"extensions":{"position":4,"depth":0,"scan_depth":0,"selectiveLogic":3,"probability":0,"useProbability":false,"match_whole_words":true,"case_sensitive":true}},{"position":"before_char"},{"position":"after_char"},{"position":"before_char","extensions":{"position":99}}]}"#.utf8)
        let report = try WorldBookCodec.decodeCharacterBook(raw)
        let first = report.entries[0]
        XCTAssertFalse(first.isEnabled)
        XCTAssertEqual(first.keys, ["主词"])
        XCTAssertEqual(first.secondaryKeys, ["次词"])
        XCTAssertEqual(first.insertionOrder, 0)
        XCTAssertEqual(first.position, .atDepth)
        XCTAssertEqual(first.depth, 0)
        XCTAssertEqual(first.scanDepth, 0)
        XCTAssertEqual(first.selectiveLogic, .andAll)
        XCTAssertEqual(first.probability, 0)
        XCTAssertEqual(first.useProbability, false)
        XCTAssertEqual(first.selectiveEnabled, false)
        XCTAssertTrue(first.matchWholeWords)
        XCTAssertTrue(first.caseSensitive)
        XCTAssertEqual(report.entries[1].position, .beforeCharDef)
        XCTAssertEqual(report.entries[2].position, .afterCharDef)
        XCTAssertEqual(report.entries[3].position, .unsupported)
        XCTAssertEqual(report.unsupportedEntryCount, 1)
    }

    func testImportDispatchesByStructure() throws {
        let world = Data(#"{"entries":[{"uid":0,"key":["独立"],"disable":true}]}"#.utf8)
        XCTAssertFalse(try WorldBookCodec.decodeImport(world).entries[0].isEnabled)
        let card = Data(#"{"spec":"chara_card_v3","data":{"character_book":{"entries":[{"keys":["卡内"],"enabled":false}]}}}"#.utf8)
        XCTAssertEqual(try WorldBookCodec.decodeImport(card).entries[0].keys, ["卡内"])
        let bare = Data(#"{"entries":[{"keys":["直接卡内书"],"enabled":false}]}"#.utf8)
        XCTAssertFalse(try WorldBookCodec.decodeImport(bare).entries[0].isEnabled)
    }

    func testNegativeDepthAndInvalidProbabilityReject() {
        for field in ["depth", "scanDepth"] {
            XCTAssertThrowsError(try WorldBookCodec.decodeWorldInfo(Data("{\"entries\":[{\"\(field)\":-1}]}".utf8)))
        }
        for field in ["depth", "scan_depth"] {
            XCTAssertThrowsError(try WorldBookCodec.decodeCharacterBook(Data("{\"entries\":[{\"extensions\":{\"\(field)\":-1}}]}".utf8)))
        }
        for value in [-1, 101] {
            XCTAssertThrowsError(try WorldBookCodec.decodeWorldInfo(Data("{\"entries\":[{\"probability\":\(value)}]}".utf8)))
        }
        XCTAssertThrowsError(try WorldBookCodec.decodeWorldInfo(Data(#"{"entries":[{},false]}"#.utf8)))
    }

    func testOldEntryAndGlobalBookDecodeAndBackupRoundTrip() throws {
        let legacyEntry = Data(#"{"id":"00000000-0000-0000-0000-000000000001","isEnabled":false,"content":"旧","depth":4}"#.utf8)
        let entry = try JSONDecoder().decode(WorldBookEntry.self, from: legacyEntry)
        XCTAssertNil(entry.rawJSONData)
        XCTAssertNil(entry.selectiveEnabled)
        XCTAssertNil(entry.useProbability)
        XCTAssertEqual(entry.depth, 4)
        let raw = Data(#"{"entries":{},"unknown":true}"#.utf8)
        var book = GlobalWorldBook(name: "全局", entries: [entry])
        let legacyBook = try JSONEncoder().encode(book)
        XCTAssertNil(try JSONDecoder().decode(GlobalWorldBook.self, from: legacyBook).rawJSONData)
        book.rawJSONData = raw
        let restored = try JSONDecoder().decode([GlobalWorldBook].self, from: JSONEncoder().encode([book]))[0]
        XCTAssertEqual(restored, book)
    }

    func testFloorBookFullDocumentRoundTripAndOldDocument() throws {
        let raw = Data(#"{"entries":[{"key":["词"],"position":99}]}"#.utf8)
        let report = try WorldBookCodec.decodeWorldInfo(raw)
        let book = WorldBook(name: "备份", profileId: "isolated", entries: report.entries)
        book.rawJSONData = raw
        let doc = FullWorldBookDocument(model: book)
        let encoded = try JSONEncoder().encode(doc)
        let restored = try JSONDecoder().decode(FullWorldBookDocument.self, from: encoded).toModel()
        XCTAssertEqual(restored.rawJSONData, raw)
        XCTAssertEqual(restored.entries, report.entries)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "rawJSONData")
        XCTAssertNil(try JSONDecoder().decode(FullWorldBookDocument.self, from: JSONSerialization.data(withJSONObject: legacy)).toModel().rawJSONData)
        XCTAssertTrue(SchemaCoverageCheck.documentFieldNames(sample: doc).contains("rawJSONData"))
    }
}
