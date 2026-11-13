import MemoryCore
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
        struct Candidate: Codable, Equatable, Sendable {
            var path: String
            /// 命中的名字（证据）
            var hits: [String]
            /// 给人看的「原料名 · 卡标题」（理由里那一行用；没有就显示路径）
            var label: String? = nil
            var factDomain: SeedFactDomain? = nil
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
        /// 种子目录项的回扫候选：原文里字面出现了这一项的名字、卡上却没提的原料（带命中的名字）。
        /// 不是原料：写页只给它们的要点卡，不能当记录出处（10-24 车头按 astra 审定）
        var candidates: [Candidate]? = nil
        /// true = 整理 path 这个分组（比如 用户），写手在分组下归页 / 开页；nil = 写 path 这一页
        var group: Bool? = nil
        /// 碎片以外的线索（A4 时间轴哪几天、到期的哪一天）：同一目标处理过的不再提，有新的才提
        var basis: [String]? = nil
        var factDomain: SeedFactDomain? = nil
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

    struct ApprovalReceipt: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable {
            case prepared, applied, committed, withdrawing, recoveryRequired
        }
        struct PageRecord: Codable, Equatable, Sendable {
            var path: String
            var beforeVersion: String?
            var afterVersion: String?
            var beforeHistoryEntry: String?
            var afterHistoryEntry: String?
            var beforePath: String? = nil
        }
        struct FragmentMark: Codable, Equatable, Sendable {
            var fragmentId: UUID
            var organizedAt: Date?
            var organizedPage: String?
            var organizeRejectedAt: Date?
            var afterOrganizedAt: Date?
            var afterOrganizedPage: String?
            var afterOrganizeRejectedAt: Date?
        }
        struct RebasedItem: Codable, Equatable, Sendable {
            var itemId: String
            var oldBase: String?
            var newBase: String?
            var changeFingerprint: String
        }
        /// 分组调整做到哪了：出错时照它尽力挪回去
        struct MoveRecord: Codable, Equatable, Sendable {
            struct HistoryMove: Codable, Equatable, Sendable {
                var from: String
                var to: String
                var version: String
            }
            var from: String
            var to: String
            var isFolder: Bool
            var history: [HistoryMove]
            var files: [String: String]
        }
        struct GroupImage: Codable, Equatable, Sendable {
            var path: String
            var createdByThisApproval: Bool
            var beforeImage: String?
            var afterImage: String?
            var afterVersion: String?
            var beforeVersion: String? = nil
            var beforePath: String? = nil
        }
        struct Progress: Codable, Equatable, Sendable {
            /// 中断核账必须区分完成原操作与完成失败补偿；旧收据按 phase / item.state 推断。
            enum Goal: String, Codable, Sendable {
                case approval, withdrawal, rollbackApproval, rollbackWithdrawal
            }
            var goal: Goal? = nil
            var completed: [String] = []
            var compensated: [String] = []
            var unresolved: [String] = []
            var failedStep: String?
        }
        var id: String = UUID().uuidString
        var proposalId: String
        var itemId: String
        var preparedAt: Date
        var approvedAt: Date?
        var phase: Phase = .prepared
        var pages: [PageRecord]
        var addedEntries: [String: [String]] = [:]
        var fragmentMarks: [FragmentMark]
        var rebasedItems: [RebasedItem] = []
        var dependencies: [String] = []
        /// regroup 的相对路径逆操作；history 只列真正迁走的文件，撞名留在原处的不列。
        var moves: [MoveRecord]? = nil
        var groupImages: [GroupImage]? = nil
        /// 改了「连到」的页（当时的路径）和改之前的原文
        var relinked: [PageRecord]? = nil

        var paths: [String] {
            var paths = Set<String>()
            for page in pages {
                paths.insert(page.path)
                if let before = page.beforePath { paths.insert(before) }
            }
            for page in relinked ?? [] {
                paths.insert(page.path)
                if let before = page.beforePath { paths.insert(before) }
            }
            for move in moves ?? [] {
                paths.insert(move.from)
                paths.insert(move.to)
            }
            for group in groupImages ?? [] {
                paths.insert(group.path + "/" + WikiStore.groupFileName)
                if let before = group.beforePath { paths.insert(before + "/" + WikiStore.groupFileName) }
            }
            return paths.sorted()
        }

        var folderPaths: [String] {
            (moves ?? []).filter(\.isFolder).flatMap { [$0.from, $0.to] }
        }
        var progress = Progress()
    }

    struct WithdrawRecord: Codable, Equatable, Sendable {
        var at: Date
        var receiptId: String
        var note: String
    }

    struct SourceSignature: Codable, Equatable, Sendable {
        enum ChangeKind: String, Codable, Sendable {
            case newPage, appendRecords, rewriteNow, link, retag, regroup, direction, confirmCovered
        }
        struct CiteLocation: Codable, Equatable, Hashable, Sendable {
            var layer: String
            var day: String?
            var filePath: String?
            var name: String?
            var profileId: String?
            var windowId: String?
            var segment: Int?
            var nodeId: String?
            var messageFrom: Int?
            var messageTo: Int?
        }
        struct Source: Codable, Equatable, Sendable {
            var path: String
            var version: String?
        }
        var changeKind: ChangeKind
        var targetPath: String
        var targetIsGroup: Bool
        var fragmentIds: [UUID]
        var cites: [CiteLocation]
        var sources: [Source]
    }

    struct Rejection: Codable, Equatable, Sendable {
        static let reasonLimit = 200
        var reason: String
        var at: Date
        var sourceSignature: SourceSignature
    }

    struct ConvertedLine: Codable, Equatable, Sendable {
        var index: Int
        var originalLine: String
        var originalLabels: [String]
        var newLine: String
    }

    struct ReviewRecord: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case rejected, reopened, handConverted
        }
        enum Origin: String, Codable, Sendable {
            case user, abandonedSeed
        }
        var id: String = UUID().uuidString
        var at: Date
        var kind: Kind
        /// 旧记录缺省为本人操作；放弃种子只标记系统作废，不补造驳回原因。
        var origin: Origin = .user
        var rejection: Rejection?
        var fragmentMarks: [ApprovalReceipt.FragmentMark]
        var conversions: [ConvertedLine]? = nil

        init(id: String = UUID().uuidString, at: Date, kind: Kind, origin: Origin = .user,
             rejection: Rejection?, fragmentMarks: [ApprovalReceipt.FragmentMark], conversions: [ConvertedLine]? = nil) {
            self.id = id
            self.at = at
            self.kind = kind
            self.origin = origin
            self.rejection = rejection
            self.fragmentMarks = fragmentMarks
            self.conversions = conversions
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            at = try values.decode(Date.self, forKey: .at)
            kind = try values.decode(Kind.self, forKey: .kind)
            origin = try values.decodeIfPresent(Origin.self, forKey: .origin) ?? .user
            rejection = try values.decodeIfPresent(Rejection.self, forKey: .rejection)
            fragmentMarks = try values.decode([ApprovalReceipt.FragmentMark].self, forKey: .fragmentMarks)
            conversions = try values.decodeIfPresent([ConvertedLine].self, forKey: .conversions)
        }
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
        var staleReason: String? = nil
        var approval: ApprovalReceipt? = nil
        var withdrawals: [WithdrawRecord]? = nil
        var rejection: Rejection? = nil
        var reviewHistory: [ReviewRecord]? = nil

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
    var beforeSave: (@Sendable (WikiProposal) throws -> Void)? = nil

    static let keepDays = 30

    enum ProposalError: LocalizedError, Equatable {
        case notFound(String)
        case notPending(String)
        case notRejected(String)
        /// 她看到的和存着的不一样了（别处改过）：看过新内容再批
        case changed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "这份提案或这一条已经不在了"
            case .notPending: return "这一条已经批过或驳回了，不能再改"
            case .notRejected: return "这一条不是已驳回的"
            case .changed: return "这一条在别处改过了，看过新内容再批"
            }
        }
    }

    var folder: URL { wiki.root.appendingPathComponent(WikiStore.proposalsFolder, isDirectory: true) }

    /// 读写删都走 `SafeWiki`（从楼层目录 / wiki 根起逐级不跟链接）：`.proposals` 或任务文件夹是链接 = 看不见、写不进、删不到
    private static let top = [WikiStore.proposalsFolder]

    /// 种子任务的文件夹（`.proposals/<任务 id>/`，名字是 UUID 的真子文件夹；链接不算）
    private func taskFolders() -> [String] {
        guard let listing = SafeWiki.names(in: Self.top, under: wiki.root) else { return [] }
        return listing.names.filter { UUID(uuidString: $0) != nil && (try? SafeWiki.itemType(listing.folder.appendingPathComponent($0))) == .typeDirectory }
    }

    /// 文件夹里这份是不是真文件（链接 / 不在 = 不算）
    private func exists(_ name: String, in parts: [String]) -> Bool {
        guard let dir = try? SafeWiki.folder(parts, under: wiki.root, create: false), let url = try? SafeWiki.file(name, in: dir) else { return false }
        return (try? SafeWiki.itemType(url)) == .typeRegular
    }

    /// 已经存着的那份在哪一层：顶层（日常 / 旧提案）或某个种子任务文件夹里；没有 = nil
    private func location(_ id: String) -> [String]? {
        guard UUID(uuidString: id) != nil else { return nil }
        if exists(id + ".json", in: Self.top) { return Self.top }
        return taskFolders().map { Self.top + [$0] }.first { exists(id + ".json", in: $0) }
    }

    private func location(for proposal: WikiProposal) -> [String]? {
        guard UUID(uuidString: proposal.id) != nil else { return nil }
        guard let task = proposal.seedTask, UUID(uuidString: task) != nil else { return Self.top }
        return Self.top + [task]
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
        try beforeSave?(proposal)
        guard let parts = location(for: proposal) else { throw ProposalError.notFound(proposal.id) }
        try SafeWiki.write(Self.encoder.encode(proposal), name: proposal.id + ".json", in: parts, under: wiki.root)
    }

    func load(_ id: String) -> WikiProposal? {
        guard let parts = location(id), let data = SafeWiki.read(id + ".json", in: parts, under: wiki.root) else { return nil }
        return try? Self.decoder.decode(WikiProposal.self, from: data)
    }

    /// 新→旧：顶层 + 各种子任务文件夹里的提案（任务快照 task.json 不算）；文件夹 / 文件是链接的跳过
    func list() -> [WikiProposal] {
        var found: [(name: String, parts: [String])] = (SafeWiki.names(in: Self.top, under: wiki.root)?.names ?? [])
            .filter { $0.hasSuffix(".json") }.map { ($0, Self.top) }
        for task in taskFolders() {
            found += (SafeWiki.names(in: Self.top + [task], under: wiki.root)?.names ?? [])
                .filter { $0.hasSuffix(".json") && UUID(uuidString: String($0.dropLast(5))) != nil }.map { ($0, Self.top + [task]) }
        }
        return found.compactMap { f in
            SafeWiki.read(f.name, in: f.parts, under: wiki.root).flatMap { try? Self.decoder.decode(WikiProposal.self, from: $0) }
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
            if p.items.contains(where: { $0.approval.map { $0.phase != .committed } ?? false }) { continue }
            if let parts = location(p.id) {
                do {
                    if p.seedTask == nil {
                        try SafeWiki.remove("images", in: Self.top + [p.id], under: wiki.root, isFolder: true)
                    }
                    try SafeWiki.remove(p.id + ".json", in: parts, under: wiki.root)
                    removed += 1
                } catch { continue }
            }
        }
        for task in tasks.all() where !task.status(outline: load(task.id)).isOpen && (task.endedAt ?? task.createdAt) < cutoff {
            guard let listing = SafeWiki.names(in: Self.top + [task.id], under: wiki.root) else { continue }
            let left = listing.names.filter { $0.hasSuffix(".json") && $0 != CatalogSeedTaskStore.fileName }
            if left.isEmpty { tasks.remove(task.id) }
        }
        return removed
    }

    func remove(_ id: String) {
        guard let parts = location(id) else { return }
        try? SafeWiki.remove(id + ".json", in: parts, under: wiki.root)
    }

    /// 批前就地改一条（文字 / 新旧判断）；只改待批的。记录行过同一套出处口径（`CatalogSources.checkEdited`）
    @discardableResult
    func edit(_ proposalId: String, itemId: String, change: WikiProposal.Change, judgment: WikiProposal.Judgment?,
              conversions: [CatalogSources.Conversion] = []) throws -> WikiProposal {
        guard var p = load(proposalId) else { throw ProposalError.notFound(proposalId) }
        guard let i = p.items.firstIndex(where: { $0.id == itemId }) else { throw ProposalError.notFound(itemId) }
        guard p.items[i].state == .pending else { throw ProposalError.notPending(itemId) }
        p.items[i] = try Self.edited(p.items[i], change: change, judgment: judgment, conversions: conversions)
        try save(p)
        return p
    }

    static func edited(_ original: WikiProposal.Item, change: WikiProposal.Change,
                       judgment: WikiProposal.Judgment?, conversions: [CatalogSources.Conversion] = [],
                       now: Date = Date()) throws -> WikiProposal.Item {
        var item = original
        var change = change
        let records: [String]
        switch (item.change, change) {
        case (.newPage(let old), .newPage(var page)):
            records = old.records
            page.path = old.path
            page.kind = old.kind
            page.factDomain = old.factDomain
            page.validUntil = WikiPage.until(page.validUntil, in: page.now)
            page.records = try CatalogSources.checkEdited(page.records, original: records, allowed: CatalogSeedDrafts.allowed(item), conversions: conversions)
            pruneSources(&item, original: records, edited: page.records)
            page.entries = keptEntries(old.entries, records: page.records, cites: original.cites)
            change = .newPage(page: page)
        case (.appendRecords(let path, let old), .appendRecords(_, let lines)):
            records = old
            let edited = try CatalogSources.checkEdited(lines, original: records, allowed: CatalogSeedDrafts.allowed(item), conversions: conversions)
            pruneSources(&item, original: records, edited: edited)
            change = .appendRecords(path: path, lines: edited)
        default:
            records = []
            guard conversions.isEmpty else { throw CatalogSeedDrafts.EditError.invalid("这行不需要转换") }
        }
        if !conversions.isEmpty {
            let audit = conversions.map {
                WikiProposal.ConvertedLine(index: $0.index, originalLine: records[$0.index],
                    originalLabels: CatalogSources.split(records[$0.index]).labels ?? [],
                    newLine: $0.newLine.trimmingCharacters(in: .whitespaces))
            }
            item.reviewHistory = (item.reviewHistory ?? []) + [
                .init(at: now, kind: .handConverted, rejection: nil, fragmentMarks: [], conversions: audit)
            ]
        }
        if item.checks != nil, item.change != change { item.checksEdited = true }
        item.change = change
        item.judgment = judgment
        return item
    }

    private static func pruneSources(_ item: inout WikiProposal.Item, original: [String], edited: [String]) {
        item.fragmentIds = CatalogSources.keptFragments(item.fragmentIds, original: original, edited: edited)
        let before = Set(original.flatMap { CatalogSources.split($0).labels ?? [] })
        let after = Set(edited.flatMap { CatalogSources.split($0).labels ?? [] })
        item.cites = item.cites.filter { cite in
            let label = CatalogSources.label(cite)
            let wasReferenced = before.contains(label) || cite.filePath.map(before.contains) == true
            let isReferenced = after.contains(label) || cite.filePath.map(after.contains) == true
            return !wasReferenced || isReferenced
        }
    }

    private static func keptEntries(_ entries: [String]?, records: [String], cites: [WikiProposal.Cite]) -> [String]? {
        let labels = Set(records.flatMap { CatalogSources.split($0).labels ?? [] })
        return entries.map { entries in
            entries.filter { entry in
                guard let separator = entry.lastIndex(of: "|") else { return false }
                let path = String(entry[..<separator])
                return labels.contains(path) || cites.contains { $0.filePath == path && labels.contains(CatalogSources.label($0)) }
            }
        }
    }

    /// 一次改好几条（文件库里改整份种子目录）：全是待批的才一起存，有一条不是就一条都不改
    @discardableResult
    func edit(_ proposalId: String, changes: [String: WikiProposal.Change]) throws -> WikiProposal {
        guard var p = load(proposalId) else { throw ProposalError.notFound(proposalId) }
        for (itemId, change) in changes {
            guard let i = p.items.firstIndex(where: { $0.id == itemId }) else { throw ProposalError.notFound(itemId) }
            guard p.items[i].state == .pending else { throw ProposalError.notPending(itemId) }
            p.items[i] = try Self.edited(p.items[i], change: change, judgment: p.items[i].judgment)
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
    typealias SaveReceipt = @Sendable (WikiProposal, WikiProposalStore) throws -> Void

    static func fingerprint(_ change: WikiProposal.Change) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return WikiStore.version(of: try encoder.encode(change))
    }
    private static func overlaps(_ a: String, _ b: String, aFolder: Bool, bFolder: Bool) -> Bool {
        a == b || (aFolder && b.hasPrefix(a + "/")) || (bFolder && a.hasPrefix(b + "/"))
    }

    private static func sharesPaths(_ a: WikiProposal.ApprovalReceipt, _ b: WikiProposal.ApprovalReceipt) -> Bool {
        a.paths.contains { path in
            b.paths.contains(path) || b.folderPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        } || b.paths.contains { path in
            a.folderPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    static func requireSettled(_ path: String, store: WikiProposalStore, unsettled: [WikiProposal]? = nil) throws {
        for p in unsettled ?? store.list() {
            if let item = p.items.first(where: { item in
                item.approval.map { receipt in
                    receipt.phase != .committed && (receipt.paths.contains(path)
                        || receipt.folderPaths.contains { path == $0 || path.hasPrefix($0 + "/") })
                } ?? false
            }) {
                let target = WithdrawTarget(proposal: p, item: item, primaryId: "")
                throw WikiStore.WikiError.conflict(path, "「\(path)」有未收口批准（\(target.label)），先处理恢复")
            }
        }
    }

    struct WithdrawTarget: Identifiable, Equatable, Sendable {
        var proposalId: String
        var itemId: String
        var receiptId: String
        var paths: [String]
        var id: String { proposalId + "/" + itemId }
        var kindLabel: String
        var authorization: Bool
        var proposalLabel: String?
        var regroupSummary: String?
        var label: String {
            (regroupSummary.map { $0 + " · " } ?? "") + paths.prefix(3).joined(separator: "、")
                + (paths.count > 3 ? "…" : "") + " · " + kindLabel + (proposalLabel.map { " · " + $0 } ?? "")
        }

        init(proposal: WikiProposal, item: WikiProposal.Item, primaryId: String) {
            proposalId = proposal.id
            itemId = item.id
            receiptId = item.approval?.id ?? proposal.id + "/" + item.id
            paths = item.approval?.paths ?? item.change.targetPath.map { [$0] } ?? []
            kindLabel = item.change.kindLabel
            authorization = item.change.direction != nil
            if case .regroup(_, let groups, let moves) = item.change {
                let folders = item.approval?.moves?.filter(\.isFolder).count ?? 0
                let pages = item.approval?.pages.count ?? moves.count
                regroupSummary = "页 \(pages) · 目录 \(folders) · 分组 \(item.approval?.groupImages?.count ?? groups.count) · 重连 \(item.approval?.relinked?.count ?? 0)"
            }
            if proposal.id != primaryId {
                proposalLabel = proposal.title.flatMap { $0.isEmpty ? nil : "提案「\($0)」" }
                    ?? "提案 " + proposal.createdAt.formatted(date: .numeric, time: .shortened)
            }
        }
    }

    struct WithdrawBlock: Equatable, Sendable {
        var target: WithdrawTarget
        var blockers: [WithdrawTarget] = []
        var reason: String
        var contentProposalId: String? = nil
    }

    struct WithdrawPlan: Sendable {
        var ordered: [WithdrawTarget] = []
        var blocked: [WithdrawBlock] = []
        var paths: [String] { Array(Set(ordered.filter { !$0.authorization }.flatMap(\.paths))).sorted() }
        var confirmation: String {
            var sections: [String] = []
            if !paths.isEmpty { sections.append("影响页：\n" + paths.joined(separator: "\n")) }
            let authorizations = ordered.filter(\.authorization)
            if !authorizations.isEmpty { sections.append("撤授权：\n" + authorizations.map(\.label).joined(separator: "\n")) }
            let changes = ordered.filter { !$0.authorization }
            if !changes.isEmpty { sections.append("撤回顺序（后批先撤）：\n" + changes.map(\.label).joined(separator: "\n")) }
            if !blocked.isEmpty {
                sections.append("被阻挡：\n" + blocked.map {
                    ([$0.target.label + "：" + $0.reason] + $0.blockers.map(\.label)).joined(separator: "\n")
                }.joined(separator: "\n"))
            }
            return sections.joined(separator: "\n\n")
        }
    }

    struct WithdrawResult: Sendable {
        enum Outcome: Equatable, Sendable {
            case withdrawn
            case blocked([WithdrawTarget], String)
            case failed(stage: String, restored: [String], unresolved: [String])
        }
        struct Item: Sendable {
            var target: WithdrawTarget
            var outcome: Outcome
            var message: String {
                switch outcome {
                case .withdrawn: return target.authorization ? "已撤授权" : "已撤回"
                case .blocked(let blockers, let reason):
                    return "撤回被阻挡：\(reason)" + (blockers.isEmpty ? "" : " · " + blockers.map(\.label).joined(separator: "；"))
                case .failed(let stage, let restored, let unresolved):
                    if unresolved.isEmpty {
                        return "此项未完成，已恢复 · 失败阶段：\(stage) · 已恢复：\(restored.joined(separator: "、")) · 未恢复：无"
                    }
                    let restored = restored.map { $0.hasPrefix("碎片 ") && $0.hasSuffix(" 已删，无需还原") ? "碎片已删，无需还原" : $0 }
                    return "已批 · 未收口 · 失败阶段：\(stage) · 已恢复：\(restored.joined(separator: "、")) · 未恢复：\(unresolved.joined(separator: "、"))"
                }
            }
        }
        var items: [Item] = []
        var indexFailure: String?
        var succeeded: Int { items.filter { $0.outcome == .withdrawn }.count }
        var message: String {
            "撤回 \(succeeded) / \(items.count) 条\n"
                + items.map { $0.target.label + "：" + $0.message }.joined(separator: "\n")
                + (indexFailure.map { "\n正文 / 标记已提交，索引更新失败：\($0)" } ?? "")
        }
    }

    private struct Receipted: Sendable {
        var proposal: WikiProposal
        var item: WikiProposal.Item
        var receipt: WikiProposal.ApprovalReceipt
        func target(relativeTo primaryId: String) -> WithdrawTarget {
            .init(proposal: proposal, item: item, primaryId: primaryId)
        }
    }

    private static func receipts(_ store: WikiProposalStore) -> [Receipted] {
        store.list().flatMap { p in p.items.compactMap { item in
            item.approval.map { Receipted(proposal: p, item: item, receipt: $0) }
        } }
    }

    static func directionBlock(_ item: WikiProposal.Item, proposal: WikiProposal, store: WikiProposalStore) async -> String? {
        guard let direction = item.change.direction else { return nil }
        if let id = direction.contentProposalId {
            guard let content = store.load(id) else { return "已交正文提案 \(id)（正文提案读不到了）" }
            let approved = content.items.filter { $0.state == .approved }.count
            let rejected = content.items.filter { $0.state == .rejected }.count
            let stale = content.items.filter { $0.state == .stale }.count
            return "已交正文提案 \(id)（\(content.pendingCount) 条待批 / 已批 \(approved) / 已驳回 \(rejected) / 已失效 \(stale)）"
        }
        if direction.mode == .seed {
            if let taskId = proposal.seedTask {
                let task = CatalogSeedTaskStore(wiki: store.wiki).load(taskId)
                if await CatalogRunner.shared.hasActiveSeed(taskId, profileId: task?.profileId) {
                    return "种子任务正在跑，先停任务"
                }
                if let task, task.page?.item == item.id,
                   ![.stopped, .ended, .complete, .abandoned].contains(task.state) {
                    return "种子任务正在写这一页，先停任务"
                }
            }
            return nil
        }
        guard direction.ranAt != nil else { return nil }
        return direction.result.map { "已认领 · " + $0 } ?? "正在查原料、写"
    }

    // 只按 receipt.dependencies 反向拓扑：没有被选中后继的项先撤；外部后继阻挡，不扩选，不按时间猜。
    private static func makeWithdrawPlan(_ proposalId: String, itemIds: Set<String>?, store: WikiProposalStore) async throws -> WithdrawPlan {
        guard let primary = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
        let all = receipts(store)
        let selectedItems = itemIds.map { ids in store.list().flatMap { p in
            p.items.filter { ids.contains($0.id) }.map { (p, $0) }
        } } ?? primary.items.filter { $0.state == .approved }.map { (primary, $0) }
        var plan = WithdrawPlan()
        var selected: [String: Receipted] = [:]
        for (p, item) in selectedItems {
            let target = WithdrawTarget(proposal: p, item: item, primaryId: proposalId)
            if item.state == .approved, item.change.direction != nil {
                if let reason = await directionBlock(item, proposal: p, store: store) {
                    plan.blocked.append(.init(target: target, reason: reason, contentProposalId: item.change.direction?.contentProposalId))
                } else { plan.ordered.append(target) }
                continue
            }
            guard item.state == .approved, let receipt = item.approval, receipt.phase == .committed,
                  let row = all.first(where: { $0.receipt.id == receipt.id }) else {
                plan.blocked.append(.init(target: target, reason: item.approval == nil
                    ? "当时未记录精确撤回凭据" : "批准尚未收口，先处理恢复"))
                continue
            }
            selected[receipt.id] = row
        }
        var remaining = selected
        while !remaining.isEmpty {
            let ready = remaining.values.filter { row in
                !remaining.values.contains { $0.receipt.dependencies.contains(row.receipt.id) }
            }.sorted { ($0.proposal.id, $0.item.id) < ($1.proposal.id, $1.item.id) }
            guard !ready.isEmpty else {
                for row in remaining.values { plan.blocked.append(.init(target: row.target(relativeTo: proposalId), reason: "撤回依赖成环，先核对凭据")) }
                break
            }
            for row in ready {
                let later = all.filter { other in
                    guard other.receipt.id != row.receipt.id else { return false }
                    if other.receipt.phase == .committed {
                        return other.receipt.dependencies.contains(row.receipt.id)
                            && !plan.ordered.contains { $0.receiptId == other.receipt.id }
                    }
                    return sharesPaths(row.receipt, other.receipt)
                        || !Set(row.receipt.fragmentMarks.map(\.fragmentId)).isDisjoint(with: other.receipt.fragmentMarks.map(\.fragmentId))
                }
                if later.isEmpty { plan.ordered.append(row.target(relativeTo: proposalId)) }
                else {
                    var reasons: [String] = []
                    if later.contains(where: { $0.receipt.phase == .committed }) {
                        reasons.append("先撤回依赖此项的后批条目")
                    }
                    let unsettled = later.filter { $0.receipt.phase != .committed }
                    if !unsettled.isEmpty {
                        reasons.append("同页 / 同碎片有未收口的批准或撤回（\(unsettled.map { $0.target(relativeTo: "").label }.joined(separator: "；"))），先处理恢复")
                    }
                    plan.blocked.append(.init(target: row.target(relativeTo: proposalId),
                        blockers: later.map { $0.target(relativeTo: proposalId) }, reason: reasons.joined(separator: "；")))
                }
                remaining[row.receipt.id] = nil
            }
        }
        var files: [String: String?] = [:]
        var folders: [String: Bool] = [:]
        for target in plan.ordered {
            guard let row = selected[target.receiptId] else { continue }
            let receipt = row.receipt
            do {
                if receipt.moves != nil {
                    try checkRegroup(receipt, wiki: store.wiki, after: true, files: files, folders: folders)
                } else {
                    for page in receipt.pages {
                        guard WikiStore.isValidPagePath(page.path), let after = page.afterVersion,
                              try previewVersion(page.path + ".md", wiki: store.wiki, files: files) == after else {
                            throw WikiStore.WikiError.conflict(page.path, "页后来改过 / 被删，先处理：\(page.path)")
                        }
                    }
                }
                for page in receipt.relinked ?? [] { files[page.path + ".md"] = .some(page.beforeVersion) }
                for move in receipt.moves ?? [] {
                    if move.isFolder {
                        for name in try previewFiles(move.to, wiki: store.wiki, files: files).keys {
                            files[move.to + "/" + name] = .some(nil)
                        }
                        for (name, version) in move.files { files[move.from + "/" + name] = .some(version) }
                        folders[move.to] = false
                        folders[move.from] = true
                    }
                    for history in move.history {
                        files[history.to] = .some(nil)
                        files[history.from] = .some(history.version)
                    }
                }
                for page in receipt.pages {
                    if let from = page.beforePath { files[page.path + ".md"] = .some(nil); files[from + ".md"] = .some(page.beforeVersion) }
                    else { files[page.path + ".md"] = .some(page.beforeVersion) }
                }
                for group in receipt.groupImages ?? [] {
                    let path = group.beforePath ?? group.path
                    if group.beforePath != nil { files[group.path + "/" + WikiStore.groupFileName] = .some(nil) }
                    files[path + "/" + WikiStore.groupFileName] = .some(group.beforeVersion)
                    if group.createdByThisApproval, try previewFiles(path, wiki: store.wiki, files: files).isEmpty {
                        folders[path] = false
                    }
                }
            } catch { plan.blocked.append(.init(target: target, reason: error.localizedDescription)) }
        }
        let blocked = Set(plan.blocked.map(\.target.receiptId))
        plan.ordered.removeAll { blocked.contains($0.receiptId) }
        return plan
    }

    @MainActor
    static func withdrawPlan(_ proposalId: String, itemIds: Set<String>? = nil, store: WikiProposalStore,
                             profileId: String, context: ModelContext) async throws -> WithdrawPlan {
        try await exclusive(wiki: store.wiki) {
            var plan = try await Task.detached(priority: .userInitiated) {
                try await makeWithdrawPlan(proposalId, itemIds: itemIds, store: store)
            }.value
            let all = await Task.detached(priority: .userInitiated) { receipts(store) }.value
            var marks: [UUID: WikiProposal.ApprovalReceipt.FragmentMark] = [:]
            for target in plan.ordered {
                guard let row = all.first(where: { $0.receipt.id == target.receiptId }) else { continue }
                do {
                    let current = try captureMarks(row.receipt.fragmentMarks.map(\.fragmentId), profileId: profileId, context: context, page: nil, now: Date())
                    for mark in row.receipt.fragmentMarks {
                        guard let currentMark = current.first(where: { $0.fragmentId == mark.fragmentId }) else { continue }
                        let live = marks[mark.fragmentId] ?? currentMark
                        guard sameMark(live, mark, after: true) else {
                            throw WikiStore.WikiError.conflict(mark.fragmentId.uuidString, "碎片标记后来改过，先处理")
                        }
                        marks[mark.fragmentId] = mark
                    }
                } catch { plan.blocked.append(.init(target: target, reason: error.localizedDescription)) }
            }
            let blocked = Set(plan.blocked.map(\.target.receiptId))
            plan.ordered.removeAll { blocked.contains($0.receiptId) }
            return plan
        }
    }

    @MainActor
    private static func captureMarks(_ ids: [UUID], profileId: String, context: ModelContext,
                                     page: String?, now: Date) throws -> [WikiProposal.ApprovalReceipt.FragmentMark] {
        guard !ids.isEmpty else { return [] }
        let rows = try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { ids.contains($0.id) && $0.profileId == profileId }))
        return rows.map { .init(fragmentId: $0.id, organizedAt: $0.organizedAt, organizedPage: $0.organizedPage,
            organizeRejectedAt: $0.organizeRejectedAt, afterOrganizedAt: page == nil ? $0.organizedAt : now,
            afterOrganizedPage: page ?? $0.organizedPage, afterOrganizeRejectedAt: $0.organizeRejectedAt) }
            .sorted { $0.fragmentId.uuidString < $1.fragmentId.uuidString }
    }

    private static func sameDate(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return abs(a.timeIntervalSince(b)) < 0.001
        default: return false
        }
    }

    private static func sameMark(_ live: WikiProposal.ApprovalReceipt.FragmentMark,
                                 _ saved: WikiProposal.ApprovalReceipt.FragmentMark, after: Bool) -> Bool {
        sameDate(live.organizedAt, after ? saved.afterOrganizedAt : saved.organizedAt)
            && live.organizedPage == (after ? saved.afterOrganizedPage : saved.organizedPage)
            && sameDate(live.organizeRejectedAt, after ? saved.afterOrganizeRejectedAt : saved.organizeRejectedAt)
    }

    @MainActor
    private static func persistedMarksMatch(_ marks: [WikiProposal.ApprovalReceipt.FragmentMark], after: Bool,
                                            profileId: String, context: ModelContext) throws -> Bool {
        let fresh = ModelContext(context.container)
        let live = try captureMarks(marks.map(\.fragmentId), profileId: profileId, context: fresh, page: nil, now: Date())
        return marks.allSatisfy { saved in
            live.first { $0.fragmentId == saved.fragmentId }.map { sameMark($0, saved, after: after) } ?? true
        }
    }

    @MainActor
    private static func setMarks(_ marks: [WikiProposal.ApprovalReceipt.FragmentMark], after: Bool,
                                 profileId: String, context: ModelContext, saveMarks: SaveMarks) throws {
        guard !marks.isEmpty else { return }
        let ids = marks.map(\.fragmentId)
        let rows = try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { ids.contains($0.id) && $0.profileId == profileId }))
        guard !rows.isEmpty else { return }
        let before = rows.map { ($0, $0.organizedAt, $0.organizedPage, $0.organizeRejectedAt) }
        for row in rows {
            guard let mark = marks.first(where: { $0.fragmentId == row.id }) else { continue }
            row.organizedAt = after ? mark.afterOrganizedAt : mark.organizedAt
            row.organizedPage = after ? mark.afterOrganizedPage : mark.organizedPage
            row.organizeRejectedAt = after ? mark.afterOrganizeRejectedAt : mark.organizeRejectedAt
        }
        do { try saveMarks(context) }
        catch {
            for (row, at, page, rejected) in before {
                row.organizedAt = at; row.organizedPage = page; row.organizeRejectedAt = rejected
            }
            throw error
        }
    }

    private static func persist(_ receipt: WikiProposal.ApprovalReceipt, store: WikiProposalStore) throws {
        guard var p = store.load(receipt.proposalId), let i = p.items.firstIndex(where: { $0.id == receipt.itemId }) else {
            throw WikiProposalStore.ProposalError.notFound(receipt.itemId)
        }
        p.items[i].approval = receipt
        if receipt.phase != .committed { p.finishedAt = nil }
        try store.save(p)
    }

    /// nil 只选本提案已批项；显式 itemIds 可跨提案，始终在本楼层内查找，不自动扩选依赖。
    /// 文件和标记补偿核实后才发布通知；未恢复目标保留在原 receipt，不能再覆盖。
    @MainActor
    static func withdraw(_ proposalId: String, itemIds: Set<String>? = nil, store: WikiProposalStore, profileId: String,
                         context: ModelContext, now: Date = Date(), saveMarks: SaveMarks = { try $0.save() },
                         beforeMove: @escaping @Sendable (String, String) throws -> Void = { _, _ in }) async throws -> WithdrawResult {
        try await exclusive(wiki: store.wiki) {
            let plan = try await Task.detached(priority: .userInitiated) {
                try await makeWithdrawPlan(proposalId, itemIds: itemIds, store: store)
            }.value
            var result = WithdrawResult(items: plan.blocked.map { .init(target: $0.target, outcome: .blocked($0.blockers, $0.reason)) })
            var touched: [String] = []
            var regrouped = false
            for (position, target) in plan.ordered.enumerated() {
                let outcome = await withdrawOne(target, store: store, profileId: profileId, context: context, now: now,
                                                saveMarks: saveMarks, beforeMove: beforeMove)
                result.items.append(.init(target: target, outcome: outcome))
                if !target.authorization {
                    touched += target.paths
                    regrouped = regrouped || target.regroupSummary != nil
                }
                if outcome != .withdrawn {
                    for skipped in plan.ordered.dropFirst(position + 1) {
                        result.items.append(.init(target: skipped, outcome: .blocked([target], "前一项未完成，后续未执行")))
                    }
                    break
                }
            }
            do {
                let paths = touched
                try await Task.detached(priority: .userInitiated) { [regrouped] in
                    if regrouped { try store.wiki.rebuildAllIndexes() }
                    else if !paths.isEmpty { try store.wiki.rebuildIndexes(affecting: paths) }
                    for path in Set(paths) where WikiStore.isValidPagePath(path) {
                        CatalogRecallIndexer.shared.changed(at: try store.wiki.pageURL(path))
                    }
                    if regrouped { CatalogRecallIndexer.shared.changed(at: store.wiki.root.appendingPathComponent(WikiStore.indexFileName)) }
                }.value
                try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: profileId)
            } catch { result.indexFailure = error.localizedDescription }
            let note = result.message + "\n" + result.items.map {
                "\($0.target.proposalId) / \($0.target.itemId) / \($0.target.receiptId)"
            }.joined(separator: "\n")
            let ok = result.succeeded == result.items.count && result.indexFailure == nil
            await Task.detached(priority: .utility) {
                MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: ok, note: note, model: "", now: now, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
            }.value
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
            NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
            return result
        }
    }

    @MainActor
    private static func withdrawOne(_ target: WithdrawTarget, store: WikiProposalStore, profileId: String,
                                    context: ModelContext, now: Date, saveMarks: SaveMarks,
                                    beforeMove: @escaping @Sendable (String, String) throws -> Void) async -> WithdrawResult.Outcome {
        guard let original = await Task.detached(priority: .userInitiated, operation: { store.load(target.proposalId) }).value,
              let item = original.items.first(where: { $0.id == target.itemId }), item.state == .approved else {
            return .blocked([], "批准凭据已变，重新查看")
        }
        if item.change.direction != nil {
            do {
                return try await Task.detached(priority: .userInitiated) {
                    if let reason = await directionBlock(item, proposal: original, store: store) { return .blocked([], reason) }
                    try commitWithdrawal(target, receipt: item.approval, store: store, now: now, note: "已撤授权")
                    return .withdrawn
                }.value
            } catch { return .failed(stage: "提交撤授权：\(error.localizedDescription)", restored: [], unresolved: []) }
        }
        guard var receipt = item.approval, receipt.phase == .committed else {
            return .blocked([], "批准凭据已变，重新查看")
        }
        if receipt.moves != nil {
            return await withdrawRegroup(target, receipt: receipt, store: store, profileId: profileId, context: context,
                                          now: now, saveMarks: saveMarks, beforeMove: beforeMove)
        }
        var stage = "预检"
        var pageAttempted = false
        var marksChanged = false
        do {
            let checked = receipt
            try await Task.detached(priority: .userInitiated) {
                for page in checked.pages {
                    _ = try store.wiki.checkedPageURL(page.path)
                    guard let after = page.afterVersion, store.wiki.version(of: page.path) == after else {
                        throw WikiStore.WikiError.conflict(page.path, "页后来改过 / 被删，先处理")
                    }
                    if page.beforeVersion != nil, page.beforeVersion != page.afterVersion {
                        guard let entry = page.beforeHistoryEntry, let text = store.wiki.historyText(page.path, entry: entry),
                              WikiStore.version(of: Data(text.utf8)) == page.beforeVersion else {
                            throw WikiStore.WikiError.conflict(page.path, "批准前像缺失 / 已变，不能撤回")
                        }
                    }
                }
            }.value
            let currentMarks = try captureMarks(receipt.fragmentMarks.map(\.fragmentId), profileId: profileId, context: context, page: nil, now: now)
            guard receipt.fragmentMarks.allSatisfy({ saved in
                currentMarks.first { $0.fragmentId == saved.fragmentId }.map { sameMark($0, saved, after: true) } ?? true
            }) else { return .blocked([], "碎片标记后来改过，先处理") }
            receipt.phase = .withdrawing
            receipt.progress = .init(goal: .withdrawal)
            receipt.progress.compensated = receipt.fragmentMarks.filter { saved in
                !currentMarks.contains { $0.fragmentId == saved.fragmentId }
            }.map { "碎片 \($0.fragmentId) 已删，无需还原" }
            stage = "持久撤回进度"
            try await saveProgress(receipt, store: store)
            for index in receipt.pages.indices {
                let page = receipt.pages[index]
                if page.beforeVersion == page.afterVersion { continue }
                if page.beforeVersion != nil {
                    stage = "保存撤回前像：\(page.path)"
                    receipt.pages[index].afterHistoryEntry = try await Task.detached(priority: .userInitiated) {
                        try store.wiki.snapshotCurrent(page.path, now: now)
                    }.value
                    try await saveProgress(receipt, store: store)
                }
                stage = "恢复页：\(page.path)"
                pageAttempted = true
                let entry = try await Task.detached(priority: .userInitiated) { () -> String? in
                    let afterEntry: String?
                    if page.beforeVersion == nil {
                        do {
                            afterEntry = try store.wiki.delete(page.path, expectedVersion: page.afterVersion!, now: now,
                                reason: "撤回新页", rebuildingIndexes: false).receipt.historyEntry
                        } catch {
                            if let failure = error as? WikiStore.DeletionFailure, store.wiki.version(of: page.path) == page.afterVersion {
                                try? store.wiki.cancelDeletion(id: failure.receipt.id)
                            }
                            throw error
                        }
                    } else {
                        guard let entry = page.beforeHistoryEntry else { throw WikiStore.WikiError.notFound(page.path + " 前像") }
                        _ = try store.wiki.restore(page.path, entry: entry, expectedVersion: page.afterVersion, now: now,
                                                  recordingHistory: false)
                        afterEntry = nil
                    }
                    guard store.wiki.version(of: page.path) == page.beforeVersion else {
                        throw WikiStore.WikiError.conflict(page.path, "恢复后版本核验失败")
                    }
                    return afterEntry
                }.value
                if let entry { receipt.pages[index].afterHistoryEntry = entry }
                receipt.progress.completed.append("页：\(page.path)")
                try await saveProgress(receipt, store: store)
            }
            stage = "恢复碎片标记"
            try setMarks(receipt.fragmentMarks, after: false, profileId: profileId, context: context, saveMarks: saveMarks)
            marksChanged = true
            guard try persistedMarksMatch(receipt.fragmentMarks, after: false, profileId: profileId, context: context) else {
                throw WikiStore.WikiError.conflict("碎片", "恢复后标记未持久化")
            }
            receipt.progress.completed.append("标记")
            try await saveProgress(receipt, store: store)
            stage = "提交撤回"
            let committed = receipt
            try await Task.detached(priority: .userInitiated) {
                try commitWithdrawal(target, receipt: committed, store: store, now: now)
            }.value
            return .withdrawn
        } catch {
            if stage == "预检" { return .blocked([], error.localizedDescription) }
            receipt.progress.failedStep = stage + "：\(error.localizedDescription)"
            receipt.progress.goal = .rollbackWithdrawal
            for page in receipt.pages.reversed() {
                let targetName = "页：\(page.path)"
                do {
                    let saved = page
                    try await Task.detached(priority: .userInitiated) {
                        let current = store.wiki.version(of: saved.path)
                        if current == saved.afterVersion { return }
                        guard current == saved.beforeVersion, let entry = saved.afterHistoryEntry else {
                            throw WikiStore.WikiError.conflict(saved.path, "补偿版本不符 / 后像缺失")
                        }
                        _ = try store.wiki.checkedPageURL(saved.path, create: true)
                        _ = try store.wiki.restore(saved.path, entry: entry, expectedVersion: current, now: now)
                        guard store.wiki.version(of: saved.path) == saved.afterVersion else {
                            throw WikiStore.WikiError.conflict(saved.path, "补偿后版本核验失败")
                        }
                    }.value
                    receipt.progress.compensated.append(targetName)
                    try await saveProgress(receipt, store: store)
                } catch { receipt.progress.unresolved.append(targetName + "（\(error.localizedDescription)）") }
            }
            do {
                let persisted = try persistedMarksMatch(receipt.fragmentMarks, after: true, profileId: profileId, context: context)
                if marksChanged || !persisted {
                    try setMarks(receipt.fragmentMarks, after: true, profileId: profileId, context: context, saveMarks: saveMarks)
                }
                guard try persistedMarksMatch(receipt.fragmentMarks, after: true, profileId: profileId, context: context) else {
                    throw WikiStore.WikiError.conflict("碎片", "补偿后标记核验失败")
                }
                receipt.progress.compensated.append("标记")
            } catch { receipt.progress.unresolved.append("标记（\(error.localizedDescription)）") }
            if pageAttempted { receipt.progress.completed.append("已核对文件补偿") }
            receipt.phase = receipt.progress.unresolved.isEmpty ? .committed : .recoveryRequired
            let recovered = receipt
            do {
                try await Task.detached(priority: .userInitiated) {
                    var p = original
                    let i = p.items.firstIndex { $0.id == target.itemId }!
                    p.items[i].approval = recovered
                    if recovered.phase == .recoveryRequired { p.finishedAt = nil }
                    try store.save(p)
                }.value
            } catch {
                receipt.phase = .recoveryRequired
                receipt.progress.unresolved.append("proposal（\(error.localizedDescription)）")
                let failed = receipt
                try? await Task.detached(priority: .userInitiated) { try persist(failed, store: store) }.value
            }
            return .failed(stage: receipt.progress.failedStep ?? stage, restored: receipt.progress.compensated, unresolved: receipt.progress.unresolved)
        }
    }

    private static func saveProgress(_ receipt: WikiProposal.ApprovalReceipt, store: WikiProposalStore) async throws {
        try await Task.detached(priority: .userInitiated) { try persist(receipt, store: store) }.value
    }

    private static func commitWithdrawal(_ target: WithdrawTarget, receipt: WikiProposal.ApprovalReceipt?,
                                         store: WikiProposalStore, now: Date, note: String = "已撤回") throws {
        guard var proposal = store.load(target.proposalId),
              let index = proposal.items.firstIndex(where: { $0.id == target.itemId }) else {
            throw WikiProposalStore.ProposalError.notFound(target.itemId)
        }
        for rebase in receipt?.rebasedItems ?? [] {
            guard let j = proposal.items.firstIndex(where: { $0.id == rebase.itemId }), proposal.items[j].state == .pending else { continue }
            if try fingerprint(proposal.items[j].change) == rebase.changeFingerprint, proposal.items[j].baseVersion == rebase.newBase {
                proposal.items[j].baseVersion = rebase.oldBase
            } else { proposal.items[j].staleReason = "基线已随上次批准跟进，撤回后需重新对照" }
        }
        proposal.items[index].state = .pending
        switch proposal.items[index].change {
        case .confirmCovered, .regroup, .direction: break
        default: proposal.items[index].baseVersion = receipt?.pages.first.flatMap { store.wiki.version(of: $0.path) }
        }
        proposal.items[index].approval = nil
        proposal.items[index].withdrawals = (proposal.items[index].withdrawals ?? [])
            + [.init(at: now, receiptId: receipt?.id ?? target.receiptId, note: note)]
        proposal.finishedAt = nil
        try store.save(proposal)
    }

    @MainActor
    private static func withdrawRegroup(_ target: WithdrawTarget, receipt initial: WikiProposal.ApprovalReceipt,
                                        store: WikiProposalStore, profileId: String, context: ModelContext, now: Date,
                                        saveMarks: SaveMarks, beforeMove: @escaping @Sendable (String, String) throws -> Void) async -> WithdrawResult.Outcome {
        var receipt = initial
        var stage = "预检"
        do {
            try await Task.detached(priority: .userInitiated) { try checkRegroup(initial, wiki: store.wiki, after: true) }.value
            guard try persistedMarksMatch(receipt.fragmentMarks, after: true, profileId: profileId, context: context) else {
                return .blocked([], "碎片标记后来改过，先处理")
            }
            receipt.phase = .withdrawing
            receipt.progress = .init(goal: .withdrawal)
            stage = "持久撤回前像"
            let prepared = receipt
            receipt = try await Task.detached(priority: .userInitiated) {
                var receipt = prepared
                for index in (receipt.relinked ?? []).indices {
                    let path = receipt.relinked![index].path
                    let entry = try store.wiki.snapshotCurrent(path, now: now)
                    receipt.relinked?[index].afterHistoryEntry = entry
                }
                try persist(receipt, store: store)
                return receipt
            }.value
            stage = "恢复分组调整"
            let preparedFiles = receipt
            receipt = await Task.detached(priority: .userInitiated) {
                var receipt = preparedFiles
                do {
                    try restoreRegroup(&receipt, wiki: store.wiki, after: false, now: now, beforeMove: beforeMove,
                                       checkpoint: { try persist($0, store: store) })
                } catch { receipt.progress.failedStep = "恢复分组调整：\(error.localizedDescription)" }
                return receipt
            }.value
            if let failure = receipt.progress.failedStep { throw WikiStore.WikiError.conflict(target.label, failure) }
            stage = "恢复碎片映射"
            try setMarks(receipt.fragmentMarks, after: false, profileId: profileId, context: context, saveMarks: saveMarks)
            guard try persistedMarksMatch(receipt.fragmentMarks, after: false, profileId: profileId, context: context) else {
                throw WikiStore.WikiError.conflict("碎片", "恢复后标记未持久化")
            }
            receipt.progress.completed += receipt.fragmentMarks.map { "碎片：\($0.fragmentId)" }
            try await saveProgress(receipt, store: store)
            stage = "提交撤回"
            let committed = receipt
            try await Task.detached(priority: .userInitiated) {
                try checkRegroup(committed, wiki: store.wiki, after: false)
                try commitWithdrawal(target, receipt: committed, store: store, now: now)
            }.value
            return .withdrawn
        } catch {
            if stage == "预检" { return .blocked([], error.localizedDescription) }
            receipt.progress.failedStep = receipt.progress.failedStep ?? stage + "：\(error.localizedDescription)"
            receipt.progress.goal = .rollbackWithdrawal
            receipt.phase = .recoveryRequired
            let partial = receipt
            receipt = await Task.detached(priority: .userInitiated) {
                var receipt = partial
                try? restoreRegroup(&receipt, wiki: store.wiki, after: true, now: now, bestEffort: true,
                                    beforeMove: beforeMove, checkpoint: { try persist($0, store: store) })
                let checks = regroupChecks(receipt, wiki: store.wiki, after: true)
                receipt.progress.unresolved = checks.filter { !$0.1 }.map(\.0)
                receipt.progress.compensated = Array(Set(checks.filter(\.1).map(\.0))).sorted()
                return receipt
            }.value
            do {
                if try !persistedMarksMatch(receipt.fragmentMarks, after: true, profileId: profileId, context: context) {
                    try setMarks(receipt.fragmentMarks, after: true, profileId: profileId, context: context, saveMarks: saveMarks)
                }
                guard try persistedMarksMatch(receipt.fragmentMarks, after: true, profileId: profileId, context: context) else {
                    throw WikiStore.WikiError.conflict("碎片", "补偿后标记核验失败")
                }
                receipt.progress.compensated += receipt.fragmentMarks.map { "碎片：\($0.fragmentId)" }
            } catch { receipt.progress.unresolved.append("碎片（\(error.localizedDescription)）") }
            receipt.phase = receipt.progress.unresolved.isEmpty ? .committed : .recoveryRequired
            do { try await saveProgress(receipt, store: store) }
            catch {
                receipt.phase = .recoveryRequired
                receipt.progress.unresolved.append("proposal（\(error.localizedDescription)）")
                try? await saveProgress(receipt, store: store)
            }
            return .failed(stage: receipt.progress.failedStep ?? stage, restored: receipt.progress.compensated, unresolved: receipt.progress.unresolved)
        }
    }

    @MainActor
    private static func recoverApproval(_ proposalId: String, itemId: String, store: WikiProposalStore, profileId: String,
                                        context: ModelContext, now: Date, saveMarks: SaveMarks, keepReceipt: Bool = false) async {
        guard let p = await Task.detached(priority: .userInitiated, operation: { store.load(proposalId) }).value,
              let i = p.items.firstIndex(where: { $0.id == itemId }), var receipt = p.items[i].approval,
              receipt.phase != .committed else { return }
        receipt.progress.goal = .rollbackApproval
        receipt.progress.unresolved = []
        if receipt.moves != nil {
            let initial = receipt
            receipt = await Task.detached(priority: .userInitiated) {
                var receipt = initial
                try? restoreRegroup(&receipt, wiki: store.wiki, after: false, now: now, bestEffort: true,
                                    checkpoint: { try persist($0, store: store) })
                receipt.progress.unresolved = regroupChecks(receipt, wiki: store.wiki, after: false).filter { !$0.1 }.map(\.0)
                return receipt
            }.value
        }
        for page in receipt.moves == nil ? receipt.pages : [] {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let current = store.wiki.version(of: page.path)
                    if current == page.beforeVersion { return }
                    guard current == page.afterVersion else { throw WikiStore.WikiError.conflict(page.path, "批准补偿版本不符") }
                    if page.beforeVersion == nil {
                        do {
                            try store.wiki.delete(page.path, expectedVersion: page.afterVersion!, now: now,
                                                  reason: "批准补偿", rebuildingIndexes: false)
                        } catch {
                            if let failure = error as? WikiStore.DeletionFailure, store.wiki.version(of: page.path) == page.afterVersion {
                                try? store.wiki.cancelDeletion(id: failure.receipt.id)
                            }
                            throw error
                        }
                    } else if let entry = page.beforeHistoryEntry {
                        guard store.wiki.historyText(page.path, entry: entry).map({ WikiStore.version(of: Data($0.utf8)) }) == page.beforeVersion else {
                            throw WikiStore.WikiError.conflict(page.path, "批准前像版本不符")
                        }
                        _ = try store.wiki.restore(page.path, entry: entry, expectedVersion: current, now: now)
                    } else { throw WikiStore.WikiError.notFound(page.path + " 前像") }
                }.value
                receipt.progress.compensated.append(page.path)
            } catch { receipt.progress.unresolved.append(page.path) }
        }
        do {
            let live = try captureMarks(receipt.fragmentMarks.map(\.fragmentId), profileId: profileId,
                                        context: ModelContext(context.container), page: nil, now: now)
            for mark in receipt.fragmentMarks {
                guard let current = live.first(where: { $0.fragmentId == mark.fragmentId }),
                      !sameMark(current, mark, after: false) else { continue }
                guard sameMark(current, mark, after: true) else { continue }
                try setMarks([mark], after: false, profileId: profileId, context: context, saveMarks: saveMarks)
            }
        } catch { receipt.progress.unresolved.append("标记") }
        let checks = await receiptChecks(receipt, store: store, after: false, profileId: profileId, context: context, now: now)
        receipt.progress.unresolved = checks.filter { !$0.1 }.map { "需人工：" + $0.0 }
        receipt.progress.compensated = Array(Set(checks.filter(\.1).map(\.0))).sorted()
        receipt.phase = .recoveryRequired
        receipt.progress.failedStep = "批准未完成"
        let recovered = receipt
        try? await Task.detached(priority: .userInitiated) {
            var saved = p
            saved.items[i].approval = !keepReceipt && recovered.progress.unresolved.isEmpty ? nil : recovered
            saved.items[i].state = .pending
            saved.finishedAt = nil
            try store.save(saved)
            if recovered.moves != nil { CatalogRecallIndexer.shared.changed(at: store.wiki.root.appendingPathComponent(WikiStore.indexFileName)) }
        }.value
    }

    /// 两边都核：全后像 / 全前像按实况收口，两边都符按 goal；混合态按收据逐步核版本回滚，不重发模型。
    @MainActor
    static func reconcile(_ proposalId: String, itemId: String, store: WikiProposalStore, profileId: String,
                          context: ModelContext, now: Date = Date()) async throws {
        try await exclusive(wiki: store.wiki) {
            try await reconcileLocked(proposalId, itemId: itemId, store: store, profileId: profileId, context: context, now: now)
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
    }

    @MainActor
    private static func receiptChecks(_ receipt: WikiProposal.ApprovalReceipt, store: WikiProposalStore, after: Bool,
                                      profileId: String, context: ModelContext, now: Date) async -> [(String, Bool)] {
        var checks = await Task.detached(priority: .userInitiated) {
            if receipt.moves != nil { return regroupChecks(receipt, wiki: store.wiki, after: after) }
            return receipt.pages.map { page -> (String, Bool) in
                let expected = after ? page.afterVersion : page.beforeVersion
                do {
                    return ("页：\(page.path)", try store.wiki.relativeData(page.path + ".md").map(WikiStore.version(of:)) == expected)
                } catch { return ("页：\(page.path)", false) }
            }
        }.value
        do {
            let live = try captureMarks(receipt.fragmentMarks.map(\.fragmentId), profileId: profileId,
                                        context: ModelContext(context.container), page: nil, now: now)
            checks += receipt.fragmentMarks.map { mark in
                ("碎片：\(mark.fragmentId)", live.first { $0.fragmentId == mark.fragmentId }.map { sameMark($0, mark, after: after) } ?? true)
            }
        } catch { checks.append(("碎片标记（\(error.localizedDescription)）", false)) }
        return checks
    }

    @MainActor
    private static func reconcileLocked(_ proposalId: String, itemId: String, store: WikiProposalStore,
                                         profileId: String, context: ModelContext, now: Date) async throws {
        guard let proposal = await Task.detached(priority: .userInitiated, operation: { store.load(proposalId) }).value,
              let item = proposal.items.first(where: { $0.id == itemId }),
              var receipt = item.approval, receipt.phase != .committed else { return }
        let goal = receipt.progress.goal ?? (receipt.phase == .withdrawing ? .withdrawal
            : receipt.phase == .recoveryRequired ? (item.state == .approved ? .rollbackWithdrawal : .rollbackApproval) : .approval)
        let beforeChecks = await receiptChecks(receipt, store: store, after: false, profileId: profileId, context: context, now: now)
        let afterChecks = await receiptChecks(receipt, store: store, after: true, profileId: profileId, context: context, now: now)
        let allBefore = beforeChecks.allSatisfy(\.1), allAfter = afterChecks.allSatisfy(\.1)
        var after: Bool
        var checks: [(String, Bool)]
        if allBefore || allAfter {
            after = allBefore && allAfter ? goal == .approval || goal == .rollbackWithdrawal : allAfter
            checks = after ? afterChecks : beforeChecks
        } else {
            await recoverApproval(proposalId, itemId: itemId, store: store, profileId: profileId, context: context,
                                  now: now, saveMarks: { try $0.save() }, keepReceipt: true)
            if let saved = await Task.detached(priority: .userInitiated, operation: { store.load(proposalId)?.items.first { $0.id == itemId }?.approval }).value {
                receipt = saved
            }
            after = false
            checks = await receiptChecks(receipt, store: store, after: false, profileId: profileId, context: context, now: now)
        }
        let settlingGoal: WikiProposal.ApprovalReceipt.Progress.Goal = after
            ? (goal == .approval || goal == .rollbackApproval ? .approval : .rollbackWithdrawal)
            : (goal == .withdrawal || goal == .rollbackWithdrawal ? .withdrawal : .rollbackApproval)
        receipt.progress.goal = settlingGoal
        receipt.progress.compensated = Array(Set(checks.filter(\.1).map(\.0))).sorted()
        receipt.progress.unresolved = checks.filter { !$0.1 }.map { "需人工：" + $0.0 }
        guard receipt.progress.unresolved.isEmpty else {
            receipt.phase = .recoveryRequired
            try await saveProgress(receipt, store: store)
            return
        }
        let settled = receipt
        try await Task.detached(priority: .userInitiated) {
            switch settlingGoal {
            case .withdrawal:
                try commitWithdrawal(.init(proposal: proposal, item: item, primaryId: proposalId),
                                     receipt: settled, store: store, now: now)
            case .rollbackApproval:
                guard var proposal = store.load(proposalId), let i = proposal.items.firstIndex(where: { $0.id == itemId }) else {
                    throw WikiProposalStore.ProposalError.notFound(itemId)
                }
                proposal.items[i].approval = nil
                proposal.items[i].state = .pending
                proposal.finishedAt = nil
                try store.save(proposal)
            case .rollbackWithdrawal:
                var receipt = settled
                receipt.phase = .committed
                try persist(receipt, store: store)
            case .approval:
                try persist(settled, store: store)
                let written: Written
                if settled.moves != nil {
                    let mapping = Dictionary(uniqueKeysWithValues: settled.pages.compactMap { page in page.beforePath.map { ($0, page.path) } })
                    written = .regroup(.init(mapping: mapping))
                } else if case .confirmCovered(let path) = item.change {
                    written = .covered(path: path, fragments: [])
                } else if let page = settled.pages.first, let version = page.afterVersion {
                    written = .page(path: page.path, old: page.beforeVersion, new: version, fragments: [])
                } else { throw WikiStore.WikiError.notFound("批准目标") }
                try commit(proposalId, itemId: itemId, written: written, store: store, now: now, saveReceipt: { try $1.save($0) })
            }
            if settled.moves != nil {
                try store.wiki.rebuildAllIndexes()
                CatalogRecallIndexer.shared.changed(at: store.wiki.root.appendingPathComponent(WikiStore.indexFileName))
            } else { try store.wiki.rebuildIndexes(affecting: settled.paths) }
        }.value
    }

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
    }


    /// 要求 root 已存在（现有入口都在页 / 提案存在后才进锁）；resolvingSymlinksInPath 对不存在路径可能保留 /private 前缀。
    static func lockKey(_ wiki: WikiStore) -> String {
        wiki.root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @MainActor
    private static func locked<T>(_ store: WikiProposalStore, _ body: () async throws -> T) async throws -> T {
        try await exclusive(wiki: store.wiki, body)
    }

    /// 同楼层的审批、人工保存与历史恢复共用边界；body 不嵌套取锁，也不等网络或 UI。
    @MainActor
    static func exclusive<T>(wiki: WikiStore, _ body: () async throws -> T) async throws -> T {
        let key = await Task.detached(priority: .userInitiated) { lockKey(wiki) }.value
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
                        context: ModelContext, now: Date = Date(), saveMarks: SaveMarks = { try $0.save() },
                        saveReceipt: @escaping SaveReceipt = { try $1.save($0) }) async throws -> WikiProposal {
        try await locked(store) {
            guard let initial = await Task.detached(priority: .userInitiated, operation: { store.load(proposalId) }).value else {
                throw WikiProposalStore.ProposalError.notFound(proposalId)
            }
            let unsettled = await Task.detached(priority: .userInitiated) {
                store.list().filter { $0.items.contains { $0.approval.map { $0.phase != .committed } ?? false } }
            }.value
            let ids = initial.items.filter { $0.state == .pending && itemIds?.contains($0.id) != false }.map(\.id)
            if let seen, let changed = initial.items.first(where: { item in ids.contains(item.id) && seen[item.id].map { $0 != item.change } ?? false }) {
                throw WikiProposalStore.ProposalError.changed(changed.id)
            }
            var touched: [String] = []
            var regrouped = false
            var approved = 0
            var failure: Error?
            for id in ids {
                let item = await Task.detached(priority: .userInitiated) { store.load(proposalId)?.items.first { $0.id == id } }.value
                do {
                    var marks: [WikiProposal.ApprovalReceipt.FragmentMark]
                    if case .regroup(_, _, let moves) = item?.change {
                        let mapping = try await Task.detached(priority: .userInitiated) { try regroupMapping(moves, wiki: store.wiki) ?? [:] }.value
                        let ids = SwiftDataMemoryStore().listAll(profileId: profileId, context: context)
                            .filter { $0.organizedPage.flatMap { mapping[$0] } != nil }.map(\.id)
                        marks = try captureMarks(ids, profileId: profileId, context: context, page: nil, now: now)
                        for index in marks.indices {
                            marks[index].afterOrganizedPage = marks[index].organizedPage.flatMap { mapping[$0] }
                        }
                    } else {
                        marks = try captureMarks(item?.organizedIds ?? [], profileId: profileId, context: context,
                                                 page: item?.change.targetPath, now: now)
                    }
                    let written = try await Task.detached(priority: .userInitiated) {
                        try writeItem(proposalId, itemId: id, store: store, profileId: profileId, now: now,
                                      marks: marks, unsettled: unsettled, saveReceipt: saveReceipt)
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
                        try remap(done.mapping, profileId: profileId, context: context, saveMarks: saveMarks)
                        regrouped = true
                    }
                    try await Task.detached(priority: .userInitiated) {
                        if var p = store.load(proposalId), let i = p.items.firstIndex(where: { $0.id == id }),
                           p.items[i].approval != nil {
                            let steps = p.items[i].approval?.moves == nil ? ["标记"]
                                : (p.items[i].approval?.fragmentMarks ?? []).map { "碎片：\($0.fragmentId)" }
                            p.items[i].approval?.progress.completed.append(contentsOf: steps)
                            try saveReceipt(p, store)
                        }
                        try commit(proposalId, itemId: id, written: written, store: store, now: now, saveReceipt: saveReceipt)
                    }.value
                    approved += 1
                } catch {
                    await recoverApproval(proposalId, itemId: id, store: store, profileId: profileId,
                                          context: context, now: now, saveMarks: saveMarks)
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
                        CatalogRecallIndexer.shared.changed(at: wiki.root.appendingPathComponent(WikiStore.indexFileName))
                    } else if !touched.isEmpty {
                        try wiki.rebuildIndexes(affecting: touched)
                    }
                    if approved > 0, var p = store.load(proposalId) {
                        for i in p.items.indices where ids.contains(p.items[i].id) && p.items[i].approval?.phase == .committed {
                            p.items[i].approval?.progress.completed.append("wiki 索引")
                        }
                        try store.save(p)
                    }
                } catch {
                    indexError = error
                }
                if approved > 0 {
                    let pages = Set(touched).count
                    MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: true,
                                          note: "整理提案批了 \(approved) 条" + (pages > 0 ? " · 写了 \(pages) 页" : "") + (regrouped ? " · 调了分组" : ""),
                                          model: "", now: now, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
                }
                return (store.load(proposalId), indexError)
            }.value
            if approved > 0 {
                NotificationCenter.default.post(name: .memoryDidChange, object: nil)
                NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
            }
            if let failure = failure ?? indexError { throw failure }
            guard let proposal else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
            return proposal
        }
    }

    /// 驳回：`itemIds` = nil 是整批驳回。条目明确引用的碎片标「整理时驳回」（covered 的不连带）
    @MainActor
    @discardableResult
    static func reject(_ proposalId: String, itemIds: Set<String>? = nil, reasons: [String: String]? = nil,
                       origin: WikiProposal.ReviewRecord.Origin = .user,
                       store: WikiProposalStore, profileId: String, context: ModelContext, now: Date = Date(),
                       saveMarks: SaveMarks = { try $0.save() }) async throws -> WikiProposal {
        try await locked(store) {
            var stage = "读取提案"
            var before: WikiProposal?
            var marks: [WikiProposal.ApprovalReceipt.FragmentMark] = []
            var saved = false
            do {
                guard let initial = await Task.detached(priority: .userInitiated, operation: { store.load(proposalId) }).value else {
                    throw WikiProposalStore.ProposalError.notFound(proposalId)
                }
                let targets = initial.items.filter { $0.state == .pending && itemIds?.contains($0.id) != false }
                guard !targets.isEmpty else { return initial }
                before = initial
                stage = "捕获碎片前像"
                marks = try captureMarks(Array(Set(targets.flatMap(\.fragmentIds))), profileId: profileId,
                                         context: context, page: nil, now: now)
                stage = "校验原因并保存拒稿"
                let captured = marks
                let rejected = try await Task.detached(priority: .userInitiated) {
                    try applyRejections(initial, itemIds: itemIds, reasons: reasons, origin: origin,
                                        marks: captured, store: store, now: now)
                }.value
                saved = true
                stage = "保存碎片标记"
                for i in marks.indices { marks[i].afterOrganizeRejectedAt = now }
                try setMarks(marks, after: true, profileId: profileId, context: context, saveMarks: saveMarks)
                stage = "保存审核后像"
                let live = try captureMarks(marks.map(\.fragmentId), profileId: profileId, context: context, page: nil, now: now)
                return try await Task.detached(priority: .userInitiated) {
                    var proposal = rejected
                    let byId = Dictionary(uniqueKeysWithValues: live.map { ($0.fragmentId, $0) })
                    let ids = Set(targets.map(\.id))
                    for i in proposal.items.indices where ids.contains(proposal.items[i].id) {
                        guard var history = proposal.items[i].reviewHistory, let last = history.indices.last else { continue }
                        for j in history[last].fragmentMarks.indices {
                            guard let after = byId[history[last].fragmentMarks[j].fragmentId] else { continue }
                            history[last].fragmentMarks[j].afterOrganizedAt = after.organizedAt
                            history[last].fragmentMarks[j].afterOrganizedPage = after.organizedPage
                            history[last].fragmentMarks[j].afterOrganizeRejectedAt = after.organizeRejectedAt
                        }
                        proposal.items[i].reviewHistory = history
                    }
                    try store.save(proposal)
                    let nonempty = targets.filter { !(reasons?[$0.id] ?? "").isEmpty }.count
                    MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: true,
                        note: "驳回 \(targets.count) 条（原因 \(nonempty) 条非空）", model: "", now: now, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
                    return proposal
                }.value
            } catch {
                var failures: [String] = []
                if saved, let before {
                    do {
                        try await Task.detached(priority: .userInitiated) { try store.save(before) }.value
                        do {
                            try setMarks(marks, after: false, profileId: profileId, context: context, saveMarks: { try $0.save() })
                        } catch { failures.append("碎片标记：\(error.localizedDescription)") }
                    } catch { failures.append("提案：\(error.localizedDescription)") }
                }
                let note = "驳回失败（\(stage)）：\(error.localizedDescription)"
                    + (failures.isEmpty ? "" : "；补偿失败：" + failures.joined(separator: "；"))
                await Task.detached(priority: .utility) {
                    MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: false, note: note, model: "", now: now, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
                }.value
                if !failures.isEmpty { throw CatalogSeedDrafts.EditError.invalid(note) }
                throw error
            }
        }
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
        try await exclusive(wiki: store.wiki, body)
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
                     store: WikiProposalStore, conversions: [CatalogSources.Conversion] = []) async throws -> WikiProposal {
        try await locked(store) {
            try await Task.detached(priority: .userInitiated) {
                try store.edit(proposalId, itemId: itemId, change: change, judgment: judgment, conversions: conversions)
            }.value
        }
    }

    struct ReopenResult: Sendable {
        var proposal: WikiProposal
        var kept: [UUID]
        var unrecorded: Bool

        var notice: String? {
            if unrecorded { return "已回待批；\(kept.count) 条来源拒绝标记保留（当时未记录归属）" }
            return kept.isEmpty ? nil : "已回待批；\(kept.count) 条来源在别处也被拒过或已归页，拒绝标记保留"
        }
    }

    struct ReopenEdit: Sendable {
        var itemId: String
        var change: WikiProposal.Change
        var baseline: WikiProposal.Change
        var judgment: WikiProposal.Judgment?
        var conversions: [CatalogSources.Conversion] = []
    }

    @MainActor
    static func reopen(_ proposalId: String, itemId: String, change: WikiProposal.Change,
                       baseline: WikiProposal.Change, judgment: WikiProposal.Judgment?,
                       store: WikiProposalStore, profileId: String, context: ModelContext, now: Date = Date(),
                       conversions: [CatalogSources.Conversion] = [], saveMarks: SaveMarks = { try $0.save() }) async throws -> ReopenResult {
        try await locked(store) {
            try await saveReopened(proposalId, edits: [.init(itemId: itemId, change: change, baseline: baseline, judgment: judgment, conversions: conversions)],
                requiringRejected: true, store: store, profileId: profileId, context: context, now: now, saveMarks: saveMarks)
        }
    }

    private static let reopenStale = CatalogSeedDrafts.EditError.invalid("页面 / 原料在驳回后变过，这条保留驳回；重新对照后另交提案")

    private static func checkReopenBaseline(_ item: WikiProposal.Item, proposal: WikiProposal,
                                            task: CatalogSeedTask?, store: WikiProposalStore) throws {
        let wiki = store.wiki
        if item.change.direction == nil, let path = item.change.targetPath {
            try requireSettled(path, store: store)
        }
        switch item.change {
        case .newPage(let page):
            guard !wiki.pageExists(page.path) else { throw reopenStale }
        case .appendRecords(let path, _), .rewriteNow(let path, _, _, _), .link(let path, _), .retag(let path, _, _, _, _):
            do { try CatalogSeedDrafts.checkVersion(path, item: item, wiki: wiki) }
            catch { throw reopenStale }
        case .direction(let direction):
            if direction.mode == .seed {
                guard CatalogSeedDrafts.canEditOutlineItem(item, task: task), let task else {
                    throw CatalogSeedDrafts.EditError.readOnly("这次种子已结束，目录项不能回待批；要这页请重新播种")
                }
                let version = task.read[CatalogSeedMaterials.wikiPath(direction.path)]
                let expected = version.flatMap { $0.isEmpty ? nil : $0 }
                guard wiki.version(of: direction.path) == expected else { throw reopenStale }
            } else {
                let exists = direction.group == true ? wiki.folderExists(direction.path) : wiki.pageExists(direction.path)
                guard exists == (direction.action == .update) else { throw reopenStale }
            }
        case .regroup(_, let groups, let moves):
            do {
                guard try regroupMapping(moves, wiki: wiki) != nil,
                      groups.allSatisfy({ WikiStore.isValidFolderPath($0.path) }),
                      Set(groups.map(\.path)).count == groups.count else { throw reopenStale }
            } catch { throw reopenStale }
        default:
            break
        }
        if let rejection = item.rejection,
           sourceSignature(item, proposal: proposal, task: task) != rejection.sourceSignature { throw reopenStale }
    }

    // 调用方已持同楼层写锁；文件库整份目录可含待批与驳回项，先全量校验，再一次保存与补偿。
    @MainActor
    static func saveReopened(_ proposalId: String, edits: [ReopenEdit], requiringRejected: Bool,
                             store: WikiProposalStore, profileId: String, context: ModelContext, now: Date = Date(),
                             saveMarks: SaveMarks = { try $0.save() }) async throws -> ReopenResult {
        var stage = "读取并重验提案"
        var before: WikiProposal?
        var marks: [WikiProposal.ApprovalReceipt.FragmentMark] = []
        var saved = false
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                guard let initial = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
                var proposal = initial
                let task = initial.seedTask.flatMap { CatalogSeedTaskStore(wiki: store.wiki).load($0) }
                for edit in edits {
                    let current = proposal.items.firstIndex(where: { $0.id == edit.itemId })
                    let change = current.map { proposal.items[$0].change } ?? edit.baseline
                    let label = change.direction?.title ?? change.targetPath ?? change.kindLabel
                    do {
                        guard let i = current else { throw WikiProposalStore.ProposalError.notFound(edit.itemId) }
                        let item = proposal.items[i]
                        guard item.state == .rejected || (!requiringRejected && item.state == .pending) else {
                            if requiringRejected && item.state == .pending {
                                throw CatalogSeedDrafts.EditError.invalid("这条已在别处回待批，关闭后重新打开")
                            }
                            throw WikiProposalStore.ProposalError.notRejected(edit.itemId)
                        }
                        guard item.change == edit.baseline else {
                            throw CatalogSeedDrafts.EditError.invalid("这条在别处改过，重新打开再改")
                        }
                        if item.state == .rejected { try checkReopenBaseline(item, proposal: initial, task: task, store: store) }
                        let checked: WikiProposal.Change
                        if case .direction(var direction) = edit.change, direction.mode != .seed {
                            direction.path = CatalogPrompts.normalizedPath(direction.path)
                            guard WikiStore.isValidPagePath(direction.path) else {
                                throw CatalogSeedDrafts.EditError.invalid("路径不合法：\(direction.path)（第一段只能是 \(WikiStore.branchesText)）")
                            }
                            checked = .direction(direction)
                        } else if CatalogSeedDrafts.isSeedProposal(initial) {
                            checked = try CatalogSeedDrafts.validate(edit.change, original: item, task: task, wiki: store.wiki, conversions: edit.conversions)
                        } else { checked = edit.change }
                        proposal.items[i] = try WikiProposalStore.edited(item, change: checked, judgment: edit.judgment, conversions: edit.conversions, now: now)
                    } catch let error as CatalogSeedDrafts.EditError {
                        let message = "「\(label)」：" + error.localizedDescription
                        if case .readOnly = error { throw CatalogSeedDrafts.EditError.readOnly(message) }
                        throw CatalogSeedDrafts.EditError.invalid(message)
                    } catch let error as WikiProposalStore.ProposalError {
                        throw CatalogSeedDrafts.EditError.invalid("「\(label)」：" + error.localizedDescription)
                    }
                }
                return (initial, proposal, store.list())
            }.value
            before = prepared.0
            var proposal = prepared.1
            let targets = prepared.0.items.filter { item in item.state == .rejected && edits.contains { $0.itemId == item.id } }
            let owned = targets.flatMap { $0.reviewHistory?.last(where: { $0.kind == .rejected })?.fragmentMarks ?? [] }
            stage = "捕获碎片前像"
            let live = try captureMarks(Array(Set(owned.map(\.fragmentId) + targets.flatMap(\.fragmentIds))),
                profileId: profileId, context: context, page: nil, now: now)
            var kept = Set<UUID>()
            var unrecorded = false
            for item in targets {
                let record = item.reviewHistory?.last(where: { $0.kind == .rejected })
                let hasOwnership = item.rejection != nil && record?.rejection == item.rejection
                if !hasOwnership { unrecorded = true }
                let itemMarks = record?.fragmentMarks ?? []
                let ids = Set(item.fragmentIds + itemMarks.map(\.fragmentId))
                for current in live where ids.contains(current.fragmentId) {
                    let elsewhere = prepared.2.contains { other in
                        other.items.contains { candidate in
                            !(other.id == proposalId && candidate.id == item.id)
                                && (candidate.state == .pending || candidate.state == .rejected)
                                && candidate.fragmentIds.contains(current.fragmentId)
                        }
                    }
                    if hasOwnership, let owned = itemMarks.first(where: { $0.fragmentId == current.fragmentId }),
                       owned.afterOrganizeRejectedAt != nil,
                       current.organizeRejectedAt?.timeIntervalSince1970 == owned.afterOrganizeRejectedAt?.timeIntervalSince1970,
                       current.organizedAt?.timeIntervalSince1970 == owned.afterOrganizedAt?.timeIntervalSince1970,
                       current.organizedPage == owned.afterOrganizedPage,
                       current.organizedPage == nil, !elsewhere {
                        var restored = current
                        restored.afterOrganizeRejectedAt = owned.organizeRejectedAt
                        if !marks.contains(where: { $0.fragmentId == current.fragmentId }) { marks.append(restored) }
                        if restored.afterOrganizeRejectedAt != nil { kept.insert(current.fragmentId) }
                    } else if current.organizeRejectedAt != nil { kept.insert(current.fragmentId) }
                }
                guard let i = proposal.items.firstIndex(where: { $0.id == item.id }) else { continue }
                proposal.items[i].state = .pending
                proposal.items[i].rejection = nil
                proposal.items[i].reviewHistory = (proposal.items[i].reviewHistory ?? []) + [
                    .init(at: now, kind: .reopened, rejection: hasOwnership ? item.rejection : nil,
                          fragmentMarks: live.filter { ids.contains($0.fragmentId) })
                ]
            }
            if proposal.pendingCount > 0 { proposal.finishedAt = nil }
            stage = "保存重新编辑提案"
            let pending = proposal
            try await Task.detached(priority: .userInitiated) { try store.save(pending) }.value
            saved = true
            stage = "保存碎片标记"
            try setMarks(marks, after: true, profileId: profileId, context: context, saveMarks: saveMarks)
            stage = "保存审核后像"
            let after = try captureMarks(live.map(\.fragmentId), profileId: profileId, context: context, page: nil, now: now)
            let result = try await Task.detached(priority: .userInitiated) {
                var final = pending
                let byId = Dictionary(uniqueKeysWithValues: after.map { ($0.fragmentId, $0) })
                let ids = Set(targets.map(\.id))
                for i in final.items.indices where ids.contains(final.items[i].id) {
                    guard var history = final.items[i].reviewHistory, let last = history.indices.last else { continue }
                    for j in history[last].fragmentMarks.indices {
                        guard let value = byId[history[last].fragmentMarks[j].fragmentId] else { continue }
                        history[last].fragmentMarks[j].afterOrganizedAt = value.organizedAt
                        history[last].fragmentMarks[j].afterOrganizedPage = value.organizedPage
                        history[last].fragmentMarks[j].afterOrganizeRejectedAt = value.organizeRejectedAt
                    }
                    final.items[i].reviewHistory = history
                }
                try store.save(final)
                return final
            }.value
            let cleared = marks.filter { $0.afterOrganizeRejectedAt == nil }.count
            let keptCount = kept.count
            await Task.detached(priority: .utility) {
                MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: true,
                    note: "重新编辑 \(targets.count) 条（解除 \(cleared) 条 / 保留 \(keptCount) 条）", model: "", now: now, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
            }.value
            return ReopenResult(proposal: result, kept: kept.sorted { $0.uuidString < $1.uuidString }, unrecorded: unrecorded)
        } catch {
            var failures: [String] = []
            if saved, let before {
                do {
                    try await Task.detached(priority: .userInitiated) { try store.save(before) }.value
                    do {
                        try setMarks(marks, after: false, profileId: profileId, context: context, saveMarks: { try $0.save() })
                    } catch { failures.append("碎片标记：\(error.localizedDescription)") }
                } catch { failures.append("提案：\(error.localizedDescription)") }
            }
            let note = "重新编辑失败（\(stage)）：\(error.localizedDescription)"
                + (failures.isEmpty ? "" : "；补偿失败：" + failures.joined(separator: "；"))
            await Task.detached(priority: .utility) {
                MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: false, note: note, model: "", now: now, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
            }.value
            if !failures.isEmpty { throw CatalogSeedDrafts.EditError.invalid(note) }
            throw error
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
    static func finishInterrupted(store: WikiProposalStore, before: Date, profileId: String, context: ModelContext) async throws -> Int {
        try await locked(store) {
            let fixed = try await Task.detached(priority: .utility) { () -> Int in
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
            if fixed > 0 {
                await Task.detached(priority: .utility) {
                    MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: false,
                        note: "上次运行中断的方向 \(fixed) 条，已记下结果", model: "", memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
                }.value
            }
            let unsettled = await Task.detached(priority: .utility) {
                receipts(store).filter { $0.receipt.phase != .committed }
            }.value
            var failure: Error?
            for row in unsettled {
                do {
                    try await reconcileLocked(row.proposal.id, itemId: row.item.id, store: store,
                                              profileId: profileId, context: context, now: Date())
                } catch {
                    CacheDiagLog.shared.log("📚 整理编目: 核账失败 \(row.proposal.id) / \(row.item.id)：\(error.localizedDescription)")
                    failure = failure ?? error
                }
            }
            if let failure { throw failure }
            return fixed
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
                let revoked = p.items[i].state != .approved
                let orphan = contentProposalId.map { "，正文提案 \($0) 悬空" } ?? ""
                d.result = result + (revoked ? " · 方向已撤授权" + orphan : "")
                if !revoked { d.contentProposalId = contentProposalId }
                p.items[i].change = .direction(d)
                try store.save(p)
                if revoked { throw WikiStore.WikiError.conflict(itemId, "方向已撤授权" + orphan) }
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
    private static func writeItem(_ proposalId: String, itemId: String, store: WikiProposalStore, profileId: String, now: Date,
                                  marks: [WikiProposal.ApprovalReceipt.FragmentMark], unsettled: [WikiProposal],
                                  saveReceipt: SaveReceipt) throws -> Written {
        guard var p = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
        guard let i = p.items.firstIndex(where: { $0.id == itemId }), p.items[i].state == .pending else { return .gone }
        var item = p.items[i]
        if item.change.direction == nil, let path = item.change.targetPath { try requireSettled(path, store: store, unsettled: unsettled) }
        var staleReason: String?
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
            if let current = store.wiki.version(of: path), current == item.baseVersion {
                _ = try store.wiki.checkedPageURL(path)
                var receipt = WikiProposal.ApprovalReceipt(proposalId: proposalId, itemId: itemId, preparedAt: now,
                    pages: [.init(path: path, beforeVersion: current, afterVersion: current)], fragmentMarks: marks)
                receipt.progress.completed = ["前像", "prepared"]
                p.items[i].approval = receipt
                try saveReceipt(p, store)
                receipt.phase = .applied
                receipt.progress.completed.append("页（确认已覆盖，未写页）")
                p.items[i].approval = receipt
                try saveReceipt(p, store)
                return .covered(path: path, fragments: item.organizedIds)
            }
        } else if case .regroup(_, let groups, let moves) = item.change {
            if let done = try applyRegroup(p, itemIndex: i, groups: groups, moves: moves, marks: marks,
                                          store: store, now: now, unsettled: unsettled, saveReceipt: saveReceipt) { return .regroup(done) }
        } else if let path = item.change.targetPath, WikiStore.isValidPagePath(path) {
            if let written = try applyPage(item, path: path, wiki: store.wiki, seedTask: p.seedTask,
                                           directionItemId: p.directionRef?.itemId, profileId: profileId, now: now,
                                           staleReason: &staleReason, prepare: { page, old in
                    let afterVersion = WikiStore.version(of: Data(page.markdown.utf8))
                    let entry = afterVersion == old ? nil : try store.wiki.snapshotCurrent(path, now: now)
                    let previousEntries = Set(store.wiki.read(path)?.entries ?? [])
                    var receipt = WikiProposal.ApprovalReceipt(proposalId: proposalId, itemId: itemId, preparedAt: now,
                        pages: [.init(path: path, beforeVersion: old, afterVersion: afterVersion,
                                      beforeHistoryEntry: entry)], fragmentMarks: marks)
                    receipt.addedEntries[path] = (page.entries ?? []).filter { !previousEntries.contains($0) }
                    receipt.progress.completed = ["前像", "prepared"]
                    p.items[i].approval = receipt
                    try saveReceipt(p, store)
                    _ = try store.wiki.checkedPageURL(path, create: true)
                }) {
                p.items[i].approval?.pages[0].afterVersion = written.1
                p.items[i].approval?.phase = .applied
                p.items[i].approval?.progress.completed.append("页")
                try saveReceipt(p, store)
                return .page(path: path, old: written.0, new: written.1, fragments: item.organizedIds)
            }
        }
        p.items[i].state = .stale
        p.items[i].staleReason = staleReason
        if p.pendingCount == 0, p.finishedAt == nil { p.finishedAt = now }
        try store.save(p)
        return .stale
    }

    /// 最后一步：条目存成「已批」；同页后面还待批、基线是旧版本的跟上新版本
    private static func commit(_ proposalId: String, itemId: String, written: Written, store: WikiProposalStore, now: Date,
                               saveReceipt: SaveReceipt) throws {
        guard var p = store.load(proposalId) else { throw WikiProposalStore.ProposalError.notFound(proposalId) }
        guard let i = p.items.firstIndex(where: { $0.id == itemId }) else { throw WikiProposalStore.ProposalError.notFound(itemId) }
        p.items[i].state = .approved
        if case .page(let path, let old, let new, _) = written {
            for j in p.items.indices where j != i && p.items[j].state == .pending
                && p.items[j].change.targetPath == path && !p.items[j].change.isNewPage && p.items[j].baseVersion == old {
                let rebase = WikiProposal.ApprovalReceipt.RebasedItem(itemId: p.items[j].id, oldBase: old, newBase: new,
                                                                    changeFingerprint: try fingerprint(p.items[j].change))
                p.items[i].approval?.rebasedItems.append(rebase)
                p.items[j].baseVersion = new
            }
        }
        if var receipt = p.items[i].approval {
            let fragments = Set(receipt.fragmentMarks.map(\.fragmentId))
            receipt.dependencies = store.list().flatMap(\.items).compactMap(\.approval).filter {
                $0.id != receipt.id && $0.phase == .committed
                    && (sharesPaths(receipt, $0)
                        || !fragments.isDisjoint(with: $0.fragmentMarks.map(\.fragmentId)))
            }.map(\.id).sorted()
            receipt.phase = .committed
            receipt.approvedAt = now
            receipt.progress.completed.append("proposal")
            p.items[i].approval = receipt
        }
        if p.pendingCount == 0, p.finishedAt == nil { p.finishedAt = now }
        try saveReceipt(p, store)
    }

    private static func sourceSignature(_ item: WikiProposal.Item, proposal: WikiProposal,
                                        task: CatalogSeedTask?) -> WikiProposal.SourceSignature {
        let kind: WikiProposal.SourceSignature.ChangeKind
        let path: String
        let group: Bool
        switch item.change {
        case .newPage: kind = .newPage
        case .appendRecords: kind = .appendRecords
        case .rewriteNow: kind = .rewriteNow
        case .link: kind = .link
        case .retag: kind = .retag
        case .regroup: kind = .regroup
        case .direction: kind = .direction
        case .confirmCovered: kind = .confirmCovered
        }
        switch item.change {
        case .regroup(let layer, _, _): path = layer; group = true
        case .direction(let direction): path = direction.path; group = direction.group == true
        default: path = item.change.targetPath ?? ""; group = false
        }
        let cites = Set(item.cites.map {
            WikiProposal.SourceSignature.CiteLocation(layer: $0.layer, day: $0.day, filePath: $0.filePath,
                name: $0.layer == CatalogSurvey.layer ? $0.name : nil,
                profileId: $0.profileId, windowId: $0.windowId, segment: $0.segment, nodeId: $0.nodeId,
                messageFrom: $0.messageFrom, messageTo: $0.messageTo)
        }).sorted(using: [
            KeyPathComparator(\.layer, comparator: String.StandardComparator.lexical),
            KeyPathComparator(\.day, comparator: String.StandardComparator.lexical),
            KeyPathComparator(\.filePath, comparator: String.StandardComparator.lexical),
            KeyPathComparator(\.name, comparator: String.StandardComparator.lexical),
            KeyPathComparator(\.profileId, comparator: String.StandardComparator.lexical),
            KeyPathComparator(\.windowId, comparator: String.StandardComparator.lexical),
            KeyPathComparator(\.segment),
            KeyPathComparator(\.nodeId, comparator: String.StandardComparator.lexical),
            KeyPathComparator(\.messageFrom), KeyPathComparator(\.messageTo),
        ])
        let paths = item.change.direction?.sources
            ?? (proposal.seedTask != nil || proposal.origin == .seed ? item.cites.compactMap { cite in
                cite.layer == CatalogSurvey.layer ? cite.name.map { CatalogSurvey.prefix + $0 } : cite.filePath
            } : [])
        let sources = Set(paths).sorted().map {
            WikiProposal.SourceSignature.Source(path: $0, version: task?.read[$0].flatMap { $0.isEmpty ? nil : $0 })
        }
        return .init(changeKind: kind, targetPath: CatalogPrompts.normalizedPath(path), targetIsGroup: group,
                     fragmentIds: Set(item.fragmentIds).sorted { $0.uuidString < $1.uuidString }, cites: cites, sources: sources)
    }

    private static func applyRejections(_ initial: WikiProposal, itemIds: Set<String>?, reasons: [String: String]?,
                                        origin: WikiProposal.ReviewRecord.Origin,
                                        marks: [WikiProposal.ApprovalReceipt.FragmentMark], store: WikiProposalStore,
                                        now: Date) throws -> WikiProposal {
        var p = initial
        let targets = p.items.indices.filter { p.items[$0].state == .pending && itemIds?.contains(p.items[$0].id) != false }
        for i in targets where (reasons?[p.items[i].id] ?? "").count > WikiProposal.Rejection.reasonLimit {
            throw CatalogSeedDrafts.EditError.invalid("驳回原因最多 200 字")
        }
        let task = p.seedTask.flatMap { CatalogSeedTaskStore(wiki: store.wiki).load($0) }
        for i in targets {
            let rejection = WikiProposal.Rejection(reason: reasons?[p.items[i].id] ?? "", at: now,
                sourceSignature: sourceSignature(p.items[i], proposal: p, task: task))
            let ids = Set(p.items[i].fragmentIds)
            let record = WikiProposal.ReviewRecord(at: now, kind: .rejected, origin: origin, rejection: rejection,
                                                   fragmentMarks: marks.filter { ids.contains($0.fragmentId) })
            p.items[i].state = .rejected
            p.items[i].rejection = rejection
            p.items[i].reviewHistory = (p.items[i].reviewHistory ?? []) + [record]
        }
        if p.pendingCount == 0, p.finishedAt == nil { p.finishedAt = now }
        try store.save(p)
        return p
    }

    /// 一页的条目：版本对不上 / 新开页已存在 → nil（置「页已变」）；对上了写，返回 (旧版本, 新版本)
    private static func applyPage(_ item: WikiProposal.Item, path: String, wiki: WikiStore, seedTask: String?,
                                  directionItemId: String?, profileId: String, now: Date, staleReason: inout String?,
                                  prepare: (WikiPage, String?) throws -> Void) throws -> (String?, String)? {
        let current = wiki.version(of: path)
        let directions = seedTask.flatMap { WikiProposalStore(wiki: wiki).load($0) }?.items ?? []
        let direction = directionItemId.flatMap { id in directions.first { $0.id == id }?.change.direction }
            ?? directions.compactMap(\.change.direction).first { $0.path == path }
        let domain = direction?.factDomain
        func logDomain(_ note: String, ok: Bool) {
            if !ok { staleReason = note }
            let task = seedTask.flatMap { CatalogSeedTaskStore(wiki: wiki).load($0) }
            MemoryWriteLog.record(writer: .c3, profileId: profileId, ok: ok, note: note,
                                  model: task?.modelName ?? "", now: now, run: task?.run, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        }
        var page: WikiPage
        switch item.change {
        case .newPage(let p):
            guard current == nil else { return nil }
            page = p
            page.validUntil = WikiPage.until(p.validUntil, in: p.now)
            if let domain, let pageDomain = page.factDomain, pageDomain != domain {
                logDomain("种子批准「\(path)」：页域不合（页 \(WikiPage.factDomainLabel(pageDomain)) / 目录项 \(WikiPage.factDomainLabel(domain))），没改页", ok: false)
                return nil
            }
            if page.factDomain == nil, let domain {
                page.factDomain = domain
                logDomain("种子批准「\(path)」：旧正文未记页域，按目录项补为 \(WikiPage.factDomainLabel(domain))", ok: true)
            }
        case .regroup, .direction, .confirmCovered:
            return nil
        default:
            guard let current, current == item.baseVersion, let existing = wiki.read(path) else { return nil }
            if let domain, existing.factDomain != domain {
                logDomain("种子批准「\(path)」：页域不合（页 \(WikiPage.factDomainLabel(existing.factDomain)) / 目录项 \(WikiPage.factDomainLabel(domain))），没改页", ok: false)
                return nil
            }
            page = existing
            switch item.change {
            case .appendRecords(_, let lines):
                page.records += lines
                if let seedTask, let task = CatalogSeedTaskStore(wiki: wiki).load(seedTask) {
                    var entries = page.entries ?? []
                    for line in lines {
                        guard let source = CatalogSources.split(line).labels?.first,
                              let version = task.carded?[source], !version.isEmpty else { continue }
                        guard version == task.read[source] else {
                            MemoryWriteLog.record(writer: .c3, profileId: task.profileId, ok: false,
                                note: "种子批准「\(path)」：条目引用未追加，\(source) 的卡版本与快照不一致（carded=\(version)，read=\(task.read[source] ?? "无")）",
                                model: task.modelName, now: now, run: task.run, memoryRoot: FileLibraryStore.memoryRoot(profileId: task.profileId))
                            continue
                        }
                        let key = source + "|" + version
                        if !entries.contains(key) { entries.append(key) }
                    }
                    if !entries.isEmpty { page.entries = entries }
                }
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
        try prepare(page, current)
        return (current, try wiki.save(page, now: now, recordingHistory: false))
    }

    /// 核对源 / 目标与目录子树重叠，返回旧页 → 新页；页可挪进同名子目录。
    private static func regroupMapping(_ moves: [WikiProposal.Move], wiki: WikiStore) throws -> [String: String]? {
        var mapping: [String: String] = [:]
        for (index, move) in moves.enumerated() {
            let folder = !wiki.pageExists(move.from)
            guard !moves.enumerated().contains(where: { other in
                let otherFolder = !wiki.pageExists(other.element.from)
                return other.offset != index
                    && (overlaps(move.from, other.element.from, aFolder: folder, bFolder: otherFolder)
                        || overlaps(move.to, other.element.to, aFolder: folder, bFolder: otherFolder))
            }), !moves.contains(where: {
                !wiki.pageExists($0.from) && overlaps(move.to, $0.from, aFolder: folder, bFolder: true)
            }),
                  !wiki.pageExists(move.to), !wiki.folderExists(move.to) else { return nil }
            if wiki.pageExists(move.from) {
                _ = try wiki.checkedPageURL(move.from)
                guard WikiStore.isValidPagePath(move.to) else { return nil }
                mapping[move.from] = move.to
            } else {
                guard wiki.folderExists(move.from), WikiStore.isValidFolderPath(move.from), move.from.split(separator: "/").count >= 2,
                      WikiStore.isValidFolderPath(move.to) else { return nil }
                _ = try SafeWiki.folder(move.from.split(separator: "/").map(String.init), under: wiki.root, create: false)
                for path in wiki.pagePaths(under: move.from) {
                    _ = try wiki.checkedPageURL(path)
                    mapping[path] = move.to + path.dropFirst(move.from.count)
                }
            }
        }
        return mapping
    }

    private static func imageData(_ reference: String?, wiki: WikiStore) throws -> Data? {
        guard let reference else { return nil }
        guard reference.hasPrefix(WikiStore.proposalsFolder + "/"), let data = try wiki.relativeData(reference) else {
            throw WikiStore.WikiError.notFound(reference)
        }
        return data
    }

    /// 分组调整：先核对（源都在、目标都空、路径合法、目标不重），对不上 → nil；
    /// 预检完才存前像、prepared，再建分组 → 挪页 / 文件夹及历史 → 重连；失败由收据逐步核版本补偿。
    /// 历史目录跟着挪；目标已有（以前同名页留下的）就逐个文件挪进去，撞名的不动。
    private static func applyRegroup(_ proposal: WikiProposal, itemIndex: Int, groups: [WikiProposal.NewGroup],
                                     moves: [WikiProposal.Move], marks: [WikiProposal.ApprovalReceipt.FragmentMark],
                                     store: WikiProposalStore, now: Date, unsettled: [WikiProposal], saveReceipt: SaveReceipt) throws -> RegroupDone? {
        let wiki = store.wiki
        guard let mapping = try regroupMapping(moves, wiki: wiki) else { return nil }
        guard groups.allSatisfy({ WikiStore.isValidFolderPath($0.path) }),
              Set(groups.map(\.path)).count == groups.count else { return nil }
        let folders = moves.filter { !wiki.pageExists($0.from) }
        let exact = moves.filter { wiki.pageExists($0.from) }.flatMap { [$0.from, $0.to] }
            + groups.map { $0.path + "/" + WikiStore.groupFileName } + Array(mapping.keys)
        for path in exact + folders.flatMap({ [$0.from, $0.to] }) {
            try requireSettled(path, store: store, unsettled: unsettled)
        }
        for p in unsettled {
            if let item = p.items.first(where: { item in
                item.approval.map { receipt in
                    receipt.phase != .committed && folders.contains { move in
                        receipt.paths.contains { path in
                            overlaps(move.from, path, aFolder: true, bFolder: receipt.folderPaths.contains(path))
                                || overlaps(move.to, path, aFolder: true, bFolder: receipt.folderPaths.contains(path))
                        }
                    }
                } ?? false
            }) {
                throw WikiStore.WikiError.conflict(proposal.id, "有未收口批准（\(WithdrawTarget(proposal: p, item: item, primaryId: "").label)），先处理恢复")
            }
        }
        var receipt = WikiProposal.ApprovalReceipt(proposalId: proposal.id, itemId: proposal.items[itemIndex].id,
            preparedAt: now, pages: [], fragmentMarks: marks)
        receipt.progress.goal = .approval
        receipt.moves = []
        receipt.groupImages = []
        receipt.relinked = []
        let imageFolder = [WikiStore.proposalsFolder, proposal.seedTask ?? proposal.id, "images", receipt.id]
        var images: [(name: String, data: Data)] = []
        var groupPaths = groups.map(\.path)
        var knownGroups = Set(groupPaths)
        let parentPaths = groups.map(\.path) + moves.map { $0.to.split(separator: "/").dropLast().joined(separator: "/") }
        for parent in parentPaths {
            let parts = parent.split(separator: "/")
            for index in parts.indices {
                let path = parts.prefix(index + 1).joined(separator: "/")
                if !wiki.folderExists(path), knownGroups.insert(path).inserted { groupPaths.append(path) }
            }
        }
        func collectMovedHooks(_ path: String) throws {
            guard let listing = SafeWiki.names(in: path.split(separator: "/").map(String.init), under: wiki.root) else {
                throw WikiStore.WikiError.notFound(path)
            }
            if listing.names.contains(WikiStore.groupFileName), knownGroups.insert(path).inserted { groupPaths.append(path) }
            for name in listing.names.sorted() where !name.hasPrefix(".") && !CCMemorySync.isExcluded(name: name) {
                if try SafeWiki.itemType(listing.folder.appendingPathComponent(name)) == .typeDirectory {
                    try collectMovedHooks(path + "/" + name)
                }
            }
        }
        for move in folders { try collectMovedHooks(move.from) }
        for (index, groupPath) in groupPaths.enumerated() {
            let moved = folders.first { groupPath == $0.from || groupPath.hasPrefix($0.from + "/") }
            let path = moved.map { $0.to + groupPath.dropFirst($0.from.count) } ?? groupPath
            let before = try wiki.relativeData(groupPath + "/" + WikiStore.groupFileName)
            let after = groups.first { $0.path == groupPath }.map { Data("---\n钩子: \($0.hook)\n---\n".utf8) } ?? before
            let beforeName = "\(index)-before.bin", afterName = after == before ? beforeName : "\(index)-after.bin"
            if let before { images.append((beforeName, before)) }
            if let after, after != before { images.append((afterName, after)) }
            receipt.groupImages?.append(.init(path: path, createdByThisApproval: !wiki.folderExists(groupPath),
                beforeImage: before.map { _ in (imageFolder + [beforeName]).joined(separator: "/") },
                afterImage: after.map { _ in (imageFolder + [afterName]).joined(separator: "/") },
                afterVersion: after.map(WikiStore.version(of:)), beforeVersion: before.map(WikiStore.version(of:)),
                beforePath: path == groupPath ? nil : groupPath))
        }
        for from in mapping.keys.sorted() {
            let to = mapping[from]!
            guard let version = wiki.version(of: from) else { throw WikiStore.WikiError.notFound(from) }
            receipt.pages.append(.init(path: to, beforeVersion: version, afterVersion: version, beforePath: from))
        }
        var rewritten: [String: String] = [:]
        var snapshots: [(from: String, path: String, entry: String)] = []
        for from in wiki.pagePaths() {
            let path = mapping[from] ?? from
            _ = try wiki.checkedPageURL(from)
            guard let raw = wiki.readVersioned(from) else { throw WikiStore.WikiError.notFound(from) }
            var page = WikiPage.parse(raw.text, path: path)
            let links = page.links.map { link in
                var link = link
                link.target = mapping[link.target] ?? link.target
                return link
            }
            guard links != page.links else { continue }
            try requireSettled(from, store: store, unsettled: unsettled)
            page.links = links
            _ = try wiki.relativeFiles(WikiStore.historyFolder + "/" + from, recursive: false)
            _ = try wiki.relativeFiles(WikiStore.historyFolder + "/" + path, recursive: false)
            let entry = try wiki.snapshotName(from, now: now, avoidingHistoryAt: from == path ? nil : path)
            snapshots.append((from, path, entry))
            receipt.relinked?.append(.init(path: path, beforeVersion: raw.version,
                afterVersion: WikiStore.version(of: Data(page.markdown.utf8)),
                beforePath: from == path ? nil : from))
            rewritten[path] = page.markdown
        }
        for move in moves {
            let folder = !wiki.pageExists(move.from)
            var histories: [WikiProposal.ApprovalReceipt.MoveRecord.HistoryMove] = []
            _ = try wiki.relativeFiles(WikiStore.historyFolder + "/" + move.to, recursive: folder)
            for (name, version) in try wiki.relativeFiles(WikiStore.historyFolder + "/" + move.from, recursive: folder).sorted(by: { $0.key < $1.key }) {
                let from = WikiStore.historyFolder + "/" + move.from + "/" + name
                if !folder && !name.hasSuffix(".md") { continue }
                let to = WikiStore.historyFolder + "/" + move.to + "/" + name
                if try wiki.relativeData(to) == nil { histories.append(.init(from: from, to: to, version: version)) }
            }
            let files = folder ? try wiki.relativeFiles(move.from, excludingIndexes: true) : [:]
            receipt.moves?.append(.init(from: move.from, to: move.to, isFolder: folder, history: histories, files: files))
        }
        for image in images { try SafeWiki.write(image.data, name: image.name, in: imageFolder, under: wiki.root) }
        for (index, snapshot) in snapshots.enumerated() {
            let entry = try wiki.snapshotCurrent(snapshot.from, now: now, plannedEntry: snapshot.entry)
            receipt.relinked?[index].beforeHistoryEntry = entry
            if snapshot.from != snapshot.path, let entry,
               let moveIndex = receipt.moves?.firstIndex(where: {
                   $0.isFolder ? snapshot.from.hasPrefix($0.from + "/") : snapshot.from == $0.from
               }) {
                receipt.moves?[moveIndex].history.append(.init(
                    from: WikiStore.historyFolder + "/" + snapshot.from + "/" + entry,
                    to: WikiStore.historyFolder + "/" + snapshot.path + "/" + entry,
                    version: receipt.relinked![index].beforeVersion!))
            }
        }
        for index in receipt.moves?.indices ?? 0..<0 {
            receipt.moves?[index].history.sort { $0.from < $1.from }
        }
        var saved = proposal
        func checkpoint() throws {
            saved.items[itemIndex].approval = receipt
            try saveReceipt(saved, store)
        }
        receipt.progress.completed = ["前像", "prepared"]
        try checkpoint()
        for image in receipt.groupImages ?? [] {
            if let data = try imageData(image.afterImage, wiki: wiki) {
                try SafeWiki.write(data, name: WikiStore.groupFileName,
                    in: (image.beforePath ?? image.path).split(separator: "/").map(String.init), under: wiki.root)
            } else {
                _ = try SafeWiki.folder((image.beforePath ?? image.path).split(separator: "/").map(String.init), under: wiki.root, create: true)
            }
            receipt.progress.completed.append("分组：\(image.path)")
            try checkpoint()
        }
        for move in receipt.moves ?? [] {
            try wiki.moveRelative(from: move.from + (move.isFolder ? "" : ".md"),
                                  to: move.to + (move.isFolder ? "" : ".md"), isFolder: move.isFolder)
            receipt.progress.completed.append((move.isFolder ? "目录：" : "页：") + move.from + " → " + move.to)
            try checkpoint()
            for (index, history) in move.history.enumerated() {
                try wiki.moveRelative(from: history.from, to: history.to)
                receipt.progress.completed.append("历史：\(history.to)")
                if index == move.history.count - 1
                    || (history.from as NSString).deletingLastPathComponent != (move.history[index + 1].from as NSString).deletingLastPathComponent {
                    try checkpoint()
                }
            }
        }
        for page in receipt.relinked ?? [] {
            _ = try wiki.checkedPageURL(page.path)
            _ = try wiki.saveRaw(rewritten[page.path]!, path: page.path, now: now, recordingHistory: false)
            receipt.progress.completed.append("重连页：\(page.path)")
            try checkpoint()
        }
        receipt.phase = .applied
        try checkpoint()
        return RegroupDone(mapping: mapping)
    }

    private static func previewVersion(_ path: String, wiki: WikiStore, files: [String: String?]) throws -> String? {
        if let version = files[path] { return version }
        return try wiki.relativeData(path).map(WikiStore.version(of:))
    }

    private static func previewFiles(_ path: String, wiki: WikiStore, files: [String: String?]) throws -> [String: String] {
        var current = try wiki.relativeFiles(path, excludingIndexes: true)
        for (file, version) in files where file.hasPrefix(path + "/") {
            if file.dropFirst(path.count + 1).split(separator: "/").contains(where: { $0.hasPrefix(".") || CCMemorySync.isExcluded(name: String($0)) }) { continue }
            current[String(file.dropFirst(path.count + 1))] = version
        }
        return current
    }

    /// 同时支持前像 / 后像核账；页与同名目录互不占用，历史只核收据中真正迁走的文件。
    private static func regroupChecks(_ receipt: WikiProposal.ApprovalReceipt, wiki: WikiStore, after: Bool,
                                       files: [String: String?] = [:], folders: [String: Bool] = [:]) -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        func fileMatches(_ path: String, _ expected: String?) -> Bool {
            do { return try previewVersion(path, wiki: wiki, files: files) == expected }
            catch { return false }
        }
        for page in receipt.pages {
            let path = after ? page.path : page.beforePath ?? page.path
            let version = after ? (receipt.relinked?.first { $0.path == page.path }?.afterVersion ?? page.afterVersion) : page.beforeVersion
            let matches = WikiStore.isValidPagePath(path) && fileMatches(path + ".md", version)
            checks.append(("页：\(path)", matches))
        }
        for page in receipt.relinked ?? [] where !receipt.pages.contains(where: { $0.path == page.path }) {
            let matches = fileMatches(page.path + ".md", after ? page.afterVersion : page.beforeVersion)
            checks.append(("重连页：\(page.path)", matches))
        }
        for move in receipt.moves ?? [] {
            let path = after ? move.to : move.from, absent = after ? move.from : move.to
            var matches = move.isFolder ? !(folders[absent] ?? wiki.folderExists(absent)) : fileMatches(absent + ".md", nil)
            if move.isFolder {
                var expected = move.files
                if after {
                    for page in receipt.relinked ?? [] where page.path.hasPrefix(move.to + "/") {
                        expected[String(page.path.dropFirst(move.to.count + 1)) + ".md"] = page.afterVersion
                    }
                }
                matches = matches && (folders[path] ?? wiki.folderExists(path))
                    && (try? previewFiles(path, wiki: wiki, files: files)) == expected
            }
            checks.append(((move.isFolder ? "目录：" : "挪页：") + path, matches))
            for history in move.history {
                let current = after ? history.to : history.from, absent = after ? history.from : history.to
                checks.append(("历史：\(current)", fileMatches(current, history.version) && fileMatches(absent, nil)))
            }
        }
        for image in receipt.groupImages ?? [] {
            let path = (after ? image.path : image.beforePath ?? image.path) + "/" + WikiStore.groupFileName
            do {
                let expected = try imageData(after ? image.afterImage : image.beforeImage, wiki: wiki)
                guard expected.map(WikiStore.version(of:)) == (after ? image.afterVersion : image.beforeVersion) else {
                    throw WikiStore.WikiError.conflict(path, "分组前像 / 后像已变")
                }
                let matches = fileMatches(path, expected.map(WikiStore.version(of:)))
                checks.append(("分组：\(image.path)", matches))
            } catch { checks.append(("分组：\(image.path)", false)) }
        }
        return checks
    }

    private static func checkRegroup(_ receipt: WikiProposal.ApprovalReceipt, wiki: WikiStore, after: Bool,
                                     files: [String: String?] = [:], folders: [String: Bool] = [:]) throws {
        let failed = regroupChecks(receipt, wiki: wiki, after: after, files: files, folders: folders).filter { !$0.1 }.map(\.0)
        guard failed.isEmpty else {
            throw WikiStore.WikiError.conflict(failed.joined(separator: "、"), "页后来改过 / 被删，先处理：\(failed.joined(separator: "、"))")
        }
        for page in after ? receipt.relinked ?? [] : [] {
            let path = page.path
            guard let entry = page.beforeHistoryEntry,
                  try previewVersion(WikiStore.historyFolder + "/" + path + "/" + entry, wiki: wiki, files: files) == page.beforeVersion else {
                throw WikiStore.WikiError.conflict(path, "批准前像缺失 / 已变，不能撤回")
            }
        }
        for image in receipt.groupImages ?? [] {
            guard try imageData(image.beforeImage, wiki: wiki).map(WikiStore.version(of:)) == image.beforeVersion else {
                throw WikiStore.WikiError.conflict(image.path, "分组前像缺失 / 已变，不能撤回")
            }
        }
    }

    /// 尽力挪回：先把改过「连到」的页换回原文，再倒着挪回页 / 历史，最后删掉新建的空分组。
    /// 每步只接受收据前像 / 后像，bestEffort 保留不匹配目标，不覆盖人工改动。
    private static func restoreRegroup(_ receipt: inout WikiProposal.ApprovalReceipt, wiki: WikiStore, after: Bool,
                                       now: Date, bestEffort: Bool = false,
                                       beforeMove: @Sendable (String, String) throws -> Void = { _, _ in },
                                       checkpoint: (WikiProposal.ApprovalReceipt) throws -> Void) throws {
        func step(_ name: String, _ body: () throws -> Void) throws {
            do {
                try body()
                if bestEffort { receipt.progress.compensated.append(name) }
                else { receipt.progress.completed.append(name) }
                try checkpoint(receipt)
            } catch {
                if !bestEffort { throw WikiStore.WikiError.conflict(name, "\(name)：\(error.localizedDescription)") }
                receipt.progress.unresolved.append(name + "（\(error.localizedDescription)）")
            }
        }
        func groups(_ images: [WikiProposal.ApprovalReceipt.GroupImage]) throws {
            for image in images {
                try step("分组：\(image.path)") {
                    let atSource = (receipt.moves ?? []).contains { $0.isFolder && wiki.folderExists($0.from)
                        && (image.path == $0.to || image.path.hasPrefix($0.to + "/")) }
                    let folderPath = atSource ? image.beforePath ?? image.path : image.path
                    let path = folderPath + "/" + WikiStore.groupFileName
                    let desired = try imageData(after ? image.afterImage : image.beforeImage, wiki: wiki)
                    let other = try imageData(after ? image.beforeImage : image.afterImage, wiki: wiki)
                    let current = try wiki.relativeData(path)
                    guard current == desired || current == other else {
                        throw WikiStore.WikiError.conflict(path, "分组补偿版本不符")
                    }
                    if let desired {
                        try SafeWiki.write(desired, name: WikiStore.groupFileName,
                            in: folderPath.split(separator: "/").map(String.init), under: wiki.root)
                    } else {
                        try SafeWiki.remove(WikiStore.groupFileName, in: folderPath.split(separator: "/").map(String.init), under: wiki.root)
                    }
                    if !after && image.createdByThisApproval && wiki.folderExists(folderPath) {
                        let folder = try SafeWiki.folder(folderPath.split(separator: "/").map(String.init), under: wiki.root, create: false)
                        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                        if names.allSatisfy({ $0 == WikiStore.indexFileName }) {
                            try SafeWiki.remove(WikiStore.indexFileName, in: folderPath.split(separator: "/").map(String.init), under: wiki.root)
                            try FileManager.default.removeItem(at: folder)
                        }
                    }
                }
            }
        }
        func relink() throws {
            for page in receipt.relinked ?? [] {
                try step("重连页：\(page.path)") {
                    let path = wiki.pageExists(page.path) ? page.path : page.beforePath ?? page.path
                    let desired = after ? page.afterVersion : page.beforeVersion
                    let other = after ? page.beforeVersion : page.afterVersion
                    let current = wiki.version(of: path)
                    if current == desired { return }
                    guard current == other, let entry = after ? page.afterHistoryEntry : page.beforeHistoryEntry else {
                        throw WikiStore.WikiError.conflict(path, "重连页补偿版本不符 / 前像缺失")
                    }
                    _ = try wiki.checkedPageURL(path)
                    if wiki.historyText(path, entry: entry).map({ WikiStore.version(of: Data($0.utf8)) }) == desired {
                        _ = try wiki.restore(path, entry: entry, expectedVersion: current, now: now, recordingHistory: false)
                    } else {
                        let historyPath = path == page.path ? page.beforePath ?? page.path : page.path
                        guard let raw = wiki.historyText(historyPath, entry: entry), WikiStore.version(of: Data(raw.utf8)) == desired else {
                            throw WikiStore.WikiError.notFound(entry)
                        }
                        _ = try wiki.saveRaw(raw, path: path, now: now, recordingHistory: false)
                    }
                }
            }
        }
        if after { try groups(receipt.groupImages ?? []) }
        else { try relink() }
        let moves = after ? receipt.moves ?? [] : (receipt.moves ?? []).reversed().map { $0 }
        for move in moves {
            let from = after ? move.from : move.to, to = after ? move.to : move.from
            try step((move.isFolder ? "目录：" : "页：") + from + " → " + to) {
                let suffix = move.isFolder ? "" : ".md"
                let sourceExists = move.isFolder ? wiki.folderExists(from) : wiki.pageExists(from)
                let targetExists = move.isFolder ? wiki.folderExists(to) : wiki.pageExists(to)
                if !sourceExists {
                    guard targetExists else { throw WikiStore.WikiError.notFound(from) }
                    return
                }
                if move.isFolder {
                    let expected = move.files
                    guard try wiki.relativeFiles(from, excludingIndexes: true) == expected else {
                        throw WikiStore.WikiError.conflict(from, "挪回目录版本不符")
                    }
                } else {
                    guard wiki.version(of: from) == receipt.pages.first(where: { $0.path == move.to })?.beforeVersion else {
                        throw WikiStore.WikiError.conflict(from, "挪回页版本不符")
                    }
                }
                try beforeMove(from, to)
                try wiki.moveRelative(from: from + suffix, to: to + suffix, isFolder: move.isFolder)
            }
            var start = 0
            while start < move.history.count {
                let path = (move.history[start].from as NSString).deletingLastPathComponent
                var end = start + 1
                while end < move.history.count && (move.history[end].from as NSString).deletingLastPathComponent == path { end += 1 }
                try step("历史：\(path)") {
                    for history in move.history[start..<end] {
                        let source = after ? history.from : history.to, target = after ? history.to : history.from
                        if try wiki.relativeData(source) == nil {
                            guard try wiki.relativeData(target).map(WikiStore.version(of:)) == history.version else {
                                throw WikiStore.WikiError.conflict(target, "历史补偿版本不符")
                            }
                            continue
                        }
                        guard try wiki.relativeData(source).map(WikiStore.version(of:)) == history.version else {
                            throw WikiStore.WikiError.conflict(source, "历史补偿版本不符")
                        }
                        try wiki.moveRelative(from: source, to: target)
                    }
                }
                start = end
            }
        }
        if after { try relink() }
        else { try groups((receipt.groupImages ?? []).sorted { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) }
    }
}
