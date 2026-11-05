import Foundation

/// 试写台模板里的一个变量值（plan-memory-audit-home-trial 3.3）：一段字 / 一个数 / 是否 / 一组（给 `{{#每 …}}` 用）
enum MemoryBenchValue: Equatable, Sendable {
    case text(String)
    case number(Int)
    case flag(Bool)
    case list([[String: MemoryBenchValue]])

    var isTruthy: Bool {
        switch self {
        case .text(let s): return !s.isEmpty
        case .number(let n): return n != 0
        case .flag(let b): return b
        case .list(let items): return !items.isEmpty
        }
    }

    /// 比较用：数 = 自己，一组 = 有几份，是否 = 1 / 0，字 = 能读成整数就按整数、否则按字数
    var numeric: Int {
        switch self {
        case .text(let s): return Int(s.trimmingCharacters(in: .whitespaces)) ?? s.count
        case .number(let n): return n
        case .flag(let b): return b ? 1 : 0
        case .list(let items): return items.count
        }
    }
}

/// 试写台的提示词模板：只有三种写法——`{{变量}}`、`{{#如果 条件}}…{{否则}}…{{/如果}}`、`{{#每 一组}}…{{/每}}`。
/// 条件 = `变量`（有内容 / 是真）、`不 变量`、`变量 <= 8`（`<` `<=` `>` `>=` `=` `!=`，右边是整数）。
/// `{{#每 段}}` 里能用这一份的字段和 `序号`（从 1 数）、`是第一个`、`是最后一个`，外层变量照样能用。
/// 除了 `{{` 开头的标记，其余一字不动（不吃换行、不做转义），所以「现行」配方能逐字复现正式写手的提示词
struct PromptTemplate: Equatable, Sendable {

    struct Problem: Equatable, Sendable {
        let line: Int
        let message: String

        var text: String { "第 \(line) 行：\(message)" }
    }

    /// 写错了：一个或几个问题（带行号）
    struct Failure: LocalizedError, Equatable, Sendable {
        let problems: [Problem]

        var errorDescription: String? { problems.map(\.text).joined(separator: "；") }
    }

    enum Comparison: String, Equatable, Sendable, CaseIterable {
        case le = "<=", ge = ">=", ne = "!=", lt = "<", gt = ">", eq = "="

        func holds(_ a: Int, _ b: Int) -> Bool {
            switch self {
            case .le: return a <= b
            case .ge: return a >= b
            case .ne: return a != b
            case .lt: return a < b
            case .gt: return a > b
            case .eq: return a == b
            }
        }
    }

    struct Condition: Equatable, Sendable {
        var name: String
        var negated = false
        var comparison: Comparison? = nil
        var operand = 0
    }

    indirect enum Node: Equatable, Sendable {
        case text(String)
        case variable(String, line: Int)
        case conditional(Condition, then: [Node], otherwise: [Node], line: Int)
        case each(String, body: [Node], line: Int)
    }

    let nodes: [Node]

    static let ifOpen = "#如果"
    static let ifElse = "否则"
    static let ifClose = "/如果"
    static let eachOpen = "#每"
    static let eachClose = "/每"
    static let indexName = "序号"
    static let firstName = "是第一个"
    static let lastName = "是最后一个"

    // MARK: - 读

    init(_ source: String) throws {
        nodes = try Self.parse(source)
    }

    private enum Frame {
        case conditional(Condition, then: [Node], otherwise: [Node]?, line: Int)
        case each(String, body: [Node], line: Int)
    }

    private static func parse(_ source: String) throws -> [Node] {
        var root: [Node] = []
        var stack: [Frame] = []
        var line = 1
        var rest = Substring(source)

        func append(_ node: Node) {
            guard let top = stack.popLast() else {
                root.append(node)
                return
            }
            switch top {
            case .conditional(let c, var then, var otherwise, let l):
                if otherwise != nil { otherwise?.append(node) } else { then.append(node) }
                stack.append(.conditional(c, then: then, otherwise: otherwise, line: l))
            case .each(let name, var body, let l):
                body.append(node)
                stack.append(.each(name, body: body, line: l))
            }
        }

        while let open = rest.range(of: "{{") {
            let before = rest[..<open.lowerBound]
            if !before.isEmpty { append(.text(String(before))) }
            line += before.filter { $0 == "\n" }.count
            guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
                throw Failure(problems: [Problem(line: line, message: "「{{」没有配上「}}」")])
            }
            let raw = rest[open.upperBound..<close.lowerBound]
            let tagLine = line
            line += raw.filter { $0 == "\n" }.count
            rest = rest[close.upperBound...]
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            if tag.hasPrefix(ifOpen) {
                let cond = try condition(String(tag.dropFirst(ifOpen.count)), line: tagLine)
                stack.append(.conditional(cond, then: [], otherwise: nil, line: tagLine))
            } else if tag == ifElse {
                guard case .conditional(let c, let then, let otherwise, let l)? = stack.last, otherwise == nil else {
                    throw Failure(problems: [Problem(line: tagLine, message: "「{{否则}}」要在「{{#如果 …}}」里面，而且只能有一个")])
                }
                stack[stack.count - 1] = .conditional(c, then: then, otherwise: [], line: l)
            } else if tag == ifClose {
                guard case .conditional(let c, let then, let otherwise, let l)? = stack.popLast() else {
                    throw Failure(problems: [Problem(line: tagLine, message: "多了一个「{{/如果}}」，或者它关的不是「{{#如果}}」")])
                }
                append(.conditional(c, then: then, otherwise: otherwise ?? [], line: l))
            } else if tag.hasPrefix(eachOpen) {
                let name = tag.dropFirst(eachOpen.count).trimmingCharacters(in: .whitespaces)
                guard isName(name) else {
                    throw Failure(problems: [Problem(line: tagLine, message: "「{{#每 …}}」后面要写一组的名字，比如「{{#每 段}}」")])
                }
                stack.append(.each(name, body: [], line: tagLine))
            } else if tag == eachClose {
                guard case .each(let name, let body, let l)? = stack.popLast() else {
                    throw Failure(problems: [Problem(line: tagLine, message: "多了一个「{{/每}}」，或者它关的不是「{{#每}}」")])
                }
                append(.each(name, body: body, line: l))
            } else if tag.hasPrefix("#") || tag.hasPrefix("/") {
                throw Failure(problems: [Problem(line: tagLine, message: "不认识「{{\(tag)}}」：块只有「#如果」「#每」两种")])
            } else {
                guard isName(tag) else {
                    throw Failure(problems: [Problem(line: tagLine, message: "「{{\(tag)}}」不是变量名（变量名里不能有空格）")])
                }
                append(.variable(tag, line: tagLine))
            }
        }
        if !rest.isEmpty { append(.text(String(rest))) }

        if let open = stack.last {
            switch open {
            case .conditional(_, _, _, let l):
                throw Failure(problems: [Problem(line: l, message: "「{{#如果 …}}」没有收尾的「{{/如果}}」")])
            case .each(_, _, let l):
                throw Failure(problems: [Problem(line: l, message: "「{{#每 …}}」没有收尾的「{{/每}}」")])
            }
        }
        return root
    }

    private static func isName(_ s: String) -> Bool {
        !s.isEmpty && !s.contains(where: { $0.isWhitespace || $0 == "{" || $0 == "}" })
    }

    private static func condition(_ raw: String, line: Int) throws -> Condition {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var cond = Condition(name: "")
        if text.hasPrefix("不"), text.dropFirst().first?.isWhitespace == true {
            cond.negated = true
            text = text.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        for op in Comparison.allCases {
            guard let r = text.range(of: op.rawValue) else { continue }
            let name = text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let number = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard isName(name), let n = Int(number) else { break }
            cond.name = name
            cond.comparison = op
            cond.operand = n
            return cond
        }
        guard isName(text), !Comparison.allCases.contains(where: { text.contains($0.rawValue) }) else {
            throw Failure(problems: [Problem(line: line, message: "看不懂条件「\(raw.trimmingCharacters(in: .whitespaces))」：写「变量」「不 变量」或「变量 <= 8」")])
        }
        cond.name = text
        return cond
    }

    // MARK: - 渲染

    /// 用一组变量渲染；不认识的变量、把一组当字用、拿不是数的东西比较，都收进 `Failure`（全部列出来，不只第一个）
    func render(_ variables: [String: MemoryBenchValue]) throws -> String {
        var problems: [Problem] = []
        let out = Self.render(nodes, scopes: [variables], problems: &problems)
        guard problems.isEmpty else { throw Failure(problems: problems) }
        return out
    }

    private static func lookup(_ name: String, _ scopes: [[String: MemoryBenchValue]]) -> MemoryBenchValue? {
        for scope in scopes.reversed() {
            if let v = scope[name] { return v }
        }
        return nil
    }

    private static func render(_ nodes: [Node], scopes: [[String: MemoryBenchValue]], problems: inout [Problem]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let s):
                out += s
            case .variable(let name, let line):
                switch lookup(name, scopes) {
                case .text(let s)?: out += s
                case .number(let n)?: out += String(n)
                case .flag(let b)?: out += b ? "是" : "否"
                case .list?: problems.append(Problem(line: line, message: "「\(name)」是一组，要用「{{#每 \(name)}}…{{/每}}」"))
                case nil: problems.append(Problem(line: line, message: "不认识变量「\(name)」"))
                }
            case .conditional(let c, let then, let otherwise, let line):
                guard let value = lookup(c.name, scopes) else {
                    problems.append(Problem(line: line, message: "不认识变量「\(c.name)」"))
                    continue
                }
                var holds = c.comparison.map { $0.holds(value.numeric, c.operand) } ?? value.isTruthy
                if c.negated { holds.toggle() }
                out += render(holds ? then : otherwise, scopes: scopes, problems: &problems)
            case .each(let name, let body, let line):
                guard let value = lookup(name, scopes) else {
                    problems.append(Problem(line: line, message: "不认识变量「\(name)」"))
                    continue
                }
                guard case .list(let items) = value else {
                    problems.append(Problem(line: line, message: "「\(name)」不是一组，不能「{{#每}}」"))
                    continue
                }
                for (i, item) in items.enumerated() {
                    var scope = item
                    scope[indexName] = .number(i + 1)
                    scope[firstName] = .flag(i == 0)
                    scope[lastName] = .flag(i == items.count - 1)
                    out += render(body, scopes: scopes + [scope], problems: &problems)
                }
            }
        }
        return out
    }
}
