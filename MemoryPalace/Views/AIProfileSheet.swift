import SwiftUI

/// 头像通用视图（顶栏胶囊/资料卡/通讯录共用）：
/// assistant = 自选头像 → 角色卡封面 → emoji → 占位圈；user = 自选头像 → 占位圈。
struct ProfileAvatarView: View {
    let profile: Profile?
    var owner: ProfileCardStore.Owner = .assistant
    var size: CGFloat = 32

    var body: some View {
        if let data = avatarData, let img = PlatformImage(data: data) {
            Image(platformImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else if owner == .assistant, let emoji = profile?.emoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: size * 0.5))
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.accent.opacity(0.6)))
        } else {
            AvatarBox(size: size)
        }
    }

    private var avatarData: Data? {
        guard let p = profile else { return nil }
        return owner == .assistant ? (p.assistantAvatarData ?? p.coverImageData) : p.userAvatarData
    }
}

/// 资料卡（点聊天页顶栏头像 / 通讯录条目弹出）。
/// 结构学角色卡界面（CharacterCardEditor）：NavigationStack + List(insetGrouped) + 原生 toolbar。
/// owner = .assistant：状态 + bio + 碎碎念；owner = .user：只有 bio（status/心声是 AI 的东西）。
/// 数据 onAppear 读文件（无观察，sheet 每次打开即最新）。
struct AIProfileSheet: View {
    var owner: ProfileCardStore.Owner = .assistant
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.dismiss) private var dismiss

    @State private var card = ProfileCardStore.Card()
    @State private var voices: [(time: Date, text: String)] = []
    @State private var isEditingBio = false
    @State private var bioDraft = ""

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    private var displayName: String {
        guard let p = profileManager?.currentProfile else { return owner == .assistant ? "助手" : "你" }
        return owner == .assistant ? p.assistantName : p.userName
    }

    var body: some View {
        NavigationStack {
            List {
                // 头部：大头像 + 名字 + 楼层 + 状态（透明行，不进卡片）
                Section {
                    VStack(spacing: 10) {
                        ProfileAvatarView(profile: profileManager?.currentProfile, owner: owner, size: 108)
                        Text(displayName)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        if let p = profileManager?.currentProfile {
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
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section("bio") {
                    if isEditingBio {
                        TextEditor(text: $bioDraft)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 80, maxHeight: 160)
                    } else {
                        Text(card.bio ?? emptyBioHint)
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(card.bio == nil ? Theme.textMuted : Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                if owner == .assistant {
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
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.plain)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle("资料卡")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if isEditingBio {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isEditingBio = false }
                            .foregroundColor(Theme.textMuted)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            ProfileCardStore.saveBio(bioDraft, profileId: profileId, owner: owner)
                            card = ProfileCardStore.load(profileId: profileId, owner: owner)
                            isEditingBio = false
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }
                } else {
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
        .onAppear { reload() }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
    }

    private var emptyBioHint: String {
        owner == .assistant ? "还没有 bio——点右上角编辑，或者让 TA 自己填" : "还没有 bio——点右上角编辑写一个"
    }

    // MARK: - Helpers

    private func reload() {
        card = ProfileCardStore.load(profileId: profileId, owner: owner)
        voices = owner == .assistant ? HeartvoiceFileStore.recentVoices(profileId: profileId, limit: 5) : []
    }

    /// 今天 → HH:mm；更早 → M/d HH:mm
    static func voiceTimeLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.defaultDigits).day()) + " " + date.formatted(date: .omitted, time: .shortened)
    }
}
