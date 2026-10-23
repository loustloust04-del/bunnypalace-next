import XCTest
import SwiftUI
@testable import 记忆花园

/// 群聊 UIKit 化（plan-group-room-uikit）：泡形路径 + markdown → NSAttributedString
final class GroupRoomUIKitTests: XCTestCase {

    // MARK: - BubbleTailPath

    func testTailPathMatchesSwiftUIShapeBounds() {
        let rect = CGRect(x: 10, y: 20, width: 180, height: 64)
        for isUser in [true, false] {
            for hasTail in [true, false] {
                let ui = BubbleTailPath.cgPath(in: rect, isUser: isUser, radius: 23, hasTail: hasTail).boundingBoxOfPath
                let swiftUI = BubbleTailShape(isUser: isUser, radius: 23, hasTail: hasTail).path(in: rect).boundingRect
                XCTAssertEqual(ui.minX, swiftUI.minX, accuracy: 0.001, "isUser=\(isUser) hasTail=\(hasTail)")
                XCTAssertEqual(ui.minY, swiftUI.minY, accuracy: 0.001)
                XCTAssertEqual(ui.maxX, swiftUI.maxX, accuracy: 0.001)
                XCTAssertEqual(ui.maxY, swiftUI.maxY, accuracy: 0.001)
            }
        }
    }

    func testTailPathWithoutTailIsBodyOnly() {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 50)
        XCTAssertEqual(BubbleTailPath.cgPath(in: rect, isUser: true, radius: 23, hasTail: false).boundingBoxOfPath, rect)
    }

    func testTailScaleShrinksTailOnly() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 80)
        let full = BubbleTailPath.cgPath(in: rect, isUser: true, radius: 23, hasTail: true).boundingBoxOfPath
        let small = BubbleTailPath.cgPath(in: rect, isUser: true, radius: 23, hasTail: true, tailScale: 0.8).boundingBoxOfPath
        // 尾巴伸出主体底边的那一截按 0.8 缩；主体不动
        XCTAssertGreaterThan(full.maxY, rect.maxY)
        XCTAssertEqual(small.maxY - rect.maxY, (full.maxY - rect.maxY) * 0.8, accuracy: 0.01)
        XCTAssertEqual(small.minY, rect.minY)
        XCTAssertEqual(small.maxX, rect.maxX, accuracy: 0.001)
    }

    // MARK: - 本机表情回应

    func testReactionToggleAddsRemovesAndIsolates() {
        let suite = "GroupRoomUIKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = Page0LocalState(defaults: defaults, profileId: "floor")
        state.toggleReaction("👍", messageId: "m1", roomId: "r1")
        state.toggleReaction("🔥", messageId: "m1", roomId: "r1")
        state.toggleReaction("❤️", messageId: "m2", roomId: "r2")
        XCTAssertEqual(state.reactions["r1"]?["m1"], ["👍", "🔥"])
        // 同一个再点一次 = 取消；空了整条移除
        state.toggleReaction("👍", messageId: "m1", roomId: "r1")
        XCTAssertEqual(Page0LocalState(defaults: defaults, profileId: "floor").reactions["r1"]?["m1"], ["🔥"])
        state.toggleReaction("🔥", messageId: "m1", roomId: "r1")
        XCTAssertNil(state.reactions["r1"])
        XCTAssertEqual(state.reactions["r2"]?["m2"], ["❤️"])
        XCTAssertTrue(Page0LocalState(defaults: defaults, profileId: "other").reactions.isEmpty)
    }

    // MARK: - Markdown

    private typealias R = GroupMarkdownRenderer
    private let style = R.Style(
        font: R.MDFont.systemFont(ofSize: 15),
        textColor: .black,
        accentColor: .systemGreen,
        codeBackground: .lightGray,
        lineSpacing: 5,
        quoteColor: .gray
    )

    private func render(_ text: String, handles: Set<String> = []) -> NSAttributedString {
        R.render(text, style: style, handles: handles)
    }

    private func attrs(_ s: NSAttributedString, at substring: String) -> [NSAttributedString.Key: Any] {
        let range = (s.string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "找不到「\(substring)」于「\(s.string)」")
        guard range.location != NSNotFound else { return [:] }
        return s.attributes(at: range.location, effectiveRange: nil)
    }

    private func font(_ s: NSAttributedString, at substring: String) -> R.MDFont? {
        attrs(s, at: substring)[.font] as? R.MDFont
    }

    private func isMonospaced(_ f: R.MDFont?) -> Bool {
        guard let f else { return false }
        #if canImport(UIKit)
        return f.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        #else
        return f.fontDescriptor.symbolicTraits.contains(.monoSpace)
        #endif
    }

    func testPlainTextUnchanged() {
        let s = render("就是一句普通的话。")
        XCTAssertEqual(s.string, "就是一句普通的话。")
        XCTAssertEqual(font(s, at: "普通")?.pointSize, 15)
    }

    func testBold() {
        let s = render("这是 **重点** 内容")
        XCTAssertEqual(s.string, "这是 重点 内容")
        XCTAssertTrue(R.isBold(font(s, at: "重点")!))
        XCTAssertFalse(R.isBold(font(s, at: "内容")!))
    }

    func testItalicStarAndUnderscore() {
        let s = render("*斜体一* 和 _斜体二_")
        XCTAssertEqual(s.string, "斜体一 和 斜体二")
        for word in ["斜体一", "斜体二"] {
            let a = attrs(s, at: word)
            let italic = (a[.font] as? R.MDFont).map(R.isItalic) == true || a[.obliqueness] != nil
            XCTAssertTrue(italic, word)
        }
        XCTAssertNil(attrs(s, at: "和")[.obliqueness])
    }

    func testSnakeCaseNotItalic() {
        XCTAssertEqual(render("snake_case_name 不是斜体").string, "snake_case_name 不是斜体")
    }

    func testInlineCode() {
        let s = render("运行 `xcodegen generate` 就好")
        XCTAssertEqual(s.string, "运行 xcodegen generate 就好")
        XCTAssertTrue(isMonospaced(font(s, at: "xcodegen")))
        XCTAssertNotNil(attrs(s, at: "xcodegen")[.backgroundColor])
        XCTAssertNil(attrs(s, at: "就好")[.backgroundColor])
    }

    func testMarkdownLink() {
        let s = render("看 [文档](https://example.com/a) 吧")
        XCTAssertEqual(s.string, "看 文档 吧")
        XCTAssertEqual(attrs(s, at: "文档")[.link] as? URL, URL(string: "https://example.com/a"))
        XCTAssertNil(attrs(s, at: "吧")[.link])
    }

    func testBareLinkTrimsTrailingPunctuation() {
        let s = render("地址是 https://example.com/x?y=1。然后")
        XCTAssertEqual(attrs(s, at: "https")[.link] as? URL, URL(string: "https://example.com/x?y=1"))
        XCTAssertNil(attrs(s, at: "然后")[.link])
        let t = render("见 https://example.com.")
        XCTAssertEqual(attrs(t, at: "https")[.link] as? URL, URL(string: "https://example.com"))
    }

    func testUnorderedListHangingIndent() {
        let s = render("- 第一项\n* 第二项")
        XCTAssertEqual(s.string, "•\t第一项\n•\t第二项")
        let para = attrs(s, at: "第二项")[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(para)
        XCTAssertGreaterThan(para?.headIndent ?? 0, 0)
        XCTAssertEqual(para?.firstLineHeadIndent, 0)
        XCTAssertEqual(para?.tabStops.first?.location, para?.headIndent)
    }

    func testOrderedList() {
        let s = render("1. 先做这个\n2) 再做那个")
        XCTAssertEqual(s.string, "1.\t先做这个\n2.\t再做那个")
        XCTAssertGreaterThan((attrs(s, at: "先做")[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0, 0)
    }

    func testFencedCodeBlock() {
        let s = render("```swift\nlet a = 1\nprint(a)\n```")
        XCTAssertEqual(s.string, "let a = 1\nprint(a)")
        let f = font(s, at: "print")
        XCTAssertTrue(isMonospaced(f))
        XCTAssertLessThan(f?.pointSize ?? 99, 15)
        XCTAssertNotNil(attrs(s, at: "let a")[.backgroundColor])
        // 代码里的 **、链接、@ 都不转
        let raw = render("```\n**不加粗** @xiaoke https://a.com\n```", handles: ["xiaoke"])
        XCTAssertEqual(raw.string, "**不加粗** @xiaoke https://a.com")
        XCTAssertNil(attrs(raw, at: "https")[.link])
        XCTAssertNotEqual(attrs(raw, at: "@xiaoke")[.foregroundColor] as? R.MDColor, style.accentColor)
    }

    func testUnclosedFenceStillCode() {
        let s = render("```\nhalf")
        XCTAssertEqual(s.string, "half")
        XCTAssertTrue(isMonospaced(font(s, at: "half")))
    }

    func testHeadingBoldNotHuge() {
        let s = render("## 小标题")
        XCTAssertEqual(s.string, "小标题")
        let f = font(s, at: "小标题")!
        XCTAssertTrue(R.isBold(f))
        XCTAssertGreaterThanOrEqual(f.pointSize, 15)
        XCTAssertLessThanOrEqual(f.pointSize, 15 * 1.1)
        XCTAssertEqual(render("#标签").string, "#标签")
    }

    func testMentionOnlyForMembers() {
        let s = render("交给 @developer 和 @nobody 吧", handles: ["developer"])
        XCTAssertEqual(attrs(s, at: "@developer")[.foregroundColor] as? R.MDColor, style.accentColor)
        XCTAssertTrue(R.isBold(font(s, at: "@developer")!))
        XCTAssertEqual(attrs(s, at: "@nobody")[.foregroundColor] as? R.MDColor, style.textColor)
        XCTAssertFalse(R.isBold(font(s, at: "@nobody")!))
    }

    func testTableFormulaHTMLKeptRaw() {
        let table = "| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(render(table).string, table)
        XCTAssertEqual(render("$E=mc^2$").string, "$E=mc^2$")
        XCTAssertEqual(render("<b>html</b>").string, "<b>html</b>")
    }

    func testPlainForOwnMessagesOnlyHighlightsMentions() {
        let s = R.plain("**不转** @product 看看", style: style, handles: ["product"])
        XCTAssertEqual(s.string, "**不转** @product 看看")
        XCTAssertEqual(attrs(s, at: "@product")[.foregroundColor] as? R.MDColor, style.accentColor)
        XCTAssertFalse(R.isBold(font(s, at: "不转")!))
    }

    func testQuoteLineMutedSmallerIndented() {
        let s = render("> 小克：看了一下 **文件夹**\n好的收到")
        XCTAssertEqual(s.string, "小克：看了一下 文件夹\n好的收到")
        let a = attrs(s, at: "看了一下")
        XCTAssertEqual(a[R.quoteKey] as? Bool, true)
        XCTAssertEqual(a[.foregroundColor] as? R.MDColor, style.quoteColor)
        XCTAssertLessThan((a[.font] as? R.MDFont)?.pointSize ?? 99, 15)
        XCTAssertEqual((a[.paragraphStyle] as? NSParagraphStyle)?.headIndent, R.quoteIndent)
        XCTAssertEqual((a[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent, R.quoteIndent)
        // 引用里的行内 markdown 照转
        XCTAssertTrue(R.isBold(font(s, at: "文件夹")!))
        // 引用下面的正文不受影响
        XCTAssertNil(attrs(s, at: "好的")[R.quoteKey])
        XCTAssertEqual(attrs(s, at: "好的")[.foregroundColor] as? R.MDColor, style.textColor)
        XCTAssertEqual(render(">没空格也算").string, "没空格也算")
    }

    func testPlainOwnMessageRendersReplyQuote() {
        let s = R.plain("> 小克：原话 **不转**\n@product 你看", style: style, handles: ["product"])
        XCTAssertEqual(s.string, "小克：原话 **不转**\n@product 你看")
        XCTAssertEqual(attrs(s, at: "原话")[R.quoteKey] as? Bool, true)
        XCTAssertEqual(attrs(s, at: "原话")[.foregroundColor] as? R.MDColor, style.quoteColor)
        XCTAssertNil(attrs(s, at: "你看")[R.quoteKey])
        XCTAssertEqual(attrs(s, at: "@product")[.foregroundColor] as? R.MDColor, style.accentColor)
    }

    func testQuoteBlockMergesIntoNextBubble() {
        let blocks = BubbleModeRow.splitBlocks("> 小克：原话\n\n我的回复\n\n第二段")
        XCTAssertEqual(R.mergingQuoteBlocks(blocks), ["> 小克：原话\n我的回复", "第二段"])
        // 只有引用没有下文：原样一段
        XCTAssertEqual(R.mergingQuoteBlocks(["> 只有引用"]), ["> 只有引用"])
        XCTAssertEqual(R.mergingQuoteBlocks(["正文", "> 结尾引用"]), ["正文", "> 结尾引用"])
    }

    func testReplyQuoteSnippet() {
        XCTAssertEqual(AgoraViewModel.replyQuote(name: "小克", content: "看了一下\n文件夹  在这"),
                       "> 小克：看了一下 文件夹 在这\n\n")
        // 原话本身带引用（回复的回复）：去掉那层；超长截断加省略号
        let long = String(repeating: "字", count: 70)
        XCTAssertEqual(AgoraViewModel.replySnippet("> 更早的引用\n\n" + long, limit: 60),
                       String(repeating: "字", count: 60) + "…")
        XCTAssertEqual(AgoraViewModel.replySnippet("短", limit: 40), "短")
    }

    func testEscapedMarkers() {
        XCTAssertEqual(render(#"\*不是斜体\*"#).string, "*不是斜体*")
    }
}
