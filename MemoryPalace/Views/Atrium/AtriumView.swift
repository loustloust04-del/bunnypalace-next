#if os(iOS)
import SwiftUI

/// atrium（plan-atrium P1）：楼层之上的总页面。每行一个楼层，点了切过去、落回那层上次停的页 / 对话。
/// 挂在 App 根视图 `.id` 之外的 fullScreenCover 里，切层整树重建时它还在
struct AtriumView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(AtriumPresenter.self) private var presenter: AtriumPresenter?

    @State private var rows: [String: AtriumRow] = [:]
    /// 当前层还在回话时点了别人 / 要删当前层：先问一句
    @State private var interruptTarget: Profile?
    /// `interruptTarget` 是要删的（不是要切过去的）
    @State private var interruptForDelete = false
    /// 长按「编辑」：任意一层都能编
    @State private var editingProfile: Profile?
    /// 编辑页点了「导入聊天记录」的那一层（关页后切过去再弹导入）
    @State private var importAfterEdit: Profile?
    @State private var profileToDelete: Profile?
    @State private var showSettings = false
    @State private var showCreate = false
    /// 点「新建一个人」时的当前层：新建页关掉后对比，变了 = 建好并切过去了
    @State private var createdFrom = ""
    @State private var importAfterCreate = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("人")
                        .font(.system(size: Theme.F.secondary, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                    ForEach(profileManager?.profiles ?? []) { profile in
                        Button { select(profile) } label: { row(profile) }
                            .buttonStyle(.plain)
                            .contextMenu { rowMenu(profile) }
                    }
                }
                .padding(.top, 8)
            }
        }
        .background(Theme.sidebarBg.ignoresSafeArea())
        .task(id: profileManager?.profiles.map(\.id)) {
            guard let pm = profileManager else { return }
            rows = await AtriumRowLoader.load(profileIds: pm.profiles.map(\.id), container: pm.container)
        }
        .confirmationDialog(interruptTitle, isPresented: Binding(get: { interruptTarget != nil }, set: { if !$0 { interruptTarget = nil } }),
                            titleVisibility: .visible, presenting: interruptTarget) { target in
            if interruptForDelete {
                // 两个确认框接力：等这个收干净再弹删除确认（同 ProfileSwitcher.handlePendingImport 的 0.4s）
                Button("继续删除", role: .destructive) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { profileToDelete = target }
                }
            } else {
                Button("切过去", role: .destructive) { switchTo(target) }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showSettings) {
            MySettingsRootView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
        // 从这里的「我」进设置再点「换人」：已经在 atrium 了，收设置就行
        .modifier(OnNotify(.atriumRequestedFromSettings) { showSettings = false })
        .sheet(isPresented: $showCreate, onDismiss: afterCreate) {
            if let pm = profileManager {
                ProfileEditorSheet(profileManager: pm, mode: .create, onRequestImport: { _ in importAfterCreate = true })
            }
        }
        .sheet(item: $editingProfile, onDismiss: afterEdit) { profile in
            if let pm = profileManager {
                ProfileEditorSheet(profileManager: pm, mode: .edit(profile), onRequestImport: { importAfterEdit = $0 })
            }
        }
        .profileDeleteConfirmation($profileToDelete, profileManager: profileManager)
    }

    /// 新建保存时 `publish(activate: true)` 已经切到新层（底下整树重建、落 page1 新草稿）：atrium 跟着收；取消新建则留在这
    private func afterCreate() {
        let wantsImport = importAfterCreate
        importAfterCreate = false
        guard let pm = profileManager, pm.currentProfile.id != createdFrom else { return }
        presenter?.dismiss(then: wantsImport ? { NotificationCenter.default.post(name: .memoryPalaceRequestImport, object: nil) } : nil)
    }

    /// 编辑页「导入聊天记录」：照新建——那一层不是当前层就切过去，收 atrium 再弹导入
    private func afterEdit() {
        guard let target = importAfterEdit, let pm = profileManager else { return }
        importAfterEdit = nil
        let post = { NotificationCenter.default.post(name: .memoryPalaceRequestImport, object: nil) }
        if target.id != pm.currentProfile.id {
            LastLocationResume.pendingProfileSwitch = target.id
            pm.switchTo(target)
        }
        presenter?.dismiss(then: post)
    }

    // MARK: 顶栏：我 / 字标 / ＋（样式同 page0 顶栏的玻璃圆钮）

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showSettings = true } label: {
                Text("我")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("atrium-me")

            Spacer()

            Image("MnemeWordmark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 24)
                .foregroundColor(Theme.textPrimary)
                .accessibilityLabel("mneme atrium")

            Spacer()

            // 「搜索所有人」P1 不做（没有跨层搜索）
            Menu {
                Button {
                    createdFrom = profileManager?.currentProfile.id ?? ""
                    showCreate = true
                } label: {
                    Label("新建一个人", systemImage: "person.badge.plus")
                }
                Button {
                    presenter?.dismiss { NotificationCenter.default.post(name: .memoryPalaceRequestImport, object: nil) }
                } label: {
                    Label("导入聊天记录", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("atrium-plus")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    // MARK: 人区

    private func row(_ profile: Profile) -> some View {
        let info = rows[profile.id]
        let isCurrent = profile.id == profileManager?.currentProfile.id
        return HStack(spacing: 12) {
            ProfileAvatarView(profile: profile, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if let status = info?.status {
                        Text(status)
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if let at = info?.updatedAt {
                        Text(ConversationRow.smartDate(at))
                            .font(.system(size: Theme.F.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                            .fixedSize()
                    }
                }
                HStack(spacing: 6) {
                    Text(info?.lastLine ?? "")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if let unread = info?.unread, unread > 0 {
                        Text(Page0LocalState.unreadLabel(unread))
                            .font(.system(size: Theme.F.badge, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 18, minHeight: 16)
                            .background(Capsule().fill(ConversationRow.unreadTint))
                            .fixedSize()
                    }
                }
                .frame(height: 17)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(isCurrent ? Theme.accent.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
    }

    // MARK: 长按：编辑 / 删除

    @ViewBuilder
    private func rowMenu(_ profile: Profile) -> some View {
        Button { editingProfile = profile } label: {
            Label("编辑", systemImage: "pencil")
        }
        // 至少留一层（同 ProfileManager.deleteProfile / ProfileSwitcher）
        if (profileManager?.profiles.count ?? 0) > 1 {
            Button(role: .destructive) { requestDelete(profile) } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 删当前层会切到第一层 = 打断正在回的话：先弹 P1 那句「还在回话」，确认了再进删除确认
    private func requestDelete(_ profile: Profile) {
        if profile.id == profileManager?.currentProfile.id, ProfileTurnActivity.shared.generatingProfileId != nil {
            interruptForDelete = true
            interruptTarget = profile
            return
        }
        profileToDelete = profile
    }

    // MARK: 切人

    private var interruptTitle: String {
        let busy = ProfileTurnActivity.shared.generatingProfileId
        let name = profileManager?.profiles.first { $0.id == busy }?.name ?? ""
        return "\(name) 还在回话，切走会打断"
    }

    private func select(_ profile: Profile) {
        guard let pm = profileManager, profile.id != pm.currentProfile.id else {
            presenter?.dismiss()
            return
        }
        if let busy = ProfileTurnActivity.shared.generatingProfileId, busy != profile.id {
            interruptForDelete = false
            interruptTarget = profile
            return
        }
        switchTo(profile)
    }

    private func switchTo(_ profile: Profile) {
        LastLocationResume.pendingProfileSwitch = profile.id
        profileManager?.switchTo(profile)
        presenter?.dismiss()
    }
}
#endif
