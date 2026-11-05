import Foundation

/// C2 碎片池接进试写台（plan-memory-audit-home-trial 第四节 C2 行）：用例 = 冻结的一截对话；
/// 「现行」配方直接拿 `FragmentPool.defaultTemplate` 换占位符（不另抄一份提示词），渲染结果和正式 C2 逐字相同；
/// 解析 / 检查直接用 `FragmentPool.parseExplained`。试写一次就是一次：不像正式写那样不合格再重写
struct MemoryBenchC2Writer: MemoryBenchWriter {
    let id = MemoryWriterID.c2.rawValue
    let title = "C2 碎片池"
    let callStyle = MemoryBenchCallStyle.single
    let labelKinds = [MemoryBenchLabel.shouldHave, MemoryBenchLabel.shouldNotHave]

    /// 「现行」= 正式 C2 现在实际用的那份（有自定义就是自定义）
    static let currentRecipeId = "c2-current"
    /// 有自定义时，默认模板另列一份候选
    static let defaultRecipeId = "c2-default"
    /// 管线参数：卡片必须带 subject / speaker（正式 C2：默认模板要、旧自定义模板不要）
    static let requireAttributionParam = "要求subject和speaker"

    /// 用例的冻结输入：两边称呼 + 几轮对话（date 存本机时区的「yyyy-MM-dd HH:mm」，和探针当初一样按本机时间算记忆日）。
    /// day = 「这一截最后一天」（提示词里的 {{日期}}）：建用例那一刻冻结进来，末条没日期也不会跑一次换一天
    struct Input: Codable, Equatable, Sendable {
        struct Names: Codable, Equatable, Sendable {
            var user: String
            var char: String
        }

        struct Line: Codable, Equatable, Sendable {
            var role: String
            var content: String
            var date: String?
        }

        var names: Names
        var messages: [Line]
        var day: String? = nil
    }

    enum InputError: LocalizedError, Equatable {
        case badDate(index: Int, value: String)
        case badDay(String)
        case noDay

        var errorDescription: String? {
            switch self {
            case .badDate(let i, let v): return "第 \(i) 条消息的日期「\(v)」看不懂（要 yyyy-MM-dd HH:mm）"
            case .badDay(let v): return "用例的日期「\(v)」看不懂（要 yyyy-MM-dd）"
            case .noDay: return "这个用例没有日期：最后一条消息没带日期，也没冻结 day"
            }
        }
    }

    let variableCatalog = [
        MemoryBenchVariable(name: "称呼", note: "她的称呼（空 =「用户」，同正式 C2）", example: "岚舟"),
        MemoryBenchVariable(name: "我的名字", note: "助手的名字（空 =「我」）", example: "星砚"),
        MemoryBenchVariable(name: "日期", note: "这一截最后一条那天（记忆日，05:00 分界）", example: "2026-10-12"),
        MemoryBenchVariable(name: "对话", note: "带编号和日期的对话，同正式 C2 喂的那份", example: "[1] 2026-10-12 · 岚舟：……"),
        MemoryBenchVariable(name: "条数", note: "这一截有几条消息", example: "6"),
    ]

    // MARK: - 用例

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 从一截真对话冻结出一个用例（建测试集 / 从整理台导入都走这里）。「这一截最后一天」按正式 C2 的口径
    /// （末条的记忆日，末条没日期 = 建用例这一天）当场冻结进 day，以后怎么跑都是这天
    static func makeCase(id: String, title: String, messages: [FragmentPool.Message], userName: String, assistantName: String,
                         labels: [MemoryBenchLabel] = [], note: String? = nil, now: Date = Date()) throws -> MemoryBenchCase {
        let input = Input(names: .init(user: userName, char: assistantName),
                          messages: messages.map { .init(role: $0.role, content: $0.content, date: $0.date.map(dateFormatter.string(from:))) },
                          day: MemoryDay.key(messages.last?.date ?? now))
        return MemoryBenchCase(id: id, title: title, input: try .from(input), labels: labels, note: note)
    }

    static func input(_ testCase: MemoryBenchCase) throws -> Input {
        try testCase.input.decode(Input.self)
    }

    /// 日期看不懂就报错（不悄悄当成没日期）
    static func messages(_ input: Input, caseId: String) throws -> [FragmentPool.Message] {
        try input.messages.enumerated().map { i, line in
            var date: Date?
            if let raw = line.date {
                guard let d = dateFormatter.date(from: raw) else { throw InputError.badDate(index: i + 1, value: raw) }
                date = d
            }
            return FragmentPool.Message(id: "bench-\(caseId)-\(i)", role: line.role, content: line.content, date: date)
        }
    }

    /// 「这一截最后一天」：末条有日期按它（同正式 C2），否则用冻结的 day；都没有 / day 看不懂就报错
    static func day(_ input: Input, messages: [FragmentPool.Message]) throws -> String {
        if let last = messages.last?.date { return MemoryDay.key(last) }
        guard let raw = input.day else { throw InputError.noDay }
        guard let day = FragmentPool.validDay(raw) else { throw InputError.badDay(raw) }
        return day
    }

    static func names(_ input: Input) -> MemoryExtractor.Names {
        MemoryExtractor.Names(userName: input.names.user, assistantName: input.names.char)
    }

    // MARK: - 配方

    /// 正式 C2 的模板占位符 → 试写台变量
    static func template(fromProduction text: String) -> String {
        text.replacingOccurrences(of: "{{USER_NAME}}", with: "{{称呼}}")
            .replacingOccurrences(of: "{{CHAR_NAME}}", with: "{{我的名字}}")
            .replacingOccurrences(of: "{{DATE}}", with: "{{日期}}")
    }

    /// 第一份「现行」= 正式 C2 现在实际用的（有自定义就是自定义：模板 + 「不要求 subject / speaker」都跟着它，astra zd2 #3）；
    /// 有自定义时默认模板另列一份「默认提示词」候选
    func builtInRecipes(defaults: UserDefaults) -> [MemoryBenchRecipe] {
        func recipe(_ rid: String, _ name: String, _ template: String, require: Bool) -> MemoryBenchRecipe {
            MemoryBenchRecipe(id: rid, writer: id, name: name, parent: nil, system: Self.template(fromProduction: template), user: "{{对话}}",
                              params: [Self.requireAttributionParam: .bool(require)], checks: "current", builtIn: true, savedAt: nil)
        }
        guard let custom = FragmentPool.activeCustomTemplate(defaults: defaults) else {
            return [recipe(Self.currentRecipeId, "现行（默认提示词）", FragmentPool.defaultTemplate, require: true)]
        }
        return [recipe(Self.currentRecipeId, "现行（你的自定义提示词）", custom, require: false),
                recipe(Self.defaultRecipeId, "默认提示词", FragmentPool.defaultTemplate, require: true)]
    }

    func variables(for testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) throws -> [String: MemoryBenchValue] {
        let input = try Self.input(testCase)
        let messages = try Self.messages(input, caseId: testCase.id)
        let names = Self.names(input)
        return [
            "称呼": .text(names.user),
            "我的名字": .text(names.char),
            "日期": .text(try Self.day(input, messages: messages)),
            "对话": .text(FragmentPool.userContent(messages, names: names)),
            "条数": .number(messages.count),
        ]
    }

    // MARK: - 解析 / 检查

    func parse(output: String, testCase: MemoryBenchCase, recipe: MemoryBenchRecipe) -> MemoryBenchParsed {
        guard let input = try? Self.input(testCase), let messages = try? Self.messages(input, caseId: testCase.id) else {
            return MemoryBenchParsed(items: [], checks: [MemoryBenchCheck(name: "用例能读", passed: false, hard: true, detail: "用例的输入读不了")])
        }
        let visible = FragmentPool.window(messages, names: Self.names(input), charBudget: nil).visible
        let require = recipe.params[Self.requireAttributionParam]?.boolValue ?? true
        let (batch, problem) = FragmentPool.parseExplained(output, visible: visible, messages: messages, requireAttribution: require)
        var checks = [MemoryBenchCheck(name: "整包是一个 JSON 对象", passed: batch != nil, hard: true, detail: problem)]
        guard let batch else { return MemoryBenchParsed(items: [], checks: checks) }
        checks.append(MemoryBenchCheck(name: "每张卡都合格", passed: batch.rejected == 0, hard: true,
                                       detail: batch.rejected > 0 ? "拒收 \(batch.rejected) 张：" + batch.rejectionReasons.joined(separator: "；") : nil))
        let items = batch.fragments.enumerated().map { i, f in
            var fields = [
                "msg": String(f.msg),
                "category": f.category,
                "importance": String(f.importance),
                "emotion": String(f.emotion),
                "tags": f.tags.joined(separator: "、"),
            ]
            fields["subject"] = f.subject
            fields["speaker"] = f.speaker
            fields["resolved"] = f.resolved.map { $0 ? "true" : "false" }
            fields["valid_until"] = f.validUntil?.value
            return MemoryBenchItem(index: i, text: f.content, fields: fields)
        }
        return MemoryBenchParsed(items: items, checks: checks)
    }
}
