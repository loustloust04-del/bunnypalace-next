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

        let items = TerminalRecents.merge([TerminalRecentSource(hubId: "primary", windows: windows, closed: closed,
                                                                agents: agents, states: states)])

        XCTAssertEqual(items.map(\.kind), [
            .agent(session: "mp-cc-1234"),
            .closedWindow(code: "cccc"),
            .window(code: "aaaa"),
            .window(code: "bbbb"),
        ])
        XCTAssertEqual(items[0].dot, .waiting)
        XCTAssertEqual(items[0].engine, .claude)
        XCTAssertEqual(items[1].title, "codex")
        XCTAssertEqual(items[1].engine, .codex)
        XCTAssertNil(items[1].dot)
        XCTAssertEqual(items[2].title, "aaaa")
        XCTAssertEqual(items[2].engine, .shell)
        XCTAssertEqual(items[3].title, "nas")
        XCTAssertTrue(items.allSatisfy { $0.hubId == "primary" && !$0.offline })
    }

    func testRecentsStaleMarksOpenWindowsDead() {
        let windows = [TerminalWindowInfo(code: "aaaa", createdAt: "2026-10-09T10:00:00Z", alive: true,
                                          title: nil, engine: nil, phase: "working")]
        let items = TerminalRecents.merge([TerminalRecentSource(hubId: "primary", windows: windows, stale: true)])
        XCTAssertEqual(items.first?.dot, .dead)
        XCTAssertEqual(items.first?.offline, false)
    }

    /// 等你回复的固定排第一（1 台也生效），不管它多旧；其余照时间倒序（plan-multi-hub B4.2c）
    func testRecentsPinWaitingFirstEvenWhenOlder() {
        let windows = [
            TerminalWindowInfo(code: "new1", createdAt: "2026-10-09T12:00:00Z", alive: true, title: nil, engine: nil, phase: "working"),
            TerminalWindowInfo(code: "new2", createdAt: "2026-10-09T11:00:00Z", alive: true, title: nil, engine: nil, phase: nil),
            TerminalWindowInfo(code: "new3", createdAt: "2026-10-09T10:00:00Z", alive: true, title: nil, engine: nil, phase: nil),
            TerminalWindowInfo(code: "new4", createdAt: "2026-10-09T09:00:00Z", alive: true, title: nil, engine: nil, phase: nil),
            TerminalWindowInfo(code: "old", createdAt: "2026-10-01T00:00:00Z", alive: true, title: nil, engine: "claude", phase: "waiting"),
        ]
        let items = TerminalRecents.merge([TerminalRecentSource(hubId: "primary", windows: windows)])
        XCTAssertEqual(items.map(\.kind), [.window(code: "old"), .window(code: "new1"), .window(code: "new2"), .window(code: "new3")])
        XCTAssertEqual(items[0].dot, .waiting)
    }

    /// 两台混排；连不上那台的条目标 offline、点灰掉，不会被当成「等你」置顶
    func testRecentsMixHubsAndGreyOfflineHub() {
        let mac = TerminalRecentSource(hubId: "primary", windows: [
            TerminalWindowInfo(code: "m1", createdAt: "2026-10-09T10:00:00Z", alive: true, title: nil, engine: "codex", phase: "working"),
        ])
        let nyc = TerminalRecentSource(
            hubId: "nyc",
            windows: [TerminalWindowInfo(code: "n1", createdAt: "2026-10-09T11:00:00Z", alive: true, title: "deploy", engine: nil, phase: nil)],
            agents: [TerminalAgentConversation(session: "mp-cc-9", title: "cc-rp",
                                               openedAt: TerminalTimestamp.parse("2026-10-09T12:00:00Z")!, hubId: "nyc")],
            states: ["mp-cc-9": TerminalStateEntry(target: .session(name: "mp-cc-9"), phase: "waiting")],
            offline: true
        )
        let items = TerminalRecents.merge([mac, nyc])
        XCTAssertEqual(items.map(\.kind), [.agent(session: "mp-cc-9"), .window(code: "n1"), .window(code: "m1")])
        XCTAssertEqual(items.map(\.hubId), ["nyc", "nyc", "primary"])
        XCTAssertEqual(items.map(\.offline), [true, true, false])
        XCTAssertEqual(items[0].dot, .dead)
        XCTAssertEqual(items[2].dot, .working)
    }

    /// 待配对那台：开着的 / 收起的 / Agent 条目都带 needsPairing（「最近」写「要重新配对」，跟首页那行一个说法）
    func testRecentsCarryNeedsPairingFromSource() {
        let mac = TerminalRecentSource(hubId: "primary", windows: [
            TerminalWindowInfo(code: "m1", createdAt: "2026-10-09T10:00:00Z", alive: true, title: nil, engine: nil, phase: nil),
        ])
        let test = TerminalRecentSource(
            hubId: "t",
            windows: [TerminalWindowInfo(code: "t1", createdAt: "2026-10-09T11:00:00Z", alive: true, title: nil, engine: nil, phase: nil)],
            closed: [TerminalWindowInfo(code: "t2", createdAt: "2026-10-01T00:00:00Z", closedAt: "2026-10-09T09:00:00Z",
                                        alive: false, title: nil, engine: nil, phase: nil)],
            agents: [TerminalAgentConversation(session: "mp-cc-1", title: "x",
                                               openedAt: TerminalTimestamp.parse("2026-10-09T12:00:00Z")!, hubId: "t")],
            offline: true,
            needsPairing: true
        )
        let items = TerminalRecents.merge([mac, test])
        XCTAssertEqual(items.map(\.hubId), ["t", "t", "primary", "t"])
        XCTAssertEqual(items.map(\.needsPairing), [true, true, false, true])
        XCTAssertTrue(items.filter(\.needsPairing).allSatisfy(\.offline))
    }

    /// 小标记按引擎出：螃蟹（Claude Code）和 Codex 分开，shell / 小电脑各一种（B4.2a）
    func testRecentEngineSeparatesClaudeAndCodex() {
        let windows = [
            TerminalWindowInfo(code: "a", createdAt: "2026-10-09T10:00:00Z", alive: true, title: nil, engine: "claude", phase: nil),
            TerminalWindowInfo(code: "b", createdAt: "2026-10-09T09:00:00Z", alive: true, title: nil, engine: "codex", phase: nil),
            TerminalWindowInfo(code: "c", createdAt: "2026-10-09T08:00:00Z", alive: true, title: nil, engine: nil, phase: nil),
        ]
        let agents = [TerminalAgentConversation(session: "mp-codex-1", title: "x", openedAt: TerminalTimestamp.parse("2026-10-09T07:00:00Z")!)]
        let items = TerminalRecents.merge([TerminalRecentSource(hubId: "primary", windows: windows, agents: agents)])
        XCTAssertEqual(items.map(\.engine), [.claude, .codex, .shell, .codex])
        XCTAssertEqual(TerminalEngine.claude.cell, TerminalEngine.codex.cell)
    }

    // MARK: - 一台电脑一行（B4.2b）

    func testHostRowConnectedHasShellAndClaude() {
        let row = TerminalHostRow(hubId: "primary", name: "MacBook", link: .connected, claudeInstalled: true)
        XCTAssertEqual(row.detail, "已接上")
        XCTAssertEqual(row.buttons, [.shell, .claude(enabled: true)])
        // 不知道装没装（老 hub）不拦
        XCTAssertEqual(TerminalHostRow(hubId: "x", name: "x", link: .connected, claudeInstalled: nil).buttons,
                       [.shell, .claude(enabled: true)])
    }

    func testHostRowWithoutClaudeGreysCrab() {
        let row = TerminalHostRow(hubId: "nyc", name: "纽约", link: .connected, claudeInstalled: false)
        XCTAssertEqual(row.buttons, [.shell, .claude(enabled: false)])
    }

    func testHostRowBrokenOnlyReconnects() {
        let row = TerminalHostRow(hubId: "nyc", name: "纽约", link: .broken, claudeInstalled: true)
        XCTAssertEqual(row.detail, "连不上")
        XCTAssertEqual(row.buttons, [.reconnect])
        XCTAssertEqual(TerminalHostRow(hubId: "primary", name: "我的电脑", link: .unplugged, claudeInstalled: nil).buttons, [.pair])
    }

    // MARK: - 断线「N 分钟前还在」/ ＋ 菜单「在哪台」（B4.3）

    func testLastSeenWording() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(TerminalLastSeen.broken(nil, now: now), "连不上")
        XCTAssertEqual(TerminalLastSeen.broken(now.addingTimeInterval(-10), now: now), "连不上 · 刚刚还在")
        XCTAssertEqual(TerminalLastSeen.broken(now.addingTimeInterval(-185), now: now), "连不上 · 3 分钟前还在")
        XCTAssertEqual(TerminalLastSeen.broken(now.addingTimeInterval(-7200), now: now), "连不上 · 2 小时前还在")
        let row = TerminalHostRow(hubId: "nyc", name: "纽约", link: .broken, claudeInstalled: true,
                                  lastSeen: now.addingTimeInterval(-185), now: now)
        XCTAssertEqual(row.detail, "连不上 · 3 分钟前还在")
        // 连着的不写时间
        XCTAssertEqual(TerminalHostRow(hubId: "nyc", name: "纽约", link: .connected, claudeInstalled: true,
                                       lastSeen: now, now: now).detail, "已接上")
    }

    func testHubChoiceRemembersLastPickAndFallsBackToPrimary() throws {
        let suite = "terminal.hubchoice.test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hubs = [CCHubRegistry.primaryId, "nyc"]
        XCTAssertEqual(TerminalHubChoice.resolve(TerminalHubChoice.load(defaults), hubs: hubs), CCHubRegistry.primaryId)
        TerminalHubChoice.save("nyc", defaults)
        XCTAssertEqual(TerminalHubChoice.resolve(TerminalHubChoice.load(defaults), hubs: hubs), "nyc")
        // 那台删了 → 主电脑
        XCTAssertEqual(TerminalHubChoice.resolve(TerminalHubChoice.load(defaults), hubs: [CCHubRegistry.primaryId]), CCHubRegistry.primaryId)
    }

    // MARK: - R4 返工

    /// B7.2 B3：待配对 / 换了机器那行不说「连不上」、不给「重新连接」，给「重新扫码」（跟管理页一致）
    func testHostRowNeedsPairingOffersRescan() {
        let row = TerminalHostRow(hubId: "nyc", name: "纽约", link: .broken, claudeInstalled: true, lastSeen: Date(), status: .needsPairing)
        XCTAssertEqual(row.detail, "要重新配对")
        XCTAssertEqual(row.buttons, [.rescan])
        XCTAssertNil(row.lastSeen, "不按分钟刷「N 分钟前还在」")
        let moved = TerminalHostRow(hubId: "nyc", name: "纽约", link: .broken, claudeInstalled: true, status: .identityChanged)
        XCTAssertEqual(moved.buttons, [.rescan])
    }

    /// b4 #6：删了的那台，固定的 Agent / 当前目标 / 弹窗都要收；首页 / 小电脑（nil）不动
    func testPruneDropsOnlyRemovedHubs() {
        let hubs: Set<String> = ["primary", "nyc"]
        XCTAssertTrue(TerminalHubPrune.isGone("gone", hubs: hubs))
        XCTAssertFalse(TerminalHubPrune.isGone("nyc", hubs: hubs))
        XCTAssertFalse(TerminalHubPrune.isGone(nil, hubs: hubs))
    }

    /// b4 #7：首页真实候选集——第 5 个以后正等你回复的 Agent 对话不能先被截掉
    func testWaitingAgentBeyondFirstFourIsPinnedInRecents() {
        let base = TerminalTimestamp.parse("2026-11-04T10:00:00Z")!
        let conversations = (0..<6).map { i -> Conversation in
            let c = Conversation(id: "c\(i)", title: "对话\(i)", createTime: base, updateTime: base, currentNodeId: "")
            c.ccBridgeSessionName = "mp-cc-\(i)"
            c.lastOpenedAt = base.addingTimeInterval(TimeInterval(-60 * i))
            return c
        }
        let all = TerminalRecents.agents(conversations, hubIds: ["primary"], hubOf: { _ in "primary" })
        XCTAssertEqual(all.count, 6)
        let waiting = [(hubId: "primary", session: "mp-cc-5")]
        let candidates = TerminalRecents.agentCandidates(all, waiting: waiting)
        XCTAssertEqual(candidates.map(\.session), ["mp-cc-0", "mp-cc-1", "mp-cc-2", "mp-cc-3", "mp-cc-5"], "前 4 个照旧 + 后面等你回复的")
        let states = ["mp-cc-5": TerminalStateEntry(target: .session(name: "mp-cc-5"), phase: "waiting")]
        let items = TerminalRecents.merge([TerminalRecentSource(hubId: "primary", agents: candidates, states: states)])
        XCTAssertEqual(items.first?.kind, .agent(session: "mp-cc-5"))
        XCTAssertEqual(items.first?.dot, .waiting)
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(TerminalRecents.missingWaiting(waiting, in: all).isEmpty)
        XCTAssertEqual(TerminalRecents.missingWaiting([(hubId: "nyc", session: "mp-cc-5")], in: all).count, 1, "最近 60 个以外的要定向补")
    }
}
