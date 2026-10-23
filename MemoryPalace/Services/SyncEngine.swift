import Foundation
import SwiftData

/// S2.5 准实时同步引擎（plan-cross-device-sync）。
/// - 导出泵：前台每 5s 跑一次指纹增量导出（无变化 = 轻量 fetch + 比较，近零成本；连续空转自动降频）
/// - 云端监听：NSMetadataQuery（iOS）+ DispatchSource 目录监听（Mac）双通道，对端文档一到货 debounce 自动导入
/// 上限被 iCloud 传输卡死（秒~几十秒），手动「立即同步」仍保留为强制档。
@MainActor
final class SyncEngine: NSObject {
    static let shared = SyncEngine()

    private var container: ModelContainer?
    private var profileId: String?
    private var exportTimer: Timer?
    private var metadataQuery: NSMetadataQuery?
    private var importDebounce: Timer?
    private var busy = false
    private var idleCount = 0
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFd: Int32 = -1
    private var dirSuspended = false

    /// 幂等：楼层切换/开关重开直接重 start
    func start(profileId: String, container: ModelContainer) {
        stop()
        guard !TestHostIsolation.active, NSClassFromString("XCTestCase") == nil else { return }
        guard SyncStore.isEnabled(profileId: profileId) else { return }
        self.profileId = profileId
        self.container = container

        FileLibraryStore.primeICloudContainer { [weak self] available in
            guard let self, self.profileId == profileId else { return }
            guard available else {
                SyncProbe.log("engine ABORT floor=\(profileId.prefix(12)) — iCloud 容器不可用")
                return
            }
            SyncProbe.log("engine START floor=\(profileId.prefix(12))")

            self.exportTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pump(exportOnly: false) }
            }

            self.startMetadataQuery()
            self.startDirectoryMonitor()
            self.pump(exportOnly: false)
        }
    }

    func stop() {
        exportTimer?.invalidate()
        exportTimer = nil
        importDebounce?.invalidate()
        importDebounce = nil
        if let query = metadataQuery {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        }
        metadataQuery = nil
        if let ds = dirSource {
            if dirSuspended { ds.resume() }
            ds.cancel()
        }
        dirSource = nil
        dirSuspended = false
        profileId = nil
        container = nil
        idleCount = 0
    }

    // MARK: - 云端监听（iOS 主力）

    private func startMetadataQuery() {
        guard let profileId else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K LIKE '*.json' AND %K CONTAINS %@",
            NSMetadataItemFSNameKey, NSMetadataItemPathKey, "/sync/\(profileId)/"
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: .NSMetadataQueryDidUpdate, object: query
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(cloudChanged),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )
        metadataQuery = query
        query.start()
    }

    @objc private func cloudChanged(_ note: Notification) {
        SyncProbe.log("cloud EVENT \(note.name == .NSMetadataQueryDidFinishGathering ? "gathered" : "update")")
        scheduleImport()
    }

    // MARK: - 目录监听（Mac 主力 — kqueue 不需要 iCloud entitlement）

    private func startDirectoryMonitor() {
        #if os(macOS)
        guard let pid = profileId,
              let root = SyncStore.syncRoot(profileId: pid) else { return }
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            SyncProbe.log("fs EVENT dir-write")
            self?.scheduleImport()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
        dirFd = fd
        #endif
    }

    // MARK: - Debounce 共用入口

    private func scheduleImport() {
        // 自己导出也会写目录触发 fs EVENT，跳过 busy 期间的事件避免回声循环
        guard !busy else { return }
        importDebounce?.invalidate()
        importDebounce = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.pump(exportOnly: false, eventDriven: true) }
        }
    }

    // MARK: - 泵

    /// 恢复后首泵 flag 消费（PendingImportApplier P2.10 写入；读到即清，只生效一次）
    static func consumeFirstPumpExportOnly() -> Bool {
        guard UserDefaults.standard.bool(forKey: SyncStore.firstPumpExportOnlyKey) else { return false }
        UserDefaults.standard.removeObject(forKey: SyncStore.firstPumpExportOnlyKey)
        return true
    }

    private func pump(exportOnly: Bool, eventDriven: Bool = false) {
        guard !busy, let profileId, let container else { return }
        guard SyncStore.isEnabled(profileId: profileId) else { stop(); return }
        // 空转降频：连续 6 轮无实质变化 → Timer 驱动的导入跳过。
        // 导出永远跑（本地发消息不触发任何 EVENT，全靠 Timer 捕获）。
        // EVENT 驱动（FS/cloud 事件）始终放行——有新文件到了值得查。
        var skipImport = !eventDriven && idleCount >= 6
        // 恢复后首泵只出不进：先把主位（恢复后状态）全量刷上云端再开 import，
        // 缩小其他设备读到旧云端的窗口（纪元闸之外的双保险，plan-fix-ios-import-impl H2）
        if SyncEngine.consumeFirstPumpExportOnly() { skipImport = true }
        busy = true
        let pid = profileId
        // 导出写文件会触发 DispatchSource → 回声循环，泵期间挂起监听
        if !dirSuspended { dirSource?.suspend(); dirSuspended = true }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let context = ModelContext(container)
            // [probe-5a] SyncEngine pump 之前 — 看 SyncEngine 启动时主位 nodeCount
            let probe5aNodes = (try? context.fetchCount(FetchDescriptor<MessageNode>())) ?? -1
            let probe5aConvs = (try? context.fetchCount(FetchDescriptor<Conversation>())) ?? -1
            NSLog("[probe-5a] SyncEngine pump start (pid=\(pid)): nodes=\(probe5aNodes) convs=\(probe5aConvs) skipImport=\(skipImport)")

            var imported = SyncStore.ImportResult()
            if !skipImport {
                imported = SyncStore.importAll(profileId: pid, context: context)
            }
            let exported = SyncStore.exportChanged(profileId: pid, context: context)
            // [probe-5b] SyncEngine pump 之后 — 看 import 是否反灌
            let probe5bNodes = (try? context.fetchCount(FetchDescriptor<MessageNode>())) ?? -1
            let probe5bConvs = (try? context.fetchCount(FetchDescriptor<Conversation>())) ?? -1
            NSLog("[probe-5b] SyncEngine pump done (pid=\(pid)): nodes=\(probe5bNodes) convs=\(probe5bConvs) imp.nodes=\(imported.nodesInserted) imp.conv+=\(imported.conversationsCreated) imp.conv~=\(imported.conversationsUpdated) exp=\(exported.exported)")
            let hadWork = exported.exported > 0
                || imported.nodesInserted > 0
                || imported.conversationsCreated > 0
                || imported.conversationsUpdated > 0
            Task { @MainActor in
                guard let self else { return }
                if self.dirSuspended { self.dirSource?.resume(); self.dirSuspended = false }
                self.busy = false
                if hadWork {
                    self.idleCount = 0
                    NotificationCenter.default.post(name: .syncDidImport, object: nil)
                } else {
                    self.idleCount += 1
                }
            }
        }
    }
}

extension Notification.Name {
    static let syncDidImport = Notification.Name("syncDidImport")
}
