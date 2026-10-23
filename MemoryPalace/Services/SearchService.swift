import Foundation
import SwiftData
import os

// MARK: - Search Types

enum SearchSort: String, CaseIterable {
    /// 相关度（S2-7）：只用于搜索结果；列表排序里按「最近」处理
    case relevance, recent, oldest, titleAZ, titleZA
}

enum SearchScope: String, CaseIterable {
    /// 只搜对话标题（默认；等价于"列表过滤模式"）
    case titleOnly
    /// 只搜消息内容
    case contentOnly
    /// 标题 + 内容，结果分块显示（标题块在上）
    case both
}

enum SearchResourceKind: String, CaseIterable {
    /// 对话（标题 + 内容；内容仅主线，B20 part 2）
    case conversation
    /// 分支（仅搜每个对话主线之外的分支气泡内容）
    case branchContent
    /// 贴纸（searchPlacedStickers）
    case sticker
    /// 角色卡
    case characterCard
    /// 世界书条目
    case worldBook
    /// 记忆（Memory）
    case memory
    /// 文件库（文件名 + 开头 4KB，searchFiles）
    case file
    /// 健康：四类备注 + 药名 / 剂量（S3-4；亲密记录跟面板开关）
    case health
    /// 书房：纸书书名 / 作者 / 批注 / 书签 + 有声书标题 / 书签备注（S3-5）
    case library
    /// 推特存档（S3-2：只按时间倒序，游标分页）
    case twitter
}

enum DateRange: Equatable {
    case all
    case today
    case last7Days
    case last30Days
    case last90Days
    case custom(start: Date, end: Date)

    var dateInterval: (start: Date, end: Date)? { interval() }

    /// 自然日口径，和 mac ⌘K 的 within: / after: / before: 一致（MacSearchFilters.dateBounds）：
    /// 「N 天」= 今天零点往回数 N-1 天到现在；自定义两端都含当天
    func interval(now: Date = Date(), calendar: Calendar = .current) -> (start: Date, end: Date)? {
        let today = calendar.startOfDay(for: now)
        func last(_ days: Int) -> (start: Date, end: Date) {
            (calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today, now)
        }
        switch self {
        case .all:
            return nil
        case .today:
            return (today, now)
        case .last7Days:
            return last(7)
        case .last30Days:
            return last(30)
        case .last90Days:
            return last(90)
        case .custom(let start, let end):
            let endDay = calendar.startOfDay(for: end)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: endDay)?.addingTimeInterval(-0.001) ?? end
            return (calendar.startOfDay(for: start), endOfDay)
        }
    }
}

struct SearchFilter {
    var keyword: String = ""
    /// 多词 AND（S2）：框里解析出的全部普通词；空 = 只有 keyword 一个词。keyword 取其中最长的那个
    var words: [String] = []
    var dateRange: DateRange = .all
    var roles: Set<String> = ["user", "assistant"]
    var sortOrder: SearchSort = .recent
    /// 搜索范围：标题 / 内容 / 标题+内容。默认 .titleOnly（列表过滤模式等价）
    var scope: SearchScope = .titleOnly
    /// 搜索的资源类型（对话 / 贴纸 / 角色卡 / 世界书 / 记忆）
    var resourceKind: SearchResourceKind = .conversation
    /// 当前 tab 对应的对话 id 范围。
    /// nil = 不限（「全部」/「回收站」）；非 nil = 只搜这些 conv（空 Set 表示 tab 没任何对话 → 直接返回空结果）。
    var conversationIdScope: Set<String>? = nil
    /// 回收站模式：搜已删除的对话（`conv.isTrashed == true`）；默认 false 只搜未删除。
    var includeDeletedConversations: Bool = false
    /// `ext:`：只对「文件」标签生效（空 = 不限）
    var extensions: [String] = []

    var hasActiveFilters: Bool {
        dateRange != .all || roles != Set(["user", "assistant"])
    }
}

struct MatchedNode: Identifiable {
    let id: String
    let role: String
    let preview: String
    let createTime: Date?
    let conversationId: String
    let keyword: String
}

struct SearchResult: Identifiable {
    /// 行唯一 id（convId + 块标识）。overlap conv 在 both 模式下会出现两次，必须独立 id
    let id: String
    /// 对话 id（跳转 / 选中状态用）
    let convId: String
    let convTitle: String
    let convTime: Date
    let matchedNodes: [MatchedNode]
    let isTitleMatch: Bool
    var isExpanded: Bool

    init(convId: String, convTitle: String, convTime: Date, matchedNodes: [MatchedNode], isTitleMatch: Bool) {
        self.id = "\(convId):\(isTitleMatch ? "t" : "c")"
        self.convId = convId
        self.convTitle = convTitle
        self.convTime = convTime
        self.matchedNodes = matchedNodes
        self.isTitleMatch = isTitleMatch
        self.isExpanded = !matchedNodes.isEmpty
    }
}

// MARK: - Search Service

/// 主线过滤的分批大小：每批 2 次 IN 查询，内存峰值 = 一批对话的全部节点（B9，K 实测后可调）
private let mainPathBatchSize = 20
/// 按 id 取行的 IN 查询分批大小（SQLite 变量数上限保守按 999 算）
private let idBatchSize = 500

/// 对话 / 分支一次扫描的分桶结果（S1）：「对话」= 标题 + 主线正文，「分支」= 分支正文
struct SearchBuckets {
    var title: [SearchResult] = []
    var main: [SearchResult] = []
    var branch: [SearchResult] = []
    /// 相关度排序时「对话」标签的整体次序：标题行和正文行按分数混排，标题块不再固定在前（S2-7）
    var ranked: [SearchResult]?
    /// 正文候选是不是从 S5 索引找的（DEBUG 对账用）
    var usedIndex = false

    var conversation: [SearchResult] { ranked ?? title + main }

    func results(for kind: SearchResourceKind) -> [SearchResult] {
        kind == .branchContent ? branch : conversation
    }
}

enum SearchService {

    /// index：S5 全文索引（nil = 旧扫描）。默认取 Indexer 的就绪库，测试 / 对账可显式传
    static func performSearch(filter: SearchFilter, profileId: String, container: ModelContainer,
                              index: SearchIndexStore? = SearchIndexer.shared.readyStore) async -> [SearchResult] {
        let isBranchOnly = filter.resourceKind == .branchContent
        let wantsContent = filter.scope == .contentOnly || filter.scope == .both
        let wantsTitle = filter.scope == .titleOnly || filter.scope == .both
        let buckets = await scan(filter: filter, title: wantsTitle && !isBranchOnly, main: wantsContent && !isBranchOnly,
                                 branch: isBranchOnly, profileId: profileId, container: container, index: index)
        return buckets?.results(for: filter.resourceKind) ?? []
    }

    /// 一次请求同时出「对话」「分支」两个标签的结果；分支不受 scope 影响（只搜正文）。被取消返回 nil
    /// highlightNodeIds：当前楼层有划线的消息 id（主线程从 ChatHighlightStore 读一次），相关度排序的「在乎」信号用
    static func searchConversationBuckets(filter: SearchFilter, profileId: String, container: ModelContainer,
                                          highlightNodeIds: Set<String> = [],
                                          index: SearchIndexStore? = SearchIndexer.shared.readyStore) async -> SearchBuckets? {
        let wantsContent = filter.scope == .contentOnly || filter.scope == .both
        let wantsTitle = filter.scope == .titleOnly || filter.scope == .both
        return await scan(filter: filter, title: wantsTitle, main: wantsContent, branch: true,
                          profileId: profileId, container: container, highlightNodeIds: highlightNodeIds, index: index)
    }

    /// 取消只在批与批之间生效，已发出的单次 fetch 打断不了
    private static func scan(filter: SearchFilter, title: Bool, main: Bool, branch: Bool,
                             profileId: String, container: ModelContainer,
                             highlightNodeIds: Set<String> = [], index: SearchIndexStore?) async -> SearchBuckets? {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: scanBuckets(
                        filter: filter, wantsTitle: title, wantsMain: main, wantsBranch: branch,
                        profileId: profileId, container: container, highlightNodeIds: highlightNodeIds, index: index,
                        isCancelled: { cancelled.withLock { $0 } }
                    ))
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// 正文候选（S5）：旧路径由实体节点转来；索引路径直接是索引命中，不实体化命中节点
    private struct ContentCandidate {
        let id: String
        let conversationId: String
        let role: String
        let createTime: Date?
    }

    /// 索引这次用不了（有词没有可索引字符）→ 整次搜索退回旧扫描，不混用两种口径
    private struct IndexUnusable: Error {}

    /// 先走索引；索引没就绪 / 抛错 / 有词搜不了 → 整次退回旧扫描
    private static func scanBuckets(filter: SearchFilter, wantsTitle: Bool, wantsMain: Bool, wantsBranch: Bool,
                                    profileId: String, container: ModelContainer, highlightNodeIds: Set<String>,
                                    index: SearchIndexStore?, isCancelled: () -> Bool) -> SearchBuckets? {
        if let index {
            do {
                return try scanBucketsThrowing(filter: filter, wantsTitle: wantsTitle, wantsMain: wantsMain,
                                               wantsBranch: wantsBranch,
                                               profileId: profileId, container: container, highlightNodeIds: highlightNodeIds,
                                               index: index, isCancelled: isCancelled)
            } catch {
                KBProbe.log("[SEARCH] index fallback: \(error)")
            }
        }
        return try? scanBucketsThrowing(filter: filter, wantsTitle: wantsTitle, wantsMain: wantsMain,
                                        wantsBranch: wantsBranch,
                                        profileId: profileId, container: container, highlightNodeIds: highlightNodeIds,
                                        index: nil, isCancelled: isCancelled)
    }

    private static func scanBucketsThrowing(filter: SearchFilter, wantsTitle: Bool, wantsMain: Bool, wantsBranch: Bool,
                                            profileId: String, container: ModelContainer, highlightNodeIds: Set<String>,
                                            index: SearchIndexStore?, isCancelled: () -> Bool) throws -> SearchBuckets? {
        var buckets = SearchBuckets()
        buckets.usedIndex = index != nil
        if let scope = filter.conversationIdScope, scope.isEmpty { return buckets }

        let context = ModelContext(container)
        context.autosaveEnabled = false
        let pid = profileId
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = filter.dateRange.dateInterval
        let scope = filter.conversationIdScope
        let wantDeleted = filter.includeDeletedConversations
        let sorter = resultSorter(filter.sortOrder)
        let words = filter.words.isEmpty ? (keyword.isEmpty ? [] : [keyword]) : filter.words
        let multiWord = words.contains { $0 != keyword }
        let relevance = filter.sortOrder == .relevance
        if index != nil, words.contains(where: { SearchTextSegmenter.ftsQuery(for: $0) == nil }) { throw IndexUnusable() }
        /// 命中消息清洗后的全文：多词 AND 要按消息复核其余词，相关度要按消息算字面分
        var contentById: [String: String] = [:]

        // --- 1. 正文：一次关键词扫描，按主线 / 分支分桶（时间过滤不进 predicate，理由见 performSearchLegacy）
        if (wantsMain || wantsBranch) && !keyword.isEmpty {
            // 旧路径的实体节点按 id 留着，片段 / 全文按需清洗；索引路径的全文按批从索引取
            var legacyNodes: [String: MessageNode] = [:]
            var contentNodes: [ContentCandidate]
            if let index {
                guard let found = try index.hits(word: keyword, profileId: pid,
                                                 roles: filter.roles.intersection(["user", "assistant"]),
                                                 interval: interval, scope: scope) else { throw IndexUnusable() }
                contentNodes = found.map {
                    ContentCandidate(id: $0.nodeId, conversationId: $0.conversationId, role: $0.role, createTime: $0.created)
                }
            } else {
                let nodes = fetchContentWithKeyword(
                    context: context, search: keyword, profileId: pid,
                    hasUser: filter.roles.contains("user"), hasAssistant: filter.roles.contains("assistant")
                )
                legacyNodes = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                contentNodes = nodes.map {
                    ContentCandidate(id: $0.id, conversationId: $0.conversationId, role: $0.role, createTime: $0.createTime)
                }
            }
            func bodies(_ ids: [String]) throws -> [String: String] {
                if let index { return try index.bodies(nodeIds: ids) }
                var out: [String: String] = [:]
                for id in ids { if let node = legacyNodes[id] { out[id] = ContentCleaner.clean(node.content, cacheKey: node.id) } }
                return out
            }
            if let interval {
                let s = interval.start
                let e = interval.end
                contentNodes = contentNodes.filter { node in
                    guard let t = node.createTime else { return false }
                    return t >= s && t <= e
                }
            }
            if let scope { contentNodes = contentNodes.filter { scope.contains($0.conversationId) } }
            if isCancelled() { return nil }

            var mainByConv: [String: [MatchedNode]] = [:]
            var branchByConv: [String: [MatchedNode]] = [:]
            // 结果行的标题 / 时间直接取主线过滤那批查到的对话，不再整楼层取（S1-3）
            var convMap: [String: Conversation] = [:]
            let nodesByConv = Dictionary(grouping: contentNodes) { $0.conversationId }
            let hitConvIds = Array(nodesByConv.keys)
            for start in stride(from: 0, to: hitConvIds.count, by: mainPathBatchSize) {
                if isCancelled() { return nil }
                let chunk = Array(hitConvIds[start..<min(start + mainPathBatchSize, hitConvIds.count)])
                let convDesc = FetchDescriptor<Conversation>(
                    predicate: #Predicate<Conversation> { chunk.contains($0.id) && $0.profileId == pid }
                )
                let convs = (try? context.fetch(convDesc)) ?? []
                if isCancelled() { return nil }
                for conv in convs where conv.isTrashed == wantDeleted { convMap[conv.id] = conv }
                let currentNodeByConv = Dictionary(uniqueKeysWithValues: convs.map { ($0.id, $0.currentNodeId) })
                let selectionByConv = Dictionary(uniqueKeysWithValues: convs.map { ($0.id, $0.branchSelectionData) })
                let allNodesDesc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { chunk.contains($0.conversationId) && $0.profileId == pid }
                )
                let allNodesInChunk = (try? context.fetch(allNodesDesc)) ?? []
                let allNodesByConv = Dictionary(grouping: allNodesInChunk) { $0.conversationId }
                var kept: [(node: ContentCandidate, onMain: Bool)] = []
                for convId in chunk {
                    // 对话行查不到（孤儿节点）→ 整对话排除
                    guard let currentNodeId = currentNodeByConv[convId],
                          let nodesInConv = nodesByConv[convId] else { continue }
                    let mainPathSet = ConversationViewModel.computeMainPathSet(
                        nodes: allNodesByConv[convId] ?? [],
                        currentNodeId: currentNodeId,
                        selectionData: selectionByConv[convId] ?? nil
                    )
                    for node in nodesInConv {
                        let onMain = mainPathSet.contains(node.id)
                        guard onMain ? wantsMain : wantsBranch else { continue }
                        kept.append((node, onMain))
                    }
                }
                let bodyById = try bodies(kept.map(\.node.id))
                for (node, onMain) in kept {
                    let cleaned = bodyById[node.id] ?? ""
                    if multiWord || relevance { contentById[node.id] = cleaned }
                    let matched = MatchedNode(
                        id: node.id,
                        role: node.role,
                        preview: MacSearchQuery.excerpt(cleaned, words: words),
                        createTime: node.createTime,
                        conversationId: node.conversationId,
                        keyword: keyword
                    )
                    if onMain {
                        mainByConv[node.conversationId, default: []].append(matched)
                    } else {
                        branchByConv[node.conversationId, default: []].append(matched)
                    }
                }
            }

            if isCancelled() { return nil }
            if !mainByConv.isEmpty || !branchByConv.isEmpty {
                func rows(_ byConv: [String: [MatchedNode]]) -> [SearchResult] {
                    byConv.compactMap { convId, nodes in
                        convMap[convId].map {
                            SearchResult(convId: $0.id, convTitle: $0.title, convTime: $0.updateTime,
                                         matchedNodes: nodes, isTitleMatch: false)
                        }
                    }.sorted(by: sorter)
                }
                buckets.main = rows(mainByConv)
                buckets.branch = rows(branchByConv)
            }
        }

        // --- 2. 标题
        if wantsTitle {
            if isCancelled() { return nil }
            buckets.title = fetchFilteredConversations(
                context: context, keyword: keyword, profileId: pid, interval: interval,
                includeDeleted: wantDeleted
            )
            .filter { scope?.contains($0.id) ?? true }
            .map { SearchResult(convId: $0.id, convTitle: $0.title, convTime: $0.updateTime, matchedNodes: [], isTitleMatch: true) }
            .sorted(by: sorter)
        }

        if multiWord {
            if isCancelled() { return nil }
            guard try requireAllWords(&buckets, words: words, keyword: keyword, filter: filter, contentById: contentById,
                                      context: context, profileId: pid, interval: interval, index: index,
                                      isCancelled: isCancelled) else { return nil }
        }
        if relevance {
            if isCancelled() { return nil }
            rank(&buckets, words: words, contentById: contentById, highlightNodeIds: highlightNodeIds,
                 context: context, profileId: pid)
        }
        return buckets
    }

    /// 相关度（S2-7）：「对话」标签按对话打分（取这个对话里分数最高的那条命中，标题行 / 正文行同分），「分支」按行打分
    private static func rank(_ buckets: inout SearchBuckets, words: [String], contentById: [String: String],
                             highlightNodeIds: Set<String>, context: ModelContext, profileId: String) {
        let pid = profileId
        let convIds = Array(Set((buckets.title + buckets.main + buckets.branch).map(\.convId)))
        var convs: [String: Conversation] = [:]
        for start in stride(from: 0, to: convIds.count, by: idBatchSize) {
            let chunk = Array(convIds[start..<min(start + idBatchSize, convIds.count)])
            let desc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { chunk.contains($0.id) && $0.profileId == pid })
            for conv in (try? context.fetch(desc)) ?? [] { convs[conv.id] = conv }
        }
        let markedIds = Array(highlightNodeIds)
        var highlighted = Set<String>()
        for start in stride(from: 0, to: markedIds.count, by: idBatchSize) {
            let chunk = Array(markedIds[start..<min(start + idBatchSize, markedIds.count)])
            var desc = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { chunk.contains($0.id) && $0.profileId == pid })
            desc.propertiesToFetch = [\.conversationId]
            for node in (try? context.fetch(desc)) ?? [] { highlighted.insert(node.conversationId) }
        }

        func literal(_ row: SearchResult) -> Int {
            row.matchedNodes.map { MacSearchQuery.score(title: row.convTitle, body: contentById[$0.id] ?? "", words: words) }.max()
                ?? MacSearchQuery.score(title: row.convTitle, body: "", words: words)
        }
        func ranked(_ rows: [SearchResult]) -> [SearchResult] {
            var best: [String: Int] = [:]
            for row in rows { best[row.convId] = max(best[row.convId] ?? 0, literal(row)) }
            return SearchRelevance.order(rows) { row in
                let conv = convs[row.convId]
                return SearchRelevance.Signals(
                    literal: best[row.convId] ?? 0, updated: row.convTime,
                    starred: conv?.isFavorite ?? false, pinned: conv?.isPinned ?? false,
                    highlighted: highlighted.contains(row.convId), lastOpened: conv?.lastOpenedAt,
                    messageCount: conv?.nodeCount ?? 0)
            }
        }
        buckets.ranked = ranked(buckets.title + buckets.main)
        buckets.branch = ranked(buckets.branch)
    }

    /// 多词 AND（S2-6）：最长词已经取到候选对话；每个候选在**该对话内**按其余每个词补查一次正文（按批，限定候选对话），
    /// 「标题 ∪ 正文」全部词都命中才保留。消息级命中只留同时含全部词的那几条（范围含标题时标题里的词也算）；
    /// 对话够格但没有一条消息含全部词时，正文行照样保留、只是不带消息（同一对话已有标题行就不重复）。被取消返回 false
    /// index 非 nil：其余词改查索引（限定候选对话），对话级 AND 语义不变
    private static func requireAllWords(_ buckets: inout SearchBuckets, words: [String], keyword: String, filter: SearchFilter,
                                        contentById: [String: String], context: ModelContext, profileId: String,
                                        interval: (start: Date, end: Date)?, index: SearchIndexStore?,
                                        isCancelled: () -> Bool) throws -> Bool {
        let pid = profileId
        let keywordBody = Set(buckets.main.map(\.convId) + buckets.branch.map(\.convId))
        let candidates = Array(keywordBody.union(buckets.title.map(\.convId)))
        var bodyHits: [String: Set<String>] = [:]
        for word in Set(words) where word != keyword {
            if let index {
                if isCancelled() { return false }
                guard let found = try index.hits(word: word, profileId: pid, roles: filter.roles, interval: interval,
                                                 scope: Set(candidates)) else { throw IndexUnusable() }
                bodyHits[word] = Set(found.map(\.conversationId))
                continue
            }
            var hits = Set<String>()
            for start in stride(from: 0, to: candidates.count, by: idBatchSize) {
                if isCancelled() { return false }
                let chunk = Array(candidates[start..<min(start + idBatchSize, candidates.count)])
                var desc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { node in
                        chunk.contains(node.conversationId) && node.profileId == pid && node.isTrashed == false &&
                        node.content.localizedStandardContains(word)
                    }
                )
                desc.propertiesToFetch = [\.conversationId, \.role, \.createTime]
                for node in (try? context.fetch(desc)) ?? [] where filter.roles.contains(node.role) {
                    if let interval {
                        guard let t = node.createTime, t >= interval.start && t <= interval.end else { continue }
                    }
                    hits.insert(node.conversationId)
                }
            }
            bodyHits[word] = hits
        }

        func qualifies(_ row: SearchResult, _ scope: SearchScope) -> Bool {
            words.allSatisfy { w in
                let inTitle = row.convTitle.localizedStandardContains(w)
                let inBody = w == keyword ? keywordBody.contains(row.convId) : bodyHits[w]?.contains(row.convId) == true
                switch scope {
                case .titleOnly: return inTitle
                case .contentOnly: return inBody
                case .both: return inTitle || inBody
                }
            }
        }
        func contentRows(_ rows: [SearchResult], _ scope: SearchScope, skipping: Set<String>) -> [SearchResult] {
            rows.compactMap { row in
                guard qualifies(row, scope) else { return nil }
                let nodes = row.matchedNodes.filter { node in
                    let body = contentById[node.id] ?? ""
                    return words.allSatisfy { w in
                        body.localizedStandardContains(w) || (scope != .contentOnly && row.convTitle.localizedStandardContains(w))
                    }
                }
                if nodes.isEmpty && skipping.contains(row.convId) { return nil }
                return SearchResult(convId: row.convId, convTitle: row.convTitle, convTime: row.convTime,
                                    matchedNodes: nodes, isTitleMatch: false)
            }
        }

        buckets.title = buckets.title.filter { qualifies($0, filter.scope == .titleOnly ? .titleOnly : .both) }
        buckets.main = contentRows(buckets.main, filter.scope, skipping: Set(buckets.title.map(\.convId)))
        buckets.branch = contentRows(buckets.branch, filter.scope == .contentOnly ? .contentOnly : .both, skipping: [])
        return true
    }

    private static func resultSorter(_ order: SearchSort) -> (SearchResult, SearchResult) -> Bool {
        switch order {
        case .relevance, .recent: return { $0.convTime > $1.convTime }
        case .oldest: return { $0.convTime < $1.convTime }
        case .titleAZ: return { $0.convTitle.localizedCompare($1.convTitle) == .orderedAscending }
        case .titleZA: return { $0.convTitle.localizedCompare($1.convTitle) == .orderedDescending }
        }
    }

    /// 回收站里被单独删掉的气泡（S3-1）：已删除且全部词都命中的消息 id，新的在前；行由主线程按 id 取 MessageNode。
    /// 不参与主线 / 分支分桶，也不进 DEBUG 新旧对账
    static func searchTrashedBubbleIds(filter: SearchFilter, profileId: String, container: ModelContainer) async -> [String] {
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let words = filter.words.isEmpty ? [keyword] : filter.words
        let interval = filter.dateRange.dateInterval
        let roles = filter.roles
        let task = Task.detached(priority: .userInitiated) { () -> [String] in
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let pid = profileId
            let desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid && node.isTrashed == true && node.content.localizedStandardContains(keyword)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
            return ((try? context.fetch(desc)) ?? []).filter { node in
                guard roles.contains(node.role) else { return false }
                if let interval {
                    guard let t = node.createTime, t >= interval.start && t <= interval.end else { return false }
                }
                return words.allSatisfy { node.content.localizedStandardContains($0) }
            }.map(\.id)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    #if DEBUG
    /// S1 前的旧实现，只留作 DEBUG 新旧结果对账（S1 验收）
    static func performSearchLegacy(filter: SearchFilter, profileId: String, container: ModelContainer) async -> [SearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // 当前 tab scope 是明确的空集 → 一定搜不到，直接 short circuit
                if let scope = filter.conversationIdScope, scope.isEmpty {
                    continuation.resume(returning: [])
                    return
                }

                let context = ModelContext(container)
                context.autosaveEnabled = false
                let scopedProfileId = profileId

                let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                let interval = filter.dateRange.dateInterval
                let hasUser = filter.roles.contains("user")
                let hasAssistant = filter.roles.contains("assistant")
                let scope = filter.conversationIdScope  // 局部捕获方便下面使用

                // .branchContent 只搜 content（标题不分主线/分支，混搜没意义）
                let isBranchOnly = filter.resourceKind == .branchContent
                let needsContent = (filter.scope == .contentOnly || filter.scope == .both) || isBranchOnly
                let needsTitle = (filter.scope == .titleOnly || filter.scope == .both) && !isBranchOnly

                // --- 1. Search message content ---
                var contentByConv: [String: [MatchedNode]] = [:]

                if needsContent && !keyword.isEmpty {
                    let search = keyword
                    // 时间过滤不放进 predicate：SwiftData 对 optional `!=nil && !` 拆包
                    // 和 `localizedStandardContains` 组合时会返回空。先按关键词+角色取出，
                    // 再在 Swift 层按 createTime 过滤。关键词已经把结果缩到很少。
                    var contentNodes = fetchContentWithKeyword(
                        context: context, search: search, profileId: scopedProfileId,
                        hasUser: hasUser, hasAssistant: hasAssistant
                    )
                    if let interval = interval {
                        let s = interval.start
                        let e = interval.end
                        contentNodes = contentNodes.filter { node in
                            guard let t = node.createTime else { return false }
                            return t >= s && t <= e
                        }
                    }

                    // B20 part 2: 主线/分支过滤
                    // .conversation → 仅保留主线 node；.branchContent → 仅保留非主线 node
                    // B9: 命中对话按批分组 IN 查询（原来每对话 2 次 fetch，几百命中 = 几百次往返）。
                    // 不用 propertiesToFetch 瘦身：computeMainPathSet 的可显判定要 hasDisplayableContent
                    // （依赖 content + segmentsData），漏列属性逐行 fault 反而更慢。
                    let needsMainPathFilter = filter.resourceKind == .conversation || filter.resourceKind == .branchContent
                    if needsMainPathFilter {
                        let nodesByConv = Dictionary(grouping: contentNodes) { $0.conversationId }
                        var allowedNodeIds = Set<String>()
                        allowedNodeIds.reserveCapacity(contentNodes.count)
                        let hitConvIds = Array(nodesByConv.keys)
                        let pid = scopedProfileId
                        for start in stride(from: 0, to: hitConvIds.count, by: mainPathBatchSize) {
                            let chunk = Array(hitConvIds[start..<min(start + mainPathBatchSize, hitConvIds.count)])
                            let convDesc = FetchDescriptor<Conversation>(
                                predicate: #Predicate<Conversation> { chunk.contains($0.id) && $0.profileId == pid }
                            )
                            let convs = (try? context.fetch(convDesc)) ?? []
                            let currentNodeByConv = Dictionary(uniqueKeysWithValues: convs.map { ($0.id, $0.currentNodeId) })
                            let selectionByConv = Dictionary(uniqueKeysWithValues: convs.map { ($0.id, $0.branchSelectionData) })
                            let allNodesDesc = FetchDescriptor<MessageNode>(
                                predicate: #Predicate<MessageNode> { chunk.contains($0.conversationId) && $0.profileId == pid }
                            )
                            let allNodesInChunk = (try? context.fetch(allNodesDesc)) ?? []
                            let allNodesByConv = Dictionary(grouping: allNodesInChunk) { $0.conversationId }
                            for convId in chunk {
                                // 对话行查不到（孤儿节点）→ 整对话排除，与改造前 guard-continue 同语义
                                guard let currentNodeId = currentNodeByConv[convId],
                                      let nodesInConv = nodesByConv[convId] else { continue }
                                let mainPathSet = ConversationViewModel.computeMainPathSet(
                                    nodes: allNodesByConv[convId] ?? [],
                                    currentNodeId: currentNodeId,
                                    selectionData: selectionByConv[convId] ?? nil
                                )
                                for node in nodesInConv {
                                    let onMain = mainPathSet.contains(node.id)
                                    if filter.resourceKind == .conversation && onMain {
                                        allowedNodeIds.insert(node.id)
                                    } else if filter.resourceKind == .branchContent && !onMain {
                                        allowedNodeIds.insert(node.id)
                                    }
                                }
                            }
                        }
                        contentNodes = contentNodes.filter { allowedNodeIds.contains($0.id) }
                    }

                    for node in contentNodes {
                        if let scope = scope, !scope.contains(node.conversationId) { continue }
                        let cleaned = ContentCleaner.clean(node.content, cacheKey: node.id)
                        let preview = buildPreview(cleaned, keyword: keyword)
                        let matched = MatchedNode(
                            id: node.id,
                            role: node.role,
                            preview: preview,
                            createTime: node.createTime,
                            conversationId: node.conversationId,
                            keyword: keyword
                        )
                        contentByConv[node.conversationId, default: []].append(matched)
                    }
                }
                // 注：无关键词+有时间+需要内容 这条路径曾经用 fetchNodesDateOnly 收集 conv，
                // 但那个函数依赖 SwiftData optional createTime predicate 会返回空。
                // 场景极边缘（用户没输关键词却搜内容），直接不跑；时间范围内的 conv 由 title
                // 路径负责列出。

                // --- 2. Search conversation titles ---
                var titleConvs: [Conversation] = []
                if needsTitle {
                    titleConvs = fetchFilteredConversations(
                        context: context, keyword: keyword, profileId: scopedProfileId, interval: interval,
                        includeDeleted: filter.includeDeletedConversations
                    )
                }

                // --- 3. 分块构建：titleBucket 与 contentBucket 独立 ---
                var titleBucket: [SearchResult] = []
                var contentBucket: [SearchResult] = []

                // 标题块：纯 title row，不展开内容（matchedNodes 强制空）
                for conv in titleConvs {
                    if let scope = scope, !scope.contains(conv.id) { continue }
                    titleBucket.append(SearchResult(
                        convId: conv.id,
                        convTitle: conv.title,
                        convTime: conv.updateTime,
                        matchedNodes: [],
                        isTitleMatch: true
                    ))
                }

                // 内容块：按 convId group matchedNodes。both 模式下 overlap conv 会在两块都出现（决策 B）
                if !contentByConv.isEmpty {
                    let wantDeleted = filter.includeDeletedConversations
                    let allConvDesc = FetchDescriptor<Conversation>(
                        predicate: #Predicate<Conversation> {
                            conv in conv.profileId == scopedProfileId && conv.isTrashed == wantDeleted
                        }
                    )
                    let allConvs = (try? context.fetch(allConvDesc)) ?? []
                    let convMap = Dictionary(uniqueKeysWithValues: allConvs.map { ($0.id, $0) })
                    for (convId, nodes) in contentByConv {
                        if let conv = convMap[convId] {
                            contentBucket.append(SearchResult(
                                convId: conv.id,
                                convTitle: conv.title,
                                convTime: conv.updateTime,
                                matchedNodes: nodes,
                                isTitleMatch: false
                            ))
                        }
                    }
                }

                // --- 4. 各块分别 sort，标题块恒在上 ---
                let sorter: (SearchResult, SearchResult) -> Bool = {
                    switch filter.sortOrder {
                    case .relevance, .recent: return { $0.convTime > $1.convTime }
                    case .oldest: return { $0.convTime < $1.convTime }
                    case .titleAZ: return { $0.convTitle.localizedCompare($1.convTitle) == .orderedAscending }
                    case .titleZA: return { $0.convTitle.localizedCompare($1.convTitle) == .orderedDescending }
                    }
                }()
                titleBucket.sort(by: sorter)
                contentBucket.sort(by: sorter)

                continuation.resume(returning: titleBucket + contentBucket)
            }
        }
    }

    /// 新旧对账，不一致打 [SEARCH-DIFF] MISMATCH，差异分三类：只在旧路径有 / 只在新路径有（行或命中消息）/ 顺序不同。
    /// 索引路径（S5）：和同一套代码关掉索引的旧扫描比，多词 AND 与相关度排序都在内；只允许 plan D2 / D3 两类差异。
    /// 非索引路径：和 S1 前的旧实现比（S1 验收，旧实现只认一个词，多词跳过）
    static func debugCompareWithLegacy(filter: SearchFilter, buckets: SearchBuckets, gen: Int,
                                       profileId: String, container: ModelContainer,
                                       highlightNodeIds: Set<String> = []) async {
        let multiWord = Set(filter.words).count > 1
        if !buckets.usedIndex && multiWord { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let scanned = buckets.usedIndex
            ? await searchConversationBuckets(filter: filter, profileId: profileId, container: container,
                                              highlightNodeIds: highlightNodeIds, index: nil)
            : nil
        if buckets.usedIndex && scanned == nil { return }
        for kind in [SearchResourceKind.conversation, .branchContent] {
            let legacy: [SearchResult]
            if let scanned {
                legacy = scanned.results(for: kind)
            } else {
                var legacyFilter = filter
                legacyFilter.resourceKind = kind
                legacy = await performSearchLegacy(filter: legacyFilter, profileId: profileId, container: container)
            }
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let current = buckets.results(for: kind)
            let nodesByRow: ([SearchResult]) -> [String: Set<String>] = { rows in
                Dictionary(rows.map { ($0.id, Set($0.matchedNodes.map(\.id))) }, uniquingKeysWith: { $0.union($1) })
            }
            let old = nodesByRow(legacy)
            let new = nodesByRow(current)
            let path = buckets.usedIndex ? "index" : "s1"
            let head = "[SEARCH-DIFF] gen=\(gen) path=\(path) kind=\(kind.rawValue) kw=\(filter.keyword) words=\(filter.words) sort=\(filter.sortOrder.rawValue) legacyMs=\(ms) rows=\(legacy.count)/\(current.count)"
            let onlyOld = Set(old.keys).subtracting(new.keys).sorted()
            let onlyNew = Set(new.keys).subtracting(old.keys).sorted()
            var nodesOnlyOld: [String] = []
            var nodesOnlyNew: [String] = []
            for row in Set(old.keys).intersection(new.keys).sorted() {
                let o = old[row] ?? [], n = new[row] ?? []
                if !o.subtracting(n).isEmpty { nodesOnlyOld.append("\(row){\(o.subtracting(n).sorted().prefix(5))}") }
                if !n.subtracting(o).isEmpty { nodesOnlyNew.append("\(row){\(n.subtracting(o).sorted().prefix(5))}") }
            }
            // 顺序只比两边都有的行（按各自结果里的先后），行集合差异不重复算进顺序
            let common = Set(old.keys).intersection(new.keys)
            let sameOrder = legacy.map(\.id).filter(common.contains) == current.map(\.id).filter(common.contains)
            if onlyOld.isEmpty && onlyNew.isEmpty && nodesOnlyOld.isEmpty && nodesOnlyNew.isEmpty && legacy.count == current.count {
                KBProbe.log(sameOrder ? "\(head) ok" : "\(head) MISMATCH orderOnly legacy=\(legacy.map(\.id).prefix(20)) new=\(current.map(\.id).prefix(20))")
                continue
            }
            KBProbe.log("\(head) MISMATCH onlyLegacy=\(onlyOld.prefix(20)) onlyNew=\(onlyNew.prefix(20)) "
                        + "nodesOnlyLegacy=\(nodesOnlyOld.prefix(20)) nodesOnlyNew=\(nodesOnlyNew.prefix(20)) sameOrder=\(sameOrder)")
        }
    }
    #endif

    // MARK: - Content Search (keyword IN predicate — SQLite filters)

    /// Keyword search, no date range
    private static func fetchContentWithKeyword(
        context: ModelContext, search: String, profileId: String,
        hasUser: Bool, hasAssistant: Bool
    ) -> [MessageNode] {
        let desc: FetchDescriptor<MessageNode>
        let pid = profileId
        if hasUser && hasAssistant {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid &&
                    node.isTrashed == false &&
                    (node.role == "user" || node.role == "assistant") &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        } else if hasUser {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid &&
                    node.isTrashed == false && node.role == "user" &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        } else if hasAssistant {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid &&
                    node.isTrashed == false && node.role == "assistant" &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        } else {
            return []
        }
        return (try? context.fetch(desc)) ?? []
    }

    /// Fetch conversations matching title keyword + date range
    /// - Parameter includeDeleted: true → 只搜已删除对话（回收站模式）；false → 只搜未删除
    private static func fetchFilteredConversations(
        context: ModelContext,
        keyword: String,
        profileId: String,
        interval: (start: Date, end: Date)?,
        includeDeleted: Bool = false
    ) -> [Conversation] {
        let wantDeleted = includeDeleted   // 本地常量，#Predicate 要能捕获
        let pid = profileId
        guard !keyword.isEmpty else {
            guard let interval = interval else { return [] }
            let startDate = interval.start
            let endDate = interval.end
            let desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == wantDeleted &&
                    conv.createTime >= startDate && conv.createTime <= endDate
                }
            )
            return (try? context.fetch(desc)) ?? []
        }

        let search = keyword
        if let interval = interval {
            let startDate = interval.start
            let endDate = interval.end
            let desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == wantDeleted &&
                    conv.title.localizedStandardContains(search) &&
                    conv.createTime >= startDate && conv.createTime <= endDate
                }
            )
            return (try? context.fetch(desc)) ?? []
        } else {
            let desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == wantDeleted && conv.title.localizedStandardContains(search)
                }
            )
            return (try? context.fetch(desc)) ?? []
        }
    }

    // MARK: - Preview Builder

    /// Extract ~80 chars around the first occurrence of keyword
    static func buildPreview(_ text: String, keyword: String) -> String {
        let lower = text.lowercased()
        let keyLower = keyword.lowercased()
        guard let range = lower.range(of: keyLower) else {
            return String(text.prefix(80))
        }

        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let contextStart = max(0, matchStart - 30)
        let startIndex = text.index(text.startIndex, offsetBy: contextStart)
        let endIndex = text.index(startIndex, offsetBy: min(80, text.distance(from: startIndex, to: text.endIndex)))

        var preview = String(text[startIndex..<endIndex])
            .replacingOccurrences(of: "\n", with: " ")
        if contextStart > 0 { preview = "..." + preview }
        if endIndex < text.endIndex { preview = preview + "..." }
        return preview
    }

    // MARK: - Sticker Search

    /// 搜索画布上的贴纸（左栏用）——按贴纸名 + 便签内容搜索，返回带对话信息的结果
    static func searchPlacedStickers(keyword: String, profileId: String, container: ModelContainer) async -> [StickerSearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let search = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !search.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                let pid = profileId

                // 1. 搜 asset name 匹配的
                let assetDesc = FetchDescriptor<StickerAsset>(
                    predicate: #Predicate<StickerAsset> { a in
                        a.profileId == pid && a.name.localizedStandardContains(search)
                    }
                )
                let matchedAssets = (try? context.fetch(assetDesc)) ?? []
                let matchedAssetIds = Set(matchedAssets.map(\.id))

                // 2. 查所有 PlacedSticker
                let placedDesc = FetchDescriptor<PlacedSticker>(
                    predicate: #Predicate<PlacedSticker> { s in s.profileId == pid }
                )
                let allPlaced = (try? context.fetch(placedDesc)) ?? []

                // 3. 过滤：asset name 匹配 or noteContent 匹配
                let matched = allPlaced.filter { s in
                    if let assetId = s.stickerAssetId, matchedAssetIds.contains(assetId) { return true }
                    if let content = s.noteContent, content.localizedStandardContains(search) { return true }
                    return false
                }

                // 4. 关联对话标题：只按命中的对话 id 分批取（S1-3）
                let convIds = Array(Set(matched.map(\.conversationId)))
                var convMap: [String: Conversation] = [:]
                for start in stride(from: 0, to: convIds.count, by: idBatchSize) {
                    let chunk = Array(convIds[start..<min(start + idBatchSize, convIds.count)])
                    let convDesc = FetchDescriptor<Conversation>(
                        predicate: #Predicate<Conversation> { c in chunk.contains(c.id) && c.profileId == pid && c.isTrashed == false }
                    )
                    for conv in (try? context.fetch(convDesc)) ?? [] { convMap[conv.id] = conv }
                }

                // 5. 构建结果
                let assetMap = Dictionary(uniqueKeysWithValues: matchedAssets.map { ($0.id, $0) })
                // 也查非名字匹配的 asset（便签内容匹配的可能没在 matchedAssets 里）；只按命中贴纸引用的 id 分批取
                let assetIds = Array(Set(matched.compactMap(\.stickerAssetId)))
                var fullAssetMap: [UUID: StickerAsset] = [:]
                for start in stride(from: 0, to: assetIds.count, by: idBatchSize) {
                    let chunk = Array(assetIds[start..<min(start + idBatchSize, assetIds.count)])
                    let assetChunkDesc = FetchDescriptor<StickerAsset>(
                        predicate: #Predicate<StickerAsset> { a in chunk.contains(a.id) && a.profileId == pid }
                    )
                    for asset in (try? context.fetch(assetChunkDesc)) ?? [] { fullAssetMap[asset.id] = asset }
                }

                var results: [StickerSearchResult] = []
                for s in matched {
                    let asset = s.stickerAssetId.flatMap { fullAssetMap[$0] }
                    let conv = convMap[s.conversationId]
                    results.append(StickerSearchResult(
                        placedStickerId: s.id,
                        assetName: asset?.name ?? (s.noteContent.map { String($0.prefix(20)) } ?? "贴纸"),
                        isNote: s.isNote,
                        thumbnailPath: asset?.thumbnailPath,
                        noteContent: s.noteContent,
                        noteStyle: s.noteStyle,
                        conversationId: s.conversationId,
                        conversationTitle: conv?.title ?? "未知对话",
                        nearestMessageId: s.nearestMessageId,
                        profileId: pid
                    ))
                }

                continuation.resume(returning: results)
            }
        }
    }

    // MARK: - Character Card Search

    /// 搜索角色卡。caller 在 MainActor 端取 manager.cards 的 snapshot 传入（避免跨 actor）
    static func searchCharacterCards(
        keyword: String,
        cards: [CharacterCard],
        filter: SearchFilter
    ) -> [CharacterCardSearchResult] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }
        let interval = filter.dateRange.dateInterval

        var results: [CharacterCardSearchResult] = []
        for card in cards {
            if let interval = interval {
                if card.createdAt < interval.start || card.createdAt > interval.end { continue }
            }
            // 优先级从高到低
            let fields: [(String, String)] = [
                ("名字", card.name),
                ("简介", card.description),
                ("补充设定", card.personality),
                ("背景设定", card.scenario),
                ("开场", card.firstMes),
                ("对话示例", card.mesExample),
                ("System prompt", card.systemPrompt),
                ("Post-history", card.postHistoryInstructions),
                ("创作者备注", card.creatorNotes),
            ]
            var matchedField: String? = nil
            var preview = ""
            for (fname, fvalue) in fields where fvalue.localizedStandardContains(kw) {
                matchedField = fname
                preview = buildPreview(fvalue, keyword: kw)
                break
            }
            if matchedField == nil {
                for greeting in card.alternateGreetings where greeting.localizedStandardContains(kw) {
                    matchedField = "开场"
                    preview = buildPreview(greeting, keyword: kw)
                    break
                }
            }
            guard let field = matchedField else { continue }
            results.append(CharacterCardSearchResult(
                id: card.id,
                cardId: card.id,
                cardName: card.name,
                imageData: card.coverImageData,
                createdAt: card.createdAt,
                matchedField: field,
                preview: preview,
                keyword: kw
            ))
        }

        switch filter.sortOrder {
        case .relevance:
            let words = filter.words.isEmpty ? [kw] : filter.words
            results = SearchRelevance.order(results) {
                SearchRelevance.Signals(literal: MacSearchQuery.score(title: $0.cardName, body: $0.preview, words: words), updated: $0.createdAt)
            }
        case .recent: results.sort { $0.createdAt > $1.createdAt }
        case .oldest: results.sort { $0.createdAt < $1.createdAt }
        case .titleAZ: results.sort { $0.cardName.localizedCompare($1.cardName) == .orderedAscending }
        case .titleZA: results.sort { $0.cardName.localizedCompare($1.cardName) == .orderedDescending }
        }
        return results
    }

    // MARK: - World Book Search

    /// 搜索世界书条目：楼层 WorldBook（SwiftData） + 全局世界书（内存 snapshot）
    static func searchWorldBookEntries(
        keyword: String,
        globalBooks: [GlobalWorldBook],
        profileId: String,
        container: ModelContainer,
        filter: SearchFilter
    ) async -> [WorldBookEntrySearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !kw.isEmpty else { continuation.resume(returning: []); return }
                let interval = filter.dateRange.dateInterval

                var results: [WorldBookEntrySearchResult] = []

                // --- 1. 全局世界书（内存 snapshot） ---
                for book in globalBooks {
                    let bookNameMatch = book.name.localizedStandardContains(kw)
                    for entry in book.entries {
                        if let hit = matchWorldBookEntry(entry, keyword: kw, bookNameMatch: bookNameMatch, bookName: book.name) {
                            results.append(WorldBookEntrySearchResult(
                                id: "global:\(book.id):\(entry.id)",
                                isGlobal: true,
                                bookId: book.id,
                                bookName: book.name,
                                entryId: entry.id,
                                entryTitle: entryDisplayTitle(entry),
                                createdAt: book.updatedAt,
                                matchedField: hit.field,
                                preview: hit.preview,
                                keyword: kw
                            ))
                        }
                    }
                }

                // --- 2. 楼层 WorldBook（SwiftData） ---
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let pid = profileId
                let wbDesc = FetchDescriptor<WorldBook>(
                    predicate: #Predicate<WorldBook> { wb in wb.profileId == pid }
                )
                let books = (try? context.fetch(wbDesc)) ?? []
                for book in books {
                    let bookNameMatch = book.name.localizedStandardContains(kw)
                    for entry in book.entries {
                        if let hit = matchWorldBookEntry(entry, keyword: kw, bookNameMatch: bookNameMatch, bookName: book.name) {
                            results.append(WorldBookEntrySearchResult(
                                id: "floor:\(book.id.uuidString):\(entry.id)",
                                isGlobal: false,
                                bookId: book.id.uuidString,
                                bookName: book.name,
                                entryId: entry.id,
                                entryTitle: entryDisplayTitle(entry),
                                createdAt: book.updatedAt,
                                matchedField: hit.field,
                                preview: hit.preview,
                                keyword: kw
                            ))
                        }
                    }
                }

                // --- 时间过滤 ---
                if let interval = interval {
                    results = results.filter { $0.createdAt >= interval.start && $0.createdAt <= interval.end }
                }

                // --- 排序 ---
                switch filter.sortOrder {
                case .relevance:
                    let words = filter.words.isEmpty ? [kw] : filter.words
                    results = SearchRelevance.order(results) {
                        SearchRelevance.Signals(literal: MacSearchQuery.score(title: $0.entryTitle, body: $0.preview, words: words), updated: $0.createdAt)
                    }
                case .recent: results.sort { $0.createdAt > $1.createdAt }
                case .oldest: results.sort { $0.createdAt < $1.createdAt }
                case .titleAZ: results.sort { $0.entryTitle.localizedCompare($1.entryTitle) == .orderedAscending }
                case .titleZA: results.sort { $0.entryTitle.localizedCompare($1.entryTitle) == .orderedDescending }
                }
                continuation.resume(returning: results)
            }
        }
    }

    private static func matchWorldBookEntry(_ entry: WorldBookEntry, keyword: String, bookNameMatch: Bool, bookName: String) -> (field: String, preview: String)? {
        // 优先级：comment > content > keys > secondaryKeys > bookName
        if entry.comment.localizedStandardContains(keyword) {
            return ("备注", buildPreview(entry.comment, keyword: keyword))
        }
        if entry.content.localizedStandardContains(keyword) {
            return ("内容", buildPreview(entry.content, keyword: keyword))
        }
        if let hit = entry.keys.first(where: { $0.localizedStandardContains(keyword) }) {
            return ("关键词", hit)
        }
        if let hit = entry.secondaryKeys.first(where: { $0.localizedStandardContains(keyword) }) {
            return ("次关键词", hit)
        }
        if bookNameMatch {
            return ("书名", buildPreview(bookName, keyword: keyword))
        }
        return nil
    }

    private static func entryDisplayTitle(_ entry: WorldBookEntry) -> String {
        if !entry.comment.isEmpty { return entry.comment }
        if let first = entry.keys.first { return first }
        return String(entry.content.prefix(20))
    }

    // MARK: - File Library Search（文件名 + 开头 4 KB，和文件库面板的过滤同一口径；没有全文索引）

    static let filePreviewBytes = 4096

    /// keyword 为 nil = 不按词筛，只列最近改过的 12 个（mac ⌘K 无词时用）
    static func searchFiles(keyword: String?, profileId: String) async -> [FileSearchResult] {
        await Task.detached(priority: .userInitiated) {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("SearchService.searchFiles") : nil
            defer { if let airSpan { AirProbeSections.leave(airSpan) } }
            #endif
            var metas = FileLibraryStore.list(profileId: profileId)
            if keyword == nil {
                metas = Array(metas.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(12))
            }
            return metas.compactMap { meta -> FileSearchResult? in
                let url = URL(fileURLWithPath: meta.path)
                let body = FileLibraryStore.isBinaryPath(meta.path)
                    ? "" : ((try? FileLibraryStore.readPreview(meta.path, maxBytes: filePreviewBytes, profileId: profileId)) ?? "")
                if let keyword, !MacSearchQuery.contains(meta.path, keyword) && !MacSearchQuery.contains(body, keyword) { return nil }
                let dir = url.deletingLastPathComponent().relativePath
                return FileSearchResult(path: meta.path, name: url.lastPathComponent, folder: dir == "." ? "" : dir,
                                        body: body, modifiedAt: meta.modifiedAt, ext: url.pathExtension.lowercased())
            }
        }.value
    }

    /// 「文件」标签：在 searchFiles 上按全部词（路径 ∪ 开头 4KB）、扩展名、修改时间筛，按 filter.sortOrder 排；没有词返回空
    static func searchFiles(filter: SearchFilter, profileId: String) async -> [FileSearchResult] {
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let words = filter.words.isEmpty ? [keyword] : filter.words
        let interval = filter.dateRange.dateInterval
        let exts = filter.extensions
        let results = await searchFiles(keyword: keyword, profileId: profileId).filter { f in
            if !exts.isEmpty && !exts.contains(f.ext) { return false }
            if let interval, f.modifiedAt < interval.start || f.modifiedAt > interval.end { return false }
            return words.allSatisfy { MacSearchQuery.contains(f.path, $0) || MacSearchQuery.contains(f.body, $0) }
        }
        switch filter.sortOrder {
        case .relevance:
            return SearchRelevance.order(results) {
                SearchRelevance.Signals(literal: MacSearchQuery.score(title: $0.name, body: $0.body, words: words), updated: $0.modifiedAt)
            }
        case .recent: return results.sorted { $0.modifiedAt > $1.modifiedAt }
        case .oldest: return results.sorted { $0.modifiedAt < $1.modifiedAt }
        case .titleAZ: return results.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .titleZA: return results.sorted { $0.name.localizedCompare($1.name) == .orderedDescending }
        }
    }

    // MARK: - Memory Search

    /// 搜索记忆（Memory），按 profileId 楼层隔离。MemoryNote 目前无 UI 展示，暂不搜。
    static func searchMemories(
        keyword: String,
        profileId: String,
        container: ModelContainer,
        filter: SearchFilter
    ) async -> [MemorySearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !kw.isEmpty else { continuation.resume(returning: []); return }
                let interval = filter.dateRange.dateInterval

                let context = ModelContext(container)
                context.autosaveEnabled = false
                let pid = profileId
                let search = kw

                let desc = FetchDescriptor<Memory>(
                    predicate: #Predicate<Memory> { mem in
                        mem.profileId == pid && mem.content.localizedStandardContains(search)
                    }
                )
                var memories = (try? context.fetch(desc)) ?? []

                // keywords 数组 predicate 不好写，内存二次过滤（只补漏，content 已 match 的跳过）
                // 这里先只按 content 匹。若 keywords 需要，再加一个 fetch 所有 memories + filter。
                // 保守：先把 keywords 匹的也加入 — 需要取所有 profile 下 memory，量不大
                let allDesc = FetchDescriptor<Memory>(
                    predicate: #Predicate<Memory> { mem in mem.profileId == pid }
                )
                let all = (try? context.fetch(allDesc)) ?? []
                let existing = Set(memories.map { $0.id })
                for mem in all where !existing.contains(mem.id) {
                    if mem.keywords.contains(where: { $0.localizedStandardContains(search) }) {
                        memories.append(mem)
                    }
                }

                // 时间过滤
                if let interval = interval {
                    memories = memories.filter { $0.createdAt >= interval.start && $0.createdAt <= interval.end }
                }

                var results = memories.map { mem -> MemorySearchResult in
                    let previewSource = mem.content.localizedStandardContains(kw) ? mem.content : mem.keywords.joined(separator: " ")
                    return MemorySearchResult(
                        id: mem.id.uuidString,
                        memoryId: mem.id,
                        category: mem.category,
                        preview: buildPreview(previewSource, keyword: kw),
                        createdAt: mem.createdAt,
                        keyword: kw
                    )
                }

                switch filter.sortOrder {
                case .relevance:
                    let words = filter.words.isEmpty ? [kw] : filter.words
                    results = SearchRelevance.order(results) {
                        SearchRelevance.Signals(literal: MacSearchQuery.score(title: "", body: $0.preview, words: words), updated: $0.createdAt)
                    }
                case .recent: results.sort { $0.createdAt > $1.createdAt }
                case .oldest: results.sort { $0.createdAt < $1.createdAt }
                case .titleAZ: results.sort { $0.preview.localizedCompare($1.preview) == .orderedAscending }
                case .titleZA: results.sort { $0.preview.localizedCompare($1.preview) == .orderedDescending }
                }
                continuation.resume(returning: results)
            }
        }
    }
}

// MARK: - 相关度打分（plan-search-s1-s2 S2-7）

enum SearchRelevance {
    /// 全部权重集中在这里：总分 = 字面·literal + 新近·recency + 在乎·care
    enum Weight {
        static let literal = 0.6
        static let recency = 0.25
        static let care = 0.15
        /// 新近 = e^(-decayPerDay · 天)
        static let decayPerDay = 0.02
        static let starred = 0.3
        static let pinned = 0.25
        static let highlighted = 0.2
        /// 「最后打开时间」按新近同一条曲线衰减（还没有打开次数字段，决策 Q-a）
        static let recentlyOpened = 0.15
        static let messageCount = 0.1
    }

    /// 缺值记 0
    struct Signals {
        var literal: Int
        var updated: Date?
        var starred = false
        var pinned = false
        var highlighted = false
        var lastOpened: Date? = nil
        var messageCount = 0
    }

    static func recency(_ date: Date?, now: Date) -> Double {
        guard let date else { return 0 }
        return exp(-Weight.decayPerDay * max(0, now.timeIntervalSince(date) / 86_400))
    }

    /// 字面分按这批里的最高分归一，最高分为 0 时字面项整体记 0（不除）；消息条数按这批里的最多条数 log 归一
    static func scores(_ items: [Signals], now: Date = Date()) -> [Double] {
        let maxLiteral = items.map(\.literal).max() ?? 0
        let maxCount = items.map(\.messageCount).max() ?? 0
        return items.map { s in
            let literal = maxLiteral > 0 ? Double(s.literal) / Double(maxLiteral) : 0
            let count = maxCount > 0 ? log(1 + Double(s.messageCount)) / log(1 + Double(maxCount)) : 0
            let care = (s.starred ? Weight.starred : 0) + (s.pinned ? Weight.pinned : 0) + (s.highlighted ? Weight.highlighted : 0)
                + Weight.recentlyOpened * recency(s.lastOpened, now: now) + Weight.messageCount * count
            return Weight.literal * literal + Weight.recency * recency(s.updated, now: now) + Weight.care * care
        }
    }

    /// 总分降序；同分按更新时间倒序；再相同按原来的先后（排序稳定）
    static func order<T>(_ items: [T], now: Date = Date(), signals: (T) -> Signals) -> [T] {
        let all = items.map(signals)
        let score = scores(all, now: now)
        return items.indices.sorted { a, b in
            if score[a] != score[b] { return score[a] > score[b] }
            let ua = all[a].updated ?? .distantPast
            let ub = all[b].updated ?? .distantPast
            if ua != ub { return ua > ub }
            return a < b
        }.map { items[$0] }
    }
}

// MARK: - Resource Search Result Structs

struct CharacterCardSearchResult: Identifiable {
    let id: String
    let cardId: String
    let cardName: String
    let imageData: Data?
    let createdAt: Date
    let matchedField: String
    let preview: String
    let keyword: String
}

struct WorldBookEntrySearchResult: Identifiable {
    let id: String
    let isGlobal: Bool
    let bookId: String         // global UUID string 或 floor UUID string
    let bookName: String
    let entryId: UUID
    let entryTitle: String
    let createdAt: Date
    let matchedField: String
    let preview: String
    let keyword: String
}

struct FileSearchResult: Identifiable {
    let path: String
    let name: String
    /// 所在子目录；空 = 文件库根目录
    let folder: String
    let body: String
    let modifiedAt: Date
    let ext: String
    var id: String { path }
}

struct MemorySearchResult: Identifiable {
    let id: String
    let memoryId: UUID
    let category: String
    let preview: String
    let createdAt: Date
    let keyword: String
}

// MARK: - Sticker Search Result

struct StickerSearchResult: Identifiable {
    let id: UUID
    let assetName: String
    let isNote: Bool
    let thumbnailPath: String?
    let noteContent: String?
    let noteStyle: String?
    let conversationId: String
    let conversationTitle: String
    let nearestMessageId: String?
    let profileId: String

    init(placedStickerId: UUID, assetName: String, isNote: Bool, thumbnailPath: String?,
         noteContent: String?, noteStyle: String?, conversationId: String,
         conversationTitle: String, nearestMessageId: String?, profileId: String) {
        self.id = placedStickerId
        self.assetName = assetName
        self.isNote = isNote
        self.thumbnailPath = thumbnailPath
        self.noteContent = noteContent
        self.noteStyle = noteStyle
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.nearestMessageId = nearestMessageId
        self.profileId = profileId
    }
}

// MARK: - iOS 搜索框的 mac Query 映射（plan-search-s1-s2 S2-5）

extension SearchResourceKind {
    /// iOS 有对应标签的 mac 类型；便笺 / 编程会话返回 nil
    init?(macKind: MacSearchKind) {
        switch macKind {
        case .chat: self = .conversation
        case .branch: self = .branchContent
        case .sticker: self = .sticker
        case .assistant: self = .characterCard
        case .worldbook: self = .worldBook
        case .memory: self = .memory
        case .file: self = .file
        case .health: self = .health
        case .library: self = .library
        case .twitter: self = .twitter
        case .note, .coding: return nil
        }
    }

    var macKind: MacSearchKind {
        switch self {
        case .conversation: .chat
        case .branchContent: .branch
        case .sticker: .sticker
        case .characterCard: .assistant
        case .worldBook: .worldbook
        case .memory: .memory
        case .file: .file
        case .health: .health
        case .library: .library
        case .twitter: .twitter
        }
    }
}

/// 框里的文字 ⇄ iOS 搜索状态（标签 / 胶囊 / 筛选 sheet 共用一份）。回车时 parse，状态变了用 text 回写框里
enum SearchQueryMapping {
    struct State: Equatable {
        var words: [String] = []
        /// 搜哪几类。nil = 框里没写 type:（沿用本机记住的选择）；写回时全选不写 type:
        var kinds: Set<SearchResourceKind>? = nil
        var scope: SearchScope = .both
        var roles: Set<String> = ["user", "assistant"]
        var dateRange: DateRange = .all
        var sort: SearchSort = .relevance
        var starredOnly = false
        var extensions: [String] = []
    }

    /// errors 非空时 state 不可信，不要落地
    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> (state: State, errors: [String]) {
        let parsed = MacSearchQuery.parse(raw)
        var errors = parsed.errors
        let f = parsed.filters
        var s = State()
        s.words = parsed.words
        // `type:all` 和不写 type: 在 mac 那边都是空数组，这里要分开：写了 all = 恢复全选，没写 = 沿用
        let typeWritten = MacSearchQuery.lex(raw).tokens.contains { !$0.quoted && $0.value.lowercased().hasPrefix("type:") }
        if typeWritten {
            var kinds = Set<SearchResourceKind>()
            for t in f.types {
                if let kind = SearchResourceKind(macKind: t) { kinds.insert(kind) } else { errors.append("type:\(t.rawValue) 无效；iOS 暂不支持\(t.label)。") }
            }
            s.kinds = f.types.isEmpty ? allKinds : kinds
        }
        if f.location != .all {
            errors.append("in:\(f.location.rawValue) 无效；iOS 暂不支持，请用筛选里的「所在文件夹」。")
        }
        if !f.extensions.isEmpty && s.kinds?.contains(.file) ?? true {
            s.extensions = f.extensions
        } else if !f.extensions.isEmpty {
            errors.append("ext:\(f.extensions.joined(separator: ",")) 无效；只在「文件」标签生效。")
        }
        switch f.match {
        case .any: s.scope = .both
        case .title: s.scope = .titleOnly
        case .content: s.scope = .contentOnly
        }
        switch f.author {
        case .all: s.roles = ["user", "assistant"]
        case .me: s.roles = ["user"]
        case .assistant: s.roles = ["assistant"]
        }
        switch f.period {
        case "all": s.dateRange = .all
        case "today": s.dateRange = .today
        case "7d": s.dateRange = .last7Days
        case "30d": s.dateRange = .last30Days
        case "90d": s.dateRange = .last90Days
        case "custom":
            s.dateRange = .custom(start: MacSearchQuery.calendarDate(f.after, calendar: calendar) ?? .distantPast,
                                  end: MacSearchQuery.calendarDate(f.before, calendar: calendar) ?? .distantFuture)
        default:
            if let b = f.dateBounds(now: now, calendar: calendar) { s.dateRange = .custom(start: b.lowerBound, end: b.upperBound) }
        }
        switch f.sort {
        case .relevance: s.sort = .relevance
        case .recent: s.sort = .recent
        case .oldest: s.sort = .oldest
        case .az: s.sort = .titleAZ
        case .za: s.sort = .titleZA
        }
        s.starredOnly = f.starred
        return (s, errors)
    }

    /// 普通词原样保留，条件按 mac `serialize` 重新拼；全选不写 type:，否则按固定顺序写，保证写出去再读回来一模一样
    static func text(for s: State, calendar: Calendar = .current) -> String {
        var f = MacSearchFilters()
        if let kinds = s.kinds, kinds != allKinds { f.types = ordered(kinds).map(\.macKind) }
        switch s.scope {
        case .both: f.match = .any
        case .titleOnly: f.match = .title
        case .contentOnly: f.match = .content
        }
        if s.roles == ["user"] { f.author = .me } else if s.roles == ["assistant"] { f.author = .assistant }
        switch s.dateRange {
        case .all: break
        case .today: f.period = "today"
        case .last7Days: f.period = "7d"
        case .last30Days: f.period = "30d"
        case .last90Days: f.period = "90d"
        case .custom(let start, let end):
            f.period = "custom"
            if start != .distantPast { f.after = MacSearchQuery.dayString(start, calendar: calendar) }
            if end != .distantFuture { f.before = MacSearchQuery.dayString(end, calendar: calendar) }
        }
        switch s.sort {
        case .relevance: f.sort = .relevance
        case .recent: f.sort = .recent
        case .oldest: f.sort = .oldest
        case .titleAZ: f.sort = .az
        case .titleZA: f.sort = .za
        }
        f.starred = s.starredOnly
        if s.kinds?.contains(.file) ?? true { f.extensions = s.extensions }
        return MacSearchQuery.serialize(words: s.words, filters: f)
    }

    // MARK: 类型选择（S3-6）：「选中的类型」集合（搜哪些）和「当前标签」（看哪个）分开

    static let allKinds = Set(SearchResourceKind.allCases)

    /// 固定顺序（标签的默认顺序、type: 的写法顺序）
    static func ordered(_ kinds: Set<SearchResourceKind>) -> [SearchResourceKind] {
        SearchResourceKind.allCases.filter(kinds.contains)
    }

    /// 当前标签：还在集合里就不动，否则换成集合里排第一的
    static func currentKind(_ preferred: SearchResourceKind, in kinds: Set<SearchResourceKind>) -> SearchResourceKind {
        kinds.contains(preferred) ? preferred : (ordered(kinds).first ?? .conversation)
    }

    /// 点一下类型胶囊：在集合里就取消（只剩它一个时不响应），不在就加上；取消的正好是当前标签 → 换第一个
    static func toggle(_ kind: SearchResourceKind, selected: Set<SearchResourceKind>,
                       current: SearchResourceKind) -> (selected: Set<SearchResourceKind>, current: SearchResourceKind) {
        var next = selected
        if next.contains(kind) {
            guard next.count > 1 else { return (selected, current) }
            next.remove(kind)
        } else {
            next.insert(kind)
        }
        return (next, currentKind(current, in: next))
    }

    /// 本机存的是 rawValue 小数组；认不出的丢掉，空了就是全选
    static func kinds(fromStored raw: [String]?) -> Set<SearchResourceKind> {
        let kinds = Set((raw ?? []).compactMap(SearchResourceKind.init(rawValue:)))
        return kinds.isEmpty ? allKinds : kinds
    }

    static func stored(_ kinds: Set<SearchResourceKind>) -> [String] {
        ordered(kinds).map(\.rawValue)
    }
}
