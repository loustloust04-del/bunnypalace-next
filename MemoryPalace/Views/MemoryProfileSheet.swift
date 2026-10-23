import SwiftUI
import SwiftData

// MARK: - 画像弹层（#067 第 4 步）：全文 / 编辑 / 重写画像 / 删除画像
// 记忆 app 首屏画像卡、设置页「整理」组的画像行都开它。

struct MemoryProfileSheet: View {
    let profileId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m

    @State private var dream: UserProfileDream? = nil
    @State private var modifiedAt: Date? = nil
    @State private var loaded = false
    @State private var rewriting = false
    @State private var status = ""
    @State private var editing: ProfileEditingContext? = nil
    /// 点「删除画像」只置 pending（连楼层 ID 一起冻结），确认分支才按那个 ID 真删
    @State private var pendingDeleteId: String? = nil

    private var assistantName: String {
        let n = profileManager?.profiles.first { $0.id == profileId }?.assistantName ?? ""
        return n.isEmpty ? "助手" : n
    }

    var body: some View {
        NavigationStack {
            List {
                if let d = dream {
                    Section {
                        Text(d.text)
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                            .textSelection(.enabled)
                    } footer: {
                        Text("\(MemoryDateText.short(d.updatedAt))更新 · \(d.text.count) 字")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .panelRowBackground()
                } else if loaded {
                    Section {
                        Text("还没有画像。聊几天后\(assistantName)会自己写一份")
                            .font(m.body)
                            .foregroundColor(Theme.textMuted)
                    }
                    .panelRowBackground()
                }

                Section {
                    if let d = dream {
                        actionRow("编辑", systemImage: "pencil") {
                            editing = ProfileEditingContext(text: d.text, modifiedAt: modifiedAt)
                        }
                    }
                    actionRow(dream == nil ? "写一份画像" : "重写画像", systemImage: "arrow.clockwise") {
                        rewrite()
                    }
                    .disabled(rewriting || !loaded)
                    if rewriting || !status.isEmpty {
                        HStack(spacing: 6) {
                            if rewriting { ProgressView().controlSize(.small) }
                            Text(rewriting ? "正在重写画像…" : status)
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                    SettingsNavRow(.dreamPrompt) {
                        PromptEditorPage.dream
                    } label: {
                        Label("编辑生成提示词", systemImage: "wand.and.stars")
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                    }
                } footer: {
                    Text("重写画像只改这份画像，不会删掉任何记忆")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .panelRowBackground()

                if dream != nil {
                    Section {
                        Button(role: .destructive) {
                            pendingDeleteId = profileId
                        } label: {
                            Label("删除画像", systemImage: "trash")
                                .font(m.body)
                                .foregroundColor(Theme.danger)
                        }
                        .buttonStyle(.plain)
                    }
                    .panelRowBackground()
                }
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .toolPageBackground()
            .tint(Theme.branchIndicator)
            .panelSheetTitle("\(assistantName)眼里的你")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            // 居中 alert：confirmationDialog 挂在整个 List 上，iOS 26 会锚过去弹成 popover
            .alert("删除画像？", isPresented: Binding(
                get: { pendingDeleteId != nil },
                set: { if !$0 { pendingDeleteId = nil } }
            )) {
                Button("删除", role: .destructive) { deleteProfile() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("记忆不受影响；之后\(assistantName)还会重新写一份")
            }
            .sheet(item: $editing) { ctx in
                FileEditorSheet(
                    path: "profile.md",
                    initialContent: ctx.text,
                    initialModifiedAt: ctx.modifiedAt,
                    currentModifiedAt: { Self.fileModifiedAt(profileId: profileId) },
                    reloadExternalContent: {
                        let latest = ProfileFileStore.load(profileId: profileId)?.text ?? ""
                        return ReloadedFileContent(content: latest, modifiedAt: Self.fileModifiedAt(profileId: profileId))
                    },
                    onSave: { newContent, _ in save(newContent) },
                    onCancel: { editing = nil }
                )
            }
            #if os(macOS)
            .frame(width: 520, height: 560)
            #endif
            .onAppear(perform: load)
        }
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    nonisolated private static func fileModifiedAt(profileId: String) -> Date? {
        let url = FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent("profile.md")
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func load() {
        let pid = profileId
        Task {
            let (d, mtime) = await Task.detached {
                (ProfileFileStore.load(profileId: pid), Self.fileModifiedAt(profileId: pid))
            }.value
            dream = d
            modifiedAt = mtime
            loaded = true
        }
    }

    private func save(_ newText: String) {
        let saved = UserProfileDream(
            text: newText.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceCount: dream?.sourceCount ?? 0,
            updatedAt: Date()
        )
        ProfileFileStore.save(saved, profileId: profileId)
        dream = saved
        editing = nil
        load()
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    private func deleteProfile() {
        guard let pid = pendingDeleteId, !pid.isEmpty else { return }
        pendingDeleteId = nil
        let url = FileLibraryStore.memoryRoot(profileId: pid).appendingPathComponent("profile.md")
        try? FileManager.default.removeItem(at: url)
        dream = nil
        modifiedAt = nil
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
    }

    private func rewrite() {
        rewriting = true
        status = ""
        Task {
            let result = await MemoryOrganizer.rewriteProfile(profileId: profileId, providerManager: providerManager, context: modelContext)
            if let d = result.dream {
                dream = d
                load()
            }
            status = result.message
            rewriting = false
        }
    }
}
