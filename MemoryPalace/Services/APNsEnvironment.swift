import Foundation

/// 本包拿到的 APNs token 属于哪个环境，随 token 报给 hub（hub 按它选 sandbox / production host）。
///
/// 由**签名**决定，不是编译配置：读包里 `embedded.mobileprovision` 的 `aps-environment`。
/// Debug / 开发签名 → development → sandbox；Ad Hoc → production；
/// App Store / TestFlight 包里没有 profile → production。
enum APNsEnvironment {
    static let current: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        return environment(fromProvisioningProfile: url.flatMap { try? Data(contentsOf: $0) })
        #endif
    }()

    /// profile 是 CMS 签名包，明文 plist 夹在 `<?xml` … `</plist>` 之间。
    static func environment(fromProvisioningProfile data: Data?) -> String {
        guard let data,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String
        else { return "production" }
        return aps == "development" ? "sandbox" : "production"
    }
}
