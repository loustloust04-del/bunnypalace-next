import XCTest
@testable import 记忆花园

/// 日历隐私闸（plan-calendar §4.3，astra #5 #7 #8）：规范化后判定，绕过写法都挡住。
final class CalendarPrivacyTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let pid = "xctest-floor"

    override func setUp() {
        super.setUp()
        // #033：本类直接测 store，测试自己站在主线程调——不算生产违规
        MainThreadIO.allowMainThreadInThisTest()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cal-priv-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("journal"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        suite = "xctest.calendar.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var privacy: CalendarPrivacy { CalendarPrivacy(defaults: defaults) }

    private func deny(_ op: FileLibraryAccess.Op, _ path: String) -> String? {
        FileLibraryAccess.denial(op, path: path, profileId: pid, root: root, privacy: privacy)
    }

    func testJournalHiddenByDefaultAcrossSpellings() {
        for p in ["journal/2026-09-27.md", "./journal/2026-09-27.md", "JOURNAL/2026-09-27.md",
                  "notes/../journal/2026-09-27.md", " journal/x.md", "journal"] {
            XCTAssertNotNil(deny(.read, p), p)
            XCTAssertNotNil(deny(.write, p), p)
            XCTAssertFalse(FileLibraryAccess.visible(p, profileId: pid, root: root, privacy: privacy), p)
        }
    }

    /// #00207 返工：清单快路径（只看首段）和完整判定对枚举出来的真实路径结论一致，两种闸状态都对
    func testListedVisibleMatchesFullCheckForEnumeratedPaths() {
        let paths = ["journal/2026-09-27.md", "Journal/x.md", "journal", "calendar/anniversaries/a.json",
                     "notes/journal.md", "notes/a/b.md", "readme.md", "journals/x.md"]
        for on in [false, true] {
            privacy.setJournalVisible(on, pid)
            for p in paths {
                XCTAssertEqual(FileLibraryAccess.listedVisible(p, journalVisible: on),
                               FileLibraryAccess.visible(p, profileId: pid, root: root, privacy: privacy), "\(p) 闸=\(on)")
            }
        }
    }

    func testJournalVisibleIsReadOnly() {
        privacy.setJournalVisible(true, pid)
        XCTAssertNil(deny(.read, "./journal/2026-09-27.md"))
        XCTAssertNotNil(deny(.write, "journal/2026-09-27.md"))
    }

    func testGateIsPerFloor() {
        privacy.setJournalVisible(true, pid)
        XCTAssertNil(deny(.read, "journal/x.md"))
        XCTAssertNotNil(FileLibraryAccess.denial(.read, path: "journal/x.md", profileId: "other-floor", root: root, privacy: privacy))
    }

    func testCalendarFolderIsReadOnly() {
        XCTAssertNil(deny(.read, "calendar/anniversaries/a.json"))
        XCTAssertNotNil(deny(.write, "Calendar/anniversaries/a.json"))
    }

    func testOtherPathsUntouched() {
        XCTAssertNil(deny(.read, "notes/journal.md"))
        XCTAssertNil(deny(.write, "notes/journal/x.md"))
        XCTAssertNil(deny(.write, "journaling.md"))
    }

    func testSymlinkIntoJournalIsCaught() throws {
        let link = root.appendingPathComponent("notes/sneaky")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("journal"))
        // 还不存在的文件（经链接新建）也要挡
        XCTAssertNotNil(deny(.read, "notes/sneaky/2026-09-27.md"))
        XCTAssertNotNil(deny(.write, "notes/sneaky/new.md"))
        // 已存在的文件
        try "x".write(to: root.appendingPathComponent("journal/2026-09-27.md"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(deny(.read, "notes/sneaky/2026-09-27.md"))
    }

    func testEscapingRootIsNotAZone() {
        XCTAssertNil(FileLibraryAccess.zone(of: "../journal/x.md", root: root.appendingPathComponent("notes")))
        XCTAssertNil(FileLibraryAccess.zone(of: "/etc/passwd", root: root))
    }

    func testAnniversaryInjectDefaultsOn() {
        XCTAssertTrue(privacy.anniversaryInject(pid))
        privacy.setAnniversaryInject(false, pid)
        XCTAssertFalse(privacy.anniversaryInject(pid))
        XCTAssertFalse(privacy.injectTodayJournal(pid))
    }
}
