import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

final class RecallWindowSummaryTests: RecallToolTestCase {
    func testIndependentA3AndDirectoryDoNotExpandA2Bodies() async throws {
        try a3("岚舟从云桥城到星砚的整窗走向")
        try a2([segment("段正文不可提前展开", to: 1), segment("星砚后段正文", from: 1, to: 3)])
        let result = await run(.init(op: .window, conversationId: cid))
        assertPage(result, layer: "A3")
        XCTAssertTrue(result.text.contains("整窗走向"))
        XCTAssertEqual(result.targets.map(\.segment), [1, 2])
        XCTAssertTrue(result.targets.allSatisfy { $0.directoryRevision != nil && $0.lastNodeId != nil })
        XCTAssertFalse(result.text.contains("【经过】段正文不可提前展开"))
    }
    func testMissingA3SaysMissingAndKeepsDirectorySeparate() async throws {
        try a2([segment("星砚的摘要")])
        let result = await run(.init(op: .window, conversationId: cid))
        assertPage(result, layer: "A3")
        XCTAssertTrue(result.text.contains("A3 缺层"))
        XCTAssertEqual(result.targets.map(\.segment), [1])
    }
    func testLongA3ContinuesBeforeAnyDirectoryEntryAndDirectoryAtMostTen() async throws {
        try a3(String(repeating: "岚舟👩🏽‍🚀", count: 2400))
        try a2((0..<12).map { segment("星砚目录\($0)", from: $0, to: $0 + 1) })
        var result = await run(.init(op: .window, conversationId: cid))
        assertPage(result, layer: "A3")
        XCTAssertTrue(result.targets.isEmpty)
        var numbers: [Int] = [], pages = 0
        repeat {
            numbers += result.targets.compactMap(\.segment)
            XCTAssertLessThanOrEqual(result.targets.count, 10)
            pages += 1
            guard let cursor = result.cursor else { break }
            result = await run(.init(op: .window, cursor: cursor))
            assertPage(result, layer: "A3")
        } while pages < 20
        XCTAssertEqual(numbers, Array(1...12))
    }
    func testLegacyLabelsUseSegmentKindsAndOldA3ReaderClassification() async throws {
        var legacy = segment("岚舟累计摘要", to: 1, kind: .legacy)
        legacy.lastNodeId = nil
        try a2([legacy, segment("星砚老收尾", from: 1, to: 3, kind: .closeout)])
        let result = await run(.init(op: .window, conversationId: cid))
        XCTAssertTrue(result.text.contains("改版前的累计摘要"))
        XCTAssertTrue(result.text.contains("老收尾段"))
        XCTAssertEqual(result.targets.map(\.segment), [0, 1])
        try WindowSummaryStore.save(SessionSummary(conversationId: cid, title: "云桥城", compressedCount: 0,
            segments: [segment("岚舟旧窗口抄本", from: 1, to: 3, kind: .rolling)], updatedAt: start), in: root)
        let old = await run(.init(op: .window, conversationId: cid))
        XCTAssertTrue(old.text.contains("旧窗口总结（还没搬）"))
    }
    func testWindowRejectsDeletedConversationEvenWhenSummaryFileRemains() async throws {
        try a3("不可读的旧窗口正文")
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == cid })
        conversation.isTrashed = true
        try context.save()
        let result = await run(.init(op: .window, conversationId: cid))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("不可读的旧窗口正文"))
    }
    func testWindowRefusesSummaryWhoseStoredIdentityOnlySharesThePrefix() async throws {
        try WindowSummaryStore.save(SessionSummary(conversationId: "star-window-0002", title: "星砚",
            compressedCount: 0, segments: [segment("不可读的同前缀窗口正文", kind: .closeout)], updatedAt: start), in: root)
        let result = await run(.init(op: .window, conversationId: cid))
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("不可读的同前缀窗口正文"))
    }
    func testNewAndOldBlocksKeywordSearchAndSourceVersions() async throws {
        var old = segment("旧段正文独有", to: 1)
        old.format = 1
        var part = segment("定下路线", from: 1, to: 3)
        part.format = 2
        part.keywords = ["月灯罗盘"]
        try a2([old, part])
        var overview = segment("从地图转到北门", to: 3, kind: .window)
        overview.format = 2
        overview.keywords = ["白帆码头"]
        func saveWindow() throws {
            try WindowSummaryStore.save(.init(conversationId: cid, title: "云桥城", compressedCount: 3,
                segments: [overview], updatedAt: start, closedThrough: "\(cid)-n2"), in: root)
        }
        try saveWindow()
        let first = await run(.init(op: .window, conversationId: cid))
        assertPage(first, layer: "A3")
        XCTAssertTrue(first.text.contains("【走向】从地图转到北门"))
        XCTAssertTrue(first.text.contains("【关键词】白帆码头"))
        let oldTarget = try XCTUnwrap(first.targets.first { $0.segment == 1 })
        let newTarget = try XCTUnwrap(first.targets.first { $0.segment == 2 })
        let oldRead = await run(.init(op: .segment, target: oldTarget))
        XCTAssertTrue(oldRead.text.contains("【经过】旧段正文独有"))
        let newRead = await run(.init(op: .segment, target: newTarget))
        XCTAssertTrue(newRead.text.contains("【经过】定下路线"))
        XCTAssertTrue(newRead.text.contains("【关键词】月灯罗盘"))
        let search = await run(.init(op: .search, query: "月灯罗盘", scope: "a"))
        assertPage(search, layer: "A2")
        XCTAssertEqual(search.targets.map(\.segment), [2])
        let oldSearch = await run(.init(op: .search, query: "旧段正文独有", scope: "a"))
        assertPage(oldSearch, layer: "A2")
        XCTAssertEqual(oldSearch.targets.map(\.segment), [1])

        overview.keywords = ["银帆码头"]
        try saveWindow()
        let second = await run(.init(op: .window, conversationId: cid))
        XCTAssertNotEqual(first.read?.sourceVersion, second.read?.sourceVersion, "只改A3关键词也使来源更新")
        part.keywords = ["星灯罗盘"]
        try a2([old, part])
        let stale = await run(.init(op: .segment, target: newTarget))
        XCTAssertEqual(stale.read?.status, "stale", "只改A2关键词不能继续使用旧target")
        let current = await run(.init(op: .segment, conversationId: cid, segment: 2))
        XCTAssertNotEqual(newRead.read?.sourceVersion, current.read?.sourceVersion)
        XCTAssertTrue(current.text.contains("【关键词】星灯罗盘"))
        let stillOld = await run(.init(op: .segment, target: oldTarget))
        assertPage(stillOld, layer: "A2")
    }

    func testMixedOldBodyAndNewKeywordsReceiveOnlyDoubleKeywordWeight() throws {
        var old = segment("月灯罗盘", to: 1)
        old.title = "路线"
        old.quotes = ""
        old.format = 1
        var new = segment("改走北门", from: 1, to: 3)
        new.title = "路线"
        new.quotes = ""
        new.format = 2
        new.keywords = ["月灯罗盘"]
        try a2([old, new])
        let candidates = CatalogALineReader.candidates(memoryRoot: root).filter { $0.layer == .a2 }
        let documents = candidates.map { MemoryBM25.document(content: $0.title + "\n" + $0.text, keywords: $0.keywords) }
        let bySegment = Dictionary(uniqueKeysWithValues: zip(candidates, documents).map { ($0.0.segment!, $0.1) })
        for term in MemoryBM25.tokens("月灯罗盘") {
            XCTAssertEqual(bySegment[1]?.filter { $0 == term }.count, 1)
            XCTAssertEqual(bySegment[2]?.filter { $0 == term }.count, 2)
        }
        let result = RecallTool.searchALine(terms: ["月灯罗盘"], memoryRoot: root)
        XCTAssertEqual(result.hits.map(\.segment), [2, 1])
    }
}
