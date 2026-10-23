import Foundation

/// App Group 共享的「纪念日快照」（plan-calendar §九 P6）。写入端：主 app 的 CalendarSnapshotWriter；读取端：CalendarWidget。
/// 只存日期，不存天数——天数由小组件时间线每天零点自己算（快照可能是几天前写的）。
/// 跟随当前楼层：切楼层时整份重写。
struct CalendarSnapshot: Codable, Equatable {
    static let widgetKind = "CalendarAnniversaryWidget"
    static let relativePath = "calendar-snapshot/latest.json"

    struct Item: Codable, Equatable {
        var title: String
        /// countdown / since / yearly
        var kind: String
        var isBirthday: Bool
        /// cut / night / stitch / dust
        var style: String
        /// 正数的起算日（yyyy-MM-dd）
        var baseDate: String
        /// 接下来几次（yyyy-MM-dd，升序；倒数型只有一个）
        var targets: [String]
        /// 照片缩略图：App Group 里的相对路径（`calendar-snapshot/photos/…`）；读不到就当没照片
        var photo: String? = nil
    }

    /// 缩略图目录（App Group 相对路径）
    static let photosDir = "calendar-snapshot/photos"

    /// 缩略图文件名 = 楼层 + 原图文件名。原图名里已经带内容哈希，所以缩略图也是不可变的：换图 → 换名
    static func thumbnailName(profileId: String, photoFile: String) -> String {
        let safe = String(profileId.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
        return "\(safe)-\(photoFile)"
    }

    /// 该清掉的旧缩略图：不在当前快照里，并且放了超过 grace（给还在用旧快照的时间线留余地）
    static func staleThumbnails(existing: [(name: String, modified: Date)], keep: Set<String>, now: Date,
                                grace: TimeInterval = 86_400) -> [String] {
        existing.filter { !keep.contains($0.name) && now.timeIntervalSince($0.modified) > grace }.map(\.name)
    }

    var profileId: String
    var items: [Item]
    var writtenAt: Date

    /// 小组件 / 测试共用：今天起算的天数与前缀
    static func days(for item: Item, today: Date, calendar: Calendar) -> (prefix: String, days: Int)? {
        func date(_ key: String) -> Date? {
            let p = key.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        let start = calendar.startOfDay(for: today)
        if item.kind == "since" {
            guard let base = date(item.baseDate) else { return nil }
            return ("已经", max(0, calendar.dateComponents([.day], from: base, to: start).day ?? 0))
        }
        for key in item.targets {
            guard let t = date(key), t >= start else { continue }
            return ("还有", calendar.dateComponents([.day], from: start, to: t).day ?? 0)
        }
        return nil
    }
}
