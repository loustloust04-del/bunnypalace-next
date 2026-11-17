// MP fork（docs/plan-重构.md R2 / R3）：给原生对话列表用的「一块一行」出口。
// SwiftUI 那条路是 DocumentView → BlockView（VStack，块距 30）→ ParagraphView → ParagraphUIView；
// 这里跳过 SwiftUI，直接把同一份属性串交给同一个 ParagraphUIView，量法也同一个，所以画出来逐像素相同。
#if os(iOS)

import UIKit

/// 文档里的一个顶层块。相等 = 内容逐字相同（流式时拿它判断「这一块没变，上次排好的还能用」）
public struct MarkdownBlock: Identifiable, Equatable, @unchecked Sendable {
  public static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool { lhs.renderable == rhs.renderable }

  public enum Kind: Equatable, Sendable {
    /// 段落 / 标题 / 段落簇 / 当段落画的独立链接：一个 ParagraphUIView
    case text
    /// 还没有原生实现的块（列表、代码块、表格、引用、公式、折叠块、分隔线）
    case other
  }

  public let id: String
  public let kind: Kind
  let renderable: MarkdownRenderable

  init(_ renderable: MarkdownRenderable) {
    self.renderable = renderable
    id = renderable.id
    switch renderable {
    case .paragraph, .heading, .textRun, .standaloneLink: kind = .text
    default: kind = .other
    }
  }

  /// 这一块的文字和它用不用配置里的段内行距（标题、段落簇不用：行距已经写在各段的段落样式里）
  var text: (contents: NSMutableAttributedString, usesParagraphLineSpacing: Bool)? {
    switch renderable {
    case .paragraph(_, let contents), .standaloneLink(_, _, _, let contents): return (contents, true)
    case .heading(_, _, let contents), .textRun(_, let contents): return (contents, false)
    default: return nil
    }
  }

  func lineSpacing(config: MarkdownRenderConfig) -> CGFloat? {
    guard let text, text.usesParagraphLineSpacing else { return nil }
    return config.paragraphLineSpacing ?? 5
  }

  /// 后台线程可算的高度：TextKit 对最终属性串（已套行距）量一遍，向上取整。
  /// 它和 `MarkdownTextBlockView.measuredSize` 是否逐值相等，由 MarkdownBlockRowsTests 钉住。
  /// 段落簇（`mergesTextRuns`，只有长按预览用）不给：多段并在一个文本视图里时两种量法差 1–5pt
  ///（末行行距、段间距的取整），要高度就在主线程用 `measuredSize`。
  public func preparedHeight(width: CGFloat, config: MarkdownRenderConfig) -> CGFloat? {
    if case .textRun = renderable { return nil }
    guard let text else { return nil }
    var string: NSAttributedString = text.contents
    if let lineSpacing = lineSpacing(config: config) {
      let copy = NSMutableAttributedString(attributedString: text.contents)
      copy.setLineSpacing(lineSpacing)
      string = copy
    }
    let bounds = string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    return bounds.height.rounded(.up)
  }
}

extension RenderableDocument {
  /// BlockView 里块与块之间的间距（iOS 恒 30）
  public static let blockSpacing: CGFloat = 30

  /// 顶层块，顺序同文档
  public var blocks: [MarkdownBlock] { renderables.map(MarkdownBlock.init) }
}

/// 文字块的原生视图：里面就是 SwiftUI 那条路用的同一个 ParagraphUIView
@MainActor
public final class MarkdownTextBlockView: UIView {
  private let paragraph = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(contents: NSMutableAttributedString(), lineSpacing: nil)

  public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    paragraph.frame = bounds
    paragraph.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(paragraph)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("不从 nib 建") }

  public func configure(_ block: MarkdownBlock, config: MarkdownRenderConfig, controller: MarkdownController? = nil,
                        onUrlTap: ((URL) -> Void)? = nil) {
    guard let text = block.text else { return }
    paragraph.setParagraphContents(text.contents, lineSpacing: block.lineSpacing(config: config), animatedByWord: false)
    paragraph.setTextContextMenu(config.textContextMenu)
    paragraph.setMarkdownController(controller)
    paragraph.setTextHighlights(config.textHighlights)
    if let onUrlTap { paragraph.onUrlTap = onUrlTap }
  }

  private static let measuring = ParagraphUIView(frame: .zero, textContainer: nil)

  /// 实排尺寸，同 `ParagraphView.sizeThatFits`：用真的文本视图量，高向上取整。宽是文字实际占的宽（气泡抱字用）
  public static func measuredSize(_ block: MarkdownBlock, width: CGFloat, config: MarkdownRenderConfig) -> CGSize? {
    guard let text = block.text else { return nil }
    measuring.setParagraphContents(text.contents, lineSpacing: block.lineSpacing(config: config), animatedByWord: false)
    let size = measuring.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: size.width, height: size.height.rounded(.up))
  }
}

#endif
