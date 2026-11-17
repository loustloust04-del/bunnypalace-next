import Foundation
import SwiftData

/// 文件夹楼层「看历史」的写库（docs/plan-folder-floor.md P2-8）：同步来的 session 落成这一层里的归档对话。
/// 全部在调用方给的 context 上跑（同步引擎给的是后台 context）。建 / 改消息用导入引擎那几个函数，不另写一套。
enum FolderHistoryStore {
    /// 记在 `Conversation.sourceMetadata` 里：这条对话是电脑上的哪条 session、已经落了几轮
    struct Source: Codable, Equatable {
        var key: String
        var hub: String
        var epoch: Int
        /// 已经落库的轮数（最后一轮可能还会长，下次从它重拉）
        var turns: Int
        /// 落到这一版时电脑那头的序号；和列表里的不一样 = 有新内容要拉
        var seq: Int
        /// 已落的最后一条消息，和「最后一轮之前」的最后一条消息：接下一页 / 重拉最后一轮时，新消息接在它们后面
        var leaf: String?
        var leafBeforeLast: String?
    }

    /// 还要拉正文的一条
    struct Job: Equatable {
        var profileId: String
        var conversationId: String
        var key: String
        var from: Int
        var epoch: Int
        var seq: Int
        var updatedAt: Double
    }

    struct ListResult {
        var jobs: [Job] = []
        /// 「账号:对话号」→ 手机上的对话号（状态标记按它对）
        var ids: [String: String] = [:]
    }

    static func source(of conversation: Conversation) -> Source? {
        guard conversation.isFolderSession, let data = conversation.sourceMetadata else { return nil }
        return try? JSONDecoder().decode(Source.self, from: data)
    }

    private static func setSource(_ source: Source, on conversation: Conversation) {
        conversation.sourceMetadata = try? JSONEncoder().encode(source)
    }

    private static func conversation(_ id: String, in context: ModelContext) throws -> Conversation? {
        var d = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    private static func node(_ id: String, in context: ModelContext) throws -> MessageNode? {
        var d = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    private static func deleteNodes(of conversationId: String, profileId: String, in context: ModelContext) throws {
        for n in try fetchConversationNodes(conversationId: conversationId, profileId: profileId, in: context) { context.delete(n) }
    }

    // MARK: 列表

    /// 列表里的每条 session：没有就建一条空的归档对话（标题、时间先到），有就更新标题和时间；算出哪些要拉正文。
    /// - 这台 hub 自己开的会话（`hubSessions`）在这一层已经有手机上的对话了：跳过，不再来一份
    /// - 她删掉的（在回收站）不复活、不更新
    /// - 号和别的楼层撞了（同一条 session 不该出现在别的楼层）：跳过，不改别人的
    /// - `gone`：电脑那头掉出 30 天窗口的，删正文、留标题
    static func applyList(metas: [FolderHistory.SessionMeta], gone: [String], hubSessions: [String: String],
                          profileId: String, hubIdentity: String, in context: ModelContext) throws -> ListResult {
        var result = ListResult()
        let pid = profileId
        let mine = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == pid }))
        let localSessions = Set(mine.compactMap { $0.isFolderSession ? nil : $0.ccBridgeSessionName })

        for meta in metas {
            if let name = hubSessions[meta.key], localSessions.contains(name) { continue }
            let id = FolderHistory.conversationId(hubIdentity: hubIdentity, profileId: profileId, key: meta.key)
            let updated = FolderHistory.date(meta.updatedAt) ?? Date()
            if let existing = try conversation(id, in: context) {
                guard existing.profileId == profileId, existing.isFolderSession, !existing.isTrashed else { continue }
                var src = source(of: existing) ?? Source(key: meta.key, hub: hubIdentity, epoch: meta.epoch, turns: 0, seq: 0)
                // 文件换过；或者来源信息自己对不上（说落过几轮、库里也有消息，却没记下最后一条是谁）：正文清掉从头拉
                if src.epoch != meta.epoch || (src.turns > 0 && src.leaf == nil && !existing.currentNodeId.isEmpty) {
                    try deleteNodes(of: id, profileId: profileId, in: context)
                    src = Source(key: meta.key, hub: hubIdentity, epoch: meta.epoch, turns: 0, seq: 0)
                    existing.currentNodeId = ""
                    existing.nodeCount = 0
                }
                if !meta.title.isEmpty, existing.title != meta.title { existing.title = meta.title }
                if existing.updateTime != updated { existing.updateTime = updated }
                setSource(src, on: existing)
                result.ids[meta.key] = id
                if src.seq != meta.seq {
                    result.jobs.append(Job(profileId: profileId, conversationId: id, key: meta.key, from: max(0, src.turns - 1),
                                           epoch: meta.epoch, seq: meta.seq, updatedAt: meta.updatedAt))
                }
            } else {
                let c = Conversation(id: id, title: meta.title.isEmpty ? placeholderTitle : meta.title,
                                     createTime: FolderHistory.date(meta.createdAt) ?? updated, updateTime: updated,
                                     currentNodeId: "", provider: FolderHistory.provider, profileId: profileId)
                c.archiveKind = FolderHistory.archiveKind
                c.memoryEnabled = false
                setSource(Source(key: meta.key, hub: hubIdentity, epoch: meta.epoch, turns: 0, seq: 0), on: c)
                context.insert(c)
                result.ids[meta.key] = id
                result.jobs.append(Job(profileId: profileId, conversationId: id, key: meta.key, from: 0,
                                       epoch: meta.epoch, seq: meta.seq, updatedAt: meta.updatedAt))
            }
        }

        // 同一次回复里又在列表里、又在「消失」里的（掉出去又回来）：以列表为准，不删
        let listed = Set(metas.map(\.key))
        for key in gone where !listed.contains(key) {
            let id = FolderHistory.conversationId(hubIdentity: hubIdentity, profileId: profileId, key: key)
            guard let existing = try conversation(id, in: context), existing.profileId == profileId, existing.isFolderSession,
                  var src = source(of: existing) else { continue }
            try deleteNodes(of: id, profileId: profileId, in: context)
            src.turns = 0
            src.seq = 0
            src.leaf = nil
            src.leafBeforeLast = nil
            setSource(src, on: existing)
            existing.currentNodeId = ""
            existing.nodeCount = 0
        }
        try context.save()
        result.jobs.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    static let placeholderTitle = "电脑上的对话"

    // MARK: 内容

    enum TurnsOutcome: Equatable {
        /// 这一页落好了；next = 下一页从哪轮起，nil = 这条拉完了
        case written(next: Int?)
        /// 对不上（对话没了 / 被她删了 / 电脑那头文件换过）：这条先不拉了，等下一次列表
        case stale
    }

    /// 落一页内容。`from` 那一轮可能是上次落过的最后一轮（它后来又长了），按号更新，不重复建
    static func applyTurns(_ reply: FolderHistory.TurnsReply, job: Job, in context: ModelContext) throws -> TurnsOutcome {
        // 回来的必须就是要的那条、那一页：key、文件版本、起点都要对上，对不上的整页丢掉
        guard let turns = reply.turns, !turns.isEmpty, let from = reply.from, from == job.from, reply.key == job.key, reply.epoch == job.epoch,
              reply.next == nil || reply.next == from + turns.count,
              let conv = try conversation(job.conversationId, in: context), conv.profileId == job.profileId, conv.isFolderSession,
              !conv.isTrashed, var src = source(of: conv), src.key == job.key, src.epoch == job.epoch else { return .stale }
        // 起点只有三种：从头、接着已落的往后、重拉已落的最后一轮。别的（跳着来、比已落的还旧）不认
        var leaf: String?
        if from == 0 { leaf = nil }
        else if from == src.turns { leaf = src.leaf }
        else if from == src.turns - 1 { leaf = src.leafBeforeLast }
        else { return .stale }

        // 先把这一页要写的消息全部算出来（纯计算），再把涉及的号都查一遍：有一个被别的楼层 / 别的对话占着，整页不写
        // （`insert` 同号会把别人的整行改写）。查完没问题才动库，所以不需要回滚
        let start = leaf
        var planned: [ImportedNodePayload] = []
        var beforeLast = leaf
        for (offset, turn) in turns.enumerated() {
            beforeLast = leaf
            let payloads = FolderHistory.nodes(for: turn, index: from + offset, conversationId: job.conversationId, parent: leaf)
            planned += payloads
            if let last = payloads.last { leaf = last.id }
        }
        var known: [String: MessageNode] = [:]
        for id in planned.map(\.id) + (start.map { [$0] } ?? []) {
            guard let n = try node(id, in: context) else { continue }
            guard n.profileId == job.profileId, n.conversationId == job.conversationId else { return .stale }
            known[id] = n
        }
        for payload in planned {
            if let existing = known[payload.id] {
                applyImportedNode(payload, to: existing)
            } else {
                let n = makeImportedNode(payload, conversationId: job.conversationId, profileId: job.profileId)
                context.insert(n)
                known[payload.id] = n
                if let parentId = payload.parentId, let parent = known[parentId], !parent.childrenIds.contains(payload.id) {
                    parent.childrenIds.append(payload.id)
                }
            }
        }

        src.turns = from + turns.count
        src.leaf = leaf
        src.leafBeforeLast = beforeLast
        if reply.next == nil { src.seq = job.seq }
        setSource(src, on: conv)
        if let leaf { conv.currentNodeId = leaf }
        if from == 0, conv.title == placeholderTitle, let first = turns.first.map(FolderHistory.inputText), !first.isEmpty {
            conv.title = String(first.replacingOccurrences(of: "\n", with: " ").prefix(40))
        }
        try context.save()
        let convId = job.conversationId, pid = job.profileId
        conv.nodeCount = try context.fetchCount(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == convId && $0.profileId == pid }))
        try context.save()
        return .written(next: reply.next)
    }
}
