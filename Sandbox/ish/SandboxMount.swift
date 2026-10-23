import Foundation
import SQLite3

/// 文件库 → guest 的 bind mount（plan-离线沙箱-phase2 §1.5，T3a）。
///
/// 每个楼层独立挂在 `/mnt/library/<slug>`，宿主源**只**是该楼层的 `filesystem/`
/// 目录——`.memorypalace/`（记忆树、summary 等）天然在外，不需要额外过滤（R14）。
///
/// 两条必须记住的性质（08-25 探针实证，probe-report 步骤 6C）：
///   1. **bind 会持久化进 rootfs**：`fakefs_bind_mount` 在 `data/` 里建 symlink、
///      在 meta.db 里写条目，两样都随 rootfs 落盘。下次启动即使宿主侧一次都没注册，
///      那条路径**照样能读能写**（只是 readdir 空）。
///   2. 所以只读状态也持久化，且**能被同 rootfs 里的旧读写 bind 绕过**。
/// 结论：宿主侧必须把 bind 表当成 rootfs 里的持久状态管——**每次 boot 先清残留**，
/// 再按本次策略重新注册。这就是 `cleanResidue` 存在的唯一理由（R16）。
enum SandboxMount {

    /// guest 里的固定挂载根。约定为空：只放各楼层的挂载点，宿主侧不许往里放真东西（R2）。
    static let libraryRoot = "/mnt/library"

    /// `FAKEFS_MAX_BIND_MOUNTS`（ish 侧的硬上限）。楼层通常个位数，这里只做防御。
    static let maxMounts = 32

    private static let lock = NSLock()
    /// 本进程已挂过的楼层 → guest 路径。已挂的不重复挂。
    private static var mounted: [String: String] = [:]

    // MARK: - slug

    /// 楼层 → guest 挂载点名字。要求：**稳定**（跨启动不变）、**纯 ASCII**、不带 minis 字样。
    ///
    /// 不能用 `FileLibraryStore.floorSlug`——那个可能是中文（`楼层-xxxx`）而且用户能改名；
    /// guest 路径要进 shell 命令行和 `cd`，必须自己派生一个安全的。
    static func slug(for profileId: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(profileId.filter { allowed.contains($0) })
        // 有被清掉的字符 / 清空了 / 太长 → 用确定性哈希兜底
        if cleaned.isEmpty || cleaned.count != profileId.count || cleaned.count > 40 {
            return "floor-" + fnv1a(profileId)
        }
        return cleaned
    }

    /// FNV-1a 32 位。**不能用 Swift 的 `hashValue`**——它每进程加盐，重启就变，
    /// 挂载点名字跟着变会导致上一次的挂载变成清不掉的残留。
    private static func fnv1a(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in Array(s.utf8) {
            h ^= UInt32(b)
            h = h &* 16_777_619
        }
        return String(format: "%08x", h)
    }

    static func guestPath(for profileId: String) -> String {
        "\(libraryRoot)/\(slug(for: profileId))"
    }

    // MARK: - 清残留（R16，boot 后、任何挂载前跑一次）

    /// 枚举 `data/mnt/library/*` 的残留 symlink 与 meta.db 里 `/mnt/library/` 前缀的行，全删。
    /// 只在 boot 之后调一次；调用方保证此时还没有任何本次的挂载。
    @discardableResult
    static func cleanResidue(rootfsPath: URL) -> (symlinks: Int, metaRows: Int) {
        lock.lock(); mounted.removeAll(); lock.unlock()

        var removedLinks = 0
        let fm = FileManager.default
        let hostDir = rootfsPath.appendingPathComponent("data/mnt/library", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(atPath: hostDir.path) {
            for name in entries {
                let p = hostDir.appendingPathComponent(name)
                // 只删 symlink（bind 建的就是相对 symlink）。真目录/真文件不碰——
                // 那说明有人往约定为空的挂载根里放了东西，宁可留着让 mount 拒挂并报错。
                let attrs = try? fm.attributesOfItem(atPath: p.path)
                guard (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink else {
                    print("[SandboxMount] ⚠️ \(libraryRoot)/\(name) 不是 symlink，保留不动（挂载根本该为空）")
                    continue
                }
                do { try fm.removeItem(at: p); removedLinks += 1 } catch {
                    print("[SandboxMount] 删残留 symlink 失败 \(name)：\(error)")
                }
            }
        }

        let rows = deleteMetaRows(metaDB: rootfsPath.appendingPathComponent("meta.db"))
        if removedLinks > 0 || rows > 0 {
            print("[SandboxMount] 清残留：symlink \(removedLinks) 个 / meta.db \(rows) 行")
        }
        return (removedLinks, rows)
    }

    /// 删 meta.db 里 `/mnt/library/` 前缀的 paths 行（连同它们的 stats 行）。
    /// `paths.path` 是 BLOB，用 `GLOB` 前缀匹配；stats 靠 inode 关联删。
    private static func deleteMetaRows(metaDB: URL) -> Int {
        guard let db = openMeta(metaDB) else { return 0 }
        defer { sqlite3_close(db) }

        // 注意只删 `/mnt/library/` **下面的**，不删 `/mnt/library` 自己
        // （那是 rootfs 自带的固定挂载根，删了下次 bind 会找不到父目录）
        let prefix = libraryRoot + "/"
        var count = 0

        if !exec(db, "DELETE FROM stats WHERE inode IN (SELECT inode FROM paths WHERE path GLOB ?)", bind: prefix + "*") {
            return 0
        }
        if !exec(db, "DELETE FROM paths WHERE path GLOB ?", bind: prefix + "*") {
            return 0
        }
        count = Int(sqlite3_changes(db))
        return count
    }

    // MARK: - 挂载

    enum MountResult {
        case mounted(guestPath: String)
        /// iCloud 楼层不挂（R4）：cwd 回落 /root，工具结果里要说明
        case skippedICloud
        /// E5：`filesystem/` 里有指向库根之外的真 symlink → 拒挂，列出违规相对路径。
        /// **不自动删/改用户文件**，让用户自己去 Files.app 处理。
        case refusedSymlinkEscape(paths: [String])
        case failed(String)
    }

    /// 扫 `filesystem/` 树里所有 symlink，返回其解析后落在库根之外的那些（相对路径）。
    ///
    /// 为什么必须扫：T3b E5 实证——宿主侧放在 `filesystem/` 里的**真** symlink，
    /// guest 能顺着它读到挂载子树之外（`ls peek/` 是空的，但 `cat peek/secret.md`
    /// 读出了 `.memorypalace/` 的内容；readdir 不跟随而 path lookup 跟随）。
    /// guest 自己造不出这种 symlink，所以来源只可能是宿主侧（用户在 Files.app 放的、
    /// 同步工具建的）。修在宿主侧比让 fakefs 不跟随更彻底。
    static func escapingSymlinks(in root: URL) -> [String] {
        let fm = FileManager.default
        let realRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                     options: []) else { return [] }
        var bad: [String] = []
        for case let url as URL in en {
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            guard isLink else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            // 指向根内的 symlink 放行（库内互链是正常用法）
            if resolved.path == realRoot.path || resolved.path.hasPrefix(realRoot.path + "/") { continue }
            let rel = url.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            bad.append(rel.isEmpty ? url.lastPathComponent : rel)
        }
        return bad.sorted()
    }

    /// 楼层上一次没挂上的原因（设置页状态句用，T38）。挂上了就清掉
    private static var lastProblem: [String: String] = [:]

    static func problem(profileId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return lastProblem[profileId]
    }

    /// 按楼层挂载文件库。幂等：已挂过的直接返回。**必须在 boot 之后调。**
    static func mount(profileId: String) -> MountResult {
        let result = performMount(profileId: profileId)
        let problem: String?
        switch result {
        case .mounted, .skippedICloud: problem = nil
        case .refusedSymlinkEscape(let paths): problem = "文件库里有 \(paths.count) 个指向库外的链接，为安全起见没接进来"
        case .failed(let message): problem = message
        }
        lock.lock(); lastProblem[profileId] = problem; lock.unlock()
        return result
    }

    private static func performMount(profileId: String) -> MountResult {
        // R4：iCloud 楼层暂不挂（宿主源在 ubiquity 容器里，bind 进去的行为没验过）
        if FileLibraryStore.iCloudEnabled, FileLibraryStore.iCloudFloorsRoot() != nil {
            return .skippedICloud
        }

        let guestPath = guestPath(for: profileId)

        lock.lock()
        if let existing = mounted[profileId] {
            lock.unlock()
            return .mounted(guestPath: existing)
        }
        guard mounted.count < maxMounts else {
            lock.unlock()
            return .failed("沙箱挂载点已满（上限 \(maxMounts) 个楼层）")
        }
        lock.unlock()

        // 宿主源**只能**是这个函数的返回值，不给参数化：挂错目录 = 把
        // .memorypalace/（记忆树）也暴露进 guest。
        let hostRoot = FileLibraryStore.libraryRoot(profileId: profileId)
        assert(hostRoot.path == FileLibraryStore.filesystemRoot(profileId: profileId).path,
               "挂载源必须是 FileLibraryStore.filesystemRoot 的返回值")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return .failed("楼层文件库目录不存在：\(hostRoot.path)")
        }

        // E5：bind 前扫一遍库树，有越界 symlink 就拒挂（不动用户文件，只报路径）
        let escapes = escapingSymlinks(in: hostRoot)
        guard escapes.isEmpty else {
            print("[SandboxMount] 拒挂 \(guestPath)：\(escapes.count) 个越界 symlink")
            return .refusedSymlinkEscape(paths: escapes)
        }

        // bind 前 lstat 落点：非空真实目录拒绝挂，不让 C 层静默 rm -rf（R2）
        guard let rootfs = RootfsManager.shared.rootfsPathIfInstalled else {
            return .failed("rootfs 未安装")
        }
        let landing = rootfs.appendingPathComponent("data/mnt/library/\(slug(for: profileId))")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: landing.path) {
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                try? FileManager.default.removeItem(at: landing)   // 本次要重挂，旧链接先摘
            } else if type == .typeDirectory {
                let empty = ((try? FileManager.default.contentsOfDirectory(atPath: landing.path))?.isEmpty ?? true)
                guard empty else {
                    return .failed("挂载点 \(guestPath) 是非空真实目录，拒绝挂载（约定这里必须为空）")
                }
                try? FileManager.default.removeItem(at: landing)
            } else {
                return .failed("挂载点 \(guestPath) 被一个真实文件占着，拒绝挂载")
            }
        }

        // 读写挂（粟粟拍的就是读写；read_only 那条路有「被同 rootfs 旧读写 bind 绕过」的洞）
        let err = ISHKernel.shared.bindMountPath(guestPath, toHostPath: hostRoot.path)
        guard err == 0 else {
            return .failed("bind mount 失败（\(err)）：\(guestPath) → \(hostRoot.path)")
        }

        lock.lock(); mounted[profileId] = guestPath; lock.unlock()
        print("[SandboxMount] 已挂 \(guestPath) → \(hostRoot.path)")

        // R12 预热已删。T3c ⑦ 在 2000 文件规模重测：冷中位 411ms vs 热中位 466ms，
        // 两组分布几乎完全重叠（冷 366-476 / 热 371-467）——**没有可测收益**，
        // 200 文件那次也一样。fakefs 的 host-probe 补 inode 路径（fs/fake.c:1019-1068）
        // 本身就足够便宜，摊不出成本。留着只会是一段没人知道为什么存在的代码。
        // 原始数字见 t3c-report。change consumer 保留（那个是有用的）。
        return .mounted(guestPath: guestPath)
    }

    /// 探针/测试用：本进程当前挂了哪些
    static var currentMounts: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return mounted
    }

    // MARK: - SQLite 小工具（R8：busy_timeout + 检返回值）

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func openMeta(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let db else {
            print("[SandboxMount] 打不开 meta.db（\(rc)）：\(url.path)")
            if db != nil { sqlite3_close(db) }
            return nil
        }
        // guest 线程可能同时在写 meta.db；不设超时会直接 SQLITE_BUSY 失败（R8）
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    /// 返回 true = 成功。**每一步都检返回值**，失败打日志（R8 点名：以前是 fire-and-forget）。
    @discardableResult
    private static func exec(_ db: OpaquePointer, _ sql: String, bind text: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            print("[SandboxMount] prepare 失败：\(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        // path 是 BLOB，必须按 blob 绑，按 text 绑匹配不上
        let bytes = Array(text.utf8)
        guard sqlite3_bind_blob(stmt, 1, bytes, Int32(bytes.count), transient) == SQLITE_OK else {
            print("[SandboxMount] bind 失败：\(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            print("[SandboxMount] step 失败（\(rc)）：\(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }
}
