import Foundation

/// widget 端读 App Group 里的 CC 用量快照。写入端是主 app 的 `UsageSnapshotWriter`，
/// wire 结构共用 `UsageSnapshot`（LiveActivityShared/），不再各写一份。
/// 任何一步失败 → nil → 每种形态显示 `--`（不是 0）。
enum UsageSnapshotStore {
    private static let appGroupId = "group.com.susu.MemoryPalace"

    static func read() -> UsageSnapshot? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return nil
        }
        let url = base.appendingPathComponent("usage-snapshot/latest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }
}
