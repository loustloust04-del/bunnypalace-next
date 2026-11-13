import MemoryCore
import Foundation
import SwiftData

/// app 侧把四个开关源填进包里那个值（plan `plan-memory-participation.md` §2.3）：
/// 实发 / 预热 / 检查器 / 测试台都从这一个函数取，不再各自拼 `master && memoryEnabled && …`。
extension EffectiveMemoryParticipation {
    /// `archiveTrigger` 非 nil 时覆盖 store（重新生成时冻结的是回执里的 tuning，不是当前设置）。
    static func resolve(profileId: String, conversation: Conversation?, preset: Preset?,
                        defaults: UserDefaults = MemoryReadEnvironment.defaults,
                        archiveTrigger: Bool? = nil) -> Self {
        let legacy = MemoryWindowChoices.legacy(profileId: profileId, defaults: defaults)
        return EffectiveMemoryParticipation(.init(
            master: (defaults.object(forKey: "mem_master") as? Bool) ?? true,
            window: conversation.map { $0.memoryEnabled && !$0.isTrashed } ?? true,
            slot: preset.map(MemoryResident.memorySlotOn) ?? true,
            choices: conversation?.memoryWindowChoices?.participationChoices,
            legacy: legacy.participationChoices,
            a2Checked: MemoryOpenWindow.isChecked(.a2, profileId: profileId, defaults: defaults),
            archiveTrigger: archiveTrigger ?? RecallTuningStore.load(profileId: profileId, defaults: defaults).archiveTriggerEnabled))
    }

    /// 来源窗隐藏集（P2-b 用）：本楼层里 `isTrashed || !memoryEnabled` 的窗 id。
    /// 用隐藏集不用可见集：来源窗不存在（物理删 / 导入丢）的碎片照带（现状）。
    static func hiddenSources(profileId: String, context: ModelContext) -> Set<String> {
        let pid = profileId
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate<Conversation> {
            $0.profileId == pid && ($0.isTrashed || !$0.memoryEnabled)
        })
        descriptor.propertiesToFetch = [\.id]
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.id))
    }
}

extension MemoryWindowChoices {
    /// 读侧快照 → 包里的 `Choices`（唯一一处转换）。
    var participationChoices: EffectiveMemoryParticipation.Choices {
        .init(timeline: timeline, pending: pending, selfMemory: selfMemory,
              archive: archive, previousWindow: previousWindow, pinned: pinned)
    }
}
