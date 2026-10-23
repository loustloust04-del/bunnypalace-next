import Foundation
import SwiftStreamingMarkdown

/// 待办卡（docs/research-chat-cards.md §4.5）。字段宽松解码：模型漏写 title / done 也能显示。
/// §14：可选 date（yyyy-MM-dd）= 点「加入我的待办」时排在哪天，没写就是今天；没有时编码与旧卡逐字一样
struct TodoCard: Codable, Equatable {
    struct Item: Codable, Equatable {
        var text: String
        var done: Bool

        init(text: String, done: Bool) {
            self.text = text
            self.done = done
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        }
    }

    var id: String?
    var title: String
    var items: [Item]
    var date: String?

    init(id: String?, title: String, items: [Item], date: String? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        date = (try? c.decodeIfPresent(String.self, forKey: .date)).flatMap { $0 }
            .flatMap { TodoManager.isValidDayKey($0) ? $0 : nil }   // 写坏了当没写，卡片照样能用
    }

    /// ➕ 新建：每行一项，空行忽略；一项都没有 → nil。
    static func make(title: String, lines: [String], avoiding taken: Set<String> = []) -> TodoCard? {
        let items = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { Item(text: $0, done: false) }
        guard !items.isEmpty else { return nil }
        return TodoCard(id: ChatCard.newId(prefix: "t", avoiding: taken),
                        title: title.trimmingCharacters(in: .whitespaces), items: items)
    }
}

/// 骰子卡（research-chat-cards §8.1）：数字骰与选项抽签二选一
struct DiceCard: Codable, Equatable {
    var id: String?
    var title: String
    var dice: String?
    var options: [String]?
    var result: DiceResult?

    init(id: String?, title: String, dice: String?, options: [String]?, result: DiceResult?) {
        self.id = id
        self.title = title
        self.dice = dice
        self.options = options
        self.result = result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        dice = try c.decodeIfPresent(String.self, forKey: .dice)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        result = try c.decodeIfPresent(DiceResult.self, forKey: .result)
    }

    /// 抽签结果下标（模型写错越界时为 nil）
    var validPick: Int? {
        guard let pick = result?.pick, let options, options.indices.contains(pick) else { return nil }
        return pick
    }
}

struct DiceResult: Codable, Equatable {
    var rolls: [Int]?
    var total: Int?
    var pick: Int?
}

/// 计时器卡（§8.2）：倒计时；autoStart 缺省 true
struct TimerCard: Codable, Equatable {
    var id: String?
    var title: String
    var seconds: Int
    var autoStart: Bool

    init(id: String?, title: String, seconds: Int, autoStart: Bool) {
        self.id = id
        self.title = title
        self.seconds = seconds
        self.autoStart = autoStart
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        seconds = try c.decode(Int.self, forKey: .seconds)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        guard (1...86_400).contains(seconds) else {
            throw DecodingError.dataCorruptedError(forKey: .seconds, in: c, debugDescription: "seconds out of range")
        }
    }

    var displayTitle: String { title.isEmpty ? "计时器" : title }

    var durationText: String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) 小时") }
        if m > 0 { parts.append("\(m) 分" + (s == 0 && h == 0 ? "钟" : "")) }
        if s > 0 { parts.append("\(s) 秒") }
        return parts.joined(separator: " ")
    }

    var finishedMessage: String { "⏰ 计时结束：\(displayTitle)（\(durationText)）" }
}

/// 图表卡（research-chat-cards §10.1；v2 docs/plan-chart-cards-v2.md）。点写成 [标签, 数值]；不合法一律解码失败 → 退回代码块。
/// v2：四件套（title 写结论 / subtitle / source）、donut、试算（params + x + formulas，series 由公式现算）。
struct ChartCard: Codable, Equatable {
    enum Kind: String, Codable {
        case bar, line, pie, donut
        // 第 2 批（docs/plan-chart-cards-v2.md）
        case area, hbar, stack, diverging, hundred, barcode, stream, calendar, heat, candle, dumbbell
        // 第 3 批
        case scatter, histogram, box, waterfall, gauge, funnel, treemap

        /// 刻度环（pie 是老名字）
        var isRing: Bool { self == .pie || self == .donut }
        /// 按顺序排的类目（能切范围）
        var isOrdered: Bool { [.bar, .line, .area, .barcode].contains(self) }
        /// 能试算（params + x + formulas）
        var supportsTrial: Bool { [.bar, .line, .area].contains(self) }
        /// 数据在 series 里的图
        var usesSeries: Bool { ![.calendar, .heat, .candle, .dumbbell, .scatter, .box, .gauge, .treemap].contains(self) }
        /// 每条系列最多几个点
        var pointLimit: Int { self == .barcode ? 120 : 60 }
    }

    /// 日历热力的一天：["yyyy-MM-dd", 值]
    struct Day: Codable, Equatable {
        var date: String
        var value: Double

        init(date: String, value: Double) {
            self.date = date
            self.value = value
        }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            date = try c.decode(String.self)
            value = try c.decode(Double.self)
            guard c.isAtEnd, value.isFinite, value >= 0, Self.parse(date) != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad day"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(date)
            try c.encode(value)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd"
            f.isLenient = false
            return f
        }()

        /// 严格 yyyy-MM-dd（UTC 零点）；2026-13-01 这种不认
        static func parse(_ s: String) -> Date? {
            guard s.count == 10, let d = formatter.date(from: s), formatter.string(from: d) == s else { return nil }
            return d
        }
    }

    /// K 线一根：[标签, 开, 高, 低, 收]
    struct Candle: Codable, Equatable {
        var label: String
        var open: Double
        var high: Double
        var low: Double
        var close: Double

        var rising: Bool { close >= open }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            label = try c.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
            open = try c.decode(Double.self)
            high = try c.decode(Double.self)
            low = try c.decode(Double.self)
            close = try c.decode(Double.self)
            guard c.isAtEnd, !label.isEmpty, [open, high, low, close].allSatisfy(\.isFinite),
                  high >= Swift.max(open, close), low <= Swift.min(open, close) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad candle"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(label)
            for v in [open, high, low, close] { try c.encode(v) }
        }
    }

    /// 散点一个：[名字, x, y]
    struct XY: Codable, Equatable {
        var label: String
        var x: Double
        var y: Double

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            label = try c.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
            x = try c.decode(Double.self)
            y = try c.decode(Double.self)
            guard c.isAtEnd, !label.isEmpty, x.isFinite, y.isFinite else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad xy"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(label)
            try c.encode(x)
            try c.encode(y)
        }
    }

    /// 箱线一组：[组名, [原始值…]]（≤200 个）
    struct BoxGroup: Codable, Equatable {
        var name: String
        var values: [Double]

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            name = try c.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
            values = try c.decode([Double].self)
            guard c.isAtEnd, !name.isEmpty, (1...200).contains(values.count), values.allSatisfy(\.isFinite) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad box"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(name)
            try c.encode(values)
        }
    }

    /// 矩形树一组：{"name", "items": [[标签, 值]]}
    struct TreeGroup: Codable, Equatable {
        var name: String
        var items: [Point]
    }

    /// 前后哑铃一行：[标签, 前, 后]
    struct Pair: Codable, Equatable {
        var label: String
        var before: Double
        var after: Double

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            label = try c.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
            before = try c.decode(Double.self)
            after = try c.decode(Double.self)
            guard c.isAtEnd, !label.isEmpty, before.isFinite, after.isFinite else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad pair"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(label)
            try c.encode(before)
            try c.encode(after)
        }
    }

    struct Point: Codable, Equatable {
        var label: String
        var value: Double

        init(label: String, value: Double) {
            self.label = label
            self.value = value
        }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            label = try c.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines)
            value = try c.decode(Double.self)
            guard c.isAtEnd, !label.isEmpty, value.isFinite else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad point"))
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(label)
            try c.encode(value)
        }
    }

    struct Series: Codable, Equatable {
        var name: String
        var points: [Point]

        init(name: String, points: [Point]) {
            self.name = name
            self.points = points
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try c.decodeIfPresent(String.self, forKey: .name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            points = try c.decode([Point].self, forKey: .points)
            // 同一条系列里标签就是点的身份：重复 → 选中 / 取值有歧义，拒收（R5 E1）
            // 单条上限放到 120（条码用）；其余图在卡层收回 60
            guard (1...120).contains(points.count), Set(points.map(\.label)).count == points.count else {
                throw DecodingError.dataCorruptedError(forKey: .points, in: c, debugDescription: "points 1...60, unique labels")
            }
        }
    }

    /// 试算的一个滑块（≤4 个）
    struct Param: Codable, Equatable {
        var key: String
        var label: String
        var min: Double
        var max: Double
        var step: Double
        var value: Double
        var unit: String?

        /// 英文字母 / 下划线开头，≤16 位；不能叫 x、不能撞函数名
        static func isValidKey(_ key: String) -> Bool {
            guard let first = key.first, (1...16).contains(key.count), first.isASCII, first.isLetter || first == "_" else { return false }
            return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                && key != "x" && ChartFormula.functions[key] == nil
        }

        var isValid: Bool {
            Self.isValidKey(key)
                && [min, max, step, value].allSatisfy(\.isFinite) && min < max && step > 0
                && (max - min) / step <= 10_000 && !label.trimmingCharacters(in: .whitespaces).isEmpty
        }

        /// 夹到范围内、对齐步长
        func snapped(_ v: Double) -> Double {
            let n = ((Swift.min(Swift.max(v, min), max) - min) / step).rounded(.toNearestOrAwayFromZero)
            return Swift.min(min + n * step, max)
        }
    }

    /// 试算的横轴：from…to 每隔 step 一个点；label 里的 {x} 换成数
    struct XAxis: Codable, Equatable {
        var from: Double
        var to: Double
        var step: Double?
        var label: String?

        var stepValue: Double { step ?? 1 }

        var values: [Double] {
            let s = stepValue
            guard from.isFinite, to.isFinite, s.isFinite, s > 0, to >= from else { return [] }
            let n = Int(((to - from) / s + 1e-9).rounded(.down)) + 1
            guard n <= 60 else { return [] }
            return (0..<n).map { from + Double($0) * s }
        }
    }

    struct Formula: Codable, Equatable {
        var name: String
        var y: String
    }

    var id: String?
    var title: String
    var type: Kind
    var unit: String
    /// 试算卡里是空的（数由公式现算，见 ChartTrial）
    var series: [Series]
    var subtitle: String = ""
    var source: String = ""
    var params: [Param]?
    var x: XAxis?
    var formulas: [Formula]?
    // 第 2 批：不走 series 的图
    var days: [Day]?
    var rows: [String]?
    var cols: [String]?
    var values: [[Double]]?
    var candles: [Candle]?
    var pairs: [Pair]?
    var pairNames: [String]?
    // 第 3 批（box 和 treemap 都叫 groups，按 type 分开存）
    var scatter: [XY]?
    var xLabel: String?
    var yLabel: String?
    var boxes: [BoxGroup]?
    var tree: [TreeGroup]?
    var total: String?
    var value: Double?
    var target: Double?

    var isTrial: Bool { formulas != nil }

    init(id: String?, title: String, type: Kind, unit: String, series: [Series]) {
        self.id = id
        self.title = title
        self.type = type
        self.unit = unit
        self.series = series
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, type, unit, series, subtitle, source, params, x, formulas
        case days, rows, cols, values, candles, pairs, pairNames
        case points, xLabel, yLabel, groups, total, value, target
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ k: CodingKeys) throws -> String {
            (try c.decodeIfPresent(String.self, forKey: k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try text(.title)
        type = try c.decode(Kind.self, forKey: .type)
        unit = try text(.unit)
        subtitle = try text(.subtitle)
        source = try text(.source)
        formulas = try c.decodeIfPresent([Formula].self, forKey: .formulas)
        if let formulas {
            // 试算：环不能试算；x 必须给、点数 ≤60；参数 ≤4 个、名字不重；每条公式只用 x 和参数名
            let params = try c.decodeIfPresent([Param].self, forKey: .params) ?? []
            let x = try c.decodeIfPresent(XAxis.self, forKey: .x)
            let keys = Set(params.map(\.key))
            guard type.supportsTrial, let x, !x.values.isEmpty, (0...4).contains(params.count), keys.count == params.count,
                  params.allSatisfy(\.isValid), (1...4).contains(formulas.count),
                  formulas.allSatisfy({ ChartFormula($0.y, variables: keys.union(["x"])) != nil })
            else { throw DecodingError.dataCorruptedError(forKey: .formulas, in: c, debugDescription: "bad trial") }
            self.params = params
            self.x = x
            series = []
            return
        }
        func bad(_ why: String) -> DecodingError { .dataCorruptedError(forKey: .type, in: c, debugDescription: why) }
        switch type {
        case .calendar:
            let days = try c.decode([Day].self, forKey: .days)
            guard (1...370).contains(days.count), Set(days.map(\.date)).count == days.count else { throw bad("days") }
            self.days = days
            series = []
            return
        case .heat:
            let rows = try c.decode([String].self, forKey: .rows).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let cols = try c.decode([String].self, forKey: .cols).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let values = try c.decode([[Double]].self, forKey: .values)
            guard (1...8).contains(rows.count), (1...24).contains(cols.count),
                  Set(rows).count == rows.count, Set(cols).count == cols.count, !rows.contains(""), !cols.contains(""),
                  values.count == rows.count, values.allSatisfy({ $0.count == cols.count && $0.allSatisfy { $0.isFinite && $0 >= 0 } })
            else { throw bad("heat") }
            (self.rows, self.cols, self.values) = (rows, cols, values)
            series = []
            return
        case .candle:
            let candles = try c.decode([Candle].self, forKey: .candles)
            guard (1...60).contains(candles.count), Set(candles.map(\.label)).count == candles.count else { throw bad("candles") }
            self.candles = candles
            series = []
            return
        case .dumbbell:
            let pairs = try c.decode([Pair].self, forKey: .pairs)
            let names = try c.decodeIfPresent([String].self, forKey: .pairNames)
            guard (1...8).contains(pairs.count), Set(pairs.map(\.label)).count == pairs.count, names == nil || names?.count == 2 else { throw bad("pairs") }
            self.pairs = pairs
            pairNames = names
            series = []
            return
        case .scatter:
            let pts = try c.decode([XY].self, forKey: .points)
            guard (1...40).contains(pts.count), Set(pts.map(\.label)).count == pts.count else { throw bad("scatter") }
            scatter = pts
            xLabel = (try? c.decodeIfPresent(String.self, forKey: .xLabel)).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            yLabel = (try? c.decodeIfPresent(String.self, forKey: .yLabel)).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            series = []
            return
        case .box:
            let groups = try c.decode([BoxGroup].self, forKey: .groups)
            guard (1...6).contains(groups.count), Set(groups.map(\.name)).count == groups.count else { throw bad("box") }
            boxes = groups
            series = []
            return
        case .treemap:
            let groups = try c.decode([TreeGroup].self, forKey: .groups)
            let leaves = groups.flatMap(\.items)
            guard (1...6).contains(groups.count), groups.allSatisfy({ !$0.items.isEmpty && !$0.name.isEmpty }), leaves.count <= 30,
                  leaves.allSatisfy({ $0.value > 0 }), Set(groups.map(\.name)).count == groups.count else { throw bad("treemap") }
            tree = groups
            series = []
            return
        case .gauge:
            let v = try c.decode(Double.self, forKey: .value), t = try c.decode(Double.self, forKey: .target)
            guard v.isFinite, t.isFinite, v >= 0, t > 0 else { throw bad("gauge") }
            (value, target) = (v, t)
            series = []
            return
        default:
            break
        }
        series = try c.decode([Series].self, forKey: .series)
        let counts: ClosedRange<Int> = switch type {
        case .pie, .donut, .barcode, .diverging, .hundred, .histogram, .waterfall, .funnel: 1...1
        case .hbar: 1...2
        case .stream: 2...5
        default: 1...4
        }
        guard counts.contains(series.count), series.allSatisfy({ $0.points.count <= type.pointLimit }) else {
            throw DecodingError.dataCorruptedError(forKey: .series, in: c, debugDescription: "series count")
        }
        let all = series.flatMap { $0.points.map(\.value) }
        let categoryCount = Set(series.flatMap { $0.points.map(\.label) }).count
        switch type {
        case .pie, .donut, .hundred:
            let total = all.reduce(0, +)
            guard all.allSatisfy({ $0 >= 0 }), total.isFinite, total > 0 else {   // 和也要有限（R5 E2）
                throw DecodingError.dataCorruptedError(forKey: .series, in: c, debugDescription: "pie values")
            }
            if type == .hundred, categoryCount > 6 { throw bad("hundred ≤6") }
        case .hbar: if categoryCount > 12 { throw bad("hbar ≤12") }
        case .stack: if categoryCount > 12 || all.contains(where: { $0 < 0 }) { throw bad("stack") }
        case .diverging: if categoryCount > 16 { throw bad("diverging ≤16") }
        case .stream: if all.contains(where: { $0 < 0 }) { throw bad("stream ≥0") }
        case .histogram: if categoryCount > 30 || all.contains(where: { $0 < 0 }) { throw bad("histogram") }
        case .funnel: if categoryCount > 8 || all.contains(where: { $0 < 0 }) || (all.first ?? 0) <= 0 { throw bad("funnel") }
        case .waterfall:
            let name = (try c.decodeIfPresent(String.self, forKey: .total))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = Set(series[0].points.map(\.label))
            guard categoryCount <= 10, name.map({ !labels.contains($0) }) ?? true else { throw bad("waterfall") }
            total = name.flatMap { $0.isEmpty ? nil : $0 }
        default: break
        }
    }

    /// 只写有内容的字段：老卡往返后不凭空长出 subtitle / params
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        if !title.isEmpty { try c.encode(title, forKey: .title) }
        try c.encode(type, forKey: .type)
        if !unit.isEmpty { try c.encode(unit, forKey: .unit) }
        if !subtitle.isEmpty { try c.encode(subtitle, forKey: .subtitle) }
        if !source.isEmpty { try c.encode(source, forKey: .source) }
        if isTrial {
            try c.encode(params ?? [], forKey: .params)
            try c.encodeIfPresent(x, forKey: .x)
            try c.encodeIfPresent(formulas, forKey: .formulas)
        } else if type.usesSeries {
            try c.encode(series, forKey: .series)
        } else {
            try c.encodeIfPresent(days, forKey: .days)
            try c.encodeIfPresent(rows, forKey: .rows)
            try c.encodeIfPresent(cols, forKey: .cols)
            try c.encodeIfPresent(values, forKey: .values)
            try c.encodeIfPresent(candles, forKey: .candles)
            try c.encodeIfPresent(pairs, forKey: .pairs)
            try c.encodeIfPresent(pairNames, forKey: .pairNames)
            try c.encodeIfPresent(scatter, forKey: .points)
            try c.encodeIfPresent(xLabel, forKey: .xLabel)
            try c.encodeIfPresent(yLabel, forKey: .yLabel)
            if let boxes { try c.encode(boxes, forKey: .groups) }
            if let tree { try c.encode(tree, forKey: .groups) }
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(target, forKey: .target)
        }
        if type == .waterfall { try c.encodeIfPresent(total, forKey: .total) }
    }
}

/// 音乐卡（§10.2，占位）。字段存原文（往返不变）；合规性在读取时判断，不合规 / 类型错都当作没给（R5 E3）。
struct MusicCard: Codable, Equatable {
    var id: String?
    var title: String
    var artist: String
    var cover: String?
    var url: String?
    var link: String?

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav"]

    init(id: String?, title: String, artist: String, cover: String?, url: String?, link: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.cover = cover
        self.url = url
        self.link = link
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        artist = ((try? c.decodeIfPresent(String.self, forKey: .artist)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cover = (try? c.decodeIfPresent(String.self, forKey: .cover)) ?? nil
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        link = (try? c.decodeIfPresent(String.self, forKey: .link)) ?? nil
        guard !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "title required")
        }
    }

    private static func web(_ raw: String?, schemes: Set<String>) -> URL? {
        guard let raw, let u = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), schemes.contains(scheme), u.host?.isEmpty == false else { return nil }
        return u
    }

    /// 自动联网（播放 / 拉封面）只对公网目标，同外链卡（R5 U8）
    var playableURL: URL? {
        guard let u = Self.web(url, schemes: ["https"]), LinkPreviewStore.isPublicTarget(u),
              Self.audioExtensions.contains(u.pathExtension.lowercased()) else { return nil }
        return u
    }
    var linkURL: URL? { Self.web(link, schemes: ["http", "https"]) }
    /// `builtin:slowtide` → 内置曲（本地合成，不联网）
    var builtinTrack: BuiltinTrack? { BuiltinTrack.parse(url) }
    /// 内置曲不信模型写的标题 / 歌手，一律显示它自己（终审 I4：别拿慢潮冒充点名的歌）
    var displayTitle: String { builtinTrack?.title ?? title }
    var displaySubtitle: String? { builtinTrack?.subtitle ?? (artist.isEmpty ? nil : artist) }
    var coverURL: URL? { Self.web(cover, schemes: ["https"]).flatMap { LinkPreviewStore.isPublicTarget($0) ? $0 : nil } }
}

/// 提问卡（docs/plan-ask-inline.md）：有 options = 选项模式（单选 / 多选），没有 = 问答模式。
/// question 必须有；答案写回卡上：picked（选中的下标）或 answer。secure = 加密问答：answer 只放 {{secret:…}} 占位（docs/plan-secure-ask.md）。
/// 有 fields（没 options）= 表单模式：一张卡几个框，答案写回各字段的 answer（docs/plan-ask-form.md）。
struct AskCard: Codable, Equatable {
    var id: String?
    var question: String
    var options: [String]?
    var multi: Bool
    var placeholder: String?
    var picked: [Int]?
    var answer: String?
    var secure: Bool
    var fields: [Field]?
    /// 加密卡的网址（docs/plan-secure-ask-sheet.md）：只做显示（小卡副标题 + 弹单网站行），缺省不编码
    var site: String?

    static let optionRange = 2...6
    static let fieldRange = 1...6

    /// 表单的一项；label 为空不在解码时拦，交给 problem 提示。
    /// 类型（粟粟 10-03 表单卡）：文字 / 单选 / 多选 / 日期 / 数字 / 滑块；没写 type 就是文字（老卡不变）
    struct Field: Codable, Equatable {
        enum Kind: String, Codable, Equatable {
            case text, single, multi, date, number, slider
        }

        /// `default` 可能写成文字、数字或文字数组（多选）
        enum Default: Codable, Equatable {
            case text(String), number(Double), list([String])

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let n = try? c.decode(Double.self) { self = .number(n) }
                else if let t = try? c.decode(String.self) { self = .text(t) }
                else { self = .list(try c.decode([String].self)) }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .text(let t): try c.encode(t)
                case .number(let n): try c.encode(n)
                case .list(let l): try c.encode(l)
                }
            }
        }

        var label: String
        var placeholder: String?
        var secure: Bool
        var answer: String?
        var kind: Kind = .text
        var options: [String]?
        var min: Double?
        var max: Double?
        var step: Double?
        var unit: String?
        var defaultValue: Default?
        /// 没写 = 必填（和以前全部必填一致）
        var required = true
        /// 单选 / 多选的答案（选项下标）
        var picked: [Int]?

        static let optionRange = 2...12

        private enum CodingKeys: String, CodingKey {
            case label, placeholder, secure, answer, kind = "type", options, min, max, step, unit
            case defaultValue = "default", required, picked
        }

        init(label: String, placeholder: String? = nil, secure: Bool = false, answer: String? = nil) {
            self.label = label
            self.placeholder = placeholder
            self.secure = secure
            self.answer = answer
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = (try c.decodeIfPresent(String.self, forKey: .label) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
            secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false
            answer = try c.decodeIfPresent(String.self, forKey: .answer)
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(Kind.init(rawValue:)) } ?? .text   // 不认识的类型当文字
            options = try? c.decodeIfPresent([String].self, forKey: .options)
            min = try? c.decodeIfPresent(Double.self, forKey: .min)
            max = try? c.decodeIfPresent(Double.self, forKey: .max)
            step = try? c.decodeIfPresent(Double.self, forKey: .step)
            unit = try? c.decodeIfPresent(String.self, forKey: .unit)
            defaultValue = try? c.decodeIfPresent(Default.self, forKey: .defaultValue)
            required = (try? c.decodeIfPresent(Bool.self, forKey: .required)) ?? true
            picked = try? c.decodeIfPresent([Int].self, forKey: .picked)
            if secure { kind = .text }   // 加密只有文字框
        }

        /// 缺省值不写出去：文字项不写 type，必填不写 required，secure 只在 true 时写
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(label, forKey: .label)
            if kind != .text { try c.encode(kind, forKey: .kind) }
            try c.encodeIfPresent(options, forKey: .options)
            try c.encodeIfPresent(min, forKey: .min)
            try c.encodeIfPresent(max, forKey: .max)
            try c.encodeIfPresent(step, forKey: .step)
            try c.encodeIfPresent(unit, forKey: .unit)
            try c.encodeIfPresent(defaultValue, forKey: .defaultValue)
            if !required { try c.encode(required, forKey: .required) }
            try c.encodeIfPresent(placeholder, forKey: .placeholder)
            if secure { try c.encode(secure, forKey: .secure) }
            try c.encodeIfPresent(answer, forKey: .answer)
            try c.encodeIfPresent(picked, forKey: .picked)
        }

        var isChoice: Bool { kind == .single || kind == .multi }

        /// 这一项写坏了：选项个数、滑块范围
        var problem: String? {
            if isChoice, !Self.optionRange.contains(options?.count ?? 0) { return "「\(label)」的选项要 2–12 个" }
            if kind == .slider, min == nil || max == nil { return "「\(label)」的滑块要写最小和最大值" }
            if kind == .number || kind == .slider, let min, let max, min >= max { return "「\(label)」的最小值要比最大值小" }
            return nil
        }

        /// 填表时的初值：已答的 → 默认 → 空（滑块从最小值起；date 默认可写 today）
        func initialValue(today: String) -> FieldValue {
            if isChoice {
                if let picked { return .picked(picked.filter { (options ?? []).indices.contains($0) }) }
                let wanted: [String]
                switch defaultValue {
                case .text(let t)?: wanted = [t]
                case .list(let l)?: wanted = l
                default: wanted = []
                }
                return .picked(wanted.compactMap { options?.firstIndex(of: $0) })
            }
            if let answer { return .text(answer) }
            switch (kind, defaultValue) {
            case (.date, .text(let t)?): return .text(t.lowercased() == "today" ? today : t)
            case (_, .number(let n)?): return .text(Self.format(n))
            case (_, .text(let t)?): return .text(t)
            case (.slider, _): return .text(min.map(Self.format) ?? "")
            default: return .text("")
            }
        }

        /// 填的值有什么问题（nil = 没问题）
        func problem(for value: FieldValue) -> String? {
            switch value {
            case .picked(let ix):
                if ix.isEmpty { return required ? "必填" : nil }
                if kind == .single, ix.count > 1 { return "只能选一个" }
                return nil
            case .text(let raw):
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return required ? "必填" : nil }
                switch kind {
                case .number, .slider:
                    guard let n = Double(t) else { return "要填数字" }
                    if let min, let max, !(min...max).contains(n) { return "要在 \(Self.format(min))–\(Self.format(max)) 之间" }
                    if let min, n < min { return "不能小于 \(Self.format(min))" }
                    if let max, n > max { return "不能大于 \(Self.format(max))" }
                case .date:
                    if !TodoManager.isValidDayKey(t) { return "日期格式不对" }
                default: break
                }
                return nil
            }
        }

        /// 500 → "500"，2.5 → "2.5"
        static func format(_ n: Double) -> String {
            n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        }
    }

    /// 表单一项填的值：文字类（文字 / 日期 / 数字 / 滑块）或选中的下标
    enum FieldValue: Equatable {
        case text(String)
        case picked([Int])
    }

    private enum CodingKeys: String, CodingKey {
        case id, question, options, multi, placeholder, picked, answer, secure, fields, site
    }

    init(id: String?, question: String, options: [String]? = nil, multi: Bool = false, placeholder: String? = nil,
         picked: [Int]? = nil, answer: String? = nil, secure: Bool = false, fields: [Field]? = nil, site: String? = nil) {
        self.id = id
        self.question = question
        self.options = options
        self.multi = multi
        self.placeholder = placeholder
        self.picked = picked
        self.answer = answer
        self.secure = secure
        self.fields = fields
        self.site = site
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question).trimmingCharacters(in: .whitespacesAndNewlines)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        multi = try c.decodeIfPresent(Bool.self, forKey: .multi) ?? false
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        picked = try c.decodeIfPresent([Int].self, forKey: .picked)
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        fields = try c.decodeIfPresent([Field].self, forKey: .fields)
        site = try? c.decodeIfPresent(String.self, forKey: .site)
        guard !question.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .question, in: c, debugDescription: "question required")
        }
    }

    /// 缺省值不写出去：问答卡不带 multi，secure 只在 true 时写
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(question, forKey: .question)
        try c.encodeIfPresent(options, forKey: .options)
        if options != nil || multi { try c.encode(multi, forKey: .multi) }
        try c.encodeIfPresent(placeholder, forKey: .placeholder)
        try c.encodeIfPresent(picked, forKey: .picked)
        try c.encodeIfPresent(answer, forKey: .answer)
        if secure { try c.encode(secure, forKey: .secure) }
        try c.encodeIfPresent(fields, forKey: .fields)
        try c.encodeIfPresent(site, forKey: .site)
    }

    /// 显示用：去掉 https:// / http:// 和末尾 /；空的当没写
    var siteDisplay: String? {
        guard var t = site?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        for prefix in ["https://", "http://"] where t.lowercased().hasPrefix(prefix) {
            t.removeFirst(prefix.count)
        }
        while t.hasSuffix("/") { t.removeLast() }
        return t.isEmpty ? nil : t
    }

    var isChoice: Bool { options != nil }
    /// 选项优先：同时有 options 和 fields 时按选项卡走
    var isForm: Bool { options == nil && fields != nil }

    /// 卡写坏了 / 还不支持时给一行提示，不给答（同 DiceRoller.problem）
    var problem: String? {
        if let options, !Self.optionRange.contains(options.count) {
            return "选项要 2–6 个，这张卡有 \(options.count) 个"
        }
        if isForm, let fields {
            if !Self.fieldRange.contains(fields.count) {
                return "要填的项要 1–6 个，这张卡有 \(fields.count) 个"
            }
            if fields.contains(where: { $0.label.isEmpty }) {
                return "有一项没写名字，这张卡没法填"
            }
            if let p = fields.lazy.compactMap(\.problem).first { return p }
        }
        return nil
    }

    /// 越界的下标丢掉
    var validPicked: [Int] {
        guard let picked, let options else { return [] }
        return picked.filter { options.indices.contains($0) }
    }

    func picking(_ indices: [Int]) -> AskCard {
        var next = self
        next.picked = indices.sorted()
        next.answer = nil
        return next
    }

    func answering(_ text: String) -> AskCard {
        var next = self
        next.answer = text
        next.picked = nil
        return next
    }

    /// 表单（带类型）：按顺序写回；文字类写 answer（空的不写），选择类写 picked
    func filling(values: [FieldValue]) -> AskCard {
        var next = self
        next.fields = fields.map { fields in
            fields.enumerated().map { i, field in
                var f = field
                guard values.indices.contains(i) else { return f }
                switch values[i] {
                case .text(let raw):
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    f.answer = t.isEmpty ? nil : t
                    f.picked = nil
                case .picked(let ix):
                    f.picked = ix.sorted()
                    f.answer = nil
                }
                return f
            }
        }
        next.picked = nil
        return next
    }

    /// 表单：按顺序把答案写回各字段（个数对不上的多余部分丢掉）
    func filling(_ answers: [String]) -> AskCard {
        var next = self
        next.fields = fields.map { fields in
            fields.enumerated().map { i, field in
                var f = field
                if answers.indices.contains(i) { f.answer = answers[i] }
                return f
            }
        }
        next.picked = nil
        return next
    }
}

/// 生词卡（research-chat-cards §14）：显示词典释义 + 生词本里的状态，粟粟点了才写生词本。按词识别，不需要 id
struct WordCard: Codable, Equatable {
    var word: String
    var note: String?

    static let maxWord = 64

    init(word: String, note: String?) {
        self.word = word
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decode(String.self, forKey: .word).trimmingCharacters(in: .whitespacesAndNewlines)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        guard !word.isEmpty, word.count <= Self.maxWord else {
            throw DecodingError.dataCorruptedError(forKey: .word, in: c, debugDescription: "word required")
        }
    }
}

/// 时间线卡（粟粟 10-03 选 A 竖排；先只读）：一串事件 / 计划排在一条竖线上，
/// 过去实心、将来空心，中间一条「现在」线；写了 quote 的项点了跳到含这句话的那条消息
struct TimelineCard: Codable, Equatable {
    struct Item: Codable, Equatable {
        /// 显示用的时间文字（「周一 10-01」「今晚」）
        var time: String
        var title: String
        var note: String?
        /// 分过去 / 将来用：yyyy-MM-dd 或 yyyy-MM-ddTHH:mm（本地时间）
        var at: String?
        /// 没写 at 时用它判过去
        var done: Bool?
        /// 点了跳到最近一条含这句话的消息
        var quote: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = (try? c.decodeIfPresent(String.self, forKey: .time)) .flatMap { $0 } ?? ""
            title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
            note = try? c.decodeIfPresent(String.self, forKey: .note)
            at = try? c.decodeIfPresent(String.self, forKey: .at)
            done = try? c.decodeIfPresent(Bool.self, forKey: .done)
            quote = try? c.decodeIfPresent(String.self, forKey: .quote)
            guard !title.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "title required")
            }
        }

        /// 有没有能分过去 / 将来的信息
        var hasTimeInfo: Bool { done != nil || parsed(TimeZone.current) != nil }

        private func parsed(_ zone: TimeZone) -> (date: Date, dayOnly: Bool)? {
            guard let at else { return nil }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            for (format, dayOnly) in [("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd HH:mm", false), ("yyyy-MM-dd", true)] {
                f.dateFormat = format
                if let d = f.date(from: at) { return (d, dayOnly) }
            }
            return nil
        }

        /// 只写日期：那天过完才算过去；写了时刻：到点就算
        func isPast(now: Date = Date(), calendar: Calendar = .current) -> Bool {
            if let done { return done }
            guard let p = parsed(calendar.timeZone) else { return false }
            if p.dayOnly {
                guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: p.date)) else { return false }
                return now >= next
            }
            return p.date <= now
        }
    }

    var id: String?
    var title: String
    var items: [Item]

    static let itemRange = 1...30

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = (try c.decodeIfPresent(String.self, forKey: .title) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        items = try c.decode([Item].self, forKey: .items)
        guard Self.itemRange.contains(items.count) else {
            throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: "1–30 items")
        }
    }

    /// 「现在」线画在第几项前面；都没有时间信息 → 不画
    func nowLineIndex(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard items.contains(where: \.hasTimeInfo) else { return nil }
        return items.firstIndex { !$0.isPast(now: now, calendar: calendar) } ?? items.count
    }

    /// 点了跳哪条：最近一条正文含这句话的消息
    static func jumpTarget(quote: String?, in nodes: [(id: String, text: String)]) -> String? {
        guard let q = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else { return nil }
        return nodes.last { $0.text.contains(q) }?.id
    }
}

/// 聊天卡片：消息文字里的一个 card-* 围栏代码块（research-chat-cards §2.1）。
enum ChatCard: Equatable {
    case todo(TodoCard)
    case dice(DiceCard)
    case timer(TimerCard)
    case chart(ChartCard)
    case music(MusicCard)
    case ask(AskCard)
    case timeline(TimelineCard)
    case word(WordCard)

    static let todoLanguage = "card-todo"
    static let diceLanguage = "card-dice"
    static let timerLanguage = "card-timer"
    static let chartLanguage = "card-chart"
    static let musicLanguage = "card-music"
    static let askLanguage = "card-ask"
    static let timelineLanguage = "card-timeline"
    static let wordLanguage = "card-word"

    /// 模型有时漏写 card- 前缀（```music）：这几个简写也认，但只在 JSON 严格解析成对应卡片时才算（粟粟 09-26 真机）
    static let shortAliases: Set<String> = ["todo", "dice", "timer", "chart", "music", "ask", "word", "timeline"]

    /// card-* 或简写；简写不保证是卡片，要再看能不能解析
    static func isCardLanguage(_ language: String) -> Bool {
        let lang = language.lowercased()
        return lang.hasPrefix("card-") || shortAliases.contains(lang)
    }

    static func parse(language: String, code: String) -> ChatCard? {
        guard let data = code.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        let lang = language.lowercased()
        switch shortAliases.contains(lang) ? "card-" + lang : lang {
        case todoLanguage:
            return (try? JSONDecoder().decode(TodoCard.self, from: data)).map(ChatCard.todo)
        case diceLanguage:
            return (try? JSONDecoder().decode(DiceCard.self, from: data)).map(ChatCard.dice)
        case timerLanguage:
            return (try? JSONDecoder().decode(TimerCard.self, from: data)).map(ChatCard.timer)
        case chartLanguage:
            return (try? JSONDecoder().decode(ChartCard.self, from: data)).map(ChatCard.chart)
        case musicLanguage:
            return (try? JSONDecoder().decode(MusicCard.self, from: data)).map(ChatCard.music)
        case timelineLanguage:
            return (try? JSONDecoder().decode(TimelineCard.self, from: data)).map(ChatCard.timeline)
        case askLanguage:
            return (try? JSONDecoder().decode(AskCard.self, from: data)).map(ChatCard.ask)
        case wordLanguage:
            return (try? JSONDecoder().decode(WordCard.self, from: data)).map(ChatCard.word)
        default:
            return nil
        }
    }

    /// 空字符串与缺失同义（无 id = 只读、不参与版本判定）
    var id: String? {
        let raw: String?
        switch self {
        case .todo(let t): raw = t.id
        case .dice(let d): raw = d.id
        case .timer(let t): raw = t.id
        case .chart(let g): raw = g.id
        case .music(let m): raw = m.id
        case .ask(let q): raw = q.id
        case .timeline(let t): raw = t.id
        case .word: raw = nil
        }
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    var kindLabel: String {
        switch self {
        case .todo: return "待办"
        case .dice: return "骰子"
        case .timer: return "计时器"
        case .chart: return "图表"
        case .music: return "音乐"
        case .ask: return "提问"
        case .timeline: return "时间线"
        case .word: return "生词"
        }
    }

    var title: String {
        switch self {
        case .todo(let t): return t.title.isEmpty ? kindLabel : t.title
        case .dice(let d): return d.title.isEmpty ? kindLabel : d.title
        case .timer(let t): return t.displayTitle
        case .chart(let g): return g.title.isEmpty ? kindLabel : g.title
        case .music(let m): return m.title
        case .ask(let q): return q.question
        case .timeline(let t): return t.title.isEmpty ? kindLabel : t.title
        case .word(let w): return w.word
        }
    }

    private var language: String {
        switch self {
        case .todo: return Self.todoLanguage
        case .dice: return Self.diceLanguage
        case .timer: return Self.timerLanguage
        case .chart: return Self.chartLanguage
        case .music: return Self.musicLanguage
        case .ask: return Self.askLanguage
        case .timeline: return Self.timelineLanguage
        case .word: return Self.wordLanguage
        }
    }

    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data?
        switch self {
        case .todo(let t): data = try? encoder.encode(t)
        case .dice(let d): data = try? encoder.encode(d)
        case .timer(let t): data = try? encoder.encode(t)
        case .chart(let g): data = try? encoder.encode(g)
        case .music(let m): data = try? encoder.encode(m)
        case .ask(let q): data = try? encoder.encode(q)
        case .timeline(let t): data = try? encoder.encode(t)
        case .word(let w): data = try? encoder.encode(w)
        }
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// 放进消息的完整代码块；内容里有连续反引号时围栏自动加长。
    var blockText: String {
        let body = json
        let fence = String(repeating: "`", count: max(3, MarkdownFenceTracker.longestBacktickRun(in: body) + 1))
        return "\(fence)\(language)\n\(body)\n\(fence)"
    }

    /// 短 id；避开对话里已有的（撞了重抽，4 位用尽时换 8 位）（终审 #2）
    static func newId(prefix: String, avoiding taken: Set<String> = []) -> String {
        for _ in 0..<64 {
            let id = "\(prefix)-" + String(format: "%04x", Int.random(in: 0...0xFFFF))
            if !taken.contains(id) { return id }
        }
        while true {
            let id = "\(prefix)-" + String(format: "%08x", UInt32.random(in: 0...UInt32.max))
            if !taken.contains(id) { return id }
        }
    }
}

/// 从一段消息文字里按出现顺序抽出所有能解析的卡片（围栏规则与渲染器一致：先推断嵌套，info 含反引号的不算围栏）。
enum ChatCardExtractor {
    static func mightContainCard(_ text: String) -> Bool {
        text.range(of: "card-", options: .caseInsensitive) != nil || text.contains("```") || text.contains("~~~")
    }

    static func cards(in text: String) -> [ChatCard] {
        blocks(in: text).compactMap { ChatCard.parse(language: $0.language, code: $0.code) }
    }

    /// #089 P2-c：写成 ```card-xxx 却解不开的（显示照旧降级成代码块，这里只给日志用）
    static func malformed(in text: String) -> [String] {
        blocks(in: text).filter {
            $0.language.lowercased().hasPrefix("card-") && ChatCard.parse(language: $0.language, code: $0.code) == nil
        }.map(\.language)
    }

    /// 按出现顺序的所有围栏代码块（语言名 + 正文）
    private static func blocks(in text: String) -> [(language: String, code: String)] {
        guard mightContainCard(text) else { return [] }
        var result: [(language: String, code: String)] = []
        var open: (char: Character, count: Int, language: String)?
        var body: [String] = []
        for line in MarkdownFenceNormalizer.normalize(text).components(separatedBy: "\n") {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let run = MarkdownFenceTracker.fenceRun(trimmed)
            if let current = open {
                if let run, run.char == current.char, run.count >= current.count,
                   trimmed.dropFirst(run.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    result.append((current.language, body.joined(separator: "\n")))
                    open = nil
                    body = []
                } else {
                    body.append(line)
                }
            } else if let run {
                let info = trimmed.dropFirst(run.count)
                if run.char == "`", info.contains("`") { continue }
                let language = info.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                open = (run.char, run.count, language)
            }
        }
        return result
    }
}
extension DiceCard {
    static func make(title: String, count: Int, sides: Int, avoiding taken: Set<String>) -> DiceCard {
        DiceCard(id: ChatCard.newId(prefix: "d", avoiding: taken), title: title.trimmingCharacters(in: .whitespaces),
                 dice: "\(count)d\(sides)", options: nil, result: nil)
    }

    /// 选项至少两个
    static func make(title: String, optionLines: [String], avoiding taken: Set<String>) -> DiceCard? {
        let options = optionLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard options.count >= 2 else { return nil }
        return DiceCard(id: ChatCard.newId(prefix: "d", avoiding: taken), title: title.trimmingCharacters(in: .whitespaces),
                        dice: nil, options: options, result: nil)
    }
}

extension TimerCard {
    /// 时钟式滚轮：时 / 分 / 秒
    static func make(title: String, hours: Int, minutes: Int, seconds: Int, autoStart: Bool, avoiding taken: Set<String>) -> TimerCard? {
        make(title: title, minutes: hours * 60 + minutes, seconds: seconds, autoStart: autoStart, avoiding: taken)
    }

    /// 新建面板上「放进输入框」为什么是灰的（TASK page1-卡片-04）；能放就 nil
    static func composerHint(hours: Int, minutes: Int, seconds: Int) -> String? {
        let total = (hours * 60 + minutes) * 60 + seconds
        if total < 1 { return "至少 1 秒" }
        if total > 86_400 { return "最长 24 小时" }
        return nil
    }

    static func make(title: String, minutes: Int, seconds: Int, autoStart: Bool, avoiding taken: Set<String>) -> TimerCard? {
        let total = minutes * 60 + seconds
        guard (1...86_400).contains(total) else { return nil }
        return TimerCard(id: ChatCard.newId(prefix: "c", avoiding: taken), title: title.trimmingCharacters(in: .whitespaces),
                         seconds: total, autoStart: autoStart)
    }
}
