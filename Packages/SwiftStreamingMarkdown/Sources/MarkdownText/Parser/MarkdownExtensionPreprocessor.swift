//
//  MP fork: 解析前的文本级扩展语法改写（cmark 不认、又必须在解析前拿到原文的那几种）。
//  - `<details><summary>…</summary>…</details>` → ````mp-details 围栏（渲染成可折叠块，正文递归解析）
//  - 缩写 `*[HTML]: HyperText Markup Language` → 删定义行，正文里整词出现处包成 `<abbr title>`
//  - 脚注 `[^1]` + `[^1]: …` → 引用处 `<sup>n</sup>`，定义收到文末一段小字
//  - 定义列表 `术语\n: 释义` → 加粗术语 + 缩进释义（硬换行同一段）
//  全部跳过围栏代码块和行内代码；没有对应标记时原样返回（热路径零开销）。
//  行内的 `==高亮==` `||剧透||` `{注音|zhù yīn}` 与 `<mark>` 等标签在段落富文本上处理
//  （InlineExtensionProcessor），那样才能跨粗体 / 斜体节点生效。
//

import Foundation

enum MarkdownExtensionPreprocessor {

  static let detailsLanguage = "mp-details"

  static func process(_ text: String) -> String {
    var result = MarkdownFenceNormalizer.normalize(text)
    result = processDetails(result)
    result = processAbbreviations(result)
    result = processFootnotes(result)
    result = processDefinitionLists(result)
    return result
  }

  // MARK: - <details>

  private static let detailsOpen = try! NSRegularExpression(pattern: #"^\s*<details(\s[^>]*)?>"#, options: [.caseInsensitive])
  private static let detailsOpenAnywhere = try! NSRegularExpression(pattern: #"<details(\s[^>]*)?>"#, options: [.caseInsensitive])
  private static let detailsClose = try! NSRegularExpression(pattern: #"</details\s*>"#, options: [.caseInsensitive])
  private static let summary = try! NSRegularExpression(pattern: #"^\s*<summary(\s[^>]*)?>(.*?)</summary\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

  static func processDetails(_ text: String) -> String {
    guard text.range(of: "<details", options: .caseInsensitive) != nil else { return text }
    let lines = text.components(separatedBy: "\n")
    var out: [String] = []
    var tracker = MarkdownFenceTracker()
    var i = 0
    while i < lines.count {
      let line = lines[i]
      if tracker.consume(line) || !detailsOpen.matches(line) {
        out.append(line)
        i += 1
        continue
      }
      // 收集到配对的 </details>（嵌套计深度；块内围栏里的字样不算）
      var depth = 0
      var inner = MarkdownFenceTracker()
      var collected: [String] = []
      var closed = false
      var j = i
      while j < lines.count {
        let l = lines[j]
        collected.append(l)
        if !inner.consume(l) {
          depth += detailsOpenAnywhere.count(in: l) - detailsClose.count(in: l)
          if depth <= 0 { closed = true; break }
        }
        j += 1
      }
      out.append(contentsOf: renderDetails(collected, closed: closed))
      i = j + 1
    }
    return out.joined(separator: "\n")
  }

  private static func renderDetails(_ lines: [String], closed: Bool) -> [String] {
    let indentation = String(lines[0].prefix(while: { $0 == " " }).prefix(3))
    var rest = lines.joined(separator: "\n") as NSString
    var isOpen = false
    if let m = detailsOpen.firstMatch(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
      if m.range(at: 1).location != NSNotFound {
        isOpen = rest.substring(with: m.range(at: 1)).range(of: #"\bopen\b"#, options: [.regularExpression, .caseInsensitive]) != nil
      }
      rest = rest.substring(from: NSMaxRange(m.range)) as NSString
    }
    if closed {
      let matches = detailsClose.matches(in: rest as String, range: NSRange(location: 0, length: rest.length))
      if let last = matches.last {
        rest = rest.substring(to: last.range.location) as NSString
      }
    }
    var summaryText = ""
    if let m = summary.firstMatch(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
      summaryText = rest.substring(with: m.range(at: 2))
      rest = rest.substring(from: NSMaxRange(m.range)) as NSString
    }
    summaryText = summaryText
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let body = (rest as String).trimmingCharacters(in: .newlines)
    let fence = String(repeating: "`", count: max(4, MarkdownFenceTracker.longestBacktickRun(in: body) + 1))
    var result = ["\(indentation)\(fence)\(detailsLanguage)", "\(indentation)\(isOpen ? "open" : "closed")", "\(indentation)\(summaryText)"]
    if !body.isEmpty {
      result.append(contentsOf: body.components(separatedBy: "\n"))
    }
    result.append("\(indentation)\(fence)")
    return result
  }

  /// `mp-details` 围栏内容 → (初始展开, 标题, 正文)。
  static func decodeDetails(_ code: String) -> (isOpen: Bool, summary: String, body: String) {
    var lines = code.components(separatedBy: "\n")
    let flag = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
    let summary = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
    return (flag == "open", summary, lines.joined(separator: "\n"))
  }

  // MARK: - 缩写

  private static let abbreviationDefinition = try! NSRegularExpression(pattern: #"^ {0,3}\*\[([^\]\n]+)\]:[ \t]*(.+?)\s*$"#)

  static func processAbbreviations(_ text: String) -> String {
    guard text.contains("*[") else { return text }
    var definitions: [(String, String)] = []
    var kept: [String] = []
    var tracker = MarkdownFenceTracker()
    for line in text.components(separatedBy: "\n") {
      if !tracker.consume(line), let m = abbreviationDefinition.firstMatch(in: line, range: line.nsRange) {
        let ns = line as NSString
        let term = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if !term.isEmpty { definitions.append((term, ns.substring(with: m.range(at: 2)))) }
        continue
      }
      kept.append(line)
    }
    guard !definitions.isEmpty else { return text }
    var titles: [String: String] = [:]
    for (term, title) in definitions { titles[term] = title }
    let alternation = titles.keys
      .sorted { $0.count > $1.count }
      .map { NSRegularExpression.escapedPattern(for: $0) }
      .joined(separator: "|")
    guard let pattern = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:"# + alternation + #")(?![\p{L}\p{N}_])"#) else {
      return kept.joined(separator: "\n")
    }
    return transformProseLines(kept.joined(separator: "\n")) { prose in
      pattern.replace(in: prose) { term in
        let title = titles[term].map(escapeAttribute) ?? ""
        return "<abbr title=\"\(title)\">\(term)</abbr>"
      }
    }
  }

  private static func escapeAttribute(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  // MARK: - 脚注

  private static let footnoteDefinition = try! NSRegularExpression(pattern: #"^ {0,3}\[\^([^\]\s]+)\]:[ \t]?(.*)$"#)
  private static let footnoteReference = try! NSRegularExpression(pattern: #"\[\^([^\]\s]+)\]"#)

  static func processFootnotes(_ text: String) -> String {
    guard text.contains("[^") else { return text }
    var definitions: [String: String] = [:]
    var definitionOrder: [String] = []
    var kept: [String] = []
    var tracker = MarkdownFenceTracker()
    var currentLabel: String?
    for line in text.components(separatedBy: "\n") {
      if tracker.consume(line) {
        currentLabel = nil
        kept.append(line)
        continue
      }
      if let m = footnoteDefinition.firstMatch(in: line, range: line.nsRange) {
        let ns = line as NSString
        let label = ns.substring(with: m.range(at: 1))
        if definitions[label] == nil { definitionOrder.append(label) }
        definitions[label] = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        currentLabel = label
        continue
      }
      // 定义的续行：缩进的非空行
      if let label = currentLabel, line.first == " " || line.first == "\t",
         !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let continuation = line.trimmingCharacters(in: .whitespaces)
        definitions[label] = [definitions[label] ?? "", continuation].filter { !$0.isEmpty }.joined(separator: " ")
        continue
      }
      currentLabel = nil
      kept.append(line)
    }
    guard !definitions.isEmpty else { return text }

    var numbers: [String: Int] = [:]
    let body = transformProseLines(kept.joined(separator: "\n")) { prose in
      footnoteReference.replace(in: prose, group: 1) { label in
        guard definitions[label] != nil else { return nil }
        if let n = numbers[label] { return "<sup>\(n)</sup>" }
        let n = numbers.count + 1
        numbers[label] = n
        return "<sup>\(n)</sup>"
      }
    }
    for label in definitionOrder where numbers[label] == nil {
      numbers[label] = numbers.count + 1
    }
    let notes = definitionOrder
      .sorted { numbers[$0]! < numbers[$1]! }
      .map { "<small><sup>\(numbers[$0]!)</sup> \(definitions[$0]!)</small>" }
      .joined(separator: "\\\n")
    return body.trimmingCharacters(in: .newlines) + "\n\n" + notes
  }

  // MARK: - 定义列表

  private static let definitionLine = try! NSRegularExpression(pattern: #"^ {0,3}:[ \t]+(\S.*)$"#)

  static func processDefinitionLists(_ text: String) -> String {
    guard text.contains("\n:") else { return text }
    let lines = text.components(separatedBy: "\n")
    var out: [String] = []
    var tracker = MarkdownFenceTracker()
    var i = 0
    while i < lines.count {
      let line = lines[i]
      let inCode = tracker.consume(line)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !inCode, !trimmed.isEmpty, definitionLine.firstMatch(in: line, range: line.nsRange) == nil,
            i + 1 < lines.count, definitionLine.firstMatch(in: lines[i + 1], range: lines[i + 1].nsRange) != nil,
            !isBlockMarker(trimmed) else {
        out.append(line)
        i += 1
        continue
      }
      var definitions: [String] = []
      var j = i + 1
      while j < lines.count, let m = definitionLine.firstMatch(in: lines[j], range: lines[j].nsRange) {
        definitions.append((lines[j] as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces))
        j += 1
      }
      let term = trimmed.contains("**") ? trimmed : "**\(trimmed)**"
      out.append(term + "\\")
      for (k, definition) in definitions.enumerated() {
        out.append("\u{3000}" + definition + (k == definitions.count - 1 ? "" : "\\"))
      }
      i = j
    }
    return out.joined(separator: "\n")
  }

  private static func isBlockMarker(_ trimmed: String) -> Bool {
    if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") { return true }
    if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
    if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
       dot != trimmed.startIndex, trimmed[..<dot].allSatisfy(\.isNumber) { return true }
    return false
  }

  // MARK: - 行内正文分段

  /// 标签 / 链接地址 / 裸 URL：整词替换不能碰
  private static let protectedInline = try! NSRegularExpression(pattern: #"<[^>\n]*>|\]\([^)\n]*\)|https?://[^\s<>()]+"#)

  /// 对围栏外每一行里「行内代码 / 标签 / 链接地址」以外的正文片段做替换。
  static func transformProseLines(_ text: String, _ transform: (String) -> String) -> String {
    var tracker = MarkdownFenceTracker()
    return text.components(separatedBy: "\n").map { line in
      if tracker.consume(line) { return line }
      return InlineCodeSpans.segments(of: line).map { segment in
        segment.isCode ? String(segment.text) : transformUnprotected(String(segment.text), transform)
      }.joined()
    }.joined(separator: "\n")
  }

  private static func transformUnprotected(_ text: String, _ transform: (String) -> String) -> String {
    let ns = text as NSString
    var result = ""
    var cursor = 0
    for m in protectedInline.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      result += transform(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
      result += ns.substring(with: m.range)
      cursor = NSMaxRange(m.range)
    }
    result += transform(ns.substring(from: cursor))
    return result
  }
}

// MARK: - 行内代码切分

/// 按 CommonMark 规则切出行内代码：n 个反引号开，恰好 n 个反引号关；找不到配对就是字面反引号。
enum InlineCodeSpans {

  static func segments(of line: String) -> [(text: Substring, isCode: Bool)] {
    guard line.contains("`") else { return [(line[...], false)] }
    var result: [(Substring, Bool)] = []
    var proseStart = line.startIndex
    var i = line.startIndex
    while i < line.endIndex {
      guard line[i] == "`" else {
        i = line.index(after: i)
        continue
      }
      let runEnd = line[i...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
      let runLength = line.distance(from: i, to: runEnd)
      var search = runEnd
      var closeEnd: String.Index?
      while search < line.endIndex {
        guard let next = line[search...].firstIndex(of: "`") else { break }
        let end = line[next...].firstIndex(where: { $0 != "`" }) ?? line.endIndex
        if line.distance(from: next, to: end) == runLength {
          closeEnd = end
          break
        }
        search = end
      }
      guard let closeEnd else {
        i = runEnd
        continue
      }
      if proseStart < i { result.append((line[proseStart..<i], false)) }
      result.append((line[i..<closeEnd], true))
      proseStart = closeEnd
      i = closeEnd
    }
    if proseStart < line.endIndex { result.append((line[proseStart...], false)) }
    return result
  }
}

// MARK: - helpers

extension String {
  var nsRange: NSRange { NSRange(location: 0, length: (self as NSString).length) }
}

extension NSRegularExpression {

  func matches(_ s: String) -> Bool {
    firstMatch(in: s, range: s.nsRange) != nil
  }

  func count(in s: String) -> Int {
    numberOfMatches(in: s, range: s.nsRange)
  }

  /// 用闭包替换每个匹配（按 `group` 取值传入，返回 nil 保留原文）。
  func replace(in s: String, group: Int = 0, _ transform: (String) -> String?) -> String {
    let ns = s as NSString
    var result = ""
    var cursor = 0
    for m in matches(in: s, range: s.nsRange) {
      result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
      let value = ns.substring(with: m.range(at: group))
      result += transform(value) ?? ns.substring(with: m.range)
      cursor = NSMaxRange(m.range)
    }
    result += ns.substring(from: cursor)
    return result
  }
}
