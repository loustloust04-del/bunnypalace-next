import Foundation
import SwiftData

/// 一次整理 = 一份提案（plan-memory-c3-catalog 2.3）：存 `wiki/.proposals/<id>.json`，条目逐条批 / 改 / 驳回，批了才写 md
struct WikiProposal: Codable, Identifiable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        case scheduled, manual, topic, seed, assistant
    }

    enum Status: Equatable, Sendable {
        case pending    // 全待批
        case partial    // 处理了一部分
        case done       // 全处理完
    }

    /// 原文 / A 线 / CC 种子出处；旧提案缺原文定位字段时不补造。
    struct Cite: Codable, Equatable, Sendable {
        var layer: String          // 原文 / A2 / A3 / A4 / CC
        var day: String? = nil
        var windowId: String? = nil
        var segment: Int? = nil
        var messageFrom: Int? = nil
        var messageTo: Int? = nil
        var filePath: String? = nil
        var profileId: String? = nil
        var nodeId: String? = nil
        var role: String? = nil
        var created: Date? = nil
        var onMain: Bool? = nil
        /// 种子出处的显示名（Prompt 槽 / 字段名）
        var name: String? = nil
    }

    struct NewGroup: Codable, Equatable, Sendable {
        var path: String
        var hook: String
    }

    /// 挪页或挪整个分组文件夹
    struct Move: Codable, Equatable, Sendable {
        var from: String
        var to: String
    }

    /// 第一批：动哪页、为什么（不含正文）。批了才去搜、写，写出来的正文另成一份提案再批
    struct Direction: Codable, Equatable, Sendable {
        enum Action: String, Codable, Sendable {
            case update, newPage
        }
        /// 日常 = 一次写手；agent = 自己查，最多 N 轮；seed = 种子目录项（由种子任务自己接着写，不走这里的执行）
        enum Mode: String, Codable, Sendable {
            case daily, agent, seed
        }
        var path: String
        var title: String
        var hook: String = ""
        var kind: WikiPage.Kind? = nil
        var aliases: [String] = []
        var action: Action
        var reason: String
        /// 线索碎片：只是为什么提这个方向，批 / 驳回都不给它们打标
        var clues: [UUID] = []
        var mode: Mode
        /// 批了以后开始执行的时间；有了就不再执行（重复批 / 重复点不重付）
        var ranAt: Date? = nil
        /// 执行结果（交了正文 / 没材料 / 被拦 / 停了 / 出错）
        var result: String? = nil
        var contentProposalId: String? = nil
        /// 种子目录项的原料清单（读过的原料路径）
        var sources: [String]? = nil
        /// true = 整理 path 这个分组（比如 楼层/{用户}），写手在分组下归页 / 开页；nil = 写 path 这一页
        var group: Bool? = nil
        /// 碎片以外的线索（A4 时间轴哪几天、到期的哪一天）：同一目标处理过的不再提，有新的才提
        var basis: [String]? = nil
    }

    /// 写手交的、收不进页的内容（关系不在四种之内的连线、不认识的条目类型、条目带了不收的字段）：原样留给她看，不执行
    struct Unapplied: Codable, Equatable, Sendable {
        /// 来源页（有的话）
        var page: String?
        /// 原始操作原文
        var raw: String
        var reason: String
        /// 在写手那份输出里的位置（items[1] …）
        var at: String
    }

    /// 正文提案是从哪条方向来的
    struct DirectionRef: Codable, Equatable, Sendable {
        var proposalId: String
        var itemId: String
    }

    /// 手动请求本身就是方向授权：她在哪个楼层说了什么
    struct Request: Codable, Equatable, Sendable {
        var profileId: String
        var text: String
    }

    enum Change: Codable, Equatable, Sendable {
        case newPage(page: WikiPage)
        case appendRecords(path: String, lines: [String])
        /// until = 新「现在」该复核的日子（写手的 valid_until）；落页时「现在」里没写这一天就不收
        case rewriteNow(path: String, old: String, new: String, until: String? = nil)
        case link(from: String, link: WikiPage.Link)
        case retag(path: String, oldHook: String, newHook: String, oldTriggers: [String], newTriggers: [String])
        case regroup(layer: String, groups: [NewGroup], moves: [Move])
        case direction(Direction)
        /// 写手判「页上已经写过」的碎片没有别的条目可挂：不改页，批了只给碎片打标
        case confirmCovered(path: String)

        /// 写哪一页；分组调整 = nil
        var targetPath: String? {
            switch self {
            case .newPage(let page): return page.path
            case .appendRecords(let path, _), .rewriteNow(let path, _, _, _), .retag(let path, _, _, _, _), .confirmCovered(let path): return path
            case .link(let from, _): return from
            case .direction(let d): return d.path
            case .regroup: return nil
            }
        }

        var direction: Direction? {
            if case .direction(let d) = self { return d }
            return nil
        }

        var isNewPage: Bool {
            if case .newPage = self { return true }
            return false
        }
    }

    /// C3 判的新旧关系（只用在追加记录 / 改现在 / 连线）
    enum Judgment: String, Codable, Sendable {
        case conflict, coexist
    }

    struct Item: Codable, Identifiable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case pending, approved, rejected
            case stale      // 页已变：生成后页被改过 / 新开页已存在，不硬盖
        }

        var id: String = UUID().uuidString
        var state: State = .pending
        var change: Change
        var judgment: Judgment? = nil
        var fragmentIds: [UUID] = []
        var cites: [Cite] = []
        /// 生成时目标页的版本；新开页 = nil（页必须还不存在）
        var baseVersion: String?
        /// 写手判「已被这页写过、不用再写」的碎片：批了一起标「已整理进」，驳回不连带
        var covered: [UUID]? = nil
        /// 写手交稿时代码硬查没过的项：照样交批，标给她看（修订到哪一步见提案的 revision）
        var checks: [String]? = nil
        /// 带着 checks 被她改过：标记是改之前的，没重新检查
        var checksEdited: Bool? = nil

        /// 批了要标「已整理进」的碎片
        var organizedIds: [UUID] { fragmentIds + (covered ?? []).filter { !fragmentIds.contains($0) } }
    }

    var id: String = UUID().uuidString
    var origin: Origin
    var createdAt: Date
    var title: String? = nil
    var seedSkipped: [String]? = nil
    /// 没整理完（轮数 / 字数到顶、被预算拦）
    var incomplete: Bool = false
    var items: [Item]
    /// 最后一条处理完的时间（30 天后清）
    var finishedAt: Date? = nil
    var directionRef: DirectionRef? = nil
    var request: Request? = nil
    /// 这份提案出自哪次整理记录（种子的目录 / 正文都带）
    var run: CatalogRunLink? = nil
    /// 属于哪个种子任务：有就存在 `.proposals/<任务 id>/` 里（目录提案的任务 id = 它自己的 id）
    var seedTask: String? = nil
    /// 写手交稿时收不进页的内容（只展示，不执行）
    var unapplied: [Unapplied]? = nil
    /// 她点了「知道了」的时间；没点之前这份提案算待阅，不进 30 天清理
    var unappliedSeenAt: Date? = nil
    /// 修订实际走到哪一步（重写一次后通过 / 还有没过的 / 没机会重写 / 重写用不了交的第一稿及原因）
    var revision: String? = nil

    var pendingCount: Int { items.filter { $0.state == .pending }.count }

    /// 没收进页、她还没看过的内容条数
    var unreadCount: Int { unappliedSeenAt == nil ? unapplied?.count ?? 0 : 0 }

    var status: Status {
        let pending = pendingCount
        if pending == 0 { return unreadCount == 0 ? .done : items.isEmpty ? .pending : .partial }
        return pending == items.count ? .pending : .partial
    }
}

// MARK: - 存取

struct WikiProposalStore: Sendable {
    let wiki: WikiStore

    static let keepDays = 30

    enum ProposalError: LocalizedError, Equatable {
        case notFound(String)
        case notPending(String)
        /// 她看到的和存着的不一样了（别处改过）：看过新内容再批
        case changed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "这份提案或这一条已经不在了"
            case .notPending: return "这一条已经批过或驳回了，不能再改"
            case .changed: return "这一条在别处改过了，看过新内容再批"
            }
        }
    }

    var folder: URL { wiki.root.appendingPathComponent(WikiStore.proposalsFolder, isDirectory: true) }

    /// 种子任务的文件夹（`.proposals/<任务 id>/`，名字是 UUID 的子文件夹）
    private func taskFolders() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { UUID(uuidString: $0) != nil }.map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    /// 已经存着的那份：顶层（日常 / 旧提案）或某个种子任务文件夹里
    private func url(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        let top = folder.appendingPathComponent(id + ".json")
        if FileManager.default.fileExists(atPath: top.path) { return top }
        return taskFolders().map { $0.appendingPathComponent(id + ".json") }.first { FileManager.default.fileExists(atPath: $0.path) } ?? top
    }

    private func url(for proposal: WikiProposal) -> URL? {
        guard UUID(uuidString: proposal.id) != nil else { return nil }
        guard let task = proposal.seedTask, UUID(uuidString: task) != nil else { return folder.appendingPathComponent(proposal.id + ".json") }
        return folder.appendingPathComponent(task, isDirectory: true).appendingPathComponent(proposal.id + ".json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    func save(_ proposal: WikiProposal) throws {
        guard let url = url(for: proposal) else { throw ProposalError.notFound(proposal.id) }
        try WikiStore.writeAtomic(Self.encoder.encode(proposal), to: url)
    }

    func load(_ id: String) -> WikiProposal? {
        guard let url = url(id), let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(WikiProposal.self, from: data)
    }

    /// 新→旧：顶层 + 各种子任务文件夹里的提案（任务快照 task.json 不算）
    func list() -> [WikiProposal] {
        var urls = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { folder.appendingPathComponent($0) }
        for task in taskFolders() {
            urls += ((try? FileManager.default.contentsOfDirectory(atPath: task.path)) ?? [])
                .filter { $0.hasSuffix(".json") && UUID(uuidString: String($0.dropLast(5))) != nil }.map { task.appendingPathComponent($0) }
        }
        return urls.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(WikiProposal.self, from: $0) }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// 待批条目 + 没收进页、还没看过的内容总数（审计台角标）
    func pendingItemCount() -> Int {
        list().reduce(0) { $0 + $1.pendingCount + $1.unreadCount }
    }

    /// 她看过没收进页的内容，点了「知道了」：之后按处理完的时间算 30 天
    @discardableResult
    func acknowledgeUnapplied(_ proposalId: String, now: Date = Date()) throws -> WikiProposal {
        guard var p = load(proposalId) else { throw ProposalError.notFound(proposalId) }
        guard p.unappliedSeenAt == nil else { return p }
        p.unappliedSeenAt = now
        if p.pendingCount == 0 { p.finishedAt = now }
        try save(p)
        return p
    }

    /// 全处理完满 30 天的删掉；返回删了几份。种子任务还没结束（等写 / 停了能继续）的目录不删；
    /// 结束了的任务（完成 / 结束没完成 / 放弃，按结束时间满 30 天），文件夹里没剩提案了就连任务快照一起删
    @discardableResult
    func purgeFinished(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.keepDays) * 86_400)
        let tasks = CatalogSeedTaskStore(wiki: wiki)
        var removed = 0
        for p in list() where p.status == .done && (p.finishedAt ?? p.createdAt) < cutoff {
            if p.seedTask == p.id, tasks.keeps(p.id, proposals: self) { continue }
            if let url = url(p.id), (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        for task in tasks.all() where !task.status(outline: load(task.id)).isOpen && (task.endedAt ?? task.createdAt) < cutoff {
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: tasks.folder(task.id).path)) ?? [])
                .filter { $0.hasSuffix(".json") && $0 != CatalogSeedTaskStore.fileName }
            if left.isEmpty { tasks.remove(task.id) }
        }
        return removed
    }

    func remove(_ id: String) {
        guard let url = url(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 批前就地改一条（文字 / 新旧判断）；只改待批的。记录行过同一套出处口径（`CatalogSources.checkEdited`）
    @discardableResult
    func edit(_ proposalId: String, itemId: String, change: WikiProposal.Change, judgment: WikiProposal.Judgment?) throws -> WikiProposal {
        guard var p = load(proposalId) else { throw ProposalError.notFound(proposalId) }
        guard let i = p.items.firstIndex(where: { $0.id == itemId }) else { throw ProposalError.notFound(itemId) }
        guard p.items[i].state == .pending else { throw ProposalError.notPending(itemId) }
        var change = change
        switch (p.items[i].change, change) {
        case (.newPage(let old), .newPage(var page)):
            page.records = try CatalogSources.checkEdited(page.records, original: old.records, allowed: CatalogSeedDrafts.allowed(p.items[i]))
            p.items[i].fragmentIds = CatalogSources.keptFragments(p.items[i].fragmentIds, original: old.records, edited: page.records)
            change = .newPage(page: page)
        case (.appendRecords(_, let old), .appendRecords(let path, let lines)):
            let edited = try CatalogSources.checkEdited(lines, original: old, allowed: CatalogSeedDrafts.allowed(p.items[i]))
            p.items[i].fragmentIds = CatalogSources.keptFragments(p.items[i].fragmentIds, original: old, edited: edited)
            change = .appendRecords(path: path, lines: edited)
        default:
            break
        }
        if p.items[i].checks != nil, p.items[i].change != change { p.items[i].checksEdited = true }
        p.items[i].change = change
        p.items[i].judgment = judgment
        try save(p)
        return p
    }

    /// 一次改好几条（文件库里改整份种子目录）：全是待批的才一起存，有一条不是就一条都不改
    @discardableResult
    func edit(_ proposalId: String, changes: [String: WikiProposal.Change]) throws -> WikiProposal {
        guard var p = load(proposalId) else { throw ProposalError.notFound(proposalId) }
        for (itemId, change) in changes {
            guard let i = p.items.firstIndex(where: { $0.id == itemId }) else { throw ProposalError.notFound(itemId) }
            guard p.items[i].state == .pending else { throw ProposalError.notPending(itemId) }
            if p.items[i].checks != nil, p.items[i].change != change { p.items[i].checksEdited = true }
            p.items[i].change = change
        }
        if !changes.isEmpty { try save(p) }
        return p
    }
}

// MARK: - 批 / 驳回

/// 文件那一步在后台，碰 SwiftData 的那一步在调用方的 context 上（审计台 = 主 context），写完显式 save。
/// 同一份 wiki 同一时间只一个在批 / 驳回
enum WikiProposalReview {

    typealias SaveMarks = @MainActor (ModelContext) throws -> Void

    private static let lock = CatalogLock()

    /// 一条条目文件那一步的结果
    private enum Written: Sendable {
        /// 已经不是待批（别处处理过了）
        case gone
        case stale
        case page(path: String, old: String?, new: String, fragments: [UUID])
        case regroup(RegroupDone)
        /// 方向：只记「已批」，不碰页和碎片
        case direction
        /// 确认已覆盖：页没动，只给碎片打标
        case covered(path: String, fragments: [UUID])
    }

    struct RegroupDone: Sendable {
        /// 旧页路径 → 新页路径
        var mapping: [String: String]
        var undo: RegroupUndo
    }

    /// 分组调整做到哪了：出错时照它尽力挪回去
    struct RegroupUndo: Sendable {
        struct Move: Sendable {
            var from: URL
            var to: URL
        }
        struct Relinked: Sendable {
            var path: String
            var data: Data
        }
        var createdFolders: [URL] = []
        var moved: [Move] = []
        /// 改了「连到」的页（当时的路径）和改之前的原文
        var relinked: [Relinked] = []
    }

    @MainActor
    private static func locked<T>(_ store: WikiProposalStore, _ body: () async throws -> T) async throws -> T {
        let key = store.wiki.root.path
        await lock.acquire(key)
        do {
            let value = try await body()
            await lock.release(key)
            return value
        } catch {
            await lock.release(key)
            throw error
        }
    }

    /// 批：`itemIds` = nil 是整批批（剩下待批的全批）。一条一条：写页 → 碎片打标存成功 → 条目存成「已批」；
    /// 哪一步出错就停在那条（它保持待批），抛出去。`seen` = 她批的时候看到的内容：存着的已经被别处改了就一条都不批
    @MainActor
    @discardableResult
    static func approve(_ proposalId: String, itemIds: Set<String>? = nil, seen: [String: WikiProposal.Change]? = nil,
                        store: WikiProposalStore, profileId: String,
                        context: ModelContext, now: Date = Date(), saveMarks: SaveMarks = { try $0.save() }) async throws -> WikiProposal {
        try await locked(store) {
            guard let initial = await Task.detached(priority: .userInitiated, operation: { store.load(proposalId) }).value else {
                throw WikiProposalStore.ProposalError.notFound(proposalId)
            }
            let ids = initial.items.filter { $0.state == .pending && itemIds?.contains($0.id) != false }.map(\.id)
            if let seen, let changed = initial.items.first(where: { item in ids.contains(item.id) && seen[item.id].map { $0 != item.change } ?? false }) {
                throw WikiProposalStore.ProposalError.changed(changed.id)
            }
            var touched: [String] = []
            var regrouped = false
            var approved = 0
            var failure: Error?
            for id in ids {
                do {
                    let written = try await Task.detached(priority: .userInitiated) {
                        try writeItem(proposalId, itemId: id, store: store, now: now)
                    }.value
                    switch written {
                    case .gone, .stale:
                        continue
                    case .direction:
                        break
                    case .covered(let path, let fragments):
                        try mark(fragments, page: path, context: context, now: now, saveMarks: saveMarks)
                    case .page(let path, _, _, let fragments):
                        try mark(fragments, page: path, context: context, now: now, saveMarks: saveMarks)
                        touched.append(path)
                    case .regroup(let done):
                        do {
                            try remap(done.mapping, profileId: profileId, context: context, saveMarks: saveMarks)
                        } catch {
                            let wiki = store.wiki
                            await Task.detached(priority: .userInitiated) { undoRegroup(done.undo, wiki: wiki) }.value
                            throw error
                        }
                        regrouped = true
                    }
                    try await Task.detached(priority: .userInitiated) {
                        try commit(proposalId, itemId: id, written: written, store: store, now: now)
                    }.value
                    approved += 1
                } catch {
                    failure = error
                    break
                }
            }

            let wiki = store.wiki
            let (proposal, indexError) = await Task.detached(priority: .userInitiated) { [touched, regrouped, approved] () -> (WikiProposal?, Error?) in
                var indexError: Error?
                do {
                    if regrouped {
                        try wiki.rebuildAllIndexes()
                    } else if !touched.isEmpty {
                        try wiki.rebuildIndexes(affecting: touched)
                    }
                } catch {
                    indexError = error
                }
                if approved > 0 {
                    let pages = Set(touched).count
                    MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: true,
                                          note: "整理提案批了 \(approved) 条" + (pages > 0 ? " · 写了 \(pages) 页" : "") + (regrouped ? " · 调了分组" : ""),
                                          model: "", now: now)
                }
                return (store.load(proposalId), indexError)
            }.value
            if let failure = failure ?? indexError { throw failure }
            guard let proposal else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
            return proposal
        }
    }

    /// 驳回：`itemIds` = nil 是整批驳回。条目明确引用的碎片标「整理时驳回」（covered 的不连带）
    @MainActor
    @discardableResult
    static func reject(_ proposalId: String, itemIds: Set<String>? = nil, store: WikiProposalStore,
                       context: ModelContext, now: Date = Date()) async throws -> WikiProposal {
        let (proposal, fragmentIds) = try await locked(store) {
            try await Task.detached(priority: .userInitiated) {
                try applyRejections(proposalId, itemIds: itemIds, store: store, now: now)
            }.value
        }
        let ids = Array(fragmentIds)
        if !ids.isEmpty {
            for m in try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { ids.contains($0.id) })) {
                m.organizeRejectedAt = now
            }
            if context.hasChanges { try context.save() }
        }
        return proposal
    }

    /// 认领已批、还没执行的方向：先记下开始时间再返回，同一条只会被认领一次（重复批 / 重复点不重付）
    @MainActor
    static func claimDirections(_ proposalId: String, itemIds: Set<String>? = nil, store: WikiProposalStore,
                                now: Date = Date()) async throws -> (WikiProposal, [WikiProposal.Item]) {
        try await locked(store) {
            try await Task.detached(priority: .userInitiated) { () -> (WikiProposal, [WikiProposal.Item]) in
                guard var p = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
                var claimed: [WikiProposal.Item] = []
                for i in p.items.indices where p.items[i].state == .approved && itemIds?.contains(p.items[i].id) != false {
                    guard case .direction(var d) = p.items[i].change, d.ranAt == nil, d.mode != .seed else { continue }
                    d.ranAt = now
                    p.items[i].change = .direction(d)
                    claimed.append(p.items[i])
                }
                if !claimed.isEmpty { try store.save(p) }
                return (p, claimed)
            }.value
        }
    }

    /// 拿着这份 wiki 的审批锁做事（清旧种子：不和批 / 驳回 / 认领交错）
    @MainActor
    static func exclusive<T>(_ store: WikiProposalStore, _ body: () async throws -> T) async throws -> T {
        try await locked(store, body)
    }

    /// 一次改好几条，同一把锁
    @MainActor
    @discardableResult
    static func edit(_ proposalId: String, changes: [String: WikiProposal.Change], store: WikiProposalStore) async throws -> WikiProposal {
        try await locked(store) {
            try await Task.detached(priority: .userInitiated) {
                try store.edit(proposalId, changes: changes)
            }.value
        }
    }

    /// 没收进页的内容「知道了」：同一把锁
    @MainActor
    @discardableResult
    static func acknowledgeUnapplied(_ proposalId: String, store: WikiProposalStore) async throws -> WikiProposal {
        try await locked(store) {
            try await Task.detached(priority: .userInitiated) { try store.acknowledgeUnapplied(proposalId) }.value
        }
    }

    /// 批前就地改一条：重读、只改还待批的、保存，都在同一把锁里（不和认领 / 记结果交错覆盖）
    @MainActor
    @discardableResult
    static func edit(_ proposalId: String, itemId: String, change: WikiProposal.Change, judgment: WikiProposal.Judgment?,
                     store: WikiProposalStore) async throws -> WikiProposal {
        try await locked(store) {
            try await Task.detached(priority: .userInitiated) {
                try store.edit(proposalId, itemId: itemId, change: change, judgment: judgment)
            }.value
        }
    }

    /// 执行前就没跑成（C3 关着、排队时点了停、楼层 / 模型没准备好）：把这些已批未执行的方向认领掉并记下原因，不再执行
    @MainActor
    static func closeDirections(_ proposalId: String, itemIds: Set<String>?, result: String, store: WikiProposalStore,
                                now: Date = Date()) async throws {
        try await locked(store) {
            try await Task.detached(priority: .userInitiated) {
                guard var p = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
                var changed = false
                for i in p.items.indices where p.items[i].state == .approved && itemIds?.contains(p.items[i].id) != false {
                    guard case .direction(var d) = p.items[i].change, d.ranAt == nil, d.mode != .seed else { continue }
                    d.ranAt = now
                    d.result = result
                    p.items[i].change = .direction(d)
                    changed = true
                }
                if changed { try store.save(p) }
            }.value
        }
    }

    /// 冷启动收尾：上次进程认领了、没记结果的方向（开始时间早于这次启动）给个终态——
    /// 按 directionRef 找到已交的正文就记已交，找不到记「上次运行中断」。不重发请求、不排队重跑
    @MainActor
    @discardableResult
    static func finishInterrupted(store: WikiProposalStore, before: Date) async throws -> Int {
        try await locked(store) {
            try await Task.detached(priority: .utility) { () -> Int in
                let all = store.list()
                var fixed = 0
                for var p in all {
                    var changed = false
                    for i in p.items.indices where p.items[i].state == .approved {
                        guard case .direction(var d) = p.items[i].change, let ran = d.ranAt, ran < before, d.result == nil else { continue }
                        let ref = WikiProposal.DirectionRef(proposalId: p.id, itemId: p.items[i].id)
                        if let content = all.first(where: { $0.directionRef == ref }) {
                            d.result = "交了 \(content.items.count) 条正文等批（上次运行中断前已交）"
                            d.contentProposalId = content.id
                        } else {
                            d.result = "上次运行中断，没交正文"
                        }
                        p.items[i].change = .direction(d)
                        changed = true
                        fixed += 1
                    }
                    if changed { try store.save(p) }
                }
                return fixed
            }.value
        }
    }

    /// 方向执行完记结果（同一把锁，不和批 / 驳回抢着写同一份提案）
    @MainActor
    static func recordDirection(_ proposalId: String, itemId: String, result: String, contentProposalId: String?,
                                store: WikiProposalStore) async throws {
        try await locked(store) {
            try await Task.detached(priority: .userInitiated) {
                guard var p = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
                guard let i = p.items.firstIndex(where: { $0.id == itemId }), case .direction(var d) = p.items[i].change else {
                    throw WikiProposalStore.ProposalError.notFound(itemId)
                }
                d.result = result
                d.contentProposalId = contentProposalId
                p.items[i].change = .direction(d)
                try store.save(p)
            }.value
        }
    }

    // MARK: SwiftData 那一步（存不成就把改的字段改回去再抛）

    @MainActor
    private static func mark(_ ids: [UUID], page: String, context: ModelContext, now: Date, saveMarks: SaveMarks) throws {
        guard !ids.isEmpty else { return }
        let rows = try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { ids.contains($0.id) }))
        let before = rows.map { ($0, $0.organizedAt, $0.organizedPage) }
        for m in rows {
            m.organizedAt = now
            m.organizedPage = page
        }
        do {
            try saveMarks(context)
        } catch {
            for (m, at, old) in before {
                m.organizedAt = at
                m.organizedPage = old
            }
            throw error
        }
    }

    @MainActor
    private static func remap(_ mapping: [String: String], profileId: String, context: ModelContext, saveMarks: SaveMarks) throws {
        let rows = SwiftDataMemoryStore().listAll(profileId: profileId, context: context).filter { $0.organizedPage.map { mapping[$0] != nil } ?? false }
        guard !rows.isEmpty else { return }
        let before = rows.map { ($0, $0.organizedPage) }
        for m in rows { m.organizedPage = m.organizedPage.flatMap { mapping[$0] } }
        do {
            try saveMarks(context)
        } catch {
            for (m, old) in before { m.organizedPage = old }
            throw error
        }
    }

    // MARK: 文件那一步（同步，后台调）

    /// 写一条：对不上 → 当场存成「页已变」；写成了先不改状态，等碎片标完再 commit
    private static func writeItem(_ proposalId: String, itemId: String, store: WikiProposalStore, now: Date) throws -> Written {
        guard var p = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
        guard let i = p.items.firstIndex(where: { $0.id == itemId }), p.items[i].state == .pending else { return .gone }
        var item = p.items[i]
        if let task = p.seedTask {
            let waiting = Set(store.list().filter { $0.seedTask == task }.flatMap(\.items)
                .filter { $0.state == .pending }.compactMap { $0.change.isNewPage ? $0.change.targetPath : nil })
            let alive = { (target: String) in store.wiki.pageExists(target) || waiting.contains(target) }
            switch item.change {
            case .newPage(var page):
                page.links = page.links.filter { alive($0.target) }
                item.change = .newPage(page: page)
            case .link(_, let link) where !alive(link.target):
                p.items[i].state = .stale
                if p.pendingCount == 0, p.finishedAt == nil { p.finishedAt = now }
                try store.save(p)
                return .stale
            default:
                break
            }
        }
        if case .direction = item.change {
            return .direction
        } else if case .confirmCovered(let path) = item.change {
            if let current = store.wiki.version(of: path), current == item.baseVersion { return .covered(path: path, fragments: item.organizedIds) }
        } else if case .regroup(_, let groups, let moves) = item.change {
            if let done = try applyRegroup(groups: groups, moves: moves, wiki: store.wiki, now: now) { return .regroup(done) }
        } else if let path = item.change.targetPath, WikiStore.isValidPagePath(path),
                  let written = try applyPage(item, path: path, wiki: store.wiki, now: now) {
            return .page(path: path, old: written.0, new: written.1, fragments: item.organizedIds)
        }
        p.items[i].state = .stale
        if p.pendingCount == 0, p.finishedAt == nil { p.finishedAt = now }
        try store.save(p)
        return .stale
    }

    /// 最后一步：条目存成「已批」；同页后面还待批、基线是旧版本的跟上新版本
    private static func commit(_ proposalId: String, itemId: String, written: Written, store: WikiProposalStore, now: Date) throws {
        guard var p = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
        guard let i = p.items.firstIndex(where: { $0.id == itemId }) else { throw WikiProposalStore.ProposalError.notFound(itemId) }
        p.items[i].state = .approved
        if case .page(let path, let old, let new, _) = written {
            for j in p.items.indices where j != i && p.items[j].state == .pending
                && p.items[j].change.targetPath == path && !p.items[j].change.isNewPage && p.items[j].baseVersion == old {
                p.items[j].baseVersion = new
            }
        }
        if p.pendingCount == 0, p.finishedAt == nil { p.finishedAt = now }
        try store.save(p)
    }

    static func applyRejections(_ proposalId: String, itemIds: Set<String>?, store: WikiProposalStore,
                                now: Date) throws -> (WikiProposal, Set<UUID>) {
        guard var p = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
        var fragments = Set<UUID>()
        for i in p.items.indices where p.items[i].state == .pending && itemIds?.contains(p.items[i].id) != false {
            p.items[i].state = .rejected
            fragments.formUnion(p.items[i].fragmentIds)
        }
        if p.pendingCount == 0, p.finishedAt == nil { p.finishedAt = now }
        try store.save(p)
        return (p, fragments)
    }

    /// 一页的条目：版本对不上 / 新开页已存在 → nil（置「页已变」）；对上了写，返回 (旧版本, 新版本)
    private static func applyPage(_ item: WikiProposal.Item, path: String, wiki: WikiStore, now: Date) throws -> (String?, String)? {
        let current = wiki.version(of: path)
        var page: WikiPage
        switch item.change {
        case .newPage(let p):
            guard current == nil else { return nil }
            page = p
            page.validUntil = WikiPage.until(p.validUntil, in: p.now)
        case .regroup, .direction, .confirmCovered:
            return nil
        default:
            guard let current, current == item.baseVersion, let existing = wiki.read(path) else { return nil }
            page = existing
            switch item.change {
            case .appendRecords(_, let lines): page.records += lines
            case .rewriteNow(_, _, let new, let until):
                page.now = new
                page.validUntil = WikiPage.until(until, in: new)
            case .link(_, let link): if !page.links.contains(link) { page.links.append(link) }
            case .retag(_, _, let hook, _, let triggers):
                page.hook = hook
                page.triggers = triggers
            case .newPage, .regroup, .direction, .confirmCovered: return nil
            }
        }
        return (current, try wiki.save(page, now: now))
    }

    /// 分组调整：先核对（源都在、目标都空、路径合法、目标不重），对不上 → nil；
    /// 建新分组写钩子 → 挪页 / 文件夹（连 .history）→ 所有页「连到」里的旧路径改新。中途抛错先尽力挪回原处再抛
    private static func applyRegroup(groups: [WikiProposal.NewGroup], moves: [WikiProposal.Move],
                                     wiki: WikiStore, now: Date) throws -> RegroupDone? {
        guard groups.allSatisfy({ WikiStore.isValidFolderPath($0.path) }),
              Set(moves.map(\.to)).count == moves.count else { return nil }
        let sources = Set(moves.map(\.from))
        var mapping: [String: String] = [:]
        for m in moves {
            guard !sources.contains(m.to), !wiki.pageExists(m.to), !wiki.folderExists(m.to) else { return nil }
            if wiki.pageExists(m.from) {
                guard WikiStore.isValidPagePath(m.to) else { return nil }
                mapping[m.from] = m.to
            } else if wiki.folderExists(m.from), m.from.split(separator: "/").count >= 2, WikiStore.isValidFolderPath(m.from),
                      WikiStore.isValidFolderPath(m.to), !m.to.hasPrefix(m.from + "/") {
                for page in wiki.pagePaths(under: m.from) { mapping[page] = m.to + page.dropFirst(m.from.count) }
            } else {
                return nil
            }
        }

        let fm = FileManager.default
        var undo = RegroupUndo()
        do {
            for g in groups {
                if !wiki.folderExists(g.path) {
                    try fm.createDirectory(at: wiki.folderURL(g.path), withIntermediateDirectories: true)
                    undo.createdFolders.append(wiki.folderURL(g.path))
                }
                try wiki.setGroupHook(g.path, hook: g.hook)
            }
            for m in moves {
                let isPage = wiki.pageExists(m.from)
                let from = isPage ? try wiki.pageURL(m.from) : wiki.folderURL(m.from)
                let to = isPage ? try wiki.pageURL(m.to) : wiki.folderURL(m.to)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                WikiInjectionCache.shared.invalidate()
                undo.moved.append(.init(from: from, to: to))
                try moveHistory(from: wiki.historyURL(m.from), to: wiki.historyURL(m.to), undo: &undo)
            }
            for path in wiki.pagePaths() {
                guard let url = try? wiki.pageURL(path), let data = try? Data(contentsOf: url) else { continue }
                var page = WikiPage.parse(String(decoding: data, as: UTF8.self), path: path)
                let links = page.links.map { link -> WikiPage.Link in
                    var l = link
                    if let to = mapping[l.target] { l.target = to }
                    return l
                }
                guard links != page.links else { continue }
                page.links = links
                undo.relinked.append(.init(path: path, data: data))
                try wiki.save(page, now: now)
            }
        } catch {
            undoRegroup(undo, wiki: wiki)
            throw error
        }
        return RegroupDone(mapping: mapping, undo: undo)
    }

    /// 尽力挪回：先把改过「连到」的页换回原文，再倒着挪回页 / 历史，最后删掉新建的空分组
    static func undoRegroup(_ undo: RegroupUndo, wiki: WikiStore) {
        let fm = FileManager.default
        for r in undo.relinked.reversed() {
            if let url = try? wiki.pageURL(r.path) { try? WikiStore.writeAtomic(r.data, to: url) }
        }
        for m in undo.moved.reversed() where fm.fileExists(atPath: m.to.path) && !fm.fileExists(atPath: m.from.path) {
            try? fm.createDirectory(at: m.from.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: m.to, to: m.from)
            if !m.to.standardizedFileURL.pathComponents.contains(WikiStore.historyFolder) {
                WikiInjectionCache.shared.invalidate()
            }
        }
        for folder in undo.createdFolders.reversed() {
            try? fm.removeItem(at: folder.appendingPathComponent(WikiStore.groupFileName))
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
        }
    }

    /// 历史目录跟着挪；目标已有（以前同名页留下的）就逐个文件挪进去，撞名的不动
    private static func moveHistory(from: URL, to: URL, undo: inout RegroupUndo) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        guard fm.fileExists(atPath: to.path) else {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: to)
            undo.moved.append(.init(from: from, to: to))
            return
        }
        for name in try fm.contentsOfDirectory(atPath: from.path) {
            let dest = to.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue {
                    try moveHistory(from: from.appendingPathComponent(name), to: dest, undo: &undo)
                }
                continue
            }
            try fm.moveItem(at: from.appendingPathComponent(name), to: dest)
            undo.moved.append(.init(from: from.appendingPathComponent(name), to: dest))
        }
    }
}
