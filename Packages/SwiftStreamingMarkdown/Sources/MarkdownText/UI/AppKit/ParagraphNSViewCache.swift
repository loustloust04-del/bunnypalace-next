//
//  MP fork mac: ParagraphUIViewCache 的 AppKit 对等物（NSTextView 缓存池，逻辑与 iOS 版相同）。
//

#if os(macOS)

import AppKit

class ParagraphNSViewCache {
  @WithLock
  private var cachedViews: [ParagraphNSView] = []
  private let maxCacheSize = 50 // Limit cache size
  private init() {}

  static let shared: ParagraphNSViewCache = .init()

  func createOrReuseParagraphNSView(contents: NSMutableAttributedString, lineSpacing: CGFloat?) -> ParagraphNSView {
    // First, try to find a cached view that's not being used
    if let availableView = findAvailableCachedView(contents: contents, lineSpacing: lineSpacing) {
      return availableView
    }

    // If no cached view is available, create a new one
    let newView = ParagraphNSView.make()
    if $cachedViews.read(closure: { $0.count }) < maxCacheSize {
      $cachedViews.mutate { $0.append(newView) }
    }
    return newView
  }

  private func findAvailableCachedView(contents: NSMutableAttributedString, lineSpacing: CGFloat?) -> ParagraphNSView? {
    // Get the first available view that is not currently in use
    let availableView = $cachedViews.read(closure: { cachedView in
      return cachedView.first { view in
        return view.superview == nil && view.window == nil
      }
    })

    return availableView
  }
}

#endif  // os(macOS)
