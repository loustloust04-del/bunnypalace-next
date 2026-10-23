#if os(iOS)
import SwiftUI
import SwiftData

// MARK: - Lite 模式「记忆」页

/// Lite 模式的记忆简化页：总开关 + 简要说明 + 只读画像卡 +「管理记忆条目」二级页。
/// 总开关与 pro 走同一路径（PermissionCenter.level(.memory) + mem_master），
/// 画像读同一个 ProfileFileStore——只是一层简化壳，不动 pro 的任何 UI。
struct LiteMemoryPage: View {
    var viewModel: ConversationViewModel?

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @AppStorage("mem_master") private var memMaster = true

    @State private var profileDream: UserProfileDream? = nil
    @State private var memoryCount = 0

    var body: some View {
        List {
            // ── 总开关（读写逻辑照抄 MemoryPageContent.sectionPerception）──
            Section {
                Toggle(isOn: Binding(
                    get: { PermissionCenter.level(.memory) == .bypass },
                    set: { PermissionCenter.setLevel($0 ? .bypass : .notAllowed, for: .memory); memMaster = $0 }
                )) {
                    Text("记住我")
                        .font(.system(size: Theme.SettingsFont.body, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
                .tint(Theme.branchIndicator)
            } footer: {
                Text("开着，聊天时 AI 会慢慢记住你；关掉就不再记了，已经记住的也不会丢。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            // ── 只读画像卡：让 lite 用户感知到"它在记"，不放任何按钮 ──
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI 眼中的你")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    if let d = profileDream, !d.text.isEmpty {
                        Text(d.text)
                            .font(.system(size: Theme.SettingsFont.body))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(6)
                        Text("\(d.updatedAt.formatted(.dateTime.month().day())) 更新 · \(d.text.count) 字")
                            .font(.system(size: Theme.SettingsFont.badge))
                            .foregroundColor(Theme.textMuted)
                    } else {
                        Text("还没有画像——多聊几轮就有啦")
                            .font(.system(size: Theme.SettingsFont.body))
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.mainBg)

            // ── 管理记忆条目（二级页，缝 page2 的条目列表）──
            Section {
                NavigationLink {
                    LiteMemoryEntriesPage(viewModel: viewModel)
                } label: {
                    HStack {
                        Text("管理记忆条目")
                            .font(.system(size: Theme.SettingsFont.body))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text("\(memoryCount) 条")
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            profileDream = nil
            memoryCount = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            refresh()
        }
    }

    private func refresh() {
        let profileId = profileManager?.currentProfile.id ?? ""
        profileDream = ProfileFileStore.load(profileId: profileId)
        memoryCount = SwiftDataMemoryStore().listAll(profileId: profileId, context: modelContext).count
    }
}

// MARK: - Lite「管理记忆条目」二级页

/// 从 page2 的 MemoryPanelView 缝过来的纯条目列表：三温区分组 + MemoryCardView 行，
/// 保留 钉住/删除（软删语义）/复活/编辑/跳出处，去掉 图谱/画像区/设置核/批量多选。
/// 数据操作语义与 MemoryPanelView 完全一致（同一 store、同一 modelContext）。
struct LiteMemoryEntriesPage: View {
    var viewModel: ConversationViewModel?

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var memories: [Memory] = []
    @State private var showAddSheet = false
    @State private var editingMemory: Memory? = nil
    /// 已失效的再删 = 永久删除，先挂这里等确认
    @State private var pendingPurge: MemoryDeletePlan.Plan? = nil

    private let store = SwiftDataMemoryStore()

    var body: some View {
        List {
            if memories.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                        Text("还没有记忆")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textMuted)
                        Text("和{{char}}聊天时会自动记住重要的事".expandingMacros(profile: profileManager?.currentProfile))
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            let grouped = groupedMemories
            if !grouped.active.isEmpty {
                Section("原子档案 · \(grouped.active.count)") {
                    ForEach(grouped.active, id: \.id) { mem in memoryRow(mem) }
                }
                .listRowBackground(Theme.mainBg)
            }
            if !grouped.superseded.isEmpty {
                Section("已失效 · \(grouped.superseded.count)") {
                    ForEach(grouped.superseded, id: \.id) { mem in memoryRow(mem) }
                }
                .listRowBackground(Theme.mainBg)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("记忆条目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddMemorySheet(profileId: profileManager?.currentProfile.id ?? "") {
                refreshMemories()
            }
        }
        .sheet(item: $editingMemory) { mem in
            AddMemorySheet(profileId: profileManager?.currentProfile.id ?? "", editing: mem) {
                refreshMemories()
            }
        }
        .onAppear { refreshMemories() }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            memories = []
            pendingPurge = nil
        }
        .confirmationDialog(
            pendingPurge.map { MemoryDeletePlan.confirmTitle($0) } ?? "",
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            titleVisibility: .visible,
            presenting: pendingPurge
        ) { plan in
            Button(MemoryDeletePlan.confirmButton(plan), role: .destructive) { purge(plan) }
            Button("取消", role: .cancel) { pendingPurge = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            refreshMemories()
        }
    }

    @ViewBuilder
    private func memoryRow(_ mem: Memory) -> some View {
        MemoryCardView(
            memory: mem,
            onPin: { togglePin(mem) },
            onDelete: { deleteMemory(mem) },
            onEdit: { editingMemory = mem },
            onRevive: mem.supersededAt != nil ? { reviveMemory(mem) } : nil,
            onJumpToSource: mem.sourceConversationId != nil ? { jumpToSource(mem) } : nil
        )
    }

    // MARK: - 操作（语义照抄 MemoryPanelView）

    private func togglePin(_ memory: Memory) {
        memory.isUserExplicit.toggle()
        if memory.isUserExplicit { memory.decayWeight = 1.0 }
        memory.updatedAt = Date()
        try? modelContext.save()
        refreshMemories()
    }

    private func deleteMemory(_ memory: Memory) {
        // 活跃条目走 supersede 可恢复；已失效再删 = 真删（与 MemoryPanelView 同语义）
        if memory.supersededAt == nil {
            memory.supersededAt = Date()
            memory.updatedAt = Date()
            try? modelContext.save()
            refreshMemories()
        } else {
            pendingPurge = MemoryDeletePlan.plan([memory])
        }
    }

    private func purge(_ plan: MemoryDeletePlan.Plan) {
        pendingPurge = nil
        for m in memories where m.supersededAt != nil && plan.purge.contains(m.id) {
            modelContext.delete(m)
        }
        try? modelContext.save()
        refreshMemories()
    }

    private func reviveMemory(_ memory: Memory) {
        memory.supersededAt = nil
        memory.updatedAt = Date()
        try? modelContext.save()
        refreshMemories()
    }

    private func jumpToSource(_ memory: Memory) {
        guard let viewModel, let cid = memory.sourceConversationId else { return }
        let pid = profileManager?.currentProfile.id ?? ""
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in conv.id == cid && conv.profileId == pid }
        )
        guard let conv = try? modelContext.fetch(convDesc).first else { return }
        if let nodeId = memory.sourceNodeId {
            viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conv, context: modelContext)
        } else {
            viewModel.loadConversation(conv, context: modelContext)
        }
    }

    // MARK: - 数据

    private var groupedMemories: (active: [Memory], superseded: [Memory]) {
        MemoryArchiveOrder.split(memories)
    }

    private func refreshMemories() {
        let profileId = profileManager?.currentProfile.id ?? ""
        memories = store.listAll(profileId: profileId, context: modelContext)
    }
}
#endif
