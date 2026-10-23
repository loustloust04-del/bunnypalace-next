import SwiftUI

// MARK: - Prompt Editor Page（学 SlotEditPage 样板，单值编辑）

/// 通用提示词编辑页：title + 大 TextEditor + 默认/清空快捷 + 原生 toolbar 取消/保存。
/// 用 NavigationLink push 调起（不是 sheet），跟 SlotEditPage 一致。
struct PromptEditorPage: View {
    let title: String
    let storageKey: String
    let defaultTemplate: String
    let hint: String

    @State private var edited: String = ""
    @State private var initial: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m

    private var isDirty: Bool { edited != initial }

    private func save() {
        UserDefaults.standard.set(edited, forKey: storageKey)
        initial = edited
        dismiss()
    }

    var body: some View {
        // mac 进设置窗 / 右栏面板都是 push 进来的：窗口 toolbar 已被宿主藏掉（会盖住页顶 ‹ › 行），取消 / 保存改画在页内；iOS 仍走原生 toolbar
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(MacSettingsButton())
                Button("保存") { save() }
                    .buttonStyle(MacSettingsButton())
                    .disabled(!isDirty)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            editor
        }
        .onAppear(perform: load)
        #else
        editor
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(isDirty ? Theme.branchIndicator : Theme.textMuted)
                        .disabled(!isDirty)
                }
            }
            .onAppear(perform: load)
        #endif
    }

    private var editor: some View {
        SettingsSectionList(.list) {
            Section("内容") {
                TextEditor(text: $edited)
                    .font(m.caption.monospaced())
                    .frame(minHeight: 240)
                    .scrollContentBackground(.hidden)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Button("用默认模板") { edited = defaultTemplate }
                    .foregroundColor(Theme.branchIndicator)
                if !edited.isEmpty {
                    Button(role: .destructive) { edited = "" } label: {
                        Text("清空（用默认）")
                    }
                }
                Text(hint)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        #else
        .scrollContentBackground(.hidden)
        #endif
    }

    private func load() {
        let stored = UserDefaults.standard.string(forKey: storageKey) ?? ""
        edited = stored
        initial = stored
    }
}

extension PromptEditorPage {
    /// 记忆页两个编辑入口的参数只写一份：iOS 推页（`MemoryPageContent`）与 mac 路由（`SettingsRoute.macDestination`）共用
    static var memoryExtract: PromptEditorPage {
        PromptEditorPage(
            title: "提取提示词",
            storageKey: "customMemoryExtractionPrompt",
            defaultTemplate: MemoryExtractor.extractionPrompt,
            hint: "可用占位符：{{CHAR_NAME}}（AI 的名字）、{{USER_NAME}}（你的称呼）、{{SYSTEM_PROMPT}}（人设）、{{PROFILE}}、{{MEMORIES}}"
        )
    }

    static var dream: PromptEditorPage {
        PromptEditorPage(
            title: "画像生成提示词",
            storageKey: "customDreamPrompt",
            defaultTemplate: DreamConsolidator.dreamPrompt,
            hint: "做梦时用这个提示词把零散事实凝成画像"
        )
    }
}
