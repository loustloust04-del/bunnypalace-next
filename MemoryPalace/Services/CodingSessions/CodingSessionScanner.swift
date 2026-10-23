#if os(macOS)
import Foundation

/// 增量扫描（Wake `scanner.rs`）。同一时刻只跑一条；按 (path, mtime, size) 判变化；
/// 一个文件只归**最长数据根**的实例（自定义根可落在别家树里）；同 key 多副本按（mtime 新, 路径小）裁决、其余作解析失败回退；
/// 写入在事务内再裁一次（败方不覆盖仍在盘上的胜方）；磁盘上没了的会话从索引删；最近修改的先解析。调用方放后台线程跑（同步阻塞）。
final class CodingSessionScanner: @unchecked Sendable {
    struct Progress: Sendable, Equatable {
        var scanning: Bool
        var done: Int
        var total: Int
    }

    struct Report: Sendable, Equatable {
        var parsed = 0
        var failed = 0
        var pruned = 0
        var skipped = false
        /// 这轮父子关系有行变了（只动关系、没重解析会话时调用方也要重读列表）
        var linksChanged = false
    }

    private let index: CodingSessionIndex
    private let adapters: [CodingSessionAdapter]
    /// 全量与监听增量共用一道闸：写连接同一时刻只有一个人用（R-WN1 #5②）
    private let gate = DispatchSemaphore(value: 1)

    init(index: CodingSessionIndex, adapters: [CodingSessionAdapter]) {
        self.index = index
        self.adapters = adapters
    }

    /// 同 key 的一份副本：哪个实例（下标）枚举到的
    private typealias Candidate = (ix: Int, ref: CodingSessionFileRef)

    /// 去重域 = 实例的 session key（Wake `session_key(agent, 实例 host, native)`）：本机与远端同 id 的两份各自成行
    private static func key(_ agent: CodingAgent, _ host: String, _ nativeId: String) -> String {
        CodingSessionKey.make(agent, host: host, nativeId: nativeId)
    }

    /// 裁决顺位：mtime 新者在前、平局路径字典序小者在前（Wake `scanner.rs:245-251`）
    private static func ranked(_ group: [Candidate]) -> [Candidate] {
        group.sorted { $0.ref.mtimeMs != $1.ref.mtimeMs ? $0.ref.mtimeMs > $1.ref.mtimeMs : $0.ref.filePath < $1.ref.filePath }
    }

    /// - Parameters:
    ///   - full: 全量重解析（忽略 mtime / size）
    ///   - isTombstoned: (filePath, key) 已被用户删除 → 不复活
    ///   - progress: 进度回调（后台线程；约 0.8 s 一次 + 终态必发）
    func run(full: Bool = false,
             isTombstoned: (String, String) -> Bool = { _, _ in false },
             progress: (Progress) -> Void = { _ in }) throws -> Report {
        // 全量撞上别的全量 / 增量：跳过（调用方稍后再刷）
        guard gate.wait(timeout: .now()) == .success else { return Report(skipped: true) }
        var report = Report()
        var state = Progress(scanning: true, done: 0, total: 0)
        defer {
            gate.signal()
            state.scanning = false
            progress(state)
        }

        for adapter in adapters { adapter.beginScan() }
        let known = try index.knownFiles()
        // 第一遍：各实例枚举 → 墓碑双轨 → 最长根归属（更深的根认领了就只归那个实例）→ 按 key 聚合
        var groups: [String: [Candidate]] = [:]
        for (ix, adapter) in adapters.enumerated() {
            for ref in adapter.listSessionFiles() {
                let key = Self.key(adapter.agent, adapter.host, ref.nativeId)
                guard !isTombstoned(ref.filePath, key) else { continue }
                if let owner = CodingSessionRoster.ownerIndex(of: ref.filePath, in: adapters), owner != ix { continue }
                groups[key, default: []].append((ix, ref))
            }
        }
        let ranked = groups.values.map(Self.ranked)
        let seen = Set(ranked.map(\.[0].ref.filePath))

        func changed(_ ref: CodingSessionFileRef) -> Bool {
            guard let k = known[ref.filePath] else { return true }
            return k.mtime != ref.mtimeMs || k.size != ref.size
        }

        // 快路径（Codex state DB）：按实例批量拿 meta，先写 meta-only 行让列表立刻有东西
        var quickByPath: [String: CodingSessionMeta] = [:]
        for (ix, adapter) in adapters.enumerated() {
            let winners = ranked.map(\.[0]).filter { $0.ix == ix }.map(\.ref)
            guard !winners.isEmpty, let quick = adapter.quickMeta(winners) else { continue }
            quickByPath.merge(quick) { current, _ in current }
            let fresh = winners.compactMap { ref -> CodingSessionMeta? in
                guard let meta = quick[ref.filePath], full || changed(ref), !isTombstoned(ref.filePath, meta.key) else { return nil }
                return meta
            }
            if !fresh.isEmpty { try index.writeMetaOnly(fresh) }
        }

        let gone = known.filter { !seen.contains($0.key) }.map(\.value.key)
        if !gone.isEmpty {
            try index.removeSessions(gone)
            report.pruned = gone.count
        }

        let queue = ranked.filter { full || changed($0[0].ref) }.sorted { $0[0].ref.mtimeMs > $1[0].ref.mtimeMs }
        state.total = queue.count
        progress(state)
        var lastNotify = Date()

        for group in queue {
            if write(group, quick: quickByPath[group[0].ref.filePath], isTombstoned: isTombstoned) {
                report.parsed += 1
            } else {
                report.failed += 1
            }
            state.done += 1
            if Date().timeIntervalSince(lastNotify) > 0.8 || state.done == state.total {
                lastNotify = Date()
                progress(state)
            }
        }
        report.linksChanged = try syncParentLinks(isTombstoned: isTombstoned)
        return report
    }

    /// 监听增量（N1-d）：只解析这些引用，与全量同口径（最长根归属 / 同 key 裁决 / 回退 / 事务内守卫）；
    /// removedPaths 按路径删索引行，被删的 key 在别处还有副本就让它上位。与全量共用闸——排队等，不跳过；
    /// 入口按路径 + key 双轨卡墓碑（R-WN1 #5③），合并出的 key 再卡一次（Codex 线程 id 改名）
    func scanFiles(_ refs: [CodingSessionFileRef], removedPaths: [String] = [],
                   isTombstoned: (String, String) -> Bool = { _, _ in false }) throws -> Report {
        gate.wait()
        defer { gate.signal() }
        var report = Report()
        let removed = removedPaths.map(CodingParse.canonicalPath)
        let goneKeys = try removed.compactMap { try index.key(forPath: $0) }
        if !goneKeys.isEmpty {
            try index.removeSessions(goneKeys)
            report.pruned = goneKeys.count
        }
        let incoming = refs + survivors(for: goneKeys, excluding: Set(removed))
        let affected = Set(incoming.map(\.agent)).union(goneKeys.compactMap { CodingAgent(rawValue: String($0.prefix { $0 != ":" })) })
        for adapter in adapters where affected.contains(adapter.agent) { adapter.beginScan() }
        var groups: [String: [Candidate]] = [:]
        for ref in incoming {
            guard let ix = owner(for: ref) else { continue }
            let key = Self.key(ref.agent, adapters[ix].host, ref.nativeId)
            guard !isTombstoned(ref.filePath, key), groups[key]?.contains(where: { $0.ref.filePath == ref.filePath }) != true else { continue }
            groups[key, default: []].append((ix, ref))
        }
        for group in groups.values {
            if write(Self.ranked(group), quick: nil, isTombstoned: isTombstoned) {
                report.parsed += 1
            } else {
                report.failed += 1
            }
        }
        if adapters.contains(where: { affected.contains($0.agent) && $0.managesParentLinks }) {
            do {
                report.linksChanged = try syncParentLinks(isTombstoned: isTombstoned)
            } catch {
                CodingDiagnostics.log("🧭 编程会话父链刷新失败：\(error.localizedDescription)")
            }
        }
        return report
    }

    /// 监听收到关系边车事件、这批又没有同家的会话文件可交给 scanFiles 时用（Wake `refresh_parent_links`）。同家全部数据根一起刷，
    /// 否则跨数据根的父链会被局部快照截断。回是否有行变了
    func refreshParentLinks(_ agents: Set<CodingAgent>, isTombstoned: (String, String) -> Bool = { _, _ in false }) throws -> Bool {
        gate.wait()
        defer { gate.signal() }
        let targets = adapters.filter { agents.contains($0.agent) && $0.managesParentLinks }
        guard !targets.isEmpty else { return false }
        for adapter in targets { adapter.beginScan() }
        return try syncParentLinks(isTombstoned: isTombstoned)
    }

    // MARK: - 父子关系

    /// 多数据根下，关系元数据跟着父会话，而子会话的胜出文件可能在另一个根：先只采纳「父会话胜出文件所属实例」给的直接边（另一份陈旧
    /// 备份不能把已解除的关系挂回去），再跨实例把嵌套链扁平到根。解除 / 换父前从子会话自己的胜出文件重解析，恢复被旧父项目覆盖的
    /// 自身归属；解析不了就保留仍有效的旧关系、下次再试（Wake `sync_parent_links`）
    private func syncParentLinks(isTombstoned: (String, String) -> Bool) throws -> Bool {
        let linksByAdapter = adapters.map { adapter -> [String: String] in
            guard adapter.managesParentLinks else { return [:] }
            return Dictionary(adapter.parentLinks().map { ($0.child, $0.parent) }, uniquingKeysWith: { _, last in last })
        }
        var changed = false
        for agent in Set(adapters.filter(\.managesParentLinks).map(\.agent)) {
            var sourceByKey: [String: String] = [:]
            var ownerByKey: [String: Int] = [:]
            for (key, path) in try index.sessionSources(agent: agent) {
                guard let ix = ownerIndex(agent: agent, path: path) else { continue }
                sourceByKey[key] = path
                ownerByKey[key] = ix
            }
            var direct: [String: String] = [:]
            for (ix, links) in linksByAdapter.enumerated() where adapters[ix].agent == agent {
                for (child, parent) in links where sourceByKey[child] != nil && ownerByKey[parent] == ix {
                    direct[child] = parent
                }
            }
            var desired: [String: String] = [:]
            for child in direct.keys {
                if let root = Self.flattenedParent(child, direct) { desired[child] = root }
            }
            for (child, oldParent) in try index.parentLinks(agent: agent) where desired[child] != oldParent {
                let restored = sourceByKey[child].map { reparseForParentChange(agent: agent, key: child, filePath: $0, isTombstoned: isTombstoned) } ?? false
                if !restored && sourceByKey[oldParent] != nil { desired[child] = oldParent }
            }
            let links = desired.sorted { $0.key < $1.key }.map { (child: $0.key, parent: $0.value) }
            if try index.replaceParentLinks(agent: agent, links: links) { changed = true }
        }
        return changed
    }

    /// 沿直接边走到根；成环 = 无根
    static func flattenedParent(_ child: String, _ direct: [String: String]) -> String? {
        var current = child
        var seen: Set<String> = [child]
        while let parent = direct[current] {
            guard seen.insert(parent).inserted else { return nil }
            guard direct[parent] != nil else { return parent }
            current = parent
        }
        return nil
    }

    private func reparseForParentChange(agent: CodingAgent, key: String, filePath: String, isTombstoned: (String, String) -> Bool) -> Bool {
        guard let ix = ownerIndex(agent: agent, path: filePath) else { return false }
        let adapter = adapters[ix]
        guard let ref = adapter.fileRef(URL(fileURLWithPath: filePath)) else {
            CodingDiagnostics.log("🧭 解除父子关系时找不回会话源文件：\(filePath)")
            return false
        }
        guard let parsed = try? adapter.parseSession(ref) else { return false }
        let meta = adapter.quickMeta([ref])?[ref.filePath].map { adapter.mergeQuickMeta(parsed.meta, $0) } ?? parsed.meta
        guard meta.key == key, !isTombstoned(filePath, meta.key) else { return false }
        return (try? index.writeSession(meta, fileMtime: ref.mtimeMs, units: parsed.units, guarded: true)) ?? false
    }

    /// 这家的这个文件归哪个实例（Wake `adapter_ix_for`）：只有一个实例直接是它；多实例取最长认领根，都不认领回第一个
    private func ownerIndex(agent: CodingAgent, path: String) -> Int? {
        let same = adapters.indices.filter { adapters[$0].agent == agent }
        guard let first = same.first else { return nil }
        guard same.count > 1 else { return first }
        let file = CodingParse.canonicalPath(CodingVirtualPath.strip(path))
        var best: (length: Int, index: Int)?
        for ix in same {
            for root in adapters[ix].dataRoots {
                let base = CodingParse.canonicalPath(root.path)
                if file == base || file.hasPrefix(base + "/"), base.count > (best?.length ?? -1) { best = (base.count, ix) }
            }
        }
        return best?.index ?? first
    }

    /// 按裁决顺位解析、写入（事务内守卫）：胜者坏了回退下一份；全都解析失败回 false
    private func write(_ group: [Candidate], quick firstQuick: CodingSessionMeta?, isTombstoned: (String, String) -> Bool) -> Bool {
        for (attempt, candidate) in group.enumerated() {
            let adapter = adapters[candidate.ix]
            do {
                let parsed = try adapter.parseSession(candidate.ref)
                let quick = (attempt == 0 ? firstQuick : nil) ?? adapter.quickMeta([candidate.ref])?[candidate.ref.filePath]
                let meta = quick.map { adapter.mergeQuickMeta(parsed.meta, $0) } ?? parsed.meta
                if !isTombstoned(candidate.ref.filePath, meta.key) {
                    try index.writeSession(meta, fileMtime: candidate.ref.mtimeMs, units: parsed.units, guarded: true)
                }
                return true
            } catch {
                CodingDiagnostics.log("🧭 编程会话解析失败 \(candidate.ref.filePath)：\(error.localizedDescription)")
            }
        }
        return false
    }

    /// ref 归哪个实例：最长根认领的（得是同家）；没有根认领时回同家第一个
    private func owner(for ref: CodingSessionFileRef) -> Int? {
        if let ix = CodingSessionRoster.ownerIndex(of: ref.filePath, in: adapters) {
            return adapters[ix].agent == ref.agent ? ix : nil
        }
        // ref 没有 host：远程 ref 恒在缓存根下、走最长根，落到这里的只可能是本机的（R-WN4 #3）
        return adapters.firstIndex { $0.agent == ref.agent && $0.host.isEmpty }
    }

    /// 幸存副本上位（Wake `promote_survivors`）：被删的 key 在同家各实例里还有同 native id 的副本 → 交增量收编；
    /// key 后缀是内容 id 的家（Gemini 的 sessionId 等，文件名对不上）退而解析比对，超过 32 份交给下次全量
    private func survivors(for keys: [String], excluding removed: Set<String>) -> [CodingSessionFileRef] {
        var out: [CodingSessionFileRef] = []
        for key in Set(keys) {
            guard let colon = key.firstIndex(of: ":"), let agent = CodingAgent(rawValue: String(key[..<colon])) else { continue }
            // 按实例反查 native id（Wake watcher `strip_key_prefix`）：本机实例不认三段 key，远程实例只认自己 host 的
            var candidates: [CodingSessionFileRef] = []
            var byName: [CodingSessionFileRef] = []
            for adapter in adapters where adapter.agent == agent {
                guard let nativeId = CodingSessionKey.nativeId(of: key, agent: agent, host: adapter.host) else { continue }
                let refs = adapter.listSessionFiles().filter { !removed.contains($0.filePath) }
                candidates += refs
                byName += refs.filter { $0.nativeId == nativeId }
            }
            if !byName.isEmpty {
                out += byName
                continue
            }
            guard candidates.count <= 32 else { continue }
            for ref in candidates {
                guard let ix = owner(for: ref), (try? adapters[ix].parseSession(ref).meta.key) == key else { continue }
                out.append(ref)
                break
            }
        }
        return out
    }
}
#endif
