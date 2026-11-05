import Foundation
import CryptoKit

// MARK: - 试写台的数据（plan-memory-audit-home-trial 3.1 / 3.2）
// 全部 Codable、带 schema，存成 JSON：界面读、以后自动跑 / 自动改配方的程序也读同一份。

enum MemoryBench {
    static let schema = 1

    /// 时间一律存「1970 起的整毫秒」（整数，哪种语言都好读）。ISO8601 只到秒，读回来和内存里那份不相等（zd2 live 实锤）；
    /// 所以试写台自己产生的时间都先过 `stamp` 截到整毫秒，存 → 读逐位相同
    static func stamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func now() -> Date { stamp(Date()) }

    private static func encodeDate(_ date: Date, _ encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    private static func decodeDate(_ decoder: Decoder) throws -> Date {
        Date(timeIntervalSince1970: Double(try decoder.singleValueContainer().decode(Int64.self)) / 1000)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom(encodeDate)
        return e
    }()

    /// 一行一条（requests.jsonl / 内容哈希）：不换行
    static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom(encodeDate)
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom(decodeDate)
        return d
    }()

    /// 测试集的版本：只哈希用例 id + 输入（标签会因为判断回流不断变多，不能因此断掉历次对比）
    static func revision(_ cases: [MemoryBenchCase]) -> String {
        struct Key: Encodable {
            let id: String
            let input: MemoryBenchJSON
        }
        return digest((try? lineEncoder.encode(cases.map { Key(id: $0.id, input: $0.input) })) ?? Data())
    }

    /// SHA-256 前 16 位十六进制
    static func digest(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

/// 任意 JSON：用例的输入、配方的管线参数都是写手自己的形状，存成通用 JSON，各写手自己解
enum MemoryBenchJSON: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MemoryBenchJSON])
    case object([String: MemoryBenchJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([MemoryBenchJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: MemoryBenchJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// 写手自己的类型 → 通用 JSON
    static func from<T: Encodable>(_ value: T) throws -> MemoryBenchJSON {
        try MemoryBench.decoder.decode(MemoryBenchJSON.self, from: MemoryBench.lineEncoder.encode(value))
    }

    /// 通用 JSON → 写手自己的类型
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try MemoryBench.decoder.decode(type, from: MemoryBench.lineEncoder.encode(self))
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

// MARK: - 测试集

/// 答案的一条：该有的 / 不该有的 / 要点…（种类按写手定，C2 = 应记 / 不该记）。keys = 自动配用的关键词
struct MemoryBenchLabel: Codable, Equatable, Sendable, Identifiable {
    static let shouldHave = "应记"
    static let shouldNotHave = "不该记"

    var id: String
    var kind: String
    var text: String
    var keys: [String]
    /// 哪来的：探针预期 / 人判 10-23 / 整理台删除…
    var from: String
}

/// 一个用例：冻结的输入 + 它的标签
struct MemoryBenchCase: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var input: MemoryBenchJSON
    var labels: [MemoryBenchLabel]
    var note: String?
}

/// 一份考卷
struct MemoryBenchSet: Codable, Equatable, Sendable, Identifiable {
    enum Source: String, Codable, Sendable {
        /// 随 app 走的（只放编造数据，只读）
        case builtin
        /// 她在这层楼建的
        case floor
        case imported
    }

    var schema = MemoryBench.schema
    var id: String
    var name: String
    var writer: String
    var source: Source
    var note: String?
    var createdAt: Date?
    var cases: [MemoryBenchCase]

    var revision: String { MemoryBench.revision(cases) }
}

// MARK: - 配方（被测对象里能改的那部分）

/// 一个版本：system / user 两份模板 + 管线参数 + 用哪套检查。parent = 从哪版改来的（以后画进化树）
struct MemoryBenchRecipe: Codable, Equatable, Sendable, Identifiable {
    var schema = MemoryBench.schema
    var id: String
    var writer: String
    var name: String
    var parent: String?
    var system: String
    var user: String
    var params: [String: MemoryBenchJSON]
    /// 检查规则：current（现行格式）/ a-line（A 线新格式）/ none
    var checks: String
    var builtIn: Bool
    var savedAt: Date?
}

/// 一个写手在这层楼存的版本 + 正在用的那份（正在用接正式写手是段 ④）
struct MemoryBenchRecipeBook: Codable, Equatable, Sendable {
    static let maxVersions = 50

    var schema = MemoryBench.schema
    var writer: String
    var active: MemoryBenchRecipe?
    var versions: [MemoryBenchRecipe]
}

// MARK: - 一次跑

struct MemoryBenchModelRef: Codable, Hashable, Sendable, Identifiable {
    var credentialId: String
    var modelId: String
    var name: String
    /// 本机模型（credentialId 空）
    var local: Bool

    var id: String { local ? "local:\(modelId)" : "\(credentialId)/\(modelId)" }

    init(credentialId: String, modelId: String, name: String, local: Bool = false) {
        self.credentialId = credentialId
        self.modelId = modelId
        self.name = name
        self.local = local
    }

    init(_ model: ProviderModel) {
        self.init(credentialId: model.credentialId, modelId: model.modelId, name: model.name)
    }
}

/// 解析出的一条（C2 = 一张卡；A 线 = 一块）
struct MemoryBenchItem: Codable, Equatable, Sendable {
    var index: Int
    var text: String
    var fields: [String: String]
}

struct MemoryBenchCheck: Codable, Equatable, Sendable {
    var name: String
    var passed: Bool
    var hard: Bool
    var detail: String?
}

/// token 数。source：measured = 回包报的完整用量；estimated = 不完整（流式快照之类）。回包没报用量 = 整个记 nil（未知），不记成 0
struct MemoryBenchUsage: Codable, Equatable, Sendable {
    static let measured = "measured"
    static let estimated = "estimated"

    var input: Int
    var output: Int
    var source: String = measured
}

/// 钱从哪来：measured = 回包报的 / 按价目表算的；estimated = 账本按估算记的；unpriced = 价目表里没有这个模型（金额未知，记 nil）
enum MemoryBenchCostSource: String, Codable, Sendable {
    case measured, estimated, unpriced
}

/// 一格 = 一个用例 × 一个配方 × 一个模型
struct MemoryBenchCell: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var caseId: String
    var recipeId: String
    var modelId: String
    /// 原始输出（30 天后和完整日志一起清，条目 / 检查 / 判断 / 分数留着）
    var output: String?
    var items: [MemoryBenchItem]
    var checks: [MemoryBenchCheck]
    var usage: MemoryBenchUsage?
    /// nil = 金额未知（没调成 / 没报用量 / 未计价），不是 $0
    var usd: Double?
    var costSource: MemoryBenchCostSource?
    var ms: Int
    var error: String?
}

enum MemoryBenchVerdict: String, Codable, Sendable, CaseIterable {
    case right = "对"
    case wrong = "错"
    case weak = "偏弱"
}

enum MemoryBenchJudge: String, Codable, Sendable {
    case human = "她"
    case auto = "自动配"
}

/// 对一格里一条的判断。item = nil 表示判整格（A4 这类「能不能用」）
struct MemoryBenchJudgment: Codable, Equatable, Sendable {
    var cellId: String
    var item: Int?
    var verdict: MemoryBenchVerdict
    var labelId: String?
    var by: MemoryBenchJudge
    var at: Date
    var note: String?
}

/// 一个打分器给一个「配方 × 模型」打的分
struct MemoryBenchScore: Codable, Equatable, Sendable {
    var scorer: String
    var version: Int
    var recipeId: String
    var modelId: String
    var main: Double?
    var mainName: String
    var parts: [String: Double]
}

struct MemoryBenchRun: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        /// interrupted = 跑到一半 app 没了（启动时把遗留的 running 改成它，已完成的格子留着）
        case running, done, cancelled, failed, interrupted
    }

    struct SetRef: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var revision: String
    }

    var schema = MemoryBench.schema
    var id: String
    var writer: String
    var at: Date
    var finishedAt: Date?
    var status: Status
    var set: SetRef
    /// 跑的时候的配方快照（不存引用：版本后来改了，老的跑照样能看、能重算）
    var recipes: [MemoryBenchRecipe]
    var models: [MemoryBenchModelRef]
    var caseIds: [String]
    var cells: [MemoryBenchCell]
    var judgments: [MemoryBenchJudgment]
    var scores: [MemoryBenchScore]
    /// 钉住的不清完整日志
    var pinned: Bool
    var note: String?
    /// 30 天清理清过原始输出的时间（没清 = nil）
    var outputsPrunedAt: Date? = nil

    /// 每条最后算数的判断：她判的压过自动配的，同一方里后判的压过先判的
    func effectiveJudgments() -> [MemoryBenchJudgment] {
        var best: [String: MemoryBenchJudgment] = [:]
        for j in judgments {
            let key = "\(j.cellId)#\(j.item.map(String.init) ?? "*")"
            guard let old = best[key] else {
                best[key] = j
                continue
            }
            if old.by == .auto && j.by == .human { best[key] = j }
            else if old.by == j.by && j.at >= old.at { best[key] = j }
        }
        return Array(best.values)
    }

    /// 已知金额相加（未知的不当 0 算，见 `unpricedCells`）
    var totalUSD: Double { cells.compactMap(\.usd).reduce(0, +) }
    /// 调成了但金额未知的格子
    var unpricedCells: Int { cells.filter { $0.output != nil && $0.usd == nil }.count }
}

/// requests.jsonl 的一行：这一格送了什么、回了什么
struct MemoryBenchRequest: Codable, Equatable, Sendable {
    var cellId: String
    var at: Date
    var model: String
    var system: String
    var user: String
    var response: String?
    var error: String?
    var usage: MemoryBenchUsage?
    var usd: Double?
    var costSource: MemoryBenchCostSource?
    var ms: Int
}
