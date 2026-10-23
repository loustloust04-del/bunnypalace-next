#if os(iOS)
import SwiftUI

// MARK: - Lite 模式「AI 性格」页

/// Lite 模式的 Prompt 简化页：【助手设定】【用户描述】两个框 + 引导语 +「帮我写」。
/// 外观跟原来一样（标签 + 内容框），点框展开全屏编辑器——小屏上 TextEditor 只有 100pt 高太憋屈。
/// 与 pro 的 Prompt 页读同一份 preset.prompts 插槽（绑定逻辑照抄 PersonaSettingsTab.personaSlotField），
/// 这里只是一层简化壳——不动 pro 的任何 UI，两套界面数据天然共通。
struct LitePersonaPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @State private var showCoach = false
    @State private var editingField: EditingField?

    private enum EditingField: Identifiable {
        case char, persona
        var id: Int { hashValue }
        var title: String {
            switch self {
            case .char: return "助手设定"
            case .persona: return "用户描述"
            }
        }
        var slotId: String {
            switch self {
            case .char: return PromptSlot.charDescriptionId
            case .persona: return PromptSlot.personaDescriptionId
            }
        }
        var placeholder: String {
            switch self {
            case .char: return "AI 助手的设定、风格、背景..."
            case .persona: return "介绍下自己…"
            }
        }
    }

    var body: some View {
        List {
            Section {
                Text("告诉 AI 它是谁、怎么跟你说话")
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(Theme.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

                liteSlotBox(label: "助手设定", field: .char, height: 120)
                liteSlotBox(label: "用户描述", field: .persona, height: 100)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            Section {
                Button(action: { showCoach = true }) {
                    Text("帮我写")
                        .font(.system(size: Theme.SettingsFont.secondary, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)

                Text("不确定怎么写？点「帮我写」，回答几个问题就能生成")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                    .listRowBackground(Theme.mainBg)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(10)
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("AI 性格")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCoach) {
            LitePersonaCoachView { char, persona in
                // 只写非空的那半边，没回答的不覆盖已有内容
                if !char.isEmpty { slotBinding(PromptSlot.charDescriptionId).wrappedValue = char }
                if !persona.isEmpty { slotBinding(PromptSlot.personaDescriptionId).wrappedValue = persona }
            }
        }
        .fullScreenCover(item: $editingField) { field in
            LiteSlotFullscreenEditor(title: field.title,
                                     placeholder: field.placeholder,
                                     text: slotBinding(field.slotId))
        }
    }

    // MARK: - 内容框（原样可直接编辑，标签旁小按钮展开全屏）

    private func liteSlotBox(label: String, field: EditingField, height: CGFloat) -> some View {
        let text = slotBinding(field.slotId)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button { editingField = field } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("全屏编辑\(label)")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(size: Theme.SettingsFont.body))
                    .frame(height: height)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(field.placeholder)
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                        .padding(.leading, 10)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sidebarBg))
        }
        .padding(.vertical, 4)
    }

    // MARK: - 插槽读写（与 PersonaSettingsTab.personaSlotField 同路径）

    private func slotBinding(_ slotId: String) -> Binding<String> {
        Binding<String>(
            get: {
                guard let pm = profileManager, let psm = presetManager else { return "" }
                return psm.preset(byId: pm.currentProfile.presetId)?
                    .prompts.first(where: { $0.id == slotId })?.content ?? ""
            },
            set: { newValue in
                guard let pm = profileManager, let psm = presetManager else { return }
                var p = psm.preset(byId: pm.currentProfile.presetId) ?? Preset.balanced
                if let idx = p.prompts.firstIndex(where: { $0.id == slotId }) {
                    p.prompts[idx].content = newValue
                    psm.save(p)
                }
            }
        )
    }
}

// MARK: - 全屏编辑器

/// 点小框后推上来的全屏编辑页：大 TextEditor + 左上关闭，自动弹键盘。
private struct LiteSlotFullscreenEditor: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: Theme.SettingsFont.body))
                    .padding(.horizontal, 12)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(placeholder)
                        .font(.system(size: Theme.SettingsFont.body))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                        .padding(.leading, 17)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Theme.mainBg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .onAppear { focused = true }
    }
}
#endif
