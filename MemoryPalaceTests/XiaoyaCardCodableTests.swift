import XCTest
@testable import 记忆花园

/// 小芽引导卡 P3（plan-onboarding-xiaoya-impl §3）：每种卡 + 每种答案往返编解码；缺字段的旧数据、新版未知卡都能解
final class XiaoyaCardCodableTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(back, value, file: file, line: line)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testEveryCardRoundTrips() throws {
        let cards: [XiaoyaCard] = [
            .choice(.identity),
            .choice(.hasMac),
            .keyForm,
            .importCard,
            .nameForm,
            .floorExit(XiaoyaFloorExitPayload(ta: XiaoyaTaRef(profileId: "p-1", name: "澪"), meta: "开场白已就位", extras: [.worldBook, .preset])),
            .goTa(XiaoyaTaRef(profileId: "p-2", name: "阿洛")),
            .pair,
            .todo(["一", "二", "三"]),
            .info,
            .makeTa,
        ]
        for card in cards {
            try roundTrip(card)
            try roundTrip(XiaoyaCardState(card: card))
        }
    }

    func testEveryAnswerRoundTrips() throws {
        let answers: [XiaoyaCardAnswer] = [
            .picked("tavern"),
            .keySaved(XiaoyaKeySaved(credentialId: "cred-1", providerName: "OpenAI", modelId: "gpt-4o-mini")),
            .skipped,
            .imported(XiaoyaImportedCard(name: "澪", greetingCount: 2, worldBookEntries: 12, hasSystemPrompt: true,
                                         fileURL: URL(fileURLWithPath: "/tmp/xiaoya-import/a/mio.png"))),
            .named(XiaoyaNameAnswer(taName: "阿洛", userName: "粟粟", who: "嘴硬心软")),
            .floor(.go),
            .floor(.stay),
            .floorExtra(.chatHistory),
            .makeTa,
            .paired("已配对 ✓ LAN"),
            .later,
        ]
        for answer in answers {
            try roundTrip(answer)
            try roundTrip(XiaoyaCardState(card: .keyForm, answer: answer))
        }
    }

    func testMissingFieldsDecodeWithDefaults() throws {
        // 选择卡只剩 kind：空选项，不炸
        XCTAssertEqual(try decode(XiaoyaCard.self, #"{"kind":"choice"}"#), .choice(XiaoyaChoicePayload(options: [])))
        // 选项缺 title / detail
        let choice = try decode(XiaoyaCard.self, #"{"kind":"choice","choice":{"options":[{"id":"yes"}]}}"#)
        XCTAssertEqual(choice, .choice(XiaoyaChoicePayload(options: [XiaoyaChoiceOption(id: "yes", title: "yes")])))
        // 出口卡缺 meta / extras，Ta 缺 profileId
        let exit = try decode(XiaoyaCard.self, #"{"kind":"floorExit","floorExit":{"ta":{"name":"澪"}}}"#)
        XCTAssertEqual(exit, .floorExit(XiaoyaFloorExitPayload(ta: XiaoyaTaRef(profileId: nil, name: "澪"), meta: "", extras: [])))
        // 答案缺字段
        XCTAssertEqual(try decode(XiaoyaCardAnswer.self, #"{"kind":"named","name":{"taName":"阿洛"}}"#),
                       .named(XiaoyaNameAnswer(taName: "阿洛")))
        XCTAssertEqual(try decode(XiaoyaCardAnswer.self, #"{"kind":"keySaved","key":{"modelId":"m"}}"#),
                       .keySaved(XiaoyaKeySaved(credentialId: "", providerName: "", modelId: "m")))
        XCTAssertEqual(try decode(XiaoyaCardAnswer.self, #"{"kind":"imported","card":{"name":"澪"}}"#),
                       .imported(XiaoyaImportedCard(name: "澪", greetingCount: 0, worldBookEntries: 0, hasSystemPrompt: false, fileURL: nil)))
        // 状态没答案
        XCTAssertEqual(try decode(XiaoyaCardState.self, #"{"card":{"kind":"info"}}"#), XiaoyaCardState(card: .info))
        // 状态连卡都没有
        XCTAssertEqual(try decode(XiaoyaCardState.self, #"{}"#), XiaoyaCardState(card: .unsupported("")))
    }

    func testUnknownKindsFromNewerVersionDecodeAsUnsupported() throws {
        XCTAssertEqual(try decode(XiaoyaCard.self, #"{"kind":"voiceNote","clip":"x"}"#), .unsupported("voiceNote"))
        XCTAssertEqual(try decode(XiaoyaCardAnswer.self, #"{"kind":"recorded"}"#), .unsupported("recorded"))
        XCTAssertEqual(try decode(XiaoyaCardAnswer.self, #"{"kind":"floor","floor":"later"}"#), .unsupported("floor.later"))
        // 新版多出来的追加导入项丢掉，认识的留下
        let exit = try decode(XiaoyaCard.self, #"{"kind":"floorExit","floorExit":{"ta":{"name":"澪"},"extras":["regex","preset"]}}"#)
        XCTAssertEqual(exit, .floorExit(XiaoyaFloorExitPayload(ta: XiaoyaTaRef(profileId: nil, name: "澪"), meta: "", extras: [.preset])))
        // unsupported 原样写回 kind，降级再升级不丢类型名
        let back = try JSONDecoder().decode(XiaoyaCard.self, from: JSONEncoder().encode(XiaoyaCard.unsupported("voiceNote")))
        XCTAssertEqual(back, .unsupported("voiceNote"))
    }

    func testFallbackTextAndClosesCard() {
        XCTAssertEqual(XiaoyaCardState(card: .nameForm).fallbackText, "Ta 叫什么？")
        XCTAssertEqual(XiaoyaCardState(card: .nameForm, answer: .named(XiaoyaNameAnswer(taName: "阿洛", userName: "粟粟"))).fallbackText,
                       "Ta 叫「阿洛」，叫你「粟粟」")
        XCTAssertFalse(XiaoyaCardAnswer.floorExtra(.worldBook).closesCard)
        XCTAssertTrue(XiaoyaCardAnswer.floor(.go).closesCard)
        XCTAssertEqual(XiaoyaImportedCard(name: "澪", greetingCount: 2, worldBookEntries: 12, hasSystemPrompt: true, fileURL: nil).meta,
                       "开场白 2 条 · 内嵌世界书 12 条 · 卡自带系统指令")
    }
}
