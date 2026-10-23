// MP fork: 段落簇几何对齐 oracle（plan-cross-paragraph-selection T8）。
// 同一份文档 merge 关（一块一个段落视图 + 块距，照 BlockView / ParagraphView 的算法摆）和 merge 开
// （一个段落视图）各排一次，逐行比每一行的顶（容差 0.5pt）和整簇总高。用真的 ParagraphNSView / ParagraphUIView，
// 在屏视图的 TextKit 2 排版取行位置（mac 还经离屏测量栈量高）。mac: `swift test --filter TextRunGeometry`。
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import SwiftStreamingMarkdown
import SwiftUI
import Testing

@Suite("Text run geometry oracle")
@MainActor
struct TextRunGeometryTests {
  private let tolerance: CGFloat = 0.5

  #if os(macOS)
  private typealias View = ParagraphNSView
  private func makeView() -> View { ParagraphNSView.make() }
  private func spacing(_ c: MarkdownRenderConfig) -> CGFloat { c.blockSpacing ?? 30 }
  private func paragraphLineSpacing(_ c: MarkdownRenderConfig) -> CGFloat { c.paragraphLineSpacing ?? 5 }
  #else
  private typealias View = ParagraphUIView
  private func makeView() -> View { ParagraphUIView(frame: .zero) }
  private func spacing(_ c: MarkdownRenderConfig) -> CGFloat { 30 }
  private func paragraphLineSpacing(_ c: MarkdownRenderConfig) -> CGFloat { 5 }
  #endif

  /// ParagraphView.sizeThatFits 的高（同一套取整规则）
  private func height(of view: View, contents: NSMutableAttributedString, width: CGFloat) -> CGFloat {
    let raw = view.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
    #if os(macOS)
    return TextRunLayoutDelegate.isTextRun(contents) ? (raw * 10_000).rounded() / 10_000 : raw.rounded(.up)
    #else
    return raw.rounded(.up)
    #endif
  }

  /// 摆好一个段落视图，返回 (高, [(字符下标, 行顶 y)])
  private func layOut(_ contents: NSMutableAttributedString, lineSpacing: CGFloat?, width: CGFloat) -> (CGFloat, [(Int, CGFloat)]) {
    let view = makeView()
    view.frame = CGRect(x: 0, y: 0, width: width, height: 10)
    view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    let h = height(of: view, contents: contents, width: width)
    view.frame = CGRect(x: 0, y: 0, width: width, height: h)
    #if os(macOS)
    view.layoutSubtreeIfNeeded()
    #else
    view.layoutIfNeeded()
    #endif
    guard let tlm = view.textLayoutManager, let tcm = tlm.textContentManager else { return (h, []) }
    tlm.ensureLayout(for: tlm.documentRange)
    var lines: [(Int, CGFloat)] = []
    tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
      let base = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
      for line in fragment.textLineFragments {
        lines.append((base + line.characterRange.location, fragment.layoutFragmentFrame.minY + line.typographicBounds.minY))
      }
      return true
    }
    return (h, lines)
  }

  private struct Report {
    var lines = 0
    var worstLine: CGFloat = 0
    var heightDiff: CGFloat = 0
    var missing = 0
  }

  private func compare(_ markdown: String, config base: MarkdownRenderConfig, width: CGFloat) -> Report {
    let off = MarkdownParserImpl.renderables(for: markdown, config: base)
    let onConfig = MarkdownRenderConfig(shouldAnimateText: base.shouldAnimateText, headingStyle: base.headingStyle,
                                        paragraphStyle: base.paragraphStyle, citationConfig: base.citationConfig,
                                        blockSpacing: base.blockSpacing, paragraphLineSpacing: base.paragraphLineSpacing,
                                        mergesTextRuns: true)
    let on = MarkdownParserImpl.renderables(for: markdown, config: onConfig)
    guard on.count == 1, case .textRun(_, let run) = on[0] else {
      Issue.record("expected one text run, got \(on.count) blocks")
      return Report()
    }
    // merge 关：一块一个视图，块顶 = 前面各块取整后的高 + 块距
    var expected: [(Int, CGFloat)] = []
    var top: CGFloat = 0
    var offset = 0
    var extent: CGFloat = 0
    for block in off {
      let contents: NSMutableAttributedString
      let lineSpacing: CGFloat?
      switch block {
      case .paragraph(_, let c): contents = c; lineSpacing = paragraphLineSpacing(base)
      case .heading(_, _, let c): contents = c; lineSpacing = nil
      default: Issue.record("oracle docs hold only paragraphs / headings"); return Report()
      }
      let (h, lines) = layOut(contents, lineSpacing: lineSpacing, width: width)
      expected += lines.map { (offset + $0.0, top + $0.1) }
      extent = top + h
      top += h + spacing(base)
      offset += contents.length + 1
    }
    // merge 开：一个视图
    let (runHeight, runLines) = layOut(run, lineSpacing: nil, width: width)
    let actual = Dictionary(runLines.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    var report = Report(lines: expected.count, heightDiff: abs(runHeight - extent))
    for (index, y) in expected {
      if let merged = actual[index] {
        report.worstLine = max(report.worstLine, abs(merged - y))
      } else {
        report.missing += 1
      }
    }
    if runLines.count != expected.count { report.missing += abs(runLines.count - expected.count) }
    return report
  }

  private func check(_ name: String, _ markdown: String, config: MarkdownRenderConfig, widths: [CGFloat] = [280, 343, 500]) {
    for width in widths {
      let r = compare(markdown, config: config, width: width)
      print("[ORACLE] \(name) w=\(Int(width)) lines=\(r.lines) worstLine=\(r.worstLine) heightDiff=\(r.heightDiff) missing=\(r.missing)")
      #expect(r.lines > 0, "\(name) w=\(width)")
      #expect(r.missing == 0, "\(name) w=\(width): line count differs")
      #expect(r.worstLine <= tolerance, "\(name) w=\(width): worst line \(r.worstLine)")
      #expect(r.heightDiff <= tolerance, "\(name) w=\(width): height diff \(r.heightDiff)")
    }
  }

  /// MP 聊天正文那组字号（MarkdownConfig.memoryPalace：正文 13.5×1.2、h1 20×1.2、h2 17×1.2、h3 15×1.2）
  private func mpConfig(blockSpacing: CGFloat? = nil, paragraphLineSpacing: CGFloat? = nil) -> MarkdownRenderConfig {
    func fonts(_ size: CGFloat, _ weight: PlatformFont.Weight) -> TextFonts {
      let f = PlatformFont.systemFont(ofSize: size, weight: weight)
      return TextFonts(normal: f, italic: nil, bold: PlatformFont.systemFont(ofSize: size, weight: .bold), boldItalic: nil,
                       preferredLetterSpacing: nil, preferredLineHeight: nil)
    }
    let body = fonts(13.5 * 1.2, .regular)
    let h2 = fonts(17 * 1.2, .semibold)
    let h3 = fonts(15 * 1.2, .semibold)
    return MarkdownRenderConfig(
      headingStyle: .init(h1Font: fonts(20 * 1.2, .bold), h2Font: h2, h3Font: h3, h4Font: h3, h5Font: h3, h6Font: h3, textColor: .black),
      orderedListStyle: .init(textFonts: body, textColor: .black),
      paragraphStyle: .init(textFonts: body, textColor: .black),
      citationConfig: .init(isEnabled: false, font: PlatformFont.systemFont(ofSize: 12), textColor: .black, backgroundColor: .white),
      blockSpacing: blockSpacing, paragraphLineSpacing: paragraphLineSpacing)
  }

  private let mixed = """
  第一段：这是一段中英混排的文字 mixed with English words，用来测试折行以后行高的累计误差是不是会被放大。

  ## 小标题 Heading

  第二段 short.

  第三段：结果跟理论完全一致，后来 2012 年又有人重复了这个实验，用的是更精确的仪器，结论没有变化。**加粗**、*斜体*、`code` 都来一点。

  ### 三级标题

  最后一段。
  """

  @Test("plain paragraphs")
  func plainParagraphs() {
    check("plain", "第一段文字，长一点长一点长一点长一点长一点长一点长一点长一点长一点。\n\n第二段。\n\n第三段 English only paragraph that wraps over a couple of lines for sure, I hope.", config: mpConfig())
  }

  @Test("headings between paragraphs, mixed CJK / Latin / inline styles")
  func headingsMixed() {
    check("mixed", mixed, config: mpConfig())
  }

  @Test("soft breaks inside a paragraph")
  func softBreaks() {
    check("softbreak", "第一行\n第二行比较长比较长比较长比较长比较长比较长比较长比较长比较长\n第三行\n\n下一段。\n\n## 标题\n第二行标题后的段落", config: mpConfig())
  }

  @Test("inline math and ruby paragraphs")
  func mathAndRuby() {
    check("math+ruby", "质能方程 $E = mc^2$ 写在行内，再来一个 $\\frac{a}{b}$ 撑高这一行。\n\n{注音|zhù yīn}的段落，{薄荷|bò he}长得很好，折行看看最小行高。\n\n普通段落收尾。", config: mpConfig())
  }

  @Test("upstream default typography")
  func upstreamDefault() {
    check("default", mixed, config: .default)
  }

  #if os(macOS)
  @Test("mac typography sliders: fractional block / line spacing, block spacing below line spacing")
  func macSliders() {
    check("mac 27.3/6.2", mixed, config: mpConfig(blockSpacing: 27.3, paragraphLineSpacing: 6.2))
    check("mac 9.1/11", mixed, config: mpConfig(blockSpacing: 9.1, paragraphLineSpacing: 11))
    check("mac 41.8/4.37", mixed, config: mpConfig(blockSpacing: 41.8, paragraphLineSpacing: 4.37))
  }
  #endif

  // MARK: - 列表（T15）：merge 关 = 真 SwiftUI 树（BlockView → OrderedListView / UnorderedListView）摆出来的各段落视图，
  // merge 开 = 同一棵树里的一个段落簇视图；逐行比行顶 y 和行首 x（0.5pt）、比整体高。

  private struct HostedLine {
    let index: Int
    let x: CGFloat
    let y: CGFloat
  }

  private func withMerge(_ base: MarkdownRenderConfig, _ on: Bool) -> MarkdownRenderConfig {
    MarkdownRenderConfig(shouldAnimateText: base.shouldAnimateText, headingStyle: base.headingStyle,
                         orderedListStyle: base.orderedListStyle, paragraphStyle: base.paragraphStyle,
                         citationConfig: base.citationConfig, blockSpacing: base.blockSpacing,
                         paragraphLineSpacing: base.paragraphLineSpacing, mergesTextRuns: on)
  }

  /// 视图里每一行的（字符下标, 行首 x, 行顶 y），视图坐标
  private func lines(of view: View) -> [(Int, CGFloat, CGFloat)] {
    guard let tlm = view.textLayoutManager, let tcm = tlm.textContentManager else { return [] }
    tlm.ensureLayout(for: tlm.documentRange)
    var result: [(Int, CGFloat, CGFloat)] = []
    tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
      let base = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
      let frame = fragment.layoutFragmentFrame
      for line in fragment.textLineFragments {
        let glyphX = line.locationForCharacter(at: line.characterRange.location).x
        result.append((base + line.characterRange.location, frame.minX + line.typographicBounds.minX + glyphX,
                       frame.minY + line.typographicBounds.minY))
      }
      return true
    }
    return result
  }

  #if os(macOS)
  /// 把一份文档放进真的 SwiftUI 树里排好：返回整体高和各段落视图（按位置排）及其在宿主里的框
  private func host(_ markdown: String, config: MarkdownRenderConfig, width: CGFloat) -> (CGFloat, [(View, CGRect)], NSWindow) {
    let blocks = MarkdownParserImpl.renderables(for: markdown, config: config)
    let root = BlockView(renderables: blocks)
      .environment(\.markdownConfig, config)
      .frame(width: width, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
    let hosting = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 2000), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    let size = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    var views: [(View, CGRect)] = []
    func walk(_ v: NSView) {
      if let p = v as? View { views.append((p, p.convert(p.bounds, to: hosting))) }
      v.subviews.forEach(walk)
    }
    walk(hosting)
    views.sort { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
    return (size.height, views, window)
  }
  #else
  private func host(_ markdown: String, config: MarkdownRenderConfig, width: CGFloat) -> (CGFloat, [(View, CGRect)], UIWindow) {
    let blocks = MarkdownParserImpl.renderables(for: markdown, config: config)
    let root = BlockView(renderables: blocks)
      .environment(\.markdownConfig, config)
      .frame(width: width, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
    let controller = UIHostingController(rootView: root)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 2000))
    window.rootViewController = controller
    window.isHidden = false
    let size = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    controller.view.frame = CGRect(origin: .zero, size: size)
    controller.view.layoutIfNeeded()
    var views: [(View, CGRect)] = []
    func walk(_ v: UIView) {
      if let p = v as? View { views.append((p, p.convert(p.bounds, to: controller.view))) }
      v.subviews.forEach(walk)
    }
    walk(controller.view)
    views.sort { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
    return (size.height, views, window)
  }
  #endif

  private struct ListReport {
    var lines = 0
    var worstY: CGFloat = 0
    var worstX: CGFloat = 0
    var heightDiff: CGFloat = 0
    var missing = 0
    var note = ""
  }

  private func compareHosted(_ markdown: String, config base: MarkdownRenderConfig, width: CGFloat) -> ListReport {
    let (offHeight, offViews, offWindow) = host(markdown, config: withMerge(base, false), width: width)
    let (onHeight, onViews, onWindow) = host(markdown, config: withMerge(base, true), width: width)
    defer {
      #if os(macOS)
      offWindow.close(); onWindow.close()
      #else
      offWindow.isHidden = true; onWindow.isHidden = true
      #endif
    }
    guard onViews.count == 1, let (runView, runFrame) = onViews.first else {
      return ListReport(missing: 1, note: "merge on: expected one paragraph view, got \(onViews.count)")
    }
    var expected: [HostedLine] = []
    var offset = 0
    for (view, frame) in offViews {
      expected += lines(of: view).map { HostedLine(index: offset + $0.0, x: frame.minX + $0.1, y: frame.minY + $0.2) }
      offset += view.paragraphContents.length + 1
    }
    let runString = runView.paragraphContents.string as NSString
    let actual = Dictionary(lines(of: runView).map { ($0.0, HostedLine(index: $0.0, x: runFrame.minX + $0.1, y: runFrame.minY + $0.2)) },
                            uniquingKeysWith: { first, _ in first })
    var report = ListReport(lines: expected.count, heightDiff: abs(onHeight - offHeight))
    if runString.length != offset - 1 { report.note = "text length \(runString.length) vs \(offset - 1)" }
    for line in expected {
      guard let merged = actual[line.index] else { report.missing += 1; continue }
      report.worstY = max(report.worstY, abs(merged.y - line.y))
      report.worstX = max(report.worstX, abs(merged.x - line.x))
    }
    if actual.count != expected.count { report.missing += abs(actual.count - expected.count) }
    return report
  }

  private func checkHosted(_ name: String, _ markdown: String, config: MarkdownRenderConfig, widths: [CGFloat] = [280, 343, 500]) {
    for width in widths {
      let r = compareHosted(markdown, config: config, width: width)
      print("[ORACLE-LIST] \(name) w=\(Int(width)) lines=\(r.lines) worstY=\(r.worstY) worstX=\(r.worstX) heightDiff=\(r.heightDiff) missing=\(r.missing) \(r.note)")
      #expect(r.lines > 0, "\(name) w=\(width)")
      #expect(r.missing == 0 && r.note.isEmpty, "\(name) w=\(width): \(r.note) missing \(r.missing)")
      #expect(r.worstY <= tolerance, "\(name) w=\(width): worst line y \(r.worstY)")
      #expect(r.worstX <= tolerance, "\(name) w=\(width): worst line x \(r.worstX)")
      #expect(r.heightDiff <= tolerance, "\(name) w=\(width): height diff \(r.heightDiff)")
    }
  }

  static let unorderedDoc = """
  前面一段：先说清楚背景，这一段要长一点长一点，才能在窄屏上折成两行以上。

  - 第一项
  - 第二项比较长比较长比较长比较长比较长比较长比较长比较长，再加一点 English words 让它折行
  - 第三项

  后面一段收尾。
  """

  static let orderedDoc = """
  步骤如下：

  1. 打开设置
  2. 找到「外观」里的排版，把行距滑杆往右拖一点点
  3. 第三步
  4. 第四步
  5. 第五步
  6. 第六步
  7. 第七步
  8. 第八步
  9. 第九步
  10. 第十步，两位数序号更宽，文字往右挪

  完成。
  """

  static let nestedDoc = """
  - 外层一
    - 里层一
    - 里层二比较长比较长比较长比较长比较长比较长比较长比较长比较长
      - 第三层
  - 外层二
    1. 有序里层一
    2. 有序里层二
  - 外层三

  1. 有序外层
     - 无序里层
     - 无序里层二
  2. 有序外层二
  """

  static let multiParagraphItemDoc = """
  - 第一项的第一段

    第一项的第二段，长一点长一点长一点长一点长一点长一点长一点长一点长一点长一点。

    第一项的第三段
  - 第二项
  1. 有序项第一段

     有序项第二段
  2. 下一项
  """

  static let mixedDoc = """
  ## 小标题 Heading

  中英混排 mixed paragraph，**加粗**、*斜体*、`code` 都来一点。

  - English item with a long sentence that definitely wraps over a couple of lines here.
  - 中文项目，夹一个 `inline code` 和 **粗体**。
  - 数字 2012 年和 E = mc² 混在一起

  1. Step one 第一步
  2. 第二步 step two

  最后一段 final paragraph.
  """

  @Test("lists: unordered list between paragraphs")
  func listUnordered() {
    checkHosted("unordered", Self.unorderedDoc, config: mpConfig())
  }

  @Test("lists: ordered 1–10 (two-digit numbers widen the marker)")
  func listOrdered() {
    checkHosted("ordered", Self.orderedDoc, config: mpConfig())
  }

  @Test("lists: two / three levels of nesting, ordered inside unordered and back")
  func listNested() {
    checkHosted("nested", Self.nestedDoc, config: mpConfig())
  }

  @Test("lists: several paragraphs inside one item")
  func listMultiParagraphItem() {
    checkHosted("multi-paragraph item", Self.multiParagraphItemDoc, config: mpConfig())
  }

  @Test("lists: mixed CJK / Latin, headings and lists in one run")
  func listMixed() {
    checkHosted("mixed", Self.mixedDoc, config: mpConfig())
  }

  @Test("lists: upstream default typography")
  func listDefault() {
    checkHosted("default", Self.nestedDoc, config: .default)
  }

  #if os(macOS)
  @Test("lists: mac typography sliders (fractional block / line spacing)")
  func listMacSliders() {
    checkHosted("mac 27.3/6.2", Self.orderedDoc + "\n\n" + Self.nestedDoc, config: mpConfig(blockSpacing: 27.3, paragraphLineSpacing: 6.2))
    checkHosted("mac 9.1/11", Self.multiParagraphItemDoc + "\n\n" + Self.unorderedDoc, config: mpConfig(blockSpacing: 9.1, paragraphLineSpacing: 11))
    checkHosted("mac 41.8/4.37", Self.mixedDoc, config: mpConfig(blockSpacing: 41.8, paragraphLineSpacing: 4.37))
  }
  #endif
}
