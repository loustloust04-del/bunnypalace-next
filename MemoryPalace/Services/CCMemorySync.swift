import Foundation

/// CC 小克的 memory → 选定楼层记忆树的 memory/cc/（plan-cc-memory-sync）。
/// 手机来拉：连上 hub / 收到 cc_memory_changed / 手动 / 每 6 小时 → 要清单 → 按哈希差分批取 → 写入；
/// 清单里没有的本地文件删掉。hub 已过滤日记，这里按同一套规则再兜一遍。
/// AI 侧仍只读：memory/ 写入一律被 fs 工具拒绝，这里是系统自己写。
enum CCMemorySync {
    static let enabledKey = "ccMemorySyncEnabled"
    static let profileKey = "ccMemorySyncProfileId"
    static let lastSyncKey = "ccMemorySyncLastAt"
    static let lastCountKey = "ccMemorySyncLastCount"
    /// 粟粟 Air 上常用的那层（D1 默认值；设备上没有这层就落到当前楼层）
    static let defaultProfileId = "774E2589-3FF0-4640-9E18-3935BDE1416F"
    static let subdir = "cc"
    static let batchSize = 20
    static let refreshInterval: TimeInterval = 6 * 3600
    static let didChange = Notification.Name("CCMemorySyncDidChange")

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// 选定的楼层；空 = 还没选过（开关打开时由设置页写入）
    static var targetProfileId: String { UserDefaults.standard.string(forKey: profileKey) ?? "" }

    private static var timer: Timer?   // 只在主线程碰（WS didOpen 回主线程后调）

    static func directory(profileId: String) -> URL {
        FileLibraryStore.memoryRoot(profileId: profileId).appendingPathComponent(subdir, isDirectory: true)
    }

    /// 文件库提示里那一行（D3）：只在开着、而且是选定楼层时出现；纯静态文本，缓存前缀稳定
    static func promptHint(profileId: String) -> String {
        guard enabled, !profileId.isEmpty, profileId == targetProfileId else { return "" }
        return " memory/cc/ 是 CC 那边的你记的笔记（从 Claude Code 同步过来，只读），需要时用 fs_search / fs_read 翻。"
    }

    // MARK: - 触发

    /// WS 每次（重）连上时调：拉一次 + 起 6 小时兜底
    static func connected() {
        timer?.invalidate()
        timer = nil
        guard enabled, !targetProfileId.isEmpty else { return }
        requestManifest()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            requestManifest()
        }
    }

    static func requestManifest() {
        guard enabled, !targetProfileId.isEmpty else { return }
        CCBridgeWebSocketClient.shared.send(["type": "cc_memory_manifest_req"]) { _ in }
    }

    /// 关开关 / 换楼层：删掉那层的 memory/cc/
    static func removeLocal(profileId: String) {
        guard !profileId.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory(profileId: profileId))
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        UserDefaults.standard.removeObject(forKey: lastCountKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: - 收帧

    static func handleManifest(_ obj: [String: Any]) {
        guard enabled, !targetProfileId.isEmpty, let remote = parseManifest(obj) else { return }
        let dir = directory(profileId: targetProfileId)
        let todo = diff(remote: remote, local: localHashes(dir: dir))
        for name in todo.delete {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        for start in stride(from: 0, to: todo.fetch.count, by: batchSize) {
            let names = Array(todo.fetch[start..<min(start + batchSize, todo.fetch.count)])
            CCBridgeWebSocketClient.shared.send(["type": "cc_memory_fetch", "names": names]) { _ in }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncKey)
        UserDefaults.standard.set(remote.count, forKey: lastCountKey)
        CacheDiagLog.shared.log("🧠 CC 记忆同步: 清单 \(remote.count) · 要取 \(todo.fetch.count) · 删 \(todo.delete.count)")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func handleFiles(_ obj: [String: Any]) {
        #if (DEBUG || PERF_BENCH) && os(iOS)
        let airSpan = AirProbeSections.enabled ? AirProbeSections.enter("CCMemorySync.handleFiles") : nil
        defer { if let airSpan { AirProbeSections.leave(airSpan) } }
        #endif
        guard enabled, !targetProfileId.isEmpty, let files = obj["files"] as? [[String: Any]] else { return }
        let dir = directory(profileId: targetProfileId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written = 0
        for f in files {
            guard let name = f["name"] as? String, let content = f["content"] as? String,
                  isSafeName(name), !isExcluded(name: name, content: content) else { continue }
            do {
                try Data(wrap(content, at: Date()).utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
                written += 1
            } catch {
                CacheDiagLog.shared.log("🧠 CC 记忆同步: ❌ 写 \(name) 失败 — \(error.localizedDescription)")
            }
        }
        if let skipped = obj["skipped"] as? [String], !skipped.isEmpty {
            CacheDiagLog.shared.log("🧠 CC 记忆同步: 超大跳过 \(skipped.joined(separator: ", "))")
        }
        if written > 0 { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    // MARK: - 纯函数层（XCTest 直测）

    struct RemoteEntry: Equatable {
        let name: String
        let sha256: String
    }

    static func parseManifest(_ obj: [String: Any]) -> [RemoteEntry]? {
        guard (obj["ok"] as? Bool) == true, let files = obj["files"] as? [[String: Any]] else { return nil }
        return files.compactMap { f in
            guard let name = f["name"] as? String, let hash = f["sha256"] as? String, isSafeName(name) else { return nil }
            return RemoteEntry(name: name, sha256: hash)
        }
    }

    /// 要取的 = 远端有、本地没有或哈希不同；要删的 = 本地有、远端没有
    static func diff(remote: [RemoteEntry], local: [String: String]) -> (fetch: [String], delete: [String]) {
        let remoteNames = Set(remote.map(\.name))
        let fetch = remote.filter { local[$0.name] != $0.sha256 }.map(\.name)
        let delete = local.keys.filter { !remoteNames.contains($0) }.sorted()
        return (fetch, delete)
    }

    static func isSafeName(_ name: String) -> Bool {
        name.hasSuffix(".md") && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") && name.count <= 200
    }

    /// 与 hub 同一套：private_ 开头 / 文件名或 frontmatter 的 name、description 提到日记
    static func isExcluded(name: String, content: String) -> Bool {
        if name.hasPrefix("private_") || mentionsDiary(name) { return true }
        let fm = frontmatter(content)
        return mentionsDiary(fm.name ?? "") || mentionsDiary(fm.description ?? "")
    }

    private static func mentionsDiary(_ s: String) -> Bool {
        s.range(of: "diary", options: .caseInsensitive) != nil || s.contains("日记")
    }

    static func frontmatter(_ text: String) -> (name: String?, description: String?) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if line.hasPrefix("name:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("description:") { description = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces) }
        }
        return (name, description)
    }

    static let headerPrefix = "<!-- 同步自 CC 的 memory（只读）"
    /// 旧版头注释措辞不同，去头时按这个公共前缀认
    static let headerMarker = "<!-- 同步自 CC"

    static func wrap(_ content: String, at date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(headerPrefix)，\(f.string(from: date)) -->\n" + content
    }

    /// 去掉头注释，还原成 hub 发来的原文（哈希比对用同一口径）
    static func unwrap(_ fileText: String) -> String {
        guard fileText.hasPrefix(headerMarker), let nl = fileText.firstIndex(of: "\n") else { return fileText }
        return String(fileText[fileText.index(after: nl)...])
    }

    /// 本地已有：文件名 → 去头注释后内容的 sha256
    static func localHashes(dir: URL) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [String: String] = [:]
        for name in names where isSafeName(name) {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            out[name] = FileLibraryStore.sha256Hex(Data(unwrap(text).utf8))
        }
        return out
    }
}
