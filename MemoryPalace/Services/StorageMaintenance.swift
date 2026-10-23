import Foundation
import SwiftData
import WebKit

/// 设置「存储」区的两把扫帚（A4，批注#5）：
/// - 清理系统缓存：tmp / html 缩略图 / URLCache / WebKit 磁盘缓存
/// - 整理媒体数据：历史内联附件外置成 ref（SwiftData 瘦身）+ attachments/ 孤儿清理
enum StorageMaintenance {

    // MARK: - 清理系统缓存

    /// app 自己往 tmp 里创建的目录前缀（附件预览/artifact 导出临时件）。
    /// ⚠️ 绝不能整清 temporaryDirectory：macOS 非沙箱下它是用户级 /var/folders 共享目录，
    /// 全清 = 枚举百万文件 + 破坏别的进程临时状态（测试卡死抓出来的）。只清自己认识的前缀。
    private static let ownedTmpPrefixes = ["preview_", "artifact_", "storage-test-"]

    /// 返回释放的字节数（自有 tmp 件 + html-thumbs + URLCache；WebKit 缓存异步清不计入）
    static func cleanSystemCaches() -> Int {
        var freed = 0
        let fm = FileManager.default

        let tmp = fm.temporaryDirectory
        if let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey]) {
            for item in items where ownedTmpPrefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
                freed += directorySize(item) + ((try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                try? fm.removeItem(at: item)
            }
        }

        let thumbs = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MemoryPalace/html-thumbs", isDirectory: true)
        freed += directorySize(thumbs)
        try? fm.removeItem(at: thumbs)

        freed += URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        URLCache.shared.removeAllCachedResponses()

        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: .distantPast
        ) {}

        return freed
    }

    private static func directorySize(_ url: URL) -> Int {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in en {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }

    // MARK: - 整理媒体数据

    struct MediaSweepResult {
        var conversationsScanned = 0
        var nodesMigrated = 0
        var orphansDeleted = 0
        var orphanBytes = 0
    }

    /// 一趟扫描：① 内联附件外置成 ref ② 收集全部 ref → 删 attachments/ 孤儿。
    /// 按对话分批（禁全量 fetch MessageNode）；optional 字段判空在内存做（SwiftData optional 谓词教训）。
    @MainActor
    static func sweepMedia(
        context: ModelContext,
        progress: @escaping (String) -> Void
    ) async -> MediaSweepResult {
        var result = MediaSweepResult()

        let conversations = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        var referencedByProfile: [String: Set<String>] = [:]
        var profileIds: Set<String> = []

        for (index, conversation) in conversations.enumerated() {
            let convId = conversation.id
            let pid = conversation.profileId
            guard !pid.isEmpty else { continue }
            profileIds.insert(pid)
            progress("扫描对话 \(index + 1)/\(conversations.count)")

            let nodeDescriptor = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { $0.conversationId == convId && $0.profileId == pid }
            )
            let nodes = (try? context.fetch(nodeDescriptor)) ?? []
            var dirty = false

            for node in nodes where node.segmentsData != nil {
                guard let segs = node.segments else { continue }
                let hasInline = segs.contains { seg in
                    if case .image = seg { return true }
                    if case .fileData = seg { return true }
                    return false
                }
                if hasInline {
                    node.setSegments(segs, conversationTitle: conversation.title)
                    result.nodesMigrated += 1
                    dirty = true
                }
                // 重写后重读，收集 ref（迁移失败保持内联时自然没有 ref，不影响）
                for seg in node.segments ?? [] {
                    switch seg {
                    case .imageRef(_, _, let path), .fileDataRef(_, _, let path):
                        referencedByProfile[pid, default: []].insert(path)
                    default:
                        break
                    }
                }
            }

            if dirty { try? context.save() }
            result.conversationsScanned += 1
            await Task.yield()
        }

        // 孤儿：attachments/ 下没有任何 ref 指向的文件
        for pid in profileIds {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("StorageMaintenance.orphanFiles") : nil
            defer { if let airSpan { AirProbeSections.leave(airSpan) } }
            #endif
            let referenced = referencedByProfile[pid] ?? []
            let attachmentFiles = FileLibraryStore.list(profileId: pid)
                .filter { $0.path.hasPrefix(AttachmentStore.folderName + "/") }
            for meta in attachmentFiles where !referenced.contains(meta.path) {
                if (try? FileLibraryStore.delete(meta.path, profileId: pid)) != nil {
                    result.orphansDeleted += 1
                    result.orphanBytes += meta.bytes
                }
            }
        }

        return result
    }
}
