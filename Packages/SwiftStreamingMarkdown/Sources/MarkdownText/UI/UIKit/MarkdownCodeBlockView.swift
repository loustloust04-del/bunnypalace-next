// MP fork（docs/plan-重构.md R3）：代码块的原生视图。摆位照 SwiftUI 版 `CodeBlockView`：
// 头部（语言标签 + 复制 + 展开，左 14 右 10 上下 8，按钮 22×22、间隔 14）→ 1 像素薄荷线 → 四周留 16 的横向滚动代码，
// 外面是 `mintCard`（米白底、圆角 20、内侧 1 像素薄荷描边）。着色走同一条队列，只换颜色不改大小。
#if os(iOS)

import SwiftUI
import UIKit

@MainActor
public final class MarkdownCodeBlockView: UIView {
  private static let headerHeight: CGFloat = 38
  private static let bodyPadding: CGFloat = 16
  private static let measuring = ParagraphUIView(frame: .zero, textContainer: nil)

  /// 同 `CodeBlockView.init`：去掉结尾的换行
  static func trimmed(_ code: String) -> String {
    String(code.reversed().drop(while: { $0 == "\n" || $0 == "\r\n" }).reversed())
  }

  /// 整个代码块在给定宽度下的大小：宽占满，高 = 头 + 线 + 代码（不折行）+ 上下各 16
  static func size(code: String, width: CGFloat, config: MarkdownRenderConfig, scale: CGFloat) -> CGSize {
    let text = textSize(code: trimmed(code), config: config)
    return CGSize(width: width, height: headerHeight + 1 / max(scale, 1) + bodyPadding * 2 + text.height)
  }

  private static func textSize(code: String, config: MarkdownRenderConfig) -> CGSize {
    measuring.setParagraphContents(CodeBlockView.contents(code: code, highlighted: nil, config: config, wraps: false),
                                   lineSpacing: nil, animatedByWord: false)
    let size = measuring.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    return CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
  }

  /// 着色结果按「语言 + 代码」留着：行被回收再用时不用重新着色，也不会先闪一下没着色的
  private static var highlights: [String: HighlightOutput] = [:]

  /// 展开图标（arrow.up.left.and.arrow.down.right，13pt medium）的轮廓。SwiftUI 版把它画成形状图层，
  /// 这是从旧页那一层里读出来的路径（12.33×12.33 的框）；系统没有公开拿符号轮廓的接口
  private static let expandOutline = "M(0.6923190, 5.4096176) C(1.0921959, 5.4096176)(1.3802779, 5.1241001)(1.3802779, 4.7254038) L(1.3802779, 4.2702769) L(1.2475738, 2.2780018) L(2.7326078, 3.8376842) L(4.5562638, 5.6817416) C(4.6900026, 5.8154803)(4.8593199, 5.8824164)(5.0436558, 5.8824164) C(5.4695835, 5.8824164)(5.7745884, 5.5916684)(5.7745884, 5.1657407) C(5.7745884, 4.9729624)(5.7036216, 4.7979575)(5.5668931, 4.6667515) L(3.7301799, 2.8313904) L(2.1661684, 1.3501015) L(4.1762043, 1.4864492) L(4.6605685, 1.4864492) C(5.0568590, 1.4864492)(5.3570396, 1.1971230)(5.3570396, 0.7984903) C(5.3570396, 0.3972550)(5.0592711, 0.1049455)(4.6605685, 0.1049455) L(1.1453321, 0.1049455) C(0.4207346, 0.1049455)(-0.0000007, 0.5256681)(-0.0000007, 1.2491103) L(-0.0000007, 4.7254038) C(-0.0000007, 5.1173715)(0.2924421, 5.4096176)(0.6923190, 5.4096176) Z M(7.5523762, 12.3333951) L(11.0676443, 12.3333951) C(11.7922292, 12.3333951)(12.2117457, 11.9126611)(12.2117457, 11.1892658) L(12.2117457, 7.7129088) C(12.2117457, 7.3209982)(11.9193092, 7.0287395)(11.5194704, 7.0287395) C(11.1251541, 7.0287395)(10.8327176, 7.3142380)(10.8327176, 7.7129088) L(10.8327176, 8.1680928) L(10.9709695, 10.1603299) L(9.4847295, 8.6006792) L(7.6567317, 6.7565964) C(7.5285090, 6.6228640)(7.3536311, 6.5559280)(7.1680892, 6.5559280) C(6.7433675, 6.5559280)(6.4371566, 6.8466824)(6.4371566, 7.2725910) C(6.4371566, 7.4653820)(6.5137094, 7.6403741)(6.6460580, 7.7727735) L(8.4816095, 9.6069349) L(10.0468144, 11.0882238) L(8.0411457, 10.9519142) L(7.5523762, 10.9519142) C(7.1549495, 10.9519142)(6.8614974, 11.2412023)(6.8547054, 11.6398750) C(6.8547054, 12.0410868)(7.1525374, 12.3333951)(7.5523762, 12.3333951) Z"
  private static let expandOutlineSize = CGSize(width: 37.0 / 3, height: 37.0 / 3)

  /// 把「M(x, y) L(x, y) C(x, y)(x, y)(x, y) Z」这样的文字还原成路径
  private static func path(fromOutline outline: String) -> CGPath {
    let path = CGMutablePath()
    let scanner = Scanner(string: outline)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " (),")
    func point() -> CGPoint { CGPoint(x: scanner.scanDouble() ?? 0, y: scanner.scanDouble() ?? 0) }
    while let command = scanner.scanCharacter() {
      switch command {
      case "M": path.move(to: point())
      case "L": path.addLine(to: point())
      case "C":
        let first = point(), second = point()
        path.addCurve(to: point(), control1: first, control2: second)
      case "Z": path.closeSubpath()
      default: break
      }
    }
    return path
  }

  // 三层，同 SwiftUI 版的 mintCard：底色层 → 裁圆角的内容 → 最上面一圈描边（描边不在被裁的那层上，否则圆角处的边会被裁细）
  private let cardFill = CALayer()
  private let content = UIView()
  private let stroke = CALayer()
  private let label = UILabel()
  private let copyButton = UIButton(type: .custom)
  private let copyIcon = CALayer()
  private var copySymbol = "doc.on.doc"
  private let expandButton = UIButton(type: .custom)
  private let expandIcon = CAShapeLayer()
  private let hairline = CALayer()
  private let scroll = UIScrollView()
  private let text = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(contents: NSMutableAttributedString(), lineSpacing: nil)

  private var language = ""
  private var code = ""
  private var config: MarkdownRenderConfig?
  private var copiedGeneration = 0
  /// 每个视图一条自己的着色队列（同 SwiftUI 版）：队列只留最新的一项，而且用的是「开工那一次」的回调，几个视图共用会串
  private let highlighter = HighlightTaskManager()

  public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    for layer in [cardFill, content.layer, stroke] {
      layer.cornerRadius = CodeBlockStyle.cornerRadius
      layer.cornerCurve = .continuous
    }
    cardFill.backgroundColor = UIColor(CodeBlockStyle.body).cgColor
    cardFill.allowsEdgeAntialiasing = true
    layer.addSublayer(cardFill)
    content.backgroundColor = .clear
    content.clipsToBounds = true
    addSubview(content)
    stroke.borderColor = UIColor(CodeBlockStyle.stroke).cgColor
    stroke.allowsEdgeAntialiasing = true
    layer.addSublayer(stroke)

    hairline.backgroundColor = UIColor(CodeBlockStyle.stroke).cgColor
    content.layer.addSublayer(hairline)
    label.backgroundColor = .clear
    label.textColor = UIColor(CodeBlockStyle.label)
    content.addSubview(label)
    copyButton.layer.addSublayer(copyIcon)
    copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
    copyButton.accessibilityLabel = String.codeCopyLabel
    content.addSubview(copyButton)
    expandIcon.fillColor = UIColor(CodeBlockStyle.label).cgColor
    expandIcon.path = Self.path(fromOutline: Self.expandOutline)
    expandIcon.allowsEdgeAntialiasing = true
    expandButton.layer.addSublayer(expandIcon)
    expandButton.addTarget(self, action: #selector(expand), for: .touchUpInside)
    expandButton.accessibilityLabel = "展开代码"
    content.addSubview(expandButton)
    scroll.backgroundColor = .clear
    scroll.showsVerticalScrollIndicator = false
    scroll.addSubview(text)
    content.addSubview(scroll)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("不从 nib 建") }

  private func setCopyIcon(_ name: String) {
    copySymbol = name
    setNeedsLayout()
  }

  /// 复制图标。SwiftUI 版把这个符号画成一张 15×17 的位图，放在 22×22 按钮里的 (3.33, 3)，
  /// 墨迹落在整像素上、离位图左上角 (1, 0)（都是从旧页图层和截图里量出来的）。
  /// 这里用 UIImage 画：位置逐像素对上了，边缘抗锯齿和 SwiftUI 自己画的差最多 14 个色阶（约 200 个像素），
  /// 试过让 SwiftUI 离屏画一张再贴（ImageRenderer），差得更多；对拍里这一小块不比
  private func drawCopyIcon(scale: CGFloat) {
    let symbol = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    guard let image = UIImage(systemName: copySymbol, withConfiguration: symbol)?
      .withTintColor(UIColor(CodeBlockStyle.label), renderingMode: .alwaysOriginal) else { return }
    let size = CGSize(width: 15, height: 17)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    let bitmap = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      // UIImage 四周带留白（左右各 1.67、上下各 1），抵掉以后墨迹在 (1, 0)
      image.draw(at: CGPoint(x: -2.0 / 3, y: -1))
    }
    copyIcon.contents = bitmap.cgImage
    copyIcon.contentsScale = scale
    copyIcon.frame = CGRect(origin: CGPoint(x: (10.0 / 3 * scale).rounded() / scale, y: 3), size: size)
  }

  public func configure(language: String, code: String, config: MarkdownRenderConfig) {
    let code = Self.trimmed(code)
    let changed = code != self.code || language != self.language
    self.language = language
    self.code = code
    self.config = config
    if changed { scroll.contentOffset = .zero }
    refresh()
    guard Self.highlights[key] == nil else { return }
    // 先记一笔「有着色在路上」再排队：排队要隔一拍才真的开始，这一拍里截图测试会以为已经没事了
    MarkdownHighlightProbe.add(1)
    Task { [weak self, highlighter] in
      defer { MarkdownHighlightProbe.add(-1) }
      await highlighter.enqueueCode(code, language: language) { [weak self] output in
        // 回调可能是更早那次排队留下的：以结果里带的代码为准，对不上现在显示的就不要
        guard let self, output.code == self.code else { return }
        if Self.highlights.count > 64 { Self.highlights.removeAll(keepingCapacity: true) }
        Self.highlights[self.key] = output
        self.refresh()
      }
    }
  }

  private var key: String { "\(language)\u{1}\(code)" }

  /// 头部标签：标了语言用标的；没标用自动识别出的；都没有写 text（同 SwiftUI 版）
  private var languageLabel: String {
    let declared = language.trimmingCharacters(in: .whitespaces)
    if !declared.isEmpty { return declared.lowercased() }
    if let detected = Self.highlights[key]?.language, !detected.isEmpty { return detected.lowercased() }
    return "text"
  }

  private func refresh() {
    guard let config else { return }
    label.font = config.inlineStyle.codeTextFont.withSize(12)
    label.text = languageLabel
    text.setParagraphContents(CodeBlockView.contents(code: code, highlighted: Self.highlights[key]?.text, config: config, wraps: false),
                              lineSpacing: nil, animatedByWord: false)
    text.setTextContextMenu(config.textContextMenu)
    setNeedsLayout()
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    guard let config else { return }
    let scale = max(traitCollection.displayScale, 1)
    func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    func ceilToPixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in [cardFill, stroke, expandIcon] { layer.contentsScale = scale }
    cardFill.frame = bounds
    stroke.frame = bounds
    stroke.borderWidth = 1 / scale
    hairline.frame = CGRect(x: 0, y: Self.headerHeight, width: bounds.width, height: 1 / scale)
    // 展开图标在 22×22 按钮里的位置是从旧页读出来的
    expandIcon.frame = CGRect(origin: CGPoint(x: 5, y: 5), size: Self.expandOutlineSize)
    drawCopyIcon(scale: scale)
    CATransaction.commit()
    content.frame = bounds
    let font = config.inlineStyle.codeTextFont.withSize(12)
    let labelSize = CGSize(width: ceilToPixel((languageLabel as NSString).size(withAttributes: [.font: font]).width),
                           height: ceilToPixel(font.lineHeight))
    label.frame = CGRect(x: 14, y: snap(8 + (22 - labelSize.height) / 2), width: labelSize.width, height: labelSize.height)
    expandButton.frame = CGRect(x: bounds.width - 10 - 22, y: 8, width: 22, height: 22)
    copyButton.frame = CGRect(x: expandButton.frame.minX - 14 - 22, y: 8, width: 22, height: 22)
    let textSize = Self.textSize(code: code, config: config)
    scroll.frame = CGRect(x: Self.bodyPadding, y: Self.headerHeight + 1 / scale + Self.bodyPadding,
                          width: bounds.width - Self.bodyPadding * 2, height: textSize.height)
    scroll.contentSize = textSize
    text.frame = CGRect(origin: .zero, size: textSize)
  }

  @objc private func copyCode() {
    PlatformClipboard.copyString(code)
    setCopyIcon("checkmark")
    copyButton.accessibilityLabel = String.codeCopiedLabel
    copiedGeneration += 1
    let generation = copiedGeneration
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard let self, self.copiedGeneration == generation else { return }
      self.setCopyIcon("doc.on.doc")
      self.copyButton.accessibilityLabel = String.codeCopyLabel
    }
  }

  @objc private func expand() {
    guard let config else { return }
    var responder: UIResponder? = self
    while let current = responder, !(current is UIViewController) { responder = current.next }
    guard let presenter = responder as? UIViewController else { return }
    let page = CodeBlockExpandedView(language: languageLabel, code: code, highlighted: Self.highlights[key]?.text,
                                     onCopy: { [weak self] in self?.copyCode() })
      .environment(\.markdownConfig, config)
    presenter.present(UIHostingController(rootView: page), animated: true)
  }
}

#endif
