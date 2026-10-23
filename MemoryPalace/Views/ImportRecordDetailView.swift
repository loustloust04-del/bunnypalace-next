import SwiftUI
import SwiftData

/// 导入历史 › 一次导入的详情（#061 A 期）：这次导进来的对话 / 文件夹 / 记忆现在在哪，撤回也在这里
struct ImportRecordDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.settingsMetrics) private var m
    @Environment(\.dismiss) private var dismiss
    let recordId: UUID
    let profileId: String

    @State private var record: ImportRecord?
    @State private var detail: ImportRecordDetail?
    @State private var loadError: String?
    @State private var confirmingUndo = false
    @State private var undoMessage = ""
    @State private var isUndoing = false
    @State private var undoProgress: Double = 0
    @State private var undoTotal = 1
    @State private var undoFailed = false

    /// 一组展开后最多列这么多段，再多只写数
    private static let listLimit = 200

    var body: some View {
        SettingsSectionList(.list) {
            if let record {
                Section {
                    infoRow("来源", "\(record.fileName) · \(Conversation.importedProviderName(record.provider) ?? record.provider)")
                    infoRow("时间", record.dateText)
                    infoRow("方式", record.modeLabel)
                    infoRow("结果", countsText(record))
                }
                if let detail {
                    if let manifest = detail.manifest { manifestSections(manifest, titles: detail.titles) }
                    conversationSections(detail)
                    if !detail.folders.isEmpty { folderSection(detail.folders) }
                    if !detail.memories.isEmpty { memorySection(detail.memories) }
                } else if let loadError {
                    Section { Text("读不出来：\(loadError)").font(m.secondary).foregroundColor(Theme.danger) }
                } else {
                    Section { ProgressView().frame(maxWidth: .infinity) }
                }
                Section {
                    undoArea(record)
                } footer: {
                    Text(detail?.manifest == nil
                         ? "这条是旧版导入的，按撤回记录查：列出的是这次新建 / 更新的东西现在的样子。来源文件、跳过的是哪些、文件库写到哪，当时没记下来。"
                         : "对话 / 文件夹 / 记忆列的是现在的样子（挪过文件夹、删过的照实显示）；「来源文件」是导入当时记下的。")
                }
            } else {
                Section { Text("这条导入记录已经不在了。").font(m.secondary).foregroundColor(Theme.textMuted) }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("导入详情")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: recordId) { await load() }
        .confirmationDialog("确认撤回", isPresented: $confirmingUndo, titleVisibility: .visible) {
            Button("撤回此次导入", role: .destructive) { if let record { undo(record) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(undoMessage)
        }
    }

    // MARK: - 各段

    /// 导入清单：按来源文件一段一段列「去了哪」，最后是没导入的
    @ViewBuilder
    private func manifestSections(_ manifest: ImportManifest, titles: [String: String]) -> some View {
        if !manifest.sources.isEmpty {
            Section(manifest.packages.count > 1 ? "来源文件（选了 \(manifest.packages.count) 个包）" : "来源文件") {
                ForEach(Array(manifest.sources.enumerated()), id: \.offset) { _, source in
                    sourceGroup(source, titles: titles)
                }
            }
        }
        if !manifest.failures.isEmpty || !manifest.notIncluded.isEmpty {
            Section("没导入") {
                ForEach(manifest.failures, id: \.step) { failure in
                    Text("「\(failure.step)」这步出错：\(failure.message)")
                        .font(m.secondary)
                        .foregroundColor(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(manifest.notIncluded, id: \.self) { line in
                    Text(line)
                        .font(m.secondary)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func sourceGroup(_ source: ImportManifest.Source, titles: [String: String]) -> some View {
        DisclosureGroup {
            listBlock("新建", source.created.map { titles[$0] ?? "（已删除）" }, total: source.created.count)
            listBlock("复制为副本", source.copied.map { titles[$0] ?? "（已删除）" }, total: source.copied.count)
            listBlock("更新", source.updated.map { titles[$0] ?? "（已删除）" }, total: source.updated.count)
            listBlock("本地已有，跳过", source.skipped.map(\.title), total: source.skippedCount)
            listBlock("已在其他楼层", source.conflicts.map(conflictLine), total: source.conflictCount)
            listBlock("空白 / 读不出来", source.empty, total: source.emptyCount)
            listBlock("新建的文件夹", source.foldersCreated.map(\.title), total: source.foldersCreated.count)
            listBlock("已有的文件夹（没动）", source.foldersExisting.map(\.title), total: source.foldersExisting.count)
            listBlock("写进文件库", source.library.filter { $0.reason == nil }.map(\.path),
                      total: source.library.filter { $0.reason == nil }.count)
            listBlock("文件库没写", source.library.compactMap { item in item.reason.map { "\(item.path)（\($0)）" } },
                      total: source.library.filter { $0.reason != nil }.count)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label.isEmpty ? "（没记来源）" : source.label)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sourceSummary(source))
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func listBlock(_ title: String, _ lines: [String], total: Int) -> some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) \(total)")
                    .font(m.secondary.weight(.medium))
                    .foregroundColor(Theme.textSecondary)
                ForEach(Array(lines.prefix(Self.listLimit).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? "（无标题）" : line)
                        .font(m.caption)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                }
                if total > min(lines.count, Self.listLimit) {
                    Text("还有 \(total - min(lines.count, Self.listLimit)) 条没列出")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
        }
    }

    private func conflictLine(_ c: ImportManifest.ConflictRef) -> String {
        let floor = c.floorName.map { "「\($0)」" } ?? "已删除的楼层"
        return "\(c.title.isEmpty ? "（无标题）" : c.title) → \(floor)" + (c.trashed ? "（在回收站）" : "")
    }

    private func sourceSummary(_ s: ImportManifest.Source) -> String {
        var parts: [String] = []
        if !s.created.isEmpty { parts.append("新增 \(s.created.count) 段 → 本楼层") }
        if !s.copied.isEmpty { parts.append("复制 \(s.copied.count)") }
        if !s.updated.isEmpty { parts.append("更新 \(s.updated.count)") }
        if s.skippedCount > 0 { parts.append("本地已有 \(s.skippedCount)") }
        if s.conflictCount > 0 {
            let floors = Set(s.conflicts.map { $0.floorName.map { "「\($0)」" } ?? "已删除的楼层" }).sorted()
            parts.append("已在其他楼层 \(s.conflictCount)（\(floors.joined(separator: "、"))）")
        }
        if s.emptyCount > 0 { parts.append("空白 / 读不出 \(s.emptyCount)") }
        if s.mergedDuplicates > 0 { parts.append("和前面的文件重复、已合并 \(s.mergedDuplicates)") }
        if !s.foldersCreated.isEmpty { parts.append("新建文件夹 \(s.foldersCreated.count)") }
        if !s.foldersExisting.isEmpty { parts.append("已有文件夹 \(s.foldersExisting.count)") }
        if s.memoriesAdded > 0 { parts.append("花园记忆新增 \(s.memoriesAdded)") }
        if s.memoriesExisting > 0 { parts.append("记忆已有 \(s.memoriesExisting)") }
        let written = s.library.filter { $0.reason == nil }.count
        if written > 0 { parts.append("写进文件库 \(written) 个") }
        if s.library.count > written { parts.append("文件库没写 \(s.library.count - written) 个") }
        return parts.isEmpty ? "没有变化" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func conversationSections(_ detail: ImportRecordDetail) -> some View {
        if detail.createdCount > 0 {
            Section("新建的对话 · \(detail.createdCount) 段") {
                ForEach(detail.created) { folderGroup($0) }
            }
        }
        if detail.updatedCount > 0 {
            Section("更新的对话 · \(detail.updatedCount) 段") {
                ForEach(detail.updated) { folderGroup($0) }
            }
        }
        if detail.missingConversations > 0 {
            Section {
                Text("另有 \(detail.missingConversations) 段导入后已经删掉了。")
                    .font(m.secondary)
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    private func folderGroup(_ group: ImportRecordDetail.FolderGroup) -> some View {
        DisclosureGroup {
            ForEach(group.items.prefix(Self.listLimit)) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.isEmpty ? "（无标题）" : item.title)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(item.messageCount) 条消息" + (item.trashed ? " · 在回收站" : ""))
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            if group.items.count > Self.listLimit {
                Text("还有 \(group.items.count - Self.listLimit) 段没列出")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        } label: {
            HStack {
                Text(group.id.isEmpty ? group.name : "文件夹「\(group.name)」")
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(group.items.count) 段")
                    .font(m.secondary)
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    private func folderSection(_ folders: [ImportRecordDetail.FolderItem]) -> some View {
        Section("新建的文件夹 · \(folders.count) 个") {
            ForEach(folders) { folder in
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name)
                        .font(m.body)
                        .foregroundColor(folder.missing ? Theme.textMuted : Theme.textPrimary)
                    if let note = folder.note {
                        Text(note).font(m.caption).foregroundColor(Theme.textMuted).lineLimit(1)
                    }
                }
            }
        }
    }

    private func memorySection(_ memories: [ImportRecordDetail.MemoryItem]) -> some View {
        Section("写进花园的记忆 · \(memories.count) 条") {
            DisclosureGroup("点开看") {
                ForEach(memories.prefix(Self.listLimit)) { memory in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(memory.content)
                            .font(m.body)
                            .foregroundColor(memory.state == .deleted ? Theme.textMuted : Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        switch memory.state {
                        case .unchanged: EmptyView()
                        case .edited: Text("导入后改过，撤回时会留着").font(m.caption).foregroundColor(Theme.textMuted)
                        case .deleted: Text("已删除").font(m.caption).foregroundColor(Theme.textMuted)
                        }
                    }
                }
                if memories.count > Self.listLimit {
                    Text("还有 \(memories.count - Self.listLimit) 条没列出").font(m.caption).foregroundColor(Theme.textMuted)
                }
            }
            .font(m.body)
        }
    }

    @ViewBuilder
    private func undoArea(_ record: ImportRecord) -> some View {
        if isUndoing {
            VStack(spacing: 6) {
                ProgressView(value: undoProgress, total: Double(undoTotal)).tint(Theme.branchIndicator)
                Text("正在撤回 \(Int(undoProgress))/\(undoTotal)").font(m.caption).foregroundColor(Theme.textMuted)
            }
        } else if record.supportsUndo {
            Button(role: .destructive) {
                undoMessage = Self.undoMessage(for: record, context: modelContext)
                confirmingUndo = true
            } label: {
                Text("撤回此次导入").font(m.body).foregroundColor(Theme.danger)
            }
            .buttonStyle(.plain)
            if undoFailed {
                Text("撤回中途出错，已撤回的部分保留，可以再点一次。").font(m.caption).foregroundColor(Theme.danger)
            }
        } else {
            Text(record.isLegacyRecord ? "旧记录，暂不支持安全撤回。" : "这次导入没有可撤回的内容。")
                .font(m.secondary)
                .foregroundColor(Theme.textMuted)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(m.body).foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func countsText(_ record: ImportRecord) -> String {
        if record.isLegacyRecord { return "\(record.conversationCount) 条对话" }
        var parts = ["新增 \(record.addedConversationCount)", "更新 \(record.updatedConversationCount)",
                     "保持本地 \(record.skippedConversationCount)"]
        if record.conflictConversationCount > 0 { parts.append("已在其他楼层 \(record.conflictConversationCount)") }
        if record.ignoredConversationCount > 0 { parts.append("未导入 \(record.ignoredConversationCount)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 取数 / 撤回

    private func load() async {
        let id = recordId, pid = profileId
        record = try? modelContext.fetch(FetchDescriptor<ImportRecord>(predicate: #Predicate {
            $0.id == id && $0.profileId == pid
        })).first
        guard record != nil else { return }
        let container = modelContext.container
        let result = await Task.detached(priority: .userInitiated) {
            Result { try ImportRecordDetail.load(recordId: id, profileId: pid, context: ModelContext(container)) }
        }.value
        switch result {
        case .success(let d): detail = d
        case .failure(let e): loadError = e.localizedDescription
        }
    }

    static func undoMessage(for record: ImportRecord, context: ModelContext) -> String {
        if record.mode == .backfill {
            return "将把这次补进去的 \(record.nodeCount) 张原图换回占位，并删掉这次存进文件库的图。对话里别的内容（包括补图后新发的消息）不动。"
        }
        let base = record.mode == .merge
            ? "将撤回这次叠加导入：新增 \(record.addedConversationCount) 条，更新 \(record.updatedConversationCount) 条。撤回后会恢复到导入前状态。"
            : "将撤回这次普通导入新增的 \(record.addedConversationCount) 条对话。"
        // #043 D9：Claude 导出包顺带建的记忆 / 文件夹也一起撤
        let recordId = record.id
        let memoryKind = ImportConversationChangeKind.createdMemory.rawValue
        let folderKind = ImportConversationChangeKind.createdFolder.rawValue
        let memories = (try? context.fetchCount(FetchDescriptor<ImportConversationChange>(predicate: #Predicate {
            $0.recordId == recordId && $0.changeKindRaw == memoryKind
        }))) ?? 0
        let folders = (try? context.fetchCount(FetchDescriptor<ImportConversationChange>(predicate: #Predicate {
            $0.recordId == recordId && $0.changeKindRaw == folderKind
        }))) ?? 0
        guard memories + folders > 0 else { return base }
        var parts: [String] = []
        if memories > 0 { parts.append("\(memories) 条花园记忆") }
        if folders > 0 { parts.append("\(folders) 个文件夹") }
        return base + "\n\n这次导进来的\(parts.joined(separator: "、"))也会删掉（导入后内容被改过的记忆会留着）。文件库里的文件不删。"
    }

    private func undo(_ record: ImportRecord) {
        let recordId = record.id
        let scopedProfileId = profileId
        let container = modelContext.container
        isUndoing = true
        undoFailed = false
        undoProgress = 0

        DispatchQueue.global(qos: .userInitiated).async {
            let bgContext = ModelContext(container)
            let changeDescriptor = FetchDescriptor<ImportConversationChange>(
                predicate: #Predicate<ImportConversationChange> { $0.recordId == recordId && $0.profileId == scopedProfileId }
            )
            guard let changes = try? bgContext.fetch(changeDescriptor) else {
                DispatchQueue.main.async {
                    isUndoing = false
                    undoFailed = true
                }
                return
            }
            DispatchQueue.main.async { undoTotal = max(changes.count, 1) }

            for (index, change) in changes.enumerated() {
                do {
                    try restoreConversationChange(change, in: bgContext)
                    if (index + 1) % 25 == 0 { try bgContext.save() }
                } catch {
                    try? bgContext.save()
                    DispatchQueue.main.async {
                        isUndoing = false
                        undoFailed = true
                    }
                    return
                }
                DispatchQueue.main.async { undoProgress = Double(index + 1) }
            }

            for change in changes { bgContext.delete(change) }
            let recordDescriptor = FetchDescriptor<ImportRecord>(
                predicate: #Predicate<ImportRecord> { $0.id == recordId && $0.profileId == scopedProfileId }
            )
            if let existing = try? bgContext.fetch(recordDescriptor).first { bgContext.delete(existing) }
            do {
                try bgContext.save()
            } catch {
                // 最后一步没存上：留在详情页，可以再点一次（sol #8）
                DispatchQueue.main.async {
                    isUndoing = false
                    undoFailed = true
                }
                return
            }

            DispatchQueue.main.async {
                isUndoing = false
                dismiss()
            }
        }
    }
}

/// mac 设置窗里 `SettingsRoute.importRecordDetail` 的落点：记录 id 从共享选择里取
struct MacImportRecordDetailRoute: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        if let id = ImportRecordSelection.shared.recordId {
            ImportRecordDetailView(recordId: id, profileId: profileManager?.currentProfile.id ?? "")
        }
    }
}
