import SwiftUI

/// 卡库 ③-4：选身份。身份库只读列表（名字 / 头像 / 描述），选中回调写楼层或对话的 personaId；新建 / 编辑身份不在这一步。
struct PersonaPickerSheet: View {
    let title: String
    /// 第一行：不用身份库时用什么（楼层：楼层原本的身份；对话：跟随楼层）
    let fallbackTitle: String
    let fallbackSubtitle: String
    let selectedId: String?
    /// 描述里的 `{{char}}` / `{{user}}` 显示时展开：角色名 + 楼层原本的用户名；选某个身份时 `{{user}}` 是它的名字（没名字沿用楼层的）
    let names: EffectiveCharacterContext
    let onPick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var store: UserPersonaStore { UserPersonaStore.shared }
    private var selectionMissing: Bool {
        guard let selectedId, !selectedId.isEmpty else { return false }
        return !store.personas.contains { $0.id == selectedId }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(id: nil, name: fallbackTitle, description: fallbackSubtitle, avatar: nil)
                    if selectionMissing {
                        Text("之前选的身份找不到了，现在按「\(fallbackTitle)」").font(.system(size: 12)).foregroundColor(Theme.danger)
                    }
                }
                Section(store.personas.isEmpty ? "身份库" : "身份库 · \(store.personas.count) 个") {
                    if store.personas.isEmpty {
                        Text("身份库是空的；导入酒馆整包会把身份带进来").font(.system(size: 13)).foregroundColor(Theme.textMuted)
                    }
                    ForEach(store.personas) { persona in
                        row(id: persona.id, name: persona.name.isEmpty ? "（没名字）" : persona.name,
                            description: EffectiveCharacterContext(charName: names.charName, userName: persona.name.isEmpty ? names.userName : persona.name)
                                .expand(persona.description), avatar: avatar(persona))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #endif
    }

    private func row(id: String?, name: String, description: String, avatar: Image?) -> some View {
        let selected = id == nil ? (selectedId ?? "").isEmpty || selectionMissing : selectedId == id
        return Button {
            onPick(id)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let avatar {
                        avatar.resizable().scaledToFill()
                    } else {
                        Text(String(name.prefix(1))).font(.system(size: 16, weight: .medium)).foregroundColor(Theme.branchIndicator)
                    }
                }
                .frame(width: 36, height: 36)
                .background(Theme.accent, in: Circle())
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 15, weight: .medium)).foregroundColor(Theme.textPrimary)
                    if !description.isEmpty {
                        Text(description).font(.system(size: 12)).foregroundColor(Theme.textMuted).lineLimit(6)
                    }
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark").foregroundColor(Theme.branchIndicator).accessibilityLabel("当前")
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func avatar(_ persona: UserPersona) -> Image? {
        guard let url = store.avatarURL(persona), let data = try? Data(contentsOf: url) else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}
