//
//  MP fork mac: LaTeX 附件载荷。解析层（Markdown+InlineConvertible）两端都要编码它，
//  而两端的段落视图文件各自只在本平台编译（UIKit / AppKit），所以定义放在这个共享文件。
//  iOS 分支内容与原定义逐字相同。
//

import Foundation
import SwiftUI

struct LatexAttachmentData: Codable {
  let latex: String
  let fontSize: CGFloat
  let lightTextColor: String
  let darkTextColor: String
}

extension LatexAttachmentData {
  #if os(iOS)
  var resolvedTextColor: PlatformColor {
    let fallback = PlatformColor(Color.Theme.Foreground.Primary.Primary750)
    guard let lightColor = PlatformColor(hex: lightTextColor),
          let darkColor = PlatformColor(hex: darkTextColor) else {
      return fallback
    }
    return PlatformColor { trait in
      trait.userInterfaceStyle == .dark ? darkColor : lightColor
    }
  }
  #else
  var resolvedTextColor: PlatformColor {
    let fallback = PlatformColor(Color.Theme.Foreground.Primary.Primary750)
    guard let lightColor = PlatformColor(hex: lightTextColor),
          let darkColor = PlatformColor(hex: darkTextColor) else {
      return fallback
    }
    return PlatformColor(name: nil, dynamicProvider: { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
    })
  }
  #endif
}
