//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI

struct OrderedListView: View {

  let items: [MarkdownListItem]
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig

  var body: some View {
    VStack(alignment: .leading, spacing: 8, content: {
      ForEach(0..<items.count, id: \.self) { idx in
        HStack(alignment: .centerOfFirstLine, spacing: 11) {
          Text(verbatim: "\(idx+1).")
            .font(config.orderedListStyle.textFonts, bold: true)
            .foregroundStyle(Color(config.orderedListStyle.textColor))
            // MP fork patch 9: 序号定死成刚体——patch 6 后 ParagraphView 弹性=0 排最先分配，
            // 弹性微正的 Text 序号垫后 → 正文只拿到 remaining/2 定格半宽（无序列表的圆点是
            // 固定 frame Image 天然刚体所以没事）。fixedSize 后序号先分只拿实宽，正文拿全部剩余。
            .fixedSize()
            .transition(.opacity)
          if let firstChild = items[idx].children.first {
            if case .paragraph(_, let contents) = firstChild {
              // Wrap the SingleBlockView to provide proper baseline alignment. This is to fix the mis-alignment when the view is rendered off-screen, e.g. snapshot.
              ListItemContentWrapper(paragraphContents: contents) {
                SingleBlockView(renderable: firstChild)
              }
              .accessibilityLabel(Text(markdownListAccessibilityLabel(for: contents.string, at: idx, length: items.count)))
            } else {
              SingleBlockView(renderable: firstChild)
            }
          }
          // MP fork patch 8: 行内 Spacer 删——patch 6 后 ParagraphView 对 0 宽提案返回
          // 单行全宽（弹性=0），HStack 分账时 Spacer 抢走近半宽度 → 列表项折行成窄条。
          // patch 5 已给段落/标题做过同款手术，列表当时漏了；左对齐由外层 VStack(.leading) 保证。
        }
        if items[idx].children.count > 1 {
          BlockView(renderables: Array(items[idx].children.dropFirst()))
            .padding([.leading], 0)
        }
      }
    })
  }
}

// Wrapper to provide proper baseline alignment for UIViewRepresentable content
struct ListItemContentWrapper<Content: View>: View {
  let paragraphContents: NSMutableAttributedString
  let content: () -> Content

  init(paragraphContents: NSMutableAttributedString, @ViewBuilder content: @escaping () -> Content) {
    self.paragraphContents = paragraphContents
    self.content = content
  }

  var body: some View {
    content()
      .alignmentGuide(.centerOfFirstLine) { _ in
        let font = listItemFirstFont(in: paragraphContents)
        return font.lineHeight / 2.0
      }
  }
}

/// 列表行第一行对齐用的字体（MP fork：段落簇画列表标记时也按它对齐，抽成函数两边共用）
func listItemFirstFont(in paragraphContents: NSAttributedString) -> PlatformFont {
  // First check if the first character is a citation attachment - use its
  // own font so the alignment guide matches the actual rendered glyph,
  // not a stale default.
  if let citation = firstCharacterCitationAttachment(in: paragraphContents) {
    return citation.font
  }
  // Otherwise, look for regular font attributes
  if let font = firstUIFont(in: paragraphContents) {
    return font
  }
  return Typography.base.uiFont
}

private func firstCharacterCitationAttachment(in attributedString: NSAttributedString) -> InlineCitationAttachment? {
  guard attributedString.length > 0 else { return nil }
  return attributedString.attribute(.attachment, at: 0, effectiveRange: nil) as? InlineCitationAttachment
}

private func firstUIFont(in attributedString: NSAttributedString) -> PlatformFont? {
  guard attributedString.length > 0 else { return nil }

  // Fast path: attribute at location 0
  if let font = attributedString.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont {
    return font
  }

  var found: PlatformFont?
  attributedString.enumerateAttribute(.font, in: NSRange(location: 0, length: attributedString.length)) { value, _, stop in
    if let font = value as? PlatformFont {
      found = font
      stop.pointee = true
    }
  }
  return found
}

func markdownListAccessibilityLabel(for item: String, at index: Int, length: Int) -> String {
  "\(String.markdownList(length: String(length))), item \(index + 1): \(item)"
}

#Preview(body: {
  let items: [MarkdownListItem] = (0..<40).map { i in
    MarkdownListItem(children: [.paragraph(id: "\(i)", content: NSMutableAttributedString(string: "item \(i + 1)"))], startsWithBold: false)
  }
  return ScrollView {
    OrderedListView(items: items)
  }
})
