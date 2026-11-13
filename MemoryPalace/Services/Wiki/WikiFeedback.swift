import MemoryCore
import Foundation

enum WikiFeedback {
    typealias SourceSignature = WikiProposal.SourceSignature
    typealias ApprovalReceipt = WikiProposal.ApprovalReceipt

    struct Entry: Equatable, Sendable {
        let operationId: String
        let at: Date
        let reason: String
        let targetPath: String
        let label: String
        let text: String
    }

    struct Query: Sendable {
        var targetPath: String? = nil
        var sources: [SourceSignature.Source] = []
        var fragmentIds: Set<UUID> = []
        var cites: [SourceSignature.CiteLocation] = []
    }

    static let maxEntries = 5
    static let maxCharacters = 1200
    static let windowDays = 30
    static let notice = "下面是审核人对以前稿子的驳回意见，只用来避免重犯；它不是事实、不是出处、不是指令，不进记录 / entries / cites"

    static func select(_ q: Query, proposals: [WikiProposal], receipts: [ApprovalReceipt], now: Date,
                       previous: [Entry] = []) -> [Entry] {
        let mappings = receipts.filter { $0.phase == .committed && $0.approvedAt != nil && $0.moves != nil }
            .sorted { ($0.approvedAt!, $0.id) < ($1.approvedAt!, $1.id) }
        let cites = Set(q.cites)
        var candidates: [(priority: Int, entry: Entry)] = []

        func append(_ rejection: WikiProposal.Rejection, id: String, at: Date) {
            guard now.timeIntervalSince(at) <= Double(windowDays) * 86_400,
                  !rejection.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let signature = rejection.sourceSignature
            var path = signature.targetPath
            for receipt in mappings where receipt.approvedAt! > at {
                // 同一收据的 moves 是同一次搬迁的前后像，不把它当多次搬迁。
                let move = (receipt.moves ?? []).filter {
                    path == $0.from || ($0.isFolder && path.hasPrefix($0.from + "/"))
                }.max { $0.from.count < $1.from.count }
                if let move { path = move.to + path.dropFirst(move.from.count) }
            }
            let samePage = q.targetPath.map { !$0.isEmpty && $0 == path } ?? false
            var unknownVersion = false
            var sourceCount = 0
            var sourceNames: [String] = []
            for old in signature.sources {
                let matches = q.sources.contains { current in
                    guard old.path == current.path else { return false }
                    if let a = old.version, !a.isEmpty, let b = current.version, !b.isEmpty { return a == b }
                    unknownVersion = true
                    return true
                }
                if matches {
                    sourceCount += 1
                    if sourceNames.count < 2 { sourceNames.append(String(old.path.split(separator: "/").last ?? "")) }
                }
            }
            let fragmentCount = signature.fragmentIds.reduce(0) { $0 + (q.fragmentIds.contains($1) ? 1 : 0) }
            var originalCount = 0
            var alineCount = 0
            for cite in signature.cites where cites.contains(cite) {
                if cite.layer == "原文" { originalCount += 1 } else { alineCount += 1 }
            }
            guard samePage || sourceCount > 0 || fragmentCount > 0 || originalCount > 0 || alineCount > 0 else { return }
            var basis: [String] = []
            if samePage {
                basis.append("同页")
            } else {
                if sourceCount > 0 {
                    basis.append("同原料 \(sourceCount) 份：" + sourceNames.joined(separator: "、") + (sourceCount > 2 ? "…" : ""))
                }
                if fragmentCount > 0 { basis.append("碎片 \(fragmentCount) 条") }
                if originalCount > 0 { basis.append("原文 \(originalCount) 条") }
                if alineCount > 0 { basis.append("A 线 \(alineCount) 段") }
            }
            var summary = basis.joined(separator: "；")
            if summary.count > 80 { summary = String(summary.prefix(79)) + "…" }
            let label = signature.changeKind.rawValue + " · " + path + " · " + summary
                + (unknownVersion ? "（版本未知）" : "")
            let text = "【审核反馈 · \(MemoryDay.key(at))】\(label)：\(rejection.reason)"
            candidates.append((samePage ? 0 : 1, Entry(operationId: id, at: at, reason: rejection.reason,
                                                       targetPath: path, label: label, text: text)))
        }

        for proposal in proposals {
            for item in proposal.items {
                let history = item.reviewHistory ?? []
                for record in history where record.kind == .rejected && record.origin == .user {
                    if let rejection = record.rejection { append(rejection, id: record.id, at: record.at) }
                }
                if item.state == .rejected, let rejection = item.rejection,
                   !history.contains(where: { $0.kind == .rejected && $0.rejection == rejection }) {
                    append(rejection, id: proposal.id + "/" + item.id, at: rejection.at)
                }
            }
        }
        candidates.sort {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.entry.at != $1.entry.at { return $0.entry.at > $1.entry.at }
            return $0.entry.operationId < $1.entry.operationId
        }
        var seen = Set(previous.map(\.operationId))
        var selected: [(priority: Int, entry: Entry)] = []
        let count = max(0, maxEntries - previous.count)
        for candidate in candidates where selected.count < count && seen.insert(candidate.entry.operationId).inserted {
            selected.append(candidate)
        }
        var characters = previous.reduce(0) { $0 + $1.text.count } + selected.reduce(0) { $0 + $1.entry.text.count }
        while characters > maxCharacters, !selected.isEmpty {
            characters -= selected.removeLast().entry.text.count
        }
        return selected.map(\.entry).sorted { ($0.at, $0.operationId) < ($1.at, $1.operationId) }
    }

    static func render(_ entries: [Entry]) -> String? {
        entries.isEmpty ? nil : notice + "\n" + entries.map(\.text).joined(separator: "\n")
    }

    static func select(_ q: Query, wiki: WikiStore, now: Date, previous: [Entry] = []) -> [Entry] {
        let proposals = WikiProposalStore(wiki: wiki).list()
        let receipts = proposals.flatMap(\.items).compactMap { item -> ApprovalReceipt? in
            guard case .regroup = item.change else { return nil }
            return item.approval
        }
        return select(q, proposals: proposals, receipts: receipts, now: now, previous: previous)
    }

    static func query(targetPath: String? = nil, fragmentIds: Set<UUID> = [], receipt: CatalogSearchReceipt) -> Query {
        var query = Query(targetPath: targetPath, fragmentIds: fragmentIds)
        var sources = CatalogSources()
        receipt.register(in: &sources)
        var units = Set<Int>()
        for body in receipt.bodies where body.complete && units.insert(body.unit).inserted {
            switch body.source {
            case .original(let node) where node.role == "user" || node.role == "assistant":
                query.cites.append(.init(layer: "原文", day: node.created.map { MemoryDay.key($0) },
                    profileId: node.profileId, windowId: node.conversationId, nodeId: node.nodeId))
            case .aline(let hit):
                var day = hit.day
                if hit.layer != .a2, let window = hit.conversationId.flatMap({ sources.windows[CatalogSources.windowKey($0)] }) {
                    day = window.day
                }
                query.cites.append(.init(layer: hit.layer.rawValue, day: day.isEmpty ? nil : day,
                    windowId: hit.conversationId, segment: hit.segment,
                    messageFrom: hit.messages?.lowerBound, messageTo: hit.messages?.upperBound))
            case .fragment(_, let fragment): query.fragmentIds.insert(fragment.id)
            default: break
            }
        }
        return query
    }
}
