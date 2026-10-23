import Foundation

/// guest 写事件 → `.fileLibraryDidChange`（plan §1.5，T3b）。
///
/// fakefs 的 change ring 是「每次 write/unlink/rename/truncate 都记一条」，
/// `echo hello > x` 这种一条命令就可能产生多条（open+write+close 各自触发）。
/// 直接转成通知会让文件库面板一秒刷十几次，所以这里做**时间窗合并**：
/// 窗口内的事件攒着，窗口到点只 post 一次。
enum SandboxChangeNotifier {

    /// 合并窗口。R12 那批面板刷新是「看到就行」的语义，200ms 足够跟手又不抖。
    static let throttleInterval: TimeInterval = 0.2

    private static let lock = NSLock()
    private static var pending: Set<String> = []
    private static var scheduled = false
    private static var installed = false

    /// 探针用：本进程一共 post 了几次通知（不是收到几条事件）
    private(set) static var postCount = 0
    /// 探针用：一共收到几条原始事件（去重前的批次条数之和）
    private(set) static var eventCount = 0

    /// boot 之后、任何 bind mount 之前装一次。重复调用是 no-op。
    static func installIfNeeded() {
        lock.lock()
        guard !installed else { lock.unlock(); return }
        installed = true
        lock.unlock()

        SandboxChangeBridge.install { paths in
            // 这里是 fakefs 的串行队列，别做重活
            lock.lock()
            eventCount += paths.count
            // 只关心挂进来的文件库；guest 自己在 /tmp、/root 里折腾不该惊动文件库面板
            let interesting = paths.filter { $0.hasPrefix(SandboxMount.libraryRoot + "/") }
            guard !interesting.isEmpty else { lock.unlock(); return }
            pending.formUnion(interesting)
            let needSchedule = !scheduled
            if needSchedule { scheduled = true }
            lock.unlock()

            guard needSchedule else { return }   // 窗口已经排好了，攒进 pending 就行
            DispatchQueue.main.asyncAfter(deadline: .now() + throttleInterval) { flush() }
        }
        print("[SandboxChangeNotifier] change consumer 已安装")
    }

    @MainActor
    private static func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        scheduled = false
        guard !batch.isEmpty else { lock.unlock(); return }
        postCount += 1
        let count = postCount
        lock.unlock()

        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
        print("[SandboxChangeNotifier] post #\(count) 合并了 \(batch.count) 条路径")
    }

    /// 探针用：读计数并清零
    static func drainCounters() -> (events: Int, posts: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (eventCount, postCount)
        eventCount = 0; postCount = 0
        return r
    }

    static var droppedCount: UInt64 { SandboxChangeBridge.droppedCount() }
}
