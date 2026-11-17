#if os(iOS) && DEBUG
import SwiftUI

/// 人页「编辑 › 电脑文件夹」（docs/plan-folder-floor.md P1，只进 Debug 包）：这一层连哪台「文件夹模式」的电脑、用哪个账号。
/// 选法照「模型」那页。连上以后这一层的模型换成 CC 卡，新开的对话发给那台电脑上的 Claude Code。
struct PersonFolderPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var saveError: String?

    private var registry: CCHubRegistry { .shared }
    private var profile: Profile? { profileManager?.currentProfile }
    private var ccModelId: String { APIProvider.ccBridge.models[0].id }

    /// 人页那一行右边的字：没连 / 「电脑名 · 文件夹名」；连着的那台已经不在了 = 待绑定
    static func summary(for profile: Profile?, registry: CCHubRegistry = .shared) -> String {
        guard let hubId = profile?.folderHubId else { return "没连" }
        guard let hub = registry.hubs.first(where: { $0.id == hubId }) else { return "待绑定" }
        guard let path = registry.client(for: hubId)?.currentHubInfo?.folder?.path else { return hub.name }
        return "\(hub.name) · \((path as NSString).lastPathComponent)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header("连哪台")
                row(title: "不连", subtitle: nil, selected: profile?.folderHubId == nil, enabled: true) { unlink() }
                ForEach(registry.hubs) { hub in
                    hubRow(hub)
                }
                note("连上以后，这一层新开的对话都发给这台电脑上的 Claude Code，在这个文件夹里干活。「模型」会跟着换成 Claude Code。")
                note("这一层的对话不提取记忆、不自己醒来、不进同步和备份。")

                if let accounts = linkedAccounts, accounts.count > 1 {
                    header("账号")
                    ForEach(accounts) { account in
                        row(title: account.label, subtitle: nil, selected: account.id == pickedAccountId(accounts), enabled: true) {
                            pickAccount(account.id == accounts.first?.id ? nil : account.id)
                        }
                    }
                    note("这一层用哪个账号。已经开过的对话不跟着变。")
                }
            }
            .padding(.top, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBg)
        .navigationTitle("电脑文件夹")
        .navigationBarTitleDisplayMode(.inline)
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: 行

    @ViewBuilder
    private func hubRow(_ hub: CCHubRegistry.HubProfile) -> some View {
        let client = registry.client(for: hub.id)
        let choice = FolderFloor.choice(connected: client?.isConnected ?? false, hello: client?.currentHubInfo)
        let isLinked = profile?.folderHubId == hub.id
        switch choice {
        case .folder(let path):
            row(title: hub.name, subtitle: FolderFloor.displayPath(path), selected: isLinked, enabled: true) {
                link(hub.id, hello: client?.currentHubInfo)
            }
        case .notFolder:
            row(title: hub.name, subtitle: "这台连的不是文件夹", selected: isLinked, enabled: false) {}
        case .offline:
            row(title: hub.name, subtitle: "没连上", selected: isLinked, enabled: false) {}
        }
    }

    private func row(title: String, subtitle: String?, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(selected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, Theme.optionRowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || selected ? 1 : 0.5)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 26)
            .padding(.vertical, 6)
    }

    // MARK: 账号

    /// 连着的那台现在报的账号名单；没连 / 那台没连上 = nil（不显示这一组）
    private var linkedAccounts: [HubHello.Account]? {
        guard let hubId = profile?.folderHubId else { return nil }
        return registry.client(for: hubId)?.currentHubInfo?.folder?.accounts
    }

    private func pickedAccountId(_ accounts: [HubHello.Account]) -> String? {
        let stored = profile?.folderAccount
        return accounts.contains(where: { $0.id == stored }) ? stored : accounts.first?.id
    }

    // MARK: 存

    private func link(_ hubId: String, hello: HubHello?) {
        guard let p = profile else { return }
        let keepAccount = p.folderHubId == hubId ? p.folderAccount : nil
        save(FolderFloor.linked(p, hubId: hubId, hubIdentity: hello?.hubId ?? registry.identity(of: hubId), account: keepAccount, ccModelId: ccModelId))
    }

    private func unlink() {
        guard let p = profile, p.folderHubId != nil else { return }
        save(FolderFloor.unlinked(p, ccModelId: ccModelId))
    }

    private func pickAccount(_ account: String?) {
        guard var p = profile, p.folderHubId != nil else { return }
        p.folderAccount = account
        save(p)
    }

    private func save(_ profile: Profile) {
        guard let profileManager else { return }
        do { try profileManager.updateProfileChecked(profile) }
        catch { saveError = error.localizedDescription }
    }
}
#endif
