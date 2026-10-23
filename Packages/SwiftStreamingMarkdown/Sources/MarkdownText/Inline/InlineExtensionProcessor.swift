//
//  MP fork: 段落富文本上的行内扩展（解析、排好粗斜体之后跑，所以能跨节点）。
//  - HTML 行内标签：cmark 把 `<mark>x</mark>` 拆成 InlineHTML / Text / InlineHTML 三个兄弟节点，
//    InlineHTML 先转成带 `.mpmdHTMLTag` 的占位字符，这里配对、上样式、删占位。
//    支持 mark / sub / sup / small / u / ins / del / s / strike / b / strong / i / em / kbd / abbr；
//    其他标签只删不渲（与原先吞标签的行为一致）。未闭合的开标签作用到段尾（流式中途也有效果）。
//  - `==高亮==`、`||剧透||`、`{漂亮|piào liang}` 注音：在拼好的字符串上找，跳过行内代码。
//

import CoreText
import Foundation
import Markdown

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension NSAttributedString.Key {
  /// InlineHTML 占位字符上的原始标签文本
  static let mpmdHTMLTag = NSAttributedString.Key("mpmd.htmlTag")
  /// 行内代码（扩展语法不在里面匹配）
  static let mpmdCode = NSAttributedString.Key("mpmd.code")
  /// 剧透片段：值 = 揭开后的前景色
  static let mpmdSpoiler = NSAttributedString.Key("mpmd.spoiler")
  /// 段落里有注音（排版时要留出行高）
  static let mpmdRuby = NSAttributedString.Key("mpmd.ruby")
}

enum InlineExtensionURL {
  static let spoilerScheme = "mpmd-spoiler"
  static let abbreviationScheme = "mpmd-abbr"

  static func spoiler(index: Int) -> URL {
    URL(string: "\(spoilerScheme)://reveal/\(index)")!
  }

  static func abbreviation(title: String) -> URL? {
    var components = URLComponents()
    components.scheme = abbreviationScheme
    components.host = "show"
    components.queryItems = [URLQueryItem(name: "t", value: title)]
    return components.url
  }

  static func abbreviationTitle(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value
  }

  static func isInternal(_ url: URL) -> Bool {
    url.scheme == spoilerScheme || url.scheme == abbreviationScheme
  }
}

extension Markdown.InlineHTML: InlineConvertible {

  static let sentinel = "\u{E000}"

  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> NSMutableAttributedString {
    let raw = rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return NSMutableAttributedString(string: "\n").mergingAttributes(attributeContainer)
    }
    var container = attributeContainer
    container[.mpmdHTMLTag] = raw
    return NSMutableAttributedString(string: Self.sentinel).mergingAttributes(container)
  }
}

enum InlineExtensionProcessor {

  static func process(_ s: NSMutableAttributedString, config: MarkdownRenderConfig) {
    guard s.length > 0 else { return }
    applyHTMLTags(s, config: config)
    // 彩色文字先上（E24）：里面的剧透揭开后是这个颜色
    if s.string.range(of: "{color:", options: .caseInsensitive) != nil { applyColor(s) }
    let string = s.string
    if string.contains("==") { applyDelimited(s, pattern: highlightPattern) { applyHighlight(s, range: $0) } }
    if string.contains("||") {
      var index = 0
      applyDelimited(s, pattern: spoilerPattern) { range in
        applySpoiler(s, range: range, index: index, config: config)
        index += 1
      }
    }
    if string.contains("{"), string.contains("|") { applyRuby(s) }
  }

  // MARK: - HTML 标签

  private static let tagPattern = try! NSRegularExpression(pattern: #"^<\s*(/)?\s*([A-Za-z][A-Za-z0-9]*)([^>]*?)/?\s*>$"#)
  private static let titleAttribute = try! NSRegularExpression(pattern: #"title\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])

  private struct TagSpan {
    let name: String
    let attributes: String
    let range: NSRange
  }

  private static func applyHTMLTags(_ s: NSMutableAttributedString, config: MarkdownRenderConfig) {
    var sentinels: [(location: Int, raw: String)] = []
    s.enumerateAttribute(.mpmdHTMLTag, in: NSRange(location: 0, length: s.length)) { value, range, _ in
      guard let raw = value as? String else { return }
      // 相邻的两个标签可能合成一个属性段：逐个占位字符记
      for offset in 0..<range.length { sentinels.append((range.location + offset, raw)) }
    }
    guard !sentinels.isEmpty else { return }
    var stack: [(name: String, attributes: String, location: Int)] = []
    var spans: [TagSpan] = []
    for sentinel in sentinels {
      guard let m = tagPattern.firstMatch(in: sentinel.raw, range: sentinel.raw.nsRange) else { continue }
      let ns = sentinel.raw as NSString
      let isClosing = m.range(at: 1).location != NSNotFound
      let name = ns.substring(with: m.range(at: 2)).lowercased()
      let attributes = ns.substring(with: m.range(at: 3))
      if isClosing {
        guard let openIndex = stack.lastIndex(where: { $0.name == name }) else { continue }
        let open = stack[openIndex]
        stack.removeSubrange(openIndex...)
        spans.append(TagSpan(name: name, attributes: open.attributes,
                             range: NSRange(location: open.location + 1, length: sentinel.location - open.location - 1)))
      } else if !sentinel.raw.hasSuffix("/>") {
        stack.append((name, attributes, sentinel.location))
      }
    }
    for open in stack {
      spans.append(TagSpan(name: open.name, attributes: open.attributes,
                           range: NSRange(location: open.location + 1, length: s.length - open.location - 1)))
    }
    // 外层先上，内层后上（内层字号在外层基础上再缩）
    for span in spans.sorted(by: { $0.range.length > $1.range.length }) where span.range.length > 0 {
      applyTag(span, to: s, config: config)
    }
    for sentinel in sentinels.reversed() {
      s.deleteCharacters(in: NSRange(location: sentinel.location, length: 1))
    }
  }

  private static func applyTag(_ span: TagSpan, to s: NSMutableAttributedString, config: MarkdownRenderConfig) {
    let range = span.range
    switch span.name {
    case "mark":
      applyHighlight(s, range: range)
    case "sup":
      scaleFont(s, range: range, factor: 0.72, baseline: { $0.pointSize * 0.38 })
    case "sub":
      scaleFont(s, range: range, factor: 0.72, baseline: { -$0.pointSize * 0.12 })
    case "small":
      scaleFont(s, range: range, factor: 0.86)
      s.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
        let color = (value as? PlatformColor) ?? config.paragraphStyle.textColor
        s.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.62), range: sub)
      }
    case "u", "ins":
      s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    case "del", "s", "strike":
      s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    case "b", "strong":
      transformFont(s, range: range) { font, fonts in fonts?.bold(font: font) ?? font }
    case "i", "em":
      transformFont(s, range: range) { font, fonts in fonts?.italicize(font: font) ?? font }
    case "kbd":
      s.addAttributes([
        .font: config.inlineStyle.codeTextFont,
        .backgroundColor: config.inlineStyle.codeBackgroundColor,
        .mpmdCode: true
      ], range: range)
    case "abbr":
      applyAbbreviation(s, range: range, attributes: span.attributes, config: config)
    default:
      break
    }
  }

  private static func applyAbbreviation(_ s: NSMutableAttributedString, range: NSRange, attributes: String, config: MarkdownRenderConfig) {
    guard let m = titleAttribute.firstMatch(in: attributes, range: attributes.nsRange) else { return }
    let ns = attributes as NSString
    let group = m.range(at: 1).location != NSNotFound ? 1 : 2
    let title = decodeEntities(ns.substring(with: m.range(at: group)))
    guard !title.isEmpty else { return }
    var attrs: [NSAttributedString.Key: Any] = [
      .underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue,
      .underlineColor: config.paragraphStyle.textColor.withAlphaComponent(0.5)
    ]
    if let url = InlineExtensionURL.abbreviation(title: title) { attrs[.link] = url }
    #if os(macOS)
    attrs[.toolTip] = title
    #endif
    s.addAttributes(attrs, range: range)
  }

  private static func decodeEntities(_ s: String) -> String {
    s.replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  // MARK: - 定界符语法

  private static let highlightPattern = try! NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#)
  private static let spoilerPattern = try! NSRegularExpression(pattern: #"\|\|(?=\S)(.+?)(?<=\S)\|\|"#)
  private static let colorPattern = try! NSRegularExpression(
    pattern: #"\{color:\s*(#[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{3}|[A-Za-z]+)\s*\}(.+?)\{/color\}"#, options: [.caseInsensitive])
  private static let rubyPattern = try! NSRegularExpression(pattern: #"\{([^{}|\n]+)\|([^{}|\n]+)\}"#)

  /// 找 `pattern`（第 1 组是正文）→ 从后往前：上样式、删两端定界符。定界符落在行内代码里的跳过。
  private static func applyDelimited(_ s: NSMutableAttributedString, pattern: NSRegularExpression, apply: (NSRange) -> Void) {
    let matches = pattern.matches(in: s.string, range: NSRange(location: 0, length: s.length))
    guard !matches.isEmpty else { return }
    let valid = matches.filter { !touchesCode(s, $0.range) }
    // 正向编号（剧透 index 稳定）→ 逆向删字
    var styled: [(inner: NSRange, whole: NSRange)] = []
    for m in valid {
      apply(m.range(at: 1))
      styled.append((m.range(at: 1), m.range))
    }
    for item in styled.reversed() {
      s.deleteCharacters(in: NSRange(location: NSMaxRange(item.inner), length: NSMaxRange(item.whole) - NSMaxRange(item.inner)))
      s.deleteCharacters(in: NSRange(location: item.whole.location, length: item.inner.location - item.whole.location))
    }
  }

  private static func touchesCode(_ s: NSAttributedString, _ range: NSRange) -> Bool {
    var found = false
    s.enumerateAttribute(.mpmdCode, in: range) { value, _, stop in
      if value != nil { found = true; stop.pointee = true }
    }
    return found
  }

  private static func applyHighlight(_ s: NSMutableAttributedString, range: NSRange) {
    s.addAttribute(.backgroundColor, value: InlineExtensionStyle.highlightBackground, range: range)
  }

  private static func applySpoiler(_ s: NSMutableAttributedString, range: NSRange, index: Int, config: MarkdownRenderConfig) {
    s.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
      s.addAttribute(.mpmdSpoiler, value: (value as? PlatformColor) ?? config.paragraphStyle.textColor, range: sub)
    }
    // 不再铺灰块：字透明，上面盖粒子（SpoilerDust，§12）
    s.addAttributes([
      .foregroundColor: PlatformColor.clear,
      .link: InlineExtensionURL.spoiler(index: index)
    ], range: range)
  }

  /// `{color:red}红色{/color}` / `{color:#3366CC}…{/color}`：上字色、删两端标记；不认识的颜色原样留着（E24）
  private static func applyColor(_ s: NSMutableAttributedString) {
    let matches = colorPattern.matches(in: s.string, range: NSRange(location: 0, length: s.length))
      .filter { !touchesCode(s, $0.range) }
    let ns = s.string as NSString
    for m in matches.reversed() {
      guard let color = InlineExtensionStyle.color(named: ns.substring(with: m.range(at: 1))) else { continue }
      let inner = m.range(at: 2)
      s.addAttribute(.foregroundColor, value: color, range: inner)
      s.deleteCharacters(in: NSRange(location: NSMaxRange(inner), length: NSMaxRange(m.range) - NSMaxRange(inner)))
      s.deleteCharacters(in: NSRange(location: m.range.location, length: inner.location - m.range.location))
    }
  }

  private static func applyRuby(_ s: NSMutableAttributedString) {
    let matches = rubyPattern.matches(in: s.string, range: NSRange(location: 0, length: s.length))
      .filter { !touchesCode(s, $0.range) }
    guard !matches.isEmpty else { return }
    let ns = s.string as NSString
    for m in matches.reversed() {
      let base = m.range(at: 1)
      let annotation = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
      guard !annotation.isEmpty, !ns.substring(with: base).trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      let ruby = CTRubyAnnotationCreateWithAttributes(
        .center, .auto, .before, annotation as CFString,
        [kCTRubyAnnotationSizeFactorAttributeName: 0.5] as CFDictionary)
      s.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String), value: ruby, range: base)
      // 删 `|注音}` 和 `{`
      s.deleteCharacters(in: NSRange(location: NSMaxRange(base), length: NSMaxRange(m.range) - NSMaxRange(base)))
      s.deleteCharacters(in: NSRange(location: m.range.location, length: 1))
    }
    s.addAttribute(.mpmdRuby, value: true, range: NSRange(location: 0, length: s.length))
    // 注音画在行框上方：给整段留出行高，否则顶行被裁、其余行压到上一行
    let font = (s.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont) ?? PlatformFont.systemFont(ofSize: 17)
    let style = (s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
      ?? NSMutableParagraphStyle()
    style.minimumLineHeight = InlineExtensionStyle.rubyLineHeight(for: font)
    s.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: s.length))
  }

  // MARK: - 字体

  private static func scaleFont(_ s: NSMutableAttributedString, range: NSRange, factor: CGFloat, baseline: ((PlatformFont) -> CGFloat)? = nil) {
    s.enumerateAttribute(.font, in: range) { value, sub, _ in
      guard let font = value as? PlatformFont else { return }
      if let baseline { s.addAttribute(.baselineOffset, value: baseline(font), range: sub) }
      let resized: PlatformFont? = PlatformFont(descriptor: font.fontDescriptor, size: font.pointSize * factor)
      s.addAttribute(.font, value: resized ?? font, range: sub)
    }
  }

  private static func transformFont(_ s: NSMutableAttributedString, range: NSRange, _ transform: (PlatformFont, TextFonts?) -> PlatformFont) {
    s.enumerateAttributes(in: range) { attrs, sub, _ in
      guard let font = attrs[.font] as? PlatformFont else { return }
      s.addAttribute(.font, value: transform(font, attrs[.typography] as? TextFonts), range: sub)
    }
  }
}

enum InlineExtensionStyle {

  static let highlightBackground: PlatformColor = .mpmdDynamic(light: 0xFFE9A8, lightAlpha: 0.85, dark: 0x8A6D1F, darkAlpha: 0.6)

  /// 彩色文字的具名色：亮 / 暗各一档，两种底色上都看得清（E24）
  private static let palette: [String: PlatformColor] = [
    "red": .mpmdDynamic(light: 0xD93D42, lightAlpha: 1, dark: 0xFF6B6F, darkAlpha: 1),
    "orange": .mpmdDynamic(light: 0xD9651A, lightAlpha: 1, dark: 0xFF9A4D, darkAlpha: 1),
    "yellow": .mpmdDynamic(light: 0xB58900, lightAlpha: 1, dark: 0xF5CD47, darkAlpha: 1),
    "green": .mpmdDynamic(light: 0x2E8B57, lightAlpha: 1, dark: 0x5FD08F, darkAlpha: 1),
    "mint": .mpmdDynamic(light: 0x4F9A7C, lightAlpha: 1, dark: 0x8ED1B2, darkAlpha: 1),
    "blue": .mpmdDynamic(light: 0x2F6FD6, lightAlpha: 1, dark: 0x6FA8FF, darkAlpha: 1),
    "purple": .mpmdDynamic(light: 0x8047C4, lightAlpha: 1, dark: 0xB88CF0, darkAlpha: 1),
    "pink": .mpmdDynamic(light: 0xCC4190, lightAlpha: 1, dark: 0xF77FC0, darkAlpha: 1),
    "gray": .mpmdDynamic(light: 0x7C7F87, lightAlpha: 1, dark: 0xA9ADB5, darkAlpha: 1),
  ]
  private static let aliases = ["grey": "gray", "violet": "purple"]

  static func namedColor(_ name: String) -> PlatformColor? {
    let key = name.lowercased()
    return palette[aliases[key] ?? key]
  }

  /// 具名色或 `#RGB` / `#RRGGBB`；不认识 → nil
  static func color(named raw: String) -> PlatformColor? {
    guard raw.hasPrefix("#") else { return namedColor(raw) }
    var hex = String(raw.dropFirst())
    if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return PlatformColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                         blue: CGFloat(v & 0xFF) / 255, alpha: 1)
  }

  /// 测试用：颜色的 0...255 RGB
  static func hexComponents(_ color: PlatformColor) -> [Int] {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    #if canImport(UIKit)
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    #else
    (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
    #endif
    return [r, g, b].map { Int(($0 * 255).rounded()) }
  }

  static func rubyLineHeight(for font: PlatformFont) -> CGFloat {
    ceil((font.ascender - font.descender + font.leading) * 1.55)
  }
}

extension PlatformColor {

  static func mpmdDynamic(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> PlatformColor {
    func make(_ hex: UInt32, _ alpha: CGFloat) -> PlatformColor {
      PlatformColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    #if canImport(UIKit)
    return UIColor { $0.userInterfaceStyle == .dark ? make(dark, darkAlpha) : make(light, lightAlpha) }
    #else
    return NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(dark, darkAlpha) : make(light, lightAlpha)
    }
    #endif
  }
}
