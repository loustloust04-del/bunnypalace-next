import Foundation
import SwiftData

extension Notification.Name {
    /// 文件夹模式的电脑发来的帧（`folder_req_result` / `folder_changed`）和「这台连上了」。userInfo：hubId、type、data
    static let folderHistoryFrame = Notification.Name("folderHistoryFrame")
}

/// 文件夹楼层「看历史」的同步（docs/plan-folder-floor.md P2-8）：问连着的那台电脑要 session 列表和内容，落进这一层。
/// 先来列表（标题、时间、状态），正文在后面按「新的先」一条条补。写库在后台 context，这里只管收发和排队。
@MainActor
@Observable
final class FolderHistorySync {
    static let shared = FolderHistorySync()

    /// 对话号 → busy（在忙）/ wait（等批）/ done（答完了）。对话行右边那个点读它
    private(set) var states: [String: String] = [:]

    /// 楼层列表、主库、记游标的地方：`start` 接上 app 的；测试里直接换
    @ObservationIgnored var profiles: () -> [Profile] = { [] }
    @ObservationIgnored var container: () -> ModelContainer? = { nil }
    @ObservationIgnored var defaults: UserDefaults = .standard
    @ObservationIgnored private var observer: NSObjectProtocol?
    /// 发帧：返回 false = 那台没连着。测试里换掉
    @ObservationIgnored var send: (_ hubId: String, _ payload: [String: Any]) -> Bool = { hubId, payload in
        guard let client = CCHubRegistry.shared.client(for: hubId) else { return false }
        client.send(payload) { _ in }
        return true
    }
    /// 那台电脑的身份、默认账号、支不支持看历史。测试里换掉
    @ObservationIgnored var hubFacts: (_ hubId: String) -> (identity: String?, defaultAccount: String?, supported: Bool) = { hubId in
        let hello = CCHubRegistry.shared.client(for: hubId)?.currentHubInfo
        return (hello?.hubId ?? CCHubRegistry.shared.identity(of: hubId), hello?.folder?.accounts.first?.id,
                hello?.capabilities.contains("folder_history") == true)
    }

    private enum Request {
        case sessions(hubId: String, after: Int, floors: [Floor])
        case turns(hubId: String, job: FolderHistoryStore.Job)
    }
    private struct Floor { var profileId: String; var account: String; var identity: String }

    @ObservationIgnored private var pending: [String: Request] = [:]
    @ObservationIgnored private var queue: [String: [FolderHistoryStore.Job]] = [:]
    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private var listing: Set<String> = []
    @ObservationIgnored private var listAgain: Set<String> = []
    /// 下一次列表要问全量的电脑：刚连上、或者有哪条正文没拉成。游标只管「之后有变化的」，没拉完的那条靠全量列表重新排上
    @ObservationIgnored private var needsFull: Set<String> = []
    /// 一条对话连着没拉成几次；到 3 次先放下，等下次连上再试（免得坏掉的一条每 5 秒重来一遍）
    @ObservationIgnored private var failures: [String: Int] = [:]
    static let maxFailures = 3
    static let replyTimeout: Duration = .seconds(15)

    /// app 启动时调一次（只有根上的那个 ProfileManager）
    func start(profileManager pm: ProfileManager) {
        profiles = { [weak pm] in pm?.profiles ?? [] }
        container = { [weak pm] in pm?.container }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .folderHistoryFrame, object: nil, queue: .main) { note in
            guard let hubId = note.userInfo?["hubId"] as? String, let type = note.userInfo?["type"] as? String else { return }
            let data = note.userInfo?["data"] as? Data
            MainActor.assumeIsolated { FolderHistorySync.shared.handle(hubId: hubId, type: type, data: data) }
        }
    }

    func handle(hubId: String, type: String, data: Data?) {
        switch type {
        case "hello":
            needsFull.insert(hubId)
            failures = [:]
            refresh(hubId: hubId)
        case "folder_changed": refresh(hubId: hubId)
        case "folder_req_result": if let data { reply(hubId: hubId, data: data) }
        default: break
        }
    }

    // MARK: 列表

    /// 连着这台电脑的楼层。这一层只收它那个账号的 session（没选账号 = 那台的默认账号）
    private func floors(of hubId: String) -> [Floor] {
        let facts = hubFacts(hubId)
        guard facts.supported, let identity = facts.identity, !identity.isEmpty else { return [] }
        return profiles().compactMap { p in
            guard p.isFolderFloor, p.folderHubId == hubId || (!(p.folderHubIdentity ?? "").isEmpty && p.folderHubIdentity == identity),
                  let account = p.folderAccount ?? facts.defaultAccount else { return nil }
            return Floor(profileId: p.id, account: account, identity: identity)
        }
    }

    private static func cursorKey(_ f: Floor) -> String { "folderHistory.seq.\(f.profileId).\(f.identity)" }

    /// 问这台电脑要列表。正在问就记一笔，回来以后再问一次（中间来的变化通知不丢）
    func refresh(hubId: String) {
        let floors = floors(of: hubId)
        guard !floors.isEmpty else { return }
        guard !listing.contains(hubId) else { listAgain.insert(hubId); return }
        let after = needsFull.contains(hubId) ? 0 : floors.map { defaults.integer(forKey: Self.cursorKey($0)) }.min() ?? 0
        let id = UUID().uuidString
        guard send(hubId, ["type": "folder_req", "req_id": id, "op": "sessions", "after": after]) else { return }
        listing.insert(hubId)
        pending[id] = .sessions(hubId: hubId, after: after, floors: floors)
        expire(id)
    }

    private func expire(_ id: String) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            guard let self, let request = self.pending.removeValue(forKey: id) else { return }
            switch request {
            case .sessions(let hubId, _, _): self.listing.remove(hubId); self.needsFull.insert(hubId)
            case .turns(let hubId, let job): self.fetching.remove(hubId); self.failed(job, hubId: hubId); self.pump(hubId)
            }
        }
    }

    private func reply(hubId: String, data: Data) {
        guard let rid = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["req_id"] as? String,
              let request = pending.removeValue(forKey: rid) else { return }
        switch request {
        case .sessions(let hub, let after, let floors):
            guard hub == hubId else { return }
            let decoded = try? JSONDecoder().decode(FolderHistory.SessionsReply.self, from: data)
            Task { await self.applyList(hubId: hubId, after: after, floors: floors, reply: decoded) }
        case .turns(let hub, let job):
            guard hub == hubId else { return }
            let decoded = try? JSONDecoder().decode(FolderHistory.TurnsReply.self, from: data)
            Task { await self.applyTurns(hubId: hubId, job: job, reply: decoded) }
        }
    }

    private func applyList(hubId: String, after: Int, floors: [Floor], reply: FolderHistory.SessionsReply?) async {
        defer {
            listing.remove(hubId)
            if listAgain.remove(hubId) != nil { refresh(hubId: hubId) }
        }
        guard let reply, reply.ok, let seq = reply.seq, let container = container() else { needsFull.insert(hubId); return }
        var jobs: [FolderHistoryStore.Job] = []
        var allWritten = true
        var next = states
        for floor in floors {
            let metas = (reply.sessions ?? []).filter { $0.account == floor.account }
            let gone = (reply.gone ?? []).filter { $0.hasPrefix(floor.account + ":") }
            let hubSessions = reply.hub_sessions ?? [:]
            let result: FolderHistoryStore.ListResult? = await Task.detached(priority: .utility) {
                try? FolderHistoryStore.applyList(metas: metas, gone: gone, hubSessions: hubSessions, profileId: floor.profileId,
                                                  hubIdentity: floor.identity, in: ModelContext(container))
            }.value
            guard let result else { allWritten = false; continue }   // 这一层没写成：游标不动，下次从原来的地方再来
            defaults.set(seq, forKey: Self.cursorKey(floor))
            jobs += result.jobs
            // 状态每次是全量：先清掉这一层在这台电脑上的，再按这次的放
            let prefix = FolderHistory.conversationId(hubIdentity: floor.identity, profileId: floor.profileId, key: "")
            next = next.filter { !$0.key.hasPrefix(prefix) }
            for (key, state) in reply.states ?? [:] where key.hasPrefix(floor.account + ":") {
                next[FolderHistory.conversationId(hubIdentity: floor.identity, profileId: floor.profileId, key: key)] = state
            }
        }
        if next != states { states = next }
        if allWritten, after == 0 { needsFull.remove(hubId) } else if !allWritten { needsFull.insert(hubId) }
        enqueue(jobs.filter { failures[$0.conversationId, default: 0] < Self.maxFailures }, hubId: hubId)
        if reply.pending == true {   // 电脑那头的索引还在建：过一会儿再问一次
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.refresh(hubId: hubId)
            }
        }
    }

    // MARK: 正文

    private func enqueue(_ jobs: [FolderHistoryStore.Job], hubId: String) {
        var q = queue[hubId] ?? []
        for job in jobs {
            q.removeAll { $0.conversationId == job.conversationId }
            q.append(job)
        }
        q.sort { $0.updatedAt > $1.updatedAt }
        queue[hubId] = q
        pump(hubId)
    }

    /// 她点开了一条还没补到的：把它提到最前面
    func prioritize(conversationId: String) {
        for (hubId, q) in queue {
            guard let i = q.firstIndex(where: { $0.conversationId == conversationId }), i > 0 else { continue }
            var q = q
            q.insert(q.remove(at: i), at: 0)
            queue[hubId] = q
        }
    }

    private func pump(_ hubId: String) {
        guard !fetching.contains(hubId), var q = queue[hubId], !q.isEmpty else { return }
        let job = q.removeFirst()
        queue[hubId] = q
        request(job, hubId: hubId)
    }

    private func request(_ job: FolderHistoryStore.Job, hubId: String) {
        let id = UUID().uuidString
        guard send(hubId, ["type": "folder_req", "req_id": id, "op": "turns", "key": job.key, "from": job.from]) else {
            queue[hubId] = []   // 那台断了：排着的都放掉，连上以后全量列表会再排一遍
            needsFull.insert(hubId)
            return
        }
        fetching.insert(hubId)
        pending[id] = .turns(hubId: hubId, job: job)
        expire(id)
    }

    /// 这条没拉成（回帧不来 / 看不懂 / 对不上 / 写不进去）：记一笔，下一次列表问全量，把它重新排上
    private func failed(_ job: FolderHistoryStore.Job, hubId: String) {
        failures[job.conversationId, default: 0] += 1
        needsFull.insert(hubId)
    }

    private func applyTurns(hubId: String, job: FolderHistoryStore.Job, reply: FolderHistory.TurnsReply?) async {
        var outcome: FolderHistoryStore.TurnsOutcome = .stale
        if let reply, reply.ok, let container = container() {
            outcome = await Task.detached(priority: .utility) {
                (try? FolderHistoryStore.applyTurns(reply, job: job, in: ModelContext(container))) ?? .stale
            }.value
        }
        fetching.remove(hubId)
        switch outcome {
        case .written(let next?):
            var more = job
            more.from = next
            request(more, hubId: hubId)   // 同一条接着拉下一页
        case .written(nil):
            failures[job.conversationId] = nil
            pump(hubId)
        case .stale:
            failed(job, hubId: hubId)
            pump(hubId)
        }
    }
}
