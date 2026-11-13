import Observation

/// 哪一层正在回话（plan-atrium P1）：切楼层会同步停掉回复和 run_command，atrium 点别人前先问一句。
/// 跟进度卡的 `TurnActivity` 不是一回事（那个按对话记工具步骤）。
/// run_command 只在 turn 的工具循环里跑（`DeviceToolDispatcher` 唯一调用点），turn 收口前它必然已结束或被杀，所以只跟 turn。
@Observable
final class ProfileTurnActivity {
    static let shared = ProfileTurnActivity()

    var generatingProfileId: String?
}
