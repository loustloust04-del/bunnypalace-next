import Foundation

/// 整理记录分节（`FileEditorPreviewLocation`）和拆围栏 / 切段（`RunRecordPreview`）共用的逐行扫描。
/// 分行认 LF / CRLF / CR，行尾原样保留：各行 `full` 首尾相接逐字节就是原文，不规范化换行。
/// Swift 里 "\r\n" 是一个字符簇，按 Character 找 "\n" 会整份漏掉（astra 审 3294acd33 P1-1）。
enum RunRecordScanner {
    struct Line {
        /// 不含行尾
        let content: Substring
        /// 含行尾
        let full: Substring
    }

    static func lines(_ text: String) -> [Line] { lines(text[...], check: {}) }

    /// 每扫这么多字节问一次要不要停（超长单行也能及时停）
    static let checkEveryBytes = 64 * 1024

    /// 下标就是原 String 的下标，切出来的行能直接在原文上取区间。`check` 抛错 = 停（后台解析传取消检查）
    static func lines(_ text: Substring, check: () throws -> Void) rethrows -> [Line] {
        var out: [Line] = []
        let bytes = text.utf8
        var start = bytes.startIndex
        var i = start
        var scanned = 0
        while i < bytes.endIndex {
            let byte = bytes[i]
            scanned += 1
            if scanned == checkEveryBytes {
                scanned = 0
                try check()
            }
            guard byte == 0x0A || byte == 0x0D else {
                i = bytes.index(after: i)
                continue
            }
            var next = bytes.index(after: i)
            if byte == 0x0D, next < bytes.endIndex, bytes[next] == 0x0A { next = bytes.index(after: next) }
            out.append(Line(content: text[start..<i], full: text[start..<next]))
            start = next
            i = next
        }
        if start < bytes.endIndex { out.append(Line(content: text[start...], full: text[start...])) }
        return out
    }

    /// `<a id="…"></a>` 独占一行（缩进 <4 列）= 分节锚点
    static func isAnchor(_ line: Substring) -> Bool {
        guard indent(line).columns < 4 else { return false }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return trimmed.hasPrefix("<a id=\"") && trimmed.hasSuffix("\"></a>")
    }

    /// ATX 标题：缩进 <4 列，1–6 个 #，后面是空格 / tab 或行尾；去掉收尾的 # 串
    static func heading(_ line: Substring) -> (level: Int, text: String)? {
        let indent = indent(line)
        guard indent.columns < 4 else { return nil }
        let rest = line.dropFirst(indent.length)
        let level = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if let closing = text.lastIndex(where: { $0 != "#" }) {
            let tail = text[text.index(after: closing)...]
            if !tail.isEmpty, text[closing] == " " || text[closing] == "\t" {
                text = String(text[...closing]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            }
        } else {
            text = ""
        }
        return (level, text)
    }

    /// 行首缩进按 CommonMark 列宽算：空格 1 列，tab 跳到下一个 4 的倍数。返回（列数，缩进占几个字符）
    static func indent(_ line: Substring) -> (columns: Int, length: Int) {
        var columns = 0
        var length = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - columns % 4
            } else {
                break
            }
            length += 1
        }
        return (columns, length)
    }

    /// CommonMark 0.31.2 §4.5 围栏。开栏：缩进 <4 列，≥3 个 ` 或 ~；` 开栏的 info string 不能含 `。
    /// 闭栏：缩进 <4 列，同字符、不短于开栏，后面只有空格 / tab。开、闭规则分开判
    struct Fence {
        let character: Character
        let count: Int
        let info: String

        var language: String {
            info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        }

        static func open(_ line: Substring) -> Fence? {
            let indent = RunRecordScanner.indent(line)
            guard indent.columns < 4 else { return nil }
            let rest = line.dropFirst(indent.length)
            guard let character = rest.first, character == "`" || character == "~" else { return nil }
            let count = rest.prefix(while: { $0 == character }).count
            guard count >= 3 else { return nil }
            let info = rest.dropFirst(count).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if character == "`", info.contains("`") { return nil }
            return Fence(character: character, count: count, info: info)
        }

        func closes(_ line: Substring) -> Bool {
            let indent = RunRecordScanner.indent(line)
            guard indent.columns < 4 else { return false }
            let rest = line.dropFirst(indent.length)
            let count = rest.prefix(while: { $0 == character }).count
            return count >= self.count && rest.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    /// 逐行喂进来：在围栏里返回当前围栏，`opened` / `closed` 说这一行是不是开 / 闭栏行
    struct FenceState {
        private(set) var fence: Fence?

        enum Step {
            case opened(Fence)
            case closed(Fence)
            case inside(Fence)
            case outside
        }

        mutating func feed(_ line: Substring) -> Step {
            if let current = fence {
                if current.closes(line) {
                    fence = nil
                    return .closed(current)
                }
                return .inside(current)
            }
            if let opened = Fence.open(line) {
                fence = opened
                return .opened(opened)
            }
            return .outside
        }
    }
}
