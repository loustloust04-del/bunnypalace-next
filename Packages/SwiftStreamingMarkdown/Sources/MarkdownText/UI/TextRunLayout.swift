//
//  MP fork: 段落簇（`.textRun`）的 TextKit 2 排版——让并进一个文字视图的几段，逐段落在和
//  「一块一个视图 + VStack 块距」完全相同的位置上（两端共用）。
//
//  一块一个视图时，第 k 块（段落 / 标题 / 列表项里的一个段落，下称「叶」）文字顶 T_k 由 VStack 摆出来，
//  每块的高被 ParagraphView 向上取整。并进一个视图后 TextKit 不会取整，段距也不认识块距，所以：
//  - 合并器在每叶第一个字上挂 `TextRunLeafStart`（叶号、本段行距、列表标记），在每叶最后一个段落的分隔符
//    （末叶是最后一个字）上挂 `TextRunBlockEnd`；
//  - 这里的布局片段在叶头记下 T_k（= 片段顶 + 本段行距：TextKit 2 在非首段的第一行上方加本段行距），
//    在叶尾把底改成 T_k + ceil(字底 - T_k)，列表行的标记比字高时取标记底，再接上 gapAfter（到下一叶的距离）。
//  - 列表的序号 / 圆点不进文字（选区、拷贝、划线 quote 都拿不到），由叶头片段画在缩进里。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension NSAttributedString.Key {
  /// MP fork: 段落簇里一叶的结束标记（值 `TextRunBlockEnd`）
  static let mpmdTextRunBlockEnd = NSAttributedString.Key("mpmd.textRunBlockEnd")
  /// MP fork: 段落簇里一叶的开头标记（值 `TextRunLeafStart`），挂在这一叶第一个字上
  static let mpmdTextRunLeafStart = NSAttributedString.Key("mpmd.textRunLeafStart")
}

/// 段落簇里一叶的结束标记。NSSecureCoding：文字视图拷贝富文本时会归档属性。
final class TextRunBlockEnd: NSObject, NSSecureCoding {
  /// 第几叶（簇内从 0 数），找同一叶的 T_k 用
  let leafIndex: Int
  /// 这一叶取整后的底到下一叶布局片段顶的距离（可为负）
  let gapAfter: CGFloat
  let isLast: Bool

  init(leafIndex: Int, gapAfter: CGFloat, isLast: Bool) {
    self.leafIndex = leafIndex
    self.gapAfter = gapAfter
    self.isLast = isLast
  }

  static var supportsSecureCoding: Bool { true }

  func encode(with coder: NSCoder) {
    coder.encode(leafIndex, forKey: "leafIndex")
    coder.encode(Double(gapAfter), forKey: "gapAfter")
    coder.encode(isLast, forKey: "isLast")
  }

  init?(coder: NSCoder) {
    leafIndex = coder.decodeInteger(forKey: "leafIndex")
    gapAfter = CGFloat(coder.decodeDouble(forKey: "gapAfter"))
    isLast = coder.decodeBool(forKey: "isLast")
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TextRunBlockEnd else { return false }
    return leafIndex == other.leafIndex && gapAfter == other.gapAfter && isLast == other.isLast
  }

  override var hash: Int {
    var hasher = Hasher()
    hasher.combine(leafIndex)
    hasher.combine(gapAfter)
    hasher.combine(isLast)
    return hasher.finalize()
  }
}

/// 段落簇里一叶的开头标记
final class TextRunLeafStart: NSObject, NSSecureCoding {
  let leafIndex: Int
  /// TextKit 2 在这一段第一行上方加的距离（= 本段行距；簇的第一段为 0）
  let topLineSpacing: CGFloat
  /// 片段整体往下挪多少：只有簇的第一叶会有（列表行的标记比字高、顶出字顶时，字顶 = 行顶 + 这段）
  let leadingInset: CGFloat
  /// 列表行的序号 / 圆点
  let marker: TextRunListMarker?

  init(leafIndex: Int, topLineSpacing: CGFloat, leadingInset: CGFloat, marker: TextRunListMarker?) {
    self.leafIndex = leafIndex
    self.topLineSpacing = topLineSpacing
    self.leadingInset = leadingInset
    self.marker = marker
  }

  static var supportsSecureCoding: Bool { true }

  func encode(with coder: NSCoder) {
    coder.encode(leafIndex, forKey: "leafIndex")
    coder.encode(Double(topLineSpacing), forKey: "topLineSpacing")
    coder.encode(Double(leadingInset), forKey: "leadingInset")
    coder.encode(marker, forKey: "marker")
  }

  init?(coder: NSCoder) {
    leafIndex = coder.decodeInteger(forKey: "leafIndex")
    topLineSpacing = CGFloat(coder.decodeDouble(forKey: "topLineSpacing"))
    leadingInset = CGFloat(coder.decodeDouble(forKey: "leadingInset"))
    marker = coder.decodeObject(of: TextRunListMarker.self, forKey: "marker")
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TextRunLeafStart else { return false }
    return leafIndex == other.leafIndex && topLineSpacing == other.topLineSpacing
      && leadingInset == other.leadingInset && marker == other.marker
  }

  override var hash: Int {
    var hasher = Hasher()
    hasher.combine(leafIndex)
    hasher.combine(topLineSpacing)
    hasher.combine(leadingInset)
    hasher.combine(marker)
    return hasher.finalize()
  }
}

/// 列表行的序号（「1.」）或圆点，画在这一行文字左边的缩进里。外观照 OrderedListView / UnorderedListView：
/// 竖直方向标记中心对齐第一行中心（`.centerOfFirstLine`，= 首字字体行高 / 2）；圆点 4×4 靠 22pt 宽格子的右边，
/// 序号是粗体正文字、和文字隔 11pt。
final class TextRunListMarker: NSObject, NSSecureCoding {
  enum Kind: Int {
    case filledBullet
    case hollowBullet
    case number
  }

  let kind: Kind
  /// 序号文字（圆点为空）
  let text: String
  let font: PlatformFont?
  let color: PlatformColor
  let kern: CGFloat?
  /// 标记框左边、宽、高（框 = OrderedListView 的 Text / UnorderedListView 的 4×4 Image）
  let x: CGFloat
  let width: CGFloat
  let height: CGFloat
  /// 标记框中心到这一行字顶的距离（首字字体行高 / 2）
  let centerFromTextTop: CGFloat

  init(kind: Kind, text: String, font: PlatformFont?, color: PlatformColor, kern: CGFloat?,
       x: CGFloat, width: CGFloat, height: CGFloat, centerFromTextTop: CGFloat) {
    self.kind = kind
    self.text = text
    self.font = font
    self.color = color
    self.kern = kern
    self.x = x
    self.width = width
    self.height = height
    self.centerFromTextTop = centerFromTextTop
  }

  /// 标记框顶出字顶多少（HStack 按标记顶摆行，字被往下推这么多）
  var topInset: CGFloat { max(0, height / 2 - centerFromTextTop) }
  /// 标记框底到字顶的距离（行高可能被它撑大）
  var bottomFromTextTop: CGFloat { centerFromTextTop + height / 2 }

  func frame(textTop: CGFloat, originX: CGFloat) -> CGRect {
    CGRect(x: originX + x, y: textTop + centerFromTextTop - height / 2, width: width, height: height)
  }

  var attributedText: NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
    if let font { attributes[.font] = font }
    if let kern { attributes[.kern] = kern }
    return NSAttributedString(string: text, attributes: attributes)
  }

  /// 在片段的绘制上下文里画（y 向下）
  func draw(in context: CGContext, textTop: CGFloat, originX: CGFloat) {
    let rect = frame(textTop: textTop, originX: originX)
    switch kind {
    case .number:
      #if canImport(UIKit)
      UIGraphicsPushContext(context)
      attributedText.draw(at: rect.origin)
      UIGraphicsPopContext()
      #else
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      attributedText.draw(at: rect.origin)
      NSGraphicsContext.restoreGraphicsState()
      #endif
    case .filledBullet:
      // SwiftUI 的 resizable SF Symbol「circle.fill」铺满 4×4 框 = 一个 4pt 的实心圆
      context.saveGState()
      context.setFillColor(resolvedColor.cgColor)
      context.fillEllipse(in: rect)
      context.restoreGState()
    case .hollowBullet:
      // 「circle」铺满 4×4：环线约为直径的 1/12
      let lineWidth = rect.width / 12
      context.saveGState()
      context.setStrokeColor(resolvedColor.cgColor)
      context.setLineWidth(lineWidth)
      context.strokeEllipse(in: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
      context.restoreGState()
    }
  }

  /// 动态色（深浅色）按当前外观取值：iOS 绘制时 UITraitCollection.current、mac 绘制时 NSAppearance.current 已是视图的
  private var resolvedColor: PlatformColor {
    #if canImport(UIKit)
    color.resolvedColor(with: UITraitCollection.current)
    #else
    var resolved = color
    NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB) ?? color
    }
    return resolved
    #endif
  }

  static var supportsSecureCoding: Bool { true }

  func encode(with coder: NSCoder) {
    coder.encode(kind.rawValue, forKey: "kind")
    coder.encode(text as NSString, forKey: "text")
    coder.encode(font, forKey: "font")
    coder.encode(color, forKey: "color")
    coder.encode(kern.map { NSNumber(value: Double($0)) }, forKey: "kern")
    coder.encode(Double(x), forKey: "x")
    coder.encode(Double(width), forKey: "width")
    coder.encode(Double(height), forKey: "height")
    coder.encode(Double(centerFromTextTop), forKey: "centerFromTextTop")
  }

  init?(coder: NSCoder) {
    guard let kind = Kind(rawValue: coder.decodeInteger(forKey: "kind")),
          let color = coder.decodeObject(of: PlatformColor.self, forKey: "color") else { return nil }
    self.kind = kind
    text = (coder.decodeObject(of: NSString.self, forKey: "text") as String?) ?? ""
    font = coder.decodeObject(of: PlatformFont.self, forKey: "font")
    self.color = color
    kern = coder.decodeObject(of: NSNumber.self, forKey: "kern").map { CGFloat($0.doubleValue) }
    x = CGFloat(coder.decodeDouble(forKey: "x"))
    width = CGFloat(coder.decodeDouble(forKey: "width"))
    height = CGFloat(coder.decodeDouble(forKey: "height"))
    centerFromTextTop = CGFloat(coder.decodeDouble(forKey: "centerFromTextTop"))
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? TextRunListMarker else { return false }
    return kind == other.kind && text == other.text && font == other.font && color == other.color && kern == other.kern
      && x == other.x && width == other.width && height == other.height && centerFromTextTop == other.centerFromTextTop
  }

  override var hash: Int {
    var hasher = Hasher()
    hasher.combine(kind)
    hasher.combine(text)
    hasher.combine(x)
    hasher.combine(centerFromTextTop)
    return hasher.finalize()
  }
}

/// 一个文字视图（一个布局管理器）里各叶的字顶 T_k：叶头片段算框时写，叶尾片段取整时读。
/// 叶头一定先于叶尾算框（叶尾的顶 = 前一个片段的底）。
final class TextRunLayoutState {
  var leafTops: [Int: CGFloat] = [:]
}

/// 段落簇里一叶的头 / 尾片段：头记字顶、画列表标记；尾把底取整、接上到下一叶的距离
final class TextRunLayoutFragment: NSTextLayoutFragment {
  private let leafStart: TextRunLeafStart?
  private let blockEnd: TextRunBlockEnd?
  /// 本段落样式里的段距（TextKit 已算进片段高；字底 = 片段底 - 段距）
  private let paragraphSpacing: CGFloat
  private let runState: TextRunLayoutState

  init(textElement: NSTextElement, range: NSTextRange?, leafStart: TextRunLeafStart?, blockEnd: TextRunBlockEnd?,
       paragraphSpacing: CGFloat, runState: TextRunLayoutState) {
    self.leafStart = leafStart
    self.blockEnd = blockEnd
    self.paragraphSpacing = paragraphSpacing
    self.runState = runState
    super.init(textElement: textElement, range: range)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override var layoutFragmentFrame: CGRect {
    var frame = super.layoutFragmentFrame
    guard frame.height > 0 else { return frame }
    var leafTop: CGFloat?
    if let leafStart {
      frame.origin.y += leafStart.leadingInset
      let top = frame.minY + leafStart.topLineSpacing
      runState.leafTops[leafStart.leafIndex] = top
      leafTop = top
    }
    if let blockEnd {
      let top = leafTop ?? runState.leafTops[blockEnd.leafIndex] ?? frame.minY
      // 先按 1e-4 抹掉浮点噪声（T_k 是小数相加），再像 ParagraphView 那样把这一叶的高向上取整
      let textHeight = (((frame.maxY - paragraphSpacing - top) * 10_000).rounded() / 10_000).rounded(.up)
      var bottom = top + textHeight
      if let marker = leafStart?.marker {
        bottom = max(bottom, top + marker.bottomFromTextTop)
      }
      if !blockEnd.isLast {
        bottom += blockEnd.gapAfter
      }
      frame.size.height = max(0, bottom - frame.minY)
    }
    return frame
  }

  // 片段自己的坐标原点在缩进处（框的 minX = 首行缩进），标记的 x 是从文字容器左边量的

  override var renderingSurfaceBounds: CGRect {
    let bounds = super.renderingSurfaceBounds
    guard let leafStart, let marker = leafStart.marker else { return bounds }
    let markerFrame = marker.frame(textTop: leafStart.topLineSpacing, originX: -layoutFragmentFrame.minX)
    return bounds.union(markerFrame.insetBy(dx: -1, dy: -1))
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    super.draw(at: point, in: context)
    guard let leafStart, let marker = leafStart.marker else { return }
    let lineTop = textLineFragments.first?.typographicBounds.minY ?? leafStart.topLineSpacing
    marker.draw(in: context, textTop: point.y + lineTop, originX: point.x - layoutFragmentFrame.minX)
  }
}

/// 段落簇用的布局管理器代理：带叶头 / 叶尾标记的段落给 `TextRunLayoutFragment`，其余照常。
/// 文字视图原有的代理（iOS：UITextView 自己的，管链接渲染属性）照旧收到它实现的其它回调。
final class TextRunLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
  private(set) weak var original: NSTextLayoutManagerDelegate?
  private let state = TextRunLayoutState()

  init(original: NSTextLayoutManagerDelegate?) {
    self.original = original
  }

  /// 换内容（视图复用时代理留着）：上一份内容记下的字顶作废
  func contentWillChange() {
    state.leafTops.removeAll()
  }

  /// 内容是不是段落簇（末字带结束标记）
  static func isTextRun(_ string: NSAttributedString) -> Bool {
    string.length > 0 && string.attribute(.mpmdTextRunBlockEnd, at: string.length - 1, effectiveRange: nil) != nil
  }

  /// 原代理自己造布局片段时不接管（接管会绕开它）——簇照样显示，只是不做块高取整、不画列表标记
  static func canWrap(_ original: NSTextLayoutManagerDelegate?) -> Bool {
    guard let original else { return true }
    return !original.responds(to: NSSelectorFromString("textLayoutManager:textLayoutFragmentForLocation:inTextElement:"))
  }

  func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                         textLayoutFragmentFor location: any NSTextLocation,
                         in textElement: NSTextElement) -> NSTextLayoutFragment {
    if let paragraph = textElement as? NSTextParagraph {
      let string = paragraph.attributedString
      if string.length > 0 {
        let leafStart = string.attribute(.mpmdTextRunLeafStart, at: 0, effectiveRange: nil) as? TextRunLeafStart
        let blockEnd = string.attribute(.mpmdTextRunBlockEnd, at: string.length - 1, effectiveRange: nil) as? TextRunBlockEnd
        if leafStart != nil || blockEnd != nil {
          let style = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
          return TextRunLayoutFragment(textElement: textElement, range: textElement.elementRange,
                                       leafStart: leafStart, blockEnd: blockEnd,
                                       paragraphSpacing: style?.paragraphSpacing ?? 0, runState: state)
        }
      }
    }
    return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    (original?.responds(to: aSelector) ?? false) ? original : nil
  }
}

extension NSTextLayoutManager {
  /// 按内容装 / 卸段落簇代理（赋内容之前调）。`holder` 是视图持有的代理（layout manager 只弱引用代理）。
  func updateTextRunDelegate(for string: NSAttributedString, holder: inout TextRunLayoutDelegate?) {
    if TextRunLayoutDelegate.isTextRun(string) {
      if let holder, delegate === holder {
        holder.contentWillChange()
        return
      }
      guard TextRunLayoutDelegate.canWrap(delegate) else { return }
      let wrapper = TextRunLayoutDelegate(original: delegate)
      holder = wrapper
      delegate = wrapper
    } else if let current = holder, delegate === current {
      delegate = current.original
      holder = nil
    }
  }
}
