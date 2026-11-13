import SwiftUI
import WebKit

/// 浏览器身份（docs/plan-garden-browser-identities.md §3）：一个身份 = 一份独立的网站数据仓（cookie / 存储各一份），
/// 同一个站可以在不同身份里登不同的号。「主号」就是原来的 `.default()`：已登的号、链接直读、AI 读网页都照旧用它。
struct BrowserIdentity: Codable, Identifiable, Equatable, Hashable {
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let main = BrowserIdentity(id: mainID, name: "主号", colorHex: "#5E9E76", desktopUA: false)

    var id: UUID
    var name: String
    var colorHex: String
    /// 用桌面版网页（Mac Safari 的 UA）
    var desktopUA: Bool

    var isMain: Bool { id == Self.mainID }

    var color: Color { Color(hex: UInt(colorHex.dropFirst(), radix: 16) ?? 0x5E9E76) }

    var userAgent: String { desktopUA ? WebUserAgent.macDesktop : WebUserAgent.platformDefault }

    @MainActor
    var dataStore: WKWebsiteDataStore { isMain ? .default() : WKWebsiteDataStore(forIdentifier: id) }
}

enum BrowserIdentityStore {
    /// 新身份依次取色（主号固定薄荷绿）
    static let palette = ["#C0703F", "#7C68A8", "#C9466E", "#4F8C8C", "#8C7F74", "#5E9E76"]
    static let currentKey = "browser.identity.current"

    static var directory: URL = AppPaths.checked(AppPaths.applicationSupport
        .appendingPathComponent("MemoryPalace", isDirectory: true))

    private static var fileURL: URL { directory.appendingPathComponent("browser-identities.json") }

    /// 主号永远在第一个；文件里只存另外建的
    static func load() -> [BrowserIdentity] {
        let saved = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([BrowserIdentity].self, from: $0) } ?? []
        return [.main] + saved.filter { !$0.isMain }
    }

    static func save(_ identities: [BrowserIdentity]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(identities.filter { !$0.isMain }) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func current(defaults: UserDefaults = .standard) -> BrowserIdentity {
        let all = load()
        guard let raw = defaults.string(forKey: currentKey), let id = UUID(uuidString: raw) else { return .main }
        return all.first { $0.id == id } ?? .main
    }

    static func setCurrent(_ id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(id.uuidString, forKey: currentKey)
    }

    @discardableResult
    static func add(name: String, colorHex: String? = nil, desktopUA: Bool = false) -> BrowserIdentity {
        var all = load()
        let color = colorHex ?? palette[(all.count - 1) % palette.count]
        let identity = BrowserIdentity(id: UUID(), name: name, colorHex: color, desktopUA: desktopUA)
        all.append(identity)
        save(all)
        return identity
    }

    static func update(_ identity: BrowserIdentity) {
        var all = load()
        guard !identity.isMain, let i = all.firstIndex(where: { $0.id == identity.id }) else { return }
        all[i] = identity
        save(all)
    }

    /// 删身份：清单、历史、收藏马上删；数据仓（这个身份登的号）交给 `removeDataStore` 在后台删
    static func delete(_ identity: BrowserIdentity, defaults: UserDefaults = .standard) {
        guard !identity.isMain else { return }
        save(load().filter { $0.id != identity.id })
        if current(defaults: defaults).id == identity.id { setCurrent(BrowserIdentity.mainID, defaults: defaults) }
        BrowsingHistoryStore.clear(identity: identity.id)
        BrowserFavoritesStore.remove(identity: identity.id)
    }

    /// 删数据仓。不 await 在界面上：11-10 模拟器实测刚看过这个身份的 cookie 时 remove 迟迟不回。
    /// 先让 WebKit 起来：这个进程还没建过 WKWebView 时，allDataStoreIdentifiers / remove(forIdentifier:)
    /// 在 WebKit 里派活到没初始化的主 RunLoop，直接崩（11-10 单测两份崩溃报告）。从没开过网页的数据仓不存在，不用删
    @MainActor
    static func removeDataStore(_ id: UUID) async {
        _ = WKWebView(frame: .zero)
        guard await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id) else { return }
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }

    /// 这个身份的数据仓里有 cookie 的域名（去掉开头的点）——主页收藏上的「已登录」小圆点
    @MainActor
    static func cookieDomains(_ identity: BrowserIdentity) async -> Set<String> {
        // 这个数据仓还没加载过网页时 allCookies 回空（11-10 模拟器：刚启动主页没有已登录点，开过一页才有）：先让它加载一张空页
        let config = WKWebViewConfiguration()
        config.websiteDataStore = identity.dataStore
        let probe = WKWebView(frame: .zero, configuration: config)
        probe.loadHTMLString("", baseURL: nil)
        try? await Task.sleep(for: .milliseconds(600))
        let cookies = await config.websiteDataStore.httpCookieStore.allCookies()
        _ = probe
        return Set(cookies.map { $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain })
    }

    /// host 命中任一 cookie 域（后缀子域匹配）
    static func hasCookies(host: String, in domains: Set<String>) -> Bool {
        let h = host.lowercased()
        return domains.contains { h == $0 || h.hasSuffix("." + $0) || $0.hasSuffix("." + h) }
    }
}

// MARK: - 收藏（每个身份一份；没存过 = 默认 5 个常用站）

struct BrowserFavorite: Codable, Identifiable, Equatable {
    var id: UUID
    var url: String
    var name: String

    var host: String {
        let h = URL(string: url)?.host() ?? url
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

enum BrowserFavoritesStore {
    static let defaults: [(String, String)] = [
        ("知乎", "https://www.zhihu.com"),
        ("豆瓣", "https://www.douban.com"),
        ("X", "https://x.com"),
        ("微博", "https://m.weibo.cn"),
        ("小红书", "https://www.xiaohongshu.com"),
    ]

    static var directory: URL { BrowserIdentityStore.directory }

    private static func fileURL(_ identity: UUID) -> URL {
        let name = identity == BrowserIdentity.mainID ? "browser-favorites.json" : "browser-favorites-\(identity.uuidString).json"
        return directory.appendingPathComponent(name)
    }

    static func load(identity: UUID) -> [BrowserFavorite] {
        guard let data = try? Data(contentsOf: fileURL(identity)),
              let list = try? JSONDecoder().decode([BrowserFavorite].self, from: data) else {
            return defaults.map { BrowserFavorite(id: UUID(), url: $0.1, name: $0.0) }
        }
        return list
    }

    static func save(_ list: [BrowserFavorite], identity: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL(identity), options: .atomic)
    }

    static func remove(identity: UUID) {
        try? FileManager.default.removeItem(at: fileURL(identity))
    }
}
