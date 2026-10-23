import Foundation
import SwiftData
import Observation

enum SearchIndexStatus: Equatable {
    case idle
    case building(progress: Double)
    case ready
    case failed(String)
}

/// UI 观察用（只在主线程改）
@Observable
final class SearchIndexState {
    fileprivate(set) var status: SearchIndexStatus = .idle
    fileprivate(set) var docCount = 0
}

/// S5 索引维护（plan-search-s5 设计 2）：回填 + 三道网。
/// 所有「读 SwiftData → 写索引」都在同一条串行队列里做，回填批和增量批不会交错覆盖。
final class SearchIndexer: @unchecked Sendable {
    static let shared = SearchIndexer(url: SearchIndexStore.defaultURL)

    static let batchSize = 500
    static let coalesceDelay: TimeInterval = 0.3

    let state = SearchIndexState()

    private let url: URL
    private let queue = DispatchQueue(label: "com.susu.MemoryPalace.search-indexer", qos: .utility)
    private let lock = NSLock()
    // lock 保护
    private var storeRef: SearchIndexStore?
    private var isReady = false
    private var pendingUpserts = Set<PersistentIdentifier>()
    private var pendingDeletedKeys = Set<String>()
    private var flushScheduled = false
    private var preStartOps: [(SearchIndexer) -> Void] = []
    private var started = false
    // queue 独占
    private var container: ModelContainer?
    private var observer: NSObjectProtocol?
    private var knownProfileIds: [String] = []
    private var backfillTotal = 0
    /// 必须 sortedKeys：不排序时同一 identifier 两次编码的键序可能不同，删除反查会偶发对不上
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(url: URL) {
        self.url = url
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 索引可查时给出 store（回填没完 / 坏了 = nil，调用方退回旧扫描）。任意线程可调
    var readyStore: SearchIndexStore? {
        lock.lock()
        defer { lock.unlock() }
        return isReady ? storeRef : nil
    }

    // MARK: - 启动

    func start(container: ModelContainer, profileIds: [String], delay: TimeInterval = 0) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            self.container = container
            knownProfileIds = profileIds
            do {
                let store = try SearchIndexStore.open(at: url)
                lock.lock()
                storeRef = store
                let ops = preStartOps
                preStartOps = []
                lock.unlock()
                attachObserver(container: container)
                ops.forEach { $0(self) }
                if store.meta("backfill_done") == "1" {
                    markReady(store)
                    reconcile(force: false)
                } else {
                    beginBackfill()
                }
            } catch {
                publish(.failed(error.localizedDescription))
            }
        }
    }

    /// 没 start 之前的失效操作先攒着，start 时补做
    private func whenStarted(_ op: @escaping (SearchIndexer) -> Void) {
        lock.lock()
        if storeRef == nil {
            preStartOps.append(op)
            lock.unlock()
            return
        }
        lock.unlock()
        queue.async { op(self) }
    }

    private var store: SearchIndexStore? {
        lock.lock()
        defer { lock.unlock() }
        return storeRef
    }

    // MARK: - 回填（按对话，攒够 500 条一批一事务 + 游标，可中断续跑）

    private func beginBackfill() {
        guard let container else { return }
        lock.lock()
        isReady = false
        lock.unlock()
        backfillTotal = (try? ModelContext(container).fetchCount(FetchDescriptor<MessageNode>())) ?? 0
        publish(.building(progress: 0))
        queue.async { self.backfillStep() }
    }

    private func backfillStep() {
        guard let store, let container else { return }
        let epoch = store.epoch
        let cursor = store.meta("cursor") ?? ""
        let processed = Int(store.meta("processed") ?? "0") ?? 0
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        var convDesc = FetchDescriptor<Conversation>()
        convDesc.propertiesToFetch = [\.id]
        do {
            // 游标只在 Swift 里比：SQLite 的字符串排序和 #Predicate 的 > 对大小写混排的 id 不一致，
            // 旧的「id > 游标 + 按 id 排序」会整段跳过（09-27 Air 首次回填漏了约 1.5 万条）
            let pending = try ctx.fetch(convDesc).map(\.id).filter { $0 > cursor }.sorted()
            var nodes: [MessageNode] = []
            var last: String?
            for convId in pending {
                nodes += try ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == convId }))
                last = convId
                if nodes.count >= Self.batchSize { break }
            }
            guard let last else {
                guard try store.apply(upserts: [], meta: ["backfill_done": "1", "cursor": nil, "processed": nil], epoch: epoch) else {
                    queue.async { self.backfillStep() }
                    return
                }
                try? store.optimize()
                markReady(store)
                reconcile(force: false)
                return
            }
            let docs = nodes.map(makeDoc)
            let done = processed + nodes.count
            if try store.apply(upserts: docs, meta: ["cursor": last, "processed": String(done)], epoch: epoch) {
                publish(.building(progress: backfillTotal > 0 ? min(1, Double(done) / Double(backfillTotal)) : 0))
            }
            queue.async { self.backfillStep() }
        } catch {
            publish(.failed(error.localizedDescription))
        }
    }

    private func markReady(_ store: SearchIndexStore) {
        lock.lock()
        isReady = true
        lock.unlock()
        publish(.ready, docCount: store.docCount())
    }

    // MARK: - 网 1：didSave 增量（300ms 合并，后台 context 按 identifier 重读）

    private func attachObserver(container: ModelContainer) {
        let target = ObjectIdentifier(container)
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] n in
            guard let self, let ctx = n.object as? ModelContext, ObjectIdentifier(ctx.container) == target else { return }
            let info = n.userInfo ?? [:]
            func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
                (info[key.rawValue] as? [PersistentIdentifier] ?? []).filter { $0.entityName == "MessageNode" }
            }
            let upserts = ids(.insertedIdentifiers) + ids(.updatedIdentifiers)
            let deletedKeys = ids(.deletedIdentifiers).compactMap(self.identifierKey)
            guard !upserts.isEmpty || !deletedKeys.isEmpty else { return }
            self.enqueue(upserts: upserts, deletedKeys: deletedKeys)
        }
    }

    private func enqueue(upserts: [PersistentIdentifier], deletedKeys: [String]) {
        lock.lock()
        pendingUpserts.formUnion(upserts)
        pendingDeletedKeys.formUnion(deletedKeys)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule {
            queue.asyncAfter(deadline: .now() + Self.coalesceDelay) { self.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let upserts = pendingUpserts
        var deletedKeys = pendingDeletedKeys
        pendingUpserts = []
        pendingDeletedKeys = []
        flushScheduled = false
        lock.unlock()
        guard let store, let container else { return }
        let epoch = store.epoch
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        var docs: [SearchIndexDoc] = []
        let ids = Array(upserts)
        for start in stride(from: 0, to: ids.count, by: 200) {
            let chunk = Array(ids[start..<min(start + 200, ids.count)])
            let nodes = (try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? []
            docs += nodes.map(makeDoc)
            let found = Set(nodes.map(\.persistentModelID))
            // 保存后又被删了：当删除处理
            deletedKeys.formUnion(chunk.filter { !found.contains($0) }.compactMap(identifierKey))
        }
        do {
            let located = try store.nodes(forIdentifierKeys: Array(deletedKeys))
            let deleteIds = located.values.map(\.nodeId)
            if try !store.apply(upserts: docs, deleteNodeIds: deleteIds, epoch: epoch) {
                enqueue(upserts: ids, deletedKeys: Array(deletedKeys))
                return
            }
            publishCount(store)
        } catch {
            print("[search-index] 增量写失败，整库对账兜底：\(error)")
            reconcile(force: true)
        }
    }

    // MARK: - 网 2：显式失效点

    /// 删楼层：该楼层 doc + fts 同事务删，epoch + 1（批删 `delete(model:where:)` 不发逐条 identifier）
    func profileDeleted(_ profileId: String) {
        whenStarted { indexer in
            try? indexer.store?.deleteProfile(profileId)
            indexer.knownProfileIds.removeAll { $0 == profileId }
            indexer.store.map(indexer.publishCount)
        }
    }

    /// 这些对话整对话重建（下一次对账时做；已就绪就立刻做）
    func markDirty(conversationIds: [String]) {
        guard !conversationIds.isEmpty else { return }
        whenStarted { indexer in
            try? indexer.store?.markDirty(conversationIds)
            indexer.reconcileDirtyOnly()
        }
    }

    /// 清空重建（设置里「重建搜索索引」、整库替换后）
    func rebuild() {
        whenStarted { indexer in
            guard let store = indexer.store else { return }
            do {
                try store.reset()
                indexer.beginBackfill()
            } catch {
                indexer.publish(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - 网 3：对账（启动 / 回前台）

    /// 楼层级先比「节点数 + 最大 createTime」，不一致的楼层再逐对话比；标脏的对话无条件整对话重建。
    /// 只兜得住增删，原地改内容靠网 1。
    func requestReconcile(profileIds: [String]? = nil, force: Bool = false) {
        whenStarted { indexer in
            if let profileIds { indexer.knownProfileIds = profileIds }
            indexer.reconcile(force: force)
        }
    }

    private func reconcileDirtyOnly() {
        guard let store, let container, readyStore != nil else { return }
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        for convId in store.dirtyConversations() {
            rebuildConversation(convId, profileId: nil, store: store, ctx: ctx)
        }
        publishCount(store)
    }

    private func reconcile(force: Bool) {
        guard let store, let container, readyStore != nil else { return }
        reconcileDirtyOnly()
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        guard let indexStats = try? store.profileStats() else { return }
        let profiles = Set(knownProfileIds).union(indexStats.keys)
        for pid in profiles {
            let live = liveStats(ctx: ctx, profileId: pid, conversationId: nil)
            if !force, live == indexStats[pid] ?? SearchIndexStats(count: 0, maxCreatedMillis: nil) { continue }
            let convStats = (try? store.conversationStats(profileId: pid)) ?? [:]
            let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.profileId == pid })
            let liveConvIds = ((try? ctx.fetch(convDesc)) ?? []).map(\.id)
            for convId in Set(liveConvIds).union(convStats.keys) {
                let liveConv = liveStats(ctx: ctx, profileId: pid, conversationId: convId)
                if liveConv != convStats[convId] ?? SearchIndexStats(count: 0, maxCreatedMillis: nil) {
                    rebuildConversation(convId, profileId: pid, store: store, ctx: ctx)
                }
            }
            ctx.rollback()
        }
        publishCount(store)
    }

    private func liveStats(ctx: ModelContext, profileId pid: String, conversationId: String?) -> SearchIndexStats {
        var desc: FetchDescriptor<MessageNode>
        if let cid = conversationId {
            desc = FetchDescriptor(predicate: #Predicate { $0.profileId == pid && $0.conversationId == cid },
                                   sortBy: [SortDescriptor(\.createTime, order: .reverse)])
        } else {
            desc = FetchDescriptor(predicate: #Predicate { $0.profileId == pid },
                                   sortBy: [SortDescriptor(\.createTime, order: .reverse)])
        }
        let count = (try? ctx.fetchCount(desc)) ?? 0
        desc.fetchLimit = 1
        desc.propertiesToFetch = [\.createTime]
        let newest = (try? ctx.fetch(desc))?.first?.createTime
        return SearchIndexStats(count: count, maxCreatedMillis: newest.map { SearchIndexStore.millis($0.timeIntervalSince1970) })
    }

    private func rebuildConversation(_ convId: String, profileId: String?, store: SearchIndexStore, ctx: ModelContext) {
        let epoch = store.epoch
        let desc: FetchDescriptor<MessageNode>
        if let pid = profileId {
            desc = FetchDescriptor(predicate: #Predicate { $0.profileId == pid && $0.conversationId == convId })
        } else {
            desc = FetchDescriptor(predicate: #Predicate { $0.conversationId == convId })
        }
        let docs = ((try? ctx.fetch(desc)) ?? []).map(makeDoc)
        if (try? store.replaceConversation(convId, with: docs, epoch: epoch)) != true {
            try? store.markDirty([convId])
        }
    }

    // MARK: - 小工具

    private func makeDoc(_ node: MessageNode) -> SearchIndexDoc {
        SearchIndexDoc(
            nodeId: node.id, conversationId: node.conversationId, profileId: node.profileId, role: node.role,
            created: node.createTime, trashed: node.isTrashed,
            body: ContentCleaner.visibleText(node.content, isUser: node.role == "user", cacheKey: node.id, cached: false),
            identifierKey: identifierKey(node.persistentModelID)
        )
    }

    private func identifierKey(_ id: PersistentIdentifier) -> String? {
        (try? encoder.encode(id)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func publish(_ status: SearchIndexStatus, docCount: Int? = nil) {
        let state = state
        DispatchQueue.main.async {
            state.status = status
            if let docCount { state.docCount = docCount }
        }
    }

    private func publishCount(_ store: SearchIndexStore) {
        let count = store.docCount()
        let state = state
        DispatchQueue.main.async { state.docCount = count }
    }
}
