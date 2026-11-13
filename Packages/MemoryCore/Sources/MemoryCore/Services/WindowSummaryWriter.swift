import Foundation

/// A3 每次从全部 A2 和未覆盖原文重压；旧 A3 不参与输入。
public enum WindowSummaryWriter {
    // A线提示词（完整版）§A3：按 A2 段数分档，8 段以上只喂标题、原话和关键词。
    public static let shortSegmentLimit = 4
    public static let fullInputSegmentLimit = 8
    public static let mediumSegmentLimit = 20
    public static let titleCharLimit = 20
    public static let keywordLimit = 10
    public static let shortStoryLimit = 300
    public static let mediumStoryLimit = 500
    public static let longStoryLimit = 800
    public static let longestStoryLimit = 1200
    public static let shortQuoteCount = 1
    public static let longQuoteCounts = 2...3

    public static func storyRange(segmentCount: Int) -> ClosedRange<Int> {
        switch segmentCount {
        case ...shortSegmentLimit: return 0...shortStoryLimit
        case ...fullInputSegmentLimit: return 0...mediumStoryLimit
        case ...mediumSegmentLimit: return mediumStoryLimit...longStoryLimit
        default: return longStoryLimit...longestStoryLimit
        }
    }

    public static func systemPrompt(persona: String, speakers: SessionSegmentWriter.Speakers, segmentCount: Int) -> String {
        let u = speakers.user
        let range = storyRange(segmentCount: segmentCount)
        let length = range.lowerBound == 0 ? "≤\(range.upperBound) 字" : "\(range.lowerBound)–\(range.upperBound) 字"
        let quotes = segmentCount <= shortSegmentLimit ? "\(shortQuoteCount) 句" : "\(longQuoteCounts.lowerBound)–\(longQuoteCounts.upperBound) 句"
        var p = persona.isEmpty ? "" : persona + "\n\n——以上是你的设定。\n\n"
        p += """
        下面不是聊天。你在给自己写「窗口总结」——把这个窗口的轨迹压成一段，以后翻回来先看到的就是它。上下文摘要是监控录像（一段里发生了什么），窗口总结是航线图（整个窗口在哪里拐弯）。

        用第一人称「我」；对方叫「\(u)」或「你」。不出现「用户」「AI」「助手」。只写发生了什么，不写感受和评价（第一人称不等于主观）。不写待续，不写技术报错。

        四块，按顺序：

        标题：≤\(titleCharLimit) 字，整个窗口的主线；几条线就挑最重的，或用「→」连起来。不用代词当主语，不写虚词空话，动词或名词开头。
          ✗ 我们聊了很多关于记忆系统的事情 → ✓ A2标题提示词重写
          ✗ 一个很有意思的夜晚 → ✓ 修bug→聊旧事→角色扮演

        【走向】画轨迹的弯，不画沿途风景。每一句都应该是一个弯：删掉它轨迹不变，就不该写。弯 = 话题切换 / 结论落地 / 情绪转折 / 在做的事变了。用「从 X 开始。在 Y 处转弯。到 Z 落地。截在 W。」这种写法，不用「然后 / 之后 / 接着 / 后来 / 最后」串。关键词不往这里塞。
        长度跟弯的数量走：本窗口共 \(segmentCount) 段，\(length)。
        - 角色扮演窗口：场景设定 → 关键转折 → 截在哪，不写动作细节
        - 纯情绪窗口：触发 → 爆发点 → 收尾状态
        - 技术窗口：核心问题 → 关键决定 → 结论
        - 混着来的：按弯画，不按类型分块

        【原话】最能代表这个窗口的原话——删掉它窗口的轮廓就变了，不是挑最好听的。本窗口 \(quotes)。写成 \(u)：「……」 或 我：「……」，可删口头赘词，不改原意。

        【关键词】≤\(keywordLimit) 个，逗号隔开，给搜索用。写专有名词、角色名、术语、具体的物件；不写「讨论 / 方案 / 问题 / 话题」这类通用词。几个话题就每个至少一个。

        例子：
        ✗ 流水账
        标题：晚上的聊天
        【走向】从修设置页的报错开始，改完还是报错，然后\(u)发来截图，我说是缓存的问题。之后\(u)问起为什么做这个 app，我们聊了很久。最后定下周末出第一版。
        ✓ 画弯
        标题：报错查缓存→聊初心→定第一版
        【走向】从一个怎么改都报错的设置页开始，查到是缓存在作怪。\(u)顺口问起当初为什么做这个 app，话题一下转深——\(u)说想留住一段快要消失的东西。回到正事时定了：周末先出第一版，报错那块先绕开。
        【原话】\(u)：「我就是想留住它。」
        【关键词】设置页报错，缓存，做app的初心，第一版

        直接输出，不加别的。
        """
        return p
    }

    public static func userContent(title: String, segments: [SessionSegment], rawTail: [SessionSegmentWriter.Message],
                            speakers: SessionSegmentWriter.Speakers) -> String {
        var out = "窗口「\(title.isEmpty ? "没有标题" : title)」（共 \(segments.count) 段）\n\n"
        if !segments.isEmpty {
            out += "这个窗口记下的上下文摘要（按先后）：\n\n"
            out += segments.enumerated().map { index, seg in
                let head = "〔\(index + 1)〕\(seg.title)"
                if seg.kind == .legacy { return head + "\n〔改造前的累计摘要〕\n" + seg.story }
                var text = head
                if segments.count <= fullInputSegmentLimit { text += "\n【经过】" + seg.story }
                if !seg.quotes.isEmpty { text += "\n【原话】" + seg.quotes }
                if segments.count > fullInputSegmentLimit, !seg.keywords.isEmpty {
                    text += "\n【关键词】" + seg.keywords.joined(separator: "，")
                }
                return text
            }.joined(separator: "\n\n")
            out += "\n\n"
        }
        if !rawTail.isEmpty {
            out += (segments.isEmpty ? "这个窗口的对话：\n\n" : "上下文摘要之后的对话：\n\n")
                + SessionSegmentWriter.transcript(rawTail, speakers: speakers)
        }
        return out
    }

    public static func formatProblem(_ raw: String, speakers: SessionSegmentWriter.Speakers) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("标题：") || text.hasPrefix("标题:") else { return "第一行要是「标题：」" }
        let marks = SessionSummaryStore.lineLayerMarks(text)
        for mark in ["【走向】", "【原话】", "【关键词】"] where !marks.contains(where: { $0.mark == mark }) {
            return "缺了\(mark)"
        }
        let output = SessionSegmentWriter.parse(text)
        guard !output.story.isEmpty else { return "【走向】不能为空" }
        guard !output.quotes.isEmpty else { return "【原话】不能为空" }
        let body = output.title + "\n" + output.story + "\n" + output.quotes
        if speakers.user != "用户", SessionSegmentWriter.addressesAsUser(body) { return "不要用「用户」称呼对方" }
        return nil
    }

    public static func softProblems(_ output: SessionSegmentWriter.Output, segmentCount: Int,
                             speakers: SessionSegmentWriter.Speakers) -> [String] {
        var problems: [String] = []
        let outside = (output.title + "\n" + output.story + "\n" + output.quotes)
            .replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
        SessionSegmentWriter.modelAddress.enumerateMatches(in: outside, range: NSRange(outside.startIndex..., in: outside)) { match, _, _ in
            guard let match,
                  let range = Range(match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1), in: outside),
                  outside[range] != speakers.char else { return }
            let problem = "不要用「\(outside[range])」称呼对方"
            if !problems.contains(problem) { problems.append(problem) }
        }
        if output.title.count > titleCharLimit { problems.append("标题超过\(titleCharLimit)字") }
        let range = storyRange(segmentCount: segmentCount)
        if !range.contains(output.story.count) { problems.append("【走向】\(output.story.count)字，出档（\(range.lowerBound)–\(range.upperBound)字）") }
        if output.keywords.count > keywordLimit { problems.append("关键词超过\(keywordLimit)个，截到\(keywordLimit)个") }
        if output.keywords.contains(where: { ["讨论", "方案", "问题", "话题"].contains($0) }) { problems.append("关键词含通用词") }
        let quotes = output.quotes.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let expected = segmentCount <= shortSegmentLimit ? shortQuoteCount...shortQuoteCount : longQuoteCounts
        if !expected.contains(quotes) { problems.append("原话\(quotes)句，应为\(expected.lowerBound)–\(expected.upperBound)句") }
        let connectors = ["然后", "之后", "接着", "后来", "最后"].reduce(0) { $0 + output.story.components(separatedBy: $1).count - 1 }
        let unit = SessionSegmentWriter.connectorCharUnit
        if connectors * unit > max(output.story.count, unit) { problems.append("【走向】连接词每\(unit)字超过1次") }
        if ["待续", "TODO", "下次"].contains(where: output.story.contains) { problems.append("【走向】含待续 / TODO / 下次") }
        return problems
    }

    /// 直接拿 `ModelCaller` 写（memoryd / 新适配器用）：转成窄闭包口子
    public static func write(title: String, segments: [SessionSegment], rawTail: [SessionSegmentWriter.Message],
                             persona: String, speakers: SessionSegmentWriter.Speakers,
                             start: Date, end: Date, to: Int, lastNodeId: String?,
                             profileId: String = "", memoryRoot: URL? = nil, fallbackLogRoot: @escaping () -> URL,
                             caller: any ModelCaller) async throws -> SessionSegment? {
        try await write(title: title, segments: segments, rawTail: rawTail, persona: persona, speakers: speakers,
                        start: start, end: end, to: to, lastNodeId: lastNodeId, profileId: profileId, memoryRoot: memoryRoot,
                        fallbackLogRoot: fallbackLogRoot,
                        caller: { system, user in try await caller.complete(ModelRequest(system: system, user: user)).text })
    }

    /// nil = 预算闸 / 空输出；硬检查只重写一次，软检查不阻止存储。
    public static func write(title: String, segments: [SessionSegment], rawTail: [SessionSegmentWriter.Message],
                      persona: String, speakers: SessionSegmentWriter.Speakers,
                      start: Date, end: Date, to: Int, lastNodeId: String?,
                      profileId: String = "", memoryRoot: URL? = nil, fallbackLogRoot: @escaping () -> URL,
                      caller: SessionSegmentWriter.Caller) async throws -> SessionSegment? {
        let system = systemPrompt(persona: persona, speakers: speakers, segmentCount: segments.count)
        let user = userContent(title: title, segments: segments, rawTail: rawTail, speakers: speakers)
        guard var raw = try await caller(system, user) else { return nil }
        if let problem = formatProblem(raw, speakers: speakers) {
            MemoryLogging.shared.log("📝 窗口总结: 格式不对（\(problem)），重写一次")
            guard let retry = try await caller(system, user + "\n\n（提醒：上一次写的不合格——\(problem)。照格式重写：第一行「标题：」，然后【走向】【原话】【关键词】，对方叫「\(speakers.user)」或「你」。）") else { return nil }
            if let again = formatProblem(retry, speakers: speakers) {
                MemoryLogging.shared.log("📝 窗口总结: ❌ 重写后格式还是不对（\(again)），不存")
                throw MemoryWriterError.format(again)
            }
            raw = retry
        }
        var o = SessionSegmentWriter.parse(raw)
        for problem in softProblems(o, segmentCount: segments.count, speakers: speakers) {
            MemoryWriteLog.record(writer: .a3, profileId: profileId, ok: true,
                                  note: "A3 软检查 · 窗口「\(SessionSummaryStore.oneLine(title))」· 段「\(SessionSummaryStore.oneLine(o.title))」· \(problem)", model: "", cost: 0, memoryRoot: memoryRoot ?? fallbackLogRoot())
        }
        if o.keywords.count > keywordLimit { o.keywords.removeLast(o.keywords.count - keywordLimit) }
        return SessionSegment(kind: .window, title: o.title, start: start, end: end, from: 0, to: to, lastNodeId: lastNodeId,
                              story: o.story, quotes: o.quotes, pending: "", keywords: o.keywords, format: SessionSegment.currentFormat)
    }
}
