import Foundation

// MARK: - Placeholder Materializer
//
// 通用 iCloud placeholder 处理（codex Round 2 强烈建议 #6）。
// 不复用 SyncStore.materializeDocuments — 那个 private 且只筛 .json，文件库/有声书/贴纸
// 是任意扩展，要自己写通用版。
//
// 设计：
// - 对每个 URL 检查 isUbiquitousItemKey / .ubiquitousItemDownloadingStatusKey
// - 状态不是 .current → startDownloadingUbiquitousItem + 短轮询（200ms × 30s = 150 次）
// - 超时 → 抛 placeholderTimeout
// - 整体 Task.checkCancellation()：用户在 GlobalExportSheet 关 sheet → cancel 这个 task
// - v1 UI 不暴露取消按钮；但底层接收 cancellation
//
// 用法：
//   try await PlaceholderMaterializer.materialize(filesUnder: url, recursive: true)
//
// 跑在调用方 Task 里；自身不 spawn task。

enum PlaceholderMaterializer {

    /// 单文件超时
    static let perFileTimeoutMs: Int = 30_000
    /// 轮询间隔
    static let pollIntervalMs: Int = 200

    /// 递归 materialize 一个目录下所有 placeholder。
    /// 调用方负责包在 Task 里 + 处理 Task.checkCancellation。
    static func materialize(filesUnder root: URL, recursive: Bool = true) async throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }

        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .isDirectoryKey
        ]

        if recursive {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else { return }

            while let next = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                try await materializeIfNeeded(url: next, keys: keys)
            }
        } else {
            try await materializeIfNeeded(url: root, keys: keys)
        }
    }

    private static func materializeIfNeeded(url: URL, keys: Set<URLResourceKey>) async throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            // 没法读元数据，跳过（一般是 sandbox 拒绝）
            return
        }

        // 目录本身不下载（递归会处理内容）
        if values.isDirectory == true { return }

        // 非 iCloud 文件不需要 materialize
        if values.isUbiquitousItem != true { return }

        let status = values.ubiquitousItemDownloadingStatus
        if status == .current { return }   // 已就绪

        // 触发下载
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw GlobalBackupError.ioFailed(url, error)
        }

        // 轮询等就绪
        let maxPolls = perFileTimeoutMs / pollIntervalMs
        for _ in 0..<maxPolls {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(pollIntervalMs) * 1_000_000)
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if v?.ubiquitousItemDownloadingStatus == .current {
                return
            }
        }

        throw GlobalBackupError.ioFailed(url, NSError(
            domain: "GlobalBackup.PlaceholderMaterializer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "iCloud 文件下载超时 (>\(perFileTimeoutMs)ms)"]
        ))
    }
}
