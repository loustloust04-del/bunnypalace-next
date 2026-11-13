import Foundation
import MemoryCore

/// 写入 agent 在 memoryd 这一头的数据（plan-write-agent W2）：副本里一个窗口主线上的一段当「新对话」，
/// 已有档案 = 空，或者之前某次写入的产出
struct SnapshotWriteSource: WriteSource, @unchecked Sendable {
    let windowTitle: String
    /// 整个窗口的主线
    let path: [SessionSegmentWriter.Message]
    /// 这次处理的是主线上的哪一段
    let range: Range<Int>
    let existing: [WriteKnownCard]
    let names: MemoryExtractor.Names
    let find: @Sendable (String) -> [OrganizeSourceLine]

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    init(window: ConversationWindow, path: [SessionSegmentWriter.Message], range: Range<Int>, existing: [WriteKnownCard],
         names: MemoryExtractor.Names, conversations: any ConversationSource) {
        self.windowTitle = window.title
        self.path = path
        self.range = range
        self.existing = existing
        self.names = names
        let profileId = window.profileId
        self.find = { terms in
            let hits = Array(((try? conversations.search(profileId: profileId, text: terms, conversationId: nil)) ?? []).prefix(20))
            let titles = (try? conversations.titles(profileId: profileId, ids: Array(Set(hits.map(\.conversationId))))) ?? [:]
            return hits.map { hit in
                let body = CatalogOriginalText.body(of: hit).trimmingCharacters(in: .whitespacesAndNewlines)
                return OrganizeSourceLine(marker: "「\(titles[hit.conversationId] ?? "")」窗口",
                                          who: hit.role == "user" ? names.user : names.char,
                                          when: hit.createTime.map { Self.stamp.string(from: $0) },
                                          text: body.count > 600 ? String(body.prefix(600)) + "…" : body)
            }
        }
    }

    private func line(_ index: Int) -> WriteLine {
        let message = path[index]
        return WriteLine(number: index - range.lowerBound + 1, who: message.role == "user" ? names.user : names.char,
                         when: message.date.map { Self.stamp.string(from: $0) }, text: message.content)
    }

    func span() throws -> [WriteLine] { range.map(line) }

    func before(count: Int, skip: Int) throws -> [WriteLine] {
        let end = range.lowerBound - skip
        guard end > 0 else { return [] }
        return (max(0, end - count)..<end).map(line)
    }

    func search(_ terms: String, limit: Int) throws -> [OrganizeSourceLine] { Array(find(terms).prefix(limit)) }
    func known() throws -> [WriteKnownCard] { existing }
    func pages() throws -> [WritePage] { [] }

    /// 和手写实验同一种格式的原文（审核页和裁判都读它）
    func transcript() -> String {
        range.map { index -> String in
            let row = line(index)
            return "#\(row.number) \(row.when ?? "") · \(row.who)：\(row.text.replacingOccurrences(of: "\n", with: " ⏎ "))"
        }.joined(separator: "\n") + "\n"
    }
}

enum MemorydWriteOutput {
    /// 之前某次写入的产出当已有档案；编号 k1、k2…
    static func known(from archive: URL) -> [WriteKnownCard]? {
        guard let data = try? Data(contentsOf: archive),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return rows.enumerated().compactMap { index, row in
            guard let content = row["content"] as? String else { return nil }
            return WriteKnownCard(id: "k\(index + 1)", content: content, subject: row["subject"] as? String, since: row["since"] as? String)
        }
    }

    static func write(_ outcome: WriteAgent.Outcome, model: String, existing: String?, spanCount: Int, to dir: URL, startedAt: Date) throws {
        let archive: [[String: Any]] = outcome.ledger.cards.map { card in
            var row: [String: Any] = ["id": card.key, "subject": card.subject, "type": card.type, "origin": card.origin,
                                      "volatile": card.volatile, "content": card.content, "msgs": card.msgs]
            if let since = card.since { row["since"] = since }
            if let confidence = card.confidence { row["confidence"] = confidence }
            if let target = card.target { row["target"] = target; row["suggestion"] = card.suggestion }
            return row
        }
        let notes: [[String: Any]] = outcome.ledger.notes.map { note in
            var row: [String: Any] = ["id": note.key, "title": note.title, "content": note.content, "cards": note.cards]
            if let page = note.page { row["page"] = page }
            return row
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ value: Any, _ name: String) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        try save(archive, "archive.json")
        try save(notes, "notes.json")
        let toolCounts = Dictionary(outcome.rounds.flatMap(\.tools).map { ($0, 1) }, uniquingKeysWith: +)
        try save([
            "model": model, "stop": outcome.stop.rawValue, "summary": outcome.summary ?? "", "error": outcome.error ?? "",
            "rounds": outcome.rounds.count, "tools": toolCounts, "span": spanCount, "existing": existing ?? "",
            "inputTokens": outcome.inputTokens, "outputTokens": outcome.outputTokens, "cacheReadTokens": outcome.cacheReadTokens,
            "seconds": Int(Date().timeIntervalSince(startedAt)),
            "cards": archive.count, "updates": outcome.ledger.cards.filter { $0.target != nil }.count, "notes": notes.count,
        ] as [String: Any], "trace.json")
    }
}
