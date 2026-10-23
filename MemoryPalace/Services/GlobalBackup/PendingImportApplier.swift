import Foundation

// MARK: - PendingImportApplier (G-C.2)
//
// 启动期 two-phase crash-resumable apply（codex Round 3 必改 #1+#4 路线级整改）。
//
// **触发**：MemoryPalaceApp.init 早期，在 makeUnifiedContainer() **之前**调
// `PendingImportApplier.applyIfNeeded()`，路线 A 路径走通。
//
// 流程：
//   读 .pending-import.json flag → 比对 appBuild + schemaFingerprint
//     不匹配 → 返回 .versionMismatch（UI 提示放弃 + cleanup）
//     OK → 读 .pending-import.marker.json
//       新建（idle） → Phase 1 archive + Phase 2 install
//       phase1-archiving → 续作 Phase 1
//       phase2-installing → 续作 Phase 2
//
// 每个 Phase 各步用 FileManager.moveItem（同 volume rename ≈ atomic），写
// marker.completedSteps 落 magnetic tape；崩了下次启动接着干。
//
// 失败任何步 → marker.errors 累计 + 返回 .failedAtStep；UI 三选一：
//   1. 继续重试（applyIfNeeded 再调）
//   2. 放弃恢复原状（reverseRollback：按 completedSteps 反向 move 主位回导入前）
//   3. 重启再试（不动 marker）
//
// 完成 → 清 flag + marker + 30 天后清 archive。

enum PendingImportApplier {

    // MARK: - Schema

    enum State: String, Codable {
        case idle
        case phase1Archiving = "phase1-archiving"
        case phase2Installing = "phase2-installing"
        case done
        case aborted
    }

    enum Step: String, Codable {
        // Phase 1
        case p1_archiveSwiftData = "p1.1"
        case p1_archiveStickers = "p1.2"
        case p1_archiveAudiobooks = "p1.3"
        case p1_archiveThemes = "p1.4"
        case p1_archiveFloors = "p1.5"
        case p1_snapshotUserDefaults = "p1.6"
        case p1_archiveCardLibrary = "p1.7"
        // Phase 2（codex Round 5 #1：verifyPrimary 必须紧跟 installStore + installStoreExternal，
        //          stickers/audiobooks/themes/floors 装之前 — 减少校验失败时的破坏面）
        case p2_installStore = "p2.1"
        case p2_installStoreExternal = "p2.2"
        case p2_verifyPrimary = "p2.3"        // plan v2 R-4 红线（新增）
        case p2_installStickers = "p2.4"
        case p2_installAudiobooks = "p2.5"
        case p2_installThemes = "p2.6"
        case p2_installFloors = "p2.7"
        case p2_applyUserDefaults = "p2.8"
        case p2_writeSlugMap = "p2.9"
        case p2_clearSyncState = "p2.10"
        case p2_installCardLibrary = "p2.11"
    }

    struct Marker: Codable {
        var state: State
        var completedSteps: [Step]
        var errors: [String]
        var startedAt: Date
        var updatedAt: Date
        var archiveDirName: String   // pre-import-archive/<ISO>/ 子目录名
    }

    /// pending-import.json schema（GlobalImporter 写入）
    ///
    /// plan v2 F-D：加 expected* 字段给 verifyPrimaryStore 双闸用。
    /// 全字段 Optional 兼容 v1 老 flag（codex Round 5 #4）—
    /// 老 flag 启动 apply 时 verifyPrimaryStore 入口 guard nil → 抛
    /// primaryValidationFailed 引导用户 cleanup + 重新导入。
    struct PendingFlag: Codable {
        let schemaVersion: Int
        let appBuild: String
        let schemaFingerprint: String
        let createdAt: Date
        let profileIds: [String]
        let floorSlugs: [String: String]
        // 新增（plan v2 R-4 双闸 — 都 Optional 兼容 v1）
        let expectedConvCount: Int?
        let expectedNodeCount: Int?
        let expectedConvIdsHash: String?
        /// 完整 expected conv ids（codex Round 5 #18 — 诊断价值高，2676 条约 100 KB 可接受）
        let expectedConvIds: [String]?
    }

    // MARK: - Result

    enum ApplyResult {
        case noFlag                                  // 无 .pending-import.json，正常启动
        case versionMismatch(reason: String)         // appBuild/fingerprint 不匹配，让 UI 清理
        case succeeded                               // 完成；继续正常启动
        case failedAtStep(Step, GlobalBackupError)   // 失败，让 UI 三选一
    }

    // MARK: - Public Entry

    /// MemoryPalaceApp.init 早期调
    static func applyIfNeeded() -> ApplyResult {
        let fm = FileManager.default

        // 1. 检查 flag
        guard fm.fileExists(atPath: StagingPaths.pendingImportFlagURL.path) else {
            return .noFlag
        }

        // 2. 读 flag + 比对 fingerprint
        let flagData: Data
        do {
            flagData = try Data(contentsOf: StagingPaths.pendingImportFlagURL)
        } catch {
            return .versionMismatch(reason: "无法读 .pending-import.json: \(error.localizedDescription)")
        }
        let flag: PendingFlag
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            flag = try decoder.decode(PendingFlag.self, from: flagData)
        } catch {
            return .versionMismatch(reason: "解析 .pending-import.json 失败")
        }

        let currentBuild = GlobalExportManifest.currentAppBuild()
        if flag.appBuild != currentBuild {
            return .versionMismatch(reason: "包是 build \(flag.appBuild) 写的，当前 app 是 build \(currentBuild)")
        }
        let currentFingerprint = SchemaCoverageCheck.fingerprint()
        if flag.schemaFingerprint != currentFingerprint {
            return .versionMismatch(reason: "数据 schema 已变")
        }

        // 3. 读 marker（如果有）
        let marker: Marker
        if fm.fileExists(atPath: StagingPaths.pendingImportMarkerURL.path) {
            do {
                let data = try Data(contentsOf: StagingPaths.pendingImportMarkerURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                marker = try decoder.decode(Marker.self, from: data)
            } catch {
                // marker 损坏 → 当作 idle 重头
                marker = Self.newMarker()
            }
        } else {
            marker = Self.newMarker()
        }

        // 4. 派发：state 决定下一步
        return run(marker: marker, flag: flag)
    }

    // MARK: - Internal Dispatch

    private static func run(marker initial: Marker, flag: PendingFlag) -> ApplyResult {
        var marker = initial

        // 写第一版 marker（含 archiveDirName，如果是新跑的）
        if marker.state == .idle && marker.completedSteps.isEmpty {
            marker.state = .phase1Archiving
            do {
                try persistMarker(marker)
            } catch {
                return .failedAtStep(.p1_archiveSwiftData, .pendingMarkerWriteFailed(error))
            }
        }

        // Phase 1 续作
        if marker.state == .phase1Archiving {
            if let err = runPhase1(&marker) {
                return .failedAtStep(err.step, err.error)
            }
            marker.state = .phase2Installing
            do { try persistMarker(marker) } catch {
                return .failedAtStep(.p1_snapshotUserDefaults, .pendingMarkerWriteFailed(error))
            }
        }

        // Phase 2 续作
        if marker.state == .phase2Installing {
            if let err = runPhase2(&marker, flag: flag) {
                return .failedAtStep(err.step, err.error)
            }
            marker.state = .done
            do { try persistMarker(marker) } catch {
                return .failedAtStep(.p2_clearSyncState, .pendingMarkerWriteFailed(error))
            }
        }

        // Done → cleanup
        finalCleanup()
        return .succeeded
    }

    // MARK: - Phase 1: Archive 主位 → pre-import-archive/<ISO>/

    private static func runPhase1(_ marker: inout Marker) -> (step: Step, error: GlobalBackupError)? {
        let archiveRoot = StagingPaths.preImportArchiveRoot
            .appendingPathComponent(marker.archiveDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)

        let p1Steps: [(Step, () throws -> Void)] = [
            (.p1_archiveSwiftData, {
                try moveIfExists(StagingPaths.primaryStoreURL, to: archiveRoot.appendingPathComponent("unified.store"))
                try moveIfExists(StagingPaths.primaryStoreExternalURL, to: archiveRoot.appendingPathComponent(".unified_SUPPORT", isDirectory: true))
                // 旧 wal/shm 一并隔离（codex Round 3 必改 #2）
                try moveIfExists(StagingPaths.walSidecar(of: StagingPaths.primaryStoreURL), to: archiveRoot.appendingPathComponent("unified.store-wal"))
                try moveIfExists(StagingPaths.shmSidecar(of: StagingPaths.primaryStoreURL), to: archiveRoot.appendingPathComponent("unified.store-shm"))
            }),
            (.p1_archiveStickers, {
                try moveIfExists(StagingPaths.primaryStickersRoot, to: archiveRoot.appendingPathComponent("stickers", isDirectory: true))
            }),
            (.p1_archiveAudiobooks, {
                try moveIfExists(StagingPaths.primaryAudiobooksRoot, to: archiveRoot.appendingPathComponent("audiobooks", isDirectory: true))
            }),
            (.p1_archiveThemes, {
                try moveIfExists(StagingPaths.primaryThemesRoot, to: archiveRoot.appendingPathComponent("themes", isDirectory: true))
            }),
            (.p1_archiveFloors, {
                try moveIfExists(StagingPaths.primaryFilelibraryRoot, to: archiveRoot.appendingPathComponent("floors", isDirectory: true))
            }),
            (.p1_snapshotUserDefaults, {
                try snapshotUserDefaults(to: archiveRoot.appendingPathComponent("userdefaults-before.plist"))
            }),
            (.p1_archiveCardLibrary, {
                try moveIfExists(StagingPaths.primaryCardLibraryRoot, to: archiveRoot.appendingPathComponent("cardlibrary", isDirectory: true))
            }),
        ]

        for (step, action) in p1Steps {
            if marker.completedSteps.contains(step) { continue }
            do {
                try action()
                marker.completedSteps.append(step)
                marker.updatedAt = Date()
                try persistMarker(marker)
            } catch {
                marker.errors.append("\(step.rawValue): \(error.localizedDescription)")
                try? persistMarker(marker)
                return (step, .phase1MoveFailed(step: step.rawValue, error))
            }
        }
        return nil
    }

    // MARK: - Phase 2: Install staging → 主位

    private static func runPhase2(_ marker: inout Marker, flag: PendingFlag) -> (step: Step, error: GlobalBackupError)? {
        let stagingDir = StagingPaths.applicationSupportRoot
            .appendingPathComponent("userdefaults-staging", isDirectory: true)

        let p2Steps: [(Step, () throws -> Void)] = [
            (.p2_installStore, {
                // 整库替换绕过 ModelContext：全文索引边车作废，启动后重新回填
                SearchIndexStore.removeFiles()
                try moveIfExists(StagingPaths.stagingStoreURL, to: StagingPaths.primaryStoreURL)
                // staging wal/shm 跟着（如果有 — checkpoint truncate 后通常 size=0 不存在）
                try moveIfExists(StagingPaths.walSidecar(of: StagingPaths.stagingStoreURL), to: StagingPaths.walSidecar(of: StagingPaths.primaryStoreURL))
                try moveIfExists(StagingPaths.shmSidecar(of: StagingPaths.stagingStoreURL), to: StagingPaths.shmSidecar(of: StagingPaths.primaryStoreURL))
            }),
            (.p2_installStoreExternal, {
                try moveIfExists(StagingPaths.stagingStoreExternalURL, to: StagingPaths.primaryStoreExternalURL)
            }),
            // ✨ plan v2 R-4 红线：install store + external 之后**立刻**校验主位
            // codex Round 5 #1：放最后会扩大破坏面到 stickers/audiobooks/etc。这里校验失败 →
            // reverseRollback 把主位 store + external 反向 move 回去就完整恢复。
            (.p2_verifyPrimary, {
                try verifyPrimaryStore(flag: flag)
            }),
            (.p2_installStickers, {
                try moveIfExists(StagingPaths.stagingStickersRoot, to: StagingPaths.primaryStickersRoot)
            }),
            (.p2_installAudiobooks, {
                try moveIfExists(StagingPaths.stagingAudiobooksRoot, to: StagingPaths.primaryAudiobooksRoot)
            }),
            (.p2_installThemes, {
                try moveIfExists(StagingPaths.stagingThemesRoot, to: StagingPaths.primaryThemesRoot)
            }),
            (.p2_installFloors, {
                try moveIfExists(StagingPaths.stagingFilelibraryRoot, to: StagingPaths.primaryFilelibraryRoot)
            }),
            (.p2_installCardLibrary, {
                try moveIfExists(StagingPaths.stagingCardLibraryRoot, to: StagingPaths.primaryCardLibraryRoot)
            }),
            (.p2_applyUserDefaults, {
                try applyStagingUserDefaults(from: stagingDir)
            }),
            (.p2_writeSlugMap, {
                if let data = try? JSONSerialization.data(withJSONObject: flag.floorSlugs, options: []) {
                    try BlobStore.set(data, forKey: "fileLibraryLocalDocumentsSlugMapV1")
                }
            }),
            (.p2_clearSyncState, {
                clearAllSyncStateFiles()
            }),
        ]

        for (step, action) in p2Steps {
            if marker.completedSteps.contains(step) { continue }
            do {
                try action()
                marker.completedSteps.append(step)
                marker.updatedAt = Date()
                try persistMarker(marker)
            } catch {
                marker.errors.append("\(step.rawValue): \(error.localizedDescription)")
                try? persistMarker(marker)
                return (step, .phase2MoveFailed(step: step.rawValue, error))
            }
        }
        return nil
    }

    // MARK: - Phase 2.3: verifyPrimaryStore (plan v2 R-4 红线)

    /// 用 SQLiteStoreVerifier 直接读主位 unified.store，跟 PendingFlag.expected* 字段比对。
    /// 必须在 p2_installStore + p2_installStoreExternal 完成后**立刻**跑（codex Round 5 #1）—
    /// 校验失败时只有 store + external 被改，reverseRollback 反向 move 就能完整恢复。
    ///
    /// 老 v1 flag（feature 还没正式发布，验收期可能有）没 expected* 字段 → 抛
    /// primaryValidationFailed 引导用户 cleanup + 重新导入。
    private static func verifyPrimaryStore(flag: PendingFlag) throws {
        // 1. 兼容性 guard：v1 老 flag 没 expected* 字段
        guard let expectedConvCount = flag.expectedConvCount,
              let expectedNodeCount = flag.expectedNodeCount,
              let expectedIdsHash = flag.expectedConvIdsHash else {
            throw GlobalBackupError.primaryValidationFailed(
                "pending flag 缺 v2 expected* 字段，请清理后重新导入")
        }

        // 2. SQLite 直接读主位 snapshot
        let snapshot: SQLiteStoreVerifier.Snapshot
        do {
            snapshot = try SQLiteStoreVerifier.snapshot(storeURL: StagingPaths.primaryStoreURL)
        } catch {
            throw GlobalBackupError.primaryValidationFailed(
                "SQLite 读取失败: \(error.localizedDescription)")
        }

        // 3. count 比对
        guard snapshot.convCount == expectedConvCount else {
            throw GlobalBackupError.primaryValidationFailed(
                "主位 conv count \(snapshot.convCount) ≠ expected \(expectedConvCount)")
        }
        guard snapshot.nodeCount == expectedNodeCount else {
            throw GlobalBackupError.primaryValidationFailed(
                "主位 node count \(snapshot.nodeCount) ≠ expected \(expectedNodeCount)")
        }

        // 4. ids hash 比对（含诊断模式：有 expectedConvIds 完整列表时报具体漂移）
        let actualIdsHash = SQLiteStoreVerifier.canonicalIdsHash(snapshot.convIds)
        guard actualIdsHash == expectedIdsHash else {
            var details = "ids hash mismatch"
            if let expectedIds = flag.expectedConvIds {
                let expectedSet = Set(expectedIds)
                let extras = snapshot.convIds.subtracting(expectedSet).sorted().prefix(3).joined(separator: ",")
                let missing = expectedSet.subtracting(snapshot.convIds).sorted().prefix(3).joined(separator: ",")
                details += " extras=\(extras) missing=\(missing)"
            }
            throw GlobalBackupError.primaryValidationFailed(details)
        }

        // [probe-1] R-4 verifyPrimaryStore 通过那一刻主位真实 snapshot
        // plan-fix-ios-import.md 假说定位
        NSLog("[probe-1] R4 pass: primary.nodes=\(snapshot.nodeCount) primary.convs=\(snapshot.convCount)")
    }

    // MARK: - Reverse Rollback (用户选择"放弃恢复原状")

    /// 按 completedSteps 反向 move，把主位恢复到导入前
    static func reverseRollback() throws {
        guard FileManager.default.fileExists(atPath: StagingPaths.pendingImportMarkerURL.path) else { return }
        let data = try Data(contentsOf: StagingPaths.pendingImportMarkerURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var marker = try decoder.decode(Marker.self, from: data)
        let archiveRoot = StagingPaths.preImportArchiveRoot
            .appendingPathComponent(marker.archiveDirName, isDirectory: true)

        // 反向 Phase 2：已 install 的回滚到 archive
        // 反向 Phase 1：archive 回到主位
        // 简化：先把 staging 资产清掉，然后从 archive 把原始资产 move 回主位

        StagingPaths.cleanupAllStagingArtifacts()  // 清 staging（含 staging-store / staging 文件区）

        // 从 archive 还原主位（覆盖语义 — 主位可能在 Phase 2 install 步已有新资产）
        let restoreMoves: [(URL, URL, String)] = [
            (archiveRoot.appendingPathComponent("unified.store"), StagingPaths.primaryStoreURL, "store"),
            (archiveRoot.appendingPathComponent(".unified_SUPPORT", isDirectory: true), StagingPaths.primaryStoreExternalURL, "store-external"),
            (archiveRoot.appendingPathComponent("unified.store-wal"), StagingPaths.walSidecar(of: StagingPaths.primaryStoreURL), "store-wal"),
            (archiveRoot.appendingPathComponent("unified.store-shm"), StagingPaths.shmSidecar(of: StagingPaths.primaryStoreURL), "store-shm"),
            (archiveRoot.appendingPathComponent("stickers", isDirectory: true), StagingPaths.primaryStickersRoot, "stickers"),
            (archiveRoot.appendingPathComponent("audiobooks", isDirectory: true), StagingPaths.primaryAudiobooksRoot, "audiobooks"),
            (archiveRoot.appendingPathComponent("themes", isDirectory: true), StagingPaths.primaryThemesRoot, "themes"),
            (archiveRoot.appendingPathComponent("floors", isDirectory: true), StagingPaths.primaryFilelibraryRoot, "floors"),
            (archiveRoot.appendingPathComponent("cardlibrary", isDirectory: true), StagingPaths.primaryCardLibraryRoot, "cardlibrary"),
        ]

        SearchIndexStore.removeFiles()
        for (src, dst, label) in restoreMoves {
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            // 主位已有 → 删，让 archive 完整覆盖回去
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.moveItem(at: src, to: dst)
            } catch {
                throw GlobalBackupError.reverseRollbackFailed(step: label, error)
            }
        }

        // 还原 UserDefaults
        let udBefore = archiveRoot.appendingPathComponent("userdefaults-before.plist")
        if FileManager.default.fileExists(atPath: udBefore.path) {
            try applyStagingUserDefaults(from: udBefore.deletingLastPathComponent(),
                                          plistFilename: "userdefaults-before.plist")
        }

        // 删 marker 跟 flag
        try? FileManager.default.removeItem(at: StagingPaths.pendingImportMarkerURL)
        try? FileManager.default.removeItem(at: StagingPaths.pendingImportFlagURL)

        marker.state = .aborted
        marker.updatedAt = Date()
    }

    // MARK: - Archive Pruning (30 天后清)

    /// 启动期调一次，清理 30 天以上的 archive
    static func pruneOldArchives() {
        let fm = FileManager.default
        let root = StagingPaths.preImportArchiveRoot
        guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let threshold = Date().addingTimeInterval(-30 * 24 * 3600)
        for name in items {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               mtime < threshold {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private static func newMarker() -> Marker {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        return Marker(
            state: .idle,
            completedSteps: [],
            errors: [],
            startedAt: now,
            updatedAt: now,
            archiveDirName: stamp
        )
    }

    private static func persistMarker(_ marker: Marker) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: StagingPaths.pendingImportMarkerURL, options: .atomic)
    }

    private static func moveIfExists(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        // dst 已有 → 先删（移到 archive 之后 dst 应该不存在；safety 兜底）
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.moveItem(at: src, to: dst)
    }

    // plan v2 F-A.4：删局部 walURL/shmURL，改调 StagingPaths.walSidecar(of:) / shmSidecar(of:)
    // 避免两处写法不一致（codex Round 5 #10）

    private static func snapshotUserDefaults(to plistURL: URL) throws {
        // 把 ConfigSchema 白名单 keys 的当前值 dump 进 plist
        var snapshot: [String: Any] = [:]
        for entry in ConfigSchema.allScalarEntries {
            if let v = UserDefaults.standard.object(forKey: entry.key) {
                snapshot[entry.key] = v
            }
        }
        for entry in ConfigSchema.structuredKeys {
            if let v = UserDefaults.standard.object(forKey: entry.key) {
                snapshot[entry.key] = v
            }
        }
        // 还要 dump 全量备份独有的内容 key
        let extraKeys = ["savedProfiles", "savedCharacterCards", "globalWorldBooks", "savedPresets",
                         "savedWritingStyles", "todoItems_v1", "petState_v1",
                         "fileLibraryLocalDocumentsSlugMapV1", "globalRegexScripts_v1"]
        for key in extraKeys {
            // 角色卡这类搬去文件的 blob 从 BlobStore 取（快照仍是 Data，回滚时写回文件）
            let v: Any? = BlobStore.migratedKeys.contains(key) ? BlobStore.data(forKey: key) : UserDefaults.standard.object(forKey: key)
            if let v {
                snapshot[key] = v
            }
        }
        // audiobook.checkpoint.*
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() {
            if k.hasPrefix("audiobook.checkpoint.") {
                snapshot[k] = v
            }
        }

        let data = try PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    /// Apply staging UserDefaults 的统一逻辑：
    /// 1. config.json 走 ConfigImporter.importAll
    /// 2. userdefaults/*.json 各自反序列化写回 stdUserDefaults
    /// 3. 或者直接读一个 plist 整段 apply（reverseRollback 走这条路）
    private static func applyStagingUserDefaults(from dir: URL, plistFilename: String? = nil) throws {
        let fm = FileManager.default

        // plist 整段 apply（reverseRollback 用）
        if let name = plistFilename {
            let plistURL = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: plistURL.path) else { return }
            let data = try Data(contentsOf: plistURL)
            guard let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
            for (k, v) in dict {
                if BlobStore.migratedKeys.contains(k) {
                    try BlobStore.set(v as? Data, forKey: k)
                } else {
                    UserDefaults.standard.set(v, forKey: k)
                }
            }
            return
        }

        // 正常 staging apply
        let cfgFile = dir.appendingPathComponent("config.json")
        if fm.fileExists(atPath: cfgFile.path) {
            let cfgData = try Data(contentsOf: cfgFile)
            try ConfigImporter.importAll(cfgData)
        }

        let udDir = dir.appendingPathComponent("userdefaults", isDirectory: true)
        if fm.fileExists(atPath: udDir.path) {
            let mapping: [(String, String)] = [
                ("profiles.json", "savedProfiles"),
                ("character_cards.json", "savedCharacterCards"),
                ("global_world_books.json", "globalWorldBooks"),
                ("presets.json", "savedPresets"),
                ("global_regex_scripts.json", "globalRegexScripts_v1"),
                ("writing_styles.json", "savedWritingStyles"),
                ("todo_items.json", "todoItems_v1"),
                ("pet_state.json", "petState_v1"),
                ("filelibrary_slug_map.json", "fileLibraryLocalDocumentsSlugMapV1"),
            ]
            for (filename, udKey) in mapping {
                let fileURL = udDir.appendingPathComponent(filename)
                guard fm.fileExists(atPath: fileURL.path) else { continue }
                let data = try Data(contentsOf: fileURL)
                guard let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
                if let blob = try? JSONSerialization.data(withJSONObject: obj, options: []) {
                    if BlobStore.migratedKeys.contains(udKey) {
                        try BlobStore.set(blob, forKey: udKey)
                    } else {
                        UserDefaults.standard.set(blob, forKey: udKey)
                    }
                }
            }

            // web_search 6 个 key
            let wsURL = udDir.appendingPathComponent("web_search.json")
            if fm.fileExists(atPath: wsURL.path) {
                let data = try Data(contentsOf: wsURL)
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (k, v) in dict {
                        if k == "webSearchProviders" || k == "webSearchBlockedDomains" {
                            // 重 encode 成 Data
                            if let blob = try? JSONSerialization.data(withJSONObject: v, options: []) {
                                UserDefaults.standard.set(blob, forKey: k)
                            }
                        } else {
                            // sanitize wrapper unsanitize（Date / Data 用 __type 标记的字典还原）
                            UserDefaults.standard.set(unsanitizeFromJSON(v), forKey: k)
                        }
                    }
                }
            }

            // audiobook checkpoints — Data 值用 __type wrapper 还原（GlobalExporter.sanitizeForJSON 配对）
            let cpURL = udDir.appendingPathComponent("audiobook_checkpoints.json")
            if fm.fileExists(atPath: cpURL.path) {
                let data = try Data(contentsOf: cpURL)
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (k, v) in dict {
                        UserDefaults.standard.set(unsanitizeFromJSON(v), forKey: k)
                    }
                }
            }
        }
    }

    /// 清 sync-state 4 类指纹（codex Round 3 强烈建议 #3）
    /// 验收 2 找到的根因：粟粟「咪」EB487C03 漂移**不是** staging container bug，
    /// 而是 SyncEngine 启动后从 `iCloud~com~susu~MemoryPalace/Documents/sync/{pid}/conversations/`
    /// 把 cp 自 MP_before_test 之前 export 过的「咪」JSON re-import 回主位。
    ///
    /// 修复（plan v2 F-F / codex Round 3 强烈建议 #3 的 follow-through）：
    /// 1. 清本地 sync-state/ 指纹 — SyncEngine 启动后觉得自己第一次跑（保留原逻辑）
    /// 2. **清 iCloud Documents/sync/ 整目录** — 让 SyncEngine 看到云端是空的不 import 任何东西
    /// 3. SyncEngine 启动后会重新 full export → 把主位（新 staging 内容）推回云端，
    ///    覆盖原 iCloud sync 目录 ≈ "以本地为准强制覆盖云端"
    ///
    /// plan v4 §G-D9 + codex Round 3 #3 当时只清本地指纹，但**没清云端目录本身**就让
    /// 反灌发生。验收 2 才把这个 gap 跑出来。
    /// GlobalExporter.sanitizeForJSON 的反向：把 __type wrapper 字典还原成 Date / Data。
    /// 递归 unsanitize dict / array。其他 JSON 兼容值原样返回。
    private static func unsanitizeFromJSON(_ obj: Any) -> Any {
        if let dict = obj as? [String: Any] {
            if let type = dict["__type"] as? String {
                if type == "Data", let b64 = dict["base64"] as? String,
                   let data = Data(base64Encoded: b64) {
                    return data
                }
                if type == "Date", let iso = dict["iso8601"] as? String {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = f.date(from: iso) { return date }
                }
            }
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = unsanitizeFromJSON(v) }
            return out
        }
        if let arr = obj as? [Any] { return arr.map(unsanitizeFromJSON) }
        return obj
    }

    private static func clearAllSyncStateFiles() {
        let fm = FileManager.default

        // 1. 清本地 export 指纹（含 legacy *-state.json 死格式）→ SyncEngine 重启后 full re-export
        //    import 账本（*.import.json）保留：mtime 没变的回流件多一层免疫
        //    （恢复纪元闸之外的 belt-and-suspenders，plan-fix-ios-import-impl H3）
        let syncStateDir = StagingPaths.applicationSupportRoot
            .appendingPathComponent("sync-state", isDirectory: true)
        if fm.fileExists(atPath: syncStateDir.path) {
            let items = (try? fm.contentsOfDirectory(atPath: syncStateDir.path)) ?? []
            for name in items {
                if name.hasSuffix(".export.json") ||
                   name.hasSuffix(".export-state.json") ||
                   name.hasSuffix(".import-state.json") {
                    try? fm.removeItem(at: syncStateDir.appendingPathComponent(name))
                }
            }
        }

        // 2. 清 iCloud Documents/sync/ 整目录（防 SyncEngine 反灌）
        //    路径跟 SyncStore.swift:39 一致：FileLibraryStore.iCloudDocumentsRoot()/sync
        //    nil safe — 用户没开 iCloud 时跳过
        if let iCloudDocs = FileLibraryStore.iCloudDocumentsRoot() {
            let cloudSyncDir = iCloudDocs.appendingPathComponent("sync", isDirectory: true)
            if fm.fileExists(atPath: cloudSyncDir.path) {
                // 清整个 sync/ 目录所有 profile：sync/{pid}/conversations/ + sync/{pid}/tombstones/ + sync/{pid}/floor.json
                try? fm.removeItem(at: cloudSyncDir)
                // 注：rm 整目录而不是逐文件 — 一次 atomic 系统调用，少触发 iCloud daemon
                // SyncEngine 启动后 SyncStore.syncRoot() 会重新 mkdir，正常工作
            }
        }

        // 3. 盖恢复纪元 + 首泵只出不进（plan-fix-ios-import-impl C1/H2）
        //    rm 只删本地副本、云端删除异步传播——mtime 早于纪元的回流件由 SyncStore 三道闸拒收。
        //    ⚠️ 两个 key 都是设备私有状态，绝不能进 GlobalExporter 的 UserDefaults 导出白名单
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SyncStore.restoreEpochKey)
        UserDefaults.standard.set(true, forKey: SyncStore.firstPumpExportOnlyKey)
    }

    private static func finalCleanup() {
        let fm = FileManager.default
        try? fm.removeItem(at: StagingPaths.pendingImportFlagURL)
        try? fm.removeItem(at: StagingPaths.pendingImportMarkerURL)
        // staging-userdefaults / userdefaults-staging
        let udStaging = StagingPaths.applicationSupportRoot
            .appendingPathComponent("userdefaults-staging", isDirectory: true)
        try? fm.removeItem(at: udStaging)
        // workspace 早已清；这里不再处理
    }

    // MARK: - Cleanup External (UI 用)

    /// 用户在 versionMismatch 时选择"清理放弃"
    static func cleanupVersionMismatch() {
        StagingPaths.cleanupAllStagingArtifacts()
        // 主位未动；正常启动
    }
}
