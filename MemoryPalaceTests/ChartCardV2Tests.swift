import XCTest
@testable import 记忆花园

/// 图表卡 v2 第 1 批（docs/plan-chart-cards-v2.md）：四件套字段、刻度环、试算、控件、引用
final class ChartCardV2Tests: XCTestCase {
    private func chart(_ json: String) -> ChartCard? {
        if case .chart(let c)? = ChatCard.parse(language: "card-chart", code: json) { return c }
        return nil
    }

    // MARK: 字段

    func testFourPieceFieldsAndRoundTrip() throws {
        let c = try XCTUnwrap(chart(#"{"id":"g-1","type":"bar","title":"周三睡得最少","subtitle":"一格 = 1 小时","source":"手环","unit":"小时","series":[{"name":"睡眠","points":[["周一",7.5],["周三",5]]}]}"#))
        XCTAssertEqual(c.title, "周三睡得最少")
        XCTAssertEqual(c.subtitle, "一格 = 1 小时")
        XCTAssertEqual(c.source, "手环")
        XCTAssertEqual(ChatCardExtractor.cards(in: ChatCard.chart(c).blockText), [.chart(c)])
        // 老卡没有这些字段：编码后也不凭空长出来
        let old = try XCTUnwrap(chart(#"{"type":"line","series":[{"points":[["a",1]]}]}"#))
        let block = ChatCard.chart(old).blockText
        XCTAssertFalse(block.contains("subtitle"))
        XCTAssertFalse(block.contains("params"))
    }

    func testDonutIsAPieAlias() throws {
        let c = try XCTUnwrap(chart(#"{"type":"donut","series":[{"points":[["a",3],["b",1]]}]}"#))
        XCTAssertTrue(c.type.isRing)
        XCTAssertNil(chart(#"{"type":"donut","series":[{"points":[["a",-1],["b",1]]}]}"#))
        XCTAssertEqual(ChatCardExtractor.cards(in: ChatCard.chart(c).blockText), [.chart(c)])
    }

    // MARK: 试算

    private let trialJSON = #"{"id":"g-2","type":"bar","title":"存钱计划","unit":"元","params":[{"key":"m","label":"每月存","min":100,"max":5000,"step":100,"value":1500,"unit":"元"},{"key":"r","label":"年化","min":0,"max":10,"step":0.5,"value":3,"unit":"%"}],"x":{"from":1,"to":12,"label":"第{x}月"},"formulas":[{"name":"余额","y":"m*x*(1+r/100*x/24)"}]}"#

    func testTrialCardComputesSeries() throws {
        let c = try XCTUnwrap(chart(trialJSON))
        XCTAssertTrue(c.isTrial)
        XCTAssertTrue(c.series.isEmpty, "存的是公式不是数")
        let s = ChartTrial.series(c, values: ChartTrial.defaults(c))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].name, "余额")
        XCTAssertEqual(s[0].points.count, 12)
        XCTAssertEqual(s[0].points.first?.label, "第1月")
        XCTAssertEqual(s[0].points.last?.value ?? 0, 18270, accuracy: 1e-6)
        let more = ChartTrial.series(c, values: ["m": 2000, "r": 0])
        XCTAssertEqual(more[0].points.last?.value ?? 0, 24000, accuracy: 1e-6)
        XCTAssertEqual(ChatCardExtractor.cards(in: ChatCard.chart(c).blockText), [.chart(c)])
    }

    func testTrialSkipsNonFinitePoints() throws {
        let c = try XCTUnwrap(chart(#"{"type":"line","params":[],"x":{"from":-2,"to":2},"formulas":[{"name":"倒数","y":"1/x"}]}"#))
        let s = ChartTrial.series(c, values: [:])
        XCTAssertEqual(s[0].points.map(\.label), ["-2", "-1", "1", "2"], "x=0 那点除零，不画")
    }

    func testTrialValidation() {
        let bad = [
            #"{"type":"bar","params":[],"x":{"from":1,"to":12},"formulas":[{"name":"a","y":"q*2"}]}"#,                 // 未知变量
            #"{"type":"bar","params":[],"x":{"from":1,"to":100},"formulas":[{"name":"a","y":"x"}]}"#,                  // 点太多
            #"{"type":"bar","params":[],"x":{"from":1,"to":12,"step":0},"formulas":[{"name":"a","y":"x"}]}"#,
            #"{"type":"bar","params":[{"key":"m","label":"a","min":5,"max":1,"step":1,"value":2}],"x":{"from":1,"to":3},"formulas":[{"name":"a","y":"m"}]}"#,
            #"{"type":"bar","params":[{"key":"x","label":"a","min":0,"max":1,"step":1,"value":0}],"x":{"from":1,"to":3},"formulas":[{"name":"a","y":"x"}]}"#,   // key 撞 x
            #"{"type":"bar","params":[{"key":"9a","label":"a","min":0,"max":1,"step":1,"value":0}],"x":{"from":1,"to":3},"formulas":[{"name":"a","y":"x"}]}"#,
            #"{"type":"pie","params":[],"x":{"from":1,"to":3},"formulas":[{"name":"a","y":"x"}]}"#,                    // 环不能试算
            #"{"type":"bar","params":[],"x":{"from":1,"to":3},"formulas":[]}"#,
            #"{"type":"bar","params":[],"formulas":[{"name":"a","y":"x"}]}"#,                                           // 缺 x
        ]
        for code in bad { XCTAssertNil(chart(code), code) }
        XCTAssertNotNil(chart(#"{"type":"line","params":[],"x":{"from":0,"to":1,"step":0.25},"formulas":[{"name":"a","y":"x^2"}]}"#))
    }

    func testParamValueIsClampedAndSnapped() throws {
        let c = try XCTUnwrap(chart(trialJSON))
        let p = c.params![0]
        XCTAssertEqual(p.snapped(1549), 1500)
        XCTAssertEqual(p.snapped(1550), 1600)
        XCTAssertEqual(p.snapped(99999), 5000)
        XCTAssertEqual(p.snapped(-3), 100)
    }

    // MARK: 几何

    func testRungUnitKeepsTallestBarCountable() {
        XCTAssertEqual(ChartGeometry.rungUnit(maxMagnitude: 38), 1)
        XCTAssertEqual(ChartGeometry.rungUnit(maxMagnitude: 7.5), 0.2)
        XCTAssertEqual(ChartGeometry.rungUnit(maxMagnitude: 1000), 50)
        XCTAssertEqual(ChartGeometry.rungUnit(maxMagnitude: 40), 1)
        XCTAssertEqual(ChartGeometry.rungUnit(maxMagnitude: 41), 2)
        XCTAssertEqual(ChartGeometry.rungUnit(maxMagnitude: 0), 1)
        for m in [3.0, 17, 99, 250, 12345, 0.07] {
            let n = m / ChartGeometry.rungUnit(maxMagnitude: m)
            XCTAssertTrue((16...40).contains(n), "\(m) → \(n) 格")
        }
    }

    func testRingTicksSumToHundred() {
        let t = ChartGeometry.ringTicks([49.0, 27.4, 13.9, 5.0, 3.2])
        XCTAssertEqual(t.reduce(0, +), 100, "最大余数法，刻度一共 100")
        XCTAssertEqual(t, [50, 28, 14, 5, 3])
        XCTAssertEqual(ChartGeometry.ringTicks([1, 0, 1]), [50, 0, 50])
        XCTAssertEqual(ChartGeometry.ringTicks([0, 0]), [0, 0])
        XCTAssertEqual(ChartGeometry.ringSegment(atTick: 0, ticks: [50, 0, 50]), 0)
        XCTAssertEqual(ChartGeometry.ringSegment(atTick: 50, ticks: [50, 0, 50]), 2)
        XCTAssertEqual(ChartGeometry.ringSegment(atTick: 99, ticks: [50, 0, 50]), 2)
    }

    func testSlotHitAndLabelStride() {
        XCTAssertEqual(ChartGeometry.slot(at: 0, plot: 0...100, count: 4), 0)
        XCTAssertEqual(ChartGeometry.slot(at: 99.9, plot: 0...100, count: 4), 3)
        XCTAssertEqual(ChartGeometry.slot(at: 50, plot: 0...100, count: 4), 2)
        XCTAssertNil(ChartGeometry.slot(at: 101, plot: 0...100, count: 4))
        XCTAssertNil(ChartGeometry.slot(at: 5, plot: 0...100, count: 0))
        XCTAssertEqual(ChartGeometry.labelStride(count: 7, width: 300, minSpacing: 36), 1)
        XCTAssertEqual(ChartGeometry.labelStride(count: 30, width: 300, minSpacing: 36), 5)
    }

    // MARK: 控件

    func testRangeOptions() {
        XCTAssertEqual(ChartControls.rangeOptions(count: 12), [])
        XCTAssertEqual(ChartControls.rangeOptions(count: 13), [7, nil])
        XCTAssertEqual(ChartControls.rangeOptions(count: 60), [7, 30, nil])
        XCTAssertEqual(ChartControls.rangeOptions(count: 120), [7, 30, 90, nil])
        let c = try! XCTUnwrap(chart(#"{"type":"line","series":[{"points":[["a",1],["b",2],["c",3]]},{"points":[["c",4],["d",5]]}]}"#))
        let cut = ChartControls.applyRange(c.series, last: 2)
        XCTAssertEqual(cut[0].points.map(\.label), ["c"], "按全部类目的最后几个取，两条系列对齐")
        XCTAssertEqual(cut[1].points.map(\.label), ["c", "d"])
        XCTAssertEqual(ChartControls.applyRange(c.series, last: nil), c.series)
    }

    func testLegendKeepsAtLeastOneSeries() {
        var hidden: Set<Int> = []
        hidden = ChartControls.toggle(hidden, series: 0, total: 2)
        XCTAssertEqual(hidden, [0])
        hidden = ChartControls.toggle(hidden, series: 1, total: 2)
        XCTAssertEqual(hidden, [0], "最后一条关不掉")
        hidden = ChartControls.toggle(hidden, series: 0, total: 2)
        XCTAssertEqual(hidden, [])
    }

    func testQuoteText() throws {
        let c = try XCTUnwrap(chart(#"{"type":"line","title":"睡眠和运动","unit":"小时","series":[{"name":"睡眠","points":[["9/18",5.4]]},{"name":"运动","points":[["9/18",1]]}]}"#))
        XCTAssertEqual(ChartControls.quote(card: c, label: "9/18", rows: ChartControls.rows(c.series, label: "9/18", unit: c.unit, hidden: [1]), params: []),
                       "图表「睡眠和运动」· 9/18：睡眠 5.4 小时")
        let t = try XCTUnwrap(chart(trialJSON))
        let s = ChartTrial.series(t, values: ChartTrial.defaults(t))
        XCTAssertEqual(ChartControls.quote(card: t, label: "第12月", rows: ChartControls.rows(s, label: "第12月", unit: t.unit, hidden: []),
                                           params: ChartControls.paramSummary(t, values: ChartTrial.defaults(t))),
                       "图表「存钱计划」· 第12月：余额 18,270 元（参数：每月存 1,500 元，年化 3 %）")
        let untitled = try XCTUnwrap(chart(#"{"type":"bar","series":[{"points":[["a",2]]}]}"#))
        XCTAssertEqual(ChartControls.quote(card: untitled, label: "a", rows: ChartControls.rows(untitled.series, label: "a", unit: "", hidden: []), params: []),
                       "图表 · a：2")
    }

    func testAutoSubtitle() throws {
        let bar = try XCTUnwrap(chart(#"{"type":"bar","unit":"小时","series":[{"points":[["a",38]]}]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(bar, series: bar.series), "一格 = 1 小时")
        let ring = try XCTUnwrap(chart(#"{"type":"pie","series":[{"points":[["a",1],["b",3]]}]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(ring, series: ring.series), "一圈 100 格 · 一格 = 1%")
        let given = try XCTUnwrap(chart(#"{"type":"bar","subtitle":"自己写的","series":[{"points":[["a",38]]}]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(given, series: given.series), "自己写的")
    }
}
