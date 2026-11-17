import Foundation
import Observation

/// 网页应用（docs/plan-webapp-as-file.md）：每个应用 = 某一层文件库里的一个 html，桌面图标 `webapp.<id>` 指过去；应用名 = 文件名。
/// 每层一张表 `Page2/floors/<楼层 id>/webapps.json`（id → 库内路径 + 最后看到的内容 hash），跟桌面摆法放一起、随层走。
/// 历史就是这个文件的版本历史（`FileVersionStore`）。写 / 改名 / 删跟着文件库的通知走；在「文件」App 里改名的，打开时按 hash 找回。
/// 在应用表里是 `webapp.<id>`（`RightPanelToolManager.recomputeTools` 并进去），桌面 / 文件夹 / Dock / 竖条都当普通应用
struct WebApp: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
    var sha256: String
    var createdAt: Date

    var title: String { WebAppStore.title(ofPath: path) }
    var toolID: String { WebAppStore.toolID(id) }
}

extension Notification.Name {
    static let webAppsDidChange = Notification.Name("webAppsDidChange")
    /// object: WebApp。文件没了（删了 / 找不回）→ 桌面图标、图标自定义、网页数据跟着清（iOS `WebAppInstaller` 收）
    static let webAppDidVanish = Notification.Name("webAppDidVanish")
}

@MainActor
@Observable
final class WebAppStore {
    static let shared = WebAppStore()

    nonisolated static let toolPrefix = "webapp."
    /// 新建的应用落在这一层文件库的这个文件夹，之后随便挪
    nonisolated static let folderName = "应用"
    nonisolated(unsafe) static var page2Root = AppPaths.applicationSupport.appendingPathComponent("MemoryPalace/Page2", isDirectory: true)

    private(set) var profileId: String?
    private(set) var apps: [WebApp] = []
    /// 文件内容变过几次：开着的应用看到变了就重载
    private(set) var revisions: [UUID: Int] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .fileLibraryFileWritten, object: nil, queue: .main) { [weak self] note in
                guard let pid = note.userInfo?["profileId"] as? String, let path = note.userInfo?["path"] as? String else { return }
                MainActor.assumeIsolated { self?.fileWritten(profileId: pid, path: path) }
            },
            center.addObserver(forName: .fileLibraryFileRenamed, object: nil, queue: .main) { [weak self] note in
                guard let pid = note.userInfo?["profileId"] as? String, let from = note.userInfo?["from"] as? String,
                      let to = note.userInfo?["to"] as? String else { return }
                MainActor.assumeIsolated { self?.fileRenamed(profileId: pid, from: from, to: to) }
            },
            center.addObserver(forName: .fileLibraryFileRemoved, object: nil, queue: .main) { [weak self] note in
                guard let pid = note.userInfo?["profileId"] as? String, let path = note.userInfo?["path"] as? String else { return }
                MainActor.assumeIsolated { self?.fileRemoved(profileId: pid, path: path) }
            },
        ]
    }

    nonisolated static func toolID(_ id: UUID) -> String { toolPrefix + id.uuidString.lowercased() }

    nonisolated static func appID(fromToolID toolID: String) -> UUID? {
        guard toolID.hasPrefix(toolPrefix) else { return nil }
        return UUID(uuidString: String(toolID.dropFirst(toolPrefix.count)))
    }

    nonisolated static func title(ofPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    nonisolated static func isHTML(_ path: String) -> Bool {
        ["html", "htm"].contains((path as NSString).pathExtension.lowercased())
    }

    nonisolated static func indexURL(profileId: String) -> URL {
        page2Root.appendingPathComponent("floors/\(profileId)/webapps.json")
    }

    /// 不经实例读盘：应用表重算时用（`RightPanelToolManager` 不在主线程隔离里）
    nonisolated static func storedApps(profileId: String) -> [WebApp] {
        guard let data = try? Data(contentsOf: indexURL(profileId: profileId)) else { return [] }
        return (try? JSONDecoder().decode([WebApp].self, from: data)) ?? []
    }

    /// 搬家时摆在两层的同一个应用共用 id（和网页数据）：删一层的时候看别的层还在不在
    nonisolated static func isRegisteredOnAnyFloor(_ id: UUID) -> Bool {
        let floors = page2Root.appendingPathComponent("floors", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: floors.path)) ?? []
        return names.contains { storedApps(profileId: $0).contains { $0.id == id } }
    }

    /// 切层（`ProfileManager.mirrorCurrent`）
    func activate(profileId: String) {
        guard profileId != self.profileId else { return }
        self.profileId = profileId
        apps = Self.storedApps(profileId: profileId)
        revisions = [:]
        NotificationCenter.default.post(name: .webAppsDidChange, object: nil)
    }

    /// 备份恢复 / 搬家后重读
    func reload() {
        guard let profileId else { return }
        apps = Self.storedApps(profileId: profileId)
        NotificationCenter.default.post(name: .webAppsDidChange, object: nil)
    }

    func app(_ id: UUID) -> WebApp? { apps.first { $0.id == id } }

    func app(path: String) -> WebApp? { apps.first { $0.path == path } }

    // MARK: 放进来

    /// 新建：写进这一层 `应用/<名字>.html`（重名加 -2、-3…），登记
    @discardableResult
    func create(html: String, title: String, id: UUID = UUID(), profileId: String) async throws -> WebApp {
        let name = Self.fileName(title)
        let document = WebAppHTML.document(html, title: name)
        let (path, hash) = try await Task.detached { try Self.writeNew(document, name: name, profileId: profileId) }.value
        return try register(WebApp(id: id, path: path, sha256: hash, createdAt: Date()), profileId: profileId)
    }

    /// 文件库里已有的 html：不拷，直接指过去（同一个文件登记过就还是那个）
    @discardableResult
    func add(path: String, id: UUID = UUID(), profileId: String) async throws -> WebApp {
        if let existing = Self.storedApps(profileId: profileId).first(where: { $0.path == path }) { return existing }
        guard Self.isHTML(path) else { throw Self.error("只有 html 文件能放到桌面") }
        let hash = await Task.detached { FileLibraryStore.contentHash(path, profileId: profileId) }.value
        guard let hash else { throw Self.error("读不到 \(path)") }
        return try register(WebApp(id: id, path: path, sha256: hash, createdAt: Date()), profileId: profileId)
    }

    // MARK: 打开

    /// 找文件：表里的路径在就用；不在了 → 在这层文件库里按内容 hash 找（「文件」App 里改名的）；都没有 → 当删了
    func fileURL(_ id: UUID) async -> URL? {
        guard let profileId, let app = app(id) else { return nil }
        guard let found = await Task.detached(operation: { Self.locate(app, profileId: profileId) }).value else {
            vanish(app, profileId: profileId)
            return nil
        }
        if found.path != app.path { update(app.id, profileId: profileId) { $0.path = found.path } }
        return found.url
    }

    nonisolated static func locate(_ app: WebApp, profileId: String) -> (path: String, url: URL)? {
        if let url = FileLibraryStore.resolve(app.path, profileId: profileId), exists(url) { return (app.path, url) }
        for meta in FileLibraryStore.list(profileId: profileId) where isHTML(meta.path) {
            guard FileLibraryStore.contentHash(meta.path, profileId: profileId) == app.sha256,
                  !storedApps(profileId: profileId).contains(where: { $0.path == meta.path && $0.id != app.id }),
                  let url = FileLibraryStore.resolve(meta.path, profileId: profileId) else { continue }
            return (meta.path, url)
        }
        return nil
    }

    /// iCloud 收起没下载的文件只剩 `.<名字>.icloud` 占位：也算在，读的时候再触发下载
    nonisolated static func exists(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    // MARK: 删

    /// 删应用 = 删文件（文件库的删除通知再走 `vanish` 清桌面和数据）
    func remove(_ id: UUID) async throws {
        guard let profileId, let app = app(id) else { return }
        do {
            try await Task.detached { try FileLibraryStore.delete(app.path, profileId: profileId) }.value
        } catch {
            // 文件早就不在了：直接清
            guard await Task.detached(operation: { Self.locate(app, profileId: profileId) }).value == nil else { throw error }
        }
        vanish(app, profileId: profileId)
    }

    // MARK: 文件库通知

    func fileWritten(profileId: String, path: String) {
        guard let app = Self.storedApps(profileId: profileId).first(where: { $0.path == path }) else { return }
        Task {
            guard let hash = await Task.detached(operation: { FileLibraryStore.contentHash(path, profileId: profileId) }).value,
                  hash != app.sha256 else { return }
            update(app.id, profileId: profileId) { $0.sha256 = hash }
            if profileId == self.profileId { revisions[app.id, default: 0] += 1 }
        }
    }

    func fileRenamed(profileId: String, from: String, to: String) {
        guard let app = Self.storedApps(profileId: profileId).first(where: { $0.path == from }) else { return syncFromDisk(profileId) }
        // 改成别的扩展名就不是网页了
        guard Self.isHTML(to) else { return vanish(app, profileId: profileId) }
        update(app.id, profileId: profileId) { $0.path = to }
    }

    func fileRemoved(profileId: String, path: String) {
        guard let app = Self.storedApps(profileId: profileId).first(where: { $0.path == path }) else { return syncFromDisk(profileId) }
        vanish(app, profileId: profileId)
    }

    /// 表在盘上是真相：别的实例（测试里宿主的 shared）先改了盘，这里只跟上
    private func syncFromDisk(_ profileId: String) {
        guard profileId == self.profileId else { return }
        let disk = Self.storedApps(profileId: profileId)
        guard disk != apps else { return }
        apps = disk
        NotificationCenter.default.post(name: .webAppsDidChange, object: nil)
    }

    // MARK: 表

    private func register(_ app: WebApp, profileId: String) throws -> WebApp {
        var next = Self.storedApps(profileId: profileId)
        next.append(app)
        try save(next, profileId: profileId)
        return app
    }

    private func update(_ id: UUID, profileId: String, _ change: (inout WebApp) -> Void) {
        var next = Self.storedApps(profileId: profileId)
        guard let i = next.firstIndex(where: { $0.id == id }) else { return syncFromDisk(profileId) }
        change(&next[i])
        try? save(next, profileId: profileId)
    }

    /// 删文件时这里会被调两次（自己删完 + 文件库的删除通知），只认第一次
    private func vanish(_ app: WebApp, profileId: String) {
        let stored = Self.storedApps(profileId: profileId)
        guard stored.contains(where: { $0.id == app.id }) else { return syncFromDisk(profileId) }
        try? save(stored.filter { $0.id != app.id }, profileId: profileId)
        revisions[app.id] = nil
        NotificationCenter.default.post(name: .webAppDidVanish, object: app, userInfo: ["profileId": profileId])
    }

    nonisolated static func writeStored(_ apps: [WebApp], profileId: String) throws {
        let url = indexURL(profileId: profileId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(apps).write(to: url, options: .atomic)
    }

    private func save(_ next: [WebApp], profileId: String) throws {
        try Self.writeStored(next, profileId: profileId)
        guard profileId == self.profileId else { return }
        apps = next
        NotificationCenter.default.post(name: .webAppsDidChange, object: nil)
    }

    // MARK: 写新文件

    /// 名字里不能当文件名的字替掉；空了用默认名
    nonisolated static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? WebAppHTML.fallbackTitle : String(cleaned.prefix(60))
    }

    nonisolated static func writeNew(_ document: String, name: String, profileId: String) throws -> (path: String, sha256: String) {
        for n in 1...200 {
            let path = "\(folderName)/\(n == 1 ? name : "\(name)-\(n)").html"
            guard try FileLibraryStore.createIfAbsent(path, content: document, profileId: profileId) else { continue }
            guard let hash = FileLibraryStore.contentHash(path, profileId: profileId) else { throw error("写进去了但读不回来：\(path)") }
            return (path, hash)
        }
        throw error("「\(folderName)」里同名的太多了")
    }

    nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "WebApps", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// 从 html 里读名字和图标地址（不跑网页，正则够用：只认常见写法）
enum WebAppHTML {
    static let fallbackTitle = "网页应用"

    /// 聊天卡片常是半截 html（没有 <html> / <head>）：包成完整文档，带上手机视口，不然整页按 980 宽缩小
    static func document(_ html: String, title: String) -> String {
        let head = html.prefix(2048).lowercased()
        if head.contains("<html") || head.contains("<!doctype") { return html }
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped)</title></head><body>
        \(html)
        </body></html>
        """
    }

    static func title(in html: String) -> String? {
        for pattern in ["<title[^>]*>([\\s\\S]*?)</title>", "<h1[^>]*>([\\s\\S]*?)</h1>"] {
            guard let raw = firstCapture(pattern, in: html) else { continue }
            let text = decodeEntities(raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(24)) }
        }
        return nil
    }

    /// `apple-touch-icon` 优先，其次 `icon` / `shortcut icon`
    static func iconHref(in html: String) -> String? {
        let links = matches("<link\\b[^>]*>", in: html)
        func href(where rel: (String) -> Bool) -> String? {
            for tag in links {
                guard let r = attribute("rel", in: tag)?.lowercased(), rel(r),
                      let h = attribute("href", in: tag), !h.isEmpty else { continue }
                return decodeEntities(h)
            }
            return nil
        }
        return href { $0.contains("apple-touch-icon") }
            ?? href { $0.split(separator: " ").contains("icon") }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstCapture("\\b\(name)\\s*=\\s*\"([^\"]*)\"", in: tag)
            ?? firstCapture("\\b\(name)\\s*=\\s*'([^']*)'", in: tag)
            ?? firstCapture("\\b\(name)\\s*=\\s*([^\\s>\"']+)", in: tag)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
