import Foundation
import SwiftSoup

/// Google Takeout → My Activity → Gemini Apps（JSON 或 HTML）→ 对话 payload（#047，实验性）。
/// 活动记录不是会话树：有 `gemini.google.com/app/<id>` 链接的按链接聚，没有的按时间间隔推测切（plan D1/D2）。
enum GeminiTakeoutParser {
    static let provider = "gemini"
    static let sessionGap: TimeInterval = 30 * 60

    struct Activity {
        var key = ""
        var sourceIndex: Int
        var timeRaw: String?
        var time: Date?
        var title: String?
        var prompt: String?
        var responseMarkdown: String?
        var firstResponseHTML = ""
        var attachments: [String] = []
        var chatId: String?
        var chatURL: String?
        var raw: Data?
    }

    // MARK: - 识别

    static func isTakeoutJSON(_ root: Any) -> Bool {
        guard let records = root as? [Any], !records.isEmpty else { return false }
        return records.contains { record in
            guard let dict = record as? [String: Any], dict["time"] != nil || dict["header"] != nil else { return false }
            return isGeminiRecord(dict)
        }
    }

    static func isTakeoutHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2 * 1024 * 1024), as: UTF8.self)
        return head.contains("outer-cell") && head.range(of: "gemini", options: .caseInsensitive) != nil
    }

    static func isGeminiRecord(_ dict: [String: Any]) -> Bool {
        if let header = dict["header"] as? String, header.range(of: "gemini", options: .caseInsensitive) != nil { return true }
        let products = dict["products"] as? [String] ?? []
        return products.contains { $0.range(of: "gemini", options: .caseInsensitive) != nil }
    }

    /// 扫描器认过的文件：开头是 `[` 走 JSON，否则按 HTML（直接选中的文件扩展名不可信）
    static func parse(file url: URL, calendar: Calendar = .current) throws -> GeminiImportResult {
        let data = try ExportJSON.data(at: url)
        let first = data.first { !(Character(UnicodeScalar($0)).isWhitespace) }
        return first == UInt8(ascii: "[") ? try parseJSON(data: data, calendar: calendar) : try parseHTML(data: data, calendar: calendar)
    }

    // MARK: - JSON 入口

    static func parseJSON(data: Data, calendar: Calendar = .current) throws -> GeminiImportResult {
        guard let root = GeminiImportSupport.jsonObject(data), isTakeoutJSON(root), let records = root as? [Any] else {
            throw GeminiImportError.notRecognized
        }
        var result = GeminiImportResult()
        var activities: [Activity] = []
        for (index, record) in records.enumerated() {
            guard let dict = record as? [String: Any] else { continue }
            guard isGeminiRecord(dict) else {
                result.otherProductCount += 1
                continue
            }
            activities.append(activity(fromJSON: dict, index: index))
        }
        build(activities, into: &result, calendar: calendar)
        return result
    }

    static func activity(fromJSON dict: [String: Any], index: Int) -> Activity {
        let title = dict["title"] as? String
        var activity = Activity(sourceIndex: index, timeRaw: dict["time"] as? String, title: title)
        activity.time = GeminiImportSupport.parseISO(activity.timeRaw)

        let subtitles = (dict["subtitles"] as? [[String: Any]]) ?? []
        activity.prompt = promptFromTitle(title) ?? nonEmpty(subtitles.compactMap { $0["value"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n"))

        let htmls = ((dict["safeHtmlItem"] as? [[String: Any]]) ?? []).compactMap { $0["html"] as? String }
        activity.firstResponseHTML = htmls.first ?? ""
        activity.responseMarkdown = nonEmpty(htmls.map(GeminiHTMLToMarkdown.convert).filter { !$0.isEmpty }.joined(separator: "\n\n"))

        var urls: [String] = []
        if let titleUrl = dict["titleUrl"] as? String { urls.append(titleUrl) }
        for list in [dict["details"], dict["subtitles"]] {
            urls += ((list as? [[String: Any]]) ?? []).compactMap { $0["url"] as? String }
        }
        if let (id, url) = urls.lazy.compactMap({ u in chatId(fromURL: u).map { ($0, u) } }).first {
            activity.chatId = id
            activity.chatURL = url
        }

        if let image = dict["imageFile"] as? String, !image.isEmpty { activity.attachments.append(image) }
        activity.attachments += ((dict["attachedFiles"] as? [Any]) ?? []).compactMap { item in
            (item as? String) ?? ((item as? [String: Any])?["name"] as? String)
        }.filter { !$0.isEmpty }

        activity.raw = GeminiImportSupport.jsonData(dict)
        return activity
    }

    // MARK: - HTML 入口（尽力而为，plan D3）

    static func parseHTML(data: Data, calendar: Calendar = .current) throws -> GeminiImportResult {
        let html = String(decoding: GeminiImportSupport.strippingBOM(data), as: UTF8.self)
        guard let doc = try? SwiftSoup.parse(html), let cells = try? doc.select("div.outer-cell").array(), !cells.isEmpty else {
            throw GeminiImportError.notRecognized
        }
        var result = GeminiImportResult()
        var activities: [Activity] = []
        for (index, cell) in cells.enumerated() {
            let header = (try? cell.select(".header-cell").first()?.text()) ?? nil
            if let header, !header.isEmpty, header.range(of: "gemini", options: .caseInsensitive) == nil {
                result.otherProductCount += 1
                continue
            }
            guard let content = contentCell(in: cell) else { continue }
            activities.append(activity(fromHTMLCell: cell, content: content, index: index))
        }
        guard !activities.isEmpty || result.otherProductCount > 0 else { throw GeminiImportError.notRecognized }
        build(activities, into: &result, calendar: calendar)
        return result
    }

    private static func contentCell(in cell: Element) -> Element? {
        let candidates = (try? cell.select("div.content-cell").array()) ?? []
        return candidates.first { el in
            el.hasClass("mdl-typography--body-1") && !el.hasClass("mdl-typography--text-right") && !el.hasClass("mdl-typography--caption")
        } ?? candidates.first
    }

    static func activity(fromHTMLCell cell: Element, content: Element, index: Int) -> Activity {
        let nodes = content.getChildNodes()
        let timeIndex = nodes.firstIndex { node in
            guard let text = (node as? TextNode)?.text() else { return false }
            return looksLikeHTMLTime(text)
        }
        let splitIndex = timeIndex ?? nodes.firstIndex { ($0 as? Element)?.tagName().lowercased() == "br" }

        var activity = Activity(sourceIndex: index)
        if let timeIndex, let text = (nodes[timeIndex] as? TextNode)?.text() {
            activity.timeRaw = text.trimmingCharacters(in: .whitespaces)
            activity.time = parseHTMLTime(activity.timeRaw)
        }
        let promptNodes = splitIndex.map { Array(nodes[..<$0]) } ?? nodes
        let responseNodes = splitIndex.map { Array(nodes[($0 + 1)...]) } ?? []

        let titleText = promptNodes.map { ($0 as? TextNode)?.getWholeText() ?? ((try? ($0 as? Element)?.text()) ?? nil) ?? "" }
            .joined().replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        activity.title = titleText
        activity.prompt = promptFromTitle(titleText)

        let responseHTML = responseNodes.map { (try? $0.outerHtml()) ?? "" }.joined()
        activity.firstResponseHTML = responseHTML
        activity.responseMarkdown = nonEmpty(GeminiHTMLToMarkdown.convert(nodes: responseNodes))

        let hrefs = ((try? cell.select("a[href]").array()) ?? []).compactMap { try? $0.attr("href") }
        if let (id, url) = hrefs.lazy.compactMap({ u in chatId(fromURL: u).map { ($0, u) } }).first {
            activity.chatId = id
            activity.chatURL = url
        }
        activity.raw = GeminiImportSupport.jsonData(["html": (try? cell.outerHtml()) ?? ""])
        return activity
    }

    private static let htmlTimeLine = try! Regex(#"^(\p{L}{3,9}\.? \d{1,2}, \d{4}, \d{1,2}:\d{2}:\d{2}|\d{1,2} \p{L}{3,9}\.? \d{4}, \d{1,2}:\d{2}:\d{2}|\d{4}年\d{1,2}月\d{1,2}日)"#)

    static func looksLikeHTMLTime(_ text: String) -> Bool {
        let t = normalizedSpaces(text).trimmingCharacters(in: .whitespaces)
        return (try? htmlTimeLine.prefixMatch(in: t)) != nil
    }

    private static let htmlTimeFormatters: [DateFormatter] = {
        let specs: [(String, String)] = [
            ("en_US_POSIX", "MMM d, yyyy, h:mm:ss a zzz"),
            ("en_US_POSIX", "MMM d, yyyy, h:mm:ss a"),
            ("en_US_POSIX", "MMM d, yyyy, HH:mm:ss zzz"),
            ("en_GB", "d MMM yyyy, HH:mm:ss zzz"),
            ("zh_CN", "yyyy年M月d日 HH:mm:ss zzz"),
            ("zh_CN", "yyyy年M月d日 HH:mm:ss"),
            ("zh_CN", "yyyy年M月d日 ah:mm:ss zzz"),
        ]
        return specs.map { locale, format in
            let f = DateFormatter()
            f.locale = Locale(identifier: locale)
            f.dateFormat = format
            return f
        }
    }()

    static func parseHTMLTime(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let t = normalizedSpaces(raw).trimmingCharacters(in: .whitespaces)
        for f in htmlTimeFormatters {
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    private static func normalizedSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: - 共用

    static func promptFromTitle(_ title: String?) -> String? {
        guard let title = title.map(normalizedSpaces) else { return nil }
        for word in ["Prompted", "Asked"] where title.hasPrefix(word) {
            let rest = title.dropFirst(word.count)
            guard let next = rest.first, next == " " || next == ":" else { continue }
            return nonEmpty(rest.drop { $0 == " " || $0 == ":" }.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// 只认 `https://gemini.google.com/app/<单段 id>`（同 split-gemini-activities-by-chats 的校验）
    static func chatId(fromURL raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "gemini.google.com", url.path.hasPrefix("/app/") else { return nil }
        let parts = url.path.dropFirst("/app/".count).split(separator: "/")
        guard parts.count == 1, let id = parts.first, id != "activitycontrols" else { return nil }
        return String(id)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    // MARK: - 分组 → payload

    static func build(_ input: [Activity], into result: inout GeminiImportResult, calendar: Calendar) {
        var activities: [Activity] = []
        var seen: [String: Int] = [:]
        for var a in input {
            result.activityCount += 1
            if a.time == nil { result.unreadableTimeCount += 1 }
            if a.prompt == nil { result.unconfirmedPromptCount += 1 }
            guard a.prompt != nil || a.responseMarkdown != nil else { continue }
            if a.prompt != nil && a.responseMarkdown == nil { result.missingResponseCount += 1 }
            // 会话链接也进哈希：重复序号只在同一会话里数，删掉别的会话不会让这条的 id 变
            let base = GeminiImportSupport.shortHash([a.timeRaw ?? "", a.title ?? "", a.prompt ?? "", a.firstResponseHTML, a.chatId ?? ""])
            let n = seen[base, default: 0]
            seen[base] = n + 1
            a.key = n == 0 ? base : "\(base)-\(n)"
            activities.append(a)
        }

        // 导出是新的在前：先倒过来当底序，没时间的沿用前一条的时间，再按时间稳定排序
        var ordered: [(activity: Activity, effective: Date)] = []
        var lastTime = Date.distantPast
        for a in activities.reversed() {
            if let t = a.time { lastTime = t }
            ordered.append((a, a.time ?? lastTime))
        }
        let chronological = ordered.enumerated()
            .sorted { ($0.element.effective, $0.offset) < ($1.element.effective, $1.offset) }
            .map(\.element.activity)

        var explicitOrder: [String] = []
        var explicit: [String: [Activity]] = [:]
        var inferred: [[Activity]] = []
        var lastInferredTime: Date?
        for a in chronological {
            if let id = a.chatId {
                if explicit[id] == nil { explicitOrder.append(id) }
                explicit[id, default: []].append(a)
                continue
            }
            if let t = a.time, let last = lastInferredTime, !inferred.isEmpty,
               t.timeIntervalSince(last) <= sessionGap, calendar.isDate(t, inSameDayAs: last) {
                inferred[inferred.count - 1].append(a)
            } else if a.time == nil, !inferred.isEmpty {
                inferred[inferred.count - 1].append(a)
            } else {
                inferred.append([a])
            }
            if let t = a.time { lastInferredTime = t }
        }

        // 对话 id 区分度高的部分放前面：附件目录按 id 前 8 位分，硬删对话也按这个前缀删整个目录（AttachmentStore）
        for id in explicitOrder {
            guard let group = explicit[id] else { continue }
            if let payload = payload(group, conversationId: "\(id)@gemini", basis: "explicitURL", chatURL: group.first?.chatURL, calendar: calendar) {
                result.payloads.append(payload)
                result.explicitConversationCount += 1
            }
            result.attachmentPlaceholderCount += group.reduce(0) { $0 + ($1.prompt == nil ? 0 : $1.attachments.count) }
        }
        for group in inferred {
            guard let first = group.first else { continue }
            if let payload = payload(group, conversationId: "\(first.key)@gemini-t", basis: "timeGap", chatURL: nil, calendar: calendar) {
                result.payloads.append(payload)
                result.inferredConversationCount += 1
            }
            result.attachmentPlaceholderCount += group.reduce(0) { $0 + ($1.prompt == nil ? 0 : $1.attachments.count) }
        }
    }

    private static func payload(_ group: [Activity], conversationId: String, basis: String, chatURL: String?, calendar: Calendar) -> ImportedConversationPayload? {
        var items: [GeminiImportSupport.ChainItem] = []
        for a in group {
            let base = "\(conversationId)/\(a.key)"
            if let prompt = a.prompt {
                let segments = [MessageSegment.text(prompt)] + a.attachments.map { MessageSegment.file(name: $0, uuid: "") }
                items.append(.init(id: base + "/q", role: "user", segments: segments, time: a.time,
                                   metadata: a.responseMarkdown == nil ? a.raw : nil))
            }
            if let response = a.responseMarkdown {
                items.append(.init(id: base + "/a", role: "assistant", segments: [.text(response)], time: a.time, metadata: a.raw))
            }
        }
        guard let last = items.last else { return nil }

        let times = group.compactMap(\.time)
        let created = times.min() ?? .distantPast
        let title: String
        if let prompt = group.lazy.compactMap(\.prompt).first {
            title = GeminiImportSupport.titleSnippet(prompt)
        } else if let first = times.min() {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = "yyyy-MM-dd"
            title = "Gemini 对话 · " + f.string(from: first)
        } else {
            title = "Gemini 对话"
        }
        var meta: [String: Any] = ["source": "gemini-takeout", "groupingBasis": basis]
        if let chatURL { meta["chatURL"] = chatURL }
        return ImportedConversationPayload(
            id: conversationId,
            title: title,
            createTime: created,
            updateTime: times.max() ?? created,
            currentNodeId: last.id,
            provider: provider,
            nodes: GeminiImportSupport.chain(items),
            sourceMetadata: GeminiImportSupport.jsonData(meta)
        )
    }
}
