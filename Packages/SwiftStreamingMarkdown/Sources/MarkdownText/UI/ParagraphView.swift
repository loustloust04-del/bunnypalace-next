//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import SwiftUI

#if os(iOS)
struct ParagraphView: UIViewRepresentable {
  @Environment(\.openURL) var openURL
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  @Environment(\.markdownController) var markdownController: MarkdownController?

  var contents: NSMutableAttributedString
  var lineSpacing: CGFloat?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> ParagraphUIView {
    let openUrlFunction = openURL.callAsFunction(_:)
    let view = ParagraphUIViewCache.shared.createOrReuseParagraphUIView(contents: contents, lineSpacing: lineSpacing)
    view.onUrlTap = openUrlFunction
    view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    view.setTextContextMenu(config.textContextMenu)
    view.setMarkdownController(markdownController)
    view.setTextHighlights(config.textHighlights)

    if config.shouldAnimateText {
      view.alpha = 0
      UIView.animate(withDuration: ParagraphUIView.animationDuration) {
        view.alpha = 1
      }
    }

    return view
  }

  func updateUIView(_ view: ParagraphUIView, context: Context) {
    if view.paragraphContents != contents || view.lineSpacing != lineSpacing {
      let shouldAnimate = view.window != nil && config.shouldAnimateText // only animate when visible
      view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: shouldAnimate)
    }
    view.setTextContextMenu(config.textContextMenu)
    view.setMarkdownController(markdownController)
    view.setTextHighlights(config.textHighlights)
  }

  // MP fork perf L1 ①：拆掉时只计数（R14-05：P1a 前不回池）
  static func dismantleUIView(_ uiView: ParagraphUIView, coordinator: Coordinator) {
    ParagraphUIViewCache.shared.recycle(uiView)
  }

  // If we don't implement this function, the snapshot tests will fail with incorrect sizing.
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ParagraphUIView, context: Context) -> CGSize? {
    #if (DEBUG || PERF_BENCH) && os(iOS)
    MarkdownPerfProbe.call?(.paragraphSizeThatFits)
    #endif
    // MP fork patch 6: nil/无限宽提案（ideal 查询）不再返回 nil——返回 nil 会退回
    // UIView intrinsicContentSize（按当下 bounds/屏宽猜着量），量出的高度与最终布局
    // 宽度错配 → 高度不足 → 长段落尾部被裁掉（气泡模式抱字协商后高发）。
    // ideal 语义 = 无约束测量（1e6 当无限用，避免 inf 进缓存键）。
    let width: CGFloat
    if let proposed = proposal.width, proposed > 0, proposed.isFinite {
      width = proposed
    } else {
      width = 1_000_000
    }

    // Check if content or lineSpacing changed - if so, clear the cache
    if contents != context.coordinator.lastContents || lineSpacing != context.coordinator.lastLineSpacing {
      context.coordinator.sizeCache.removeAll()
      context.coordinator.lastContents = contents
      context.coordinator.lastLineSpacing = lineSpacing
    }

    // Round width to avoid cache misses from floating point precision issues
    let cacheKey = (width * 10).rounded() / 10 // Round to 1 decimal place

    // Check if we have a cached size for this width
    if let cachedSize = context.coordinator.sizeCache[cacheKey] {
      return cachedSize
    }

    // Calculate new size
    let targetSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    let size = uiView.sizeThatFits(targetSize)
    let calculatedSize = CGSize(width: size.width, height: size.height.rounded(.up))

    context.coordinator.sizeCache[cacheKey] = calculatedSize

    return calculatedSize
  }

  class Coordinator {
    // Cache all calculated sizes keyed by width
    var sizeCache: [CGFloat: CGSize] = [:]
    var lastContents: NSMutableAttributedString?
    var lastLineSpacing: CGFloat?
  }
}

extension ParagraphView: Equatable {
  static func == (lhs: ParagraphView, rhs: ParagraphView) -> Bool {
    lhs.contents == rhs.contents && lhs.lineSpacing == rhs.lineSpacing
  }
}
#else
// MP fork mac: NSTextView 版段落视图，与上面 iOS 分支逐行对应（同一套 size cache、patch 6 语义）。
struct ParagraphView: NSViewRepresentable {
  @Environment(\.openURL) var openURL
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  @Environment(\.markdownController) var markdownController: MarkdownController?

  var contents: NSMutableAttributedString
  var lineSpacing: CGFloat?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> ParagraphNSView {
    let openUrlFunction = openURL.callAsFunction(_:)
    let view = ParagraphNSViewCache.shared.createOrReuseParagraphNSView(contents: contents, lineSpacing: lineSpacing)
    view.onUrlTap = openUrlFunction
    view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    view.setTextContextMenu(config.textContextMenu)
    view.setMarkdownController(markdownController)
    view.setTextHighlights(config.textHighlights)
    // mac 不做淡入：iOS 这里按 shouldAnimateText 做 alpha 0→1，mac 的原生文本视图不走这条动画。
    return view
  }

  func updateNSView(_ view: ParagraphNSView, context: Context) {
    if view.paragraphContents != contents || view.lineSpacing != lineSpacing {
      // mac 不做逐词淡入：iOS 的 shouldAnimate = window != nil && shouldAnimateText，mac 恒 false。
      view.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
    }
    view.setTextContextMenu(config.textContextMenu)
    view.setMarkdownController(markdownController)
    view.setTextHighlights(config.textHighlights)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ParagraphNSView, context: Context) -> CGSize? {
    // MP fork patch 6（mac 同语义）：nil/无限宽提案（ideal 查询）= 无约束测量（1e6 当无限用，避免 inf 进缓存键）。
    let width: CGFloat
    if let proposed = proposal.width, proposed > 0, proposed.isFinite {
      width = proposed
    } else {
      width = 1_000_000
    }

    // Check if content or lineSpacing changed - if so, clear the cache
    if contents != context.coordinator.lastContents || lineSpacing != context.coordinator.lastLineSpacing {
      context.coordinator.sizeCache.removeAll()
      context.coordinator.lastContents = contents
      context.coordinator.lastLineSpacing = lineSpacing
    }

    // Round width to avoid cache misses from floating point precision issues
    let cacheKey = (width * 10).rounded() / 10 // Round to 1 decimal place

    // Check if we have a cached size for this width
    if let cachedSize = context.coordinator.sizeCache[cacheKey] {
      return cachedSize
    }

    // Calculate new size
    let targetSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    let size = nsView.sizeThatFits(targetSize)
    // MP fork: 段落簇的高 = 末块取整后的底（块距可以是小数，滑杆），再取整会把后面的块顶下去最多 1pt
    let height = TextRunLayoutDelegate.isTextRun(contents) ? (size.height * 10_000).rounded() / 10_000 : size.height.rounded(.up)
    let calculatedSize = CGSize(width: size.width, height: height)

    context.coordinator.sizeCache[cacheKey] = calculatedSize

    return calculatedSize
  }

  class Coordinator {
    // Cache all calculated sizes keyed by width
    var sizeCache: [CGFloat: CGSize] = [:]
    var lastContents: NSMutableAttributedString?
    var lastLineSpacing: CGFloat?
  }
}

extension ParagraphView: Equatable {
  static func == (lhs: ParagraphView, rhs: ParagraphView) -> Bool {
    lhs.contents == rhs.contents && lhs.lineSpacing == rhs.lineSpacing
  }
}
#endif
