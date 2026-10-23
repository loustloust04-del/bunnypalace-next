//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Foundation

extension CodeBlockView {

  // MP fork: 浅色高亮（One Light 系），配 #F9FAFB 代码底色。
  // 关键字紫、字符串绿、注释灰（渲染时再加斜体，见 `commentColorHex`）、数字橙、函数 / 标题蓝、类型 / 内建棕黄。
  static let commentColorHex: UInt32 = 0xA0A1A7

  static let syntaxHighlightingCss = """
  code {
  color: #383A42
  }

  .hljs-comment,
  .hljs-quote {
  color: #A0A1A7
  }

  .hljs-keyword,
  .hljs-selector-tag,
  .hljs-doctag,
  .hljs-formula {
  color: #A626A4
  }

  .hljs-string,
  .hljs-regexp,
  .hljs-addition,
  .hljs-attribute,
  .hljs-meta .hljs-string {
  color: #50A14F
  }

  .hljs-number {
  color: #C96A12
  }

  .hljs-literal {
  color: #0184BC
  }

  .hljs-title,
  .hljs-title.function_,
  .hljs-section,
  .hljs-symbol,
  .hljs-bullet,
  .hljs-link,
  .hljs-selector-id {
  color: #4078F2
  }

  .hljs-built_in,
  .hljs-type,
  .hljs-class .hljs-title,
  .hljs-title.class_,
  .hljs-meta {
  color: #C18401
  }

  .hljs-attr,
  .hljs-variable,
  .hljs-template-variable,
  .hljs-selector-class,
  .hljs-selector-attr,
  .hljs-selector-pseudo {
  color: #986801
  }

  .hljs-deletion {
  color: #E45649
  }
  """
}
