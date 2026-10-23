import Foundation
import Markdown

/// MP fork：顶层段落整段是一个 http(s) 链接（research-chat-cards §7.1）
public struct StandaloneLink: Equatable {
  public let url: URL
  /// 链接文字；与网址相同（裸网址 / 自动链接）时为 nil
  public let label: String?
}

public enum StandaloneLinkDetector {

  /// 宿主用：一段 markdown（气泡用户块）整块是不是一个独立链接——与渲染器同一套判断
  public static func detect(markdownBlock: String) -> StandaloneLink? {
    let document = Document(parsing: markdownBlock)
    guard document.childCount == 1, let paragraph = document.child(at: 0) as? Paragraph else { return nil }
    return detect(paragraph, coder: .default)
  }

  static func detect(_ paragraph: Paragraph, coder: CitationCoder) -> StandaloneLink? {
    guard paragraph.parent is Document else { return nil }
    let children = Array(paragraph.children)
    guard children.count == 1 else { return nil }
    let raw: String
    var label: String?
    if let link = children[0] as? Markdown.Link, let destination = link.destination {
      if link.isInlineCitation(coder: coder) { return nil }     // 引用标注：不看 isEnabled
      raw = destination
      let text = link.plainText.trimmingCharacters(in: .whitespaces)
      label = (text.isEmpty || text == destination) ? nil : text
    } else if let text = children[0] as? Markdown.Text {
      raw = text.string.trimmingCharacters(in: .whitespaces)
      // 裸网址只认 ASCII：中文紧跟网址（「https://a.com这个项目」）是正文，不是链接（终审 I1）
      // 包最低 iOS 16：encodingInvalidCharacters 是 iOS 17 起才有；上面已限 ASCII，老接口判断结果一致
      let parsed: URL? = if #available(iOS 17, macOS 14, *) {
        URL(string: raw, encodingInvalidCharacters: false)
      } else {
        URL(string: raw)
      }
      guard !raw.contains(where: { $0.isWhitespace || !$0.isASCII }), parsed != nil else { return nil }
    } else {
      return nil
    }
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
    return StandaloneLink(url: url, label: label)
  }
}
