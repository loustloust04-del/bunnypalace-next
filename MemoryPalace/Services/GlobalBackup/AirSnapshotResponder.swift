#if DEBUG
import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - AirSnapshotResponder（research-backup-while-open §3.1，粟粟 11-06 拍板 1：只进 Debug）
//
// scripts/air-backup.py 用 devicectl 往容器丢请求，app 在后台串行队列上做一致快照（StoreSnapshotter），她照常用。
// 只在 iOS 接线（App.init 里 start）；类本身两端都编，好在 mac 单测里测。
// 目录 Application Support/MemoryPalace/air-snapshot/：
//   requests/<id>.request   Mac 写：要一份快照；做完 / 失败后删
//   requests/<id>.release   Mac 写：拉完了（或不要了），删 <id>/
//   .tmp-<id>/              做的过程中；rename 成 <id>/ = 完成
//   <id>/                   成品：unified.store + .unified_SUPPORT/ + snapshot.json；release 或 2 小时后删
//   <id>.failed.json        做不成的原因（air-backup 拉去报）；2 小时后删

final class AirSnapshotResponder: @unchecked Sendable {

    struct Failure: Codable, Equatable {
        var id: String
        var reason: String
        var at: String
    }

    static let shared = AirSnapshotResponder(root: StagingPaths.airSnapshotRoot,
                                             store: StagingPaths.primaryStoreURL,
                                             external: StagingPaths.primaryStoreExternalURL)
    static let maxAge: TimeInterval = 2 * 3600
    static let pollInterval: TimeInterval = 3

    let root: URL
    let store: URL
    let external: URL
    var requests: URL { root.appendingPathComponent("requests", isDirectory: true) }

    var appBuild: () -> String = { PreUpgradeSnapshot.BuildStamp.current.description }
    var fingerprint: () -> String = { SchemaCoverageCheck.fingerprint() }
    var freeBytes: (URL) -> Int64? = StoreSnapshotter.volumeFreeBytes
    var now: () -> Date = Date.init

    private let queue = DispatchQueue(label: "com.susu.MemoryPalace.air-snapshot", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var started = false

    init(root: URL, store: URL, external: URL) {
        self.root = root
        self.store = store
        self.external = external
    }

    /// 主线程调，幂等：建目录、监听 requests/（目录变动 + 3 秒兜底轮询）。第一次轮询顺手清掉上次残留的 .tmp-
    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        let fd = open(requests.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: queue)
            src.setEventHandler { [weak self] in self?.processPending() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.processPending() }
        t.resume()
        timer = t
    }

    /// 串行队列上跑（测试直接调）：先处理 release，再清过期 / 残留，最后最多做一份快照——
    /// 同时有好几个请求只做最新的，旧的记「被取代」。在这个队列上跑时不会有快照在做，所以见到的 .tmp- 都是残留。
    func processPending() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: requests.path)) ?? []

        for name in names where name.hasSuffix(".release") {
            let id = String(name.dropLast(".release".count))
            if Self.isValid(id) {
                try? fm.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
                try? fm.removeItem(at: failureURL(id))
                try? fm.removeItem(at: requests.appendingPathComponent(id + ".request"))
            }
            try? fm.removeItem(at: requests.appendingPathComponent(name))
        }

        cleanup()

        var pending: [(id: String, at: Date)] = []
        for name in (try? fm.contentsOfDirectory(atPath: requests.path)) ?? [] where name.hasSuffix(".request") {
            let id = String(name.dropLast(".request".count))
            let url = requests.appendingPathComponent(name)
            guard Self.isValid(id),
                  !fm.fileExists(atPath: root.appendingPathComponent(id).path),
                  !fm.fileExists(atPath: failureURL(id).path) else {
                try? fm.removeItem(at: url)
                continue
            }
            pending.append((id, modificationDate(url) ?? .distantPast))
        }
        pending.sort { ($0.at, $0.id) < ($1.at, $1.id) }
        guard let newest = pending.last else { return }
        for old in pending.dropLast() {
            writeFailure(old.id, reason: "被更新的请求 \(newest.id) 取代")
            try? fm.removeItem(at: requests.appendingPathComponent(old.id + ".request"))
        }

        let task = beginBackgroundWork()
        defer { endBackgroundWork(task) }
        do {
            let manifest = try StoreSnapshotter.snapshot(store: store, external: external, root: root, id: newest.id,
                                                         appBuild: appBuild(), fingerprint: fingerprint(), freeBytes: freeBytes)
            print("[air-snapshot] \(manifest.id) ok：\(manifest.storeBytes) 字节，外置 \(manifest.externalFiles) 个，\(manifest.durationMs) ms")
        } catch {
            writeFailure(newest.id, reason: error.localizedDescription)
            print("[air-snapshot] \(newest.id) 失败：\(error.localizedDescription)")
        }
        try? fm.removeItem(at: requests.appendingPathComponent(newest.id + ".request"))
    }

    // MARK: - Helpers

    /// id 只准字母数字 - _（devicectl 传进来的文件名，拼路径前先挡）
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    func failureURL(_ id: String) -> URL {
        root.appendingPathComponent(id + ".failed.json")
    }

    private func cleanup() {
        let fm = FileManager.default
        let current = now()
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name != "requests" {
            let url = root.appendingPathComponent(name)
            if name.hasPrefix(StoreSnapshotter.tmpPrefix) {
                try? fm.removeItem(at: url)
            } else if let at = modificationDate(url), current.timeIntervalSince(at) > Self.maxAge {
                try? fm.removeItem(at: url)
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: requests.path)) ?? [] {
            let url = requests.appendingPathComponent(name)
            if let at = modificationDate(url), current.timeIntervalSince(at) > Self.maxAge {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func writeFailure(_ id: String, reason: String) {
        let failure = Failure(id: id, reason: reason, at: StoreSnapshotter.isoString(now()))
        try? JSONEncoder().encode(failure).write(to: failureURL(id), options: .atomic)
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    #if os(iOS)
    private func beginBackgroundWork() -> UIBackgroundTaskIdentifier {
        onMain {
            var task = UIBackgroundTaskIdentifier.invalid
            // 到点还没做完就放掉：进程被杀后 .tmp- 留着，下次启动清；air-backup 那边超时判 ❌
            task = UIApplication.shared.beginBackgroundTask(withName: "air-snapshot") { UIApplication.shared.endBackgroundTask(task) }
            return task
        }
    }

    private func endBackgroundWork(_ task: UIBackgroundTaskIdentifier) {
        guard task != .invalid else { return }
        onMain { UIApplication.shared.endBackgroundTask(task) }
    }

    private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
    #else
    private func beginBackgroundWork() -> Int { 0 }
    private func endBackgroundWork(_ task: Int) {}
    #endif
}
#endif
