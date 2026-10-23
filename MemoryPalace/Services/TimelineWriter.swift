import Foundation

/// 时间轴写手（W3②，plan-memory-v4-1 §五②）：一天 × 一个窗口一条。动笔前先读这一天这个窗口已有的那条（改写它），
/// 这一天还没有时读这个窗口上一条的待续；输出改写后的整条（话题行 + 待续）。和窗口总结分开调，格式不同
enum TimelineWriter {

    struct Draft: Equatable {
        var topics: [String]
        var pending: [String]

        /// 存进条目：一个话题一行「- 话题」；待续一条一行
        var text: String { topics.map { "- \($0)" }.joined(separator: "\n") }
        var pendingText: String { pending.joined(separator: "\n") }
    }

    // MARK: - 提示词

    static func systemPrompt(persona: String, speakers: SessionSegmentWriter.Speakers) -> String {
        let u = speakers.user
        var p = ""
        if !persona.isEmpty {
            p += persona + "\n\n——以上是你的设定。\n\n"
        }
        p += """
        下面不是聊天，是你在给自己记「时间轴」：一天 × 一个窗口记一条，以后换了窗口、翻时间轴，靠它知道那天在这个窗口聊了什么、做到哪、还欠着什么。

        用你自己的口吻，第一人称「我」；对方就叫「\(u)」或「你」。不要出现「用户」「AI」「助手」这类称呼。

        按这个格式输出，第一行必须是【话题】：
        【话题】
        - 一个话题一行（40 字以内，写聊了 / 做了什么、停在哪）
        【待续】
        - 一条一行（做到一半的事、答应了的事、还没哄完的情绪；没有就写「- 无」）

        规则：
        - 输出改写后的整条，不是往后追加：这一天已经记下的话题留着，新的加在后面。
        - 待续逐条对一遍：做完的删掉，新的加上，没变的照抄；不加「仍未」「上段遗留」这类批注。
        - 不用「这个窗口……」开头；不用角色口吻回话，不写戏文、动作描写；不写技术报错、重试这些噪音。
        - 直接输出这两块，不加别的。
        """
        return p
    }

    static func userContent(day: String, windowTitle: String, existing: TimelineEntry?, previousPending: String?,
                            messages: [SessionSegmentWriter.Message], speakers: SessionSegmentWriter.Speakers) -> String {
        var out = "日期：\(day)（一天从凌晨 5 点算起）\n窗口：《\(windowTitle.isEmpty ? "没有标题" : windowTitle)》\n\n"
        if let existing {
            out += "这一天这个窗口已经记下的（改写它）：\n【话题】\n"
            out += existing.topics.map { "- \($0)" }.joined(separator: "\n")
            let pend = TimelineStore.pendingItems(existing.pending)
            out += "\n【待续】\n" + (pend.isEmpty ? "- 无" : pend.map { "- \($0)" }.joined(separator: "\n")) + "\n\n"
        } else {
            out += "这一天这个窗口还没记过。\n"
            let pend = previousPending.map(TimelineStore.pendingItems) ?? []
            if !pend.isEmpty {
                out += "这个窗口上一条的待续（逐条对一遍）：\n" + pend.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            out += "\n"
        }
        out += "这一份对话：\n\n" + SessionSegmentWriter.transcript(messages, speakers: speakers)
        return out
    }

    // MARK: - 解析 / 格式检查

    /// 纯函数：合格 → (draft, nil)；不合格 → (nil, 带进重写提醒的那句话)
    static func parse(_ raw: String) -> (draft: Draft?, problem: String?) {
        let lines = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, first.hasPrefix("【话题】") else { return (nil, "第一行必须是【话题】，前面不能有任何字") }
        guard let pendIdx = lines.firstIndex(where: { $0.hasPrefix("【待续】") }) else { return (nil, "缺了【待续】") }
        let topics = lines[1..<pendIdx].filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !topics.isEmpty else { return (nil, "【话题】下面至少要有一行「- 」开头的话题") }
        var pending = lines[(pendIdx + 1)...].filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) : $0 }
            .filter { !$0.isEmpty }
        if pending == ["无"] { pending = [] }
        let outside = (topics + pending).joined(separator: "\n")
            .replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
        if outside.contains("用户") { return (nil, "不要用「用户」称呼对方") }
        return (Draft(topics: topics, pending: pending), nil)
    }

    // MARK: - 执行

    struct Request {
        let day: String
        let windowTitle: String
        let existing: TimelineEntry?
        let previousPending: String?
        let messages: [SessionSegmentWriter.Message]
        let persona: String
        let speakers: SessionSegmentWriter.Speakers
    }

    /// 写一份：格式不对带提醒重写一次，还不对抛 `.format`。nil = 预算闸 / 空输出
    static func write(_ req: Request, caller: SessionSegmentWriter.Caller) async throws -> Draft? {
        let system = systemPrompt(persona: req.persona, speakers: req.speakers)
        let user = userContent(day: req.day, windowTitle: req.windowTitle, existing: req.existing,
                               previousPending: req.previousPending, messages: req.messages, speakers: req.speakers)
        guard let raw = try await caller(system, user) else { return nil }
        let first = parse(raw)
        if let draft = first.draft { return draft }
        let problem = first.problem ?? "格式不对"
        CacheDiagLog.shared.log("📝 时间轴: 格式不对（\(problem)），重写一次")
        guard let retry = try await caller(system, user + "\n\n（提醒：上一次写的不合格——\(problem)。只输出【话题】【待续】两块，第一行就是【话题】。）") else { return nil }
        let second = parse(retry)
        if let draft = second.draft { return draft }
        let again = second.problem ?? "格式不对"
        CacheDiagLog.shared.log("📝 时间轴: ❌ 重写后格式还是不对（\(again)），不存")
        throw MemoryWriterError.format(again)
    }
}
