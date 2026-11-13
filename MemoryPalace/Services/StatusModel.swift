import Foundation

// MARK: - 帧（plan-status-panel §7.5）

/// hub 存的一个外部检修源（status_result.sources[]）
struct StatusSource: Equatable, Identifiable {
    struct Item: Equatable {
        let name: String
        let ok: Bool
        let detail: String?
    }

    let id: String
    let title: String
    let checkedAt: Date?
    let staleAfterHours: Double
    let items: [Item]
    let canRun: Bool
    let running: Bool
}

extension StatusSource.Item: Codable {
    private enum CodingKeys: String, CodingKey { case name, ok, detail }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(detail, forKey: .detail)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        ok = try c.decode(Bool.self, forKey: .ok)
        let detail = try c.decodeIfPresent(String.self, forKey: .detail)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail?.isEmpty == false ? detail : nil
    }
}

extension StatusSource: Codable {
    private enum CodingKeys: String, CodingKey { case id, title, checkedAt, staleAfterHours, items, canRun, running }

    /// 本地存一份给冷启动 / 连不上时看：running 不存（那是此刻的事）
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(checkedAt.map(StatusISO.string), forKey: .checkedAt)
        try c.encode(staleAfterHours, forKey: .staleAfterHours)
        try c.encode(items, forKey: .items)
        try c.encode(canRun, forKey: .canRun)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let title = try c.decodeIfPresent(String.self, forKey: .title)
        self.title = title?.isEmpty == false ? title ?? id : id
        checkedAt = try c.decodeIfPresent(String.self, forKey: .checkedAt).flatMap(StatusISO.parse)
        staleAfterHours = try c.decodeIfPresent(Double.self, forKey: .staleAfterHours) ?? StatusModel.defaultStaleHours
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        canRun = try c.decodeIfPresent(Bool.self, forKey: .canRun) ?? false
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
    }
}

/// 小芽夜里不吵你（App 设，按手机时区）
struct StatusQuiet: Codable, Equatable {
    let start: String
    let end: String
    let tz: String

    static let fallback = StatusQuiet(start: "23:30", end: "08:30", tz: TimeZone.current.identifier)
}

struct StatusResultFrame: Codable, Equatable {
    let sources: [StatusSource]
    let quiet: StatusQuiet?

    private enum CodingKeys: String, CodingKey { case sources, quiet }

    init(sources: [StatusSource], quiet: StatusQuiet?) {
        self.sources = sources
        self.quiet = quiet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([StatusSource].self, forKey: .sources) ?? []
        quiet = try c.decodeIfPresent(StatusQuiet.self, forKey: .quiet)
    }
}

/// hub 推来的一条小芽提醒（status_alert.alert）
struct StatusAlert: Decodable, Equatable {
    enum Kind: String, Decodable { case bad, recovered }

    let id: String
    let source: String
    let title: String
    let kind: Kind
    let text: String
    let names: [String]
    let createdAt: String

    private enum CodingKeys: String, CodingKey { case id, source, title, kind, text, names, createdAt }

    init(id: String, source: String, title: String, kind: Kind, text: String, names: [String], createdAt: String) {
        self.id = id
        self.source = source
        self.title = title
        self.kind = kind
        self.text = text
        self.names = names
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? source
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct StatusAlertFrame: Decodable {
    let alert: StatusAlert
}

enum StatusISO {
    static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

// MARK: - 判定（每串 → 状态 + 一句话）

enum StatusBead: Equatable {
    case ok, bad, off
}

enum StatusVerdict: Equatable {
    case ok, bad(Int), stale

    /// 「最差的那块」排序：坏 > 过期 > 通
    var rank: Int {
        switch self {
        case .bad: return 3
        case .stale: return 2
        case .ok: return 1
        }
    }
}

struct StatusLine: Equatable, Identifiable {
    let id: String
    let name: String
    let bead: StatusBead
    let detail: String
}

/// 一串：外部源一串，App 自带的五项合成「花园自检」一串。
/// sourceID = hub 那边的源 id（发 status_run 用）；nil = 花园自检。UI 身份 id 两边分开，外部源叫 garden 也不撞
struct StatusStrand: Equatable, Identifiable {
    let sourceID: String?
    let title: String
    let verdict: StatusVerdict
    let lines: [StatusLine]
    let checkedAt: Date?
    let canRun: Bool
    let running: Bool

    var id: String { sourceID.map { "source.\($0)" } ?? StatusModel.gardenID }
    var isGarden: Bool { sourceID == nil }
    var badLines: [StatusLine] { lines.filter { $0.bead == .bad } }
}

/// App 自带的五颗珠要看的东西（读现成的 store，判定是纯函数）
struct GardenSelfCheck: Equatable {
    enum Notify: Equatable { case on, off, bannerOnly, unknown }
    struct MemoryFailure: Equatable {
        let text: String
        let streak: Int
    }

    var connected: Bool
    var lastError: String?
    var memoryOn: Bool
    var memoryFailure: MemoryFailure?
    var memoryLastOK: Date?
    var budgetEnabled: Bool
    var spentUSD: Double
    var limitUSD: Double
    var backupEnabled: Bool
    var lastBackup: Date?
    var notify: Notify
}

enum StatusModel {
    static let gardenID = "garden"
    static let gardenTitle = "花园自检"
    static let defaultStaleHours: Double = 36
    static let backupStaleDays: Double = 3

    static func verdict(_ source: StatusSource, now: Date) -> StatusVerdict {
        guard let at = source.checkedAt, now.timeIntervalSince(at) <= source.staleAfterHours * 3600 else { return .stale }
        let bad = source.items.filter { !$0.ok }.count
        return bad > 0 ? .bad(bad) : .ok
    }

    static func strand(_ source: StatusSource, now: Date) -> StatusStrand {
        let lines = source.items.enumerated().map { index, item in
            StatusLine(id: "\(index)-\(item.name)", name: item.name, bead: item.ok ? .ok : .bad,
                       detail: item.detail ?? (item.ok ? "通" : "不通"))
        }
        return StatusStrand(sourceID: source.id, title: source.title, verdict: verdict(source, now: now), lines: lines,
                            checkedAt: source.checkedAt, canRun: source.canRun, running: source.running)
    }

    static func gardenStrand(_ check: GardenSelfCheck, now: Date, calendar: Calendar = .current) -> StatusStrand {
        var lines: [StatusLine] = []
        lines.append(check.connected
            ? StatusLine(id: "mac", name: "Mac 连接", bead: .ok, detail: "连着")
            : StatusLine(id: "mac", name: "Mac 连接", bead: .bad, detail: BridgeDisconnectWording.humanize(check.lastError) ?? "没连上"))

        if !check.memoryOn {
            lines.append(StatusLine(id: "memory", name: "记忆", bead: .off, detail: "关着"))
        } else if let failure = check.memoryFailure {
            lines.append(StatusLine(id: "memory", name: "记忆", bead: .bad, detail: "\(failure.text) · 连续 \(failure.streak) 次"))
        } else {
            let detail = check.memoryLastOK.map { "\(StatusTime.ago($0, now: now))整理过" } ?? "还没写过"
            lines.append(StatusLine(id: "memory", name: "记忆", bead: .ok, detail: detail))
        }

        let spent = money(check.spentUSD), limit = money(check.limitUSD)
        if !check.budgetEnabled {
            lines.append(StatusLine(id: "budget", name: "预算", bead: .off, detail: "保险闸关着"))
        } else if check.spentUSD >= check.limitUSD {
            lines.append(StatusLine(id: "budget", name: "预算", bead: .bad, detail: "花了 \(spent)，到上限 \(limit) 了"))
        } else {
            lines.append(StatusLine(id: "budget", name: "预算", bead: .ok, detail: "花了 \(spent)，上限 \(limit)"))
        }

        if !check.backupEnabled {
            lines.append(StatusLine(id: "backup", name: "备份", bead: .off, detail: "没开"))
        } else if let last = check.lastBackup {
            let old = now.timeIntervalSince(last) > backupStaleDays * 86400
            let when = StatusTime.format(last, now: now, calendar: calendar)
            lines.append(StatusLine(id: "backup", name: "备份", bead: old ? .bad : .ok, detail: old ? "上次是 \(when)，三天多没备了" : when))
        } else {
            lines.append(StatusLine(id: "backup", name: "备份", bead: .ok, detail: "开着，还没备过"))
        }

        switch check.notify {
        case .on: lines.append(StatusLine(id: "notify", name: "通知", bead: .ok, detail: "开着，小芽叫得到你"))
        case .off: lines.append(StatusLine(id: "notify", name: "通知", bead: .bad, detail: "关着，小芽叫不到你"))
        case .bannerOnly: lines.append(StatusLine(id: "notify", name: "通知", bead: .off, detail: "这台设备上小芽只挂横幅"))
        case .unknown: lines.append(StatusLine(id: "notify", name: "通知", bead: .off, detail: "还在看"))
        }

        let bad = lines.filter { $0.bead == .bad }.count
        return StatusStrand(sourceID: nil, title: gardenTitle, verdict: bad > 0 ? .bad(bad) : .ok, lines: lines,
                            checkedAt: now, canRun: false, running: false)
    }

    /// 外部源在前（按 id），花园自检在后，固定
    static func strands(sources: [StatusSource], garden: GardenSelfCheck, now: Date, calendar: Calendar = .current) -> [StatusStrand] {
        sources.sorted { $0.id < $1.id }.map { strand($0, now: now) } + [gardenStrand(garden, now: now, calendar: calendar)]
    }

    /// 最差的那块；一样差时外部源（排前面的）优先
    static func worst(_ strands: [StatusStrand]) -> StatusStrand? {
        strands.reduce(nil) { best, strand in
            guard let best else { return strand }
            return strand.verdict.rank > best.verdict.rank ? strand : best
        }
    }

    struct Headline: Equatable {
        let title: String
        let subtitle: String
    }

    /// 面板大标题就是结论（「两颗掉了」「都通着」「检修没跑」）+ 一行小字说哪一串、什么时候查的
    static func headline(_ strands: [StatusStrand], now: Date, calendar: Calendar = .current) -> Headline {
        let bads = strands.filter { if case .bad = $0.verdict { return true } else { return false } }
        if !bads.isEmpty {
            let total = bads.reduce(0) { $0 + $1.badLines.count }
            if bads.count == 1, let one = bads.first {
                return Headline(title: "\(countWord(total))颗掉了", subtitle: "\(one.title) · \(checkedPhrase(one, now: now, calendar: calendar))")
            }
            return Headline(title: "\(countWord(total))颗掉了", subtitle: bads.map(\.title).joined(separator: "、"))
        }
        if let stale = strands.first(where: { $0.verdict == .stale }) {
            let last = stale.checkedAt.map { "上次 \(StatusTime.format($0, now: now, calendar: calendar))" } ?? "没有时间"
            return Headline(title: "检修没跑", subtitle: "\(stale.title) · \(last)")
        }
        let external = strands.filter { !$0.isGarden }
        if external.count == 1, let one = external.first {
            return Headline(title: "都通着", subtitle: "\(one.title) · \(checkedPhrase(one, now: now, calendar: calendar))")
        }
        if let latest = external.compactMap(\.checkedAt).max() {
            return Headline(title: "都通着", subtitle: "\(external.count) 串 · 最近 \(StatusTime.phrase(latest, now: now, calendar: calendar)) 查的")
        }
        return Headline(title: "都通着", subtitle: "\(gardenTitle) · 刚刚")
    }

    private static func checkedPhrase(_ strand: StatusStrand, now: Date, calendar: Calendar) -> String {
        if strand.isGarden { return "刚刚" }
        return strand.checkedAt.map { "\(StatusTime.phrase($0, now: now, calendar: calendar)) 查的" } ?? "没有时间"
    }

    /// 前 3 个名字用「、」连，多了加「等」
    static func namesPreview(_ names: [String]) -> String {
        names.prefix(3).joined(separator: "、") + (names.count > 3 ? "等" : "")
    }

    static func countWord(_ n: Int) -> String {
        let words = ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九", "十"]
        return words.indices.contains(n) ? words[n] : "\(n) "
    }

    static func money(_ value: Double) -> String {
        value.rounded() == value ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}

// MARK: - 时间（按设备时区：今天只写时刻，昨天写「昨天 HH:mm」，更早写「M月d日」）

enum StatusTime {
    static func format(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, calendar: calendar) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(clock(date, calendar: calendar))"
        }
        let c = calendar.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    /// 句子里用：今天的补个「今天」
    static func phrase(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? "今天 \(format(date, now: now, calendar: calendar))" : format(date, now: now, calendar: calendar)
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
