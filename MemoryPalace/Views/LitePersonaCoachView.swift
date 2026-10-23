#if os(iOS)
import SwiftUI

// MARK: - Lite「帮我写」提示词教练

/// 学 Airbnb 搜索页的交互：三个问题卡，一次展开一张，答过的收成一行摘要可点回去改；
/// 底部「清空 / 生成」。生成优先走 AI（ProviderRouter.sendNonStreaming，模型解析复用
/// DreamConsolidator.resolveModel：🌛副模型 → 当前聊天模型）；没配 API 或 AI 失败时
/// 用本地模板拼装（PersonaCoachComposer）兜底，草稿不会丢。
struct LitePersonaCoachView: View {
    /// 生成结果写回两个插槽（助手设定 / 用户描述）
    var onGenerate: (_ char: String, _ persona: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    @State private var scenes: Set<String> = []
    @State private var customScene = ""
    @State private var style: String?
    @State private var customStyle = ""
    @State private var nickname: String = ""
    @State private var about: String = ""
    @State private var expandedStep = 0
    @State private var generating = false
    @State private var generateError: String?

    private static let sceneOptions = ["聊天陪伴", "学习", "写东西", "编程", "工作", "随便聊聊"]
    private static let styleOptions = ["简短直接", "温柔耐心", "活泼一点", "严谨专业", "像朋友那样"]

    /// 场景答案按选项顺序排，自己写的追加在最后
    private var orderedScenes: [String] {
        Self.sceneOptions.filter { scenes.contains($0) } + scenes.filter { !Self.sceneOptions.contains($0) }.sorted()
    }

    private var hasAnyAnswer: Bool {
        !scenes.isEmpty || style != nil
            || !nickname.trimmingCharacters(in: .whitespaces).isEmpty
            || !about.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var aiAvailable: Bool {
        providerManager.flatMap { Self.resolveCoachModel(providerManager: $0) } != nil
    }

    /// 教练用的模型解析：🌛副模型 → 当前聊天模型 → 任意可用模型，全程跳过 ccBridge
    /// （桥是 WS 直发，不支持非流式调用，路由进去必报错）。
    static func resolveCoachModel(providerManager pm: ProviderManager) -> ProviderModel? {
        func usable(_ m: ProviderModel?) -> ProviderModel? {
            guard let m, pm.provider(for: m)?.type != .ccBridge else { return nil }
            return m
        }
        let extractId = UserDefaults.standard.string(forKey: "memoryExtractModelId") ?? ""
        if !extractId.isEmpty, let m = usable(pm.model(byId: extractId)) { return m }
        let chatId = UserDefaults.standard.string(forKey: "selectedChatModel") ?? ""
        if !chatId.isEmpty, let m = usable(pm.model(byId: chatId)) { return m }
        return pm.availableModels.first(where: { pm.provider(for: $0)?.type != .ccBridge })
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部：标题 + 关闭（Airbnb 同款右上 X）
            ZStack {
                Text("✦ 帮我写")
                    .font(.system(size: Theme.SettingsFont.body, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.mainBg))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 12) {
                    sceneCard
                    styleCard
                    aboutCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.immediately)

            // 底部：清空 / 生成
            VStack(spacing: 6) {
                if let generateError {
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Text("AI 没生成成功")
                                .font(.system(size: Theme.SettingsFont.caption))
                                .foregroundColor(Theme.textMuted)
                            Button("用模板填入") { applyResult(templateResult()); dismiss() }
                                .font(.system(size: Theme.SettingsFont.caption, weight: .medium))
                                .foregroundColor(Theme.branchIndicator)
                        }
                        Text(generateError)
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(Theme.textMuted.opacity(0.7))
                            .lineLimit(2)
                    }
                }
                HStack {
                    Button("清空") {
                        scenes.removeAll(); customScene = ""; style = nil; customStyle = ""
                        nickname = ""; about = ""; generateError = nil
                        expandedStep = 0
                    }
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Button(action: generate) {
                        HStack(spacing: 6) {
                            if generating {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                                Text("生成中…")
                            } else {
                                Text(aiAvailable ? "✦ AI 生成" : "生成")
                            }
                        }
                        .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(generateButtonBg)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasAnyAnswer || generating)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Theme.sidebarBg)
    }

    // MARK: - 生成按钮背景：薄荷绿胶囊（流光版退役到「开发调试」橱窗，见 RainbowFlowCapsule）

    private var generateButtonBg: some View {
        Capsule().fill(hasAnyAnswer && !generating ? Theme.branchIndicator : Theme.textMuted.opacity(0.4))
    }

    // MARK: - 三张问题卡

    private var sceneCard: some View {
        questionCard(step: 0, emoji: "🌱", title: "你主要拿它做什么？",
                     summary: scenes.isEmpty ? nil : orderedScenes.joined(separator: "、")) {
            chipFlow(Self.sceneOptions, isSelected: { scenes.contains($0) }) { option in
                if scenes.contains(option) { scenes.remove(option) } else { scenes.insert(option) }
            }
            customInput("自己写：比如 学日语", text: $customScene) {
                let v = customScene.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { scenes.insert(v); customScene = "" }
            }
            if !scenes.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.2)) { expandedStep = 1 } } label: {
                    Text("下一步")
                        .font(.system(size: Theme.SettingsFont.secondary, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var styleCard: some View {
        questionCard(step: 1, emoji: "🎐", title: "希望它说话什么感觉？",
                     summary: style) {
            chipFlow(Self.styleOptions, isSelected: { style == $0 }) { option in
                style = option
                withAnimation(.easeInOut(duration: 0.2)) { expandedStep = 2 }
            }
            customInput("自己写：比如 毒舌但靠谱", text: $customStyle) {
                let v = customStyle.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty {
                    style = v; customStyle = ""
                    withAnimation(.easeInOut(duration: 0.2)) { expandedStep = 2 }
                }
            }
        }
    }

    private var aboutCard: some View {
        questionCard(step: 2, emoji: "🌷", title: "它该怎么称呼你？",
                     summary: coachAboutSummary) {
            VStack(alignment: .leading, spacing: 10) {
                coachField("称呼", text: $nickname, placeholder: "比如：小鹿")
                coachField("还想让它知道你什么？（可不填）", text: $about, placeholder: "比如：在学英语，喜欢直接给答案")
            }
        }
    }

    private var coachAboutSummary: String? {
        let parts = [nickname, about]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 生成

    private func templateResult() -> (char: String, persona: String) {
        PersonaCoachComposer.compose(scenes: orderedScenes, style: style,
                                     nickname: nickname.trimmingCharacters(in: .whitespaces),
                                     about: about.trimmingCharacters(in: .whitespaces))
    }

    private func applyResult(_ result: (char: String, persona: String)) {
        onGenerate(result.char, result.persona)
    }

    private func generate() {
        guard let pm = providerManager,
              let model = Self.resolveCoachModel(providerManager: pm) else {
            applyResult(templateResult()); dismiss(); return
        }
        generating = true
        generateError = nil
        let answers = PersonaCoachComposer.answersPrompt(scenes: orderedScenes, style: style,
                                                         nickname: nickname.trimmingCharacters(in: .whitespaces),
                                                         about: about.trimmingCharacters(in: .whitespaces))
        Task {
            do {
                let router = ProviderRouter(usageContext: UsageContext(kind: .coach))
                let (text, _) = try await router.sendNonStreaming(
                    model: model,
                    messages: [(role: "user", content: answers)],
                    systemPrompt: PersonaCoachComposer.coachSystemPrompt,
                    providerManager: pm)
                let parsed = PersonaCoachComposer.parseAI(text)
                await MainActor.run {
                    generating = false
                    // 解析不出来就降级模板，草稿不丢
                    applyResult(parsed ?? templateResult())
                    dismiss()
                }
            } catch {
                await MainActor.run { generating = false; generateError = error.localizedDescription }
            }
        }
    }

    // MARK: - 卡片骨架：展开=emoji+大标题+内容，收起=标题+摘要一行

    @ViewBuilder
    private func questionCard<Content: View>(step: Int, emoji: String, title: String, summary: String?,
                                             @ViewBuilder content: () -> Content) -> some View {
        let isExpanded = expandedStep == step
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expandedStep = step }
            } label: {
                HStack(spacing: 8) {
                    Text(emoji)
                        .font(.system(size: isExpanded ? 22 : 15))
                    Text(title)
                        .font(.system(size: isExpanded ? Theme.SettingsFont.sectionHeader : Theme.SettingsFont.body,
                                      weight: isExpanded ? .bold : .regular))
                        .foregroundColor(isExpanded ? Theme.textPrimary : Theme.textSecondary)
                    Spacer()
                    if !isExpanded {
                        Text(summary ?? "点我回答")
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .foregroundColor(summary == nil ? Theme.textMuted.opacity(0.5) : Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isExpanded)
            if isExpanded {
                content()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
    }

    private func chipFlow(_ options: [String], isSelected: @escaping (String) -> Bool,
                          onTap: @escaping (String) -> Void) -> some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            // 预设选项 + 用户自己写的场景（自定义项排在预设后面，可点掉）
            ForEach(options, id: \.self) { option in
                chip(label: option, selected: isSelected(option), custom: false) { onTap(option) }
            }
            ForEach(orderedScenes.filter { !options.contains($0) }, id: \.self) { custom in
                chip(label: custom, selected: true, custom: true) { onTap(custom) }
            }
        }
    }

    private func chip(label: String, selected: Bool, custom: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                if custom {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .font(.system(size: Theme.SettingsFont.secondary, weight: selected ? .medium : .regular))
            .foregroundColor(selected ? .white : Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? Theme.branchIndicator : Theme.mainBg))
            .overlay(Capsule().stroke(selected ? Color.clear : Theme.textMuted.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func customInput(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
            TextField(placeholder, text: text)
                .font(.system(size: Theme.SettingsFont.secondary))
                .onSubmit(onSubmit)
            if !text.wrappedValue.isEmpty {
                Button(action: onSubmit) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebarBg))
    }

    private func coachField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted)
            TextField(placeholder, text: text)
                .font(.system(size: Theme.SettingsFont.body))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sidebarBg))
        }
    }
}

// MARK: - 生成：AI + 模板兜底

enum PersonaCoachComposer {
    /// AI 教练的 system prompt：输出固定两段标记，方便解析
    static let coachSystemPrompt = """
        你是提示词教练，根据用户的回答写两段设定文字。输出格式严格如下：
        【助手设定】
        （对 AI 说的话，用"你"开头：它是谁、围绕什么场景、什么说话风格，一两句）
        【用户描述】
        （介绍用户的第一人称短文，一两句；没有可写的就留空这一段）
        不要输出任何解释、标题之外的格式或多余内容。
        """

    /// 把回答整理成给 AI 的 user prompt
    static func answersPrompt(scenes: [String], style: String?, nickname: String, about: String) -> String {
        var lines: [String] = []
        if !scenes.isEmpty { lines.append("使用场景：\(scenes.joined(separator: "、"))") }
        if let style { lines.append("喜欢的说话风格：\(style)") }
        if !nickname.isEmpty { lines.append("称呼用户为：\(nickname)") }
        if !about.isEmpty { lines.append("关于用户：\(about)") }
        return lines.joined(separator: "\n")
    }

    /// 解析 AI 输出的【助手设定】【用户描述】两段；解析失败返回 nil（调用方降级模板）
    static func parseAI(_ text: String) -> (char: String, persona: String)? {
        guard let charRange = text.range(of: "【助手设定】") else { return nil }
        let afterChar = text[charRange.upperBound...]
        var charText: Substring
        var personaText: Substring = ""
        if let personaRange = afterChar.range(of: "【用户描述】") {
            charText = afterChar[..<personaRange.lowerBound]
            personaText = afterChar[personaRange.upperBound...]
        } else {
            charText = afterChar
        }
        let char = charText.trimmingCharacters(in: .whitespacesAndNewlines)
        let persona = personaText.trimmingCharacters(in: .whitespacesAndNewlines)
        return char.isEmpty && persona.isEmpty ? nil : (char, persona)
    }

    /// 本地模板拼装：AI 不可用/失败时的兜底
    static func compose(scenes: [String], style: String?, nickname: String, about: String)
        -> (char: String, persona: String) {
        var charParts: [String] = []
        if !scenes.isEmpty {
            charParts.append("我的主要使用场景是：\(scenes.joined(separator: "、"))，请围绕这些场景帮助我")
        }
        if let style {
            charParts.append("说话风格：\(style)")
        }
        let char = charParts.isEmpty ? "" : charParts.joined(separator: "。") + "。"

        var personaParts: [String] = []
        if !nickname.isEmpty { personaParts.append("称呼我「\(nickname)」") }
        if !about.isEmpty { personaParts.append(about) }
        let persona = personaParts.isEmpty ? "" : personaParts.joined(separator: "。") + "。"

        return (char, persona)
    }
}
#endif
