// MP fork（docs/plan-重构.md R2 / R3）：原生块行的量法要和 SwiftUI 那条路逐值相同，对话页新旧两版才可能逐像素相同。
#if os(iOS)

import Foundation
@testable import SwiftStreamingMarkdown
import Testing
import UIKit

@MainActor
@Suite("MarkdownBlockRows")
struct MarkdownBlockRowsTests {
  private static let samples = [
    "一句话。",
    "这句里有**粗体**、*斜体*、`行内代码`、~~删除线~~，还有一个[链接](https://example.com)。",
    "春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。The quick brown fox jumps over the lazy dog, twice. 再接一段中文让它折到第三行、第四行，看取整是不是一致。",
    "# 一级标题",
    "## 二级标题 with English",
    "### 三级标题\n\n标题后面的段落。",
    "第一段。\n\n第二段，稍微长一点点，为了折行：一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十。\n\n第三段。",
    "emoji 😀🍪 和 CJK 标点——「引号」、省略号……混排 mixed 123。"
  ]
  private static let widths: [CGFloat] = [120, 240, 329, 361, 393, 700]

  @Test func blocksKeepDocumentOrderAndClassifyText() {
    let document = MarkdownParserImpl().parseSync(text: "# 标题\n\n段落\n\n- 列表\n\n```swift\nlet a = 1\n```\n\n结尾", config: .default)
    #expect(document.blocks.map(\.kind) == [.text, .text, .other, .other, .text])
    #expect(Set(document.blocks.map(\.id)).count == 5)
  }

  /// 后台预排的高度必须等于真视图量出来的高度；不等就不能把后台高度当最终高度用
  @Test func preparedHeightEqualsMeasuredHeight() {
    var mismatches: [String] = []
    var compared = 0
    for sample in Self.samples {
      for block in MarkdownParserImpl().parseSync(text: sample, config: .default).blocks where block.kind == .text {
        for width in Self.widths {
          guard let prepared = block.preparedHeight(width: width, config: .default),
                let measured = MarkdownTextBlockView.measuredSize(block, width: width, config: .default) else {
            mismatches.append("量不出来：\(sample.prefix(12)) @\(width)")
            continue
          }
          compared += 1
          if prepared != measured.height {
            mismatches.append("\(sample.prefix(12))… 宽 \(width)：预排 \(prepared) 实排 \(measured.height)")
          }
        }
      }
    }
    #expect(compared >= Self.samples.count * Self.widths.count)
    #expect(mismatches.isEmpty, "\(mismatches.count) 处不一致：\n\(mismatches.prefix(20).joined(separator: "\n"))")
  }

  /// 段落簇两种量法对不上（实测差 1–5pt），所以后台不给高度，只能主线程量
  @Test func mergedTextRunsHaveNoPreparedHeight() throws {
    let config = MarkdownRenderConfig(shouldAnimateText: false, mergesTextRuns: true)
    let block = try #require(MarkdownParserImpl().parseSync(text: Self.samples[6], config: config).blocks.first)
    #expect(block.preparedHeight(width: 329, config: config) == nil)
    #expect(MarkdownTextBlockView.measuredSize(block, width: 329, config: config) != nil)
  }

  /// 原生视图按量出来的尺寸摆好以后，文字不被裁：文本视图自己需要的高度不超过给它的高度
  @Test func textBlockViewFitsItsMeasuredSize() throws {
    let document = MarkdownParserImpl().parseSync(text: Self.samples[2], config: .default)
    let block = try #require(document.blocks.first)
    let size = try #require(MarkdownTextBlockView.measuredSize(block, width: 329, config: .default))
    let view = MarkdownTextBlockView(frame: CGRect(x: 0, y: 0, width: 329, height: size.height))
    view.configure(block, config: .default)
    view.layoutIfNeeded()
    let text = try #require(view.subviews.first as? UITextView)
    #expect(text.sizeThatFits(CGSize(width: 329, height: CGFloat.greatestFiniteMagnitude)).height.rounded(.up) == size.height)
    #expect(size.width <= 329)
  }
}

#endif
