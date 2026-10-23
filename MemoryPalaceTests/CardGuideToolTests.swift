import XCTest
@testable import 记忆花园

/// 卡片说明改成用到再查（粟粟 10-03：这么长一坨不要全塞系统提示词）
final class CardGuideToolTests: XCTestCase {

    // MARK: - 短目录

    func testIndexIsShortAndListsEveryKind() {
        let index = ChatCardPromptGuide.index
        XCTAssertLessThan(index.utf8.count, ChatCardPromptGuide.text.utf8.count * 2 / 3, "目录比完整版短")
        for kind in ["card-todo", "card-dice", "card-timer", "card-chart", "card-music", "card-word", "card-timeline", "card-ask", "```html"] {
            XCTAssertTrue(index.contains(kind), kind)
        }
        XCTAssertTrue(index.contains("card_guide"), "目录里说清复杂卡用之前先查")
        XCTAssertTrue(index.contains("[附带事件]"), "怎么读对方消息的那句一直在")
        XCTAssertFalse(index.contains("builtin:slowtide"), "复杂卡细节不进目录")
    }

    /// #089 P2-c：常用四种格式直接在系统提示里（和 card_guide 切出来的是同一份文字），不用每次查
    func testCommonKindsInlined() {
        let index = ChatCardPromptGuide.index
        for kind in ChatCardPromptGuide.inlineKinds {
            XCTAssertTrue(index.contains(ChatCardPromptGuide.section(kind)), kind)
        }
        XCTAssertTrue(index.contains("新卡片自己起一个短 id"), "公共规则跟着进")
        XCTAssertFalse(index.contains(ChatCardPromptGuide.section("chart")), "复杂卡不进")
    }

    // MARK: - 按种类切段

    func testSectionsForOneKind() {
        let out = ChatCardPromptGuide.guide(for: ["music"])
        XCTAssertTrue(out.contains("card-music："))
        XCTAssertTrue(out.contains("builtin:slowtide"))
        XCTAssertFalse(out.contains("card-chart："), "只给要的那种")
        XCTAssertTrue(out.contains("新卡片自己起一个短 id"), "公共规则每次都带")
        XCTAssertTrue(out.contains("要修改已有卡片"))
        XCTAssertTrue(out.contains("语言名要写全"))
    }

    func testAskSectionKeepsItsContinuationLines() {
        let out = ChatCardPromptGuide.guide(for: ["ask"])
        XCTAssertTrue(out.contains("card-ask："))
        XCTAssertTrue(out.contains("\"secure\":true"), "提问卡后面缩进的几段（加密 / 表单）跟着走")
        XCTAssertTrue(out.contains("slider"))
    }

    func testHTMLAndMultipleKinds() {
        let out = ChatCardPromptGuide.guide(for: ["html", "todo"])
        XCTAssertTrue(out.contains("mp.todo.add"))
        XCTAssertTrue(out.contains("card-todo："))
        XCTAssertFalse(out.contains("card-dice："))
    }

    func testUnknownAndEmptyKinds() {
        let unknown = ChatCardPromptGuide.guide(for: ["poster"])
        XCTAssertTrue(unknown.contains("没有这种卡：poster"))
        XCTAssertTrue(unknown.contains("todo"), "告诉它有哪几种")
        let all = ChatCardPromptGuide.guide(for: [])
        for s in ["card-todo：", "card-music：", "card-ask：", "mp.todo.add"] { XCTAssertTrue(all.contains(s), s) }
    }

    func testEveryKindHasASection() {
        for kind in ChatCardPromptGuide.kinds {
            XCTAssertFalse(ChatCardPromptGuide.section(kind).isEmpty, kind)
        }
    }

    // MARK: - 工具

    func testToolExecute() {
        let r = CardGuideTool.execute(inputJSON: #"{"kinds":["word"]}"#)
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("card-word："))
        let bad = CardGuideTool.execute(inputJSON: "not json")
        XCTAssertFalse(bad.isError, "参数坏了也给全部，别让模型卡住")
        XCTAssertTrue(bad.text.contains("card-todo："))
    }

    // MARK: - 什么时候只放目录

    func testCompactOnlyWhenToolIsSent() {
        XCTAssertTrue(CardGuideTool.isOffered(in: [["name": "card_guide"]]))
        XCTAssertTrue(CardGuideTool.isOffered(in: [["type": "function", "function": ["name": "card_guide"]]]))
        XCTAssertFalse(CardGuideTool.isOffered(in: [["name": "roll_dice"]]))
        XCTAssertFalse(CardGuideTool.isOffered(in: nil), "没发工具：照旧放完整说明")
    }
}
