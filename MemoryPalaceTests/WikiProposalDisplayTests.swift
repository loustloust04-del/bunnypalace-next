import MemoryCore
import XCTest
@testable import 记忆花园

/// 审计台第四格「整理提案」的显示规则（plan-memory-c3-catalog 第五节 / todo 10）：卡片摘要、来源中文名、按页分组、
/// 条目状态 → 能不能动、「改」的草稿、「它搜了什么」取哪几行日志
final class WikiProposalDisplayTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func page(_ path: String) -> WikiPage {
        WikiPage(path: path, kind: .person, triggers: ["小慧"], hook: "提到她时", title: String(path.split(separator: "/").last!),
                 now: "室友（自 2026-09 起）", records: ["2026-10-01 认识"])
    }

    private func item(_ change: WikiProposal.Change, _ state: WikiProposal.Item.State = .pending) -> WikiProposal.Item {
        WikiProposal.Item(state: state, change: change, baseVersion: nil)
    }

    private let link = WikiPage.Link(target: "地点/五楼", relation: .supplement, why: "一起住过")

    // MARK: - 来源

    func testOriginLabels() {
        XCTAssertEqual(WikiProposal.Origin.scheduled.label, "定时整理")
        XCTAssertEqual(WikiProposal.Origin.manual.label, "现在整理")
        XCTAssertEqual(WikiProposal.Origin.topic.label, "整理主题")
        XCTAssertEqual(WikiProposal.Origin.seed.label, "种子")
        XCTAssertEqual(WikiProposal.Origin.assistant.label, "助手")
        XCTAssertEqual(WikiProposalDisplay.originLabel(.assistant, assistantName: "阿雾"), "阿雾", "助手交的显示楼层助手名")
        XCTAssertEqual(WikiProposalDisplay.originLabel(.assistant, assistantName: ""), "助手")
        XCTAssertEqual(WikiProposalDisplay.originLabel(.scheduled, assistantName: "阿雾"), "定时整理")
    }

    func testOldCitesDecodeWithoutInventingOriginalNode() throws {
        for json in [
            #"{"layer":"A2","day":"2026-10-12","windowId":"old-window","segment":3,"messageFrom":4,"messageTo":9}"#,
            #"{"layer":"A4","day":"2026-10-12","windowId":"old-window"}"#,
            #"{"layer":"CC","filePath":"memory/cc/user.md"}"#,
        ] {
            let cite = try JSONDecoder().decode(WikiProposal.Cite.self, from: Data(json.utf8))
            XCTAssertNil(cite.profileId)
            XCTAssertNil(cite.nodeId)
            XCTAssertNil(cite.role)
            XCTAssertNil(cite.created)
            XCTAssertNil(cite.onMain)
            XCTAssertNil(WikiProposalDisplay.messageTarget(for: cite, currentProfileId: "floor"))
            XCTAssertEqual(try JSONDecoder().decode(WikiProposal.Cite.self, from: JSONEncoder().encode(cite)), cite)
        }
    }

    func testOriginalCitationLabelsKeepAssistantAttribution() {
        let assistant = WikiProposal.Cite(layer: "原文", windowId: "conversation", profileId: "floor",
                                          nodeId: "assistant-message", role: "assistant", onMain: false)
        let text = WikiProposalDisplay.citeText(assistant, titles: ["conversation": "云桥城"])
        XCTAssertTrue(text.contains("助手发言"))
        XCTAssertTrue(text.contains("非用户事实"))
        XCTAssertTrue(text.contains("支线"))
        XCTAssertTrue(text.contains("assistant-message"))
        var user = assistant
        user.role = "user"
        let userText = WikiProposalDisplay.citeText(user, titles: ["conversation": "云桥城"])
        XCTAssertTrue(userText.contains("用户发言"))
        XCTAssertFalse(userText.contains("助手发言"))
        var unknown = assistant
        unknown.role = nil
        XCTAssertTrue(WikiProposalDisplay.citeText(unknown, titles: [:]).contains("发言者未知"))
    }

    func testReviewOriginalJumpTargetRetainsConversationAndNode() throws {
        let cite = WikiProposal.Cite(layer: "原文", windowId: "conversation", profileId: "floor",
                                    nodeId: "branch-message", role: "assistant", onMain: false)
        let target = try XCTUnwrap(WikiProposalDisplay.messageTarget(for: cite, currentProfileId: "floor"))
        XCTAssertEqual(target.profileId, "floor")
        XCTAssertEqual(target.conversationId, "conversation")
        XCTAssertEqual(target.nodeId, "branch-message", "审核按钮与导航共用这个目标，支线也按指定消息定位")
        XCTAssertNil(WikiProposalDisplay.messageTarget(for: cite, currentProfileId: "other-floor"))
        var missingNode = cite
        missingNode.nodeId = nil
        XCTAssertNil(WikiProposalDisplay.messageTarget(for: missingNode, currentProfileId: "floor"))
        var missingConversation = cite
        missingConversation.windowId = nil
        XCTAssertNil(WikiProposalDisplay.messageTarget(for: missingConversation, currentProfileId: "floor"))
    }

    // MARK: - 卡片摘要

    func testSummaryCountsEachKind() {
        let p = WikiProposal(origin: .scheduled, createdAt: date(10, 18, 5, 2), items: [
            item(.newPage(page: page("人/小慧"))),
            item(.newPage(page: page("人/阿青"))),
            item(.appendRecords(path: "人/阿青", lines: ["a", "b", "c", "d"])),
            item(.appendRecords(path: "人/小慧", lines: Array(repeating: "x", count: 5))),
            item(.rewriteNow(path: "人/小慧", old: "旧", new: "新")),
            item(.link(from: "人/小慧", link: link)),
            item(.link(from: "人/阿青", link: link)),
            item(.link(from: "人/阿青", link: link)),
        ])
        XCTAssertEqual(WikiProposalDisplay.summary(p, timeZone: utc), "10-18 05:02 定时整理 · 新开 2 页 · 追加 9 行 · 改现在 1 处 · 连线 3 条")
    }

    func testSummaryTopicTitleRetagRegroupAndEmpty() {
        let p = WikiProposal(origin: .topic, createdAt: date(10, 3, 23, 9), title: "电影", items: [
            item(.retag(path: "主题/电影", oldHook: "a", newHook: "b", oldTriggers: [], newTriggers: ["电影"])),
            item(.regroup(layer: "主题", groups: [], moves: [])),
        ])
        XCTAssertEqual(WikiProposalDisplay.summary(p, timeZone: utc), "10-03 23:09 整理主题「电影」 · 改钩子 1 处 · 分组调整 1 处")
        let empty = WikiProposal(origin: .assistant, createdAt: date(1, 2, 3, 4), items: [])
        XCTAssertEqual(WikiProposalDisplay.summary(empty, assistantName: "阿雾", timeZone: utc), "01-02 03:04 阿雾 · 没有条目")
    }

    func testStatusText() {
        var p = WikiProposal(origin: .manual, createdAt: date(10, 1, 0, 0), items: [
            item(.rewriteNow(path: "人/a", old: "", new: "x")),
            item(.rewriteNow(path: "人/b", old: "", new: "y")),
            item(.rewriteNow(path: "人/c", old: "", new: "z")),
        ])
        XCTAssertEqual(WikiProposalDisplay.statusText(p), "待批 3")
        p.items[0].state = .approved
        p.items[1].state = .stale
        XCTAssertEqual(WikiProposalDisplay.statusText(p), "待批 1")
        p.items[2].state = .rejected
        XCTAssertEqual(WikiProposalDisplay.statusText(p), "已处理", "页已变的不算待批")
    }

    // MARK: - 按页分组

    func testGroupsByTargetPageInFirstSeenOrderRegroupLast() {
        let p = WikiProposal(origin: .scheduled, createdAt: date(10, 1, 0, 0), items: [
            item(.appendRecords(path: "人/阿青", lines: ["1"])),
            item(.regroup(layer: "主题", groups: [], moves: [])),
            item(.newPage(page: page("人/小慧"))),
            item(.link(from: "人/阿青", link: link)),
            item(.rewriteNow(path: "人/小慧", old: "", new: "n")),
        ])
        let groups = WikiProposalDisplay.groups(p)
        XCTAssertEqual(groups.map(\.path), ["人/阿青", "人/小慧", nil])
        XCTAssertEqual(groups.map(\.title), ["阿青", "小慧", "分组调整"])
        XCTAssertEqual(groups.map { $0.items.map(\.id) }, [[p.items[0].id, p.items[3].id], [p.items[2].id, p.items[4].id], [p.items[1].id]])
    }

    // MARK: - 条目状态

    func testItemStatusMapping() {
        let change = WikiProposal.Change.rewriteNow(path: "人/a", old: "", new: "x")
        XCTAssertEqual(WikiProposalDisplay.status(item(change, .pending)), .actionable)
        XCTAssertEqual(WikiProposalDisplay.status(item(change, .stale)), .stale)
        XCTAssertEqual(WikiProposalDisplay.status(item(change, .approved)), .legacyApproved)
        XCTAssertEqual(WikiProposalDisplay.status(item(change, .rejected)), .rejected)
        XCTAssertTrue(WikiProposalDisplay.ItemStatus.actionable.canAct)
        for s in [WikiProposalDisplay.ItemStatus.stale, .approved, .legacyApproved, .withdrawable, .unsettled([]), .rejected] {
            XCTAssertFalse(s.canAct)
        }
        XCTAssertNil(WikiProposalDisplay.ItemStatus.actionable.label)
        XCTAssertEqual(WikiProposalDisplay.ItemStatus.stale.label, "页在这之后被改过，重新整理")
        XCTAssertEqual(WikiProposalDisplay.ItemStatus.approved.label, "已批")
        XCTAssertEqual(WikiProposalDisplay.ItemStatus.rejected.label, "已驳回")
        XCTAssertEqual(WikiProposal.Judgment.conflict.label, "冲突")
        XCTAssertEqual(WikiProposal.Judgment.coexist.label, "共存")
    }

    // MARK: - 「改」的草稿

    func testDraftEditsNewPageTextOnly() {
        let change = WikiProposal.Change.newPage(page: page("人/小慧"))
        var d = WikiProposalDraft(change)
        XCTAssertEqual(d.triggers, "小慧")
        XCTAssertEqual(d.records.map(\.body), ["2026-10-01 认识"])
        d.now = "  搬去七楼（自 2026-10-12 起）\n"
        d.records.append(.init(line: "  2026-10-12 搬家 "))
        d.hook = "提到室友时"
        d.triggers = "小慧, 慧慧、阿慧"
        guard case .newPage(let out) = d.apply(to: change) else { return XCTFail() }
        XCTAssertEqual(out.path, "人/小慧")
        XCTAssertEqual(out.kind, .person)
        XCTAssertEqual(out.now, "搬去七楼（自 2026-10-12 起）")
        XCTAssertEqual(out.records, ["2026-10-01 认识", "2026-10-12 搬家"], "空行扔掉、两头空白去掉")
        XCTAssertEqual(out.hook, "提到室友时")
        XCTAssertEqual(out.triggers, ["小慧", "慧慧", "阿慧"])
    }

    func testDraftRecordFoldsNewlinesWithoutChangingSourceSuffix() {
        let change = WikiProposal.Change.appendRecords(path: "主题/虚构纸舟", lines: ["虚构原稿（出处：碎片 11111111）"])
        var draft = WikiProposalDraft(change)
        draft.records[0].body = "虚构第一段\n虚构第二段"
        XCTAssertEqual(draft.apply(to: change), .appendRecords(path: "主题/虚构纸舟",
            lines: ["虚构第一段 虚构第二段（出处：碎片 11111111）"]))
    }

    func testBlankDraftTitleFallsBackToOriginalTitleThenPath() {
        var original = page("人/小慧")
        original.title = "虚构显示名"
        var draft = WikiProposalDraft(.newPage(page: original))
        draft.title = " \n "
        guard case .newPage(let kept) = draft.apply(to: .newPage(page: original)) else { return XCTFail() }
        XCTAssertEqual(kept.title, "虚构显示名")
        original.title = " \n "
        guard case .newPage(let fallback) = draft.apply(to: .newPage(page: original)) else { return XCTFail() }
        XCTAssertEqual(fallback.title, "小慧")
    }

    func testDraftEditsOtherKindsKeepPathAndOld() {
        var d = WikiProposalDraft(.appendRecords(path: "人/a", lines: ["x"]))
        d.records.append(.init(line: "y"))
        XCTAssertEqual(d.apply(to: .appendRecords(path: "人/a", lines: ["x"])), .appendRecords(path: "人/a", lines: ["x", "y"]))

        let now = WikiProposal.Change.rewriteNow(path: "人/a", old: "旧", new: "新")
        d = WikiProposalDraft(now)
        XCTAssertEqual(d.now, "新")
        d.now = "更新"
        XCTAssertEqual(d.apply(to: now), .rewriteNow(path: "人/a", old: "旧", new: "更新"))

        let l = WikiProposal.Change.link(from: "人/a", link: link)
        d = WikiProposalDraft(l)
        d.why = "邻居"
        XCTAssertEqual(d.apply(to: l), .link(from: "人/a", link: .init(target: "地点/五楼", relation: .supplement, why: "邻居")))

        let retag = WikiProposal.Change.retag(path: "人/a", oldHook: "h0", newHook: "h1", oldTriggers: ["a"], newTriggers: ["b"])
        d = WikiProposalDraft(retag)
        XCTAssertEqual(d.hook, "h1")
        d.hook = "h2"
        d.triggers = "b，c"
        XCTAssertEqual(d.apply(to: retag), .retag(path: "人/a", oldHook: "h0", newHook: "h2", oldTriggers: ["a"], newTriggers: ["b", "c"]))
    }

    func testDraftRenamesGroupAndItsMoveTargets() {
        let change = WikiProposal.Change.regroup(layer: "人", groups: [.init(path: "人/朋友", hook: "朋友们"), .init(path: "人/家人", hook: "家里")],
                                                 moves: [.init(from: "人/小慧", to: "人/朋友/小慧"),
                                                         .init(from: "人/妈妈", to: "人/家人/妈妈"),
                                                         .init(from: "人/朋友圈", to: "人/朋友圈2")])
        var d = WikiProposalDraft(change)
        XCTAssertEqual(d.groups.map(\.name), ["朋友", "家人"])
        d.groups[0].name = "老朋友"
        d.groups[0].hook = "认识很久的"
        d.groups[1].name = ".藏"
        guard case .regroup(let layer, let groups, let moves) = d.apply(to: change) else { return XCTFail() }
        XCTAssertEqual(layer, "人")
        XCTAssertEqual(groups, [.init(path: "人/老朋友", hook: "认识很久的"), .init(path: "人/家人", hook: "家里")], "不合法的名字那组照旧")
        XCTAssertEqual(moves.map(\.to), ["人/老朋友/小慧", "人/家人/妈妈", "人/朋友圈2"], "只改挪进改名那组下面的，前缀相似的不动")
    }

    // MARK: - 它搜了什么

    func testSearchLogPicksThisTopicsRoundsInWindow() {
        let t = date(10, 18, 10, 0)
        let p = WikiProposal(origin: .topic, createdAt: t, title: "电影", items: [])
        let later = WikiProposal(origin: .manual, createdAt: t.addingTimeInterval(3600), title: "电影", items: [])
        let other = WikiProposal(origin: .manual, createdAt: t.addingTimeInterval(600), title: "猫", items: [])
        func e(_ dt: TimeInterval, _ note: String, writer: String = "C3") -> MemoryWriteLog.Entry {
            MemoryWriteLog.Entry(time: t.addingTimeInterval(dt), writer: writer, ok: true, note: note, model: "m")
        }
        let entries = [
            e(120, "整理「电影」第 2 轮：read_aline 0001aaaa 第 3 段 300 字、read_wiki 事/电影 80 字"),
            e(60, "整理「电影」第 1 轮：search_aline「电影」「星际穿越」 1200 字"),
            e(-60, "整理「电影」第 1 轮：更早那次"),
            e(90, "整理「猫」第 1 轮：search_aline 10 字"),
            e(100, "「电影」2 轮 · 查回 1500 字 · 交了 3 条"),
            e(110, "整理「电影」第 1 轮：别的写手", writer: "C2"),
            e(3700, "整理「电影」第 1 轮：下一份的"),
        ]
        XCTAssertEqual(WikiProposalDisplay.searchLog(entries, for: p, all: [p, later, other]).map(\.note),
                       ["整理「电影」第 1 轮：search_aline「电影」「星际穿越」 1200 字",
                        "整理「电影」第 2 轮：read_aline 0001aaaa 第 3 段 300 字、read_wiki 事/电影 80 字"], "日志带搜索词 / 路径（astra 跟进 F13）")
        let scheduled = WikiProposal(origin: .scheduled, createdAt: t, title: "电影", items: [])
        XCTAssertTrue(WikiProposalDisplay.searchLog(entries, for: scheduled, all: [scheduled]).isEmpty, "定时那份没有 agent")
        let untitled = WikiProposal(origin: .manual, createdAt: t, items: [])
        XCTAssertTrue(WikiProposalDisplay.searchLog(entries, for: untitled, all: [untitled]).isEmpty)
    }

    /// 走查 P2：批正文（不是方向）不再空跑一次方向执行；正文批完，目录那条跟着显示结果
    func testOnlyApprovedUnranDirectionsRunAndContentDecisionShowsOnOutline() {
        let t = Date(timeIntervalSince1970: 1_000)
        var ran = WikiProposal.Direction(path: "主题/甲", title: "甲", action: .newPage, reason: "测试", mode: .daily)
        ran.ranAt = t
        let fresh = WikiProposal.Direction(path: "主题/乙", title: "乙", action: .newPage, reason: "测试", mode: .daily)
        var items: [WikiProposal.Item] = [
            .init(change: .direction(fresh)),
            .init(change: .direction(ran)),
            .init(change: .newPage(page: WikiPage(path: "主题/丙", title: "丙"))),
            .init(change: .direction(fresh)),
        ]
        for i in 0..<3 { items[i].state = .approved }
        let mixed = WikiProposal(origin: .manual, createdAt: t, items: items)
        XCTAssertEqual(WikiProposalDisplay.unranDirections(mixed), [items[0].id], "只有批了、没执行的方向；正文条目和待批的不算")
        let content = WikiProposal(origin: .seed, createdAt: t, items: [items[2]])
        XCTAssertTrue(WikiProposalDisplay.unranDirections(content).isEmpty, "批正文提案不触发方向执行")

        var page = WikiProposal(origin: .seed, createdAt: t, items: [
            .init(change: .newPage(page: WikiPage(path: "主题/丁", title: "丁"))),
            .init(change: .rewriteNow(path: "主题/丁", old: "", new: "现在")),
        ])
        XCTAssertNil(WikiProposalDisplay.contentStatus(page), "还有待批：照旧显示「交了 N 条正文等批」")
        page.items[0].state = .approved
        XCTAssertNil(WikiProposalDisplay.contentStatus(page))
        page.items[1].state = .rejected
        XCTAssertEqual(WikiProposalDisplay.contentStatus(page), "正文批了 1 条、驳回 1 条")
        page.items[1].state = .approved
        XCTAssertEqual(WikiProposalDisplay.contentStatus(page), "正文批了 2 条")
        page.items[1].state = .stale
        XCTAssertEqual(WikiProposalDisplay.contentStatus(page), "正文批了 1 条、失效 1 条", "外部改过失效的那条不能消失")
        page.items[0].state = .stale
        XCTAssertEqual(WikiProposalDisplay.contentStatus(page), "正文失效 2 条", "全失效不说「批了 0 条」")
        XCTAssertEqual(WikiProposalDisplay.contentStatus(nil), "正文提案读不到了（已删除或文件坏了）", "读不到不退回「等批」")
    }
}
