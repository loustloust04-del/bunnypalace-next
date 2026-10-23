import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

#if DEBUG
@MainActor enum PerfCounters {
    static var contentViewBody = 0
    static var chatInputBarBody = 0
    static var inputFieldBody = 0
    static var cardFlowBody = 0
    /// iu0902 C4：侧边栏整体 body 次数（@Query<ConversationTag> 每 save 失效的判据）
    static var sidebarBody = 0
    /// 上一次 ContentView.body 的订阅源快照，用于诊断 #N body 是哪个 source 变了
    static var lastContentViewSnapshot: [String: String] = [:]
}
#endif

private enum ContentDestination: Equatable {
    case chat
    case agoraRoom
}

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(ThemeManager.self) private var themeManager: ThemeManager?
    @State private var viewModel = ConversationViewModel()
    @State private var agoraViewModel = AgoraViewModel()
    @State private var destination: ContentDestination = .chat
    @State private var showAgoraCreateSheet = false
    @Environment(GlobalWorldBookManager.self) private var globalWBManager: GlobalWorldBookManager?
    /// 路线 B 下 ContentView 订阅 ProfileManager 获取 currentProfile.id，用于给 @Query-backed
    /// sub-views (EmptyStateView 等) init(profileId:) 传值。由于 ProfileManager.switchTo
    /// 只改 currentProfile（container 不动），订阅 ProfileManager 触发的 body rebuild 不会
    /// 引发 SwiftData reset race，安全。原 master R1 revert 担心的是订阅 3 个 Manager 放大
    /// body 频次，这里只订阅 ProfileManager（currentProfile 变化频率极低）。
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    // ProviderManager / PresetManager 的 @Environment 订阅挪到
    // PagingContainerView（Representable 层），避免 ContentView.body 被这些 @Observable
    // Manager 的属性变化触发整体重算 + 被 updatePages 大锤放大到 ChatInputBar.body
    // （master R1 revert 原罪，见 docs/postmortem-kelivo-keyboard-wallpaper.md）。
    @Environment(RightPanelNavigator.self) private var rightPanelNavigator: RightPanelNavigator?
    @Environment(RightPanelToolManager.self) private var rightPanelToolManager: RightPanelToolManager?
    #if os(macOS)
    /// 设置是独立窗口（⌘,，plan-mac-shape A5）；iOS 仍是 sheet
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var showImporter = false
    @State private var showSettings = false
    /// 摇一摇反馈（上架版）：只带页面描述，不采截图/上下文
    @State private var feedbackPayload: FeedbackPayload? = nil
    @AppStorage("feedbackGestureEnabled") private var feedbackGestureEnabled = true
    @State private var searchText = ""
    @State private var showFavoritesOnly = false
    @State private var showTrash = false
    #if os(iOS)
    // 当前 iOS page：0=list, 1=chat, 2=more。只由 PageSync 读（翻页命令 + 副作用）；
    // UIKit 手势翻页落定后经 PagingContainerView.onPageChanged 回写。
    @State private var iOSPage: Int = ProcessInfo.processInfo.arguments.contains("page2-ui-test") ? 2 : 1
    /// 首启引导：未完成就盖 fullScreenCover（设计 docs/未来愿景/design-onboarding.md）；
    /// 设置页搜索框「?」重走一遍时把 onboardingCompletedV1 置 false 也会回到这里。
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingCompletedV1")
    /// 宽屏悬浮面板形态（iPad 横屏等，判据见 Theme.landscapePanelThreshold）：
    /// 三页横滑收成固定聊天页，列表/更多改由左右浮层承载。
    @State private var isWidePanelMode = false
    /// 转屏归位那一次要静音：否则每次横竖切换都震一下、还会白收一次键盘
    @State private var suppressPageEffects = false
    /// 只为订阅：设置-外观-iPad 改了正文栏宽度，这里一变就带整棵 iOS 树重算，
    /// 各消费点（聊天正文/输入条/桌面/dock/浮层）才会重新读 Theme.contentMaxWidth。
    /// 值本身不在这里用——@AppStorage 的 declaration 就是订阅。
    @AppStorage(Theme.contentWidthKey) private var ipadContentWidthPref: Double = Double(Theme.contentWidthDefault)
    #endif
    // ── 宽屏壳状态（iPad 宽屏 overlay 与 mac 新壳共用，plan-mac-shape A1a 提出 #if）
    /// 宽屏形态下的可用尺寸，面板据此钳宽度、算浮窗高度
    @State private var widePanelAvailableSize: CGSize = .zero
    /// 面板布局状态（模式/展开/宽高/开着哪些卡），全部持久化。body 里**只读开关和模式**，
    /// 不读宽高——宽高由 IPadPanelOverlay / DockedInsetHost 自己读，拖动才不会带整棵树重算
    /// （@Observable 按属性追踪；ContentView.body 一重算就 updatePages 三棵 HC 树）。
    private let panelLayout = IPadPanelLayout.shared
    // iOSPageDragOffset removed — ScrollView handles drag natively
    #if os(iOS)
    @SceneStorage("page2.currentApp") private var selectedToolId: String = "home"   // iOS：page2 默认停桌面；被系统杀掉后回到离开时的应用
    /// page2 后台的应用和返回路径。Page2AppShell 在分页子 HC 里拿不到 SceneStorage，由这里恢复和写盘
    @SceneStorage("page2.openApps") private var page2OpenApps = ""
    @SceneStorage("page2.readingBook") private var page2ReadingBook = ""
    #endif
    @State private var stickerVM = StickerViewModel()
    #if os(iOS)
    @State private var isKeyboardVisible = false
    @State private var topSafeAreaInset: CGFloat = 59  // 默认 iPhone 常见值；onAppear 更新成 UIApplication 的真值
    #endif
    /// 顶栏状态岛收起（往下读时，粟粟 09-28 稿）
    @Environment(\.accessibilityReduceMotion) private var topBarReduceMotion
    @State private var topBarCollapse = TopBarCollapseState()
    /// 长按顶栏岛：置顶消息 + 音乐卡预览（学 Telegram）
    @State private var showIslandPeek = false
    /// 岛上显示第几条置顶（聊天先后，nil = 最新）；换条方向（更新的 = 往上走）
    @State private var islandPinIndex: Int?
    @State private var islandPinSlideUp = false
    // Pin Bar state：两端共用（iOS 挂 iOSChatTopBar，mac 挂 macChatContent——面 2.1 从 CardFlowView 挪上来）
    @State private var pinCurrentIndex: Int = 0
    @State private var pinBarHidden: Bool = false
    // 对话菜单 / 重命名 / 改标签 / 分支地图（B20 part 2 A3）——悬浮条的菜单两端共用，宿主各自挂
    @State private var showRenameAlert = false
    #if os(macOS)
    @State private var showCodingCard = false
    #endif
    @State private var renameText: String = ""
    @State private var showChangeProjectSheet = false
    /// 对话 ⋯「窗口总结」「上下文摘要」打开的那个（弹层挂在 `ConversationMemorySheets`）
    @State private var memorySheet: ConversationMemorySheetTarget? = nil
    @State private var showBranchMap = false
    #if os(macOS)
    // bgMode 在 iOS 上从未被 read（仅 macOS 内 zstackLayer 判断），但 @AppStorage declaration
    // 让 ContentView 订阅 _debugBackgroundModeRaw 这个 wrapper，启动后 UserDefaults 异步同步
    // 触发 ContentView body re-eval（第三轮 log 实证 #2 +2.85s ghost body 的真凶）。
    // 包 #if os(macOS) 后 iOS struct 没这个 property，不再订阅。
    @AppStorage(DebugRenderSettings.themeBackgroundModeKey)
    private var debugBackgroundModeRaw: String = DebugThemeBackgroundMode.original.rawValue

    private var debugBackgroundMode: DebugThemeBackgroundMode {
        DebugThemeBackgroundMode(rawValue: debugBackgroundModeRaw) ?? .original
    }
    #endif
    @AppStorage("blurRadius") private var blurRadius = 1.3
    /// 气泡模式下悬浮条不挂 🌿 分支钮（两端共用）
    @AppStorage("chatBubbleMode") private var chatBubbleMode = false
    /// 设置 › 外观 › 音乐：聊天页以外挂不挂全局音乐胶囊
    @AppStorage("globalMusicCapsuleEnabled") private var globalMusicCapsuleEnabled = true
    // pageIndicatorInZStack / debugPageIndicatorMode / @AppStorage debugPageIndicatorModeRaw
    // 全 dead code（pageIndicatorInZStack 无 call site）— 已删除以减少订阅 surface。
    /// 启动 / 回到无选中态时托底一个草稿对话，让聊天页直接可输入（不落库、不进 page0）。
    private func ensureDraftConversation() {
        guard viewModel.selectedConversation == nil else { return }
        #if DEBUG
        if ChatSampleSeed.isActive, let pm = profileManager, pm.currentProfile.id == ChatSampleSeed.profileId {
            let ctx = ModelContext(pm.container)
            let cid = ChatSampleSeed.conversationId
            let pid = ChatSampleSeed.profileId
            if let conversation = try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId == pid })).first {
                viewModel.loadConversation(conversation, context: ctx, scrollTargetNodeId: "sample-tools")
                return
            }
        }
        #endif
        let pid = profileManager?.currentProfile.id ?? ""
        guard !pid.isEmpty else { return }
        viewModel.startDraftConversation(profileId: pid)
    }

    var body: some View {
        #if DEBUG
        // SwiftUI 暗器 _logChanges() — 让 SwiftUI runtime 自己 print "因为 X 改变所以重 eval"
        // （走 unified logging os_log，subsystem 大致是 com.apple.SwiftUI）。Hermes Q2 推荐
        // 用 newer variant 替代 _printChanges()。两者都是 underscore-prefixed 非 public API，
        // iOS 26 / macOS 14 deployment target 上 verified 可用，DEBUG only。
        // 若以后 Apple 改签名，build error → fallback Self._printChanges()。
        let _ = Self._printChanges()
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = PerfCount.hit("contentViewBody")
        let _ = LaunchTrace.event("contentViewBody")
        let bodySpan = LaunchTrace.begin("contentViewBody")
        defer { LaunchTrace.end("contentViewBody", bodySpan) }
        #endif
        let manager = themeManager ?? ThemeManager.shared
        let _ = manager.themeChangeID
        #if os(macOS)
        let bgMode = debugBackgroundMode
        #endif
        #if DEBUG
        // 订阅源 snapshot — 砍掉之前探针 observer effect 引入的字段（ContentView 生产代码
        // 不 read 这些 field，但探针 read 让 ContentView 订阅了它们 → 第三轮 log 看到的
        // sidebarRefresh / stickerCount 触发 body 是"假" hot path，是探针自己挑起的）。
        // 保留字段 = ContentView body 真实 read 的 source（grep 实证）：
        //   selectedConv / currentPath / isStreaming / pinnedNodes (= currentPath 衍生) /
        //   isEditingStickers / themeID / profileId / colorScheme.
        //   （iOSPage / isKeyboardVisible 已删：翻页解耦后 body 不读它们，plan-paging-decouple B-2）
        // 删除（探针引入）：scrollToNode / highlightNode / streamingTextLen / sidebarRefresh /
        //   stickerCount / stickerSelected / stickerImporting / wbBooks / navTarget / bgMode(iOS).
        // 头号嫌疑根据 Hermes Q4 不再是 SwiftData @Model（per-keypath 应不 invalidate）。
        PerfCounters.contentViewBody += 1
        var _bodyProbeSnapshot: [String: String] = [
            "selectedConv": viewModel.selectedConversation?.id.prefix(8).description ?? "nil",
            "isStreaming": "\(viewModel.providerRouter.isStreaming)",
            "isEditingStickers": "\(stickerVM.isEditingStickers)",
            "themeID": manager.themeChangeID.uuidString.prefix(8).description,
            "profileId": profileManager?.currentProfile.id.prefix(8).description ?? "nil",
            "colorScheme": "\(colorScheme)",
        ]
        // L6 A7：开关开时探针也不读 path 衍生量（否则 Debug 下 ContentView 仍订阅 currentPath）
        if !ChatPerfSwitch.a7 {
            _bodyProbeSnapshot["currentPath"] = "\(viewModel.currentPath.count)"
            _bodyProbeSnapshot["pinnedNodes"] = "\(viewModel.pinnedNodes.count)"
        }
        #if os(macOS)
        _bodyProbeSnapshot["bgMode"] = bgMode.rawValue
        #endif
        let _bodyProbeDiff = _bodyProbeSnapshot
            .filter { PerfCounters.lastContentViewSnapshot[$0.key] != $0.value }
            .map { "\($0.key): \(PerfCounters.lastContentViewSnapshot[$0.key] ?? "∅")→\($0.value)" }
            .sorted()
        PerfCounters.lastContentViewSnapshot = _bodyProbeSnapshot
        let _bodyProbeDiffStr = _bodyProbeDiff.isEmpty ? "(none — SwiftUI re-eval w/o source change?)" : _bodyProbeDiff.joined(separator: ", ")
        print(String(format: "[PERF] ContentView.body #%d t=%.3f Δ=%@",
                     PerfCounters.contentViewBody,
                     CFAbsoluteTimeGetCurrent(),
                     _bodyProbeDiffStr))
        #endif
        return ZStack {
            #if os(macOS)
            // master 的 Theme.mainBg baseline，仅 macOS 留：路线 C 下 iOS 每页自己 .background +
            // hc.view.clipsToBounds 已兜底，不需要 baseline；macOS 保留作 ZStack 底色防露白。
            // 窗口玻璃开（停靠壳）时不画：系统玻璃模糊的是窗里它底下的东西，垫着实底就只模糊出一片奶白（plan-mac-glass-chrome）
            if !macGlassActive {
                Theme.mainBg.ignoresSafeArea()
            }
            #endif

            #if os(macOS)
            // Debug: C 模式把 wallpaper 挪到 ZStack 底层（避开 .background 的 parent-size 约束）
            // iOS 下已改为"只聊天页带 wallpaper"，全局 zstackLayer 不再适用，保留仅 macOS
            if bgMode == .zstackLayer, !macGlassActive {
                ThemeBackgroundView(
                    fill: Theme.mainBg,
                    imageURL: manager.currentBackgroundImageURL,
                    scheme: manager.activeScheme,
                    backgroundStyle: manager.currentBackgroundStyle
                )
                .ignoresSafeArea()
            }
            // 一棵树（plan-mac-shape ⧫4）：普通窗口和系统全屏同一份 macLayout，全屏只是窗口变大；
            // 02-26 为绕白框分的双树、64pt 遮色条、右上角钮、全屏观察者 A1b 一并删
            macLayout
            #endif
            #if os(iOS)
            iOSLayout
            #endif

            // 全局 toast（R3.3：各 view 自挂 overlay 位置漂移——统一钉屏幕顶）
            GlobalToastOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { ensureDraftConversation() }
        .onChange(of: viewModel.selectedConversation == nil) { _, isNil in
            if isNil { ensureDraftConversation() }
        }
        #if os(macOS)
        .background {
            if bgMode != .zstackLayer, !macGlassActive {
                ThemeBackgroundView(
                    fill: Theme.mainBg,
                    imageURL: manager.currentBackgroundImageURL,
                    scheme: manager.activeScheme,
                    backgroundStyle: manager.currentBackgroundStyle
                )
                .ignoresSafeArea()
            }
        }
        #else
        // 路线 C：body.background 撤了。每页自己处理背景 + safe area 延伸：
        // - iOSListPage / iOSDashboardPage 各自 .background(color.ignoresSafeArea())
        // - iOSChatPage 内部 .background { ChatWallpaperBackdrop.ignoresSafeArea() } + topBar overlay
        // R1 revert (2026-04-19 perf)：原来这里有 scenePhase / profileManager 两个 onChange flush，
        // chat→sidebar 的 flush 已挪到 onChange(iOSPage) 里 (oldPage==1 && newPage==0 触发)。
        // 页码点（翻页浮现 ~1s 后淡出，粟粟点名）perf-flash C1 起由 PagingViewController 持有（UIKit）
        // ── 宽屏面板（挂 body overlay 而不是 iOSLayout 内部：child HC 不继承 parent
        // 的 SwiftUI env，SidebarView 要的 CharacterCardManager / RightPanelNavigator
        // 只有在这一层才拿得到，见 research-ipad-landscape §2.4）。
        // 面板常驻（没有 pin 了，展开就是常驻），不铺点外收起层。
        .overlay {
            if isWidePanelMode {
                ZStack(alignment: .top) {
                    IPadPanelOverlay(layout: panelLayout, availableSize: widePanelAvailableSize,
                                     viewModel: viewModel, stickerVM: stickerVM) {
                        SidebarView(
                            searchText: $searchText,
                            showFavoritesOnly: $showFavoritesOnly,
                            showTrash: $showTrash,
                            showImporter: $showImporter,
                            showSettings: $showSettings,
                            viewModel: viewModel,
                            agoraViewModel: agoraViewModel,
                            onSelectAgoraRoom: { room in
                                selectAgoraRoom(room)
                                collapseLeftPanelAfterSelect()
                            },
                            onCreateAgoraRoom: { showAgoraCreateSheet = true },
                            onSelectConversation: {
                                showNormalChat()
                                collapseLeftPanelAfterSelect()
                            },
                            profileId: profileManager?.currentProfile.id ?? ""
                        )
                    }
                    .environment(\.widePanelMode, true)
                    // 顶部悬浮条居中于**设置算出的聊天区**（排版 / dock 左右 / 模式都是设置），与面板、窗口开关无关
                    // （粟粟：「应该跟着我的设置变而不是跟着我的窗口变」）。没格子（Split View）时屏幕居中
                    if destination == .chat {
                        let g = panelLayout.grid(in: widePanelAvailableSize)
                        fencedByA7 { landscapeTopBar }
                            .padding(.top, 6)
                            .offset(x: g.map { $0.leftLane + $0.chatWidth / 2 - widePanelAvailableSize.width / 2 } ?? 0)
                            // 对话内查找时让给聊天页顶栏里的搜索栏（它在 chat HC 里，键盘管线认得它的焦点）
                            // 多选同理：让给聊天页顶栏里的「取消 / 已选 N 条」
                            .opacity(viewModel.inConvSearchActive || viewModel.messageSelection.isActive ? 0 : 1)
                            .allowsHitTesting(!viewModel.inConvSearchActive && !viewModel.messageSelection.isActive)
                            .zIndex(3000)
                    }
                }
                // 宽度掉到阈值以下（Split View / 转竖屏）时整层退场：淡出 + 微缩，
                // 跟 `isWidePanelMode` 那一处的 withAnimation 是同一条事务
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        #if DEBUG
        // DebugOrb：设置-开发调试-悬浮调试球 toggle 控制；在所有页面上方。
        // sheet 不会被它盖住（sheet 在独立 window scene 上层），录屏时 sheet 收起浮球可见。
        .overlay {
            DebugOrbHost()
        }
        #endif
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .showStickerLibrary)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                #if os(iOS)
                // iOS 窄屏只换页 2 的选中工具、不翻页（现役行为）；宽屏开 tab
                selectedToolId = "sticker"
                if isWidePanelMode { openToolFromOutside("sticker") }
                #else
                openToolFromOutside("sticker")
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: VocabCollector.sourceJumpNotification)) { notif in
            // 收词来源跳转：词详情/刷词卡点出处 → 跳回收词的对话原处（B20 统一入口，
            // 自动切分支/切 page/去抖；node 已删由发送端预检，这里兜底静默）
            guard let nodeId = notif.userInfo?["nodeId"] as? String else { return }
            let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { $0.id == nodeId })
            guard let node = (try? modelContext.fetch(nodeDesc))?.first, !node.isTrashed else {
                ToastCenter.shared.show("原消息已删除")
                return
            }
            let convId = node.conversationId
            let pid = profileManager?.currentProfile.id ?? ""
            let convDesc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.id == convId && $0.profileId == pid }
            )
            guard let conversation = (try? modelContext.fetch(convDesc))?.first else {
                ToastCenter.shared.show("原对话不在这个楼层")
                return
            }
            showNormalChat()
            viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conversation, context: modelContext)
            // 思考链收词：导航落地（滚动/切页 settle）后请求气泡弹思考链+闪词
            if let word = notif.userInfo?["thinkingWord"] as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NotificationCenter.default.post(
                        name: VocabCollector.openThinkingNotification, object: nil,
                        userInfo: ["nodeId": nodeId, "highlightWord": word]
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openVocabTool)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { openToolFromOutside("vocab") }
        }
        #if os(macOS)
        // 本机终端（plan-mp-local-terminal A5）：编程会话「继续 → 记忆花园」开了 tab，把终端面板拉到前面
        .onReceive(NotificationCenter.default.publisher(for: .openLocalTerminalTool)) { _ in
            if rightPanelToolManager?.tool(byId: "terminal")?.isEnabled == false {
                rightPanelToolManager?.setEnabled("terminal", true)
            }
            withAnimation(.easeInOut(duration: 0.2)) { openToolFromOutside("terminal") }
        }
        #endif
        #if PERSONAL_APPS
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .openTopicBoxTool)) { notif in
            // 工具被从 toolbar 移除时自动请回来（widget 还在桌面就该点得进去）
            if rightPanelToolManager?.tool(byId: "topicBox")?.isEnabled == false {
                rightPanelToolManager?.setEnabled("topicBox", true)
            }
            // 面板可能还没挂载收不到本通知——停一份，面板 onAppear 消费
            if let path = notif.userInfo?["topicPath"] as? String {
                TopicBoxStore.pendingOpenRelPath = path
            }
            withAnimation(.easeInOut(duration: 0.2)) { openToolFromOutside("topicBox") }
        }
        #endif
        #endif
        #if PERSONAL_APPS
        .modifier(OnNotify(.deathScaleUnlock) { unlockDeathScale() })
        #endif
        // turn 收口回填（挂 app 根，不依赖面板/阅读器存活）：
        // CR-3 vocab aiNote + CR-1 书批注 aiBubble
        .onReceive(NotificationCenter.default.publisher(for: .assistantTurnDidFinish)) { notif in
            guard let nodeId = notif.userInfo?["nodeId"] as? String,
                  let convId = notif.userInfo?["conversationId"] as? String else { return }
            VocabCollector.fillAINote(nodeId: nodeId, conversationId: convId, context: modelContext)
            BookNoteBackfill.fill(nodeId: nodeId, conversationId: convId, context: modelContext)
            // R2：聊天内批注意向（```book-note 块）落地成书页批注
            AgentBookNoteWriter.processChatIntents(nodeId: nodeId, context: modelContext)
            // 发语音条：```voice 块 → ElevenLabs TTS → .audioRef 语音条
            VoiceMessageWriter.processChatIntents(nodeId: nodeId, context: modelContext, profiles: profileManager?.profiles ?? [])
            // 健康记录：```health-log 块 → 落库 → 结果行
            HealthLogIntentWriter.processChatIntents(nodeId: nodeId, context: modelContext)
            #if PERSONAL_APPS
            // 交易记录：```trade 块 → 落卡（开/平/复盘）→ 结果行 + journal.md 镜像
            TradeLogIntentWriter.processChatIntents(nodeId: nodeId, context: modelContext)
            #endif
            // 纪念日：```anniversary 块 → 记进日历 → 结果行（plan-calendar §八）
            AnniversaryIntentWriter.processChatIntents(nodeId: nodeId, context: modelContext)
            // 语音通话：流式已经边写边念，这里只收尾（flush + 结束本轮）；整轮没收到流式 delta 才整段念（未通话时零成本 guard）
            #if os(iOS)
            if CallSession.shared.active {
                CallSession.shared.assistantTurnFinished(nodeId: nodeId, conversationId: convId) {
                    let callDesc = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { $0.id == nodeId })
                    guard let node = (try? modelContext.fetch(callDesc))?.first, node.role == "assistant" else { return nil }
                    return node.content
                }
            }
            #endif
        }
        // 资源搜索点击 → SidebarView 设 navigator.pendingTarget → 这里协调打开工具（条目目标由各面板消费）
        .onChange(of: rightPanelNavigator?.pendingTarget) { _, target in
            guard let t = target else { return }
            withAnimation(.easeInOut(duration: 0.2)) { openToolFromOutside(t.tool) }
        }
        .transaction { tx in
            tx.animation = nil
        }
        .modifier(CardLibraryReturnHooks(
            returnProfileId: rightPanelNavigator?.cardLibraryReturnProfileId,
            onReturn: consumeCardLibraryReturn,
            onOpenChat: showNormalChat
        ))
        .onAppear {
            LaunchMarks.mark("contentAppear")   // 秒连尺子
            consumeCardLibraryReturn()
            #if (DEBUG || PERF_BENCH) && os(iOS)
            PerfHarness.viewModel = viewModel
            PerfHarness.modelContext = modelContext
            #endif
            #if os(iOS)
            // #042：通话接线不依赖通话页，锁屏接原生来电也能开麦
            CallController.shared.attach(viewModel: viewModel, modelContext: modelContext)
            #endif
            // CC Bridge: 启动时自动连接
            // 读 baseURL override（UserDefaults，由 setCCBridgeBaseURL 写入）+ token（keychain）
            // 不走 ProviderManager 是为了维持 ContentView 不订阅它（性能优化，见上面注释）
            let urls = CCBridgeEndpoints.configuredURLs()
            if !urls.isEmpty {
                // Phase 2：走 HubTokenStore（keychain 优先 + macOS 首次读 launchd plist bootstrap），
                // 保证 hub 收紧 loopback 后 Mac app 侧仍能自愈拿到 token。
                let token = HubTokenStore.get()
                CCBridgeWebSocketClient.shared.connect(urls: urls, token: (token?.isEmpty == false) ? token : nil, keepExistingToken: true)
            }
            // CC 主动消息：收到 reply 但无 pending 占位（CC 主动发的）→ 落地成对应会话的新小克消息
            CCBridgeWebSocketClient.shared.onProactiveMessage = { [weak viewModel] chatId, content, fileData, fileName, mime, isImage, ccMessageId, replyToId, callReply in
                viewModel?.insertProactiveAssistantMessage(chatId: chatId, content: content, fileData: fileData, fileName: fileName, mime: mime, isImage: isImage, ccMessageId: ccMessageId, replyToId: replyToId, callReply: callReply, context: modelContext)
            }
            // A4：CC 编辑消息 → 按 ccMessageId 找节点改 content
            CCBridgeWebSocketClient.shared.onEditMessage = { [weak viewModel] chatId, ccMessageId, content, streaming in
                viewModel?.applyCCEdit(chatId: chatId, ccMessageId: ccMessageId, content: content, streaming: streaming, context: modelContext)
            }
            // 思考链：CC 当轮 thinking → 挂到 ccMessageId 锚定的消息节点
            CCBridgeWebSocketClient.shared.onThinking = { [weak viewModel] chatId, ccMessageId, content in
                viewModel?.applyCCThinking(chatId: chatId, ccMessageId: ccMessageId, content: content, context: modelContext)
            }
            // 问问题 CC 桥：题面弹卡 / 收账落 Q/A 泡 / 失效收卡
            CCBridgeWebSocketClient.shared.onAskUserQuestion = { [weak viewModel] chatId, toolUseId, questions in
                viewModel?.presentCCAskUser(chatId: chatId, toolUseId: toolUseId, questions: questions, context: modelContext)
            }
            CCBridgeWebSocketClient.shared.onAskUserResolved = { [weak viewModel] chatId, toolUseId, questions, answers in
                viewModel?.handleCCAskUserResolved(chatId: chatId, toolUseId: toolUseId, questions: questions, answers: answers, context: modelContext)
            }
            CCBridgeWebSocketClient.shared.onAskUserStale = { [weak viewModel] toolUseId in
                viewModel?.handleCCAskUserStale(toolUseId: toolUseId)
            }
            // CR-4：AI 读书产物（批注落书 + 读后感进对话）；true = ack 让 hub 删 pending
            CCBridgeWebSocketClient.shared.onAgentBookNote = { payload in
                AgentBookNoteWriter.handle(payload, context: modelContext)
            }
            #if PERSONAL_APPS
            CCBridgeWebSocketClient.shared.onTradingReport = { [weak profileManager] payload in
                TradingReportLanding.handle(payload, profileId: profileManager?.currentProfile.id ?? "",
                                            context: modelContext)
            }
            #endif
            // 小克用本地推特：chat_id 定楼层，缺省当前楼层
            CCBridgeWebSocketClient.shared.onTwitterCmd = { [weak profileManager] frame in
                TwitterCCBridge.handle(frame, profiles: profileManager?.profiles ?? [],
                                       currentProfileId: profileManager?.currentProfile.id ?? "",
                                       context: modelContext)
            }
            #if PERSONAL_APPS
            // 夜跑自动档：启动时全量上报一次关注列表（连接未就绪则静默，下次关注变化补上）
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                TradingStore.reportWatchlist(context: modelContext,
                                             profileId: profileManager?.currentProfile.id ?? "")
            }
            #endif
            #if os(macOS)
            // 思考链 hook 自检安装（幂等；没配 CC 桥时直接返回）
            DispatchQueue.global(qos: .utility).async { CCThinkingHookInstaller.ensureInstalled() }
            // 内嵌 hub：「启动 hub」开关开着就随 App 拉起（这台 Mac 已有外部 hub 时不起），退出时停（#046）
            CCHubProcess.shared.autoStartAtLaunch()
            #endif
            // 冷启动从推送点进来：didReceive 可能早于 onAppear 把 chatId 写进 UserDefaults，延迟消费一次
            #if os(iOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { consumePendingPushTarget() }
            // 推送 NSE 索引：启动期一次性全量 dump 最近 N 个 cc-bridge 会话给 NSE 用
            // （fetch 在主 context 上；writer 内部 dispatch 到 serial queue 走文件 IO，不阻塞 UI）
            PushIdentityWriter.rebuildFromContext(modelContext)
            #endif
            manager.syncSystemColorScheme(colorScheme)
            #if os(iOS)
            let top = screenSafeAreaTop
            if top > 0 { topSafeAreaInset = top }

            #if DEBUG || PERF_BENCH
            uiTestAutoOpen()
            #endif
            #if DEBUG
            // [PROBE 键盘] 自动选中键盘避让 probe conversation（KeyboardLatestVisibleUITests 用）
            if KeyboardProbeSeed.shouldAutoSelectProbeConv {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let descriptor = FetchDescriptor<Conversation>(
                        predicate: #Predicate { $0.id == "probe-kb-conv-1" }
                    )
                    if let conv = try? modelContext.fetch(descriptor).first {
                        // 走真实点击同路径（loadConversation 才加载 currentPath，光设 selected 列表不渲染）
                        viewModel.loadConversation(conv, context: modelContext)
                        PROBE("[PROBE 键盘 ContentView.onAppear] loaded conv id=\(conv.id)")
                    } else {
                        PROBE("[PROBE 键盘 ContentView.onAppear] probe conv NOT FOUND")
                    }
                }
            }
            // [PERF bench] L1：自动选中基准对话并武装连滚采样（--perf-bench）。
            // 延 3s：0.3s 档实测被「恢复上次对话」流程覆盖（path check 落在 kb 对话 44 条）。
            if PerfBenchSeed.isActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let benchId = PerfBenchSeed.convId
                    let descriptor = FetchDescriptor<Conversation>(
                        predicate: #Predicate { $0.id == benchId }
                    )
                    if let conv = try? modelContext.fetch(descriptor).first {
                        viewModel.loadConversation(conv, context: modelContext)
                        ChatPerfBench.startWhenReady()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                            let path = viewModel.currentPath
                            let lastId = path.last?.id ?? "-"
                            let lastChildren = path.last?.childrenIds ?? []
                            KBProbe.log("[PERFBENCH] path check: currentPath=\(path.count) loading=\(viewModel.isLoading) first=\(path.first?.id ?? "-") last=\(lastId) lastChildren=\(lastChildren)")
                        }
                    } else {
                        KBProbe.log("[PERFBENCH] bench conv NOT FOUND in store")
                    }
                }
            }
            #endif
            #endif
        }
        .onChange(of: colorScheme) { _, newScheme in
            manager.syncSystemColorScheme(newScheme)
        }
        #if os(macOS)
        .toolbarBackground(.hidden, for: .windowToolbar)
        // B1 顶部白条：macOS 26 给滚到透明标题栏下的滚动区自动挂 NSScrollPocket
        // （scroll edge effect），其 LuminanceAdjustment 在奶白主题上渲染成一条
        // 不透明白带（lldb X 光实锤：NSView 952×80 bg=(1,1)）。整棵层级关掉。
        .hideTopScrollEdgeEffect()
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .memoryPalaceRequestImport)) { _ in
            showImporter = true
        }
        .sheet(isPresented: $showImporter) {
            ImportView()
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(Theme.sidebarBg)
                #endif
        }
        #if os(iOS)
        // mac 的设置是独立 Settings 窗口（A5），不再走 sheet；SidebarView 的 showSettings binding 在 mac 上不会被置 true
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.clear)
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .feedbackGestureTriggered)) { _ in
            presentFeedback()
        }
        .sheet(item: $feedbackPayload) { payload in
            FeedbackSheet(payload: payload)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationBackground(Theme.mainBg)
                #endif
        }
    }

    /// 摇一摇（iOS）/ ⌘⇧D（macOS）→ 先截图（所见即所得）再弹反馈面板。
    /// 已有面板开着 / 开关关闭时忽略。上架版不带对话标题/楼层名/消息内容。
    private func presentFeedback() {
        guard feedbackGestureEnabled, feedbackPayload == nil else { return }
        let shot = FeedbackStore.captureScreenshot()
        var ctx = FeedbackStore.Context()
        #if os(iOS)
        let pageNames = ["列表", "聊天", "更多"]
        ctx.pageDescription = "iOS page \(iOSPage)（\(pageNames[min(max(iOSPage, 0), 2)])）"
        #else
        ctx.pageDescription = "macOS 主窗口"
        #endif
        feedbackPayload = FeedbackPayload(screenshot: shot, context: ctx)
    }

    @Environment(\.scenePhase) private var scenePhase

    private func activateAgoraIfNeeded() async {
        guard AgoraFeatureGate.isEnabled else { return }
        let floorId = profileManager?.currentProfile.id ?? ""
        if !floorId.isEmpty { await agoraViewModel.activate(floorId: floorId) }
    }

    private func showNormalChat() {
        destination = .chat
        agoraViewModel.closeRoom()
    }

    /// ⌘N 新建对话（S1-4）。`startDraftConversation` 自带幂等——已经停在同楼层的空草稿上就直接 return，
    /// 所以连按 ⌘N 不会攒出一堆空对话。
    /// **不聚焦输入框**：主聊天输入框没有全局聚焦入口，接它要动 CardFlowView 的焦点管线（IME 那套），不在这一刀里。
    private func handleNewConversationRequest() {
        guard let pid = profileManager?.currentProfile.id, !pid.isEmpty else { return }
        showNormalChat()
        viewModel.startDraftConversation(profileId: pid)
        #if os(iOS)
        if iOSPage != 1 { withAnimation { iOSPage = 1 } }
        #endif
    }

    private func selectAgoraRoom(_ roomId: String) {
        destination = .agoraRoom
        Task { await agoraViewModel.openRoom(id: roomId) }
        #if os(iOS)
        withAnimation { iOSPage = 1 }
        #endif
    }

    private func showAgoraRoomPage() {
        destination = .agoraRoom
        #if os(iOS)
        withAnimation { iOSPage = 1 }
        #endif
    }

    // MARK: - iOS Three-Screen Layout (ScrollView horizontal paging)
    #if os(iOS)
    private var iOSLayout: some View {
        let manager = themeManager ?? ThemeManager.shared
        let scheme = manager.activeScheme
        let style = manager.currentBackgroundStyle
        // Wallpaper 走 UIKit 层（PagingViewController.view 底层 UIImageView + CAGradientLayer），
        // 不用 SwiftUI `.background`——A10 实测 SwiftUI .background content frame 响应
        // keyboard safeArea 等比放大 13%，导致"背景跟着键盘动"。
        // 见 docs/research-wallpaper-uikit-layer.md + docs/plan-wallpaper-uikit-layer.md。
        let wallpaperConfig = WallpaperConfig(
            fill: Theme.mainBg,
            imageURL: manager.currentBackgroundImageURL,
            saturation: 1.0,   // M2：不再偷偷降饱和；==1 时 applyWallpaper 直接跳过 CIFilter
            opacity: style.resolvedOpacity(for: scheme),
            offsetX: style.resolvedOffsetX,
            offsetY: style.resolvedOffsetY,
            gradientColors: wallpaperGradientColors(for: scheme, veil: style.resolvedVeil)
        )
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let _ = { if LaunchTrace.enabled {
            LaunchTrace.page2Target = selectedToolId
            LaunchTrace.appearance = ["font": UserDefaults.standard.string(forKey: "selectedFont") ?? "",
                "fontScale": UserDefaults.standard.double(forKey: "fontScale") > 0 ? UserDefaults.standard.double(forKey: "fontScale") : 1.2,
                "theme": manager.selectedThemeId, "scheme": String(describing: scheme),
                "backgroundOpacity": wallpaperConfig.opacity, "chatBubbleMode": chatBubbleMode,
                "page2Presentation": homePresentation, "page2DesktopStyle": page2DesktopStyle]
        } }()
        #endif
        // 路线 B 下 container 不变，外层 App.body 的 .id(profile.id) 已经保证 profile
        // 切换时整棵 ContentView re-init，PagingContainerView 自动跟着新建。不需要这里
        // 额外 .id() hack。
        let paging = PagingContainerView(
            // 宽屏形态下列表/更多改由浮层承载，这两页喂 EmptyView——三页结构本身保留
            // （输入条挂 hostingControllers[1] 且要求 count>1，减页会让挂载链失效），
            // 但内容不重复渲染。updatePages 只换 rootView 不重建 HC，来回切安全。
            listPage: isWidePanelMode ? AnyView(EmptyView()) : AnyView(injectPagingEnv(iOSListPage)),
            chatPage: AnyView(injectPagingEnv(iOSChatPage)),
            dashPage: isWidePanelMode ? AnyView(EmptyView()) : AnyView(injectPagingEnv(iOSDashboardPage)),
            // B2：输入条栈独立 host（挂 chat HC + keyboardLayoutGuide），环境注入同 page 双层链
            inputBar: AnyView(injectPagingEnv(InputBarStack(stickerVM: stickerVM))),
            // 翻页解耦（plan-paging-decouple §3.2）：iOSPage 只由 PageSync 读；开关关时回原 binding 链（body 读 iOSPage）
            currentPage: PagingSwitch.pageSync ? nil : iOSPage,
            onPageChanged: { iOSPage = $0 },
            contentKey: PagingContentKey(conversation: viewModel.selectedConversation?.id, destination: String(describing: destination),
                                         profile: profileManager?.currentProfile.id ?? "", wide: isWidePanelMode,
                                         theme: manager.themeChangeID.uuidString, stickers: stickerVM.isEditingStickers),
            disableScroll: stickerVM.isEditingStickers,
            widePanelMode: isWidePanelMode,
            initialPage: ProcessInfo.processInfo.arguments.contains("page2-ui-test") ? 2 : 1,
            launchProfile: profileManager?.currentProfile.id ?? "",
            launchRequired: !isWidePanelMode && !showOnboarding && !ProcessInfo.processInfo.arguments.contains("page2-ui-test"),
            launchChatReady: { [weak viewModel, weak profileManager, launchConversationID = viewModel.selectedConversation?.id] in
                guard let vm = viewModel, let conversation = vm.selectedConversation,
                      conversation.id == launchConversationID else { return false }
                return !vm.isLoading && conversation.profileId == profileManager?.currentProfile.id
                    && UserDefaults.standard.string(forKey: "pendingPushChatId") == nil
            },
            wallpaper: isWidePanelMode ? .cleared : wallpaperConfig,
            // B2 窄版：流式期间 skip updatePages。读 isStreaming 会让 ContentView.body
            // 在流式开始/结束各重算一次（边界时刻触发更新 rootView），非流式期间无成本。
            isStreaming: destination == .chat && viewModel.providerRouter.isStreaming
        )
        .ignoresSafeArea()
        // 宽屏下正文让位：翻页容器按桌面格子 / 面板宽度内缩（输入条挂 chat HC，跟着缩）。
        // content 传**值**不传闭包——拖宽度时只有 DockedInsetHost 重算，翻页容器的值原样透传。
        return ZStack {
            if isWidePanelMode {
                WallpaperBackdrop(config: wallpaperConfig).ignoresSafeArea()
            }
            DockedInsetHost(layout: panelLayout, active: isWidePanelMode,
                            availableSize: widePanelAvailableSize, content: paging)
        }
        // iOSPage 的唯一读者：音乐胶囊 + 触感 + 翻页副作用 + 翻页命令（plan-paging-decouple §3.2，PageSync.swift）
        .overlay(alignment: .top) {
            PageSync(page: $iOSPage, suppressEffects: $suppressPageEffects, isChatDestination: destination == .chat,
                     isWidePanelMode: isWidePanelMode, musicCapsuleEnabled: globalMusicCapsuleEnabled, viewModel: viewModel)
        }
        // 形态判据取**可用宽度**不取设备型号：Split View / Stage Manager 缩窗时
        // 自动退回三页横滑，不需要额外分支（research-ipad §1.3）。量的是内缩前的整块。
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // 这层的高度是桌面格子的行数依据，**键盘期不能跟着掉**：09-06 探针实测点进输入框
            // 782→374，格子 4 行掉到 1 行、桌面组件当场消失（`.ignoresSafeArea(.keyboard)`
            // 拦不住——这层是被压矮，不是被 inset）。
            // 「变矮一大截」延后一拍再认：那时 `keyboardWillShow` 必已到，键盘引起的忽略掉，
            // 真的缩窗（Stage Manager）照收。变高、变宽一律立刻认。
            if size.width == widePanelAvailableSize.width,
               size.height < widePanelAvailableSize.height - 100 {
                DispatchQueue.main.async {
                    guard !isKeyboardVisible else { return }
                    widePanelAvailableSize = size
                    panelLayout.screenSize = UIScreen.main.bounds.size
                }
                return
            }
            widePanelAvailableSize = size
            #if DEBUG
            // research-ipad-desktop-bugs §2.4 探针：键盘起落时这个数变不变（变 = 这层吃了键盘 safe area）
            print("[PROBE ipad] availableSize=\(Int(size.width))x\(Int(size.height))")
            #endif
            // 桌面格子按机器的屏幕档取尺寸（Split View 缩窗不换档）
            panelLayout.screenSize = UIScreen.main.bounds.size
            let wide = size.width >= Theme.landscapePanelThreshold
            guard wide != isWidePanelMode else { return }
            suppressPageEffects = true
            // 降级 / 升级都走一条 spring：面板和桌面淡出淡入、正文的让位 padding 跟着收放，
            // 不再是一帧硬切。`iOSPage` 的归位留在事务外，别把翻页也带着动
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { isWidePanelMode = wide }
            // 归位到聊天页；副作用被上面那行静音。面板开关在 panelLayout 里持久化，转屏不改
            if wide { iOSPage = 1 }
            DispatchQueue.main.async { suppressPageEffects = false }
        }
        .fullScreenCover(isPresented: $showOnboarding) { OnboardingFlowView() }
        .onChange(of: stickerVM.isEditingStickers) { _, editing in
            setStickerEditScrollLock(editing)
        }
        .modifier(Page2AppShellPersistence(encoded: $page2OpenApps, readingBook: $page2ReadingBook, current: selectedToolId))
        .onChange(of: globalWBManager?.books.count) { _, _ in
            viewModel.globalWorldBookEntries = (globalWBManager?.enabledBooks ?? []).flatMap { $0.entries }
        }
        .onAppear {
            viewModel.globalWorldBookEntries = (globalWBManager?.enabledBooks ?? []).flatMap { $0.entries }
            // 首屏焦点上报（直接进对话页的情况）；连接没好时由 didOpen 重报兜底
            CCBridgeWebSocketClient.shared.updateFocus(
                iOSPage == 1 && destination == .chat ? viewModel.selectedConversation?.id : nil
            )
        }
        .onChange(of: viewModel.selectedConversation?.id) { _, newId in
            if newId != nil && iOSPage == 0 {
                withAnimation { iOSPage = 1 }
            }
            // 同页换会话也要重报焦点（切到 page 1 由上面 iOSPage onChange 兜）
            CCBridgeWebSocketClient.shared.updateFocus(iOSPage == 1 && destination == .chat ? newId : nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationNavigationRequested)) { _ in
            // B20 part 2: 同 conv 内点搜索结果时 selectedConversation?.id 不变，
            // 上面那条 onChange 不触发，靠这条通知补 page 切换。
            showNormalChat()
            if iOSPage != 1 {
                withAnimation { iOSPage = 1 }
            }
        }
        // ⌘N「新建对话」（S1-4）。**必须走 `OnNotify` 这个独立 modifier，不能直接写 `.onReceive`**——
        // body 这条 modifier 链已经贴着类型检查预算，再加一个 `NotificationCenter.default.publisher(for:)`
        // 的泛型就翻（iOS 侧实测 "unable to type-check this expression in reasonable time"；
        // 把闭包体抽成方法**不够**，压垮它的是链上多一项 Publisher 泛型，不是闭包复杂度）。
        .modifier(OnNotify(.newConversationRequested) { handleNewConversationRequest() })
        .onReceive(NotificationCenter.default.publisher(for: .pushConversationRequested)) { _ in
            consumePendingPushTarget()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .task(id: profileManager?.currentProfile.id ?? "") {
            await activateAgoraIfNeeded()
        }
        .onChange(of: destination) { _, dest in
            #if os(iOS)
            // 中庭房间页有自己的 composer，抑制常驻聊天输入条（双输入框叠层的修复）
            KeyboardInsetBridge.shared.chatInputSuppressed = (dest == .agoraRoom)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // 切后台 socket 死 → 回前台立即重连（不等 30s 退避）——07-19 群聊全哑修复的一半
            if phase == .active, AgoraFeatureGate.isEnabled { agoraViewModel.nudgeReconnectIfNeeded() }
        }
        .sheet(isPresented: $showAgoraCreateSheet) {
            AgoraRoomCreateSheet(
                viewModel: agoraViewModel,
                initialOwnerDisplayName: profileManager?.currentProfile.userName ?? "你",
                onCreated: { showAgoraRoomPage() }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    /// 点击 APNs 推送后打开对应会话：读 pendingPushChatId → PushTargetResolver 全库解析
    /// → 同楼层直接跳、异楼层先切楼层、terminal 失败给可见反馈。
    ///
    /// 洞 7：修前是「先删 key → 按当前楼层 scoped fetch → 查不到静默 return」三步叠加，
    /// 推送落在别的楼层时点了什么都不发生、key 还没了。现在 **pending key 只在成功导航或
    /// 明确 terminal failure 之后才消费**，可恢复的失败（数据库没就绪 / 切楼层途中）保留。
    private func consumePendingPushTarget() {
        #if os(iOS)
        if consumeNativeCallTarget() { return }
        #endif
        #if DEBUG && os(iOS)
        // 冒烟/基准启动不吃推送落点：simctl terminate 强杀让通知 response 永不确认，
        // 系统每次冷启动重投 → 写 key → 把 seed 刚切入的测试楼层劫回去（09-09 面包屑实锤）
        if StreamSmokeSeed.isActive || PerfBenchSeed.isActive { return }
        #endif
        #if (DEBUG || PERF_BENCH) && os(iOS)
        // perf-flash 各角色（测量 / 被动 / 补种 / 收尾）同理不吃推送落点，Release+PERF 包也要拦（astra R2 M2）
        if PerfHarness.anyRole { return }
        #endif
        guard let chatId = UserDefaults.standard.string(forKey: "pendingPushChatId"), !chatId.isEmpty else { return }
        let resolution = PushTargetResolver.resolve(
            chatId: chatId,
            currentProfileId: profileManager?.currentProfile.id ?? "",
            knownProfileIds: Set(profileManager?.profiles.map(\.id) ?? []),
            in: modelContext
        )
        switch resolution {
        case .navigate(let convId, let nodeId):
            let pid = profileManager?.currentProfile.id ?? ""
            let desc = FetchDescriptor<Conversation>(
                predicate: #Predicate<Conversation> { $0.id == convId && $0.profileId == pid }
            )
            guard let conv = try? modelContext.fetch(desc).first else {
                BreadcrumbLog.shared.add("🔔", "推送落点这一刻取不到 conv=\(convId.prefix(8))，保留待跳转")
                return   // 可恢复：key 留着，下次消费再试
            }
            UserDefaults.standard.removeObject(forKey: "pendingPushChatId")
            showNormalChat()
            viewModel.navigateToSearchResult(nodeId: nodeId, conversation: conv, context: modelContext)

        case .switchProfile(let profileId, let convId):
            guard let manager = profileManager,
                  let target = manager.profiles.first(where: { $0.id == profileId }) else {
                UserDefaults.standard.removeObject(forKey: "pendingPushChatId")
                BreadcrumbLog.shared.add("🔔", "推送对话所在楼层已删除 conv=\(convId.prefix(8))")
                viewModel.transientNotice = TransientNotice("这条消息所在的楼层已经不在了")
                return
            }
            // key 不消费：switchTo 会同步广播清旧 SwiftData 引用再翻 currentProfile，
            // App.body 的 .id(currentProfile.id) 随即重建整棵 ContentView subtree——
            // 拿现在这份 context 导航是无效的。让新 subtree 的 onAppear 再消费一次，
            // 那时解析结果就是 .navigate。
            BreadcrumbLog.shared.add("🔔", "推送落在别的楼层，切到 \(target.name) 再跳 conv=\(convId.prefix(8))")
            manager.switchTo(target)

        case .conversationMissing:
            UserDefaults.standard.removeObject(forKey: "pendingPushChatId")
            BreadcrumbLog.shared.add("🔔", "推送对话已不存在 chat=\(chatId.prefix(8))")
            viewModel.transientNotice = TransientNotice("这条消息对应的对话已经被删除了")

        case .profileMissing(let profileId):
            UserDefaults.standard.removeObject(forKey: "pendingPushChatId")
            BreadcrumbLog.shared.add("🔔", "推送对话所在楼层已删除 pid=\(profileId.prefix(8))")
            viewModel.transientNotice = TransientNotice("这条消息所在的楼层已经不在了")

        case .conversationEmpty(let convId):
            UserDefaults.standard.removeObject(forKey: "pendingPushChatId")
            BreadcrumbLog.shared.add("🔔", "推送对话还没有可跳转的消息 conv=\(convId.prefix(8))")
            viewModel.transientNotice = TransientNotice("这个对话还没有消息可以打开")

        case .unavailable:
            BreadcrumbLog.shared.add("🔔", "推送落点暂时查不了（数据库未就绪），保留待跳转")
        }
    }

    #if os(iOS)
    /// 接听后的冷/热启动都按本机对话归属切楼层，空对话也能接听。
    private func consumeNativeCallTarget() -> Bool {
        let coordinator = NativeCallCoordinator.shared
        guard coordinator.readyToPresent, let call = coordinator.current else { return false }
        let id = call.chat_id
        do {
            let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
            guard let conversation = try modelContext.fetch(descriptor).first,
                  let manager = profileManager,
                  let profile = manager.profiles.first(where: { $0.id == conversation.profileId }) else {
                coordinator.fail("来电对应的对话或楼层已经删除"); return true
            }
            if manager.currentProfile.id != profile.id {
                manager.switchTo(profile); return true
            }
            showNormalChat()
            viewModel.loadConversation(conversation, context: modelContext)
            iOSPage = 1
            CallController.shared.retryNative()
        } catch { coordinator.fail("无法读取来电对话") }
        return true
    }
    #endif

    /// UIViewControllerRepresentable 包的 UIHostingController 不自动继承 SwiftUI parent env，
    /// 显式把低频 env（modelContext / themeManager / globalWBManager）注入给每页。
    /// ProviderManager / ProfileManager / PresetManager 的注入**移到 PagingContainerView**
    /// 完成，避免 ContentView 订阅这 3 个 @Observable Manager 引起 body 全量重算。
    @ViewBuilder
    private func injectPagingEnv<V: View>(_ page: V) -> some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let auditedPage = page.modifier(LaunchEnvironmentAudit())
        let _ = LaunchTrace.event("environmentOuter", fields: ["modelContext": LaunchTrace.identity(modelContext),
            "themeManager": LaunchTrace.identity(themeManager ?? ThemeManager.shared),
            "worldBookManager": LaunchTrace.identity(globalWBManager),
            "rightPanelToolManager": LaunchTrace.identity(rightPanelToolManager),
            "profile": profileManager?.currentProfile.id ?? "missing"])
        #else
        let auditedPage = page
        #endif
        let manager = themeManager ?? ThemeManager.shared
        if let wb = globalWBManager {
            auditedPage
                .environment(\.modelContext, modelContext)
                .environment(manager)
                .environment(wb)
                .environment(viewModel)   // M3-B：读书 sheet 需要拿 vm 调 sendMessage
        } else {
            auditedPage
                .environment(\.modelContext, modelContext)
                .environment(manager)
                .environment(viewModel)
        }
    }

    /// Wallpaper overlay gradient 颜色（与 ThemeBackgroundView.overlayColors 同一组系数），
    /// 按 colorScheme 区分明暗主题。SwiftUI ColorScheme → UIColor[]（UIKit 层消费）。
    /// `veil` = ThemeBackgroundStyle.resolvedVeil：1 是改动前的强度，0 不盖（M2）。
    private func wallpaperGradientColors(for scheme: ColorScheme, veil: Double) -> [UIColor] {
        if scheme == .dark {
            return [
                UIColor.black.withAlphaComponent(0.42 * veil),
                UIColor.black.withAlphaComponent(0.18 * veil),
                UIColor.black.withAlphaComponent(0.50 * veil)
            ]
        }
        return [
            UIColor.white.withAlphaComponent(0.18 * veil),
            UIColor.white.withAlphaComponent(0.04 * veil),
            UIColor.white.withAlphaComponent(0.24 * veil)
        ]
    }

    // MARK: - iOS Page indicator (debug-mode aware)

    private var screenSafeAreaTop: CGFloat {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return 0 }
        return window.safeAreaInsets.top
    }

    // pageIndicatorInZStack(proxy:) 已删除 — dead code（无 call site）。
    // 同 删 @AppStorage debugPageIndicatorModeRaw / private var debugPageIndicatorMode。

    @State private var showAIProfile = false

    /// 气泡模式顶栏中央：大圆头像悬浮 + 底下贴一个紧身名字小胶囊（X chat 式上下结构）。
    /// 气泡模式不挂 PinBar（pin 单气泡是普通模式的事），这个替位。
    /// 头像素材 fallback：自选头像 → 角色卡封面 → 人像图标。
    private var bubbleModeAvatarCapsule: some View {
        AvatarNameCapsule(name: profileManager?.currentProfile.assistantName ?? "助手") {
            Group {
                // 自选头像和角色卡封面优先，未设置时显示人像图标。
                if let data = profileManager?.currentProfile.assistantAvatarData,
                   let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(Circle())
                } else if let data = profileManager?.currentProfile.coverImageData,
                   let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Theme.accent.opacity(0.6)))
                }
            }
        }
    }

    #endif

    // MARK: - 宽屏壳共用（iPad 宽屏 overlay 与 mac 新壳都用；plan-mac-shape A1a 提出 #if）

    /// 设置入口：mac 开独立设置窗口（⌘, 同一扇），iOS 开 sheet
    private func openSettingsEntry() {
        #if os(macOS)
        openSettings()
        #else
        showSettings = true
        #endif
    }

    /// 浮窗模式下选中对话后收起左面板（它盖着正文；粟粟上轮裁「收」）；全屏模式它是侧栏，不收
    private func collapseLeftPanelAfterSelect() {
        guard panelLayout.mode == .floating else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { panelLayout.leftShown = false }
    }

    /// 顶部悬浮条的左右钮在宽屏下：左 = 开关左面板，右 = 开关整条竖 dock（dock 收了卡片一起收）。
    /// 窄屏仍是翻页。
    private func toggleLeftPanel() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { panelLayout.leftShown.toggle() }
    }

    private func toggleDock() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            panelLayout.dockShown.toggle()
            #if os(macOS)
            // 停靠壳里这颗只管工具面板（dock 条恒在）：开的时候一个 tab 都没有就把上次选的工具开回来，
            // 不然点了没反应——她 09-17 报「打开右栏 dock 反而收起」就是全关状态下点它把 dock 一起收了
            if panelLayout.mode == .docked, panelLayout.dockShown, !panelLayout.macToolShown {
                panelLayout.open(panelLayout.selectedTool ?? "home")
            }
            #endif
        }
    }

    /// 外部入口（搜索结果 / 通知）要打开某个工具。调用点两端统一，**函数体保留平台叉**（astra F3）：
    /// iOS 宽屏 → 开它的 tab（页 2 是 EmptyView 且禁滑，`iOSPage = 2` 在这形态下是死的）；iOS 窄屏 → 翻到页 2；
    /// mac → 只有宽屏壳，开 dock + tab
    /// 卡墙切楼层会重建 ContentView：重建后打开卡库中的角色页
    private func consumeCardLibraryReturn() {
        guard let profileId = rightPanelNavigator?.cardLibraryReturnProfileId,
              profileId == profileManager?.currentProfile.id else { return }
        rightPanelNavigator?.cardLibraryReturnProfileId = nil
        openToolFromOutside("cardLibrary")
    }

    #if PERSONAL_APPS
    /// 死亡天平暗号（plan-death-scale §4.2）：启用 + 给当前楼层（输暗号的那层）开读 + 上桌 / 上 Dock + 打开。
    /// 走 OnNotify：body 链贴着类型检查预算，见上面 ⌘N 那条注释
    private func unlockDeathScale() {
        DeathScaleGate.unlock(profileId: profileManager?.currentProfile.id, tools: rightPanelToolManager)
        withAnimation(.easeInOut(duration: 0.2)) { openToolFromOutside(DeathScaleGate.toolId) }
    }
    #endif

    private func openToolFromOutside(_ id: String) {
        #if os(iOS)
        selectedToolId = id
        if isWidePanelMode {
            panelLayout.dockShown = true
            panelLayout.open(id)
        } else {
            iOSPage = 2
        }
        #else
        panelLayout.dockShown = true
        panelLayout.open(id)
        #endif
    }

    #if os(macOS)
    /// 顶部悬浮条那颗放得下的标题。胶囊是按内容撑开的，`.frame(maxWidth:)` **压不住**固有宽度超标的 Text
    /// （见 feedback「maxWidth 不 clamp 超宽内容」），长标题会把「工具」和齿轮一起顶出窗口
    ///（09-16 她实拍：一条 `<channel source=…>` 当标题的会话把整条胶囊撑出屏）。
    /// 所以先在字符串层面截断；按显示宽度算而不是按字数——一个汉字约等于两个字母宽。
    /// 预算 24 是这么来的：胶囊给这颗 220pt，扣掉图标 13 + 箭头 13 + 两道间距 12 ≈ 182pt 归文字；
    /// 13pt medium 下字母约 7.3pt、汉字 13pt → 24 个字母 ≈ 175pt / 12 个汉字 ≈ 156pt，都塞得下
    static func capsuleTitle(_ raw: String, budget: Int = 24) -> String {
        var used = 0
        var kept = ""
        for ch in raw {
            let w = ch.isASCII ? 1 : 2
            if used + w > budget { return kept + "…" }
            used += w
            kept.append(ch)
        }
        return kept
    }

    /// code 组激活时悬浮条中间那颗的标题 = 当前这条编程会话的标题
    private var codingSessionTitle: String {
        guard case .loaded(let box) = CodingSessionLibrary.shared.detail else { return "编程会话" }
        return CodingSessionFormat.title(box.transcript.meta)
    }

    /// 编程会话卡：原来摊在详情页顶上的那块摘要收到这儿（她 09-16 圈掉了它），外加改名 / 路径动作 / 回聊天的出口。
    /// 09-25 从 `Menu` 换成挂在标题上的 popover（学 Otty，正对标题居中；plan-mac-code-mode-gaps §3）
    @ViewBuilder
    private var codingSessionCard: some View {
        if case .loaded(let box) = CodingSessionLibrary.shared.detail {
            CodingSessionTitleCard(meta: box.transcript.meta,
                                   backTitle: viewModel.selectedConversation.map { "回到「\($0.title)」" } ?? "回到聊天") {
                showCodingCard = false
                CodingSessionLibrary.shared.deactivate()
            }
        }
    }
    #endif

    /// 对话操作菜单项。窄屏挂在 ⋯ 上，宽屏挂在悬浮条的标题上——两种形态共用一份，不会漂。
    @ViewBuilder
    private var conversationMenuItems: some View {
        if let conv = viewModel.selectedConversation {
            Section { Text(conv.title) }
            #if os(iOS)
            Button {
                // 输入栏要被查找面板顶替：先把没打完的拼音定稿进草稿（同 InputBarStack 切对话）
                ChatInputHandle.shared.finalizeCompositionAndCommit()
                viewModel.beginInConvSearch()
            } label: { Label("在对话中查找", systemImage: "magnifyingglass") }
            #endif
            Button { showChangeProjectSheet = true } label: { Label("移到文件夹", systemImage: "folder") }
            Button { FavoriteTags.setFavorite(conv, !conv.isFavorite) } label: {
                Label(conv.isFavorite ? "取消收藏" : "收藏",
                      systemImage: conv.isFavorite ? "star.slash" : "star")
            }
            Button {
                renameText = conv.title
                showRenameAlert = true
            } label: { Label("重命名", systemImage: "pencil") }
            // 一直显示：菜单内容会被提前算，判断「有没有」就要在主线程读 sessions/（撞主线程读盘预算），没有时弹层里说
            Button {
                memorySheet = ConversationMemorySheetTarget(kind: .windowSummary, conversationId: conv.id,
                                                            profileId: conv.profileId, title: conv.title)
            } label: { Label("窗口总结", systemImage: "rectangle.stack") }
            Button {
                memorySheet = ConversationMemorySheetTarget(kind: .contextSummary, conversationId: conv.id,
                                                            profileId: conv.profileId, title: conv.title)
            } label: { Label("上下文摘要", systemImage: "text.append") }
            // 卡库 ③-4：这个对话用哪个身份（身份库空时不出现）；写 Conversation.personaId，优先于楼层身份
            if !UserPersonaStore.shared.personas.isEmpty {
                Menu {
                    Button {
                        conv.personaId = nil
                        try? modelContext.save()
                    } label: {
                        Label("跟随楼层", systemImage: (conv.personaId ?? "").isEmpty ? "checkmark" : "person.crop.circle")
                    }
                    ForEach(UserPersonaStore.shared.personas) { persona in
                        Button {
                            conv.personaId = persona.id
                            try? modelContext.save()
                        } label: {
                            Label(persona.name.isEmpty ? "（没名字）" : persona.name,
                                  systemImage: conv.personaId == persona.id ? "checkmark" : "person")
                        }
                    }
                } label: { Label("这个对话用的身份", systemImage: "person.crop.circle") }
            }
            // 带不带终端：按 tmux session 设（从对话列表长按挪来，粟粟 10-11）。切换后 hub 收掉旧进程按新传输重生
            //（同一 claude 会话 resume，正在跑的一轮等跑完）
            if let ccSession = conv.ccBridgeSessionName, !ccSession.isEmpty {
                let current = CCBridgeWebSocketClient.transportPolicy(for: ccSession)
                Menu {
                    ForEach([("", "跟随全局设置", "gearshape"), ("tmux", "带终端", "terminal"),
                             ("stream", "不带终端（逐字流式）", "text.bubble")], id: \.0) { policy, title, icon in
                        Button {
                            CCBridgeWebSocketClient.setTransportPolicy(policy, for: ccSession)
                        } label: {
                            Label(title, systemImage: current == policy ? "checkmark" : icon)
                        }
                    }
                } label: { Label("终端 · \(ccSession)", systemImage: "terminal") }
            }
            Divider()
            Button(role: .destructive) {
                viewModel.softDeleteConversation(conv)
            } label: { Label("删除", systemImage: "trash") }
        }
    }

    /// 宽屏顶部悬浮条（⧫5 粟粟：「不是说了有一个悬浮条吗」，参考 Silo 顶部那排胶囊）：
    /// 把窄屏下被 Spacer 撑到两端的控件收拢成居中一条。左右两端的按钮直接召浮层。
    @ViewBuilder
    private var landscapeTopBar: some View {
        #if os(macOS)
        // mac 只有浮窗模式用这条胶囊；停靠模式的标题行是 `macDockedTree` 的第一行（`macTitleBarRow`），不经过这里。
        // `#if` 包整支、property 不拆成两个——拆了会把 iOS 的宽屏顶栏一起带走（R-FS I3）
        landscapeCapsule
        #else
        landscapeCapsule
        #endif
    }

    #if os(macOS)
    /// 全屏（停靠）模式的标题栏那一行：**对话名居卡、列表钮贴着红绿灯、工具钮贴右缘、中间空域不放东西**
    ///（她 09-17：「左栏右栏设置那三个按钮不要挤在一坨，左栏放左边顶上右栏放右边顶上」）。
    /// 学 Otty 的构成（她 09-16：「我说了学这个 otty 你怎么就不明白呢」）——没有底色、没有描边，它就坐在桌布上。
    /// 它是 `macDockedTree` 的第一行，整棵树越过顶部安全区，所以这一行从窗顶 y 0 起、红绿灯浮在它左边
    /// （v1 也这么写但没越安全区，实际从 32.5 起——09-17 实拍抓的）。
    /// 标题居**卡**（她裁 ⧫3）：卡槽框由 `IPadPanelOverlay` 上报（`macCardFrame`，工作区坐标 = 窗口 x），还没量到就居窗
    private var macTitleBarRow: some View {
        let m = MacShellMetrics.shared
        let card = panelLayout.macCardFrame
        return ZStack(alignment: .leading) {
            // 空处能拖窗：行背景接窗口拖动手势（macOS 15+）——越过安全区之后系统标题栏不再替我们接（R-FS2 Q6 / plan R2）
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            if card.width > 0 {
                macTitleMenu
                    .frame(width: card.width)
                    .offset(x: card.minX)
            } else {
                macTitleMenu
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: m.iconButtonGap) {
                // 给红绿灯让位（量出来的，`MacWindowChrome`）
                Spacer().frame(width: max(0, MacWindowChrome.shared.trafficLightInset - m.titleBarPadX))
                Button(action: toggleLeftPanel) {
                    macTitleIcon("sidebar.leading")
                }
                .buttonStyle(MacShellButton(selected: panelLayout.leftShown, width: m.titleButtonSide, height: m.titleButtonSide))
                .help("显示或隐藏对话列表")
                Spacer()
                Button(action: focusMacSearch) { macTitleIcon("magnifyingglass") }
                    .buttonStyle(MacShellButton(width: m.titleButtonSide, height: m.titleButtonSide))
                    .help("全局搜索（⌘K）")
                    .accessibilityLabel("全局搜索")
                if !chatBubbleMode, branchOffMainCount > 0 {
                    Button { showBranchMap = true } label: {
                        macTitleIcon("ri-git-branch")
                    }
                    .buttonStyle(MacShellButton(width: m.titleButtonSide, height: m.titleButtonSide))
                    .help("查看对话分支（\(branchOffMainCount)）")
                }
                Button { openSettingsEntry() } label: {
                    macTitleIcon("gearshape")
                }
                .buttonStyle(MacShellButton(width: m.titleButtonSide, height: m.titleButtonSide))
                .help("设置（⌘,）")
                .accessibilityLabel("设置")
                Button(action: toggleDock) {
                    macTitleIcon("sidebar.trailing")
                }
                .buttonStyle(MacShellButton(selected: panelLayout.dockShown, width: m.titleButtonSide, height: m.titleButtonSide))
                .help("显示或隐藏工具面板")
            }
            .padding(.horizontal, m.titleBarPadX)
        }
        .frame(maxWidth: .infinity)
        .frame(height: m.titleBarHeight)
    }

    @ViewBuilder
    private func macTitleIcon(_ symbol: String) -> some View {
        if AppIconView.isAssetName(symbol) {
            AppIconView(name: symbol, size: MacShellMetrics.shared.titleIconSize, tint: nil)
        } else {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: MacShellMetrics.shared.titleIconSize, height: MacShellMetrics.shared.titleIconSize)
                .symbolRenderingMode(.monochrome)
        }
    }

    /// 标题栏中央那颗：当前对话（或编程会话）的名字 + 它的菜单。
    /// 和胶囊里那颗是同一份菜单、同一套标题截断——`capsuleTitle` 是必须的，
    /// `.frame(maxWidth:)` 压不住超宽 Text（09-16 她实拍过一条把胶囊撑出屏的标题）
    @ViewBuilder
    private var macTitleMenu: some View {
        if CodingSessionLibrary.shared.isActive {
            // 按钮只有标题文字那么宽，popover 才正对标题（以前 Menu 被撑满整卡宽，菜单跑到右边）
            Button { showCodingCard.toggle() } label: {
                macTitleLabel(Self.capsuleTitle(codingSessionTitle))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $showCodingCard, arrowEdge: .bottom) { codingSessionCard }
            .help("当前编程会话：改名、路径、在终端继续")
        } else {
            Menu { conversationMenuItems } label: {
                macTitleLabel(Self.capsuleTitle(viewModel.selectedConversation?.title ?? "新对话"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .help("当前对话菜单")
        }
    }

    private func macTitleLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: MacShellMetrics.shared.titleSize, weight: .regular))
            .foregroundStyle(ShellStyle.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())   // mac plain 按钮只有画了像素的地方能点
    }
    #endif

    /// 悬浮胶囊。**浮窗（面板）模式专用，这一刀一个字没动**
    @ViewBuilder
    private var landscapeCapsule: some View {
        #if os(macOS)
        HStack(spacing: ShellStyle.controlGap) {
            Button(action: toggleLeftPanel) {
                MacShellLabel(symbol: "sidebar.leading", title: "列表")
            }
            .buttonStyle(MacShellButton(selected: panelLayout.leftShown))
            .help("显示或隐藏对话列表")
            // code 组激活时主区域是只读的会话详情，这颗就是回聊天的出口——否则同一条对话点回来 id 没变，
            // `onChange(selectedConversation)` 不触发，永远回不去（09-15 她报的「聊天页根本输入框都没有」）
            if CodingSessionLibrary.shared.isActive {
                // 跟聊天时同一个位置同一个形状：这里放当前这条的标题（她 09-16：摘要栏「放那个顶部 bar 的那个放对话标题那里」，
                // 「回到对话」那颗字面按钮「很诡异」）。摘要（模型 / 条数 / tokens / 路径 / 时间）和回聊天的出口都收进这个菜单
                Button { showCodingCard.toggle() } label: {
                    MacShellLabel(symbol: "chevron.left.forwardslash.chevron.right",
                                  title: Self.capsuleTitle(codingSessionTitle), chevron: true)
                        .frame(maxWidth: 220)
                }
                .buttonStyle(MacShellButton())
                .popover(isPresented: $showCodingCard, arrowEdge: .bottom) { codingSessionCard }
                .help("当前编程会话：改名、路径、在终端继续")
            } else {
                Menu { conversationMenuItems } label: {
                    // 同一颗、同一个坑：对话标题长了一样会把胶囊撑出窗口
                    MacShellLabel(symbol: "bubble.left",
                                  title: Self.capsuleTitle(viewModel.selectedConversation?.title ?? "新对话"),
                                  chevron: true)
                        .frame(maxWidth: 220)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(MacShellButton())
                .help("当前对话菜单")
            }
            if !chatBubbleMode, branchOffMainCount > 0 {
                Button { showBranchMap = true } label: {
                    MacShellLabel(symbol: "ri-git-branch", title: "\(branchOffMainCount)")
                }
                .buttonStyle(MacShellButton())
                .help("查看对话分支")
            }
            Button(action: toggleDock) {
                MacShellLabel(symbol: "sidebar.trailing", title: "工具")
            }
            .buttonStyle(MacShellButton(selected: panelLayout.dockShown))
            .help("显示或隐藏工具栏")
            Button { openSettingsEntry() } label: {
                MacShellLabel(symbol: "gearshape")
            }
            .buttonStyle(MacShellButton(width: ShellStyle.tabHeight))
            .help("设置（⌘,）")
            .accessibilityLabel("设置")
        }
        .padding(6)
        .background(ShellStyle.windowBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(ShellStyle.hairline, lineWidth: ShellStyle.hairlineWidth).allowsHitTesting(false))
        .shadow(color: ShellStyle.shadow, radius: ShellStyle.shadowRadius, y: 4)
        #else
        HStack(spacing: 2) {
            landscapeBarButton(icon: "sidebar.leading", text: "列表", active: panelLayout.leftShown) {
                toggleLeftPanel()
            }

            landscapeBarDivider

            Menu {
                conversationMenuItems
            } label: {
                HStack(spacing: 5) {
                    Text(viewModel.selectedConversation?.title ?? "新对话")
                        .font(.system(size: Theme.F.label, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: 220)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }

            if !chatBubbleMode, branchOffMainCount > 0 {
                landscapeBarDivider
                Button { showBranchMap = true } label: {
                    HStack(spacing: 3) {
                        AppIconView(name: "ri-git-branch", size: 13)
                        Text("\(branchOffMainCount)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                }
            }

            landscapeBarDivider

            landscapeBarButton(icon: "sidebar.trailing", text: "工具", active: panelLayout.dockShown) {
                toggleDock()
            }

            landscapeBarDivider

            // 宽屏的设置入口放这条上（粟粟：「跟工具栏条条放一起，放最顶上」）。
            // SidebarView 自带的齿轮在宽屏下收掉——它压在对话窗右下角那枚缩放弧底下，两个手势抢一个点
            Button { openSettingsEntry() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .shellGlass(in: Capsule(), tint: 0.15, interactive: true)
        #endif
    }

    private var landscapeBarDivider: some View {
        Rectangle()
            .fill(Theme.textMuted.opacity(0.22))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private func landscapeBarButton(icon: String, text: String, active: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(text)
                    .font(.system(size: Theme.F.secondary, weight: .medium))
            }
            .foregroundColor(active ? Theme.branchIndicator : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                Capsule().fill(active ? Theme.branchIndicator.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    #if os(iOS)
    /// 聊天页顶栏：左箭头(page 0) + 中间 PinBar(有 pin 时) + 右侧加长胶囊(⋯ Menu + 右箭头 page 2)。
    /// 当前对话标题挪进 ⋯ Menu 的 header（原顶栏中间不再显示标题）。
    /// blur 层在 CardFlowView 的 overlay（z 顺序：blur < nav HStack < Menu popover）。
    private var iOSChatTopBar: some View {
        // 音乐在别的对话里放着：顶栏下面一行浮一个小玻璃胶囊（粟粟 09-27；放聊天页顶上会被这条顶栏压住）
        VStack(spacing: 6) {
            iOSChatTopBarRow
            // 气泡模式中间是头像层、没有状态岛：音乐胶囊仍放顶栏下一行
            if chatBubbleMode { MusicNowPlayingCapsule(viewModel: viewModel) }
        }
        .onAppear {
            StreamScrollAnchor.AnchorView.onTopBarCollapse = { collapsed in
                withAnimation(ChatCardMotion.animation(ChatCardMotion.morph, reduceMotion: topBarReduceMotion)) { topBarCollapse.collapsed = collapsed }
            }
        }
        .onChange(of: viewModel.selectedConversation?.id) { _, _ in
            StreamScrollAnchor.AnchorView.resetTopBarCollapse()
            topBarCollapse.collapsed = false
            islandPinIndex = nil
        }
    }

    private var iOSChatTopBarRow: some View {
        return ZStack(alignment: .top) {
            if viewModel.inConvSearchActive {
                ChatFindTopBar(viewModel: viewModel)
                    .frame(maxWidth: isWidePanelMode ? 520 : .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity)
                    // 搜索框底下垫一层渐隐奶白：正文不再从玻璃后面透上来
                    .background {
                        LinearGradient(stops: [
                            .init(color: Theme.mainBg, location: 0),
                            .init(color: Theme.mainBg.opacity(0.92), location: 0.7),
                            .init(color: Theme.mainBg.opacity(0), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                    }
            } else if viewModel.messageSelection.isActive {
                // 多选气泡：顶栏换「取消 / 已选 N 条」（照对话内查找换装；计数只在 ChatSelectTopBar 里读）
                ChatSelectTopBar(selection: viewModel.messageSelection,
                                 onCancel: { viewModel.endMessageSelection() })
                    .frame(maxWidth: isWidePanelMode ? 520 : .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else if isWidePanelMode {
                // 宽屏：悬浮条本体挂在 body overlay 上钉在屏幕正中（不跟聊天区一起被面板推来推去），
                // 这里只留 PinBar 浮在它底下那一行的位置
                VStack(spacing: 7) {
                    Color.clear.frame(height: 46)
                    if !chatBubbleMode, !viewModel.pinnedNodes.isEmpty, !pinBarHidden,
                       viewModel.selectedConversation != nil {
                        PinnedMessageBar(
                            pinnedNodes: viewModel.pinnedNodes,
                            currentIndex: $pinCurrentIndex,
                            isHidden: $pinBarHidden,
                            onTap: handlePinBarTap,
                            onUnpinCurrent: handleUnpinCurrent,
                            onUnpinAll: {
                                viewModel.unpinAll()
                                pinCurrentIndex = 0
                            }
                        )
                        .frame(maxWidth: Theme.contentMaxWidth * 0.72)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .padding(.top, 6)
                .animation(.easeInOut(duration: 0.25), value: pinBarHidden)
            } else {
            HStack(spacing: 8) {
                // 左箭头 → page 0（对话列表）
                Button {
                    withAnimation { iOSPage = 0 }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .circle)
                }
                // 左右两侧等宽 → 中间的岛按屏幕真居中（粟粟：「没有完全居中」）
                .frame(width: ChatTopBarLayout.side, alignment: .leading)

                // 中间：状态岛（置顶消息 + 正在放的音乐合在一块玻璃里；粟粟 09-28 稿）。气泡模式中央是头像胶囊层，不放岛。
                if !chatBubbleMode, viewModel.selectedConversation != nil,
                   let content = ChatTopIsland.Content(
                       hasPin: !viewModel.pinnedNodes.isEmpty && !pinBarHidden,
                       hasMusic: MusicCardPlayer.shared.isActive && MusicCardPlayer.shared.origin != nil) {
                    let pins = viewModel.pinnedNodesInChatOrder
                    ChatTopIsland(
                        content: content,
                        pinnedNodes: pins,
                        pinIndex: PinCycle.clamp(index: islandPinIndex, count: pins.count),
                        pinSlideUp: islandPinSlideUp,
                        collapseState: topBarCollapse,
                        viewModel: viewModel,
                        onPinTap: handleIslandPinTap,
                        onExpand: {
                            StreamScrollAnchor.AnchorView.resetTopBarCollapse()
                            withAnimation(ChatCardMotion.animation(ChatCardMotion.morph, reduceMotion: topBarReduceMotion)) { topBarCollapse.collapsed = false }
                        },
                        onLongPress: { showIslandPeek = true }
                    )
                    .layoutPriority(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    Spacer(minLength: 0)
                }

                // 右侧胶囊：⋯(Menu，含分支地图) + 右箭头(page 2)
                HStack(spacing: 0) {
                    // 分支地图（B20 part 2 A3）并进 ⋯ 菜单；不再单独显示分支数（粟粟 09-28：角标「吵」）
                    Menu {
                        if !chatBubbleMode, branchOffMainCount > 0 {
                            Button { showBranchMap = true } label: {
                                Label("分支地图（\(branchOffMainCount)）", systemImage: "arrow.triangle.branch")
                            }
                            Divider()
                        }
                        conversationMenuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多")

                    // 右箭头 → page 2（更多）
                    Button {
                        withAnimation { iOSPage = 2 }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
                .glassEffect(.regular.tint(Color.white.opacity(0.15)).interactive(), in: .capsule)
                .frame(width: ChatTopBarLayout.side, alignment: .trailing)
            }
            // 定高：岛在 48 ↔ 34 之间伸缩时，两侧按钮不跟着上下抖（粟粟 09-28「1pt 抖动」）
            .frame(height: 48)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .animation(.easeInOut(duration: 0.25), value: pinBarHidden)
            }

            // 气泡模式：中央头像胶囊（独立层做屏幕真居中，不受左右按钮宽度影响）。点开 AI 资料卡。
            if chatBubbleMode, viewModel.selectedConversation != nil, !viewModel.inConvSearchActive,
               !viewModel.messageSelection.isActive {
                Button(action: { showAIProfile = true }) {
                    bubbleModeAvatarCapsule
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .sheet(isPresented: $showAIProfile) {
                    AIProfileSheet()
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Theme.sidebarBg)
                }
            }
        }
    }

    /// L6 A7：开关开时内容放进观察围栏求值（path 衍生量的观察记在围栏上，不牵动 ContentView.body）
    @ViewBuilder
    private func fencedByA7<V: View>(@ViewBuilder _ content: @escaping () -> V) -> some View {
        if ChatPerfSwitch.a7 { ObservationFence(content: content) } else { content() }
    }

    private var iOSListPage: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let viewSpan = LaunchTrace.begin("pageViewValue", fields: ["page": 0, "reason": "body", "profile": profileManager?.currentProfile.id ?? "missing"])
        defer { LaunchTrace.end("pageViewValue", viewSpan, fields: ["page": 0]) }
        #endif
        return SidebarView(
            searchText: $searchText,
            showFavoritesOnly: $showFavoritesOnly,
            showTrash: $showTrash,
            showImporter: $showImporter,
            showSettings: $showSettings,
            viewModel: viewModel,
            agoraViewModel: agoraViewModel,
            onSelectAgoraRoom: selectAgoraRoom,
            onCreateAgoraRoom: { showAgoraCreateSheet = true },
            onSelectConversation: showNormalChat,
            profileId: profileManager?.currentProfile.id ?? ""
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var iOSChatPage: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let viewSpan = LaunchTrace.begin("pageViewValue", fields: ["page": 1, "reason": "body", "profile": profileManager?.currentProfile.id ?? "missing"])
        defer { LaunchTrace.end("pageViewValue", viewSpan, fields: ["page": 1]) }
        #endif
        // wallpaper 已挪到 iOSLayout 外层（chat page child HC 之外）以避开键盘 safeArea 影响，
        // 这里不再挂 .background { ChatWallpaperBackdrop }。chat page ZStack 透明，让外层
        // wallpaper 透过来。
        return ZStack(alignment: .top) {
            if destination == .agoraRoom {
                AgoraRoomView(viewModel: agoraViewModel, onBack: showNormalChat,
                              onForward: { withAnimation { iOSPage = 2 } })
            } else if viewModel.selectedConversation != nil {
                #if (DEBUG || PERF_BENCH) && os(iOS)
                // P1a-0 spike 一次性挂载点（docs/spike-uikit-chat-page.md）：开关 / 测量台都没开时就是原 CardFlowView
                if UIKitChatSpike.engaged {
                    UIKitChatSpikeSwitch(viewModel: viewModel, stickerVM: stickerVM)
                } else {
                    CardFlowView(viewModel: viewModel, stickerVM: stickerVM)
                }
                #else
                CardFlowView(viewModel: viewModel, stickerVM: stickerVM)
                #endif
            } else {
                EmptyStateView(showImporter: $showImporter, profileId: profileManager?.currentProfile.id ?? "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            if destination == .chat {
                fencedByA7 { iOSChatTopBar }
            }
        }
        .overlay {
            if destination == .chat, showIslandPeek {
                fencedByA7 { ChatTopIslandPeek(
                    pins: viewModel.pinnedNodesInChatOrder,
                    currentIndex: PinCycle.clamp(index: islandPinIndex, count: viewModel.pinnedNodesInChatOrder.count),
                    showsPins: !viewModel.pinnedNodes.isEmpty && !pinBarHidden,
                    onJump: { node in
                        jumpToPinned(node)
                        islandPinIndex = viewModel.pinnedNodesInChatOrder.firstIndex { $0.id == node.id }
                    },
                    onUnpin: { node in
                        node.isPinned = false
                        node.pinnedAt = nil
                        islandPinIndex = nil
                    },
                    onUnpinAll: {
                        viewModel.unpinAll()
                        islandPinIndex = nil
                        pinCurrentIndex = 0
                    },
                    onDismiss: { showIslandPeek = false }
                ) }
            }
        }
        // home indicator 区 hit shield 已挪到 UIKit 层（PagingViewController.homeIndicatorShield）。
        // SwiftUI overlay 在 child HC（clipsToBounds=true）+ chat 页 additionalSafeAreaInsets
        // 动态变化下命中条会漂，时灵时不灵。改 UIKit 顶层 UIView + window.safeAreaInsets.bottom
        // 命中链稳定。
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { }
            Button("确认") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let conv = viewModel.selectedConversation {
                    conv.title = trimmed
                    conv.updateTime = Date()
                    viewModel.markConversationDirty()
                }
            }
        }
        .sheet(isPresented: $showChangeProjectSheet) {
            if let conv = viewModel.selectedConversation {
                TagPickerPopover(
                    conversationId: conv.id,
                    profileId: profileManager?.currentProfile.id ?? ""
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.sidebarBg)
            }
        }
        .modifier(ConversationMemorySheets(target: $memorySheet))
        .sheet(isPresented: $showBranchMap) {
            BranchMapSheet(
                viewModel: viewModel,
                onNavigateToNode: { nodeId in
                    if let conv = viewModel.selectedConversation {
                        viewModel.navigateToNode(nodeId: nodeId, conversation: conv, context: modelContext)
                    }
                }
            )
            .presentationBackground(Theme.sidebarBg)
        }
        .onChange(of: viewModel.selectedConversation?.id) { _, _ in
            pinCurrentIndex = 0
            pinBarHidden = false
        }
    }

    #endif

    // MARK: - Pin Bar handlers：两端共用（iOS Phase 3 挪上来，mac 面 2.1 跟上；状态在本 struct 顶部）

    private func handlePinBarTap() {
        let pins = viewModel.pinnedNodes
        guard !pins.isEmpty else { return }
        let idx = min(pinCurrentIndex, pins.count - 1)
        let target = pins[idx]
        if viewModel.currentPath.contains(where: { $0.id == target.id }) {
            viewModel.scrollToNodeId = target.id
            viewModel.highlightedNodeId = target.id
            let targetId = target.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if viewModel.highlightedNodeId == targetId {
                    viewModel.highlightedNodeId = nil
                }
            }
        }
        pinCurrentIndex = (idx + 1) % pins.count
    }

    /// 岛上点置顶（照 Telegram）：跳到这条并高亮，然后换成更旧的一条；最旧再点回到最新
    private func handleIslandPinTap() {
        let pins = viewModel.pinnedNodesInChatOrder
        guard !pins.isEmpty else { return }
        let idx = PinCycle.clamp(index: islandPinIndex, count: pins.count)
        jumpToPinned(pins[idx])
        let next = PinCycle.afterTap(index: idx, count: pins.count)
        islandPinSlideUp = next > idx
        withAnimation(.easeInOut(duration: 0.2)) { islandPinIndex = next }
    }

    private func jumpToPinned(_ target: MessageNode) {
        guard viewModel.currentPath.contains(where: { $0.id == target.id }) else { return }
        viewModel.scrollToNodeId = target.id
        viewModel.highlightedNodeId = target.id
        let targetId = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if viewModel.highlightedNodeId == targetId {
                viewModel.highlightedNodeId = nil
            }
        }
    }

    private func handleUnpinCurrent() {
        let pins = viewModel.pinnedNodes
        guard !pins.isEmpty else { return }
        let idx = min(pinCurrentIndex, pins.count - 1)
        let target = pins[idx]
        target.isPinned = false
        target.pinnedAt = nil
        if pinCurrentIndex >= pins.count - 1 {
            pinCurrentIndex = 0
        }
    }

    /// 当前对话有多少条非主线分支（用于决定是否显示 🌿 按钮 + 角标 N）。两端共用（悬浮条读它）。
    /// 含嵌套分支（DFS 全树），跟 BranchMapSheet 显示口径一致。空则按钮隐藏。
    /// B20 part 2 A3 反馈 + 第二轮 1+2 修：count 跟 sheet list 自洽。
    private var branchOffMainCount: Int {
        viewModel.branchOffMainCount()
    }

    #if os(iOS)
    /// 针脚点阵桌面时外壳底色跟 canvas，否则 10pt 侧衬会露出旧主题色成白边
    @AppStorage("page2DesktopStyle") private var page2DesktopStyle = "classic"
    @AppStorage("page2HomePresentation_v1") private var homePresentation = "free"

    private var iOSDashboardPage: some View {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let viewSpan = LaunchTrace.begin("pageViewValue", fields: ["page": 2, "reason": "body", "profile": profileManager?.currentProfile.id ?? "missing"])
        defer { LaunchTrace.end("pageViewValue", viewSpan, fields: ["page": 2]) }
        #endif
        #if os(iOS)
        let stitchHome = selectedToolId == "home" && (homePresentation == "free" || homePresentation == "stitch")
        let pageBg: Color = stitchHome ? Page2Palette.canvas : Theme.sidebarBg
        #else
        let stitchHome = false
        let pageBg: Color = Theme.sidebarBg
        #endif
        return RightPanelView(
            selectedToolId: $selectedToolId,
            viewModel: viewModel,
            stickerVM: stickerVM
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(pageBg.ignoresSafeArea())
    }

    /// 编辑贴纸时彻底禁用所有滚动。路线 C 下水平 paging 已由 PagingContainerView.disableScroll
    /// 管（UIScrollView.isScrollEnabled），这里只管 chat page 内 CardFlowView 的竖直 ScrollView。
    /// （旧的 disableBounceInSubviews / findCollectionView 路线 C 下 TabView 没了，已删）
    private func setStickerEditScrollLock(_ editing: Bool) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else { return }
        setAllScrollViewsEnabled(!editing, in: window)
    }

    private func setAllScrollViewsEnabled(_ enabled: Bool, in view: UIView) {
        if let scrollView = view as? UIScrollView {
            scrollView.isScrollEnabled = enabled
        }
        for subview in view.subviews {
            setAllScrollViewsEnabled(enabled, in: subview)
        }
    }
    #endif

    // MARK: - macOS Layout

    #if os(macOS)
    /// mac 新壳（plan-mac-shape A1）：iPad 宽屏壳跑在 mac——正文按格子道让位（`DockedInsetHost`），
    /// 对话面板 / tab 组 / dock / 浮窗盖在 overlay，悬浮条居中于**设置算出的聊天道**（跟设置走不跟窗口走）。
    /// mac 只有这一种形态（没有窄屏三页），所以没有 `isWidePanelMode` 判据、没有键盘门控。
    /// A1a：只编入不接主 body；A1b 原子切换、删双树。
    @State private var macWorkspaceActions = MacWorkspaceActions()

    private func focusMacSearch() {
        macWorkspaceActions.search()
    }

    /// 上次停在 Code tab → 启动回到 Code。单元测试宿主也会拉起整个 app：别顺手去扫她的真会话目录
    private func restoreLeftPanelTab() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              MacWorkspacePreferences.shared.restoredLeftPanelTab == .code,
              !CodingSessionLibrary.shared.isActive else { return }
        CodingSessionLibrary.shared.activate()
    }

    /// 窗口玻璃只在停靠壳生效（窗底玻璃挂在 `macDockedTree`；浮窗那棵树照旧实底 + 壁纸）
    private var macGlassActive: Bool { MacGlass.shared.enabled && panelLayout.mode == .docked }

    private var macLayout: some View {
        Group {
            // 两棵树按 mode 切（plan-mac-fullscreen-shell-v2）：停靠 = 标题行 + 四列并排；浮窗 = 09-08 那棵 ZStack 一行不动
            if panelLayout.mode == .docked {
                macDockedTree
            } else {
                macFloatingTree
            }
        }
        .onChange(of: MacWorkspacePreferences.shared.showCodingSessions) { _, visible in
            if !visible { CodingSessionLibrary.shared.deactivate() }
        }
        // 左栏面板组「对话 | Code」的选中 tab 派生自 isActive（⌘K 命中编程会话、终端「在编程会话里看」、点对话回聊天都会改它），
        // 这里统一记下来；启动时按记的恢复
        .onChange(of: CodingSessionLibrary.shared.isActive) { _, active in
            MacWorkspacePreferences.shared.leftPanelTab = active ? .code : .chats
        }
        .task { restoreLeftPanelTab() }
        .background(MacScrollbars().id(panelLayout.currentTab))
        .focusedSceneValue(\.macWorkspaceActions, macWorkspaceActions)
        // 子树（code 组侧栏的搜索钮）靠它开全局搜索并预选类型
        .environment(macWorkspaceActions)
        .background {
            // ⇧⌘F：⌘K 的别名（菜单项一条只能挂一个键；与对话内 ⌘F、文件库 ⌘G / ⇧⌘G 不重）
            Button("") { macWorkspaceActions.search() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // 全局搜索是盖在整窗上的一层（原型 #search-dialog），不是 sheet
        .overlay {
            if macWorkspaceActions.isSearchPresented {
                MacGlobalSearchOverlay(profileId: profileManager?.currentProfile.id ?? "",
                                       profileName: profileManager?.currentProfile.name ?? "",
                                       viewModel: viewModel,
                                       focusToken: macWorkspaceActions.searchFocusToken,
                                       presetKinds: macWorkspaceActions.searchPresetKinds,
                                       onOpenChat: showNormalChat,
                                       onClose: { macWorkspaceActions.closeSearch() })
            }
        }
        .modifier(OnNotify(.newConversationRequested) { handleNewConversationRequest() })
        .onChange(of: panelLayout.mode) { _, _ in panelLayout.cancelMacPresentation() }
        .onChange(of: panelLayout.dockSide) { _, _ in panelLayout.cancelMacPresentation() }
        .onChange(of: panelLayout.arrangement) { _, _ in panelLayout.cancelMacPresentation() }
        .onDisappear { panelLayout.cancelMacPresentation() }
        .environment(\.chatMetrics, MacShellMetrics.shared.chatMetrics)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 悬浮条菜单的三个弹层宿主（iOS 挂在 iOSChatPage 上；mac 没有页，挂壳根）
        .alert("重命名", isPresented: $showRenameAlert) {
            TextField("对话名称", text: $renameText)
            Button("取消", role: .cancel) { }
            Button("确认") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let conv = viewModel.selectedConversation {
                    conv.title = trimmed
                    conv.updateTime = Date()
                    viewModel.markConversationDirty()
                }
            }
        }
        .sheet(isPresented: $showChangeProjectSheet) {
            if let conv = viewModel.selectedConversation {
                TagPickerPopover(
                    conversationId: conv.id,
                    profileId: profileManager?.currentProfile.id ?? ""
                )
                .frame(minWidth: 320, minHeight: 360)
            }
        }
        .modifier(ConversationMemorySheets(target: $memorySheet))
        .sheet(isPresented: $showBranchMap) {
            BranchMapSheet(
                viewModel: viewModel,
                onNavigateToNode: { nodeId in
                    if let conv = viewModel.selectedConversation {
                        viewModel.navigateToNode(nodeId: nodeId, conversation: conv, context: modelContext)
                    }
                }
            )
            .presentationBackground(Theme.sidebarBg)
        }
        .environment(viewModel)   // M3-B：读书 sheet 等子 view 用 @Environment 拿
    }

    /// 浮窗模式那棵树（plan-mac-shape A1 的 ZStack）：正文按格子道让位（`DockedInsetHost`），面板 / dock / 浮窗盖在 overlay，
    /// 悬浮胶囊居中于**设置算出的聊天道**。**v2 一行不动**，只是把停靠模式的分支挪去了 `macDockedTree`
    private var macFloatingTree: some View {
        let grid = panelLayout.grid(in: widePanelAvailableSize)
        let width = widePanelAvailableSize.width
        return ZStack(alignment: .top) {
            // 量**窗口给的**宽高，不量 ZStack 自己：正文的固有最小宽会把 ZStack 撑到比窗口宽，
            // 那时量自己得到的是溢出后的数，面板钳宽永远算不出要让（A1b 冒烟：980 宽两边各裁 25pt）。
            // Color.clear 只接受提案不撑大，量到的就是窗口内容区
            Color.clear
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    widePanelAvailableSize = size
                    // mac 桌面格子列数按窗宽算（带滞回），只在这一处提交（plan-mac-shape A3）
                    panelLayout.commitMacColumns(width: size.width)
                }
                // 排版 / 模式换了，同一宽度下的列数预算也变，重算一次
                .onChange(of: panelLayout.arrangement) { _, _ in panelLayout.commitMacColumns(width: widePanelAvailableSize.width) }
                .onChange(of: panelLayout.mode) { _, _ in panelLayout.commitMacColumns(width: widePanelAvailableSize.width) }
            DockedInsetHost(layout: panelLayout, active: true, availableSize: widePanelAvailableSize,
                            content: macChatContent)
                // 正文层钉在窗口宽内：正文比让位后的道还宽时在道里裁掉（盖在面板底下），壳不整体位移
                .frame(width: width > 0 ? width : nil, alignment: .leading)
                .clipped()
            IPadPanelOverlay(layout: panelLayout, availableSize: widePanelAvailableSize,
                             viewModel: viewModel, stickerVM: stickerVM) { macSidebar }
                .environment(\.widePanelMode, true)
            MacPanelFlightLayer(layout: panelLayout)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(2500)
            if destination == .chat {
                // 悬浮胶囊：「顶 6pt + 按聊天道中心偏移」原样保留
                landscapeTopBar
                    .padding(.top, 6)
                    .offset(x: grid.map { $0.leftLane + $0.chatWidth / 2 - widePanelAvailableSize.width / 2 } ?? 0)
                    .zIndex(3000)
            }
        }
        .coordinateSpace(name: ShellStyle.coordinateSpace)
    }

    /// 停靠（全屏）模式那棵树（plan-mac-fullscreen-shell-v2 §1）：
    /// `VStack { 标题行 ; 工作区 }`——标题行越过顶部安全区画在 y 0（红绿灯那一排），工作区里四列并排实占，
    /// 桌面格子只在空地上、浮出去的窗在工作区里（永远盖不到标题行）。桌布是整棵树的底。
    private var macDockedTree: some View {
        VStack(spacing: 0) {
            // 标题行沿用 `destination == .chat` 的门控；中庭房间时留一条同高的空行，工作区不跳（R-FS2 S5）
            if destination == .chat {
                macTitleBarRow
            } else {
                Spacer().frame(height: MacShellMetrics.shared.titleBarHeight)
            }
            // 工作区尺寸用 GeometryReader 取，**不能**用 ZStack 里的 Color.clear 探针（09-17 实拍复现）：
            // 四个槽是固定宽的 HStack，缩窗那一帧它还撑着旧宽，会把 ZStack 撑到比窗口宽，
            // 同一个 ZStack 里的探针量到的是撑大后的旧数——尺寸永远缩不回去，放大能跟缩小不跟。
            // GeometryReader 的尺寸永远 = 提案，不受子视图撑大；再把 overlay 钉在这个尺寸上、溢出裁掉
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    IPadPanelOverlay(layout: panelLayout, availableSize: geo.size,
                                     viewModel: viewModel, stickerVM: stickerVM, chat: macChatContent) { macSidebar }
                        .environment(\.widePanelMode, true)
                    MacPanelFlightLayer(layout: panelLayout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .zIndex(2500)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                // 坐标空间挂在工作区：tab 框 / 停回框 / 飞行 / 卡槽框全在这一层里上报和消费（R-FS2 Q4）
                .coordinateSpace(name: ShellStyle.coordinateSpace)
                .onChange(of: geo.size, initial: true) { _, size in
                    widePanelAvailableSize = size
                    panelLayout.commitMacColumns(width: size.width)
                }
                .onChange(of: panelLayout.arrangement) { _, _ in panelLayout.commitMacColumns(width: geo.size.width) }
                .onChange(of: panelLayout.mode) { _, _ in panelLayout.commitMacColumns(width: geo.size.width) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 一块桌布：整扇窗从标题栏到底只有一个底色；壁纸在正文卡里（她裁 R2）。
        // 窗口玻璃开时桌布是一层系统玻璃（plan-mac-glass-chrome §1.2）
        .background(MacWindowBackdrop(enabled: MacGlass.shared.enabled, tint: MacGlass.shared.tint,
                                      color: Theme.platformSidebarBackgroundColor).ignoresSafeArea())
        // `fullSizeContentView` 下 SwiftUI 容器默认在安全区**里面**（09-17 实拍：从 32.5 起）——整棵树越过去，标题行才在 y 0
        .ignoresSafeArea(.container, edges: .top)
    }

    private var macSidebar: some View {
        SidebarView(
            searchText: $searchText,
            showFavoritesOnly: $showFavoritesOnly,
            showTrash: $showTrash,
            showImporter: $showImporter,
            showSettings: $showSettings,
            viewModel: viewModel,
            agoraViewModel: agoraViewModel,
            onSelectAgoraRoom: { room in
                selectAgoraRoom(room)
                collapseLeftPanelAfterSelect()
            },
            onCreateAgoraRoom: { showAgoraCreateSheet = true },
            onSelectConversation: {
                showNormalChat()
                collapseLeftPanelAfterSelect()
            },
            profileId: profileManager?.currentProfile.id ?? ""
        )
    }

    /// mac 正文：聊天 / 空态（和旧双树的 detail 一致，不含中庭房间）。顶上给悬浮条留 46pt——
    /// iOS 是在 iOSChatTopBar 里用 Color.clear 占位，mac 没有那层，改用 safeAreaInset
    private var macChatContent: some View {
        let manager = themeManager ?? ThemeManager.shared
        return Group {
            if CodingSessionLibrary.shared.isActive {
                // 侧栏 code 组激活：主区域是编程会话详情（plan-wake-native §3 路由）
                CodingSessionDetailView()
            } else if viewModel.selectedConversation != nil {
                VStack(spacing: 0) {
                    // Pin bar：面 2.1 从 CardFlowView 挪到宿主层，与 iOS（iOSChatTopBar）同层、同顺序（Pin → ⌘F 搜索条 → 列表）；
                    // 气泡模式下隐（B4）。PinnedMessageBar 自己判空 / 判隐藏。
                    if !chatBubbleMode {
                        PinnedMessageBar(
                            pinnedNodes: viewModel.pinnedNodes,
                            currentIndex: $pinCurrentIndex,
                            isHidden: $pinBarHidden,
                            onTap: handlePinBarTap,
                            onUnpinCurrent: handleUnpinCurrent,
                            onUnpinAll: {
                                viewModel.unpinAll()
                                pinCurrentIndex = 0
                            }
                        )
                        .animation(.easeInOut(duration: 0.25), value: viewModel.pinnedNodes.map(\.id))
                        .animation(.easeInOut(duration: 0.25), value: pinCurrentIndex)
                        .animation(.easeInOut(duration: 0.25), value: pinBarHidden)
                    }
                    CardFlowView(viewModel: viewModel, stickerVM: stickerVM)
                    MacChatComposerHost(viewModel: viewModel, stickerVM: stickerVM)
                }
            } else {
                EmptyStateView(showImporter: $showImporter, profileId: profileManager?.currentProfile.id ?? "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 全屏模式：正文（含输入条）装进一张卡，卡外是桌布；浮窗模式照旧铺满 + 给悬浮胶囊让 46
        .modifier(MacChatCard(layout: panelLayout,
                              imageURL: manager.currentBackgroundImageURL,
                              scheme: manager.activeScheme,
                              backgroundStyle: manager.currentBackgroundStyle))
        .task { CodingSessionLibrary.shared.scheduleStartupScan() }
        // 切会话重置轮播 / 隐藏（同 iOSChatPage 的 onChange；原在 CardFlowView 的 mac 分支）
        .onChange(of: viewModel.selectedConversation?.id) { old, _ in
            pinCurrentIndex = 0
            pinBarHidden = false
            // code 组开着时新建 / 选中了对话 → 回到聊天。
            // 从「无选中」托底出草稿（启动 / 删光后的 `ensureDraftConversation`）不算她选了对话：
            // 不然启动时恢复的 Code tab 会被这一下冲掉。点开真对话另有 `loadConversation` 里的 deactivate 兜着
            if old != nil { CodingSessionLibrary.shared.deactivate() }
        }
    }
    #endif

}

// MARK: - Empty State

struct EmptyStateView: View {
    @Binding var showImporter: Bool
    let profileId: String
    @Query private var conversations: [Conversation]

    init(showImporter: Binding<Bool>, profileId: String) {
        self._showImporter = showImporter
        self.profileId = profileId
        // 只判 isEmpty，fetchLimit=1 免全量拉 1700+ 行（B9 顺带 P2）；Query(descriptor) 保留响应性
        var desc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.profileId == profileId })
        desc.fetchLimit = 1
        _conversations = Query(desc)
    }

    var body: some View {
        VStack(spacing: 20) {
            if conversations.isEmpty {
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundColor(Theme.textMuted)
                Text("还没有对话")
                    .font(.title2)
                    .foregroundColor(Theme.textSecondary)
                Text("导入你的 ChatGPT 对话，开始构建记忆花园")
                    .foregroundColor(Theme.textMuted)
                Button("导入 conversations.json") {
                    showImporter = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.branchIndicator)
            } else {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 48))
                    .foregroundColor(Theme.textMuted)
                Text("选择一条对话")
                    .font(.title2)
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
private extension View {
    /// B1 白条修复：macOS 26 的 scrollEdgeEffectHidden 需要可用性守卫（app 最低 macOS 14）。
    @ViewBuilder
    func hideTopScrollEdgeEffect() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
#endif

#if (DEBUG || PERF_BENCH) && os(iOS)
// UI 回归 / 贴纸探针的自动打开（拆出 onAppear：闭包太长 iOS Debug 类型检查超时）
extension ContentView {
    fileprivate func uiTestAutoOpen() {
        // [PROBE 贴纸] 自动选中 probe conversation + 进编辑模式（XCUITest 用）
        if ProbeStickerSeed.shouldAutoSelectProbeConv {
            PROBE("[PROBE 贴纸 ContentView.onAppear] auto-select probe conv")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let descriptor = FetchDescriptor<Conversation>(
                    predicate: #Predicate { $0.id == "probe-sticker-conv-1" }
                )
                if let conv = try? modelContext.fetch(descriptor).first, conv.profileId == profileManager?.currentProfile.id {
                    viewModel.selectedConversation = conv
                    PROBE("[PROBE 贴纸 ContentView.onAppear] selected conv id=\(conv.id)")
                    // 等 5s 让 LazyVStack 渲染出 contentHeight，再进编辑模式
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        stickerVM.isEditingStickers = true
                        PROBE("[PROBE 贴纸 ContentView.onAppear] isEditingStickers=true")
                    }
                } else {
                    PROBE("[PROBE 贴纸 ContentView.onAppear] probe conv NOT FOUND")
                }
            }
        }
        // [UI 回归] 自动打开 R1 键盘对话（plan-perf-watch §1.1，走真实 loadConversation 路径）
        if UIRegressionSeed.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let convId = UIRegressionSeed.keyboardConvId
                let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == convId })
                if let conv = try? modelContext.fetch(descriptor).first, conv.profileId == profileManager?.currentProfile.id {
                    viewModel.loadConversation(conv, context: modelContext)
                }
            }
        }
    }
}
#endif

/// 卡墙切楼层 / 角色页打开聊天的两个钩子——单独拎出来，ContentView.body 链太长会让编译器类型检查超时
private struct CardLibraryReturnHooks: ViewModifier {
    let returnProfileId: String?
    let onReturn: () -> Void
    let onOpenChat: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: returnProfileId) { _, _ in onReturn() }
            #if os(macOS)
            .modifier(OnNotify(.conversationNavigationRequested) { onOpenChat() })
            #endif
    }
}

/// L6 A7（plan-chat-list-perf §3）：观察围栏——内容闭包在本视图 body 里才求值，里面读到的 Observation
/// 依赖记在围栏上，不记到构造它的父视图上（父视图 State 变照旧连带重算：闭包不可比）
struct ObservationFence<Content: View>: View {
    let content: () -> Content
    var body: some View { content() }
}
