import Foundation

/// 图表试算的公式（docs/plan-chart-cards-v2.md）：模型写 `m*x*(1+r/100*x/24)`，对方拖滑块当场重算。
/// 自写递归下降解析器——只认数字、+ - * / ^、括号、给定的变量名和 min / max / round / abs / sqrt，
/// 不走 NSExpression（坏输入会抛 ObjC 异常、还能调方法），不执行任何代码。解析不了就是 nil。
struct ChartFormula: Equatable {
    indirect enum Node: Equatable {
        case number(Double)
        case variable(String)
        case negate(Node)
        case binary(Character, Node, Node)
        case call(String, [Node])
    }

    static let functions: [String: ClosedRange<Int>] = ["min": 1...8, "max": 1...8, "round": 1...2, "abs": 1...1, "sqrt": 1...1]
    static let maxLength = 300
    static let maxDepth = 32

    let root: Node

    init?(_ source: String, variables: Set<String>) {
        guard source.count <= Self.maxLength else { return nil }
        var p = Parser(chars: Array(source), variables: variables)
        guard let node = p.parseExpression(depth: 0) else { return nil }
        p.skipSpaces()
        guard p.pos == p.chars.count else { return nil }
        root = node
    }

    /// 算不出有限数（除零、负数开方、溢出）→ nil，调用方不画那个点
    func evaluate(_ vars: [String: Double]) -> Double? {
        let v = Self.eval(root, vars)
        return v.isFinite ? v : nil
    }

    private static func eval(_ n: Node, _ vars: [String: Double]) -> Double {
        switch n {
        case .number(let d): return d
        case .variable(let name): return vars[name] ?? .nan
        case .negate(let a): return -eval(a, vars)
        case .binary(let op, let a, let b):
            let x = eval(a, vars), y = eval(b, vars)
            switch op {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            case "/": return y == 0 ? .nan : x / y
            default: return pow(x, y)
            }
        case .call(let name, let args):
            let v = args.map { eval($0, vars) }
            switch name {
            case "min": return v.min() ?? .nan
            case "max": return v.max() ?? .nan
            case "abs": return abs(v[0])
            case "sqrt": return v[0] < 0 ? .nan : v[0].squareRoot()
            default:   // round(a) / round(a, 位数)
                let digits = v.count > 1 ? max(0, min(10, Int(v[1]))) : 0
                let scale = pow(10, Double(digits))
                return (v[0] * scale).rounded(.toNearestOrAwayFromZero) / scale
            }
        }
    }

    private struct Parser {
        let chars: [Character]
        let variables: Set<String>
        var pos = 0

        mutating func skipSpaces() { while pos < chars.count, chars[pos] == " " { pos += 1 } }

        mutating func peek() -> Character? { skipSpaces(); return pos < chars.count ? chars[pos] : nil }

        mutating func eat(_ c: Character) -> Bool {
            guard peek() == c else { return false }
            pos += 1
            return true
        }

        // expr := term (('+'|'-') term)*
        mutating func parseExpression(depth: Int) -> Node? {
            guard depth < ChartFormula.maxDepth, var lhs = parseTerm(depth: depth) else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                pos += 1
                guard let rhs = parseTerm(depth: depth) else { return nil }
                lhs = .binary(c, lhs, rhs)
            }
            return lhs
        }

        // term := unary (('*'|'/') unary)*
        mutating func parseTerm(depth: Int) -> Node? {
            guard var lhs = parseUnary(depth: depth) else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                pos += 1
                guard let rhs = parseUnary(depth: depth) else { return nil }
                lhs = .binary(c, lhs, rhs)
            }
            return lhs
        }

        // unary := '-' unary | power（负号比乘方低：-2^2 = -4）
        mutating func parseUnary(depth: Int) -> Node? {
            guard depth < ChartFormula.maxDepth else { return nil }
            if eat("-") { return parseUnary(depth: depth + 1).map(Node.negate) }
            if eat("+") { return parseUnary(depth: depth + 1) }
            return parsePower(depth: depth)
        }

        // power := primary ('^' unary)?（右结合）
        mutating func parsePower(depth: Int) -> Node? {
            guard let base = parsePrimary(depth: depth) else { return nil }
            if eat("^") {
                guard let exp = parseUnary(depth: depth + 1) else { return nil }
                return .binary("^", base, exp)
            }
            return base
        }

        mutating func parsePrimary(depth: Int) -> Node? {
            guard let c = peek() else { return nil }
            if c == "(" {
                pos += 1
                guard let inner = parseExpression(depth: depth + 1), eat(")") else { return nil }
                return inner
            }
            if c.isASCII, c.isNumber || c == "." { return parseNumber() }
            if c.isASCII, c.isLetter || c == "_" {
                let start = pos
                while pos < chars.count, chars[pos].isASCII, chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_" { pos += 1 }
                let name = String(chars[start..<pos])
                if peek() == "(" {
                    guard let arity = ChartFormula.functions[name] else { return nil }
                    pos += 1
                    var args: [Node] = []
                    if peek() != ")" {
                        repeat {
                            guard let a = parseExpression(depth: depth + 1) else { return nil }
                            args.append(a)
                        } while eat(",")
                    }
                    guard eat(")"), arity.contains(args.count) else { return nil }
                    return .call(name, args)
                }
                return variables.contains(name) ? .variable(name) : nil
            }
            return nil
        }

        mutating func parseNumber() -> Node? {
            let start = pos
            var dot = false
            while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber || (chars[pos] == "." && !dot) {
                if chars[pos] == "." { dot = true }
                pos += 1
            }
            guard let d = Double(String(chars[start..<pos])), d.isFinite else { return nil }
            return .number(d)
        }
    }
}
