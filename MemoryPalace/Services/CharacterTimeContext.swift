import Foundation

// MARK: - 角色时区与作息感知（research-ai-virtual-phone-对比 §3，AVP character-time 的 MP 版）
// 楼层开了「作息感知」且设了有效 IANA 时区才注入。分钟级易变内容——
// 注入位置由 PromptAssembler 按 cacheFriendly 决定（volatile 伪 user 段 / 历史后 system 段）。

enum CharacterTimeContext {

    /// 注入文本；全局开关关 / 时区无效 → nil（不注入）
    static func promptText(profile: Profile, now: Date = Date()) -> String? {
        guard UserDefaults.standard.bool(forKey: "timeAwareness.enabled"),
              let tzName = profile.characterTimeZone?.trimmingCharacters(in: .whitespaces),
              !tzName.isEmpty,
              let tz = TimeZone(identifier: tzName) else { return nil }

        let charName = profile.assistantName.isEmpty ? "助手" : profile.assistantName
        let charTime = formatter(in: tz).string(from: now)
        let sysTz = TimeZone.current
        let instruction = "问候、作息、深夜/清晨/工作时间的判断以\(charName)的本地时间为准，不要复述本段。"

        // 同时区（按当前偏移判定，同名不同写也算同）→ 只给一份，省 token
        if tz.secondsFromGMT(for: now) == sysTz.secondsFromGMT(for: now) {
            return "〔时间〕现在：\(charTime)。\(instruction)"
        }
        let sysTime = formatter(in: sysTz).string(from: now)
        return "〔时间〕用户本地：\(sysTime)（\(sysTz.identifier)）；\(charName)本地：\(charTime)（\(tzName)）。\(instruction)"
    }

    private static func formatter(in tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        f.timeZone = tz
        return f
    }
}
