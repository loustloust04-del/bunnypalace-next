//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI

struct BlockQuoteView: View {
  let item: BlockQuoteType

  init(item: BlockQuoteRenderable) {
    self.item = item.quoteType
  }

  // MP fork: 顶层 wrapper 画唯一一条竖线（避免内层 nested 复画两条）
  var body: some View {
    HStack(spacing: 8.0) {
      QuoteDivider()
        .frame(width: 3.0)
      InternalBlockQuoteView(item: item)
        .padding(.leading, 4.0)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct InternalBlockQuoteView: View {
  let item: BlockQuoteType

  var body: some View {
    // MP fork: 内层不画竖线（顶层 BlockQuoteView 已画唯一一条），避免嵌套复画
    VStack(spacing: 12.0) {
      switch item {
      case .text(let text):
        HStack {
          QuoteTextView(text: text)
          Spacer()
        }
        .fixedSize(horizontal: false, vertical: true)
      case .nested(let subItems):
        ForEach(subItems.indices, id: \.self) { index in
          InternalBlockQuoteView(item: subItems[index])
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 4.0)
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct QuoteTextView: View {
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig

  let text: String

  var body: some View {
    Text(text)
      .font(config.blockQuoteStyle.textFonts)
      .foregroundStyle(Color(config.blockQuoteStyle.textColor))
      .padding(.vertical, 4.0)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct QuoteDivider: View {
  var body: some View {
    // MP fork: 浅薄荷绿 branchIndicator #8EBD9F @ 0.6（不再用库内置 stroke 灰）
    RoundedRectangle(cornerRadius: 8.0, style: .continuous)
      .foregroundStyle(Color(red: 142.0/255.0, green: 189.0/255.0, blue: 159.0/255.0, opacity: 0.6))
  }
}

indirect enum BlockQuoteType: Equatable, Hashable {
  case text(String)
  case nested([BlockQuoteType])

  var isNested: Bool {
    switch self {
    case .text:
      false
    case .nested:
      true
    }
  }
}
