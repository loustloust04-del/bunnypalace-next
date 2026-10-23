#if PERSONAL_APPS
import XCTest
@testable import 记忆花园

@MainActor
final class DeathScaleStoreTests: XCTestCase {
    private var root: URL!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DeathScaleTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeStore() -> DeathScaleStore {
        DeathScaleStore(root: root, now: { [unowned self] in self.clock })
    }

    func testAddRemoveEditWriteLedgerWithSums() throws {
        let s = makeStore()
        let a = try XCTUnwrap(s.add(side: .die, text: "累", weight: 5))
        let b = try XCTUnwrap(s.add(side: .live, text: "小雾", weight: 7))
        _ = s.add(side: .die, text: "超重", weight: 42)
        XCTAssertEqual(s.sum(.die), 14, "分量夹到 9")
        XCTAssertEqual(s.sum(.live), 7)

        s.setWeight(a.id, 2)
        s.setText(b.id, "小雾和花园")
        s.remove(a.id)
        XCTAssertEqual(s.sum(.die), 9)
        XCTAssertEqual(s.reasons.first { $0.id == b.id }?.text, "小雾和花园")

        XCTAssertEqual(s.ledger.map(\.kind), [.add, .add, .add, .weight, .text, .remove])
        XCTAssertEqual(s.ledger.map(\.sumDie), [5, 5, 14, 11, 11, 9])
        XCTAssertEqual(s.ledger.map(\.sumLive), [0, 7, 7, 7, 7, 7])
        XCTAssertEqual(s.ledger[3].from, "5")
        XCTAssertEqual(s.ledger[3].to, "2")
        XCTAssertEqual(s.ledger[4].from, "小雾")
        XCTAssertEqual(s.ledger[5].text, "累")

        s.setWeight(b.id, 7)
        s.setText(b.id, "小雾和花园")
        XCTAssertEqual(s.ledger.count, 6, "没变化不记账")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.reasons, s.reasons)
        XCTAssertEqual(reloaded.ledger, s.ledger)
        let lines = try String(contentsOf: root.appendingPathComponent("ledger.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 6, "jsonl 每条一行")
    }

    func testHourOpenCloseAndSurvivesRestart() throws {
        let s = makeStore()
        let h = try XCTUnwrap(s.startHour())
        XCTAssertEqual(s.startHour()?.id, h.id, "已在计时就不再开一段")
        XCTAssertEqual(s.openHour?.id, h.id)

        let reopened = makeStore()
        XCTAssertEqual(reopened.openHour?.id, h.id, "未结束的段重开还在")
        XCTAssertNil(reopened.openHour?.end)

        clock += 125
        reopened.endHour()
        XCTAssertNil(reopened.openHour)
        XCTAssertEqual(reopened.hours.first?.end?.timeIntervalSince(h.start), 125)
        XCTAssertEqual(reopened.ledger.map(\.kind), [.hourOpen, .hourClose])
    }

    func testHourAddEditDeleteLogged() throws {
        let s = makeStore()
        let start = clock - 3600
        let h = try XCTUnwrap(s.addHour(start: start, end: start + 60))
        XCTAssertNil(s.addHour(start: start, end: start - 1), "结束早于开始不收")
        s.editHour(h.id, start: start, end: start + 90)
        XCTAssertEqual(s.hours.first?.end, start + 90)
        s.deleteHour(h.id)
        XCTAssertTrue(s.hours.isEmpty)
        XCTAssertEqual(s.ledger.map(\.kind), [.hourEdit, .hourEdit, .hourDelete])
    }

    func testCarnetNotLogged() {
        let s = makeStore()
        s.setCarnet("今天\n下雨")
        XCTAssertTrue(s.ledger.isEmpty)
        XCTAssertEqual(makeStore().carnet, "今天\n下雨")
    }

    func testAccessGrantRevoke() {
        let s = makeStore()
        XCTAssertFalse(s.canRead(profileId: "p1"))
        s.grantRead("p1")
        s.grantRead("p1")
        s.grantRead("p2")
        XCTAssertEqual(s.readableProfileIds, ["p1", "p2"])
        XCTAssertTrue(makeStore().canRead(profileId: "p1"))
        s.revokeRead("p1")
        XCTAssertEqual(makeStore().readableProfileIds, ["p2"])
        XCTAssertFalse(s.canRead(profileId: nil))
        XCTAssertFalse(s.canRead(profileId: ""))
        XCTAssertTrue(s.ledger.isEmpty, "权限变动不进账簿")
    }

    func testTimeFormatIgnoresDeviceTimeZone() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(DeathScaleTime.format(Date(timeIntervalSince1970: 0)), "01.01.1970 · 08:00:00")
        // 2026-10-01 07:00:05 UTC = 东八 15:00:05（PDT 那边还是 00:00:05）
        XCTAssertEqual(DeathScaleTime.format(Date(timeIntervalSince1970: 1_790_838_005)), "01.10.2026 · 15:00:05")
    }
}
#endif
