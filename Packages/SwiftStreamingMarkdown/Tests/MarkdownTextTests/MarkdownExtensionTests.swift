// MP fork: 扩展语法（行内公式 / details / 脚注 / 缩写 / 定义列表 / 高亮 / 剧透 / 注音 / 行内 HTML）。
// 纯逻辑，iOS 与 mac 都跑（mac: `swift test --filter MarkdownExtensionTests`）。

import CoreText
import Foundation
import SwiftUI
@testable import SwiftStreamingMarkdown
import XCTest

final class MarkdownExtensionTests: XCTestCase {

  private let config = MarkdownRenderConfig.default

  private func paragraphs(_ text: String) -> [NSMutableAttributedString] {
    MarkdownParserImpl.renderables(for: text, config: config).compactMap {
      if case .paragraph(_, let content) = $0 { return content }
      return nil
    }
  }

  private func firstParagraph(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> NSMutableAttributedString {
    guard let p = paragraphs(text).first else {
      XCTFail("no paragraph", file: file, line: line)
      return NSMutableAttributedString()
    }
    return p
  }

  private func range(of needle: String, in s: NSAttributedString) -> NSRange {
    (s.string as NSString).range(of: needle)
  }

  // MARK: - 围栏

  func testFenceTrackerLongerOuterFence() {
    var tracker = MarkdownFenceTracker()
    let lines = ["text", "````markdown", "```python", "print(1)", "```", "````", "after"]
    XCTAssertEqual(lines.map { tracker.consume($0) }, [false, true, true, true, true, true, false])
  }

  func testFenceTrackerTildeAndInlineBackticks() {
    var tracker = MarkdownFenceTracker()
    XCTAssertFalse(tracker.consume("```not a fence``` inline"))
    XCTAssertTrue(tracker.consume("~~~"))
    XCTAssertTrue(tracker.consume("```"))
    XCTAssertTrue(tracker.consume("~~~~"))
    XCTAssertFalse(tracker.isInsideFence)
  }

  func testNestedFenceStaysOneCodeBlock() {
    let text = "````markdown\n```python\nx = 1\n```\n````"
    let blocks = MarkdownParserImpl.renderables(for: text, config: config)
    XCTAssertEqual(blocks.count, 1)
    guard case .codeBlock(_, let language, let code)? = blocks.first else { return XCTFail() }
    XCTAssertEqual(language, "markdown")
    XCTAssertEqual(code, "```python\nx = 1\n```\n")
  }

  /// 三个反引号包三个反引号（她的极限测试原文）：外层按推断延长，整块一个代码块
  func testSameLengthNestedFencesInferred() {
    let text = """
    好！极限测试——全部用三个反引号，不作弊：

    ```markdown
    # 这是外层代码块

    里面也有代码块：

    ```python
    def meow():
        return "喵"
    ```

    外层应该还没结束，这行还在代码块里

    ```javascript
    console.log("第二个内层代码块")
    ```

    外层结束
    ```

    ---

    来了宝宝！这是最容易炸的情况——三个 ``` 包三个 ```。
    """
    let blocks = MarkdownParserImpl.renderables(for: text, config: config)
    XCTAssertEqual(blocks.count, 4, "\(blocks)")
    guard case .codeBlock(_, let language, let code) = blocks[1] else { return XCTFail("\(blocks)") }
    XCTAssertEqual(language, "markdown")
    XCTAssertTrue(code.hasPrefix("# 这是外层代码块"))
    XCTAssertTrue(code.contains("```python\ndef meow():"))
    XCTAssertTrue(code.contains("外层应该还没结束"))
    XCTAssertTrue(code.contains("```javascript"))
    XCTAssertTrue(code.hasSuffix("外层结束\n"))
    guard case .thematicBreak = blocks[2] else { return XCTFail("\(blocks)") }
  }

  func testFenceNormalizerIdempotentAndLeavesSiblingsAlone() {
    let nested = "```md\n```py\nx\n```\n```"
    let once = MarkdownFenceNormalizer.normalize(nested)
    XCTAssertEqual(once, "````md\n```py\nx\n```\n````")
    XCTAssertEqual(MarkdownFenceNormalizer.normalize(once), once)
    let siblings = "```py\na\n```\n\n```js\nb\n```"
    XCTAssertEqual(MarkdownFenceNormalizer.normalize(siblings), siblings)
    // 流式：内层还没关，外层只加长开头，后面全留在代码里
    XCTAssertEqual(MarkdownFenceNormalizer.normalize("```md\n```py\nx"), "````md\n```py\nx")
  }

  private func blocks(_ text: String) -> [MarkdownRenderable] {
    MarkdownParserImpl.renderables(for: text, config: config)
  }

  private func containsStandaloneLink(_ renderables: [MarkdownRenderable]) -> Bool {
    renderables.contains { r in
      switch r {
      case .standaloneLink: return true
      case .orderedList(_, let items), .unorderedList(_, let items, _):
        return items.contains { containsStandaloneLink($0.children) }
      case .details(_, _, _, let children): return containsStandaloneLink(children)
      default: return false
      }
    }
  }

  func testStandaloneLinkParagraphs() {
    guard case .standaloneLink(_, let bare, let bareLabel, _)? = blocks("https://example.com/a?b=1").first else { return XCTFail() }
    XCTAssertEqual(bare.absoluteString, "https://example.com/a?b=1")
    XCTAssertNil(bareLabel)
    guard case .standaloneLink(_, let url, let label, let content)? = blocks("[标题](https://x.com/p)").first else { return XCTFail() }
    XCTAssertEqual(url.absoluteString, "https://x.com/p")
    XCTAssertEqual(label, "标题")
    XCTAssertEqual(content.string, "标题")
    guard case .standaloneLink(_, _, let autoLabel, _)? = blocks("<https://y.com>").first else { return XCTFail() }
    XCTAssertNil(autoLabel)
    guard case .standaloneLink? = blocks("[t](https://z.com \"说明\")").first else { return XCTFail() }
  }

  func testNotStandaloneLinks() {
    let citation = "[9F742443](https://example.com/?citationMarker=9F742443&citationTitle=x&citationA11yValue=x)"
    for text in ["看 https://z.com 吧", "[$NVDA](ticker://open/NVDA)", "https://a.com 和 https://b.com",
                 "- https://c.com", "1. [t](https://c.com)", "> https://d.com", "ftp://e.com/f", "https://",
                 "**https://g.com**", citation, "| a |\n|---|\n| https://h.com |",
                 "https://github.com/foo/bar这个项目不错", "https://a.com，看这个"] {
      XCTAssertFalse(containsStandaloneLink(blocks(text)), text)
    }
  }

  func testDetectorForMarkdownBlocks() {
    XCTAssertEqual(StandaloneLinkDetector.detect(markdownBlock: " https://a.com/x \n")?.url.absoluteString, "https://a.com/x")
    XCTAssertEqual(StandaloneLinkDetector.detect(markdownBlock: "[看这个](https://b.com)")?.label, "看这个")
    XCTAssertNil(StandaloneLinkDetector.detect(markdownBlock: "https://a.com\nhttps://b.com"))
    XCTAssertNil(StandaloneLinkDetector.detect(markdownBlock: "[$NVDA](ticker://open/NVDA)"))
  }

  func testCodeBlockRoutePriority() {
    XCTAssertEqual(BlockView.route(hasCustom: true), .custom)
    XCTAssertEqual(BlockView.route(hasCustom: false), .standard)
  }

  // MARK: - 行内公式

  func testInlineDollarMathRewrite() {
    XCTAssertEqual(InlineDollarMath.rewrite("质能 $E = mc^2$ 公式"), "质能 \\(E = mc^2\\) 公式")
    XCTAssertEqual(InlineDollarMath.rewrite("$$x$$ 和 $y$"), "\\(x\\) 和 \\(y\\)")
  }

  func testInlineDollarLeavesMoneyAndTickersAlone() {
    for text in ["花了 $5 和 $10", "$AAPL and $TSLA", "价格 $5.00", "转义 \\$x\\$", "`$x$` 代码", "a $ b $ c"] {
      XCTAssertEqual(InlineDollarMath.rewrite(text), text, text)
    }
  }

  func testInlineDollarSkipsFencedCode() {
    let text = "```bash\necho $HOME$PATH$x$\n```"
    XCTAssertEqual(InlineDollarMath.rewrite(text), text)
  }

  func testInlineDollarSpansForTickerLinkifier() {
    let line = "看 $E = mc^2$ 和 $AAPL 涨了"
    let spans = InlineDollarMath.spans(in: line)
    XCTAssertEqual(spans.map { String(line[$0]) }, ["$E = mc^2$"])
  }

  func testInlineDollarBecomesMathAttachment() {
    let p = firstParagraph("能量 $E = mc^2$ 守恒")
    var attachments = 0
    p.enumerateAttribute(.attachment, in: NSRange(location: 0, length: p.length)) { value, _, _ in
      if value != nil { attachments += 1 }
    }
    XCTAssertEqual(attachments, 1)
    XCTAssertFalse(p.string.contains("$"))
  }

  // MARK: - 行内 HTML

  func testMarkSubSup() {
    let p = firstParagraph("H<sub>2</sub>O 和 x<sup>2</sup>，<mark>重点</mark>")
    XCTAssertEqual(p.string, "H2O 和 x2，重点")
    let sub = range(of: "2", in: p)
    XCTAssertLessThan(p.attribute(.baselineOffset, at: sub.location, effectiveRange: nil) as? CGFloat ?? 0, 0)
    let sup = (p.string as NSString).range(of: "2", options: .backwards)
    XCTAssertGreaterThan(p.attribute(.baselineOffset, at: sup.location, effectiveRange: nil) as? CGFloat ?? 0, 0)
    XCTAssertNotNil(p.attribute(.backgroundColor, at: range(of: "重点", in: p).location, effectiveRange: nil))
  }

  func testUnknownTagsAreDroppedAndNothingLeaks() {
    let p = firstParagraph("a <span class=\"x\">b</span> c<br>d")
    XCTAssertEqual(p.string, "a b c\nd")
    XCTAssertFalse(p.string.contains("\u{E000}"))
  }

  func testUnclosedMarkAppliesToEnd() {
    let p = firstParagraph("前 <mark>流式中")
    XCTAssertEqual(p.string, "前 流式中")
    XCTAssertNotNil(p.attribute(.backgroundColor, at: range(of: "流式中", in: p).location, effectiveRange: nil))
  }

  // MARK: - 定界符

  func testDoubleEqualsHighlightAcrossBold() {
    let p = firstParagraph("这是 ==很**重要**的== 事")
    XCTAssertEqual(p.string, "这是 很重要的 事")
    XCTAssertNotNil(p.attribute(.backgroundColor, at: range(of: "重要", in: p).location, effectiveRange: nil))
    XCTAssertNil(p.attribute(.backgroundColor, at: range(of: "事", in: p).location, effectiveRange: nil))
  }

  func testHighlightIgnoresInlineCode() {
    let p = firstParagraph("比较 `a == b == c` 吧")
    XCTAssertTrue(p.string.contains("a == b == c"))
  }

  func testSpoiler() {
    let p = firstParagraph("答案是 ||42|| 哦")
    XCTAssertEqual(p.string, "答案是 42 哦")
    let at = range(of: "42", in: p).location
    let url = p.attribute(.link, at: at, effectiveRange: nil) as? URL
    XCTAssertEqual(url?.scheme, InlineExtensionURL.spoilerScheme)
    XCTAssertNotNil(p.attribute(.mpmdSpoiler, at: at, effectiveRange: nil))
  }

  // MARK: - 彩色文字（E24：{color:red}红色{/color}）

  func testColorText() {
    let p = firstParagraph("这是{color:red}红色{/color}和{color:#3366CC}蓝色{/color}")
    XCTAssertEqual(p.string, "这是红色和蓝色")
    let red = p.attribute(.foregroundColor, at: range(of: "红色", in: p).location, effectiveRange: nil) as? PlatformColor
    XCTAssertEqual(red, InlineExtensionStyle.namedColor("red"))
    let blue = p.attribute(.foregroundColor, at: range(of: "蓝色", in: p).location, effectiveRange: nil) as? PlatformColor
    XCTAssertEqual(blue.map { InlineExtensionStyle.hexComponents($0) }, [0x33, 0x66, 0xCC])
    XCTAssertNotEqual(p.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor, red)
  }

  func testColorTextLeavesUnknownAndCodeAlone() {
    XCTAssertEqual(firstParagraph("{color:banana}香蕉{/color}").string, "{color:banana}香蕉{/color}")   // 不认识的颜色原样
    XCTAssertEqual(firstParagraph("`{color:red}x{/color}`").string, "{color:red}x{/color}")            // 行内代码里不动
    XCTAssertEqual(firstParagraph("{color:red}没收尾").string, "{color:red}没收尾")
    // 颜色里套剧透：揭开后是那个颜色
    let p = firstParagraph("{color:green}绿||藏||{/color}")
    XCTAssertEqual(p.string, "绿藏")
    let hidden = p.attribute(.mpmdSpoiler, at: range(of: "藏", in: p).location, effectiveRange: nil) as? PlatformColor
    XCTAssertEqual(hidden, InlineExtensionStyle.namedColor("green"))
  }

  func testRuby() {
    let p = firstParagraph("很{漂亮|piào liang}的花")
    XCTAssertEqual(p.string, "很漂亮的花")
    let key = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
    XCTAssertNotNil(p.attribute(key, at: range(of: "漂亮", in: p).location, effectiveRange: nil))
    XCTAssertNil(p.attribute(key, at: 0, effectiveRange: nil))
    XCTAssertNotNil(p.attribute(.mpmdRuby, at: 0, effectiveRange: nil))
  }

  // MARK: - details

  func testDetailsBecomesCollapsibleBlock() {
    let text = """
    前文

    <details>
    <summary>点我看**答案**</summary>

    答案是 42

    ```python
    print(42)
    ```
    </details>

    后文
    """
    let blocks = MarkdownParserImpl.renderables(for: text, config: config)
    XCTAssertEqual(blocks.count, 3)
    guard case .details(_, let summary, let isOpen, let children) = blocks[1] else { return XCTFail("\(blocks)") }
    XCTAssertEqual(summary.string, "点我看答案")
    XCTAssertFalse(isOpen)
    XCTAssertEqual(children.count, 2)
    guard case .codeBlock(_, let language, _) = children[1] else { return XCTFail() }
    XCTAssertEqual(language, "python")
  }

  func testDetailsSingleLineAndOpen() {
    let blocks = MarkdownParserImpl.renderables(for: "<details open><summary>标题</summary>内容</details>", config: config)
    guard case .details(_, let summary, let isOpen, let children)? = blocks.first else { return XCTFail("\(blocks)") }
    XCTAssertEqual(summary.string, "标题")
    XCTAssertTrue(isOpen)
    XCTAssertEqual(children.count, 1)
  }

  // MARK: - 脚注 / 缩写 / 定义列表

  func testFootnotes() {
    let text = "正文[^a]，又一处[^b]。\n\n[^b]: 第二条\n[^a]: 第一条\n  续行"
    let out = MarkdownExtensionPreprocessor.processFootnotes(text)
    XCTAssertEqual(out, "正文<sup>1</sup>，又一处<sup>2</sup>。\n\n<small><sup>1</sup> 第一条 续行</small>\\\n<small><sup>2</sup> 第二条</small>")
  }

  func testUndefinedFootnoteLeftAlone() {
    let text = "没有定义[^x]"
    XCTAssertEqual(MarkdownExtensionPreprocessor.processFootnotes(text), text)
  }

  func testAbbreviations() {
    let text = "HTML 很常见，`HTML` 不动，[链接](https://x.com/HTML) 也不动，HTMLX 不算。\n\n*[HTML]: HyperText \"Markup\" Language"
    let out = MarkdownExtensionPreprocessor.processAbbreviations(text)
    XCTAssertEqual(out, "<abbr title=\"HyperText &quot;Markup&quot; Language\">HTML</abbr> 很常见，`HTML` 不动，[链接](https://x.com/HTML) 也不动，HTMLX 不算。\n")
    let p = firstParagraph(text)
    let url = p.attribute(.link, at: 0, effectiveRange: nil) as? URL
    XCTAssertEqual(url.flatMap(InlineExtensionURL.abbreviationTitle(from:)), "HyperText \"Markup\" Language")
  }

  func testDefinitionList() {
    let text = "苹果\n: 一种水果\n: 一家公司"
    XCTAssertEqual(MarkdownExtensionPreprocessor.processDefinitionLists(text), "**苹果**\\\n\u{3000}一种水果\\\n\u{3000}一家公司")
    let p = firstParagraph(text)
    XCTAssertEqual(p.string, "苹果\n\u{3000}一种水果\n\u{3000}一家公司")
  }

  func testPlainTextUntouched() {
    let text = "普通文字：没有扩展。a | b，{x}，=，|"
    XCTAssertEqual(MarkdownExtensionPreprocessor.process(text), text)
    XCTAssertEqual(firstParagraph(text).string, text)
  }
}
