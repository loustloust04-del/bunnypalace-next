import SwiftUI
import SwiftData

// MARK: - 正则脚本设置页

/// 一份 body 两端共用（plan-settings-merge-x 刀 3）：容器走 `SettingsSectionList(.list)`；
/// mac 没有 toolbar 也没有左滑手势，页顶「新建」与行内「编辑 / 删除」是第 1 / 7 类例外。
/// 删除走 D2 确认合同：两个入口共用一个 pending（存楼层 ID + `RegexScript.id`），确认分支才写。
struct RegexPage: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m

    @State private var editingRegex: RegexScript?
    @State private var isAddingRegex = false
    @State private var regexRefreshId = UUID()
    @State private var pendingDelete: PendingRegexDelete?

    /// 确认期间只记 ID：确认时按楼层 ID 读最新 profile、在最新数组里按脚本 ID 重找 index（列表顺序变了也删对对象）
    private struct PendingRegexDelete {
        let profileId: String
        let scriptId: String
    }

    var body: some View {
        let scripts = profileManager?.currentProfile.regexScripts ?? []

        SettingsSectionList(.list) {
            // ⑤b：楼层绑定卡后执行链用卡规则、不叠加这里的楼层规则，提示去卡库正则页改
            if let profile = profileManager?.currentProfile,
               RegexLibrary.boundCard(profile: profile, cards: profileManager?.characterCardManager?.cards ?? []) != nil {
                Section {
                    Text("这个楼层绑定了角色卡时，生效的是卡里的正则，去卡库 → 正则里改")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Theme.mainBg)
            }

            #if os(macOS)
            // 只有 header 的 Section 不画空卡（`MacSettingsForm` 的 `section.content.isEmpty` 分支）
            Section {
                EmptyView()
            } header: {
                HStack {
                    Text("正则脚本")
                    Spacer()
                    Button {
                        isAddingRegex = true
                        editingRegex = RegexScript()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(ShellStyle.secondaryFont)
                            Text("新建")
                                .font(ShellStyle.secondaryFont)
                        }
                        .foregroundColor(Theme.branchIndicator)
                    }
                    .buttonStyle(MacSettingsButton())
                }
            }
            #endif

            if scripts.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "textformat.abc")
                            .font(.system(size: 24))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                        Text("没有正则脚本")
                            .font(m.body)
                            .foregroundColor(Theme.textMuted)
                        Text("导入助手模板时会自动导入，也可手动新建")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            } else {
                Section("脚本列表") {
                    ForEach(Array(scripts.enumerated()), id: \.element.id) { index, script in
                        #if os(macOS)
                        // mac 没有 swipeActions（`MacSettingsForm` 是 ScrollView + VStack），编辑 / 删除给行内钮
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { !script.disabled },
                                set: { enabled in
                                    var s = profileManager?.currentProfile.regexScripts ?? []
                                    guard index < s.count else { return }
                                    s[index].disabled = !enabled
                                    profileManager?.currentProfile.regexScripts = s
                                    if let profile = profileManager?.currentProfile {
                                        profileManager?.updateProfile(profile)
                                    }
                                    regexRefreshId = UUID()
                                }
                            ))
                            .toggleStyle(.switch)
                            .scaleEffect(0.6)
                            .frame(width: 30)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(script.scriptName.isEmpty ? "未命名" : script.scriptName)
                                    .font(m.rowTitle)
                                    .foregroundColor(script.disabled ? Theme.textMuted : Theme.textPrimary)

                                HStack(spacing: 4) {
                                    if script.markdownOnly {
                                        Text("渲染")
                                            .font(ShellStyle.microFont)
                                            .foregroundColor(Theme.branchIndicator)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                                    }
                                    if script.promptOnly {
                                        Text("API")
                                            .font(ShellStyle.microFont)
                                            .foregroundColor(Theme.branchIndicator)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                                    }
                                }
                                // mac 独有一行（并集裁决：placement 文本不并到 iOS，mac 保留 J2 原样）
                                Text("placement: \(script.placement.map(String.init).joined(separator: ","))")
                                    .font(m.secondary)
                                    .foregroundColor(Theme.textMuted)
                            }

                            Spacer()

                            Button {
                                isAddingRegex = false
                                editingRegex = script
                            } label: {
                                Image(systemName: "pencil")
                                    .font(m.secondary)
                                    .foregroundColor(Theme.textMuted)
                            }
                            .buttonStyle(.plain)

                            Button {
                                askDelete(script)
                            } label: {
                                Image(systemName: "trash")
                                    .font(m.secondary)
                                    .foregroundColor(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        #else
                        Button {
                            isAddingRegex = false
                            editingRegex = script
                        } label: {
                            HStack(spacing: 10) {
                                // Toggle
                                Toggle("", isOn: Binding(
                                    get: { !script.disabled },
                                    set: { enabled in
                                        var s = profileManager?.currentProfile.regexScripts ?? []
                                        guard index < s.count else { return }
                                        s[index].disabled = !enabled
                                        profileManager?.currentProfile.regexScripts = s
                                        if let profile = profileManager?.currentProfile {
                                            profileManager?.updateProfile(profile)
                                        }
                                        regexRefreshId = UUID()
                                    }
                                ))
                                .toggleStyle(.switch)
                                .scaleEffect(0.65)
                                .frame(width: 40)
                                .highPriorityGesture(TapGesture())

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(script.scriptName.isEmpty ? "未命名" : script.scriptName)
                                        .font(.system(size: Theme.F.body, weight: .medium))
                                        .foregroundColor(script.disabled ? Theme.textMuted : Theme.textPrimary)

                                    HStack(spacing: 4) {
                                        if script.markdownOnly {
                                            Text("渲染")
                                                .font(.system(size: Theme.F.badge, weight: .semibold))
                                                .foregroundColor(Theme.branchIndicator)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                                        }
                                        if script.promptOnly {
                                            Text("API")
                                                .font(.system(size: Theme.F.badge, weight: .semibold))
                                                .foregroundColor(Theme.branchIndicator)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))
                                        }
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                askDelete(script)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                isAddingRegex = false
                                editingRegex = script
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(Theme.branchIndicator)
                        }
                        #endif
                    }
                }
                .listRowBackground(Theme.mainBg)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        #endif
        #if os(iOS)
        .navigationTitle("正则脚本")   // mac：设置窗标题由宿主 MacSettingsPage 给（同 Prompt 页口径）；右栏里不带——会被提升成窗口标题（面 4.3）
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingRegex = true
                    editingRegex = RegexScript()
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        #endif
        .sheet(item: $editingRegex) { script in
            RegexScriptEditor(
                script: script,
                isNew: isAddingRegex,
                onSave: { updated in
                    saveRegexScript(updated)
                    editingRegex = nil
                    regexRefreshId = UUID()
                },
                onCancel: { editingRegex = nil }
            )
        }
        .confirmationDialog(
            "删除脚本？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        .id(regexRefreshId)
    }

    private func askDelete(_ script: RegexScript) {
        guard let profileId = profileManager?.currentProfile.id else { return }
        pendingDelete = PendingRegexDelete(profileId: profileId, scriptId: script.id)
    }

    /// 确认分支才写：按 pending 的楼层 ID 取最新 profile（不切楼层），在最新数组里按脚本 ID 找 index；对象没了就不写
    private func confirmDelete() {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil
        guard var profile = profileManager?.profiles.first(where: { $0.id == pending.profileId }) else { return }
        guard let idx = profile.regexScripts.firstIndex(where: { $0.id == pending.scriptId }) else { return }
        profile.regexScripts.remove(at: idx)
        profileManager?.updateProfile(profile)
        regexRefreshId = UUID()
    }

    private func saveRegexScript(_ script: RegexScript) {
        guard var profile = profileManager?.currentProfile else { return }
        var scripts = profile.regexScripts
        if isAddingRegex {
            scripts.append(script)
        } else if let idx = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[idx] = script
        }
        profile.regexScripts = scripts
        profileManager?.updateProfile(profile)
    }
}
