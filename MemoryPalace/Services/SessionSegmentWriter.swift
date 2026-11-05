import Foundation

/// 写一段上下文摘要（W2，压缩段）/ 窗口总结最后那段（W3①，收尾）：人设本人第一人称、双方用楼层称呼，
/// 标题 /【经过】/【原话】/【待续】（c2c3-v2 第 7 段起 A2 恢复写待续，A4 拼日时由代码搬进待续本子）。
/// 动笔前先读上一段全文，接着写，不重新介绍窗口。格式不对带提醒重写一次，还不对就不存（抛 `MemoryWriterError.format`）
enum SessionSegmentWriter {

    struct Message: Equatable {
        let id: String
        let role: String
        let content: String
        let date: Date?
    }

    struct Speakers: Equatable {
        let user: String
        let char: String

        init(userName: String, assistantName: String) {
            let u = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
            user = u.isEmpty ? "对方" : u
            char = c.isEmpty ? "我" : c
        }
    }

    struct Output: Equatable {
        var title: String
        var story: String
        var quotes: String
        /// 【待续】一条一行；「无」/ 没写 = 空
        var pending = ""
    }

    /// 调一次模型：(system, user) → 原文；nil = 预算闸 / 空输出（不算失败）
    typealias Caller = (_ system: String, _ user: String) async throws -> String?

    /// 单条消息喂给模型的上限（cc-bridge 一条能上万字）
    static let messageCharLimit = 1500

    // MARK: - 提示词

    static func systemPrompt(persona: String, speakers: Speakers, kind: SessionSegment.Kind) -> String {
        let u = speakers.user
        var p = ""
        if !persona.isEmpty {
            p += persona + "\n\n——以上是你的设定。\n\n"
        }
        if kind == .closeout {
            p += """
            下面不是聊天，是你在给自己写「上下文摘要」最后那截（尾段）：这个窗口前面的部分已经一段一段记在上下文摘要里了，现在把最后一段之后、到眼下为止的这一截记下来。这截以后接着聊还会整段重写。
            """
        } else {
            p += """
            下面不是聊天，是你在给自己写「上下文摘要」：这个窗口聊长了，前面的消息挤出了视野，把挤出去的这一截记下来，接着聊的时候靠它续上。
            """
        }
        p += """


        这是接着上一段写的下一段：不要重新介绍这个窗口，不要用「这个窗口」开头，上一段写过的不再重复。

        用你自己的口吻，第一人称「我」；对方就叫「\(u)」或「你」。不要出现「用户」「AI」「助手」这类称呼。

        按这个格式输出，第一行就是标题，四块都要有：
        标题：一行，这一段讲了什么（15 字以内）
        【经过】300 字以内：只写发生了什么——谁做了什么、说了什么、定了什么；不写我当时怎么想、什么感受。只写这一段里的事。
        【原话】两边的关键原句逐字抄，一句一行，写成 \(u)：「……」 或 我：「……」。\(u)的原话占三到五成。挑能让以后的我想起当时情形的句子，不抄大段。
        【待续】这一段里做到一半的事、答应了的事、还没哄完的情绪，一条一行；真的没有就写「无」。

        不写技术报错、重试这些噪音。直接输出，不加别的。
        """
        return p
    }

    static func userContent(messages: [Message], speakers: Speakers, previous: SessionSegment?, kind: SessionSegment.Kind) -> String {
        var out = ""
        if let previous, previous.kind == .legacy {
            out += "之前的摘要（改造前写的）：\n\(previous.story)\n\n"
        } else if let previous {
            out += kind == .closeout ? "上下文摘要最后一段" : "上一段"
            out += "「\(previous.title)」全文：\n【经过】\(previous.story)"
            if !previous.quotes.isEmpty { out += "\n【原话】\(previous.quotes)" }
            out += "\n\n"
        } else {
            out += "（这是这个窗口记下的第一段。）\n\n"
        }
        out += "这一段对话：\n\n" + transcript(messages, speakers: speakers)
        return out
    }

    /// 说话人用楼层称呼，不标「用户 / AI」——那两个词漏进旧摘要的根子
    static func transcript(_ messages: [Message], speakers: Speakers) -> String {
        messages.map { m in
            let who = m.role == "user" ? speakers.user : speakers.char
            let text = m.content.count > messageCharLimit ? String(m.content.prefix(messageCharLimit)) + "…（后面略）" : m.content
            return "\(who)：\(text)"
        }.joined(separator: "\n\n")
    }

    // MARK: - 解析 / 格式检查

    /// 【待续】单独收（「无」= 空），模型多写的【时间轴】直接丢掉
    static func parse(_ raw: String) -> Output {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = text.range(of: "【时间轴】") { text = String(text[..<r.lowerBound]) }
        var pending = ""
        if let r = text.range(of: "【待续】") {
            pending = TimelineStore.pendingItems(String(text[r.upperBound...])).joined(separator: "\n")
            text = String(text[..<r.lowerBound])
        }
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
            title = String(firstLine.prefix(15))
        }
        title = title.replacingOccurrences(of: " · ", with: "·")
        return Output(title: title, story: layers.story, quotes: layers.quotes, pending: pending)
    }

    /// 格式检查（纯函数）：nil = 合格；否则是带进重写提醒里的那句话
    static func formatProblem(_ raw: String) -> String? {
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

    /// 不该出现的称呼：把她叫成「用户」（引号里的原话不算——她自己说「用户」也照抄）
    static func hasForbiddenAddress(_ o: Output) -> Bool {
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
    static func addressesAsUser(_ text: String) -> Bool {
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

    struct Request {
        let messages: [Message]
        /// .rolling = 上下文摘要（W2）；.closeout = 窗口总结最后那段（W3①）
        let kind: SessionSegment.Kind
        let from: Int
        let persona: String
        let speakers: Speakers
        let previous: SessionSegment?
    }

    /// 写一段：格式不对带提醒重写一次，还不对抛 `.format`（不存、不推水位线）。nil = 预算闸 / 空输出
    static func write(_ req: Request, caller: Caller) async throws -> SessionSegment? {
        guard let first = req.messages.first, let last = req.messages.last else { return nil }
        let system = systemPrompt(persona: req.persona, speakers: req.speakers, kind: req.kind)
        let user = userContent(messages: req.messages, speakers: req.speakers, previous: req.previous, kind: req.kind)
        let label = req.kind == .closeout ? "窗口总结" : "上下文摘要"
        guard var raw = try await caller(system, user) else { return nil }
        if let problem = formatProblem(raw) {
            CacheDiagLog.shared.log("📝 \(label): 格式不对（\(problem)），重写一次")
            guard let retry = try await caller(system, user + "\n\n（提醒：上一次写的不合格——\(problem)。照格式重写：第一行「标题：」，然后【经过】【原话】，对方叫「\(req.speakers.user)」或「你」。）") else { return nil }
            if let again = formatProblem(retry) {
                CacheDiagLog.shared.log("📝 \(label): ❌ 重写后格式还是不对（\(again)），不存")
                throw MemoryWriterError.format(again)
            }
            raw = retry
        }
        let o = parse(raw)
        return SessionSegment(
            kind: req.kind, title: o.title,
            start: first.date ?? Date(), end: last.date ?? Date(),
            from: req.from, to: req.from + req.messages.count, lastNodeId: last.id,
            story: o.story, quotes: o.quotes, pending: o.pending, format: SessionSegment.currentFormat)
    }

    /// 每次调模型前后都复查开关（astra #1）：关着 = nil（跳过，不算失败）。等模型时她关了开关，回来的结果也不落盘——
    /// 调用方拿到结果到落盘之间不隔 await，后查这一下就是落盘前那一查
    static func gated(_ isOn: @escaping () -> Bool, _ caller: @escaping Caller) -> Caller {
        { system, user in
            guard isOn() else {
                CacheDiagLog.shared.log("📝 记忆写手: 跳过（开关关了）")
                return nil
            }
            let raw = try await caller(system, user)
            guard isOn() else {
                CacheDiagLog.shared.log("📝 记忆写手: 开关关了，这次写的不存")
                return nil
            }
            return raw
        }
    }

    /// 真的调模型：写入预算（后台写手才查；手动「现在写」不查，v5 Q10）→ 全局预算闸 → 副模型非流式 → 记花费；空输出 = nil。
    /// kind = 账本里算谁的（A2 .summary / A3 .windowSummary / A4 .timeline / C2 .memory，v5 · A11）
    /// preflight = 调用方自己的那一查（C3 在主线程读卡片和全局闸），给了就不走 budgetBlock
    /// onUsage = 这次调用用了多少 token、花了多少钱（试写台要显示；没报用量就是 nil, nil）
    static func modelCaller(model: ProviderModel, providerManager: ProviderManager, conversationId: String, profileId: String,
                            kind: UsageKind = .summary, checkWriteBudget: Bool = true,
                            preflight: ((String) async -> String?)? = nil,
                            onUsage: ((TokenUsage?, Double?) -> Void)? = nil) -> Caller {
        { system, user in
            let blocked: String?
            if let preflight {
                blocked = await preflight(system + user)
            } else {
                blocked = budgetBlock(model: model, providerManager: providerManager, text: system + user, checkWriteBudget: checkWriteBudget)
            }
            if let why = blocked {
                CacheDiagLog.shared.log("📝 记忆写手: 跳过（\(why)）")
                return nil
            }
            let router = ProviderRouter(usageContext: UsageContext(kind: kind, conversationId: conversationId, profileId: profileId))
            let (response, usage) = try await router.sendNonStreaming(
                model: model, messages: [(role: "user", content: user)], systemPrompt: system, providerManager: providerManager)
            var spent: Double?
            if let usage, let provider = providerManager.provider(for: model) {
                let cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
                spent = cost
                MemoryWriteLog.addCost(cost)
                await MainActor.run { providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage) }
            }
            onUsage?(usage, spent)
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                CacheDiagLog.shared.log("📝 记忆写手: ⚠️ 模型返回空内容")
                return nil
            }
            return trimmed
        }
    }

    /// 后台写手发请求前那一查（modelCaller 和 C3 手动 agent 每一轮共用）：写入预算 → 全局预算闸（按这次要送的字估）。
    /// 拦下 = 原因；model = nil（本机）只查写入预算。读账本，后台调
    static func budgetBlock(model: ProviderModel?, providerManager: ProviderManager, text: String, checkWriteBudget: Bool = true) -> String? {
        if checkWriteBudget, WriteBudgetStore.exceeded() { return "写入预算用完" }
        guard let model, let provider = providerManager.provider(for: model) else { return nil }
        let est = BudgetCalculator.actualCost(
            provider: provider, modelId: model.modelId,
            usage: TokenUsage(inputTokens: HeuristicEstimator().estimate(text), outputTokens: 1500))
        if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: est),
           !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: est) {
            return "预算闸"
        }
        return nil
    }
}

/// 记忆写手的格式错（两次都不合格）：不存、不推水位线、记健康状态
enum MemoryWriterError: LocalizedError, Equatable {
    case format(String)

    var errorDescription: String? {
        switch self {
        case .format(let problem): return "写出来的格式不对：\(problem)"
        }
    }
}
