import Foundation
import MemoryCore

/// 实验台：从楼层快照里挑一个对话，在电脑上把写入那一侧跑一遍——
/// A2（一段一段的上下文摘要，后一段接着前一段写）→ A3（窗口总结）→ C2（整段写手：每满一截写一次，带前文和这次已经写出来的卡）。
/// 每次调模型吃进去的提示词、材料和它原样回的话都存下来（`<实验 id>-calls/`），页面上能点开看。
/// 用的是包里的正式写手（提示词、格式检查、重写一次的规矩都和 app 相同）；切段在 app 里由上下文挤出触发，
/// 这里按固定条数切。结果只落副本的 `bench-runs/experiments/`，不写 `sessions/` `windows/` 和碎片库
struct MemorydExperiment: Codable, Sendable {
    struct Options: Codable, Equatable, Sendable {
        var conversationId: String
        var userName = ""
        var assistantName = ""
        var persona = ""
        /// A2 每段几条消息
        var segmentSize = 40
        /// C2 老写手每截几条消息（app 默认 20）
        var fragmentEvery = 20
        /// C2 整段写手每满几条写一次（app 默认 200）
        var wholeEvery = FragmentPool.wholeDefaultEvery
        /// whole = 整段写手（app 现在默认的）；classic = 老写手（每截互不相干、不带已记的）
        var writer = "whole"
        /// 整段写手用的提示词（带 {u} {c} {窗口名} {起} {止} 占位）；空 = app 现在那份
        var c2Prompt = ""
        /// 这份提示词叫什么（列表里显示）
        var c2PromptName = ""
        /// 1 = 只写；2 = 写完再核对一次
        var c2Rounds = 1
        /// 从主线第几条开始、最多跑几条（长窗口先跑一截看看）
        var from = 0
        var limit = 400
        var steps = ["a2", "a3", "c2"]

        init(conversationId: String) {
            self.conversationId = conversationId
        }

        /// 请求里只有 conversationId 必填，其余没给用默认
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            conversationId = try c.decode(String.self, forKey: .conversationId)
            userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
            assistantName = try c.decodeIfPresent(String.self, forKey: .assistantName) ?? ""
            persona = try c.decodeIfPresent(String.self, forKey: .persona) ?? ""
            segmentSize = try c.decodeIfPresent(Int.self, forKey: .segmentSize) ?? 40
            fragmentEvery = try c.decodeIfPresent(Int.self, forKey: .fragmentEvery) ?? 20
            wholeEvery = try c.decodeIfPresent(Int.self, forKey: .wholeEvery) ?? FragmentPool.wholeDefaultEvery
            writer = try c.decodeIfPresent(String.self, forKey: .writer) ?? "whole"
            c2Prompt = try c.decodeIfPresent(String.self, forKey: .c2Prompt) ?? ""
            c2PromptName = try c.decodeIfPresent(String.self, forKey: .c2PromptName) ?? ""
            c2Rounds = try c.decodeIfPresent(Int.self, forKey: .c2Rounds) ?? 1
            from = try c.decodeIfPresent(Int.self, forKey: .from) ?? 0
            limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 400
            steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? ["a2", "a3", "c2"]
        }

        static let segmentRange = 6...200
        static let fragmentRange = 6...40
        static let wholeRange = 40...400
        static let maxLimit = 3000
    }

    struct Segment: Codable, Equatable, Sendable {
        var index: Int
        /// 这一段覆盖主线第几条到第几条（从 1 数，含两头）
        var from: Int
        var to: Int
        var title = ""
        var story = ""
        var quotes = ""
        var keywords: [String] = []
        var pending = ""
        /// 软检查没过的几条（不拦，只给人看）
        var problems: [String] = []
        var error: String?
    }

    struct Card: Codable, Equatable, Sendable {
        /// 出自主线第几条（从 1 数）
        var message: Int
        var content: String
        var subject: String?
        var speaker: String?
        var category: String
        var importance: Int
        var tags: [String]
        var confidence: Int?
        var day: String?
        /// 整段写手标的全部出处（主线第几条，从 1 数，从小到大）；和 app 落库进 `Memory.sourceNodeIds` 的是同一串。老写手 / 老结果文件 = nil
        var messages: [Int]?
    }

    struct FragmentBatch: Codable, Equatable, Sendable {
        var from: Int
        var to: Int
        var cards: [Card] = []
        var rejected = 0
        var rejectionReasons: [String] = []
        var error: String?
        /// 整段写手这一批带了几张已记的卡、几条前文；tail = 不够一批、当尾巴写的
        var known: Int?
        var before: Int?
        var tail: Bool?
    }

    /// 一次模型调用的账（吃进去和回出来的全文另存一个文件，按 n 取）
    struct Call: Codable, Equatable, Sendable {
        var n: Int
        /// a2 / a3 / c2
        var step: String
        var label: String
        var systemChars: Int
        var userChars: Int
        var replyChars: Int
        var inputTokens: Int
        var outputTokens: Int
        var seconds: Int
        var error: String?
    }

    var id: String
    var at: Date
    var finishedAt: Date?
    /// running / done / failed
    var status: String
    var options: Options
    var windowTitle: String
    var model: String
    /// 这个对话主线一共几条、这次跑了几条
    var totalMessages: Int
    var ranMessages: Int
    var progress = ""
    var segments: [Segment] = []
    var summary: Segment?
    var fragments: [FragmentBatch] = []
    var calls = 0
    var inputTokens = 0
    var outputTokens = 0
    var note: String?
    /// 每次调模型一行（老实验没有 = nil）
    var callLog: [Call]?
    /// 「写完再对着档案下结论」那种实验的结果（别的实验没有 = nil）
    var verdict: MemorydVerdictReport?
}

/// 一次实验里所有模型调用的记账（并发的 C2 也往这里加）
final class ExperimentMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var input = 0
    private var output = 0

    func add(_ usage: MemoryBenchUsage?) {
        lock.withLock {
            calls += 1
            input += usage?.input ?? 0
            output += usage?.output ?? 0
        }
    }

    var totals: (calls: Int, input: Int, output: Int) { lock.withLock { (calls, input, output) } }
}

/// 把每次调用吃进去的（system、user）和回出来的原文存成 `<dir>/<n>.json`
final class ExperimentCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private let dir: URL
    private var rows: [MemorydExperiment.Call] = []

    init(dir: URL) { self.dir = dir }

    var all: [MemorydExperiment.Call] { lock.withLock { rows } }

    func add(step: String, label: String, system: String, user: String, reply: String?, usage: MemoryBenchUsage?, seconds: Int, error: String?) {
        lock.withLock {
            let n = rows.count + 1
            rows.append(.init(n: n, step: step, label: label, systemChars: system.count, userChars: user.count, replyChars: reply?.count ?? 0,
                              inputTokens: usage?.input ?? 0, outputTokens: usage?.output ?? 0, seconds: seconds, error: error))
            let body: [String: Any] = ["n": n, "step": step, "label": label, "system": system, "user": user,
                                       "reply": reply ?? "", "error": error ?? ""]
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("\(n).json"), options: .atomic)
        }
    }
}

enum MemorydExperimentRunner {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 主线上的消息（和正式写手同一个口径：`visiblePath` + `CatalogOriginalText.body`），正文空的不算
    static func messages(window: ConversationWindow, source: any ConversationSource) throws -> [SessionSegmentWriter.Message] {
        let nodes = try source.nodes(profileId: window.profileId, conversationId: window.id)
        return visiblePath(window: window, nodes: nodes).compactMap { node in
            let body = CatalogOriginalText.body(of: node).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return SessionSegmentWriter.Message(id: node.id, role: node.role, content: body, date: node.createTime)
        }
    }

    /// 这层楼没进回收站的每个对话主线上有正文的消息几条（就是 `messages` 的条数，同一个函数）。
    /// 慢在逐条清洗正文（真快照 3.5 万条一个核要数 7 秒以上）；各窗口互不相干，分到几个核上同时数
    static func messageCounts(source: any ConversationSource, profileId: String) throws -> [String: Int] {
        let windows = try source.windows(profileId: profileId, updatedSince: nil, includeTrashed: false)
        let lock = NSLock()
        var counts: [String: Int] = [:]
        var failure: Error?
        DispatchQueue.concurrentPerform(iterations: windows.count) { index in
            do {
                let count = try messages(window: windows[index], source: source).count
                lock.withLock { counts[windows[index].id] = count }
            } catch {
                lock.withLock { failure = failure ?? error }
            }
        }
        if let failure { throw failure }
        return counts
    }

    static func normalized(_ raw: MemorydExperiment.Options) -> MemorydExperiment.Options {
        var o = raw
        o.segmentSize = min(max(o.segmentSize, MemorydExperiment.Options.segmentRange.lowerBound), MemorydExperiment.Options.segmentRange.upperBound)
        o.fragmentEvery = min(max(o.fragmentEvery, MemorydExperiment.Options.fragmentRange.lowerBound), MemorydExperiment.Options.fragmentRange.upperBound)
        o.wholeEvery = min(max(o.wholeEvery, MemorydExperiment.Options.wholeRange.lowerBound), MemorydExperiment.Options.wholeRange.upperBound)
        if o.writer != "classic" { o.writer = "whole" }
        o.c2Rounds = o.c2Rounds == 2 ? 2 : 1
        // 提示词是空的 = 跑的就是 app 那份，名字不留（列表里按「手机上现在跑的」显示）
        if o.c2Prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { o.c2PromptName = "" }
        o.from = max(o.from, 0)
        o.limit = min(max(o.limit, 1), MemorydExperiment.Options.maxLimit)
        return o
    }

    /// 跑一遍。`onUpdate` 每完成一步回调一次当前结果（服务拿去存盘 / 给页面轮询）
    static func run(_ start: MemorydExperiment, all: [SessionSegmentWriter.Message], model: MemorydModel, floor: URL, callsDir: URL,
                    onUpdate: @escaping @Sendable (MemorydExperiment) async -> Void) async -> MemorydExperiment {
        var result = start
        let options = start.options
        let slice = Array(all.dropFirst(options.from).prefix(options.limit))
        let speakers = SessionSegmentWriter.Speakers(userName: options.userName, assistantName: options.assistantName)
        let meter = ExperimentMeter()
        let calls = ExperimentCallLog(dir: callsDir)
        // 整段写手一次吃十来万字，带思考的模型思考也算输出：上限给大，免得 JSON 被截断
        var roomy = model
        roomy.maxTokens = 64000
        func caller(_ step: String, _ label: String, model: MemorydModel) -> SessionSegmentWriter.Caller {
            { system, user in
                let started = Date()
                do {
                    let reply = try await model.complete(system: system, user: user)
                    meter.add(reply.usage)
                    calls.add(step: step, label: label, system: system, user: user, reply: reply.text, usage: reply.usage,
                              seconds: Int(Date().timeIntervalSince(started)), error: nil)
                    return reply.text
                } catch {
                    calls.add(step: step, label: label, system: system, user: user, reply: nil, usage: nil,
                              seconds: Int(Date().timeIntervalSince(started)), error: error.localizedDescription)
                    throw error
                }
            }
        }
        func publish(_ progress: String) async {
            let totals = meter.totals
            result.progress = progress
            result.calls = totals.calls
            result.inputTokens = totals.input
            result.outputTokens = totals.output
            result.callLog = calls.all
            await onUpdate(result)
        }

        // A2：一段接一段，后一段带着前一段全文
        var written: [SessionSegment] = []
        if options.steps.contains("a2") {
            let chunks = stride(from: 0, to: slice.count, by: options.segmentSize).map {
                Array(slice[$0..<min($0 + options.segmentSize, slice.count)])
            }
            for (index, chunk) in chunks.enumerated() {
                guard !Task.isCancelled else { break }
                let from = options.from + index * options.segmentSize
                var row = MemorydExperiment.Segment(index: index + 1, from: from + 1, to: from + chunk.count)
                await publish("上下文摘要 \(index + 1) / \(chunks.count)")
                do {
                    let request = SessionSegmentWriter.Request(messages: chunk, kind: .rolling, from: from, persona: options.persona,
                                                               speakers: speakers, previous: written.last,
                                                               profileId: "", windowTitle: start.windowTitle, memoryRoot: floor)
                    if let segment = try await SessionSegmentWriter.write(request, fallbackLogRoot: { floor },
                                                                          caller: caller("a2", "上下文摘要 第 \(index + 1) 段", model: model)) {
                        written.append(segment)
                        row.title = segment.title
                        row.story = segment.story
                        row.quotes = segment.quotes
                        row.keywords = segment.keywords
                        row.pending = segment.pending
                        row.problems = problems(segment, chunk: chunk, speakers: speakers)
                    } else {
                        row.error = "模型没回内容"
                    }
                } catch {
                    row.error = error.localizedDescription
                }
                result.segments.append(row)
            }
        }

        // A3：拿上面写出来的段写窗口总结；没跑 A2 就直接喂原文
        if options.steps.contains("a3"), !Task.isCancelled, let first = slice.first, let last = slice.last {
            await publish("窗口总结")
            var row = MemorydExperiment.Segment(index: 0, from: options.from + 1, to: options.from + slice.count)
            do {
                let tail = written.isEmpty ? slice : []
                if let summary = try await WindowSummaryWriter.write(
                    title: start.windowTitle, segments: written, rawTail: tail, persona: options.persona, speakers: speakers,
                    start: first.date ?? Date(), end: last.date ?? Date(), to: slice.count, lastNodeId: last.id,
                    profileId: "", memoryRoot: floor, fallbackLogRoot: { floor }, caller: caller("a3", "窗口总结", model: model)) {
                    row.title = summary.title
                    row.story = summary.story
                    row.quotes = summary.quotes
                    row.keywords = summary.keywords
                    let output = SessionSegmentWriter.Output(title: summary.title, story: summary.story, quotes: summary.quotes,
                                                             keywords: summary.keywords)
                    row.problems = WindowSummaryWriter.softProblems(output, segmentCount: written.count, speakers: speakers)
                } else {
                    row.error = "模型没回内容"
                }
            } catch {
                row.error = error.localizedDescription
            }
            result.summary = row
        }

        // C2 整段写手（app 现在默认的）：一批接一批，每批带前文和已记的卡。实验台里档案从空开始，已记的 = 这次前面几批写出来的
        if options.steps.contains("c2"), options.writer == "whole", !Task.isCancelled {
            let names = MemoryExtractor.Names(userName: options.userName, assistantName: options.assistantName)
            let sizes = slice.map(\.content.count)
            var known: [FragmentPool.KnownCard] = []
            var at = 0
            while at < slice.count, !Task.isCancelled {
                guard let end = FragmentPool.wholeSpanEnd(sizes: sizes, from: at, every: options.wholeEvery, tail: true) else {
                    result.note = "最后 \(slice.count - at) 条不够 \(FragmentPool.wholeTailMinimum) 条，没写（手机上也一样）"
                    break
                }
                let chunk = Array(slice[at..<end])
                let base = options.from + at
                let before = FragmentPool.wholeBefore(all, upTo: base, size: { $0.content.count })
                var batch = MemorydExperiment.FragmentBatch(from: base + 1, to: base + chunk.count)
                batch.known = min(known.count, FragmentPool.wholeKnownCards)
                batch.before = before.count
                batch.tail = chunk.count < options.wholeEvery
                await publish("碎片 第 \(base + 1)–\(base + chunk.count) 条")
                func message(_ m: SessionSegmentWriter.Message) -> FragmentPool.Message {
                    FragmentPool.Message(id: m.id, role: m.role, content: m.content, date: m.date)
                }
                let context = FragmentPool.WholeContext(windowTitle: start.windowTitle, before: before.map(message),
                                                        known: Array(known.prefix(FragmentPool.wholeKnownCards)))
                let span = chunk.map(message)
                let days = FragmentPool.wholeDays(span)
                let custom = options.c2Prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                let system = custom.isEmpty ? nil : Self.filled(custom, names: names, window: start.windowTitle, from: days.from, to: days.to)
                do {
                    if let out = try await FragmentPool.runWhole(span, context: context, names: names,
                                                                 system: system, verify: options.c2Rounds == 2,
                                                                 caller: caller("c2", "碎片 第 \(base + 1)–\(base + chunk.count) 条", model: roomy)) {
                        batch.rejected = out.rejected
                        batch.rejectionReasons = out.rejectionReasons
                        batch.cards = out.fragments.map {
                            MemorydExperiment.Card(message: base + $0.msg, content: $0.content, subject: $0.subject, speaker: $0.speaker,
                                                   category: $0.category, importance: $0.importance, tags: $0.tags,
                                                   confidence: $0.confidence, day: $0.occurredDay, messages: $0.msgs.map { $0.map { base + $0 } })
                        }
                        // 手机上已记的卡新的在前
                        known.insert(contentsOf: out.fragments.reversed().map { FragmentPool.KnownCard(subject: $0.subject, content: $0.content) }, at: 0)
                    } else {
                        batch.error = "模型没回内容"
                    }
                } catch {
                    batch.error = error.localizedDescription
                }
                result.fragments.append(batch)
                at = end
            }
        }

        // C2 老写手：每满一截抽一次，一截一截互不相干，最多同时 3 个
        if options.steps.contains("c2"), options.writer == "classic", !Task.isCancelled {
            let names = MemoryExtractor.Names(userName: options.userName, assistantName: options.assistantName)
            let starts = Array(stride(from: 0, to: slice.count, by: options.fragmentEvery))
            await publish("碎片 0 / \(starts.count)")
            var batches: [MemorydExperiment.FragmentBatch] = []
            await withTaskGroup(of: MemorydExperiment.FragmentBatch.self) { group in
                var next = 0
                func addNext() {
                    guard next < starts.count else { return }
                    let offset = starts[next]
                    next += 1
                    let chunk = Array(slice[offset..<min(offset + options.fragmentEvery, slice.count)])
                    let base = options.from + offset
                    group.addTask {
                        var batch = MemorydExperiment.FragmentBatch(from: base + 1, to: base + chunk.count)
                        let messages = chunk.map { FragmentPool.Message(id: $0.id, role: $0.role, content: $0.content, date: $0.date) }
                        do {
                            if let out = try await FragmentPool.run(messages, names: names, defaults: MemoryReadEnvironment.defaults,
                                                                    caller: caller("c2", "碎片（老写手）第 \(base + 1)–\(base + chunk.count) 条", model: model)) {
                                batch.rejected = out.rejected
                                batch.rejectionReasons = out.rejectionReasons
                                batch.cards = out.fragments.map {
                                    MemorydExperiment.Card(message: base + $0.msg, content: $0.content, subject: $0.subject, speaker: $0.speaker,
                                                           category: $0.category, importance: $0.importance, tags: $0.tags)
                                }
                            } else {
                                batch.error = "模型没回内容"
                            }
                        } catch {
                            batch.error = error.localizedDescription
                        }
                        return batch
                    }
                }
                for _ in 0..<min(3, starts.count) { addNext() }
                while let batch = await group.next() {
                    batches.append(batch)
                    result.fragments = batches.sorted { $0.from < $1.from }
                    await publish("碎片 \(batches.count) / \(starts.count)")
                    if !Task.isCancelled { addNext() }
                }
            }
        }

        result.status = Task.isCancelled ? "failed" : "done"
        if Task.isCancelled { result.note = "中途停下" }
        result.finishedAt = Date()
        await publish("")
        return result
    }

    /// 提示词模板里的占位换成这一批的名字、窗口名、日期
    static func filled(_ template: String, names: MemoryExtractor.Names, window: String, from: String?, to: String?) -> String {
        template.replacingOccurrences(of: "{u}", with: names.user).replacingOccurrences(of: "{c}", with: names.char)
            .replacingOccurrences(of: "{窗口名}", with: window)
            .replacingOccurrences(of: "{起}", with: from ?? "").replacingOccurrences(of: "{止}", with: to ?? "")
    }

    /// app 现在那份提示词，名字和日期换成占位（页面上给她看、给她改）
    static func appPromptTemplate() -> String {
        FragmentPool.wholeSystem(names: MemoryExtractor.Names(userName: "{u}", assistantName: "{c}"), windowTitle: "{窗口名}", from: "{起}", to: "{止}")
    }

    /// A2 一段的软检查：正式写手的那几条 + 【原话】在原文里找不到 + 把自己写成第三人称
    static func problems(_ segment: SessionSegment, chunk: [SessionSegmentWriter.Message],
                         speakers: SessionSegmentWriter.Speakers) -> [String] {
        let output = SessionSegmentWriter.Output(title: segment.title, story: segment.story, quotes: segment.quotes,
                                                 pending: segment.pending, keywords: segment.keywords)
        // 关键词那两条要原始输出才判得了（这里只有存下来的段），略过
        var out = SessionSegmentWriter.softProblems("【关键词】", output: output)
        if segment.story.count > SessionSegmentWriter.storyCharLimit { out.append("【经过】\(segment.story.count) 字，超过 \(SessionSegmentWriter.storyCharLimit)") }
        let quoted = MemoryBenchA2Writer.quoteLines(segment.quotes)
        let source = chunk.map(\.content).joined(separator: "\n")
        let missing = quoted.filter { !source.contains($0) }
        if !missing.isEmpty { out.append("【原话】有 \(missing.count) / \(quoted.count) 句在原文里找不到") }
        let outside = [segment.title, segment.story, segment.quotes, segment.pending].joined(separator: "\n")
            .replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
        if speakers.char != "我", outside.contains(speakers.char) { out.append("把自己写成了「\(speakers.char)」，没用「我」") }
        return out
    }
}
