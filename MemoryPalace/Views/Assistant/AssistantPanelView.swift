import SwiftUI
import SwiftData

// MARK: - 小芽助手面板 v2（plan-小芽-v2 §3.3；设计 docs/design-小芽-v2.html §01 A 舞台头）
// 舞台（大表情 + 名字 + 状态）浮在消息列表上方；她的话用一条墨线引出、不套气泡，你的话是浅薄荷气泡。
// 离底部远了（在翻旧消息）舞台收成一行，回到底部再展开。
//
// plan-onboarding-xiaoya-impl §2.2 拆两层：XiaoyaConversationView（舞台 + 消息 + 输入框，engine 从外面给）+ 外壳。
// 10-16 改向（§10）：小芽没有自己的楼层了，外壳只剩 page2 / mac 右栏的小芽 app；新手引导也在这里走。
// 传的是 AssistantEngine.shared：在哪个楼层跟小芽说话都是同一段对话。

extension Notification.Name {
    /// 打开小芽 app（iOS：ContentView 翻到 page2 打开它）——新装首启 / 设置「新手引导」（§10-4、§10-6）
    static let xiaoyaAppRequested = Notification.Name("MemoryPalaceXiaoyaAppRequested")
    /// 出口卡「去找 X」：iOS 把 page2 退回桌面、翻回 page1（§10-5）
    static let xiaoyaAppLeaveRequested = Notification.Name("MemoryPalaceXiaoyaAppLeaveRequested")
    /// Tip「带我去桌面」：iOS 把 page2 退回桌面（不翻页），第一次回桌面接开机 hello（§11-5）
    static let xiaoyaDesktopRequested = Notification.Name("MemoryPalaceXiaoyaDesktopRequested")
}

@MainActor
enum XiaoyaApp {
    static let toolId = "xiaoya"

    /// 这次启动时引导在走（新装刚判成 started / 上次没走完）：一打开就在小芽 app 里。进程内不再变（开屏判据用）
    private(set) static var launchedInApp = false
    private static var launchOpenPending = false

    /// App.init 判完新装后调：iOS 记下来等 ContentView 出现时打开；mac 直接开右栏
    static func noteLaunch(onboardingStarted: Bool) {
        guard onboardingStarted else { return }
        launchedInApp = true
        #if os(iOS)
        launchOpenPending = true
        #else
        open()
        #endif
    }

    /// ContentView 第一次出现时取一次：要不要把 page2 翻到小芽 app
    static func takeLaunchOpen() -> Bool {
        defer { launchOpenPending = false }
        return launchOpenPending
    }

    /// 回 page1：iOS 交给 ContentView；mac 右栏随原样
    static func leave() {
        #if os(iOS)
        NotificationCenter.default.post(name: .xiaoyaAppLeaveRequested, object: nil)
        #endif
    }

    /// Tip「带我去桌面」：只 iOS 有桌面
    static func goDesktop() {
        #if os(iOS)
        NotificationCenter.default.post(name: .xiaoyaDesktopRequested, object: nil)
        #endif
    }

    /// iOS 交给 ContentView（page / 选中的 app 是它的状态）；mac 直接开右栏
    static func open() {
        #if os(iOS)
        NotificationCenter.default.post(name: .xiaoyaAppRequested, object: nil)
        #else
        IPadPanelLayout.shared.dockShown = true
        IPadPanelLayout.shared.open(toolId)
        #endif
    }
}

/// 舞台收不收（§12-D）。旧版只看聊天输入框的 inputFocused：钥匙卡（UIKit UITextField）、起名卡 / 挑名字卡（各自的 TextField）
/// 聚焦弹键盘时它一直是 false，舞台不收。现在键盘起来了也收；聊天框有焦点照旧收（外接键盘不弹软键盘也算）
enum XiaoyaStageFold {
    static func collapsed(chatFocused: Bool, keyboardUp: Bool) -> Bool {
        chatFocused || keyboardUp
    }
}

/// page2 / mac 右栏的「小芽」app
struct AssistantPanelView: View {
    @State private var engine: AssistantEngine

    /// engine 可注入（测试台用）；不传就用读写真实聊天记录的那个（全 App 共用的 shared）
    @MainActor
    init(engine: AssistantEngine? = nil) {
        _engine = State(initialValue: engine ?? .shared)
    }

    var body: some View {
        XiaoyaConversationView(engine: engine)
    }
}

struct XiaoyaConversationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    let engine: AssistantEngine
    @State private var input = ""
    /// 在看旧消息：流式输出不再把你拽回底部（只有亲手滚动才会变，见 XiaoyaScrollFollow）
    @State private var follow = XiaoyaScrollFollow()
    @FocusState private var inputFocused: Bool
    #if os(macOS)
    @Environment(\.isFrontmostTool) private var isFrontmostTool
    #else
    /// 键盘起来了（不管是哪个输入框弹的）：钥匙卡 / 起名卡 / 挑名字卡的输入框不走 inputFocused（§12-D）
    @State private var keyboardUp = false
    #endif
    @State private var showLedger = false
    @State private var showSettings = false
    /// 舞台边的灯泡：看过的 Tip（§11-4）
    @State private var showTips = false
    /// 点了马克笔概念词：弹释义 sheet
    @State private var glossTerm: XiaoyaGlossary.Term?
    @AppStorage("selectedFont") private var selectedFont = ""
    @AppStorage("fontScale") private var fontScale = 1.2
    /// 编辑以前的话：后面有盖过章的卡时先确认（D3）
    @State private var rewindPrompt: RewindPrompt?
    @AppStorage(XiaoyaStageTheme.storageKey) private var stageThemeRaw = XiaoyaStageTheme.mint.rawValue
    @State private var undoPrompt: UndoPrompt?
    @State private var undoError: String?
    /// 出口卡上的追加导入（世界书 / 预设）：选文件、导进 Ta 的楼层
    @State private var extraRequest: XiaoyaFloorExtraRequest?
    @Environment(\.chatMetrics) private var metrics

    private var skin: XiaoyaSkin { XiaoyaSkin.current(Theme.activeScheme) }
    /// 粟粟 09-26：舞台别搞复杂——弹键盘收起，收键盘展开。mac 没有软键盘，一直展开
    private var stageCollapsed: Bool {
        #if os(iOS)
        XiaoyaStageFold.collapsed(chatFocused: inputFocused, keyboardUp: keyboardUp)
        #else
        false
        #endif
    }
    private var stageTheme: XiaoyaStageTheme { XiaoyaStageTheme(rawValue: stageThemeRaw) ?? .mint }

    private var env: AssistantEnv? {
        // page1 的聊天页宿主只转注 provider / profile / preset 三个 manager（injectPagingEnv 教训），卡库从楼层管理器上拿
        guard let profileManager, let presetManager, let providerManager,
              let cardManager = cardManager ?? profileManager.characterCardManager else { return nil }
        return AssistantEnv(
            profileManager: profileManager,
            presetManager: presetManager,
            cardManager: cardManager,
            providerManager: providerManager,
            modelContext: modelContext
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
                .environment(\.xiaoyaSkin, skin)
                .overlay(alignment: .top) {
                    XiaoyaStageView(state: engine.stageState,
                                    name: AssistantPrompts.assistantName,
                                    englishName: AssistantPrompts.englishName,
                                    collapsed: stageCollapsed,
                                    theme: stageTheme,
                                    dark: Theme.activeScheme == .dark,
                                    local: engine.usingLocalBrain,
                                    onLedger: { showLedger = true },
                                    onSettings: { showSettings = true },
                                    helping: profileManager?.currentProfile,
                                    onTips: { showTips = true },
                                    tipPulse: engine.script.tipPulse,
                                    tipUnseen: engine.script.tips.unseenCount)
                }
            inputBar
        }
        .toolPageBackground(skin.paper)
        // 引导剧本的落地能力（建楼层 / 切楼层 / 推送）用这个面板的环境；没走完的引导在这里原地接上
        .onAppear { if let env { engine.script.attach(world: .live(env: env)) } }
        .modifier(XiaoyaFloorExtraImporter(request: $extraRequest, env: env, script: engine.script))
        // 本机模型不用时放掉（plan §6.2 B8）：面板关了、mac 右栏切到别的工具——主聊天还在用就不动；
        // iOS 进后台 / 内存警告由 LocalLLMService 自己停
        .onDisappear { LocalLLMService.shared.unloadIfIdle() }
        #if os(macOS)
        .onChange(of: isFrontmostTool) { _, front in
            if !front { LocalLLMService.shared.unloadIfIdle() }
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        #endif
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                XiaoyaSettingsTab()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 560)
            #endif
        }
        .confirmationDialog("改这句话", isPresented: Binding(
            get: { rewindPrompt != nil }, set: { if !$0 { rewindPrompt = nil } }
        ), titleVisibility: .visible, presenting: rewindPrompt) { prompt in
            Button("改") { performRewind(prompt.messageId) }
            Button("算了", role: .cancel) {}
        } message: { prompt in
            Text("这句往后的对话会删掉。后面有 \(prompt.stamped) 张已生效的提案，改动不会撤回，要撤去账本里撤。")
        }
        .sheet(isPresented: $showTips) {
            XiaoyaTipHistoryView(script: engine.script, skin: skin)
        }
        .sheet(item: $glossTerm) { term in
            XiaoyaGlossSheet(term: term)
        }
        .sheet(isPresented: $showLedger) {
            AssistantLedgerView(engine: engine, skin: skin) { actionId in
                showLedger = false
                requestUndo(actionId)
            }
        }
        .confirmationDialog(undoPrompt?.title ?? "", isPresented: Binding(
            get: { undoPrompt != nil }, set: { if !$0 { undoPrompt = nil } }
        ), titleVisibility: .visible, presenting: undoPrompt) { prompt in
            Button(prompt.force ? "覆盖并撤销" : "撤销", role: .destructive) { performUndo(prompt) }
            Button("算了", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .alert("没能撤销", isPresented: Binding(get: { undoError != nil }, set: { if !$0 { undoError = nil } })) {
            Button("好") {}
        } message: {
            Text(undoError ?? "")
        }
    }

    // MARK: - 消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if engine.messages.isEmpty, !engine.script.isActive { emptyState }
                    // §12-A 贴纸一屏最多两处、§12-B 只有最新那张 tip 带「懂了，下一条」：整列算一次
                    let decorations = XiaoyaStickerRule.decorations(engine.messages)
                    let latestTip = engine.messages.last { if case .tip = $0.card?.card { true } else { false } }?.id
                    ForEach(Array(engine.messages.enumerated()), id: \.element.id) { index, msg in
                        if let stamp = timeStamp(at: index) {
                            Text(stamp)
                                .font(.system(size: 11))
                                .tracking(0.5)
                                .foregroundStyle(skin.inkMuted)
                                .frame(maxWidth: .infinity)
                        }
                        messageRow(msg, decor: decorations[msg.id], latestTip: msg.id == latestTip).id(msg.id)
                    }
                    if engine.isGenerating {
                        streamingRow.id("streaming")
                    } else if engine.script.typing {
                        typingRow.id("script-typing")
                    }
                    // 底部锚点，顺带当底部留白：按到底之后离底距离是 0，不会反复触发按底
                    Color.clear.frame(height: 12).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
            }
            // 顶部固定留出展开舞台的高度：舞台是浮层，收放不改列表可视区
            .contentMargins(.top, XiaoyaStageView.expandedHeight + 14, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            // 点聊天区（文字 / 空白）收键盘；卡片上的按钮是子手势，优先级更高，不受影响
            .onTapGesture { inputFocused = false }
            // 打开时落在最新一条；对话还短时从顶部排起，不沉到底下留一大片空
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // 只有用户亲手滚动才改「在看旧消息」（XiaoyaScrollFollow）；内容长高 / 键盘压矮一律按回底部
            .onScrollPhaseChange { _, phase in
                follow.userScrolling(phase == .tracking || phase == .interacting || phase == .decelerating)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                max(0, geo.contentSize.height - geo.visibleRect.maxY)
            } action: { _, distance in
                let action = follow.geometryChanged(distance: distance)
                XiaoyaProbe.log("geo dist=\(Int(distance)) reading=\(follow.readingHistory) action=\(action)")
                if action == .pinToBottom { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            // 兜底：LazyVStack 下几何回调在布局变化时不一定发（feedback_swiftui_geometry_apis_lazyvstack_stuck）
            .onChange(of: engine.messages.count) { _, _ in
                if !follow.readingHistory { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: engine.streamingText) { _, _ in
                if !follow.readingHistory { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: engine.script.typing) { _, _ in
                if !follow.readingHistory { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private static let bottomAnchor = "xiaoya-bottom"

    private var emptyState: some View {
        herLine("\(Self.greeting())～今天想折腾点什么？写角色卡、改预设、管世界书、问我记不记得你的事，都可以找我。改东西之前我会先拿给你看，你盖了章才算数。")
    }

    @ViewBuilder
    private func messageRow(_ msg: AssistantChatMessage, decor: XiaoyaDecor?, latestTip: Bool) -> some View {
        if let state = msg.card {
            cardRow(msg, state, stamped: decor == .stamp, latestTip: latestTip)
        } else if msg.source == .handoff || msg.source == .divider {
            handoffDivider(msg.text)
        } else if msg.isUser {
            HStack {
                Spacer(minLength: 48)
                Text(msg.text)
                    .font(.system(size: Theme.F.body + 0.5))
                    .foregroundStyle(skin.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(skin.mint, in: UnevenRoundedRectangle(
                        topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18))
                    .contextMenu {
                        if engine.canRewind(msg.id) {
                            Button("编辑", systemImage: "pencil") { requestRewind(msg.id) }
                        }
                        Button("复制", systemImage: "doc.on.doc") { copy(msg.text) }
                    }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !msg.text.isEmpty {
                    if msg.source == .script {
                        scriptLine(msg, decor: decor)
                    } else {
                        herLine(msg.text)
                    }
                }
                ForEach(msg.actions) { action in
                    AssistantProposalCard(
                        action: action,
                        skin: skin,
                        canUndo: engine.canUndo(action),
                        beyondRetention: engine.isBeyondRetention(action),
                        stampDate: action.ledgerId.flatMap(engine.ledger.entry(id:))?.date ?? msg.createdAt,
                        onStamp: {
                            if let env { engine.stamp(action.id, in: LiveAssistantWorkspace(env: env)) }
                        },
                        onDiscard: { engine.discard(action.id) },
                        onUndo: { requestUndo(action.id) }
                    )
                }
            }
        }
    }

    /// 她说的话：左边一条墨线，不套气泡（像手帐里的批注）。跟主聊天正文一样：说完走 ChatMarkdownView，流式中走 StreamingTextView。
    /// 剧本台词（marked）：[[概念词]] 换成粗体 + 一笔马克笔，点词 = onMarkTap；sticker = 右上角外侧贴一张（§12-A / E）
    private func herLine(_ text: String, streaming: Bool = false, marked: Bool = false, sticker: XiaoyaStickerKind? = nil,
                         onMarkTap: ((String) -> Void)? = nil) -> some View {
        Group {
            if streaming {
                XiaoyaStreamingText(engine: engine)
            } else {
                // 跟主聊天正文同一套（MessageSegmentsView）：外观里选的字体 / 字号，assistant 字色
                ChatMarkdownView(text: marked ? XiaoyaGlossary.markdown(text) : text,
                                 fontName: selectedFont, scale: CGFloat(fontScale > 0 ? fontScale : 1.0),
                                 linkifyTickers: false, role: .assistant,
                                 extraHighlights: marked ? XiaoyaMarker.highlights(XiaoyaGlossary.words(in: text), dark: Theme.activeScheme == .dark) : [],
                                 onExtraHighlightTap: onMarkTap)
            }
        }
            .textSelection(.enabled)
            .padding(.leading, 12)
            .padding(.vertical, 1)
            .overlay(alignment: .leading) {
                Rectangle().fill(skin.ink).frame(width: 2)
            }
            .overlay(alignment: .topTrailing) {
                if let sticker {
                    XiaoyaPaperSticker(kind: sticker, seed: Self.stickerSeed(sticker), size: 40, rotation: Self.stickerTilt(sticker))
                        .offset(x: 38, y: -16)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 28)
    }

    /// 剧本台词：马克笔 + 角上贴纸；点马克笔词弹释义 sheet（不在词表的词点了不动）
    private func scriptLine(_ msg: AssistantChatMessage, decor: XiaoyaDecor?) -> some View {
        let sticker: XiaoyaStickerKind? = if case .line(let kind) = decor { kind } else { nil }
        return herLine(msg.text, marked: true, sticker: sticker) { word in glossTerm = XiaoyaGlossary.term(word) }
    }

    /// 小样里各贴纸用的种子 / 角度（同一种每次长一样）
    private static func stickerSeed(_ kind: XiaoyaStickerKind) -> UInt32 {
        switch kind {
        case .ques: 5
        case .excl: 9
        case .heart: 2
        default: 4
        }
    }

    private static func stickerTilt(_ kind: XiaoyaStickerKind) -> Double {
        switch kind {
        case .ques: 12
        case .excl: 10
        case .heart: -10
        default: 8
        }
    }

    // MARK: - 引导卡 / 交接分隔线（plan-onboarding-xiaoya-impl §4）

    @ViewBuilder
    private func cardRow(_ msg: AssistantChatMessage, _ state: XiaoyaCardState, stamped: Bool, latestTip: Bool) -> some View {
        if case .unsupported = state.card {
            if !msg.text.isEmpty { herLine(msg.text) }     // 新版的卡：只显示兜底那句
        } else {
            XiaoyaCardView(state: state, context: cardContext(latestTip: latestTip)) { answer in
                handleCardAnswer(msg.id, state, answer)
            }
            // 完成一步：卡角「啪」一枚星爆（§12-A）
            .overlay(alignment: .topTrailing) {
                if stamped {
                    XiaoyaStampSticker(fresh: engine.script.freshStamp == msg.id) { engine.script.stampPlayed(msg.id) }
                        .offset(x: 14, y: -24)
                }
            }
        }
    }

    private func cardContext(latestTip: Bool) -> XiaoyaCardContext {
        let pm = providerManager
        let commit: XiaoyaKeyCardModel.Commit = { draft, key, model in
            guard let pm else { return "" }
            return XiaoyaScriptRunner.commitKey(draft, key: key, model: model, providerManager: pm)
        }
        #if os(iOS)
        var context = XiaoyaCardContext(keyModel: engine.script.keyModel, commitKey: commit, userName: DefaultUserName.value(),
                                        applyPairing: XiaoyaPairOutcome.applying(providerManager: pm))
        #else
        var context = XiaoyaCardContext(keyModel: engine.script.keyModel, commitKey: commit, userName: DefaultUserName.value())
        #endif
        let floors = profileManager?.profiles ?? []
        context.takenNames = floors.flatMap { [$0.assistantName, $0.userName] }
        let current = profileManager?.currentProfile
        context.avatarData = { $0 == .user ? current?.userAvatarData : current?.assistantAvatarData }
        context.showsTipChips = latestTip
        return context
    }

    /// 追加导入是视图的事（要弹选文件）；其余交剧本
    private func handleCardAnswer(_ messageId: UUID, _ state: XiaoyaCardState, _ answer: XiaoyaCardAnswer) {
        if case .floorExtra(let extra) = answer, case .floorExit(let payload) = state.card {
            switch extra {
            case .chatHistory:
                engine.script.note(XiaoyaScriptLines.chatHistoryHint(payload.ta.name))
            case .worldBook, .preset:
                guard let taId = payload.ta.profileId else { return }
                extraRequest = XiaoyaFloorExtraRequest(extra: extra, taProfileId: taId, taName: payload.ta.name)
            }
            return
        }
        engine.script.answer(messageId, answer)
    }

    /// 「钥匙接好了 · 从这里起小芽用 M 说话」
    private func handoffDivider(_ text: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(skin.line).frame(height: 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(skin.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
            Rectangle().fill(skin.line).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    /// 剧本台词前的「在打字」
    private var typingRow: some View {
        XiaoyaBusyDots(color: skin.inkSoft)
            .padding(.leading, 12)
            .padding(.vertical, 6)
            .overlay(alignment: .leading) { Rectangle().fill(skin.ink).frame(width: 2) }
    }

    @ViewBuilder
    private var streamingRow: some View {
        if engine.streamingText.isEmpty {
            XiaoyaBusyDots(color: skin.inkSoft)
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .overlay(alignment: .leading) { Rectangle().fill(skin.ink).frame(width: 2) }
        } else {
            herLine(engine.streamingText, streaming: true)
        }
    }

    // MARK: - 撤销（先确认；这之后又被改过 → 再确认一次覆盖）

    private struct RewindPrompt: Identifiable {
        let messageId: UUID
        let stamped: Int
        var id: UUID { messageId }
    }

    private func requestRewind(_ messageId: UUID) {
        let stamped = engine.stampedCount(from: messageId)
        if stamped > 0 {
            rewindPrompt = RewindPrompt(messageId: messageId, stamped: stamped)
        } else {
            performRewind(messageId)
        }
    }

    private func performRewind(_ messageId: UUID) {
        guard let text = engine.rewind(to: messageId) else { return }
        input = text
        inputFocused = true
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private struct UndoPrompt: Identifiable {
        let id = UUID()
        let actionId: UUID
        let title: String
        let message: String
        let force: Bool
    }

    private func requestUndo(_ actionId: UUID) {
        let title = engine.messages.lazy.flatMap(\.actions).first { $0.id == actionId }?.change?.title ?? ""
        undoPrompt = UndoPrompt(actionId: actionId, title: "撤销\(title)？", message: "会把这笔改动还原成盖章之前的样子。", force: false)
    }

    private func performUndo(_ prompt: UndoPrompt) {
        guard let env else { return }
        switch engine.undo(prompt.actionId, in: LiveAssistantWorkspace(env: env), force: prompt.force) {
        case .done:
            break
        case .conflict(let why):
            undoPrompt = UndoPrompt(actionId: prompt.actionId, title: "还要撤销吗？", message: why, force: true)
        case .failed(let why):
            undoError = why
        }
    }

    // MARK: - 输入条（粟粟 09-26：照 Page1 主聊天输入框——iOS 玻璃胶囊、mac 圆角框，发送钮收在框内右下）

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !quickChips.isEmpty { chipRow }
            inputField
        }
        .padding(.horizontal, metrics.composerInsetH)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    /// 小白线「跟我说句话」的三个建议；引导走完后常驻召回 chips（配钥匙 / 建一个 Ta / 连电脑 / 导卡）
    private var quickChips: [String] {
        let script = engine.script
        if !script.suggestions.isEmpty { return engine.isGenerating ? [] : script.suggestions }
        return script.showsRecallChips && !inputFocused ? XiaoyaScriptLines.recallChips : []
    }

    /// 放不下就折行（不用横向 ScrollView：里面的按钮会被滚动手势吞）
    private var chipRow: some View {
        XiaoyaFlowRow(spacing: 6, lineSpacing: 6) {
            ForEach(quickChips, id: \.self) { chip in
                XiaoyaChip(title: chip, on: false) { sendChip(chip) }
            }
        }
        .padding(.horizontal, 2)
        .environment(\.xiaoyaSkin, skin)
    }

    private func sendChip(_ text: String) {
        guard let env, !engine.isGenerating else { return }
        follow.userSent()
        engine.send(text, env: env)
    }

    private var inputLocked: Bool { engine.script.locksInput }

    @ViewBuilder
    private var inputField: some View {
        let field = TextField(engine.script.inputPlaceholder ?? "跟\(AssistantPrompts.assistantName)说点什么…", text: $input, axis: .vertical)
            .textFieldStyle(.plain)
            .disabled(inputLocked)
            .font(.system(size: Theme.F.body + 0.5))
            .foregroundColor(Theme.textPrimary)
            .lineLimit(1...6)
            .focused($inputFocused)
            .onSubmit { send() }
        #if os(macOS)
        HStack(alignment: .bottom, spacing: 8) {
            field
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            sendButton
        }
        .padding(10)
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(inputFocused ? Theme.branchIndicator : ShellStyle.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
        #else
        HStack(alignment: .bottom, spacing: 4) {
            field
                .padding(.leading, 16)
                .padding(.vertical, 12)
            sendButton
                .padding(.trailing, 6)
                .padding(.bottom, 6)
        }
        .shellGlass(in: .rect(cornerRadius: 20), tint: 0.15, interactive: true)
        // 同 Page1：玻璃 .interactive() 真机点穿有延迟，外层抢焦点
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
        #endif
    }

    /// 同 Page1 发送钮三态：有字 = 薄荷实心 + 白箭头；没字 = 淡灰箭头不画底；她在说 = 红底停止
    private var sendButton: some View {
        Button {
            engine.isGenerating ? engine.cancel() : send()
        } label: {
            Image(systemName: engine.isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: metrics.sendIconSize, weight: .semibold))
                .foregroundColor(canSend || engine.isGenerating ? .white : Theme.textMuted.opacity(0.55))
                .frame(width: metrics.sendFrame, height: metrics.sendFrame)
                .background(Circle().fill(engine.isGenerating ? Theme.danger
                                          : canSend ? Theme.branchIndicator : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !engine.isGenerating)
        .accessibilityLabel(engine.isGenerating ? "停止" : "发送")
        .animation(.easeOut(duration: 0.15), value: canSend)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !engine.isGenerating && !inputLocked
    }

    private func send() {
        guard let env, canSend else { return }
        let text = input
        input = ""
        follow.userSent()
        engine.send(text, env: env)
    }

    // MARK: - 时间

    /// 第一条、跨天、或跟上一条隔了 30 分钟以上才标时间
    private func timeStamp(at index: Int) -> String? {
        let date = engine.messages[index].createdAt
        if index > 0 {
            let prev = engine.messages[index - 1].createdAt
            if Calendar.current.isDate(prev, inSameDayAs: date), date.timeIntervalSince(prev) < 30 * 60 { return nil }
        }
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "今天 \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "昨天 \(time)" }
        return date.formatted(.dateTime.month().day()) + " " + time
    }

    static func greeting(now: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<11: "早上好"
        case 11..<13: "中午好"
        case 13..<18: "下午好"
        case 18..<23: "晚上好"
        default: "这么晚还没睡"
        }
    }
}
