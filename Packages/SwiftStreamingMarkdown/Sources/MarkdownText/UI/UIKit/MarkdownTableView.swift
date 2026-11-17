// MP fork（docs/plan-重构.md R3）：表格的原生视图。排法照 SwiftUI 版 `TableView` + `TableLayout`，
// 图层结构照 11-12 从旧页读出来的：横向滚动里一张格子图，格子图裁 12 的连续曲率圆角；
// 表头格有底色；每格在自己的右边、下边里侧画 1pt 的线（最后一列不画右边、最后一行不画下边）；最上面一圈 1pt 描边。
#if os(iOS)

import UIKit

/// 一张表排好以后的样子（不含横向滚动的位置）
struct MarkdownTableLayout {
  struct Cell {
    let text: NSAttributedString
    /// 文字在格子里的位置
    let textFrame: CGRect
  }

  let columnWidths: [CGFloat]
  let rowHeights: [CGFloat]
  /// 第 0 行是表头
  let cells: [[Cell]]

  var size: CGSize { CGSize(width: columnWidths.reduce(0, +), height: rowHeights.reduce(0, +)) }

  private static let padding: CGFloat = 12
  /// 格子里文字后面跟着一个 Spacer，它最少占 8（系统默认间距）
  private static let spacerMinimum: CGFloat = 8
  /// 一列最宽：200 和「可见宽度平分」里大的那个
  private static let defaultMaxColumnWidth: CGFloat = 200

  @MainActor
  init(headers: [NSMutableAttributedString], rows: [[NSMutableAttributedString]], availableWidth: CGFloat,
       config: MarkdownRenderConfig, scale: CGFloat) {
    func ceilToPixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
    let columnCount = headers.count
    let style = config.tableStyle
    let source = [headers] + rows.map { Array($0.prefix(columnCount)) + Array(repeating: NSMutableAttributedString(), count: max(0, columnCount - $0.count)) }

    // 没自带颜色的字用表格的字色；多行时每行行高取到整像素（SwiftUI 的 Text 这样排，见 MarkdownBlockLayout 的引用块）
    let texts: [[NSAttributedString]] = source.enumerated().map { rowIndex, row in
      row.map { cell in
        let text = NSMutableAttributedString(attributedString: cell)
        let range = NSRange(location: 0, length: text.length)
        let color = rowIndex == 0 ? style.headerTextColor : style.regularTextColor
        text.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
          if value == nil { text.addAttribute(.foregroundColor, value: color, range: sub) }
        }
        let font = (text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil) ?? style.textFonts.normal
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = ceilToPixel(font.lineHeight) - font.lineHeight
        text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return text
      }
    }
    func textSize(_ text: NSAttributedString, width: CGFloat) -> CGSize {
      let bounds = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
      return CGSize(width: ceilToPixel(bounds.width), height: ceilToPixel(bounds.height))
    }

    let maxWidth = max(availableWidth / CGFloat(max(columnCount, 1)), Self.defaultMaxColumnWidth)
    var widths = Array(repeating: CGFloat(0), count: columnCount)
    for row in texts {
      for (column, text) in row.enumerated() {
        let ideal = textSize(text, width: .greatestFiniteMagnitude).width + Self.spacerMinimum + Self.padding * 2
        widths[column] = min(max(widths[column], ideal), maxWidth)
      }
    }
    var heights: [CGFloat] = []
    var cells: [[Cell]] = []
    for row in texts {
      let sizes = row.enumerated().map { column, text in
        textSize(text, width: widths[column] - Self.spacerMinimum - Self.padding * 2)
      }
      heights.append((sizes.map(\.height).max() ?? 0) + Self.padding * 2)
      cells.append(zip(row, sizes).map { text, size in
        Cell(text: text, textFrame: CGRect(origin: CGPoint(x: Self.padding, y: Self.padding), size: size))
      })
    }
    columnWidths = widths
    rowHeights = heights
    self.cells = cells
  }
}

@MainActor
final class MarkdownTableView: UIView {
  private let scroll = UIScrollView()
  private let grid = UIView()
  /// 表头底色和格线都在这一层里，垫在文字下面
  private let decor = CALayer()
  private let strokeClip = CALayer()
  private let stroke = CALayer()
  /// 每个色块外面各套一层自己的圆角裁切（SwiftUI 把 `.cornerRadius(12)` 摊到每个叶子上，旧页就是一个零件一层裁切）。
  /// 整张图只裁一次的话，半透明的表头底和描边在圆角边缘先叠后裁，和旧页「各裁各的再叠」差 1–2 个色阶
  private var fills: [(clip: CALayer, fill: CALayer)] = []
  private var labels: [UILabel] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    scroll.backgroundColor = .clear
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    addSubview(scroll)
    grid.backgroundColor = .clear
    scroll.addSubview(grid)
    grid.layer.addSublayer(decor)
    for layer in [strokeClip, stroke] {
      layer.cornerRadius = 12
      layer.cornerCurve = .continuous
    }
    strokeClip.masksToBounds = true
    strokeClip.addSublayer(stroke)
    stroke.borderWidth = 1
    stroke.allowsEdgeAntialiasing = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("不从 nib 建") }

  func apply(_ layout: MarkdownTableLayout, config: MarkdownRenderConfig) {
    let scale = max(traitCollection.displayScale, 1)
    let style = config.tableStyle
    let border = style.borderColor.resolvedColor(with: traitCollection).cgColor
    scroll.frame = bounds
    scroll.contentSize = layout.size
    grid.frame = CGRect(origin: .zero, size: layout.size)

    var usedFills = 0
    func fill(_ frame: CGRect, _ color: CGColor) {
      if usedFills == fills.count {
        let clip = CALayer()
        clip.cornerRadius = 12
        clip.cornerCurve = .continuous
        clip.masksToBounds = true
        let layer = CALayer()
        clip.addSublayer(layer)
        decor.addSublayer(clip)
        fills.append((clip, layer))
      }
      let (clip, layer) = fills[usedFills]
      usedFills += 1
      clip.isHidden = false
      clip.frame = CGRect(origin: .zero, size: layout.size)
      clip.contentsScale = scale
      layer.frame = frame
      layer.backgroundColor = color
      layer.contentsScale = scale
    }
    var usedLabels = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    var y: CGFloat = 0
    for (rowIndex, row) in layout.cells.enumerated() {
      var x: CGFloat = 0
      let height = layout.rowHeights[rowIndex]
      for (column, cell) in row.enumerated() {
        let width = layout.columnWidths[column]
        if rowIndex == 0 {
          fill(CGRect(x: x, y: y, width: width, height: height), style.headerBackgroundColor.resolvedColor(with: traitCollection).cgColor)
        }
        let hasBottom = rowIndex == 0 || rowIndex < layout.cells.count - 1
        let hasTrailing = column < row.count - 1
        if hasBottom { fill(CGRect(x: x, y: y + height - 1, width: width, height: 1), border) }
        // 右边和下边在角上重叠的那 1×1 只画一次（线是半透明的，画两次会深一块）
        if hasTrailing { fill(CGRect(x: x + width - 1, y: y, width: 1, height: hasBottom ? height - 1 : height), border) }

        if usedLabels == labels.count {
          let label = UILabel()
          label.backgroundColor = .clear
          label.numberOfLines = 0
          grid.addSubview(label)
          labels.append(label)
        }
        let label = labels[usedLabels]
        usedLabels += 1
        label.isHidden = false
        label.attributedText = cell.text
        label.frame = cell.textFrame.offsetBy(dx: x, dy: y)
        x += width
      }
      y += height
    }
    fills[usedFills...].forEach { $0.clip.isHidden = true }
    labels[usedLabels...].forEach { $0.isHidden = true }
    decor.frame = grid.bounds
    strokeClip.frame = grid.bounds
    strokeClip.contentsScale = scale
    stroke.frame = grid.bounds
    stroke.borderColor = border
    stroke.contentsScale = scale
    grid.layer.addSublayer(strokeClip)   // 描边永远在最上面
    CATransaction.commit()
  }
}

#endif
