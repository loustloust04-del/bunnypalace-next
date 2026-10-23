import SwiftUI

// MARK: - 设置 · 小芽（plan-小芽助手.md Q4 裁决：人设设置里可改）
// 人设 prompt 覆写 + 说明。空 = 用内置小芽人设（会跟随 assistantName / lite-pro 默认名）。

struct XiaoyaSettingsTab: View {
    @AppStorage(AssistantPrompts.personaOverrideKey) private var personaOverride = ""
    @AppStorage(AssistantPrompts.nameKey) private var nameOverride = ""
    @AppStorage(XiaoyaStageTheme.storageKey) private var stageThemeRaw = XiaoyaStageTheme.mint.rawValue
    @AppStorage(XiaoyaPack.read.storageKey) private var packRead = XiaoyaPack.read.defaultEnabled
    @AppStorage(XiaoyaPack.creation.storageKey) private var packCreation = XiaoyaPack.creation.defaultEnabled
    @AppStorage(XiaoyaPack.appearance.storageKey) private var packAppearance = XiaoyaPack.appearance.defaultEnabled
    @AppStorage(XiaoyaModelChoice.key) private var modelChoice = ""
    @AppStorage("selectedChatModel") private var chatModelId = ""
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    var body: some View {
        List {
            Section {
                TextField("小芽", text: $nameOverride)
                    .font(.system(size: Theme.F.body))
            } header: {
                Text("名字")
            } footer: {
                Text("留空用默认：lite 叫「小芽」，pro 叫「Rosemary」。跟楼层 AI 的名字互不相干。")
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.sidebarBg)

            // 剪纸舞台四选一（plan-小芽-v2 §3.6）：迷你舞台是真布景渲染，亮色出太阳、暗色出月亮
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(XiaoyaStageTheme.allCases) { theme in
                        stageOption(theme)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("舞台")
            } footer: {
                Text("她窗口顶上的纸剧场。亮色主题出太阳，暗色主题出月亮。")
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.sidebarBg)

            // 权限包（plan-小芽-v2 §4.5）：关掉的包，模型连工具都看不见；写改动不管开没开包都要盖章
            Section {
                Toggle(isOn: $packRead) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(XiaoyaPack.read.title)
                        Text(XiaoyaPack.read.detail).font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted)
                    }
                }
                Toggle(isOn: $packCreation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(XiaoyaPack.creation.title)
                        Text(XiaoyaPack.creation.detail).font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted)
                    }
                }
                Toggle(isOn: $packAppearance) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(XiaoyaPack.appearance.title)
                        Text(XiaoyaPack.appearance.detail).font(.system(size: Theme.F.secondary)).foregroundColor(Theme.textMuted)
                    }
                }
            } header: {
                Text("能做什么")
            } footer: {
                Text("改东西一律先给你看，你盖了章才落地；盖过的在她窗口右上角的账本里能撤回。")
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.sidebarBg)

            modelSection

            Section {
                TextEditor(text: $personaOverride)
                    .font(.system(size: Theme.F.secondary))
                    .frame(minHeight: 220)
            } header: {
                Text("人设 prompt")
            } footer: {
                Text("留空使用内置人设。改了立即生效，下一轮对话就用新人设。")
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.sidebarBg)

            Section {
                Button("查看内置人设") {
                    personaOverride = AssistantPrompts.defaultPersona(name: AssistantPrompts.assistantName)
                }
                .foregroundColor(Theme.branchIndicator)
                if !personaOverride.isEmpty {
                    Button("恢复默认（清空覆写）", role: .destructive) {
                        personaOverride = ""
                    }
                }
            } footer: {
                Text("「查看内置人设」会把默认人设填进编辑框，方便在它基础上改。")
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.sidebarBg)

            Section {
                Label("能做什么：写角色卡、改预设、管世界书、查记忆", systemImage: "sparkles")
                Label("改东西都会先出一张卡给你看，你盖了章才生效，还能撤回", systemImage: "checkmark.shield")
                Label("用哪个模型在上面「模型」里选，可以选本机模型", systemImage: "network")
            }
            .font(.system(size: Theme.F.secondary))
            .foregroundColor(Theme.textSecondary)
            .listRowBackground(Theme.sidebarBg)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
        .navigationTitle("小芽")
    }

    // MARK: - 模型（plan-小芽-v3 §2）：默认跟随聊天；也能单独选收藏的模型或装好的本机模型

    private var modelOptions: [(id: String, label: String)] {
        guard let pm = providerManager else { return [] }
        var options = pm.favoritesByCredential.flatMap { credential, models in
            models.map { (id: $0.id, label: "\(credential.emoji) \($0.name)") }
        }
        let local = AssistantLocalModel.catalog.filter { AssistantModelStore.installedDirectory(modelId: $0.id) != nil }
            .map { (id: "\(APICredential.localId)/\($0.id)", label: "🌱 \($0.title)") }
        options += local.filter { item in !options.contains { $0.id == item.id } }
        if !modelChoice.isEmpty, !options.contains(where: { $0.id == modelChoice }) {
            options.append((id: modelChoice, label: pm.model(byId: modelChoice)?.name ?? "（已不可用）"))
        }
        return options
    }

    private var modelSection: some View {
        Section {
            Picker("\(AssistantPrompts.assistantName)用的模型", selection: $modelChoice) {
                Text("跟随聊天（\(providerManager?.model(byId: chatModelId)?.name ?? "未选")）").tag("")
                ForEach(modelOptions, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
        } header: {
            Text("模型")
        } footer: {
            Text("本机模型不联网、不花钱，手机上会慢一些；在「设置 › API › 本机模型」下载。")
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.sidebarBg)
    }

    private func stageOption(_ theme: XiaoyaStageTheme) -> some View {
        let selected = stageThemeRaw == theme.rawValue
        return Button {
            stageThemeRaw = theme.rawValue
        } label: {
            VStack(spacing: 6) {
                XiaoyaStageBackdrop(theme: theme, dark: Theme.activeScheme == .dark, collapsed: false)
                    .overlay(alignment: .bottomLeading) {
                        Image(XiaoyaMood.smirk.assetName)
                            .resizable().scaledToFit()
                            .frame(height: 44)
                            .shadow(color: .black.opacity(0.28), radius: 0, x: 1, y: 2)
                            .padding(.leading, 10)
                            .padding(.bottom, XiaoyaStageBackdrop.edgeDepth + 4)
                    }
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(selected ? Theme.branchIndicator : Color.clear, lineWidth: 2.5))
                Text(theme.title)
                    .font(.system(size: Theme.F.secondary, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Theme.textPrimary : Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
