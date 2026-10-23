#if os(macOS)
import Foundation
import Observation

/// 编程会话的用户状态（plan-wake-native-n1 §2.1）：收藏 / 置顶 / 墓碑 / 续跑目标 / 导出目录。
/// 放 Application Support（索引在 Caches 会被系统清，用户状态不能跟着丢）；原子写。
@Observable
@MainActor
final class CodingSessionState {
    static let shared = CodingSessionState()

    struct Snapshot: Codable, Equatable {
        var favorites: Set<String> = []
        var pins: Set<String> = []
        var tombstonePaths: Set<String> = []
        var tombstoneKeys: Set<String> = []
        var terminal: String?
        var lastExportDir: String?
        /// 列表形态 / 排序（N1-e）；老文件没有这三项 → nil 走默认
        var listMode: String?
        var sort: String?
        var ascending: Bool?
        /// 会话位置（N3-e）：自定义根 / 被移除的整家默认 / 被单独移除的默认根 / 停用的根。全可选——非可选字段会让老文件整份解码失败重置
        var customRoots: [CodingLocationEntry]?
        var removedDefaults: [String]?
        var removedDefaultRoots: [CodingLocationEntry]?
        var disabledLocations: [CodingLocationEntry]?
        /// 远程主机（N4）：可选——老文件没有这一项照读
        var remoteHosts: [CodingRemoteHost]?
        /// 改名（09-25 plan-mac-code-mode-gaps §1）：key → 显示名。只存在我们这边，不写回 agent 自己的会话文件
        var titleOverrides: [String: String]?

        // 状态 → roster 映射下沉在这里：app 与 mp-code 读同一份（R-WN6 I2）
        var locationOverrides: CodingLocationOverrides {
            CodingLocationOverrides(customRoots: customRoots ?? [],
                                    removedDefaults: (removedDefaults ?? []).compactMap(CodingAgent.init(rawValue:)),
                                    removedDefaultRoots: removedDefaultRoots ?? [], disabled: disabledLocations ?? [])
        }

        var enabledRemoteHostNames: [String] { (remoteHosts ?? []).filter(\.enabled).map(\.name) }
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace", isDirectory: true)
            .appendingPathComponent("coding-sessions.json")
    }

    private(set) var snapshot: Snapshot
    @ObservationIgnored private let url: URL
    /// 后台线程可读的墓碑（监听增量在自己的队列上判；bury 时同步更新）
    nonisolated let tombstones: TombstoneBox

    init(url: URL = CodingSessionState.defaultURL) {
        self.url = url
        var initial = Snapshot()
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            initial = decoded
        }
        snapshot = initial
        tombstones = TombstoneBox(paths: initial.tombstonePaths, keys: initial.tombstoneKeys)
    }

    func isFavorite(_ key: String) -> Bool { snapshot.favorites.contains(key) }
    func titleOverride(_ key: String) -> String? { snapshot.titleOverrides?[key] }

    /// 空串 / nil = 清掉改名，回到会话原名
    func setTitle(_ title: String?, for key: String) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var overrides = snapshot.titleOverrides ?? [:]
        overrides[key] = trimmed.isEmpty ? nil : trimmed
        snapshot.titleOverrides = overrides.isEmpty ? nil : overrides
        save()
    }

    /// 改名后能命中筛选词的 key（列表筛选按改后的名字也搜得到）
    func keysWithTitle(matching query: String) -> Set<String> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, let overrides = snapshot.titleOverrides else { return [] }
        return Set(overrides.filter { $0.value.lowercased().contains(q) }.keys)
    }
    func isPinned(_ key: String) -> Bool { snapshot.pins.contains(key) }

    func toggleFavorite(_ key: String) {
        if snapshot.favorites.remove(key) == nil { snapshot.favorites.insert(key) }
        save()
    }

    func togglePin(_ key: String) {
        if snapshot.pins.remove(key) == nil { snapshot.pins.insert(key) }
        save()
    }

    /// 删除后防复活：路径 + key 双轨（别的副本不得复活同一逻辑会话）
    func bury(path: String, key: String) {
        snapshot.tombstonePaths.insert(path)
        snapshot.tombstoneKeys.insert(key)
        tombstones.update(paths: snapshot.tombstonePaths, keys: snapshot.tombstoneKeys)
        snapshot.favorites.remove(key)
        snapshot.pins.remove(key)
        snapshot.titleOverrides?[key] = nil
        save()
    }

    func setTerminal(_ id: String) {
        snapshot.terminal = id
        save()
    }

    func setListPrefs(mode: String, sort: String, ascending: Bool) {
        snapshot.listMode = mode
        snapshot.sort = sort
        snapshot.ascending = ascending
        save()
    }

    func setLastExportDir(_ path: String) {
        snapshot.lastExportDir = path
        save()
    }

    // MARK: - 会话位置（N3-e，Wake `custom_roots` / `removed_defaults` / `removed_default_roots` / `disabled_locations`）

    var locationOverrides: CodingLocationOverrides { snapshot.locationOverrides }

    /// 添加自定义根（幂等）
    func addCustomRoot(agent: CodingAgent, path: String) {
        insert(CodingLocationEntry(agent: agent.rawValue, path: path), into: \.customRoots)
        save()
    }

    /// 真正移除一个自定义根：它派生的根（如 Codex sessions + archived）的停用标记一并清，今后重新添加默认启用
    func removeCustomRoot(agent: CodingAgent, path: String) {
        snapshot.customRoots?.removeAll { $0.agent == agent.rawValue && $0.path == path }
        snapshot.disabledLocations?.removeAll { $0.agent == agent.rawValue && CodingLocations.pathOwns(path, $0.path) }
        save()
    }

    /// 位置开关的唯一写入口：启用 = 删停用标记，停用 = 幂等记入
    func setLocationEnabled(agent: CodingAgent, path: String, enabled: Bool) {
        let entry = CodingLocationEntry(agent: agent.rawValue, path: path)
        if enabled {
            snapshot.disabledLocations?.removeAll { $0 == entry }
        } else {
            insert(entry, into: \.disabledLocations)
        }
        save()
    }

    /// 编辑一个位置的全形态写入（一次落盘，不会半生效）：旧单元是自定义 = 删记录，可单独移除的默认根 = 只压这条根，其余默认 = 压整家
    /// 默认；新单元一律记自定义（含换家）。旧单元派生根的停用标记随旧配置清掉，免得日后重新添加同一路径时意外继承（Wake `replace_location`）
    func replaceLocation(oldAgent: CodingAgent, oldCustomPath: String?, oldDefaultRoot: String?, oldDataRoot: String,
                         newAgent: CodingAgent, newPath: String) {
        let unit = oldCustomPath ?? oldDataRoot
        snapshot.disabledLocations?.removeAll { $0.agent == oldAgent.rawValue && CodingLocations.pathOwns(unit, $0.path) }
        if let oldCustomPath {
            snapshot.customRoots?.removeAll { $0.agent == oldAgent.rawValue && $0.path == oldCustomPath }
        } else if let oldDefaultRoot {
            insert(CodingLocationEntry(agent: oldAgent.rawValue, path: oldDefaultRoot), into: \.removedDefaultRoots)
        } else if !(snapshot.removedDefaults ?? []).contains(oldAgent.rawValue) {
            snapshot.removedDefaults = (snapshot.removedDefaults ?? []) + [oldAgent.rawValue]
        }
        insert(CodingLocationEntry(agent: newAgent.rawValue, path: newPath), into: \.customRoots)
        save()
    }

    /// 恢复默认：四类偏离一起清
    func clearLocationOverrides() {
        snapshot.customRoots = nil
        snapshot.removedDefaults = nil
        snapshot.removedDefaultRoots = nil
        snapshot.disabledLocations = nil
        save()
    }

    private func insert(_ entry: CodingLocationEntry, into keyPath: WritableKeyPath<Snapshot, [CodingLocationEntry]?>) {
        var list = snapshot[keyPath: keyPath] ?? []
        if !list.contains(entry) { list.append(entry) }
        snapshot[keyPath: keyPath] = list
    }

    // MARK: - 远程主机（N4，Wake `remote_hosts` 表；索引在 Caches 会被系统清，配置跟用户状态走）

    var remoteHosts: [CodingRemoteHost] { snapshot.remoteHosts ?? [] }

    /// roster 组装与启动 / 刷新同步共用——远程实例集合与同步目标必须同源
    var enabledRemoteHostNames: [String] { snapshot.enabledRemoteHostNames }

    /// 添加：校验在这道门（名字进 key 作中段、直接当 ssh / rsync 参数，任何入口都不得绕过）；重名幂等。回 false = 名字不合法
    @discardableResult
    func addRemoteHost(_ name: String) -> Bool {
        guard CodingRemote.validHostName(name) else { return false }
        guard !remoteHosts.contains(where: { $0.name == name }) else { return true }
        snapshot.remoteHosts = remoteHosts + [CodingRemoteHost(name: name, enabled: true, addedAt: Int64(Date().timeIntervalSince1970 * 1000))]
        save()
        return true
    }

    func removeRemoteHost(_ name: String) {
        snapshot.remoteHosts = remoteHosts.filter { $0.name != name }
        save()
    }

    func setRemoteHostEnabled(_ name: String, enabled: Bool) {
        snapshot.remoteHosts = remoteHosts.map { host in
            var updated = host
            if host.name == name { updated.enabled = enabled }
            return updated
        }
        save()
    }

    /// 同步收尾：成功记时间清错误，失败只写错误（保留上次成功时间）；同步途中被移除的主机不再写回
    func recordRemoteSync(_ name: String, error: String?) {
        snapshot.remoteHosts = remoteHosts.map { host in
            guard host.name == name else { return host }
            var updated = host
            if let error {
                updated.lastSyncError = error
            } else {
                updated.lastSyncAt = Int64(Date().timeIntervalSince1970 * 1000)
                updated.lastSyncError = nil
            }
            return updated
        }
        save()
    }

    /// 给后台扫描用的墓碑判定（读锁住的盒子：之后新删的也算数）
    nonisolated var tombstoneCheck: @Sendable (String, String) -> Bool {
        let box = tombstones
        return { path, key in box.contains(path: path, key: key) }
    }

    final class TombstoneBox: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String>
        private var keys: Set<String>

        init(paths: Set<String>, keys: Set<String>) {
            self.paths = paths
            self.keys = keys
        }

        func update(paths: Set<String>, keys: Set<String>) {
            lock.lock()
            self.paths = paths
            self.keys = keys
            lock.unlock()
        }

        func contains(path: String, key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.contains(path) || keys.contains(key)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            CodingDiagnostics.log("🧭 编程会话用户状态写入失败：\(error.localizedDescription)")
        }
    }
}
#endif
