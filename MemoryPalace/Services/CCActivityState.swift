enum CCActivityPhase: String, Codable, Hashable {
    case idle
    case working
    case waiting
    case done
}

struct CCActivityState: Codable, Hashable {
    var phase: CCActivityPhase
    var model: String?
    var ctx: Int?
    var fiveHour: Int?
    var sevenDay: Int?
    var detail: String?
    var sinceUnix: Int?
    var updatedUnix: Int?
    var runId: String?

    enum CodingKeys: String, CodingKey {
        case phase
        case model
        case ctx
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case detail
        case sinceUnix = "since_unix"
        case updatedUnix = "updated_unix"
        case runId = "run_id"
    }
}
