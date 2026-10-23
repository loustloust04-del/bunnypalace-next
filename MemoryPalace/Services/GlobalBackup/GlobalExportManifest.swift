import Foundation
import UniformTypeIdentifiers

// MARK: - Global Export Manifest (.mpb schemaVersion = 4)
//
// 全量备份单文件包 (.mpb = ZIP) 的根 manifest schema。
// 见 docs/plan-global-export.md v4。
//
// v4 跟 v1/v2/v3 不兼容（v1 是未合的 feature/global-backup 老分支；v2/v3 是 plan 迭代中
// 设计修正版本，未真发布过包 → importer 直接拒绝 v1/v2/v3 安全 break）。
//
// 启动期 PendingImportApplier 在 makeUnifiedContainer 之前比对 appBuild 和 schemaFingerprint，
// 不匹配 → 拒绝 apply（防"用户在 build A 写包，升级 build B 后导入"翻车）。

enum GlobalExportConstants {
    static let schemaVersion: Int = 4
    static let kind: String = "global-export"
    static let fileExtension: String = "mpb"
    /// 自定义 UTI；macOS Info.plist + iOS Info-iOS.plist 注册（G-E 阶段）
    static let utiIdentifier: String = "com.susu.MemoryPalace.backup"
}

extension UTType {
    /// `.mpb` 自定义 UTI；继承 public.zip-archive，归档器能打开
    static let memoryPalaceBackup: UTType = UTType(
        exportedAs: GlobalExportConstants.utiIdentifier,
        conformingTo: .zip
    )
}

struct GlobalExportManifest: Codable {
    let schemaVersion: Int
    let kind: String
    let appVersion: String          // CFBundleShortVersionString
    let appBuild: String            // CFBundleVersion — 启动 apply 前比对
    let schemaFingerprint: String   // fullSchema 字段清单 sha256 — 启动 apply 前比对
    let exportedAt: Date
    let device: String
    let stats: Stats
    let includes: Includes
    let profileIds: [String]
    /// profileId → floorSlug；还原时写回 UserDefaults `fileLibraryLocalDocumentsSlugMapV1`
    let floorSlugs: [String: String]
    /// 每 section canonical sha256；wipe/staging 前校验包完整
    let sections: [SectionEntry]

    struct Stats: Codable {
        let profileCount: Int
        let conversationCount: Int
        let messageNodeCount: Int
        let memoryNoteCount: Int
        let memoryCount: Int
        let worldBookCount: Int
        let userCardCount: Int
        let tagCount: Int
        let favoriteCount: Int
        let importRecordCount: Int
        let importChangeCount: Int
        let bookEntryCount: Int
        let audiobookCount: Int
        let audiobookBookmarkCount: Int
        let stickerAssetCount: Int
        let stickerAssetBytes: Int
        let placedStickerCount: Int
        let characterCardCount: Int
        let backgroundImageCount: Int
        let audiobookFileBytes: Int
        let filesystemFileCount: Int
        let uncompressedBytes: Int
    }

    struct Includes: Codable {
        let memoryTree: Bool
        let characterCards: Bool
        let backgroundImages: Bool
        let stickerAssets: Bool
        let audiobookFiles: Bool
    }

    struct SectionEntry: Codable {
        let path: String        // 包内相对路径
        let sha256: String      // canonical hash (见 SectionHasher)
        let bytes: Int
    }
}

extension GlobalExportManifest {
    /// 当前 app 的 appVersion / appBuild
    static func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static func currentAppBuild() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}
