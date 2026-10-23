import Foundation
import SwiftData

/// CR-4 P3：AI 读书产物落地（agent_book_note payload → 书批注 + 主对话消息）。
/// - 批注：anchorText 在章文本流（title+段落 join，与批注 offset 同域）搜索定位，
///   **唯一命中才收**（零命中=AI 幻觉引用 / 多命中=定位歧义，都丢弃——宁缺毋滥）
/// - 回批注：replyToAnchor 命中她的批注（contains 匹配，容 reading_context 的 120 字截断）→ 挂 replyTo 成串
/// - 消息：复用 AgentOutboxDrainer 消息对插入（agentOrigin=uuid 查重）
enum AgentBookNoteWriter {

    /// 返回 true = payload 处理完成可 ack。个别批注定位失败丢弃不影响整体成功；
    /// 书不存在/楼层不对返回 false（不 ack，hub 补投重试）。
    @discardableResult
    static func handle(_ payload: [String: Any], context: ModelContext) -> Bool {
        guard let uuid = payload["uuid"] as? String, !uuid.isEmpty,
              let safeName = payload["safeName"] as? String, !safeName.isEmpty,
              let floorId = payload["floorId"] as? String, !floorId.isEmpty,
              let chapter = payload["chapter"] as? Int else { return false }
        let notesRaw = payload["notes"] as? [[String: Any]] ?? []
        let message = payload["message"] as? String ?? ""

        var wroteNotes = false
        if !notesRaw.isEmpty {
            guard let wrote = writeBookNotes(
                notesRaw, safeName: safeName, chapter: chapter, profileId: floorId
            ) else { return false }   // 书/章不存在 → 不 ack 等重试（可能装包/迁移间隙）
            wroteNotes = wrote
        }

        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let bookName = payload["bookName"] as? String ?? safeName
            let pair = AgentOutboxDrainer.Payload(
                v: 1, uuid: uuid, triggerId: "reader-daemon", floorId: floorId,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                userSeed: "（共读 ·《\(bookName)》第 \(chapter) 章）",
                assistantText: message
            )
            _ = AgentOutboxDrainer.insert(pair, context: context)   // 查重内建；无落点也算处理过
        }

        if wroteNotes {
            NotificationCenter.default.post(
                name: .bookNotesDidChange, object: nil, userInfo: ["safeName": safeName]
            )
        }
        return true
    }

    // MARK: - R2 聊天内批注意向（```book-note 块 → 锚定落地 → 替换成结果行）

    private static let intentRegex = try! NSRegularExpression(
        pattern: "```book-note\\s*\\n([\\s\\S]*?)```",
        options: []
    )

    /// assistant turn 收口时调：扫消息里的 book-note 块逐条锚定落地，
    /// 块替换成可读结果行（流式期间块本身可见 = 「TA 在写批注」，落地后变结果）。
    /// 无块零成本；替换后不再含块 = 天然幂等。
    static func processChatIntents(nodeId: String, context: ModelContext) {
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        guard let node = (try? context.fetch(nodeDesc))?.first,
              node.role == "assistant",
              node.content.contains("```book-note") else { return }

        let content = node.content
        let ns = content as NSString
        let matches = intentRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }

        var touchedBooks = Set<String>()
        var newContent = content
        // 倒序替换保 range 有效
        for m in matches.reversed() {
            let jsonStr = ns.substring(with: m.range(at: 1))
            let replacement = applyIntent(jsonStr, profileId: node.profileId, touchedBooks: &touchedBooks)
            newContent = (newContent as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        node.content = newContent
        try? context.save()

        for safeName in touchedBooks {
            NotificationCenter.default.post(
                name: .bookNotesDidChange, object: nil, userInfo: ["safeName": safeName]
            )
        }
    }

    /// 单条意向落地，返回替换进消息的结果行。
    private static func applyIntent(_ jsonStr: String, profileId: String, touchedBooks: inout Set<String>) -> String {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let book = obj["book"] as? String, !book.isEmpty,
              let chapter = obj["chapter"] as? Int,
              let anchor = (obj["anchorText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !anchor.isEmpty,
              let comment = (obj["comment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !comment.isEmpty else {
            return "📖 批注格式无效，未落地"
        }
        var note: [String: Any] = ["anchorText": anchor, "comment": comment]
        if let ra = obj["replyToAnchor"] as? String, !ra.isEmpty { note["replyToAnchor"] = ra }

        let wrote = writeBookNotes([note], safeName: book, chapter: chapter, profileId: profileId)
        let bookName = BookStore.loadIndex(safeName: book, profileId: profileId)?.name ?? book
        switch wrote {
        case nil:
            return "📖 批注未落地（找不到《\(bookName)》第 \(chapter) 章）"
        case .some(true):
            touchedBooks.insert(book)
            return "📖 已在《\(bookName)》第 \(chapter) 章留下批注：「\(comment.prefix(60))\(comment.count > 60 ? "…" : "")」"
        case .some(false):
            return "📖 批注未落地（引用与原文不符或已存在）：「\(anchor.prefix(40))…」"
        }
    }

    /// nil = 书/章文件缺失（整体不可处理）；true/false = 是否至少写入一条。
    private static func writeBookNotes(
        _ raw: [[String: Any]], safeName: String, chapter: Int, profileId: String
    ) -> Bool? {
        guard let idx = BookStore.loadIndex(safeName: safeName, profileId: profileId) else { return nil }
        // CR-7 P3：PDF 书走保真锚定（chapter 语义 = 页码，quote 在 OCR 行缓存命中 → rects）
        if idx.format == "pdf" {
            return writeFidelityNotes(raw, safeName: safeName, page: chapter, profileId: profileId)
        }
        guard let meta = idx.chapters.first(where: { $0.no == chapter }),
              let text = BookStore.loadChapterText(safeName: safeName, chapterNo: chapter, profileId: profileId)
        else { return nil }

        let flow = meta.title + ChapterHTMLRenderer.splitParagraphs(text).joined()
        var all = BookStore.loadNotes(safeName: safeName, profileId: profileId)
        var wrote = false

        for n in raw {
            guard let anchor = (n["anchorText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !anchor.isEmpty,
                  let comment = (n["comment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !comment.isEmpty,
                  let range = uniqueRange(of: anchor, in: flow) else { continue }

            // 幂等：同锚同话的 AI 批注已存在（重复投递的部分处理场景）不再写
            if all.contains(where: { $0.role == "ai" && $0.anchorText == anchor && $0.content == comment }) { continue }

            var replyTo: String? = nil
            if let ra = (n["replyToAnchor"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ra.isEmpty {
                // 重复划线后可能命中好几处：挂到最新那处（plan-reading-marks §1 归组）
                replyTo = all.filter {
                    $0.role == "user" && $0.replyTo == nil && $0.chapter == chapter &&
                    ($0.anchorText.contains(ra) || ra.contains($0.anchorText))
                }.max { $0.createdAt < $1.createdAt }?.id
            }

            all.append(BookStore.Note(
                id: UUID().uuidString, chapter: chapter, anchorText: anchor,
                anchorStart: range.lowerBound, anchorEnd: range.upperBound,
                kind: "note", content: comment, role: "ai", messageId: nil,
                createdAt: Date(), replyTo: replyTo
            ))
            wrote = true
        }

        if wrote {
            try? BookStore.saveNotes(all, safeName: safeName, profileId: profileId)
        }
        return wrote
    }

    // MARK: - CR-7 P3：PDF 保真锚定

    /// PDF 书批注落地：quote 在页窗口（page±1，daemon 材料窗口同款）的 OCR 行里
    /// 归一化唯一命中 → 命中行 bbox 落 rects。窗口内任何页缓存缺失不算失败
    /// （跳过该页）；quote 全窗口零/多命中 → 该条丢弃（宁缺毋滥，与 txt 同则）。
    private static func writeFidelityNotes(
        _ raw: [[String: Any]], safeName: String, page: Int, profileId: String
    ) -> Bool? {
        guard page >= 1 else { return nil }
        var all = BookStore.loadNotes(safeName: safeName, profileId: profileId)
        var wrote = false

        for n in raw {
            guard let anchor = (n["anchorText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !anchor.isEmpty,
                  let comment = (n["comment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !comment.isEmpty,
                  let hit = fidelityAnchor(quote: anchor, safeName: safeName, aroundPage: page, profileId: profileId)
            else { continue }

            if all.contains(where: { $0.role == "ai" && $0.anchorText == anchor && $0.content == comment }) { continue }

            var replyTo: String? = nil
            if let ra = (n["replyToAnchor"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !ra.isEmpty {
                replyTo = all.filter {
                    $0.role == "user" && $0.replyTo == nil && $0.chapter == hit.page &&
                    ($0.anchorText.contains(ra) || ra.contains($0.anchorText))
                }.max { $0.createdAt < $1.createdAt }?.id
            }

            var note = BookStore.Note(
                id: UUID().uuidString, chapter: hit.page, anchorText: anchor,
                anchorStart: 0, anchorEnd: 0,
                kind: "note", content: comment, role: "ai", messageId: nil,
                createdAt: Date(), replyTo: replyTo
            )
            note.rects = hit.rects
            all.append(note)
            wrote = true
        }

        if wrote {
            try? BookStore.saveNotes(all, safeName: safeName, profileId: profileId)
        }
        return wrote
    }

    /// quote → (页码, 命中行 bbox 组)。页窗口 ±1 内归一化（去空白）匹配，
    /// 全窗口总命中必须恰好 1。
    static func fidelityAnchor(
        quote: String, safeName: String, aroundPage: Int, profileId: String
    ) -> (page: Int, rects: [[Double]])? {
        let target = normalized(quote)
        guard !target.isEmpty else { return nil }
        var found: (page: Int, rects: [[Double]])? = nil
        for p in max(1, aroundPage - 1)...(aroundPage + 1) {
            guard let lines = OCRStore.cachedLines(safeName: safeName, profileId: profileId, page: p),
                  !lines.isEmpty else { continue }
            for span in matchSpans(target: target, lines: lines) {
                if found != nil { return nil }   // 跨窗口多命中 → 歧义，弃
                found = (p, span)
            }
        }
        return found
    }

    /// 单页内匹配：行文本去空白拼接 + 记录每行的归一化字符区间 →
    /// 所有命中位置映射回覆盖的行 bbox 集合。
    private static func matchSpans(target: [Character], lines: [OCRStore.Line]) -> [[[Double]]] {
        var flow: [Character] = []
        var lineRanges: [(range: Range<Int>, bbox: [Double])] = []
        for line in lines where line.bbox.count == 4 {
            let chars = normalized(line.text)
            guard !chars.isEmpty else { continue }
            let start = flow.count
            flow.append(contentsOf: chars)
            lineRanges.append((start..<flow.count, line.bbox))
        }
        guard target.count <= flow.count else { return [] }

        var spans: [[[Double]]] = []
        var i = 0
        while i <= flow.count - target.count {
            var match = true
            for j in 0..<target.count where flow[i + j] != target[j] {
                match = false
                break
            }
            if match {
                let hitRange = i..<(i + target.count)
                let rects = lineRanges.filter { $0.range.overlaps(hitRange) }.map(\.bbox)
                if !rects.isEmpty { spans.append(rects) }
                if spans.count > 1 { return spans }   // 两个就够判歧义了
            }
            i += 1
        }
        return spans
    }

    /// 归一化：去所有空白（OCR 换行/空格与 AI 引用的差异容错）。
    private static func normalized(_ s: String) -> [Character] {
        Array(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init))
    }

    /// 章文本流内唯一命中的字符 offset 区间（与批注 offset 同域）。零/多命中 → nil。
    static func uniqueRange(of needle: String, in flow: String) -> Range<Int>? {
        let chars = Array(flow)
        let target = Array(needle)
        guard !target.isEmpty, target.count <= chars.count else { return nil }
        var found: Int? = nil
        var i = 0
        while i <= chars.count - target.count {
            var match = true
            for j in 0..<target.count where chars[i + j] != target[j] {
                match = false
                break
            }
            if match {
                if found != nil { return nil }   // 多命中 → 定位歧义，弃
                found = i
            }
            i += 1
        }
        guard let s = found else { return nil }
        return s..<(s + target.count)
    }
}
