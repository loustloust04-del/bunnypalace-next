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
}
