import XCTest
@testable import 记忆花园

/// R9c-A N5：segmented 流式尾巴与定稿 .text 段共享同一个显示加工（SegmentDisplayText.apply）。
/// 两处调用点都调它（MessageSegmentsView.itemView .text / SegmentedAssistantBody.renderSnapshot），
/// 这里测这个函数本身的行为。
final class SegmentDisplayTextTests: XCTestCase {
    /// 显示时机会跑的脚本：markdownOnly=true + placement 含 2（AI 消息）。
    private func displayScript(find: String, replace: String) -> RegexScript {
        var s = RegexScript()
        s.scriptName = "t"
        s.findRegex = find
        s.replaceString = replace
        s.markdownOnly = true
        s.placement = [2]
        return s
    }

    func testRegexHitTransforms() {
        let scripts = [displayScript(find: "/秘密/g", replace: "**")]
        XCTAssertEqual(SegmentDisplayText.apply(scripts: scripts, to: "这是秘密计划。"), "这是**计划。")
    }

    func testEmptyScriptsPassthrough() {
        XCTAssertEqual(SegmentDisplayText.apply(scripts: [], to: "原文"), "原文")
    }

    func testDisabledScriptNotApplied() {
        var s = displayScript(find: "秘密", replace: "**")
        s.disabled = true
        XCTAssertEqual(SegmentDisplayText.apply(scripts: [s], to: "秘密"), "秘密")
    }

    /// 非显示时机的脚本（markdownOnly=false 且 promptOnly=false = 普通模式）在显示加工里不跑。
    func testNonMarkdownScriptSkipped() {
        var s = displayScript(find: "秘密", replace: "**")
        s.markdownOnly = false
        XCTAssertEqual(SegmentDisplayText.apply(scripts: [s], to: "秘密"), "秘密")
    }
}
