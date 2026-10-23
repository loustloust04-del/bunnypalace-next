import ActivityKit

struct CCActivityAttributes: ActivityAttributes {
    typealias ContentState = CCActivityState

    var sessionName: String

    enum CodingKeys: String, CodingKey {
        case sessionName = "session_name"
    }
}
