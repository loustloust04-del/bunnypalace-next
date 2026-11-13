// MP fork（段尾丢字探针 B，粟粟 10-31）：段落视图排完版后，
// 有字没排进视图高度（iOS 文本容器高 = 视图高，排不下的行整行不画）就报给宿主。
// 只在 DEBUG 构建里存在；回调为 nil 时插入点只做一次 nil 判断。报告里没有正文。
#if DEBUG
import CoreGraphics
import SwiftUI

public enum ParagraphLayoutProbe {
  public struct Report: Equatable {
    /// 宿主经 `markdownProbeTag` 给的标记（MP：节点 id 前 8 位 + 泡序号）
    public let tag: String?
    /// 顶层块序号（`BlockView` 里第几块；嵌套块沿用外层序号）
    public let block: Int?
    /// 没排进视图的字数（UTF-16）
    public let missing: Int
    /// 段落总字数（UTF-16）
    public let length: Int
    public let width: CGFloat
    public let height: CGFloat
    /// 同宽排完全部需要的高
    public let needed: CGFloat

    public init(tag: String?, block: Int?, missing: Int, length: Int, width: CGFloat, height: CGFloat, needed: CGFloat) {
      self.tag = tag
      self.block = block
      self.missing = missing
      self.length = length
      self.width = width
      self.height = height
      self.needed = needed
    }
  }

  nonisolated(unsafe) public static var onTruncation: ((Report) -> Void)?

  /// 行底超出视图高这么多才算排不下（浮点误差）
  static let tolerance: CGFloat = 0.01

  /// lines：按排版顺序每行（起点偏移，行底 y）；laidOutEnd：排出来的最后一个片段之后的偏移。
  /// 第一行排不下 → 从它起往后都算没进来；行都在框里但片段没排到结尾 → 尾巴那截算没进来。
  static func missingCount(lines: [(start: Int, maxY: CGFloat)], laidOutEnd: Int, total: Int, height: CGFloat) -> Int {
    if let firstOut = lines.first(where: { $0.maxY > height + tolerance }) {
      return max(0, total - firstOut.start)
    }
    return max(0, total - laidOutEnd)
  }
}

extension EnvironmentValues {
  /// 宿主给段落探针的标记（不放正文）
  @Entry public var markdownProbeTag: String? = nil
  @Entry var markdownProbeBlock: Int? = nil
}
#endif
