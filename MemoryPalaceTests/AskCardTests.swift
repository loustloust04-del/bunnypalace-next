import XCTest
@testable import 记忆花园

/// 提问卡 card-ask（docs/plan-ask-inline.md）
final class AskCardTests: XCTestCase {

    func ask(_ code: String, language: String = "card-ask") -> AskCard? {
        guard case .ask(let q)? = ChatCard.parse(language: language, code: code) else { return nil }
        return q
    }

    func testParseChoiceMode() {
        let q = ask(#"{"id":"q-1a2b","question":"晚饭吃什么？","options":["火锅","面","随便"],"multi":true,"picked":[2,0]}"#)
        XCTAssertEqual(q?.id, "q-1a2b")
        XCTAssertEqual(q?.question, "晚饭吃什么？")
        XCTAssertEqual(q?.options, ["火锅", "面", "随便"])
        XCTAssertEqual(q?.multi, true)
        XCTAssertEqual(q?.isChoice, true)
        XCTAssertEqual(q?.picked, [2, 0])
        XCTAssertNil(q?.problem)
        XCTAssertEqual(ChatCard.ask(q!).kindLabel, "提问")
        XCTAssertEqual(ChatCard.ask(q!).title, "晚饭吃什么？")
    }

    func testParseQuestionMode() {
        let q = ask(#"{"id":"q-3c4d","question":"你的城市？","placeholder":"比如：上海","answer":"上海"}"#)
        XCTAssertEqual(q?.isChoice, false)
        XCTAssertEqual(q?.placeholder, "比如：上海")
        XCTAssertEqual(q?.answer, "上海")
        XCTAssertNil(q?.problem)
    }

    func testMultiDefaultsFalse() {
        XCTAssertEqual(ask(#"{"id":"q-1","question":"选一个","options":["a","b"]}"#)?.multi, false)
    }

    func testMissingOrBlankQuestionFails() {
        XCTAssertNil(ask(#"{"id":"q-1","options":["a","b"]}"#))
        XCTAssertNil(ask(#"{"id":"q-1","question":"  ","options":["a","b"]}"#))
        XCTAssertNil(ask(#"{"id":"q-1","question":"#))
    }

    func testOptionCountOutOfRangeIsProblem() {
        XCTAssertNotNil(ask(#"{"id":"q-1","question":"x","options":["a"]}"#)?.problem)
        XCTAssertNotNil(ask(#"{"id":"q-1","question":"x","options":["1","2","3","4","5","6","7"]}"#)?.problem)
        XCTAssertNil(ask(#"{"id":"q-1","question":"x","options":["1","2","3","4","5","6"]}"#)?.problem)
    }

    func testSecureRecognizedAndAnswerable() {
        let q = ask(#"{"id":"q-1","question":"密码？","secure":true}"#)
        XCTAssertEqual(q?.secure, true)
        XCTAssertNil(q?.problem)
        XCTAssertEqual(ask(#"{"id":"q-1","question":"x"}"#)?.secure, false)
    }

    func testShortAliasAsk() {
        XCTAssertTrue(ChatCard.isCardLanguage("ask"))
        XCTAssertNotNil(ask(#"{"id":"q-1","question":"x"}"#, language: "ask"))
        XCTAssertNil(ChatCard.parse(language: "ask", code: "what?"))
    }

    func testBlockTextRoundTrips() {
        let choice = ChatCard.ask(AskCard(id: "q-1", question: "吃什么", options: ["火锅", "面"]).picking([1]))
        let text = AskCard(id: "q-2", question: "城市", placeholder: "上海").answering("北京")
        for card in [choice, .ask(text)] {
            XCTAssertTrue(card.blockText.hasPrefix("```card-ask\n"))
            XCTAssertEqual(ChatCardExtractor.cards(in: "前文\n\n" + card.blockText + "\n\n后文"), [card])
        }
    }

    func testEncodingOmitsDefaults() {
        let plain = ChatCard.ask(AskCard(id: "q-2", question: "城市")).blockText
        XCTAssertFalse(plain.contains("multi"))
        XCTAssertFalse(plain.contains("secure"))
        XCTAssertFalse(plain.contains("picked"))
        XCTAssertFalse(plain.contains("answer"))
        XCTAssertTrue(ChatCard.ask(AskCard(id: "q-1", question: "x", options: ["a", "b"])).blockText.contains(#""multi":false"#))
        XCTAssertTrue(ChatCard.ask(AskCard(id: "q-3", question: "x", secure: true)).blockText.contains(#""secure":true"#))
    }

    func testPickingAndAnsweringReplaceEachOther() {
        let base = AskCard(id: "q-1", question: "x", options: ["a", "b", "c"], multi: true)
        let picked = base.picking([2, 0])
        XCTAssertEqual(picked.picked, [0, 2])
        XCTAssertEqual(picked.validPicked, [0, 2])
        XCTAssertNil(picked.answering("y").picked)
        XCTAssertEqual(AskCard(id: "q-1", question: "x", options: ["a", "b"], picked: [0, 5]).validPicked, [0])
    }

    // MARK: - 表单（docs/plan-ask-form.md）

    func testParseFormMode() {
        let q = ask(#"{"id":"q-1a2b","question":"登录服务器","fields":[{"label":" 账号 ","placeholder":"root"},{"label":"密码","secure":true,"answer":"{{secret:s-1a2b3c4d}}"}]}"#)
        XCTAssertEqual(q?.isForm, true)
        XCTAssertEqual(q?.isChoice, false)
        XCTAssertNil(q?.problem)
        XCTAssertEqual(q?.fields, [
            AskCard.Field(label: "账号", placeholder: "root"),
            AskCard.Field(label: "密码", secure: true, answer: "{{secret:s-1a2b3c4d}}"),
        ])
        XCTAssertNil(ask(#"{"id":"q-1","question":"x"}"#)?.fields)
        XCTAssertEqual(ask(#"{"id":"q-1","question":"x"}"#)?.isForm, false)
    }

    func testFormRoundTripsAndOmitsDefaults() {
        let form = AskCard(id: "q-1", question: "登录服务器",
                           fields: [.init(label: "账号", placeholder: "root"), .init(label: "密码", secure: true)])
            .filling(["root", "{{secret:s-1a2b3c4d}}"])
        XCTAssertEqual(form.fields?.map(\.answer), ["root", "{{secret:s-1a2b3c4d}}"])
        let card = ChatCard.ask(form)
        XCTAssertEqual(ChatCardExtractor.cards(in: card.blockText), [card])
        XCTAssertEqual(card.blockText.components(separatedBy: #""secure":true"#).count, 2)
        XCTAssertFalse(card.blockText.contains(#""secure":false"#))
        XCTAssertFalse(ChatCard.ask(AskCard(id: "q-2", question: "城市")).blockText.contains("fields"))
    }

    func testFieldCountAndLabelProblems() {
        XCTAssertNotNil(ask(#"{"id":"q-1","question":"x","fields":[]}"#)?.problem)
        let seven = (1...7).map { #"{"label":"f\#($0)"}"# }.joined(separator: ",")
        XCTAssertNotNil(ask(#"{"id":"q-1","question":"x","fields":["# + seven + "]}")?.problem)
        let six = (1...6).map { #"{"label":"f\#($0)"}"# }.joined(separator: ",")
        XCTAssertNil(ask(#"{"id":"q-1","question":"x","fields":["# + six + "]}")?.problem)
        XCTAssertNotNil(ask(#"{"id":"q-1","question":"x","fields":[{"label":"账号"},{"label":"  "}]}"#)?.problem)
        XCTAssertNotNil(ask(#"{"id":"q-1","question":"x","fields":[{"placeholder":"没名字"}]}"#)?.problem)
    }

    func testOptionsWinOverFields() {
        let q = ask(#"{"id":"q-1","question":"x","options":["a","b"],"fields":[]}"#)
        XCTAssertEqual(q?.isChoice, true)
        XCTAssertEqual(q?.isForm, false)
        XCTAssertNil(q?.problem)
    }

    // MARK: - 网站（docs/plan-secure-ask-sheet.md）

    func testSiteParsesAndDisplaysWithoutScheme() {
        let q = ask(#"{"id":"q-1","question":"登录","fields":[{"label":"密码","secure":true}],"site":"https://account.proton.me/"}"#)
        XCTAssertEqual(q?.site, "https://account.proton.me/")
        XCTAssertEqual(q?.siteDisplay, "account.proton.me")
        XCTAssertNil(q?.problem)
        XCTAssertEqual(AskCard(id: "q-2", question: "x", secure: true, site: "http://a.com/b/").siteDisplay, "a.com/b")
        XCTAssertEqual(AskCard(id: "q-2", question: "x", secure: true, site: "a.com").siteDisplay, "a.com")
        XCTAssertNil(AskCard(id: "q-2", question: "x", secure: true, site: "  ").siteDisplay)
        XCTAssertNil(ask(#"{"id":"q-1","question":"x","secure":true}"#)?.site)
    }

    func testSiteRoundTripsAndOmittedByDefault() {
        let card = ChatCard.ask(AskCard(id: "q-1", question: "密码", secure: true, site: "https://account.proton.me")
            .answering("{{secret:s-1a2b3c4d}}"))
        XCTAssertTrue(card.blockText.contains(#""site":"https://account.proton.me""#))
        XCTAssertEqual(ChatCardExtractor.cards(in: card.blockText), [card])
        XCTAssertFalse(ChatCard.ask(AskCard(id: "q-2", question: "城市")).blockText.contains("site"))
    }

    func testPromptGuideCoversAsk() {
        for s in ["card-ask", "提问 q-", "picked", "answer", "fields"] {
            XCTAssertTrue(ChatCardPromptGuide.text.contains(s), s)
        }
    }
}
