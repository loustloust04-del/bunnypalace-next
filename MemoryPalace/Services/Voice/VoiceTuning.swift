import Foundation

/// 语音条调音参数：默认值 + 按楼层读写一处管（atrium P3③ 起存在 `Profile`）。
/// 默认值来自《非官方状态标签攻略》推荐（表演感拉满）；人页 › 声音（Mac：设置 › 语音）「声音效果」可调。
enum VoiceTuning {
    /// 老的全局键（P3③ 前存 UserDefaults）；现在只给一次性迁移读
    static let stabilityKey = "voice_stability"
    static let styleKey = "voice_style"
    static let speedKey = "voice_speed"
    static let migratedKey = "voiceTuning.perFloorMigrated"
    /// 「AI 主动发语音」总开关
    static let proactiveKey = "voice_proactive_enabled"
    /// ElevenLabs key 的 Keychain account
    static let keychainAccount = "elevenlabs"

    /// v3 走 API 时 stability 只认三档离散值：0.0 奔放（Creative）/ 0.5 自然 / 1.0 沉稳（Robust）。
    static let defaultStability = 0.0
    static let defaultStyle = 0.88
    static let defaultSpeed = 1.1
    static let similarityBoost = 0.75

    struct Settings: Equatable {
        var stability: Double
        var similarityBoost: Double
        var style: Double
        var speed: Double
    }

    static let defaults = Settings(stability: defaultStability, similarityBoost: similarityBoost,
                                   style: defaultStyle, speed: defaultSpeed)

    /// 这一层生效的参数
    static func current(for profile: Profile) -> Settings {
        Settings(stability: profile.voiceStability, similarityBoost: similarityBoost,
                 style: profile.voiceStyle, speed: profile.voiceSpeed)
    }

    static func set(_ settings: Settings, on profile: inout Profile) {
        profile.voiceStability = settings.stability
        profile.voiceStyle = settings.style
        profile.voiceSpeed = settings.speed
    }

    static func resetToDefaults(_ profile: inout Profile) {
        set(defaults, on: &profile)
    }

    /// 老的全局三键任一设过 → 原样复制到所有已有楼层（没设的那个用默认值）。
    /// 改过的楼层全部落盘成功才落标记，失败下次启动重试；返回是否落了标记
    @discardableResult
    static func migrateGlobalToFloors(profiles: [Profile], defaults store: UserDefaults, persist: ([Profile]) -> Bool) -> Bool {
        guard !store.bool(forKey: migratedKey) else { return false }
        if [stabilityKey, styleKey, speedKey].contains(where: { store.object(forKey: $0) != nil }) {
            let global = Settings(stability: read(stabilityKey, or: defaultStability, from: store),
                                  similarityBoost: similarityBoost,
                                  style: read(styleKey, or: defaultStyle, from: store),
                                  speed: read(speedKey, or: defaultSpeed, from: store))
            let changed = profiles.map { p -> Profile in
                var p = p
                set(global, on: &p)
                return p
            }
            if !changed.isEmpty, !persist(changed) { return false }
        }
        store.set(true, forKey: migratedKey)
        return true
    }

    private static func read(_ key: String, or fallback: Double, from defaults: UserDefaults) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }
}
