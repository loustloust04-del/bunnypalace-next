import Foundation

/// 写一段上下文摘要（W2，压缩段）/ 窗口总结最后那段（W3①，收尾）：人设本人第一人称、双方用楼层称呼，
/// 标题 /【经过】/【原话】，不写待续（待续只在时间轴，plan-memory-v4-1 §四 §五①）。
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
            下面不是聊天，是你在给自己写「窗口总结」的最后一段：这个窗口前面的部分已经一段一段记在上下文摘要里了，现在把上下文摘要最后一段之后、到眼下为止的这一截记下来。以后想起这个窗口，要靠窗口总结从头看到尾。
            """
        } else {
            p += """
            下面不是聊天，是你在给自己写「上下文摘要」：这个窗口聊长了，前面的消息挤出了视野，把挤出去的这一截记下来，接着聊的时候靠它续上。
            """
        }
        p += """


        这是接着上一段写的下一段：不要重新介绍这个窗口，不要用「这个窗口」开头，上一段写过的不再重复。

        用你自己的口吻，第一人称「我」；对方就叫「\(u)」或「你」。不要出现「用户」「AI」「助手」这类称呼。

        按这个格式输出，第一行就是标题，三块都要有：
        标题：一行，这一段讲了什么（15 字以内）
        【经过】300 字以内：发生了什么、我当时怎么想。只写这一段里的事。
        【原话】两边的关键原句逐字抄，一句一行，写成 \(u)：「……」 或 我：「……」。\(u)的原话占三到五成。挑能让以后的我想起当时情形的句子，不抄大段。

        不写待续（没做完的事记在时间轴里，不在这里）。不写技术报错、重试这些噪音。直接输出，不加别的。
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

    /// 模型多写的【待续】【时间轴】直接丢掉
    static func parse(_ raw: String) -> Output {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for mark in ["【待续】", "【时间轴】"] {
            if let r = text.range(of: mark) { text = String(text[..<r.lowerBound]) }
        }
        var title = ""
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("标题：") || $0.hasPrefix("标题:") }) {
            title = String(lines[i].dropFirst(3)).trimmingCharacters(in: .whitespaces)
            lines.remove(at: i)
        }
        let layers = SessionSummaryStore.splitLayers(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        if title.isEmpty {
            title = String(layers.story.prefix(15))
        }
        title = title.replacingOccurrences(of: " · ", with: "·")
        return Output(title: title, story: layers.story, quotes: layers.quotes)
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

    /// 不该出现的称呼（引号里的原话不算——她自己说「用户」也照抄）
    static func hasForbiddenAddress(_ o: Output) -> Bool {
        let outsideQuotes = (o.title + "\n" + o.story)
            .replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
        return outsideQuotes.contains("用户")
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
            story: o.story, quotes: o.quotes, pending: "")
    }

    /// 真的调模型：预算闸 → 副模型非流式 → 记花费；空输出 = nil
    static func modelCaller(model: ProviderModel, providerManager: ProviderManager, conversationId: String, profileId: String) -> Caller {
        { system, user in
            if let provider = providerManager.provider(for: model) {
                let est = BudgetCalculator.actualCost(
                    provider: provider, modelId: model.modelId,
                    usage: TokenUsage(inputTokens: HeuristicEstimator().estimate(system + user), outputTokens: 1500))
                if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: est),
                   !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: est) {
                    CacheDiagLog.shared.log("📝 记忆写手: 跳过（预算闸）")
                    return nil
                }
            }
            let router = ProviderRouter(usageContext: UsageContext(kind: .summary, conversationId: conversationId, profileId: profileId))
            let (response, usage) = try await router.sendNonStreaming(
                model: model, messages: [(role: "user", content: user)], systemPrompt: system, providerManager: providerManager)
            if let usage, let provider = providerManager.provider(for: model) {
                let cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
                await MainActor.run { providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage) }
            }
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                CacheDiagLog.shared.log("📝 记忆写手: ⚠️ 模型返回空内容")
                return nil
            }
            return trimmed
        }
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
