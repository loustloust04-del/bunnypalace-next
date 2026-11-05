import Foundation

/// 整理记录（`.runs/`）只读预览的数据：后台解析一次，原生列表直接用。
/// 每轮一个标题行；节里的叙述原地显示；每个代码块（请求原文、工具回执、参数）都折成一张卡，点开弹 sheet 看全文（粟粟 10-22）。
/// 只有这里用，不给别处当通用组件。
/// 10-23 粟粟：整理提案目录项的原料全文「依旧复用看 log 的页面办法」——`WikiProposalItemPage` 直接拼一份喂进来（每份原料一张卡）。
struct RunRecordDocument: Sendable {
    struct Block: Identifiable, Sendable {
        let id: Int
        /// 卡上的名字：紧挨着的「正文：」「### 系统提示」这类标签，没有就用语言，再没有写「原文」
        let name: String
        let language: String
        /// 围栏里的原文（不含围栏行和最后那个换行），复制 / sheet 都用它
        let text: String
        let count: Int
        /// 第一行非空内容（卡上单行截断）
        let summary: String
        /// sheet 顶上标的一行（整理提案的原料：「这份原料在提案之后改过」）；整理记录不用
        var note: String? = nil
        /// 一律折成卡（整理提案的原料：短到一行也要看得见名字）；整理记录不用
        var alwaysCard = false

        var icon: String { language.lowercased() == "json" ? "curlybraces" : "doc.plaintext" }
    }

    enum Row: Sendable {
        case heading(String, level: Int)
        case prose(String)
        case block(Block)
    }

    let id = UUID()
    let rows: [Row]
    /// 每节第一行在 rows 里的下标（节 = `<a id>` 分出来的段）
    let sectionStarts: [Int]
    /// 指定轮次那一节的标题行；没指定或没找到是 nil
    let targetRow: Int?

    var blocks: [Block] {
        rows.compactMap { if case .block(let b) = $0 { return b } else { return nil } }
    }

    // MARK: - 后台解析（可取消）

    /// 测试用：每次解析结束报一声（true = 被取消）
    nonisolated(unsafe) static var parseObserver: ((Bool) -> Void)?
    /// 测试用：每个取消检查点报一声（确定性地「扫到一半取消」）
    nonisolated(unsafe) static var checkpointObserver: (() -> Void)?

    /// 关页 / 换文件 = 外层 task 取消 → 后台解析在下一个检查点停：分行每 64KB、分节 / 拆围栏 / 叙述 / 摘要逐行都查，
    /// 返回前再查一次；被取消就抛错，不交结果
    static func load(content: String, anchor: String?) async throws -> RunRecordDocument {
        let job = Task.detached(priority: .userInitiated) { try parse(content: content, anchor: anchor) }
        let document = try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
        try Task.checkCancellation()
        return document
    }

    static func parse(content: String, anchor: String?) throws -> RunRecordDocument {
        do {
            let check: () throws -> Void = {
                checkpointObserver?()
                try Task.checkCancellation()
            }
            let document = try parseSections(content: content, anchor: anchor, check: check)
            try check()
            parseObserver?(false)
            return document
        } catch {
            parseObserver?(true)
            throw error
        }
    }

    private static func parseSections(content: String, anchor: String?, check: () throws -> Void) throws -> RunRecordDocument {
        try check()
        let location = try FileEditorPreviewLocation(content: content, anchor: anchor, separatesSections: true, check: check)
        var rows: [Row] = []
        var starts: [Int] = []
        var target: Int?
        for (index, part) in location.parts.enumerated() {
            try check()
            starts.append(rows.count)
            var label: String?
            for segment in try segments(Substring(part), check: check) {
                try check()
                switch segment {
                case .prose(let raw):
                    try appendProse(raw, to: &rows, label: &label, check: check)
                case .code(_, let body, let close, let fence):
                    let text = codeText(body, closed: close != nil)
                    let id = rows.count
                    let name = label ?? (fence.language.isEmpty ? "原文" : fence.language)
                    rows.append(.block(Block(id: id, name: name, language: fence.language, text: text,
                                             count: text.count, summary: try summary(text, check: check))))
                    label = nil
                }
            }
            if index == location.targetIndex, rows.count > starts[index] {
                target = rows[starts[index]...].firstIndex { if case .heading = $0 { return true } else { return false } } ?? starts[index]
            }
        }
        return RunRecordDocument(rows: rows, sectionStarts: starts, targetRow: target)
    }

    // MARK: - 节内拆围栏（原始区间，拼回逐字节 = 原文）

    enum Segment {
        case prose(Substring)
        case code(open: Substring, body: Substring, close: Substring?, fence: RunRecordScanner.Fence)
    }

    static func segments(_ section: Substring, check: () throws -> Void) rethrows -> [Segment] {
        var out: [Segment] = []
        var state = RunRecordScanner.FenceState()
        var proseStart = section.startIndex
        var open: (line: Substring, fence: RunRecordScanner.Fence)?
        var bodyStart = section.startIndex
        for line in try RunRecordScanner.lines(section, check: check) {
            try check()
            switch state.feed(line.content) {
            case .opened(let fence):
                if proseStart < line.full.startIndex { out.append(.prose(section[proseStart..<line.full.startIndex])) }
                open = (line.full, fence)
                bodyStart = line.full.endIndex
            case .closed:
                if let open {
                    out.append(.code(open: open.line, body: section[bodyStart..<line.full.startIndex], close: line.full, fence: open.fence))
                }
                open = nil
                proseStart = line.full.endIndex
            case .inside, .outside:
                break
            }
        }
        if let open {
            out.append(.code(open: open.line, body: section[bodyStart...], close: nil, fence: open.fence))
        } else if proseStart < section.endIndex {
            out.append(.prose(section[proseStart...]))
        }
        return out
    }

    /// 围栏正文 → 原文：只剥写入器（`CatalogRunRecord.code`）在原文后面追加、闭栏前的那一个 LF 字节。
    /// 按字节剥：原文 "A\r" 包装后末尾是 CR LF（一个字符簇），按 Character 删会把原文的 CR 一起删掉；
    /// 没闭栏的围栏没有这个分隔符，一个字节都不剥（astra 审 97d41cbab P1）
    static func codeText(_ body: Substring, closed: Bool) -> String {
        guard closed, body.utf8.last == 0x0A else { return String(body) }
        return String(decoding: body.utf8.dropLast(), as: UTF8.self)
    }

    /// 第一行非空内容；不切整块，找到就停（大块也只扫到第一行）
    private static func summary(_ text: String, check: () throws -> Void) throws -> String {
        let bytes = text.utf8
        var start = bytes.startIndex
        var i = start
        var scanned = 0
        while true {
            let atEnd = i == bytes.endIndex
            if atEnd || bytes[i] == 0x0A || bytes[i] == 0x0D {
                let trimmed = text[start..<i].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
                if atEnd { return "" }
                var next = bytes.index(after: i)
                if bytes[i] == 0x0D, next < bytes.endIndex, bytes[next] == 0x0A { next = bytes.index(after: next) }
                start = next
                i = next
            } else {
                i = bytes.index(after: i)
            }
            scanned += 1
            if scanned == RunRecordScanner.checkEveryBytes {
                scanned = 0
                try check()
            }
        }
    }

    // MARK: - 叙述：标题行单列，段落按空行分行；`<a id>` 不显示

    private static func appendProse(_ raw: Substring, to rows: inout [Row], label: inout String?, check: () throws -> Void) throws {
        var paragraph: [Substring] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            rows.append(.prose(paragraph.joined(separator: "\n")))
            label = labelLine(paragraph.last!)
            paragraph = []
        }
        for line in try RunRecordScanner.lines(raw, check: check) {
            try check()
            let content = line.content
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if RunRecordScanner.isAnchor(content) { continue }
            if trimmed.isEmpty {
                flush()
            } else if let heading = RunRecordScanner.heading(content) {
                flush()
                rows.append(.heading(heading.text, level: heading.level))
                label = heading.text.isEmpty ? nil : heading.text
            } else {
                paragraph.append(content)
                label = nil
            }
        }
        flush()
    }

    /// 「正文：」「argumentsJSON：」这种短标签才拿来给下面的卡起名
    private static func labelLine(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 40, let last = trimmed.last, last == "：" || last == ":" else { return nil }
        let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
