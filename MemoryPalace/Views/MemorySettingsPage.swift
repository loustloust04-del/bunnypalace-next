import SwiftUI
import SwiftData

// MARK: - macOS Memory Settings Tab

/// 刀1（plan-memory-usable）：提取/做梦生死状态行——供水断了要能一眼看见（此前静默死 11 天）。
/// macOS 设置-记忆 与 iOS 记忆页共用。
struct MemoryHealthStatusView: View {
    let profileId: String
    @Environment(\.settingsMetrics) private var m
    @State private var extractStatus: MemoryHealthStore.Status = .init(lastOK: nil, lastError: nil, lastErrorMessage: nil, failStreak: 0, modelName: nil)
    @State private var dreamStatus: MemoryHealthStore.Status = .init(lastOK: nil, lastError: nil, lastErrorMessage: nil, failStreak: 0, modelName: nil)
    @State private var summaryStatus: MemoryHealthStore.Status = .init(lastOK: nil, lastError: nil, lastErrorMessage: nil, failStreak: 0, modelName: nil)
    @State private var contextStatus: MemoryHealthStore.Status = .init(lastOK: nil, lastError: nil, lastErrorMessage: nil, failStreak: 0, modelName: nil)
    @State private var timelineStatus: MemoryHealthStore.Status = .init(lastOK: nil, lastError: nil, lastErrorMessage: nil, failStreak: 0, modelName: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            healthLine(label: "记新东西", failing: "最近记不住新东西了，去看看模型设置", status: extractStatus)
            healthLine(label: "写画像", failing: "最近写不成画像，去看看模型设置", status: dreamStatus)
            // 第三刀：跑过或在失败才显示（不再多一行「还没跑过」）；v4-1 分三行（Q8）
            if contextStatus.lastOK != nil || contextStatus.needsAttention {
                healthLine(label: "写上下文摘要", failing: "最近写不成上下文摘要，去看看模型设置", status: contextStatus)
            }
            if summaryStatus.lastOK != nil || summaryStatus.needsAttention {
                healthLine(label: "写窗口总结", failing: "最近写不成窗口总结，去看看模型设置", status: summaryStatus)
            }
            if timelineStatus.lastOK != nil || timelineStatus.needsAttention {
                healthLine(label: "写时间轴", failing: "最近写不成时间轴，去看看模型设置", status: timelineStatus)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in reload() }
    }

    private func reload() {
        extractStatus = MemoryHealthStore.status(.extract, profileId: profileId)
        dreamStatus = MemoryHealthStore.status(.dream, profileId: profileId)
        summaryStatus = MemoryHealthStore.status(.summary, profileId: profileId)
        contextStatus = MemoryHealthStore.status(.context, profileId: profileId)
        timelineStatus = MemoryHealthStore.status(.timeline, profileId: profileId)
    }

    @ViewBuilder
    private func healthLine(label: String, failing: String, status: MemoryHealthStore.Status) -> some View {
        HStack(spacing: 5) {
            if status.needsAttention {
                Circle().fill(Theme.danger).frame(width: 6, height: 6)
                Text(failing)
                    .foregroundColor(Theme.danger)
            } else if let ok = status.lastOK {
                Text("上次\(label)：\(Self.relative(ok))")
                    .foregroundColor(Theme.textMuted)
            } else {
                Text("上次\(label)：还没有")
                    .foregroundColor(Theme.textMuted)
            }
        }
        .font(m.caption)
        .lineLimit(2)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#if os(macOS)
/// A5（她裁「不删」）：mac 设置 · 记忆页保留的条目 CRUD —— 分档列表（钉住 / 编辑 / 硬删）+ 手动添加。
/// 第 2 类例外：iOS 这块在右栏「记忆」面板，设置页没有；接在 `MemoryPageContent()` 之后。
///
/// **刷新合同（plan-x §1-A5）**：本节四条写路径（添加 / 钉住·取消钉住 / 编辑 / 硬删）**提交成功后**
/// post `.memoryDidChange`，共用核（`MemoryPageContent`）订阅后刷统计；本节自己也订阅它，
/// 好让共用核那两条写路径（整理完成 / 单独做梦）刷到这个列表。切楼层仍先清空。
struct MacMemoryEntriesSections: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m

    @State private var memories: [Memory] = []
    @State private var newNoteText = ""
    @State private var editingNoteId: UUID? = nil
    @State private var editingNoteText = ""
    /// D9 确认：点删除只置 pending（存 Memory.id + 楼层 ID），确认分支才按 ID 在最新列表里重找再删
    @State private var pendingDelete: PendingMemoryDelete?

    private struct PendingMemoryDelete {
        let profileId: String
        let memoryId: UUID
    }

    /// 第二刀 A1：档案不分冷热，mac 条目列表按分类分组
    private static let categories: [(String, String)] = [
        ("relationship", "关系"), ("preference", "偏好"), ("fact", "事实"), ("goal", "目标"), ("context", "近况"),
    ]

    var body: some View {
        Group {
            Section("记忆条目") {
                if memories.isEmpty {
                    Text("还没有记忆")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                        .padding(.vertical, 8)
                } else {
                    let grouped = Dictionary(grouping: memories) { mem in
                        Self.categories.contains { $0.0 == mem.category } ? mem.category : "other"
                    }
                    ForEach(Self.categories + [("other", "其他")], id: \.0) { key, label in
                        if let items = grouped[key], !items.isEmpty {
                            let color = Theme.branchIndicator
                            Text(label)
                                .font(m.sectionHeader)
                                .foregroundColor(color)
                                .padding(.top, 4)

                            ForEach(items, id: \.id) { memory in
                                memoryRow(memory, tierColor: color)
                            }
                        }
                    }
                }
            }

            Section("手动添加记忆") {
                TextEditor(text: $newNoteText)
                    .font(m.body)
                    .frame(height: 50)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
                    .scrollContentBackground(.hidden)

                Button {
                    addNote()
                } label: {
                    Text("添加")
                        .font(m.secondary)
                        .foregroundColor(ShellStyle.text)
                }
                .buttonStyle(MacSettingsButton())
            }
        }
        .onAppear { refreshMemories() }
        // 切楼层 race defense，见 docs/plan-profile-switch-atomic.md
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            memories = []
        }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in
            refreshMemories()
        }
        .confirmationDialog(
            "删除这条记忆？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private func memoryRow(_ memory: Memory, tierColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Circle().fill(tierColor).frame(width: 5, height: 5)

                let categoryLabels: [String: String] = [
                    "preference": "偏好", "fact": "事实", "relationship": "关系",
                    "goal": "目标", "context": "近况",
                ]
                Text(categoryLabels[memory.category] ?? memory.category)
                    .font(m.caption)
                    .foregroundColor(Theme.mainBg)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tierColor.opacity(0.7)))

                if memory.isUserExplicit {
                    Image(systemName: "pin.fill")
                        .font(m.caption)
                        .foregroundColor(Theme.branchIndicator)
                }

                Spacer()

                Text(memory.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(m.secondary)
                    .foregroundColor(Theme.textMuted.opacity(0.6))
            }

            // Content
            if editingNoteId == memory.id {
                TextEditor(text: $editingNoteText)
                    .font(m.body)
                    .frame(height: 50)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
                    .scrollContentBackground(.hidden)

                HStack(spacing: 8) {
                    Button("取消") { editingNoteId = nil }
                        .font(m.secondary).foregroundColor(Theme.textMuted).buttonStyle(.plain)
                    Button("保存") { saveEdit(memory) }
                        .font(m.secondary).foregroundColor(Theme.mainBg)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.branchIndicator))
                        .buttonStyle(.plain)
                }
            } else {
                Text(memory.content)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)
            }

            // Actions
            if editingNoteId != memory.id {
                HStack(spacing: 12) {
                    Button(memory.isUserExplicit ? "取消钉住" : "钉住") { togglePin(memory) }
                        .font(m.secondary).foregroundColor(Theme.textMuted).buttonStyle(.plain)

                    Button("编辑") {
                        editingNoteText = memory.content
                        editingNoteId = memory.id
                    }
                    .font(m.secondary).foregroundColor(Theme.textMuted).buttonStyle(.plain)

                    Button("删除") { askDelete(memory) }
                        .font(m.secondary).foregroundColor(Theme.danger).buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.assistantBubble))
    }

    // MARK: - 四条写路径（成功才 post）

    private func addNote() {
        let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let profileId = profileManager?.currentProfile.id ?? ""
        let store = SwiftDataMemoryStore()
        do {
            try store.add(
                content: text, category: "fact", keywords: [],
                profileId: profileId, isUserExplicit: true, extractedBy: "manual",
                sourceConversationId: nil, context: modelContext
            )
        } catch {
            return
        }
        newNoteText = ""
        // 本节自己也订阅 .memoryDidChange → refreshMemories()，这里不再先刷一遍（R6b S3）
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    private func saveEdit(_ memory: Memory) {
        let store = SwiftDataMemoryStore()
        do {
            try store.update(id: memory.id, content: editingNoteText, keywords: memory.keywords, context: modelContext)
        } catch {
            return
        }
        editingNoteId = nil
        // 本节自己也订阅 .memoryDidChange → refreshMemories()，这里不再先刷一遍（R6b S3）
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    private func togglePin(_ memory: Memory) {
        memory.isUserExplicit.toggle()
        if memory.isUserExplicit { memory.decayWeight = 1.0 }
        do {
            try modelContext.save()
        } catch {
            return
        }
        // 本节自己也订阅 .memoryDidChange → refreshMemories()，这里不再先刷一遍（R6b S3）
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    private func askDelete(_ memory: Memory) {
        pendingDelete = PendingMemoryDelete(profileId: profileManager?.currentProfile.id ?? "",
                                            memoryId: memory.id)
    }

    /// 确认分支才写：按 pending 的楼层 ID 读最新列表，再按 Memory.id 找对象（列表变了也删对那条）
    private func confirmDelete() {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil
        let store = SwiftDataMemoryStore()
        let latest = store.listAll(profileId: pending.profileId, context: modelContext)
        guard let target = latest.first(where: { $0.id == pending.memoryId }) else { return }
        modelContext.delete(target)
        do {
            try modelContext.save()
        } catch {
            return
        }
        // 本节自己也订阅 .memoryDidChange → refreshMemories()，这里不再先刷一遍（R6b S3）
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    private func refreshMemories() {
        let profileId = profileManager?.currentProfile.id ?? ""
        let store = SwiftDataMemoryStore()
        memories = store.listAll(profileId: profileId, context: modelContext)
    }
}
#endif

// MARK: - Memory Page（壳 — 内容全交给 MemoryPageContent 共用核，两端一份 body）

struct MemoryPage: View {
    @AppStorage("memoryExplanationExpanded") private var memoryExplanationExpanded = true
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        // 搜索锚点：命中叶子条目时滚到那一行
        ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            // 说明卡（设置-记忆 专属，page2 不显示）
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { memoryExplanationExpanded.toggle() }
                } label: {
                    HStack {
                        Text("记忆系统说明")
                            .font(m.body)
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        Image(systemName: memoryExplanationExpanded ? "chevron.down" : "chevron.right")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if memoryExplanationExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        explanationLine("每聊几轮（默认 3 轮），后台用副模型从最近的对话里提取值得记住的事实")
                        explanationLine("钉住的、关系类、偏好类：每次都会想起")
                        explanationLine("其余的看「检索」区：全量就全带上；关键词 / 按意思找就聊到相关才带上")
                        explanationLine("你或{{char}}删掉的记忆会进「已删除」，可以恢复".expandingMacros(profile: profileManager?.currentProfile))
                    }
                }

                MemoryHealthStatusView(profileId: profileManager?.currentProfile.id ?? "")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 共用核：六组 Section
            MemoryPageContent()

            #if os(macOS)
            // A5：mac 独有的条目 CRUD（第 2 类例外），接在共用核之后
            MacMemoryEntriesSections()
            #endif
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        #endif
        #if os(iOS)
        .navigationTitle("记忆")   // mac 根页标题由宿主 `MacSettingsPage` 的 toolbar 给（同外观五页口径）
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .settingsAnchorScroll(anchorProxy)
        }
    }

    private func explanationLine(_ text: String) -> some View {
        Text(text)
            .font(m.caption)
            .foregroundColor(Theme.textSecondary)
    }
}
