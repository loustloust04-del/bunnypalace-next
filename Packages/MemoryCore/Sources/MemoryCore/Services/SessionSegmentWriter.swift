import Foundation

/// 写一段上下文摘要（W2，压缩段）/ 窗口总结最后那段（W3①，收尾）：人设本人第一人称、双方用楼层称呼，
/// 标题 /【经过】/【原话】/【关键词】/【待续】；待续由独立本子承接。
/// 动笔前先读上一段全文，接着写，不重新介绍窗口。格式不对带提醒重写一次，还不对就不存（抛 `MemoryWriterError.format`）
public enum SessionSegmentWriter {

    public struct Message: Equatable {
        public let id: String
        public let role: String
        public let content: String
        public let date: Date?

        public init(id: String, role: String, content: String, date: Date?) {
            self.id = id
            self.role = role
            self.content = content
            self.date = date
        }
    }

    public struct Speakers: Equatable {
        public let user: String
        public let char: String

        public init(userName: String, assistantName: String) {
            let u = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
            user = u.isEmpty ? "对方" : u
            char = c.isEmpty ? "我" : c
        }
    }

    public struct Output: Equatable {
        public var title: String
        public var story: String
        public var quotes: String
        /// 【待续】一条一行；「无」/ 没写 = 空
        public var pending = ""
        public var keywords: [String] = []

        public init(title: String, story: String, quotes: String, pending: String = "", keywords: [String] = []) {
            self.title = title
            self.story = story
            self.quotes = quotes
            self.pending = pending
            self.keywords = keywords
        }
    }

    /// 调一次模型：(system, user) → 原文；nil = 预算闸 / 空输出（不算失败）。
    /// 真模型在 app 侧 `AppModelCaller`（`ModelCaller` 协议）里，这里只留窄闭包口子
    public typealias Caller = (_ system: String, _ user: String) async throws -> String?

    /// A线提示词（完整版）§A2：标题 ≤15、关键词 ≤5、连接词每300字≤1；原文沿用1500字上限。
    public static let titleCharLimit = 15
    public static let keywordLimit = 5
    public static let connectorCharUnit = 300
    public static let storyCharLimit = 300
    public static let messageCharLimit = 1500

    // MARK: - 提示词

    public static func systemPrompt(persona: String, speakers: Speakers, kind: SessionSegment.Kind) -> String {
        let u = speakers.user
        var p = ""
        if !persona.isEmpty {
            p += persona + "\n\n——以上是你的设定。\n\n"
        }
        if kind == .closeout {
            p += """
            下面不是聊天，是你在给自己写「上下文摘要」最后那截（尾段）：前面的部分已经一段一段记下了，现在把最后一段之后、到眼下为止的这一截记下来。这截以后接着聊还会整段重写。
            """
        } else {
            p += """
            下面不是聊天，是你在给自己写「上下文摘要」：这个窗口聊长了，前面的消息挤出了视野，把挤出去的这一截记下来，接着聊的时候靠它续上。
            """
        }
        p += """


        这是接着上一段写的下一段：不要重新介绍这个窗口，不要用「这个窗口」开头，上一段写过的不再重复。

        用第一人称「我」；对方叫「\(u)」或「你」。不出现「用户」「AI」「助手」。只写发生了什么，不写感受和评价。不写技术报错和重试；做到一半的事只写进【待续】。

        按这个格式输出，第一行就是标题，五块都要有：

        标题：≤\(titleCharLimit) 字。它会被用在时间轴、窗口总结和搜索里，所以要能搜到东西。
        - 不用「我 / 你 / 我们」当主语；需要主语就用最短的称呼，能省就省
        - 不写虚词（了 / 的 / 在 / 把 / 给）和空话（继续 / 深入 / 一些 / 相关 / 关于）
        - 动词或名词开头
        - 按顺序想：有结论 → 动词 + 结论（定 X / 改 X 为 Y）；没结论但有事 → 动词 + 关键名词；只有话题 → 话题 + 卡在哪；纯闲聊 → 最具体的那个名词
        - 亲密 / 角色扮演段：写场景或角色 + 动作，不写身体部位
        - 纯情绪段：写触发它的东西，不写情绪本身
        - 和上一段同一个话题：写这一段新多出来的
          ✗ 我和\(u)讨论了审计台的方案 → ✓ 定审计台方案
          ✗ 继续聊记忆系统 → ✓ A2标题改无主语
          ✗ 解决了一个bug → ✓ 修摘要重复写入bug
          ✗ 进行了角色扮演 → ✓ 雨夜旅馆角色扮演·告别戏
          ✗ 很难过 → ✓ 翻旧照片深夜低潮
          ✗ 闲聊了一会儿 → ✓ 吐槽外卖太咸

        【经过】≤\(storyCharLimit) 字，能短则短。归组不归轮：在「话题变了」或「在做的事变了」的地方切，不在「换人说话」的地方切；几条消息在做同一件事就合成一句。有结论写「做了 X，定了 Y」，没结论写「聊 X，没定」。过程本身就是内容的时候（怎么设的套、戏怎么展开），写成一串动作，不逐句复述。不用「然后 / 之后 / 接着 / 后来 / 最后」串。
          ✗ \(u)说试一下，我说收到。\(u)又说试一下，我又说收到。\(u)第三次说试一下，这次通了。
          ✓ \(u)试了三次连接，第三次通了。
          ✗ \(u)问为什么卡。我说可能是List。\(u)说试了还卡。我说换LazyVStack。\(u)说好了。
          ✓ \(u)问列表卡顿，查出是List，改LazyVStack解决。

        【原话】两边的关键原句逐字抄，一句一行，写成 \(u)：「……」 或 我：「……」。\(u)的原话占三到五成。挑能让以后的我想起当时情形的句子，不抄大段。

        【关键词】≤\(keywordLimit) 个，逗号隔开，给搜索用。写这一段里的专有名词、角色名、术语、具体的物件；不写「讨论 / 方案 / 问题 / 话题」这类通用词。

        【待续】这一段里做到一半的事、答应了的事、还没哄完的情绪，一条一行；真的没有就写「无」。

        直接输出，不加别的。
        """
        return p
    }

    public static func userContent(messages: [Message], speakers: Speakers, previous: SessionSegment?, kind: SessionSegment.Kind) -> String {
        var out = ""
        if let previous, previous.kind == .legacy || previous.format < 2 {
            out += "之前的摘要（改造前写的）：\n\(SessionSummaryStore.segmentText(previous))\n\n"
        } else if let previous {
            out += "上一段"
            out += "「\(previous.title)」全文：\n【经过】\(previous.story)"
            if !previous.quotes.isEmpty { out += "\n【原话】\(previous.quotes)" }
            if !previous.keywords.isEmpty { out += "\n【关键词】" + previous.keywords.joined(separator: "，") }
            out += "\n\n"
        } else {
            out += "（这是这个窗口记下的第一段。）\n\n"
        }
        out += "这一段对话：\n\n" + transcript(messages, speakers: speakers)
        return out
    }

    /// 说话人用楼层称呼，不标「用户 / AI」——那两个词漏进旧摘要的根子
    public static func transcript(_ messages: [Message], speakers: Speakers) -> String {
        messages.map { m in
            let who = m.role == "user" ? speakers.user : speakers.char
            let text = m.content.count > messageCharLimit ? String(m.content.prefix(messageCharLimit)) + "…（后面略）" : m.content
            return "\(who)：\(text)"
        }.joined(separator: "\n\n")
    }

    // MARK: - 解析 / 格式检查

    /// 【待续】单独收（「无」= 空），模型多写的【时间轴】直接丢掉
    public static func parse(_ raw: String) -> Output {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = text.range(of: "【时间轴】") { text = String(text[..<r.lowerBound]) }
        var title = ""
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("标题：") || $0.hasPrefix("标题:") }) {
            title = String(lines[i].dropFirst(3)).trimmingCharacters(in: .whitespaces)
            lines.remove(at: i)
        }
        let layers = SessionSummaryStore.splitLayers(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        if title.isEmpty {
            // 10-16：兜底只取经过的第一行（以前整截 prefix(15)，换行带进标题，文件里标题行断开 → 严格读判坏）
            let firstLine = layers.story.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            title = String(firstLine.prefix(titleCharLimit))
        }
        title = title.replacingOccurrences(of: " · ", with: "·")
        return Output(title: title, story: layers.story, quotes: layers.quotes,
                      pending: TimelineStore.pendingItems(layers.pending).joined(separator: "\n"), keywords: layers.keywords)
    }

    /// 格式检查（纯函数）：nil = 合格；否则是带进重写提醒里的那句话
    public static func formatProblem(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let storyMark = text.range(of: "【经过】") else { return "缺了【经过】" }
        guard text.range(of: "【原话】") != nil else { return "缺了【原话】" }
        let head = text[..<storyMark.lowerBound].components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let titles = head.filter { $0.hasPrefix("标题：") || $0.hasPrefix("标题:") }
        if titles.isEmpty { return "第一行要是「标题：」" }
        if head.count > titles.count { return "【经过】前面除了「标题：」那一行，不能有别的字" }
        if hasForbiddenAddress(parse(text)) { return "不要用「用户」称呼对方" }
        return nil
    }

    /// A2 硬检查：格式与「用户」称呼；模型称呼只记软日志。
    public static func a2FormatProblem(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("标题：") || text.hasPrefix("标题:") else { return "第一行要是「标题：」" }
        if let problem = formatProblem(text) { return problem }
        if addressesAsUser(parse(text).pending) { return "不要用「用户」称呼对方" }
        return nil
    }

    public static let modelAddress = try! NSRegularExpression(
        pattern: "(?<![A-Za-z的个位些名类新老他各每有多分批真普])(AI|助手)"
            + "(?![A-Za-z]|模型|工具|功能|接口|系统|技术|开发|应用|说明(?![天早晚日])|问题|需求|体验|名|画像|数据|界面|协议|反馈|信息|头像|列表|量|群|端|侧|们)"
            + "(?:[：:]|(?:今天|昨天|刚才|刚刚|早上|晚上|最近|突然|一直|总是|已经|曾经|又|也|还|就|再|先|很|不|没有|没)*"
            + "(?:说|问|要|让|请|表示|希望|觉得|认为|告诉|叫|喊|撒娇|想|追问|回复|回答|提到|喜欢|讨厌|答应|决定|同意|拒绝))"
            + "|(?:提醒|告诉|给|陪|跟|和)(AI|助手)(?![A-Za-z]|模型|工具|功能|接口|系统|技术|开发|应用|说明(?![天早晚日])|问题|需求|体验|名|画像|数据|界面|协议|反馈|信息|头像|列表|量|群|端|侧|们)")

    public static func softProblems(_ raw: String, output: Output) -> [String] {
        var problems: [String] = []
        if output.title.count > titleCharLimit { problems.append("标题超过\(titleCharLimit)字") }
        if ["我", "你", "我们"].contains(where: output.title.hasPrefix) { problems.append("标题以代词开头") }
        if !raw.contains("【关键词】") { problems.append("没有【关键词】") }
        if output.keywords.count > keywordLimit { problems.append("关键词超过\(keywordLimit)个，截到\(keywordLimit)个") }
        let outside = (output.title + "\n" + output.story + "\n" + output.quotes + "\n" + output.pending)
            .replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
        if let match = modelAddress.firstMatch(in: outside, range: NSRange(outside.startIndex..., in: outside)),
           let range = Range(match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1), in: outside) {
            problems.append("不要用「\(outside[range])」称呼对方")
        }
        let connectors = ["然后", "之后", "接着", "后来", "最后"].reduce(0) { count, word in
            count + output.story.components(separatedBy: word).count - 1
        }
        if connectors * connectorCharUnit > max(output.story.count, connectorCharUnit) {
            problems.append("【经过】连接词每\(connectorCharUnit)字超过1次")
        }
        return problems
    }

    /// 不该出现的称呼：把她叫成「用户」（引号里的原话不算——她自己说「用户」也照抄）
    public static func hasForbiddenAddress(_ o: Output) -> Bool {
        addressesAsUser(o.title + "\n" + o.story + "\n" + o.quotes)
    }

    /// 「用户」后面接这些是名词组合（用户说明 / 用户问题 / 用户名…），不是拿它称呼人（10-16 astra #5）；「说明天」是「说 + 明天」不算
    private static let userNounTail = "(?!说明(?![天早晚日])|问题|想法|请求|需求|体验|名|画像|数据|界面|协议|反馈|信息|头像|列表|量|群|端|侧|们)"

    /// 「用户」当主语称呼对方：后面直接接动词，或隔几个时间词 / 副词再接（用户今天说… / 用户又想…，10-16 astra #4）
    private static let userAsSubject = try! NSRegularExpression(
        pattern: "(?<![的个位些名类新老他各每有多分批真普])用户" + userNounTail
            + "(?:今天|昨天|前天|刚才|刚刚|早上|晚上|后来|最近|突然|一直|总是|已经|曾经|又|也|还|就|再|先|很|特别|非常|不|没有|没)*"
            + "(?:说|问|要|让|请|表示|希望|觉得|认为|告诉|叫|喊|撒娇|想要|追问|回复|回答|提到|喜欢|讨厌|想|答应|决定|同意|拒绝)")

    /// 「用户」当宾语称呼对方：提醒用户 / 告诉用户 / 给用户 / 陪用户 / 跟用户 / 和用户（10-16 astra #4）
    private static let userAsObject = try! NSRegularExpression(pattern: "(?:提醒|告诉|给|陪|跟|和)用户" + userNounTail)

    /// 纯函数（10-16 放窄）：只拦把「用户」当成称呼她本人的写法——说话人写成「用户：」，「用户说 / 问 / 要…」当主语，
    /// 「提醒用户 / 陪用户…」当宾语。「别的用户」「用户画像」「用户说明」这类普通名词放行（整天聊 app 的窗口以前一律被拦，A2 / A4 都误伤）。
    /// 引号里的原话不算：先把完整的「…」（可以跨行）整段剥掉再查，引文里的「用户：」也不当说话人
    public static func addressesAsUser(_ text: String) -> Bool {
        let outside = text.replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
        for line in outside.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^(【[^】]*】|- )+", with: "", options: .regularExpression)
            if t.hasPrefix("用户：") || t.hasPrefix("用户:") { return true }
        }
        let range = NSRange(outside.startIndex..., in: outside)
        return userAsSubject.firstMatch(in: outside, range: range) != nil || userAsObject.firstMatch(in: outside, range: range) != nil
    }

    // MARK: - 执行

    public struct Request {
        public let messages: [Message]
        /// .rolling = 上下文摘要（W2）；.closeout = 窗口总结最后那段（W3①）
        public let kind: SessionSegment.Kind
        public let from: Int
        public let persona: String
        public let speakers: Speakers
        public let previous: SessionSegment?
        public var profileId = ""
        public var windowTitle = ""
        public var memoryRoot: URL? = nil

        public init(messages: [Message], kind: SessionSegment.Kind, from: Int, persona: String, speakers: Speakers,
                    previous: SessionSegment?, profileId: String = "", windowTitle: String = "", memoryRoot: URL? = nil) {
            self.messages = messages
            self.kind = kind
            self.from = from
            self.persona = persona
            self.speakers = speakers
            self.previous = previous
            self.profileId = profileId
            self.windowTitle = windowTitle
            self.memoryRoot = memoryRoot
        }
    }

    /// 写一段：格式不对带提醒重写一次，还不对抛 `.format`（不存、不推水位线）。nil = 预算闸 / 空输出
    public static func write(_ req: Request, fallbackLogRoot: @escaping () -> URL, caller: Caller) async throws -> SessionSegment? {
        guard let first = req.messages.first, let last = req.messages.last else { return nil }
        let system = systemPrompt(persona: req.persona, speakers: req.speakers, kind: req.kind)
        let user = userContent(messages: req.messages, speakers: req.speakers, previous: req.previous, kind: req.kind)
        let label = req.kind == .closeout ? "窗口总结" : "上下文摘要"
        guard var raw = try await caller(system, user) else { return nil }
        if let problem = a2FormatProblem(raw) {
            MemoryLogging.shared.log("📝 \(label): 格式不对（\(problem)），重写一次")
            guard let retry = try await caller(system, user + "\n\n（提醒：上一次写的不合格——\(problem)。照格式重写：第一行「标题：」，然后【经过】【原话】，对方叫「\(req.speakers.user)」或「你」。）") else { return nil }
            if let again = a2FormatProblem(retry) {
                MemoryLogging.shared.log("📝 \(label): ❌ 重写后格式还是不对（\(again)），不存")
                throw MemoryWriterError.format(again)
            }
            raw = retry
        }
        var o = parse(raw)
        for problem in softProblems(raw, output: o) {
            MemoryWriteLog.record(writer: .a2, profileId: req.profileId, ok: true,
                                  note: "A2 软检查 · 窗口「\(SessionSummaryStore.oneLine(req.windowTitle))」· 段「\(SessionSummaryStore.oneLine(o.title))」· \(problem)", model: "", cost: 0, memoryRoot: req.memoryRoot ?? fallbackLogRoot())
        }
        if o.keywords.count > keywordLimit { o.keywords.removeLast(o.keywords.count - keywordLimit) }
        return SessionSegment(
            kind: req.kind, title: o.title,
            start: first.date ?? Date(), end: last.date ?? Date(),
            from: req.from, to: req.from + req.messages.count, lastNodeId: last.id,
            story: o.story, quotes: o.quotes, pending: o.pending, keywords: o.keywords, format: SessionSegment.currentFormat)
    }

    /// 直接拿 `ModelCaller` 写（memoryd / 新适配器用）：转成窄闭包口子
    public static func write(_ req: Request, fallbackLogRoot: @escaping () -> URL, caller: any ModelCaller) async throws -> SessionSegment? {
        try await write(req, fallbackLogRoot: fallbackLogRoot, caller: { system, user in
            try await caller.complete(ModelRequest(system: system, user: user)).text
        })
    }

    /// 每次调模型前后都复查开关（astra #1）：关着 = nil（跳过，不算失败）。等模型时她关了开关，回来的结果也不落盘——
    /// 调用方拿到结果到落盘之间不隔 await，后查这一下就是落盘前那一查
    public static func gated(_ isOn: @escaping () -> Bool, _ caller: @escaping Caller) -> Caller {
        { system, user in
            guard isOn() else {
                MemoryLogging.shared.log("📝 记忆写手: 跳过（开关关了）")
                return nil
            }
            let raw = try await caller(system, user)
            guard isOn() else {
                MemoryLogging.shared.log("📝 记忆写手: 开关关了，这次写的不存")
                return nil
            }
            return raw
        }
    }

}

/// 记忆写手的格式错（两次都不合格）：不存、不推水位线、记健康状态
public enum MemoryWriterError: LocalizedError, Equatable {
    case format(String)

    public var errorDescription: String? {
        switch self {
        case .format(let problem): return "写出来的格式不对：\(problem)"
        }
    }
}
