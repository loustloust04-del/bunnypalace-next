import Foundation
import SwiftData

/// 预览页先查「这次要导的对话有多少已经在别的楼层」（#061）。只按对话 id 查；
/// 对话 id 不撞、节点 id 撞的预览算不到，写库时照样跳过，完成页为准。
struct ImportConflictReport: Equatable {
    struct Floor: Equatable {
        let profileId: String
        var count = 0
        /// 其中在那边回收站里的
        var trashed = 0
    }

    /// 按段数从多到少
    var floors: [Floor] = []
    /// 本楼层已经有副本（`#c-`）的：选复制也不会再多一份
    var copiedHere = 0

    var total: Int { floors.reduce(0) { $0 + $1.count } }
    var isEmpty: Bool { floors.isEmpty }

    /// 几个来源的报告并成一份（预览按勾选合）
    static func merged(_ reports: [ImportConflictReport]) -> ImportConflictReport {
        var byFloor: [String: Floor] = [:]
        var copied = 0
        for report in reports {
            copied += report.copiedHere
            for floor in report.floors {
                var f = byFloor[floor.profileId] ?? Floor(profileId: floor.profileId)
                f.count += floor.count
                f.trashed += floor.trashed
                byFloor[floor.profileId] = f
            }
        }
        return ImportConflictReport(floors: sorted(Array(byFloor.values)), copiedHere: copied)
    }

    fileprivate static func sorted(_ floors: [Floor]) -> [Floor] {
        floors.sorted { $0.count != $1.count ? $0.count > $1.count : $0.profileId < $1.profileId }
    }
}

enum ImportConflictProbe {
    private static let batchSize = 500

    static func probe(ids: [String], currentProfileId: String, context: ModelContext) throws -> ImportConflictReport {
        let unique = Array(Set(ids))
        let hits = try crossProfileConversationHits(unique, currentProfileId: currentProfileId, in: context)
        guard !hits.isEmpty else { return ImportConflictReport() }
        var byFloor: [String: ImportConflictReport.Floor] = [:]
        for hit in hits.values {
            var f = byFloor[hit.profileId] ?? .init(profileId: hit.profileId)
            f.count += 1
            if hit.trashed { f.trashed += 1 }
            byFloor[hit.profileId] = f
        }
        let copyIds = hits.keys.map { copyId($0, profileId: currentProfileId) }
        var copied = 0
        let pid = currentProfileId
        for start in stride(from: 0, to: copyIds.count, by: batchSize) {
            let chunk = Array(copyIds[start..<min(start + batchSize, copyIds.count)])
            copied += try context.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate {
                chunk.contains($0.id) && $0.profileId == pid
            }))
        }
        return ImportConflictReport(floors: ImportConflictReport.sorted(Array(byFloor.values)), copiedHere: copied)
    }
}
