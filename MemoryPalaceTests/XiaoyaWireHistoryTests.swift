import XCTest
@testable import 记忆花园

/// 与真 AI 交接（plan-onboarding-xiaoya-impl §4.5）：剧本消息 / 卡片不进 wire；交接分隔线换成一句系统备注，只挂一次、挂在下一句用户话前
@MainActor
final class XiaoyaWireHistoryTests: XCTestCase {
    private var f: XiaoyaScriptFixture!

    override func setUp() async throws { f = try XiaoyaScriptFixture() }
    override func tearDown() async throws { f.clean() }

    func testScriptMessagesAndCardsStayOutOfWire() async {
        await f.start()
        await f.answer(.picked("newbie"))
        await f.answerFaces()
        await f.answer(XiaoyaScriptFixture.saved)
        f.engine.messages.append(AssistantChatMessage(isUser: true, text: "你好呀"))
        f.engine.messages.append(AssistantChatMessage(isUser: false, text: "你好～"))
        f.engine.messages.append(AssistantChatMessage(isUser: true, text: "再说一句"))

        let wire = f.engine.wireHistory()
        XCTAssertEqual(wire.map(\.role), ["user", "assistant", "user"], "剧本台词、「我是小白」气泡、卡片都不进")
        XCTAssertTrue(wire[0].content.hasPrefix("（系统备注，不是用户说的，也别在回复里写：用户刚走完开场引导——"))
        XCTAssertTrue(wire[0].content.contains("园丁类型「我是小白」"))
        XCTAssertTrue(wire[0].content.contains("已配好 OpenAI 的钥匙（模型 gpt-4o-mini）"))
        XCTAssertTrue(wire[0].content.hasSuffix("\n你好呀"))
        XCTAssertEqual(wire[2].content, "再说一句", "交接备注只挂一次")
        XCTAssertEqual(wire.filter { $0.content.contains("开场引导") }.count, 1)
    }

    func testOnlyLatestHandoffBecomesNote() {
        let e = f.engine
        e.messages = [
            AssistantChatMessage(isUser: false, text: "钥匙接好了 · 从这里起小芽用 a 说话", source: .handoff),
            AssistantChatMessage(isUser: true, text: "一"),
            AssistantChatMessage(isUser: false, text: "钥匙接好了 · 从这里起小芽用 b 说话", source: .handoff),
            AssistantChatMessage(isUser: true, text: "二"),
        ]
        let wire = e.wireHistory()
        XCTAssertEqual(wire.count, 2)
        XCTAssertEqual(wire[0].content, "一")
        XCTAssertTrue(wire[1].content.hasPrefix("（系统备注"))
        XCTAssertTrue(wire[1].content.hasSuffix("\n二"))
    }

    func testHandoffNoteFollowsLaterTaFloor() async throws {
        await f.start()
        await f.answer(.picked("tavern"))
        await f.answer(XiaoyaScriptFixture.saved)
        await f.answer(.imported(try f.importedCard()))
        f.engine.messages.append(AssistantChatMessage(isUser: true, text: "改改澪的预设"))
        let wire = f.engine.wireHistory()
        XCTAssertEqual(wire.count, 1)
        XCTAssertTrue(wire[0].content.contains("Ta 的楼层：月见坂 · 澪"), "备注现拼：交接之后才建的楼层也在")
    }

    func testLegacyHistoryDecodesAndUnknownCardFallsBack() throws {
        let legacy = Data(#"[{"isUser":true,"text":"旧的一句"},{"isUser":false,"text":"卡的兜底","source":"future","card":{"card":{"kind":"hologram"}}}]"#.utf8)
        let messages = try JSONDecoder().decode([AssistantChatMessage].self, from: legacy)
        XCTAssertNil(messages[0].source)
        XCTAssertNil(messages[0].card)
        XCTAssertNil(messages[1].source, "不认识的来源当普通话")
        XCTAssertEqual(messages[1].card?.card, .unsupported("hologram"))
        // 往返：新字段写得出读得回
        let roundTrip = try JSONDecoder().decode([AssistantChatMessage].self, from: try JSONEncoder().encode([
            AssistantChatMessage(isUser: false, text: "你是哪种园丁？", source: .script,
                                 card: XiaoyaCardState(card: .choice(.identity), answer: .picked("tech"))),
        ]))
        XCTAssertEqual(roundTrip[0].source, .script)
        XCTAssertEqual(roundTrip[0].card?.answer, .picked("tech"))
    }

    func testRewindRefusesScriptBubblesAndAnythingBeforeACard() async {
        await f.start()
        await f.answer(.picked("newbie"))
        let bubble = f.engine.messages.first { $0.isUser && $0.source == .script }
        XCTAssertFalse(f.engine.canRewind(bubble!.id), "点卡生成的气泡不能改")
        XCTAssertNil(f.engine.rewind(to: bubble!.id))
        await f.answerFaces()
        await f.answer(XiaoyaScriptFixture.saved)
        f.engine.messages.append(AssistantChatMessage(isUser: true, text: "你好呀"))
        let typed = f.engine.messages.last!
        XCTAssertTrue(f.engine.canRewind(typed.id), "卡片之后自己打的字能改")
        f.script.replyFinished()
        await f.script.idle()
        XCTAssertFalse(f.engine.canRewind(typed.id), "后面出了卡就不能改了（删了剧本接不上）")
    }
}
