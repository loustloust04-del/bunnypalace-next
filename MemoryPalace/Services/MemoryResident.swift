import Foundation
import SwiftData

/// 常驻记忆（plan-memory-audit-desk 第八½节）：每一轮都带的有哪些、为什么带、这一轮带没带。
/// 规则不另写一份：档案常驻层直接用 `activeRetrievers()` 里那一路 `PersistentRetriever`，{助手}的记忆用 `SelfMemoryInjection.fullCandidates`；
/// 「带没带」看同一次 `roundInputs` + `memoryLayers` 的结果（预览 = 实发）。只把现状摆出来，不改规则本身
enum MemoryResident {

    // MARK: - 规则

    /// 档案常驻层收谁：只有钉住的（C3 ② 起按类别常驻停掉）；三个检索开关都关 → nil（一条都不带）
    static func archiveRule() -> ((Memory) -> Bool)? {
        guard let persistent = MemoryInjector.activeRetrievers().lazy.compactMap({ $0 as? PersistentRetriever }).first else { return nil }
        return { !persistent.retrieve([$0], recent: []).isEmpty }
    }

    /// 记忆格普通列表里列谁（第八½节）：不搜的时候常驻的挪到常驻页、这里不列；搜索时照旧全列（不然搜不到钉住的）
    static func panelListed(_ active: [Memory], searching: Bool, rule: ((Memory) -> Bool)?) -> [Memory] {
        guard !searching, let rule else { return active }
        return active.filter { !rule($0) }
    }

    /// 实发的最后一道关卡（10-16 astra #6）：预设里记忆插槽关着（或被改成普通插槽）= 组装跳过整段记忆，同 `PromptAssembler` 的 activeSlots + isMarker
    static func memorySlotOn(_ preset: Preset) -> Bool {
        preset.prompts.contains { $0.id == PromptSlot.memoryInjectionId && $0.isEnabled && $0.isMarker }
    }

    // MARK: - 刷新

    /// 刷新代次（10-16 astra #3）：每次刷新领一个号，后台算完回来只收最新那个号的，旧结果不盖新结果
    struct LoadTicket {
        private(set) var current = 0

        mutating func next() -> Int {
            current += 1
            return current
        }

        func isLatest(_ n: Int) -> Bool { n == current }
    }

    struct IdentityKey: Equatable {
        let floorPersonaId: String?
        let conversationPersonaId: String?
        let persona: UserPersona?
        let userName: String
        let assistantName: String
        let userPersona: String

        init(profile: Profile?, conversationPersonaId: String?, personas: [UserPersona]) {
            floorPersonaId = profile?.personaId
            self.conversationPersonaId = conversationPersonaId
            let resolution = PersonaResolution.resolve(conversationPersonaId: conversationPersonaId,
                                                       floorPersonaId: profile?.personaId, personas: personas)
            persona = resolution.persona
            let effective = profile.map { resolution.applied(to: $0) }
            userName = effective?.userName ?? ""
            assistantName = effective?.assistantName ?? ""
            userPersona = effective?.userPersona ?? ""
        }
    }

    /// 刷新只观察已驻内存的值；外置 segmentsData 留给后台 context 读取。
    struct WikiNodeRevision: Equatable {
        let id: String
        let content: String
        let cardEditedAt: Date?
        let ccEdited: Bool
    }

    static func wikiNodes(in path: [MessageNode], excluding excludeId: String? = nil) -> [MessageNode] {
        var recent: [MessageNode] = []
        for node in path.reversed() {
            guard node.id != excludeId, !node.isSyntheticRoot, !node.isSourceHidden,
                  node.role == "user" || node.role == "assistant" else { continue }
            recent.append(node)
            if recent.count == WikiInjection.windowSize { break }
        }
        return recent.reversed()
    }

    static func wikiRevisions(in path: [MessageNode]) -> [WikiNodeRevision] {
        wikiNodes(in: path).map {
            WikiNodeRevision(id: $0.id, content: $0.content,
                             cardEditedAt: $0.cardEditedAt, ccEdited: $0.ccEdited)
        }
    }

    private static let wikiThinkingDelimiters = [("<think>", "</think>"), ("<thinking>", "</thinking>"),
                                                 ("[thinking]", "[/thinking]")]

    static func wikiScanBody(_ node: MessageNode) -> String {
        // 用户消息和历史窗口同口径只认正文（分段只有助手那边才分思考 / 正文）
        guard node.role == "assistant" else { return node.content }
        if let segments = node.segments, segments.contains(where: {
            switch $0 {
            case .text, .thinking: return true
            default: return false
            }
        }) {
            return segments.compactMap { segment -> String? in
                if case .text(let text) = segment { return text }
                return nil
            }.joined(separator: "\n\n")
        }
        var content = node.content
        while true {
            let leading = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (open, close) = wikiThinkingDelimiters.first(where: {
                leading.range(of: $0.0, options: [.anchored, .caseInsensitive]) != nil
            }) else {
                return content
            }
            let contentStart = leading.index(leading.startIndex, offsetBy: open.count)
            guard let end = leading.range(of: close, options: .caseInsensitive,
                                          range: contentStart..<leading.endIndex) else {
                return ""
            }
            let thinking = leading[contentStart..<end.lowerBound]
            let block = ContentCleaner.extractThinking(from: "[thinking]\(thinking)[/thinking]")
            content = (block.content + leading[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// ids 已由主线程按真实节点截成四条；只在后台自己的 context 里读正文和外置分段。
    static func wikiMessages(nodeIds: [String], context: ModelContext) -> [String] {
        nodeIds.compactMap { id in
            var descriptor = FetchDescriptor<MessageNode>(predicate: #Predicate<MessageNode> { $0.id == id })
            descriptor.fetchLimit = 1
            guard let node = try? context.fetch(descriptor).first,
                  !node.isSyntheticRoot, !node.isSourceHidden,
                  node.role == "user" || node.role == "assistant" else { return nil }
            return wikiScanBody(node)
        }
    }

    /// 刷新键里的注入设置（10-16 astra #7）：总开关、C / B4 勾、预算、{助手}的记忆预算比例和最近 N 条、三个检索开关、目录模式。
    /// 读 UserDefaults 内存值，不碰盘；别的窗口（mac 设置窗）改了，比这份快照就知道要重算
    static let settingsKeys = ["mem_master", MemoryOpenWindow.cKey, MemoryOpenWindow.b4Key, "mem_inject_budget",
                               "mem_self_budget_percent", "mem_self_recent_count", "mem_inject_keyword", "mem_inject_full",
                               "mem_inject_vector", "mem_inject_catalog"]

    /// 末尾带 C 档案的版本（wiki 页 / 索引 / 不触发的词改了就变，`WikiInjectionCache`，只读内存）
    static func settingsStamp(_ defaults: UserDefaults = .standard, wikiVersion: Int = WikiInjectionCache.shared.version) -> [String] {
        settingsKeys.map { k in defaults.object(forKey: k).map { "\($0)" } ?? "-" } + ["wiki \(wikiVersion)"]
    }

    // MARK: - 原因

    /// 档案那条为什么每一轮都带：钉住的 →「你钉的」；否则 →「标成{类别}」
    static func reason(_ m: Memory) -> String {
        m.isUserExplicit ? "你钉的" : "标成\(MemoryCardView.categoryLabels[m.category] ?? m.category)"
    }

    /// {助手}的记忆为什么带全文（名字、条数都是变量）
    static func reason(_ r: SelfMemoryInjection.Reason, assistant: String, recentCount: Int = MemoryFlags.selfRecentCount) -> String {
        switch r {
        case .five: return "\(assistant)的记忆 · 重要度 5"
        case .recent: return "\(assistant)的记忆 · 最近 \(recentCount) 条"
        }
    }

    // MARK: - 这一轮带不带（灰字）

    enum Gate: Equatable {
        case memoryOff          // 总开关关 / 这个对话关了记忆
        case slotOff            // 当前预设没开记忆插槽（10-16 astra #6）
        case archiveUnchecked   // 【开窗口】C 没勾
        case selfUnchecked      // 【开窗口】B4 没勾
        case overBudget         // 规则上算常驻，预算装不下

        var text: String {
            switch self {
            case .memoryOff: return "记忆关着，现在不带"
            case .slotOff: return "预设没开记忆插槽，现在不带"
            case .archiveUnchecked: return "\(MemoryWriterID.c.code) 没勾，现在不带"
            case .selfUnchecked: return "\(MemoryWriterID.b4.code) 没勾，现在不带"
            case .overBudget: return "超出注入预算，这一轮没带"
            }
        }
    }

    struct ArchiveRow: Identifiable {
        let memory: Memory
        let reason: String
        let gate: Gate?
        var id: UUID { memory.id }
    }

    /// 档案那条的判定结果（只带 id，不带 @Model 对象：后台算好交回主线程）
    struct ArchiveGate: Equatable, Sendable {
        let id: UUID
        let gate: Gate?
    }

    struct WikiRow: Equatable {
        let indexCount: Int
        let hits: [WikiPageHit]
        let gate: Gate?

        var text: String { WikiInjection.residentLine(indexCount: indexCount, hits: hits) }
    }

    struct SelfRow: Identifiable {
        let memory: SelfMemory
        let reason: String
        let gate: Gate?
        var id: String { memory.slug }
    }

    /// 后台算好的一份（不含 @Model 对象，可以跨线程）
    struct Summary {
        var archive: [ArchiveGate] = []
        var selfRows: [SelfRow] = []
        /// 全量注入开着时，常驻层以外也每一轮都带的档案条数（预算内）
        var fullFallbackCount = 0
        /// 下半「下一轮会看见什么」：同一次 memoryLayers 的两段
        var stable = ""
        var volatile = ""
        /// 下半底部那行「共 N 条」：这一轮带的档案 + {助手}的记忆（全文 + 目录），同原来的预览口径
        var memoryCount = 0
        /// C 档案那一行：根索引几行、这一轮命中哪几页（wiki 空 = nil，不显示这一行）
        var wiki: WikiRow?

        var count: Int { archive.count + selfRows.count }
        var grayCount: Int { archive.filter { $0.gate != nil }.count + selfRows.filter { $0.gate != nil }.count }

        /// 主线程复核（10-16 astra #3）：后台算完到交回主线程之间被删（失效 / 彻底删）、取消钉住、规则变了的档案不再列。
        /// memories = 主线程这边的最新档案（按 id 找，找不到 = 彻底删了）
        func revalidated(_ memories: [Memory], rule: ((Memory) -> Bool)? = MemoryResident.archiveRule()) -> Summary {
            let byId = Dictionary(memories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var s = self
            s.archive = archive.filter { g in
                guard let m = byId[g.id], m.supersededAt == nil, let rule else { return false }
                return rule(m)
            }
            return s
        }
    }

    /// 主线程那份：档案按 id 换成主线程 context 里的对象（改类别 / 取消钉住要用）；复核不过的（刚被删 / 取消钉住）不列，
    /// `dropped` > 0 = 下半预览也是旧的，调用方该重算一次
    struct Snapshot {
        var summary = Summary()
        var archive: [ArchiveRow] = []
        var dropped = 0

        init() {}

        init(_ summary: Summary, memories: [Memory]) {
            let checked = summary.revalidated(memories)
            self.summary = checked
            dropped = summary.archive.count - checked.archive.count
            let byId = Dictionary(memories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            archive = checked.archive.compactMap { g in byId[g.id].map { ArchiveRow(memory: $0, reason: MemoryResident.reason($0), gate: g.gate) } }
        }

        var selfRows: [SelfRow] { summary.selfRows }
        var fullFallbackCount: Int { summary.fullFallbackCount }
        var stable: String { summary.stable }
        var volatile: String { summary.volatile }
        var memoryCount: Int { summary.memoryCount }
        var wiki: WikiRow? { summary.wiki }
        var count: Int { archive.count + selfRows.count }
    }

    /// 纯函数：把已经算好的（同一次 roundInputs + memoryLayers）摆成每一行。
    /// - archive：规则上常驻的档案（活着的，按创建时间旧→新，同常驻层的行序）；injectedIds = hits 里 `persistent` 那一路
    /// - selfCandidates：全文候选；fullSlugs = 实际装进全文的（B4 没勾时 nil）
    /// - slotOn：当前预设开没开记忆插槽；关着 = 整段不发，全部灰字（记忆关着优先说那个）
    static func compute(archive: [Memory], injectedIds: Set<UUID>, selfCandidates: [(memory: SelfMemory, reason: SelfMemoryInjection.Reason)],
                        fullSlugs: Set<String>?, memoryOn: Bool, cChecked: Bool, assistant: String, recentCount: Int,
                        slotOn: Bool = true) -> Summary {
        var s = Summary()
        s.archive = archive.map { m in
            ArchiveGate(id: m.id, gate: !memoryOn ? .memoryOff : !slotOn ? .slotOff : !cChecked ? .archiveUnchecked
                        : injectedIds.contains(m.id) ? nil : .overBudget)
        }
        s.selfRows = selfCandidates.map { c in
            let gate: Gate?
            if !memoryOn { gate = .memoryOff }
            else if !slotOn { gate = .slotOff }
            else if let full = fullSlugs { gate = full.contains(c.memory.slug) ? nil : .overBudget }
            else { gate = .selfUnchecked }
            return SelfRow(memory: c.memory, reason: reason(c.reason, assistant: assistant, recentCount: recentCount), gate: gate)
        }
        return s
    }

    /// 跑一遍实发那几个函数，上下两半都用这一次的结果。recentMessages = 当前对话最近几条（触发词 / 关键词按它算；空 = 按「刚开始聊」）。
    /// 读{助手}的记忆文件、组装注入都在这里：**在后台调**（自己开一个 ModelContext，主线程只接 `Summary`）。
    /// selfMemories = 调用方已经读好的{助手}的记忆（记忆格刷新时后台读过一份），给了就不再为列候选读一遍。
    /// slotOn = 当前预设开没开记忆插槽（`memorySlotOn`）；availableTools = 这一轮调得到的工具名（nil = 不知道，尾注原样），
    /// 下半预览照实发过一遍 `PromptAssembler.droppingOffToolMentions`（10-16 astra #6）
    static func summary(profile: Profile, conversationMemoryEnabled: Bool, container: ModelContainer,
                        selfMemories: [SelfMemory]? = nil, slotOn: Bool = true, availableTools: Set<String>? = nil,
                        recentMessages: [String] = [], recentNodeIds: [String]? = nil, wikiStore: WikiStore? = nil) -> Summary {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let recentMessages = recentNodeIds.map { wikiMessages(nodeIds: $0, context: context) } ?? recentMessages
        let store = SwiftDataMemoryStore()
        let inputs = MemoryInjector.roundInputs(profileId: profile.id, conversationMemoryEnabled: conversationMemoryEnabled,
                                                store: store, context: context, wikiStore: wikiStore)
        let layers = PromptAssembler.memoryLayers(profile: profile,
                                                  selfMemory: (inputs.selfMemory?.text).flatMap { $0.isEmpty ? nil : $0 },
                                                  memories: inputs.memories, recentMessages: recentMessages, budget: inputs.archiveBudget,
                                                  wiki: inputs.wiki)
        let memoryOn = MemoryFlags.masterEnabled && conversationMemoryEnabled
        let cChecked = MemoryOpenWindow.isChecked(.c)
        // C 没勾 / 记忆关着时 roundInputs 给的档案是空的：列表另取活着的，全部标灰
        let active = memoryOn && cChecked ? inputs.memories : store.listActive(profileId: profile.id, context: context)
        let archive = archiveRule().map { rule in active.filter(rule).sorted { $0.createdAt < $1.createdAt } } ?? []
        let recentCount = MemoryFlags.selfRecentCount
        let assistant = profile.assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = compute(archive: archive,
                        injectedIds: Set(layers.hits.filter { $0.retrieverId == "persistent" }.map(\.memoryId)),
                        selfCandidates: SelfMemoryInjection.fullCandidates(selfMemories ?? SelfMemoryStore.list(profileId: profile.id),
                                                                           recentCount: recentCount),
                        fullSlugs: inputs.selfMemory?.fullSlugs, memoryOn: memoryOn, cChecked: cChecked,
                        assistant: assistant.isEmpty ? "助手" : assistant, recentCount: recentCount, slotOn: slotOn)
        // C 档案：没勾 / 记忆关着也列出来（灰字），快照另取
        let wiki = inputs.wiki ?? WikiInjectionCache.shared.snapshot(profileId: profile.id, store: wikiStore)
        if let wiki, !wiki.indexLines.isEmpty || !wiki.pages.isEmpty {
            let gate: Gate? = !memoryOn ? .memoryOff : !slotOn ? .slotOff : !cChecked ? .archiveUnchecked : nil
            s.wiki = WikiRow(indexCount: wiki.indexLines.count, hits: gate == nil ? layers.pages : [], gate: gate)
        }
        // 插槽关着：实发整段跳过，下半预览、「共 N 条」、全量兜底都是空的
        guard slotOn else { return s }
        s.fullFallbackCount = layers.hits.filter { $0.retrieverId == "fullFallback" }.count
        s.stable = availableTools.map { PromptAssembler.droppingOffToolMentions(layers.stable, available: $0) } ?? layers.stable
        s.volatile = availableTools.map { PromptAssembler.droppingOffToolMentions(layers.volatile, available: $0) } ?? layers.volatile
        s.memoryCount = inputs.memories.count + (inputs.selfMemory?.fullCount ?? 0) + (inputs.selfMemory?.indexCount ?? 0)
        return s
    }

    /// 后台算一份，回主线程交出来
    static func loadSummary(profile: Profile, conversationMemoryEnabled: Bool, container: ModelContainer,
                            selfMemories: [SelfMemory]? = nil, slotOn: Bool = true, availableTools: Set<String>? = nil,
                            recentNodeIds: [String] = [], wikiStore: WikiStore? = nil) async -> Summary {
        await Task.detached(priority: .userInitiated) {
            summary(profile: profile, conversationMemoryEnabled: conversationMemoryEnabled, container: container, selfMemories: selfMemories,
                    slotOn: slotOn, availableTools: availableTools, recentNodeIds: recentNodeIds, wikiStore: wikiStore)
        }.value
    }
}
