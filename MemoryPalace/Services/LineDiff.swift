import Foundation

/// A4 版本历史的行级 diff。末行有没有换行算进行身份（同 git 的「No newline at end of file」），CRLF 当一个换行。
/// 先剥公共前后缀、再丢掉对面根本没有的行（这些行必然是增 / 删，不影响 LCS），剩下的交给 CollectionDifference：
/// 整篇重写的 5000 行文件也只剩空集，不会走 Myers 最坏情况。
enum LineDiff {
    enum Change: Equatable, Sendable {
        case added, removed, unchanged
    }

    struct Line: Equatable, Sendable {
        let change: Change
        let text: String
        /// 1 起；增行为 nil
        let oldNumber: Int?
        /// 1 起；删行为 nil
        let newNumber: Int?
        /// 文件末行没有换行
        let missingNewline: Bool
    }

    struct Result: Equatable, Sendable {
        let lines: [Line]
        let added: Int
        let removed: Int
    }

    private struct RawLine: Hashable {
        let text: String
        let hasNewline: Bool
    }

    static func compute(old: String, new: String) -> Result {
        let a = split(old), b = split(new)
        var ids: [RawLine: Int] = [:]
        func intern(_ line: RawLine) -> Int {
            if let id = ids[line] { return id }
            ids[line] = ids.count
            return ids.count - 1
        }
        let ai = a.map(intern), bi = b.map(intern)

        var anchors: [(Int, Int)] = []
        var prefix = 0
        while prefix < ai.count, prefix < bi.count, ai[prefix] == bi[prefix] {
            anchors.append((prefix, prefix))
            prefix += 1
        }
        var suffix = 0
        while suffix < ai.count - prefix, suffix < bi.count - prefix,
              ai[ai.count - 1 - suffix] == bi[bi.count - 1 - suffix] {
            suffix += 1
        }

        let midA = Array(prefix..<(ai.count - suffix)), midB = Array(prefix..<(bi.count - suffix))
        let inA = Set(midA.map { ai[$0] }), inB = Set(midB.map { bi[$0] })
        let keptA = midA.filter { inB.contains(ai[$0]) }, keptB = midB.filter { inA.contains(bi[$0]) }
        let seqA = keptA.map { ai[$0] }, seqB = keptB.map { bi[$0] }
        var removedAt = Set<Int>(), insertedAt = Set<Int>()
        for change in seqB.difference(from: seqA) {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }
        var x = 0, y = 0
        while x < seqA.count, y < seqB.count {
            if removedAt.contains(x) { x += 1 }
            else if insertedAt.contains(y) { y += 1 }
            else { anchors.append((keptA[x], keptB[y])); x += 1; y += 1 }
        }
        for k in 0..<suffix { anchors.append((ai.count - suffix + k, bi.count - suffix + k)) }

        var lines: [Line] = []
        lines.reserveCapacity(max(a.count, b.count))
        var added = 0, removed = 0, i = 0, j = 0
        for (anchorA, anchorB) in anchors + [(a.count, b.count)] {
            while i < anchorA {
                lines.append(Line(change: .removed, text: a[i].text, oldNumber: i + 1, newNumber: nil,
                                  missingNewline: !a[i].hasNewline))
                removed += 1; i += 1
            }
            while j < anchorB {
                lines.append(Line(change: .added, text: b[j].text, oldNumber: nil, newNumber: j + 1,
                                  missingNewline: !b[j].hasNewline))
                added += 1; j += 1
            }
            guard anchorA < a.count else { break }
            lines.append(Line(change: .unchanged, text: a[i].text, oldNumber: i + 1, newNumber: j + 1,
                              missingNewline: !a[i].hasNewline))
            i += 1; j += 1
        }
        return Result(lines: lines, added: added, removed: removed)
    }

    /// 空串 = 0 行；以换行结尾不多出一个空行
    private static func split(_ text: String) -> [RawLine] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let endsWithNewline = text.last?.isNewline == true
        if endsWithNewline { parts.removeLast() }
        return parts.enumerated().map { offset, part in
            RawLine(text: String(part), hasNewline: endsWithNewline || offset < parts.count - 1)
        }
    }
}

// MARK: - 版本 diff 页：行内高亮 + 折叠没变的段

extension LineDiff {
    /// 每行要加深的字符区间（Character 偏移，左闭右开），下标对齐 `lines`。
    /// 一段连续改动（删行组 + 增行组）整体拼起来（行间算一个换行）做词级 diff：中文按字、英文数字按词；
    /// 再把高亮切回各自行，换行本身不画。纯增 / 纯删、去掉公共前后缀后中段超 `maxMiddleTokens`、
    /// 相同部分不到三成（基本是重写）→ 这段不给行内高亮，只剩整行浅底。
    static func inlineHighlights(_ lines: [Line], maxMiddleTokens: Int = 2000) -> [[Range<Int>]] {
        var result = Array(repeating: [Range<Int>](), count: lines.count)
        var i = 0
        while i < lines.count {
            guard lines[i].change != .unchanged else { i += 1; continue }
            var removed: [Int] = [], added: [Int] = []
            while i < lines.count, lines[i].change != .unchanged {
                if lines[i].change == .removed { removed.append(i) } else { added.append(i) }
                i += 1
            }
            guard !removed.isEmpty, !added.isEmpty,
                  let (old, new) = blockHighlights(old: removed.map { lines[$0].text },
                                                   new: added.map { lines[$0].text },
                                                   maxMiddleTokens: maxMiddleTokens)
            else { continue }
            for (k, index) in removed.enumerated() { result[index] = old[k] }
            for (k, index) in added.enumerated() { result[index] = new[k] }
        }
        return result
    }

    enum Segment: Equatable, Sendable {
        case shown(Range<Int>)
        /// 连续没变的行，折成一行「… N 行没变」
        case folded(Range<Int>)
    }

    /// 每处改动上下各留 `context` 行，其余连续没变的折起来；只差 1 行的不折（折了也不省地方）
    static func segments(_ lines: [Line], context: Int = 3) -> [Segment] {
        guard !lines.isEmpty else { return [] }
        var keep = [Bool](repeating: false, count: lines.count)
        for i in lines.indices where lines[i].change != .unchanged {
            for k in max(0, i - context)...min(lines.count - 1, i + context) { keep[k] = true }
        }
        var result: [Segment] = []
        var start = 0
        while start < lines.count {
            var end = start
            while end < lines.count, keep[end] == keep[start] { end += 1 }
            if !keep[start], end - start >= 2 {
                result.append(.folded(start..<end))
            } else if case .shown(let previous)? = result.last {
                result[result.count - 1] = .shown(previous.lowerBound..<end)
            } else {
                result.append(.shown(start..<end))
            }
            start = end
        }
        return result
    }

    private enum Chunk {
        case equal(Int)
        case change(removed: Int, inserted: Int)
    }

    private static let lineBreakToken = "\n"

    private static func blockHighlights(old: [String], new: [String], maxMiddleTokens: Int)
        -> ([[Range<Int>]], [[Range<Int>]])? {
        let a = tokens(old), b = tokens(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = a[prefix..<(a.count - suffix)], midB = b[prefix..<(b.count - suffix)]
        guard midA.count + midB.count <= maxMiddleTokens else { return nil }

        var removedAt = Set<Int>(), insertedAt = Set<Int>()
        for change in Array(midB).difference(from: Array(midA)) {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }

        var chunks: [Chunk] = []
        func append(_ chunk: Chunk) {
            switch (chunks.last, chunk) {
            case (.equal(let x)?, .equal(let y)):
                chunks[chunks.count - 1] = .equal(x + y)
            case (.change(let r1, let i1)?, .change(let r2, let i2)):
                chunks[chunks.count - 1] = .change(removed: r1 + r2, inserted: i1 + i2)
            default:
                chunks.append(chunk)
            }
        }
        append(.equal(a[..<prefix].reduce(0) { $0 + $1.count }))
        var x = 0, y = 0
        while x < midA.count || y < midB.count {
            if x < midA.count, removedAt.contains(x) || y == midB.count {
                append(.change(removed: midA[prefix + x].count, inserted: 0)); x += 1
            } else if y < midB.count, insertedAt.contains(y) || x == midA.count {
                append(.change(removed: 0, inserted: midB[prefix + y].count)); y += 1
            } else {
                append(.equal(midA[prefix + x].count)); x += 1; y += 1
            }
        }
        append(.equal(a[(a.count - suffix)...].reduce(0) { $0 + $1.count }))

        // 两段改动中间夹的短相同片段并进改动（同 diff-match-patch 的语义清理），免得高亮碎成芝麻点
        var merged = true
        while merged {
            merged = false
            var k = 1
            while k + 1 < chunks.count {
                if case .equal(let length) = chunks[k],
                   case .change(let r1, let i1) = chunks[k - 1],
                   case .change(let r2, let i2) = chunks[k + 1],
                   length <= max(r1, i1), length <= max(r2, i2) {
                    chunks.replaceSubrange((k - 1)...(k + 1),
                                           with: [.change(removed: r1 + length + r2, inserted: i1 + length + i2)])
                    merged = true
                } else {
                    k += 1
                }
            }
        }

        let oldLength = a.reduce(0) { $0 + $1.count }, newLength = b.reduce(0) { $0 + $1.count }
        var same = 0, oldRanges: [Range<Int>] = [], newRanges: [Range<Int>] = []
        var oldPos = 0, newPos = 0
        for chunk in chunks {
            switch chunk {
            case .equal(let length):
                same += length; oldPos += length; newPos += length
            case .change(let removed, let inserted):
                if removed > 0 { oldRanges.append(oldPos..<(oldPos + removed)) }
                if inserted > 0 { newRanges.append(newPos..<(newPos + inserted)) }
                oldPos += removed; newPos += inserted
            }
        }
        guard same * 10 >= max(oldLength, newLength) * 3 else { return nil }
        return (split(oldRanges, lines: old), split(newRanges, lines: new))
    }

    /// 拼接坐标（行间一个换行）→ 各行本地坐标
    private static func split(_ ranges: [Range<Int>], lines: [String]) -> [[Range<Int>]] {
        var result: [[Range<Int>]] = []
        var start = 0
        for line in lines {
            let length = line.count
            result.append(ranges.compactMap { range in
                let lower = max(range.lowerBound, start), upper = min(range.upperBound, start + length)
                return lower < upper ? (lower - start)..<(upper - start) : nil
            })
            start += length + 1
        }
        return result
    }

    /// ASCII 字母数字连成一个词，其余（汉字、标点、空格）一个字一个 token；行间插换行 token
    private static func tokens(_ lines: [String]) -> [String] {
        var result: [String] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(lineBreakToken) }
            var word = ""
            for character in line {
                if character.isASCII, character.isLetter || character.isNumber || character == "_" {
                    word.append(character)
                    continue
                }
                if !word.isEmpty { result.append(word); word = "" }
                result.append(String(character))
            }
            if !word.isEmpty { result.append(word) }
        }
        return result
    }
}
