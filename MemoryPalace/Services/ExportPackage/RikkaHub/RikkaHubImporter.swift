import Foundation
import SwiftData

/// 扫描出来的一个 RikkaHub 备份：staging 里的库 + WAL + 附件；settings.json 只留下助手名（D2）
struct RikkaHubPackage {
    let stagingDir: URL
    /// 助手 id → 名字；没有 settings.json 或读不了就是空
    let assistantNames: [String: String]
    let hasSettings: Bool
}

/// 预览页的数。后台线程算；开库会在 staging 里回放 WAL，导入时再开的是同一份拷贝
struct RikkaHubPreview: Equatable {
    var conversations = 0
    var multiVersionPositions = 0
    var assistantFolders = 0
    var folderFolders = 0
    var memories = 0
    var attachments = 0
    /// 写库时的对话 id（预览先查跨楼层冲突，#061）
    var conversationIds: [String] = []
    var newerThanKnown = false
    /// 包里有、认得但不导的（D7 灰字）
    var ignored: [String] = []
    /// 打不开的包
    var failures: [String] = []

    var hasContent: Bool { conversations > 0 || memories > 0 }

    static func make(_ packages: [RikkaHubPackage]) -> RikkaHubPreview {
        var preview = RikkaHubPreview()
        var ignored: [String] = []
        for package in packages {
            do {
                let db = try RikkaHubDatabase(stagingDir: package.stagingDir)
                let rows = try db.conversations()
                preview.conversations += rows.count
                preview.conversationIds += rows.map { RikkaHubPayloadBuilder.conversationId($0.id) }
                preview.multiVersionPositions += try db.multiVersionPositionCount()
                let plan = RikkaHubImporter.folderPlan(rows: rows, folders: try db.folders(), names: package.assistantNames)
                preview.assistantFolders += plan.specs.filter { $0.source.hasPrefix(RikkaHubImporter.assistantSource) }.count
                preview.folderFolders += plan.specs.filter { $0.source.hasPrefix(RikkaHubImporter.folderSource) }.count
                preview.memories += try db.memories().count
                preview.newerThanKnown = preview.newerThanKnown || db.isNewerThanKnown
                if package.hasSettings { ignored += ["设置和 API key", "助手设定和提示词", "世界书", "模式注入", "快捷消息"] }
                if db.hasRows("favorites") { ignored.append("收藏") }
                if db.hasRows("GenMediaEntity") || db.hasRows("media_creation_record") { ignored.append("生图记录") }
                if db.hasRows("workspaces") { ignored.append("工作区") }
            } catch {
                preview.failures.append(error.localizedDescription)
            }
            let upload = package.stagingDir.appendingPathComponent("upload")
            preview.attachments += (try? FileManager.default.contentsOfDirectory(atPath: upload.path))?.count ?? 0
        }
        var seen = Set<String>()
        preview.ignored = ignored.filter { seen.insert($0).inserted }
        return preview
    }
}

/// RikkaHub 备份 → 花园（#048 plan §3.2）：文件夹（D4）→ 对话（每 200 段一批交引擎）→ 记忆（D5）
enum RikkaHubImporter {
    static let folderIdPrefix = "rikkahub"
    static let memorySource = "rikkahub-export"
    static let assistantSource = "assistant:"
    static let folderSource = "folder:"

    struct Outcome {
        var foldersCreated = 0
        var foldersExisting = 0
        var memoriesAdded = 0
        var memoriesExisting = 0
        var warnings = RikkaHubWarnings()
        var newerThanKnown = false
        var unreadable: [String] = []
    }

    static func assistantName(_ id: String, names: [String: String]) -> String {
        names[id] ?? "RikkaHub 助手 \(id.prefix(8))"
    }

    /// D4：在 RikkaHub 文件夹里的进「助手名 · 文件夹名」，其余进「助手名」；没有助手 id 的不进文件夹。
    /// 返回要建的文件夹 + 对话 id → 文件夹来源 id
    static func folderPlan(rows: [RikkaHubConversationRow], folders: [RikkaHubFolderRow], names: [String: String])
        -> (specs: [ImportFolders.Spec], sourceByConversation: [String: String]) {
        let folderById = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var specs: [ImportFolders.Spec] = []
        var seen = Set<String>()
        var sourceByConversation: [String: String] = [:]
        for row in rows {
            let source: String
            let name: String
            if let folder = folderById[row.folderId] {
                let owner = folder.assistantId.isEmpty ? row.assistantId : folder.assistantId
                let folderName = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
                source = folderSource + folder.id
                name = "\(assistantName(owner, names: names)) · \(folderName.isEmpty ? "文件夹" : folderName)"
            } else if !row.assistantId.isEmpty {
                source = assistantSource + row.assistantId
                name = assistantName(row.assistantId, names: names)
            } else {
                continue
            }
            sourceByConversation[row.id] = source
            if seen.insert(source).inserted {
                specs.append(.init(source: source, idPrefix: folderIdPrefix, name: name, instructions: ""))
            }
        }
        return (specs, sourceByConversation)
    }

    /// D5：一条一句，带助手名前缀；超长的按 Claude 记忆同款切
    static func memoryDrafts(_ memories: [RikkaHubMemoryRow], names: [String: String]) -> [ClaudeMemoryImporter.Draft] {
        memories.flatMap { memory -> [ClaudeMemoryImporter.Draft] in
            let prefix = memory.assistantId.isEmpty ? "（RikkaHub）" : "（RikkaHub 助手「\(assistantName(memory.assistantId, names: names))」）"
            return ClaudeMemoryImporter.split(memory.content).map { ClaudeMemoryImporter.Draft(content: prefix + $0, category: "context") }
        }
    }

    typealias Attachments = (_ segments: [MessageSegment], _ conversationId: String, _ title: String) -> [MessageSegment]

    /// 后台线程同步跑。打不开的包跳过并记下，不挡别的包。
    /// `attachments` 不传：内嵌附件由写库引擎外置到本楼层文件库（只对真写入的对话）；测试传别的，免得碰真文件库
    static func run(_ packages: [RikkaHubPackage], conversations: Bool, memories: Bool, profileId: String, recordId: UUID,
                    engine: PayloadImportEngine, context: ModelContext, timeZone: TimeZone = .current,
                    attachments: Attachments? = nil, progress: (Double) -> Void = { _ in }) throws -> Outcome {
        var outcome = Outcome()
        // 默认交给写库引擎转存（#050）：只对真写入的对话落盘，跳过 / 冲突的不留孤儿文件。测试传自己的 attachments
        let externalizeInEngine = attachments == nil
        let store: Attachments = attachments ?? { segments, _, _ in segments }
        for (index, package) in packages.enumerated() {
            let db: RikkaHubDatabase
            do {
                db = try RikkaHubDatabase(stagingDir: package.stagingDir)
            } catch {
                outcome.unreadable.append(error.localizedDescription)
                continue
            }
            outcome.newerThanKnown = outcome.newerThanKnown || db.isNewerThanKnown
            let names = package.assistantNames

            if conversations {
                let rows = try db.conversations()
                let plan = folderPlan(rows: rows, folders: try db.folders(), names: names)
                var folderIds: [String: String] = [:]
                if !plan.specs.isEmpty {
                    let r = try ImportFolders.ensure(plan.specs, profileId: profileId, recordId: recordId, context: context)
                    outcome.foldersCreated += r.created
                    outcome.foldersExisting += r.existing
                    folderIds = r.folderIdBySource
                    if r.created > 0 { engine.record.supportsUndo = true }
                }
                try importConversations(rows, db: db, package: package, folderIds: folderIds,
                                        sourceByConversation: plan.sourceByConversation, attachments: store,
                                        externalizeInEngine: externalizeInEngine, engine: engine, timeZone: timeZone, warnings: &outcome.warnings) { f in
                    progress((Double(index) + f) / Double(packages.count))
                }
            }

            if memories {
                let drafts = memoryDrafts(try db.memories(), names: names)
                if !drafts.isEmpty {
                    let r = try ClaudeMemoryImporter.apply(drafts, profileId: profileId, recordId: recordId,
                                                           extractedBy: memorySource, context: context)
                    outcome.memoriesAdded += r.added
                    outcome.memoriesExisting += r.existing
                    if r.added > 0 { engine.record.supportsUndo = true }
                }
            }
        }
        return outcome
    }

    private static func importConversations(_ rows: [RikkaHubConversationRow], db: RikkaHubDatabase, package: RikkaHubPackage,
                                            folderIds: [String: String], sourceByConversation: [String: String],
                                            attachments: Attachments, externalizeInEngine: Bool,
                                            engine: PayloadImportEngine, timeZone: TimeZone,
                                            warnings: inout RikkaHubWarnings, progress: (Double) -> Void) throws {
        let resolver = RikkaHubAttachmentResolver(stagingDir: package.stagingDir)
        for start in stride(from: 0, to: rows.count, by: ImportRunner.batchSize) {
            let end = min(start + ImportRunner.batchSize, rows.count)
            try autoreleasepool {
                var batch: [ImportedConversationPayload?] = []
                for row in rows[start..<end] {
                    let (positions, broken) = try db.positions(of: row.id)
                    warnings.brokenJSON += broken
                    var payload = RikkaHubPayloadBuilder.build(
                        row: row, positions: positions, assistantName: package.assistantNames[row.assistantId],
                        timeZone: timeZone, resolver: resolver, attachments: attachments, warnings: &warnings)
                    if let source = sourceByConversation[row.id] { payload?.folderId = folderIds[source] }
                    if externalizeInEngine { payload?.externalizeOnWrite = true }
                    batch.append(payload)
                }
                try engine.importBatch(batch)
            }
            progress(Double(end) / Double(max(rows.count, 1)))
        }
    }

    /// 完成页说明（ImportSummary.notes）
    static func notes(_ outcome: Outcome, timeZone: TimeZone = .current) -> [String] {
        var notes: [String] = []
        let w = outcome.warnings
        if w.missingAttachments > 0 {
            notes.append("RikkaHub：\(w.missingAttachments) 个附件包里没有（或是网址），留了带名字的占位")
        }
        if w.unknownParts + w.brokenJSON > 0 {
            notes.append("RikkaHub：\(w.unknownParts + w.brokenJSON) 段内容认不出来，没导")
        }
        if w.badTimestamps > 0 { notes.append("RikkaHub：\(w.badTimestamps) 条消息时间读不出来，留空") }
        notes.append("RikkaHub 的消息时间没带时区，按这台设备的时区（\(timeZone.identifier)）算")
        if outcome.newerThanKnown { notes.append("这个 RikkaHub 备份比已知的版本新，可能有没读到的内容") }
        for failure in outcome.unreadable { notes.append("有一个 RikkaHub 备份没导：\(failure)") }
        return notes
    }
}
