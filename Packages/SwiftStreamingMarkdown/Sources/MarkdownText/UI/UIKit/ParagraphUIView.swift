//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

// MP fork mac-port L1: 整文件 iOS 专属留门（UITextView 全家桶）；mac 对等物由 L2 新建。
#if os(iOS)

import iosMath
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AccessibilityContent {
  let label: String?
  let actions: [UIAccessibilityCustomAction]
}

struct FadeAnimationData {
  let id: UUID = UUID()
  let startTime: CFTimeInterval
  let duration: CFTimeInterval
  let range: NSRange
}

private struct CachedParagraphUIViewSize {
  let size: CGSize
  let targetWidth: CGFloat
}

class ParagraphUIView: UITextView {
  private static let jsonEncoder = JSONEncoder()
  static let animationDuration: CFTimeInterval = 0.5 // Animation duration for each word

  private(set) var paragraphContents: NSMutableAttributedString = NSMutableAttributedString()
  private(set) var lineSpacing: CGFloat?
  private var activeAnimations: [FadeAnimationData] = []
  private var fadeAnimationDisplayLink: CADisplayLink?
  private var cachedSize: CachedParagraphUIViewSize?

  var textContextMenu: TextContextMenu?
  var markdownController: MarkdownController?
  /// MP fork patch 7: persistent highlight layer state
  private var currentHighlights: [TextHighlight] = []
  /// Every painted highlight range (tap hit-testing), attribute-painted or layer-drawn, with the quote it
  /// paints (a cross-paragraph quote paints only its piece here; a tap reports the whole quote).
  private var appliedHighlightRanges: [(range: NSRange, quote: String)] = []
  /// Ranges that got a `.backgroundColor` attribute (legacy `.background` style) — the only ones to strip.
  private var attributeHighlightRanges: [NSRange] = []
  /// Layer-drawn strokes (fill / underline / pen), in paint order, with their underline step.
  private var drawnStrokes: [(highlight: TextHighlight, range: NSRange, layer: Int)] = []
  /// Sits under the text (index 0 of the view's layer); redrawn when strokes or line layout change.
  private lazy var strokeLayer: CALayer = {
    let l = CALayer()
    l.actions = ["sublayers": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    layer.insertSublayer(l, at: 0)
    return l
  }()
  private var strokeLayoutSize: CGSize = .zero
  /// MP fork patch 7.1: tap-to-manage highlights
  private var highlightTapGesture: UITapGestureRecognizer?
  /// MP fork: ||剧透|| 揭开状态 / 缩写释义菜单
  private var spoilerState = SpoilerRevealState()
  private let abbreviationPresenter = AbbreviationMenuPresenter()
  /// MP fork: 剧透粒子（每个还藏着的剧透一层，research-chat-cards §12）
  private var spoilerDust: [URL: SpoilerDustLayer] = [:]
  private var spoilerDustSize: CGSize = .zero
  private var hasHiddenSpoilers = false
  /// 最近一次按下的位置：揭开的圆从这里开
  private var lastTouchPoint: CGPoint?
  /// perf L1 ①：刚从池里出来——下一次 setParagraphContents 不认「内容没变」的短路，整条流程重走（剧透 / 无障碍 / 划线状态已清）
  private var needsContentRefresh = false
  /// MP fork: 内容是段落簇时装在 textLayoutManager 上的代理（layout manager 只弱引用代理，这里持有）
  private var textRunLayout: TextRunLayoutDelegate?
  #if (DEBUG || PERF_BENCH) && os(iOS)
  /// perf M4：当前内容是否已排过（换内容清零）/ 上次 layoutSubviews 时的 bounds 宽（区分 0→真值那一遍）
  private var perfLaidOut = false
  /// R12-06：上次 layoutSubviews 观测到的 bounds 宽（-1 = 还没观测过）/ 上一遍排版的目标宽 / 正在走 intrinsicContentSize 的猜宽路径
  private var perfBoundsWidth: CGFloat = -1
  private var perfLastWidth: CGFloat = -1
  private var perfGuessing = false
  /// perf L1a：本次 setParagraphContents 里 attributedText 赋值的时长（秒）
  private var perfAttrSec: CFTimeInterval = 0
  #endif

  // To override the behaviour of this property, do so on ParagraphView's SwiftUI wrapper.
  var onUrlTap: (URL) -> Void = { UIApplication.shared.open($0) }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    #if (DEBUG || PERF_BENCH) && os(iOS)
    MarkdownPerfProbe.call?(.paragraphInit)
    #endif
    super.init(frame: frame, textContainer: textContainer)
    delegate = self
    setupView()
  }

  required init?(coder: NSCoder) {
    #if (DEBUG || PERF_BENCH) && os(iOS)
    MarkdownPerfProbe.call?(.paragraphInit)
    #endif
    super.init(coder: coder)
    delegate = self
    setupView()
  }

  deinit {
    #if (DEBUG || PERF_BENCH) && os(iOS)
    if MarkdownPerfProbe.span != nil { let perfT0 = CACurrentMediaTime(); MarkdownPerfProbe.span?(.deinitView, perfT0, perfT0) }
    #endif
    tearDownDisplayLink()
    activeAnimations.removeAll()
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    // Fix for crash: "UIPreviewTarget requires that the container view is in a window". When the view is removed from the window (e.g. scrolled out in LazyVStack), we should clear the selection to prevent any pending menu or drag interactions from trying to reference the detached view.
    if newWindow == nil {
      selectedTextRange = nil
      #if (DEBUG || PERF_BENCH) && os(iOS)
      if MarkdownPerfProbe.span != nil { let perfT0 = CACurrentMediaTime(); MarkdownPerfProbe.span?(.leaveWindow, perfT0, perfT0) }
      #endif
    }
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      selectedTextRange = nil
    }
    return result
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
      InlineCitationAttachment.updateInterfaceStyle(traitCollection.userInterfaceStyle)
    }
  }

  override var intrinsicContentSize: CGSize {
    if let cachedSize {
      return cachedSize.size
    }
    var targetWidth = bounds.width
    if targetWidth <= 0 || targetWidth.isInfinite {
      // When bounds.width is not valid, we have to give a best guess, otherwise Chat becomes blank in some cases sometimes. It may be related to LazyVStack.
      targetWidth = UIScreen.main.bounds.width
      #if (DEBUG || PERF_BENCH) && os(iOS)
      perfGuessing = MarkdownPerfProbe.layout != nil   // perf R12-06：这一遍按屏宽猜着排
      #endif
    }
    let targetSize = CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
    let contentSize = sizeThatFits(targetSize)
    #if (DEBUG || PERF_BENCH) && os(iOS)
    perfGuessing = false
    #endif
    let roundedUpSize = CGSize(width: contentSize.width.rounded(.up), height: contentSize.height.rounded(.up))
    cachedSize = CachedParagraphUIViewSize(size: roundedUpSize, targetWidth: targetWidth)
    return roundedUpSize
  }

  override func layoutSubviews() {
    #if (DEBUG || PERF_BENCH) && os(iOS)
    // perf M4：测量台挂了回调才计时（最外层）；nil = 原行为
    let perfT0: CFTimeInterval? = MarkdownPerfProbe.layout != nil && MarkdownPerfProbe.depth == 0 ? CACurrentMediaTime() : nil
    if perfT0 != nil { MarkdownPerfProbe.depth += 1 }
    defer { if let perfT0 { MarkdownPerfProbe.depth -= 1; perfNoteLayout(isLayout: true, width: bounds.width, since: perfT0) } }
    #endif
    super.layoutSubviews()
    if bounds.width != cachedSize?.targetWidth {
      invalidateCachedSize()
    }
    invalidateIntrinsicContentSize()
    // Lines reflow with width, attachments (formulas) resize with height: layer-drawn strokes follow
    if !drawnStrokes.isEmpty, bounds.size != strokeLayoutSize {
      redrawStrokeLayer()
    }
    if hasHiddenSpoilers, bounds.size != spoilerDustSize {
      refreshSpoilerDust()
    }
  }

  #if (DEBUG || PERF_BENCH) && os(iOS)
  // perf M4：sizeThatFits 只在测量构建里覆写；回调为 nil 直接走 super
  override func sizeThatFits(_ size: CGSize) -> CGSize {
    guard MarkdownPerfProbe.layout != nil, MarkdownPerfProbe.depth == 0 else { return super.sizeThatFits(size) }
    MarkdownPerfProbe.depth += 1
    let t0 = CACurrentMediaTime()
    let result = super.sizeThatFits(size)
    MarkdownPerfProbe.depth -= 1
    perfNoteLayout(isLayout: false, width: size.width, since: t0)
    return result
  }

  /// R12-06 分类：换内容后首遍（firstGuess = 首遍走的是屏宽猜宽）/ 之后的猜宽遍 / bounds 宽确实从 0 变真值的 layoutSubviews /
  /// 目标宽变了的重排 / 其它（同宽重排）
  private func perfNoteLayout(isLayout: Bool, width: CGFloat, since t0: CFTimeInterval) {
    let guessed = !isLayout && perfGuessing
    let pass: MarkdownPerfProbe.Pass
    if !perfLaidOut {
      pass = guessed ? .firstGuess : .first
    } else if guessed {
      pass = .guess
    } else if isLayout && perfBoundsWidth == 0 && bounds.width > 0 {
      pass = .zeroToReal
    } else if perfLastWidth >= 0 && abs(width - perfLastWidth) > 0.5 {
      pass = .widthChanged
    } else {
      pass = .other
    }
    perfLaidOut = true
    if isLayout { perfBoundsWidth = bounds.width }
    perfLastWidth = width
    MarkdownPerfProbe.layout?(pass, t0, CACurrentMediaTime())
  }

  /// perf L1a：attributedText 赋值本身（记下时长，setContents 自身时长要扣掉它）
  private func perfNoteSetAttr(since t0: CFTimeInterval) {
    let t1 = CACurrentMediaTime()
    perfAttrSec = t1 - t0
    MarkdownPerfProbe.span?(.setAttr, t0, t1)
  }

  /// perf L1a：setParagraphContents 扣掉 attributedText 赋值后的自身时长
  private func perfNoteSetContents(since t0: CFTimeInterval) {
    let total = CACurrentMediaTime() - t0
    MarkdownPerfProbe.span?(.setContents, t0, t0 + max(0, total - perfAttrSec))
  }

  // perf L1a：宿主摆放（frame / bounds setter）计时，最外层；回调为 nil 直接走 super
  override var frame: CGRect {
    get { super.frame }
    set {
      guard MarkdownPerfProbe.span != nil, MarkdownPerfProbe.depth == 0 else { super.frame = newValue; return }
      MarkdownPerfProbe.depth += 1
      let t0 = CACurrentMediaTime()
      super.frame = newValue
      MarkdownPerfProbe.depth -= 1
      MarkdownPerfProbe.span?(.frame, t0, CACurrentMediaTime())
    }
  }

  override var bounds: CGRect {
    get { super.bounds }
    set {
      guard MarkdownPerfProbe.span != nil, MarkdownPerfProbe.depth == 0 else { super.bounds = newValue; return }
      MarkdownPerfProbe.depth += 1
      let t0 = CACurrentMediaTime()
      super.bounds = newValue
      MarkdownPerfProbe.depth -= 1
      MarkdownPerfProbe.span?(.frame, t0, CACurrentMediaTime())
    }
  }
  #endif

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    lastTouchPoint = touches.first?.location(in: self)
    super.touchesBegan(touches, with: event)
  }

  func setParagraphContents(_ newContents: NSMutableAttributedString, lineSpacing: CGFloat? = nil, animatedByWord: Bool) {
    #if (DEBUG || PERF_BENCH) && os(iOS)
    MarkdownPerfProbe.call?(.paragraphSetContents)
    // perf L1a：最外层计时；自身时长扣掉内层 attributedText 赋值（perfAttrSec），两段分开报
    let perfT0: CFTimeInterval? = MarkdownPerfProbe.span != nil && MarkdownPerfProbe.depth == 0 ? CACurrentMediaTime() : nil
    if perfT0 != nil { MarkdownPerfProbe.depth += 1; perfAttrSec = 0 }
    defer { if let perfT0 { MarkdownPerfProbe.depth -= 1; perfNoteSetContents(since: perfT0) } }
    #endif
    // Keep the cached interface style up to date for citation preview rendering.
    // This runs on the main thread so it's safe to read traitCollection here.
    InlineCitationAttachment.updateInterfaceStyle(traitCollection.userInterfaceStyle)

    let forceRefresh = needsContentRefresh
    needsContentRefresh = false
    guard forceRefresh || paragraphContents != newContents || self.lineSpacing != lineSpacing else {
      return
    }
    self.paragraphContents = newContents
    self.lineSpacing = lineSpacing

    let oldAttributedString: NSAttributedString = attributedText
    let finalString: NSMutableAttributedString
    if lineSpacing != nil {
      finalString = applyLineSpacing(to: newContents, lineSpacing: lineSpacing)
    } else {
      finalString = newContents
    }

    guard forceRefresh || finalString != oldAttributedString else {
      return
    }

    // Stop display link update before updating the attributed string
    tearDownDisplayLink()
    invalidateCachedSize()
    #if (DEBUG || PERF_BENCH) && os(iOS)
    let perfA0: CFTimeInterval? = perfT0 != nil ? CACurrentMediaTime() : nil
    #endif
    // MP fork: 段落簇要自己的布局片段（块高取整 + 块距），赋内容前装好；普通段落卸掉、还原 UITextView 原代理
    textLayoutManager?.updateTextRunDelegate(for: finalString, holder: &textRunLayout)
    attributedText = finalString
    #if (DEBUG || PERF_BENCH) && os(iOS)
    if let perfA0 { perfNoteSetAttr(since: perfA0) }
    if MarkdownPerfProbe.layout != nil { perfLaidOut = false }   // perf M4：换了内容，下一遍算首遍
    #endif
    spoilerState.contentDidChange(to: finalString.string)
    spoilerState.reapply(in: textStorage)
    refreshSpoilerDust()

    configureAccessibility(for: finalString)

    // MP fork patch 7: content replaced — old ranges void, repaint highlight layer
    appliedHighlightRanges = []
    attributeHighlightRanges = []
    reapplyHighlights()

    invalidateIntrinsicContentSize()

    let newContentLength = attributedText.length - oldAttributedString.length

    if animatedByWord,
       newContentLength > 0 {
      // Animate word by word
      let newContentRange = NSRange(location: oldAttributedString.length, length: newContentLength)
      let wordRanges = attributedText.splitIntoWords(withIn: newContentRange)
      let wordCount = wordRanges.count
      let delayBetweenWords: Double = 0.1 / Double(wordCount)
      let baseStartTime = CACurrentMediaTime()
      for (index, wordRange) in wordRanges.enumerated() {
        let animationData = FadeAnimationData(
          startTime: baseStartTime + Double(index) * delayBetweenWords,
          duration: Self.animationDuration,
          range: wordRange
        )
        activeAnimations.append(animationData)
      }

      updateTextViewWithCurrentAnimations()

      if fadeAnimationDisplayLink == nil {
        setUpDisplayLink()
      }
    } else {
      // If no animation needed anymore, clean up all existings animations if any.
      activeAnimations.removeAll()
    }
  }

  /// perf L1 ①：回池前重置（等价 prepareForReuse）。SwiftUI 已拆掉这个段落视图；下一个用它的 makeUIView 会重新
  /// 设内容 / 菜单 / 控制器 / 划线。文字与 frame 留着（清文字要重排、留 frame 让下次同宽时免一遍宽度变化重排）。
  func prepareForReuse() {
    tearDownDisplayLink()
    activeAnimations.removeAll()
    layer.removeAllAnimations()
    alpha = 1
    layer.mask = nil
    selectedTextRange = nil
    for dust in spoilerDust.values { dust.removeFromSuperlayer() }
    spoilerDust = [:]
    hasHiddenSpoilers = false
    spoilerDustSize = .zero
    spoilerState = SpoilerRevealState()
    lastTouchPoint = nil
    currentHighlights = []
    if !drawnStrokes.isEmpty {
      drawnStrokes = []
      strokeLayer.sublayers = nil
    }
    appliedHighlightRanges = []
    attributeHighlightRanges = []
    textContextMenu = nil
    markdownController = nil
    onUrlTap = { UIApplication.shared.open($0) }
    needsContentRefresh = true
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
    if NSTextAttachment.textAttachmentViewProviderClass(forFileType: UTType.url.identifier) == nil {
      NSTextAttachment.registerViewProviderClass(InlineCitationViewProvider.self, forFileType: UTType.url.identifier)
    }

    isEditable = false
    isSelectable = true
    isScrollEnabled = false
    textAlignment = .left
    backgroundColor = .clear
    if #available(iOS 18.0, *) {
      writingToolsBehavior = .none
    }

    setContentHuggingPriority(.defaultHigh, for: .vertical)
    setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    textContainerInset = .zero
    textContainer.lineFragmentPadding = 0
    textContainer.widthTracksTextView = true
    textContainer.heightTracksTextView = true
    textContainer.maximumNumberOfLines = 0
    textContainer.lineBreakMode = .byWordWrapping

    // When this is empty, UITextView will not override the styles set by attributes
    self.linkTextAttributes = [:]

    // Disable drag interaction to prevent crashes related to dragging from a view that might disappear
    textDragInteraction?.isEnabled = false
  }

  /// Creates a custom accessibility action that forwards activation to `onUrlTap`.
  private func makeAccessibilityAction(name: String, url: URL) -> UIAccessibilityCustomAction {
    return UIAccessibilityCustomAction(name: name) { [weak self] _ in
      guard let self else { return false }
      self.onUrlTap(url)
      return true
    }
  }

  /// Generate accessibility label and actions in a single pass (optimized)
  private func generateAccessibilityContent(from attributedString: NSAttributedString) -> AccessibilityContent? {
    var labelComponents: [String] = []
    var actions: [UIAccessibilityCustomAction] = []
    let fullRange = NSRange(location: 0, length: attributedString.length)

    attributedString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
      // Handle citation attachments
      if let attachment = attrs[.attachment] as? InlineCitationAttachment,
         let citationData = attachment.citationData {
        // Add to accessibility label
        labelComponents.append(citationData.accessibilityLabel)

        // Create accessibility action for citations
        let actionName = String.openCitation(citationLabel: citationData.accessibilityLabel)
        let action = makeAccessibilityAction(name: actionName, url: citationData.url)
        actions.append(action)
      } else {
        // Add the regular text for this range
        let substring = attributedString.attributedSubstring(from: range)
        let text = substring.string
        if !text.isEmpty {
          labelComponents.append(text)
        }
      }
    }

    let accessibilityLabel = labelComponents.isEmpty ? nil : labelComponents.joined()

    // Return nil if no attachments were found
    guard !actions.isEmpty else { return nil }

    return AccessibilityContent(label: accessibilityLabel, actions: actions)
  }

  /// Configure accessibility properties for the text view
  private func configureAccessibility(for attributedString: NSAttributedString) {
    // Generate the full accessibility content directly
    if let accessibilityContent = generateAccessibilityContent(from: attributedString) {
      // We have citations, use the generated content
      accessibilityLabel = accessibilityContent.label
      accessibilityCustomActions = accessibilityContent.actions
    } else {
      // No citations found, just use the plain text
      accessibilityLabel = attributedString.string
      accessibilityCustomActions = nil
    }
  }

  /// Configure visual styling for citations (separate from accessibility)
  private func configureVisualStyling(for attributedString: NSAttributedString) {
    // This method handles visual styling that should always be applied
    // regardless of accessibility configuration
    // Currently, the visual styling is handled during attachment creation
    // but this method is a placeholder for any future visual processing
  }

  // Custom easeOut curve
  private func easeOut(_ t: CGFloat) -> CGFloat {
    let c2: CGFloat = 0.1
    let c4: CGFloat = 1.0

    // Cubic Bezier evaluation
    let t2 = t * t
    let t3 = t2 * t
    let mt = 1 - t
    let mt2 = mt * mt

    return 3 * mt2 * t * c2 + 3 * mt * t2 * c4 + t3
  }

  @objc private func updateFadeAnimation() {
    let currentTime = CACurrentMediaTime()
    var completedAnimations: [UUID] = []

    updateTextViewWithCurrentAnimations()

    // Remove completed animations
    for animation in activeAnimations {
      let elapsed = currentTime - animation.startTime
      let progress = elapsed / animation.duration

      if progress >= 1.0 {
        completedAnimations.append(animation.id)
      }
    }
    activeAnimations.removeAll { completedAnimations.contains($0.id) }

    if activeAnimations.isEmpty {
      tearDownDisplayLink()
    }
  }

  private func updateTextViewWithCurrentAnimations() {
    let currentTime = CACurrentMediaTime()

    textStorage.beginEditing()
    defer { textStorage.endEditing() }

    for animation in activeAnimations {
      guard animation.range.location + animation.range.length <= textStorage.length else {
        continue
      }
      let elapsed = currentTime - animation.startTime
      let animatedAlpha: CGFloat

      if elapsed < 0 {
        animatedAlpha = 0.0
      } else {
        let progress = min(max(elapsed / animation.duration, 0.0), 1.0)
        let easedProgress = easeOut(progress) // Apply ease-out curve
        animatedAlpha = easedProgress
      }

      // Apply alpha to this animation's range, preserving each span's
      // existing foreground color. Spans with no foreground color get a
      // sensible default so they still fade in instead of disappearing.
      let defaultColor = UIColor(Color.Theme.Foreground.Primary.Primary750)
      textStorage.enumerateAttribute(.foregroundColor, in: animation.range, options: []) { value, range, _ in
        // MP fork: 未揭开的剧透字色是透明的，淡入不能把它染回来
        if textStorage.attribute(.mpmdSpoiler, at: range.location, effectiveRange: nil) != nil { return }
        let baseColor = (value as? UIColor) ?? defaultColor
        textStorage.addAttribute(.foregroundColor, value: baseColor.withAlphaComponent(animatedAlpha), range: range)
      }
    }
  }

  private func setUpDisplayLink() {
    fadeAnimationDisplayLink = CADisplayLink(target: self, selector: #selector(updateFadeAnimation))
    fadeAnimationDisplayLink?.preferredFramesPerSecond = 60
    fadeAnimationDisplayLink?.add(to: .main, forMode: .common)
  }

  private func tearDownDisplayLink() {
    fadeAnimationDisplayLink?.remove(from: .main, forMode: .common)
    fadeAnimationDisplayLink = nil
  }

  private func invalidateCachedSize() {
    cachedSize = nil
  }

  func setTextContextMenu(_ menu: TextContextMenu?) {
    textContextMenu = menu
  }

  func setMarkdownController(_ controller: MarkdownController?) {
    markdownController = controller
  }

  // MARK: - MP fork patch 7: persistent highlights (chat transcript annotations)

  /// Repaint highlight layer. Independent of the content pipeline: tracks its
  /// own applied ranges so it never strips other `.backgroundColor` users
  /// (inline code chips). Content replacement must reset `appliedHighlightRanges`
  /// before repainting (old ranges are void against new storage).
  func setTextHighlights(_ highlights: [TextHighlight]) {
    guard highlights != currentHighlights else { return }
    currentHighlights = highlights
    reapplyHighlights()
    installHighlightTapIfNeeded()
  }

  /// MP fork patch 7.1: single tap on a highlighted run reports it via
  /// `onContextMenuTap(id: "highlight.tap", selectedContent: quote)` so hosts
  /// can present a management UI. Link taps pass through untouched; requires
  /// double-tap (word selection) to fail first so text selection still works.
  private func installHighlightTapIfNeeded() {
    guard !currentHighlights.isEmpty, highlightTapGesture == nil else { return }
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleHighlightTap(_:)))
    tap.cancelsTouchesInView = false
    for g in gestureRecognizers ?? [] {
      if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired > 1 {
        tap.require(toFail: t)
      }
    }
    addGestureRecognizer(tap)
    highlightTapGesture = tap
  }

  @objc private func handleHighlightTap(_ gesture: UITapGestureRecognizer) {
    guard !appliedHighlightRanges.isEmpty else { return }
    let point = gesture.location(in: self)
    // UITextInput hit test — TextKit-version agnostic (this view runs TextKit 2;
    // touching .layoutManager would silently downgrade to TextKit 1)
    guard let position = closestPosition(to: point) else { return }
    let idx = offset(from: beginningOfDocument, to: position)
    guard idx >= 0, idx < textStorage.length else { return }
    if textStorage.attribute(.link, at: idx, effectiveRange: nil) != nil { return }
    guard let hit = appliedHighlightRanges.first(where: { NSLocationInRange(idx, $0.range) }) else { return }
    markdownController?.onContextMenuTap(id: "highlight.tap", selectedContent: hit.quote)
  }

  func reapplyHighlights() {
    for r in attributeHighlightRanges where NSMaxRange(r) <= textStorage.length {
      textStorage.removeAttribute(.backgroundColor, range: r)
    }
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
    redrawStrokeLayer()
  }

  /// Per-line frames of `range` from TextKit 2 (never touch `layoutManager`: it downgrades to TextKit 1).
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
    let inset = textContainerInset
    return frames.map { $0.offsetBy(dx: inset.left, dy: inset.top) }
  }

  private func redrawStrokeLayer() {
    guard !drawnStrokes.isEmpty || strokeLayer.sublayers?.isEmpty == false else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    strokeLayer.frame = bounds
    strokeLayer.sublayers = nil
    strokeLayoutSize = bounds.size
    for stroke in drawnStrokes {
      let pieces = TextHighlightGeometry.pieces(
        style: stroke.highlight.style, color: stroke.highlight.color.cgColor,
        strokeId: stroke.highlight.strokeId, layer: stroke.layer, rects: segmentFrames(for: stroke.range))
      for piece in pieces {
        let shape = CAShapeLayer()
        shape.path = piece.path
        shape.fillColor = piece.color
        shape.actions = ["path": NSNull(), "fillColor": NSNull()]
        strokeLayer.addSublayer(shape)
      }
    }
    CATransaction.commit()
  }
}

// MARK: - MP fork: 剧透粒子
extension ParagraphUIView {
  /// 按还藏着的剧透重建 / 更新粒子层（内容换了、宽度变了）
  fileprivate func refreshSpoilerDust() {
    let hidden = SpoilerRevealState.hiddenSpoilers(in: textStorage)
    hasHiddenSpoilers = !hidden.isEmpty
    spoilerDustSize = bounds.size
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
          dust = SpoilerDustLayer(animated: !UIAccessibility.isReduceMotionEnabled)
          dust.contentsScale = traitCollection.displayScale
          layer.addSublayer(dust)
          spoilerDust[spoiler.url] = dust
        }
        dust.frame = bounds
        dust.update(rects: rects, color: spoiler.color.resolvedColor(with: traitCollection).cgColor)
      }
    }
    for (url, dust) in spoilerDust where !alive.contains(url) && !dust.isRevealing {
      dust.removeFromSuperlayer()
      spoilerDust[url] = nil
    }
  }

  /// 点开一个剧透：字放回原色但先被遮罩挡着，圆从手指处扩开露出来；粒子层同步散掉
  fileprivate func revealSpoiler(_ url: URL) {
    guard let dust = spoilerDust[url], !dust.isRevealing else {
      _ = spoilerState.reveal(url, in: textStorage)
      refreshSpoilerDust()
      return
    }
    let union = dust.rects.reduce(CGRect.null) { $0.union($1) }
    let point = lastTouchPoint.flatMap { p in dust.rects.contains { $0.insetBy(dx: -12, dy: -12).contains(p) } ? p : nil }
      ?? CGPoint(x: union.midX, y: union.midY)
    let mask = SpoilerTextRevealMask(bounds: bounds, spoilerRects: dust.rects)
    layer.mask = mask
    _ = spoilerState.reveal(url, in: textStorage)
    dust.reveal(at: point, textMask: mask) { [weak self, weak dust] in
      dust?.removeFromSuperlayer()
      guard let self else { return }
      if self.spoilerDust[url] === dust { self.spoilerDust[url] = nil }
      if self.layer.mask === mask { self.layer.mask = nil }
      self.hasHiddenSpoilers = !self.spoilerDust.isEmpty
    }
  }
}

// MARK: - UITextViewDelegate
extension ParagraphUIView: UITextViewDelegate {
  func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
    // MP fork: 剧透 / 缩写是内部链接，自己处理（长按预览之类的交互直接吞掉）
    if InlineExtensionURL.isInternal(URL) {
      guard interaction == .invokeDefaultAction else { return false }
      if URL.scheme == InlineExtensionURL.spoilerScheme {
        revealSpoiler(URL)
      } else if let title = InlineExtensionURL.abbreviationTitle(from: URL),
                let start = position(from: beginningOfDocument, offset: characterRange.location),
                let end = position(from: start, offset: characterRange.length),
                let range = textRange(from: start, to: end) {
        let rect = firstRect(for: range)
        abbreviationPresenter.present(title: title, at: CGPoint(x: rect.midX, y: rect.minY), in: self)
      }
      return false
    }
    self.onUrlTap(URL)
    return false
  }

  func textView(_ textView: UITextView, shouldInteractWith textAttachment: NSTextAttachment, in characterRange: NSRange) -> Bool {
    // Check if this is our custom citation attachment with pre-decoded data
    if let citationAttachment = textAttachment as? InlineCitationAttachment,
       let citationData = citationAttachment.citationData {
      self.onUrlTap(citationData.url)
      return false
    }

    return false
  }

  func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
    return textContextMenu?.buildUIMenu(
      textView: textView,
      selectedRange: range,
      suggestedActions: suggestedActions,
      markdownController: markdownController
    )
  }

  func textView(_ textView: UITextView, willPresentEditMenuWith animator: any UIEditMenuInteractionAnimating) {
    guard let textContextMenu, let markdownController else { return }
    let clampedRange = NSIntersectionRange(textView.selectedRange, NSRange(location: 0, length: textView.attributedText.length))
    let selectedText = textView.attributedText.attributedSubstring(from: clampedRange).string
    for group in textContextMenu.menuGroups {
      for item in group.items {
        markdownController.onContextMenuAppear(id: item.id, selectedContent: selectedText)
      }
    }
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

final class LatexViewProvider: NSTextAttachmentViewProvider {
  private let latex: String
  private let fontSize: CGFloat
  private let textColor: UIColor
  private static let jsonDecoder = JSONDecoder()

  required override init(textAttachment attachment: NSTextAttachment,
                         parentView: UIView?,
                         textLayoutManager: NSTextLayoutManager?,
                         location: any NSTextLocation) {

    var tempLatex = ""
    var tempFontSize = Typography.base.uiFont.pointSize
    var tempTextColor: UIColor = UIColor(Color.Theme.Foreground.Primary.Primary750)
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
    let label = MTMathUILabel()
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
    mathLabel.sizeToFit()
    // It's a known issue that MTMathUILabel may be cut off for some short statement. Manually add 1 to the height fix it.
    let height = mathLabel.bounds.height.rounded(.up) + 1.0
    let font = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: fontSize)
    let yOffset = (font.xHeight - height) / 2.0
    return CGRect(x: 0, y: yOffset, width: mathLabel.bounds.width.rounded(.up), height: height)
  }
}

#endif  // os(iOS)
