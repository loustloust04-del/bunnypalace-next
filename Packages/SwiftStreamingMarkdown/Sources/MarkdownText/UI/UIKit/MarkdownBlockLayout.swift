// MP fork（docs/plan-重构.md R3）：顶层块的原生排版。
// SwiftUI 那条路是 SingleBlockView → 各种 *View（VStack / HStack 摆位）；这里把同样的摆位规则算成一张
// 「每件东西放在哪」的表（排一次），`MarkdownBlockView` 照着摆（不再量）。规则逐条对着 SwiftUI 版写，
// 对不对由 app 里的新旧像素对拍判定——改这里的数之前先看对应的 SwiftUI 视图。
#if os(iOS)

import SwiftUI
import UIKit

/// 一个顶层块排好以后的样子
public struct MarkdownBlockLayout: @unchecked Sendable {
  enum Piece {
    /// 一段正文（ParagraphUIView）
    case text(contents: NSMutableAttributedString, lineSpacing: CGFloat?, frame: CGRect)
    /// 纯色块（分隔线、引用竖线）：带底色的普通图层，连续曲率圆角
    case fill(color: UIColor, frame: CGRect, cornerRadius: CGFloat)
    /// 矢量图形（列表圆点）：形状图层，路径按 frame 的大小缩放
    case glyph(Glyph, color: UIColor, frame: CGRect)
    /// 一行或几行纯文字（SwiftUI 版里是 Text：有序列表的序号、引用正文）
    case label(text: String, font: UIFont, color: UIColor, kern: CGFloat?, lineSpacing: CGFloat, frame: CGRect)
    /// 代码块：自己有状态（复制后的对勾、横向滚动、着色），是一个单独的视图
    case code(language: String, code: String, frame: CGRect)
    /// 表格：横向滚动的一张格子图，也是一个单独的视图
    case table(MarkdownTableLayout, frame: CGRect)

    /// 位置取整到像素（SwiftUI 把每个视图的位置各自取整；对齐线算出来的零头不能留在最终位置里）
    func snapped(scale: CGFloat) -> Piece {
      func snap(_ frame: CGRect) -> CGRect {
        CGRect(x: (frame.minX * scale).rounded() / scale, y: (frame.minY * scale).rounded() / scale,
               width: frame.width, height: frame.height)
      }
      switch self {
      case .text(let contents, let lineSpacing, let frame):
        return .text(contents: contents, lineSpacing: lineSpacing, frame: snap(frame))
      case .fill(let color, let frame, let cornerRadius):
        // 色块四条边各自取整：0.5 高的分隔线在 3x 屏上是 1.5 个像素，SwiftUI 画出来是整 2 个像素
        let maxX = (frame.maxX * scale).rounded() / scale
        let maxY = (frame.maxY * scale).rounded() / scale
        let origin = snap(frame).origin
        return .fill(color: color, frame: CGRect(x: origin.x, y: origin.y, width: maxX - origin.x, height: maxY - origin.y),
                     cornerRadius: cornerRadius)
      case .glyph(let glyph, let color, let frame):
        return .glyph(glyph, color: color, frame: snap(frame))
      case .label(let text, let font, let color, let kern, let lineSpacing, let frame):
        return .label(text: text, font: font, color: color, kern: kern, lineSpacing: lineSpacing, frame: snap(frame))
      case .code(let language, let code, let frame):
        return .code(language: language, code: code, frame: snap(frame))
      case .table(let table, let frame):
        return .table(table, frame: snap(frame))
      }
    }
  }

  /// SwiftUI 画 `Image(systemName:).resizable()` 用的是形状图层 + 符号的矢量轮廓（11-12 从旧页的图层里读出来的）。
  /// 系统没有公开拿符号轮廓的接口，用到的两个符号的轮廓照抄在这里（单位：框的宽高各算 1）
  enum Glyph: Hashable {
    case circleFill
    /// 空心圆（嵌套一层的无序列表）
    case circle

    /// 轮廓的几段三次曲线，坐标按 4×4 的框（读出来时的原样）
    func path(in size: CGSize) -> CGPath {
      let sx = size.width / 4, sy = size.height / 4
      func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
      let path = CGMutablePath()
      switch self {
      case .circleFill:
        path.move(to: point(1.9922, 4.0508))
        path.addCurve(to: point(3.9844, 2.0586), control1: point(3.0918, 4.0508), control2: point(3.9844, 3.1563))
        path.addCurve(to: point(1.9922, 0.0664), control1: point(3.9844, 0.9590), control2: point(3.0918, 0.0664))
        path.addCurve(to: point(0, 2.0586), control1: point(0.8945, 0.0664), control2: point(0, 0.9590))
        path.addCurve(to: point(1.9922, 4.0508), control1: point(0, 3.1563), control2: point(0.8945, 4.0508))
        path.closeSubpath()
      case .circle:
        path.move(to: point(1.9922, 4.0508))
        path.addCurve(to: point(3.9844, 2.0586), control1: point(3.0918, 4.0508), control2: point(3.9844, 3.1582))
        path.addCurve(to: point(1.9922, 0.0664), control1: point(3.9844, 0.9590), control2: point(3.0918, 0.0664))
        path.addCurve(to: point(0, 2.0586), control1: point(0.8926, 0.0664), control2: point(0, 0.9590))
        path.addCurve(to: point(1.9922, 4.0508), control1: point(0, 3.1582), control2: point(0.8926, 4.0508))
        path.closeSubpath()
        path.move(to: point(1.9922, 3.7188))
        path.addCurve(to: point(0.3320, 2.0586), control1: point(1.0742, 3.7188), control2: point(0.3320, 2.9766))
        path.addCurve(to: point(1.9922, 0.3984), control1: point(0.3320, 1.1406), control2: point(1.0742, 0.3984))
        path.addCurve(to: point(3.6523, 2.0586), control1: point(2.9102, 0.3984), control2: point(3.6523, 1.1406))
        path.addCurve(to: point(1.9922, 3.7188), control1: point(3.6523, 2.9766), control2: point(2.9102, 3.7188))
        path.closeSubpath()
      }
      return path
    }
  }

  public let size: CGSize
  let pieces: [Piece]
}

extension MarkdownBlock {
  /// 在给定宽度里排这一块。nil = 这种块还没有原生实现。要用真的文本视图量字，所以只能在主线程。
  /// `hostClaimsCodeBlock`：宿主要自己画的代码块（语言、内容）——对应 SwiftUI 版的 `customBlockRenderer`，这种块这里不排
  @MainActor
  public func layout(width: CGFloat, config: MarkdownRenderConfig, displayScale: CGFloat,
                     hostClaimsCodeBlock: (String, String) -> Bool = { _, _ in false }) -> MarkdownBlockLayout? {
    var builder = MarkdownBlockLayoutBuilder(config: config, scale: displayScale)
    if case .codeBlock(_, let language, let code) = renderable, hostClaimsCodeBlock(language ?? "", code) { return nil }
    guard let size = builder.place(renderable, at: .zero, width: width) else { return nil }
    // 整块的高也取到像素：行是一行一行往上摞的，零头留着会让上面所有的行都落在半个像素上
    return MarkdownBlockLayout(size: CGSize(width: size.width, height: (size.height * displayScale).rounded() / displayScale),
                               pieces: builder.pieces.map { $0.snapped(scale: displayScale) })
  }
}

@MainActor
struct MarkdownBlockLayoutBuilder {
  let config: MarkdownRenderConfig
  let scale: CGFloat
  private(set) var pieces: [MarkdownBlockLayout.Piece] = []

  init(config: MarkdownRenderConfig, scale: CGFloat) {
    self.config = config
    self.scale = scale
  }

  private static let measuring = ParagraphUIView(frame: .zero, textContainer: nil)
  private static let bulletColor = UIColor(Color.Theme.Foreground.Primary.Primary450)
  private static let mint = (red: 142.0 / 255.0, green: 189.0 / 255.0, blue: 159.0 / 255.0)

  /// 向上取到整像素（SwiftUI 的 Text 这样取自己的宽高）
  private func ceilToPixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }

  /// 同 `ParagraphView.sizeThatFits`：真的文本视图量，高向上取整
  private func textSize(_ contents: NSMutableAttributedString, lineSpacing: CGFloat?, width: CGFloat) -> CGSize {
    Self.measuring.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    let size = Self.measuring.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: size.width, height: size.height.rounded(.up))
  }

  private mutating func placeText(_ contents: NSMutableAttributedString, lineSpacing: CGFloat?, at origin: CGPoint,
                                  width: CGFloat) -> CGSize {
    let size = textSize(contents, lineSpacing: lineSpacing, width: width)
    pieces.append(.text(contents: contents, lineSpacing: lineSpacing, frame: CGRect(origin: origin, size: size)))
    return size
  }

  /// 返回这一块占的大小；不支持的块返回 nil（已经加进去的零件由调用方丢弃整张表）
  mutating func place(_ renderable: MarkdownRenderable, at origin: CGPoint, width: CGFloat) -> CGSize? {
    switch renderable {
    case .paragraph(_, let contents), .standaloneLink(_, _, _, let contents):
      return placeText(contents, lineSpacing: config.paragraphLineSpacing ?? 5, at: origin, width: width)
    case .heading(_, _, let contents), .textRun(_, let contents):
      return placeText(contents, lineSpacing: nil, at: origin, width: width)
    case .thematicBreak:
      // ThematicBreakView：0.5 高的线，左右各缩 48，上下各留 12；线是贪心的，整块占满宽
      pieces.append(.fill(color: UIColor(red: Self.mint.red, green: Self.mint.green, blue: Self.mint.blue, alpha: 0.4),
                          frame: CGRect(x: origin.x + 48, y: origin.y + 12, width: max(0, width - 96), height: 0.5),
                          cornerRadius: 0))
      return CGSize(width: width, height: 24.5)
    case .unorderedList(_, let items, let nestedLevel):
      return placeList(items, at: origin, width: width, indent: CGFloat(nestedLevel) * 8) { builder, _, rowOrigin, lineHeight in
        // 圆点：22 宽的格子里居中一个 4×4，竖向对齐首行的中线；格子和正文之间 1
        builder.pieces.append(.glyph(nestedLevel % 2 == 0 ? .circleFill : .circle, color: Self.bulletColor,
                                     frame: CGRect(x: rowOrigin.x + 9, y: rowOrigin.y + lineHeight / 2 - 2, width: 4, height: 4)))
        return (markerWidth: 22, spacing: 1, markerHalfHeight: 2)
      }
    case .orderedList(_, let items):
      let fonts = config.orderedListStyle.textFonts
      let font = fonts.bold ?? fonts.normal
      let color = config.orderedListStyle.textColor
      return placeList(items, at: origin, width: width, indent: 0) { builder, index, rowOrigin, lineHeight in
        // 序号：粗体的 Text，包住字；竖向中线对齐首行中线；和正文之间 11
        let text = "\(index + 1)."
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let kern = fonts.preferredLetterSpacing { attributes[.kern] = kern }
        let labelSize = CGSize(width: builder.ceilToPixel((text as NSString).size(withAttributes: attributes).width),
                               height: builder.ceilToPixel(font.lineHeight))
        let half = labelSize.height / 2
        builder.pieces.append(.label(text: text, font: font, color: color, kern: fonts.preferredLetterSpacing, lineSpacing: 0,
                                     frame: CGRect(x: rowOrigin.x, y: rowOrigin.y + max(0, lineHeight / 2 - half),
                                                   width: labelSize.width, height: labelSize.height)))
        return (markerWidth: labelSize.width, spacing: 11, markerHalfHeight: half)
      }
    case .blockQuote(_, let item):
      // BlockQuoteView：3 宽的竖线 + 8 + 正文（再缩 4）；正文一侧有 Spacer，整块占满宽
      let barIndex = pieces.count
      pieces.append(.fill(color: .clear, frame: .zero, cornerRadius: 0))
      let height = placeQuote(item.quoteType, at: CGPoint(x: origin.x + 15, y: origin.y), width: width - 15)
      // 竖线：SwiftUI 版写的半径是 8，3 宽的框里实际落成 1.5（旧页图层里读到的）
      pieces[barIndex] = .fill(color: UIColor(red: Self.mint.red, green: Self.mint.green, blue: Self.mint.blue, alpha: 0.6),
                               frame: CGRect(x: origin.x, y: origin.y, width: 3, height: height), cornerRadius: 1.5)
      return CGSize(width: width, height: height)
    case .codeBlock(_, let language, let code):
      let size = MarkdownCodeBlockView.size(code: code, width: width, config: config, scale: scale)
      pieces.append(.code(language: language ?? "", code: code, frame: CGRect(origin: origin, size: size)))
      return size
    case .table(_, let headers, let rows, _):
      // 横向滚动占满可用宽，高 = 格子图的高
      let table = MarkdownTableLayout(headers: headers, rows: rows, availableWidth: width, config: config, scale: scale)
      let size = CGSize(width: width, height: table.size.height)
      pieces.append(.table(table, frame: CGRect(origin: origin, size: size)))
      return size
    case .latex, .details:
      return nil
    }
  }

  /// 有序 / 无序列表共用的骨架：VStack(spacing 8)，每项一行「标记 + 首段」，这一项剩下的块（嵌套列表等）
  /// 另起一行、按块距 30 往下排、不再缩进。`marker` 画标记并返回它的宽、和正文的间距、它中线到自己顶边的距离
  private mutating func placeList(
    _ items: [MarkdownListItem], at origin: CGPoint, width: CGFloat, indent: CGFloat,
    marker: (inout MarkdownBlockLayoutBuilder, Int, CGPoint, CGFloat) -> (markerWidth: CGFloat, spacing: CGFloat, markerHalfHeight: CGFloat)
  ) -> CGSize? {
    let left = origin.x + indent
    let available = width - indent
    var y = origin.y
    var widest: CGFloat = 0
    var first = true
    func advance(_ y: inout CGFloat) {
      if !first { y += 8 }
      first = false
    }
    for (index, item) in items.enumerated() {
      guard let head = item.children.first else { continue }
      guard case .paragraph(_, let contents) = head else { return nil }   // 首块不是段落的列表项先不做
      advance(&y)
      let lineHeight = listItemFirstFont(in: contents).lineHeight
      let metrics = marker(&self, index, CGPoint(x: left, y: y), lineHeight)
      // 标记比首行高的时候（不该出现），正文往下让
      let textTop = y + max(0, metrics.markerHalfHeight - lineHeight / 2)
      let textX = left + metrics.markerWidth + metrics.spacing
      let size = placeText(contents, lineSpacing: config.paragraphLineSpacing ?? 5,
                           at: CGPoint(x: textX, y: textTop), width: available - metrics.markerWidth - metrics.spacing)
      widest = max(widest, metrics.markerWidth + metrics.spacing + size.width)
      y = max(textTop + size.height, y + metrics.markerHalfHeight * 2)
      let rest = item.children.dropFirst()
      guard !rest.isEmpty else { continue }
      advance(&y)
      for (offset, child) in rest.enumerated() {
        if offset > 0 { y += RenderableDocument.blockSpacing }
        guard let size = place(child, at: CGPoint(x: left, y: y), width: available) else { return nil }
        widest = max(widest, size.width)
        y += size.height
      }
    }
    return CGSize(width: indent + widest, height: y - origin.y)
  }

  /// InternalBlockQuoteView：上下各 4；文字再上下各 4；嵌套的几段之间隔 12。返回占的高
  private mutating func placeQuote(_ quote: BlockQuoteType, at origin: CGPoint, width: CGFloat) -> CGFloat {
    switch quote {
    case .text(let text):
      let fonts = config.blockQuoteStyle.textFonts
      // SwiftUI 的 Text 每行的行高向上取到整像素；UILabel 用字体原始行高。差的那一点补成行间距
      let lineSpacing = ceilToPixel(fonts.normal.lineHeight) - fonts.normal.lineHeight
      let style = NSMutableParagraphStyle()
      style.lineSpacing = lineSpacing
      var attributes: [NSAttributedString.Key: Any] = [.font: fonts.normal, .paragraphStyle: style]
      if let kern = fonts.preferredLetterSpacing { attributes[.kern] = kern }
      let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: attributes, context: nil)
      let size = CGSize(width: ceilToPixel(bounds.width), height: ceilToPixel(bounds.height))
      pieces.append(.label(text: text, font: fonts.normal, color: config.blockQuoteStyle.textColor,
                           kern: fonts.preferredLetterSpacing, lineSpacing: lineSpacing,
                           frame: CGRect(x: origin.x, y: origin.y + 8, width: size.width, height: size.height)))
      return size.height + 16
    case .nested(let items):
      var y = origin.y + 4
      for (index, item) in items.enumerated() {
        if index > 0 { y += 12 }
        y += placeQuote(item, at: CGPoint(x: origin.x, y: y), width: width)
      }
      return y + 4 - origin.y
    }
  }
}

/// 照着 `MarkdownBlockLayout` 摆零件的视图。自己不量、不排
@MainActor
public final class MarkdownBlockView: UIView {
  private var paragraphs: [ParagraphUIView] = []
  private var fills: [CALayer] = []
  private var glyphs: [CAShapeLayer] = []
  private var labels: [UILabel] = []
  private var codeBlocks: [MarkdownCodeBlockView] = []
  private var tables: [MarkdownTableView] = []

  public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("不从 nib 建") }

  public func apply(_ layout: MarkdownBlockLayout, config: MarkdownRenderConfig) {
    var used = (paragraphs: 0, fills: 0, glyphs: 0, labels: 0, codeBlocks: 0, tables: 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for piece in layout.pieces {
      switch piece {
      case .text(let contents, let lineSpacing, let frame):
        if used.paragraphs == paragraphs.count {
          let view = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(contents: NSMutableAttributedString(), lineSpacing: nil)
          addSubview(view)
          paragraphs.append(view)
        }
        let view = paragraphs[used.paragraphs]
        used.paragraphs += 1
        view.isHidden = false
        view.frame = frame
        view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
        view.setTextContextMenu(config.textContextMenu)
        view.setMarkdownController(nil)
        view.setTextHighlights(config.textHighlights)
      case .fill(let color, let frame, let cornerRadius):
        if used.fills == fills.count {
          let fill = CALayer()
          fill.contentsScale = traitCollection.displayScale
          fill.allowsEdgeAntialiasing = true
          fill.cornerCurve = .continuous
          layer.addSublayer(fill)
          fills.append(fill)
        }
        let fill = fills[used.fills]
        used.fills += 1
        fill.isHidden = false
        fill.frame = frame
        fill.backgroundColor = color.cgColor
        fill.cornerRadius = cornerRadius
      case .glyph(let glyph, let color, let frame):
        if used.glyphs == glyphs.count {
          let shape = CAShapeLayer()
          shape.contentsScale = traitCollection.displayScale
          shape.allowsEdgeAntialiasing = true
          layer.addSublayer(shape)
          glyphs.append(shape)
        }
        let shape = glyphs[used.glyphs]
        used.glyphs += 1
        shape.isHidden = false
        shape.frame = frame
        shape.path = glyph.path(in: frame.size)
        shape.fillColor = color.resolvedColor(with: traitCollection).cgColor
      case .table(let table, let frame):
        if used.tables == tables.count {
          let view = MarkdownTableView(frame: frame)
          addSubview(view)
          tables.append(view)
        }
        let view = tables[used.tables]
        used.tables += 1
        view.isHidden = false
        view.frame = frame
        view.apply(table, config: config)
      case .code(let language, let code, let frame):
        if used.codeBlocks == codeBlocks.count {
          let view = MarkdownCodeBlockView(frame: frame)
          addSubview(view)
          codeBlocks.append(view)
        }
        let view = codeBlocks[used.codeBlocks]
        used.codeBlocks += 1
        view.isHidden = false
        view.frame = frame
        view.configure(language: language, code: code, config: config)
      case .label(let text, let font, let color, let kern, let lineSpacing, let frame):
        if used.labels == labels.count {
          let label = UILabel()
          label.backgroundColor = .clear
          label.numberOfLines = 0
          addSubview(label)
          labels.append(label)
        }
        let label = labels[used.labels]
        used.labels += 1
        label.isHidden = false
        label.frame = frame
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let kern { attributes[.kern] = kern }
        if lineSpacing > 0 {
          let style = NSMutableParagraphStyle()
          style.lineSpacing = lineSpacing
          attributes[.paragraphStyle] = style
        }
        label.attributedText = NSAttributedString(string: text, attributes: attributes)
      }
    }
    codeBlocks[used.codeBlocks...].forEach { $0.isHidden = true }
    tables[used.tables...].forEach { $0.isHidden = true }
    paragraphs[used.paragraphs...].forEach { $0.isHidden = true }
    fills[used.fills...].forEach { $0.isHidden = true }
    glyphs[used.glyphs...].forEach { $0.isHidden = true }
    labels[used.labels...].forEach { $0.isHidden = true }
    CATransaction.commit()
  }
}

#endif
