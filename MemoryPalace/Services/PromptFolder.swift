import Foundation

/// 文件库「Prompt」（C2/C3 v2 第 5 段）：楼层当前预设实例的插槽 + 楼层字段，和 Prompt 页是同一份数据。
/// 只是虚拟目录：读从 PresetManager / Profile 现取，写回同一个实例 / 楼层，不往磁盘复制。
/// 路径是稳定身份（presetId + slotId / 楼层字段属性键），不用槽名拼；显示名原样取槽名。
enum PromptFolder {
    static let root = ".prompt"
    static let fieldsFolder = root + "/fields"
    private static let fileExtension = ".txt"

    /// 旧楼层仍存在 Profile 里的手填文字。三份格式模板（Preset.characterFormat…）不在这里
    enum Field: String, CaseIterable, Sendable {
        case systemPrompt, userPersona, characterDescription, characterPersonality, scenario, chatExamples, postInstructions

        var label: String {
            switch self {
            case .systemPrompt: "系统指令"
            case .userPersona: "用户描述"
            case .characterDescription: "助手设定"
            case .characterPersonality: "助手性格"
            case .scenario: "背景设定"
            case .chatExamples: "对话示例"
            case .postInstructions: "后置提醒"
            }
        }

        var keyPath: WritableKeyPath<Profile, String> {
            switch self {
            case .systemPrompt: \.systemPrompt
            case .userPersona: \.userPersona
            case .characterDescription: \.characterDescription
            case .characterPersonality: \.characterPersonality
            case .scenario: \.scenario
            case .chatExamples: \.chatExamples
            case .postInstructions: \.postInstructions
            }
        }
    }

    enum Source: Hashable, Sendable {
        case slot(presetId: String, slotId: String)
        case field(Field)
    }

    struct Entry: Equatable, Identifiable, Sendable {
        var path: String
        var name: String
        var content: String
        var source: Source
        /// 插槽开关；楼层字段没有开关
        var isEnabled: Bool?
        var isMarker = false
        /// 自动填充的 marker（PromptSlot.isAutoFilled）只读，和 Prompt 页一致
        var isEditable = true
        var id: String { path }
    }

    enum SaveError: LocalizedError, Equatable {
        case gone
        case conflict
        case readOnly

        var errorDescription: String? {
            switch self {
            case .gone: "这个插槽已不在当前楼层的预设里（删了或换了预设），没有保存。"
            case .conflict: "这段在别处改过了，请关闭重开后再保存。"
            case .readOnly: "这个插槽由系统自动填充，不能在这里改。"
            }
        }
    }

    static func isPromptPath(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    static func displayName(_ path: String) -> String? {
        switch path {
        case root: "Prompt"
        case fieldsFolder: "楼层字段"
        default: nil
        }
    }

    // MARK: - 路径

    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    private static func encode(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
    }

    static func path(for source: Source) -> String {
        switch source {
        case .slot(let presetId, let slotId): root + "/" + encode(presetId) + "." + encode(slotId) + fileExtension
        case .field(let field): fieldsFolder + "/" + field.rawValue + fileExtension
        }
    }

    static func source(of path: String) -> Source? {
        guard path.hasSuffix(fileExtension) else { return nil }
        let stem = String(path.dropLast(fileExtension.count))
        if stem.hasPrefix(fieldsFolder + "/") {
            return Field(rawValue: String(stem.dropFirst(fieldsFolder.count + 1))).map(Source.field)
        }
        guard stem.hasPrefix(root + "/") else { return nil }
        let parts = stem.dropFirst(root.count + 1).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let presetId = parts[0].removingPercentEncoding,
              let slotId = parts[1].removingPercentEncoding, !presetId.isEmpty, !slotId.isEmpty else { return nil }
        return .slot(presetId: presetId, slotId: slotId)
    }

    // MARK: - 读

    /// 楼层自己的实例：presetId 指向模板 / 别层 / 不存在 → nil（不回退改共享模板）
    static func instance(profile: Profile, presets: [Preset]) -> Preset? {
        presets.first { $0.id == profile.presetId && $0.ownerProfileId == profile.id }
    }

    /// 插槽按 Prompt 页顺序全列（空槽、关闭槽都在）；楼层字段只列填过的
    static func entries(profile: Profile, presets: [Preset]) -> [Entry] {
        var out: [Entry] = []
        if let preset = instance(profile: profile, presets: presets) {
            for slot in SlotOrder.ordered(preset.prompts) {
                let source = Source.slot(presetId: preset.id, slotId: slot.id)
                out.append(Entry(path: path(for: source), name: slot.name, content: slot.content, source: source,
                                 isEnabled: slot.isEnabled, isMarker: slot.isMarker,
                                 isEditable: !slot.isAutoFilled))
            }
        }
        for field in Field.allCases {
            let text = profile[keyPath: field.keyPath]
            guard !text.isEmpty else { continue }
            out.append(Entry(path: path(for: .field(field)), name: field.label, content: text, source: .field(field)))
        }
        return out
    }

    // MARK: - 写

    /// 按稳定身份重读当前实例 / 楼层，只改这一段正文，写盘成功才更新内存。
    /// baseline = 打开编辑时看到的正文；别处在这之后改过（且不是改成同样的字）就拒存，不盖掉。
    @MainActor
    static func save(_ path: String, text: String, baseline: String, profileId: String,
                     profiles: ProfileManager, presets: PresetManager) throws {
        guard let source = source(of: path),
              let profile = profiles.profiles.first(where: { $0.id == profileId }) else { throw SaveError.gone }
        switch source {
        case .slot(let presetId, let slotId):
            let (owned, index) = try ownedSlot(profile: profile, presetId: presetId, slotId: slotId, presets: presets)
            var preset = owned
            let slot = preset.prompts[index]
            if slot.isAutoFilled { throw SaveError.readOnly }
            guard slot.content != text else { return }
            guard slot.content == baseline else { throw SaveError.conflict }
            preset.prompts[index].content = text
            try presets.persistNew(preset)
        case .field(let field):
            var updated = profile
            guard updated[keyPath: field.keyPath] != text else { return }
            guard updated[keyPath: field.keyPath] == baseline else { throw SaveError.conflict }
            updated[keyPath: field.keyPath] = text
            try profiles.updateProfileChecked(updated)
        }
    }

    /// 楼层当前在用、且属于这层的实例里按 id 找槽；换了预设 / 槽删了 → gone
    @MainActor
    static func ownedSlot(profile: Profile, presetId: String, slotId: String, presets: PresetManager) throws -> (Preset, Int) {
        guard profile.presetId == presetId,
              let preset = presets.preset(byId: presetId), preset.ownerProfileId == profile.id,
              let index = preset.prompts.firstIndex(where: { $0.id == slotId }) else { throw SaveError.gone }
        return (preset, index)
    }
}

/// Prompt 页插槽编辑页的一次编辑：打开时钉住楼层 + 预设 + 插槽和当时的值。
/// 保存按 id 重找，只提交改过的字段；正文和文件库同一口径做 baseline 冲突检查，成功才算存上
struct PromptSlotEdit: Equatable {
    let profileId: String
    let presetId: String
    let baseline: PromptSlot

    @MainActor
    func commit(name: String, role: String, content: String, depth: Int,
                profiles: ProfileManager, presets: PresetManager) throws {
        guard let profile = profiles.profiles.first(where: { $0.id == profileId }) else { throw PromptFolder.SaveError.gone }
        let (owned, index) = try PromptFolder.ownedSlot(profile: profile, presetId: presetId, slotId: baseline.id, presets: presets)
        var preset = owned
        let current = preset.prompts[index]
        var slot = current
        if name != baseline.name { slot.name = name }
        if role != baseline.role { slot.role = role }
        if !baseline.isMarker && depth != baseline.injectionDepth { SlotOrder.setDepth(depth, of: &slot) }
        if !current.isAutoFilled && content != baseline.content && current.content != content {
            guard current.content == baseline.content else { throw PromptFolder.SaveError.conflict }
            slot.content = content
        }
        guard slot != current else { return }
        preset.prompts[index] = slot
        try presets.persistNew(preset)
    }
}
