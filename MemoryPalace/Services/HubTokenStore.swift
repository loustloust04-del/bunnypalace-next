import Foundation

/// hub token 单一入口。优先 Keychain（`cc-bridge` account）；空则从 launchd plist bootstrap 一次。
/// Phase 2 hub 收紧后（loopback 也校验 token），Mac app 主连接 & /pair 请求都从这里拿 token。
///
/// 信任边界：本机同 UID 进程能读 644 权限的 plist——等价"能读你 home 的进程"，
/// 与 SSH key / Keychain（无 ACL prompt 时）同级。iOS 侧不走 bootstrap（无 plist），
/// 只从 Keychain 读（扫码后 CCSettingsView/APICredentialEditor 会写入）。
enum HubTokenStore {
    static let keychainAccount = "cc-bridge"

    #if os(macOS)
    /// install-launchd.sh 装的 hub plist，label 前缀不固定（`<前缀>.cc-bridge-hub.plist`）
    private static var plistPath: String? {
        let dir = "\(NSHomeDirectory())/Library/LaunchAgents"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".cc-bridge-hub.plist") }.sorted().first.map { "\(dir)/\($0)" }
    }
    #endif

    /// 拿 token。幂等：keychain 有直接返回；空则 macOS 上 bootstrap 读 plist 存入。
    /// 每次 connect 前调，重启 hub 后自动补上，无需 Mac app 重启。
    static func get() -> String? {
        if TestHostIsolation.blocks(.hub) { return nil }   // #035：测试宿主不取口令、不从 plist 回写钥匙串
        if let existing = KeychainStore.get(account: keychainAccount), !existing.isEmpty {
            return existing
        }
        #if os(macOS)
        if let bootstrapped = readTokenFromLaunchdPlist(), !bootstrapped.isEmpty {
            _ = KeychainStore.set(bootstrapped, account: keychainAccount, sync: false)
            print("[HubTokenStore] bootstrapped from launchd plist")
            return bootstrapped
        }
        #endif
        return nil
    }

    #if os(macOS)
    private static func readTokenFromLaunchdPlist() -> String? {
        guard let plistPath, let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: String] else {
            return nil
        }
        let token = env["MP_CC_HUB_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }
    #endif
}
