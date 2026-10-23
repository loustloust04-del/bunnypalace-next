import Foundation

/// CC 用量快照的 wire 结构：app（UsageSnapshotWriter）写、widget（UsageSnapshotStore）读。
/// 字段名跟 `CCActivityState` 的 snake_case wire 名对齐——灵动岛、锁屏 widget、桌面 widget
/// 画的是同一份数据，不是三份逻辑。
struct UsageSnapshot: Codable, Hashable {
    var sessionName: String
    var model: String?
    var ctx: Int?
    var fiveHour: Int?
    var sevenDay: Int?
    /// 写入时刻，不是 hub 采样时刻——widget 拿它算「x MIN AGO」。
    var updatedUnix: Int

    enum CodingKeys: String, CodingKey {
        case sessionName = "session_name"
        case model
        case ctx
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case updatedUnix = "updated_unix"
    }
}
