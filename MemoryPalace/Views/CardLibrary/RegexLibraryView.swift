import SwiftUI

/// 卡库第三页签「正则」（⑤b，小样 07）：按来源分组（全局 / 当前楼层预设 / 绑定卡或楼层旧规则），
/// 每条单独开关（写回规则自身 disabled），角色卡整组受许可控制；点行进 RegexRuleEditor。
struct RegexLibraryView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?

    @State private var scope: Scope = .all
    @State private var editing: EditingRule?
    @State private var errorMessage: String?

    private let globalStore = GlobalRegexStore.shared

    private enum Scope: String, CaseIterable {
        case all = "全部", global = "全局", preset = "预设", card = "角色卡"

        func includes(_ owner: RegexRuleOwner) -> Bool {
            switch (self, owner) {
            case (.all, _), (.global, .global), (.preset, .preset), (.card, .card), (.card, .profile): true
            default: false
            }
        }
    }

    private struct EditingRule: Identifiable {
        let owner: RegexRuleOwner
        let ownerLabel: String
        let rule: RegexScript
        let isNew: Bool
        var id: String { rule.id }
    }

    private var cards: CharacterCardManager? { cardManager ?? profileManager?.characterCardManager }

    private var groups: [RegexLibraryGroup] {
        guard let profile = profileManager?.currentProfile else { return [] }
        return RegexLibrary.groups(global: globalStore.scripts, profile: profile,
                                   preset: presetManager?.preset(byId: profile.presetId), cards: cards?.cards ?? [])
    }

    private var store: RegexOwnerStore? {
        guard let presetManager, let cards, let profileManager else { return nil }
        return RegexOwnerStore(global: globalStore, presets: presetManager, cards: cards, profiles: profileManager)
    }

    var body: some View {
        let visible = groups.filter { scope.includes($0.owner) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header.padding(.horizontal, 16)
                scopePicker.padding(.horizontal, 16)
                CalendarTicket {
                    if visible.isEmpty {
                        Text(scope == .preset ? "这个楼层没有预设" : "没有规则")
                            .font(.system(size: 14)).foregroundColor(Theme.textMuted).padding(IOSCal.pad)
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { TicketNotch() }
                        groupSection(group)
                    }
                    Color.clear.frame(height: 8)
                }
            }
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Theme.sidebarBg)
        .sheet(item: $editing) { item in
            RegexRuleEditor(
                rule: item.rule, ownerLabel: item.ownerLabel, isNew: item.isNew,
                names: profileManager.map { EffectiveCharacterContext(profile: $0.currentProfile) }
                    ?? EffectiveCharacterContext(charName: "", userName: ""),
                onSave: { rule in
                    guard let store else { throw RegexOwnerStore.Failure.ownerMissing }
                    try store.upsert(rule, in: item.owner)
                    editing = nil
                },
                onDelete: item.isNew ? nil : {
                    guard let store else { throw RegexOwnerStore.Failure.ownerMissing }
                    try store.delete(ruleId: item.rule.id, in: item.owner)
                    editing = nil
                },
                onCancel: { editing = nil })
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好的") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("正则").font(.system(size: 30, weight: .bold)).foregroundColor(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("改写显示、发送、输入的文字").font(.system(size: 13)).foregroundColor(Theme.textMuted)
            }
            Spacer(minLength: 8)
            Button {
                editing = EditingRule(owner: .global, ownerLabel: "来自全局", rule: RegexScript(), isNew: true)
            } label: {
                Image(systemName: "plus").font(.system(size: 21))
                    .foregroundColor(Theme.branchIndicator)
                    .frame(width: 44, height: 44)
                    .background(Theme.mainBg, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建全局规则")
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            ForEach(Scope.allCases, id: \.self) { value in
                let on = scope == value
                Button { scope = value } label: {
                    Text(value.rawValue)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundColor(on ? Theme.textPrimary : Theme.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.mainBg) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.textPrimary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func groupSection(_ group: RegexLibraryGroup) -> some View {
        let showsConsent = group.consent != nil && !group.rules.isEmpty
        HStack(spacing: 6) {
            Text(group.title).font(.system(size: 12)).tracking(0.5).foregroundColor(Theme.textMuted).lineLimit(1)
            Spacer(minLength: 6)
            if showsConsent && !group.cardAllowed {
                Text("还没启用").font(.system(size: 11, weight: .medium)).foregroundColor(Theme.danger)
            }
        }
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        if group.rules.isEmpty {
            Text(emptyText(group)).font(.system(size: 13)).foregroundColor(Theme.textMuted)
                .padding(.horizontal, IOSCal.pad).padding(.vertical, 10)
        }
        ForEach(group.rules) { rule in row(rule, in: group) }
        if showsConsent, case .card(let cardId) = group.owner {
            consentButton(allowed: group.consent == .allowed, cardId: cardId)
        }
    }

    private func emptyText(_ group: RegexLibraryGroup) -> String {
        switch group.owner {
        case .global: "还没有全局规则，点右上 ＋ 新建"
        case .preset: "这个预设没有正则"
        case .card: "这张卡没有正则"
        case .profile: "这个楼层没有正则"
        }
    }

    private func row(_ rule: RegexScript, in group: RegexLibraryGroup) -> some View {
        let name = rule.scriptName.isEmpty ? "未命名" : rule.scriptName
        let on = group.cardAllowed && !rule.disabled
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { edit(rule, in: group) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.system(size: 15))
                                .foregroundColor(on ? Theme.textPrimary : Theme.textMuted).lineLimit(1)
                            if RegexLibrary.hasUnsupportedPlacement(rule) {
                                Text("这个位置暂不支持").font(.system(size: 11)).foregroundColor(Theme.textMuted)
                            }
                        }
                        Spacer(minLength: 6)
                        phaseTags(rule)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑「\(name)」")
                Toggle("", isOn: Binding(get: { on }, set: { setEnabled($0, rule: rule, in: group) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.branchIndicator)
                    .disabled(!group.cardAllowed)
                    .accessibilityLabel("启用「\(name)」")
                Button { edit(rule, in: group) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, IOSCal.pad)
            IOSHairline()
        }
    }

    private func phaseTags(_ rule: RegexScript) -> some View {
        let phases = rule.phases
        let tags: [(RegexPhase, String)] = [(.display, "显示"), (.send, "发送"), (.input, "输入")]
        return HStack(spacing: 3) {
            ForEach(tags.filter { phases.contains($0.0) }, id: \.1) { _, label in
                Text(label).font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Theme.textPrimary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .fixedSize()
    }

    private func consentButton(allowed: Bool, cardId: String) -> some View {
        Button {
            perform { try $0.setConsent(allowed ? .deferred : .allowed, cardId: cardId) }
        } label: {
            Text(allowed ? "停用这张卡的正则" : "启用这张卡的正则")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(allowed ? Theme.textMuted : Theme.danger)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(allowed ? Theme.textPrimary.opacity(0.05) : Theme.danger.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, IOSCal.pad)
        .padding(.top, 10)
    }

    private func edit(_ rule: RegexScript, in group: RegexLibraryGroup) {
        let label = "来自" + ([group.sourceLabel] + (group.ownerName.map { [$0] } ?? [])).joined(separator: " · ")
        editing = EditingRule(owner: group.owner, ownerLabel: label, rule: rule, isNew: false)
    }

    private func setEnabled(_ enabled: Bool, rule: RegexScript, in group: RegexLibraryGroup) {
        perform { try $0.setEnabled(enabled, ruleId: rule.id, in: group.owner) }
    }

    private func perform(_ action: (RegexOwnerStore) throws -> Void) {
        guard let store else { return }
        do { try action(store) } catch { errorMessage = error.localizedDescription }
    }
}
