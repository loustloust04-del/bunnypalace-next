//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import HighlightSwift
import SwiftUI

private struct HighlightOutput {
  let code: String
  let text: AttributedString
  /// highlight.js 用上的语言（没标语言时是自动识别的结果）
  let language: String?
}

private actor HighlightTaskManager: ObservableObject {
  /// Shared Highlight instance to avoid creating multiple JSContext/HLJS instances.
  /// Each Highlight() creates its own JSContext and evaluates highlight.min.js (~600KB).
  /// When multiple CodeBlockViews render concurrently, N separate JSContexts cause
  /// JavaScriptCore OOM crashes (COPILOT-IOS-3F9C, 3F7Z, 3FSQ).
  private static let sharedHighlight = Highlight()

  private var latest: (code: String, language: String)?
  private var isProcessing = false

  func enqueueCode(_ code: String, language: String, completion: @escaping (HighlightOutput) -> Void) {
    latest = (code, language)

    if !isProcessing {
      Task {
        await processQueue(completion: completion)
      }
    }
  }

  /// MP fork: 标了语言按语言高亮（认不出的别名退回自动识别）；没标语言自动识别。
  private func highlight(_ code: String, language: String) async -> HighlightResult? {
    let colors = HighlightColors.custom(css: CodeBlockView.syntaxHighlightingCss, background: "")
    let alias = language.trimmingCharacters(in: .whitespaces).lowercased()
    if !alias.isEmpty, let result = try? await Self.sharedHighlight.request(code, mode: .languageAliasIgnoreIllegal(alias), colors: colors) {
      return result
    }
    return try? await Self.sharedHighlight.request(code, mode: .automatic, colors: colors)
  }

  private func processQueue(completion: @escaping (HighlightOutput) -> Void) async {
    guard !isProcessing else { return }

    isProcessing = true

    while let (codeToProcess, language) = latest {
      latest = nil

      if let result = await highlight(codeToProcess, language: language) {
        let detected = result.isUndefined ? nil : result.language
        let highlighted = result.attributedText
        await MainActor.run {
          let highlightedCode = String(highlighted.characters)
          if !highlightedCode.isEmpty, let range = codeToProcess.range(of: highlightedCode) {
            completion(HighlightOutput(
              code: codeToProcess,
              text: AttributedString(String(codeToProcess[..<range.lowerBound]))
                + highlighted
                + AttributedString(String(codeToProcess[range.upperBound...])),
              language: detected))
          } else {
            completion(HighlightOutput(code: codeToProcess, text: AttributedString(codeToProcess), language: detected))
          }
        }
      }
    }

    isProcessing = false
  }
}

struct CodeBlockView: View {

  let language: String
  let code: String
  let onCodeCopied: (() -> Void)?

  @Environment(\.markdownConfig) private var config: MarkdownRenderConfig
  @State var copied: Bool = false
  @State private var highlighted: HighlightOutput?
  @State private var isExpanded = false
  @StateObject private var taskManager: HighlightTaskManager = HighlightTaskManager()

  init(language: String, code: String, onCodeCopied: (() -> Void)? = nil) {
    self.language = language
    self.code = String(code.reversed().drop(while: { $0 == "\n" || $0 == "\r\n" }).reversed())
    self.onCodeCopied = onCodeCopied
  }

  private func updateHighlight(code: String) async {
    await taskManager.enqueueCode(code, language: language) { output in
      self.highlighted = output
    }
  }

  /// 头部标签：标了语言用标的；没标用自动识别出的；都没有写 text。
  private var languageLabel: String {
    let declared = language.trimmingCharacters(in: .whitespaces)
    if !declared.isEmpty { return declared.lowercased() }
    if let detected = highlighted?.language, highlighted?.code == code, !detected.isEmpty { return detected.lowercased() }
    return "text"
  }

  static func contents(code: String, highlighted: AttributedString?, config: MarkdownRenderConfig, wraps: Bool) -> NSMutableAttributedString {
    // Use the native attributes produced by HighlightSwift; the configured font
    // applies to every run, including the whitespace restored around its result.
    let valid = highlighted.flatMap { String($0.characters) == code ? $0 : nil }
    let contents = NSMutableAttributedString(attributedString: NSAttributedString(valid ?? AttributedString(code)))
    let range = NSRange(location: 0, length: contents.length)
    contents.addAttribute(.font, value: config.inlineStyle.codeTextFont, range: range)
    if valid == nil {
      contents.addAttribute(.foregroundColor, value: config.inlineStyle.codeTextColor, range: range)
    } else {
      // MP fork: HighlightSwift 导入时丢了字体，注释的斜体按颜色补回（obliqueness 对任何等宽字体都有效）
      contents.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
        guard let color = value as? PlatformColor, color.mpmdMatches(hex: CodeBlockView.commentColorHex) else { return }
        contents.addAttribute(.obliqueness, value: 0.18, range: sub)
      }
    }
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = wraps ? .byWordWrapping : .byClipping
    contents.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
    return contents
  }

  private var codeContents: NSMutableAttributedString {
    Self.contents(code: code, highlighted: highlighted?.text, config: config, wraps: false)
  }

  var codeblock: some View {
    ScrollView(.horizontal) {
      ParagraphView(contents: codeContents, lineSpacing: nil)
        .fixedSize(horizontal: true, vertical: true)
    }.transaction { transaction in
      // The horizontal scrollView resizing animation was causing the code block to animate
      // all janky.
      transaction.animation = nil
    }
    #if os(macOS)
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    #endif
    .padding(16)
  }

  private func copyCode() {
    copied = true
    PlatformClipboard.copyString(code)
    onCodeCopied?()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 14) {
        Text(languageLabel)
          .font(Font(config.inlineStyle.codeTextFont.withSize(12) as CTFont))
          .foregroundStyle(CodeBlockStyle.label)
        Spacer()
        Button(action: copyCode) {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(CodeBlockStyle.label)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? String.codeCopiedLabel : String.codeCopyLabel)
        Button {
          isExpanded = true
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(CodeBlockStyle.label)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开代码")
      }.frame(maxWidth: .infinity)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
      MintHairline()
      codeblock
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.automatic)
    }
    // MP fork: 米白底（头和体同色，中间一条薄荷线）+ 薄荷绿描边 + 大圆角
    .mintCard()
    .sheet(isPresented: $isExpanded) {
      CodeBlockExpandedView(language: languageLabel, code: code, highlighted: highlighted?.text, onCopy: copyCode)
        .environment(\.markdownConfig, config)
    }
    .onChange(of: copied, perform: { isCopied in
      if isCopied {
        Task {
          try await Task.sleep(seconds: 3)
          copied = false
        }
      }
    })
    .onChange(of: code, perform: { value in
      Task {
        await updateHighlight(code: value)
      }
    })
    .onAppear(perform: {
      Task {
        await updateHighlight(code: code)
      }
    })
  }
}

/// MP fork: 代码块展开页（sheet）——长代码读起来方便；可切换折行，默认不折（横向滚动）。
private struct CodeBlockExpandedView: View {

  let language: String
  let code: String
  let highlighted: AttributedString?
  let onCopy: () -> Void

  @Environment(\.markdownConfig) private var config: MarkdownRenderConfig
  @Environment(\.dismiss) private var dismiss
  @State private var wraps = false
  @State private var copied = false

  var body: some View {
    NavigationStack {
      ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
        ParagraphView(contents: CodeBlockView.contents(code: code, highlighted: highlighted, config: config, wraps: wraps),
                      lineSpacing: nil)
          .fixedSize(horizontal: !wraps, vertical: true)
          .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
          .padding(16)
          .id(wraps)
      }
      .background(CodeBlockStyle.body)
      .navigationTitle(language)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("完成") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
          Button {
            wraps.toggle()
          } label: {
            Image(systemName: wraps ? "arrow.left.and.right.text.vertical" : "text.alignleft")
          }
          .accessibilityLabel(wraps ? "不折行" : "折行")
          Button {
            onCopy()
            copied = true
          } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
          }
          .accessibilityLabel(copied ? String.codeCopiedLabel : String.codeCopyLabel)
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 620)
    #endif
  }
}

public enum CodeBlockStyle {
  public static let cornerRadius: CGFloat = 20
  /// 比原来的奶白 #FFFBF6 更白一档的米白
  public static let body = Color(red: 0xFF / 255, green: 0xFD / 255, blue: 0xF9 / 255)
  /// 薄荷绿描边 / 头体分隔线：同一个半透明色、同一根 1 像素发丝线
  public static let stroke = Color(red: 0x7F / 255, green: 0xB8 / 255, blue: 0x9E / 255).opacity(0.38)
  /// 语言标注和按钮：棕灰
  public static let label = Color(red: 0x8C / 255, green: 0x7F / 255, blue: 0x74 / 255)
}

/// 1 物理像素的薄荷分隔线（与外框同粗）
public struct MintHairline: View {
  @Environment(\.displayScale) private var displayScale

  public init() {}

  public var body: some View {
    Rectangle()
      .fill(CodeBlockStyle.stroke)
      .frame(height: 1 / max(displayScale, 1))
  }
}

public extension View {
  /// 米白卡片：底色 + 裁圆角 + 画在内侧的 1 像素薄荷描边（画在裁剪之后，不会被裁掉半边而比分隔线细）
  func mintCard() -> some View {
    modifier(MintCardModifier())
  }
}

private struct MintCardModifier: ViewModifier {
  @Environment(\.displayScale) private var displayScale

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: CodeBlockStyle.cornerRadius, style: .continuous)
    content
      .background(shape.fill(CodeBlockStyle.body))
      .clipShape(shape)
      .overlay(shape.strokeBorder(CodeBlockStyle.stroke, lineWidth: 1 / max(displayScale, 1)))
  }
}

extension PlatformColor {
  /// sRGB 下与 hex 近似相等（HTML 导入的颜色可能带色彩空间换算误差）
  func mpmdMatches(hex: UInt32) -> Bool {
    #if os(macOS)
    guard let c = usingColorSpace(.sRGB) else { return false }
    let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
    #else
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
    #endif
    let target = [CGFloat((hex >> 16) & 0xFF), CGFloat((hex >> 8) & 0xFF), CGFloat(hex & 0xFF)].map { $0 / 255 }
    return abs(r - target[0]) < 0.02 && abs(g - target[1]) < 0.02 && abs(b - target[2]) < 0.02
  }
}

#if DEBUG

#Preview {
  return LazyVStack {
    Spacer()
    CodeBlockView(language: "Python", code: "import random\n\ndef generate_and_add_numbers(num_numbers):\n    # Generate a list of random numbers random_numbers\n    random_numbers = [random.randint(1, 100) for _ in range(num_numbers)]\n\n\n    # Add the numbers together\n    sum_of_numbers = sum(random_numbers)\n\n    return random_numbers, sum_of_numbers\n\n# Example: Generate 5 random numbers and add them together\nnum_numbers = 5\nrandom_numbers, sum_of_numbers = generate_and_add_numbers(num_numbers)\nprint(f\"Generated numbers: {random_numbers}\")\nprint(f\"Sum of numbers: {sum_of_numbers}\")")
    Spacer()
  }.padding(24)
}

#endif
