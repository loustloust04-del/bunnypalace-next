import XCTest
@testable import 记忆花园

/// 图表试算的公式（docs/plan-chart-cards-v2.md）：自写解析器，只认四则、乘方、括号、变量和几个函数
final class ChartFormulaTests: XCTestCase {
    private func eval(_ s: String, _ vars: [String: Double] = [:]) -> Double? {
        guard let f = ChartFormula(s, variables: Set(vars.keys)) else { return nil }
        return f.evaluate(vars)
    }

    func testPrecedenceAndParentheses() {
        XCTAssertEqual(eval("1+2*3"), 7)
        XCTAssertEqual(eval("(1+2)*3"), 9)
        XCTAssertEqual(eval("10-4-3"), 3, "左结合")
        XCTAssertEqual(eval("2^3^2"), 512, "乘方右结合")
        XCTAssertEqual(eval("-2^2"), -4, "负号比乘方低")
        XCTAssertEqual(eval("2*-3"), -6)
        XCTAssertEqual(eval("8/4/2"), 1)
        XCTAssertEqual(eval(" 1.5 * 2 "), 3)
        XCTAssertEqual(eval(".5+1"), 1.5)
    }

    func testVariablesAndFunctions() {
        XCTAssertEqual(eval("m*x*(1+r/100*x/24)", ["m": 1500, "r": 3, "x": 12]) ?? 0, 18270, accuracy: 1e-6)
        XCTAssertEqual(eval("min(x, 3, 5)", ["x": 4]), 3)
        XCTAssertEqual(eval("max(1, x)", ["x": 4]), 4)
        XCTAssertEqual(eval("round(2.567, 1)"), 2.6)
        XCTAssertEqual(eval("round(2.5)"), 3)
        XCTAssertEqual(eval("abs(-3)+sqrt(16)"), 7)
    }

    func testRejectsUnknownOrBadInput() {
        XCTAssertNil(ChartFormula("y*2", variables: ["x"]), "未知变量")
        XCTAssertNil(ChartFormula("foo(1)", variables: []), "未知函数")
        XCTAssertNil(ChartFormula("1+", variables: []))
        XCTAssertNil(ChartFormula("(1+2", variables: []))
        XCTAssertNil(ChartFormula("1 2", variables: []))
        XCTAssertNil(ChartFormula("x; rm -rf", variables: ["x"]))
        XCTAssertNil(ChartFormula("", variables: []))
        XCTAssertNil(ChartFormula("abs()", variables: []))
        XCTAssertNil(ChartFormula("sqrt(1,2)", variables: []))
        XCTAssertNil(ChartFormula(String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100), variables: []), "嵌套太深")
        XCTAssertNil(ChartFormula(String(repeating: "1+", count: 200) + "1", variables: []), "太长")
    }

    func testNonFiniteResultsAreNil() {
        XCTAssertNil(eval("1/0"))
        XCTAssertNil(eval("sqrt(-1)"))
        XCTAssertNil(eval("10^400"))
    }
}
