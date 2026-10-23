import Foundation

// MARK: - Tagged Segment（上下文检查器用）

enum SegmentSource: Equatable {
    case slot(id: String, name: String)
    case memory
    case worldBook(entryName: String)
    case contextSummary
    case chatHistory
    case dialogueExample
    case fileLibrary
    case userProfile
    case timeline
    case volatileContext   // cacheFriendly：易变内容（命中记忆/触发世界书/摘要/时间宏）下沉的伪 user 段
    case style              // 写作风格：贴在最后一条 user message 末尾的隐藏提示词（<style>…</style>）
    case cardGuide          // 聊天卡片格式说明（ChatCardPromptGuide），固定文字放历史之前
    case folder             // 对话所在文件夹的说明（ConversationTag.instructions），紧跟角色描述
}

struct TaggedSegment {
    let source: SegmentSource
    let role: String
    let template: String    // 宏未展开（{{user}}、{{char}} 原样）
    let content: String     // 宏已展开（{{user}} / {{char}} 换成楼层的名字）
    var nodeId: String? = nil   // ④b：对话历史段的来源节点 id（附件 / 写作风格按它找真实消息，不按正文匹配）
}

// MARK: - 有序消息序列（④b：检查器逻辑顺序 → provider adapter）

struct PromptMessage {
    let role: String            // system / user / assistant
    var content: String         // 宏已展开
    let source: SegmentSource
    /// 真实对话历史节点 id；注入段为 nil
    let nodeId: String?
    /// 组装层自带、历来并进 system 前缀的段（能力提示 / 时间与今日注 / 卡片格式 / 文件夹说明）：
    /// 不按逻辑位置发，仍进前缀，保日常聊天请求体不变
    let pinnedToSystemPrefix: Bool
    /// 按节点 id 挂上的附件（图片 / 文件），provider 渲染成多模态块
    var attachments: [PendingChatAttachment] = []
    /// #089 P0-b：assistant 历史节点的工具回合（按节点 id 挂），provider 展开成真 tool_use / tool_result
    var toolRounds: [ToolReplayRound] = []

    /// 不是对话里的真消息（插槽 / 世界书 / 记忆 / 动态段…）
    var isInjected: Bool { source != .chatHistory }

    /// 附件按节点 id 挂回真实用户消息（不按正文匹配：注入段、重复正文、宏展开、写作风格后缀都不会挂错或丢图）
    static func attaching(_ attachmentsByNodeId: [String: [PendingChatAttachment]], to ordered: [PromptMessage]) -> [PromptMessage] {
        var result = ordered
        for idx in result.indices where result[idx].role == "user" {
            if let nodeId = result[idx].nodeId, let attachments = attachmentsByNodeId[nodeId] {
                result[idx].attachments = attachments
            }
        }
        return result
    }

    /// #089 P0-b：工具回合按节点 id 挂回 assistant 历史消息
    static func attachingToolRounds(_ roundsByNodeId: [String: [ToolReplayRound]], to ordered: [PromptMessage]) -> [PromptMessage] {
        guard !roundsByNodeId.isEmpty else { return ordered }
        var result = ordered
        for idx in result.indices where result[idx].role == "assistant" {
            if let nodeId = result[idx].nodeId, let rounds = roundsByNodeId[nodeId] {
                result[idx].toolRounds = rounds
            }
        }
        return result
    }

    /// 与改前 assemble() 同形：所有 system 并成前缀，其余按序；imageMap 由附件按正文派生（给还没迁的调用方）
    static func legacyShape(_ ordered: [PromptMessage]) -> (systemPrompt: String?, messages: [(role: String, content: String)], imageMap: [String: [PendingChatAttachment]]) {
        let systems = ordered.filter { $0.role == "system" }.map(\.content)
        var imageMap: [String: [PendingChatAttachment]] = [:]
        for message in ordered where message.role == "user" && !message.attachments.isEmpty {
            imageMap[message.content] = message.attachments
        }
        return (systems.isEmpty ? nil : systems.joined(separator: "\n\n"),
                ordered.filter { $0.role != "system" }.map { (role: $0.role, content: $0.content) },
                imageMap)
    }
}

extension SegmentSource {
    var displayName: String {
        switch self {
        case .slot(_, let name): return name
        case .memory: return "记忆"
        case .worldBook(let name): return "世界书: \(name)"
        case .contextSummary: return "上下文摘要"
        case .chatHistory: return "对话历史"
        case .dialogueExample: return "对话示例"
        case .fileLibrary: return "文件库"
        case .userProfile: return "用户画像"
        case .timeline: return "时间轴"
        case .volatileContext: return "动态上下文"
        case .style: return "写作风格"
        case .cardGuide: return "卡片格式"
        case .folder: return "文件夹说明"
        }
    }
}

// MARK: - Prompt Assembler

struct PromptAssembler {
    /// 结构锚点不属于历史；API 和记忆提取共用此过滤入口。
    static func historyNodes(_ nodes: [MessageNode]) -> [MessageNode] {
        nodes.filter { !$0.isSyntheticRoot && !$0.isSourceHidden }
    }


    /// 组装最终发给 API 的 system prompt + messages（原有接口，加 styleContent 后向兼容）
    static func assemble(
        preset: Preset,
        profile: Profile,
        memories: [Memory],
        chatHistory: [(role: String, content: String)],
        worldBooks: [WorldBook] = [],
        globalEntries: [WorldBookEntry] = [],
        contextSummary: String? = nil,
        userProfile: String? = nil,
        timelineSummary: String? = nil,
        healthSummary: String = "",
        tradingSummary: String = "",
        fileLibrary: String? = nil,
        styleContent: String? = nil,
        folderInstructions: String? = nil,
        volatileNote: String? = nil,
        selfMemory: String? = nil,
        memoryBudget: Int? = nil
    ) -> (systemPrompt: String?, messages: [(role: String, content: String)], memoryHits: [InjectionHit]) {
        let assembled = assembleTagged(
            preset: preset, profile: profile, memories: memories,
            chatHistory: chatHistory, worldBooks: worldBooks,
            globalEntries: globalEntries, contextSummary: contextSummary,
            userProfile: userProfile, timelineSummary: timelineSummary,
            healthSummary: healthSummary, tradingSummary: tradingSummary, fileLibrary: fileLibrary,
            styleContent: styleContent, folderInstructions: folderInstructions,
            volatileNote: volatileNote, selfMemory: selfMemory, memoryBudget: memoryBudget
        )
        let tagged = assembled.segments
        let systemSegments = tagged.filter { $0.role == "system" }
        let systemPrompt = systemSegments.isEmpty ? nil : systemSegments.map(\.content).joined(separator: "\n\n")
        // 合并 .style 段到最后一条 user，避免 user+user 连排发到模型
        var nonSystem = tagged.filter { $0.role != "system" }
        if let styleIdx = nonSystem.lastIndex(where: { if case .style = $0.source { return true } else { return false } }) {
            let styleSeg = nonSystem.remove(at: styleIdx)
            if let lastUserIdx = nonSystem.lastIndex(where: { $0.role == "user" }) {
                let merged = nonSystem[lastUserIdx]
                nonSystem[lastUserIdx] = TaggedSegment(
                    source: merged.source, role: "user",
                    template: merged.template + "\n" + styleSeg.template,
                    content: merged.content + "\n" + styleSeg.content
                )
            } else {
                // 没 user 历史（首轮），单独作 user 段发
                nonSystem.append(styleSeg)
            }
        }
        let messages = nonSystem.map { (role: $0.role, content: $0.content) }
        return (systemPrompt: systemPrompt, messages: messages, memoryHits: assembled.memoryHits)
    }

    /// ④b 有序输出：顺序 = 检查器逻辑顺序，system 不再整体抽成前缀（前缀怎么定、非前缀怎么降级归 provider adapter）。
    /// historyNodeIds 与 chatHistory 一一对应时，历史段带上节点 id（附件 / 写作风格靠它定位真实消息）。
    static func assembleOrdered(
        preset: Preset,
        profile: Profile,
        memories: [Memory],
        chatHistory: [(role: String, content: String)],
        historyNodeIds: [String]? = nil,
        worldBooks: [WorldBook] = [],
        globalEntries: [WorldBookEntry] = [],
        contextSummary: String? = nil,
        userProfile: String? = nil,
        timelineSummary: String? = nil,
        healthSummary: String = "",
        tradingSummary: String = "",
        fileLibrary: String? = nil,
        styleContent: String? = nil,
        folderInstructions: String? = nil,
        volatileNote: String? = nil,
        regexScripts: [RegexScript] = [],
        selfMemory: String? = nil,
        memoryBudget: Int? = nil
    ) -> (messages: [PromptMessage], memoryHits: [InjectionHit]) {
        let assembled = assembleTagged(
            preset: preset, profile: profile, memories: memories,
            chatHistory: chatHistory, worldBooks: worldBooks,
            globalEntries: globalEntries, contextSummary: contextSummary,
            userProfile: userProfile, timelineSummary: timelineSummary,
            healthSummary: healthSummary, tradingSummary: tradingSummary, fileLibrary: fileLibrary,
            styleContent: styleContent, folderInstructions: folderInstructions,
            volatileNote: volatileNote, historyNodeIds: historyNodeIds, regexScripts: regexScripts,
            selfMemory: selfMemory, memoryBudget: memoryBudget
        )
        return (orderedMessages(from: assembled.segments), assembled.memoryHits)
    }

    /// tagged 段 → 有序消息（实发与检查器共用）。写作风格段并进**真实**最后一条用户消息（注入段不算）；
    /// 没有真实用户消息时单独作一条 user 段放最后（同改前首轮口径）
    static func orderedMessages(from segments: [TaggedSegment]) -> [PromptMessage] {
        var result: [PromptMessage] = []
        var style: TaggedSegment?
        for seg in segments {
            if case .style = seg.source { style = seg; continue }
            result.append(PromptMessage(
                role: seg.role, content: seg.content, source: seg.source, nodeId: seg.nodeId,
                pinnedToSystemPrefix: seg.role == "system" && isPinnedToSystemPrefix(seg.source)))
        }
        if let style {
            if let idx = result.lastIndex(where: { $0.role == "user" && !$0.isInjected }) {
                result[idx].content += "\n" + style.content
            } else {
                result.append(PromptMessage(role: "user", content: style.content, source: .style, nodeId: nil, pinnedToSystemPrefix: false))
            }
        }
        return result
    }

    private static func isPinnedToSystemPrefix(_ source: SegmentSource) -> Bool {
        switch source {
        case .fileLibrary, .volatileContext, .cardGuide, .folder: return true
        default: return false
        }
    }

    /// 带来源标注的组装（上下文检查器用）
    ///
    /// 每段同时保留 template（宏未展开）和 content（宏已展开），
    /// 组装 tab 显示 template，请求 tab 显示 content。
    /// styleContent 非空时,末尾追加一个 .style 段；assemble() wrapper 合并到 last user。
    static func assembleTagged(
        preset: Preset,
        profile: Profile,
        memories: [Memory],
        chatHistory: [(role: String, content: String)],
        worldBooks: [WorldBook] = [],
        globalEntries: [WorldBookEntry] = [],
        contextSummary: String? = nil,
        userProfile: String? = nil,
        timelineSummary: String? = nil,
        healthSummary: String = "",
        tradingSummary: String = "",
        fileLibrary: String? = nil,
        styleContent: String? = nil,
        folderInstructions: String? = nil,
        /// 每轮可能变的一段（例如今天的日记，plan-calendar §八）：cacheFriendly 时进动态段，不碰前缀
        volatileNote: String? = nil,
        /// #089 P1：〔状态〕（时间 / 正在读 / 药单 / 文件库摘要）——不管开没开缓存友好，一律进动态段（最新一条用户消息前），不进 system
        statusNote: String? = nil,
        /// ④b：与 chatHistory 一一对应的节点 id（数量不符就不带）
        historyNodeIds: [String]? = nil,
        /// ⑤a：当前有效规则（RegexPipeline 解析）；这里只跑发送阶段，没有发送规则时组装与改前逐字节一致
        regexScripts: [RegexScript] = [],
        /// 第二刀 B3：AI 自己的记忆（[我的记忆] 整段，SelfMemoryInjection 拼好），放在记忆插槽里、档案前面，进常驻层
        selfMemory: String? = nil,
        /// 第二刀 B3：原子档案能用的预算（总预算减去「我的记忆」实际占用）；nil = 总预算
        memoryBudget: Int? = nil,
        /// 这轮发了 card_guide 工具：卡片说明只放短目录，模型要用再查（粟粟 10-03）
        cardGuideCompact: Bool = false
    ) -> (segments: [TaggedSegment], memoryHits: [InjectionHit]) {
        // 本轮注入命中（召回卡片 + S1 检查器）——cacheFriendly 分支和 marker 老路都会填
        var memoryHits: [InjectionHit] = []

        // 截断只是兜底：实际窗口由 CV.buildWindowedAPIMessages 控制（摘要边界锚定，可达 depth×2），
        // 这里上限取 ×2 防直接调用方传超长历史，不再二次裁掉锚定窗口
        // +1：历史以 assistant 结尾时补的那条合成用户消息（#089 P0-a）不能把窗口第一条真实消息挤掉（astra #3）
        let contextDepth = preset.sampling.contextDepth * 2 + 1
        let trimmedHistory = chatHistory.count > contextDepth
            ? Array(chatHistory.suffix(contextDepth))
            : chatHistory
        let trimmedHistoryIds: [String?] = historyNodeIds.flatMap { ids in
            ids.count == chatHistory.count ? Array(ids.suffix(trimmedHistory.count)) : nil
        } ?? Array(repeating: nil, count: trimmedHistory.count)

        // ⑤a 发送正则：历史副本（宏展开后）按深度（最新 = 0）跑发送规则，世界书扫描吃处理后的文本；
        // 没有发送规则 = nil，下面全部走原路
        let names = EffectiveCharacterContext(profile: profile)
        let sendScripts = regexScripts.filter { !$0.disabled && $0.phases.contains(.send) }
        let sendHistory = sendScripts.isEmpty ? nil : RegexPipeline.sendHistory(trimmedHistory, scripts: sendScripts, names: names)

        // ④a：序列顺序只经 SlotOrder 读（旧数据无 sequenceIndex 时就是原来的 injectionOrder 顺序）
        let activeSlots = SlotOrder.ordered(preset.prompts)
            .filter { $0.isEnabled }

        // chatHistory marker 是分割点：序列里在它之前的 relative 插槽在历史前，之后的在历史后
        let chatHistoryPosition = activeSlots
            .firstIndex { $0.isMarker && $0.id == PromptSlot.chatHistoryId } ?? Int.max

        var preHistorySystem: [TaggedSegment] = []
        var preHistoryMessages: [TaggedSegment] = []
        var postHistorySystem: [TaggedSegment] = []
        // absolute 注入：depth=0 在历史最末（最新一条之后），depth=N 在倒数第 N 条之前；同深度按 order 升序
        var depthInjections: [(depth: Int, order: Int, segment: TaggedSegment)] = []

        // cacheFriendly：每轮会变的内容不留在前缀里（system/历史一变缓存全废），
        // 收集到这里，最后并成一条伪 user 段插在当前消息之前
        let cacheFriendly = preset.sampling.cacheFriendly == true
        var volatileParts: [String] = []

        // ── 世界书预扫描（B27）：before/after 桶由 World Info 插槽承载，按插槽位排序。
        // marker 存在 → 桶归插槽（disabled 时槽不进 activeSlots = 整桶不注入，对齐酒馆）；
        // marker 不存在 → 桶退回 charDef 旁注入兜底（不丢条目）
        var wiBeforeBucket: [ResolvedEntry] = []
        var wiAfterBucket: [ResolvedEntry] = []
        var wiRestEntries: [ResolvedEntry] = []
        if !worldBooks.isEmpty || !globalEntries.isEmpty {
            var resolved = WorldBookScanner.scan(
                worldBooks: worldBooks, recentMessages: (sendHistory ?? trimmedHistory).map { $0.content },
                profile: profile, globalEntries: globalEntries
            )
            // SC-B4 刀3：世界书预算闸——唯一无闸全注的源。按 insertionOrder 优先级进预算，
            // 超出裁尾 + log。默认 0 = 无限 = 现状（行为零退化）
            // ⑥：卡库设置「每次最多注入」条数上限也在这道闸，先条数后 token，两个 0 都是不限
            let wbBudget = UserDefaults.standard.integer(forKey: CardLibraryPreferences.worldBookTokenBudgetKey)
            let wbMaxEntries = UserDefaults.standard.integer(forKey: CardLibraryPreferences.worldBookMaxEntriesKey)
            if wbBudget > 0 || wbMaxEntries > 0 {
                let kept = WorldBookScanner.limited(resolved, maxEntries: wbMaxEntries, tokenBudget: wbBudget)
                if kept.count < resolved.count {
                    CacheDiagLog.shared.log("📚 世界书预算闸：命中 \(resolved.count) 条 → 注入 \(kept.count) 条（上限 \(wbMaxEntries) 条 / 预算 \(wbBudget) tok）")
                }
                resolved = kept
            }
            // 命中的世界书内容也跑 placement=5 的发送规则再注入（酒馆 world-info.js 同）；跑空的条目不注入
            if !sendScripts.isEmpty {
                resolved = resolved.compactMap { entry in
                    let content = RegexPipeline.run(
                        sendScripts, text: entry.content, phase: .send, placement: RegexPipeline.worldInfoPlacement,
                        depth: entry.position == .atDepth ? entry.depth : nil,
                        userName: names.userName, charName: names.charName)
                    guard !content.isEmpty else { return nil }
                    return ResolvedEntry(content: content, position: entry.position, depth: entry.depth,
                                         insertionOrder: entry.insertionOrder, role: entry.role,
                                         tokenCount: entry.tokenCount, isConstant: entry.isConstant)
                }
            }
            let hasBeforeSlot = preset.prompts.contains { $0.id == PromptSlot.worldInfoBeforeId }
            let hasAfterSlot = preset.prompts.contains { $0.id == PromptSlot.worldInfoAfterId }
            for entry in resolved {
                switch entry.position {
                case .beforeCharDef where hasBeforeSlot: wiBeforeBucket.append(entry)
                case .afterCharDef where hasAfterSlot: wiAfterBucket.append(entry)
                default: wiRestEntries.append(entry)
                }
            }
        }

        var sawSummarySlot = false
        var sawProfileSlot = false

        for (position, slot) in activeSlots.enumerated() {
            if slot.isMarker && slot.id == PromptSlot.chatHistoryId { continue }

            let isAfterHistory = position > chatHistoryPosition

            // 上下文摘要插槽：注入位置由粟粟在插槽列表里排（顺序=位置）。
            // 滞后压缩（5-10 轮一变）后足够稳定 → 不下沉，留前缀（每次更新付一次缓存 miss，划算）
            if slot.isMarker && slot.id == PromptSlot.contextSummaryId {
                sawSummarySlot = true
                if let summary = contextSummary, !summary.isEmpty {
                    let text = "[上下文摘要]\n\(summary)"
                    let seg = TaggedSegment(source: .contextSummary, role: slot.role, template: text, content: text)
                    if slot.isAbsolute {
                        depthInjections.append((depth: slot.injectionDepth, order: slot.injectionOrder, segment: seg))
                    } else if isAfterHistory {
                        postHistorySystem.append(seg)
                    } else if slot.role == "system" {
                        preHistorySystem.append(seg)
                    } else {
                        preHistoryMessages.append(seg)
                    }
                }
                continue
            }

            // 时间轴插槽（M6）：最新一篇楼层日记，天级稳定，进前缀，位置粟粟排
            if slot.isMarker && slot.id == PromptSlot.timelineId {
                if let timeline = timelineSummary, !timeline.isEmpty {
                    let seg = TaggedSegment(source: .timeline, role: slot.role, template: timeline, content: timeline)
                    if slot.isAbsolute {
                        depthInjections.append((depth: slot.injectionDepth, order: slot.injectionOrder, segment: seg))
                    } else if isAfterHistory {
                        postHistorySystem.append(seg)
                    } else if slot.role == "system" {
                        preHistorySystem.append(seg)
                    } else {
                        preHistoryMessages.append(seg)
                    }
                }
                continue
            }

            // 用户画像插槽（M5）：天级更新足够稳定，进前缀，位置粟粟排
            if slot.isMarker && slot.id == PromptSlot.userProfileId {
                sawProfileSlot = true
                if let portrait = userProfile, !portrait.isEmpty {
                    let text = "[用户画像]\n\(portrait)"
                    let seg = TaggedSegment(source: .userProfile, role: slot.role, template: text, content: text)
                    if slot.isAbsolute {
                        depthInjections.append((depth: slot.injectionDepth, order: slot.injectionOrder, segment: seg))
                    } else if isAfterHistory {
                        postHistorySystem.append(seg)
                    } else if slot.role == "system" {
                        preHistorySystem.append(seg)
                    } else {
                        preHistoryMessages.append(seg)
                    }
                }
                continue
            }

            // 记忆槽拆两层：常驻层留原位（稳定），命中/兜底层下沉（每轮可变）
            if cacheFriendly && slot.isMarker && slot.id == PromptSlot.memoryInjectionId {
                let layers = memoryLayers(profile: profile, selfMemory: selfMemory, memories: memories,
                                          recentMessages: trimmedHistory.map { $0.content }, budget: memoryBudget)
                memoryHits = layers.hits
                if !layers.stable.isEmpty {
                    let text = layers.stable
                    let seg = TaggedSegment(source: .memory, role: slot.role, template: text, content: text)
                    if slot.isAbsolute {
                        depthInjections.append((depth: slot.injectionDepth, order: slot.injectionOrder, segment: seg))
                    } else if isAfterHistory {
                        postHistorySystem.append(seg)
                    } else if slot.role == "system" {
                        preHistorySystem.append(seg)
                    } else {
                        preHistoryMessages.append(seg)
                    }
                }
                if !layers.volatile.isEmpty {
                    volatileParts.append(layers.volatile)
                }
                continue
            }

            // 世界书插槽（B27）：对应桶逐条注入（保 S1 逐条可见性），桶内序=insertionOrder 升序（酒馆同）；
            // 关键词命中条目 cacheFriendly 下沉，常驻条目随插槽进前缀
            if slot.isMarker && (slot.id == PromptSlot.worldInfoBeforeId || slot.id == PromptSlot.worldInfoAfterId) {
                let bucket = slot.id == PromptSlot.worldInfoBeforeId ? wiBeforeBucket : wiAfterBucket
                for entry in bucket {
                    if cacheFriendly && !entry.isConstant {
                        volatileParts.append(entry.content)
                        continue
                    }
                    let entryLabel = String(entry.content.prefix(30)).components(separatedBy: "\n").first ?? "条目"
                    let seg = TaggedSegment(source: .worldBook(entryName: entryLabel), role: entry.role, template: entry.content, content: entry.content)
                    if slot.isAbsolute {
                        depthInjections.append((depth: slot.injectionDepth, order: slot.injectionOrder, segment: seg))
                    } else if isAfterHistory {
                        postHistorySystem.append(seg)
                    } else if slot.role == "system" {
                        preHistorySystem.append(seg)
                    } else {
                        preHistoryMessages.append(seg)
                    }
                }
                continue
            }

            if slot.isMarker && slot.id == PromptSlot.dialogueExamplesId {
                let pair = resolveSlotContentPair(slot, profile: profile, preset: preset, memories: memories, chatHistory: trimmedHistory, health: healthSummary, trading: tradingSummary, selfMemory: selfMemory, memoryBudget: memoryBudget)
                if let p = pair {
                    preHistoryMessages.append(TaggedSegment(source: .dialogueExample, role: "_examples_marker_", template: "", content: ""))
                    let examples = parseChatExamples(p.expanded, profile: profile)
                    for ex in examples {
                        preHistoryMessages.append(TaggedSegment(source: .dialogueExample, role: ex.role, template: ex.content, content: ex.content))
                    }
                    preHistoryMessages.append(TaggedSegment(source: .dialogueExample, role: "_examples_end_marker_", template: "", content: ""))
                }
                continue
            }

            guard let pair = resolveSlotContentPair(slot, profile: profile, preset: preset, memories: memories, chatHistory: trimmedHistory, health: healthSummary, trading: tradingSummary, selfMemory: selfMemory, memoryBudget: memoryBudget, hitsSink: { memoryHits = $0 }),
                  !pair.expanded.isEmpty else { continue }

            let source: SegmentSource = slot.id == PromptSlot.memoryInjectionId
                ? .memory
                : .slot(id: slot.id, name: slot.name)

            let seg = TaggedSegment(source: source, role: slot.role, template: pair.template, content: pair.expanded)

            // 含时间宏的 system 槽每分钟都在变 → 整段下沉（粟粟拍板：不禁用，挪位置）；absolute（含 depth=0）按深度语义走，不下沉
            if cacheFriendly && slot.role == "system" && !slot.isAbsolute
                && (pair.template.contains("{{date}}") || pair.template.contains("{{time}}")) {
                volatileParts.append(pair.expanded)
                continue
            }

            if slot.isAbsolute {
                depthInjections.append((depth: slot.injectionDepth, order: slot.injectionOrder, segment: seg))
            } else if isAfterHistory {
                postHistorySystem.append(seg)
            } else if slot.role == "system" {
                preHistorySystem.append(seg)
            } else {
                preHistoryMessages.append(seg)
            }
        }

        // ── 世界书注入（B27 后：仅剩 examples/atDepth/作者注 + marker 缺失时的 before/after 兜底）──
        if !wiRestEntries.isEmpty {
            for entry in wiRestEntries {
                let entryLabel = String(entry.content.prefix(30)).components(separatedBy: "\n").first ?? "条目"

                // 关键词触发条目每轮命中集不同 → 下沉（蓝灯常驻条目稳定，留原位；
                // 消息区位置 atDepth/examples 是显式定位语义，不动）
                if cacheFriendly && !entry.isConstant {
                    switch entry.position {
                    case .beforeCharDef, .afterCharDef, .authorNoteTop, .authorNoteBot:
                        volatileParts.append(entry.content)
                        continue
                    default: break
                    }
                }

                let seg = TaggedSegment(
                    source: .worldBook(entryName: entryLabel),
                    role: entry.role == "system" ? "system" : entry.role,
                    template: entry.content, content: entry.content
                )

                switch entry.position {
                case .beforeCharDef:
                    if let idx = preHistorySystem.firstIndex(where: { if case .slot(let id, _) = $0.source { return id == PromptSlot.charDescriptionId } else { return false } }) {
                        preHistorySystem.insert(seg, at: idx)
                    } else { preHistorySystem.append(seg) }

                case .afterCharDef:
                    if let idx = preHistorySystem.firstIndex(where: { if case .slot(let id, _) = $0.source { return id == PromptSlot.charDescriptionId } else { return false } }) {
                        preHistorySystem.insert(seg, at: preHistorySystem.index(after: idx))
                    } else { preHistorySystem.append(seg) }

                case .beforeExamples:
                    if let idx = preHistoryMessages.firstIndex(where: { $0.role == "_examples_marker_" }) {
                        preHistoryMessages.insert(seg, at: idx)
                    } else { preHistoryMessages.append(seg) }

                case .afterExamples:
                    if let idx = preHistoryMessages.firstIndex(where: { $0.role == "_examples_end_marker_" }) {
                        preHistoryMessages.insert(seg, at: preHistoryMessages.index(after: idx))
                    } else { preHistoryMessages.append(seg) }

                case .unsupported:
                    continue

                case .atDepth:
                    // order 取最大：同深度排在插槽注入之后（与 ④a 前的追加顺序一致）
                    depthInjections.append((depth: entry.depth, order: Int.max, segment: seg))

                case .authorNoteTop:
                    if let idx = postHistorySystem.firstIndex(where: { if case .slot(let id, _) = $0.source { return id == PromptSlot.jailbreakId } else { return false } }) {
                        postHistorySystem.insert(seg, at: idx)
                    } else { postHistorySystem.append(seg) }

                case .authorNoteBot:
                    if let idx = postHistorySystem.firstIndex(where: { if case .slot(let id, _) = $0.source { return id == PromptSlot.jailbreakId } else { return false } }) {
                        postHistorySystem.insert(seg, at: postHistorySystem.index(after: idx))
                    } else { postHistorySystem.append(seg) }
                }
            }
        }

        // 清理 marker 占位符
        preHistoryMessages.removeAll { $0.role == "_examples_marker_" || $0.role == "_examples_end_marker_" }

        // 用户画像兜底（无插槽的旧实例：常驻区头部）
        if let portrait = userProfile, !portrait.isEmpty, !sawProfileSlot {
            let text = "[用户画像]\n\(portrait)"
            preHistorySystem.insert(TaggedSegment(source: .userProfile, role: "system", template: text, content: text), at: 0)
        }

        // 上下文摘要兜底（preset 里没有摘要插槽的旧实例：历史之前）
        if let summary = contextSummary, !summary.isEmpty, !sawSummarySlot {
            let text = "[上下文摘要]\n\(summary)"
            preHistorySystem.append(TaggedSegment(source: .contextSummary, role: "system", template: text, content: text))
        }

        // 文件夹说明：固定文字进缓存前缀，紧跟角色描述（没有角色描述插槽就排常驻区末尾）
        if let folderInstructions, !folderInstructions.isEmpty {
            let text = "[文件夹说明]\n\(folderInstructions)"
            let seg = TaggedSegment(source: .folder, role: "system", template: text,
                                    content: applyMacros(text, profile: profile, health: healthSummary, trading: tradingSummary))
            if let idx = preHistorySystem.firstIndex(where: { if case .slot(let id, _) = $0.source { return id == PromptSlot.charDescriptionId } else { return false } }) {
                preHistorySystem.insert(seg, at: preHistorySystem.index(after: idx))
            } else { preHistorySystem.append(seg) }
        }

        // 对话历史：正文里的 {{char}}/{{user}}（卡开场）只在发送副本展开，template 留原文（③b）；
        // 有发送规则时 content 取跑过规则的副本（⑤a），nodeId 不变 → 附件仍挂原节点
        let historySegments = zip(trimmedHistory, trimmedHistoryIds).enumerated().map { index, pair in
            TaggedSegment(source: .chatHistory, role: pair.0.role, template: pair.0.content,
                          content: sendHistory?[index].content ?? names.expand(pair.0.content), nodeId: pair.1)
        }

        // 组装：preHistorySystem + preHistoryMessages + chatHistory + depthInjections + postHistorySystem
        var allMessages = preHistoryMessages + historySegments
        // 深的先插；同深度 order 小的先插（后插的落在它后面）；再同则按收集顺序
        let sortedInjections = depthInjections.enumerated().sorted {
            (-$0.element.depth, $0.element.order, $0.offset) < (-$1.element.depth, $1.element.order, $1.offset)
        }.map(\.element)
        for injection in sortedInjections {
            let insertIndex = max(0, allMessages.count - injection.depth)
            allMessages.insert(injection.segment, at: insertIndex)
        }

        // 角色时区与作息感知：分钟级易变 → cacheFriendly 走 volatile 伪 user 段（保护前缀缓存），
        // 否则挂历史后 system 段（离生成点近）
        if let timeCtx = CharacterTimeContext.promptText(profile: profile) {
            if cacheFriendly {
                volatileParts.append(timeCtx)
            } else {
                postHistorySystem.append(TaggedSegment(source: .volatileContext, role: "system", template: timeCtx, content: timeCtx))
            }
        }

        if let volatileNote, !volatileNote.isEmpty {
            if cacheFriendly {
                volatileParts.append(volatileNote)
            } else {
                postHistorySystem.append(TaggedSegment(source: .volatileContext, role: "system", template: volatileNote, content: volatileNote))
            }
        }

        // cacheFriendly：易变段并成一条伪 user 消息，插在当前消息之前（深度 1）。
        // 放 system 尾部没用——system 排在所有消息前面，它一变 history 缓存全废；
        // 放历史之后，前缀（system+全部历史）才能逐字稳定（NyraSeithhh/cache 的 volatile_context 思路）
        if let statusNote, !statusNote.isEmpty {
            volatileParts.insert(applyMacros(statusNote, profile: profile, health: healthSummary, trading: tradingSummary), at: 0)
        }
        // 缓存友好关着时，时间 / 日记照旧走历史后 system（上面），这里只剩〔状态〕
        if !volatileParts.isEmpty {
            let text = "[动态上下文｜仅供参考，不要复述]\n" + volatileParts.joined(separator: "\n\n")
            let seg = TaggedSegment(source: .volatileContext, role: "user", template: text, content: text)
            // 锚在最后一条历史之前（④a：absolute depth=0 注入排在历史之后，不能再用 count-1）
            let lastHistory = allMessages.lastIndex { if case .chatHistory = $0.source { return true } else { return false } }
            allMessages.insert(seg, at: lastHistory ?? max(0, allMessages.count - 1))
        }

        // 文件库注入（独立来源「文件库」，放 system 段最后，离生成点近）
        // content 过宏展开（{{user}}/{{char}}——「正在读的书」语境用；通用 app 禁止硬编码人称），
        // template 保留原文与其他 slot 的 (template, expanded) 口径一致
        var fileLibrarySegments: [TaggedSegment] = []
        if let fileLibrary, !fileLibrary.isEmpty {
            fileLibrarySegments.append(TaggedSegment(
                source: .fileLibrary, role: "system",
                template: fileLibrary,
                content: applyMacros(fileLibrary, profile: profile, health: healthSummary, trading: tradingSummary)
            ))
        }

        // 聊天卡片格式说明（research-chat-cards §4.7）：固定文字，放历史之前不破坏缓存前缀
        // 发了 card_guide 工具只放目录（完整写法模型自己查）；没发工具（CC / 工具关了）照旧放全文
        let cardGuideText = cardGuideCompact ? ChatCardPromptGuide.index : ChatCardPromptGuide.text
        let cardGuide: [TaggedSegment] = ChatCardPromptGuide.isEnabledForTesting
            ? [TaggedSegment(source: .cardGuide, role: "system",
                             template: cardGuideText, content: cardGuideText)]
            : []
        var result = preHistorySystem + cardGuide + allMessages + postHistorySystem + fileLibrarySegments
        // 写作风格段：tagging 中独立显示（预览/插槽可见），assemble wrapper 合并到 last user content 末尾
        if let styleContent, !styleContent.isEmpty {
            let styleText = "<style>\(styleContent)</style>"
            result.append(TaggedSegment(source: .style, role: "user", template: styleText, content: styleText))
        }
        return (segments: result, memoryHits: memoryHits)
    }
    /// cacheFriendly 记忆槽两层：常驻层 =「我的记忆」+ 档案常驻，命中层 = 档案本轮相关。
    /// 实发组装和记忆面板「下一轮会想起什么」预览共用（预览 = 实发）
    static func memoryLayers(profile: Profile, selfMemory: String?, memories: [Memory],
                             recentMessages: [String], budget: Int?) -> (stable: String, volatile: String, hits: [InjectionHit]) {
        let (stable, volatile, hits) = MemoryInjector.buildInjectionSplit(memories: memories, recentMessages: recentMessages, budget: budget ?? MemoryInjector.tokenBudget)
        let stableText = [selfMemory ?? "", stable.isEmpty ? "" : "[\(archiveLabel(profile))]\n\(stable)"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let volatileText = volatile.isEmpty ? "" : "[\(archiveLabel(profile))·本轮相关]\n\(volatile)"
        return (stableText, volatileText, hits)
    }

    /// 原子档案段的标签：粟粟 10-03 批改「[关于用户]」→「[关于{她在楼层里的称呼}]」；没设称呼用「对方」
    static func archiveLabel(_ profile: Profile) -> String {
        let name = profile.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "关于\(name.isEmpty ? "对方" : name)"
    }

    // MARK: - Private

    /// 解析插槽内容，同时返回模板（宏未展开）和最终文本（宏已展开）
    private static func resolveSlotContentPair(
        _ slot: PromptSlot, profile: Profile, preset: Preset,
        memories: [Memory], chatHistory: [(role: String, content: String)],
        health: String = "",
        trading: String = "",
        selfMemory: String? = nil,
        memoryBudget: Int? = nil,
        hitsSink: (([InjectionHit]) -> Void)? = nil
    ) -> (template: String, expanded: String)? {

        guard slot.isMarker else {
            let raw = slot.content
            return raw.isEmpty ? nil : (template: raw, expanded: applyMacros(raw, profile: profile, health: health, trading: trading))
        }

        if !slot.content.isEmpty {
            switch slot.id {
            case PromptSlot.chatHistoryId: return nil
            case PromptSlot.memoryInjectionId: break
            default:
                let raw = slot.content
                return (template: raw, expanded: applyMacros(raw, profile: profile, health: health, trading: trading))
            }
        }

        switch slot.id {
        case PromptSlot.mainId:
            guard !profile.systemPrompt.isEmpty else { return nil }
            let raw = profile.systemPrompt
            return (template: raw, expanded: applyMacros(raw, profile: profile, health: health, trading: trading))

        case PromptSlot.personaDescriptionId:
            guard !profile.userPersona.isEmpty else { return nil }
            let raw = preset.personaFormat
                .replacingOccurrences(of: "{{persona}}", with: profile.userPersona)
            return (template: raw, expanded: applyMacros(raw, profile: profile, health: health, trading: trading))

        case PromptSlot.charDescriptionId:
            guard !profile.characterDescription.isEmpty else { return nil }
            let raw = preset.characterFormat
                .replacingOccurrences(of: "{{description}}", with: profile.characterDescription)
                .replacingOccurrences(of: "{{personality}}", with: profile.characterPersonality)
            return (template: raw, expanded: applyMacros(raw, profile: profile, health: health, trading: trading))

        case PromptSlot.charPersonalityId:
            return nil

        case PromptSlot.scenarioId:
            guard !profile.scenario.isEmpty else { return nil }
            let raw = preset.scenarioFormat
                .replacingOccurrences(of: "{{scenario}}", with: profile.scenario)
            return (template: raw, expanded: applyMacros(raw, profile: profile, health: health, trading: trading))

        case PromptSlot.memoryInjectionId:
            let (stable, volatile, hits) = MemoryInjector.buildInjectionSplit(memories: memories, recentMessages: chatHistory.map { $0.content }, budget: memoryBudget ?? MemoryInjector.tokenBudget)
            let injection = [stable, volatile].filter { !$0.isEmpty }.joined(separator: "\n")
            let parts = [selfMemory ?? "", injection.isEmpty ? "" : "[\(archiveLabel(profile))]\n\(injection)"].filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            hitsSink?(hits)
            let text = parts.joined(separator: "\n\n")
            return (template: text, expanded: text)

        case PromptSlot.dialogueExamplesId:
            guard !profile.chatExamples.isEmpty else { return nil }
            return (template: profile.chatExamples, expanded: profile.chatExamples)

        case PromptSlot.chatHistoryId:
            return nil

        default:
            return nil
        }
    }

    /// 宏替换：{{user}} / {{char}} / {{health}} / {{trading}} / {{date}} / {{time}}
    private static func applyMacros(_ text: String, profile: Profile, health: String, trading: String = "") -> String {
        MacroExpander.expand(text, userName: profile.userName, charName: profile.assistantName, health: health, trading: trading)
    }

    /// 解析对话示例为 user/assistant 消息对
    ///
    /// 格式支持：
    /// - `{{user}}: 内容` / `{{char}}: 内容`
    /// - `用户: 内容` / `AI: 内容`
    /// - `<START>` 分隔符（忽略）
    private static func parseChatExamples(_ text: String, profile: Profile) -> [(role: String, content: String)] {
        let lines = text.components(separatedBy: "\n")
        var messages: [(role: String, content: String)] = []

        let userPrefixes = ["{{user}}:", "\(profile.userName):", "用户:"]
        let charPrefixes = ["{{char}}:", "\(profile.assistantName):", "AI:"]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "<START>" || trimmed.hasPrefix("[Start") { continue }

            var matched = false
            for prefix in userPrefixes {
                if trimmed.hasPrefix(prefix) {
                    let content = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    if !content.isEmpty { messages.append((role: "user", content: content)) }
                    matched = true
                    break
                }
            }
            if matched { continue }

            for prefix in charPrefixes {
                if trimmed.hasPrefix(prefix) {
                    let content = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    if !content.isEmpty { messages.append((role: "assistant", content: content)) }
                    matched = true
                    break
                }
            }
        }

        return messages
    }
}
