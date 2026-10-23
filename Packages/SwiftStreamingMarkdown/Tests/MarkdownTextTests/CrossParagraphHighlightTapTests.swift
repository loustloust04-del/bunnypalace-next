// MP fork: 跨段划线在「一段一个视图」时逐截画出，单击任一截上报整条 quote（mac 命中路径 highlightHit）。
#if os(macOS)

import AppKit
import Foundation
@testable import SwiftStreamingMarkdown
import Testing

@Suite("Cross-paragraph highlight hit (mac)")
@MainActor
struct CrossParagraphHighlightTapMacTests {
  private func view(_ text: String) -> ParagraphNSView {
    let view = ParagraphNSView.make()
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 10)
    view.setParagraphContents(NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 17)]),
                              lineSpacing: 5, animatedByWord: false)
    let size = view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
    view.frame = CGRect(x: 0, y: 0, width: 320, height: size.height)
    return view
  }

  /// 第 index 个字的字形框中心（视图坐标）
  private func center(of index: Int, in view: ParagraphNSView) throws -> NSPoint {
    let tlm = try #require(view.textLayoutManager)
    let tcm = try #require(tlm.textContentManager)
    let start = try #require(tcm.location(tcm.documentRange.location, offsetBy: index))
    let end = try #require(tcm.location(start, offsetBy: 1))
    var rect: CGRect?
    tlm.enumerateTextSegments(in: try #require(NSTextRange(location: start, end: end)), type: .standard, options: []) { _, frame, _, _ in
      rect = frame
      return false
    }
    let r = try #require(rect)
    return NSPoint(x: r.midX + view.textContainerOrigin.x, y: r.midY + view.textContainerOrigin.y)
  }

  @Test("tapping either piece reports the whole quote; single-paragraph quotes report themselves")
  func hitReportsWholeQuote() throws {
    let quote = "段尾半句\n下一段的开头"
    let color = NSColor.systemGreen.withAlphaComponent(0.3)
    let first = view("第一段写到这里的段尾半句")
    first.setTextHighlights([TextHighlight(quote: quote, color: color, style: .fill, strokeId: "x")])
    let firstHit = try #require(first.highlightHit(atViewPoint: try center(of: 10, in: first)))
    #expect(firstHit.quote == quote)
    #expect((first.textStorage!.string as NSString).substring(with: firstHit.range) == "段尾半句")
    #expect(first.highlightHit(atViewPoint: try center(of: 2, in: first)) == nil)

    let second = view("下一段的开头和后面的字")
    second.setTextHighlights([TextHighlight(quote: quote, color: color, style: .underline, strokeId: "x")])
    let secondHit = try #require(second.highlightHit(atViewPoint: try center(of: 1, in: second)))
    #expect(secondHit.quote == quote)
    #expect((second.textStorage!.string as NSString).substring(with: secondHit.range) == "下一段的开头")

    let single = view("窗台上的薄荷长得很好")
    single.setTextHighlights([TextHighlight(quote: "薄荷", color: color, style: .fill, strokeId: "y")])
    #expect(single.highlightHit(atViewPoint: try center(of: 4, in: single))?.quote == "薄荷")
  }

  /// T15：列表并进段落簇的视图里，跨项选区拷贝出来的文字不带序号 / 圆点；跨项划线整条命中、轻点报整条
  @Test("list run: copy across items has no markers; a cross-item highlight hits as one quote")
  func listRunCopyAndHighlight() throws {
    let blocks = MarkdownParserImpl.renderables(for: "开头一段\n\n- 第一项\n- 第二项\n\n1. 甲\n2. 乙\n\n结尾一段",
                                                config: MarkdownRenderConfig(mergesTextRuns: true))
    guard case .textRun(_, let run)? = blocks.first else { Issue.record("\(blocks)"); return }
    let view = ParagraphNSView.make()
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 10)
    view.setParagraphContents(run, lineSpacing: nil, animatedByWord: false)
    let size = view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
    view.frame = CGRect(x: 0, y: 0, width: 320, height: size.height)
    let text = run.string as NSString
    let start = text.range(of: "一项").location
    let end = NSMaxRange(text.range(of: "乙"))
    view.setSelectedRange(NSRange(location: start, length: end - start))
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("mpmd.test.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    // 走系统拷贝同一条路（Copy 写的就是这几种类型；测试进程里纯文本类型报的是旧名 NSStringPboardType）
    #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
    let copied = pasteboard.string(forType: .string) ?? pasteboard.string(forType: NSPasteboard.PasteboardType("NSStringPboardType"))
    #expect(copied == "一项\n第二项\n甲\n乙")

    let quote = "一项\n第二项\n甲"
    view.setTextHighlights([TextHighlight(quote: quote, color: NSColor.systemGreen.withAlphaComponent(0.3), style: .fill, strokeId: "q")])
    view.setSelectedRange(NSRange(location: 0, length: 0))
    let hit = try #require(view.highlightHit(atViewPoint: try center(of: text.range(of: "第二项").location + 1, in: view)))
    #expect(hit.quote == quote)
    #expect(text.substring(with: hit.range) == quote)
  }
}

#endif
