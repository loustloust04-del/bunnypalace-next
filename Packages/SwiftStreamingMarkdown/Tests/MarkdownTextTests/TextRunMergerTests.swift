// MP fork: 段落簇合并器（mergesTextRuns）。纯模型层，两端都跑（mac: `swift test --filter TextRunMerger`）。
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import SwiftStreamingMarkdown
import Testing

@Suite("Text run merger")
struct TextRunMergerTests {
  private let mergeOn = MarkdownRenderConfig(mergesTextRuns: true)

  private func blocks(_ text: String, _ config: MarkdownRenderConfig) -> [MarkdownRenderable] {
    MarkdownParserImpl.renderables(for: text, config: config)
  }

  private func kinds(_ blocks: [MarkdownRenderable]) -> [String] {
    blocks.map {
      switch $0 {
      case .paragraph: return "p"
      case .heading: return "h"
      case .textRun: return "run"
      case .codeBlock: return "code"
      case .standaloneLink: return "link"
      case .details: return "details"
      case .unorderedList, .orderedList: return "list"
      case .blockQuote: return "quote"
      case .latex: return "math"
      case .table: return "table"
      case .thematicBreak: return "hr"
      }
    }
  }

  private func run(_ block: MarkdownRenderable) -> NSMutableAttributedString? {
    if case .textRun(_, let content) = block { return content }
    return nil
  }

  private func style(_ s: NSAttributedString, at index: Int) -> NSParagraphStyle? {
    s.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
  }

  private func blockEnd(_ s: NSAttributedString, at index: Int) -> TextRunBlockEnd? {
    s.attribute(.mpmdTextRunBlockEnd, at: index, effectiveRange: nil) as? TextRunBlockEnd
  }

  private func leafStart(_ s: NSAttributedString, at index: Int) -> TextRunLeafStart? {
    s.attribute(.mpmdTextRunLeafStart, at: index, effectiveRange: nil) as? TextRunLeafStart
  }

  @Test("off by default: the block list is untouched")
  func offByDefault() {
    let text = "第一段\n\n## 标题\n\n第二段"
    #expect(kinds(blocks(text, .default)) == ["p", "h", "p"])
    #expect(MarkdownRenderConfig.default.mergesTextRuns == false)
  }

  @Test("consecutive paragraphs, headings and lists merge; other blocks are boundaries; lone paragraphs stay")
  func boundaries() {
    let text = """
    第一段

    ## 标题

    第二段

    ```swift
    let a = 1
    ```

    孤零零的一段

    - 列表项

    第三段

    https://example.com/a

    第四段

    第五段

    > 引用

    第六段
    """
    #expect(kinds(blocks(text, mergeOn)) == ["run", "code", "run", "link", "run", "quote", "p"])
  }

  @Test("run content: blocks joined by \\n, id of the first block, plain text unchanged")
  func content() throws {
    let off = blocks("第一段\n\n## 标题\n\n第二段", .default)
    let on = blocks("第一段\n\n## 标题\n\n第二段", mergeOn)
    let content = try #require(run(on[0]))
    #expect(content.string == "第一段\n标题\n第二段")
    #expect(on[0].id == off[0].id)
  }

  @Test("styles: paragraphs get line spacing 5, headings none; block spacing written so the next text top lands 30 below")
  func styles() throws {
    let content = try #require(run(blocks("第一段\n\n## 标题\n\n第二段\n\n第三段", mergeOn)[0]))
    let s = content.string as NSString
    let heading = s.range(of: "标题").location
    let second = s.range(of: "第二段").location
    let third = s.range(of: "第三段").location
    #expect(style(content, at: 0)?.lineSpacing == 5)
    #expect(style(content, at: 0)?.alignment == .left)
    #expect(style(content, at: heading)?.lineSpacing ?? 0 == 0)
    #expect(style(content, at: second)?.lineSpacing == 5)
    // 段距 = 块距 - 下一块自己的行距（TextKit 2 在非首段第一行上方加本段行距）
    #expect(style(content, at: 0)?.paragraphSpacing == 30)          // 下一块是标题（行距 0）
    #expect(style(content, at: heading)?.paragraphSpacing == 25)    // 下一块是段落（行距 5）
    #expect(style(content, at: second)?.paragraphSpacing == 25)
    #expect(style(content, at: third)?.paragraphSpacing == 0)
    // 结束标记：每块的分隔符上 + 末块最后一个字上
    #expect(blockEnd(content, at: heading - 1) == TextRunBlockEnd(leafIndex: 0, gapAfter: 30, isLast: false))
    #expect(blockEnd(content, at: second - 1) == TextRunBlockEnd(leafIndex: 1, gapAfter: 25, isLast: false))
    #expect(blockEnd(content, at: s.length - 1) == TextRunBlockEnd(leafIndex: 3, gapAfter: 0, isLast: true))
    #expect(blockEnd(content, at: 0) == nil)
    // 开头标记：每块第一个字上，带本段行距（簇的第一段 0）
    #expect(leafStart(content, at: 0) == TextRunLeafStart(leafIndex: 0, topLineSpacing: 0, leadingInset: 0, marker: nil))
    #expect(leafStart(content, at: heading) == TextRunLeafStart(leafIndex: 1, topLineSpacing: 0, leadingInset: 0, marker: nil))
    #expect(leafStart(content, at: second) == TextRunLeafStart(leafIndex: 2, topLineSpacing: 5, leadingInset: 0, marker: nil))
    #expect(leafStart(content, at: heading - 1) == nil)   // 分隔符不带
    #expect(TextRunLayoutDelegate.isTextRun(content))
  }

  @Test("soft breaks inside a block: only the block's last paragraph gets the block spacing")
  func softBreaks() throws {
    let content = try #require(run(blocks("第一行\n第二行\n\n下一段", mergeOn)[0]))
    let s = content.string as NSString
    #expect(content.string == "第一行\n第二行\n下一段")
    #expect(style(content, at: 0)?.paragraphSpacing == 0)
    #expect(style(content, at: s.range(of: "第二行").location)?.paragraphSpacing == 25)
    #expect(blockEnd(content, at: s.range(of: "第一行").length) == nil)
  }

  @Test("ruby paragraphs keep their minimum line height")
  func ruby() throws {
    let off = blocks("{注音|zhù yīn}在这里\n\n下一段", .default)
    guard case .paragraph(_, let rubyContent) = off[0] else { Issue.record("\(off)"); return }
    let minimum = try #require(style(rubyContent, at: 0)?.minimumLineHeight)
    #expect(minimum > 0)
    let content = try #require(run(blocks("{注音|zhù yīn}在这里\n\n下一段", mergeOn)[0]))
    #expect(style(content, at: 0)?.minimumLineHeight == minimum)
    #expect(style(content, at: 0)?.lineSpacing == 5)
  }

  @Test("<details> body merges too")
  func details() throws {
    let text = "<details open><summary>标题</summary>\n\n第一段\n\n第二段\n\n</details>"
    let top = blocks(text, mergeOn)
    guard case .details(_, _, _, let children)? = top.first else { Issue.record("\(top)"); return }
    #expect(kinds(children) == ["run"])
  }

  #if os(macOS)
  @Test("mac: block spacing / line spacing come from the typography sliders")
  func macSliders() throws {
    let config = MarkdownRenderConfig(blockSpacing: 27.3, paragraphLineSpacing: 6.2, mergesTextRuns: true)
    let content = try #require(run(blocks("一\n\n二\n\n三", config)[0]))
    let s = content.string as NSString
    #expect(style(content, at: 0)?.lineSpacing == 6.2)
    #expect(abs((style(content, at: 0)?.paragraphSpacing ?? 0) - (27.3 - 6.2)) < 1e-9)
    let third = try #require(blockEnd(content, at: s.length - 1))
    #expect(third.leafIndex == 2 && third.isLast)
    #expect(abs((blockEnd(content, at: s.range(of: "二").location + 1)?.gapAfter ?? 0) - (27.3 - 6.2)) < 1e-9)
  }
  #endif

  // MARK: - 列表（T15）

  private func marker(_ s: NSAttributedString, at index: Int) -> TextRunListMarker? {
    leafStart(s, at: index)?.marker
  }

  @Test("lists merge with neighbours; markers stay out of the text; indents / bullets / numbers follow the list views")
  func lists() throws {
    let text = "前面一段\n\n- 第一项\n- 第二项\n  - 里层\n\n1. 甲\n2. 乙\n\n后面一段"
    let merged = blocks(text, mergeOn)
    #expect(kinds(merged) == ["run"])
    let content = try #require(run(merged[0]))
    // 序号 / 圆点不进文字：拷贝、划线 quote、引用拿到的都是这串
    #expect(content.string == "前面一段\n第一项\n第二项\n里层\n甲\n乙\n后面一段")
    let s = content.string as NSString
    let first = s.range(of: "第一项").location
    let inner = s.range(of: "里层").location
    let jia = s.range(of: "甲").location
    let yi = s.range(of: "乙").location
    let after = s.range(of: "后面一段").location
    #expect(marker(content, at: 0) == nil)
    let bullet = try #require(marker(content, at: first))
    #expect(bullet.kind == .filledBullet && bullet.x == 9 && bullet.width == 4 && bullet.height == 4)
    #expect(style(content, at: first)?.headIndent == 23 && style(content, at: first)?.firstLineHeadIndent == 23)
    let nested = try #require(marker(content, at: inner))
    #expect(nested.kind == .hollowBullet && nested.x == CGFloat(8 + 9))
    #expect(style(content, at: inner)?.headIndent == CGFloat(8 + 23))
    let one = try #require(marker(content, at: jia))
    let two = try #require(marker(content, at: yi))
    #expect(one.kind == .number && one.text == "1." && two.text == "2." && one.x == 0)
    #expect(abs((style(content, at: jia)?.headIndent ?? 0) - (one.width + 11)) < 1e-9)
    #expect(style(content, at: after)?.headIndent ?? 0 == 0)
    // 列表项之间 VStack 间距 8（减掉下一段自己的行距 5），列表前后照块距 30
    #expect(blockEnd(content, at: first - 1)?.gapAfter == CGFloat(30 - 5))
    #expect(blockEnd(content, at: s.range(of: "第二项").location - 1)?.gapAfter == CGFloat(8 - 5))
    #expect(blockEnd(content, at: inner - 1)?.gapAfter == CGFloat(8 - 5))
    #expect(blockEnd(content, at: jia - 1)?.gapAfter == CGFloat(30 - 5) + one.topInset)
    #expect(blockEnd(content, at: after - 1)?.gapAfter == CGFloat(30 - 5))
    // 列表项段落和正文段落一样的行距
    #expect(style(content, at: first)?.lineSpacing == 5)
  }

  @Test("list item with several paragraphs: the rest sit at the list's left edge, block spacing between them")
  func listItemParagraphs() throws {
    let content = try #require(run(blocks("- 第一段\n\n  第二段\n- 下一项", mergeOn)[0]))
    let s = content.string as NSString
    #expect(content.string == "第一段\n第二段\n下一项")
    let second = s.range(of: "第二段").location
    #expect(marker(content, at: second) == nil)
    #expect(style(content, at: second)?.headIndent ?? 0 == 0)
    #expect(blockEnd(content, at: second - 1)?.gapAfter == CGFloat(8 - 5))                                   // 行 → 项内其余块：8
    #expect(blockEnd(content, at: s.range(of: "下一项").location - 1)?.gapAfter == CGFloat(8 - 5))          // 项 → 项：8
  }

  @Test("lists holding code / quotes / tables stay their own block; a one-item list alone stays a list")
  func listBoundaries() {
    #expect(kinds(blocks("前\n\n- 项\n\n  ```\n  code\n  ```\n\n后", mergeOn)) == ["p", "list", "p"])
    #expect(kinds(blocks("前\n\n- 项\n\n  > 引用\n\n后", mergeOn)) == ["p", "list", "p"])
    #expect(kinds(blocks("- 只有一项", mergeOn)) == ["list"])
    #expect(kinds(blocks("- 一\n- 二", mergeOn)) == ["run"])
  }
}
