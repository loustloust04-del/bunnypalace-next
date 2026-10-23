import Foundation
import SwiftData

/// S3 新增的四类资料（交易 / 健康 / 书房 / 推特）共用的一行结果：点开 = 设 `RightPanelNavigator.pendingTarget(tool, target)`
struct ResourceHit: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let tag: String
    let preview: String
    let date: Date
    let tool: String
    let target: String
}

/// 推特标签的翻页游标：上一页最后一条的时间 + id（同一秒的推文靠 id 分先后）
struct TweetSearchCursor: Equatable {
    let date: Date
    let tweetId: String
}

extension SearchResourceKind {
    /// 结果是 ResourceHit 的几类（S3）
    static let resourceHitKinds: Set<SearchResourceKind> = [.health, .library, .twitter]
    var usesResourceHits: Bool { Self.resourceHitKinds.contains(self) }
}

extension SearchService {

    static let tweetPageSize = 100

    /// 后台跑；外面的搜索任务被取消时一并取消（Task.detached 自己不继承取消）
    private static func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// 这次搜索的全部普通词；没有多词时退回 keyword
    static func searchWords(_ filter: SearchFilter) -> [String] {
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.words.isEmpty { return filter.words }
        return keyword.isEmpty ? [] : [keyword]
    }

    /// 每个词都要在某个字段里出现；返回第一个含词的字段（名字 + 原文），给结果行当标签和片段
    private static func firstHit(_ fields: [(String, String)], words: [String]) -> (field: String, text: String)? {
        let all = fields.map(\.1).joined(separator: "\n")
        guard words.allSatisfy({ MacSearchQuery.contains(all, $0) }) else { return nil }
        let hit = fields.first { f in words.contains { MacSearchQuery.contains(f.1, $0) } }
        return hit.map { ($0.0, $0.1) }
    }

    private static func ordered(_ hits: [ResourceHit], filter: SearchFilter, words: [String]) -> [ResourceHit] {
        var hits = hits
        if let interval = filter.dateRange.dateInterval {
            hits = hits.filter { $0.date >= interval.start && $0.date <= interval.end }
        }
        switch filter.sortOrder {
        case .relevance:
            return SearchRelevance.order(hits) {
                SearchRelevance.Signals(literal: MacSearchQuery.score(title: $0.title, body: $0.preview, words: words), updated: $0.date)
            }
        case .recent: return hits.sorted { $0.date > $1.date }
        case .oldest: return hits.sorted { $0.date < $1.date }
        case .titleAZ: return hits.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .titleZA: return hits.sorted { $0.title.localizedCompare($1.title) == .orderedDescending }
        }
    }


    // MARK: - 健康（四类备注 + 药名 / 剂量；归档的药不搜；亲密记录由调用方按开关决定带不带）

    static let intimacyHitPrefix = "intimacy:"

    static func searchHealth(filter: SearchFilter, profileId: String, includeIntimacy: Bool,
                             container: ModelContainer) async -> [ResourceHit] {
        let words = searchWords(filter)
        guard !words.isEmpty else { return [] }
        return await detached {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let pid = profileId
            var hits: [ResourceHit] = []
            func add(_ category: String, id: UUID, symbol: String, title: String, tag: String,
                     fields: [(String, String)], date: Date) {
                guard let hit = firstHit(fields, words: words) else { return }
                hits.append(ResourceHit(
                    id: "\(category):\(id.uuidString)", symbol: symbol, title: title, tag: "\(tag) · \(hit.field)",
                    preview: MacSearchQuery.excerpt(hit.text, words: words), date: date,
                    tool: "health", target: "\(category):\(id.uuidString)"))
            }
            let meds = (try? context.fetch(FetchDescriptor<Medication>(predicate: #Predicate { $0.profileId == pid && !$0.isArchived }))) ?? []
            for m in meds {
                add("meds", id: m.id, symbol: "pills", title: m.name, tag: "用药",
                    fields: [("药名", m.name), ("剂量", m.dosage), ("备注", m.note)], date: m.createdAt)
            }
            let weights = (try? context.fetch(FetchDescriptor<WeightEntry>(predicate: #Predicate { $0.profileId == pid && $0.note != "" }))) ?? []
            for w in weights {
                add("weight", id: w.id, symbol: "scalemass", title: "体重", tag: "体重", fields: [("备注", w.note)], date: w.date)
            }
            let cycles = (try? context.fetch(FetchDescriptor<CycleDay>(predicate: #Predicate { $0.profileId == pid && $0.note != "" }))) ?? []
            for c in cycles {
                add("cycle", id: c.id, symbol: "drop", title: "经期", tag: "经期", fields: [("备注", c.note)], date: c.date)
            }
            if includeIntimacy {
                let days = (try? context.fetch(FetchDescriptor<IntimacyEntry>(predicate: #Predicate { $0.profileId == pid && $0.note != "" }))) ?? []
                for d in days {
                    add("intimacy", id: d.id, symbol: "heart", title: "亲密", tag: "亲密", fields: [("备注", d.note)], date: d.date)
                }
            }
            return ordered(hits, filter: filter, words: words)
        }
    }

    // MARK: - 书房（纸书书名 / 作者 / 批注 / 书签 + 有声书标题 / 书签备注）

    /// 纸书的批注和书签是每本书一个 JSON，逐本读，本与本之间看取消。取书时只取索引字段，不碰外置存储的封面
    static func searchLibrary(filter: SearchFilter, profileId: String, container: ModelContainer) async -> [ResourceHit] {
        let words = searchWords(filter)
        guard !words.isEmpty else { return [] }
        return await detached {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let pid = profileId
            var hits: [ResourceHit] = []
            var bookDesc = FetchDescriptor<BookEntry>(predicate: #Predicate { $0.profileId == pid })
            bookDesc.propertiesToFetch = [\.id, \.name, \.author, \.addedAt, \.lastReadAt, \.profileId]
            let books = (try? context.fetch(bookDesc)) ?? []
            for b in books {
                if Task.isCancelled { return [] }
                let bookDate = b.lastReadAt ?? b.addedAt
                if let hit = firstHit([("书名", b.name), ("作者", b.author)], words: words) {
                    hits.append(ResourceHit(id: "book:\(b.id)", symbol: "book.closed", title: b.name, tag: "纸书 · \(hit.field)",
                                            preview: hit.field == "书名" ? b.author : hit.text, date: bookDate,
                                            tool: "reading", target: b.id))
                }
                for n in BookStore.loadNotes(safeName: b.id, profileId: pid) {
                    guard let hit = firstHit([("批注", n.content), ("原文", n.anchorText)], words: words) else { continue }
                    hits.append(ResourceHit(id: "note:\(b.id):\(n.id)", symbol: "text.quote", title: b.name, tag: "批注 · \(hit.field)",
                                            preview: MacSearchQuery.excerpt(hit.text, words: words), date: n.createdAt,
                                            tool: "reading", target: b.id))
                }
                for m in BookStore.loadBookmarks(safeName: b.id, profileId: pid) {
                    guard let hit = firstHit([("书签", m.title)], words: words) else { continue }
                    hits.append(ResourceHit(id: "bookmark:\(b.id):\(m.id)", symbol: "bookmark", title: b.name, tag: "书签",
                                            preview: hit.text, date: m.createdAt, tool: "reading", target: b.id))
                }
            }
            return ordered(hits, filter: filter, words: words)
        }
    }

    // MARK: - 推特（只按时间倒序；「时间 + id」游标翻页；数用 fetchCount）

    private static func tweetBounds(_ filter: SearchFilter) -> (Date, Date) {
        let interval = filter.dateRange.dateInterval
        return (interval?.start ?? .distantPast, interval?.end ?? .distantFuture)
    }

    static func searchTweets(filter: SearchFilter, profileId: String, after cursor: TweetSearchCursor?,
                             container: ModelContainer) async -> (hits: [ResourceHit], next: TweetSearchCursor?) {
        let words = searchWords(filter)
        guard !words.isEmpty else { return ([], nil) }
        let (lo, hi) = tweetBounds(filter)
        return await detached {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let desc = TwitterQueries.searchPage(profileId: profileId, words: words, from: lo, to: hi,
                                                 after: cursor, limit: tweetPageSize)
            let rows = (try? context.fetch(desc)) ?? []
            let next = rows.count == tweetPageSize ? rows.last.map { TweetSearchCursor(date: $0.createdAt, tweetId: $0.tweetId) } : nil
            let hits = rows.map { t -> ResourceHit in
                let author = t.authorName ?? t.authorScreenName.map { "@\($0)" } ?? t.retweetedName ?? "推文"
                return ResourceHit(id: "tweet:\(t.tweetId)", symbol: "bird", title: author, tag: "推特",
                                   preview: MacSearchQuery.excerpt(t.text, words: words), date: t.createdAt,
                                   tool: "twitter", target: t.tweetId)
            }
            return (hits, next)
        }
    }

    static func countTweets(filter: SearchFilter, profileId: String, container: ModelContainer) async -> Int {
        let words = searchWords(filter)
        guard !words.isEmpty else { return 0 }
        let (lo, hi) = tweetBounds(filter)
        return await detached {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return (try? context.fetchCount(TwitterQueries.searchCount(profileId: profileId, words: words, from: lo, to: hi))) ?? 0
        }
    }
}
