import XCTest
@testable import 记忆花园

final class CardFidelityTests: XCTestCase {
    private func fixture(spec: String = "chara_card_v2") -> Data {
        Data("""
        { "spec": "\(spec)", "spec_version": "\(spec.hasSuffix("v3") ? "3.0" : "2.0")", "top_unknown": [1,2],
          "name":"顶层兜底", "data": {"name":"原名", "first_mes":"a\\nb", "description":" 保留\\r\\n空格 ",
          "tags":["标签"], "creator":"作者", "character_version":"版本", "alternate_greetings":["x\\ny"],
          "extensions":{"unknown":{"array":[false,0,null]},"regex_scripts":[
            {"id":"one","scriptName":"规则一","findRegex":"a","replaceString":"b","maxDepthL":7},
            {"id":"two","scriptName":"规则二","disabled":true}]},
          "character_book":{"name":"内嵌书","custom":true,"entries":[{"keys":["词"],"enabled":false,"content":"原文"}]}}
        }
        """.utf8)
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testOldCardWithoutNewKeysDecodes() throws {
        let legacy = Data(#"{"id":"old","name":"旧卡","firstMes":"a\nb","characterBookEntriesData":"W10=","createdAt":123}"#.utf8)
        let card = try JSONDecoder().decode(CharacterCard.self, from: legacy)
        XCTAssertEqual(card.id, "old")
        XCTAssertEqual(card.firstMes, "a\nb")
        XCTAssertEqual(card.characterBookEntriesData, Data("[]".utf8))
        XCTAssertNil(card.rawJSONData)
        XCTAssertEqual(card.regexScripts, [])
        XCTAssertEqual(card.tags, [])
        XCTAssertNil(card.creator)
        XCTAssertNil(card.characterVersion)
    }

    func testV2AndV3KeepMetadataRegexAndOriginalBytes() throws {
        for spec in ["chara_card_v2", "chara_card_v3"] {
            let raw = fixture(spec: spec)
            let parsed = try TavernCard.parseJSON(data: raw)
            XCTAssertEqual(parsed.tags, ["标签"])
            XCTAssertEqual(parsed.creator, "作者")
            XCTAssertEqual(parsed.characterVersion, "版本")
            XCTAssertEqual(parsed.regexScripts.count, 2)
            let card = CharacterCard(from: parsed)
            let restored = try JSONDecoder().decode(CharacterCard.self, from: JSONEncoder().encode(card))
            XCTAssertEqual(restored.regexScripts.map(\.id), ["one", "two"])
            XCTAssertTrue(restored.regexScripts[1].disabled)
            XCTAssertEqual(restored.firstMes, "a\nb")
            XCTAssertEqual(restored.alternateGreetings, ["x\ny"])
            XCTAssertEqual(restored.description, " 保留\r\n空格 ")
            XCTAssertEqual(try restored.exportJSON(), raw)
        }
    }

    func testTopLevelFallbackAndExplicitEmptyInnerValues() throws {
        let raw = Data(#"{"name":"old","creator":"old","tags":["old"],"system_prompt":"sys","post_history_instructions":"post","alternate_greetings":["hi"],"creatorcomment":"note","extensions":{"regex_scripts":[{"id":"legacy"}]},"data":{"name":"","creator":"","tags":[]}}"#.utf8)
        let card = try TavernCard.parseJSON(data: raw)
        XCTAssertEqual(card.name, "")
        XCTAssertEqual(card.creator, "")
        XCTAssertEqual(card.tags, [])
        XCTAssertEqual(card.systemPrompt, "sys")
        XCTAssertEqual(card.postHistoryInstructions, "post")
        XCTAssertEqual(card.alternateGreetings, ["hi"])
        XCTAssertEqual(card.creatorNotes, "note")
        XCTAssertEqual(card.regexScripts.count, 1)
    }

    func testNameOverlayChangesOnlyDataName() throws {
        let raw = fixture()
        var card = CharacterCard(from: try TavernCard.parseJSON(data: raw))
        card.name = "改名"
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var inner = try XCTUnwrap(expected["data"] as? [String: Any])
        inner["name"] = "改名"
        expected["data"] = inner
        XCTAssertEqual(try object(card.exportJSON()), NSDictionary(dictionary: expected))
        card.name = "原名"
        XCTAssertEqual(try card.exportJSON(), raw)
    }

    func testLegacyExportCreatesMinimalV2() throws {
        let card = CharacterCard(from: TavernCard(name: "旧卡", firstMes: "a\nb"))
        let json = try object(card.exportJSON())
        XCTAssertEqual(json["spec"] as? String, "chara_card_v2")
        XCTAssertEqual(json["spec_version"] as? String, "2.0")
        let inner = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(inner["name"] as? String, "旧卡")
        XCTAssertEqual(inner["first_mes"] as? String, "a\nb")
    }

    func testPNGPrefersCCV3AndFallsBackToChara() throws {
        func chunk(_ keyword: String, _ raw: Data) -> Data {
            let bytes = Data((keyword + "\0" + raw.base64EncodedString()).utf8)
            let length = UInt32(bytes.count)
            return Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
                + Data("tEXt".utf8) + bytes + Data(repeating: 0, count: 4)
        }
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let v2 = fixture(), v3 = fixture(spec: "chara_card_v3")
        let png = signature + chunk("ccv3", v3) + chunk("chara", v2)
        XCTAssertEqual(try TavernCard.parsePNG(data: png).rawJSONData, v3)
        XCTAssertEqual(try TavernCard.parsePNG(data: png).imageData, png)
        XCTAssertEqual(try TavernCard.parsePNG(data: signature + chunk("chara", v2)).rawJSONData, v2)
    }

    /// 与 .mpb userdefaults/*.json 相同的整对象编码路径，无真实 stores。
    func testPresetRawAndOptionalBackwardCompatibility() throws {
        let raw = Data(#"{"prompts":[{"identifier":"x","name":"原名","content":"a\nb"}],"prompt_order":[{"character_id":100000,"order":[]},{"character_id":100001,"order":[{"identifier":"x","enabled":false}]}],"extensions":{"unknown":[1,2]}}"#.utf8)
        let preset = try Preset.fromSillyTavernJSON(raw)
        let restored = try JSONDecoder().decode([Preset].self, from: JSONEncoder().encode([preset]))[0]
        XCTAssertEqual(restored.rawJSONData, raw)
        XCTAssertEqual(restored.prompts.first?.isEnabled, false)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
        legacy.removeValue(forKey: "rawJSONData")
        XCTAssertNil(try JSONDecoder().decode(Preset.self, from: JSONSerialization.data(withJSONObject: legacy)).rawJSONData)
    }

    func testIsolatedBlobStoreRoundTripAndWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CardFidelityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let manager = CharacterCardManager(root: root, libraryRoot: root.appendingPathComponent("cardlibrary"), defaults: defaults)
        let card = CharacterCard(from: try TavernCard.parseJSON(data: fixture()))
        try manager.add(card)
        XCTAssertEqual(CharacterCardManager(root: root, libraryRoot: root.appendingPathComponent("cardlibrary"), defaults: defaults).cards, [card])
        var edited = card
        edited.name = "新名字"
        try manager.update(edited)
        XCTAssertEqual(CharacterCardManager(root: root, libraryRoot: root.appendingPathComponent("cardlibrary"), defaults: defaults).cards, [edited])
        // 把目录换成普通文件，制造可重复的写失败（不靠权限或真实磁盘满）。
        try FileManager.default.removeItem(at: root)
        try Data("blocked".utf8).write(to: root)
        XCTAssertThrowsError(try manager.delete(edited))
        XCTAssertEqual(manager.cards, [edited])
        XCTAssertThrowsError(try manager.add(card))
        XCTAssertEqual(manager.cards, [edited])
    }

    func testCorruptLibraryCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CardFidelityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("savedCharacterCards")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        let manager = CharacterCardManager(root: root, libraryRoot: root.appendingPathComponent("cardlibrary"), defaults: defaults)
        XCTAssertThrowsError(try manager.add(CharacterCard(from: TavernCard(name: "新卡"))))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testLegacyDefaultsMigrationUsesOnlyInjectedSuite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CardFidelityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let legacy = Data(#"[{"id":"legacy","name":"旧卡","firstMes":"a\nb"}]"#.utf8)
        defaults.set(legacy, forKey: "savedCharacterCards")
        XCTAssertEqual(CharacterCardManager(root: root, libraryRoot: root.appendingPathComponent("cardlibrary"), defaults: defaults).cards.first?.firstMes, "a\nb")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("savedCharacterCards")), legacy)
        XCTAssertNil(defaults.data(forKey: "savedCharacterCards"))
    }
}
