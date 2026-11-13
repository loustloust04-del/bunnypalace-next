import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

final class RecallNavigationTests: RecallToolTestCase {
    private func conversation(_ id: String) throws -> Conversation {
        try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == id })
    }

    private func tree(_ id: String, story: String, count: Int = 3) throws {
        var part = segment(story, to: count)
        part.lastNodeId = "\(id)-n\(count - 1)"
        let summary = SessionSummary(conversationId: id, title: story, compressedCount: count,
            segments: [part], updatedAt: start)
        try SessionSummaryStore.save(summary, in: SessionSummaryStore.dir(root: root))
        var overview = part
        overview.kind = .closeout
        try WindowSummaryStore.save(SessionSummary(conversationId: id, title: story, compressedCount: count,
            segments: [overview], updatedAt: start, closedThrough: part.lastNodeId), in: root)
    }

    private func event(_ id: String, title: String, from: Int = 0, to: Int = 2,
                       at: Date? = nil) -> TimelineDayRecord.Item {
        .init(kind: .segment, conversationId: id, window: title, title: title,
            start: at ?? start, end: at ?? start.addingTimeInterval(120),
            from: "\(id)-n\(from)", to: "\(id)-n\(to)")
    }

    @discardableResult
    private func descend(_ target: RecallTool.Target, id: String, contains: String,
                         excludes: String? = nil, current: String? = nil) async throws -> RecallTool.Target {
        let window = await run(.init(op: .window, target: target), current: current)
        assertPage(window, layer: "A3")
        let segmentTarget = try XCTUnwrap(window.targets.first { $0.layer == "segment" })
        XCTAssertEqual(segmentTarget.conversationId, id)
        let part = await run(.init(op: .segment, target: segmentTarget), current: current)
        assertPage(part, layer: "A2")
        let originalTarget = try XCTUnwrap(part.targets.first { $0.layer == "messages" })
        XCTAssertEqual(originalTarget.conversationId, id)
        let original = await run(.init(op: .messages, target: originalTarget), current: current)
        assertPage(original, layer: "原文")
        XCTAssertTrue(original.text.contains(contains), original.text)
        if let excludes { XCTAssertFalse(original.text.contains(excludes), original.text) }
        return originalTarget
    }

    private func rejection(_ result: RecallTool.ExecResult, status: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.isError, result.text, file: file, line: line)
        XCTAssertEqual(result.read?.status, status, result.text, file: file, line: line)
        let header = result.text.components(separatedBy: "\n")[0]
        XCTAssertTrue(header.contains("本次 0 条") && header.contains("重新定位"), header, file: file, line: line)
        XCTAssertNil(result.cursor, file: file, line: line)
    }

    private func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func localDate(_ key: String, hour: Int, minute: Int = 0, calendar: Calendar) -> Date {
        let day = MemoryDay.date(ofKey: key, calendar: calendar)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func datePage(_ key: String, calendar: Calendar) async throws -> RecallTool.ExecResult {
        let state = RecallTool.Cursor(profileId: pid, root: RecallTool.revision(root.path),
            input: .init(op: .date, date: key), layer: "A4", timeZone: calendar.timeZone.identifier)
        let container = self.container!
        let root = self.root!
        return try await Task.detached {
            try await RecallTool.readDate(state, source: SwiftDataConversationSource(container: container), root: root)
        }.value
    }

    func testTwoATreesOnSameDayStaySeparateAndParticipationOnlyBlocksDerivedReads() async throws {
        let other = "lantern-window-0002"
        try seed(other, lines: ["林栖在星砚港折纸", "林栖拿出纸鹤", "林栖收好纸鹤"])
        try tree(cid, story: "岚舟航图")
        try tree(other, story: "林栖纸鹤")
        try timeline(items: [event(cid, title: "岚舟航图"), event(other, title: "林栖纸鹤")], headline: "")
        let date = await run(.init(op: .date, date: "2026-10-31"))
        assertPage(date, layer: "A4")
        XCTAssertTrue(date.text.hasPrefix("在 A4 层 · 本次 2 条"))
        let targets = date.targets.filter { $0.layer == "window" }
        XCTAssertEqual(Set(targets.compactMap(\.conversationId)), [cid, other])
        let firstOriginal = try await descend(try XCTUnwrap(targets.first { $0.conversationId == cid }),
            id: cid, contains: "岚舟在云桥城画地图", excludes: "林栖拿出纸鹤")
        try await descend(try XCTUnwrap(targets.first { $0.conversationId == other }),
            id: other, contains: "林栖拿出纸鹤", excludes: "岚舟在云桥城画地图")
        let search = await run(.init(op: .search, query: "航图", scope: "a"))
        assertPage(search, layer: "A4")
        let searchedDate = await run(.init(op: .date, target: try XCTUnwrap(search.targets.first)))
        assertPage(searchedDate, layer: "A4")
        try conversation(cid).memoryEnabled = false
        try context.save()
        let filtered = await run(.init(op: .date, date: "2026-10-31"))
        XCTAssertFalse(filtered.text.contains("岚舟航图"))
        XCTAssertTrue(filtered.text.contains("林栖纸鹤"))
        let excluded = await run(.init(op: .search, query: "岚舟航图", scope: "a"))
        XCTAssertFalse(excluded.targets.contains { $0.conversationId == cid || $0.layer == "date" })
        for input in [RecallTool.Input(op: .window, target: try XCTUnwrap(targets.first { $0.conversationId == cid })),
                      .init(op: .segment, conversationId: cid, segment: 1)] {
            rejection(await run(input), status: "unavailable")
        }
        let stillVisible = await run(.init(op: .messages, target: firstOriginal))
        assertPage(stillVisible, layer: "原文")
        XCTAssertTrue(stillVisible.text.contains("岚舟在云桥城画地图"))
    }

    func testFiveAMBoundaryDateAndHalfOpenSearchNavigateOnlyTheirMemoryDay() async throws {
        let cal = Calendar.current
        let early = localDate("2026-11-01", hour: 4, minute: 59, calendar: cal)
        let late = localDate("2026-11-01", hour: 5, minute: 1, calendar: cal)
        try node("\(cid)-n0").createTime = early
        try node("\(cid)-n1").createTime = late
        try context.save()
        try a2([segment("岚舟前日航图", to: 1), segment("星砚次日航图", from: 1, to: 2)])
        try timeline("2026-10-31", items: [event(cid, title: "岚舟前日航图", to: 0, at: early)], headline: "")
        try timeline("2026-11-01", items: [event(cid, title: "星砚次日航图", from: 1, to: 1, at: late)], headline: "")
        for (key, expected, absent) in [("2026-10-31", "岚舟在云桥城画地图", "星砚带来了航图"),
                                         ("2026-11-01", "星砚带来了航图", "岚舟在云桥城画地图")] {
            let date = await run(.init(op: .date, date: key))
            assertPage(date, layer: "A4")
            let target = try XCTUnwrap(date.targets.first { $0.layer == "segment" })
            let window = await run(.init(op: .window, target: try XCTUnwrap(date.targets.first { $0.layer == "window" })))
            assertPage(window, layer: "A3")
            XCTAssertTrue(window.targets.contains(target))
            let part = await run(.init(op: .segment, target: target))
            assertPage(part, layer: "A2")
            let original = await run(.init(op: .messages, target: try XCTUnwrap(part.targets.first)))
            assertPage(original, layer: "原文")
            XCTAssertTrue(original.text.contains(expected))
            XCTAssertFalse(original.text.contains(absent))
        }
        let range = await run(.init(op: .search, after: "2026-11-01", before: "2026-11-02",
                                    query: "航图", scope: "a", exact: true))
        assertPage(range, layer: "原文")
        XCTAssertEqual(range.targets.compactMap(\.fromNodeId), ["\(cid)-n1"])
        let stop = RecallTool.parseDay("2026-11-02")!
        try node("\(cid)-n2").createTime = stop
        try node("\(cid)-n2").content = "林栖航图止界"
        try context.save()
        let again = await run(.init(op: .search, after: "2026-11-01", before: "2026-11-02",
                                    query: "航图", scope: "a", exact: true))
        XCTAssertFalse(again.text.contains("林栖航图止界"))
        try seed("boundary-window", lines: ["星砚航图起界"])
        try node("boundary-window-n0").createTime = RecallTool.parseDay("2026-11-01")
        try context.save()
        let includedStart = await run(.init(op: .search, after: "2026-11-01", before: "2026-11-02",
                                            query: "航图", scope: "a", exact: true))
        XCTAssertTrue(includedStart.text.contains("星砚航图起界"))
        XCTAssertFalse(includedStart.text.contains("林栖航图止界"))
    }

    func testTimeZoneChangeMakesPreviouslyIssuedDateCursorStale() async throws {
        try tree(cid, story: "岚舟日界航图")
        try timeline()
        let first = await run(.init(op: .date, after: "2026-10-31", before: "2026-11-03"))
        try await descend(try XCTUnwrap(first.targets.first { $0.layer == "window" }),
            id: cid, contains: "岚舟在云桥城画地图")
        var cursor = try XCTUnwrap(RecallTool.decodeCursor(try XCTUnwrap(first.cursor)))
        cursor.timeZone = Calendar.current.timeZone.identifier == "America/Los_Angeles" ? "Asia/Shanghai" : "America/Los_Angeles"
        rejection(await run(.init(op: .date, cursor: RecallTool.encodeCursor(cursor))), status: "stale")
    }

    func testDSTSpringAndAutumnKeepLocalFiveAMAndCalendarDayEnd() async throws {
        let cal = calendar("America/Los_Angeles")
        try tree(cid, story: "星砚的日界航图")
        for (before, after, hours) in [("2026-03-07", "2026-03-08", 23.0), ("2026-10-31", "2026-11-01", 25.0)] {
            let low = RecallTool.parseDay(before, calendar: cal)!
            let high = RecallTool.parseDay(after, calendar: cal)!
            XCTAssertEqual(high.timeIntervalSince(low), hours * 3600)
            let following = MemoryDay.key(RecallTool.parseDay(after, endOfDay: true, calendar: cal)!, calendar: cal)
            for key in [before, after, following] {
                let boundary = RecallTool.parseDay(key, calendar: cal)!
                let end = RecallTool.parseDay(key, endOfDay: true, calendar: cal)!
                XCTAssertEqual(cal.component(.hour, from: boundary), 5)
                XCTAssertEqual(cal.component(.hour, from: end), 5)
                XCTAssertEqual(MemoryDay.key(boundary.addingTimeInterval(-60), calendar: cal),
                    MemoryDay.key(cal.date(byAdding: .day, value: -1, to: boundary)!, calendar: cal))
                try timeline(key, items: [event(cid, title: "星砚日界\(key)", at: boundary)], headline: "")
                let date = try await datePage(key, calendar: cal)
                assertPage(date, layer: "A4")
                try await descend(try XCTUnwrap(date.targets.first { $0.layer == "window" }),
                    id: cid, contains: "岚舟在云桥城画地图")
            }
        }
    }

    func testCrossMonthLegacyFilesReturnOneMemoryDayAndBothOriginals() async throws {
        let cal = Calendar.current
        let late = localDate("2026-10-31", hour: 23, calendar: cal)
        let early = localDate("2026-11-01", hour: 4, minute: 30, calendar: cal)
        try node("\(cid)-n0").createTime = late
        try node("\(cid)-n1").createTime = early
        try context.save()
        try tree(cid, story: "岚舟跨月航图", count: 2)
        for (month, date, text) in [("2026-10", late, "岚舟月末航图"), ("2026-11", early, "星砚月初航图")] {
            try TimelineStore.write([.init(start: date, end: date, conversationId: cid, title: "云桥城",
                text: text, pending: "")], month: month, in: TimelineStore.dir(root: root))
        }
        let date = await run(.init(op: .date, date: "2026-10-31"))
        assertPage(date, layer: "A4")
        XCTAssertTrue(date.text.contains("岚舟月末航图"))
        XCTAssertTrue(date.text.contains("星砚月初航图"))
        XCTAssertNil(date.cursor)
        let target = try await descend(try XCTUnwrap(date.targets.first), id: cid,
            contains: "岚舟在云桥城画地图")
        let original = await run(.init(op: .messages, target: target))
        XCTAssertTrue(original.text.contains("星砚带来了航图"))
        XCTAssertFalse(original.text.contains("岚舟准备出发"))
    }

    func testLegacyDailyWithAndWithoutExplicitSourcesRespectsVisibility() async throws {
        let directory = root.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try tree(cid, story: "星砚旧日航图")
        for sources in [Optional<String>.none, RecallTool.json([cid])] {
            var meta = [("date", "2026-10-31")]
            if let sources { meta.append(("sourceConversations", sources)) }
            try Data(FrontmatterCodec.render(meta: meta, body: "星砚旧日航图").utf8)
                .write(to: directory.appendingPathComponent("2026-10-31.md"))
            let date = await run(.init(op: .date, date: "2026-10-31"))
            assertPage(date, layer: "A4")
            XCTAssertTrue(date.text.contains("旧 daily"))
            let search = await run(.init(op: .search, query: "星砚旧日航图", scope: "a"))
            assertPage(search, layer: "A3")
            try await descend(try XCTUnwrap(search.targets.first), id: cid, contains: "岚舟在云桥城画地图")
            try conversation(cid).memoryEnabled = false
            try context.save()
            rejection(await run(.init(op: .date, date: "2026-10-31")), status: "unavailable")
            try conversation(cid).memoryEnabled = true
            try context.save()
        }
    }

    func testLegacyLabelsMissingLayersAndOldDirectoryTargetNeverReadAnotherSegment() async throws {
        var zero = segment("岚舟累计航图", to: 1, kind: .legacy)
        zero.lastNodeId = nil
        let closeout = segment("星砚老收尾航图", from: 1, to: 3, kind: .closeout)
        try a2([zero, closeout])
        try timeline(items: [event(cid, title: "岚舟旧标签航图")], headline: "")
        let date = await run(.init(op: .date, date: "2026-10-31"))
        let window = await run(.init(op: .window, target: try XCTUnwrap(date.targets.first)))
        assertPage(window, layer: "A3")
        XCTAssertTrue(window.text.contains("A3 缺层"))
        XCTAssertTrue(window.text.contains("改版前的累计摘要"))
        XCTAssertTrue(window.text.contains("老收尾段"))
        let zeroTarget = try XCTUnwrap(window.targets.first { $0.segment == 0 })
        let old = await run(.init(op: .segment, target: zeroTarget))
        assertPage(old, layer: "A2")
        XCTAssertTrue(old.text.contains("原文范围不可精确定位"))
        XCTAssertTrue(old.targets.isEmpty)
        let tail = await run(.init(op: .segment, target: try XCTUnwrap(window.targets.first { $0.segment == 1 })))
        let original = await run(.init(op: .messages, target: try XCTUnwrap(tail.targets.first)))
        assertPage(original, layer: "原文")
        XCTAssertFalse(original.text.contains("岚舟在云桥城画地图"))
        try a2([segment("林栖新目录", to: 3)])
        rejection(await run(.init(op: .segment, target: zeroTarget)), status: "unavailable")
        try FileManager.default.removeItem(at: SessionSummaryStore.dir(root: root))
        var legacyA3 = closeout
        legacyA3.kind = .rolling
        try WindowSummaryStore.save(.init(conversationId: cid, title: "云桥城", compressedCount: 3,
            segments: [legacyA3], updatedAt: start), in: root)
        let oldWindow = await run(.init(op: .window, conversationId: cid))
        assertPage(oldWindow, layer: "A3")
        XCTAssertTrue(oldWindow.text.contains("旧窗口总结（还没搬）"))
        XCTAssertTrue(oldWindow.targets.isEmpty)
        XCTAssertTrue(oldWindow.text.components(separatedBy: "\n")[0].contains("A2 缺层"))
    }

    func testInvisibleTrashedAndForeignWindowsRejectEveryNavigationLayer() async throws {
        try tree(cid, story: "岚舟不可见派生航图")
        try timeline(items: [event(cid, title: "岚舟不可见派生航图")], headline: "")
        let date = await run(.init(op: .date, date: "2026-10-31"))
        let windowTarget = try XCTUnwrap(date.targets.first { $0.layer == "window" })
        let window = await run(.init(op: .window, target: windowTarget))
        let segmentTarget = try XCTUnwrap(window.targets.first)
        let part = await run(.init(op: .segment, target: segmentTarget))
        let originalTarget = try XCTUnwrap(part.targets.first)
        for foreign in [false, true] {
            let conv = try conversation(cid)
            if foreign { conv.profileId = "fictional-foreign" } else { conv.isTrashed = true }
            try context.save()
            for input in [RecallTool.Input(op: .window, target: windowTarget),
                          .init(op: .segment, target: segmentTarget), .init(op: .messages, target: originalTarget)] {
                let rejected = await run(input)
                rejection(rejected, status: "invalidTarget")
                XCTAssertFalse(rejected.text.contains("岚舟不可见派生航图"))
                XCTAssertFalse(rejected.text.contains("岚舟在云桥城画地图"))
            }
            let hiddenDate = await run(.init(op: .date, date: "2026-10-31"))
            XCTAssertTrue(hiddenDate.targets.isEmpty)
            let search = await run(.init(op: .search, query: "航图", scope: "a"))
            XCTAssertTrue(search.targets.isEmpty)
            conv.isTrashed = false
            conv.profileId = pid
            try context.save()
        }
    }

    func testHiddenDeletedAndUnselectedNodesRejectOldRangeWithoutWholeWindowFallback() async throws {
        try tree(cid, story: "岚舟隐藏锚航图")
        let search = await run(.init(op: .search, query: "岚舟隐藏锚航图", scope: "a"))
        let windowTarget = try XCTUnwrap(search.targets.first)
        let originalTarget = try await descend(windowTarget, id: cid, contains: "星砚带来了航图")
        let window = await run(.init(op: .window, target: windowTarget))
        let segmentTarget = try XCTUnwrap(window.targets.first)
        let boundWindowTarget = try RecallTool.decoder.decode(RecallTool.Target.self,
            from: Data(try XCTUnwrap(window.read?.target).utf8))
        try timeline(items: [event(cid, title: "岚舟隐藏锚航图")], headline: "星砚主调")
        for deleted in [false, true] {
            try node("\(cid)-n1").sourceVisibility = deleted ? nil : "hidden"
            try node("\(cid)-n1").isTrashed = deleted
            try context.save()
            rejection(await run(.init(op: .messages, target: originalTarget)), status: "stale")
            rejection(await run(.init(op: .segment, target: segmentTarget)), status: "stale")
            rejection(await run(.init(op: .window, target: boundWindowTarget)), status: "stale")
            let rejected = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n1"))
            rejection(rejected, status: "invalidTarget")
            XCTAssertFalse(rejected.text.contains("岚舟在云桥城画地图"))
            let original = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0"))
            assertPage(original, layer: "原文")
            XCTAssertTrue(original.text.contains("岚舟在云桥城画地图"))
            XCTAssertTrue(original.text.contains("岚舟准备出发"))
            XCTAssertFalse(original.text.contains("星砚带来了航图"))
            let exact = await run(.init(op: .search, query: "星砚带来了航图", scope: "a", exact: true))
            XCTAssertTrue(exact.targets.isEmpty)
            let derived = await run(.init(op: .search, query: "岚舟隐藏锚航图", scope: "a"))
            assertPage(derived, layer: "A4")
            XCTAssertEqual(derived.targets.first?.date, "2026-10-31")
            let date = await run(.init(op: .date, target: try XCTUnwrap(derived.targets.first)))
            assertPage(date, layer: "A4")
            XCTAssertTrue(date.text.contains("星砚主调"))
            XCTAssertTrue(date.targets.contains { $0.conversationId == cid })
            let freshWindow = await run(.init(op: .window, target: windowTarget))
            assertPage(freshWindow, layer: "A3")
            XCTAssertTrue(freshWindow.text.contains("岚舟隐藏锚航图"))
            let freshSegment = await run(.init(op: .segment, conversationId: cid, segment: 1))
            assertPage(freshSegment, layer: "A2")
            XCTAssertTrue(freshSegment.text.contains("岚舟隐藏锚航图"))
        }
        try node("\(cid)-n1").isTrashed = false
        try node("\(cid)-n0").childrenIds.append("alternate-node")
        context.insert(MessageNode(id: "alternate-node", role: "assistant", content: "林栖未选分支航图", contentType: "text",
            createTime: start, parentId: "\(cid)-n0", childrenIds: [], conversationId: cid, profileId: pid))
        try context.save()
        let unselected = await run(.init(op: .messages, conversationId: cid, fromNodeId: "alternate-node"))
        rejection(unselected, status: "invalidTarget")
        XCTAssertFalse(unselected.text.contains("岚舟在云桥城画地图"))
        let searchBranch = await run(.init(op: .search, query: "林栖未选分支航图", scope: "a", exact: true))
        XCTAssertTrue(searchBranch.targets.isEmpty)
        try node("alternate-node").sourceVisibility = "hidden"
        try context.save()
        let stillVisible = await run(.init(op: .search, query: "岚舟隐藏锚航图", scope: "a"))
        assertPage(stillVisible, layer: "A4")
        let visibleDate = await run(.init(op: .date, target: try XCTUnwrap(stillVisible.targets.first)))
        try await descend(try XCTUnwrap(visibleDate.targets.first { $0.layer == "window" }),
                          id: cid, contains: "星砚带来了航图")
    }

    func testStaleSegmentCursorAndTargetAfterRewriteAndMessageWithdrawal() async throws {
        try a2([segment(String(repeating: "岚舟航图", count: 1500))])
        let search = await run(.init(op: .search, query: "岚舟航图", scope: "a"))
        assertPage(search, layer: "A2")
        let target = try XCTUnwrap(search.targets.first)
        let window = await run(.init(op: .window, conversationId: try XCTUnwrap(target.conversationId)))
        assertPage(window, layer: "A3")
        XCTAssertTrue(window.targets.contains(target))
        let first = await run(.init(op: .segment, target: target))
        let cursor = try XCTUnwrap(first.cursor)
        let originalTarget = try XCTUnwrap(first.targets.first)
        try a2([segment("林栖已改版航图")])
        rejection(await run(.init(op: .segment, target: target)), status: "stale")
        rejection(await run(.init(op: .segment, cursor: cursor)), status: "stale")
        try node("\(cid)-n0").content = String(repeating: "星砚原文", count: 1500)
        try context.save()
        let original = await run(.init(op: .messages, target: originalTarget))
        let messageCursor = try XCTUnwrap(original.cursor)
        try node("\(cid)-n0").isTrashed = true
        try context.save()
        rejection(await run(.init(op: .messages, target: originalTarget)), status: "stale")
        rejection(await run(.init(op: .messages, cursor: messageCursor)), status: "stale")
    }

    func testExplicitCurrentWindowCanBeReadWhileDefaultDateAndSearchExcludeIt() async throws {
        try tree(cid, story: "岚舟当前航图")
        try timeline(items: [event(cid, title: "岚舟当前航图")], headline: "")
        let excludedDate = await run(.init(op: .date, date: "2026-10-31"), current: cid)
        assertPage(excludedDate, layer: "A4")
        XCTAssertTrue(excludedDate.targets.isEmpty)
        let excludedSearch = await run(.init(op: .search, query: "岚舟当前航图", scope: "a"), current: cid)
        XCTAssertTrue(excludedSearch.targets.isEmpty)
        let explicit = await run(.init(op: .window, conversationId: cid), current: cid)
        assertPage(explicit, layer: "A3")
        try await descend(.init(tree: "a", layer: "window", conversationId: cid), id: cid,
            contains: "岚舟在云桥城画地图", current: cid)
        let search = await run(.init(op: .search, conversationId: cid, query: "岚舟当前航图", scope: "a"), current: cid)
        assertPage(search, layer: "A4")
        let date = await run(.init(op: .date, target: try XCTUnwrap(search.targets.first)))
        assertPage(date, layer: "A4")
    }

    private func fragmentPage() async throws -> (WikiStore, WikiPage, RecallTool.Target) {
        let memory = Memory(content: "星砚末尾碎片的航图", category: "fact", profileId: pid)
        memory.sourceConversationId = cid
        memory.sourceNodeId = "\(cid)-n2"
        context.insert(memory)
        try context.save()
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        let page = WikiPage(path: "人/星砚", title: "星砚", now: "林栖在云桥城",
            records: ["岚舟的航图（出处：\(CatalogSources.label(memory.id))）"])
        try wiki.save(page)
        let index = await run(.init(op: .wiki, layer: "index", folder: "人"))
        assertPage(index, layer: "wiki索引")
        let read = await run(.init(op: .wiki, target: try XCTUnwrap(index.targets.first)))
        assertPage(read, layer: "wiki页")
        let entry = await run(.init(op: .wiki, target: try XCTUnwrap(read.targets.first)))
        assertPage(entry, layer: "L1")
        return (wiki, page, try XCTUnwrap(entry.targets.first))
    }

    func testWikiTerminalFragmentAppendKeepsL2TargetAndCursorButEditingRangeIsStale() async throws {
        try node("\(cid)-n2").content = String(repeating: "岚舟末尾原文", count: 800)
        try context.save()
        let (_, _, target) = try await fragmentPage()
        let first = await run(.init(op: .wiki, target: target))
        assertPage(first, layer: "L2")
        let token = try XCTUnwrap(first.cursor)
        try node("\(cid)-n2").childrenIds = ["appended"]
        context.insert(MessageNode(id: "appended", role: "assistant", content: "林栖后继消息不在碎片里", contentType: "text",
            createTime: start, parentId: "\(cid)-n2", childrenIds: [], conversationId: cid, profileId: pid))
        try conversation(cid).currentNodeId = "appended"
        try context.save()
        let repeated = await run(.init(op: .wiki, target: target))
        assertPage(repeated, layer: "L2")
        XCTAssertEqual(repeated.text, first.text)
        let next = await run(.init(op: .wiki, cursor: token))
        assertPage(next, layer: "L2")
        XCTAssertFalse(next.text.contains("林栖后继消息不在碎片里"))
        XCTAssertNil(next.cursor)
        try node("\(cid)-n2").content = "星砚范围内改版"
        try context.save()
        rejection(await run(.init(op: .wiki, target: target)), status: "stale")
        rejection(await run(.init(op: .wiki, cursor: token)), status: "stale")
    }

    func testWikiPageRewriteAndDeletionInvalidateOldRowAndCursorWithoutReadingOtherPage() async throws {
        let (wiki, page, original) = try await fragmentPage()
        let l2 = await run(.init(op: .wiki, target: original))
        assertPage(l2, layer: "L2")
        let index = await run(.init(op: .wiki, layer: "index", folder: "人"))
        let pageTarget = try XCTUnwrap(index.targets.first)
        var longPage = page
        longPage.now = String(repeating: "星砚页正文", count: 900)
        try wiki.save(longPage)
        rejection(await run(.init(op: .wiki, target: pageTarget)), status: "stale")
        let freshIndex = await run(.init(op: .wiki, layer: "index", folder: "人"))
        let first = await run(.init(op: .wiki, target: try XCTUnwrap(freshIndex.targets.first)))
        let cursor = try XCTUnwrap(first.cursor)
        longPage.now = "林栖改版后不应续接旧页"
        try wiki.save(longPage)
        rejection(await run(.init(op: .wiki, cursor: cursor)), status: "stale")
        rejection(await run(.init(op: .wiki, target: original)), status: "stale")
        let file = wiki.root.appendingPathComponent(page.path + ".md")
        try FileManager.default.removeItem(at: file)
        let deleted = await run(.init(op: .wiki, target: original))
        rejection(deleted, status: "stale")
        XCTAssertTrue(deleted.text.contains("页已删除，请从索引重新定位"), deleted.text)
        let deletedCursor = await run(.init(op: .wiki, cursor: cursor))
        rejection(deletedCursor, status: "stale")
        XCTAssertTrue(deletedCursor.text.contains("页已删除，请从索引重新定位"), deletedCursor.text)
        XCTAssertFalse(deleted.text.contains("岚舟准备出发"))
    }

    func testWikiForeignPageRowAndOriginalStayUnavailableEvenAfterLocalPageDeletion() async throws {
        let (wiki, page, original) = try await fragmentPage()
        let row = try XCTUnwrap(original.row)
        let targets = [
            RecallTool.Target(tree: "c", layer: "page", page: row.page),
            RecallTool.Target(tree: "c", layer: "entry", row: row),
            original
        ]
        for deleted in [false, true] {
            if deleted { try FileManager.default.removeItem(at: wiki.pageURL(page.path)) }
            for var target in targets {
                target.page?.profileId = "fictional-foreign"
                target.row?.page.profileId = "fictional-foreign"
                let rejected = await run(.init(op: .wiki, target: target))
                rejection(rejected, status: "unavailable")
                XCTAssertFalse(rejected.text.contains("页已删除"))
                XCTAssertFalse(rejected.text.contains("岚舟准备出发"))
            }
        }
    }

    func testWikiTerminalFragmentWithdrawalMakesOldL2TargetAndCursorUnavailable() async throws {
        try node("\(cid)-n2").content = String(repeating: "岚舟末尾原文", count: 800)
        try context.save()
        let (_, _, target) = try await fragmentPage()
        let first = await run(.init(op: .wiki, target: target))
        assertPage(first, layer: "L2")
        let token = try XCTUnwrap(first.cursor)
        try node("\(cid)-n2").isTrashed = true
        try context.save()
        for input in [RecallTool.Input(op: .wiki, target: target), .init(op: .wiki, cursor: token)] {
            let rejected = await run(input)
            rejection(rejected, status: "unavailable")
            XCTAssertFalse(rejected.text.contains("岚舟末尾原文"))
        }
    }

}
