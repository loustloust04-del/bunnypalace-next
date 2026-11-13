import Foundation

// MARK: - 角色时区与作息感知（research-ai-virtual-phone-对比 §3，AVP character-time 的 MP 版）
// 楼层开了「作息感知」且设了有效 IANA 时区才注入。分钟级易变内容——
// 注入位置由 PromptAssembler 按 cacheFriendly 决定（volatile 伪 user 段 / 历史后 system 段）。

enum CharacterTimeContext {

    /// 注入文本；这一层「作息感知」关 / 时区无效 → nil（不注入）
    static func promptText(profile: Profile, now: Date = Date()) -> String? {
        guard profile.timeAwarenessEnabled,
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

    /// 老的全局开关（09-11 起全局一个）；atrium P3② 起只给一次性迁移读
    static let legacyGlobalKey = "timeAwareness.enabled"
    static let migratedKey = "timeAwareness.perFloorMigrated"

    /// 全局开关开着 → 所有已有楼层都开。改过的楼层全部落盘成功才落标记，失败下次启动重试；返回是否落了标记
    @discardableResult
    static func migrateGlobalSwitch(profiles: [Profile], defaults: UserDefaults, persist: ([Profile]) -> Bool) -> Bool {
        guard !defaults.bool(forKey: migratedKey) else { return false }
        if defaults.bool(forKey: legacyGlobalKey) {
            let changed = profiles.filter { !$0.timeAwarenessEnabled }.map { p -> Profile in
                var p = p
                p.timeAwarenessEnabled = true
                return p
            }
            if !changed.isEmpty, !persist(changed) { return false }
        }
        defaults.set(true, forKey: migratedKey)
        return true
    }

    private static func formatter(in tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        f.timeZone = tz
        return f
    }
}
