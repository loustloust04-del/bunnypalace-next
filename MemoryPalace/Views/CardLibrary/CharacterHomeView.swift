import SwiftUI
import SwiftData

struct CharacterHomeView: View {
    let profileId: String
    let cardId: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @AppStorage("assistantName") private var assistantName = "助手"
    /// 没楼层时 `names` 回退读全局用户名。B-8（plan-paging-decouple B-0 表 1）：翻页不再重交 rootView 后，这个值要自带失效通道——声明即订阅
    @AppStorage("userName") private var userNameSubscription = ""
    @Query private var conversations: [Conversation]
    @State private var editingCard: CharacterCard?
    @State private var editingProfile: Profile?
    @State private var exporting = false
    @State private var errorMessage: String?
    @State private var creatingChat = false
    @State private var accessoriesExpanded = true
    @State private var bannerVisible = false
    @State private var pickingPersona = false
    /// 第二批 B1：静态扫描出的不支持功能（读原 JSON，进页 / 卡变了算一次）；右侧 ⓘ 展开的是哪一行
    @State private var staticUnsupported: [CardUnsupportedFeature] = []
    @State private var openInfo: String?

    init(profileId: String, cardId: String?) {
        self.profileId = profileId
        self.cardId = cardId
        _conversations = Query(filter: #Predicate<Conversation> { $0.profileId == profileId && !$0.isTrashed },
                               sort: [SortDescriptor(\Conversation.updateTime, order: .reverse), SortDescriptor(\Conversation.id)])
    }

    private var card: CharacterCard? { cardManager?.cards.first { $0.id == cardId } }
    private var profile: Profile? { profileManager?.profiles.first { $0.id == profileId } }
    private var name: String { card?.name ?? profile?.name ?? assistantName }
    private var needsConsent: Bool {
        guard let card else { return false }
        return card.extensionConsent == .unknown && card.needsExtensionConsent
    }
    /// 「用到了还不支持的」：静态扫描 ∪ Page2 运行时垫片记下的
    private var unsupportedLabels: [String] {
        CardFeatureScanner.describe(static: staticUnsupported,
                                    runtime: HTMLEmbedRuntimeStore.shared.reports[profileId]?.unsupportedAPIs ?? [])
    }
    private var isCurrent: Bool { profileManager?.currentProfile.id == profileId }
    /// 卡描述里的 `{{char}}` / `{{user}}` 只在显示时展开：角色名 + 楼层有效身份（楼层 personaId → 楼层原本的身份）；没楼层用卡名 + 全局用户名
    private var names: EffectiveCharacterContext {
        guard let profile else { return EffectiveCharacterContext(charName: name, userName: UserDefaults.standard.string(forKey: "userName") ?? "") }
        let persona = PersonaResolution.resolve(conversationPersonaId: nil, floorPersonaId: profile.personaId, personas: UserPersonaStore.shared.personas)
        return EffectiveCharacterContext(profile: persona.applied(to: profile))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                #if os(iOS)
                // 位置同 page1 聊天顶栏返回键（左 16、安全区下 8）
                HStack {
                    GlassBackButton { navigator?.characterHome = nil }
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 8)
                #else
                HStack {
                    Button { navigator?.characterHome = nil } label: {
                        Label("角色", systemImage: "chevron.left").frame(minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundColor(Theme.branchIndicator)
                    Spacer()
                }.padding(.horizontal, IOSCal.pad)
                #endif
                if bannerVisible, let card { consentBanner(card) }
                CalendarTicket {
                    cover
                    header
                    TicketNotch()
                    IOSSubLabel(text: "聊天 · \(conversations.count) 个")
                    if conversations.isEmpty {
                        Text("还没开始").font(.system(size: 14)).foregroundColor(Theme.textMuted).padding(IOSCal.pad)
                    }
                    ForEach(conversations) { conversation in chatRow(conversation) }
                    if let profile {
                        TicketNotch()
                        IOSCalendarRow(icon: "person.crop.circle", title: "我的身份", meta: personaLabel(profile)) { pickingPersona = true }
                    }
                    if let card {
                        TicketNotch()
                        accessories(card)
                    }
                    TicketNotch()
                    IOSCalendarRow(icon: "pencil", title: card == nil ? "编辑楼层" : "编辑卡") {
                        if let card { editingCard = card } else { editingProfile = profile }
                    }
                    // 第二批 B7：导出小票（PNG / JSON）
                    IOSCalendarRow(icon: "square.and.arrow.up", title: "导出", meta: "PNG / JSON") { exporting = true }
                        .disabled(card == nil && profile == nil)
                    if card != nil {
                        IOSCalendarRow(icon: "arrow.down.doc", title: "应用到这个楼层", meta: "下一版") {}.disabled(true)
                    }
                    Color.clear.frame(height: 12)
                }
            }.padding(.bottom, 16)
        }
        .background(Theme.sidebarBg)
        .onAppear { updateBanner() }
        .task { await resumeIfRequested() }
        .task(id: card) { staticUnsupported = card?.unsupportedFeatures ?? [] }
        .onChange(of: needsConsent) { _, _ in updateBanner() }
        .sheet(isPresented: $exporting) {
            if let exported = card ?? profile.map({ CharacterCard(profile: $0) }) {
                CardExportTicketView(card: exported, isLibraryCard: card != nil, profile: profile)
            }
        }
        .sheet(item: $editingCard) { original in
            CharacterCardEditor(card: original) { updated in
                guard isCurrent, let cardManager else { throw CharacterFloorService.Failure.notCurrent }
                try cardManager.update(updated)
                editingCard = nil
            } onCancel: { editingCard = nil }
        }
        .sheet(item: $editingProfile) { profile in
            if let profileManager { ProfileEditorSheet(profileManager: profileManager, mode: .edit(profile)) }
        }
        .sheet(isPresented: $pickingPersona) {
            PersonaPickerSheet(title: "我的身份", fallbackTitle: "楼层原本的身份",
                               fallbackSubtitle: "用楼层设置里的名字和身份描述", selectedId: profile?.personaId,
                               names: profile.map { EffectiveCharacterContext(profile: $0) } ?? names) { id in
                guard var updated = profile, let profileManager else { return }
                updated.personaId = id
                profileManager.updateProfile(updated)
            }
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好的") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var cover: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Theme.accent, Theme.sidebarBg, Theme.branchIndicator.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(height: 154)
            .overlay {
                if let data = card?.coverImageData ?? profile?.coverImageData, let image = platformImage(data) {
                    GeometryReader { geometry in
                        image.resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                } else {
                    Text(String(name.prefix(1))).font(.system(size: 58, weight: .light, design: .serif)).foregroundColor(Theme.branchIndicator)
                }
            }
            .clipped()
            // 封面图 scaledToFill 后比 154 高（竖图 512×768 → 386×579），clipped 只裁画面不裁命中：
            // 溢出的上半截盖住了上面许可横幅的「启用 / 先不」。封面纯装饰，不接点按
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 25, weight: .bold)).foregroundColor(Theme.textPrimary)
                if isCurrent {
                    Text("当前楼层").font(.system(size: 10, weight: .medium)).foregroundColor(Theme.branchIndicator)
                        .padding(5).background(Theme.accent, in: Capsule()).fixedSize()
                }
            }
            Text(String(names.expand(card?.description ?? profile?.characterDescription ?? "").prefix(60)))
                .font(.system(size: 14)).foregroundColor(Theme.textSecondary).lineLimit(2)
            Button(action: newChat) {
                Text("＋ 新聊天").font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.mainBg)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Theme.branchIndicator, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).disabled(creatingChat || !isCurrent)
        }.padding(IOSCal.pad)
    }

    /// 「昨天」「3 天前」这种中文相对时间
    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func chatRow(_ conversation: Conversation) -> some View {
        Button { open(conversation) } label: {
            HStack(spacing: 12) {
                Image(systemName: viewModel?.selectedConversation?.id == conversation.id ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(viewModel?.selectedConversation?.id == conversation.id ? Theme.branchIndicator : Theme.textMuted)
                    .accessibilityLabel(viewModel?.selectedConversation?.id == conversation.id ? "当前打开" : "")
                Text(conversation.title).font(.system(size: 15, weight: .medium)).foregroundColor(Theme.textPrimary).lineLimit(2)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Self.relative(conversation.updateTime))
                    Text("\(conversation.nodeCount) 条")
                }.font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, IOSCal.pad).padding(.vertical, 12).frame(minHeight: 44)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .overlay(alignment: .bottom) { IOSHairline() }
    }

    private func accessories(_ card: CharacterCard) -> some View {
        VStack(spacing: 0) {
            Button { accessoriesExpanded.toggle() } label: {
                HStack {
                    Text("这张卡带了什么")
                    Spacer()
                    Image(systemName: accessoriesExpanded ? "chevron.up" : "chevron.down")
                }.font(.system(size: 12)).foregroundColor(Theme.textMuted)
                    .padding(.horizontal, IOSCal.pad).frame(minHeight: 44)
            }.buttonStyle(.plain)
            if accessoriesExpanded {
                accessoryRow("开场", meta: "\(card.greetings.count) 条候选")
                accessoryRow("世界书", meta: "\(card.worldBookEntryCount) 条")
                accessoryRow("正则", meta: "\(card.regexScripts.count) 条")
                // 第二批 B1（小样 03）：没在运行的东西分两行，替代第一批的「交互还不完整」
                if card.scriptCount > 0 {
                    infoRow("scripts", title: "后台脚本", value: "\(card.scriptCount) 个未运行",
                            explain: Text("卡里不挂在消息上、在后台一直跑的脚本，这一版不运行，消息里的网页不受影响。"))
                }
                let unsupported = unsupportedLabels
                if !unsupported.isEmpty {
                    infoRow("unsupported", title: "用到了还不支持的", value: unsupported.joined(separator: "、"), rose: true,
                            explain: Text("这张卡的网页会调用 ") + Text(unsupported.joined(separator: "、")).bold().foregroundColor(Theme.textPrimary)
                                + Text("，记忆花园暂不支持；用到它们的部分不会动，其余照常显示。"))
                }
            }
        }
    }

    private func accessoryRow(_ title: String, meta: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 4)
                Text(meta).foregroundColor(Theme.textMuted)
            }.font(.system(size: 13)).padding(.horizontal, IOSCal.pad).frame(minHeight: 44)
            IOSHairline()
        }
    }

    /// 小样 03 的说明行：右侧 ⓘ 点开就地展开一句；不支持的功能用玫瑰灰字，只标名字不标警告色块
    private func infoRow(_ id: String, title: String, value: String, rose: Bool = false, explain: Text) -> some View {
        let open = openInfo == id
        return VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { openInfo = open ? nil : id }
            } label: {
                HStack(spacing: 6) {
                    Text(title).foregroundColor(Theme.textPrimary).layoutPriority(1)
                    Spacer(minLength: 4)
                    Text(value).foregroundColor(rose ? Self.rose : Theme.textMuted).lineLimit(1)
                    Image(systemName: "info.circle").font(.system(size: 14))
                        .foregroundColor(open ? Theme.branchIndicator : Theme.textMuted)
                        .accessibilityLabel(open ? "收起说明" : "说明")
                }.font(.system(size: 13)).padding(.horizontal, IOSCal.pad).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open {
                explain.font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, IOSCal.pad).padding(.bottom, 8)
            }
            IOSHairline()
        }
    }

    /// 小样的玫瑰灰（--rose #a16f79）
    private static let rose = Color(red: 0xA1 / 255, green: 0x6F / 255, blue: 0x79 / 255)

    private func consentBanner(_ card: CharacterCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 纯前端卡（只有开场网页）也问许可（第二批 B1）
            let parts = [card.regexScripts.isEmpty ? nil : "\(card.regexScripts.count) 条正则",
                         card.scriptCount > 0 ? "\(card.scriptCount) 个脚本" : nil,
                         card.hasFrontendGreeting ? "开场网页" : nil].compactMap { $0 }
            Text("\(card.name)带了 \(parts.joined(separator: "、"))")
                .font(.system(size: 13, weight: .medium)).foregroundColor(Theme.textPrimary)
            if card.scriptCount > 0 {
                Text("后台脚本这一版不运行").font(.system(size: 11)).foregroundColor(Theme.textMuted)
            }
            HStack(spacing: 18) {
                Button("启用") { consent(.allowed) }.foregroundColor(Theme.branchIndicator)
                Button("先不") { consent(.deferred) }.foregroundColor(Theme.textMuted)
            }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).frame(minHeight: 44)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.mainBg.opacity(0.94), in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: Theme.textPrimary.opacity(0.12), radius: 12, y: 5)
        .padding(.horizontal, 10)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    /// 「我的身份」行右侧：楼层指定的身份名；没指定 = 楼层原本的身份；指定了但找不到要说出来
    private func personaLabel(_ profile: Profile) -> String {
        guard let id = profile.personaId, !id.isEmpty else { return "楼层原本的身份" }
        guard let persona = UserPersonaStore.shared.personas.first(where: { $0.id == id }) else { return "找不到了，用楼层原本的" }
        return persona.name.isEmpty ? "（没名字）" : persona.name
    }

    private func updateBanner() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { bannerVisible = needsConsent }
    }

    private func consent(_ value: CharacterCard.ExtensionConsent) {
        guard var card, let cardManager else { return }
        card.extensionConsent = value
        do { try cardManager.update(card); updateBanner() } catch { errorMessage = error.localizedDescription }
    }

    private func newChat() {
        guard !creatingChat, let cardManager, let profileManager, let presetManager, let profile else { return }
        creatingChat = true
        // 保持禁用到角色页离开，连点不会新建第二个聊天。
        do {
            let service = cardManager.floors(profileManager: profileManager, presetManager: presetManager)
            let conversation = try card.map { try service.newChat(card: $0) } ?? service.newChat(profile: profile)
            open(conversation)
        } catch { creatingChat = false; errorMessage = error.localizedDescription }
    }

    /// 卡库设置「点卡直接进最近的聊天」（⑥）：只续一次，最近 = lastOpenedAt 最新（没打开过的按更新时间）；
    /// 没有聊天就留在角色页。等一拍再开，让切楼层后的右栏先落地。
    private func resumeIfRequested() async {
        guard let home = navigator?.characterHome, home.autoResume, home.profileId == profileId else { return }
        navigator?.characterHome = RightPanelNavigator.CharacterHome(profileId: home.profileId, cardId: home.cardId)
        let latest = conversations.max { ($0.lastOpenedAt ?? $0.updateTime) < ($1.lastOpenedAt ?? $1.updateTime) }
        guard let latest else { return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        open(latest)
    }

    private func open(_ conversation: Conversation) {
        guard isCurrent, !conversation.isTrashed, let viewModel else { return }
        do {
            // 新聊天由独立写入 context 提交，交给聊天 VM 前重取当前 UI context 的对象。
            let conversationId = conversation.id
            let pid = profileId
            let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate {
                $0.id == conversationId && $0.profileId == pid && !$0.isTrashed
            })
            guard let selected = try modelContext.fetch(descriptor).first else {
                creatingChat = false
                errorMessage = "这个聊天已经不在了"
                return
            }
            viewModel.loadConversation(selected, context: modelContext)
            navigator?.characterHome = nil
            NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
        } catch { creatingChat = false; errorMessage = error.localizedDescription }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }
}
