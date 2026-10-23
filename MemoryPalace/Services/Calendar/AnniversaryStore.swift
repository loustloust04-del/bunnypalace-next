import Foundation

// MARK: - 纪念日（plan-calendar §3.2 / §3.3）
// 一条一个文件：filesystem/calendar/anniversaries/{id}.json——两台设备各加一条不会互相覆盖整份。

struct LunarMonthDay: Codable, Equatable, Hashable, Sendable {
    var month: Int
    var day: Int
    var leap: Bool
}

struct Anniversary: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// 倒数：还有 N 天（过了显示已过 N 天）
        case countdown
        /// 正数：已经 N 天（起始日是第 0 天）
        case since
        /// 每年：还有 N 天 · 第 N 次（生日）
        case yearly
    }

    enum Style: String, Codable, CaseIterable, Sendable {
        case polaroid, stamp, tape, full, film, arch
        case cut, night, stitch, dust

        var label: String {
            switch self {
            case .polaroid: "拍立得"
            case .stamp: "邮票"
            case .tape: "胶带"
            case .full: "满幅"
            case .film: "胶片"
            case .arch: "拱窗"
            case .cut: "镂空星卡"
            case .night: "夜 · 像素花"
            case .stitch: "彩色刺绣"
            case .dust: "仙尘星轨"
            }
        }

        /// 用得上照片（快照拷缩略图按这个）：六种照片样式 + 镂空星卡（照片垫在星孔底下）
        var acceptsPhoto: Bool { self != .night && self != .stitch && self != .dust }
        /// 离不开照片：没放照片时卡上画虚线框「放一张照片」
        var needsPhoto: Bool { acceptsPhoto && self != .cut }

        /// 以后的版本加了新样式、这台还不认识：降级成刺绣显示（只读不回写）
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Style(rawValue: raw) ?? .stitch
        }
    }

    /// 聊天里记下的来源：按它 upsert，同一块重复处理不会加两条
    struct Source: Codable, Equatable, Sendable {
        var nodeId: String
        var blockHash: String
    }

    var id: String = UUID().uuidString
    var title: String
    var kind: Kind
    var isBirthday = false
    /// 公历日期 yyyy-MM-dd：倒数 / 正数的那一天；每年型是「第一次」（算第几次用）
    var date: String
    /// 每年型按农历过时有值
    var lunar: LunarMonthDay?
    var style: Style = .stitch
    /// 自己放的照片：同目录下的文件名 `{id}-{哈希}.jpg`（不可变，换图换名）
    var photo: String?
    /// 提前几天让小克知道；nil = 不告诉
    var remindDays: Int? = 3
    var source: Source?
    var createdAt = Date()
    var updatedAt = Date()
}

struct AnniversaryStore: Sendable {
    let root: URL

    init(root: URL) { self.root = root }

    static func forProfile(_ profileId: String) -> AnniversaryStore {
        AnniversaryStore(root: FileLibraryStore.libraryRoot(profileId: profileId)
            .appendingPathComponent("calendar/anniversaries", isDirectory: true))
    }

    private func url(for id: String) -> URL { root.appendingPathComponent(ActivityCacheStore.sanitize(id) + ".json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func loadAll() -> [Anniversary] {
        MainThreadIO.note(.enumerate, "AnniversaryStore.loadAll")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { load(at: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func load(at url: URL) -> Anniversary? {
        MainThreadIO.note(.read, "AnniversaryStore.load")
        return (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(Anniversary.self, from: $0) }
    }

    /// 照片文件的位置（文件可能还没从 iCloud 下来：调用方读不到就画占位，别清引用）
    func photoURL(_ a: Anniversary) -> URL? {
        a.photo.map { root.appendingPathComponent(ActivityCacheStore.sanitize($0)) }
    }

    enum PhotoChange: Equatable, Sendable {
        case keep
        /// 已经压好的 JPEG
        case replace(Data)
        case remove
    }

    /// 保存（plan-calendar-photos-todos 裁定 #1 的顺序）：先写不可变的新照片 → 再原子写 JSON → 成功后才删旧照片。
    /// 任何一步失败都抛出，旧图还在。
    @discardableResult
    func save(_ a: Anniversary, photo change: PhotoChange = .keep) throws -> Anniversary {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var copy = a
        let onDisk = load(at: url(for: a.id))?.photo
        switch change {
        case .keep:
            break
        case .replace(let jpeg):
            let name = "\(ActivityCacheStore.sanitize(a.id))-\(AnniversaryPhoto.hash8(jpeg)).jpg"
            try jpeg.write(to: root.appendingPathComponent(name), options: .atomic)
            copy.photo = name
        case .remove:
            copy.photo = nil
        }
        copy.updatedAt = Date()
        try Self.encoder.encode(copy).write(to: url(for: a.id), options: .atomic)
        if let old = onDisk, old != copy.photo {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(ActivityCacheStore.sanitize(old)))
        }
        return copy
    }

    /// 删除：JSON 删成功才删照片
    func delete(id: String) throws {
        let photo = load(at: url(for: id))?.photo
        try FileManager.default.removeItem(at: url(for: id))
        if let photo { try? FileManager.default.removeItem(at: root.appendingPathComponent(ActivityCacheStore.sanitize(photo))) }
    }
}

// MARK: - 算日子

enum AnniversaryMath {

    /// 农历（只在纪念日里用）
    static func chineseCalendar(timeZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .chinese)
        c.timeZone = timeZone
        return c
    }

    static func lunar(of date: Date, chinese: Calendar) -> LunarMonthDay {
        let c = chinese.dateComponents([.month, .day], from: date)
        return LunarMonthDay(month: c.month ?? 1, day: c.day ?? 1, leap: c.isLeapMonth ?? false)
    }

    /// 这一天所在的农历月有几天
    static func lunarMonthLength(containing date: Date, chinese: Calendar) -> Int {
        chinese.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    /// 这个农历年（`near` 附近）有没有闰 `month` 月
    static func hasLeapMonth(_ month: Int, near date: Date, chinese: Calendar, gregorian: Calendar) -> Bool {
        for offset in stride(from: -60, through: 60, by: 3) {
            guard let d = gregorian.date(byAdding: .day, value: offset, to: date) else { continue }
            let l = lunar(of: d, chinese: chinese)
            if l.month == month, l.leap { return true }
        }
        return false
    }

    /// 从 `start`（含当天）起，下一次农历 `md`。规则（plan §3.3）：
    /// - 闰月生日：那一年有同一个闰月就过闰月那天，没有就过正常月
    /// - 三十：目标月只有二十九天时过二十九
    /// - 今天就是：返回今天
    static func nextLunar(_ md: LunarMonthDay, onOrAfter start: Date, gregorian: Calendar, chinese: Calendar) -> Date? {
        let startDay = gregorian.startOfDay(for: start)
        for i in 0..<420 {
            guard let d = gregorian.date(byAdding: .day, value: i, to: startDay),
                  let noon = gregorian.date(bySettingHour: 12, minute: 0, second: 0, of: d) else { continue }
            let l = lunar(of: noon, chinese: chinese)
            guard l.month == md.month else { continue }
            let length = lunarMonthLength(containing: noon, chinese: chinese)
            let targetDay = min(md.day, length)
            guard l.day == targetDay else { continue }
            if md.leap {
                if l.leap { return d }
                // 正常月那天：只有这一年没有闰这个月时才算
                if !hasLeapMonth(md.month, near: noon, chinese: chinese, gregorian: gregorian) { return d }
            } else if !l.leap {
                return d
            }
        }
        return nil
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        DailyActivity.date(fromKey: key, calendar: calendar).map { calendar.startOfDay(for: $0) }
    }

    static func daysBetween(_ a: Date, _ b: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }

    struct Countdown: Equatable, Sendable {
        /// 下一次（或那一天）
        let target: Date
        /// 倒数 / 每年：还有几天（0 = 就是今天）；正数：已经几天
        let days: Int
        /// 每年型：第几次（从 1 起）；其它 nil
        let occurrence: Int?
        /// 倒数型已经过了
        let isPast: Bool
    }

    static func countdown(for a: Anniversary, today: Date, gregorian: Calendar = .current, chinese: Calendar? = nil) -> Countdown? {
        guard let base = date(fromKey: a.date, calendar: gregorian) else { return nil }
        let todayStart = gregorian.startOfDay(for: today)
        switch a.kind {
        case .countdown:
            let d = daysBetween(todayStart, base, calendar: gregorian)
            return Countdown(target: base, days: abs(d), occurrence: nil, isPast: d < 0)
        case .since:
            return Countdown(target: base, days: max(0, daysBetween(base, todayStart, calendar: gregorian)), occurrence: nil, isPast: false)
        case .yearly:
            let next: Date?
            if let lunar = a.lunar {
                next = nextLunar(lunar, onOrAfter: todayStart, gregorian: gregorian, chinese: chinese ?? chineseCalendar(timeZone: gregorian.timeZone))
            } else {
                let md = gregorian.dateComponents([.month, .day], from: base)
                next = gregorian.nextDate(after: gregorian.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart,
                                          matching: DateComponents(month: md.month, day: md.day, hour: 0),
                                          matchingPolicy: .nextTimePreservingSmallerComponents)
                    .map { gregorian.startOfDay(for: $0) }
            }
            guard let next else { return nil }
            let occurrence = max(1, gregorian.component(.year, from: next) - gregorian.component(.year, from: base))
            return Countdown(target: next, days: daysBetween(todayStart, next, calendar: gregorian), occurrence: occurrence, isPast: false)
        }
    }
}
