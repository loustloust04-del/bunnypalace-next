// MP fork mac-port L1: 测试 target 是 UIKit 快照测试，整文件 iOS 留门（mac 侧为空，iOS 原样跑）。
#if os(iOS)

//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI
@testable import SwiftStreamingMarkdown

/// A Canvas view for convenience of SwiftUI previews or snapshot tests.
/// It disables all animation by default.
public struct CanvasView<Content: View>: View {

  public let content: (() -> Content)

  public init(content: @escaping () -> Content) {
    self.content = content
  }

  public var body: some View {
    VStack {
      content()
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.Theme.Background.Page.Chat.Flat)
    .transaction { tr in tr.animation = nil }
  }
}

#endif  // os(iOS)
