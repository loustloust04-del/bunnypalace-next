//
//  MP fork: 段落簇合并（`MarkdownRenderConfig.mergesTextRuns`）。连续的段落 / 标题 / 列表并成一个
//  `.textRun`，选区就能在系统原生的一个文字视图里跨段；代码块 / 表格 / 公式 / 引用 / 独立链接 / 卡片，
//  以及装着这些东西的列表，仍各自成块，是簇的分界。
//
//  外观要和一块一个视图逐 pt 相同：每块的行距照 ParagraphView 的套法写进段落样式（段落 = 行距，
//  标题 = 不加），列表项的缩进写成段落的 headIndent；块距、块高取整和列表标记交给
//  `TextRunLayoutFragment`（见 TextRunLayout.swift）。序号 / 圆点不进文字。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import SwiftUI

enum TextRunMerger {

  static func merge(_ blocks: [MarkdownRenderable], config: MarkdownRenderConfig) -> [MarkdownRenderable] {
    var merged: [MarkdownRenderable] = []
    var pending: [MarkdownRenderable] = []
    func flush() {
      if pending.reduce(0, { $0 + leafCount(of: $1) }) > 1 {
        merged.append(run(pending, config: config))
      } else {
        merged.append(contentsOf: pending)
      }
      pending = []
    }
    for block in blocks {
      if isMergeable(block) {
        pending.append(block)
      } else {
        flush()
        merged.append(block)
      }
    }
    flush()
    return merged
  }

  /// 能进簇的块：非空段落 / 标题；列表要求每一项都以非空段落开头，其余子块只能是非空段落或能进簇的列表
  private static func isMergeable(_ block: MarkdownRenderable) -> Bool {
    switch block {
    case .paragraph(_, let content), .heading(_, _, let content):
      return content.length > 0
    case .orderedList(_, let items), .unorderedList(_, let items, _):
      return !items.isEmpty && items.allSatisfy(isMergeable(item:))
    default:
      return false
    }
  }

  private static func isMergeable(item: MarkdownListItem) -> Bool {
    guard case .paragraph(_, let first)? = item.children.first, first.length > 0 else { return false }
    return item.children.dropFirst().allSatisfy { child in
      switch child {
      case .paragraph(_, let content): return content.length > 0
      case .orderedList, .unorderedList: return isMergeable(child)
      default: return false
      }
    }
  }

  /// 并进簇后占几个段落视图（一块一个视图时的个数）
  private static func leafCount(of block: MarkdownRenderable) -> Int {
    switch block {
    case .orderedList(_, let items), .unorderedList(_, let items, _):
      return items.reduce(0) { sum, item in sum + item.children.reduce(0) { $0 + leafCount(of: $1) } }
    default:
      return 1
    }
  }

  /// 一个「叶」= 一块一个视图时的一个段落视图（段落 / 标题 / 列表项里的段落）
  private struct Leaf {
    let piece: NSMutableAttributedString
    /// 左缩进（列表层级 + 标记格子）
    var indent: CGFloat = 0
    var marker: TextRunListMarker?
    /// 和前一个元素之间的 VStack 间距（第一叶为 0）
    var spacingBefore: CGFloat = 0
  }

  private struct Metrics {
    let blockSpacing: CGFloat
    let paragraphLineSpacing: CGFloat
    let config: MarkdownRenderConfig
  }

  private static func run(_ blocks: [MarkdownRenderable], config: MarkdownRenderConfig) -> MarkdownRenderable {
    // 与 BlockView / SingleBlockView 同一组数：iOS 写死块距 30 / 段落行距 5，mac 吃排版滑杆
    #if os(macOS)
    let metrics = Metrics(blockSpacing: config.blockSpacing ?? 30, paragraphLineSpacing: config.paragraphLineSpacing ?? 5, config: config)
    #else
    let metrics = Metrics(blockSpacing: 30, paragraphLineSpacing: 5, config: config)
    #endif

    let leaves = flatten(blocks, x: 0, spacing: metrics.blockSpacing, metrics: metrics)

    let result = NSMutableAttributedString()
    for (index, leaf) in leaves.enumerated() {
      let piece = leaf.piece
      let isLast = index == leaves.count - 1
      if leaf.indent > 0 {
        setIndent(leaf.indent, of: piece)
      }
      let topLineSpacing = index == 0 ? 0 : self.topLineSpacing(of: piece)
      let leafStart = TextRunLeafStart(leafIndex: index, topLineSpacing: topLineSpacing,
                                       leadingInset: index == 0 ? (leaf.marker?.topInset ?? 0) : 0, marker: leaf.marker)
      // 挂满这一叶的第一个段落（只挂第一个字会把注音之类按字符区间起作用的属性切成两截，排版跟着变）
      let firstBreak = (piece.string as NSString).range(of: "\n")
      let firstParagraphLength = firstBreak.location == NSNotFound ? piece.length : NSMaxRange(firstBreak)
      piece.addAttribute(.mpmdTextRunLeafStart, value: leafStart, range: NSRange(location: 0, length: firstParagraphLength))

      // 下一叶的字顶 = 这一叶的行底 + VStack 间距 + 下一行标记顶出字顶的部分；
      // TextKit 2 在非首段第一行上方自己加本段行距，从间距里扣掉
      let gapAfter: CGFloat
      if isLast {
        gapAfter = 0
      } else {
        let next = leaves[index + 1]
        gapAfter = next.spacingBefore + (next.marker?.topInset ?? 0) - self.topLineSpacing(of: next.piece)
        piece.append(separator(after: piece))
      }
      // 段距只给这一叶的最后一个段落（叶内软换行分出的段落不加）
      let text = piece.string as NSString
      let searchLength = isLast ? text.length : text.length - 1
      let lastBreak = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: searchLength))
      let start = lastBreak.location == NSNotFound ? 0 : NSMaxRange(lastBreak)
      setParagraphSpacing(isLast ? 0 : max(0, gapAfter), in: NSRange(location: start, length: text.length - start), of: piece)
      let blockEnd = TextRunBlockEnd(leafIndex: index, gapAfter: gapAfter, isLast: isLast)
      piece.addAttribute(.mpmdTextRunBlockEnd, value: blockEnd, range: NSRange(location: piece.length - 1, length: 1))
      result.append(piece)
    }
    return .textRun(id: blocks[0].id, content: result)
  }

  /// 一列块（一个 VStack）摊成叶；块与块之间隔 `spacing`
  private static func flatten(_ blocks: [MarkdownRenderable], x: CGFloat, spacing: CGFloat, metrics: Metrics) -> [Leaf] {
    var leaves: [Leaf] = []
    for (index, block) in blocks.enumerated() {
      var sub = self.leaves(of: block, x: x, metrics: metrics)
      if index > 0, !sub.isEmpty {
        sub[0].spacingBefore = spacing
      }
      leaves += sub
    }
    return leaves
  }

  private static func leaves(of block: MarkdownRenderable, x: CGFloat, metrics: Metrics) -> [Leaf] {
    switch block {
    case .paragraph(_, let content):
      let piece = NSMutableAttributedString(attributedString: content)
      applyLineSpacing(metrics.paragraphLineSpacing, to: piece)
      return [Leaf(piece: piece, indent: x)]
    case .heading(_, let level, let content):
      let piece = NSMutableAttributedString(attributedString: content)
      #if canImport(UIKit)
      // 一块一个视图时靠 .isHeader trait；并进文字视图后用文字属性保 VoiceOver 标题导航
      piece.addAttribute(.accessibilityTextHeadingLevel, value: level, range: NSRange(location: 0, length: piece.length))
      #endif
      return [Leaf(piece: piece, indent: x)]
    case .unorderedList(_, let items, let nestedLevel):
      // UnorderedListView：整个 VStack 左边 padding 8 × 层级；行 = 22pt 宽格子 + 间距 1 + 文字。圆点 4×4：
      // ZStack(.trailing) 只有它一个，自己就 4 宽，再 .frame(width: 22) 默认居中 → 圆点在格子正中（x 9…13）
      let listX = x + CGFloat(nestedLevel) * 8
      return listLeaves(items, listX: listX, metrics: metrics) { _, firstParagraph in
        let center = listItemFirstFont(in: firstParagraph).lineHeight / 2
        let marker = TextRunListMarker(kind: nestedLevel % 2 == 0 ? .filledBullet : .hollowBullet, text: "", font: nil,
                                       color: bulletColor, kern: nil, x: listX + 9, width: 4, height: 4,
                                       centerFromTextTop: center)
        return (marker, listX + 23)
      }
    case .orderedList(_, let items):
      // OrderedListView：没有层级缩进；行 = 粗体序号「n.」（从 1 数）+ 间距 11 + 文字
      let style = metrics.config.orderedListStyle
      let font = style.textFonts.bold ?? style.textFonts.normal
      return listLeaves(items, listX: x, metrics: metrics) { index, firstParagraph in
        let label = "\(index + 1)."
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let kern = style.textFonts.preferredLetterSpacing { attributes[.kern] = kern }
        let size = NSAttributedString(string: label, attributes: attributes).size()
        let center = listItemFirstFont(in: firstParagraph).lineHeight / 2
        let marker = TextRunListMarker(kind: .number, text: label, font: font, color: style.textColor,
                                       kern: style.textFonts.preferredLetterSpacing, x: x, width: size.width,
                                       height: size.height, centerFromTextTop: center)
        return (marker, x + size.width + 11)
      }
    default:
      return []
    }
  }

  /// 列表的 VStack(spacing: 8)：每项 = 一行（标记 + 第一段）+ 其余子块（BlockView，左边齐列表、块距照常）
  private static func listLeaves(_ items: [MarkdownListItem], listX: CGFloat, metrics: Metrics,
                                 marker: (Int, NSAttributedString) -> (TextRunListMarker, CGFloat)) -> [Leaf] {
    var leaves: [Leaf] = []
    for (index, item) in items.enumerated() {
      guard case .paragraph(_, let first)? = item.children.first else { continue }
      let (rowMarker, indent) = marker(index, first)
      let piece = NSMutableAttributedString(attributedString: first)
      applyLineSpacing(metrics.paragraphLineSpacing, to: piece)
      var row = Leaf(piece: piece, indent: indent, marker: rowMarker)
      if index > 0 { row.spacingBefore = 8 }
      leaves.append(row)
      var rest = flatten(Array(item.children.dropFirst()), x: listX, spacing: metrics.blockSpacing, metrics: metrics)
      if !rest.isEmpty {
        rest[0].spacingBefore = 8
      }
      leaves += rest
    }
    return leaves
  }

  /// UnorderedListView 圆点的颜色
  private static let bulletColor = PlatformColor(Color.Theme.Foreground.Primary.Primary450)

  /// ParagraphUIView / ParagraphNSView `setLineSpacing` 的同一套：整块一个新样式，保留注音段落的最小行高
  private static func applyLineSpacing(_ lineSpacing: CGFloat, to string: NSMutableAttributedString) {
    let paragraphStyle = NSMutableParagraphStyle()
    if string.length > 0, let existing = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
      paragraphStyle.minimumLineHeight = existing.minimumLineHeight
    }
    paragraphStyle.lineSpacing = lineSpacing
    paragraphStyle.alignment = .left
    string.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: string.length))
  }

  /// TextKit 2 在非首段第一行上方加的距离 = 本段行距
  private static func topLineSpacing(of string: NSAttributedString) -> CGFloat {
    (string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
  }

  /// 块间分隔符：只带上一个字的字体 / 字色 / 段落样式（不带附件、链接、底色之类）
  private static func separator(after string: NSAttributedString) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [:]
    for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
      if let value = string.attribute(key, at: string.length - 1, effectiveRange: nil) {
        attributes[key] = value
      }
    }
    return NSAttributedString(string: "\n", attributes: attributes)
  }

  private static func setParagraphSpacing(_ spacing: CGFloat, in range: NSRange, of string: NSMutableAttributedString) {
    updateParagraphStyles(in: range, of: string) { $0.paragraphSpacing = spacing }
  }

  /// 列表项文字左缩进（首行同）：一块一个视图时文字视图本身就摆在缩进后面
  private static func setIndent(_ indent: CGFloat, of string: NSMutableAttributedString) {
    updateParagraphStyles(in: NSRange(location: 0, length: string.length), of: string) {
      $0.headIndent = indent
      $0.firstLineHeadIndent = indent
    }
  }

  private static func updateParagraphStyles(in range: NSRange, of string: NSMutableAttributedString,
                                            _ change: (NSMutableParagraphStyle) -> Void) {
    var runs: [(NSRange, NSMutableParagraphStyle)] = []
    string.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
      let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
      change(style)
      runs.append((subrange, style))
    }
    for (subrange, style) in runs {
      string.addAttribute(.paragraphStyle, value: style, range: subrange)
    }
  }
}
