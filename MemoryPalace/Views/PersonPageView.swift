#if os(iOS)
import MemoryCore
import SwiftData
import SwiftUI

/// 人页（plan-atrium P2；11-16 学 Telegram 资料页减压，plan-chat-menus C）：page0 左上大头像、聊天页顶栏头像、通讯录组件都开它。只看当前层。
/// 主页面只「看」：头部（头像 / 名字 / 状态 / 一行小字）+ 四个大按钮（聊天 · 通话 · 记忆 · 更多）+ bio + 三个小 tab（动态 / 碎碎念 / 时间轴）。
/// 改东西都在右上「编辑」（`PersonEditPage`：bio、是谁、怎么说话、聊天时的样子、权限和 App）
struct PersonPageView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    /// 记忆页的 lite、pro 两版跟设置走同一个开关
    @AppStorage("settings.proMode") private var settingsProMode = false

    private enum Tab: String, CaseIterable, Identifiable {
        // 「动态」= 原 heartbeat（粟粟 11-11）：TA 自己醒来做事的任务
        case feed = "动态", voices = "碎碎念", timeline = "时间轴"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .feed
    @State private var card = ProfileCardStore.Card()
    @State private var voices: [(time: Date, text: String)] = []
    @State private var todayTimeline: String?
    @State private var conversationCount = 0
    @State private var memoryCount = 0
    @State private var showWriteLog = false
    @State private var showMemory = false

    private var profile: Profile? { profileManager?.currentProfile }
    private var profileId: String { profile?.id ?? "" }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                actionsSection
                bioSection
                tabPicker
                switch tab {
                case .feed: HeartbeatSections(profileId: profileId)
                case .voices: voicesSection
                case .timeline: timelineSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .foregroundColor(Theme.textSecondary)
                        .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink("编辑") { PersonEditPage(onBioSaved: reload) }
                        .foregroundColor(Theme.branchIndicator)
                        .accessibilityIdentifier("person-edit")
                }
            }
            .navigationDestination(isPresented: $showMemory) {
                if settingsProMode { MemoryPage() } else { LiteMemoryPage() }
            }
        }
        .tint(Theme.branchIndicator)
        .onAppear(perform: reload)
        .sheet(isPresented: $showWriteLog) {
            MemoryWriteLogSheet(profileId: profileId)
        }
        .accessibilityAction(.escape) { dismiss() }
        // 「聊天」/「通话」/ heartbeat 里点了「去这个对话里看」：人页收起，回到聊天
        .onReceive(NotificationCenter.default.publisher(for: .conversationNavigationRequested)) { _ in dismiss() }
    }

    // MARK: 头部

    private var headerSection: some View {
        Section {
            VStack(spacing: 8) {
                ProfileAvatarView(profile: profile, size: 96)
                Text(profile?.assistantName ?? "助手")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
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
                Text("相识 \(acquaintedDays) 天 · \(conversationCount) 段对话 · \(memoryCount) 条记忆")
                    .font(.system(size: Theme.F.caption))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// 建层那天算第 1 天
    private var acquaintedDays: Int {
        guard let created = profile?.createdAt else { return 0 }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: created), to: cal.startOfDay(for: Date())).day ?? 0
        return max(days, 0) + 1
    }

    // MARK: 四个大按钮

    private var actionsSection: some View {
        Section {
            HStack(spacing: 10) {
                actionButton("聊天", "bubble.left.and.bubble.right") {
                    NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
                }
                actionButton("通话", "phone") {
                    NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
                    // 等人页收起、翻到聊天页再拨（通话页挂在聊天页上）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NotificationCenter.default.post(name: .voiceCallRequested, object: nil)
                    }
                }
                actionButton("记忆", "brain") { showMemory = true }
                Menu {
                    Button { showWriteLog = true } label: { Label("记忆写入日志", systemImage: "list.bullet.rectangle") }
                } label: {
                    actionLabel("更多", "ellipsis")
                }
                .accessibilityIdentifier("person-action-更多")
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func actionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, icon) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("person-action-\(title)")
    }

    private func actionLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .frame(height: 24)
            Text(title)
                .font(.system(size: Theme.F.caption))
        }
        .foregroundColor(Theme.branchIndicator)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.mainBg))
        .contentShape(Rectangle())
    }

    // MARK: bio + 三个小 tab（全是看的，改 bio 在「编辑」）

    private var bioSection: some View {
        Section {
            Text(card.bio ?? "还没有 bio——点右上角编辑，或者让 TA 自己填")
                .font(.system(size: Theme.F.body))
                .foregroundColor(card.bio == nil ? Theme.textMuted : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowBackground(Theme.mainBg)
    }

    private var tabPicker: some View {
        Section {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private var voicesSection: some View {
        Section {
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
    }

    private var timelineSection: some View {
        Section {
            Text(todayTimeline ?? "今天还没有时间轴")
                .font(.system(size: Theme.F.body))
                .foregroundColor(todayTimeline == nil ? Theme.textMuted : Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .listRowBackground(Theme.mainBg)
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
}

extension Notification.Name {
    /// 人页「通话」：聊天页（CardFlowView）收到就拨，同 + 号条 📞
    static let voiceCallRequested = Notification.Name("MemoryPalaceVoiceCallRequested")
}

// MARK: - 编辑（原「设定」「权限」两个 tab，11-16 挪进右上「编辑」）

private struct PersonEditPage: View {
    let onBioSaved: () -> Void

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @Environment(\.settingsMetrics) private var m
    /// 人设 / 记忆页的 lite、pro 两版跟设置走同一个开关（去留 P3 拍）
    @AppStorage("settings.proMode") private var settingsProMode = false

    @State private var bio = ""
    @State private var bioLoaded = false
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
        List {
            Section {
                TextEditor(text: $bio)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, maxHeight: 160)
                HStack {
                    Text("TA 也会自己填")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Button {
                        ProfileCardStore.saveBio(bio, profileId: profileId)
                        onBioSaved()
                        ToastCenter.shared.show("已保存")
                    } label: {
                        Text("保存")
                            .font(m.secondary.weight(.medium))
                            .settingsCapsuleLabel(filled: true, hPadding: 16)
                    }
                    .settingsActionButton()
                }
            } header: {
                Text("bio")
            }
            .listRowBackground(Theme.mainBg)

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
                #if DEBUG
                // 电脑文件夹（plan-folder-floor P1，只进 Debug 包）：这一层连哪台电脑上的文件夹
                link("电脑文件夹", value: PersonFolderPage.summary(for: profile)) { PersonFolderPage() }
                #endif
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
                // atrium P3⑤a / ⑥a：TA 主屏上的 App + 这个人的权限真表 + 本楼层工具抽屉
                link("权限和 App") {
                    ToolDrawerPage(floorOnly: true, leading: AnyView(Group {
                        PersonAppSections(profileId: profileId)
                        PersonPermissionSections(profileId: profileId)
                    }))
                    .navigationTitle("权限和 App")
                }
            } header: {
                Text("能做什么")
            }
            .listRowBackground(Theme.mainBg)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("编辑")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !bioLoaded else { return }
            bio = ProfileCardStore.load(profileId: profileId).bio ?? ""
            bioLoaded = true
        }
        .onChange(of: profile?.id, initial: true) { _, _ in refreshNames() }
        .onChange(of: profile?.userName) { _, _ in refreshNames() }
        .onChange(of: profile?.assistantName) { _, _ in refreshNames() }
        .alert("改名失败", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("好", role: .cancel) { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
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
