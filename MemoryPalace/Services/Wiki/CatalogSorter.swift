import MemoryCore
import Foundation
import SwiftData

// MARK: - C3 用哪个模型（同 C2 那一套：空 = 跟提取模型；能选本机，本机没下 / 在后台 → 这一轮用提取模型）

enum CatalogModelRoute {
    static let key = "mem_model_c3"

    @MainActor
    static func resolve(providerManager: ProviderManager, chatFallback: ProviderModel, defaults: UserDefaults = .standard) -> FragmentModelRoute.Resolved {
        FragmentModelRoute.resolve(providerManager: providerManager, chatFallback: chatFallback, defaults: defaults, choiceKey: key)
    }
}

// MARK: - 原料：碎片池里待整理的（plan-memory-c3-catalog 4.1、⧫B）

/// 送给 C3 的一条碎片（不带 SwiftData 对象，能过线程）
struct CatalogFragment: Equatable, Sendable {
    let id: UUID
    let content: String
    let category: String
    let day: String
    var organizedAt: Date? = nil
    var organizedPage: String? = nil
    var rejected = false
    var keywords: [String] = []
    var subject: String? = nil
    var speaker: String? = nil
    var embeddingData: Data? = nil
    var embeddingRevision: Int? = nil
    var profileId: String = ""

    var retrievalDocument: MemoryRetrievalDocument {
        MemoryRetrievalDocument(id: id, profileId: profileId, content: content, keywords: keywords,
                                embeddingData: embeddingData, embeddingRevision: embeddingRevision)
    }

    /// 只展示快照里的归因；旧碎片缺字段时明确未知，不从正文猜。
    var attributionText: String { "主体：\(subject ?? "未知") · 发言归因：\(speaker ?? "未知")" }

    /// 手动 agent 搜碎片时给它看的状态
    var status: String {
        if rejected { return "整理时驳回" }
        guard organizedAt != nil else { return "没整理" }
        return organizedPage.map { "已整理进《\(String($0.split(separator: "/").last ?? ""))》" } ?? "单条就够"
    }

    init(id: UUID, content: String, category: String, day: String) {
        self.id = id
        self.content = content
        self.category = category
        self.day = day
    }

    init(_ m: Memory) {
        self.init(id: m.id, content: m.content, category: m.category, day: m.occurredDay ?? "")
        organizedAt = m.organizedAt
        organizedPage = m.organizedPage
        rejected = m.organizeRejectedAt != nil
        keywords = m.keywords
        subject = m.subject
        speaker = m.speaker
        embeddingData = m.embeddingData
        embeddingRevision = m.embeddingRevision
        profileId = m.profileId
    }
}

enum CatalogMaterial {
    /// 10 月起的才整理（10 月前的旧原子档案不整理）
    static let startDay = "2026-10-01"

    /// A 线搜的起点：10-01 那天 05:00
    static var startDate: Date {
        MemoryDay.date(ofKey: startDay).map { MemoryDay.boundary(of: $0) } ?? .distantPast
    }

    /// 待批提案里用到的碎片（还在等她批的正文条目和方向线索都不再发现）
    static func pendingFragmentIds(_ store: WikiProposalStore) -> Set<UUID> {
        Set(store.list().flatMap { $0.items.filter { $0.state == .pending }.flatMap { $0.organizedIds + ($0.change.direction?.clues ?? []) } })
    }

    /// 手动与自动共用的原料域；旧档案、未留、已删都不进入 C3。
    static func isEligible(_ m: Memory) -> Bool {
        m.isFragment && (m.occurredDay ?? "") >= startDay && m.reviewedAt != nil && m.supersededAt == nil
    }

    /// 能被发现的：没整理过的，加「单条就够」的（它们只跟着新证据回来）；已进页、整理驳回、待批占用的不要
    static func isCandidate(_ m: Memory, excluding: Set<UUID>) -> Bool {
        isEligible(m) && m.organizedPage == nil && m.organizeRejectedAt == nil && !excluding.contains(m.id)
    }

    /// 这个楼层的碎片池（profileId 非可选，谓词里查；别的条件内存里滤）
    static func fragments(profileId: String, context: ModelContext) -> [Memory] {
        let pid = profileId
        let rows = (try? context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { $0.profileId == pid }))) ?? []
        return rows.filter(\.isFragment).sorted { ($0.occurredDay ?? "", $0.createdAt) < ($1.occurredDay ?? "", $1.createdAt) }
    }

    /// 待整理的（后台 context 读），早的在前；「单条就够」的带着 organizedAt，只当别人的同伴
    static func pending(profileId: String, container: ModelContainer, wiki: WikiStore) async -> [CatalogFragment] {
        await Task.detached(priority: .utility) {
            let excluding = pendingFragmentIds(WikiProposalStore(wiki: wiki))
            let context = ModelContext(container)
            return fragments(profileId: profileId, context: context).filter { isCandidate($0, excluding: excluding) }.map(CatalogFragment.init)
        }.value
    }

    /// 已留碎片值快照；补算只处理本楼层合格候选，不受注入开关控制、不建图边。
    static func snapshot(profileId: String, container: ModelContainer,
                         embedder: any MemoryEmbedding = AppleMemoryEmbedder.shared,
                         cancel: CatalogCancel = CatalogCancel()) async -> [CatalogFragment] {
        await cancel.withTaskCancellation {
        await Task.detached(priority: .utility) {
            guard !cancel.isCancelled else { return [] }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let documents = fragments(profileId: profileId, context: context).filter(isEligible).map(MemoryRetrievalDocument.init)
            guard !cancel.isCancelled else { return [] }
            let filled = MemoryEmbeddingBackfill.fill(documents, embedder: embedder, cancel: cancel)
            guard !cancel.isCancelled else { return [] }
            do {
                try MemoryEmbeddingBackfill.persist(filled.documents, container: container,
                                                    revision: embedder.revision, isEligible: isEligible, cancel: cancel)
            } catch {
                CacheDiagLog.shared.log("📚 C3 向量补算保存失败：\(error.localizedDescription)")
            }
            guard !cancel.isCancelled else { return [] }
            let ids = Set(documents.map(\.id))
            let currentContext = ModelContext(container)
            return fragments(profileId: profileId, context: currentContext)
                .filter { ids.contains($0.id) && isEligible($0) }.map(CatalogFragment.init)
        }.value
        }
    }

    static func conversationIds(profileId: String, source: any ConversationSource) async -> Set<String> {
        await Task.detached(priority: .utility) {
            let rows = (try? source.windows(profileId: profileId, updatedSince: nil, includeTrashed: false)) ?? []
            return Set(rows.map(\.id))
        }.value
    }

    /// 「单条就够」：直接打标、页留空（不进提案、不用她批），后台 context 写完显式 save
    static func markSingle(_ ids: [UUID], container: ModelContainer, now: Date) async throws {
        guard !ids.isEmpty else { return }
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            for m in try context.fetch(FetchDescriptor<Memory>(predicate: #Predicate { ids.contains($0.id) })) where m.organizedPage == nil {
                m.organizedAt = now
            }
            if context.hasChanges { try context.save() }
        }.value
    }
}

// MARK: - 模型原始输出先落盘（`wiki/.proposals/drafts/`），格式不对重试也各留一份

struct CatalogDrafts: Sendable {
    static let folderName = "drafts"
    static let keepDays = 30
    static let submitArgumentsLimit = 20_000
    static let submitTextLimit = 8_000
    static let submitReasonsLimit = 4_000
    static let submitPerRunLimit = 12
    private static let submitLock = NSLock()

    let folder: URL
    let run: String

    init(wiki: WikiStore, now: Date) {
        folder = Self.folder(wiki)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        run = f.string(from: now) + "-" + UUID().uuidString.prefix(4)
    }

    static func folder(_ wiki: WikiStore) -> URL {
        wiki.root.appendingPathComponent(WikiStore.proposalsFolder, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
    }

    static func safeName(_ s: String) -> String {
        String(s.map { "/\\:*?\"<>|".contains($0) || $0.isNewline ? "_" : $0 }.prefix(40))
    }

    @discardableResult
    func save(_ text: String, name: String) -> URL {
        let url = folder.appendingPathComponent("\(run)-\(Self.safeName(name)).txt")
        try? WikiStore.writeAtomic(Data(text.utf8), to: url)
        return url
    }

    private static func clipped(_ text: String, limit: Int, marker: String) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n" + marker
    }

    /// 提交取证：调用方放到后台；同轮多次提交逐份保留，不覆盖。同一次 run 最多 12 份。
    @discardableResult
    func saveSubmit(argumentsJSON: String, text: String, truncated: Bool?, parsed: CatalogItems.Parsed?, topic: String, round: Int) -> URL? {
        let end = argumentsJSON.index(argumentsJSON.startIndex, offsetBy: Self.submitArgumentsLimit, limitedBy: argumentsJSON.endIndex) ?? argumentsJSON.endIndex
        let arguments = String(argumentsJSON[..<end])
        let argumentsClipped = end != argumentsJSON.endIndex
        let truncation = truncated.map { $0 ? "true" : "false" } ?? "未知/不适用"
        let result: String
        if truncated == true {
            result = "解析结果：跳过（truncated=true）\nitems：未知\ndropped：未知\ndropReasons：未知\nreason：未知（未解析）"
        } else if let parsed {
            let reasons = parsed.dropReasons.isEmpty ? "（无）" : parsed.dropReasons.map { "- \($0)" }.joined(separator: "\n")
            let reasonSection = Self.clipped("dropReasons：\n\(reasons)\nreason：\(parsed.reason ?? "（无）")",
                                             limit: Self.submitReasonsLimit, marker: "【原因列表超过 4000 字符，已截断】")
            result = "解析结果：成功\nitems：\(parsed.items.count)\ndropped：\(parsed.dropped)\n\(reasonSection)"
        } else {
            result = "解析结果：格式不合格（不是有效的 items 对象）\nitems：未知\ndropped：未知\ndropReasons：整包格式不合格，无法逐项解析\nreason：未知（未解析）"
        }
        let body = Self.clipped(text, limit: Self.submitTextLimit, marker: "【正文超过 8000 字符，已截断】")
        let report = """
        argumentsJSON：
        \(arguments)
        \(argumentsClipped ? "【argumentsJSON 超过 20000 字符，已截断】" : "【argumentsJSON 完整】")

        正文：
        \(body)

        truncated：\(truncation)
        \(result)
        """
        return Self.submitLock.withLock {
            let fm = FileManager.default
            let savedCount = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
                $0.hasPrefix(run + "-") && $0.contains("-submit-")
            }.count
            guard savedCount < Self.submitPerRunLimit else {
                CacheDiagLog.shared.log("📚 整理编目: \(run) 的提交草稿已达 12 份，后续不再落盘")
                return nil
            }
            let stem = "\(run)-\(Self.safeName(topic))-submit-\(round)"
            var url = folder.appendingPathComponent("\(stem).txt")
            var suffix = 2
            while fm.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(stem)-\(suffix).txt")
                suffix += 1
            }
            try? WikiStore.writeAtomic(Data(report.utf8), to: url)
            return url
        }
    }

    /// 30 天前的删掉（每天自动那次顺手调）
    static func prune(_ wiki: WikiStore, now: Date) {
        let fm = FileManager.default
        let dir = folder(wiki)
        let cutoff = now.addingTimeInterval(-TimeInterval(keepDays) * 86_400)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let url = dir.appendingPathComponent(name)
            if let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}


// MARK: - 严格 JSON 调一次（照 C2：整包正好一个对象；不合格带提醒重来）

extension CatalogJSON {
    static let retryNote = "\n\n（上一次不合格：只输出一个 JSON 对象，不要别的字，字段照上面的格式。）"

    /// 每次的原始输出先落盘再解析；不合格重来，最多 retries 次，还不合格抛 `.format`。nil = 预算闸 / 空输出（不算失败）。
    /// 停了：发请求前、请求回来后都查，抛 CancellationError
    static func call<T>(system: String, user: String, retries: Int, caller: SessionSegmentWriter.Caller,
                        drafts: CatalogDrafts?, name: String, userName: String, cancel: CatalogCancel? = nil,
                        run: CatalogRunRecord? = nil, parse: (String) -> T?) async throws -> T? {
        do {
            for attempt in 0...retries {
                try cancel?.check()
                let requestUser = attempt == 0 ? user : user + retryNote
                let round = "\(name) · 第 \(attempt + 1) 次"
                let reply = try await request(system: system, user: requestUser, caller: caller, run: run, name: round, userName: userName)
                try cancel?.check()
                guard let raw = reply else { return nil }
                if let drafts {
                    await Task.detached(priority: .utility) {
                        drafts.save(raw, name: attempt == 0 ? name : "\(name)-重试\(attempt)")
                    }.value
                }
                if let value = parse(raw) {
                    run?.section("\(round) · 解析", body: "解析成功。")
                    return value
                }
                run?.section("\(round) · 解析", body: "解析失败：不是合格的 JSON 对象或字段格式不合格。\n\n" + (attempt < retries ? "下一次请求将回灌原始提醒：\n" + CatalogRunRecord.code(retryNote) : "已达到原有格式重试次数，不再重试。"))
                CacheDiagLog.shared.log("📚 整理编目: \(name) 不是合格的 JSON，" + (attempt < retries ? "重来" : "不收"))
            }
            throw MemoryWriterError.format("整理编目「\(name)」\(retries + 1) 次都不是合格的 JSON")
        } catch {
            run?.section("\(name) · 中止", body: CatalogRunRecord.code(error is CancellationError ? "已取消。" : "错误：\(error.localizedDescription)"))
            throw error
        }
    }

    /// 只观察模型调用；独立计量本次花费，并原额加回外层任务，包含抛错时已经发生的花费。
    /// 发出去的提示词把本人那组 `{{user}}` 显示成名字（userName = 楼层用户名）；回复原样返回（落盘草稿、运行记录都是模型原文），
    /// 各解析器恢复出正文后按自己的路径位置还原 {{user}}（WikiStore.storedJSON + WikiPathFields）
    static func request(system: String, user: String, caller: SessionSegmentWriter.Caller,
                        run: CatalogRunRecord?, name: String, userName: String) async throws -> String? {
        let system = WikiStore.shown(system, user: userName), user = WikiStore.shown(user, user: userName)
        guard let run else { return try await caller(system, user) }
        run.section("\(name) · 模型请求 · 系统提示与用户文本", body: "系统文本：\n\(CatalogRunRecord.code(system))\n\n用户文本（含本次实际回灌）：\n\(CatalogRunRecord.code(user))")
        let outerMeter = MemoryWriteLog.meter
        let meter = MemoryWriteLog.CostMeter()
        defer {
            if let usd = meter.usd { outerMeter?.add(usd) }
            run.section("\(name) · 花费", body: meter.usd.map { "本次花费（美元）：\($0)" } ?? "本次花费未知（调用方未提供计费）。")
        }
        do {
            let reply = try await MemoryWriteLog.$meter.withValue(meter) { try await caller(system, user) }
            if let raw = reply {
                run.section("\(name) · 模型原文", body: CatalogRunRecord.code(raw))
            } else {
                run.section("\(name) · 无输出", body: "预算闸 / 空输出：调用方返回 nil，不算格式失败，不重试。")
            }
            return reply
        } catch {
            run.section("\(name) · 请求结束", body: CatalogRunRecord.code(error is CancellationError ? "请求已取消。" : "请求错误：\(error.localizedDescription)"))
            throw error
        }
    }

    /// 编号可以写成 "f3" 也可以写成 3
    struct Label: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                value = s.trimmingCharacters(in: .whitespaces)
            } else {
                value = "f\(try c.decode(Int.self))"
            }
        }
    }

    /// 一项一项解：解不开的那项记 nil（只扔那项）
    struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? Container<T>(from: decoder).value
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String, onError: ((String) -> Void)? = nil) -> T? {
        do {
            return try decodeValue(type, text)
        } catch let failure as Failure {
            onError?(failure.message)
            return nil
        } catch {
            onError?(error.localizedDescription)
            return nil
        }
    }
}

// MARK: - 提示词里两步、手动 agent 共用的几句

enum CatalogPrompts {
    static func pathRules(names: MemoryExtractor.Names) -> String {
        """
        路径写成「组 / 页名」：第一段只能是这九组之一——\(WikiStore.branchesText)。{{user}} 这组 = \(names.user)本人（拆成多页，比如 {{user}}/模型船收藏）；工程 = 代码工程、app；别的按类放（人放 人/，地点放 地点/……）。中间可以再分组（比如 {{user}}/行为模式/涨潮前囤灯），最后一段是页名。
        类只能是：用户 / 人 / 物 / 地点 / 时间 / 事 / 项目 / 主题。用户 = \(names.user)本人，页挂在 {{user}}/ 下，按内容自己起页名，不预设子页；时间 = 纪念日、生日这类特定的日子，不是每天记账；事 = 一件事的起因、经过、结果，可以横跨很多窗口很多天；主题 = 关注的主题，比如模型船制作。
        """
    }

    /// 模型写的路径：去空白、去头尾斜杠、去 .md
    static func normalizedPath(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if p.hasPrefix("[["), p.hasSuffix("]]") { p = String(p.dropFirst(2).dropLast(2)) }
        if p.lowercased().hasSuffix(".md") { p = String(p.dropLast(3)) }
        return p
    }
}

// MARK: - 自动方向 / 现在整理的主题清单：分拣（代码基线默认、零模型；模型分拣见 CatalogModelSorter）

enum CatalogSorter {
    /// 新主题攒够几条碎片才开新页（规格 Q2）
    static let newPageThreshold = 3

    struct Topic: Equatable, Sendable {
        var path: String
        var title: String
        var kind: WikiPage.Kind?
        var aliases: [String] = []
        /// 已有页 / 新主题
        var existing: Bool
        var fragmentIds: [UUID] = []
        /// 方向里定好的钩子（她可能改过）：写模块照用
        var hook: String = ""
        /// 为什么分到这一组（方向提案上给她看）
        var reason: String = ""
        /// 整理一个分组（path 是分组，比如 用户），不是写 path 这一页
        var group = false
        /// 碎片以外的线索的来源身份（A4 连续段 = 话题词 + 起始日；到期 = 页 + 期限）：提过的不再提
        var basis: [String] = []
        /// 来自 A4 时间轴的哪几天（这几天的日记录在方向交出去之前不算看过）
        var days: [String] = []

        /// 搜 A 线用的词：标题 + 别名
        var terms: [String] { WikiStore.normalizedWords([title] + aliases) }

        /// 目标身份：类型 + 路径（同名的页和分组是两个目标）
        var target: String { CatalogSorter.target(path, group: group) }
    }

    struct Grouped: Equatable, Sendable {
        var topics: [Topic]
        /// 同时碰上几页、拿不准的：留着等以后
        var unclear: Int
        /// 模型分拣从 A4 时间轴提的开新页（只来自时间轴，没有碎片线索）；代码基线的另算（`timeline(_:…)`）
        var timeline: [Topic] = []
    }

    static func label(_ i: Int) -> String { "f\(i + 1)" }

    static func target(_ path: String, group: Bool) -> String { (group ? "分组:" : "页:") + path }

    /// 碎片标题的词：主体 + 关键词（旧碎片只有关键词）；名字、「不触发的词」不算
    static func titleWords(_ f: CatalogFragment, blocked: Set<String>) -> [String] {
        WikiStore.normalizedWords([f.subject ?? ""] + f.keywords).filter { !blocked.contains(key($0)) }
    }

    /// 给人看的碎片标题；什么都没有 = 未命名碎片 + 短编号
    static func title(_ f: CatalogFragment, blocked: Set<String> = []) -> String {
        let words = titleWords(f, blocked: blocked)
        return words.isEmpty ? "未命名碎片 " + f.id.uuidString.prefix(8).lowercased() : words.joined(separator: " · ")
    }

    /// 代码基线（零模型）：碎片的 subject / tags / content 里逐字出现某页的标题 / 触发词 → 归那页（碰上不止一页 = 拿不准，留着）；
    /// 没对上任何页的按规范化后的 subject 聚（真没有 subject 的旧碎片按第一个关键词），同组 ≥3 条 → 以它提开新页，路径先放「主题/」；
    /// subject 是{用户}本人的不以名字开页，凑够 3 条提一条「整理{用户}本人」（分组方向），归哪页、开不开页交写手。
    /// subject 是助手名、「不触发的词」的不开页。每组至少一条没整理过的（单条就够的只跟着新证据回来）
    static func group(_ pool: [CatalogFragment], pages: [WikiInjectionSnapshot.Page], blocked: [String], user: String = "") -> Grouped {
        let blockedSet = Set(blocked.map(key).filter { !$0.isEmpty })
        let pageTerms = pages.map { page -> (WikiInjectionSnapshot.Page, [String]) in
            var seen = Set<String>()
            let terms = ([page.title] + page.triggers).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !blockedSet.contains(key($0)) && seen.insert(key($0)).inserted }
            return (page, terms)
        }
        let me = user.trimmingCharacters(in: .whitespacesAndNewlines)
        var order: [String] = []
        var topics: [String: Topic] = [:]
        var hits: [String: [String]] = [:]
        var newKeys: [String: String] = [:]
        var unclear = 0
        for f in pool {
            let text = ([f.subject ?? ""] + f.keywords + [f.content]).joined(separator: "\n")
            let matched = pageTerms.filter { !$0.1.isEmpty && WikiInjection.match($0.1, in: text) != nil }
            if matched.count > 1 {
                unclear += 1
                continue
            }
            if let hit = matched.first {
                let (page, terms) = hit
                let id = target(page.path, group: false)
                if topics[id] == nil {
                    order.append(id)
                    topics[id] = Topic(path: page.path, title: page.title, kind: nil, aliases: page.triggers, existing: true)
                }
                topics[id]!.fragmentIds.append(f.id)
                for (field, value) in [("subject", f.subject ?? ""), ("tags", f.keywords.joined(separator: "\n")), ("content", f.content)] {
                    guard let word = WikiInjection.match(terms, in: value)?.word else { continue }
                    let hit = "\(field)「\(word)」"
                    if !(hits[id] ?? []).contains(hit) { hits[id, default: []].append(hit) }
                }
                continue
            }
            let subject = (f.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let id: String
            if !me.isEmpty, key(subject) == key(me) {
                id = target(WikiStore.userBranch, group: true)
                if topics[id] == nil {
                    order.append(id)
                    topics[id] = Topic(path: WikiStore.userBranch, title: "\(me)本人", kind: .user, existing: false, group: true)
                }
            } else {
                guard !blockedSet.contains(key(subject)), let name = subject.isEmpty ? titleWords(f, blocked: blockedSet).first : subject else { continue }
                if let known = newKeys[key(name)] {
                    id = known
                } else {
                    let candidate = WikiPage.Kind.topic.rawValue + "/" + name
                    guard !name.contains("/"), WikiStore.isValidPagePath(candidate), !pages.contains(where: { $0.path == candidate }) else { continue }
                    id = target(candidate, group: false)
                    newKeys[key(name)] = id
                    order.append(id)
                    topics[id] = Topic(path: candidate, title: name, kind: .topic, existing: false)
                }
            }
            topics[id]!.fragmentIds.append(f.id)
        }
        for id in order {
            let t = topics[id]!
            if t.existing {
                topics[id]!.reason = "碎片里有这页的标题 / 触发词：" + (hits[id] ?? []).joined(separator: "、")
            } else if t.group {
                topics[id]!.reason = "subject 是\(me)本人、没对上现有页的有 \(t.fragmentIds.count) 条：归到 \(t.path)/ 下哪页、开不开新页交写手判断"
            } else {
                topics[id]!.reason = "subject「\(t.title)」有 \(t.fragmentIds.count) 条碎片，还没有页对上"
            }
        }
        let fresh = Set(pool.filter { $0.organizedAt == nil }.map(\.id))
        let kept = order.compactMap { topics[$0] }.filter { t in
            t.fragmentIds.contains(where: fresh.contains) && (t.existing || t.fragmentIds.count >= newPageThreshold)
        }
        return Grouped(topics: ordered(kept), unclear: unclear)
    }

    /// 比名字用的规范化：NFKC、全半角、大小写、连续空白；不合并同义词 / 昵称
    static func key(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 以前提过的方向：还在待批的目标（不重复提）、处理过的每个目标的线索碎片（没有新碎片不再提，驳回的也一样）；
    /// 碎片以外的线索按来源身份算，待批的、处理过的、提案清掉了但记在已处理状态里的都算提过
    static func priorDirections(_ store: WikiProposalStore) -> (pending: Set<String>, clues: [String: Set<UUID>], basis: Set<String>) {
        var pending = Set<String>()
        var clues: [String: Set<UUID>] = [:]
        var basis = CatalogDiscoveryState.load(store.wiki).handled
        for p in store.list() {
            for item in p.items {
                guard let d = item.change.direction else { continue }
                let id = target(d.path, group: d.group == true)
                basis.formUnion(d.basis ?? [])
                if item.state == .pending {
                    pending.insert(id)
                } else {
                    clues[id, default: []].formUnion(d.clues)
                }
            }
        }
        return (pending, clues, basis)
    }

    /// 这个主题这次算不算新：有以前没提过的碎片，或有以前没提过的来源
    static func isNew(_ t: Topic, clues: Set<UUID>, basis: Set<String>) -> Bool {
        !Set(t.fragmentIds).isSubset(of: clues) || !Set(t.basis).isSubset(of: basis)
    }

    /// 代码基线的时间轴提案（零模型）：新写成 / 刚补齐、C3 还没看过的 A4 日记录里的话题词，在完整历史里和相邻的记忆日连成 ≥2 天，
    /// 词里没有字面出现任何现有页的标题 / 触发词、本轮碎片分拣也没出这个主题 → 提开新页（只来自时间轴，批了就开，不凑 3 条碎片）。
    /// 只出现一天的不提。来源身份 = 话题词 + 这段连续在完整历史里的起始日
    static func timeline(_ source: CatalogTimeline.Source, pages: [WikiInjectionSnapshot.Page], blocked: [String], taken: [Topic]) -> [Topic] {
        let blockedSet = Set(blocked.map(key).filter { !$0.isEmpty })
        let pageTerms = pages.map { page in
            ([page.title] + page.triggers).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !blockedSet.contains(key($0)) }
        }
        var out: [Topic] = []
        var seen = Set<String>()
        for day in source.fresh {
            for raw in day.topics {
                let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let k = key(word)
                guard !k.isEmpty, !blockedSet.contains(k), !word.contains("/") else { continue }
                let run = CatalogTimeline.run(word, around: day.date, in: source.history)
                guard run.count >= 2, let start = run.first else { continue }
                let id = CatalogTimeline.identity(word, start: start)
                guard seen.insert(id).inserted else { continue }
                guard !pageTerms.contains(where: { !$0.isEmpty && WikiInjection.match($0, in: word) != nil }) else { continue }
                guard !taken.contains(where: { key($0.title) == k || WikiInjection.match($0.terms, in: word) != nil }) else { continue }
                let path = WikiPage.Kind.topic.rawValue + "/" + word
                guard WikiStore.isValidPagePath(path), !pages.contains(where: { $0.path == path }) else { continue }
                var t = Topic(path: path, title: word, kind: .topic, existing: false)
                t.reason = "A4 时间轴的话题「\(word)」\(CatalogTimeline.span(run))连续 \(run.count) 天出现，wiki 里没有页对上，本轮碎片也没分出这个主题；"
                    + "只来自时间轴：批了就开页，不用凑 \(newPageThreshold) 条碎片"
                t.basis = [id]
                t.days = run
                out.append(t)
            }
        }
        return out
    }

    /// 页上 valid_until（「现在」该复核的日子）已过：提复核这页「现在」的方向。不删、不衰减、不自动改；旧页没有期限的不提
    static func expired(_ pages: [WikiInjectionSnapshot.Page], now: Date, calendar: Calendar = .current) -> [Topic] {
        let today = MemoryDay.key(now, calendar: calendar)
        return pages.compactMap { page in
            guard let until = page.validUntil, until < today else { return nil }
            var t = Topic(path: page.path, title: page.title, kind: nil, aliases: page.triggers, existing: true)
            t.reason = "「现在」写着\(WikiPage.validUntilKey) \(until)，已经过了：复核这页的「现在」（批了才查原料重写，不删、不自动改）"
            t.basis = ["页 \(page.path) · \(WikiPage.validUntilKey) \(until)"]
            return t
        }
    }

    /// 同一个目标（页 / 分组）合成一条：碎片、别的线索、理由都并起来
    static func merged(_ topics: [Topic]) -> [Topic] {
        var order: [String] = []
        var byTarget: [String: Topic] = [:]
        for t in topics {
            guard var m = byTarget[t.target] else {
                order.append(t.target)
                byTarget[t.target] = t
                continue
            }
            for id in t.fragmentIds where !m.fragmentIds.contains(id) { m.fragmentIds.append(id) }
            for b in t.basis where !m.basis.contains(b) { m.basis.append(b) }
            for d in t.days where !m.days.contains(d) { m.days.append(d) }
            m.reason += "；" + t.reason
            byTarget[t.target] = m
        }
        return order.compactMap { byTarget[$0] }
    }

    /// 碎片多的主题在前（自动那次最多 N 个，剩下的下次）；一样多按先出现的
    static func ordered(_ topics: [Topic]) -> [Topic] {
        topics.enumerated().sorted { ($0.element.fragmentIds.count, -$0.offset) > ($1.element.fragmentIds.count, -$1.offset) }.map(\.element)
    }
}

// MARK: - A4 时间轴线索（c2c3-v2 第 8b 段）：读已经落盘的一天一条（topics），两种分拣共用；读不了只算这一路没准备好

enum CatalogTimeline {
    /// 一次最多看几天新写成 / 刚补齐的日记录；多的留到下次（进度只记看过的）
    static let batch = 31

    struct Day: Equatable, Sendable {
        var date: String
        var topics: [String]
    }

    struct Source: Equatable, Sendable {
        /// 完整历史：主调写成了的日子 → 话题（有消息的记忆日才有日记录，跨天的段每天都算）
        var history: [String: [String]] = [:]
        /// 新写成 / 刚补齐、C3 还没看过的（旧的先，最多 batch 天）
        var fresh: [Day] = []
        /// fresh 每天看时的签名：方向交出去了才记进进度
        var signatures: [String: String] = [:]
        /// 超过 batch、留到下次的天数
        var backlog = 0
        /// 真没写成：过了那天、有 A2 标题却没有主调（今天还没到时候、没有 A2 标题的日子都不算）
        var failed: [String] = []
        /// 月文件读不了：这一路整个没准备好
        var error: String? = nil

        /// 这一路的毛病（记日志用；状态没变不再记）
        var problems: [String] { error.map { ["读不了：\($0)"] } ?? failed }
    }

    static func signature(_ topics: [String]) -> String { topics.joined(separator: "\n") }

    /// 后台调；consumed = 已经看过的日子和当时的签名
    static func load(memoryRoot: URL, consumed: [String: String], now: Date, calendar: Calendar = .current) -> Source {
        let dir = TimelineStore.dir(root: memoryRoot)
        let today = MemoryDay.key(now, calendar: calendar)
        var out = Source()
        do {
            for month in try TimelineStore.monthsStrict(in: dir) {
                for r in try TimelineStore.monthStrict(month, in: dir).days {
                    guard r.headline != nil else {
                        if r.date < today, r.items.contains(where: { $0.kind == .segment }) { out.failed.append(r.date) }
                        continue
                    }
                    out.history[r.date] = r.topics
                }
            }
        } catch {
            return Source(error: error.localizedDescription)
        }
        out.failed.sort()
        let unseen = out.history.keys.sorted().filter { consumed[$0] != signature(out.history[$0]!) }
        for date in unseen.prefix(batch) {
            out.fresh.append(Day(date: date, topics: out.history[date]!))
            out.signatures[date] = signature(out.history[date]!)
        }
        out.backlog = max(0, unseen.count - batch)
        return out
    }

    static func shifted(_ date: String, by days: Int, calendar: Calendar = .current) -> String? {
        MemoryDay.date(ofKey: date, calendar: calendar).flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
            .map { MemoryDay.key(MemoryDay.boundary(of: $0, calendar: calendar), calendar: calendar) }
    }

    /// 这个词在 date 所在那段连续里出现的每一天（完整历史，旧 → 新）；date 那天没有这个词 = 空
    static func run(_ word: String, around date: String, in history: [String: [String]], calendar: Calendar = .current) -> [String] {
        let k = CatalogSorter.key(word)
        func has(_ d: String) -> Bool { history[d]?.contains { CatalogSorter.key($0) == k } ?? false }
        guard has(date) else { return [] }
        var run = [date]
        var d = date
        while let p = shifted(d, by: -1, calendar: calendar), has(p) {
            run.insert(p, at: 0)
            d = p
        }
        d = date
        while let n = shifted(d, by: 1, calendar: calendar), has(n) {
            run.append(n)
            d = n
        }
        return run
    }

    /// 来源身份：话题词 + 这段连续在完整历史里的起始日（两种分拣同一种）
    static func identity(_ word: String, start: String) -> String { "A4「\(CatalogSorter.key(word))」自 \(start) 起连续" }

    /// 模型提的：词就是它给的标题；起始日按完整历史往前找，标题不是当天的话题词就用它依据的最早一天
    static func identified(_ t: CatalogSorter.Topic, history: [String: [String]]) -> CatalogSorter.Topic {
        guard let first = t.days.min() else { return t }
        var out = t
        out.basis = [identity(t.title, start: run(t.title, around: first, in: history).first ?? first)]
        return out
    }

    static func span(_ run: [String]) -> String {
        let md = run.map { String($0.dropFirst(5)) }
        return md.count <= 5 ? "在 " + md.joined(separator: "、") + " " : "从 \(md.first!) 到 \(md.last!) "
    }

    /// 给模型分拣看的：每个新写成的日子连同它前一天（看得出连没连上），有话题的
    static func modelDays(_ source: Source, calendar: Calendar = .current) -> [Day] {
        var dates = Set<String>()
        for d in source.fresh {
            dates.insert(d.date)
            if let p = shifted(d.date, by: -1, calendar: calendar), source.history[p] != nil { dates.insert(p) }
        }
        return dates.sorted().compactMap { d in source.history[d].flatMap { $0.isEmpty ? nil : Day(date: d, topics: $0) } }
    }
}

/// 自动发现的轻量状态（`wiki/.sort/discovery.json`），和提案历史分开：提案满 30 天清掉了它还在
struct CatalogDiscoveryState: Codable, Equatable {
    /// 处理过的方向的来源身份（A4 连续段、页 + 期限）
    var handled: Set<String> = []
    /// A4 日记录看到哪儿了：日期 → 看时的话题签名
    var consumed: [String: String] = [:]
    /// 上次记进日志的 A4 毛病（状态没变不再记）
    var reported: [String] = []

    static func url(_ wiki: WikiStore) -> URL {
        wiki.root.appendingPathComponent(".sort", isDirectory: true).appendingPathComponent("discovery.json")
    }

    static func load(_ wiki: WikiStore) -> CatalogDiscoveryState {
        (try? Data(contentsOf: url(wiki))).flatMap { try? JSONDecoder().decode(CatalogDiscoveryState.self, from: $0) } ?? CatalogDiscoveryState()
    }

    /// 读 — 改 — 写；没变不写
    static func update(_ wiki: WikiStore, _ change: (inout CatalogDiscoveryState) -> Void) throws {
        var state = load(wiki)
        let old = state
        change(&state)
        guard state != old else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try WikiStore.writeAtomic(encoder.encode(state), to: url(wiki))
    }

    /// 清提案之前：处理过的方向的来源身份先记下来
    static func rememberHandled(_ store: WikiProposalStore) throws {
        let done = store.list().flatMap { p in p.items.filter { $0.state != .pending }.flatMap { $0.change.direction?.basis ?? [] } }
        try update(store.wiki) { $0.handled.formUnion(done) }
    }
}
