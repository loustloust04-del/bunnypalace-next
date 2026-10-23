//
//  MP fork: `<details><summary>` 折叠块。标题行点一下展开 / 收起，正文是递归解析出的块。
//

import SwiftUI

struct DetailsBlockView: View {

  let summary: NSMutableAttributedString
  let children: [MarkdownRenderable]
  @State private var isOpen: Bool

  init(summary: NSMutableAttributedString, initiallyOpen: Bool, children: [MarkdownRenderable]) {
    self.summary = Self.styledSummary(summary)
    self.children = children
    self._isOpen = State(initialValue: initiallyOpen)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(CodeBlockStyle.label)
          .rotationEffect(.degrees(isOpen ? 90 : 0))
          // 只转箭头：整块布局不做动画，否则下面代码块的文字视图跟着插值晃动
          .animation(.easeInOut(duration: 0.2), value: isOpen)
        ParagraphView(contents: summary, lineSpacing: nil)
          .fixedSize(horizontal: false, vertical: true)
          .allowsHitTesting(false)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
      .onTapGesture {
        isOpen.toggle()
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityValue(isOpen ? "已展开" : "已收起")

      if isOpen, !children.isEmpty {
        MintHairline()
        BlockView(renderables: children)
          .padding(.horizontal, 12)
          .padding(.vertical, 12)
      }
    }
    // 与代码块同一套：米白底 + 薄荷发丝描边
    .mintCard()
  }

  /// 标题：棕灰、比正文小一档（保留粗体等字形）
  private static func styledSummary(_ source: NSMutableAttributedString) -> NSMutableAttributedString {
    let s = NSMutableAttributedString(attributedString: source)
    let range = NSRange(location: 0, length: s.length)
    s.addAttribute(.foregroundColor, value: PlatformColor(red: 0x8C / 255, green: 0x7F / 255, blue: 0x74 / 255, alpha: 1), range: range)
    s.enumerateAttribute(.font, in: range) { value, sub, _ in
      guard let font = value as? PlatformFont else { return }
      let smaller: PlatformFont? = PlatformFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.88)
      s.addAttribute(.font, value: smaller ?? font, range: sub)
    }
    return s
  }
}
