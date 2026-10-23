import SwiftUI
import SwiftData

// MARK: - 小芽助手面板 v2（plan-小芽-v2 §3.3；设计 docs/design-小芽-v2.html §01 A 舞台头）
// 舞台（大表情 + 名字 + 状态）浮在消息列表上方；她的话用一条墨线引出、不套气泡，你的话是浅薄荷气泡。
// 离底部远了（在翻旧消息）舞台收成一行，回到底部再展开。

struct AssistantPanelView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(PresetManager.self) private var presetManager: PresetManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    @State private var engine: AssistantEngine
    /// 名字 / 英文名 / 占位文字读 AssistantPrompts（直读 UserDefaults）。B-8（plan-paging-decouple B-0 表 1）：翻页不再重交 rootView 后，这个值要自带失效通道——声明即订阅
    @AppStorage(AssistantPrompts.nameKey) private var xiaoyaNameSubscription = ""
    @AppStorage("settings.proMode") private var proModeSubscription = false

    /// engine 可注入（测试台用）；不传就用读写真实聊天记录的那个
    @MainActor
    init(engine: AssistantEngine? = nil) {
        _engine = State(initialValue: engine ?? AssistantEngine())
    }
    @State private var input = ""
    /// 在看旧消息：流式输出不再把你拽回底部（只有亲手滚动才会变，见 XiaoyaScrollFollow）
    @State private var follow = XiaoyaScrollFollow()
    @FocusState private var inputFocused: Bool
    #if os(macOS)
    @Environment(\.isFrontmostTool) private var isFrontmostTool
    #endif
    @State private var showLedger = false
    @State private var showSettings = false
    @AppStorage("selectedFont") private var selectedFont = ""
    @AppStorage("fontScale") private var fontScale = 1.2
    /// 编辑以前的话：后面有盖过章的卡时先确认（D3）
    @State private var rewindPrompt: RewindPrompt?
    @AppStorage(XiaoyaStageTheme.storageKey) private var stageThemeRaw = XiaoyaStageTheme.mint.rawValue
    @State private var undoPrompt: UndoPrompt?
    @State private var undoError: String?
    @Environment(\.chatMetrics) private var metrics

    private var skin: XiaoyaSkin { XiaoyaSkin.current(Theme.activeScheme) }
    /// 粟粟 09-26：舞台别搞复杂——弹键盘收起，收键盘展开。mac 没有软键盘，一直展开
    private var stageCollapsed: Bool {
        #if os(iOS)
        inputFocused
        #else
        false
        #endif
    }
    private var stageTheme: XiaoyaStageTheme { XiaoyaStageTheme(rawValue: stageThemeRaw) ?? .mint }

    private var env: AssistantEnv? {
        guard let profileManager, let presetManager, let cardManager, let providerManager else { return nil }
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
                .overlay(alignment: .top) {
                    XiaoyaStageView(state: engine.stageState,
                                    name: AssistantPrompts.assistantName,
                                    englishName: AssistantPrompts.englishName,
                                    collapsed: stageCollapsed,
                                    theme: stageTheme,
                                    dark: Theme.activeScheme == .dark,
                                    local: engine.usingLocalBrain,
                                    onLedger: { showLedger = true },
                                    onSettings: { showSettings = true })
                }
            inputBar
        }
        .toolPageBackground(skin.paper)
        // 本机模型不用时放掉（plan §6.2 B8）：面板关了、mac 右栏切到别的工具——主聊天还在用就不动；
        // iOS 进后台 / 内存警告由 LocalLLMService 自己停
        .onDisappear { LocalLLMService.shared.unloadIfIdle() }
        #if os(macOS)
        .onChange(of: isFrontmostTool) { _, front in
            if !front { LocalLLMService.shared.unloadIfIdle() }
        }
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
                    if engine.messages.isEmpty { emptyState }
                    ForEach(Array(engine.messages.enumerated()), id: \.element.id) { index, msg in
                        if let stamp = timeStamp(at: index) {
                            Text(stamp)
                                .font(.system(size: 11))
                                .tracking(0.5)
                                .foregroundStyle(skin.inkMuted)
                                .frame(maxWidth: .infinity)
                        }
                        messageRow(msg).id(msg.id)
                    }
                    if engine.isGenerating {
                        streamingRow.id("streaming")
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
        }
    }

    private static let bottomAnchor = "xiaoya-bottom"

    private var emptyState: some View {
        herLine("\(Self.greeting())～今天想折腾点什么？写角色卡、改预设、管世界书、问我记不记得你的事，都可以找我。改东西之前我会先拿给你看，你盖了章才算数。")
    }

    @ViewBuilder
    private func messageRow(_ msg: AssistantChatMessage) -> some View {
        if msg.isUser {
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
                        if !engine.isGenerating {
                            Button("编辑", systemImage: "pencil") { requestRewind(msg.id) }
                        }
                        Button("复制", systemImage: "doc.on.doc") { copy(msg.text) }
                    }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !msg.text.isEmpty { herLine(msg.text) }
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

    /// 她说的话：左边一条墨线，不套气泡（像手帐里的批注）。跟主聊天正文一样：说完走 ChatMarkdownView，流式中走 StreamingTextView
    private func herLine(_ text: String, streaming: Bool = false) -> some View {
        Group {
            if streaming {
                XiaoyaStreamingText(engine: engine)
            } else {
                // 跟主聊天正文同一套（MessageSegmentsView）：外观里选的字体 / 字号，assistant 字色
                ChatMarkdownView(text: text, fontName: selectedFont, scale: CGFloat(fontScale > 0 ? fontScale : 1.0),
                                 linkifyTickers: false, role: .assistant)
            }
        }
            .textSelection(.enabled)
            .padding(.leading, 12)
            .padding(.vertical, 1)
            .overlay(alignment: .leading) {
                Rectangle().fill(skin.ink).frame(width: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 28)
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
        inputField
            .padding(.horizontal, metrics.composerInsetH)
            .padding(.top, 6)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var inputField: some View {
        let field = TextField("跟\(AssistantPrompts.assistantName)说点什么…", text: $input, axis: .vertical)
            .textFieldStyle(.plain)
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
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !engine.isGenerating
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
