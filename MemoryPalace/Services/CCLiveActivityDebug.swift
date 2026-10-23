#if os(iOS) && DEBUG
import ActivityKit

enum CCLiveActivityDebug {
    /// 走 Manager 的真路径（`pushType: .token` + token 注册链），别在 debug 里另开一条。
    static func start(_ state: CCActivityState) async {
        await CCLiveActivityManager.shared.start(state: state)
    }

    static func update(_ state: CCActivityState) async {
        let content = ActivityContent(state: state, staleDate: nil)
        for activity in Activity<CCActivityAttributes>.activities {
            await activity.update(content)
        }
    }

    static func end() async {
        for activity in Activity<CCActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
