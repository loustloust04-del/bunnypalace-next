import Foundation
import SwiftData

/// 扫描完、导入前给预览页看的东西（项目 / 记忆 / artifact 已解析好，导入时直接用）
struct ImportPreview {
    var projects: [ClaudeProject] = []
    var designProjects: [(uuid: String, name: String)] = []
    var memoryDrafts: [ClaudeMemoryImporter.Draft] = []
    var memoryFiles: [ClaudeMemoryImporter.MemoryFile] = []
    var artifactCount = 0
    var claudeBytes: Int64 = 0
    /// 文件库实际写到 iCloud 还是本机（开关开着但容器没就绪会回退本机）
    var libraryInICloud = false
    /// #047：只留计数，导入时重新解析
    var gemini = GeminiImportResult()
    var aiStudio = GeminiImportResult()
    var rikkaHub = RikkaHubPreview()
    var kelivo = KelivoPreview()
    var notes: [String] = []

    /// 后台线程调
    static func make(_ scan: ExportPackageScan) -> ImportPreview {
        var preview = ImportPreview()
        var seen = Set<String>()
        for url in scan.projectFiles {
            for project in ClaudeProject.load(url) ?? [] where seen.insert(project.uuid).inserted {
                preview.projects.append(project)
            }
        }
        preview.designProjects = ClaudeImporter.designProjects(scan.designChatFiles)
        let (parsed, badMemory) = ClaudeMemoryImporter.parse(scan.memoryFiles)
        let names = Dictionary(preview.projects.map { ($0.uuid, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        preview.memoryDrafts = ClaudeMemoryImporter.drafts(parsed, projectNames: names)
        preview.memoryFiles = parsed.memoryFiles
        preview.artifactCount = scan.artifactDirs.count
        preview.claudeBytes = scan.claudeFiles.reduce(0) {
            $0 + Int64((try? $1.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var unreadable: [String] = []
        for url in scan.geminiActivityFiles {
            do { preview.gemini.addCounts(of: try GeminiTakeoutParser.parse(file: url)) } catch { unreadable.append(url.lastPathComponent) }
        }
        for url in scan.aiStudioFiles {
            do { preview.aiStudio.addCounts(of: try AIStudioParser.parse(file: url)) } catch { unreadable.append(url.lastPathComponent) }
        }
        if !unreadable.isEmpty { preview.notes.append("读不了：\(unreadable.prefix(3).joined(separator: "、"))") }
        if !badMemory.isEmpty { preview.notes.append("记忆文件没认出来：\(badMemory.prefix(3).joined(separator: "、"))") }
        preview.rikkaHub = RikkaHubPreview.make(scan.rikkaHubPackages)
        preview.kelivo = KelivoPreview.make(scan.kelivoPackages)
        preview.notes += preview.kelivo.failures.map { "Kelivo 备份读不了：\($0)" }
        return preview
    }
}

/// 预览页的勾选。注册表里的来源按 id 记「关掉的」（默认全开），Claude 几项照旧
struct ImportSelection: Equatable {
    var claudeConversations = true
    var designChats = true
    var projects = true
    var memories = true
    var artifacts = true
    private var off: Set<String> = []

    subscript(source: String) -> Bool {
        get { !off.contains(source) }
        set { if newValue { off.remove(source) } else { off.insert(source) } }
    }
}

/// 一次导入的结果（完成页按卡片显示，只列非零项）
struct ImportSummary {
    var conversations = ImportCounts()
    var foldersCreated = 0
    var foldersExisting = 0
    var memoriesAdded = 0
    var memoriesExisting = 0
    var library = ClaudeLibraryImporter.ApplyResult()
    /// RikkaHub 的文件夹 / 记忆 / 警告（对话计数并在 conversations 里）
    var rikkaHub: RikkaHubImporter.Outcome?
    var librarySkipped: [String] = []
    /// 通用说明 / 警告（多文件合并、认不出的文件…；以后别的导入源也往这塞）
    var notes: [String] = []
    /// 注意事项（#050 E9）：同类合并计数，完成页折叠显示
    var warnings: [ImportWarnings.Group] = []
    /// 第一处失败（老字段，测试和导入历史用）
    var failedStep: String?
    var failure: String?
    /// 所有失败的步骤（来源之间不连累，可能不止一处）（sol #12）
    var failures: [(step: String, message: String)] = []
}

/// 导入阶段（进度页一行一个）。注册表里的来源各带一个
struct ImportStage: Hashable {
    let rawValue: String

    static let chatGPT = ImportStage(rawValue: "ChatGPT 对话")
    static let gemini = ImportStage(rawValue: "Gemini 活动")
    static let aiStudio = ImportStage(rawValue: "AI Studio")
    static let rikkaHub = ImportStage(rawValue: "RikkaHub 对话和记忆")
    static let kelivo = ImportStage(rawValue: "Kelivo 对话")
    static let folders = ImportStage(rawValue: "项目文件夹")
    static let claude = ImportStage(rawValue: "Claude 对话")
    static let design = ImportStage(rawValue: "设计对话")
    static let memories = ImportStage(rawValue: "花园记忆")
    static let library = ImportStage(rawValue: "写入文件库")
}

/// 导入执行（后台线程，同步跑）。顺序：注册表里的来源（ChatGPT → Gemini → AI Studio → RikkaHub → Kelivo）→ 文件夹 → Claude 对话（逐文件）
/// → 设计对话 → 记忆 → 文件库。来源之间失败不连累（#050 E8）；Claude 内部某一步失败就停。
/// 前面的照样留着（每批都已存好撤回信息），结果里标出失败那步。
enum ImportRunner {
    static let batchSize = 200

    struct Options {
        var merge = false
        var copyConflicts = false
        /// 导入记录上显示的来源名
        var sourceName = "导出包"
        /// 楼层 id → 名字（导入当时的快照，清单里的冲突带上）
        var floorNames: [String: String] = [:]
    }

    typealias Progress = (ImportStage, Double) -> Void

    static func run(scan: ExportPackageScan, preview: ImportPreview, selection: ImportSelection, options: Options,
                    profileId: String, container: ModelContainer,
                    libraryCreate: (LibraryWrite) throws -> Bool,
                    progress: Progress) -> ImportSummary {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var summary = ImportSummary()
        let mode: ImportMode = options.merge ? .merge : .normal
        let warnings = ImportWarnings()
        for name in scan.missingFromManifest where ImportSources.chatGPT.isSelected(selection, scan, preview) {
            warnings.add("清单里有、包里没有的分片（部分导入）", name)
        }

        func attempt(_ stage: ImportStage, _ body: () throws -> Void) -> Bool {
            do {
                try body()
                return true
            } catch {
                Self.recordFailure(&summary, step: stage.rawValue, message: error.localizedDescription)
                return false
            }
        }
        func finish(_ summary: ImportSummary, context: ModelContext) -> ImportSummary {
            var out = Self.finish(summary, context: context)
            out.warnings = warnings.groups
            return out
        }
        /// 导入清单（#061 B 期）：failuresFrom = 这条记录开始前 summary.failures 有几条
        let notIncluded = ImportManifest.notIncluded(scan, unchecked: uncheckedLabels(scan, preview, selection))
        func writeManifest(_ record: ImportRecord, _ sources: [ImportManifest.Source], failuresFrom: Int) {
            let manifest = ImportManifest(
                packages: scan.packageNames, sources: sources.filter { !$0.isEmpty }, notIncluded: notIncluded,
                failures: summary.failures.dropFirst(failuresFrom).map { .init(step: $0.step, message: $0.message) })
            record.detailData = manifest.encoded()
        }

        // 注册表里的来源：各自一条导入记录，失败不连累别的
        for source in ImportSources.conversationSources where source.isSelected(selection, scan, preview) {
            let record = ImportRecord(fileName: options.sourceName, provider: source.id, mode: mode, profileId: profileId)
            context.insert(record)
            var engine: PayloadImportEngine?
            let failuresBefore = summary.failures.count
            _ = attempt(source.stage) {
                let e = try PayloadImportEngine(context: context, profileId: profileId, record: record,
                                                merge: options.merge, copyConflicts: options.copyConflicts,
                                                warnings: warnings)
                e.floorNames = options.floorNames
                engine = e
                try withoutActuallyEscaping(progress) { progress in
                    let run = ConversationImportSource.Run(
                        scan: scan, preview: preview, selection: selection, engine: e, context: context,
                        profileId: profileId, recordId: record.id, progress: { progress(source.stage, $0) })
                    try source.run(run, &summary)
                }
            }
            if let engine {
                summary.conversations = summary.conversations + engine.counts
                if !options.merge, let hint = source.upgradeHint, engine.counts.skipped > 0 {
                    summary.notes.append("有 \(engine.counts.skipped) 段 \(source.label) 对话本地已有，这次跳过了。\(hint)，打开「叠加导入」再导一次同一个包（可撤回）。")
                }
            }
            writeManifest(record, engine?.sources ?? [], failuresFrom: failuresBefore)
            summary = Self.finish(summary, context: context, notes: false)
        }

        let wantsClaude = (selection.claudeConversations && !scan.claudeFiles.isEmpty)
            || (selection.designChats && !scan.designChatFiles.isEmpty)
            || (selection.projects && !preview.projects.isEmpty)
            || (selection.memories && !preview.memoryDrafts.isEmpty)
        guard wantsClaude else {
            summary = finish(summary, context: context)
            // 只导文件库（只勾了 artifacts / 记忆文件）也留一条记录，不可撤回（R6）
            guard let library = applyLibrary(into: &summary, scan: scan, preview: preview, selection: selection,
                                             create: libraryCreate, progress: progress) else { return summary }
            let record = ImportRecord(fileName: options.sourceName, provider: "claude", mode: mode, profileId: profileId)
            context.insert(record)
            writeManifest(record, [library], failuresFrom: summary.failures.count)
            return Self.finish(summary, context: context, notes: false)
        }

        let record = ImportRecord(fileName: options.sourceName, provider: "claude", mode: mode, profileId: profileId)
        context.insert(record)
        let failuresBefore = summary.failures.count
        /// 文件夹 / 记忆 / 文件库几段；对话那几段在 engine.sources，排在文件夹后面
        var claudeSources: [ImportManifest.Source] = []
        var engine: PayloadImportEngine?
        func claudeManifest() -> [ImportManifest.Source] {
            var out = claudeSources
            if let engine { out.insert(contentsOf: engine.sources, at: out.first?.kind == .projects ? 1 : 0) }
            return out
        }

        // 项目 → 文件夹（先建，对话导入时要用文件夹 id）
        var folderIds: [String: String] = [:]
        let projectsForFolders = selection.projects ? preview.projects : []
        let designForFolders = selection.designChats ? preview.designProjects : []
        if !projectsForFolders.isEmpty || !designForFolders.isEmpty {
            progress(.folders, 0)
            let ok = attempt(.folders) {
                let r = try ClaudeProjectFolders.apply(projects: projectsForFolders, designProjects: designForFolders,
                                                       profileId: profileId, recordId: record.id, context: context)
                folderIds = r.folderIdBySource
                summary.foldersCreated = r.created
                summary.foldersExisting = r.existing
                if r.created > 0 { record.supportsUndo = true }
                var folders = ImportManifest.Source(label: folderLabel(scan, projects: !projectsForFolders.isEmpty), kind: .projects)
                folders.foldersCreated = r.createdFolders
                folders.foldersExisting = r.existingFolders
                claudeSources.append(folders)
            }
            guard ok else {
                writeManifest(record, claudeManifest(), failuresFrom: failuresBefore)
                return finish(summary, context: context)
            }
        }

        let ok = attempt(.claude) {
            let e = try PayloadImportEngine(context: context, profileId: profileId, record: record,
                                            merge: options.merge, copyConflicts: options.copyConflicts,
                                            warnings: warnings)
            e.floorNames = options.floorNames
            engine = e
            if selection.claudeConversations {
                for (i, file) in scan.claudeFiles.enumerated() {
                    e.beginSource(scan.sourceLabel(file.url))
                    try importClaudeFile(file.url, folderIds: folderIds, engine: e) { f in
                        progress(.claude, (Double(i) + f) / Double(scan.claudeFiles.count))
                    }
                }
            }
            if selection.designChats, !scan.designChatFiles.isEmpty {
                progress(.design, 0)
                // 按所在目录分开记来源（几个包都有设计对话时各归各的）（sol #3）
                let byDir = Dictionary(grouping: scan.designChatFiles) { $0.deletingLastPathComponent() }
                for dir in byDir.keys.sorted(by: { $0.path < $1.path }) {
                    let files = byDir[dir] ?? []
                    e.beginSource("\(scan.sourceLabel(dir))（\(files.count) 个文件）", kind: .designChats)
                    try importDesignChats(files, folderIds: folderIds, engine: e)
                }
            }
        }
        if let engine { summary.conversations = summary.conversations + engine.counts }
        guard ok else {
            writeManifest(record, claudeManifest(), failuresFrom: failuresBefore)
            return finish(summary, context: context)
        }

        if selection.memories, !preview.memoryDrafts.isEmpty {
            progress(.memories, 0)
            let ok = attempt(.memories) {
                let r = try ClaudeMemoryImporter.apply(preview.memoryDrafts, profileId: profileId,
                                                       recordId: record.id, context: context)
                summary.memoriesAdded = r.added
                summary.memoriesExisting = r.existing
                if r.added > 0 { record.supportsUndo = true }
                var memories = ImportManifest.Source(label: scan.memoryFiles.map(scan.sourceLabel).joined(separator: "、"),
                                                     kind: .memories)
                memories.memoriesAdded = r.added
                memories.memoriesExisting = r.existing
                claudeSources.append(memories)
            }
            guard ok else {
                writeManifest(record, claudeManifest(), failuresFrom: failuresBefore)
                return finish(summary, context: context)
            }
        }

        writeManifest(record, claudeManifest(), failuresFrom: failuresBefore)
        summary = finish(summary, context: context)
        // Claude 段都成了、最后也存上了，才写文件库（别的来源失败不影响）
        guard !summary.failures.contains(where: { !sourceSteps.contains($0.step) }) else { return summary }
        if let library = applyLibrary(into: &summary, scan: scan, preview: preview, selection: selection,
                                      create: libraryCreate, progress: progress) {
            claudeSources.append(library)
            writeManifest(record, claudeManifest(), failuresFrom: failuresBefore)
            summary = Self.finish(summary, context: context, notes: false)
        }
        return summary
    }

    /// 包里有、这次没勾的类别（清单「没导入」段）
    private static func uncheckedLabels(_ scan: ExportPackageScan, _ preview: ImportPreview,
                                        _ selection: ImportSelection) -> [String] {
        var out: [String] = []
        for source in ImportSources.conversationSources {
            for item in source.shownRows(scan, preview) where !selection[item.row.key] {
                out.append("\(source.label) \(item.row.title)")
            }
        }
        if !selection.claudeConversations, !scan.claudeFiles.isEmpty { out.append("Claude 对话") }
        if !selection.designChats, !scan.designChatFiles.isEmpty { out.append("Claude 设计对话") }
        if !selection.projects, !preview.projects.isEmpty { out.append("Claude 项目") }
        if !selection.memories, !preview.memoryDrafts.isEmpty || !preview.memoryFiles.isEmpty { out.append("Claude 记忆") }
        if !selection.artifacts, !scan.artifactDirs.isEmpty { out.append("Claude Artifacts") }
        return out
    }

    /// 项目 → 文件夹那一步在清单里的名字
    private static func folderLabel(_ scan: ExportPackageScan, projects: Bool) -> String {
        guard projects, let file = scan.projectFiles.first else { return "设计项目" }
        return scan.projectFiles.count == 1 ? scan.sourceLabel(file) : "\(scan.sourceLabel(file)) 等 \(scan.projectFiles.count) 个"
    }

    private static let sourceSteps = Set(ImportSources.conversationSources.map(\.stage.rawValue))

    private static func recordFailure(_ summary: inout ImportSummary, step: String, message: String) {
        summary.failures.append((step, message))
        if summary.failure == nil {
            summary.failedStep = step
            summary.failure = message
        }
    }

    /// 文件库这步不随撤回删除（文件不删），失败的文件逐个列出，不中断。
    /// 返回清单里的「文件库」一段；什么都没有 = nil
    private static func applyLibrary(into summary: inout ImportSummary, scan: ExportPackageScan, preview: ImportPreview,
                                     selection: ImportSelection, create: (LibraryWrite) throws -> Bool,
                                     progress: Progress) -> ImportManifest.Source? {
        let plan = ClaudeLibraryImporter.plan(
            projects: selection.projects ? preview.projects : [],
            memoryFiles: selection.memories ? preview.memoryFiles.map { ($0.path, $0.content) } : [],
            artifactDirs: selection.artifacts ? scan.artifactDirs : [])
        summary.librarySkipped = plan.skipped
        var source = ImportManifest.Source(label: "文件库", kind: .library)
        source.library = plan.skipped.map { .init(path: $0, reason: "跳过") }
        if !plan.writes.isEmpty {
            progress(.library, 0)
            summary.library = ClaudeLibraryImporter.apply(plan.writes, create: create)
            source.library = summary.library.items + source.library
        }
        return source.library.isEmpty ? nil : source
    }

    private static func finish(_ summary: ImportSummary, context: ModelContext, notes: Bool = true) -> ImportSummary {
        var summary = summary
        do {
            try context.save()
        } catch {
            recordFailure(&summary, step: "保存", message: error.localizedDescription)
        }
        guard notes else { return summary }
        if summary.conversations.mergedDuplicates > 0 {
            summary.notes.append("\(summary.conversations.mergedDuplicates) 段对话在多个文件里都有，已合成一段")
        }
        return summary
    }

    // MARK: - 单个文件（测试也走这里）

    /// 文件按对话切片逐条解码（#050 E2）：坏一条只丢那一条（计「未导入」+ 注意事项）；
    /// 整个文件一条都切不出来才算这步失败
    static func importClaudeFile(_ url: URL, folderIds: [String: String], engine: PayloadImportEngine,
                                 progress: (Double) -> Void = { _ in }) throws {
        let file = try sliced(url, engine: engine)
        let decoder = ClaudeImporter.makeClaudeDecoder()
        try inBatches(file.count, progress: progress) { range in
            try engine.importBatch(range.map { i -> ImportedConversationPayload? in
                guard let raw = decodeOrWarn(file, ClaudeRawConversation.self, at: i, decoder: decoder, url: url, engine: engine) else { return nil }
                return ClaudeImporter.payload(from: raw, folderIdByProject: folderIds)
            }, offset: range.lowerBound)
        }
    }

    static func importChatGPTFile(_ url: URL, engine: PayloadImportEngine, assets: ChatGPTAssetIndex = .init(),
                                  progress: (Double) -> Void = { _ in }) throws {
        let file = try sliced(url, engine: engine)
        let builder = ChatGPTPayloadBuilder(assets: assets, warnings: engine.warnings)
        let decoder = JSONDecoder()
        try inBatches(file.count, progress: progress) { range in
            try engine.importBatch(range.map { i in
                decodeOrWarn(file, RawConversation.self, at: i, decoder: decoder, url: url, engine: engine)
                    .flatMap { builder.payload(from: $0) }
            }, offset: range.lowerBound)
        }
    }

    private static func sliced(_ url: URL, engine: PayloadImportEngine) throws -> JSONArrayFile {
        let file = try JSONArrayFile(url: url)
        if let error = file.error {
            guard file.count > 0 else { throw ExportPackageError.unreadable("\(url.lastPathComponent)：\(error)") }
            engine.warnings.add("文件不完整，只导了前面能读的部分", "\(url.lastPathComponent)：\(error)")
        }
        return file
    }

    private static func decodeOrWarn<T: Decodable>(_ file: JSONArrayFile, _ type: T.Type, at i: Int, decoder: JSONDecoder,
                                                   url: URL, engine: PayloadImportEngine) -> T? {
        do {
            return try file.decode(type, at: i, decoder: decoder)
        } catch {
            engine.warnings.add("有对话格式读不出来，跳过了", "\(url.lastPathComponent) 第 \(i + 1) 段")
            return nil
        }
    }

    /// 内嵌图先落文件库再交引擎（引擎直接存 segmentsData）
    /// Gemini / AI Studio 的 payload 分批写；内嵌图（`.image` / `.fileData`）由引擎只对真写入的对话转存进文件库
    static func importGeminiPayloads(_ payloads: [ImportedConversationPayload], engine: PayloadImportEngine) throws {
        try inBatches(payloads.count) { range in
            try engine.importBatch(payloads[range].map {
                var p = $0
                p.externalizeOnWrite = true
                return p
            }, offset: range.lowerBound)
        }
    }

    /// 读不出来的设计对话算「未导入」
    static func importDesignChats(_ urls: [URL], folderIds: [String: String], engine: PayloadImportEngine) throws {
        let payloads = urls.map { url in
            ClaudeImporter.loadDesignChat(url).flatMap { ClaudeImporter.makeDesignChatPayload($0, folderIdByProject: folderIds) }
        }
        try inBatches(payloads.count) { range in try engine.importBatch(Array(payloads[range]), offset: range.lowerBound) }
    }

    private static func inBatches(_ count: Int, progress: (Double) -> Void = { _ in },
                                  _ body: (Range<Int>) throws -> Void) throws {
        for start in stride(from: 0, to: count, by: batchSize) {
            let end = min(start + batchSize, count)
            try autoreleasepool { try body(start..<end) }
            progress(Double(end) / Double(max(count, 1)))
        }
    }
}
