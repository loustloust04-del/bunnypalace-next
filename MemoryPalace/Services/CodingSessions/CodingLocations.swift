#if os(macOS)
import Foundation

/// 位置配置里的一条（家 + 路径），存在用户状态 JSON 里
struct CodingLocationEntry: Codable, Hashable, Sendable {
    var agent: String
    var path: String
}

/// 用户对默认位置的四类偏离（Wake `custom_roots` / `removed_defaults` / `removed_default_roots` / `disabled_locations`）
struct CodingLocationOverrides: Equatable, Sendable {
    var customRoots: [CodingLocationEntry] = []
    var removedDefaults: [CodingAgent] = []
    var removedDefaultRoots: [CodingLocationEntry] = []
    var disabled: [CodingLocationEntry] = []
}

/// 一条真实数据根（位置 sheet 的一行）：停用的也列着；扫描与监听只吃 active 那份（Wake `AdapterLocation`）
struct CodingLocation: Equatable, Sendable {
    var agent: CodingAgent
    var path: String
    var enabled: Bool
    var individuallyRemovable: Bool
}

/// roster 代号（换代时 +1）：后台队列上读，锁住
final class CodingEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance() {
        lock.lock()
        current += 1
        lock.unlock()
    }
}

enum CodingLocations {
    /// 数据根是否拥有这个会话路径：边界落在分隔符或 `#`（SQLite 虚拟路径）上，`…/sessions-old` 不归 `…/sessions`；空根不拥有任何东西；
    /// 以分隔符收尾的根（`/`）拥有一切后代（Wake `path_owns`）
    static func pathOwns(_ root: String, _ path: String) -> Bool {
        guard !root.isEmpty else { return false }
        if root.hasSuffix("/") { return path.hasPrefix(root) }
        guard path.hasPrefix(root) else { return false }
        let rest = path.dropFirst(root.count)
        return rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("#")
    }

    /// `~` / `~/…` 展开成家目录（Wake `expand_tilde`）
    static func expandTilde(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard path.hasPrefix("~") else { return path }
        let rest = path.dropFirst()
        return rest.isEmpty || rest.hasPrefix("/") ? home + rest : path
    }

    /// 家目录前缀折成 `~`；边界落在分隔符上，同名前缀的兄弟目录不折（Wake `tilde_path`）
    static func tildePath(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard path.hasPrefix(home) else { return path }
        let rest = path.dropFirst(home.count)
        return rest.isEmpty || rest.hasPrefix("/") ? "~" + rest : path
    }

    /// 入库前的自定义根整形：按家静态分派、不依赖 roster——该家默认实例被移除时也要生效（Wake `normalize_custom_root`）
    static func normalizeCustomRoot(_ agent: CodingAgent, _ dir: URL) -> URL {
        agent == .codex ? CodexAdapter.normalizeCustomRoot(dir) : dir
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }
}

extension CodingSessionRoster {
    struct Configured {
        var active: [CodingSessionAdapter]
        var locations: [CodingLocation]
    }

    /// 按位置配置构造 roster（Wake `create_adapter_roster_for`）：默认实例先压掉被移除的家 / 被单独移除的默认根，再追加自定义实例
    /// （用默认模板造，侧档相对自定义目录）；停用的根留在位置清单里、从 active 剔出——多根实例裁剪，裁不了就整实例停用，绝不能
    /// 继续扫她明确关掉的路径
    static func configured(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           overrides: CodingLocationOverrides,
                           remoteHosts: [String] = [], cacheRoot: URL? = nil) -> Configured {
        let base = adapters(home: home, environment: environment)
        let customs = overrides.customRoots.compactMap { entry -> CodingSessionAdapter? in
            guard let agent = CodingAgent(rawValue: entry.agent), let template = base.first(where: { $0.agent == agent }) else { return nil }
            return template.withCustomRoot(URL(fileURLWithPath: entry.path))
        }
        var configured: [CodingSessionAdapter] = []
        for adapter in base where !overrides.removedDefaults.contains(adapter.agent) {
            let excluded = overrides.removedDefaultRoots.filter { $0.agent == adapter.agent.rawValue }.map { URL(fileURLWithPath: $0.path) }
            if excluded.isEmpty {
                configured.append(adapter)
            } else if let filtered = adapter.excludingDataRoots(excluded) {
                if !filtered.dataRoots.isEmpty { configured.append(filtered) }
            } else {
                configured.append(adapter)
            }
        }
        configured += customs
        let disabled = Set(overrides.disabled)
        var active: [CodingSessionAdapter] = []
        var locations: [CodingLocation] = []
        for adapter in configured {
            let roots = adapter.dataRoots
            let off = roots.filter { disabled.contains(CodingLocationEntry(agent: adapter.agent.rawValue, path: $0.path)) }
            locations += roots.map {
                CodingLocation(agent: adapter.agent, path: $0.path, enabled: !off.contains($0),
                               individuallyRemovable: adapter.supportsIndividualRootRemoval)
            }
            if off.isEmpty {
                active.append(adapter)
            } else if off.count < roots.count, let filtered = adapter.excludingDataRoots(off), !filtered.dataRoots.isEmpty {
                active.append(filtered)
            }
        }
        // 启用的远程主机以装饰器实例追加在 active 尾部（N4，Wake `create_adapter_roster_for`）：模板用未经位置覆盖的原始实例，
        // 数据根全部派生自缓存目录；不进位置清单（远程在「远程主机」页管）
        if let cacheRoot {
            for host in remoteHosts { active += CodingRemote.adapters(templates: base, host: host, cacheRoot: cacheRoot) }
        }
        return Configured(active: active, locations: locations)
    }
}
#endif
