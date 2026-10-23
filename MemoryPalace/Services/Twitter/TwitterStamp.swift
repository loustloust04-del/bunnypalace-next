import Foundation

/// 时间线那行的短时间戳。推特是「2h」「1d」而不是完整日期——
/// 这一处很影响「像不像」，所以单独做并测住。
enum TwitterStamp {

    private static let sameYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    private static let otherYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    static func short(_ date: Date, now: Date = Date()) -> String {
        let gap = now.timeIntervalSince(date)
        // 设备时钟歪了也不能显示「-3天」
        guard gap >= 60 else { return "刚刚" }
        if gap < 3600 { return "\(Int(gap / 60))分" }
        if gap < 86_400 { return "\(Int(gap / 3600))时" }
        if gap < 7 * 86_400 { return "\(Int(gap / 86_400))天" }
        // 超过一周给日期——「43天」没人读得懂
        let cal = Calendar(identifier: .gregorian)
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: now)
        return (sameYear ? Self.sameYear : Self.otherYear).string(from: date)
    }
}
