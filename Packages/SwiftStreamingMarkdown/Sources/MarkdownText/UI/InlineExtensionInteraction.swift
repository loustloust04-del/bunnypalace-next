//
//  MP fork: 剧透 / 缩写的点击交互（iOS 与 mac 的段落视图共用）。
//  剧透是一段带内部链接的遮罩（字色透明 + 灰底），点了把原字色放回、摘掉遮罩和链接。
//  揭开状态只活在当前视图里（流式追加内容时保留，换成别的段落就清掉），不写回数据。
//

import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct SpoilerRevealState {

  private var revealed: Set<URL> = []
  private var contentString = ""

  /// 内容换了：流式追加（新内容以旧内容开头）保留揭开状态，否则清空。
  mutating func contentDidChange(to string: String) {
    if !string.hasPrefix(contentString) { revealed.removeAll() }
    contentString = string
  }

  /// 点了一个剧透链接：揭开并记住。返回被揭开的范围。
  mutating func reveal(_ url: URL, in storage: NSTextStorage) -> NSRange? {
    revealed.insert(url)
    return Self.reveal(url, in: storage)
  }

  /// 还藏着的剧透：一个 ||…|| 一组（按它的内部链接归组），带字本来的颜色（粒子用）
  static func hiddenSpoilers(in storage: NSAttributedString) -> [(url: URL, range: NSRange, color: PlatformColor)] {
    var result: [(url: URL, range: NSRange, color: PlatformColor)] = []
    storage.enumerateAttribute(.mpmdSpoiler, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      guard let color = value as? PlatformColor else { return }
      let link = storage.attribute(.link, at: range.location, effectiveRange: nil)
      guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return }
      if let i = result.firstIndex(where: { $0.url == url }) {
        result[i].range = NSUnionRange(result[i].range, range)
      } else {
        result.append((url, range, color))
      }
    }
    return result
  }

  /// 内容重灌之后把已揭开的重新揭开。
  func reapply(in storage: NSTextStorage) {
    for url in revealed { _ = Self.reveal(url, in: storage) }
  }

  private static func reveal(_ url: URL, in storage: NSTextStorage) -> NSRange? {
    var target: NSRange?
    storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
      let linked = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
      guard linked == url else { return }
      target = target.map { NSUnionRange($0, range) } ?? range
    }
    guard let target else { return nil }
    storage.beginEditing()
    storage.enumerateAttribute(.mpmdSpoiler, in: target) { value, sub, _ in
      if let value { storage.addAttribute(.foregroundColor, value: value, range: sub) }
    }
    storage.removeAttribute(.backgroundColor, range: target)
    storage.removeAttribute(.link, range: target)
    storage.removeAttribute(.mpmdSpoiler, range: target)
    storage.endEditing()
    return target
  }
}

#if canImport(UIKit)

/// 缩写释义：在点中的位置弹一个只有一项（释义本身）的系统编辑菜单。
final class AbbreviationMenuPresenter: NSObject, UIEditMenuInteractionDelegate {

  private var title = ""
  private weak var host: UIView?
  private lazy var interaction = UIEditMenuInteraction(delegate: self)

  func present(title: String, at point: CGPoint, in view: UIView) {
    if host !== view {
      host?.removeInteraction(interaction)
      view.addInteraction(interaction)
      host = view
    }
    self.title = title
    interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
  }

  func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                           menuFor configuration: UIEditMenuConfiguration,
                           suggestedActions: [UIMenuElement]) -> UIMenu? {
    UIMenu(children: [UIAction(title: title) { _ in }])
  }
}

#elseif canImport(AppKit)

/// 缩写释义（mac）：悬停有 toolTip；点击弹一个小气泡。
enum AbbreviationPopover {

  static func show(title: String, relativeTo rect: NSRect, of view: NSView) {
    let label = NSTextField(wrappingLabelWithString: title)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.preferredMaxLayoutWidth = 280
    let size = label.fittingSize
    label.frame = NSRect(x: 10, y: 8, width: size.width, height: size.height)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 20, height: size.height + 16))
    container.addSubview(label)
    let controller = NSViewController()
    controller.view = container
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = controller
    popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
  }
}

#endif
