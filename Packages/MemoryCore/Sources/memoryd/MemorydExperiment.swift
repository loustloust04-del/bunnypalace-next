import Foundation
import MemoryCore

/// 实验台：从楼层快照里挑一个对话，在电脑上把写入那一侧跑一遍——
/// A2（一段一段的上下文摘要，后一段接着前一段写）→ A3（窗口总结）→ C2（每满一截抽碎片）。
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
        /// C2 每截几条消息（app 默认 20）
        var fragmentEvery = 20
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
            from = try c.decodeIfPresent(Int.self, forKey: .from) ?? 0
            limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 400
            steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? ["a2", "a3", "c2"]
        }

        static let segmentRange = 6...200
        static let fragmentRange = 6...40
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
    }

    struct FragmentBatch: Codable, Equatable, Sendable {
        var from: Int
        var to: Int
        var cards: [Card] = []
        var rejected = 0
        var rejectionReasons: [String] = []
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
}

/// 一次实验里所有模型调用的记账（并发的 C2 也往这里加）
private final class ExperimentMeter: @unchecked Sendable {
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

    static func normalized(_ raw: MemorydExperiment.Options) -> MemorydExperiment.Options {
        var o = raw
        o.segmentSize = min(max(o.segmentSize, MemorydExperiment.Options.segmentRange.lowerBound), MemorydExperiment.Options.segmentRange.upperBound)
        o.fragmentEvery = min(max(o.fragmentEvery, MemorydExperiment.Options.fragmentRange.lowerBound), MemorydExperiment.Options.fragmentRange.upperBound)
        o.from = max(o.from, 0)
        o.limit = min(max(o.limit, 1), MemorydExperiment.Options.maxLimit)
        return o
    }

    /// 跑一遍。`onUpdate` 每完成一步回调一次当前结果（服务拿去存盘 / 给页面轮询）
    static func run(_ start: MemorydExperiment, all: [SessionSegmentWriter.Message], model: MemorydModel, floor: URL,
                    onUpdate: @escaping @Sendable (MemorydExperiment) async -> Void) async -> MemorydExperiment {
        var result = start
        let options = start.options
        let slice = Array(all.dropFirst(options.from).prefix(options.limit))
        let speakers = SessionSegmentWriter.Speakers(userName: options.userName, assistantName: options.assistantName)
        let meter = ExperimentMeter()
        let caller: SessionSegmentWriter.Caller = { system, user in
            let reply = try await model.complete(system: system, user: user)
            meter.add(reply.usage)
            return reply.text
        }
        func publish(_ progress: String) async {
            let totals = meter.totals
            result.progress = progress
            result.calls = totals.calls
            result.inputTokens = totals.input
            result.outputTokens = totals.output
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
                    if let segment = try await SessionSegmentWriter.write(request, fallbackLogRoot: { floor }, caller: caller) {
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
                    profileId: "", memoryRoot: floor, fallbackLogRoot: { floor }, caller: caller) {
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

        // C2：每满一截抽一次，一截一截互不相干，最多同时 3 个
        if options.steps.contains("c2"), !Task.isCancelled {
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
                            if let out = try await FragmentPool.run(messages, names: names, defaults: MemoryReadEnvironment.defaults, caller: caller) {
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
