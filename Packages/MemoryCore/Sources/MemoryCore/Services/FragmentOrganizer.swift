import Foundation

/// C2 整理（plan-c2-write-shape §0.6）：原来要她在整理台一张张点「留」的那一步，改成后台对着出处原文下结论。
/// 有把握的自动处理，拿不准的才留给她。一次调用、不带工具，该看的由调用方找好喂进来，便宜模型也得做得了。
/// 这里只有提示词、解析（纯函数）和「判一批」；落库 / 触发在调用方
public enum FragmentOrganizer {
    /// 一张还没看过的卡。source = 出处那条原文连同前面一两条
    public struct Card: Equatable, Sendable {
        public let id: String
        public let content: String
        public let subject: String?
        public let source: String

        public init(id: String, content: String, subject: String? = nil, source: String) {
            self.id = id
            self.content = content
            self.subject = subject
            self.source = source
        }
    }

    /// 已经在档案里的卡（已留的，或这一批之前处理过的）
    public struct Known: Equatable, Sendable {
        public let id: String
        public let content: String

        public init(id: String, content: String) {
            self.id = id
            self.content = content
        }
    }

    public enum Action: String, Codable, CaseIterable, Sendable {
        /// 原文确有其事、过了这段还成立、档案里还没有
        case keep
        /// 不该进档案：当下状态 / 经过 / 戏里的 / 原文没这么说
        case drop
        /// 和档案里某张是同一件事：并进那张（into = 那张的编号，content = 并好之后的整句）
        case merge
        /// 事是真的但写得不对或不全：改对再留（content = 改好的整句）
        case fix
        /// 拿不准，留给她
        case unsure

        public var label: String {
            switch self {
            case .keep: return "留"
            case .drop: return "删"
            case .merge: return "并"
            case .fix: return "改"
            case .unsure: return "拿不准"
            }
        }
    }

    public struct Decision: Codable, Equatable, Sendable {
        public let id: String
        public let action: Action
        public let into: String?
        public let content: String?
        public let why: String?

        public init(id: String, action: Action, into: String? = nil, content: String? = nil, why: String? = nil) {
            self.id = id
            self.action = action
            self.into = into
            self.content = content
            self.why = why
        }
    }

    public static let batchSize = 20
    public static let maxContentChars = 200

    /// 提示词两版（plan §3.2：数字决定用哪版）
    public enum Variant: String, Sendable {
        /// 只说这份档案拿来干什么，不列清单
        case purpose
        /// 在上面基础上加最少的几条界线
        case rules
    }

    // MARK: - 提示词

    static let ruleBlock = """

        几条容易判错的界线：
        - 这份档案记的是人，不是工程。做 app、写代码、调系统、定方案时的决定和过程（「同意某个方案」「定下某个参数」「希望某个页面怎么显示」）一律 drop，哪怕它说得很确定。她为什么做这件事、这件事对她意味着什么，才是关于她的。
        - 「当时」怎么样（困、冷、想哭、还没睡）是那一刻的状态，drop。反复出现、她自己说成是常态的才留。
        - 哄人、安慰时说的「不会离开」「明天还在」「会陪着」不是约定，drop。带着具体要做的事或日子的才留。
        - 你自己判不了的（戏里还是戏外、是气话还是真话、原文到底说没说），用 unsure，不要硬选。
        """

    public static func systemPrompt(names: MemoryExtractor.Names, variant: Variant = .purpose) -> String {
        base(names: names).replacingOccurrences(of: "\n\n难过、痛苦这类话", with: (variant == .rules ? ruleBlock : "") + "\n\n难过、痛苦这类话")
    }

    private static func base(names: MemoryExtractor.Names) -> String {
        """
        你在整理一份长期档案。档案的主人是\(names.user)；\(names.char)是陪她聊天的那一位。

        这份档案的用处：过一个月，\(names.char)翻到其中一张卡，不看原来的对话，就能知道关于\(names.user)（或者她在意的人和东西）的一件确定的事，并且用得上。它是活的档案：同一件事只有一张卡，有了新进展就改那张，不另起一张。

        下面有两样东西：「档案里已经有的卡」和「新来的卡」。新来的每张卡带着它的出处原文——**原文是事实，卡要向原文对齐**。请你一张一张决定它该怎么办，action 五选一：

        - keep：原文确实是这么回事，过了这段对话还成立，档案里还没有。原样留下。
        - drop：不该进档案。过了那一刻就不成立的（当时的状态、一次性的请求）、只是在讲经过的（谁同意了什么、今天做到哪一步）、戏里演的、哄人时顺口说的、原文其实没这么说的，都不留。
        - merge：和档案里已经有的某张说的是同一件事。into 写那张的编号，content 写并好之后的一整句（把两边的信息合在一起，不丢东西）。
        - fix：事是真的，但这张卡写得不对或者读不懂（主语错了、缺了关键的词、把谁说的记反了）。content 写改好的一整句。
        - unsure：你拿不准。宁可交给\(names.user)自己看，也不要猜。

        难过、痛苦这类话，如果是她真实说出的处境，是事实，不要因为沉重就 drop。

        只输出一个 JSON 对象，不要别的字：
        {"decisions":[{"id":"12","action":"keep"},{"id":"13","action":"drop","why":"只是那一刻困"},{"id":"14","action":"merge","into":"7","content":"……"},{"id":"15","action":"fix","content":"……"},{"id":"16","action":"unsure","why":"……"}]}
        新来的每张卡都要有一条，id 照抄。why 一句话，keep 可以不写。content 不超过 \(maxContentChars) 字，主语写名字，不用「我」「你」。
        """
    }

    public static func userContent(batch: [Card], known: [Known]) -> String {
        var out = "档案里已经有的卡：\n"
        out += known.isEmpty ? "（还没有）\n" : known.map { "[\($0.id)] \($0.content)" }.joined(separator: "\n") + "\n"
        out += "\n新来的卡：\n\n"
        out += batch.map { card in
            "[\(card.id)] \(card.content)" + (card.subject.map { "\n（主题：\($0)）" } ?? "")
                + "\n出处原文：\n" + (card.source.isEmpty ? "（找不到出处）" : card.source)
        }.joined(separator: "\n\n———\n\n")
        return out
    }

    // MARK: - 解析

    private struct Envelope: Decodable {
        let decisions: [Loose]
    }

    private struct Loose: Decodable {
        let id: String?
        let action: String?
        let into: String?
        let content: String?
        let why: String?

        init(from decoder: Decoder) throws {
            enum Keys: String, CodingKey { case id, action, into, content, why }
            let c = try decoder.container(keyedBy: Keys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? (try? c.decode(Int.self, forKey: .id)).map(String.init)
            action = try? c.decode(String.self, forKey: .action)
            into = (try? c.decode(String.self, forKey: .into)) ?? (try? c.decode(Int.self, forKey: .into)).map(String.init)
            content = try? c.decode(String.self, forKey: .content)
            why = try? c.decode(String.self, forKey: .why)
        }
    }

    /// 这一批每张卡正好一条才算数（否则 nil，调用方重判一次）。单条不合规矩的不连累整批，降成 unsure 并写明原因：
    /// action 不认识、merge 的 into 不在已有的卡里（或指向自己）、merge / fix 没给 content 或超长
    public static func parse(_ raw: String, expecting ids: [String], known: Set<String>) -> [Decision]? {
        guard let text = FragmentPool.strictObjectText(raw), let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        let rows = envelope.decisions.filter { $0.id != nil }
        guard rows.count == ids.count, Set(rows.compactMap(\.id)) == Set(ids) else { return nil }
        var byId: [String: Decision] = [:]
        for row in rows {
            guard let id = row.id else { continue }
            let content = row.content?.trimmingCharacters(in: .whitespacesAndNewlines)
            func unsure(_ reason: String) -> Decision { Decision(id: id, action: .unsure, why: reason) }
            guard let action = row.action.flatMap(Action.init(rawValue:)) else {
                byId[id] = unsure("模型给的处理方式看不懂")
                continue
            }
            switch action {
            case .keep, .drop, .unsure:
                byId[id] = Decision(id: id, action: action, why: row.why)
            case .merge:
                guard let into = row.into, into != id, known.contains(into) || ids.contains(into) else {
                    byId[id] = unsure("要并进去的那张不在档案里")
                    continue
                }
                guard let content, !content.isEmpty, content.count <= maxContentChars else {
                    byId[id] = unsure("并的时候没写出合格的整句")
                    continue
                }
                byId[id] = Decision(id: id, action: .merge, into: into, content: content, why: row.why)
            case .fix:
                guard let content, !content.isEmpty, content.count <= maxContentChars else {
                    byId[id] = unsure("改的时候没写出合格的整句")
                    continue
                }
                byId[id] = Decision(id: id, action: .fix, content: content, why: row.why)
            }
        }
        return ids.compactMap { byId[$0] }
    }

    /// 判一批：整包不合格带着提醒重判一次；还不行这一批全部算 unsure（交给她，不猜）
    public static func organize(batch: [Card], known: [Known], names: MemoryExtractor.Names, variant: Variant = .purpose,
                                caller: SessionSegmentWriter.Caller) async throws -> [Decision] {
        guard !batch.isEmpty else { return [] }
        let system = systemPrompt(names: names, variant: variant)
        let user = userContent(batch: batch, known: known)
        let ids = batch.map(\.id)
        let knownIds = Set(known.map(\.id))
        if let raw = try await caller(system, user), let parsed = parse(raw, expecting: ids, known: knownIds) { return parsed }
        let note = "\n\n（上一次交的不合格：必须只输出一个 JSON 对象，新来的 \(ids.count) 张卡每张正好一条，id 照抄。重交。）"
        if let retry = try await caller(system, user + note), let parsed = parse(retry, expecting: ids, known: knownIds) { return parsed }
        return ids.map { Decision(id: $0, action: .unsure, why: "模型两次都没交出合格的结论") }
    }

    // MARK: - 统计

    public struct Tally: Codable, Equatable, Sendable {
        public var total = 0
        public var byAction: [String: Int] = [:]

        public init() {}

        public func count(_ action: Action) -> Int { byAction[action.rawValue] ?? 0 }
        /// 她还得自己看的比例
        public var unsureRate: Double? { total > 0 ? Double(count(.unsure)) / Double(total) : nil }
        /// 处理完档案里净增几张（keep + fix；merge 是并进已有的，不增）
        public var added: Int { count(.keep) + count(.fix) }
    }

    public static func tally(_ decisions: [Decision]) -> Tally {
        var t = Tally()
        t.total = decisions.count
        for d in decisions { t.byAction[d.action.rawValue, default: 0] += 1 }
        return t
    }
}
