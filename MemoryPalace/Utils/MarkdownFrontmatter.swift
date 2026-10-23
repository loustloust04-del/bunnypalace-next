import Foundation

/// `---` 包起来的 YAML 头。**保序**解析（展示要按原文顺序，`TradingStore.parseFrontmatter` 那份返回字典、顺序会丢）。
/// 不是全功能 YAML：只认顶层 `key: value`、行内数组 `[a, b]`、以及缩进的 `- item` 续行。
/// 认不出的行原样忽略，绝不吞正文。
enum MarkdownFrontmatter {

    struct Field: Equatable {
        let key: String
        let value: String
    }

    struct Split: Equatable {
        var fields: [Field]
        /// 去掉头之后的正文（没有头就是原文）
        var body: String
    }

    static func split(_ md: String) -> Split {
        guard md.hasPrefix("---\n") else { return Split(fields: [], body: md) }
        let afterOpen = md.index(md.startIndex, offsetBy: 4)
        // 收尾行必须是单独一行 `---`（正文里的分隔线不能当收尾）
        guard let end = closingFence(md, from: afterOpen) else { return Split(fields: [], body: md) }
        let head = String(md[afterOpen..<end.lowerBound])
        let body = String(md[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Split(fields: fields(inHead: head), body: body)
    }

    /// 只解析字段（没有头就是空）
    static func fields(_ md: String) -> [Field] { split(md).fields }

    // MARK: -

    private static func closingFence(_ md: String, from: String.Index) -> Range<String.Index>? {
        var searchFrom = from
        while let hit = md.range(of: "\n---", range: searchFrom..<md.endIndex) {
            // `\n---` 之后必须是行尾（换行或文件结束），否则是 `----` 或 `--- foo`
            let after = hit.upperBound
            if after == md.endIndex { return hit.lowerBound..<after }
            if md[after] == "\n" { return hit.lowerBound..<md.index(after: after) }
            searchFrom = after
        }
        return nil
    }

    private static func fields(inHead head: String) -> [Field] {
        var out: [Field] = []
        for raw in head.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // 缩进的 `- item`：并进上一个字段
            if line.first == " " || line.first == "\t" || line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                let item = clean(line.trimmingCharacters(in: .whitespaces).drop { $0 == "-" }.trimmingCharacters(in: .whitespaces))
                guard !item.isEmpty, let last = out.popLast() else { continue }
                out.append(Field(key: last.key, value: last.value.isEmpty ? item : last.value + "、" + item))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out.append(Field(key: key, value: clean(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))))
        }
        return out
    }

    /// 去掉包裹引号、把行内数组 `[a, b]` 摊成「a、b」
    private static func clean<S: StringProtocol>(_ raw: S) -> String {
        var v = String(raw)
        if v.count >= 2, v.hasPrefix("["), v.hasSuffix("]") {
            v = v.dropFirst().dropLast()
                .split(separator: ",")
                .map { clean($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "、")
            return v
        }
        for quote in ["\"", "'", "“"] where v.hasPrefix(quote) {
            v = String(v.dropFirst())
        }
        for quote in ["\"", "'", "”"] where v.hasSuffix(quote) {
            v = String(v.dropLast())
        }
        return v
    }
}
