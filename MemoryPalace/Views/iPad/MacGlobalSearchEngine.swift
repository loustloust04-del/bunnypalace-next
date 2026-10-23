import Foundation
import SwiftData

#if os(macOS)
/// 一条全局搜索结果（原型 `buildSearchIndex()` 的一行）。
struct MacSearchRecord: Identifiable {
    enum Route {
        /// 对话 / 分支 / 贴纸：打开对话，有 nodeId 就走 `navigateToSearchResult`（切分支 + 滚动 + 闪烁）
        case conversation(id: String, nodeId: String?)
        /// 右栏工具：`RightPanelNavigator.pendingTarget`
        case rightPanel(tool: String, id: String)
        /// 编程会话：`CodingSessionLibrary.open(hit)`
        case coding(CodingSessionIndex.SearchHit)
    }

    let id: String
    let kind: MacSearchKind
    let title: String
    /// 原型的 `project`：楼层名 / 书名 / 所在对话 / 目录 / 项目名
    let sub: String
    /// 用来判命中和截片段的正文
    let body: String
    let updated: Date?
    var ext: String = ""
    var starred = false
    /// 全局资源（不属于任何楼层）：助手模板、全局世界书、编程会话。`in:workspace` 时排除
    var isGlobal = false
    /// 这条正文是谁写的；nil = 没有角色信息（`by:` 生效时排除）
    var author: MacSearchFilters.Author? = nil
    /// 引擎自己已经按「每个词都命中」筛过（编程会话 FTS），片段不一定含全部词，不再用正文复核
    var preMatched = false
    let route: Route
    var score = 0
}

/// 把现有各路搜索（SearchService / 文件库 preview / CodingSessionIndex）接成原型那一张结果表。
/// 不新建索引、不碰数据库结构：关键词先交给现成引擎取候选（取最长的那个词，最能收窄），
/// 再按原型口径在 Swift 这边做「每个词都要命中」、筛选、打分、排序。
enum MacGlobalSearchEngine {
    struct Snapshot {
        let profileId: String
        let profileName: String
        let currentConversationId: String?
        let cards: [CardSnapshot]
        let globalBooks: [GlobalWorldBook]
        let codingEnabled: Bool
    }

    struct CardSnapshot: Sendable {
        let id: String
        let name: String
        let createdAt: Date
        let text: String
    }

    static let resultLimit = 120

    static func availableKinds(codingEnabled: Bool) -> [MacSearchKind] {
        MacSearchKind.allCases.filter { $0 != .coding || codingEnabled }
    }

    @MainActor
    static func search(words: [String], filters f: MacSearchFilters, snapshot s: Snapshot,
                       container: ModelContainer) async -> [MacSearchRecord] {
        let kinds = (f.types.isEmpty ? availableKinds(codingEnabled: s.codingEnabled) : f.types)
            .filter { $0.isSupported && ($0 != .coding || s.codingEnabled) }
        guard !kinds.isEmpty else { return [] }
        let bounds = f.dateBounds()
        let keyword = words.max { $0.count < $1.count } ?? ""
        let pid = s.profileId
        let currentConv = f.location == .current ? s.currentConversationId : nil
        if f.location == .current && currentConv == nil { return [] }

        var records: [MacSearchRecord] = []
        let favorites = await favoriteConversationIds(profileId: pid, container: container)

        if keyword.isEmpty {
            // 原型：没有关键词时列「最近更新」
            if kinds.contains(.chat) {
                records += await recentConversations(profileId: pid, container: container, only: currentConv, favorites: favorites)
            }
            if f.location != .current {
                if kinds.contains(.memory) { records += await recentMemories(profileId: pid, profileName: s.profileName, container: container) }
                if kinds.contains(.file) { records += await files(keyword: nil, profileId: pid) }
                if kinds.contains(.assistant) {
                    records += s.cards.sorted { $0.createdAt > $1.createdAt }.prefix(12).map(cardRecord)
                }
            }
        } else {
            async let chat: [MacSearchRecord] = kinds.contains(.chat)
                ? conversations(branch: false, keyword: keyword, words: words, filters: f, bounds: bounds,
                                profileId: pid, only: currentConv, favorites: favorites, container: container) : []
            async let branch: [MacSearchRecord] = kinds.contains(.branch)
                ? conversations(branch: true, keyword: keyword, words: words, filters: f, bounds: bounds,
                                profileId: pid, only: currentConv, favorites: favorites, container: container) : []
            async let sticker: [MacSearchRecord] = kinds.contains(.sticker)
                ? stickers(keyword: keyword, profileId: pid, only: currentConv, container: container) : []
            let wantsFloorResources = f.location != .current
            async let memory: [MacSearchRecord] = wantsFloorResources && kinds.contains(.memory)
                ? memories(keyword: keyword, profileId: pid, profileName: s.profileName, container: container) : []
            async let world: [MacSearchRecord] = wantsFloorResources && kinds.contains(.worldbook)
                ? worldBooks(keyword: keyword, snapshot: s, container: container) : []
            async let file: [MacSearchRecord] = wantsFloorResources && kinds.contains(.file)
                ? files(keyword: keyword, profileId: pid) : []
            var coding: [MacSearchRecord] = []
            if wantsFloorResources && kinds.contains(.coding) {
                coding = await codingSessions(words: words)
            }
            var cards: [MacSearchRecord] = []
            if wantsFloorResources && kinds.contains(.assistant) {
                cards = s.cards.filter { MacSearchQuery.contains($0.name + "\n" + $0.text, keyword) }.map(cardRecord)
            }
            var hits: [MacSearchRecord] = []
            if wantsFloorResources {
                #if PERSONAL_APPS
                for kind in [MacSearchKind.trading, .health, .library, .twitter] where kinds.contains(kind) {
                    hits += await resourceHits(kind, words: words, profileId: pid, container: container)
                }
                #else
                for kind in [MacSearchKind.health, .library, .twitter] where kinds.contains(kind) {
                    hits += await resourceHits(kind, words: words, profileId: pid, container: container)
                }
                #endif
            }
            records = await chat + branch + sticker + memory + world + file + coding + cards + hits
        }
        // 搜的途中健康面板的亲密卡被关掉：结果里也不能留亲密记录
        if !HealthLogStore.showIntimacyCard {
            records.removeAll { $0.kind == .health && $0.id.hasPrefix("health:\(SearchService.intimacyHitPrefix)") }
        }

        // 原型 runSearch 的逐行筛选
        var out: [MacSearchRecord] = []
        for var row in records {
            if f.location == .workspace && row.isGlobal { continue }
            if !f.extensions.isEmpty && !f.extensions.contains(row.ext) { continue }
            if f.starred && !row.starred { continue }
            if let bounds {
                guard let updated = row.updated, bounds.contains(updated) else { continue }
            }
            if f.author != .all && row.author != f.author { continue }
            if !(row.preMatched && f.match != .title) {
                guard MacSearchQuery.matches(title: row.title, body: row.body, words: words, match: f.match) else { continue }
            }
            row.score = MacSearchQuery.score(title: row.title, body: row.body, words: words)
            out.append(row)
        }
        let ordered = MacSearchQuery.order(out, sort: f.sort, hasWords: !words.isEmpty,
                                           id: \.id, title: \.title, updated: \.updated, score: \.score)
        return Array(ordered.prefix(resultLimit))
    }

    // MARK: - 对话 / 分支（SearchService.performSearch）

    private static func conversations(branch: Bool, keyword: String, words: [String], filters f: MacSearchFilters,
                                      bounds: ClosedRange<Date>?, profileId: String, only: String?,
                                      favorites: Set<String>, container: ModelContainer) async -> [MacSearchRecord] {
        var filter = SearchFilter()
        filter.keyword = keyword
        filter.resourceKind = branch ? .branchContent : .conversation
        filter.scope = branch ? .contentOnly : (f.match == .title ? .titleOnly : f.match == .content ? .contentOnly : .both)
        switch f.author {
        case .all: filter.roles = ["user", "assistant"]
        case .me: filter.roles = ["user"]
        case .assistant: filter.roles = ["assistant"]
        }
        if let bounds { filter.dateRange = .custom(start: bounds.lowerBound, end: bounds.upperBound) }
        if let only { filter.conversationIdScope = [only] }
        let results = await SearchService.performSearch(filter: filter, profileId: profileId, container: container)
        let nodes = results.flatMap(\.matchedNodes)
        let contents = await nodeContents(ids: nodes.map(\.id), container: container)

        var byConv: [String: (title: String, time: Date, titleHit: Bool, nodes: [MatchedNode])] = [:]
        var order: [String] = []
        for r in results {
            if byConv[r.convId] == nil { order.append(r.convId); byConv[r.convId] = (r.convTitle, r.convTime, false, []) }
            if r.isTitleMatch { byConv[r.convId]?.titleHit = true }
            byConv[r.convId]?.nodes += r.matchedNodes
        }
        let kind: MacSearchKind = branch ? .branch : .chat
        var out: [MacSearchRecord] = []
        for convId in order {
            guard let entry = byConv[convId] else { continue }
            // 选第一条让「每个词都命中」成立的消息作这一行的落点；没有就退回标题行
            let node = entry.nodes
                .sorted { ($0.createTime ?? .distantPast) > ($1.createTime ?? .distantPast) }
                .first { MacSearchQuery.matches(title: entry.title, body: contents[$0.id] ?? $0.preview, words: words, match: f.match) }
            if let node {
                out.append(MacSearchRecord(
                    id: "\(kind.rawValue):\(convId)", kind: kind, title: entry.title,
                    sub: branch ? "分支" : "对话", body: contents[node.id] ?? node.preview,
                    updated: entry.time, starred: favorites.contains(convId),
                    author: node.role == "user" ? .me : .assistant,
                    route: .conversation(id: convId, nodeId: node.id)))
            } else if entry.titleHit {
                out.append(MacSearchRecord(
                    id: "\(kind.rawValue):\(convId)", kind: kind, title: entry.title, sub: "对话", body: "",
                    updated: entry.time, starred: favorites.contains(convId),
                    author: f.author == .all ? nil : f.author,
                    route: .conversation(id: convId, nodeId: nil)))
            }
        }
        return out
    }

    /// 命中消息的全文（清洗后）：多词 AND 与片段都要看全文，SearchService 的 preview 只有 80 字
    private static func nodeContents(ids: [String], container: ModelContainer) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            var out: [String: String] = [:]
            let unique = Array(Set(ids))
            for start in stride(from: 0, to: unique.count, by: 200) {
                let chunk = Array(unique[start..<min(start + 200, unique.count)])
                let desc = FetchDescriptor<MessageNode>(predicate: #Predicate { chunk.contains($0.id) })
                for node in (try? context.fetch(desc)) ?? [] {
                    out[node.id] = ContentCleaner.clean(node.content, cacheKey: node.id)
                }
            }
            return out
        }.value
    }

    private static func favoriteConversationIds(profileId: String, container: ModelContainer) async -> Set<String> {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let pid = profileId
            let desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == pid && $0.isFavorite && !$0.isTrashed })
            return Set(((try? context.fetch(desc)) ?? []).map(\.id))
        }.value
    }

    private static func recentConversations(profileId: String, container: ModelContainer, only: String?,
                                            favorites: Set<String>) async -> [MacSearchRecord] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let pid = profileId
            var desc = FetchDescriptor<Conversation>(
                predicate: #Predicate { $0.profileId == pid && !$0.isTrashed },
                sortBy: [SortDescriptor(\.updateTime, order: .reverse)])
            desc.fetchLimit = 60
            return ((try? context.fetch(desc)) ?? [])
                .filter { only == nil || $0.id == only }
                .map { conv in
                    MacSearchRecord(id: "chat:\(conv.id)", kind: .chat, title: conv.title.isEmpty ? "新对话" : conv.title,
                                    sub: "对话", body: "", updated: conv.updateTime, starred: favorites.contains(conv.id),
                                    route: .conversation(id: conv.id, nodeId: nil))
                }
        }.value
    }

    // MARK: - 贴纸 / 记忆 / 世界书 / 助手模板

    private static func stickers(keyword: String, profileId: String, only: String?, container: ModelContainer) async -> [MacSearchRecord] {
        await SearchService.searchPlacedStickers(keyword: keyword, profileId: profileId, container: container)
            .filter { only == nil || $0.conversationId == only }
            .map { r in
                MacSearchRecord(
                    id: "sticker:\(r.id.uuidString)", kind: .sticker,
                    title: r.assetName.isEmpty ? (r.isNote ? "便签" : "贴纸") : r.assetName,
                    sub: r.conversationTitle.isEmpty ? "对话" : r.conversationTitle,
                    body: r.noteContent ?? "", updated: nil,
                    route: .conversation(id: r.conversationId, nodeId: r.nearestMessageId))
            }
    }

    private static let memoryCategories = [
        "preference": "偏好", "fact": "事实", "relationship": "关系", "goal": "目标", "context": "背景",
    ]

    private static func memoryRecord(id: UUID, content: String, category: String, updated: Date, profileName: String) -> MacSearchRecord {
        let line = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
        let title = line.count > 28 ? String(line.prefix(28)) + "…" : line
        return MacSearchRecord(
            id: "memory:\(id.uuidString)", kind: .memory, title: title.isEmpty ? "记忆" : title,
            sub: "\(profileName) · \(memoryCategories[category] ?? category)", body: content, updated: updated,
            route: .rightPanel(tool: "memory", id: id.uuidString))
    }

    private static func memories(keyword: String, profileId: String, profileName: String,
                                 container: ModelContainer) async -> [MacSearchRecord] {
        let hits = await SearchService.searchMemories(keyword: keyword, profileId: profileId, container: container, filter: SearchFilter())
        let ids = hits.map(\.memoryId)
        guard !ids.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let desc = FetchDescriptor<Memory>(predicate: #Predicate { ids.contains($0.id) })
            return ((try? context.fetch(desc)) ?? []).map {
                memoryRecord(id: $0.id, content: $0.content + ($0.keywords.isEmpty ? "" : "\n" + $0.keywords.joined(separator: " ")),
                             category: $0.category, updated: $0.updatedAt, profileName: profileName)
            }
        }.value
    }

    private static func recentMemories(profileId: String, profileName: String, container: ModelContainer) async -> [MacSearchRecord] {
        await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let pid = profileId
            var desc = FetchDescriptor<Memory>(predicate: #Predicate { $0.profileId == pid && $0.supersededAt == nil },
                                               sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            desc.fetchLimit = 12
            return ((try? context.fetch(desc)) ?? []).map {
                memoryRecord(id: $0.id, content: $0.content, category: $0.category, updated: $0.updatedAt, profileName: profileName)
            }
        }.value
    }

    private static func worldBooks(keyword: String, snapshot s: Snapshot, container: ModelContainer) async -> [MacSearchRecord] {
        await SearchService.searchWorldBookEntries(keyword: keyword, globalBooks: s.globalBooks, profileId: s.profileId,
                                                  container: container, filter: SearchFilter())
            .map { r in
                MacSearchRecord(
                    id: "worldbook:\(r.id)", kind: .worldbook, title: r.entryTitle.isEmpty ? r.bookName : r.entryTitle,
                    sub: r.isGlobal ? "全局 · \(r.bookName)" : r.bookName, body: r.preview, updated: r.createdAt,
                    isGlobal: r.isGlobal, route: .rightPanel(tool: "worldBook", id: r.id))
            }
    }

    private static func cardRecord(_ card: CardSnapshot) -> MacSearchRecord {
        MacSearchRecord(id: "assistant:\(card.id)", kind: .assistant, title: card.name.isEmpty ? "未命名助手" : card.name,
                        sub: "助手模板", body: card.text, updated: card.createdAt, isGlobal: true,
                        route: .rightPanel(tool: "cardLibrary", id: card.id))
    }

    @MainActor
    static func cardSnapshots(_ cards: [CharacterCard]) -> [CardSnapshot] {
        cards.map { c in
            let text = ([c.description, c.personality, c.scenario, c.firstMes, c.mesExample, c.systemPrompt,
                         c.postHistoryInstructions, c.creatorNotes] + c.alternateGreetings)
                .filter { !$0.isEmpty }.joined(separator: "\n")
            return CardSnapshot(id: c.id, name: c.name, createdAt: c.createdAt, text: text)
        }
    }

    // MARK: - 交易 / 健康 / 书房 / 推特（SearchService 的 ResourceHit，iOS 共用）

    /// 每条都已按「每个词都命中」筛过（片段只截了第一个命中的字段），不再用片段复核。
    /// 推特只取最新的一页（100 条）当候选：⌘K 整体只出 120 条，全库命中可能上万
    @MainActor
    private static func resourceHits(_ kind: MacSearchKind, words: [String], profileId: String,
                                     container: ModelContainer) async -> [MacSearchRecord] {
        var filter = SearchFilter()
        filter.keyword = words.max { $0.count < $1.count } ?? ""
        filter.words = words
        filter.sortOrder = .recent
        let hits: [ResourceHit]
        switch kind {
        #if PERSONAL_APPS
        case .trading: hits = await SearchService.searchTrading(filter: filter, profileId: profileId, container: container)
        #endif
        case .health:
            hits = await SearchService.searchHealth(filter: filter, profileId: profileId,
                                                    includeIntimacy: HealthLogStore.showIntimacyCard, container: container)
        case .library: hits = await SearchService.searchLibrary(filter: filter, profileId: profileId, container: container)
        case .twitter: hits = await SearchService.searchTweets(filter: filter, profileId: profileId, after: nil, container: container).hits
        default: hits = []
        }
        return hits.map { h in
            MacSearchRecord(id: "\(kind.rawValue):\(h.id)", kind: kind, title: h.title, sub: h.tag, body: h.preview,
                            updated: h.date, preMatched: true, route: .rightPanel(tool: h.tool, id: h.target))
        }
    }

    // MARK: - 文件库（SearchService.searchFiles，iOS 共用）

    private static func files(keyword: String?, profileId: String) async -> [MacSearchRecord] {
        await SearchService.searchFiles(keyword: keyword, profileId: profileId).map { f in
            MacSearchRecord(
                id: "file:\(f.path)", kind: .file, title: f.name,
                sub: f.folder.isEmpty ? "文件库" : "文件库 / \(f.folder)", body: f.body, updated: f.modifiedAt,
                ext: f.ext, route: .rightPanel(tool: "fileLibrary", id: f.path))
        }
    }

    // MARK: - 编程会话（CodingSessionIndex FTS5，同一会话只留第一条命中）

    @MainActor
    private static func codingSessions(words: [String]) async -> [MacSearchRecord] {
        let result = await CodingSessionLibrary.shared.search(words.joined(separator: " "))
        var seen = Set<String>()
        var out: [MacSearchRecord] = []
        for hit in result.hits where !seen.contains(hit.meta.key) {
            seen.insert(hit.meta.key)
            let snippet = hit.snippet.filter { $0 != CodingSessionIndex.highlightOpen && $0 != CodingSessionIndex.highlightClose }
            let ms = hit.timestamp ?? hit.meta.updatedAt
            out.append(MacSearchRecord(
                id: "coding:\(hit.meta.key)", kind: .coding, title: CodingSessionFormat.title(hit.meta),
                sub: hit.meta.projectName.isEmpty ? "编程会话" : hit.meta.projectName, body: snippet,
                updated: Date(timeIntervalSince1970: TimeInterval(ms) / 1000), isGlobal: true,
                author: hit.role == "user" ? .me : .assistant, preMatched: true, route: .coding(hit)))
        }
        return out
    }
}
#endif
