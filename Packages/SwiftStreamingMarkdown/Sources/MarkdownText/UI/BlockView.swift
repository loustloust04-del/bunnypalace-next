//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import SwiftUI

struct BlockView: View {

  let renderables: [MarkdownRenderable]
  #if os(macOS)
  // MP fork mac: mac 的排版滑杆经 config 覆盖块距；iOS 不订阅 config，保持上游常量 30
  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  #endif

  init(renderables: [MarkdownRenderable]) {
    self.renderables = renderables
  }

  var body: some View {
    #if os(macOS)
    VStack(alignment: .leading, spacing: config.blockSpacing ?? 30) {
      ForEach(renderables) { renderable in
        SingleBlockView(renderable: renderable)
      }
    }
    #else
    VStack(alignment: .leading, spacing: 30) {
      ForEach(renderables) { renderable in
        SingleBlockView(renderable: renderable)
      }
    }
    #endif
  }
}

struct SingleBlockView: View {

  @Environment(\.markdownConfig) var config: MarkdownRenderConfig
  // MP fork: HTML artifact 自定义渲染 hook（MP 把 ```html block 渲成 HTMLArtifactCardView）
  // MP fork: 通用代码块口子（MP 的卡片注册表）
  @Environment(\.customBlockRenderer) var customBlockRenderer
  @Environment(\.standaloneLinkRenderer) var standaloneLinkRenderer

  let renderable: MarkdownRenderable

  init(renderable: MarkdownRenderable) {
    self.renderable = renderable
  }

  var body: some View {
    Group {
      switch renderable {
      // MP fork patch 5: 段落/标题去掉 HStack+Spacer 包装——Spacer 把块的理想宽度
      // 顶成无限，短文字气泡被撑满全宽（外层 VStack(alignment:.leading) 已保证左对齐，
      // 长段落换行不受影响）
      case .heading(_, _, let contents):
        ParagraphView(contents: contents)
          .transition(.opacity)
          .accessibilityAddTraits(.isHeader)
      case .paragraph(_, let contents):
        #if os(macOS)
        // MP fork mac: mac 的排版滑杆经 config 覆盖段落行距；iOS 保持上游常量 5
        ParagraphView(contents: contents, lineSpacing: config.paragraphLineSpacing ?? 5)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity)
        #else
        ParagraphView(contents: contents, lineSpacing: 5)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity)
        #endif
      case .latex(_, let latexString):
        ScrollView(.horizontal) {
          HStack(spacing: 0) {
            BlockMathView(latex: latexString, color: Color(config.paragraphStyle.textColor))
            Spacer()
          }
        }.scrollIndicators(.hidden)
        #if os(macOS)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
      case .orderedList(_, let items):
        OrderedListView(items: items)
      case .unorderedList(_, let items, let nestedLevel):
        UnorderedListView(items: items, nestedLevel: nestedLevel)
      case .codeBlock(_, let language, let code):
        let custom = customBlockRenderer?(language ?? "", code)
        switch BlockView.route(hasCustom: custom != nil) {
        case .custom: custom!
        case .standard: CodeBlockView(language: language ?? "", code: code)
        }
      case .thematicBreak:
        ThematicBreakView()
      case .table(_, let headers, let rows, let rawMarkdown):
        TableView(headings: headers,
                  rows: rows,
                  rawMarkdown: rawMarkdown)
      case .blockQuote(_, let item):
        BlockQuoteView(item: item)
      case .standaloneLink(_, let url, let label, let contents):
        if let card = standaloneLinkRenderer?(url, label) {
          card
        } else {
          #if os(macOS)
          ParagraphView(contents: contents, lineSpacing: config.paragraphLineSpacing ?? 5)
            .fixedSize(horizontal: false, vertical: true)
          #else
          ParagraphView(contents: contents, lineSpacing: 5)
            .fixedSize(horizontal: false, vertical: true)
          #endif
        }
      case .details(_, let summary, let isOpen, let children):
        DetailsBlockView(summary: summary, initiallyOpen: isOpen, children: children)
      case .textRun(_, let contents):
        // MP fork: 段落簇（段间距 / 行距已写进各段落样式，视图不再套行距）
        ParagraphView(contents: contents, lineSpacing: nil)
          .fixedSize(horizontal: false, vertical: true)
          .transition(.opacity)
      }
    }
  }
}

enum CodeBlockRoute: Equatable { case custom, standard }

extension BlockView {
  /// 宿主（MP 卡片注册表，含 html）返回了视图 → custom；否则默认代码块
  static func route(hasCustom: Bool) -> CodeBlockRoute {
    hasCustom ? .custom : .standard
  }
}
