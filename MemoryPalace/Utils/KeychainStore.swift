import Foundation
import Security
import os

/// 薄封装 Keychain 通用密码条目，支持可选 iCloud 同步。
/// Service 统一；account 就是 providerId。
/// 各函数的 service 参数默认就是这个；加密值（SecretVault）传自己的 service。
enum KeychainStore {
    static let service = "com.susu.MemoryPalace.apikey"
    private static let log = Logger(subsystem: "com.susu.MemoryPalace", category: "keychain")

    /// #042：锁屏来电要读的几条（hub 口令 / 语音 key / 老 ElevenLabs key）放宽到「首次解锁后可读」，其余保持系统默认。
    /// 按 account 判、不按 service（测试 service 也能覆盖）。只在 iOS 写入 / 迁移时用。
    static func accessibleOverride(account: String) -> CFString? {
        account == "cc-bridge" || account == "elevenlabs" || account.hasPrefix("voice.") ? kSecAttrAccessibleAfterFirstUnlock : nil
    }

    /// 写入/更新/删除（value == nil 等价于 remove）。成功返回 true。
    /// 为保证一致性：写入前先删除同 account 的所有条目（本机+云），再按 sync 写一份。
    @discardableResult
    static func set(_ value: String?, account: String, sync: Bool, service: String = KeychainStore.service) -> Bool {
        guard let value, !value.isEmpty else {
            remove(account: account, service: service)
            return true
        }

        // 先清掉同 account 的旧条目（不管同步模式）
        _ = SecItemDelete(TestHostIsolation.keychainQuery(anyQuery(account: account, service: service)) as CFDictionary)

        let data = Data(value.utf8)
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrSynchronizable as String: sync ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        #if os(iOS)
        if let accessible = accessibleOverride(account: account) { attrs[kSecAttrAccessible as String] = accessible }
        #endif

        let status = SecItemAdd(TestHostIsolation.keychainQuery(attrs) as CFDictionary, nil)
        if status != errSecSuccess {
            print("[KeychainStore] set failed account=\(account) sync=\(sync) status=\(status)")
            return false
        }
        return true
    }

    static func get(account: String, service: String = KeychainStore.service) -> String? {
        var query = anyQuery(account: account, service: service)
        query[kSecReturnData as String] = kCFBooleanTrue!
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(TestHostIsolation.keychainQuery(query) as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound {
                log.error("get failed account=\(account, privacy: .public) status=\(status, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 只看能不能读（不取值）：诊断用，锁屏读不到是 errSecInteractionNotAllowed(-25308)
    static func readStatus(account: String, service: String = KeychainStore.service) -> OSStatus {
        var query = anyQuery(account: account, service: service)
        query[kSecReturnData as String] = kCFBooleanTrue!
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(TestHostIsolation.keychainQuery(query) as CFDictionary, &out)
    }

    static func remove(account: String, service: String = KeychainStore.service) {
        let status = SecItemDelete(TestHostIsolation.keychainQuery(anyQuery(account: account, service: service)) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[KeychainStore] remove failed account=\(account) status=\(status)")
        }
    }

    /// 列出当前 service 下所有 account（本机+云）。用于开关同步时统一迁移。
    static func allAccounts(service: String = KeychainStore.service) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue!,
        ]

        var out: CFTypeRef?
        let status = SecItemCopyMatching(TestHostIsolation.keychainQuery(query) as CFDictionary, &out)
        guard status == errSecSuccess, let items = out as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// 一次性读出当前 service 下所有 account→value 映射。
    /// 一次 SecItemCopyMatching 只触发一次 Keychain 授权弹窗，避免循环调 get 导致狂弹。
    static func getAll(service: String = KeychainStore.service) -> [String: String] {
        // macOS legacy 钥匙串不支持 kSecMatchLimitAll + kSecReturnData 同用，会返回
        // errSecParam(-50) → 整批读空 → 启动后所有 key 像被清空（iOS 支持该组合故无此症）。
        // 改成：批量只取 account 名（仅属性，不取 data），再逐条 get() 取值。
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue!,
        ]

        var out: CFTypeRef?
        let status = SecItemCopyMatching(TestHostIsolation.keychainQuery(query) as CFDictionary, &out)
        guard status == errSecSuccess, let items = out as? [[String: Any]] else {
            if status != errSecItemNotFound {
                print("[KeychainStore] getAll failed status=\(status)")
            }
            return [:]
        }

        // 关掉钥匙串交互：旧签名创建的"外来"条目读 data 需要弹 login 密码框，逐条读会狂弹 +
        // 卡死主线程。关掉后外来条目静默失败(errSecInteractionNotAllowed)被跳过，本 app
        // 自己写的条目（在 ACL 可信列表里）照常静默读出。
        #if os(macOS)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(!TestHostIsolation.active) }   // #035 测试宿主全程不弹
        #endif

        var result: [String: String] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            if let value = get(account: account, service: service) {
                result[account] = value
            }
        }
        return result
    }

    #if os(iOS)
    /// 把名单内、还不是目标可访问性的条目改过去。只用 SecItemUpdate 改属性：失败的条目原样留着下次再试，不丢 key。
    /// 要解锁状态才能改（update 要解密）；幂等，已是目标值的跳过。返回改了几条 + 失败的 account → status。
    @discardableResult
    static func migrateAccessibility(service: String = KeychainStore.service) -> (migrated: Int, failures: [String: OSStatus]) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue!,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(TestHostIsolation.keychainQuery(query) as CFDictionary, &out)
        guard status == errSecSuccess, let items = out as? [[String: Any]] else {
            if status != errSecItemNotFound { log.error("migrate query failed status=\(status, privacy: .public)") }
            return (0, [:])
        }
        var migrated = 0, skipped = 0
        var failures: [String: OSStatus] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let target = accessibleOverride(account: account) else { continue }
            if let current = item[kSecAttrAccessible as String] as? String, current == target as String {
                skipped += 1; continue
            }
            let synced = (item[kSecAttrSynchronizable as String] as? Bool) ?? false
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: synced ? kCFBooleanTrue! : kCFBooleanFalse!,
            ]
            let result = SecItemUpdate(TestHostIsolation.keychainQuery(match) as CFDictionary, [kSecAttrAccessible as String: target] as CFDictionary)
            if result == errSecSuccess { migrated += 1 } else { failures[account] = result }
        }
        let failed = failures.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        log.notice("accessibility migrated=\(migrated, privacy: .public) skipped=\(skipped, privacy: .public) failed=[\(failed, privacy: .public)]")
        return (migrated, failures)
    }
    #endif

    // MARK: - Private

    private static func anyQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }
}
