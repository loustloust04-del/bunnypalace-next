//
//  MP fork mac: 平台类型层。iOS = UIKit 对应物，macOS = AppKit 对应物。
//  app 侧（MemoryPalace）也按这些符号名编译，改名要两边一起改。
//

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(UIKit)
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformImage = UIImage
public typealias PlatformEdgeInsets = UIEdgeInsets
public typealias PlatformView = UIView
#else
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformImage = NSImage
public typealias PlatformEdgeInsets = NSEdgeInsets
public typealias PlatformView = NSView
#endif

extension PlatformColor {
  /// 浅色外观下解析后的 hex 串（供 `LatexAttachmentData.lightTextColor`）。
  /// iOS 分支 = 原 `resolvedColor(with: UITraitCollection(userInterfaceStyle:))` 表达式原样（iOS 取色结果不变）。
  public func resolvedHexForLightAppearance() -> String {
    #if canImport(UIKit)
    return resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).toHexString()
    #else
    return resolvedHexString(appearance: NSAppearance(named: .aqua))
    #endif
  }

  /// 深色外观下解析后的 hex 串（供 `LatexAttachmentData.darkTextColor`）。
  public func resolvedHexForDarkAppearance() -> String {
    #if canImport(UIKit)
    return resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).toHexString()
    #else
    return resolvedHexString(appearance: NSAppearance(named: .darkAqua))
    #endif
  }

  #if !canImport(UIKit)
  private func resolvedHexString(appearance: NSAppearance?) -> String {
    var result = toHexString()
    appearance?.performAsCurrentDrawingAppearance {
      result = (usingColorSpace(.sRGB) ?? self).toHexString()
    }
    return result
  }
  #endif
}

/// 字号缩放。iOS = `UIFontMetrics` 动态字号（原表达式）；mac 无动态字号 = 恒等。
public enum PlatformFontMetrics {
  public static func scaledValue(for size: CGFloat) -> CGFloat {
    #if canImport(UIKit)
    return UIFontMetrics.default.scaledValue(for: size)
    #else
    return size
    #endif
  }
}

/// 剪贴板写字符串。iOS = `UIPasteboard.general.string =`（原表达式）；
/// mac = `NSPasteboard.general` clearContents + setString。
public enum PlatformClipboard {
  public static func copyString(_ string: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = string
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    #endif
  }
}

#if !canImport(UIKit)
extension PlatformFont {
  /// mac 补 `UIFont.lineHeight` 同名语义（`NSFont` 无此属性）。
  public var lineHeight: CGFloat {
    ascender - descender + leading
  }
}
#endif
