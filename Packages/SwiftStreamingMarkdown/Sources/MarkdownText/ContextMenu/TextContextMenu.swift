//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Configuration for the edit menu that appears on text selection.
public struct TextContextMenu: Hashable, Sendable {
  /// Ordered groups that compose the custom portion of the menu.
  public let menuGroups: [TextContextMenuGroup]

  /// Create a menu definition from the supplied groups.
  public init(menuGroups: [TextContextMenuGroup]) {
    self.menuGroups = menuGroups
  }

  // UIMenu / UIAction 只有 UIKit 有，buildUIMenu 只在 iOS 编译；AppKit 的右键菜单由下方 buildNSMenu 生成。
  #if os(iOS)
  /// Build the `UIMenu` to present on text selection by merging the standard
  /// system edit actions with the configured custom groups. Used by
  /// `MarkdownViewController` and is rarely called directly by consumers.
  /// - Parameters:
  ///   - textView: The `UITextView` requesting the menu.
  ///   - selectedRange: Current selection range, clamped to the text length.
  ///   - suggestedActions: System-suggested actions from UIKit.
  ///   - markdownController: Optional controller used to forward item taps.
  /// - Returns: The composed `UIMenu` to display.
  public func buildUIMenu(textView: UITextView, selectedRange: NSRange, suggestedActions: [UIMenuElement], markdownController: MarkdownController?) -> UIMenu {
    var customMenu: [UIMenu] = []

    let clampedRange = NSIntersectionRange(selectedRange, NSRange(location: 0, length: textView.attributedText.length))
    let selectedText = textView.attributedText.attributedSubstring(from: clampedRange).string
    for group in menuGroups {
      var groupActions: [UIAction] = []
      for item in group.items {
        let uiAction = UIAction(
          title: item.title,
          subtitle: item.subtitle,
          image: item.image?.withRenderingMode(.alwaysTemplate),
        ) { _ in
          markdownController?.onContextMenuTap(id: item.id, selectedContent: selectedText)
        }
        groupActions.append(uiAction)
      }
      let submenu = UIMenu(
        title: group.title ?? "",
        image: group.image?.withRenderingMode(.alwaysTemplate),
        options: group.displayInline ? .displayInline : [],
        children: groupActions
      )
      customMenu.append(submenu)
    }

    // Combine: system suggested actions first, then custom actions
    let filteredSuggestedActions = suggestedActions.filter { menuItem in
      if let menuItem = menuItem as? UIMenu {
        return menuItem.identifier == .standardEdit
      }
      return false
    }
    return UIMenu(children: filteredSuggestedActions + customMenu)
  }
  #endif

  #if os(macOS)
  /// mac 对等于 `buildUIMenu`：用同一份 `menuGroups` 生成自定义那一截菜单（`displayInline == false`
  /// 的组变子菜单，末尾一条分隔线）。`ParagraphNSView.menu(for:)` 把这些项插到系统右键菜单**顶部**，
  /// 系统项原样留在下面。点击经 `markdownController.onContextMenuTap(id:selectedContent:)` 上报。
  /// - Parameters:
  ///   - textView: The `NSTextView` requesting the menu.
  ///   - selectedRange: Current selection range, clamped to the text length.
  ///   - markdownController: Optional controller used to forward item taps.
  /// - Returns: A menu holding only the custom items (merged into the system menu by the caller).
  public func buildNSMenu(textView: NSTextView, selectedRange: NSRange, markdownController: MarkdownController?) -> NSMenu {
    let menu = NSMenu()

    let text = textView.attributedString()
    let clampedRange = NSIntersectionRange(selectedRange, NSRange(location: 0, length: text.length))
    let selectedText = text.attributedSubstring(from: clampedRange).string
    for group in menuGroups {
      var groupItems: [NSMenuItem] = []
      for item in group.items {
        let menuItem = TextContextMenuActionItem(title: item.title) { [weak textView] in
          markdownController?.onContextMenuTap(id: item.id, selectedContent: selectedText)
          // 菜单开着期间文本可能变短（换消息 / 重渲染），按当前长度再夹一次，越界 setSelectedRange 会抛 NSRangeException
          if let textView {
            let end = min(NSMaxRange(clampedRange), (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: end, length: 0))
          }
        }
        menuItem.subtitle = item.subtitle
        menuItem.image = item.image.map(Self.templateImage(_:))
        groupItems.append(menuItem)
      }
      if group.displayInline {
        groupItems.forEach(menu.addItem(_:))
      } else {
        let submenu = NSMenu(title: group.title ?? "")
        groupItems.forEach(submenu.addItem(_:))
        let submenuItem = NSMenuItem(title: group.title ?? "", action: nil, keyEquivalent: "")
        submenuItem.image = group.image.map(Self.templateImage(_:))
        submenuItem.submenu = submenu
        menu.addItem(submenuItem)
      }
    }
    if !menu.items.isEmpty {
      menu.addItem(.separator())
    }
    return menu
  }

  /// iOS `withRenderingMode(.alwaysTemplate)` 的 mac 对等：复制一份再标 template（不改调用方的图）。
  private static func templateImage(_ image: NSImage) -> NSImage {
    let template = (image.copy() as? NSImage) ?? image
    template.isTemplate = true
    return template
  }
  #endif
}

#if os(macOS)
/// 闭包驱动的 `NSMenuItem`（target 指向自己；菜单持有 item，item 持有闭包）。
final class TextContextMenuActionItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(performHandler(_:)), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func performHandler(_ sender: Any?) {
    handler()
  }
}
#endif
