import XCTest
import MemoryCore
@testable import 记忆花园

/// 消息显示副本唯一口径（plan-铲屎-显示统一 刀 A）
final class MessageDisplayTextTests: XCTestCase {

    private func rule(_ find: String, _ replace: String, placement: [Int] = [2], display: Bool = true) -> RegexScript {
        var s = RegexScript()
        s.findRegex = find
        s.replaceString = replace
        s.placement = placement
        s.markdownOnly = display
        return s
    }

    private func make(_ raw: String, role: String = "assistant", scripts: [RegexScript] = [],
                      legacy: Bool = true) -> MessageDisplayText.Result {
        MessageDisplayText.make(raw, role: role, scripts: scripts, userName: "禾禾", charName: "小岚",
                                legacyErrorMarker: legacy)
    }

    /// L-B14：跨段落的规则整条跑才匹配得上；切泡在这之后
    func testRegexSpanningParagraphsMatchesBeforeBlockSplit() {
        let raw = "第一段\n\n<status>\n体力 3\n\n心情 好\n</status>\n\n最后一段"
        let body = make(raw, scripts: [rule("/<status>[\\s\\S]*?<\\/status>/g", "【状态栏】")]).body
        XCTAssertEqual(BubbleModeRow.splitBlocks(body), ["第一段", "【状态栏】", "最后一段"])
    }

    /// 没有规则时和各渲染器原来的口径逐字相同
    func testNoScriptsMatchesLegacyPipeline() {
        let raw = "你好 {{user}}，我是 {{char}}。\n\n第二段"
        let legacy = EffectiveCharacterContext(charName: "小岚", userName: "禾禾").expand(ContentCleaner.clean(raw, cacheKey: nil))
        XCTAssertEqual(make(raw).body, ContentCleaner.extractThinking(from: legacy).content)
        XCTAssertEqual(make(raw).body, "你好 禾禾，我是 小岚。\n\n第二段")
    }

    /// L-B15 ③：先剥思考再跑正则——规则碰不到思考里的字
    func testThinkingExtractedBeforeRegex() {
        let result = make("[thinking]我想想 苹果[/thinking]\n正文 苹果", scripts: [rule("/苹果/g", "梨")])
        XCTAssertEqual(result.thinking, "我想想 苹果")
        XCTAssertEqual(result.body.trimmingCharacters(in: .whitespacesAndNewlines), "正文 梨")
    }

    /// L-B15 ①：ChatGPT 导入的引用标记被清掉
    func testChatGPTCitationMarkersCleaned() {
        let raw = "结论在这\u{E200}cite\u{E202}turn0search1\u{E201}。"
        XCTAssertEqual(make(raw).body, ContentCleaner.clean(raw, cacheKey: nil))
        XCTAssertFalse(make(raw).body.contains("turn0search"))
    }

    func testAssistantErrorTailSplitOff() {
        XCTAssertEqual(make("说到一半\n\n⚠️ 网络断了").body, "说到一半")
        XCTAssertEqual(make("⚠️ 网络断了").body, "")
        // 新标记（11-08 起）：正文里的 ⚠️ 不再被拆，只认 errorLine
        XCTAssertEqual(make("说到一半\n\n⚠️ 注意别烫手", legacy: false).body, "说到一半\n\n⚠️ 注意别烫手")
        XCTAssertEqual(make("说到一半\n\n" + ChatSystemMessage.errorLine("网络断了"), legacy: false).body, "说到一半")
        // 页 2：尾巴留在正文里
        XCTAssertEqual(MessageDisplayText.make("说到一半\n\n⚠️ 网络断了", role: "assistant", scripts: [], userName: "", charName: "",
                                               splitsSystemTail: false, legacyErrorMarker: true).body, "说到一半\n\n⚠️ 网络断了")
    }

    /// 用户消息：不拆尾巴、不剥思考，只跑 placement 1 的规则
    func testUserMessageKeepsMarkersAndUsesUserPlacement() {
        let raw = "[thinking]不是思考[/thinking]\n\n⚠️ 我自己打的 苹果"
        let scripts = [rule("/苹果/g", "梨", placement: [2]), rule("/我自己/g", "{{user}}", placement: [1])]
        let result = make(raw, role: "user", scripts: scripts)
        XCTAssertNil(result.thinking)
        XCTAssertEqual(result.body, "[thinking]不是思考[/thinking]\n\n⚠️ 禾禾打的 苹果")
    }

    func testNonDisplayRulesAndOtherRolesSkipped() {
        XCTAssertEqual(make("苹果", scripts: [rule("/苹果/g", "梨", display: false)]).body, "苹果")
        XCTAssertEqual(make("苹果", role: "system", scripts: [rule("/苹果/g", "梨", placement: [1, 2])]).body, "苹果")
    }

    /// N1：流式口径也把名字传给规则；不拆尾巴、不展开正文里的名字宏
    func testStreamingRunsWholeTextWithNames() {
        let scripts = [rule("/<status>[\\s\\S]*?<\\/status>/g", "【{{char}} 的状态】")]
        let result = MessageDisplayText.streaming("[thinking]想[/thinking]\n甲\n\n<status>\n一\n\n二\n</status>\n\n乙",
                                                  scripts: scripts, userName: "禾禾", charName: "小岚")
        XCTAssertEqual(result.thinking, "想")
        XCTAssertEqual(BubbleModeRow.splitBlocks(result.body), ["甲", "【小岚 的状态】", "乙"])
        let open = MessageDisplayText.streaming("甲\n\n<status>\n一", scripts: scripts, userName: "禾禾", charName: "小岚")
        XCTAssertEqual(open.body, "甲\n\n<status>\n一")
    }
}
