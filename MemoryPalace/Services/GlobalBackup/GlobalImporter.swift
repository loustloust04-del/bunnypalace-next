import Foundation
import SwiftData
import ZIPFoundation
#if os(iOS)
import UIKit
#endif

// MARK: - GlobalImporter (G-C.1)
//
// 全量备份导入第一阶段 — 解包、校验、构建 staging 资产、落 pending-import flag。
// **不动主位资产**（主 unified.store / stickers/ / audiobooks/ / themes/ / floors/ 全不碰）。
//
// 流程：
//   peek(at:) → 解 manifest.json 验 schemaVersion=4 + appBuild + schemaFingerprint
//   extractToWorkspace(url:) → 解 zip 到 Caches/MemoryPalace/import-workspace/<uuid>/
//   validateWorkspace(manifest:) → section canonical sha256 比对 + Full*Document 试解码
//   buildStagingArtifacts(workspace:) → 写 staging container + 文件区 + UserDefaults snapshot
//   commitPendingImport(manifest:) → 落 .pending-import.json flag
//
// 失败任何一步 → rollback() 清 workspace + staging（主位永不动）
//
// 成功后 UI 弹 alert：
//   macOS：NSApp.terminate(nil) 自动重启 → PendingImportApplier 在 init 早期 apply
//   iOS：弹 alert 提示用户从 App Switcher 退出（不调 exit(0)）

enum GlobalImporter {

    // MARK: - C.1.1 peek

    /// 只解 manifest.json + 严格校验 schemaVersion / appBuild / schemaFingerprint
    /// 不解其他内容；不写主位
    static func peek(at url: URL) throws -> GlobalExportManifest {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw GlobalBackupError.malformedManifest("无法打开 .mpb（zip 损坏？）")
        }
        guard let entry = archive["manifest.json"] else {
            throw GlobalBackupError.malformedManifest("包内缺 manifest.json")
        }
        var collected = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                collected.append(chunk)
            }
        } catch {
            throw GlobalBackupError.malformedManifest("manifest.json 解压失败: \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: GlobalExportManifest
        do {
            manifest = try decoder.decode(GlobalExportManifest.self, from: collected)
        } catch {
            throw GlobalBackupError.malformedManifest("manifest.json 解析失败: \(error.localizedDescription)")
        }

        // schemaVersion 校验
        if manifest.schemaVersion < GlobalExportConstants.schemaVersion {
            throw GlobalBackupError.rejectedV1V2V3SchemaVersion(manifest.schemaVersion)
        }
        if manifest.schemaVersion > GlobalExportConstants.schemaVersion {
            throw GlobalBackupError.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        // kind 校验
        if manifest.kind != GlobalExportConstants.kind {
            throw GlobalBackupError.malformedManifest("manifest.kind 非 global-export (是 \(manifest.kind))")
        }

        // appBuild 比对（不同 build 拒，避免 schema 漂移）
        let currentBuild = GlobalExportManifest.currentAppBuild()
        if manifest.appBuild != currentBuild {
            throw GlobalBackupError.appBuildMismatch(packBuild: manifest.appBuild, currentBuild: currentBuild)
        }

        // schemaFingerprint 比对（不同字段集拒，比 appBuild 更严）
        let currentFingerprint = SchemaCoverageCheck.fingerprint()
        if manifest.schemaFingerprint != currentFingerprint {
            throw GlobalBackupError.schemaFingerprintMismatch
        }

        return manifest
    }

    // MARK: - C.1.2 extractToWorkspace

    /// 解压整包到一次性 workspace。返回 workspace URL（调用方负责清理 / 由 rollback 清）
    static func extractToWorkspace(_ url: URL) throws -> URL {
        let workspace = StagingPaths.freshWorkspace()
        do {
            try FileManager.default.unzipItem(at: url, to: workspace)
        } catch {
            try? FileManager.default.removeItem(at: workspace)
            throw GlobalBackupError.extractFailed(error)
        }
        return workspace
    }

    // MARK: - C.1.3 validateWorkspace

    /// 校验 workspace 完整性：
    /// 1. 每 section canonical sha256 对得上 manifest.sections
    /// 2. 各 Full*Document 试解码（不写库）
    static func validateWorkspace(_ workspace: URL, manifest: GlobalExportManifest) throws {
        // 1. section checksum
        for sec in manifest.sections {
            let secURL: URL
            if sec.path == "config.json" {
                // 单文件 section
                let fileURL = workspace.appendingPathComponent(sec.path)
                let actualSha = SectionHasher.sha256OfRegularFile(at: fileURL)
                if actualSha != sec.sha256 {
                    throw GlobalBackupError.sectionChecksumMismatch(path: sec.path)
                }
                continue
            }
            // 目录 section
            secURL = workspace.appendingPathComponent(sec.path, isDirectory: true)
            let (actualSha, _) = try SectionHasher.hash(directory: secURL)
            if actualSha != sec.sha256 {
                throw GlobalBackupError.sectionChecksumMismatch(path: sec.path)
            }
        }

        // 2. Full*Document 试解码（抽样：每 profile 选第一个对话试解，jsonl 每段试解第一行）
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for pid in manifest.profileIds {
            let pidDir = workspace
                .appendingPathComponent("swiftdata", isDirectory: true)
                .appendingPathComponent(pid, isDirectory: true)

            // 对话：每 profile 抽 1 个
            let convsDir = pidDir.appendingPathComponent("conversations", isDirectory: true)
            if let items = try? FileManager.default.contentsOfDirectory(atPath: convsDir.path),
               let first = items.first(where: { $0.hasSuffix(".json") }) {
                let url = convsDir.appendingPathComponent(first)
                let data = try Data(contentsOf: url)
                do {
                    _ = try decoder.decode(FullConversationDocument.self, from: data)
                } catch {
                    throw GlobalBackupError.fullDocumentDecodeFailed(path: "swiftdata/\(pid)/conversations/\(first)", error)
                }
            }

            // jsonl：抽样首行试解
            try validateJSONLFirstLine(pidDir.appendingPathComponent("user_cards.jsonl"), as: FullUserCardDocument.self, decoder: decoder, pid: pid)
            try validateJSONLFirstLine(pidDir.appendingPathComponent("memory_notes.jsonl"), as: FullMemoryNoteDocument.self, decoder: decoder, pid: pid)
            try validateJSONLFirstLine(pidDir.appendingPathComponent("memories.jsonl"), as: FullMemoryDocument.self, decoder: decoder, pid: pid)
            try validateJSONLFirstLine(pidDir.appendingPathComponent("world_books.jsonl"), as: FullWorldBookDocument.self, decoder: decoder, pid: pid)
            try validateJSONLFirstLine(pidDir.appendingPathComponent("book_entries.jsonl"), as: FullBookEntryDocument.self, decoder: decoder, pid: pid)
            try validateJSONLFirstLine(pidDir.appendingPathComponent("audiobook_items.jsonl"), as: FullAudiobookItemDocument.self, decoder: decoder, pid: pid)
            try validateJSONLFirstLine(pidDir.appendingPathComponent("audiobook_bookmarks.jsonl"), as: FullAudiobookBookmarkDocument.self, decoder: decoder, pid: pid)
            try validateJSONLFirstLine(pidDir.appendingPathComponent("import_changes.jsonl"), as: FullImportConversationChangeDocument.self, decoder: decoder, pid: pid)
        }
    }

    private static func validateJSONLFirstLine<D: Decodable>(
        _ url: URL,
        as type: D.Type,
        decoder: JSONDecoder,
        pid: String
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        // 读首行（最多 1 MB；超出认为不正常）
        let chunk = try handle.read(upToCount: 1_000_000) ?? Data()
        guard let nlIndex = chunk.firstIndex(of: 0x0A) else { return }  // 文件无换行 = 可能单行
        let firstLine = chunk[chunk.startIndex..<nlIndex]
        do {
            _ = try decoder.decode(type, from: firstLine)
        } catch {
            throw GlobalBackupError.fullDocumentDecodeFailed(path: url.path, error)
        }
    }

    // MARK: - C.1.4 buildStagingArtifacts

    /// 把 workspace 的内容写到 staging：
    ///   1. staging SwiftData container（unified-staging.store）+ WAL checkpoint
    ///   2. **verifyStagingStore 硬校验**（plan v2 R-1 红线）— staging conv count/node count/id 集合
    ///      vs manifest.stats + workspace conv 文件名；任何漂移立即抛
    ///   3. UserDefaults snapshot plist
    ///   4. 文件区 staging（stickers/audiobooks/themes/floors-staging）
    /// 整个过程**不动主位**。任一失败 → rollback() 清 staging。
    ///
    /// 返回 expectedConvIds 用于 F-D commitPendingImport 写 PendingFlag.expectedConvIds 字段。
    @discardableResult
    static func buildStagingArtifacts(workspace: URL, manifest: GlobalExportManifest) throws -> Set<String> {
        // 先清残留（codex Round 4 抓的 sidecar bug — F-A.3 修了 cleanup 拼路径）
        StagingPaths.cleanupAllStagingArtifacts()

        // C.1.4 staging SwiftData container（autoreleasepool 包以保证 ARC 释放，然后 WAL checkpoint）
        try buildStagingContainer(workspace: workspace, manifest: manifest)

        // ✨ 新增（plan v2 F-C / codex Round 4 #1 红线）：staging 硬校验
        // 调用点严格在：buildStagingContainer 后 → WAL checkpoint 后 →
        //              文件区 staging 前 → commitPendingImport 前
        // 任何漂移立即 throw → runStaging catch → rollback → 主位安全
        let expectedConvIds = try verifyStagingStore(workspace: workspace, manifest: manifest)

        // C.1.5 UserDefaults snapshot
        try buildStagingUserDefaults(workspace: workspace)

        // C.1.6 文件区 staging
        try buildStagingFileTrees(workspace: workspace, manifest: manifest)

        return expectedConvIds
    }

    // MARK: - C.1.4½ verifyStagingStore (plan v2 R-1 红线)

    /// 用 SQLiteStoreVerifier 直接读 staging-store，跟 manifest.stats + workspace 比对。
    /// **不开 SwiftData ModelContainer**（避免再触发同款漂移 bug）。
    ///
    /// 返回 expectedConvIds，调用方传给 commitPendingImport 落进 PendingFlag。
    /// throws stagingValidationFailed 时，runStaging.catch 触发 rollback 清 staging，
    /// 主位永不被破坏。
    private static func verifyStagingStore(workspace: URL, manifest: GlobalExportManifest) throws -> Set<String> {
        // 1. 收集期望的 conv id 集合（从 workspace conv JSON 文件名 + 内容 doc.id 双重校验）
        let expectedIds = try collectExpectedConvIds(workspace: workspace, manifest: manifest)

        // 2. 用 system sqlite3 直接读 staging-store snapshot
        let snapshot: SQLiteStoreVerifier.Snapshot
        do {
            snapshot = try SQLiteStoreVerifier.snapshot(storeURL: StagingPaths.stagingStoreURL)
        } catch {
            throw GlobalBackupError.stagingValidationFailed(
                "SQLite 读取失败: \(error.localizedDescription)")
        }

        // 3. count 比对
        guard snapshot.convCount == manifest.stats.conversationCount else {
            throw GlobalBackupError.stagingValidationFailed(
                "conv count \(snapshot.convCount) ≠ manifest \(manifest.stats.conversationCount)")
        }
        guard snapshot.nodeCount == manifest.stats.messageNodeCount else {
            throw GlobalBackupError.stagingValidationFailed(
                "node count \(snapshot.nodeCount) ≠ manifest \(manifest.stats.messageNodeCount)")
        }

        // 4. id 集合严格比对（找出 extras/missing，含诊断细节）
        let extras = snapshot.convIds.subtracting(expectedIds)
        let missing = expectedIds.subtracting(snapshot.convIds)
        guard extras.isEmpty && missing.isEmpty else {
            let extrasPreview = extras.sorted().prefix(3).joined(separator: ",")
            let missingPreview = missing.sorted().prefix(3).joined(separator: ",")
            throw GlobalBackupError.stagingValidationFailed(
                "extras=\(extrasPreview) (\(extras.count)) missing=\(missingPreview) (\(missing.count))")
        }

        return expectedIds
    }

    /// 枚举 workspace/swiftdata/{pid}/conversations/*.json 拿期望 conv id 集合。
    /// **不只信文件名**（codex Round 5 #5）：
    /// - 进 JSON 验 filename == doc.id + ".json"
    /// - 整体 count == manifest.stats.conversationCount
    /// 任何不一致直接抛 stagingValidationFailed → manifest/workspace 自身污染早抓
    private static func collectExpectedConvIds(workspace: URL, manifest: GlobalExportManifest) throws -> Set<String> {
        var ids = Set<String>()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for pid in manifest.profileIds {
            let convsDir = workspace
                .appendingPathComponent("swiftdata", isDirectory: true)
                .appendingPathComponent(pid, isDirectory: true)
                .appendingPathComponent("conversations", isDirectory: true)
            guard FileManager.default.fileExists(atPath: convsDir.path) else { continue }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: convsDir.path)) ?? []
            for fname in items where fname.hasSuffix(".json") {
                let idFromName = String(fname.dropLast(5))  // 去掉 .json
                let data: Data
                do {
                    data = try Data(contentsOf: convsDir.appendingPathComponent(fname))
                } catch {
                    throw GlobalBackupError.stagingValidationFailed(
                        "读 conv 文件失败: \(fname) - \(error.localizedDescription)")
                }
                let doc: FullConversationDocument
                do {
                    doc = try decoder.decode(FullConversationDocument.self, from: data)
                } catch {
                    throw GlobalBackupError.stagingValidationFailed(
                        "解析 conv 文件失败: \(fname) - \(error.localizedDescription)")
                }
                guard doc.id == idFromName else {
                    throw GlobalBackupError.stagingValidationFailed(
                        "包内 conv 文件名/id 不一致: file=\(fname) doc.id=\(doc.id)")
                }
                ids.insert(doc.id)
            }
        }

        // 整体 count 校验
        guard ids.count == manifest.stats.conversationCount else {
            throw GlobalBackupError.stagingValidationFailed(
                "包内 conv 文件数 \(ids.count) ≠ manifest \(manifest.stats.conversationCount)")
        }

        return ids
    }

    private static func buildStagingContainer(workspace: URL, manifest: GlobalExportManifest) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // 验收 2 抓到现象：staging build 完成后，主位多 1 条粟粟在 staging build 期间还
        // 活在主 ctx 内存的对话「咪」EB487C03。根因暂未坐实（candidate 见
        // docs/research-staging-data-leak.md）。
        //
        // 防御性措施：用 ProfileManager.makeFullSchema() 每次返回新 Schema 实例 而不是共享
        // ProfileManager.fullSchema static let。codex Round 4 review 明确：**这不是已证根因修复**，
        // 只是降低 SwiftData 同进程多 container 共享 Schema 实例时的潜在私有行为风险。
        //
        // 真正红线：verifyStagingStore（buildStagingArtifacts 末尾、commitPendingImport 前）
        // + verifyPrimaryStore（PendingImportApplier Phase 2 P2.3）双闸。
        let stagingSchema = ProfileManager.makeFullSchema()

        do {
            try autoreleasepool {
                let cfg = ModelConfiguration(
                    "unified-staging",
                    schema: stagingSchema,
                    url: StagingPaths.stagingStoreURL,
                    allowsSave: true,
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(for: stagingSchema, configurations: cfg)
                let bgContext = ModelContext(container)
                bgContext.autosaveEnabled = false

                for pid in manifest.profileIds {
                    let pidDir = workspace
                        .appendingPathComponent("swiftdata", isDirectory: true)
                        .appendingPathComponent(pid, isDirectory: true)

                    // 对话 + nodes
                    try insertConversations(pidDir: pidDir, context: bgContext, decoder: decoder)

                    // 12 子段流式 insert
                    try insertJSONLBatch(pidDir.appendingPathComponent("user_cards.jsonl"),
                        FullUserCardDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONLBatch(pidDir.appendingPathComponent("memory_notes.jsonl"),
                        FullMemoryNoteDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONLBatch(pidDir.appendingPathComponent("memories.jsonl"),
                        FullMemoryDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONLBatch(pidDir.appendingPathComponent("world_books.jsonl"),
                        FullWorldBookDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONLBatch(pidDir.appendingPathComponent("book_entries.jsonl"),
                        FullBookEntryDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONLBatch(pidDir.appendingPathComponent("audiobook_items.jsonl"),
                        FullAudiobookItemDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONLBatch(pidDir.appendingPathComponent("audiobook_bookmarks.jsonl"),
                        FullAudiobookBookmarkDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONLBatch(pidDir.appendingPathComponent("import_changes.jsonl"),
                        FullImportConversationChangeDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    // 小表 JSON array
                    try insertJSONArrayBatch(pidDir.appendingPathComponent("tags.json"),
                        [FullConversationTagDocument].self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONArrayBatch(pidDir.appendingPathComponent("favorites.json"),
                        [FullFavoriteItemDocument].self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONArrayBatch(pidDir.appendingPathComponent("import_records.json"),
                        [FullImportRecordDocument].self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    // StickerAsset / PlacedSticker（包内 stickers/{pid}/ 下）
                    let stickersPidDir = workspace
                        .appendingPathComponent("stickers", isDirectory: true)
                        .appendingPathComponent(pid, isDirectory: true)

                    try insertJSONLBatch(stickersPidDir.appendingPathComponent("assets.jsonl"),
                        FullStickerAssetDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try insertJSONLBatch(stickersPidDir.appendingPathComponent("placements.jsonl"),
                        FullPlacedStickerDocument.self, context: bgContext, decoder: decoder,
                        insert: { bgContext.insert($0.toModel()) })

                    try bgContext.save()
                }
                // 局部变量出 scope → ARC deinit container/context
            }
        } catch {
            throw GlobalBackupError.stagingContainerFailed(error)
        }

        // WAL checkpoint + 验证 wal 文件 size==0
        try WALCheckpointer.checkpointAndVerify(storeURL: StagingPaths.stagingStoreURL)
    }

    private static func insertConversations(pidDir: URL, context: ModelContext, decoder: JSONDecoder) throws {
        let convsDir = pidDir.appendingPathComponent("conversations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: convsDir.path) else { return }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: convsDir.path)) ?? []
        var savedCount = 0
        for fname in items where fname.hasSuffix(".json") {
            let data = try Data(contentsOf: convsDir.appendingPathComponent(fname))
            let doc = try decoder.decode(FullConversationDocument.self, from: data)
            let conv = doc.toConversationModel()
            context.insert(conv)
            for nodeDoc in doc.nodes {
                context.insert(nodeDoc.toNodeModel())
            }
            savedCount += 1
            if savedCount % 100 == 0 {
                try context.save()
            }
        }
        if savedCount > 0 { try context.save() }
    }

    private static func insertJSONLBatch<D: Decodable>(
        _ url: URL,
        _ type: D.Type,
        context: ModelContext,
        decoder: JSONDecoder,
        insert: (D) -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        var saved = 0
        // 逐 chunk 读，按 \n 切
        let chunkSize = 256 * 1024
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            while let nlIdx = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nlIdx]
                if !line.isEmpty {
                    let doc = try decoder.decode(D.self, from: line)
                    insert(doc)
                    saved += 1
                    if saved % 500 == 0 {
                        try context.save()
                    }
                }
                buffer.removeSubrange(buffer.startIndex...nlIdx)
            }
        }
        // 处理最后一行（无尾 \n）
        if !buffer.isEmpty {
            let doc = try decoder.decode(D.self, from: buffer)
            insert(doc)
            saved += 1
        }
        if saved > 0 { try context.save() }
    }

    private static func insertJSONArrayBatch<D: Decodable, Item>(
        _ url: URL,
        _ type: D.Type,
        context: ModelContext,
        decoder: JSONDecoder,
        insert: (Item) -> Void
    ) throws where D == [Item], Item: Decodable {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let arr = try decoder.decode([Item].self, from: data)
        for item in arr { insert(item) }
        if !arr.isEmpty { try context.save() }
    }

    // MARK: - C.1.5 UserDefaults snapshot

    private static func buildStagingUserDefaults(workspace: URL) throws {
        // 把 workspace/userdefaults/*.json + workspace/config.json 合并成一个 plist：
        // - config.json 走 ConfigImporter.importAll 的语义（applier 重启时调）
        // - userdefaults/*.json 各自反序列化成 UserDefaults 标量 / Data
        // staging 阶段只复制文件 + 用 plist 登记，apply 阶段才真正写 UserDefaults

        let stagingDir = StagingPaths.applicationSupportRoot
            .appendingPathComponent("userdefaults-staging", isDirectory: true)
        try? FileManager.default.removeItem(at: stagingDir)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // 拷整个 workspace/userdefaults + workspace/config.json
        let udSrc = workspace.appendingPathComponent("userdefaults", isDirectory: true)
        if FileManager.default.fileExists(atPath: udSrc.path) {
            let udDst = stagingDir.appendingPathComponent("userdefaults", isDirectory: true)
            try FileManager.default.copyItem(at: udSrc, to: udDst)
        }
        let cfgSrc = workspace.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: cfgSrc.path) {
            try FileManager.default.copyItem(at: cfgSrc, to: stagingDir.appendingPathComponent("config.json"))
        }
    }

    // MARK: - C.1.6 文件区 staging

    private static func buildStagingFileTrees(workspace: URL, manifest: GlobalExportManifest) throws {
        let fm = FileManager.default

        // stickers/{pid}/ → stickers-staging/{pid}/
        let stickersSrc = workspace.appendingPathComponent("stickers", isDirectory: true)
        if fm.fileExists(atPath: stickersSrc.path) {
            try fm.copyItem(at: stickersSrc, to: StagingPaths.stagingStickersRoot)
        }

        // audiobooks/{pid}/ → audiobooks-staging/{pid}/
        let audioSrc = workspace.appendingPathComponent("audiobooks", isDirectory: true)
        if fm.fileExists(atPath: audioSrc.path) {
            try fm.copyItem(at: audioSrc, to: StagingPaths.stagingAudiobooksRoot)
        }

        // themes/images/ → themes-staging/
        let themesSrc = workspace.appendingPathComponent("themes", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        if fm.fileExists(atPath: themesSrc.path) {
            try fm.copyItem(at: themesSrc, to: StagingPaths.stagingThemesRoot)
        }

        // cardlibrary/ → cardlibrary-staging/（卡库 ⑧c；旧包没有这段 = 恢复后为空）
        let cardLibrarySrc = workspace.appendingPathComponent("cardlibrary", isDirectory: true)
        if fm.fileExists(atPath: cardLibrarySrc.path) {
            try fm.copyItem(at: cardLibrarySrc, to: StagingPaths.stagingCardLibraryRoot)
        }

        // filelibrary/{pid}/ → floors-staging/{slug}/（按 manifest.floorSlugs 复建 slug）
        let flSrc = workspace.appendingPathComponent("filelibrary", isDirectory: true)
        if fm.fileExists(atPath: flSrc.path) {
            try fm.createDirectory(at: StagingPaths.stagingFilelibraryRoot, withIntermediateDirectories: true)
            for pid in manifest.profileIds {
                let pidSrc = flSrc.appendingPathComponent(pid, isDirectory: true)
                guard fm.fileExists(atPath: pidSrc.path) else { continue }
                // 用 manifest 里的 slug 命名（导入时主位 UserDefaults slugMap 写回这套 slug）
                let slug = manifest.floorSlugs[pid] ?? pid
                let dst = StagingPaths.stagingFilelibraryRoot.appendingPathComponent(slug, isDirectory: true)
                try fm.copyItem(at: pidSrc, to: dst)
            }
        }
    }

    // MARK: - C.1.7 commitPendingImport

    /// 落 .pending-import.json flag，记录 staging 资产路径 + manifest 比对字段。
    /// 启动期 PendingImportApplier 看到这个 flag 才进 two-phase apply。
    ///
    /// plan v2 F-D：接收 verifyStagingStore 拿到的 expectedConvIds，
    /// 写进 PendingFlag 给 verifyPrimaryStore 用（R-4 红线）。
    static func commitPendingImport(manifest: GlobalExportManifest, expectedConvIds: Set<String>) throws {
        let sortedIds = expectedConvIds.sorted()
        let idsHash = SQLiteStoreVerifier.canonicalIdsHash(expectedConvIds)

        let flag = PendingImportApplier.PendingFlag(
            schemaVersion: manifest.schemaVersion,
            appBuild: manifest.appBuild,
            schemaFingerprint: manifest.schemaFingerprint,
            createdAt: Date(),
            profileIds: manifest.profileIds,
            floorSlugs: manifest.floorSlugs,
            expectedConvCount: manifest.stats.conversationCount,
            expectedNodeCount: manifest.stats.messageNodeCount,
            expectedConvIdsHash: idsHash,
            expectedConvIds: sortedIds
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(flag)
        } catch {
            throw GlobalBackupError.commitFlagWriteFailed(error)
        }
        do {
            try data.write(to: StagingPaths.pendingImportFlagURL, options: .atomic)
        } catch {
            throw GlobalBackupError.commitFlagWriteFailed(error)
        }
    }

    // MARK: - Public Entry

    /// 完整 staging 流程：peek → extract → validate → buildStagingArtifacts → commitPendingImport
    /// 成功 → 主位还没变，要求用户重启 app（PendingImportApplier 在启动期 apply）
    static func runStaging(from url: URL, progress: GlobalBackupProgress) async throws -> GlobalExportManifest {
        await MainActor.run {
            progress.reset(mode: .importStaging)
            progress.beginSection("validate")
        }

        let manifest = try peek(at: url)
        let workspace: URL
        do {
            workspace = try extractToWorkspace(url)
        } catch {
            throw error
        }

        do {
            try validateWorkspace(workspace, manifest: manifest)
            await MainActor.run { progress.completeSection("validate") }

            await MainActor.run { progress.beginSection("swiftdata") }
            // plan v2 F-D：buildStagingArtifacts 返回 expectedConvIds（来自 verifyStagingStore），
            // 传给 commitPendingImport 写进 PendingFlag 供 verifyPrimaryStore 用
            let expectedConvIds = try buildStagingArtifacts(workspace: workspace, manifest: manifest)
            await MainActor.run { progress.completeSection("swiftdata") }

            try commitPendingImport(manifest: manifest, expectedConvIds: expectedConvIds)

            // 清 workspace（staging 资产已落主位 staging 路径）
            try? FileManager.default.removeItem(at: workspace)
        } catch {
            rollback(workspace: workspace)
            throw error
        }

        return manifest
    }

    // MARK: - rollback

    /// 失败任何阶段调，清 workspace + 所有 staging 资产，主位永不动
    static func rollback(workspace: URL?) {
        if let workspace {
            try? FileManager.default.removeItem(at: workspace)
        }
        StagingPaths.cleanupAllStagingArtifacts()
    }
}

// MARK: - SectionHasher 扩展：单文件 sha256

extension SectionHasher {
    static func sha256OfRegularFile(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256_FileWrapper()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalize()
    }
}

import CryptoKit
private struct SHA256_FileWrapper {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
