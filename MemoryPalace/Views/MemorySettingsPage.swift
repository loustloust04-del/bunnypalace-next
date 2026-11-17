import MemoryCore
import SwiftUI
import SwiftData

// MARK: - macOS Memory Settings Tab

/// 状态卡（v5 §二）：iOS 原样几行平铺——记新东西（C2）/ 写上下文摘要（A2）/ 写窗口总结（A3）/ 写时间轴（A4）。
/// 右上 ⓘ → 记忆日志；每一行点了 → 日志里这一项最近那条。关着灰字「关着，没在写」不红、计数不清（0.1）；
/// 写入预算用完灰字「写入预算用完，下周一再写」。macOS 设置-记忆 与 iOS 记忆页 / 记忆 app 设置格共用。
struct MemoryHealthStatusView: View {
    let profileId: String
    @Environment(\.settingsMetrics) private var m
    @State private var statuses: [MemoryHealthStore.Kind: MemoryHealthStore.Status] = [:]
    /// 这一项开没开（总开关 && 这一项）；关着灰字、不红
    @State private var on: [MemoryHealthStore.Kind: Bool] = [:]
    @State private var masterOn = true
    @State private var budgetPaused = false
    @State private var logFocus: LogTarget?

    private struct LogTarget: Identifiable {
        let writer: MemoryWriterID?
        var id: String { writer?.rawValue ?? "all" }
    }

    /// 四行：（种类，编号，标签，红字）
    static let lines: [(MemoryHealthStore.Kind, String, String)] = [
        (.extract, "记新东西", "最近记不住新东西了"),
        (.context, "写上下文摘要", "最近写不成上下文摘要"),
        (.summary, "写窗口总结", "最近写不成窗口总结"),
        (.timeline, "写时间轴", "最近写不成时间轴"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if !masterOn {
                    Text("总开关关着 · 都暂停了")
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(Self.lines, id: \.1) { kind, label, failing in
                        // 第三刀：A2 / A3 / A4 跑过、在失败或关着才显示（不再多一行「还没跑过」）
                        let s = statuses[kind] ?? .init(lastOK: nil, lastError: nil, lastErrorMessage: nil, failStreak: 0, modelName: nil)
                        if kind == .extract || s.lastOK != nil || s.needsAttention || on[kind] == false {
                            healthLine(kind, label: label, failing: failing, status: s)
                        }
                    }
                }
            }
            .font(m.caption)
            Spacer(minLength: 0)
            Button { logFocus = LogTarget(writer: nil) } label: {
                Image(systemName: "info.circle")
                    .font(m.body)
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("记忆日志")
        }
        .sheet(item: $logFocus) { target in
            MemoryWriteLogSheet(profileId: profileId, focus: target.writer)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in reloadOn() }
    }

    private func reload() {
        var s: [MemoryHealthStore.Kind: MemoryHealthStore.Status] = [:]
        for (kind, _, _) in Self.lines { s[kind] = MemoryHealthStore.status(kind, profileId: profileId) }
        statuses = s
        reloadOn()
        Task {
            let over = await Task.detached(priority: .utility) { WriteBudgetStore.exceeded() }.value
            if over != budgetPaused { budgetPaused = over }
        }
    }

    private func reloadOn() {
        let now = Dictionary(uniqueKeysWithValues: Self.lines.map { ($0.0, MemoryHealthStore.isOn($0.0)) })
        if now != on { on = now }
        if MemoryFlags.masterEnabled != masterOn { masterOn = MemoryFlags.masterEnabled }
    }

    @ViewBuilder
    private func healthLine(_ kind: MemoryHealthStore.Kind, label: String, failing: String, status: MemoryHealthStore.Status) -> some View {
        let off = on[kind] == false
        // C2 是本机 $0 / 也算写入预算（云上那条）；B1 / B4 不在状态卡
        let paused = budgetPaused && !off
        Button { logFocus = LogTarget(writer: MemoryWriterID(health: kind)) } label: {
            HStack(spacing: 5) {
                if off {
                    Text("\(label)：关着，没在写")
                        .foregroundColor(Theme.textMuted)
                } else if paused {
                    Text("\(label)：\(WriteBudgetStore.pausedText(period: WriteBudgetStore.shared.period))")
                        .foregroundColor(Theme.textMuted)
                } else if status.needsAttention {
                    Circle().fill(Theme.danger).frame(width: 6, height: 6)
                    Text("\(failing) · 连续 \(status.failStreak) 次")
                        .foregroundColor(Theme.danger)
                } else if let ok = status.lastOK {
                    Text("上次\(label)：\(Self.relative(ok))")
                        .foregroundColor(Theme.textMuted)
                } else {
                    Text("上次\(label)：还没有")
                        .foregroundColor(Theme.textMuted)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#if os(macOS)
/// A5（她裁「不删」）：mac 设置 · 记忆页保留的条目区——一行一条（和记忆页同一个行），点一条开唯一的那张详情页（改 / 钉 / 删都在那里，
/// 记进记忆日志、在记忆日志里能 Undo）；「手动添加记忆」开同一张页的新建态。11-15 起不再就地改、不再硬删（删了进 Deleted）。
/// 第 2 类例外：iOS 这块在右栏「记忆」面板，设置页没有；接在 `MemoryPageContent()` 之后。
/// 列表订阅 `.memoryDidChange` 刷新（共用核那两条写路径——整理完成 / 单独做梦——也刷得到）。切楼层仍先清空。
struct MacMemoryEntriesSections: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m

    @State private var memories: [Memory] = []
    @State private var entryTarget: MemoryEntryTarget?

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    var body: some View {
        Group {
            Section("记忆条目") {
                if memories.isEmpty {
                    Text("还没有记忆")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                        .padding(.vertical, 8)
                } else {
                    ForEach(memories, id: \.id) { memory in
                        Button { entryTarget = .existing(memory) } label: {
                            MemoryRow(item: MemoryRowItem(memory)) { EmptyView() }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button { entryTarget = .new(profileId: profileId) } label: {
                    Label("手动添加记忆", systemImage: "plus")
                        .font(m.secondary)
                        .foregroundColor(ShellStyle.text)
                }
                .buttonStyle(MacSettingsButton())
                // 挂在常在的这一行上（挂在 Group 上会分到每一行）
                .memoryEntryPage($entryTarget)
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
    }

    /// 活着的，钉住在前、新→旧（同记忆页）
    private func refreshMemories() {
        memories = MemoryArchiveOrder.split(SwiftDataMemoryStore().listAll(profileId: profileId, context: modelContext)).active
    }
}
#endif

// MARK: - Memory Page（壳 — 内容全交给 MemoryPageContent 共用核，两端一份 body）

struct MemoryPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    #if os(iOS)
    @State private var memorySearchRoute: SettingsRoute?
    #endif

    var body: some View {
        // 搜索锚点：命中叶子条目时滚到那一行
        ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            // 状态卡（设置-记忆 专属；记忆系统说明挪到页底一行，粟粟 11-15）
            Section {
                MemoryHealthStatusView(profileId: profileManager?.currentProfile.id ?? "")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            // 共用核：设置-记忆 的各节
            MemoryPageContent()
                #if os(iOS)
                .environment(\.settingsRoutePush) { memorySearchRoute = $0 }
                #endif

            #if os(macOS)
            // A5：mac 独有的条目 CRUD（第 2 类例外），接在共用核之后
            MacMemoryEntriesSections()
            #endif
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationDestination(item: $memorySearchRoute) { route in
            switch route {
            case .memoryArchiveTrigger: ArchiveTriggerPage(searchTarget: SettingsSearchRouter.shared.flashingAnchor)
            case .memoryRecallBrowse: RecallBrowsePage(searchTarget: SettingsSearchRouter.shared.flashingAnchor)
            case .memoryOpenWindow: MemoryOpenWindowPage(searchTarget: SettingsSearchRouter.shared.flashingAnchor)
            case .memoryCCSync: MemoryCCSyncPage()
            case .memoryAuditSettings: MemoryAuditSettingsPage()
            default: EmptyView()
            }
        }
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
}
