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
    var selectedConversation: Conversation?
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
    #endif

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
            self.turnGeneration += 1   // 旧楼层的工具 handler 回来后作废
            self.clearAllSwiftDataRefs()
            // turn 状态随楼层清：旧 stream 的回调即使再来也只是 no-op，
            // 不清的话 assistantTurnInFlight 卡 true，新楼层永远发不出消息。
            // pendingSends 持有旧楼层 ModelContext ref，必须一起丢。
            self.assistantTurnInFlight = false
            self.activeAssistantNodeId = nil
            self.activeConversationId = nil
            self.pendingUserQuestion = nil   // 持有旧楼层 conversation/node/context ref，必须随楼层丢
            self.pendingCCQuestion = nil     // 旧楼层对话的题面，一并丢（hub pending 还在，重连会再来）
            self.pendingSends = []
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
        selectedConversation = nil
        currentPath = []
        timeDividerCache.reset()
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
        return (try? context.fetch(desc).first?.content) ?? ""
    }

    /// CC 主动发来的消息（无 pending 占位时）：作为一条新 assistant 消息插进 chatId 对应的会话。
    /// chatId == conversation.id。当前选中会话走 in-memory 路径即时刷新；非选中只持久化，下次打开加载。
    func insertProactiveAssistantMessage(chatId: String, content: String, fileData: Data? = nil, fileName: String? = nil, mime: String? = nil, isImage: Bool = false, ccMessageId: String? = nil, replyToId: String? = nil, callReply: CCCallReply? = nil, context: ModelContext) {
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == chatId })
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
            pendingEntranceNodeIds.insert(newId)
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
        if content.contains(AnniversaryIntentWriter.blockTag) {
            Task { @MainActor in
                AnniversaryIntentWriter.processChatIntents(nodeId: newId, context: context)
            }
        }
        // v4-1 §四：CC 楼层的上下文摘要（满 60 条 / 跨过 05:00），和 API 那条压缩分开挂（回复从哪条路落地分）；同一个对话 60 秒内只喊一次
        if MemoryFlags.contextSummaryEnabled && conversation.memoryEnabled {
            SessionCloseoutTrigger.shared.requestCC(conversationId: chatId, profileId: pid)
        }
    }

    // MARK: - 问问题 CC 桥（plan-问问题-cc桥）

    /// hub 推来 AskUserQuestion 题面帧 → 挂 pendingCC（切到该对话时 sheet 弹出）。
    /// 重连会重发 pending 帧：同 toolUseId 幂等；已有别的卡挂着 → 先到先得，后到的丢
    ///（hub pending 还在，下次重连再来）。已落过泡的（ccMessageId 查重）不再弹。
    @MainActor
    func presentCCAskUser(chatId: String, toolUseId: String, questions raw: [[String: Any]], context: ModelContext) {
        guard pendingCCQuestion?.toolUseId != toolUseId else { return }
        guard pendingUserQuestion == nil, pendingCCQuestion == nil else { return }
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == chatId })
        guard let conversation = try? context.fetch(convDesc).first else { return }   // 别的设备的 chat → 丢
        guard let questions = AskUserTool.parseCCQuestions(raw) else { return }
        if ccDedupContains(chatId: chatId, ccMessageId: "askuser:\(toolUseId)", pid: conversation.profileId, context: context) { return }
        pendingCCQuestion = PendingCCQuestion(
            chatId: chatId, toolUseId: toolUseId, questions: questions,
            collectedAnswers: Array(repeating: nil, count: questions.count)
        )
    }

    /// resolved 帧：收卡 + Q/A 落真实 user 气泡（唯一落泡来源——app 答/tmux 答/declined 同路）。
    /// dedup 用 ccMessageId="askuser:<toolUseId>" 走 proactive 同款三层防御。
    @MainActor
    func handleCCAskUserResolved(chatId: String, toolUseId: String, questions raw: [[String: Any]], answers: [String: String]?, context: ModelContext) {
        if pendingCCQuestion?.toolUseId == toolUseId { pendingCCQuestion = nil }
        guard let questions = AskUserTool.parseCCQuestions(raw) else { return }
        let content = questions.map { q in
            "Q: \(q.question)\nA: \(answers?[q.question] ?? AskUserTool.skippedAnswer)"
        }.joined(separator: "\n\n")
        insertCCUserMessage(chatId: chatId, content: content, ccMessageId: "askuser:\(toolUseId)", context: context)
    }

    /// stale 帧：问题已在别处回答/TUI 已死——收卡即可（真相由 resolved 帧稍后落）。
    @MainActor
    func handleCCAskUserStale(toolUseId: String) {
        guard pendingCCQuestion?.toolUseId == toolUseId else { return }
        pendingCCQuestion = nil
        transientNotice = TransientNotice("这个问题已经失效了")
    }

    /// CC 桥的 user 消息落地（Q/A 泡）：insertProactiveAssistantMessage 的 user 版——
    /// 同款 ccMessageId 三层查重 + 上树 + currentPath 同步，少了 unread/推送/意图块（用户自己的话）。
    @MainActor
    private func insertCCUserMessage(chatId: String, content: String, ccMessageId: String, context: ModelContext) {
        let convDesc = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == chatId })
        guard let conversation = try? context.fetch(convDesc).first else { return }
        let pid = conversation.profileId
        let isCurrentAndLoaded = (selectedConversation?.id == chatId && !isLoading)
        if isCurrentAndLoaded {
            if nodeMap.values.contains(where: { $0.ccMessageId == ccMessageId }) { return }
        } else if ccDedupContains(chatId: chatId, ccMessageId: ccMessageId, pid: pid, context: context) {
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
    func applyCCEdit(chatId: String, ccMessageId: String, content: String, streaming: Bool = false, context: ModelContext) {
        // 当前会话：内存里找 + 即时刷新。streaming = 逐字流式中间态（hub 每 150ms 一帧）：不算「编辑过」、不每帧滚动
        if selectedConversation?.id == chatId,
           let node = currentPath.first(where: { $0.ccMessageId == ccMessageId }) {
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
        if let node = (try? context.fetch(desc))?.first(where: { $0.ccMessageId == ccMessageId }) {
            node.content = content
            if !streaming { node.ccEdited = true }
            try? context.save()
        }
    }

    /// 思考链回传：按 ccMessageId 找节点写 ccThinking（查找逻辑同 applyCCEdit）。
    /// 精确锚找不到时兜底挂该会话最新 assistant 节点（盖 id 回调竞态/旧节点没 id 的保险）。
    /// 同值忽略（replay 幂等）。不滚动——thinking 晚到几秒，别打扰阅读。
    func applyCCThinking(chatId: String, ccMessageId: String, content: String, context: ModelContext) {
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

        branchSelection = BranchSelection.selecting(
            nodeId, in: branchSelection,
            parentOf: { [nodeMap] in nodeMap[$0]?.parentId },
            childCount: { [effectiveChildrenMap] in effectiveChildrenMap[$0]?.count ?? 0 })

        rebuildPath()
        persistBranchSelection()
        highlightedNodeId = nodeId
        pendingScrollNodeId = nodeId
    }

    /// 旧入口保留：搜索结果 / 外部跳转 用全量 reload（含 fetch）。
    func navigateToNode(nodeId: String, conversation: Conversation, context: ModelContext) {
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

        // 判断是否在主线
        let cid = conversation.id
        let pid = conversation.profileId
        let nodesDesc = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { $0.conversationId == cid && $0.profileId == pid }
        )
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
    var needsInitialLoad: Bool { selectedConversation != nil && currentPath.isEmpty && !isLoading }

    /// Build path for selected conversation (fetch + tree computation on background thread)
    /// - scrollTargetNodeId: 搜索跳转的临时浏览——显示路径改走这条，持久选择表不动
    func loadConversation(_ conversation: Conversation, context: ModelContext, scrollTargetNodeId: String? = nil) {
        if conversation.id != selectedConversation?.id { SessionCloseoutTrigger.shared.request() }   // 第三刀：切窗口时巡检（巡检在后台）
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
        selectedConversation = conversation
        #if os(macOS)
        // 点对话 = 回聊天。不能只靠 `onChange(selectedConversation)`——点回同一条 id 没变就不触发，
        // 主区域会一直卡在只读的编程会话详情上（09-15 她报的「聊天页根本输入框都没有」）
        Task { @MainActor in CodingSessionLibrary.shared.deactivate() }
        #endif
        // CC 入场弹泡：清零前抓未读快照（场景 B），入口重置集合防跨对话残留
        entranceUnreadSnapshot = conversation.unreadCount
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
        currentPath = []
        timeDividerCache.reset()   // 重开同一对话也重算（导入 / 恢复可能改过节点时间）
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { perfPathRevision += 1 }
        #endif
        branchSelection.removeAll()
        displayLeafId = nil
        bubbledBranches.removeAll()
        nodeMap.removeAll()
        cachedRootId = nil
        effectiveChildrenMap.removeAll()
        branchInfoMap.removeAll()

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
        #endif

        DispatchQueue.global(qos: .userInitiated).async {
            #if (DEBUG || PERF_BENCH) && os(iOS)
            if perfDelayMs > 0 { Thread.sleep(forTimeInterval: perfDelayMs / 1000) }
            #endif
            #if DEBUG
            if testDelay > 0 { Thread.sleep(forTimeInterval: testDelay) }
            let bgT0 = CFAbsoluteTimeGetCurrent()
            #endif
            let treeData = Self.buildTreeInBackground(convId: convId, profileId: convProfileId, currentNodeId: currentNodeId,
                                                      selection: selection, browseTargetId: scrollTargetNodeId, container: container)
            #if DEBUG
            let bgT1 = CFAbsoluteTimeGetCurrent()
            print(String(format: "[PERF] buildTreeInBackground=%.0fms nodes=%d", (bgT1 - bgT0) * 1000, treeData.allNodeIds.count))
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
                                              container: ModelContainer) -> TreeData {
        let bgContext = ModelContext(container)

        // Fetch all nodes for this conversation
        let descriptor = FetchDescriptor<MessageNode>(
            predicate: #Predicate<MessageNode> { node in node.conversationId == convId && node.profileId == profileId }
        )
        let nodes = (try? bgContext.fetch(descriptor)) ?? []

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
                if let found = try? bgContext.fetch(desc).first {
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
        if let nodes = try? context.fetch(descriptor) {
            nodeMap.reserveCapacity(nodes.count)
            for node in nodes { nodeMap[node.id] = node }
        }

        // Fetch ancestor nodes not in this conversation
        for nodeId in data.allNodeIds where nodeMap[nodeId] == nil {
            let nid = nodeId
            let nidProfileId = convProfileId
            let desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in node.id == nid && node.profileId == nidProfileId }
            )
            if let node = try? context.fetch(desc).first {
                nodeMap[node.id] = node
            }
        }

        // Apply pre-computed structures
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
        if entranceUnreadSnapshot > 0 {
            pendingEntranceNodeIds = Self.entranceNodeIds(
                path: currentPath.map { (role: $0.role, id: $0.id) },
                unread: entranceUnreadSnapshot,
                cap: 3
            )
            entranceUnreadSnapshot = 0
        }

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
        branchSelection[nodeId] = children[childIndex]
        rebuildPath()
        persistBranchSelection()
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
        try? conversation.modelContext?.save()
        if selectedConversation?.id == conversation.id {
            selectedConversation = nil
            currentPath = []
            timeDividerCache.reset()
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
        }

        // 附件一份存储：彻底删除时连同文件库附件目录一起清（软删/回收站不走这里）
        AttachmentStore.deleteConversationAttachments(conversationId: convId, profileId: convProfileId)
        // 只属于这个对话的加密值一起删（plan-secure-ask §5）
        SecretVault.deleteAll(conversationId: convId)

        #if os(iOS)
        PushIdentityWriter.removeConversation(chatId: convId)
        #endif

        ccDedupCache.removeValue(forKey: convId)   // 跟随 conversation 销毁清掉 cache 条目

        context.delete(conversation)
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
    var streamingText = ""

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
            #if os(iOS)
            ChatParagraphPrewarm.turnInFlight = assistantTurnInFlight   // perf L1 ① 闲置门：流式中不补段落视图池
            #endif
        }
    }

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
    }
    var pendingCCQuestion: PendingCCQuestion? = nil

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
        CCBridgeWebSocketClient.shared.sendAskUserAnswer(toolUseId: cc.toolUseId, answers: answers)
    }

    /// sheet X/拖拽提前关的出口。API=已答保留剩余跳过回灌；CC=整卡跳过（hub 发 Esc，TUI 语义所限）。
    @MainActor
    func dismissActiveAskCard() {
        if pendingUserQuestion != nil { resumeUserQuestion(); return }
        guard let cc = pendingCCQuestion else { return }
        pendingCCQuestion = nil
        CCBridgeWebSocketClient.shared.sendAskUserAnswer(toolUseId: cc.toolUseId, answers: nil, skip: true)
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
            toolTurns: pending.toolTurns + [ToolTurn(calls: pending.calls, results: results)],
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
    /// 连续几轮工具参数被输出上限截断（plan-output-token-cap 2-7）：到 2 就停，不空转到 8 轮
    private var toolTruncationStreak = 0
    /// 正文停在输出上限的回复（内存态，不落库；气泡「继续」由 page1 接）
    private(set) var outputLimitHitNodeIds: Set<String> = []
    /// in-flight 期间用户发的消息排队，turn 结束自动补发
    var pendingSends: [PendingSend] = []
    /// §13 待捎带箱（测试注入独立实例；产品用 shared）
    @ObservationIgnored private var cardEventOutboxOverride: ChatCardEventOutbox?
    @MainActor var cardEventOutbox: ChatCardEventOutbox {
        get { cardEventOutboxOverride ?? .shared }
        set { cardEventOutboxOverride = newValue }
    }
    /// §13 网页卡 mp.ask：往输入框追加一句（ChatInputBar 接手后清掉）
    var composerInsert: ComposerInsert?
    /// 表单卡提交即发（粟粟 10-03）：ChatInputBar 接手，只发这张卡
    var cardSendRequest: CardSendRequest?
    /// CC 收口即发（plan-跨对话排队）：发出后等回复中的对话 → 弹跳点等待泡。
    /// 纯 UI 状态不阻塞任何发送；insertProactiveAssistantMessage 落地时清，10 分钟兜底静默清。
    var ccWaitingSince: [String: Date] = [:]
    /// CC 回复落地时起标题要用（落地回调在 ContentView，那里刻意不持有 ProviderManager）；发 CC 时记一下
    @ObservationIgnored weak var ccTitleProviderManager: ProviderManager?
    /// cancel 时定位要写「（已停止）」闭合的节点
    private var activeAssistantNodeId: String?
    /// 正在回复的对话（计时器投递跨窗口判忙要读，故非 private）
    var activeConversationId: String?

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
            conversationId: conversationId
        ))
        clearQuoting()   // 引用已捕获进 pending，输入栏引用条清掉
    }

    /// ✕ 取消排队：移除并返回，UI 把内容写回输入框
    @MainActor
    func cancelPendingSend(id: UUID) -> PendingSend? {
        guard let idx = pendingSends.firstIndex(where: { $0.id == id }) else { return nil }
        return pendingSends.remove(at: idx)
    }

    /// turn 结束统一出口：清状态 + drain 队列。四个调用点：
    /// onComplete / onError / maxToolRounds / cancelAssistantTurn（regenerate、
    /// editAndResend 的 complete/error 也走这里）。
    /// turn 代际：stop / 切楼层 时 +1。工具循环的异步 handler 在 await 回来后对照它——
    /// 不等就会出现「用户已停止，旧 handler 却接着存结果并再请求模型一轮」（codex 评审阻塞 1）。
    private var turnGeneration = 0

    private func finishAssistantTurn(drainQueued: Bool = true) {
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
        recallCallsThisTurn = 0
        toolTruncationStreak = 0
        diceToolIssuedIds = []
        if drainQueued { drainPending() }
    }

    /// 每次只发一条；发出去的那条又会设 in-flight，剩下的排到下一次 turn 结束。
    /// 对话已切走的 pending 不发（防发错对话），写回原对话草稿字段。
    private func drainPending() {
        Task { @MainActor in
            while !self.pendingSends.isEmpty {
                let pending = self.pendingSends.removeFirst()
                guard let conversation = self.selectedConversation,
                      conversation.id == pending.conversationId else {
                    self.restoreToDraft(pending)
                    continue   // 这条写回草稿，继续看下一条
                }
                self.quotingPreview = pending.quotePreview
                self.quotingReplyTo = pending.quoteReplyTo
                let started = self.sendMessage(
                    pending.text, model: pending.model, profile: pending.profile,
                    preset: pending.preset, providerManager: pending.providerManager,
                    context: pending.context, attachments: pending.attachments
                )
                if started { return }   // 一条上路，后面的等下次
                // 被拦（如预算）→ 写回草稿，停止 drain，不静默丢
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
        if !pending.attachments.isEmpty,
           let data = try? JSONEncoder().encode(pending.attachments) {
            conv.draftAttachmentsData = data
        }
        try? pending.context.save()
    }

    /// stop 按钮：取消当前 turn。provider cancel 不回调 onComplete/onError
    /// （ChatService.swift cancel 只杀 task），所以闭合标记必须在这里写——
    /// 否则 placeholder 留空，下一轮 history 又是 user+user。
    /// 已执行的工具副作用（磁盘写入）不回滚。
    @MainActor
    func cancelAssistantTurn(context: ModelContext, drainQueued: Bool = true) {
        providerRouter.cancel()
        turnGeneration += 1   // 让正在 await 的工具 handler 作废：回来后不存结果、不递归下一轮
        pendingUserQuestion = nil   // 选择卡挂起中按 stop：丢弃问题，孤儿 toolUse 走渲染/历史降级
        // 审批卡挂着时按 stop：算拒绝这一次，工具循环醒来后按 turnGeneration 作废（粟粟 10-03）
        if let conv = activeConversationId ?? selectedConversation?.id { PermissionPromptCenter.shared.cancel(conversationId: conv) }
        // 正在跑的 run_command 一并杀树（工具循环不吃 Task 取消，网络层 cancel 管不到子进程）
        // 两端都要：iOS 后端杀的是 guest 进程组
        if let cid = activeConversationId { RunCommandTool.cancel(conversationId: cid) }
        if let id = activeAssistantNodeId, let node = nodeMap[id] {
            if let record = providerRouter.lastUsageRecord { UsageCostSettlement.shared.attach(record: record, node: node) }
            if var segs = node.segments, !segs.isEmpty {
                if !streamingText.isEmpty { segs.append(.text(streamingText)) }
                segs.append(.text("（已停止）"))
                node.setSegments(segs)
            }
            if node.content.isEmpty {
                node.content = streamingText.isEmpty ? "（已停止）" : streamingText
            }
            try? context.save()
        }
        streamingText = ""
        finishAssistantTurn(drainQueued: drainQueued)
    }
    /// Recent messages to send for memory extraction
    /// MV2: N=3 间隔下窗口扩到 7 = 覆盖 3 轮 + 4 条衔接（粟粟批"按推荐")
    private let memoryExtractWindow = 7
    /// MV2 提取间隔化：counter 跨对话共享（全局，粟粟批"按推荐"）
    private var extractRoundCounter: Int = 0
    private var hasExtractedEverInSession: Bool = false

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
        preset: Preset,
        excludingNodeId: String? = nil,
        context: ModelContext,
        globalEntries: [WorldBookEntry] = [],
        fileLibraryHint: String? = nil,
        cardGuideCompact: Bool = false
    ) -> (systemPrompt: String?, messages: [(role: String, content: String)], sampling: SamplingParams, imageMap: [String: [PendingChatAttachment]], recallHits: [InjectionHit], ordered: [PromptMessage]) {
        let composed = composePrompt(profile: profile, preset: preset, excludingNodeId: excludingNodeId, context: context,
                                     globalEntries: globalEntries, fileLibraryHint: fileLibraryHint, mode: .send,
                                     cardGuideCompact: cardGuideCompact)
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

    struct ComposedPrompt {
        let segments: [TaggedSegment]
        let memoryHits: [InjectionHit]
        let ordered: [PromptMessage]
        let identity: [String]
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
        cardGuideCompact: Bool = false
    ) -> ComposedPrompt {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("ConversationViewModel.composePrompt") : nil
        defer { if let airSpan { AirProbeRuntime.shared.finishedSection(airSpan) } }
        #endif
        // 取数 + 预算与记忆面板「下一轮会想起什么」预览同一个函数（预览 = 实发）
        let memoryInputs = MemoryInjector.roundInputs(profileId: profile.id,
                                                      conversationMemoryEnabled: selectedConversation?.memoryEnabled ?? true,
                                                      store: memoryStore, context: context)
        let memories = memoryInputs.memories
        let selfMemory = memoryInputs.selfMemory
        let archiveBudget = memoryInputs.archiveBudget
        // access 语义（SC-B1 刀3）：进候选池不再 +1——recall 真命中才强化（分发分支记），
        // 否则 hot 池全员每轮通胀、强化信号无区分度（paramecium"翻目录不算想起来"语义）
        // M2：缺向量的记忆后台补算（开关关/无缺口时零开销）
        if mode == .send, !memories.isEmpty { MemoryEmbeddingBackfill.run(memories: memories, context: context) }

        let history = AirTimedSection.run("composePrompt.history") {
            windowedHistory(excluding: excludingNodeId, depth: preset.sampling.contextDepth)
        }
        let apiMessages = history.messages
        var chatHistory = apiMessages.map { (role: $0.role, content: $0.content) }
        var historyNodeIds = apiMessages.map(\.id)
        // #089 P0-a：最后一条必须是 user。历史以 assistant 结尾 = 网页卡 /trigger 让 AI 接着说，或检查器预览时还没打字
        if chatHistory.last?.role == "assistant" {
            chatHistory.append((role: "user", content: mode == .preview ? Self.previewNextUserPlaceholder : Self.triggerNudge))
            historyNodeIds.append(Self.syntheticUserNodeId)
        }
        // v4-1 §六：和历史窗口原文重复的上下文摘要段 / 时间轴条目不注（判定用节点 id，就用这份历史，不另算）
        let windowIds = Set(apiMessages.map(\.id))

        // 查询当前楼层的世界书（过滤 conversation scope）
        // 卡库 ③-4：有效身份 + 有效书集合（楼层 / 对话 / 身份的书）和检查器同一次解析；profile 换成身份套上后的副本
        let sendContext = AirTimedSection.run("composePrompt.context") {
            SendContextResolver.resolve(profile: profile, conversation: selectedConversation, context: context, globalEntries: globalEntries)
        }
        let profile = sendContext.profile
        let currentConvId = selectedConversation?.id ?? ""
        let worldBooks = sendContext.worldBooks

        // 上下文总结开关（mem_content_summary，受 mem_master 连坐）：关 = 不注入。
        // v4-1：只注压缩段和第 0 段，收尾段不注；最后一条还在历史窗口里的段不注（纯函数，读盘和以前一样一次）
        var contextSegments: [SessionSegment] = []
        var contextSummary: String?
        if MemoryFlags.contextSummaryEnabled {
            var s = SessionSummaryStore.loadOrSeed(conversationId: currentConvId, profileId: profile.id, title: "")
            s.segments = SessionSummaryStore.injectableSegments(s.segments, windowIds: windowIds, windowStart: history.start)
            contextSegments = s.segments
            contextSummary = SessionSummaryStore.injectionText(s, fullCount: SessionCloseout.fullSegmentCount)
        }
        // M5 用户画像：开关开才注（天级更新，进缓存前缀）
        let userProfile = MemoryFlags.profileInjectionEnabled ? ProfileFileStore.load(profileId: profile.id)?.text : nil
        // M6 时间轴：开关开才注（最新一篇楼层日记，天级稳定）+ 快到的纪念日（plan-calendar §八，同样按天稳定）
        let timelineSlot = CalendarInjection.timelineSlot(profileId: profile.id, currentConversationId: currentConvId, windowIds: windowIds)
        let timeline = timelineSlot.text

        // 写作风格：选了 style 才传 styleContent;PromptAssembler 内部合并到 last user。
        // 历史轮不复读(因为只在出口拼一次,user node 存的 content 干净)。
        // ccBridge 路径稍后会 strip 掉 <style> 后缀(CC 是 exec relay 不需要写作风格)。
        let styleContent: String? = {
            guard let conv = selectedConversation, !conv.currentStyleId.isEmpty,
                  let s = StyleManager.shared.find(conv.currentStyleId), !s.content.isEmpty else { return nil }
            return s.content
        }()

        // 发语音条：注入段与文件库 hint 同槽（过 applyMacros，实发/检查器同路）。
        // 语音通话中让路：否则 AI 把内容写进 ```voice 块 → 通话朗读只读到清洗后的空正文（和通话打架）。
        let capabilityHint: String? = {
            let voiceHint = CallSession.activeSnapshot ? nil : VoicePromptInjector.hint(profile: profile)
            let parts = [fileLibraryHint, voiceHint].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }()

        // assembleOrdered 展开（= assembleTagged + orderedMessages）：检查器要带 template 的 tagged 段
        let healthSummary = AirTimedSection.run("composePrompt.health") {
            HealthLogStore.composedHealthSummary(context: context, profileId: profile.id, grants: permGrants(for: selectedConversation))
        }
        let tradingSummary = AirTimedSection.run("composePrompt.trading") {
            tradingSummaryForPrompt(context: context, profileId: profile.id)
        }
        let assembled = AirTimedSection.run("composePrompt.assemble") { PromptAssembler.assembleTagged(
            preset: preset,
            profile: profile,
            memories: memories,
            chatHistory: chatHistory,
            worldBooks: worldBooks,
            globalEntries: sendContext.globalEntries,
            contextSummary: contextSummary,
            userProfile: userProfile,
            timelineSummary: timeline,
            healthSummary: healthSummary,
            tradingSummary: tradingSummary,
            fileLibrary: capabilityHint,
            styleContent: styleContent,
            folderInstructions: folderInstructions(for: selectedConversation, context: context),
            volatileNote: CalendarInjection.todayJournalText(profileId: profile.id),
            statusNote: turnStatusNote(profileId: profile.id,
                                       library: fileLibraryHint != nil && PermissionCenter.capabilityEnabled(.fileLibrary)),
            historyNodeIds: historyNodeIds,
            regexScripts: regexScripts(profile: profile, preset: preset),
            selfMemory: (selfMemory?.text).flatMap { $0.isEmpty ? nil : $0 },
            memoryBudget: archiveBudget,
            cardGuideCompact: cardGuideCompact
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
        // 刀5：设置页「上一轮实际注入」只在真实组装路径记账（预览不记）
        if mode == .send {
            if ordered.last?.role == "assistant" {
                CacheDiagLog.shared.log("⚠️ 发出去的最后一条是 assistant（预设里的预填），新模型可能不认")
            }
            MemoryInjectionMeter.record(profileId: profile.id, hits: assembled.memoryHits, memories: memories,
                                        selfTokens: selfMemory?.tokens ?? 0,
                                        selfCount: (selfMemory?.fullCount ?? 0) + (selfMemory?.indexCount ?? 0),
                                        timelineKeys: MemoryInjectionMeter.keptTimelineEntries(timelineSlot.entries, in: assembled.segments)
                                            .map(MemoryInjectionMeter.key),
                                        contextKeys: assembled.segments.contains { $0.source == .contextSummary }
                                            ? contextSegments.map { MemoryInjectionMeter.key(conversationId: currentConvId, segment: $0) } : [])
        }
        return ComposedPrompt(segments: assembled.segments, memoryHits: assembled.memoryHits, ordered: ordered,
                              identity: sendContext.inspectorLines)
    }

    /// 检查器只读入口：此刻按发送键（除了新打的那条）模型会收到的全部。取模型 / 取工具 / 组装与实发同一套函数，
    /// 不写库、不钉模型、不弹 askOnce、不写 breadcrumb、不补向量。excludingNodeId 只给测试对齐「重新生成」用
    @MainActor
    func previewTurn(profile: Profile, preset: Preset, providerManager: ProviderManager, globalModelId: String?,
                     context: ModelContext, excludingNodeId: String? = nil) -> TurnPreview? {
        guard let conversation = selectedConversation else { return nil }
        let model = providerManager.resolveModel(conversationModelId: conversation.selectedModelId, globalFallbackId: globalModelId)
        // CC 实发不调 toolInjection、fileLibraryHint 传 nil（sendMessage / regenerate 的 CC 分支）
        let injection: (tools: [[String: Any]]?, systemHint: String, absentReason: ToolsAbsentReason?, tucked: [String]) =
            providerManager.provider(for: model)?.type == .ccBridge
            ? (nil, "", .ccBridge, [])
            : toolInjectionDetailed(for: model, providerManager: providerManager, conversation: conversation,
                                    profileId: conversation.profileId, silent: true)
        let composed = composePrompt(profile: profile, preset: preset, excludingNodeId: excludingNodeId, context: context,
                                     globalEntries: globalWorldBookEntries,
                                     fileLibraryHint: injection.systemHint.isEmpty ? nil : injection.systemHint, mode: .preview,
                                     cardGuideCompact: CardGuideTool.isOffered(in: injection.tools))
        return TurnPreview(model: model, tools: injection.tools, toolsAbsentReason: injection.absentReason, tuckedTools: injection.tucked,
                           segments: composed.segments, memoryHits: composed.memoryHits, ordered: composed.ordered,
                           sampling: StreamingPreference.apply(Self.withEffectiveEffort(preset.sampling, model: model, providerManager: providerManager)),
                           identity: composed.identity)
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
        messageNodeId: String
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
            return (assembled.messages, assembled.systemPrompt, assembled.sampling, headers, assembled.imageMap, assembled.ordered)
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
        if let rt = quotingReplyTo, !rt.isEmpty {
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

    /// 贵的一遍（只对留下的那些）：引用头、卡片事件、附件（从磁盘读图 / 文件）。
    /// 从后往前一条对一条，图片配额和「3 条之前的旧图换描述」都从末尾数——只喂窗口（全量的后缀）结果逐字节不变
    private func materializeAPIMessages(_ relevant: [(node: MessageNode, content: String)]) -> [APIMessage] {
        let sendImages = PermissionCenter.injectionAllowed(.images, grants: permGrants(for: selectedConversation))
        let maxImages = UserDefaults.standard.object(forKey: "maxImagesToModel") as? Int ?? 20

        // 从后往前收集最近 maxImages 张图片
        let transcribe = UserDefaults.standard.object(forKey: "imageTranscriptionEnabled") as? Bool ?? true
        var imageQuota = sendImages ? maxImages : 0
        var fromEnd = 0
        var result: [APIMessage] = []
        for (node, content) in relevant.reversed() {
            var content = content
            var images: [PendingChatAttachment] = []
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
    func windowedHistory(excluding excludeId: String? = nil, depth: Int) -> (messages: [APIMessage], start: Int) {
        let full = historyCandidates(excluding: excludeId)
        guard full.count > depth else { return (materializeAPIMessages(full), 0) }
        // 开关关时摘要不注入 → 锚定必须退滑动窗，否则窗外消息既无摘要又不在窗（信息丢失）
        let covered = MemoryFlags.contextSummaryEnabled ? selectedConversation.flatMap {
            ContextSummarizer.load(conversationId: $0.id, profileId: $0.profileId)?.coveredCount
        } : nil
        guard let start = Self.anchoredWindowStart(fullCount: full.count, covered: covered, depth: depth) else {
            if let covered, covered > 0 {
                CacheDiagLog.shared.log("📝 历史窗口: 锚定失效（全 \(full.count)/覆盖 \(covered)/深度 \(depth)），退回滑动窗")
            }
            return (materializeAPIMessages(Array(full.suffix(depth))), full.count - depth)
        }
        return (materializeAPIMessages(Array(full.dropFirst(start))), start)
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
        ""
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
        // 卡库 ⑧c：群聊只读归档不续聊
        guard let conversation = selectedConversation, !conversation.isReadOnlyArchive else { return false }

        // 草稿对话：首次发送时落库（此后才出现在 page0 列表）。放最前，覆盖斜杠/正常所有路径。
        commitDraftConversationIfNeeded(context: context)

        // CC 收口即发（plan-跨对话排队）：ccBridge 对话不进流式管线、不占全局 turn。
        let isCC = providerManager.provider(for: model)?.type == .ccBridge

        // Turn guard：上一轮 assistant/tool loop 未结束 → 排队，turn 结束自动补发。
        // 放在斜杠分支之前：斜杠命令也不许在 turn 中途插队建 user node（user+user 连排）。
        // ccBridge 只防**同对话**中途插队（并发改 currentPath）；别的对话在跑不拦——
        // CC 是异步信使不碰流式管线共享状态，跨对话串行没必要（research-跨对话排队）。
        if assistantTurnInFlight && (!isCC || activeConversationId == conversation.id) {
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

        // 所有 precheck 已过，本轮 turn 正式开始（user node 创建前设置，
        // 之后没有早退路径，不会卡死 true）。
        // ccBridge 不占 turn：发出即结束，回复走 proactive 异步落地。
        if !isCC {
            assistantTurnInFlight = true
            activeConversationId = conversation.id
        }
        BreadcrumbLog.shared.add("📤", "发送@「\(conversation.title)」（\(modelText.count)字）")

        // 1–2. 路径末尾建 user 节点（卡库第二批 B5 的 /send 共用 appendUserNode）
        let userNode = AirTimedSection.run("sendMessage.appendUserNode") {
            appendUserNode(content: modelText, contentType: parts.contentType, segments: parts.segments,
                           replyToId: quotingReplyTo, replyQuote: quotingPreview,
                           conversation: conversation, context: context)
        }
        let userNodeId = userNode.id

        // —— ccBridge 收口即发：到此为止，不建占位节点、不进流式管线（plan-跨对话排队）——
        // 组装照旧走 assemblePrompt + prepareRouterPayload（style 后缀/附件砍文/引用头全保留），
        // 终点从 runStreamingTurn 换成 WS 直发一帧。回复由 proactive 路径落地，
        // 按 conversation.currentNodeId 链 parent——所以 currentNodeId 必须指到这条 user。
        if isCC {
            commitSelection(to: userNodeId, conversation: conversation)
            conversation.updateTime = Date()
            markConversationDirty()
            // excludingNodeId 传 ""：没有占位节点要排除，刚建的 user 必须进组装（它就是要发的消息）
            let assembled = AirTimedSection.run("sendMessage.cc.assemble") {
                assemblePrompt(profile: profile, preset: preset, excludingNodeId: "", context: context, globalEntries: globalWorldBookEntries, fileLibraryHint: nil)
            }
            let payload = AirTimedSection.run("sendMessage.cc.payload") {
                prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: userNodeId)
            }
            AirTimedSection.run("sendMessage.cc.wsSend") {
                sendCCFireAndForget(payload: payload, model: model, conversation: conversation, profile: profile, providerManager: providerManager)
            }
            AirTimedSection.run("sendMessage.cc.save") { try? context.save() }
            clearQuoting()
            scrollToNodeId = userNodeId
            return true
        }

        // 3–6. 占位 assistant + 组装 / 发送 / 流式（卡库第二批 B5 的 /trigger 共用 startAssistantTurn，同一条管线）
        startAssistantTurn(after: userNode, scrollTo: userNodeId, clearsQuoting: true, model: model, profile: profile,
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

    /// 在 parent 下建占位 assistant，组装 → 发送 → 流式。调用方已占好 turn（assistantTurnInFlight / activeConversationId）
    @MainActor
    private func startAssistantTurn(after parent: MessageNode, scrollTo: String, clearsQuoting: Bool,
                                    model: ProviderModel, profile: Profile, preset: Preset,
                                    providerManager: ProviderManager, conversation: Conversation, context: ModelContext) {
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
        context.insert(assistantNode)

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
        Task { @MainActor in
            await self.resolveInjectionAsks(conversation: conversation, context: context)

            // 4. 工具注入（文件库 fs_* + MCP 远程工具，进组装链 + preview 共用）
            let injection = self.toolInjection(for: model, providerManager: providerManager, conversation: conversation, profileId: conversation.profileId)
            let fileHint = injection.systemHint.isEmpty ? nil : injection.systemHint

            // 5. Assemble prompt（注入段已进组装链，payload.systemPrompt 含「文件库」段）
            let assembled = self.assemblePrompt(profile: profile, preset: preset, excludingNodeId: assistantNodeId, context: context, globalEntries: self.globalWorldBookEntries, fileLibraryHint: fileHint, cardGuideCompact: CardGuideTool.isOffered(in: injection.tools))
            // 召回卡片：cc-bridge 发送会丢弃组装结果（只发 raw 文字），不写卡片数据免得撒谎
            if providerManager.provider(for: model)?.type != .ccBridge {
                assistantNode.setRecallHits(assembled.recallHits)
            }
            let payload = self.prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: assistantNodeId)

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
        guard !assistantTurnInFlight else { return false }      // 生成中不插 user（user+user 连排）
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
        guard !assistantTurnInFlight, let parent = currentPath.last else { return false }
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
        let askable: [PermissionDomain] = [.healthApple, .healthWeight, .healthMeds, .healthCycle, .healthIntimacy, .images]
        var grants = PermissionGrants(raw: conversation.permGrantsRaw)
        var changed = false
        for domain in askable where PermissionCenter.level(domain) == .askOnce && !grants.isResolved(domain) {
            let decision = await PermissionPromptCenter.shared.decide(domain)
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
        guard toolName != AskUserTool.toolName else { return .proceed(argumentsJSON) }   // 问问题工具自身永不被闸
        let domain = PermissionDomain.forTool(named: toolName)
        switch PermissionCenter.level(domain) {
        case .bypass:
            return .proceed(argumentsJSON)
        case .notAllowed:
            return .deny("permission_denied：用户未允许「\(domain.displayName)」。可以请用户到 设置→权限 调整。")
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
                let decision = await PermissionPromptCenter.shared.decide(
                    domain, detail: detail,
                    approval: .init(conversationId: conversation.id, toolName: toolName, argumentsJSON: argumentsJSON, conversationGrant: true))
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
                : .deny("permission_denied：用户本次未允许「\(domain.displayName)」。可以请用户到 设置→权限 调整。")
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
    static func skipsOffload(_ name: String) -> Bool {
        #if os(macOS)
        return CodingTools.names.contains(name)
        #else
        return false
        #endif
    }

    private static let maxToolRounds = 8
    private static let budgetSummaryMaxTokens = 512
    private static let toolTruncationStopText = "（连续 2 轮工具参数超过输出上限，已停止。可以在预设里调大 Max Tokens，或者让我分段写。）"

    static func toolTruncatedMessage(name: String, cap: Int) -> String {
        "\(name) 的参数超过了本轮输出上限（\(cap) tokens），写到一半被截断，未执行。请把内容拆小：先用 fs_write 写开头一部分，再用 fs_append 分几次追加剩下的；其他工具请缩短参数。"
    }
    enum TuckedInvoke { case notWrapped, invalid(String), unwrapped(ToolCallBlock) }

    /// tool_invoke 包的是「更多工具」里的内建工具（名字一字不差）→ 拆成真调用（同 id、保留截断标记）；
    /// 包的是别的（MCP、拼错的名字）→ notWrapped，照旧交给 handleMetaTool
    static func unwrapTuckedInvoke(_ call: ToolCallBlock) -> TuckedInvoke {
        guard call.name == MetaTools.invokeName,
              let outer = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any],
              let name = outer["name"] as? String, ToolRegistry.tuckedNames.contains(name) else { return .notWrapped }
        guard let args = outer["arguments"] as? [String: Any] else {
            return .invalid("tool_invoke 的 arguments 要是一个对象（没有参数就填 {}），没有执行。")
        }
        let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .unwrapped(ToolCallBlock(id: call.id, name: name, argumentsJSON: json, truncated: call.truncated))
    }

    /// 授权卡改过内层参数后，重新包回 tool_invoke 的参数形状
    static func rewrapInvoke(name: String, argumentsJSON: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let outer: [String: Any] = ["name": name, "arguments": args]
        return (try? JSONSerialization.data(withJSONObject: outer, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? argumentsJSON
    }

    static func toolUnavailableMessage(name: String) -> String {
        "\(name) 这个工具现在没开（设置里关着，这一轮没给你），这次做不了。如实告诉对方，不要再试。"
    }
    private static let budgetToolStopText = "（预算不足，已停止继续调用工具；已有工具结果已保留。）"
    private static let budgetSummaryInstruction = "预算已不足以继续调用工具。不要再调用任何工具，请基于已有工具结果直接给出简短总结。"
    /// MCP 工具数超过此值就 defer：不全量内联 schema，改用 3 个元工具（tool_search/inspect/invoke）让模型搜目录。
    /// fs_ 核心工具不受影响，始终内联。以后可换成 Cherry 的「占 context 比例」更精细的阈值。
    private static let mcpDeferThreshold = 16

    /// 执行前复查用的门控语境（#069），同 toolInjectionDetailed 的算法：家族看卡类型、元工具看 MCP 数量。
    /// nil = 这张卡这一轮根本不发工具（找不到卡 / 卡关了工具调用）——内建工具一律不执行
    @MainActor
    private func toolGate(for model: ProviderModel, providerManager: ProviderManager, profileId: String) -> ToolGateContext? {
        guard let provider = providerManager.provider(for: model), provider.toolsSupported != false else { return nil }
        let mcpCount = MCPProvider.shared.enabledTools(for: MCPProvider.shared.activeServerIds).count
        return ToolGateContext(family: provider.type == .anthropic ? .anthropic : .openAI,
                               deferMCP: mcpCount > Self.mcpDeferThreshold, profileId: profileId)
    }

    /// 兼容旧调用：只下发文件库工具。真实发送路径使用 toolInjection。
    @MainActor
    func fileLibraryInjection(for model: ProviderModel, providerManager: ProviderManager, profileId: String) -> (tools: [[String: Any]]?, systemHint: String) {
        toolInjection(for: model, providerManager: providerManager, conversation: nil, profileId: profileId)
    }

    /// 工具注入：该 model 下要下发的工具 + 要追加到 system 的提示。
    /// **实发（sendMessage）与上下文检查器（buildRequestJSON）共用此方法，杜绝预览/实发分叉。**
    @MainActor
    /// silent=true：预览路径用（cacheDashboard / previewTurn），不写 breadcrumb 和 probe 文件。
    /// 否则 UI 渲染每次都会调 toolInjection → add breadcrumb → @Observable 触发 view 重渲 → 又调 → 死循环。
    /// 实发路径（sendStreaming / regenerate / editAndResend）默认 silent=false 保持诊断日志。
    func toolInjection(for model: ProviderModel, providerManager: ProviderManager, conversation: Conversation?, profileId: String, silent: Bool = false) -> (tools: [[String: Any]]?, systemHint: String) {
        let result = toolInjectionDetailed(for: model, providerManager: providerManager, conversation: conversation, profileId: profileId, silent: silent)
        return (result.tools, result.systemHint)
    }

    /// toolInjection 本体；absentReason 只给检查器说清「为什么一个工具都不发」
    @MainActor
    private func toolInjectionDetailed(for model: ProviderModel, providerManager: ProviderManager, conversation: Conversation?, profileId: String, silent: Bool) -> (tools: [[String: Any]]?, systemHint: String, absentReason: ToolsAbsentReason?, tucked: [String]) {
        guard let provider = providerManager.provider(for: model) else { return (nil, "", .cardNotFound, []) }
        // 卡级「工具调用」开关（B 止血）：后端不带 function calling 的卡 = 不发 tools、不提工具（同 ccBridge 待遇）
        if provider.toolsSupported == false { return (nil, "", .cardToolsOff, []) }
        // F4 工具总开关（设置-MCP）：关闭 = 请求不带 tools 字段，模型纯对话。
        // 场景：切到不受信任的中转站时，防模型按上下文惯性调工具把命令/结果明文暴露。
        guard PermissionCenter.capabilityEnabled(.toolsMaster) else { return (nil, "", .masterOff, []) }
        // MCP 全局生效：enabled 的 server 对所有对话可用，不再按对话隔离（conversation 参数已不参与 MCP 选取）。
        let mcpServerIds = MCPProvider.shared.activeServerIds
        // 文件库总开关：关掉后不下发 fs_* 工具、不注入文件库说明（设置→文件库）。
        let fileLibraryOn = PermissionCenter.capabilityEnabled(.fileLibrary)
        // MCP 工具太多就 defer：换成 3 个元工具让模型搜目录，省得工具海淹没模型。fs_ 不受影响。
        let mcpCatalog = MCPProvider.shared.enabledTools(for: mcpServerIds)
        let deferMCP = mcpCatalog.count > Self.mcpDeferThreshold
        // ccBridge 上游自带工具，这里不下发
        // 本机模型也不下发：工具 schema 太大，小模型扛不住（plan-小芽-v3 §1）
        if provider.type == .ccBridge { return (nil, "", .ccBridge, []) }
        if provider.type == .localMLX { return (nil, "", .localModel, []) }
        // chatgptOAuth 也用 OpenAI Chat Completions 风格的 tools；
        // ChatGPTOAuthProvider.buildRequestBody 内部会 map 成 Responses API 平铺格式
        let family: ToolGateContext.Family = provider.type == .anthropic ? .anthropic : .openAI
        let gate = ToolGateContext(family: family, deferMCP: deferMCP, profileId: profileId)

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
        if family == .anthropic, PermissionCenter.capabilityEnabled(.webSearch) {
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
        guard !tools.isEmpty else { return (nil, "", .noneEnabled, []) }
        var hint = fileLibraryOn ? fileLibrarySystemHint(profileId: profileId) : ""
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
                + tuckedDefs.map { "- \($0.name) — \(ToolRegistry.tuckedBlurbs[$0.name] ?? "")" }.joined(separator: "\n")
        }
        // 设备工具说明段（有任一设备工具可用才加，前缀稳定）
        if builtinNames.contains(where: { DeviceToolDispatcher.handles($0) }) {
            if !hint.isEmpty { hint += "\n\n" }
            hint += DeviceToolDispatcher.systemHint
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
        if !searchTools.isEmpty, family == .openAI {
            if !hint.isEmpty { hint += "\n\n" }
            let assistantName = (UserDefaults.standard.string(forKey: "assistantName") ?? "").trimmingCharacters(in: .whitespaces)
            hint += WebSearchToolService.systemPrompt(assistantName: assistantName)
        }
        // #089 P1-c：能力说明按这一轮真实下发的工具生成（人设 / 预设里写的「某某暂时关闭」和这里冲突时以这里为准）。工具不变这段字就不变
        if !hint.isEmpty { hint += "\n\n" }
        hint += Self.capabilitySection(tools)
        return (tools, hint, nil, tuckedDefs.map(\.name))
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
            let inner = args["arguments"] as? [String: Any] ?? [:]
            let innerJSON = (try? JSONSerialization.data(withJSONObject: inner))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
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
    func fileLibrarySystemHint(profileId: String) -> String {
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
        let template = (custom?.isEmpty == false) ? custom! : FileLibraryTools.defaultInjectionTemplate
        let filled = template
            .replacingOccurrences(of: "{{files}}", with: listing)
            .replacingOccurrences(of: "{{fileContents}}", with: contentsSection)
        // 记忆树提示是固定文本（不列文件名）——前缀稳定，具体内容让模型 fs_list/fs_read 按需拉
        // 「正在读」挪进〔状态〕（#089 P1：章节号每读一章就变）
        let topicBox = ""
        let healthLog = healthLogHint(profileId: profileId)
        let tradeLog = ""
        let anniversary = AnniversaryIntentWriter.hint(profileId: profileId)
        // #069：fs_* 对 memory/ 只读，但 self 记忆和资料卡有专用写入口——别再说整棵树「系统生成、只读」
        let memoryTreeHint = SelfMemoryTool.enabled
            ? "记忆树：memory/ 下是楼层记忆（上下文摘要、窗口总结、时间轴、心声等），fs_* 工具对它只读，可用 fs_read / fs_search 查阅；其中 memory/self/ 是你自己的记忆，改它用 remember / edit_memory / forget_memory，资料卡用 update_profile_card 改。"
            : "记忆树：memory/ 下是楼层记忆（上下文摘要、窗口总结、时间轴、心声等），fs_* 工具对它只读，可用 fs_read / fs_search 查阅；资料卡用 update_profile_card 改。"
        return "<文件库>\n\(filled)\(topicBox)\(healthLog)\(tradeLog)\(anniversary)\n\(memoryTreeHint)\(CCMemorySync.promptHint(profileId: profileId))过长的工具结果会存档在 tool-results/（只读），结果里给了路径时用 fs_read(path, offset, limit) 分段取回。\n</文件库>"
    }


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


    /// 健康手账约定段（```health-log 意向协议，plan-health-chat-entry）：
    /// 闸+域双守卫——读闸关 = 不教 AI 写（语义一致零新开关）；域空 = 零污染。
    private func healthLogHint(profileId: String) -> String {
        guard let ctx = selectedConversation?.modelContext else { return "" }
        let weightOn = HealthLogStore.weightGateEnabled
            && !HealthLogStore.fetchRecentWeights(context: ctx, profileId: profileId, limit: 1).isEmpty
        let meds = HealthLogStore.medsGateEnabled
            ? HealthLogStore.fetchActiveMeds(context: ctx, profileId: profileId) : []
        // cycle/intimacy 只看闸不看域：敏感闸手动开 = 明确要用，教 AI 记第一笔有价值
        let cycleOn = HealthLogStore.cycleGateEnabled
        let intimacyOn = HealthLogStore.intimacyGateEnabled
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
    static func capabilitySection(_ tools: [[String: Any]]) -> String {
        let lines = tools.compactMap { tool -> String? in
            let fn = tool["function"] as? [String: Any]
            guard let name = (tool["name"] as? String) ?? (fn?["name"] as? String), !name.isEmpty else { return nil }
            let desc = (tool["description"] as? String) ?? (fn?["description"] as? String) ?? ""
            if desc.isEmpty { return tool["type"] != nil ? "- \(name)（服务端执行）" : "- \(name)" }
            let first = desc.split(whereSeparator: { "。\n".contains($0) }).first.map(String.init) ?? desc
            return "- \(name) — \(first.count > 60 ? String(first.prefix(60)) + "…" : first)"
        }
        return "〔当前能用的工具〕这一轮工具清单里实际有这些（人设或预设里关于哪些工具开着、关着的说法和这里冲突时，以这里为准；〔更多工具〕里列的也能用）：\n"
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
        guard HealthLogStore.medsGateEnabled, let ctx = selectedConversation?.modelContext else { return nil }
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

    private static func toolTurnsEstimateText(_ toolTurns: [ToolTurn]) -> String {
        toolTurns.flatMap { turn in
            turn.calls.map { "tool_call \($0.id) \($0.name) \($0.argumentsJSON)" }
                + turn.results.map { "tool_result \($0.toolUseId) \($0.text)" }
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
        guard let lastTurn = toolTurns.last, !lastTurn.results.isEmpty else { return toolTurns }
        var turns = toolTurns
        var results = lastTurn.results
        let lastResult = results.removeLast()
        results.append(ToolResultBlock(
            toolUseId: lastResult.toolUseId,
            text: lastResult.text + "\n\n" + budgetSummaryInstruction,
            isError: lastResult.isError
        ))
        turns[turns.count - 1] = ToolTurn(calls: lastTurn.calls, results: results)
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

        let summaryTurns = Self.addingBudgetSummaryInstruction(to: toolTurns)
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
                let fullText = self.applyInputRegex(streamedText, role: "assistant", profile: profile, preset: preset)
                if let existing = assistantNode.segments, !existing.isEmpty {
                    var segs = existing
                    if !fullText.isEmpty { segs.append(.text(fullText)) }
                    assistantNode.setSegments(segs)
                }
                assistantNode.content = fullText
                RequestBodyDiag.checkReply(ChatCardIndex.visibleText(content: fullText, segments: assistantNode.segments),
                                           segments: assistantNode.segments)
                // Anthropic server-side web search 收尾——把流式累积的 sources 落到 message
                // onComplete 总是在 main thread 调（DispatchQueue.main.async），但闭包没 @MainActor 标注
                let sources = MainActor.assumeIsolated { self.providerRouter.currentWebSources }
                if !sources.isEmpty { assistantNode.setWebSources(sources) }
                if self.providerRouter.lastReplyHitOutputLimit {
                    self.outputLimitHitNodeIds.insert(assistantNodeId)
                    BreadcrumbLog.shared.add("✂️", "已达输出上限 \(self.providerRouter.lastRequestedMaxTokens ?? 0)")
                }
                streamingText = ""
                conversation.nodeCount = currentPath.filter {
                    ($0.role == "user" || $0.role == "assistant") && $0.hasDisplayableContent
                }.count
                if conversation.title == ConversationTitler.placeholderTitle {
                    let firstUserMsg = currentPath.first(where: { $0.role == "user" && !$0.content.isEmpty })?.content ?? ""
                    if !firstUserMsg.isEmpty {
                        MainActor.assumeIsolated {
                            ConversationTitler.autoTitle(conversation, firstUser: firstUserMsg, firstAssistant: fullText,
                                                         providerManager: providerManager)
                        }
                        markConversationDirty()
                    }
                }
                self.recordUsage(usage, on: assistantNode, model: model, providerManager: providerManager)
                try? context.save()
                // 回复写回发起时的节点；用户中途切了支就不滚过去（不把她拉回原分支，③b）
                if currentPath.contains(where: { $0.id == assistantNodeId }) { scrollToNodeId = assistantNodeId }
                BreadcrumbLog.shared.add("✅", "回复完成 in \(usage?.inputTokens ?? 0) / out \(usage?.outputTokens ?? 0) tok")
                self.commitBudgetSpend(providerManager: providerManager, model: model, usage: usage)
                if MemoryFlags.masterEnabled && conversation.memoryEnabled {
                    // 第二刀 A2：人设 = systemPrompt + 角色描述，作为提取时的「你是谁」；称呼用楼层真名
                    let persona = [profile.systemPrompt, profile.characterDescription]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    self.extractMemoriesIfNeeded(profileId: profile.id, conversationId: conversation.id, systemPrompt: persona,
                                                 names: MemoryExtractor.Names(userName: profile.userName, assistantName: profile.assistantName),
                                                 model: model, providerManager: providerManager, context: context)
                    self.dreamIfNeeded(profileId: profile.id, model: model, providerManager: providerManager, context: context)
                }
                self.transcribeImagesIfNeeded(model: model, providerManager: providerManager, context: context)
                self.triggerContextSummaryIfNeeded(
                    conversationId: conversation.id,
                    conversationTitle: conversation.title,
                    profile: profile,
                    contextDepth: preset.sampling.contextDepth,
                    model: model, providerManager: providerManager
                )
                SessionCloseoutTrigger.shared.request()   // 第三刀：别的窗口静默够了就收尾
                self.finishAssistantTurn()   // onComplete 只在最终无工具轮触发（与 onToolCalls 互斥）
            },
            onError: { [weak self] error in
                guard let self else { return }
                if let record = self.providerRouter.lastUsageRecord {
                    MainActor.assumeIsolated { UsageCostSettlement.shared.attach(record: record, node: assistantNode) }
                }
                BreadcrumbLog.shared.add("⚠️", "出错：\(error.prefix(120))")
                // Phase 4 流式重写 Contract 5：保 partial post-tool 文本（不丢已生成内容）
                // 跟 cancelAssistantTurn (line 1363-1380) 行为对齐
                if var segs = assistantNode.segments, !segs.isEmpty {
                    if !streamingText.isEmpty { segs.append(.text(streamingText)) }
                    segs.append(.text("⚠️ \(error)"))
                    assistantNode.setSegments(segs)
                } else if streamingText.isEmpty {
                    assistantNode.content = "⚠️ \(error)"
                } else {
                    // 非 segmented 且有 partial → 保 partial 不覆盖
                    assistantNode.content = streamingText + "\n\n⚠️ \(error)"
                }
                streamingText = ""
                self.finishAssistantTurn()
            },
            onToolCalls: { [weak self] calls, usage in
                guard let self else { return }
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
                    if !streamingText.isEmpty { segs.append(.text(streamingText)) }
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
                    guard round < Self.maxToolRounds else {
                        segs.append(.text("（工具调用达到上限 \(Self.maxToolRounds) 轮，已停止）"))
                        assistantNode.setSegments(segs)
                        assistantNode.contentType = "segmented"
                        if assistantNode.content.isEmpty {
                            assistantNode.content = "（工具调用达到上限 \(Self.maxToolRounds) 轮，已停止）"
                        }
                        try? context.save()
                        self.finishAssistantTurn()
                        return
                    }
                    // 第一轮从新开始（防上一个 turn 没走收口留下的旧记录）；之后几轮接着记
                    var activity = (round == 0 ? nil : self.turnActivities[conversation.id]) ?? TurnActivity(maxRounds: Self.maxToolRounds)
                    activity.startRound(round + 1)
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
                    let gate = self.toolGate(for: model, providerManager: providerManager, profileId: profileId)

                    for call in calls {
                        var call = call   // 审批卡上改过命令时换参数
                        guard gen == self.turnGeneration else { return }   // 用户已停止/切楼层：剩下的调用不跑
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
                        switch Self.unwrapTuckedInvoke(call) {
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
                        if let bad = ToolCallPreflight.check(
                            name: call.name, argumentsJSON: call.argumentsJSON,
                            required: ToolCallPreflight.requiredFields(for: call.name, mcpServerIds: mcpServerIds)
                        ) {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "参数错误", iconName: "exclamationmark.triangle"))
                            segs.append(.toolResult(toolUseId: call.id, text: bad.message, isError: true, integrationName: "参数错误"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: bad.message, isError: true))
                            continue
                        }
                        // 执行前复查（#069）：这一轮没下发的内建工具（开关关着），照着历史直接叫也不执行
                        let unavailable = gate.map { ToolRegistry.availability(of: call.name, $0) == false }
                            ?? ToolRegistry.all.contains { $0.definition.name == call.name }
                        if unavailable {
                            let msg = Self.toolUnavailableMessage(name: call.name)
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "未开启", iconName: "nosign"))
                            segs.append(.toolResult(toolUseId: call.id, text: msg, isError: true, integrationName: "未开启"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: msg, isError: true))
                            continue
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
                        guard gen == self.turnGeneration else { return }   // 等审批时被停止 / 切楼层
                        #if os(macOS)
                        // 编程会话 AI 工具（W-N N5）：精确四名（不按前缀）；只读，后台新开只读连接执行
                        if CodingTools.names.contains(call.name) {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "编程会话", iconName: "terminal"))
                            let r = await CodingSessionLibrary.shared.runCodingTool(name: call.name, argumentsJSON: call.argumentsJSON)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "编程会话"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                            continue
                        }
                        #endif
                        if MetaTools.names.contains(call.name) {
                            let m = await handleMetaTool(call, mcpServerIds: mcpServerIds, conversationId: conversation.id,
                                                         builtins: gate.map { ToolRegistry.tuckedDefinitions($0) } ?? [])
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: m.integrationName, iconName: "magnifyingglass"))
                            #if DEBUG
                            print("[Meta] \(call.name) → isError=\(m.isError): \(m.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: m.text, isError: m.isError, integrationName: m.integrationName))
                            results.append(ToolResultBlock(toolUseId: call.id, text: m.text, isError: m.isError))
                        } else if call.name.hasPrefix("fs_") {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: nil, iconName: nil))
                            // 修全局卡顿：fs_list / fs_search 要枚举整库（search 还要读每个文件），挪到后台跑；写类工具照旧
                            let r: FileLibraryTools.Result
                            if ["fs_list", "fs_search"].contains(call.name) {
                                let name = call.name, json = call.argumentsJSON, pid = profileId
                                r = await Task.detached(priority: .userInitiated) {
                                    FileLibraryTools.execute(name: name, inputJSON: json, profileId: pid)
                                }.value
                            } else {
                                r = MainThreadIO.tolerated("#033 AI 文件工具主线程执行") {
                                    FileLibraryTools.execute(name: call.name, inputJSON: call.argumentsJSON, profileId: profileId)
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
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "骰子", iconName: "dice"))
                            var rng = SystemRandomNumberGenerator()
                            let r = DiceTool.execute(inputJSON: call.argumentsJSON, using: &rng,
                                                     takenIds: Set(cardIndex.keys).union(diceToolIssuedIds))
                            if !r.isError, let id = ChatCardExtractor.cards(in: r.text).first?.id {
                                diceToolIssuedIds.insert(id)
                            }
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "骰子"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == CardGuideTool.toolName {
                            // 卡片写法用到再查（粟粟 10-03）：系统提示里只有目录
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "卡片说明", iconName: "rectangle.stack"))
                            let r = CardGuideTool.execute(inputJSON: call.argumentsJSON)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "卡片说明"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == ProfileCardTool.toolName {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "资料卡", iconName: "person.crop.circle"))
                            let r = ProfileCardTool.execute(inputJSON: call.argumentsJSON, profileId: profileId)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "资料卡"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == TwitterAITool.toolName {
                            // 本地推特：AI 的主号名字头像跟楼层 AI 资料同步（头像同其它地方：assistantAvatar ?? cover）
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "推特", iconName: "bird"))
                            let r = TwitterAITool.execute(inputJSON: call.argumentsJSON, profileId: profileId,
                                                          aiName: profile.assistantName,
                                                          aiAvatar: profile.assistantAvatarData ?? profile.coverImageData,
                                                          context: context)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "推特"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == InnerVoice.toolName {
                            // v2c 心声：当轮立即回执让对话继续；第二跳后台生成+落盘
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "心声", iconName: "heart"))
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
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "记忆", iconName: "bookmark"))
                            let r = conversation.memoryEnabled
                                ? SelfMemoryTool.execute(name: call.name, inputJSON: call.argumentsJSON, profileId: profileId, conversationId: conversation.id)
                                : SelfMemoryTool.Result(text: "这场对话关了记忆参与，不能写记忆", isError: true)
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "记忆"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == RecallTool.toolName {
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "回忆", iconName: "clock.arrow.circlepath"))
                            // 连环 recall 熔断（粟粟实测：宽查询翻页式 5+ 连调爆上下文）
                            recallCallsThisTurn += 1
                            guard recallCallsThisTurn <= RecallTool.maxCallsPerTurn else {
                                let msg = "recall 本轮已调用 \(RecallTool.maxCallsPerTurn) 次。结果太多说明查询太宽——请基于已有结果回答；还不够就先和用户确认具体主题，下一轮再查。"
                                segs.append(.toolResult(toolUseId: call.id, text: msg, isError: true, integrationName: "回忆"))
                                results.append(ToolResultBlock(toolUseId: call.id, text: msg, isError: true))
                                continue
                            }
                            let r = await RecallTool.execute(
                                inputJSON: call.argumentsJSON,
                                profileId: profileId,
                                currentConversationId: conversation.id,
                                userName: profile.userName.isEmpty ? "用户" : profile.userName,
                                assistantName: profile.assistantName.isEmpty ? "AI" : profile.assistantName,
                                container: context.container
                            )
                            // 刀3 语义：recall 真命中的记忆才强化（注入候选池不再 +1）
                            if !r.hitMemoryIds.isEmpty { try? self.memoryStore.recordAccess(ids: r.hitMemoryIds, context: context) }
                            #if DEBUG
                            print("[Recall] → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "回忆"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == WebSearchToolService.toolName {
                            // client-side 联网搜索：当前选中的 backend 跑一遍 + 给 items 加 id/index 后回灌
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "联网搜索", iconName: "globe"))
                            let r = await WebSearchToolService.execute(inputJSON: call.argumentsJSON)
                            #if DEBUG
                            print("[WebSearch] → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "联网搜索"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if call.name == AskUserTool.toolName {
                            // 问问题：不立即执行——循环收尾存 pending 暂停，等用户点选（resumeUserQuestion 恢复）
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "问问题", iconName: "questionmark.circle"))
                            if let questions = AskUserTool.parse(inputJSON: call.argumentsJSON) {
                                askItems.append(.init(call: call, questions: questions))
                            } else {
                                segs.append(.toolResult(toolUseId: call.id, text: AskUserTool.invalidArgsMessage, isError: true, integrationName: "问问题"))
                                results.append(ToolResultBlock(toolUseId: call.id, text: AskUserTool.invalidArgsMessage, isError: true))
                            }
                        } else if call.name == BrowseURLTool.toolName {
                            // 内置浏览器读 URL → Markdown 全文（v2 Phase 1）
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "网页阅读", iconName: "doc.text.magnifyingglass"))
                            let r = await BrowseURLTool.execute(inputJSON: call.argumentsJSON)
                            #if DEBUG
                            print("[BrowseURL] → isError=\(r.isError): \(r.text.prefix(120))")
                            #endif
                            segs.append(.toolResult(toolUseId: call.id, text: r.text, isError: r.isError, integrationName: "网页阅读"))
                            results.append(ToolResultBlock(toolUseId: call.id, text: r.text, isError: r.isError))
                        } else if DeviceToolDispatcher.handles(call.name) {
                            // 设备工具（plan-设备工具）：权限闸已在循环头判过；dispatcher 自带 required 预检
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: "设备", iconName: "iphone"))
                            let r: (text: String, isError: Bool)
                            if call.name == RunCommandTool.toolName {
                                // 加密值只换 run_command；「运行」面板登记占位版命令
                                r = await runWithSecrets(toolName: call.name, argumentsJSON: call.argumentsJSON, conversationId: conversation.id) { json in
                                    let shown = json == call.argumentsJSON ? nil : DeviceToolIO.str(DeviceToolIO.args(call.argumentsJSON), "command")
                                    let e = await DeviceToolDispatcher.execute(name: call.name, inputJSON: json, profileId: profileId, conversationId: conversation.id, monitorCommand: shown)
                                    return (e.text, e.isError)
                                }
                            } else {
                                let e = await DeviceToolDispatcher.execute(name: call.name, inputJSON: call.argumentsJSON, profileId: profileId, conversationId: conversation.id)
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
                            segs.append(.toolUse(id: call.id, name: call.name, inputJSON: call.argumentsJSON, integrationName: serverName ?? "MCP", iconName: "network"))
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
                        if let si = segs.lastIndex(where: { if case .toolResult(let id, _, _, _) = $0 { return id == call.id }; return false }),
                           case .toolResult(_, _, let isErr, let integ) = segs[si] {
                            segs[si] = .toolResult(toolUseId: call.id, text: o.text, isError: isErr, integrationName: integ)
                        }
                    }
                    // 工具都跑完了，但 turn 已被 stop / 切楼层作废：不存结果、不递归再请求模型
                    // （cancelAssistantTurn 已给节点追加「（已停止）」并 finish）
                    guard gen == self.turnGeneration else { return }
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
                            tools: tools, toolTurns: toolTurns, round: round,
                            calls: sentCalls, otherResults: results
                        )
                        return
                    }

                    self.continueToolLoop(
                        payload: payload, systemPrompt: systemPrompt,
                        model: model, providerManager: providerManager,
                        conversation: conversation, assistantNode: assistantNode, assistantNodeId: assistantNodeId,
                        profile: profile, preset: preset, context: context,
                        tools: tools, toolTurns: toolTurns + [ToolTurn(calls: sentCalls, results: results)], round: round + 1
                    )
                }
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
        let ws = CCBridgeWebSocketClient.shared
        // 冷启动兜底：ContentView 启动时已 connect，这里补一手（沿旧 CCBridgeProvider 语义）。
        // 已经有候选地址（内嵌 hub 的端口 / 扫码的 LAN+Tailscale）就只催它现在重连：provider.baseURL 默认还是 7890，
        // 拿它覆盖会把断线中的 App 连去错的 hub（astra 实现审 #4）。从没连过才走 provider 地址。
        if !ws.isConnected {
            if ws.hasCandidates {
                // 正在握手的那次别掐：掐了重来只会更晚连上（旧 connect 同目标时也是不动在途连接）
                if !ws.isConnecting { ws.reconnectNow() }
            } else if let provider = providerManager.provider(for: model), let url = URL(string: provider.baseURL) {
                let key = providerManager.apiKey(for: provider.id) ?? ""
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
        // 等待泡（纯 UI 不阻塞）：回复落地时清；10 分钟没等到就静默收掉（对齐旧 grace 时长，
        // 不弹错误——hub replay 会把迟到的回复兜回来）
        ccTitleProviderManager = providerManager
        let convId = conversation.id
        let stamp = Date()
        ccWaitingSince[convId] = stamp
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
        CCBridgeWebSocketClient.shared.sendCommand(text, session: sessionName) { result in
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
                    content: "⚠️ 命令发送失败：\(err.reason)",
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

    /// AUDN 记忆提取：每轮对话后异步调用便宜模型提取/更新/删除记忆
    private func extractMemoriesIfNeeded(profileId: String, conversationId: String, systemPrompt: String, names: MemoryExtractor.Names, model: ProviderModel, providerManager: ProviderManager, context: ModelContext) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("memoryExtract"); return }   // 测量角色旁路早退（perf P0 §3.2）
        #endif
        guard !profileId.isEmpty, MemoryFlags.factsEnabled else { return }

        // CR-4：agent 消息（自主读书的读后感等）不进提取窗口——AI 的话不该变成"关于粟粟的记忆"
        let agentNodeIds = Set(currentPath.filter { $0.agentOrigin != nil }.map(\.id))
        let recentMessages = Array(buildSideModelMessages().suffix(memoryExtractWindow))
            .filter { !agentNodeIds.contains($0.id) }
            .map { (id: $0.id, role: $0.role, content: $0.content) }
        guard !recentMessages.isEmpty else { return }

        // MV2 间隔化：counter 计自上次实际提取以来累积的轮次；首轮必跑（hasEverRun=false）；
        // counter 更新永远生效，guard 决定是否实际跑后续工作
        let decision = ExtractScheduler.tick(
            counter: extractRoundCounter,
            interval: MemoryFlags.extractInterval,
            hasEverRun: hasExtractedEverInSession
        )
        extractRoundCounter = decision.newCounter
        guard decision.shouldRun else {
            #if DEBUG
            print("🧠 记忆提取: 间隔守卫跳过（counter=\(decision.newCounter)/N=\(MemoryFlags.extractInterval)）")
            #endif
            return
        }
        hasExtractedEverInSession = true

        let existingMemories = memoryStore.listHotAndWarm(profileId: profileId, context: context)
        let extractModel = cheapModel(providerManager: providerManager, fallback: model)
        #if DEBUG
        print("🧠 记忆提取: 使用模型 \(extractModel.name) (\(extractModel.id)), 最近 \(recentMessages.count) 条消息, 已有 \(existingMemories.count) 条记忆")
        #endif

        // MV1: 加载短期画像喂给提取器（已涵盖的事实不再 add，封僵尸回路）
        // 紧急修：把楼层 systemPrompt 也喂——AUDN 看不见语境就分不清剧情/本人/AI 互动
        let profile = ProfileFileStore.load(profileId: profileId)
        let request = MemoryExtractor.buildRequest(
            recentMessages: recentMessages,
            existingMemories: existingMemories,
            profile: profile,
            systemPrompt: systemPrompt,
            names: names
        )

        // 预算保险闸：共用主对话 provider 一个预算（粟粟批注：分词器也是粗算，保险即可）
        if backendAgentBlockedByBudget(model: model, messages: request.messages, systemPrompt: request.systemPrompt, providerManager: providerManager) {
            #if DEBUG
            print("🧠 记忆提取: 跳过（主 provider \(model.credentialId) 预算已用完 / 未拨款）")
            #endif
            return
        }

        // Fire-and-forget: 异步调用，不阻塞对话
        let router = ProviderRouter(usageContext: UsageContext(kind: .memory, conversationId: conversationId, profileId: profileId))
        Task.detached { [weak self] in
            do {
                let (response, usage) = try await router.sendNonStreaming(
                    model: extractModel,
                    messages: request.messages,
                    systemPrompt: request.systemPrompt,
                    providerManager: providerManager
                )
                #if DEBUG
                print("🧠 记忆提取: 模型返回 \(response.prefix(200))...")
                #endif

                // Spent 累加到全局预算池（GlobalBudgetStore 不分 providerId，共用一个预算）。
                // 但 actualCost 必须用 extractModel（实际跑的廉价模型）查 PricingCatalog，
                // 否则 Haiku token 数 × Opus 单价会超收 ~18×（ultrareview B17 / bug_004）。
                if let usage {
                    await MainActor.run {
                        self?.commitBudgetSpend(providerManager: providerManager, model: extractModel, usage: usage, recordTurn: false)
                    }
                }

                let actions = MemoryExtractor.parseActions(response)
                #if DEBUG
                if actions.isEmpty {
                    print("🧠 记忆提取: 解析结果为空（模型返回了无法解析的格式或 NOOP）")
                } else {
                    print("🧠 记忆提取: 解析到 \(actions.count) 个操作")
                }
                #endif
                // 刀1：模型调用+解析走通 = 供水在流（NOOP 也算成功）；写入失败在下面单独记
                MemoryHealthStore.recordOK(.extract, profileId: profileId, modelName: extractModel.name)
                guard !actions.isEmpty else {
                    return
                }

                await MainActor.run {
                    var adds = 0, updates = 0, deletes = 0
                    for action in actions {
                        switch action {
                        case .add(let content, let category, _, _):
                            adds += 1
                            #if DEBUG
                            print("🧠 记忆: ✅ ADD [\(category)] \(content.prefix(60))...")
                            #endif
                        case .update(let id, let content, _, _):
                            updates += 1
                            #if DEBUG
                            print("🧠 记忆: ✏️ UPDATE \(id.uuidString.prefix(8)) → \(content.prefix(60))...")
                            #endif
                        case .delete(let id):
                            deletes += 1
                            #if DEBUG
                            print("🧠 记忆: 🗑️ DELETE \(id.uuidString.prefix(8))")
                            #endif
                        }
                    }
                    // 胶囊在 executeActions 成功后才弹——失败弹"记住 N 条"是假成功（R-B4/P1-19）
                    do {
                        try MemoryExtractor.executeActions(
                            actions,
                            store: self?.memoryStore ?? SwiftDataMemoryStore(),
                            profileId: profileId,
                            extractedBy: extractModel.name,
                            sourceConversationId: conversationId,
                            recentMessages: recentMessages,
                            context: context
                        )
                        if let self {
                            var parts: [String] = []
                            if adds > 0 { parts.append("记住 \(adds) 条") }
                            if updates > 0 { parts.append("更新 \(updates) 条") }
                            if deletes > 0 { parts.append("失效 \(deletes) 条") }
                            self.transientNotice = TransientNotice("🧠 " + (parts.isEmpty ? "记忆已更新" : parts.joined(separator: " · ")))
                            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
                        }
                    } catch {
                        MemoryHealthStore.recordError(.extract, profileId: profileId,
                                                      message: "写入失败：\(error.localizedDescription)", modelName: extractModel.name)
                        self?.transientNotice = TransientNotice("🧠 记忆写入失败：\(error.localizedDescription)")
                    }
                }
            } catch {
                MemoryHealthStore.recordError(.extract, profileId: profileId,
                                              message: error.localizedDescription, modelName: extractModel.name)
                await MainActor.run { self?.transientNotice = TransientNotice("🧠 记忆提取失败") }
                #if DEBUG
                print("🧠 记忆提取: ⚠️ 失败 — \(error)")
                #endif
            }
        }
    }

    /// 窗口摘要用的消息：和历史窗口同一个口径（同一批候选、同一个计数），带 id 和时间（第三刀）
    private func sessionMessages() -> [SessionSegmentWriter.Message] {
        // 上下文摘要的输入：工具调用写成中性的 [调用了 …]（#089 P0-b）
        historyCandidates(excluding: nil).map { node, content in
            let text = node.role == "assistant" && Self.hasToolUse(node.segments)
                ? ToolReplay.sideModelText(content: content, rounds: ToolReplay.rounds(from: node.segments) ?? [])
                : content
            return .init(id: node.id, role: node.role, content: text, date: node.createTime)
        }
    }

    /// 窗口摘要压缩触发（fire-and-forget）：超窗并攒够 N 轮就追加一段压缩段
    private func triggerContextSummaryIfNeeded(conversationId: String, conversationTitle: String, profile: Profile, contextDepth: Int, model: ProviderModel, providerManager: ProviderManager) {
        guard MemoryFlags.contextSummaryEnabled else { return }
        let messages = sessionMessages()
        let ctx = SessionCloseout.Context(profile: profile, model: cheapModel(providerManager: providerManager, fallback: model))
        let coveredBefore = ContextSummarizer.load(conversationId: conversationId, profileId: profile.id)?.coveredCount ?? 0
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("contextSummary"); return }   // 测量角色旁路早退（perf P0 §3.2；R7-09 同步前处理照跑、只拦后台外发）
        #endif
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
        let ctx = SessionCloseout.Context(profile: profile, model: cheapModel(providerManager: providerManager, fallback: model))
        Task.detached { [weak self] in
            try? await ContextSummarizer.summarize(
                messages: all, contextDepth: contextDepth, conversationId: convId,
                conversationTitle: convTitle, ctx: ctx, providerManager: providerManager, force: true)
            await MainActor.run {
                if let s = ContextSummarizer.load(conversationId: convId, profileId: ctx.profileId), s.coveredCount == all.count - contextDepth {
                    self?.transientNotice = TransientNotice("📝 上下文摘要记了一段（压到第 \(s.coveredCount) 条）")
                } else {
                    self?.transientNotice = TransientNotice("📝 压缩失败，看调试日志")
                }
            }
        }
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
                guard let (desc, usage) = try? await router.sendNonStreaming(
                    model: model, messages: [(role: "user", content: prompt)],
                    systemPrompt: nil, providerManager: providerManager, images: [att]
                ) else {
                    CacheDiagLog.shared.log("🖼 图片转述: ❌ \(item.name) 调用失败")
                    continue
                }
                if let usage { commitBudgetSpend(providerManager: providerManager, model: model, usage: usage, recordTurn: false) }
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

    /// M5 自动做梦：24h 一次且记忆有新增。fire-and-forget，成功弹胶囊。
    /// MV1: 做梦成功后毕业消费的碎片（钉住免疫）——同一事实不再画像+碎片双份注入，封僵尸回路
    private func dreamIfNeeded(profileId: String, model: ProviderModel, providerManager: ProviderManager, context: ModelContext) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        if PerfHarness.strictMeasure { PerfGuardrails.suppress("dream"); return }   // 测量角色旁路早退（perf P0 §3.2）
        #endif
        let memories = memoryStore.listHotAndWarm(profileId: profileId, context: context)
        guard DreamConsolidator.shouldDream(
            profileId: profileId,
            newestMemoryUpdate: memories.map(\.updatedAt).max(),
            memoryCount: memories.count
        ) else { return }
        let facts = memories.map { (content: $0.content, category: $0.category) }
        // 修复第一刀·刀2：做梦不再把喂进去的碎片标失效（此前一次做梦 = 全体非钉住下岗）
        let dreamModel = cheapModel(providerManager: providerManager, fallback: model)
        Task.detached { [weak self] in
            do {
                guard let result = try await DreamConsolidator.dream(
                    profileId: profileId, facts: facts, model: dreamModel, providerManager: providerManager
                ) else { return }
                MemoryHealthStore.recordOK(.dream, profileId: profileId, modelName: dreamModel.name)
                await MainActor.run {
                    self?.transientNotice = TransientNotice("🌙 画像已更新（\(result.sourceCount) 条记忆 → \(result.text.count) 字）")
                }
            } catch {
                // 刀1：做梦此前 try? 全吞——失败连胶囊都没有，现在至少落健康状态
                MemoryHealthStore.recordError(.dream, profileId: profileId,
                                              message: error.localizedDescription, modelName: dreamModel.name)
            }
        }
    }

    /// Regenerate: create a new assistant response as a sibling branch of the existing one
    func regenerate(assistantNodeId: String, model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, context: ModelContext) {
        guard !assistantTurnInFlight else { return }   // 历史操作不排队，turn 中直接拒，防并发破坏 currentPath
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
            let assembled = assemblePrompt(profile: profile, preset: preset, excludingNodeId: "", context: context, globalEntries: globalWorldBookEntries, fileLibraryHint: nil)
            let payload = prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: userParentId)
            // UI 按钮触发必然 main thread（同上 toolInjection 的 assumeIsolated 先例）
            MainActor.assumeIsolated {
                sendCCFireAndForget(payload: payload, model: model, conversation: conversation, profile: profile, providerManager: providerManager)
            }
            try? context.save()
            scrollToNodeId = userParentId
            return
        }

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
        context.insert(newNode)

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

        // 工具注入（与 sendMessage 同款，包含 fs_*/MCP/recall/联网搜索）
        // regenerate/editAndResend 都是 UI 按钮触发，必然 main thread；assumeIsolated 跨 actor 边界
        let injection = MainActor.assumeIsolated {
            toolInjection(for: model, providerManager: providerManager, conversation: conversation, profileId: conversation.profileId)
        }
        let fileHint = injection.systemHint.isEmpty ? nil : injection.systemHint

        // Assemble prompt（hint 进 system，否则模型不知道有 fs_*/搜索这些工具的用法规范）
        let assembled = assemblePrompt(profile: profile, preset: preset, excludingNodeId: newAssistantId, context: context, globalEntries: globalWorldBookEntries, fileLibraryHint: fileHint, cardGuideCompact: CardGuideTool.isOffered(in: injection.tools))
        // 召回卡片：cc-bridge 发送会丢弃组装结果（只发 raw 文字），不写卡片数据免得撒谎
        if providerManager.provider(for: model)?.type != .ccBridge {
            newNode.setRecallHits(assembled.recallHits)
        }
        let payload = prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: newAssistantId)

        // 复用 runStreamingTurn 走 sendMessage 同款工具循环——regenerate 也能用工具（含联网搜索）
        runStreamingTurn(
            payload: payload, systemPrompt: payload.systemPrompt,
            model: model, providerManager: providerManager,
            conversation: conversation, assistantNode: newNode, assistantNodeId: newAssistantId,
            profile: profile, preset: preset, context: context,
            tools: injection.tools, toolTurns: [], round: 0
        )

        scrollToNodeId = newAssistantId
    }

    /// Edit a user message: create a new branch from the original message's parent with new text, then get a response
    /// 返回 false = 没发出去（turn 中 / 预算拦 / 节点找不到）——输入框编辑态据此保留文字。
    /// attachments / 引用只有输入框编辑传（plan-edit-attachments）；user「重新生成」和 Page2 不传，不读 vm 里的草稿引用
    @discardableResult
    func editAndResend(_ originalNodeId: String, newText: String, attachments: [PendingChatAttachment] = [],
                       replyToId: String? = nil, replyQuote: String? = nil, isEdit: Bool = false,
                       model: ProviderModel, profile: Profile, preset: Preset, providerManager: ProviderManager, context: ModelContext) -> Bool {
        guard !assistantTurnInFlight else { return false }   // 同 regenerate：turn 中直接拒
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
            let assembled = assemblePrompt(profile: profile, preset: preset, excludingNodeId: "", context: context, globalEntries: globalWorldBookEntries, fileLibraryHint: nil)
            let payload = prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: newUserId)
            // UI 按钮触发必然 main thread（同上 toolInjection 的 assumeIsolated 先例）
            MainActor.assumeIsolated {
                sendCCFireAndForget(payload: payload, model: model, conversation: conversation, profile: profile, providerManager: providerManager)
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

        // 工具注入（同 sendMessage / regenerate）
        let injection = MainActor.assumeIsolated {
            toolInjection(for: model, providerManager: providerManager, conversation: conversation, profileId: conversation.profileId)
        }
        let fileHint = injection.systemHint.isEmpty ? nil : injection.systemHint
        let assembled = assemblePrompt(profile: profile, preset: preset, excludingNodeId: newAssistantId, context: context, globalEntries: globalWorldBookEntries, fileLibraryHint: fileHint, cardGuideCompact: CardGuideTool.isOffered(in: injection.tools))
        // 召回卡片：cc-bridge 发送会丢弃组装结果（只发 raw 文字），不写卡片数据免得撒谎
        if providerManager.provider(for: model)?.type != .ccBridge {
            newAssistantNode.setRecallHits(assembled.recallHits)
        }
        let payload = prepareRouterPayload(assembled: assembled, model: model, conversation: conversation, profile: profile, providerManager: providerManager, messageNodeId: newAssistantId)

        runStreamingTurn(
            payload: payload, systemPrompt: payload.systemPrompt,
            model: model, providerManager: providerManager,
            conversation: conversation, assistantNode: newAssistantNode, assistantNodeId: newAssistantId,
            profile: profile, preset: preset, context: context,
            tools: injection.tools, toolTurns: [], round: 0
        )

        scrollToNodeId = newUserId
        return true
    }

    // MARK: - Draft Conversation（草稿对话：真 id 但延迟落库，发首条消息才出现在 page0）

    /// 当前 selectedConversation 是否还是未落库的草稿
    private(set) var isDraftConversation = false
    /// 草稿的 invisible root，转正时一并 insert
    private var draftRootNode: MessageNode?

    /// 起一个草稿对话：建对象但不 insert，UI 直接进聊天界面（空消息 + 输入框）。
    /// 发首条消息时 commitDraftConversationIfNeeded 落库；没发就切走 = 丢弃，不污染列表。
    @MainActor
    func startDraftConversation(profileId: String, fresh: Bool = false) {
        // 已是同楼层草稿就不重建（避免覆盖用户正在输入的上下文）；楼层变了则重建。
        // fresh：page0 ＋ 菜单明确点了「新建」（可能从 Codex 草稿换成普通草稿）→ 总是重建
        if !fresh, isDraftConversation, let c = selectedConversation, c.profileId == profileId { return }
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
        let rootNode = MessageNode(
            id: rootId, role: "system", content: "", contentType: "text",
            createTime: Date(), parentId: nil, childrenIds: [],
            conversationId: conversation.id, profileId: profileId
        )
        // 不 insert —— 纯内存对象
        draftRootNode = rootNode
        isDraftConversation = true

        // 模拟空对话 load 后的状态（invisible root 不进 pathNodeIds，故 currentPath 为空）
        selectedConversation = conversation
        isLoading = false
        currentPath = []
        timeDividerCache.reset()
        nodeMap = [rootId: rootNode]
        effectiveChildrenMap = [rootId: []]
        cachedRootId = rootId
        mainPathIds = []
        branchSelection.removeAll()
        displayLeafId = nil
        bubbledBranches.removeAll()
        branchInfoMap.removeAll()
    }

    /// 草稿转正：发首条消息前调用，把 conversation + root 落库（此后才进 page0 列表）。
    @MainActor
    private func commitDraftConversationIfNeeded(context: ModelContext) {
        guard isDraftConversation, let conversation = selectedConversation else { return }
        context.insert(conversation)
        if let root = draftRootNode { context.insert(root) }
        try? context.save()
        isDraftConversation = false
        draftRootNode = nil
    }

    /// Create a new empty conversation for chatting
    func createNewConversation(title: String, profileId: String, context: ModelContext) -> Conversation {
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

    /// 和设置页实际叫法对齐：简洁版设置里这一行叫「模型（API）」，完整版叫「API」，节名「预算（全局总闸）」
    private static var budgetSettingsPath: String {
        "设置 → API（简洁版叫「模型（API）」）→ 预算（全局总闸）"
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
    let segments: [TaggedSegment]
    let memoryHits: [InjectionHit]
    let ordered: [PromptMessage]
    let sampling: SamplingParams
    /// 卡库 ③-4：SendContext.inspectorLines（有效身份来源 / 退回原因 / 身份的书）
    let identity: [String]

    /// 实发同一个 provider 构造函数建的 body；nil = CC / 本机 / 不支持的卡。懒算：带图对话每次要 base64
    func requestBody(providerManager: ProviderManager) -> [String: Any]? {
        // 和实发 prepareRouterPayload 同一步：不发真工具块的 provider 退纯文字（#089 P0-b）
        let ordered = ToolReplay.orderedForProvider(providerManager.provider(for: model)?.type, self.ordered)
        let legacy = PromptMessage.legacyShape(ordered)
        return ProviderRouter.previewRequestBody(model: model, messages: legacy.messages, systemPrompt: legacy.systemPrompt,
                                                 providerManager: providerManager, samplingParams: sampling,
                                                 tools: tools, ordered: ordered)
    }

    func placementNote(providerManager: ProviderManager) -> String? {
        ProviderRouter.previewSystemPlacementNote(model: model, ordered: ordered, providerManager: providerManager)
    }
}
