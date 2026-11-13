import Foundation

/// 整理 agent（plan-organize-agent §3）：通看全部卡 → 按需回原文 → 自己拿主意 → 核对 → 交。
/// 循环和六个工具都在包里，电脑（memoryd）和手机（app）跑同一份；模型和数据从外面给。
/// 只读数据、只写结论本，不碰库、不碰文件
public enum OrganizeAgent {
    public struct Limits: Sendable, Equatable {
        /// 最多几轮（一轮 = 调一次模型）
        public var rounds: Int
        /// 对话里留着的工具结果总字数；超了就把早的结果换成一行提示，一次裁到一半（结论在结论本里，不丢）。
        /// 一次裁到一半而不是每轮裁一点：前面的内容稳定不变，接口的缓存才命中得上
        public var contextChars: Int
        /// 一次工具结果最多多少字
        public var resultChars: Int

        public init(rounds: Int = 60, contextChars: Int = 60_000, resultChars: Int = 12_000) {
            self.rounds = rounds
            self.contextChars = contextChars
            self.resultChars = resultChars
        }
    }

    /// 外壳的两处做法，留成开关好做对照（plan-organize-agent §1.1 之后）
    public struct Options: Sendable, Equatable {
        /// 列卡时把字面相近的排在一起，并给它 `similar_cards` 工具
        public var neighbors: Bool
        /// 允许 `keep`（原样留一张、不用写内容）。关掉 = 每条进档案的都得自己写出整句
        public var allowKeep: Bool
        /// 给它一张「分堆的桌子」：先把全部卡按「说的是同一个人 / 同一样东西 / 同一件事」分成堆，再一堆一堆处理。
        /// 自由 agent 都是先分堆再动手的（它们靠写脚本）；没有这张桌子时它一页一页边看边交，只会就近小并
        public var piles: Bool

        public init(neighbors: Bool = true, allowKeep: Bool = false, piles: Bool = true) {
            self.neighbors = neighbors
            self.allowKeep = allowKeep
            self.piles = piles
        }
    }

    public struct Round: Sendable, Equatable, Codable {
        public var tools: [String]
        public var usage: AgentUsage?
        public var ms: Int
    }

    public enum Stop: String, Sendable, Codable {
        /// 它自己 finish 了
        case finished
        /// 到轮数上限
        case rounds
        /// 调用方的预算闸说停
        case budget
        case cancelled
        /// 模型接口出错
        case failed
    }

    public struct Outcome: Sendable, Equatable, Codable {
        public var ledger: OrganizeLedger
        public var stop: Stop
        public var summary: String?
        public var error: String?
        public var rounds: [Round]

        public var inputTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.input ?? 0) } }
        public var outputTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.output ?? 0) } }
        public var cacheReadTokens: Int { rounds.reduce(0) { $0 + ($1.usage?.cacheRead ?? 0) } }
    }

    // MARK: - 给它的话（只有三样：档案干什么用、主人的原话、工具怎么用；不列「不记 X」清单）

    public static let defaultOwnerWords = """
    - 「我想要的是精准的增加，不是加屎不是记录流程。精准的事实。」
    - 「原话是事实，A 是纪录片，B 是日记，C 是活档案。」（这份是 C）
    - 「该记的，记了然后呢！切这么碎！」
    - 「拿不准的才让我手动。」
    """

    public static func systemPrompt(names: MemoryExtractor.Names, ownerWords: String = defaultOwnerWords,
                                    options: Options = Options()) -> String {
        let actions = options.allowKeep
            ? "keep（原样留一张）/ merge（几张是同一件事，并成一条，content 写并好的整句）/ rewrite（一张，事是真的但要重写，content 写改好的整句）/ drop（不进档案）/ unsure（你拿不准，交给她）。\n          keep / merge / rewrite 带上 confidence"
            : "merge（几张是同一件事，并成一条）/ rewrite（只有一张）/ drop（不进档案）/ unsure（你拿不准，交给她）。\n          merge / rewrite 都要在 content 里用你自己的话写出整理后的整句，并带上 confidence"
        let listing = options.neighbors
            ? "- list_cards：分页看卡，字面相近的已经排在一起。先把全部卡看完再动手。\n        - similar_cards：看和某张卡字面相近的还有哪些（排在一起的不一定是同一件事，隔得远的也可能是，自己判断）。"
            : "- list_cards：分页看卡。先把全部卡看完再动手。"
        let piling = options.piles
            ? "\n        - sort_cards：把卡分到你起了名字的堆里（说的是同一个人、同一样东西、同一件事的放一堆；一堆可以很大）。先把全部卡看完、全部分好堆，再开始 record。\n        - list_piles：看现在有哪些堆、每堆几张、还有几张没结论。list_cards 带上 pile 就只看那一堆。\n          分好之后一堆一堆处理：一堆通常并成一条，把这个人 / 这样东西 / 这件事的要点写全；确实是互不相干的两件事才分成两条。"
            : ""
        return """
        你在整理一份长期记忆档案。档案的主人是\(names.user)；\(names.char)是陪她聊天的那一位。

        档案里的卡是另一个模型每隔一段对话自动抽出来的，她还没看过。请你把它们整理成一份好用的档案：过一个月，\(names.char)翻到其中一条，不看原来的对话，就知道一件关于她（或她在意的人和东西）的确定的事，并且用得上。

        主人对这份档案说过的话（原话，别的标准没有，其余由你判断）：
        \(ownerWords)

        原文是事实，卡要向原文对齐。卡可能抽错（把意思记反、把别人的事记成她的、把随口一说当成定论），拿不准就用 read_source / search_source 回去看。

        你有这些工具：
        \(listing)\(piling)
        - read_source：看一张卡出处那条消息和前后几条原文。
        - search_source：按词搜原文，跨窗口核对。
        - record：交一批结论。每条结论说清它处理了哪几张卡（cards），action：
          \(actions)（0–1）：你对「这件事是真的、而且以后还成立」的把握，按实际给，不要都给高分。why 写一句理由。
          可以分很多次交；同一张卡再交一次会顶掉之前的。
        - check：让程序核对有没有卡漏了、有没有对不上的。
        - finish：全部卡都有结论、check 过了，再调它结束。

        已经在档案里的卡（列表里标着「已在档案」）她认可过，你可以拿来对照；觉得该改就照常 record，那会作为建议交给她，不会直接生效。
        """
    }

    // MARK: - 工具

    static func tools(_ options: Options) -> [AgentToolSpec] {
        var out = baseTools
        if options.neighbors {
            out.insert(AgentToolSpec(name: "similar_cards", description: "看和某张卡字面相近的卡（只是字面上像，是不是同一件事自己判断）。",
                                     schema: #"{"type":"object","properties":{"card":{"type":"string","description":"卡的编号"},"limit":{"type":"integer","description":"最多几张，默认 10"}},"required":["card"]}"#), at: 1)
        }
        if options.piles {
            out.insert(AgentToolSpec(name: "sort_cards", description: "把卡分到起了名字的堆里。同一张卡再分一次会换堆。",
                                     schema: #"{"type":"object","properties":{"piles":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string","description":"这一堆的名字"},"cards":{"type":"array","items":{"type":"string"}}},"required":["name","cards"]}}},"required":["piles"]}"#), at: 1)
            out.insert(AgentToolSpec(name: "list_piles", description: "看现在有哪些堆：名字、几张、其中几张还没结论。",
                                     schema: #"{"type":"object","properties":{}}"#), at: 2)
            out = out.map { spec in
                spec.name == "list_cards"
                    ? AgentToolSpec(name: spec.name, description: spec.description + "带 pile 只看那一堆（「未分堆」看还没分的）。",
                                    schema: spec.schema.replacingOccurrences(of: #""properties":{"offset""#, with: #""properties":{"pile":{"type":"string","description":"只看这一堆"},"offset""#))
                    : spec
            }
        }
        if !options.allowKeep {
            out = out.map { spec in
                spec.name == "record"
                    ? AgentToolSpec(name: spec.name, description: spec.description, schema: spec.schema.replacingOccurrences(of: #""keep","merge""#, with: #""merge""#))
                    : spec
            }
        }
        return out
    }

    static let tools = tools(Options(neighbors: false, allowKeep: true, piles: false))

    private static let baseTools: [AgentToolSpec] = [
        AgentToolSpec(name: "list_cards", description: "分页列出卡。每张：编号、日期、正文；已在档案里的会标出来。",
                      schema: #"{"type":"object","properties":{"offset":{"type":"integer","description":"从第几张开始，默认 0"},"limit":{"type":"integer","description":"最多几张，默认 100"}}}"#),
        AgentToolSpec(name: "read_source", description: "看一张卡出处那条消息和前后几条原文。",
                      schema: #"{"type":"object","properties":{"card":{"type":"string","description":"卡的编号"},"before":{"type":"integer","description":"往前几条，默认 3，最多 10"},"after":{"type":"integer","description":"往后几条，默认 3，最多 10"}},"required":["card"]}"#),
        AgentToolSpec(name: "search_source", description: "按词搜原文（所有窗口）。",
                      schema: #"{"type":"object","properties":{"terms":{"type":"string","description":"要搜的词"}},"required":["terms"]}"#),
        AgentToolSpec(name: "record", description: "交一批结论。同一张卡再交一次会顶掉之前的。",
                      schema: #"{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"action":{"type":"string","enum":["keep","merge","rewrite","drop","unsure"]},"cards":{"type":"array","items":{"type":"string"},"description":"这条结论处理了哪几张卡的编号"},"content":{"type":"string","description":"merge / rewrite 必填：整理后的整句"},"confidence":{"type":"number","description":"0 到 1"},"why":{"type":"string"}},"required":["action","cards"]}}},"required":["items"]}"#),
        AgentToolSpec(name: "check", description: "让程序核对：有没有卡还没结论、有没有对不上的。",
                      schema: #"{"type":"object","properties":{}}"#),
        AgentToolSpec(name: "finish", description: "全部卡都有结论并且 check 过了，调它结束。",
                      schema: #"{"type":"object","properties":{"summary":{"type":"string","description":"一句话：这次整理了什么"}}}"#),
    ]

    private struct ListArgs: Decodable { var offset: Int?; var limit: Int?; var pile: String? }
    private struct SortArgs: Decodable {
        struct Pile: Decodable { var name: String; var cards: [Flexible] }
        var piles: [Pile]
    }

    /// 分堆的桌子：哪张卡在哪一堆。只是它干活时的草稿，不进结论
    public struct Desk: Sendable, Equatable {
        public var pileOf: [String: String] = [:]
        public init() {}
    }

    static let unsortedName = "未分堆"
    private struct ReadArgs: Decodable { var card: Flexible; var before: Int?; var after: Int? }
    private struct SearchArgs: Decodable { var terms: String }
    private struct SimilarArgs: Decodable { var card: Flexible; var limit: Int? }
    private struct FinishArgs: Decodable { var summary: String? }
    private struct RecordArgs: Decodable {
        struct Item: Decodable {
            var action: String
            var cards: [Flexible]
            var content: String?
            var confidence: Double?
            var why: String?
        }
        var items: [Item]
    }

    /// 编号模型有时给数字有时给字符串
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

    private static func lines(_ rows: [OrganizeSourceLine]) -> String {
        rows.map { row in
            "\(row.isOrigin ? "→ " : "  ")\(row.marker)\(row.when.map { " \($0)" } ?? "") · \(row.who)：\(row.text)"
        }.joined(separator: "\n")
    }

    /// 跑一个工具。返回给模型看的文字；finished = 它成功 finish 了
    static func execute(_ call: AgentToolCall, cards: [OrganizeCard], source: any OrganizeSource,
                        ledger: inout OrganizeLedger, neighbors: OrganizeNeighbors? = nil,
                        options: Options = Options(neighbors: false, allowKeep: true, piles: false)) -> (content: String, isError: Bool, finished: String?) {
        var desk = Desk()
        return execute(call, cards: cards, source: source, ledger: &ledger, desk: &desk, neighbors: neighbors, options: options)
    }

    static func execute(_ call: AgentToolCall, cards: [OrganizeCard], source: any OrganizeSource,
                        ledger: inout OrganizeLedger, desk: inout Desk, neighbors: OrganizeNeighbors?,
                        options: Options) -> (content: String, isError: Bool, finished: String?) {
        func undecided() -> Int {
            let done = ledger.decided
            return cards.filter { $0.zone == .draft && !done.contains($0.id) }.count
        }
        switch call.name {
        case "list_cards":
            let args = decode(ListArgs.self, call.arguments)
            let offset = max(args?.offset ?? 0, 0)
            let limit = min(max(args?.limit ?? 100, 1), 200)
            var pool = cards
            var scope = ""
            if options.piles, let pile = args?.pile?.trimmingCharacters(in: .whitespaces), !pile.isEmpty {
                pool = cards.filter { pile == unsortedName ? desk.pileOf[$0.id] == nil : desk.pileOf[$0.id] == pile }
                scope = "「\(pile)」这一堆"
                guard !pool.isEmpty else { return ("没有叫「\(pile)」的堆（或者它是空的）。用 list_piles 看有哪些堆。", true, nil) }
            }
            let page = pool.dropFirst(offset).prefix(limit)
            guard !page.isEmpty else { return ("没有更多卡了（\(scope)一共 \(pool.count) 张）。", false, nil) }
            let done = ledger.decided
            let body = page.map { card in
                "[\(card.id)]\(card.day.map { " \($0)" } ?? "")\(card.zone == .draft ? "" : "（已在档案）")\(options.piles && done.contains(card.id) ? "（已有结论）" : "") \(card.content)"
            }.joined(separator: "\n")
            let shown = offset + page.count
            return (body + "\n\n\(scope)第 \(offset + 1)–\(shown) 张，共 \(pool.count) 张\(shown < pool.count ? "，下一页 offset=\(shown)" : "，已经到底")；全部卡里还有 \(undecided()) 张没结论。", false, nil)
        case "sort_cards" where options.piles:
            guard let args = decode(SortArgs.self, call.arguments) else {
                return ("参数要 {\"piles\":[{\"name\":\"…\",\"cards\":[…]}]}，这次的 JSON 读不懂", true, nil)
            }
            let known = Set(cards.map(\.id))
            var placed = 0
            var unknown: [String] = []
            for pile in args.piles {
                let name = pile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != unsortedName else { continue }
                for id in pile.cards.map(\.value) {
                    if known.contains(id) { desk.pileOf[id] = name; placed += 1 } else { unknown.append(id) }
                }
            }
            let unsorted = cards.filter { $0.zone == .draft && desk.pileOf[$0.id] == nil }.count
            var text = "分了 \(placed) 张；现在一共 \(Set(desk.pileOf.values).count) 堆，还有 \(unsorted) 张没分堆。"
            if !unknown.isEmpty { text += "\n没有这些编号的卡：\(unknown.prefix(20).joined(separator: "、"))" }
            return (text, false, nil)
        case "list_piles" where options.piles:
            let done = ledger.decided
            var counts: [String: (total: Int, open: Int)] = [:]
            var order: [String] = []
            for card in cards {
                let name = desk.pileOf[card.id] ?? unsortedName
                if counts[name] == nil { order.append(name) }
                counts[name, default: (0, 0)].total += 1
                if card.zone == .draft, !done.contains(card.id) { counts[name, default: (0, 0)].open += 1 }
            }
            return (order.map { "「\($0)」\(counts[$0]?.total ?? 0) 张，\(counts[$0]?.open ?? 0) 张没结论" }.joined(separator: "\n"), false, nil)
        case "similar_cards":
            guard let neighbors else { return ("没有叫 similar_cards 的工具", true, nil) }
            guard let args = decode(SimilarArgs.self, call.arguments) else { return ("参数要 {\"card\": \"编号\"}", true, nil) }
            guard cards.contains(where: { $0.id == args.card.value }) else { return ("没有编号为 \(args.card.value) 的卡", true, nil) }
            let byId = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let done = ledger.decided
            let rows = neighbors.similar(to: args.card.value, limit: min(max(args.limit ?? 10, 1), 30)).compactMap { hit -> String? in
                guard let card = byId[hit.id] else { return nil }
                return "[\(card.id)]\(done.contains(card.id) ? "（已有结论）" : "") \(card.content)"
            }
            return (rows.isEmpty ? "没有字面相近的卡。" : rows.joined(separator: "\n"), false, nil)
        case "read_source":
            guard let args = decode(ReadArgs.self, call.arguments) else { return ("参数要 {\"card\": \"编号\"}", true, nil) }
            guard cards.contains(where: { $0.id == args.card.value }) else { return ("没有编号为 \(args.card.value) 的卡", true, nil) }
            let rows = (try? source.source(of: args.card.value, before: min(max(args.before ?? 3, 0), 10), after: min(max(args.after ?? 3, 0), 10))) ?? []
            return (rows.isEmpty ? "这张卡找不到出处原文。" : lines(rows), false, nil)
        case "search_source":
            guard let args = decode(SearchArgs.self, call.arguments), !args.terms.trimmingCharacters(in: .whitespaces).isEmpty else {
                return ("参数要 {\"terms\": \"要搜的词\"}", true, nil)
            }
            let rows = (try? source.search(args.terms, limit: 20)) ?? []
            return (rows.isEmpty ? "没搜到。" : lines(rows), false, nil)
        case "record":
            guard let args = decode(RecordArgs.self, call.arguments) else {
                return ("参数要 {\"items\":[{\"action\":…,\"cards\":[…],…}]}，这次的 JSON 读不懂", true, nil)
            }
            var refused: [String] = []
            var items: [OrganizeLedger.Item] = []
            for (offset, item) in args.items.enumerated() {
                if item.action == "keep", !options.allowKeep {
                    refused.append("第 \(offset + 1) 条：没有 keep；只有一张卡就用 rewrite，在 content 里用你自己的话写出这条事实")
                } else {
                    items.append(OrganizeLedger.Item(action: item.action, cards: item.cards.map(\.value), content: item.content,
                                                     confidence: item.confidence, why: item.why))
                }
            }
            var receipt = ledger.record(items, cards: cards)
            receipt.rejected = refused + receipt.rejected
            var text = "收下 \(receipt.accepted) 条"
            if !receipt.rejected.isEmpty { text += "；退回 \(receipt.rejected.count) 条：\n" + receipt.rejected.joined(separator: "\n") }
            return (text + "\n还有 \(undecided()) 张没结论。", false, nil)
        case "check":
            let problems = ledger.problems(cards: cards)
            return (problems.isEmpty ? "都对上了：每张卡都有结论。" : problems.joined(separator: "\n"), false, nil)
        case "finish":
            let problems = ledger.problems(cards: cards)
            guard problems.isEmpty else { return ("还不能结束：\n" + problems.joined(separator: "\n"), true, nil) }
            return ("好。", false, decode(FinishArgs.self, call.arguments)?.summary ?? "")
        default:
            return ("没有叫 \(call.name) 的工具", true, nil)
        }
    }

    // MARK: - 循环

    static let elided = "（较早的结果已省略；要看就再调一次。已经 record 的结论都还在。）"

    /// 留着的工具结果总字数超了上限，就把早的换成一行提示，一直裁到上限的一半（最近 4 段不动）；没超不动
    static func trimmed(_ turns: [AgentTurn], limit: Int, elided: String = elided) -> [AgentTurn] {
        func size(_ turn: AgentTurn) -> Int {
            if case .toolResults(let results) = turn { return results.reduce(0) { $0 + $1.content.count } }
            return 0
        }
        var total = turns.reduce(0) { $0 + size($1) }
        guard total > limit else { return turns }
        var out = turns
        for index in out.indices.dropLast(4) {
            guard total > limit / 2, case .toolResults(let results) = out[index] else { continue }
            guard !results.allSatisfy({ $0.content == elided }) else { continue }
            total -= size(out[index])
            out[index] = .toolResults(results.map {
                AgentToolResult(callId: $0.callId, content: elided, isError: $0.isError)
            })
            total += results.count * elided.count
        }
        return out
    }

    /// 跑一次整理。`allow` 是调用方的预算闸：每轮发请求前问一次，false 就停
    public static func run(source: any OrganizeSource, caller: any ToolModelCaller, names: MemoryExtractor.Names,
                           ownerWords: String = defaultOwnerWords, limits: Limits = Limits(), options: Options = Options(),
                           resume: OrganizeLedger = OrganizeLedger(),
                           allow: @escaping @Sendable () async -> Bool = { true },
                           onProgress: (@Sendable (OrganizeLedger, Int) async -> Void)? = nil) async -> Outcome {
        var outcome = Outcome(ledger: resume, stop: .rounds, summary: nil, error: nil, rounds: [])
        var cards: [OrganizeCard]
        do { cards = try source.cards() } catch {
            outcome.stop = .failed
            outcome.error = error.localizedDescription
            return outcome
        }
        var neighbors: OrganizeNeighbors?
        if options.neighbors {
            let built = OrganizeNeighbors(cards: cards)
            let byId = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            cards = built.ordered().compactMap { byId[$0] }
            neighbors = built
        }
        let toolset = tools(options)
        guard cards.contains(where: { $0.zone == .draft }) else {
            outcome.stop = .finished
            outcome.summary = "没有新卡"
            return outcome
        }
        let system = systemPrompt(names: names, ownerWords: ownerWords, options: options)
        let already = outcome.ledger.decided.count
        var desk = Desk()
        var turns: [AgentTurn] = [.user("一共 \(cards.count) 张卡\(already > 0 ? "，其中 \(already) 张上次已经有结论（再 record 会顶掉）" : "")。开始吧。")]
        var nudged = false

        for round in 0..<limits.rounds {
            if Task.isCancelled { outcome.stop = .cancelled; break }
            guard await allow() else { outcome.stop = .budget; break }
            // 最后几轮只让它交和结束
            let closing = round >= limits.rounds - 3
            let available = closing ? toolset.filter { ["record", "check", "finish"].contains($0.name) } : toolset
            if closing, round == limits.rounds - 3 {
                turns.append(.user("快到轮数上限了：把还没结论的卡 record 掉（拿不准的用 unsure），然后 finish。"))
            }
            let clock = ContinuousClock.now
            let step: AgentStep
            do {
                turns = trimmed(turns, limit: limits.contextChars)
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
            outcome.rounds.append(Round(tools: step.calls.map(\.name), usage: step.usage, ms: ms))
            turns.append(step.turn)

            if step.calls.isEmpty, step.truncated {
                // 一口气写太多被截断，什么都没交上：让它分批，不算它偷懒
                turns.removeLast()
                turns.append(.user("上一轮你的输出太长被截断了，什么都没交上。record 一次最多交 15 条结论，分几次交。"))
                continue
            }
            if step.calls.isEmpty {
                // 光说话没调工具：提醒一次，再这样就当它不干了
                if nudged { break }
                nudged = true
                turns.append(.user("请用工具继续：还没看完就 list_cards，看完了就 record，都有结论了就 check 再 finish。"))
                continue
            }
            nudged = false
            var results: [AgentToolResult] = []
            var finished: String?
            for call in step.calls {
                let done = execute(call, cards: cards, source: source, ledger: &outcome.ledger, desk: &desk, neighbors: neighbors, options: options)
                let content = done.content.count > limits.resultChars
                    ? String(done.content.prefix(limits.resultChars)) + "\n…（太长，截断了；缩小范围再调）" : done.content
                results.append(AgentToolResult(callId: call.id, content: content, isError: done.isError))
                if let summary = done.finished { finished = summary }
            }
            turns.append(.toolResults(results))
            await onProgress?(outcome.ledger, round + 1)
            if let finished {
                outcome.stop = .finished
                outcome.summary = finished
                break
            }
        }
        if outcome.stop != .finished {
            outcome.ledger.closeUndecided(cards: cards, why: "整理没跑完（\(outcome.stop.rawValue)），这张没来得及看")
        }
        return outcome
    }
}
