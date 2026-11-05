import Foundation

/// A3 窗口总结（v5 §1、plan §六 D2）：每次收尾读这个窗口 A2 的全部段 + 尾段，把整个窗口真·再压一遍，约 N 字。
/// 不再是 A2 的抄本。格式同上下文摘要（标题 /【经过】/【原话】），格式不对带提醒重写一次，还不对抛 `.format`
enum WindowSummaryWriter {

    static func systemPrompt(persona: String, speakers: SessionSegmentWriter.Speakers, chars: Int) -> String {
        let u = speakers.user
        var p = ""
        if !persona.isEmpty {
            p += persona + "\n\n——以上是你的设定。\n\n"
        }
        p += """
        下面不是聊天，是你在给自己写「窗口总结」：把这一整个窗口从头到尾再压一遍，压成一段。以后想起这个窗口，先看的就是它。

        用你自己的口吻，第一人称「我」；对方就叫「\(u)」或「你」。不要出现「用户」「AI」「助手」这类称呼。

        按这个格式输出，第一行就是标题，三块都要有：
        标题：一行，这个窗口聊了什么（15 字以内）
        【经过】约 \(chars) 字：从头到尾发生了什么、走到了哪。不按段落复述，挑要紧的。
        【原话】最要紧的两三句原话逐字抄，一句一行，写成 \(u)：「……」 或 我：「……」。

        不写待续（没做完的事记在时间轴里）。不写技术报错、重试这些噪音。直接输出，不加别的。
        """
        return p
    }

    /// 喂给模型的：A2 各段（标题 + 经过 + 原话，尾段也在里面）；A2 没盖到的最后那截给原文
    static func userContent(title: String, segments: [SessionSegment], rawTail: [SessionSegmentWriter.Message],
                            speakers: SessionSegmentWriter.Speakers) -> String {
        var out = "窗口：《\(title.isEmpty ? "没有标题" : title)》\n\n"
        if !segments.isEmpty {
            out += "这个窗口记下的上下文摘要（按先后）：\n\n"
            out += segments.map { seg in
                seg.kind == .legacy ? "〔改造前的累计摘要〕\n\(seg.story)" : "〔\(seg.title)〕\n\(SessionSummaryStore.segmentText(seg))"
            }.joined(separator: "\n\n")
            out += "\n\n"
        }
        if !rawTail.isEmpty {
            out += (segments.isEmpty ? "这个窗口的对话：\n\n" : "上下文摘要之后的对话：\n\n")
                + SessionSegmentWriter.transcript(rawTail, speakers: speakers)
        }
        return out
    }

    /// 写一段：nil = 预算闸 / 空输出
    static func write(title: String, segments: [SessionSegment], rawTail: [SessionSegmentWriter.Message],
                      persona: String, speakers: SessionSegmentWriter.Speakers, chars: Int,
                      start: Date, end: Date, to: Int, lastNodeId: String?,
                      caller: SessionSegmentWriter.Caller) async throws -> SessionSegment? {
        let system = systemPrompt(persona: persona, speakers: speakers, chars: chars)
        let user = userContent(title: title, segments: segments, rawTail: rawTail, speakers: speakers)
        guard var raw = try await caller(system, user) else { return nil }
        if let problem = SessionSegmentWriter.formatProblem(raw) {
            CacheDiagLog.shared.log("📝 窗口总结: 格式不对（\(problem)），重写一次")
            guard let retry = try await caller(system, user + "\n\n（提醒：上一次写的不合格——\(problem)。照格式重写：第一行「标题：」，然后【经过】【原话】，对方叫「\(speakers.user)」或「你」。）") else { return nil }
            if let again = SessionSegmentWriter.formatProblem(retry) {
                CacheDiagLog.shared.log("📝 窗口总结: ❌ 重写后格式还是不对（\(again)），不存")
                throw MemoryWriterError.format(again)
            }
            raw = retry
        }
        let o = SessionSegmentWriter.parse(raw)
        return SessionSegment(kind: .closeout, title: o.title, start: start, end: end, from: 0, to: to, lastNodeId: lastNodeId,
                              story: o.story, quotes: o.quotes, pending: "")
    }
}
