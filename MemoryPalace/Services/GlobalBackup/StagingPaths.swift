import Foundation

// MARK: - Staging Paths
//
// 全量备份导入流程的路径常量。
//
// staging 父目录必须跟目标父目录同 volume（codex Round 2 强烈建议 #6），
// 否则 FileManager.replaceItem 跨 volume 退化成拷贝，不再原子。
//
// 设计：
// - workspace（解 zip 临时区）放 Caches/MemoryPalace/import-workspace/<uuid>/
//   崩了 OS 可能清，不影响主位
// - staging container store 放 Application Support/MemoryPalace/ 跟主 store 同目录
// - staging 文件区按 section 放各自目标父目录同 volume
// - pre-import archive 放 Application Support/MemoryPalace/pre-import-archive/<ISO>/
// - pending-import flag 放 Application Support/MemoryPalace/.pending-import.json
// - apply marker 放 Application Support/MemoryPalace/.pending-import.marker.json

enum StagingPaths {

    // MARK: - Roots

    static var applicationSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MemoryPalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var documentsRoot: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("记忆宫殿", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var cachesRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MemoryPalace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Workspace (临时解压区，可被 OS 清理)

    /// 一次性 workspace：Caches/MemoryPalace/import-workspace/<uuid>/
    static func freshWorkspace() -> URL {
        let dir = cachesRoot
            .appendingPathComponent("import-workspace", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanupAllWorkspaces() {
        let root = cachesRoot.appendingPathComponent("import-workspace", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Staging assets (跟目标父目录同 volume)

    /// staging SwiftData store（跟主 store 同目录）
    static var stagingStoreURL: URL {
        applicationSupportRoot.appendingPathComponent("unified-staging.store")
    }

    /// staging SwiftData externalStorage 目录（G-A.1.7 sentinel blob 法实测确认）
    /// 命名规则：`.<storeBasename>_SUPPORT/`（隐藏目录前缀 `.`），子目录 `_EXTERNAL_DATA` 存 blob
    /// macOS 实测：probe.store → .probe_SUPPORT/_EXTERNAL_DATA
    /// iOS 预期一致（SwiftData 同框架，但真机/模拟器需复跑一次探针确认）
    static var stagingStoreExternalURL: URL {
        applicationSupportRoot.appendingPathComponent(".unified-staging_SUPPORT", isDirectory: true)
    }

    /// 主位 SwiftData store
    static var primaryStoreURL: URL {
        applicationSupportRoot.appendingPathComponent("unified.store")
    }

    /// 主位 SwiftData externalStorage 目录（G-A.1.7 实测确认）
    static var primaryStoreExternalURL: URL {
        applicationSupportRoot.appendingPathComponent(".unified_SUPPORT", isDirectory: true)
    }

    /// staging stickers 区
    static var stagingStickersRoot: URL {
        applicationSupportRoot.appendingPathComponent("stickers-staging", isDirectory: true)
    }

    static var primaryStickersRoot: URL {
        applicationSupportRoot.appendingPathComponent("stickers", isDirectory: true)
    }

    /// staging audiobooks 区
    static var stagingAudiobooksRoot: URL {
        applicationSupportRoot.appendingPathComponent("audiobooks-staging", isDirectory: true)
    }

    static var primaryAudiobooksRoot: URL {
        applicationSupportRoot.appendingPathComponent("audiobooks", isDirectory: true)
    }

    /// staging themes 区
    static var stagingThemesRoot: URL {
        applicationSupportRoot.appendingPathComponent("themes-staging", isDirectory: true)
    }

    static var primaryThemesRoot: URL {
        applicationSupportRoot.appendingPathComponent("themes", isDirectory: true)
    }

    /// 卡库 ⑧c：身份库 / 导入来源 / 原件归档 / 未完成批次（CardLibraryStorage.defaultRoot）
    static var stagingCardLibraryRoot: URL {
        applicationSupportRoot.appendingPathComponent("cardlibrary-staging", isDirectory: true)
    }

    static var primaryCardLibraryRoot: URL {
        applicationSupportRoot.appendingPathComponent("cardlibrary", isDirectory: true)
    }

    /// staging filelibrary 区（floors-staging/，本地路径；iCloud 路径走 FileLibraryStore 拿）
    static var stagingFilelibraryRoot: URL {
        documentsRoot.appendingPathComponent("floors-staging", isDirectory: true)
    }

    static var primaryFilelibraryRoot: URL {
        documentsRoot.appendingPathComponent("floors", isDirectory: true)
    }

    /// UserDefaults staging snapshot（plist）
    static var stagingUserDefaultsURL: URL {
        applicationSupportRoot.appendingPathComponent("staging-userdefaults.plist")
    }

    // MARK: - Pending Import State

    /// staging build 完成后落的 flag
    static var pendingImportFlagURL: URL {
        applicationSupportRoot.appendingPathComponent(".pending-import.json")
    }

    /// PendingImportApplier 的 marker（记录 phase + completedSteps）
    static var pendingImportMarkerURL: URL {
        applicationSupportRoot.appendingPathComponent(".pending-import.marker.json")
    }

    // MARK: - Pre-Import Archive (Phase 1 把主位资产存这)

    /// pre-import-archive 根
    static var preImportArchiveRoot: URL {
        applicationSupportRoot.appendingPathComponent("pre-import-archive", isDirectory: true)
    }

    /// 新一次 archive 目录（用 ISO 时间戳）
    static func freshArchiveDirectory() -> URL {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = preImportArchiveRoot.appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - SQLite Sidecar Helpers (plan v2 R-2)

    /// SQLite WAL sidecar URL（`<store>-wal`，**不是 `<store>.wal`**）。
    /// codex Round 4 抓的真 bug：旧代码用 `appendingPathExtension("wal")` 拼出 `.store.wal`，永远删不到真 sidecar。
    /// codex Round 5 #10：PendingImportApplier 也复用同一 helper 避免两处写法不一致。
    static func walSidecar(of store: URL) -> URL {
        URL(fileURLWithPath: store.path + "-wal")
    }

    static func shmSidecar(of store: URL) -> URL {
        URL(fileURLWithPath: store.path + "-shm")
    }

    // MARK: - Cleanup

    /// 清所有 staging 残留（rollback 用）
    static func cleanupAllStagingArtifacts() {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingStoreURL)
        try? fm.removeItem(at: stagingStoreExternalURL)
        // codex Round 4 抓的 sidecar bug — 用 walSidecar/shmSidecar helper 拼对路径
        try? fm.removeItem(at: walSidecar(of: stagingStoreURL))
        try? fm.removeItem(at: shmSidecar(of: stagingStoreURL))
        try? fm.removeItem(at: stagingStickersRoot)
        try? fm.removeItem(at: stagingAudiobooksRoot)
        try? fm.removeItem(at: stagingThemesRoot)
        try? fm.removeItem(at: stagingCardLibraryRoot)
        try? fm.removeItem(at: stagingFilelibraryRoot)
        try? fm.removeItem(at: stagingUserDefaultsURL)
        try? fm.removeItem(at: pendingImportFlagURL)
        try? fm.removeItem(at: pendingImportMarkerURL)
    }
}
