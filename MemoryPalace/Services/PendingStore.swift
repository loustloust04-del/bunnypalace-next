import Foundation
import CryptoKit

/// 待续的三种状态（v5 §3-2，学惦记小本本）
enum PendingState: String, CaseIterable, Identifiable {
    case open, faded, done
    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: return "没做完"
        case .faded: return "淡了"
        case .done: return "做完了"
        }
    }
}

/// 待续一条：哪个窗口、哪天冒出来的、记到哪条消息
struct PendingItem: Equatable, Identifiable {
    var id: String
    var text: String
    var state: PendingState
    var conversationId: String
    /// 05:00 日界的 yyyy-MM-dd
    var day: String
    /// 出处消息 id（时间轴写手写到的那条）
    var anchor: String?
    /// 搬进来时的来源（c2c3-v2 第 7 段 astra 二轮 #7）：哪一段 / 哪条老条目（哈希），以后不变
    var source: String? = nil
    /// 搬进来时的原文哈希：她改了字、改了三态，按它去重，不会再搬一遍。老的（没有）按窗口 + 一字不差
    var origin: String? = nil
}

/// 待续单独存（plan §八）：`memory/pending/待续.md`，一条一行。老时间轴条目里的待续迁进来；c2c3-v2 第 7 段起 A4 拼日时由代码
/// 把当天碰到的 A2 段自带的待续搬进来（以前是 A4 窗口写手的模型写）；注入只带「没做完」；
/// {助手}用 `pending_notes` 标「做完了 / 淡了」；设置「整理 › 待续」和记忆 app 时间轴格同一份，能改三态、改字。
/// 文件不在 = 这一层还没迁移：注入 / recall 照读时间轴条目里的老字段（金样走这条）
enum PendingStore {
    static let folder = "pending"
    static let fileName = "待续.md"

    static func fileURL(profileId: String) -> URL {
        fileURL(root: FileLibraryStore.memoryRoot(profileId: profileId))
    }

    static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(fileName)
    }

    // MARK: - 缓存（组 prompt 在主线程读：读过一次就记住，含「没迁移」；写都经过这里，缓存跟着换）

    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var cache: [String: [PendingItem]?] = [:]
    /// 给主线程看的那份（astra #5）：缓存每次换新都抄一份过来；这把锁只护字典、不在里面读写盘，有人在写盘时组 prompt 照样拿得到上一份
    private static let snapshotLock = NSLock()
    nonisolated(unsafe) private static var snapshot: [String: [PendingItem]?] = [:]

    /// 这一层迁移过没有：按楼层的布尔，主线程不读盘也能判断（迁移 / 读到文件 / 写过一次都记上）
    static func migratedKey(profileId: String) -> String { "mem_pending_migrated_\(profileId)" }

    static func isMigrated(profileId: String) -> Bool {
        UserDefaults.standard.bool(forKey: migratedKey(profileId: profileId))
    }

    /// nil = 没迁移。memoryRoot 非空（三代搬迁注入了根：演练 / 测试）= 直接读那份，不进缓存、不记「迁移过」——那是 app 里这一层的状态
    static func load(profileId: String, memoryRoot: URL? = nil) -> [PendingItem]? {
        if let memoryRoot { return read(fileURL(root: memoryRoot)) }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[profileId] { return hit }
        let items = read(fileURL(profileId: profileId))
        remember(items, profileId: profileId)
        return items
    }

    static func forget(profileId: String) {
        lock.lock(); cache[profileId] = nil; lock.unlock()
        snapshotLock.lock(); snapshot[profileId] = nil; snapshotLock.unlock()
    }

    /// 缓存换新（锁里调）：抄给主线程那份；有文件 = 迁移过，记上
    private static func remember(_ items: [PendingItem]?, profileId: String) {
        cache[profileId] = .some(items)
        snapshotLock.lock(); snapshot[profileId] = .some(items); snapshotLock.unlock()
        if items != nil, !isMigrated(profileId: profileId) {
            UserDefaults.standard.set(true, forKey: migratedKey(profileId: profileId))
        }
    }

    private static func read(_ url: URL) -> [PendingItem]? {
        MainThreadIO.note(.read, "PendingStore.load")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(raw)
    }

    /// 锁里严格读实际文件（不用缓存）：读不了 / 有认不出的行就抛；不在 = nil（c2c3-v2 第 7 段 astra 三轮 #1：所有改动都走它）
    private static func strictLoad(profileId: String, memoryRoot: URL?) throws -> [PendingItem]? {
        try checkReadable(profileId: profileId, memoryRoot: memoryRoot)
        return read(memoryRoot.map(fileURL(root:)) ?? fileURL(profileId: profileId))
    }

    /// 读—改—写整份（锁里，严格读实际文件：有认不出的行就拒写，不宽松读了再整份重写）；没迁移的先当空的
    @discardableResult
    static func mutate(profileId: String, memoryRoot: URL? = nil, _ change: (inout [PendingItem]) -> Void) throws -> [PendingItem] {
        lock.lock(); defer { lock.unlock() }
        var items = try strictLoad(profileId: profileId, memoryRoot: memoryRoot) ?? []
        change(&items)
        try write(items, to: memoryRoot.map(fileURL(root:)) ?? fileURL(profileId: profileId))
        if memoryRoot == nil { remember(items, profileId: profileId) }
        return items
    }

    /// 整份写；legacyDone = nil 时照原文件头上的「老条目待续迁完了」标记写回去（日常改三态 / 改字 / 搬待续都不碰这个标记）
    private static func write(_ items: [PendingItem], to url: URL, legacyDone: Bool? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let done = legacyDone ?? isLegacyDone(url)
        try Data(render(items, legacyDone: done).utf8).write(to: url, options: .atomic)
    }

    /// 老时间轴条目里的待续全部严格迁进来过没有（标记在本子文件头上，跟着本子一起备份 / 恢复）。本子在 ≠ 迁完了
    static func isLegacyDone(_ url: URL) -> Bool {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return frontmatter(raw)?["legacy"] == "done"
    }

    static func isLegacyDone(profileId: String, memoryRoot: URL? = nil) -> Bool {
        isLegacyDone(memoryRoot.map(fileURL(root:)) ?? fileURL(profileId: profileId))
    }

    /// 只读头（一条都没有时 `FrontmatterCodec.parse` 给 nil，这里照样读得出）
    private static func frontmatter(_ raw: String) -> [String: String]? {
        if let (meta, _) = FrontmatterCodec.parse(raw) { return meta }
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var meta: [String: String] = [:]
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            meta[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return meta
    }

    // MARK: - 读给别人用

    /// 每个窗口没做完的（按先后）；nil = 没迁移
    static func openByConversation(profileId: String) -> [String: [String]]? {
        guard let items = load(profileId: profileId) else { return nil }
        return Dictionary(grouping: items.filter { $0.state == .open }, by: \.conversationId).mapValues { $0.map(\.text) }
    }

    /// 组 prompt 用（主线程）：只读快照、不碰盘。有快照就用（有人正在写盘也照用上一份）；没快照时后台去读，这一轮——
    /// 没迁移的楼层 → nil（照读条目老字段）；迁移过但还没热 → 空的（这一轮不带待续，别把做完 / 淡了的老字段翻出来，astra #5）
    static func openByConversationCached(profileId: String) -> [String: [String]]? {
        snapshotLock.lock()
        let hit = snapshot[profileId]
        snapshotLock.unlock()
        guard let hit else {
            warm(profileId: profileId)
            return isMigrated(profileId: profileId) ? [:] : nil
        }
        guard let items = hit else { return nil }
        return Dictionary(grouping: items.filter { $0.state == .open }, by: \.conversationId).mapValues { $0.map(\.text) }
    }

    /// 后台把这一层读进缓存（启动、第一次组 prompt 时）
    static func warm(profileId: String) {
        DispatchQueue.global(qos: .utility).async { _ = load(profileId: profileId) }
    }

    // MARK: - 改

    /// 只加：同一个窗口已经有一字不差、还没做完的不再加。返回新加的
    @discardableResult
    static func add(_ texts: [String], conversationId: String, day: String, anchor: String?, profileId: String,
                    memoryRoot: URL? = nil) throws -> [PendingItem] {
        var added: [PendingItem] = []
        try mutate(profileId: profileId, memoryRoot: memoryRoot) { items in
            added = adding(texts, conversationId: conversationId, day: day, anchor: anchor, to: &items)
        }
        return added
    }

    /// 一处要搬进来的待续：A2 段（含尾段）或一条老时间轴条目。source = 来源身份（不含字），day / anchor 照旧
    struct Candidate: Equatable, Codable {
        var conversationId: String
        var day: String
        var anchor: String?
        var texts: [String]
        var source: String
    }

    /// A2 段的来源身份：窗口 + 尾段（尾段整段重写，身份不变）/ 正式段的起点
    static func segmentSource(conversationId: String, segment: SessionSegment) -> String {
        hash("a2|\(conversationId)|" + (segment.isTail ? "tail" : String(Int(segment.start.timeIntervalSince1970))))
    }

    /// 老条目的来源身份：窗口 + 日期 + 末条消息
    static func legacySource(_ e: TimelineEntry) -> String {
        hash("old|\(e.conversationId)|\(e.dayKey)|\(e.lastNodeId ?? "")")
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// c2c3-v2 第 7 段：A2 段的待续 / 老条目的待续搬进来（不调模型）。「无」/ 空的不搬；同一个窗口已经搬过这句（按原文哈希，
    /// 她改了字、标了做完 / 淡了都算搬过）、或老的没哈希但一字不差的，不再加；老条目还认「同窗口同日同锚点」那批（以前迁过的整条）。
    /// 严格读：本子在但有认不出的行就抛，一条都不写（不丢行）。返回新加的；没有要加的不写盘
    @discardableResult
    static func addCandidates(_ list: [Candidate], profileId: String, memoryRoot: URL? = nil) throws -> [PendingItem] {
        lock.lock(); defer { lock.unlock() }
        guard !list.isEmpty else { return [] }
        let before = try strictLoad(profileId: profileId, memoryRoot: memoryRoot) ?? []
        var items = before
        let added = importing(list, into: &items)
        guard items != before else { return [] }
        try write(items, to: memoryRoot.map(fileURL(root:)) ?? fileURL(profileId: profileId))
        if memoryRoot == nil { remember(items, profileId: profileId) }
        return added
    }

    // MARK: - 待补（搬不成的来源先记下，下次存段 / A4 巡检再搬，不丢）

    static let retryFileName = ".待补.json"

    static func retryURL(profileId: String, memoryRoot: URL?) -> URL {
        (memoryRoot.map(fileURL(root:)) ?? fileURL(profileId: profileId)).deletingLastPathComponent().appendingPathComponent(retryFileName)
    }

    /// 待补：不在 = 空的；在但读不了 / 解不出来就抛（astra 四轮 #2：坏队列不能当空的，更不能被覆盖）
    static func retryQueueStrict(profileId: String, memoryRoot: URL? = nil) throws -> [Candidate] {
        lock.lock(); defer { lock.unlock() }
        let url = retryURL(profileId: profileId, memoryRoot: memoryRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([Candidate].self, from: Data(contentsOf: url)) } catch {
            throw MemoryReadError.corrupt(url.path)
        }
    }

    /// 只看有没有（读不了也算有：别当成没东西可补）
    static func hasRetry(profileId: String, memoryRoot: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: retryURL(profileId: profileId, memoryRoot: memoryRoot).path)
    }

    /// 记进待补并落盘；原来的读不了就拒绝覆盖、抛；写不进去也抛（调用方据此不覆盖 A2）
    static func enqueueRetry(_ list: [Candidate], profileId: String, memoryRoot: URL? = nil) throws {
        guard !list.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var queue = try retryQueueStrict(profileId: profileId, memoryRoot: memoryRoot)
        for c in list where !queue.contains(c) { queue.append(c) }
        let url = retryURL(profileId: profileId, memoryRoot: memoryRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(queue).write(to: url, options: .atomic)
    }

    /// 待补的 + 这一批一起搬；成了清掉待补，没成抛（待补原样留着）。待补读不了：只搬这一批，坏的那份原样留着不动
    @discardableResult
    static func addCandidatesFlushingRetry(_ list: [Candidate], profileId: String, memoryRoot: URL? = nil) throws -> [PendingItem] {
        lock.lock(); defer { lock.unlock() }
        let queue = try? retryQueueStrict(profileId: profileId, memoryRoot: memoryRoot)
        let added = try addCandidates((queue ?? []) + list, profileId: profileId, memoryRoot: memoryRoot)
        if let queue, !queue.isEmpty { try? FileManager.default.removeItem(at: retryURL(profileId: profileId, memoryRoot: memoryRoot)) }
        return added
    }

    /// 纯函数（可测）：去重规则见 `addCandidates`。对上的老条目顺手补上搬运身份（astra 三轮 #4）：
    /// 以前整条迁过的那批（没来源身份、同窗口同日同锚点）——字没改的按字对、改过的按先后对上剩下的原文，都记成搬过、不再加；
    /// 一字不差对上的也记下原文哈希和来源。以后她再改字、标三态，同一句都不会再搬一遍
    static func importing(_ list: [Candidate], into items: inout [PendingItem]) -> [PendingItem] {
        var added: [PendingItem] = []
        var next = (items.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        for c in list {
            let texts = c.texts.map(oneLine).filter { !$0.isEmpty && $0 != "无" }
            if c.source.hasPrefix(legacyMark) {
                let batch = items.indices.filter {
                    items[$0].source == nil && items[$0].conversationId == c.conversationId && items[$0].day == c.day && items[$0].anchor == c.anchor
                }
                if !batch.isEmpty {
                    var left = texts
                    var edited: [Int] = []
                    for i in batch {
                        if let k = left.firstIndex(of: items[i].text) {
                            items[i].origin = hash(left.remove(at: k))
                        } else {
                            edited.append(i)
                        }
                        items[i].source = c.source
                    }
                    for (i, t) in zip(edited, left) where items[i].origin == nil { items[i].origin = hash(t) }
                    continue
                }
            }
            for t in texts {
                let origin = hash(t)
                if let i = items.firstIndex(where: { $0.conversationId == c.conversationId && ($0.origin == origin || ($0.origin == nil && $0.text == t)) }) {
                    if items[i].origin == nil {
                        items[i].origin = origin
                        if items[i].source == nil { items[i].source = c.source }
                    }
                    continue
                }
                let item = PendingItem(id: String(format: "p%04d", next), text: t, state: .open, conversationId: c.conversationId,
                                       day: c.day, anchor: c.anchor, source: c.source, origin: origin)
                next += 1
                items.append(item)
                added.append(item)
            }
        }
        return added
    }

    /// 老条目来源身份的前缀标记（`legacyCandidate` 里加上），只用来认「以前整条迁过」
    private static let legacyMark = "o"

    static func legacyCandidate(_ e: TimelineEntry) -> Candidate {
        Candidate(conversationId: e.conversationId, day: e.dayKey, anchor: e.lastNodeId,
                  texts: TimelineStore.pendingItems(e.pending), source: legacyMark + legacySource(e))
    }

    /// 这条老条目搬进本子的那几条（迁完以后 A 线读它，按本子的三态和现在的字）：按来源身份认；以前没身份的按同窗口同日同锚点
    static func items(from e: TimelineEntry, in items: [PendingItem]) -> [PendingItem] {
        let src = legacyMark + legacySource(e)
        return items.filter { $0.source == src || ($0.source == nil && $0.conversationId == e.conversationId && $0.day == e.dayKey && $0.anchor == e.lastNodeId) }
    }

    /// 老条目的待续还没迁好（或迁移失败）：不许改，免得改了一半的本子再被当成迁完（astra 三轮 #1）
    struct NotMigrated: LocalizedError {
        var errorDescription: String? { "老时间轴里的待续还没迁好" }
    }

    private static func requireMigrated(profileId: String) throws {
        if try needsLegacyImport(profileId: profileId) { throw NotMigrated() }
    }

    static func setState(_ id: String, _ state: PendingState, profileId: String) throws {
        try requireMigrated(profileId: profileId)
        try mutate(profileId: profileId) { items in
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = state }
        }
    }

    static func setText(_ id: String, _ text: String, profileId: String) throws {
        try requireMigrated(profileId: profileId)
        let t = oneLine(text)
        guard !t.isEmpty else { return }
        try mutate(profileId: profileId) { items in
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].text = t }
        }
    }

    // MARK: - 三代搬迁 / 恢复（astra #7 #8 #9）

    /// 恢复备份独占：整段拿着这把锁换文件，出来时（成 / 败都算）缓存清掉、下次读盘。期间加待续、改三态、改字都等着
    static func replacingFiles<T>(profileId: String, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer {
            forget(profileId: profileId)
            lock.unlock()
        }
        return try body()
    }

    /// 文件在就必须读得出、每一行都认得（读不了 / 头坏了 / 有认不出的非空行就抛——整份重写会丢掉它）；不在 = 没迁移，不算错
    static func checkReadable(profileId: String, memoryRoot: URL? = nil) throws {
        let url = memoryRoot.map(fileURL(root:)) ?? fileURL(profileId: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let raw = try MemoryReadError.read(url)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let (_, body) = FrontmatterCodec.parse(raw) else {
            // 只有头、一条都没有（`render([])`）也算读得出
            let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---"),
                  lines[(close + 1)...].allSatisfy(\.isEmpty) else { throw MemoryReadError.corrupt(url.path) }
            return
        }
        let lines = body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard parse(raw).count == lines else { throw MemoryReadError.corrupt(url.path) }
    }

    // MARK: - 老条目待续迁移（严格，唯一入口在 `TimelineDaily.ensurePendingMigrated`）

    /// 还要不要迁：本子头上标了迁完 = 不用；没有老时间轴月文件 = 没东西可迁
    static func needsLegacyImport(profileId: String, memoryRoot: URL? = nil) throws -> Bool {
        if isLegacyDone(profileId: profileId, memoryRoot: memoryRoot) { return false }
        let dir = memoryRoot.map(TimelineStore.dir(root:)) ?? TimelineStore.dir(profileId: profileId)
        return try !TimelineStore.monthsStrict(in: dir).isEmpty
    }

    /// 严格迁（调用方先备份好）：本子在就必须每行都认得；全部月文件严格读，每个窗口最新一条老条目里的待续补进来——
    /// 已经在的（以前宽松迁过的、她改过字的、标了三态的）不动、不重复，漏掉的补上；都成了才在本子头上标「迁完」。
    /// 有月文件读不了 / 本子读不全就抛，一条都不写
    static func importLegacyStrict(profileId: String, memoryRoot: URL? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try checkReadable(profileId: profileId, memoryRoot: memoryRoot)
        let url = memoryRoot.map(fileURL(root:)) ?? fileURL(profileId: profileId)
        guard !isLegacyDone(url) else { return }
        let dir = memoryRoot.map(TimelineStore.dir(root:)) ?? TimelineStore.dir(profileId: profileId)
        var latest: [String: TimelineEntry] = [:]
        for month in try TimelineStore.monthsStrict(in: dir) {
            for e in try TimelineStore.entriesStrict(month: month, in: dir) {
                if let old = latest[e.conversationId], (old.dayKey, old.end) >= (e.dayKey, e.end) { continue }
                latest[e.conversationId] = e
            }
        }
        var items = try strictLoad(profileId: profileId, memoryRoot: memoryRoot) ?? []
        let added = importing(latest.values.sorted { ($0.dayKey, $0.end) < ($1.dayKey, $1.end) }.map(legacyCandidate), into: &items)
        try write(items, to: url, legacyDone: true)
        if memoryRoot == nil { remember(items, profileId: profileId) }
        CacheDiagLog.shared.log("📌 待续: 老条目的待续迁好了（补了 \(added.count) 条）")
    }

    // MARK: - 纯函数（可测）

    static func adding(_ texts: [String], conversationId: String, day: String, anchor: String?, to items: inout [PendingItem]) -> [PendingItem] {
        var added: [PendingItem] = []
        var next = (items.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        for raw in texts {
            let t = oneLine(raw)
            guard !t.isEmpty, t != "无" else { continue }
            if items.contains(where: { $0.conversationId == conversationId && $0.state == .open && $0.text == t }) { continue }
            let item = PendingItem(id: String(format: "p%04d", next), text: t, state: .open,
                                   conversationId: conversationId, day: day, anchor: anchor)
            next += 1
            items.append(item)
            added.append(item)
        }
        return added
    }

    static func render(_ items: [PendingItem], legacyDone: Bool = false) -> String {
        let body = items.map { i -> String in
            var meta = "id=\(i.id) state=\(i.state.rawValue) conv=\(i.conversationId) day=\(i.day)"
            if let a = i.anchor { meta += " anchor=\(a)" }
            if let s = i.source { meta += " src=\(s)" }
            if let o = i.origin { meta += " orig=\(o)" }
            return "- \(i.text) <!-- \(meta) -->"
        }.joined(separator: "\n")
        return FrontmatterCodec.render(meta: [("version", "1")] + (legacyDone ? [("legacy", "done")] : []), body: body)
    }

    static func parse(_ raw: String) -> [PendingItem] {
        guard let (_, body) = FrontmatterCodec.parse(raw) else { return [] }
        return body.components(separatedBy: "\n").compactMap { line -> PendingItem? in
            guard line.hasPrefix("- "), let open = line.range(of: " <!-- ", options: .backwards),
                  line.hasSuffix(" -->") else { return nil }
            let text = String(line[line.index(line.startIndex, offsetBy: 2)..<open.lowerBound])
            let metaText = line[open.upperBound..<line.index(line.endIndex, offsetBy: -4)]
            let fields = Dictionary(metaText.split(separator: " ").compactMap { pair -> (String, String)? in
                let kv = pair.split(separator: "=", maxSplits: 1)
                return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
            }, uniquingKeysWith: { a, _ in a })
            guard let id = fields["id"], let conv = fields["conv"] else { return nil }
            return PendingItem(id: id, text: text, state: fields["state"].flatMap(PendingState.init(rawValue:)) ?? .open,
                               conversationId: conv, day: fields["day"] ?? "", anchor: fields["anchor"],
                               source: fields["src"], origin: fields["orig"])
        }
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "<!--", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
