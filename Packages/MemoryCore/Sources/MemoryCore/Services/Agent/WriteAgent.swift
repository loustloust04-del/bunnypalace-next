import Foundation

// 写入 agent（plan-write-agent）：窗口停下来后把这段新对话读一遍，能往前翻、能查已记的，
// 交两样：事实卡，和「有来龙去脉的事」给 wiki 的段落。循环和调用口沿用整理 agent 那套。
// 只读数据、只写账本，不碰库、不碰文件。

public struct WriteLine: Sendable, Equatable {
    /// 这段新对话里从 1 数的编号；往前翻出来的更早原文是 0、-1、-2…
    public let number: Int
    public let who: String
    public let when: String?
    public let text: String

    public init(number: Int, who: String, when: String? = nil, text: String) {
        self.number = number
        self.who = who
        self.when = when
        self.text = text
    }
}

/// 档案里已经有的一张卡
public struct WriteKnownCard: Sendable, Equatable, Codable {
    public let id: String
    public let content: String
    public let subject: String?
    public let since: String?
    /// 她 Approve 过的：只能提 Suggestion
    public let archived: Bool

    public init(id: String, content: String, subject: String? = nil, since: String? = nil, archived: Bool = false) {
        self.id = id
        self.content = content
        self.subject = subject
        self.since = since
        self.archived = archived
    }
}

public struct WritePage: Sendable, Equatable {
    public let path: String
    public let hook: String

    public init(path: String, hook: String) {
        self.path = path
        self.hook = hook
    }
}

/// 写入 agent 读数据的口子。memoryd 读副本，app 读库
public protocol WriteSource: Sendable {
    /// 这个窗口的名字（条目里说到这个窗口要写它）
    var windowTitle: String { get }
    /// 这次要处理的新对话，编号从 1 起
    func span() throws -> [WriteLine]
    /// 这段之前的原文，离得近的在后；`skip` = 已经往前翻过几条
    func before(count: Int, skip: Int) throws -> [WriteLine]
    /// 按词搜原文（跨窗口）
    func search(_ terms: String, limit: Int) throws -> [OrganizeSourceLine]
    /// 档案里已有的卡
    func known() throws -> [WriteKnownCard]
    /// wiki 现有的页
    func pages() throws -> [WritePage]
}

/// 写入的账本：交上来的卡和给 wiki 的段落。存在循环外面，上下文裁掉也不丢
public struct WriteLedger: Sendable, Equatable, Codable {
    public struct Card: Sendable, Equatable, Codable {
        /// 账本里的编号（n1、n2…）
        public var key: String
        /// 改已有的哪一张（nil = 新增）
        public var target: String?
        /// target 是 Archive 里的卡：这条只是 Suggestion
        public var suggestion: Bool
        public var subject: String
        public var type: String
        public var origin: String
        public var volatile: Bool
        public var content: String
        public var msgs: [Int]
        public var since: String?
        public var confidence: Double?
    }

    public struct Note: Sendable, Equatable, Codable {
        /// p1、p2…
        public var key: String
        public var title: String
        /// 建议放进哪一页；nil = 新页（名字用 title）
        public var page: String?
        public var content: String
        /// 撑着它的卡：账本里的 n… 或档案里已有的编号
        public var cards: [String]
    }

    public struct Receipt: Sendable, Equatable {
        /// 收下的编号
        public var accepted: [String] = []
        /// 其中改的是她认可过的卡（只算建议）
        public var suggestions: [String] = []
        public var rejected: [String] = []
    }

    public var cards: [Card] = []
    public var notes: [Note] = []
    private var cardSeq = 0
    private var noteSeq = 0

    public init() {}

    static let types: Set<String> = ["fact", "instruction"]
    static let origins: Set<String> = ["said", "assistant", "inferred"]
    /// 要站在原地才读得懂的说法（核对时提醒，不拦）
    static let dangling = ["这个窗口", "本窗口", "今天", "昨天", "明天", "刚才", "刚刚", "这次"]

    public struct CardInput: Sendable, Equatable {
        public var key: String?
        public var target: String?
        public var subject: String?
        public var type: String?
        public var origin: String?
        public var volatile: Bool?
        public var content: String?
        public var msgs: [Int]
        public var since: String?
        public var confidence: Double?
    }

    /// 一件事：标题 + 一段现状和原因（给 wiki 的）+ 它底下的几条事实卡
    public struct MatterInput: Sendable, Equatable {
        public var key: String?
        public var title: String?
        public var page: String?
        public var summary: String?
        public var facts: [CardInput]
    }

    /// 交一批卡。带 key = 顶掉之前交的那条。逐条验，不合格的退回并说原因
    public mutating func submit(cards inputs: [CardInput], span: ClosedRange<Int>, known: [WriteKnownCard]) -> Receipt {
        var receipt = Receipt()
        let knownById = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (offset, input) in inputs.enumerated() {
            let label = "卡第 \(offset + 1) 条"
            let content = (input.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = (input.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { receipt.rejected.append("\(label)：content 是空的"); continue }
            guard !subject.isEmpty else { receipt.rejected.append("\(label)：要写 subject（这条是关于谁 / 什么的，写名字）"); continue }
            guard let type = input.type, Self.types.contains(type) else { receipt.rejected.append("\(label)：type 只能是 fact 或 instruction"); continue }
            guard let origin = input.origin, Self.origins.contains(origin) else {
                receipt.rejected.append("\(label)：origin 只能是 said / assistant / inferred"); continue
            }
            let msgs = input.msgs.filter { span.contains($0) }
            guard !msgs.isEmpty else { receipt.rejected.append("\(label)：msgs 要给出处的消息编号（这段对话的第 \(span.lowerBound)–\(span.upperBound) 条里）"); continue }
            var suggestion = false
            if let target = input.target {
                guard let old = knownById[target] else { receipt.rejected.append("\(label)：档案里没有编号为 \(target) 的卡"); continue }
                suggestion = old.archived
            }
            var card = Card(key: "", target: input.target, suggestion: suggestion, subject: subject, type: type, origin: origin,
                            volatile: input.volatile ?? false, content: content, msgs: msgs,
                            since: input.since?.trimmingCharacters(in: .whitespaces).nilIfEmpty, confidence: input.confidence)
            if let key = input.key {
                guard let index = cards.firstIndex(where: { $0.key == key }) else { receipt.rejected.append("\(label)：没有交过编号为 \(key) 的卡"); continue }
                card.key = key
                cards[index] = card
            } else {
                cardSeq += 1
                card.key = "n\(cardSeq)"
                cards.append(card)
            }
            receipt.accepted.append(card.key)
            if suggestion { receipt.suggestions.append(card.key) }
        }
        return receipt
    }

    /// 交一件事。带 key = 整件重交（原来底下的卡一起换掉）。底下一条事实都没收下的整件退回
    public mutating func submit(matter input: MatterInput, label: String, span: ClosedRange<Int>, known: [WriteKnownCard]) -> Receipt {
        var receipt = Receipt()
        let title = (input.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (input.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !summary.isEmpty else { receipt.rejected.append("\(label)：title 和 summary 都要有"); return receipt }
        guard !input.facts.isEmpty else { receipt.rejected.append("\(label)：facts 里至少要有一条事实卡"); return receipt }
        var index: Int?
        if let key = input.key {
            guard let found = notes.firstIndex(where: { $0.key == key }) else { receipt.rejected.append("\(label)：没有交过编号为 \(key) 的事"); return receipt }
            index = found
        }
        let backup = self
        if let index {
            let own = Set(notes[index].cards)
            cards.removeAll { own.contains($0.key) }
        }
        let made = submit(cards: input.facts.map { var fact = $0; fact.key = nil; return fact }, span: span, known: known)
        receipt.rejected = made.rejected.map { "\(label) 底下的\($0)" }
        guard !made.accepted.isEmpty else {
            self = backup
            receipt.rejected.append("\(label)：底下一条事实都没收下，整件没记上")
            return receipt
        }
        var note = Note(key: "", title: title, page: input.page?.trimmingCharacters(in: .whitespaces).nilIfEmpty, content: summary, cards: made.accepted)
        if let index {
            note.key = notes[index].key
            notes[index] = note
        } else {
            noteSeq += 1
            note.key = "p\(noteSeq)"
            notes.append(note)
        }
        receipt.accepted = [note.key] + made.accepted
        receipt.suggestions = made.suggestions
        return receipt
    }

    /// 撤回：n… 撤一张卡；p… 撤一件事连同它底下的卡
    public mutating func remove(_ keys: [String]) -> Int {
        let before = cards.count + notes.count
        var gone = Set(keys)
        for note in notes where gone.contains(note.key) { gone.formUnion(note.cards) }
        cards.removeAll { gone.contains($0.key) }
        notes.removeAll { gone.contains($0.key) }
        for index in notes.indices { notes[index].cards.removeAll { gone.contains($0) } }
        return before - cards.count - notes.count
    }

    /// 程序看得出来的毛病。`blocking` 的不改不能结束；其余只是提醒
    public func problems(windowTitle: String) -> (blocking: [String], hints: [String]) {
        var blocking: [String] = []
        var hints: [String] = []
        for note in notes where note.cards.isEmpty { blocking.append("\(note.key)「\(note.title)」底下的卡都被撤回了：带 key 重交这件事，或者把它也撤回") }
        var seen: [String: String] = [:]
        for card in cards {
            if let first = seen[card.content] { blocking.append("卡 \(card.key) 和 \(first) 一字不差") } else { seen[card.content] = card.key }
        }
        func scan(_ key: String, _ text: String) {
            let hits = Self.dangling.filter { text.contains($0) }
            if !hits.isEmpty { hints.append("\(key) 里有「\(hits.joined(separator: "」「"))」：别的窗口读到会当成说自己。说到这个窗口写「\(windowTitle)」，说到时间写日期（引号里她的原话不用改）") }
        }
        for card in cards { scan(card.key, card.content) }
        for note in notes { scan(note.key, note.content) }
        // 字面很像的两张：只是提醒，是不是同一件事它自己看
        let sets = cards.map { Set(MemoryBM25.tokens($0.subject + " " + $0.content)) }
        for a in cards.indices {
            for b in cards.indices where b > a {
                let shared = sets[a].intersection(sets[b]).count
                if shared * 2 >= max(min(sets[a].count, sets[b].count), 1), shared > 0 {
                    hints.append("\(cards[a].key) 和 \(cards[b].key) 字面很像：是同一件事就留一张（另一张 remove）")
                }
            }
        }
        return (blocking, hints)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum WriteAgent {
    public struct Outcome: Sendable, Equatable {
        public var ledger: WriteLedger
        public var stop: OrganizeAgent.Stop
        public var summary: String?
        public var error: String?
        public var rounds: [OrganizeAgent.Round]

        public var inputTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.input ?? 0) } }
        public var outputTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.output ?? 0) } }
        public var cacheReadTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.cacheRead ?? 0) } }
    }

    // MARK: - 给它的话（三轮对照实验的最后一版任务书，plan-organize-agent §1.3.3；不再调措辞）

    public static let defaultOwnerWords = """
    - 「我想要的是精准的增加，不是加屎不是记录流程，你理解吗？精准的事实！」
    - 「原话是事实，A 是纪录片，B 是日记，C 是活档案。」（这份是 C）
    - 「现在写的也有很多错 / 太短 / 太没头没尾。」「切这么碎！」
    """

    public static func systemPrompt(names: MemoryExtractor.Names, windowTitle: String, from: String?, to: String?,
                                    ownerWords: String = defaultOwnerWords) -> String {
        let dates = [from, to].compactMap { $0 }
        let range = dates.isEmpty ? "" : "，这段对话的时间是 \(dates.first ?? "") 到 \(dates.last ?? "")"
        return """
        你在给一份长期记忆档案写新内容。档案的主人是\(names.user)；\(names.char)是陪她聊天的那一位。

        她刚在一个窗口里聊完一段，请你把这段新对话完整读一遍，把里面值得长期记住的东西写进档案。**这个窗口的名字是「\(windowTitle)」**\(range)。她同时开着很多个窗口，每个窗口里都有一个\(names.char)；这份档案以后会被**别的窗口**里的\(names.char)读到。

        主人对这份档案说过的话（原话）：
        \(ownerWords)
        她认可的一把尺子：一条好的记忆 = 三个月后，\(names.char)在一个全新的窗口里翻到它，不需要再翻原文就能直接用，用它来更好地对待她。翻到了没法用的（不知道在说什么、不知道现在还作不作数），要么写到能用，要么不写。大多数闲聊里没有值得长期记的事，那就不写。

        你交的单位是**「一件事」**（submit 的 matters），每件事有三样：
        - title：这是哪件事。
        - summary：这件事**现在是什么情况、为什么**，几句话，带日期。它以后会被放进 wiki 里这件事的那一页；判断该写什么：下个月这件事变了，这段要改的那些内容才写，「那几天是怎么来回变的」不用写。
        - facts：这件事底下的事实卡，一张 = 一个能独立使用的事实，一两句。来龙去脉已经在 summary 里，卡不用再背一遍；但每张卡单独拿出来要读得懂。
        不成一件事的零散事实，放在 submit 的 cards 里单交。

        每张事实卡（matters 里的 facts 和单交的 cards 都一样）：
        1. 谁说的要分清（origin）：said = 她亲口说的或对话里直接发生的；assistant = \(names.char)说的，她没确认也没反驳；inferred = 推出来的。角色扮演里的话、几分钟后就反悔的气话，不是她的现实或决定。交之前逐条回出处核对：这句是谁说的？是不是在演？后面有没有改口？
        2. 事实和「该怎么对待她」分开（type）：「她是什么样 / 发生了什么」是 fact；「这种时候要怎么做 / 不要怎么做」是 instruction。同一件事只记一次，不要事实版、做法版各写一张。
        3. 不要悬空的指代：「这个窗口」「这次」「今天」「昨天」「现在」「最近」「刚才」这类要站在原地才读得懂的词不许出现（summary 里也一样）。说到这个窗口或这个窗口里的\(names.char)，写窗口名；说到时间写日期。
        4. 不记流程和琐碎：「谁问了什么、谁回了什么」不是记忆；一次性的小事不记。
        5. 会变的状态（「正在考虑」「还没定」）标 volatile。
        6. 她的原话值得留的用引号留着。主语写在 subject 里，正文不用每句都以名字开头，但正文里出现的其他人要写名字。
        7. confidence 只表示这件事本身有多确定，不用它表示「这是推断」。since = 这件事从什么时候起成立，说不清就不写。
        8. **先查已记的**：交一张卡之前用 search_memory 看档案里是不是已经有说同一件事的。已经有而且没变 → 不交；已经有但这段对话里有了新情况 → 带上 target（那张卡的编号）交改好的整条；没有 → 新增。

        同一个事实只出现在一件事底下，不要在两件事里各记一遍。page 填这件事该放进 wiki 的哪一页（list_pages 里的路径），没有合适的页就不填。

        你有这些工具：
        - read_span：分页读这段新对话。先把它全部读完再动手。
        - read_before：往前翻这段之前的原文（看不懂指代、不知道前因时用）。
        - search_source：按词搜原文，跨窗口核对。
        - search_memory：按词查档案里已有的卡（也包括你这次已经交的）。
        - list_pages：看 wiki 现有哪些页。
        - submit：交一批事（matters）和 / 或零散的卡（cards）。可以分很多次交；一件事带上 key（p…）是整件重交；remove 里列编号是撤回（p… 连同它底下的卡一起撤）。
        - list_submitted：通看你到现在交过的全部。全部交完之后看一遍：有没有同一件事记了两遍、有没有该并成一件事的、有没有漏的，再改。
        - check：让程序核对。
        - finish：都交完、check 过了，调它结束。
        """
    }

    // MARK: - 工具

    static let tools: [AgentToolSpec] = [
        AgentToolSpec(name: "read_span", description: "分页读这段新对话。每条：#编号 时间 · 说话人：正文。",
                      schema: #"{"type":"object","properties":{"from":{"type":"integer","description":"从第几条开始，默认 1"},"count":{"type":"integer","description":"读几条，默认 80，最多 150"}}}"#),
        AgentToolSpec(name: "read_before", description: "往前翻这段之前的原文（编号是 0、-1、-2…，离这段越远越小）。",
                      schema: #"{"type":"object","properties":{"count":{"type":"integer","description":"翻几条，默认 30，最多 100"},"skip":{"type":"integer","description":"跳过离这段最近的几条（已经翻过的），默认 0"}}}"#),
        AgentToolSpec(name: "search_source", description: "按词搜原文（所有窗口）。",
                      schema: #"{"type":"object","properties":{"terms":{"type":"string","description":"要搜的词"}},"required":["terms"]}"#),
        AgentToolSpec(name: "search_memory", description: "按词查档案里已有的卡和你这次已经交的卡，字面相近的在前。",
                      schema: #"{"type":"object","properties":{"terms":{"type":"string","description":"要查的词或一句话"},"limit":{"type":"integer","description":"最多几张，默认 8"}},"required":["terms"]}"#),
        AgentToolSpec(name: "list_pages", description: "看 wiki 现有哪些页：路径和一句话。",
                      schema: #"{"type":"object","properties":{}}"#),
        AgentToolSpec(name: "submit", description: "交一批事和 / 或零散的事实卡。",
                      schema: #"{"type":"object","properties":{"matters":{"type":"array","items":{"type":"object","properties":{"key":{"type":"string","description":"只在整件重交时填：p…"},"title":{"type":"string","description":"这是哪件事"},"page":{"type":"string","description":"建议放进 wiki 的哪一页；没有合适的不填"},"summary":{"type":"string","description":"这件事现在是什么情况、为什么"},"facts":{"type":"array","items":{"type":"object","properties":{"target":{"type":"string","description":"只在改档案里已有的卡时填：那张卡的编号"},"subject":{"type":"string"},"type":{"type":"string","enum":["fact","instruction"]},"origin":{"type":"string","enum":["said","assistant","inferred"]},"volatile":{"type":"boolean"},"content":{"type":"string"},"msgs":{"type":"array","items":{"type":"integer"},"description":"出处的消息编号"},"since":{"type":"string","description":"YYYY-MM-DD 或 YYYY-MM"},"confidence":{"type":"number"}},"required":["subject","type","origin","content","msgs"]}}},"required":["title","summary","facts"]}},"cards":{"type":"array","description":"不成一件事的零散事实","items":{"type":"object","properties":{"target":{"type":"string","description":"只在改档案里已有的卡时填：那张卡的编号"},"subject":{"type":"string"},"type":{"type":"string","enum":["fact","instruction"]},"origin":{"type":"string","enum":["said","assistant","inferred"]},"volatile":{"type":"boolean"},"content":{"type":"string"},"msgs":{"type":"array","items":{"type":"integer"},"description":"出处的消息编号"},"since":{"type":"string","description":"YYYY-MM-DD 或 YYYY-MM"},"confidence":{"type":"number"}},"required":["subject","type","origin","content","msgs"]}},"remove":{"type":"array","items":{"type":"string"},"description":"撤回你之前交的：n… 或 p…"}}}"#),
        AgentToolSpec(name: "list_submitted", description: "通看你到现在交过的全部：每件事和它底下的卡，以及零散的卡。",
                      schema: #"{"type":"object","properties":{}}"#),
        AgentToolSpec(name: "check", description: "让程序核对交上来的东西。",
                      schema: #"{"type":"object","properties":{}}"#),
        AgentToolSpec(name: "finish", description: "都交完并且 check 过了，调它结束。这段里没有值得记的也可以直接结束。",
                      schema: #"{"type":"object","properties":{"summary":{"type":"string","description":"一句话：这次记了什么"}}}"#),
    ]

    private struct SpanArgs: Decodable { var from: Int?; var count: Int? }
    private struct BeforeArgs: Decodable { var count: Int?; var skip: Int? }
    private struct TermsArgs: Decodable { var terms: String; var limit: Int? }
    private struct FinishArgs: Decodable { var summary: String? }
    private struct SubmitArgs: Decodable {
        struct Card: Decodable {
            var target: Flexible?; var subject: String?; var type: String?; var origin: String?
            var volatile: Bool?; var content: String?; var msgs: [Int]?; var since: String?; var confidence: Double?

            var input: WriteLedger.CardInput {
                .init(key: nil, target: target?.value, subject: subject, type: type, origin: origin, volatile: volatile,
                      content: content, msgs: msgs ?? [], since: since, confidence: confidence)
            }
        }
        struct Matter: Decodable { var key: String?; var title: String?; var page: String?; var summary: String?; var facts: [Card]? }
        var matters: [Matter]?
        var cards: [Card]?
        var remove: [String]?
    }

    private struct Flexible: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let text = try? c.decode(String.self) { value = text } else { value = String(try c.decode(Int.self)) }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? JSONDecoder().decode(type, from: Data((text.isEmpty ? "{}" : text).utf8))
    }

    private static func show(_ rows: [WriteLine]) -> String {
        rows.map { "#\($0.number)\($0.when.map { " \($0)" } ?? "") · \($0.who)：\($0.text)" }.joined(separator: "\n")
    }

    /// 按「共有的词有多稀罕」给卡排队（词的切法同 `MemoryBM25.tokens`）；一个词都不共有的不出
    static func rank(_ terms: String, in rows: [(id: String, text: String)], limit: Int) -> [String] {
        let query = Set(MemoryBM25.tokens(terms))
        guard !query.isEmpty else { return [] }
        let sets = rows.map { Set(MemoryBM25.tokens($0.text)) }
        var df: [String: Int] = [:]
        for set in sets { for term in set { df[term, default: 0] += 1 } }
        let n = Double(max(rows.count, 1))
        let scored = rows.indices.compactMap { index -> (String, Double)? in
            let score = query.intersection(sets[index]).reduce(0.0) { $0 + log(1 + n / Double(df[$1] ?? 1)) }
            return score > 0 ? (rows[index].id, score / sqrt(Double(max(sets[index].count, 1)))) : nil
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    struct Desk {
        let span: [WriteLine]
        let known: [WriteKnownCard]
        let pages: [WritePage]
        let windowTitle: String
        var range: ClosedRange<Int> { 1...max(span.count, 1) }
    }

    /// 跑一个工具。返回给模型看的文字；finished = 它成功 finish 了
    static func execute(_ call: AgentToolCall, desk: Desk, source: any WriteSource,
                        ledger: inout WriteLedger) -> (content: String, isError: Bool, finished: String?) {
        switch call.name {
        case "read_span":
            let args = decode(SpanArgs.self, call.arguments)
            let from = max(args?.from ?? 1, 1)
            let count = min(max(args?.count ?? 80, 1), 150)
            let page = desk.span.dropFirst(from - 1).prefix(count)
            guard !page.isEmpty else { return ("没有更多了（这段一共 \(desk.span.count) 条）。", false, nil) }
            let last = from + page.count - 1
            return (show(Array(page)) + "\n\n第 \(from)–\(last) 条，共 \(desk.span.count) 条\(last < desk.span.count ? "，下一页 from=\(last + 1)" : "，已经到底")。", false, nil)
        case "read_before":
            let args = decode(BeforeArgs.self, call.arguments)
            let rows = (try? source.before(count: min(max(args?.count ?? 30, 1), 100), skip: max(args?.skip ?? 0, 0))) ?? []
            return (rows.isEmpty ? "前面没有更早的原文了。" : show(rows), false, nil)
        case "search_source":
            guard let args = decode(TermsArgs.self, call.arguments), !args.terms.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ("参数要 {\"terms\": \"要搜的词\"}", true, nil)
            }
            let rows = (try? source.search(args.terms, limit: 20)) ?? []
            return (rows.isEmpty ? "没搜到。" : rows.map { "\($0.marker)\($0.when.map { " \($0)" } ?? "") · \($0.who)：\($0.text)" }.joined(separator: "\n"), false, nil)
        case "search_memory":
            guard let args = decode(TermsArgs.self, call.arguments), !args.terms.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ("参数要 {\"terms\": \"要查的词\"}", true, nil)
            }
            guard !desk.known.isEmpty || !ledger.cards.isEmpty else { return ("档案现在是空的，你这次也还没交过卡。", false, nil) }
            var text: [String: String] = [:]
            var rows: [(id: String, text: String)] = []
            for card in desk.known {
                text[card.id] = "[\(card.id)]\(card.archived ? "（她认可过）" : "")\(card.since.map { " 自 \($0)" } ?? "") \(card.subject.map { $0 + "：" } ?? "")\(card.content)"
                rows.append((card.id, (card.subject ?? "") + " " + card.content))
            }
            for card in ledger.cards {
                text[card.key] = "[\(card.key)]（你这次交的）\(card.subject)：\(card.content)"
                rows.append((card.key, card.subject + " " + card.content))
            }
            let hits = rank(args.terms, in: rows, limit: min(max(args.limit ?? 8, 1), 20))
            return (hits.isEmpty ? "档案里没有字面相近的卡。" : hits.compactMap { text[$0] }.joined(separator: "\n"), false, nil)
        case "list_pages":
            return (desk.pages.isEmpty ? "wiki 现在还没有页。段落的 page 不用填。"
                        : desk.pages.map { "\($0.path)：\($0.hook)" }.joined(separator: "\n"), false, nil)
        case "submit":
            guard let args = decode(SubmitArgs.self, call.arguments) else {
                return ("参数要 {\"cards\":[…],\"notes\":[…]}，这次的 JSON 读不懂", true, nil)
            }
            let removed = ledger.remove(args.remove ?? [])
            var accepted: [String] = []
            var suggestions: [String] = []
            var rejected: [String] = []
            for (offset, matter) in (args.matters ?? []).enumerated() {
                let receipt = ledger.submit(matter: .init(key: matter.key, title: matter.title, page: matter.page, summary: matter.summary,
                                                          facts: (matter.facts ?? []).map(\.input)),
                                            label: "第 \(offset + 1) 件事", span: desk.range, known: desk.known)
                if let key = receipt.accepted.first { accepted.append("\(key)（卡 \(receipt.accepted.dropFirst().joined(separator: "、"))）") }
                suggestions += receipt.suggestions
                rejected += receipt.rejected
            }
            let loose = ledger.submit(cards: (args.cards ?? []).map(\.input), span: desk.range, known: desk.known)
            accepted += loose.accepted
            suggestions += loose.suggestions
            rejected += loose.rejected
            var text = accepted.isEmpty ? "这次没有收下新的" : "收下：" + accepted.joined(separator: "；")
            if !suggestions.isEmpty { text += "\n\(suggestions.joined(separator: "、")) 改的是她认可过的卡，会作为建议交给她" }
            if removed > 0 { text += "\n撤回 \(removed) 条" }
            if !rejected.isEmpty { text += "\n退回 \(rejected.count) 条：\n" + rejected.joined(separator: "\n") }
            return (text + "\n现在一共 \(ledger.notes.count) 件事、\(ledger.cards.count) 张卡。", false, nil)
        case "list_submitted":
            guard !ledger.cards.isEmpty else { return ("你还没交过东西。", false, nil) }
            func show(_ card: WriteLedger.Card) -> String {
                "  [\(card.key)] \(card.type) · \(card.origin)\(card.volatile ? " · volatile" : "")\(card.target.map { " · 改 \($0)" } ?? "") · \(card.subject)：\(card.content)"
            }
            let byKey = Dictionary(ledger.cards.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            var owned = Set<String>()
            var blocks: [String] = []
            for note in ledger.notes {
                owned.formUnion(note.cards)
                blocks.append("[\(note.key)]「\(note.title)」\(note.page.map { " → \($0)" } ?? "")\n  \(note.content)\n" + note.cards.compactMap { byKey[$0] }.map(show).joined(separator: "\n"))
            }
            let loose = ledger.cards.filter { !owned.contains($0.key) }
            if !loose.isEmpty { blocks.append("零散的卡：\n" + loose.map(show).joined(separator: "\n")) }
            return (blocks.joined(separator: "\n\n"), false, nil)
        case "check":
            let found = ledger.problems(windowTitle: desk.windowTitle)
            let lines = found.blocking + found.hints
            return (lines.isEmpty ? "没看出问题：\(ledger.notes.count) 件事、\(ledger.cards.count) 张卡。" : lines.joined(separator: "\n"), false, nil)
        case "finish":
            let found = ledger.problems(windowTitle: desk.windowTitle)
            guard found.blocking.isEmpty else { return ("还不能结束：\n" + found.blocking.joined(separator: "\n"), true, nil) }
            return ("好。", false, decode(FinishArgs.self, call.arguments)?.summary ?? "")
        default:
            return ("没有叫 \(call.name) 的工具", true, nil)
        }
    }

    // MARK: - 循环

    static let elided = "（较早的结果已省略；要看就再调一次。已经 submit 的都还在。）"

    public static func run(source: any WriteSource, caller: any ToolModelCaller, names: MemoryExtractor.Names,
                           ownerWords: String = defaultOwnerWords, limits: OrganizeAgent.Limits = .init(rounds: 40, contextChars: 120_000, resultChars: 24_000),
                           allow: @escaping @Sendable () async -> Bool = { true }) async -> Outcome {
        var outcome = Outcome(ledger: WriteLedger(), stop: .rounds, summary: nil, error: nil, rounds: [])
        let desk: Desk
        do {
            desk = Desk(span: try source.span(), known: try source.known(), pages: try source.pages(), windowTitle: source.windowTitle)
        } catch {
            outcome.stop = .failed
            outcome.error = error.localizedDescription
            return outcome
        }
        guard !desk.span.isEmpty else {
            outcome.stop = .finished
            outcome.summary = "没有新对话"
            return outcome
        }
        let day: (WriteLine?) -> String? = { $0?.when.map { String($0.prefix(10)) } }
        let system = systemPrompt(names: names, windowTitle: desk.windowTitle, from: day(desk.span.first), to: day(desk.span.last), ownerWords: ownerWords)
        var turns: [AgentTurn] = [.user("这段新对话一共 \(desk.span.count) 条；档案里现在有 \(desk.known.count) 张卡。开始吧。")]
        var nudged = false

        for round in 0..<limits.rounds {
            if Task.isCancelled { outcome.stop = .cancelled; break }
            guard await allow() else { outcome.stop = .budget; break }
            let closing = round >= limits.rounds - 3
            let available = closing ? tools.filter { ["submit", "list_submitted", "check", "finish"].contains($0.name) } : tools
            if closing, round == limits.rounds - 3 {
                turns.append(.user("快到轮数上限了：把还没交的 submit 掉，然后 finish。"))
            }
            let clock = ContinuousClock.now
            let step: AgentStep
            do {
                turns = OrganizeAgent.trimmed(turns, limit: limits.contextChars, elided: elided)
                step = try await caller.step(system: system, turns: turns, tools: available)
            } catch is CancellationError {
                outcome.stop = .cancelled
                break
            } catch {
                outcome.stop = .failed
                outcome.error = error.localizedDescription
                break
            }
            let elapsed = ContinuousClock.now - clock
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            outcome.rounds.append(.init(tools: step.calls.map(\.name), usage: step.usage, ms: ms))
            turns.append(step.turn)

            if step.calls.isEmpty, step.truncated {
                turns.removeLast()
                turns.append(.user("上一轮你的输出太长被截断了，什么都没交上。submit 一次最多交 3 件事，分几次交。"))
                continue
            }
            if step.calls.isEmpty {
                if nudged { break }
                nudged = true
                turns.append(.user("请用工具继续：还没读完就 read_span，读完了就 submit，都交了就 list_submitted 通看一遍、check，再 finish。"))
                continue
            }
            nudged = false
            var results: [AgentToolResult] = []
            var finished: String?
            for call in step.calls {
                let done = execute(call, desk: desk, source: source, ledger: &outcome.ledger)
                let content = done.content.count > limits.resultChars
                    ? String(done.content.prefix(limits.resultChars)) + "\n…（太长，截断了；缩小范围再调）" : done.content
                results.append(AgentToolResult(callId: call.id, content: content, isError: done.isError))
                if let summary = done.finished { finished = summary }
            }
            turns.append(.toolResults(results))
            if let finished {
                outcome.stop = .finished
                outcome.summary = finished
                break
            }
        }
        return outcome
    }
}
