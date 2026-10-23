import XCTest
@testable import 记忆花园

/// ⌘K 全局搜索的纯逻辑：用例照原型 JS（parseSearchQuery / serializeSearch / runSearch / dateLabel）的分支抄。
final class MacGlobalSearchQueryTests: XCTestCase {

    func testLexQuotesAndEscapes() {
        let lexed = MacSearchQuery.lex(#"薄荷 "quiet workspace" a\"b"#)
        XCTAssertEqual(lexed.tokens.map(\.value), ["薄荷", "quiet workspace", #"a"b"#])
        XCTAssertEqual(lexed.tokens.map(\.quoted), [false, true, false])
        XCTAssertTrue(lexed.errors.isEmpty)
        XCTAssertFalse(MacSearchQuery.lex(#""open"#).errors.isEmpty, "未闭合引号要报错")
    }

    func testParseExamples() {
        let a = MacSearchQuery.parse("薄荷 type:memory")
        XCTAssertEqual(a.words, ["薄荷"])
        XCTAssertEqual(a.filters.types, [.memory])
        XCTAssertTrue(a.isValid)

        let b = MacSearchQuery.parse("布局 type:file ext:.md,pdf")
        XCTAssertEqual(b.filters.types, [.file])
        XCTAssertEqual(b.filters.extensions, ["md", "pdf"])

        let c = MacSearchQuery.parse("type:chat by:me within:7d")
        XCTAssertEqual(c.words, [])
        XCTAssertEqual(c.filters.author, .me)
        XCTAssertEqual(c.filters.period, "7d")

        let d = MacSearchQuery.parse("type:记忆,编程 in:project sort:newest is:starred match:body")
        XCTAssertEqual(d.filters.types, [.memory, .coding])
        XCTAssertEqual(d.filters.location, .workspace)
        XCTAssertEqual(d.filters.sort, .recent)
        XCTAssertEqual(d.filters.match, .content)
        XCTAssertTrue(d.filters.starred)
    }

    func testParseErrors() {
        XCTAssertFalse(MacSearchQuery.parse("foo:bar").isValid, "未知 key")
        XCTAssertFalse(MacSearchQuery.parse("type:chat type:file").isValid, "重复 key")
        XCTAssertFalse(MacSearchQuery.parse("type:").isValid, "缺值")
        XCTAssertFalse(MacSearchQuery.parse("type:nope").isValid)
        XCTAssertFalse(MacSearchQuery.parse("within:7d after:2026-01-01").isValid, "within 与 after 互斥")
        XCTAssertFalse(MacSearchQuery.parse("after:2026-02-30").isValid, "无效日期")
        XCTAssertFalse(MacSearchQuery.parse("after:2026-03-02 before:2026-03-01").isValid, "起始晚于结束")
        XCTAssertTrue(MacSearchQuery.parse("https://example.com").isValid, "URL 当关键词")
        XCTAssertEqual(MacSearchQuery.parse("https://example.com").words, ["https://example.com"])
        XCTAssertEqual(MacSearchQuery.parse(#""type:chat""#).words, ["type:chat"], "整段加引号就是关键词")
    }

    func testSerializeRoundTrip() {
        var f = MacSearchFilters()
        f.types = [.chat, .file]
        f.location = .current
        f.author = .assistant
        f.period = "30d"
        f.extensions = ["md"]
        f.starred = true
        f.sort = .za
        let raw = MacSearchQuery.serialize(words: ["a b", "薄荷"], filters: f)
        XCTAssertEqual(raw, #""a b" 薄荷 in:current type:chat,file by:assistant within:30d ext:md is:starred sort:za"#)
        let back = MacSearchQuery.parse(raw)
        XCTAssertEqual(back.words, ["a b", "薄荷"])
        XCTAssertEqual(back.filters, f)
    }

    func testCustomDateRangeSetsPeriod() {
        let p = MacSearchQuery.parse("after:2026-01-01 before:2026-01-31")
        XCTAssertEqual(p.filters.period, "custom")
        let bounds = p.filters.dateBounds()!
        XCTAssertEqual(MacSearchQuery.dayString(bounds.lowerBound), "2026-01-01")
        XCTAssertEqual(MacSearchQuery.dayString(bounds.upperBound), "2026-01-31", "before 含当天")
    }

    func testMatchScoreAndOrder() {
        XCTAssertTrue(MacSearchQuery.matches(title: "薄荷工作台", body: "布局", words: ["薄荷", "布局"], match: .any))
        XCTAssertFalse(MacSearchQuery.matches(title: "薄荷工作台", body: "布局", words: ["薄荷", "布局"], match: .title))
        XCTAssertTrue(MacSearchQuery.matches(title: "x", body: "Quiet Workspace", words: ["quiet"], match: .content))
        XCTAssertEqual(MacSearchQuery.score(title: "薄荷", body: "薄荷 布局", words: ["薄荷", "布局"]), 3 + 2 + 2)

        struct Row { let id: String; let title: String; let updated: Date; let score: Int }
        let old = Date(timeIntervalSince1970: 0), new = Date()
        let rows = [Row(id: "a", title: "乙", updated: new, score: 2), Row(id: "b", title: "甲", updated: old, score: 5)]
        func ids(_ sort: MacSearchFilters.Sort) -> [String] {
            MacSearchQuery.order(rows, sort: sort, hasWords: true, id: \.id, title: \.title, updated: { $0.updated }, score: \.score).map(\.id)
        }
        XCTAssertEqual(ids(.relevance), ["b", "a"])
        XCTAssertEqual(ids(.recent), ["a", "b"])
        XCTAssertEqual(ids(.oldest), ["b", "a"])
        XCTAssertEqual(ids(.az), ["b", "a"], "甲 在 乙 前（zh-CN 排序）")
        XCTAssertEqual(ids(.za), ["a", "b"])
    }

    func testConditionsAndClear() {
        var f = MacSearchFilters()
        f.period = "7d"
        f.author = .me
        XCTAssertEqual(f.activeConditions.map(\.label), ["近 7 天", "角色：你"])
        f.clear(.period)
        XCTAssertEqual(f.period, "all")
        XCTAssertEqual(f.activeConditions.count, 1)
        XCTAssertEqual(f.scopeCaption, "全局 · 全部类型 · 标题 + 内容")
    }

    func testExcerptAndDateLabel() {
        let body = String(repeating: "前", count: 40) + "薄荷" + String(repeating: "后", count: 200)
        let ex = MacSearchQuery.excerpt(body, words: ["薄荷"])
        XCTAssertTrue(ex.hasPrefix("…"))
        XCTAssertTrue(ex.hasSuffix("…"))
        XCTAssertTrue(ex.contains("薄荷"))

        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 15))!
        XCTAssertEqual(MacSearchQuery.dateLabel(now.addingTimeInterval(-60), now: now), "刚刚")
        XCTAssertEqual(MacSearchQuery.dateLabel(now.addingTimeInterval(-3600), now: now), "今天")
        XCTAssertEqual(MacSearchQuery.dateLabel(now.addingTimeInterval(-86400), now: now), "昨天")
        XCTAssertEqual(MacSearchQuery.dateLabel(cal.date(from: DateComponents(year: 2026, month: 6, day: 12))!, now: now), "6月12日")
        XCTAssertEqual(MacSearchQuery.dateLabel(cal.date(from: DateComponents(year: 2025, month: 6, day: 12))!, now: now), "2025/6月12日")
    }
}

/// S2：iOS 搜索框的 Query 映射、自然日口径、相关度打分（纯函数，不开 store）
final class SearchQueryMappingTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    func testQuotedPhraseStaysOneWord() {
        let (state, errors) = SearchQueryMapping.parse(#""quiet workspace" 薄荷"#)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(state.words, ["quiet workspace", "薄荷"])
        XCTAssertFalse(MacSearchQuery.matches(title: "quiet room workspace", body: "", words: ["quiet workspace"], match: .any),
                       "引号短语整段匹配，不拆成两个词")
        XCTAssertEqual(SearchQueryMapping.text(for: state), #""quiet workspace" 薄荷"#)
        XCTAssertEqual(SearchQueryMapping.parse("薄荷布局").state.words, ["薄荷布局"], "中文不自动分词")
    }

    func testMappingErrors() {
        XCTAssertTrue(SearchQueryMapping.parse("a type:note").errors.contains { $0.contains("iOS 暂不支持") })
        XCTAssertTrue(SearchQueryMapping.parse("a type:coding").errors.contains { $0.contains("iOS 暂不支持") })
        XCTAssertTrue(SearchQueryMapping.parse("a in:current").errors.contains { $0.contains("in:current") })
        XCTAssertTrue(SearchQueryMapping.parse("a type:memory ext:md").errors.contains { $0.contains("只在「文件」标签生效") })

        let file = SearchQueryMapping.parse("布局 type:file ext:md,pdf")
        XCTAssertTrue(file.errors.isEmpty)
        XCTAssertEqual(file.state.kinds, [.file])
        XCTAssertEqual(file.state.extensions, ["md", "pdf"])

        let full = SearchQueryMapping.parse("薄荷 type:memory match:title by:ai within:30d sort:oldest is:starred")
        XCTAssertTrue(full.errors.isEmpty)
        XCTAssertEqual(full.state.kinds, [.memory])
        XCTAssertEqual(full.state.scope, .titleOnly)
        XCTAssertEqual(full.state.roles, ["assistant"])
        XCTAssertEqual(full.state.dateRange, .last30Days)
        XCTAssertEqual(full.state.sort, .oldest)
        XCTAssertTrue(full.state.starredOnly)
        XCTAssertEqual(SearchQueryMapping.text(for: full.state), "薄荷 type:memory match:title by:assistant within:30d is:starred sort:oldest")
    }

    func testClearedConditionIsWrittenBack() {
        var state = SearchQueryMapping.parse("薄荷 布局 within:7d by:me").state
        state.dateRange = .all
        XCTAssertEqual(SearchQueryMapping.text(for: state), "薄荷 布局 by:me", "胶囊清掉后框里的条件跟着消失，普通词保留")
    }

    func testNaturalDayRanges() {
        let cal = utc
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 15))!
        let today = cal.startOfDay(for: now)
        let week = DateRange.last7Days.interval(now: now, calendar: cal)!
        XCTAssertEqual(week.start, cal.date(byAdding: .day, value: -6, to: today), "7 天 = 今天零点往回数 6 天")
        XCTAssertEqual(week.end, now)
        XCTAssertEqual(DateRange.today.interval(now: now, calendar: cal)!.start, today)

        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9))!
        let end = cal.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 9))!
        let custom = DateRange.custom(start: start, end: end).interval(now: now, calendar: cal)!
        XCTAssertEqual(MacSearchQuery.dayString(custom.start, calendar: cal), "2026-01-01")
        XCTAssertEqual(custom.start, cal.startOfDay(for: start))
        XCTAssertEqual(MacSearchQuery.dayString(custom.end, calendar: cal), "2026-01-31", "结束日含当天")
        XCTAssertGreaterThan(custom.end, end)

        let odd = SearchQueryMapping.parse("a within:3d", now: now, calendar: cal).state.dateRange
        XCTAssertEqual(odd.interval(now: now, calendar: cal)?.start, cal.date(byAdding: .day, value: -2, to: today),
                       "within 任意天数和 mac dateBounds 同口径")
    }

    func testZeroLiteralDoesNotDivide() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let scores = SearchRelevance.scores([
            SearchRelevance.Signals(literal: 0, updated: now),
            SearchRelevance.Signals(literal: 0, updated: now, starred: true),
        ], now: now)
        XCTAssertTrue(scores.allSatisfy(\.isFinite))
        XCTAssertEqual(scores[0], SearchRelevance.Weight.recency, accuracy: 1e-9, "最高字面分为 0：字面项记 0，只剩新近")
        XCTAssertEqual(scores[1] - scores[0], SearchRelevance.Weight.care * SearchRelevance.Weight.starred, accuracy: 1e-9)
    }

    func testRelevanceOrderIsStable() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let older = now.addingTimeInterval(-86_400 * 10)
        let items: [(String, SearchRelevance.Signals)] = [
            ("a", .init(literal: 3, updated: older)),
            ("b", .init(literal: 3, updated: older)),
            ("c", .init(literal: 5, updated: older)),
            ("d", .init(literal: 3, updated: now)),
        ]
        let ordered = SearchRelevance.order(items, now: now) { $0.1 }.map(\.0)
        XCTAssertEqual(ordered, ["c", "d", "a", "b"], "字面高的在前；同字面新的在前；完全同分保持原顺序")
        XCTAssertEqual(SearchRelevance.order(items, now: now) { $0.1 }.map(\.0), ordered, "重复排序结果一致")
    }
}

/// S3-6：类型选择——「选中的类型」集合和「当前标签」分开
final class SearchKindSelectionTests: XCTestCase {

    func testMultipleTypesAreASelection() {
        let (state, errors) = SearchQueryMapping.parse("a type:chat,memory")
        XCTAssertTrue(errors.isEmpty, "多选不再报「一次只能看一类」")
        XCTAssertEqual(state.kinds, [.conversation, .memory])
    }

    func testNoTypeKeepsRememberedAndAllRestores() {
        XCTAssertNil(SearchQueryMapping.parse("薄荷").state.kinds, "没写 type: = 沿用本机记住的选择")
        XCTAssertEqual(SearchQueryMapping.parse("薄荷 type:all").state.kinds, SearchQueryMapping.allKinds)
        XCTAssertNil(SearchQueryMapping.parse(#""type:chat" 薄荷"#).state.kinds, "加引号的是关键词不是条件")
    }

    func testTypeRoundTripIsStable() {
        var state = SearchQueryMapping.State(words: ["薄荷"])
        state.kinds = [.memory, .conversation, .file]
        let text = SearchQueryMapping.text(for: state)
        XCTAssertEqual(text, "薄荷 type:chat,memory,file", "按固定顺序写")
        XCTAssertEqual(SearchQueryMapping.parse(text).state.kinds, state.kinds)
        XCTAssertEqual(SearchQueryMapping.text(for: SearchQueryMapping.parse(text).state), text, "写出去再读回来一模一样")

        state.kinds = SearchQueryMapping.allKinds
        XCTAssertEqual(SearchQueryMapping.text(for: state), "薄荷", "全选不写 type:")
    }

    func testSelectionCannotBeEmpty() {
        let only: Set<SearchResourceKind> = [.memory]
        let r = SearchQueryMapping.toggle(.memory, selected: only, current: .memory)
        XCTAssertEqual(r.selected, only, "只剩最后一个时点它不响应")
        XCTAssertEqual(r.current, .memory)
        XCTAssertEqual(SearchQueryMapping.kinds(fromStored: []), SearchQueryMapping.allKinds, "存的是空 = 全选")
        XCTAssertEqual(SearchQueryMapping.kinds(fromStored: ["nope"]), SearchQueryMapping.allKinds)
        XCTAssertEqual(SearchQueryMapping.kinds(fromStored: SearchQueryMapping.stored([.file, .memory])), [.file, .memory])
    }

    func testDeselectingCurrentMovesToFirst() {
        let r = SearchQueryMapping.toggle(.conversation, selected: [.conversation, .memory, .file], current: .conversation)
        XCTAssertEqual(r.selected, [.memory, .file])
        XCTAssertEqual(r.current, .memory, "取消当前标签 → 换成集合里排第一的（固定顺序 memory 在 file 前）")
        let other = SearchQueryMapping.toggle(.memory, selected: [.conversation, .memory], current: .conversation)
        XCTAssertEqual(other.current, .conversation, "取消的不是当前就不动")
        XCTAssertEqual(SearchQueryMapping.toggle(.sticker, selected: [.memory], current: .memory).selected, [.memory, .sticker])
    }

    func testNewKindAliases() {
        XCTAssertEqual(MacSearchQuery.parse("a type:聊天").filters.types, [.chat], "「聊天」和「对话」同义")
    }

    func testExtNeedsFileWhenTypeWritten() {
        XCTAssertTrue(SearchQueryMapping.parse("a ext:md").errors.isEmpty, "没写 type: 时 ext: 照收，只对「文件」生效")
        XCTAssertTrue(SearchQueryMapping.parse("a type:file,memory ext:md").errors.isEmpty)
        XCTAssertFalse(SearchQueryMapping.parse("a type:memory ext:md").errors.isEmpty)
    }
}
