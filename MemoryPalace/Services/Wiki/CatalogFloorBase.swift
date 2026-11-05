import Foundation

/// 楼层完整底图（C2/C3 v2 第 5 段）：Prompt 里人填的全部文字，来源和文件库「Prompt」同一份。
/// 插槽按 Prompt 页顺序全收（关着的也收、标出来）；字段路由沿组装的「显式槽优先、楼层字段兜底」：
/// 对应槽填了字（开没开都算）→ 那个楼层字段被覆盖、不再收；对应 marker 槽空着 → 在槽的位置放字段原文。
/// 没有独立槽的字段（角色性格、后置提醒…）和没被路由到的字段完整排在后面。不截断、不跨槽去重；
/// 自动填充的槽（PromptSlot.isAutoFilled，组装不读它存的字）、三份格式模板、记忆 / 世界书等动态注入都不收。
/// 主线程取一次，之后是不可变值。
struct CatalogFloorBase: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        /// 文件库「Prompt」里的稳定路径（读源 / 出处用）
        var path: String
        var name: String
        /// 名字宏已展开的原文
        var text: String
        /// 插槽开关；不挂在插槽上的楼层字段 = nil
        var isEnabled: Bool?
    }

    var sections: [Section]

    /// 组装里空 marker 槽退回的楼层字段（PromptAssembler.resolveSlotContentPair）
    private static let fallbackField: [String: PromptFolder.Field] = [
        PromptSlot.mainId: .systemPrompt,
        PromptSlot.personaDescriptionId: .userPersona,
        PromptSlot.charDescriptionId: .characterDescription,
        PromptSlot.scenarioId: .scenario,
        PromptSlot.dialogueExamplesId: .chatExamples,
    ]

    static func make(profile: Profile, presets: [Preset], names: EffectiveCharacterContext) -> CatalogFloorBase {
        var sections: [Section] = []
        var routed = Set<PromptFolder.Field>()
        func section(_ source: PromptFolder.Source, _ name: String, _ raw: String, _ enabled: Bool?) -> Section {
            Section(path: PromptFolder.path(for: source), name: name, text: names.expand(raw), isEnabled: enabled)
        }
        if let preset = PromptFolder.instance(profile: profile, presets: presets) {
            for slot in SlotOrder.ordered(preset.prompts) where !slot.isAutoFilled {
                let field = fallbackField[slot.id]
                if !slot.content.isEmpty {
                    if let field { routed.insert(field) }
                    sections.append(section(.slot(presetId: preset.id, slotId: slot.id), slot.name, slot.content, slot.isEnabled))
                } else if slot.isMarker, let field, !routed.contains(field), !profile[keyPath: field.keyPath].isEmpty {
                    routed.insert(field)
                    sections.append(section(.field(field), field.label, profile[keyPath: field.keyPath], slot.isEnabled))
                }
            }
        }
        for field in PromptFolder.Field.allCases where !routed.contains(field) && !profile[keyPath: field.keyPath].isEmpty {
            sections.append(section(.field(field), field.label, profile[keyPath: field.keyPath], nil))
        }
        return CatalogFloorBase(sections: sections)
    }

    var text: String {
        sections.map { s in
            "〔\(s.name)\(s.isEnabled == false ? "（已关闭）" : "")〕\n\(s.text)"
        }.joined(separator: "\n\n")
    }
}
