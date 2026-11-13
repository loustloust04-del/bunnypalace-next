import Foundation

/// A4 主调写手（plan-memory-c2c3-v2 第 7 段 + rev5 §3）：只喂一天的 A2 标题清单 + 日期，不带人设；
/// 只交 `{"headline":"≤40 字","topics":["1–3 个话题词"]}`。topics 坏了只丢 topics，主调照收
public enum TimelineWriter {

    public struct Draft: Equatable {
        public var headline: String
        public var topics: [String]

        public init(headline: String, topics: [String]) {
            self.headline = headline
            self.topics = topics
        }
    }

    public static let maxTopics = 3
    public static let topicMaxChars = 16

    // MARK: - 提示词

    public static let systemPrompt = """
    这是一天的聊天话题列表（每行一段聊天的标题，按时间先后）。用一句话概括这一天整体是什么样的，不超过 \(TimelineStore.headlineLimit) 字；再挑 1–3 个这一天的话题词（几个字的名词或短语）。
    只写发生了什么，不写感受和评价；不写技术报错、重试；不出现「用户」「AI」「助手」「人类」这类称呼。
    只输出一个 JSON，不加别的字：{"headline":"那一句话","topics":["话题词"]}
    """

    public static func userContent(date: String, titles: [String]) -> String {
        ([date] + titles).joined(separator: "\n")
    }

    // MARK: - 解析

    /// 纯函数：主调拿得到 → Draft（超 40 字截到 40 字、记日志）；拿不到 → nil。
    /// 先按 JSON 读；JSON 坏了按字面捞 "headline"；整个没给 JSON（本机小模型常这样）就把第一行当主调
    public static func parse(_ raw: String) -> Draft? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = t.range(of: "<think>") {
            guard let close = t.range(of: "</think>", range: open.upperBound..<t.endIndex) else { return nil }
            t = (String(t[..<open.lowerBound]) + String(t[close.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headline: String?
        var topicsRaw: Any?
        if let object = FragmentPool.strictObjectText(t),
           let dict = (try? JSONSerialization.jsonObject(with: Data(object.utf8))) as? [String: Any] {
            headline = dict["headline"] as? String
            topicsRaw = dict["topics"]
        } else if t.contains("\"headline\"") {
            headline = captured(#""headline"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: t).flatMap(unescaped)
            topicsRaw = captured(#""topics"\s*:\s*(\[[^\]]*\])"#, in: t).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        } else if !t.contains("{") {
            headline = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        } else {
            headline = nil
        }
        guard var h = headline.map(clean), !h.isEmpty else { return nil }
        if h.count > TimelineStore.headlineLimit {
            MemoryLogging.shared.log("📝 时间轴: 主调 \(h.count) 字，截到 \(TimelineStore.headlineLimit) 字")
            h = String(h.prefix(TimelineStore.headlineLimit))
        }
        return Draft(headline: h, topics: topics(topicsRaw))
    }

    /// 话题词：只收字符串数组里的、去空、去重、每个不超过 topicMaxChars 字，最多 3 个；不是数组 = 丢掉，主调不受影响
    public static func topics(_ raw: Any?) -> [String] {
        guard let raw else { return [] }
        guard let list = raw as? [Any] else {
            MemoryLogging.shared.log("📝 时间轴: topics 不是数组，只丢 topics")
            return []
        }
        var out: [String] = []
        for case let s as String in list {
            let w = clean(s)
            guard !w.isEmpty, w.count <= topicMaxChars, !out.contains(w) else { continue }
            out.append(w)
        }
        if out.count > maxTopics { MemoryLogging.shared.log("📝 时间轴: topics 给了 \(out.count) 个，留前 \(maxTopics) 个") }
        return Array(out.prefix(maxTopics))
    }

    private static func clean(_ s: String) -> String {
        var t = SessionSummaryStore.oneLine(s)
        for (a, b) in [("\"", "\""), ("「", "」"), ("“", "”"), ("'", "'")] where t.count >= 2 && t.hasPrefix(a) && t.hasSuffix(b) {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func captured(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func unescaped(_ s: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data("\"\(s)\"".utf8), options: .fragmentsAllowed)) as? String ?? s
    }

    // MARK: - 执行

    /// 直接拿 `ModelCaller` 写（memoryd / 新适配器用）
    public static func write(date: String, titles: [String], caller: any ModelCaller) async throws -> Draft? {
        try await write(date: date, titles: titles,
                        caller: { system, user in try await caller.complete(ModelRequest(system: system, user: user)).text })
    }

    /// 调一次（不重写：一天一次调用）。nil = 预算闸 / 开关 / 空输出跳过；主调拿不到抛 `.format`
    public static func write(date: String, titles: [String], caller: SessionSegmentWriter.Caller) async throws -> Draft? {
        guard let raw = try await caller(systemPrompt, userContent(date: date, titles: titles)) else { return nil }
        guard let draft = parse(raw) else {
            MemoryLogging.shared.log("📝 时间轴: ❌ \(date) 没拿到主调，不存")
            throw MemoryWriterError.format("没拿到主调")
        }
        return draft
    }
}
