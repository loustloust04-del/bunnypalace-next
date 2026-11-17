import Foundation

/// 一份活的工作书（plan-agent-workspace §2.3）：任务书 + 往工作台放材料 + 交卷时程序验产出文件。
/// 循环和工具都是通用的，一份活只写这几样
public protocol AgentJob: Sendable {
    /// 任务书（system）
    var brief: String { get }
    /// 开场那句
    var opening: String { get }
    /// 工作台里能写的顶层目录
    var writable: [String] { get }
    /// 往工作台里放材料
    func prepare(_ workspace: AgentWorkspace) throws
    /// 交卷时的核对：`blocking` 不改不能结束，`hints` 只是提醒。只管格式和编号对不对得上，不管内容好坏
    func review(_ workspace: AgentWorkspace) -> (blocking: [String], hints: [String])
}

public enum AgentJobRunner {
    private struct FinishArgs: Decodable { var summary: String? }

    static let notes = AgentLoop.Notes(
        closingTools: ["write", "edit", "check", "finish"],
        closing: "快到轮数上限了：把产出文件写完整，check 一下，然后 finish。",
        truncated: "上一轮你的输出太长被截断了，什么都没写上。大文件分几次写：先 write 开头那部分，再用 edit 往后接。",
        idle: "请用工具继续：还没读完材料就 read，读完了就把产出 write 到指定的文件，写完 check 再 finish。",
        elided: "（较早的结果已省略；要看就再读一次。你写进文件的东西都还在。）")

    /// 在 `root`（调用方建好、跑完自己删）上跑一份活
    public static func run(_ job: any AgentJob, root: URL, caller: any ToolModelCaller,
                           limits: OrganizeAgent.Limits = .init(rounds: 40, contextChars: 160_000, resultChars: 32_000),
                           allow: @escaping @Sendable () async -> Bool = { true }) async -> AgentLoop.Outcome {
        let workspace = AgentWorkspace(root: root, writable: job.writable)
        do {
            for dir in job.writable {
                try FileManager.default.createDirectory(at: workspace.root.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            try job.prepare(workspace)
        } catch {
            return .init(stop: .failed, summary: nil, error: error.localizedDescription, rounds: [])
        }
        let tools = workspace.tools + [
            AgentTool(name: "check", description: "让程序核对你写的产出文件：格式对不对、编号对不对得上。",
                      schema: #"{"type":"object","properties":{}}"#) { _ in
                let found = job.review(workspace)
                let lines = found.blocking + found.hints
                return .init(lines.isEmpty ? "没看出问题。" : lines.joined(separator: "\n"))
            },
            AgentTool(name: "finish", description: "产出写完并且 check 过了，调它结束。",
                      schema: #"{"type":"object","properties":{"summary":{"type":"string","description":"一句话：这次做了什么"}}}"#) { json in
                let found = job.review(workspace)
                guard found.blocking.isEmpty else { return .init("还不能结束：\n" + found.blocking.joined(separator: "\n"), isError: true) }
                let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = (try? JSONDecoder().decode(FinishArgs.self, from: Data((text.isEmpty ? "{}" : text).utf8)))?.summary
                return .init("好。", finished: summary ?? "")
            },
        ]
        return await AgentLoop.run(system: job.brief, opening: job.opening, tools: tools, caller: caller, limits: limits, notes: notes, allow: allow)
    }
}

// MARK: - 写入这张工作书

/// 把一段新对话写成记忆（任务书 = 三轮对照实验的最后一版，plan-organize-agent §1.3.3，不调措辞）
public struct WriteJob: AgentJob {
    public struct Entry: Sendable, Equatable, Codable {
        public var id: String
        /// 改档案里已有的哪一张（nil = 新增）
        public var target: String?
        public var subject: String
        public var type: String
        public var origin: String
        public var volatile: Bool
        public var content: String
        public var msgs: [Int]
        public var since: String?
        public var confidence: Double?
    }

    public let windowTitle: String
    public let span: [WriteLine]
    /// 这段之前的原文（编号 ≤ 0）
    public let before: [WriteLine]
    public let known: [WriteKnownCard]
    public let names: MemoryExtractor.Names
    public let ownerWords: String

    public init(windowTitle: String, span: [WriteLine], before: [WriteLine] = [], known: [WriteKnownCard] = [],
                names: MemoryExtractor.Names, ownerWords: String = WriteAgent.defaultOwnerWords) {
        self.windowTitle = windowTitle
        self.span = span
        self.before = before
        self.known = known
        self.names = names
        self.ownerWords = ownerWords
    }

    static let output = "out/archive.json"
    public var writable: [String] { ["out", "notes"] }

    public var opening: String {
        "材料已经放在工作台里：这段新对话 \(span.count) 条\(before.isEmpty ? "" : "，之前的原文 \(before.count) 条")，档案里现有 \(known.count) 张卡。开始吧。"
    }

    public var brief: String {
        let day: (WriteLine?) -> String? = { $0?.when.map { String($0.prefix(10)) } }
        let dates = [day(span.first), day(span.last)].compactMap { $0 }
        let range = dates.isEmpty ? "" : "，这 \(span.count) 条的时间是 \(dates.first ?? "") 到 \(dates.last ?? "")"
        return """
        请你读一段真实的私人对话，把里面值得长期记住的东西写成一份记忆档案。怎么做由你决定，自由使用你的工具（列目录、读文件、搜索、写文件、改文件）。

        ## 材料（都在工作台里，只读）

        - `transcript.txt`：一个对话窗口新聊的 \(span.count) 条消息，一条一行，形如 `#编号 时间 · 说话人：正文`（正文里的换行写成 ` ⏎ `）。「\(names.user)」是用户，「\(names.char)」是陪她聊天的 AI。请完整读完。
        \(before.isEmpty ? "" : "- `before.txt`：这段之前的原文（编号是 0、-1、-2…，离这段越远越小）。看不懂指代、不知道前因时翻。\n")- `known.jsonl`：档案里已经有的卡，一行一张（`id`、`subject`、`content`、`since`；`archived` = 她认可过）。\(known.isEmpty ? "现在是空的，从零写。" : "")

        **这个窗口的名字是「\(windowTitle)」**\(range)。她同时开着很多个窗口，每个窗口里都有一个\(names.char)；这份档案以后会被**别的窗口**里的\(names.char)读到。

        ## 主人对这份档案说过的话（原话）

        \(ownerWords)
        - 她认可的一把尺子：**一条好的记忆 = 三个月后，\(names.char)在一个全新的窗口里翻到它，不需要再翻原文就能直接用，用它来更好地对待她。** 翻到了没法用的（不知道在说什么、不知道现在还作不作数），要么写到能用，要么不写。
        - 一条 = 一件完整的事：一个能独立使用的事实，连同它的直接原因和结果，写在一起。

        ## 之前的档案被挑出的毛病（这一版要改掉）

        1. **谁说的要分清。** 她亲口说的事，和\(names.char)的解读 / 观察 / 建议 / 台词，是两种东西。角色扮演里的话、几分钟后就反悔的气话，不是她的现实或决定。交之前逐条回出处核对：这句是谁说的？是不是在演？后面有没有改口？
        2. **事实和「该怎么对待她」分开**：「她是什么样 / 发生了什么」是 fact；「这种时候要怎么做 / 不要怎么做」是 instruction。但**同一件事只记一次**：不要把一件事的事实版和做法版各写一条；做法类条目里把它依据的那个事实一句带过就够，反过来也一样。
        3. **不要撕。** 一件事就是一条，条目里可以有三四句；「写短句、一句一个信息点」说的是条目内部怎么写，不是一条只许一句。也不要反过来把几件不相干的事塞进一条。
        4. **不要悬空的指代。** 「这个窗口」「这次」「今天」「昨天」「现在」「最近」「刚才」这类要站在原地才读得懂的词不许出现：说到这个窗口或这个窗口里的\(names.char)，就写窗口名（「\(windowTitle)」窗口的\(names.char)）；说到时间就写日期。别的窗口的\(names.char)读到时，必须一眼看出这说的是哪个窗口、哪天的事，而不会当成在说自己。
        5. **不记流程和琐碎。** 「谁问了什么、谁回了什么」的对话经过不是记忆；一次性的小事不记。
        6. **会变的状态标出来**（`volatile`）。
        7. 她的原话值得留的用引号留着。主语写在 `subject` 字段里，正文不用每句都以名字开头，但正文里出现的其他人要写名字。
        8. **档案里已经有的不要再记一遍。** 写之前对着 `known.jsonl` 看：已经有而且没变 → 不写；已经有但这段对话里有了新情况 → 写一条带 `target`（那张卡的 `id`）的、改好的整条；没有 → 新增。

        ## 产出

        写到 `out/archive.json`：JSON 数组，每个元素

        ```
        {"id":"w1",
         "target":"只在改档案里已有的卡时写：那张卡的 id",
         "subject":"这条是关于谁 / 什么的（名字）",
         "type":"fact 或 instruction",
         "origin":"said（她亲口说的或对话里直接发生的）/ assistant（\(names.char)说的，她没确认也没反驳）/ inferred（你或\(names.char)推出来的）",
         "volatile":true 或 false,
         "content":"正文",
         "msgs":[出处的消息编号…],
         "since":"这件事从什么时候起成立（YYYY-MM-DD 或 YYYY-MM，说不清就不写这个字段）",
         "confidence":0.0–1.0}
        ```

        `confidence` 只表示「这件事本身有多确定」，不用它表示「这是推断」——那个归 `origin`。按实际给。大多数闲聊里没有值得长期记的事，那就少写；一条都没有就写 `[]`。

        `notes/` 是你的草稿纸，随便用（列候选、记拿不准的），不算产出。写完用 check 让程序核对格式，再 finish。
        """
    }

    public func prepare(_ workspace: AgentWorkspace) throws {
        func transcript(_ rows: [WriteLine]) -> String {
            rows.map { "#\($0.number) \($0.when ?? "") · \($0.who)：\($0.text.replacingOccurrences(of: "\n", with: " ⏎ "))" }.joined(separator: "\n") + "\n"
        }
        try Data(transcript(span).utf8).write(to: workspace.root.appendingPathComponent("transcript.txt"), options: .atomic)
        if !before.isEmpty {
            try Data(transcript(before).utf8).write(to: workspace.root.appendingPathComponent("before.txt"), options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rows = try known.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try Data((rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")).utf8).write(to: workspace.root.appendingPathComponent("known.jsonl"), options: .atomic)
    }

    /// 读产出文件。读不成 = 错误说明；读成 = 条目 + 逐条的问题
    func parse(_ workspace: AgentWorkspace) -> (entries: [Entry], problems: [String]) {
        guard let data = try? Data(contentsOf: workspace.root.appendingPathComponent(Self.output)) else {
            return ([], ["还没有 `\(Self.output)`。没有值得记的也要写一个 `[]`。"])
        }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([], ["`\(Self.output)` 不是合法的 JSON 数组（每个元素是一个对象）。"])
        }
        let knownIds = Set(known.map(\.id))
        var entries: [Entry] = []
        var problems: [String] = []
        var seen = Set<String>()
        for (offset, row) in rows.enumerated() {
            let id = (row["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "w\(offset + 1)"
            func text(_ key: String) -> String { (row[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            var wrong: [String] = []
            if !seen.insert(id).inserted { wrong.append("id 重复") }
            if text("content").isEmpty { wrong.append("content 是空的") }
            if text("subject").isEmpty { wrong.append("缺 subject") }
            if !WriteLedger.types.contains(text("type")) { wrong.append("type 只能是 fact / instruction") }
            if !WriteLedger.origins.contains(text("origin")) { wrong.append("origin 只能是 said / assistant / inferred") }
            let msgs = (row["msgs"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }.filter { $0 >= 1 && $0 <= span.count }
            if msgs.isEmpty { wrong.append("msgs 要给 transcript.txt 里的消息编号（1–\(span.count)）") }
            let target = (row["target"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (row["target"] as? NSNumber).map { $0.stringValue }
            if let target, !knownIds.contains(target) { wrong.append("target「\(target)」不是 known.jsonl 里的 id") }
            if !wrong.isEmpty { problems.append("\(id)：\(wrong.joined(separator: "；"))"); continue }
            let since = text("since")
            entries.append(Entry(id: id, target: target, subject: text("subject"), type: text("type"), origin: text("origin"),
                                 volatile: row["volatile"] as? Bool ?? false, content: text("content"), msgs: msgs,
                                 since: since.isEmpty ? nil : since, confidence: (row["confidence"] as? NSNumber)?.doubleValue))
        }
        return (entries, problems)
    }

    public func review(_ workspace: AgentWorkspace) -> (blocking: [String], hints: [String]) {
        let parsed = parse(workspace)
        var hints: [String] = []
        for entry in parsed.entries {
            let hits = WriteLedger.dangling.filter { entry.content.contains($0) }
            if !hits.isEmpty {
                hints.append("\(entry.id) 里有「\(hits.joined(separator: "」「"))」：别的窗口读到会当成说自己。说到这个窗口写「\(windowTitle)」，说到时间写日期（引号里她的原话不用改）")
            }
        }
        return (parsed.problems, hints)
    }

    /// 收卷：合格的条目
    public func collect(_ workspace: AgentWorkspace) -> [Entry] { parse(workspace).entries }
}
