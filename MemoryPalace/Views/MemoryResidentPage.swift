import SwiftUI
import SwiftData

// MARK: - 常驻记忆（plan-memory-audit-desk 第八½节 8½.4）
// 记忆 app 记忆格里推入。上半「每一轮都会带的」：档案 / {助手}的记忆两组，每条写为什么带、这一轮没带的写灰字；
// 下半「下一轮会看见什么」= 原 ⋯ 弹层的内容（`InjectionPreviewSections`）。上下两半用同一次 roundInputs + memoryLayers（`MemoryResident.load`）。
// 390 宽：每行只有文字 + 灰字，不并排放按钮；动作走滑动 / 右键

struct MemoryResidentPage: View {
    /// 跳过来的请求：每次带新 token，页面开着时再跳同一条 / 另一条也执行（10-16 astra #9）
    struct Highlight: Equatable {
        let id: UUID
        var token = UUID()
    }

    /// 从别处跳过来的那条（常驻的不在普通列表里）：滚到它、薄荷底亮一下
    var highlight: Highlight? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("selectedChatModel") private var selectedChatModelId = ""

    @State private var snapshot = MemoryResident.Snapshot()
    @State private var lastInjection: MemoryInjectionRecord?
    @State private var loaded = false
    @State private var saveError: String?
    @State private var flashing: UUID?
    /// 刷新代次 + 交出来第几份数据（定位等数据到了再滚）+ 已经执行过的定位请求
    @State private var ticket = MemoryResident.LoadTicket()
    @State private var dataVersion = 0
    @State private var handledHighlight: UUID?
    @State private var settingsStamp = MemoryResident.settingsStamp()

    private var profile: Profile? { profileManager?.currentProfile }
    private var personaStore: UserPersonaStore { UserPersonaStore.shared }
    private var profileId: String { profile?.id ?? "" }
    private var assistantName: String {
        let n = (profile?.assistantName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "助手" : n
    }

    /// 同时观察真实消息窗口和有效身份；身份库走现有 @Observable store，不只看 personaId。
    private struct RefreshKey: Equatable {
        let conversationId: String?
        let conversationMemoryOn: Bool
        let conversationUpdatedAt: Date?
        let settings: [String]
        let slotOn: Bool
        let model: String
        let branchId: String?
        let recentNodes: [MemoryResident.WikiNodeRevision]
        let identity: MemoryResident.IdentityKey
    }

    private var refreshKey: RefreshKey {
        let conv = viewModel?.selectedConversation
        return RefreshKey(conversationId: conv?.id, conversationMemoryOn: conv?.memoryEnabled ?? true,
                          conversationUpdatedAt: conv?.updateTime, settings: settingsStamp,
                          slotOn: slotOn, model: (conv?.selectedModelId ?? "") + "|" + selectedChatModelId,
                          branchId: conv?.currentNodeId, recentNodes: MemoryResident.wikiRevisions(in: viewModel?.currentPath ?? []),
                          identity: MemoryResident.IdentityKey(profile: profile, conversationPersonaId: conv?.personaId,
                                                               personas: personaStore.personas))
    }

    /// 实发用的预设同聊天页：楼层绑的那份，找不到用内置
    private var slotOn: Bool {
        MemoryResident.memorySlotOn(presetManager?.preset(byId: profile?.presetId ?? "") ?? Preset.balanced)
    }

    private struct HighlightKey: Equatable {
        let highlight: Highlight?
        let dataVersion: Int
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                // 定位请求和数据都到了才滚；每个请求只执行一次（10-16 astra #9）
                .onChange(of: HighlightKey(highlight: highlight, dataVersion: dataVersion), initial: true) { _, key in
                    guard let h = key.highlight, h.token != handledHighlight, snapshot.archive.contains(where: { $0.id == h.id }) else { return }
                    handledHighlight = h.token
                    let id = h.id
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    withAnimation(.easeInOut(duration: 0.35)) { flashing = id }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard flashing == id else { return }
                        withAnimation(.easeOut(duration: 0.6)) { flashing = nil }
                    }
                }
        }
    }

    private var list: some View {
        List {
            if let saveError {
                Section {
                    Text(saveError)
                        .font(m.caption)
                        .foregroundColor(Theme.danger)
                }
                .panelRowBackground()
            }
            Section { EmptyView() } header: { Text("每一轮都会带的") }
            if let wiki = snapshot.wiki {
                Section("\(MemoryWriterID.c.code) 档案") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(wiki.text)
                            .font(m.body)
                            .foregroundColor(wiki.gate == nil ? Theme.textPrimary : Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let gate = wiki.gate { grayLine(gate) }
                    }
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .panelRowBackground()
            }
            if loaded && snapshot.count == 0 && snapshot.wiki == nil {
                Section {
                    Text("现在没有每一轮都带的记忆。在记忆列表里左滑一条「钉住」，它就会到这里")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .panelRowBackground()
            }
            if !snapshot.archive.isEmpty {
                Section(profile.map(PromptAssembler.archiveLabel) ?? "关于对方") {
                    ForEach(snapshot.archive) { row in
                        archiveRow(row)
                            .id(row.id)
                            .panelRowBackground(flashing == row.id ? Theme.branchIndicator.opacity(0.35) : Theme.mainBg)
                    }
                }
                .panelRowBackground()
            }
            if !snapshot.selfRows.isEmpty {
                Section("\(assistantName)的记忆") {
                    ForEach(snapshot.selfRows) { selfRow($0) }
                }
                .panelRowBackground()
            }
            if snapshot.fullFallbackCount > 0 {
                Section {
                    Text("全量注入开着：另外 \(snapshot.fullFallbackCount) 条档案也每一轮都带（预算内）")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
            Section { EmptyView() } header: { Text("下一轮会看见什么") }
            InjectionPreviewSections(stable: snapshot.stable, volatilePart: snapshot.volatile, masterOff: !MemoryFlags.masterEnabled,
                                     memoryCount: snapshot.memoryCount, lastInjection: lastInjection, assistantName: assistantName)
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .memorySubpage("常驻记忆")
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            _ = ticket.next()
            snapshot = MemoryResident.Snapshot()
            lastInjection = nil
            loaded = false
        }
        .onChange(of: profileId) { _, _ in reload() }
        // 别的窗口（mac 设置窗）改了注入设置：比快照，变了才重算（同工具抽屉的 upstreamSnapshot）
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            let now = MemoryResident.settingsStamp()
            if now != settingsStamp { settingsStamp = now }
        }
        // 重建发布未必递增版本（同一代缓存完成加载也会发通知），每次都取最新快照。
        .onReceive(NotificationCenter.default.publisher(for: WikiInjectionCache.didRebuild)) { _ in
            settingsStamp = MemoryResident.settingsStamp()
            reload()
        }
        .onChange(of: refreshKey) { _, _ in reload() }
    }

    // MARK: - 行

    /// 正文 2 行 + 「原因 · 类别 ▾ · 日期」+ 灰字；钉住的左滑 / 右键「取消钉住」
    private func archiveRow(_ row: MemoryResident.ArchiveRow) -> some View {
        let mem = row.memory
        return VStack(alignment: .leading, spacing: 3) {
            Text(mem.content)
                .font(m.body)
                .foregroundColor(row.gate == nil ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(row.reason + " ·")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                categoryMenu(mem)
                Text("· " + MemoryDateText.short(mem.createdAt))
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            if let gate = row.gate { grayLine(gate) }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .swipeActions(edge: .leading) {
            if mem.isUserExplicit {
                Button { unpin(mem) } label: { Label("取消钉住", systemImage: "pin.slash") }
                    .tint(Theme.branchIndicator)
            }
        }
        .contextMenu {
            if mem.isUserExplicit {
                Button { unpin(mem) } label: { Label("取消钉住", systemImage: "pin.slash") }
            }
        }
    }

    /// 描述 + 原因 + 灰字；只看（B4 在文件库里改）
    private func selfRow(_ row: MemoryResident.SelfRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.memory.description.isEmpty ? row.memory.name : row.memory.description)
                .font(m.body)
                .foregroundColor(row.gate == nil ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(2)
            Text(row.reason)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
            if let gate = row.gate { grayLine(gate) }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grayLine(_ gate: MemoryResident.Gate) -> some View {
        Text(gate.text)
            .font(m.caption)
            .foregroundColor(Theme.textMuted.opacity(0.8))
            .lineLimit(1)
    }

    /// 同审计台：五选一立刻存，改类别也算「留」（⧫2）
    private func categoryMenu(_ mem: Memory) -> some View {
        Menu {
            ForEach(MemoryAuditFilterSheet.categories, id: \.key) { c in
                Button {
                    MemoryAudit.setCategory(mem, c.key)
                    save()
                } label: {
                    if c.key == mem.category { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                }
            }
        } label: {
            Text("\(MemoryCardView.categoryLabels[mem.category] ?? mem.category) ▾")
                .font(m.caption)
                .foregroundColor(Theme.branchIndicator)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - 动作 / 数据

    /// 取消钉住：存成了才刷新，它回到记忆格普通列表
    private func unpin(_ mem: Memory) {
        guard mem.isUserExplicit else { return }
        MemoryPinPlan.apply([mem])
        save()
    }

    /// 存盘成功才发通知、重算（同审计台 10-16 astra #7）；存不成顶上一行红字
    private func save() {
        do {
            try modelContext.save()
        } catch {
            saveError = "保存失败：\(error.localizedDescription)"
            return
        }
        saveError = nil
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    /// 读文件、组装注入都在后台（`MemoryResident.loadSummary`）；主线程只按 id 取回那几条档案（改类别 / 取消钉住要用这个 context 里的对象）。
    /// 只收最新一次刷新的结果；拼的时候复核掉了行（后台算完后被删 / 取消钉住）→ 下半预览也是旧的，再算一次（只补一次，10-16 astra #3）
    private func reload(retry: Bool = false) {
        guard let profile else { return }
        let n = ticket.next()
        let key = refreshKey
        let effectiveProfile = SendContextResolver.resolve(profile: profile, conversation: viewModel?.selectedConversation,
                                                            context: modelContext, globalEntries: []).profile
        let convOn = viewModel?.selectedConversation?.memoryEnabled ?? true
        let container = modelContext.container
        let slotOn = slotOn
        // 这一轮调得到的工具：同工具抽屉，走实发那一套（没有对话 = nil，尾注原样）
        let tools = providerManager.flatMap { viewModel?.previewTools(providerManager: $0, globalModelId: selectedChatModelId) }
            .map { Set($0.signature.tools).union($0.signature.catalog) }
        let recentNodeIds = key.recentNodes.map(\.id)
        Task {
            let summary = await MemoryResident.loadSummary(profile: effectiveProfile, conversationMemoryEnabled: convOn, container: container,
                                                           slotOn: slotOn, availableTools: tools, recentNodeIds: recentNodeIds)
            guard ticket.isLatest(n), profile.id == profileId, refreshKey == key else { return }
            let ids = Set(summary.archive.map(\.id))
            let pid = profile.id
            let mems = ids.isEmpty ? [] : (try? modelContext.fetch(FetchDescriptor<Memory>(predicate: #Predicate<Memory> {
                ids.contains($0.id) && $0.profileId == pid
            }))) ?? []
            let next = MemoryResident.Snapshot(summary, memories: mems)
            if next.dropped > 0 && !retry {
                reload(retry: true)
                return
            }
            snapshot = next
            lastInjection = MemoryInjectionMeter.load(profileId: pid)
            loaded = true
            dataVersion += 1
        }
    }
}
