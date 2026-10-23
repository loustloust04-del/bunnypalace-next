// MP fork: 划线画在字下面一层（底色 / 下划线 / 彩笔 / 叠划）的离屏渲染检查。iOS only。
#if os(iOS)

import Foundation
@testable import SwiftStreamingMarkdown
import Testing
import UIKit

@Suite("Highlight stroke layer")
@MainActor
struct HighlightStrokeRenderTests {
  private func render(_ view: UIView) -> UIImage {
    UIGraphicsImageRenderer(bounds: view.bounds).image { ctx in view.layer.render(in: ctx.cgContext) }
  }

  @Test("fill / underline / pen / stacked strokes draw under the text")
  func strokesDraw() throws {
    let text = "窗台上的薄荷长得很好，分盆以后三盆都活着。Mint grows well on the sill, and the three pots all survived after splitting. 第二段的话也要够长，才能看出折行以后每一行的笔道是不是各画一份。"
    let attributed = NSMutableAttributedString(string: text, attributes: [
      .font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black,
    ])
    let view = ParagraphUIView(frame: CGRect(x: 0, y: 0, width: 320, height: 10))
    view.setParagraphContents(attributed, lineSpacing: 5, animatedByWord: false)
    let size = view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
    view.frame = CGRect(x: 0, y: 0, width: 320, height: size.height + 20)
    view.backgroundColor = .white
    view.layoutIfNeeded()
    let mint = UIColor(red: 0.557, green: 0.741, blue: 0.624, alpha: 1)
    let lilac = UIColor(red: 0.741, green: 0.659, blue: 0.847, alpha: 1)
    let rose = UIColor(red: 0.788, green: 0.541, blue: 0.541, alpha: 1)
    view.setTextHighlights([
      TextHighlight(quote: "窗台上的薄荷", color: mint.withAlphaComponent(0.3), style: .fill, strokeId: "a"),
      TextHighlight(quote: "窗台上的薄荷", color: rose.withAlphaComponent(0.9), style: .underline, strokeId: "b"),
      TextHighlight(quote: "上的薄荷长得", color: lilac.withAlphaComponent(0.9), style: .underline, strokeId: "c"),
      TextHighlight(quote: "Mint grows well on the sill, and the three pots", color: lilac.withAlphaComponent(0.45), style: .pen, strokeId: "d"),
      TextHighlight(quote: "折行以后每一行的笔道", color: rose.withAlphaComponent(0.3), style: .fill, strokeId: "e"),
      TextHighlight(quote: "每一行的笔道是不是", color: mint.withAlphaComponent(0.3), style: .fill, strokeId: "f"),
      TextHighlight(quote: "三盆", color: .yellow, style: .background),
    ])
    view.layoutIfNeeded()
    let image = render(view)
    let out = ProcessInfo.processInfo.environment["MP_HIGHLIGHT_SHOT"] ?? NSTemporaryDirectory() + "highlight-strokes.png"
    try image.pngData()?.write(to: URL(fileURLWithPath: out))
    print("[HLSHOT] \(out)")
    // 字下面那层确实画了东西：strokeLayer 是 layer 的第 0 个子层，且有笔画
    let strokeLayer = try #require(view.layer.sublayers?.first)
    #expect((strokeLayer.sublayers?.count ?? 0) >= 6)
  }
}

#endif

#if os(macOS)

import AppKit
import Foundation
@testable import SwiftStreamingMarkdown
import Testing

@Suite("Highlight stroke layer (mac)")
@MainActor
struct HighlightStrokeRenderMacTests {
  @Test("fill / underline / pen draw under the text")
  func strokesDraw() throws {
    let text = "窗台上的薄荷长得很好，分盆以后三盆都活着。Mint grows well on the sill, and the three pots all survived after splitting."
    let attributed = NSMutableAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black,
    ])
    let view = ParagraphNSView.make()
    view.frame = CGRect(x: 0, y: 0, width: 320, height: 10)
    view.setParagraphContents(attributed, lineSpacing: 5, animatedByWord: false)
    let size = view.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
    view.frame = CGRect(x: 0, y: 0, width: 320, height: size.height + 20)
    let mint = NSColor(red: 0.557, green: 0.741, blue: 0.624, alpha: 1)
    let lilac = NSColor(red: 0.741, green: 0.659, blue: 0.847, alpha: 1)
    let rose = NSColor(red: 0.788, green: 0.541, blue: 0.541, alpha: 1)
    view.setTextHighlights([
      TextHighlight(quote: "窗台上的薄荷", color: mint.withAlphaComponent(0.3), style: .fill, strokeId: "a"),
      TextHighlight(quote: "窗台上的薄荷", color: rose.withAlphaComponent(0.9), style: .underline, strokeId: "b"),
      TextHighlight(quote: "上的薄荷长得", color: lilac.withAlphaComponent(0.9), style: .underline, strokeId: "c"),
      TextHighlight(quote: "Mint grows well on the sill, and the three pots", color: lilac.withAlphaComponent(0.45), style: .pen, strokeId: "d"),
    ])
    view.layoutSubtreeIfNeeded()
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    view.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    let out = ProcessInfo.processInfo.environment["MP_HIGHLIGHT_SHOT_MAC"] ?? NSTemporaryDirectory() + "highlight-strokes-mac.png"
    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    print("[HLSHOT] \(out)")
  }
}

#endif
