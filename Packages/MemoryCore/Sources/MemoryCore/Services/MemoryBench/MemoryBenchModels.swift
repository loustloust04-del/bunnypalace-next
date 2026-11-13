import Foundation
import CryptoKit

// MARK: - 试写台的数据（plan-memory-audit-home-trial 3.1 / 3.2）
// 全部 Codable、带 schema，存成 JSON：界面读、以后自动跑 / 自动改配方的程序也读同一份。

public enum MemoryBench {}

public extension MemoryBench {
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
public enum MemoryBenchJSON: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MemoryBenchJSON])
    case object([String: MemoryBenchJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([MemoryBenchJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: MemoryBenchJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
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
    public static func from<T: Encodable>(_ value: T) throws -> MemoryBenchJSON {
        try MemoryBench.decoder.decode(MemoryBenchJSON.self, from: MemoryBench.lineEncoder.encode(value))
    }

    /// 通用 JSON → 写手自己的类型
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try MemoryBench.decoder.decode(type, from: MemoryBench.lineEncoder.encode(self))
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

// MARK: - 测试集

/// 答案的一条：该有的 / 不该有的 / 要点…（种类按写手定，C2 = 应记 / 不该记）。keys = 自动配用的关键词
public struct MemoryBenchLabel: Codable, Equatable, Sendable, Identifiable {
    public static let shouldHave = "应记"
    public static let shouldNotHave = "不该记"

    public var id: String
    public var kind: String
    public var text: String
    public var keys: [String]
    /// 哪来的：探针预期 / 人判 10-23 / 整理台删除…
    public var from: String

    public init(id: String, kind: String, text: String, keys: [String], from: String) {
        self.id = id
        self.kind = kind
        self.text = text
        self.keys = keys
        self.from = from
    }
}

/// 一个用例：冻结的输入 + 它的标签
public struct MemoryBenchCase: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var input: MemoryBenchJSON
    public var labels: [MemoryBenchLabel]
    public var note: String?

    public init(id: String, title: String, input: MemoryBenchJSON, labels: [MemoryBenchLabel], note: String? = nil) {
        self.id = id
        self.title = title
        self.input = input
        self.labels = labels
        self.note = note
    }
}

/// 一份考卷
public struct MemoryBenchSet: Codable, Equatable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable {
        /// 随 app 走的（只放编造数据，只读）
        case builtin
        /// 她在这层楼建的
        case floor
        case imported
    }

    public var schema = MemoryBench.schema
    public var id: String
    public var name: String
    public var writer: String
    public var source: Source
    public var note: String?
    public var createdAt: Date?
    public var cases: [MemoryBenchCase]

    public var revision: String { MemoryBench.revision(cases) }

    public init(schema: Int = MemoryBench.schema, id: String, name: String, writer: String, source: Source,
                note: String? = nil, createdAt: Date? = nil, cases: [MemoryBenchCase]) {
        self.schema = schema
        self.id = id
        self.name = name
        self.writer = writer
        self.source = source
        self.note = note
        self.createdAt = createdAt
        self.cases = cases
    }
}

// MARK: - 配方（被测对象里能改的那部分）

/// 一个版本：system / user 两份模板 + 管线参数 + 用哪套检查。parent = 从哪版改来的（以后画进化树）
public struct MemoryBenchRecipe: Codable, Equatable, Sendable, Identifiable {
    public var schema = MemoryBench.schema
    public var id: String
    public var writer: String
    public var name: String
    public var parent: String?
    public var system: String
    public var user: String
    public var params: [String: MemoryBenchJSON]
    /// 检查规则：current（现行格式）/ a-line（A 线新格式）/ none
    public var checks: String
    public var builtIn: Bool
    public var savedAt: Date?

    public init(schema: Int = MemoryBench.schema, id: String, writer: String, name: String, parent: String? = nil,
                system: String, user: String, params: [String: MemoryBenchJSON], checks: String, builtIn: Bool, savedAt: Date? = nil) {
        self.schema = schema
        self.id = id
        self.writer = writer
        self.name = name
        self.parent = parent
        self.system = system
        self.user = user
        self.params = params
        self.checks = checks
        self.builtIn = builtIn
        self.savedAt = savedAt
    }
}

/// 一个写手在这层楼存的版本 + 正在用的那份（正在用接正式写手是段 ④）
public struct MemoryBenchRecipeBook: Codable, Equatable, Sendable {
    public static let maxVersions = 50

    public var schema = MemoryBench.schema
    public var writer: String
    public var active: MemoryBenchRecipe?
    public var versions: [MemoryBenchRecipe]

    public init(schema: Int = MemoryBench.schema, writer: String, active: MemoryBenchRecipe? = nil, versions: [MemoryBenchRecipe]) {
        self.schema = schema
        self.writer = writer
        self.active = active
        self.versions = versions
    }
}

// MARK: - 一次跑

public struct MemoryBenchModelRef: Codable, Hashable, Sendable, Identifiable {
    public var credentialId: String
    public var modelId: String
    public var name: String
    /// 本机模型（credentialId 空）
    public var local: Bool

    public var id: String { local ? "local:\(modelId)" : "\(credentialId)/\(modelId)" }

    public init(credentialId: String, modelId: String, name: String, local: Bool = false) {
        self.credentialId = credentialId
        self.modelId = modelId
        self.name = name
        self.local = local
    }

}

/// 解析出的一条（C2 = 一张卡；A 线 = 一块）
public struct MemoryBenchItem: Codable, Equatable, Sendable {
    public var index: Int
    public var text: String
    public var fields: [String: String]

    public init(index: Int, text: String, fields: [String: String]) {
        self.index = index
        self.text = text
        self.fields = fields
    }
}

public struct MemoryBenchCheck: Codable, Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var hard: Bool
    public var detail: String?

    public init(name: String, passed: Bool, hard: Bool, detail: String? = nil) {
        self.name = name
        self.passed = passed
        self.hard = hard
        self.detail = detail
    }
}

/// token 数。source：measured = 回包报的完整用量；estimated = 不完整（流式快照之类）。回包没报用量 = 整个记 nil（未知），不记成 0
public struct MemoryBenchUsage: Codable, Equatable, Sendable {
    public static let measured = "measured"
    public static let estimated = "estimated"

    public var input: Int
    public var output: Int
    public var source: String = measured

    public init(input: Int, output: Int, source: String = measured) {
        self.input = input
        self.output = output
        self.source = source
    }
}

/// 钱从哪来：measured = 回包报的 / 按价目表算的；estimated = 账本按估算记的；unpriced = 价目表里没有这个模型（金额未知，记 nil）
public enum MemoryBenchCostSource: String, Codable, Sendable {
    case measured, estimated, unpriced
}

/// 一格 = 一个用例 × 一个配方 × 一个模型
public struct MemoryBenchCell: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var caseId: String
    public var recipeId: String
    public var modelId: String
    /// 原始输出（30 天后和完整日志一起清，条目 / 检查 / 判断 / 分数留着）
    public var output: String?
    public var items: [MemoryBenchItem]
    public var checks: [MemoryBenchCheck]
    public var usage: MemoryBenchUsage?
    /// nil = 金额未知（没调成 / 没报用量 / 未计价），不是 $0
    public var usd: Double?
    public var costSource: MemoryBenchCostSource?
    public var ms: Int
    public var error: String?

    public init(id: String, caseId: String, recipeId: String, modelId: String, output: String? = nil, items: [MemoryBenchItem],
                checks: [MemoryBenchCheck], usage: MemoryBenchUsage? = nil, usd: Double? = nil, costSource: MemoryBenchCostSource? = nil,
                ms: Int, error: String? = nil) {
        self.id = id
        self.caseId = caseId
        self.recipeId = recipeId
        self.modelId = modelId
        self.output = output
        self.items = items
        self.checks = checks
        self.usage = usage
        self.usd = usd
        self.costSource = costSource
        self.ms = ms
        self.error = error
    }
}

public enum MemoryBenchVerdict: String, Codable, Sendable, CaseIterable {
    case right = "对"
    case wrong = "错"
    case weak = "偏弱"
}

public enum MemoryBenchJudge: String, Codable, Sendable {
    case human = "她"
    case auto = "自动配"
}

/// 对一格里一条的判断。item = nil 表示判整格（A4 这类「能不能用」）
public struct MemoryBenchJudgment: Codable, Equatable, Sendable {
    public var cellId: String
    public var item: Int?
    public var verdict: MemoryBenchVerdict
    public var labelId: String?
    public var by: MemoryBenchJudge
    public var at: Date
    public var note: String?

    public init(cellId: String, item: Int? = nil, verdict: MemoryBenchVerdict, labelId: String? = nil, by: MemoryBenchJudge, at: Date, note: String? = nil) {
        self.cellId = cellId
        self.item = item
        self.verdict = verdict
        self.labelId = labelId
        self.by = by
        self.at = at
        self.note = note
    }
}

/// 一个打分器给一个「配方 × 模型」打的分
public struct MemoryBenchScore: Codable, Equatable, Sendable {
    public var scorer: String
    public var version: Int
    public var recipeId: String
    public var modelId: String
    public var main: Double?
    public var mainName: String
    public var parts: [String: Double]

    public init(scorer: String, version: Int, recipeId: String, modelId: String, main: Double?, mainName: String, parts: [String: Double]) {
        self.scorer = scorer
        self.version = version
        self.recipeId = recipeId
        self.modelId = modelId
        self.main = main
        self.mainName = mainName
        self.parts = parts
    }
}

public struct MemoryBenchRun: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// interrupted = 跑到一半 app 没了（启动时把遗留的 running 改成它，已完成的格子留着）
        case running, done, cancelled, failed, interrupted
    }

    public struct SetRef: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var revision: String

        public init(id: String, name: String, revision: String) {
            self.id = id
            self.name = name
            self.revision = revision
        }
    }

    public var schema = MemoryBench.schema
    public var id: String
    public var writer: String
    public var at: Date
    public var finishedAt: Date?
    public var status: Status
    public var set: SetRef
    /// 跑的时候的配方快照（不存引用：版本后来改了，老的跑照样能看、能重算）
    public var recipes: [MemoryBenchRecipe]
    public var models: [MemoryBenchModelRef]
    public var caseIds: [String]
    public var cells: [MemoryBenchCell]
    public var judgments: [MemoryBenchJudgment]
    public var scores: [MemoryBenchScore]
    /// 钉住的不清完整日志
    public var pinned: Bool
    public var note: String?
    /// 30 天清理清过原始输出的时间（没清 = nil）
    public var outputsPrunedAt: Date? = nil

    public init(schema: Int = MemoryBench.schema, id: String, writer: String, at: Date, finishedAt: Date? = nil,
                status: Status, set: SetRef, recipes: [MemoryBenchRecipe], models: [MemoryBenchModelRef], caseIds: [String],
                cells: [MemoryBenchCell], judgments: [MemoryBenchJudgment], scores: [MemoryBenchScore], pinned: Bool,
                note: String? = nil, outputsPrunedAt: Date? = nil) {
        self.schema = schema
        self.id = id
        self.writer = writer
        self.at = at
        self.finishedAt = finishedAt
        self.status = status
        self.set = set
        self.recipes = recipes
        self.models = models
        self.caseIds = caseIds
        self.cells = cells
        self.judgments = judgments
        self.scores = scores
        self.pinned = pinned
        self.note = note
        self.outputsPrunedAt = outputsPrunedAt
    }

    /// 每条最后算数的判断：她判的压过自动配的，同一方里后判的压过先判的
    public func effectiveJudgments() -> [MemoryBenchJudgment] {
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
    public var totalUSD: Double { cells.compactMap(\.usd).reduce(0, +) }
    /// 调成了但金额未知的格子
    public var unpricedCells: Int { cells.filter { $0.output != nil && $0.usd == nil }.count }
}

/// requests.jsonl 的一行：这一格送了什么、回了什么
public struct MemoryBenchRequest: Codable, Equatable, Sendable {
    public var cellId: String
    public var at: Date
    public var model: String
    public var system: String
    public var user: String
    public var response: String?
    public var error: String?
    public var usage: MemoryBenchUsage?
    public var usd: Double?
    public var costSource: MemoryBenchCostSource?
    public var ms: Int

    public init(cellId: String, at: Date, model: String, system: String, user: String, response: String? = nil, error: String? = nil,
                usage: MemoryBenchUsage? = nil, usd: Double? = nil, costSource: MemoryBenchCostSource? = nil, ms: Int) {
        self.cellId = cellId
        self.at = at
        self.model = model
        self.system = system
        self.user = user
        self.response = response
        self.error = error
        self.usage = usage
        self.usd = usd
        self.costSource = costSource
        self.ms = ms
    }
}
