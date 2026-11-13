import Foundation

/// Mac 配对页从哪个 hub 拿二维码（#046 刀 2）。三条路：
/// - 这台 Mac 已有外部 hub（launchd 装的 / 7890 有人应答）→ 7890 + 本机外部 hub 的口令（`externalHubToken`：plist，粟粟那台走这条）
/// - 没有外部 hub、内嵌 hub 在跑 → 它的端口 + Keychain `cc-bridge-hub-token`
/// - 都没有 → 提示先打开「启动 CC 桥接」开关
enum PairingEndpoint: Equatable {
    case ready(port: Int, token: String)
    /// 外部 hub 在，但口令读不到（plist 没有、主 hub 配的也不是本机 7890）
    case missingToken
    case noHub

    static let externalPort = 7890

    static func resolve(externalHub: Bool, externalToken: String?, embeddedPort: Int?, embeddedToken: String?) -> PairingEndpoint {
        if externalHub {
            guard let token = externalToken, !token.isEmpty else { return .missingToken }
            return .ready(port: externalPort, token: token)
        }
        guard let port = embeddedPort else { return .noHub }
        guard let token = embeddedToken, !token.isEmpty else { return .missingToken }
        return .ready(port: port, token: token)
    }

    /// 外部 hub（本机 7890）的 /pair 口令：launchd plist 里的；没有 plist（手动跑的 hub）时，只有主 hub 配对目标就是本机 7890
    /// 才用主 hub 本机副本。都确认不了 = nil（不发请求）。绝不读 `cc-bridge`（plan-multi-hub recheck1 N1）
    static func externalHubToken(plistToken: String?, pairedPrimaryToken: String?, primaryURLs: [URL]) -> String? {
        if let plistToken, !plistToken.isEmpty { return plistToken }
        let targetsExternal = !primaryURLs.isEmpty && primaryURLs.allSatisfy {
            CCHubRegistry.isLoopback($0) && $0.port == externalPort
        }
        guard targetsExternal, let pairedPrimaryToken, !pairedPrimaryToken.isEmpty else { return nil }
        return pairedPrimaryToken
    }

    /// 二维码出不来时那一句
    var failureText: String? {
        switch self {
        case .ready: return nil
        case .missingToken: return "读不到 hub 的口令，二维码生成不了"
        case .noHub: return "这台 Mac 上还没有 hub 在跑：先打开「启动 CC 桥接」开关"
        }
    }
}

/// 「这台 Mac 已经有 hub 在跑」的判定（astra P1-2）：有就绝不起内嵌 hub，免得和 launchd 的双开。
enum ExternalHub {
    /// install-launchd.sh 装的 plist 名是 `<前缀>.cc-bridge-hub.plist`（同 `HubTokenStore.plistPath`）。只读目录列表，不碰 launchd。
    static func plistExists(inLaunchAgents dir: URL) -> Bool {
        #if os(macOS)
        if BenchIsolation.active { return false }
        #endif
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { $0.hasSuffix(".cc-bridge-hub.plist") }
    }

    /// 7890 有应答但那正是内嵌 hub 自己（OS 恰好分到 7890）不算外部
    static func isExternal(plistExists: Bool, healthResponds: Bool, embeddedPort: Int?) -> Bool {
        plistExists || (healthResponds && embeddedPort != PairingEndpoint.externalPort)
    }

    #if os(macOS)
    static var userLaunchAgents: URL {
        AppPaths.checked(AppPaths.home.appendingPathComponent("Library/LaunchAgents", isDirectory: true))
    }

    /// `GET http://127.0.0.1:7890/health`，拿到任何 HTTP 状态码就算有人在（同 WS client 探测口径），1.5 秒没回算没有。
    static func healthResponds() async -> Bool {
        if BenchIsolation.active { return false }
        guard let url = URL(string: "http://127.0.0.1:\(PairingEndpoint.externalPort)/health") else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return response is HTTPURLResponse
    }
    #endif
}
