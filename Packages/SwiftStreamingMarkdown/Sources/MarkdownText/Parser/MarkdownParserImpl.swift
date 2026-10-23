//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Markdown

/// The built-in `MarkdownParser` implementation.
public final class MarkdownParserImpl: MarkdownParser {

  private let rewriters: [MarkupPostParsingRewriter] = [
    PartialStrongMarkupPostParsingRewriter(),
    PartialTableMarkupPostParsingRewriter()
  ]

  private let latexPreprocessor: LaTexPreProcessor

  /// Create a new parser instance using the default LaTeX preprocessor.
  public init() {
    self.latexPreprocessor = LaTexPreProcessorImpl()
  }

  /// Parse `text` into a `MarkdownParseResult`. See `MarkdownParser.parse(text:option:)`.
  public func parse(text: String, option: MarkdownParseOption) async -> MarkdownParseResult {
    let targetString = Self.preprocess(text, latexPreprocessor: latexPreprocessor, rules: option.latexMatchingRules)

    var result: MarkdownParseResult = MarkdownParseResult(
      document: Document(parsing: targetString),
      speculativeRewritten: false
    )

    if option.speculativeRewrite {
      for rewriter in rewriters {
        if let rewrittenDoc = rewriter.rewriteIfApplicable(document: result.document) {
          result = MarkdownParseResult(document: rewrittenDoc, speculativeRewritten: true)
        }
      }
    }
    return result
  }

  /// mp-custom: synchronous parse-to-renderable for first-appearance rendering.
  /// The whole pipeline is pure CPU with no real suspension points (`parse` has
  /// no awaits; `RenderableDocument.init` wraps a synchronous `convert`), so a
  /// caller that needs the *correct height on the first layout pass* — avoiding
  /// the empty-placeholder → async-grow double layout that thrashes list
  /// compensation during fast scrolls — can pay the cost inline.
  public func parseSync(text: String, config: MarkdownRenderConfig) -> RenderableDocument {
    let processed = Self.preprocess(text, latexPreprocessor: latexPreprocessor, rules: MarkdownParseOption.LatexMatching.allCases)
    let document = Document(parsing: processed)
    return RenderableDocument(renderables: document.convert(with: config))
  }

  /// MP fork: 扩展语法（details / 缩写 / 脚注 / 定义列表）→ LaTeX（块、`$`、`\(`）。
  static func preprocess(_ text: String, latexPreprocessor: LaTexPreProcessor, rules: [MarkdownParseOption.LatexMatching]) -> String {
    let extended = MarkdownExtensionPreprocessor.process(text)
    return latexPreprocessor.process(input: extended, matchingRules: rules)
  }

  /// MP fork: 嵌套片段（`<details>` 正文）用同一条管线同步解析成块。
  static func renderables(for text: String, config: MarkdownRenderConfig) -> [MarkdownRenderable] {
    let processed = preprocess(text, latexPreprocessor: LaTexPreProcessorImpl(), rules: MarkdownParseOption.LatexMatching.allCases)
    return Document(parsing: processed).convert(with: config)
  }
}
