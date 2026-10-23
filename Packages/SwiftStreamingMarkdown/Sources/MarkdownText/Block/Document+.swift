//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation
import Markdown
import SwiftUI

extension Markdown.Document {

  func convert(with config: MarkdownRenderConfig) -> [MarkdownRenderable] {
    let blocks = self
      .blockConvertibleChildren
      .map { $0.convert(attributeContainer: NSAttributeContainer(), config: config) }
    // MP fork: 段落簇合并（顶层与 <details> 正文都走这里：details 正文也是一个 Document）
    return config.mergesTextRuns ? TextRunMerger.merge(blocks, config: config) : blocks
  }
}
