import XCTest
@testable import 记忆花园

/// AI 发表情包（plan-AI表情包）：清单文案、块 → 记号、发回模型的文字、流式藏块
final class MemeIntentWriterTests: XCTestCase {

    private let a = UUID(), b = UUID()
    private func lookup(_ name: String) -> UUID? { ["馋了": a, "晚安": b][name] }

    func testHintListsNamesOnceInOrder() throws {
        XCTAssertNil(MemeIntentWriter.hintText(names: []))
        XCTAssertNil(MemeIntentWriter.hintText(names: ["", "  "]))
        let hint = try XCTUnwrap(MemeIntentWriter.hintText(names: ["馋了", "晚安", "馋了"]))
        XCTAssertTrue(hint.contains("能用的：馋了、晚安\n"), hint)
        XCTAssertTrue(hint.contains("```meme\n名字\n```"))
        XCTAssertEqual(hint, MemeIntentWriter.hintText(names: ["馋了", "晚安"]))
    }

    func testFenceBecomesOwnParagraphToken() {
        let out = MemeIntentWriter.resolve("好呀\n```meme\n馋了\n```\n那就说定了", lookup: lookup)
        XCTAssertEqual(out, "好呀\n\n\(MemeToken.make(a))\n\n那就说定了")
        XCTAssertEqual(BubbleModeRow.splitBlocks(out).count, 3)
    }

    func testFenceVariantsAndMany() {
        XCTAssertEqual(MemeIntentWriter.resolve("```meme 晚安```", lookup: lookup), MemeToken.make(b))
        XCTAssertEqual(MemeIntentWriter.resolve("```meme\n  馋了 \n```\n\n```meme\n晚安\n```", lookup: lookup),
                       "\(MemeToken.make(a))\n\n\(MemeToken.make(b))")
    }

    func testUnknownNameStaysVisible() {
        XCTAssertEqual(MemeIntentWriter.resolve("嗯\n\n```meme\n不存在\n```", lookup: lookup), "嗯\n\n〖表情包：不存在〗")
    }

    func testBracketFallbackOnlyWholeParagraph() {
        XCTAssertEqual(MemeIntentWriter.resolve("嗯\n〖表情包：馋了——眯眼〗", lookup: lookup), "嗯\n\n\(MemeToken.make(a))")
        XCTAssertEqual(MemeIntentWriter.resolve("我想发〖表情包：馋了〗给你", lookup: lookup), "我想发〖表情包：馋了〗给你")
        XCTAssertEqual(MemeIntentWriter.resolve("〖表情包：不存在〗", lookup: lookup), "〖表情包：不存在〗")
    }

    func testPlainTextUntouched() {
        let s = "```swift\nlet x = 1\n```\n\n普通的话"
        XCTAssertEqual(MemeIntentWriter.resolve(s, lookup: lookup), s)
    }

    func testTextFormForModelAndCopy() {
        let meme = ChatMeme(id: a, name: "馋了", detail: "眯眼舔嘴", fileName: "x.png", mimeType: "image/png", profileId: "p")
        let content = "好呀\n\n\(MemeToken.make(a))\n\n\(MemeToken.make(b))"
        let fetch: (UUID) -> ChatMeme? = { $0 == self.a ? meme : nil }
        XCTAssertEqual(MemeIntentWriter.textForm(content, detail: true, fetch: fetch), "好呀\n\n〖表情包：馋了——眯眼舔嘴〗\n\n〖表情包〗")
        XCTAssertEqual(MemeIntentWriter.textForm(content, detail: false, fetch: fetch), "好呀\n\n〖表情包：馋了〗\n\n〖表情包〗")
        XCTAssertEqual(MemeIntentWriter.textForm("没有记号", detail: true, fetch: fetch), "没有记号")
    }

    func testStreamingHidesMemeBlock() {
        XCTAssertEqual(MemeIntentWriter.visible("```meme\n馋了\n```"), "")
        XCTAssertEqual(MemeIntentWriter.visible("晚安"), "晚安")
    }

    func testPickPrefersRecentlySentThenOldest() {
        let old = ChatMeme(name: "笑", fileName: "1", mimeType: "image/png", profileId: "p")
        old.createdAt = Date(timeIntervalSince1970: 1)
        let new = ChatMeme(name: "笑", fileName: "2", mimeType: "image/png", profileId: "p")
        new.createdAt = Date(timeIntervalSince1970: 2)
        XCTAssertEqual(MemeIntentWriter.pick(named: "笑", in: [new, old])?.id, old.id)
        new.lastSentAt = Date()
        XCTAssertEqual(MemeIntentWriter.pick(named: "笑", in: [old, new])?.id, new.id)
        XCTAssertNil(MemeIntentWriter.pick(named: "哭", in: [old, new]))
    }
}
