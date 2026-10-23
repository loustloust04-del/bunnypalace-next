import SwiftUI

/// 卡库第四页签「设置」（⑥，小样 08）：用卡 / 前端卡（含卡的授权）/ 世界书注入上限 / 酒馆整包（⑧c）/ 楼层。
/// 偏好全是 CardLibraryPreferences 里的 UserDefaults key，这里 @AppStorage 直接读写。
struct CardLibrarySettingsView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @AppStorage(CardLibraryPreferences.autoResumeKey) private var autoResume = false
    @AppStorage(CardLibraryPreferences.allowWebScriptsKey) private var allowWebScripts = false
    @AppStorage(CardLibraryPreferences.worldBookMaxEntriesKey) private var maxEntries = 0
    @AppStorage(CardLibraryPreferences.worldBookTokenBudgetKey) private var tokenBudget = 0
    @State private var showFloorSwitcher = false
    @State private var errorMessage: String?
    @State private var importBusyText: String?

    private var cards: CharacterCardManager? { cardManager ?? profileManager?.characterCardManager }

    /// 带正则 / 脚本 / 开场网页（纯前端卡，第二批 B1）的卡（归档的不列）
    private var extensionCards: [CharacterCard] {
        (cards?.cards ?? []).filter { $0.archivedAt == nil && $0.needsExtensionConsent }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置").font(.system(size: 30, weight: .bold)).foregroundColor(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("按自己的习惯用卡").font(.system(size: 13)).foregroundColor(Theme.textMuted)
                }
                .padding(.horizontal, 16)
                CalendarTicket {
                    IOSSubLabel(text: "用卡")
                    toggleRow("点卡直接进最近的聊天", isOn: $autoResume)
                    note("关闭时先进入角色页，自己选一个聊天；打开后没有聊天也还是进角色页。")
                    TicketNotch()
                    IOSSubLabel(text: "前端卡")
                    toggleRow("允许卡里的网页运行脚本", isOn: $allowWebScripts)
                    note("交互还不完整，只支持显示和点击")
                    IOSSubLabel(text: "卡的授权")
                    if extensionCards.isEmpty {
                        note("没有带正则、脚本或网页的卡")
                    }
                    ForEach(extensionCards) { card in
                        consentRow(card)
                        sendConsentRow(card)
                    }
                    note("每张卡的正则 / 脚本要单独启用；卡里的规则或脚本被替换后会重新问你。")
                    TicketNotch()
                    IOSSubLabel(text: "世界书")
                    limitRow("每次最多注入", value: $maxEntries, unit: "条")
                    limitRow("token 预算", value: $tokenBudget, unit: "tok")
                    note("两个都生效：先按注入顺序取前面的条数，再按 token 预算放，放不下的那条跳过。留空或 0 = 不限。")
                    TicketNotch()
                    IOSSubLabel(text: "酒馆整包")
                    SillyTavernImportSettingsSection(busyText: $importBusyText)
                    TicketNotch()
                    IOSSubLabel(text: "楼层")
                    floorSection
                    Color.clear.frame(height: 12)
                }
            }
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.sidebarBg)
        .overlay { if let importBusyText { SillyTavernBusyOverlay(text: importBusyText) } }
        #if os(macOS)
        .sheet(isPresented: $showFloorSwitcher) {
            VStack(alignment: .leading, spacing: 16) {
                if let profileManager { ProfileSwitcher(profileManager: profileManager) }
                Button("完成") { showFloorSwitcher = false }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24)
            .frame(minWidth: 520)
            .background(Theme.mainBg)
        }
        #endif
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好的") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private var floorSection: some View {
        #if os(iOS)
        if let profileManager {
            ProfileSwitcher(profileManager: profileManager)
                .padding(.horizontal, IOSCal.pad)
                .padding(.vertical, 8)
        }
        #else
        IOSCalendarRow(icon: "building.2", title: "切楼层", meta: profileManager?.currentProfile.name) { showFloorSwitcher = true }
        #endif
    }

    private func consentRow(_ card: CharacterCard) -> some View {
        let allowed = card.extensionConsent == .allowed
        let status: String = switch card.extensionConsent {
        case .allowed: "已启用"
        case .deferred: "先不"
        case .unknown: "还没决定"
        }
        let parts = [card.regexScripts.isEmpty ? nil : "\(card.regexScripts.count) 条正则",
                     card.scriptCount > 0 ? "\(card.scriptCount) 个脚本" : nil,
                     card.hasFrontendGreeting ? "开场网页" : nil].compactMap { $0 }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name.isEmpty ? "未命名" : card.name).font(.system(size: 16)).foregroundColor(Theme.textPrimary).lineLimit(1)
                    Text((parts + [status]).joined(separator: " · ")).font(.system(size: 11))
                        .foregroundColor(allowed ? Theme.branchIndicator : Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { allowed }, set: { setConsent($0 ? .allowed : .deferred, card: card) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.branchIndicator)
                    .accessibilityLabel("启用「\(card.name)」的正则和脚本")
            }
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 52)
            IOSHairline()
        }
    }

    /// 第二批 B5：卡里网页的按钮要替你发消息时——问我 / 直接发 / 只填输入框（= sendConsent unknown / allowed / denied）
    private func sendConsentRow(_ card: CharacterCard) -> some View {
        let options: [(CardSendConsent, String)] = [(.unknown, "问我"), (.allowed, "直接发"), (.denied, "只填输入框")]
        let current = options.first { $0.0 == card.sendConsent }?.1 ?? "问我"
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("替你发消息").font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                Spacer(minLength: 8)
                Menu {
                    ForEach(options, id: \.0) { option in
                        Button {
                            setSendConsent(option.0, card: card)
                        } label: {
                            if option.0 == card.sendConsent { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(current).font(.system(size: 14))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(Theme.branchIndicator)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("「\(card.name)」替你发消息：\(current)")
            }
            .padding(.leading, IOSCal.pad + 12)
            .padding(.trailing, IOSCal.pad)
            .frame(minHeight: 40)
            IOSHairline()
        }
    }

    private func setSendConsent(_ consent: CardSendConsent, card: CharacterCard) {
        guard let cards, var latest = cards.cards.first(where: { $0.id == card.id }) else { return }
        latest.sendConsent = consent
        do { try cards.update(latest) } catch { errorMessage = error.localizedDescription }
    }

    private func limitRow(_ title: String, value: Binding<Int>, unit: String) -> some View {
        let text = Binding<String>(
            get: { value.wrappedValue > 0 ? String(value.wrappedValue) : "" },
            set: { value.wrappedValue = Int($0.filter(\.isNumber)) ?? 0 })
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 16)).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                TextField("不限", text: text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15))
                    .frame(width: 72, height: 32)
                    .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .accessibilityLabel(title)
                Text(unit).font(.system(size: 15)).foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 44)
            IOSHairline()
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.branchIndicator)
                    .accessibilityLabel(title)
            }
            .padding(.horizontal, IOSCal.pad)
            .frame(minHeight: 44)
            IOSHairline()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, IOSCal.pad)
            .padding(.top, 6)
    }

    private func setConsent(_ consent: CharacterCard.ExtensionConsent, card: CharacterCard) {
        guard let cards, var latest = cards.cards.first(where: { $0.id == card.id }) else { return }
        latest.extensionConsent = consent
        do { try cards.update(latest) } catch { errorMessage = error.localizedDescription }
    }
}
