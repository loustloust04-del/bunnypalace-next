//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI

extension CodeBlock: BlockConvertible {
  func convert(attributeContainer: NSAttributeContainer, config: MarkdownRenderConfig) -> MarkdownRenderable {
    if self.language == LaTexPreProcessorImpl.customCodeType {
      return .latex(id: self.id, content: self.code)
    } else if self.language == MarkdownExtensionPreprocessor.detailsLanguage {
      // MP fork: <details> 折叠块——标题按行内 markdown 排，正文走完整管线递归解析
      let details = MarkdownExtensionPreprocessor.decodeDetails(self.code)
      let summaryText = details.summary.isEmpty ? "详情" : details.summary
      let summary: NSMutableAttributedString
      if case .paragraph(_, let content)? = MarkdownParserImpl.renderables(for: summaryText, config: config).first {
        summary = content
      } else {
        summary = NSMutableAttributedString(string: summaryText, attributes: [
          .font: config.paragraphStyle.textFonts.normal,
          .foregroundColor: config.paragraphStyle.textColor
        ])
      }
      return .details(id: self.id, summary: summary, isOpen: details.isOpen,
                      children: MarkdownParserImpl.renderables(for: details.body, config: config))
    } else {
      return .codeBlock(id: self.id, language: self.language, code: self.code)
    }
  }
}
