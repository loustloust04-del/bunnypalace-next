import MemoryCore
import Foundation
import SwiftData
import SwiftUI

/// 临时提示（fade-out toast）。每条新提示 id 必须新生成，
/// CardFlowView 用 .id() 做 overlay 重置触发。
struct TransientNotice: Equatable {
    let id: UUID
    let text: String
    init(_ text: String) {
        self.id = UUID()
        self.text = text
    }
}

@Observable
final class ConversationViewModel {
    var selectedConversation: Conversation? {
        didSet {
            if oldValue?.id != selectedConversation?.id { recallReceiptCache.removeAll(keepingCapacity: true) }
            if oldValue?.id != selectedConversation?.id, let oldId = oldValue?.id {
                MainActor.assumeIsolated {
                    cancelPromptPreparations(conversationId: oldId, drainQueued: false)
                    let abandoned = pendingSends.filter { $0.conversationId == oldId }
                    pendingSends.removeAll { $0.conversationId == oldId }
                    abandoned.forEach { restoreToDraft($0) }
                }
            }
            if selectedConversation !== oldValue, assistantTurnStatus != nil { assistantTurnStatus = nil }
            syncBubbleModeToTheme()
        }
    }
    /// 当前是不是气泡模式：聊天页唯一来源（ContentView / CardFlowView / BubbleView 读它，ThemeManager 由它同步）。
    /// 没选中对话 = 文章
    var isBubbleMode: Bool { selectedConversation?.isBubbleMode ?? false }

    /// 聊天页配色跟着当前对话的模式走：选中对话变了、模式换了都同步一次。
    /// 顺手盯住当前对话的 displayMode：谁改的都算（同步导入直接写这一列），变了下一拍再同步
    func syncBubbleModeToTheme() {
        ThemeManager.shared.isBubbleModeActive = isBubbleMode
        displayModeWatch &+= 1
        let watch = displayModeWatch
        withObservationTracking {
            _ = selectedConversation?.displayMode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.displayModeWatch == watch else { return }
                self.syncBubbleModeToTheme()
            }
        }
    }
    /// 只认最新一次布下的盯梢，旧的回调到了直接丢
    @ObservationIgnored private var displayModeWatch = 0

    /// 对话菜单「换成气泡 / 换成文章」：只改 displayMode（和它的时间，给跨设备同步比新旧）并保存，
    /// 不推进 updateTime（列表按它排），分支数据不动
    func setDisplayMode(_ mode: ConversationDisplayMode, for conversation: Conversation, context: ModelContext) {
        guard conversation.mode != mode else { return }
        conversation.mode = mode
        conversation.displayModeUpdatedAt = Date()
        try? context.save()
        if conversation === selectedConversation { syncBubbleModeToTheme() }
    }
    var currentPath: [MessageNode] = []   // The currently displayed path of cards
    #if (DEBUG || PERF_BENCH) && os(iOS)
    /// 测量用路径版本号（perf P0 §4.1）：只在列出的写点显式自增、不加 didSet、不参与观察；严格测量角色外恒 0
    @ObservationIgnored var perfPathRevision = 0
    #endif
    /// 本回合 roll_dice 已发出的卡片 id（工具结果里的卡还没进正文索引，同回合连掷也要避重）；回合结束清空
    @ObservationIgnored var diceToolIssuedIds: Set<String> = []
    /// 卡片索引缓存（ConversationViewModel+Cards）；不参与观察
    @ObservationIgnored var cardIndexCache = ChatCardIndexCache()
    /// 时间分割线缓存（#027）；不参与观察
    @ObservationIgnored var timeDividerCache = ChatTimeDividerCache()
    @ObservationIgnored var bubbleRunCache = ChatBubbleRunCache()
    /// 待发卡片的底稿消息（卡片 id → 点的是哪条消息里的卡）
    var cardStagingBase: [String: String] = [:]
    /// 当前显示用的分支选择（父 id → 孩子 id）：平时 = 持久选择表；搜索临时浏览时叠了一层去目标的路径，不落库
    var branchSelection: [String: String] = [:]
    /// 显示路径（含不显示节点）的末端；后台追加 / 迟到的回复据此判断还接不接在眼前这条路上
    private var displayLeafId: String?
    var isLoading: Bool = false
    var scrollToNodeId: String? = nil
    var pendingScrollNodeId: String? = nil
    var highlightedNodeId: String? = nil
    /// 加载请求代号：每次 loadConversation +1；后台建树回主线程只有最新一次能 apply（docs/bug-branch-late-apply-overwrite.md）
    @ObservationIgnored private(set) var loadGeneration: UInt64 = 0
    #if DEBUG
    /// 单测钩子：下一次 loadConversation 的后台建树多睡这么久（秒），用完清零
    @ObservationIgnored var testNextLoadBuildDelay: Double = 0
    @ObservationIgnored var testNextLoadBuildGate: DispatchSemaphore?
    @ObservationIgnored var testNextLoadBuildFailure = false
    @ObservationIgnored var testNextLoadApplyFailure = false
    #endif
    @ObservationIgnored private var failedTreeConversationId: String?
    @ObservationIgnored private var displayedTreeConversationId: String?

    /// CC 入场弹泡（research-cc-bubble-entrance）：待弹 node id（内存态不落库）。
    /// 场景 A=insertProactive isCurrent 时加；场景 B=loadConversation 按未读快照标尾部。
    /// BubbleModeRow reveal 完成回调移除；loadConversation 入口重置防跨对话残留。
    var pendingEntranceNodeIds: Set<String> = []
    /// 视口是否在底部（CardFlowView onScrollGeometryChange 同步写入）。
    /// CC 到达跟随判定：在底 → 滚到新消息；不在底 → 不拽（回底按钮亮徽章，粟粟在上面看历史时不打断）
    var isViewAtBottom = true
    #if os(macOS)
    /// Automatic CC following is not an explicit navigation-to-message request.
    var macCCTailRevision: UInt64 = 0
    private func requestMacCCTailFollow(updatedNodeId: String) {
        guard isViewAtBottom, currentPath.last?.id == updatedNodeId, scrollToNodeId == nil else { return }
        macCCTailRevision &+= 1
    }
    #endif
    /// 行级弹泡白名单（pop-tuner v3）：只有发消息路径明确标记的 node 才弹——
    /// 打开对话时集合为空=门天然关死，物理上不可能群弹（v2 的时序武装门被别的动画事务
    /// 捕获行插入导致进对话全弹，粟粟打回）。loadConversation 入口清空。
    var popNodeIds: Set<String> = []

    /// 标记待弹 + 动画跑完后自动销账——LazyVStack 行滚出屏回收再滚回=子树重新插入，
    /// 不销账会在某个动画事务里意外重弹（pop-tuner v7）
    func markPop(_ id: String) {
        guard BubblePopTuning.enabled else { return }
        popNodeIds.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + BubblePopTuning.duration + 0.6) { [weak self] in
            self?.popNodeIds.remove(id)
        }
    }
    /// 场景 B 的未读快照：loadConversation 清零前抓，applyTreeData 树就位后消费
    private var entranceUnreadSnapshot = 0
    var sidebarRefreshTrigger: Int = 0
    var globalWorldBookEntries: [WorldBookEntry] = []  // View 层从 GlobalWorldBookManager 注入

    // In-conversation search
    /// 对话内查找是否打开（iOS 顶栏 / 底部面板、mac ⌘F 搜索条共用）
    var inConvSearchActive = false
    /// iOS 顶栏搜索框里的原文（含 by: 条件）
    var inConvQuery = ""
    /// iOS 查找结果：按路径从旧到新；Set 给气泡判命中 O(1)
    var inConvHits: [InConvFind.Hit] = []
    var inConvHitIds: Set<String> = []
    /// 当前停在第几条命中（inConvHits 下标）；显示时最新一条算第 1 条
    var inConvHitCursor: Int? = nil
    /// 高亮用的词（by: 不算词）
    var inConvTerms: [String] = []
    var inConvSearching = false
    /// 查询写法不支持时的提示（底部面板替代计数显示）
    var inConvSearchNote: String? = nil
    var inConvListMode = false
    private var inConvSearchTask: Task<Void, Never>?
    var inConvSearchKeyword: String = ""
    var inConvMatches: [String] = []   // matched node IDs
    var inConvMatchIndex: Int = -1

    /// 多选气泡（research-multi-select-bubbles）：选中状态放独立 model，VM 只持有引用（let 不参与 VM 观察）
    let messageSelection = ChatSelectionModel()

    /// 临时提示文案（如"已切换到分支"），CardFlowView overlay 监听显示，
    /// id 变化触发自动 fade out。设新文案时 id 必须新生成。
    var transientNotice: TransientNotice? = nil
    /// 最近一次组装历史时，最新一轮因为模型看不了图少发了图（plan-model-vision-check §1.3）
    @ObservationIgnored private(set) var visionWithheldNode: MessageNode?
    static let visionWithheldNotice = "这个模型看不了图，只发了描述"

    /// 搜索点击去抖：300ms 内同 nodeId 重复点击直接吃掉。
    /// 不放 SidebarView 是因为它是 struct view，state 在 reload 间易丢。
    private var lastNavigateNodeId: String? = nil
    private var lastNavigateAt: Date? = nil

    /// Maps a displayed node id → the actual branching node id (for invisible branch points)
    var bubbledBranches: [String: String] = [:]

    /// Precomputed branch info for each node in currentPath (avoids redundant computation during rendering)
    var branchInfoMap: [String: BranchInfo] = [:]

    private var nodeMap: [String: MessageNode] = [:]
    private var mainPathIds: Set<String> = []
    private var cachedRootId: String?

    /// CC 主动消息去重 cache：chatId -> Set<ccMessageId>。`insertProactiveAssistantMessage`
    /// 的 ccMessageId 库查重热路径用（hub replay 一次最多 500 条砸来，逐条 fetch 整对话太重）。
    /// 首次查某 chatId 走 fetch 填充，后续 O(1) 命中。单调增长，profileWillSwitch 清空。
    /// 见 [[feedback_cc_replay_duplicate_landing]] 和 docs/plan-cc-replay-dedup-fortify.md。
    private var ccDedupCache: [String: Set<String>] = [:]

    // MARK: - Profile Switch Race Defense
    //
    // 切楼层时（ProfileManager.switchTo）会换 modelContainer，旧 Conversation /
    // MessageNode 实例被 SwiftData reset。但路线 C（UIKit PagingContainerView 嵌套
    // UIHostingController）下，旧 SwiftUI view tree 的 dismount 时序不和主 tree
    // 原子对齐，旧 CardFlowView.body 可能在 reset 后还跑一次读 selectedConversation.id
    // → fatal。Master 用 SwiftUI 原生 TabView 无此问题（同 commit phase 原子）。
    //
    // 修法：切楼层前 post .profileWillSwitch，这里 observer 把 VM 持有的所有
    // SwiftData 实例 ref 清空。旧 view body 再跑时读到 nil，不访问已 destroy 实例。
    /// profileWillSwitch observer 的 token。addObserver(forName:...:queue:using:) 返回
    /// 的是 token 不是 self，removeObserver(self) 对 block-based observer 不生效 ——
    /// 必须存 token 显式 remove。
    /// xcdoc: /documentation/foundation/notificationcenter/addobserver(forname:object:queue:using:)
    private var profileSwitchObserver: NSObjectProtocol?

    init() {
        Self.liveInstances.add(self)   // 计时器投递跨窗口判忙（ConversationViewModel+Cards）
        // queue: nil → block 同步在 posting 线程（switchTo 跑在 main）跑，post() 返回时
        // clear 已经执行完，随后 currentProfile / container flip 时旧 VM 已无 SwiftData ref。
        profileSwitchObserver = NotificationCenter.default.addObserver(
            forName: .profileWillSwitch, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // 切楼层：正在跑的 run_command 一并杀（registry 按旧 activeConversationId 键）
            // 两端都要：iOS 后端同样有正在跑的 guest 进程树
            if let cid = self.activeConversationId {
                RunCommandTool.cancel(conversationId: cid)
                MainActor.assumeIsolated { PermissionPromptCenter.shared.cancel(conversationId: cid) }   // 挂着的审批卡算拒绝这一次（switchTo 在主线程 post）
            }
            MainActor.assumeIsolated { self.cancelPromptPreparations(drainQueued: false) }
            // 10-29 返工 B2：旧楼层正在跑的回复先停掉并收口（按登记的节点 / context），剩下的登记一律注销
            MainActor.assumeIsolated {
                if self.assistantTurnInFlight, let id = self.activeAssistantNodeId,
                   let context = self.reactionTurns[id]?.context ?? self.nodeMap[id]?.modelContext {
                    self.cancelAssistantTurn(context: context, drainQueued: false)
                }
                self.reactionTurns.removeAll()
                self.reactionEventOwners.removeAll()
            }
            MainActor.assumeIsolated {
                let abandoned = self.pendingSends
                self.pendingSends = []
                abandoned.forEach { self.restoreToDraft($0) }
            }
            self.turnGeneration += 1   // 旧楼层的工具 handler 回来后作废
            self.clearAllSwiftDataRefs()
            // turn 状态随楼层清：旧 stream 的回调即使再来也只是 no-op，
            // 不清的话 assistantTurnInFlight 卡 true，新楼层永远发不出消息。
            // pendingSends 持有旧楼层 ModelContext ref，必须一起丢。
            self.assistantTurnInFlight = false
            self.turnActivities.removeAll()
            self.activeAssistantNodeId = nil
            self.activeConversationId = nil
            self.pendingUserQuestion = nil   // 持有旧楼层 conversation/node/context ref，必须随楼层丢
            self.pendingCCQuestion = nil     // 旧楼层对话的题面，一并丢（hub pending 还在，重连会再来）
            self.ccWaitingSince = [:]
            self.endInConvSearch()
            self.pendingRefreshTask?.cancel()
            self.pendingRefreshTask = nil
        }
    }

    deinit {
        if let observer = profileSwitchObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 清空所有 SwiftData ref（profileWillSwitch 用）。
    /// 跟旧楼层 container reset / cleanup 后节点失效是同类 race，必须把持有的 @Model 实例 ref 全清。
    private func clearAllSwiftDataRefs() {
        // 旧楼层的 context 不能再被冻结回调用：取消后台任务并清登记（等待者立刻返回）
        for id in freezingWindows.keys { freezingWindows[id]?.task.cancel() }
        freezingWindows.removeAll()
        freezingWindowIds.removeAll()
        selectedConversation = nil
        openWindowNote = nil
        displayedTreeConversationId = nil
        failedTreeConversationId = nil
        currentPath = []
        timeDividerCache.reset()
        bubbleRunCache.reset()
        nodeMap.removeAll()
        mainPathIds.removeAll()
        cachedRootId = nil
        ccDedupCache.removeAll()    // fortify v2 cache：节点表变了必须清
        branchSelection.removeAll()
        displayLeafId = nil
        bubbledBranches.removeAll()
        branchInfoMap.removeAll()
        effectiveChildrenMap.removeAll()
        scrollToNodeId = nil
        pendingScrollNodeId = nil
        highlightedNodeId = nil
    }

    // MARK: - Sidebar 重排 debounce
    /// 内容改动（发消息 / rename / 贴纸加删）后，连续 3 秒无新改动才触发一次 sidebar 重排。
    /// 目的：浏览/快速互动时列表不抖动；点击对话本身不触发（见 loadConversation）。
    /// 下拉刷新 / 切楼层 / 进后台 / 从聊天页切回 sidebar 时立即 flush。
    private var pendingRefreshTask: Task<Void, Never>?
    private let refreshDebounceNanoseconds: UInt64 = 3_000_000_000

    /// 标记有对话内容已改动，触发（或重置）3 秒 debounce。
    func markConversationDirty() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.refreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.flushPendingRefresh()
        }
    }

    /// 立刻触发 sidebar re-fetch，取消挂起的 debounce。
    func flushPendingRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        sidebarRefreshTrigger += 1
    }

    /// 对话的第一条用户消息（起标题用）：当前对话读内存路径，其余按 conversationId 取最早一条 user
    private func firstUserText(chatId: String, pid: String, isCurrent: Bool, context: ModelContext) -> String {
        if isCurrent, let hit = currentPath.first(where: { $0.role == "user" && !$0.content.isEmpty }) { return hit.content }
        var desc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == chatId && $0.profileId == pid && $0.role == "user" },
            sortBy: [SortDescriptor(\MessageNode.createTime)]
        )
        desc.fetchLimit = 1
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
        #endif
        return (try? context.fetch(desc).first?.content) ?? ""
    }

    /// CC 主动发来的消息（无 pending 占位时）：作为一条新 assistant 消息插进 chatId 对应的会话。
    /// chatId == conversation.id。当前选中会话走 in-memory 路径即时刷新；非选中只持久化，下次打开加载。
    func insertProactiveAssistantMessage(chatId: String, content: String, fileData: Data? = nil, fileName: String? = nil, mime: String? = nil, isImage: Bool = false, ccMessageId: String? = nil, replyToId: String? = nil, callReply: CCCallReply? = nil, fromHub hubId: String = CCHubRegistry.primaryId, context: ModelContext) {
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == chatId })
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
        #endif
        guard let conversation = try? context.fetch(convDesc).first else { return }  // 没对应会话 → 丢弃
        let pid = conversation.profileId

        // 🛡️ 终极兜底：按 ccMessageId 查重。CCBridgeWebSocketClient.seenReplyIds 是第一道防线，
        // 这里是数据库层面最后一道：UserDefaults 丢 / 装老版本 / dedup 配置漂移 → 上层失效时，
        // 这层仍然拦住 hub replay 老 reply 重复落库（2026-06-21 装老 app 触发 replay 暴击事故）。
        //
        // 三层防御（见 docs/plan-cc-replay-dedup-fortify.md）：
        // - A: 仅当 selectedConversation==chatId && !isLoading 时 nodeMap 才可信，否则走 cache+fetch
        //   （loadConversation 设了 selectedConversation 但 nodeMap 异步还没填好的 race 窗口会漏拦）
        // - C: cache 命中 O(1)，未命中 fetch 一次然后填 cache，避免 500 条 replay 触发 500 次大 fetch
        // - ccMessageId 是 optional，按 feedback_swiftdata_optional_predicate 教训：非 optional 字段
        //   (conversationId) fetch 缩范围 + 内存 filter ccMessageId，避免 #Predicate 静默不匹配
        if let ccMessageId, !ccMessageId.isEmpty {
            // 只贴了表情、没建节点的那条（2b）：回放照样认得
            if ccReactOnlyReplies.contains(ccMessageId) { return }
            let isCurrentAndLoaded = (selectedConversation?.id == chatId && !isLoading)
            if isCurrentAndLoaded {
                // nodeMap fast path：仅在已 load 完的当前会话用（race 窗口外）
                if nodeMap.values.contains(where: { $0.ccMessageId == ccMessageId }) {
                    return
                }
            } else {
                // 非当前会话 或 当前会话 load 中：走 cache（首次 fetch 填，后续 O(1) 命中）
                if ccDedupContains(chatId: chatId, ccMessageId: ccMessageId, pid: pid, context: context) {
                    return
                }
            }
        }

        // CC 收口即发：真实新消息落地 = 回复到了，收掉等待泡（replay 旧消息在上面 dedup 已 return）
        ccWaitingSince.removeValue(forKey: chatId)
        ccLastReplyAt[chatId] = Date()
        // 老 hub 没有阶段帧时的收口：等着的贴表情再投一次（仍过 isCCTurnBusy，CC 还在跑就接着等）
        MainActor.assumeIsolated { ChatReactionTrigger.shared.turnDidEnd() }
        // 只接 1 台、对话也没改绑过：不记（edit 查不到来源时本来就放行），单 hub 用户不白写
        if let ccMessageId, !ccMessageId.isEmpty,
           MainActor.assumeIsolated({ hubRegistry.hubs.count }) > 1 || CCChatOriginLedger.wasRebound(chatId: chatId, defaults: ccOriginLedger.defaults) {
            let identity = MainActor.assumeIsolated { ccIdentity(ofHub: hubId) }
            ccOriginLedger.recordMessage(chatId: chatId, messageId: ccMessageId, hubId: hubId, identity: identity)
        }

        // 2b：CC 写的 ```react 建节点前剥掉、贴到她的消息上（不分气泡 / 文章）；剥完什么都不剩就不建节点
        var content = content
        if content.contains(ChatReactionIntent.blockTag) {
            let settled = ChatReactionIntent.settle(content)
            let anchor = conversation.currentNodeId
            MainActor.assumeIsolated {
                applyCCReactions(settled.intents, parentId: anchor.isEmpty ? nil : anchor, context: context)
            }
            if settled.text != content, fileData == nil, settled.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let ccMessageId, !ccMessageId.isEmpty {
                    ccReactOnlyReplies.insert(ccMessageId)
                    ccDedupCache[chatId, default: []].insert(ccMessageId)
                }
                try? context.save()
                return
            }
            content = settled.text
        }

        let newId = UUID().uuidString
        let parentId = conversation.currentNodeId

        let node = MessageNode(
            id: newId, role: "assistant", content: content, contentType: "text",
            createTime: Date(), parentId: parentId.isEmpty ? nil : parentId,
            childrenIds: [], conversationId: chatId, profileId: pid
        )
        node.ccMessageId = ccMessageId   // A4：存 CC 消息 id（供 edit 定位）+ 引用
        node.replyToId = replyToId
        context.insert(node)
        registerAutoStartTimers(nodeId: newId, conversationId: chatId, text: content, sentAt: node.createTime ?? Date())
        // C2：CC 发来的文件 → 图存 .image（气泡显示）、非图存 .fileData（文件卡片）
        if let fileData {
            let seg: MessageSegment = isImage
                ? .image(name: fileName ?? "图片", type: nil, data: fileData)
                : .fileData(name: fileName ?? "文件", mime: mime ?? "application/octet-stream", data: fileData)
            node.setSegments([seg, .text(content)], conversationTitle: conversation.title)
        }

        let isCurrent = (selectedConversation?.id == chatId)
        // 眼前显示的就是持久末端（没在临时浏览 / 没切走）→ 新消息接上屏；否则只落库 + 记选择
        let onDisplayedPath = isCurrent && !isLoading && displayLeafId == parentId

        // 链 parent.childrenIds
        var parentChildCount = 0
        if !parentId.isEmpty {
            if isCurrent, let parent = nodeMap[parentId] {
                if !parent.childrenIds.contains(newId) { parent.childrenIds.append(newId) }
                parentChildCount = parent.childrenIds.count
            } else {
                let parentDesc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.id == parentId && $0.profileId == pid }
                )
                #if (DEBUG || PERF_BENCH) && os(macOS)
                if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
                #endif
                if let parent = try? context.fetch(parentDesc).first {
                    if !parent.childrenIds.contains(newId) { parent.childrenIds.append(newId) }
                    parentChildCount = parent.childrenIds.count
                }
            }
        }

        if isCurrent {
            nodeMap[newId] = node
            effectiveChildrenMap[newId] = []
            if !parentId.isEmpty { effectiveChildrenMap[parentId, default: []].append(newId) }
        }
        if onDisplayedPath {
            commitSelection(to: newId, conversation: conversation)
        } else {
            conversation.recordBranchChoice(parentId: parentId, childId: newId, parentChildCount: parentChildCount)
            conversation.currentNodeId = newId
            if isCurrent, parentChildCount > 1, !currentPath.contains(where: { $0.id == parentId }) {
                // 用户在临时浏览别的支：内存选择也记上（不影响眼前路径），之后切支落库不会把这条冲掉
                branchSelection[parentId] = newId
            }
        }
        conversation.updateTime = Date()
        if !isCurrent { conversation.unreadCount += 1 }
        if conversation.title == ConversationTitler.placeholderTitle {
            let firstUser = firstUserText(chatId: chatId, pid: pid, isCurrent: isCurrent, context: context)
            // WS 回调在主线程投递（下面还要改 nodeMap / currentPath）
            MainActor.assumeIsolated {
                ConversationTitler.autoTitle(conversation, firstUser: firstUser, firstAssistant: content,
                                             providerManager: ccTitleProviderManager)
            }
        }

        #if os(iOS)
        // 推送 NSE 索引：proactive message 落地 → touch 进 LRU（任何 provider 都可能被推送）
        PushIdentityWriter.touchConversation(chatId: chatId, profileId: pid)
        #endif

        // 当前会话且接在眼前这条路上：同步 in-memory 路径 + 滚动到新消息（UI 立即刷新）
        if onDisplayedPath {
            currentPath.append(node)
            // 在底部才跟随滚动；用户在上面翻历史时不拽（弹泡随行 onAppear 延迟到被看见时触发）
            #if os(macOS)
            requestMacCCTailFollow(updatedNodeId: newId)
            #else
            if isViewAtBottom { scrollToNodeId = newId }
            #endif
            // CC 入场弹泡（场景 A）：正看着对话时到达 → 待弹。
            // replay 灌入天然不进这里（重启后 isCurrent=false 走上面分支）
            if BubblePopTuning.enabled { pendingEntranceNodeIds.insert(newId) }
        }

        // 插入后同步 cache（hot path：hub replay 连续插入时下一条立即命中）
        if let ccMessageId, !ccMessageId.isEmpty {
            ccDedupCache[chatId, default: []].insert(ccMessageId)
        }

        markConversationDirty()
        try? context.save()

        if onDisplayedPath, let callReply, let hook = callStreamHook,
           callReplyCanTrack?(callReply.requestId, chatId) == true {
            if callReply.streaming || content.isEmpty {
                if callReplyRequests.count >= 64 { callReplyRequests.removeAll() }
                callReplyRequests[newId] = callReply.requestId
            }
            hook(.externalReply(content, callReply), newId, chatId)
        }

        // 发语音条：CC 主动消息不走 assistantTurnDidFinish 收口，voice 块在这里直接处理
        if content.contains("```voice") {
            Task { @MainActor in
                VoiceMessageWriter.processChatIntents(nodeId: newId, context: context, profiles: VoiceMessageWriter.profilesProvider())
            }
        }
        // 健康记录块同理（voice 同款挂点）
        if content.contains("```health-log") {
            Task { @MainActor in
                HealthLogIntentWriter.processChatIntents(nodeId: newId, context: context)
            }
        }
        #if PERSONAL_APPS
        // 交易记录块同理（CC 主动消息不走 assistantTurnDidFinish——漏这挂点 CC 侧永不落地）
        if content.contains("```trade") {
            Task { @MainActor in
                TradeLogIntentWriter.processChatIntents(nodeId: newId, context: context)
            }
        }
        #endif
        if content.contains(AnniversaryIntentWriter.blockTag) {
            Task { @MainActor in
                AnniversaryIntentWriter.processChatIntents(nodeId: newId, context: context)
            }
        }
        // v4-1 §四：CC 楼层的上下文摘要（满 60 条 / 跨过 05:00），和 API 那条压缩分开挂（回复从哪条路落地分）；同一个对话 60 秒内只喊一次。
        // A3 / A4 巡检带这个窗口（「每 N 回合」，astra #8）；v5 C2：每满 N 条新消息（`mem_c2_every`）记一次碎片池
        SessionCloseoutTrigger.shared.ccReplyLanded(conversationId: chatId, profileId: pid, memoryEnabled: conversation.memoryEnabled)
    }

    // MARK: - 问问题 CC 桥（plan-问问题-cc桥）

    /// hub 推来 AskUserQuestion 题面帧 → 挂 pendingCC（切到该对话时 sheet 弹出）。
    /// 重连会重发 pending 帧：同 toolUseId 幂等；已有别的卡挂着 → 先到先得，后到的丢
    ///（hub pending 还在，下次重连再来）。已落过泡的（ccMessageId 查重）不再弹。
    @MainActor
    func presentCCAskUser(chatId: String, toolUseId: String, questions raw: [[String: Any]], fromHub hubId: String = CCHubRegistry.primaryId,
                          context: ModelContext) {
        guard pendingCCQuestion?.toolUseId != toolUseId else { return }
        guard pendingUserQuestion == nil, pendingCCQuestion == nil else { return }
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == chatId })
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
        #endif
        guard let conversation = try? context.fetch(convDesc).first else { return }   // 别的设备的 chat → 丢
        guard let questions = AskUserTool.parseCCQuestions(raw) else { return }
        let keys = Self.ccAskUserDedupKeys(toolUseId: toolUseId, identity: ccIdentity(ofHub: hubId))
        if keys.contains(where: { ccDedupContains(chatId: chatId, ccMessageId: $0, pid: conversation.profileId, context: context) }) { return }
        guard case .success(let client) = ccRoute(hubId: hubId) else { return }
        pendingCCQuestion = PendingCCQuestion(
            chatId: chatId, toolUseId: toolUseId, questions: questions,
            collectedAnswers: Array(repeating: nil, count: questions.count),
            origin: CCHubOrigin(client)
        )
    }

    /// resolved 帧：收卡 + Q/A 落真实 user 气泡（唯一落泡来源——app 答/tmux 答/declined 同路）。
    /// 收卡要 chat + 问问题那台 + toolUseId 都对上（impl1 #15：两台同 toolUseId 互不收卡）；
    /// dedup 用 ccMessageId="askuser:<hub_id>:<toolUseId>"（旧键 "askuser:<toolUseId>" 照认）走 proactive 同款三层防御。
    @MainActor
    func handleCCAskUserResolved(chatId: String, toolUseId: String, questions raw: [[String: Any]], answers: [String: String]?,
                                 fromHub hubId: String = CCHubRegistry.primaryId, context: ModelContext) {
        if let q = pendingCCQuestion, q.toolUseId == toolUseId, q.chatId == chatId, q.origin.hubId == hubId { pendingCCQuestion = nil }
        guard let questions = AskUserTool.parseCCQuestions(raw) else { return }
        let content = questions.map { q in
            "Q: \(q.question)\nA: \(answers?[q.question] ?? AskUserTool.skippedAnswer)"
        }.joined(separator: "\n\n")
        let keys = Self.ccAskUserDedupKeys(toolUseId: toolUseId, identity: ccIdentity(ofHub: hubId))
        insertCCUserMessage(chatId: chatId, content: content, ccMessageId: keys[0], alsoDedupBy: Array(keys.dropFirst()), context: context)
    }

    /// Q/A 泡的去重键：[新键, 旧键]。新键带问问题那台的 hub_id（跨设备一致，槽位 id 是本机的）；不知道 hub_id 只有旧键
    static func ccAskUserDedupKeys(toolUseId: String, identity: String?) -> [String] {
        let legacy = "askuser:\(toolUseId)"
        guard let identity, !identity.isEmpty else { return [legacy] }
        return ["askuser:\(identity):\(toolUseId)", legacy]
    }

    /// stale 帧：问题已在别处回答/TUI 已死——收卡即可（真相由 resolved 帧稍后落）。
    @MainActor
    func handleCCAskUserStale(toolUseId: String, fromHub hubId: String = CCHubRegistry.primaryId) {
        guard pendingCCQuestion?.toolUseId == toolUseId, pendingCCQuestion?.origin.hubId == hubId else { return }
        pendingCCQuestion = nil
        transientNotice = TransientNotice("这个问题已经失效了")
    }

    /// CC 桥的 user 消息落地（Q/A 泡）：insertProactiveAssistantMessage 的 user 版——
    /// 同款 ccMessageId 三层查重 + 上树 + currentPath 同步，少了 unread/推送/意图块（用户自己的话）。
    @MainActor
    private func insertCCUserMessage(chatId: String, content: String, ccMessageId: String, alsoDedupBy legacyIds: [String] = [], context: ModelContext) {
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == chatId })
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
        #endif
        guard let conversation = try? context.fetch(convDesc).first else { return }
        let pid = conversation.profileId
        let isCurrentAndLoaded = (selectedConversation?.id == chatId && !isLoading)
        let keys = [ccMessageId] + legacyIds
        if isCurrentAndLoaded {
            if nodeMap.values.contains(where: { node in node.ccMessageId.map { keys.contains($0) } == true }) { return }
        } else if keys.contains(where: { ccDedupContains(chatId: chatId, ccMessageId: $0, pid: pid, context: context) }) {
            return
        }
        let newId = UUID().uuidString
        let parentId = conversation.currentNodeId
        let node = MessageNode(
            id: newId, role: "user", content: content, contentType: "text",
            createTime: Date(), parentId: parentId.isEmpty ? nil : parentId,
            childrenIds: [], conversationId: chatId, profileId: pid
        )
        node.ccMessageId = ccMessageId
        context.insert(node)
        let isCurrent = (selectedConversation?.id == chatId)
        let onDisplayedPath = isCurrent && !isLoading && displayLeafId == parentId
        var parentChildCount = 0
        if !parentId.isEmpty {
            if isCurrent, let parent = nodeMap[parentId] {
                if !parent.childrenIds.contains(newId) { parent.childrenIds.append(newId) }
                parentChildCount = parent.childrenIds.count
            } else {
                let parentDesc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.id == parentId && $0.profileId == pid }
                )
                #if (DEBUG || PERF_BENCH) && os(macOS)
                if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
                #endif
                if let parent = try? context.fetch(parentDesc).first {
                    if !parent.childrenIds.contains(newId) { parent.childrenIds.append(newId) }
                    parentChildCount = parent.childrenIds.count
                }
            }
        }
        if isCurrent {
            nodeMap[newId] = node
            effectiveChildrenMap[newId] = []
            if !parentId.isEmpty { effectiveChildrenMap[parentId, default: []].append(newId) }
        }
        if onDisplayedPath {
            commitSelection(to: newId, conversation: conversation)
        } else {
            conversation.recordBranchChoice(parentId: parentId, childId: newId, parentChildCount: parentChildCount)
            conversation.currentNodeId = newId
        }
        conversation.updateTime = Date()
        if onDisplayedPath {
            currentPath.append(node)
            #if os(macOS)
            requestMacCCTailFollow(updatedNodeId: newId)
            #else
            if isViewAtBottom { scrollToNodeId = newId }
            #endif
        }
        ccDedupCache[chatId, default: []].insert(ccMessageId)
        markConversationDirty()
        try? context.save()
    }

    /// CC 主动消息按 `ccMessageId` 查重的 helper。命中 cache → O(1) 返回；首次查某 chatId →
    /// 一次 fetch 整对话填 cache。见 `insertProactiveAssistantMessage` 和
    /// docs/plan-cc-replay-dedup-fortify.md（漏洞 C 的修法）。
    private func ccDedupContains(chatId: String, ccMessageId: String, pid: String, context: ModelContext) -> Bool {
        if let set = ccDedupCache[chatId] { return set.contains(ccMessageId) }
        // 首次：fetch 该对话全部 MessageNode（按 feedback_swiftdata_optional_predicate 教训用
        // 非 optional 字段 conversationId/profileId 做 predicate，optional 的 ccMessageId 走内存
        // compactMap）。一次性开销，之后命中 cache。
        let desc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == chatId && $0.profileId == pid }
        )
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
        #endif
        let nodes = (try? context.fetch(desc)) ?? []
        let set = Set(nodes.compactMap(\.ccMessageId))
        ccDedupCache[chatId] = set
        return set.contains(ccMessageId)
    }

    /// A4：用户引用某条消息回复——长按气泡「引用」设置，输入栏显示，发送时带上。
    /// 待发送附件（B2：输入条搬独立 host 后与贴纸面板/macOS 输入条共享，从 CardFlowView @State 升格）
    var selectedAttachments: [PendingChatAttachment] = []
    var quotingPreview: String?    // 输入栏显示的被引用截断文字
    var quotingReplyTo: String?    // reply_to 值（被引用节点的 ccMessageId 优先，否则 id）
    /// 引用某条消息的指定文字（气泡模式传单个 block，文章模式传整条 content）。
    /// 预览显示该文字截断，但 reply_to 仍指向整条消息（block 不是独立消息）。
    func startQuotingText(_ text: String, node: MessageNode) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 200：给组装注入留够语义（UI 引用条渲染处自截）
        quotingPreview = t.isEmpty ? "（附件）" : String(t.prefix(200))
        quotingReplyTo = node.ccMessageId ?? node.id
    }
    func clearQuoting() { quotingPreview = nil; quotingReplyTo = nil }
    /// 卡片里「问问这个」（图表 v2）：把卡上选中的那一项引用进输入框，reply_to 指向卡所在的消息；不自动发
    func quoteCardText(_ text: String, nodeId: String) {
        guard let node = nodeMap[nodeId] else { return }
        startQuotingText(text, node: node)
    }

    /// 编辑旧消息：在输入框里改（plan-edit-in-composer）。消息行只发信号（beginEditing），
    /// 输入条接手：收起草稿进 stash、写原文、聚焦；发送走 editAndResend，退出时放回 stash。
    struct EditingMessage {
        let nodeId: String
        /// 原消息拆回的文字 / 附件 / 引用（plan-edit-attachments §1）
        let restored: ChatAttachmentPromptBuilder.RestoredComposer
        var stash: ComposerStash? = nil
        /// 每次 beginEditing 一个新 token：输入条按它接手（同一条再点一次也重写原文）
        let token = UUID()
        /// 输入条已把原文写进框（重挂载时不再覆盖她改到一半的字）
        var applied = false
    }
    struct ComposerStash {
        let text: String
        let attachments: [PendingChatAttachment]
        let quotePreview: String?
        let quoteReplyTo: String?
    }
    var editingMessage: EditingMessage?
    /// 编辑中又点另一条：只换目标，stash 保留（不重收）
    func beginEditing(_ node: MessageNode) {
        let profileId = node.profileId
        // 同步读盘（粟粟 09-26 拍板：先同步，实测卡再改后台）
        let restored = ChatAttachmentPromptBuilder.restore(
            content: node.content, segments: node.segments,
            replyToId: node.replyToId, replyQuote: node.replyQuote,
            read: { AttachmentStore.read($0, profileId: profileId) },
            extract: { path in
                FileLibraryStore.absoluteURL(path, profileId: profileId).flatMap { try? AttachmentTextExtractor.extract(from: $0) }
            })
        editingMessage = EditingMessage(nodeId: node.id, restored: restored, stash: editingMessage?.stash)
    }

    /// A4：CC 编辑某条消息 → 按 ccMessageId 找节点改 content。当前会话先查 nodeMap，否则 fetch。找不到忽略。
    func applyCCEdit(chatId: String, ccMessageId: String, content raw: String, streaming: Bool = false, context: ModelContext) {
        if ccReactOnlyReplies.contains(ccMessageId) { return }
        // 2b：流式中间态把 ```react 藏起来（不闪一下）；定稿剥掉、贴上，只剩块就撤节点
        var content = raw
        var intents: [ChatReactionIntent.Intent] = []
        if raw.contains(ChatReactionIntent.blockTag) {
            if streaming {
                content = ChatReactionIntent.streamingVisible(raw)
            } else {
                let settled = ChatReactionIntent.settle(raw)
                content = settled.text
                intents = settled.intents
            }
        }
        let settles = !streaming && content != raw
        // 当前会话：内存里找 + 即时刷新。streaming = 逐字流式中间态（hub 每 150ms 一帧）：不算「编辑过」、不每帧滚动
        if selectedConversation?.id == chatId,
           let node = currentPath.first(where: { $0.ccMessageId == ccMessageId }) {
            if settles {
                guard let kept = MainActor.assumeIsolated({ landCCEditReactions(intents, on: node, text: content, ccMessageId: ccMessageId, context: context) })
                else { return }
                content = kept
            }
            node.content = content
            if !streaming {
                node.ccEdited = true
                #if os(macOS)
                // Content observation already refreshes the bubble. Navigation is
                // only appropriate while following the tail, not while reading history.
                requestMacCCTailFollow(updatedNodeId: node.id)
                #else
                scrollToNodeId = node.id   // 触发刷新
                #endif
            }
            try? context.save()
            if !streaming, let requestId = callReplyRequests.removeValue(forKey: node.id) {
                callStreamHook?(.externalReply(content, CCCallReply(requestId: requestId, streaming: false)), node.id, chatId)
            }
            return
        }
        // 非当前会话：限会话内 fetch（conversationId==chatId 是非 optional 比较，稳）再内存找 ccMessageId
        // —— 避开 SwiftData #Predicate 对 optional 字段 `==` 匹配不到的坑。
        let desc = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { $0.conversationId == chatId })
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
        #endif
        if let node = (try? context.fetch(desc))?.first(where: { $0.ccMessageId == ccMessageId }) {
            if settles {
                guard let kept = MainActor.assumeIsolated({ landCCEditReactions(intents, on: node, text: content, ccMessageId: ccMessageId, context: context) })
                else { return }
                content = kept
            }
            node.content = content
            if !streaming { node.ccEdited = true }
            try? context.save()
        }
    }

    /// CC 回复里的 ```react（2b）：从新回复要挂的父节点往上找她的消息贴上。CC 自己的转录里留着块，
    /// 所以不像 API 那条路往箱里记「你给 ta…回了」
    @MainActor
    private func applyCCReactions(_ intents: [ChatReactionIntent.Intent], parentId: String?, context: ModelContext) {
        guard !intents.isEmpty, let parentId, let parent = lookupNode(parentId, context: context) else { return }
        let ancestors = [parent] + ancestorNodes(of: parent, context: context)
        for intent in intents {
            guard let target = ChatReactionIntent.target(for: intent, among: ancestors) else {
                BreadcrumbLog.shared.add("🙈", "CC 贴表情 \(intent.emoji) 没找到要贴的那条，不贴（对话 \(parent.conversationId.prefix(8))）")
                continue
            }
            reactionStore.addAIReaction(intent.emoji, on: target.id)
        }
    }

    /// edit 定稿剥出了 ```react：贴上；剩下什么都看不见（没字、没附件段）就撤掉这个节点并记进只贴表情的回复，
    /// 撤不掉（父节点下还有别的回复）写「（没有回复）」。返回要写进节点的正文；nil = 节点撤掉了
    @MainActor
    private func landCCEditReactions(_ intents: [ChatReactionIntent.Intent], on node: MessageNode, text: String,
                                     ccMessageId: String, context: ModelContext) -> String? {
        applyCCReactions(intents, parentId: node.parentId, context: context)
        let hasAttachment = (node.segments ?? []).contains { if case .text = $0 { return false }; return true }
        guard !hasAttachment, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let convId = node.conversationId
        let conversation = selectedConversation?.id == convId ? selectedConversation
            : (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == convId })))?.first
        if let conversation, rollbackSilentAssistant(node, conversation: conversation, context: context) {
            ccReactOnlyReplies.insert(ccMessageId)
            try? context.save()
            return nil
        }
        return "（没有回复）"
    }

    /// 思考链回传：按 ccMessageId 找节点写 ccThinking（查找逻辑同 applyCCEdit）。
    /// 精确锚找不到时兜底挂该会话最新 assistant 节点（盖 id 回调竞态/旧节点没 id 的保险）。
    /// 同值忽略（replay 幂等）。不滚动——thinking 晚到几秒，别打扰阅读。
    /// 只贴了表情、没留节点的回复（2b）：这一轮的思考直接丢，不往上一条挂
    func applyCCThinking(chatId: String, ccMessageId: String, content: String, context: ModelContext) {
        if ccReactOnlyReplies.contains(ccMessageId) { return }
        if selectedConversation?.id == chatId {
            let node = currentPath.first(where: { $0.ccMessageId == ccMessageId })
                ?? currentPath.last(where: { $0.role == "assistant" })
            if let node, node.ccThinking != content {
                node.ccThinking = content
                try? context.save()
            }
            return
        }
        let desc = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { $0.conversationId == chatId })
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
        #endif
        guard let nodes = try? context.fetch(desc) else { return }
        let node = nodes.first(where: { $0.ccMessageId == ccMessageId })
            ?? nodes.filter({ $0.role == "assistant" })
                .max(by: { ($0.createTime ?? .distantPast) < ($1.createTime ?? .distantPast) })
        if let node, node.ccThinking != content {
            node.ccThinking = content
            try? context.save()
        }
    }

    /// Effective children for each node — rebuilt from actual parent-child relationships
    private var effectiveChildrenMap: [String: [String]] = [:]

    // MARK: - Load Conversation

    /// Background-computed tree data (pure value types, safe to cross threads)
    private struct TreeData {
        let effectiveChildrenMap: [String: [String]]
        let rootId: String?
        let mainPathIds: Set<String>
        let pathNodeIds: [String]
        let bubbledBranches: [String: String]
        let allNodeIds: Set<String>
        /// 显示用选择（临时浏览时叠了去目标的路径）与显示路径末端
        let displaySelection: [String: String]
        let displayLeafId: String?
        /// 持久选择表修补结果；changed = 需要写回（旧对话首次生成 / 记录失效）
        let persistedSelection: [String: String]
        let selectionChanged: Bool
    }

    /// BranchMap v6 用：拍一份只读快照（root + nodeMap + childrenMap + currentPath ids）
    /// 让 sheet view 不直接碰 private 状态。
    struct BranchMapSnapshot {
        let rootId: String
        let nodeMap: [String: MessageNode]
        let childrenMap: [String: [String]]
        let currentPathIds: Set<String>
        let mainPathIds: Set<String>   // v10: conversation 永久主路径（切 currentPath 不变）
    }

    func branchMapSnapshot() -> BranchMapSnapshot? {
        guard let root = cachedRootId, nodeMap[root] != nil else { return nil }
        return BranchMapSnapshot(
            rootId: root,
            nodeMap: nodeMap,
            childrenMap: effectiveChildrenMap,
            currentPathIds: Set(currentPath.map { $0.id }),
            mainPathIds: mainPathIds
        )
    }

    /// BranchMap v6 用：单击节点 = 快切 currentPath。
    /// 不走 loadConversation（那是异步全量 buildTree，200ms+）；
    /// 沿 nodeId 的 parent 链回 root，把每个 multi-child anchor 选到通向它的孩子，
    /// 然后 rebuildPath() 主线程同步重算 currentPath 并持久选择（③b：地图上点选 = 切支）。流畅秒切。
    func navigateToNodeFast(nodeId: String) {
        guard nodeMap[nodeId] != nil else { return }
        MainActor.assumeIsolated { cancelPromptPreparations(conversationId: selectedConversation?.id, drainQueued: false) }

        branchSelection = BranchSelection.selecting(
            nodeId, in: branchSelection,
            parentOf: { [nodeMap] in nodeMap[$0]?.parentId },
            childCount: { [effectiveChildrenMap] in effectiveChildrenMap[$0]?.count ?? 0 })

        rebuildPath()
        persistBranchSelection()
        highlightedNodeId = nodeId
        pendingScrollNodeId = nodeId
        drainPending()
    }

    /// 旧入口保留：搜索结果 / 外部跳转 用全量 reload（含 fetch）。
    func navigateToNode(nodeId: String, conversation: Conversation, context: ModelContext) {
        MainActor.assumeIsolated { cancelPromptPreparations(conversationId: selectedConversation?.id, drainQueued: false) }
        pendingScrollNodeId = nodeId
        loadConversation(conversation, context: context, scrollTargetNodeId: nodeId)
        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
    }

    /// 搜索结果点击的统一入口（B20 part 2）。
    /// - 300ms 同 nodeId 去抖，吃掉用户连点
    /// - 主线 node：path 不切（保持 conversation.currentNodeId 主线）+ 仅 scroll
    /// - 分支 node：切 branch（loadConversation scrollTargetNodeId）+ 弹"已切换到分支"
    /// - 不论主/分支：都发 conversationNavigationRequested 通知让 ContentView 切 page 0→1
    func navigateToSearchResult(nodeId: String, conversation: Conversation, context: ModelContext) {
        // 去抖
        let now = Date()
        if let last = lastNavigateAt, lastNavigateNodeId == nodeId,
           now.timeIntervalSince(last) < 0.3 {
            return
        }
        lastNavigateNodeId = nodeId
        lastNavigateAt = now
        MainActor.assumeIsolated { cancelPromptPreparations(conversationId: selectedConversation?.id, drainQueued: false) }

        // 判断是否在主线
        let cid = conversation.id
        let pid = conversation.profileId
        let nodesDesc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == cid && $0.profileId == pid }
        )
        #if (DEBUG || PERF_BENCH) && os(macOS)
        if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
        #endif
        let allNodes = (try? context.fetch(nodesDesc)) ?? []
        let mainPathSet = Self.computeMainPathSet(nodes: allNodes, currentNodeId: conversation.currentNodeId, selectionData: conversation.branchSelectionData)
        let isOnMainPath = mainPathSet.contains(nodeId)

        pendingScrollNodeId = nodeId

        if isOnMainPath {
            // 主线 node：按持久选择重建 path（path 维持原样），仅 scroll
            loadConversation(conversation, context: context)
        } else {
            // 分支 node：临时浏览那条 branch（不写持久选择，③b）+ toast 提示
            loadConversation(conversation, context: context, scrollTargetNodeId: nodeId)
            transientNotice = TransientNotice("已切换到分支")
        }

        // 触发 page 0→1（同 conv 时 selectedConversation?.id 不变 onChange 不响应）
        NotificationCenter.default.post(name: .conversationNavigationRequested, object: nil)
    }

    /// 选中了对话、列表空、且没有在途加载 = 从没走过加载流程（冷启动直进 Page2 的 css 聊天）。
    /// 有在途加载时补发会把那一单（可能带搜索 / 收藏 / 推送跳转）按代号顶掉，见 docs/bug-branch-late-apply-overwrite.md R11-01
    var needsInitialLoad: Bool {
        selectedConversation != nil && currentPath.isEmpty && !isLoading &&
            (failedTreeConversationId == nil || failedTreeConversationId != selectedConversation?.id)
    }

    /// Build path for selected conversation (fetch + tree computation on background thread)
    /// - scrollTargetNodeId: 搜索跳转的临时浏览——显示路径改走这条，持久选择表不动
    func loadConversation(_ conversation: Conversation, context: ModelContext, scrollTargetNodeId: String? = nil) {
        if conversation.id != selectedConversation?.id { SessionCloseoutTrigger.shared.request() }   // 第三刀：切窗口时巡检（巡检在后台）
        wikiInjectionCache.prefetch(profileId: conversation.profileId)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfCount.hit("loadConversation")
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("ConversationViewModel.loadConversation") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        // 请求 ID 在函数首部捕获，随后台块带进 apply（perf P0 §4.1）；同步段 = 任务区间 loadSync
        let perfReq = PerfHarness.strictMeasure ? PerfHarness.currentReqId : 0
        let perfSyncBegin = PerfHarness.strictMeasure ? CACurrentMediaTime() : 0
        defer { if PerfHarness.strictMeasure { PerfChatV1.loadSync(req: perfReq, begin: perfSyncBegin, end: CACurrentMediaTime()) } }
        // R5 C-08 测试钩子：被点名的请求在后台块里多睡一会儿（强制迟到 apply）
        let perfDelayMs = PerfHarness.strictMeasure && perfReq == PerfHarness.testDelayApplyReq ? PerfHarness.testApplyDelayMs : 0
        #endif
        #if DEBUG
        let loadT0 = CFAbsoluteTimeGetCurrent()
        print(String(format: "[PERF] loadConversation start convId=%@ t=%.3f", conversation.id, loadT0))
        #endif

        // 刀5（plan-memory-usable）：衰减写回已退役——applyDecay 唯一触发点摘除。
        // "忘"= AI 园丁（做梦毕业/合并）+ 人工修剪；时间衰减只活在 effectiveWeight 惰性计算
        //（三温区展示/recall 排序），不再写回 decayWeight 决定任何在场资格。MV3 作废。
        #if DEBUG
        let tConsolidate = CFAbsoluteTimeGetCurrent()
        print(String(format: "[PERF] loadConversation consolidate=%.0fms", (tConsolidate - loadT0) * 1000))
        #endif

        BreadcrumbLog.shared.add("💬", "打开对话「\(conversation.title)」")
        // B41 病根：打开真对话必须离开草稿态——此前只有发消息（commitDraft）才复位，
        // 冷启动草稿→点开真对话后标志残留 true，把 flushDraft/实时草稿同步全拦死
        //（"暂存有时丢/不同步"的间歇性 = 是否发过一条消息）
        isDraftConversation = false
        draftRootNode = nil
        draftGreetingNodes = []
        let changingConversation = displayedTreeConversationId != conversation.id
        selectedConversation = conversation
        #if os(macOS)
        // 点对话 = 回聊天。不能只靠 `onChange(selectedConversation)`——点回同一条 id 没变就不触发，
        // 主区域会一直卡在只读的编程会话详情上（09-15 她报的「聊天页根本输入框都没有」）
        Task { @MainActor in CodingSessionLibrary.shared.deactivate() }
        #endif
        // CC 入场弹泡：清零前抓未读快照（场景 B），入口重置集合防跨对话残留
        entranceUnreadSnapshot = BubblePopTuning.enabled ? conversation.unreadCount : 0
        pendingEntranceNodeIds = []
        popNodeIds = []
        conversation.unreadCount = 0

        #if os(iOS)
        // 推送 NSE 索引：会话被打开时保活 LRU（防止陈年会话被 2000 上限挤掉）
        // 不区分 provider —— 任何 chat 都可能收到 hub APNs 推送（chat_id 跟 provider 字段无关）
        PushIdentityWriter.touchConversation(chatId: conversation.id, profileId: conversation.profileId)
        #endif
        // 点击对话本身不影响排序（旧逻辑 lastOpenedAt = Date() + sidebarRefreshTrigger++
        // 会让对话立刻跳到列表顶部，粟粟的新语义是"纯浏览不打乱列表"）。
        // 真正的内容改动（发消息/rename/贴纸）走 markConversationDirty() 的 3s debounce。
        isLoading = true
        if changingConversation { clearDisplayedTree() }
        timeDividerCache.reset()   // 重开同一对话也重算（导入 / 恢复可能改过节点时间）
        bubbleRunCache.reset()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { perfPathRevision += 1 }
        #endif

        let convId = conversation.id
        let convProfileId = conversation.profileId
        let currentNodeId = conversation.currentNodeId
        let selection = BranchSelection.decode(conversation.branchSelectionData)
        let container = context.container
        loadGeneration &+= 1
        let generation = loadGeneration
        // 搜索 / 收藏跳转目标归这次请求：被更新的请求顶掉就跟着丢
        let pendingJump = pendingScrollNodeId
        pendingScrollNodeId = nil
        #if DEBUG
        let testDelay = testNextLoadBuildDelay
        testNextLoadBuildDelay = 0
        let testGate = testNextLoadBuildGate
        testNextLoadBuildGate = nil
        let testBuildFailure = testNextLoadBuildFailure
        testNextLoadBuildFailure = false
        #else
        let testBuildFailure = false
        #endif

        DispatchQueue.global(qos: .userInitiated).async {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if perfDelayMs > 0 { Thread.sleep(forTimeInterval: perfDelayMs / 1000) }
            #endif
            #if DEBUG
            if testDelay > 0 { Thread.sleep(forTimeInterval: testDelay) }
            testGate?.wait()
            let bgT0 = CFAbsoluteTimeGetCurrent()
            #endif
            let treeData = testBuildFailure ? nil :
                (try? Self.buildTreeInBackground(convId: convId, profileId: convProfileId, currentNodeId: currentNodeId,
                                                selection: selection, browseTargetId: scrollTargetNodeId, container: container))
            #if DEBUG
            let bgT1 = CFAbsoluteTimeGetCurrent()
            print(String(format: "[PERF] buildTreeInBackground=%.0fms nodes=%d", (bgT1 - bgT0) * 1000, treeData?.allNodeIds.count ?? 0))
            #endif

            DispatchQueue.main.async { [self] in
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure, selectedConversation?.id != convId || generation != loadGeneration { PerfChatV1.applyDropped(req: perfReq) }
                #endif
                guard selectedConversation?.id == convId, generation == loadGeneration else {
                    // 在途时当前对话被删 / 切楼层（selection 置空）：再没有哪一单能落地清它
                    if selectedConversation == nil { isLoading = false }
                    return
                }
                guard let treeData else {
                    treeReadFailed(conversationId: convId)
                    return
                }
                #if DEBUG
                let applyT0 = CFAbsoluteTimeGetCurrent()
                #endif
                #if (DEBUG || PERF_BENCH) && os(iOS)
                let perfApplyBegin = PerfHarness.strictMeasure ? CACurrentMediaTime() : 0
                let perfRowsBefore = PerfHarness.strictMeasure ? currentPath.map(\.id) : []
                let perfNodeBefore = PerfHarness.strictMeasure ? selectedConversation?.currentNodeId : nil
                #endif
                applyTreeData(treeData, conversation: conversation, context: context, pendingJump: pendingJump, generation: generation)
                #if (DEBUG || PERF_BENCH) && os(iOS)
                if PerfHarness.strictMeasure {
                    PerfChatV1.applyDone(req: perfReq, begin: perfApplyBegin, end: CACurrentMediaTime(), revision: perfPathRevision,
                                         rowsBefore: perfRowsBefore, rowsAfter: currentPath.map(\.id),
                                         nodeBefore: perfNodeBefore, nodeAfter: selectedConversation?.currentNodeId)
                }
                #endif
                #if DEBUG
                let applyT1 = CFAbsoluteTimeGetCurrent()
                print(String(format: "[PERF] applyTreeData=%.0fms loadTotal=%.0fms", (applyT1 - applyT0) * 1000, (applyT1 - loadT0) * 1000))
                #endif
            }
        }
    }

    /// Compute the main-path nodeId set for a given conversation snapshot.
    /// 给定 nodes 和 currentNodeId，按 buildTreeInBackground 同套算法
    /// （反向 trace mainPath + 正向走选 child）算出主线 nodeId Set。
    /// 用于搜索过滤、UI 高亮等不需要全套 TreeData 的场景。
    /// 算法跟 buildTreeInBackground 必须一致（搜索结果不能跟 chat 显示打架）。
    /// CC 入场弹泡（场景 B）标记规则：主线尾部**连续 assistant 段**的最后 min(unread, cap) 条。
    /// 尾部不是 assistant（怪态/用户已回过）→ 空集不弹。纯函数可测。
    static func entranceNodeIds(path: [(role: String, id: String)], unread: Int, cap: Int) -> Set<String> {
        guard unread > 0, cap > 0 else { return [] }
        var ids: [String] = []
        let want = min(unread, cap)
        for item in path.reversed() {
            guard item.role == "assistant" else { break }
            ids.append(item.id)
            if ids.count == want { break }
        }
        return Set(ids)
    }

    static func computeMainPathSet(nodes: [MessageNode], currentNodeId: String, selectionData: Data? = nil) -> Set<String> {
        let resolution = BranchSelection.resolve(
            links: nodes.map { BranchSelection.Link(id: $0.id, parentId: $0.parentId, childrenIds: $0.childrenIds) },
            selection: BranchSelection.decode(selectionData),
            legacyCurrentNodeId: currentNodeId)
        let byId = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return Set(resolution.pathIds.filter { id in
            guard let n = byId[id] else { return false }
            return (n.role == "user" || n.role == "assistant") && n.hasDisplayableContent && !n.isTrashed
        })
    }

    /// Heavy lifting on background thread: fetch nodes, build tree, compute path (all with pure IDs)
    private static func buildTreeInBackground(convId: String, profileId: String, currentNodeId: String,
                                              selection: [String: String], browseTargetId: String?,
                                              container: ModelContainer) throws -> TreeData {
        let bgContext = ModelContext(container)

        // Fetch all nodes for this conversation
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in node.conversationId == convId && node.profileId == profileId }
        )
        let nodes = try bgContext.fetch(descriptor)

        // Lightweight node data for pure computation
        struct NodeInfo {
            let id: String
            let role: String
            let hasContent: Bool
            let isTrashed: Bool
            let parentId: String?
            let childrenIds: [String]
        }

        var infoMap: [String: NodeInfo] = [:]
        infoMap.reserveCapacity(nodes.count)
        for node in nodes {
            infoMap[node.id] = NodeInfo(id: node.id, role: node.role, hasContent: node.hasDisplayableContent, isTrashed: node.isTrashed, parentId: node.parentId, childrenIds: node.childrenIds)
        }

        // Chase missing ancestors on background context
        var missingIds = Set<String>()
        for info in infoMap.values {
            if let pid = info.parentId, !pid.isEmpty, infoMap[pid] == nil {
                missingIds.insert(pid)
            }
        }
        var toChase = missingIds
        while !toChase.isEmpty {
            var nextChase = Set<String>()
            for mid in toChase {
                let targetId = mid
                let targetProfileId = profileId
                let desc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { node in node.id == targetId && node.profileId == targetProfileId }
                )
                if let found = try bgContext.fetch(desc).first {
                    infoMap[found.id] = NodeInfo(id: found.id, role: found.role, hasContent: found.hasDisplayableContent, isTrashed: found.isTrashed, parentId: found.parentId, childrenIds: found.childrenIds)
                    if let pid = found.parentId, !pid.isEmpty, infoMap[pid] == nil {
                        nextChase.insert(pid)
                    }
                }
            }
            toChase = nextChase
        }

        // 选择走唯一 resolver（③b）：持久选择表 → 旧 currentNodeId 路径 → 稳定序第一个。
        // 根仍是 currentNodeId 的顶层祖先（失效时取无父节点里 id 最小的，至少确定——
        // 旧写法按 dict 迭代序挑根会「抽盲盒」，见 docs/research-conversation-blank-bug.md）
        var links: [String: BranchSelection.Link] = [:]
        links.reserveCapacity(infoMap.count)
        for (id, info) in infoMap {
            links[id] = BranchSelection.Link(id: id, parentId: info.parentId, childrenIds: info.childrenIds)
        }
        let persisted = BranchSelection.resolve(byId: links, selection: selection, legacyCurrentNodeId: currentNodeId)
        let effectiveChildren = persisted.children

        // 搜索跳转：显示路径叠一层「去目标」的选择，只在内存里，持久表不动
        var displaySelection = persisted.selection
        var displayPathIds = persisted.pathIds
        if let target = browseTargetId, links[target] != nil,
           let targetRoot = BranchSelection.trace(from: target, in: links).rootId {
            displaySelection = BranchSelection.selecting(
                target, in: persisted.selection,
                parentOf: { links[$0]?.parentId },
                childCount: { effectiveChildren[$0]?.count ?? 0 })
            displayPathIds = BranchSelection.walk(from: targetRoot, children: effectiveChildren,
                                                  selection: displaySelection, fallbackPath: Set(persisted.pathIds))
        }

        // Build display path (collect node IDs + bubbled branches)
        var pathNodeIds: [String] = []
        var bubbledBranches: [String: String] = [:]
        var lastDisplayedId: String? = nil
        for nid in displayPathIds {
            guard let info = infoMap[nid] else { continue }
            let isDisplayable = (info.role == "user" || info.role == "assistant") && info.hasContent && !info.isTrashed
            if isDisplayable {
                pathNodeIds.append(nid)
                lastDisplayedId = nid
            }
            if (effectiveChildren[nid]?.count ?? 0) > 1 && !isDisplayable, let lastId = lastDisplayedId {
                bubbledBranches[lastId] = nid
            }
        }

        return TreeData(
            effectiveChildrenMap: effectiveChildren,
            rootId: displayPathIds.first ?? persisted.rootId,
            mainPathIds: Set(persisted.pathIds),
            pathNodeIds: pathNodeIds,
            bubbledBranches: bubbledBranches,
            allNodeIds: Set(infoMap.keys),
            displaySelection: displaySelection,
            displayLeafId: displayPathIds.last,
            persistedSelection: persisted.selection,
            selectionChanged: persisted.changed
        )
    }

    /// Apply background results on main thread (re-fetch managed objects for UI)
    private func applyTreeData(_ data: TreeData, conversation: Conversation, context: ModelContext,
                               pendingJump: String?, generation: UInt64) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfCount.hit("applyTreeData")
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("ConversationViewModel.applyTreeData") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        let convId = conversation.id
        let convProfileId = conversation.profileId

        // Re-fetch on main context (fast — SQLite page cache hit)
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in node.conversationId == convId && node.profileId == convProfileId }
        )
        var fetchedNodeMap: [String: MessageNode] = [:]
        do {
            #if DEBUG
            if testNextLoadApplyFailure {
                testNextLoadApplyFailure = false
                throw CocoaError(.fileReadUnknown)
            }
            #endif
            #if (DEBUG || PERF_BENCH) && os(macOS)
            if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
            #endif
            let nodes = try context.fetch(descriptor)
            fetchedNodeMap.reserveCapacity(nodes.count)
            for node in nodes { fetchedNodeMap[node.id] = node }
            for nodeId in data.allNodeIds where fetchedNodeMap[nodeId] == nil {
                let nid = nodeId
                let nidProfileId = convProfileId
                let desc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { node in node.id == nid && node.profileId == nidProfileId }
                )
                #if (DEBUG || PERF_BENCH) && os(macOS)
                if Thread.isMainThread { PerfCountMac.hit(.mainFetch) }
                #endif
                guard let node = try context.fetch(desc).first else {
                    treeReadFailed(conversationId: convId)
                    return
                }
                fetchedNodeMap[node.id] = node
            }
        } catch {
            treeReadFailed(conversationId: convId)
            return
        }

        // Apply pre-computed structures
        nodeMap = fetchedNodeMap
        displayedTreeConversationId = convId
        failedTreeConversationId = nil
        effectiveChildrenMap = data.effectiveChildrenMap
        cachedRootId = data.rootId
        mainPathIds = data.mainPathIds
        bubbledBranches = data.bubbledBranches
        currentPath = data.pathNodeIds.compactMap { nodeMap[$0] }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { perfPathRevision += 1 }
        #endif
        branchSelection = data.displaySelection
        displayLeafId = data.displayLeafId

        rebuildBranchInfoMap()

        // 旧对话首次生成选择表 / 记录指向的节点没了：修补结果写回（只在确实变了时写）
        if data.selectionChanged {
            conversation.branchSelectionData = BranchSelection.encode(data.persistedSelection)
            try? context.save()
        }

        // 与发消息 / 删消息同口径：只数当前分支路径（数全树会把重新生成的旁支也算进去，打开就翻倍）
        conversation.nodeCount = currentPath.filter {
            ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent
        }.count
        isLoading = false

        // CC 入场弹泡（场景 B）：打开带未读的对话 → 尾部连续 assistant 段最近 ≤3 条待弹
        if BubblePopTuning.enabled, entranceUnreadSnapshot > 0 {
            pendingEntranceNodeIds = Self.entranceNodeIds(
                path: currentPath.map { (role: $0.role, id: $0.id) },
                unread: entranceUnreadSnapshot,
                cap: 3
            )
        }
        entranceUnreadSnapshot = 0

        // 反转列表：offset=0 自然在最新消息，不需要回底兜底。只处理搜索/收藏跳转目标。
        if let pending = pendingJump {
            DispatchQueue.main.async { [self] in
                guard generation == loadGeneration else { return }
                scrollToNodeId = pending
                highlightedNodeId = pending
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                    if highlightedNodeId == pending { highlightedNodeId = nil }
                }
            }
        }
        drainPending()
    }

    private func treeReadFailed(conversationId: String) {
        failedTreeConversationId = conversationId
        isLoading = false
        transientNotice = TransientNotice("对话读取失败，请重新打开后发送")
    }

    private func clearDisplayedTree() {
        currentPath = []
        displayedTreeConversationId = nil
        mainPathIds.removeAll()
        branchSelection.removeAll()
        displayLeafId = nil
        bubbledBranches.removeAll()
        nodeMap.removeAll()
        cachedRootId = nil
        effectiveChildrenMap.removeAll()
        branchInfoMap.removeAll()
    }

    /// Build effective children map from actual parent→child relationships
    private func buildEffectiveChildrenMap() {
        // 与加载同一份孩子表规则（BranchSelection.effectiveChildren：过滤不存在 + 按 parentId 补回，稳定序）
        effectiveChildrenMap = BranchSelection.effectiveChildren(nodeMap.mapValues {
            BranchSelection.Link(id: $0.id, parentId: $0.parentId, childrenIds: $0.childrenIds)
        })
    }

    /// Get children IDs for a node
    private func childrenIds(for nodeId: String) -> [String] {
        effectiveChildrenMap[nodeId] ?? []
    }

    // MARK: - Path Building

    func rebuildPath() {
        currentPath.removeAll()
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { perfPathRevision += 1 }
        #endif
        bubbledBranches.removeAll()
        displayLeafId = nil

        guard let rootId = cachedRootId ?? findRootId() else { return }

        var lastDisplayedNodeId: String? = nil
        let pathIds = BranchSelection.walk(from: rootId, children: effectiveChildrenMap,
                                           selection: branchSelection, fallbackPath: mainPathIds)
        for nid in pathIds {
            guard let node = nodeMap[nid] else { break }
            let isDisplayable = (node.role == "user" || node.role == "assistant") && node.hasDisplayableContent && !node.isTrashed
            if isDisplayable {
                currentPath.append(node)
                lastDisplayedNodeId = nid
            }
            if childrenIds(for: nid).count > 1 && !isDisplayable, let lastId = lastDisplayedNodeId {
                bubbledBranches[lastId] = nid
            }
            displayLeafId = nid
        }

        rebuildBranchInfoMap()
    }

    /// 分叉点选哪个孩子（③b 唯一规则，地图 / 分支长度 / 计数都走它）
    private func selectedChild(of nodeId: String, among children: [String]) -> String? {
        BranchSelection.pick(parent: nodeId, children: children, selection: branchSelection, fallbackPath: mainPathIds)
    }

    /// 切支 / 地图点选后：选择表与派生出的路径末端（currentNodeId）同一次保存；主线随之换成这条
    private func persistBranchSelection() {
        guard let conversation = selectedConversation, let leaf = displayLeafId else { return }
        conversation.branchSelectionData = BranchSelection.encode(branchSelection)
        conversation.currentNodeId = leaf
        mainPathIds = ancestorChain(of: leaf)
        recoverRecallBranch(conversation, clearActive: true)
        rebuildBranchInfoMap()   // 「★ 主线」标记跟着新主线走
        try? conversation.modelContext?.save()
    }

    /// 新节点接在显示路径末端（发送 / 重新生成 / 编辑重发 / 当前对话的追加）：
    /// 祖先链上的分叉点记成通向它，currentNodeId 指向它；保存由调用方那次 save 一起落
    private func commitSelection(to nodeId: String, conversation: Conversation) {
        branchSelection = BranchSelection.selecting(
            nodeId, in: branchSelection,
            parentOf: { [nodeMap] in nodeMap[$0]?.parentId },
            childCount: { [effectiveChildrenMap] in effectiveChildrenMap[$0]?.count ?? 0 })
        conversation.branchSelectionData = BranchSelection.encode(branchSelection)
        conversation.currentNodeId = nodeId
        displayLeafId = nodeId
        mainPathIds = ancestorChain(of: nodeId)
    }

    private func ancestorChain(of nodeId: String) -> Set<String> {
        var chain: Set<String> = [nodeId]
        var current = nodeId
        while let pid = nodeMap[current]?.parentId, nodeMap[pid] != nil, chain.insert(pid).inserted { current = pid }
        return chain
    }

    // MARK: - Branch Navigation

    func switchBranch(at nodeId: String, to childIndex: Int) {
        let children = childrenIds(for: nodeId)
        guard children.indices.contains(childIndex) else { return }
        MainActor.assumeIsolated { cancelPromptPreparations(conversationId: selectedConversation?.id, drainQueued: false) }
        branchSelection[nodeId] = children[childIndex]
        rebuildPath()
        persistBranchSelection()
        drainPending()
    }

    func branchNodeId(for displayedNodeId: String) -> String? {
        if childrenIds(for: displayedNodeId).count > 1 {
            return displayedNodeId
        }
        return bubbledBranches[displayedNodeId]
    }

    func hasBranches(for displayedNodeId: String) -> Bool {
        return branchNodeId(for: displayedNodeId) != nil
    }

    func branchCount(for displayedNodeId: String) -> Int {
        guard let bid = branchNodeId(for: displayedNodeId) else { return 0 }
        return childrenIds(for: bid).count
    }

    /// "你在哪"位置 hint — 给 BranchMapSheet v2 mini-map 标当前位置用。
    /// 直接读 highlightedNodeId（最近交互过的 node：搜索点击 / pin 跳转 / branch 切换都会设）。
    /// 3s 后会被清空，sheet 打开时如果是 nil 就不画位置 marker（视觉降级，不出 false 信息）。
    /// 详见 docs/plan-branch-map-v2-minimap.md Q1。
    var currentPositionHint: String? { highlightedNodeId }

    /// 给定 child nodeId（某条 branch 的入口），顺向走到 leaf 数 displayable node 数。
    /// 分叉时按选择表选（selectedChild，跟加载同一规则）。
    /// 用于分支地图显示"分支 N 共 X 条"。B20 part 2 A3 反馈。
    func branchLength(fromChildId childId: String) -> Int {
        var count = 0
        var visited = Set<String>()
        var currentId: String? = childId
        while let nid = currentId, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)
            let isDisplayable = (node.role == "user" || node.role == "assistant") && node.hasDisplayableContent && !node.isTrashed
            if isDisplayable { count += 1 }
            currentId = selectedChild(of: nid, among: effectiveChildrenMap[nid] ?? [])
        }
        return count
    }

    /// 一条分支的完整描述（含嵌套）。给 BranchMapSheet v2 用。
    /// branchInfoMap 只覆盖当前 currentPath 上的 anchor，看不到嵌套二级分支；
    /// 这个函数 DFS 整棵 effectiveChildrenMap 树，收集所有有 ≥2 displayable
    /// children 的 anchor 的所有非"主选 child"，包括分支之中的子分支。
    /// depth=0 表示 anchor 在主线上；depth>0 表示 anchor 自己也是别人的分支。
    struct AllBranchEntry: Identifiable {
        let id: String                  // anchor + childIndex 唯一
        let anchorNodeId: String        // 实际 branching node id（≥2 children）
        let childIndex: Int             // 该分支是 anchor 的第几个 child
        let childPreviewNode: MessageNode  // 分支起点的第一条 displayable
        let depth: Int                  // 0 = 主线分支；>0 = 分支的分支
        let parentAnchorOnMain: String?  // 一路追溯到主线 anchor 的 nodeId（用于按主线位置排序）
        let parentBranchEntryId: String?  // v5 outline tree：嵌套分支指向直接父 entry id（一级 = nil）
        let length: Int                 // 分支长度（displayable node 数）
        let location: Int               // 在主线 currentPath 第几条；嵌套分支 = parent 的 location
    }

    /// 给 collectAllBranches 用：找 anchor 在主线上能定位的"显示位置"。
    /// anchor 可能是 invisible system/tool 节点（在 mainPathIds 但不在 currentPath），
    /// 此时 currentPath.firstIndex 返回 nil。改沿 parent 链回溯，找最近的
    /// displayable + 在 currentPath 的 ancestor，取它的 index。
    private func nearestDisplayedIndexInPath(of nodeId: String) -> Int? {
        var current: String? = nodeId
        var visited = Set<String>()
        while let nid = current, !visited.contains(nid), let node = nodeMap[nid] {
            visited.insert(nid)
            if let idx = currentPath.firstIndex(where: { $0.id == nid }) {
                return idx
            }
            current = node.parentId
        }
        return nil
    }

    /// 非主线分支条数，口径 = `collectAllBranches().count`（同一 DFS、同一「有可显示后代」判定），
    /// 但不做主线定位 / 分支长度 / 条目构造 / 排序——顶栏 🌿 角标每次 body 都要读（perf-flash C2）
    func branchOffMainCount() -> Int {
        guard let rootId = cachedRootId, nodeMap[rootId] != nil else { return 0 }
        var count = 0
        var stack = [rootId]
        var visited = Set<String>()
        while let nid = stack.popLast() {
            guard visited.insert(nid).inserted else { continue }
            let children = effectiveChildrenMap[nid] ?? []
            if children.count >= 2 {
                let chosenChild = selectedChild(of: nid, among: children) ?? children[0]
                for childId in children where childId != chosenChild && firstDisplayableDescendant(from: childId) != nil {
                    count += 1
                }
            }
            stack.append(contentsOf: children)
        }
        return count
    }

    func collectAllBranches() -> [AllBranchEntry] {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        PerfCount.hit("collectAllBranches")
        #endif
        guard let rootId = cachedRootId, nodeMap[rootId] != nil else { return [] }

        var out: [AllBranchEntry] = []
        // DFS：(nodeId, depth, mainAnchorAncestor, mainAnchorLocation, parentBranchEntryId)
        // parentBranchEntryId：进入分支 child 后，该 child 下游所有嵌套 entry 的父
        var stack: [(String, Int, String?, Int, String?)] = [(rootId, 0, nil, -1, nil)]
        var visited = Set<String>()

        while let (nid, depth, mainAnchor, mainLoc, parentEntryId) = stack.popLast() {
            if visited.contains(nid) { continue }
            visited.insert(nid)
            let children = effectiveChildrenMap[nid] ?? []

            if children.count >= 2 {
                // anchor — 选 mainPathIds 里的 child（主选），其余都是分支
                let chosenChild = selectedChild(of: nid, among: children) ?? children[0]
                let anchorOnMain = mainPathIds.contains(nid)
                let anchorLocation: Int = {
                    if anchorOnMain {
                        // invisible branch（system 节点 anchor）不在 currentPath
                        // → 往 parent 链找最近的 displayed ancestor 的位置
                        return nearestDisplayedIndexInPath(of: nid) ?? mainLoc
                    }
                    return mainLoc
                }()
                let nextMainAnchor: String? = anchorOnMain ? nid : mainAnchor

                for (idx, childId) in children.enumerated() {
                    if childId == chosenChild {
                        // 主选 child 继续往下走找深层分支；parentEntryId 不变（仍属于上层 branch lane）
                        stack.append((childId, depth, nextMainAnchor, anchorLocation, parentEntryId))
                        continue
                    }
                    // 分支 child：记录一条分支 entry
                    guard let preview = firstDisplayableDescendant(from: childId) else {
                        // 无 displayable 后代，跳过；下游嵌套不会有合法 preview，但还是要透传 parent
                        stack.append((childId, depth + 1, nextMainAnchor, anchorLocation, parentEntryId))
                        continue
                    }
                    let entryId = "\(nid):\(idx)"
                    out.append(AllBranchEntry(
                        id: entryId,
                        anchorNodeId: nid,
                        childIndex: idx,
                        childPreviewNode: preview,
                        depth: anchorOnMain ? 0 : depth,
                        parentAnchorOnMain: nextMainAnchor,
                        parentBranchEntryId: parentEntryId,
                        length: branchLength(fromChildId: childId),
                        location: anchorLocation
                    ))
                    // 进入这条分支继续找子分支：下游嵌套的父 = 本 entry
                    stack.append((childId, depth + 1, nextMainAnchor, anchorLocation, entryId))
                }
            } else {
                for childId in children {
                    stack.append((childId, depth, mainAnchor, mainLoc, parentEntryId))
                }
            }
        }

        // 按主线位置排序；同位置按 depth 升序（一级在嵌套之前）
        out.sort { lhs, rhs in
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.depth < rhs.depth
        }
        return out
    }

    func branchChildren(for nodeId: String) -> [(index: Int, node: MessageNode, isMainPath: Bool)] {
        forkChildren(of: bubbledBranches[nodeId] ?? nodeId)
    }

    /// 分支信息挂在「有多个版本的那条」自己身上（plan-thinking-branch §1）：从这条往上走，第一个有多个孩子的祖先
    /// 就是它的分叉点；途中先碰到可见消息 = 它没有别的版本。currentIndex = 分叉点孩子里通向它的那个。
    /// 隐形根 / system / tool 这些不可见节点会被跨过去（第一条消息的分叉在隐形根上）
    private func rebuildBranchInfoMap() {
        branchInfoMap.removeAll()
        for node in currentPath {
            var child = node.id
            var seen: Set<String> = [node.id]
            while let pid = nodeMap[child]?.parentId, let parent = nodeMap[pid], seen.insert(pid).inserted {
                let kids = childrenIds(for: pid)
                if kids.count > 1 {
                    branchInfoMap[node.id] = BranchInfo(
                        displayedNodeId: node.id,
                        branchNodeId: pid,
                        branchCount: kids.count,
                        currentIndex: kids.firstIndex(of: child) ?? 0,
                        branchChildren: forkChildren(of: pid))
                    break
                }
                let parentDisplayable = (parent.role == "user" || parent.role == "assistant")
                    && parent.hasDisplayableContent && !parent.isTrashed
                if parentDisplayable { break }
                child = pid
            }
        }
    }

    private func forkChildren(of actualId: String) -> [(index: Int, node: MessageNode, isMainPath: Bool)] {
        let children = childrenIds(for: actualId)
        return children.enumerated().compactMap { (idx, childId) in
            let previewNode = firstDisplayableDescendant(from: childId)
            guard let preview = previewNode else { return nil }
            return (index: idx, node: preview, isMainPath: mainPathIds.contains(childId))
        }
    }

    private func firstDisplayableDescendant(from nodeId: String) -> MessageNode? {
        var visited = Set<String>()
        var current: String? = nodeId
        while let nid = current, let node = nodeMap[nid], !visited.contains(nid) {
            visited.insert(nid)
            if (node.role == "user" || node.role == "assistant") && node.hasDisplayableContent && !node.isTrashed {
                return node
            }
            current = childrenIds(for: nid).first
        }
        return nil
    }

    // MARK: - In-Conversation Search

    func searchInConversation(keyword: String) {
        inConvSearchKeyword = keyword
        guard !keyword.isEmpty else {
            inConvMatches = []
            inConvMatchIndex = -1
            return
        }
        inConvMatches = currentPath.filter { node in
            (node.role == "user" || node.role == "assistant") &&
            node.content.localizedStandardContains(keyword)
        }.map(\.id)
        inConvMatchIndex = inConvMatches.isEmpty ? -1 : 0
        if let firstId = inConvMatches.first {
            scrollToNodeId = firstId
            highlightedNodeId = firstId
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                if highlightedNodeId == firstId { highlightedNodeId = nil }
            }
        }
    }

    func navigateInConvMatch(direction: Int) {
        guard !inConvMatches.isEmpty else { return }
        inConvMatchIndex = (inConvMatchIndex + direction + inConvMatches.count) % inConvMatches.count
        let nodeId = inConvMatches[inConvMatchIndex]
        scrollToNodeId = nodeId
        highlightedNodeId = nodeId
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            if highlightedNodeId == nodeId { highlightedNodeId = nil }
        }
    }

    func clearInConvSearch() {
        inConvSearchKeyword = ""
        inConvMatches = []
        inConvMatchIndex = -1
    }

    func beginInConvSearch() {
        messageSelection.end()   // 查找和多选都要换装顶栏 / 输入栏，不叠
        inConvSearchActive = true
    }

    func endInConvSearch() {
        inConvSearchActive = false
        inConvSearchTask?.cancel()
        inConvSearchTask = nil
        inConvQuery = ""
        inConvHits = []
        inConvHitIds = []
        inConvHitCursor = nil
        inConvTerms = []
        inConvSearching = false
        inConvSearchNote = nil
        inConvListMode = false
        clearInConvSearch()
    }

    /// 边打边搜：停 0.2 秒搜一次，新的取消旧的。主线程取路径快照，后台清洗 + 过滤
    func scheduleInConvSearch() {
        inConvSearchTask?.cancel()
        let raw = inConvQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            inConvSearching = false
            applyInConvResult(InConvFind.Result(hits: [], terms: [], note: nil))
            return
        }
        inConvSearching = true
        inConvSearchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            let items = self.currentPath.compactMap { n -> InConvFind.Item? in
                guard n.role == "user" || n.role == "assistant" else { return nil }
                return InConvFind.Item(id: n.id, isUser: n.role == "user", content: n.content, date: n.createTime)
            }
            let result = await Task.detached(priority: .userInitiated) { InConvFind.run(raw, items: items) }.value
            guard !Task.isCancelled else { return }
            self.inConvSearching = false
            self.applyInConvResult(result)
        }
    }

    /// 新结果落地：原来停的那条还在就不动；改了关键词停在离原位置最近的那条；第一次跳到最新一条
    private func applyInConvResult(_ result: InConvFind.Result) {
        let previousId = inConvHitCursor.flatMap { inConvHits.indices.contains($0) ? inConvHits[$0].id : nil }
        inConvHits = result.hits
        inConvHitIds = Set(result.hits.map(\.id))
        inConvTerms = result.terms
        inConvSearchNote = result.note
        guard !result.hits.isEmpty else {
            inConvHitCursor = nil
            inConvListMode = false
            return
        }
        var cursor = result.hits.count - 1
        if let previousId {
            if let same = result.hits.firstIndex(where: { $0.id == previousId }) {
                cursor = same
            } else {
                let order = Dictionary(currentPath.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
                if let anchor = order[previousId] {
                    cursor = result.hits.indices.min { abs((order[result.hits[$0].id] ?? 0) - anchor) < abs((order[result.hits[$1].id] ?? 0) - anchor) } ?? cursor
                }
            }
        }
        if result.hits[cursor].id == previousId {
            inConvHitCursor = cursor
        } else {
            jumpToInConvHit(cursor)
        }
    }

    func jumpToInConvHit(_ index: Int) {
        guard inConvHits.indices.contains(index) else { return }
        inConvHitCursor = index
        let id = inConvHits[index].id
        scrollToNodeId = id
        flashNode(id)
    }

    /// ↑ 更旧：最旧一条时不动（按钮置灰），不循环
    func stepInConvHitOlder() {
        guard let cursor = inConvHitCursor, cursor > 0 else { return }
        jumpToInConvHit(cursor - 1)
    }

    /// ↓ 更新：已经在最新一条返回 false，调用方回到对话底部
    func stepInConvHitNewer() -> Bool {
        guard let cursor = inConvHitCursor, cursor < inConvHits.count - 1 else { return false }
        jumpToInConvHit(cursor + 1)
        return true
    }

    /// 日历跳到某天：退出查找，跳到当前路径里第一条 createTime ≥ 那天零点的消息（没有就最后一条），闪一下
    func jumpToDay(_ day: Date) {
        endInConvSearch()
        let start = Calendar.current.startOfDay(for: day)
        guard let target = currentPath.first(where: { ($0.createTime ?? .distantPast) >= start }) ?? currentPath.last else { return }
        scrollToNodeId = target.id
        flashNode(target.id)
    }

    /// 气泡闪一下：先清再置（同一条连跳两次也要重新闪），1.5 秒后熄
    func flashNode(_ id: String) {
        highlightedNodeId = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.highlightedNodeId = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.highlightedNodeId == id { self?.highlightedNodeId = nil }
            }
        }
    }

    // MARK: - Actions

    func toggleFavorite(_ node: MessageNode) {
        FavoriteTags.setFavorite(node, !node.isFavorite)
    }

    func togglePin(_ node: MessageNode) {
        if node.isPinned {
            node.isPinned = false
            node.pinnedAt = nil
        } else {
            node.isPinned = true
            node.pinnedAt = Date()
        }
    }

    func unpinAll() {
        for node in currentPath where node.isPinned {
            node.isPinned = false
            node.pinnedAt = nil
        }
    }

    /// 当前对话 pin 的节点，按 pinnedAt 降序（新 → 旧），过滤软删除
    /// 置顶按聊天里的先后（0 = 最旧）：顶栏状态岛照 Telegram 用这个顺序翻（粟粟 09-28）
    var pinnedNodesInChatOrder: [MessageNode] {
        currentPath.filter { $0.isPinned && !$0.isTrashed }
    }

    var pinnedNodes: [MessageNode] {
        currentPath
            .filter { $0.isPinned && !$0.isTrashed }
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    func softDelete(_ node: MessageNode) {
        // 1) Instantly remove from display path (single-item diff, no lag)
        let deletedId = node.id
        currentPath.removeAll { $0.id == deletedId }

        // 2) Defer SwiftData mutation so UI updates first, then notify sidebar
        let conv = selectedConversation
        DispatchQueue.main.async { [self] in
            node.isTrashed = true
            node.trashedAt = Date()
            // 软删除是"内容改动"，同步更新对话的 updateTime + nodeCount + 走 3s
            // debounce 重排（之前漏了，导致 sidebar 行里 nodeCount 不减、位置不变）
            if let conv {
                conv.updateTime = Date()
                conv.nodeCount = currentPath.filter {
                    ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent
                }.count
                markConversationDirty()
            }
            // 显式落盘：只靠 autosave 时 didSave 发不发没证实（S5 探针），全文索引靠 didSave 跟进回收站状态
            try? node.modelContext?.save()
        }
    }

    // MARK: - 多选批量（research-multi-select-bubbles §3）

    /// 批量收藏 = 标星：有没收藏的 → 全部收藏；已经全收藏了 → 全部取消（Telegram / 相册同逻辑）。返回收藏后的状态
    @discardableResult
    func setFavorite(_ nodes: [MessageNode]) -> Bool {
        let on = nodes.contains { !$0.isFavorite }
        for node in nodes where node.isFavorite != on { node.isFavorite = on }
        try? nodes.first?.modelContext?.save()
        return on
    }

    /// 批量软删：一次 path 变更 + 一次计数 + 一次 save（不循环调单条 softDelete——那样每条一轮 path diff + save）。
    /// 只删选中的这几条，不删子树；语义同单条
    func softDelete(nodes: [MessageNode]) {
        guard !nodes.isEmpty else { return }
        let ids = Set(nodes.map(\.id))
        currentPath.removeAll { ids.contains($0.id) }

        let conv = selectedConversation
        DispatchQueue.main.async { [self] in
            let now = Date()
            for node in nodes {
                node.isTrashed = true
                node.trashedAt = now
            }
            if let conv {
                conv.updateTime = now
                conv.nodeCount = currentPath.filter {
                    ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent
                }.count
                markConversationDirty()
            }
            try? nodes.first?.modelContext?.save()
        }
    }

    func restore(_ node: MessageNode) {
        node.isTrashed = false
        node.trashedAt = nil
        if selectedConversation != nil {
            nodeMap[node.id] = node
            buildEffectiveChildrenMap()
            rebuildPath()
        }
    }

    // MARK: - Conversation Delete / Restore

    func softDeleteConversation(_ conversation: Conversation) {
        conversation.isTrashed = true
        conversation.trashedAt = Date()
        // S4：碰 updateTime 让软删状态走 LWW 传播到对端（之前漏了 → 删除不同步）
        conversation.updateTime = Date()
        // S4.5 续：必须显式 save——SyncEngine 后台 context 与主 context 隔离，
        // autosave 延迟下后台 fetch 读到的还是 isTrashed=false，云文档不会带新状态
        // → 对端永远收不到删除（粟粟 2026-06-14 实测"手机删 Mac 没删"的根因）
        // 段④：拿它当「上个窗口」的新窗，副本一起清（恢复也不复活）
        if let context = conversation.modelContext {
            PreviousWindowPicker.invalidateCopies(of: [conversation.id], context: context)
        }
        try? conversation.modelContext?.save()
        if selectedConversation?.id == conversation.id {
            selectedConversation = nil
            currentPath = []
            timeDividerCache.reset()
            bubbleRunCache.reset()
        }
    }

    func restoreConversation(_ conversation: Conversation) {
        conversation.isTrashed = false
        conversation.trashedAt = nil
        // S4：恢复也要传播（updateTime 新者赢，对端跟着恢复）
        conversation.updateTime = Date()
        // 同 softDeleteConversation：必须显式 save 让后台 SyncEngine 看到
        try? conversation.modelContext?.save()
    }

    func permanentlyDeleteConversation(_ conversation: Conversation, context: ModelContext) {
        let convId = conversation.id
        let convProfileId = conversation.profileId

        // S4：先写墓碑+删云文档+清指纹。
        // 必须在删本地数据前——保证就算后面崩了，墓碑也已落盘，对端下次同步仍能收到删除指令。
        if SyncStore.isEnabled(profileId: convProfileId) {
            SyncStore.recordPermanentDeletion(conversationId: convId, profileId: convProfileId)
        }

        // 清理上下文摘要
        ContextSummarizer.clear(conversationId: convId, profileId: convProfileId)

        // Delete all MessageNodes belonging to this conversation
        let nodeDescriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in
                node.conversationId == convId && node.profileId == convProfileId
            }
        )
        if let nodes = try? context.fetch(nodeDescriptor) {
            let sources = Set(nodes.filter { $0.role == "user" }.flatMap { node in
                (node.segments?.audioRefs ?? []).map { node.profileId + ":" + $0.path }
            })
            if !sources.isEmpty {
                MainActor.assumeIsolated { VoiceProsodyStore.shared.forget(sources: sources) }
            }
            for node in nodes { context.delete(node) }
        }

        // Delete all FavoriteItems referencing this conversation
        let favDescriptor = FetchDescriptor<FavoriteItem>(
            predicate: #Predicate<FavoriteItem> { item in
                item.conversationId == convId && item.profileId == convProfileId
            }
        )
        if let items = try? context.fetch(favDescriptor) {
            for item in items { context.delete(item) }
        }

        // Clear selection if needed
        if selectedConversation?.id == convId {
            selectedConversation = nil
            currentPath = []
            timeDividerCache.reset()
            bubbleRunCache.reset()
        }

        // 附件一份存储：彻底删除时连同文件库附件目录一起清（软删/回收站不走这里）
        AttachmentStore.deleteConversationAttachments(conversationId: convId, profileId: convProfileId)
        // 只属于这个对话的加密值一起删（plan-secure-ask §5）
        SecretVault.deleteAll(conversationId: convId)

        #if os(iOS)
        PushIdentityWriter.removeConversation(chatId: convId)
        #endif

        ccDedupCache.removeValue(forKey: convId)   // 跟随 conversation 销毁清掉 cache 条目
        // 段④：拿它当「上个窗口」的新窗，副本一起清
        PreviousWindowPicker.invalidateCopies(of: [convId], context: context)

        context.delete(conversation)
        try? context.save()
    }

    func permanentlyDeleteNode(_ node: MessageNode, context: ModelContext) {
        let nodeId = node.id
        let nodeProfileId = node.profileId
        forgetVoiceProsody(node)

        // Delete FavoriteItems referencing this node
        let favDescriptor = FetchDescriptor<FavoriteItem>(
            predicate: #Predicate<FavoriteItem> { item in
                item.nodeId == nodeId && item.profileId == nodeProfileId
            }
        )
        if let items = try? context.fetch(favDescriptor) {
            for item in items { context.delete(item) }
        }

        context.delete(node)
    }

    /// 永久删除用户语音时移除基线样本；转写任务迟到也不能把这份声音重新学回来。
    private func forgetVoiceProsody(_ node: MessageNode) {
        guard node.role == "user", let segments = node.segments else { return }
        let sources = segments.audioRefs.map { node.profileId + ":" + $0.path }
        guard !sources.isEmpty else { return }
        MainActor.assumeIsolated {
            for source in sources { VoiceProsodyStore.shared.forget(source: source) }
        }
    }

    /// 对话的隐形根（新建对话时建的空 system 节点，还没挂孩子）
    private func invisibleRootId() -> String? {
        if let rid = cachedRootId, let root = nodeMap[rid], Self.isInvisibleRoot(root), childrenIds(for: rid).isEmpty {
            return rid
        }
        return nodeMap.values.first { Self.isInvisibleRoot($0) && childrenIds(for: $0.id).isEmpty }?.id
    }

    private static func isInvisibleRoot(_ node: MessageNode) -> Bool {
        node.role == "system" && node.parentId == nil && node.content.isEmpty
    }

    /// 老对话的第一条消息没有父节点（2026-09 前 sendMessage 的写法）：编辑前把它挂到隐形根下——
    /// 复用空着的隐形根，没有就建一个。之后它和编辑出的新版本就是同一个根下的兄弟
    private func adoptUnderInvisibleRoot(_ node: MessageNode, conversation: Conversation, context: ModelContext) -> String {
        let rootId: String
        if let rid = invisibleRootId(), rid != node.id {
            rootId = rid
        } else {
            let root = MessageNode(id: UUID().uuidString, role: "system", content: "", contentType: "text",
                                   createTime: node.createTime, parentId: nil, childrenIds: [],
                                   conversationId: conversation.id, profileId: conversation.profileId)
            context.insert(root)
            nodeMap[root.id] = root
            rootId = root.id
        }
        node.parentId = rootId
        if let root = nodeMap[rootId], !root.childrenIds.contains(node.id) {
            root.childrenIds.append(node.id)
        }
        effectiveChildrenMap[rootId, default: []].append(node.id)
        cachedRootId = rootId
        return rootId
    }

    private func findRootId() -> String? {
        // 确定性 root 选择，与导出器共用单一实现（避免 dict 迭代序"抽盲盒"）
        MarkdownExporter.deterministicRootId(nodeMap: nodeMap)
    }

    // MARK: - Export

    /// Export the currently loaded conversation as Markdown
    func exportMarkdown(mode: ExportPathMode, userName: String, assistantName: String) -> String {
        guard let rootId = cachedRootId ?? findRootId() else { return "" }
        return MarkdownExporter.export(
            nodeMap: nodeMap,
            effectiveChildren: effectiveChildrenMap,
            rootId: rootId,
            mainPathIds: mainPathIds,
            currentPath: currentPath,
            mode: mode,
            userName: userName,
            assistantName: assistantName
        )
    }

    // MARK: - Chat (API)

    var providerRouter = ProviderRouter()
    let memoryStore: MemoryStore = SwiftDataMemoryStore()
    /// Content being streamed for the current assistant response
    var streamingText = "" {
        didSet {
            let hasText = !streamingText.isEmpty
            if streamingHasText != hasText { streamingHasText = hasText }
        }
    }
    private(set) var streamingHasText = false
    private var assistantTurnStatus: String?

    /// 通话流式朗读钩子（plan-voice-providers V4c）：CallScreen 开场注入、挂断清空。
    /// 不在通话（`CallSession.activeSnapshot` false）时 onToken 里只多一次 bool 判断。主线程调。
    enum CallStreamEvent { case delta(String), segmentBreak, externalReply(String, CCCallReply) }
    @ObservationIgnored var callStreamHook: ((CallStreamEvent, _ nodeId: String, _ conversationId: String) -> Void)?
    @ObservationIgnored private var callReplyRequests: [String: String] = [:]
    @ObservationIgnored var callReplyCanTrack: ((_ requestId: String, _ conversationId: String) -> Bool)?

    func clearCallReplyTracking() { callReplyRequests.removeAll() }

    func callReplyNodeId(conversationId: String) -> String? {
        guard activeConversationId == conversationId, assistantTurnInFlight else { return nil }
        return activeAssistantNodeId
    }

    @MainActor
    func cancelCallReply(conversationId: String, context: ModelContext) {
        guard callReplyNodeId(conversationId: conversationId) != nil else { return }
        cancelAssistantTurn(context: context, drainQueued: false)
    }

    // MARK: - Assistant Turn Lifecycle
    //
    // providerRouter.isStreaming 只表示底层单次 stream 在跑；工具执行 / 多轮 tool loop
    // 的空窗期它是 false，此时放行发送会让 API history 出现 user+user 连排（上一轮
    // assistant placeholder 为空被 buildAPIMessages 过滤），模型把两条都当待办 →
    // fs_append 重复执行。turn 级状态从 sendMessage 到最终 onComplete/onError/
    // maxToolRounds/cancel 全程 true。Plan: docs/plan-consecutive-user-turns-fix.md

    /// 当前 assistant turn（含工具循环全程）是否进行中
    var assistantTurnInFlight = false {
        didSet {
            if assistantTurnInFlight, !oldValue {
                turnGeneration += 1
                assistantTurnID = turnGeneration
                assistantTurnStatus = nil
            }
            if !assistantTurnInFlight, assistantTurnStatus != nil { assistantTurnStatus = nil }
            if assistantTurnInFlight != oldValue {
                // 起 turn 的入口都从 selectedConversation 起（send / regenerate / editAndResend / trigger）
                ProfileTurnActivity.shared.generatingProfileId = assistantTurnInFlight ? selectedConversation?.profileId : nil
            }
            #if os(iOS)
            ChatParagraphPrewarm.turnInFlight = assistantTurnInFlight   // perf L1 ① 闲置门：流式中不补段落视图池
            #endif
        }
    }

    private var assistantTurnID = 0
    var currentTurnID: Int? { assistantTurnInFlight ? assistantTurnID : nil }

    /// 进度卡（粟粟 10-03「都按推荐」）：按对话记工具循环里真实发生的事；只有工具循环写，turn 收口就清
    private(set) var turnActivities: [String: TurnActivity] = [:]

    /// 进度卡读这个：该对话的 turn 还在跑、且已经开始调工具才有
    func turnActivity(for conversationId: String) -> TurnActivity? {
        guard assistantTurnInFlight, activeConversationId == conversationId,
              let a = turnActivities[conversationId], a.round > 0 else { return nil }
        return a
    }

    /// 工具循环每往 segs 里记一段就喂一次；没变化不写（@Observable 赋值即通知）
    private func noteTurnSegment(_ seg: MessageSegment, conversationId: String) {
        guard var a = turnActivities[conversationId] else { return }
        let before = a
        a.observe(seg)
        if a != before { turnActivities[conversationId] = a }
    }

    func currentTurnNode(for conversationId: String) -> MessageNode? {
        guard let id = callReplyNodeId(conversationId: conversationId) else { return nil }
        return nodeMap[id]
    }

    func turnStatus(for conversationId: String) -> String? {
        guard assistantTurnInFlight, activeConversationId == conversationId else { return nil }
        return assistantTurnStatus
    }

    private func acceptTurnStatus(_ text: String, conversationId: String, nodeId: String, generation: Int) -> Bool {
        guard generation == turnGeneration, selectedConversation?.id == conversationId,
              isNodeStreaming(nodeId: nodeId, conversationId: conversationId) else { return false }
        if assistantTurnStatus != text { assistantTurnStatus = text }
        return true
    }

    // MARK: - 问问题（ask_user）暂停态

    /// ask_user 暂停：工具循环停在本轮等用户点选，恢复参数全打包（runStreamingTurn 全参）。
    /// 内存态不落盘——杀 app 丢弃，节点里留孤儿 toolUse（渲染跳过，历史压平降级工具名行）。
    struct PendingUserQuestion {
        struct AskItem {
            let call: ToolCallBlock
            let questions: [AskUserTool.ParsedQuestion]
        }
        let conversationId: String
        let askItems: [AskItem]
        /// 全部题目答案，跨 askItems 平铺按序对齐；nil = 未答（回灌时按跳过拼文）
        var collectedAnswers: [AskUserTool.AnswerValue?]
        let payload: (messages: [(role: String, content: String)], systemPrompt: String?, sampling: SamplingParams, additionalHeaders: [String: String], imageMap: [String: [PendingChatAttachment]], ordered: [PromptMessage])
        let systemPrompt: String?
        let model: ProviderModel
        let providerManager: ProviderManager
        let conversation: Conversation
        let assistantNode: MessageNode
        let assistantNodeId: String
        let profile: Profile
        let preset: Preset
        let context: ModelContext
        let tools: [[String: Any]]?
        let toolTurns: [ToolTurn]
        let round: Int
        let calls: [ToolCallBlock]
        let otherResults: [ToolResultBlock]
        /// thinking 回传：暂停那一次回复的原样块，恢复时拼进 ToolTurn
        let assistantContent: [[String: Any]]?
        /// 那一次回复的 thinking_tokens（保险闸按输入估回传的思考）
        let thinkingTokens: Int?
        /// OpenAI 兼容路那一次回复的思考（恢复时拼进 ToolTurn，续轮回传）
        let reasoning: ReasoningCapture?

        var allQuestions: [AskUserTool.ParsedQuestion] { askItems.flatMap(\.questions) }
    }

    /// 非 nil = 选择卡挂起中（sheet 由 CardFlowView 按 conversationId 匹配呈现）
    var pendingUserQuestion: PendingUserQuestion? = nil

    /// CC 桥选择卡（plan-问问题-cc桥）：hub 推来的 AskUserQuestion 题面。
    /// 无恢复参数——答案发 WS 帧回 hub 驱动 tmux TUI，Q/A 气泡等 resolved 帧统一落。
    struct PendingCCQuestion {
        let chatId: String
        let toolUseId: String
        let questions: [AskUserTool.ParsedQuestion]
        var collectedAnswers: [AskUserTool.AnswerValue?]
        /// 问这题的那台（B3.2）：回答 / 跳过回它，不按对话现在绑哪台
        let origin: CCHubOrigin
    }
    var pendingCCQuestion: PendingCCQuestion? = nil

    /// 一次交互发生在哪台 hub 上（B3.2）：槽位 id + 当时的配对代次 + 交互代次（换目标 / Mac 本机切换都推进，impl1 #4）+ 当时记下的 hub_id；
    /// verified / connectionIdentity = 这一刻那条连接核准了没有、核准时 hello 报的 hub_id（不是 defaults 里的历史值）
    struct CCHubOrigin: Equatable {
        let hubId: String
        let gen: Int
        let epoch: Int
        let identity: String?
        let verified: Bool
        let connectionIdentity: String?

        init(_ client: CCBridgeWebSocketClient) {
            hubId = client.hubId
            gen = CCHubPairingStore.gen(client.defaults)
            epoch = client.interactionEpoch
            identity = client.defaults.string(forKey: CCHubPairingStore.hubIdentityKey)
            verified = client.isIdentityVerified
            connectionIdentity = client.verifiedHubIdentity
        }

        /// now 那条连接还是不是问问题的那台：没核准一律不是（不进身份闸的出站暂存）；hub_id 矛盾一律不是；
        /// 配对代次、交互代次都没变 = 同一个目标；代次变了只认「当前连接核准时 hello 报的 hub_id」= 问题来源那台（recheck1 #4）
        func isSameMachine(as now: CCHubOrigin) -> Bool {
            guard now.verified else { return false }
            if let identity, let other = now.identity, identity != other { return false }
            if gen == now.gen && epoch == now.epoch { return true }
            guard let identity, let live = now.connectionIdentity else { return false }
            return identity == live
        }
    }

    /// 回到原来那台：那台还在、当前连接核准过、还是同一台才给连接；否则提示、不发
    @MainActor
    private func ccClient(backTo origin: CCHubOrigin) -> CCBridgeWebSocketClient? {
        // 当前连接还没核对完身份（Mac 刚切到内嵌 hub、hello 还没到）也算用不了：不进身份闸的出站暂存
        guard case .success(let client) = ccRoute(hubId: origin.hubId), client.isIdentityVerified else {
            transientNotice = TransientNotice("问这个问题的那台电脑现在用不了，答案没发出去")
            return nil
        }
        guard origin.isSameMachine(as: CCHubOrigin(client)) else {
            transientNotice = TransientNotice("问这个问题的那台电脑已经换了，答案没发出去")
            return nil
        }
        return client
    }

    /// sheet 的统一题面源（API 优先——同时挂起时 API 卡先出，CC 卡等它收）
    var activeAskQuestions: [AskUserTool.ParsedQuestion]? {
        if let p = pendingUserQuestion { return p.allQuestions }
        if let c = pendingCCQuestion { return c.questions }
        return nil
    }

    /// sheet 记录单题答案（index 跨题面平铺）
    @MainActor
    func recordUserAnswer(_ answer: AskUserTool.AnswerValue?, at index: Int) {
        if pendingUserQuestion != nil {
            guard pendingUserQuestion?.collectedAnswers.indices.contains(index) == true else { return }
            pendingUserQuestion?.collectedAnswers[index] = answer
        } else {
            guard pendingCCQuestion?.collectedAnswers.indices.contains(index) == true else { return }
            pendingCCQuestion?.collectedAnswers[index] = answer
        }
    }

    /// sheet 全部答完的出口。API=回灌工具循环；CC=答案帧回 hub（气泡等 resolved 帧）。
    @MainActor
    func completeActiveAskCard() {
        if pendingUserQuestion != nil { resumeUserQuestion(); return }
        guard let cc = pendingCCQuestion else { return }
        pendingCCQuestion = nil
        let answers: [[String: Any]] = zip(cc.questions, cc.collectedAnswers).map { _, v in
            switch v {
            case .options(let idxs): return ["indices": idxs]
            case .text(let s): return ["text": s]
            case nil: return [:]   // 不应出现（completeActiveAskCard 只在全答后调）；hub 侧校验兜底
            }
        }
        ccClient(backTo: cc.origin)?.sendAskUserAnswer(toolUseId: cc.toolUseId, answers: answers, verifiedOnly: true)
    }

    /// sheet X/拖拽提前关的出口。API=已答保留剩余跳过回灌；CC=整卡跳过（hub 发 Esc，TUI 语义所限）。
    @MainActor
    func dismissActiveAskCard() {
        if pendingUserQuestion != nil { resumeUserQuestion(); return }
        guard let cc = pendingCCQuestion else { return }
        pendingCCQuestion = nil
        ccClient(backTo: cc.origin)?.sendAskUserAnswer(toolUseId: cc.toolUseId, answers: nil, skip: true, verifiedOnly: true)
    }

    /// 问问题统一出口：答完 / X / 拖拽关闭都走这里（未答题自动按跳过拼文，已答保留——方案 a）。
    /// stop 按钮 / 楼层切换走 cancel 路径直接清 pending 不经这里。
    ///
    /// 官端同款结构：Q/A 落成**真实 user 消息节点**（100% 复用用户气泡渲染，历史重建天然带上），
    /// AI 接话进新的 assistant 节点。原 assistant 节点上仍存 toolUse/toolResult segments 做 API 痕迹
    /// （渲染隐藏）；API 侧回灌走 toolTurns 配对，与节点结构无关。
    @MainActor
    func resumeUserQuestion() {
        guard let pending = pendingUserQuestion else { return }
        pendingUserQuestion = nil
        var results = pending.otherResults
        var segs = pending.assistantNode.segments ?? []
        var qaTexts: [String] = []
        var cursor = 0
        for item in pending.askItems {
            let values = Array(pending.collectedAnswers[cursor ..< cursor + item.questions.count])
            cursor += item.questions.count
            let answers: [String?] = zip(item.questions, values).map { q, v in v?.displayString(options: q.options) }
            let text = AskUserTool.resultText(questions: item.questions, answers: answers)
            qaTexts.append(text)
            segs.append(.toolResult(toolUseId: item.call.id, text: text, isError: false, integrationName: "问问题"))
            results.append(ToolResultBlock(toolUseId: item.call.id, text: text, isError: false))
        }
        pending.assistantNode.setSegments(segs)

        let conversation = pending.conversation
        let userNode = MessageNode(
            id: UUID().uuidString, role: "user",
            content: qaTexts.joined(separator: "\n\n"), contentType: "text",
            createTime: Date(), parentId: pending.assistantNode.id, childrenIds: [],
            conversationId: conversation.id, profileId: conversation.profileId
        )
        pending.context.insert(userNode)
        pending.assistantNode.childrenIds.append(userNode.id)
        let newAssistantId = UUID().uuidString
        let newAssistant = MessageNode(
            id: newAssistantId, role: "assistant",
            content: "", contentType: "text",
            createTime: Date(), parentId: userNode.id, childrenIds: [],
            conversationId: conversation.id, profileId: conversation.profileId
        )
        pending.context.insert(newAssistant)
        userNode.childrenIds.append(newAssistantId)
        conversation.updateTime = Date()
        // 回复绑定发起它的那条 assistant：用户中途切了支就只落库，不把她拉回这条（③b）
        let isCurrent = selectedConversation?.id == conversation.id
        let onDisplayedPath = isCurrent && displayLeafId == pending.assistantNode.id
        // 展示态只在还停在这场对话时更新（sheet 按 conversationId 匹配，正常必然在；防御切走的竞态）
        if isCurrent {
            nodeMap[userNode.id] = userNode
            nodeMap[newAssistantId] = newAssistant
            effectiveChildrenMap[userNode.id] = [newAssistantId]
            effectiveChildrenMap[pending.assistantNode.id, default: []].append(userNode.id)
            effectiveChildrenMap[newAssistantId] = []
        }
        if onDisplayedPath {
            commitSelection(to: newAssistantId, conversation: conversation)
            currentPath.append(userNode)
            currentPath.append(newAssistant)
            markPop(userNode.id)
            scrollToNodeId = userNode.id
        } else if conversation.currentNodeId == pending.assistantNode.id {
            conversation.currentNodeId = newAssistantId
        }
        activeAssistantNodeId = newAssistantId
        streamingText = ""
        try? pending.context.save()

        continueToolLoop(
            payload: pending.payload, systemPrompt: pending.systemPrompt,
            model: pending.model, providerManager: pending.providerManager,
            conversation: conversation, assistantNode: newAssistant, assistantNodeId: newAssistantId,
            profile: pending.profile, preset: pending.preset, context: pending.context,
            tools: pending.tools,
            toolTurns: pending.toolTurns + [ToolTurn(calls: pending.calls, results: results, assistantContent: pending.assistantContent,
                                                     thinkingTokens: pending.thinkingTokens, reasoning: pending.reasoning)],
            round: pending.round + 1
        )
    }

    /// 当前**选中对话**是否正在等待 AI 回复。assistantTurnInFlight 全局单值（设计是
    /// 串行单流：pendingSends 队列跨对话），UI 必须按 activeConversationId 隔离否则
    /// 切到别的对话也会显示"暂停"按钮，骗用户以为这个对话也在跑。
    var isCurrentConvResponding: Bool {
        assistantTurnInFlight && activeConversationId == selectedConversation?.id
    }

    /// Phase 4 流式 source 判定：bubble 是否当前流式 turn 的 assistant 节点。
    /// 用 turn-level 三元 (conversationId, nodeId, assistantTurnInFlight) 而不是 provider 级
    /// providerRouter.isStreaming——后者在 tool 间隙 false，view 会闪。
    /// 跨文件访问点（StreamingMarkdownSource / CardFlowView.makeBubbleView）调本方法，
    /// 不直接读 activeAssistantNodeId/activeConversationId（private）。
    func isNodeStreaming(nodeId: String, conversationId: String) -> Bool {
        guard activeConversationId == conversationId else { return false }
        guard activeAssistantNodeId == nodeId else { return false }
        return assistantTurnInFlight
    }

    /// 本 turn 内 recall 调用计数（连环翻页熔断，finishAssistantTurn 清零）
    private var recallCallsThisTurn = 0
    /// 本 turn 内 chrome_read / site_query 合计次数（plan-opencli-in-app：每轮最多 6 次）
    private var chromeBridgeCallsThisTurn = 0
    /// AI 操作浏览器（plan-ai-browser-operate）：每轮合计
    private var browserOperateCallsThisTurn = 0
    private var lastRecallLayer = "原文"
    /// 连续几轮工具参数被输出上限截断（plan-output-token-cap 2-7）：到 2 就停，不空转到 8 轮
    private var toolTruncationStreak = 0
    /// in-flight 期间用户发的消息排队，turn 结束自动补发
    var pendingSends: [PendingSend] = []
    /// §13 待捎带箱（测试注入独立实例；产品用 shared）
    @ObservationIgnored private var cardEventOutboxOverride: ChatCardEventOutbox?
    @MainActor var cardEventOutbox: ChatCardEventOutbox {
        get { cardEventOutboxOverride ?? .shared }
        set { cardEventOutboxOverride = newValue }
    }
    /// 进行中的 API 回复（收口时剥 react 块 / 撤空泡 / 还事件用；节点 id → 发起时的节点、对话、context）
    @ObservationIgnored private var reactionTurns: [String: ReactionTurn] = [:]
    /// 还挂着收口登记的回复节点（测试核对用）
    var pendingReactionTurnIds: Set<String> { Set(reactionTurns.keys) }
    /// 触发事件是从待捎带箱取出来的那些回复节点（表情触发那轮）；只有它们没落地时事件才还回箱里
    @ObservationIgnored private var reactionEventOwners: Set<String> = []
    /// 10-29 表情回应存储（测试注入独立实例；产品用 shared）
    @ObservationIgnored private var reactionStoreOverride: ChatReactionStore?
    @MainActor var reactionStore: ChatReactionStore {
        get { reactionStoreOverride ?? .shared }
        set { reactionStoreOverride = newValue }
    }
    /// §13 网页卡 mp.ask：往输入框追加一句（ChatInputBar 接手后清掉）
    var composerInsert: ComposerInsert?
    /// 表单卡提交即发（粟粟 10-03）：ChatInputBar 接手，只发这张卡
    var cardSendRequest: CardSendRequest?
    /// 报错「去改」（推理档不收）：待输入条打开模型 / 思考强度选择器。输入条不在树上（贴纸面板 / 查找 / 多选）时一直挂着，
    /// 输入条重新出现时接手并清掉
    var modelPickerRequested = false
    /// CC 收口即发（plan-跨对话排队）：发出后等回复中的对话 → 弹跳点等待泡。
    /// 纯 UI 状态不阻塞任何发送；insertProactiveAssistantMessage 落地时清，10 分钟兜底静默清。
    var ccWaitingSince: [String: Date] = [:]
    /// 等回复的那条发到了哪台（b4 #9：改连提示按来源判，连改两次不把 A 上的算到 B 头上）
    @ObservationIgnored var ccWaitingHub: [String: String] = [:]
    /// CC 回复落地时起标题要用（落地回调在 ContentView，那里刻意不持有 ProviderManager）；发 CC 时记一下
    @ObservationIgnored weak var ccTitleProviderManager: ProviderManager?
    /// 最近一条 CC 回复落地的时间（老 hub 没有阶段帧时判忙用，见 isCCTurnBusy）
    @ObservationIgnored var ccLastReplyAt: [String: Date] = [:]
    /// V1（plan-cc-reactions-1105 §0）：CC 忙时塞进去的消息会并进当前轮。没有阶段帧时，回复落地后这么久内也当 CC 还在跑
    @ObservationIgnored var ccReplySettleGrace: TimeInterval = 3
    /// 只贴了表情、没留节点的 CC 回复 id（测试注入独立 suite）
    @ObservationIgnored var ccReactOnlyReplies = CCReactOnlyReplies()
    /// cancel 时定位要写「（已停止）」闭合的节点
    private var activeAssistantNodeId: String?
    /// 正在回复的对话（计时器投递跨窗口判忙要读，故非 private）
    var activeConversationId: String?
    @ObservationIgnored var wikiInjectionCache = WikiInjectionCache.shared
    private struct PromptPreparation {
        let id: UUID
        let conversation: Conversation
        let target: MessageNode
        let context: ModelContext
        let ownsTurn: Bool
        let abortLeafId: String?
        let abortPath: [MessageNode]?
        let markCCUnsentOnAbort: Bool
        var task: Task<Void, Never>?
    }
    private struct QueuedCCSend {
        let enqueueOrder: UInt64
        let isCC: Bool
        let recovery: PendingSend?
        let run: @MainActor () -> Void
    }
    @ObservationIgnored private var promptPreparations: [UUID: PromptPreparation] = [:]
    @ObservationIgnored private var activePromptPreparationId: UUID?
    @ObservationIgnored private var ccPreparationTails: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var queuedCCSends: [String: [QueuedCCSend]] = [:]
    @ObservationIgnored private var nextSendOrder: UInt64 = 0

    private func allocateSendOrder() -> UInt64 {
        nextSendOrder += 1
        return nextSendOrder
    }
    /// 主 hub 的连接（单测注入替身）。附加 hub 的连接从 ccHubRegistry 取（plan-multi-hub B3.1）
    @ObservationIgnored var ccBridgeClient = CCBridgeWebSocketClient.shared
    /// nil = CCHubRegistry.shared（单测注入）
    @ObservationIgnored var ccHubRegistry: CCHubRegistry?
    /// 对话最近在哪几台 hub 上发过东西（B3.2 / impl1 #13，持久、带过期、带 hub_id）：改绑后 / 重启后原来那台迟到的回包据此照收。单测注入
    @ObservationIgnored var ccSentLedger = CCSentHubLedger(defaults: .standard)

    @MainActor private var hubRegistry: CCHubRegistry { ccHubRegistry ?? .shared }

    /// 这台 hub 的连接：主 hub = ccBridgeClient（照旧）；删了 / 待配对 / 换了机器、待绑定 → 失败，不回落主 hub。
    /// 主 hub 待配对 / 换了机器跟 Registry.route 一样报出来（b4 #4），正常时照旧
    @MainActor
    func ccRoute(hubId: String) -> Result<CCBridgeWebSocketClient, CCHubRegistry.Unavailable> {
        guard hubId == CCHubRegistry.primaryId else { return hubRegistry.route(hubId) }
        if case .failure(let why) = hubRegistry.route(hubId) { return .failure(why) }
        return .success(ccBridgeClient)
    }

    /// 那台现在记下的 hub_id（主 hub = ccBridgeClient 的存储）
    @MainActor
    private func ccIdentity(ofHub hubId: String) -> String? {
        hubId == CCHubRegistry.primaryId ? ccBridgeClient.defaults.string(forKey: CCHubPairingStore.hubIdentityKey) : hubRegistry.identity(of: hubId)
    }

    /// 这条对话现在发不了的原因（nil = 能发）。B4 的输入框提示读它
    @MainActor
    func ccSendBlocker(for conversation: Conversation) -> CCHubRegistry.Unavailable? {
        if case .failure(let why) = ccRoute(hubId: CCHubRegistry.hubId(of: conversation)) { return why }
        return nil
    }

    /// 这条对话在现在连的那台上还有没回完的（发到这台、还在等的回复 / 这台问的、没答的问题卡）：改连时提示回复会回到那台（B4.4）。
    /// 只说有没有，不数条数（b4 #9：等待只按对话记一个，数不准）
    @MainActor
    func ccHasUnfinished(for conversation: Conversation) -> Bool {
        let hub = CCHubRegistry.hubId(of: conversation)
        let waiting = ccWaitingSince[conversation.id] != nil && ccWaitingHub[conversation.id] == hub
        let question = pendingCCQuestion.map { $0.chatId == conversation.id && $0.origin.hubId == hub } == true
        return waiting || question
    }

    /// 拿这条对话的连接；拿不到就提示原因、返回 nil（调用方不发）
    @MainActor
    private func ccClientOrNotice(for conversation: Conversation) -> CCBridgeWebSocketClient? {
        switch ccRoute(hubId: CCHubRegistry.hubId(of: conversation)) {
        case .success(let client):
            ccSentLedger.record(chatId: conversation.id, hubId: client.hubId,
                                identity: client.defaults.string(forKey: CCHubPairingStore.hubIdentityKey))
            return client
        case .failure(let why):
            BridgeProbe.log("cc send refused chat=\(conversation.id.prefix(8)) hub=\(CCHubRegistry.hubId(of: conversation).prefix(8)) \(why)")
            transientNotice = TransientNotice(why.message)
            return nil
        }
    }

    enum CCFrameVerdict: Equatable {
        case accept
        /// 对话待绑定（同步 / 恢复认不出那台）：这回不收，也不记已收——认出那台、自动绑回后回放还能补上（impl1 #13）
        case retryLater
        /// 对话绑着别的那台：不收，记成已收——以后改绑到这台，回放也不再收改绑前它发的（B7.2 B1）
        case reject
    }

    /// 来源核对（B3.2）：某台 hub 推来的、属于 chatId 的帧收不收。这条对话当前绑这台，或 7 天内在这台（同一个 hub_id）上发过东西 → 收；
    /// 否则（删掉 / 换掉的那台迟到的回包、改绑前那台的阶段帧）丢。本机没有这条对话的照收（后面的落库路径自己丢）
    @MainActor
    func ccFrameVerdict(chatId: String, fromHub hubId: String, context: ModelContext) -> CCFrameVerdict {
        if ccSentLedger.sent(chatId: chatId, hubId: hubId, identity: ccIdentity(ofHub: hubId)) { return .accept }
        let conversation: Conversation?
        if selectedConversation?.id == chatId {
            conversation = selectedConversation
        } else {
            conversation = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == chatId })).first
        }
        guard let conversation else { return .accept }
        let bound = CCHubRegistry.hubId(of: conversation)
        guard bound == hubId else {
            BridgeProbe.log("cc frame dropped chat=\(chatId.prefix(8)) from hub=\(hubId.prefix(8)) bound=\(bound.prefix(8))")
            return bound == CCHubRegistry.unboundHubId ? .retryLater : .reject
        }
        return .accept
    }

    @MainActor
    func acceptsCCFrame(chatId: String, fromHub hubId: String, context: ModelContext) -> Bool {
        ccFrameVerdict(chatId: chatId, fromHub: hubId, context: context) == .accept
    }

    /// reply / thinking 的投递（client 的 onProactiveMessage / onThinking）：收 → apply；返回 client 要不要记已收、推游标——
    /// 收了、绑着别的那台拒收的都记（改绑后回放不再收，B7.2 B1），只有待绑定的不记（认出那台后回放补上，impl1 #13）
    @MainActor
    func deliverCCFrame(chatId: String, fromHub hubId: String, context: ModelContext, apply: () -> Void) -> Bool {
        switch ccFrameVerdict(chatId: chatId, fromHub: hubId, context: context) {
        case .accept:
            apply()
            return true
        case .reject: return true
        case .retryLater: return false
        }
    }

    /// 消息 / 问题卡的来源（持久，R5.2）。单测注入
    @ObservationIgnored var ccOriginLedger = CCChatOriginLedger(defaults: CCChatOriginLedger.store)

    /// 问题卡 / 收账帧（没有持久去重）：对话绑着别的那台时拒过的 (那台, 对话, toolUseId) 记进账本，改绑到它以后 / 重启后再来也不收（B7.2 B1）
    @MainActor
    func acceptsCCAskFrame(chatId: String, toolUseId: String, fromHub hubId: String, context: ModelContext) -> Bool {
        let identity = ccIdentity(ofHub: hubId)
        guard !ccOriginLedger.refusedAsk(chatId: chatId, toolUseId: toolUseId, hubId: hubId, identity: identity) else { return false }
        switch ccFrameVerdict(chatId: chatId, fromHub: hubId, context: context) {
        case .accept: return true
        case .retryLater: return false
        case .reject:
            ccOriginLedger.recordRefusedAsk(chatId: chatId, toolUseId: toolUseId, hubId: hubId, identity: identity)
            return false
        }
    }

    /// edit 收不收：来源核对过了，还要核被改的那条是不是这台推来的（逐条来源，持久）。查不到来源（账本之前落地的 / 过期了）：
    /// 只在这条对话从没改绑过时放行
    @MainActor
    func acceptsCCEdit(chatId: String, ccMessageId: String, fromHub hubId: String, context: ModelContext) -> Bool {
        guard acceptsCCFrame(chatId: chatId, fromHub: hubId, context: context) else { return false }
        let identity = ccIdentity(ofHub: hubId)
        let ok: Bool
        if let origin = ccOriginLedger.messageOrigin(chatId: chatId, messageId: ccMessageId) {
            ok = origin.hub == hubId && (origin.identity == nil || identity == nil || origin.identity == identity)
        } else {
            ok = !CCChatOriginLedger.wasRebound(chatId: chatId, defaults: ccOriginLedger.defaults)
        }
        if !ok { BridgeProbe.log("cc edit dropped chat=\(chatId.prefix(8)) msg=\(ccMessageId.prefix(14)) from hub=\(hubId.prefix(8))") }
        return ok
    }
    @ObservationIgnored private var injectionPermissionCenterOverride: PermissionPromptCenter?
    @MainActor var injectionPermissionCenter: PermissionPromptCenter {
        get { injectionPermissionCenterOverride ?? .shared }
        set { injectionPermissionCenterOverride = newValue }
    }
    #if DEBUG
    var promptPreparationTasksForTesting: [Task<Void, Never>] { promptPreparations.values.compactMap(\.task) }
    var displayLeafIdForTesting: String? { displayLeafId }
    #endif

    struct PendingSend: Identifiable {
        let id = UUID()
        let text: String
        let attachments: [PendingChatAttachment]
        let quotePreview: String?
        let quoteReplyTo: String?
        let model: ProviderModel
        let profile: Profile
        let preset: Preset
        let providerManager: ProviderManager
        let context: ModelContext
        let conversationId: String
        var enqueueOrder: UInt64 = 0
    }

    @MainActor
    private func queuePendingSend(
        _ text: String, attachments: [PendingChatAttachment],
        model: ProviderModel, profile: Profile, preset: Preset,
        providerManager: ProviderManager, context: ModelContext, conversationId: String
    ) {
        pendingSends.append(PendingSend(
            text: text, attachments: attachments,
            quotePreview: quotingPreview, quoteReplyTo: quotingReplyTo,
            model: model, profile: profile, preset: preset,
            providerManager: providerManager, context: context,
            conversationId: conversationId, enqueueOrder: allocateSendOrder()
        ))
        clearQuoting()   // 引用已捕获进 pending，输入栏引用条清掉
    }

    /// ✕ 取消排队：移除并返回，UI 把内容写回输入框
    @MainActor
    func cancelPendingSend(id: UUID) -> PendingSend? {
        guard let idx = pendingSends.firstIndex(where: { $0.id == id }) else { return nil }
        return pendingSends.remove(at: idx)
    }

    /// #094：这一请求 400 自愈学到了「这个模型不收 xx」→ 聊天页临时提示胶囊（Q5），之后同地址 + 模型不再出
    private func showParamAdaptationNotice() {
        if let notice = providerRouter.consumeParamAdaptation() {
            transientNotice = TransientNotice("✂️ " + notice)
        }
    }

    /// turn 结束统一出口：清状态 + drain 队列。四个调用点：
    /// onComplete / onError / maxToolRounds / cancelAssistantTurn（regenerate、
    /// editAndResend 的 complete/error 也走这里）。
    /// turn 代际：stop / 切楼层 时 +1。工具循环的异步 handler 在 await 回来后对照它——
    /// 不等就会出现「用户已停止，旧 handler 却接着存结果并再请求模型一轮」（codex 评审阻塞 1）。
    private var turnGeneration = 0

    private struct RecallAttemptContext {
        let requestId: UUID
        let conversation: Conversation
        let turnId: String
        let branchAnchor: String
        let assistantNodeId: String
        var attemptId: String
    }
    private var activeRecallAttempt: RecallAttemptContext?

    private struct CachedRecallReceipt {
        let dataHash: Int
        let data: Data?
        let receipt: RecallTurnReceipt?
    }
    @ObservationIgnored private var recallReceiptCache: [String: CachedRecallReceipt] = [:]
    #if DEBUG
    @ObservationIgnored private(set) var recallReceiptDecodeCount = 0
    #endif

    func cachedRecallReceipt(_ node: MessageNode) -> RecallTurnReceipt? {
        let data = node.recallReceiptData
        let hash = data.hashValue
        if let cached = recallReceiptCache[node.id], cached.dataHash == hash, cached.data == data { return cached.receipt }
        let receipt = data.flatMap { data -> RecallTurnReceipt? in
            #if DEBUG
            recallReceiptDecodeCount += 1
            #endif
            return try? JSONDecoder().decode(RecallTurnReceipt.self, from: data)
        }
        recallReceiptCache[node.id] = CachedRecallReceipt(dataHash: hash, data: data, receipt: receipt)
        return receipt
    }

    private func touchRecallConversation(_ conversation: Conversation) {
        conversation.updateTime = Date(timeIntervalSince1970:
            max(Date().timeIntervalSince1970, conversation.updateTime.timeIntervalSince1970.nextUp))
    }

    /// 账只归回复自己的节点（plan-memory-receipt §2.2）：user 节点只留 decision（CC 加清单），不镜像 attempts / reads
    private func storeRecallReceipt(_ receipt: RecallTurnReceipt, on assistant: MessageNode,
                                    conversation: Conversation, context: ModelContext) {
        assistant.recallReceipt = receipt
        touchRecallConversation(conversation)
        try? context.save()
    }

    /// 路径上同一真实轮最后一条 assistant 回执：`/trigger` / 贴表情的新回复只继承「已生效」这一格
    private func priorAssistantReceipt(onTurn turnId: String) -> RecallTurnReceipt? {
        for node in currentPath.reversed() where node.role == "assistant" {
            guard let receipt = cachedRecallReceipt(node), receipt.decision.turnId == turnId else { continue }
            return receipt
        }
        return nil
    }

    private func prepareRecallAttempt(on assistant: MessageNode, conversation: Conversation, context: ModelContext) -> UUID? {
        guard var receipt = assistant.recallReceipt else { return nil }
        let attemptId = receipt.beginAttempt(deliveryId: receipt.delivery?.id)
        let requestId = UUID()
        activeRecallAttempt = RecallAttemptContext(
            requestId: requestId, conversation: conversation, turnId: receipt.decision.turnId, branchAnchor: receipt.decision.branchAnchor,
            assistantNodeId: assistant.id, attemptId: attemptId)
        storeRecallReceipt(receipt, on: assistant, conversation: conversation, context: context)
        return requestId
    }

    private func submitRecallAttempt(_ requestId: UUID?, on assistant: MessageNode, context: ModelContext) {
        guard var active = activeRecallAttempt, active.requestId == requestId,
              var receipt = assistant.recallReceipt else { return }
        if receipt.attempts.first(where: { $0.id == active.attemptId })?.status != .prepared {
            receipt.finishAttempt(id: active.attemptId, status: .failed)
            active.attemptId = receipt.beginAttempt(deliveryId: receipt.delivery?.id)
        }
        receipt.markAttempt(active.attemptId, status: .submitted)
        activeRecallAttempt = active
        storeRecallReceipt(receipt, on: assistant, conversation: active.conversation, context: context)
    }

    private func respondRecallAttempt(_ requestId: UUID?, conversation: Conversation, assistant: MessageNode,
                                      context: ModelContext) {
        guard let active = activeRecallAttempt, active.requestId == requestId,
              active.conversation.id == conversation.id, active.assistantNodeId == assistant.id,
              var receipt = assistant.recallReceipt,
              receipt.decision.turnId == active.turnId,
              receipt.decision.branchAnchor == active.branchAnchor else { return }
        let wasEffective = receipt.hasEffectiveResponse
        // 真实 user 轮首次响应打戳；切窗后仍按回执 turnId 查原节点，工具续轮不重复推进。
        if !wasEffective, PreviousWindowPicker.isLiveChat(conversation) {
            let turnId = receipt.decision.turnId
            var descriptor = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == turnId })
            descriptor.fetchLimit = 1
            if let user = try? context.fetch(descriptor).first, user.conversationId == conversation.id,
               user.role == "user", !user.isSyntheticRoot {
                conversation.lastRealChatAt = Date()
            }
        }
        var state = conversation.recallState
        let applies = selectedConversation?.id == conversation.id
            && currentPath.contains(where: { $0.id == active.turnId })
            && currentPath.contains(where: { $0.id == assistant.id })
            && state.branchAnchor == active.branchAnchor
        let applied = receipt.recordResponse(attemptId: active.attemptId, state: &state,
                                            currentTurnId: active.turnId, currentBranchAnchor: active.branchAnchor,
                                            applyState: applies)
        if applied { conversation.recallState = state }
        storeRecallReceipt(receipt, on: assistant, conversation: conversation, context: context)
        // 账是回执的投影：首个有效响应才写（重生成 / `/trigger` 的 inherited 已为真，不重写；失败 / 首事件前取消不写）
        if !wasEffective, receipt.hasEffectiveResponse {
            MemoryInjectionMeter.record(profileId: conversation.profileId, receipt: receipt)
        }
    }

    private func finishRecallAttempt(_ requestId: UUID?, on assistant: MessageNode,
                                     status: RecallAttemptStatus, context: ModelContext) {
        guard let active = activeRecallAttempt, active.requestId == requestId,
              var receipt = assistant.recallReceipt else { return }
        receipt.finishAttempt(id: active.attemptId, status: status)
        storeRecallReceipt(receipt, on: assistant, conversation: active.conversation, context: context)
    }

    private func recallPathReceipts() -> [RecallTurnReceipt] {
        var receipts: [RecallTurnReceipt] = []
        var userReceipt: RecallTurnReceipt?
        var selectedReceipt: RecallTurnReceipt?
        var turnId: String?
        func appendTurn() {
            if let receipt = selectedReceipt ?? userReceipt.flatMap({ $0.hasEffectiveResponse ? nil : $0 }) {
                receipts.append(receipt)
            }
        }
        for node in currentPath where !node.isTrashed && !node.isSourceHidden && !node.isSyntheticRoot {
            if node.role == "user" {
                appendTurn()
                turnId = node.id
                userReceipt = cachedRecallReceipt(node)
                selectedReceipt = nil
            } else if node.role == "assistant", let receipt = cachedRecallReceipt(node), receipt.decision.turnId == turnId {
                selectedReceipt = receipt
            }
        }
        appendTurn()
        return receipts
    }

    private func recoverRecallBranch(_ conversation: Conversation, clearActive: Bool) {
        let receipts = recallPathReceipts()
        let cached = conversation.recallState
        let anchor = clearActive ? UUID().uuidString : (cached.branchAnchor.isEmpty ? conversation.id : cached.branchAnchor)
        conversation.recallState = RecallTurnState.recover(receipts: receipts, branchAnchor: anchor, clearActive: clearActive)
    }

    private func finishAssistantTurn(drainQueued: Bool = true) {
        if let nodeId = activeAssistantNodeId {
            MainActor.assumeIsolated { _ = settleReactionTurn(nodeId: nodeId) }
        }
        // CR-3 P3：turn 收口广播（vocab aiNote 回填等旁路消费；error/cancel 也算收口）
        if let nodeId = activeAssistantNodeId, let convId = activeConversationId {
            // 回复写完就登记里面要自动开始的计时器——不等卡片被画出来（锁屏 / 切走也照常计时）
            if let node = nodeMap[nodeId] {
                registerAutoStartTimers(nodeId: nodeId, conversationId: convId,
                                        text: ChatCardIndex.visibleText(content: node.content, segments: node.segments),
                                        sentAt: node.createTime ?? Date())
            }
            NotificationCenter.default.post(
                name: .assistantTurnDidFinish, object: nil,
                userInfo: ["nodeId": nodeId, "conversationId": convId]
            )
            MarkdownRenderCache.shared.noteStreamFinished(nodeId: nodeId)   // perf L1c：翻回静态分支前登记，首见同步解析
        }
        if let convId = activeConversationId { turnActivities[convId] = nil }
        assistantTurnInFlight = false
        activeAssistantNodeId = nil
        activeConversationId = nil
        activeRecallAttempt = nil
        recallCallsThisTurn = 0
        chromeBridgeCallsThisTurn = 0
        browserOperateCallsThisTurn = 0
        Task { @MainActor in BrowserOperateTools.endTurn() }   // 一轮说完：浏览器流光收掉、接管清零
        lastRecallLayer = "原文"
        toolTruncationStreak = 0
        diceToolIssuedIds = []
        if drainQueued { drainPending() }
        MainActor.assumeIsolated { ChatReactionTrigger.shared.turnDidEnd() }   // 10-31：等着的贴表情排在她排队的消息后面
    }

    private func isConversationSendBusy(_ conversationId: String) -> Bool {
        isLoading || failedTreeConversationId == conversationId || ccPreparationTails[conversationId] != nil ||
            (assistantTurnInFlight && activeConversationId == conversationId)
    }

    /// CC 只占准备期；API 占完整 turn。每次发送后按实际占用继续排水。
    private func drainPending() {
        Task { @MainActor in
            guard !self.isLoading else { return }
            while true {
                if let pending = self.pendingSends.first,
                   self.selectedConversation?.id != pending.conversationId {
                    self.pendingSends.removeFirst()
                    self.restoreToDraft(pending)
                    continue
                }
                guard let conversationId = self.selectedConversation?.id,
                      !self.isConversationSendBusy(conversationId) else { return }
                let queued = self.queuedCCSends[conversationId]?.first
                let pending = self.pendingSends.first
                if let queued, pending == nil || queued.enqueueOrder < pending!.enqueueOrder {
                    guard queued.isCC || !self.assistantTurnInFlight else { return }
                    self.queuedCCSends[conversationId]!.removeFirst()
                    if self.queuedCCSends[conversationId]?.isEmpty == true { self.queuedCCSends[conversationId] = nil }
                    queued.run()
                    continue
                }
                guard let pending else { return }
                let isCC = pending.providerManager.provider(for: pending.model)?.type == .ccBridge
                guard isCC || !self.assistantTurnInFlight else { return }
                self.pendingSends.removeFirst()
                self.quotingPreview = pending.quotePreview
                self.quotingReplyTo = pending.quoteReplyTo
                let started = self.sendMessage(
                    pending.text, model: pending.model, profile: pending.profile,
                    preset: pending.preset, providerManager: pending.providerManager,
                    context: pending.context, attachments: pending.attachments
                )
                if started { continue }
                self.clearQuoting()
                self.restoreToDraft(pending)
                return
            }
        }
    }

    /// pending 无法发送时写回该对话的持久化草稿，避免丢内容
    @MainActor
    private func restoreToDraft(_ pending: PendingSend) {
        let targetId = pending.conversationId
        let convs = try? pending.context.fetch(
            FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == targetId })
        )
        guard let conv = convs?.first else { return }
        conv.draftText = conv.draftText.isEmpty ? pending.text : conv.draftText + "\n" + pending.text
        if !pending.attachments.isEmpty {
            let existing = conv.draftAttachmentsData.flatMap {
                try? JSONDecoder().decode([PendingChatAttachment].self, from: $0)
            } ?? []
            if let data = try? JSONEncoder().encode(existing + pending.attachments) {
                conv.draftAttachmentsData = data
            }
        }
        try? pending.context.save()
    }

    /// stop 按钮：取消当前 turn。provider cancel 不回调 onComplete/onError
    /// （ChatService.swift cancel 只杀 task），所以闭合标记必须在这里写——
    /// 否则 placeholder 留空，下一轮 history 又是 user+user。
    /// 已执行的工具副作用（磁盘写入）不回滚。
    @MainActor
    func cancelAssistantTurn(context: ModelContext, drainQueued: Bool = true) {
        let wasPreparing = activePromptPreparationId != nil
        cancelPromptPreparations(conversationId: activeConversationId ?? selectedConversation?.id, drainQueued: drainQueued)
        if wasPreparing { return }
        // 停在请求中途才有这一次回复的块（工具执行间隙停下时，上一次回复的思考已在 onToolCalls 存过）
        let thinking = providerRouter.isStreaming ? providerRouter.lastThinkingSegments : []
        providerRouter.cancel()
        turnGeneration += 1   // 让正在 await 的工具 handler 作废：回来后不存结果、不递归下一轮
        pendingUserQuestion = nil   // 选择卡挂起中按 stop：丢弃问题，孤儿 toolUse 走渲染/历史降级
        // 审批卡挂着时按 stop：算拒绝这一次，工具循环醒来后按 turnGeneration 作废（粟粟 10-03）
        if let conv = activeConversationId ?? selectedConversation?.id { PermissionPromptCenter.shared.cancel(conversationId: conv) }
        // 正在跑的 run_command 一并杀树（工具循环不吃 Task 取消，网络层 cancel 管不到子进程）
        // 两端都要：iOS 后端杀的是 guest 进程组
        if let cid = activeConversationId { RunCommandTool.cancel(conversationId: cid) }
        if let id = activeAssistantNodeId, let node = nodeMap[id] {
            finishRecallAttempt(activeRecallAttempt?.requestId, on: node, status: .cancelled, context: context)
            if let record = providerRouter.lastUsageRecord { UsageCostSettlement.shared.attach(record: record, node: node) }
            let thinkingBase = node.segments.flatMap { $0.isEmpty ? nil : $0.count }
            if var segs = node.segments, !segs.isEmpty {
                if !streamingText.isEmpty { segs.append(.text(streamingText)) }
                segs.append(.text("（已停止）"))
                node.setSegments(segs)
            }
            if node.content.isEmpty {
                node.content = streamingText.isEmpty ? "（已停止）" : streamingText
            }
            Self.attachThinking(thinking, to: node, base: thinkingBase)
            try? context.save()
        }
        streamingText = ""
        finishAssistantTurn(drainQueued: drainQueued)
    }
    // MARK: - Budget (保险闸)
    /// 被拦截时 UI 层通过这个显示 alert；UI 消掉后置 nil
    var budgetBlockedMessage: String? = nil
    /// Pre-send 的估算额度，发送完没 usage 时兜底扣费
    private var pendingEstimatedCost: Double = 0
    /// 上一轮主对话的 token 用量（含 cache 命中数），S1 检查器显示用
    var lastTurnUsage: TokenUsage? = nil

    /// 对话所在文件夹的说明（只进 API 对话；CC 路径不发 system，见 memory project_folder_instructions_cc_gap）
    private func folderInstructions(for conversation: Conversation?, context: ModelContext) -> String? {
        guard let folderId = conversation?.folderId else { return nil }
        var desc = FetchDescriptor<ConversationTag>(predicate: #Predicate<ConversationTag> { $0.id == folderId })
        desc.fetchLimit = 1
        guard let text = (try? context.fetch(desc).first)?.instructions, !text.isEmpty else { return nil }
        return text
    }

    /// 用 PromptAssembler 组装完整 prompt（实发外壳；组装本体在 composePrompt，与检查器共用）
    private func assemblePrompt(
        profile: Profile,
        providerType: ProviderType?,
        preset: Preset,
        excludingNodeId: String? = nil,
        context: ModelContext,
        globalEntries: [WorldBookEntry] = [],
        fileLibraryHint: String? = nil,
        cardGuide: (mode: ChatCardPromptGuide.Mode, tools: Set<String>?) = (.full, nil),
        conversation: Conversation? = nil,
        warmedWiki: WikiInjectionCache.WarmedSnapshot? = nil,
        imagesAllowed: Bool = true
    ) -> (systemPrompt: String?, messages: [(role: String, content: String)], sampling: SamplingParams, imageMap: [String: [PendingChatAttachment]], recallHits: [InjectionHit], ordered: [PromptMessage]) {
        let composed = composePrompt(profile: profile, preset: preset, excludingNodeId: excludingNodeId, context: context,
                                     globalEntries: globalEntries, fileLibraryHint: fileLibraryHint, mode: .send,
                                     cardGuide: cardGuide, conversation: conversation, warmedWiki: warmedWiki, providerType: providerType,
                                     imagesAllowed: imagesAllowed)
        let legacy = PromptMessage.legacyShape(composed.ordered)
        // 卡片只关心 volatile 命中（"这轮想起来了"）；常驻层是"一直记得"，不进卡（S1 走实时组装另有全量）
        let volatileHits = composed.memoryHits.filter { $0.retrieverId != "persistent" }
        return (systemPrompt: legacy.systemPrompt, messages: legacy.messages, sampling: preset.sampling, imageMap: legacy.imageMap, recallHits: volatileHits, ordered: composed.ordered)
    }

    enum ComposeMode { case send, preview }

    /// #089 P0-a：历史以 assistant 结尾时补的那条用户消息（不入库）
    static let previewNextUserPlaceholder = "（你的下一条消息）"
    static let triggerNudge = "（卡片里有新动作，接着回应）"
    static let syntheticUserNodeId = "synthetic-next-user"
    /// 历史里表情触发回合前补的那条 user（不落库）的 id 前缀
    static let reactionEventIdPrefix = "reaction-event:"

    struct ComposedPrompt {
        let segments: [TaggedSegment]
        let memoryHits: [InjectionHit]
        let ordered: [PromptMessage]
        let identity: [String]
        let recallDecision: RecallTurnDecision
        /// 这一轮实际带了什么（send 写回执 / 预览给检查器，同一个 `MemoryDelivery.build`）
        let delivery: RecallDelivery
    }

    /// 账上算「这轮想起来了」的项：X 已送达（页 / 卡 / 碎片）+ 触发关的 legacy 碎片
    static func countsAsRecallHit(_ item: RecallDeliveryItem) -> Bool {
        switch item.kind {
        case RecallDeliveryItem.Kind.page, RecallDeliveryItem.Kind.card,
             RecallDeliveryItem.Kind.fragment, RecallDeliveryItem.Kind.legacyFragment: return true
        default: return false
        }
    }

    /// 实发与检查器共用的唯一组装路径（预览 = 实发铁律）：preview 只跳过副作用（向量回填），其余一行不分叉
    func composePrompt(
        profile: Profile,
        preset: Preset,
        excludingNodeId: String?,
        context: ModelContext,
        globalEntries: [WorldBookEntry],
        fileLibraryHint: String?,
        mode: ComposeMode,
        cardGuide: (mode: ChatCardPromptGuide.Mode, tools: Set<String>?) = (.full, nil),
        conversation: Conversation? = nil,
        warmedWiki: WikiInjectionCache.WarmedSnapshot? = nil,
        providerType: ProviderType? = nil,
        imagesAllowed: Bool = true
    ) -> ComposedPrompt {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("ConversationViewModel.composePrompt") : nil
        defer { if let airSpan { AirProbeRuntime.shared.finishedSection(airSpan) } }
        #endif
        let conversation = conversation ?? selectedConversation
        // 段④：本窗六项（老窗 nil = 照开窗口页）+ 上个窗口快照（组装前复核源窗，失效的发送时写回、不再复活）
        let windowChoices = conversation?.memoryWindowChoices
        var previousWindow = windowChoices?.previousWindow == true ? conversation?.previousWindowSnapshot : nil
        if let snapshot = previousWindow {
            let checked = PreviousWindowPicker.validate(snapshot, profileId: profile.id, context: context)
            if checked != snapshot, mode == .send { conversation?.previousWindowSnapshot = checked }
            previousWindow = checked
        }
        // 这一轮的记忆参与度：一处算，X 自动注入 / recall 闸都只读它（plan-memory-participation §2.3）
        let participation = EffectiveMemoryParticipation.resolve(profileId: profile.id, conversation: conversation,
                                                                 preset: preset)
        // 来源窗隐藏集（已删 / 关参与）：X 碎片、待续、时间轴行都不带（plan-memory-participation §2.4）
        let hiddenSources = EffectiveMemoryParticipation.hiddenSources(profileId: profile.id, context: context)
        // 取数 + 预算与记忆面板「下一轮会想起什么」预览同一个函数（预览 = 实发）
        let memoryInputs = MemoryInjector.roundInputs(profileId: profile.id, participation: participation,
                                                      store: memoryStore, context: context, warmedWiki: warmedWiki,
                                                      useCachedWiki: mode == .preview,
                                                      previousWindow: previousWindow,
                                                      hiddenSources: hiddenSources)
        let memories = memoryInputs.memories
        let selfMemory = memoryInputs.selfMemory
        let archiveBudget = memoryInputs.archiveBudget
        // access 语义（SC-B1 刀3）：进候选池不再 +1——recall 真命中才强化（分发分支记），
        // 否则 hot 池全员每轮通胀、强化信号无区分度（paramecium"翻目录不算想起来"语义）
        // M2：缺向量的记忆后台补算（开关关/无缺口时零开销）
        if mode == .send, !memories.isEmpty { MemoryEmbeddingBackfill.run(memories: memories, context: context) }

        let history = AirTimedSection.run("composePrompt.history") {
            windowedHistory(excluding: excludingNodeId, depth: preset.sampling.contextDepth, imagesAllowed: imagesAllowed,
                            anchorOnSummary: participation.a2Summary)
        }
        if mode == .send, let node = visionWithheldNode { node.sendNotice = Self.visionWithheldNotice }
        let apiMessages = history.messages
        var chatHistory = apiMessages.map { (role: $0.role, content: $0.content) }
        var historyNodeIds = apiMessages.map(\.id)
        let wikiScan = wikiScanWindow(excluding: excludingNodeId).map(\.content)
        // 10-29 贴表情立刻生效：这一轮是表情触发的（事件挂在本轮回复节点上）→ 补一条「[附带事件]」user，
        // 和它落地后历史里插的那条逐字节一样（materializeAPIMessages）
        let turnEvents = excludingNodeId.flatMap { nodeMap[$0] }?.cardEvents ?? []
        if !turnEvents.isEmpty {
            chatHistory.append((role: "user", content: ChatCardEventPrompt.turnContent(turnEvents)))
            historyNodeIds.append(Self.syntheticUserNodeId)
        } else if chatHistory.last?.role == "assistant" {
            // #089 P0-a：最后一条必须是 user。历史以 assistant 结尾 = 网页卡 /trigger 让 AI 接着说，或检查器预览时还没打字
            chatHistory.append((role: "user", content: mode == .preview ? Self.previewNextUserPlaceholder : Self.triggerNudge))
            historyNodeIds.append(Self.syntheticUserNodeId)
        }
        // v4-1 §六：和历史窗口原文重复的上下文摘要段 / 时间轴条目不注（判定用节点 id，就用这份历史，不另算）
        let windowIds = Set(apiMessages.map(\.id))

        // 查询当前楼层的世界书（过滤 conversation scope）
        // 卡库 ③-4：有效身份 + 有效书集合（楼层 / 对话 / 身份的书）和检查器同一次解析；profile 换成身份套上后的副本
        let sendContext = AirTimedSection.run("composePrompt.context") {
            SendContextResolver.resolve(profile: profile, conversation: conversation, context: context, globalEntries: globalEntries)
        }
        let profile = sendContext.profile
        let recallUser = currentPath.last { $0.role == "user" && !$0.isSyntheticRoot && !$0.isSourceHidden && !$0.isTrashed }
        let cachedRecall = conversation?.recallState ?? RecallConversationState()
        let branchAnchor = cachedRecall.branchAnchor.isEmpty ? (conversation?.id ?? "") : cachedRecall.branchAnchor
        let receipts = recallPathReceipts()
        let recallState = RecallTurnState.recover(receipts: receipts, branchAnchor: branchAnchor,
                                                 clearActive: receipts.last?.decision.branchAnchor != branchAnchor)
        let assistantReceipt = excludingNodeId.flatMap { nodeMap[$0].flatMap(cachedRecallReceipt) }
        let userReceipt = recallUser.flatMap(cachedRecallReceipt)
        // 同一轮的决策取回：重生成看新回复自己的回执，`/trigger` / 贴表情看 user 上留的 decision
        let existingReceipt = assistantReceipt ?? userReceipt
        let recallEnabled = participation.on
        let recalled = RecallSelection.prepare(
            profile: profile, conversationId: conversation?.id ?? "", turnId: recallUser?.id ?? Self.syntheticUserNodeId,
            branchAnchor: branchAnchor, text: recallUser?.content ?? "", state: recallState,
            existingDecision: existingReceipt?.decision, inputs: memoryInputs,
            recentMessages: wikiScan, now: MemoryClock.now, tuning: RecallTuningStore.load(profileId: profile.id),
            enabled: recallEnabled)
        let currentConvId = conversation?.id ?? ""
        let worldBooks = sendContext.worldBooks

        // 【开窗口】A2（mem_open_a2，没写过跟 mem_content_summary；受 mem_master / 本窗参与连坐）：关 = 不注入。
        // v4-1：只注压缩段和第 0 段，收尾段不注；最后一条还在历史窗口里的段不注（纯函数，读盘和以前一样一次）
        var contextSegments: [SessionSegment] = []
        var contextSummary: String?
        var contextUnits: [RecallDeliveryUnit] = []
        if participation.a2Summary {
            var s = SessionSummaryStore.loadOrSeed(conversationId: currentConvId, memoryRoot: FileLibraryStore.memoryRoot(profileId: profile.id), title: "")
            s.segments = SessionSummaryStore.injectableSegments(s.segments, windowIds: windowIds, windowStart: history.start)
            contextSegments = s.segments
            contextSummary = SessionSummaryStore.injectionText(s, fullCount: SessionCloseout.fullSegmentCount)
            // 单位文本 = `injectionText` 里该段那几行（更早的每段一行 / 最近的整块），同序旁录
            let olderCount = max(0, s.segments.count - max(1, SessionCloseout.fullSegmentCount))
            for (index, segment) in s.segments.enumerated() {
                let range = "\(SessionSummaryStore.timeRange(segment)) · \(segment.title)"
                let text = index < olderCount ? "- \(range)"
                    : "〔\(range)〕\n\(SessionSummaryStore.segmentText(segment))"
                contextUnits.append(RecallDeliveryUnit(
                    kind: RecallDeliveryItem.Kind.a2, ref: MemoryInjectionMeter.key(conversationId: currentConvId, segment: segment),
                    text: text, tokens: Memory.estimateTokens(text), shown: range, segment: .contextSummary))
            }
        }
        // M5 用户画像：v5 Q4 下线，不再注入（画像文件留着不动）
        // M6 时间轴：开关开才注（最新一篇楼层日记，天级稳定）+ 快到的纪念日（plan-calendar §八，同样按天稳定）
        let timelineSlot = CalendarInjection.timelineSlot(profileId: profile.id, currentConversationId: currentConvId, windowIds: windowIds,
                                                          participation: participation, hiddenSources: hiddenSources)
        let timeline = timelineSlot.text

        // 写作风格：选了 style 才传 styleContent;PromptAssembler 内部合并到 last user。
        // 历史轮不复读(因为只在出口拼一次,user node 存的 content 干净)。
        // ccBridge 路径稍后会 strip 掉 <style> 后缀(CC 是 exec relay 不需要写作风格)。
        let styleContent: String? = {
            guard let conv = conversation, !conv.currentStyleId.isEmpty,
                  let s = StyleManager.shared.find(conv.currentStyleId), !s.content.isEmpty else { return nil }
            return s.content
        }()

        // 发语音条：注入段与文件库 hint 同槽（过 applyMacros，实发/检查器同路）。
        // 语音通话中让路：否则 AI 把内容写进 ```voice 块 → 通话朗读只读到清洗后的空正文（和通话打架）。
        let capabilityHint: String? = {
            let voiceHint = CallSession.activeSnapshot ? nil : VoicePromptInjector.hint(profile: profile)
            // 10-29：只有气泡对话教「贴表情会叫你 / 怎么给她贴表情」；文章对话一个字不变
            let bubbleHint = conversation?.isBubbleMode == true ? ChatReactionIntent.promptHint : nil
            let parts = [fileLibraryHint, voiceHint, bubbleHint].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }()

        // assembleOrdered 展开（= assembleTagged + orderedMessages）：检查器要带 template 的 tagged 段
        let healthSummary = AirTimedSection.run("composePrompt.health") {
            HealthLogStore.composedHealthSummary(context: context, profileId: profile.id, grants: permGrants(for: conversation))
        }
        let tradingSummary = AirTimedSection.run("composePrompt.trading") {
            tradingSummaryForPrompt(context: context, profileId: profile.id)
        }
        // 今天的日记：同一份文本进 volatileNote（拼接不改）并旁录进账（P0）
        let today = MemoryClock.now
        let journal = CalendarInjection.todayJournalText(profileId: profile.id, today: today)
        let assembled = AirTimedSection.run("composePrompt.assemble") { PromptAssembler.assembleTagged(
            preset: preset,
            profile: profile,
            memories: memories,
            chatHistory: chatHistory,
            worldBooks: worldBooks,
            globalEntries: sendContext.globalEntries,
            contextSummary: contextSummary,
            timelineSummary: timeline,
            healthSummary: healthSummary,
            tradingSummary: tradingSummary,
            fileLibrary: capabilityHint,
            styleContent: styleContent,
            folderInstructions: folderInstructions(for: conversation, context: context),
            volatileNote: journal,
            statusNote: turnStatusNote(profileId: profile.id,
                                       library: fileLibraryHint?.hasPrefix("<文件库>") == true),
            historyNodeIds: historyNodeIds,
            regexScripts: regexScripts(profile: profile, preset: preset),
            selfMemory: (selfMemory?.text).flatMap { $0.isEmpty ? nil : $0 },
            memoryBudget: archiveBudget,
            cardGuide: cardGuide.mode,
            availableTools: cardGuide.tools,
            wiki: memoryInputs.wiki,
            wikiScanMessages: wikiScan,
            recallLayers: recalled.layers
        ) }

        // ④b：历史图片 / 文件按节点 id 挂回真实用户消息（不按正文匹配——注入段、重复正文、宏展开、
        // 写作风格后缀都不会让图挂错或丢）；旧形态的 imageMap 由有序序列派生给 CC / 非有序 provider
        var imagesByNodeId: [String: [PendingChatAttachment]] = [:]
        for msg in apiMessages where !msg.images.isEmpty {
            imagesByNodeId[msg.id] = msg.images
        }
        var roundsByNodeId: [String: [ToolReplayRound]] = [:]
        for msg in apiMessages where !msg.toolRounds.isEmpty {
            roundsByNodeId[msg.id] = msg.toolRounds
        }
        let ordered = PromptMessage.attachingToolRounds(roundsByNodeId,
            to: PromptMessage.attaching(imagesByNodeId, to: PromptAssembler.orderedMessages(from: assembled.segments)))
        let deliveredSegments = providerType == .localMLX
            ? LocalChatProvider.retainedSystemSegments(assembled.segments) : assembled.segments
        let cacheFriendly = preset.sampling.cacheFriendly == true
        // 缓存模式的 X 段由 assembler 插在最后一条真实历史之前；其它记忆段属于 Z。
        let volatileSegmentIndex = providerType == .localMLX && cacheFriendly
            ? assembled.segments.lastIndex(where: { $0.source == .chatHistory }).map { $0 - 1 } : nil
        var volatileCursor = recalled.layers.volatile.startIndex
        var stableCursor = recalled.layers.stable.startIndex
        func deliveredPrefix(_ payload: String, volatile: Bool, after cursor: inout String.Index) -> String {
            guard !payload.isEmpty else { return "" }
            if providerType != .localMLX { return payload }
            let layer = volatile ? recalled.layers.volatile : recalled.layers.stable
            guard let range = layer.range(of: payload, range: cursor..<layer.endIndex) else { return "" }
            cursor = range.upperBound
            let layerOffset = volatile && !cacheFriendly && !recalled.layers.stable.isEmpty
                ? recalled.layers.stable.count + "\n\n".count : 0
            let offset = layerOffset + layer.distance(from: layer.startIndex, to: range.lowerBound)
            for (index, sent) in zip(assembled.segments.indices.lazy.filter({ assembled.segments[$0].role == "system" }), deliveredSegments) {
                let original = assembled.segments[index]
                guard original.source == .memory,
                      !cacheFriendly || (index == volatileSegmentIndex) == volatile,
                      original.content.dropFirst(layerOffset).hasPrefix(layer) else { continue }
                return String(sent.content.dropFirst(offset).prefix(payload.count))
            }
            return ""
        }
        let decision = providerType == .localMLX ? recalled.decision.recordingDelivery(recalled.decision.selected.compactMap { item in
            let sent = deliveredPrefix(item.text, volatile: true, after: &volatileCursor)
            return sent.isEmpty ? nil : RecallItem(source: item.source, text: sent, identities: item.identities,
                                                   tokenCost: Memory.estimateTokens(sent))
        }) : recalled.decision

        // ── 账（plan-memory-receipt §2.2）：生产者吐的单位在最终段里核存活，send / preview 同一条 locate
        let availableTools = cardGuide.tools
        func wireText(_ text: String) -> String {
            availableTools.map { PromptAssembler.droppingOffToolMentions(text, available: $0) } ?? text
        }
        /// 两层整层各变换一次（与 assembler 对段做的同一步），单位文本逐条变换只在闭包里用
        let stableWire = wireText(recalled.layers.stable)
        let volatileWire = wireText(recalled.layers.volatile)
        /// 本机按 system 段截断后的实际内容；其它 provider 就是段本身
        let deliveredByIndex: [Int: String] = {
            guard providerType == .localMLX else {
                return Dictionary(uniqueKeysWithValues: assembled.segments.indices.map { ($0, assembled.segments[$0].content) })
            }
            var map: [Int: String] = [:]
            for (index, sent) in zip(assembled.segments.indices.lazy.filter({ assembled.segments[$0].role == "system" }), deliveredSegments) {
                map[index] = sent.content
            }
            return map
        }()
        /// 段映射（步 1）：cacheFriendly 的面板段 + X 段各一段，按层文本认；其它 provider 一段。
        /// `.volatileContext` 不能取第一段：非 cacheFriendly 时时间与日记各一段，按 needle 所在段找。
        var segmentCache: [RecallDeliveryUnit.Segment: Int] = [:]
        func segmentIndex(_ segment: RecallDeliveryUnit.Segment, needle: String = "") -> Int? {
            if segment != .volatileContext, let cached = segmentCache[segment] { return cached }
            let found: Int?
            switch segment {
            case .memoryStable, .memoryVolatile:
                let layer = segment == .memoryVolatile ? volatileWire : stableWire
                if cacheFriendly, !layer.isEmpty,
                   let hit = assembled.segments.firstIndex(where: { $0.source == .memory && $0.content == layer }) {
                    found = hit
                } else {
                    found = assembled.segments.firstIndex { $0.source == .memory }
                }
            case .contextSummary:
                found = assembled.segments.firstIndex { $0.source == .contextSummary }
            case .timeline:
                found = assembled.segments.firstIndex { $0.source == .timeline }
            case .volatileContext:
                found = needle.isEmpty ? nil
                    : assembled.segments.firstIndex { $0.source == .volatileContext && $0.content.contains(needle) }
            }
            if let found, segment != .volatileContext { segmentCache[segment] = found }
            return found
        }
        var wireCursors: [RecallDeliveryUnit.Segment: String.Index] = [:]
        /// 段内起点：非 cacheFriendly 时 stable / volatile 同在一段，volatile 从 stable 部分之后起跳
        func segmentCursor(_ segment: RecallDeliveryUnit.Segment, in full: String) -> String.Index {
            if let cursor = wireCursors[segment] { return cursor }
            guard segment == .memoryVolatile, !cacheFriendly, !stableWire.isEmpty, full.hasPrefix(stableWire) else {
                return full.startIndex
            }
            return full.index(full.startIndex, offsetBy: stableWire.count)
        }
        func locate(_ unit: RecallDeliveryUnit) -> MemoryDelivery.Located {
            let needle = wireText(unit.text)
            guard !needle.isEmpty, let index = segmentIndex(unit.segment, needle: needle) else { return .none }
            let full = assembled.segments[index].content
            let start = segmentCursor(unit.segment, in: full)
            guard let range = full.range(of: needle, range: start..<full.endIndex) else { return .none }
            wireCursors[unit.segment] = range.upperBound
            // 本机：段按 system 顺序吃 systemBudget，超出部分逐字截掉（Character 口径）
            guard providerType == .localMLX else { return .full }
            let deliveredCount = (deliveredByIndex[index] ?? full).count
            let end = full.distance(from: full.startIndex, to: range.upperBound)
            if end <= deliveredCount { return .full }
            return full.distance(from: full.startIndex, to: range.lowerBound) < deliveredCount ? .partial : .none
        }
        var deliveryUnits = recalled.layers.units
        deliveryUnits += contextUnits
        for unit in timelineSlot.units {
            deliveryUnits.append(RecallDeliveryUnit(
                kind: RecallDeliveryItem.Kind.timeline, ref: unit.key, text: unit.line,
                tokens: Memory.estimateTokens(unit.line), shown: unit.line.trimmingCharacters(in: .whitespaces),
                segment: .timeline))
        }
        for pending in timelineSlot.pendingUnits {
            deliveryUnits.append(RecallDeliveryUnit(
                kind: RecallDeliveryItem.Kind.pending, ref: "pending:\(pending.conversationId)", text: pending.line,
                tokens: Memory.estimateTokens(pending.line), shown: pending.line, segment: .timeline))
        }
        if let anniversary = timelineSlot.anniversaryUnit {
            deliveryUnits.append(RecallDeliveryUnit(
                kind: RecallDeliveryItem.Kind.anniversary, ref: "anniversary", text: anniversary,
                tokens: Memory.estimateTokens(anniversary), shown: anniversary, segment: .timeline))
        }
        if let journal {
            deliveryUnits.append(RecallDeliveryUnit(
                kind: RecallDeliveryItem.Kind.journal,
                ref: "journal:\(DailyActivity.dayKey(today, calendar: .current))",
                text: journal, tokens: Memory.estimateTokens(journal), shown: "今天的日记",
                segment: .volatileContext))
        }
        let gate = RecallGateSnapshot(participation, hiddenFragments: memoryInputs.hiddenFragmentCount,
                                      hiddenTimeline: timelineSlot.hiddenCount)
        let route = providerType == .ccBridge ? "ccBridge" : (providerType == .localMLX ? "local" : "api")
        let delivery = route == "ccBridge"
            ? MemoryDelivery.build(units: [], route: route, gate: gate) { _ in .none }
            : MemoryDelivery.build(units: deliveryUnits, route: route, gate: gate, locate: locate)

        // 刀5：设置页「上一轮实际注入」——组装时只算好注入快照存进回执（预览不记）；Meter 在首个有效响应时写
        // （respondRecallAttempt），CC 在这里 recordCCBridge。
        if mode == .send {
            if ordered.last?.role == "assistant" {
                CacheDiagLog.shared.log("⚠️ 发出去的最后一条是 assistant（预设里的预填），新模型可能不认")
            }
            let memorySegments = deliveredSegments.filter { $0.source == .memory && !$0.content.isEmpty }
            let sentSelf = providerType == .localMLX
                ? deliveredPrefix(selfMemory?.text ?? "", volatile: false, after: &stableCursor) : ""
            let injection = MemoryInjectionRecord(
                tokens: memorySegments.isEmpty ? 0 : Memory.estimateTokens(memorySegments.map(\.content).joined(separator: "\n\n")),
                stableCount: assembled.memoryHits.filter { hit in
                    guard hit.retrieverId == "persistent" else { return false }
                    guard providerType == .localMLX else { return true }
                    guard let memory = memories.first(where: { $0.id == hit.memoryId }) else { return false }
                    return !deliveredPrefix(MemoryInjector.injectionPayload(memory, stable: true, catalog: false, now: MemoryClock.now).text,
                                            volatile: false, after: &stableCursor).isEmpty
                }.count,
                hitCount: delivery.items.filter(Self.countsAsRecallHit).count, at: Date(),
                selfTokens: providerType == .localMLX ? (sentSelf.isEmpty ? 0 : Memory.estimateTokens(sentSelf)) : selfMemory?.tokens ?? 0,
                selfCount: providerType == .localMLX
                    ? min((selfMemory?.fullCount ?? 0) + (selfMemory?.indexCount ?? 0),
                          sentSelf.components(separatedBy: "\n").filter { $0.hasPrefix("### ") || $0.hasPrefix("- ") }.count)
                    : (selfMemory?.fullCount ?? 0) + (selfMemory?.indexCount ?? 0),
                timelineKeys: MemoryInjectionMeter.keptTimelineKeys(timelineSlot.units, in: deliveredSegments),
                contextKeys: deliveredSegments.contains { $0.source == .contextSummary && !$0.content.isEmpty }
                    ? contextSegments.map { MemoryInjectionMeter.key(conversationId: currentConvId, segment: $0) } : [],
                conversationId: currentConvId)
            if let recallUser {
                var receipt = assistantReceipt ?? RecallTurnReceipt(decision: decision)
                if assistantReceipt == nil, let prior = priorAssistantReceipt(onTurn: decision.turnId) {
                    receipt.inheritedEffective = prior.hasEffectiveResponse
                }
                receipt.decision = decision
                receipt.delivery = delivery
                receipt.injectionRecord = providerType == .ccBridge ? nil : injection
                if let excludingNodeId, let assistant = nodeMap[excludingNodeId], assistant.role == "assistant" {
                    assistant.recallReceipt = receipt
                }
                if providerType == .ccBridge {
                    // CC 回复节点（hub 推回）不挂回执：decision + 空清单挂在 user 上
                    recallUser.recallReceipt = receipt
                    MemoryInjectionMeter.recordCCBridge(profileId: profile.id)
                } else if userReceipt == nil {
                    recallUser.recallReceipt = RecallTurnReceipt(decision: decision)
                }
                if let conversation {
                    conversation.recallState = recallState
                    touchRecallConversation(conversation)
                }
            }
        }
        return ComposedPrompt(segments: assembled.segments, memoryHits: assembled.memoryHits, ordered: ordered,
                              identity: sendContext.inspectorLines, recallDecision: decision, delivery: delivery)
    }

    /// 检查器只读入口：此刻按发送键（除了新打的那条）模型会收到的全部。取模型 / 取工具 / 组装与实发同一套函数，
    /// 不写库、不钉模型、不弹 askOnce、不写 breadcrumb、不补向量。excludingNodeId 只给测试对齐「重新生成」用
    @MainActor
    func previewTurn(profile: Profile, preset: Preset, providerManager: ProviderManager, globalModelId: String?,
                     context: ModelContext, excludingNodeId: String? = nil) -> TurnPreview? {
        guard let conversation = selectedConversation else { return nil }
        let model = providerManager.resolveModel(conversationModelId: conversation.selectedModelId, profileModelId: profile.preferredModel,
                                                 globalFallbackId: globalModelId)
        // CC 实发不调 toolInjection、fileLibraryHint 传 nil（sendMessage / regenerate 的 CC 分支）
        let injection: (tools: [[String: Any]]?, systemHint: String, absentReason: ToolsAbsentReason?, tucked: [String], offered: Set<String>?) =
            providerManager.provider(for: model)?.type == .ccBridge
            ? (nil, "", .ccBridge, [], nil)
            : toolInjectionDetailed(for: model, providerManager: providerManager, conversation: conversation,
                                    profileId: conversation.profileId, silent: true, userName: profile.userName)
        let composed = composePrompt(profile: profile, preset: preset, excludingNodeId: excludingNodeId, context: context,
                                     globalEntries: globalWorldBookEntries,
                                     fileLibraryHint: injection.systemHint.isEmpty ? nil : injection.systemHint, mode: .preview,
                                     cardGuide: Self.cardGuideChoice(tools: injection.tools, offered: injection.offered, profileId: conversation.profileId),
                                     providerType: providerManager.provider(for: model)?.type,
                                     imagesAllowed: VisionCapability.of(model, providerType: providerManager.provider(for: model)?.type) != .no)
        return TurnPreview(model: model, tools: injection.tools, toolsAbsentReason: injection.absentReason, tuckedTools: injection.tucked,
                           offeredTools: injection.offered,
                           segments: composed.segments, memoryHits: composed.memoryHits, ordered: composed.ordered,
                           sampling: StreamingPreference.apply(Self.withEffectiveEffort(preset.sampling, model: model, providerManager: providerManager)),
                           identity: composed.identity, delivery: composed.delivery)
    }

    /// ⑤a：当前楼层有效正则（全局 → 预设实例 → 绑定卡 / 楼层旧规则），发送与入库共用；检查器走同一解析
    private func regexScripts(profile: Profile, preset: Preset) -> [RegexScript] {
        RegexPipeline.scripts(profile: profile, preset: preset, cards: RegexPipeline.liveCards?.cards ?? [])
    }

    /// ⑤a 输入阶段：用户提交 / 编辑 / assistant 完整回复入库前跑一次普通规则（编辑只跑 runOnEdit）
    /// 卡库 ③-4：选中对话的有效身份（对话 → 楼层 → 楼层原有身份文本）。显示 / 入库前宏 / 输入正则用它，发送走 SendContextResolver 同一规则
    func personaResolution(profile: Profile?) -> PersonaResolution {
        PersonaResolution.resolve(conversationPersonaId: selectedConversation?.personaId, floorPersonaId: profile?.personaId,
                                  personas: UserPersonaStore.shared.personas)
    }

    /// 显示副本用的有效名字（nil = 沿用楼层的）；身份库空时不读楼层 / 对话，免得每个气泡都多订阅一层
    func personaDisplayName(profile: @autoclosure () -> Profile?) -> String? {
        guard !UserPersonaStore.shared.personas.isEmpty else { return nil }
        return personaResolution(profile: profile()).displayUserName
    }

    private func applyInputRegex(_ text: String, role: String, isEdit: Bool = false, profile: Profile, preset: Preset) -> String {
        let names = EffectiveCharacterContext(profile: personaResolution(profile: profile).applied(to: profile))
        return RegexPipeline.run(regexScripts(profile: profile, preset: preset), text: text, phase: .input,
                                 placement: RegexPipeline.placement(forRole: role), isEdit: isEdit,
                                 userName: names.userName, charName: names.charName)
    }

    /// 这个模型记过的档位优先，没记过拿预设当起点，再按它能选的档位取最近（发送 / 检查器预览共用）
    static func withEffectiveEffort(_ sampling: SamplingParams, model: ProviderModel, providerManager: ProviderManager) -> SamplingParams {
        guard let provider = providerManager.provider(for: model) else { return sampling }
        let route = ReasoningEffort.route(providerType: provider.type, credentialId: provider.id,
                                          baseURL: provider.baseURL, modelId: model.modelId)
        var r = sampling
        r.reasoningEffort = ReasoningEffort.effective(
            stored: ReasoningEffort.stored(credentialId: provider.id, modelId: model.modelId),
            presetDefault: sampling.reasoningEffort,
            levels: ReasoningEffort.levels(route: route, modelId: model.modelId))
        return r
    }

    /// ccBridge 路径：把 PromptAssembler 的输出后处理成只发 raw user 文字，
    /// 同时构造 router 的 additionalHeaders（chat_id/message_id/user）。
    /// 其他 provider 类型走原路（直接返回 assembled + 空 headers）。
    private func prepareRouterPayload(
        assembled: (systemPrompt: String?, messages: [(role: String, content: String)], sampling: SamplingParams, imageMap: [String: [PendingChatAttachment]], recallHits: [InjectionHit], ordered: [PromptMessage]),
        model: ProviderModel,
        conversation: Conversation,
        profile: Profile,
        providerManager: ProviderManager,
        messageNodeId: String,
        offered: Set<String>? = nil
    ) -> (
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        sampling: SamplingParams,
        additionalHeaders: [String: String],
        imageMap: [String: [PendingChatAttachment]],
        ordered: [PromptMessage]
    ) {
        // 思考强度跟着模型走（research-reasoning-effort §2.2）：每条路发之前都在这里换成这个模型的档位
        var assembled = assembled
        assembled.sampling = Self.withEffectiveEffort(assembled.sampling, model: model, providerManager: providerManager)
        guard let provider = providerManager.provider(for: model),
              provider.type == .ccBridge else {
            var headers: [String: String] = [:]
            // OpenRouter sticky 路由：不带 session_id 时 OR 要先撞上一次命中才粘住 provider，
            // 而上游轮换导致永远撞不上（实测 0 命中）。显式 x-session-id 从第一轮就钉住。
            if assembled.sampling.cacheFriendly == true,
               let p = providerManager.provider(for: model),
               p.baseURL.lowercased().contains("openrouter") {
                headers["x-session-id"] = "mp-\(conversation.id.prefix(60))"
            }
            // #089 P0-b：只有 Anthropic / OpenAI 兼容把历史工具回合发成真工具块；别家（ChatGPT 登录、本机模型）退纯文字 + 〔系统记录〕
            let ordered = ToolReplay.orderedForProvider(providerManager.provider(for: model)?.type, assembled.ordered)
            if ordered.contains(where: { !$0.toolRounds.isEmpty }) != assembled.ordered.contains(where: { !$0.toolRounds.isEmpty }) {
                let legacy = PromptMessage.legacyShape(ordered)
                return (legacy.messages, legacy.systemPrompt, assembled.sampling, headers, legacy.imageMap, ordered)
            }
            // #093：调过这一轮调不到的工具（抽屉 / 权限关了）那条退纯文字，不让 ChatService 包成 tool_invoke（检查器 requestBody 同一步）
            let replay = offered.map { ToolReplay.offeredOnly(assembled.ordered, offered: $0) } ?? assembled.ordered
            return (assembled.messages, assembled.systemPrompt, assembled.sampling, headers, assembled.imageMap, replay)
        }
        // CC 不发花园的记忆 / 完整 system；语音能力会单独附在本轮传输文字。
        MemoryInjectionMeter.recordCCBridge(profileId: profile.id)
        // L2：任何用 ccBridge 聊过的对话都自动获得 ccBridgeSessionName，
        // 这样 SidebarView 的荧光绿 badge 能区分"CC 对话"跟其它对话。
        // 默认值 "mp-cc"（隐式约定的默认 session），跟 nil fallback 行为一致；
        // 用户可以通过 picker 切到 mp-cc-N 或显式解绑回 nil（非 CC 对话）。
        // L2→C1：每个会话派生唯一 session（mp-cc-<id前8位>）→ 严格 1:1，context 不互串。
        // 只在 nil 时赋（新会话），现有绑定不动 = 自动 grandfather（「测试」仍走 mp-cc）。
        if conversation.ccBridgeSessionName == nil {
            conversation.ccBridgeSessionName = Self.deriveCCSession(conversation.id)
        }
        // ccBridge：只取最后一条 user 的 raw 文字，丢掉 system prompt 和历史
        // Style 在 assemblePrompt 出口已贴到末尾，跟着 user 一起发给 CC（风格也对 CC 生效）。
        // ④b：取真实最后一条用户消息（depth=0 user 注入不算），写作风格已并在它身上
        let realLastUser = assembled.ordered.last(where: { $0.role == "user" && !$0.isInjected })
        let lastUserRaw = realLastUser?.content ?? assembled.messages.last(where: { $0.role == "user" })?.content ?? ""
        // C2：砍掉附件展开的提取文字（CC 拿原始文件去 Read，不要塞整篇 PDF 文本——否则 channel 超长 tmux send-keys 失败）。
        // Style 后缀贴在最末尾、在附件标记之后，先摘出来免得被一起砍掉，砍完再拼回。
        let lastUser: String = {
            var body = lastUserRaw
            var styleSuffix = ""
            if body.hasSuffix("</style>"), let r = body.range(of: "\n<style>", options: .backwards) {
                styleSuffix = String(body[r.lowerBound...])
                body = String(body[..<r.lowerBound])
            }
            let markers = [body.range(of: "[图片附件："), body.range(of: "[附件：")].compactMap { $0?.lowerBound }
            let trimmed = markers.min().map { String(body[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? body
            return VoicePromptInjector.bridgeContent(trimmed + styleSuffix, inCall: CallSession.activeSnapshot)
        }()
        let userLabel = profile.userName.isEmpty ? "user" : profile.userName
        var headers: [String: String] = [
            "X-MP-ChatId": conversation.id,
            "X-MP-MessageId": messageNodeId,
            "X-MP-User": userLabel,
        ]
        // A4：用户引用了某条 → 告诉 CC（channel 带 reply_to）
        if let rt = currentPath.first(where: { $0.id == messageNodeId })?.replyToId, !rt.isEmpty {
            headers["X-MP-ReplyTo"] = rt
        }
        // L2：绑定的 tmux session 名字传给 hub 做 per-session 路由
        if let session = conversation.ccBridgeSessionName, !session.isEmpty {
            headers["X-MP-CCSession"] = session
        }
        // C2：只透传当前这条 user 消息的图/文件给 CC。imageMap 按原文(lastUserRaw)做键，
        // 但 key 改成砍后的 lastUser（跟发出去的 content 一致，CC override 才匹配得到）。
        var ccImages: [String: [PendingChatAttachment]] = [:]
        if let imgs = realLastUser?.attachments ?? assembled.imageMap[lastUserRaw], !imgs.isEmpty {
            ccImages[lastUser] = imgs
        }
        return (
            messages: [(role: "user", content: lastUser)],
            systemPrompt: nil,
            sampling: assembled.sampling,
            additionalHeaders: headers,
            imageMap: ccImages,
            ordered: []
        )
    }

    /// C1：从会话 id 派生唯一 tmux session 名。`mp-cc-<id前8位小写>`，只留合法字符（hub 校验 [A-Za-z0-9_.-]{1,32}）。
    static func deriveCCSession(_ convId: String) -> String {
        let suffix = convId.prefix(8).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return "mp-cc-\(suffix)"
    }

    /// 主 provider id → 该 provider 下"便宜模型"的 modelId。粟粟批注：暂硬编码，
    /// 未来可扩展成配置。provider 不在表里就没 cheap 可用 → fallback 到主对话模型。
    static let cheapModelIdByProvider: [String: String] = [
        "anthropic": "claude-haiku-4-5",
        "openai":    "gpt-4o-mini",
        "deepseek":  "deepseek-chat",
        "gemini":    "gemini-2.5-flash",
        "groq":      "llama-3.3-70b-versatile",
    ]

    /// 选择记忆提取 / 上下文总结等 backend agent 用的便宜模型。
    /// **只在 enabledProviders（有 key）里找**，避免落到没 key 没拨款的 provider。
    /// 顺序：用户旧设置 `memoryExtractModelId`（限 enabled）→ 主 provider 的 cheap map → fallback。
    private func cheapModel(providerManager: ProviderManager, fallback: ProviderModel) -> ProviderModel {
        Self.memoryModel(providerManager: providerManager, fallback: fallback)
    }

    /// 同上，静态版：发消息那条路之外（窗口收尾巡检）也用同一个记忆模型
    static func memoryModel(providerManager: ProviderManager, fallback: ProviderModel) -> ProviderModel {
        let enabledModels = providerManager.enabledProviders.flatMap(\.models)

        // 老 UserDefaults key 兼容（Picker 现已被 MemoryModelConfig 替代，但之前选过的仍尊重）
        let userChoice = UserDefaults.standard.string(forKey: "memoryExtractModelId") ?? ""
        if !userChoice.isEmpty, let model = enabledModels.first(where: { $0.id == userChoice }) {
            return model
        }

        // cheap map 是按 preset id（"anthropic"/"openai"/…）硬编码；fallback.credentialId 在 M1 后是 cred-UUID。
        // 通过 credential.presetId 反查 cheap 模型。
        if let cred = providerManager.credential(for: fallback),
           let presetId = cred.presetId,
           let cheapId = Self.cheapModelIdByProvider[presetId],
           let model = cred.models.first(where: { $0.modelId == cheapId }) {
            return model
        }

        return fallback
    }


    /// Build API message history from currentPath, excluding a specific node, limited to recent messages
    struct APIMessage {
        let id: String                  // 来源 node id（SC-B2 quote 出处定位用）
        let role: String
        let content: String
        let images: [PendingChatAttachment]
        /// #089 P0-b：assistant 节点的工具回合（content 只剩最后的正文）
        var toolRounds: [ToolReplayRound] = []
    }

    func buildAPIMessages(excluding excludeId: String? = nil, maxMessages: Int = 40) -> [APIMessage] {
        materializeAPIMessages(Array(historyCandidates(excluding: excludeId).suffix(maxMessages)))
    }

    /// 给副模型（记忆提取）看的历史：工具调用写成中性的 [调用了 …]，不是第一人称、不像模型自己的输出（#089 P0-b）
    func buildSideModelMessages(maxMessages: Int = 40) -> [APIMessage] {
        buildAPIMessages(maxMessages: maxMessages).map {
            APIMessage(id: $0.id, role: $0.role, content: ToolReplay.sideModelText(content: $0.content, rounds: $0.toolRounds),
                       images: $0.images)
        }
    }

    /// 便宜的一遍（全路径）：只定「哪些消息进历史、正文是什么」，不碰附件。窗口大小要靠它的条数算
    private func historyCandidates(excluding excludeId: String?) -> [(node: MessageNode, content: String)] {
        PromptAssembler.historyNodes(currentPath).compactMap { node -> (node: MessageNode, content: String)? in
            guard !node.isSyntheticRoot, node.role == "user" || node.role == "assistant" else { return nil }
            if node.id == excludeId { return nil }
            let content: String
            if node.role == "assistant" {
                // 正文只取最后一轮的话；工具调用由 materialize 挂成回合（#089 P0-b，不再写进正文）。
                // tool-only assistant（正文空、只有工具 segments）不能丢：丢了 history 会出现 user+user 连排，模型把上一条也当待办重复执行
                content = ContentCleaner.extractThinking(from: node.content).content
                guard !content.isEmpty || Self.hasToolUse(node.segments) else { return nil }
            } else {
                guard !node.content.isEmpty else { return nil }
                content = node.content
            }
            return (node, content)
        }
    }

    struct WikiScanMessage: Equatable {
        let id: String
        let content: String
    }

    func wikiScanWindow(excluding excludeId: String? = nil) -> [WikiScanMessage] {
        // 先用标量转换选窗口（只读 id / role / isSyntheticRoot / isSourceHidden，不碰外置 segmentsData），
        // 再只对窗口内的节点做带分段的完整转换——窗口外 / 隐藏节点不读盘。
        let selected = MemoryResident.wikiNodes(in: currentPath.map { ConversationMessage(scalar: $0) },
                                                excluding: excludeId).map(\.id)
        guard !selected.isEmpty else { return [] }
        let window = Set(selected)
        return currentPath.filter { window.contains($0.id) }.map { node in
            let message = ConversationMessage(node)
            return WikiScanMessage(id: message.id, content: MemoryResident.wikiScanBody(message))
        }
    }

    /// 贵的一遍（只对留下的那些）：引用头、卡片事件、附件（从磁盘读图 / 文件）。
    /// 从后往前一条对一条，图片配额和「3 条之前的旧图换描述」都从末尾数——只喂窗口（全量的后缀）结果逐字节不变
    /// `imagesAllowed` = false：模型明确看不了图（plan-model-vision-check §1.2），照片换文字、表情包只留文字；
    /// 当轮因此少发了图 → `visionWithheldNode`（发送时记到那条消息的 `sendNotice` 上，plan-send-notice-marker A）
    private func materializeAPIMessages(_ relevant: [(node: MessageNode, content: String)], imagesAllowed: Bool = true) -> [APIMessage] {
        let permitted = PermissionCenter.injectionAllowed(.images, profileId: selectedConversation?.profileId, grants: permGrants(for: selectedConversation))
        let sendImages = permitted && imagesAllowed
        visionWithheldNode = nil
        let maxImages = UserDefaults.standard.object(forKey: "maxImagesToModel") as? Int ?? 20

        // 从后往前收集最近 maxImages 张图片
        let transcribe = UserDefaults.standard.object(forKey: "imageTranscriptionEnabled") as? Bool ?? true
        var imageQuota = sendImages ? maxImages : 0
        var fromEnd = 0
        var result: [APIMessage] = []
        for (node, content) in relevant.reversed() {
            var content = content
            var images: [PendingChatAttachment] = []
            // 表情包：历史里永远是「〖表情包：名字——描述〗」；只有最新一轮 + 设置开着才附原图（plan-bubble-sticker-send §1.5）
            if node.role == "user", let memeId = MemeToken.match(node.content) {
                let meme = MemeStore.fetch(memeId, in: node.modelContext)
                let parts = MemeStore.promptParts(for: meme, attachImage: fromEnd == 0 && sendImages && MemeStore.sendsImageToModel)
                content = parts.text
                if let image = parts.image { images.append(image) }
                if fromEnd == 0, permitted, !imagesAllowed, meme != nil, MemeStore.sendsImageToModel { visionWithheldNode = node }
            }
            // 引用注入（粟粟：AI 得看得见引用的哪段）——markdown 引用块前置；
            // 老消息 replyQuote=nil 零字节变化（前缀缓存安全），注入串随消息落库后逐轮稳定
            if node.role == "user", let rq = node.replyQuote, !rq.isEmpty {
                content = "> \(rq)\n\n" + content
            }
            // §13 网页卡事件 / 表情回应：落在节点上，逐轮稳定（老消息 nil 零字节变化）
            if node.role == "user", node.cardEventsData != nil {
                content = ChatCardEventPrompt.prefix(node.cardEvents) + content
            }
            if node.role == "user", let segs = node.segments?.hydratedForDisplay(profileId: node.profileId) {
                let descs = node.imageDescs
                for seg in segs {
                    if case .image(let name, let type, let data) = seg {
                        // M7：3 条消息之前的旧图，有描述就换文字、不发 base64（没描述保留原图兜底，不丢信息）
                        if transcribe, fromEnd >= 3, let desc = descs[name] {
                            content = "[图片: \(desc)]\n" + content
                            continue
                        }
                        if permitted, !imagesAllowed {
                            content = (descs[name].map { "[图片: \($0)]\n" } ?? "[图片]\n") + content
                            if fromEnd == 0 { visionWithheldNode = node }
                            continue
                        }
                        if imageQuota > 0,
                           let att = try? PendingChatAttachment.image(
                                name: name, typeDescription: type ?? "图片",
                                mimeType: "image/jpeg", data: data) {
                            images.append(att)
                            imageQuota -= 1
                        }
                    } else if case .fileData(let name, let mime, let data) = seg {
                        // C2：任意文件（带原始字节），不占图片配额；CC 路径会用，非-CC provider 自动忽略（isImage=false）
                        images.append(.text(name: name, typeDescription: name, extractedText: "",
                                            byteCount: data.count, fileData: data, fileMime: mime))
                    }
                }
            }
            var rounds: [ToolReplayRound] = []
            if node.role == "assistant", Self.hasToolUse(node.segments) {
                if let replay = toolReplayRounds(node) {
                    rounds = replay
                } else if content.isEmpty {
                    content = ToolReplay.toolOnlyPlaceholder   // 导入的老工具段回放不了：只留正文，不带任何前缀
                }
            }
            result.append(APIMessage(id: node.id, role: node.role, content: content, images: images, toolRounds: rounds))
            // 10-29：表情触发的那轮回复前面补回触发它的「[附带事件]」（倒序遍历，后 append = 排在它前面）
            if node.role == "assistant", node.cardEventsData != nil {
                let events = node.cardEvents
                if !events.isEmpty {
                    result.append(APIMessage(id: Self.reactionEventIdPrefix + node.id, role: "user",
                                             content: ChatCardEventPrompt.turnContent(events), images: []))
                }
            }
            fromEnd += 1
        }
        return result.reversed()
    }

    /// 历史窗口（实发与检查器预览共用，预览=实发铁律）：
    /// 有摘要时锚定摘要边界（coveredCount）——两次压缩之间窗口只在尾部生长（append-only → BP4 rolling 命中），
    /// 压缩触发时边界与摘要同步跳变，每 N 轮付一次 miss（滞后压缩缓存收益的另一半，plan-memory-tree-v1 刀4）。
    /// 锚定失效保护：窗口超 depth×2（摘要长期没跑成）或不足 depth（切分支后 coveredCount 失配）→ 退回滑动窗。
    /// #026：先用便宜的一遍定窗口，只对窗口里的读附件（以前 2647 条的对话每次发送都把全路径的附件读一遍再裁掉）
    func buildWindowedAPIMessages(excluding excludeId: String? = nil, depth: Int) -> [APIMessage] {
        windowedHistory(excluding: excludeId, depth: depth).messages
    }

    /// 同上，另带窗口在全路径里从第几条起（v4-1 注入判重叠：改造前的老段没有 id，看下标）
    /// `anchorOnSummary`：这一轮 A2 摘要注不注（`participation.a2Summary`）；nil = 按 `selectedConversation` 现算
    func windowedHistory(excluding excludeId: String? = nil, depth: Int, imagesAllowed: Bool = true,
                         anchorOnSummary: Bool? = nil) -> (messages: [APIMessage], start: Int) {
        let full = historyCandidates(excluding: excludeId)
        guard full.count > depth else { return (materializeAPIMessages(full, imagesAllowed: imagesAllowed), 0) }
        // 【开窗口】A2 不带（本窗关参与 / 楼层 A2 没勾）时摘要不注入 → 锚定必须退滑动窗，
        // 否则窗外消息既无摘要又不在窗（信息丢失），还白占 depth…depth×2 那段
        let anchored = anchorOnSummary ?? selectedConversation.map {
            EffectiveMemoryParticipation.resolve(profileId: $0.profileId, conversation: $0, preset: nil).a2Summary
        } ?? false
        let covered = anchored ? selectedConversation.flatMap {
            ContextSummarizer.load(conversationId: $0.id, profileId: $0.profileId)?.coveredCount
        } : nil
        guard let start = Self.anchoredWindowStart(fullCount: full.count, covered: covered, depth: depth) else {
            if let covered, covered > 0 {
                CacheDiagLog.shared.log("📝 历史窗口: 锚定失效（全 \(full.count)/覆盖 \(covered)/深度 \(depth)），退回滑动窗")
            }
            return (materializeAPIMessages(Array(full.suffix(depth)), imagesAllowed: imagesAllowed), full.count - depth)
        }
        return (materializeAPIMessages(Array(full.dropFirst(start)), imagesAllowed: imagesAllowed), start)
    }

    /// 纯函数（可测）：锚定窗口的起始下标。nil = 锚定不适用/失效 → 调用方退滑动窗。
    /// 适用：超窗 + 有摘要；失效：窗口 < depth（切分支 coveredCount 失配）或 > depth×2（摘要长期没跑成）。
    static func anchoredWindowStart(fullCount: Int, covered: Int?, depth: Int) -> Int? {
        guard fullCount > depth, let covered, covered > 0 else { return nil }
        let start = min(covered, fullCount)
        let windowCount = fullCount - start
        guard windowCount >= depth, windowCount <= depth * 2 else { return nil }
        return start
    }

    /// #089 P0-b：节点上存的工具调用 → 回放回合（过去回合的结果截 2KB，附存档路径）。不可回放（导入的空 id）→ nil
    private func toolReplayRounds(_ node: MessageNode) -> [ToolReplayRound]? {
        let convId = selectedConversation?.id ?? node.conversationId
        return ToolReplay.rounds(from: node.segments) { id, name in
            name == FileLibraryTools.Name.read.rawValue || Self.skipsOffload(name) ? nil
                : FileLibraryStore.toolResultVirtualPath(conversationId: convId, toolUseId: id, toolName: name)
        }
    }

    private static func hasToolUse(_ segments: [MessageSegment]?) -> Bool {
        segments?.contains { if case .toolUse = $0 { return true }; return false } ?? false
    }

    /// Send a user message and get a streaming response
    /// 用户手打消息的宏展开（与插槽一致：{{user}}/{{char}}/{{date}}/{{time}}/{{health}}/{{trading}}）。
    /// 发送/编辑时 bake 进消息——气泡和 AI 都看到展开后文本，历史保留当时的值。
    private func expandUserMacros(_ text: String, profile: Profile, context: ModelContext) -> String {
        // 修全局卡顿：健康 / 交易摘要只在消息里真写了 {{health}} / {{trading}} 时才算（以前每次发送都算一遍）
        let wantsHealth = text.range(of: "{{health}}", options: .caseInsensitive) != nil
        let wantsTrading = text.range(of: "{{trading}}", options: .caseInsensitive) != nil
        return MacroExpander.expand(text, userName: personaResolution(profile: profile).applied(to: profile).userName, charName: profile.assistantName,
                             health: wantsHealth ? HealthLogStore.composedHealthSummary(context: context, profileId: profile.id, grants: permGrants(for: selectedConversation)) : "",
                             trading: wantsTrading ? tradingSummaryForPrompt(context: context, profileId: profile.id) : "")
    }

    /// `{{trading}}` 取值；关掉私人子应用时恒为空（宏照常替换成空，不原样漏出）
    private func tradingSummaryForPrompt(context: ModelContext, profileId: String) -> String {
        #if PERSONAL_APPS
        TradingStore.composedTradingSummary(context: context, profileId: profileId, grants: permGrants(for: selectedConversation))
        #else
        ""
        #endif
    }

    @MainActor
    @discardableResult
    func sendMessage(
        _ text: String,
        model: ProviderModel,
        profile: Profile,
        preset: Preset,
        providerManager: ProviderManager,
        context: ModelContext,
        attachments: [PendingChatAttachment] = []
    ) -> Bool {
        // #026：整个发送一段——它结束之后还卡的部分 = 返回后的 UI 更新
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("sendMessage") : nil
        defer { if let airSpan { AirProbeRuntime.shared.finishedSection(airSpan) } }
        #endif
        #if PERSONAL_APPS
        // 死亡天平暗号兜底（cssChat / 语音 / 排队回放这些不经 ChatInputBar 的入口）
        if DeathScaleUnlock.matches(text) {
            DeathScaleUnlock.post()
            return true
        }
        #if os(iOS)
        if TutuSkinUnlock.matches(text) {
            if editingMessage == nil {
                selectedConversation?.draftText = ""
                selectedConversation?.draftAttachmentsData = nil
                selectedConversation?.draftQuotePreview = ""
                selectedConversation?.draftQuoteReplyTo = ""
                clearQuoting()
            }
            TutuSkinUnlock.post()
            return true
        }
        #endif
        #endif
        // 卡库 ⑧c：群聊只读归档不续聊
        guard let conversation = selectedConversation, !conversation.isReadOnlyArchive else { return false }
        commitDraftConversationIfNeeded(context: context)

        // CC 收口即发（plan-跨对话排队）：ccBridge 对话不进流式管线、不占全局 turn。
        let isCC = providerManager.provider(for: model)?.type == .ccBridge
        // 多 hub（B1 / B3.1）：新 CC 对话先定连哪台；那台用不了就不发、不回落主 hub，输入框留着
        if isCC {
            let blocked = MainActor.assumeIsolated { () -> Bool in
                hubRegistry.bindNewCCConversation(conversation)
                guard let why = ccSendBlocker(for: conversation) else { return false }
                transientNotice = TransientNotice(why.message)
                return true
            }
            if blocked { return false }
        }

        // API 与 CC 共用对话级门控；跨对话 CC 不占 API 的全局流。
        if isConversationSendBusy(conversation.id) || (!isCC && assistantTurnInFlight) {
            queuePendingSend(
                text, attachments: attachments, model: model, profile: profile,
                preset: preset, providerManager: providerManager, context: context,
                conversationId: conversation.id
            )
            return true   // 已受理（排队），UI 清输入框
        }

        // L3 斜杠命令路径：text 是 / 开头 + 当前 model 是 ccBridge → raw 直发不走 LLM 流式
        if isCC, text.hasPrefix("/"), !attachments.contains(where: { $0.kind == .card }) {   // 带卡片的斜杠文字按普通消息发
            sendCCSlashCommand(text, conversation: conversation, context: context)
            drainPending()
            return true
        }

        // 卡片是正文的一部分：宏只展开粟粟打的字，卡片块原样拼在后面（research-chat-cards §6 R1-10）。
        // 排队分支在此之前、原样保留卡片附件——取消排队时卡片回到附件条。
        let parts = ChatAttachmentPromptBuilder.userMessage(
            displayBase: applyInputRegex(expandUserMacros(text.trimmingCharacters(in: .whitespacesAndNewlines), profile: profile, context: context),
                                         role: "user", profile: profile, preset: preset),
            attachments: attachments)
        let modelText = parts.modelText
        guard !modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        SpeechService.shared.stop()
        guard AirTimedSection.run("sendMessage.preCheckBudget", {
            preCheckBudget(text: modelText, model: model, profile: profile, preset: preset, providerManager: providerManager)
        }) else { return false }
        if isCC {
            let user = appendUserNode(content: modelText, contentType: parts.contentType, segments: parts.segments,
                                      replyToId: quotingReplyTo, replyQuote: quotingPreview, conversation: conversation, context: context)
            commitSelection(to: user.id, conversation: conversation)
            conversation.updateTime = Date()
            markConversationDirty()
            preparePromptSend(conversation: conversation, profileId: profile.id, targetNodeId: user.id,
                              context: context, isCC: true, markCCUnsentOnAbort: true) { warmedWiki in
                let assembled = self.assemblePrompt(profile: profile, providerType: providerManager.provider(for: model)?.type, preset: preset, excludingNodeId: "",
                                                    context: context, globalEntries: self.globalWorldBookEntries,
                                                    fileLibraryHint: nil, conversation: conversation, warmedWiki: warmedWiki)
                let payload = self.prepareRouterPayload(assembled: assembled, model: model, conversation: conversation,
                                                        profile: profile, providerManager: providerManager, messageNodeId: user.id)
                self.sendCCFireAndForget(payload: payload, model: model, conversation: conversation,
                                         profile: profile, providerManager: providerManager)
            }
            try? context.save()
            scrollToNodeId = user.id
            clearQuoting()
            return true
        }

        assistantTurnInFlight = true
        activeConversationId = conversation.id
        BreadcrumbLog.shared.add("📤", "发送@「\(conversation.title)」（\(modelText.count)字）")

        // 1–2. 路径末尾建 user 节点（卡库第二批 B5 的 /send 共用 appendUserNode）
        let userNode = AirTimedSection.run("sendMessage.appendUserNode") {
            appendUserNode(content: modelText, contentType: parts.contentType, segments: parts.segments,
                           replyToId: quotingReplyTo, replyQuote: quotingPreview,
                           conversation: conversation, context: context)
        }

        // 3–6. 占位 assistant + 组装 / 发送 / 流式（卡库第二批 B5 的 /trigger 共用 startAssistantTurn，同一条管线）
        startAssistantTurn(after: userNode, scrollTo: userNode.id, clearsQuoting: true, model: model, profile: profile,
                           preset: preset, providerManager: providerManager, conversation: conversation, context: context)
        return true
    }

    /// 在路径末尾建一条 user 节点（第一条挂到对话的隐形根下：不挂的话第一条自己成了根，编辑不了——编辑是在父节点下开兄弟分支）
    @MainActor
    private func appendUserNode(content: String, contentType: String, segments: [MessageSegment]?,
                                replyToId: String?, replyQuote: String?,
                                conversation: Conversation, context: ModelContext) -> MessageNode {
        // 1. Determine parent node：路径末尾；第一条挂到对话的隐形根下
        let parentId = currentPath.last?.id ?? invisibleRootId()

        // 2. Create user MessageNode
        let userNodeId = UUID().uuidString
        let userNode = MessageNode(
            id: userNodeId,
            role: "user",
            content: content,
            contentType: contentType,
            createTime: Date(),
            parentId: parentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        if let segments {
            userNode.setSegments(segments, conversationTitle: selectedConversation?.title)
        }
        userNode.replyToId = replyToId   // A4：用户引用某条 → 存到消息（气泡显示引用条 + 传给 CC）
        userNode.replyQuote = replyQuote   // 选段文本落库：组装注入给 AI + 引用条精准显示
        userNode.cardEvents = cardEventOutbox.drain(conversation.id)   // §13：待捎带箱整箱挂到这条上
        // Style 快照（仅气泡 chip 显示用，不参与注入）：发送时定格当前 style，
        // 之后切 style 不影响历史 chip。空 = 发送时无 style（Normal）。
        if !conversation.currentStyleId.isEmpty {
            userNode.styleIdSnapshot = conversation.currentStyleId
        }
        context.insert(userNode)

        // Update parent's childrenIds
        if let parentId, let parent = nodeMap[parentId] {
            if !parent.childrenIds.contains(userNodeId) {
                parent.childrenIds.append(userNodeId)
            }
        }

        // Add to nodeMap and path
        nodeMap[userNodeId] = userNode
        effectiveChildrenMap[userNodeId] = []
        if let parentId {
            effectiveChildrenMap[parentId, default: []].append(userNodeId)
        }
        currentPath.append(userNode)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { perfPathRevision += 1 }
        #endif
        markPop(userNodeId)
        return userNode
    }

    @MainActor
    private func preparePromptSend(conversation: Conversation, profileId: String, targetNodeId: String,
                                   context: ModelContext, resolveAsks: Bool = false, isCC: Bool = false,
                                   abortLeafId: String? = nil, abortPath: [MessageNode]? = nil,
                                   markCCUnsentOnAbort: Bool = false,
                                   send: @escaping @MainActor (WikiInjectionCache.WarmedSnapshot?) -> Void) {
        guard let target = nodeMap[targetNodeId] else { return }
        let id = UUID()
        let conversationId = conversation.id
        let frozenPath = currentPath
        let predecessor = isCC ? ccPreparationTails[conversationId]?.task : nil
        promptPreparations[id] = PromptPreparation(
            id: id, conversation: conversation, target: target, context: context, ownsTurn: !isCC,
            abortLeafId: abortLeafId, abortPath: abortPath, markCCUnsentOnAbort: markCCUnsentOnAbort
        )
        if !isCC { activePromptPreparationId = id }
        func isCurrent() -> Bool {
            guard !Task.isCancelled, self.promptPreparations[id] != nil,
                  self.selectedConversation?.id == conversationId,
                  self.selectedConversation?.profileId == profileId else { return false }
            if isCC { return true }
            return self.activePromptPreparationId == id &&
                self.activeAssistantNodeId == targetNodeId &&
                self.currentPath.last?.id == targetNodeId &&
                conversation.currentNodeId == targetNodeId
        }
        let task = Task { @MainActor in
            defer {
                if isCC, self.ccPreparationTails[conversationId]?.id == id {
                    self.ccPreparationTails[conversationId] = nil
                    self.drainPending()
                }
            }
            if let predecessor { await predecessor.value }
            guard isCurrent() else { self.abortPromptPreparation(id); return }
            if resolveAsks {
                await self.resolveInjectionAsks(conversation: conversation, context: context)
                guard isCurrent() else { self.abortPromptPreparation(id); return }
            }
            do {
                let recallUser = frozenPath.last {
                    $0.role == "user" && !$0.isSyntheticRoot && !$0.isSourceHidden && !$0.isTrashed
                }
                let previous = self.cachedRecallReceipt(target)?.decision ?? recallUser.flatMap { self.cachedRecallReceipt($0)?.decision }
                let tuning = previous.flatMap { $0.turnId == recallUser?.id ? $0.tuning : nil }
                    ?? RecallTuningStore.load(profileId: profileId)
                var warmed: WikiInjectionCache.WarmedSnapshot?
                // 段④：值里已含本窗「档案」那一勾 / 触发开关；archiveTrigger 用回执里冻结的 tuning
                let participation = EffectiveMemoryParticipation.resolve(profileId: profileId, conversation: conversation,
                                                                         preset: nil,
                                                                         archiveTrigger: tuning.archiveTriggerEnabled)
                if participation.archive || participation.pages {
                    warmed = try await self.wikiInjectionCache.warm(profileId, WikiInjectionCache.source(profileId: profileId))
                } else {
                    warmed = nil
                }
                guard isCurrent() else { self.abortPromptPreparation(id); return }
                if participation.fullText,
                   let recallUser, !recallUser.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let snapshot = warmed?.snapshot {
                    let text = recallUser.content
                    let state = conversation.recallState
                    let keeping = ((previous?.selected ?? []) + state.active + state.pending).map(\.source).filter {
                        $0.kind == .card && $0.profileId == profileId && $0.conversationId == conversationId
                    }
                    let personaId = conversation.personaId
                    let defaultNames = [UserDefaults.standard.string(forKey: "userName") ?? "",
                                        UserDefaults.standard.string(forKey: "assistantName") ?? ""]
                    warmed?.fullText = await RecallFullTextRetriever.fetch(
                        profileId: profileId, text: text, snapshot: snapshot, excluding: {
                            MainThreadIO.assertOffMain(.read, "RecallFullTextRetriever.names")
                            let stored = ProfileManager.loadProfiles().first { $0.id == profileId }
                            let personaStore = UserPersonaStore.shared
                            let personas = await MainActor.run { personaStore.personas }
                            let persona = PersonaResolution.resolve(conversationPersonaId: personaId,
                                                                    floorPersonaId: stored?.personaId, personas: personas)
                            var names = defaultNames
                            if let stored {
                                let context = EffectiveCharacterContext(profile: persona.applied(to: stored))
                                names += [stored.userName, stored.assistantName, context.userName, context.charName]
                            }
                            if let name = persona.displayUserName { names.append(name) }
                            return names
                        }, tuning: tuning, source: WikiInjectionCache.source(profileId: profileId), indexer: .shared, keeping: keeping)
                }
                guard isCurrent() else { self.abortPromptPreparation(id); return }
                // E2-7b r4 M2：落库后 / 快照回写前进程退出过 → 任务表是空的，这里按已存的上窗 id 补冻
                self.resumePreviousWindowFreezeIfNeeded(conversation, context: context)
                // E2-7b：新窗冻结还在后台（第一句发得比冻结快）→ 等快照落好再组装
                await self.awaitPreviousWindowFreeze(conversationId)
                guard isCurrent() else { self.abortPromptPreparation(id); return }
                self.promptPreparations[id] = nil
                if self.activePromptPreparationId == id { self.activePromptPreparationId = nil }
                // 组装无 suspension：CC 每条只看到自己的冻结路径，不借用后来的消息。
                let displayedPath = self.currentPath
                if isCC { self.currentPath = frozenPath }
                send(warmed)
                if isCC { self.currentPath = displayedPath }
            } catch is CancellationError {
                self.abortPromptPreparation(id)
            } catch {
                self.abortPromptPreparation(id, failure: error.localizedDescription)
            }
        }
        promptPreparations[id]?.task = task
        if isCC { ccPreparationTails[conversationId] = (id, task) }
    }

    @MainActor
    private func cancelPromptPreparations(conversationId: String? = nil, drainQueued: Bool = true) {
        let cancelled: [QueuedCCSend]
        if let conversationId {
            cancelled = queuedCCSends.removeValue(forKey: conversationId) ?? []
            ccPreparationTails[conversationId] = nil
        } else {
            cancelled = queuedCCSends.values.flatMap { $0 }
            queuedCCSends.removeAll()
            ccPreparationTails.removeAll()
        }
        for item in cancelled {
            if let recovery = item.recovery { restoreToDraft(recovery) }
        }
        let ids = promptPreparations.values.filter { conversationId == nil || $0.conversation.id == conversationId }.map(\.id)
        for id in ids { abortPromptPreparation(id, drainQueued: false) }
        if drainQueued { drainPending() }
    }

    @MainActor
    private func abortPromptPreparation(_ id: UUID, failure: String? = nil, drainQueued: Bool = true) {
        guard let preparation = promptPreparations.removeValue(forKey: id) else { return }
        preparation.task?.cancel()
        let target = preparation.target
        let targetId = target.id
        let conversationId = preparation.conversation.id
        let profileId = preparation.conversation.profileId
        // 10-29 返工 #1：这一轮没发出去，收口登记作废；占位节点真被删掉、事件又是它从箱里取的 → 还回箱里
        reactionTurns[targetId] = nil
        let heldEvents = reactionEventOwners.remove(targetId) != nil ? target.cardEvents : []
        let storedNodes: [MessageNode]?
        if preparation.ownsTurn {
            storedNodes = try? preparation.context.fetch(FetchDescriptor<MessageNode>(
                predicate: #Predicate { $0.conversationId == conversationId && $0.profileId == profileId }))
        } else {
            storedNodes = []
        }
        let hasChildren = preparation.ownsTurn && (storedNodes == nil || !target.childrenIds.isEmpty ||
            storedNodes!.contains { $0.parentId == targetId })
        let failureReason = failure ?? (preparation.ownsTurn && hasChildren ? "准备已取消" :
            (!preparation.ownsTurn && preparation.markCCUnsentOnAbort ? "未发送" : nil))
        if let failureReason {
            if preparation.ownsTurn {
                target.content = ChatSystemMessage.errorLine("发送失败：\(failureReason)")
            } else {
                // 记在对话那台的账上；那台用不了就记在主 hub 账上（不可重发，只给气泡显示，不会发到主 hub）
                let tracker = (try? ccRoute(hubId: CCHubRegistry.hubId(of: preparation.conversation)).get()) ?? ccBridgeClient
                tracker.sendTracker.store.set(target.id, state: .failed, reason: failureReason,
                                              retryable: false, hasFrame: false)
            }
        } else if preparation.ownsTurn && target.content.isEmpty && target.segments?.isEmpty != false {
            let wasDisplayed = displayLeafId == target.id
            let restoreLeafId = preparation.abortLeafId ?? target.parentId
            if let parentId = target.parentId {
                let nodeParent = nodeMap[parentId] ?? (try? preparation.context.fetch(FetchDescriptor<MessageNode>(
                    predicate: #Predicate { $0.id == parentId })))?.first
                nodeParent?.childrenIds.removeAll { $0 == target.id }
                effectiveChildrenMap[parentId]?.removeAll { $0 == target.id }
                if preparation.conversation.currentNodeId == target.id, let restoreLeafId {
                    preparation.conversation.currentNodeId = restoreLeafId
                }
            }
            currentPath.removeAll { $0.id == target.id }
            nodeMap[target.id] = nil
            effectiveChildrenMap[target.id] = nil
            preparation.context.delete(target)
            restoreReactionEvents(heldEvents, conversationId: conversationId)
            if wasDisplayed {
                if let restoreLeafId, nodeMap[restoreLeafId] != nil {
                    commitSelection(to: restoreLeafId, conversation: preparation.conversation)
                    if let abortPath = preparation.abortPath {
                        currentPath = abortPath
                        displayLeafId = restoreLeafId
                    }
                } else {
                    displayLeafId = target.parentId
                }
            }
            rebuildBranchInfoMap()
        }
        if preparation.ownsTurn, hasChildren, selectedConversation?.id == conversationId {
            if let storedNodes {
                for node in storedNodes { nodeMap[node.id] = node }
                buildEffectiveChildrenMap()
                rebuildPath()
                if let leaf = displayLeafId, currentPath.last?.id == leaf,
                   ancestorChain(of: leaf).contains(targetId), childrenIds(for: leaf).isEmpty {
                    persistBranchSelection()
                } else {
                    treeReadFailed(conversationId: conversationId)
                }
            } else {
                treeReadFailed(conversationId: conversationId)
            }
        }
        try? preparation.context.save()
        guard preparation.ownsTurn, activePromptPreparationId == id else { return }
        activePromptPreparationId = nil
        assistantTurnInFlight = false
        activeAssistantNodeId = nil
        activeConversationId = nil
        streamingText = ""
        if drainQueued { drainPending() }
        ChatReactionTrigger.shared.turnDidEnd()
    }

    /// 在 parent 下建占位 assistant，组装 → 发送 → 流式。调用方已占好 turn（assistantTurnInFlight / activeConversationId）
    @MainActor
    private func startAssistantTurn(after parent: MessageNode, scrollTo: String, clearsQuoting: Bool,
                                    model: ProviderModel, profile: Profile, preset: Preset,
                                    providerManager: ProviderManager, conversation: Conversation, context: ModelContext,
                                    turnEvents: [ChatCardEvent] = []) {
        // 3. Create placeholder assistant node
        let assistantNodeId = UUID().uuidString
        let assistantNode = MessageNode(
            id: assistantNodeId,
            role: "assistant",
            content: "",
            contentType: "text",
            createTime: Date(),
            parentId: parent.id,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        if !turnEvents.isEmpty { assistantNode.cardEvents = turnEvents }   // 10-29：表情触发的这一轮，事件跟着回复节点走
        context.insert(assistantNode)
        if !turnEvents.isEmpty { reactionEventOwners.insert(assistantNodeId) }

        parent.childrenIds.append(assistantNodeId)
        nodeMap[assistantNodeId] = assistantNode
        effectiveChildrenMap[assistantNodeId] = []
        effectiveChildrenMap[parent.id, default: []].append(assistantNodeId)
        currentPath.append(assistantNode)
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { perfPathRevision += 1 }
        #endif
        markPop(assistantNodeId)

        // Update conversation
        commitSelection(to: assistantNodeId, conversation: conversation)
        conversation.updateTime = Date()
        markConversationDirty()

        activeAssistantNodeId = assistantNodeId
        streamingText = ""

        // 3.9 权限 askOnce 前置（plan-权限管理 §2）：注入类域设了「每次询问」且本对话未答过 → 弹卡等答案。
        // 组装以下步骤挪进 Task：ask 需要 await；无待问域时零弹卡直落。turn 防重入由前面的 inFlight 保证。
        if clearsQuoting { clearQuoting() }   // A4：引用值已烤进 payload header，清掉输入栏引用条
        scrollToNodeId = scrollTo
        preparePromptSend(conversation: conversation, profileId: profile.id, targetNodeId: assistantNodeId,
                          context: context, resolveAsks: true) { warmedWiki in

            // 4. 工具注入（文件库 fs_* + MCP 远程工具，进组装链 + preview 共用）
            let injection = self.toolInjection(for: model, providerManager: providerManager, conversation: conversation, profileId: conversation.profileId,
                                                   userName: profile.userName)
            ToolDrawerStore.shared.recordSent(conversationId: conversation.id, signature: ToolSignature(tools: injection.tools, offered: injection.offered))
            let fileHint = injection.systemHint.isEmpty ? nil : injection.systemHint

            // 5. Assemble prompt（注入段已进组装链，payload.systemPrompt 含「文件库」段）
            let assembled = self.assemblePrompt(profile: profile, providerType: providerManager.provider(for: model)?.type, preset: preset, excludingNodeId: assistantNodeId, context: context, globalEntries: self.globalWorldBookEntries, fileLibraryHint: fileHint, cardGuide: Self.cardGuideChoice(tools: injection.tools, offered: injection.offered, profileId: profile.id), conversation: conversation, warmedWiki: warmedWiki, imagesAllowed: VisionCapability.of(model, providerType: providerManager.provider(for: model)?.type) != .no)
            // 召回卡片：cc-bridge 发送会丢弃组装结果（只发 raw 文字），不写卡片数据免得撒谎
            if providerManager.provider(for: model)?.type != .ccBridge {
                assistantNode.setRecallHits(assembled.recallHits)
            }
            let payload = self.prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: assistantNodeId, offered: injection.offered)

            // 6. Stream（工具循环：模型不调工具时退化纯文本）
            self.runStreamingTurn(
                payload: payload, systemPrompt: payload.systemPrompt,
                model: model, providerManager: providerManager,
                conversation: conversation, assistantNode: assistantNode, assistantNodeId: assistantNodeId,
                profile: profile, preset: preset, context: context,
                tools: injection.tools, toolTurns: [], round: 0
            )
        }
    }

    // MARK: - 卡库第二批 B5：卡里网页替你发消息（/send、/trigger）

    /// `/send`：只在末尾追加一条用户消息，不生成。宏 / 输入正则与手动发送同一套（expandUserMacros → applyInputRegex）
    @MainActor
    @discardableResult
    func appendUserMessage(_ text: String, profile: Profile, preset: Preset, context: ModelContext) -> Bool {
        guard let conversation = selectedConversation, !conversation.isReadOnlyArchive else { return false }
        guard !assistantTurnInFlight, !isConversationSendBusy(conversation.id) else { return false }
        let base = applyInputRegex(expandUserMacros(text.trimmingCharacters(in: .whitespacesAndNewlines), profile: profile, context: context),
                                   role: "user", profile: profile, preset: preset)
        let parts = ChatAttachmentPromptBuilder.userMessage(displayBase: base, attachments: [])
        guard !parts.modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        commitDraftConversationIfNeeded(context: context)
        let userNode = appendUserNode(content: parts.modelText, contentType: parts.contentType, segments: parts.segments,
                                      replyToId: nil, replyQuote: nil, conversation: conversation, context: context)
        commitSelection(to: userNode.id, conversation: conversation)
        conversation.updateTime = Date()
        markConversationDirty()
        try? context.save()
        scrollToNodeId = userNode.id
        return true
    }

    /// `/trigger`：在当前末尾生成一次回复，走和发送同一条管线（startAssistantTurn：组装 / 正则 / 世界书 / 记忆 / persona 照常）。
    /// 生成中、空对话、Claude Code 对话不生成
    @MainActor
    @discardableResult
    func triggerReply(model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, context: ModelContext) -> Bool {
        guard let conversation = selectedConversation, !conversation.isReadOnlyArchive else { return false }
        guard !assistantTurnInFlight, !isConversationSendBusy(conversation.id), let parent = currentPath.last else { return false }
        guard providerManager.provider(for: model)?.type != .ccBridge else { return false }
        SpeechService.shared.stop()
        guard preCheckBudget(text: "", model: model, profile: profile, preset: preset, providerManager: providerManager) else { return false }
        commitDraftConversationIfNeeded(context: context)
        assistantTurnInFlight = true
        activeConversationId = conversation.id
        BreadcrumbLog.shared.add("📤", "卡里网页触发回复@「\(conversation.title)」")
        startAssistantTurn(after: parent, scrollTo: parent.id, clearsQuoting: false, model: model, profile: profile,
                           preset: preset, providerManager: providerManager, conversation: conversation, context: context)
        return true
    }

    /// 10-29 贴表情立刻生效：待捎带箱里有她新贴的表情 → 整箱取走、挂到新回复节点上、走 `/trigger` 同一条管线跑一轮。
    /// CC 对话单独发一帧（triggerCCReactionReply）。只在气泡对话；文章 / 只读 / 预算拦 / CC 没连上 = unsupported（表情留在箱里随下一条消息）
    @MainActor
    func triggerReactionReply(model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager,
                              context: ModelContext) -> ChatReactionTrigger.Outcome {
        guard let conversation = selectedConversation, !conversation.isReadOnlyArchive, conversation.isBubbleMode else { return .unsupported }
        let events = cardEventOutbox.events(for: conversation.id)
        guard events.contains(where: ChatReactionStore.isAddEvent), let parent = currentPath.last else { return .nothingPending }
        if providerManager.provider(for: model)?.type == .ccBridge {
            return triggerCCReactionReply(conversation: conversation, model: model, profile: profile, preset: preset,
                                          providerManager: providerManager)
        }
        guard !assistantTurnInFlight, !isConversationSendBusy(conversation.id) else { return .busy }
        SpeechService.shared.stop()
        guard preCheckBudget(text: "", model: model, profile: profile, preset: preset, providerManager: providerManager) else { return .unsupported }
        commitDraftConversationIfNeeded(context: context)
        let taken = cardEventOutbox.drain(conversation.id)
        assistantTurnInFlight = true
        activeConversationId = conversation.id
        BreadcrumbLog.shared.add("📤", "贴表情触发回复@「\(conversation.title)」（\(taken.count) 条事件）")
        startAssistantTurn(after: parent, scrollTo: parent.id, clearsQuoting: false, model: model, profile: profile,
                           preset: preset, providerManager: providerManager, conversation: conversation, context: context,
                           turnEvents: taken)
        return .sent
    }

    /// CC 对话贴表情（plan-cc-reactions-1105 第 1 步）：整箱事件单独发一帧 send 给 CC，不建她的泡。
    /// CC 在跑 / 在等她回答 = busy（等这轮收口）；连不上 = unsupported，事件留箱里跟下一条走、不弹提示条。
    /// 发出去以后事件不还回箱里（CC 的转录里已经有了）
    @MainActor
    private func triggerCCReactionReply(conversation: Conversation, model: ProviderModel, profile: Profile, preset: Preset,
                                        providerManager: ProviderManager) -> ChatReactionTrigger.Outcome {
        guard !isConversationSendBusy(conversation.id), !isCCTurnBusy(conversation) else { return .busy }
        guard let session = conversation.ccBridgeSessionName, !session.isEmpty,
              case .success(let ws) = ccRoute(hubId: CCHubRegistry.hubId(of: conversation)), ws.isConnected,
              preCheckBudget(text: "", model: model, profile: profile, preset: preset, providerManager: providerManager)
        else { return .unsupported }
        let taken = cardEventOutbox.drain(conversation.id)
        let content = VoicePromptInjector.bridgeContent(ChatCardEventPrompt.turnContent(taken), inCall: CallSession.activeSnapshot)
        ws.sendUserMessage(chatId: conversation.id, messageId: "react-" + UUID().uuidString, content: content,
                           user: profile.userName.isEmpty ? "user" : profile.userName, session: session, replyTo: nil,
                           attachments: [],
                           effort: Self.withEffectiveEffort(preset.sampling, model: model, providerManager: providerManager).reasoningEffort)
        markCCWaiting(conversation: conversation, ws: ws, providerManager: providerManager)
        BreadcrumbLog.shared.add("📤", "贴表情发给 CC（对话 \(conversation.id.prefix(8))，\(taken.count) 条事件）")
        return .sent
    }

    /// CC 这一轮还没完：等着回复（等待泡）、hub 阶段是干活中 / 等她回答。
    /// 没有阶段帧（老 hub / 没报 client_info）时，回复落地后 ccReplySettleGrace 秒内也算忙：V1 实测 CC 忙时塞进去的消息会并进当前轮
    @MainActor
    func isCCTurnBusy(_ conversation: Conversation, now: Date = Date()) -> Bool {
        if ccWaitingSince[conversation.id] != nil { return true }
        if let p = CCSessionPhaseStore.shared.phase(for: conversation.id, hubId: CCHubRegistry.hubId(of: conversation)) {
            return p.phase == .working || p.phase == .waiting
        }
        if let last = ccLastReplyAt[conversation.id], now.timeIntervalSince(last) < ccReplySettleGrace { return true }
        return false
    }

    /// hub 阶段帧说这个对话一轮收口了：清掉这台发出去的、比收口早的等待泡（重连快照里的旧 done 帧不清她刚发的新等待），
    /// 等着的贴表情马上再投一次
    @MainActor
    func ccTurnSettled(chatId: String, hubId: String, settledAt: Date) {
        if ccWaitingHub[chatId] == hubId, let since = ccWaitingSince[chatId], since <= settledAt {
            ccWaitingSince.removeValue(forKey: chatId)
        }
        ChatReactionTrigger.shared.turnDidEnd()
    }

    /// 一轮 API 回复的收口要用的东西：发起时就记下节点 / 对话 / context，收口不看当前选中的那棵树（10-29 返工 #3）。
    /// 登记集中在 runStreamingTurn（所有 API 回复都过它：发送 / 表情触发 / 重新生成 / 编辑重发 / 预算收尾），不在各入口补
    struct ReactionTurn {
        let node: MessageNode
        let conversation: Conversation
        let context: ModelContext
    }

    /// 这一轮不收口了（工具循环因 stop / 切楼层作废退出、切楼层）：注销登记，事件归属一起丢
    @MainActor
    private func dropReactionTurn(_ nodeId: String) {
        reactionTurns[nodeId] = nil
        reactionEventOwners.remove(nodeId)
    }

    /// 回合收口（气泡对话）：```react 块从正文删掉（末尾没收尾的一并丢掉）、贴到她的消息上，并往箱里记一笔让模型下轮知道自己贴过；
    /// 收口后什么都看不见（AI 选择不回 / 只贴了表情）→ 撤掉这个占位节点不留空泡，真撤掉了且事件是它从箱里取的才还回箱里。
    /// 只跑一次（登记取走即作废）。返回 true = 节点被撤掉了
    @MainActor
    @discardableResult
    private func settleReactionTurn(nodeId: String, allowRollback: Bool = true) -> Bool {
        let ownsEvents = reactionEventOwners.remove(nodeId) != nil
        guard let turn = reactionTurns.removeValue(forKey: nodeId) else { return false }
        let node = turn.node
        let conversation = turn.conversation
        let context = turn.context
        guard node.role == "assistant", conversation.isBubbleMode else { return false }
        let intents = ChatReactionIntent.consume(node)
        guard !intents.isEmpty || node.cardEventsData != nil else { return false }
        let ancestors = ancestorNodes(of: node, context: context)
        var notes: [(text: String, key: String)] = []
        for intent in intents {
            guard let target = ChatReactionIntent.target(for: intent, among: ancestors) else {
                BreadcrumbLog.shared.add("🙈", "AI 贴表情 \(intent.emoji) 没找到开头是「\(intent.hint.prefix(20))」的消息，不贴")
                continue
            }
            if reactionStore.addAIReaction(intent.emoji, on: target.id) {
                let snippet = ChatReactionTarget.snippet(from: String(target.content.prefix(200)))
                notes.append(("你给 ta 那条「\(snippet)」回了 \(intent.emoji)", "ai-reaction:\(target.id):\(intent.emoji)"))
            }
        }
        let events = node.cardEvents
        var removed = false
        if allowRollback, ChatReactionIntent.isSilent(node) {
            removed = rollbackSilentAssistant(node, conversation: conversation, context: context)
            if !removed { node.content = "（没有回复）" }
        }
        if removed, ownsEvents { restoreReactionEvents(events, conversationId: conversation.id) }
        for note in notes { cardEventOutbox.add(note.text, conversationId: conversation.id, key: note.key) }
        try? context.save()
        return removed
    }

    /// 还回没落地的触发事件（AI 不回 / 准备被取消）：保留原身份和顺序，同 key 有更新操作的不覆盖；
    /// 再按现在实际的表情状态核对一遍，对不上的扔掉（生成期间撤销过的不会被当成新贴的再叫一次模型）
    @MainActor
    private func restoreReactionEvents(_ events: [ChatCardEvent], conversationId: String) {
        guard !events.isEmpty else { return }
        cardEventOutbox.restore(events, conversationId: conversationId)
        for event in cardEventOutbox.events(for: conversationId) where event.carried == true && !reactionStore.stillHolds(event) {
            cardEventOutbox.remove(id: event.id, conversationId: conversationId)
        }
    }

    /// 这条回复自己的祖先链（新 → 旧），不看当前显示的路径：生成中切了分支 / 对话也找得对
    @MainActor
    private func ancestorNodes(of node: MessageNode, context: ModelContext) -> [MessageNode] {
        var result: [MessageNode] = []
        var seen: Set<String> = [node.id]
        var parentId = node.parentId
        while let pid = parentId, seen.insert(pid).inserted, result.count < 400, let parent = lookupNode(pid, context: context) {
            result.append(parent)
            parentId = parent.parentId
        }
        return result
    }

    @MainActor
    private func lookupNode(_ id: String, context: ModelContext) -> MessageNode? {
        if let node = nodeMap[id] { return node }
        var desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        return (try? context.fetch(desc))?.first
    }

    /// 撤掉一个什么都没说的回复节点（startAssistantTurn 的反操作）。父节点下还有别的回复（重新生成出来的）就不撤。
    /// 不管现在显示的是哪个对话 / 分支都改树；只有它还是当前显示的末端时才改当前选择
    @MainActor
    private func rollbackSilentAssistant(_ node: MessageNode, conversation: Conversation, context: ModelContext) -> Bool {
        guard let parentId = node.parentId, let parent = lookupNode(parentId, context: context),
              parent.childrenIds == [node.id] else { return false }
        parent.childrenIds.removeAll { $0 == node.id }
        if conversation.currentNodeId == node.id { conversation.currentNodeId = parentId }
        if selectedConversation?.id == conversation.id {
            let wasLeaf = displayLeafId == node.id
            effectiveChildrenMap[parentId]?.removeAll { $0 == node.id }
            effectiveChildrenMap[node.id] = nil
            nodeMap[node.id] = nil
            currentPath.removeAll { $0.id == node.id }
            if wasLeaf { commitSelection(to: parentId, conversation: conversation) }
            rebuildBranchInfoMap()
        }
        context.delete(node)
        return true
    }

    // MARK: - 权限（plan-权限管理）

    /// 当前对话的 askOnce 授权快照。
    private func permGrants(for conversation: Conversation?) -> PermissionGrants {
        PermissionGrants(raw: conversation?.permGrantsRaw)
    }

    /// 注入类域的 askOnce 前置弹卡：设了「每次询问」且本对话未答过的域逐个问，结果落 Conversation。
    @MainActor
    private func resolveInjectionAsks(conversation: Conversation, context: ModelContext) async {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("askOnce"); return }   // 测量角色旁路早退（perf P0 §3.2）
        #endif
        #if PERSONAL_APPS
        var askable: [PermissionDomain] = [.healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy, .trading, .images]
        #if DEBUG
        askable.append(.topicBox)
        #endif
        #else
        let askable: [PermissionDomain] = [.healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy, .images]
        #endif
        var grants = PermissionGrants(raw: conversation.permGrantsRaw)
        var changed = false
        for domain in askable where PermissionCenter.level(domain, profileId: conversation.profileId) == .askOnce && !grants.isResolved(domain) {
            guard !Task.isCancelled else { return }
            let decision = await injectionPermissionCenter.decide(domain)
            guard !Task.isCancelled else { return }
            guard decision != .timedOut else { continue }   // 超时不落档：这轮不注入，下轮再问
            grants.record(domain, allow: decision == .allowed)
            changed = true
        }
        if changed {
            conversation.permGrantsRaw = grants.raw
            try? context.save()
        }
    }

    /// 工具调用时闸（tool loop 用）：notAllowed 直接拒；askOnce 未答先弹卡。返回 nil = 放行，非 nil = 拒绝文案。
    @MainActor
    /// 工具过闸（审批卡，粟粟 10-03）：放行用哪份参数（卡上可能改过命令），或回给模型的拒绝说明
    private func toolPermissionGate(toolName: String, argumentsJSON: String = "", conversation: Conversation, context: ModelContext) async -> ToolGate {
        if toolName == AskUserTool.toolName || toolName == TurnStatusTool.toolName { return .proceed(argumentsJSON) }
        let domain = PermissionDomain.forTool(named: toolName)
        switch PermissionCenter.level(domain, profileId: conversation.profileId) {
        case .bypass:
            return .proceed(argumentsJSON)
        case .notAllowed:
            if let app = PermissionCenter.blockingApp(domain, profileId: conversation.profileId) {
                return .deny(PermissionCenter.notInstalledDenial(app))   // atrium P3⑥a：没装 App 挡住的，说清是哪个 App
            }
            return .deny("permission_denied：用户未允许「\(domain.displayName)」。\(PermissionCenter.adjustHint)")
        case .askOnce:
            var grants = PermissionGrants(raw: conversation.permGrantsRaw)
            if !grants.isResolved(domain) {
                // run_command 的弹卡带命令预览：只给第一行、截 80 字（plan-离线沙箱-phase1 §1.3）
                var detail: String? = nil
                if domain == .shell, let cmd = DeviceToolIO.str(DeviceToolIO.args(argumentsJSON), "command") {
                    let firstLine = cmd.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? cmd
                    detail = "$ " + String(firstLine.prefix(80))
                }
                #if os(macOS)
                // 编程会话：卡上写清这次要查什么（R-WN5 #10）
                if domain == .codingSessions { detail = CodingTools.permissionDetail(name: toolName, argumentsJSON: argumentsJSON) }
                #endif
                // 正看着这个对话：审批卡出在对话底部（完整命令 / 参数，可改命令，不超时）；否则照旧弹窗
                let decision: PermissionPromptCenter.Decision
                #if os(iOS)
                if domain == .browserOperate, BrowserOperator.shared.hasOpenBrowser {
                    // 花园浏览器正盖着聊天：卡出在浏览器里（plan-ai-browser-operate 收尾）
                    switch await BrowserOperator.shared.askPermission() {
                    case .once: decision = .allowedOnce
                    case .conversation: decision = .allowed
                    case .deny: decision = .deniedOnce
                    }
                } else {
                    decision = await PermissionPromptCenter.shared.decide(
                        domain, detail: detail,
                        approval: .init(conversationId: conversation.id, toolName: toolName, argumentsJSON: argumentsJSON, conversationGrant: true))
                }
                #else
                decision = await PermissionPromptCenter.shared.decide(
                    domain, detail: detail,
                    approval: .init(conversationId: conversation.id, toolName: toolName, argumentsJSON: argumentsJSON, conversationGrant: true))
                #endif
                // 超时（卡没弹出来 / 走开）、卡上「允许这一次 / 拒绝 / 改了再允许」都不写对话授权，下次再问
                let outcome = PermissionGate.outcome(decision, domain: domain, originalArgs: argumentsJSON)
                if let allow = outcome.record {
                    grants.record(domain, allow: allow)
                    conversation.permGrantsRaw = grants.raw
                    try? context.save()
                }
                return outcome.gate
            }
            return grants.isAllowed(domain) ? .proceed(argumentsJSON)
                : .deny("permission_denied：用户本次未允许「\(domain.displayName)」。\(PermissionCenter.adjustHint)")
        }
    }

    /// 加密值（plan-secure-ask §3/§4，只 run_command + MCP 调）：参数里有 {{secret:…}} 占位时**每次**弹卡问
    /// （不读写对话授权、不看 bypass 档，超时按拒），允许才用换好真值的参数执行，结果擦回占位再返回。
    /// 没占位 = 原参数直接执行。`execute` 拿到的 JSON 只在这次调用里用，别存。
    @MainActor
    private func runWithSecrets(toolName: String, argumentsJSON: String, conversationId: String,
                                execute: (String) async -> (text: String, isError: Bool)) async -> (text: String, isError: Bool) {
        guard !SecretVault.ids(in: argumentsJSON).isEmpty else { return await execute(argumentsJSON) }
        let sub = SecretVault.substitute(argumentsJSON, conversationId: conversationId)
        guard sub.problems.isEmpty else { return (sub.problems.joined(separator: "；") + "。本次未执行。", true) }
        let labels = sub.used.map { "【\($0.label)】" }.joined()
        var detail = toolName
        if toolName == RunCommandTool.toolName, let cmd = DeviceToolIO.str(DeviceToolIO.args(argumentsJSON), "command") {
            let firstLine = cmd.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? cmd
            detail += "：" + String(firstLine.prefix(80))
        }
        // 加密值每次都问、不能改参数（改了占位就对不上）：卡上没有「本对话都允许」和「修改」
        switch await PermissionPromptCenter.shared.decide(
            PermissionDomain.forTool(named: toolName), detail: detail, secretLabels: labels,
            approval: .init(conversationId: conversationId, toolName: toolName, argumentsJSON: argumentsJSON, conversationGrant: false)) {
        case .allowed, .allowedOnce, .modified:
            let r = await execute(sub.json)
            return (SecretVault.scrub(r.text, used: sub.used), r.isError)
        case .denied, .deniedOnce:
            return ("对方拒绝使用加密值\(labels)，本次未执行。", true)
        case .timedOut:
            return ("等对方确认使用加密值\(labels)超时，本次未执行。", true)
        }
    }

    // MARK: - Tool Loop

    /// 自带硬顶的工具不走结果外置：外置按字节头截，会截掉编程会话 get_session 页尾的 from_seq（R-WN5 #2）
    #if PERSONAL_APPS
    /// 死亡天平自己封顶 40KB，并且绝不能外置落进楼层文件
    #endif
    static func skipsOffload(_ name: String) -> Bool {
        #if PERSONAL_APPS
        if name == DeathScaleAITool.toolName { return true }
        #endif
        #if os(macOS)
        return CodingTools.names.contains(name)
        #else
        return false
        #endif
    }

    private static let maxToolRounds = 8
    /// 这一轮用到「AI 操作浏览器」时的上限：开 / 看 / 点 / 填各占一轮，8 轮做不完一件事（11-11 模拟器实测）
    private static let browserToolRounds = 24
    private static let budgetSummaryMaxTokens = 512
    private static let toolTruncationStopText = "（连续 2 轮工具参数超过输出上限，已停止。可以在预设里调大 Max Tokens，或者让我分段写。）"

    static func toolTruncatedMessage(name: String, cap: Int) -> String {
        "\(name) 的参数超过了本轮输出上限（\(cap) tokens），写到一半被截断，未执行。请把内容拆小：先用 fs_write 写开头一部分，再用 fs_append 分几次追加剩下的；其他工具请缩短参数。"
    }
    enum TuckedInvoke { case notWrapped, invalid(String), unwrapped(ToolCallBlock) }

    /// tool_invoke 包的是 tucked 里的内建工具（名字一字不差）→ 拆成真调用（同 id、保留截断标记）；
    /// 包的是别的（MCP、拼错的名字、清单里本来就有的）→ notWrapped，照旧交给 handleMetaTool。tucked 见 invokableBuiltins
    static func unwrapTuckedInvoke(_ call: ToolCallBlock, tucked: Set<String>) -> TuckedInvoke {
        guard call.name == MetaTools.invokeName,
              let outer = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any],
              let name = outer["name"] as? String, tucked.contains(name) else { return .notWrapped }
        guard let args = outer["arguments"] as? [String: Any] else {
            return .invalid("tool_invoke 的 arguments 要是一个对象（没有参数就填 {}），没有执行。")
        }
        let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .unwrapped(ToolCallBlock(id: call.id, name: name, argumentsJSON: json, truncated: call.truncated))
    }

    /// #093：工具循环里能拆包的内建工具 = 这一轮发出去的清单里没有的（收起的；抽屉 / 开关关着的拆了也会被执行前复查拒）。
    /// 按发出去的清单算、不按现读的抽屉：循环中途改档位，模型手上还是第一轮那份清单和〔更多工具〕
    @MainActor
    static func invokableBuiltins(sentTools: [[String: Any]]?) -> Set<String> {
        Set(ToolRegistry.all.map(\.definition.name)).subtracting(MetaTools.names).subtracting(ToolReplay.clientToolNames(sentTools))
    }

    /// 执行前复查（#069 / #093）：现读抽屉和开关，不用这一批开头的快照。nil gate = 这张卡不发工具，内建一律不执行
    @MainActor
    private func toolUnavailableNow(_ name: String, model: ProviderModel, providerManager: ProviderManager,
                                    profileId: String, conversation: Conversation?) -> Bool {
        guard let gate = toolGate(for: model, providerManager: providerManager, profileId: profileId, conversation: conversation) else {
            return ToolRegistry.all.contains { $0.definition.name == name }
        }
        return ToolRegistry.availability(of: name, gate) == false
    }

    /// 授权卡改过内层参数后，重新包回 tool_invoke 的参数形状
    static func rewrapInvoke(name: String, argumentsJSON: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let outer: [String: Any] = ["name": name, "arguments": args]
        return (try? JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? argumentsJSON
    }

    /// R8：执行 / 解析入口一律拿过滤后的参数（`.toolUse` 历史记录才用原样 replayArgs）；DEBUG 下测试经 executionArgsTap 看执行器收到什么
    static func executionArgs(_ call: ToolCallBlock) -> String {
        #if DEBUG
        executionArgsTap?(call.name, call.argumentsJSON)
        #endif
        return call.argumentsJSON
    }
    #if DEBUG
    static var executionArgsTap: ((_ name: String, _ argumentsJSON: String) -> Void)?
    #endif

    /// tool_invoke 拆出的内层参数：按真实工具的 schema 去掉中转塞的未声明顶层键（R8）；回给模型的仍是原样外层调用
    static func invokeInnerJSON(_ inner: [String: Any], schema: [String: Any]?) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: inner)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolCallPreflight.droppingUndeclared(json, schema: schema)
    }

    /// 执行前复查的拒绝文案。`memoryParticipationOff` = 本窗关了记忆参与（`writeTools == false`）：
    /// 五个写工具被拒是那个原因，不是抽屉里关着——照通用文案说会让对方去抽屉里看，而那一行显示开着
    static func toolUnavailableMessage(name: String, memoryParticipationOff: Bool = false) -> String {
        if memoryParticipationOff, ToolRegistry.memoryWriteNames.contains(name) {
            return "\(name)：这个对话关了记忆参与，remember / edit_memory / forget_memory / pending_notes / suggest_wiki_direction 这一轮没给你，这次做不了。如实告诉对方，不要再试。"
        }
        return "\(name) 这个工具现在没开（设置或工具抽屉里关着，这一轮没给你），这次做不了。如实告诉对方，不要再试。"
    }
    private static let budgetToolStopText = "（预算不足，已停止继续调用工具；已有工具结果已保留。）"
    private static let budgetSummaryInstruction = "预算已不足以继续调用工具。不要再调用任何工具，请基于已有工具结果直接给出简短总结。"
    /// MCP 工具数超过此值就 defer：不全量内联 schema，改用 3 个元工具（tool_search/inspect/invoke）让模型搜目录。
    /// fs_ 核心工具不受影响，始终内联。以后可换成 Cherry 的「占 context 比例」更精细的阈值。
    static let mcpDeferThreshold = 16

    /// 执行前复查用的门控语境（#069），同 toolInjectionDetailed 的算法：家族看卡类型、元工具看 MCP 数量。
    /// nil = 这张卡这一轮根本不发工具（找不到卡 / 卡关了工具调用）——内建工具一律不执行
    @MainActor
    private func toolGate(for model: ProviderModel, providerManager: ProviderManager, profileId: String,
                          conversation: Conversation?, userName: String = "") -> ToolGateContext? {
        guard let provider = providerManager.provider(for: model), provider.toolsSupported != false,
              provider.type != .ccBridge, provider.type != .localMLX else { return nil }
        let mcpCount = MCPProvider.shared.enabledTools(for: MCPProvider.shared.activeServerIds).count
        return ToolGateContext(family: provider.type == .anthropic ? .anthropic : .openAI,
                               deferMCP: mcpCount > Self.mcpDeferThreshold, profileId: profileId,
                               drawer: ToolDrawerStore.shared.state, userName: userName,
                               memoryWriteTools: EffectiveMemoryParticipation.resolve(profileId: profileId, conversation: conversation, preset: nil).writeTools)
    }

    /// 兼容旧调用：只下发文件库工具。真实发送路径使用 toolInjection。
    @MainActor
    func fileLibraryInjection(for model: ProviderModel, providerManager: ProviderManager, profileId: String) -> (tools: [[String: Any]]?, systemHint: String) {
        let injection = toolInjection(for: model, providerManager: providerManager, conversation: nil, profileId: profileId)
        return (injection.tools, injection.systemHint)
    }

    @MainActor
    /// 卡片说明放哪一版 + 这一轮能调到的工具名（实发 / 预览同一口径）：card_guide 下发或收在〔更多工具〕→ 目录；
    /// 对方关了 card_guide 或工具总开关 → 不放（粟粟 10-15 选 A）；其余（卡发不了工具）→ 全文
    static func cardGuideChoice(tools: [[String: Any]]?, offered: Set<String>?, profileId: String) -> (mode: ChatCardPromptGuide.Mode, tools: Set<String>?) {
        let available = offered ?? []
        if available.contains(CardGuideTool.toolName) || CardGuideTool.isOffered(in: tools) { return (.index, available) }
        let turnedOff = !PermissionCenter.capabilityEnabled(.toolsMaster, profileId: profileId)
            || ToolDrawerStore.shared.state.override(CardGuideTool.toolName, profileId: profileId) == .off
        return (turnedOff ? .none : .full, available)
    }

    /// 工具注入：该 model 下要下发的工具 + 要追加到 system 的提示。
    /// **实发（sendMessage）与上下文检查器（buildRequestJSON）共用此方法，杜绝预览/实发分叉。**
    @MainActor
    /// silent=true：预览路径用（cacheDashboard / previewTurn），不写 breadcrumb 和 probe 文件。
    /// 否则 UI 渲染每次都会调 toolInjection → add breadcrumb → @Observable 触发 view 重渲 → 又调 → 死循环。
    /// 实发路径（sendStreaming / regenerate / editAndResend）默认 silent=false 保持诊断日志。
    func toolInjection(for model: ProviderModel, providerManager: ProviderManager, conversation: Conversation?, profileId: String, silent: Bool = false,
                       userName: String = "") -> (tools: [[String: Any]]?, systemHint: String, tucked: [String], offered: Set<String>?) {
        let result = toolInjectionDetailed(for: model, providerManager: providerManager, conversation: conversation, profileId: profileId, silent: silent, userName: userName)
        return (result.tools, result.systemHint, result.tucked, result.offered)
    }

    /// 工具抽屉顶部的数字（#093 §2.4）：取模型 / 取工具和 previewTurn、实发同一套（silent，不写 breadcrumb），不跑 composePrompt。
    /// nil = 没有对话（设置页入口）
    @MainActor
    func previewTools(providerManager: ProviderManager, profileModelId: String?, globalModelId: String?) -> ToolDrawerPreview? {
        guard let conversation = selectedConversation else { return nil }
        let model = providerManager.resolveModel(conversationModelId: conversation.selectedModelId, profileModelId: profileModelId,
                                                 globalFallbackId: globalModelId)
        let injection: (tools: [[String: Any]]?, systemHint: String, absentReason: ToolsAbsentReason?, tucked: [String], offered: Set<String>?) =
            providerManager.provider(for: model)?.type == .ccBridge
            ? (nil, "", .ccBridge, [], nil)
            : toolInjectionDetailed(for: model, providerManager: providerManager, conversation: conversation,
                                    profileId: conversation.profileId, silent: true)
        return ToolDrawerPreview(tools: injection.tools, systemHint: injection.systemHint, tucked: injection.tucked,
                                 offered: injection.offered, absentReason: injection.absentReason, modelName: model.name.isEmpty ? model.modelId : model.name)
    }

    /// toolInjection 本体；absentReason 只给检查器说清「为什么一个工具都不发」
    @MainActor
    private func toolInjectionDetailed(for model: ProviderModel, providerManager: ProviderManager, conversation: Conversation?, profileId: String, silent: Bool,
                                       userName: String = "") -> (tools: [[String: Any]]?, systemHint: String, absentReason: ToolsAbsentReason?, tucked: [String], offered: Set<String>?) {
        guard let provider = providerManager.provider(for: model) else { return (nil, "", .cardNotFound, [], nil) }
        // 卡级「工具调用」开关（B 止血）：后端不带 function calling 的卡 = 不发 tools、不提工具（同 ccBridge 待遇）
        if provider.toolsSupported == false { return (nil, "", .cardToolsOff, [], nil) }
        // F4 工具总开关（设置-MCP）：关闭 = 请求不带 tools 字段，模型纯对话。
        // 场景：切到不受信任的中转站时，防模型按上下文惯性调工具把命令/结果明文暴露。
        guard PermissionCenter.capabilityEnabled(.toolsMaster, profileId: profileId) else { return (nil, "", .masterOff, [], nil) }
        // MCP 全局生效：enabled 的 server 对所有对话可用，不再按对话隔离（conversation 参数已不参与 MCP 选取）。
        let mcpServerIds = MCPProvider.shared.activeServerIds
        // MCP 工具太多就 defer：换成 3 个元工具让模型搜目录，省得工具海淹没模型。fs_ 不受影响。
        let mcpCatalog = MCPProvider.shared.enabledTools(for: mcpServerIds)
        let deferMCP = mcpCatalog.count > Self.mcpDeferThreshold
        // ccBridge 上游自带工具，这里不下发
        // 本机模型也不下发：工具 schema 太大，小模型扛不住（plan-小芽-v3 §1）
        if provider.type == .ccBridge { return (nil, "", .ccBridge, [], nil) }
        if provider.type == .localMLX { return (nil, "", .localModel, [], nil) }
        // chatgptOAuth 也用 OpenAI Chat Completions 风格的 tools；
        // ChatGPTOAuthProvider.buildRequestBody 内部会 map 成 Responses API 平铺格式
        let family: ToolGateContext.Family = provider.type == .anthropic ? .anthropic : .openAI
        let gate = ToolGateContext(family: family, deferMCP: deferMCP, profileId: profileId, drawer: ToolDrawerStore.shared.state, userName: userName,
                                   memoryWriteTools: EffectiveMemoryParticipation.resolve(profileId: profileId, conversation: conversation, preset: nil).writeTools)

        // 内建工具（fs_*9/心声/recall/搜索/browse/元工具）统一走注册表：定义+门控单一来源。
        // 注册表外的两个注入侧特例：MCP 动态工具（MCPProvider 自渲染）+ anthropic server 搜索（形状特殊）。
        // #069：平时用不到的收进「更多工具」，不进清单；这一轮可用的全集（直接给的 + 收起来的）给说明段判断提不提
        let builtinDefs = ToolRegistry.inlineDefinitions(gate)
        let tuckedDefs = ToolRegistry.tuckedDefinitions(gate).sorted { $0.name < $1.name }
        let builtinNames = Set((builtinDefs + tuckedDefs).map(\.name))
        let builtinTools = ToolSchemaRenderer.render(builtinDefs, family: family)
        let mcpTools: [[String: Any]] = deferMCP
            ? []   // 元工具已在注册表
            : (family == .anthropic ? MCPProvider.shared.anthropicTools(for: mcpServerIds)
                                    : MCPProvider.shared.openAITools(for: mcpServerIds))
        // anthropic 直连联网搜索走 server tool（Claude 后端执行，不依赖 client backend）；
        // browse_url 不发 anthropic——server tool 已一站式（搜+读+引用）
        var serverTools: [[String: Any]] = []
        if family == .anthropic, PermissionCenter.capabilityEnabled(.webSearch, profileId: profileId), ToolRegistry.serverWebSearchOn(gate) {
            serverTools = [WebSearchToolService.anthropicServerTool()]
        }

        func toolName(_ t: [String: Any]) -> String {
            (t["name"] as? String) ?? ((t["function"] as? [String: Any])?["name"] as? String) ?? ""
        }
        let searchTools = builtinTools.filter { toolName($0) == WebSearchToolService.toolName } + serverTools
        let browseTools = builtinTools.filter { toolName($0) == BrowseURLTool.toolName }
        // 诊断：搜索注入情况落 breadcrumb + probe 文件，方便排查"模型说没联网"。
        // silent=true 跳过——预览路径（cacheDashboard / previewTurn）每次 view 重算
        // 都会调 toolInjection，写 breadcrumb 触发 @Observable publish 把 view tree 锁死循环。
        if !silent {
            if WebSearchSettings.shared.searchEnabled {
                BreadcrumbLog.shared.add("🌐", "联网搜索注入：provider=\(provider.type) selected=\(WebSearchSettings.shared.selected?.kind.rawValue ?? "nil") search=\(searchTools.count) browse=\(browseTools.count)")
                WebSearchProbe.log("[toolInjection] enabled=true provider=\(provider.type) selected=\(WebSearchSettings.shared.selected?.kind.rawValue ?? "nil") searchTools=\(WebSearchProbe.summarizeTools(searchTools)) browseTools=\(WebSearchProbe.summarizeTools(browseTools)) total-tools=\(builtinTools.count + mcpTools.count + serverTools.count)")
            } else {
                WebSearchProbe.log("[toolInjection] enabled=false")
            }
        }
        // 工具按 name 字典序固定排序：顺序抖动 = prompt cache 整段 miss（无论哪家 provider）
        let tools = (builtinTools + mcpTools + serverTools).sorted { toolName($0) < toolName($1) }
        guard !tools.isEmpty else { return (nil, "", .noneEnabled, [], nil) }
        // 文件库说明跟着 fs_* 走（权限关了 / 抽屉里全关了都不发；收在〔更多工具〕里的也算能用）
        var hint = builtinNames.contains(where: { FileLibraryTools.Name(rawValue: $0) != nil }) ? fileLibrarySystemHint(profileId: profileId, available: builtinNames, tucked: Set(tuckedDefs.map(\.name))) : ""
        if !mcpCatalog.isEmpty {
            if !hint.isEmpty { hint += "\n\n" }
            if deferMCP {
                hint += "〔外部工具〕本对话有 \(mcpCatalog.count) 个 MCP 工具未直接展开。需要外部能力时：tool_search(关键词) 搜 → tool_inspect(名字) 看参数 → tool_invoke(名字, 参数) 调用。命名空间：\(MetaTools.namespacesSummary(mcpCatalog))"
            } else {
                hint += "## MCP 外部工具\n本对话已启用外部 MCP server。你可以按工具描述调用这些工具获取外部记忆、搜索或其他服务结果。"
            }
        }
        // 〔更多工具〕只随设置 / 平台变（不按当轮话术），前缀稳定
        if !tuckedDefs.isEmpty {
            if !hint.isEmpty { hint += "\n\n" }
            hint += "〔更多工具〕下面这些工具没放进工具清单，要用时直接 tool_invoke(name, arguments) 调；参数不清楚先 tool_inspect(names) 看：\n"
                + tuckedDefs.map { "- \($0.name) — \(ToolRegistry.blurb(for: $0))" }.joined(separator: "\n")
        }
        // 设备工具说明段（只提这一轮能调到的，前缀稳定）
        if builtinNames.contains(where: { DeviceToolDispatcher.handles($0) }) {
            if !hint.isEmpty { hint += "\n\n" }
            hint += DeviceToolDispatcher.systemHint(available: builtinNames)
            if let routing = DeviceToolDispatcher.timingHint(available: builtinNames) { hint += "\n" + routing }
        }
        // 固定一句（前缀稳定），职责边界与 fs_search 对仗
        if builtinNames.contains(RecallTool.toolName) {
            if !hint.isEmpty { hint += "\n\n" }
            hint += "〔回忆〕可用 recall 工具搜索我们的对话历史与你的记忆库（我们说过的话）；文件库笔记用 fs_search。"
        }
        // 第二刀返工：remember 在系统提示里得有一句（Air 验收：说「记住」只建了日历），固定文本、前缀稳定
        if builtinNames.contains(SelfMemoryTool.rememberName) {
            if !hint.isEmpty { hint += "\n\n" }
            hint += SelfMemoryTool.systemHint(available: builtinNames)
        }
        // 联网搜索 system 提示——client-side 才需要（教引用语法）；server tool 由 Anthropic 后端管
        // 10-15：按能调到的算（收进〔更多工具〕的也算）；browse_url 关了就给不提它的版本
        if builtinNames.contains(WebSearchToolService.toolName), family == .openAI {
            if !hint.isEmpty { hint += "\n\n" }
            let assistantName = (UserDefaults.standard.string(forKey: "assistantName") ?? "").trimmingCharacters(in: .whitespaces)
            hint += WebSearchToolService.systemPrompt(assistantName: assistantName, browse: builtinNames.contains(BrowseURLTool.toolName))
        }
        // #089 P1-c：能力说明按这一轮真实下发的工具生成（人设 / 预设里写的「某某暂时关闭」和这里冲突时以这里为准）。工具不变这段字就不变
        if !hint.isEmpty { hint += "\n\n" }
        hint += Self.capabilitySection(tools, hasTucked: !tuckedDefs.isEmpty)
        // #093：这一轮能调到的名字（历史回放判断「包回 tool_invoke 还是退纯文字」用）：清单里的 + 收起的 + defer 的 MCP 目录
        let offered = ToolReplay.clientToolNames(tools).union(tuckedDefs.map(\.name))
            .union(deferMCP ? mcpCatalog.map(\.tool.name) : [])
        return (tools, hint, nil, tuckedDefs.map(\.name), offered)
    }

    /// 元工具执行：tool_search/tool_inspect 查 MCP catalog + 收起来的内建（builtins）；tool_invoke 路由到真实 MCP 工具
    /// （包着收起来的内建工具的 tool_invoke 在 tool loop 开头已拆回真名，到不了这里）。
    @MainActor
    private func handleMetaTool(_ call: ToolCallBlock, mcpServerIds: [String], conversationId: String, builtins: [ToolDefinition]) async -> (text: String, isError: Bool, integrationName: String?) {
        let catalog = MCPProvider.shared.enabledTools(for: mcpServerIds)
        let reserved = Set(ToolRegistry.all.map(\.definition.name))
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case MetaTools.searchName:
            return (MetaTools.search(query: args["query"] as? String ?? "", catalog: catalog, builtins: builtins, reserved: reserved), false, "工具检索")
        case MetaTools.inspectName:
            let names = (args["names"] as? [Any])?.compactMap { $0 as? String }
                ?? (args["names"] as? String).map { [$0] } ?? []
            return (MetaTools.inspect(names: names, catalog: catalog, builtins: builtins, reserved: reserved), false, "工具检索")
        case MetaTools.invokeName:
            guard let rawName = args["name"] as? String, !rawName.isEmpty else {
                return ("tool_invoke 缺少 name 参数", true, "工具检索")
            }
            if reserved.contains(rawName) {
                return ("\(rawName) 不在「更多工具」里：它在工具清单里就直接调它，不在就是这一轮没开。", true, "工具检索")
            }
            guard let toolName = MetaTools.resolve(rawName, catalog: catalog) else {
                let valid = (builtins.map(\.name) + catalog.map { $0.tool.name }).joined(separator: ", ")
                return ("找不到工具「\(rawName)」。name 只填名字本身、别带来源。可用：\(valid)。先用 tool_search 确认。", true, "工具检索")
            }
            let innerJSON = Self.invokeInnerJSON(args["arguments"] as? [String: Any] ?? [:],
                                                 schema: catalog.first { $0.tool.name == toolName }?.tool.schemaAny())
            var serverName: String?
            let r = await runWithSecrets(toolName: toolName, argumentsJSON: innerJSON, conversationId: conversationId) { json in
                let m = await MCPProvider.shared.callToolText(serverIds: mcpServerIds, toolName: toolName, argumentsJSON: json)
                serverName = m.serverName
                return (m.text, m.isError)
            }
            return (r.text, r.isError, serverName ?? "MCP")
        default:
            return ("未知元工具: \(call.name)", true, nil)
        }
    }

    /// 注入 system prompt 的文件库说明 + 文件名清单（不含正文，上限 50）
    /// R2：books/ 从清单排除（章节文件会淹没 50 条坑），换成紧凑的「正在读」语境段
    /// available / tucked：这一轮能调到的 / 收起的工具名，默认模板里的工具清单只提能调到的；nil = 原样（测试 / 不关心工具的调用方）
    func fileLibrarySystemHint(profileId: String, available: Set<String>? = nil, tucked: Set<String> = []) -> String {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("ConversationViewModel.fileLibrarySystemHint") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        #if DEBUG
        let hintT0 = CACurrentMediaTime()
        #endif
        // journal/ 闸关时整夹不列（plan-calendar §4.3）
        // 修全局卡顿：发消息组 prompt 在主线程，只读缓存（旧了后台重扫），不再每次枚举整库
        // #00207 返工：以前每个文件都 FileLibraryAccess.visible（逐个 libraryRoot + 解符号链接 + 逐级 fileExists，~750 个文件 0.5 秒+），
        // 清单里的路径是枚举出来的真实路径，只看首段；闸只算一次
        #if DEBUG
        KBProbe.log(String(format: "[SENDPROBE] libraryHint list=%.1fms", (CACurrentMediaTime() - hintT0) * 1000))
        #endif
        // #089 P1 / P2：文件清单每轮会变、大半是附件照片——不再列进 system，改成〔状态〕里一行目录摘要
        let listing = Self.fileListPointer
        // pull 化（plan-memory-tree-v1 刀3）：碰过文件的全文默认不再注入 system——
        // 全文是"大而易变"段，模型每写一次文件下一轮 BP1 全 miss（research-context-topology A1）；
        // 模型需要内容时 fs_read 按需拉，工具结果固化进历史（append-only）对缓存天生友好。
        // fileLibraryFullContent=true 恢复旧行为（模型不主动读导致质量下降时的回滚开关，UserDefaults 手动设）
        var contentsSection = ""
        if UserDefaults.standard.bool(forKey: "fileLibraryFullContent") {
            var finalVersions = ""
            // 历史里的调用参数不代表当时读成功了：回注前同样过日历闸（astra #8）
            for path in touchedFilePaths().filter({ FileLibraryAccess.visible($0, profileId: profileId) }).prefix(10) {
                guard let content = try? FileLibraryStore.read(path, profileId: profileId) else { continue }
                let body = content.count > 4000 ? String(content.prefix(4000)) + "\n…（内容过长已截断）" : content
                finalVersions += "\n\n### \(path)\n\(body.isEmpty ? "（空文件）" : body)"
            }
            contentsSection = finalVersions.isEmpty ? "" : "\n\n本对话碰过的文件 · 当前最终内容\(finalVersions)"
        }

        // 模板可在设置页改（留空=默认）。占位符 {{files}} / {{fileContents}}
        let custom = UserDefaults.standard.string(forKey: "fileLibraryInjectionTemplate")
        let template = (custom?.isEmpty == false) ? custom!
            : available.map { FileLibraryTools.defaultInjectionTemplate.replacingOccurrences(
                of: FileLibraryTools.defaultToolSentence, with: FileLibraryTools.toolSentence(available: $0, tucked: tucked)) }
            ?? FileLibraryTools.defaultInjectionTemplate
        let filled = template
            .replacingOccurrences(of: "{{files}}", with: listing)
            .replacingOccurrences(of: "{{fileContents}}", with: contentsSection)
        // 记忆树提示是固定文本（不列文件名）——前缀稳定，具体内容让模型 fs_list/fs_read 按需拉
        // 「正在读」挪进〔状态〕（#089 P1：章节号每读一章就变）
        #if PERSONAL_APPS
        #if DEBUG
        let topicBox = topicBoxHint(profileId: profileId)
        #else
        let topicBox = ""
        #endif
        #else
        let topicBox = ""
        #endif
        let healthLog = healthLogHint(profileId: profileId)
        #if PERSONAL_APPS
        let tradeLog = tradeLogHint(profileId: profileId)
        #else
        let tradeLog = ""
        #endif
        let anniversary = AnniversaryIntentWriter.hint(profileId: profileId)
        // #069：fs_* 对 memory/ 只读，但 self 记忆和资料卡有专用写入口——别再说整棵树「系统生成、只读」
        // 10-15：只提这一轮能调到的写入口（available 为 nil = 按记忆开关，老口径）
        let selfTools = available.map { avail in [SelfMemoryTool.rememberName, SelfMemoryTool.editName, SelfMemoryTool.forgetName].filter(avail.contains) }
            ?? (SelfMemoryTool.enabled ? [SelfMemoryTool.rememberName, SelfMemoryTool.editName, SelfMemoryTool.forgetName] : [])
        let profileCardOn = available?.contains(ProfileCardTool.toolName) ?? true
        var memoryTreeHint = "记忆树：memory/ 下是楼层记忆（上下文摘要、窗口总结、时间轴、心声等），fs_* 工具对它只读，可用 fs_read / fs_search 查阅"
        if !selfTools.isEmpty { memoryTreeHint += "；其中 memory/self/ 是你自己的记忆，改它用 \(selfTools.joined(separator: " / "))" }
        if profileCardOn { memoryTreeHint += (selfTools.isEmpty ? "；" : "，") + "资料卡用 \(ProfileCardTool.toolName) 改" }
        memoryTreeHint += "。"
        return "<文件库>\n\(filled)\(topicBox)\(healthLog)\(tradeLog)\(anniversary)\n\(memoryTreeHint)\(CCMemorySync.promptHint(profileId: profileId))过长的工具结果会存档在 tool-results/（只读），结果里给了路径时用 fs_read(path, offset, limit) 分段取回。\n</文件库>"
    }

    #if PERSONAL_APPS
    #if DEBUG
    /// 话题盒约定段：纯静态文本（无日期无清单——prompt 前缀逐字稳定，缓存安全），
    /// {{user}} 走 PromptAssembler 文件库段现有 applyMacros。开关默认开。
    private func topicBoxHint(profileId: String) -> String {
        guard PermissionCenter.injectionAllowed(.topicBox, profileId: profileId, grants: permGrants(for: selectedConversation)) else { return "" }
        return "\ntopics/ 目录是「话题盒」——你和 {{user}} 共用的问题池，存放值得琢磨的问题（哲学、理论、任何有趣的困惑）。聊天中遇到这样的问题，可以用 fs_write 存一张卡：路径 topics/<问题短句>.md，第一行写问题本身；也可以用 fs_read 翻已有的卡，用 fs_append 在某张卡的「## 回应」下追加你的想法，小节格式：### 日期 · 你的名字。不必刻意，自然遇到才存。"
    }
    #endif
    #endif

    /// R2 聊天内看书：「她正在读的书」语境 + 批注意向协议（零新工具——书就是文件库文件，
    /// 读=fs_read 原语；写批注=回复内嵌 book-note 块，系统做锚定落地）。没书 = 空串零污染。
    private func currentBookHint(profileId: String) -> String {
        var desc = FetchDescriptor<BookEntry>(
            predicate: #Predicate<BookEntry> { $0.profileId == profileId },
            sortBy: [SortDescriptor(\BookEntry.lastReadAt, order: .reverse)]
        )
        desc.fetchLimit = 1
        guard let ctx = selectedConversation?.modelContext,
              let book = (try? ctx.fetch(desc))?.first else { return "" }
        return """
        \n{{user}} 正在读：《\(book.name)》第 \(book.currentChapter)/\(book.totalChapters) 章。
        想一起读：fs_read books/\(book.id)/\(String(format: "chapter_%04d.txt", book.currentChapter))（fs_list 可看全部章节；批注在 books/\(book.id)/notes.json，只读——不要直接改它）。
        读完想在书页留批注，在回复中输出代码块（可多个）：
        ```book-note
        {"book": "\(book.id)", "chapter": \(book.currentChapter), "anchorText": "章节原文一字不差的引用（20-60字）", "comment": "你的批注", "replyToAnchor": "{{user}} 批注的原文（仅回复对方批注时带）"}
        ```
        系统会把它锚定到书页上（anchorText 必须与原文完全一致，否则定位失败被丢弃）。
        """
    }

    #if PERSONAL_APPS
    /// 交易手账约定段（```trade 意向协议第四例，plan-trading-t1-journal）：
    /// 闸随 {{trading}} 总闸（AI 看得见交易=才教它记）+ 域守卫（无未平卡不教 close/review）。
    /// 拷问段是松弛版方向不是问卷——措辞集中在这，粟粟要调只改这一处。
    private func tradeLogHint(profileId: String) -> String {
        guard PermissionCenter.injectionAllowed(.trading, profileId: profileId, grants: permGrants(for: selectedConversation)) else { return "" }
        guard let ctx = selectedConversation?.modelContext else { return "" }
        let openCount = TradingStore.openTradeCount(context: ctx, profileId: profileId)

        var hint = """

        交易手账：{{user}} 明确说了开仓/买入某标的（含数量和价格）时，在回复里输出：
        ```trade
        {"type": "open", "symbol": "NVDA", "side": "long", "qty": 100, "price": 180.5, "reason": "{{user}}说的开仓理由，用{{user}}的原话概括"}
        ```
        reason 必填——那是这张卡的灵魂，之后复盘全靠它。做空 side 用 "short"。
        """
        if openCount > 0 {
            hint += """

        {{user}}说平仓/卖了 → `{"type": "close", "symbol": "NVDA", "price": 195.0}`（price 可省）。
        复盘对话聊出结论后 → `{"type": "review", "symbol": "NVDA", "note": "{{user}}认可的结论"}`。
        {{user}}想复盘某笔交易时：先把那张卡的开仓理由原文引用给{{user}}看（注入里有），围绕"当时的判断 vs 后来发生的"自然展开——论点验证了吗、纪律守住没、如果重来。别列问卷，像聊天一样。档案里有该标的研报的话可以对照着看（fs_read trading/ 目录）。聊透了再用 review 块把{{user}}认可的结论挂回卡。
        """
        }
        hint += "\n系统会真实落卡并把块变成结果行。只在{{user}}明确说了才记，不要猜测。\n"
        return hint
    }
    #endif

    /// 健康手账约定段（```health-log 意向协议，plan-health-chat-entry）：
    /// 闸+域双守卫——读闸关 = 不教 AI 写（语义一致零新开关）；域空 = 零污染。
    private func healthLogHint(profileId: String) -> String {
        guard let ctx = selectedConversation?.modelContext else { return "" }
        // 读这一层的档位（老 Bool 键只是默认的投影，atrium P3⑤0）；`== .bypass` 同老投影口径
        let weightOn = PermissionCenter.level(.healthWeight, profileId: profileId) == .bypass
            && !HealthLogStore.fetchRecentWeights(context: ctx, profileId: profileId, limit: 1).isEmpty
        let meds = PermissionCenter.level(.healthMeds, profileId: profileId) == .bypass
            ? HealthLogStore.fetchActiveMeds(context: ctx, profileId: profileId) : []
        // cycle/intimacy 只看闸不看域：敏感闸手动开 = 明确要用，教 AI 记第一笔有价值
        let cycleOn = PermissionCenter.level(.healthCycle, profileId: profileId) == .bypass
        let intimacyOn = PermissionCenter.level(.healthIntimacy, profileId: profileId) == .bypass
        guard weightOn || !meds.isEmpty || cycleOn || intimacyOn else { return "" }

        let example = weightOn
            ? "{\"type\": \"weight\", \"kg\": 52.3}"
            : (!meds.isEmpty
                ? "{\"type\": \"med\", \"name\": \"药名\", \"time\": \"8:00\"}"
                : (cycleOn
                    ? "{\"type\": \"cycle\", \"flow\": \"medium\"}"
                    : "{\"type\": \"intimacy\"}"))
        var lines = """
        \n{{user}} 在用健康手账。{{user}}口头告诉你健康记录时（"我吃药了""今天 52.3"），在回复中输出代码块帮{{user}}记下，一块一条 JSON，可多块：
        ```health-log
        \(example)
        ```
        """
        if weightOn, !meds.isEmpty {
            lines += "\n吃药打卡用 {\"type\": \"med\", \"name\": \"药名\", \"time\": \"8:00\"}（time 可省略=就近计划时刻）。"
        }
        if !meds.isEmpty {
            lines += "\n当前在吃的药见〔状态〕。"   // #089 P1：药单会变，挪进〔状态〕
        }
        if cycleOn {
            lines += "\n月经打点用 {\"type\": \"cycle\", \"flow\": \"medium\"}（flow: spotting/light/medium/heavy，date 可补记）。"
        }
        if intimacyOn {
            lines += "\n亲密记录用 {\"type\": \"intimacy\"}（date/note 可选）。"
        }
        lines += "\n系统会真实落库并把块变成结果行。只在{{user}}明确说了才记，不要猜测。"
        return lines
    }

    /// #089 P1-c：「这一轮工具清单里实际有的」，一行一个名字 + 描述的第一句。顺序同工具清单（已按名字排好）
    static func capabilitySection(_ tools: [[String: Any]], hasTucked: Bool = true) -> String {
        let lines = tools.compactMap { tool -> String? in
            let fn = tool["function"] as? [String: Any]
            guard let name = (tool["name"] as? String) ?? (fn?["name"] as? String), !name.isEmpty else { return nil }
            let desc = (tool["description"] as? String) ?? (fn?["description"] as? String) ?? ""
            if desc.isEmpty { return tool["type"] != nil ? "- \(name)（服务端执行）" : "- \(name)" }
            return "- \(name) — \(ToolRegistry.firstSentence(desc))"
        }
        // 没有收起的工具就不提〔更多工具〕（粟粟 10-15：关了的不带说明）
        return "〔当前能用的工具〕这一轮工具清单里实际有这些（人设或预设里关于哪些工具开着、关着的说法和这里冲突时，以这里为准\(hasTucked ? "；〔更多工具〕里列的也能用" : "")）：\n"
            + lines.joined(separator: "\n")
    }

    // MARK: - #089 P1〔状态〕：每轮会变的东西不进 system（一变 system + 全部历史的缓存都废），挂在最新一条用户消息前

    static let fileListPointer = "（文件清单不在这里列：每条消息前的〔状态〕里有各目录的文件数，具体文件用 fs_list 查看）"

    /// library = 这轮有文件库说明（工具开着、文件库开着）：正在读 / 药单 / 文件库摘要跟着它（以前都在文件库说明里）
    func turnStatusNote(profileId: String, library: Bool) -> String? {
        // P1-b：当前时间一直写（不看「时间感知」开关），精确到分钟；人设时区不同时 CharacterTimeContext 照旧另给一行
        var lines = [Self.statusTimeLine(now: MemoryClock.now)]
        if library {
            let reading = currentBookHint(profileId: profileId).trimmingCharacters(in: .whitespacesAndNewlines)
            if !reading.isEmpty { lines.append(reading) }
            if let meds = medsStatusLine(profileId: profileId) { lines.append(meds) }
            lines.append(fileLibrarySummary(profileId: profileId))
        }
        return lines.isEmpty ? nil : "〔状态〕\n" + lines.joined(separator: "\n")
    }

    /// 现在：2026-10-11 周日 21:40（UTC+8 Asia/Shanghai）
    static func statusTimeLine(now: Date, timeZone: TimeZone = NSTimeZone.default) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd EEE HH:mm"
        let secs = timeZone.secondsFromGMT(for: now)
        let minutes = abs(secs) % 3600 / 60
        let offset = "UTC" + (secs < 0 ? "-" : "+") + "\(abs(secs) / 3600)" + (minutes > 0 ? String(format: ":%02d", minutes) : "")
        return "现在：\(f.string(from: now))（\(offset) \(timeZone.identifier)）"
    }

    private func medsStatusLine(profileId: String) -> String? {
        guard PermissionCenter.level(.healthMeds, profileId: profileId) == .bypass, let ctx = selectedConversation?.modelContext else { return nil }
        let meds = HealthLogStore.fetchActiveMeds(context: ctx, profileId: profileId)
        guard !meds.isEmpty else { return nil }
        return "当前的药：\(Self.mergedMedsText(meds.map { ($0.name, $0.timesOfDay) }))。"
    }

    /// #089 P3-a：同名的药合成一条、时间取并集（一种药一天可能吃好几次；库里的同名多行不动）
    static func mergedMedsText(_ meds: [(name: String, minutes: [Int])]) -> String {
        var order: [String] = []
        var times: [String: Set<Int>] = [:]
        for med in meds {
            if times[med.name] == nil { order.append(med.name) }
            times[med.name, default: []].formUnion(med.minutes)
        }
        return order.map { name in
            "\(name)（\((times[name] ?? []).sorted().map(HealthLogStore.timeText).joined(separator: "/"))）"
        }.joined(separator: "、")
    }

    /// 文件库一行目录摘要（只读清单缓存，不枚举盘）：顶层目录各几个文件，books/ 不算（正在读另有一行）
    func fileLibrarySummary(profileId: String) -> String {
        let journalVisible = CalendarPrivacy().journalVisible(profileId)
        let files = FileLibraryStore.cachedList(profileId: profileId, skippingTopLevelDirs: ["books"])
            .filter { !$0.path.hasPrefix("books/") && FileLibraryAccess.listedVisible($0.path, journalVisible: journalVisible) }
        return Self.fileLibrarySummaryLine(paths: files.map(\.path))
    }

    static func fileLibrarySummaryLine(paths: [String]) -> String {
        guard !paths.isEmpty else { return "文件库：空" }
        var counts: [String: Int] = [:]
        var rootCount = 0
        for path in paths {
            if let slash = path.firstIndex(of: "/") {
                counts[String(path[..<slash]), default: 0] += 1
            } else {
                rootCount += 1
            }
        }
        var parts = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        if rootCount > 0 { parts.append("根目录 \(rootCount)") }
        return "文件库：\(parts.joined(separator: " / "))（共 \(paths.count) 个，具体文件用 fs_list 查看）"
    }

    /// 扫本对话路径，收集小克 write/edit/read 碰过的文件路径（去重、保留首次出现顺序）。
    private func touchedFilePaths() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for node in currentPath where node.role == "assistant" {
            guard let segs = node.segments else { continue }
            for seg in segs {
                guard case .toolUse(_, let name, let inputJSON, _, _) = seg,
                      name == "fs_write" || name == "fs_edit" || name == "fs_read" else { continue }
                let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
                if let path = args["path"] as? String, !path.isEmpty, !seen.contains(path) {
                    seen.insert(path)
                    ordered.append(path)
                }
            }
        }
        return ordered
    }

    /// thinking 回传 §3.2：原逻辑跑完后挂这一次回复的思考段。base = 原逻辑追加前的段数（工具节点：插在这次追加的段前面）；
    /// nil = 普通回复，存成 `[.text(content), 思考…]`（astra #4：老版本按分段渲染也看得到正文；新版本认 `isAttachedThinkingReply` 照旧按 content 渲染），contentType 不变。
    /// 正文为空 / 只剩「⚠️ 出错」「（已停止）」也照挂（只想了没说完的思考不丢）；没正文时不画空正文泡由显示层管（CardFlowView.hasMessageBody）
    static func attachThinking(_ thinking: [MessageSegment], to node: MessageNode, base: Int?) {
        guard !thinking.isEmpty else { return }
        if let base, var segs = node.segments, base <= segs.count {
            segs.insert(contentsOf: thinking, at: base)
            node.setSegments(segs)
        } else if base == nil, (node.segments ?? []).isEmpty {
            node.setSegments([.text(node.content)] + thinking)
        }
    }

    /// 调工具那一次回复里工具段之前的段：思考 → 正文 → 进度更新思考（按回复顺序；工具调用之间的进度更新思考也放这里，只影响显示）。
    /// 没有块（OpenAI 兼容）= 有思考时 [思考, 正文]（思考总在正文前），没有就只有正文，和以前一样
    static func replySegments(_ blocks: [ReplyBlock], text: String, reasoning: ReasoningCapture? = nil) -> [MessageSegment] {
        if blocks.isEmpty, let thinking = reasoning?.segment {
            return text.isEmpty ? [thinking] : [thinking, .text(text)]
        }
        var out: [MessageSegment] = []
        var textPlaced = text.isEmpty
        for block in blocks {
            if let seg = block.thinkingSegment {
                out.append(seg)
            } else if block.type == "text", !textPlaced {
                out.append(.text(text))
                textPlaced = true
            }
        }
        if !textPlaced { out.append(.text(text)) }
        return out
    }

    private static func toolTurnsEstimateText(_ toolTurns: [ToolTurn]) -> String {
        toolTurns.flatMap { turn in
            turn.calls.map { "tool_call \($0.id) \($0.name) \($0.argumentsJSON)" }
                + turn.results.map { "tool_result \($0.toolUseId) \($0.text)" }
                + [turn.reasoning?.text].compactMap { $0 }.filter { !$0.isEmpty }.map { "reasoning \($0)" }
        }.joined(separator: "\n")
    }

    private func preCheckToolRequestBudget(
        payload: (messages: [(role: String, content: String)], systemPrompt: String?, sampling: SamplingParams, additionalHeaders: [String: String], imageMap: [String: [PendingChatAttachment]], ordered: [PromptMessage]),
        systemPrompt: String?,
        tools: [[String: Any]]?,
        toolTurns: [ToolTurn],
        model: ProviderModel,
        providerManager: ProviderManager,
        maxOutputTokens: Int
    ) -> Bool {
        guard let provider = providerManager.provider(for: model) else { return true }
        var messages = payload.messages
        let toolText = Self.toolTurnsEstimateText(toolTurns)
        if !toolText.isEmpty { messages.append((role: "tool", content: toolText)) }
        if let tools,
           let data = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys]) {
            messages.append((role: "system", content: String(decoding: data, as: UTF8.self)))
        }
        let estimated = BudgetCalculator.estimateCost(
            provider: provider,
            modelId: model.modelId,
            messages: messages,
            systemPrompt: systemPrompt,
            maxOutputTokens: maxOutputTokens,
            estimator: HeuristicEstimator()
        )
        pendingEstimatedCost = estimated
        if BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: estimated) { return true }
        switch providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated) {
        case .ok, .disabled, .warning:
            return true
        case .blocked(let spent, let budget):
            budgetBlockedMessage = Self.blockedMessage(providerName: provider.name, spent: spent, budget: budget)
            pendingEstimatedCost = 0
            return false
        }
    }

    private static func addingBudgetSummaryInstruction(to toolTurns: [ToolTurn]) -> [ToolTurn] {
        guard var lastTurn = toolTurns.last, !lastTurn.results.isEmpty else { return toolTurns }
        var turns = toolTurns
        let lastResult = lastTurn.results.removeLast()
        lastTurn.results.append(ToolResultBlock(
            toolUseId: lastResult.toolUseId,
            text: lastResult.text + "\n\n" + budgetSummaryInstruction,
            isError: lastResult.isError
        ))
        turns[turns.count - 1] = lastTurn
        return turns
    }

    private func continueToolLoop(
        payload: (messages: [(role: String, content: String)], systemPrompt: String?, sampling: SamplingParams, additionalHeaders: [String: String], imageMap: [String: [PendingChatAttachment]], ordered: [PromptMessage]),
        systemPrompt: String?,
        model: ProviderModel,
        providerManager: ProviderManager,
        conversation: Conversation,
        assistantNode: MessageNode,
        assistantNodeId: String,
        profile: Profile,
        preset: Preset,
        context: ModelContext,
        tools: [[String: Any]]?,
        toolTurns: [ToolTurn],
        round: Int
    ) {
        if preCheckToolRequestBudget(
            payload: payload,
            systemPrompt: systemPrompt,
            tools: tools,
            toolTurns: toolTurns,
            model: model,
            providerManager: providerManager,
            maxOutputTokens: OutputTokenCap.budgetEstimate(preset.sampling, modelId: model.modelId)
        ) {
            runStreamingTurn(
                payload: payload, systemPrompt: systemPrompt,
                model: model, providerManager: providerManager,
                conversation: conversation, assistantNode: assistantNode, assistantNodeId: assistantNodeId,
                profile: profile, preset: preset, context: context,
                tools: tools, toolTurns: toolTurns, round: round
            )
            return
        }

        var segs = assistantNode.segments ?? []
        segs.append(.text(Self.budgetToolStopText))
        assistantNode.setSegments(segs)
        assistantNode.contentType = "segmented"
        if assistantNode.content.isEmpty { assistantNode.content = Self.budgetToolStopText }
        try? context.save()

        // 收尾这次 tools: nil = tools 变了，当轮思考块的前缀跟着变（plan-thinking §3.3 / R8）→ 这一次不带思考块
        let summaryTurns = Self.addingBudgetSummaryInstruction(to: toolTurns).map { $0.droppingThinking() }
        let droppedThinking = toolTurns.reduce(0) { $0 + $1.thinkingBlockCount }
        if droppedThinking > 0 { CacheDiagLog.shared.log("🧠 预算收尾不带 tools：当轮 \(droppedThinking) 个思考块这一次没带") }
        var summarySampling = payload.sampling
        summarySampling.maxTokens = min(OutputTokenCap.resolved(payload.sampling, modelId: model.modelId).maxTokens, Self.budgetSummaryMaxTokens)
        summarySampling.maxTokensAuto = false
        let summaryPayload = (
            messages: payload.messages,
            systemPrompt: payload.systemPrompt,
            sampling: summarySampling,
            additionalHeaders: payload.additionalHeaders,
            imageMap: payload.imageMap,
            ordered: payload.ordered
        )
        guard preCheckToolRequestBudget(
            payload: summaryPayload,
            systemPrompt: systemPrompt,
            tools: nil,
            toolTurns: summaryTurns,
            model: model,
            providerManager: providerManager,
            maxOutputTokens: summarySampling.maxTokens
        ) else {
            finishAssistantTurn()
            return
        }
        runStreamingTurn(
            payload: summaryPayload, systemPrompt: systemPrompt,
            model: model, providerManager: providerManager,
            conversation: conversation, assistantNode: assistantNode, assistantNodeId: assistantNodeId,
            profile: profile, preset: preset, context: context,
            tools: nil, toolTurns: summaryTurns, round: round, isBudgetSummary: true
        )
    }

    /// 单轮流式 + 工具循环：模型回 tool_call 就执行、回灌、再请求；纯文本收尾走原收尾逻辑。
    private func runStreamingTurn(
        payload: (messages: [(role: String, content: String)], systemPrompt: String?, sampling: SamplingParams, additionalHeaders: [String: String], imageMap: [String: [PendingChatAttachment]], ordered: [PromptMessage]),
        systemPrompt: String?,
        model: ProviderModel,
        providerManager: ProviderManager,
        conversation: Conversation,
        assistantNode: MessageNode,
        assistantNodeId: String,
        profile: Profile,
        preset: Preset,
        context: ModelContext,
        tools: [[String: Any]]?,
        toolTurns: [ToolTurn],
        round: Int,
        isBudgetSummary: Bool = false
    ) {
        providerRouter.usageContext = UsageContext(kind: .chat, conversationId: conversation.id, profileId: profile.id, messageNodeId: assistantNodeId)
        // 收口登记（10-29 返工 B1）：所有 API 回复都过这里，第一轮登记，工具轮 / 预算收尾沿用
        if reactionTurns[assistantNodeId] == nil {
            reactionTurns[assistantNodeId] = ReactionTurn(node: assistantNode, conversation: conversation, context: context)
        }
        let recallRequestId = prepareRecallAttempt(on: assistantNode, conversation: conversation, context: context)
        providerRouter.sendStreaming(
            model: model,
            messages: payload.messages,
            systemPrompt: systemPrompt,
            providerManager: providerManager,
            samplingParams: StreamingPreference.apply(payload.sampling),
            imageMap: payload.imageMap,
            additionalHeaders: payload.additionalHeaders,
            tools: tools,
            toolTurns: toolTurns,
            ordered: payload.ordered,
            onToken: { [weak self] token in
                guard let self else { return }
                streamingText += token
                if CallSession.activeSnapshot { callStreamHook?(.delta(token), assistantNodeId, conversation.id) }
                // Phase 5：切断 per-token node.content 写。
                // Phase 4 后 view 走 source.streamingText 不读 node.content，
                // onComplete (line 2105/2110) 写 fullText、cancel (line 1363-1374) 写 partial、
                // onError 写 partial（Phase 4 修过）。流式中 SwiftData 写次数从 250/turn 降到 1。
            },
            onComplete: { [weak self] streamedText, usage in
                guard let self else { return }
                // ⑤a 输入阶段：完整回复入库前跑一次普通规则（流式中不逐 token 改存储）
                var fullText = self.applyInputRegex(streamedText, role: "assistant", profile: profile, preset: preset)
                // thinking 回传 §3.6 / Q8：模型拒绝在正文里写内部推理 → 气泡尾巴说人话 + 诊断日志
                let refusal = MainActor.assumeIsolated { self.providerRouter.lastRefusalCategory }
                if let notice = ParamErrorClassifier.refusalNotice(category: refusal) {
                    fullText += (fullText.isEmpty ? "" : "\n\n") + ChatSystemMessage.errorLine(notice)
                    CacheDiagLog.shared.log("🧠 回复被拒 stop_details.category=\(refusal ?? "")（\(model.modelId)）")
                }
                let thinking = MainActor.assumeIsolated { self.providerRouter.lastThinkingSegments }
                let thinkingBase = assistantNode.segments.flatMap { $0.isEmpty ? nil : $0.count }
                if let existing = assistantNode.segments, !existing.isEmpty {
                    var segs = existing
                    if !fullText.isEmpty { segs.append(.text(fullText)) }
                    assistantNode.setSegments(segs)
                }
                assistantNode.content = fullText
                Self.attachThinking(thinking, to: assistantNode, base: thinkingBase)
                RequestBodyDiag.checkReply(ChatCardIndex.visibleText(content: fullText, segments: assistantNode.segments),
                                           segments: assistantNode.segments)
                // Anthropic server-side web search 收尾——把流式累积的 sources 落到 message
                // onComplete 总是在 main thread 调（DispatchQueue.main.async），但闭包没 @MainActor 标注
                let sources = MainActor.assumeIsolated { self.providerRouter.currentWebSources }
                if !sources.isEmpty { assistantNode.setWebSources(sources) }
                // 结局落库（plan-reply-error-report-1106 §1.3）：正常留 nil，提示文字绝不进 content
                let outcome = MainActor.assumeIsolated { self.providerRouter.lastReplyOutcome }
                assistantNode.replyOutcome = outcome.isAbnormal ? outcome.rawValue : nil
                assistantNode.finishReason = MainActor.assumeIsolated { self.providerRouter.lastFinishReason }
                if outcome == .truncatedLength {
                    BreadcrumbLog.shared.add("✂️", "已达输出上限 \(self.providerRouter.lastRequestedMaxTokens ?? 0)")
                }
                self.showParamAdaptationNotice()
                self.recordUsage(usage, on: assistantNode, model: model, providerManager: providerManager)   // 用量先挂上（节点可能马上被撤）
                // 10-29 返工 #6：先消费 react 块、做完静默回滚，再存最终状态、再起记忆提取 / 摘要这些旁路
                let silentRemoved = MainActor.assumeIsolated { self.settleReactionTurn(nodeId: assistantNodeId) }
                streamingText = ""
                conversation.nodeCount = currentPath.filter {
                    ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent
                }.count
                if !silentRemoved, conversation.title == ConversationTitler.placeholderTitle {
                    let firstUserMsg = currentPath.first(where: { $0.role == "user" && !$0.content.isEmpty })?.content ?? ""
                    if !firstUserMsg.isEmpty {
                        MainActor.assumeIsolated {
                            ConversationTitler.autoTitle(conversation, firstUser: firstUserMsg, firstAssistant: assistantNode.content,
                                                         providerManager: providerManager)
                        }
                        markConversationDirty()
                    }
                }
                try? context.save()
                // 回复写回发起时的节点；用户中途切了支就不滚过去（不把她拉回原分支，③b）
                if currentPath.contains(where: { $0.id == assistantNodeId }) { scrollToNodeId = assistantNodeId }
                BreadcrumbLog.shared.add("✅", "回复完成 in \(usage?.inputTokens ?? 0) / out \(usage?.outputTokens ?? 0) tok")
                self.commitBudgetSpend(providerManager: providerManager, model: model, usage: usage)
                if MemoryFlags.masterEnabled && conversation.memoryEnabled {
                    // v5 C2：只看称呼 + 这一截，不带主提示词；画像（做梦）v5 Q4 下线，不再自动写
                    self.extractMemoriesIfNeeded(profileId: profile.id, conversationId: conversation.id,
                                                 names: MemoryExtractor.Names(userName: profile.userName, assistantName: profile.assistantName),
                                                 model: model, providerManager: providerManager, context: context)
                }
                self.transcribeImagesIfNeeded(model: model, providerManager: providerManager, context: context)
                self.triggerContextSummaryIfNeeded(
                    conversation: conversation,
                    conversationId: conversation.id,
                    conversationTitle: conversation.title,
                    profile: profile,
                    contextDepth: preset.sampling.contextDepth,
                    model: model, providerManager: providerManager
                )
                SessionCloseoutTrigger.shared.request(activeConversationId: conversation.id)   // 第三刀：别的窗口静默够了就收尾；v5 A8「每 N 回合」看刚回完的这个
                self.finishAssistantTurn()   // onComplete 只在最终无工具轮触发（与 onToolCalls 互斥）
            },
            onError: { [weak self] error in
                guard let self else { return }
                self.finishRecallAttempt(recallRequestId, on: assistantNode, status: .failed, context: context)
                if let record = self.providerRouter.lastUsageRecord {
                    MainActor.assumeIsolated { UsageCostSettlement.shared.attach(record: record, node: assistantNode) }
                }
                self.showParamAdaptationNotice()
                BreadcrumbLog.shared.add("⚠️", "出错：\(error.prefix(120))")
                // Phase 4 流式重写 Contract 5：保 partial post-tool 文本（不丢已生成内容）
                // 跟 cancelAssistantTurn (line 1363-1380) 行为对齐
                let thinking = MainActor.assumeIsolated { self.providerRouter.lastThinkingSegments }
                let thinkingBase = assistantNode.segments.flatMap { $0.isEmpty ? nil : $0.count }
                // 10-29 返工 #8 / B2：先放 partial、按发起时的节点收口（剥 react 块、贴表情；报错不撤泡），再追加警告行，
                // 存下来的正文不会有块残留；不靠之后会被改掉的 active id
                let warning = ChatSystemMessage.errorLine("\(error)")
                if var segs = assistantNode.segments, !segs.isEmpty {
                    if !streamingText.isEmpty { segs.append(.text(streamingText)) }
                    assistantNode.setSegments(segs)
                    MainActor.assumeIsolated { _ = self.settleReactionTurn(nodeId: assistantNodeId, allowRollback: false) }
                    var settled = assistantNode.segments ?? []
                    settled.append(.text(warning))
                    assistantNode.setSegments(settled)
                } else if streamingText.isEmpty {
                    MainActor.assumeIsolated { _ = self.settleReactionTurn(nodeId: assistantNodeId, allowRollback: false) }
                    assistantNode.content = warning
                } else {
                    // 非 segmented 且有 partial → 保 partial 不覆盖
                    assistantNode.content = streamingText
                    MainActor.assumeIsolated { _ = self.settleReactionTurn(nodeId: assistantNodeId, allowRollback: false) }
                    assistantNode.content = assistantNode.content.isEmpty ? warning : assistantNode.content + "\n\n" + warning
                }
                Self.attachThinking(thinking, to: assistantNode, base: thinkingBase)
                streamingText = ""
                self.finishAssistantTurn()
            },
            onToolCalls: { [weak self] calls, usage in
                guard let self else { return }
                self.showParamAdaptationNotice()
                // thinking 回传：这一次回复的原样块（存段 + 下一次请求原样回传），趁下一次请求开始前读
                let replyBlocks = MainActor.assumeIsolated { self.providerRouter.lastAssistantBlocks }
                let reasoning = MainActor.assumeIsolated { self.providerRouter.lastReasoning }
                // astra #1：这一次是「思考块被拒、去块重发」成功的 → 前面几轮之后也一直不带思考块（别把被拒的块再带回来）
                let turnsSoFar = MainActor.assumeIsolated { self.providerRouter.lastRequestDroppedThinking }
                    ? toolTurns.map { $0.droppingThinking() } : toolTurns
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.recordUsage(usage, on: assistantNode, model: model, providerManager: providerManager)
                    self.commitBudgetSpend(providerManager: providerManager, model: model, usage: usage, recordTurn: false)
                    let gen = self.turnGeneration   // stop / 切楼层会 +1；每个 await 回来都对照
                    #if DEBUG
                    print("[Tools] round=\(round) 模型调用: \(calls.map { "\($0.name)(\($0.argumentsJSON.prefix(80)))" })")
                    #endif
                    // 工具调用前模型可能先说了话 → 存为 text segment
                    // 进度卡：每记一段工具调用 / 结果就喂给 turnActivities（所有分支都经 segs，不用逐个改）
                    let activityConvId = conversation.id
                    var segs: [MessageSegment] = assistantNode.segments ?? [] {
                        didSet { if let last = segs.last { self.noteTurnSegment(last, conversationId: activityConvId) } }
                    }
                    if CallSession.activeSnapshot { self.callStreamHook?(.segmentBreak, assistantNodeId, conversation.id) }
                    for seg in Self.replySegments(replyBlocks, text: streamingText, reasoning: reasoning) { segs.append(seg) }
                    streamingText = ""
                    if isBudgetSummary {
                        segs.append(.text("（预算收尾请求仍返回了工具调用，已结束。）"))
                        assistantNode.setSegments(segs)
                        assistantNode.contentType = "segmented"
                        try? context.save()
                        self.finishAssistantTurn()
                        return
                    }
                    self.toolTruncationStreak = calls.contains(where: \.truncated) ? self.toolTruncationStreak + 1 : 0
                    guard self.toolTruncationStreak < 2 else {
                        segs.append(.text(Self.toolTruncationStopText))
                        assistantNode.setSegments(segs)
                        assistantNode.contentType = "segmented"
                        if assistantNode.content.isEmpty { assistantNode.content = Self.toolTruncationStopText }
                        try? context.save()
                        self.finishAssistantTurn()
                        return
                    }
                    let usesBrowser = self.browserOperateCallsThisTurn > 0 || calls.contains { BrowserOperateTools.names.contains($0.name) }
                    let roundCap = usesBrowser ? Self.browserToolRounds : Self.maxToolRounds
                    guard round < roundCap else {
                        segs.append(.text("（工具调用达到上限 \(roundCap) 轮，已停止）"))
                        assistantNode.setSegments(segs)
                        assistantNode.contentType = "segmented"
                        if assistantNode.content.isEmpty {
                            assistantNode.content = "（工具调用达到上限 \(roundCap) 轮，已停止）"
                        }
                        try? context.save()
                        self.finishAssistantTurn()
                        return
                    }
                    // 第一轮从新开始（防上一个 turn 没走收口留下的旧记录）；之后几轮接着记
                    var activity = (round == 0 ? nil : self.turnActivities[conversation.id]) ?? TurnActivity(maxRounds: roundCap)
                    activity.maxRounds = roundCap
                    activity.startRound(round + 1, thinking: self.providerRouter.lastThinkingSegments.nativeThinkingText)
                    self.turnActivities[conversation.id] = activity
                    let profileId = conversation.profileId
                    let mcpServerIds = MCPProvider.shared.activeServerIds
                    var results: [ToolResultBlock] = []
                    var askItems: [PendingUserQuestion.AskItem] = []
                    /// 审批卡上改过命令的调用（id → 改过的参数）：下一轮给模型的记录换成改过的，并在结果里说一声
                    var editedArgs: [String: String] = [:]
                    /// 拆回真名执行的 tool_invoke（id → 内层工具名）
                    var invokeWrapped: [String: String] = [:]
                    var fileLibraryDidChange = false
                    let gate = self.toolGate(for: model, providerManager: providerManager, profileId: profileId, conversation: conversation, userName: profile.userName)
                    // 拆包按这一轮实际发出去的 tools 数组算（astra #3：循环中途把收起改成直接给，模型手上还是第一轮那份清单）
                    let invokable = Self.invokableBuiltins(sentTools: tools)

                    for call in calls {
                        var call = call   // 审批卡上改过命令时换参数
                        guard gen == self.turnGeneration else { self.dropReactionTurn(assistantNodeId); return }   // 用户已停止/切楼层：剩下的调用不跑
                        // 输出上限截断（plan-output-token-cap 2-7）：参数写到一半，不执行；说清原因让模型拆小，别原样重发
                        if call.truncated {
                            let msg = Self.toolTruncatedMessage(name: call.name, cap: self.providerRouter.lastRequestedMaxTokens ?? OutputTokenCap.resolved(payload.sampling, modelId: model.modelId).maxTokens)
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "输出上限", iconName: "scissors"))
                            segs.append(.toolResult(toolUseId: call.id, text: msg, isError: true, integrationName: "输出上限"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: msg, isError: true))
                            continue
                        }
                        // #069 包着「更多工具」里内建工具的 tool_invoke：拆回真名，后面的预检 / 复查 / 权限 / 执行 / 卡片 / 存档都按真工具走；
                        // 回给模型的调用记录仍是原样的 tool_invoke（invokeWrapped 记内层名字，授权卡改过参数时重新包回）
                        switch Self.unwrapTuckedInvoke(call, tucked: invokable) {
                        case .notWrapped:
                            break
                        case .invalid(let msg):
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "参数错误", iconName: "exclamationmark.triangle"))
                            segs.append(.toolResult(toolUseId: call.id, text: msg, isError: true, integrationName: "参数错误"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: msg, isError: true))
                            continue
                        case .unwrapped(let inner):
                            invokeWrapped[call.id] = inner.name
                            call = inner
                        }
                        // 参数预检（《minis对比》A1 / 洞 1）：required 缺失或 JSON 不合法一律不执行，
                        // 回灌 isError 让模型重发——fs_write 缺 content 会清空已有文件，那类事故止于此。
                        // 放在权限闸**之前**：坏调用不该先弹一张没有命令预览的授权卡（kimi 评审打穿 10）。
                        if call.name != RecallTool.toolName, let bad = ToolCallPreflight.check(
                            name: call.name, argumentsJSON: call.argumentsJSON,
                            required: ToolCallPreflight.requiredFields(for: call.name, mcpServerIds: mcpServerIds)
                        ) {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "参数错误", iconName: "exclamationmark.triangle"))
                            segs.append(.toolResult(toolUseId: call.id, text: bad.message, isError: true, integrationName: "参数错误"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: bad.message, isError: true))
                            continue
                        }
                        // 执行前复查（#069）：这一轮没下发的内建工具（开关关着），照着历史直接叫也不执行。
                        // #093 astra #1：每个调用现读抽屉 / 开关（同一批前面的调用可能 await 很久），审批卡回来后再查一次
                        if self.toolUnavailableNow(call.name, model: model, providerManager: providerManager, profileId: profileId, conversation: conversation) {
                            let msg = Self.toolUnavailableMessage(
                                name: call.name,
                                memoryParticipationOff: !EffectiveMemoryParticipation.resolve(profileId: profileId, conversation: conversation, preset: nil).writeTools)
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "未开启", iconName: "nosign"))
                            segs.append(.toolResult(toolUseId: call.id, text: msg, isError: true, integrationName: "未开启"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: msg, isError: true))
                            continue
                        }
                        self.turnActivities[conversation.id]?.startTool(call)
                        defer {
                            if gen == self.turnGeneration, self.isNodeStreaming(nodeId: assistantNodeId, conversationId: conversation.id) {
                                self.turnActivities[conversation.id]?.finishTool(call.id)
                            }
                        }
                        // 权限闸（plan-权限管理 §2 工具路径）：notAllowed 拒 / askOnce 未答弹卡
                        switch await toolPermissionGate(toolName: call.name, argumentsJSON: call.argumentsJSON, conversation: conversation, context: context) {
                        case .deny(let denial):
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "权限", iconName: "lock"))
                            segs.append(.toolResult(toolUseId: call.id, text: denial, isError: true, integrationName: "权限"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: denial, isError: true))
                            continue
                        case .proceed(let args):
                            if args != call.argumentsJSON { editedArgs[call.id] = args }
                            call.argumentsJSON = args   // 卡上改过命令：照改过的执行，模型从工具记录里看得到
                        }
                        guard gen == self.turnGeneration else { self.dropReactionTurn(assistantNodeId); return }   // 等审批时被停止 / 切楼层
                        if self.toolUnavailableNow(call.name, model: model, providerManager: providerManager, profileId: profileId, conversation: conversation) {
                            let msg = Self.toolUnavailableMessage(
                                name: call.name,
                                memoryParticipationOff: !EffectiveMemoryParticipation.resolve(profileId: profileId, conversation: conversation, preset: nil).writeTools)
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "未开启", iconName: "nosign"))
                            segs.append(.toolResult(toolUseId: call.id, text: msg, isError: true, integrationName: "未开启"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: msg, isError: true))
                            continue
                        }
                        // 中转塞进参数的未声明顶层键（R8）只在执行时去掉；存进历史 / 回给模型的调用记录照原样
                        let replayArgs = call.argumentsJSON
                        if self.turnActivities[conversation.id]?.pendingTool?.inputJSON != replayArgs {
                            self.turnActivities[conversation.id]?.startTool(call)
                        }
                        if call.name != RecallTool.toolName {
                            call.argumentsJSON = ToolCallPreflight.droppingUndeclared(
                                call.argumentsJSON, schema: ToolCallPreflight.schema(for: call.name, mcpServerIds: mcpServerIds))
                        }
                        if call.name == TurnStatusTool.toolName {
                            let status = TurnStatusTool.text(from: call.argumentsJSON)
                            let accepted = status.map {
                                self.acceptTurnStatus($0, conversationId: conversation.id, nodeId: assistantNodeId, generation: gen)
                            } ?? false
                            let text = status == nil ? "status需要非空文字，最多20字。" : (accepted ? "本轮状态已更新。" : "本轮状态已失效，未更新。")
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "本轮状态", iconName: "text.bubble"))
                            segs.append(.toolResult(toolUseId: call.id, text: text, isError: !accepted, integrationName: "本轮状态"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: text, isError: !accepted))
                            continue
                        }
                        #if os(macOS)
                        // 编程会话 AI 工具（W-N N5）：精确四名（不按前缀）；只读，后台新开只读连接执行
                        if CodingTools.names.contains(call.name) {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "编程会话", iconName: "terminal"))
                            let r = await CodingSessionLibrary.shared.runCodingTool(name: call.name, argumentsJSON: call.argumentsJSON)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "编程会话"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                            continue
                        }
                        #endif
                        #if PERSONAL_APPS
                        if call.name == DeathScaleAITool.toolName {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "Mort sans sépulture", iconName: "scalemass"))
                            let r = DeathScaleAITool.execute(inputJSON: Self.executionArgs(call), profileId: profileId)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "Mort sans sépulture"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                            continue
                        }
                        #endif
                        if MetaTools.names.contains(call.name) {
                            let m = await handleMetaTool(call, mcpServerIds: mcpServerIds, conversationId: conversation.id,
                                                         builtins: gate.map { ToolRegistry.tuckedDefinitions($0) } ?? [])
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: m.integrationName, iconName: "magnifyingglass"))
                            #if DEBUG
                            print("[Meta] \(call.name) → isError=\(m.isError): \(m.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: m.text, isError: m.isError, integrationName: m.integrationName))
                            results.append(ToolResultBlock(toolUseId: call.id, text: m.text, isError: m.isError))
                        } else if call.name.hasPrefix("fs_") {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: nil, iconName: nil))
                            // 修全局卡顿：fs_list / fs_search 要枚举整库（search 还要读每个文件），挪到后台跑；写类工具照旧
                            let r: FileLibraryTools.Result
                            if ["fs_list", "fs_search"].contains(call.name) {
                                let name = call.name, json = call.argumentsJSON, pid = profileId, userName = profile.userName
                                r = await Task.detached(priority: .userInitiated) {
                                    FileLibraryTools.execute(name: name, inputJSON: json, profileId: pid, userName: userName)
                                }.value
                            } else {
                                r = MainThreadIO.tolerated("#033 AI 文件工具主线程执行") {
                                    FileLibraryTools.execute(name: call.name, inputJSON: Self.executionArgs(call), profileId: profileId, userName: profile.userName)
                                }
                            }
                            if ["fs_write", "fs_append", "fs_edit", "fs_rename", "fs_delete"].contains(call.name) {
                                fileLibraryDidChange = true
                            }
                            #if DEBUG
                            print("[FileLib] \(call.name) → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: nil))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == DiceTool.toolName {
                            // 模型自己掷骰子（粟粟 09-26）：真随机；本回合已发的 id 一并避开
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "骰子", iconName: "dice"))
                            var rng = SystemRandomNumberGenerator()
                            let r = DiceTool.execute(inputJSON: Self.executionArgs(call), using: &rng,
                                                     takenIds: Set(cardIndex.keys).union(diceToolIssuedIds))
                            if !r.isError, let id = ChatCardExtractor.cards(in: r.text).first?.id {
                                diceToolIssuedIds.insert(id)
                            }
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "骰子"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == CardGuideTool.toolName {
                            // 卡片写法用到再查（粟粟 10-03）：系统提示里只有目录
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "卡片说明", iconName: "rectangle.stack"))
                            let r = CardGuideTool.execute(inputJSON: Self.executionArgs(call),
                                                          available: gate.map { Set(ToolRegistry.enabledDefinitions($0).map(\.name)) })
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "卡片说明"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == ProfileCardTool.toolName {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "资料卡", iconName: "person.crop.circle"))
                            let r = ProfileCardTool.execute(inputJSON: Self.executionArgs(call), profileId: profileId)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "资料卡"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == TwitterAITool.toolName {
                            // 本地推特：AI 的主号名字头像跟楼层 AI 资料同步（头像同其它地方：assistantAvatar ?? cover）
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "推特", iconName: "bird"))
                            let r = TwitterAITool.execute(inputJSON: Self.executionArgs(call), profileId: profileId,
                                                          aiName: profile.assistantName,
                                                          aiAvatar: profile.assistantAvatarData ?? profile.coverImageData,
                                                          context: context)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "推特"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == InnerVoice.toolName {
                            // v2c 心声：当轮立即回执让对话继续；第二跳后台生成+落盘
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "心声", iconName: "heart"))
                            let resultText: String
                            if !InnerVoice.enabled {
                                resultText = "（心声功能未开启）"
                            } else if InnerVoice.onCooldown(convId: conversation.id, messageCount: payload.messages.count) {
                                resultText = "（你刚静过心，等情绪再沉一会儿）"
                            } else {
                                InnerVoice.markVoiced(convId: conversation.id, messageCount: payload.messages.count)
                                let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
                                let reason = args["reason"] as? String ?? ""
                                let msgs = payload.messages
                                let sys = systemPrompt
                                let convId = conversation.id
                                Task.detached { [weak self] in
                                    let text = await InnerVoice.generate(
                                        messages: msgs, systemPrompt: sys, reason: reason,
                                        convId: convId, profileId: profileId,
                                        model: model, providerManager: providerManager
                                    )
                                    await MainActor.run {
                                        guard let self, let text else { return }
                                        self.transientNotice = TransientNotice("💭 它写下了一段心声")
                                        if InnerVoice.showInChat {
                                            self.appendHeartvoiceMessage(text: text, conversation: conversation, context: context)
                                        }
                                    }
                                }
                                resultText = "（你记下了此刻的心声）"
                            }
                            segs.append(.toolResult(toolUseId: call.id, text: resultText, isError: false, integrationName: "心声"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: resultText, isError: false))
                        } else if SelfMemoryTool.names.contains(call.name) {
                            // 第二刀 B2：写自己的记忆（memory/self/）；这场对话关了「记忆参与」就不写
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "记忆", iconName: "bookmark"))
                            let r = conversation.memoryEnabled
                                ? SelfMemoryTool.execute(name: call.name, inputJSON: Self.executionArgs(call), profileId: profileId, conversationId: conversation.id)
                                : SelfMemoryTool.Result(text: "这场对话关了记忆参与，不能写记忆", isError: true)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "记忆"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == PendingNotesTool.toolName {
                            // v5 §3-2：标待续（读写 memory/pending/，放后台）；这场对话关了「记忆参与」就不动
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "待续", iconName: "pin"))
                            let input = call.argumentsJSON, convId = conversation.id, memoryEnabled = conversation.memoryEnabled
                            let r = await Task.detached {
                                PendingNotesTool.execute(inputJSON: input, profileId: profileId, conversationId: convId, memoryEnabled: memoryEnabled)
                            }.value
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "待续"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == WikiSuggestTool.toolName {
                            // C2/C3 v2 第 4 段：提整理方向，只进待批（批了才查、写）；这场对话关了「记忆参与」就不提
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "整理方向", iconName: "books.vertical"))
                            let input = Self.executionArgs(call), userName = profile.userName
                            let r = conversation.memoryEnabled
                                ? await Task.detached { WikiSuggestTool.execute(inputJSON: input, wiki: WikiStore(profileId: profileId), profileId: profileId, userName: userName) }.value
                                : WikiSuggestTool.Result(text: "这场对话关了记忆参与，不能提整理方向", isError: true)
                            if !r.isError { NotificationCenter.default.post(name: .memoryDidChange, object: nil) }
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "整理方向"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == RecallTool.toolName {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "回忆", iconName: "clock.arrow.circlepath"))
                            // 连环 recall 熔断（粟粟实测：宽查询翻页式 5+ 连调爆上下文）
                            recallCallsThisTurn += 1
                            let maximumCalls = assistantNode.recallReceipt?.decision.tuning.maximumRecallCalls
                                ?? RecallTuning.defaults.maximumRecallCalls
                            guard recallCallsThisTurn <= maximumCalls else {
                                let layer = lastRecallLayer
                                let msg = "在 \(layer) 层 · 本次 0 条 · 下一步 下一轮继续\n本轮 recall 已到 \(maximumCalls) 次，目前读到 \(layer)，余下可下一轮继续"
                                segs.append(.toolResult(toolUseId: call.id, text: msg, isError: true, integrationName: "回忆"))
                                results.append(ToolResultBlock(toolUseId: call.id, text: msg, isError: true))
                                if var receipt = assistantNode.recallReceipt {
                                    receipt.reads.append(RecallReadReceipt(
                                        toolCallId: call.id, turnId: receipt.decision.turnId, layer: layer,
                                        target: call.argumentsJSON, sourceVersion: nil, status: "limited",
                                        returnedRange: [], next: .init(hasMore: false, cursorIssued: false),
                                        returnedCount: 0))
                                    storeRecallReceipt(receipt, on: assistantNode, conversation: conversation, context: context)
                                } else {
                                    CacheDiagLog.shared.log("recall 读回执缺失：call=\(call.id) status=limited")
                                }
                                continue
                            }
                            let r = await RecallTool.execute(
                                inputJSON: Self.executionArgs(call),
                                profileId: profileId,
                                currentConversationId: conversation.id,
                                userName: profile.userName.isEmpty ? "用户" : profile.userName,
                                assistantName: profile.assistantName.isEmpty ? "AI" : profile.assistantName,
                                source: SwiftDataConversationSource(container: context.container),
                                memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId),
                                tuning: assistantNode.recallReceipt?.decision.tuning,
                                memoryParticipation: EffectiveMemoryParticipation.resolve(
                                    profileId: profileId, conversation: conversation, preset: nil
                                ).participates,
                                environment: RecallTool.l1Environment(container: context.container)
                            )
                            if let read = r.read { lastRecallLayer = read.layer }
                            if let read = r.read, var receipt = assistantNode.recallReceipt {
                                receipt.reads.append(RecallReadReceipt(
                                    toolCallId: call.id, turnId: receipt.decision.turnId, layer: read.layer, target: read.target,
                                    sourceVersion: read.sourceVersion, status: read.status,
                                    returnedRange: read.returnedRange, next: read.next,
                                    returnedCount: read.returnedCount, gate: read.gate))
                                storeRecallReceipt(receipt, on: assistantNode, conversation: conversation, context: context)
                            } else if assistantNode.recallReceipt == nil {
                                CacheDiagLog.shared.log("recall 读回执缺失：call=\(call.id)")
                            }
                            // 刀3 语义：recall 真命中的记忆才强化（注入候选池不再 +1）
                            if !r.hitMemoryIds.isEmpty { try? self.memoryStore.recordAccess(ids: r.hitMemoryIds, context: context) }
                            #if DEBUG
                            print("[Recall] → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "回忆"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == WebSearchToolService.toolName {
                            // client-side 联网搜索：当前选中的 backend 跑一遍 + 给 items 加 id/index 后回灌
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "联网搜索", iconName: "globe"))
                            let r = await WebSearchToolService.execute(inputJSON: Self.executionArgs(call))
                            #if DEBUG
                            print("[WebSearch] → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "联网搜索"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == AskUserTool.toolName {
                            // 问问题：不立即执行——循环收尾存 pending 暂停，等用户点选（resumeUserQuestion 恢复）
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "问问题", iconName: "questionmark.circle"))
                            if let questions = AskUserTool.parse(inputJSON: Self.executionArgs(call)) {
                                askItems.append(.init(call: call, questions: questions))
                            } else {
                                segs.append(.toolResult(toolUseId: call.id, text: AskUserTool.invalidArgsMessage, isError: true, integrationName: "问问题"))
                                results.append(ToolResultBlock(toolUseId: call.id, text: AskUserTool.invalidArgsMessage, isError: true))
                            }
                        } else if call.name == BrowseURLTool.toolName {
                            // 内置浏览器读 URL → Markdown 全文（v2 Phase 1）
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "网页阅读", iconName: "doc.text.magnifyingglass"))
                            let r = await BrowseURLTool.execute(inputJSON: Self.executionArgs(call))
                            #if DEBUG
                            print("[BrowseURL] → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "网页阅读"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if ChromeBridgeTools.names.contains(call.name) {
                            // 借 Mac 上 Chrome 登录态（plan-opencli-in-app）：hub 执行，每轮合计 6 次
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "Chrome", iconName: "globe"))
                            chromeBridgeCallsThisTurn += 1
                            let r = chromeBridgeCallsThisTurn <= ChromeBridgeTools.perTurnLimit
                                ? await ChromeBridgeTools.execute(name: call.name, inputJSON: Self.executionArgs(call))
                                : (text: ChromeBridgeTools.perTurnLimitMessage, isError: true)
                            #if DEBUG
                            print("[ChromeBridge] \(call.name) → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "Chrome"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if BrowserOperateTools.names.contains(call.name) {
                            // AI 在花园浏览器里动手（plan-ai-browser-operate）：权限闸已在循环头判过；写动作在浏览器里弹卡；每轮合计 30 次
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "浏览器", iconName: "cursorarrow.rays"))
                            browserOperateCallsThisTurn += 1
                            let r = browserOperateCallsThisTurn <= BrowserOperateTools.perTurnLimit
                                ? await BrowserOperateTools.execute(name: call.name, inputJSON: Self.executionArgs(call), conversationId: conversation.id)
                                : (text: BrowserOperateTools.perTurnLimitMessage, isError: true)
                            #if DEBUG
                            print("[BrowserOperate] \(call.name) → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "浏览器"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if DeviceToolDispatcher.handles(call.name) {
                            // 设备工具（plan-设备工具）：权限闸已在循环头判过；dispatcher 自带 required 预检
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: "设备", iconName: "iphone"))
                            let r: (text: String, isError: Bool)
                            if call.name == RunCommandTool.toolName {
                                // 加密值只换 run_command；「运行」面板登记占位版命令
                                r = await runWithSecrets(toolName: call.name, argumentsJSON: call.argumentsJSON, conversationId: conversation.id) { json in
                                    let shown = json == call.argumentsJSON ? nil : DeviceToolIO.str(DeviceToolIO.args(call.argumentsJSON), "command")
                                    let e = await DeviceToolDispatcher.execute(name: call.name, inputJSON: json, profileId: profileId, conversationId: conversation.id, monitorCommand: shown)
                                    return (e.text, e.isError)
                                }
                            } else {
                                let e = await DeviceToolDispatcher.execute(name: call.name, inputJSON: Self.executionArgs(call), profileId: profileId, conversationId: conversation.id)
                                r = (e.text, e.isError)
                            }
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "设备"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else {
                            var serverName: String?
                            let r = await runWithSecrets(toolName: call.name, argumentsJSON: call.argumentsJSON, conversationId: conversation.id) { json in
                                let m = await MCPProvider.shared.callToolText(serverIds: mcpServerIds, toolName: call.name, argumentsJSON: json)
                                serverName = m.serverName
                                return (m.text, m.isError)
                            }
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: replayArgs, integrationName: serverName ?? "MCP", iconName: "network"))
                            #if DEBUG
                            print("[MCP] \(call.name) → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: serverName ?? "MCP"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        }
                    }
                    // B4 工具结果外置（plan-B4 D5/D7）：超 2000 行 / 50KB 的结果全文落 tool-results/，
                    // 回灌只带头部 + 续读指引，气泡 seg 与回灌同文本。fs_read 自己按同一上限头截并指回原文件，跳过（D4）。
                    for i in results.indices {
                        guard let call = calls.first(where: { $0.id == results[i].toolUseId }) else { continue }
                        let execName = invokeWrapped[call.id] ?? call.name   // 包着调的按真工具判豁免、命名存档
                        guard execName != FileLibraryTools.Name.read.rawValue, !Self.skipsOffload(execName) else { continue }
                        let o = MainThreadIO.tolerated("#033 超长工具结果主线程落盘") {
                            ToolResultOffload.apply(text: results[i].text, conversationId: conversation.id, toolUseId: call.id, toolName: execName, profileId: profileId)
                        }
                        guard o.offloaded else {
                            // #089 P0-b：以后回放这一轮只留开头 2KB，超出的现在存一份原文（后台写），回放时指过去；当轮照旧完整
                            if results[i].text.utf8.count > ToolReplay.historyResultCapBytes {
                                let text = results[i].text, convId = conversation.id, useId = call.id
                                Task.detached(priority: .utility) {
                                    _ = try? FileLibraryStore.toolResultWrite(conversationId: convId, toolUseId: useId, toolName: execName,
                                                                              content: text, profileId: profileId)
                                }
                            }
                            continue
                        }
                        results[i] = ToolResultBlock(toolUseId: call.id, text: o.text, isError: results[i].isError)
                        self.turnActivities[conversation.id]?.replaceOffloadedResult(toolUseId: call.id, text: o.text)
                        if let si = segs.lastIndex(where: { if case .toolResult(let id, _, _, _) = $0 { return id == call.id }; return false }),
                           case .toolResult(_, _, let isErr, let integ) = segs[si] {
                            segs[si] = .toolResult(toolUseId: call.id, text: o.text, isError: isErr, integrationName: integ)
                        }
                    }
                    // 工具都跑完了，但 turn 已被 stop / 切楼层作废：不存结果、不递归再请求模型
                    // （cancelAssistantTurn 已给节点追加「（已停止）」并 finish）
                    guard gen == self.turnGeneration else { self.dropReactionTurn(assistantNodeId); return }
                    assistantNode.setSegments(segs)
                    assistantNode.contentType = "segmented"
                    try? context.save()
                    if fileLibraryDidChange {
                        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
                    }
                    // 审批卡改过命令：给模型的调用记录用改过的参数，结果开头说明是对方改的
                    let sentCalls = calls.map { c -> ToolCallBlock in
                        var c = c
                        if let args = editedArgs[c.id] {
                            c.argumentsJSON = invokeWrapped[c.id].map { Self.rewrapInvoke(name: $0, argumentsJSON: args) } ?? args
                        }
                        return c
                    }
                    results = results.map { r in
                        editedArgs[r.toolUseId] == nil ? r
                            : ToolResultBlock(toolUseId: r.toolUseId, text: "（对方在执行前把这次调用的命令改成了上面这条）\n" + r.text, isError: r.isError)
                    }

                    // 问问题暂停：不递归，存 pending 等用户点选。其余工具的 results 一并打包，
                    // resumeUserQuestion 拼上 Q/A 后按 use→result 严格配对恢复循环。
                    if !askItems.isEmpty {
                        self.pendingUserQuestion = PendingUserQuestion(
                            conversationId: conversation.id,
                            askItems: askItems,
                            collectedAnswers: Array(repeating: nil, count: askItems.reduce(0) { $0 + $1.questions.count }),
                            payload: payload, systemPrompt: systemPrompt, model: model, providerManager: providerManager,
                            conversation: conversation, assistantNode: assistantNode, assistantNodeId: assistantNodeId,
                            profile: profile, preset: preset, context: context,
                            tools: tools, toolTurns: turnsSoFar, round: round,
                            calls: sentCalls, otherResults: results, assistantContent: replyBlocks.wireContent,
                            thinkingTokens: usage?.reasoningTokens, reasoning: reasoning
                        )
                        return
                    }

                    self.continueToolLoop(
                        payload: payload, systemPrompt: systemPrompt,
                        model: model, providerManager: providerManager,
                        conversation: conversation, assistantNode: assistantNode, assistantNodeId: assistantNodeId,
                        profile: profile, preset: preset, context: context,
                        tools: tools,
                        toolTurns: turnsSoFar + [ToolTurn(calls: sentCalls, results: results, assistantContent: replyBlocks.wireContent,
                                                         thinkingTokens: usage?.reasoningTokens, reasoning: reasoning)],
                        round: round + 1
                    )
                }
            },
            onRetry: { [weak self] notice in
                self?.transientNotice = TransientNotice(notice)
            },
            onStallNotice: { [weak self] notice in
                // 只在这一轮还在生成、还是同一条回复时出提示（切楼层 / 停止后不再打扰）
                guard let self, self.assistantTurnInFlight, self.activeAssistantNodeId == assistantNodeId else { return }
                self.transientNotice = TransientNotice(notice)
            },
            onEffectiveEvent: { [weak self] in
                self?.respondRecallAttempt(recallRequestId, conversation: conversation, assistant: assistantNode, context: context)
            },
            onRequestAttempt: { [weak self] in
                self?.submitRecallAttempt(recallRequestId, on: assistantNode, context: context)
            }
        )
    }

    /// CC 收口即发（plan-跨对话排队）：WS 直发一帧 send，不注册 reply handler、不建占位、不占 turn。
    /// 回复由 hub 推回 → 无 handler 自动走 proactive 路径落地（查重/未读/上树/滚动全复用）。
    /// payload 来自 prepareRouterPayload 原路（style 后缀/附件砍文/引用头与旧流式路径完全一致）。
    @MainActor
    private func sendCCFireAndForget(
        payload: (messages: [(role: String, content: String)], systemPrompt: String?, sampling: SamplingParams, additionalHeaders: [String: String], imageMap: [String: [PendingChatAttachment]], ordered: [PromptMessage]),
        model: ProviderModel,
        conversation: Conversation,
        profile: Profile,
        providerManager: ProviderManager
    ) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        // R4 C-05：CC 发送不经 Router，严格测量角色在读钥匙串 / 连 WS 之前记外发并停轮（§3.1）
        if PerfHarness.strictMeasure { PerfGuardrails.tripOutbound("cc.send", model.credentialId); return }
        #endif
        // 按对话取那台的连接（B3.1）；拿不到就不发，不回落主 hub
        guard let ws = ccClientOrNotice(for: conversation) else { return }
        // 冷启动兜底：ContentView 启动时已 connect，这里补一手（沿旧 CCBridgeProvider 语义）。
        // 已经有候选地址（内嵌 hub 的端口 / 扫码的 LAN+Tailscale）就只催它现在重连：provider.baseURL 默认还是 7890，
        // 拿它覆盖会把断线中的 App 连去错的 hub（astra 实现审 #4）。从没连过才走 provider 地址。
        if !ws.isConnected {
            if ws.hasCandidates {
                // 正在握手的那次别掐：掐了重来只会更晚连上（旧 connect 同目标时也是不动在途连接）
                if !ws.isConnecting { ws.reconnectNow() }
            } else if ws === ccBridgeClient, let provider = providerManager.provider(for: model), let url = URL(string: provider.baseURL) {
                // 卡片的地址只属于主 hub（B2「口令不串」2）：附加 hub 一律只用 Registry 给的配对。
                // 口令只认主 hub 本机副本（impl1 #1），不读可能被 iCloud 改过的 cc-bridge
                let key = hubRegistry.pairedPrimaryToken ?? ""
                ws.connect(url: url, token: key.isEmpty ? nil : key, keepExistingToken: true)
            }
        }
        // 楼层语音设置先同步进 cc-rp CLAUDE.md 标记块（同一条 WS、排在 send 帧前；内容没变不发）
        ws.syncVoiceInstructions(VoicePromptInjector.ccInstructionsBlock(profile: profile))
        let content = payload.messages.last(where: { $0.role == "user" })?.content ?? ""
        let headers = payload.additionalHeaders
        ws.sendUserMessage(
            chatId: headers["X-MP-ChatId"] ?? conversation.id,
            messageId: headers["X-MP-MessageId"] ?? UUID().uuidString,
            content: content,
            user: headers["X-MP-User"] ?? "user",
            session: headers["X-MP-CCSession"],
            replyTo: headers["X-MP-ReplyTo"],
            attachments: payload.imageMap[content] ?? [],
            effort: payload.sampling.reasoningEffort       // 已换成这个模型的档位（prepareRouterPayload）
        )
        markCCWaiting(conversation: conversation, ws: ws, providerManager: providerManager)
    }

    /// 等待泡（纯 UI 不阻塞）：回复落地 / 阶段收口时清；10 分钟没等到就静默收掉（对齐旧 grace 时长，
    /// 不弹错误——hub replay 会把迟到的回复兜回来）
    @MainActor
    private func markCCWaiting(conversation: Conversation, ws: CCBridgeWebSocketClient, providerManager: ProviderManager) {
        ccTitleProviderManager = providerManager
        let convId = conversation.id
        let stamp = Date()
        ccWaitingSince[convId] = stamp
        ccWaitingHub[convId] = ws.hubId
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            guard let self, self.ccWaitingSince[convId] == stamp else { return }
            self.ccWaitingSince.removeValue(forKey: convId)
        }
    }

    /// L3：cc-bridge 斜杠命令路径 — text 是 / 开头时调用，不走 LLM 流式，
    /// hub raw send-keys 给 CC 触发命令系统。fire-and-forget：
    /// CC 内建命令大多不调 reply tool（响应在 tmux 里渲染），MP 只创建 user node
    /// 留痕，不创建 assistant 占位（避免 60s 干等）。
    private func sendCCSlashCommand(_ text: String, conversation: Conversation, context: ModelContext) {
        guard let client = MainActor.assumeIsolated({ ccClientOrNotice(for: conversation) }) else { return }
        let parentId = currentPath.last?.id ?? invisibleRootId()   // 同 sendMessage：第一条挂隐形根
        let userNodeId = UUID().uuidString
        let userNode = MessageNode(
            id: userNodeId,
            role: "user",
            content: text,
            contentType: "text",
            createTime: Date(),
            parentId: parentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        context.insert(userNode)

        if let parentId, let parent = nodeMap[parentId] {
            if !parent.childrenIds.contains(userNodeId) {
                parent.childrenIds.append(userNodeId)
            }
        }
        nodeMap[userNodeId] = userNode
        effectiveChildrenMap[userNodeId] = []
        if let parentId {
            effectiveChildrenMap[parentId, default: []].append(userNodeId)
        }
        currentPath.append(userNode)
        markPop(userNodeId)
        commitSelection(to: userNodeId, conversation: conversation)
        conversation.updateTime = Date()
        markConversationDirty()
        try? context.save()
        scrollToNodeId = userNodeId

        // hub raw 直发；session_name 跟随当前对话绑定（nil → hub fallback 默认 mp-cc）
        let sessionName = conversation.ccBridgeSessionName
        client.sendCommand(text, session: sessionName) { result in
            switch result {
            case .success:
                #if DEBUG
                print("[CC slash] sent: \(text) → session=\(sessionName ?? "mp-cc")")
                #endif
            case .failure(let err):
                #if DEBUG
                print("[CC slash] err: \(err.reason)")
                #endif
                // 失败提示：在 user node 后面追加一个 system role 节点（不污染对话流，
                // 渲染时可以特殊样式 — v1 暂时跟普通节点同显示，至少有错误线索）
                let sysNodeId = UUID().uuidString
                let sysNode = MessageNode(
                    id: sysNodeId,
                    role: "system",
                    content: "⚠️ 命令发送失败：\(err.reason)",   // system 节点不走 split、AI 写不出来，留老前缀给 CardFlowView 认红色
                    contentType: "text",
                    createTime: Date(),
                    parentId: userNodeId,
                    childrenIds: [],
                    conversationId: conversation.id,
                    profileId: conversation.profileId
                )
                context.insert(sysNode)
                userNode.childrenIds.append(sysNodeId)
                // 失败回执绑在发起的那条命令下；用户已切走就只落库，不把路径拉回来（③b）
                if self.selectedConversation?.id == conversation.id {
                    self.nodeMap[sysNodeId] = sysNode
                    self.effectiveChildrenMap[sysNodeId] = []
                    self.effectiveChildrenMap[userNodeId, default: []].append(sysNodeId)
                }
                if self.selectedConversation?.id == conversation.id, self.displayLeafId == userNodeId {
                    self.currentPath.append(sysNode)
                    self.commitSelection(to: sysNodeId, conversation: conversation)
                } else if conversation.currentNodeId == userNodeId {
                    conversation.currentNodeId = sysNodeId
                }
                try? context.save()
            }
        }
    }

    /// C2 碎片池（v5 §3-1、plan §七）：每满 N 条新消息（`mem_c2_every` 默认 20，两边加起来；和 CC 那条路同一份水位 `FragmentWatch`）
    /// 把这一截交给小小模型填严格 JSON，只加不改不删。消息和 A2 同口径（`sessionMessages`，工具调用写成中性的 [调用了 …]）。
    /// 不带主提示词；模型默认跟提取模型，选了本机但没装 / 在后台这一轮用提取模型（第一次碰到没装弹一次提示）
    private func extractMemoriesIfNeeded(profileId: String, conversationId: String, names: MemoryExtractor.Names,
                                         model: ProviderModel, providerManager: ProviderManager, context: ModelContext) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("memoryExtract"); return }   // 测量角色旁路早退（perf P0 §3.2）
        #endif
        guard !profileId.isEmpty, MemoryFlags.factsEnabled else { return }

        // CR-4：agent 消息（自主读书的读后感等）不进提取窗口——AI 的话不该变成"关于粟粟的记忆"
        let agentNodeIds = Set(currentPath.filter { $0.agentOrigin != nil }.map(\.id))
        let path = sessionMessages().filter { !agentNodeIds.contains($0.id) }
        guard !path.isEmpty else { return }

        let route = MainActor.assumeIsolated { FragmentModelRoute.resolve(providerManager: providerManager, chatFallback: model) }
        let caller = FragmentModelRoute.caller(for: route.route, providerManager: providerManager,
                                               conversationId: conversationId, profileId: profileId)
        let store = memoryStore
        let every = FragmentWatch.every()
        Task.detached { [weak self] in
            // 没满 N 条 / 第一次见这个窗口 / 这个窗口正在跑：不动（水位成功处理后才提交，astra #3）
            guard let claim = await FragmentWatch.shared.due(conversationId: conversationId, pathIds: path.map(\.id),
                                                             dates: path.map(\.date), threshold: every) else { return }
            let recent = path[claim.range].map { FragmentPool.Message(id: $0.id, role: $0.role, content: $0.content, date: $0.date) }
            if route.localMissing {
                await MainActor.run {
                    guard !UserDefaults.standard.bool(forKey: Self.fragmentLocalHintKey) else { return }
                    UserDefaults.standard.set(true, forKey: Self.fragmentLocalHintKey)
                    self?.transientNotice = TransientNotice("🧠 C2 碎片池选的本机模型还没下载——去「设置 › 记忆 › C2 碎片池」下载；这一轮先用 \(route.displayName)")
                }
            }
            // 进后台被停下 / 断网 / 开关关了：不算失败，下一轮重来；整包拒收按失败记（连续 3 包状态卡变红）
            let outcome = await MemoryWriteLog.metered {
                await FragmentPool.process(recent, names: names, caller: caller, local: route.isLocal, profileId: profileId,
                                           modelName: route.displayName, fallbackNote: route.fallbackNote) { fragments in
                    // 认领超时作废了（另一轮已经接手）就不落库（10-16 astra #3）
                    guard await FragmentWatch.shared.holds(conversationId: conversationId, token: claim.token) else {
                        throw FragmentPoolError.staleClaim
                    }
                    return try await MainActor.run {
                        try FragmentPool.write(fragments, messages: recent, profileId: profileId, conversationId: conversationId,
                                               extractedBy: route.displayName, store: store, context: context)
                    }
                }
            }
            // 写成（含合法空包）/ 整包拒收才挪水位；预算跳过 / 断网 / 请求或落库失败留着下次再来（同 CC 那条路，10-16 astra #2）
            await FragmentWatch.shared.finish(conversationId: conversationId, claim: claim, outcome: outcome)
            switch outcome {
            case .done(let added) where added > 0:
                await MainActor.run {
                    self?.transientNotice = TransientNotice("🧠 记住 \(added) 条")
                    NotificationCenter.default.post(name: .memoryDidChange, object: nil)
                }
            case .failed, .rejected:
                await MainActor.run { self?.transientNotice = TransientNotice("🧠 记忆提取失败") }
            default:
                break
            }
        }
    }

    /// 「C2 选的本机模型还没下载」只弹一次
    static let fragmentLocalHintKey = "mem_c2_local_hint_shown"

    /// 窗口摘要用的消息：和历史窗口同一个口径（同一批候选、同一个计数），带 id 和时间（第三刀）
    func sessionMessages() -> [SessionSegmentWriter.Message] {
        // 上下文摘要的输入：工具调用写成中性的 [调用了 …]（#089 P0-b）
        historyCandidates(excluding: nil).map { node, content in
            let text = node.role == "assistant" && Self.hasToolUse(node.segments)
                ? ToolReplay.sideModelText(content: content, rounds: ToolReplay.rounds(from: node.segments) ?? [])
                : content
            return .init(id: node.id, role: node.role, content: text, date: node.createTime)
        }
    }

    /// 窗口摘要压缩触发（fire-and-forget）：超窗并攒够 N 轮就追加一段压缩段。
    /// v5 A8：A2 选「停 N 分钟」= 只记下这一轮的样子、静默够了巡检时压；「只手动」= 不自动压
    /// 测试（@testable）直接调这一条验证关参与窗不入队
    func triggerContextSummaryIfNeeded(conversation: Conversation, conversationId: String, conversationTitle: String, profile: Profile, contextDepth: Int, model: ProviderModel, providerManager: ProviderManager) {
        guard MemoryFlags.contextSummaryEnabled else { return }
        // 关参与窗不写（plan-memory-participation §2.2）；已排进 idle 队列的由 runIdleCompress 到点时复查
        guard EffectiveMemoryParticipation.resolve(profileId: profile.id, conversation: conversation, preset: nil).a2Write else { return }
        let mode = MemoryTriggers.mode(.a2)
        guard mode != .manual else { return }
        let messages = sessionMessages()
        let ctx = SessionCloseoutTrigger.context(profile: profile, providers: providerManager, chat: model,
                                                 container: conversation.modelContext?.container)
        let coveredBefore = ContextSummarizer.load(conversationId: conversationId, profileId: profile.id)?.coveredCount ?? 0
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("contextSummary"); return }   // 测量角色旁路早退（perf P0 §3.2；R7-09 同步前处理照跑、只拦后台外发）
        #endif
        if mode == .idle {
            guard messages.count > contextDepth else { return }
            let oldCount = messages.count - contextDepth
            Task.detached {
                await SessionCloseout.shared.noteIdleCompress(conversationId: conversationId, messages: messages, oldCount: oldCount,
                                                              title: conversationTitle, ctx: ctx)
            }
            return
        }
        Task.detached { [weak self] in
            try? await ContextSummarizer.summarize(
                messages: messages, contextDepth: contextDepth, conversationId: conversationId,
                conversationTitle: conversationTitle, ctx: ctx, providerManager: providerManager)
            // 自动压缩成功 → 弹胶囊（和 🧠 记住 N 条同款可见性，别藏调试页）
            await MainActor.run {
                if let s = ContextSummarizer.load(conversationId: conversationId, profileId: ctx.profileId), s.coveredCount != coveredBefore {
                    self?.transientNotice = TransientNotice("📝 上下文摘要记了一段（压到第 \(s.coveredCount) 条）")
                }
            }
        }
    }

    /// 手动压缩上下文（Prompt 页仪表盘按钮）。同自动规则：只压窗外，没超窗如实说。
    func manualCompressContext(contextDepth: Int, profile: Profile, model: ProviderModel, providerManager: ProviderManager) {
        guard MemoryFlags.contextSummaryEnabled else {
            transientNotice = TransientNotice("📝 上下文摘要已关闭（设置-记忆）")
            return
        }
        guard let conv = selectedConversation else { return }
        // 关参与窗不写（plan-memory-participation §2.2）：提示说清为什么不写
        guard EffectiveMemoryParticipation.resolve(profileId: conv.profileId, conversation: conv, preset: nil).a2Write else {
            transientNotice = TransientNotice("📝 本窗不参与记忆，不写上下文摘要")
            return
        }
        let convId = conv.id
        let convTitle = conv.title
        let all = sessionMessages()
        guard all.count > contextDepth else {
            transientNotice = TransientNotice("📝 未超窗（\(all.count)/\(contextDepth) 条），无需压缩")
            return
        }
        if let existing = ContextSummarizer.load(conversationId: convId, profileId: conv.profileId), existing.coveredCount == all.count - contextDepth {
            transientNotice = TransientNotice("📝 摘要已是最新（压到第 \(existing.coveredCount) 条）")
            return
        }
        transientNotice = TransientNotice("📝 压缩中…")
        // 手动：不看写入预算、不看冷却（v5 Q10）
        var ctx = SessionCloseoutTrigger.context(profile: profile, providers: providerManager, chat: model,
                                                 container: conv.modelContext?.container)
        ctx.manual = true
        let manualCtx = ctx
        Task.detached { [weak self] in
            try? await ContextSummarizer.summarize(
                messages: all, contextDepth: contextDepth, conversationId: convId,
                conversationTitle: convTitle, ctx: manualCtx, providerManager: providerManager, force: true)
            await MainActor.run {
                if let s = ContextSummarizer.load(conversationId: convId, profileId: manualCtx.profileId), s.coveredCount == all.count - contextDepth {
                    self?.transientNotice = TransientNotice("📝 上下文摘要记了一段（压到第 \(s.coveredCount) 条）")
                } else {
                    self?.transientNotice = TransientNotice("📝 压缩失败，看调试日志")
                }
            }
        }
    }

    /// 对话 ⋯「现在写」（plan §九）：这个窗口开着的 A2 / A3 / A4 立刻写一遍——A2 = 手动压缩（CC 窗口的 A2 在 `closeoutNow` 里写，astra #6），
    /// A3 = 跑一次收尾，不等静默、不看冷却；A4 = 拼最近几天 + 今天（今天的主调重写）；都不看写入预算（Q10）。写完提示「写好了：A2 1 段 · A4 1 天」；后台占着 / 没写成如实说（astra #10）
    func writeMemoryNow(contextDepth: Int, profile: Profile, model: ProviderModel, providerManager: ProviderManager) {
        guard MemoryFlags.masterEnabled, let conv = selectedConversation else { return }
        // 关参与窗：A2 被闸挡住、A3 / A4 拿到 nothingToWrite，最后提示「都写到最新了」会误导 → 开头就说清
        guard EffectiveMemoryParticipation.resolve(profileId: conv.profileId, conversation: conv, preset: nil).participates else {
            transientNotice = TransientNotice("📝 本窗不参与记忆，不写")
            return
        }
        let convId = conv.id, convTitle = conv.title
        let all = sessionMessages()
        let a2Write = EffectiveMemoryParticipation.resolve(profileId: conv.profileId, conversation: conv, preset: nil).a2Write
        let compressA2 = MemoryFlags.contextSummaryEnabled && a2Write && all.count > contextDepth && !SessionCloseout.isCCPath(currentPath.last { $0.role == "assistant" }.map { [ConversationMessage($0)] } ?? [])
        var ctx = SessionCloseoutTrigger.context(profile: profile, providers: providerManager, chat: model,
                                                 container: conv.modelContext?.container)
        ctx.manual = true
        let manualCtx = ctx
        transientNotice = TransientNotice("📝 正在写…")
        Task.detached { [weak self] in
            func formalCount() -> Int {
                SessionSummaryStore.load(conversationId: convId, memoryRoot: FileLibraryStore.memoryRoot(profileId: manualCtx.profileId))?.segments.filter { !$0.isTail }.count ?? 0
            }
            var a2 = 0
            var a2Failed = false
            if compressA2 {
                let before = formalCount()
                do {
                    try await ContextSummarizer.summarize(messages: all, contextDepth: contextDepth, conversationId: convId,
                                                          conversationTitle: convTitle, ctx: manualCtx, providerManager: providerManager, force: true)
                } catch {
                    a2Failed = true
                }
                a2 = max(0, formalCount() - before)
            }
            let r = await SessionCloseoutTrigger.shared.writeNow(conversationId: convId, profile: profile)
            let text = Self.writeNowSummary(a2Segments: a2, a2Failed: a2Failed, result: r)
            await MainActor.run {
                self?.transientNotice = TransientNotice(text)
                NotificationCenter.default.post(name: .memoryDidChange, object: nil)
            }
        }
    }

    /// 纯函数（可测）：「写好了：A2 1 段 · A4 1 天」；后台占着 / 出错 / 预算闸拦下各说各的，确实没新的才说「都写到最新了」（astra #10）
    static func writeNowSummary(a2Segments: Int, a2Failed: Bool = false, result: SessionCloseout.CloseoutResult) -> String {
        if result.busy { return "📝 后台正在写这个窗口，稍后再点" }
        var parts: [String] = []
        let a2 = a2Segments + result.context + (result.tail ? 1 : 0)
        if a2 > 0 { parts.append("A2 \(a2) 段") }
        if result.window { parts.append("A3 1 段") }
        if result.timeline > 0 { parts.append("A4 \(result.timeline) 天") }
        let failed = a2Failed || result.failed
        if !parts.isEmpty {
            return "📝 写好了：" + parts.joined(separator: " · ") + (failed || result.skipped ? "（有一项没写成）" : "")
        }
        if failed { return "📝 没写成，看记忆日志" }
        if result.skipped { return "📝 没写成：被预算闸拦下，或模型没回内容（手动不看写入预算）" }
        return "📝 没有要写的（都写到最新了）"
    }

    /// M7 图片转述：3 条之前的旧图后台生成 80 字描述（每轮最多 2 张），存 node.imageDescsData。
    private func transcribeImagesIfNeeded(model: ProviderModel, providerManager: ProviderManager, context: ModelContext) {
        guard UserDefaults.standard.object(forKey: "imageTranscriptionEnabled") as? Bool ?? true else { return }
        let msgs = currentPath.filter { ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent }
        guard msgs.count > 3 else { return }
        var batch: [(node: MessageNode, name: String, data: Data)] = []
        outer: for node in msgs.dropLast(3) where node.role == "user" {
            guard let segs = node.segments?.hydratedForDisplay(profileId: node.profileId) else { continue }
            let descs = node.imageDescs
            for seg in segs {
                if case .image(let name, _, let data) = seg, descs[name] == nil {
                    batch.append((node, name, data))
                    if batch.count >= 2 { break outer }
                }
            }
        }
        guard !batch.isEmpty else { return }
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("imageTranscribe"); return }   // 测量角色旁路早退（perf P0 §3.2；R7-09 同步前处理照跑、只拦后台外发）
        #endif
        let router = ProviderRouter(usageContext: UsageContext(kind: .image, conversationId: selectedConversation?.id, profileId: selectedConversation?.profileId))
        Task { @MainActor in
            for item in batch {
                guard let att = try? PendingChatAttachment.image(
                    name: item.name, typeDescription: "图片", mimeType: "image/jpeg", data: item.data) else { continue }
                let prompt = "用中文客观描述这张图，80 字以内。保留界面文字和数字、人物动作、物品、场景。只输出描述。"
                guard let (desc, _) = try? await router.sendNonStreaming(
                    model: model, messages: [(role: "user", content: prompt)],
                    systemPrompt: nil, providerManager: providerManager, images: [att]
                ) else {
                    CacheDiagLog.shared.log("🖼 图片转述: ❌ \(item.name) 调用失败")
                    continue
                }
                let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    CacheDiagLog.shared.log("🖼 图片转述: ⚠️ \(item.name) 返回空")
                    continue
                }
                item.node.setImageDesc(String(trimmed.prefix(120)), for: item.name)
                CacheDiagLog.shared.log("🖼 图片转述: \(item.name) → \(min(trimmed.count, 120)) 字")
            }
            try? context.save()
        }
    }

    /// v2c A 模式：心声实时插进聊天流（追加为当前路径末尾的 assistant 节点）。
    /// contentType="heartvoice" 让 CardFlowView 识别后用 HeartvoiceCardView 卡片渲染（日记本样式）。
    /// content 存干净正文（不带 💭 头标）。老消息（"💭 心声\n\n" 前缀 + contentType="text"）渲染层兼容剥前缀。
    private func appendHeartvoiceMessage(text: String, conversation: Conversation, context: ModelContext) {
        // 心声异步晚到：用户已换到别的对话时 currentPath 属于那边，不能挂过去
        guard selectedConversation?.id == conversation.id, let parent = currentPath.last else { return }
        let node = MessageNode(
            id: UUID().uuidString, role: "assistant",
            content: text, contentType: "heartvoice",
            createTime: Date(), parentId: parent.id, childrenIds: [],
            conversationId: conversation.id, profileId: conversation.profileId
        )
        context.insert(node)
        parent.childrenIds.append(node.id)
        nodeMap[node.id] = node
        effectiveChildrenMap[node.id] = []
        effectiveChildrenMap[parent.id, default: []].append(node.id)
        commitSelection(to: node.id, conversation: conversation)
        currentPath.append(node)
        try? context.save()
    }

    /// Regenerate: create a new assistant response as a sibling branch of the existing one
    func regenerate(assistantNodeId: String, model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, context: ModelContext) {
        let isCC = providerManager.provider(for: model)?.type == .ccBridge
        guard !isLoading, failedTreeConversationId == nil || failedTreeConversationId != selectedConversation?.id,
              !assistantTurnInFlight || (isCC && activeConversationId != selectedConversation?.id) else { return }
        if let conversationId = selectedConversation?.id, ccPreparationTails[conversationId] != nil {
            queuedCCSends[conversationId, default: []].append(QueuedCCSend(enqueueOrder: allocateSendOrder(), isCC: isCC, recovery: nil) {
                guard self.selectedConversation?.id == conversationId else { return }
                self.regenerate(assistantNodeId: assistantNodeId, model: model, profile: profile, preset: preset,
                                providerManager: providerManager, context: context)
            })
            return
        }
        guard preCheckBudget(text: "", model: model, profile: profile, preset: preset, providerManager: providerManager) else { return }
        guard let conversation = selectedConversation, !conversation.isReadOnlyArchive,
              let oldNode = nodeMap[assistantNodeId],
              oldNode.role == "assistant",
              let userParentId = oldNode.parentId,
              let userParent = nodeMap[userParentId]
        else { return }
        SpeechService.shared.stop()
        BreadcrumbLog.shared.add("🔄", "重新生成@「\(conversation.title)」")

        // ccBridge 收口即发（plan-跨对话排队 M4）：不建占位节点，重发锚点 user 原文。
        // path 截到 user 为止（旧回复保留在树里），currentNodeId 回拨到 user →
        // 回复 proactive 落地时链成该 user 的新孩子 = 旧回复的 sibling 分支。
        if providerManager.provider(for: model)?.type == .ccBridge {
            if let idx = currentPath.firstIndex(where: { $0.id == assistantNodeId }) {
                currentPath.removeSubrange(idx...)
            }
            conversation.currentNodeId = userParentId
            displayLeafId = userParentId   // 显示路径也截到 user：回复落地时按「接在眼前」上屏
            conversation.updateTime = Date()
            markConversationDirty()
            MainActor.assumeIsolated {
                preparePromptSend(conversation: conversation, profileId: profile.id, targetNodeId: userParentId, context: context, isCC: true) { warmedWiki in
                    let assembled = self.assemblePrompt(profile: profile, providerType: providerManager.provider(for: model)?.type, preset: preset, excludingNodeId: "", context: context, globalEntries: self.globalWorldBookEntries, fileLibraryHint: nil, conversation: conversation, warmedWiki: warmedWiki, imagesAllowed: VisionCapability.of(model, providerType: providerManager.provider(for: model)?.type) != .no)
                    let payload = self.prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: userParentId)
                    self.sendCCFireAndForget(payload: payload, model: model, conversation: conversation, profile: profile, providerManager: providerManager)
                }
            }
            try? context.save()
            scrollToNodeId = userParentId
            return
        }

        let abortPath = currentPath
        let abortLeafId = displayLeafId ?? currentPath.last?.id
        // Create new assistant node as sibling
        let newAssistantId = UUID().uuidString
        let newNode = MessageNode(
            id: newAssistantId,
            role: "assistant",
            content: "",
            contentType: "text",
            createTime: Date(),
            parentId: userParentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        newNode.cardEventsData = oldNode.cardEventsData   // 10-29：表情触发的那轮重新生成，触发事件跟着新版本走
        context.insert(newNode)
        // §2.5：新回复只继承「上一版已生效」这一格，attempts / reads 从空开始
        if let decision = oldNode.recallReceipt?.decision ?? userParent.recallReceipt?.decision {
            var inherited = RecallTurnReceipt(decision: decision)
            inherited.inheritedEffective = oldNode.recallReceipt?.hasEffectiveResponse
            newNode.recallReceipt = inherited
        }

        userParent.childrenIds.append(newAssistantId)
        nodeMap[newAssistantId] = newNode
        effectiveChildrenMap[newAssistantId] = []
        effectiveChildrenMap[userParentId, default: []].append(newAssistantId)

        // Replace old node in path with new one
        if let idx = currentPath.firstIndex(where: { $0.id == assistantNodeId }) {
            // Remove everything after the old assistant node
            currentPath.removeSubrange(idx...)
            currentPath.append(newNode)
            markPop(newNode.id)
        }
        rebuildBranchInfoMap()   // 新回复是旧回复的兄弟：切换器立刻出在新回复上

        commitSelection(to: newAssistantId, conversation: conversation)
        conversation.updateTime = Date()
        markConversationDirty()
        assistantTurnInFlight = true
        activeAssistantNodeId = newAssistantId
        activeConversationId = conversation.id
        streamingText = ""

        MainActor.assumeIsolated {
            preparePromptSend(conversation: conversation, profileId: profile.id, targetNodeId: newAssistantId,
                              context: context, resolveAsks: true, abortLeafId: abortLeafId, abortPath: abortPath) { warmedWiki in
                let injection = self.toolInjection(for: model, providerManager: providerManager, conversation: conversation, profileId: conversation.profileId,
                                                   userName: profile.userName)
                ToolDrawerStore.shared.recordSent(conversationId: conversation.id, signature: ToolSignature(tools: injection.tools, offered: injection.offered))
                let fileHint = injection.systemHint.isEmpty ? nil : injection.systemHint
                let assembled = self.assemblePrompt(profile: profile, providerType: providerManager.provider(for: model)?.type, preset: preset, excludingNodeId: newAssistantId, context: context, globalEntries: self.globalWorldBookEntries, fileLibraryHint: fileHint, cardGuide: Self.cardGuideChoice(tools: injection.tools, offered: injection.offered, profileId: profile.id), conversation: conversation, warmedWiki: warmedWiki, imagesAllowed: VisionCapability.of(model, providerType: providerManager.provider(for: model)?.type) != .no)
                newNode.setRecallHits(assembled.recallHits)
                let payload = self.prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: newAssistantId, offered: injection.offered)
                self.runStreamingTurn(
                    payload: payload, systemPrompt: payload.systemPrompt,
                    model: model, providerManager: providerManager,
                    conversation: conversation, assistantNode: newNode, assistantNodeId: newAssistantId,
                    profile: profile, preset: preset, context: context,
                    tools: injection.tools, toolTurns: [], round: 0
                )
            }
        }

        scrollToNodeId = newAssistantId
    }

    /// Edit a user message: create a new branch from the original message's parent with new text, then get a response
    /// 返回 false = 没发出去（turn 中 / 预算拦 / 节点找不到）——输入框编辑态据此保留文字。
    /// attachments / 引用只有输入框编辑传（plan-edit-attachments）；user「重新生成」和 Page2 不传，不读 vm 里的草稿引用
    @discardableResult
    func editAndResend(_ originalNodeId: String, newText: String, attachments: [PendingChatAttachment] = [],
                       replyToId: String? = nil, replyQuote: String? = nil, isEdit: Bool = false,
                       model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, context: ModelContext) -> Bool {
        let isCC = providerManager.provider(for: model)?.type == .ccBridge
        guard !isLoading, failedTreeConversationId == nil || failedTreeConversationId != selectedConversation?.id,
              !assistantTurnInFlight || (isCC && activeConversationId != selectedConversation?.id) else { return false }
        if let conversationId = selectedConversation?.id, ccPreparationTails[conversationId] != nil {
            let recovery = PendingSend(
                text: newText, attachments: attachments,
                quotePreview: replyQuote, quoteReplyTo: replyToId,
                model: model, profile: profile, preset: preset,
                providerManager: providerManager, context: context,
                conversationId: conversationId
            )
            queuedCCSends[conversationId, default: []].append(QueuedCCSend(enqueueOrder: allocateSendOrder(), isCC: isCC, recovery: recovery) {
                guard self.selectedConversation?.id == conversationId else { return }
                _ = self.editAndResend(originalNodeId, newText: newText, attachments: attachments,
                                       replyToId: replyToId, replyQuote: replyQuote, isEdit: isEdit,
                                       model: model, profile: profile, preset: preset,
                                       providerManager: providerManager, context: context)
            })
            return true
        }
        // ⑤a：真编辑（isEdit）才跑 runOnEdit 输入规则；「重新生成」原文重发不再跑一遍
        let editedBase = expandUserMacros(newText, profile: profile, context: context).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = ChatAttachmentPromptBuilder.userMessage(
            displayBase: isEdit ? applyInputRegex(editedBase, role: "user", isEdit: true, profile: profile, preset: preset) : editedBase,
            attachments: attachments)
        guard let conversation = selectedConversation,
              let originalNode = nodeMap[originalNodeId],
              originalNode.role == "user"
        else { return false }
        // 先预检后截路径：预检只算原节点之前的上下文，拦了什么都不动（H4）
        let keptPath = Array(currentPath.prefix(while: { $0.id != originalNodeId }))
        guard preCheckBudget(text: parts.modelText, model: model, profile: profile, preset: preset,
                             providerManager: providerManager, path: keptPath) else { return false }
        SpeechService.shared.stop()
        BreadcrumbLog.shared.add("✏️", "编辑重发@「\(conversation.title)」（\(parts.modelText.count)字）")

        let abortPath = currentPath
        let abortLeafId = displayLeafId ?? currentPath.last?.id
        currentPath = keptPath
        let grandparentId = originalNode.parentId ?? adoptUnderInvisibleRoot(originalNode, conversation: conversation, context: context)

        // Create new user node as sibling branch
        let newUserId = UUID().uuidString
        let newUserNode = MessageNode(
            id: newUserId,
            role: "user",
            content: parts.modelText,
            contentType: parts.contentType,
            createTime: Date(),
            parentId: grandparentId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        if let segments = parts.segments {
            newUserNode.setSegments(segments, conversationTitle: conversation.title)
        }
        newUserNode.replyToId = replyToId
        newUserNode.replyQuote = replyQuote
        newUserNode.cardEventsData = originalNode.cardEventsData   // §13：那一轮捎带的事件跟着新版本走，箱子不动
        context.insert(newUserNode)

        if let grandparent = nodeMap[grandparentId] {
            if !grandparent.childrenIds.contains(newUserId) {
                grandparent.childrenIds.append(newUserId)
            }
            effectiveChildrenMap[grandparentId, default: []].append(newUserId)
        }
        nodeMap[newUserId] = newUserNode
        effectiveChildrenMap[newUserId] = []
        currentPath.append(newUserNode)
        markPop(newUserId)
        rebuildBranchInfoMap()   // 新版本是原消息的兄弟：切换器立刻出在新的这条上

        // ccBridge 收口即发（plan-跨对话排队 M4）：编辑分支的 user 节点已建好，
        // 不建占位、不进流式管线；currentNodeId 指到新 user，回复 proactive 链上来。
        if providerManager.provider(for: model)?.type == .ccBridge {
            commitSelection(to: newUserId, conversation: conversation)
            conversation.updateTime = Date()
            markConversationDirty()
            MainActor.assumeIsolated {
                preparePromptSend(conversation: conversation, profileId: profile.id, targetNodeId: newUserId,
                                  context: context, isCC: true, markCCUnsentOnAbort: true) { warmedWiki in
                    let assembled = self.assemblePrompt(profile: profile, providerType: providerManager.provider(for: model)?.type, preset: preset, excludingNodeId: "", context: context, globalEntries: self.globalWorldBookEntries, fileLibraryHint: nil, conversation: conversation, warmedWiki: warmedWiki, imagesAllowed: VisionCapability.of(model, providerType: providerManager.provider(for: model)?.type) != .no)
                    let payload = self.prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: newUserId)
                    self.sendCCFireAndForget(payload: payload, model: model, conversation: conversation, profile: profile, providerManager: providerManager)
                }
            }
            try? context.save()
            scrollToNodeId = newUserId
            return true
        }

        // Create placeholder assistant node
        let newAssistantId = UUID().uuidString
        let newAssistantNode = MessageNode(
            id: newAssistantId,
            role: "assistant",
            content: "",
            contentType: "text",
            createTime: Date(),
            parentId: newUserId,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: conversation.profileId
        )
        context.insert(newAssistantNode)

        newUserNode.childrenIds.append(newAssistantId)
        nodeMap[newAssistantId] = newAssistantNode
        effectiveChildrenMap[newAssistantId] = []
        effectiveChildrenMap[newUserId, default: []].append(newAssistantId)
        currentPath.append(newAssistantNode)
        markPop(newAssistantId)

        commitSelection(to: newAssistantId, conversation: conversation)
        conversation.updateTime = Date()
        markConversationDirty()
        assistantTurnInFlight = true
        activeAssistantNodeId = newAssistantId
        activeConversationId = conversation.id
        streamingText = ""

        MainActor.assumeIsolated {
            preparePromptSend(conversation: conversation, profileId: profile.id, targetNodeId: newAssistantId,
                              context: context, resolveAsks: true, abortLeafId: abortLeafId, abortPath: abortPath) { warmedWiki in
                let injection = self.toolInjection(for: model, providerManager: providerManager, conversation: conversation, profileId: conversation.profileId,
                                                   userName: profile.userName)
                ToolDrawerStore.shared.recordSent(conversationId: conversation.id, signature: ToolSignature(tools: injection.tools, offered: injection.offered))
                let fileHint = injection.systemHint.isEmpty ? nil : injection.systemHint
                let assembled = self.assemblePrompt(profile: profile, providerType: providerManager.provider(for: model)?.type, preset: preset, excludingNodeId: newAssistantId, context: context, globalEntries: self.globalWorldBookEntries, fileLibraryHint: fileHint, cardGuide: Self.cardGuideChoice(tools: injection.tools, offered: injection.offered, profileId: profile.id), conversation: conversation, warmedWiki: warmedWiki, imagesAllowed: VisionCapability.of(model, providerType: providerManager.provider(for: model)?.type) != .no)
                newAssistantNode.setRecallHits(assembled.recallHits)
                let payload = self.prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: newAssistantId, offered: injection.offered)
                self.runStreamingTurn(
                    payload: payload, systemPrompt: payload.systemPrompt,
                    model: model, providerManager: providerManager,
                    conversation: conversation, assistantNode: newAssistantNode, assistantNodeId: newAssistantId,
                    profile: profile, preset: preset, context: context,
                    tools: injection.tools, toolTurns: [], round: 0
                )
            }
        }

        scrollToNodeId = newUserId
        return true
    }

    // MARK: - Draft Conversation（草稿对话：真 id 但延迟落库，发首条消息才出现在 page0）

    /// 当前 selectedConversation 是否还是未落库的草稿
    private(set) var isDraftConversation = false
    /// 草稿的 invisible root，转正时一并 insert
    private var draftRootNode: MessageNode?
    /// B5：卡楼层草稿的开场白（隐形根下的兄弟候选），和根一样只在内存，转正时一并 insert
    private var draftGreetingNodes: [MessageNode] = []

    /// 段④：新建纸条和菜单编辑共用请求，目标窗不依赖当前选中窗
    struct OpenWindowNoteRequest: Identifiable, Equatable {
        enum Mode: Equatable { case newConversation, editChoices }
        let conversation: Conversation
        let mode: Mode
        /// 取消新建时回到的窗口（没有 = 留在草稿上按默认）
        let returnConversationId: String?
        var conversationId: String { conversation.id }
        var profileId: String { conversation.profileId }
        var id: String { conversationId }
        var initialChoices: MemoryWindowChoices {
            if let choices = conversation.memoryWindowChoices { return choices }
            var legacy = MemoryWindowChoices.legacy(profileId: profileId)
            // 老窗触发与根索引独立；纸条档案行显示实际开着的状态，不为显示改写老窗。
            legacy.archive = legacy.archive || RecallTuningStore.load(profileId: profileId).archiveTriggerEnabled
            return legacy
        }
    }

    var openWindowNote: OpenWindowNoteRequest?
    /// 这个草稿是普通聊天入口建的（专用草稿不冻结六项，保持老窗语义）
    @ObservationIgnored private var draftIsNormalChat = false
    /// 已经弹过纸条的草稿（同一草稿再进不再弹）
    @ObservationIgnored private var notedDraftId: String?

    // MARK: - 上个窗口冻结（E2-7b：主线程只 latest + 写选择，正文抓取在后台）

    /// 正在后台抓正文的目标窗；发送路径用 `.task.value` 等它（键清掉 = 已落定）。
    /// token 用于完成回调只清自己那一项：同窗重开冻结时别把新任务从表里抹掉
    @ObservationIgnored private var freezingWindows: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// 纸条据此显示「正在读取上个窗口…」（@Observable 追踪，完成即刷新）
    private(set) var freezingWindowIds: Set<String> = []

    func isFreezing(_ conversationId: String) -> Bool { freezingWindowIds.contains(conversationId) }

    /// 发送路径用：这个窗口还在冻结就等它落定；没在冻立即返回
    @MainActor
    func awaitPreviousWindowFreeze(_ conversationId: String) async {
        await freezingWindows[conversationId]?.task.value
    }

    /// 同步冻结选择 + 上窗 id，正文抓取登记到后台；完成后回主线程写快照并保存
    @MainActor
    func freezePreviousWindow(_ conversation: Conversation, context: ModelContext, forNote: Bool = false) {
        guard let plan = PreviousWindowPicker.prepareFreeze(conversation, context: context, forNote: forNote) else { return }
        registerFreeze(plan: plan, conversationId: conversation.id, container: context.container, context: context)
    }

    /// E2-7b r4 M2：首句落库（choices + 上窗 id 已 save）后、快照回写前进程退出 → 重启后任务表是空的，
    /// 而 choices 非 nil 会阻止 `prepareFreeze` 重冻。发送前按已存的 `previousWindowId` 补抓一次；
    /// 源窗已经不在 / 进了回收站 → 直接落不可逆占位（不退回「没有快照」，也不带正文）。
    @MainActor
    func resumePreviousWindowFreezeIfNeeded(_ conversation: Conversation, context: ModelContext) {
        guard !isDraftConversation,
              let sourceId = conversation.previousWindowId,
              conversation.previousWindowSnapshot == nil,
              freezingWindows[conversation.id] == nil else { return }
        guard let source = Self.fetchConversation(sourceId, context: context), !source.isTrashed else {
            conversation.previousWindowSnapshot = .deletedPlaceholder(sourceId: sourceId)
            if let mc = conversation.modelContext { try? mc.save() }
            return
        }
        let plan = PreviousWindowPicker.FreezePlan(
            window: SwiftDataConversationSource.window(source),
            count: RecallTuningStore.load(profileId: conversation.profileId).previousWindowMessages)
        registerFreeze(plan: plan, conversationId: conversation.id, container: context.container, context: context)
    }

    /// 登记一次后台抓取；开窗冻结与重启后补冻共用同一条路径
    @MainActor
    private func registerFreeze(plan: PreviousWindowPicker.FreezePlan, conversationId: String,
                                container: ModelContainer, context: ModelContext) {
        let token = UUID()
        freezingWindows[conversationId]?.task.cancel()
        freezingWindowIds.insert(conversationId)
        freezingWindows[conversationId] = (token, Task { @MainActor [weak self] in
            let snapshot = await PreviousWindowPicker.captureInBackground(plan, container: container)
            guard let self else { return }
            // 只认自己那一项：同窗又开了新一次冻结 / 已取消清表时，旧 token 既不写表也不写快照
            let mine = self.freezingWindows[conversationId]?.token == token
            if mine {
                self.freezingWindows[conversationId] = nil
                self.freezingWindowIds.remove(conversationId)
            }
            // 冻结中被取消（纸条划掉上个窗口）/ 切走 / 删窗：结果丢弃，不晚写
            guard mine, !Task.isCancelled, let snapshot else { return }
            // 草稿还没落库，只有当前选中这一份能拿到；其余一律按 id 回库确认还在（删了 = 丢弃）
            let target = self.isDraftConversation && self.selectedConversation?.id == conversationId
                ? self.selectedConversation : Self.fetchConversation(conversationId, context: context)
            guard let target, target.previousWindowId == plan.window.id else { return }
            // E2-7b r4 M1：抓取挂起期间源窗可能被删 / 进回收站 —— 那时 `invalidateCopies` 还没有快照可清，
            // 迟到的正文不能写回（否则恢复源窗后发送侧 `validate` 会放行）。落不可逆失效，与它结果一致。
            let source = Self.fetchConversation(plan.window.id, context: context)
            var landed = snapshot
            if source == nil || source?.isTrashed == true { landed.invalidate(.deleted) }
            target.previousWindowSnapshot = landed
            // 草稿还没 insert：save 只会把主 context 里别处的待存改动提前落盘。save 失败同 HEAD 吞掉
            if target.modelContext != nil { try? context.save() }
        })
    }

    /// 划掉 / 切走 / 丢草稿：取消后台抓取并解除登记 —— 等待者立刻返回，不再等已取消任务跑完
    @MainActor
    func cancelPreviousWindowFreeze(_ conversationId: String) {
        freezingWindows[conversationId]?.task.cancel()
        freezingWindows[conversationId] = nil
        freezingWindowIds.remove(conversationId)
    }

    @MainActor
    private static func fetchConversation(_ id: String, context: ModelContext) -> Conversation? {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// B5：开新对话的公共口（page0 新建 / ⌘N / 启动和切楼层后的自动草稿）——从卡建的楼层带开场白，其余照旧空草稿。
    /// 读书、单词、学习、Codex 这些专用草稿不走这里。
    /// 段④：explicit = 她亲手点的新建（page0 / ⌘N），带 context 才能当场冻结并弹纸条；自动草稿在转正时才冻结
    @MainActor
    func startNewConversation(profileId: String, fresh: Bool = false, displayMode: ConversationDisplayMode = .article,
                              cards: CharacterCardManager?, explicit: Bool = false, context: ModelContext? = nil) {
        let previous = isDraftConversation ? nil : selectedConversation?.id
        let wasDraftId = isDraftConversation ? selectedConversation?.id : nil
        startDraftConversation(profileId: profileId, fresh: fresh, displayMode: displayMode,
                               greetings: CharacterFloorService.greetings(profileId: profileId, cards: cards?.cards ?? []))
        guard isDraftConversation, let draft = selectedConversation else { return }
        if draft.id != wasDraftId { draftIsNormalChat = true }
        guard draftIsNormalChat, explicit, let context, notedDraftId != draft.id else { return }
        // 显式新建 = 这一刻冻结（自动草稿还没冻结过就现在冻；冻过的不重来）
        // 总开关关着照弹（纸条上写明「勾了也不带」，选择照存、不暗开总开关）
        let showNote = MemoryOpenWindowNote.enabled(profileId: profileId)
        if draft.memoryWindowChoicesData == nil { freezePreviousWindow(draft, context: context, forNote: showNote) }
        guard showNote else { return }
        notedDraftId = draft.id
        openWindowNote = OpenWindowNoteRequest(conversation: draft, mode: .newConversation, returnConversationId: previous)
    }

    @MainActor
    func editOpenWindowNote(for conversation: Conversation) {
        openWindowNote = OpenWindowNoteRequest(conversation: conversation, mode: .editChoices, returnConversationId: nil)
    }

    /// 纸条「就这样」：写本窗选择；上个窗口那一勾划掉就不留副本正文
    @MainActor
    func confirmOpenWindowNote(_ choices: MemoryWindowChoices, initialChoices: MemoryWindowChoices? = nil) {
        defer { openWindowNote = nil }
        guard let request = openWindowNote else { return }
        let conversation = request.conversation
        if request.mode == .editChoices, conversation.memoryWindowChoicesData == nil,
           choices == (initialChoices ?? MemoryWindowChoices.legacy(profileId: request.profileId)) { return }
        conversation.memoryWindowChoices = choices
        if !choices.previousWindow {
            // E2-7b：冻结还没落定就划掉 → 取消后台任务并解除登记，结果丢弃（快照 / id 立刻清）
            cancelPreviousWindowFreeze(conversation.id)
            conversation.previousWindowId = nil
            conversation.previousWindowSnapshot = nil
        }
        try? conversation.modelContext?.save()
    }

    /// 纸条下滑关掉：按冻结时的默认（上个窗口默认不勾就不留副本）
    @MainActor
    func dismissOpenWindowNote() {
        guard openWindowNote != nil else { return }
        guard openWindowNote?.mode == .newConversation else { openWindowNote = nil; return }
        guard let conversation = selectedConversation, conversation.id == openWindowNote?.conversationId,
              let frozen = conversation.memoryWindowChoices else { openWindowNote = nil; return }
        confirmOpenWindowNote(frozen)
    }

    /// 纸条「不开了」：回到原来那个窗口，草稿没落库直接丢；没有原窗口就留在草稿上（按默认）
    @MainActor
    func cancelOpenWindowNote(context: ModelContext) {
        defer { openWindowNote = nil }
        guard let request = openWindowNote, request.mode == .newConversation else { return }
        guard isDraftConversation, selectedConversation?.id == request.conversationId,
              let rid = request.returnConversationId else { dismissOpenWindowNote(); return }
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == rid })
        descriptor.fetchLimit = 1
        guard let back = try? context.fetch(descriptor).first, !back.isTrashed else { dismissOpenWindowNote(); return }
        draftIsNormalChat = false
        // 丢草稿前收尾：后台冻结还在跑就取消并清登记（草稿不 insert，回写无处落）
        cancelPreviousWindowFreeze(request.conversationId)
        loadConversation(back, context: context)   // 会离开草稿态，草稿对象没 insert 过，直接丢
    }

    /// 起一个草稿对话：建对象但不 insert，UI 直接进聊天界面（空消息 + 输入框）。
    /// 发首条消息时 commitDraftConversationIfNeeded 落库；没发就切走 = 丢弃，不污染列表。
    @MainActor
    func startDraftConversation(profileId: String, fresh: Bool = false, displayMode: ConversationDisplayMode = .article,
                                greetings: [String] = []) {
        // 已是同楼层草稿就不重建（避免覆盖用户正在输入的上下文），只把模式换成这次要的；楼层变了则重建。
        // fresh：page0 ＋ 菜单明确点了「新建」（可能从 Codex 草稿换成普通草稿）→ 总是重建
        if !fresh, isDraftConversation, let c = selectedConversation, c.profileId == profileId {
            if c.mode != displayMode {
                c.mode = displayMode
                syncBubbleModeToTheme()
            }
            return
        }
        wikiInjectionCache.prefetch(profileId: profileId)
        // 第三刀：新开窗口 → 刚才在聊的对话立刻收尾（草稿是新窗口最常见的入口）
        defer { SessionCloseoutTrigger.shared.request(newConversationId: selectedConversation?.id) }

        let rootId = UUID().uuidString
        let conversation = Conversation(
            id: UUID().uuidString,
            title: "新对话",
            createTime: Date(),
            updateTime: Date(),
            currentNodeId: rootId,
            provider: "api",
            profileId: profileId
        )
        conversation.mode = displayMode
        let rootNode = MessageNode(
            id: rootId, role: "system", content: "", contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [],
            conversationId: conversation.id, profileId: profileId
        )
        // 不 insert —— 纯内存对象
        draftRootNode = rootNode
        draftGreetingNodes = []
        isDraftConversation = true
        draftIsNormalChat = false   // 段④：专用草稿保持老窗语义；普通聊天由 startNewConversation 标上

        // 模拟空对话 load 后的状态（invisible root 不进 pathNodeIds，故 currentPath 为空）
        selectedConversation = conversation
        displayedTreeConversationId = conversation.id
        failedTreeConversationId = nil
        isLoading = false
        currentPath = []
        timeDividerCache.reset()
        bubbleRunCache.reset()
        nodeMap = [rootId: rootNode]
        effectiveChildrenMap = [rootId: []]
        cachedRootId = rootId
        mainPathIds = []
        branchSelection.removeAll()
        displayLeafId = nil
        bubbledBranches.removeAll()
        branchInfoMap.removeAll()

        // B5：开场白挂在隐形根下（同 CharacterFloorService.makeChat 的形状），默认停在第一条
        let (shaped, nodes) = CharacterFloorService.makeChat(title: conversation.title, greetings: greetings, profileId: profileId)
        guard nodes.count > 1 else { return }
        let children = Array(nodes.dropFirst())
        for child in children { child.parentId = rootId; child.conversationId = conversation.id }
        rootNode.isSyntheticRoot = true
        rootNode.childrenIds = children.map(\.id)
        conversation.provider = shaped.provider
        conversation.currentNodeId = children[0].id
        conversation.nodeCount = 1
        draftGreetingNodes = children
        for child in children { nodeMap[child.id] = child }
        effectiveChildrenMap = [rootId: rootNode.childrenIds]
        mainPathIds = [rootId, children[0].id]
        branchSelection = [rootId: children[0].id]
        displayLeafId = children[0].id
        currentPath = [children[0]]
        rebuildBranchInfoMap()
    }

    /// 草稿转正：发首条消息前调用，把 conversation + root 落库（此后才进 page0 列表）。
    @MainActor
    private func commitDraftConversationIfNeeded(context: ModelContext) {
        guard isDraftConversation, let conversation = selectedConversation else { return }
        // 段④：普通聊天草稿转正 = 窗口真的开了，没冻结过（自动草稿）就现在冻结六项和上个窗口
        if draftIsNormalChat, conversation.memoryWindowChoicesData == nil {
            freezePreviousWindow(conversation, context: context)
        }
        draftIsNormalChat = false
        context.insert(conversation)
        if let root = draftRootNode { context.insert(root) }
        draftGreetingNodes.forEach { context.insert($0) }
        try? context.save()
        isDraftConversation = false
        draftRootNode = nil
        draftGreetingNodes = []
    }

    /// Create a new empty conversation for chatting
    func createNewConversation(title: String, profileId: String, displayMode: ConversationDisplayMode = .article,
                               context: ModelContext) -> Conversation {
        let rootId = UUID().uuidString
        let conversation = Conversation(
            id: UUID().uuidString,
            title: title,
            createTime: Date(),
            updateTime: Date(),
            currentNodeId: rootId,
            provider: "api",
            profileId: profileId
        )
        conversation.mode = displayMode
        context.insert(conversation)

        // Create invisible root node
        let rootNode = MessageNode(
            id: rootId,
            role: "system",
            content: "",
            contentType: "text",
            createTime: Date(),
            parentId: nil,
            childrenIds: [],
            conversationId: conversation.id,
            profileId: profileId
        )
        context.insert(rootNode)
        try? context.save()
        // 第三刀：新开窗口 → 刚才在聊的对话立刻收尾（不等静默），新窗口第一轮就能看到时间轴
        SessionCloseoutTrigger.shared.request(newConversationId: conversation.id)

        return conversation
    }

    /// 复制对话：含全部分支消息树、附件目录、标签/气泡收藏。
    /// 标题 xxx-copy，已存在则 xxx-copy2/copy3…。不复制 importBatchId（批量撤销别误删副本）
    /// 和 ccBridgeSessionName（CC session 绑定不能共享）。
    @discardableResult
    func duplicateConversation(_ original: Conversation, context: ModelContext) -> Conversation {
        let pid = original.profileId
        let convId = original.id
        let newConvId = UUID().uuidString

        let titleDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid && $0.isTrashed == false }
        )
        let existingTitles = Set(((try? context.fetch(titleDescriptor)) ?? []).map(\.title))
        var newTitle = original.title + "-copy"
        var index = 2
        while existingTitles.contains(newTitle) {
            newTitle = "\(original.title)-copy\(index)"
            index += 1
        }

        let nodeDescriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in
                node.conversationId == convId && node.profileId == pid
            }
        )
        let sourceNodes = (try? context.fetch(nodeDescriptor)) ?? []

        var idMap: [String: String] = [:]
        idMap.reserveCapacity(sourceNodes.count)
        for node in sourceNodes { idMap[node.id] = UUID().uuidString }

        let copiedDirs = AttachmentStore.copyConversationAttachments(
            from: convId, to: newConvId, newTitle: newTitle, profileId: pid
        )

        for source in sourceNodes {
            let node = MessageNode(
                id: idMap[source.id] ?? UUID().uuidString,
                role: source.role,
                content: source.content,
                contentType: source.contentType,
                createTime: source.createTime,
                parentId: source.parentId.flatMap { idMap[$0] },
                childrenIds: source.childrenIds.compactMap { idMap[$0] },
                conversationId: newConvId,
                profileId: pid
            )
            node.isFavorite = source.isFavorite
            node.isPinned = source.isPinned
            node.pinnedAt = source.pinnedAt
            node.isTrashed = source.isTrashed
            node.trashedAt = source.trashedAt
            if let dirs = copiedDirs {
                node.segmentsData = AttachmentStore.rewriteSegmentRefs(
                    source.segmentsData, oldDir: dirs.oldDir, newDir: dirs.newDir
                )
            } else {
                node.segmentsData = source.segmentsData
            }
            node.ccMessageId = source.ccMessageId
            node.replyToId = source.replyToId.flatMap { idMap[$0] ?? $0 }
            node.ccEdited = source.ccEdited
            node.ccThinking = source.ccThinking
            node.usagePromptTokens = source.usagePromptTokens
            node.usageCompletionTokens = source.usageCompletionTokens
            node.usageCacheReadTokens = source.usageCacheReadTokens
            node.usageCacheWriteTokens = source.usageCacheWriteTokens
            node.usageCostUSD = source.usageCostUSD
            node.usageSavedUSD = source.usageSavedUSD
            node.imageDescsData = source.imageDescsData
            node.thinkingSummary = source.thinkingSummary
            node.toolSummariesData = source.toolSummariesData
            node.replyOutcome = source.replyOutcome
            node.finishReason = source.finishReason
            node.recallReceipt = source.recallReceipt?.remapped(from: convId, conversationId: newConvId, nodeIds: idMap)
            context.insert(node)
        }

        let rootId = sourceNodes.first(where: { $0.parentId == nil }).flatMap { idMap[$0.id] }
        let copy = Conversation(
            id: newConvId,
            title: newTitle,
            createTime: Date(),
            updateTime: Date(),
            currentNodeId: idMap[original.currentNodeId] ?? rootId ?? "",
            provider: original.provider,
            profileId: pid
        )
        copy.isFavorite = original.isFavorite
        copy.folderId = original.folderId
        copy.nodeCount = original.nodeCount
        copy.memoryEnabled = original.memoryEnabled
        copy.selectedModelId = original.selectedModelId
        copy.mcpServerIds = original.mcpServerIds
        copy.draftText = original.draftText
        copy.draftAttachmentsData = original.draftAttachmentsData
        copy.draftQuotePreview = original.draftQuotePreview
        copy.draftQuoteReplyTo = idMap[original.draftQuoteReplyTo] ?? ""
        copy.branchSelectionData = BranchSelection.remap(original.branchSelectionData) { idMap[$0] }
        copy.recallState = original.recallState.remapped(conversationId: newConvId, nodeIds: idMap)
        copy.displayMode = original.displayMode
        context.insert(copy)

        let favDescriptor = FetchDescriptor<FavoriteItem>(
            predicate: #Predicate<FavoriteItem> { item in
                item.conversationId == convId && item.profileId == pid
            }
        )
        for item in (try? context.fetch(favDescriptor)) ?? [] {
            let mappedNodeId: String?
            if let nid = item.nodeId {
                guard let mapped = idMap[nid] else { continue }
                mappedNodeId = mapped
            } else {
                mappedNodeId = nil
            }
            context.insert(FavoriteItem(
                nodeId: mappedNodeId,
                conversationId: newConvId,
                tagId: item.tagId,
                contentPreview: item.contentPreview,
                profileId: pid
            ))
        }

        try? context.save()
        return copy
    }

    // MARK: - Budget

    /// 发送后扣费：优先用响应里的真实 usage；没 usage 就用最近一次 pre-check 估的值保守扣。
    /// 每轮 usage 落盘到 assistant 节点（D1）。归一化：Anthropic 的 input_tokens 不含缓存读写 → 补成总 prompt；OAI 的 prompt_tokens 本来就含。
    func recordUsage(_ usage: TokenUsage?, on node: MessageNode, model: ProviderModel, providerManager: ProviderManager) {
        guard let usage, let provider = providerManager.provider(for: model) else { return }
        let read = usage.cacheReadTokens ?? 0
        let subscriptionRecord = provider.type == .chatgptOAuth ? providerRouter.lastUsageRecord : nil
        let matchingSubscriptionRecord = subscriptionRecord.flatMap { row in
            row.providerId == provider.id && row.model == model.modelId && row.messageNodeId == node.id && row.profileId == node.profileId ? row : nil
        }
        var record = usage.ledgerRecord ?? matchingSubscriptionRecord ?? UsageRecord(provider: provider, modelId: model.modelId, usage: usage,
            started: Date(), ended: Date(), status: .ok, context: UsageContext())
        if record.requestId == nil { record.requestId = UUID().uuidString }
        MainActor.assumeIsolated { UsageCostSettlement.shared.attach(record: record, node: node) }
        node.usageSavedUSD = BudgetCalculator.displaySavings(provider: provider, modelId: model.modelId, cacheReadTokens: read)
    }

    func commitBudgetSpend(providerManager: ProviderManager, model: ProviderModel, usage: TokenUsage?, recordTurn: Bool = true) {
        if recordTurn, let usage { lastTurnUsage = usage }
        guard let provider = providerManager.provider(for: model) else { return }
        let cost: Double
        if let usage {
            cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
        } else if pendingEstimatedCost > 0 {
            // 没 usage（流中断 / 某些 API 不回 usage）→ 按 pre-send 估算扣
            cost = pendingEstimatedCost // 未知账单金额仍保留保险闸的保守扣费。
        } else {
            return
        }
        providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage)
        pendingEstimatedCost = 0
    }

    /// pre-send 门控：超额返回 false（调用方 return）。失败会写 budgetBlockedMessage 让 UI 显示 alert。
    /// 成功（ok / warning）会把 estimate 存到 pendingEstimatedCost，发送完回填扣费兜底。
    func preCheckBudget(
        text: String,
        model: ProviderModel,
        profile: Profile,
        preset: Preset,
        providerManager: ProviderManager,
        path: [MessageNode]? = nil
    ) -> Bool {
        guard let provider = providerManager.provider(for: model) else { return true }
        let maxOut = OutputTokenCap.budgetEstimate(preset.sampling, modelId: model.modelId)
        // 粗估 input：system + 当前 path（已有上下文）+ 新消息
        // 系统提示词单一来源 = 楼层预设实例 main 槽（profile.systemPrompt 已不进组装链）
        var accumulated = ""
        let mainPrompt = preset.prompts.first(where: { $0.id == PromptSlot.mainId })?.content ?? ""
        if !mainPrompt.isEmpty { accumulated += mainPrompt + "\n" }
        // path：编辑重发传「原节点之前」——旧分支的后缀会被替换，不该算进这次（plan-edit-attachments H4）
        for node in path ?? currentPath where !node.content.isEmpty {
            accumulated += node.content + "\n"
        }
        accumulated += text
        let inputTok = HeuristicEstimator().estimate(accumulated)
        let estimated = BudgetCalculator.actualCost(
            provider: provider,
            modelId: model.modelId,
            usage: TokenUsage(inputTokens: inputTok, outputTokens: maxOut)
        )
        pendingEstimatedCost = estimated
        if BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: estimated) { return true }
        let gate = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated)
        switch gate {
        case .ok, .disabled, .warning:
            return true
        case .blocked(let spent, let budget):
            budgetBlockedMessage = Self.blockedMessage(providerName: provider.name, spent: spent, budget: budget)
            pendingEstimatedCost = 0
            return false
        }
    }

    /// Backend agent（memory extract / context summary 等）统一预算 gate。
    /// 返回 true = 被预算拦了，应该跳过这次 API 调用。
    func backendAgentBlockedByBudget(
        model: ProviderModel,
        messages: [(role: String, content: String)],
        systemPrompt: String?,
        providerManager: ProviderManager,
        assumedMaxOutput: Int = 1024
    ) -> Bool {
        guard let provider = providerManager.provider(for: model) else { return true }
        var accumulated = systemPrompt ?? ""
        for m in messages {
            accumulated += "\n" + m.content
        }
        let inputTok = HeuristicEstimator().estimate(accumulated)
        let estimated = BudgetCalculator.actualCost(
            provider: provider,
            modelId: model.modelId,
            usage: TokenUsage(inputTokens: inputTok, outputTokens: assumedMaxOutput)
        )
        if BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: estimated) { return false }
        let gate = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated)
        if case .blocked = gate { return true }
        return false
    }

    /// 友好文案：区分"没拨款（首次使用）"和"已用完"。
    private static func blockedMessage(providerName: String, spent: Double, budget: Double) -> String {
        if budget <= 0 {
            // 走到这里只可能是**用户明确把上限填成了 0**（没填过按默认 10 算，不会 <= 0）
            return """
            所有 API 共用的预算上限是 $0，所有调用都会被拦下。

            去「\(budgetSettingsPath)」填一个额度，或关掉「启用预算限额」开关。
            """
        }
        // 预算是全局总闸，不属于哪张卡（#092：以前写「「卡名」预算已用完」，指路的节名也不对）
        return String(
            format: "所有 API 共用的预算已用完：$%.2f / $%.2f（这次用的是「%@」）。\n\n去「%@」点「重置已用」，或调高上限。",
            spent, budget, providerName, budgetSettingsPath
        )
    }

    /// 和设置页实际叫法对齐：简洁版 / 完整版都叫「模型和API」，节名「预算（全局总闸）」
    private static var budgetSettingsPath: String {
        "设置 → 模型和API → 预算（全局总闸）"
    }
}

/// 检查器：这一轮为什么一个工具都不发（与 toolInjection 的过滤链一一对应）
enum ToolsAbsentReason {
    case cardNotFound, cardToolsOff, masterOff, ccBridge, localModel, noneEnabled
}

/// 检查器的一轮预览（CVM.previewTurn）：与实发同一个模型、同一份工具、同一条组装
struct TurnPreview {
    let model: ProviderModel
    let tools: [[String: Any]]?
    let toolsAbsentReason: ToolsAbsentReason?
    /// 收在「更多工具」里、这一轮可用的内建工具（#069；不在 tools 里）
    let tuckedTools: [String]
    /// 这一轮能调到的工具名（#093；nil = 不发工具），历史回放和实发同一步 offeredOnly
    let offeredTools: Set<String>?
    let segments: [TaggedSegment]
    let memoryHits: [InjectionHit]
    let ordered: [PromptMessage]
    let sampling: SamplingParams
    /// 卡库 ③-4：SendContext.inspectorLines（有效身份来源 / 退回原因 / 身份的书）
    let identity: [String]
    /// 这一轮按发送键会带上的记忆（与实发回执同一份 `MemoryDelivery`；只带数据，UI 另说）
    let delivery: RecallDelivery

    /// 实发同一个 provider 构造函数建的 body；nil = CC / 本机 / 不支持的卡。懒算：带图对话每次要 base64
    func requestBody(providerManager: ProviderManager) -> [String: Any]? {
        preview(providerManager).body
    }

    /// 检查器请求 tab：body 和「实发」说明共用这一次预览 resolve 的 compat
    func requestBodyAndPlacementNote(providerManager: ProviderManager) -> (body: [String: Any]?, placementNote: String?) {
        let p = preview(providerManager)
        guard let body = p.body else { return (nil, nil) }
        return (body, ProviderRouter.previewSystemPlacementNote(model: model, ordered: ordered,
                                                                providerManager: providerManager, compat: p.compat))
    }

    private func preview(_ providerManager: ProviderManager) -> (body: [String: Any]?, compat: ResolvedCompat?) {
        // 和实发 prepareRouterPayload 同一步：不发真工具块的 provider 退纯文字（#089 P0-b）
        var ordered = ToolReplay.orderedForProvider(providerManager.provider(for: model)?.type, self.ordered)
        if let offeredTools { ordered = ToolReplay.offeredOnly(ordered, offered: offeredTools) }
        let legacy = PromptMessage.legacyShape(ordered)
        return ProviderRouter.previewRequest(model: model, messages: legacy.messages, systemPrompt: legacy.systemPrompt,
                                             providerManager: providerManager, samplingParams: sampling,
                                             tools: tools, ordered: ordered)
    }
}
