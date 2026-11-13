import Foundation

/// 记忆写手共用的小件
public struct MemoryExtractor {
    /// 楼层真名（空的话：对方叫「用户」，自己叫「我」）。人设里的 {{user}} / {{char}} 宏也换成真名
    public struct Names: Equatable, Sendable {
        public let user: String
        public let char: String

        public init(userName: String, assistantName: String) {
            let u = userName.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
            user = u.isEmpty ? "用户" : u
            char = c.isEmpty ? "我" : c
        }

        public func apply(_ text: String) -> String {
            text.replacingOccurrences(of: "{{user}}", with: user, options: .caseInsensitive)
                .replacingOccurrences(of: "{{char}}", with: char, options: .caseInsensitive)
        }
    }
}

// MARK: - C2 碎片池：小小模型填严格 JSON（v5 §3-1、plan §七）

/// 只看称呼 + 这一截消息（`[3]` 编号），不带主提示词；只交 `{"fragments":[…]}`（Scarlett 脱水各字段 + category）。
/// JSON 或单卡不合格都只重写一次；最终一包才落库，第二轮坏卡丢弃。
/// 只加不改不删，一字不差的不加
extension FragmentPool {
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

    public struct Fragment: Decodable, Equatable {
        public let msg: Int
        public let content: String
        public let tags: [String]
        public let importance: Int
        public let emotion: Int
        public let resolved: Bool?
        public let category: String
        public var subject: String? = nil
        public var speaker: String? = nil
        /// 带明确日子的事到哪天（YYYY-MM-DD，规格 4⅞-3）；类型 / 日期不对只丢这个字段
        public var validUntil: Loose? = nil

        public init(msg: Int, content: String, tags: [String], importance: Int, emotion: Int, resolved: Bool?,
                    category: String, subject: String? = nil, speaker: String? = nil, validUntil: Loose? = nil) {
            self.msg = msg
            self.content = content
            self.tags = tags
            self.importance = importance
            self.emotion = emotion
            self.resolved = resolved
            self.category = category
            self.subject = subject
            self.speaker = speaker
            self.validUntil = validUntil
        }

        enum CodingKeys: String, CodingKey {
            case msg, content, tags, importance, emotion, resolved, category, subject, speaker
            case validUntil = "valid_until"
        }
    }

    /// 解不成字符串就当没写（不连累整张卡）
    public struct Loose: Decodable, Equatable {
        public let value: String?

        public init(_ value: String?) {
            self.value = value
        }

        public init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    /// 解出来的一包：合格的卡 + 拒收几张
    public struct Batch: Equatable {
        public let fragments: [Fragment]
        public let rejected: Int
        public var rejectionReasons: [String] = []

        public init(fragments: [Fragment], rejected: Int, rejectionReasons: [String] = []) {
            self.fragments = fragments
            self.rejected = rejected
            self.rejectionReasons = rejectionReasons
        }
    }

    public static let categories = ["preference", "fact", "relationship", "goal", "context"]
    public static let speakers = ["用户自述", "AI 观察", "AI 承诺"]
    public static let maxMessageChars = 600
    public static let maxContentChars = 200
    public static let maxSubjectChars = 40
    public static let maxTags = 5

    /// 提示词编辑页的自定义模板（新 key；老的 AUDN 形状模板对不上这张表，不迁移）
    public static let customPromptKey = "customFragmentPrompt"

    /// e62b23fa4 的默认全文，仅识别旧编辑器保存的未修改默认；不作为出站模板。
    private static let legacyDefaultTemplate = """
这不是在跟你聊天。你是填表的工具：读下面这段对话，把里面的事实一条一条填进表里。
事实 = 过一个月还成立、还用得上的事：{{USER_NAME}}是谁、有什么、在做什么、喜欢 / 讨厌什么、身体和生活的状况、和{{CHAR_NAME}}之间定下的约定和关系变化。
大多数对话里没有新事实，交 {"fragments":[]} 是正常的。宁可漏，不要凑。

只输出一个 JSON 对象，不要别的字：{"fragments":[{"msg":3,"content":"……","tags":["……"],"importance":3,"emotion":0,"resolved":null,"category":"fact"}]}；没有就 {"fragments":[]}。
- msg：这件事出自第几条（方括号里的编号）。日期不用写。
- content：一件事一条，120 字以内，干的陈述句，主语写名字（{{USER_NAME}} / {{CHAR_NAME}}），不用「我」「你」，不写感受评价。
- tags：关键词，最多 5 个。
- importance：1 到 5，5 = 一直要记得。
- emotion：-2 到 2，这件事带的情绪，0 = 平常。
- resolved：事情了结了填 true，还悬着填 false，说不上填 null。
- category：preference / fact / relationship / goal / context 选一个。
  relationship 只放{{USER_NAME}}和{{CHAR_NAME}}之间定下的约定、关系变化；拿不准填 fact。
- valid_until：只有带明确日子的事才写（复诊、截止、约好的那天），写到那天为止，格式 YYYY-MM-DD；「明天」「下周三」这类相对日期按那条消息自己的日期（编号后面那个日子）换算成日子，没标日子的按这一截最后一天（{{DATE}}）。没有就不写这个字段。
亲密互动里{{USER_NAME}}说的自身喜好、身体感受、边界都是真事，要记；只有括号里的动作描写和架空设定才算演出来的剧情。

不记：
- 客套闲聊、在问不是在说的（比如「这个报错是啥意思」）、报错 / 网络 / 工具失败、演出来的剧情（跳出剧情说的真事照记）。
- 对话经过：谁说了什么、谁承认 / 解释 / 道歉、谁看不懂谁——这些是时间轴的事，不是事实。
- {{CHAR_NAME}}说的话、做的事（只有对{{USER_NAME}}的承诺例外）。
- 把一句话原样抄成一条：content 必须是你自己写的陈述句，不是某一条消息的复制。
- 正在进行的工作步骤（「在写 plan」「收到单子了」）；只记做成了 / 定下来的结果。

坏例子（这些都不该进表）：
- 「{{CHAR_NAME}}承认漏画了船帆」——对话经过
- 「{{USER_NAME}}：这艘模型船要装两面帆吗？」——把一句提问原样抄了
- 「{{CHAR_NAME}}：船帆已经加进去了」——{{CHAR_NAME}}自己的话
好例子：
- 「{{USER_NAME}}在制作灯塔航线模型船，10-15 定下双帆方案」
例子只示范写法，别把例子里的事填进表。
"""

    public static let defaultTemplate = """
这不是聊天。读两边对话，只把值得长期记住的事实填表。只记{{USER_NAME}}的事实；{{CHAR_NAME}}只有对{{USER_NAME}}的承诺或约定例外。
按顺序判断：
1. 一个月后还成立、还用得上吗？不确定、临时请求、纯讨论不记。
2. 是属性、状态、偏好或关系变化吗？记独立可读的状态句。
3. 是定下的结论或决定吗？写具体结论，不写「同意了」「决定照做」之类过程。
4. 是{{CHAR_NAME}}对{{USER_NAME}}的承诺吗？记，category=relationship；其他{{CHAR_NAME}}的话，包括普通观察和评价，不记。
大多数对话没有新事实，没有就 {"fragments":[]}，不要凑。

只输出一个 JSON 对象，不要别的字：
{"fragments":[{"msg":3,"content":"……","tags":["……"],"importance":3,"emotion":0,"resolved":null,"category":"fact","subject":"……","speaker":"用户自述"}]}
content、subject、tags 里引用词语一律用「」，不要用英文双引号。
- msg / content / tags / importance / emotion / category / subject / speaker 必填，格式如下。
- msg：事实出自哪条消息，填方括号里的编号；两边上下文可帮你读懂，不把助手的观察变成用户自述。
- content：一件事一条，1–3 句，≤200 字，脱离原文能读懂的状态句或结论句；主语写名字或明确事物，不用「我」「你」「那个」。不要原样复制消息。
- subject：这件事说的那个人或东西的名字本身，不写「X 的 Y」这种方面短语，方面写进 content 和 tags；同一个人或东西有几种叫法，用这段对话里最常用的那个。不能为空，最多 40 个字（按 Character 计），超长要改写，不裁剪。
- speaker：只填「用户自述」或「AI 承诺」，按事实来源归因，不按 content 的主语猜。
- tags：关键词数组，最多 5 个，没有填 []。
- importance：1–5，5 = 一直要记得。
- emotion：必填整数，-2…2，0 = 平常。
- resolved：已了结 true，还悬着 false，说不上 null。
- category：preference（偏好）/ fact（事实）/ relationship（两人约定或关系变化）/ goal（目标）/ context（状况）选一个。
- valid_until：只有带明确日子的事才写到那天为止，格式 YYYY-MM-DD。相对日期按来源消息编号后的日期换算；没标日期按这一截最后一天（{{DATE}}）；没有明确日期就不写，不猜。

亲密互动里{{USER_NAME}}说的自身喜好、真实身体感受和边界都是真事，要记；括号动作描写、架空动作不是现实事实。持久共享角色设定沿对话上下文理解，不把演出来的一次动作当现实经历。
不记工具日志、报错或工具失败、临时步骤、对话经过、一次性请求、提问和未定的讨论。只记做成了或定下来的结果。

以下全是编造的正反例，只示范写法，不填进表：
- 坏：{{USER_NAME}}同意了那个规则。好：《灯塔航线》规则定为每局三轮、轮流领航。
- 坏：{{CHAR_NAME}}说配色很好。这是普通观察，不记。
- 好：{{CHAR_NAME}}承诺下次陪{{USER_NAME}}画《云桥城》地图。subject={{CHAR_NAME}}，speaker=AI 承诺，category=relationship。
- 坏：「帮我查一下模型船胶水的价格」。一次请求，不记。
- 好：{{USER_NAME}}制作模型船时只用水性颜料。subject={{USER_NAME}}，speaker=用户自述。
- 坏：subject={{USER_NAME}}的作息、subject={{USER_NAME}}的模型船船帆。好：subject={{USER_NAME}}、subject=模型船，作息、船帆写进 content 和 tags。

写后自检：每条是否长期有用、独立可读、有明确主语和来源？是否写出了结论而非过程、没有原样复制、没有混入工具或助手观察？字段齐全、枚举和日期正确、content≤200 字、tags≤5；不合格的改写或删掉，不为填表编事实。
"""

    /// day = 这截对话最后一天（没标日子的消息换算「下周三」用）；不给 = 今天
    public static func systemPrompt(names: MemoryExtractor.Names, defaults: UserDefaults = .standard, day: String? = nil) -> String {
        expandedPrompt(customTemplate(defaults) ?? defaultTemplate, names: names, day: day)
    }

    /// 现在生效的自定义模板（没有 / 是旧默认 = nil）：试写台把它导成「现在的自定义」配方
    public static func activeCustomTemplate(defaults: UserDefaults = .standard) -> String? {
        customTemplate(defaults)
    }

    private static func customTemplate(_ defaults: UserDefaults) -> String? {
        guard let text = defaults.string(forKey: customPromptKey) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != legacyDefaultTemplate else { return nil }
        return text
    }

    private static func expandedPrompt(_ template: String, names: MemoryExtractor.Names, day: String?) -> String {
        template.replacingOccurrences(of: "{{USER_NAME}}", with: names.user)
            .replacingOccurrences(of: "{{CHAR_NAME}}", with: names.char)
            .replacingOccurrences(of: "{{DATE}}", with: day ?? MemoryDay.key(Date()))
    }

    /// 每条前面一个编号和它那天 `[3] 2026-10-18 · 粟粟：……`（记忆日 05:00 分界、设备时区；没时间的不带），每条最多 600 字；
    /// charBudget 给本机路线（装不下从最早的往外丢，编号不变）
    public static func userContent(_ messages: [Message], names: MemoryExtractor.Names, charBudget: Int? = nil) -> String {
        window(messages, names: names, charBudget: charBudget).text
    }

    /// 送进去的那截 + 模型看得到的编号（被预算丢掉的前几条不算）
    public static func window(_ messages: [Message], names: MemoryExtractor.Names, charBudget: Int?) -> (text: String, visible: ClosedRange<Int>) {
        var lines = messages.enumerated().map { i, m -> String in
            let label = m.role == "user" ? names.user : names.char
            let text = m.content.count > maxMessageChars ? String(m.content.prefix(maxMessageChars)) + "…" : m.content
            return "[\(i + 1)] " + (m.date.map { MemoryDay.key($0) + " · " } ?? "") + "\(label)：\(text)"
        }
        if let charBudget {
            while lines.count > 1, lines.reduce(0, { $0 + $1.count + 2 }) > charBudget { lines.removeFirst() }
        }
        return (lines.joined(separator: "\n\n"), (messages.count - lines.count + 1)...max(messages.count, 1))
    }

    // MARK: - 严格解析（纯函数）

    private struct Envelope: Decodable {
        let fragments: [Lossy]
    }

    private struct Lossy: Decodable {
        let value: Fragment?
        let reason: String?

        init(from decoder: Decoder) throws {
            do {
                let fields = try decoder.container(keyedBy: Fragment.CodingKeys.self)
                for key in [Fragment.CodingKeys.subject, .speaker] where fields.contains(key) {
                    _ = try fields.decode(String.self, forKey: key)
                }
                value = try Fragment(from: decoder)
                reason = nil
            } catch {
                value = nil
                reason = decodingReason(error)
            }
        }
    }

    private static func decodingReason(_ error: Error, text: String? = nil) -> String {
        switch error {
        case DecodingError.dataCorrupted(let context):
            let parser = (context.underlyingError ?? error) as NSError
            let debug = parser.userInfo[NSDebugDescriptionErrorKey] as? String ?? context.debugDescription
            var reason = "JSON 数据格式不合法（解析器：\(debug)）"
            if let text, let offset = parser.userInfo["NSJSONSerializationErrorIndex"] as? Int,
               let byteIndex = text.utf8.index(text.utf8.startIndex, offsetBy: max(0, offset), limitedBy: text.utf8.endIndex),
               let position = String.Index(byteIndex, within: text) {
                let lower = text.index(position, offsetBy: -10, limitedBy: text.startIndex) ?? text.startIndex
                let upper = text.index(position, offsetBy: 10, limitedBy: text.endIndex) ?? text.endIndex
                reason += "；第 \(text.distance(from: text.startIndex, to: position) + 1) 字符附近：\(text[lower..<upper])"
            }
            return reason + #"；字符串里的双引号要写成 \" 或改用「」。"#
        case DecodingError.keyNotFound(let key, _): return "缺少字段 \(key.stringValue)"
        case DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context):
            return "\(context.codingPath.last?.stringValue ?? "卡片") 类型不合法或为 null"
        default: return "JSON 数据格式不合法"
        }
    }

    /// nil = 整包不合格；卡片错误保留原因供唯一一次整包重写。
    public static func parse(_ raw: String, visible: ClosedRange<Int>, messages: [Message] = [],
                      requireAttribution: Bool = true) -> Batch? {
        try? decodedBatch(raw, visible: visible, messages: messages, requireAttribution: requireAttribution)
    }

    /// 同 `parse`，整包不合格时带上原因（试写台的检查要显示哪条没过）
    public static func parseExplained(_ raw: String, visible: ClosedRange<Int>, messages: [Message] = [],
                               requireAttribution: Bool = true) -> (batch: Batch?, problem: String?) {
        do {
            return (try decodedBatch(raw, visible: visible, messages: messages, requireAttribution: requireAttribution), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private static func decodedBatch(_ raw: String, visible: ClosedRange<Int>, messages: [Message],
                                     requireAttribution: Bool) throws -> Batch {
        guard let text = strictObjectText(raw), let data = text.data(using: .utf8) else {
            throw MemoryWriterError.format("必须只输出一个 JSON 对象")
        }
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw MemoryWriterError.format(decodingReason(error, text: text)) }
        var kept: [Fragment] = []
        var reasons: [String] = []
        for (index, item) in env.fragments.enumerated() {
            guard var f = item.value else {
                reasons.append("第 \(index + 1) 张：\(item.reason ?? "卡片格式不合法")")
                continue
            }
            let content = f.content.trimmingCharacters(in: .whitespacesAndNewlines)
            f.subject = f.subject?.trimmingCharacters(in: .whitespacesAndNewlines)
            f.speaker = f.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = validationReason(f, content: content, visible: visible, messages: messages, requireAttribution: requireAttribution) {
                reasons.append("第 \(index + 1) 张：\(reason)")
                continue
            }
            kept.append(Fragment(msg: f.msg, content: content,
                                 tags: f.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                                 importance: f.importance, emotion: f.emotion, resolved: f.resolved, category: f.category,
                                 subject: f.subject, speaker: f.speaker,
                                 validUntil: validDay(f.validUntil?.value).map { Loose($0) }))
        }
        return Batch(fragments: kept, rejected: reasons.count, rejectionReasons: reasons)
    }

    private static let copyIgnored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)

    private static func validationReason(_ f: Fragment, content: String, visible: ClosedRange<Int>, messages: [Message],
                                         requireAttribution: Bool) -> String? {
        guard visible.contains(f.msg) else { return "msg 不在本次可见编号内" }
        guard !content.isEmpty else { return "content 不能为空" }
        guard content.count <= maxContentChars else { return "content 超过 200 字，不能裁剪" }
        guard f.tags.count <= maxTags else { return "tags 超过 5 个" }
        guard (1...5).contains(f.importance) else { return "importance 必须为 1–5" }
        guard (-2...2).contains(f.emotion) else { return "emotion 必须为 -2…2" }
        guard categories.contains(f.category) else { return "category 不在允许枚举内" }
        if requireAttribution && (f.subject == nil || f.speaker == nil) { return "新默认必须填写 subject / speaker" }
        if let subject = f.subject {
            if subject.isEmpty { return "subject 不能为空" }
            if subject.count > maxSubjectChars { return "subject 超过 40 字，不能裁剪" }
        }
        if let speaker = f.speaker, !speakers.contains(speaker) || (requireAttribution && speaker == "AI 观察") {
            return "speaker 不在允许枚举内"
        }
        if messages.indices.contains(f.msg - 1),
           content.lazy.filter({ $0.unicodeScalars.allSatisfy { !copyIgnored.contains($0) } }).elementsEqual(
            messages[f.msg - 1].content.lazy.filter { $0.unicodeScalars.allSatisfy { !copyIgnored.contains($0) } }) {
            return "content 去掉空白、标点和符号后与 msg 原文完全相同，必须改写"
        }
        return nil
    }

    /// 到哪天为止 → 那一天的记忆日结束（次日 05:00）
    public static func validUntilDate(_ day: String, calendar: Calendar = .current) -> Date? {
        guard let d = MemoryDay.date(ofKey: day, calendar: calendar), let next = calendar.date(byAdding: .day, value: 1, to: d) else { return nil }
        return MemoryDay.boundary(of: next, calendar: calendar)
    }

    /// 仅反馈第一处具体错误及总数，不把模型的坏输出再次灌入提示词。
    public static let retryNote = "\n\n上一次不合格：请修正后重交完整的 {\"fragments\":[…]} JSON 对象，不要别的字。\n原因："

    /// 整包或单卡失败都只重写一次；第二轮只保留合格卡，不先写第一轮。
    /// userBudget = 本机路线留给对话那截的字数（按 system 字数和重来那句的长度算）；云上不给
    public static func run(_ messages: [Message], names: MemoryExtractor.Names,
                           userBudget: ((_ system: String, _ retryChars: Int) -> Int)? = nil,
                    defaults: UserDefaults = .standard, onFirstRejection: ((Int, String) -> Void)? = nil,
                    caller: SessionSegmentWriter.Caller) async throws -> Batch? {
        guard !messages.isEmpty else { return Batch(fragments: [], rejected: 0) }
        let custom = customTemplate(defaults)
        let system = expandedPrompt(custom ?? defaultTemplate, names: names, day: messages.last?.date.map { MemoryDay.key($0) })
        let sent = window(messages, names: names, charBudget: userBudget?(system, retryNote.count))
        guard let raw = try await caller(system, sent.text) else { return nil }
        let reason: String
        var rejected = 1
        do {
            let batch = try decodedBatch(raw, visible: sent.visible, messages: messages, requireAttribution: custom == nil)
            if batch.rejected == 0 { return batch }
            rejected = batch.rejected
            reason = batch.rejectionReasons.first ?? "卡片校验失败"
        } catch { reason = error.localizedDescription }
        onFirstRejection?(rejected, reason)
        MemoryLogging.shared.log("🧠 碎片池: \(reason)，重写一次")
        let note = retryNote + reason + "；共 \(rejected) 张不合格"
        let retrySent = window(messages, names: names,
                               charBudget: userBudget?(system, note.count))
        guard let retry = try await caller(system, retrySent.text + note) else { return nil }
        return try decodedBatch(retry, visible: retrySent.visible, messages: messages, requireAttribution: custom == nil)
    }
}
