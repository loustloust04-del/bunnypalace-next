import XCTest
import SwiftUI
@testable import 记忆花园

/// 纪念日照片 + 待办日期（plan-calendar-photos-todos）
@MainActor
final class CalendarPhotosTodosTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("photos-todos-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // MARK: 纪念日：兼容

    func testLegacyAnniversaryJSONWithoutPhotoDecodes() throws {
        let json = #"{"id":"a1","title":"妈妈生日","kind":"yearly","isBirthday":true,"date":"1970-10-28","style":"stitch","remindDays":3,"createdAt":"2026-09-27T00:00:00Z","updatedAt":"2026-09-27T00:00:00Z"}"#
        let a = try decoder.decode(Anniversary.self, from: Data(json.utf8))
        XCTAssertNil(a.photo)
        XCTAssertEqual(a.style, .stitch)
    }

    func testUnknownStyleFallsBackToStitch() throws {
        let json = #"{"id":"a2","title":"x","kind":"since","isBirthday":false,"date":"2025-01-01","style":"hologram","createdAt":"2026-09-27T00:00:00Z","updatedAt":"2026-09-27T00:00:00Z"}"#
        XCTAssertEqual(try decoder.decode(Anniversary.self, from: Data(json.utf8)).style, .stitch)
    }

    func testPhotoStyleFlags() {
        for s in [Anniversary.Style.polaroid, .stamp, .tape, .full, .film, .arch] {
            XCTAssertTrue(s.acceptsPhoto, "\(s)")
            XCTAssertTrue(s.needsPhoto, "\(s)")
        }
        XCTAssertTrue(Anniversary.Style.cut.acceptsPhoto)
        XCTAssertFalse(Anniversary.Style.cut.needsPhoto)
        for s in [Anniversary.Style.night, .stitch, .dust] { XCTAssertFalse(s.acceptsPhoto, "\(s)") }
    }

    // MARK: 纪念日：照片存取顺序（新图不可变 → JSON → 删旧图）

    private func files() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
    }

    func testReplaceWritesImmutableFileAndDeletesOld() throws {
        let store = AnniversaryStore(root: tmp)
        let a = Anniversary(id: "k1", title: "去京都", kind: .countdown, date: "2026-11-14", style: .polaroid)
        let first = try store.save(a, photo: .replace(Data("first".utf8)))
        let name1 = try XCTUnwrap(first.photo)
        XCTAssertTrue(name1.hasPrefix("k1-") && name1.hasSuffix(".jpg"))
        XCTAssertTrue(files().contains(name1))

        let second = try store.save(first, photo: .replace(Data("second".utf8)))
        let name2 = try XCTUnwrap(second.photo)
        XCTAssertNotEqual(name1, name2)
        XCTAssertEqual(files(), ["k1.json", name2])
        XCTAssertEqual(store.loadAll().first?.photo, name2)
    }

    func testKeepLeavesPhotoAlone() throws {
        let store = AnniversaryStore(root: tmp)
        let a = try store.save(Anniversary(id: "k2", title: "x", kind: .since, date: "2025-01-01", style: .full), photo: .replace(Data("p".utf8)))
        var edited = a
        edited.title = "改个名"
        try store.save(edited)
        XCTAssertEqual(store.loadAll().first?.photo, a.photo)
        XCTAssertTrue(files().contains(try XCTUnwrap(a.photo)))
    }

    func testRemoveAndDeleteCleanUpFiles() throws {
        let store = AnniversaryStore(root: tmp)
        let a = try store.save(Anniversary(id: "k3", title: "x", kind: .since, date: "2025-01-01", style: .film), photo: .replace(Data("p".utf8)))
        let removed = try store.save(a, photo: .remove)
        XCTAssertNil(removed.photo)
        XCTAssertEqual(files(), ["k3.json"])

        let again = try store.save(removed, photo: .replace(Data("q".utf8)))
        try store.delete(id: again.id)
        XCTAssertEqual(files(), [])
    }

    // MARK: 小组件缩略图（CalendarSnapshot 只编进 iOS / 小组件 target：只有 iOS 有系统小组件）

    #if os(iOS)
    func testThumbnailNameFollowsPhotoFileAndFloor() {
        let a = CalendarSnapshot.thumbnailName(profileId: "floor/1", photoFile: "k1-aaaa1111.jpg")
        let b = CalendarSnapshot.thumbnailName(profileId: "floor/1", photoFile: "k1-bbbb2222.jpg")
        XCTAssertNotEqual(a, b)                // 换图 → 换名（不可变）
        XCTAssertFalse(a.contains("/"))        // 楼层名里的斜杠不会变成子目录
        XCTAssertNotEqual(a, CalendarSnapshot.thumbnailName(profileId: "floor2", photoFile: "k1-aaaa1111.jpg"))
    }

    func testStaleThumbnailsKeepCurrentAndRecent() {
        let now = Date()
        let existing: [(name: String, modified: Date)] = [
            ("keep.jpg", now.addingTimeInterval(-10 * 86_400)),
            ("old.jpg", now.addingTimeInterval(-2 * 86_400)),
            ("fresh.jpg", now.addingTimeInterval(-3_600)),
        ]
        XCTAssertEqual(CalendarSnapshot.staleThumbnails(existing: existing, keep: ["keep.jpg"], now: now), ["old.jpg"])
    }

    func testLegacySnapshotItemWithoutPhotoDecodes() throws {
        let json = #"{"title":"元旦","kind":"countdown","isBirthday":false,"style":"night","baseDate":"2027-01-01","targets":["2027-01-01"]}"#
        XCTAssertNil(try JSONDecoder().decode(CalendarSnapshot.Item.self, from: Data(json.utf8)).photo)
    }
    #endif

    // MARK: 待办

    private func freshDefaults() -> UserDefaults {
        let name = "todo-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testLegacyTodoDataDecodes() throws {
        let d = freshDefaults()
        let legacy = #"[{"id":"8C0A6B1C-3B7E-4D5B-9F66-1E2B3C4D5E6F","text":"买花","done":true},{"id":"9C0A6B1C-3B7E-4D5B-9F66-1E2B3C4D5E6F","text":"打电话","done":false}]"#
        d.set(Data(legacy.utf8), forKey: "todoItems_v1")
        let m = TodoManager(defaults: d)
        XCTAssertEqual(m.items.map(\.text), ["买花", "打电话"])
        XCTAssertNil(m.items[0].date)
        XCTAssertNil(m.items[0].doneAt)
        XCTAssertEqual(m.remaining, 1)
    }

    private func seeded() -> TodoManager {
        let m = TodoManager(defaults: freshDefaults())
        m.add("今天没做", date: "2026-09-27")
        m.add("今天做了", date: "2026-09-27")
        m.add("过期", date: "2026-09-20")
        m.add("过期做了", date: "2026-09-21")
        m.add("没排日子")
        m.add("明天", date: "2026-09-28")
        m.add("下周", date: "2026-10-03")
        m.toggle(m.items[1].id)
        m.toggle(m.items[3].id)
        return m
    }

    func testActionListOrderTodayOverdueUndated() {
        XCTAssertEqual(seeded().actionList(today: "2026-09-27").map(\.text), ["今天没做", "过期", "没排日子"])
    }

    func testDayQueriesKeepDoneAndOverdueStaysOnItsDay() {
        let m = seeded()
        XCTAssertEqual(m.items(on: "2026-09-27").map(\.text), ["今天没做", "今天做了"])
        XCTAssertEqual(m.items(on: "2026-09-20").map(\.text), ["过期"])
        XCTAssertEqual(m.todayGroup(today: "2026-09-27").map(\.text), ["今天没做", "今天做了", "过期"])
        XCTAssertEqual(m.later(today: "2026-09-27").map(\.text), ["下周"])
    }

    func testMarksAllDoneOnlyWhenEveryItemDone() {
        let marks = TodoManager.marks(seeded().items)
        XCTAssertEqual(marks["2026-09-27"], false)
        XCTAssertEqual(marks["2026-09-21"], true)
        XCTAssertEqual(marks["2026-09-20"], false)
        XCTAssertNil(marks["2026-09-26"])
    }

    func testToggleSetsAndClearsDoneAtAndDateCanBeCleared() {
        let m = TodoManager(defaults: freshDefaults())
        m.add("x", date: "2026-09-27")
        let id = m.items[0].id
        m.toggle(id)
        XCTAssertNotNil(m.items[0].doneAt)
        m.toggle(id)
        XCTAssertNil(m.items[0].doneAt)
        m.setDate(nil, for: id)
        XCTAssertNil(m.items[0].date)
    }

    func testPersistsAcrossInstances() {
        let d = freshDefaults()
        TodoManager(defaults: d).add("留着", date: "2026-09-28")
        XCTAssertEqual(TodoManager(defaults: d).items.first?.date, "2026-09-28")
    }

    func testMonthMarksCarryTodoState() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let first = cal.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        var inputs = CalendarMarks.Inputs(summary: DailyActivity.Summary())
        inputs.todoMarks = ["2026-09-03": true, "2026-09-27": false]
        let marks = CalendarMarks.month(first, daysInMonth: 30, inputs: inputs, thresholds: [40, 100, 180], calendar: cal)
        XCTAssertEqual(marks[3]?.todo, true)
        XCTAssertEqual(marks[27]?.todo, false)
        XCTAssertNil(marks[4]?.todo)
    }

    func testTomorrowKeyCrossesMonth() {
        XCTAssertEqual(TodoManager.dayKey(after: "2026-09-30"), "2026-10-01")
        XCTAssertEqual(TodoManager.dayKey(after: "2026-12-31"), "2027-01-01")
    }

    func testPhotoURLPointsIntoStoreRoot() {
        let store = AnniversaryStore(root: tmp)
        var a = Anniversary(title: "x", kind: .since, date: "2025-01-01")
        XCTAssertNil(store.photoURL(a))
        a.photo = "abc-12345678.jpg"
        XCTAssertEqual(store.photoURL(a), tmp.appendingPathComponent("abc-12345678.jpg"))
    }
}
