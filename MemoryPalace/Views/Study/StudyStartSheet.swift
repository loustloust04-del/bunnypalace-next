import SwiftUI
import SwiftData

/// 学堂「开一门课」（plan-study-zero-engine §4.4 W2）：收主题 → 确保学堂文件夹 → 草稿带上文件夹 / 标题 / 钉模型 / 关记忆 →
/// 第一条消息 = 主题 + 课堂笔记路径 → 跳到聊天。只调 ConversationViewModel 现有的 public 方法。
/// Claude Code（P5 S1）：收不到 system，课程说明改成附件随第一条消息发，每门课绑专属 session，笔记发在聊天里。
struct StudyStartSheet: View {
    var viewModel: ConversationViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @AppStorage("selectedChatModel") private var globalModelId = ""

    @State private var topic = ""
    /// 她在开课页手动选的模型；nil = 用默认（主对话模型，是 Code 时自动改选第一张能上课的卡）
    @State private var pickedModelId: String?

    private var trimmedTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var assistantName: String {
        let name = profileManager?.currentProfile.assistantName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "助手" : name
    }

    private var mainModel: ProviderModel? {
        providerManager?.resolveModel(conversationModelId: nil, globalFallbackId: globalModelId)
    }

    /// 默认候选卡（有 key / 已装模型，不含 Code 桥——Claude Code 能上课但默认仍优先这些）：claude -p 优先，其次直连 API，本机模型垫底；
    /// 同档里收藏过模型的卡在前
    private var teachableCredentials: [APICredential] {
        guard let pm = providerManager else { return [] }
        func rank(_ c: APICredential) -> Int {
            if c.presetId == APIProvider.claudeP.id { return 0 }
            return c.type == .localMLX ? 2 : 1
        }
        return pm.enabledCredentials.enumerated()
            .filter { $0.element.type != .ccBridge && $0.element.type.isUsable }
            .sorted { a, b in
                let ka = (rank(a.element), hasFavorite(a.element) ? 0 : 1, a.offset)
                let kb = (rank(b.element), hasFavorite(b.element) ? 0 : 1, b.offset)
                return ka < kb
            }
            .map(\.element)
    }

    private func hasFavorite(_ c: APICredential) -> Bool {
        c.models.contains { providerManager?.isFavoriteModel(id: $0.id) == true }
    }

    /// 一张卡在选择器里露哪些模型：收藏的；没收藏就露上次用的（再不行第一个）——拉过几百个模型的卡不至于把菜单撑爆
    private func pickerModels(for c: APICredential) -> [ProviderModel] {
        let favorites = c.models.filter { providerManager?.isFavoriteModel(id: $0.id) == true }
        if !favorites.isEmpty { return favorites }
        if let last = c.lastUsedModelId, let m = c.models.first(where: { $0.modelId == last }) { return [m] }
        return c.models.first.map { [$0] } ?? []
    }

    /// 选择器分组：所有可用卡（含 Code 桥；Codex 选了会被拦），当前选中的模型保证在列表里
    private var pickerGroups: [(APICredential, [ProviderModel])] {
        guard let pm = providerManager else { return [] }
        var groups = pm.enabledCredentials.filter(\.type.isUsable).map { ($0, pickerModels(for: $0)) }
        if let model {
            if let i = groups.firstIndex(where: { $0.0.id == model.credentialId }) {
                if !groups[i].1.contains(where: { $0.id == model.id }) { groups[i].1.insert(model, at: 0) }
            } else if let c = pm.credential(for: model) {
                groups.append((c, [model]))
            }
        }
        return groups.filter { !$0.1.isEmpty }
    }

    /// 主对话模型能上课就用它；是 Code 桥或那张卡没 key（比如示例卡）→ 改选第一张能上课的卡
    private var defaultModel: ProviderModel? {
        guard let main = mainModel, let pm = providerManager else { return nil }
        let usable = pm.enabledCredentials.contains { $0.id == main.credentialId && $0.type != .ccBridge }
        if usable { return main }
        return teachableCredentials.first.flatMap { pickerModels(for: $0).first } ?? main
    }

    private var model: ProviderModel? {
        if let id = pickedModelId, let m = providerManager?.model(byId: id) { return m }
        return defaultModel
    }

    private var modelSelection: Binding<String> {
        Binding(get: { model?.id ?? "" }, set: { pickedModelId = $0 })
    }

    private var credential: APICredential? {
        guard let model else { return nil }
        return providerManager?.provider(for: model)
    }

    private var isCodex: Bool { credential?.type == .ccBridge && credential?.id == APIProvider.codexBridge.id }
    private var isClaudeCode: Bool { credential?.type == .ccBridge && !isCodex }

    private var softHints: [String] {
        guard let credential, credential.type != .ccBridge else { return [] }
        var hints: [String] = []
        if credential.type == .localMLX {
            hints.append("本机小模型带不动这份几千字的课程说明，效果会打折")
        }
        if credential.toolsSupported == false {
            hints.append("这张卡不能写文件，课堂笔记会以网页卡的形式留在对话里，旁边的笔记面板看不到")
        }
        if credential.type == .anthropic, credential.presetId != APIProvider.claudeP.id,
           let profile = profileManager?.currentProfile,
           (presetManager?.preset(byId: profile.presetId) ?? .balanced).sampling.maxTokens <= 4096 {
            hints.append("这张卡每次最多输出 4096 token，长讲解或写笔记可能被截断，可以在预设里调高输出上限")
        }
        return hints
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(assistantName)会先带你看全景，再从你最好奇的地方切入；每学完一块，都用问题检查理解，并回头补上概念之间的新联系。最后，你会自己整理这套知识，试着解释、迁移和应用。")
                        .font(.system(size: Theme.F.body))
                        .foregroundColor(Theme.textSecondary)
                }

                Section("想系统学什么？") {
                    TextField("一个主题、一个实际问题，或者一直没搞明白的东西", text: $topic, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    Picker(selection: modelSelection) {
                        ForEach(pickerGroups, id: \.0.id) { credential, models in
                            Section("\(credential.emoji) \(credential.name)") {
                                ForEach(models, id: \.id) { m in
                                    Text(m.name).tag(m.id)
                                }
                            }
                        }
                    } label: {
                        Label("上课用的模型", systemImage: "cpu")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .pickerStyle(.menu)
                    if isClaudeCode {
                        Text("Claude Code 上课：课程说明作为附件发给它，课堂笔记在聊天里以网页卡显示")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                    if isCodex {
                        // Codex 卡是跟着 Claude Code 卡成对补出来的（APIProvider.ensureCodexBridgeCard），选择器里通常就有 CC
                        Text("Codex 还不能上课，点上面的模型换成 Claude Code 或别的卡")
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.danger)
                    }
                    ForEach(softHints, id: \.self) { hint in
                        Text(hint)
                            .font(.system(size: Theme.F.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .navigationTitle("开一门课")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开课", action: start)
                        .disabled(trimmedTopic.isEmpty || model == nil || isCodex)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private func start() {
        guard let model, let profile = profileManager?.currentProfile,
              let pm = providerManager, let psm = presetManager else {
            ToastCenter.shared.show("缺少楼层或模型设置，开不了课")
            return
        }
        let topic = trimmedTopic
        let claudeCode = isClaudeCode
        let folder = StudyTemplate.ensureFolder(profileId: profile.id, context: modelContext)

        viewModel.startDraftConversation(profileId: profile.id, fresh: true)
        guard let draft = viewModel.selectedConversation else { return }
        draft.folderId = folder.id
        draft.title = StudyTemplate.courseTitle(topic: topic)
        draft.selectedModelId = model.id
        draft.memoryEnabled = false

        // CC 没有花园文件库工具：不占笔记目录、第一条不带笔记路径；课程说明作附件，session 只在 nil 时才会被 CVM 派生，这里先占
        let text: String
        var attachments: [PendingChatAttachment] = []
        if claudeCode {
            draft.ccBridgeSessionName = StudyTemplate.ccSessionName(conversationId: draft.id)
            attachments = [StudyTemplate.ccAttachment(body: StudyTemplate.teachingBody(of: folder.instructions),
                                                      userName: profile.userName, charName: profile.assistantName)]
            text = StudyTemplate.ccFirstMessage(topic: topic)
        } else {
            let notePath = StudyTemplate.notePath(topic: topic, profileId: profile.id)
            StudyTemplate.reserveNoteDirectory(notePath, profileId: profile.id)
            text = StudyTemplate.firstMessage(topic: topic, notePath: notePath)
        }

        let sent = viewModel.sendMessage(
            text,
            model: model,
            profile: profile,
            preset: psm.preset(byId: profile.presetId) ?? .balanced,
            providerManager: pm,
            context: modelContext,
            attachments: attachments
        )
        if !sent { ToastCenter.shared.show("没发出去，进课里重发一次") }
        dismiss()
        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
    }
}
