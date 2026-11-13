import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

final class RecallYesterdayTests: RecallToolTestCase {
    func testDateReturnsA4AndShortEventTargetsOriginalWithoutInventingA2() async throws {
        try timeline()
        let result = await run(.init(op: .date, date: "2026-10-31"))
        assertPage(result, layer: "A4")
        XCTAssertTrue(result.text.contains("岚舟的云桥城主调"))
        XCTAssertTrue(result.text.contains("星砚的短窗事件"))
        XCTAssertEqual(result.targets.map(\.layer), ["window", "messages"])
        let original = await run(.init(op: .messages, target: try XCTUnwrap(result.targets.last)))
        XCTAssertTrue(original.text.contains("岚舟准备出发"))
    }
    func testGroupedDateEventKeepsCompleteOriginalRangeInsteadOfFirstSegmentOnly() async throws {
        try a2([segment("岚舟第一段", from: 0, to: 1), segment("星砚第二段", from: 1, to: 3)])
        let item = TimelineDayRecord.Item(kind: .segment, conversationId: cid, window: "云桥城", title: "连续航图段",
            start: start, end: start.addingTimeInterval(120), from: "\(cid)-n0", to: "\(cid)-n2")
        try timeline(items: [item])
        let date = await run(.init(op: .date, date: "2026-10-31"))
        assertPage(date, layer: "A4")
        XCTAssertFalse(date.targets.contains { $0.layer == "segment" })
        let target = try XCTUnwrap(date.targets.first { $0.layer == "messages" })
        let original = await run(.init(op: .messages, target: target))
        XCTAssertFalse(original.isError, original.text)
        for text in ["岚舟在云桥城画地图", "星砚带来了航图", "岚舟准备出发"] {
            XCTAssertTrue(original.text.contains(text), original.text)
        }
    }

    func testDateFallsBackToReadOnlyLegacyDailyAndDoesNotCreateMissingDirectory() async throws {
        let absent = await run(.init(op: .date, date: "2026-10-31"))
        XCTAssertFalse(absent.isError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("daily").path))
        let daily = root.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        let text = FrontmatterCodec.render(meta: [("date", "2026-10-31")], body: "岚舟的旧日记")
        try Data(text.utf8).write(to: daily.appendingPathComponent("2026-10-31.md"))
        let result = await run(.init(op: .date, date: "2026-10-31"))
        assertPage(result, layer: "A4")
        XCTAssertTrue(result.text.contains("旧时间轴"))
        XCTAssertTrue(result.text.contains("岚舟的旧日记"))
    }
    func testDateHidesWholeDayHeadlineWhenAnyWindowIsInvisible() async throws {
        let foreign = TimelineDayRecord.Item(kind: .short, conversationId: "foreign-window", window: "星砚不可见",
            title: "不可见内容", start: start, end: start, from: nil, to: nil)
        let visible = TimelineDayRecord.Item(kind: .short, conversationId: cid, window: "云桥城", title: "岚舟可见事件",
            start: start, end: start, from: "\(cid)-n0", to: "\(cid)-n0")
        try timeline(items: [visible, foreign], headline: "主调不可泄露")
        let result = await run(.init(op: .date, date: "2026-10-31"))
        XCTAssertTrue(result.text.contains("岚舟可见事件"))
        XCTAssertFalse(result.text.contains("主调不可泄露"))
        XCTAssertFalse(result.text.contains("不可见内容"))
    }
    func testDateEventPaginationFinishesDayBeforeMovingAcrossMonth() async throws {
        let items = (0..<13).map { i in
            TimelineDayRecord.Item(kind: .short, conversationId: cid, window: "云桥城", title: "星砚事件\(i)",
                start: start.addingTimeInterval(Double(i)), end: start.addingTimeInterval(Double(i)), from: nil, to: nil)
        }
        try timeline(items: items)
        var result = await run(.init(op: .date, after: "2026-10-31", before: "2026-11-02"))
        var events: [String] = []
        var pages = 0
        repeat {
            assertPage(result, layer: "A4")
            events += result.text.components(separatedBy: "\n").filter { $0.contains("星砚事件") }
            pages += 1
            guard let token = result.cursor else { break }
            let next = try XCTUnwrap(RecallTool.decodeCursor(token))
            if next.day == "2026-11-01" { XCTAssertEqual(events.count, 13) }
            result = await run(.init(op: .date, cursor: token))
        } while pages < 15
        XCTAssertEqual(events.count, 13)
        XCTAssertEqual(Set(events).count, 13)
        XCTAssertTrue(result.text.contains("2026-11-01"))
    }
    func testMemoryDayRangeStartsAtFiveAndAfterAloneReadsOneDay() throws {
        let range = try RecallTool.resolveRange(date: nil, after: "2026-10-31", before: nil).get()
        let boundary = try XCTUnwrap(range.after)
        XCTAssertEqual(Calendar.current.component(.hour, from: boundary), 5)
        XCTAssertFalse(RecallTool.inRange(boundary.addingTimeInterval(-1), after: range.after, beforeExclusive: range.beforeExclusive))
        XCTAssertTrue(RecallTool.inRange(boundary, after: range.after, beforeExclusive: range.beforeExclusive))
        XCTAssertEqual(range.beforeExclusive, Calendar.current.date(byAdding: .day, value: 1, to: boundary))
    }
    func testSearchAStopsAtFirstLayerAndExactOnlySearchesOriginal() async throws {
        try timeline(headline: "云桥城 A4 主调证据")
        try a3("云桥城 A3 不该混入")
        try a2([segment("云桥城 A2 不该混入")])
        let result = await run(.init(op: .search, query: "云桥城", scope: "a"))
        assertPage(result, layer: "A4")
        XCTAssertFalse(result.text.contains("A3 不该混入"))
        XCTAssertFalse(result.text.contains("A2 不该混入"))
        XCTAssertFalse(result.text.contains("岚舟在云桥城画地图"))
        let exact = await run(.init(op: .search, query: "云桥城", scope: "a", exact: true))
        assertPage(exact, layer: "原文")
        XCTAssertTrue(exact.text.contains("岚舟在云桥城画地图"))
        XCTAssertFalse(exact.text.contains("A4 主调证据"))
    }
    func testSearchCStopsAtPageBeforeCardAndUsesVerifiedTargets() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        let card = SeedNoteCard(path: "memory/cc/星砚.md", version: "v1", name: "星砚", layer: "CC", title: "云桥城",
            gist: "云桥城卡片下层证据", mentions: [], aboutUser: false, group: "主题", when: [], model: "fictional",
            madeAt: start, run: .init(path: ".runs/fictional.md"))
        try SeedNoteStore(wiki: wiki).save(card)
        try wiki.save(WikiPage(path: "主题/云桥城", title: "云桥城", now: "云桥城页证据", entries: [card.path + "|v1"]))
        try await readyCatalog()
        let result = await run(.init(op: .search, query: "云桥城", scope: "c"))
        assertPage(result, layer: "wiki页")
        XCTAssertTrue(result.text.contains("云桥城页证据"))
        XCTAssertFalse(result.text.contains("卡片下层证据"))
        XCTAssertEqual(result.targets.first?.page?.path, "主题/云桥城")
    }
    func testIncludeInvalidOnlyExtendsSoftInvalidLegacyArchives() async throws {
        let memory = Memory(content: "云桥城旧档案证据", category: "fact", profileId: pid)
        memory.supersededAt = start
        memory.sourceConversationId = cid
        memory.sourceNodeId = "\(cid)-n0"
        context.insert(memory)
        try context.save()
        let normal = await run(.init(op: .search, query: "云桥城", scope: "c"))
        XCTAssertFalse(normal.text.contains("旧档案证据"))
        let invalid = await run(.init(op: .search, query: "云桥城", scope: "c", includeInvalid: true))
        assertPage(invalid, layer: "L1")
        XCTAssertTrue(invalid.text.contains("已失效"))
        XCTAssertTrue(invalid.text.contains("旧档案证据"))
        XCTAssertTrue(invalid.hitMemoryIds.isEmpty)
        try node("\(cid)-n0").sourceVisibility = "hidden"
        try context.save()
        let hidden = await run(.init(op: .search, query: "云桥城", scope: "c", includeInvalid: true))
        XCTAssertFalse(hidden.text.contains("旧档案证据"))
    }
    func testSearchDefaultExcludesCurrentAndExplicitIDAllowsIt() async {
        let excluded = await run(.init(op: .search, query: "云桥城", scope: "a", exact: true), current: cid)
        XCTAssertFalse(excluded.text.contains("岚舟在云桥城画地图"))
        let explicit = await run(.init(op: .search, conversationId: cid, query: "云桥城", scope: "a", exact: true), current: cid)
        XCTAssertTrue(explicit.text.contains("岚舟在云桥城画地图"))
    }
    func testMasterDisabledKeepsOriginalsButRejectsDerivedNavigation() async throws {
        let memory = Memory(content: "云桥城记忆专属证据", category: "fact", profileId: pid)
        context.insert(memory)
        try context.save()
        let enabled = await run(.init(op: .search, query: "云桥城", scope: "c"))
        XCTAssertEqual(enabled.hitMemoryIds, [memory.id])
        defaults.set(false, forKey: "mem_master")
        let search = await run(.init(op: .search, query: "云桥城", scope: "c"))
        assertPage(search, layer: "原文")
        XCTAssertTrue(search.text.contains("记忆总开关关闭，只搜原文"))
        XCTAssertTrue(search.text.contains("岚舟在云桥城画地图"))
        XCTAssertTrue(search.hitMemoryIds.isEmpty)
        XCTAssertFalse(search.text.contains(memory.content))
        let window = await run(.init(op: .window, conversationId: cid))
        XCTAssertTrue(window.isError)
        defaults.set(true, forKey: "mem_master")
        let restored = await run(.init(op: .search, query: "云桥城", scope: "c"))
        XCTAssertEqual(restored.hitMemoryIds, [memory.id])
    }
    func testSearchAContinuationStaysInChosenLayerAndVisitsEverySourceOnce() async throws {
        try a2((0..<9).map { segment("云桥城证据\($0)", from: $0, to: $0 + 1) })
        var result = await run(.init(op: .search, query: "云桥城", scope: "a"))
        var numbers: [Int] = [], pages = 0
        repeat {
            assertPage(result, layer: "A2")
            XCTAssertLessThanOrEqual(result.targets.count, 5)
            numbers += result.targets.compactMap(\.segment)
            pages += 1
            guard let cursor = result.cursor else { break }
            result = await run(.init(op: .search, cursor: cursor))
        } while pages < 10
        XCTAssertEqual(Set(numbers), Set(1...9))
        XCTAssertEqual(numbers.count, 9)
    }
    func testSearchCCardL0PrecedesL1AndBothHaveReaderTargets() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        let card = SeedNoteCard(path: "memory/cc/星砚.md", version: "v1", name: "星砚", layer: "CC", title: "岚舟",
            gist: "云桥城的卡片证据", mentions: [], aboutUser: false, group: "主题", when: [], model: "fictional",
            madeAt: start, run: .init(path: ".runs/fictional.md"))
        try SeedNoteStore(wiki: wiki).save(card)
        try wiki.save(WikiPage(path: "主题/星砚", title: "星砚", records: ["记录（\(card.path)）"], entries: [card.path + "|v1"]))
        let fragment = Memory(content: "岚舟云桥城碎片证据", category: "fact", profileId: pid)
        fragment.sourceConversationId = cid
        fragment.sourceNodeId = "\(cid)-n0"
        fragment.occurredDay = "2026-10-31"
        context.insert(fragment)
        try context.save()
        try await readyCatalog()
        let l0 = await run(.init(op: .search, query: "岚舟", scope: "c"))
        assertPage(l0, layer: "L1")
        XCTAssertTrue(l0.text.contains("卡 L0 定位"))
        XCTAssertFalse(l0.text.contains(card.gist))
        XCTAssertFalse(l0.text.contains(fragment.content))
        let l1 = await run(.init(op: .search, query: "云桥城", scope: "c"))
        assertPage(l1, layer: "L1")
        XCTAssertTrue(l1.text.contains(card.gist))
        XCTAssertTrue(l1.text.contains(fragment.content))
        let entry = try XCTUnwrap(l1.targets.first { $0.row != nil })
        let read = await run(.init(op: .wiki, layer: "entry", target: entry))
        assertPage(read, layer: "L1")
        XCTAssertTrue(read.text.contains(card.gist))
        try wiki.saveRaw(WikiPage(path: "主题/星砚", title: "星砚", records: []).markdown, path: "主题/星砚")
        let revoked = await run(.init(op: .search, query: "云桥城", scope: "c"))
        XCTAssertFalse(revoked.text.contains(card.gist))
    }

    func testLegacyDailyRejectsTrashedWindowUpdatedAtTwoInCalendarDay() async throws {
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == cid })
        let midnight = Calendar.current.startOfDay(for: start)
        conversation.createTime = midnight
        conversation.updateTime = midnight.addingTimeInterval(2 * 3600)
        conversation.isTrashed = true
        try context.save()
        let daily = root.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        try Data(FrontmatterCodec.render(meta: [("date", "2026-10-31")], body: "岚舟不可读旧日记").utf8)
            .write(to: daily.appendingPathComponent("2026-10-31.md"))
        let result = await run(.init(op: .date, date: "2026-10-31"))
        XCTAssertEqual(result.read?.status, "unavailable")
        XCTAssertTrue(result.text.contains("旧日记来源无法逐窗核验"))
        XCTAssertFalse(result.text.contains("岚舟不可读旧日记"))
    }

    func testLegacyDailySourceIdsMustAllRemainVisibleAndCountsCannotProveSources() async throws {
        let daily = root.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        for sources in ["1", RecallTool.json([cid, "deleted-window"]), RecallTool.json([cid])] {
            try Data(FrontmatterCodec.render(meta: [("date", "2026-10-31"), ("sourceConversations", sources)],
                body: "岚舟旧日记来源证据").utf8).write(to: daily.appendingPathComponent("2026-10-31.md"))
            let result = await run(.init(op: .date, date: "2026-10-31"))
            XCTAssertEqual(result.isError, sources != RecallTool.json([cid]), result.text)
            XCTAssertEqual(result.text.contains("岚舟旧日记来源证据"), sources == RecallTool.json([cid]))
        }
    }

    func testDateExcludesCurrentWindowEvenWhenItsA4Exists() async throws {
        try timeline()
        let excluded = await run(.init(op: .date, date: "2026-10-31"), current: cid)
        XCTAssertFalse(excluded.text.contains("星砚的短窗事件"))
        XCTAssertTrue(excluded.targets.isEmpty)
        let visible = await run(.init(op: .date, date: "2026-10-31"))
        XCTAssertTrue(visible.text.contains("星砚的短窗事件"))
    }

    func testSearchPageDiscardsPrivateSourceOnlyEvidenceAndEmptyTargets() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        try wiki.save(WikiPage(path: "人/星砚", hook: "岚舟记录", title: "星砚",
            records: ["航图私源证据（出处：private_fixture/云桥城.md）", "岚舟公开记录"]))
        try await readyCatalog()
        let result = await run(.init(op: .search, query: "航图", scope: "c"))
        XCTAssertFalse(result.isError, result.text)
        XCTAssertFalse(result.text.contains("航图私源证据"))
        XCTAssertFalse(result.targets.contains { $0.page?.path == "人/星砚" })
    }

    func testRecallALineUsesBM25AndConversationVisibilityBeforePresentation() async throws {
        for id in ["current-window", "trashed-window", "foreign-window"] {
            try seed(id, lines: ["岚舟"], profile: id == "foreign-window" ? "other-floor" : pid)
        }
        let deleted = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == "trashed-window" })
        deleted.isTrashed = true
        try context.save()
        for (id, story) in [(cid, "marble 铜铃航线"), ("current-window", "marble 当前隐藏"),
                            ("trashed-window", "marble 回收隐藏"), ("foreign-window", "marble 别层隐藏"),
                            ("orphan-window", "marble 孤立隐藏")] {
            try SessionSummaryStore.save(.init(conversationId: id, title: "云桥城", compressedCount: 2,
                segments: [segment(story)], updatedAt: start), in: SessionSummaryStore.dir(root: root))
        }
        let result = await run(.init(op: .search, query: "marble separate", scope: "a"), current: "current-window")
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("铜铃航线"), result.text)
        for hidden in ["当前隐藏", "回收隐藏", "别层隐藏", "孤立隐藏"] { XCTAssertFalse(result.text.contains(hidden), result.text) }
        XCTAssertEqual(result.targets.compactMap(\.conversationId), [cid])
        XCTAssertTrue(result.hitMemoryIds.isEmpty)
    }

    var yesterday: Date { RecallTool.parseDay("2026-10-31")! }
    var today: Date { RecallTool.parseDay("2026-11-01")! }

    func testStructuredL1KeepsProfileValidityDatesAndPriority() throws {
        let low = Memory(content: "marble low", category: "fact", profileId: pid)
        low.importance = 1
        low.createdAt = yesterday
        let high = Memory(content: "marble high", category: "fact", profileId: pid, isUserExplicit: true)
        high.importance = 5
        high.createdAt = yesterday
        let invalid = Memory(content: "marble obsolete", category: "fact", profileId: pid)
        invalid.supersededAt = today
        invalid.createdAt = yesterday
        let foreign = Memory(content: "marble foreign", category: "fact", profileId: "other-floor")
        let outside = Memory(content: "marble future", category: "fact", profileId: pid)
        outside.createdAt = today
        [low, high, invalid, foreign, outside].forEach { context.insert($0) }
        try context.save()
        let embedder = RecordingMemoryEmbedder(ready: false)
        let result = RecallTool.searchL1(query: "marble", profileId: pid, includeInvalid: false,
                                         after: yesterday, beforeExclusive: today, context: context, embedder: embedder)
        XCTAssertEqual(result.hits.map(\.id), [high.id, low.id])
        XCTAssertTrue(result.vectorStatus?.contains("不可用") == true)
        let withInvalid = RecallTool.searchL1(query: "marble", profileId: pid, includeInvalid: true,
                                              after: yesterday, beforeExclusive: today, context: context, embedder: embedder)
        XCTAssertEqual(Set(withInvalid.hits.map(\.id)), Set([high.id, low.id, invalid.id]))
        XCTAssertEqual(withInvalid.hits.first { $0.id == invalid.id }?.invalid, true)
        XCTAssertTrue(embedder.embeddedTexts.isEmpty)
    }

    func testRecallL1DropsCommonBigramNoiseBeforePriorityAndFirstFourLimit() async throws {
        let target = Memory(content: "上次说的旅行计划：到云桥城看航图", category: "fact", profileId: pid)
        target.importance = 3
        context.insert(target)
        var noiseIds = Set<UUID>()
        for index in 0..<24 {
            let noise = Memory(content: "上次说的共同闲聊 noise-\(index)", category: "fact", profileId: pid)
            noise.importance = 5
            context.insert(noise)
            noiseIds.insert(noise.id)
        }
        try context.save()
        let result = await run(.init(op: .search, query: "上次说的旅行计划", scope: "c"))
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.hitMemoryIds, [target.id], result.text)
        XCTAssertTrue(result.text.contains(target.content), result.text)
        XCTAssertTrue(Set(result.hitMemoryIds).isDisjoint(with: noiseIds))
        XCTAssertFalse(result.text.contains("noise-"), result.text)
    }

    func testRecallL1ShortNameRequiresWholeNameRatherThanSharedSuffix() async throws {
        let target = Memory(content: "岚舟星砚在云桥城画图", category: "fact", profileId: pid)
        target.importance = 3
        let partial = Memory(content: "星砚在云桥城散步", category: "fact", profileId: pid)
        partial.importance = 5
        context.insert(target)
        context.insert(partial)
        try context.save()
        let result = await run(.init(op: .search, query: "岚舟星砚", scope: "c"))
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.hitMemoryIds, [target.id], result.text)
        XCTAssertTrue(result.text.contains(target.content), result.text)
        XCTAssertFalse(result.text.contains(partial.content), result.text)
    }

    func testIncludeInvalidRejectsNonArchiveAndExactCombinations() async {
        for input in [RecallTool.Input(op: .search, query: "云桥城", scope: "a", includeInvalid: true),
                      .init(op: .search, query: "云桥城", scope: "c", exact: true, includeInvalid: false)] {
            let result = await run(input)
            XCTAssertTrue(result.isError)
            XCTAssertTrue(result.text.contains("include_invalid"))
        }
    }
}
