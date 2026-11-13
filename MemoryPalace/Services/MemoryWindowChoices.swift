import MemoryCore
import Foundation
import SwiftData

// MARK: - 读侧段④：本窗六项（Z3–Z8）+ 上个窗口（plan-recall-slice-4）

/// 纸条上的六项。人设、本窗口摘要（A2）、工具说明不在这里，照旧
enum MemoryNoteItem: String, CaseIterable, Identifiable, Codable, Sendable {
    case timeline, pending, selfMemory, archive, previousWindow, pinned

    var id: String { rawValue }

    func title(assistant: String) -> String {
        switch self {
        case .timeline: return "时间轴"
        case .pending: return "待续"
        case .selfMemory: return "\(assistant)的记忆"
        case .archive: return "档案"
        case .previousWindow: return "上一个窗口最后几条"
        case .pinned: return "钉住的"
        }
    }

    /// 纸条新增的三勾的楼层默认键（时间轴 / B4 / 档案沿用开窗口页原来那三勾）
    var defaultsKey: String? {
        switch self {
        case .pending: return "mem_open_pending"
        case .previousWindow: return "mem_open_prev"
        case .pinned: return "mem_open_pinned"
        default: return nil
        }
    }
}

struct MemoryWindowChoices: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var timeline: Bool
    var pending: Bool
    var selfMemory: Bool
    var archive: Bool
    var previousWindow: Bool
    var pinned: Bool

    subscript(_ item: MemoryNoteItem) -> Bool {
        get {
            switch item {
            case .timeline: return timeline
            case .pending: return pending
            case .selfMemory: return selfMemory
            case .archive: return archive
            case .previousWindow: return previousWindow
            case .pinned: return pinned
            }
        }
        set {
            switch item {
            case .timeline: timeline = newValue
            case .pending: pending = newValue
            case .selfMemory: selfMemory = newValue
            case .archive: archive = newValue
            case .previousWindow: previousWindow = newValue
            case .pinned: pinned = newValue
            }
        }
    }

    static let allOff = MemoryWindowChoices(timeline: false, pending: false, selfMemory: false,
                                            archive: false, previousWindow: false, pinned: false)

    /// 新窗档案 = 根索引勾或档案触发开；其余三项读新键（没写过 = 开）。
    static func defaults(profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) -> MemoryWindowChoices {
        func extra(_ item: MemoryNoteItem) -> Bool {
            item.defaultsKey.flatMap { MemoryOpenWindowStore.load(key: $0, profileId: profileId, defaults: defaults) } ?? true
        }
        return MemoryWindowChoices(timeline: MemoryOpenWindow.isChecked(.a4, profileId: profileId, defaults: defaults),
                                   pending: extra(.pending),
                                   selfMemory: MemoryOpenWindow.isChecked(.b4, profileId: profileId, defaults: defaults),
                                   archive: MemoryOpenWindow.isChecked(.c, profileId: profileId, defaults: defaults)
                                       || RecallTuningStore.load(profileId: profileId, defaults: defaults).archiveTriggerEnabled,
                                   previousWindow: extra(.previousWindow),
                                   pinned: extra(.pinned))
    }

    /// 老窗（没存选择）：逐字等于今天——待续跟时间轴一勾、钉住跟档案一勾、没有上个窗口
    static func legacy(profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) -> MemoryWindowChoices {
        let a4 = MemoryOpenWindow.isChecked(.a4, profileId: profileId, defaults: defaults)
        let c = MemoryOpenWindow.isChecked(.c, profileId: profileId, defaults: defaults)
        return MemoryWindowChoices(timeline: a4, pending: a4,
                                   selfMemory: MemoryOpenWindow.isChecked(.b4, profileId: profileId, defaults: defaults),
                                   archive: c, previousWindow: false, pinned: c)
    }

    static func setDefault(_ item: MemoryNoteItem, _ on: Bool, profileId: String, defaults: UserDefaults = .standard) {
        switch item {
        case .timeline: MemoryOpenWindowStore.save(.a4, on, profileId: profileId, defaults: defaults)
        case .selfMemory: MemoryOpenWindowStore.save(.b4, on, profileId: profileId, defaults: defaults)
        case .archive: MemoryOpenWindowStore.save(.c, on, profileId: profileId, defaults: defaults)
        default:
            if let key = item.defaultsKey { MemoryOpenWindowStore.save(key: key, on, profileId: profileId, defaults: defaults) }
        }
    }
}

/// 「新开窗口先弹纸条」（楼层档，没写过 = 开）
enum MemoryOpenWindowNote {
    static let key = "mem_open_note"

    static func enabled(profileId: String, defaults: UserDefaults = MemoryReadEnvironment.defaults) -> Bool {
        MemoryOpenWindowStore.load(key: key, profileId: profileId, defaults: defaults) ?? true
    }

    static func set(_ on: Bool, profileId: String, defaults: UserDefaults = .standard) {
        MemoryOpenWindowStore.save(key: key, on, profileId: profileId, defaults: defaults)
    }
}

// MARK: - 上个窗口的冻结快照

struct PreviousWindowSnapshot: Codable, Equatable, Sendable {
    struct Message: Codable, Equatable, Sendable {
        var nodeId: String
        var role: String
        var createTime: Date?
        var text: String
    }

    enum Invalid: String, Codable, Sendable {
        case deleted, memoryOff, missing

        var label: String {
            switch self {
            case .deleted: return "源窗口已删除"
            case .memoryOff: return "源窗口已关闭记忆参与"
            case .missing: return "源窗口找不到了"
            }
        }
    }

    var schemaVersion = 1
    var sourceId: String
    var sourceTitle: String
    var leafId: String
    var capturedAt: Date
    var messages: [Message]
    var invalid: Invalid? = nil

    /// 失效一次就不复活：正文清掉，只留来源占位
    mutating func invalidate(_ reason: Invalid) {
        guard invalid == nil else { return }
        invalid = reason
        messages = []
    }

    /// E2-7b r4：恢复冻结时源窗已经不在 / 进了回收站 → 直接落一份不可逆占位（不新增存储字段）
    static func deletedPlaceholder(sourceId: String) -> PreviousWindowSnapshot {
        var snapshot = PreviousWindowSnapshot(sourceId: sourceId, sourceTitle: "", leafId: "",
                                              capturedAt: Date(), messages: [])
        snapshot.invalidate(.deleted)
        return snapshot
    }

    /// 进 system 段。从最新一条往回装，预算放不下的最早几条不带（写明几条）；一条都放不下 = 空。
    func render(user: String, assistant: String, budget: Int) -> (text: String, tokens: Int, count: Int) {
        guard invalid == nil, !messages.isEmpty, budget > 0 else { return ("", 0, 0) }
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        func head(_ count: Int, dropped: Int) -> String {
            "[上一个窗口]（《\(title.isEmpty ? "没有标题的窗口" : title)》最后 \(count) 条，开这个窗口时记下的；只为接上话头，不是这个窗口里说过的话"
                + (dropped > 0 ? "；更早的 \(dropped) 条放不下，没带" : "") + "）"
        }
        func line(_ m: Message) -> String { "\(m.role == "user" ? user : assistant)：\(m.text)" }
        var kept: [String] = []
        for m in messages.reversed() {
            let candidate = [line(m)] + kept
            let text = head(candidate.count, dropped: messages.count - candidate.count) + "\n" + candidate.joined(separator: "\n")
            guard Memory.estimateTokens(text) <= budget else { break }
            kept = candidate
        }
        guard !kept.isEmpty else { return ("", 0, 0) }
        let text = head(kept.count, dropped: messages.count - kept.count) + "\n" + kept.joined(separator: "\n")
        return (text, Memory.estimateTokens(text), kept.count)
    }
}

extension Conversation {
    var memoryWindowChoices: MemoryWindowChoices? {
        get { memoryWindowChoicesData.flatMap { try? JSONDecoder().decode(MemoryWindowChoices.self, from: $0) } }
        set { memoryWindowChoicesData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var previousWindowSnapshot: PreviousWindowSnapshot? {
        get { previousWindowSnapshotData.flatMap { try? JSONDecoder().decode(PreviousWindowSnapshot.self, from: $0) } }
        set { previousWindowSnapshotData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

// MARK: - 选上个窗口 / 冻结 / 复核

enum PreviousWindowPicker {
    /// 冻结副本最多 50 条，每条最多 4000 字，避免复制超长源消息。
    static let maximumMessages = 50
    static let maximumMessageCharacters = 4_000

    /// 在花园里直接聊的窗口（新建的 api / 卡楼层的 sillytavern），不含导入归档、群聊归档
    static func isLiveChat(_ c: Conversation) -> Bool {
        (c.provider == "api" || c.provider == "sillytavern") && c.importBatchId == nil && c.archiveKind == nil
    }

    /// 同楼层、没进回收站、允许记忆、直接聊的窗口
    static func eligible(_ c: Conversation, profileId: String) -> Bool {
        c.profileId == profileId && !c.isTrashed && c.memoryEnabled && isLiveChat(c)
    }

    static func visible(_ node: MessageNode) -> Bool {
        (node.role == "user" || node.role == "assistant") && !node.isTrashed && !node.isSourceHidden && !node.isSyntheticRoot
            && !node.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 最后一次真实交互取 max(本机戳, 最新合格提供商回复时间)，兼容跨设备戳缺失或较旧。
    /// CC 回复带 ccMessageId、自主消息带 agentOrigin，都不算。同刻按 id 稳定排序，不看打开时间。
    static func latest(profileId: String, excluding: String, context: ModelContext) -> Conversation? {
        var best: (at: Date, conversation: Conversation)?
        func consider(_ at: Date, _ c: Conversation) {
            guard c.id != excluding, eligible(c, profileId: profileId) else { return }
            if let b = best, b.at > at || (b.at == at && b.conversation.id <= c.id) { return }
            best = (at, c)
        }
        // optional 字段不进 predicate（SwiftData 坑）：按它倒序取（NULL 垫底），内存里挑有值的
        var stamped = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.profileId == profileId && $0.isTrashed == false },
            sortBy: [SortDescriptor(\.lastRealChatAt, order: .reverse)])
        stamped.fetchLimit = 32
        for c in (try? context.fetch(stamped)) ?? [] {
            if let at = c.lastRealChatAt { consider(at, c) }
        }
        // E2-7b：最新一条 assistant 节点不比现有戳新 → 下面第一轮就 break，扫描改不了结果。
        // 先探一条（1 次取回）省掉 256 条节点材料化；相等仍要扫（同刻按 id 破并列）
        if let cutoff = best?.at {
            var probe = FetchDescriptor<MessageNode>(
                predicate: #Predicate { $0.profileId == profileId && $0.role == "assistant" && $0.isTrashed == false },
                sortBy: [SortDescriptor(\.createTime, order: .reverse)])
            probe.fetchLimit = 1
            if let newest = (try? context.fetch(probe))?.first?.createTime, newest < cutoff {
                return best?.conversation
            }
        }
        var nodes = FetchDescriptor<MessageNode>(
            predicate: #Predicate { $0.profileId == profileId && $0.role == "assistant" && $0.isTrashed == false },
            sortBy: [SortDescriptor(\.createTime, order: .reverse)])
        nodes.fetchLimit = 256
        var seen = Set<String>()
        for node in (try? context.fetch(nodes)) ?? [] {
            guard let at = node.createTime else { continue }
            if let b = best, b.at > at { break }
            guard visible(node), node.ccMessageId == nil, node.agentOrigin == nil,
                  seen.insert(node.conversationId).inserted else { continue }
            let cid = node.conversationId
            var one = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId == profileId })
            one.fetchLimit = 1
            guard let c = try? context.fetch(one).first else { continue }
            consider(max(at, c.lastRealChatAt ?? at), c)
        }
        return best?.conversation
    }

    /// 源窗选中分支（包里 `visiblePath` 单口径）最后 count 条可见 user / assistant；不整窗取。
    /// 正文去首尾空白后截 4000 字；去空白后为空的条目（附件 / 空白消息）不进快照。
    /// E2-7b：从路径尾部往前凑够即停（不再对整条路径逐条 trim），结果与 `suffix(count)` 逐字相同。
    static func capture(_ window: ConversationWindow, count: Int, from source: any ConversationSource,
                        now: Date = Date()) -> PreviousWindowSnapshot {
        let nodes = (try? source.nodes(profileId: window.profileId, conversationId: window.id)) ?? []
        return capture(window, count: count, path: visiblePath(window: window, nodes: nodes), now: now)
    }

    /// 已算好的路径 → 倒序凑够（后台版在取节点 / 算路径两处之外复用同一段，结果逐字相同）
    static func capture(_ window: ConversationWindow, count: Int, path: [ConversationMessage],
                        now: Date = Date()) -> PreviousWindowSnapshot {
        let limit = min(max(count, 0), maximumMessages)
        var kept: [PreviousWindowSnapshot.Message] = []
        kept.reserveCapacity(limit)
        if limit > 0 {
            for node in path.reversed() {
                let text = String(node.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumMessageCharacters))
                guard !text.isEmpty else { continue }
                kept.append(.init(nodeId: node.id, role: node.role, createTime: node.createTime, text: text))
                if kept.count == limit { break }
            }
        }
        return PreviousWindowSnapshot(sourceId: window.id, sourceTitle: window.title, leafId: window.currentNodeId,
                                      capturedAt: now, messages: Array(kept.reversed()))
    }

    /// 现有调用方（freeze / 测试）的薄重载：源窗在调用方 context 里，读走自开 context 的协议实现（先 save 才能看见未落盘的改动）
    static func capture(_ source: Conversation, count: Int, context: ModelContext, now: Date = Date()) -> PreviousWindowSnapshot {
        capture(SwiftDataConversationSource.window(source), count: count,
                from: SwiftDataConversationSource(container: context.container), now: now)
    }

    /// 组装前复核：源窗没了 / 进回收站 / 关了记忆参与 / 换了楼层 → 失效（清正文），不换另一个窗口顶上
    static func validate(_ snapshot: PreviousWindowSnapshot, profileId: String, context: ModelContext) -> PreviousWindowSnapshot {
        guard snapshot.invalid == nil else { return snapshot }
        var out = snapshot
        let sid = snapshot.sourceId
        var one = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == sid && $0.profileId == profileId })
        one.fetchLimit = 1
        if let source = try? context.fetch(one).first {
            if source.isTrashed { out.invalidate(.deleted) } else if !source.memoryEnabled { out.invalidate(.memoryOff) }
            return out
        }
        // 本楼层没有：全库再看一眼 —— 有这行 = 换楼层了（.missing），没有 = 删了（.deleted）
        var any = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == sid })
        any.fetchLimit = 1
        if (try? context.fetch(any).first) != nil { out.invalidate(.missing) } else { out.invalidate(.deleted) }
        return out
    }

    /// 源窗删除：引用它的目标窗副本一并清正文（只留来源不可用占位）
    static func invalidateCopies(of sourceIds: Set<String>, context: ModelContext) {
        guard !sourceIds.isEmpty else { return }
        // id 全库唯一；目标窗可能已迁层，不能只查源楼层。optional 字段在内存里比，避开 SwiftData predicate 坑。
        for target in (try? context.fetch(FetchDescriptor<Conversation>())) ?? [] {
            guard let sourceId = target.previousWindowId, sourceIds.contains(sourceId) else { continue }
            guard var snapshot = target.previousWindowSnapshot, snapshot.invalid == nil else { continue }
            snapshot.invalidate(.deleted)
            target.previousWindowSnapshot = snapshot
        }
    }

    /// E2-7b：冻结拆两段。主线程同步段不再随正文量增长；仍含 `latest` 探针 fetch（≤256 条）、
    /// `RecallTuningStore.load`、选择落值（perf 测试量的是这一段）。正文抓取交给后台。
    struct FreezePlan: Sendable {
        let window: ConversationWindow
        let count: Int
    }

    /// 同步部分：选择取楼层默认；上窗在「上一个窗口」默认勾着、或要弹纸条（她可能当场勾上）时选源窗。已经冻结过的不重来
    @discardableResult
    static func prepareFreeze(_ conversation: Conversation, context: ModelContext, forNote: Bool = false) -> FreezePlan? {
        guard conversation.memoryWindowChoicesData == nil else { return nil }
        let choices = MemoryWindowChoices.defaults(profileId: conversation.profileId)
        conversation.memoryWindowChoices = choices
        guard choices.previousWindow || forNote,
              let source = latest(profileId: conversation.profileId, excluding: conversation.id, context: context) else { return nil }
        conversation.previousWindowId = source.id
        return FreezePlan(window: SwiftDataConversationSource.window(source),
                          count: RecallTuningStore.load(profileId: conversation.profileId).previousWindowMessages)
    }

    /// 后台抓正文：自开 context，不碰主线程的 `Conversation` 模型对象（只吃值）。
    /// 非隔离 async = 本来就在协作线程池跑，不用 `Task.detached`（那样也不继承取消）；
    /// 取消在「取节点前」「算路径后」两处提前退出，返回 nil 让调用方丢弃
    static func captureInBackground(_ plan: FreezePlan, container: ModelContainer, now: Date = Date()) async -> PreviousWindowSnapshot? {
        #if DEBUG
        // 模拟不可取消的取节点段（真实 `source.nodes(...)` 不响应取消）；取消只在它之后生效
        if let delay = debugCaptureDelay {
            let parts = delay.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { c.resume() }
            }
        }
        #endif
        if Task.isCancelled { return nil }
        let source = SwiftDataConversationSource(container: container)
        let nodes = (try? source.nodes(profileId: plan.window.profileId, conversationId: plan.window.id)) ?? []
        let path = visiblePath(window: plan.window, nodes: nodes)
        if Task.isCancelled { return nil }
        return capture(plan.window, count: plan.count, path: path, now: now)
    }

    #if DEBUG
    /// 测试钩子：`captureInBackground` 抓正文前先睡这么久（模拟大窗 / 慢机器，钉住「冻结没落定就发首句」的等待）。生产恒 nil
    nonisolated(unsafe) static var debugCaptureDelay: Duration?
    #endif

    /// 同步全套（测试 / live 冒烟用）；App 走 `prepareFreeze` + `captureInBackground`，主线程不抓正文
    static func freeze(_ conversation: Conversation, context: ModelContext, forNote: Bool = false, now: Date = Date()) {
        guard let plan = prepareFreeze(conversation, context: context, forNote: forNote) else { return }
        conversation.previousWindowSnapshot = capture(plan.window, count: plan.count,
                                                     from: SwiftDataConversationSource(container: context.container), now: now)
    }
}

// MARK: - 纸条上每一行「是什么 / 多少 token」（窗口透视）

struct MemoryNotePreviewRow: Equatable, Identifiable {
    let item: MemoryNoteItem
    /// 一句话：这项现在会带什么
    let summary: String
    /// 约多少 token（和实发同一批构件函数算；聊到才带的部分不计）
    let tokens: Int
    /// 有没有东西可带
    var available: Bool { tokens > 0 }
    var id: String { item.rawValue }
}

enum MemoryNotePreview {
    static func rows(profile: Profile, conversationId: String, snapshot: PreviousWindowSnapshot?,
                     store: MemoryStore, context: ModelContext, wiki: WikiInjectionSnapshot?, now: Date = MemoryClock.now,
                     previousPending: Bool = false) -> [MemoryNotePreviewRow] {
        let pid = profile.id
        let names = EffectiveCharacterContext(profile: profile)
        let pending = PendingStore.openByConversationCached(profileId: pid, floorMemoryRoot: FileLibraryStore.memoryRoot(profileId: pid))
        let timeline = TimelineStore.injection(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), now: now, currentConversationId: conversationId, windowIds: [],
                                               openPending: { [:] }, timelineLines: true)
        let pendingOnly = TimelineStore.injection(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), now: now, currentConversationId: conversationId, windowIds: [],
                                                  openPending: { pending }, timelineLines: false)
        let pendingCount = pendingOnly.text.map { $0.split(separator: "\n").filter { $0.hasPrefix("- ") }.count } ?? 0
        let selfBuilt = SelfMemoryInjection.build(SelfMemoryStore.list(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid), checkPath: AppPaths.checked), recentCount: MemoryFlags.selfRecentCount,
                                                  budget: MemoryInjector.tokenBudget * MemoryFlags.selfBudgetPercent / 100)
        let injectable = store.listActive(profileId: pid, context: context).filter(MemoryInjector.isInjectable)
        let pinned = injectable.filter(\.isUserExplicit)
        let archiveTitle = PromptAssembler.archiveLabel(profile)
        let pinnedText = pinned.isEmpty ? "" : "[\(archiveTitle)]\n" + pinned.map {
            MemoryInjector.injectionPayload($0, stable: true, catalog: false, now: now).text
        }.joined(separator: "\n")
        let root = wiki.map { WikiInjection.indexBlock($0, user: profile.userName) } ?? ""
        let rootLines = wiki?.indexLines.filter { $0.hasPrefix("- ") }.count ?? 0
        let triggerOn = RecallTuningStore.load(profileId: pid).archiveTriggerEnabled
        let fragments = injectable.filter { !$0.isUserExplicit }
        let fragmentText = triggerOn ? "" : MemoryInjector.buildInjectionSplit(memories: fragments, recentMessages: [],
                                                                               budget: MemoryInjector.tokenBudget, now: now).volatile
        let previous = snapshot.map { $0.render(user: names.userName, assistant: names.charName, budget: MemoryInjector.tokenBudget) }

        func tokens(_ text: String?) -> Int { text.map { $0.isEmpty ? 0 : Memory.estimateTokens($0) } ?? 0 }
        let archiveSummary: String = {
            var parts: [String] = []
            parts.append(wiki == nil ? "目录还没读好" : (rootLines > 0 ? "目录 \(rootLines) 页" : "还没有档案页"))
            if !triggerOn, !fragments.isEmpty { parts.append("留下的碎片 \(fragments.count) 条") }
            parts.append("聊到哪页带哪页另算")
            return parts.joined(separator: "，")
        }()
        let previousSummary: String = {
            guard let snapshot else { return previousPending ? "正在读取上个窗口…" : "没有上一个窗口" }
            if let invalid = snapshot.invalid { return invalid.label }
            let title = snapshot.sourceTitle.isEmpty ? "没有标题的窗口" : snapshot.sourceTitle
            return "《\(title)》最后 \(snapshot.messages.count) 条"
        }()
        return [
            .init(item: .timeline, summary: timeline.text == nil ? "这几天还没有" : "最近 \(TimelineStore.injectDays) 天，今天、昨天带各时段",
                  tokens: tokens(timeline.text)),
            .init(item: .pending, summary: pendingCount == 0 ? "没有没做完的" : "\(pendingCount) 个窗口有没做完的",
                  tokens: tokens(pendingOnly.text)),
            .init(item: .selfMemory, summary: selfBuilt.fullCount + selfBuilt.indexCount == 0 ? "还没有"
                    : "\(selfBuilt.fullCount) 条全文" + (selfBuilt.indexCount > 0 ? "，\(selfBuilt.indexCount) 条只带标题" : ""),
                  tokens: selfBuilt.tokens),
            .init(item: .archive, summary: archiveSummary, tokens: tokens(root) + tokens(fragmentText)),
            .init(item: .previousWindow, summary: previousSummary, tokens: previous?.tokens ?? 0),
            .init(item: .pinned, summary: pinned.isEmpty ? "没有钉住的" : "\(pinned.count) 条", tokens: tokens(pinnedText)),
        ]
    }

    /// 勾上的各项合计，和每项占合计的百分之几（四舍五入；合计 0 时都是 0）
    static func share(_ rows: [MemoryNotePreviewRow], choices: MemoryWindowChoices) -> (total: Int, percent: [MemoryNoteItem: Int]) {
        let total = rows.filter { choices[$0.item] }.map(\.tokens).reduce(0, +)
        var percent: [MemoryNoteItem: Int] = [:]
        for row in rows where choices[row.item] {
            percent[row.item] = total > 0 ? Int((Double(row.tokens) * 100 / Double(total)).rounded()) : 0
        }
        return (total, percent)
    }
}
