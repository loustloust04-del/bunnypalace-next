import XCTest
@testable import 记忆花园

/// 图表卡 v2 第 2 批（docs/plan-chart-cards-v2.md）：area · hbar · stack · diverging · hundred · barcode · stream ·
/// calendar · heat · candle · dumbbell
final class ChartBatch2Tests: XCTestCase {
    private func chart(_ json: String) -> ChartCard? {
        if case .chart(let c)? = ChatCard.parse(language: "card-chart", code: json) { return c }
        return nil
    }

    private func roundTrips(_ c: ChartCard, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ChatCardExtractor.cards(in: ChatCard.chart(c).blockText), [.chart(c)], file: file, line: line)
    }

    private func pts(_ n: Int, _ f: (Int) -> Double = { Double($0) }) -> String {
        (0..<n).map { #"["p\#($0)",\#(f($0))]"# }.joined(separator: ",")
    }

    // MARK: 系列类

    func testSeriesKindsParseWithTheirLimits() throws {
        for kind in ["area", "barcode"] {
            let c = try XCTUnwrap(chart(#"{"type":"\#(kind)","series":[{"points":[\#(pts(30))]}]}"#), kind)
            roundTrips(c)
        }
        XCTAssertNotNil(chart(#"{"type":"barcode","series":[{"points":[\#(pts(120))]}]}"#), "条码能放 90 天级")
        XCTAssertNil(chart(#"{"type":"barcode","series":[{"points":[\#(pts(121))]}]}"#))
        XCTAssertNil(chart(#"{"type":"bar","series":[{"points":[\#(pts(61))]}]}"#), "别的图还是最多 60")
        XCTAssertNil(chart(#"{"type":"barcode","series":[{"points":[["a",1]]},{"points":[["a",1]]}]}"#), "条码只能 1 条")

        XCTAssertNotNil(chart(#"{"type":"hbar","series":[{"points":[\#(pts(12))]},{"points":[\#(pts(12))]}]}"#))
        XCTAssertNil(chart(#"{"type":"hbar","series":[{"points":[\#(pts(13))]}]}"#), "横条 ≤12 行")
        XCTAssertNil(chart(#"{"type":"hbar","series":[{"points":[["a",1]]},{"points":[["a",1]]},{"points":[["a",1]]}]}"#))

        XCTAssertNotNil(chart(#"{"type":"stack","series":[{"name":"核心","points":[["北",18],["南",14]]},{"name":"增值","points":[["北",11],["南",9]]}]}"#))
        XCTAssertNil(chart(#"{"type":"stack","series":[{"points":[["北",-1]]}]}"#), "堆叠不能为负")

        XCTAssertNotNil(chart(#"{"type":"diverging","series":[{"points":[["a",-3],["b",5]]}]}"#))
        XCTAssertNil(chart(#"{"type":"diverging","series":[{"points":[\#(pts(17))]}]}"#), "正负条 ≤16 行")

        XCTAssertNotNil(chart(#"{"type":"hundred","series":[{"points":[["a",49],["b",27],["c",24]]}]}"#))
        XCTAssertNil(chart(#"{"type":"hundred","series":[{"points":[\#(pts(7, { _ in 1 }))]}]}"#), "百格 ≤6 类")
        XCTAssertNil(chart(#"{"type":"hundred","series":[{"points":[["a",0]]}]}"#))

        let five = (0..<5).map { i in #"{"name":"s\#(i)","points":[["一",1],["二",2]]}"# }.joined(separator: ",")
        XCTAssertNotNil(chart(#"{"type":"stream","series":[\#(five)]}"#), "河流 2–5 条")
        XCTAssertNil(chart(#"{"type":"stream","series":[{"points":[["一",1]]}]}"#))
        XCTAssertNil(chart(#"{"type":"stream","series":[{"points":[["一",1]]},{"points":[["一",-1]]}]}"#))
    }

    func testTrialOnlyOnBarLineArea() {
        let trial = #""params":[],"x":{"from":1,"to":3},"formulas":[{"name":"a","y":"x"}]"#
        XCTAssertNotNil(chart(#"{"type":"area",\#(trial)}"#))
        XCTAssertNil(chart(#"{"type":"stack",\#(trial)}"#))
        XCTAssertNil(chart(#"{"type":"barcode",\#(trial)}"#))
    }

    // MARK: 日历

    func testCalendarParseAndLayout() throws {
        let c = try XCTUnwrap(chart(#"{"type":"calendar","title":"一年部署","days":[["2026-01-01",3],["2026-01-05",0],["2026-02-01",7]]}"#))
        XCTAssertEqual(c.days?.count, 3)
        roundTrips(c)
        XCTAssertNil(chart(#"{"type":"calendar","days":[["2026-13-01",1]]}"#), "日期不合法")
        XCTAssertNil(chart(#"{"type":"calendar","days":[["2026-01-01",1],["2026-01-01",2]]}"#), "重复日期")
        XCTAssertNil(chart(#"{"type":"calendar","days":[["2026-01-01",-1]]}"#))
        XCTAssertNil(chart(#"{"type":"calendar","days":[]}"#))
        // 2026-01-01 是周四：周一起算第 0 行 → 周四第 3 行；同一周的周一（12-29）那一列是第 0 列
        let cells = ChartCalendar.cells(c.days!)
        XCTAssertEqual(cells.first?.row, 3)
        XCTAssertEqual(cells.first?.column, 0)
        XCTAssertEqual(cells.first { $0.day.date == "2026-01-05" }?.column, 1, "下周一换列")
        XCTAssertEqual(cells.first { $0.day.date == "2026-01-05" }?.row, 0)
        XCTAssertEqual(ChartCalendar.columnCount(cells), 5)
    }

    // MARK: 点阵热力

    func testHeatParse() throws {
        let c = try XCTUnwrap(chart(#"{"type":"heat","rows":["周一","周二"],"cols":["9点","10点","11点"],"values":[[1,4,9],[0,2,3]]}"#))
        roundTrips(c)
        XCTAssertNil(chart(#"{"type":"heat","rows":["a"],"cols":["x","y"],"values":[[1]]}"#), "格数对不上")
        XCTAssertNil(chart(#"{"type":"heat","rows":["a","b","c","d","e","f","g","h","i"],"cols":["x"],"values":[[1],[1],[1],[1],[1],[1],[1],[1],[1]]}"#), "≤8 行")
        XCTAssertNil(chart(#"{"type":"heat","rows":["a"],"cols":["x"],"values":[[-1]]}"#))
        XCTAssertNil(chart(#"{"type":"heat","rows":["a","a"],"cols":["x"],"values":[[1],[2]]}"#), "行名重复")
        // 点的面积正比于值（半径开方）
        XCTAssertEqual(ChartGeometry.areaRadius(9, max: 9, maxRadius: 6), 6)
        XCTAssertEqual(ChartGeometry.areaRadius(2.25, max: 9, maxRadius: 6), 3, accuracy: 1e-9)
        XCTAssertEqual(ChartGeometry.areaRadius(0, max: 9, maxRadius: 6), 0)
    }

    // MARK: K 线

    func testCandleParse() throws {
        let c = try XCTUnwrap(chart(#"{"type":"candle","candles":[["周一",10,12,9,11],["周二",11,11.5,8,8.5]]}"#))
        XCTAssertEqual(c.candles?.first?.rising, true)
        XCTAssertEqual(c.candles?.last?.rising, false)
        roundTrips(c)
        XCTAssertNil(chart(#"{"type":"candle","candles":[["周一",10,9,8,11]]}"#), "高要不低于开收")
        XCTAssertNil(chart(#"{"type":"candle","candles":[["周一",10,12,10.5,11]]}"#), "低要不高于开收")
        XCTAssertNil(chart(#"{"type":"candle","candles":[["a",1,2,0,1],["a",1,2,0,1]]}"#))
    }

    // MARK: 哑铃

    func testDumbbellParseAndBeads() throws {
        let c = try XCTUnwrap(chart(#"{"type":"dumbbell","unit":"分钟","pairNames":["改版前","改版后"],"pairs":[["邀请",14,6],["导入",26,13]]}"#))
        XCTAssertEqual(c.pairs?.count, 2)
        roundTrips(c)
        XCTAssertNil(chart(#"{"type":"dumbbell","pairs":[\#((0..<9).map { #"["r\#($0)",1,2]"# }.joined(separator: ","))]}"#), "≤8 行")
        XCTAssertNil(chart(#"{"type":"dumbbell","pairNames":["只一个"],"pairs":[["a",1,2]]}"#))
        XCTAssertEqual(ChartGeometry.beads(gap: 8, unit: 1), 7, "两端之间的串珠：真单位，不含两端")
        XCTAssertEqual(ChartGeometry.beads(gap: 100, unit: 1), 20, "最多 20 颗")
        XCTAssertEqual(ChartGeometry.beads(gap: 0, unit: 1), 0)
    }

    // MARK: 读数（选中 / 问问这个 / 读屏）

    func testReadingsPerKind() throws {
        let stack = try XCTUnwrap(chart(#"{"type":"stack","unit":"万","series":[{"name":"核心","points":[["北",18]]},{"name":"增值","points":[["北",11]]}]}"#))
        XCTAssertEqual(ChartReadings.rows(stack, series: stack.series, label: "北", hidden: []).map(\.text), ["18 万", "11 万", "29 万"])
        XCTAssertEqual(ChartReadings.rows(stack, series: stack.series, label: "北", hidden: []).last?.name, "合计")

        let hundred = try XCTUnwrap(chart(#"{"type":"hundred","series":[{"points":[["a",1],["b",3]]}]}"#))
        XCTAssertEqual(ChartReadings.rows(hundred, series: hundred.series, label: "b", hidden: []).map(\.text), ["3（75 格）"])

        let cal = try XCTUnwrap(chart(#"{"type":"calendar","unit":"次","days":[["2026-01-01",3]]}"#))
        XCTAssertEqual(ChartReadings.labels(cal, series: []), ["2026-01-01"])
        XCTAssertEqual(ChartReadings.rows(cal, series: [], label: "2026-01-01", hidden: []).map(\.text), ["3 次"])

        let heat = try XCTUnwrap(chart(#"{"type":"heat","rows":["周一"],"cols":["9点","10点"],"values":[[1,4]]}"#))
        XCTAssertEqual(ChartReadings.labels(heat, series: []), ["周一 · 9点", "周一 · 10点"])
        XCTAssertEqual(ChartReadings.rows(heat, series: [], label: "周一 · 10点", hidden: []).map(\.text), ["4"])

        let candle = try XCTUnwrap(chart(#"{"type":"candle","candles":[["周一",10,12,9,11]]}"#))
        XCTAssertEqual(ChartReadings.rows(candle, series: [], label: "周一", hidden: []).map(\.text), ["开 10 · 高 12 · 低 9 · 收 11"])

        let bell = try XCTUnwrap(chart(#"{"type":"dumbbell","unit":"分钟","pairNames":["改版前","改版后"],"pairs":[["邀请",14,6]]}"#))
        XCTAssertEqual(ChartReadings.rows(bell, series: [], label: "邀请", hidden: []).map(\.text), ["改版前 14 分钟 → 改版后 6 分钟"])
        let plain = try XCTUnwrap(chart(#"{"type":"dumbbell","pairs":[["a",1,2]]}"#))
        XCTAssertEqual(ChartReadings.rows(plain, series: [], label: "a", hidden: []).map(\.text), ["之前 1 → 之后 2"])
    }

    func testAutoSubtitles() throws {
        let hundred = try XCTUnwrap(chart(#"{"type":"hundred","series":[{"points":[["a",1],["b",3]]}]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(hundred, series: hundred.series), "一百个点 · 一点 = 1%")
        let hbar = try XCTUnwrap(chart(#"{"type":"hbar","unit":"次","series":[{"points":[["a",38]]}]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(hbar, series: hbar.series), "一根刻度 = 1 次")
        let candle = try XCTUnwrap(chart(#"{"type":"candle","candles":[["周一",10,12,9,11]]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(candle, series: []), "空心 = 涨 · 实心 = 跌")
        let bell = try XCTUnwrap(chart(#"{"type":"dumbbell","pairs":[["a",1,9]]}"#))
        XCTAssertEqual(ChartGeometry.autoSubtitle(bell, series: []), "空心 = 之前 · 实心 = 之后 · 中间一颗 = 1")
    }
}
