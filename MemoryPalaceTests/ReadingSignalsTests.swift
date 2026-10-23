import XCTest
import SwiftData
@testable import 记忆花园

/// CR-2 阅读在场信号：日界累加 / 30 天裁剪 / jsonl 轮转 / 今日事件计数。
/// 文件落 xctest 专用 profileId 目录，tearDown 清理。
/// 注：logTick 会顺手向 CCBridgeWebSocketClient 上报——未连接时 send 静默失败，无副作用。
final class ReadingSignalsTests: XCTestCase {
    static let pid = "xctest-cr2-signals"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.libraryRoot(profileId: Self.pid))
        super.tearDown()
    }

    func testLogTickAccumulatesPerDayAndBook() {
        let now = Date()
        ReadingSignals.logTick(bookSafeName: "b1", bookDisplayName: "书一", chapter: 3,
                               profileId: Self.pid, seconds: 60, now: now)
        ReadingSignals.logTick(bookSafeName: "b1", bookDisplayName: "书一", chapter: 4,
                               profileId: Self.pid, seconds: 60, now: now)
        ReadingSignals.logTick(bookSafeName: "b2", bookDisplayName: "书二", chapter: 1,
                               profileId: Self.pid, seconds: 60, now: now)

        let log = ReadingSignals.loadLog(profileId: Self.pid)
        let day = log.days[ReadingSignals.dayKey(now)]
        XCTAssertEqual(day?.totalSeconds, 180)
        XCTAssertEqual(day?.books["b1"]?.seconds, 120)
        XCTAssertEqual(day?.books["b1"]?.lastChapter, 4, "lastChapter 取最新")
        XCTAssertEqual(day?.books["b2"]?.seconds, 60)
    }

    func testPruneDropsOldDays() {
        var log = ReadingSignals.ReadingLog()
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -40, to: now)!
        log.days[ReadingSignals.dayKey(old)] = .init(totalSeconds: 100, books: [:])
        log.days[ReadingSignals.dayKey(now)] = .init(totalSeconds: 60, books: [:])

        ReadingSignals.prune(&log, keep: 30, now: now)

        XCTAssertNil(log.days[ReadingSignals.dayKey(old)], "40 天前的裁掉")
        XCTAssertNotNil(log.days[ReadingSignals.dayKey(now)])
    }

    func testEventLogRotationKeepsTail() {
        for i in 0..<2001 {
            ReadingSignals.logEvent(type: "highlight", book: "b", chapter: i,
                                    profileId: Self.pid)
        }
        let content = try! String(contentsOf: ReadingSignals.eventsURL(profileId: Self.pid), encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1000, "超 2000 裁到尾部 1000（含最新一条）")
        XCTAssertTrue(lines.last!.contains("\"chapter\":2000"), "保尾部（最新）")
    }

    func testTodayEventCountsFiltersByDay() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        ReadingSignals.logEvent(type: "highlight", book: "b", chapter: 1, profileId: Self.pid, now: yesterday)
        ReadingSignals.logEvent(type: "highlight", book: "b", chapter: 2, profileId: Self.pid, now: now)
        ReadingSignals.logEvent(type: "vocab", book: "b", chapter: 2, word: "apple", profileId: Self.pid, now: now)

        let counts = ReadingSignals.todayEventCounts(profileId: Self.pid, now: now)
        XCTAssertEqual(counts["highlight"], 1, "昨天的不计")
        XCTAssertEqual(counts["vocab"], 1)
    }

    // MARK: - R1 人格包

    @MainActor
    func testBuildPersonaPackageAssemblesIdentityAndMemories() throws {
        let container = try ModelContainer(
            for: Memory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let profile = Profile(
            name: "测试楼", emoji: "🌸", description: "",
            userName: "禾禾", assistantName: "小岚",
            systemPrompt: "温柔、直接，爱书成痴。"
        )
        let mem = Memory(content: "她在准备 GRE，读英文原著攒词汇", category: "goal", profileId: profile.id)
        ctx.insert(mem)
        try ctx.save()

        let pkg = ReadingSignals.buildPersonaPackage(profile: profile, context: ctx)
        XCTAssertTrue(pkg.contains("你是小岚"))
        XCTAssertTrue(pkg.contains("禾禾"))
        XCTAssertTrue(pkg.contains("温柔、直接"))
        XCTAssertTrue(pkg.contains("GRE"), "记忆注入段带进人格包")
    }
}
