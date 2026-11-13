import XCTest
@testable import 记忆花园

/// plan-garden-browser-identities：身份清单 / 收藏 / 历史各身份一份，历史同网址一条
final class BrowserIdentityTests: XCTestCase {
    private var saved: URL!
    private var temp: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        saved = BrowserIdentityStore.directory
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("browser-identity-\(UUID().uuidString)")
        BrowserIdentityStore.directory = temp
        defaults = UserDefaults(suiteName: "browser-identity-\(UUID().uuidString)")
    }

    override func tearDown() {
        BrowserIdentityStore.directory = saved
        try? FileManager.default.removeItem(at: temp)
    }

    func testHistoryKeepsOneEntryPerURL() {
        BrowsingHistoryStore.append(url: "https://a.com", title: "A")
        BrowsingHistoryStore.append(url: "https://b.com", title: "B")
        BrowsingHistoryStore.append(url: "https://a.com", title: "A2")
        let entries = BrowsingHistoryStore.load()
        XCTAssertEqual(entries.map(\.url), ["https://a.com", "https://b.com"])
        XCTAssertEqual(entries.first?.title, "A2")
    }

    func testHistoryIsPerIdentity() {
        let other = BrowserIdentityStore.add(name: "小号")
        BrowsingHistoryStore.append(url: "https://a.com", title: "A")
        BrowsingHistoryStore.append(url: "https://x.com", title: "X", identity: other.id)
        XCTAssertEqual(BrowsingHistoryStore.load().map(\.url), ["https://a.com"])
        XCTAssertEqual(BrowsingHistoryStore.load(identity: other.id).map(\.url), ["https://x.com"])
        BrowsingHistoryStore.remove(id: BrowsingHistoryStore.load().first!.id)
        XCTAssertTrue(BrowsingHistoryStore.load().isEmpty)
    }

    func testFavoritesDefaultThenRoundTrip() {
        let defaultsList = BrowserFavoritesStore.load(identity: BrowserIdentity.mainID)
        XCTAssertEqual(defaultsList.map(\.name), ["知乎", "豆瓣", "X", "微博", "小红书"])
        let mine = [BrowserFavorite(id: UUID(), url: "https://www.bilibili.com", name: "B 站")]
        BrowserFavoritesStore.save(mine, identity: BrowserIdentity.mainID)
        XCTAssertEqual(BrowserFavoritesStore.load(identity: BrowserIdentity.mainID), mine)
        XCTAssertEqual(mine[0].host, "bilibili.com")
    }

    func testIdentityListKeepsMainFirstAndCurrentFallsBack() {
        XCTAssertEqual(BrowserIdentityStore.load(), [.main])
        var alt = BrowserIdentityStore.add(name: "小号")
        alt.desktopUA = true
        BrowserIdentityStore.update(alt)
        XCTAssertEqual(BrowserIdentityStore.load(), [.main, alt])
        XCTAssertEqual(alt.userAgent, WebUserAgent.macDesktop)

        BrowserIdentityStore.setCurrent(alt.id, defaults: defaults)
        XCTAssertEqual(BrowserIdentityStore.current(defaults: defaults), alt)
        BrowserIdentityStore.save([.main])
        XCTAssertEqual(BrowserIdentityStore.current(defaults: defaults), .main)
    }

    @MainActor
    func testDeleteRemovesHistoryAndFavorites() async {
        let alt = BrowserIdentityStore.add(name: "工作")
        BrowserIdentityStore.setCurrent(alt.id, defaults: defaults)
        BrowsingHistoryStore.append(url: "https://a.com", title: "A", identity: alt.id)
        BrowserFavoritesStore.save([], identity: alt.id)
        BrowserIdentityStore.delete(alt, defaults: defaults)
        await BrowserIdentityStore.removeDataStore(alt.id)
        XCTAssertEqual(BrowserIdentityStore.load(), [.main])
        XCTAssertEqual(BrowserIdentityStore.current(defaults: defaults), .main)
        XCTAssertTrue(BrowsingHistoryStore.load(identity: alt.id).isEmpty)
        XCTAssertEqual(BrowserFavoritesStore.load(identity: alt.id).count, BrowserFavoritesStore.defaults.count)
    }

    func testCookieHostMatch() {
        let domains: Set<String> = ["zhihu.com", "x.com"]
        XCTAssertTrue(BrowserIdentityStore.hasCookies(host: "www.zhihu.com", in: domains))
        XCTAssertTrue(BrowserIdentityStore.hasCookies(host: "x.com", in: domains))
        XCTAssertFalse(BrowserIdentityStore.hasCookies(host: "douban.com", in: domains))
    }
}
