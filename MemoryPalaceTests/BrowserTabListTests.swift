import XCTest
@testable import 记忆花园

/// plan-browser-tabs T1：开 / 关 / 切 / 卸载 / 上限 / 存盘
final class BrowserTabListTests: XCTestCase {
    private let me = BrowserIdentity.mainID
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testOpenInsertsAfterActiveAndSelects() {
        var list = BrowserTabList()
        let a = list.open(url: "https://a.com", identityID: me, at: t0)
        let b = list.open(url: "https://b.com", identityID: me, at: t0.addingTimeInterval(1))
        list.select(a, at: t0.addingTimeInterval(2))
        let c = list.open(url: nil, identityID: me, at: t0.addingTimeInterval(3))
        XCTAssertEqual(list.records.map(\.id), [a, c, b], "新页接在当前页后面")
        XCTAssertEqual(list.activeID, c)
        XCTAssertNil(list.active?.url, "新标签页没有网址 = 显示主页")
    }

    func testCloseActivePicksMostRecent() {
        var list = BrowserTabList()
        let a = list.open(url: "https://a.com", identityID: me, at: t0)
        let b = list.open(url: "https://b.com", identityID: me, at: t0.addingTimeInterval(1))
        let c = list.open(url: "https://c.com", identityID: me, at: t0.addingTimeInterval(2))
        list.select(a, at: t0.addingTimeInterval(3))
        list.select(c, at: t0.addingTimeInterval(4))
        list.close(c)
        XCTAssertEqual(list.activeID, a, "关掉当前页切到最近看过的")
        list.close(b)
        XCTAssertEqual(list.activeID, a, "关别的页不动当前页")
        list.close(a)
        XCTAssertNil(list.activeID)
        XCTAssertTrue(list.records.isEmpty)
    }

    func testCloseOthersAndAll() {
        var list = BrowserTabList()
        let a = list.open(url: "https://a.com", identityID: me)
        list.open(url: "https://b.com", identityID: me)
        list.closeOthers(keeping: a)
        XCTAssertEqual(list.records.map(\.id), [a])
        XCTAssertEqual(list.activeID, a)
        list.closeAll()
        XCTAssertNil(list.active)
    }

    func testUnloadOldestExceptActive() {
        var list = BrowserTabList()
        var ids: [UUID] = []
        for i in 0..<6 { ids.append(list.open(url: "https://\(i).com", identityID: me, at: t0.addingTimeInterval(Double(i)))) }
        list.select(ids[0], at: t0.addingTimeInterval(10))
        let unload = list.toUnload(live: Set(ids), limit: 4)
        XCTAssertEqual(unload, [ids[1], ids[2]], "最久没看的先卸，当前页（刚切回的 0）不卸")
        XCTAssertEqual(list.toUnload(live: Set(ids.prefix(4)), limit: 4), [])
    }

    func testTrimToMax() {
        var list = BrowserTabList()
        for i in 0..<(BrowserTabList.maxTabs + 3) {
            list.open(url: "https://\(i).com", identityID: me, at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(list.records.count, BrowserTabList.maxTabs)
        XCTAssertFalse(list.records.contains { $0.url == "https://0.com" }, "最久没看的被关掉")
        XCTAssertEqual(list.active?.url, "https://\(BrowserTabList.maxTabs + 2).com")
    }

    func testUpdateAndCodable() throws {
        var list = BrowserTabList()
        let other = UUID()
        let a = list.open(url: nil, identityID: me, at: t0)
        list.update(a, url: "https://x.com/p", title: "X", identityID: other)
        XCTAssertEqual(list.record(a)?.url, "https://x.com/p")
        XCTAssertEqual(list.record(a)?.identityID, other)
        let data = try JSONEncoder().encode(list)
        XCTAssertEqual(try JSONDecoder().decode(BrowserTabList.self, from: data), list)
    }
}
