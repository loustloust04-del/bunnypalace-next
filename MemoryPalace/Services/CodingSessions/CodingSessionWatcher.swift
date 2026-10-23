#if os(macOS)
import CoreServices
import Foundation

/// 实时增量（plan-wake-native-n1 §2.3，Wake `watcher.rs`）：FSEvents 挂各 adapter 现存的数据根。
/// - 流 latency 0 + NoDefer；800 ms 是应用层合批窗口（R-WN1 #7）
/// - 回调只记路径（在自己的串行队列上），批处理交给 `onBatch`（R-WN1 #5①）——调用方把解析放别的队列
/// - 同一文件两次重解析至少隔 3 s（她用 CC 时 jsonl 一直在写，十几 MB 的文件不能每 0.8 s 解析一遍）
/// - 丢事件（MustScanSubDirs / UserDropped / KernelDropped）→ `needsRescan`，调用方补一轮增量扫
/// - Kimi 的 `session_*/state.json`（标题所在）映射到同会话 `wire.jsonl`（R-WN1 #8）
/// - 关系边车（Grok 的 `subagents/*/meta.json`）记进 `parentLinkAgents`，调用方批末单独刷父链
final class CodingSessionWatcher: @unchecked Sendable {
    struct Batch: Sendable {
        var refs: [CodingSessionFileRef] = []
        var removedPaths: [String] = []
        var needsRescan = false
        var parentLinkAgents: Set<CodingAgent> = []

        var isEmpty: Bool { refs.isEmpty && removedPaths.isEmpty && !needsRescan && parentLinkAgents.isEmpty }
    }

    static let batchWindow: TimeInterval = 0.8
    static let reparseInterval: TimeInterval = 3

    private let queue = DispatchQueue(label: "mp.coding-sessions.watcher")
    /// real = realpath（FSEvents 报的就是它：/var/folders → /private/var/folders，探针实测）；
    /// path = adapter 枚举用的原写法——事件路径换回它，增量与全量的 file_path 才是同一个
    private let roots: [(real: String, path: String, adapter: CodingSessionAdapter)]
    private let onBatch: (Batch) -> Void
    private var stream: FSEventStreamRef?
    // 以下只在 queue 上碰
    private var pendingPaths = Set<String>()
    private var pendingRescan = false
    private var flushScheduled = false
    private var lastParsed: [String: Date] = [:]

    /// - Parameter onBatch: 在监听队列上回调；别在里面做重活
    init(adapters: [CodingSessionAdapter], onBatch: @escaping (Batch) -> Void) {
        var roots: [(String, String, CodingSessionAdapter)] = []
        for adapter in adapters {
            for root in adapter.dataRoots {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
                    roots.append((Self.realPath(root.path), root.path, adapter))
                }
            }
        }
        self.roots = roots
        self.onBatch = onBatch
    }

    deinit {
        stop()
    }

    var watchedPaths: [String] { roots.map(\.path) }

    func start() {
        guard stream == nil, !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<CodingSessionWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            watcher.record(list, flagList)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, roots.map(\.real) as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - 队列内

    private static let droppedMask = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
    )

    /// 测试入口 + FSEvents 回调：只记账，攒够窗口再批处理
    func record(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        queue.async { [self] in
            for (i, path) in paths.enumerated() {
                let flag = i < flags.count ? flags[i] : 0
                if flag & Self.droppedMask != 0 {
                    pendingRescan = true
                } else {
                    pendingPaths.insert(path)
                }
            }
            scheduleFlush(after: Self.batchWindow)
        }
    }

    private func scheduleFlush(after delay: TimeInterval) {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        var batch = Batch(needsRescan: pendingRescan)
        pendingRescan = false
        var deferred = Set<String>()
        var seen = Set<String>()
        let now = Date()
        for raw in pendingPaths {
            guard let (path, adapter) = resolve(Self.sessionFilePath(for: raw)), seen.insert(path).inserted else { continue }
            if adapter.isParentLinkEvent(path) { batch.parentLinkAgents.insert(adapter.agent) }
            guard FileManager.default.fileExists(atPath: path) else {
                batch.removedPaths.append(path)
                continue
            }
            guard let ref = adapter.fileRef(URL(fileURLWithPath: path)) else { continue }
            if let last = lastParsed[ref.filePath], now.timeIntervalSince(last) < Self.reparseInterval {
                deferred.insert(raw)
                continue
            }
            lastParsed[ref.filePath] = now
            batch.refs.append(ref)
        }
        pendingPaths = deferred
        if !deferred.isEmpty { scheduleFlush(after: Self.reparseInterval) }
        if !batch.isEmpty { onBatch(batch) }
    }

    /// 事件路径 →（adapter 枚举用的原写法路径, 归属 adapter）：realpath 形态（FSEvents）与原写法（直接喂的）都认；
    /// 取最长匹配根（自定义根可以落在别家数据树内），匹配上的前缀统一换回原写法
    private func resolve(_ eventPath: String) -> (String, CodingSessionAdapter)? {
        var best: (base: String, path: String, adapter: CodingSessionAdapter)?
        for root in roots {
            for base in [root.real, root.path] where eventPath == base || eventPath.hasPrefix(base + "/") {
                if base.count > (best?.base.count ?? -1) { best = (base, root.path, root.adapter) }
            }
        }
        guard let best else { return nil }
        return (best.path + eventPath.dropFirst(best.base.count), best.adapter)
    }

    /// realpath（解析 /var → /private/var 这类符号链接；Foundation 的 standardized / resolvingSymlinks 会反向剥掉 /private）
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Kimi 标题边车 `session_*/state.json` → 同会话主文件
    static func sessionFilePath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "state.json", url.deletingLastPathComponent().lastPathComponent.hasPrefix("session_") {
            return url.deletingLastPathComponent().appendingPathComponent("agents/main/wire.jsonl").path
        }
        return path
    }
}
#endif
