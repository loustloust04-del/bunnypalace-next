#if os(iOS)
import MemoryCore
import SwiftData
import SwiftUI

/// 人页（plan-atrium P2）：page0 右上胶囊、气泡模式顶栏头像、通讯录组件都开它。只看当前层（不带 profileId，research-atrium §4⑦）。
/// 头部 + 三个 tab：动态（这个人在聊天之外干了什么）/ 设定（是谁 · 怎么说话 · 聊天时的样子）/ 权限（这个人的档位表 + 本楼层工具抽屉）。
/// 设定里的行不再带 `SharedByAllBadge`（atrium P3④b 起「聊天时的样子」三行也按人存）；记忆不进人页，只留一个「记忆 ›」
struct PersonPageView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m
    /// 人设 / 记忆页的 lite、pro 两版跟设置走同一个开关（去留 P3 拍）
    @AppStorage("settings.proMode") private var settingsProMode = false

    private enum Tab: String, CaseIterable, Identifiable {
        case feed = "动态", settings = "设定", permissions = "权限"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .feed
    @State private var card = ProfileCardStore.Card()
    @State private var voices: [(time: Date, text: String)] = []
    @State private var todayTimeline: String?
    @State private var conversationCount = 0
    @State private var memoryCount = 0
    @State private var isEditingBio = false
    @State private var bioDraft = ""
    @State private var showWriteLog = false
    @State private var names = ProfileNameDraft()
    @State private var renameError: String?

    private var profile: Profile? { profileManager?.currentProfile }
    private var profileId: String { profile?.id ?? "" }
    private var theme: ThemeManager { themeManager ?? ThemeManager.shared }

    /// 「主题」行右边：TA 的聊天主题名；没选过 / 选的那套删了 = 跟随
    private var chatThemeValue: String {
        let target = ThemeTarget.person(profileId)
        return target.isFollowingInterface(theme, profileManager)
            ? "跟随界面主题（宫殿默认）"
            : theme.chatTheme(for: target.storedChatThemeId(profileManager)).name
    }

    /// 「聊天背景」行右边：TA 的聊天主题有图 = 透明度，没图 =「无背景图」
    private var chatBackgroundValue: String {
        let id = ThemeTarget.person(profileId).themeId(theme, profileManager)
        guard theme.backgroundImageURL(for: id) != nil else { return "无背景图" }
        return "\(Int((theme.backgroundStyle(for: id).resolvedOpacity(for: theme.activeScheme) * 100).rounded()))%"
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .feed: tabList { feedSections }
                case .settings: tabList { settingsSections }
                case .permissions:
                    // atrium P3⑤a：头部后先是这个人的权限真表，再是本楼层工具抽屉；⑥a：真表前是「TA 主屏上的 App」
                    ToolDrawerPage(floorOnly: true, leading: AnyView(Group {
                        headerSections
                        PersonAppSections(profileId: profileId)
                        PersonPermissionSections(profileId: profileId)
                    }))
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .tint(Theme.branchIndicator)
        .onAppear(perform: reload)
        .onChange(of: profile?.id, initial: true) { _, _ in refreshNames() }
        .onChange(of: profile?.userName) { _, _ in refreshNames() }
        .onChange(of: profile?.assistantName) { _, _ in refreshNames() }
        .sheet(isPresented: $showWriteLog) {
            MemoryWriteLogSheet(profileId: profileId)
        }
        .alert("改名失败", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("好", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
        .accessibilityAction(.escape) { dismiss() }
    }

    private func tabList<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List {
            headerSections
            content()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditingBio {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { isEditingBio = false }
                    .foregroundColor(Theme.textMuted)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    ProfileCardStore.saveBio(bioDraft, profileId: profileId)
                    card = ProfileCardStore.load(profileId: profileId)
                    isEditingBio = false
                }
                .foregroundColor(Theme.branchIndicator)
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .foregroundColor(Theme.textSecondary)
                    .accessibilityLabel("关闭")
            }
            if tab == .feed {
                ToolbarItem(placement: .confirmationAction) {
                    Button("编辑") {
                        bioDraft = card.bio ?? ""
                        isEditingBio = true
                    }
                    .foregroundColor(Theme.branchIndicator)
                }
            }
        }
    }

    // MARK: 头部（三个 tab 共用，排在每个 tab 列表的最前面）

    @ViewBuilder
    private var headerSections: some View {
        Section {
            VStack(spacing: 10) {
                ProfileAvatarView(profile: profile, size: 96)
                Text(profile?.assistantName ?? "助手")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let p = profile {
                    Text("\(p.emoji) \(p.name)")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                if let status = card.status {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.branchIndicator)
                            .frame(width: 6, height: 6)
                        Text(status)
                            .font(.system(size: Theme.F.secondary, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                HStack(spacing: 0) {
                    stat(conversationCount, "对话")
                    stat(acquaintedDays, "相识天数")
                    stat(memoryCount, "记忆")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)

        Section {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isEditingBio)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text(label)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    /// 建层那天算第 1 天
    private var acquaintedDays: Int {
        guard let created = profile?.createdAt else { return 0 }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: created), to: cal.startOfDay(for: Date())).day ?? 0
        return max(days, 0) + 1
    }

    // MARK: 动态

    @ViewBuilder
    private var feedSections: some View {
        Section("bio") {
            if isEditingBio {
                TextEditor(text: $bioDraft)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 160)
            } else {
                Text(card.bio ?? "还没有 bio——点右上角编辑，或者让 TA 自己填")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(card.bio == nil ? Theme.textMuted : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .listRowBackground(Theme.mainBg)
        .listRowSeparator(.hidden)

        Section("💭 碎碎念") {
            if voices.isEmpty {
                Text("还没有碎碎念")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(Array(voices.enumerated()), id: \.offset) { _, voice in
                    HeartvoiceCardView(text: voice.text, time: voice.time)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listRowBackground(Theme.mainBg)

        if let todayTimeline {
            Section("今天的时间轴") {
                Text(todayTimeline)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(Theme.mainBg)
        }

        Section {
            Button { showWriteLog = true } label: {
                HStack {
                    Text("记忆写入日志")
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: 设定

    @ViewBuilder
    private var settingsSections: some View {
        Section {
            VStack(spacing: 8) {
                SettingsTextField(label: "我的名字", placeholder: "你", text: $names.userName)
                SettingsTextField(label: "AI 的名字", placeholder: "助手", text: $names.assistantName)
            }
            HStack {
                Text("用于对话提示词和消息名称标签")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button(action: saveNames) {
                    Text("确认")
                        .font(m.secondary.weight(.medium))
                        .settingsCapsuleLabel(filled: true, hPadding: 16)
                }
                .settingsActionButton()
            }
            AvatarSettingsRows()
            link("人设 Prompt") {
                if settingsProMode { PersonaSettingsTab() } else { LitePersonaPage() }
            }
            link("世界书") { WorldBookPage() }
            link("正则") { RegexPage() }
            link("贴纸") { StickerPage() }
        } header: {
            Text("是谁")
        }
        .listRowBackground(Theme.mainBg)

        Section {
            link("声音") { PersonVoicePage() }
            link("模型", value: providerManager?.model(byId: profile?.preferredModel ?? "")?.name ?? "跟随全局默认") { PersonModelPage() }
            link("时区", value: profile?.characterTimeZone ?? "未设置") { CharacterTimeZonePage() }
        } header: {
            Text("怎么说话")
        }
        .listRowBackground(Theme.mainBg)

        Section {
            link("聊天背景", value: chatBackgroundValue) { ChatBackgroundPage(target: .person(profileId)) }
            link("主题", value: chatThemeValue) { ThemeLibraryPage(target: .person(profileId)) }
            link("气泡 · 字号") { PersonChatAppearancePage(profileId: profileId) }
        } header: {
            Text("聊天时的样子")
        }
        .listRowBackground(Theme.mainBg)

        Section {
            link("记忆") {
                if settingsProMode { MemoryPage() } else { LiteMemoryPage() }
            }
        } footer: {
            Text("记忆的开关和条目在记忆设置页里管，不放进人页。")
                .font(.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
    }

    private func link<Destination: View>(_ title: String, value: String? = nil,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: 数据

    private func reload() {
        let pid = profileId
        card = ProfileCardStore.load(profileId: pid)
        voices = HeartvoiceFileStore.recentVoices(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), limit: 5)
        conversationCount = (try? modelContext.fetchCount(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.profileId == pid && !$0.isTrashed }))) ?? 0
        memoryCount = (try? modelContext.fetchCount(FetchDescriptor<Memory>(
            predicate: #Predicate { $0.profileId == pid }))) ?? 0
        todayTimeline = Self.latestTimelineItem(profileId: pid)
    }

    /// 今天（记忆日，05:00 起）时间轴里最近的一项；旧的按天日记（memory/daily/）已停写，读新时间轴
    private static func latestTimelineItem(profileId: String) -> String? {
        let now = Date()
        let dir = TimelineStore.dir(memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        let today = MemoryDay.key(now)
        guard let record = TimelineStore.month(MemoryDay.month(now), in: dir).days.first(where: { $0.date == today }),
              let item = record.items.max(by: { $0.start < $1.start }) else { return nil }
        return TimelineStore.itemBody(item)
    }

    private func refreshNames() {
        guard let p = profile else { return }
        names.refresh(profileId: p.id, userName: p.userName, assistantName: p.assistantName)
    }

    private func saveNames() {
        guard let profileManager else { return }
        do {
            try names.save(using: profileManager)
            ToastCenter.shared.show("已保存")
        } catch {
            renameError = error.localizedDescription
        }
    }
}

// MARK: - 声音（本楼层）

/// 人页「声音 ›」：只放按楼层存的那几行（服务 / 声音 / 嗓子说明 / 语音条和通话模型 / 声音效果）。
/// 改了照设置 › 语音那样同步 cc-rp 的语音说明块（`VoiceMessageSettingsIOSSections`）
private struct PersonVoicePage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        List {
            Section {
                FloorVoiceRows()
            } footer: {
                Text("语音服务的 key、听语气这些在 设置 › 语音。")
            }
            .listRowBackground(Theme.mainBg)

            Section {
                VoiceEffectControls()
            } header: {
                Text("声音效果")
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("声音")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: profileManager?.currentProfile) { _, p in
            guard let p else { return }
            CCBridgeWebSocketClient.shared.syncVoiceInstructions(VoicePromptInjector.ccInstructionsBlock(profile: p))
        }
    }
}

// MARK: - 气泡 · 字号（本楼层）

/// 人页「气泡 · 字号 ›」（atrium P3④b）：字体字号 / 行距段距 / 气泡几何，只改这个人的
private struct PersonChatAppearancePage: View {
    let profileId: String

    var body: some View {
        List {
            ChatAppearanceSections(profileId: profileId)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("气泡 · 字号")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 模型（本楼层）

/// 人页「模型 ›」（atrium P3①）：选这个人的模型，写 `Profile.preferredModel`，不动全局 🌞。
/// 列表和输入框模型切换器同一个（只列 ☆ 收藏）；「跟随全局默认」= 存空
private struct PersonModelPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedChatModel") private var globalModelId = ""
    @State private var saveError: String?

    /// 层上存的 id 解析不出（空 / 老格式默认值 / 模型已删）都算跟随全局
    private var picked: ProviderModel? { providerManager?.model(byId: profileManager?.currentProfile.preferredModel ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { save("") } label: {
                HStack(spacing: 8) {
                    Image(systemName: picked == nil ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(picked == nil ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("跟随全局默认")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                        Text("现在是 \(providerManager?.model(byId: globalModelId)?.name ?? "没设")，在 我 › 模型和API 里点 🌞 改")
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                }
                .padding(.horizontal, 26)
                .padding(.vertical, Theme.optionRowVerticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Text("只管这个人之后新开的对话；聊过的对话记着自己的模型，在输入框里切。")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 26)
                .padding(.vertical, 6)

            Divider().opacity(0.15).padding(.horizontal, 26)

            if let providerManager {
                ModelPickerPopover(providerManager: providerManager, selectedModelId: picked?.id ?? "") { save($0.id) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg)
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save(_ modelId: String) {
        guard let profileManager else { return }
        var p = profileManager.currentProfile
        p.preferredModel = modelId
        do {
            try profileManager.updateProfileChecked(p)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - 时区（本楼层）

/// 人页「时区 ›」：原来只能在楼层编辑页改（`ProfileEditorSheet`「角色时区」），这里直接给一页。
/// 「作息感知」开关按楼层（atrium P3②），拨了立刻存；时区输入照旧点「保存」
private struct CharacterTimeZonePage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var saveError: String?

    private var trimmed: String { input.trimmingCharacters(in: .whitespaces) }
    private var invalid: Bool { !trimmed.isEmpty && TimeZone(identifier: trimmed) == nil }

    var body: some View {
        List {
            Section {
                Toggle("作息感知（问候 / 作息按这个人的时区）", isOn: Binding(
                    get: { profileManager?.currentProfile.timeAwarenessEnabled ?? false },
                    set: { setAwareness($0) }
                ))
                .tint(Theme.branchIndicator)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                TextField("例：Asia/Shanghai", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                if invalid {
                    Text("时区名无效——用 IANA 名，如 Asia/Shanghai、Asia/Tokyo、America/New_York")
                        .foregroundColor(Theme.danger)
                } else {
                    Text("填了之后，问候和作息（深夜/清晨/工作时间）按角色的本地时间算；留空就不带。")
                }
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("时区")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(invalid)
            }
        }
        .onAppear { input = profileManager?.currentProfile.characterTimeZone ?? "" }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func setAwareness(_ on: Bool) {
        guard let profileManager else { return }
        var p = profileManager.currentProfile
        p.timeAwarenessEnabled = on
        do { try profileManager.updateProfileChecked(p) } catch { saveError = error.localizedDescription }
    }

    private func save() {
        guard let profileManager else { return }
        var p = profileManager.currentProfile
        p.characterTimeZone = trimmed.isEmpty ? nil : trimmed
        do {
            try profileManager.updateProfileChecked(p)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
#endif
