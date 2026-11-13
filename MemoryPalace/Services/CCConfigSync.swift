import Foundation

/// CC 设置以 hub 为准（铲屎二期刀 5 D-B1，hub 侧 cc-bridge/cc-config.ts）：
/// 连上 hub 时整份带上「本机每项最后一次手改的时间」，hub 只收比它记的更新的那几项（第一次没落盘时整份收下当初值）；
/// hub 改完回推 `cc_config`，主 hub 的值写回本机，设置页显示的就是 hub 在用的。
/// 推送名 / 称呼跟着当前楼层走，不在这里（每次连上照发）
enum CCConfigSync {
    static let editedAtKey = "ccConfigEditedAt"

    /// wire 名 ↔ 本机 UserDefaults key
    static let fields: [(wire: String, key: String)] = [
        ("nudgeEnabled", "ccNudgeEnabled"),
        ("newSessionTransport", "ccNewSessionStream"),
        ("idleMinMin", "ccNudgeIdleMin"),
        ("idleMaxMin", "ccNudgeIdleMax"),
        ("quietStartMin", "ccNudgeQuietStartMin"),
        ("quietEndMin", "ccNudgeQuietEndMin"),
        ("cooldownMin", "ccNudgeCooldown"),
        ("nudgeTemplate", "ccNudgeTemplate"),
    ]

    /// 设置页手改了这几项（只在用户动手时调，hub 回推写本机不走这里）：记时间，发给所有 hub
    @MainActor
    static func edited(_ wires: String..., defaults: UserDefaults = .standard, now: Date = Date()) {
        markEdited(wires, defaults: defaults, now: now)
        CCHubRegistry.shared.broadcastCCConfig()
    }

    static func markEdited(_ wires: [String], defaults: UserDefaults, now: Date) {
        var map = defaults.dictionary(forKey: editedAtKey) as? [String: Double] ?? [:]
        for w in wires { map[w] = (now.timeIntervalSince1970 * 1000).rounded() }
        defaults.set(map, forKey: editedAtKey)
    }

    /// set_cc_config 里的设置项 + editedAt（名字、保暖表由调用方补）
    static func payload(_ d: UserDefaults) -> [String: Any] {
        var p: [String: Any] = [
            "nudgeEnabled": (d.object(forKey: "ccNudgeEnabled") as? Bool) ?? true,
            "newSessionTransport": d.bool(forKey: "ccNewSessionStream") ? "stream" : "tmux",
            // 空 = 默认模板；hub 只在这项手改过（比它记的新）时才当「清空回默认」
            "nudgeTemplate": d.string(forKey: "ccNudgeTemplate") ?? "",
            "editedAt": d.dictionary(forKey: editedAtKey) as? [String: Double] ?? [:],
        ]
        if let v = d.object(forKey: "ccNudgeIdleMin") as? Int, v > 0 { p["idleMinMin"] = v }
        if let v = d.object(forKey: "ccNudgeIdleMax") as? Int, v > 0 { p["idleMaxMin"] = v }
        if let v = d.object(forKey: "ccNudgeQuietStartMin") as? Int { p["quietStartMin"] = v }
        if let v = d.object(forKey: "ccNudgeQuietEndMin") as? Int { p["quietEndMin"] = v }
        if let v = d.object(forKey: "ccNudgeCooldown") as? Int, v >= 0 { p["cooldownMin"] = v }
        return p
    }

    /// hub 回推的 `cc_config` 写本机。本机手改得比 hub 记的新的那项不覆盖：那次改动还在路上（或 hub 当时没连着），
    /// 下一次 set_cc_config 会带过去，hub 收下再推回来
    static func apply(_ obj: [String: Any], to d: UserDefaults) {
        let hubAt = obj["updatedAt"] as? [String: Any] ?? [:]
        let localAt = d.dictionary(forKey: editedAtKey) as? [String: Double] ?? [:]
        for (wire, key) in fields {
            if let mine = localAt[wire], mine > ((hubAt[wire] as? NSNumber)?.doubleValue ?? 0) { continue }
            switch wire {
            case "nudgeEnabled":
                if let v = obj[wire] as? Bool, d.object(forKey: key) as? Bool != v { d.set(v, forKey: key) }
            case "newSessionTransport":
                if let v = obj[wire] as? String, v == "stream" || v == "tmux", d.bool(forKey: key) != (v == "stream") { d.set(v == "stream", forKey: key) }
            case "nudgeTemplate":
                let v = obj[wire] as? String ?? ""
                if (d.string(forKey: key) ?? "") != v {
                    if v.isEmpty { d.removeObject(forKey: key) } else { d.set(v, forKey: key) }
                }
            default:
                if let v = (obj[wire] as? NSNumber)?.intValue, d.object(forKey: key) as? Int != v { d.set(v, forKey: key) }
            }
        }
    }
}
