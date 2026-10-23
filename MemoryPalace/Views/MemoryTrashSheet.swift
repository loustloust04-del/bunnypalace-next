import SwiftUI
import SwiftData

// MARK: - 已删除（#067 第 3 步，替掉「找回失效的记忆」）
// 两类记忆删掉的都在这：恢复 / 彻底删除只在这里做；彻底删除要确认。

struct MemoryTrashSheet: View {
    let profileId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MemoryTrashList(profileId: profileId, onDone: { dismiss() })
        }
        #if os(macOS)
        .frame(width: 520, height: 560)
        #endif
    }
}

private struct MemoryTrashList: View {
    let profileId: String
    let onDone: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    #if os(iOS)
    @Environment(\.editMode) private var editMode
    #endif

    @State private var archive: [Memory] = []
    @State private var assistant: [SelfMemory] = []
    @State private var loaded = false
    @State private var selection: Set<MemoryRowID> = []
    @State private var pendingPurge: Set<MemoryRowID>? = nil

    private var assistantName: String {
        let n = profileManager?.profiles.first { $0.id == profileId }?.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    var body: some View {
        let grouped = MemoryRevival.trash(archive: archive, assistant: assistant)
        List(selection: $selection) {
            ForEach(grouped.batches) { batch in
                Section("\(MemoryDateText.short(batch.start))整理时合并掉的 · \(batch.memories.count)") {
                    ForEach(batch.memories.map { MemoryRowItem($0) }) { row($0) }
                    Button("全部恢复 \(batch.memories.count) 条") {
                        restore(Set(batch.memories.map { MemoryRowID.archive($0.id) }))
                    }
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
                    .buttonStyle(.plain)
                    .panelRowBackground()
                }
            }
            if !grouped.scattered.isEmpty {
                Section("你删的、\(assistantName)划掉的 · \(grouped.scattered.count)") {
                    ForEach(grouped.scattered) { row($0) }
                }
            }
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .overlay {
            if loaded && grouped.batches.isEmpty && grouped.scattered.isEmpty {
                MemoryEmptyState(title: "没有删除的记忆", message: "删掉的记忆会先放在这里，想要回来可以恢复")
            }
        }
        .toolPageBackground()
        .contextMenu(forSelectionType: MemoryRowID.self) { ids in
            actions(ids)
        }
        .tint(Theme.branchIndicator)
        .panelSheetTitle("已删除")
        .toolbar { toolbarItems }
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selection.isEmpty { macSelectionBar }
        }
        #endif
        // 居中 alert：iOS 26 的 confirmationDialog 会锚到它挂的视图（这里是整个 List）弹成 popover，飘在列表中间
        .alert(
            MemoryDeletePlan.purgeTitle(pendingPurge?.count ?? 0),
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            presenting: pendingPurge
        ) { ids in
            Button("彻底删除", role: .destructive) { purge(ids) }
            Button("取消", role: .cancel) { pendingPurge = nil }
        } message: { ids in
            Text("删掉之后找不回来，\(assistantName)也不会再想起\(ids.count == 1 ? "它" : "它们")。")
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in onDone() }
    }

    private func row(_ item: MemoryRowItem) -> some View {
        MemoryRow(item: item) { actions([item.id]) }
            .tag(item.id)
            .swipeActions(edge: .leading) {
                Button { restore([item.id]) } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                }
                .tint(Theme.branchIndicator)
            }
            .swipeActions(edge: .trailing) {
                Button { pendingPurge = [item.id] } label: {
                    Label("彻底删除", systemImage: "trash")
                }
                .tint(Theme.danger)
            }
            .panelRowBackground(rowBackground(item.id))
    }

    @ViewBuilder
    private func actions(_ ids: Set<MemoryRowID>) -> some View {
        if !ids.isEmpty {
            Button { restore(ids) } label: {
                Label(ids.count > 1 ? "恢复 \(ids.count) 条" : "恢复", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { pendingPurge = ids } label: {
                Label(ids.count > 1 ? "彻底删除 \(ids.count) 条" : "彻底删除", systemImage: "trash")
            }
        }
    }

    private func rowBackground(_ id: MemoryRowID) -> Color {
        #if os(macOS)
        selection.contains(id) ? Theme.accent : Theme.mainBg
        #else
        Theme.mainBg
        #endif
    }

    // MARK: - Toolbar

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        let editing = editMode?.wrappedValue.isEditing == true
        ToolbarItem(placement: .topBarLeading) {
            MemorySelectButton()
        }
        if !editing {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { onDone() }
                    .foregroundColor(Theme.branchIndicator)
            }
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { restore(selection) } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Text("\(selection.count) 已选")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button(role: .destructive) { pendingPurge = selection } label: {
                    Label("彻底删除", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
    }
    #else
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("完成") { onDone() }
                .foregroundColor(Theme.branchIndicator)
        }
    }

    private var macSelectionBar: some View {
        HStack(spacing: 14) {
            Text("\(selection.count) 已选")
                .foregroundColor(Theme.textMuted)
            Spacer()
            Button { restore(selection) } label: {
                Label("恢复", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { pendingPurge = selection } label: {
                Label("彻底删除", systemImage: "trash")
            }
            Button { selection = [] } label: {
                Image(systemName: "xmark.circle")
            }
            .help("取消选择")
        }
        .font(.system(size: 13))
        .foregroundColor(Theme.textSecondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .toolPageBackground()
    }
    #endif

    // MARK: - Actions

    private func endSelection() {
        selection = []
        #if os(iOS)
        editMode?.wrappedValue = .inactive
        #endif
    }

    private func restore(_ ids: Set<MemoryRowID>) {
        let archiveTargets = archive.filter { ids.contains(.archive($0.id)) }
        if !archiveTargets.isEmpty {
            MemoryRevival.revive(archiveTargets)
            try? modelContext.save()
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
        for m in assistant where !m.isActive && ids.contains(.assistant(m.slug)) {
            var revived = m
            revived.superseded = nil
            try? SelfMemoryStore.save(revived, profileId: profileId)
        }
        endSelection()
        reload()
    }

    /// 彻底删除：按楼层 ID 读最新列表再按 id 找（确认期间列表刷新过也删对那几条），只删已删除的
    private func purge(_ ids: Set<MemoryRowID>) {
        pendingPurge = nil
        let plan = MemoryDeletePlan.plan(archive.filter { ids.contains(.archive($0.id)) })
        if !plan.purge.isEmpty {
            for m in SwiftDataMemoryStore().listAll(profileId: profileId, context: modelContext)
            where m.supersededAt != nil && plan.purge.contains(m.id) {
                modelContext.delete(m)
            }
            try? modelContext.save()
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        }
        for m in assistant where !m.isActive && ids.contains(.assistant(m.slug)) {
            try? SelfMemoryStore.delete(slug: m.slug, profileId: profileId)
        }
        endSelection()
        reload()
    }

    private func reload() {
        archive = SwiftDataMemoryStore().listAll(profileId: profileId, context: modelContext).filter { $0.supersededAt != nil }
        let pid = profileId
        Task {
            let list = await Task.detached { SelfMemoryStore.list(profileId: pid) }.value
            assistant = list
            loaded = true
            let inTrash = Set(archive.map { MemoryRowID.archive($0.id) } + list.filter { !$0.isActive }.map { MemoryRowID.assistant($0.slug) })
            selection.formIntersection(inTrash)
        }
    }
}
