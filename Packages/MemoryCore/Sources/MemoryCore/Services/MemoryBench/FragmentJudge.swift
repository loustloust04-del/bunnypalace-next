import Foundation

/// C2 碎片的裁判（plan-c2-write-shape §3.1）：一个强模型对着出处原文，给每张卡判「能不能用」，
/// 再判它和此前的卡是不是重复 / 同一件事被切开。只打分，不改任何数据。
/// 这里只有提示词、解析和统计（纯函数）；调模型由调用方给
public enum FragmentJudge {
    /// 一张待判的卡。source = 它出处那条原文连同前面一两条（让裁判看得懂上下文）
    public struct Card: Equatable, Sendable {
        public let id: String
        public let content: String
        public let subject: String?
        public let speaker: String?
        public let category: String
        public let source: String

        public init(id: String, content: String, subject: String? = nil, speaker: String? = nil, category: String, source: String) {
            self.id = id
            self.content = content
            self.subject = subject
            self.speaker = speaker
            self.category = category
            self.source = source
        }
    }

    /// 此前已经有的卡（只给编号和正文，拿来判重复 / 切碎）
    public struct Prior: Equatable, Sendable {
        public let id: String
        public let content: String

        public init(id: String, content: String) {
            self.id = id
            self.content = content
        }
    }

    public enum Verdict: String, Codable, CaseIterable, Sendable {
        /// 过了这段对话还成立、读它不用回去翻原文的事实
        case ok
        /// 做 app / 写代码 / 调系统时的决定和过程
        case engineering
        /// 当下的状态、一次性的请求或念头
        case momentary
        /// 哄人、安慰时说的话被记成承诺
        case comfort
        /// 戏里 / 角色扮演里的设定和动作被当成现实
        case roleplay
        /// 脱离原文看不懂在说什么
        case unclear
        /// 气话、玩笑被当真，或者把谁说的 / 谁的事记错了
        case misattributed
        /// 原文没说，或者说的是相反的
        case unsupported

        public var label: String {
            switch self {
            case .ok: return "可用"
            case .engineering: return "工程内容"
            case .momentary: return "当下状态"
            case .comfort: return "安慰话当承诺"
            case .roleplay: return "剧场当事实"
            case .unclear: return "看不懂"
            case .misattributed: return "气话 / 归因错"
            case .unsupported: return "和原文对不上"
            }
        }
    }

    public enum Relation: String, Codable, Sendable {
        /// 和此前某张说的是同一个事实，只是换了说法
        case duplicate
        /// 和此前某张是同一件事的另一面，本该写在一起
        case sameTopic = "same_topic"
    }

    public struct Judgment: Codable, Equatable, Sendable {
        public let id: String
        public let verdict: Verdict
        public let relation: Relation?
        /// relation 指向的那张卡的编号
        public let of: String?
        public let why: String?

        public init(id: String, verdict: Verdict, relation: Relation? = nil, of: String? = nil, why: String? = nil) {
            self.id = id
            self.verdict = verdict
            self.relation = relation
            self.of = of
            self.why = why
        }
    }

    public static let batchSize = 40

    // MARK: - 提示词

    public static func systemPrompt(names: MemoryExtractor.Names) -> String {
        """
        你在审一份长期档案。档案的主人是\(names.user)；\(names.char)是陪她聊天的那一位。档案里每一张卡，是另一个模型从他们的对话里记下来的。

        这份档案的用处：过一个月，\(names.char)翻到某张卡，不看原来的对话，就能知道关于\(names.user)（或者她在意的人和东西）的一件确定的事，并且用得上。所以一张好卡是一个**过了那段对话还成立的事实**，自己读得懂。

        下面给你两样东西：「此前已有的卡」和「这一批要判的卡」。要判的每张卡都带着它的出处原文。请你对着原文，一张一张判。

        verdict 从这八个里选一个：
        - ok：过了那段对话还成立的事实，读它不用翻原文。
        - engineering：做 app、写代码、调系统时的决定和过程（「同意某个方案」「定下某个参数」），不是关于她这个人的事。
        - momentary：当下的状态、一次性的请求或念头（「当时有点困」「想让对方讲某件事」）。
        - comfort：安慰、哄人时说的话被记成了承诺（「承诺不会离开」「承诺明天还在」）。带着具体动作和日子的约定不算这一类，算 ok。
        - roleplay：戏里、角色扮演里的设定和动作被当成了现实。两个人长期共用的称呼和设定如果原文显示是真的日常，不算这一类。
        - unclear：脱离原文看不懂（「不喜欢对方说的某句话」，哪句没写）。
        - misattributed：气话、玩笑被当真；或者把谁说的、谁的事记错了。
        - unsupported：原文里没有这回事，或者原文说的是相反的。

        另外判 relation（没有就不写）：
        - duplicate：和「此前已有的卡」或这一批里更早的某张，说的是同一个事实，只是换了说法。
        - same_topic：和某张是同一件事的另一面，本该写成一张（同一只猫的来历被拆成好几张那种）。
        有 relation 就在 of 里写那张卡的编号。

        难过、痛苦、想死这类话，如果是她真实说出的处境，是 ok，不要因为沉重就判成别的。

        只输出一个 JSON 对象，不要别的字：
        {"judgments":[{"id":"12","verdict":"ok"},{"id":"13","verdict":"momentary","why":"只是那一刻困"},{"id":"14","verdict":"ok","relation":"duplicate","of":"7"}]}
        这一批的每张卡都要有一条，id 照抄。why 一句话，ok 的可以不写。
        """
    }

    public static func userContent(batch: [Card], prior: [Prior]) -> String {
        var out = "此前已有的卡（只用来判 relation）：\n"
        out += prior.isEmpty ? "（没有）\n" : prior.map { "[\($0.id)] \($0.content)" }.joined(separator: "\n") + "\n"
        out += "\n这一批要判的卡：\n\n"
        out += batch.map { card in
            var head = "[\(card.id)] \(card.content)"
            let meta = [card.subject.map { "主题：\($0)" }, card.speaker.map { "来源：\($0)" }, "类别：\(card.category)"]
                .compactMap { $0 }.joined(separator: " · ")
            head += "\n（\(meta)）"
            return head + "\n出处原文：\n" + (card.source.isEmpty ? "（找不到出处）" : card.source)
        }.joined(separator: "\n\n———\n\n")
        return out
    }

    // MARK: - 解析

    private struct Envelope: Decodable {
        let judgments: [Loose]
    }

    /// verdict / relation 写了不认识的值时：verdict 不认识整条作废，relation 不认识当没写
    private struct Loose: Decodable {
        let value: Judgment?

        init(from decoder: Decoder) throws {
            enum Keys: String, CodingKey { case id, verdict, relation, of, why }
            guard let c = try? decoder.container(keyedBy: Keys.self) else { value = nil; return }
            let id = (try? c.decode(String.self, forKey: .id)) ?? (try? c.decode(Int.self, forKey: .id)).map(String.init)
            guard let id, let raw = try? c.decode(String.self, forKey: .verdict), let verdict = Verdict(rawValue: raw) else {
                value = nil
                return
            }
            let relation = (try? c.decode(String.self, forKey: .relation)).flatMap(Relation.init(rawValue:))
            let of = (try? c.decode(String.self, forKey: .of)) ?? (try? c.decode(Int.self, forKey: .of)).map(String.init)
            value = Judgment(id: id, verdict: verdict, relation: of == nil ? nil : relation, of: relation == nil ? nil : of,
                             why: try? c.decode(String.self, forKey: .why))
        }
    }

    /// 这一批每张卡正好一条才算数；缺的 / 多的 / 重的都算整批不合格（nil，调用方重判一次）
    public static func parse(_ raw: String, expecting ids: [String]) -> [Judgment]? {
        guard let text = FragmentPool.strictObjectText(raw), let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        let got = envelope.judgments.compactMap(\.value)
        guard got.count == ids.count, Set(got.map(\.id)) == Set(ids) else { return nil }
        let byId = Dictionary(got.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    /// 判一批：解析不过带着提醒重判一次，还不过抛错
    public static func judge(batch: [Card], prior: [Prior], names: MemoryExtractor.Names,
                             caller: SessionSegmentWriter.Caller) async throws -> [Judgment] {
        guard !batch.isEmpty else { return [] }
        let system = systemPrompt(names: names)
        let user = userContent(batch: batch, prior: prior)
        let ids = batch.map(\.id)
        guard let raw = try await caller(system, user) else { throw MemoryWriterError.format("裁判没回内容") }
        if let parsed = parse(raw, expecting: ids) { return parsed }
        let note = "\n\n（上一次交的不合格：必须只输出一个 JSON 对象，这一批 \(ids.count) 张卡每张正好一条，id 照抄。重交。）"
        guard let retry = try await caller(system, user + note), let parsed = parse(retry, expecting: ids) else {
            throw MemoryWriterError.format("裁判两次都没交出合格的判断")
        }
        return parsed
    }

    // MARK: - 统计

    public struct Tally: Codable, Equatable, Sendable {
        public var total = 0
        public var byVerdict: [String: Int] = [:]
        public var duplicates = 0
        public var sameTopic = 0

        public init() {}

        public var unsatisfied: Int { total - (byVerdict[Verdict.ok.rawValue] ?? 0) }
        /// 0…1；没有卡 = nil
        public var unsatisfiedRate: Double? { total > 0 ? Double(unsatisfied) / Double(total) : nil }
        public var duplicateRate: Double? { total > 0 ? Double(duplicates) / Double(total) : nil }
        public var sameTopicRate: Double? { total > 0 ? Double(sameTopic) / Double(total) : nil }
    }

    public static func tally(_ judgments: [Judgment]) -> Tally {
        var t = Tally()
        t.total = judgments.count
        for j in judgments {
            t.byVerdict[j.verdict.rawValue, default: 0] += 1
            switch j.relation {
            case .duplicate: t.duplicates += 1
            case .sameTopic: t.sameTopic += 1
            case nil: break
            }
        }
        return t
    }
}
