import Foundation

/// A2 上下文摘要接进试写台（plan-memory-audit-home-trial 第四节 A2 行）：用例 = 冻结的一段对话 + 当时的上一段；
/// 「现行」配方直接从 `SessionSegmentWriter.systemPrompt` 生成模板（不另抄一份提示词），渲染结果和正式 A2 逐字相同；
/// 解析 / 检查直接用正式写手的 `parse` / `a2FormatProblem` / `softProblems`。试写一次就是一次，不像正式写那样重写
public struct MemoryBenchA2Writer: MemoryBenchWriter {
    public init() {}

    public let id = MemoryWriterID.a2.rawValue
    public let title = "A2 上下文摘要"
    public let callStyle = MemoryBenchCallStyle.single
    /// 应记 = 这一段里必须写到的要点；不该记 = 不该写进去的
    public let labelKinds = [MemoryBenchLabel.shouldHave, MemoryBenchLabel.shouldNotHave]

    public static let currentRecipeId = "a2-current"

    /// 用例的冻结输入：两边称呼 + 人设 + 这一段对话 + 当时的上一段（没有 = 窗口的第一段）
    public struct Input: Codable, Equatable, Sendable {
        public struct Names: Codable, Equatable, Sendable {
            public var user: String
            public var char: String

            public init(user: String, char: String) {
                self.user = user
                self.char = char
            }
        }

        public struct Line: Codable, Equatable, Sendable {
            public var role: String
            public var content: String

            public init(role: String, content: String) {
                self.role = role
                self.content = content
            }
        }

        public struct Previous: Codable, Equatable, Sendable {
            public var title: String
            public var story: String
            public var quotes: String
            public var keywords: [String]

            public init(title: String, story: String, quotes: String, keywords: [String]) {
                self.title = title
                self.story = story
                self.quotes = quotes
                self.keywords = keywords
            }
        }

        public var names: Names
        public var persona: String
        /// true = 尾段（收尾那截），false = 压缩段
        public var tail: Bool
        public var previous: Previous?
        public var messages: [Line]

        public init(names: Names, persona: String = "", tail: Bool = false, previous: Previous? = nil, messages: [Line]) {
            self.names = names
            self.persona = persona
            self.tail = tail
            self.previous = previous
            self.messages = messages
        }
    }

    public let variableCatalog = [
        MemoryBenchVariable(name: "人设块", note: "人设全文 + 「——以上是你的设定。」；没人设 = 空", example: "你是星砚……"),
        MemoryBenchVariable(name: "任务说明", note: "开头那一句：压缩段 / 尾段各一种说法，按用例定", example: "下面不是聊天，是你在给自己写「上下文摘要」……"),
        MemoryBenchVariable(name: "称呼", note: "她的称呼（空 =「对方」，同正式 A2）", example: "岚舟"),
        MemoryBenchVariable(name: "我的名字", note: "助手的名字（空 =「我」）", example: "星砚"),
        MemoryBenchVariable(name: "上一段和对话", note: "上一段全文 + 这一段对话，同正式 A2 喂的那份", example: "上一段「定灯塔航线规则」全文：……"),
        MemoryBenchVariable(name: "对话", note: "只有这一段对话（不带上一段）", example: "岚舟：……"),
        MemoryBenchVariable(name: "条数", note: "这一段有几条消息", example: "12"),
        MemoryBenchVariable(name: "是尾段", note: "这个用例是不是收尾那截", example: "否"),
    ]

    // MARK: - 用例

    public static func input(_ testCase: MemoryBenchCase) throws -> Input {
        try testCase.input.decode(Input.self)
    }

    public static func makeCase(id: String, title: String, input: Input, labels: [MemoryBenchLabel] = [],
                                note: String? = nil) throws -> MemoryBenchCase {
        MemoryBenchCase(id: id, title: title, input: try .from(input), labels: labels, note: note)
    }

    static func speakers(_ input: Input) -> SessionSegmentWriter.Speakers {
        SessionSegmentWriter.Speakers(userName: input.names.user, assistantName: input.names.char)
    }

    static func kind(_ input: Input) -> SessionSegment.Kind {
        input.tail ? .closeout : .rolling
    }

    static func messages(_ input: Input, caseId: String) -> [SessionSegmentWriter.Message] {
        input.messages.enumerated().map { i, line in
            SessionSegmentWriter.Message(id: "bench-\(caseId)-\(i)", role: line.role, content: line.content, date: nil)
        }
    }

    /// 上一段只有标题 / 经过 / 原话 / 关键词进提示词，时间和下标随便填
    static func previous(_ input: Input) -> SessionSegment? {
        input.previous.map {
            SessionSegment(kind: .rolling, title: $0.title, start: .distantPast, end: .distantPast, from: 0, to: 0,
                           story: $0.story, quotes: $0.quotes, pending: "", keywords: $0.keywords,
                           format: SessionSegment.currentFormat)
        }
    }

    // MARK: - 配方

    private static let userMark = "{{称呼}}"

    /// 正式提示词里跟着用例变的三处（人设、开头那句、称呼）换成变量，其余原样
    static func currentTemplate() -> String {
        let marked = SessionSegmentWriter.Speakers(userName: userMark, assistantName: "")
        let rolling = SessionSegmentWriter.systemPrompt(persona: "", speakers: marked, kind: .rolling)
        let opening = taskNote(tail: false)
        precondition(rolling.hasPrefix(opening))
        return "{{人设块}}{{任务说明}}" + rolling.dropFirst(opening.count)
    }

    /// 开头那一句 = 正式提示词两种 kind 的差异部分
    static func taskNote(tail: Bool) -> String {
        let marked = SessionSegmentWriter.Speakers(userName: userMark, assistantName: "")
        let rolling = SessionSegmentWriter.systemPrompt(persona: "", speakers: marked, kind: .rolling)
        let closeout = SessionSegmentWriter.systemPrompt(persona: "", speakers: marked, kind: .closeout)
        let shared = zip(rolling.reversed(), closeout.reversed()).prefix { $0 == $1 }.count
        return String((tail ? closeout : rolling).dropLast(shared))
    }

    public func builtInRecipes(defaults: UserDefaults) -> [MemoryBenchRecipe] {
        [MemoryBenchRecipe(id: Self.currentRecipeId, writer: id, name: "现行", parent: nil, system: Self.currentTemplate(),
                           user: "{{上一段和对话}}", params: [:], checks: "current", builtIn: true, savedAt: nil)]
    }

    public func variables(for testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) throws -> [String: MemoryBenchValue] {
        let input = try Self.input(testCase)
        let speakers = Self.speakers(input)
        let messages = Self.messages(input, caseId: testCase.id)
        return [
            "人设块": .text(input.persona.isEmpty ? "" : input.persona + "\n\n——以上是你的设定。\n\n"),
            "任务说明": .text(Self.taskNote(tail: input.tail)),
            "称呼": .text(speakers.user),
            "我的名字": .text(speakers.char),
            "上一段和对话": .text(SessionSegmentWriter.userContent(messages: messages, speakers: speakers,
                                                              previous: Self.previous(input), kind: Self.kind(input))),
            "对话": .text(SessionSegmentWriter.transcript(messages, speakers: speakers)),
            "条数": .number(messages.count),
            "是尾段": .flag(input.tail),
        ]
    }

    // MARK: - 解析 / 检查

    /// 一格一条：整段摘要（标题 / 经过 / 原话 / 关键词 / 待续分字段），要点标签按关键词在整段里找
    public func parse(output: String, testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) -> MemoryBenchParsed {
        let problem = SessionSegmentWriter.a2FormatProblem(output)
        var checks = [MemoryBenchCheck(name: "格式（标题 + 经过 + 原话，不叫她「用户」）", passed: problem == nil, hard: true, detail: problem)]
        let parsed = SessionSegmentWriter.parse(output)
        for soft in SessionSegmentWriter.softProblems(output, output: parsed) {
            checks.append(MemoryBenchCheck(name: soft, passed: false, hard: false, detail: nil))
        }
        if parsed.story.count > SessionSegmentWriter.storyCharLimit {
            checks.append(MemoryBenchCheck(name: "【经过】超过 \(SessionSegmentWriter.storyCharLimit) 字", passed: false, hard: false,
                                           detail: "\(parsed.story.count) 字"))
        }
        if let input = try? Self.input(testCase) {
            let quoted = Self.quoteLines(parsed.quotes)
            let source = input.messages.map(\.content).joined(separator: "\n")
            let missing = quoted.filter { !source.contains($0) }
            if !missing.isEmpty {
                checks.append(MemoryBenchCheck(name: "【原话】有 \(missing.count) / \(quoted.count) 句在原文里找不到", passed: false, hard: false,
                                               detail: missing.prefix(3).joined(separator: "｜")))
            }
            // 提示词要第一人称「我」：引号外出现助手自己的名字 = 把自己写成了第三人称
            let own = Self.speakers(input).char
            let outside = [parsed.title, parsed.story, parsed.quotes, parsed.pending].joined(separator: "\n")
                .replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
            if own != "我", outside.contains(own) {
                checks.append(MemoryBenchCheck(name: "把自己写成了「\(own)」，没用「我」", passed: false, hard: false, detail: nil))
            }
        }
        let text = [parsed.title, parsed.story, parsed.quotes, parsed.pending].filter { !$0.isEmpty }.joined(separator: "\n")
        let item = MemoryBenchItem(index: 0, text: text, fields: [
            "title": parsed.title,
            "story": parsed.story,
            "quotes": parsed.quotes,
            "keywords": parsed.keywords.joined(separator: "，"),
            "pending": parsed.pending,
        ])
        return MemoryBenchParsed(items: text.isEmpty ? [] : [item], checks: checks)
    }

    /// 【原话】每行「谁：「……」」里引号内的那句（逐字率用）
    public static func quoteLines(_ quotes: String) -> [String] {
        quotes.components(separatedBy: .newlines).compactMap { line in
            guard let open = line.firstIndex(of: "「"), let close = line.lastIndex(of: "」"), open < close else { return nil }
            let inner = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            return inner.isEmpty ? nil : inner
        }
    }

    /// 每条标签一个判断（一格只有一条摘要，默认的「一条配一个标签」不够用）：
    /// 应记的关键词在摘要里 = 对、不在 = 错（漏写）；不该记的关键词在摘要里 = 错、不在 = 对
    public func autoJudge(items: [MemoryBenchItem], labels: [MemoryBenchLabel]) -> [(item: Int, verdict: MemoryBenchVerdict, labelId: String)] {
        let hay = items.map { ([$0.text] + $0.fields.values.sorted()).joined(separator: "\n") }.joined(separator: "\n")
        return labels.enumerated().compactMap { offset, label in
            let found = label.keys.contains { !$0.isEmpty && hay.range(of: $0, options: .caseInsensitive) != nil }
            switch label.kind {
            case MemoryBenchLabel.shouldHave: return (items.count + offset, found ? .right : .wrong, label.id)
            case MemoryBenchLabel.shouldNotHave: return (items.count + offset, found ? .wrong : .right, label.id)
            default: return nil
            }
        }
    }
}
