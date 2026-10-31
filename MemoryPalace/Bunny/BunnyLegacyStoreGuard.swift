import Foundation
import SQLite3

// MARK: - [Bunny patch BP-006] 换车保护：绝不用新 schema 打开旧兔的数据库
//
// 换车那天新兔会用旧兔的 Bundle ID 覆盖安装，住进同一个沙盒，unified.store 路径与旧兔完全相同。
// 若直接让 SwiftData 打开，旧版独有的表/字段可能在自动迁移中被丢弃（audit/risks.md R1）。
// 启动时（全量备份导入与建容器之前）以只读、immutable 方式看一眼表名：
//   有 ≥2 张旧版独有表、且没有任何上游独有表 → 判定为旧兔库 → 整组文件原样挪到 MemoryPalace/BunnyLegacy-<时间>/。
// 挪不动就停止启动（宁可打不开，也不冒险迁移旧库）。读不了库（如未解锁）则什么都不做。
// 旧数据的正式搬家走「转换器 → 全量备份包 → 从链接下载并导入」（BP-004）。

enum BunnyLegacyStoreGuard {
    static let legacyOnlyTables = ["ZSONG", "ZDAILYCONTEXT", "ZGROUPTURN", "ZSPEAKCLAIM",
                                   "ZWORKCARD", "ZINSPIRATIONNOTE", "ZDRAFT", "ZPROJECT"]
    static let upstreamOnlyTables = ["ZAUDIOBOOKITEM", "ZAUDIOBOOKBOOKMARK", "ZVOCABPROGRESS",
                                     "ZTICKERENTRY", "ZTRADEENTRY"]

    static func runIfNeeded() {
        let fm = FileManager.default
        let store = ProfileManager.unifiedStorePath
        guard fm.fileExists(atPath: store.path) else { return }
        guard let tables = tableNames(store) else {
            NSLog("[bunny-guard] 读不了 unified.store，跳过检查（不移动任何文件）")
            return
        }
        let legacyHits = legacyOnlyTables.filter { tables.contains($0) }
        let upstreamHits = upstreamOnlyTables.filter { tables.contains($0) }
        guard legacyHits.count >= 2, upstreamHits.isEmpty else { return }

        let dir = store.deletingLastPathComponent()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let dest = dir.appendingPathComponent("BunnyLegacy-\(fmt.string(from: Date()))", isDirectory: true)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            // 先挪主库，再挪 WAL / SHM / 外部存储：主库一旦离开，新容器就不会再碰旧数据
            for name in ["unified.store", "unified.store-wal", "unified.store-shm", ".unified_SUPPORT"] {
                let src = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) {
                    try fm.moveItem(at: src, to: dest.appendingPathComponent(name))
                }
            }
            let info: [String: Any] = [
                "movedAt": ISO8601DateFormatter().string(from: Date()),
                "reason": "detected legacy BunnyPalace store",
                "legacyTables": legacyHits,
                "note": "旧兔数据库原样保存于此；正式搬家请用转换后的全量备份包导入。",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
                try? data.write(to: dest.appendingPathComponent("bunny-guard.json"))
            }
            NSLog("[bunny-guard] 检测到旧兔数据库（\(legacyHits.joined(separator: ","))），已原样挪到 \(dest.lastPathComponent)")
        } catch {
            NSLog("[bunny-guard] 挪走旧兔数据库失败：\(error)")
            fatalError("BunnyLegacyStoreGuard: legacy store detected but could not be moved aside: \(error)")
        }
    }

    /// 只读 + immutable 打开，不创建 -shm、不动 WAL；失败返回 nil
    static func tableNames(_ url: URL) -> Set<String>? {
        var db: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
    }
}
