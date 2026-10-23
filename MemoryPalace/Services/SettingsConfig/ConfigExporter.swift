import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Settings Config Exporter
//
// 把 app 所有"设置类"数据序列化成 JSON Data。
// 默认不含 Keychain（key/token）和 SwiftData（对话/记忆）。
// 详见 plan-settings-config.md。
// 「包含 API key」（research-magpie 2.8）走 exportWithKeys：同一份 root 加 secrets 段，
// 整份 JSON 交给 ConfigCrypto 用口令加密；OAuth / hub token 仍不带（见 ConfigSecrets）。

enum ConfigExporter {

    /// 导出全部设置为 JSON Data（pretty-printed）。明文，不含任何 key —— 格式与旧版一致。
    static func exportAll(defaults: UserDefaults = .standard) -> Data {
        serialize(buildRoot(defaults: defaults))
    }

    /// 导出全部设置 + API key，整份用口令加密（AES-256-GCM / PBKDF2-SHA256 60 万次）。
    static func exportWithKeys(
        passphrase: String,
        defaults: UserDefaults = .standard,
        secrets: ConfigSecretStore = KeychainConfigSecretStore()
    ) throws -> Data {
        var root = buildRoot(defaults: defaults)
        root["secrets"] = ["api_keys": ConfigSecrets.collect(defaults: defaults, store: secrets)]
        if var excluded = root["_excluded"] as? [String: String] {
            excluded["keychain"] = "OAuth token / CC Hub Token / MCP 密钥（API key 已随本文件加密打包）"
            root["_excluded"] = excluded
        }
        return try ConfigCrypto.seal(serialize(root), passphrase: passphrase)
    }

    private static func buildRoot(defaults: UserDefaults) -> [String: Any] {
        var root: [String: Any] = [:]

        // 元信息
        root["schema_version"] = ConfigSchema.currentVersion
        root["app_version"] = appVersionString()
        root["exported_at"] = ISO8601DateFormatter().string(from: Date())
        root["device"] = deviceName()

        // 按 section 分组
        var sections: [String: [String: Any]] = [:]
        for s in ConfigSchema.Section.allCases {
            sections[s.rawValue] = [:]
        }

        // 1) 标量 keys
        for entry in ConfigSchema.allScalarEntries {
            guard let value = defaults.object(forKey: entry.key) else { continue }
            // 按 kind 强转，避免 NSNumber 在 JSON 序列化时类型漂移
            let converted: Any?
            switch entry.kind {
            case .bool:   converted = (value as? Bool)   ?? (value as? NSNumber)?.boolValue
            case .int:    converted = (value as? Int)    ?? (value as? NSNumber)?.intValue
            case .double: converted = (value as? Double) ?? (value as? NSNumber)?.doubleValue
            case .string: converted = value as? String
            }
            if let v = converted {
                sections[entry.section.rawValue]?[entry.key] = v
            }
        }

        // 2) 结构化 JSON 存档 —— 解码后再嵌入（保 JSON 嵌套结构而不是字符串 blob）
        for entry in ConfigSchema.structuredKeys {
            guard let data = defaults.data(forKey: entry.key) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { continue }

            // credentials 特殊处理：剥掉 .models 数组（fetchModels 可重拉，没必要导）
            // 保留 lastUsedModelId（用户用过的）+ favoriteModels 单独存（☆ 收藏）
            if entry.key == "credentials", let arr = obj as? [[String: Any]] {
                let trimmed: [[String: Any]] = arr.map { dict in
                    var d = dict
                    d.removeValue(forKey: "models")
                    return d
                }
                sections[entry.section.rawValue]?[entry.key] = trimmed
                continue
            }
            sections[entry.section.rawValue]?[entry.key] = obj
        }

        // 3) profiles 头像 base64：savedProfiles 已经在 structuredKeys 里整体导出；
        //    内部头像/封面 Data 字段在 Profile Codable 序列化时被 JSONEncoder 自动转 base64 String。
        //    所以无需特殊处理 —— Profile.userAvatarData (Data) 序列化时就是 base64。

        // 4) 把 section 嵌进 root，但跳过空 section 不污染输出
        for (name, dict) in sections where !dict.isEmpty {
            root[name] = dict
        }

        // 5) 边界提示
        root["_excluded"] = [
            "_note": "以下数据有意排除（config 不是整机备份）",
            "keychain": "API key / OAuth token / CC Hub Token",
            "credentials_models": "每张 API 卡的完整模型列表（导入后点「刷新模型」一键重拉）",
            "content": "角色卡库 / 世界书 / 楼层（含头像）— 是【内容】不是设置",
            "theme_images": "主题的背景图文件（纯色配置已含；图片本身跨机不一定能找到）",
            "swiftdata": "对话 / 消息 / 记忆 / 贴纸 — 用「数据与备份」单独导出"
        ]
        return root
    }

    private static func serialize(_ root: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            // 兜底：返回错误信息 JSON（不应该走到）
            let fallback: [String: Any] = [
                "schema_version": ConfigSchema.currentVersion,
                "error": "序列化失败：\(error.localizedDescription)"
            ]
            return (try? JSONSerialization.data(withJSONObject: fallback, options: .prettyPrinted)) ?? Data()
        }
    }

    /// 文件名：MemoryPalace-Settings-2026-06-14-1030.json；加密版多一段 -encrypted
    static func suggestedFilename(encrypted: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "MemoryPalace-Settings-\(f.string(from: Date()))\(encrypted ? "-encrypted" : "").json"
    }

    // MARK: - helpers

    private static func appVersionString() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "MemoryPalace \(version) (\(build))"
    }

    private static func deviceName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}
