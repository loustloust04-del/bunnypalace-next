import Foundation

/// hub token：主 hub 旧条目的账户名（`cc-bridge`）+ 本机 launchd 外部 hub 的 plist 口令。
/// Phase 2 hub 收紧后（loopback 也校验 token）。plan-multi-hub recheck1 起：连接只用主 hub 本机副本（CCHubRegistry），
/// plist 口令只在配对目标是本机回环时由 Registry 补进副本；Mac 配对页 /pair 只用 plist 口令。
///
/// 信任边界：本机同 UID 进程能读 644 权限的 plist——等价"能读你 home 的进程"，
/// 与 SSH key / Keychain（无 ACL prompt 时）同级。iOS 侧不走 bootstrap（无 plist），
/// 只从 Keychain 读（扫码后 CCSettingsView/APICredentialEditor 会写入）。
enum HubTokenStore {
    static let keychainAccount = "cc-bridge"

    #if os(macOS)
    /// install-launchd.sh 装的 hub plist，label 前缀不固定（`<前缀>.cc-bridge-hub.plist`）
    private static var plistPath: String? {
        let dir = AppPaths.checked(AppPaths.home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)).path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { $0.hasSuffix(".cc-bridge-hub.plist") }.sorted().first.map { "\(dir)/\($0)" }
    }
    #endif

    /// 这台 Mac 本机 launchd 外部 hub 的口令（plist 里的 MP_CC_HUB_TOKEN），只读、不写钥匙串。
    /// 跟本机外部 hub 绑定的只有它：`cc-bridge` 条目会经 iCloud 被别的设备改成别台 hub 的口令，不能拿来连 / 配对本机 hub（plan-multi-hub recheck1 #1 / N1）。
    /// 主 hub 的本机副本由 CCHubRegistry 核过配对目标后再用它补；Mac 配对二维码页用它请求 /pair。iOS / 测试宿主 = nil
    static func launchdPlistToken() -> String? {
        if TestHostIsolation.blocks(.hub) { return nil }   // #035：测试宿主不取口令
        #if os(macOS)
        return readTokenFromLaunchdPlist()
        #else
        return nil
        #endif
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
