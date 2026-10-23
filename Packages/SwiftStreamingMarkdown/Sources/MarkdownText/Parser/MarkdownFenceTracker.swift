//
//  MP fork: CommonMark 围栏代码块识别（多反引号 / 波浪线）。
//  打开时记下围栏字符和长度 N，只有同字符、长度 ≥ N、后面只剩空白的行才算关闭——
//  ````` 包 ``` 的嵌套不会被内层提前关掉。行级预处理（MP 侧分气泡、简化、ticker；
//  fork 侧公式 / 扩展语法）都用它判断「这一行在不在代码里」。
//

import Foundation

public struct MarkdownFenceTracker {

  private var open: (char: Character, count: Int)?

  public init() {}

  /// 当前是否处在一个未关闭的围栏里（下一行若不是关闭行就是代码内容）。
  public var isInsideFence: Bool { open != nil }

  /// 读入一行。返回 true = 这一行属于代码（开围栏行、内容行、关围栏行），行级改写应原样跳过。
  @discardableResult
  public mutating func consume<S: StringProtocol>(_ line: S) -> Bool {
    let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
    if let current = open {
      if let run = Self.fenceRun(trimmed), run.char == current.char, run.count >= current.count,
         trimmed.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
        open = nil
      }
      return true
    }
    guard let run = Self.fenceRun(trimmed) else { return false }
    // 反引号围栏的 info string 不能再含反引号（否则是行内代码）
    if run.char == "`", trimmed.dropFirst(run.count).contains("`") { return false }
    open = run
    return true
  }

  /// 行首连续 ≥3 个 ` 或 ~。
  public static func fenceRun<S: StringProtocol>(_ s: S) -> (char: Character, count: Int)? {
    guard let first = s.first, first == "`" || first == "~" else { return nil }
    let count = s.prefix(while: { $0 == first }).count
    return count >= 3 ? (first, count) : nil
  }

  /// 文本中最长的连续反引号（用来挑一个不会被内容提前关闭的外层围栏长度）。
  public static func longestBacktickRun<S: StringProtocol>(in s: S) -> Int {
    var longest = 0, current = 0
    for ch in s {
      if ch == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
    }
    return longest
  }
}

/// MP fork: 同长度围栏嵌套的推断 + 改写。
/// 模型常用三个反引号包三个反引号（```markdown 里再写 ```python … ```）。按 CommonMark，
/// 内层第一个裸 ``` 就会关掉外层，后半截全乱。推断规则：在围栏里遇到**带 info string**的
/// 同字符、不短于外层的围栏行（结束行不可能带语言名）→ 视为开了一层内层；裸围栏行先关内层，
/// 内层全关完才关外层。推断出嵌套的外层块，开 / 关两行的围栏加长到比内层最长的还长一个，
/// 此后任何按标准配对的下游（cmark、MarkdownFenceTracker）都能正确解析。幂等。
public enum MarkdownFenceNormalizer {

  public static func normalize(_ text: String) -> String {
    guard text.contains("```") || text.contains("~~~") else { return text }
    var lines = text.components(separatedBy: "\n")
    var changed = false
    var i = 0
    while i < lines.count {
      let trimmed = lines[i].drop(while: { $0 == " " || $0 == "\t" })
      guard let open = MarkdownFenceTracker.fenceRun(trimmed),
            !(open.char == "`" && trimmed.dropFirst(open.count).contains("`")) else {
        i += 1
        continue
      }
      // 找这个外层块的结尾，同时记内层嵌套
      var depth = 0
      var innerMax = 0
      var close: Int?
      var j = i + 1
      while j < lines.count {
        let t = lines[j].drop(while: { $0 == " " || $0 == "\t" })
        if let run = MarkdownFenceTracker.fenceRun(t), run.char == open.char, run.count >= open.count {
          let rest = t.dropFirst(run.count)
          let isBare = rest.allSatisfy { $0 == " " || $0 == "\t" }
          if !isBare, !(run.char == "`" && rest.contains("`")) {
            depth += 1
            innerMax = max(innerMax, run.count)
          } else if isBare {
            if depth == 0 { close = j; break }
            depth -= 1
            innerMax = max(innerMax, run.count)
          }
        }
        j += 1
      }
      if innerMax > 0 {
        let length = innerMax + 1
        lines[i] = relength(lines[i], char: open.char, to: length)
        if let close { lines[close] = relength(lines[close], char: open.char, to: length) }
        changed = true
      }
      i = (close ?? lines.count - 1) + 1
    }
    return changed ? lines.joined(separator: "\n") : text
  }

  private static func relength(_ line: String, char: Character, to length: Int) -> String {
    let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
    let rest = line.dropFirst(indent.count).drop(while: { $0 == char })
    return String(indent) + String(repeating: char, count: length) + rest
  }
}
