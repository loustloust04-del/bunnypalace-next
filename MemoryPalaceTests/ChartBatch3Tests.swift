import XCTest
import CoreGraphics
@testable import 记忆花园

/// 图表卡 v2 第 3 批（docs/plan-chart-cards-v2.md）：scatter · histogram · box · waterfall · gauge · funnel · treemap
final class ChartBatch3Tests: XCTestCase {
    private func chart(_ json: String) -> ChartCard? {
        if case .chart(let c)? = ChatCard.parse(language: "card-chart", code: json) { return c }
        return nil
    }

    private func roundTrips(_ c: ChartCard, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ChatCardExtractor.cards(in: ChatCard.chart(c).blockText), [.chart(c)], file: file, line: line)
    }

    func testScatter() throws {
        let c = try XCTUnwrap(chart(#"{"type":"scatter","xLabel":"价格","yLabel":"满意度","points":[["编辑器",120,86],["日历",0,64]]}"#))
        XCTAssertEqual(c.scatter?.count, 2)
        roundTrips(c)
        XCTAssertEqual(ChartReadings.rows(c, series: [], label: "编辑器", hidden: []).map(\.text), ["价格 120 · 满意度 86"])
        XCTAssertNil(chart(#"{"type":"scatter","points":[["a",1]]}"#), "要三个数")
        XCTAssertNil(chart(#"{"type":"scatter","points":[["a",1,2],["a",3,4]]}"#), "名字不重")
        XCTAssertNil(chart(#"{"type":"scatter","points":[\#((0..<41).map { #"["p\#($0)",1,2]"# }.joined(separator: ","))]}"#), "≤40 点")
    }

    func testHistogramAndFunnel() throws {
        let h = try XCTUnwrap(chart(#"{"type":"histogram","unit":"单","series":[{"points":[["<1h",22],["1–3h",38]]}]}"#))
        roundTrips(h)
        XCTAssertNil(chart(#"{"type":"histogram","series":[{"points":[["a",-1]]}]}"#))
        let f = try XCTUnwrap(chart(#"{"type":"funnel","unit":"人","series":[{"points":[["访问",12400],["注册",3100],["付费",240]]}]}"#))
        XCTAssertEqual(ChartReadings.rows(f, series: f.series, label: "注册", hidden: []).map(\.text), ["3,100 人 · 留下上一步的 25%"])
        XCTAssertEqual(ChartReadings.rows(f, series: f.series, label: "访问", hidden: []).map(\.text), ["12,400 人"])
        XCTAssertNil(chart(#"{"type":"funnel","series":[{"points":[["a",0],["b",0]]}]}"#), "第一步要大于 0")
        XCTAssertNil(chart(#"{"type":"funnel","series":[{"points":[\#((0..<9).map { #"["s\#($0)",1]"# }.joined(separator: ","))]}]}"#), "≤8 步")
    }

    func testBoxFiveNumbers() throws {
        let c = try XCTUnwrap(chart(#"{"type":"box","unit":"分钟","groups":[["专业",[12,15,14,18,11,16,13,17,15,40]],["团队",[20,26]]]}"#))
        XCTAssertEqual(c.boxes?.map(\.name), ["专业", "团队"])
        roundTrips(c)
        let s = ChartStats.five(c.boxes![0].values)
        XCTAssertEqual(s.median, 15, accuracy: 1e-9)
        XCTAssertEqual(s.q1, 13.25, accuracy: 1e-9)
        XCTAssertEqual(s.q3, 16.75, accuracy: 1e-9)
        XCTAssertEqual(s.outliers, [40], "超出 1.5 倍四分距的是离群")
        XCTAssertEqual(s.high, 18)
        XCTAssertEqual(ChartReadings.rows(c, series: [], label: "专业", hidden: []).map(\.text), ["中位 15 分钟 · 中间一半 13.25–16.75 · 10 个"])
        XCTAssertNil(chart(#"{"type":"box","groups":[["a",[]]]}"#))
        XCTAssertNil(chart(#"{"type":"box","groups":[["a",[1]],["a",[2]]]}"#))
    }

    func testWaterfallSteps() throws {
        let c = try XCTUnwrap(chart(#"{"type":"waterfall","unit":"万","total":"净利","series":[{"points":[["收入",42],["退款",-6],["成本",-11]]}]}"#))
        roundTrips(c)
        let steps = ChartStats.waterfall(c)
        XCTAssertEqual(steps.map(\.label), ["收入", "退款", "成本", "净利"])
        XCTAssertEqual(steps.map(\.from), [0, 42, 36, 0])
        XCTAssertEqual(steps.map(\.to), [42, 36, 25, 25])
        XCTAssertEqual(ChartReadings.rows(c, series: c.series, label: "退款", hidden: []).map(\.text), ["-6 万"])
        XCTAssertEqual(ChartReadings.rows(c, series: c.series, label: "净利", hidden: []).map(\.text), ["25 万"])
        XCTAssertEqual(ChartReadings.labels(c, series: c.series), ["收入", "退款", "成本", "净利"])
        XCTAssertNil(chart(#"{"type":"waterfall","total":"收入","series":[{"points":[["收入",42],["退款",-6]]}]}"#), "合计名不能和某一步重名")
    }

    func testGauge() throws {
        let c = try XCTUnwrap(chart(#"{"type":"gauge","unit":"万","value":73,"target":100}"#))
        roundTrips(c)
        XCTAssertEqual(ChartReadings.labels(c, series: []), ["进度"])
        XCTAssertEqual(ChartReadings.rows(c, series: [], label: "进度", hidden: []).map(\.text), ["73 万 / 100 万（73%）"])
        XCTAssertNil(chart(#"{"type":"gauge","value":3,"target":0}"#))
        XCTAssertNil(chart(#"{"type":"gauge","value":-1,"target":10}"#))
        XCTAssertNotNil(chart(#"{"type":"gauge","value":130,"target":100}"#), "超额也认，表盘画满")
    }

    func testTreemapLayout() throws {
        let c = try XCTUnwrap(chart(#"{"type":"treemap","unit":"元","groups":[{"name":"住","items":[["房租",4200],["水电",380]]},{"name":"吃","items":[["外卖",1260],["买菜",820]]}]}"#))
        XCTAssertEqual(c.tree?.count, 2)
        roundTrips(c)
        XCTAssertEqual(ChartReadings.labels(c, series: []), ["住 · 房租", "住 · 水电", "吃 · 外卖", "吃 · 买菜"])
        XCTAssertEqual(ChartReadings.rows(c, series: [], label: "吃 · 外卖", hidden: []).map(\.text), ["1,260 元（占 19%）"])
        // squarified：面积正比于值、铺满、不重叠
        let rects = ChartStats.squarify([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(rects.count, 7)
        XCTAssertEqual(rects.map { $0.width * $0.height }.reduce(0, +), 240_000, accuracy: 1e-6)
        XCTAssertEqual(rects[0].width * rects[0].height, 60_000, accuracy: 1e-6)
        for (i, a) in rects.enumerated() { for b in rects[(i + 1)...] { XCTAssertLessThan(a.intersection(b).width * a.intersection(b).height, 1e-6) } }
        let worst = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        XCTAssertLessThan(worst, 4, "squarified 不切细条")
        XCTAssertNil(chart(#"{"type":"treemap","groups":[{"name":"a","items":[["x",-1]]}]}"#))
        XCTAssertNil(chart(#"{"type":"treemap","groups":[{"name":"a","items":[]}]}"#))
    }

    func testAutoSubtitles() throws {
        let s = try XCTUnwrap(chart(#"{"type":"scatter","xLabel":"价格","yLabel":"满意度","points":[["a",1,2]]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(s, series: []), "每个点垂一根线：看线脚读价格、看高度读满意度")
        let w = try XCTUnwrap(chart(#"{"type":"waterfall","unit":"万","series":[{"points":[["收入",38],["退款",-6]]}]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(w, series: w.series), "一格 = 1 万 · 实线 = 加 · 虚线 = 减")
        let g = try XCTUnwrap(chart(#"{"type":"gauge","value":3,"target":10}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(g, series: []), "一根刻度 = 目标的 1%")
    }
}
