#if os(macOS)
import XCTest
@testable import 记忆花园

/// N2「统计」口径：逐条照抄 Wake `db_roundtrip.rs::insights_snapshot_and_streaks`（MP 不索引子代理，那条 sidechain 单元不移植），
/// 加 MP 的脏 created_at 形态（0）；派生与界面纯逻辑单测。全在 tmp。
final class CodingInsightsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-coding-insights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func ts(_ day: Int, _ hour: Int, month: Int = 1) -> Int64 {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: 30))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// 同 Wake 测试的 `meta()`：会话都建于同一毫秒（2023），同一个项目
    private let createdMs: Int64 = {
        let date = Calendar.current.date(from: DateComponents(year: 2023, month: 6, day: 1, hour: 12))!
        return Int64(date.timeIntervalSince1970 * 1000)
    }()

    private func meta(_ key: String, agent: CodingAgent = .claudeCode, model: String? = nil, tokens: Int64? = nil,
                      archived: Bool = false, created: Int64? = nil) -> CodingSessionMeta {
        CodingSessionMeta(key: key, nativeId: key, agent: agent, title: key, projectPath: "/tmp/proj", projectName: "proj",
                          filePath: "/tmp/fixtures/\(key).jsonl", createdAt: created ?? createdMs, updatedAt: createdMs,
                          messageCount: 1, sizeBytes: 1, gitBranch: nil, model: model, tokensUsed: tokens, archived: archived, source: nil)
    }

    private func unit(_ seq: Int, _ role: CodingRole, _ timestamp: Int64?) -> CodingIndexUnit {
        CodingIndexUnit(seq: seq, role: role, timestamp: timestamp, text: "msg \(seq)")
    }

    func testSnapshotAndStreaksMatchWake() throws {
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        // s1（claude-code）：10 / 11 / 12 三连活跃日；含 assistant、无 ts 行
        try index.writeSession(meta("claude-code:i1", model: "claude-opus"), fileMtime: 1, units: [
            unit(0, .user, ts(10, 9)), unit(1, .assistant, ts(10, 9)), unit(2, .user, ts(11, 14)),
            unit(3, .user, ts(11, 14)), unit(4, .user, ts(12, 22)), unit(5, .user, nil),
        ])
        // s2（codex）：1/7 孤立 + 1/11；带 tokens；另有一条 2/5 的「未来」消息（相对 today = 1/13）
        try index.writeSession(meta("codex:i2", agent: .codex, model: "gpt-5-codex", tokens: 500), fileMtime: 1, units: [
            unit(0, .user, ts(7, 9)), unit(1, .user, ts(11, 14)), unit(2, .user, ts(5, 9, month: 2)),
        ])
        // s3：archived，任何统计都不该出现
        try index.writeSession(meta("codex:i3", agent: .codex, archived: true), fileMtime: 1, units: [unit(0, .user, ts(1, 9))])

        let today = CodingDay(year: 2026, month: 1, day: 13)
        let d = try index.insights(today: today)

        XCTAssertEqual(d.asOf, today)
        XCTAssertEqual(d.sessions, 2)
        XCTAssertEqual(d.prompts, 8, "主线 user：s1 五条（含无 ts）+ s2 三条（含未来）")
        XCTAssertEqual(d.tokens, 500)
        XCTAssertEqual(d.projectCount, 1)
        XCTAssertEqual(d.activeDays, 4, "未来日不算活跃天")
        XCTAssertEqual(d.busiestDay, CodingDayCount(day: CodingDay(year: 2026, month: 1, day: 11), count: 3))
        XCTAssertEqual(d.currentStreak, 3)
        XCTAssertEqual(d.longestStreak, 3)
        XCTAssertEqual(d.hourly[9], 2)
        XCTAssertEqual(d.hourly[14], 3)
        XCTAssertEqual(d.hourly[22], 1)
        XCTAssertEqual(d.hourly.reduce(0, +), 6, "无 ts 与未来行不进 hourly")
        // 01-07 周三、01-10 周六、01-11 周日 ×3、01-12 周一（周一起始序）
        XCTAssertEqual(d.weekday, [1, 0, 1, 0, 0, 1, 3])
        XCTAssertEqual(d.monthly[0], 6, "全部落在一月")
        XCTAssertEqual(d.monthly.reduce(0, +), 6)
        XCTAssertEqual(d.agents, [
            CodingUsageTally(name: "claude-code", sessions: 1, prompts: 5, tokens: 0),
            CodingUsageTally(name: "codex", sessions: 1, prompts: 3, tokens: 500),
        ], "榜单 prompts 不看日期：无 ts、未来行也计")
        XCTAssertEqual(d.projects, [CodingUsageTally(name: "proj", sessions: 2, prompts: 8, tokens: 500)])
        XCTAssertEqual(d.models, [
            CodingUsageTally(name: "claude-opus", sessions: 1, prompts: 5, tokens: 0),
            CodingUsageTally(name: "gpt-5-codex", sessions: 1, prompts: 3, tokens: 500),
        ])
        // 会话按创建日分桶，归档不计
        let createdDay = CodingDay(Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000))
        XCTAssertEqual(d.dailySessions, [CodingDayCount(day: createdDay, count: 2)])
        // 趋势：as_of = 1/13（周二）→ 本周从 1/12 起是末列 52；1/7、1/10、1/11 落在 1/5 那周 = 51
        let claude = try XCTUnwrap(d.trendAgents.first)
        XCTAssertEqual(claude.name, "claude-code")
        XCTAssertEqual(claude.total, 4)
        XCTAssertEqual(claude.weekly[51], 3)
        XCTAssertEqual(claude.weekly[52], 1)
        XCTAssertEqual(claude.weekly.count, CodingInsightsData.trendWeeks)
        let codex = d.trendAgents[1]
        XCTAssertEqual(codex.name, "codex")
        XCTAssertEqual(codex.total, 2)
        XCTAssertEqual(codex.weekly[51], 2)
        // 最近 7 天（1/7–1/13）对前 7 天（12/31–1/6）：提问 6 / 0，活跃天 4 / 0；会话建于 2023，两窗都是 0
        let (current, previous) = d.lastWeekPair
        XCTAssertEqual(current, CodingWindowStats(sessions: 0, prompts: 6, activeDays: 4))
        XCTAssertEqual(previous, CodingWindowStats())

        // 脏 created_at：超出 date() 范围的正数（date 回 NULL）与 MP 的 0 形态——都跳过，快照不能失败
        try index.writeSession(meta("codex:i-bad", agent: .codex, created: 9_000_000_000_000_000), fileMtime: 1,
                               units: [unit(0, .user, ts(12, 8))])
        try index.writeSession(meta("codex:i-zero", agent: .codex, created: 0), fileMtime: 1, units: [])
        let d2 = try index.insights(today: today)
        XCTAssertEqual(d2.sessions, d.sessions + 2)
        XCTAssertEqual(d2.dailySessions, [CodingDayCount(day: createdDay, count: 2)], "0 不落 1970 桶")
        XCTAssertEqual(d2.firstTs, createdMs, "first_ts 跳过 0")
    }

    func testEmptyLibrary() throws {
        let d = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite")).insights(today: CodingDay(year: 2026, month: 9, day: 13))
        XCTAssertEqual(d.sessions, 0)
        XCTAssertTrue(d.daily.isEmpty)
        XCTAssertEqual(d.currentStreak, 0)
        XCTAssertEqual(CodingInsightsFormat.subtitle(d), "你的 coding agent 活动")
        XCTAssertEqual(CodingInsightsFormat.subtitle(nil), "你的 coding agent 活动")
    }

    // MARK: - 派生

    func testWeeksAndTrendIndexAreInverse() {
        let tuesday = CodingDay(year: 2026, month: 1, day: 13)
        XCTAssertEqual(tuesday.weekdayFromMonday, 1)
        XCTAssertEqual(tuesday.weekStart, CodingDay(year: 2026, month: 1, day: 12))
        XCTAssertEqual(CodingDay(year: 2026, month: 1, day: 18).weekStart, CodingDay(year: 2026, month: 1, day: 12), "周日归前一个周一")
        let data = CodingInsightsData(asOf: tuesday)
        for week in [0, 17, 51, 52] {
            let monday = data.trendStart.adding(days: week * 7)
            XCTAssertEqual(CodingInsightsData.trendWeekIndex(asOf: tuesday, day: monday), week)
            XCTAssertEqual(CodingInsightsData.trendWeekIndex(asOf: tuesday, day: monday.adding(days: 6)), week)
        }
        XCTAssertNil(CodingInsightsData.trendWeekIndex(asOf: tuesday, day: data.trendStart.adding(days: -1)), "窗外")
        XCTAssertNil(CodingInsightsData.trendWeekIndex(asOf: tuesday, day: tuesday.adding(days: 7)), "未来")
        XCTAssertEqual(CodingDay(year: 2024, month: 3, day: 1).days(since: CodingDay(year: 2024, month: 2, day: 28)), 2, "闰年")
    }

    func testStreakEdges() {
        func days(_ list: [Int]) -> [CodingDayCount] { list.map { CodingDayCount(day: CodingDay(year: 2026, month: 3, day: $0), count: 1) } }
        let today = CodingDay(year: 2026, month: 3, day: 20)
        XCTAssertEqual(CodingInsightsData.streaks(days([17, 18, 19]), today: today).current, 3, "今天没活动从昨天起算")
        XCTAssertEqual(CodingInsightsData.streaks(days([17, 18]), today: today).current, 0, "断一天归零")
        let mixed = CodingInsightsData.streaks(days([1, 2, 3, 4, 10, 19, 20]), today: today)
        XCTAssertEqual(mixed.current, 2)
        XCTAssertEqual(mixed.longest, 4)
        XCTAssertEqual(CodingInsightsData.streaks([], today: today).current, 0)
    }

    func testChangeTextEdges() {
        XCTAssertEqual(CodingInsightsFormat.change(now: 0, before: 0).text, "没有活动")
        XCTAssertEqual(CodingInsightsFormat.change(now: 5, before: 0).text, "本周新增")
        XCTAssertTrue(CodingInsightsFormat.change(now: 5, before: 0).emphasized)
        XCTAssertEqual(CodingInsightsFormat.change(now: 251, before: 250).text, "与上周持平", "+0.4% 四舍五入为 0")
        XCTAssertEqual(CodingInsightsFormat.change(now: 0, before: 4).text, "较上周 -100%")
        XCTAssertFalse(CodingInsightsFormat.change(now: 0, before: 4).emphasized)
        XCTAssertEqual(CodingInsightsFormat.change(now: 112, before: 100).text, "较上周 +12%")
        XCTAssertTrue(CodingInsightsFormat.change(now: 112, before: 100).emphasized)
        XCTAssertEqual(CodingInsightsFormat.change(now: 90, before: 100).text, "较上周 -10%")
    }

    func testHeatLevelsMonthTicksAndFormats() {
        XCTAssertEqual(CodingInsightsFormat.heatLevel(0, peak: 8), 0)
        XCTAssertEqual(CodingInsightsFormat.heatLevel(1, peak: 8), 1)
        XCTAssertEqual(CodingInsightsFormat.heatLevel(2, peak: 8), 1, "正好 25%")
        XCTAssertEqual(CodingInsightsFormat.heatLevel(3, peak: 8), 2)
        XCTAssertEqual(CodingInsightsFormat.heatLevel(8, peak: 8), 4)
        XCTAssertEqual(CodingInsightsFormat.heatLevel(3, peak: 0), 4, "峰值至少 1")

        let start = CodingDay(year: 2025, month: 1, day: 13)   // 周一，月中
        let ticks = CodingInsightsFormat.monthTicks(start: start)
        XCTAssertEqual(ticks.first?.column, 3, "首列与前一周同月不标；2/3 那列标 2 月")
        XCTAssertEqual(ticks.first?.month, 2)
        XCTAssertEqual(ticks.count, 12)

        XCTAssertEqual(CodingInsightsFormat.thousands(1_234_567), "1,234,567")
        XCTAssertEqual(CodingInsightsFormat.thousands(999), "999")
        XCTAssertEqual(CodingInsightsFormat.tokens(0), "")
        XCTAssertEqual(CodingInsightsFormat.tokens(1_500), "1.5K")
        XCTAssertEqual(CodingInsightsFormat.tokens(99_271_606), "99.3M")
        XCTAssertEqual(CodingInsightsFormat.hourLabel(0), "凌晨 12 点")
        XCTAssertEqual(CodingInsightsFormat.hourLabel(9), "上午 9 点")
        XCTAssertEqual(CodingInsightsFormat.hourLabel(12), "中午 12 点")
        XCTAssertEqual(CodingInsightsFormat.hourLabel(14), "下午 2 点")
        XCTAssertEqual(CodingInsightsFormat.promptsLabel(0), "没有提问")
        XCTAssertEqual(CodingInsightsFormat.promptsLabel(1_200), "1,200 次提问")
    }

    // MARK: - 榜单与趋势层

    func testLeaderboardRankingAndMetricCycle() {
        let rows = [
            CodingUsageTally(name: "a", sessions: 5, prompts: 1, tokens: 0),
            CodingUsageTally(name: "b", sessions: 3, prompts: 9, tokens: 700),
            CodingUsageTally(name: "c", sessions: 3, prompts: 2, tokens: 100),
        ]
        XCTAssertEqual(CodingInsightsMetric.available(for: rows), [.sessions, .tokens, .prompts])
        XCTAssertEqual(CodingInsightsMetric.ranked(rows, by: .sessions, limit: nil).map(\.name), ["a", "b", "c"], "平局保持基线序")
        XCTAssertEqual(CodingInsightsMetric.ranked(rows, by: .prompts, limit: 1).map(\.name), ["b"], "先排序后截断")
        XCTAssertEqual(CodingInsightsMetric.ranked(rows, by: .tokens, limit: nil).map(\.name), ["b", "c"], "Token 档只列报过的")
        let noTokens = rows.map { CodingUsageTally(name: $0.name, sessions: $0.sessions, prompts: $0.prompts, tokens: 0) }
        let available = CodingInsightsMetric.available(for: noTokens)
        XCTAssertEqual(available, [.sessions, .prompts])
        XCTAssertEqual(CodingInsightsMetric.resolved(.tokens, in: available), .sessions, "存档位失效落回首档")
        XCTAssertEqual(CodingInsightsMetric.resolved(.prompts, in: available), .prompts)
        XCTAssertEqual(CodingInsightsMetric.tokens.display(rows[1]), "700")
    }

    func testTrendLayersAndLeader() {
        func series(_ name: String, last: Int64, previous: Int64 = 0) -> CodingTrendSeries {
            var weekly = [Int64](repeating: 1, count: CodingInsightsData.trendWeeks)
            weekly[51] = previous
            weekly[52] = last
            return CodingTrendSeries(name: name, weekly: weekly)
        }
        let six = ["claude-code", "codex", "kimi", "x1", "x2", "x3"].map { series($0, last: 0) }
        let layers = CodingInsightsFormat.trendLayers(six)
        XCTAssertEqual(layers.count, 6)
        XCTAssertEqual(layers.last?.name, "其他")
        XCTAssertEqual(layers.last?.weekly[0], 1)
        XCTAssertEqual(layers.first?.name, "Claude Code")
        XCTAssertNil(CodingInsightsFormat.trendLeader(layers), "两周都为零没有领先者")
        XCTAssertEqual(CodingInsightsFormat.trendCaption(layers), "各 agent 每周提问数")

        let lastWeekOnly = CodingInsightsFormat.trendLayers([series("claude-code", last: 0, previous: 2), series("codex", last: 0, previous: 5)])
        XCTAssertEqual(CodingInsightsFormat.trendLeader(lastWeekOnly), "Codex", "本周为零退回上周")
        let thisWeek = CodingInsightsFormat.trendLayers([series("claude-code", last: 4), series("codex", last: 1, previous: 9)])
        XCTAssertEqual(CodingInsightsFormat.trendCaption(thisWeek), "各 agent 每周提问数 · 本周 Claude Code 领先")
    }
}
#endif
