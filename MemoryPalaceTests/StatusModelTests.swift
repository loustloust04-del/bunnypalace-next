import XCTest
@testable import 记忆花园

/// 状态面板（plan-status-panel §7）：帧解析 + 每串判定 + 时间三档
final class StatusModelTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    /// 2026-10-31 10:17 上海
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10, minute: 17))! }

    private func source(id: String = "lineA", items: [StatusSource.Item], checkedHoursAgo: Double = 1, stale: Double = 36) -> StatusSource {
        StatusSource(id: id, title: "线路检修", checkedAt: now.addingTimeInterval(-checkedHoursAgo * 3600), staleAfterHours: stale,
                     items: items, canRun: false, running: false)
    }

    private let allOK = [StatusSource.Item(name: "线路A", ok: true, detail: nil), StatusSource.Item(name: "服务器B", ok: true, detail: nil)]
    private let oneBad = [StatusSource.Item(name: "线路A", ok: true, detail: nil), StatusSource.Item(name: "服务器B", ok: false, detail: "连不上")]

    private var gardenOK: GardenSelfCheck {
        GardenSelfCheck(connected: true, lastError: nil, memoryOn: true, memoryFailure: nil, memoryLastOK: now.addingTimeInterval(-180),
                        budgetEnabled: true, spentUSD: 3.2, limitUSD: 10, backupEnabled: false, lastBackup: nil, notify: .on)
    }

    // MARK: 帧解析

    func testStatusResultFrameParses() throws {
        let json = """
        {"type":"status_result","sources":[{"id":"lineA","title":"线路检修","checkedAt":"2026-10-31T10:17:42+08:00",
          "staleAfterHours":24,"items":[{"name":"线路A","ok":true,"detail":""},{"name":"服务器B","ok":false,"detail":"连不上"}],
          "receivedAt":"2026-10-31T02:17:43.120Z","canRun":true,"running":false},
          {"id":"backup","checkedAt":"2026-10-30T02:00:00.500Z","items":[{"name":"盘B","ok":true}]}],
         "quiet":{"start":"23:30","end":"08:30","tz":"Asia/Shanghai"}}
        """
        let frame = try JSONDecoder().decode(StatusResultFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.sources.count, 2)
        let first = frame.sources[0]
        XCTAssertEqual(first.title, "线路检修")
        XCTAssertEqual(first.staleAfterHours, 24)
        XCTAssertTrue(first.canRun)
        XCTAssertNil(first.items[0].detail, "空 detail 当没有")
        XCTAssertEqual(first.items[1].detail, "连不上")
        XCTAssertNotNil(first.checkedAt)
        let second = frame.sources[1]
        XCTAssertEqual(second.title, "backup", "没给 title 用 id")
        XCTAssertEqual(second.staleAfterHours, 36)
        XCTAssertFalse(second.canRun)
        XCTAssertNotNil(second.checkedAt, "带毫秒的 ISO 也认")
        XCTAssertEqual(frame.quiet, StatusQuiet(start: "23:30", end: "08:30", tz: "Asia/Shanghai"))
    }

    func testStatusAlertFrameParses() throws {
        let json = """
        {"type":"status_alert","alert":{"id":"9b1f","source":"lineA","title":"线路检修","kind":"bad",
          "text":"线路检修掉了 1 颗：服务器B。点我看原因。","names":["服务器B"],"createdAt":"2026-10-31T02:17:43.000Z"}}
        """
        let alert = try JSONDecoder().decode(StatusAlertFrame.self, from: Data(json.utf8)).alert
        XCTAssertEqual(alert.id, "9b1f")
        XCTAssertEqual(alert.kind, .bad)
        XCTAssertEqual(alert.names, ["服务器B"])
        let recovered = try JSONDecoder().decode(StatusAlertFrame.self, from: Data(#"{"alert":{"id":"x","source":"lineA","kind":"recovered","text":"好了"}}"#.utf8)).alert
        XCTAssertEqual(recovered.kind, .recovered)
        XCTAssertEqual(recovered.title, "lineA")
        XCTAssertEqual(recovered.names, [])
    }

    func testMalformedAlertRejected() {
        XCTAssertNil(try? JSONDecoder().decode(StatusAlertFrame.self, from: Data(#"{"alert":{"id":"x","kind":"weird","text":"?"}}"#.utf8)))
    }

    // MARK: 判定

    func testAllGreen() {
        let strand = StatusModel.strand(source(items: allOK), now: now)
        XCTAssertEqual(strand.verdict, .ok)
        let head = StatusModel.headline([strand, StatusModel.gardenStrand(gardenOK, now: now, calendar: calendar)], now: now, calendar: calendar)
        XCTAssertEqual(head.title, "都通着")
        XCTAssertEqual(head.subtitle, "线路检修 · 今天 09:17 查的")
    }

    func testBadCountsAndHeadline() {
        let strand = StatusModel.strand(source(items: oneBad), now: now)
        XCTAssertEqual(strand.verdict, .bad(1))
        XCTAssertEqual(strand.badLines.map(\.name), ["服务器B"])
        XCTAssertEqual(strand.badLines.first?.detail, "连不上")
        let strands = [strand, StatusModel.gardenStrand(gardenOK, now: now, calendar: calendar)]
        XCTAssertEqual(StatusModel.worst(strands)?.sourceID, "lineA")
        XCTAssertEqual(StatusModel.headline(strands, now: now, calendar: calendar).title, "一颗掉了")
    }

    func testStaleOverridesRedAndGreen() {
        let staleBad = StatusModel.strand(source(items: oneBad, checkedHoursAgo: 37), now: now)
        XCTAssertEqual(staleBad.verdict, .stale)
        let staleOK = StatusModel.strand(source(items: allOK, checkedHoursAgo: 25, stale: 24), now: now)
        XCTAssertEqual(staleOK.verdict, .stale, "源自定 staleAfterHours")
        let fresh = StatusModel.strand(source(items: allOK, checkedHoursAgo: 35), now: now)
        XCTAssertEqual(fresh.verdict, .ok)
        let head = StatusModel.headline([staleOK, StatusModel.gardenStrand(gardenOK, now: now, calendar: calendar)], now: now, calendar: calendar)
        XCTAssertEqual(head.title, "检修没跑")
    }

    func testEmptyHasOnlyGarden() {
        let strands = StatusModel.strands(sources: [], garden: gardenOK, now: now, calendar: calendar)
        XCTAssertEqual(strands.map(\.id), [StatusModel.gardenID])
        XCTAssertEqual(StatusModel.headline(strands, now: now, calendar: calendar).title, "都通着")
    }

    func testWorstPrefersBadOverStale() {
        let stale = StatusModel.strand(source(id: "a", items: allOK, checkedHoursAgo: 40), now: now)
        let bad = StatusModel.strand(source(id: "b", items: oneBad), now: now)
        XCTAssertEqual(StatusModel.worst([stale, bad])?.sourceID, "b")
        let strands = StatusModel.strands(sources: [source(id: "b", items: oneBad), source(id: "a", items: allOK)],
                                          garden: gardenOK, now: now, calendar: calendar)
        XCTAssertEqual(strands.map(\.sourceID), ["a", "b", nil], "外部源按 id 在前，花园自检在后")
    }

    func testExternalSourceNamedGardenIsNotSelfCheck() {
        let strands = StatusModel.strands(sources: [source(id: StatusModel.gardenID, items: oneBad)], garden: gardenOK, now: now, calendar: calendar)
        XCTAssertEqual(strands.count, 2)
        XCTAssertEqual(Set(strands.map(\.id)).count, 2, "ForEach id 不撞")
        XCTAssertEqual(strands.map(\.isGarden), [false, true], "外部源叫 garden 也不当自检")
        XCTAssertEqual(strands.first?.sourceID, StatusModel.gardenID, "发 status_run 仍用原始 id")
        XCTAssertEqual(strands.first?.verdict, .bad(1))
        XCTAssertEqual(StatusModel.headline(strands, now: now, calendar: calendar).subtitle, "线路检修 · 今天 09:17 查的")
    }

    func testLocalCopyRoundTripsWithoutRunning() throws {
        let running = StatusSource(id: "lineA", title: "线路检修", checkedAt: now, staleAfterHours: 24, items: oneBad, canRun: true, running: true)
        let frame = StatusResultFrame(sources: [running], quiet: StatusQuiet(start: "23:00", end: "07:00", tz: "Asia/Shanghai"))
        let back = try JSONDecoder().decode(StatusResultFrame.self, from: JSONEncoder().encode(frame))
        let source = try XCTUnwrap(back.sources.first)
        XCTAssertEqual(source.items, oneBad)
        XCTAssertEqual(source.checkedAt.map { Int($0.timeIntervalSince1970) }, Int(now.timeIntervalSince1970))
        XCTAssertTrue(source.canRun)
        XCTAssertFalse(source.running, "running 是此刻的事，不进本地副本")
        XCTAssertEqual(back.quiet, frame.quiet)
    }

    func testGardenBeads() {
        var check = gardenOK
        check.backupEnabled = false
        var strand = StatusModel.gardenStrand(check, now: now, calendar: calendar)
        XCTAssertEqual(strand.lines.map(\.bead), [.ok, .ok, .ok, .off, .ok], "备份没开 = 灰珠不算坏")
        XCTAssertEqual(strand.verdict, .ok)
        XCTAssertEqual(strand.lines[1].detail, "3 分钟前整理过")
        XCTAssertEqual(strand.lines[2].detail, "花了 $3.20，上限 $10")

        check.connected = false
        check.lastError = "auth"
        check.memoryFailure = .init(text: "最近记不住新东西了", streak: 3)
        check.spentUSD = 10
        check.backupEnabled = true
        check.lastBackup = now.addingTimeInterval(-4 * 86400)
        check.notify = .off
        strand = StatusModel.gardenStrand(check, now: now, calendar: calendar)
        XCTAssertEqual(strand.verdict, .bad(5))
        XCTAssertEqual(strand.lines[0].detail, "口令不对：重新扫码配对一次")
        XCTAssertEqual(strand.lines[1].detail, "最近记不住新东西了 · 连续 3 次")

        check.lastBackup = now.addingTimeInterval(-2 * 86400)
        check.notify = .bannerOnly
        strand = StatusModel.gardenStrand(check, now: now, calendar: calendar)
        XCTAssertEqual(strand.lines[3].bead, .ok, "3 天内备过不算坏")
        XCTAssertEqual(strand.lines[4].bead, .off)
    }

    func testNamesPreview() {
        XCTAssertEqual(StatusModel.namesPreview(["线路A", "服务器B"]), "线路A、服务器B")
        XCTAssertEqual(StatusModel.namesPreview(["线路A", "线路B", "线路C", "服务器B"]), "线路A、线路B、线路C等")
        XCTAssertEqual(StatusModel.countWord(2), "两")
    }

    // MARK: 时间三档

    func testTimeFormats() {
        XCTAssertEqual(StatusTime.format(now.addingTimeInterval(-3600), now: now, calendar: calendar), "09:17")
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 23, minute: 10))!
        XCTAssertEqual(StatusTime.format(yesterday, now: now, calendar: calendar), "昨天 23:10")
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 10, minute: 17))!
        XCTAssertEqual(StatusTime.format(earlier, now: now, calendar: calendar), "10月29日")
        XCTAssertEqual(StatusTime.phrase(now, now: now, calendar: calendar), "今天 10:17")
    }

    func testTimeFollowsDeviceZone() {
        // 同一时刻：上海 10-31 00:30，太平洋 10-30 09:30 —— 按设备时区分「今天 / 昨天」
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let shanghaiMidnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 0, minute: 30))!
        XCTAssertEqual(StatusTime.format(shanghaiMidnight, now: now, calendar: calendar), "00:30")
        XCTAssertEqual(StatusTime.format(shanghaiMidnight, now: now, calendar: pacific), "09:30", "太平洋那边 now 还是 10-30")
    }

    func testAgo() {
        XCTAssertEqual(StatusTime.ago(now.addingTimeInterval(-20), now: now), "刚刚")
        XCTAssertEqual(StatusTime.ago(now.addingTimeInterval(-180), now: now), "3 分钟前")
        XCTAssertEqual(StatusTime.ago(now.addingTimeInterval(-2 * 86400), now: now), "2 天前")
    }
}
