//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

// MP fork mac-port L1: 整文件 iOS 专属留门（UITextView 缓存池）；mac 对等物由 L2 新建。
#if os(iOS)

import UIKit

/// MP fork（perf L1，MemoryPalace docs/plan-chat-list-perf.md §3）：长文首次渲染的产品开关。
/// 默认新行为；DEBUG / PERF_BENCH 构建可用 env 置 "0" 关回原行为（同包 ABBA 对照），普通 Release 恒为默认。
enum ParagraphL1Switch {
  /// ① UITextView 池：启动后与池低于低水位时空闲分片预热；SwiftUI 拆段落视图（dismantle）时重置回池（10-01 实测文章模式聊天里不发生）（MP_PERF_L1_POOL）
  static let pool = flag("MP_PERF_L1_POOL", default: true)
  /// 空闲补池的目标数（默认 128；DEBUG / PERF_BENCH 可用 MP_PERF_L1_POOL_TARGET 试 64 等，低水位 = 一半）
  static let poolTarget: Int = {
    #if DEBUG || PERF_BENCH
    if let v = ProcessInfo.processInfo.environment["MP_PERF_L1_POOL_TARGET"].flatMap(Int.init), v > 0 { return v }
    #endif
    return 128
  }()

  private static func flag(_ key: String, default on: Bool) -> Bool {
    #if DEBUG || PERF_BENCH
    if let v = ProcessInfo.processInfo.environment[key] { return v != "0" }
    #endif
    return on
  }
}

/// MP fork（perf L1 ①）：宿主 app 在启动后空闲时调一次，先把段落视图池补起来（第一次打开对话就有池可用）。开关关 = 无事
public enum ParagraphViewPrewarm {
  /// 宿主给的闲置门（R14-04）：返回 false = 现在别建（键盘过渡 / 流式中 / 刚有触摸），补池推迟 100ms 再看
  nonisolated(unsafe) public static var idleGate: (() -> Bool)?

  public static func start() {
    guard ParagraphL1Switch.pool else { return }
    ParagraphUIViewCache.shared.prewarmIfNeeded()
  }
}

class ParagraphUIViewCache {
  @WithLock
  private var cachedViews: [ParagraphUIView] = []
  private let maxCacheSize = 50 // Limit cache size
  /// L1 ①：预热新建、还没发出去的视图，只在主线程碰
  private var free: [ParagraphUIView] = []
  /// 空闲补池：低于 lowWater 就在空闲时补到 prewarmTarget（首次发视图时池是空的 = 首次预热）
  private let prewarmTarget = ParagraphL1Switch.poolTarget
  private let lowWater = ParagraphL1Switch.poolTarget / 2
  private var prewarmScheduled = false
  private init() {}

  static let shared: ParagraphUIViewCache = .init()

  func createOrReuseParagraphUIView(contents: NSMutableAttributedString, lineSpacing: CGFloat?) -> ParagraphUIView {
    #if (DEBUG || PERF_BENCH) && os(iOS)
    // perf M4：池命中 / 新建计数（新建耗时含 ParagraphUIView.init）；回调为 nil 不计时
    let perfT0: CFTimeInterval? = MarkdownPerfProbe.vend != nil ? CACurrentMediaTime() : nil
    #endif
    if ParagraphL1Switch.pool {
      defer { if free.count < lowWater { schedulePrewarm() } }
      while let view = free.popLast() {
        guard view.superview == nil else { continue }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if let perfT0 { MarkdownPerfProbe.vend?(true, perfT0, CACurrentMediaTime()) }
        #endif
        return view
      }
      let newView = ParagraphUIView()
      #if (DEBUG || PERF_BENCH) && os(iOS)
      if let perfT0 { MarkdownPerfProbe.vend?(false, perfT0, CACurrentMediaTime()) }
      #endif
      return newView
    }

    // First, try to find a cached view that's not being used
    if let availableView = findAvailableCachedView(contents: contents, lineSpacing: lineSpacing) {
      #if (DEBUG || PERF_BENCH) && os(iOS)
      if let perfT0 { MarkdownPerfProbe.vend?(true, perfT0, CACurrentMediaTime()) }
      #endif
      return availableView
    }

    // If no cached view is available, create a new one
    let newView = ParagraphUIView()
    if $cachedViews.read(closure: { $0.count }) < maxCacheSize {
      $cachedViews.mutate { $0.append(newView) }
    }
    #if (DEBUG || PERF_BENCH) && os(iOS)
    if let perfT0 { MarkdownPerfProbe.vend?(false, perfT0, CACurrentMediaTime()) }
    #endif
    return newView
  }

  /// SwiftUI 拆掉段落视图（ParagraphView.dismantleUIView）。R14-05：P1a 前只计数、不回池——回池路径（sheet 关闭等）
  /// 没验证过，聊天里实测也从不触发；P1a 原生 cell 用 ParagraphUIView.prepareForReuse 自己回收。
  func recycle(_ view: ParagraphUIView) {
    #if (DEBUG || PERF_BENCH) && os(iOS)
    if MarkdownPerfProbe.span != nil { let perfT0 = CACurrentMediaTime(); MarkdownPerfProbe.span?(.dismantle, perfT0, perfT0) }
    #endif
  }

  /// 池低于 lowWater 时排一轮补池：0.3s 后开始（不压正在进行的加载），主 run loop 默认模式（滚动跟踪模式下不跑），
  /// 每 20ms 一片、每片 1 个视图；闲置门（R14-04）：app 非 active、宿主 idleGate 说不闲时不建，100ms 后再看。补到 prewarmTarget 停
  func prewarmIfNeeded() {
    if free.count < lowWater { schedulePrewarm() }
  }

  private func schedulePrewarm() {
    guard !prewarmScheduled else { return }
    prewarmScheduled = true
    prewarmStep(after: 0.3)
  }

  private func prewarmStep(after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        guard let self else { return }
        guard UIApplication.shared.applicationState == .active, ParagraphViewPrewarm.idleGate?() ?? true else {
          self.prewarmStep(after: 0.1)
          return
        }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let perfT0: CFTimeInterval? = MarkdownPerfProbe.span != nil && MarkdownPerfProbe.depth == 0 ? CACurrentMediaTime() : nil
        defer { if let perfT0 { MarkdownPerfProbe.span?(.prewarm, perfT0, CACurrentMediaTime()) } }
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if let section = MarkdownPerfProbe.section {
          section("ParagraphPrewarm.step") { self.free.insert(ParagraphUIView(), at: 0) }
        } else {
          self.free.insert(ParagraphUIView(), at: 0)
        }
        #else
        self.free.insert(ParagraphUIView(), at: 0)
        #endif
        if self.free.count < self.prewarmTarget { self.prewarmStep(after: 0.02) } else { self.prewarmScheduled = false }
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }

  private func findAvailableCachedView(contents: NSMutableAttributedString, lineSpacing: CGFloat?) -> ParagraphUIView? {
    // Get the first available view that is not currently in use
    let availableView = $cachedViews.read(closure: { cachedView in
      return cachedView.first { view in
        return view.superview == nil && view.window == nil
      }
    })

    return availableView
  }
}

#endif  // os(iOS)
