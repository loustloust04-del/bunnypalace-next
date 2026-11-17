import Foundation

/// 老的全局网页应用（#00802 / #00805：`WebApps/<id>/index.html` + `versions/`）搬进各层文件库（plan-webapp-as-file §2.8）。
/// 每个应用：哪几层的桌面摆着它就搬进哪几层（都没摆 → 当前层），写成 `应用/<名字>.html`，历史一版一版导进这个文件的版本历史，
/// id 不变（网页数据还在；摆在两层的共用一份数据）。全部成功 → `WebApps/` 改名留着、下次不再搬；中途失败 → 下次启动再来，
/// 已经搬过的按表里的 id / 文件内容 hash 认出来，不重复。老备份导入又带回 `WebApps/` 的，下次启动照样搬
enum WebAppMigration {
    struct LegacyApp: Decodable {
        var id: UUID
        var title: String
        var createdAt: Date
        var updatedAt: Date?
    }

    struct LegacyVersion: Decodable {
        var id: String
        var at: Date
        var by: String
        var note: String
    }

    static var legacyDirectory: URL {
        AppPaths.applicationSupport.appendingPathComponent("MemoryPalace/WebApps", isDirectory: true)
    }

    @MainActor
    static func runIfNeeded() async {
        let dir = legacyDirectory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("webapps.json").path),
              let profileId = WebAppStore.shared.profileId else { return }
        let page2Root = WebAppStore.page2Root
        let done = await Task.detached { await migrate(from: dir, currentProfileId: profileId, page2Root: page2Root, versions: .shared) }.value
        if done { retire(dir) }
        WebAppStore.shared.reload()
    }

    /// 返回 true = 全部搬完
    static func migrate(from dir: URL, currentProfileId: String, page2Root: URL, versions: FileVersionStore) async -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("webapps.json")),
              let apps = try? JSONDecoder().decode([LegacyApp].self, from: data) else { return false }
        var allDone = true
        for app in apps {
            let folder = dir.appendingPathComponent(app.id.uuidString.lowercased(), isDirectory: true)
            guard let current = try? String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8) else { continue }
            for profileId in floors(showing: WebAppStore.toolID(app.id), page2Root: page2Root, current: currentProfileId) {
                do {
                    try await move(app, current: current, folder: folder, profileId: profileId, versions: versions)
                } catch {
                    allDone = false
                }
            }
        }
        return allDone
    }

    /// 这个应用摆在哪几层：读每层的桌面摆法（`Page2HomeStore` 的层文件），有它的图标就算；
    /// 当前层还没存过自己的摆法、用的是老的默认那份，也看默认那份；都没有 → 当前层
    static func floors(showing toolID: String, page2Root: URL, current: String) -> [String] {
        func shows(_ url: URL) -> Bool {
            (try? String(contentsOf: url, encoding: .utf8))?.contains("\"\(toolID)\"") == true
        }
        let floorsDir = page2Root.appendingPathComponent("floors", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: floorsDir.path)) ?? []).sorted()
        var found = names.filter { shows(floorsDir.appendingPathComponent("\($0)/home-layout-v1.json")) }
        let currentLayout = floorsDir.appendingPathComponent("\(current)/home-layout-v1.json")
        if !found.contains(current), !FileManager.default.fileExists(atPath: currentLayout.path),
           shows(page2Root.appendingPathComponent("home-layout-v1.json")) {
            found.append(current)
        }
        return found.isEmpty ? [current] : found
    }

    private static func move(_ app: LegacyApp, current: String, folder: URL, profileId: String, versions store: FileVersionStore) async throws {
        var registered = WebAppStore.storedApps(profileId: profileId)
        guard !registered.contains(where: { $0.id == app.id }) else { return }
        let name = WebAppStore.fileName(app.title)
        let taken = Set(registered.map(\.path))
        let path = try existingCopy(name: name, content: current, profileId: profileId, taken: taken)
            ?? WebAppStore.writeNew(current, name: name, profileId: profileId).path
        // 历史：最早的一版起按顺序记，保留原来的时间和谁改的
        let key = FileVersionStore.Key.file(profileId: profileId, relativePath: path)
        let versionsDir = folder.appendingPathComponent("versions", isDirectory: true)
        let list = (try? Data(contentsOf: versionsDir.appendingPathComponent("versions.json")))
            .flatMap { try? JSONDecoder().decode([LegacyVersion].self, from: $0) } ?? []
        for version in list {
            guard let text = try? String(contentsOf: versionsDir.appendingPathComponent("\(version.id).html"), encoding: .utf8) else { continue }
            _ = try await store.record(key: key, content: text, source: .external, actor: version.by == "AI" ? "AI" : nil, date: version.at)
        }
        _ = try await store.record(key: key, content: current, source: .external, date: app.updatedAt ?? app.createdAt)
        guard let hash = FileLibraryStore.contentHash(path, profileId: profileId) else { throw WebAppStore.error("读不回 \(path)") }
        registered.append(WebApp(id: app.id, path: path, sha256: hash, createdAt: app.createdAt))
        try WebAppStore.writeStored(registered, profileId: profileId)
    }

    /// 上次搬到一半（文件写了、表没写）：`应用/` 里同名、内容一样、还没被别的应用认领的就是它
    /// （同名同内容的两个应用——测试时装了两遍——各要各的文件）
    private static func existingCopy(name: String, content: String, profileId: String, taken: Set<String>) throws -> String? {
        let hash = FileLibraryStore.sha256Hex(Data(content.utf8))
        for n in 1...200 {
            let path = "\(WebAppStore.folderName)/\(n == 1 ? name : "\(name)-\(n)").html"
            guard FileLibraryStore.exists(path, profileId: profileId) else { return nil }
            if !taken.contains(path), FileLibraryStore.contentHash(path, profileId: profileId) == hash { return path }
        }
        return nil
    }

    /// 搬完改名留着（不删，出了问题还能找回来）
    private static func retire(_ dir: URL) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let target = dir.deletingLastPathComponent().appendingPathComponent("WebApps-搬家前-\(f.string(from: Date()))", isDirectory: true)
        try? FileManager.default.moveItem(at: dir, to: target)
    }
}
