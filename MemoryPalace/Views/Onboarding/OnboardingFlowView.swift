#if os(iOS)
import SwiftUI

// MARK: - Onboarding 引导（设计：docs/未来愿景/design-onboarding.md）
//
// 首启 fullScreenCover 触发（ContentView iOS 分支），设置页搜索框「?」可重走。
// 流程：欢迎 → 身份 →（酒馆线：导入角色卡/世界书/预设｜其他：Ta叫什么名字）→ 称呼 → 配钥匙 → 挑脑子
//      →（酒馆线直达完成｜技术线：连桌面工具扫码配对｜其他：「Ta是谁」教练）→ 完成（顶栏计数 6 步，欢迎/完成不计）。
// 身份只写一次 lite/pro 默认值：小白/陪伴 lite，酒馆/技术/保持神秘 pro；之后用户在设置里随便改。
// 陪伴线的差异化（教练必过/强调记忆）仍是设计文档里的 TODO，以后单独做。
// 视觉：十字绣风墨绿点阵插画（PixelArtView），不用 emoji；布局抄 Pillow（居中大画 + 胶囊选项）。

struct OnboardingFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?

    @AppStorage("onboardingCompletedV1") private var completed = false
    @AppStorage("onboardingIdentity") private var identity = ""
    @AppStorage("onboardingUserName") private var userName = ""
    @AppStorage("settings.proMode") private var proMode = false

    private enum Step: Int {
        case welcome = 0, identity, charName, name, provider, model, coach, done
        case cardImport = 20   // 酒馆线：替代 charName 的坑位（进度算第 2 步）
        case desktopTools = 30 // 技术线：替代 coach 的坑位（进度算第 6 步）
    }

    /// 顶栏计数用的序号（cardImport 占 charName 的坑，desktopTools 占 coach 的坑）
    private var progressIndex: Int {
        switch step {
        case .cardImport: return 2
        case .desktopTools: return 6
        default: return min(step.rawValue, 6)
        }
    }

    @State private var step: Step = .welcome

    // S2「Ta叫什么名字」
    @AppStorage("assistantName") private var assistantName = "助手"
    @State private var charNameText = ""
    @FocusState private var charNameFocused: Bool

    // S2 酒馆线：导入角色卡/世界书/预设
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(\.modelContext) private var modelContext
    @State private var importedCardName: String?
    @State private var importedBookName: String?
    @State private var importedPresetName: String?
    @State private var importError: String?
    @State private var importSummary: String?
    @State private var importKind: ImportKind?
    private enum ImportKind { case card, worldBook, preset }

    // S3 称呼
    @State private var nameText = ""
    @FocusState private var nameFocused: Bool

    // S4 provider
    @State private var pickedProvider: OnbProvider?
    @State private var keyText = ""
    @State private var customBaseURL = ""
    @State private var pingState: PingState = .idle

    // S5 模型（草稿：确认之前什么都不落盘，#092 C）
    @State private var models: [ProviderModel] = []
    /// 选中的 modelId（草稿阶段还没有卡 id，落盘时再拼复合 id）
    @State private var pickedModelId: String?
    @State private var loadingModels = false
    @State private var modelLoadError: String?
    @State private var manualModelText = ""

    // S6 教练
    @State private var showCoach = false
    // 陪伴线：教练屏多一个「导入聊天记录」
    @State private var showHistoryImport = false
    // 技术线：教练屏换成「连桌面工具」（扫码配对 cc-bridge）
    @State private var showToolScanner = false
    @State private var toolPairResult: String?

    // S7 完成
    @State private var bloomed = false

    private enum PingState: Equatable {
        case idle, testing, ok, fail(String)
    }

    /// S4 的四个选择：三个内置预设 + 自定义（OpenAI 兼容）
    private enum OnbProvider {
        case openai, anthropic, gemini, custom
        var preset: APIProvider? {
            switch self {
            case .openai: return .openai
            case .anthropic: return .anthropic
            case .gemini: return .gemini
            case .custom: return nil
            }
        }
        var title: String {
            switch self {
            case .openai: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .gemini: return "Gemini"
            case .custom: return "自定义（OpenAI 兼容）"
            }
        }
        var tag: String {
            switch self {
            case .openai: return "gpt 系列"
            case .anthropic: return "claude 系列"
            case .gemini: return "google"
            case .custom: return "baseURL"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome && step != .identity && step != .done {
                topBar
            }
            Group {
                switch step {
                case .welcome: welcomeStep
                case .identity: identityStep
                case .charName: charNameStep
                case .cardImport: cardImportStep
                case .name: nameStep
                case .provider: providerStep
                case .model: modelStep
                case .coach: coachStep
                case .desktopTools: desktopToolsStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, step == .welcome || step == .identity ? 0 : 24)
        .padding(.vertical, step == .welcome || step == .identity ? 0 : 20)
        .frame(maxWidth: step == .welcome || step == .identity ? .infinity : Theme.contentMaxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.mainBg.ignoresSafeArea())
    }

    // MARK: - 顶栏（Pillow 三件套：返回 + 细进度条 + 计数 + 跳过）

    private var topBar: some View {
        HStack(spacing: 12) {
            GlassBackButton { back() }   // 1:1 复用聊天页 page1 的返回钮

            Capsule()
                .fill(Color(hex: 0xE5DDCF))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Theme.branchIndicator)
                            .frame(width: geo.size.width * CGFloat(progressIndex) / 6)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: step)

            Text("\(progressIndex)/6")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)

            Button("跳过") { skip() }
                .font(.system(size: 13))
                .foregroundColor(Theme.textMuted)
                .buttonStyle(.plain)
        }
        .padding(.bottom, 14)
    }

    private func back() {
        withAnimation {
            switch step {
            case .cardImport: step = .identity
            case .name: step = identity == "tavern" ? .cardImport : .charName
            case .desktopTools: step = .model
            default: step = Step(rawValue: step.rawValue - 1) ?? .welcome
            }
        }
    }

    private func skip() {
        switch step {
        case .identity: finishGhostCopy()
        case .charName:
            // 点了跳过但名字已经打了：留着，别白打
            if !charNameText.trimmingCharacters(in: .whitespaces).isEmpty { submitCharName() } else { advance(to: .name) }
        case .cardImport: advance(to: .name)
        case .name:
            if !nameText.trimmingCharacters(in: .whitespaces).isEmpty { submitName() } else { advance(to: .provider) }
        case .provider:
            // 点了跳过但 key 已经贴了：存下来再跳，别白填（与上面 charName/name 同款保护）。
            // 不进 .model 屏——用户点的是「跳过」，卡上第一个模型顶成默认并收藏；
            // 否则 resolveModel 兜底会落到排在前面的 Claude Code 卡，第一句就发不出去。
            if canGoModel, let cid = persistCard(),
               let first = providerManager?.credentials.first(where: { $0.id == cid })?.models.first {
                UserDefaults.standard.set(first.id, forKey: "selectedChatModel")
                favoriteIfNeeded(first.id)
            }
            advance(to: stepAfterModel())
        case .model: advance(to: stepAfterModel())
        case .coach: advance(to: .done)
        case .desktopTools: advance(to: .done)
        default: break
        }
    }

    /// 挑脑子之后去哪：酒馆直达完成（角色卡已回答"Ta是谁"），技术去连桌面工具，其余进教练
    private func stepAfterModel() -> Step {
        switch identity {
        case "tavern": return .done
        case "tech": return .desktopTools
        default: return .coach
        }
    }

    private func advance(to next: Step) {
        withAnimation { step = next }
    }

    // MARK: - S0 欢迎

    private var welcomeStep: some View {
        AstralWelcomeView(
            onStart: { advance(to: .identity) },
            onExplore: { finishGhostCopy() }
        )
    }

    // MARK: - S1 身份

    private struct IdentityCard {
        let id: String, title: String, desc: String, defaultPro: Bool
    }

    private let identityCards: [IdentityCard] = [
        .init(id: "newbie", title: "我是小白", desc: "先聊起来再说，别的慢慢懂", defaultPro: false),
        .init(id: "tavern", title: "酒馆用户", desc: "我有角色卡，直接导入", defaultPro: true),
        .init(id: "companion", title: "长期陪伴", desc: "想要个记得我的长期搭子", defaultPro: false),
        .init(id: "tech", title: "技术用户", desc: "别废话，给我 key 框", defaultPro: true),
        .init(id: "ghost", title: "保持神秘", desc: "不定义我，直接进去", defaultPro: true),
    ]

    // Pillow 同款：左题 → 居中大画 → 胶囊选项
    private var identityStep: some View {
        AstralIdentityView(
            choices: identityCards.map { AstralIdentityChoice(id: $0.id, title: $0.title, detail: $0.desc) },
            onSelect: { id in
                if let card = identityCards.first(where: { $0.id == id }) { pickIdentity(card) }
            },
            onBack: { back() },
            onSkip: { skip() }
        )
        .transition(.opacity)
    }

    private func pickIdentity(_ card: IdentityCard) {
        identity = card.id
        proMode = card.defaultPro   // 只写一次默认值，之后用户在设置里随便改
        switch card.id {
        case "ghost": finishGhostCopy()
        case "tavern": advance(to: .cardImport)
        default: advance(to: .charName)
        }
    }

    // MARK: - S2「Ta叫什么名字」（AI 名不该偷偷默认，问一句）

    private var charNameStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ta叫什么名字？")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("就叫\(defaultAiName)也行，或者给 Ta 起一个")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            PixelArtView(motif: .quill, scale: 6)
            TextField(defaultAiName, text: $charNameText)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .focused($charNameFocused)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(charNameFocused ? Theme.branchIndicator : Color(hex: 0xDDD4C6))
                        .frame(height: 2)
                }
                .padding(.top, 22)
            Spacer()
            Spacer()
            HStack {
                Spacer()
                Button { submitCharName() } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            if charNameText.isEmpty {
                let cur = assistantName.trimmingCharacters(in: .whitespaces)
                if !cur.isEmpty && cur != "助手" { charNameText = cur }  // 重走时带出已有名字
            }
            charNameFocused = true
        }
    }

    private func submitCharName() {
        let n = charNameText.trimmingCharacters(in: .whitespaces)
        let resolved = n.isEmpty ? defaultAiName : n
        assistantName = resolved
        // ⚠️ 光写 @AppStorage 不够：UserDefaults 的 assistantName 只是 Profile 的**单向镜像**，
        // ProfileManager.switchTo/updateProfile 都会拿 profile 的值盖回来（MemoryPalaceApp:217/244），
        // 而设置页的 AI 名字框读的也是 profile（:1258）。真相源是 profile，必须一起写。
        if var p = profileManager?.currentProfile {
            p.assistantName = resolved
            profileManager?.updateProfile(p)
        }
        advance(to: .name)
    }

    /// 引导吉祥物默认名：lite = 小芽，pro = rosemary（不准用楼层 AI 的名字）
    private var defaultAiName: String { proMode ? "rosemary" : "小芽" }

    /// 空着/还是默认「助手」时，称呼屏标题用吉祥物名兜底
    private var aiNameDisplay: String {
        let n = assistantName.trimmingCharacters(in: .whitespaces)
        return (n.isEmpty || n == "助手") ? defaultAiName : n
    }

    // MARK: - S2 酒馆线：导入角色卡 / 世界书 / 预设（替代「Ta叫什么名字」）

    private var cardImportStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroArt(.card, scale: 7)
            Text("导入你的角色卡、预设和世界书")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text("酒馆导出的 .json / .png 都行；没有也没事，右栏卡库随时能补")
                .font(.system(size: 14))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 2)
                .padding(.bottom, 14)

            importRow(title: "角色卡", hint: ".json / .png", done: importedCardName) { importKind = .card }
            importRow(title: "世界书", hint: ".json", done: importedBookName) { importKind = .worldBook }
            importRow(title: "预设", hint: ".json", done: importedPresetName) { importKind = .preset }

            Spacer()
            primaryButton("下一步") { advance(to: .name) }
        }
        .fileImporter(
            isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
            allowedContentTypes: importKind == .card ? [.json, .png] : [.json],
            allowsMultipleSelection: false
        ) { handleOnbImport($0) }
        .alert("导入完成", isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })) {
            Button("好的") { importSummary = nil }
        } message: { Text(importSummary ?? "") }
        .alert("导入失败", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好的") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importRow(title: String, hint: String, done: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if let done {
                    Text("✓ \(done)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.branchIndicator)
                        .lineLimit(1)
                } else {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.sidebarBg))
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.sidebarBg, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 9)
    }

    private func handleOnbImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first, let kind = importKind else { return }
        importKind = nil
        switch kind {
        case .card:
            guard let cardManager, let profileManager, let presetManager else { return }
            do {
                let card = try cardManager.importFromFile(url: url)
                Task { @MainActor in
                    do {
                        _ = try await cardManager.floors(profileManager: profileManager, presetManager: presetManager).enter(card: card)
                        importedCardName = card.name
                        assistantName = card.name
                        if card.hasWorldBook { importSummary = try card.decodeWorldBook().summary }
                    } catch { importError = error.localizedDescription }
                }
            } catch { importError = error.localizedDescription }
        case .worldBook:
            importWorldBook(url: url)
        case .preset:
            importPreset(url: url)
        }
    }

    /// 与 WorldBookPanelView.handleWorldBookImport 同套解析（酒馆 entries 数组/对象两种格式）
    private func importWorldBook(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let report = try WorldBookCodec.decodeImport(data)
            guard !report.entries.isEmpty else {
                importError = "世界书没有条目"
                return
            }
            let name = report.name ?? url.deletingPathExtension().lastPathComponent
            let book = WorldBook(name: name, profileId: profileManager?.currentProfile.id ?? "", entries: report.entries)
            book.rawJSONData = report.rawJSONData
            modelContext.insert(book)

            if var profile = profileManager?.currentProfile {
                profile.linkedWorldBookIDs.append(book.id.uuidString)
                profileManager?.updateProfile(profile)
            }
            try modelContext.save()
            importedBookName = name
            importSummary = report.summary
        } catch {
            importError = error.localizedDescription
        }
    }

    /// 与 PersonaSettingsTab.importPresetData 同路径：酒馆预设导入 + 绑到当前楼层
    private func importPreset(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let imported = try? presetManager?.importFromSillyTavern(data) else {
            importError = "不是能认的预设文件"
            return
        }
        if var p = profileManager?.currentProfile {
            p.presetId = imported.preset.id
            profileManager?.updateProfile(p)
        }
        importedPresetName = imported.preset.name
        // ④a：prompt_order 没按 100001 组导入时接上已有的「导入完成」提示
        if !imported.notes.isEmpty { importSummary = imported.notes.joined(separator: "\n") }
    }

    // MARK: - S3 称呼（Pillow 第一题同款：名字是个性化杠杆）

    private var nameStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(aiNameDisplay)该怎么称呼你？")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("之后聊天 Ta 就这么叫你")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            PixelArtView(motif: .heart, scale: 6)
            TextField("你的名字", text: $nameText)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .focused($nameFocused)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(nameFocused ? Theme.branchIndicator : Color(hex: 0xDDD4C6))
                        .frame(height: 2)
                }
                .padding(.top, 22)
            Spacer()
            Spacer()
            HStack {
                Spacer()
                Button { submitName() } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)
                .opacity(nameText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 1)
                .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { nameFocused = true }
    }

    private func submitName() {
        let n = nameText.trimmingCharacters(in: .whitespaces)
        userName = n
        // ⚠️ `onboardingUserName` 全 app 没有第二个消费者（引导自己读写自己），
        // 真正被聊天/{{user}}/设置读到的是 Profile.userName。不写这一句，用户填的称呼直接蒸发。
        if var p = profileManager?.currentProfile, !n.isEmpty {
            p.userName = n
            profileManager?.updateProfile(p)
        }
        advance(to: .provider)
    }

    /// Pillow 式大插画区：居中大画 + 上下留白
    private func heroArt(_ motif: PixelMotif, scale: CGFloat) -> some View {
        PixelArtView(motif: motif, scale: scale)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.bottom, 22)
    }

    /// Pillow 式：答过称呼后标题带上名字
    private func titled(_ base: String) -> String {
        userName.isEmpty ? base : "\(userName)，\(base)"
    }

    // MARK: - S4 Provider（配钥匙，连上自动去挑脑子）

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroArt(.key, scale: 6)
            Text(titled("先拿把钥匙"))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text(identity == "newbie" ? "key 在服务商官网的 API 页面拿，复制贴进来就行" : "选一个 AI 服务商，把 API key 贴进来")
                .font(.system(size: 14))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 2)
                .padding(.bottom, 14)

            ForEach([OnbProvider.openai, .anthropic, .gemini, .custom], id: \.title) { p in
                Button { pickProvider(p) } label: {
                    HStack {
                        ProviderIconView(presetId: p.preset?.id, displayName: p.title,
                                         size: AppIconSize.list, tint: Theme.textSecondary)
                            .padding(.trailing, 4)
                        Text(p.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Text(p.tag)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textMuted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.sidebarBg))
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(
                        pickedProvider == p ? Theme.branchIndicator : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 9)
            }

            if pickedProvider != nil {
                if pickedProvider == .custom {
                    TextField("baseURL，比如 https://your-proxy/v1", text: $customBaseURL)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.sidebarBg, lineWidth: 1.5))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .padding(.bottom, 8)
                }
                HStack(spacing: 8) {
                    SecureField("sk-...", text: $keyText)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.sidebarBg, lineWidth: 1.5))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button { testKey() } label: {
                        Text(pingState == .testing ? "连接中…" : "连一下试试")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xC4A882)))
                    }
                    .buttonStyle(.plain)
                    .disabled(keyText.isEmpty || pingState == .testing)
                    .opacity(keyText.isEmpty || pingState == .testing ? 0.5 : 1)
                }
                switch pingState {
                case .ok:
                    Text("✓ 连上了")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.branchIndicator)
                        .padding(.top, 8)
                case .fail(let msg):
                    Text("✕ 没连上：\(msg)")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: 0xB4574E))
                        .padding(.top, 8)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
            }

            Spacer()
            primaryButton("下一步", enabled: canGoModel) { goModel() }
        }
    }

    private var canGoModel: Bool {
        guard pickedProvider != nil else { return false }
        if pickedProvider == .custom && customBaseURL.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return !keyText.isEmpty
    }

    private func pickProvider(_ p: OnbProvider) {
        pickedProvider = p
        pingState = .idle
        models = []
        pickedModelId = nil
        modelLoadError = nil
    }

    /// 当前选择现拼的草稿卡（不进卡表）：测试、拉模型都用它；换服务商 / 改地址自然用新的
    private func draftCredential() -> APICredential? {
        guard let choice = pickedProvider else { return nil }
        let preset = choice.preset
        let id = "onboarding-draft"
        let list = models.isEmpty ? (preset?.models ?? []) : models
        return APICredential(
            id: id,
            name: choice.title,
            emoji: "🔑",
            presetId: preset?.id,
            type: preset?.type ?? .openaiCompatible,
            baseURL: BaseURLNormalizer.normalize(preset?.baseURL ?? customBaseURL, type: preset?.type ?? .openaiCompatible),
            extraHeaders: preset?.extraHeaders ?? [:],
            models: list.map { ProviderModel(credentialId: id, modelId: $0.modelId, name: $0.name) }
        )
    }

    /// 确认模型（或带着 key 跳过）时才建卡。已有同协议、同地址、同 key 的卡就复用，重走引导不再多一张。
    @discardableResult
    private func persistCard() -> String? {
        guard let pm = providerManager, let draft = draftCredential() else { return nil }
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let reuse = pm.credentials.first {
            $0.type == draft.type && $0.baseURL == draft.baseURL && pm.apiKey(for: $0.id) == key
        }
        let cid = reuse?.id ?? "cred-" + UUID().uuidString
        var merged = reuse?.models ?? []
        for m in draft.models where !merged.contains(where: { $0.modelId == m.modelId }) { merged.append(m) }
        pm.addCredential(APICredential(
            id: cid,
            name: reuse?.name ?? draft.name,
            emoji: reuse?.emoji ?? pm.allocateUnusedEmoji(),
            presetId: draft.presetId,
            type: draft.type,
            baseURL: draft.baseURL,
            extraHeaders: draft.extraHeaders,
            models: merged.map { ProviderModel(credentialId: cid, modelId: $0.modelId, name: $0.name) },
            createdAt: reuse?.createdAt ?? Date(),
            lastUsedAt: reuse?.lastUsedAt,
            lastUsedModelId: reuse?.lastUsedModelId,
            toolsSupported: reuse?.toolsSupported
        ))
        pm.setApiKey(key, for: cid)
        return cid
    }

    private func testKey() {
        guard let draft = draftCredential() else { return }
        let key = keyText
        pingState = .testing
        Task {
            let result = await ProviderProbe.test(draft: draft, key: key)
            await MainActor.run {
                switch result {
                case .success(let ok):
                    if models.isEmpty, !ok.fetchedModels.isEmpty { models = ok.fetchedModels }
                    pingState = .ok
                    // 真 2xx 才会走到这里：自动去挑脑子（顺手拉模型列表）；手动「下一步」也留着兜底
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        await MainActor.run {
                            if step == .provider && pingState == .ok { goModel() }
                        }
                    }
                case .failure(let e): pingState = .fail(e.localizedDescription)
                }
            }
        }
    }

    private func goModel() {
        loadModels()
        advance(to: .model)
    }

    // MARK: - S5 模型（挑脑子：★ 标省钱默认款，底部指路 设置 → API）

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroArt(.spark, scale: 8)
            Text(titled("挑个脑子"))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text("随时能换，先选个顺手的")
                .font(.system(size: 14))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 2)
                .padding(.bottom, 14)

            if !canGoModel {
                Text("还没钥匙——之后去 设置 → API 加好再来挑")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textMuted)
                    .padding(.bottom, 14)
            } else if loadingModels && models.isEmpty {
                ProgressView().padding(.bottom, 14)
            } else {
                if models.isEmpty, let err = modelLoadError {
                    Text("拉不到模型列表：\(err)")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: 0xB4574E))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    HStack(spacing: 8) {
                        TextField("手填模型 ID，比如 gpt-4o-mini", text: $manualModelText)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textPrimary)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.mainBg))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.sidebarBg, lineWidth: 1.5))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button { addManualModel() } label: {
                            Text("用这个")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xC4A882)))
                        }
                        .buttonStyle(.plain)
                        .disabled(manualModelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.bottom, 14)
                }
                ForEach(models) { m in
                    Button { pickedModelId = m.modelId } label: {
                        HStack {
                            Text(m.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            if priceTag(m) == "便宜" {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.branchIndicator)
                            }
                            Text(priceTag(m))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textMuted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.sidebarBg))
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
                            pickedModelId == m.modelId ? Theme.branchIndicator : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 9)
                }
                Text(identity == "newbie"
                     ? "★ 省钱默认款，会自动兼差当后台小模型（记忆提取那些杂活）\n以后想换模型、加 key：设置 → 模型（API）里都有，找不到就点搜索框的「?」\n默认累计花到 $10 会先拦一下，免得烧穿 key；上限在 设置 → 模型（API）→ 预算 改"
                     : "★ 省钱默认款 · 之后都在 设置 → API 改\n默认累计花到 $10 会先拦一下，上限在 设置 → API → 预算 改")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)   // 两行小字不许压成一行省略号
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }

            Spacer()
            if canGoModel {
                primaryButton("下一步", enabled: pickedModelId != nil) { confirmModel() }
            }
        }
    }

    private func priceTag(_ m: ProviderModel) -> String {
        let s = (m.modelId + m.name).lowercased()
        if s.contains("haiku") || s.contains("mini") || s.contains("nano") || s.contains("flash") || s.contains("lite") {
            return "便宜"
        }
        if s.contains("opus") || s.contains("o3") || s.contains("pro") || s.contains("deepseek-reasoner") {
            return "旗舰"
        }
        return "中等"
    }

    /// 用草稿拉模型（不落盘）：拉到的并进预设清单；拉不到留着预设清单，空的就让人手填
    private func loadModels() {
        guard let draft = draftCredential() else { return }
        models = draft.models
        modelLoadError = nil
        // 预选便宜款当默认
        pickedModelId = models.first(where: { priceTag($0) == "便宜" })?.modelId ?? models.first?.modelId
        loadingModels = true
        let key = keyText
        Task {
            let r = await ProviderProbe.fetchModels(draft: draft, key: key)
            await MainActor.run {
                loadingModels = false
                switch r {
                case .success(let fetched):
                    for m in fetched where !models.contains(where: { $0.modelId == m.modelId }) { models.append(m) }
                    if models.isEmpty { modelLoadError = "列表是空的" }
                case .failure(let err):
                    modelLoadError = err.localizedDescription
                }
                if pickedModelId == nil || !models.contains(where: { $0.modelId == pickedModelId }) {
                    pickedModelId = models.first(where: { priceTag($0) == "便宜" })?.modelId ?? models.first?.modelId
                }
            }
        }
    }

    private func addManualModel() {
        let id = manualModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if !models.contains(where: { $0.modelId == id }) {
            models.append(ProviderModel(credentialId: "onboarding-draft", modelId: id, name: id))
        }
        pickedModelId = id
        manualModelText = ""
    }

    private func confirmModel() {
        if let mid = pickedModelId, let cid = persistCard() {
            let combined = "\(cid)/\(mid)"
            UserDefaults.standard.set(combined, forKey: "selectedChatModel")  // 复合 id <credentialId>/<modelId>
            favoriteIfNeeded(combined)
        }
        advance(to: stepAfterModel())
    }

    /// 选择器只列收藏——不收藏，用户切走一次就再也找不回自己刚配的模型。
    private func favoriteIfNeeded(_ modelId: String) {
        guard let pm = providerManager, !pm.isFavoriteModel(id: modelId) else { return }
        pm.toggleFavoriteModel(id: modelId)
    }

    // MARK: - S6 提示词教练（复用 LitePersonaCoachView，不改它本身；酒馆线跳过本屏）

    private var coachStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroArt(.blossom, scale: 8)
            Text(titled("最后，Ta是谁？"))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text("回答两小题，帮你写好设定（就是设置里的「帮我写」）")
                .font(.system(size: 14))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 2)
            Spacer()
            primaryButton("回答两小题") { showCoach = true }
            // 陪伴线：让 Ta 直接吃历史对话当记忆，比回答两小题更快
            if identity == "companion" {
                Button { showHistoryImport = true } label: {
                    Text("导入聊天记录")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.branchIndicator)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().stroke(Theme.branchIndicator, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
            Button { advance(to: .done) } label: {
                Text("我自己写 / 之后再说 →")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
        .sheet(isPresented: $showHistoryImport) {
            ImportView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Theme.sidebarBg)
        }
        .fullScreenCover(isPresented: $showCoach) {
            LitePersonaCoachView { char, persona in
                writeSlot(PromptSlot.charDescriptionId, char)
                writeSlot(PromptSlot.personaDescriptionId, persona)
                advance(to: .done)
            }
        }
    }

    /// 与 LitePersonaPage.slotBinding 同路径：写 preset.prompts 插槽
    private func writeSlot(_ slotId: String, _ content: String) {
        guard !content.isEmpty, let pm = profileManager, let psm = presetManager else { return }
        var p = psm.preset(byId: pm.currentProfile.presetId) ?? Preset.balanced
        if let idx = p.prompts.firstIndex(where: { $0.id == slotId }) {
            p.prompts[idx].content = content
            psm.save(p)
        }
    }

    // MARK: - S6 技术线：连桌面工具（替代教练屏；大概版，app 本体还在动，以后细化）

    private var desktopToolsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroArt(.gear, scale: 8)
            Text(titled("连桌面工具"))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text("Claude Code / Codex / 终端都跑在 Mac 上，手机扫个码就连上")
                .font(.system(size: 14))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 2)
                .padding(.bottom, 14)

            toolRow("Claude Code", "Mac 端 ~/.claude 的会话直接搬进来")
            toolRow("Codex", "同一个桥，配对一次两边通用")
            toolRow("终端", "手机上跑 Mac 的 shell")

            if let toolPairResult {
                Text(toolPairResult)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.branchIndicator)
                    .padding(.top, 4)
            }

            Spacer()
            primaryButton(toolPairResult == nil ? "扫码配对" : "已连上，下一步") {
                if toolPairResult == nil { showToolScanner = true } else { advance(to: .done) }
            }
            Button { advance(to: .done) } label: {
                Text("以后再说，设置 → 编程工具 里随时连 →")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
        .fullScreenCover(isPresented: $showToolScanner) {
            CCPairScannerSheet { payload in applyToolPairing(payload) }
        }
    }

    private func toolRow(_ title: String, _ desc: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Text(desc)
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.sidebarBg, lineWidth: 1.5))
        .padding(.bottom, 9)
    }

    /// 与设置页扫码同一份落地（CC 和 Codex 是同一个 cc-bridge）
    private func applyToolPairing(_ p: CCPairPayload) {
        let result = CCPairingApply.apply(p, providerManager: providerManager)
        toolPairResult = result.hasPrefix("已配对") ? result : nil
    }

    // MARK: - S7 完成

    private var doneStep: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 26) {
                PixelArtView(motif: .sprout, scale: 5.5)
                    .scaleEffect(bloomed ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55), value: bloomed)
                PixelArtView(motif: .spark, scale: 5.5)
                    .scaleEffect(bloomed ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.12), value: bloomed)
                PixelArtView(motif: .blossom, scale: 5.5)
                    .scaleEffect(bloomed ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.24), value: bloomed)
            }
            Text(identity == "ghost" ? "好，不问了" : titled("都准备好了"))
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .padding(.top, 20)
            // ghost 线是从身份卡屏直接跳到这里的，没经过 key 那屏 —— 不指路的话
            // 用户发第一句必然撞报错，而引导标记完成后不会再自己出现（粟粟 09-04 拍：
            // 保持现状 + 完成页加指路）。
            Text(identity == "ghost"
                 ? "还差一把钥匙——设置 → API 里贴一把就能开聊。右下角永远有个「?」"
                 : "花园开工，去聊第一句吧")
                .font(.system(size: 14))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 4)
            Spacer()
            primaryButton(identity == "ghost" ? "进屋" : "开始对话") { completeAndDismiss() }
        }
        .onAppear {
            bloomed = true
            PushAppDelegate.requestAuthorization()   // 首启不在启动时弹，挪到这里（「随便看看」/跳过也落到本页）
        }
    }

    private func finishGhostCopy() {
        identity = "ghost"
        proMode = true   // 保持神秘也默认 pro（身份卡里 ghost.defaultPro = true）
        advance(to: .done)
    }

    private func completeAndDismiss() {
        completed = true
        dismiss()
    }

    // MARK: - 通用件

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Theme.branchIndicator))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }
}
#endif
