import Foundation
import SwiftData

/// recall 工具（SC-B1）：模型翻自己的历史——L0 对话原文检索，返回原话窗口（命中 ±1 主线邻居）。
/// 纯检索不写库；access 计数由调用方（CV 分发分支）用返回值记。
/// 设计：docs/research-recall-tool.md / docs/plan-recall-tool.md；修复第一刀·刀6：docs/plan-memory-fix-1.md
enum RecallTool {
    static let toolName = "recall"

    /// 开关 = 设置页「记忆内容」的"对话历史搜索"行（灰占位点亮，key 沿用）。
    /// 默认开（已批）；关 = 不下发工具，行为回纯现状
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "mem_content_convhistory") as? Bool) ?? true
    }

    // 防刷屏（research 决策 5：地板/上限/截断，宁缺勿滥）
    static let maxWindowsPerConversation = 2
    static let maxL0Windows = 4
    static let maxL1Hits = 4
    static let snippetLimit = 300
    static let totalTextLimit = 4000
    /// 单 turn 调用熔断（粟粟实测：宽查询连环翻页 5+ 次爆上下文），CV 分发处计数
    static let maxCallsPerTurn = 3
    /// 按天浏览：最多列几个对话 / 候选对话扫描上限 / 每句截断
    static let maxBrowseConversations = 12
    static let maxBrowseCandidates = 200
    static let browseLineLimit = 120

    // MARK: - 工具定义（双格式，FileLibraryTools 同款模式）

    // 检索契约（obelisk Retrieval Contract 浓缩，2026-06-13）：窄定位优先/证据先行/记忆非权威/结论提议存档
    private static let toolDescription = """
    回忆对话历史（我们说过的话）。三种用法：\
    ①给 query：逐字搜索原话片段并返回上下文；②想翻某天聊了什么：只给 date（或 after/before），不给 query，会列出那段时间的每个对话（标题 + 开头几句）；\
    ③只给 conversation_id：看那个窗口的窗口总结（从头到尾的经过、原话，加上时间轴里这个窗口还没做完的事）——时间轴里的 conv 编号就是它。\
    日期规则：date = 只看这一天；after = 从这天开始（含这天）；before = 到这天之前（不含这天）。\
    默认不搜当前这场对话；要搜它就用 conversation_id 指定。找文件库笔记请用 fs_search。\
    一次查清：不要翻页式反复调用（每轮最多 \(maxCallsPerTurn) 次）。\
    结果带 conv id，可用 conversation_id 在单场对话里继续深挖。\
    引用回忆要带出处（日期/原话），别凭印象转述；【相关记忆】段是先前的笔记不是最终事实，关键处以对话原文为准。\
    查到值得长期记住的结论时，先问用户要不要记下来，同意了再记。
    """

    private static let properties: [String: Any] = [
        "query": ["type": "string", "description": "要回忆的关键词或原话片段（不填 = 按日期翻对话）"],
        "exact": ["type": "boolean", "description": "true=只逐字找对话原文，不查记忆"],
        "date": ["type": "string", "description": "只看这一天，YYYY-MM-DD"],
        "after": ["type": "string", "description": "从这天开始（含这天），YYYY-MM-DD"],
        "before": ["type": "string", "description": "到这天之前（不含这天），YYYY-MM-DD"],
        "conversation_id": ["type": "string", "description": "只在这场对话里找（用之前结果里的 conv id 全量或前缀均可）"],
        "include_invalid": ["type": "boolean", "description": "true=记忆也搜已失效的（结果会标「已失效」）"],
    ]
    private static let required: [String] = []

    static var definition: ToolDefinition {
        ToolDefinition(name: toolName, description: toolDescription, properties: properties, required: required)
    }

    // MARK: - 执行

    struct ExecResult {
        let text: String
        let isError: Bool
        let hitMemoryIds: [UUID]
    }

    static func execute(
        inputJSON: String,
        profileId: String,
        currentConversationId: String?,
        userName: String,
        assistantName: String,
        container: ModelContainer
    ) async -> ExecResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        let queryArg = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (queryArg?.isEmpty == false) ? queryArg : nil
        let exact = args["exact"] as? Bool ?? false
        let includeInvalid = args["include_invalid"] as? Bool ?? false
        let range: (after: Date?, beforeExclusive: Date?)
        switch resolveRange(date: args["date"] as? String, after: args["after"] as? String, before: args["before"] as? String) {
        case .success(let r): range = r
        case .failure(let e): return ExecResult(text: e.message, isError: true, hitMemoryIds: [])
        }
        let convIdArg = (args["conversation_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let convId = (convIdArg?.isEmpty == false) ? convIdArg : nil
        // 第三刀：只给 conversation_id = 翻那个窗口的窗口总结 + 时间轴待续（时间轴上的 conv 编号就是给这个用的）
        let summaryOnly = query == nil && range.after == nil && range.beforeExclusive == nil && convId != nil
        guard query != nil || range.after != nil || summaryOnly else {
            let msg = range.beforeExclusive == nil
                ? "recall 需要 query、日期（date / after）或 conversation_id 至少一个。"
                : "只给 before 范围太宽：按日期翻对话请给 date 或 after。"
            return ExecResult(text: msg, isError: true, hitMemoryIds: [])
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let context = ModelContext(container)
                context.autosaveEnabled = false

                // 越层防护：conversation_id 必须属于当前楼层（支持结果里给的前 8 位前缀）
                var resolvedConvId: String? = nil
                if let convId {
                    guard let resolved = resolveConversation(idOrPrefix: convId, profileId: profileId, context: context) else {
                        continuation.resume(returning: ExecResult(
                            text: "没有找到这场对话（id 不存在或不属于当前楼层）。", isError: true, hitMemoryIds: []))
                        return
                    }
                    resolvedConvId = resolved
                }
                if summaryOnly, let cid = resolvedConvId {
                    continuation.resume(returning: ExecResult(
                        text: windowSummaryText(conversationId: cid, profileId: profileId, context: context),
                        isError: false, hitMemoryIds: []))
                    return
                }
                // 刀6：默认排除当前对话（请求本身就在里面，永远第一个命中）；显式指定 conversation_id 时不排除
                let excludeConvId = resolvedConvId == nil ? currentConversationId : nil

                var notes: [String] = []
                let windows: [String]
                if let query {
                    windows = searchL0(
                        query: query, profileId: profileId, convId: resolvedConvId, excludeConvId: excludeConvId,
                        after: range.after, beforeExclusive: range.beforeExclusive,
                        userName: userName, assistantName: assistantName, context: context
                    )
                } else {
                    let browsed = browseByDate(
                        after: range.after ?? .distantPast, beforeExclusive: range.beforeExclusive,
                        profileId: profileId, convId: resolvedConvId, excludeConvId: excludeConvId,
                        userName: userName, assistantName: assistantName, context: context
                    )
                    windows = browsed.entries
                    if browsed.truncated { notes.append("对话太多只扫了 \(maxBrowseCandidates) 个") }
                }
                if excludeConvId != nil { notes.append("已排除当前对话") }

                // L1 记忆并查：exact=只找原话时跳过；mem_master 关 = 只砍记忆半边，历史照查（已批边界）
                var memoryLines: [String] = []
                var hitIds: [UUID] = []
                if !exact && MemoryFlags.masterEnabled {
                    (memoryLines, hitIds) = searchL1(
                        query: query, profileId: profileId, includeInvalid: includeInvalid,
                        after: range.after, beforeExclusive: range.beforeExclusive, context: context
                    )
                }

                let text = composeResult(memoryLines: memoryLines, windows: windows, totalLimit: totalTextLimit,
                                         notes: notes, browse: query == nil)
                continuation.resume(returning: ExecResult(text: text, isError: false, hitMemoryIds: hitIds))
            }
        }
    }

    // MARK: - L0 原文检索

    /// 关键词在 predicate 层缩集（20 万 node 红线）；时间过滤在 Swift 层
    /// （红线：optional createTime 与 contains 同进 predicate 会静默返回空，SearchService:150 同款教训）。
    ///
    /// 2026-06-19：SwiftStreamingMarkdown 引入的 swift-syntax 600.0.1 让 Xcode 16 的 #Predicate
    /// type-checker 对 5+ 条件 + OR + localizedStandardContains 超时。把 role OR 过滤移到内存层
    /// 让 predicate 简化到 4 个 && 项，type-checker 不爆炸。
    private static func fetchHits(query: String, profileId: String, convId: String?, context: ModelContext) -> [MessageNode] {
        let pid = profileId
        let search = query
        let desc: FetchDescriptor<MessageNode>
        if let cid = convId {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid && node.conversationId == cid &&
                    node.isTrashed == false &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        } else {
            desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { node in
                    node.profileId == pid &&
                    node.isTrashed == false &&
                    node.content.localizedStandardContains(search)
                },
                sortBy: [SortDescriptor(\MessageNode.createTime, order: .reverse)]
            )
        }
        let allHits = (try? context.fetch(desc)) ?? []
        // role OR 在内存层（预过滤后命中量已小，O(n) filter 开销可忽略）
        return allHits.filter { $0.role == "user" || $0.role == "assistant" }
    }

    /// conversation_id 解析：全量 id 或结果行里的前 8 位前缀；楼层归属校验
    /// 只给 conversation_id：那个窗口的窗口总结（读 windows/，没有就退回 sessions/：段标题 + 最近两段全文）
    /// + 时间轴上这个窗口最新一条的待续（Q12）；都还没有就说清楚，指路按 query 搜
    private static func windowSummaryText(conversationId: String, profileId: String, context: ModelContext) -> String {
        let cid = conversationId
        let title = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> { $0.id == cid })).first?.title) ?? ""
        let s = WindowSummaryStore.load(conversationId: cid, profileId: profileId)
            ?? SessionSummaryStore.loadOrSeed(conversationId: cid, profileId: profileId, title: title)
        let latest = TimelineStore.latest(conversationId: cid, in: TimelineStore.dir(profileId: profileId))
        let pending = latest.map { TimelineStore.pendingItems($0.pending) } ?? []
        guard !s.segments.isEmpty || !pending.isEmpty else {
            return "《\(title)》conv \(cid.prefix(8)) 还没有窗口总结（聊得不长，或还没收尾）。要找具体说过的话，带上 query 再搜这个 conversation_id。"
        }
        var text = s.segments.isEmpty
            ? "《\(title)》conv \(cid.prefix(8)) 还没有窗口总结"
            : SessionSummaryStore.recallText(SessionSummary(conversationId: cid, title: title, compressedCount: s.compressedCount,
                                                            segments: s.segments, updatedAt: s.updatedAt))
        if let latest, !pending.isEmpty {
            text += "\n\n时间轴上这个窗口最近一条（\(latest.dayKey)）还没做完的：\n" + pending.map { "- \($0)" }.joined(separator: "\n")
        }
        if text.count > totalTextLimit { text = String(text.prefix(totalTextLimit)) + "…（太长截断了）" }
        return text
    }

    private static func resolveConversation(idOrPrefix: String, profileId: String, context: ModelContext) -> String? {
        let pid = profileId
        let exact = idOrPrefix
        let exactDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.id == exact && $0.profileId == pid && $0.isTrashed == false }
        )
        if let conv = try? context.fetch(exactDesc).first { return conv.id }
        guard idOrPrefix.count >= 8 else { return nil }
        // 前缀匹配：#Predicate 无 hasPrefix，楼层内未删对话量级小，内存过滤可接受
        let allDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.profileId == pid && $0.isTrashed == false }
        )
        let matches = ((try? context.fetch(allDesc)) ?? []).filter { $0.id.hasPrefix(idOrPrefix) }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func searchL0(
        query: String, profileId: String, convId: String?, excludeConvId: String?,
        after: Date?, beforeExclusive: Date?,
        userName: String, assistantName: String, context: ModelContext
    ) -> [String] {
        var hits = fetchHits(query: query, profileId: profileId, convId: convId, context: context)
        if let excludeConvId { hits = hits.filter { $0.conversationId != excludeConvId } }
        if after != nil || beforeExclusive != nil {
            hits = hits.filter { inRange($0.createTime, after: after, beforeExclusive: beforeExclusive) }
        }
        guard !hits.isEmpty else { return [] }

        let pid = profileId
        // 每对话的主线路径缓存（最多 maxL0Windows 个 conv 会真的 fetch）
        var pathCache: [String: (title: String, path: [RecallMessage], indexById: [String: Int])] = [:]
        var deadConvs = Set<String>()
        var perConvCount: [String: Int] = [:]
        var usedNodeIds = Set<String>()
        var windows: [String] = []

        for hit in hits {
            if windows.count >= maxL0Windows { break }
            let cid = hit.conversationId
            if deadConvs.contains(cid) { continue }
            if (perConvCount[cid] ?? 0) >= maxWindowsPerConversation { continue }
            if usedNodeIds.contains(hit.id) { continue }   // 已作为邻居出现过，免重叠窗

            if pathCache[cid] == nil {
                let convDesc = FetchDescriptor<Conversation>(
                    predicate: #Predicate<Conversation> { $0.id == cid && $0.profileId == pid && $0.isTrashed == false }
                )
                guard let conv = try? context.fetch(convDesc).first else { deadConvs.insert(cid); continue }
                let nodesDesc = FetchDescriptor<MessageNode>(
                    predicate: #Predicate<MessageNode> { $0.conversationId == cid && $0.profileId == pid && $0.isTrashed == false }
                )
                let allNodes = (try? context.fetch(nodesDesc)) ?? []
                let mainSet = ConversationViewModel.computeMainPathSet(nodes: allNodes, currentNodeId: conv.currentNodeId, selectionData: conv.branchSelectionData)
                let ordered = allNodes
                    .filter { mainSet.contains($0.id) && ($0.role == "user" || $0.role == "assistant") }
                    .sorted { ($0.createTime ?? .distantPast) < ($1.createTime ?? .distantPast) }
                    .map { RecallMessage(id: $0.id, role: $0.role, content: ContentCleaner.clean($0.content, cacheKey: $0.id), date: $0.createTime) }
                var index: [String: Int] = [:]
                for (i, m) in ordered.enumerated() { index[m.id] = i }
                pathCache[cid] = (title: conv.title, path: ordered, indexById: index)
            }
            guard let entry = pathCache[cid] else { continue }

            let text: String
            if let idx = entry.indexById[hit.id] {
                let header = "[\(dayString(hit.createTime)) · \(entry.title) conv:\(String(cid.prefix(8)))]"
                text = windowText(
                    path: entry.path, hitIndex: idx, header: header, query: query,
                    userName: userName, assistantName: assistantName, snippetLimit: snippetLimit
                )
                if !text.isEmpty {
                    for i in max(0, idx - 1)...min(entry.path.count - 1, idx + 1) { usedNodeIds.insert(entry.path[i].id) }
                }
            } else {
                // 刀6：支线命中不再静默跳过——单独成窗、只给命中这一句
                let header = "[\(dayString(hit.createTime)) · \(entry.title) conv:\(String(cid.prefix(8))) · 支线]"
                let msg = RecallMessage(id: hit.id, role: hit.role, content: ContentCleaner.clean(hit.content, cacheKey: hit.id), date: hit.createTime)
                text = windowText(path: [msg], hitIndex: 0, header: header, query: query,
                                  userName: userName, assistantName: assistantName, snippetLimit: snippetLimit)
                usedNodeIds.insert(hit.id)
            }
            guard !text.isEmpty else { continue }
            windows.append(text)
            perConvCount[cid, default: 0] += 1
        }
        return windows
    }

    // MARK: - 按天浏览（刀6：只给日期 = 翻那段时间的对话）

    /// 先用两个非 optional 字段缩集（对话在区间开始后还更新过、且在区间结束前就开了），
    /// 再逐对话取节点、内存层按 createTime 过滤（optional 谓词陷阱，TimelineConsolidator 同款做法）。
    private static func browseByDate(
        after: Date, beforeExclusive: Date?, profileId: String, convId: String?, excludeConvId: String?,
        userName: String, assistantName: String, context: ModelContext
    ) -> (entries: [String], truncated: Bool) {
        let pid = profileId
        let start = after
        let end = beforeExclusive ?? .distantFuture
        let convDesc = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> {
                $0.profileId == pid && $0.isTrashed == false && $0.updateTime >= start && $0.createTime < end
            },
            sortBy: [SortDescriptor(\Conversation.updateTime, order: .forward)]
        )
        var candidates = ((try? context.fetch(convDesc)) ?? []).filter { $0.id != excludeConvId }
        if let convId { candidates = candidates.filter { $0.id == convId } }
        let truncated = candidates.count > maxBrowseCandidates
        candidates = Array(candidates.prefix(maxBrowseCandidates))

        var found: [(first: Date, text: String)] = []
        for conv in candidates {
            let cid = conv.id
            let nodesDesc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { $0.conversationId == cid && $0.profileId == pid && $0.isTrashed == false }
            )
            let messages = ((try? context.fetch(nodesDesc)) ?? [])
                .filter { ($0.role == "user" || $0.role == "assistant") && inRange($0.createTime, after: start, beforeExclusive: beforeExclusive) }
                .sorted { ($0.createTime ?? .distantPast) < ($1.createTime ?? .distantPast) }
                .map { RecallMessage(id: $0.id, role: $0.role, content: ContentCleaner.clean($0.content, cacheKey: $0.id), date: $0.createTime) }
            guard let first = messages.first?.date else { continue }
            let text = browseEntry(title: conv.title, convId: cid, messages: messages,
                                   userName: userName, assistantName: assistantName, lineLimit: browseLineLimit)
            guard !text.isEmpty else { continue }
            found.append((first, text))
        }
        let entries = found.sorted { $0.first < $1.first }.prefix(maxBrowseConversations).map(\.text)
        return (Array(entries), truncated)
    }

    /// 一个对话在区间内的概览：头行（日期 · 标题 conv · 条数 · 起止时间）+ 开头 2 句 + 结尾 1 句。纯函数可测
    static func browseEntry(
        title: String, convId: String, messages: [RecallMessage],
        userName: String, assistantName: String, lineLimit: Int
    ) -> String {
        let nonEmpty = messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let firstDate = nonEmpty.first?.date, let lastDate = nonEmpty.last?.date else { return "" }
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        let header = "[\(dayString(firstDate)) · \(title) conv:\(String(convId.prefix(8)))] \(nonEmpty.count) 条，\(hm.string(from: firstDate))–\(hm.string(from: lastDate))"
        var picked = Array(nonEmpty.prefix(2))
        if nonEmpty.count > 3 { picked.append(RecallMessage(id: "", role: "gap", content: "…", date: nil)) }
        if nonEmpty.count > 2, let last = nonEmpty.last { picked.append(last) }
        let lines = picked.map { m -> String in
            if m.role == "gap" { return "…" }
            let flat = m.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let snippet = flat.count > lineLimit ? String(flat.prefix(lineLimit)) + "…" : flat
            return "\(m.role == "user" ? userName : assistantName): \(snippet)"
        }
        return ([header] + lines).joined(separator: "\n")
    }

    // MARK: - L1 记忆并查

    /// 刀6：不再借注入检索器的候选口径（它们排除常驻层 → 关系/偏好/钉住永远搜不到）；
    /// 同一套 BM25 / 向量打分，候选 = 全部活着的记忆（include_invalid 时连已失效一起）。
    /// 无 query（按日期翻）时列出区间内新记的记忆。
    private static func searchL1(
        query: String?, profileId: String, includeInvalid: Bool,
        after: Date?, beforeExclusive: Date?, context: ModelContext
    ) -> (lines: [String], ids: [UUID]) {
        let store = SwiftDataMemoryStore()
        let pool = includeInvalid
            ? store.listAll(profileId: profileId, context: context)
            : store.listActive(profileId: profileId, context: context)
        guard !pool.isEmpty else { return ([], []) }
        var ranked: [Memory]
        if let query {
            let kw = KeywordRetriever(excludePersistent: false).retrieve(pool, recent: [query])
            let vec = VectorRetriever(excludePersistent: false).retrieve(pool, recent: [query])
            if kw.isEmpty { ranked = vec.map(\.memory) }
            else if vec.isEmpty { ranked = kw.map(\.memory) }
            else { ranked = MemoryInjector.rrfFuse([kw, vec]) }
        } else {
            ranked = pool.sorted { $0.createdAt > $1.createdAt }
        }
        if after != nil || beforeExclusive != nil {
            ranked = ranked.filter { inRange($0.createdAt, after: after, beforeExclusive: beforeExclusive) }
        }
        let top = Array(ranked.prefix(maxL1Hits))
        let lines = top.map { m in
            var line = "- [\(dayString(m.createdAt)) · 记忆·\(categoryLabel(m.category))] \(String(m.content.prefix(snippetLimit)))"
            // SC-B2 出处：有 quote 锚的记忆带上原话证据
            if let quote = m.sourceQuote {
                line += "（出处:「\(String(quote.prefix(40)))」）"
            }
            if m.supersededAt != nil { line += "（已失效）" }
            return line
        }
        // 已失效的不算"想起来"（不强化）
        return (lines, top.filter { $0.supersededAt == nil }.map(\.id))
    }

    private static func categoryLabel(_ c: String) -> String {
        ["preference": "偏好", "fact": "事实", "relationship": "关系", "goal": "目标", "context": "情境"][c] ?? c
    }

    // MARK: - 纯函数层（XCTest 直测，不碰 SwiftData）

    struct RecallMessage {
        let id: String
        let role: String      // "user" / "assistant"
        let content: String   // 已 ContentCleaner.clean
        let date: Date?
    }

    /// 命中 ±1 主线邻居拼窗。空内容行跳过；全空返回空串
    static func windowText(
        path: [RecallMessage], hitIndex: Int, header: String, query: String,
        userName: String, assistantName: String, snippetLimit: Int
    ) -> String {
        guard path.indices.contains(hitIndex) else { return "" }
        var lines: [String] = []
        for i in max(0, hitIndex - 1)...min(path.count - 1, hitIndex + 1) {
            let m = path[i]
            let snippet = i == hitIndex
                ? centeredSnippet(m.content, keyword: query, limit: snippetLimit)
                : String(m.content.prefix(snippetLimit)) + (m.content.count > snippetLimit ? "…" : "")
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let speaker = m.role == "user" ? userName : assistantName
            lines.append("\(speaker): \(trimmed)")
        }
        guard !lines.isEmpty else { return "" }
        return header + "\n" + lines.joined(separator: "\n")
    }

    /// 以关键词首次命中处为中心截 limit 字；未命中退化为前缀截断
    static func centeredSnippet(_ text: String, keyword: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let lower = text.lowercased()
        guard let range = lower.range(of: keyword.lowercased()) else {
            return String(text.prefix(limit)) + "…"
        }
        let matchStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let contextStart = max(0, min(matchStart - limit / 3, text.count - limit))
        let start = text.index(text.startIndex, offsetBy: contextStart)
        let end = text.index(start, offsetBy: min(limit, text.distance(from: start, to: text.endIndex)))
        var snippet = String(text[start..<end])
        if contextStart > 0 { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }

    /// 结果拼装：头部统计行 + 记忆段 + 原文段；总长截断；全空给"没找到"。
    /// browse=按日期翻（头行写"翻到 N 个对话"）；notes 追加进头行（如"已排除当前对话"）
    static func composeResult(memoryLines: [String], windows: [String], totalLimit: Int,
                              notes: [String] = [], browse: Bool = false) -> String {
        let noteText = notes.isEmpty ? "" : " · " + notes.joined(separator: " · ")
        if memoryLines.isEmpty && windows.isEmpty {
            let base = browse
                ? "那段时间没有找到对话。可以放宽日期再试。"
                : "没有找到相关记录。可以换个关键词，或去掉日期限制再试。"
            return notes.isEmpty ? base : base + "（" + notes.joined(separator: " · ") + "）"
        }
        let countText = browse ? "翻到 \(windows.count) 个对话" : "原文 \(windows.count) 窗"
        var parts: [String] = ["（\(countText) · 记忆 \(memoryLines.count) 条\(noteText)）"]
        if !memoryLines.isEmpty {
            parts.append("【相关记忆】\n" + memoryLines.joined(separator: "\n"))
        }
        if !windows.isEmpty {
            parts.append((browse ? "【那段时间的对话】\n" : "【对话原文】\n") + windows.joined(separator: "\n\n"))
        }
        let text = parts.joined(separator: "\n\n")
        guard text.count > totalLimit else { return text }
        return String(text.prefix(totalLimit)) + "\n…（结果过长已截断）"
    }

    struct RangeError: Error { let message: String }

    /// 日期参数 → 区间（刀6 统一语义）：date = 只这一天；after 含当天；before 不含当天。
    /// 给了但格式不对 → 报错（不静默当没给）
    static func resolveRange(date: String?, after: String?, before: String?) -> Result<(after: Date?, beforeExclusive: Date?), RangeError> {
        func given(_ s: String?) -> Bool { !(s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        for (name, s) in [("date", date), ("after", after), ("before", before)] where given(s) && parseDay(s) == nil {
            return .failure(RangeError(message: "\(name) 格式要 YYYY-MM-DD（收到「\(s ?? "")」）"))
        }
        if given(date), let d = parseDay(date) {
            return .success((d, parseDay(date, endOfDay: true)))
        }
        let a = parseDay(after)
        let b = parseDay(before)
        if let a, let b, b <= a {
            return .failure(RangeError(message: "before 要晚于 after（before 不含当天；只看一天请用 date）"))
        }
        return .success((a, b))
    }

    /// YYYY-MM-DD → 当天零点（本地时区）。endOfDay=true 返回次日零点（date 单日的 exclusive 上界）。
    /// 格式预校验：DateFormatter 对分隔符宽容（"2026/06/12" 也能过），正则先把关
    static func parseDay(_ s: String?, endOfDay: Bool = false) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let day = formatter.date(from: s) else { return nil }
        return endOfDay ? Calendar.current.date(byAdding: .day, value: 1, to: day) : day
    }

    static func inRange(_ date: Date?, after: Date?, beforeExclusive: Date?) -> Bool {
        guard let date else { return false }
        if let after, date < after { return false }
        if let beforeExclusive, date >= beforeExclusive { return false }
        return true
    }

    private static func dayString(_ date: Date?) -> String {
        guard let date else { return "????-??-??" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
