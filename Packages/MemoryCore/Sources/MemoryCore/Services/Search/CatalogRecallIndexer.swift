import Foundation

public final class CatalogRecallIndexer: @unchecked Sendable {
    public static let shared = CatalogRecallIndexer()

    public init() {}

    private final class Floor {
        let wiki: WikiStore
        var store: CatalogRecallIndexStore?
        var status = CatalogRecallIndexStore.Status(state: .building, epoch: 0)
        var error: Error?
        init(wiki: WikiStore) { self.wiki = wiki }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.susu.MemoryPalace.catalog-recall.indexer", qos: .utility)
    private var floors: [String: Floor] = [:]

    public func ensure(profileId: String, wiki: WikiStore) {
        lock.lock()
        guard floors[profileId] == nil else { lock.unlock(); return }
        let floor = Floor(wiki: wiki)
        floors[profileId] = floor
        queue.async { [self] in
            do {
                MainThreadIO.assertOffMain(.enumerate, "CatalogRecallIndexer.ensure")
                let safe = SafeWiki.scan(wiki, memoryRoot: wiki.root.deletingLastPathComponent())
                guard safe.refused == nil else { throw CatalogRecallIndexStore.IndexError.refused }
                if try SafeWiki.itemType(wiki.root) == nil {
                    lock.withLock {
                        if floors[profileId] === floor { floors[profileId] = nil }
                    }
                    return
                }
                let store = try CatalogRecallIndexStore.open(profileId: profileId, wiki: wiki)
                try store.rebuild(snapshot: safe)
                let status = try store.status(profileId: profileId)
                lock.lock()
                if floors[profileId] === floor {
                    floor.store = store
                    floor.status = status
                }
                lock.unlock()
            } catch { record(error, profileId: profileId, floor: floor) }
        }
        lock.unlock()
    }

    public func status(profileId: String) -> CatalogRecallIndexStore.Status {
        lock.lock(); defer { lock.unlock() }
        return floors[profileId]?.status ?? .init(state: .empty, epoch: 0)
    }

    public func store(profileId: String) -> CatalogRecallIndexStore? {
        lock.lock(); defer { lock.unlock() }
        return floors[profileId]?.store
    }

    public func changed(at url: URL) {
        let path = url.standardizedFileURL.path
        lock.lock()
        for (profileId, floor) in floors {
            let prefix = floor.wiki.root.standardizedFileURL.path + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            queue.async { [self] in
                do {
                    guard let store = currentStore(profileId: profileId, floor: floor) else { return }
                    if relative.hasSuffix(".md"), WikiStore.isValidPagePath(String(relative.dropLast(3))) {
                        let epoch = try store.status(profileId: profileId).epoch
                        try store.update(paths: [String(relative.dropLast(3))], epoch: epoch)
                    } else {
                        try store.reconcile()
                    }
                } catch { record(error, profileId: profileId, floor: floor) }
            }
        }
        lock.unlock()
    }

    public func reconcile(profileId: String) async throws {
        try await perform(profileId: profileId) { try $0.reconcile() }
    }

    public func waitUntilIdle(profileId: String) async throws {
        try await perform(profileId: profileId) { _ in }
    }

    /// fallback：既没传 wiki、这层也没建过时用的楼层 wiki（app 按 profileId 算路径），只在后台队列里按需求值
    public func deleteProfile(_ profileId: String, wiki: WikiStore?, fallback: @escaping @Sendable () -> WikiStore) {
        lock.lock()
        let floor = floors.removeValue(forKey: profileId)
        queue.async {
            do {
                try floor?.store?.invalidate()
                let wiki = wiki ?? floor?.wiki ?? fallback()
                CatalogRecallIndexStore.removeFiles(at: CatalogRecallIndexStore.indexURL(wiki: wiki))
            } catch {
                print("[catalog-recall] 删层索引未关闭，保留文件：\(error)")
            }
        }
        lock.unlock()
    }

    private func currentStore(profileId: String, floor: Floor) -> CatalogRecallIndexStore? {
        lock.lock(); defer { lock.unlock() }
        return floors[profileId] === floor ? floor.store : nil
    }

    private func record(_ error: Error, profileId: String, floor: Floor) {
        lock.lock(); defer { lock.unlock() }
        guard floors[profileId] === floor else { return }
        floor.error = error
        if floor.store == nil { floor.status = .init(state: .empty, epoch: 0) }
    }

    private func perform(profileId: String, body: @escaping @Sendable (CatalogRecallIndexStore) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                lock.lock()
                let floor = floors[profileId]
                let store = floor?.store
                let error = floor?.error
                lock.unlock()
                do {
                    if let error { throw error }
                    if let store { try body(store) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
