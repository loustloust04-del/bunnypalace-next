import Foundation
import SwiftData

/// 导入页的状态（#043 plan §3.4）。主线程只放状态；扫描、写库、写文件库都在后台跑。
@MainActor
@Observable
final class ImportSession {
    enum Phase: Equatable {
        case idle
        case scanning
        case preview
        /// 只选了 Claude 的下载清单 / 预览里点「去下载」（#059）
        case download
        case importing
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var scan: ExportPackageScan?
    private(set) var preview = ImportPreview()
    /// 这次选进来的 Claude 下载清单（#059）：链接只在这里、只在内存
    private(set) var claudeManifest: ClaudeExportManifest?
    /// ②在花园里下好的临时目录（换包 / 关页时删）和没下下来的包名（#059）
    private var downloadDirs: [URL] = []
    private(set) var downloadMissing: [String] = []
    /// 这次选进来的（②从预览进来时，下好的包和它们一起重新扫）
    private var pickedURLs: [URL] = []
    var selection = ImportSelection()
    var merge = false
    var copyConflicts = false

    private(set) var stage: ImportStage?
    private(set) var stageProgress: Double = 0
    private(set) var stages: [ImportStage] = []
    private(set) var summary = ImportSummary()
    /// 开始导入时预览里查到几段冲突（完成页对比：多出来的是消息 id 撞的，预览查不到）
    private(set) var previewConflicts = 0
    private var sourceName = ""
    /// 按来源先查的跨楼层冲突（#061）：键 = 注册表来源 id / `claudeConversationsKey` / `designChatsKey`
    private(set) var conflictReports: [String: ImportConflictReport] = [:]
    static let claudeConversationsKey = "claude.conversations"
    static let designChatsKey = "claude.design"

    var isBusy: Bool { phase == .scanning || phase == .importing }

    // MARK: - 预览页用的数

    var hasClaude: Bool {
        guard let scan else { return false }
        return !scan.claudeFiles.isEmpty || !scan.designChatFiles.isEmpty || !preview.projects.isEmpty
            || !preview.memoryDrafts.isEmpty || !preview.memoryFiles.isEmpty || !scan.artifactDirs.isEmpty
    }

    /// 这次扫描里有东西的注册表来源（预览页按它出分组）
    var presentSources: [ConversationImportSource] {
        guard let scan else { return [] }
        return ImportSources.conversationSources.filter { !$0.shownRows(scan, preview).isEmpty }
    }

    /// 勾上的来源合起来的冲突
    var conflictReport: ImportConflictReport {
        guard let scan else { return ImportConflictReport() }
        let s = selection
        // 按「对话」那一行（每个来源的第一行）勾没勾算：只勾了 RikkaHub 记忆的不算（sol #4）
        var keys = presentSources.filter { source in
            source.rows.first.map { row in s[row.key] && row.detail(scan, preview) != nil } ?? false
        }.map(\.id)
        if s.claudeConversations { keys.append(Self.claudeConversationsKey) }
        if s.designChats { keys.append(Self.designChatsKey) }
        return .merged(keys.compactMap { conflictReports[$0] })
    }

    var nothingSelected: Bool {
        guard let scan else { return true }
        let s = selection
        return !(presentSources.contains { $0.isSelected(s, scan, preview) }
            || (s.claudeConversations && !scan.claudeFiles.isEmpty)
            || (s.designChats && !scan.designChatFiles.isEmpty)
            || (s.projects && !preview.projects.isEmpty)
            || (s.memories && (!preview.memoryDrafts.isEmpty || !preview.memoryFiles.isEmpty))
            || (s.artifacts && !scan.artifactDirs.isEmpty))
    }

    // MARK: - 流程

    /// container 给了就顺手查跨楼层冲突（预览提示用）
    func open(_ urls: [URL], container: ModelContainer? = nil, profileId: String = "", sourceName: String? = nil) {
        guard !isBusy, !urls.isEmpty else { return }
        reset()
        phase = .scanning
        pickedURLs = urls
        self.sourceName = sourceName
            ?? (urls.count == 1 ? urls[0].lastPathComponent : "\(urls[0].lastPathComponent) 等 \(urls.count) 个")
        Task.detached(priority: .userInitiated) {
            let outcome: Result<(ExportPackageScan, ImportPreview, [String: ImportConflictReport]), Error> = Result {
                let scan = try ExportPackageScanner.scan(urls)
                var preview = ImportPreview.make(scan)
                preview.libraryInICloud = FileLibraryStore.documentsBaseRoot() != FileLibraryStore.localDocumentsBaseRoot()
                let reports = container.map { Self.probeConflicts(scan, preview, ModelContext($0), profileId) } ?? [:]
                return (scan, preview, reports)
            }
            await MainActor.run {
                switch outcome {
                case .success(let (scan, preview, reports)):
                    self.scan = scan
                    self.preview = preview
                    self.conflictReports = reports
                    self.claudeManifest = scan.claudeManifest
                    if scan.isEmpty, scan.claudeManifest != nil {
                        // 只选了清单：不算「没找到」，进下载页
                        Self.cleanupInBackground(scan)
                        self.scan = nil
                        self.phase = .download
                    } else if scan.isEmpty {
                        let seen = (scan.unrecognized + scan.emptyFiles).prefix(5).joined(separator: "、")
                        let tavern = scan.ignoredLabels.contains(ExportPackageScanner.sillyTavernLabel)
                        Self.cleanupInBackground(scan)
                        self.scan = nil
                        if !scan.rikkaHubSettingsOnly.isEmpty {
                            self.phase = .failed("这个 RikkaHub 备份没带聊天数据库（备份时没勾“数据库”），里面只有设置，不导入。")
                        } else if !scan.kelivoSettingsOnly.isEmpty {
                            self.phase = .failed("这个 Kelivo 备份没勾「聊天记录」，里面只有设置，不导入。")
                        } else if tavern {
                            self.phase = .failed("这是酒馆（SillyTavern）的数据，这里不导。去 卡库 › 导入酒馆整包，那边连角色卡、世界书一起导。")
                        } else {
                            self.phase = .failed("这里面没找到 Claude、ChatGPT、Gemini、RikkaHub 或 Kelivo 的导出数据"
                                                 + (seen.isEmpty ? "。" : "。看到的文件：\(seen)"))
                        }
                    } else {
                        self.phase = .preview
                    }
                case .failure(let error):
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 查不了就当没冲突（写库时照样会挡，完成页报）
    nonisolated static func probeConflicts(_ scan: ExportPackageScan, _ preview: ImportPreview,
                                           _ context: ModelContext, _ profileId: String) -> [String: ImportConflictReport] {
        var ids: [String: [String]] = [:]
        for source in ImportSources.conversationSources { ids[source.id] = source.conversationIds(scan, preview) }
        ids[claudeConversationsKey] = scan.claudeFiles.flatMap { $0.entries.map(\.id) }
        ids[designChatsKey] = scan.designChatFiles.compactMap {
            ClaudeImporter.loadDesignChat($0).flatMap { ClaudeImporter.makeDesignChatPayload($0, folderIdByProject: [:])?.id }
        }
        var out: [String: ImportConflictReport] = [:]
        for (key, list) in ids where !list.isEmpty {
            if let report = try? ImportConflictProbe.probe(ids: list, currentProfileId: profileId, context: context),
               !report.isEmpty {
                out[key] = report
            }
        }
        return out
    }

    /// floorNames：楼层 id → 名字，导入清单里的冲突记下导入当时的楼层名
    func start(container: ModelContainer, profileId: String, floorNames: [String: String] = [:]) {
        guard phase == .preview, let scan, !nothingSelected else { return }
        let preview = preview, selection = selection
        let options = ImportRunner.Options(merge: merge, copyConflicts: copyConflicts, sourceName: sourceName,
                                           floorNames: floorNames)
        previewConflicts = conflictReport.total
        stages = plannedStages(scan: scan)
        stage = stages.first
        stageProgress = 0
        phase = .importing
        BreadcrumbLog.shared.add("📥", "开始导入 \(sourceName)")
        Task.detached(priority: .userInitiated) {
            let summary = ImportRunner.run(
                scan: scan, preview: preview, selection: selection, options: options,
                profileId: profileId, container: container,
                libraryCreate: { try FileLibraryStore.createIfAbsent($0.relPath, content: $0.content, profileId: profileId) },
                progress: { stage, fraction in
                    Task { @MainActor in
                        self.stage = stage
                        self.stageProgress = fraction
                    }
                })
            scan.cleanup()
            await MainActor.run {
                var summary = summary
                summary.notes += preview.notes
                if !scan.unrecognized.isEmpty {
                    summary.notes.append("没认出来：\(scan.unrecognized.prefix(5).joined(separator: "、"))")
                }
                self.summary = summary
                self.scan = nil
                self.phase = .done
                BreadcrumbLog.shared.add("📥", "导入结束 \(summary.failure.map { "（\($0)）" } ?? "")")
            }
        }
    }

    /// 关页面 / 重新选：清 staging（删目录在后台，不卡界面）
    /// 预览里「去下载没选到的包」
    func showDownload() {
        guard phase == .preview, claudeManifest != nil else { return }
        phase = .download
    }

    /// 下载页「返回」：从预览来的回预览，只选了清单的回到选包
    func leaveDownload() {
        guard phase == .download else { return }
        if scan != nil { phase = .preview } else { reset() }
    }

    /// ②下完：下好的包进预览，目录归会话管。从预览进来的：和原来选的一起重新扫（勾选回到默认）
    func openDownloaded(_ dir: URL, files: [URL], missing: [String], container: ModelContainer? = nil, profileId: String = "") {
        guard !isBusy else { return }
        let earlier = scan != nil ? pickedURLs : []
        // 先摘下来，免得 open 里的 reset 把上一轮下好、这次还要扫的目录删了
        let dirs = downloadDirs + [dir]
        downloadDirs = []
        open(earlier + files, container: container, profileId: profileId,
             sourceName: earlier.isEmpty ? "从 claude.ai 下载的导出包" : nil)
        downloadDirs = dirs
        downloadMissing = missing
    }

    func reset() {
        guard !isBusy else { return }
        if let scan { Self.cleanupInBackground(scan) }
        scan = nil
        claudeManifest = nil
        let dirs = downloadDirs
        if !dirs.isEmpty {
            Task.detached(priority: .utility) { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
        }
        downloadDirs = []
        downloadMissing = []
        pickedURLs = []
        preview = ImportPreview()
        selection = ImportSelection()
        summary = ImportSummary()
        conflictReports = [:]
        previewConflicts = 0
        copyConflicts = false   // 选项只在预览查出冲突时出现，换包重来不沿用上次的
        stages = []
        stage = nil
        phase = .idle
    }

    nonisolated static func cleanupInBackground(_ scan: ExportPackageScan) {
        Task.detached(priority: .utility) { scan.cleanup() }
    }

    /// 上次崩溃 / 被杀留下的 staging：打开导入页时后台清一次
    nonisolated static func cleanupStaleStaging() {
        Task.detached(priority: .utility) {
            ExportPackageScanner.cleanupStale(in: FileManager.default.temporaryDirectory)
        }
    }

    func fail(_ message: String) {
        guard !isBusy else { return }
        phase = .failed(message)
    }

    private func plannedStages(scan: ExportPackageScan) -> [ImportStage] {
        let s = selection
        var out: [ImportStage] = []
        out += presentSources.filter { $0.isSelected(s, scan, preview) }.map(\.stage)
        if (s.projects && !preview.projects.isEmpty) || (s.designChats && !preview.designProjects.isEmpty) { out.append(.folders) }
        if s.claudeConversations, !scan.claudeFiles.isEmpty { out.append(.claude) }
        if s.designChats, !scan.designChatFiles.isEmpty { out.append(.design) }
        if s.memories, !preview.memoryDrafts.isEmpty { out.append(.memories) }
        if (s.projects && !preview.projects.isEmpty) || (s.memories && !preview.memoryFiles.isEmpty)
            || (s.artifacts && !scan.artifactDirs.isEmpty) { out.append(.library) }
        return out
    }
}
