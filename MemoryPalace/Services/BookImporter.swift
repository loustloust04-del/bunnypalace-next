import Foundation
import SwiftData
import PDFKit

/// 把外部书文件（txt 等）导进文件库 books/。
///
/// 流程：编码嗅探 → 文本归一化 → 章节切分 → 每章写 chapter_NNNN.txt → 写 index.json → 创建 BookEntry。
///
/// 章节切分（plan-reading-marks P4-A）：逐行认标题，按把握分三档，用得上的最高一档；
/// 一个都认不出才按长度切，而且切在段落 / 换行 / 句号上，标题取那段的第一句（`auto` = 自动分段）。
/// 规范化后的全文存成 `source.txt`，每章记下它在全文里的起止——以后重新分章从全文重切，不丢字。
enum BookImporter {

    enum ImportError: LocalizedError {
        case unreadable(String)
        case unsupportedEncoding
        case emptyText
        case fileTooLarge(Int)
        case duplicateName(String)   // 同 safeName 目录已存在

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): return "无法读取文件：\(detail)"
            case .unsupportedEncoding: return "无法识别文件编码（试过 UTF-8 / GBK / GB18030 都失败）"
            case .emptyText: return "文件内容为空"
            case .fileTooLarge(let bytes): return "文件过大（\(bytes / 1_000_000)MB），第一版限制 50MB"
            case .duplicateName(let name): return "书架里已经有一本《\(name)》了——换个书名再导，或者先删掉旧的"
            }
        }
    }

    static let maxFileBytes = 50 * 1024 * 1024
    static let fallbackChunkSize = 4000

    // MARK: - 编码嗅探

    /// 试 UTF-8 → GBK → GB18030。GBK/GB18030 在 swift 里用 CFStringEncoding 转 String.Encoding。
    static func readTextSniffEncoding(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.isEmpty { throw ImportError.emptyText }

        let candidates: [String.Encoding] = [
            .utf8,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue))),
        ]
        for enc in candidates {
            if let s = String(data: data, encoding: enc), !s.isEmpty {
                // utf8 失败 String 会返回 nil；GBK 一般不返 nil 但可能乱码——
                // 简单启发：含太多 replacement char (\u{FFFD}) 认为是乱码
                let replacementCount = s.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
                if Double(replacementCount) / Double(s.count) < 0.01 { return s }
            }
        }
        throw ImportError.unsupportedEncoding
    }

    // MARK: - 文本归一化

    /// CRLF→LF + 折叠超过 2 个连续换行
    static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
        // 3+ \n → 2
        while t.contains("\n\n\n") {
            t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 章节切分

    struct Chapter {
        let title: String
        let content: String
        /// true = 没认出标题、按长度切出来的段，标题是这段的第一句
        var auto: Bool = false
        /// 这章（含标题行）在规范化全文里的字符起止
        var start: Int = 0
        var end: Int = 0
    }

    /// 用的是哪一档规则（重新分章的预览里告诉你「按什么切的」）
    enum SplitMethod: String {
        case headings, numbered, shortLines, length
        var title: String {
            switch self {
            case .headings: "按章节标题"
            case .numbered: "按编号标题"
            case .shortLines: "按单独成行的短标题"
            case .length: "没认出标题，按段落自动分段"
            }
        }
    }

    struct SplitResult {
        let chapters: [Chapter]
        let method: SplitMethod
        /// 规范化后的全文（存 source.txt）
        let source: String
    }

    static func splitChapters(_ text: String) -> [Chapter] { split(text).chapters }

    /// 一章超过这么多字（标题认出来了但章太长 / 前言太长）→ 再按段落切开，免得网页卡、共读材料截断
    static let maxSectionChars = 60_000

    static func split(_ text: String) -> SplitResult {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return SplitResult(chapters: [], method: .length, source: "") }
        let lines = scanLines(normalized)
        let fenced = fencedLines(lines)
        let levels = lines.indices.map { fenced.contains($0) ? nil : level(of: lines, at: $0) }
        func heads(_ l: HeadingLevel) -> [Int] { lines.indices.filter { levels[$0] == l } }

        var method = SplitMethod.length
        var chosen: [Int] = []
        let strong = dropTableOfContents(heads(.strong), lines: lines)
        let numbered = heads(.numbered)
        let numberedOK = dense(numbered, lines: lines, minCount: 3, meanGap: 800, minGap: 100)
        if !strong.isEmpty {
            // 强标题和编号标题混排（Prologue + 1 / 2 / 3…）：编号那串自己够稀就一起用
            chosen = numberedOK ? (strong + numbered).sorted() : strong
            method = .headings
        } else if numberedOK {
            chosen = numbered
            method = .numbered
        } else {
            let short = heads(.short)
            if dense(short, lines: lines, minCount: 3, meanGap: 1500, minGap: 300) {
                chosen = short
                method = .shortLines
            }
        }

        let chars = Array(normalized)
        guard !chosen.isEmpty else {
            return SplitResult(chapters: chunkByLength(chars, from: 0, to: chars.count), method: .length, source: normalized)
        }

        var result: [Chapter] = []
        // 第一个标题前的东西（书名、作者、题记、序）不管多短都留着；标题不在原文里，都算自动的
        if let pre = trimmedRange(chars, 0, lines[chosen[0]].start) {
            let body = String(chars[pre])
            result += section(chars, title: body.count > 200 ? "序" : firstSentence(body), auto: true,
                              start: pre.lowerBound, body: pre)
        }
        for (i, h) in chosen.enumerated() {
            let line = lines[h]
            let bodyEnd = i + 1 < chosen.count ? lines[chosen[i + 1]].start : chars.count
            if let body = trimmedRange(chars, line.end, bodyEnd) {
                result += section(chars, title: line.trimmed, auto: false, start: line.start, body: body)
            } else {
                result.append(Chapter(title: line.trimmed, content: line.trimmed, start: line.start, end: line.end))
            }
        }
        return SplitResult(chapters: result, method: method, source: normalized)
    }

    /// 一个标题下的一段；太长的再按段落切，第一截留原标题，后面的算自动分段
    private static func section(_ chars: [Character], title: String, auto: Bool, start: Int, body: Range<Int>) -> [Chapter] {
        guard body.count > maxSectionChars else {
            let first = auto ? body.lowerBound : start
            return [Chapter(title: title, content: String(chars[body]), auto: auto, start: first, end: body.upperBound)]
        }
        var pieces = chunkByLength(chars, from: body.lowerBound, to: body.upperBound, size: maxSectionChars / 2)
        guard let head = pieces.first else { return [] }
        pieces[0] = Chapter(title: title, content: head.content, auto: auto, start: auto ? head.start : start, end: head.end)
        return pieces
    }

    /// Markdown 代码块（``` 围起来的）里的行不当标题
    private static func fencedLines(_ lines: [Line]) -> Set<Int> {
        var inside = false
        var out = Set<Int>()
        for (i, l) in lines.enumerated() {
            if l.trimmed.hasPrefix("```") {
                out.insert(i)
                inside.toggle()
            } else if inside {
                out.insert(i)
            }
        }
        return inside ? [] : out   // 没闭合就当没有代码块
    }

    // MARK: 行

    struct Line {
        let trimmed: String
        /// 行首 / 行尾（不含换行）的字符 offset
        let start: Int
        let end: Int
        let blankBefore: Bool
        let blankAfter: Bool
    }

    private static func scanLines(_ text: String) -> [Line] {
        let raw = text.components(separatedBy: "\n")
        var out: [Line] = []
        var offset = 0
        for (i, l) in raw.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            let before = i == 0 || raw[i - 1].trimmingCharacters(in: .whitespaces).isEmpty
            let after = i == raw.count - 1 || raw[i + 1].trimmingCharacters(in: .whitespaces).isEmpty
            out.append(Line(trimmed: t, start: offset, end: offset + l.count, blankBefore: before, blankAfter: after))
            offset += l.count + 1
        }
        return out
    }

    enum HeadingLevel { case strong, numbered, short }

    private static let cnNum = "[一二三四五六七八九十百千万零〇两0-9０-９]+"
    private static let enNum = "(?:[0-9]+|[IVXLCDM]+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty(?:[- ](?:one|two|three|four|five|six|seven|eight|nine))?|thirty|forty|fifty)"
    private static let strongPatterns: [NSRegularExpression] = [
        "^第\\s*\(cnNum)\\s*[章节節卷回篇幕集部](?:[\\s：:·．.、—-].{0,40}|.{0,40})$",
        "^卷\\s*\(cnNum)(?:[\\s：:·．.、—-].{0,40})?$",
        "^(?:楔子|序章|序言|序|引子|引言|前言|尾声|尾聲|后记|後記|终章|終章|番外[一二三四五六七八九十0-9]*|附录|附錄)(?:[\\s：:·—-].{0,30})?$",
        "^(?:chapter|part|book)\\s+\(enNum)\\b.{0,60}$",
        "^(?:prologue|epilogue|preface|introduction|afterword|interlude)\\b.{0,50}$",
        "^#{1,3}\\s+\\S.{0,60}$",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let numberedPatterns: [NSRegularExpression] = [
        "^[0-9０-９]{1,3}[.．、]?$",
        "^[IVXLC]{1,7}\\.?$",
        "^(?i:\(enNum))$",
        "^[一二三四五六七八九十百]{1,4}(?:[、.．]\\s*\\S.{0,20})?$",
    ].map { try! NSRegularExpression(pattern: $0, options: []) }
    private static let sentenceEnd: Set<Character> = ["。", "！", "？", "…", "，", "、", "；", "：", ".", "!", "?", ",", ";", ":", "”", "」", "\"", "'"]

    private static func matches(_ res: [NSRegularExpression], _ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return res.contains { $0.firstMatch(in: s, range: r) != nil }
    }

    static func level(of lines: [Line], at i: Int) -> HeadingLevel? {
        let t = lines[i].trimmed
        guard !t.isEmpty, t.count <= 60 else { return nil }
        // 以句号结尾的是正文（「第三节课下课后，他说。」），不是标题；问号 / 感叹号结尾的短行可以是章名（「第十章 你是谁？」）
        let endsLikeProse = t.last.map { "。…，,".contains($0) || ("！？!?.".contains($0) && t.count > 20) } ?? false
        if matches(strongPatterns, t), !endsLikeProse || t.hasPrefix("#") { return .strong }
        if matches(numberedPatterns, t) { return .numbered }
        let line = lines[i]
        if (1...20).contains(t.count), line.blankBefore, line.blankAfter,
           let last = t.last, !sentenceEnd.contains(last),
           let first = t.first, !"“「『\"'（(—-*".contains(first) {
            return .short
        }
        return nil
    }

    /// 开头的目录：书的前 10% 里连着 ≥3 个标题、每个底下几乎没字，而且这些标题后面又原样出现 → 这一串是目录不是章节。
    /// 书中间连着几个很短的章不会被当成目录
    private static func dropTableOfContents(_ heads: [Int], lines: [Line]) -> [Int] {
        guard heads.count >= 3, let total = lines.last?.end else { return heads }
        func bodyChars(_ k: Int) -> Int {
            let next = k + 1 < heads.count ? heads[k + 1] : lines.count
            return lines[(heads[k] + 1)..<next].reduce(0) { $0 + $1.trimmed.count }
        }
        var run: [Int] = []
        for k in heads.indices {
            guard lines[heads[k]].start <= total / 10, bodyChars(k) < 10 else {
                if run.count >= 3 { break }
                run = []
                continue
            }
            run.append(k)
        }
        guard run.count >= 3, let last = run.last else { return heads }
        let later = Set(heads[(last + 1)...].map { lines[$0].trimmed })
        let repeated = run.filter { later.contains(lines[heads[$0]].trimmed) }.count
        guard repeated * 2 >= run.count else { return heads }
        let drop = Set(run)
        let kept = heads.indices.filter { !drop.contains($0) }.map { heads[$0] }
        return kept.isEmpty ? heads : kept
    }

    /// 编号 / 短行标题要够「稀」才算数，挡住正文里的编号列表
    private static func dense(_ heads: [Int], lines: [Line], minCount: Int, meanGap: Int, minGap: Int) -> Bool {
        guard heads.count >= minCount else { return false }
        let gaps = zip(heads, heads.dropFirst()).map { lines[$1].start - lines[$0].end }
        guard let smallest = gaps.min() else { return false }
        return smallest >= minGap && gaps.reduce(0, +) / gaps.count >= meanGap
    }

    // MARK: 按长度切（没有标题时）

    /// 每段最多 size 字（默认 fallbackChunkSize）；在最后 1500 字里找切点：空行 → 换行 → 句末 → 实在没有才硬切
    private static func chunkByLength(_ chars: [Character], from: Int, to: Int, size: Int = fallbackChunkSize) -> [Chapter] {
        var result: [Chapter] = []
        var start = from
        while start < to {
            var end = min(start + size, to)
            if end < to {
                let floor = max(start + size - 1500, start + 1)
                end = cutPoint(chars, floor: floor, ceil: end) ?? end
            }
            if let r = trimmedRange(chars, start, end) {
                let body = String(chars[r])
                result.append(Chapter(title: firstSentence(body), content: body, auto: true,
                                      start: r.lowerBound, end: r.upperBound))
            }
            start = end
        }
        return result
    }

    private static func cutPoint(_ chars: [Character], floor: Int, ceil: Int) -> Int? {
        func last(_ ok: (Int) -> Bool) -> Int? {
            var i = ceil - 1
            while i >= floor { if ok(i) { return i + 1 }; i -= 1 }
            return nil
        }
        return last { chars[$0] == "\n" && $0 > 0 && chars[$0 - 1] == "\n" }
            ?? last { chars[$0] == "\n" }
            ?? last { "。！？!?…".contains(chars[$0]) || (chars[$0] == "." && $0 + 1 < chars.count && chars[$0 + 1] == " ") }
    }

    /// 去掉两头空白后的区间；全是空白返回 nil
    private static func trimmedRange(_ chars: [Character], _ from: Int, _ to: Int) -> Range<Int>? {
        var a = from, b = to
        while a < b, chars[a].isWhitespace { a += 1 }
        while b > a, chars[b - 1].isWhitespace { b -= 1 }
        return a < b ? a..<b : nil
    }

    /// 自动分段的标题：这段第一句，最多 16 个字
    static func firstSentence(_ body: String) -> String {
        let firstLine = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? body
        var s = firstLine.trimmingCharacters(in: .whitespaces)
        if let cut = s.firstIndex(where: { "。！？!?；;".contains($0) }) { s = String(s[..<cut]) }
        return s.count > 16 ? String(s.prefix(16)) + "…" : s
    }

    // MARK: - 主入口

    struct ImportResult {
        let safeName: String
        let totalChapters: Int
        let totalChars: Int
    }

    /// 导入一个 txt 文件——**async**，IO 重活在后台 queue，SwiftData 写回 MainActor。
    ///
    /// - parameter url: 源文件本地路径
    /// - parameter bookName: 显示书名（用户填）
    /// - parameter author: 作者（可空）
    /// - parameter profileId: 当前楼层
    /// - parameter context: SwiftData ctx（用来插 BookEntry）— **必须是 MainActor 上的 ctx**
    /// - parameter progress: 进度回调（@MainActor，可安全更新 UI）
    /// CR-7：PDF 导入——原文件拷入 books/{safe}/book.pdf（不转不抽），
    /// index.json：章节表 = outline 顶层条目（tap 跳页），无 outline 退化为空表（纯页码导航）。
    /// hasTextLayer 抽样检测（前中后 12 页），false = 扫描版（批注走框选+OCR 路线）。
    static let maxPDFBytes = 500 * 1024 * 1024

    static func importPDF(
        url: URL,
        bookName: String,
        author: String = "",
        profileId: String,
        context: ModelContext,
        progress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ImportResult {
        let safeName = BookStore.safeName(bookName)
        let bookDir = BookStore.bookDir(safeName: safeName, profileId: profileId)
        if FileManager.default.fileExists(atPath: bookDir.path) {
            throw ImportError.duplicateName(bookName)
        }

        await progress?("读取 PDF…")

        let (pageCount, outlineChapters, hasText) = try await Task.detached(priority: .userInitiated) { () -> (Int, [BookStore.ChapterMeta], Bool) in
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > maxPDFBytes {
                throw ImportError.fileTooLarge(size)
            }
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
                throw ImportError.emptyText
            }

            // outline 顶层 → 章节表（no = 1-based 页码）
            var chapters: [BookStore.ChapterMeta] = []
            if let root = doc.outlineRoot {
                for i in 0..<root.numberOfChildren {
                    guard let child = root.child(at: i),
                          let label = child.label, !label.isEmpty,
                          let page = child.destination?.page,
                          let pageIdx = doc.index(for: page) as Int? else { continue }
                    chapters.append(.init(no: pageIdx + 1, title: label, chars: 0))
                }
            }

            // 文本层抽样：前/中/后各几页，任一页有实质文本即视为有文本层
            var sampled = 0
            let count = doc.pageCount
            let samples = [0, 1, 2, count / 4, count / 2, count * 3 / 4, count - 3, count - 2, count - 1,
                           count / 8, count * 3 / 8, count * 5 / 8].filter { $0 >= 0 && $0 < count }
            for idx in Set(samples) {
                sampled += doc.page(at: idx)?.string?.count ?? 0
            }

            // 扫描版抽样恒为 0，阈值只需挡住零星 OCR 噪声/页眉水印
            return (count, chapters, sampled > 100)
        }.value

        await progress?("拷贝文件…\(pageCount) 页")

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: bookDir.appendingPathComponent("book.pdf"))
            let now = Date()
            var index = BookStore.BookIndex(
                name: bookName,
                author: author,
                format: "pdf",
                createdAt: now,
                updatedAt: now,
                currentChapter: 1,          // PDF 语义 = 当前页（1-based）
                scrollRatio: 0,
                totalChapters: pageCount,   // PDF 语义 = 总页数
                chapters: outlineChapters
            )
            index.hasTextLayer = hasText
            try BookStore.saveIndex(index, safeName: safeName, profileId: profileId)
            try BookStore.saveNotes([], safeName: safeName, profileId: profileId)
        }.value

        await progress?("完成")

        await MainActor.run {
            BookStore.refreshEntries(profileId: profileId, context: context)
        }
        return ImportResult(safeName: safeName, totalChapters: pageCount, totalChars: 0)
    }

    static func importTxt(
        url: URL,
        bookName: String,
        author: String = "",
        profileId: String,
        context: ModelContext,
        progress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ImportResult {
        // ① 查重——同 safeName 目录已存在 → 拒绝覆盖（爸爸 batch B1）
        let safeName = BookStore.safeName(bookName)
        let bookDir = BookStore.bookDir(safeName: safeName, profileId: profileId)
        if FileManager.default.fileExists(atPath: bookDir.path) {
            throw ImportError.duplicateName(bookName)
        }

        await progress?("读取文件…")

        // ② IO 重活全部 detach 到后台（爸爸 batch B3）
        let result = try await Task.detached(priority: .userInitiated) { () -> SplitResult in
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > maxFileBytes {
                throw ImportError.fileTooLarge(size)
            }
            let raw = try readTextSniffEncoding(url)
            let r = split(raw)
            if r.chapters.isEmpty { throw ImportError.emptyText }
            return r
        }.value
        let chapters = result.chapters

        await progress?("切分章节… \(chapters.count) 章")

        // ③ 写盘也走后台
        try await Task.detached(priority: .userInitiated) { [chapters, result] in
            // 章节 + 规范化全文（以后重新分章从它重切，P4-A）
            let chapterMeta = try BookStore.writeChapters(result, into: bookDir)
            let now = Date()
            let index = BookStore.BookIndex(
                name: bookName,
                author: author,
                format: "txt",
                createdAt: now,
                updatedAt: now,
                currentChapter: 1,
                scrollRatio: 0,
                totalChapters: chapters.count,
                chapters: chapterMeta
            )
            try BookStore.saveIndex(index, safeName: safeName, profileId: profileId)
            try BookStore.saveNotes([], safeName: safeName, profileId: profileId)
        }.value

        await progress?("写入文件库…完成")

        // ④ SwiftData 写回 MainActor
        await MainActor.run {
            BookStore.refreshEntries(profileId: profileId, context: context)
        }

        let totalChars = chapters.reduce(0) { $0 + $1.content.count }
        return ImportResult(safeName: safeName, totalChapters: chapters.count, totalChars: totalChars)
    }
}
