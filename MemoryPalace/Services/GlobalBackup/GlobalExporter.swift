import Foundation
import SwiftData
import ZIPFoundation
#if os(iOS)
import UIKit
#endif

// MARK: - GlobalExporter (G-B)
//
// 全量备份单文件包导出主流程。整个流程跑后台 ModelContext（参考 BackupStore.swift / SyncStore.swift）。
// 流程：
//   1. workspace 临时目录
//   2. 按 section 顺序 dump（每段写 manifest.sections 条目 + canonical sha256）
//      - config.json (ConfigExporter)
//      - userdefaults/ (11 个 JSON)
//      - swiftdata/{pid}/ (15 个 Model 流式)
//      - stickers/{pid}/ (平铺文件镜像)
//      - audiobooks/{pid}/
//      - themes/images/
//      - filelibrary/{pid}/ (含 .memorypalace；G-D3 开关含 memory/)
//   3. buildManifest 含 stats + schemaFingerprint + appBuild + floorSlugs
//   4. ZIPFoundation 流式打包 .mpb
//   5. cleanup workspace
//
// 公开入口接收 outputURL（NSSavePanel / .fileExporter 由 UI 层处理）。

enum GlobalExporter {

    enum ExportConfig {
        /// G-D3 开关：AI 记忆树是否进包（默认 true）
        struct Options {
            var includeMemoryTree: Bool = true
        }
    }

    // MARK: - Public Entry

    /// 全量导出。outputURL 必须是用户选好的目标 .mpb 路径。
    /// `progress` 在 @MainActor 上更新；后台流程通过 `await MainActor.run` 回调。
    static func exportAll(
        to outputURL: URL,
        profileManager: ProfileManager,
        options: ExportConfig.Options,
        progress: GlobalBackupProgress
    ) async throws -> URL {
        // #037：只读时楼层列表是 seed，导出会静默缺楼层
        try profileManager.ensureWritable()
        // 后台 context（参考 BackupStore.swift:303、SyncStore.swift:219）
        let container = profileManager.container

        // workspace
        let workspace = StagingPaths.freshWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        await MainActor.run {
            progress.reset(mode: .export)
            progress.beginSection("config")
        }

        var sections: [GlobalExportManifest.SectionEntry] = []
        var stats = MutableStats()

        // B.1
        try exportConfig(to: workspace, sections: &sections)
        await MainActor.run { progress.completeSection("config") }

        // B.2
        await MainActor.run { progress.beginSection("userdefaults") }
        try exportUserDefaultsContent(to: workspace, sections: &sections, stats: &stats, profileManager: profileManager)
        await MainActor.run { progress.completeSection("userdefaults") }

        // B.3
        await MainActor.run { progress.beginSection("swiftdata") }
        try await exportSwiftData(to: workspace, sections: &sections, stats: &stats, container: container, profileManager: profileManager)
        await MainActor.run { progress.completeSection("swiftdata") }

        // B.4
        await MainActor.run { progress.beginSection("stickers") }
        try exportStickers(to: workspace, sections: &sections, stats: &stats, profileManager: profileManager)
        await MainActor.run { progress.completeSection("stickers") }

        // B.5
        await MainActor.run { progress.beginSection("audiobooks") }
        try exportAudiobookFiles(to: workspace, sections: &sections, stats: &stats, profileManager: profileManager)
        await MainActor.run { progress.completeSection("audiobooks") }

        // B.6
        await MainActor.run { progress.beginSection("themes") }
        try exportThemeBackgroundImages(to: workspace, sections: &sections, stats: &stats)
        // 卡库 ⑧c：身份库 / 导入来源 / 原件归档 / 批次整目录（体量小于主题外的大段，不单列进度）
        try exportCardLibraryFiles(to: workspace, sections: &sections, stats: &stats)
        await MainActor.run { progress.completeSection("themes") }

        // B.7
        await MainActor.run { progress.beginSection("filelibrary") }
        try await exportFileLibrary(to: workspace, sections: &sections, stats: &stats, profileManager: profileManager, includeMemoryTree: options.includeMemoryTree)
        await MainActor.run { progress.completeSection("filelibrary") }

        // B.8 + B.9 manifest + zip
        await MainActor.run { progress.beginSection("manifest+zip") }
        try buildManifest(to: workspace, sections: sections, stats: stats, options: options, profileManager: profileManager)
        try packZIP(workspace: workspace, output: outputURL)
        await MainActor.run { progress.completeSection("manifest+zip") }

        return outputURL
    }

    // MARK: - B.1 exportConfig

    /// 写 config.json（调 ConfigExporter.exportAll()，前提 G-A.0 修完）
    private static func exportConfig(
        to workspace: URL,
        sections: inout [GlobalExportManifest.SectionEntry]
    ) throws {
        let data = ConfigExporter.exportAll()
        let outURL = workspace.appendingPathComponent("config.json")
        do {
            try data.write(to: outURL, options: .atomic)
        } catch {
            throw GlobalBackupError.exportConfigFailed(error)
        }
        // sha256 for single file
        let sha = sha256OfFile(at: outURL)
        sections.append(.init(path: "config.json", sha256: sha, bytes: data.count))
    }

    // MARK: - B.2 exportUserDefaultsContent

    /// 11 个 UserDefaults JSON 存档（内容性数据）
    /// 见 plan v4 §1.1 包结构 + §1.4 数据源真相表
    private static func exportUserDefaultsContent(
        to workspace: URL,
        sections: inout [GlobalExportManifest.SectionEntry],
        stats: inout MutableStats,
        profileManager: ProfileManager
    ) throws {
        let defaults = UserDefaults.standard
        let udDir = workspace.appendingPathComponent("userdefaults", isDirectory: true)
        try FileManager.default.createDirectory(at: udDir, withIntermediateDirectories: true)

        // 各 UserDefaults key 跟 dump 文件名
        // ⚠️ 白名单制。设备私有状态（syncRestoreEpochAt / syncFirstPumpExportOnly /
        // hasUnifiedContainerMigrationV1 / sync-state 指纹类）绝不能加进来——
        // 纪元/sentinel 随包旅行会把别的设备的防灌闸带过来（plan-fix-ios-import-impl C2）
        let mapping: [(udKey: String, filename: String, statsField: ((inout MutableStats, Any) -> Void)?)] = [
            ("savedProfiles",                 "profiles.json", { stats, raw in
                if let arr = raw as? [Any] { stats.profileCount = arr.count }
            }),
            ("savedCharacterCards",           "character_cards.json", { stats, raw in
                if let arr = raw as? [Any] { stats.characterCardCount = arr.count }
            }),
            ("globalWorldBooks",              "global_world_books.json", nil),
            ("savedPresets",                  "presets.json", nil),
            ("globalRegexScripts_v1",         "global_regex_scripts.json", nil),
            ("savedWritingStyles",            "writing_styles.json", nil),
            ("fileLibraryLocalDocumentsSlugMapV1", "filelibrary_slug_map.json", nil),
            ("todoItems_v1",                  "todo_items.json", nil),
            ("petState_v1",                   "pet_state.json", nil),
        ]

        for entry in mapping {
            try dumpUDDataAsJSON(udKey: entry.udKey, into: udDir.appendingPathComponent(entry.filename), stats: &stats, statsField: entry.statsField)
        }

        // web_search 6 个 key 合成一个 JSON
        var webSearch: [String: Any] = [:]
        for key in ["webSearchEnabled", "webSearchResultSize", "webSearchTimeoutMs",
                    "webSearchProviders", "webSearchSelectedId", "webSearchBlockedDomains"] {
            if let v = defaults.object(forKey: key) {
                // providers/blockedDomains 是 Data JSON 存档，要解出
                if (key == "webSearchProviders" || key == "webSearchBlockedDomains"),
                   let data = v as? Data,
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    webSearch[key] = obj
                } else {
                    webSearch[key] = sanitizeForJSON(v)
                }
            }
        }
        if !webSearch.isEmpty {
            let wsURL = udDir.appendingPathComponent("web_search.json")
            let wsData = try JSONSerialization.data(withJSONObject: webSearch, options: [.prettyPrinted, .sortedKeys])
            try wsData.write(to: wsURL, options: .atomic)
        }

        // audiobook checkpoints — 这一组是动态前缀 audiobook.checkpoint.*
        // 注意：PlaybackCheckpointStore.write 存的是 Data（JSON-encoded Checkpoint）→
        //      Data 不是 JSONSerialization 兼容类型 → 直接 set 进 dict 后 JSONSerialization 抛 NSException → iOS crash
        //      所以这里用 sanitizeForJSON 把 Data 转 base64-string
        let allKeys = defaults.dictionaryRepresentation().keys
        let checkpoints = allKeys.filter { $0.hasPrefix("audiobook.checkpoint.") }
        if !checkpoints.isEmpty {
            var dict: [String: Any] = [:]
            for k in checkpoints {
                if let v = defaults.object(forKey: k) {
                    dict[k] = sanitizeForJSON(v)
                }
            }
            let cpURL = udDir.appendingPathComponent("audiobook_checkpoints.json")
            let cpData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try cpData.write(to: cpURL, options: .atomic)
        }

        // section sha256（整目录）
        let (sha, bytes) = try SectionHasher.hash(directory: udDir)
        sections.append(.init(path: "userdefaults", sha256: sha, bytes: bytes))
    }

    /// 把 UserDefaults object 转成 JSONSerialization 兼容值。
    ///
    /// 修 V-A iOS crash：PlaybackCheckpointStore 把 Data 直接 set 到 UserDefaults
    /// `audiobook.checkpoint.*`，dump 时 JSONSerialization 不接受 Data → 抛 NSException → SIGABRT。
    /// 同样 Date、自定义对象都不在 JSONSerialization 支持类型列表
    /// （[NSString, NSNumber, NSArray, NSDictionary, NSNull]）。
    ///
    /// 解决：递归 sanitize：
    /// - Data → ["__type": "Data", "base64": ...]
    /// - Date → ["__type": "Date", "iso8601": ...]
    /// - dict/array → 递归
    /// - 其他 JSON 兼容（Bool/Int/Double/String）原样
    /// - 其他不识别类型 → NSNull（不抛错，避免单 key 拖垮整段 dump）
    ///
    /// 导入时 PendingImportApplier.applyStagingUserDefaults 反向 unsanitize，把 wrapper 字典还原成原类型。
    private static func sanitizeForJSON(_ obj: Any) -> Any {
        // Bool / Int / Double / String / NSNumber 直接通过
        if obj is String || obj is NSNumber { return obj }
        if let date = obj as? Date {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ["__type": "Date", "iso8601": f.string(from: date)]
        }
        if let data = obj as? Data {
            return ["__type": "Data", "base64": data.base64EncodedString()]
        }
        if let dict = obj as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitizeForJSON(v) }
            return out
        }
        if let arr = obj as? [Any] { return arr.map(sanitizeForJSON) }
        // 不识别 → NSNull（避免抛错）
        return NSNull()
    }

    private static func dumpUDDataAsJSON(
        udKey: String,
        into outURL: URL,
        stats: inout MutableStats,
        statsField: ((inout MutableStats, Any) -> Void)?
    ) throws {
        let defaults = UserDefaults.standard
        // 搬去文件的大 blob（角色卡）从 BlobStore 读，备份格式不变
        guard let data = BlobStore.migratedKeys.contains(udKey) ? BlobStore.data(forKey: udKey) : defaults.data(forKey: udKey) else { return }
        // 验证 JSON 可解 → 重序列化保 pretty
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        if let f = statsField {
            f(&stats, obj)
        }
        let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try pretty.write(to: outURL, options: .atomic)
    }

    // MARK: - B.3 / B.4 / B.5 / B.6 / B.7 占位 — 下批 commit 补完

    private static func exportSwiftData(
        to workspace: URL,
        sections: inout [GlobalExportManifest.SectionEntry],
        stats: inout MutableStats,
        container: ModelContainer,
        profileManager: ProfileManager
    ) async throws {
        let swiftdataDir = workspace.appendingPathComponent("swiftdata", isDirectory: true)
        try FileManager.default.createDirectory(at: swiftdataDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // 后台 context — 在主 container 上但写入 staging workspace 不触动主库
        let bgContext = ModelContext(container)

        for profile in profileManager.profiles {
            let pid = profile.id
            let pidDir = swiftdataDir.appendingPathComponent(pid, isDirectory: true)
            try FileManager.default.createDirectory(at: pidDir, withIntermediateDirectories: true)

            // 12 子段（PlacedSticker + StickerAsset 归 B.4 stickers/）

            // --- Conversations（含 nodes 嵌入；每对话一个 JSON 文件） ---
            let convsDir = pidDir.appendingPathComponent("conversations", isDirectory: true)
            try FileManager.default.createDirectory(at: convsDir, withIntermediateDirectories: true)

            let allConvs = try bgContext.fetch(FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == pid }
            ))
            let allNodes = try bgContext.fetch(FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { $0.profileId == pid }
            ))
            var nodesByConvId: [String: [MessageNode]] = [:]
            for n in allNodes {
                nodesByConvId[n.conversationId, default: []].append(n)
            }
            for conv in allConvs {
                try Task.checkCancellation()
                let nodes = nodesByConvId[conv.id] ?? []
                let doc = FullConversationDocument(model: conv, nodes: nodes)
                let data = try encoder.encode(doc)
                let fname = "\(conv.id).json"
                try data.write(to: convsDir.appendingPathComponent(fname), options: .atomic)
                stats.conversationCount += 1
                stats.messageNodeCount += nodes.count
            }

            // --- jsonl 大表（流式逐行 append） ---

            try dumpJSONL(
                FetchDescriptor<UserCard>(predicate: #Predicate<UserCard> { $0.profileId == pid }),
                context: bgContext, mapping: FullUserCardDocument.init(model:),
                to: pidDir.appendingPathComponent("user_cards.jsonl"),
                stats: &stats.userCardCount
            )

            try dumpJSONL(
                FetchDescriptor<ImportConversationChange>(predicate: #Predicate<ImportConversationChange> { $0.profileId == pid }),
                context: bgContext, mapping: FullImportConversationChangeDocument.init(model:),
                to: pidDir.appendingPathComponent("import_changes.jsonl"),
                stats: &stats.importChangeCount
            )

            try dumpJSONL(
                FetchDescriptor<MemoryNote>(predicate: #Predicate<MemoryNote> { $0.profileId == pid }),
                context: bgContext, mapping: FullMemoryNoteDocument.init(model:),
                to: pidDir.appendingPathComponent("memory_notes.jsonl"),
                stats: &stats.memoryNoteCount
            )

            try dumpJSONL(
                FetchDescriptor<Memory>(predicate: #Predicate<Memory> { $0.profileId == pid }),
                context: bgContext, mapping: FullMemoryDocument.init(model:),
                to: pidDir.appendingPathComponent("memories.jsonl"),
                stats: &stats.memoryCount
            )

            try dumpJSONL(
                FetchDescriptor<WorldBook>(predicate: #Predicate<WorldBook> { $0.profileId == pid }),
                context: bgContext, mapping: FullWorldBookDocument.init(model:),
                to: pidDir.appendingPathComponent("world_books.jsonl"),
                stats: &stats.worldBookCount
            )

            try dumpJSONL(
                FetchDescriptor<BookEntry>(predicate: #Predicate<BookEntry> { $0.profileId == pid }),
                context: bgContext, mapping: FullBookEntryDocument.init(model:),
                to: pidDir.appendingPathComponent("book_entries.jsonl"),
                stats: &stats.bookEntryCount
            )

            try dumpJSONL(
                FetchDescriptor<AudiobookItem>(predicate: #Predicate<AudiobookItem> { $0.profileId == pid }),
                context: bgContext, mapping: FullAudiobookItemDocument.init(model:),
                to: pidDir.appendingPathComponent("audiobook_items.jsonl"),
                stats: &stats.audiobookCount
            )

            try dumpJSONL(
                FetchDescriptor<AudiobookBookmark>(predicate: #Predicate<AudiobookBookmark> { $0.profileId == pid }),
                context: bgContext, mapping: FullAudiobookBookmarkDocument.init(model:),
                to: pidDir.appendingPathComponent("audiobook_bookmarks.jsonl"),
                stats: &stats.audiobookBookmarkCount
            )

            // --- 小表（JSON 数组） ---

            try dumpJSONArray(
                FetchDescriptor<ConversationTag>(predicate: #Predicate<ConversationTag> { $0.profileId == pid }),
                context: bgContext, mapping: FullConversationTagDocument.init(model:),
                to: pidDir.appendingPathComponent("tags.json"),
                stats: &stats.tagCount
            )

            try dumpJSONArray(
                FetchDescriptor<FavoriteItem>(predicate: #Predicate<FavoriteItem> { $0.profileId == pid }),
                context: bgContext, mapping: FullFavoriteItemDocument.init(model:),
                to: pidDir.appendingPathComponent("favorites.json"),
                stats: &stats.favoriteCount
            )

            try dumpJSONArray(
                FetchDescriptor<ImportRecord>(predicate: #Predicate<ImportRecord> { $0.profileId == pid }),
                context: bgContext, mapping: FullImportRecordDocument.init(model:),
                to: pidDir.appendingPathComponent("import_records.json"),
                stats: &stats.importRecordCount
            )
        }

        // section sha256
        let (sha, bytes) = try SectionHasher.hash(directory: swiftdataDir)
        sections.append(.init(path: "swiftdata", sha256: sha, bytes: bytes))
        stats.uncompressedBytes += bytes
    }

    /// 流式 jsonl dump（每行一个 Document JSON）
    private static func dumpJSONL<M, D: Encodable>(
        _ descriptor: FetchDescriptor<M>,
        context: ModelContext,
        mapping: (M) -> D,
        to outURL: URL,
        stats: inout Int
    ) throws {
        let models = try context.fetch(descriptor)
        guard !models.isEmpty else { return }
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outURL) else {
            throw GlobalBackupError.exportSwiftDataFailed(NSError(domain: "GlobalExporter", code: -1))
        }
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for m in models {
            let doc = mapping(m)
            var data = try encoder.encode(doc)
            data.append(0x0A) // \n
            try handle.write(contentsOf: data)
            stats += 1
        }
    }

    /// 小表 JSON array dump
    private static func dumpJSONArray<M, D: Encodable>(
        _ descriptor: FetchDescriptor<M>,
        context: ModelContext,
        mapping: (M) -> D,
        to outURL: URL,
        stats: inout Int
    ) throws {
        let models = try context.fetch(descriptor)
        guard !models.isEmpty else { return }
        let docs = models.map(mapping)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(docs)
        try data.write(to: outURL, options: .atomic)
        stats += models.count
    }

    private static func exportStickers(
        to workspace: URL,
        sections: inout [GlobalExportManifest.SectionEntry],
        stats: inout MutableStats,
        profileManager: ProfileManager
    ) throws {
        let stickersOut = workspace.appendingPathComponent("stickers", isDirectory: true)
        try FileManager.default.createDirectory(at: stickersOut, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let container = profileManager.container
        let bgContext = ModelContext(container)

        for profile in profileManager.profiles {
            let pid = profile.id
            let pidOut = stickersOut.appendingPathComponent(pid, isDirectory: true)
            try FileManager.default.createDirectory(at: pidOut, withIntermediateDirectories: true)

            // 1. 拷贴纸文件根目录平铺（imagePath/thumbnailPath/originalImagePath 三种文件直接 copy）
            let srcRoot = StickerFileManager.stickerDirectory(profileId: pid)
            if FileManager.default.fileExists(atPath: srcRoot.path) {
                let items = (try? FileManager.default.contentsOfDirectory(atPath: srcRoot.path)) ?? []
                for name in items {
                    let src = srcRoot.appendingPathComponent(name)
                    let dst = pidOut.appendingPathComponent(name)
                    do {
                        try FileManager.default.copyItem(at: src, to: dst)
                        let sz = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
                        stats.stickerAssetBytes += sz
                    } catch {
                        throw GlobalBackupError.exportFileCopyFailed(src, error)
                    }
                }
            }

            // 2. dump StickerAsset metadata → assets.jsonl
            try dumpJSONL(
                FetchDescriptor<StickerAsset>(predicate: #Predicate<StickerAsset> { $0.profileId == pid }),
                context: bgContext, mapping: FullStickerAssetDocument.init(model:),
                to: pidOut.appendingPathComponent("assets.jsonl"),
                stats: &stats.stickerAssetCount
            )

            // 3. PlacedSticker → placements.jsonl
            try dumpJSONL(
                FetchDescriptor<PlacedSticker>(predicate: #Predicate<PlacedSticker> { $0.profileId == pid }),
                context: bgContext, mapping: FullPlacedStickerDocument.init(model:),
                to: pidOut.appendingPathComponent("placements.jsonl"),
                stats: &stats.placedStickerCount
            )
        }

        let (sha, bytes) = try SectionHasher.hash(directory: stickersOut)
        sections.append(.init(path: "stickers", sha256: sha, bytes: bytes))
        stats.uncompressedBytes += bytes
    }

    private static func exportAudiobookFiles(
        to workspace: URL,
        sections: inout [GlobalExportManifest.SectionEntry],
        stats: inout MutableStats,
        profileManager: ProfileManager
    ) throws {
        let audioOut = workspace.appendingPathComponent("audiobooks", isDirectory: true)
        try FileManager.default.createDirectory(at: audioOut, withIntermediateDirectories: true)

        let baseAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let srcRoot = baseAppSupport
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("audiobooks", isDirectory: true)

        for profile in profileManager.profiles {
            let pid = profile.id
            let src = srcRoot.appendingPathComponent(pid, isDirectory: true)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = audioOut.appendingPathComponent(pid, isDirectory: true)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                throw GlobalBackupError.exportFileCopyFailed(src, error)
            }
            // 累加大小
            let enumerator = FileManager.default.enumerator(atPath: dst.path)
            while let p = enumerator?.nextObject() as? String {
                let url = dst.appendingPathComponent(p)
                if let sz = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int {
                    stats.audiobookFileBytes += sz
                }
            }
        }

        let (sha, bytes) = try SectionHasher.hash(directory: audioOut)
        sections.append(.init(path: "audiobooks", sha256: sha, bytes: bytes))
        stats.uncompressedBytes += bytes
    }

    private static func exportThemeBackgroundImages(
        to workspace: URL,
        sections: inout [GlobalExportManifest.SectionEntry],
        stats: inout MutableStats
    ) throws {
        let themesOut = workspace.appendingPathComponent("themes", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: themesOut, withIntermediateDirectories: true)

        let baseAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let srcRoot = baseAppSupport
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)

        if FileManager.default.fileExists(atPath: srcRoot.path) {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: srcRoot.path)) ?? []
            for name in items {
                let src = srcRoot.appendingPathComponent(name)
                let dst = themesOut.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: src, to: dst)
                    stats.backgroundImageCount += 1
                } catch {
                    throw GlobalBackupError.exportFileCopyFailed(src, error)
                }
            }
        }

        let parent = workspace.appendingPathComponent("themes", isDirectory: true)
        let (sha, bytes) = try SectionHasher.hash(directory: parent)
        sections.append(.init(path: "themes", sha256: sha, bytes: bytes))
        stats.uncompressedBytes += bytes
    }

    /// cardlibrary/ 原样镜像（内部只存相对路径，换机器 / 恢复后照样能用）
    private static func exportCardLibraryFiles(
        to workspace: URL,
        sections: inout [GlobalExportManifest.SectionEntry],
        stats: inout MutableStats
    ) throws {
        let src = StagingPaths.primaryCardLibraryRoot
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        let dst = workspace.appendingPathComponent("cardlibrary", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            throw GlobalBackupError.exportFileCopyFailed(src, error)
        }
        let (sha, bytes) = try SectionHasher.hash(directory: dst)
        sections.append(.init(path: "cardlibrary", sha256: sha, bytes: bytes))
        stats.uncompressedBytes += bytes
    }

    private static func exportFileLibrary(
        to workspace: URL,
        sections: inout [GlobalExportManifest.SectionEntry],
        stats: inout MutableStats,
        profileManager: ProfileManager,
        includeMemoryTree: Bool
    ) async throws {
        let outRoot = workspace.appendingPathComponent("filelibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)

        // 当前文件库根（iCloud or 本地，按开关）
        let baseDocs = FileLibraryStore.documentsBaseRoot()

        for profile in profileManager.profiles {
            let pid = profile.id
            let slug = FileLibraryStore.floorSlug(profileId: pid)
            let outPid = outRoot.appendingPathComponent(pid, isDirectory: true)  // 包内按 pid（slug 不稳定）
            try FileManager.default.createDirectory(at: outPid, withIntermediateDirectories: true)

            let floorRoot = baseDocs.appendingPathComponent(slug, isDirectory: true)
            let fsSrc = floorRoot.appendingPathComponent("filesystem", isDirectory: true)
            let mpSrc = floorRoot.appendingPathComponent(".memorypalace", isDirectory: true)

            // materialize iCloud placeholder（递归 + 30s/文件超时 + cancellable）
            try await PlaceholderMaterializer.materialize(filesUnder: fsSrc, recursive: true)
            try await PlaceholderMaterializer.materialize(filesUnder: mpSrc, recursive: true)

            if FileManager.default.fileExists(atPath: fsSrc.path) {
                let dst = outPid.appendingPathComponent("filesystem", isDirectory: true)
                do {
                    try FileManager.default.copyItem(at: fsSrc, to: dst)
                } catch {
                    throw GlobalBackupError.exportFileCopyFailed(fsSrc, error)
                }
            }
            if FileManager.default.fileExists(atPath: mpSrc.path) {
                let dst = outPid.appendingPathComponent(".memorypalace", isDirectory: true)
                do {
                    try FileManager.default.copyItem(at: mpSrc, to: dst)
                } catch {
                    throw GlobalBackupError.exportFileCopyFailed(mpSrc, error)
                }
            }

            // memory 树（G-D3 开关；memory 永远本地，单独路径）
            if includeMemoryTree {
                let memSrc = FileLibraryStore.memoryRoot(profileId: pid)
                if FileManager.default.fileExists(atPath: memSrc.path) {
                    let dst = outPid.appendingPathComponent("memory", isDirectory: true)
                    do {
                        try FileManager.default.copyItem(at: memSrc, to: dst)
                    } catch {
                        throw GlobalBackupError.exportFileCopyFailed(memSrc, error)
                    }
                }
            }

            // 统计文件数
            if let enumerator = FileManager.default.enumerator(at: outPid, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let url = enumerator.nextObject() as? URL {
                    if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        stats.filesystemFileCount += 1
                    }
                }
            }
        }

        let (sha, bytes) = try SectionHasher.hash(directory: outRoot)
        sections.append(.init(path: "filelibrary", sha256: sha, bytes: bytes))
        stats.uncompressedBytes += bytes
    }

    // MARK: - B.8 buildManifest

    private static func buildManifest(
        to workspace: URL,
        sections: [GlobalExportManifest.SectionEntry],
        stats: MutableStats,
        options: ExportConfig.Options,
        profileManager: ProfileManager
    ) throws {
        let manifest = GlobalExportManifest(
            schemaVersion: GlobalExportConstants.schemaVersion,
            kind: GlobalExportConstants.kind,
            appVersion: GlobalExportManifest.currentAppVersion(),
            appBuild: GlobalExportManifest.currentAppBuild(),
            schemaFingerprint: SchemaCoverageCheck.fingerprint(),
            exportedAt: Date(),
            device: deviceName(),
            stats: stats.snapshot(),
            includes: .init(
                memoryTree: options.includeMemoryTree,
                characterCards: true,
                backgroundImages: true,
                stickerAssets: true,
                audiobookFiles: true
            ),
            profileIds: profileManager.profiles.map(\.id),
            floorSlugs: collectFloorSlugs(profileManager: profileManager),
            sections: sections
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: workspace.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func collectFloorSlugs(profileManager: ProfileManager) -> [String: String] {
        var map: [String: String] = [:]
        for p in profileManager.profiles {
            map[p.id] = FileLibraryStore.floorSlug(profileId: p.id)
        }
        return map
    }

    // MARK: - B.9 packZIP

    private static func packZIP(workspace: URL, output: URL) throws {
        // 删旧（覆盖语义）
        try? FileManager.default.removeItem(at: output)
        do {
            try FileManager.default.zipItem(at: workspace, to: output, shouldKeepParent: false, compressionMethod: .deflate, progress: nil)
        } catch {
            throw GlobalBackupError.packZipFailed(error)
        }
    }

    // MARK: - Helpers

    private static func sha256OfFile(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256_Wrapper()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalize()
    }

    private static func deviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

// MARK: - MutableStats (内部累计 Stats)

struct MutableStats {
    var profileCount: Int = 0
    var conversationCount: Int = 0
    var messageNodeCount: Int = 0
    var memoryNoteCount: Int = 0
    var memoryCount: Int = 0
    var worldBookCount: Int = 0
    var userCardCount: Int = 0
    var tagCount: Int = 0
    var favoriteCount: Int = 0
    var importRecordCount: Int = 0
    var importChangeCount: Int = 0
    var bookEntryCount: Int = 0
    var audiobookCount: Int = 0
    var audiobookBookmarkCount: Int = 0
    var stickerAssetCount: Int = 0
    var stickerAssetBytes: Int = 0
    var placedStickerCount: Int = 0
    var characterCardCount: Int = 0
    var backgroundImageCount: Int = 0
    var audiobookFileBytes: Int = 0
    var filesystemFileCount: Int = 0
    var uncompressedBytes: Int = 0

    func snapshot() -> GlobalExportManifest.Stats {
        .init(
            profileCount: profileCount,
            conversationCount: conversationCount,
            messageNodeCount: messageNodeCount,
            memoryNoteCount: memoryNoteCount,
            memoryCount: memoryCount,
            worldBookCount: worldBookCount,
            userCardCount: userCardCount,
            tagCount: tagCount,
            favoriteCount: favoriteCount,
            importRecordCount: importRecordCount,
            importChangeCount: importChangeCount,
            bookEntryCount: bookEntryCount,
            audiobookCount: audiobookCount,
            audiobookBookmarkCount: audiobookBookmarkCount,
            stickerAssetCount: stickerAssetCount,
            stickerAssetBytes: stickerAssetBytes,
            placedStickerCount: placedStickerCount,
            characterCardCount: characterCardCount,
            backgroundImageCount: backgroundImageCount,
            audiobookFileBytes: audiobookFileBytes,
            filesystemFileCount: filesystemFileCount,
            uncompressedBytes: uncompressedBytes
        )
    }
}

// MARK: - SHA256 流式 helper

import CryptoKit
private struct SHA256_Wrapper {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finalize() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
