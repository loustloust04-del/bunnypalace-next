#if os(iOS)
import SwiftUI

/// 人页「权限」的真表（atrium P3⑤a §3.2）：这个人单独设的档位，没设的跟着「我 › 权限」里的默认。
/// 分节照「我 › 权限」；只全局的三项（工具总开关、遥控浏览器、记忆）不出现。
/// 人页里排在头部后、抽屉前；别的设置页的档位点进来推的也是这一份（`PersonPermissionsPage`）
struct PersonPermissionSections: View {
    let profileId: String
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var confirmReset = false
    @State private var voiceLevel: PermissionLevel?

    private var target: PermissionTarget { .floor(profileId) }
    private var readOnly: Bool { profileManager?.isReadOnly == true || profileId.isEmpty }

    var body: some View {
        Section {
            NavigationLink {
                HealthPermissionSubpage(target: target)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("健康")
                        .font(m.body)
                    Text("苹果健康、体重、用药、月经、亲密五个子域")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            #if PERSONAL_APPS
            PermissionDomainRow(domain: .trading, target: target)
            #endif
            PermissionDomainRow(domain: .images, target: target)
            PermissionDomainRow(domain: .fileLibrary, target: target)
            #if PERSONAL_APPS
            #if DEBUG
            PermissionDomainRow(domain: .topicBox, target: target)
            #endif
            #endif
        } header: {
            Text("AI 能看什么")
        }
        .listRowBackground(Theme.mainBg)
        .disabled(readOnly)

        Section {
            PermissionDomainRow(domain: .webSearch, target: target)
            PermissionDomainRow(domain: .voiceProactive, twoLevelsOnly: true, target: target)
                .onAppear { voiceLevel = PermissionCenter.level(.voiceProactive, profileId: profileId) }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
                    syncVoiceIfChanged()
                }
            PermissionDomainRow(domain: .calendar, target: target)
            PermissionDomainRow(domain: .reminders, target: target)
            PermissionDomainRow(domain: .clipboard, target: target)
            PermissionDomainRow(domain: .shell, target: target)   // 只能比默认严（下拉里只列更严的档）
            PermissionDomainRow(domain: .twitter, target: target)
        } header: {
            Text("AI 能做什么")
        }
        .listRowBackground(Theme.mainBg)
        .disabled(readOnly)

        Section {
            PermissionDomainRow(domain: .notifications, twoLevelsOnly: true, target: target)
        } header: {
            Text("AI 自主行为")
        } footer: {
            Text("「跟随默认」= 用「我 › 权限」里的那一档，改默认 TA 跟着变。工具总开关、遥控浏览器、记忆所有人共用，在「我」里改。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
        .disabled(readOnly)

        Section {
            Button("权限全部恢复跟随默认") { confirmReset = true }
                .font(m.body)
                .foregroundColor(Theme.textSecondary)
                .settingsActionButton()
                .confirmationDialog("这个人的权限全部恢复跟随默认？", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("恢复", role: .destructive) {
                        PermissionCenter.clearAll(profileId: profileId)
                        syncVoiceIfChanged()
                    }
                    Button("取消", role: .cancel) {}
                }
        } footer: {
            Text("删掉这个人单独设的档位，全部跟着「我 › 权限」走。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
        .disabled(readOnly)
    }

    /// 主动语音生效值变了 → 同步一次 CC 的语音块（语音设置页监听的是老键，听不到层上的改动，plan §3.2）。
    /// CC 块只写当前层的，人页也只开当前层
    private func syncVoiceIfChanged() {
        let now = PermissionCenter.level(.voiceProactive, profileId: profileId)
        guard now != voiceLevel else { return }
        voiceLevel = now
        guard let current = profileManager?.currentProfile, current.id == profileId else { return }
        VoiceMessageSettingsIOSSections.syncCCVoiceInstructions(current)
    }
}

/// 别的设置页的档位点进来：当前这个人的权限表（和人页「权限」是同一份，plan §6-2 不跨栈跳人页）
struct PersonPermissionsPage: View {
    let profileId: String
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    var body: some View {
        SettingsSectionList(.list) {
            PersonPermissionSections(profileId: profileId)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
        .navigationTitle("\(profileManager?.profiles.first { $0.id == profileId }?.name ?? "") 的权限")
    }
}
#endif
