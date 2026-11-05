import Foundation

/// C 档案注入（plan-memory-c3-catalog 第六节）：根索引进稳定层；最近 4 条消息里逐字出现某页的标题 / 触发词，
/// 这页「钩子 + 现在」进动态层，一轮最多 3 页。组装路径只读 `WikiInjectionCache` 里的快照，读盘都在后台
struct WikiInjectionSnapshot: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        let path: String
        let title: String
        let triggers: [String]
        let hook: String
        let now: String
        /// 页上的 valid_until（「现在」该复核的日子）；旧页 nil
        var validUntil: String? = nil
    }

    var indexLines: [String] = []
    var pages: [Page] = []
    var stopWords: [String] = []
}

struct WikiPageHit: Equatable, Sendable {
    let page: WikiInjectionSnapshot.Page
    /// 命中它的那个词（常驻页显示「小慧（“慧慧”）」）
    let word: String
}

enum WikiInjection {
    static let windowSize = 4
    static let maxPages = 3
    static let indexTitle = "[C 档案 · 索引]"
    static let hitsTitle = "[C 档案 · 本轮相关]"

    // MARK: 读盘（后台）

    static func load(_ wiki: WikiStore) -> WikiInjectionSnapshot {
        MainThreadIO.assertOffMain(.enumerate, "WikiInjection.load")
        let index = (try? Data(contentsOf: wiki.folderURL("").appendingPathComponent(WikiStore.indexFileName)))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let pages = wiki.pagePaths().compactMap { path in
            wiki.read(path).map { WikiInjectionSnapshot.Page(path: path, title: $0.title, triggers: $0.triggers, hook: $0.hook, now: $0.now, validUntil: $0.validUntil) }
        }
        return WikiInjectionSnapshot(indexLines: indexLines(index), pages: pages, stopWords: wiki.stopWords())
    }

    /// 根 INDEX.md 里的条目行（「- 」开头）；文件头、两支的小标题、「待分组」标记都不要
    static func indexLines(_ markdown: String) -> [String] {
        markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
    }

    // MARK: 触发词

    /// 最近 4 条（含本轮刚发的）逐字找每页的标题 + 触发词（英文不分大小写）；名字和「不触发的词」不算。
    /// 排序：最近一条里先出现的在前、同一条里次数多的在前，再往前一条条比；最多 3 页
    static func hits(_ snapshot: WikiInjectionSnapshot, recent: [String], excluding names: [String]) -> [WikiPageHit] {
        let window = Array(recent.suffix(windowSize).reversed())
        guard !window.isEmpty, !snapshot.pages.isEmpty else { return [] }
        let blocked = Set((names + snapshot.stopWords).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        typealias Found = (pos: Int, count: Int, word: String)
        var scored: [(page: WikiInjectionSnapshot.Page, found: [Found?])] = []
        for page in snapshot.pages {
            var seen = Set<String>()
            let terms = ([page.title] + page.triggers)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !blocked.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
            guard !terms.isEmpty else { continue }
            let found = window.map { match(terms, in: $0) }
            if found.contains(where: { $0 != nil }) { scored.append((page, found)) }
        }
        scored.sort { a, b in
            for (x, y) in zip(a.found, b.found) {
                switch (x, y) {
                case let (x?, y?):
                    if x.pos != y.pos { return x.pos < y.pos }
                    if x.count != y.count { return x.count > y.count }
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): continue
                }
            }
            return a.page.path < b.page.path
        }
        return scored.prefix(maxPages).compactMap { s in
            s.found.lazy.compactMap { $0 }.first.map { WikiPageHit(page: s.page, word: $0.word) }
        }
    }

    /// 一条消息里：最早出现在第几个字、几个词一共出现几次、最早出现的是哪个词（同位置取长的）
    static func match(_ terms: [String], in text: String) -> (pos: Int, count: Int, word: String)? {
        var best: (pos: Int, word: String)?
        var count = 0
        for term in terms {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
                let pos = text.distance(from: text.startIndex, to: r.lowerBound)
                if best.map({ pos < $0.pos || (pos == $0.pos && term.count > $0.word.count) }) ?? true { best = (pos, term) }
                count += 1
                from = r.upperBound
            }
        }
        return best.map { ($0.pos, count, $0.word) }
    }

    // MARK: 文字

    static func indexBlock(_ snapshot: WikiInjectionSnapshot) -> String {
        snapshot.indexLines.isEmpty ? "" : indexTitle + "\n" + snapshot.indexLines.joined(separator: "\n")
    }

    /// 每页三行：标题、钩子、现在（不带「记录」）
    static func hitsBlock(_ hits: [WikiPageHit], now: Date) -> String {
        guard !hits.isEmpty else { return "" }
        return hitsTitle + "\n" + hits.map { hit in
            let p = hit.page
            var lines = ["[[\(p.path)]] \(p.title)"]
            if !p.hook.isEmpty { lines.append("钩子：\(p.hook)") }
            if !p.now.isEmpty { lines.append("现在：" + markExpired(p.now, now: now)) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static let untilPattern = try! NSRegularExpression(pattern: #"([（(]到\s*)(\d{4}-\d{2}(?:-\d{2})?)(\s*[）)])"#)

    /// 「（到 2026-10-22）」那天已过 →「（到 2026-10-22，已过期）」；只写到月的过了那个月才算。按记忆日（05:00 分界）算今天
    static func markExpired(_ text: String, now: Date, calendar: Calendar = .current) -> String {
        let today = MemoryDay.key(now, calendar: calendar)
        let ns = text as NSString
        var out = text
        for m in untilPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let day = ns.substring(with: m.range(at: 2))
            guard day.count == 10 ? day < today : day < String(today.prefix(7)) else { continue }
            let replaced = ns.substring(with: m.range(at: 1)) + day + "，已过期" + ns.substring(with: m.range(at: 3))
            out = (out as NSString).replacingCharacters(in: m.range, with: replaced)
        }
        return out
    }

    /// 碎片过了有效期：`validUntil` 是到期那天的记忆日结束（次日 05:00），它所在的记忆日早于今天
    static func isExpired(_ m: Memory, now: Date, calendar: Calendar = .current) -> Bool {
        guard let until = m.validUntil else { return false }
        return MemoryDay.key(until.addingTimeInterval(-1), calendar: calendar) < MemoryDay.key(now, calendar: calendar)
    }

    /// 页和已整理进它的碎片同一轮命中：只带页，碎片不带（钉住的照带）
    static func dedup(_ memories: [Memory], against hits: [WikiPageHit]) -> [Memory] {
        guard !hits.isEmpty else { return memories }
        let paths = Set(hits.map(\.page.path))
        return memories.filter { m in m.isUserExplicit || !(m.organizedPage.map(paths.contains) ?? false) }
    }

    /// 常驻页那一行
    static func residentLine(indexCount: Int, hits: [WikiPageHit]) -> String {
        let tail = hits.isEmpty ? "本轮没命中" : "本轮命中：" + hits.map { "\($0.page.title)（“\($0.word)”）" }.joined(separator: "、")
        return "根索引 \(indexCount) 行 · \(tail)"
    }
}

/// 按楼层缓存快照；发送前等待当前有效代次，拿到的值固定用于这一轮。
/// 读盘在后台进行，等待者的超时 / 取消不依赖同步读盘是否已经返回。
final class WikiInjectionCache: @unchecked Sendable {
    typealias Source = @Sendable () -> WikiStore

    struct WarmedSnapshot: Equatable, Sendable {
        let generation: Int
        let snapshot: WikiInjectionSnapshot
    }

    enum WarmError: Error, Equatable, LocalizedError {
        case timedOut
        case rebuildLimitReached

        var errorDescription: String? {
            switch self {
            case .timedOut: return "等待 wiki 注入缓存超时，请稍后重试。"
            case .rebuildLimitReached: return "wiki 持续变更，注入缓存未能就绪，请稍后重试。"
            }
        }
    }

    static let shared = WikiInjectionCache()
    /// 后台重建完一份（主线程发）：常驻页据此刷新
    static let didRebuild = Notification.Name("MemoryPalaceWikiInjectionDidRebuild")

    private struct Entry {
        let generation: Int
        let snapshot: WikiInjectionSnapshot
        let buildID: UInt64
        let source: Source

        var warmed: WarmedSnapshot { WarmedSnapshot(generation: generation, snapshot: snapshot) }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<WarmedSnapshot, Error>
        let timeout: DispatchWorkItem

        func resume(with result: Result<WarmedSnapshot, Error>) {
            timeout.cancel()
            continuation.resume(with: result)
        }
    }

    private let lock = NSLock()
    private let injectedSource: Source?
    private var generation = 0
    private var nextBuildID: UInt64 = 0
    private var entries: [String: Entry] = [:]
    private var scheduled: Set<String> = []
    private var waiters: [String: [UUID: Waiter]] = [:]
    private var observer: NSObjectProtocol?

    init(source: Source? = nil) {
        injectedSource = source
        observer = NotificationCenter.default.addObserver(forName: .memoryDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    static func source(profileId: String) -> Source {
        { WikiStore(profileId: profileId) }
    }

    /// 楼层的快照；store 给了（测试的临时目录）按它的路径存
    func snapshot(profileId: String, store: WikiStore?) -> WikiInjectionSnapshot? {
        guard let store else { return snapshot(profileId, Self.source(profileId: profileId)) }
        return snapshot(store.root.path) { store }
    }

    var version: Int { lock.withLock { generation } }

    /// 作废全部，建过的楼层排后台重建
    func invalidate() {
        let known: [(String, Source)] = lock.withLock {
            generation += 1
            return entries.map { ($0.key, $0.value.source) }
        }
        known.forEach { schedule($0.0, $0.1) }
    }

    func isFresh(_ key: String) -> Bool {
        lock.withLock { entries[key]?.generation == generation }
    }

    /// 预览 / 检查器可读旧值并安排重建；发送只用 warm 返回的快照。
    func snapshot(_ key: String, _ source: @escaping Source) -> WikiInjectionSnapshot? {
        let (cached, fresh): (WikiInjectionSnapshot?, Bool) = lock.withLock {
            let e = entries[key]
            return (e?.snapshot, e?.generation == generation)
        }
        if fresh { return cached }
        if Thread.isMainThread {
            schedule(key, source)
            return cached
        }
        return build(key, source)
    }

    /// 读盘前后核对代次，最多重试三次；持续写入时保留最后一次读到的内容，但不冒充新代次
    @discardableResult
    func build(_ key: String, _ source: @escaping Source) -> WikiInjectionSnapshot {
        let source = injectedSource ?? source
        var attempt = 0
        while true {
            let (g, buildID) = lock.withLock {
                nextBuildID += 1
                return (generation, nextBuildID)
            }
            let snapshot = WikiInjection.load(source())
            let result: (snapshot: WikiInjectionSnapshot, published: Bool, ready: [Waiter], warmed: WarmedSnapshot?)? = lock.withLock {
                if let entry = entries[key],
                   entry.generation > g || (entry.generation == g && entry.buildID > buildID) {
                    if entry.generation == generation || attempt == 3 {
                        return (entry.snapshot, false, [], nil)
                    }
                    return nil
                }
                guard g == generation || attempt == 3 else { return nil }
                let entry = Entry(generation: g, snapshot: snapshot, buildID: buildID, source: source)
                entries[key] = entry
                let ready = g == generation ? waiters.removeValue(forKey: key).map { Array($0.values) } ?? [] : []
                return (snapshot, true, ready, g == generation ? entry.warmed : nil)
            }
            guard let result else {
                attempt += 1
                continue
            }
            if attempt == 3, !isFresh(key) {
                CacheDiagLog.shared.log("📚 wiki 注入缓存: \(key) 连续失效，使用最后一次快照，保留旧代次")
            }
            if let warmed = result.warmed { result.ready.forEach { $0.resume(with: .success(warmed)) } }
            if result.published {
                Task { @MainActor in NotificationCenter.default.post(name: Self.didRebuild, object: nil) }
            }
            return result.snapshot
        }
    }

    /// 总等待上限五秒；在锁内取有效 entry，避免检查新鲜后又取到另一个代次。
    func warm(_ key: String, _ source: @escaping Source) async throws -> WarmedSnapshot {
        try Task.checkCancellation()
        let deadline = DispatchTime.now() + .seconds(5)
        let id = UUID()
        let warmed: WarmedSnapshot = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = DispatchWorkItem { [weak self] in
                    self?.finishWaiter(key, id: id, result: .failure(WarmError.timedOut))
                }
                let immediate: Result<WarmedSnapshot, Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let entry = entries[key], entry.generation == generation { return .success(entry.warmed) }
                    waiters[key, default: [:]][id] = Waiter(continuation: continuation, timeout: timeout)
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                } else {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: timeout)
                    schedule(key, source)
                }
            }
        } onCancel: {
            self.finishWaiter(key, id: id, result: .failure(CancellationError()))
        }
        try Task.checkCancellation()
        return warmed
    }

    private func finishWaiter(_ key: String, id: UUID, result: Result<WarmedSnapshot, Error>) {
        let waiter = lock.withLock {
            let waiter = waiters[key]?.removeValue(forKey: id)
            if waiters[key]?.isEmpty == true { waiters.removeValue(forKey: key) }
            return waiter
        }
        waiter?.resume(with: result)
    }

    /// 打开对话时先在后台备好（C 没勾不读）
    func prefetch(profileId: String) {
        guard MemoryOpenWindow.injects(.c), !isFresh(profileId) else { return }
        schedule(profileId, Self.source(profileId: profileId))
    }

    /// 连续写合成一次；最多三批，每批 build 自身最多读取四次。
    func schedule(_ key: String, _ source: @escaping Source) {
        let source = injectedSource ?? source
        guard lock.withLock({
            entries[key]?.generation != generation && scheduled.insert(key).inserted
        }) else { return }
        Task.detached(priority: .utility) {
            for batch in 0..<3 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.build(key, source)
                let result: (done: Bool, failed: [Waiter]) = self.lock.withLock {
                    if self.entries[key]?.generation == self.generation {
                        self.scheduled.remove(key)
                        return (true, [])
                    }
                    guard batch == 2 else { return (false, []) }
                    self.scheduled.remove(key)
                    return (true, self.waiters.removeValue(forKey: key).map { Array($0.values) } ?? [])
                }
                result.failed.forEach { $0.resume(with: .failure(WarmError.rebuildLimitReached)) }
                if result.done { return }
            }
        }
    }
}
