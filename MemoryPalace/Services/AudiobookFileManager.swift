#if PERSONAL_APPS
#if DEBUG
import Foundation
import AVFoundation

// MARK: - Errors

enum AudiobookImportError: LocalizedError {
    case accessDenied
    case unsupportedFormat(String)
    case copyFailed(underlying: Error)
    case durationProbeFailed
    case moveFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "无法访问该文件（沙盒权限拒绝）"
        case .unsupportedFormat(let ext): return "不支持的音频格式：.\(ext)"
        case .copyFailed(let e): return "复制文件失败：\(e.localizedDescription)"
        case .durationProbeFailed: return "无法读取音频时长"
        case .moveFailed(let e): return "移动文件失败：\(e.localizedDescription)"
        }
    }
}

// MARK: - Import Result

struct AudiobookImportResult {
    let fileName: String          // {uuid}.{ext}
    let fileSizeBytes: Int64
    let totalDuration: Double     // 秒
    let suggestedTitle: String    // 原文件名去扩展名，给 UI 默认值
}

// MARK: - File Manager (namespace 风格，跟 StickerFileManager 一致)

enum AudiobookFileManager {

    /// 支持格式白名单（不要用 .audio 太宽）
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "m4b", "wav", "aac"]

    // MARK: Directories

    /// 有声书根目录: ~/Library/Application Support/MemoryPalace/audiobooks/{profileId}/
    static func audiobookDirectory(profileId: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("audiobooks", isDirectory: true)
            .appendingPathComponent(profileId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 已落盘文件的完整 URL（不验证存在）
    static func audioURL(fileName: String, profileId: String) -> URL {
        audiobookDirectory(profileId: profileId).appendingPathComponent(fileName)
    }

    // MARK: Import

    /// 从用户选择的源 URL 复制音频进 app sandbox + 探测时长。
    /// 关键点：
    /// - 用户选的 URL 是 security-scoped，必须 startAccessing 才能读
    /// - 大文件 copy 在 detached task 里（caller 已在 Task 里也 OK，复用线程）
    /// - 先写临时文件再 atomic move，避免 partial-write
    static func importAudio(from sourceURL: URL, profileId: String) async throws -> AudiobookImportResult {
        let ext = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw AudiobookImportError.unsupportedFormat(ext)
        }

        // security-scoped resource：fileImporter 来源的 URL 必须 startAccessing 才能读。
        // sandbox 关闭的 macOS dev 环境会 return false 但 copy 仍可能成功 → 不立刻抛，让 copy 试一试。
        let scopeOK = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scopeOK { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let dir = audiobookDirectory(profileId: profileId)
        let finalName = "\(UUID().uuidString).\(ext)"
        let tempURL = dir.appendingPathComponent("\(UUID().uuidString).tmp")
        let finalURL = dir.appendingPathComponent(finalName)

        // 1. 复制到临时文件
        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        } catch {
            // 如果 scope 失败这里大概率 EACCES
            if !scopeOK {
                throw AudiobookImportError.accessDenied
            }
            throw AudiobookImportError.copyFailed(underlying: error)
        }

        // 2. atomic move 到最终文件
        do {
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudiobookImportError.moveFailed(underlying: error)
        }

        // 3. 文件大小
        let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // 4. 探测时长
        let asset = AVURLAsset(url: finalURL)
        let duration: Double
        do {
            let cmTime = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmTime)
            guard duration.isFinite, duration > 0 else {
                throw AudiobookImportError.durationProbeFailed
            }
        } catch {
            try? FileManager.default.removeItem(at: finalURL)
            throw AudiobookImportError.durationProbeFailed
        }

        // 5. 建议标题：原文件名去扩展名
        let suggestedTitle = sourceURL.deletingPathExtension().lastPathComponent

        return AudiobookImportResult(
            fileName: finalName,
            fileSizeBytes: size,
            totalDuration: duration,
            suggestedTitle: suggestedTitle
        )
    }

    // MARK: Delete

    /// 删除音频文件（不管 SwiftData 行，由 caller 单独处理）
    static func deleteAudio(fileName: String, profileId: String) {
        let url = audioURL(fileName: fileName, profileId: profileId)
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
#endif
