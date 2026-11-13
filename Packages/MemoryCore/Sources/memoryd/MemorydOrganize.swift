import Foundation
import MemoryCore

/// 整理 agent 在 memoryd 这一头的数据：副本里导出的卡（`exports/fragments.json`）+ 楼层快照里的原文。
/// 卡全部当 Draft（副本里没有她 Approve 过哪些的可靠记录，实验口径就是「整理全池」）
struct SnapshotOrganizeSource: OrganizeSource, @unchecked Sendable {
    struct Origin: Sendable {
        let window: Int
        let conversationId: String
        let index: Int
    }

    let all: [OrganizeCard]
    /// 窗口序号（按卡里第一次出现的先后，从 1 数）→ 主线消息
    let paths: [Int: [SessionSegmentWriter.Message]]
    let origins: [String: Origin]
    let names: MemoryExtractor.Names
    let search: @Sendable (String) -> [(conversationId: String, id: String)]
    let windowOf: [String: Int]

    init(cards: [MemorydService.ExportedFragment], conversations: any ConversationSource, profileId: String,
         names: MemoryExtractor.Names) throws {
        var paths: [Int: [SessionSegmentWriter.Message]] = [:]
        var windowOf: [String: Int] = [:]
        var origins: [String: Origin] = [:]
        for card in cards {
            guard let cid = card.conversationId else { continue }
            if windowOf[cid] == nil {
                let number = windowOf.count + 1
                windowOf[cid] = number
                paths[number] = try conversations.window(profileId: profileId, idOrPrefix: cid).map {
                    try MemorydExperimentRunner.messages(window: $0, source: conversations)
                } ?? []
            }
            guard let number = windowOf[cid], let node = card.sourceNodeId,
                  let index = paths[number]?.firstIndex(where: { $0.id == node }) else { continue }
            origins[String(card.i)] = Origin(window: number, conversationId: cid, index: index)
        }
        self.all = cards.map { OrganizeCard(id: String($0.i), content: $0.content, day: $0.day, zone: .draft) }
        self.paths = paths
        self.origins = origins
        self.names = names
        self.windowOf = windowOf
        self.search = { terms in
            ((try? conversations.search(profileId: profileId, text: terms, conversationId: nil)) ?? [])
                .map { ($0.conversationId, $0.id) }
        }
    }

    private func line(window: Int, index: Int, isOrigin: Bool) -> OrganizeSourceLine? {
        guard let path = paths[window], path.indices.contains(index) else { return nil }
        let message = path[index]
        let text = message.content.count > 1200 ? String(message.content.prefix(1200)) + "…" : message.content
        let when = message.date.map { date -> String in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        }
        return OrganizeSourceLine(marker: "窗口 \(window) · #\(index + 1)", who: message.role == "user" ? names.user : names.char,
                                  when: when, text: text, isOrigin: isOrigin)
    }

    func cards() throws -> [OrganizeCard] { all }

    func source(of card: String, before: Int, after: Int) throws -> [OrganizeSourceLine] {
        guard let origin = origins[card], let path = paths[origin.window] else { return [] }
        return (max(0, origin.index - before)...min(path.count - 1, origin.index + after)).compactMap {
            line(window: origin.window, index: $0, isOrigin: $0 == origin.index)
        }
    }

    /// 只在出过卡的那几个窗口的主线里认（别的窗口这次整理不涉及）
    func search(_ terms: String, limit: Int) throws -> [OrganizeSourceLine] {
        var out: [OrganizeSourceLine] = []
        for hit in search(terms) {
            guard let window = windowOf[hit.conversationId],
                  let index = paths[window]?.firstIndex(where: { $0.id == hit.id }),
                  let row = line(window: window, index: index, isOrigin: false) else { continue }
            out.append(row)
            if out.count >= limit { break }
        }
        return out
    }
}

/// 一次整理 agent 的产出，写成审核页认得的那几样（和对照实验里自由 agent 的目录同形）
enum MemorydOrganizeOutput {
    static func write(_ outcome: OrganizeAgent.Outcome, cards: [OrganizeCard], model: String, to dir: URL, startedAt: Date) throws {
        let original = Dictionary(cards.map { ($0.id, $0.content) }, uniquingKeysWith: { a, _ in a })
        var archive: [[String: Any]] = []
        var dropped: [[String: Any]] = []
        var unsure: [[String: Any]] = []
        for entry in outcome.ledger.entries {
            let from = entry.cards.compactMap(Int.init)
            switch entry.action {
            case .keep, .merge, .rewrite:
                var row: [String: Any] = ["id": "g\(archive.count + 1)", "from": from, "action": entry.action.rawValue,
                                          "content": entry.content ?? entry.cards.compactMap { original[$0] }.joined(separator: " ")]
                if let confidence = entry.confidence { row["confidence"] = confidence }
                if let why = entry.why { row["why"] = why }
                archive.append(row)
            case .drop:
                dropped += from.map { ["i": $0, "why": entry.why ?? ""] }
            case .unsure:
                unsure += from.map { ["i": $0, "why": entry.why ?? ""] }
            }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ value: Any, _ name: String) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent(name), options: .atomic)
        }
        try save(archive, "archive.json")
        try save(dropped, "dropped.json")
        try save(unsure, "unsure.json")
        let toolCounts = Dictionary(outcome.rounds.flatMap(\.tools).map { ($0, 1) }, uniquingKeysWith: +)
        try save([
            "model": model, "stop": outcome.stop.rawValue, "summary": outcome.summary ?? "", "error": outcome.error ?? "",
            "rounds": outcome.rounds.count, "tools": toolCounts,
            "inputTokens": outcome.inputTokens, "outputTokens": outcome.outputTokens, "cacheReadTokens": outcome.cacheReadTokens,
            "seconds": Int(Date().timeIntervalSince(startedAt)),
            "archive": archive.count, "dropped": dropped.count, "unsure": unsure.count,
        ] as [String: Any], "trace.json")
    }
}
