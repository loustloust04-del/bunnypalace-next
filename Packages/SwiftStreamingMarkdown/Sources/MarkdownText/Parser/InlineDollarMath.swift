//
//  MP fork: 行内 `$…$` 公式识别（pandoc 规则，防美元金额误伤）。
//  - 开 `$` 后面紧跟非空白；关 `$` 前面紧跟非空白，后面不是字母 / 数字
//    （`$5 和 $10`、`$AAPL and $TSLA` 都不成对）
//  - `\$` 是字面美元符；行内 `$$…$$` 也当行内公式
//  - 只在单行内、行内代码以外找；围栏代码块由调用方用 MarkdownFenceTracker 跳过
//

import Foundation

public enum InlineDollarMath {

  /// 一行里所有行内公式的范围（含两端 `$`）。MP 的 ticker 链接化用它避开 `$E = mc^2$` 里的 `$E`。
  public static func spans(in line: String) -> [Range<String.Index>] {
    guard line.contains("$") else { return [] }
    return InlineCodeSpans.segments(of: line)
      .filter { !$0.isCode }
      .flatMap { spans(inProse: $0.text) }
  }

  /// 把行内 `$…$` 改写成 `\(…\)`（随后由 LaTeX 预处理器转成行内公式附件）。
  static func rewrite(_ text: String) -> String {
    guard text.contains("$") else { return text }
    var tracker = MarkdownFenceTracker()
    return text.components(separatedBy: "\n").map { line in
      if tracker.consume(line) { return line }
      let found = spans(in: line)
      guard !found.isEmpty else { return line }
      var result = ""
      var cursor = line.startIndex
      for span in found {
        result += line[cursor..<span.lowerBound]
        let width = line[span].hasPrefix("$$") ? 2 : 1
        let inner = line[span].dropFirst(width).dropLast(width)
        result += "\\(\(inner)\\)"
        cursor = span.upperBound
      }
      result += line[cursor...]
      return result
    }.joined(separator: "\n")
  }

  private static func spans(inProse s: Substring) -> [Range<String.Index>] {
    var result: [Range<String.Index>] = []
    var i = s.startIndex
    while i < s.endIndex {
      let c = s[i]
      if c == "\\" {
        i = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
        continue
      }
      guard c == "$" else {
        i = s.index(after: i)
        continue
      }
      let afterFirst = s.index(after: i)
      let width = (afterFirst < s.endIndex && s[afterFirst] == "$") ? 2 : 1
      let contentStart = s.index(i, offsetBy: width)
      guard contentStart < s.endIndex, !s[contentStart].isWhitespace, s[contentStart] != "$" else {
        i = contentStart
        continue
      }
      if let close = closingDelimiter(in: s, from: contentStart, width: width) {
        let end = s.index(close, offsetBy: width)
        result.append(i..<end)
        i = end
      } else {
        i = contentStart
      }
    }
    return result
  }

  private static func closingDelimiter(in s: Substring, from start: String.Index, width: Int) -> String.Index? {
    var j = start
    while j < s.endIndex {
      let c = s[j]
      if c == "\\" {
        j = s.index(j, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
        continue
      }
      guard c == "$" else {
        j = s.index(after: j)
        continue
      }
      let next = s.index(after: j)
      let isDouble = next < s.endIndex && s[next] == "$"
      let before = s[s.index(before: j)]
      if width == 2 {
        if isDouble, !before.isWhitespace { return j }
        j = isDouble ? s.index(after: next) : next
        continue
      }
      if isDouble {
        j = s.index(after: next)
        continue
      }
      let after = next < s.endIndex ? s[next] : nil
      if !before.isWhitespace, !(after?.isLetter ?? false), !(after?.isNumber ?? false) {
        return j
      }
      j = next
    }
    return nil
  }
}
