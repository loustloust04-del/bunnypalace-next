import Foundation

/// 一次导入的清单（#061 B 期）：哪个文件去了哪、跳过了哪些、文件库写到哪。
/// 存在 `ImportRecord.detailData`（外部存储），详情页按「来源文件」分组显示。
/// 一条记录一份：同一次导入分成几条记录（每个来源一条 + Claude 一条）时，包名 / 没导入的类别每份都抄一遍。
struct ImportManifest: Codable, Equatable {
    /// 跳过 / 冲突这类列表只记前这么多段，多的只计数
    static let listLimit = 200

    struct Ref: Codable, Equatable {
        let id: String
        let title: String
    }

    struct ConflictRef: Codable, Equatable {
        let id: String
        let title: String
        let profileId: String
        /// 导入当时的楼层名；楼层已删 = nil
        let floorName: String?
        let trashed: Bool
    }

    struct LibraryItem: Codable, Equatable {
        let path: String
        /// 没写进去的原因（同名已有 / 写失败的错误 / 不是文本…）；写进去了 = nil
        var reason: String?
    }

    enum Kind: String, Codable {
        case conversations, designChats, projects, memories, library
    }

    struct Source: Codable, Equatable {
        /// 「包名 › 包内路径」
        var label: String
        var kind: Kind
        /// 新建 / 更新 / 复制成副本的对话 id（全量，详情页回查标题）
        var created: [String] = []
        var updated: [String] = []
        var copied: [String] = []
        var skipped: [Ref] = []
        var skippedCount = 0
        var conflicts: [ConflictRef] = []
        var conflictCount = 0
        /// 空白草稿 / 没有有效内容 / 读不出来：总数 + 前 200 段的位置「第 N 段」
        var emptyCount = 0
        var empty: [String] = []
        /// 前面的文件已经有、合进去的
        var mergedDuplicates = 0
        var foldersCreated: [Ref] = []
        var foldersExisting: [Ref] = []
        var memoriesAdded = 0
        var memoriesExisting = 0
        var library: [LibraryItem] = []

        init(label: String, kind: Kind) {
            self.label = label
            self.kind = kind
        }

        var isEmpty: Bool {
            created.isEmpty && updated.isEmpty && copied.isEmpty && skippedCount == 0 && conflictCount == 0
                && emptyCount == 0 && mergedDuplicates == 0 && foldersCreated.isEmpty && foldersExisting.isEmpty
                && memoriesAdded == 0 && memoriesExisting == 0 && library.isEmpty
        }
    }

    struct Failure: Codable, Equatable {
        let step: String
        let message: String
    }

    var packages: [String] = []
    var sources: [Source] = []
    /// 按设计不导的类别、清单里有但没选到的、没认出来的、空文件（一行一条，已经是给人看的话）
    var notIncluded: [String] = []
    var failures: [Failure] = []

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data?) -> ImportManifest? {
        data.flatMap { try? JSONDecoder().decode(ImportManifest.self, from: $0) }
    }

    /// 包级说明（每条记录都抄一份）。unchecked：包里有、这次没勾的类别（sol #6）
    static func notIncluded(_ scan: ExportPackageScan, unchecked: [String] = [], extraIgnored: [String] = []) -> [String] {
        var out: [String] = []
        if !unchecked.isEmpty { out.append("这次没勾：\(unchecked.joined(separator: "、"))") }
        let ignored = scan.ignoredLabels + extraIgnored
        if !ignored.isEmpty { out.append("按设计不导：\(ignored.joined(separator: "、"))") }
        if !scan.missingFromManifest.isEmpty { out.append("清单里有、但这次没选到：\(scan.missingFromManifest.joined(separator: "、"))") }
        if !scan.unrecognized.isEmpty { out.append("没认出来：\(scan.unrecognized.joined(separator: "、"))") }
        if !scan.emptyFiles.isEmpty { out.append("空文件：\(scan.emptyFiles.joined(separator: "、"))") }
        return out
    }
}
