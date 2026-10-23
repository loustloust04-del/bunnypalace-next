//
//  MP fork mac: ParagraphUIView 的 AppKit 对等物（对 ParagraphView 暴露同一组接口）。
//  NSTextView 子类，TextKit 2 栈：公式走 NSTextAttachmentViewProvider，而 view provider 由
//  NSTextLayoutManager 协调。本类任何地方都不能读 `layoutManager`——一读就会把
//  TextKit 2 静默降级成 TextKit 1（公式附件随之失效）。
//  mac 不做：逐词淡入（animatedByWord 忽略）、a11y custom actions、引文 pill（pill 绘制是 UIKit 专属）。
//

#if os(macOS)

import AppKit
import iosMath
import SwiftUI
import UniformTypeIdentifiers

private struct CachedParagraphNSViewSize {
  let size: CGSize
  let targetWidth: CGFloat
}

class ParagraphNSView: NSTextView {
  private(set) var paragraphContents: NSMutableAttributedString = NSMutableAttributedString()
  private(set) var lineSpacing: CGFloat?
  private var cachedSize: CachedParagraphNSViewSize?

  var textContextMenu: TextContextMenu?
  var markdownController: MarkdownController?
  /// MP fork patch 7: persistent highlight layer state
  private var currentHighlights: [TextHighlight] = []
  /// 所有划线区间（点击命中用），不管是属性底色还是画在字下面的；带它画的那条 quote
  /// （跨段 quote 在这里只画它的一截，单击上报整条）
  private var appliedHighlightRanges: [(range: NSRange, quote: String)] = []
  /// 加了 `.backgroundColor` 属性的区间（老的 `.background` 样式：查找高亮 / 闪词），撤的时候只动这些
  private var attributeHighlightRanges: [NSRange] = []
  /// 画在字下面的笔画（底色 / 下划线 / 彩笔），按画的先后，带下划线层号
  private var drawnStrokes: [(highlight: TextHighlight, range: NSRange, layer: Int)] = []
  /// 内容自带的 `.backgroundColor`（inline code 底色）。撤划线时按它恢复原值，而不是把底色一删了之。
  private var contentBackgroundRuns: [(range: NSRange, color: Any)] = []
  /// MP fork: ||剧透|| 揭开状态
  private var spoilerState = SpoilerRevealState()
  /// MP fork: 剧透粒子（§12）。挂在一个只放层的透明子视图里——不碰 AppKit 管着的 backing layer 的子层
  private lazy var spoilerDustHost: SpoilerDustHostView = {
    let v = SpoilerDustHostView(frame: bounds)
    v.autoresizingMask = [.width, .height]
    addSubview(v)
    return v
  }()
  private var spoilerDust: [URL: SpoilerDustLayer] = [:]
  private var hasHiddenSpoilers = false
  /// 最近一次按下的位置：揭开的圆从这里开
  private var lastClickPoint: CGPoint?
  /// MP fork patch 7.1 (mac): 单击划线要等双击窗口过去才上报，期间来了第二击就作废
  private var pendingHighlightTap: DispatchWorkItem?
  /// 离屏 TextKit 2 测量栈：测量不动在屏视图的容器宽度（SwiftUI 会拿 0 / 1e6 / 实宽反复问）
  private let measuringStack = ParagraphMeasuringStack()

  // To override the behaviour of this property, do so on ParagraphView's SwiftUI wrapper.
  var onUrlTap: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

  /// TextKit 2 网络的持有者（NSTextLayoutManager.textContentManager 是 weak，得有人强引用 content storage）
  private var textKit2ContentStorage: NSTextContentStorage?
  /// MP fork: 内容是段落簇时装在 textLayoutManager 上的代理（layout manager 只弱引用代理，这里持有）
  private var textRunLayout: TextRunLayoutDelegate?

  /// TextKit 2 栈的唯一构造入口。`NSTextView(usingTextLayoutManager:)` 在子类上不继承（Swift 只给 init(coder:)），
  /// 所以手搭 Apple 文档里的那条网络：content storage → layout manager → container → text view。
  static func make() -> ParagraphNSView {
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    contentStorage.primaryTextLayoutManager = layoutManager
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    layoutManager.textContainer = container
    let view = ParagraphNSView(frame: .zero, textContainer: container)
    view.textKit2ContentStorage = contentStorage
    return view
  }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    delegate = self
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    delegate = self
    setupView()
  }

  deinit {
    pendingHighlightTap?.cancel()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    // iOS 对等（ParagraphUIView.willMove(toWindow:)）：离开窗口（LazyVStack 滚出 / 缓存池回收）时清选区，
    // 并作废还没到点的划线单击。
    if newWindow == nil {
      cancelPendingHighlightTap()
      setSelectedRange(NSRange(location: 0, length: 0))
    }
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      // 焦点走了（点了输入框 / 另一段 / 键盘去了别处）：双击窗口内待发的划线单击作废
      cancelPendingHighlightTap()
      setSelectedRange(NSRange(location: selectedRange().location, length: 0))
    }
    return result
  }

  override var intrinsicContentSize: NSSize {
    var targetWidth = bounds.width
    if targetWidth <= 0 || targetWidth.isInfinite {
      // When bounds.width is not valid, we have to give a best guess (iOS 同款兜底，mac 用 NSScreen.main).
      targetWidth = NSScreen.main?.frame.width ?? 1_000
    }
    if let cachedSize, cachedSize.targetWidth == targetWidth {
      return cachedSize.size
    }
    let targetSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
    let contentSize = sizeThatFits(targetSize)
    let roundedUpSize = CGSize(width: contentSize.width.rounded(.up), height: contentSize.height.rounded(.up))
    cachedSize = CachedParagraphNSViewSize(size: roundedUpSize, targetWidth: targetWidth)
    return roundedUpSize
  }

  /// 按给定宽度测量内容尺寸（iOS 的 `UITextView.sizeThatFits` 对等物）：宽 = 实际最宽一行（≤ 给定宽），
  /// 高 = 全部布局片段的底。走离屏 TextKit 2 栈，与在屏视图同属性、同宽度、同 lineFragmentPadding 0。
  func sizeThatFits(_ size: CGSize) -> CGSize {
    guard let textStorage else { return .zero }
    return measuringStack.size(of: textStorage, width: size.width)
  }

  func setParagraphContents(_ newContents: NSMutableAttributedString, lineSpacing: CGFloat? = nil, animatedByWord: Bool) {
    // mac 不做逐词淡入（iOS 靠 CADisplayLink 逐帧改字色 alpha，没有移植）：animatedByWord 忽略。
    // iOS 这里还会刷新引文 pill 的界面风格缓存——mac 不画 pill。
    guard paragraphContents != newContents || self.lineSpacing != lineSpacing else {
      return
    }
    // 内容换了：待发单击捕获的 quote / 区间已过期
    cancelPendingHighlightTap()
    self.paragraphContents = newContents
    self.lineSpacing = lineSpacing

    let finalString: NSMutableAttributedString
    if lineSpacing != nil {
      finalString = applyLineSpacing(to: newContents, lineSpacing: lineSpacing)
    } else {
      finalString = newContents
    }

    guard let textStorage, !finalString.isEqual(to: textStorage) else {
      return
    }

    invalidateCachedSize()
    // MP fork: 段落簇要自己的布局片段（块高取整 + 块距），在屏视图和离屏测量栈都要，赋内容前装好
    textLayoutManager?.updateTextRunDelegate(for: finalString, holder: &textRunLayout)
    measuringStack.updateTextRunDelegate(for: finalString)
    textStorage.setAttributedString(finalString)
    spoilerState.contentDidChange(to: finalString.string)
    spoilerState.reapply(in: textStorage)
    contentBackgroundRuns = Self.backgroundRuns(in: textStorage)
    measuringStack.invalidate()
    refreshSpoilerDust()

    // MP fork patch 7: content replaced — old ranges void, repaint highlight layer
    appliedHighlightRanges = []
    attributeHighlightRanges = []
    reapplyHighlights()

    invalidateIntrinsicContentSize()
  }

  private func applyLineSpacing(to attributedString: NSMutableAttributedString, lineSpacing: CGFloat?) -> NSMutableAttributedString {
    let result = NSMutableAttributedString(attributedString: attributedString)
    if let lineSpacing {
      result.setLineSpacing(lineSpacing)
    }
    return result
  }

  private func setupView() {
    // Only register if not already registered to prevent conflicts
    if NSTextAttachment.textAttachmentViewProviderClass(forFileType: UTType.data.identifier) == nil {
      NSTextAttachment.registerViewProviderClass(LatexViewProvider.self, forFileType: UTType.data.identifier)
    }
    // 引文 pill（UTType.url）的 view provider 留 iOS 门；MP citationConfig.isEnabled = false。

    isEditable = false
    isSelectable = true
    isRichText = true
    allowsUndo = false
    alignment = .left
    drawsBackground = false
    backgroundColor = .clear
    writingToolsBehavior = .none

    // SwiftUI 宿主定 frame；文本视图自己不改尺寸
    isVerticallyResizable = false
    isHorizontallyResizable = false
    autoresizingMask = []

    setContentHuggingPriority(.defaultHigh, for: .vertical)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    textContainerInset = .zero
    if let textContainer {
      textContainer.lineFragmentPadding = 0
      textContainer.widthTracksTextView = true
      // iOS 的 heightTracksTextView = true 是 UITextView 非滚动语义；NSTextView 高度由 SwiftUI 给，容器高不设限
      textContainer.heightTracksTextView = false
      textContainer.size = NSSize(width: textContainer.size.width, height: CGFloat.greatestFiniteMagnitude)
      textContainer.maximumNumberOfLines = 0
      textContainer.lineBreakMode = .byWordWrapping
    }

    // iOS 同款：清空 linkTextAttributes，链接的字色 / 字体听内容属性的；mac 只保留手形光标
    linkTextAttributes = [.cursor: NSCursor.pointingHand]
  }

  private func invalidateCachedSize() {
    cachedSize = nil
  }

  func setTextContextMenu(_ menu: TextContextMenu?) {
    textContextMenu = menu
  }

  func setMarkdownController(_ controller: MarkdownController?) {
    // updateNSView 每次都会调；只有真换了 controller（上报对象变了）才作废待发单击
    if controller !== markdownController {
      cancelPendingHighlightTap()
    }
    markdownController = controller
  }

  // MARK: - Context menu（iOS editMenuForTextIn + willPresentEditMenuWith 的对等物）

  /// 系统右键菜单原样保留，自定义项插在**顶部**（先例 MP `SelectableActionTextView.swift:85-96`）；
  /// 无选区时不插（iOS 编辑浮条同样只在有选区时出现）。插完同步广播 `onContextMenuAppear`。
  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    guard let textContextMenu, let textStorage else { return menu }
    let range = NSIntersectionRange(selectedRange(), NSRange(location: 0, length: textStorage.length))
    guard range.length > 0 else { return menu }

    let customMenu = textContextMenu.buildNSMenu(textView: self, selectedRange: range, markdownController: markdownController)
    let customItems = customMenu.items
    customMenu.removeAllItems()
    for (index, item) in customItems.enumerated() {
      menu.insertItem(item, at: index)
    }

    if let markdownController {
      let selectedText = textStorage.attributedSubstring(from: range).string
      for group in textContextMenu.menuGroups {
        for item in group.items {
          markdownController.onContextMenuAppear(id: item.id, selectedContent: selectedText)
        }
      }
    }
    return menu
  }

  // MARK: - MP fork patch 7: persistent highlights (chat transcript annotations)

  /// Repaint highlight layer. Independent of the content pipeline: tracks its
  /// own applied ranges, and when a highlight goes away the content's own
  /// `.backgroundColor` (inline code chips) is restored under it rather than
  /// stripped. Content replacement must reset `appliedHighlightRanges` before
  /// repainting (old ranges are void against new storage).
  func setTextHighlights(_ highlights: [TextHighlight]) {
    guard highlights != currentHighlights else { return }
    // 划线变了（取消 / 换色 / 新增）：待发单击指向的那条可能已不存在
    cancelPendingHighlightTap()
    currentHighlights = highlights
    reapplyHighlights()
  }

  func reapplyHighlights() {
    guard let textStorage else { return }
    for r in attributeHighlightRanges where NSMaxRange(r) <= textStorage.length {
      restoreContentBackground(in: r, of: textStorage)
    }
    let hadStrokes = !drawnStrokes.isEmpty
    appliedHighlightRanges = []
    attributeHighlightRanges = []
    var drawn: [(TextHighlight, NSRange)] = []
    let plain = textStorage.string as NSString
    for h in currentHighlights {
      for found in TextHighlightMatcher.ranges(of: h.quote, in: plain) {
        if h.style == .background {
          textStorage.addAttribute(.backgroundColor, value: h.color, range: found)
          attributeHighlightRanges.append(found)
        } else {
          drawn.append((h, found))
        }
        appliedHighlightRanges.append((found, h.quote))
      }
    }
    let steps = TextHighlightGeometry.underlineLayers(drawn.filter { $0.0.style == .underline }.map(\.1))
    var k = 0
    drawnStrokes = drawn.map { h, r in
      guard h.style == .underline else { return (h, r, 0) }
      defer { k += 1 }
      return (h, r, steps[k])
    }
    if hadStrokes || !drawnStrokes.isEmpty { needsDisplay = true }
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    // 宽度变了行会重排、公式附件会撑高：画在字下面的笔画跟着重画
    if changed, !drawnStrokes.isEmpty { needsDisplay = true }
    if changed, hasHiddenSpoilers { refreshSpoilerDust() }
  }

  /// 划线画在字下面：先画笔画再让 NSTextView 画字（drawsBackground = false，本身不铺底）
  override func draw(_ dirtyRect: NSRect) {
    if !drawnStrokes.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
      ctx.saveGState()
      for stroke in drawnStrokes {
        let pieces = TextHighlightGeometry.pieces(
          style: stroke.highlight.style, color: stroke.highlight.color.cgColor,
          strokeId: stroke.highlight.strokeId, layer: stroke.layer, rects: segmentFrames(for: stroke.range))
        for piece in pieces {
          ctx.addPath(piece.path)
          ctx.setFillColor(piece.color)
          ctx.fillPath()
        }
      }
      ctx.restoreGState()
    }
    super.draw(dirtyRect)
  }

  /// 区间在每一行的框（TextKit 2；本类不能碰 `layoutManager`）
  private func segmentFrames(for range: NSRange) -> [CGRect] {
    guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
          let start = tcm.location(tcm.documentRange.location, offsetBy: range.location),
          let end = tcm.location(start, offsetBy: range.length),
          let textRange = NSTextRange(location: start, end: end) else { return [] }
    tlm.ensureLayout(for: textRange)
    var frames: [CGRect] = []
    tlm.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
      if frame.width > 0.5 { frames.append(frame) }
      return true
    }
    let origin = textContainerOrigin
    return frames.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
  }

  /// 把 `range` 的 `.backgroundColor` 恢复成内容本来的样子：原来有（inline code 底色）就放回原值，原来没有才删。
  private func restoreContentBackground(in range: NSRange, of storage: NSTextStorage) {
    storage.removeAttribute(.backgroundColor, range: range)
    for run in contentBackgroundRuns {
      let overlap = NSIntersectionRange(run.range, range)
      if overlap.length > 0 {
        storage.addAttribute(.backgroundColor, value: run.color, range: overlap)
      }
    }
  }

  private static func backgroundRuns(in string: NSAttributedString) -> [(range: NSRange, color: Any)] {
    var runs: [(range: NSRange, color: Any)] = []
    string.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: string.length)) { value, range, _ in
      if let value {
        runs.append((range, value))
      }
    }
    return runs
  }

  // MARK: - MP fork patch 7.1 (mac): single click on a highlighted run → `highlight.tap`

  /// 行为约束：
  /// - 双击选词 / 三击选段 / 拖选 / Shift 等修饰键扩选全部优先：只有「无修饰键的第一击、松开时没有选区」
  ///   才成为候选，而且要等 `NSEvent.doubleClickInterval` 过去、期间没有第二击才上报；
  /// - 只有点在**真实字形框**里才算命中（插入点索引不算——行尾空白、换行后的空处不开）；
  /// - 点在链接上只走链接（NSTextView 自己在 super.mouseDown 里派发 clickedOnLink）；
  /// - 待发单击在 下次按下 / 失焦 / 内容替换 / controller 更换 / 划线变化 / 离窗 时作废，到点执行时再复核一遍。
  override func mouseDown(with event: NSEvent) {
    cancelPendingHighlightTap()

    let downPoint = convert(event.locationInWindow, from: nil)
    lastClickPoint = downPoint
    let isPlainFirstClick = event.clickCount == 1
      && event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty

    // NSTextView 的 mouseDown 自带跟踪循环：选区 / 拖选 / 链接都在这里处理完，返回时鼠标已松开
    super.mouseDown(with: event)

    guard isPlainFirstClick, !appliedHighlightRanges.isEmpty else { return }
    // 拖选的判据就是「松开时有选区」：拖过任何字形都会留下非空选区
    guard selectedRange().length == 0 else { return }
    guard let hit = highlightHit(atViewPoint: downPoint), let textStorage else { return }

    let range = hit.range, quote = hit.quote
    let piece = (textStorage.string as NSString).substring(with: range)
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingHighlightTap = nil
      // 到点复核（失效点都已取消，这里兜底）：选区仍空、那条划线仍涂在原处、原处还是那段字
      guard self.selectedRange().length == 0,
            self.appliedHighlightRanges.contains(where: { $0.range == range && $0.quote == quote }),
            let storage = self.textStorage,
            NSMaxRange(range) <= storage.length,
            (storage.string as NSString).substring(with: range) == piece else { return }
      self.markdownController?.onContextMenuTap(id: "highlight.tap", selectedContent: quote)
    }
    pendingHighlightTap = work
    DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
  }

  /// 作废还没到点的划线单击（双击窗口内挂着的那一个）。
  private func cancelPendingHighlightTap() {
    pendingHighlightTap?.cancel()
    pendingHighlightTap = nil
  }

  /// 点 → 命中的划线区间和它所属的整条 quote。只用 TextKit 2 接口（textSelectionNavigation / enumerateTextSegments），
  /// 不碰 layoutManager。先取离点最近的插入点，再核插入点左右两个合成字符（emoji 不拆）的字形框是否真含这个点。
  func highlightHit(atViewPoint viewPoint: NSPoint) -> (range: NSRange, quote: String)? {
    guard !appliedHighlightRanges.isEmpty,
          let textStorage,
          let layoutManager = textLayoutManager,
          let contentStorage = textContentStorage else { return nil }
    let origin = textContainerOrigin
    let point = CGPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
    let documentStart = layoutManager.documentRange.location
    let selections = layoutManager.textSelectionNavigation.textSelections(
      interactingAt: point,
      inContainerAt: documentStart,
      anchors: [],
      modifiers: [],
      selecting: false,
      bounds: .zero
    )
    guard let insertion = selections.first?.textRanges.first?.location else { return nil }
    let insertionIndex = contentStorage.offset(from: documentStart, to: insertion)
    let plain = textStorage.string as NSString

    for candidate in [insertionIndex - 1, insertionIndex] where candidate >= 0 && candidate < plain.length {
      let characterRange = plain.rangeOfComposedCharacterSequence(at: candidate)
      guard let frame = glyphFrame(of: characterRange, layoutManager: layoutManager, contentStorage: contentStorage),
            frame.contains(point) else { continue }
      if textStorage.attribute(.link, at: characterRange.location, effectiveRange: nil) != nil { return nil }
      return appliedHighlightRanges.first { NSLocationInRange(characterRange.location, $0.range) }
    }
    return nil
  }

  /// MP fork: 某个字符的字形框（视图坐标），缩写气泡的锚点。
  fileprivate func firstRect(forCharacterAt index: Int) -> NSRect? {
    guard let layoutManager = textLayoutManager, let contentStorage = textContentStorage,
          let textStorage, index < textStorage.length else { return nil }
    let range = (textStorage.string as NSString).rangeOfComposedCharacterSequence(at: index)
    guard let frame = glyphFrame(of: range, layoutManager: layoutManager, contentStorage: contentStorage) else { return nil }
    return frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
  }

  private func glyphFrame(of range: NSRange, layoutManager: NSTextLayoutManager, contentStorage: NSTextContentStorage) -> CGRect? {
    let documentStart = layoutManager.documentRange.location
    guard let start = contentStorage.location(documentStart, offsetBy: range.location),
          let end = contentStorage.location(start, offsetBy: range.length),
          let textRange = NSTextRange(location: start, end: end) else { return nil }
    var result: CGRect?
    layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
      result = result.map { $0.union(frame) } ?? frame
      return true
    }
    return result
  }
}

// MARK: - MP fork: 剧透粒子（§12，与 iOS 同一层 SpoilerDustLayer）
extension ParagraphNSView {
  fileprivate func refreshSpoilerDust() {
    guard let textStorage else { return }
    let hidden = SpoilerRevealState.hiddenSpoilers(in: textStorage)
    hasHiddenSpoilers = !hidden.isEmpty
    guard hasHiddenSpoilers || !spoilerDust.isEmpty else { return }
    let host = spoilerDustHost
    host.frame = bounds
    var alive: Set<URL> = []
    if bounds.width > 0 {
      for spoiler in hidden {
        let rects = segmentFrames(for: spoiler.range).map { $0.insetBy(dx: 0, dy: 1) }
        guard !rects.isEmpty else { continue }
        alive.insert(spoiler.url)
        let dust: SpoilerDustLayer
        if let existing = spoilerDust[spoiler.url] {
          dust = existing
        } else {
          dust = SpoilerDustLayer(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
          dust.contentsScale = window?.backingScaleFactor ?? 2
          host.dustRoot.addSublayer(dust)
          spoilerDust[spoiler.url] = dust
        }
        dust.frame = host.dustRoot.bounds
        var color = spoiler.color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = spoiler.color.cgColor }
        dust.update(rects: rects, color: color)
      }
    }
    for (url, dust) in spoilerDust where !alive.contains(url) && !dust.isRevealing {
      dust.removeFromSuperlayer()
      spoilerDust[url] = nil
    }
  }

  fileprivate func revealSpoiler(_ url: URL) {
    guard let textStorage else { return }
    guard let dust = spoilerDust[url], !dust.isRevealing else {
      if spoilerState.reveal(url, in: textStorage) != nil {
        contentBackgroundRuns = Self.backgroundRuns(in: textStorage)
        needsDisplay = true
      }
      refreshSpoilerDust()
      return
    }
    let union = dust.rects.reduce(CGRect.null) { $0.union($1) }
    let point = lastClickPoint.flatMap { p in dust.rects.contains { $0.insetBy(dx: -12, dy: -12).contains(p) } ? p : nil }
      ?? CGPoint(x: union.midX, y: union.midY)
    // 字的遮罩挂在本视图的 backing layer 上（只用 mask，不加子层）；没有 layer 就直接显示
    wantsLayer = true
    var mask: SpoilerTextRevealMask?
    if let layer {
      let m = SpoilerTextRevealMask(bounds: bounds, spoilerRects: dust.rects)
      m.isGeometryFlipped = !layer.isGeometryFlipped && isFlipped
      layer.mask = m
      mask = m
    }
    if spoilerState.reveal(url, in: textStorage) != nil {
      contentBackgroundRuns = Self.backgroundRuns(in: textStorage)
      needsDisplay = true
    }
    dust.reveal(at: point, textMask: mask) { [weak self, weak dust] in
      dust?.removeFromSuperlayer()
      guard let self else { return }
      if self.spoilerDust[url] === dust { self.spoilerDust[url] = nil }
      if let mask, self.layer?.mask === mask { self.layer?.mask = nil }
      self.hasHiddenSpoilers = !self.spoilerDust.isEmpty
    }
  }
}

/// 只放剧透粒子层的透明子视图（layer-hosting，坐标与文字视图一致：左上原点），不接鼠标
final class SpoilerDustHostView: NSView {
  let dustRoot = CALayer()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    dustRoot.isGeometryFlipped = true
    dustRoot.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
    layer = dustRoot
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - NSTextViewDelegate
extension ParagraphNSView: NSTextViewDelegate {
  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
    guard let url else { return false }
    // MP fork: 剧透 / 缩写是内部链接
    if url.scheme == InlineExtensionURL.spoilerScheme {
      revealSpoiler(url)
      return true
    }
    if url.scheme == InlineExtensionURL.abbreviationScheme {
      if let title = InlineExtensionURL.abbreviationTitle(from: url),
         let rect = firstRect(forCharacterAt: charIndex) {
        AbbreviationPopover.show(title: title, relativeTo: rect, of: self)
      }
      return true
    }
    self.onUrlTap(url)
    return true
  }
}

fileprivate extension NSMutableAttributedString {
  func setLineSpacing(_ lineSpacing: CGFloat) {
    let paragraphStyle = NSMutableParagraphStyle()
    // MP fork: 注音段落的最小行高（给 ruby 留位置）不能被行距覆盖掉
    if length > 0, let existing = attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
      paragraphStyle.minimumLineHeight = existing.minimumLineHeight
    }
    paragraphStyle.lineSpacing = lineSpacing
    paragraphStyle.alignment = .left
    addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: length))
  }
}

/// 离屏 TextKit 2 测量栈（每个 ParagraphNSView 一份）：内容变了才重灌字符串，宽度变了才重排。
private final class ParagraphMeasuringStack {
  private let contentStorage = NSTextContentStorage()
  private let layoutManager = NSTextLayoutManager()
  private let container = NSTextContainer(size: .zero)
  private var isLoaded = false
  private var textRunLayout: TextRunLayoutDelegate?

  init() {
    container.lineFragmentPadding = 0
    container.maximumNumberOfLines = 0
    container.lineBreakMode = .byWordWrapping
    layoutManager.textContainer = container
    contentStorage.addTextLayoutManager(layoutManager)
    contentStorage.primaryTextLayoutManager = layoutManager
  }

  func invalidate() {
    isLoaded = false
  }

  func updateTextRunDelegate(for string: NSAttributedString) {
    layoutManager.updateTextRunDelegate(for: string, holder: &textRunLayout)
  }

  func size(of attributedString: NSAttributedString, width: CGFloat) -> CGSize {
    if !isLoaded {
      contentStorage.textStorage?.setAttributedString(attributedString)
      isLoaded = true
    }
    if container.size.width != width {
      container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
    layoutManager.ensureLayout(for: layoutManager.documentRange)
    var maxLineX: CGFloat = 0
    var maxY: CGFloat = 0
    layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresLayout]) { fragment in
      let frame = fragment.layoutFragmentFrame
      for line in fragment.textLineFragments {
        maxLineX = max(maxLineX, frame.minX + line.typographicBounds.maxX)
      }
      maxY = max(maxY, frame.maxY)
      return true
    }
    return CGSize(width: min(maxLineX.rounded(.up), width), height: maxY)
  }
}

/// mac：MTMathUILabel 在 layout 时把 textColor 解析成 CGColor（iosMath `MTMathListDisplay.m:132`），
/// 外观切换后不会自己重排 → 深浅色切换公式颜色不变。这里外观变了就标脏重排，并在本视图外观下 layout。
final class AppearanceAwareMathLabel: MTMathUILabel {
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else {
      super.draw(dirtyRect)
      return
    }
    context.saveGState()
    context.setShouldSmoothFonts(false)
    super.draw(dirtyRect)
    context.restoreGState()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsLayout = true
    needsDisplay = true
  }

  override func layout() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      super.layout()
    }
  }
}

/// mac：AppKit 的 NSTextAttachmentLayout 默认实现给 `public.data` 类型附件返回一张 32×32 文件图标
/// （`image(for:attributes:location:textContainer:)`），TextKit 2 布局片段会把它画进附件框——
/// 正好垫在 LatexViewProvider 的公式视图（透明底）下面。公式只由 view provider 画，附件本身不画图。
final class LatexTextAttachment: NSTextAttachment {
  override func image(for bounds: CGRect,
                      attributes: [NSAttributedString.Key: Any],
                      location: any NSTextLocation,
                      textContainer: NSTextContainer?) -> NSImage? {
    nil
  }
}

final class LatexViewProvider: NSTextAttachmentViewProvider {
  private let latex: String
  private let fontSize: CGFloat
  private let textColor: NSColor
  private var fittedSize: CGSize?
  private static let jsonDecoder = JSONDecoder()

  required override init(textAttachment attachment: NSTextAttachment,
                         parentView: NSView?,
                         textLayoutManager: NSTextLayoutManager?,
                         location: any NSTextLocation) {

    var tempLatex = ""
    var tempFontSize = Typography.base.uiFont.pointSize
    var tempTextColor: NSColor = NSColor(Color.Theme.Foreground.Primary.Primary750)
    if let data = attachment.contents {
      if let attachmentData = try? Self.jsonDecoder.decode(LatexAttachmentData.self, from: data) {
        tempLatex = attachmentData.latex
        tempFontSize = attachmentData.fontSize
        tempTextColor = attachmentData.resolvedTextColor
      }
    }
    latex = tempLatex
    fontSize = tempFontSize
    textColor = tempTextColor

    super.init(textAttachment: attachment,
               parentView: parentView,
               textLayoutManager: textLayoutManager,
               location: location)

    tracksTextAttachmentViewBounds = true
  }

  override func loadView() {
    fittedSize = nil
    let label = AppearanceAwareMathLabel()
    label.latex = latex
    label.textColor = textColor
    label.displayErrorInline = false
    label.fontSize = fontSize
    label.setContentHuggingPriority(.defaultHigh, for: .vertical)
    self.view = label
  }

  override func attachmentBounds(for attributes: [NSAttributedString.Key: Any],
                                 location: any NSTextLocation,
                                 textContainer: NSTextContainer?,
                                 proposedLineFragment: CGRect,
                                 position: CGPoint) -> CGRect {
    guard let mathLabel = view as? MTMathUILabel else {
      return .zero
    }
    // iOS 用 sizeToFit()；NSView 没有它，MTMathUILabel 在 mac 的 intrinsicContentSize = sizeThatFits:CGSizeZero
    // （iosMath MTMathUILabel.m:236-239）
    // 公式和字号在 provider 内不可变；TextKit 的重复提案不需要反复运行数学排版器。
    let fitted = fittedSize ?? mathLabel.intrinsicContentSize
    fittedSize = fitted
    mathLabel.setFrameSize(NSSize(width: fitted.width.rounded(.up), height: fitted.height.rounded(.up)))
    // It's a known issue that MTMathUILabel may be cut off for some short statement. Manually add 1 to the height fix it.
    let height = fitted.height.rounded(.up) + 1.0
    let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: fontSize)
    let yOffset = (font.xHeight - height) / 2.0
    return CGRect(x: 0, y: yOffset, width: fitted.width.rounded(.up), height: height)
  }
}

#endif  // os(macOS)
