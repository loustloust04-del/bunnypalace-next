import Foundation

// MARK: - Settings Config Importer
//
// 把 ConfigExporter 导出的 JSON 应用回 UserDefaults。
// 全替换语义（plan C-D3 选 A）：导入文件覆盖现有设置，旧值丢。
// 明文文件不动 Keychain（旧格式照旧导入）。
// 口令加密文件（ConfigExporter.exportWithKeys）解开后按 magpie 规则写回 API key：
// 同 account 替换；备份没带的保留本机；OAuth / hub token 不写（ConfigSecrets）。
// 调用方在 UI 层应该已经做过 confirmation alert。

enum ConfigImporter {

    enum ImportError: LocalizedError {
        case malformedJSON(String)
        case missingSchemaVersion
        case unsupportedSchemaVersion(Int)
        case passphraseRequired

        var errorDescription: String? {
            switch self {
            case .passphraseRequired: return "这是口令加密的设置文件，需要输入导出时设的口令"
            case .malformedJSON(let s): return "文件 JSON 解析失败：\(s)"
            case .missingSchemaVersion: return "文件缺 schema_version 字段，可能不是有效的设置导出文件"
            case .unsupportedSchemaVersion(let v): return "schema_version=\(v) 比当前 app 知道的 \(ConfigSchema.currentVersion) 还高，无法导入（请升级 app）"
            }
        }
    }

    struct Result {
        /// 写回 Keychain 的 key 条数（明文文件恒为 0）
        var restoredKeys = 0
    }

    /// 口令解开后的明文 bundle。只有经 unlock 得到的才会写 Keychain。
    struct UnlockedConfig {
        fileprivate let plain: Data
    }

    static func isEncrypted(_ data: Data) -> Bool { ConfigCrypto.isEncrypted(data) }

    /// 用口令解开加密文件。口令错 / 文件被改 → ConfigCrypto.CryptoError.wrongPassphrase
    static func unlock(_ data: Data, passphrase: String) throws -> UnlockedConfig {
        UnlockedConfig(plain: try ConfigCrypto.open(data, passphrase: passphrase))
    }

    /// 解析 + 校验 + 应用。失败 throw。加密文件需带 passphrase，否则 .passphraseRequired。
    @discardableResult
    static func importAll(
        _ data: Data,
        passphrase: String? = nil,
        defaults: UserDefaults = .standard,
        secrets: ConfigSecretStore = KeychainConfigSecretStore()
    ) throws -> Result {
        if ConfigCrypto.isEncrypted(data) {
            guard let passphrase else { throw ImportError.passphraseRequired }
            return try importAll(unlock(data, passphrase: passphrase), defaults: defaults, secrets: secrets)
        }
        return try apply(data, allowSecrets: false, defaults: defaults, secrets: secrets)
    }

    @discardableResult
    static func importAll(
        _ unlocked: UnlockedConfig,
        defaults: UserDefaults = .standard,
        secrets: ConfigSecretStore = KeychainConfigSecretStore()
    ) throws -> Result {
        try apply(unlocked.plain, allowSecrets: true, defaults: defaults, secrets: secrets)
    }

    private static func apply(
        _ data: Data,
        allowSecrets: Bool,
        defaults: UserDefaults,
        secrets: ConfigSecretStore
    ) throws -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw ImportError.malformedJSON("不是合法 JSON 对象")
        }
        guard let version = root["schema_version"] as? Int else {
            throw ImportError.missingSchemaVersion
        }
        if version > ConfigSchema.currentVersion {
            throw ImportError.unsupportedSchemaVersion(version)
        }

        // 1) 标量 keys
        for entry in ConfigSchema.allScalarEntries {
            guard let sectionDict = root[entry.section.rawValue] as? [String: Any] else { continue }
            guard let raw = sectionDict[entry.key] else { continue }
            switch entry.kind {
            case .bool:
                if let v = raw as? Bool { defaults.set(v, forKey: entry.key) }
                else if let n = raw as? NSNumber { defaults.set(n.boolValue, forKey: entry.key) }
            case .int:
                if let v = raw as? Int { defaults.set(v, forKey: entry.key) }
                else if let n = raw as? NSNumber { defaults.set(n.intValue, forKey: entry.key) }
            case .double:
                if let v = raw as? Double { defaults.set(v, forKey: entry.key) }
                else if let n = raw as? NSNumber { defaults.set(n.doubleValue, forKey: entry.key) }
            case .string:
                if let v = raw as? String { defaults.set(v, forKey: entry.key) }
            }
        }

        // 2) 结构化 JSON 存档：把嵌套 JSON 重新序列化成 Data 写回
        for entry in ConfigSchema.structuredKeys {
            guard let sectionDict = root[entry.section.rawValue] as? [String: Any] else { continue }
            guard var obj = sectionDict[entry.key] else { continue }

            // credentials 特殊处理：导出时剥了 .models，导入时按 presetId 补默认 preset.models
            // 让用户至少能看到几个预设模型（想全量再点「刷新模型」）
            if entry.key == "credentials", let arr = obj as? [[String: Any]] {
                let filled: [[String: Any]] = arr.map { dict in
                    var d = dict
                    if d["models"] == nil,
                       let presetId = d["presetId"] as? String,
                       let preset = APIProvider.presets.first(where: { $0.id == presetId }) {
                        let cardId = (d["id"] as? String) ?? presetId
                        d["models"] = preset.models.map { m in
                            ["credentialId": cardId, "modelId": m.modelId, "name": m.name]
                        }
                    } else if d["models"] == nil {
                        d["models"] = []
                    }
                    return d
                }
                obj = filled
            }

            // 语音服务列表按 id 合并：备份里的同 id 覆盖、新的追加，本机独有的保留（楼层可能还引用着）
            if entry.key == VoiceServiceStore.listKey, let incoming = obj as? [[String: Any]] {
                obj = mergeVoiceServices(local: defaults.data(forKey: entry.key), incoming: incoming)
            }

            if let data = try? JSONSerialization.data(withJSONObject: obj, options: []) {
                defaults.set(data, forKey: entry.key)
            }
        }

        // 3) API key：只认口令解开的 bundle；明文文件里的 secrets 段一律忽略
        var result = Result()
        if allowSecrets,
           let secretSection = root["secrets"] as? [String: Any],
           let keys = secretSection["api_keys"] as? [String: String] {
            result.restoredKeys = ConfigSecrets.restore(keys, into: secrets)
        }

        // 4) 触发各 manager reload（让 view 立即看到新设置）。
        //    各 manager 大多通过 @Observable + UserDefaults 直读，不需要显式刷新，
        //    但 ProviderManager 维持自己的 credentials/favoriteModelIds @State，得 reload。
        //    ProfileManager 的 profiles list 也是 init 时一次性 load，需要重启 app 完整生效。
        //    UI 层在 alert 里提示"导入成功 · 请关闭设置重开 app"。
        NotificationCenter.default.post(name: .settingsConfigDidImport, object: nil)
        // B-8（plan-paging-decouple B-0 表 1 #2 #5）：气泡半透明开关（ThemeManager.resolvedTokenSet 直读）和文件库 iCloud
        // 文案没有自己的观察，正常界面路径各自会通知；导入路径原来只能等下一次翻页的根重交
        ThemeManager.shared.notifyThemeChange()
        NotificationCenter.default.post(name: .fileLibraryDidChange, object: nil)
        return result
    }

    /// 本机列表顺序在前（同 id 换成备份里的），备份里新的 id 按原顺序追加；按字典合并，不认识的字段原样保留
    static func mergeVoiceServices(local: Data?, incoming: [[String: Any]]) -> [[String: Any]] {
        let localList = local.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? []
        var incomingById: [String: [String: Any]] = [:]
        for s in incoming { if let id = s["id"] as? String { incomingById[id] = s } }
        var merged: [[String: Any]] = []
        var seen = Set<String>()
        for s in localList {
            guard let id = s["id"] as? String else { continue }
            merged.append(incomingById[id] ?? s)
            seen.insert(id)
        }
        for s in incoming {
            guard let id = s["id"] as? String, !seen.contains(id) else { continue }
            merged.append(s)
            seen.insert(id)
        }
        return merged
    }
}

extension Notification.Name {
    /// 导入完成 → ProviderManager 等监听重 load
    static let settingsConfigDidImport = Notification.Name("settingsConfigDidImport")
}
