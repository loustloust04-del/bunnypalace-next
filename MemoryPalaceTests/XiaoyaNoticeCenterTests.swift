import XCTest
@testable import 记忆花园

/// 小芽横幅队列（plan-status-panel §7.7）：去重 / 同源顶替 / 合并 / 持久化
@MainActor
final class XiaoyaNoticeCenterTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "xctest-xiaoya-notice-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func alert(_ id: String, source: String = "lineA", kind: StatusAlert.Kind = .bad, text: String = "线路检修掉了 1 颗：服务器B。点我看原因。",
                       createdAt: String = "2026-10-31T02:17:43Z") -> StatusAlert {
        StatusAlert(id: id, source: source, title: "线路检修", kind: kind, text: text, names: ["服务器B"], createdAt: createdAt)
    }

    func testOlderAlertDoesNotReplaceNewer() {
        let center = XiaoyaNoticeCenter(defaults: defaults)
        center.receive(alert("new", kind: .recovered, text: "好了", createdAt: "2026-10-31T03:00:00Z"))
        XCTAssertTrue(center.receive(alert("old", kind: .bad, text: "坏了", createdAt: "2026-10-31T02:00:00Z")), "旧的照样 ack")
        XCTAssertEqual(center.bannerText, "好了", "补投来的旧提醒不顶掉新的")
        center.receive(alert("old", kind: .bad, text: "坏了", createdAt: "2026-10-31T02:00:00Z"))
        XCTAssertEqual(center.bannerText, "好了")
        center.receive(alert("newer", kind: .bad, text: "又坏了", createdAt: "2026-10-31T04:00:00Z"))
        XCTAssertEqual(center.bannerText, "又坏了")
    }

    func testDuplicateIDIsAckedButNotRequeued() {
        let center = XiaoyaNoticeCenter(defaults: defaults)
        XCTAssertTrue(center.receive(alert("a1")))
        center.dismissAll()
        XCTAssertTrue(center.receive(alert("a1")), "收过的照样 ack")
        XCTAssertTrue(center.notices.isEmpty, "收过的不再挂出来")
    }

    func testSameSourceReplacesOld() {
        let center = XiaoyaNoticeCenter(defaults: defaults)
        center.receive(alert("a1"))
        center.receive(alert("a2", kind: .recovered, text: "线路检修又串满了，刚才那 1 条都通了。"))
        XCTAssertEqual(center.notices.count, 1)
        XCTAssertEqual(center.single?.kind, .recovered, "坏了→好了只留「好了」")
        XCTAssertEqual(center.bannerText, "线路检修又串满了，刚才那 1 条都通了。")
    }

    func testTwoOrMoreMerge() {
        let center = XiaoyaNoticeCenter(defaults: defaults)
        XCTAssertNil(center.bannerText)
        center.receive(alert("a1", source: "lineA"))
        center.receive(alert("b1", source: "serverB"))
        XCTAssertNil(center.single)
        XCTAssertEqual(center.bannerText, "有 2 件事要你看一眼。")
        center.dismissAll()
        XCTAssertNil(center.bannerText)
    }

    func testPersistenceRoundTrip() {
        let center = XiaoyaNoticeCenter(defaults: defaults)
        center.receive(alert("a1", source: "lineA"))
        center.receive(alert("b1", source: "serverB"))
        let reloaded = XiaoyaNoticeCenter(defaults: defaults)
        XCTAssertEqual(reloaded.notices, center.notices)
        XCTAssertTrue(reloaded.receive(alert("a1")))
        XCTAssertEqual(reloaded.notices.count, 2, "重启后 id 去重照样认")
    }

    func testSeenKeepsLatest200() {
        let center = XiaoyaNoticeCenter(defaults: defaults)
        for i in 0..<205 { center.receive(alert("id\(i)")) }
        center.dismissAll()
        XCTAssertTrue(center.receive(alert("id0")))
        XCTAssertEqual(center.notices.count, 1, "超出 200 的老 id 被挤掉，再来会重新挂")
        center.dismissAll()
        center.receive(alert("id204"))
        XCTAssertTrue(center.notices.isEmpty)
    }
}
