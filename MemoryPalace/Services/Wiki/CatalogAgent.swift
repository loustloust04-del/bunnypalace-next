import MemoryCore
import Foundation

// MARK: - 手动整理 = 真 agent 的工具（plan-memory-c3-catalog 4.1b）：全是只读的，submit_proposal 是唯一的出口

struct CatalogAgentTools: Sendable {
    static let submit = "submit_proposal"
    /// 每次工具返回最多几个字
    static let resultLimit = CatalogRetrieval.Limits.chars

    let wiki: WikiStore
    let memoryRoot: URL
    /// 本楼层已留碎片（编号 = 原快照下标 + 1）
    let fragments: [CatalogFragment]
    var conversationIds: Set<String>? = nil
    var embedder: any MemoryEmbedding = AppleMemoryEmbedder.shared
    var originalSearch: CatalogRetrieval.OriginalSearch? = nil
    var cancel: CatalogCancel = CatalogCancel()
    /// 楼层用户名：list_wiki / read_wiki 的 path 第一段写名字的按本人那组（{{user}}）找
    var user: String = ""

    enum Seen: Sendable {
        case none
        /// read_wiki 读到的页和它的版本（提案改这页用它当基线）
        case page(path: String, version: String)
    }

    struct Output: Sendable {
        var text: String
        var isError = false
        var seen: Seen = .none
        var receipt: CatalogSearchReceipt? = nil
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["type": "function", "function": ["name": name, "description": description, "parameters": schema]]
    }

    private static let terms: [String: Any] = ["type": "array", "items": ["type": "string"], "description": "关键词，任一个命中就算"]

    private static let citeSchema: [String: Any] = [
        "type": "object", "properties": [
            "layer": ["type": "string", "enum": ["原文", "A2", "A3", "A4"]],
            "day": ["type": "string"], "window": ["type": "string"], "segment": ["type": "integer"],
            "nodeId": ["type": "string"], "profileId": ["type": "string"],
        ], "required": ["layer"],
    ]
    private static let recordSchema: [String: Any] = [
        "type": "object", "properties": [
            "text": ["type": "string"],
            "fragments": ["type": "array", "items": ["type": "string"]],
            "aline": ["type": "array", "items": citeSchema],
        ], "required": ["text"],
    ]
    private static let linkSchema: [String: Any] = [
        "type": "object", "properties": [
            "to": ["type": "string"], "relation": ["type": "string", "enum": ["补充", "矛盾", "共鸣", "引用"]],
            "why": ["type": "string"],
        ], "required": ["to", "relation"],
    ]
    static let coverageSchema: [String: Any] = [
        "type": "array", "description": "分到的每份输入写进了哪儿（at），或为什么没写（why）；只记日志",
        "items": ["type": "object", "properties": ["input": ["type": "string"], "at": ["type": "string"], "why": ["type": "string"]],
                  "required": ["input"]],
    ]
    static let preservationSchema: [String: Any] = [
        "type": "array", "description": "交了 rewrite_now 时：旧「现在」里每件事保留 / 改了 / 疑似漏了；只记日志",
        "items": ["type": "object", "properties": [
            "page": ["type": "string"], "old": ["type": "string"], "status": ["type": "string", "enum": ["保留", "改了", "疑似漏了"]],
            "new": ["type": "string"], "why": ["type": "string"],
        ], "required": ["old", "status"]],
    ]
    static func itemSchema(record: [String: Any]) -> [String: Any] { [
        "type": "object", "properties": [
            "type": ["type": "string", "enum": ["new_page", "append", "rewrite_now", "link", "retag"]],
            "path": ["type": "string"], "kind": ["type": "string"],
            "title": ["type": "string"], "triggers": ["type": "array", "items": ["type": "string"]],
            "hook": ["type": "string"], "now": ["type": "string"],
            "records": ["type": "array", "items": record],
            "links": ["type": "array", "items": linkSchema],
            "to": ["type": "string"], "relation": ["type": "string", "enum": ["补充", "矛盾", "共鸣", "引用"]],
            "why": ["type": "string"], "judgment": ["type": "string", "enum": ["conflict", "coexist"]],
            "fragments": ["type": "array", "items": ["type": "string"]],
            "aline": ["type": "array", "items": citeSchema],
        ], "required": ["type", "path"],
    ] }

    static let submitDefinition = tool(submit, "交整理结果：一批条目（格式见系统提示）。这是唯一的出口；确实没有值得写进 wiki 的内容时才交空的 items，并用 reason 说明为什么。",
                                       ["items": ["type": "array", "items": itemSchema(record: recordSchema), "description": "条目"],
                                        "covered": ["type": "array", "items": ["type": "string"],
                                                    "description": "分到这个主题的碎片里，页上已经写过、不用再写的 f 编号（可不写）"],
                                        "covered_page": ["type": "string",
                                                         "description": "covered 对应的已有页路径（必须是这次 read_wiki 读过的页；分到了主题页可不写）"],
                                        "single": ["type": "array", "items": ["type": "string"],
                                                   "description": "分到这个主题的碎片里，几乎不变、自己就完整、不用进页的 f 编号（可不写）"],
                                        "reason": ["type": "string", "description": "确实没有值得写的内容时，说明为什么交空"],
                                        "coverage": coverageSchema, "preservation": preservationSchema],
                                       required: ["items"])

    /// submitOnly = 轮数 / 字数到顶，只剩交提案
    static func definitions(submitOnly: Bool) -> [[String: Any]] {
        guard !submitOnly else { return [submitDefinition] }
        return [
            tool("search_aline", "三路广搜本楼层原料：聊天可见原文、A4 时间轴/A3 窗口总结/A2 上下文摘要、已留碎片（关键词和向量）。按统一相关度和来源权重全局取料，结果明示来源、原文 nodeId 与角色；助手发言不是用户事实。搜到片名、人名、地名可再搜。after / before 写 YYYY-MM-DD，不写 = 10 月起到现在。",
                 ["terms": terms, "after": ["type": "string"], "before": ["type": "string"]], required: ["terms"]),
            tool("read_aline", "往下翻 A 线：只给 window = 这个窗口的 A3 窗口总结 + A2 段目录；再给 segment = 那一段 A2 全文（经过 + 原话）。window 写 conv 后面那 8 位。读要窄。",
                 ["window": ["type": "string"], "segment": ["type": "integer"]], required: ["window"]),
            tool("search_fragments", "定向追搜本楼层 10 月起已留、未删除的碎片，按关键词和向量召回；已整理或整理驳回的也可回读并标状态。返回原编号 f…、日期、状态、主体、发言归因、正文；旧归因缺失显示未知，编号写进记录的 fragments。",
                 ["terms": terms], required: ["terms"]),
            tool("list_wiki", "看 wiki 一层的索引（一行一个「标题 — 钩子」）；不给 path = 根索引。先看这个，已有的不重复写。",
                 ["path": ["type": "string"]]),
            tool("read_wiki", "读 wiki 一页全文；path 不带 .md。", ["path": ["type": "string"]], required: ["path"]),
            submitDefinition,
        ]
    }

    static let clipNote = "…（太长，后面截掉了）"

    /// 截到 limit 字以内（连截断提示）
    static func clip(_ s: String, limit: Int = resultLimit) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(max(0, limit - clipNote.count))) + clipNote
    }

    /// 记忆日志 / 草稿里那一次调用：搜的词、读的路径
    static func describe(_ name: String, _ argumentsJSON: String) -> String {
        guard let a = CatalogJSON.decode(Args.self, argumentsJSON.isEmpty ? "{}" : argumentsJSON) else { return name }
        switch name {
        case "search_aline", "search_fragments":
            var out = name + WikiStore.normalizedWords(a.terms ?? []).map { "「\($0)」" }.joined()
            if a.after != nil || a.before != nil { out += "（\(a.after ?? "")～\(a.before ?? "")）" }
            return out
        case "read_aline":
            return name + " " + CatalogSources.windowKey(a.window ?? "") + (a.segment.map { " 第 \($0) 段" } ?? "")
        case "read_wiki":
            return name + " " + CatalogPrompts.normalizedPath(a.path ?? "")
        case "list_wiki":
            let path = CatalogPrompts.normalizedPath(a.path ?? "")
            return name + " " + (path.isEmpty ? "根" : path)
        default:
            return name
        }
    }

    private struct Args: Decodable {
        let terms: [String]?
        let after: String?
        let before: String?
        let window: String?
        let segment: Int?
        let path: String?
    }

    /// 「2026-10-01」→ 那天 05:00；坏了 nil
    static func boundary(_ key: String?, nextDay: Bool = false) -> Date? {
        guard let key, let day = MemoryDay.date(ofKey: key.trimmingCharacters(in: .whitespaces)) else { return nil }
        let d = nextDay ? Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day : day
        return MemoryDay.boundary(of: d)
    }

    func execute(name: String, argumentsJSON: String, now: Date) async -> Output {
        guard !cancel.isCancelled else { return Output(text: "已取消", isError: true) }
        guard let args = CatalogJSON.decode(Args.self, argumentsJSON.isEmpty ? "{}" : argumentsJSON) else {
            return Output(text: "参数不是合格的 JSON", isError: true)
        }
        switch name {
        case "search_aline":
            let words = WikiStore.normalizedWords(args.terms ?? [])
            guard !words.isEmpty else { return Output(text: "terms 不能是空的", isError: true) }
            let start = Self.boundary(args.after) ?? CatalogMaterial.startDate
            let end = Self.boundary(args.before, nextDay: true) ?? now
            guard start <= end else { return Output(text: "after 晚于 before", isError: true) }
            let result = await CatalogRetrieval(memoryRoot: memoryRoot, fragments: fragments, conversationIds: conversationIds,
                                               embedder: embedder, originalSearch: originalSearch).search(words, in: DateInterval(start: start, end: end), cancel: cancel)
            let receipt = result.receipt
            return Output(text: receipt.text, receipt: receipt)
        case "read_aline":
            guard let raw = args.window, !CatalogSources.windowKey(raw).isEmpty else { return Output(text: "缺 window", isError: true) }
            let key = CatalogSources.windowKey(raw)
            if let conversationIds, !conversationIds.contains(where: { $0.hasPrefix(key) }) {
                return Output(text: "没有窗口 \(key)", isError: true)
            }
            if let n = args.segment {
                guard let s = await CatalogALineReader.readSegment(key, number: n, memoryRoot: memoryRoot, cancel: cancel) else {
                    return Output(text: "窗口 \(key) 没有第 \(n) 段", isError: true)
                }
                let receipt = s.receipt()
                return Output(text: Self.clip(receipt.text), receipt: receipt)
            }
            guard let w = await CatalogALineReader.readWindow(key, memoryRoot: memoryRoot, cancel: cancel) else { return Output(text: "没有窗口 \(key)", isError: true) }
            let receipt = w.receipt()
            return Output(text: Self.clip(receipt.text), receipt: receipt)
        case "search_fragments":
            let words = WikiStore.normalizedWords(args.terms ?? [])
            guard !words.isEmpty else { return Output(text: "terms 不能是空的", isError: true) }
            let result = await CatalogRetrieval(memoryRoot: memoryRoot, fragments: fragments, conversationIds: conversationIds,
                                               embedder: embedder, originalSearch: originalSearch).search(words, fragmentsOnly: true, cancel: cancel)
            let receipt = result.receipt
            return Output(text: receipt.text, receipt: receipt)
        case "list_wiki":
            let path = WikiStore.stored(CatalogPrompts.normalizedPath(args.path ?? ""), user: user)
            return await Task.detached(priority: .utility) { [wiki] in
                guard path.isEmpty || (WikiStore.isValidFolderPath(path) && wiki.folderExists(path)) else {
                    return Output(text: "没有这一层：\(path)", isError: true)
                }
                return Output(text: Self.clip(wiki.layerMarkdown(path)))
            }.value
        case "read_wiki":
            let path = WikiStore.stored(CatalogPrompts.normalizedPath(args.path ?? ""), user: user)
            return await Task.detached(priority: .utility) { [wiki] in
                guard let read = wiki.readVersioned(path) else { return Output(text: "没有这一页：\(path)", isError: true) }
                return Output(text: Self.clip(read.text), seen: .page(path: path, version: read.version))
            }.value
        default:
            return Output(text: "没有这个工具：\(name)", isError: true)
        }
    }
}

// MARK: - 循环（照小芽：toolCalls → 执行 → ToolTurn 回灌 → 下一轮，直到交提案或封顶）

@MainActor
final class CatalogAgent {
    /// 累计最多喂回去几个字（工具结果、错误、提醒都算），到了只能交提案
    static let maxToolChars = 40_000
    /// 给最后那句提醒、交提案的回执留的字
    static let reserve = 300
    static let defaultRounds = 10
    static let maxTokens = 4096

    struct Deps {
        /// 云端走 ProviderRouter 原生 tool calling；选了本机走本机后端
        var makeBackend: @MainActor () -> AssistantBackend
        /// 每一轮发请求前：写入预算 + 全局预算闸（参数 = 这一轮要送的字，估钱用）；拦下 = 原因
        var gate: (String) async -> String?
        /// 这一轮记进账本的花费（记忆日志用）
        var roundCost: @MainActor (AssistantBackend) -> Double? = { ($0 as? AssistantCloudBackend)?.lastCostUSD }
        /// 这一工具轮的完整回复（provider 内容块 / 思考 / reasoning）：种子 checkpoint 存下来、续轮原样回灌
        var roundTurn: @MainActor (AssistantBackend) -> AssistantTurnExtras? = { ($0 as? AssistantCloudBackend)?.lastTurnExtras }
        /// 这一轮失败是请求超时（URLSession 的 NSURLErrorTimedOut，含回了 200 之后流断在半路）：种子原样再发一次
        var roundTimedOut: @MainActor (AssistantBackend) -> Bool = { ($0 as? AssistantCloudBackend)?.lastFailureTimedOut == true }
    }

    struct Job {
        var topic: String
        var aliases: [String] = []
        /// 列主题 / 方向给的：类 / 建议路径，或已有页
        var hint: String = ""
        /// 列主题 / 方向给的页路径（covered 的碎片挂在写这页的第一条上）
        var path: String? = nil
        /// 分到这个主题的碎片（线索）
        var fragmentIds: [UUID] = []
        var profileId: String
        var memoryRoot: URL
        var names: MemoryExtractor.Names
        var floorPrompt: String
        /// 碎片池快照（search_fragments 搜它；编号 f1… = 下标 + 1）
        var snapshot: [CatalogFragment]
        var modelName: String
        var maxRounds = CatalogAgent.defaultRounds
        var run: CatalogRunRecord? = nil
        var conversationIds: Set<String>? = nil
        var embedder: any MemoryEmbedding = AppleMemoryEmbedder.shared
        var originalSearch: CatalogRetrieval.OriginalSearch? = nil
        var feedback: String? = nil
    }

    enum Stop: Equatable {
        case submitted
        /// 轮数 / 字数到顶，最后那次「现在必须交」也没交
        case gaveUp
        case blocked(String)
        case cancelled
        case failed(String)
    }

    struct Outcome: Equatable {
        var items: [WikiProposal.Item] = []
        /// 交的 covered 里没条目可挂的（页不在），不打标
        var covered: [UUID] = []
        /// 分到这个主题、判「单条就够」的
        var single: [UUID] = []
        /// 交空时它说的为什么
        var reason: String? = nil
        /// 没整理完（轮数 / 字数到顶才交的）
        var incomplete = false
        var stop: Stop
        var rounds = 0
        /// 交上来扔掉的（格式不对的条目、没出处的行）
        var dropped = 0
        /// 实际喂回去的字
        var toolChars = 0
        var searchedChars = 0
        /// 收不进页的内容（提案上只展示）
        var unapplied: [WikiProposal.Unapplied] = []
        /// 有没过的项时修订实际走到哪一步
        var revision: String? = nil
        /// 交审诊断在运行记录里的锚点
        var diagnostics: String? = nil
    }

    private enum Forced {
        case rounds, chars, noSubmit

        var note: String {
            switch self {
            case .rounds: return "（系统提醒：轮数到顶了，不能再查。现在调用 submit_proposal，把已经查到的整理成条目交上来。）"
            case .chars: return "（系统提醒：查回来的字数到顶了，不能再查。现在调用 submit_proposal，把已经查到的整理成条目交上来。）"
            case .noSubmit: return "（系统提醒：你还没交。现在调用 submit_proposal 交条目；确实没有值得写进 wiki 的内容时才交空的 items，并用 reason 说明为什么。）"
            }
        }
    }

    let deps: Deps
    /// 第几轮了（给「正在整理：电影（第 3 轮）」）
    var onRound: ((Int) -> Void)?
    let cancelToken: CatalogCancel
    var isCancelled: Bool { cancelToken.isCancelled }
    var backend: AssistantBackend?
    private var waiting: ((AssistantBackendEvent) -> Void)?
    var currentRun: CatalogRunRecord?
    var currentAnchor: String?

    init(deps: Deps, cancel: CatalogCancel = CatalogCancel()) {
        self.deps = deps
        self.cancelToken = cancel
    }

    /// 停：不再发请求；正在等的那一轮当作被停
    func cancel() {
        cancelToken.cancel()
        backend?.cancel()
        resume(.failed("停了"))
    }

    private func resume(_ event: AssistantBackendEvent) {
        let w = waiting
        waiting = nil
        w?(event)
    }

    /// 一轮：收集正文，等后端的终止事件。发出去的那份把本人那组 `{{user}}` 显示成名字（`shown`）；
    /// 回来的原样交回（重放给模型的就是它自己写的，签过名的思考不受影响）；执行 / 解析时各自按位置把名字还原成 {{user}}
    func step(_ backend: AssistantBackend, _ request: AssistantBackendRequest, user: String) async -> (event: AssistantBackendEvent, text: String) {
        let sent = Self.shown(request, user: user)
        return await withCheckedContinuation { cont in
            MainActor.assumeIsolated {
                var text = ""
                waiting = { cont.resume(returning: ($0, text)) }
                backend.run(sent) { [weak self] event in
                    if case .token(let token) = event {
                        text += token
                    } else {
                        self?.resume(event)
                    }
                }
            }
        }
    }

    /// 发给模型的那份：提示词、历史、工具回执、工具定义里的 `{{user}}` 换成名字（工具定义在值上换）；模型自己的调用 / 正文 / 内容块原样，签过名的思考不能动
    static func shown(_ request: AssistantBackendRequest, user: String) -> AssistantBackendRequest {
        var r = request
        r.system = WikiStore.shown(r.system, user: user)
        r.history = r.history.map { (role: $0.role, content: WikiStore.shown($0.content, user: user)) }
        r.toolTurns = r.toolTurns.map { turn in
            var t = turn
            t.results = t.results.map { ToolResultBlock(toolUseId: $0.toolUseId, text: WikiStore.shown($0.text, user: user), isError: $0.isError) }
            t.followUps = t.followUps.map { ToolFollowUp(reply: $0.reply, note: WikiStore.shown($0.note, user: user)) }
            return t
        }
        r.tools = r.tools.map { WikiStore.shownValue($0, user: user) as? [String: Any] ?? $0 }
        return r
    }

    static func systemPrompt(names: MemoryExtractor.Names) -> String {
        """
        这不是在跟你聊天。你在整理\(names.user)和\(names.char)的记忆 wiki：自己用工具查原料——聊天可见原文、A 线（A4 时间轴、A3 窗口总结、A2 上下文摘要）、已留碎片、wiki 已有的页——把这个主题写成 / 补进 wiki 页，最后调用 submit_proposal 交一批条目给\(names.user)过目。工具都只读，submit_proposal 是唯一的出口，交完就结束。原文中的助手发言仅作上下文，不能归为用户事实；跳过不相关内容。
        查的时候：
        - 只靠主题词会漏掉那天只说了片名、人名的讨论：搜到片名、人名、地名就再搜它，顺着往下找；
        - 先看 wiki 索引（list_wiki），已有的页 read_wiki 读全文，已有的事实不重复写；
        - 读要窄：read_aline 先看窗口目录，要细节再读那一段。
        查到的东西里，只要有她明确说过的事实或讨论，就写成页；宁可写一页简短的，也别交空。

        submit_proposal 的 items：
        \(CatalogPrompts.itemFormat(names: names))
        碎片编号用 search_aline / search_fragments 实际返回的 f 编号；原文引用实际返回的 nodeId，A 线只引用实际给出的层 / 窗口 / 段。
        \(CatalogPrompts.diagnostics(names: names, standalone: false))

        \(CatalogPrompts.pageRules(names: names))
        """
    }

    static func opening(_ job: Job, rootIndex: String, labels: [UUID: String]) -> String {
        var out = ["【主题】\(job.topic)" + (job.aliases.isEmpty ? "" : "（别名：\(job.aliases.joined(separator: "、"))）") + (job.hint.isEmpty ? "" : "\n\(job.hint)")]
        if let feedback = job.feedback { out.append(feedback) }
        out.append("【楼层提示词】（\(job.names.user)亲手写的人设，权威底图：已有的写「详见人设」，不重抄；\(CatalogPrompts.factDomainPrinciple)）\n" + (job.floorPrompt.isEmpty ? "（没写）" : job.floorPrompt))
        out.append("【wiki 根索引】\n" + rootIndex)
        let given = job.snapshot.filter { job.fragmentIds.contains($0.id) }
        if !given.isEmpty {
            out.append("【分到这个主题的碎片】\n" + given.map { f in
                "- \(labels[f.id] ?? "") · \(f.day) · \(f.category) · \(f.attributionText) · \(f.content)"
            }.joined(separator: "\n"))
        }
        out.append("先 search_aline 搜主题词和别名，顺着搜到的再搜；最多 \(job.maxRounds) 轮，查完调用 submit_proposal。")
        return out.joined(separator: "\n\n")
    }

    /// 送出去的大概有多少字（估钱用）
    static func payload(_ system: String, _ history: [(role: String, content: String)], _ turns: [ToolTurn]) -> String {
        ([system] + history.map(\.content) + turns.flatMap { turn in
            turn.calls.map(\.argumentsJSON) + turn.results.map(\.text) + turn.followUps.flatMap { [$0.reply, $0.note] }
        }).joined(separator: "\n")
    }

    /// 提醒它交。reply = 模型刚才只回的那段字（没调工具）：有工具回合时这段话按 assistant 接在最后一个回合后面、提醒另起一条 user
    /// （回执原样不动，同一条回执上不叠提醒）；还没有工具回合就进 history。
    /// reply = nil：工具回合刚收完、要它收尾——提醒接在这个新回合最后一条结果后面；同一回合已经接过一条就不再接（astra：防连调两次叠两条）
    static func remind(_ note: String, history: inout [(role: String, content: String)], turns: inout [ToolTurn], reply: String?) {
        guard var last = turns.popLast() else {
            if let reply, !reply.isEmpty { history.append((role: "assistant", content: reply)) }
            history.append((role: "user", content: note))
            return
        }
        if reply == nil, last.followUps.isEmpty, let r = last.results.last {
            if !last.reminded {
                last.results[last.results.count - 1] = ToolResultBlock(toolUseId: r.toolUseId, text: r.text + "\n\n" + note, isError: r.isError)
                last.reminded = true
            }
        } else {
            last.followUps.append(ToolFollowUp(reply: reply ?? "", note: note))
        }
        turns.append(last)
    }

    private static func traceJSON(_ value: [String]) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch {
            return "序列化失败：\(error)"
        }
    }

    static func traceCalls(_ calls: [ToolCallBlock]) -> String {
        calls.enumerated().map { index, call in
            """
            #### 调用 \(index + 1)
            id：
            \(CatalogRunRecord.code(call.id))
            name：
            \(CatalogRunRecord.code(call.name))
            truncated：\(call.truncated)
            argumentsJSON：
            \(CatalogRunRecord.code(call.argumentsJSON, language: "json"))
            """
        }.joined(separator: "\n\n")
    }

    static func traceResults(_ results: [ToolResultBlock]) -> String {
        results.enumerated().map { index, result in
            """
            #### 回执 \(index + 1)
            toolUseId：
            \(CatalogRunRecord.code(result.toolUseId))
            isError：\(result.isError)
            正文：
            \(CatalogRunRecord.code(result.text))
            """
        }.joined(separator: "\n\n")
    }

    /// 回执之后模型只回的字和补的提醒（没有 = 空）
    static func traceFollowUps(_ followUps: [ToolFollowUp]) -> String {
        followUps.enumerated().map { index, follow in
            "#### 回执后 \(index + 1) · 模型只回了字（assistant）\n" + CatalogRunRecord.code(follow.reply)
                + "\n\n#### 回执后 \(index + 1) · 补的提醒（user）\n" + CatalogRunRecord.code(follow.note)
        }.joined(separator: "\n\n")
    }

    /// 一个工具回合的记录：调用、回执、回执后的一来一回
    static func traceTurn(_ turn: ToolTurn) -> String {
        traceCalls(turn.calls) + "\n\n" + traceResults(turn.results) + (turn.followUps.isEmpty ? "" : "\n\n" + traceFollowUps(turn.followUps))
    }

    static func traceRequest(_ request: AssistantBackendRequest) -> String {
        let tools: String
        do {
            tools = String(decoding: try JSONSerialization.data(withJSONObject: request.tools, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        } catch {
            tools = "序列化失败：\(error)"
        }
        var parts = ["### 系统提示 system\n" + CatalogRunRecord.code(request.system)]
        parts.append("### opening / history\n" + request.history.enumerated().map { index, message in
            "#### 消息 \(index + 1) · \(message.role)\n" + CatalogRunRecord.code(message.content)
        }.joined(separator: "\n\n"))
        parts.append("### 工具定义\n" + CatalogRunRecord.code(tools, language: "json"))
        parts.append("### 回灌 toolTurns\n" + (request.toolTurns.isEmpty ? "（无）" : request.toolTurns.enumerated().map { index, turn in
            "#### 工具回合 \(index + 1)\n" + traceTurn(turn)
        }.joined(separator: "\n\n")))
        return parts.joined(separator: "\n\n")
    }

    private static func traceSubmit(_ parsed: CatalogItems.Parsed?, parseError: String, truncated: Bool) -> String {
        var parts = ["解析状态：\(truncated ? "跳过（truncated=true）" : parsed == nil ? "格式不合格" : "已解析")",
                     "parseError：\n" + CatalogRunRecord.code(parseError)]
        if let parsed {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let items: String
            do {
                items = String(decoding: try encoder.encode(parsed.items), as: UTF8.self)
            } catch {
                items = "序列化失败：\(error)"
            }
            parts += ["items：\n" + CatalogRunRecord.code(items, language: "json"),
                      "covered：\n" + CatalogRunRecord.code(traceJSON(parsed.covered.map(\.uuidString)), language: "json"),
                      "single：\n" + CatalogRunRecord.code(traceJSON(parsed.single.map(\.uuidString)), language: "json"),
                      "reason：\n" + CatalogRunRecord.code(parsed.reason ?? "（无）"),
                      "dropped：\(parsed.dropped)",
                      "dropReasons：\n" + CatalogRunRecord.code(traceJSON(parsed.dropReasons), language: "json")]
        } else {
            parts += ["items：未知", "covered：未知", "single：未知", "reason：未知", "dropped：未知", "dropReasons：未知"]
        }
        return parts.joined(separator: "\n\n")
    }

    /// 总请求数 ≤ maxRounds：第 maxRounds 轮就是只能交的收尾轮；字数到顶也提前收尾
    func run(_ job: Job) async -> Outcome {
        let token = cancelToken
        return await withTaskCancellationHandler {
            await runCancellable(job)
        } onCancel: {
            token.cancel()
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func runCancellable(_ input: Job) async -> Outcome {
        var job = input
        guard !isCancelled else { return Outcome(stop: .cancelled) }
        let wiki = WikiStore(root: job.memoryRoot.appendingPathComponent("wiki", isDirectory: true))
        let run = job.run ?? CatalogRunRecord(wiki: wiki, topic: job.topic, kind: "手动 agent")
        currentRun = run
        currentAnchor = nil
        let tools = CatalogAgentTools(wiki: wiki, memoryRoot: job.memoryRoot, fragments: job.snapshot,
                                      conversationIds: job.conversationIds, embedder: job.embedder,
                                      originalSearch: job.originalSearch, cancel: cancelToken, user: job.names.user)
        let drafts = CatalogDrafts(wiki: wiki, now: Date())
        var sources = CatalogSources()
        for (index, fragment) in job.snapshot.enumerated() where job.fragmentIds.contains(fragment.id) {
            guard !isCancelled else { return Outcome(stop: .cancelled) }
            sources.fragments[CatalogSorter.label(index)] = fragment
        }
        var labels: [UUID: String] = [:]
        for (i, f) in job.snapshot.enumerated() where labels[f.id] == nil { labels[f.id] = CatalogSorter.label(i) }
        run.recordSearch(CatalogSearchEvidence(assigned: job.snapshot.filter { job.fragmentIds.contains($0.id) }.map(\.content)))
        let token = cancelToken
        let initialQuery = WikiFeedback.Query(targetPath: job.path, fragmentIds: Set(job.fragmentIds))
        let (rootIndex, versions, initialFeedback) = await Task.detached(priority: .utility) {
            guard !token.isCancelled else { return ("", [String: String](), [WikiFeedback.Entry]()) }
            let index = wiki.layerMarkdown("")
            guard !token.isCancelled else { return ("", [String: String](), [WikiFeedback.Entry]()) }
            return (index, wiki.versionSnapshot(), WikiFeedback.select(initialQuery, wiki: wiki, now: Date()))
        }.value
        guard !isCancelled else { return Outcome(stop: .cancelled) }
        sources.versions = versions
        job.feedback = WikiFeedback.render(initialFeedback)
        var sentFeedback = initialFeedback
        /// 生成这一轮回复时模型已经收到的出处 / 读过的页：提交只认它，这一轮工具新查到的下一次请求发出去之后才算
        var seen = sources
        var seenPages: [String] = []
        let system = Self.systemPrompt(names: job.names)
        var opening = Self.opening(job, rootIndex: rootIndex, labels: labels)
        var forced: Forced?
        if job.maxRounds <= 1 {
            forced = .rounds
            opening += "\n\n" + Forced.rounds.note
        }
        var history: [(role: String, content: String)] = [(role: "user", content: opening)]
        var turns: [ToolTurn] = []
        var out = Outcome(stop: .submitted)
        /// 被拦时记进草稿：查过什么、回了多少字
        var executed: [String] = []
        /// read_wiki 实际读过的页（covered 只能挂在这些页上，或分到的主题页）
        var readPages: [String] = []
        var retriedEmpty = false
        /// 修订只给一次（全部被扔 / 没过检查 / 收不进页共用）；用过之后下一份就是最后一份
        var revised = false
        /// 打回修订前那一稿（有可审的内容才留）：修订用不了就交它
        var firstDraft: (parsed: CatalogItems.Parsed, seen: CatalogSources, pages: [String])?
        let backend = deps.makeBackend()
        self.backend = backend

        /// 交审的那一份：covered 挂好，诊断按最终条目记一次
        func take(_ submitted: CatalogItems.Parsed, seen given: CatalogSources, pages: [String]) {
            out.items = submitted.items
            out.dropped = submitted.dropped
            out.incomplete = forced == .rounds || forced == .chars
            let named = submitted.coveredPage.flatMap { pages.contains($0) || $0 == job.path ? $0 : nil }
            if submitted.coveredPage != nil, named == nil, !submitted.covered.isEmpty {
                // 点名了却挂不上：不改挂到别的页，这几条碎片留在池里
                out.covered = []
                run.section("Agent「\(job.topic)」covered 没挂", body: "covered_page「\(submitted.coveredPage ?? "")」不是读过的页，\(submitted.covered.count) 条 covered 碎片没挂、留在池里")
            } else {
                let path = named ?? job.path ?? out.items.first?.change.targetPath ?? (pages.count == 1 ? pages[0] : "")
                out.covered = CatalogItems.attachCovered(&out.items, covered: submitted.covered, path: path, version: given.versions[path])
            }
            let provided = Dictionary(given.fragments.values.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            out.single = submitted.single.filter { provided[$0].map { $0.organizedPage == nil && !$0.rejected } ?? false }
            out.reason = submitted.reason
            out.unapplied = submitted.unapplied
            out.revision = submitted.revision
            var final = submitted
            final.items = out.items
            final.single = out.single
            out.diagnostics = CatalogDiagnostics.record(final, sources: given, final: true, title: "Agent「\(job.topic)」", run: run)
        }

        func takeFirst(_ why: String) {
            guard var first = firstDraft else { return }
            first.parsed.revision = CatalogChecks.fellBack(why)
            run.section("Agent「\(job.topic)」重写用不了", body: first.parsed.revision ?? "")
            take(first.parsed, seen: first.seen, pages: first.pages)
            firstDraft = nil
        }

        /// 修订之后只要不是被取消，用不了就交第一稿；被预算拦下照样往上报「被拦」，让后面的主题停下
        func finish(_ stop: Stop) async -> Outcome {
            var stop = stop
            if firstDraft != nil {
                switch stop {
                case .gaveUp:
                    takeFirst("后没再交")
                    stop = .submitted
                case .failed(let message):
                    takeFirst("那轮出错（\(message)）")
                    stop = .submitted
                case .blocked(let why): takeFirst("那轮被预算拦下（\(why)）")
                case .submitted, .cancelled: break
                }
            }
            out.stop = stop
            let reason: String
            switch stop {
            case .submitted: reason = "已提交"
            case .gaveUp: reason = "到顶未提交"
            case .blocked(let why): reason = "被拦：\(why)"
            case .cancelled: reason = "已取消"
            case .failed(let message): reason = "异常：\(message)"
            }
            run.section("Agent 结束 · \(job.topic)", body: "结果：\n\(CatalogRunRecord.code(reason))\n\n轮数：\(out.rounds)\n\n累计 toolChars：\(out.toolChars)\n\n条目：\(out.items.count)\n\n丢弃：\(out.dropped)\n\n未整理完：\(out.incomplete)")
            await run.flush()
            return out
        }

        func feedback(_ text: String) -> String {
            let clipped = String(text.prefix(max(0, Self.maxToolChars - out.toolChars)))
            out.toolChars += clipped.count
            return clipped
        }

        func remind(_ note: String, reply: String?) {
            let room = max(0, Self.maxToolChars - out.toolChars - 2)
            guard room > 0 else { return }
            let text = String(note.prefix(room))
            out.toolChars += text.count + 2
            Self.remind(text, history: &history, turns: &turns, reply: reply)
        }

        while true {
            if isCancelled { return await finish(.cancelled) }
            let finalChance = forced != nil
            let isLastRound = out.rounds + 1 >= max(1, job.maxRounds)
            out.rounds += 1
            onRound?(out.rounds)
            let request = AssistantBackendRequest(system: system, history: history, tools: CatalogAgentTools.definitions(submitOnly: finalChance),
                                                  toolTurns: turns, maxTokens: Self.maxTokens)
            currentAnchor = run.section("Agent「\(job.topic)」第 \(out.rounds) 轮 · 系统提示与请求", body: Self.traceRequest(Self.shown(request, user: job.names.user)))
            if let why = await deps.gate(Self.payload(system, history, turns)) {
                await blocked(job, drafts: drafts, why: why, round: out.rounds, executed: executed)
                return await finish(.blocked(why))
            }
            if isCancelled { return await finish(.cancelled) }
            let response = await step(backend, request, user: job.names.user)
            let modelText: String
            let eventName: String
            var callsText = ""
            switch response.event {
            case .finished(let text): modelText = text; eventName = "finished"
            case .toolCalls(let calls):
                modelText = response.text
                eventName = "toolCalls"
                callsText = "\n\n### 工具调用\n" + Self.traceCalls(calls)
            case .failed(let message): modelText = response.text; eventName = "failed：\(message)"
            case .token: modelText = response.text; eventName = "token"
            }
            run.section("第 \(out.rounds) 轮模型回复", body: "事件：\n" + CatalogRunRecord.code(eventName) + "\n\n### 模型正文\n" + CatalogRunRecord.code(modelText) + callsText)
            if isCancelled { return await finish(.cancelled) }
            let cost = deps.roundCost(backend)
            run.section("第 \(out.rounds) 轮用量", body: "cost：\(cost.map { String($0) } ?? "未知")\n\n累计 toolChars：\(out.toolChars)")

            switch response.event {
            case .token:
                continue
            case .failed(let message):
                await log(job, "第 \(out.rounds) 轮出错：\(message)", ok: false, cost: cost)
                return await finish(.failed(message))
            case .finished(let text):
                await log(job, "第 \(out.rounds) 轮没调工具" + (finalChance || revised ? "，也没交" : "，提醒它交"), ok: !finalChance && !revised, cost: cost)
                if finalChance || revised { return await finish(.gaveUp) }
                let next: Forced = out.rounds + 2 >= job.maxRounds ? .rounds : .noSubmit
                forced = next
                remind(next.note, reply: text)
                run.section("第 \(out.rounds) 轮补充提醒", body: Self.traceRequest(Self.shown(AssistantBackendRequest(system: system, history: history, tools: request.tools, toolTurns: turns), user: job.names.user)) + "\n\n累计 toolChars：\(out.toolChars)")
            case .toolCalls(let calls):
                seen = sources
                seenPages = readPages
                var results: [ToolResultBlock] = []
                var notes: [String] = []
                var submitted: CatalogItems.Parsed?
                /// 修订之后交来的那一份用不了：交第一稿（没有第一稿就到此为止）
                var settled: Stop?
                var retrySubmit = false
                for call in calls {
                    if call.name == CatalogAgentTools.submit {
                        let json = call.argumentsJSON
                        let snapshot = seen
                        let round = out.rounds
                        let topic = job.topic
                        let user = job.names.user
                        let body = response.text
                        let (parsed, draft, parseError) = await Task.detached(priority: .utility) {
                            var failure = ""
                            let parsed = CatalogItems.parse(json, sources: snapshot, wiki: wiki, truncated: call.truncated, user: user) { failure = $0 }
                            let draft = drafts.saveSubmit(argumentsJSON: json, text: body, truncated: call.truncated,
                                                          parsed: parsed, topic: topic, round: round)
                            return (parsed, draft, failure)
                        }.value
                        /// 截断只截在诊断里时正文照收；正文本身不完整才算截断
                        let truncated = call.truncated && parsed == nil
                        run.section("第 \(out.rounds) 轮 submit 解析 · \(call.id)", body: "### 原参数\n" + CatalogRunRecord.code(json, language: "json") + "\n\n" + Self.traceSubmit(parsed, parseError: parseError, truncated: truncated))
                        if let parsed { CatalogWriter.recordChecks(parsed, names: job.names, title: "第 \(out.rounds) 轮 submit · \(call.id)", run: run) }
                        let tookBefore = submitted != nil
                        if isCancelled { return await finish(.cancelled) }
                        let text: String
                        let note: String
                        var rejected = false
                        if revised {
                            if !truncated, var parsed, parsed.deliverable {
                                parsed.revision = CatalogChecks.revised(parsed)
                                submitted = parsed
                                text = "收到 \(parsed.items.count) 条"
                                note = "交了 \(parsed.items.count) 条（\(parsed.revision ?? "")）"
                            } else {
                                let why = truncated ? "那次输出被截断" : parsed == nil ? "那次格式不对（\(parseError)）"
                                    : "那次交的没有能用的内容（\(parsed?.dropReasons.joined(separator: "；") ?? "")）"
                                if firstDraft != nil {
                                    takeFirst(why)
                                    settled = .submitted
                                    text = "收到（\(why)，交的是上一稿）"
                                    note = "重写用不了，交上一稿"
                                } else if let parsed {
                                    submitted = parsed
                                    text = "收到 \(parsed.items.count) 条"
                                    note = "重写后交了 \(parsed.items.count) 条"
                                } else {
                                    settled = .gaveUp
                                    text = "收到（\(why)），不再重交"
                                    note = "重写用不了"
                                }
                            }
                        } else if truncated {
                            if isLastRound {
                                text = "最后一轮输出被截断"
                                note = "最后一轮输出被截断"
                            } else {
                                text = "输出太长被截断了：少写几条（比如先交最重要的一两页），或者把记录写短"
                                note = "交的输出被截断"
                                rejected = true
                            }
                        } else if var parsed {
                            if let note = CatalogItems.coveredPageCheck(parsed, allowed: { seenPages.contains($0) || $0 == job.path }) {
                                parsed.checks.append(note)
                            }
                            let allDropped = parsed.items.isEmpty && parsed.unapplied.isEmpty && parsed.dropped > 0
                            if allDropped || !parsed.revisionNotes.isEmpty, !isLastRound {
                                revised = true
                                rejected = true
                                if !parsed.items.isEmpty || !parsed.unapplied.isEmpty { firstDraft = (parsed, snapshot, seenPages) }
                                text = allDropped
                                    ? "交的条目全部被扔掉了，按以下原因修正后重交：\n" + parsed.dropReasons.joined(separator: "\n")
                                    : "这几处没过检查。只改这几处，别的照旧，整份重交：\n" + parsed.revisionNotes.map { "- " + $0 }.joined(separator: "\n")
                            } else if !parsed.deliverable, parsed.dropped == 0, out.toolChars > 0, parsed.reason == nil, !isLastRound, !retriedEmpty {
                                retriedEmpty = true
                                rejected = true
                                text = "你交了空的。如果查到的东西里确实没有值得进 wiki 的，用 reason 说明为什么；否则把查到的写成条目重交。"
                            } else {
                                if !parsed.revisionNotes.isEmpty { parsed.revision = CatalogChecks.noChance }
                                submitted = parsed
                                text = "收到 \(parsed.items.count) 条"
                            }
                            note = "交了 \(parsed.items.count) 条"
                                + (parsed.items.isEmpty ? parsed.reason.map { "：\($0)" } ?? "" : "")
                                + (parsed.dropped > 0 ? "（扔了 \(parsed.dropped) 处）" : "")
                        } else {
                            text = "格式不对：\(parseError)\n参数要是 {\"items\":[…]}，照系统提示的格式重交"
                            note = "交的格式不对"
                            rejected = true
                        }
                        retrySubmit = retrySubmit || rejected
                        if let parsed, tookBefore || submitted == nil {
                            CatalogDiagnostics.record(parsed, sources: snapshot, final: false, title: "第 \(out.rounds) 轮 submit · \(call.id)", run: run)
                        }
                        notes.append(note + (draft.map { " · 草稿 " + $0.lastPathComponent } ?? " · 草稿已达 12 份上限"))
                        results.append(ToolResultBlock(toolUseId: call.id, text: feedback(text), isError: rejected))
                        run.section("第 \(out.rounds) 轮 submit 实际回执 · \(call.id)", body: Self.traceResults([results[results.count - 1]]) + "\n\n累计 toolChars：\(out.toolChars)")
                        continue
                    }
                    let room = Self.maxToolChars - Self.reserve - out.toolChars
                    if finalChance || room <= CatalogAgentTools.clipNote.count {
                        let text = feedback("不能再查了，现在只能 submit_proposal")
                        results.append(ToolResultBlock(toolUseId: call.id, text: text, isError: true))
                        run.section("第 \(out.rounds) 轮工具实际回执 · \(call.id)", body: Self.traceResults([results[results.count - 1]]) + "\n\n累计 toolChars：\(out.toolChars)")
                        continue
                    }
                    let output = await tools.execute(name: call.name, argumentsJSON: call.argumentsJSON, now: Date())
                    if isCancelled {
                        run.section("第 \(out.rounds) 轮取消前工具结果 · \(call.id)", body: "isError：\(output.isError)\n\n" + CatalogRunRecord.code(output.text) + "\n\n（已取消，未回灌）")
                        return await finish(.cancelled)
                    }
                    let limit = output.receipt != nil ? room : min(CatalogAgentTools.resultLimit, room)
                    var text = feedback(CatalogAgentTools.clip(output.text, limit: limit))
                    if let receipt = output.receipt {
                        let count = text.hasSuffix(CatalogAgentTools.clipNote) ? text.count - CatalogAgentTools.clipNote.count : text.count
                        let visible = receipt.prefix(count)
                        visible.register(in: &sources)
                        let evidence = visible.evidence()
                        out.searchedChars += evidence.searchedChars
                        run.recordSearch(evidence)
                        let query = WikiFeedback.query(receipt: visible)
                        let previous = sentFeedback
                        var additional = await Task.detached(priority: .utility) {
                            WikiFeedback.select(query, wiki: wiki, now: Date(), previous: previous)
                        }.value
                        let remaining = Self.maxToolChars - Self.reserve - out.toolChars
                        while let rendered = WikiFeedback.render(additional), rendered.count + 2 > remaining {
                            additional.removeFirst()
                        }
                        if let rendered = WikiFeedback.render(additional) {
                            text += feedback("\n\n" + rendered)
                            sentFeedback += additional
                        }
                    }
                    if case .page(let path, let version) = output.seen {
                        sources.versions[path] = version
                        if !readPages.contains(path) { readPages.append(path) }
                    }
                    let what = CatalogAgentTools.describe(call.name, call.argumentsJSON)
                    notes.append("\(what) \(text.count) 字")
                    executed.append("\(what) · 参数 \(call.argumentsJSON) · 回 \(text.count) 字" + (output.isError ? "（出错）" : ""))
                    results.append(ToolResultBlock(toolUseId: call.id, text: text, isError: output.isError))
                    run.section("第 \(out.rounds) 轮工具实际回执 · \(call.id)", body: Self.traceResults([results[results.count - 1]]) + "\n\n累计 toolChars：\(out.toolChars)")
                }
                await log(job, "第 \(out.rounds) 轮：" + (notes.isEmpty ? "没调工具" : notes.joined(separator: "、")), ok: true, cost: cost)
                turns.append(ToolTurn(calls: calls, results: results))
                if let submitted {
                    take(submitted, seen: seen, pages: seenPages)
                    return await finish(.submitted)
                }
                if let settled { return await finish(settled) }
                if out.rounds >= max(1, job.maxRounds) || (finalChance && !retrySubmit) { return await finish(.gaveUp) }
                if out.rounds + 2 >= job.maxRounds {
                    forced = .rounds
                } else if Self.maxToolChars - Self.reserve - out.toolChars <= CatalogAgentTools.clipNote.count {
                    forced = .chars
                }
                if let forced {
                    remind(forced.note, reply: nil)
                    run.section("第 \(out.rounds) 轮补充提醒", body: Self.traceResults(turns.last?.results ?? []) + "\n\n累计 toolChars：\(out.toolChars)")
                }
            }
        }
    }

    /// 被预算拦下：查过的（工具名、参数、字数，不存全文）记进草稿，日志记一行
    private func blocked(_ job: Job, drafts: CatalogDrafts, why: String, round: Int, executed: [String]) async {
        let text = "整理「\(job.topic)」第 \(round) 轮被预算拦下（\(why)）\n查过的：\n"
            + (executed.isEmpty ? "（还没查）" : executed.map { "- " + $0 }.joined(separator: "\n")) + "\n"
        let topic = job.topic
        currentRun?.section("第 \(round) 轮被预算拦下", body: CatalogRunRecord.code(text))
        _ = await Task.detached(priority: .utility) { drafts.save(text, name: "\(topic)-被拦") }.value
        await log(job, "被预算拦下，第 \(round) 轮（\(why)）· 查过 \(executed.count) 次，记进草稿", ok: false, cost: nil)
    }

    /// 每一轮调了什么、返回多少字、花了多少，记进记忆日志
    private func log(_ job: Job, _ note: String, ok: Bool, cost: Double?) async {
        let run = currentRun?.link(anchor: currentAnchor)
        await currentRun?.flush()
        await MemoryWriteLog.metered {
            if let cost { MemoryWriteLog.addCost(cost) }
            MemoryWriteLog.record(writer: .c3, profileId: job.profileId, ok: ok, note: "整理「\(job.topic)」\(note)", model: job.modelName, run: run, memoryRoot: FileLibraryStore.memoryRoot(profileId: job.profileId))
        }
    }
}
