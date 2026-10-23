//
//  MP fork: 代码块自定义渲染 hook（MP 的卡片注册表：html → HTMLArtifactCardView、card-* → 聊天卡片）。
//  调用方：MarkdownView/StreamedMarkdownView 外面 .environment(\.customBlockRenderer) { language, code in ... }
//

import SwiftUI

/// MP fork：通用代码块渲染口子。返回 nil = 不认识，走默认渲染。
public struct CustomBlockRendererKey: EnvironmentKey {
  public static let defaultValue: ((_ language: String, _ code: String) -> AnyView?)? = nil
}

public extension EnvironmentValues {
  var customBlockRenderer: ((_ language: String, _ code: String) -> AnyView?)? {
    get { self[CustomBlockRendererKey.self] }
    set { self[CustomBlockRendererKey.self] = newValue }
  }
}

/// MP fork：独立链接段落的渲染口子（与代码块口子分开：正文伪造不了）。返回 nil = 按原段落显示。
public struct StandaloneLinkRendererKey: EnvironmentKey {
  public static let defaultValue: ((_ url: URL, _ label: String?) -> AnyView?)? = nil
}

public extension EnvironmentValues {
  var standaloneLinkRenderer: ((_ url: URL, _ label: String?) -> AnyView?)? {
    get { self[StandaloneLinkRendererKey.self] }
    set { self[StandaloneLinkRendererKey.self] = newValue }
  }
}
