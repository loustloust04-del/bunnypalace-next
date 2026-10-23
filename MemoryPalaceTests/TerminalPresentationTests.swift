import XCTest
@testable import 记忆花园

/// 终端 T1（plan-terminal-t1）里 tab 条 / 窗口面板 / 首页共用的纯逻辑。UI 在 iOS，这里只测跨端类型。
final class TerminalPresentationTests: XCTestCase {

    // MARK: - 重名编号

    func testNumberedKeepsFirstAndNumbersRest() {
        XCTAssertEqual(TerminalNames.numbered(["claude", "shell", "claude", "claude"]),
                       ["claude", "shell", "claude 2", "claude 3"])
    }

    func testNumberedSkipsNamesAlreadyTaken() {
        XCTAssertEqual(TerminalNames.numbered(["claude", "claude 2", "claude"]),
                       ["claude", "claude 2", "claude 3"])
    }

    func testNumberedLeavesUniqueNamesAlone() {
        XCTAssertEqual(TerminalNames.numbered(["a", "b"]), ["a", "b"])
        XCTAssertEqual(TerminalNames.numbered([]), [])
    }

    // MARK: - 引擎 / 格标

    func testAgentSessionEngineFallsBackToPrefix() {
        XCTAssertEqual(TerminalEngine.forAgentSession("mp-codex-2", reported: nil), .codex)
        XCTAssertEqual(TerminalEngine.forAgentSession("mp-cc-3f2a", reported: nil), .claude)
        XCTAssertEqual(TerminalEngine.forAgentSession("mp-codex-2", reported: "claude"), .claude)
    }

    func testWindowEngineDefaultsToShell() {
        XCTAssertEqual(TerminalEngine.forWindow(reported: nil), .shell)
        XCTAssertEqual(TerminalEngine.forWindow(reported: "codex"), .codex)
        XCTAssertEqual(TerminalEngine.shell.cell, .computer)
        XCTAssertEqual(TerminalEngine.claude.cell, .agent)
        XCTAssertEqual(TerminalEngine.codex.cell.rawValue, 3)
    }

    // MARK: - 状态点

    func testDotDeadOverridesPhase() {
        XCTAssertEqual(TerminalDot.resolve(phase: "waiting", dead: true), .dead)
        XCTAssertEqual(TerminalDot.resolve(phase: "waiting", dead: false), .waiting)
        XCTAssertEqual(TerminalDot.resolve(phase: "working", dead: false), .working)
        XCTAssertEqual(TerminalDot.resolve(phase: "done", dead: false), .done)
        XCTAssertNil(TerminalDot.resolve(phase: "idle", dead: false))
        XCTAssertNil(TerminalDot.resolve(phase: nil, dead: false))
    }

    // MARK: - 时间

    func testTimestampParsesBothHubAndLocalFormats() {
        XCTAssertNotNil(TerminalTimestamp.parse("2026-10-09T12:00:00.123Z"))
        XCTAssertNotNil(TerminalTimestamp.parse("2026-10-09T12:00:00Z"))
        XCTAssertNil(TerminalTimestamp.parse(nil))
        XCTAssertNil(TerminalTimestamp.parse("昨天"))
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(TerminalTimestamp.relative(now.addingTimeInterval(-20), now: now), "刚刚")
        XCTAssertEqual(TerminalTimestamp.relative(now.addingTimeInterval(-12 * 60), now: now), "12 分钟前")
        XCTAssertEqual(TerminalTimestamp.relative(now.addingTimeInterval(-3 * 3600), now: now), "3 小时前")
    }

    // MARK: - 最近

    func testRecentsMergeSortsByTimeAndLimits() {
        let windows = [
            TerminalWindowInfo(code: "aaaa", createdAt: "2026-10-09T10:00:00.000Z", alive: true,
                               title: nil, engine: nil, phase: nil),
            TerminalWindowInfo(code: "bbbb", createdAt: "2026-10-09T08:00:00.000Z", alive: true,
                               title: "nas", engine: "shell", phase: nil),
        ]
        let closed = [
            TerminalWindowInfo(code: "cccc", createdAt: "2026-10-01T00:00:00Z", closedAt: "2026-10-09T11:00:00Z",
                               alive: true, title: nil, engine: "codex", phase: nil),
        ]
        let agents = [
            TerminalAgentConversation(session: "mp-cc-1234", title: "夜聊",
                                      openedAt: TerminalTimestamp.parse("2026-10-09T12:00:00Z")!),
            TerminalAgentConversation(session: "mp-codex-1", title: "旧的",
                                      openedAt: TerminalTimestamp.parse("2026-10-01T12:00:00Z")!),
        ]
        let states = ["mp-cc-1234": TerminalStateEntry(target: .session(name: "mp-cc-1234"), phase: "waiting")]

        let items = TerminalRecents.merge(windows: windows, closed: closed, agents: agents,
                                          states: states, stale: false)

        XCTAssertEqual(items.map(\.kind), [
            .agent(session: "mp-cc-1234"),
            .closedWindow(code: "cccc"),
            .window(code: "aaaa"),
            .window(code: "bbbb"),
        ])
        XCTAssertEqual(items[0].dot, .waiting)
        XCTAssertEqual(items[0].cell, .agent)
        XCTAssertEqual(items[1].title, "codex")
        XCTAssertEqual(items[1].cell, .agent)
        XCTAssertNil(items[1].dot)
        XCTAssertEqual(items[2].title, "aaaa")
        XCTAssertEqual(items[2].cell, .computer)
        XCTAssertEqual(items[3].title, "nas")
    }

    func testRecentsStaleMarksOpenWindowsDead() {
        let windows = [TerminalWindowInfo(code: "aaaa", createdAt: "2026-10-09T10:00:00Z", alive: true,
                                          title: nil, engine: nil, phase: "working")]
        let items = TerminalRecents.merge(windows: windows, closed: [], agents: [], states: [:], stale: true)
        XCTAssertEqual(items.first?.dot, .dead)
    }
}
