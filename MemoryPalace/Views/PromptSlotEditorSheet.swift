import SwiftUI

@MainActor
final class PromptSlotEditing {
    static let shared = PromptSlotEditing()

    struct Target: Identifiable {
        let profileId: String
        let presetId: String
        let slotId: String
        let label: String
        let initialContent: String

        var versionKey: FileVersionStore.Key {
            PromptSlotEditing.key(profileId: profileId, presetId: presetId, slotId: slotId)
        }
        var id: FileVersionStore.Key { versionKey }
    }

    enum SaveError: LocalizedError, Equatable {
        case profileChanged, conflict

        var errorDescription: String? {
            switch self {
            case .profileChanged: "当前楼层已切换，没有保存。"
            case .conflict: "这段在别处改过，关闭重开再改"
            }
        }
    }

    private let store: FileVersionStore
    private let defaults: UserDefaults
    private var pendingVersions: [FileVersionStore.Key: Task<Void, Never>] = [:]

    init(store: FileVersionStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    nonisolated static func key(profileId: String, presetId: String, slotId: String) -> FileVersionStore.Key {
        .virtual("preset/\(presetId)/\(slotId)", profileId: profileId)
    }

    private func slot(profileId: String, presetId: String, slotId: String,
                      profiles: ProfileManager, presets: PresetManager) throws -> (Preset, Int) {
        guard profiles.currentProfile.id == profileId else { throw SaveError.profileChanged }
        let result = try PromptFolder.ownedSlot(profile: profiles.currentProfile, presetId: presetId,
                                              slotId: slotId, presets: presets)
        guard !result.0.prompts[result.1].isAutoFilled else { throw PromptFolder.SaveError.readOnly }
        return result
    }

    func open(profileId: String, presetId: String, slotId: String, label: String,
              profiles: ProfileManager, presets: PresetManager) throws -> Target {
        let (preset, index) = try slot(profileId: profileId, presetId: presetId, slotId: slotId,
                                       profiles: profiles, presets: presets)
        return Target(profileId: profileId, presetId: presetId, slotId: slotId,
                      label: label, initialContent: preset.prompts[index].content)
    }

    func editor(_ target: Target, profiles: ProfileManager, presets: PresetManager,
                onCancel: @escaping () -> Void) -> FileEditorSheet {
        FileEditorSheet(
            path: "提示词/" + target.label + ".md",
            initialContent: target.initialContent,
            initialModifiedAt: nil,
            currentModifiedAt: { nil },
            reloadExternalContent: {
                let (preset, index) = try self.slot(profileId: target.profileId, presetId: target.presetId,
                                                    slotId: target.slotId, profiles: profiles, presets: presets)
                return ReloadedFileContent(content: preset.prompts[index].content, modifiedAt: nil)
            },
            onSaveAsync: { text, baseline in
                try self.save(text, baseline: baseline, target: target, profiles: profiles, presets: presets)
            },
            onCancel: onCancel,
            title: target.label,
            versionKey: target.versionKey,
            openedProfileId: target.profileId,
            isStandaloneText: true
        )
    }

    func save(_ text: String, baseline: String, target: Target,
              profiles: ProfileManager, presets: PresetManager) throws {
        var (preset, index) = try slot(profileId: target.profileId, presetId: target.presetId,
                                       slotId: target.slotId, profiles: profiles, presets: presets)
        guard preset.prompts[index].content == baseline else { throw SaveError.conflict }
        if text != baseline {
            preset.prompts[index].content = text
            try presets.persistNew(preset)
        }
        pendingVersions.removeValue(forKey: target.versionKey)?.cancel()
    }

    func setInline(_ text: String, profileId: String, presetId: String, slotId: String,
                   profiles: ProfileManager, presets: PresetManager) throws {
        var (preset, index) = try slot(profileId: profileId, presetId: presetId, slotId: slotId,
                                       profiles: profiles, presets: presets)
        guard preset.prompts[index].content != text else { return }
        preset.prompts[index].content = text
        try presets.persistNew(preset)
        recordInline(profileId: profileId, presetId: presetId, slotId: slotId, content: text, presets: presets)
    }

    /// 按稳定身份防抖；离页不取消，别处已改成新内容则不补记过时的快照。
    func recordInline(profileId: String, presetId: String, slotId: String, content: String,
                      presets: PresetManager) {
        let key = Self.key(profileId: profileId, presetId: presetId, slotId: slotId)
        pendingVersions.removeValue(forKey: key)?.cancel()
        guard FileVersionHistory.isEnabled(defaults) else { return }
        let task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            self.pendingVersions[key] = nil
            guard FileVersionHistory.isEnabled(self.defaults),
                  let preset = presets.preset(byId: presetId), preset.ownerProfileId == profileId,
                  preset.prompts.first(where: { $0.id == slotId })?.content == content else { return }
            do {
                try await self.store.record(key: key, content: content, source: .autoSave)
            } catch {
                CacheDiagLog.shared.log("提示词记版本失败：\(error.localizedDescription)")
            }
        }
        pendingVersions[key] = task
    }
}

struct PromptSlotEditorButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12))
                .foregroundColor(Theme.textMuted.opacity(0.6))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("全屏编辑\(label)")
    }
}

struct PromptSlotEditorSheet: View {
    let target: PromptSlotEditing.Target
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(PresetManager.self) private var presets: PresetManager?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let profiles, let presets {
            PromptSlotEditing.shared.editor(target, profiles: profiles, presets: presets, onCancel: { dismiss() })
        }
    }
}
