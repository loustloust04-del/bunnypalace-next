import Foundation

/// 语音条调音参数：AppStorage 键 + 默认值一处管。
/// 默认值来自《非官方状态标签攻略》推荐（表演感拉满）；设置-朗读「声音效果」折叠节可调。
enum VoiceTuning {
    static let stabilityKey = "voice_stability"
    static let styleKey = "voice_style"
    static let speedKey = "voice_speed"
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

    /// 当前生效参数（未设置过的键回落默认值）
    static func current(defaults: UserDefaults = .standard) -> Settings {
        Settings(
            stability: read(stabilityKey, or: defaultStability, from: defaults),
            similarityBoost: similarityBoost,
            style: read(styleKey, or: defaultStyle, from: defaults),
            speed: read(speedKey, or: defaultSpeed, from: defaults)
        )
    }

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: stabilityKey)
        defaults.removeObject(forKey: styleKey)
        defaults.removeObject(forKey: speedKey)
    }

    private static func read(_ key: String, or fallback: Double, from defaults: UserDefaults) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }
}
