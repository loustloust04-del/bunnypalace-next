import Foundation
import Network
import dnssd

// MARK: - Proxy Discovery（局域网自动发现 claude-proxy）
//
// 契约 C1：Bonjour 服务类型 `_mpclaude._tcp`，TXT = v / path / proto / auth（+ 可选 ts）。
//
// 两个 API 分工（实测定的，不是随手选）：
//   · NWBrowser  —— 浏览 + TXT + 状态。本地网络权限被拒只有它报得出来（.waiting/.failed 里
//                   带 DNSServiceErrorType，见 isPermissionDenied）。
//   · NetService —— 把实例名解析成 `<mac>.local.` 主机名。NWConnection 解析出来的是 IP
//                   （实测 `192.168.31.20%en0:8792`，还带 interface scope），而 C2 要的是
//                   换 Wi-Fi 不变的 mDNS 名，所以这一段必须走 NetService。

// MARK: - TXT 记录（C1）

struct ProxyServiceTXT: Equatable {
    /// 协议版本（TXT `v`）
    var version: String
    /// API 前缀（TXT `path`），永远以 `/` 开头、不带结尾 `/`
    var apiPath: String
    /// 支持的对话协议（TXT `proto`，逗号分隔）
    var protocols: [String]
    /// 准入模式（TXT `auth`）。C4 落定后是 `lan`＝网关白名单准入，不是"无鉴权"。
    var auth: String
    /// Tailscale 地址（TXT `ts`），出门用。proxy 拿不到 Tailscale IP 时整个字段省略，不能假设存在。
    var tailscaleIP: String?

    static func parse(_ dict: [String: String]) -> ProxyServiceTXT {
        var path = (dict["path"] ?? "").trimmingCharacters(in: .whitespaces)
        if path.isEmpty { path = "/v1" }
        if !path.hasPrefix("/") { path = "/" + path }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        let protos = (dict["proto"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        let auth = (dict["auth"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let ts = (dict["ts"] ?? "").trimmingCharacters(in: .whitespaces)

        return ProxyServiceTXT(
            version: (dict["v"] ?? "").trimmingCharacters(in: .whitespaces),
            apiPath: path,
            protocols: protos,
            auth: auth.isEmpty ? "lan" : auth,
            tailscaleIP: ts.isEmpty ? nil : ts
        )
    }
}

// MARK: - 发现结果（C2 的输入）

struct DiscoveredProxy: Identifiable, Equatable {
    /// Bonjour 实例名，同域内唯一 —— 直接当 id
    let id: String
    /// 解析出的主机名，形如 `mimiair.local.`
    let host: String
    let port: Int
    let txt: ProxyServiceTXT

    var displayName: String { id }

    /// 去掉 FQDN 结尾点的主机名
    var hostname: String {
        host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    var displayHost: String { "\(hostname):\(port)" }

    /// C2：`http://<host>:<port>/v1` —— 卡里的 baseURL 必须自带 `/v1`
    var baseURL: String { "http://\(hostname):\(port)\(txt.apiPath)" }

    /// 探活端点在根路径，不带 API 前缀
    var healthURL: URL? { URL(string: "http://\(hostname):\(port)/health") }
}

// MARK: - 状态机（纯逻辑，单测覆盖）

enum ProxyDiscoveryState: Equatable {
    case idle
    case searching
    case found(Int)
    /// 搜完了一个来回还是零结果
    case empty
    case permissionDenied
    case unavailable(String)
}

enum ProxyDiscoveryEvent: Equatable {
    case started
    case stopped
    case browserReady
    case browserBlocked(denied: Bool, reason: String)
    case servicesChanged(Int)
    case searchDeadlineReached
}

struct ProxyDiscoveryMachine {
    private(set) var state: ProxyDiscoveryState = .idle
    private var count = 0
    private var deadlinePassed = false

    mutating func apply(_ event: ProxyDiscoveryEvent) {
        switch event {
        case .started:
            count = 0
            deadlinePassed = false
            state = .searching
        case .stopped:
            count = 0
            deadlinePassed = false
            state = .idle
        case .browserReady:
            state = settled()
        case .browserBlocked(let denied, let reason):
            state = denied ? .permissionDenied : .unavailable(reason)
        case .servicesChanged(let n):
            // 拿得到结果 = 权限没问题，之前的 denied/unavailable 自然被顶掉
            count = n
            state = settled()
        case .searchDeadlineReached:
            deadlinePassed = true
            switch state {
            case .permissionDenied, .unavailable:
                return   // 失败态不因为"搜了一会儿"改口
            default:
                state = settled()
            }
        }
    }

    private func settled() -> ProxyDiscoveryState {
        if count > 0 { return .found(count) }
        return deadlinePassed ? .empty : .searching
    }
}

// MARK: - baseURL 规整（去重键，刀4）

enum ProxyBaseURL {
    /// 卡去重比的是规整后的 baseURL：大小写、FQDN 结尾点、默认端口、结尾斜杠、query 都不算差异。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.contains("://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased() else {
            return s.lowercased()
        }
        comps.scheme = scheme
        if var h = comps.host?.lowercased() {
            while h.hasSuffix(".") { h.removeLast() }
            comps.host = h
        }
        if let p = comps.port,
           (scheme == "http" && p == 80) || (scheme == "https" && p == 443) ||
           (scheme == "ws" && p == 80) || (scheme == "wss" && p == 443) {
            comps.port = nil
        }
        var path = comps.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        comps.path = (path == "/") ? "" : path
        comps.query = nil
        comps.fragment = nil
        return (comps.string ?? s).lowercased()
    }
}

// MARK: - 发现服务（跨平台一份）
//
// 所有回调都钉在 main queue：NWBrowser 用 .main 起，NetService 挂 main runloop。

@Observable
final class ProxyDiscovery {
    static let serviceType = "_mpclaude._tcp"
    /// 搜多久还零结果就改口说"没找到"（mDNS 通常 1s 内就有应答）
    static let searchDeadline: TimeInterval = 3.0

    private(set) var state: ProxyDiscoveryState = .idle
    private(set) var services: [DiscoveredProxy] = []

    @ObservationIgnored private var machine = ProxyDiscoveryMachine()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var txtByName: [String: ProxyServiceTXT] = [:]
    @ObservationIgnored private var resolvers: [String: ProxyHostResolver] = [:]
    @ObservationIgnored private var deadlineTimer: DispatchSourceTimer?

    func start() {
        guard browser == nil else { return }
        apply(.started)

        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.apply(.browserReady)
            case .waiting(let err), .failed(let err):
                self.apply(.browserBlocked(denied: Self.isPermissionDenied(err),
                                           reason: Self.describe(err)))
            default:
                break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        browser = b
        b.start(queue: .main)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.searchDeadline)
        timer.setEventHandler { [weak self] in self?.apply(.searchDeadlineReached) }
        deadlineTimer = timer
        timer.resume()
    }

    func stop() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        txtByName.removeAll()
        services = []
        apply(.stopped)
    }

    // MARK: 内部

    private func apply(_ event: ProxyDiscoveryEvent) {
        machine.apply(event)
        state = machine.state
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var liveNames = Set<String>()
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint else { continue }
            liveNames.insert(name)
            if case .bonjour(let txt) = r.metadata {
                txtByName[name] = ProxyServiceTXT.parse(txt.dictionary)
            }
            if resolvers[name] == nil {
                resolvers[name] = ProxyHostResolver(name: name) { [weak self] host, port in
                    self?.hostResolved(name: name, host: host, port: port)
                }
            }
        }
        // 广播消失的条目立即下架（proxy 退出会撤回广播）
        for gone in Set(services.map(\.id)).subtracting(liveNames) {
            resolvers[gone]?.cancel()
            resolvers.removeValue(forKey: gone)
            txtByName.removeValue(forKey: gone)
            services.removeAll { $0.id == gone }
        }
        for gone in Set(resolvers.keys).subtracting(liveNames) {
            resolvers[gone]?.cancel()
            resolvers.removeValue(forKey: gone)
        }
        apply(.servicesChanged(services.count))
    }

    private func hostResolved(name: String, host: String, port: Int) {
        let txt = txtByName[name] ?? ProxyServiceTXT.parse([:])
        let found = DiscoveredProxy(id: name, host: host, port: port, txt: txt)
        if let idx = services.firstIndex(where: { $0.id == name }) {
            services[idx] = found
        } else {
            services.append(found)
            services.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        }
        apply(.servicesChanged(services.count))
    }

    /// 本地网络权限被拒的判定。iOS 14+ / macOS 15+ 拒绝后 NWBrowser 卡在 .waiting/.failed，
    /// 带的是 dnssd 的 PolicyDenied / NoAuth（或 POSIX EPERM/EACCES）。
    static func isPermissionDenied(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code):
            return code == kDNSServiceErr_PolicyDenied || code == kDNSServiceErr_NoAuth
        case .posix(let code):
            return code == .EPERM || code == .EACCES
        default:
            return false
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .dns(let code): return "mDNS 错误 \(code)"
        case .posix(let code): return "系统错误 \(code.rawValue)"
        case .tls(let code): return "TLS 错误 \(code)"
        default: return error.localizedDescription
        }
    }
}

// MARK: - 主机名解析
//
// NWBrowser 只给实例名，NetService 才给得到 `<mac>.local.`。

private final class ProxyHostResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let onResolved: (String, Int) -> Void
    init(name: String, onResolved: @escaping (String, Int) -> Void) {
        self.service = NetService(domain: "local.", type: "\(ProxyDiscovery.serviceType).", name: name)
        self.onResolved = onResolved
        super.init()
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func cancel() {
        service.stop()
        service.delegate = nil
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        onResolved(host, sender.port)
    }
}
