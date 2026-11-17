import Foundation
import SwiftData

/// atrium 一行要的数（plan-atrium P1）：该层最近一条对话的那句 / 时间、全层未读、AI 状态
struct AtriumRow: Equatable, Sendable {
    var lastLine = ""
    var updatedAt: Date?
    var unread = 0
    var status: String?
}

enum AtriumRowLoader {
    /// 后台 context 算，主线程只拿结果。每层两次 fetch + 读一个小文件；层多时的代价见 research-atrium §6，先不优化
    static func load(profileIds: [String], container: ModelContainer) async -> [String: AtriumRow] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            var rows: [String: AtriumRow] = [:]
            for pid in profileIds {
                var row = AtriumRow()
                var latest = FetchDescriptor<Conversation>(
                    predicate: #Predicate { $0.profileId == pid && !$0.isTrashed },
                    sortBy: [SortDescriptor(\.updateTime, order: .reverse)])
                latest.fetchLimit = 1
                if let conversation = try? context.fetch(latest).first {
                    let line = ConversationPreviewCache.compute(for: conversation, context: context)
                    row.lastLine = line.isEmpty ? conversation.title : line
                    row.updatedAt = conversation.updateTime
                }
                let unread = FetchDescriptor<Conversation>(
                    predicate: #Predicate { $0.profileId == pid && !$0.isTrashed && $0.unreadCount > 0 })
                row.unread = ((try? context.fetch(unread)) ?? []).reduce(0) { $0 + $1.unreadCount }
                row.status = ProfileCardStore.load(profileId: pid).status
                rows[pid] = row
            }
            return rows
        }.value
    }

    /// 只要每层最近一条对话的时间（page0 顶栏挑最近聊过的人用，不算预览和未读）
    static func latestTimes(profileIds: [String], container: ModelContainer) async -> [String: AtriumRow] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            var rows: [String: AtriumRow] = [:]
            for pid in profileIds {
                var latest = FetchDescriptor<Conversation>(
                    predicate: #Predicate { $0.profileId == pid && !$0.isTrashed },
                    sortBy: [SortDescriptor(\.updateTime, order: .reverse)])
                latest.fetchLimit = 1
                rows[pid] = AtriumRow(updatedAt: (try? context.fetch(latest).first)?.updateTime)
            }
            return rows
        }.value
    }

    /// 最近聊过的在上（按该层最近一条对话的时间）；没聊过的垫底，保持建层顺序
    static func recentFirst(_ profiles: [Profile], rows: [String: AtriumRow]) -> [Profile] {
        profiles.enumerated().sorted { a, b in
            switch (rows[a.element.id]?.updatedAt, rows[b.element.id]?.updatedAt) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}
