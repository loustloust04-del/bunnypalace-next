import Foundation
import SwiftData

/// 导入源注册表（#050 E1）：Claude 以外的来源（ChatGPT / Gemini / AI Studio / RikkaHub / Kelivo …）。
///
/// 加一个来源 = 扫描器里加分类规则（把文件收进 `ExportPackageScan`）+ 这里加一项。
/// 预览页的分组和勾选行、导入阶段、导入步骤（各自一条导入记录、失败不连累别的来源）都按这张表循环。
/// 导入历史的名字、侧栏 / 日历的「导入的对话」图标看 `Conversation.importedProviders`。
/// Claude 自带项目 / 记忆 / 文件库，单独走 `ImportRunner` 里的 Claude 段。
struct ConversationImportSource: Identifiable {
    /// 预览页的一行勾选
    struct Row {
        /// `ImportSelection` 的下标
        let key: String
        let title: String
        /// 这一行的说明；nil = 这次没有这类东西，不显示
        let detail: (ExportPackageScan, ImportPreview) -> String?
    }

    /// 跑一个来源时手边的东西
    struct Run {
        let scan: ExportPackageScan
        let preview: ImportPreview
        let selection: ImportSelection
        let engine: PayloadImportEngine
        let context: ModelContext
        let profileId: String
        let recordId: UUID
        let progress: (Double) -> Void
    }

    /// = ImportRecord.provider = Conversation.provider
    let id: String
    /// 预览分组标题「识别到 · <label>」，也用在完成页提示里
    let label: String
    let stage: ImportStage
    var footnote: (ExportPackageScan, ImportPreview) -> String? = { _, _ in nil }
    let rows: [Row]
    /// 写库走 `run.engine`；完成页要的说明 / 统计写进 summary
    let run: (Run, inout ImportSummary) throws -> Void
    /// 普通模式下跳过的本地已有对话：完成页提示「开叠加再导一次」能得到什么（nil 不提示）
    var upgradeHint: String?
    /// 写库时用的对话 id，预览先查跨楼层冲突（#061）。给不出就空，冲突只在完成页报
    var conversationIds: (ExportPackageScan, ImportPreview) -> [String] = { _, _ in [] }

    /// 这次有东西的行（行 + 说明）
    func shownRows(_ scan: ExportPackageScan, _ preview: ImportPreview) -> [(row: Row, detail: String)] {
        rows.compactMap { row in row.detail(scan, preview).map { (row, $0) } }
    }

    func isSelected(_ selection: ImportSelection, _ scan: ExportPackageScan, _ preview: ImportPreview) -> Bool {
        shownRows(scan, preview).contains { selection[$0.row.key] }
    }
}

enum ImportSources {
    static let conversationSources: [ConversationImportSource] = [chatGPT, gemini, aiStudio, rikkaHub, kelivo]

    static let chatGPT = ConversationImportSource(
        id: "chatgpt", label: "ChatGPT", stage: .chatGPT,
        rows: [.init(key: "chatgpt", title: "对话") { scan, _ in
            guard !scan.chatGPTFiles.isEmpty else { return nil }
            var text = "\(scan.chatGPTConversationCount) 段 · 保留分支、思考和工具 → 本楼层"
            if !scan.chatGPTAssets.isEmpty { text += "；包里带 \(scan.chatGPTAssets.count) 个附件，能对上的存进文件库" }
            return text
        }],
        run: { run, _ in
            let files = run.scan.chatGPTFiles
            for (i, file) in files.enumerated() {
                run.engine.beginSource(run.scan.sourceLabel(file.url))
                try ImportRunner.importChatGPTFile(file.url, engine: run.engine, assets: run.scan.chatGPTAssets) { f in
                    run.progress((Double(i) + f) / Double(files.count))
                }
            }
        },
        upgradeHint: "想让它们也带上思考、工具和图片",
        // 缺 id 的写库时按内容算哈希，这里算不到（扫描给的是「无id:」占位）
        conversationIds: { scan, _ in scan.chatGPTFiles.flatMap { $0.entries.map(\.id) }.filter { !$0.hasPrefix("无id:") } })

    private static let experimentalFootnote = "格式是照公开资料推的，还没拿真导出包对过，导完对照原对话看一眼。已有的对话只有打开「叠加导入」才会补上新问答。"

    static let gemini = ConversationImportSource(
        id: GeminiTakeoutParser.provider, label: "Gemini（实验性）", stage: .gemini,
        footnote: { _, _ in experimentalFootnote },
        rows: [.init(key: GeminiTakeoutParser.provider, title: "对话") { scan, p in
            guard !scan.geminiActivityFiles.isEmpty else { return nil }
            let g = p.gemini
            var text = "活动 \(g.activityCount) 条 → 约 \(g.conversationCount) 段"
            if g.inferredConversationCount > 0 {
                text += "（\(g.explicitConversationCount) 段按会话链接，\(g.inferredConversationCount) 段按时间间隔推测）"
            }
            return text + " → 本楼层"
        }],
        run: { run, summary in
            summary.notes += try runGemini(run.scan.geminiActivityFiles, run: run) { try GeminiTakeoutParser.parse(file: $0) }
        },
        conversationIds: { _, p in p.gemini.conversationIds })

    static let aiStudio = ConversationImportSource(
        id: AIStudioParser.provider, label: "AI Studio（实验性）", stage: .aiStudio,
        footnote: { _, _ in experimentalFootnote },
        rows: [.init(key: AIStudioParser.provider, title: "对话") { scan, p in
            scan.aiStudioFiles.isEmpty ? nil
                : "\(p.aiStudio.conversationCount) 段 → 本楼层；系统指令和参数只记在对话来源里，不会套用"
        }],
        run: { run, summary in
            summary.notes += try runGemini(run.scan.aiStudioFiles, run: run, parse: AIStudioParser.parse(file:))
        },
        conversationIds: { _, p in p.aiStudio.conversationIds })

    /// RikkaHub（#048）：对话 / 记忆两行勾选，文件夹 / 对话 / 记忆同一条导入记录，一起撤
    static let rikkaHub = ConversationImportSource(
        id: RikkaHubPayloadBuilder.provider, label: "RikkaHub（实验性）", stage: .rikkaHub,
        footnote: { _, p in
            let r = p.rikkaHub
            var lines: [String] = []
            if !r.ignored.isEmpty { lines.append("不导入：\(r.ignored.joined(separator: "、"))。") }
            lines.append("消息时间按这台设备的时区算。")
            if r.newerThanKnown { lines.append("这个备份比已知版本新，可能有没读到的内容。") }
            lines += r.failures.map { "没法读：\($0)" }
            return lines.joined(separator: "\n")
        },
        rows: [
            .init(key: "rikkahub.conversations", title: "对话") { _, p in
                let r = p.rikkaHub
                guard r.conversations > 0 else { return nil }
                var text = "\(r.conversations) 段"
                if r.multiVersionPositions > 0 { text += "（\(r.multiVersionPositions) 处有多个版本，导成可左右切的分支）" }
                text += " → 本楼层"
                let folders = r.assistantFolders + r.folderFolders
                if folders > 0 { text += "，按助手 / 文件夹归进 \(folders) 个文件夹" }
                if r.attachments > 0 { text += "；附件 \(r.attachments) 个 → 文件库" }
                return text
            },
            .init(key: "rikkahub.memories", title: "记忆") { _, p in
                p.rikkaHub.memories > 0 ? "\(p.rikkaHub.memories) 条 → 花园记忆（不钉住，前面带助手名）" : nil
            },
        ],
        run: { run, summary in
            run.engine.beginSource(run.scan.rikkaHubPackages.map { run.scan.sourceLabel($0.stagingDir) }.joined(separator: "、"))
            let outcome = try RikkaHubImporter.run(
                run.scan.rikkaHubPackages, conversations: run.selection["rikkahub.conversations"],
                memories: run.selection["rikkahub.memories"], profileId: run.profileId, recordId: run.recordId,
                engine: run.engine, context: run.context, progress: run.progress)
            run.engine.writeRecordCounts()
            run.engine.note {
                $0.memoriesAdded = outcome.memoriesAdded
                $0.memoriesExisting = outcome.memoriesExisting
            }
            summary.rikkaHub = outcome
            summary.notes += RikkaHubImporter.notes(outcome)
        },
        conversationIds: { _, p in p.rikkaHub.conversationIds })

    /// Kelivo（#049）：新旧两代备份；两代官方 macOS 版真导出对过，不标实验性（plan D6）
    static let kelivo = ConversationImportSource(
        id: KelivoBackup.provider, label: "Kelivo", stage: .kelivo,
        footnote: { _, _ in "不导入：设置和 API key、助手、供应商、MCP、记忆、快捷短语。助手名和系统提示词只记在对话来源里，不套用。" },
        rows: [.init(key: KelivoBackup.provider, title: "对话") { _, p in
            let k = p.kelivo
            guard k.conversations > 0 else { return nil }
            let kind = k.legacyPackages > 0 && k.modernPackages > 0 ? "新旧两代备份"
                : (k.legacyPackages > 0 ? "旧版备份" : "新版备份")
            var text = "\(k.conversations) 段 · \(kind)"
            if k.regenerated > 0 { text += "，含 \(k.regenerated) 处重新生成，所有版本都保留" }
            text += " → 本楼层"
            if k.attachments > 0 { text += "；附件 \(k.attachments) 个 → 文件库" }
            return text
        }],
        run: { run, summary in
            // 导入清单（#061）：几个包合成一个来源记
            run.engine.beginSource(run.scan.kelivoPackages.map { package -> String in
                switch package.content {
                case .legacy(let chats): return run.scan.sourceLabel(chats)
                case .modern(let manifest, _): return run.scan.sourceLabel(manifest)
                }
            }.joined(separator: "、"))
            summary.notes += try KelivoImporter.run(run.scan.kelivoPackages, engine: run.engine, progress: run.progress).notes
        },
        conversationIds: { _, p in p.kelivo.conversationIds })

    /// Gemini / AI Studio（#047）：整文件解析后分批写；内嵌图交给引擎只对真写入的对话转存
    private static func runGemini(_ files: [URL], run: ConversationImportSource.Run,
                                  parse: (URL) throws -> GeminiImportResult) throws -> [String] {
        var stats = GeminiImportResult()
        for (i, url) in files.enumerated() {
            run.progress(Double(i) / Double(files.count))
            run.engine.beginSource(run.scan.sourceLabel(url))
            let parsed = try parse(url)
            stats.addCounts(of: parsed)
            try ImportRunner.importGeminiPayloads(parsed.payloads, engine: run.engine)
        }
        return stats.notes
    }
}
