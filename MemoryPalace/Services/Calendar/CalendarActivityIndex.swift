import Foundation
import SwiftData
import Observation

// MARK: - 按天统计：扫描 / 失效 / 对账（plan-calendar §2.2）
// 样板照 SearchIndexer：后台串行队列，每次新建 ModelContext，跨线程只传 ID 和值类型。
// 失效三道网：① didSave 里的 MessageNode → 对话标脏；② 刷新时补扫新对话、删掉没了的对话；
// ③ 节点数对账（每天一次 / 有删除时）——兜住导入、备份恢复、同步补节点这些不走本进程保存通知的路径。

final class CalendarActivityIndex: @unchecked Sendable {
    static let shared = CalendarActivityIndex()

    private let queue = DispatchQueue(label: "memorypalace.calendar.activity", qos: .utility)
    private let lock = NSLock()
    private var container: ModelContainer?
    private var observer: NSObjectProtocol?
    private var pendingUpserts: Set<PersistentIdentifier> = []
    private var pendingDeleted = false
    private var flushScheduled = false
    private var generation = 0

    /// 只在 queue 上读写：楼层 → 对话 → 贡献（内存缓存，避免每次刷新都读几千个小文件）
    private var memo: [String: [String: ConversationContribution]] = [:]

    private static let batchSize = 500
    private static let saveEvery = 50

    func start(container: ModelContainer) {
        lock.lock()
        let already = self.container != nil
        self.container = container
        lock.unlock()
        guard !already else { return }
        let target = ObjectIdentifier(container)
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] n in
            guard let self, let ctx = n.object as? ModelContext, ObjectIdentifier(ctx.container) == target else { return }
            let info = n.userInfo ?? [:]
            func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
                (info[key.rawValue] as? [PersistentIdentifier] ?? []).filter { $0.entityName == "MessageNode" }
            }
            let upserts = ids(.insertedIdentifiers) + ids(.updatedIdentifiers)
            let deleted = !ids(.deletedIdentifiers).isEmpty
            guard !upserts.isEmpty || deleted else { return }
            self.enqueue(upserts: upserts, deleted: deleted)
        }
    }

    private func enqueue(upserts: [PersistentIdentifier], deleted: Bool) {
        lock.lock()
        pendingUpserts.formUnion(upserts)
        pendingDeleted = pendingDeleted || deleted
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule { queue.asyncAfter(deadline: .now() + 1) { self.flush() } }
    }

    /// 把保存通知里的节点换成「楼层 → 脏对话」，写进各楼层 manifest。
    private func flush() {
        lock.lock()
        let ids = Array(pendingUpserts)
        let deleted = pendingDeleted
        pendingUpserts = []
        pendingDeleted = false
        flushScheduled = false
        let container = self.container
        lock.unlock()
        guard let container else { return }
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        var dirty: [String: Set<String>] = [:]
        for start in stride(from: 0, to: ids.count, by: 200) {
            let chunk = Array(ids[start..<min(start + 200, ids.count)])
            var d = FetchDescriptor<MessageNode>(predicate: #Predicate { chunk.contains($0.persistentModelID) })
            d.propertiesToFetch = [\.profileId, \.conversationId]
            for node in (try? ctx.fetch(d)) ?? [] { dirty[node.profileId, default: []].insert(node.conversationId) }
        }
        for (pid, convs) in dirty {
            let store = ActivityCacheStore(profileId: pid)
            guard var m = store.loadManifest() else { continue }   // 这个楼层还没建过缓存：首次刷新会全扫
            m.dirty.formUnion(convs)
            store.saveManifest(m)
        }
        if deleted { markAllNeedReconcile() }
    }

    private func markAllNeedReconcile() {
        let base = ActivityCacheStore.defaultRoot(profileId: "x").deletingLastPathComponent()
        let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let store = ActivityCacheStore(root: dir)
            guard var m = store.loadManifest(), !m.needsReconcile else { continue }
            m.needsReconcile = true
            store.saveManifest(m)
        }
    }

    // MARK: 刷新

    /// 主线程调。切楼层 / 再次刷新会让旧的一轮停下（代际号）。
    func refresh(profileId: String, force: Bool = false) {
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()
        queue.async { self.run(profileId: profileId, force: force, gen: gen) }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    private func run(profileId pid: String, force: Bool, gen: Int) {
        lock.lock()
        let container = self.container
        lock.unlock()
        guard let container, isCurrent(gen) else { return }
        let calendar = Calendar.current
        let store = ActivityCacheStore(profileId: pid)
        var manifest = store.loadManifest() ?? ActivityManifest()
        if force || manifest.version != ActivityManifest.currentVersion || manifest.timeZone != TimeZone.current.identifier {
            store.wipe()
            manifest = ActivityManifest()
            memo[pid] = [:]
        }
        var contribs = memo[pid] ?? store.loadAll()

        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        var convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == pid && $0.isTrashed == false })
        convDesc.propertiesToFetch = [\.id]
        let live = Set(((try? ctx.fetch(convDesc)) ?? []).map(\.id))

        // 没了的 / 进回收站的
        for gone in Set(contribs.keys).subtracting(live) {
            contribs[gone] = nil
            store.remove(convId: gone)
        }
        manifest.dirty = manifest.dirty.intersection(live)
        var toScan = manifest.dirty.union(live.subtracting(contribs.keys))

        // 节点数对账
        let today = DailyActivity.dayKey(Date(), calendar: calendar)
        if manifest.needsReconcile || manifest.reconciledDay != today {
            for id in live where !toScan.contains(id) {
                if Self.nodeCount(convId: id, profileId: pid, ctx: ctx) != contribs[id]?.nodeCount { toScan.insert(id) }
                if !isCurrent(gen) { return }
            }
            manifest.needsReconcile = false
            manifest.reconciledDay = today
        }
        store.saveManifest(manifest)
        publish(pid, contribs, progress: toScan.isEmpty ? nil : (0, toScan.count), gen: gen)

        // 扫
        var done = 0
        var lastSave = Date()
        for id in toScan.sorted() {
            guard isCurrent(gen) else {
                memo[pid] = contribs
                store.saveManifest(manifest)
                return
            }
            let c = Self.scan(convId: id, profileId: pid, container: container, calendar: calendar)
            contribs[id] = c
            store.save(c)
            manifest.dirty.remove(id)
            done += 1
            if done % Self.saveEvery == 0 || Date().timeIntervalSince(lastSave) > 2 {
                store.saveManifest(manifest)
                lastSave = Date()
                publish(pid, contribs, progress: (done, toScan.count), gen: gen)
            }
        }
        store.saveManifest(manifest)
        memo[pid] = contribs
        publish(pid, contribs, progress: nil, gen: gen)
    }

    private static func nodeCount(convId: String, profileId pid: String, ctx: ModelContext) -> Int {
        let d = FetchDescriptor<MessageNode>(predicate: #Predicate {
            $0.profileId == pid && $0.conversationId == convId && $0.isTrashed == false
        })
        return (try? ctx.fetchCount(d)) ?? -1
    }

    /// 一个对话：分批取节点，只留值类型样本。每个对话用新 context，扫完就放。
    static func scan(convId: String, profileId pid: String, container: ModelContainer, calendar: Calendar) -> ConversationContribution {
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        var samples: [ActivityNodeSample] = []
        var offset = 0
        while true {
            var d = FetchDescriptor<MessageNode>(
                predicate: #Predicate { $0.profileId == pid && $0.conversationId == convId && $0.isTrashed == false },
                sortBy: [SortDescriptor(\.id)]
            )
            d.fetchLimit = batchSize
            d.fetchOffset = offset
            d.propertiesToFetch = [\.role, \.createTime, \.content, \.isDeleted]
            let batch = (try? ctx.fetch(d)) ?? []
            samples += batch.map { ActivityNodeSample(role: $0.role, createTime: $0.createTime, charCount: $0.content.count, isDeleted: $0.isDeleted) }
            if batch.count < batchSize { break }
            offset += batchSize
        }
        return DailyActivity.contribution(convId: convId, nodeCount: samples.count, samples: samples, calendar: calendar)
    }

    private func publish(_ pid: String, _ contribs: [String: ConversationContribution], progress: (Int, Int)?, gen: Int) {
        let summary = DailyActivity.aggregate(contribs.values)
        DispatchQueue.main.async {
            guard self.isCurrent(gen) else { return }
            MainActor.assumeIsolated {
                CalendarActivityModel.shared.apply(profileId: pid, summary: summary, progress: progress)
            }
        }
    }
}

/// 主线程可观察的快照：日历视图只读它。
@MainActor
@Observable
final class CalendarActivityModel {
    static let shared = CalendarActivityModel()

    private(set) var profileId = ""
    private(set) var summary = DailyActivity.Summary()
    /// 扫描中：(已扫, 总共)；nil = 没在扫
    private(set) var progress: (done: Int, total: Int)?
    /// 每次数据更新 +1：Canvas 等据此判断要不要重画
    private(set) var version = 0

    func apply(profileId: String, summary: DailyActivity.Summary, progress: (Int, Int)?) {
        if profileId != self.profileId || summary != self.summary { version += 1 }
        self.profileId = profileId
        self.summary = summary
        self.progress = progress.map { (done: $0.0, total: $0.1) }
    }

    func refresh(profileId: String, force: Bool = false) {
        if profileId != self.profileId {
            // 切楼层先清掉旧楼层的数据，避免短暂显示错楼层
            self.profileId = profileId
            summary = DailyActivity.Summary()
            version += 1
        }
        CalendarActivityIndex.shared.refresh(profileId: profileId, force: force)
    }
}
