import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 常驻记忆（plan-memory-audit-desk 第八½节 8½.4）
// 记忆 app 记忆格里推入。上半「每一轮都会带的」：档案 / {助手}的记忆两组，每条写为什么带、这一轮没带的写灰字；
// 下半「下一轮会看见什么」= 原 ⋯ 弹层的内容（`InjectionPreviewSections`）。上下两半用同一次 roundInputs + memoryLayers（`MemoryResident.load`）。
// 390 宽：每行只有文字 + 灰字，不并排放按钮；点一条开唯一的那张详情页，取消钉住走滑动 / 右键（记进记忆日志、浮条能 Undo）

struct MemoryResidentPage: View {
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
    /// 刷新代次
    @State private var ticket = MemoryResident.LoadTicket()
    @State private var settingsStamp = MemoryResident.settingsStamp()
    @State private var entryTarget: MemoryEntryTarget?
    @State private var undo = MemoryUndoCenter()

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
        /// 本窗六项（档案 / 钉住 / B4 / 上窗都跟它走）；改纸条只写 choices 不动 `updateTime`，所以要单独收
        let choices: MemoryWindowChoices?
        let model: String
        let branchId: String?
        let recentNodes: [MemoryResident.WikiNodeRevision]
        let identity: MemoryResident.IdentityKey
    }

    private var refreshKey: RefreshKey {
        let conv = viewModel?.selectedConversation
        return RefreshKey(conversationId: conv?.id, conversationMemoryOn: conv?.memoryEnabled ?? true,
                          conversationUpdatedAt: conv?.updateTime, settings: settingsStamp,
                          slotOn: slotOn, choices: conv?.memoryWindowChoices,
                          model: (conv?.selectedModelId ?? "") + "|" + selectedChatModelId,
                          branchId: conv?.currentNodeId,
                          // 标量转换：刷新键只观察已驻内存的值，绝不读外置 segmentsData
                          recentNodes: MemoryResident.wikiRevisions(in: (viewModel?.currentPath ?? []).map { ConversationMessage(scalar: $0) }),
                          identity: MemoryResident.IdentityKey(profile: profile, conversationPersonaId: conv?.personaId,
                                                               personas: personaStore.personas))
    }

    /// 实发用的预设同聊天页：楼层绑的那份，找不到用内置
    private var slotOn: Bool {
        MemoryResident.memorySlotOn(presetManager?.preset(byId: profile?.presetId ?? "") ?? Preset.balanced)
    }

    var body: some View {
        List {
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
                            .panelRowBackground()
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
                    Text("每轮全带勾着：另外 \(snapshot.fullFallbackCount) 条批过的记忆条目也每一轮都带（预算内）")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
            Section { EmptyView() } header: { Text("下一轮会看见什么") }
            InjectionPreviewSections(stable: snapshot.stable, volatilePart: snapshot.volatile, everyRound: snapshot.everyRound,
                                     masterOff: !MemoryFlags.masterEnabled,
                                     memoryCount: snapshot.memoryCount, lastInjection: lastInjection, assistantName: assistantName)
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .memorySubpage("常驻记忆")
        .memoryEntryPage($entryTarget, onJump: jumpAction, onEvent: { undo.show($0) })
        .memoryUndoToast(undo, profileId: profileId)
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

    /// 正文 2 行 +「原因 · 日期」+ 灰字；点开详情页；钉住的左滑 / 右键 Unpin
    private func archiveRow(_ row: MemoryResident.ArchiveRow) -> some View {
        let mem = row.memory
        return Button { entryTarget = .existing(mem) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(mem.lineText)
                    .font(m.body)
                    .foregroundColor(row.gate == nil ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(2)
                Text(row.reason + " · " + MemoryDateText.short(mem.createdAt))
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                if let gate = row.gate { grayLine(gate) }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            if mem.isUserExplicit {
                Button { unpin(mem) } label: { Label("Unpin", systemImage: "pin.slash") }
                    .tint(Theme.branchIndicator)
            }
        }
        .contextMenu {
            Button { entryTarget = .existing(mem) } label: { Label("Edit", systemImage: "pencil") }
            if mem.isUserExplicit {
                Button { unpin(mem) } label: { Label("Unpin", systemImage: "pin.slash") }
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

    // MARK: - 动作 / 数据

    /// 取消钉住：走 `MemoryEntryActions`（存成了发通知、重算；记一笔，浮条能 Undo；存不成浮那句红字）
    private func unpin(_ mem: Memory) {
        guard mem.isUserExplicit else { return }
        undo.show(MemoryEntryActions.togglePin([mem], profileId: profileId, context: modelContext))
    }

    /// 详情页里 Open in chat：同记忆页
    private func jumpAction(_ mem: Memory) -> (() -> Void)? {
        guard let viewModel, mem.sourceConversationId != nil else { return nil }
        return { _ = MemoryConversationLink.openSource(of: mem, profileId: profileId, context: modelContext, viewModel: viewModel) }
    }

    /// 读文件、组装注入都在后台（`MemoryResident.loadSummary`）；主线程只按 id 取回那几条档案（开详情页 / 取消钉住要用这个 context 里的对象）。
    /// 只收最新一次刷新的结果；拼的时候复核掉了行（后台算完后被删 / 取消钉住）→ 下半预览也是旧的，再算一次（只补一次，10-16 astra #3）
    private func reload(retry: Bool = false) {
        guard let profile else { return }
        let n = ticket.next()
        let key = refreshKey
        let effectiveProfile = SendContextResolver.resolve(profile: profile, conversation: viewModel?.selectedConversation,
                                                            context: modelContext, globalEntries: []).profile
        let container = modelContext.container
        let preset = presetManager?.preset(byId: profile.presetId ?? "") ?? Preset.balanced
        let participation = EffectiveMemoryParticipation.resolve(profileId: profile.id,
                                                                 conversation: viewModel?.selectedConversation,
                                                                 preset: preset)
        // 这一轮调得到的工具：同工具抽屉，走实发那一套（没有对话 = nil，尾注原样）
        let tools = providerManager.flatMap { viewModel?.previewTools(providerManager: $0, profileModelId: profile.preferredModel,
                                                                      globalModelId: selectedChatModelId) }
            .map { Set($0.signature.tools).union($0.signature.catalog) }
        let recentNodeIds = key.recentNodes.map(\.id)
        let path = viewModel?.currentPath ?? []
        Task {
            let summary = await MemoryResident.loadSummary(profile: effectiveProfile, participation: participation, container: container,
                                                           availableTools: tools, recentNodeIds: recentNodeIds)
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
            lastInjection = MemoryResident.lastInjection(in: path) { viewModel?.cachedRecallReceipt($0) }
                ?? MemoryInjectionMeter.load(profileId: pid)
            loaded = true
        }
    }
}
