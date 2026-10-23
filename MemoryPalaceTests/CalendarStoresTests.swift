import XCTest
@testable import 记忆花园

/// 她的日记 / 纪念日 / 农历（plan-calendar §3，astra #9 #14）。全部用临时目录，不碰真文件库。
final class CalendarStoresTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cal-stores-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private var g: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    private var chinese: Calendar { AnniversaryMath.chineseCalendar(timeZone: g.timeZone) }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { g.date(from: DateComponents(year: y, month: m, day: d))! }

    // MARK: frontmatter

    func testParseRenderRoundTripKeepsEverything() {
        let text = "---\ndate: 2026-09-25\nmood: calm\nweather: 晴\n---\n\n  前面两个空格\n最后有换行\n"
        let doc = JournalDocument.parse(text)
        XCTAssertEqual(doc.frontmatter, ["date: 2026-09-25", "mood: calm", "weather: 晴"])
        XCTAssertEqual(doc.mood, .calm)
        XCTAssertEqual(doc.render(), text)
    }

    func testNoFrontmatterIsAllBody() {
        let text = "--- 不是分隔线\n正文"
        let doc = JournalDocument.parse(text)
        XCTAssertTrue(doc.frontmatter.isEmpty)
        XCTAssertEqual(doc.body, text)
        XCTAssertEqual(doc.render(), text)
    }

    func testSetMoodOnlyTouchesMoodLine() {
        var doc = JournalDocument.parse("---\ndate: x\nweather: 晴\n---\n正文")
        doc.setMood(.happy)
        XCTAssertEqual(doc.render(), "---\ndate: x\nweather: 晴\nmood: happy\n---\n正文")
        doc.setMood(.sad)
        XCTAssertEqual(doc.mood, .sad)
        XCTAssertEqual(doc.frontmatter.filter { $0.hasPrefix("mood") }.count, 1)
    }

    // MARK: JournalStore

    func testMoodWithoutJournalCreatesFrontmatterOnlyFile() throws {
        let store = JournalStore(root: tmp)
        try store.setMood(.tired, date: "2026-09-25")
        let doc = try XCTUnwrap(store.load(date: "2026-09-25"))
        XCTAssertEqual(doc.mood, .tired)
        XCTAssertEqual(doc.body, "")
        XCTAssertEqual(store.existingDates(), ["2026-09-25"])
    }

    func testMoodDoesNotClobberBody() throws {
        let store = JournalStore(root: tmp)
        let (fm, body) = JournalStore.expandTemplate(JournalStore.defaultTemplate, date: "2026-09-25", weekday: "周五")
        XCTAssertFalse(body.contains("这天的待办"))
        try store.saveBody(body + "\n写了一点", date: "2026-09-25", baseHash: nil, newFileFrontmatter: fm)
        try store.setMood(.happy, date: "2026-09-25")
        let doc = try XCTUnwrap(store.load(date: "2026-09-25"))
        XCTAssertTrue(doc.body.hasSuffix("写了一点"))
        XCTAssertEqual(doc.mood, .happy)
    }

    func testSaveDetectsExternalChange() throws {
        let store = JournalStore(root: tmp)
        let h1 = try store.saveBody("v1", date: "2026-09-25", baseHash: nil, newFileFrontmatter: [])
        // 别处改了文件
        try "别处改的".write(to: store.url(for: "2026-09-25"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.saveBody("v2", date: "2026-09-25", baseHash: h1, newFileFrontmatter: [])) { err in
            guard case JournalStoreError.conflict = err else { return XCTFail("应当是冲突") }
        }
        // 新文件却发现已经有了：也是冲突
        XCTAssertThrowsError(try store.saveBody("v2", date: "2026-09-25", baseHash: nil, newFileFrontmatter: []))
        // 选择覆盖
        try store.overwriteBody("v2", date: "2026-09-25", newFileFrontmatter: [])
        XCTAssertEqual(store.load(date: "2026-09-25")?.body, "v2")
    }

    func testMoodChangeDuringEditingIsKeptOnSave() throws {
        let store = JournalStore(root: tmp)
        let h1 = try store.saveBody("v1", date: "2026-09-25", baseHash: nil, newFileFrontmatter: ["date: 2026-09-25"])
        let h2 = try store.setMood(.calm, date: "2026-09-25")
        XCTAssertNotEqual(h1, h2)
        // 编辑器拿最新哈希保存：心情不丢
        try store.saveBody("v2", date: "2026-09-25", baseHash: h2, newFileFrontmatter: [])
        XCTAssertEqual(store.load(date: "2026-09-25")?.mood, .calm)
    }

    // MARK: AnniversaryStore

    func testAnniversaryFilesRoundTrip() throws {
        let store = AnniversaryStore(root: tmp)
        let a = Anniversary(title: "妈妈生日", kind: .yearly, isBirthday: true, date: "1970-10-28",
                            lunar: LunarMonthDay(month: 9, day: 9, leap: false), style: .stitch)
        let b = Anniversary(title: "去京都", kind: .countdown, date: "2026-11-14", style: .cut)
        try store.save(a)
        try store.save(b)
        let all = store.loadAll()
        XCTAssertEqual(Set(all.map(\.title)), ["妈妈生日", "去京都"])
        XCTAssertEqual(all.first { $0.id == a.id }?.lunar, a.lunar)
        try store.delete(id: a.id)
        XCTAssertEqual(store.loadAll().map(\.id), [b.id])
    }

    // MARK: 农历（期望值用 Foundation 中国历单独查过：2025 有闰六月，2026 没有；2026 八月只有 29 天）

    func testLeapBirthdayInYearWithThatLeapMonth() {
        // 闰六月初十，2025 有闰六月 → 2025-08-03（跳过正常六月初十 07-04）
        let d = AnniversaryMath.nextLunar(LunarMonthDay(month: 6, day: 10, leap: true), onOrAfter: day(2025, 7, 1), gregorian: g, chinese: chinese)
        XCTAssertEqual(d, day(2025, 8, 3))
    }

    func testLeapBirthdayFallsBackToNormalMonth() {
        // 2026 没有闰六月 → 正常六月初十 2026-07-23
        let d = AnniversaryMath.nextLunar(LunarMonthDay(month: 6, day: 10, leap: true), onOrAfter: day(2025, 9, 1), gregorian: g, chinese: chinese)
        XCTAssertEqual(d, day(2026, 7, 23))
    }

    func testNormalBirthdaySkipsLeapMonth() {
        // 正常六月初十：2025 的闰六月初十（08-03）不算 → 2026-07-23
        let d = AnniversaryMath.nextLunar(LunarMonthDay(month: 6, day: 10, leap: false), onOrAfter: day(2025, 7, 10), gregorian: g, chinese: chinese)
        XCTAssertEqual(d, day(2026, 7, 23))
    }

    func testThirtiethInShortMonthUsesTwentyNinth() {
        // 2026 八月只有 29 天（09-11 初一）→ 八月三十过廿九 = 2026-10-09
        let d = AnniversaryMath.nextLunar(LunarMonthDay(month: 8, day: 30, leap: false), onOrAfter: day(2026, 9, 1), gregorian: g, chinese: chinese)
        XCTAssertEqual(d, day(2026, 10, 9))
    }

    func testTodayIsTheDay() {
        // 2026-10-18 是九月初九
        let d = AnniversaryMath.nextLunar(LunarMonthDay(month: 9, day: 9, leap: false), onOrAfter: day(2026, 10, 18), gregorian: g, chinese: chinese)
        XCTAssertEqual(d, day(2026, 10, 18))
    }

    // MARK: 天数口径

    func testCountdownSinceYearly() {
        let today = day(2026, 9, 27)
        let trip = Anniversary(title: "去京都", kind: .countdown, date: "2026-11-14")
        XCTAssertEqual(AnniversaryMath.countdown(for: trip, today: today, gregorian: g)?.days, 48)
        let past = Anniversary(title: "过了", kind: .countdown, date: "2026-09-20")
        let p = AnniversaryMath.countdown(for: past, today: today, gregorian: g)
        XCTAssertEqual(p?.days, 7)
        XCTAssertEqual(p?.isPast, true)
        let met = Anniversary(title: "认识", kind: .since, date: "2026-09-27")
        XCTAssertEqual(AnniversaryMath.countdown(for: met, today: today, gregorian: g)?.days, 0)
        let bday = Anniversary(title: "生日", kind: .yearly, isBirthday: true, date: "2000-10-01")
        let b = AnniversaryMath.countdown(for: bday, today: today, gregorian: g)
        XCTAssertEqual(b?.days, 4)
        XCTAssertEqual(b?.occurrence, 26)
        let lunarBday = Anniversary(title: "妈妈", kind: .yearly, isBirthday: true, date: "1970-10-08",
                                    lunar: LunarMonthDay(month: 9, day: 9, leap: false))
        XCTAssertEqual(AnniversaryMath.countdown(for: lunarBday, today: today, gregorian: g, chinese: chinese)?.days, 21)
    }

    func testYearlyTodayIsZero() {
        let bday = Anniversary(title: "生日", kind: .yearly, date: "2000-09-27")
        XCTAssertEqual(AnniversaryMath.countdown(for: bday, today: day(2026, 9, 27), gregorian: g)?.days, 0)
    }
}
