#if os(iOS)
import SwiftUI
import SwiftData

struct Page2WidgetHost: View {
    let item: Page2Item
    var preview = false
    var onOpen: (String) -> Void
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    private var size: WidgetSize { item.span == .small ? .small : (item.span == .large ? .large : .medium) }

    var body: some View {
        Group {
            if preview {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Page2WidgetCatalog.name(item.widgetKind ?? "")).font(.caption.weight(.semibold))
                    Text(Page2WidgetCatalog.sample(item.widgetKind ?? "")).font(.body)
                    Spacer(minLength: 0)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).modifier(Page2WidgetSurface())
            } else {
                switch item.widgetKind {
                case "pet": PetWidgetView(size: size)
                case "todo": TodoWidgetView(size: size) { day in
                    navigator?.pendingTarget = .init(tool: "calendar", id: day)
                    onOpen("calendar")
                }
                case "garden": GardenWidgetView(size: size)
                case "contacts": ContactsWidgetView(size: size)
                case "vocab": VocabWidgetView(size: size)
                #if PERSONAL_APPS
                #if DEBUG
                case "topicBox": TopicWidgetView(size: size)
                #endif
                #endif
                default: Page2SummaryWidget(item: item, onOpen: onOpen)
                }
            }
        }
        .environment(\.usesSystemDesktop, true)
    }
}

struct Page2StackView: View {
    let item: Page2Item
    let height: CGFloat
    var showLabel = true
    var onOpen: (String) -> Void
    var onScrolling: (Bool) -> Void = { _ in }
    @State private var selectedID: UUID?
    @State private var suggestion: Page2Item?
    @State private var home = Page2HomeStore.shared
    @AppStorage("page2RecentTool_v1") private var recentTool = ""
    @Environment(RightPanelToolManager.self) private var tools: RightPanelToolManager?
    @Environment(\.isPage2Active) private var active
    private var stored: Page2Item { home.layout.item(item.id) ?? item }
    private var members: [Page2Item] {
        stored.children.compactMap { home.layout.item($0) }.filter { child in
            guard let toolID = child.toolID else { return true }
            guard let tool = tools?.tool(byId: toolID) else { return false }
            return tool.isEnabled && tools?.isVisibleInCurrentMode(tool) == true
        }
    }
    private var shown: [Page2Item] {
        let candidate = stored.configuration["widgetSuggestions"] != "false" ? suggestion : nil
        return members + (candidate.map { [$0] } ?? [])
    }
    private var selection: UUID? {
        if let selectedID, shown.contains(where: { $0.id == selectedID }) { return selectedID }
        let desired = stored.configuration["activeChild"].flatMap(UUID.init(uuidString:))
        return shown.first(where: { $0.id == desired })?.id ?? shown.first?.id
    }
    var body: some View {
        if let selection {
            VStack(spacing: 4) {
                Page2StackPager(items: shown, selectedID: selection, onSelect: select, onScrolling: onScrolling, onOpen: onOpen)
                    .frame(height: height)
                    .overlay(alignment: .trailing) {
                    VStack(spacing: 6) {
                        ForEach(shown) { child in Circle().fill(.white.opacity(child.id == selection ? 0.9 : 0.35)).frame(width: 5, height: 5) }
                    }.offset(x: 10).allowsHitTesting(false)
                }
                if showLabel { Text(Page2WidgetCatalog.name(shown.first(where: { $0.id == selection })?.widgetKind ?? "")).font(.system(size: 12)).modifier(Page2DesktopLabel()) }
            }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("page2.stack.\(item.id.uuidString)")
                .accessibilityValue(Page2WidgetCatalog.name(shown.first(where: { $0.id == selection })?.widgetKind ?? ""))
                .accessibilityAction(named: "下一个组件") {
                    if let index = shown.firstIndex(where: { $0.id == selection }) { select(shown[(index + 1) % shown.count].id) }
                }
                .onAppear { refreshSuggestion() }
                .onChange(of: recentTool) { _, _ in if active { refreshSuggestion() } }
                .onChange(of: active) { _, value in if value { refreshSuggestion() } else { onScrolling(false) } }
                .onChange(of: stored.children) { _, _ in refreshSuggestion() }
                .onChange(of: stored.span) { _, _ in refreshSuggestion() }
                .onChange(of: stored.configuration["activeChild"]) { _, value in selectedID = value.flatMap(UUID.init(uuidString:)) }
                .onChange(of: stored.configuration["widgetSuggestions"]) { _, _ in refreshSuggestion() }
        }
    }
    private func select(_ id: UUID) {
        selectedID = id
        guard members.contains(where: { $0.id == id }) else { return }
        var values = stored.configuration
        guard values["activeChild"] != id.uuidString || values["rotationTool"] != recentTool else { return }
        values["activeChild"] = id.uuidString; values["rotationTool"] = recentTool
        home.configure(item.id, values: values)
    }
    private func refreshSuggestion() {
        if stored.configuration["widgetSuggestions"] != "false", members.count < 10, !recentTool.isEmpty,
           !members.contains(where: { $0.toolID == recentTool }), let tool = tools?.tool(byId: recentTool),
           tool.isEnabled && tools?.isVisibleInCurrentMode(tool) == true {
            if suggestion?.toolID != recentTool || suggestion?.span != item.span { suggestion = .widget(recentTool, span: item.span) }
        } else { suggestion = nil }
        if stored.configuration["smartRotate"] != "false", stored.configuration["rotationTool"] != recentTool,
           let preferred = shown.first(where: { $0.toolID == recentTool }) { select(preferred.id) }
    }
}

struct Page2SummaryWidget: View {
    let item: Page2Item
    var onOpen: (String) -> Void
    @Environment(\.isPage2Active) private var desktopActive
    @Environment(\.page2Date) private var desktopDate
    @State private var loadedProfileID = ""
    @Environment(\.modelContext) private var context
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(CharacterCardManager.self) private var cards: CharacterCardManager?
    @Environment(PresetManager.self) private var presets: PresetManager?
    @Environment(GlobalWorldBookManager.self) private var globalBooks: GlobalWorldBookManager?
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    @Environment(\.scenePhase) private var scenePhase
    @State private var headline = ""
    @State private var detail = ""
    @State private var target: String?
    @State private var imageData: Data?
    @State private var updated: Date?
    @State private var loadError: String?
    @State private var bridge = CCBridgeWebSocketClient.shared
    private var profileID: String { profiles?.currentProfile.id ?? "" }
    private var kind: String { item.widgetKind ?? item.toolID ?? "" }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Page2WidgetCatalog.name(kind)).font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    if kind == "ccTerminal" { Circle().fill(bridge.isConnected ? Color.green : .secondary).frame(width: 6, height: 6) }
                }.foregroundStyle(.secondary)
                if kind == "calendar" {
                    Text(Date(), format: .dateTime.day()).font(.system(size: 44, weight: .light))
                }
                HStack(alignment: .top, spacing: 10) {
                    if let imageData, let image = UIImage(data: imageData) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 44, height: 64).clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(headline.isEmpty ? "暂无内容" : headline).font(.system(size: item.span == .small ? 17 : 20, weight: .semibold))
                            .lineLimit(item.span == .small ? 2 : 3)
                        if !detail.isEmpty { Text(detail).font(.caption).lineLimit(item.span == .large ? 8 : 3).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 0)
                if let loadError { Text(loadError).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                else if let updated { Text(updated, style: .date).font(.caption2).foregroundStyle(.secondary) }
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .modifier(Page2WidgetSurface())
        .task(id: "\(profileID)-\(kind)-\(item.configuration)-\(desktopActive)-\(Calendar.current.startOfDay(for: desktopDate))") { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in if kind == "memory" { Task { await refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .fileLibraryDidChange)) { _ in if ["fileLibrary", "reading", "calendar"].contains(kind) { Task { await refresh() } } }
        #if PERSONAL_APPS
        .onChange(of: Page2WarroomSnapshot.shared.updatedAt) { _, _ in if kind == "warroom" { Task { await refresh() } } }
        .onChange(of: bridge.isConnected) { _, _ in if ["ccTerminal", "warroom"].contains(kind) { Task { await refresh() } } }
        #else
        .onChange(of: bridge.isConnected) { _, _ in if ["ccTerminal"].contains(kind) { Task { await refresh() } } }
        #endif
        .onChange(of: TodoManager.shared.items) { _, _ in if kind == "plan" { Task { await refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in if kind == "plan" { Task { await refresh() } } }
    }

    @MainActor private func refresh() async {
        let pid = profileID
        let preferred = item.configuration["resourceID"] ?? ""
        guard desktopActive, !pid.isEmpty else { return }
        loadedProfileID = pid
        headline = ""
        detail = ""
        target = nil
        imageData = nil
        loadError = nil
        updated = nil
        do {
            switch kind {
            case "plan":
                let today = TodoManager.dayKey(Date())
                let list = TodoManager.shared.actionList(today: today)
                headline = list.first?.text ?? "今天留一点空白"
                detail = list.isEmpty ? "今天没有待办" : "今天 \(list.count) 项待办"
                target = today
            case "calendar":
                // 没指定内容：最近一个纪念日（plan-calendar §九 P6）；旧配置（AI 日记日期）照旧，点开是那天的每日页
                if preferred.isEmpty, let a = AnniversaryOrdering.upcoming(AnniversaryStore.forProfile(pid).loadAll()).first {
                    let (prefix, number) = AnniversaryText.count(a)
                    headline = "\(a.title) · \(prefix) \(number)\(number == "今天" ? "" : " 天")"
                    detail = AnniversaryText.subtitle(a)
                    target = "anniv:\(a.id)"
                    break
                }
                let note = preferred.isEmpty ? DailyFileStore.latest(profileId: pid) : DailyFileStore.load(date: preferred, profileId: pid)
                headline = note.map { String($0.text.prefix(90)) } ?? Date().formatted(.dateTime.weekday(.wide))
                detail = note?.date ?? "还没有日记"
                target = note?.date
                updated = note?.updatedAt
            case "memory":
                var query = FetchDescriptor<Memory>(predicate: #Predicate { $0.profileId == pid && $0.supersededAt == nil }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                query.fetchLimit = 3
                if let selected = UUID(uuidString: preferred) { query.predicate = #Predicate { $0.profileId == pid && $0.id == selected && $0.supersededAt == nil } }
                if let memory = try context.fetch(query).first {
                    headline = memory.content; detail = "最近记住的事"; target = memory.id.uuidString; updated = memory.updatedAt
                } else { detail = "聊一聊，留下一点记忆" }
            case "reading":
                var query = FetchDescriptor<BookEntry>(predicate: #Predicate { $0.profileId == pid }, sortBy: [SortDescriptor(\.lastReadAt, order: .reverse)])
                query.fetchLimit = 3
                if !preferred.isEmpty { query.predicate = #Predicate { $0.profileId == pid && $0.id == preferred } }
                if let book = try context.fetch(query).first {
                    headline = book.name; detail = "\(book.author)\n读到第 \(book.currentChapter) 章"; target = book.id; imageData = book.coverData; updated = book.lastReadAt
                } else { detail = "导入一本书，开始阅读" }
            #if PERSONAL_APPS
            #if DEBUG
            case "audiobook":
                var query = FetchDescriptor<AudiobookItem>(predicate: #Predicate { $0.profileId == pid }, sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
                query.fetchLimit = 3
                if let selected = UUID(uuidString: preferred) { query.predicate = #Predicate { $0.profileId == pid && $0.id == selected } }
                if let book = try context.fetch(query).first {
                    let seconds = PlaybackCheckpointStore.read(profileId: pid, bookId: book.id)?.timestamp ?? book.currentTime
                    headline = book.title; detail = "听到 \(Int(seconds) / 60) 分 \(Int(seconds) % 60) 秒"; target = book.id.uuidString; updated = book.lastPlayedAt
                } else { detail = "导入音频，听一段故事" }
            #endif
            #endif
            case "worldBook":
                var query = FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == pid })
                query.fetchLimit = 3
                if preferred.hasPrefix("floor:"), let selected = UUID(uuidString: String(preferred.dropFirst(6))) { query.predicate = #Predicate { $0.profileId == pid && $0.id == selected } }
                if !preferred.hasPrefix("global:"), let book = try context.fetch(query).first {
                    headline = book.name; detail = "本楼层 · \(book.entries.count) 个条目"
                    if let entry = book.entries.first { target = "floor:\(book.id):\(entry.id)" }
                } else if let book = globalBooks?.books.first(where: { preferred.isEmpty || "global:\($0.id)" == preferred }) {
                    headline = book.name; detail = "全局 · \(book.entries.count) 个条目"
                    if let entry = book.entries.first { target = "global:\(book.id):\(entry.id)" }
                }
            case "cardLibrary":
                if let card = cards?.cards.first(where: { preferred.isEmpty || $0.id == preferred }) {
                    headline = card.name; detail = card.description; target = card.id; imageData = card.coverImageData
                } else { detail = "导入一张角色卡" }
            case "prompt":
                if let presetID = profiles?.currentProfile.presetId, let preset = presets?.preset(byId: presetID) {
                    headline = preset.name; detail = "当前楼层配置\n轻点查看与编辑"
                }
            case "sticker":
                var query = FetchDescriptor<StickerAsset>(predicate: #Predicate { $0.profileId == pid }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
                query.fetchLimit = 3
                if let selected = UUID(uuidString: preferred) { query.predicate = #Predicate { $0.profileId == pid && $0.id == selected } }
                if let sticker = try context.fetch(query).first {
                    headline = sticker.name; detail = sticker.noteContent ?? "最近的贴纸"; target = sticker.id.uuidString
                    imageData = StickerFileManager.loadImageCached(path: sticker.thumbnailPath, profileId: pid)
                } else { detail = "添加一张自己的贴纸" }
            case "browser":
                if let entry = BrowsingHistoryStore.load().first(where: { preferred.isEmpty || $0.url == preferred }) {
                    headline = entry.title; detail = URL(string: entry.url)?.host ?? entry.url; target = entry.url; updated = entry.date
                } else { detail = "最近访问的网站会出现在这里" }
            case "fileLibrary":
                let files = await Task.detached(priority: .utility) {
                    #if (DEBUG || PERF_BENCH) && os(iOS)
                    let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("Page2WidgetHost.files") : nil
                    defer { if let airSpan { AirProbeSections.leave(airSpan) } }
                    #endif
                    return FileLibraryStore.list(profileId: pid).filter { preferred.isEmpty || $0.path == preferred }.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(3).map { ($0.path, $0.modifiedAt) }
                }.value
                guard pid == profileID, !Task.isCancelled else { return }
                if let file = files.first { headline = URL(fileURLWithPath: file.0).lastPathComponent; detail = file.0; target = file.0; updated = file.1 }
                else { detail = "还没有文件" }
            case "health":
                var query = FetchDescriptor<WeightEntry>(predicate: #Predicate { $0.profileId == pid }, sortBy: [SortDescriptor(\.date, order: .reverse)])
                query.fetchLimit = 1
                if let entry = try context.fetch(query).first {
                    headline = item.configuration["hideValue"] == "true" ? "已记录体重" : String(format: "%.1f kg", entry.weightKg)
                    detail = "最近一次记录"; updated = entry.date; target = "weight"
                } else { detail = "还没有体重记录" }
            #if PERSONAL_APPS
            case "trading":
                var query = FetchDescriptor<TickerEntry>(predicate: #Predicate { $0.profileId == pid }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
                query.fetchLimit = 3
                if !preferred.isEmpty { query.predicate = #Predicate { $0.profileId == pid && $0.symbol == preferred } }
                let entries = try context.fetch(query)
                if let entry = entries.first { headline = entry.symbol; detail = entry.displayName ?? "关注列表"; target = entry.symbol; updated = entry.createdAt }
            #endif
            case "ccTerminal":
                headline = bridge.isConnected ? "已连接" : "未连接"
                if let window = TerminalWindowStore.shared.windows.first(where: { !$0.isClosed && (preferred.isEmpty || $0.code == preferred) }) {
                    detail = TerminalTitle.resolve(title: window.title, engine: window.engine, code: window.code)
                    target = window.code
                } else { detail = bridge.lastError ?? "轻点打开终端" }
            #if PERSONAL_APPS
            case "warroom":
                let snapshot = Page2WarroomSnapshot.shared
                snapshot.refreshIfNeeded()
                headline = snapshot.updatedAt == nil ? "尚未读取看板" : "\(snapshot.pendingCount) 项待处理"
                detail = (bridge.isConnected ? "" : "离线 · ") + (snapshot.firstTitle ?? "轻点查看军机处")
                if let selected = snapshot.tasks.first(where: { $0.id == preferred }) { headline = selected.title; target = selected.id }
                else { target = snapshot.firstID }
                updated = snapshot.updatedAt
            #endif
            default: detail = "轻点打开\(Page2WidgetCatalog.name(kind))"
            }
        } catch { loadError = "暂时无法读取：\(error.localizedDescription)" }
    }

    private func open() {
        if kind == "plan" {
            navigator?.pendingTarget = .init(tool: "calendar", id: target ?? TodoManager.dayKey(Date()))
            onOpen("calendar")
            return
        }
        guard loadedProfileID == profileID, let tool = item.toolID else { return }
        if let target { navigator?.pendingTarget = .init(tool: tool, id: target) }
        onOpen(tool)
    }
}
struct Page2WidgetConfigurationView: View {
    let item: Page2Item
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(CharacterCardManager.self) private var cards: CharacterCardManager?
    @Environment(GlobalWorldBookManager.self) private var worldBooks: GlobalWorldBookManager?
    @State private var home = Page2HomeStore.shared
    @State private var choices: [Choice] = []
    @State private var error: String?
    private struct Choice: Identifiable { let id: String; let name: String }
    private var kind: String { item.widgetKind ?? "" }
    private var current: Page2Item { home.layout.item(item.id) ?? item }

    var body: some View {
        NavigationStack {
            List {
                Section("显示内容") {
                    Button("自动显示最近内容") { choose(nil) }
                    ForEach(choices) { choice in
                        Button { choose(choice.id) } label: {
                            HStack {
                                Text(choice.name)
                                Spacer()
                                if current.configuration["resourceID"] == choice.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                if kind == "health" {
                    Toggle("收起数值", isOn: Binding(get: { current.configuration["hideValue"] == "true" }, set: { hidden in
                        var values = current.configuration
                        values["hideValue"] = hidden ? "true" : "false"
                        home.configure(item.id, values: values)
                    }))
                }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            .navigationTitle("编辑\(Page2WidgetCatalog.name(kind))").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await load() }
        }
    }
    private func choose(_ id: String?) {
        var values = current.configuration
        values["resourceID"] = id
        home.configure(item.id, values: values)
        dismiss()
    }
    @MainActor private func load() async {
        guard let pid = profiles?.currentProfile.id else { return }
        do {
            switch kind {
            case "reading": choices = try context.fetch(FetchDescriptor<BookEntry>(predicate: #Predicate { $0.profileId == pid })).map { Choice(id: $0.id, name: $0.name) }
            #if PERSONAL_APPS
            #if DEBUG
            case "audiobook": choices = try context.fetch(FetchDescriptor<AudiobookItem>(predicate: #Predicate { $0.profileId == pid })).map { Choice(id: $0.id.uuidString, name: $0.title) }
            #endif
            #endif
            case "memory":
                var query = FetchDescriptor<Memory>(predicate: #Predicate { $0.profileId == pid && $0.supersededAt == nil }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                query.fetchLimit = 100
                choices = try context.fetch(query).map { Choice(id: $0.id.uuidString, name: String($0.content.prefix(60))) }
            case "worldBook":
                choices = try context.fetch(FetchDescriptor<WorldBook>(predicate: #Predicate { $0.profileId == pid })).map { Choice(id: "floor:\($0.id)", name: $0.name + " · 本楼层") }
                choices += (worldBooks?.books ?? []).map { Choice(id: "global:\($0.id)", name: $0.name + " · 全局") }
            case "cardLibrary": choices = (cards?.cards ?? []).map { Choice(id: $0.id, name: $0.name) }
            case "sticker": choices = try context.fetch(FetchDescriptor<StickerAsset>(predicate: #Predicate { $0.profileId == pid })).map { Choice(id: $0.id.uuidString, name: $0.name) }
            case "calendar": choices = DailyFileStore.existingDates(profileId: pid).sorted(by: >).prefix(60).map { Choice(id: $0, name: $0) }
            case "browser": choices = BrowsingHistoryStore.load().map { Choice(id: $0.url, name: $0.title.isEmpty ? $0.url : $0.title) }
            #if PERSONAL_APPS
            case "trading": choices = try context.fetch(FetchDescriptor<TickerEntry>(predicate: #Predicate { $0.profileId == pid })).map { Choice(id: $0.symbol, name: $0.symbol) }
            #endif
            case "ccTerminal": choices = TerminalWindowStore.shared.windows.filter { !$0.isClosed }.map { Choice(id: $0.code, name: $0.title ?? $0.code) }
            #if PERSONAL_APPS
            case "warroom": choices = Page2WarroomSnapshot.shared.tasks.map { Choice(id: $0.id, name: $0.title) }
            #endif
            case "fileLibrary":
                let names = await Task.detached(priority: .utility) {
                    #if (DEBUG || PERF_BENCH) && os(iOS)
                    let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("Page2WidgetHost.fileChoices") : nil
                    defer { if let airSpan { AirProbeSections.leave(airSpan) } }
                    #endif
                    return FileLibraryStore.list(profileId: pid).map(\.path)
                }.value
                choices = names.map { Choice(id: $0, name: $0) }
            default: break
            }
            var seen = Set<String>()
            choices = choices.filter { seen.insert($0.id).inserted }
        } catch { self.error = error.localizedDescription }
    }
}

#endif
