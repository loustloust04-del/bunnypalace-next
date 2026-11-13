import Foundation

// MARK: - 写手接口（plan-memory-audit-home-trial 3.3）
// 试写台不认识 A2 / C2 / C3，只认这个接口。接一个新写手 = 写一个遵循它的类型 + 在 `MemoryBenchWriters.all` 加一行。

/// 怎么调模型：一次 system + user；多轮 + 只读工具（C3 整理用，接口先占位，这一刀不实现）
public enum MemoryBenchCallStyle: Equatable, Sendable {
    case single
    case agent
    case local
}

/// 模板里能用的一个变量（编辑框旁「能用的变量」就是它）
public struct MemoryBenchVariable: Equatable, Sendable {
    public let name: String
    public let note: String
    public let example: String

    public init(name: String, note: String, example: String) {
        self.name = name
        self.note = note
        self.example = example
    }
}

/// 渲染好、要送出去的一份
public struct MemoryBenchPrompt: Equatable, Sendable {
    public let system: String
    public let user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

/// 一格输出解析的结果：条目 + 检查（检查只辅助，不拦、不打分）
public struct MemoryBenchParsed: Equatable, Sendable {
    public var items: [MemoryBenchItem]
    public var checks: [MemoryBenchCheck]

    public init(items: [MemoryBenchItem], checks: [MemoryBenchCheck]) {
        self.items = items
        self.checks = checks
    }
}

public protocol MemoryBenchWriter: Sendable {
    /// 编号（c2 / a2…），同 `MemoryWriterID.rawValue`
    var id: String { get }
    var title: String { get }
    var callStyle: MemoryBenchCallStyle { get }
    /// 这个写手的标签有哪几种
    var labelKinds: [String] { get }
    var variableCatalog: [MemoryBenchVariable] { get }
    /// 挂几个打分器（⧫Q1：可插拔，这一刀都用占位的）
    var scorers: [any MemoryBenchScorer] { get }

    /// 内置配方：第一个永远是「现行」（渲染结果和正式写手逐字相同）
    func builtInRecipes(defaults: UserDefaults) -> [MemoryBenchRecipe]
    /// 用例的冻结材料 → 模板变量
    func variables(for testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) throws -> [String: MemoryBenchValue]
    /// 输出 → 条目 + 检查
    func parse(output: String, testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) -> MemoryBenchParsed
    /// 新输出的条目和已有标签对一对，配上的预填判断（她只确认）
    func autoJudge(items: [MemoryBenchItem], labels: [MemoryBenchLabel]) -> [(item: Int, verdict: MemoryBenchVerdict, labelId: String)]
}

public extension MemoryBenchWriter {
    public var scorers: [any MemoryBenchScorer] { [MemoryBenchBasicScorer()] }

    /// 两份模板各渲染一遍；写错的抛 `PromptTemplate.Failure`（带行号）
    public func prompt(for testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) throws -> MemoryBenchPrompt {
        if callStyle == .local { return MemoryBenchPrompt(system: "", user: "") }
        let vars = try variables(for: testCase, recipe: recipe)
        return MemoryBenchPrompt(system: try PromptTemplate(recipe.system).render(vars),
                                 user: try PromptTemplate(recipe.user).render(vars))
    }

    /// 默认的自动配：条目正文 + 各字段里含某条标签的任一关键词就算配上；「不该记」先配（一条既像该记又像不该记时按错算）。
    /// 一条最多配一个标签；没配上的留给她判
    public func autoJudge(items: [MemoryBenchItem], labels: [MemoryBenchLabel]) -> [(item: Int, verdict: MemoryBenchVerdict, labelId: String)] {
        let ordered = labels.filter { $0.kind == MemoryBenchLabel.shouldNotHave } + labels.filter { $0.kind == MemoryBenchLabel.shouldHave }
        return items.compactMap { item in
            let hay = ([item.text] + item.fields.values.sorted()).joined(separator: "\n")
            guard let label = ordered.first(where: { l in l.keys.contains { !$0.isEmpty && hay.range(of: $0, options: .caseInsensitive) != nil } }) else {
                return nil
            }
            return (item.index, label.kind == MemoryBenchLabel.shouldNotHave ? .wrong : .right, label.id)
        }
    }
}

// MARK: - 打分（⧫Q1 粟粟 10-23：「先别细究，弄个架子就行」→ 可插拔，先占位）

public protocol MemoryBenchScorer: Sendable {
    var id: String { get }
    var version: Int { get }
    var mainName: String { get }
    /// 一个「配方 × 模型」的格子 + 这些格子上最后算数的判断 → 主分 + 副分
    func score(cells: [MemoryBenchCell], judgments: [MemoryBenchJudgment]) -> (main: Double?, parts: [String: Double])
}

/// 占位打分器（所有写手共用）：主分 = 已判条目里「对」的比例（没判过 = 没有主分）；副分只是数数
public struct MemoryBenchBasicScorer: MemoryBenchScorer {
    public let id = "basic"
    public let version = 1
    public let mainName = "判对比例"

    public init() {}

    public func score(cells: [MemoryBenchCell], judgments: [MemoryBenchJudgment]) -> (main: Double?, parts: [String: Double]) {
        let ids = Set(cells.map(\.id))
        let mine = judgments.filter { ids.contains($0.cellId) }
        let right = mine.filter { $0.verdict == .right }.count
        let wrong = mine.filter { $0.verdict == .wrong }.count
        let weak = mine.filter { $0.verdict == .weak }.count
        let judged = right + wrong + weak
        let parts: [String: Double] = [
            "格子": Double(cells.count),
            "出错格": Double(cells.filter { $0.error != nil }.count),
            "条目": Double(cells.reduce(0) { $0 + $1.items.count }),
            "已判": Double(judged),
            "判对": Double(right),
            "判错": Double(wrong),
            "偏弱": Double(weak),
            "自动配": Double(mine.filter { $0.by == .auto }.count),
            "硬检查没过": Double(cells.reduce(0) { $0 + $1.checks.filter { $0.hard && !$0.passed }.count }),
            "输入token": Double(cells.compactMap(\.usage?.input).reduce(0, +)),
            "输出token": Double(cells.compactMap(\.usage?.output).reduce(0, +)),
            "美元": cells.compactMap(\.usd).reduce(0, +),
        ]
        return (judged > 0 ? Double(right) / Double(judged) : nil, parts)
    }
}

extension MemoryBenchRun {
    /// 用这些打分器给每个「配方 × 模型」打分（判断变了 / 打分器换了，随时重算）
    public func scored(with scorers: [any MemoryBenchScorer]) -> [MemoryBenchScore] {
        let judgments = effectiveJudgments()
        var out: [MemoryBenchScore] = []
        for recipe in recipes {
            for model in models {
                let group = cells.filter { $0.recipeId == recipe.id && $0.modelId == model.id }
                guard !group.isEmpty else { continue }
                for s in scorers {
                    let r = s.score(cells: group, judgments: judgments)
                    out.append(MemoryBenchScore(scorer: s.id, version: s.version, recipeId: recipe.id, modelId: model.id,
                                                main: r.main, mainName: s.mainName, parts: r.parts))
                }
            }
        }
        return out
    }
}
