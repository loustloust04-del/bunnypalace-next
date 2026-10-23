import SwiftUI
import SwiftData

// MARK: - 通用页（两端一份 body）

/// 设置 · 通用：楼层切换 + 气泡标签（名字 / 头像 / 风格标记）。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`。
/// `dismiss()` 两端语义不同（mac 关整个设置窗 / iOS pop 回根列表）是合流前就有的现状，本刀不改（第 3 类）。
struct GeneralPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m

    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage("showStyleChip") private var showStyleChip = true
    @State private var editingUserName = ""
    @State private var editingAssistantName = ""

    var body: some View {
        SettingsSectionList(.list) {
            Section("楼层") {
                if let pm = profileManager {
                    ProfileSwitcher(profileManager: pm)
                }
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                VStack(spacing: 8) {
                    SettingsTextField(label: "我的名字", placeholder: "你", text: $editingUserName)
                    SettingsTextField(label: "AI 的名字", placeholder: "助手", text: $editingAssistantName)
                }

                AvatarSettingsRows()

                HStack {
                    Text("显示在每条消息气泡上方的名称标签")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                    Button(action: {
                        let newUser = editingUserName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let newAssistant = editingAssistantName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !newUser.isEmpty { userName = newUser }
                        if !newAssistant.isEmpty { assistantName = newAssistant }
                        dismiss()
                    }) {
                        Text("确认")
                            .font(m.secondary.weight(.medium))
                            .settingsCapsuleLabel(filled: true, hPadding: 16)
                    }
                    .settingsActionButton()
                }

                // G1：mac 独有的「显示风格标记」并进两端，key 与默认值不变
                Toggle("显示风格标记", isOn: $showStyleChip)
                    .tint(Theme.branchIndicator)
            } header: {
                Text("气泡标签")
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            editingUserName = userName
            editingAssistantName = assistantName
        }
    }
}

/// 世界书绑定页（两端一份 body）：iOS 挂 Prompt 页底部「相关」入口，mac 是侧栏「AI 与对话」组里的一级 tab（A2）。
struct WorldBookPage: View {
    var body: some View {
        SettingsSectionList(.list) {
            Section("世界书") {
                GeneralWorldBookBindingSection()
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("世界书")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct GeneralWorldBookBindingSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    /// P0-4：✕ 实为删除整本书，必须过确认弹窗
    @State private var wbPendingDelete: WorldBook? = nil

    var body: some View {
        let profileId = profileManager?.currentProfile.id ?? ""
        let wbDescriptor = FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == profileId })
        let floorBooks = (try? modelContext.fetch(wbDescriptor)) ?? []

        if floorBooks.isEmpty {
            Text("当前楼层没有绑定的世界书")
                .font(m.body)
                .foregroundColor(Theme.textMuted)
        } else {
            ForEach(floorBooks, id: \.id) { book in
                HStack(spacing: 8) {
                    Image(systemName: book.scopeConversationId != nil ? "bubble.left" : "book.closed.fill")
                        .font(m.secondary)
                        .foregroundColor(Theme.branchIndicator)
                    Text(book.name)
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)

                    Text(book.scopeConversationId != nil ? "对话" : "楼层")
                        .font(m.caption.weight(.medium))   // 徽章：iOS badge 11 = caption 11 不变；mac 10（无 badge 档，不开新档）
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.branchIndicator.opacity(0.1)))

                    Text("\(book.entries.count) 条")
                        .font(m.secondary)
                        .foregroundColor(Theme.textMuted)

                    Spacer()

                    Button {
                        wbPendingDelete = book
                    } label: {
                        Image(systemName: "xmark")
                            .font(m.secondary.weight(.medium))
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.accent.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        Text("在右栏「世界书」tab 里可以新建、导入、编辑世界书")
            .font(m.caption)
            .foregroundColor(Theme.textMuted.opacity(0.6))
            .confirmationDialog(
                "删除世界书",
                isPresented: Binding(
                    get: { wbPendingDelete != nil },
                    set: { if !$0 { wbPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let book = wbPendingDelete { deleteWorldBook(book) }
                    wbPendingDelete = nil
                }
                Button("取消", role: .cancel) { wbPendingDelete = nil }
            } message: {
                if let book = wbPendingDelete {
                    Text("确定要删除「\(book.name)」吗？包含 \(book.entries.count) 个条目，不可恢复。")
                }
            }
    }

    private func deleteWorldBook(_ book: WorldBook) {
        modelContext.delete(book)
        if var profile = profileManager?.currentProfile {
            profile.linkedWorldBookIDs.removeAll { $0 == book.id.uuidString }
            profileManager?.updateProfile(profile)
        }
        do {
            try modelContext.save()
        } catch {
            print("[worldbook] 删除保存失败: \(error)")
        }
    }
}

// MARK: - 朗读 / 语音页（两端一份 body）

/// 设置 · 朗读（mac 侧栏叫「朗读」，iOS 页名叫「语音」——F6：叫法不动）。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
/// 只剩滑块壳一处分支（mac 的 `MacSettingsSlider` 自带 step 吸附，第 5 类）。
struct TTSPage: View {
    @Environment(\.settingsMetrics) private var m
    @AppStorage("ttsEnabled") private var ttsEnabled = true
    @AppStorage("ttsRate") private var ttsRate = 0.48
    @State private var pageExit = SettingsPageExit()

    var body: some View {
        ScrollViewReader { proxy in
            SettingsSectionList(.list) {
                Section {
                    SettingsNavRow(.voiceServices) {
                        VoiceServicesPage()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("语音服务")
                            Text("添加语音厂商和 key，试听效果")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
                Section {
                    Toggle("启用系统朗读", isOn: $ttsEnabled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("语速：\(ttsRate, specifier: "%.2f")")
                            .font(m.secondary)
                            .foregroundColor(Theme.textMuted)
                        #if os(macOS)
                        MacSettingsSlider(value: $ttsRate, in: 0.35...0.65, step: 0.01)
                        #else
                        Slider(value: $ttsRate, in: 0.35...0.65, step: 0.01)
                        #endif
                    }
                }
                Section {
                    Text("在助手消息长按菜单里选择「朗读」或「停止朗读」。切换对话自动停止。")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }

                VoiceMessageSettingsIOSSections()
            }
            // 整页消失才算离开（滚动不触发）：声纹录音等在这里收尾
            .onDisappear { pageExit.fire() }
            .environment(\.settingsPageExit, pageExit)
            .settingsAnchorScroll(proxy)
            #if os(iOS)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle("语音")
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
// MARK: - 附件页（两端一份 body）

/// 设置 · 附件：图片发送档位 + 每次携带张数 + 图片转述。
///
/// 一份 body 两端共用（plan-settings-merge-x 刀 3）。B1：两端都取 iOS 的 `PermissionLevelPicker(.images)`
/// ——mac 原来那个 `sendImagesToModel` Toggle 只写 legacy key，真闸读 `perm.images`，开关是失效的。
struct AttachmentPage: View {
    @Environment(\.settingsMetrics) private var m
    @AppStorage("sendImagesToModel") private var sendImagesToModel = true
    @AppStorage("imageTranscriptionEnabled") private var imageTranscriptionEnabled = true
    @AppStorage("maxImagesToModel") private var maxImagesToModel = 20

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                HStack {
                    Text("发送图片给模型")
                    Spacer(minLength: 8)
                    PermissionLevelPicker(domain: .images)
                }
            }
            if sendImagesToModel {
                Section {
                    ParameterRow(
                        label: "每次携带图片数",
                        value: Binding(
                            get: { Double(maxImagesToModel) },
                            set: { maxImagesToModel = Int($0) }
                        ),
                        range: 1...999,
                        step: 1,
                        intMode: true
                    )
                } header: {
                    Text("上下文图片")
                }
            }
            Section {
                Text("每次发消息时，从最近的对话往前数，携带这么多张图片给模型。更早的图片仍在气泡中显示，但不会发送。同时受上下文深度约束——被截断的消息里的图片也不发。")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
            Section {
                Toggle("图片转述省 token", isOn: $imageTranscriptionEnabled)
                Text("3 条消息之前的旧图自动换成 80 字文字描述（后台用主模型生成一次，永久复用），不再每轮重发原图。原图仍保留在气泡里。")
                    .font(.caption)
                    .foregroundColor(Theme.textMuted)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("附件")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
