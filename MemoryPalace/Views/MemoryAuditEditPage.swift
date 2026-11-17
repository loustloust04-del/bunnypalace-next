import MemoryCore
import SwiftUI
import SwiftData

// MARK: - 一条 C2 原子事实唯一的详情页（粟粟 11-15「为什么记忆看一个条目在记忆-审计台和记忆-记忆是两回事」）
// 记忆页列表 / 常驻页 / 「想起来了」卡 / 整理台 Edit / mac 设置 点一条、记忆页的 ＋，都开这一张（`memoryEntryPage`）。
// 三层：一眼 =「说的是谁 ·」+ 正文，直接改；点开再收 = 卡底一排 chip（About / From / 置信度 / Importance / 标签 / Source / Why），
// 点哪颗从卡底升起一块玻璃托盘只管那一项；⋯ 里 = 这条的记录、当文件打开、Pin、Delete。顶上 Cancel / Save。
// 两档字：16 = 正文 / 按钮 / 托盘选项 / 输入框（`m.sectionHeader`），13 = chip / 小字（`m.secondary`）；两档圆角：卡 / 托盘 16，其余胶囊；点按区 44。
// 旧的五个类别当标签显示（「事实」不出），只是显示层：存回去还是 `category`。
// 存盘 / 记一笔 / 算 Approve / 改过记 100 都在 `MemoryEntryActions`（Save **不钉**，钉不钉只看 ⋯ 里的 Pin）。

struct MemoryAuditEditPage: View {
    /// nil = 新加一条
    let memory: Memory?
    let profileId: String
    /// 去原对话（跳到出处那条消息）；nil = 没有出处窗口 / 这里跳不了
    var onJump: (() -> Void)? = nil
    /// 做完的一笔（存了 / 删了 / 钉了 / 加了）交回开它的地方
    var onEvent: (MemoryEntryEvent) -> Void = { _ in }

    enum Trait: Hashable { case about, from, confidence, importance, tags, detail, source, why }
    private enum Field: Hashable { case about, tag, confidence }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m
    @Environment(\.modelContext) private var modelContext
    /// 拿不到（mac 设置窗是另一个窗口）就不出「当文件打开」
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    /// 出处那条消息现在的原文、窗口名、C2 整理给的理由、候选：进页面时取一次
    @State private var sourceText: String?
    @State private var sourceMessages: [MemorySourceMessage] = []
    @State private var windowTitle: String?
    @State private var dreamNote: FragmentDreamNotes.Note?
    /// 这层楼活着的条目上出现过的标签 / 「说的是谁」，多→少；Tags / About 托盘里当候选
    @State private var tagPool: [String] = []
    @State private var subjectPool: [String] = []
    @State private var text: String
    @State private var category: String
    @State private var importance: Int?
    @State private var subject: String
    @State private var speaker: String?
    @State private var confidence: Int?
    /// 她在 Confidence 托盘里点过 Adjust、亲手定数（以她定的为准）；Auto 放回自动
    @State private var manualConfidence = false
    @State private var adjusting = false
    @State private var tags: [String]
    @State private var newTag = ""
    @State private var open: Trait?
    @FocusState private var focus: Field?
    @State private var error: String?
    /// 新加的这条要不要钉（⋯ 里的 Pin）
    @State private var pinNew = false
    @State private var showLog = false
    /// 详细度（`CardDetailRewrite`）：现在是哪一档（从审计日志推，进页面时后台读一次）、找没找到当时的原文、用哪个模型、
    /// 等她确认的那一档、正在跑的那一档、跑好了等她 Save 的那一份（只在编辑框里，Save 才落库）
    @State private var detailState: CardDetailRewrite.State?
    @State private var detailGathered: CardDetailRewrite.Gathered?
    @State private var detailLoading = false
    @State private var detailRoute: CardDetailRewrite.Route?
    @State private var detailAsk: CardDetail.Level?
    @State private var detailRunning: CardDetail.Level?
    @State private var detailDraft: CardDetailRewrite.Draft?
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    init(memory: Memory?, profileId: String, onJump: (() -> Void)? = nil, onEvent: @escaping (MemoryEntryEvent) -> Void = { _ in }) {
        self.memory = memory
        self.profileId = profileId
        self.onJump = onJump
        self.onEvent = onEvent
        let base = memory.map(MemoryAudit.Edit.init) ?? MemoryAudit.Edit()
        _text = State(initialValue: base.text)
        _category = State(initialValue: base.category)
        _importance = State(initialValue: base.importance)
        _subject = State(initialValue: base.subject ?? "")
        _speaker = State(initialValue: base.speaker)
        _confidence = State(initialValue: base.confidence)
        _tags = State(initialValue: base.keywords)
    }

    /// 比「改过没有」的底：卡上现在的值；新加的是空草稿
    private var base: MemoryAudit.Edit { memory.map(MemoryAudit.Edit.init) ?? MemoryAudit.Edit() }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var shownTags: [String] { MemoryAuditTraits.shownTags(category: category, keywords: tags) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 6) {
                if let error {
                    Text(error)
                        .font(m.secondary)
                        .foregroundColor(Theme.danger)
                        .lineLimit(2)
                        .padding(.horizontal, 4)
                }
                card
            }
            .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(Theme.sidebarBg.ignoresSafeArea())
            .animation(.easeOut(duration: 0.18), value: open)
            .task { load() }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(MemoryAuditStyle.pageIsDark ? .dark : nil, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Text("Cancel").font(m.sectionHeader.weight(.medium))
                    }
                    .foregroundStyle(MemoryAuditStyle.onPage)
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("C2 原子事实").font(m.sectionHeader)
                        if let state = stateLine {
                            Text(state)
                                .font(m.secondary)
                                .opacity(0.72)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(MemoryAuditStyle.onPage)
                }
                ToolbarItem(placement: .primaryAction) { moreMenu }
                ToolbarItem(placement: .confirmationAction) {
                    // 墨色实心（页面底是浅薄荷时不放薄荷实心钮，免得绿套绿）
                    Button(action: save) {
                        Text("Save")
                            .font(m.sectionHeader)
                            .foregroundStyle(MemoryAuditStyle.offPage)
                    }
                    .auditGlassButton(prominent: true)
                    .tint(MemoryAuditStyle.onPage)
                    .disabled(trimmed.isEmpty || detailRunning != nil)
                }
            }
        }
        .sheet(isPresented: $showLog) {
            MemoryWriteLogSheet(profileId: profileId, card: memory?.id)
                .environment(\.settingsMetrics, m)
        }
        .alert(CardDetailRewrite.name, isPresented: Binding(get: { detailAsk != nil }, set: { if !$0 { detailAsk = nil } }),
               presenting: detailAsk) { level in
            Button("Cancel", role: .cancel) { }
            Button("Rewrite") { runDetail(level) }
        } message: { level in
            Text(detailAskText(level))
        }
        #if os(macOS)
        .frame(width: 520, height: 640)
        #endif
    }

    /// 标题下那一行：Draft / Archive（钉着的带 · Pinned）
    private var stateLine: String? {
        guard let memory else { return pinNew ? "Pinned" : nil }
        return MemoryCardFolder.stateLabel(memory) + (memory.isUserExplicit ? " · Pinned" : "")
    }

    private func load() {
        let all = SwiftDataMemoryStore().listAll(profileId: profileId, context: modelContext)
        tagPool = Self.tagRanking(all)
        subjectPool = Self.subjectRanking(all)
        guard let memory else { return }
        let pid = memory.profileId
        sourceText = MemoryConversationLink.sourceText(of: memory, profileId: pid, context: modelContext)
        sourceMessages = MemoryConversationLink.sourceMessages(of: memory, profileId: pid, context: modelContext)
        if let cid = memory.sourceConversationId {
            windowTitle = MemoryAudit.windowTitles(ids: [cid], profileId: pid,
                                                   source: SwiftDataConversationSource(container: modelContext.container))[cid]
        }
        let root = FileLibraryStore.memoryRoot(profileId: pid)
        dreamNote = FragmentDreamNotes.load(memoryRoot: root)[memory.id]
        let id = memory.id
        Task {
            let states = await Task.detached(priority: .userInitiated) { CardDetailRewrite.states(MemoryAuditLog.load(memoryRoot: root)) }.value
            detailState = states[id]
        }
    }

    // MARK: - ⋯：这条的记录 / 当文件打开 / Pin / Delete（新加的只有 Pin）

    private var moreMenu: some View {
        Menu {
            if let memory {
                Button { showLog = true } label: { Label("这条的记录", systemImage: "clock") }
                if navigator != nil {
                    Button { openAsFile(memory) } label: { Label("当文件打开", systemImage: "doc.text") }
                }
                Button { togglePin(memory) } label: {
                    Label(memory.isUserExplicit ? "Unpin" : "Pin", systemImage: memory.isUserExplicit ? "pin.slash" : "pin")
                }
                Divider()
                Button(role: .destructive) { delete(memory) } label: { Label("Delete", systemImage: "trash") }
            } else {
                Toggle(isOn: $pinNew) { Label("Pin", systemImage: "pin") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(m.sectionHeader.weight(.medium))
                .foregroundStyle(MemoryAuditStyle.onPage)
                .accessibilityLabel("More")
        }
        .menuIndicator(.hidden)
    }

    /// 跳到文件库 › 记忆 里这条那份 md（她 11-14 定的「对外是文件夹」）
    private func openAsFile(_ memory: Memory) {
        guard let path = MemoryCardFolder.entries(profileId: memory.profileId, context: modelContext)
            .first(where: { $0.card == memory.id })?.path else { return }
        dismiss()
        navigator?.pendingTarget = .init(tool: "fileLibrary", id: path)
    }

    private func togglePin(_ memory: Memory) {
        let out = MemoryEntryActions.togglePin([memory], profileId: memory.profileId, context: modelContext)
        if let e = out.error { error = e; return }
        error = nil
        if out.entry != nil { onEvent(MemoryEntryEvent(kind: .pinned, card: memory.id, outcome: out)) }
    }

    private func delete(_ memory: Memory) {
        let out = MemoryEntryActions.trash([memory], profileId: memory.profileId, context: modelContext)
        if let e = out.error { error = e; return }
        dismiss()
        onEvent(MemoryEntryEvent(kind: .deleted, card: memory.id, outcome: out))
    }

    // MARK: - 卡：正文 + 卡底 chips；托盘开着时 chips 原地让出来，托盘盖在卡底

    private var card: some View {
        VStack(spacing: 0) {
            if let lead = MemoryEntryLine.lead(subject: subject, content: text) {
                Button { open == .about ? closeTray() : openTray(.about) } label: {
                    Text((lead + MemoryEntryLine.separator).trimmingCharacters(in: .whitespaces))
                        .font(m.sectionHeader.weight(.regular))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .accessibilityLabel("About")
                .accessibilityValue(lead)
            }
            editor
                .padding(.horizontal, 13)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 托盘开着时点正文：收托盘（键盘由正文自己弹）
                .simultaneousGesture(TapGesture().onEnded { if open != nil { closeTray() } }, including: open == nil ? .none : .all)
                // 正在重写：正文先别动（结果会放进这里）
                .allowsHitTesting(detailRunning == nil)
                .opacity(detailRunning == nil ? 1 : 0.5)
            if let memory {
                MemoryAuditPageNotice(memory: memory)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
            }
            Rectangle()
                .fill(Self.line)
                .frame(height: 1)
            FlowLayout(spacing: 4, lineSpacing: 0) {
                chip(.about)
                chip(.from)
                chip(.confidence)
                chip(.importance)
                chip(.tags)
                if memory != nil { chip(.detail) }
                if hasSource { chip(.source) }
                if hasWhy { chip(.why) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .opacity(open == nil ? 1 : 0)
            .allowsHitTesting(open == nil)
            .accessibilityHidden(open != nil)
        }
        .background {
            RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous)
                .fill(Theme.mainBg)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        }
        .overlay(alignment: .bottom) {
            if let open {
                tray(open)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// 有原话或者跳得过去才出 Source
    private var hasSource: Bool {
        memory.map { MemorySourceTray.has($0, live: sourceText, canJump: onJump != nil) } ?? false
    }

    /// Open in chat：先关这页再跳
    private var openInChat: (() -> Void)? {
        guard let onJump else { return nil }
        return {
            dismiss()
            onJump()
        }
    }

    /// C2 整理给这条下过结论、写了理由才出 Why
    private var hasWhy: Bool { MemoryWhyTray.shows(dreamNote, for: memory) }

    @ViewBuilder
    private var editor: some View {
        #if os(iOS)
        ExpandInputTextView(text: $text, uiFont: .systemFont(ofSize: Theme.F.sectionHeader), autoFocus: memory == nil)
        #else
        TextEditor(text: $text)
            .font(m.sectionHeader.weight(.regular))
            .scrollContentBackground(.hidden)
        #endif
    }

    private static var fill: Color { MemoryEntryChip.fill }
    private static var line: Color { MemoryEntryChip.line }

    // MARK: - chips

    private func look(_ t: Trait) -> MemoryEntryChip.Look {
        switch t {
        case .about: return MemoryAudit.cleaned(subject) == nil ? .empty : .filled
        case .from: return MemoryAuditTraits.from(speaker, assistant: assistantName) == nil ? .empty : .filled
        case .confidence:
            if !manualConfidence && edited { return .mine }
            return confidence == nil && !manualConfidence ? .empty : .filled
        case .importance: return importance == nil ? .empty : .filled
        case .tags: return shownTags.isEmpty ? .empty : .filled
        case .detail: return shownLevel == nil ? .empty : .filled
        case .source, .why: return .filled
        }
    }

    private func chipText(_ t: Trait) -> String {
        switch t {
        case .about: return MemoryChipText.about(subject) ?? "+ About"
        case .from: return MemoryAuditTraits.fromChip(speaker, assistant: assistantName) ?? "+ From"
        case .confidence:
            if manualConfidence { return confidence.map { "You set \($0)%" } ?? "You cleared" }
            if edited { return "You edited" }
            return MemoryChipText.sure(confidence) ?? "+ Confidence"
        case .importance: return MemoryChipText.importance(importance) ?? "+ Importance"
        case .tags: return MemoryChipText.tags(shownTags) ?? "+ Tags"
        case .detail: return shownLevel.map(CardDetailRewrite.label) ?? CardDetailRewrite.name
        case .source: return memory.map(MemoryChipText.source) ?? "Source"
        case .why: return "Why"
        }
    }

    private func chipName(_ t: Trait) -> String {
        switch t {
        case .about: return "About"
        case .from: return "From"
        case .confidence: return "Confidence"
        case .importance: return "Importance"
        case .tags: return "Tags"
        case .detail: return CardDetailRewrite.name
        case .source: return "Source"
        case .why: return "Why"
        }
    }

    private func chip(_ t: Trait) -> some View {
        MemoryEntryChip(text: chipText(t), look: look(t), changed: changed(t), name: chipName(t)) {
            open == t ? closeTray() : openTray(t)
        }
    }

    // MARK: - 改过没有（只做显示：真正存什么、记不记 100 都在 `MemoryAudit.apply`）

    private func changed(_ t: Trait) -> Bool {
        let base = base
        switch t {
        case .about: return MemoryAudit.cleaned(subject) != MemoryAudit.cleaned(base.subject)
        case .from: return speaker != base.speaker
        case .confidence: return manualConfidence && confidence != base.confidence
        case .importance: return importance != base.importance
        case .tags: return category != base.category || MemoryAudit.cleanedTags(tags) != MemoryAudit.cleanedTags(base.keywords)
        case .detail: return detailDraft != nil
        case .source, .why: return false
        }
    }

    /// 她改了正文或任何一项（置信度自己除外）：Save 时按 `MemoryAudit.handEditedConfidence` 存。
    /// 编辑框里是详细度重写好、她没再动的字，不算她改的
    private var edited: Bool {
        (trimmed != base.text && trimmed != detailDraft?.text) || [Trait.about, .from, .importance, .tags].contains(where: changed)
    }

    /// 卡上现在是哪一档：日志里推出来的；日志里没有、她也没亲手改过正文 = 写手写的，算适中；她改过 = 不算哪一档
    private var savedLevel: CardDetail.Level? {
        guard let memory else { return nil }
        if let detailState { return detailState.level }
        return memory.userEditedAt == nil ? .medium : nil
    }

    /// 托盘里亮的那一格：草稿里重写好的那一档，没有就卡上现在那一档
    private var shownLevel: CardDetail.Level? { detailDraft?.level ?? savedLevel }

    // MARK: - 托盘

    private func openTray(_ t: Trait) {
        commitPendingTag()
        adjusting = false
        open = t
        // 没有输入框的托盘收键盘，给卡让地方；About / Tags 的输入框出现时自己聚焦
        if t != .about && t != .tags { dismissKeyboard() }
        if t == .detail { prepareDetail() }
    }

    private func closeTray() {
        commitPendingTag()
        open = nil
        adjusting = false
        focus = nil
    }

    /// 托盘里打了字没回车就走（Done / 换托盘）：也算加上
    private func commitPendingTag() {
        guard !newTag.isEmpty else { return }
        (tags, category) = Self.adding(newTag, to: tags, category: category)
        newTag = ""
    }

    private func dismissKeyboard() {
        focus = nil
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    @ViewBuilder
    private func tray(_ t: Trait) -> some View {
        Group {
            switch t {
            case .about: aboutTray
            case .from: fromTray
            case .confidence: confidenceTray
            case .importance: importanceTray
            case .tags: tagsTray
            case .detail: detailTray
            case .source:
                if let memory {
                    MemorySourceTray(memory: memory, windowTitle: windowTitle, live: sourceText, messages: sourceMessages,
                                     onJump: openInChat, onDone: closeTray)
                }
            case .why:
                if let dreamNote { MemoryWhyTray(note: dreamNote, onDone: closeTray) }
            }
        }
        .memoryTray()
    }

    private func trayHead<Extra: View>(_ title: String, @ViewBuilder extra: @escaping () -> Extra) -> some View {
        MemoryTrayHead(title: title, onDone: closeTray, extra: extra)
    }

    private func trayHead(_ title: String) -> some View {
        MemoryTrayHead(title: title, onDone: closeTray)
    }

    private func trayButton(_ title: String, plain: Bool, height: CGFloat = 44, action: @escaping () -> Void) -> some View {
        MemoryTrayButton(title: title, plain: plain, height: height, action: action)
    }

    /// 胶囊输入框（44 高，浅底）
    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .frame(height: 44)
            .background(Self.fill, in: Capsule())
    }

    /// 候选：描边胶囊、灰字（看得见的 32，点按区 44）
    private func suggestion(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(m.secondary)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(Capsule().strokeBorder(Self.line, lineWidth: 1))
                .frame(height: 44)
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    /// 一行候选：从排在前面的挑这一行放得下的（不滚动：横滑里点按会被吞）
    @ViewBuilder
    private func suggestionRow(_ items: [String], title: @escaping (String) -> String, label: @escaping (String) -> String,
                               pick: @escaping (String) -> Void) -> some View {
        if !items.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach(Array((1...items.count).reversed()), id: \.self) { n in
                    HStack(spacing: 6) {
                        ForEach(items.prefix(n), id: \.self) { s in
                            suggestion(title(s), label: label(s)) { pick(s) }
                        }
                    }
                }
            }
        }
    }

    // MARK: About

    private var aboutTray: some View {
        VStack(alignment: .leading, spacing: 4) {
            trayHead("About — who it’s about")
            field {
                TextField("Name", text: $subject)
                    .textFieldStyle(.plain)
                    .font(m.sectionHeader.weight(.regular))
                    .focused($focus, equals: .about)
                    .onSubmit { closeTray() }
                    .onAppear { focus = .about }
                if !subject.isEmpty { clearButton("Clear About") { subject = "" } }
            }
            suggestionRow(Self.subjectSuggestions(subjectPool, typed: subject, original: base.subject),
                          title: { $0 }, label: { "About \($0)" }) { name in
                subject = name
                closeTray()
            }
        }
    }

    private func clearButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(m.sectionHeader)
                .foregroundColor(Theme.textMuted)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    // MARK: From

    private var fromTray: some View {
        VStack(alignment: .leading, spacing: 0) {
            trayHead("From — who said it")
            // 认得的三种 + 卡上原来的别的词（`speakerOptions`），Not set 放最后
            let options = Self.speakerOptions(current: base.speaker).filter { $0 != nil } + [nil]
            ForEach(Array(options.enumerated()), id: \.offset) { i, s in
                if i > 0 { Rectangle().fill(Self.line).frame(height: 1) }
                option(MemoryAuditTraits.from(s, assistant: assistantName) ?? "Not set", on: speaker == s) {
                    speaker = s
                    // 选完稍等一下自动收回（看得见勾落在哪）
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(220))
                        if open == .from { closeTray() }
                    }
                }
            }
        }
    }

    private func option(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(m.secondary.weight(.bold))
                    .opacity(on ? 1 : 0)
                    .frame(width: 20)
                Text(title)
                    .font(on ? m.sectionHeader : m.sectionHeader.weight(.regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 4)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Confidence（平时一句话；滑杆藏在 Adjust 后面）

    @ViewBuilder
    private var confidenceTray: some View {
        if adjusting {
            VStack(alignment: .leading, spacing: 2) {
                trayHead("Confidence") { trayButton("Auto", plain: true, action: autoConfidence) }
                HStack(spacing: 8) {
                    TextField("—", text: Binding(
                        get: { confidence.map(String.init) ?? "" },
                        set: { confidence = Self.confidence(from: $0) }))
                        .textFieldStyle(.plain)
                        .font(m.sectionHeader)
                        .multilineTextAlignment(.center)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .focused($focus, equals: .confidence)
                        .onSubmit { closeTray() }
                        .frame(width: 64, height: 44)
                        .background(Self.fill, in: Capsule())
                        .accessibilityLabel("Confidence number")
                    Text("% sure")
                        .font(m.sectionHeader.weight(.regular))
                        .foregroundColor(Theme.textSecondary)
                }
                Slider(value: Binding(
                    get: { Double(confidence ?? 50) },
                    set: { confidence = Int($0.rounded()) }), in: 0...100, step: 1)
                    .tint(Theme.textPrimary)
                    .frame(height: 44)
                    .accessibilityLabel("Confidence")
                HStack {
                    Text("0")
                    Spacer()
                    Text("50")
                    Spacer()
                    Text("100")
                }
                .font(m.secondary)
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                trayHead("Confidence")
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(confidenceSummary.title).font(m.sectionHeader)
                        Text(confidenceSummary.detail)
                            .font(m.secondary)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if manualConfidence { trayButton("Auto", plain: true, action: autoConfidence) }
                    trayButton("Adjust", plain: true) {
                        if !manualConfidence {
                            manualConfidence = true
                            confidence = edited ? MemoryAudit.handEditedConfidence : base.confidence
                        }
                        adjusting = true
                    }
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 44)
            }
        }
    }

    /// 这张存成多少，一句话说清（原型 Confidence 托盘第一层）
    private var confidenceSummary: (title: String, detail: String) {
        if manualConfidence {
            return (confidence.map { "\($0)% sure" } ?? "Not set", "You set this yourself.")
        }
        if edited {
            return ("Saves as \(MemoryAudit.handEditedConfidence)% sure", "You changed this card, so it counts as certain.")
        }
        if let c = base.confidence { return ("\(c)% sure", "How sure the writer was.") }
        return ("Not rated", "The writer didn’t rate this card.")
    }

    private func autoConfidence() {
        manualConfidence = false
        adjusting = false
        confidence = base.confidence
        if focus == .confidence { focus = nil }
    }

    // MARK: Importance

    private var importanceTray: some View {
        VStack(alignment: .leading, spacing: 0) {
            trayHead("Importance")
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { v in
                    segment("\(v)", on: importance == v, outlined: false) { importance = v }
                        .accessibilityLabel("Importance \(v)")
                }
                // 定过的撤不回「没定」（`MemoryAudit.Edit.importance`）：原来没定的才给 Not set
                if base.importance == nil {
                    segment("Not set", on: importance == nil, outlined: true) { importance = nil }
                }
            }
            Text("1 = small detail · 5 = matters a lot")
                .font(m.secondary)
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 4)
        }
    }

    private func segment(_ title: String, on: Bool, outlined: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(on ? m.secondary.weight(.semibold) : m.secondary)
                .foregroundColor(on ? Theme.mainBg : outlined ? Theme.textSecondary : Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(minWidth: 32)
                .frame(height: 32)
                .background(on ? Theme.textPrimary : outlined ? .clear : Self.fill, in: Capsule())
                .overlay { if outlined && !on { Capsule().strokeBorder(Self.line, lineWidth: 1) } }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Tags（类别标签和普通标签一个样：× 去掉，候选里能换）

    private var tagsTray: some View {
        VStack(alignment: .leading, spacing: 4) {
            trayHead("Tags")
            let shown = shownTags
            if !shown.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 0) {
                    ForEach(shown, id: \.self) { t in
                        Button { (tags, category) = Self.removing(t, from: tags, category: category) } label: {
                            HStack(spacing: 4) {
                                Text("#" + t).lineLimit(1)
                                Image(systemName: "xmark")
                                    .font(m.secondary.weight(.semibold))
                                    .foregroundColor(Theme.textSecondary)
                            }
                            .font(m.secondary)
                            .padding(.leading, 12)
                            .padding(.trailing, 8)
                            .frame(maxWidth: 260)
                            .frame(height: 32)
                            .background(Self.fill, in: Capsule())
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove tag \(t)")
                    }
                }
            }
            field {
                TextField("Add tag, then Return", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(m.sectionHeader.weight(.regular))
                    .focused($focus, equals: .tag)
                    .submitLabel(.done)
                    .onSubmit {
                        if newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            newTag = ""
                            closeTray()
                        } else {
                            commitPendingTag()
                            focus = .tag
                        }
                    }
                    .onAppear { focus = .tag }
                if !newTag.isEmpty {
                    trayButton("Add", plain: false, height: 36) {
                        commitPendingTag()
                        focus = .tag
                    }
                }
            }
            suggestionRow(Self.tagSuggestions(tagPool, shown: shown, typed: newTag),
                          title: { "+ #" + $0 }, label: { "Add tag \($0)" }) { t in
                (tags, category) = Self.adding(t, to: tags, category: category)
                newTag = ""
            }
        }
    }

    // MARK: 详细度（三格；点简略 / 详细先问一句再调模型，结果进编辑框，Save 才存）

    private var detailTray: some View {
        VStack(alignment: .leading, spacing: 0) {
            trayHead(CardDetailRewrite.name)
            HStack(spacing: 6) {
                ForEach(CardDetail.Level.allCases, id: \.self) { level in
                    segment(CardDetailRewrite.word(level), on: shownLevel == level, outlined: false) { pickDetail(level) }
                        .disabled(!canPickDetail(level))
                }
                if detailRunning != nil { ProgressView().controlSize(.small).padding(.leading, 4) }
            }
            Text(detailNote)
                .font(m.secondary)
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// 编辑框里有她打了没存的字（详细度重写好、她没再动的那份不算）：三格都点不了，免得重写结果盖掉
    private var hasUnsavedText: Bool { trimmed != base.text && trimmed != detailDraft?.text }

    /// 托盘里那一行小字
    private var detailNote: String {
        if let level = detailRunning {
            return "正在重写成「\(CardDetailRewrite.word(level))」…"
        }
        if hasUnsavedText { return "先 Save 或撤掉没存的改动" }
        if detailDraft != nil { return "重写好的已经放进正文：点 Save 才存，Cancel 就当没发生。" }
        if case .unavailable(let why)? = detailRoute { return why }
        switch detailGathered {
        case .unavailable(let why)?: return why
        case .ready?: return "照这条当时附近的原文重写，写手写出来的算 Normal。" + (savedLevel == nil ? "这条你改过正文，现在不算哪一档。" : "")
        case nil: return "在找这条当时的原文…"
        }
    }

    private var detailNames: MemoryExtractor.Names {
        let p = profileManager?.profiles.first { $0.id == profileId }
        return MemoryExtractor.Names(userName: p?.userName ?? userName, assistantName: p?.assistantName ?? assistantName)
    }

    /// 打开托盘时找一次原文（后台读库）、定一次用哪个模型
    private func prepareDetail() {
        guard let memory, detailGathered == nil, !detailLoading else { return }
        detailRoute = CardDetailRewrite.route(providers: providerManager)
        detailLoading = true
        let card = CardDetailRewrite.Card(memory), pid = memory.profileId, container = modelContext.container
        let names = detailNames, every = FragmentWatch.wholeEvery()
        Task {
            detailGathered = await Task.detached(priority: .userInitiated) {
                CardDetailRewrite.gather(card, profileId: pid, names: names, container: container, every: every)
            }.value
            detailLoading = false
        }
    }

    /// 这一格现在点得动没有：要调模型的那几格，原文找到了、有云上模型才点得动（找不到的原因在托盘那行小字里）
    private func canPickDetail(_ level: CardDetail.Level) -> Bool {
        guard let memory, detailRunning == nil, !hasUnsavedText else { return false }
        if level == savedLevel || level == detailDraft?.level { return true }
        if level == .medium, let original = detailState?.original, original != memory.content { return true }
        guard case .ready? = detailGathered, case .remote? = detailRoute else { return false }
        return true
    }

    private func pickDetail(_ level: CardDetail.Level) {
        guard let memory, canPickDetail(level), detailDraft?.level != level else { return }
        // 点回卡上现在那一档：丢掉没存的草稿
        if level == savedLevel {
            if detailDraft != nil {
                text = base.text
                detailDraft = nil
            }
            return
        }
        // 点回适中：日志里找得回写手原来那句就直接放回去，不调模型
        if level == .medium, let original = detailState?.original, original != memory.content {
            text = original
            detailDraft = .init(level: .medium, text: original, sent: memory.content, recordId: nil, actor: MemoryAuditLog.you)
            closeTray()
            return
        }
        detailAsk = level
    }

    private func detailAskText(_ level: CardDetail.Level) -> String {
        guard case .ready(let prepared)? = detailGathered, case .remote(let model, let name)? = detailRoute else { return "" }
        return CardDetailRewrite.askText(level, prepared: prepared, model: name,
                                         cost: CardDetailRewrite.cost(prepared, level: level, model: model, providers: providerManager))
    }

    private func runDetail(_ level: CardDetail.Level) {
        guard let memory, let providerManager, case .ready(let prepared)? = detailGathered,
              case .remote(let model, let name)? = detailRoute else { return }
        let pid = memory.profileId
        // 她手动点的：不看写入预算，全局预算照查（同 A2 / A3 手动 Rewrite）；花费记在写入用量名下
        let caller = SessionSegmentWriter.modelCaller(model: model, providerManager: providerManager, conversationId: prepared.conversationId,
                                                      profileId: pid, kind: .memory, checkWriteBudget: false)
        detailRunning = level
        error = nil
        Task {
            let out = await CardDetailRewrite.run(level, prepared: prepared, model: name, caller: caller, profileId: pid)
            detailRunning = nil
            guard let new = out.text else {
                error = "没重写成：\(out.failure ?? "模型没回内容")。正文没动。"
                return
            }
            text = new
            detailDraft = .init(level: level, text: new, sent: prepared.material.content, recordId: out.recordId, actor: name)
            if open == .detail { closeTray() }
        }
    }

    // MARK: - Save（存 / 记一笔 / 浮条都在 `MemoryEntryActions`；这里只把草稿交过去）

    private func save() {
        commitPendingTag()
        guard let memory else { return create() }
        let wasDraft = MemoryAudit.state(of: memory) == .unreviewed
        // 编辑框里是详细度重写好、她没再动的字：先照详细度那一笔存（只换正文、算批过、不记她改过），别的改动再走下面
        var detailOut: MemoryEntryActions.Outcome?
        if let draft = detailDraft, trimmed == draft.text {
            let out = CardDetailRewrite.save(draft, to: memory, context: modelContext)
            if let e = out.error {
                error = e
                return
            }
            detailOut = out
        }
        // 四项先原样带回卡上现有的值，动过的才换（原样传回的数据层不碰）
        var edit = MemoryAudit.Edit(memory)
        edit.text = trimmed
        edit.category = category
        edit.importance = importance
        if subject != (memory.subject ?? "") { edit.subject = subject }
        edit.speaker = speaker
        // 没点 Adjust = 置信度交给 `MemoryAudit.apply`（改过就 100）；点了 = 她定的数
        if manualConfidence { edit.confidence = confidence }
        edit.keywords = tags
        let out = MemoryEntryActions.save(edit, to: memory, context: modelContext)
        if let e = out.error {
            error = e
            return
        }
        dismiss()
        if let done = out.entry != nil ? out : detailOut, done.entry != nil {
            onEvent(MemoryEntryEvent(kind: .saved, card: memory.id, outcome: done, wasDraft: wasDraft))
        }
    }

    /// 新加一条：她亲手写的 = 置信度 100（她 Adjust 过以她的为准），钉不钉看 ⋯ 里的 Pin
    private func create() {
        let edit = MemoryAudit.Edit(text: trimmed, category: category, importance: importance, subject: MemoryAudit.cleaned(subject),
                                    speaker: speaker, keywords: tags,
                                    confidence: manualConfidence ? confidence : MemoryAudit.handEditedConfidence)
        let (made, out) = MemoryEntryActions.create(edit, pinned: pinNew, profileId: profileId, context: modelContext)
        if let e = out.error {
            error = e
            return
        }
        dismiss()
        if let made { onEvent(MemoryEntryEvent(kind: .added, card: made.id, outcome: out)) }
    }
}

// MARK: - 纯逻辑（测试在 MemoryAuditTests）

extension MemoryAuditEditPage {
    /// 这层楼活着的卡上出现过的标签（类别当标签算，见 `MemoryAuditTraits.shownTags`）：一张卡同一个只算一次，
    /// 按出现的卡数多→少（同数按字排，顺序稳定）；不写死任何清单
    static func tagRanking(_ memories: [Memory], limit: Int = 30) -> [String] {
        ranking(memories, limit: limit) { MemoryAuditTraits.shownTags(category: $0.category, keywords: $0.keywords) }
    }

    /// 这层楼活着的卡上出现过的「说的是谁」，规则同 `tagRanking`
    static func subjectRanking(_ memories: [Memory], limit: Int = 30) -> [String] {
        ranking(memories, limit: limit) { MemoryAudit.cleaned($0.subject).map { [$0] } ?? [] }
    }

    private static func ranking(_ memories: [Memory], limit: Int, values: (Memory) -> [String]) -> [String] {
        var counts: [String: Int] = [:]
        for m in memories where m.supersededAt == nil {
            for t in Set(values(m).compactMap(MemoryAudit.cleaned)) { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    /// 候选里去掉卡上已经有的（按去空白比）
    static func suggestions(_ pool: [String], excluding tags: [String], limit: Int = 12) -> [String] {
        let have = Set(tags.compactMap(MemoryAudit.cleaned))
        return Array(pool.filter { !have.contains($0) }.prefix(limit))
    }

    /// Tags 托盘的候选：库里出现过的（`tagRanking`）后面补上库里还没出现过的另几个类别（保证四个都换得到），
    /// 去掉卡上显示着的；打了字就只留含这段字的
    static func tagSuggestions(_ pool: [String], shown: [String], typed: String, limit: Int = 12) -> [String] {
        let categories = MemoryAuditFilterSheet.categories.compactMap { MemoryAuditTraits.categoryTag($0.key) }
        let all = pool + categories.filter { !pool.contains($0) }
        let q = stripHash(typed)
        return suggestions(all.filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }, excluding: shown, limit: limit)
    }

    /// About 托盘的候选：去掉现在填着的；改成了别的字就只留含这段字的
    static func subjectSuggestions(_ pool: [String], typed: String, original: String?, limit: Int = 12) -> [String] {
        let q = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let typing = !q.isEmpty && q != MemoryAudit.cleaned(original)
        return Array(pool.filter { $0 != q && (!typing || $0.localizedCaseInsensitiveContains(q)) }.prefix(limit))
    }

    private static func stripHash(_ input: String) -> String {
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 加一个标签：去首尾空白和打在前面的 #；空的、已经有的不加（原数组原样返回）
    static func adding(_ input: String, to tags: [String]) -> [String] {
        guard let tag = MemoryAudit.cleaned(stripHash(input)), !tags.compactMap(MemoryAudit.cleaned).contains(tag) else { return tags }
        return tags + [tag]
    }

    /// 加一个标签，类别当标签算：加的是另四个类别之一 = 换成这个类别（一张卡只一个类别），其余照 `adding(_:to:)`
    static func adding(_ input: String, to tags: [String], category: String) -> (tags: [String], category: String) {
        if let key = MemoryAuditTraits.categoryKey(forTag: stripHash(input)) { return (tags, key) }
        return (adding(input, to: tags), category)
    }

    /// 去掉一个显示着的标签：是类别标签 = 存回「事实」（同名的普通标签一起去掉，免得换个身份又出来）；其余去掉同名的
    static func removing(_ tag: String, from tags: [String], category: String) -> (tags: [String], category: String) {
        let rest = tags.filter { MemoryAudit.cleaned($0) != tag }
        if MemoryAuditTraits.categoryTag(category) == tag { return (rest, MemoryAuditTraits.plainCategory) }
        return (rest, category)
    }

    /// From 的选项：没设 + 认得的三种；卡上原来是别的词（去空白后不在三种里）原样多一项放最后
    static func speakerOptions(current: String?) -> [String?] {
        var out: [String?] = [nil] + MemoryAuditTraits.speakers.map { Optional($0) }
        if let c = current, let t = MemoryAudit.cleaned(c), !MemoryAuditTraits.speakers.contains(t) { out.append(c) }
        return out
    }

    /// 置信度输入框：只留数字，最多三位
    static func confidenceInput(_ text: String) -> String {
        String(text.filter { $0.isASCII && $0.isNumber }.prefix(3))
    }

    /// 框里的字 → 置信度：空 = 清空（nil），其余夹到 0–100
    static func confidence(from text: String) -> Int? {
        Int(confidenceInput(text)).map { min(max($0, 0), 100) }
    }
}
