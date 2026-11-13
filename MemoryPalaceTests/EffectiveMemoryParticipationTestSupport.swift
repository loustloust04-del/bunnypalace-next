import MemoryCore
import XCTest
@testable import 记忆花园

/// 测试造值：把原来的 `conversationMemoryEnabled / slotOn / choices` 三件套折成包里的 `EffectiveMemoryParticipation`
/// （legacy / A2 勾 / 触发开关按当前 defaults 算；`master` 不给时也按 defaults，与实发同一口径）。
extension EffectiveMemoryParticipation {
    static func testValue(profileId: String, master: Bool? = nil, window: Bool = true, slot: Bool = true,
                          choices: MemoryWindowChoices? = nil,
                          defaults: UserDefaults = .standard) -> Self {
        let legacy = MemoryWindowChoices.legacy(profileId: profileId, defaults: defaults)
        return EffectiveMemoryParticipation(.init(
            master: master ?? (defaults.object(forKey: "mem_master") as? Bool ?? true), window: window, slot: slot,
            choices: choices?.participationChoices,
            legacy: legacy.participationChoices,
            a2Checked: MemoryOpenWindow.isChecked(.a2, profileId: profileId, defaults: defaults),
            archiveTrigger: RecallTuningStore.load(profileId: profileId, defaults: defaults).archiveTriggerEnabled))
    }
}
