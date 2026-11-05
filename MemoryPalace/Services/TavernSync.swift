import Foundation

/// 卡库改卡 → 楼层同步（B1）、卡楼层的用户称呼（B6）、Prompt 页空槽预览（B2）。纯函数，单测 TavernSyncTests
enum TavernSync {
    struct Outcome {
        var profile: Profile
        var preset: Preset?
        /// 你改过、这次没覆盖的槽（槽名）
        var skipped: [String] = []
    }

    /// 只有这些字段会被拷进楼层（makeFloor 同口径）
    static func touchesFloor(old: CharacterCard, new: CharacterCard) -> Bool {
        old.description != new.description || old.personality != new.personality || old.scenario != new.scenario
            || old.mesExample != new.mesExample || old.systemPrompt != new.systemPrompt
            || old.postHistoryInstructions != new.postHistoryInstructions
    }

    /// 楼层里的卡字段和卡库不一致 = 卡改过还没同步
    static func needsSync(card: CharacterCard, profile: Profile) -> Bool {
        profile.characterDescription != card.description || profile.characterPersonality != card.personality
            || profile.scenario != card.scenario || profile.chatExamples != card.mesExample
    }

    /// makeFloor 当初往槽里写的值：卡字段非空写卡字段，空的话槽保持模板原文
    static func seeded(_ cardValue: String, template: String?) -> String {
        cardValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (template ?? "") : cardValue
    }

    /// sources：楼层可能是从哪几版卡拷过去的（改卡前那版、导入原件）。槽内容等于其中任一版当初写进去的值 = 没被改过
    static func apply(card: CharacterCard, sources: [CharacterCard], profile: Profile,
                      preset: Preset?, template: Preset?) -> Outcome {
        var profile = profile
        profile.characterDescription = card.description
        profile.characterPersonality = card.personality
        profile.scenario = card.scenario
        profile.chatExamples = card.mesExample
        // 楼层编辑能改 systemPrompt，同样只换没改过的
        if sources.contains(where: { $0.systemPrompt == profile.systemPrompt }) { profile.systemPrompt = card.systemPrompt }
        if sources.contains(where: { $0.postHistoryInstructions == profile.postInstructions }) {
            profile.postInstructions = card.postHistoryInstructions
        }
        guard var preset else { return Outcome(profile: profile, preset: nil) }
        var skipped: [String] = []
        let fields: [(String, KeyPath<CharacterCard, String>)] = [(PromptSlot.mainId, \.systemPrompt),
                                                                   (PromptSlot.jailbreakId, \.postHistoryInstructions)]
        for (slotId, field) in fields {
            guard let index = preset.prompts.firstIndex(where: { $0.id == slotId && !$0.forbidOverrides }) else { continue }
            let original = template?.prompts.first { $0.id == slotId }?.content
            let target = seeded(card[keyPath: field], template: original)
            let content = preset.prompts[index].content
            guard content != target else { continue }
            let baselines = sources.map { seeded($0[keyPath: field], template: original) }
            // 卡这一栏没变：槽和卡不同是你自己改的，不算「没覆盖」
            if !baselines.isEmpty, baselines.allSatisfy({ $0 == target }) { continue }
            if baselines.contains(content) {
                preset.prompts[index].content = target
            } else {
                skipped.append(preset.prompts[index].name)
            }
        }
        return Outcome(profile: profile, preset: preset, skipped: skipped)
    }

    /// B6：卡楼层的 {{user}}——按顺序取第一个填过的称呼（「你」算没填），都没有才「你」
    static func userName(_ candidates: [String?]) -> String {
        for value in candidates {
            let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty, name != "你" { return name }
        }
        return "你"
    }

    /// B2：槽空着时，组装会退回楼层上的卡字段——把它灰着显示在框里；hint 写在标签旁
    static func cardFieldPreview(slotId: String, profile: Profile, limit: Int = 300) -> (text: String, hint: String)? {
        let (value, hint): (String, String)
        switch slotId {
        case PromptSlot.charDescriptionId: (value, hint) = (profile.characterDescription, "在这里写会替换卡描述")
        case PromptSlot.dialogueExamplesId: (value, hint) = (profile.chatExamples, "在这里写会替换卡里的示例")
        default: return nil
        }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text.count > limit ? String(text.prefix(limit)) + "…" : text, hint)
    }
}
