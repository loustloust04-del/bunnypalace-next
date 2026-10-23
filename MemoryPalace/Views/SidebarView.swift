import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 左栏 tab 标识 —— 文件级可见，让 SidebarCardShape 等 ViewModifier 能引用。
fileprivate enum SidebarTab: Hashable {
    case all
    case favorites
    case trash
    #if os(macOS)
    /// 编程会话（plan-wake-native）。不再出现在筛选排里——它是左栏面板组的 tab（`MacLeftPanelGroup`）；
    /// 这里只留作「当前态」，激活态由 CodingSessionLibrary.isActive 表达
    case code
    #endif
    case tag(id: String)

    var displayTitle: String {
        switch self {
        case .all: return "全部"
        case .favorites: return "收藏"
        case .trash: return "回收站"
        #if os(macOS)
        case .code: return "Code"
        #endif
        case .tag: return ""
        }
    }

    var isCustom: Bool {
        if case .tag = self { return true }
        return false
    }
}

/// 收藏页分段（粟粟 10-02 终审：整个对话 / 收藏的气泡 / 划线混在一张列表里太乱 → 分开看）
fileprivate enum FavoritesKind: String, CaseIterable {
    case conversations
    case messages
    case highlights

    var title: String {
        switch self {
        case .conversations: return "对话"
        case .messages: return "消息"
        case .highlights: return "划线"
        }
    }
}

private struct SidebarJumpWord: Identifiable {
    let word: String
    var id: String { word }
}

// 缓存保暖策略的展示映射（策略本身存在 CCBridgeWebSocketClient，按 tmux session）
private func keepalivePolicyLabel(_ policy: String) -> String {
    switch policy {
    case "always": return "🔥 常驻保暖"
    case "never":  return "❄️ 不保暖"
    default:       return "⚙️ 自动"
    }
}

private func keepalivePolicyIcon(_ policy: String) -> String {
    switch policy {
    case "always": return "flame"
    case "never":  return "snowflake"
    default:       return "gearshape"
    }
}

struct SidebarView: View {
    @Binding var searchText: String
    @Binding var showFavoritesOnly: Bool
    @Binding var showTrash: Bool
    @Binding var showImporter: Bool
    @Binding var showSettings: Bool
    /// 宽屏面板形态：底栏齿轮收掉（设置入口在顶部悬浮条上）
    @Environment(\.widePanelMode) private var widePanelMode
    #if os(macOS)
    /// mac 设置是独立窗口（⌘,，plan-mac-shape A5）；iOS 仍走 showSettings sheet
    @Environment(\.openSettings) private var openSettings
    #endif
    var viewModel: ConversationViewModel
    let agoraViewModel: AgoraViewModel
    let onSelectAgoraRoom: (String) -> Void
    let onCreateAgoraRoom: () -> Void
    let onSelectConversation: () -> Void
    /// 路线 B 必填：tag 列表的 fetch 用 init(profileId:) 传进来的 profileId 构造 predicate。
    /// Parent (ContentView 在 App.body 层 `.id(profile.id)` 保证 profile 变化时 SidebarView
    /// 整个 re-init，onAppear 带新 profileId 重 fetch。
    let profileId: String

    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.launchPageSignal) private var launchSignal
    #endif
    /// input-jank C4：原本是 `@Query private var tags`，随**每次** `modelContext.save()`
    /// 失效（打字落盘、流式每 token）→ 驱动 `ForEach<Conversation>` 4.1 万条边重 diff
    /// （research-input-jank.md §7）。改显式 fetch，刷新点只有三个：onAppear、profileId 变、
    /// `.conversationTagsChanged` 通知（写点全集见 plan-input-jank-2.md §2）。
    /// 会话切换**不是**刷新点（不改 tag 数据，kimi Y5）。
    @State private var tags: [ConversationTag] = []

    init(
        searchText: Binding<String>,
        showFavoritesOnly: Binding<Bool>,
        showTrash: Binding<Bool>,
        showImporter: Binding<Bool>,
        showSettings: Binding<Bool>,
        viewModel: ConversationViewModel,
        agoraViewModel: AgoraViewModel,
        onSelectAgoraRoom: @escaping (String) -> Void,
        onCreateAgoraRoom: @escaping () -> Void,
        onSelectConversation: @escaping () -> Void,
        profileId: String
    ) {
        self._searchText = searchText
        self._showFavoritesOnly = showFavoritesOnly
        self._showTrash = showTrash
        self._showImporter = showImporter
        self._showSettings = showSettings
        self.viewModel = viewModel
        self.agoraViewModel = agoraViewModel
        self.onSelectAgoraRoom = onSelectAgoraRoom
        self.onCreateAgoraRoom = onCreateAgoraRoom
        self.onSelectConversation = onSelectConversation
        self.profileId = profileId
    }

    /// tag 列表显式 fetch。predicate / 排序与原 `@Query` 逐字一致。
    private func reloadTags() {
        let pid = profileId
        var descriptor = FetchDescriptor<ConversationTag>(
            predicate: #Predicate<ConversationTag> { $0.profileId == pid },
            sortBy: [SortDescriptor(\ConversationTag.order)]
        )
        descriptor.includePendingChanges = true
        tags = (try? modelContext.fetch(descriptor)) ?? []
    }
    @AppStorage("page0GroupPlacement") private var groupPlacement = "timeline"
    @AppStorage("page0LiquidMetal") private var liquidMetal = true
    /// 底是深色液态金属：字标、没选中的 tab 字换浅色
    private var onMetal: Bool {
        #if os(iOS)
        return liquidMetal && isIOSStyle && !widePanelMode
        #else
        return false
        #endif
    }
    @State private var roomFolderRevision = 0
    #if os(iOS)
    @State private var editingRoom: AgoraRoomSummary?
    #endif
    private var roomState: Page0LocalState { Page0LocalState(defaults: .standard, profileId: profileId) }

    private var showsOnlyRooms: Bool {
        #if os(iOS)
        return agoraEnabled && groupPlacement == "only" && !showTrash && !showFavoritesOnly
        #else
        return false
        #endif
    }

    private var visibleRooms: [AgoraRoomSummary] {
        #if os(iOS)
        guard agoraEnabled, !showTrash, !showFavoritesOnly,
              searchFilter.dateRange == .all, !listSortIsCustom else { return [] }
        if isSearchActive && !isConversationKind && !showsOnlyRooms { return [] }
        if isSearchActive && (searchFolder == .favorites || searchFolder == .trash || searchStarredOnly) { return [] }
        _ = roomFolderRevision
        let folder: String?
        if isSearchActive {
            if case .tag(let id) = searchFolder { folder = id } else { folder = nil }
        } else { folder = selectedTagId }
        let mappings = roomState.roomFolders
        let keyword = (isSearchActive ? searchFilter.keyword : searchText).trimmingCharacters(in: .whitespacesAndNewlines)
        return agoraViewModel.rooms.filter { room in
            room.floorId == profileId && (folder == nil || mappings[room.id] == folder)
                && (keyword.isEmpty || agoraViewModel.displayTitle(for: room).localizedStandardContains(keyword))
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        #else
        return []
        #endif
    }

    private var showsRoomStrip: Bool {
        #if os(iOS)
        return agoraEnabled && groupPlacement == "strip" && selectedTagId == nil
            && !showTrash && !showFavoritesOnly && searchText.isEmpty && !isSearchActive
            && searchFilter.dateRange == .all && !listSortIsCustom
        #else
        return false
        #endif
    }

    private var listItems: [PageZeroListItem] {
        let rooms = visibleRooms
        if showsOnlyRooms { return rooms.map { .room($0.id) } }
        if !searchText.isEmpty { return rooms.map { .room($0.id) } + conversations.map { .conversation($0.id) } }
        if rooms.isEmpty || showsRoomStrip { return conversations.map { .conversation($0.id) } }
        return Page0ListMerge.merge(
            conversations: conversations.map { .init(id: $0.id, isPinned: $0.isPinned, updateTime: $0.updateTime) },
            rooms: rooms.map { .init(id: $0.id, updatedAt: $0.updatedAt) },
            hasMorePages: conversations.count < totalCount)
    }

    @State private var conversations: [Conversation] = []
    @State private var totalCount: Int = 0
    @State private var isLoadingMore = false
    #if os(iOS)
    /// 主列表可拖滚动条（plan-page0-scrubber）：每个 SidebarView 一份，不与聊天页 ChatScrubber 共用
    @State private var page0Scrubber = Page0ScrubberModel()
    #endif
    @State private var showNewTagSheet = false
    @State private var editingFolder: ConversationTag? = nil
    @State private var selectedTagId: String? = nil
    @State private var favoritedNodes: [(node: MessageNode, convTitle: String)] = []
    /// R3-2：收藏页「划线」分组（聊天划线聚合，tap 跳消息）
    @State private var chatHighlightRows: [ChatHighlightListItem] = []
    /// 收藏页当前看哪一类：记住上次看的；进收藏页时那类空着就换到条目最多的一类（`settleFavoritesKind`）
    @AppStorage("favoritesKind") private var favoritesKind: FavoritesKind = .conversations
    /// 收藏标签组（10-02）：tag 快照（只在收藏页取）/ 当前按哪个 tag 筛（nil = 全部；换分段、离开收藏页清掉）/
    /// 「收藏到标签」sheet 的目标 / 胶囊长按改名中的 tag
    @State private var favoriteTagIndex = FavoriteTags.Index()
    @State private var favoriteTagFilter: String? = nil
    @State private var favoriteTagTarget: FavoriteTags.Target? = nil
    #if os(iOS)
    /// 对话行长按浮层的会话模型（浮层挂 window，见 BubbleMenuOverlayPresenter）。
    /// 用 @State 存引用、不用 @StateObject：SidebarView 不订阅它，开关菜单不重算整页 body
    @State private var rowMenuModel = BubbleMenuOverlayModel()
    #endif
    @State private var renamingFavoriteTag: String? = nil
    @State private var favoriteTagRenameText = ""
    /// 划线列表里点交易 / 话题卡的划线 → 打开对应页面
    #if PERSONAL_APPS
    @State private var highlightTicker: String? = nil
    #endif
    #if PERSONAL_APPS
    #if DEBUG
    @State private var highlightTopic: String? = nil
    #endif
    #endif
    /// R5-1 收藏页点词卡划线 → 打开词详情 sheet。
    @State private var highlightJumpWord: String? = nil
    @State private var deletedNodes: [(node: MessageNode, convTitle: String)] = []
    @State private var renamingConversationId: String? = nil
    #if os(macOS)
    /// 行内改名框的焦点（S1-9）。iOS 走系统 alert，不需要
    @FocusState private var renameFieldFocused: Bool
    @FocusState private var macSearchFocused: Bool
    @FocusState private var macListFocused: Bool
    #endif
    @State private var renameText: String = ""
    @State private var exportingConversation: Conversation? = nil
    @State private var searchResults: [SearchResult] = []
    /// 对话 / 分支两个标签共用的一次搜索结果；切这两个标签直接取，不重搜（S1）
    @State private var conversationBuckets: SearchBuckets?
    @State private var stickerSearchResults: [StickerSearchResult] = []
    @State private var characterCardResults: [CharacterCardSearchResult] = []
    @State private var worldBookEntryResults: [WorldBookEntrySearchResult] = []
    @State private var memoryResults: [MemorySearchResult] = []
    @State private var fileResults: [FileSearchResult] = []
    /// 交易 / 健康 / 书房 / 推特共用一种结果行（S3）；推特是分页取的，tweetTotal 是总数
    @State private var resourceHits: [ResourceHit] = []
    @State private var tweetTotal = 0
    @State private var tweetCursor: TweetSearchCursor?
    @State private var isLoadingMoreTweets = false
    /// 回收站里被单独删掉、内容命中的气泡：「对话」标签最后一节，数字单独算（S3-1）
    @State private var trashedBubbles: [(node: MessageNode, convTitle: String)] = []
    @State private var isSearchActive = false
    @State private var searchFilter: SearchFilter = {
        var filter = SearchFilter()
        #if os(iOS)
        filter.scope = .both   // 回车深搜默认标题+正文；打字时的实时过滤只看标题，不受它影响
        filter.sortOrder = .relevance
        #endif
        return filter
    }()
    /// 列表自己的排序，和搜索排序分开存（S2-11）：iOS 没有列表排序入口，恒为「最近」；mac 跟高级筛选面板走
    @State private var listSortOrder: SearchSort = .recent
    @State private var showAdvancedFilter = false
    #if os(iOS)
    // 全局搜索（plan-page0-global-search）
    @FocusState private var searchFieldFocused: Bool
    @State private var showFilterSheet = false
    /// 搜索态里的「所在文件夹」：进搜索时取当前文件夹标签，之后在抽屉里改
    @State private var searchFolder: SidebarTab = .all
    @State private var kindCounts: [SearchResourceKind: Int] = [:]
    /// 选中的类型（搜哪些，S3-6）：默认全选、不能为空，记在本机；当前标签仍是 searchFilter.resourceKind
    @State private var searchKinds = SearchQueryMapping.kinds(fromStored: UserDefaults.standard.stringArray(forKey: SidebarView.searchKindsKey))
    /// 标签栏的排法：有结果的在前按数量、0 条的排后，当前标签位置不动
    @State private var kindTabOrder: [SearchResourceKind] = []
    /// 这一轮搜索的标签顺序已定住（数字全回来后排一次，之后点标签不再重排）
    @State private var kindTabsSettled = false
    /// 这一轮搜索用户自己点过标签：定住时不再自动跳到结果最多的标签
    @State private var userPickedKindTab = false
    @State private var kindCountTask: Task<Void, Never>?
    @State private var recentSearches: [String] = []
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    /// 框里 `is:starred` / 抽屉「收藏」组：只在收藏的对话里搜（S2-5）
    @State private var searchStarredOnly = false
    /// 框里的 Query 解析不通过 / 映射不支持时的报错（mac 同款文案），显示在结果区顶部
    @State private var searchErrors: [String] = []
    #endif
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    /// 搜索请求代次：结果回来只有代次对得上才落地、收「忙」态（S1-2）
    @State private var searchGeneration = 0
    @State private var currentMatchIndex: Int = -1
    @State private var showSortPopover = false
    @AppStorage("exportMode") private var exportMode = "lightweight"
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage(AgoraFeatureGate.key) private var agoraEnabled = false
    /// page0 列表样式：compact 单行 / detailed 两行（第二行 = 模型最后一句）
    @AppStorage("page0ListStyle") private var listStyle = "compact"
    /// 只在「重新生成标题」按钮里读，不进 body，不订阅
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    /// 健康面板的亲密卡开关：关着的时候搜索不搜、不数亲密记录（S3-4 隐私）
    @AppStorage(HealthLogStore.intimacyShowKey) private var intimacyShown = false
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(CharacterCardManager.self) private var cardManager: CharacterCardManager?
    @Environment(GlobalWorldBookManager.self) private var globalWBManager: GlobalWorldBookManager?
    @Environment(RightPanelNavigator.self) private var rightPanelNavigator: RightPanelNavigator?
    private let pageSize = 100
    /// 标签桶 IN 查询的 convIds 上限：SQLite 变量数有上限（保守按 999 算），超过走内存兜底（B9/P1-1）
    private let tagInQueryLimit = 500
    /// 列表过滤防抖（B9 顺带 P2）
    @State private var filterDebounceTask: Task<Void, Never>?
    /// 打字即搜正文（S5 D7）：索引命中的对话 id，并进列表标题过滤的 predicate
    @State private var typingBodyConvIds: [String] = []
    @State private var typingBodyTask: Task<Void, Never>?
    @State private var typingBodyGen = 0


    /// 当前选中的文件夹 tab（「全部 / 收藏 / 回收站」时为 nil）
    private var currentFolder: ConversationTag? {
        guard let id = selectedTagId, !showTrash, !showFavoritesOnly else { return nil }
        return tags.first { $0.id == id }
    }

    #if os(iOS)
    private func folderPill(on: Bool) -> some View {
        Text(on ? "prompt 已启用" : "+ prompt")
            .font(.system(size: Theme.F.badge))
            .foregroundColor(on ? Theme.textSecondary : Theme.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(on ? Color.primary.opacity(0.045) : Color.clear))
            .overlay {
                if !on {
                    Capsule().strokeBorder(Theme.textMuted.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
    }

    /// 文件夹 tab 顶上的状态卡（粟粟 09-26 小样 v4，`docs/design-folder-card-v4.html`）：
    /// 不填色，浅绿极细描边；白底图标浮起（图标 / 颜色是她自选的，只落在白底上，不深绿套浅绿）；
    /// 右半边底边长 1–3 朵开屏同款点点小花。没设 prompt 时是虚线胶囊；点整张卡编辑。空文件夹在卡下面给空态
    @ViewBuilder
    private func folderHeader(_ folder: ConversationTag) -> some View {
        Button { editingFolder = folder } label: {
            HStack(spacing: 10) {
                FolderIconView(tag: folder, size: 15)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.06), radius: 0.75, y: 1)
                            .shadow(color: .black.opacity(0.09), radius: 5, y: 4)
                    )
                VStack(alignment: .leading, spacing: 5) {
                    Text(folder.name)
                        .font(.system(size: Theme.F.label, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    folderPill(on: !folder.instructions.isEmpty)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .background {
                FolderFlowers(seed: folder.id)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.branchIndicator.opacity(0.4), lineWidth: 0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)

        if conversations.isEmpty && visibleRooms.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: Theme.F.sectionHeader))
                    .foregroundColor(Theme.textMuted.opacity(0.45))
                Text(searchText.isEmpty ? "还没有对话" : "没有匹配的对话")
                    .font(.system(size: Theme.F.sectionHeader, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if searchText.isEmpty {
                    Text("点右上 ＋ 在这里开新对话，或长按别的对话移进来")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
    #endif

    @ViewBuilder
    private var timelineRows: some View {
        let items = listItems
        // 重复 id 不崩（09-30 Air 闪退：分页取到同一条两次，uniqueKeysWithValues 直接 trap）
        let conversationById = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let roomById = Dictionary(visibleRooms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 学堂对话 = 落在学堂文件夹里的对话（文件夹靠说明第一行标记行识别，StudyTemplate.parse 同口径，不算哈希）
        let studyFolderIds = Set(tags.lazy.filter { $0.instructions.hasPrefix(StudyTemplate.markerPrefix) }.map(\.id))
        let firstRecent = items.first { item in
            switch item {
            case .room: return true
            case .conversation(let id): return conversationById[id]?.isPinned == false
            }
        }
        ForEach(items) { item in
            if showPinSections && !showsOnlyRooms {
                if item == items.first { listSectionHeader("Pinned") }
                if item == firstRecent { listSectionHeader("Recents") }
            }
            switch item {
            case .room(let id):
                #if os(iOS)
                if let room = roomById[id] {
                    agoraRoomRow(room)
                        .modifier(Page0ScrubberRowTracker(id: item.id, model: page0Scrubber))
                }
                #else
                EmptyView()
                #endif
            case .conversation(let id):
                if let conversation = conversationById[id] {
                    if isInlineRenaming(conversation.id) {
                        TextField("对话名称", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: Theme.F.label, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Theme.accent.opacity(0.5))
                            .onSubmit {
                                applyRename(to: conversation)
                            }
                            #if os(macOS)
                            // S1-9：改名框出现就拿焦点。以前只有右键「重命名」这一条路，出来的框**不聚焦**，
                            // 还要再点一下才能打字；双击改名把这条路变高频了，不补焦点等于半残。
                            // AppKit 的 NSTextField 拿到焦点默认全选内容，所以直接打字就是覆盖。
                            .focused($renameFieldFocused)
                            .onAppear { renameFieldFocused = true }
                            .onExitCommand {
                                renamingConversationId = nil
                            }
                            #endif
                    } else {
                        #if os(iOS)
                        // 长按走 page1 同款自绘浮层（不用系统 .contextMenu：字大行高、十几行占大半屏，粟粟 10-11）
                        BubbleMenuLiftWrapper(isUser: false, cornerRadius: 16, actions: conversationMenuSpecs(conversation)) {
                            conversationRowView(conversation, isStudy: conversation.folderId.map(studyFolderIds.contains) ?? false)
                        }
                        .environment(\.bubbleMenuOverlayModel, rowMenuModel)
                        .modifier(Page0ScrubberRowTracker(id: item.id, model: page0Scrubber))
                        #else
                        conversationRowView(conversation, isStudy: conversation.folderId.map(studyFolderIds.contains) ?? false)
                        #endif
                    }
                    if conversation.id == conversations.last?.id {
                        Color.clear.frame(height: 0).onAppear { loadMore() }
                    }
                }
            }
        }
    }

    /// 对话列表主体（08-26 拆分：原本整块嵌在 body 的 ScrollView>LazyVStack 里，
    /// body 单表达式 660 行 / 缩进 69 层，SwiftUI 泛型元数据实例化时爆栈 SIGSEGV
    ///（真机崩溃 035157.ips 栈顶 swift_getGenericMetadata ← SidebarView.body）。
    /// 抽成独立 @ViewBuilder 属性 = 各自一个类型，泛型深度降下来。
    @ViewBuilder
    private var conversationListContent: some View {
            Color.clear.frame(height: 4)
            #if os(iOS)
            if let folder = currentFolder {
                folderHeader(folder)
            }
            if showsRoomStrip { agoraAvatarStrip }
            #endif
            if showFavoritesOnly {
                favoritesKindPicker
                favoriteTagChips
            }
            if !showFavoritesOnly || favoritesKind == .conversations {
                timelineRows
            }
            if showFavoritesOnly && favoritesKind == .conversations && conversations.isEmpty {
                favoritesEmptyHint("star", searchText.isEmpty ? "在对话菜单里选「收藏整个对话」，就会出现在这里" : "没有匹配的对话")
            }

            // 收藏的气泡（消息）
            if showFavoritesOnly && favoritesKind == .messages {
                if favoritedNodes.isEmpty {
                    favoritesEmptyHint("text.bubble", "在气泡的菜单里选「收藏」，就会出现在这里")
                }
                ForEach(visibleFavoritedNodes, id: \.node.id) { item in
                    FavoritedBubbleRow(
                        node: item.node,
                        convTitle: item.convTitle,
                        isSelected: viewModel.selectedConversation?.id == item.node.conversationId,
                        tags: favoriteTagIndex.nodeTags[item.node.id] ?? []
                    )
                    .rowHover(selected: viewModel.selectedConversation?.id == item.node.conversationId)
                    .onTapGesture {
                        navigateToNode(item.node)
                    }
                    .contextMenu {
                        Button(action: { favoriteTagTarget = FavoriteTags.Target(node: item.node) }) {
                            Label("编辑标签…", systemImage: "tag")
                        }
                        Button(action: {
                            FavoriteTags.setFavorite(item.node, false)
                            fetchFavoritedNodes()
                            reloadFavoriteTags()
                        }) {
                            Label("取消收藏", systemImage: "star.slash")
                        }
                    }
                }
            }

            // R3-2：划线（聊天划线聚合，tap 跳回消息）
            if showFavoritesOnly && favoritesKind == .highlights {
                if chatHighlightRows.isEmpty {
                    favoritesEmptyHint("highlighter", "在聊天里选中文字划线，就会出现在这里")
                }
                ForEach(chatHighlightRows) { item in
                    let selected = item.node.map { viewModel.selectedConversation?.id == $0.conversationId } ?? false
                    ChatHighlightRow(item: item, isSelected: selected)
                    .rowHover(selected: selected)
                    .onTapGesture { openHighlight(item) }
                    .contextMenu {
                        Button(role: .destructive) {
                            ChatHighlightStore.shared.mutate { NoteThreads.removePlace(item.place, in: &$0) }
                            fetchChatHighlights()
                        } label: {
                            Label("删掉这处划线", systemImage: "trash")
                        }
                    }
                }
            }

            // Deleted individual bubbles section (in trash mode)
            if showTrash && !deletedNodes.isEmpty {
                Divider().opacity(0.3).padding(.horizontal, 12).padding(.vertical, 6)

                HStack {
                    Image(systemName: "text.bubble")
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted)
                    Text("已删除的气泡")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)

                ForEach(deletedNodes, id: \.node.id) { item in
                    DeletedBubbleRow(
                        node: item.node,
                        convTitle: item.convTitle
                    )
                    .rowHover()
                    .contextMenu {
                        Button(action: {
                            viewModel.restore(item.node)
                            fetchDeletedNodes()
                        }) {
                            Label("恢复", systemImage: "arrow.uturn.backward")
                        }

                        Button(role: .destructive, action: {
                            viewModel.permanentlyDeleteNode(item.node, context: modelContext)
                            fetchDeletedNodes()
                        }) {
                            Label("永久删除", systemImage: "trash.slash")
                        }
                    }
                }
            }

            // Empty state for trash
            if showTrash && conversations.isEmpty && deletedNodes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: Theme.F.sectionHeader))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                    Text("回收站是空的")
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                #if os(iOS)
                .contentShape(Rectangle())
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                #endif
            }

            if isLoadingMore {
                ProgressView()
                    .padding()
            }

            // Bottom breathing room（iOS 底部压着计数行 + 渐变遮罩，最后一行要能滚出来）
            #if os(iOS)
            Color.clear.frame(height: 40)
            #else
            Color.clear.frame(height: 4)
            #endif
    }


    private func favoritesCount(_ kind: FavoritesKind) -> Int {
        switch kind {
        case .conversations: return totalCount
        case .messages: return visibleFavoritedNodes.count
        case .highlights: return chatHighlightRows.count
        }
    }

    /// 收藏页「消息」分段按 tag 筛过的
    private var visibleFavoritedNodes: [(node: MessageNode, convTitle: String)] {
        guard let tag = favoriteTagFilter else { return favoritedNodes }
        return favoritedNodes.filter { favoriteTagIndex.nodeTags[$0.node.id]?.contains(tag) == true }
    }

    /// 当前分段里用到的 tag（带条数，最近用过的在前）。划线的 tag 入口第二期，这里先不列
    private var currentFavoriteTagChips: [(name: String, count: Int)] {
        let lists: [[String]]
        switch favoritesKind {
        case .conversations: lists = Array(favoriteTagIndex.conversationTags.values)
        case .messages: lists = favoritedNodes.compactMap { favoriteTagIndex.nodeTags[$0.node.id] }
        case .highlights: return []
        }
        return FavoriteTags.chips(lists, lastUsed: favoriteTagIndex.lastUsed)
    }

    /// 分段下面一排 tag 胶囊（是关于什么），和分段（是什么）叠着筛；长按胶囊改名 / 删 tag。
    /// 横向滚动区里用 onTapGesture 不用 Button（Button 的 tap 会被滚动手势吞）
    @ViewBuilder
    private var favoriteTagChips: some View {
        let chips = currentFavoriteTagChips
        if !chips.isEmpty || favoriteTagFilter != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    FavoriteTagChip(title: "全部", on: favoriteTagFilter == nil)
                        .onTapGesture { setFavoriteTagFilter(nil) }
                    ForEach(chips, id: \.name) { chip in
                        FavoriteTagChip(title: chip.name, on: favoriteTagFilter == chip.name, count: chip.count)
                            .onTapGesture { setFavoriteTagFilter(favoriteTagFilter == chip.name ? nil : chip.name) }
                            .contextMenu {
                                Button {
                                    favoriteTagRenameText = chip.name
                                    renamingFavoriteTag = chip.name
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    deleteFavoriteTag(chip.name)
                                } label: {
                                    Label("删掉这个标签（收藏还在）", systemImage: "tag.slash")
                                }
                            }
                    }
                }
                .padding(.horizontal, isIOSStyle ? 16 : 6)
            }
            .padding(.bottom, 8)
        }
    }

    private func setFavoriteTagFilter(_ tag: String?) {
        guard favoriteTagFilter != tag else { return }
        favoriteTagFilter = tag
        // 对话分段是分页查的，筛选变了重查；消息分段在内存里筛，不用查
        conversations.removeAll()
        fetchPage(offset: 0)
    }

    /// 收藏页 tag 快照。整个对话的 tag 只留还在收藏里的对话（回收站里的、别处取消收藏的不算）
    private func reloadFavoriteTags() {
        let pid = profileManager?.currentProfile.id ?? ""
        var index = FavoriteTags.index(profileId: pid, context: modelContext)
        if !index.conversationTags.isEmpty {
            var desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == pid && $0.isTrashed == false && $0.isFavorite == true }
            )
            desc.propertiesToFetch = [\.id]
            let favoriteIds = Set(((try? modelContext.fetch(desc)) ?? []).map(\.id))
            index.conversationTags = index.conversationTags.filter { favoriteIds.contains($0.key) }
        }
        favoriteTagIndex = index
        if let tag = favoriteTagFilter, index.lastUsed[tag] == nil { favoriteTagFilter = nil }
    }

    private func renameFavoriteTag(_ old: String, to new: String) {
        let pid = profileManager?.currentProfile.id ?? ""
        FavoriteTags.rename(old, to: new, profileId: pid, context: modelContext)
        let newName = FavoriteTags.normalized(new)
        if favoriteTagFilter == old, !newName.isEmpty { favoriteTagFilter = newName }
        refreshList(keepLoaded: true)
    }

    private func deleteFavoriteTag(_ tag: String) {
        let pid = profileManager?.currentProfile.id ?? ""
        FavoriteTags.delete(tag, profileId: pid, context: modelContext)
        if favoriteTagFilter == tag { favoriteTagFilter = nil }
        refreshList(keepLoaded: true)
    }

    /// 收藏页顶上的分段：对话 / 消息 / 划线各看各的
    private var favoritesKindPicker: some View {
        Picker("收藏分类", selection: $favoritesKind) {
            ForEach(FavoritesKind.allCases, id: \.self) { kind in
                Text("\(kind.title) \(favoritesCount(kind))").tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, isIOSStyle ? 16 : 6)
        .padding(.top, 6)
        .padding(.bottom, 8)
        // 正文 / 别的窗口改了划线（改色、加批注、删）→ 列表跟着刷新
        .onChange(of: ChatHighlightStore.shared.highlights) { _, _ in fetchChatHighlights() }
        // 换分段：各段的 tag 不一样，筛选回到「全部」
        .onChange(of: favoritesKind) { _, _ in setFavoriteTagFilter(nil) }
        // 点交易 / 话题卡上的划线：sheet 挂在这里（挂在外层整条 modifier 链上会让类型检查超时）
        #if PERSONAL_APPS
        .sheet(item: Binding(
            get: { highlightTicker.map { SidebarJumpWord(word: $0) } },
            set: { if $0 == nil { highlightTicker = nil } }
        )) { t in
            TickerDetailSheet(symbol: t.word)
        }
        #endif
        #if PERSONAL_APPS
        #if DEBUG
        .sheet(item: Binding(
            get: { highlightTopic.map { SidebarJumpWord(word: $0) } },
            set: { if $0 == nil { highlightTopic = nil } }
        )) { t in
            TopicCardSheet(relPath: t.word, profileId: profileManager?.currentProfile.id ?? "")
        }
        #endif
        #endif
    }

    /// 收藏页某一类空着时的一句话
    private func favoritesEmptyHint(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: Theme.F.sectionHeader))
                .foregroundColor(Theme.textMuted.opacity(0.45))
            Text(text)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
    }

    /// 进收藏页：停在上次看的那类；那类空着就换到条目最多的一类
    private func settleFavoritesKind() {
        guard favoritesCount(favoritesKind) == 0,
              let best = FavoritesKind.allCases.max(by: { favoritesCount($0) < favoritesCount($1) }),
              favoritesCount(best) > 0 else { return }
        favoritesKind = best
    }

    /// 贴纸搜索结果（08-26 从 body 拆出，同 conversationListContent 的理由）
    @ViewBuilder
    private var stickerSearchContent: some View {
                LazyVStack(spacing: 2) {
                    Color.clear.frame(height: 4)
                    ForEach(stickerSearchResults) { result in
                        StickerMatchRow(result: result)
                            .rowHover()
                            .onTapGesture {
                                navigateToStickerResult(result)
                            }
                    }
                    if stickerSearchResults.isEmpty {
                        VStack(spacing: 8) {
                            AppIconView(name: "ri-emoji-sticker", size: 28,
                                        tint: Theme.textMuted.opacity(0.3))
                            Text("没有找到贴纸")
                                .font(.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
    }

    /// 消息搜索结果（08-26 从 body 拆出，同 conversationListContent 的理由）
    @ViewBuilder
    private var messageSearchContent: some View {
        let titleCount = searchResults.filter { $0.isTitleMatch }.count
        let contentCount = searchResults.count - titleCount
                LazyVStack(spacing: 2) {
                    Color.clear.frame(height: 4)
                    #if os(iOS)
                    ForEach(visibleRooms) { room in agoraRoomRow(room) }
                    #endif


                    if searchFilter.sortOrder == .relevance {
                        // 相关度：标题命中已计进字面分，标题块不再固定在前（S2-7）
                        ForEach($searchResults) { $group in
                            if group.isTitleMatch {
                                searchTitleRow(group: group)
                            } else {
                                searchContentRow(group: $group)
                            }
                        }
                    } else {
                    // 标题块
                    if titleCount > 0 {
                        searchBucketLabel("标题 · \(titleCount)")
                        ForEach($searchResults) { $group in
                            if group.isTitleMatch {
                                searchTitleRow(group: group)
                            }
                        }
                    }

                    // 分隔（两块都存在时）
                    if titleCount > 0 && contentCount > 0 {
                        Divider()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }

                    // 内容块
                    if contentCount > 0 {
                        searchBucketLabel("内容 · \(contentCount)")
                        ForEach($searchResults) { $group in
                            if !group.isTitleMatch {
                                searchContentRow(group: $group)
                            }
                        }
                    }
                    }

                    if !trashedBubbles.isEmpty {
                        if !searchResults.isEmpty {
                            Divider()
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                        }
                        searchBucketLabel("已删除的气泡 · \(trashedBubbles.count)")
                        ForEach(trashedBubbles, id: \.node.id) { item in
                            DeletedBubbleRow(node: item.node, convTitle: item.convTitle)
                                .rowHover()
                                .contextMenu {
                                    Button(action: { restoreTrashedBubble(item.node) }) {
                                        Label("恢复", systemImage: "arrow.uturn.backward")
                                    }
                                    Button(role: .destructive, action: { deleteTrashedBubble(item.node) }) {
                                        Label("永久删除", systemImage: "trash.slash")
                                    }
                                }
                        }
                    }

                    if searchResults.isEmpty && trashedBubbles.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: Theme.F.sectionHeader))
                                .foregroundColor(Theme.textMuted.opacity(0.5))
                            Text("没有找到结果")
                                .font(.system(size: Theme.F.secondary))
                                .foregroundColor(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        #if os(iOS)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        #endif
                    }
                }
    }

    var body: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = PerfCount.hit("sidebarBody")
        #endif
        #if DEBUG
        // iu0902 C4 验收探针：数侧边栏整体 body。合同判据 =「流式回复期间不再随
        // modelContext.save() 重跑」。对照 KBProbe 里的 `[SAVE]`（InputBarStack:91）读：
        // C4 前每个 [SAVE] 后面跟一条 SidebarView.body，C4 后跟 0 条。
        let _ = {
            PerfCounters.sidebarBody += 1
            let line = String(format: "[PERF] SidebarView.body #%d t=%.3f tags=%d",
                              PerfCounters.sidebarBody, CFAbsoluteTimeGetCurrent(), tags.count)
            print(line)
            KBProbe.log(line)
        }()
        #endif
        VStack(spacing: 0) {
            #if os(macOS)
            // Code 是左栏面板组里的另一个 tab（面板头「对话 | Code」），不是这里的筛选：
            // 切到 Code 时整块内容换成编程会话列表（自带搜索框 / 筛选），对话的搜索行和筛选行都不出
            if !isCodeTab { macSearchToolbar }
            #else
            // 字标 + 新建（搜索挪到底栏，plan-page0-brand-layout）
            HStack(spacing: 8) {
                // 字标：粟粟 PSD「图层 63」的透明通道，模板图跟正文色走
                Image("MnemeWordmark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)
                    .foregroundColor(onMetal ? .white : Theme.textPrimary)
                    .accessibilityLabel("mneme atrium")

                Spacer()

                // 新建对话（始终显示）：点按弹菜单
                Menu {
                    Button(action: { createNewConversation() }) {
                        Label("新建对话", systemImage: "square.and.pencil")
                    }
                    #if os(iOS)
                    if agoraEnabled {
                        Button(action: onCreateAgoraRoom) {
                            Label("新建群聊", systemImage: "person.2")
                        }
                    }
                    #endif
                    Button(action: { createNewCodexConversation() }) {
                        // Menu 行只吃 Text/Image/Label，用不了 AppIconView（自定义视图会被丢）
                        Label { Text("新建 Codex 对话") } icon: { Image("ri-openai") }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: isIOSStyle ? 17 : 11, weight: .medium))
                        .foregroundColor(onMetal ? .white : Theme.textPrimary)
                        .frame(width: isIOSStyle ? 44 : 34, height: isIOSStyle ? 44 : 34)
                        #if os(iOS)
                        .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                        #else
                        .background(Capsule().fill(Theme.mainBg.opacity(0.8)))
                        .overlay(Capsule().stroke(Theme.accent.opacity(0.5), lineWidth: 0.5))
                        #endif
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, isIOSStyle ? 20 : 12)
            .padding(.top, isIOSStyle ? 8 : 10)
            .padding(.bottom, isIOSStyle ? 20 : 14)


            #endif

            // Advanced filter panel（iOS 挪到底栏搜索框上方，见 iosBottomBar）
            #if os(macOS)
            if showAdvancedFilter && !isCodeTab {
                advancedFilterPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            #endif

            // Chrome-style tab bar + content card
            VStack(spacing: 0) {
                #if os(iOS)
                if isSearchActive {
                    searchKindTabBar
                    searchSortBar
                } else {
                    sidebarTabBar
                }
                #else
                if !isCodeTab { sidebarTabBar }
                #endif

            if isCodeTab {
                codeTabContent
            } else if isSearchActive && !showsOnlyRooms {
                // MARK: - Search Results View
                if isSearching {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("搜索中...")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                } else {
                    if isIOSStyle && allResultsEmpty {
                        compactEmptyCard(
                            icon: "magnifyingglass",
                            title: "没有找到结果",
                            subtitle: "换个关键词试试，多个词用空格隔开"
                        )
                        .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)

                        Spacer(minLength: 0)
                    } else if searchFilter.resourceKind == .sticker {
                        // 贴纸搜索结果
                        ScrollView {
                            stickerSearchContent
                        }
                        #if os(iOS)
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.immediately)
                        .refreshable {
                            viewModel.flushPendingRefresh()
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                        #endif
                        .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)
                    } else if searchFilter.resourceKind == .characterCard {
                        resourceResultsView(kind: .characterCard)
                    } else if searchFilter.resourceKind == .worldBook {
                        resourceResultsView(kind: .worldBook)
                    } else if searchFilter.resourceKind == .memory {
                        resourceResultsView(kind: .memory)
                    } else if searchFilter.resourceKind == .file {
                        resourceResultsView(kind: .file)
                    } else if searchFilter.resourceKind.usesResourceHits {
                        resourceResultsView(kind: searchFilter.resourceKind)
                    } else {
                        ScrollView {
                            messageSearchContent
                        }
                        #if os(iOS)
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.immediately)
                        .refreshable {
                            viewModel.flushPendingRefresh()
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                        #endif
                        .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)
                    }
                }
            } else {
                #if os(macOS)
                macConversationList
                    .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)
                #else
                // MARK: - Normal Conversation List
                // 「最近搜过」盖在上面，列表在底下隐藏但不拆：关掉最近搜过时停在原处，不回顶部
                VStack(spacing: 0) {
                if !searchErrors.isEmpty {
                    queryErrorCard
                        .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)

                    Spacer(minLength: 0)
                } else if isIOSStyle && shouldShowCompactListEmptyState && currentFolder == nil {
                    compactEmptyCard(
                        icon: compactListEmptyStateIcon,
                        title: compactListEmptyStateTitle,
                        subtitle: compactListEmptyStateSubtitle,
                        showImport: searchText.isEmpty && !showTrash && !showFavoritesOnly && selectedTagId == nil
                    )
                    .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)

                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            conversationListContent
                        }
                        #if os(iOS)
                        .background(Page0ScrubberAnchor(model: page0Scrubber).frame(width: 0, height: 0))
                        #endif
                    }
                    #if os(iOS)
                    // iPhone 系统竖条换自绘 Page0Scrubber（plan-page0-scrubber），iPad 保持系统条
                    .scrollIndicators(Page0ScrubberModel.systemIndicator, axes: .vertical)
                    .scrollDismissesKeyboard(.immediately)
                    .refreshable {
                        viewModel.flushPendingRefresh()
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    }
                    .modifier(Page0ListTopFade())
                    .overlay { page0ScrubberOverlay }
                    #endif
                    .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)
                }
                } // end 列表（最近搜过盖在上面）
                .opacity(showRecentSearches ? 0 : 1)
                .allowsHitTesting(!showRecentSearches)
                .overlay(alignment: .top) {
                    if showRecentSearches { recentSearchesCover }
                }
                #endif
            }
            } // end card container
            #if os(iOS)
            // 计数 / 搜索导航压在卡片底部，底下垫一层 mainBg 渐变遮罩（plan-page0-brand-layout）
            .overlay(alignment: .bottom) {
                if showsIOSCardFooter { iosCardFooter }
            }
            #endif

            #if os(iOS)
            iosBottomBar
            #else
            // Stats footer + settings
            HStack(spacing: 8) {
                footerInfo

                // 宽屏下这颗压在对话窗右下角的缩放弧底下，两个手势抢一个点 → 收掉，入口在顶部悬浮条
                if !widePanelMode {
                    Button(action: {
                        #if os(macOS)
                        openSettings()
                        #else
                        showSettings = true
                        #endif
                    }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: Theme.F.sectionHeader))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, isIOSStyle ? 20 : 16)
            .padding(.vertical, isIOSStyle ? 6 : 6)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if isIOSStyle {
                ZStack {
                    Theme.sidebarBg.ignoresSafeArea()
                    #if os(iOS)
                    if onMetal {
                        Page0LiquidMetalBackground()
                    }
                    #endif
                }
            } else {
                #if os(macOS)
                ShellStyle.chrome
                #else
                Theme.sidebarBg
                #endif
            }
        }
        .onAppear {
            #if DEBUG
            ShellProbe.keep("[PROBE sidebar.appear] pid=\(profileId.prefix(8)) tab=\(currentTab)")
            #endif
            #if (DEBUG || PERF_BENCH) && os(iOS)
            PerfHarness.registerList(launchSignal, profile: profileId, open: { openFromList($0) })
            let appearSpan = LaunchTrace.begin("page0.onAppear")
            defer { LaunchTrace.end("page0.onAppear", appearSpan) }
            #endif
            #if os(iOS)
            syncMetalStatusBar()
            #endif
            #if (DEBUG || PERF_BENCH) && os(iOS)
            LaunchTrace.measure("page0.migration") {
                FolderMigration.runIfNeeded(context: modelContext)
                FavoriteTagMigration.runIfNeeded(context: modelContext)
            }
            LaunchTrace.measure("page0.tags") { reloadTags() }
            LaunchTrace.measure("page0.list") { refreshList() }
            #else
            FolderMigration.runIfNeeded(context: modelContext)
            FavoriteTagMigration.runIfNeeded(context: modelContext)
            reloadTags()
            refreshList()
            #endif
            #if os(iOS)
            loadRecentSearches()
            launchSignal?.note("contentReady")
            #endif
        }
        #if os(iOS)
        // 筛选：和思考链同一个 sheet 壳（DisclosureSheet），由搜索框里的 ≡ 打开
        .sheet(isPresented: $showFilterSheet) {
            DisclosureSheet(title: "筛选") { filterSheetContent }
        }
        #endif
        // C4 刷新点 2：profileId 变（`.id(profile.id)` 通常已让整棵 re-init 走 onAppear，
        // 这里兜住不 re-init 的 edge case）。
        .onChange(of: profileId) { _, _ in
            reloadTags()
            #if os(iOS)
            loadRecentSearches()
            #endif
        }
        // C4 刷新点 3：ConversationTag 本体被写（新建 / 删除 / 拖拽排序）。
        .onReceive(NotificationCenter.default.publisher(for: .conversationTagsChanged)) { _ in
            reloadTags()
        }
        // 路线 B 下 ContentView.id(profileId) 已经让 SidebarView 在 profile 切换时
        // 整棵 re-init，@State 自然清空。保留此 observer 作为 defense-in-depth：
        // 若 SidebarView 恰好处于某个 edge case 不 re-init（比如外层 sheet 直接调 switchTo），
        // 这里也能兜底清理 @State 里的 @Model ref。
        #if os(macOS)
        .modifier(OnNotify(.profileWillSwitch, action: resetMacProfileState))
        #else
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            #if DEBUG
            ShellProbe.keep("[PROBE sidebar.profileWillSwitch] pid=\(profileId.prefix(8)) had=\(conversations.count)/\(totalCount)")
            #endif
            // C4：tags 从 @Query 变成 @State 后也是「@State 里的 @Model ref」，同样要清。
            tags = []
            conversations = []
            exportingConversation = nil
            favoritedNodes = []
            deletedNodes = []
            clearResults()
            totalCount = 0
            renamingConversationId = nil
            selectedTagId = nil
            searchText = ""
        }
        #endif
        .onChange(of: searchText) { _, newValue in
            // 300ms 防抖：每键击原来跑 fetchCount+fetch 两次同步 SQLite 查询（contains 无索引）。
            // 清空路径保持即时；onSubmit 深搜不走这里（B9 顺带 P2）
            filterDebounceTask?.cancel()
            // 拼音组字中（框里还是 mi gu 这种未上屏的字母）不过滤：列表保持原样，上屏后再按真字搜
            if !newValue.isEmpty && isComposingSearchText {
                typingBodyTask?.cancel()
                return
            }
            let bodyPathTookOver = scheduleTypingBodySearch(newValue)
            if newValue.isEmpty {
                clearSearch()
                refreshList()
            } else if !bodyPathTookOver {
                filterDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled, !isComposingSearchText else { return }
                    refreshList()
                }
            }
        }
        .onChange(of: selectedTagId) { _, _ in refreshList() }
        #if os(iOS)
        .onChange(of: liquidMetal) { _, _ in syncMetalStatusBar() }
        #endif
        .onChange(of: intimacyShown) { _, _ in intimacyVisibilityChanged() }
        .onChange(of: showImporter) { _, showing in if !showing { refreshList() } }
        .onChange(of: showSettings) { _, showing in if !showing { refreshList() } }
        // 内容改动重排 / 同步导入：列表本身没换，保住已加载的页数，否则只剩第一页、滚动位置被截掉跳走
        .onChange(of: viewModel.sidebarRefreshTrigger) { _, _ in refreshList(keepLoaded: true) }
        .onReceive(NotificationCenter.default.publisher(for: .syncDidImport)) { _ in refreshList(keepLoaded: true) }
        .sheet(isPresented: $showNewTagSheet) {
            FolderEditSheet(profileId: profileId, tag: nil) { created in
                reloadTags()
                selectTab(.tag(id: created.id))
            }
        }
        #if os(iOS)
        .sheet(item: $editingRoom) { room in
            GroupEditSheet(room: room, viewModel: agoraViewModel)
        }
        #endif
        .sheet(item: $editingFolder) { folder in
            FolderEditSheet(profileId: profileId, tag: folder)
        }
        // Settings sheet is presented from ContentView for proper centering
        .sheet(item: $exportingConversation) { conversation in
            ExportOptionsSheet(
                conversation: conversation,
                viewModel: viewModel,
                userName: userName,
                assistantName: assistantName
            )
        }
        .sheet(item: Binding(
            get: { highlightJumpWord.map { SidebarJumpWord(word: $0) } },
            set: { if $0 == nil { highlightJumpWord = nil } }
        )) { j in
            VocabWordDetailSheet(word: j.word)
        }
        .modifier(FavoriteTagHost(target: $favoriteTagTarget, renaming: $renamingFavoriteTag,
                                  renameText: $favoriteTagRenameText,
                                  onChanged: { refreshList(keepLoaded: true) },
                                  onRename: { renameFavoriteTag($0, to: $1) }))
        #if os(iOS)
        // iOS 不在行内改名（粟粟拍）：走系统 alert 输入框，和聊天页顶栏重命名同一手感。
        .alert("重命名", isPresented: Binding(
            get: { renamingConversationId != nil },
            set: { if !$0 { renamingConversationId = nil } }
        )) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { renamingConversationId = nil }
            Button("确认") {
                if let id = renamingConversationId,
                   let conversation = conversations.first(where: { $0.id == id }) {
                    applyRename(to: conversation)
                } else {
                    renamingConversationId = nil
                }
            }
        }
        #endif
    }

    /// 底部资料行：对话计数 / 回收站计数 / 搜索态（清除 + 结果数 + ↑↓）。mac 在独立底栏，iOS 压在卡片底部。
    @ViewBuilder
    private var footerInfo: some View {
        if isCodeTab {
            codeTabFooter
        } else if isSearchActive {
            Button(action: { clearSearch() }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.F.caption))
                    Text("清除搜索")
                        .font(.caption2)
                }
                .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)

            // 搜索结果计数
            if !isSearching {
                resultCountLabel()
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            searchMatchNav
        } else if showTrash {
            Text("回收站中 \(totalCount) 条对话")
                .font(.caption2)
                .foregroundColor(Theme.textMuted)
            Spacer()
        } else if showFavoritesOnly && favoritesKind != .conversations {
            Text(favoritesKind == .messages ? "\(visibleFavoritedNodes.count) 条收藏的消息" : "\(chatHighlightRows.count) 处划线")
                .font(.caption2)
                .foregroundColor(Theme.textMuted)
            Spacer()
        } else if showsOnlyRooms {
            Text("\(visibleRooms.count) 个群聊")
                .font(.caption2)
                .foregroundColor(Theme.textMuted)
            Spacer()
        } else {
            Text("显示 \(conversations.count) / \(totalCount) 条对话")
                .font(.caption2)
                .foregroundColor(Theme.textMuted)
            Spacer()
        }

    }

    /// 匹配索引 + 上下快速翻页（只对消息命中）
    @ViewBuilder
    private var searchMatchNav: some View {
        if !flatMatches.isEmpty {
            Text("\(currentMatchIndex + 1)/\(flatMatches.count)")
                .font(.caption2)
                .foregroundColor(Theme.textMuted)
                .monospacedDigit()
            Button(action: { navigatePrev() }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: Theme.F.caption, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
            Button(action: { navigateNext() }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: Theme.F.caption, weight: .medium))
                    .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
        }
    }

    private var advancedFilterPanel: some View {
        AdvancedSearchPanel(
            filter: $searchFilter,
            userName: userName,
            assistantName: assistantName,
            // 角色筛选只在「对话 + 搜 content + 已按➡️」场景有意义
            isContentSearchActive: isSearchActive && searchFilter.resourceKind == .conversation && searchFilter.scope != .titleOnly,
            onFilterChanged: {
                listSortOrder = searchFilter.sortOrder
                triggerSearchIfActive()
            }
        )
    }

    #if os(iOS)
    // MARK: - 主列表可拖滚动条（plan-page0-scrubber）

    /// iPhone 专用（iPad 保持系统竖条）；轨道底让开卡片底部计数条
    @ViewBuilder
    private var page0ScrubberOverlay: some View {
        if Page0ScrubberModel.isEnabledDevice {
            Page0Scrubber(
                model: page0Scrubber,
                enabled: !showRecentSearches,
                bottomInset: showsIOSCardFooter ? 52 : 10,
                entries: { page0ScrubberEntries() },
                onLoadMore: { loadMore() }
            )
        }
    }

    /// 抓住那一刻的列表快照。小标：置顶段 →「置顶」、按标题排序 → 首字、其余 → 对话 updateTime / 群聊 updatedAt
    private func page0ScrubberEntries() -> Page0Scrubber.Entries {
        let items = listItems
        let conversationById = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let roomById = Dictionary(visibleRooms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinSections = showPinSections && !showsOnlyRooms
        let byTitle = listSortOrder == .titleAZ || listSortOrder == .titleZA
        let roomRows = items.reduce(0) { n, item in
            if case .room = item { return n + 1 }
            return n
        }
        return Page0Scrubber.Entries(ids: items.map(\.id), total: showsOnlyRooms ? items.count : totalCount + roomRows) { i in
            switch items[i] {
            case .conversation(let id):
                guard let conversation = conversationById[id] else { return nil }
                if pinSections && conversation.isPinned { return .pinned }
                return byTitle ? .title(conversation.title) : .date(conversation.updateTime)
            case .room(let id):
                guard let room = roomById[id] else { return nil }
                return byTitle ? .title(room.title) : .date(room.updatedAt)
            }
        }
    }
    #endif

    #if os(iOS)
    // MARK: - 全局搜索（plan-page0-global-search）：A 打字 / B 结果页 / C 筛选抽屉

    /// 空态卡是一张短卡、下面露底色：这时计数行不垫渐变，直接落在底色上
    private var isCompactEmptyCard: Bool {
        if isSearchActive {
            return !isSearching && allResultsEmpty
        }
        return shouldShowCompactListEmptyState || showRecentSearches || !searchErrors.isEmpty
    }

    /// B 状态只剩「第几个命中 + ↑↓」；没有命中就整条不画
    private var showsIOSCardFooter: Bool {
        (!isSearchActive && searchErrors.isEmpty) || !flatMatches.isEmpty
    }

    private var iosCardFooter: some View {
        HStack(spacing: 8) {
            if isSearchActive {
                Spacer()
                searchMatchNav
            } else {
                footerInfo
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Theme.mainBg.opacity(0), location: 0),
                    .init(color: Theme.mainBg.opacity(0.92), location: 0.55),
                    .init(color: Theme.mainBg, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            .opacity(isCompactEmptyCard ? 0 : 1)
        )
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        .padding(.horizontal, 20)
    }

    /// 底栏：搜索长条 + 设置圆钮（在搜时换成 ✕ 退出搜索）。打字时框里只有 ➡️；结果页（键盘已收）换成 ✕ 退出搜索。
    private var iosBottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textMuted)

                TextField("搜索", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.F.body))
                    .focused($searchFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { submitSearch() }

                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    if isSearchActive && !searchFieldFocused {
                        Button {
                            searchText = ""   // onChange(searchText) 清空 → clearSearch + refreshList
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textMuted)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: submitSearch) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.branchIndicator)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    searchFieldFocused = false
                    showFilterSheet = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(activeConditions.isEmpty ? Theme.textMuted : Theme.branchIndicator)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular.tint(Color.white.opacity(0.15)), in: .capsule)

            // 宽屏下这颗压在对话窗右下角的缩放弧底下，两个手势抢一个点 → 收掉，入口在顶部悬浮条
            // 在搜的时候齿轮换成 ✕ 退出搜索：「最近搜过」卡不是 ScrollView，下滑 / 点空白都收不了键盘
            if !widePanelMode {
                Button(action: { if isInSearchMode { exitSearch() } else { showSettings = true } }) {
                    Image(systemName: isInSearchMode ? "xmark" : "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(onMetal ? .white : Theme.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.snappy(duration: 0.2), value: isInSearchMode)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// 在搜：框聚焦（打字 / 最近搜过）、框里有字（标题过滤）、结果页、查询报错卡
    private var isInSearchMode: Bool {
        searchFieldFocused || !searchText.isEmpty || isSearchActive || !searchErrors.isEmpty
    }

    /// 底栏 ✕：收键盘、清搜索词和结果、搜索专属条件回默认；列表的文件夹 / 收藏 / 回收站不动，选中的类型记在本机也不动
    private func exitSearch() {
        searchFieldFocused = false
        searchFilter.scope = .both
        searchFilter.dateRange = .all
        searchFilter.roles = Self.bothRoles
        searchFilter.sortOrder = .relevance
        searchFilter.extensions = []
        searchFolder = .all
        searchStarredOnly = false
        if searchText.isEmpty {
            clearSearch()
        } else {
            searchText = ""   // onChange(searchText) 清空 → clearSearch + refreshList
        }
    }

    /// 回车：框里的文字按 mac Query 解析，映射到标签 / 胶囊 / 筛选；有不支持的条件就报错不搜（S2-5）
    private func submitSearch() {
        let (state, errors) = SearchQueryMapping.parse(searchText)
        if errors.isEmpty {
            applyQueryState(state)
            triggerSearch()
        } else {
            clearSearch()
            searchErrors = errors
        }
        searchFieldFocused = false
    }

    private var queryState: SearchQueryMapping.State {
        SearchQueryMapping.State(words: searchFilter.words, kinds: searchKinds, scope: searchFilter.scope,
                                 roles: searchFilter.roles, dateRange: searchFilter.dateRange,
                                 sort: searchFilter.sortOrder, starredOnly: searchStarredOnly,
                                 extensions: searchFilter.extensions)
    }

    private func applyQueryState(_ state: SearchQueryMapping.State) {
        searchFilter.words = state.words
        if let kinds = state.kinds { setSearchKinds(kinds) }
        searchFilter.resourceKind = SearchQueryMapping.currentKind(.conversation, in: searchKinds)
        searchFilter.scope = state.scope
        searchFilter.roles = state.roles
        searchFilter.dateRange = state.dateRange
        searchFilter.sortOrder = state.sort
        searchStarredOnly = state.starredOnly
        searchFilter.extensions = state.extensions
    }

    static let searchKindsKey = "search.selectedKinds"

    private func setSearchKinds(_ kinds: Set<SearchResourceKind>) {
        searchKinds = kinds
        UserDefaults.standard.set(SearchQueryMapping.stored(kinds), forKey: Self.searchKindsKey)
    }

    private func toggleSearchKind(_ kind: SearchResourceKind) {
        let next = SearchQueryMapping.toggle(kind, selected: searchKinds, current: searchFilter.resourceKind)
        setSearchKinds(next.selected)
        searchFilter.resourceKind = next.current
    }

    private var queryErrorCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("这条查询还差一点")
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .foregroundColor(Theme.danger)
            Text(searchErrors.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " "))
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: A · 最近搜过

    private var showRecentSearches: Bool {
        searchFieldFocused && searchText.isEmpty && !isSearchActive && !recentSearches.isEmpty
    }

    private var recentSearchesKey: String {
        "sidebar.recentSearches.\(profileManager?.currentProfile.id ?? "")"
    }

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
    }

    private func rememberSearch(_ keyword: String) {
        guard !keyword.isEmpty else { return }
        recentSearches = Array(([keyword] + recentSearches.filter { $0 != keyword }).prefix(10))
        UserDefaults.standard.set(recentSearches, forKey: recentSearchesKey)
    }

    private func forgetSearch(_ keyword: String) {
        recentSearches.removeAll { $0 == keyword }
        UserDefaults.standard.set(recentSearches, forKey: recentSearchesKey)
    }

    /// 卡片照旧短短一张、下面露底色；整块吃点按（列表点不到也滚不动），点空白处收键盘
    private var recentSearchesCover: some View {
        VStack(spacing: 0) {
            recentSearchesCard
                .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { searchFieldFocused = false }
    }

    private var recentSearchesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近搜过")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(recentSearches, id: \.self) { word in
                    Text(word)
                        .font(.system(size: Theme.F.secondary))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                        .contentShape(Capsule())
                        .onTapGesture {
                            searchText = word
                            submitSearch()
                        }
                        .contextMenu {
                            Button(role: .destructive) { forgetSearch(word) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: B · 「搜什么」标签栏

    private func kindTitle(_ kind: SearchResourceKind) -> String {
        switch kind {
        case .conversation: return "对话"
        case .branchContent: return "分支"
        case .sticker: return "贴纸"
        case .characterCard: return "助手模板"
        case .worldBook: return "世界书"
        case .memory: return "记忆"
        case .file: return "文件"
        #if PERSONAL_APPS
        case .trading: return "交易"
        #endif
        case .health: return "健康"
        case .library: return "书房"
        case .twitter: return "推特"
        }
    }

    private var isConversationKind: Bool {
        searchFilter.resourceKind == .conversation || searchFilter.resourceKind == .branchContent
    }

    private var currentKindResultCount: Int {
        switch searchFilter.resourceKind {
        case .conversation, .branchContent: return searchResults.count
        case .sticker: return stickerSearchResults.count
        case .characterCard: return characterCardResults.count
        case .worldBook: return worldBookEntryResults.count
        case .memory: return memoryResults.count
        case .file: return fileResults.count
        #if PERSONAL_APPS
        case .trading, .health, .library: return resourceHits.count
        #else
        case .health, .library: return resourceHits.count
        #endif
        case .twitter: return tweetTotal
        }
    }

    /// nil = 还在算
    private func kindCount(_ kind: SearchResourceKind) -> Int? {
        if kind == searchFilter.resourceKind { return isSearching ? nil : currentKindResultCount }
        return kindCounts[kind]
    }

    private var searchKindTabBar: some View {
        TabBarGestureContainer {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(displayedKindTabs.enumerated()), id: \.element) { index, kind in
                        kindTab(kind, isFirst: index == 0)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .onAppear { arrangeKindTabs() }
        .onChange(of: kindCounts) { _, _ in arrangeKindTabs() }
        .onChange(of: searchKinds) { _, _ in arrangeKindTabs() }
    }

    /// 只出选中的类型；还没排过就按固定顺序
    private var displayedKindTabs: [SearchResourceKind] {
        let order = kindTabOrder.isEmpty ? SearchQueryMapping.ordered(searchKinds) : kindTabOrder
        return order.filter(searchKinds.contains)
    }

    /// 有结果的排前面按数量从多到少，还在算的居中，0 条的排最后；当前标签留在原来的位置
    private func arrangeKindTabs() {
        guard !kindTabsSettled else { return }
        if searchKinds.allSatisfy({ kindCount($0) != nil }) {
            settleKindTabs()
            return
        }
        let current = searchFilter.resourceKind
        let others = SearchQueryMapping.ordered(searchKinds).filter { $0 != current }
        func rank(_ kind: SearchResourceKind) -> Int {
            guard let count = kindCounts[kind] else { return 1 }
            return count > 0 ? 0 : 2
        }
        let sorted = others.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            if ra != rb { return ra < rb }
            let ca = kindCounts[a.element] ?? 0, cb = kindCounts[b.element] ?? 0
            if ca != cb { return ca > cb }
            return a.offset < b.offset
        }.map(\.element)
        var order = sorted
        order.insert(current, at: min(kindTabOrder.firstIndex(of: current) ?? 0, sorted.count))
        kindTabOrder = order
    }

    /// 数字全回来：按结果数排一次并定住；当前停在 0 条、且这一轮没点过标签 → 切到结果最多的那个（09-26 实拍：落在空标签上很误导）
    private func settleKindTabs() {
        let ordered = SearchQueryMapping.ordered(searchKinds)
        let sorted = ordered.enumerated().sorted { a, b in
            let ca = kindCount(a.element) ?? 0, cb = kindCount(b.element) ?? 0
            if (ca > 0) != (cb > 0) { return ca > 0 }
            if ca != cb { return ca > cb }
            return a.offset < b.offset
        }.map(\.element)
        kindTabOrder = sorted
        kindTabsSettled = true
        let current = searchFilter.resourceKind
        if !userPickedKindTab, (kindCount(current) ?? 0) == 0, let best = sorted.first, best != current, (kindCount(best) ?? 0) > 0 {
            if !isSearching { kindCounts[current] = currentKindResultCount }
            searchFilter.resourceKind = best
            triggerSearch(recount: false)
        }
    }

    private func kindTab(_ kind: SearchResourceKind, isFirst: Bool) -> some View {
        let isSelected = searchFilter.resourceKind == kind
        let isEmpty = !isSelected && kindCount(kind) == 0
        return Button {
            guard !isSelected else { return }
            userPickedKindTab = true
            // 切走前把当前这种的数留下来（它不在 kindCounts 里）
            if !isSearching { kindCounts[searchFilter.resourceKind] = currentKindResultCount }
            searchFilter.resourceKind = kind
            triggerSearch(recount: false)
        } label: {
            HStack(spacing: 4) {
                Text(kindTitle(kind))
                    .font(.system(size: Theme.F.secondary, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Theme.textPrimary : (onMetal ? Color.white.opacity(0.78) : Theme.textSecondary))
                Text(kindCount(kind).map { "\($0)" } ?? "…")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(isSelected || !onMetal ? Theme.textMuted : Color.white.opacity(0.6))
                    .monospacedDigit()
            }
            .opacity(isEmpty ? 0.45 : 1)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: tabCornerRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: tabCornerRadius
                )
                .fill(isSelected ? Theme.mainBg : Color.clear)
            )
            .overlay(alignment: .bottomLeading) {
                if isSelected && !isFirst {
                    InverseTabCorner(radius: 8, flipped: true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    InverseTabCorner(radius: 8, flipped: false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .zIndex(isSelected ? 1 : 0)
    }

    // MARK: B · 细栏（排序 / 已生效条件 / 筛选）

    private struct ActiveCondition: Identifiable {
        let id: String
        let label: String
        let reset: () -> Void
    }

    private func dateRangeLabel(_ range: DateRange) -> String {
        switch range {
        case .all: return "不限"
        case .today: return "今天"
        case .last7Days: return "7 天"
        case .last30Days: return "30 天"
        case .last90Days: return "90 天"
        case .custom(let start, let end):
            let day: (Date) -> String = { $0.formatted(.dateTime.month(.defaultDigits).day()) }
            return "\(start == .distantPast ? "不限" : day(start))–\(end == .distantFuture ? "不限" : day(end))"
        }
    }

    private func folderLabel(_ tab: SidebarTab) -> String {
        tab.isCustom ? tagLabel(for: tab) : tab.displayTitle
    }

    private static let bothRoles: Set<String> = ["user", "assistant"]

    private var activeConditions: [ActiveCondition] {
        var result: [ActiveCondition] = []
        if searchFilter.dateRange != .all {
            result.append(ActiveCondition(id: "date", label: dateRangeLabel(searchFilter.dateRange)) {
                searchFilter.dateRange = .all
            })
        }
        if searchFilter.resourceKind == .file && !searchFilter.extensions.isEmpty {
            result.append(ActiveCondition(id: "ext", label: searchFilter.extensions.map { "." + $0 }.joined(separator: " / ")) {
                searchFilter.extensions = []
            })
        }
        if isConversationKind {
            if searchFilter.scope != .both {
                result.append(ActiveCondition(id: "scope", label: searchFilter.scope == .titleOnly ? "只搜标题" : "只搜正文") {
                    searchFilter.scope = .both
                })
            }
            if searchFilter.scope != .titleOnly && searchFilter.roles != Self.bothRoles {
                let who = searchFilter.roles.contains("user") ? userName : assistantName
                result.append(ActiveCondition(id: "roles", label: "谁说的：\(who)") {
                    searchFilter.roles = Self.bothRoles
                })
            }
            if searchStarredOnly {
                result.append(ActiveCondition(id: "starred", label: "只看收藏") {
                    searchStarredOnly = false
                })
            }
            if searchFolder != .all {
                result.append(ActiveCondition(id: "folder", label: folderLabel(searchFolder)) {
                    searchFolder = .all
                })
            }
        }
        return result
    }

    private var sortTitle: String {
        // 推特只按时间倒序（plan-search-s3 裁定 2），不跟排序菜单
        if searchFilter.resourceKind == .twitter { return "按时间" }
        switch searchFilter.sortOrder {
        case .relevance: return "相关度"
        case .recent: return "最近"
        case .oldest: return "最早"
        case .titleAZ: return "A→Z"
        case .titleZA: return "Z→A"
        }
    }

    private var searchSortBar: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("排序", selection: Binding(
                    get: { searchFilter.sortOrder },
                    set: { searchFilter.sortOrder = $0; conversationBuckets = nil; triggerSearch(recount: false) }
                )) {
                    Text("相关度").tag(SearchSort.relevance)
                    Text("最近").tag(SearchSort.recent)
                    Text("最早").tag(SearchSort.oldest)
                    Text("A→Z").tag(SearchSort.titleAZ)
                    Text("Z→A").tag(SearchSort.titleZA)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(sortTitle)
                        .font(.system(size: Theme.F.secondary, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(searchFilter.resourceKind == .twitter ? 0 : 1)
                }
                .foregroundColor(Theme.textPrimary)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .disabled(searchFilter.resourceKind == .twitter)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activeConditions) { condition in
                        HStack(spacing: 3) {
                            Text(condition.label)
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: Theme.F.caption, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.branchIndicator.opacity(0.22)))
                        .contentShape(Capsule())
                        .onTapGesture {
                            condition.reset()
                            triggerSearch()
                        }
                    }
                }
            }

        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.mainBg)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.3)
        }
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: searchFilter.resourceKind == displayedKindTabs.first ? 0 : 16,
            topTrailingRadius: 16
        ))
        .padding(.horizontal, 20)
    }

    // MARK: C · 筛选 sheet

    private var filterSheetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(searchFilter.keyword.isEmpty
                 ? kindTitle(searchFilter.resourceKind)
                 : "\(kindTitle(searchFilter.resourceKind)) · \(searchFilter.keyword)")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)

            drawerGroups

            HStack(spacing: 10) {
                Button(action: resetSearchFilters) {
                    Text("重置")
                        .font(.system(size: Theme.F.body, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 88)
                        .frame(height: 44)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button { showFilterSheet = false } label: {
                    Text(!isSearchActive || isSearching ? "完成" : "完成（显示 \(currentKindResultCount) 条）")
                        .font(.system(size: Theme.F.body, weight: .semibold))
                        .foregroundColor(Theme.mainBg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(Theme.textPrimary))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 28)
        }
    }

    private var drawerFolders: [SidebarTab] {
        [.all, .favorites, .trash] + tags.map { .tag(id: $0.id) }
    }

    @ViewBuilder
    private var drawerGroups: some View {
        // 列表显示设置：不跟搜索状态 / 上次搜的资料类型走，打开 ≡ 永远在最上面
        drawerGroup("列表样式") {
            drawerChip("紧凑", on: listStyle == "compact", search: false) { listStyle = "compact" }
            drawerChip("详细", on: listStyle == "detailed", search: false) { listStyle = "detailed" }
            drawerChip("纯净", on: listStyle == "pure", search: false) { listStyle = "pure" }
        }

        if agoraEnabled {
            drawerGroup("群聊") {
                drawerChip("混在列表里", on: groupPlacement == "timeline", search: false) { groupPlacement = "timeline" }
                drawerChip("顶部头像条", on: groupPlacement == "strip", search: false) { groupPlacement = "strip" }
                drawerChip("只看群聊", on: groupPlacement == "only", search: false) { groupPlacement = "only" }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("类型")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button("全选") {
                    setSearchKinds(SearchQueryMapping.allKinds)
                    triggerSearch()
                }
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(searchKinds == SearchQueryMapping.allKinds ? Theme.textMuted : Theme.branchIndicator)
                .buttonStyle(.plain)
                .disabled(searchKinds == SearchQueryMapping.allKinds)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(SearchResourceKind.allCases, id: \.self) { kind in
                    let on = searchKinds.contains(kind)
                    drawerChip(kindTitle(kind), on: on, enabled: !(on && searchKinds.count == 1)) { toggleSearchKind(kind) }
                }
            }
        }
        .padding(.top, 18)

        if isConversationKind {
            drawerGroup("范围") {
                drawerChip("标题", on: searchFilter.scope == .titleOnly) { searchFilter.scope = .titleOnly }
                drawerChip("正文", on: searchFilter.scope == .contentOnly) { searchFilter.scope = .contentOnly }
                drawerChip("标题+正文", on: searchFilter.scope == .both) { searchFilter.scope = .both }
            }
        }

        drawerGroup("时间") {
            drawerChip("不限", on: searchFilter.dateRange == .all) { searchFilter.dateRange = .all }
            drawerChip("今天", on: searchFilter.dateRange == .today) { searchFilter.dateRange = .today }
            drawerChip("7 天", on: searchFilter.dateRange == .last7Days) { searchFilter.dateRange = .last7Days }
            drawerChip("30 天", on: searchFilter.dateRange == .last30Days) { searchFilter.dateRange = .last30Days }
            drawerChip("90 天", on: searchFilter.dateRange == .last90Days) { searchFilter.dateRange = .last90Days }
            drawerChip("自定义", on: isCustomDateRange) {
                searchFilter.dateRange = .custom(start: customStart, end: customEnd)
            }
        }
        if isCustomDateRange {
            HStack(spacing: 8) {
                DatePicker("", selection: $customStart, displayedComponents: .date)
                    .labelsHidden()
                Text("—")
                    .foregroundColor(Theme.textMuted)
                DatePicker("", selection: $customEnd, displayedComponents: .date)
                    .labelsHidden()
            }
            .padding(.top, 8)
            .onChange(of: customStart) { _, _ in applyCustomDateRange() }
            .onChange(of: customEnd) { _, _ in applyCustomDateRange() }
        }

        if isConversationKind && searchFilter.scope != .titleOnly {
            drawerGroup("谁说的") {
                drawerChip(userName, on: searchFilter.roles == ["user"]) { searchFilter.roles = ["user"] }
                drawerChip(assistantName, on: searchFilter.roles == ["assistant"]) { searchFilter.roles = ["assistant"] }
                drawerChip("都要", on: searchFilter.roles == Self.bothRoles) { searchFilter.roles = Self.bothRoles }
            }
        }

        if isConversationKind {
            drawerGroup("收藏") {
                drawerChip("不限", on: !searchStarredOnly) { searchStarredOnly = false }
                drawerChip("只看收藏", on: searchStarredOnly) { searchStarredOnly = true }
            }
            drawerGroup("所在文件夹") {
                ForEach(drawerFolders, id: \.self) { folder in
                    drawerChip(folderLabel(folder), on: searchFolder == folder) { searchFolder = folder }
                }
            }
        }
    }

    private var isCustomDateRange: Bool {
        if case .custom = searchFilter.dateRange { return true }
        return false
    }

    private func applyCustomDateRange() {
        searchFilter.dateRange = .custom(start: customStart, end: customEnd)
        triggerSearch()
    }

    private func drawerGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                content()
            }
        }
        .padding(.top, 18)
    }

    /// 点了立即生效：改完 filter 直接重搜（plan 决策 ②）
    private func drawerChip(_ title: String, on: Bool, enabled: Bool = true, search: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            action()
            if search { triggerSearch() }
        } label: {
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: on ? .semibold : .regular))
                .foregroundColor(on ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Theme.branchIndicator.opacity(0.22) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(on ? Theme.branchIndicator.opacity(0.7) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resetSearchFilters() {
        searchFilter.scope = .both
        searchFilter.dateRange = .all
        searchFilter.roles = Self.bothRoles
        searchFolder = .all
        searchStarredOnly = false
        searchFilter.extensions = []
        setSearchKinds(SearchQueryMapping.allKinds)
        triggerSearch()
    }
    #endif

    /// 行内改名只留 macOS；iOS 走系统 alert（见 body 尾部）。
    private func isInlineRenaming(_ conversationId: String) -> Bool {
        #if os(macOS)
        return renamingConversationId == conversationId
        #else
        return false
        #endif
    }

    private func applyRename(to conversation: Conversation) {
        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newTitle.isEmpty {
            conversation.title = newTitle
            conversation.updateTime = Date()
            viewModel.markConversationDirty()
        }
        renamingConversationId = nil
    }

    #if os(iOS)
    private func agoraRoomRow(_ room: AgoraRoomSummary) -> some View {
        Page0AgoraRow(room: room, viewModel: agoraViewModel, detailed: listStyle == "detailed",
                      pure: listStyle == "pure",
                      isSelected: agoraViewModel.selectedRoomId == room.id,
                      unread: agoraViewModel.unreadCount(for: room)) { onSelectAgoraRoom(room.id) }
            .contextMenu { agoraRoomMenu(room) }
    }

    @ViewBuilder
    private func agoraRoomMenu(_ room: AgoraRoomSummary) -> some View {
        Button("编辑群聊…") { editingRoom = room }
        Menu("移到文件夹") {
            ForEach(tags, id: \.id) { tag in
                Button(tag.name) {
                    var folders = roomState.roomFolders
                    folders[room.id] = tag.id
                    roomState.roomFolders = folders
                    roomFolderRevision += 1
                }
            }
        }
        if roomState.roomFolders[room.id] != nil {
            Button("移出文件夹") {
                var folders = roomState.roomFolders
                folders.removeValue(forKey: room.id)
                roomState.roomFolders = folders
                roomFolderRevision += 1
            }
        }
    }

    private var agoraAvatarStrip: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(visibleRooms) { room in
                    Page0AgoraAvatar(room: room, viewModel: agoraViewModel, unread: agoraViewModel.unreadCount(for: room)) {
                        onSelectAgoraRoom(room.id)
                    }
                    .contextMenu { agoraRoomMenu(room) }
                }
                VStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .light))
                        .frame(width: 52, height: 52)
                        .overlay(Circle().stroke(Theme.textMuted.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    Text("新建群聊").font(.system(size: 11)).frame(width: 68)
                }
                .foregroundColor(Theme.textMuted)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCreateAgoraRoom)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("新建群聊")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
    }
    #endif

    /// 置顶分组头只在「置顶浮顶」排序生效时显示：非回收站、无搜索/筛选、且第一行确实是置顶
    /// （pinnedFirstSort 保证置顶全在最前，first 不置顶 = 一个置顶都没有）。
    private var showPinSections: Bool {
        guard !showTrash else { return false }
        let usingFilters = !searchText.isEmpty || searchFilter.dateRange != .all || listSortIsCustom
        return !usingFilters && conversations.first?.isPinned == true
    }

    #if os(iOS)
    private func syncMetalStatusBar() {
        guard Page0Stage.shared.lightStatusBar != onMetal else { return }
        Page0Stage.shared.lightStatusBar = onMetal
        PagingViewController.refreshStatusBar()
    }
    #endif

    private func listSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: Theme.F.caption, weight: .medium))
                .foregroundColor(Theme.textMuted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func toggleConversationPin(_ conversation: Conversation) {
        conversation.pinnedAt = conversation.isPinned ? nil : Date()
        #if os(macOS)
        try? modelContext.save()
        #endif
        refreshList()
    }

    /// 对话行长按 / 右键菜单（跨平台一份）：iOS 走 page1 同款自绘浮层（带 quickLabel 的进顶上图标排，
    /// 带 children 的卡内原地换页），mac 用 MenuActionSpec.menuItems 渲原生右键菜单（粟粟 10-11）
    private func conversationMenuSpecs(_ conversation: Conversation) -> [MenuActionSpec] {
        if showTrash {
            return [
                MenuActionSpec(title: "恢复", systemImage: "arrow.uturn.backward") {
                    viewModel.restoreConversation(conversation)
                    refreshList()
                },
                MenuActionSpec(title: "永久删除", systemImage: "trash.slash", isDestructive: true) {
                    viewModel.permanentlyDeleteConversation(conversation, context: modelContext)
                    refreshList()
                },
            ]
        }
        var specs: [MenuActionSpec] = [
            MenuActionSpec(title: "重命名", systemImage: "pencil", quickLabel: "Rename") {
                renameText = conversation.title
                renamingConversationId = conversation.id
            },
            MenuActionSpec(title: "重新生成标题", systemImage: "sparkles") {
                ConversationTitler.regenerate(conversation, context: modelContext, providerManager: providerManager)
            },
            MenuActionSpec(title: "复制对话", systemImage: "doc.on.doc", quickLabel: "Copy") {
                viewModel.duplicateConversation(conversation, context: modelContext)
                refreshList()
            },
            MenuActionSpec(title: conversation.isPinned ? "取消置顶" : "置顶对话",
                           systemImage: conversation.isPinned ? "pin.slash" : "pin", quickLabel: "Pin") {
                toggleConversationPin(conversation)
            },
            MenuActionSpec(title: conversation.isFavorite ? "取消收藏" : "收藏整个对话",
                           systemImage: conversation.isFavorite ? "star.slash" : "star", quickLabel: "Star") {
                FavoriteTags.setFavorite(conversation, !conversation.isFavorite)
            },
            MenuActionSpec(title: "收藏到标签…", systemImage: "tag") {
                favoriteTagTarget = FavoriteTags.Target(conversation: conversation)
            },
            MenuActionSpec(title: conversation.memoryEnabled ? "关闭记忆参与" : "开启记忆参与",
                           systemImage: conversation.memoryEnabled ? "brain" : "brain.head.profile") {
                conversation.memoryEnabled.toggle()
            },
        ]

        // 缓存保暖：按 tmux session 设（不是按对话）——共享同一 session 的
        // 对话共用一份 prompt cache，标题里带上 session 名让这件事看得见。
        if let ccSession = conversation.ccBridgeSessionName, !ccSession.isEmpty {
            let current = CCBridgeWebSocketClient.keepalivePolicy(for: ccSession)
            specs.append(MenuActionSpec(
                title: "缓存保暖 · \(ccSession)", systemImage: "flame",
                children: ["always", "auto", "never"].map { policy in
                    MenuActionSpec(title: keepalivePolicyLabel(policy),
                                   systemImage: current == policy ? "checkmark" : keepalivePolicyIcon(policy)) {
                        CCBridgeWebSocketClient.setKeepalivePolicy(policy, for: ccSession)
                    }
                }
            ) {})
        }

        if !tags.isEmpty {
            specs.append(MenuActionSpec(
                title: "移到文件夹", systemImage: "folder",
                children: tags.map { tag in
                    MenuActionSpec(title: tag.name, systemImage: conversation.folderId == tag.id ? "checkmark" : "folder") {
                        conversation.folderId = tag.id
                        try? modelContext.save()
                        refreshList()
                    }
                }
            ) {})
            if conversation.folderId != nil {
                specs.append(MenuActionSpec(title: "移出文件夹", systemImage: "folder.badge.minus") {
                    conversation.folderId = nil
                    try? modelContext.save()
                    refreshList()
                })
            }
        }
        specs[specs.count - 1].dividerAfter = true

        specs.append(MenuActionSpec(title: "新建文件夹…", systemImage: "folder.badge.plus", dividerAfter: true) {
            showNewTagSheet = true
        })
        specs.append(MenuActionSpec(title: "导出为 Markdown", systemImage: "doc.text", dividerAfter: true) {
            exportConversation(conversation)
        })
        specs.append(MenuActionSpec(title: "删除", systemImage: "trash", isDestructive: true, quickLabel: "Delete") {
            viewModel.softDeleteConversation(conversation)
            refreshList()
        })
        return specs
    }

    @ViewBuilder
    private func conversationRowView(_ conversation: Conversation, isStudy: Bool) -> some View {
        // 群聊房间选中时对话行不高亮（双选中态互斥；selectedConversation 保留不清，回聊天还在）
        let isSelected = viewModel.selectedConversation?.id == conversation.id && agoraViewModel.selectedRoomId == nil
        let favoriteTags: [String] = showFavoritesOnly ? (favoriteTagIndex.conversationTags[conversation.id] ?? []) : []
        #if os(iOS)
        let row = ConversationRow(
            conversation: conversation,
            isSelected: isSelected,
            isFirst: conversation.id == conversations.first?.id,
            isRunning: viewModel.ccWaitingSince[conversation.id] != nil,
            detailed: listStyle == "detailed",
            pure: listStyle == "pure",
            isStudy: isStudy,
            folderLabel: selectedTagId == nil ? conversation.folderId.map { tagLabel(for: .tag(id: $0)) }.flatMap { $0.isEmpty ? nil : $0 } : nil,
            favoriteTags: favoriteTags
        )
        .rowHover(selected: isSelected)
        row.onTapGesture { openFromList(conversation) }
        #else
        MacConversationRow(conversation: conversation, selected: isSelected, canPin: !showTrash,
            favoriteTags: favoriteTags,
            onSelect: {
                onSelectConversation()
                viewModel.loadConversation(conversation, context: modelContext)
                macListFocused = true
            },
            onRename: {
                renameText = conversation.title
                renamingConversationId = conversation.id
            },
            onPin: {
                toggleConversationPin(conversation)
            },
            menuItems: { MenuActionSpec.menuItems(from: conversationMenuSpecs(conversation)) })
        #endif
    }

    private func exportConversation(_ conversation: Conversation) {
        if exportMode == "full" {
            // Delay to let context menu dismiss first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                exportingConversation = conversation
            }
        } else {
            #if os(macOS)
            // Lightweight mode: show save panel first, then export
            let panel = NSSavePanel()
            panel.title = "导出 Markdown"
            panel.nameFieldStringValue = "\(MarkdownExporter.sanitizedFileName(conversation.title)).md"
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let markdown = MarkdownExporter.loadAndExport(
                    conversation: conversation,
                    context: modelContext,
                    mode: .longest,
                    userName: userName,
                    assistantName: assistantName
                )
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    viewModel.transientNotice = TransientNotice("导出失败：\(error.localizedDescription)")
                }
            }
            #endif
        }
    }

    private var shouldShowCompactListEmptyState: Bool {
        guard isIOSStyle else { return false }
        if showTrash {
            return conversations.isEmpty && deletedNodes.isEmpty
        }
        if showFavoritesOnly {
            return conversations.isEmpty && favoritedNodes.isEmpty && chatHighlightRows.isEmpty
        }
        return listItems.isEmpty && !showsRoomStrip
    }

    private var compactListEmptyStateIcon: String {
        if !searchText.isEmpty { return "magnifyingglass" }
        if showTrash { return "trash" }
        if showFavoritesOnly { return "star" }
        if selectedTagId != nil { return "tag" }
        return "bubble.left.and.bubble.right"
    }

    private var compactListEmptyStateTitle: String {
        if !searchText.isEmpty { return "没有匹配的对话" }
        if showTrash { return "回收站是空的" }
        if showFavoritesOnly { return "还没有收藏" }
        if selectedTagId != nil { return "还没有对话" }
        return "还没有对话"
    }

    private var compactListEmptyStateSubtitle: String {
        if !searchText.isEmpty { return "按回车在所有内容里搜" }
        if showTrash { return "删除的对话和气泡会出现在这里" }
        if showFavoritesOnly { return "收藏的对话、消息和划线会出现在这里" }
        if selectedTagId != nil { return "点右上 ＋ 在这里开新对话，或长按别的对话移进来" }
        return "导入或新建后会出现在这里"
    }

    @ViewBuilder
    private func compactEmptyCard(icon: String, title: String, subtitle: String, showImport: Bool = false) -> some View {
        let cardBody = VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: Theme.F.sectionHeader))
                .foregroundColor(Theme.textMuted.opacity(0.45))

            Text(title)
                .font(.system(size: Theme.F.sectionHeader, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            Text(subtitle)
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)

            if showImport {
                Button(action: { showImporter = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入聊天记录")
                    }
                    .font(.system(size: Theme.F.secondary, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.branchIndicator.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 170)

        #if os(iOS)
        // iOS 空态：ScrollView + 系统 .refreshable，和大卡下拉动画一致
        // （卡片跟手指下移 + 顶部 spinner 滑进）。frame(height: 170) 锁死小卡高度。
        // .scrollBounceBehavior(.always) 让没内容也能 bounce → refresh 可触发。
        // .scrollIndicators(.hidden) 去掉滚动条。
        ScrollView {
            cardBody
        }
        .frame(height: 170)
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .refreshable {
            viewModel.flushPendingRefresh()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        .scrollDismissesKeyboard(.immediately)
        #else
        cardBody
        #endif
    }

    #if os(macOS)
    private func resetMacProfileState() {
            #if DEBUG
            ShellProbe.keep("[PROBE sidebar.profileWillSwitch] pid=\(profileId.prefix(8)) had=\(conversations.count)/\(totalCount)")
            #endif
            // C4：tags 从 @Query 变成 @State 后也是「@State 里的 @Model ref」，同样要清。
            tags = []
            conversations = []
            exportingConversation = nil
            favoritedNodes = []
            deletedNodes = []
            clearResults()
            totalCount = 0
            renamingConversationId = nil
            selectedTagId = nil
            searchText = ""
    }

    private var macSearchToolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("搜索对话…", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($macSearchFocused)
                    .onSubmit { triggerSearch() }
                    .onExitCommand {
                        searchText = ""
                        clearSearch()
                        macSearchFocused = false
                        macListFocused = true
                    }
                    .accessibilityIdentifier("mac-conversation-search")
                if !searchText.isEmpty {
                    Button { searchText = ""; clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
                Button { showAdvancedFilter.toggle() } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .buttonStyle(.plain)
                .help("搜索范围与筛选")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(macSearchFocused ? Theme.branchIndicator : ShellStyle.hairline, lineWidth: 0.5)
            }
            Menu {
                Button("新建对话", action: createNewConversation)
                Button("新建 Codex 对话", action: createNewCodexConversation)
            } label: {
                Image(systemName: "square.and.pencil")
            } primaryAction: { createNewConversation() }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .help("新建对话（⌘N）；菜单可新建 Codex 对话")
            Button { showImporter = true } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(MacShellButton(width: 26))
            .help("导入对话")
        }
        .padding(12)

    }

    private var macConversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) { conversationListContent }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($macListFocused)
            .onKeyPress(.downArrow) { moveMacSelection(by: 1) }
            .onKeyPress(.upArrow) { moveMacSelection(by: -1) }
            .onKeyPress(.return) {
                guard renamingConversationId == nil, let selected = viewModel.selectedConversation,
                      conversations.contains(where: { $0.id == selected.id }) else { return .ignored }
                renameText = selected.title
                renamingConversationId = selected.id
                return .handled
            }
            .onChange(of: viewModel.selectedConversation?.id) { _, id in
                if macListFocused, let id { proxy.scrollTo(id) }
            }
            .accessibilityLabel("对话列表，方向键切换，Return 重命名")
        }
    }

    private func moveMacSelection(by step: Int) -> KeyPress.Result {
        guard renamingConversationId == nil, !conversations.isEmpty else { return .ignored }
        let current = conversations.firstIndex { $0.id == viewModel.selectedConversation?.id }
        let next = current.map { min(max($0 + step, 0), conversations.count - 1) }
            ?? (step > 0 ? 0 : conversations.count - 1)
        viewModel.loadConversation(conversations[next], context: modelContext)
        // Preserve list focus and visibility while traversing; Return/click handles opening.
        return .handled
    }
    #endif

    private var isIOSStyle: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    // MARK: - Chrome-style Tab Bar

    /// 左栏面板组切到 Code（mac）：整块内容 / 底栏换成编程会话（plan-wake-native §3 路由）。
    /// 由面板头的 tab 驱动（`MacLeftPanelGroup`），激活态仍是 `CodingSessionLibrary.isActive`
    private var isCodeTab: Bool {
        #if os(macOS)
        currentTab == .code
        #else
        false
        #endif
    }

    @ViewBuilder
    private var codeTabContent: some View {
        #if os(macOS)
        CodingSessionSidebarList(onOpen: onSelectConversation)
            .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)
        #endif
    }

    @ViewBuilder
    private var codeTabFooter: some View {
        #if os(macOS)
        Text("本机 Claude Code / Codex / Kimi 会话")
            .font(.caption2)
            .foregroundColor(Theme.textMuted)
            .lineLimit(1)
        Spacer()
        #endif
    }

    private var currentTab: SidebarTab {
        #if os(macOS)
        if CodingSessionLibrary.shared.isActive { return .code }
        #endif
        if showTrash { return .trash }
        if showFavoritesOnly { return .favorites }
        if let id = selectedTagId { return .tag(id: id) }
        return .all
    }

    private var allTabs: [SidebarTab] {
        // mac 的 Code 不在这排筛选里：它是左栏面板组的 tab（`MacLeftPanelGroup`，面板头「对话 | Code」）
        var result: [SidebarTab] = [.all, .favorites, .trash]
        result.append(contentsOf: tags.map { .tag(id: $0.id) })
        return result
    }

    private func selectTab(_ tab: SidebarTab) {
        #if os(macOS)
        if tab != .code { CodingSessionLibrary.shared.deactivate() }
        #endif
        switch tab {
        #if os(macOS)
        case .code:
            showFavoritesOnly = false
            showTrash = false
            selectedTagId = nil
            CodingSessionLibrary.shared.activate()
        #endif
        case .all:
            showFavoritesOnly = false
            showTrash = false
            selectedTagId = nil
        case .favorites:
            showFavoritesOnly = true
            showTrash = false
            selectedTagId = nil
        case .trash:
            showTrash = true
            showFavoritesOnly = false
            selectedTagId = nil
        case .tag(let id):
            selectedTagId = id
            showFavoritesOnly = false
            showTrash = false
        }
        refreshList()
        if tab == .favorites { settleFavoritesKind() }
        // 如果正在搜索，切 tab 后用新 scope 重跑搜索
        triggerSearchIfActive()
    }

    private let tabCornerRadius: CGFloat = 16

    /// 内容卡顶部两角：选中第一个标签时左上角是直角（连着标签）。
    /// iOS 搜索态卡片顶上接着细栏（细栏自己画圆角），卡片顶部两角都是直角。
    private var cardTopLeading: CGFloat {
        #if os(iOS)
        if isSearchActive { return 0 }
        #endif
        return currentTab == .all ? 0 : 16
    }

    private var cardTopTrailing: CGFloat {
        #if os(iOS)
        if isSearchActive { return 0 }
        #endif
        return 16
    }

    @State private var draggingTagId: String? = nil
    @State private var snappedTabId: SidebarTab? = nil

    private var sidebarTabBar: some View {
        #if os(iOS)
        // iOS：包一层 TabBarGestureContainer（UIHostingController wrapper），
        // 在容器 view 上挂 pan gesture，配合 TabView(.page) 的
        // require(toFail:) 屏蔽翻页
        return TabBarGestureContainer { sidebarTabBarBody }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        #else
        return ScrollView(.horizontal) {
            HStack(spacing: 3) {
                ForEach(Array(allTabs.enumerated()), id: \.element) { index, tab in
                    tabButton(tab, index: index, total: allTabs.count, fillWidth: false)
                }
                plusButton
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.automatic)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    @ViewBuilder
    private var sidebarTabBarBody: some View {
        let tabs = allTabs
        let hasCustomTags = !self.tags.isEmpty

        if hasCustomTags {
            // 有自定义 tag：「全部」锁定在左，其余进 ScrollView 横滚
            HStack(spacing: 0) {
                // 锁定的「全部」tab
                tabButton(tabs[0], index: 0, total: tabs.count, fillWidth: false)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                        HStack(spacing: 0) {
                            HStack(spacing: 0) {
                                ForEach(Array(tabs.dropFirst().enumerated()), id: \.element) { offset, tab in
                                    tabButton(tab, index: offset + 1, total: tabs.count, fillWidth: false)
                                        .id(tab)
                                }
                            }
                            .scrollTargetLayout()  // 只有 tab 是 snap 目标，加号不是
                            plusButton.id("plusButton")
                        }
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollPosition(id: $snappedTabId)
                    // 两侧都 clip 会切掉第一个 tab 的反向圆角（offset -8pt），
                    // 两侧都 clip off（scrollClipDisabled）又会让 tab 横滑时盖到「全部」上。
                    // 用 mask 自定义：leading 只延伸 8pt 给反向圆角，trailing 正常 clip。
                    .scrollClipDisabled()
                    .mask(
                        GeometryReader { geo in
                            Rectangle()
                                .frame(width: geo.size.width + 8, height: geo.size.height)
                                .offset(x: -8)
                        }
                    )
                    #if os(iOS)
                    .onChange(of: snappedTabId) { oldTab, newTab in
                        // Clock 齿轮手感：划过每个 tab 都震一下
                        if oldTab != nil && newTab != nil && oldTab != newTab {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    #endif
                    .onChange(of: currentTab) { _, newTab in
                        guard newTab != .all else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(newTab, anchor: .center)
                        }
                    }
                }
            }
            .padding(.leading, isIOSStyle ? 20 : 12)
            .padding(.trailing, isIOSStyle ? 20 : 12)
        } else {
            // 只有内置 tab：平分宽度铺满
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    tabButton(tab, index: index, total: tabs.count, fillWidth: true)
                }
                plusButton
            }
            .padding(.horizontal, isIOSStyle ? 20 : 12)
        }
    }

    private var plusButton: some View {
        Button {
            showNewTagSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Theme.F.secondary, weight: .medium))
                .foregroundColor(onMetal ? Color.white.opacity(0.7) : Theme.textMuted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func tabButton(_ tab: SidebarTab, index: Int, total: Int, fillWidth: Bool) -> some View {
        let isSelected = currentTab == tab
        let isFirst = index == 0

        let folder = tagIdOf(tab).flatMap { id in tags.first { $0.id == id } }

        Button { selectTab(tab) } label: {
            HStack(spacing: 4) {
                if let folder { FolderIconView(tag: folder, size: Theme.F.secondary) }
                Text(folder?.name ?? tab.displayTitle)
            }
                .font(.system(size: Theme.F.secondary, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Theme.textPrimary : (onMetal ? Color.white.opacity(0.78) : Theme.textSecondary))
                .lineLimit(1)
                .if(!fillWidth) { $0.fixedSize() }
                .padding(.horizontal, isIOSStyle ? 16 : 8)
                .padding(.vertical, isIOSStyle ? 8 : 6)
                .if(fillWidth) { $0.frame(maxWidth: .infinity) }
                #if os(macOS)
                .background(isSelected ? ShellStyle.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                #else
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: tabCornerRadius,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: tabCornerRadius
                    )
                    .fill(isSelected ? Theme.mainBg : Color.clear)
                )
                .overlay(alignment: .bottomLeading) {
                    if isSelected && !isFirst {
                        InverseTabCorner(radius: 8, flipped: true)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // 选中即显示右凹弧 — 最后一个 tab 右边是 "+" 按钮（sidebarBg），也需要过渡
                    if isSelected {
                        InverseTabCorner(radius: 8, flipped: false)
                    }
                }
                #endif
                .contentShape(Rectangle())   // 整个 frame 都响应点击，不只是 Text 区域
        }
        .buttonStyle(.plain)
        .zIndex(isSelected ? 1 : 0)
        .if(tab.isCustom) { view in
            view
                .onDrag {
                    if case .tag(let id) = tab {
                        draggingTagId = id
                        return NSItemProvider(object: id as NSString)
                    }
                    return NSItemProvider()
                }
                .onDrop(of: [UTType.text], delegate: TagReorderDropDelegate(
                    targetTagId: tagIdOf(tab) ?? "",
                    tags: tags,
                    modelContext: modelContext,
                    draggingTagId: $draggingTagId
                ))
                .contextMenu {
                    if case .tag(let id) = tab {
                        Button {
                            editingFolder = tags.first { $0.id == id }
                        } label: {
                            Label("编辑文件夹", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleteTag(id: id)
                        } label: {
                            Label("删除文件夹", systemImage: "trash")
                        }
                    }
                }
        }
    }

    private func tagIdOf(_ tab: SidebarTab) -> String? {
        if case .tag(let id) = tab { return id }
        return nil
    }

    private func tagLabel(for tab: SidebarTab) -> String {
        guard case .tag(let id) = tab,
              let t = tags.first(where: { $0.id == id }) else { return "" }
        return t.symbol.isEmpty ? "\(t.emoji) \(t.name)" : t.name
    }

    private func deleteTag(id: String) {
        guard let tag = tags.first(where: { $0.id == id }) else { return }
        let pid = profileManager?.currentProfile.id ?? ""
        // 删文件夹不删对话：里面的对话移回「全部」
        let memberIds = folderConversationIds(id)
        if !memberIds.isEmpty {
            let desc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.profileId == pid })
            for conv in (try? modelContext.fetch(desc)) ?? [] where memberIds.contains(conv.id) {
                conv.folderId = nil
            }
        }
        // 气泡级收藏（nodeId 非空）仍挂在 tag 上，一起清掉（仅当前楼层）
        let descriptor = FetchDescriptor<FavoriteItem>(
            predicate: #Predicate<FavoriteItem> { item in item.tagId == id && item.profileId == pid }
        )
        if let items = try? modelContext.fetch(descriptor) {
            for item in items { modelContext.delete(item) }
        }
        roomState.removeFolder(id)
        roomFolderRevision += 1
        modelContext.delete(tag)
        try? modelContext.save()
        // C4 写点：同步发通知，让 @State tags 立刻丢掉已删对象（不发 = tab 栏还挂着死 tag，
        // 点进去 fetchPage 空桶，kimi Y5）。post 是同步的，onReceive 在本函数返回前就跑完。
        NotificationCenter.default.post(name: .conversationTagsChanged, object: nil)
        // 如果当前选中的就是被删的，回落
        if selectedTagId == id {
            selectedTagId = nil
            refreshList()
        }
    }

    private func navigateToNode(_ node: MessageNode) {
        // Find the conversation for this node
        let convId = node.conversationId
        let pid = profileManager?.currentProfile.id ?? ""
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in
                conv.id == convId && conv.profileId == pid
            }
        )
        guard let conversation = try? modelContext.fetch(descriptor).first else { return }

        // B23：走 B20 统一入口——老路径只设 pendingScroll 不判分支，
        // 收藏的气泡在非当前分支上时 scrollTo 落空（id 不在 currentPath），
        // 且同对话内跳转缺 page 切换通知（iOS 停在列表页看不到滚动）
        onSelectConversation()
        viewModel.navigateToSearchResult(nodeId: node.id, conversation: conversation, context: modelContext)
    }

    /// Fetch all Conversation titles in one query, return as [id: title] map
    private func fetchConversationTitleMap() -> [String: String] {
        let pid = profileManager?.currentProfile.id ?? ""
        var desc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid }
        )
        desc.propertiesToFetch = [\.id, \.title]
        guard let allConvs = try? modelContext.fetch(desc) else { return [:] }
        var map: [String: String] = [:]
        map.reserveCapacity(allConvs.count)
        for conv in allConvs { map[conv.id] = conv.title }
        return map
    }

    private func fetchFavoritedNodes() {
        let pid = profileManager?.currentProfile.id ?? ""
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in
                node.profileId == pid && node.isFavorite == true && node.isTrashed == false
            },
            sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
        )
        guard let nodes = try? modelContext.fetch(descriptor) else {
            favoritedNodes = []
            return
        }

        let titleMap = fetchConversationTitleMap()
        favoritedNodes = nodes.map { node in
            (node: node, convTitle: titleMap[node.conversationId] ?? "未知对话")
        }
    }

    /// R3-2：聊天等处的划线聚合（当前楼层，新→旧）。一处（同锚同原文）一行；
    /// 消息划线 node 已删 / 失踪的不显示（数据保留）；思考过程 / 交易 / 话题卡 / 单词页的合成锚各自标来源。
    private func fetchChatHighlights() {
        let pid = profileManager?.currentProfile.id ?? ""
        let all = ChatHighlightStore.shared.highlights.filter { $0.profileId == pid }
        let places = NoteThreads.places(for: all.filter { $0.replyTo == nil }.map(\.id), in: all)
            .sorted { ($0.strokes.last?.createdAt ?? .distantPast) > ($1.strokes.last?.createdAt ?? .distantPast) }
        guard !places.isEmpty else {
            chatHighlightRows = []
            return
        }
        let nodeIds = Set(places.map { ChatHighlightListItem.messageNodeId($0.primary.nodeId) })
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in nodeIds.contains(node.id) }
        )
        let nodeMap = Dictionary(
            ((try? modelContext.fetch(descriptor)) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let titleMap = fetchConversationTitleMap()
        chatHighlightRows = places.compactMap { place in
            let anchor = place.primary.nodeId
            let summary = NoteThreads.summary(of: place, in: all)
            func item(_ source: String, _ node: MessageNode? = nil) -> ChatHighlightListItem {
                ChatHighlightListItem(place: place, node: node, source: source,
                                      latestNote: summary.latest, noteCount: summary.count)
            }
            // R5-1：词卡划线（合成锚）混排进收藏，标来源，点击开词详情
            if anchor.hasPrefix("vocab:") { return item("\(anchor.dropFirst("vocab:".count)) 的考古笔记") }
            if anchor.hasPrefix("vocabnote:") { return item("\(anchor.dropFirst("vocabnote:".count)) 的词条笔记") }
            #if PERSONAL_APPS
            if anchor.hasPrefix("ticker:") { return item("$\(anchor.dropFirst("ticker:".count)) 的笔记") }
            #endif
            #if PERSONAL_APPS
            #if DEBUG
            if anchor.hasPrefix("topic:") { return item("话题卡") }
            #endif
            #endif
            let nid = ChatHighlightListItem.messageNodeId(anchor)
            guard let node = nodeMap[nid], !node.isTrashed else { return nil }
            let title = titleMap[node.conversationId] ?? "未知对话"
            return item(anchor.hasPrefix("thinking:") ? "\(title) · 思考过程" : title, node)
        }
    }

    /// 点划线行：回到它所在的地方
    private func openHighlight(_ item: ChatHighlightListItem) {
        let anchor = item.place.primary.nodeId
        #if PERSONAL_APPS
        if anchor.hasPrefix("ticker:") {
            highlightTicker = String(anchor.dropFirst("ticker:".count))
            return
        }
        #endif
        if let node = item.node {
            navigateToNode(node)
            if anchor.hasPrefix("thinking:") {
                // 导航落地后让那条消息弹思考过程并闪这段（ContentView 词卡跳转同款）
                let quote = item.place.primary.quote
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NotificationCenter.default.post(name: VocabCollector.openThinkingNotification, object: nil,
                                                    userInfo: ["nodeId": node.id, "highlightWord": quote])
                }
            }
        } else if let w = VocabCollector.parseVocabAnchor(anchor) {
            highlightJumpWord = w
        } else if anchor.hasPrefix("topic:") {
            #if PERSONAL_APPS
            #if DEBUG
            let rest = anchor.dropFirst("topic:".count)
            highlightTopic = String(rest[..<(rest.lastIndex(of: "#") ?? rest.endIndex)])
            #endif
            #endif
        }
    }

    private func fetchDeletedNodes() {
        let pid = profileManager?.currentProfile.id ?? ""
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in
                node.profileId == pid && node.isTrashed == true
            },
            sortBy: [SortDescriptor(\MessageNode.trashedAt, order: .reverse)]
        )
        guard let nodes = try? modelContext.fetch(descriptor) else {
            deletedNodes = []
            return
        }

        let titleMap = fetchConversationTitleMap()
        deletedNodes = nodes.map { node in
            (node: node, convTitle: titleMap[node.conversationId] ?? "未知对话")
        }
    }

    /// 列表只看自己的排序；相关度在列表里按「最近」处理（置顶照旧在前）
    private var listSortIsCustom: Bool {
        listSortOrder != .recent && listSortOrder != .relevance
    }

    private func conversationSortDescriptors() -> [SortDescriptor<Conversation>] {
        switch listSortOrder {
        case .relevance, .recent:
            return [SortDescriptor(\Conversation.updateTime, order: .reverse)]
        case .oldest:
            return [SortDescriptor(\Conversation.updateTime, order: .forward)]
        case .titleAZ:
            return [SortDescriptor(\Conversation.title, order: .forward)]
        case .titleZA:
            return [SortDescriptor(\Conversation.title, order: .reverse)]
        }
    }

    private var flatMatches: [MatchedNode] {
        searchResults.flatMap { $0.matchedNodes }
    }

    /// 清空各类结果数组；except 那一类留着（对话 / 分支共用 searchResults）
    private func clearResults(except kind: SearchResourceKind? = nil) {
        if kind != .conversation && kind != .branchContent { searchResults = [] }
        if kind != .conversation { trashedBubbles = [] }
        if kind != .sticker { stickerSearchResults = [] }
        if kind != .characterCard { characterCardResults = [] }
        if kind != .worldBook { worldBookEntryResults = [] }
        if kind != .memory { memoryResults = [] }
        if kind != .file { fileResults = [] }
        if !(kind?.usesResourceHits ?? false) {
            resourceHits = []
            tweetTotal = 0
            tweetCursor = nil
            isLoadingMoreTweets = false
        }
    }

    private var allResultsEmpty: Bool {
        visibleRooms.isEmpty && searchResults.isEmpty && trashedBubbles.isEmpty && stickerSearchResults.isEmpty && characterCardResults.isEmpty && worldBookEntryResults.isEmpty && memoryResults.isEmpty && fileResults.isEmpty && resourceHits.isEmpty
    }

    private func clearSearch() {
        isSearchActive = false
        isSearching = false
        clearResults()
        conversationBuckets = nil
        currentMatchIndex = -1
        searchTask?.cancel()
        searchGeneration += 1
        #if os(iOS)
        kindCountTask?.cancel()
        kindCounts = [:]
        kindTabOrder = []
        searchErrors = []
        #endif
    }

    /// - recount: iOS 结果页标签上的各类结果数要不要重算（只切资料类型 / 排序时不用）
    private func triggerSearch(recount: Bool = true) {
        #if os(iOS)
        // 没选中的类型不搜：当前标签一定落在选中的类型里（S3-6）
        searchFilter.resourceKind = SearchQueryMapping.currentKind(searchFilter.resourceKind, in: searchKinds)
        // 普通词以框里的文字为准、条件以状态为准；条件变了就回写框里的文字，清掉的胶囊不会在下次回车复活（S2-5）
        searchFilter.words = MacSearchQuery.parse(searchText).words
        let queryText = SearchQueryMapping.text(for: queryState)
        if queryText != searchText { searchText = queryText }
        let keyword = searchFilter.words.max { $0.count < $1.count } ?? ""
        #else
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
        searchFilter.keyword = keyword
        guard !keyword.isEmpty || searchFilter.dateRange != .all else {
            clearSearch()
            #if os(iOS)
            if !searchText.isEmpty { searchErrors = ["再加一个词或时间。"] }
            #endif
            return
        }
        #if os(iOS)
        // 搜索态顶上的标签换成了资料类型，文件夹范围改由抽屉里的「所在文件夹」决定
        if !isSearchActive { searchFolder = currentTab }
        let folder = searchFolder
        #else
        let folder = currentTab
        #endif
        isSearchActive = true
        isSearching = true
        currentMatchIndex = -1

        // 根据文件夹限定搜索范围：空 tag 时 scope 是空 Set → 直接没结果
        var scope = scopeFor(folder)
        #if os(iOS)
        if searchStarredOnly, let favorites = scopeFor(.favorites) { scope = scope.map { $0.intersection(favorites) } ?? favorites }
        #endif
        searchFilter.conversationIdScope = scope
        // 回收站：搜的是已删除的对话
        searchFilter.includeDeletedConversations = (folder == .trash)

        searchTask?.cancel()
        searchGeneration += 1
        let gen = searchGeneration
        let t0 = CFAbsoluteTimeGetCurrent()
        let filter = searchFilter
        let container = modelContext.container
        let pid = profileManager?.currentProfile.id ?? ""
        let kind = filter.resourceKind

        // MainActor 取 snapshot（避免跨 actor 访问 @Observable）
        let includeIntimacy = HealthLogStore.showIntimacyCard
        let cardsSnapshot = cardManager?.cards ?? []
        let globalBooksSnapshot = globalWBManager?.books ?? []
        // 相关度的「有划线」：每次搜索按楼层只读一次划线表（S2-7）
        let highlightNodeIds = filter.sortOrder == .relevance
            ? Set(ChatHighlightStore.shared.highlights.filter { $0.profileId == pid }.map(\.nodeId)) : []

        if recount { conversationBuckets = nil }
        let isConversationSearch = kind == .conversation || kind == .branchContent
        let cachedBuckets = isConversationSearch ? conversationBuckets : nil
        if let cachedBuckets {
            applyConversationBuckets(cachedBuckets, kind: kind)
            KBProbe.log("[SEARCH] gen=\(gen) kind=\(kind.rawValue) hits=\(searchResults.count) ms=0 cancelled=false reused=true")
        }

        searchTask = Task {
            switch kind {
            case .conversation, .branchContent:
                let wantsBubbles = kind == .conversation && filter.includeDeletedConversations && filter.scope != .titleOnly
                async let bubbleIds: [String] = wantsBubbles
                    ? SearchService.searchTrashedBubbleIds(filter: filter, profileId: pid, container: container) : []
                if cachedBuckets == nil {
                    let buckets = await SearchService.searchConversationBuckets(filter: filter, profileId: pid, container: container,
                                                                               highlightNodeIds: highlightNodeIds)
                    await MainActor.run {
                        commitSearch(gen, kind: kind, t0: t0, hits: buckets?.results(for: kind).count ?? 0,
                                     cancelled: buckets == nil || Task.isCancelled) {
                            guard let buckets else { return }
                            conversationBuckets = buckets
                            applyConversationBuckets(buckets, kind: kind)
                            #if DEBUG && os(iOS)
                            // 索引路径连多词 / 排序一起对账；非索引路径旧实现只认一个词，多词在里面跳过
                            Task.detached(priority: .utility) {
                                await SearchService.debugCompareWithLegacy(filter: filter, buckets: buckets, gen: gen,
                                                                           profileId: pid, container: container,
                                                                           highlightNodeIds: highlightNodeIds)
                            }
                            #endif
                        }
                    }
                }
                let ids = await bubbleIds
                await MainActor.run {
                    guard gen == searchGeneration, !Task.isCancelled else { return }
                    trashedBubbles = trashedBubbleRows(ids)
                }
            case .sticker:
                let stickers = await SearchService.searchPlacedStickers(keyword: keyword, profileId: pid, container: container)
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: stickers.count, cancelled: Task.isCancelled) {
                        clearResults(except: .sticker)
                        stickerSearchResults = stickers
                    }
                }
            case .characterCard:
                let cards = SearchService.searchCharacterCards(keyword: keyword, cards: cardsSnapshot, filter: filter)
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: cards.count, cancelled: Task.isCancelled) {
                        clearResults(except: .characterCard)
                        characterCardResults = cards
                    }
                }
            case .worldBook:
                let entries = await SearchService.searchWorldBookEntries(
                    keyword: keyword, globalBooks: globalBooksSnapshot,
                    profileId: pid, container: container, filter: filter
                )
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: entries.count, cancelled: Task.isCancelled) {
                        clearResults(except: .worldBook)
                        worldBookEntryResults = entries
                    }
                }
            case .file:
                let files = await SearchService.searchFiles(filter: filter, profileId: pid)
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: files.count, cancelled: Task.isCancelled) {
                        clearResults(except: .file)
                        fileResults = files
                    }
                }
            #if PERSONAL_APPS
            case .trading:
                let hits = await SearchService.searchTrading(filter: filter, profileId: pid, container: container)
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: hits.count, cancelled: Task.isCancelled) {
                        clearResults(except: kind)
                        resourceHits = hits
                    }
                }
            #endif
            case .health:
                let hits = await SearchService.searchHealth(filter: filter, profileId: pid, includeIntimacy: includeIntimacy,
                                                            container: container)
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: hits.count, cancelled: Task.isCancelled) {
                        clearResults(except: kind)
                        resourceHits = visibleHealthHits(hits)
                    }
                }
            case .library:
                let hits = await SearchService.searchLibrary(filter: filter, profileId: pid, container: container)
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: hits.count, cancelled: Task.isCancelled) {
                        clearResults(except: kind)
                        resourceHits = hits
                    }
                }
            case .twitter:
                async let total = SearchService.countTweets(filter: filter, profileId: pid, container: container)
                let page = await SearchService.searchTweets(filter: filter, profileId: pid, after: nil, container: container)
                let count = await total
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: page.hits.count, cancelled: Task.isCancelled) {
                        clearResults(except: .twitter)
                        resourceHits = page.hits
                        tweetCursor = page.next
                        tweetTotal = count
                    }
                }
            case .memory:
                let mems = await SearchService.searchMemories(
                    keyword: keyword, profileId: pid, container: container, filter: filter
                )
                await MainActor.run {
                    commitSearch(gen, kind: kind, t0: t0, hits: mems.count, cancelled: Task.isCancelled) {
                        clearResults(except: .memory)
                        memoryResults = mems
                    }
                }
            }
        }

        #if os(iOS)
        if recount {
            let kinds = searchKinds
            refreshKindCounts(filter: filter, kinds: kinds, keyword: keyword, pid: pid, container: container,
                              cardCount: kinds.contains(.characterCard)
                                  ? SearchService.searchCharacterCards(keyword: keyword, cards: cardsSnapshot, filter: filter).count : nil,
                              globalBooks: globalBooksSnapshot, highlightNodeIds: highlightNodeIds)
        }
        rememberSearch(searchText)
        #endif
    }

    /// 代次不对 = 已被新搜索或清空取代，什么都不动；代次对但被取消 = 只收「忙」态
    private func commitSearch(_ gen: Int, kind: SearchResourceKind, t0: CFAbsoluteTime, hits: Int,
                              cancelled: Bool, apply: () -> Void) {
        let stale = gen != searchGeneration
        KBProbe.log("[SEARCH] gen=\(gen) kind=\(kind.rawValue) hits=\(hits) ms=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) cancelled=\(cancelled) stale=\(stale)")
        guard !stale else { return }
        if !cancelled { apply() }
        isSearching = false
    }

    private func applyConversationBuckets(_ buckets: SearchBuckets, kind: SearchResourceKind) {
        clearResults(except: kind)
        searchResults = buckets.results(for: kind)
        isSearching = false
        #if os(iOS)
        kindCounts[.conversation] = buckets.conversation.count
        kindCounts[.branchContent] = buckets.branch.count
        #endif
    }

    private func trashedBubbleRows(_ ids: [String]) -> [(node: MessageNode, convTitle: String)] {
        guard !ids.isEmpty else { return [] }
        let pid = profileManager?.currentProfile.id ?? ""
        var nodes: [String: MessageNode] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let desc = FetchDescriptor<MessageNode>(predicate: #Predicate { chunk.contains($0.id) && $0.profileId == pid && $0.isTrashed == true })
            for node in (try? modelContext.fetch(desc)) ?? [] { nodes[node.id] = node }
        }
        let convIds = Array(Set(nodes.values.map(\.conversationId)))
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { convIds.contains($0.id) && $0.profileId == pid })
        let titles = Dictionary(((try? modelContext.fetch(convDesc)) ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { id in nodes[id].map { ($0, titles[$0.conversationId] ?? "未知对话") } }
    }

    private func restoreTrashedBubble(_ node: MessageNode) {
        viewModel.restore(node)
        try? modelContext.save()
        triggerSearch()
    }

    private func deleteTrashedBubble(_ node: MessageNode) {
        trashedBubbles.removeAll { $0.node.id == node.id }
        viewModel.permanentlyDeleteNode(node, context: modelContext)
        try? modelContext.save()
        triggerSearch()
    }

    #if os(iOS)
    /// 结果页标签上的数：除当前这种以外，其余资料并行各搜一遍，谁先回来谁先显示（plan 决策 ①）。
    /// 对话 / 分支的数来自同一次分桶搜索（S1）；当前就是这两种时由主搜索顺带给出。
    /// 当前这种的数直接取它的结果数组。
    /// 只算选中的类型（S3-6：没选中的不搜、不算数）
    private func refreshKindCounts(filter: SearchFilter, kinds: Set<SearchResourceKind>, keyword: String, pid: String,
                                   container: ModelContainer, cardCount: Int?, globalBooks: [GlobalWorldBook],
                                   highlightNodeIds: Set<String>) {
        kindCountTask?.cancel()
        kindCounts = [:]
        kindTabOrder = []
        kindTabsSettled = false
        userPickedKindTab = false
        let current = filter.resourceKind
        if current != .characterCard, let cardCount { kindCounts[.characterCard] = cardCount }
        let includeIntimacy = HealthLogStore.showIntimacyCard
        kindCountTask = Task {
            await withTaskGroup(of: (SearchResourceKind, Int).self) { group in
                if current != .conversation && current != .branchContent
                    && (kinds.contains(.conversation) || kinds.contains(.branchContent)) {
                    group.addTask {
                        let t0 = CFAbsoluteTimeGetCurrent()
                        let buckets = await SearchService.searchConversationBuckets(filter: filter, profileId: pid, container: container,
                                                                                   highlightNodeIds: highlightNodeIds)
                        KBProbe.log("[SEARCH] gen=count kind=conversation+branch hits=\(buckets?.conversation.count ?? 0)/\(buckets?.branch.count ?? 0) ms=\(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) cancelled=\(buckets == nil)")
                        guard let buckets else { return (.conversation, 0) }
                        await MainActor.run {
                            // 排序变了（不重算数、不取消本任务）就别把旧顺序的桶存进缓存
                            guard !Task.isCancelled, searchFilter.sortOrder == filter.sortOrder else { return }
                            conversationBuckets = buckets
                            kindCounts[.branchContent] = buckets.branch.count
                        }
                        return (.conversation, buckets.conversation.count)
                    }
                }
                for kind in SearchQueryMapping.ordered(kinds)
                where kind != current && kind != .characterCard && kind != .conversation && kind != .branchContent {
                    var kindFilter = filter
                    kindFilter.resourceKind = kind
                    group.addTask {
                        switch kind {
                        case .conversation, .branchContent:
                            return (kind, 0)
                        case .sticker:
                            return (kind, await SearchService.searchPlacedStickers(keyword: keyword, profileId: pid, container: container).count)
                        case .worldBook:
                            return (kind, await SearchService.searchWorldBookEntries(
                                keyword: keyword, globalBooks: globalBooks,
                                profileId: pid, container: container, filter: kindFilter
                            ).count)
                        case .memory:
                            return (kind, await SearchService.searchMemories(
                                keyword: keyword, profileId: pid, container: container, filter: kindFilter
                            ).count)
                        case .file:
                            return (kind, await SearchService.searchFiles(filter: kindFilter, profileId: pid).count)
                        #if PERSONAL_APPS
                        case .trading:
                            return (kind, await SearchService.searchTrading(filter: kindFilter, profileId: pid, container: container).count)
                        #endif
                        case .health:
                            let hits = await SearchService.searchHealth(filter: kindFilter, profileId: pid,
                                                                        includeIntimacy: includeIntimacy, container: container)
                            return (kind, await MainActor.run { visibleHealthHits(hits).count })
                        case .library:
                            return (kind, await SearchService.searchLibrary(filter: kindFilter, profileId: pid, container: container).count)
                        case .twitter:
                            return (kind, await SearchService.countTweets(filter: kindFilter, profileId: pid, container: container))
                        case .characterCard:
                            return (kind, 0)
                        }
                    }
                }
                for await (kind, count) in group {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { kindCounts[kind] = count }
                }
            }
        }
    }
    #endif

    /// 把当前 tab 翻译成搜索范围。
    /// - 「全部」/「回收站」：nil（不限；回收站搜索仍受 performSearch 里 isTrashed==false 的约束）
    /// - 「收藏」：所有 isFavorite 的 conv id
    /// - 文件夹：folderId 指向它的 conv id（空文件夹返回空 Set → 搜不到任何东西）
    private func scopeFor(_ tab: SidebarTab) -> Set<String>? {
        let pid = profileManager?.currentProfile.id ?? ""
        switch tab {
        #if os(macOS)
        case .code:
            return nil
        #endif
        case .all, .trash:
            return nil
        case .favorites:
            let desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.profileId == pid && $0.isTrashed == false && $0.isFavorite == true }
            )
            let convs = (try? modelContext.fetch(desc)) ?? []
            return Set(convs.map(\.id))
        case .tag(let id):
            return folderConversationIds(id)
        }
    }

    /// 文件夹里的对话 id（`Conversation.folderId`）。folderId 是 optional，#Predicate 直接比较会静默查不到，
    /// 所以按楼层只取 id / folderId 两列、内存里筛
    private func folderConversationIds(_ folderId: String) -> Set<String> {
        let pid = profileManager?.currentProfile.id ?? ""
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.profileId == pid })
        desc.propertiesToFetch = [\.id, \.folderId]
        let convs = (try? modelContext.fetch(desc)) ?? []
        return Set(convs.lazy.filter { $0.folderId == folderId }.map(\.id))
    }

    private func navigateNext() {
        let matches = flatMatches
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        let match = matches[currentMatchIndex]
        navigateToNodeById(match.id, conversationId: match.conversationId)
    }

    private func navigatePrev() {
        let matches = flatMatches
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        let match = matches[currentMatchIndex]
        navigateToNodeById(match.id, conversationId: match.conversationId)
    }

    /// Re-trigger search when filter changes.
    /// - 资源类型（非对话）：没有"列表过滤"对应概念 → 有关键词就直接进全量搜索，否则清空
    /// - 对话类型：已按 ➡️ → 重新跑全量；未按 → 只刷新列表
    private func triggerSearchIfActive() {
        if searchFilter.resourceKind != .conversation {
            let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kw.isEmpty {
                triggerSearch()
            } else {
                clearSearch()
            }
            return
        }
        if isSearchActive {
            triggerSearch()
        } else {
            refreshList()
        }
    }

    private func navigateToNodeById(_ nodeId: String, conversationId: String) {
        let cid = conversationId
        let pid = profileManager?.currentProfile.id ?? ""
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { conv in conv.id == cid && conv.profileId == pid }
        )
        guard let conversation = try? modelContext.fetch(convDesc).first else { return }
        // B20 part 2: 走 ViewModel 统一入口（去抖 + 主线/分支判断 + page 切换通知 + toast）
        onSelectConversation()
        viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conversation, context: modelContext)
    }

    // MARK: - Resource Result Navigation
    // 只发请求，ContentView 监听 pendingTarget 决定 iOS/macOS 怎么显示右栏

    private func navigateToCardResult(_ result: CharacterCardSearchResult) {
        rightPanelNavigator?.pendingTarget = .init(tool: "cardLibrary", id: result.cardId)
    }

    private func navigateToWorldBookResult(_ result: WorldBookEntrySearchResult) {
        rightPanelNavigator?.pendingTarget = .init(tool: "worldBook", id: result.id)
    }

    private func navigateToMemoryResult(_ result: MemorySearchResult) {
        rightPanelNavigator?.pendingTarget = .init(tool: "memory", id: result.id)
    }

    /// 文件：和 mac ⌘K 同一条路，文件库面板消费 pendingTarget 后直接打开这份文件
    private func navigateToFileResult(_ result: FileSearchResult) {
        rightPanelNavigator?.pendingTarget = .init(tool: "fileLibrary", id: result.path)
    }

    /// 写结果前按开关当下的值再筛一次：搜的途中开关被关掉，亲密记录也不能落进结果
    private func visibleHealthHits(_ hits: [ResourceHit]) -> [ResourceHit] {
        HealthLogStore.showIntimacyCard ? hits : hits.filter { !$0.id.hasPrefix(SearchService.intimacyHitPrefix) }
    }

    /// 亲密卡开关一变：先把已有结果和数字里的亲密记录清掉，再按新开关重搜
    private func intimacyVisibilityChanged() {
        guard isSearchActive else { return }
        if searchFilter.resourceKind == .health { resourceHits = visibleHealthHits(resourceHits) }
        #if os(iOS)
        kindCounts[.health] = nil
        #endif
        triggerSearch()
    }

    private func navigateToResourceHit(_ hit: ResourceHit) {
        rightPanelNavigator?.pendingTarget = .init(tool: hit.tool, id: hit.target)
    }

    /// 推特标签滚到底：按上一页最后一条的「时间 + id」再取一页
    private func loadMoreTweets() {
        guard let cursor = tweetCursor, !isLoadingMoreTweets else { return }
        isLoadingMoreTweets = true
        let gen = searchGeneration
        let filter = searchFilter
        let container = modelContext.container
        let pid = profileManager?.currentProfile.id ?? ""
        Task {
            let page = await SearchService.searchTweets(filter: filter, profileId: pid, after: cursor, container: container)
            await MainActor.run {
                guard gen == searchGeneration, searchFilter.resourceKind == .twitter else { return }
                isLoadingMoreTweets = false
                resourceHits += page.hits
                tweetCursor = page.next
            }
        }
    }

    private func navigateToStickerResult(_ result: StickerSearchResult) {
        onSelectConversation()
        if let nearestId = result.nearestMessageId {
            // 同一对话不重载，只滚动（延迟让 UI 更新完成）
            if viewModel.selectedConversation?.id == result.conversationId {
                viewModel.highlightedNodeId = nearestId
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    viewModel.scrollToNodeId = nearestId
                }
            } else {
                navigateToNodeById(nearestId, conversationId: result.conversationId)
            }
        } else {
            // 没有 nearestMessageId，至少跳到对话
            let cid = result.conversationId
            let pid = profileManager?.currentProfile.id ?? ""
            let convDesc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in conv.id == cid && conv.profileId == pid }
            )
            if let conv = try? modelContext.fetch(convDesc).first {
                onSelectConversation()
                viewModel.loadConversation(conv, context: modelContext)
            }
        }
    }

    /// 新建 = 内存草稿（startDraftConversation），发出首条才落库进列表；没发就切走直接丢。
    private func createNewConversation() {
        onSelectConversation()
        let profileId = profileManager?.currentProfile.id ?? ""
        viewModel.startDraftConversation(profileId: profileId, fresh: true)
        // 在文件夹 tab 里新建 = 直接建在这个文件夹里（落库时一起带进去）
        viewModel.selectedConversation?.folderId = selectedTagId
    }

    /// B：Codex 有自己的门面——建对话即绑独立 mp-codex-N 会话 + 自动选 ccBridge 通道模型，
    /// 不用去 CC 选择器里手挑 session。编号用本机计数器（撞名无害：两对话共享同一 codex 会话）。
    private func createNewCodexConversation() {
        onSelectConversation()
        let profileId = profileManager?.currentProfile.id ?? ""
        // 标题留占位，首条回复落地后自动起（行首珊瑚色 </> 已经在说「这是 Codex」）
        viewModel.startDraftConversation(profileId: profileId, fresh: true)
        guard let conversation = viewModel.selectedConversation else { return }
        conversation.folderId = selectedTagId
        let n = UserDefaults.standard.integer(forKey: "codexSessionCounter") + 1
        UserDefaults.standard.set(n, forKey: "codexSessionCounter")
        conversation.ccBridgeSessionName = "mp-codex-\(n)"
        conversation.selectedModelId = APIProvider.codexBridge.models[0].id   // "codex-bridge/codex-local"
    }

    /// 打字即搜正文（S5 D7）：索引就绪时正文也跟着打字搜，命中对话并进列表的标题过滤，不新造结果页。
    /// 独立轻路径：不经 triggerSearch（不回写框里文字、不动焦点和光标），防抖 250ms，组字中不搜，按代次丢旧结果。
    /// 接手了就由它在结果回来后 refreshList（返回 true），调用方不再跑标题防抖；没接手清掉旧命中、照旧只搜标题
    private func scheduleTypingBodySearch(_ text: String) -> Bool {
        typingBodyTask?.cancel()
        typingBodyGen += 1
        let gen = typingBodyGen
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !isSearchActive, SearchTextSegmenter.ftsQuery(for: keyword) != nil,
              let index = SearchIndexer.shared.readyStore else {
            typingBodyConvIds = []
            return false
        }
        var filter = SearchFilter()
        filter.keyword = keyword
        filter.words = [keyword]
        filter.scope = .contentOnly
        filter.includeDeletedConversations = showTrash
        let container = modelContext.container
        let pid = profileManager?.currentProfile.id ?? ""
        typingBodyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, gen == typingBodyGen else { return }
            if isComposingSearchText { return }
            let rows = await SearchService.performSearch(filter: filter, profileId: pid, container: container, index: index)
            guard !Task.isCancelled, gen == typingBodyGen, !isSearchActive else { return }
            typingBodyConvIds = rows.map(\.convId)
            refreshList()
        }
        return true
    }

    /// 输入法组字中（有 markedText）：mac 读字段编辑器；iOS 从 key window 找 first responder 的 markedTextRange
    private var isComposingSearchText: Bool {
        #if os(macOS)
        return (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
        #else
        func responder(in view: UIView) -> UITextInput? {
            if view.isFirstResponder { return view as? UITextInput }
            for sub in view.subviews { if let found = responder(in: sub) { return found } }
            return nil
        }
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return window.flatMap(responder(in:))?.markedTextRange != nil
        #endif
    }

    #if os(iOS)
    /// page0 行点击（perf-flash 驱动器经 PerfHarness.openFromList 走同一函数）
    private func openFromList(_ conversation: Conversation) {
        onSelectConversation()
        viewModel.loadConversation(conversation, context: modelContext)
        // 同 id 重进：selectedConversation?.id 不变，ContentView 翻页 onChange 不 fire，
        // 走 B20 通知补 page 切换（否则点当前对话回不到聊天页——B41 复现器抓到的）
        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
    }
    #endif

    /// keepLoaded：同一份列表原地重查（从聊天页回来 / 同步导入），按已加载条数一次取回；
    /// 切 tab / 搜索 / 筛选这类换列表的照旧从第一页开始
    private func refreshList(keepLoaded: Bool = false) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfCount.hit("refreshList")
        #endif
        let loaded = keepLoaded ? conversations.count : 0
        conversations.removeAll()
        // 收藏标签快照要在查对话之前取（对话分段按 tag 筛要用）
        if showFavoritesOnly {
            reloadFavoriteTags()
        } else {
            if favoriteTagFilter != nil { favoriteTagFilter = nil }
            if !favoriteTagIndex.lastUsed.isEmpty { favoriteTagIndex = FavoriteTags.Index() }
        }
        fetchPage(offset: 0, limit: max(pageSize, loaded))
        if showFavoritesOnly {
            fetchFavoritedNodes()
            fetchChatHighlights()
        } else {
            favoritedNodes = []
            chatHighlightRows = []
        }
        if showTrash {
            fetchDeletedNodes()
        } else {
            deletedNodes = []
        }
    }

    /// 追加下一页：按 id 去掉已经在列表里的（排序兜底之外再保一层——两页之间有新对话插到顶上也会错位）
    private func appendPage(_ page: [Conversation]) {
        let existing = Set(conversations.map(\.id))
        conversations.append(contentsOf: page.filter { !existing.contains($0.id) })
    }

    private func loadMore() {
        guard !isLoadingMore else { return }
        #if os(iOS)
        // 拖滚动条期间不翻页：contentSize 中途变长会让 thumb↔offset 映射跳；松手由 Page0Scrubber 补调（plan-page0-scrubber）
        if page0Scrubber.isScrubbing {
            page0Scrubber.pendingLoadMore = true
            return
        }
        #endif
        fetchPage(offset: conversations.count)
    }

    private func fetchPage(offset: Int, limit: Int? = nil) {
        isLoadingMore = true
        let limit = limit ?? pageSize

        let interval = searchFilter.dateRange.dateInterval
        let defaultSort = [SortDescriptor(\Conversation.updateTime, order: .reverse)]
        // 置顶浮顶：pinnedAt DESC 时 SQLite NULL 垫底，未置顶组退回 updateTime 排序。
        // 回收站不浮（删了还钉着很怪）；搜索/筛选时尊重用户选的 sortOrder。
        let pinnedFirstSort = [SortDescriptor(\Conversation.pinnedAt, order: .reverse)] + defaultSort
        // 有关键词 / 有时间筛选 / 改过排序 → 都用用户选的 sortOrder
        let usingFilters = !searchText.isEmpty || searchFilter.dateRange != .all || listSortIsCustom
        // 末尾补 id 兜底：同一时间的几条对话每次查询先后要固定，否则 offset 分页第二页会把第一页的某条再取一次
        let sortBy = (usingFilters ? conversationSortDescriptors() : (showTrash ? defaultSort : pinnedFirstSort))
            + [SortDescriptor(\Conversation.id)]

        // Trash mode
        if showTrash {
            var descriptor = FetchDescriptor<Conversation>(sortBy: sortBy)
            descriptor.predicate = trashPredicate(search: searchText, interval: interval)

            if let count = try? modelContext.fetchCount(descriptor) {
                totalCount = count
            }

            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit

            if let results = try? modelContext.fetch(descriptor) {
                if offset == 0 {
                    conversations = results
                } else {
                    appendPage(results)
                }
            }

            isLoadingMore = false
            return
        }

        // Tag mode（B9/P1-1）：convIds 收窄 predicate 走真分页，替代原来的
        // 全量 fetch + 内存 filter + prefix（offset 被无视，loadMore 空转）。
        if let tagId = selectedTagId {
            do {
                let convIds = Array(folderConversationIds(tagId))
                if convIds.isEmpty {
                    totalCount = 0
                    conversations = []
                } else if convIds.count <= tagInQueryLimit {
                    // 现实全部场景：IN 查询 + 与另两分支同构的真分页
                    var descriptor = FetchDescriptor<Conversation>(sortBy: sortBy)
                    descriptor.predicate = tagPredicate(convIds: convIds, search: searchText, interval: interval)
                    if let count = try? modelContext.fetchCount(descriptor) {
                        totalCount = count
                    }
                    descriptor.fetchOffset = offset
                    descriptor.fetchLimit = limit
                    if let results = try? modelContext.fetch(descriptor) {
                        if offset == 0 {
                            conversations = results
                        } else {
                            appendPage(results)
                        }
                    }
                } else {
                    // 兜底：超大标签避开 SQLite IN 变量数上限——内存 filter 但分页正确
                    var convDescriptor = FetchDescriptor<Conversation>(sortBy: sortBy)
                    convDescriptor.predicate = normalPredicate(search: searchText, interval: interval, favoritesOnly: false)
                    if let allConvs = try? modelContext.fetch(convDescriptor) {
                        let idSet = Set(convIds)
                        let filtered = allConvs.filter { idSet.contains($0.id) }
                        totalCount = filtered.count
                        let page = Array(filtered.dropFirst(offset).prefix(limit))
                        if offset == 0 {
                            conversations = page
                        } else {
                            appendPage(page)
                        }
                    }
                }
            }
            isLoadingMore = false
            return
        }

        // 收藏页「对话」分段按 tag 筛（10-02）：收藏的对话不多，取全部收藏再按 tag 内存筛，分页照常
        if showFavoritesOnly, favoritesKind == .conversations, let tag = favoriteTagFilter {
            var convDescriptor = FetchDescriptor<Conversation>(sortBy: sortBy)
            convDescriptor.predicate = normalPredicate(search: searchText, interval: interval, favoritesOnly: true)
            if let allConvs = try? modelContext.fetch(convDescriptor) {
                let filtered = allConvs.filter { favoriteTagIndex.conversationTags[$0.id]?.contains(tag) == true }
                totalCount = filtered.count
                let page = Array(filtered.dropFirst(offset).prefix(limit))
                if offset == 0 {
                    conversations = page
                } else {
                    appendPage(page)
                }
            }
            isLoadingMore = false
            return
        }

        var descriptor = FetchDescriptor<Conversation>(sortBy: sortBy)
        descriptor.predicate = normalPredicate(search: searchText, interval: interval, favoritesOnly: showFavoritesOnly)

        if let count = try? modelContext.fetchCount(descriptor) {
            totalCount = count
        }

        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit

        if let results = try? modelContext.fetch(descriptor) {
            if offset == 0 {
                conversations = results
            } else {
                appendPage(results)
            }
        }

        #if DEBUG
        // 09-17 她实拍「显示 0 / 0 条对话」但同一楼层另一实例 36 条，两次复现都没抓到——
        // 取证探针：这一路到底是没条目（pid 空 / 谓词）还是 fetch 抛了（上面 try? 吞掉）
        let pidNow = profileManager?.currentProfile.id ?? ""
        var fetchError = "none"
        do { _ = try modelContext.fetchCount(descriptor) } catch { fetchError = "\(error)" }
        ShellProbe.keep("[PROBE sidebar.fetch] pid=\(pidNow.prefix(8)) off=\(offset) fav=\(showFavoritesOnly) kw=\(!searchText.isEmpty) range=\(interval != nil) → \(conversations.count)/\(totalCount) err=\(fetchError)")
        #endif

        isLoadingMore = false
    }

    /// 标题含词 || 正文命中（打字即搜，S5 D7）
    private func titleOrBodyPredicate(_ kw: String, _ bodyIds: [String]) -> Predicate<Conversation> {
        #Predicate<Conversation> { conv in conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id) }
    }

    /// 构造非 trash 会话的 predicate（关键词 × 时间范围 × favoritesOnly 组合）
    /// 所有分支都加 `$0.profileId == pid` —— 路线 B 单 container 下必须按 profileId 隔离。
    private func normalPredicate(search: String, interval: (start: Date, end: Date)?, favoritesOnly: Bool) -> Predicate<Conversation> {
        let hasKeyword = !search.isEmpty
        let kw = search
        let bodyIds = typingBodyConvIds
        let pid = profileManager?.currentProfile.id ?? ""
        if let interval = interval {
            let s = interval.start
            let e = interval.end
            if favoritesOnly && hasKeyword {
                // 条件太多，内联 || 会让 #Predicate 类型检查超时 → 关键词这一段拆成子 predicate
                let keywordMatch = titleOrBodyPredicate(kw, bodyIds)
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && conv.isFavorite == true &&
                    keywordMatch.evaluate(conv) &&
                    conv.createTime >= s && conv.createTime <= e
                }
            } else if favoritesOnly {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && conv.isFavorite == true &&
                    conv.createTime >= s && conv.createTime <= e
                }
            } else if hasKeyword {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false &&
                    (conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id)) &&
                    conv.createTime >= s && conv.createTime <= e
                }
            } else {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false &&
                    conv.createTime >= s && conv.createTime <= e
                }
            }
        } else {
            if favoritesOnly && hasKeyword {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && conv.isFavorite == true &&
                    (conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id))
                }
            } else if favoritesOnly {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && conv.isFavorite == true
                }
            } else if hasKeyword {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && (conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id))
                }
            } else {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid && conv.isTrashed == false
                }
            }
        }
    }

    /// 构造 trash（已删除）会话的 predicate（关键词 × 时间范围）
    private func trashPredicate(search: String, interval: (start: Date, end: Date)?) -> Predicate<Conversation> {
        let hasKeyword = !search.isEmpty
        let kw = search
        let bodyIds = typingBodyConvIds
        let pid = profileManager?.currentProfile.id ?? ""
        if let interval = interval {
            let s = interval.start
            let e = interval.end
            if hasKeyword {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == true &&
                    (conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id)) &&
                    conv.createTime >= s && conv.createTime <= e
                }
            } else {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == true &&
                    conv.createTime >= s && conv.createTime <= e
                }
            }
        } else {
            if hasKeyword {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == true && (conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id))
                }
            } else {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid && conv.isTrashed == true
                }
            }
        }
    }

    /// 构造标签桶会话的 predicate（B9/P1-1）：convIds IN + 关键词 × 时间范围。
    /// IN 写法照 ImportSupport 先例（chunk.contains）；分支数 4，不往 normalPredicate 的 8 分支上再乘维度。
    private func tagPredicate(convIds: [String], search: String, interval: (start: Date, end: Date)?) -> Predicate<Conversation> {
        let hasKeyword = !search.isEmpty
        let kw = search
        let bodyIds = typingBodyConvIds
        let pid = profileManager?.currentProfile.id ?? ""
        let ids = convIds
        if let interval = interval {
            let s = interval.start
            let e = interval.end
            if hasKeyword {
                let keywordMatch = titleOrBodyPredicate(kw, bodyIds)
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && ids.contains(conv.id) &&
                    keywordMatch.evaluate(conv) &&
                    conv.createTime >= s && conv.createTime <= e
                }
            } else {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && ids.contains(conv.id) &&
                    conv.createTime >= s && conv.createTime <= e
                }
            }
        } else {
            if hasKeyword {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && ids.contains(conv.id) &&
                    (conv.title.localizedStandardContains(kw) || bodyIds.contains(conv.id))
                }
            } else {
                return #Predicate<Conversation> { conv in
                    conv.profileId == pid &&
                    conv.isTrashed == false && ids.contains(conv.id)
                }
            }
        }
    }

    // MARK: - Footer Result Count

    private func resultCountLabel() -> Text {
        switch searchFilter.resourceKind {
        case .conversation:
            let totalMatches = searchResults.reduce(0) { $0 + max(1, $1.matchedNodes.count) }
            return Text("\(searchResults.count) 个对话，\(totalMatches) 条结果")
        case .branchContent:
            let totalMatches = searchResults.reduce(0) { $0 + max(1, $1.matchedNodes.count) }
            return Text("\(searchResults.count) 个对话，\(totalMatches) 条分支结果")
        case .sticker:
            return Text("\(stickerSearchResults.count) 个贴纸")
        case .characterCard:
            return Text("\(characterCardResults.count) 个助手模板")
        case .worldBook:
            return Text("\(worldBookEntryResults.count) 条世界书")
        case .memory:
            return Text("\(memoryResults.count) 条记忆")
        case .file:
            return Text("\(fileResults.count) 个文件")
        #if PERSONAL_APPS
        case .trading:
            return Text("\(resourceHits.count) 条交易")
        #endif
        case .health:
            return Text("\(resourceHits.count) 条健康记录")
        case .library:
            return Text("\(resourceHits.count) 条书房结果")
        case .twitter:
            return Text("已加载 \(resourceHits.count) / 共 \(tweetTotal) 条推文")
        }
    }

    // MARK: - Resource Results View

    @ViewBuilder
    private func resourceResultsView(kind: SearchResourceKind) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                Color.clear.frame(height: 4)
                switch kind {
                case .characterCard:
                    if characterCardResults.isEmpty {
                        resourceEmptyState(icon: "person.crop.rectangle", text: "没有找到助手模板")
                    } else {
                        ForEach(characterCardResults) { result in
                            CharacterCardMatchRow(result: result)
                                .rowHover()
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToCardResult(result) }
                        }
                    }
                case .worldBook:
                    if worldBookEntryResults.isEmpty {
                        resourceEmptyState(icon: "book.closed", text: "没有找到世界书条目")
                    } else {
                        ForEach(worldBookEntryResults) { result in
                            WorldBookEntryMatchRow(result: result)
                                .rowHover()
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToWorldBookResult(result) }
                        }
                    }
                case .memory:
                    if memoryResults.isEmpty {
                        resourceEmptyState(icon: "brain", text: "没有找到记忆")
                    } else {
                        ForEach(memoryResults) { result in
                            MemoryMatchRow(result: result)
                                .rowHover()
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToMemoryResult(result) }
                        }
                    }
                case .file:
                    if fileResults.isEmpty {
                        resourceEmptyState(icon: "doc.text", text: "没有找到文件")
                    } else {
                        ForEach(fileResults) { result in
                            FileMatchRow(result: result, words: highlightWords)
                                .rowHover()
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToFileResult(result) }
                        }
                    }
                default:
                    if resourceHits.isEmpty {
                        resourceEmptyState(icon: "magnifyingglass", text: "没有找到结果")
                    } else {
                        ForEach(resourceHits) { hit in
                            ResourceHitRow(hit: hit, words: highlightWords)
                                .rowHover()
                                .contentShape(Rectangle())
                                .onTapGesture { navigateToResourceHit(hit) }
                                .onAppear {
                                    if kind == .twitter && hit.id == resourceHits.last?.id { loadMoreTweets() }
                                }
                        }
                        if kind == .twitter {
                            HStack(spacing: 6) {
                                if isLoadingMoreTweets { ProgressView().scaleEffect(0.6) }
                                Text("已加载 \(resourceHits.count) / 共 \(tweetTotal)")
                                    .font(.system(size: Theme.F.caption))
                                    .foregroundColor(Theme.textMuted)
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        #endif
        .sidebarCardShape(topLeading: cardTopLeading, topTrailing: cardTopTrailing)
    }

    @ViewBuilder
    private func resourceEmptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(Theme.textMuted.opacity(0.3))
            Text(text)
                .font(.caption)
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Search Result Rendering Helpers

    /// 搜索结果块的分隔标签（"标题 · 5" / "内容 · 12"）
    @ViewBuilder
    private func searchBucketLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.F.badge, weight: .medium))
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 多词 AND 时每个词都高亮（S2-8）
    private var highlightWords: [String] {
        searchFilter.words.isEmpty ? [searchFilter.keyword] : searchFilter.words
    }

    /// 标题块的 row：纯标题，无 chevron、无展开
    @ViewBuilder
    private func searchTitleRow(group: SearchResult) -> some View {
        HStack(spacing: 6) {
            highlightedText(group.convTitle, words: highlightWords)
                .font(.system(size: Theme.F.sectionHeader, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(viewModel.selectedConversation?.id == group.convId ? Theme.accent.opacity(0.5) : Color.clear)
        )
        // 这一行自己的选中底没有水平内缩、圆角 8，悬停层跟它对齐
        .rowHover(selected: viewModel.selectedConversation?.id == group.convId, insetH: 0, radius: 8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            let cid = group.convId
            let pid = profileManager?.currentProfile.id ?? ""
            let convDesc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in conv.id == cid && conv.profileId == pid }
            )
            if let conv = try? modelContext.fetch(convDesc).first {
                onSelectConversation()
                viewModel.loadConversation(conv, context: modelContext)
            }
        }
    }

    /// 内容块的 row：可展开的 conv header + matchedNodes 列表
    @ViewBuilder
    private func searchContentRow(group: Binding<SearchResult>) -> some View {
        let g = group.wrappedValue
        Button(action: { group.isExpanded.wrappedValue.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: g.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .frame(width: 10)

                highlightedText(g.convTitle, words: highlightWords)
                    .font(.system(size: Theme.F.sectionHeader, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if g.matchedNodes.count > 0 {
                    Text("\(g.matchedNodes.count)")
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(viewModel.selectedConversation?.id == g.convId ? Theme.accent.opacity(0.5) : Color.clear)
            )
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .onTapGesture {
            let cid = g.convId
            let pid = profileManager?.currentProfile.id ?? ""
            let convDesc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { conv in conv.id == cid && conv.profileId == pid }
            )
            if let conv = try? modelContext.fetch(convDesc).first {
                onSelectConversation()
                viewModel.loadConversation(conv, context: modelContext)
            }
        }

        if g.isExpanded {
            let isBranch = searchFilter.resourceKind == .branchContent
            ForEach(g.matchedNodes) { match in
                ContentMatchRow(
                    nodeId: match.id,
                    role: match.role,
                    convTitle: "",
                    preview: match.preview,
                    createTime: match.createTime,
                    userName: userName,
                    assistantName: assistantName,
                    keyword: match.keyword,
                    words: highlightWords
                )
                .rowHover()
                .padding(.leading, isBranch ? 32 : 16)
                .overlay(alignment: .topLeading) {
                    if isBranch {
                        Text("🌿")
                            .font(.system(size: 11))
                            .padding(.leading, 10)
                            .padding(.top, 6)
                            .opacity(0.7)
                    }
                }
                .onTapGesture {
                    if let idx = flatMatches.firstIndex(where: { $0.id == match.id }) {
                        currentMatchIndex = idx
                    }
                    navigateToNodeById(match.id, conversationId: match.conversationId)
                }
            }
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    var showDivider: Bool = true
    var isFirst: Bool = false
    /// CC 已发出、还在等回复（`ConversationViewModel.ccWaitingSince`）
    var isRunning: Bool = false
    /// 详细模式：两行，第二行 = 模型最后一句
    var detailed: Bool = false
    /// 纯净模式：只显示标题，不带图标/条数/时间/未读
    var pure: Bool = false
    /// 学堂文件夹里的对话：行首类型图标换学位帽
    var isStudy: Bool = false
    /// 「全部」里属于某文件夹的对话，详细模式第二行开头标一下（「🎯 码」）
    var folderLabel: String? = nil
    /// 收藏页里这条对话挂的收藏标签，行底下一行小字
    var favoriteTags: [String] = []

    @Environment(\.modelContext) private var modelContext
    @State private var preview = ""

    /// 行首类型图标色：CC = Claude 橙、codex = GPT 绿（都压低饱和度，不再用荧光绿胶囊分伙伴）
    static let ccTint = Color(red: 0.80, green: 0.52, blue: 0.40)
    static let codexTint = Color(red: 0.40, green: 0.62, blue: 0.52)
    /// 未读点 / 未读数字：灰薄荷，不跟伙伴色走
    static let unreadTint = Color(red: 0.45, green: 0.66, blue: 0.56)

    private var sessionName: String? {
        guard let name = conversation.ccBridgeSessionName, !name.isEmpty else { return nil }
        return name
    }

    /// 标题后的 session 短名：只去 `mp-` 前缀——`mp-cc` → `cc`、`mp-cc-52` → `cc-52`、`mp-codex-3` → `codex-3`
    static func sessionShortName(_ name: String) -> String {
        name.hasPrefix("mp-") ? String(name.dropFirst(3)) : name
    }

    private var typeIcon: (symbol: String, tint: Color) {
        if let name = sessionName {
            return ("chevron.left.forwardslash.chevron.right", name.hasPrefix("mp-codex") ? Self.codexTint : Self.ccTint)
        }
        if isStudy { return ("graduationcap", Theme.textMuted) }
        if Conversation.importedProviders.contains(conversation.provider) { return ("archivebox", Theme.textMuted) }
        return ("bubble.left", Theme.textMuted)
    }

    private var hasUnread: Bool { conversation.unreadCount > 0 }

    /// 列表时间分级（跟随系统语言和 12/24 小时制）：
    /// 今天 → 时:分；7 天内 → 周几；今年 → 月日；更早 → 年月日。
    static func smartDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? .max
        if days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                if pure { pureContent } else if detailed { detailedContent } else { compactContent }
                if !pure && !favoriteTags.isEmpty {
                    // 对齐标题：行首类型图标 20 + 间距 10
                    FavoriteTagLine(tags: favoriteTags)
                        .padding(.leading, 30)
                }
            }
            #if os(macOS)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            #else
            .padding(.horizontal, 16)
            .padding(.vertical, detailed ? 10 : 12)
            #endif
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.45) : Color.clear)
            )
            #if os(macOS)
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(Theme.branchIndicator).frame(width: 2, height: 16)
                }
            }
            #else
            .padding(.horizontal, 4)
            #endif

            #if os(iOS)
            if showDivider && !isSelected {
                Divider().opacity(0.15).padding(.leading, 16)
            }
            #endif
        }
    }

    private var pureContent: some View {
        Text(conversation.title)
            .font(.system(size: Theme.F.label, weight: .medium))
            .foregroundColor(Theme.textPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactContent: some View {
        HStack(spacing: 10) {
            typeIconView
            titleLine
            Spacer(minLength: 2)
            // 条数在前、时间贴右：各行时间（含群聊行）落在同一条竖线上
            HStack(spacing: 4) {
                if conversation.nodeCount > 0 {
                    Text("\(conversation.nodeCount) ·")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                        .fixedSize()
                }
                dateText
            }
        }
        // 未读点 / 转圈不占布局：画进右侧 16pt 留白里，日期和群聊行的「N 位成员」对齐
        .overlay(alignment: .trailing) {
            statusSlot(showUnreadDot: true)
                .offset(x: 11)
        }
    }

    private var detailedContent: some View {
        HStack(alignment: .top, spacing: 10) {
            typeIconView
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    titleLine
                    Spacer(minLength: 2)
                    // 条数在前、时间贴右：各行时间（含群聊行）落在同一条竖线上
                    HStack(spacing: 4) {
                        if conversation.nodeCount > 0 {
                            Text("\(conversation.nodeCount) ·")
                                .font(.system(size: Theme.F.caption))
                                .foregroundColor(Theme.textMuted.opacity(0.7))
                                .fixedSize()
                        }
                        dateText
                    }
                }
                HStack(spacing: 6) {
                    Text(secondLine)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    // 第二行右端一格：在跑 = 转圈，否则未读数字（第一行日期因此能贴右对齐）
                    ZStack(alignment: .trailing) {
                        let badgeOn = hasUnread && !isRunning
                        Text("\(conversation.unreadCount)")
                            .font(.system(size: Theme.F.badge, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 18, minHeight: 16)
                            .background(Capsule().fill(Self.unreadTint))
                            .fixedSize()
                            .opacity(badgeOn ? 1 : 0)
                            .scaleEffect(badgeOn ? 1 : 0.3)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: badgeOn)
                        statusSlot(showUnreadDot: false)
                    }
                }
                .frame(height: 17)
            }
        }
        .task(id: ConversationPreviewCache.key(conversation)) {
            preview = ConversationPreviewCache.preview(for: conversation, context: modelContext)
        }
    }

    private var secondLine: String {
        let body = isRunning ? "正在回复…" : preview
        guard let folderLabel else { return body }
        return body.isEmpty ? folderLabel : "\(folderLabel) · \(body)"
    }

    private var typeIconView: some View {
        let icon = typeIcon
        return Image(systemName: icon.symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(icon.tint)
            .frame(width: 20)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(conversation.title)
                .font(.system(size: Theme.F.label, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)

            if let name = sessionName {
                Text(Self.sessionShortName(name))
                    .font(.system(size: Theme.F.badge, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }

            if conversation.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: Theme.F.badge))
                    .foregroundColor(Theme.favorite)
            }
        }
    }

    private var dateText: some View {
        Text(Self.smartDate(conversation.updateTime))
            .font(.system(size: Theme.F.caption))
            .foregroundColor(Theme.textMuted.opacity(0.7))
            .fixedSize()
    }

    /// 右侧固定 10pt 状态位：永远占位，只改透明度 / 缩放，未读来去不改行高（官端做法）
    private func statusSlot(showUnreadDot: Bool) -> some View {
        let dotOn = showUnreadDot && hasUnread && !isRunning
        return ZStack {
            Circle()
                .fill(Self.unreadTint)
                .frame(width: 6, height: 6)
                .opacity(dotOn ? 1 : 0)
                .scaleEffect(dotOn ? 1 : 0.3)
            // 条件插入没事：外面是定尺寸 ZStack，不影响行布局；只在跑的行才挂转圈，不让一百行都在后台转
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                    .transition(.opacity)
            }
        }
        .frame(width: 10, height: 10)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: dotOn)
        .animation(.easeInOut(duration: 0.2), value: isRunning)
    }
}

// MARK: - Favorited Bubble Row

struct FavoritedBubbleRow: View {
    let node: MessageNode
    let convTitle: String
    let isSelected: Bool
    var tags: [String] = []
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    var body: some View {
        // 收藏页「消息」分段的一行：发言人 · 出处对话，下面是这条消息的摘要
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(node.role == "user" ? userName : assistantName)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textSecondary)
                    Text("· \(convTitle)")
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted)
                }
                .lineLimit(1)

                Text(node.content.prefix(80).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)

                if !tags.isEmpty {
                    FavoriteTagLine(tags: tags)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.accent.opacity(0.5) : Color.clear)
        )
        .padding(.horizontal, 8)
    }
}

// MARK: - Chat Highlight Row（R3-2 收藏页划线分组）

/// 侧栏划线列表的一行 = 一处（同锚同原文，可能叠了几道）
struct ChatHighlightListItem: Identifiable {
    let place: MarkPlace<ChatHighlight>
    let node: MessageNode?
    /// 来源小字：对话标题 /「xx · 思考过程」/「$NVDA 的笔记」/「话题卡」/ 单词页
    let source: String
    let latestNote: String?
    let noteCount: Int
    var id: String { place.id }

    /// `thinking:<消息id>` → 消息 id；真消息锚原样
    static func messageNodeId(_ anchor: String) -> String {
        anchor.hasPrefix("thinking:") ? String(anchor.dropFirst("thinking:".count)) : anchor
    }
}

struct ChatHighlightRow: View {
    let item: ChatHighlightListItem
    let isSelected: Bool

    var body: some View {
        // 引文样式：左边一道划线色竖条（叠了几道就分几段颜色），原文在上，出处在下
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.place.primary.quote.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(3)

                if let note = item.latestNote, !note.isEmpty {
                    Text((item.noteCount > 1 ? "共 \(item.noteCount) 条 · " : "") + note)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }

                Text("— \(item.source)")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            .padding(.leading, 11)
            .overlay(alignment: .leading) {
                VStack(spacing: 2) {
                    ForEach(item.place.strokes.prefix(4), id: \.id) { s in
                        Capsule().fill(s.dotColor)
                    }
                }
                .frame(width: 3)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.accent.opacity(0.5) : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Deleted Bubble Row

struct DeletedBubbleRow: View {
    let node: MessageNode
    let convTitle: String
    @AppStorage("userName") private var userName = "你"
    @AppStorage("assistantName") private var assistantName = "助手"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: Theme.F.badge))
                .foregroundColor(Theme.textMuted.opacity(0.6))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(convTitle)
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)

                Text(node.content.prefix(80).replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }

            Spacer()

            Text(node.role == "user" ? userName : assistantName)
                .font(.caption2)
                .foregroundColor(Theme.textMuted.opacity(0.7))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}

// MARK: - Content Match Row

// MARK: - Sticker Match Row（贴纸搜索结果）

struct StickerMatchRow: View {
    let result: StickerSearchResult

    var body: some View {
        HStack(spacing: 8) {
            // 贴纸图标/缩略图
            if result.isNote {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: 1, green: 0.96, blue: 0.75))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text(String((result.noteContent ?? "").prefix(2)))
                            .font(.system(size: 8))
                            .foregroundColor(Theme.textPrimary)
                    )
            } else {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.branchIndicator.opacity(0.6))
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("🎨")
                        .font(.system(size: 9))
                    Text(result.assetName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                Text(result.conversationTitle)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
        )
        .padding(.horizontal, 8)
    }
}

// MARK: - Character Card Match Row

struct CharacterCardMatchRow: View {
    let result: CharacterCardSearchResult

    var body: some View {
        HStack(spacing: 8) {
            // 头像缩略
            Group {
                if let data = result.imageData {
                    #if os(macOS)
                    if let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else { Image(systemName: "person.crop.rectangle") }
                    #else
                    if let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else { Image(systemName: "person.crop.rectangle") }
                    #endif
                } else {
                    Image(systemName: "person.crop.rectangle")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    highlightedText(result.cardName, keyword: result.keyword)
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(result.matchedField)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.textMuted.opacity(0.15)))
                }
                highlightedText(result.preview, keyword: result.keyword)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}

// MARK: - World Book Entry Match Row

struct WorldBookEntryMatchRow: View {
    let result: WorldBookEntrySearchResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.isGlobal ? "globe" : "book.closed")
                .font(.system(size: 14))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(result.bookName)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                    Text("›")
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                    highlightedText(result.entryTitle, keyword: result.keyword)
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(result.matchedField)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.textMuted.opacity(0.15)))
                }
                highlightedText(result.preview, keyword: result.keyword)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}

// MARK: - Memory Match Row

struct MemoryMatchRow: View {
    let result: MemorySearchResult

    private var categoryLabel: String {
        switch result.category {
        case "fact": return "事实"
        case "preference": return "偏好"
        case "relationship": return "关系"
        case "goal": return "目标"
        case "context": return "情境"
        default: return result.category
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 13))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(categoryLabel)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.textMuted.opacity(0.15)))
                }
                highlightedText(result.preview, keyword: result.keyword)
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}

// MARK: - File Match Row（文件库搜索结果）

struct FileMatchRow: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    let result: FileSearchResult
    let words: [String]

    var body: some View {
        HStack(spacing: 8) {
            FileLibraryTile.file(result.path, profileId: profileManager?.currentProfile.id ?? "", side: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    highlightedText(result.name, words: words)
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    if !result.folder.isEmpty {
                        Text(result.folder)
                            .font(.system(size: Theme.F.badge))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
                if !result.body.isEmpty {
                    highlightedText(MacSearchQuery.excerpt(result.body, words: words), words: words)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}

// MARK: - Resource Hit Row（交易 / 健康 / 书房 / 推特，S3）

struct ResourceHitRow: View {
    let hit: ResourceHit
    let words: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: hit.symbol)
                .font(.system(size: 13))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    highlightedText(hit.title, words: words)
                        .font(.system(size: Theme.F.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(hit.tag)
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.textMuted.opacity(0.15)))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(MacSearchQuery.dateLabel(hit.date))
                        .font(.system(size: Theme.F.badge))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                if !hit.preview.isEmpty {
                    highlightedText(hit.preview, words: words)
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}

// MARK: - Content Match Row

struct ContentMatchRow: View {
    let nodeId: String
    let role: String
    let convTitle: String
    let preview: String
    let createTime: Date?
    let userName: String
    let assistantName: String
    var keyword: String = ""
    var words: [String] = []

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: Theme.F.badge))
                .foregroundColor(Theme.branchIndicator)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                if !convTitle.isEmpty {
                    Text(convTitle)
                        .font(.caption2)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }

                highlightedText(preview, words: words.isEmpty ? [keyword] : words)
                    .font(.system(size: Theme.F.body))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(role == "user" ? userName : assistantName)
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted.opacity(0.7))
                if let time = createTime {
                    Text(Self.dateFormatter.string(from: time))
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.clear)
        )
        .padding(.horizontal, 8)
    }
}

// MARK: - Keyword Highlighting Helper

func highlightedText(_ text: String, keyword: String) -> Text {
    guard !keyword.isEmpty else { return Text(text) }
    var result = Text("")
    var searchStart = text.startIndex

    while let range = text.range(of: keyword, options: .caseInsensitive, range: searchStart..<text.endIndex) {
        let before = text[searchStart..<range.lowerBound]
        if !before.isEmpty {
            result = result + Text(before)
        }
        let matched = text[range]
        result = result + Text(matched)
            .foregroundColor(Theme.branchIndicator)
            .bold()
        searchStart = range.upperBound
    }
    let tail = text[searchStart...]
    if !tail.isEmpty {
        result = result + Text(tail)
    }
    return result
}

/// 多个词全部高亮：命中区间由 MacSearchQuery.hitRanges 给（和 mac ⌘K 同一口径），颜色走 iOS / 侧栏主题
func highlightedText(_ text: String, words: [String]) -> Text {
    var result = Text("")
    var cursor = text.startIndex
    for range in MacSearchQuery.hitRanges(in: text, words: words) {
        if cursor < range.lowerBound { result = result + Text(text[cursor..<range.lowerBound]) }
        result = result + Text(text[range]).foregroundColor(Theme.branchIndicator).bold()
        cursor = range.upperBound
    }
    if cursor < text.endIndex { result = result + Text(text[cursor...]) }
    return result
}

// MARK: - Advanced Search Panel

struct AdvancedSearchPanel: View {
    @Binding var filter: SearchFilter
    let userName: String
    let assistantName: String
    /// 是否处于全量内容搜索模式（按过 ➡️）。false = 列表标题过滤模式，角色筛选无意义 → 灰掉
    let isContentSearchActive: Bool
    var onFilterChanged: () -> Void

    /// 资源类型下（角色卡/世界书/记忆），范围/角色筛选无意义 → 灰掉
    private var isResourceSearch: Bool {
        filter.resourceKind == .characterCard ||
        filter.resourceKind == .worldBook ||
        filter.resourceKind == .memory ||
        filter.resourceKind == .file ||
        filter.resourceKind.usesResourceHits
    }

    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            // 范围
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                categoryLabel("范围")
                scopeChip("标题", scope: .titleOnly)
                scopeChip("内容", scope: .contentOnly)
                scopeChip("标题+内容", scope: .both)
            }

            // 时间
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    categoryLabel("时间")
                    dateChip("全部", range: .all)
                    dateChip("今天", range: .today)
                    dateChip("7 天", range: .last7Days)
                    dateChip("30 天", range: .last30Days)
                    dateChip("90 天", range: .last90Days)
                    dateChip("自定义", range: .custom(start: customStart, end: customEnd))
                }

                if case .custom = filter.dateRange {
                    HStack(spacing: 8) {
                        DatePicker("", selection: $customStart, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .frame(maxWidth: 110)
                        Text("—")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                        DatePicker("", selection: $customEnd, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .frame(maxWidth: 110)
                    }
                    .onChange(of: customStart) { _, _ in
                        filter.dateRange = .custom(start: customStart, end: customEnd)
                        onFilterChanged()
                    }
                    .onChange(of: customEnd) { _, _ in
                        filter.dateRange = .custom(start: customStart, end: customEnd)
                        onFilterChanged()
                    }
                }
            }

            // 角色
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                categoryLabel("角色")
                roleChip(userName, role: "user")
                roleChip(assistantName, role: "assistant")
            }

            // 排序
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                categoryLabel("排序")
                sortChip("相关度", sort: .relevance)
                sortChip("最近", sort: .recent)
                sortChip("最早", sort: .oldest)
                sortChip("A→Z", sort: .titleAZ)
                sortChip("Z→A", sort: .titleZA)
            }

            // 类型 — 6 个 chip 一行塞不下，用 FlowLayout 自动换行（B20 part 2 反馈 Bβ）
            VStack(alignment: .leading, spacing: 6) {
                categoryLabel("类型")
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    typeChip("全部", kind: .conversation)
                    typeChip("🌿 分支", kind: .branchContent)
                    typeChip("🎨 贴纸", kind: .sticker)
                    typeChip("👤 助手模板", kind: .characterCard)
                    typeChip("📚 世界书", kind: .worldBook)
                    typeChip("🧠 记忆", kind: .memory)
                    typeChip("📄 文件", kind: .file)
                    #if PERSONAL_APPS
                    typeChip("📈 交易", kind: .trading)
                    #endif
                    typeChip("❤️ 健康", kind: .health)
                    typeChip("📖 书房", kind: .library)
                    typeChip("🕊️ 推特", kind: .twitter)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, isIOSStyle ? 25 : 17)
        .padding(.trailing, isIOSStyle ? 20 : 12)
        .padding(.top, 8)
        .padding(.bottom, 18)
        #if os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.mainBg.opacity(0.6))
        )
        .padding(.horizontal, 10)
        #endif
    }

    private var isIOSStyle: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// 分类名（时间/角色/排序/类型）
    private func categoryLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: Theme.F.badge, weight: .medium))
            .foregroundColor(Theme.textMuted)
    }

    /// 统一的纯文字过滤选项：字号 = tab 栏字号，选中态靠字重+颜色，无背景
    private func filterOption(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? Theme.branchIndicator : Theme.textSecondary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dateChip(_ title: String, range: DateRange) -> some View {
        filterOption(title, isActive: filter.dateRange == range) {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter.dateRange = range
            }
            onFilterChanged()
        }
    }

    private func roleChip(_ title: String, role: String) -> some View {
        let isActive = filter.roles.contains(role)
        // 列表标题过滤模式下，角色对 Conversation.title 无意义 → 灰掉 + 禁用
        return Button(action: {
            if isActive && filter.roles.count > 1 {
                filter.roles.remove(role)
            } else if !isActive {
                filter.roles.insert(role)
            }
            onFilterChanged()
        }) {
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: isActive && isContentSearchActive ? .semibold : .regular))
                .foregroundColor(
                    isContentSearchActive
                        ? (isActive ? Theme.branchIndicator : Theme.textSecondary)
                        : Theme.textMuted.opacity(0.4)
                )
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isContentSearchActive)
    }

    private func sortChip(_ title: String, sort: SearchSort) -> some View {
        filterOption(title, isActive: filter.sortOrder == sort) {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter.sortOrder = sort
            }
            onFilterChanged()
        }
    }

    private func scopeChip(_ title: String, scope: SearchScope) -> some View {
        // 资源搜索（角色卡/世界书/记忆）没"标题 vs 内容"二分 → 灰掉 + 禁用
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter.scope = scope
            }
            onFilterChanged()
        }) {
            Text(title)
                .font(.system(size: Theme.F.secondary, weight: filter.scope == scope && !isResourceSearch ? .semibold : .regular))
                .foregroundColor(
                    isResourceSearch
                        ? Theme.textMuted.opacity(0.4)
                        : (filter.scope == scope ? Theme.branchIndicator : Theme.textSecondary)
                )
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isResourceSearch)
    }

    private func typeChip(_ title: String, kind: SearchResourceKind) -> some View {
        filterOption(title, isActive: filter.resourceKind == kind) {
            withAnimation(.easeInOut(duration: 0.15)) {
                filter.resourceKind = kind
            }
            onFilterChanged()
        }
    }
}

// MARK: - Inverse Tab Corner（Chrome 反向圆角）

struct InverseTabCorner: View {
    let radius: CGFloat
    let flipped: Bool

    var body: some View {
        InverseTabCornerShape()
            .fill(Theme.mainBg)
            .frame(width: radius, height: radius)
            .scaleEffect(x: flipped ? -1 : 1, anchor: .center)
            .offset(x: flipped ? -radius : radius)
    }
}

struct InverseTabCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height)
        // 填 mainBg 的区域：左下角 + 凹弧
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addLine(to: CGPoint(x: r, y: r))
        path.addArc(
            center: CGPoint(x: r, y: 0),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - Sidebar Card Shape（Chrome 风格：选中 tab 下方 topLeading 清零连上 tab）

/// 收藏标签：「收藏到标签…」sheet + 胶囊长按改名的 alert。独立 modifier，不往 body 长链上直接堆
private struct FavoriteTagHost: ViewModifier {
    @Binding var target: FavoriteTags.Target?
    @Binding var renaming: String?
    @Binding var renameText: String
    let onChanged: () -> Void
    let onRename: (String, String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $target) { t in
                FavoriteTagSheet(target: t, onDone: onChanged)
            }
            .alert("重命名标签", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("标签名", text: $renameText)
                Button("取消", role: .cancel) { renaming = nil }
                Button("确认") {
                    if let old = renaming { onRename(old, renameText) }
                    renaming = nil
                }
            }
    }
}

private struct SidebarCardShape: ViewModifier {
    let topLeading: CGFloat
    let topTrailing: CGFloat

    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(ShellStyle.chrome)
        #else
        content
            .background(Theme.mainBg)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: topLeading,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 16,
                topTrailingRadius: topTrailing
            ))
            .padding(.horizontal, horizontalPadding)
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(iOS)
        20
        #else
        12
        #endif
    }
}

#if os(iOS)
/// page0 列表滚离顶部后，卡片顶边一条小渐隐：高度同底部计数行渐变（≈24pt），曲线同聊天页 ChatEdgeFadeMask 的 smoothstep。
/// 卡片是 Theme.mainBg 实底，顶边叠一层 mainBg → 透明的渐变，跟「行变透明露卡片底色」同一个效果，液态金属开 / 关两种底都一样；
/// 在顶部（含下拉刷新）时不遮。不用 .mask：mask 包住 ScrollView 后卡片顶边被画低约 2/3pt，「全部」页签和卡片之间漏缝（粟粟 10-02）
private struct Page0ListTopFade: ViewModifier {
    @State private var scrolled = false
    private static let height: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, isScrolled in
                scrolled = isScrolled
            }
            .overlay(alignment: .top) {
                LinearGradient(stops: fadeStops, startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.height)
                    .opacity(scrolled ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: scrolled)
                    .allowsHitTesting(false)
            }
    }

    /// 顶边不透明 → 下沿透明，smoothstep 反向（= 原 mask 的 1 − alpha）
    private var fadeStops: [Gradient.Stop] {
        (0...16).map { index in
            let t = Double(index) / 16
            return .init(color: Theme.mainBg.opacity(1 - t * t * (3 - 2 * t)), location: CGFloat(t))
        }
    }
}
#endif

extension View {
    /// 左栏内容卡：Theme.mainBg 底 + 跟随选中 tab 的 UnevenRoundedRectangle + 水平 padding。
    /// 搜索结果卡、空结果卡、正常列表卡、贴纸搜索卡 5 处统一走这条。
    fileprivate func sidebarCardShape(topLeading: CGFloat, topTrailing: CGFloat) -> some View {
        modifier(SidebarCardShape(topLeading: topLeading, topTrailing: topTrailing))
    }
}

// MARK: - Tag Reorder Drop Delegate

struct TagReorderDropDelegate: DropDelegate {
    let targetTagId: String
    let tags: [ConversationTag]
    let modelContext: ModelContext
    @Binding var draggingTagId: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingTagId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let fromId = draggingTagId, fromId != targetTagId else { return }
        reorder(fromId: fromId, toId: targetTagId)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool { true }

    private func reorder(fromId: String, toId: String) {
        var sorted = tags.sorted { $0.order < $1.order }
        guard let fromIdx = sorted.firstIndex(where: { $0.id == fromId }),
              let toIdx = sorted.firstIndex(where: { $0.id == toId }) else { return }
        let moving = sorted.remove(at: fromIdx)
        sorted.insert(moving, at: toIdx)
        for (i, tag) in sorted.enumerated() {
            tag.order = i
        }
        try? modelContext.save()
        // C4 写点：order 即 tab 顺序，不发通知拖完不动（显式 fetch 不再自动失效）。
        NotificationCenter.default.post(name: .conversationTagsChanged, object: nil)
    }
}
