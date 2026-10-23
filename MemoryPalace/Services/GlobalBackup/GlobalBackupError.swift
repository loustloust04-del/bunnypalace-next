import Foundation

// MARK: - Global Backup Error
//
// 统一的错误类型 + 用户可见文案。
// UI 层（GlobalExportSheet / GlobalImportSheet / PendingImportSplashView）直接拿
// errorDescription 渲染。

enum GlobalBackupError: LocalizedError {

    // 导出
    case exportConfigFailed(Error)
    case exportSwiftDataFailed(Error)
    case exportFileCopyFailed(URL, Error)
    case packZipFailed(Error)
    case insufficientDiskSpace(needBytes: Int, freeBytes: Int)

    // 导入 - 校验
    case malformedManifest(String)
    case unsupportedSchemaVersion(Int)
    case rejectedV1V2V3SchemaVersion(Int)
    case appBuildMismatch(packBuild: String, currentBuild: String)
    case schemaFingerprintMismatch
    case sectionChecksumMismatch(path: String)
    case fullDocumentDecodeFailed(path: String, Error)

    // 导入 - staging
    case extractFailed(Error)
    case stagingContainerFailed(Error)
    case walCheckpointFailed(URL)
    case walStillExistsAfterCheckpoint(URL)
    case stagingFileCopyFailed(URL, Error)
    case commitFlagWriteFailed(Error)

    // 导入 - pending apply
    case pendingMarkerWriteFailed(Error)
    case phase1MoveFailed(step: String, Error)
    case phase2MoveFailed(step: String, Error)
    case reverseRollbackFailed(step: String, Error)

    // 导入 - 硬校验（plan v2 R-1/R-4 红线）
    case stagingValidationFailed(String)
    case primaryValidationFailed(String)
    case sqliteVerifierFailed(URL, String)

    // 通用
    case userCancelled
    case ioFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .exportConfigFailed(let e):
            return "导出设置失败: \(e.localizedDescription)"
        case .exportSwiftDataFailed(let e):
            return "导出对话/记忆失败: \(e.localizedDescription)"
        case .exportFileCopyFailed(let url, let e):
            return "导出文件 \(url.lastPathComponent) 失败: \(e.localizedDescription)"
        case .packZipFailed(let e):
            return "打包 zip 失败: \(e.localizedDescription)"
        case .insufficientDiskSpace(let need, let free):
            return "磁盘空间不足。需要 ~\(need / 1_048_576) MB，剩余 \(free / 1_048_576) MB。"

        case .malformedManifest(let s):
            return "包损坏: \(s)"
        case .unsupportedSchemaVersion(let v):
            return "此备份来自更新版本（schemaVersion=\(v)），请升级 app 后重试。"
        case .rejectedV1V2V3SchemaVersion(let v):
            return "此备份来自不兼容的早期版本（schemaVersion=\(v)），无法导入。"
        case .appBuildMismatch(let pack, let cur):
            return "包是 build \(pack) 写的，当前 app 是 build \(cur)。请用同一版本 app 导入，或在本版本重新导出包。"
        case .schemaFingerprintMismatch:
            return "包的数据 schema 跟当前 app 不一致（字段已变）。请用同一版本 app 导入，或重新导出包。"
        case .sectionChecksumMismatch(let path):
            return "包内 \(path) 校验失败，文件可能损坏或被篡改。"
        case .fullDocumentDecodeFailed(let path, let e):
            return "解析 \(path) 失败: \(e.localizedDescription)"

        case .extractFailed(let e):
            return "解压失败: \(e.localizedDescription)"
        case .stagingContainerFailed(let e):
            return "构建临时数据库失败: \(e.localizedDescription)"
        case .walCheckpointFailed(let url):
            return "SQLite WAL checkpoint 失败: \(url.lastPathComponent)"
        case .walStillExistsAfterCheckpoint(let url):
            return "SQLite WAL 在 checkpoint 后仍有残留: \(url.lastPathComponent)"
        case .stagingFileCopyFailed(let url, let e):
            return "复制 \(url.lastPathComponent) 到临时区失败: \(e.localizedDescription)"
        case .commitFlagWriteFailed(let e):
            return "提交导入失败: \(e.localizedDescription)"

        case .pendingMarkerWriteFailed(let e):
            return "写入恢复 marker 失败: \(e.localizedDescription)"
        case .phase1MoveFailed(let step, let e):
            return "Phase 1（归档当前数据）失败于步骤 \(step): \(e.localizedDescription)"
        case .phase2MoveFailed(let step, let e):
            return "Phase 2（安装新数据）失败于步骤 \(step): \(e.localizedDescription)"
        case .reverseRollbackFailed(let step, let e):
            return "恢复原状失败于步骤 \(step): \(e.localizedDescription)"

        case .stagingValidationFailed(let detail):
            return "导入校验失败: \(detail)（已回滚，主位安全）"
        case .primaryValidationFailed(let detail):
            return """
            主位已被新数据置换但校验失败: \(detail)

            请从 ~/Library/Application Support/MemoryPalace/pre-import-archive/<ISO>/ 手动恢复，
            或在启动期选择「放弃恢复原状」让 PendingImportApplier 自动回滚到导入前状态。
            """
        case .sqliteVerifierFailed(let url, let detail):
            return "SQLite 校验内部错误: \(url.lastPathComponent) - \(detail)"

        case .userCancelled:
            return "已取消"
        case .ioFailed(let url, let e):
            return "文件 \(url.lastPathComponent) 操作失败: \(e.localizedDescription)"
        }
    }
}
