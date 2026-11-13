#if DEBUG
import Foundation
import MemoryCore
import SwiftData

/// 自用（只在 Debug 菜单）：把本楼层全部对话导出成 memoryd 可读的楼层快照（plan-memory-core-extract-2 §2.3 / E2-6）。
/// 只读 `SwiftDataConversationSource`（不直接 fetch 对话模型），文件只落在楼层 `memory/exports/`。
/// 导出的是整楼层原文（含回收站 / 隐藏 / 软删），所以别把 `exports/` 带进备份或同步。
enum FloorSnapshotExport {
    static func export(profileId: String, container: ModelContainer, memoryRoot: URL,
                       now: Date = Date()) throws -> (url: URL, windows: Int, nodes: Int) {
        let source = SwiftDataConversationSource(container: container)
        var windows: [FloorSnapshot.Window] = []
        var nodeCount = 0
        for window in try source.windows(profileId: profileId, updatedSince: nil, includeTrashed: true) {
            let nodes = try source.nodes(profileId: profileId, conversationId: window.id)
            nodeCount += nodes.count
            let selection = window.branchSelection.flatMap { data -> [String: String]? in
                let decoded = BranchSelection.decode(data)
                return decoded.isEmpty ? nil : decoded
            }
            windows.append(FloorSnapshot.Window(
                id: window.id, title: window.title, current: window.currentNodeId,
                memoryEnabled: window.memoryEnabled, trashed: window.isTrashed,
                nodes: nodes.map { node($0) },
                profileId: window.profileId, createTime: window.createTime, updateTime: window.updateTime,
                branchSelection: selection, isCC: window.isCC, lastRealChatAt: window.lastRealChatAt,
                provider: window.provider, importBatchId: window.importBatchId,
                archiveKind: window.archiveKind))
        }
        let snapshot = FloorSnapshot(windows: windows, schema: FloorSnapshot.currentSchema,
                                     exportedAt: now, profileId: profileId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)

        let dir = memoryRoot.appendingPathComponent(FloorSnapshotExportFolder.name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(FloorSnapshotExportFolder.filePrefix + stamp(now) + ".json")
        // 先写临时文件再落位：中途失败不留半份
        let tmp = dir.appendingPathComponent(".tmp-" + UUID().uuidString + ".json")
        try data.write(to: tmp, options: .atomic)
        do {
            // 同一秒连导第二次：目标同名，直接 move 会失败 → 原子替换旧文件
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        prune(in: dir)
        return (url, windows.count, nodeCount)
    }

    /// 每次导出都是整楼层原文：只留最新 2 份（按文件名字典序 = 时间序），多的删。
    /// 只碰严格匹配时间戳名、普通文件、非符号链接的项：目录 / 链接 / 别的名字一概不动。
    private static func prune(in dir: URL, keeping limit: Int = 2) {
        let fm = FileManager.default
        let candidates = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter(FloorSnapshotExportFolder.isSnapshotFileName)
            .compactMap { name -> (name: String, url: URL)? in
                let url = dir.appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return (name, url)
            }
            .sorted { $0.name < $1.name }
        for item in candidates.dropLast(limit) {
            try? fm.removeItem(at: item.url)
        }
    }

    /// 快照节点：字段照 schema 2；`at` 原样带消息时间（nil 就写 nil，不再填窗口时间）
    private static func node(_ message: ConversationMessage) -> FloorSnapshot.Node {
        FloorSnapshot.Node(
            id: message.id, role: message.role, text: message.content,
            at: message.createTime, parent: message.parentId,
            hidden: message.isSourceHidden, deleted: message.isTrashed,
            contentType: message.contentType, segments: message.segments,
            isSyntheticRoot: message.isSyntheticRoot, sourceVisibility: message.sourceVisibility,
            ccMessageId: message.ccMessageId, childrenIds: message.childrenIds,
            cardEditedAt: message.cardEditedAt, ccEdited: message.ccEdited)
    }

    /// 文件名里的时间戳（UTC，秒级 + `Z`）：`floor-snapshot-20261108-153012Z.json`。
    /// 不用本地时区：往西跨时区 / 夏令时回拨那 1 小时里，新文件的字典序可能小于旧文件，memoryd 会取错。
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return formatter.string(from: date)
    }
}
#endif
