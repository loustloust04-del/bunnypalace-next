#if os(iOS)
import Foundation
import WidgetKit

/// App Group 共享的「CC 用量快照」写入端。每收到一帧 `terminal_usage` 覆盖一次。
/// 读取端是 widget extension 的 `UsageSnapshotStore`；两边共用 `UsageSnapshot`（LiveActivityShared/）。
///
/// 落盘：group.com.susu.MemoryPalace/usage-snapshot/latest.json（覆盖式，只留最新一份）
///
/// 静态 widget 的 TimelineProvider 撑不住常驻 WS，所以它显示的必然是「上次 app 开着时的数字」——
/// 每种形态都显式标 x MIN AGO，宁可诚实地旧。
enum UsageSnapshotWriter {
    static let appGroupId = "group.com.susu.MemoryPalace"

    private static let queue = DispatchQueue(label: "usage-snapshot-writer", qos: .utility)

    private static var fileURL: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            // App Group 没配 → 静默失败；widget 读不到就显示 `--`，合理
            return nil
        }
        let dir = base.appendingPathComponent("usage-snapshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("latest.json")
    }

    static func write(
        sessionName: String,
        model: String?,
        ctx: Int?,
        fiveHour: Int?,
        sevenDay: Int?
    ) {
        let snapshot = UsageSnapshot(
            sessionName: sessionName,
            model: model,
            ctx: ctx,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            updatedUnix: Int(Date().timeIntervalSince1970)
        )
        queue.async {
            guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: LiveActivityKinds.usageWidget)
        }
    }
}
#endif
