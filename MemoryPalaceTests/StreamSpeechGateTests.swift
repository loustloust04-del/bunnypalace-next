import XCTest
@testable import 记忆花园

/// V4a：通话流式朗读闸——区域状态机 / 构造扣留清洗 / 断句 / flush
final class StreamSpeechGateTests: XCTestCase {

    /// 按片喂完再 flush，收集全部放出的句子
    private func run(_ pieces: [String]) -> [String] {
        var gate = StreamSpeechGate()
        var out: [String] = []
        for p in pieces { out += gate.feed(p) }
        out += gate.flush()
        return out
    }

    private func charByChar(_ text: String) -> [String] { run(text.map(String.init)) }
    private func scalarByScalar(_ text: String) -> [String] { run(text.unicodeScalars.map { String($0) }) }

    // MARK: - 断句

    func testCharByCharSentences() {
        XCTAssertEqual(charByChar("你好呀。今天怎么样？我很好！"), ["你好呀。", "今天怎么样？", "我很好！"])
    }

    func testHoldsUntilSentenceEnd() {
        var gate = StreamSpeechGate()
        XCTAssertEqual(gate.feed("我在想"), [])
        XCTAssertEqual(gate.feed("一件事。然"), ["我在想一件事。"])
        XCTAssertEqual(gate.feed("后"), [])
        XCTAssertEqual(gate.flush(), ["然后"])
    }

    func testSentenceEndAtBufferTailWaitsForClosingQuote() {
        var gate = StreamSpeechGate()
        XCTAssertEqual(gate.feed("他说：“好啊！"), [], "句末在结尾先等一个字")
        XCTAssertEqual(gate.feed("”然后"), ["他说：“好啊！”"])
        XCTAssertEqual(gate.flush(), ["然后"])
        XCTAssertEqual(charByChar("他说：“好啊！”然后走了。"), ["他说：“好啊！”", "然后走了。"])
    }

    func testMultipleSentencesInOneDelta() {
        var gate = StreamSpeechGate()
        XCTAssertEqual(gate.feed("第一句。第二句！第三"), ["第一句。", "第二句！"])
        XCTAssertEqual(gate.flush(), ["第三"])
    }

    func testNewlineAndEllipsisAreBoundaries() {
        XCTAssertEqual(charByChar("嗯……\n我想想"), ["嗯……", "我想想"])
    }

    func testMixedChineseEnglish() {
        XCTAssertEqual(charByChar("Hello world. 你好！This is v4.5 model? Yes"),
                       ["Hello world.", "你好！", "This is v4.5 model?", "Yes"])
    }

    func testPunctuationOnlyPiecesDropped() {
        XCTAssertEqual(charByChar("好。\n\n"), ["好。"])
        XCTAssertEqual(charByChar("……\n！"), [])
    }

    // MARK: - 硬切

    func testHardCutWithoutPunctuation() {
        let out = charByChar(String(repeating: "啊", count: 500))
        XCTAssertEqual(out.map(\.count), [220, 220, 60])
    }

    func testHardCutPrefersComma() {
        let text = String(repeating: "字", count: 100) + "，" + String(repeating: "字", count: 200)
        let out = charByChar(text)
        XCTAssertEqual(out.map(\.count), [101, 200])
        XCTAssertTrue(out[0].hasSuffix("，"))
    }

    func testLongSentenceInOneDeltaAlsoCut() {
        let body = String(repeating: "长", count: 2100)
        var gate = StreamSpeechGate()
        let out = gate.feed(body + "。\n后面")
        XCTAssertTrue(out.allSatisfy { $0.count <= StreamSpeechGate.hardLimit }, "整包一句几千字也切到上限内")
        XCTAssertEqual(out.joined(), body + "。")
        XCTAssertEqual(gate.flush(), ["后面"])
    }

    func testLongSentenceWithCommasCutAtCommas() {
        let clause = String(repeating: "字", count: 150) + "，"
        let out = run([String(repeating: clause, count: 4) + "完。"])
        XCTAssertTrue(out.allSatisfy { $0.count <= StreamSpeechGate.hardLimit })
        XCTAssertTrue(out.dropLast().allSatisfy { $0.hasSuffix("，") }, "优先在逗号切")
        XCTAssertEqual(out.joined(), String(repeating: clause, count: 4) + "完。")
    }

    // MARK: - emoji

    func testEmojiNotSplitAcrossScalarDeltas() {
        let text = "早安☀️！一起去看👨‍👩‍👧‍👦吗？"
        XCTAssertEqual(scalarByScalar(text), ["早安☀️！", "一起去看👨‍👩‍👧‍👦吗？"])
    }

    func testHardCutCountsCharactersNotUTF16() {
        let text = String(repeating: "好😀", count: 150)
        let out = scalarByScalar(text)
        XCTAssertEqual(out.map(\.count), [220, 80])
        XCTAssertEqual(out.joined(), text, "切点落在 Character 边界，拼回原文")
    }

    // MARK: - 代码块

    func testFenceAcrossDeltas() {
        let out = run(["好的，看这个：\n``", "`swift\nlet a = 1。\n", "``", "`\n代码写完了。"])
        XCTAssertEqual(out, ["好的，看这个：", "代码写完了。"])
    }

    func testVoiceAndBookNoteFencesNotSpoken() {
        let text = "嗯，我给你录了一段。\n```voice\n[whispering] 晚安。\n```\n早点睡！\n```book-note\n批注内容。\n```\n明天见。"
        XCTAssertEqual(charByChar(text), ["嗯，我给你录了一段。", "早点睡！", "明天见。"])
        XCTAssertEqual(run([text]), ["嗯，我给你录了一段。", "早点睡！", "明天见。"])
    }

    func testTextBeforeFenceReleasedWithoutWaitingForFenceEnd() {
        var gate = StreamSpeechGate()
        XCTAssertEqual(gate.feed("我录了一段：\n```voice\n很长的表演"), ["我录了一段："])
    }

    func testFenceInterruptsSentence() {
        XCTAssertEqual(charByChar("我写了段代码```js\nx()\n```你看看。"), ["我写了段代码", "你看看。"])
    }

    func testFlushDropsUnclosedFence() {
        XCTAssertEqual(charByChar("先说一句\n```python\nprint(1)。"), ["先说一句"])
    }

    // MARK: - 思考

    func testAngleThinkingAcrossDeltas() {
        XCTAssertEqual(run(["<thin", "king>我先想想要说什么。</thi", "nking>好的。"]), ["好的。"])
    }

    func testBracketThinkingCharByChar() {
        XCTAssertEqual(charByChar("[thinking]内心戏。[/thinking]说出口的话。"), ["说出口的话。"])
    }

    func testThinkingCaseInsensitiveAndShortTag() {
        XCTAssertEqual(charByChar("<Thinking>嗯。</THINKING>你好。<think>再想。</think>再见。"), ["你好。", "再见。"])
    }

    func testAllThinkingReleasesNothing() {
        XCTAssertEqual(charByChar("<thinking>全是思考，没有正文。"), [])
        XCTAssertEqual(charByChar("[thinking]只有思考。[/thinking]"), [])
    }

    // MARK: - 清洗

    func testMarkdownCleanedCharByChar() {
        let text = "**重点**是[这个链接](https://a.com/x?y=1)，还有![图](http://img.png)和 `code`。\n# 标题\n- 列表项一\n> 引用一句"
        let expected = ["重点是这个链接，还有和 code。", "标题", "列表项一", "引用一句"]
        XCTAssertEqual(charByChar(text), expected)
        XCTAssertEqual(run([text]), expected)
    }

    func testBareURLNotSpokenAndQueryMarkNotBoundary() {
        XCTAssertEqual(charByChar("看这里 https://example.com/a?b=1&c=2 挺好的。"), ["看这里 挺好的。"])
    }

    func testBracketWithoutLinkKept() {
        XCTAssertEqual(charByChar("[笑] 你真逗。"), ["[笑] 你真逗。"])
    }

    // MARK: - flush / reset

    func testFlushResetsForNextSegment() {
        var gate = StreamSpeechGate()
        _ = gate.feed("<thinking>没关")
        XCTAssertEqual(gate.flush(), [], "还在思考里的丢弃")
        XCTAssertEqual(gate.feed("新的一句。"), [])
        XCTAssertEqual(gate.flush(), ["新的一句。"], "flush 后不再处于思考区")
    }

    func testResetDropsEverything() {
        var gate = StreamSpeechGate()
        _ = gate.feed("半句话")
        gate.reset()
        XCTAssertEqual(gate.flush(), [])
    }

    func testPartialMarkerHeldThenReleasedOnFlush() {
        var gate = StreamSpeechGate()
        XCTAssertEqual(gate.feed("就这样<"), [])
        XCTAssertEqual(gate.flush(), ["就这样<"])
    }
}
