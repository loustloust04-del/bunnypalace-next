// MP fork（P1a-0 spike，MemoryPalace docs/spike-uikit-chat-page.md）：让 app 侧的 UIKit 聊天新页 spike
// 直接用现有 ParagraphUIView（原生 cell 方案 b / c）。只在 DEBUG / PERF_BENCH 的 iOS 构建里存在，spike 删除时一并删。
#if (DEBUG || PERF_BENCH) && os(iOS)
import UIKit

public enum ParagraphSpikeAccess {
  /// 从同一个池（ParagraphUIViewCache，上限 50、superview == nil 才复用）取一个 ParagraphUIView
  public static func vend() -> UITextView {
    ParagraphUIViewCache.shared.createOrReuseParagraphUIView(contents: NSMutableAttributedString(), lineSpacing: nil)
  }

  public static func setContents(_ view: UITextView, _ contents: NSMutableAttributedString, lineSpacing: CGFloat?) {
    (view as? ParagraphUIView)?.setParagraphContents(contents, lineSpacing: lineSpacing, animatedByWord: false)
  }
}
#endif
