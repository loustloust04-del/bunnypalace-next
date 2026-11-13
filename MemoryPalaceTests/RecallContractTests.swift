import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
class RecallToolTestCase: XCTestCase {
    var pid: String!
    var root: URL!
    var container: ModelContainer!
    var context: ModelContext!
    var defaults: UserDefaults!
    var suite: String!
    let cid = "star-window-0001"
    var start: Date { RecallTool.parseDay("2026-10-31")!.addingTimeInterval(3600) }

    override func setUpWithError() throws {
        pid = "fictional-recall-\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(pid)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = pid
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "mem_master")
        container = try ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        context = ModelContext(container)
        try seed(cid, lines: ["岚舟在云桥城画地图", "星砚带来了航图", "岚舟准备出发"])
    }
    override func tearDown() async throws {
        CatalogRecallIndexer.shared.deleteProfile(pid, wiki: WikiStore(root: root.appendingPathComponent("wiki")))
        try? await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
        defaults.removePersistentDomain(forName: suite)
        context = nil; container = nil; defaults = nil
        try FileManager.default.removeItem(at: root)
    }
    func seed(_ id: String, lines: [String], profile: String? = nil) throws {
        for (i, text) in lines.enumerated() {
            context.insert(MessageNode(id: "\(id)-n\(i)", role: i % 2 == 0 ? "user" : "assistant", content: text,
                contentType: "text", createTime: start.addingTimeInterval(Double(i * 60)),
                parentId: i == 0 ? nil : "\(id)-n\(i - 1)", childrenIds: i + 1 < lines.count ? ["\(id)-n\(i + 1)"] : [],
                conversationId: id, profileId: profile ?? pid))
        }
        context.insert(Conversation(id: id, title: "云桥城 · 星砚", createTime: start,
            updateTime: start.addingTimeInterval(Double(lines.count * 60)), currentNodeId: "\(id)-n\(lines.count - 1)", profileId: profile ?? pid))
        try context.save()
    }
    func node(_ id: String) throws -> MessageNode { try XCTUnwrap(context.fetch(FetchDescriptor<MessageNode>()).first { $0.id == id }) }

    /// 同一份种子压成楼层快照，给 `SnapshotConversationSource` 跑对照（研究 §9.8）。
    func snapshotSource() -> SnapshotConversationSource {
        let conversations = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let nodes = (try? context.fetch(FetchDescriptor<MessageNode>())) ?? []
        let windows = conversations.map { conv in
            FloorSnapshot.Window(
                id: conv.id, title: conv.title, current: conv.currentNodeId,
                memoryEnabled: conv.memoryEnabled, trashed: conv.isTrashed,
                nodes: nodes.filter { $0.conversationId == conv.id }.map { node in
                    FloorSnapshot.Node(id: node.id, role: node.role, text: node.content, at: node.createTime ?? start,
                                       parent: node.parentId, hidden: node.isSourceHidden, deleted: node.isTrashed,
                                       contentType: node.contentType, segments: nil, isSyntheticRoot: node.isSyntheticRoot,
                                       sourceVisibility: node.sourceVisibility, ccMessageId: node.ccMessageId,
                                       childrenIds: node.childrenIds)
                },
                profileId: conv.profileId, updateTime: conv.updateTime,
                branchSelection: conv.branchSelectionData.flatMap { BranchSelection.decode($0) },
                isCC: conv.ccBridgeSessionName != nil, lastRealChatAt: conv.lastRealChatAt,
                provider: conv.provider, importBatchId: conv.importBatchId?.uuidString, archiveKind: conv.archiveKind)
        }
        return SnapshotConversationSource(floor: FloorSnapshot(windows: windows))
    }

    func run(_ input: RecallTool.Input, current: String? = nil) async -> RecallTool.ExecResult {
        await raw(RecallTool.json(input), current: current)
    }
    func source() -> any ConversationSource { SwiftDataConversationSource(container: container) }

    func raw(_ json: String, current: String? = nil) async -> RecallTool.ExecResult {
        try? await readyCatalog()
        let environment = RecallTool.l1Environment(container: container, embedder: KeywordOnlyEmbedder())
        let snapshot = await RecallTool.execute(inputJSON: json, profileId: pid, currentConversationId: current,
            userName: "岚舟", assistantName: "星砚", source: snapshotSource(), memoryRoot: root,
            defaults: defaults, environment: environment)
        let result = await RecallTool.execute(inputJSON: json, profileId: pid, currentConversationId: current,
            userName: "岚舟", assistantName: "星砚", source: source(), memoryRoot: root,
            defaults: defaults, environment: environment)
        XCTAssertEqual(snapshot.text, result.text, json)
        XCTAssertEqual(snapshot.isError, result.isError, json)
        XCTAssertEqual(snapshot.targets, result.targets, json)
        XCTAssertEqual(snapshot.cursor, result.cursor, json)
        return result
    }
    func segment(_ story: String, from: Int = 0, to: Int = 2, kind: SessionSegment.Kind = .rolling) -> SessionSegment {
        SessionSegment(kind: kind, title: "云桥城段\(from)", start: start.addingTimeInterval(Double(from * 60)),
            end: start.addingTimeInterval(Double(to * 60)), from: from, to: to, lastNodeId: "\(cid)-n\(to - 1)",
            story: story, quotes: "", pending: "")
    }
    func a2(_ segments: [SessionSegment]) throws {
        try SessionSummaryStore.save(SessionSummary(conversationId: cid, title: "云桥城", compressedCount: segments.last?.to ?? 0,
            segments: segments, updatedAt: start), in: SessionSummaryStore.dir(root: root))
    }
    func a3(_ story: String) throws {
        try WindowSummaryStore.save(SessionSummary(conversationId: cid, title: "云桥城", compressedCount: 0,
            segments: [segment(story, from: 0, to: 3, kind: .closeout)], updatedAt: start, closedThrough: "\(cid)-n2"), in: root)
    }
    func timeline(_ day: String = "2026-10-31", items: [TimelineDayRecord.Item]? = nil, headline: String = "岚舟的云桥城主调") throws {
        let item = TimelineDayRecord.Item(kind: .short, conversationId: cid, window: "云桥城", title: "星砚的短窗事件",
            start: start, end: start.addingTimeInterval(120), from: "\(cid)-n0", to: "\(cid)-n2")
        try TimelineStore.save(.init(days: [.init(date: day, headline: headline, items: items ?? [item])]),
                               month: String(day.prefix(7)), in: TimelineStore.dir(root: root))
    }
    func readyCatalog() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        CatalogRecallIndexer.shared.ensure(profileId: pid, wiki: wiki)
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
    }
    func assertPage(_ result: RecallTool.ExecResult, layer: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        XCTAssertTrue(result.text.hasPrefix("在 \(layer) 层 · 本次 "), result.text, file: file, line: line)
        XCTAssertLessThanOrEqual(result.text.count, 4000, file: file, line: line)
        let body = result.text.components(separatedBy: "\n").dropFirst().filter {
            !$0.hasPrefix("[") && !$0.hasPrefix("target: ") && !$0.hasPrefix("cursor: ")
                && $0 != "（该消息未完）" && $0 != "（本块未完）"
        }.joined()
        XCTAssertLessThanOrEqual(body.count, 3000, file: file, line: line)
    }
}

final class RecallContractTests: RecallToolTestCase {
    func testEveryOpRejectsMissingRequiredArgumentsAndInapplicableFlags() async {
        for op in [RecallTool.Op.date, .window, .segment, .messages, .search, .wiki] {
            let missing = await run(.init(op: op))
            XCTAssertTrue(missing.isError, op.rawValue)
            for flag in ["exact", "include_invalid"] where op != .search {
                let result = await raw("{\"op\":\"\(op.rawValue)\",\"\(flag)\":false}")
                XCTAssertTrue(result.isError)
                XCTAssertTrue(result.text.contains(flag))
            }
        }
        for input in [#"{"query":"云桥城"}"#, #"{"op":"date","date":"2026-10-31","after":"2026-10-30"}"#,
                      #"{"op":"date","before":"2026-11-01"}"#, #"{"op":"search","query":"云桥城","scope":"b"}"#,
                      #"{"op":"messages","conversation_id":"star-window-0001","from_node_id":"x","offset":3}"#] {
            let result = await raw(input)
            XCTAssertTrue(result.isError, result.text)
        }
    }
    func testWindowPrefixesMustBeUniqueAndAtLeastEightCharacters() async throws {
        try seed("star-window-0002", lines: ["星砚"])
        let ambiguous = await run(.init(op: .window, conversationId: "star-win"))
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains("歧义"))
        let short = await run(.init(op: .window, conversationId: "star"))
        XCTAssertTrue(short.isError)
        let exact = await run(.init(op: .window, conversationId: cid))
        assertPage(exact, layer: "A3")
    }
    func testSegmentAcceptsMatchingParametersAndUsesTargetOverAmbiguousPrefix() async throws {
        try a2([segment("岚舟第一段", to: 1), segment("星砚第二段", from: 1, to: 3)])
        let window = await run(.init(op: .window, conversationId: cid))
        let target = try XCTUnwrap(window.targets.first { $0.segment == 1 })
        try seed("star-window-0002", lines: ["林栖另一窗"])
        for id in [cid, String(cid.prefix(8))] {
            let result = await run(.init(op: .segment, conversationId: id, segment: 1, target: target))
            assertPage(result, layer: "A2")
            XCTAssertTrue(result.text.contains("岚舟第一段"))
            XCTAssertFalse(result.text.contains("星砚第二段"))
            XCTAssertFalse(result.text.contains("林栖另一窗"))
        }
    }
    func testSegmentRejectsConflictingParametersAndShortPrefix() async throws {
        try a2([segment("岚舟第一段", to: 1), segment("星砚第二段", from: 1, to: 3)])
        let window = await run(.init(op: .window, conversationId: cid))
        let target = try XCTUnwrap(window.targets.first { $0.segment == 1 })
        for input in [
            RecallTool.Input(op: .segment, conversationId: "star-window-0002", target: target),
            .init(op: .segment, conversationId: String(cid.prefix(7)), target: target),
            .init(op: .segment, segment: 2, target: target),
        ] {
            let result = await run(input)
            XCTAssertTrue(result.isError, result.text)
            XCTAssertEqual(result.read?.status, "invalidTarget")
            XCTAssertFalse(result.text.contains("岚舟第一段"))
            XCTAssertFalse(result.text.contains("星砚第二段"))
        }
    }
    func testMessagesAcceptMatchingParametersAndRejectConflictingAnchors() async throws {
        try a2([segment("岚舟第一段")])
        let segment = await run(.init(op: .segment, conversationId: cid, segment: 1))
        let target = try XCTUnwrap(segment.targets.first)
        try seed("star-window-0002", lines: ["林栖另一窗"])
        for id in [cid, String(cid.prefix(8))] {
            let result = await run(.init(op: .messages, conversationId: id, fromNodeId: "\(cid)-n0",
                                         toNodeIdExclusive: "\(cid)-n2", target: target))
            assertPage(result, layer: "原文")
            XCTAssertTrue(result.text.contains("岚舟在云桥城画地图"))
            XCTAssertTrue(result.text.contains("星砚带来了航图"))
            XCTAssertFalse(result.text.contains("岚舟准备出发"))
            XCTAssertFalse(result.text.contains("林栖另一窗"))
        }
        for input in [
            RecallTool.Input(op: .messages, conversationId: "star-window-0002", target: target),
            .init(op: .messages, fromNodeId: "\(cid)-n1", target: target),
            .init(op: .messages, toNodeIdExclusive: "\(cid)-n1", target: target),
        ] {
            let result = await run(input)
            XCTAssertTrue(result.isError, result.text)
            XCTAssertEqual(result.read?.status, "invalidTarget")
            XCTAssertFalse(result.text.contains("岚舟在云桥城画地图"))
            XCTAssertFalse(result.text.contains("星砚带来了航图"))
        }
    }
    func testTargetPrefixAllowsFullParameterCursorContinuation() async throws {
        try a2([segment("岚舟第一段")])
        let segment = await run(.init(op: .segment, conversationId: cid, segment: 1))
        let target = try XCTUnwrap(segment.targets.first)
        try node("\(cid)-n0").content = String(repeating: "岚舟", count: 1800) + "林栖尾声"
        try context.save()
        var input = RecallTool.Input(op: .messages, conversationId: String(cid.prefix(8)), fromNodeId: "\(cid)-n0",
                                     toNodeIdExclusive: "\(cid)-n2", target: target)
        let first = await run(input)
        assertPage(first, layer: "原文")
        XCTAssertFalse(first.text.contains("林栖尾声"))
        input.cursor = try XCTUnwrap(first.cursor)
        let next = await run(input)
        assertPage(next, layer: "原文")
        XCTAssertTrue(next.text.contains("林栖尾声"))
        XCTAssertTrue(next.text.contains("星砚带来了航图"))
        XCTAssertFalse(next.text.contains("岚舟准备出发"))
    }
    func testCursorAcceptsPartialMessageParametersAndRejectsChangedTarget() async throws {
        try a2([segment("岚舟第一段")])
        let segment = await run(.init(op: .segment, conversationId: cid, segment: 1))
        let target = try XCTUnwrap(segment.targets.first)
        try node("\(cid)-n0").content = String(repeating: "岚舟", count: 1800) + "林栖尾声"
        try context.save()
        let first = await run(.init(op: .messages, target: target))
        let token = try XCTUnwrap(first.cursor)
        let pure = await run(.init(op: .messages, cursor: token))
        assertPage(pure, layer: "原文")
        XCTAssertTrue(pure.text.contains("林栖尾声"))
        XCTAssertTrue(pure.text.contains("星砚带来了航图"))
        var changed = target
        changed.fromNodeId = "\(cid)-n1"
        for input in [
            RecallTool.Input(op: .messages, conversationId: cid, cursor: token),
            .init(op: .messages, conversationId: String(cid.prefix(8)), cursor: token),
            .init(op: .messages, fromNodeId: target.fromNodeId, cursor: token),
            .init(op: .messages, toNodeIdExclusive: target.toNodeIdExclusive, target: target, cursor: token),
        ] {
            let continued = await run(input)
            assertPage(continued, layer: "原文")
            XCTAssertEqual(continued.text, pure.text)
            XCTAssertEqual(continued.targets, pure.targets)
            XCTAssertEqual(continued.cursor, pure.cursor)
        }
        for input in [
            RecallTool.Input(op: .messages, conversationId: "star-window-0002", cursor: token),
            .init(op: .messages, conversationId: String(cid.prefix(7)), cursor: token),
            .init(op: .messages, fromNodeId: "\(cid)-n1", cursor: token),
            .init(op: .messages, target: changed, cursor: token),
        ] {
            let rejected = await run(input)
            XCTAssertTrue(rejected.isError, rejected.text)
            XCTAssertTrue(rejected.text.contains("cursor 续读不能改变目标/区间"), rejected.text)
            XCTAssertFalse(rejected.text.contains("林栖尾声"))
        }
        for field in ["conversation_id", "target", "from_node_id"] {
            let rejected = await raw(#"{"op":"messages","cursor":"\#(token)","\#(field)":null}"#)
            XCTAssertTrue(rejected.isError, rejected.text)
            XCTAssertTrue(rejected.text.contains("\(field) 与签发时不一致"), rejected.text)
        }
    }
    func testCursorAcceptsSegmentSubsetButRejectsChangedSegment() async throws {
        try a2([segment(String(repeating: "岚舟", count: 4000))])
        let first = await run(.init(op: .segment, conversationId: cid, segment: 1))
        let token = try XCTUnwrap(first.cursor)
        let pure = await run(.init(op: .segment, cursor: token))
        let continued = await run(.init(op: .segment, segment: 1, cursor: token))
        assertPage(continued, layer: "A2")
        XCTAssertEqual(continued.text, pure.text)
        let rejected = await run(.init(op: .segment, segment: 2, cursor: token))
        XCTAssertTrue(rejected.isError, rejected.text)
        XCTAssertTrue(rejected.text.contains("cursor 续读不能改变目标/区间：segment 与签发时不一致"), rejected.text)
    }
    func testCursorSearchSubsetPreservesQueryScopeFlagsAndDates() async throws {
        try seed("cloudbridge-window", lines: (0..<12).map { "岚舟航图\($0)" })
        let first = await run(.init(op: .search, after: "2026-10-31", before: "2026-11-01",
                                    query: "航图", scope: "a", exact: true))
        let token = try XCTUnwrap(first.cursor)
        let pure = await run(.init(op: .search, cursor: token))
        let continued = await run(.init(op: .search, before: "2026-11-01", scope: "a", exact: true, cursor: token))
        assertPage(continued, layer: "原文")
        XCTAssertEqual(continued.text, pure.text)
        for input in [
            RecallTool.Input(op: .search, after: "2026-10-30", cursor: token),
            .init(op: .search, before: "2026-11-02", cursor: token),
            .init(op: .search, query: "林栖", cursor: token),
            .init(op: .search, scope: "c", cursor: token),
            .init(op: .search, exact: false, cursor: token),
            .init(op: .search, includeInvalid: false, cursor: token),
        ] {
            let rejected = await run(input)
            XCTAssertTrue(rejected.isError, rejected.text)
            XCTAssertTrue(rejected.text.contains("cursor 续读不能改变目标/区间"), rejected.text)
        }
    }
    func testTerminalMessagesTargetFreezesLastNodeAcrossAppendAndRejectsDeletedEnd() async throws {
        try a2([segment("岚舟末段", from: 1, to: 3)])
        let segment = await run(.init(op: .segment, conversationId: cid, segment: 1))
        let target = try XCTUnwrap(segment.targets.first)
        XCTAssertEqual(target.fromNodeId, "\(cid)-n1")
        XCTAssertNil(target.toNodeIdExclusive)
        XCTAssertEqual(target.lastNodeId, "\(cid)-n2")
        let original = await run(.init(op: .messages, target: target))
        assertPage(original, layer: "原文")
        XCTAssertTrue(original.text.contains("星砚带来了航图"))
        XCTAssertTrue(original.text.contains("岚舟准备出发"))
        XCTAssertFalse(original.text.contains("岚舟在云桥城画地图"))
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == cid })
        try node("\(cid)-n2").childrenIds = ["appended"]
        context.insert(MessageNode(id: "appended", role: "assistant", content: "林栖追加不在冻结范围", contentType: "text",
            createTime: start, parentId: "\(cid)-n2", childrenIds: [], conversationId: cid, profileId: pid))
        conversation.currentNodeId = "appended"
        try context.save()
        let repeated = await run(.init(op: .messages, target: target))
        assertPage(repeated, layer: "原文")
        XCTAssertEqual(repeated.text, original.text)
        XCTAssertFalse(repeated.text.contains("林栖追加不在冻结范围"))
        let explicitTo = await run(.init(op: .messages, toNodeIdExclusive: "appended", target: target))
        XCTAssertTrue(explicitTo.isError, explicitTo.text)
        XCTAssertTrue(explicitTo.text.contains("显式 to_node_id_exclusive 与 target 内 to_node_id_exclusive 不一致"))
        var guessed = target
        guessed.toNodeIdExclusive = "\(cid)-n2"
        let changed = await run(.init(op: .messages, target: guessed))
        XCTAssertEqual(changed.read?.status, "stale", changed.text)
        XCTAssertFalse(changed.text.contains("星砚带来了航图"))
        context.delete(try node("\(cid)-n2"))
        try context.save()
        let deleted = await run(.init(op: .messages, target: target))
        XCTAssertTrue(deleted.isError, deleted.text)
        XCTAssertEqual(deleted.read?.status, "stale")
        XCTAssertTrue(deleted.text.contains("原文范围的末节点已不可见"), deleted.text)
    }
    func testTerminalMessagesTargetRejectsHiddenCrossBranchAndReversedLastNode() async throws {
        try a2([segment("岚舟末段", from: 1, to: 3)])
        let segment = await run(.init(op: .segment, conversationId: cid, segment: 1))
        let target = try XCTUnwrap(segment.targets.first)
        try node("\(cid)-n2").sourceVisibility = "hidden"
        try context.save()
        let hidden = await run(.init(op: .messages, target: target))
        XCTAssertEqual(hidden.read?.status, "stale", hidden.text)
        try node("\(cid)-n2").sourceVisibility = "visible"
        try node("\(cid)-n0").childrenIds.append("alternate-node")
        context.insert(MessageNode(id: "alternate-node", role: "assistant", content: "林栖另一支", contentType: "text",
            createTime: start, parentId: "\(cid)-n0", childrenIds: [], conversationId: cid, profileId: pid))
        try context.save()
        for last in ["alternate-node", "\(cid)-n0"] {
            var invalid = target
            invalid.lastNodeId = last
            let rejected = await run(.init(op: .messages, target: invalid))
            XCTAssertEqual(rejected.read?.status, "stale", rejected.text)
            XCTAssertTrue(rejected.text.contains("原文范围的末节点已不可见"), rejected.text)
        }
    }
    func testMessagesHalfOpenRangeAndSelectedTreeOrder() async throws {
        let result = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0", toNodeIdExclusive: "\(cid)-n2"))
        assertPage(result, layer: "原文")
        XCTAssertTrue(result.text.contains("岚舟在云桥城画地图"))
        XCTAssertTrue(result.text.contains("星砚带来了航图"))
        XCTAssertFalse(result.text.contains("岚舟准备出发"))
        let reverse = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n2", toNodeIdExclusive: "\(cid)-n0"))
        XCTAssertTrue(reverse.isError)
    }
    func testLongMessageContinuesWithoutMissingOrRepeatingCharacters() async throws {
        let body = (0..<7200).map { String(UnicodeScalar(0x4E00 + $0)!) }.joined() + "👩🏽‍🚀"
        try node("\(cid)-n0").content = body
        try context.save()
        var input = RecallTool.Input(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0", toNodeIdExclusive: "\(cid)-n1")
        var collected = "", pages = 0
        repeat {
            let result = await run(input)
            assertPage(result, layer: "原文")
            let content = result.text.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
                .components(separatedBy: "cursor: ")[0].replacingOccurrences(of: "（该消息未完）\n", with: "")
            collected += content.hasSuffix("\n") ? String(content.dropLast()) : content
            pages += 1
            guard let cursor = result.cursor else { break }
            XCTAssertTrue(result.text.contains("该消息未完"))
            input = .init(op: .messages, cursor: cursor)
            XCTAssertLessThan(pages, 10)
        } while pages < 10
        XCTAssertEqual(collected, body)
    }
    func testMessagesRejectHiddenDeletedForeignAndCrossBranchAnchors() async throws {
        try node("\(cid)-n1").sourceVisibility = "hidden"
        try context.save()
        for anchor in ["\(cid)-n1", "missing-node"] {
            let result = await run(.init(op: .messages, conversationId: cid, fromNodeId: anchor))
            XCTAssertTrue(result.isError)
            XCTAssertFalse(result.text.contains("星砚带来了航图"))
        }
        context.insert(MessageNode(id: "alternate-node", role: "assistant", content: "星砚另一支", contentType: "text",
            createTime: start, parentId: "\(cid)-n0", childrenIds: [], conversationId: cid, profileId: pid))
        try context.save()
        let branch = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0", toNodeIdExclusive: "alternate-node"))
        XCTAssertTrue(branch.isError)
        try seed("foreign-window", lines: ["岚舟别层"], profile: "fictional-foreign")
        let foreign = await run(.init(op: .messages, conversationId: "foreign-window", fromNodeId: "foreign-window-n0"))
        XCTAssertTrue(foreign.isError)
    }
    func testCursorNormalizesCopyingSuffixAndWhitespaceButRejectsInteriorDeletion() async throws {
        try seed("many-window", lines: (0..<12).map { "云桥城第\($0)条" })
        let first = await run(.init(op: .messages, conversationId: "many-window", fromNodeId: "many-window-n0"))
        assertPage(first, layer: "原文")
        let cursor = try XCTUnwrap(first.cursor)
        let clean = await run(.init(op: .messages, cursor: cursor))
        assertPage(clean, layer: "原文")
        XCTAssertTrue(clean.text.contains("云桥城第8条"))
        XCTAssertTrue(clean.text.contains("云桥城第11条"))
        XCTAssertFalse(clean.text.contains("云桥城第7条"))
        for copied in [cursor + "\">\n", " \t\n" + cursor + "\r\n ", " \t" + cursor + "\">\n"] {
            let continued = await run(.init(op: .messages, cursor: copied))
            assertPage(continued, layer: "原文")
            XCTAssertEqual(continued.text, clean.text)
            XCTAssertEqual(continued.targets, clean.targets)
            XCTAssertEqual(continued.cursor, clean.cursor)
        }
        var damaged = cursor
        damaged.remove(at: damaged.index(damaged.startIndex, offsetBy: damaged.count / 2))
        let stale = await run(.init(op: .messages, cursor: damaged))
        XCTAssertTrue(stale.isError)
        XCTAssertEqual(stale.read?.status, "stale")
        XCTAssertFalse(stale.text.contains("云桥城第8条"))
    }
    func testMessagesEightNodeLimitAndChangedSourceMakesCursorStale() async throws {
        try seed("many-window", lines: (0..<12).map { "云桥城第\($0)条" })
        let first = await run(.init(op: .messages, conversationId: "many-window", fromNodeId: "many-window-n0"))
        assertPage(first, layer: "原文")
        XCTAssertTrue(first.text.contains("本次 8 条"))
        XCTAssertFalse(first.text.contains("云桥城第8条"))
        let cursor = try XCTUnwrap(first.cursor)
        let second = await run(.init(op: .messages, cursor: cursor))
        XCTAssertTrue(second.text.contains("云桥城第8条"))
        XCTAssertFalse(second.text.contains("云桥城第7条"))
        try node("many-window-n8").content = "星砚修改"
        try context.save()
        let stale = await run(.init(op: .messages, cursor: cursor))
        XCTAssertEqual(stale.read?.status, "stale")
        let undecodable = await run(.init(op: .messages, cursor: "not-a-valid-cursor"))
        XCTAssertEqual(undecodable.read?.status, "stale")
        XCTAssertTrue(undecodable.text.contains("cursor 已过期或不属于当前楼层/目标"))
    }
    func testSegmentReadsOnlyOneSegmentAndRejectsOldDirectoryTarget() async throws {
        try a2([segment("岚舟第一段", to: 1), segment("星砚第二段", from: 1, to: 3)])
        let window = await run(.init(op: .window, conversationId: cid))
        let target = try XCTUnwrap(window.targets.first { $0.segment == 1 })
        let result = await run(.init(op: .segment, target: target))
        assertPage(result, layer: "A2")
        XCTAssertTrue(result.text.contains("岚舟第一段"))
        XCTAssertFalse(result.text.contains("星砚第二段"))
        let original = try XCTUnwrap(result.targets.first)
        XCTAssertEqual(original.fromNodeId, "\(cid)-n0")
        XCTAssertEqual(original.toNodeIdExclusive, "\(cid)-n1")
        try a2([segment("岚舟改段", to: 1), segment("星砚第二段", from: 1, to: 3)])
        let stale = await run(.init(op: .segment, target: target))
        XCTAssertEqual(stale.read?.status, "stale")
        let absent = await run(.init(op: .segment, conversationId: cid, segment: 9))
        XCTAssertTrue(absent.isError)
    }
    func testWikiFourLayersAndStaleRowThroughRecall() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let card = SeedNoteCard(path: "memory/cc/星砚.md", version: "v1", name: "星砚", layer: "CC", title: "云桥城卡",
            gist: "岚舟和星砚画航图", mentions: [], aboutUser: false, group: "主题", when: [], model: "fictional",
            madeAt: start, run: .init(path: ".runs/fictional.md"))
        let store = SeedNoteStore(wiki: wiki)
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        try store.saveOriginal(path: card.path, version: card.version,
            text: "岚舟在云桥城的原料" + String(repeating: "星砚", count: 1800), sourceContext: nil)
        try store.save(card)
        var page = WikiPage(path: "主题/云桥城", hook: "云桥城", title: "云桥城", now: "岚舟画图",
            records: ["星砚的记录（\(card.path)）"], entries: [card.path + "|v1"],
            links: [.init(target: "人/林栖", relation: .resonance, why: "云桥城同行")])
        try wiki.save(page)
        try wiki.save(WikiPage(path: "人/林栖", title: "林栖", now: "林栖未展开的纸鹤"))
        let index = await run(.init(op: .wiki, folder: "主题", target: .init(tree: "c", layer: "index")))
        assertPage(index, layer: "wiki索引")
        let p = await run(.init(op: .wiki, target: try XCTUnwrap(index.targets.first)))
        assertPage(p, layer: "wiki页")
        XCTAssertFalse(p.text.contains(card.gist))
        XCTAssertTrue(p.targets.contains { $0.page?.path == "人/林栖" })
        let pageRanges = try XCTUnwrap(p.read?.returnedRange)
        XCTAssertEqual(Set(pageRanges.compactMap { $0.page?.path ?? $0.row?.page.path }), [page.path])
        XCTAssertFalse(p.text.contains("林栖未展开的纸鹤"))
        let row = try XCTUnwrap(p.targets.first { $0.row != nil })
        let entry = await run(.init(op: .wiki, target: row))
        assertPage(entry, layer: "L1")
        XCTAssertTrue(entry.text.contains(card.gist))
        XCTAssertFalse(entry.text.contains("岚舟在云桥城的原料"))
        let originalTarget = try XCTUnwrap(entry.targets.first)
        let original = await run(.init(op: .wiki, target: originalTarget))
        assertPage(original, layer: "L2")
        XCTAssertTrue(original.text.contains("岚舟在云桥城的原料"))
        let token = try XCTUnwrap(original.cursor)
        let pure = await run(.init(op: .wiki, cursor: token))
        let continued = await run(.init(op: .wiki, scope: "c", layer: "original", target: originalTarget, cursor: token))
        assertPage(continued, layer: "L2")
        XCTAssertEqual(continued.text, pure.text)
        for layer in ["entry", "page"] {
            let changed = await run(.init(op: .wiki, layer: layer, target: originalTarget, cursor: token))
            XCTAssertTrue(changed.isError, changed.text)
            XCTAssertTrue(changed.text.contains("cursor 续读不能改变目标/区间：layer 与签发时不一致"), changed.text)
        }
        page.now = "星砚改版"
        try wiki.save(page)
        let stale = await run(.init(op: .wiki, layer: "entry", target: row))
        XCTAssertEqual(stale.read?.status, "stale")
        let hidden = await run(.init(op: .wiki, layer: "index", folder: ".cards"))
        XCTAssertTrue(hidden.isError)
    }
    func testWikiAcceptsScopeCButRejectsOtherScopesLayerConflictsAndSkippingEntry() async throws {
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        try wiki.save(WikiPage(path: "主题/云桥城", title: "云桥城", now: "岚舟画航图"))
        let target = RecallTool.Target(tree: "c", layer: "page",
            page: .init(profileId: pid, path: "主题/云桥城"))
        let conflict = await run(.init(op: .wiki, layer: "entry", target: target))
        XCTAssertTrue(conflict.isError, conflict.text)
        XCTAssertEqual(conflict.read?.status, "invalidTarget")
        XCTAssertEqual(conflict.read?.layer, "L1")
        XCTAssertTrue(conflict.text.components(separatedBy: "\n")[0].contains("从父层重新定位"), conflict.text)
        let scopeC = await raw(#"{"op":"wiki","scope":"c","target":\#(RecallTool.json(target))}"#)
        assertPage(scopeC, layer: "wiki页")
        XCTAssertTrue(scopeC.text.contains("岚舟画航图"))
        let index = await run(.init(op: .wiki, scope: "c", layer: "index"))
        assertPage(index, layer: "wiki索引")
        for scope in ["a", "b"] {
            let rejected = await run(.init(op: .wiki, scope: scope, target: target))
            XCTAssertTrue(rejected.isError, rejected.text)
            XCTAssertEqual(rejected.read?.status, "invalidTarget")
            XCTAssertEqual(rejected.read?.layer, "wiki页")
            XCTAssertTrue(rejected.text.contains("wiki 用 layer:index|page|entry|original，不用 scope"), rejected.text)
            XCTAssertFalse(rejected.text.contains("岚舟画航图"))
        }
        var premature = target
        premature.layer = "original"
        let skipped = await run(.init(op: .wiki, target: premature))
        XCTAssertTrue(skipped.isError, skipped.text)
        XCTAssertEqual(skipped.read?.status, "invalidTarget")
        XCTAssertEqual(skipped.read?.layer, "L2")
        XCTAssertTrue(skipped.text.components(separatedBy: "\n")[0].contains("从 page 请先 layer:entry"), skipped.text)
        XCTAssertFalse(skipped.text.contains("岚舟画航图"))
    }
    func testContinuationUsesCurrentSnapshotAndRejectsAnotherProfileOrAlteredArguments() async throws {
        try seed("tuned-window", lines: (0..<6).map { "岚舟云桥城\($0)" })
        var tuning = RecallTuning.defaults
        tuning.originalPageMessages = 2
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let first = await run(.init(op: .messages, conversationId: "tuned-window", fromNodeId: "tuned-window-n0"))
        XCTAssertTrue(first.text.contains("本次 2 条"))
        let token = try XCTUnwrap(first.cursor)
        tuning.originalPageMessages = 1
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let second = await run(.init(op: .messages, cursor: token))
        XCTAssertTrue(second.text.contains("本次 1 条"))
        XCTAssertTrue(second.text.contains("岚舟云桥城2"))
        let changed = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0", cursor: token))
        XCTAssertTrue(changed.isError)
        let foreign = await RecallTool.execute(inputJSON: RecallTool.json(RecallTool.Input(op: .messages, cursor: token)),
            profileId: "fictional-other", currentConversationId: nil, userName: "岚舟", assistantName: "星砚",
            source: SwiftDataConversationSource(container: container), memoryRoot: root, defaults: defaults,
            environment: RecallTool.l1Environment(container: container, embedder: KeywordOnlyEmbedder()))
        XCTAssertEqual(foreign.read?.status, "stale")
    }
    func testLongSegmentRetainsStableOriginalBoundaryOnEveryChunk() async throws {
        let story = String(repeating: "岚舟👩🏽‍🚀星砚", count: 1800)
        try a2([segment(story)])
        var result = await run(.init(op: .segment, conversationId: cid, segment: 1))
        var text = "", pages = 0
        repeat {
            assertPage(result, layer: "A2")
            XCTAssertEqual(result.targets.first?.fromNodeId, "\(cid)-n0")
            XCTAssertEqual(result.targets.first?.toNodeIdExclusive, "\(cid)-n2")
            let payload = result.text.components(separatedBy: "\n").dropFirst(3).joined(separator: "\n")
                .components(separatedBy: "cursor: ")[0].replacingOccurrences(of: "（本块未完）\n", with: "")
            text += payload.hasSuffix("\n") ? String(payload.dropLast()) : payload
            pages += 1
            guard let cursor = result.cursor else { break }
            result = await run(.init(op: .segment, cursor: cursor))
        } while pages < 20
        XCTAssertEqual(text, CatalogALineReader.segmentParts(segment(story)).map(\.text).joined())
    }
    func testWikiFragmentUsesExistingMemoryAnchorWithoutCreatingASeedCard() async throws {
        let memory = Memory(content: "星砚碎片的 L1 证据", category: "fact", profileId: pid)
        memory.sourceConversationId = cid
        memory.sourceNodeId = "\(cid)-n0"
        memory.occurredDay = "2026-10-31"
        context.insert(memory)
        try context.save()
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        try wiki.save(WikiPage(path: "主题/云桥城", title: "云桥城",
            records: ["岚舟的记录（出处：\(CatalogSources.label(memory.id))）"]))
        let page = await run(.init(op: .wiki, layer: "page", target: .init(
            tree: "c", layer: "page", page: .init(profileId: pid, path: "主题/云桥城"))))
        let entry = await run(.init(op: .wiki, layer: "entry", target: try XCTUnwrap(page.targets.first)))
        assertPage(entry, layer: "L1")
        XCTAssertTrue(entry.text.contains(memory.content))
        let target = try XCTUnwrap(entry.targets.first)
        XCTAssertEqual(target.memoryId, memory.id.uuidString)
        let original = await run(.init(op: .wiki, layer: "original", target: target))
        assertPage(original, layer: "L2")
        XCTAssertTrue(original.text.contains("岚舟在云桥城画地图"))
        XCTAssertFalse(original.text.contains(memory.content))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wiki.root.appendingPathComponent(".cards").path))
        try node("\(cid)-n0").content = "星砚修改原文"
        try context.save()
        let stale = await run(.init(op: .wiki, layer: "original", target: target))
        XCTAssertEqual(stale.read?.status, "stale")
        try node("\(cid)-n0").sourceVisibility = "hidden"
        try context.save()
        let hidden = await run(.init(op: .wiki, layer: "original", target: target))
        XCTAssertTrue(hidden.isError)
        XCTAssertFalse(hidden.text.contains("星砚修改原文"))
    }

    func testDecodedCursorRejectsInvalidPositionsTimezoneLayerRevisionAndDate() async throws {
        try node("\(cid)-n0").content = String(repeating: "岚舟", count: 4000)
        try context.save()
        let first = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0"))
        let saved = try XCTUnwrap(RecallTool.decodeCursor(XCTUnwrap(first.cursor)))
        var invalid: [RecallTool.Cursor] = []
        var next = saved; next.position = -1; invalid.append(next)
        next = saved; next.offset = -1; invalid.append(next)
        next = saved; next.timeZone = "unresolvable-zone"; invalid.append(next)
        next = saved; next.layer = "A4"; invalid.append(next)
        next = saved; next.revision = ""; invalid.append(next)
        for state in invalid {
            let result = await run(.init(op: .messages, cursor: RecallTool.encodeCursor(state)))
            XCTAssertEqual(result.read?.status, "stale", result.text)
        }
        try timeline(items: (0..<13).map {
            .init(kind: .short, conversationId: cid, window: "云桥城", title: "航图\($0)",
                  start: start, end: start, from: nil, to: nil)
        })
        let date = await run(.init(op: .date, date: "2026-10-31"))
        let dateCursor = try XCTUnwrap(RecallTool.decodeCursor(XCTUnwrap(date.cursor)))
        for day in ["not-a-date", "2026-11-01", "2026-10-30"] {
            var state = dateCursor
            state.day = day
            let result = await run(.init(op: .date, cursor: RecallTool.encodeCursor(state)))
            XCTAssertEqual(result.read?.status, "stale", result.text)
        }
    }

    func testUUIDMetadataFitsTenSegmentsAndTwelveDateEvents() async throws {
        let id = UUID().uuidString
        let ids = (0..<12).map { _ in UUID().uuidString }
        for i in ids.indices {
            context.insert(MessageNode(id: ids[i], role: i % 2 == 0 ? "user" : "assistant", content: "航图",
                contentType: "text", createTime: start.addingTimeInterval(Double(i)), parentId: i == 0 ? nil : ids[i - 1],
                childrenIds: i + 1 < ids.count ? [ids[i + 1]] : [], conversationId: id, profileId: pid))
        }
        context.insert(Conversation(id: id, title: "云桥城", createTime: start, updateTime: start, currentNodeId: ids.last!, profileId: pid))
        try context.save()
        let segments = (0..<12).map { i in
            SessionSegment(kind: .rolling, title: "航图\(i)", start: start, end: start, from: i, to: i + 1,
                           lastNodeId: ids[i], story: "岚舟", quotes: "", pending: "")
        }
        try SessionSummaryStore.save(.init(conversationId: id, title: "云桥城", compressedCount: 10,
            segments: Array(segments.prefix(10)), updatedAt: start), in: SessionSummaryStore.dir(root: root))
        let window = await run(.init(op: .window, conversationId: id))
        assertPage(window, layer: "A3")
        XCTAssertEqual(window.targets.compactMap(\.segment), Array(1...10))
        XCTAssertNil(window.cursor)
        try SessionSummaryStore.save(.init(conversationId: id, title: "云桥城", compressedCount: 12,
            segments: segments, updatedAt: start), in: SessionSummaryStore.dir(root: root))
        for kind in [TimelineDayRecord.Item.Kind.short, .segment] {
            try timeline(items: (0..<12).map {
                .init(kind: kind, conversationId: id, window: "云桥城", title: "航图\($0)",
                      start: start.addingTimeInterval(Double($0)), end: start, from: ids[$0], to: ids[$0])
            })
            let date = await run(.init(op: .date, date: "2026-10-31"))
            assertPage(date, layer: "A4")
            XCTAssertEqual(date.targets.filter { $0.layer == "window" }.count, 12)
            XCTAssertEqual(date.targets.filter { $0.layer == (kind == .short ? "messages" : "segment") }.count, 12)
            XCTAssertNil(date.cursor)
        }
    }

    func testWideOriginalSearchBuildsOnlyPageAndLookahead() async throws {
        for window in 0..<200 {
            let id = "cloudbridge-\(window)"
            for i in 0..<50 {
                context.insert(MessageNode(id: "\(id)-\(i)", role: i % 2 == 0 ? "user" : "assistant", content: "航图\(window)-\(i)",
                    contentType: "text", createTime: start.addingTimeInterval(Double(window * 100 + i)),
                    parentId: i == 0 ? nil : "\(id)-\(i - 1)", childrenIds: i < 49 ? ["\(id)-\(i + 1)"] : [],
                    conversationId: id, profileId: pid))
            }
            context.insert(Conversation(id: id, title: "云桥城", createTime: start, updateTime: start,
                                        currentNodeId: "\(id)-49", profileId: pid))
        }
        try context.save()
        let input = RecallTool.Input(op: .search, query: "航图", scope: "a", exact: true)
        let state = RecallTool.Cursor(profileId: pid, root: root.path, input: input, layer: "原文", timeZone: Calendar.current.timeZone.identifier)
        var paths: [String: RecallTool.Path] = [:]
        var loads = 0
        let source = SwiftDataConversationSource(container: container!)
        let page = try RecallTool.originalSearch(state, source: source, query: "航图", cid: nil, after: nil, before: nil) { id in
            if let path = paths[id] { return path }
            loads += 1
            let path = try RecallTool.path(id, state: state, source: source)
            paths[id] = path
            return path
        }
        XCTAssertEqual(page.blocks.count, state.tuning.searchPageResults + 1)
        XCTAssertLessThanOrEqual(loads, 2)
        XCTAssertEqual(page.blocks.prefix(5).compactMap { $0.targets.first?.fromNodeId },
                       (45...49).reversed().map { "cloudbridge-199-\($0)" })
        let first = await run(input)
        XCTAssertEqual(first.targets.compactMap(\.fromNodeId), (45...49).reversed().map { "cloudbridge-199-\($0)" })
        let second = await run(.init(op: .search, cursor: try XCTUnwrap(first.cursor)))
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(second.targets.first?.fromNodeId, "cloudbridge-198-49")
    }

    func testLegacyMemoryCursorRejectsBranchChangeWithoutNodeAnchor() async throws {
        for text in ["云桥城航图甲", "云桥城航图乙"] {
            let memory = Memory(content: text, category: "fact", profileId: pid)
            memory.sourceConversationId = cid
            context.insert(memory)
        }
        try context.save()
        var tuning = RecallTuning.defaults
        tuning.searchPageResults = 1
        func search(_ input: RecallTool.Input) async -> RecallTool.ExecResult {
            await RecallTool.execute(inputJSON: RecallTool.json(input), profileId: pid, currentConversationId: nil,
                userName: "岚舟", assistantName: "星砚", source: SwiftDataConversationSource(container: container), memoryRoot: root,
                defaults: defaults, tuning: tuning,
                environment: RecallTool.l1Environment(container: container, embedder: KeywordOnlyEmbedder()))
        }
        let input = RecallTool.Input(op: .search, query: "云桥城航图", scope: "c")
        let first = await search(input)
        XCTAssertFalse(first.isError, first.text)
        let token = try XCTUnwrap(first.cursor)
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == cid })
        try node("\(cid)-n0").childrenIds.append("star-branch")
        context.insert(MessageNode(id: "star-branch", role: "assistant", content: "林栖的新分支", contentType: "text",
            createTime: start, parentId: "\(cid)-n0", childrenIds: [], conversationId: cid, profileId: pid))
        conversation.currentNodeId = "star-branch"
        try context.save()
        let continuation = await search(.init(op: .search, cursor: token))
        XCTAssertTrue(continuation.isError, continuation.text)
        XCTAssertEqual(continuation.read?.status, "stale")
        let relocated = await search(input)
        XCTAssertFalse(relocated.isError, relocated.text)
        XCTAssertEqual(relocated.hitMemoryIds, first.hitMemoryIds)
    }

    func testMemoryParticipationAndSourceParticipationOnlyBlockDerivedReads() async throws {
        try a2([segment("岚舟派生记忆")])
        let disabled = await RecallTool.execute(inputJSON: RecallTool.json(RecallTool.Input(op: .window, conversationId: cid)),
            profileId: pid, currentConversationId: nil, userName: "岚舟", assistantName: "星砚",
            source: SwiftDataConversationSource(container: container), memoryRoot: root, defaults: defaults, memoryParticipation: false,
            environment: RecallTool.l1Environment(container: container, embedder: KeywordOnlyEmbedder()))
        XCTAssertTrue(disabled.isError)
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == cid })
        conversation.memoryEnabled = false
        try context.save()
        for input in [RecallTool.Input(op: .window, conversationId: cid), .init(op: .segment, conversationId: cid, segment: 1)] {
            let result = await run(input)
            XCTAssertTrue(result.isError)
            XCTAssertFalse(result.text.contains("岚舟派生记忆"))
        }
        let original = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0", toNodeIdExclusive: "\(cid)-n1"))
        XCTAssertFalse(original.isError, original.text)
        XCTAssertTrue(original.text.contains("岚舟在云桥城画地图"))
    }

    func testEmptyHitReturnedCountZero() async throws {
        var tuning = RecallTuning.defaults
        tuning.datePageDays = 2
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let empty = await run(.init(op: .date, after: "2026-10-30", before: "2026-11-02"))
        assertPage(empty, layer: "A4")
        XCTAssertTrue(empty.text.hasPrefix("在 A4 层 · 本次 0 条"))
        XCTAssertEqual(empty.read?.returnedCount, 0, "空命中 = 0，不是 nil")
        XCTAssertNil(empty.read?.gate, "正常读数没有闸")

        let invalid = await run(.init(op: .window))
        XCTAssertTrue(invalid.isError)
        XCTAssertEqual(invalid.read?.returnedCount, 0, "失败也是 0")
        XCTAssertNil(invalid.read?.gate, "参数错不是关闭拒绝")

        let messages = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0",
                                       toNodeIdExclusive: "\(cid)-n2"))
        XCTAssertFalse(messages.isError, messages.text)
        XCTAssertTrue(messages.text.hasPrefix("在 原文 层 · 本次 2 条"), "n0…n2 不含 = 2 条")
        XCTAssertEqual(messages.read?.returnedCount, 2, "成功页 = 本条数")
    }

    func testMasterAndWindowRejectionGate() async throws {
        try a2([segment("岚舟派生记忆")])
        defaults.set(false, forKey: "mem_master")
        let masterOff = await run(.init(op: .window, conversationId: cid))
        XCTAssertTrue(masterOff.isError)
        XCTAssertEqual(masterOff.read?.gate, "master", "mem_master 关")
        XCTAssertEqual(masterOff.read?.returnedCount, 0)
        XCTAssertEqual(masterOff.read?.status, "invalidTarget", "status 字符串一个不改")

        defaults.set(true, forKey: "mem_master")
        let windowOff = await RecallTool.execute(inputJSON: RecallTool.json(RecallTool.Input(op: .window, conversationId: cid)),
            profileId: pid, currentConversationId: nil, userName: "岚舟", assistantName: "星砚",
            source: SwiftDataConversationSource(container: container), memoryRoot: root, defaults: defaults, memoryParticipation: false,
            environment: RecallTool.l1Environment(container: container, embedder: KeywordOnlyEmbedder()))
        XCTAssertTrue(windowOff.isError)
        XCTAssertEqual(windowOff.read?.gate, "window", "本窗关参与")
        XCTAssertEqual(windowOff.read?.returnedCount, 0)

        let search = await run(.init(op: .search, query: "岚舟", scope: "a", exact: true))
        XCTAssertFalse(search.isError, "搜索不受闸")
        XCTAssertNil(search.read?.gate, "照读不是拒绝")
    }

    func testAppendingMessagesKeepsExistingSegmentAndOpenEndedCursorStable() async throws {
        try a2([segment("岚舟第一段", to: 1)])
        let window = await run(.init(op: .window, conversationId: cid))
        let target = try XCTUnwrap(window.targets.first)
        try node("\(cid)-n0").content = String(repeating: "星砚", count: 4000)
        try context.save()
        let original = await run(.init(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0"))
        let token = try XCTUnwrap(original.cursor)
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first { $0.id == cid })
        try node("\(cid)-n2").childrenIds = ["appended"]
        context.insert(MessageNode(id: "appended", role: "assistant", content: "林栖追加不在冻结范围", contentType: "text",
            createTime: start, parentId: "\(cid)-n2", childrenIds: [], conversationId: cid, profileId: pid))
        conversation.currentNodeId = "appended"
        try context.save()
        let segment = await run(.init(op: .segment, target: target))
        XCTAssertFalse(segment.isError, segment.text)
        let continuation = await run(.init(op: .messages, cursor: token))
        XCTAssertFalse(continuation.isError, continuation.text)
        XCTAssertFalse(continuation.text.contains("林栖追加不在冻结范围"))
    }

    func testLargerTurnLimitsApplyWithoutCursorTuningAndLegacySegmentsHaveNoFalseOriginalAnchor() async throws {
        try node("\(cid)-n0").content = String(repeating: "岚舟", count: 4000)
        try context.save()
        var tuning = RecallTuning.defaults
        tuning.maximumBodyCharacters = 4500
        tuning.maximumResponseCharacters = 6000
        let first = await RecallTool.execute(inputJSON: RecallTool.json(RecallTool.Input(
            op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0", toNodeIdExclusive: "\(cid)-n1")),
            profileId: pid, currentConversationId: nil, userName: "岚舟", assistantName: "星砚",
            source: SwiftDataConversationSource(container: container), memoryRoot: root, defaults: defaults, tuning: tuning,
            environment: RecallTool.l1Environment(container: container, embedder: KeywordOnlyEmbedder()))
        XCTAssertFalse(first.isError, first.text)
        let body = first.text.components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
            .components(separatedBy: "cursor: ")[0].replacingOccurrences(of: "（该消息未完）\n", with: "")
            .trimmingCharacters(in: .newlines)
        XCTAssertEqual(body.count, tuning.maximumBodyCharacters)
        XCTAssertLessThanOrEqual(first.text.count, tuning.maximumResponseCharacters)
        var legacy = segment("岚舟旧累计段", kind: .legacy)
        legacy.lastNodeId = nil
        try a2([legacy])
        let result = await run(.init(op: .segment, conversationId: cid, segment: 0))
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("旧段，原文范围不可精确定位"))
        XCTAssertTrue(result.targets.isEmpty)
    }
    func testDatePageDaysOneReturnsThreeDaysInThreePagesAndTuningChangesOnContinuation() async throws {
        for key in ["2026-10-30", "2026-10-31", "2026-11-01"] {
            try TimelineStore.mutateMonth(String(key.prefix(7)), in: TimelineStore.dir(root: root)) {
                $0.days.append(.init(date: key, headline: nil, items: [
                    .init(kind: .short, conversationId: cid, window: "云桥城", title: "星砚航图\(key)",
                          start: start, end: start, from: nil, to: nil)
                ]))
            }
        }
        var tuning = RecallTuning.defaults
        tuning.datePageDays = 1
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let first = await run(.init(op: .date, after: "2026-10-30", before: "2026-11-02"))
        assertPage(first, layer: "A4")
        XCTAssertTrue(first.text.hasPrefix("在 A4 层 · 本次 1 条"))
        XCTAssertTrue(first.text.contains("星砚航图2026-10-30"))
        XCTAssertFalse(first.text.contains("星砚航图2026-10-31"))
        let firstToken = try XCTUnwrap(first.cursor)
        let second = await run(.init(op: .date, cursor: firstToken))
        XCTAssertTrue(second.text.contains("星砚航图2026-10-31"))
        XCTAssertFalse(second.text.contains("星砚航图2026-11-01"))
        let third = await run(.init(op: .date, cursor: try XCTUnwrap(second.cursor)))
        XCTAssertTrue(third.text.contains("星砚航图2026-11-01"))
        XCTAssertNil(third.cursor)
        tuning.datePageDays = 2
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let changed = await run(.init(op: .date, cursor: firstToken))
        assertPage(changed, layer: "A4")
        XCTAssertTrue(changed.text.hasPrefix("在 A4 层 · 本次 2 条"))
        XCTAssertTrue(changed.text.contains("星砚航图2026-10-31"))
        XCTAssertTrue(changed.text.contains("星砚航图2026-11-01"))
        XCTAssertEqual(changed.read?.returnedRange?.compactMap(\.date), ["2026-10-31", "2026-11-01"])
        XCTAssertEqual(changed.read?.next, .init(hasMore: false, cursorIssued: false))
        XCTAssertNil(changed.cursor)
    }

    func testMultiDayDatePageKeepsOtherDaysWhenLegacyDailyCannotBeVerified() async throws {
        for key in ["2026-10-30", "2026-11-01"] {
            try TimelineStore.mutateMonth(String(key.prefix(7)), in: TimelineStore.dir(root: root)) {
                $0.days.append(.init(date: key, headline: nil, items: [
                    .init(kind: .short, conversationId: cid, window: "云桥城", title: "星砚航图\(key)",
                          start: start, end: start, from: nil, to: nil)
                ]))
            }
        }
        let daily = root.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        try Data(FrontmatterCodec.render(meta: [
            ("date", "2026-10-31"), ("sourceConversations", RecallTool.json(["fictional-missing-window"]))
        ], body: "林栖不能公开的旧日记").utf8).write(to: daily.appendingPathComponent("2026-10-31.md"))
        var tuning = RecallTuning.defaults
        tuning.datePageDays = 2
        tuning.datePageEvents = 1
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let first = await run(.init(op: .date, after: "2026-10-30", before: "2026-11-02"))
        assertPage(first, layer: "A4")
        XCTAssertEqual(first.read?.status, "partial")
        XCTAssertTrue(first.text.contains("星砚航图2026-10-30"))
        let second = await run(.init(op: .date, cursor: try XCTUnwrap(first.cursor)))
        assertPage(second, layer: "A4")
        XCTAssertEqual(second.read?.status, "success")
        XCTAssertTrue(second.text.contains("2026-10-31 旧时间轴（旧 daily）· 来源无法逐窗核验"))
        XCTAssertTrue(second.text.contains("星砚航图2026-11-01"))
        XCTAssertFalse(second.text.contains("林栖不能公开的旧日记"))
        XCTAssertEqual(second.targets.filter { $0.layer == "window" }.map(\.conversationId), [cid])
        XCTAssertTrue(second.targets.allSatisfy { $0.date != "2026-10-31" })
        XCTAssertNil(second.cursor)
        let single = await run(.init(op: .date, date: "2026-10-31"))
        XCTAssertTrue(single.isError, single.text)
        XCTAssertEqual(single.read?.status, "unavailable")
        XCTAssertTrue(single.text.contains("2026-10-31"))
        XCTAssertTrue(single.text.contains("旧日记来源无法逐窗核验"))
    }

    func testDateDayLimitAndEventLimitKeepDayLocalCursorAcrossTuningChangeAndRevision() async throws {
        for key in ["2026-10-30", "2026-10-31", "2026-11-01"] {
            try TimelineStore.mutateMonth(String(key.prefix(7)), in: TimelineStore.dir(root: root)) {
                $0.days.append(.init(date: key, headline: nil, items: (0..<2).map { index in
                    .init(kind: .short, conversationId: cid, window: "云桥城", title: "星砚\(key)事件\(index)",
                          start: start.addingTimeInterval(Double(index)), end: start, from: nil, to: nil)
                }))
            }
        }
        var tuning = RecallTuning.defaults
        tuning.datePageDays = 3
        tuning.datePageEvents = 3
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let first = await run(.init(op: .date, after: "2026-10-30", before: "2026-11-02"))
        let token = try XCTUnwrap(first.cursor)
        XCTAssertEqual(first.read?.next, .init(hasMore: true, cursorIssued: true))
        XCTAssertTrue(first.text.contains("星砚2026-10-31事件0"))
        XCTAssertFalse(first.text.contains("星砚2026-10-31事件1"))
        tuning.datePageDays = 1
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let second = await run(.init(op: .date, cursor: token))
        assertPage(second, layer: "A4")
        XCTAssertTrue(second.text.contains("星砚2026-10-31事件1"))
        XCTAssertFalse(second.text.contains("星砚2026-10-31事件0"))
        XCTAssertFalse(second.text.contains("星砚2026-11-01事件0"))
        try TimelineStore.mutateMonth("2026-10", in: TimelineStore.dir(root: root)) {
            let index = $0.days.firstIndex { $0.date == "2026-10-31" }!
            $0.days[index].items[1].title = "林栖改版事件"
        }
        let stale = await run(.init(op: .date, cursor: token))
        XCTAssertEqual(stale.read?.status, "stale")
        XCTAssertFalse(stale.text.contains("林栖改版事件"))
    }

    func testEmptyDatePagesReportWholeAdvancedRangeAndContinueAcrossMonth() async throws {
        var tuning = RecallTuning.defaults
        tuning.datePageDays = 2
        RecallTuningStore.save(tuning, profileId: pid, defaults: defaults)
        let first = await run(.init(op: .date, after: "2026-10-30", before: "2026-11-02"))
        assertPage(first, layer: "A4")
        XCTAssertTrue(first.text.hasPrefix("在 A4 层 · 本次 0 条"))
        XCTAssertTrue(first.text.contains("2026-10-30…2026-10-31 没有可见的 A4 或旧时间轴。"))
        XCTAssertEqual(first.read?.returnedRange?.compactMap(\.date), ["2026-10-30", "2026-10-31"])
        let next = await run(.init(op: .date, cursor: try XCTUnwrap(first.cursor)))
        assertPage(next, layer: "A4")
        XCTAssertTrue(next.text.contains("2026-11-01 没有可见的 A4 或旧时间轴。"))
        XCTAssertEqual(next.read?.returnedRange?.compactMap(\.date), ["2026-11-01"])
        XCTAssertEqual(next.read?.next, .init(hasMore: false, cursorIssued: false))
        XCTAssertNil(next.cursor)
    }

    func testSearchReceiptDoesNotClaimMessagesBetweenNoncontiguousHits() async throws {
        let result = await run(.init(op: .search, query: "岚舟", scope: "a", exact: true))
        assertPage(result, layer: "原文")
        let ranges = try XCTUnwrap(result.read?.returnedRange)
        XCTAssertEqual(Set(ranges.compactMap(\.fromNodeId)), ["\(cid)-n0", "\(cid)-n2"])
        XCTAssertTrue(ranges.allSatisfy { $0.conversationId == cid && $0.fromNodeId == $0.lastNodeId })
        XCTAssertFalse(result.text.contains("星砚带来了航图"))
    }


    /// 同一批 op 走 SwiftData 与 Snapshot 两个实现，回执逐字相同。
    func testSwiftDataParity() async throws {
        try timeline()
        let inputs = [
            RecallTool.Input(op: .date, date: "2026-10-31"),
            RecallTool.Input(op: .window, conversationId: cid),
            RecallTool.Input(op: .segment, conversationId: cid, segment: 0),
            RecallTool.Input(op: .messages, conversationId: cid, fromNodeId: "\(cid)-n0"),
            RecallTool.Input(op: .search, query: "航图", scope: "a"),
        ]
        let swiftData = SwiftDataConversationSource(container: container)
        let snapshot = snapshotSource()
        let environment = RecallTool.l1Environment(container: container, embedder: KeywordOnlyEmbedder())
        for input in inputs {
            let json = RecallTool.json(input)
            let a = await RecallTool.execute(inputJSON: json, profileId: pid, currentConversationId: nil,
                                             userName: "岚舟", assistantName: "星砚", source: swiftData,
                                             memoryRoot: root, defaults: defaults, environment: environment)
            let b = await RecallTool.execute(inputJSON: json, profileId: pid, currentConversationId: nil,
                                             userName: "岚舟", assistantName: "星砚", source: snapshot,
                                             memoryRoot: root, defaults: defaults, environment: environment)
            XCTAssertEqual(a.text, b.text, "\(input.op)")
            XCTAssertEqual(a.isError, b.isError, "\(input.op)")
            XCTAssertEqual(a.targets, b.targets, "\(input.op)")
            XCTAssertEqual(a.cursor, b.cursor, "\(input.op)")
            if input.op == .date || input.op == .messages || input.op == .search {
                XCTAssertFalse(a.isError, "\(input.op): \(a.text)")
                XCTAssertFalse(b.isError, "\(input.op): \(b.text)")
            }
        }
    }
}

struct KeywordOnlyEmbedder: MemoryEmbedding {
    var isReady: Bool { false }
    var revision: Int { 0 }
    func embed(_ text: String) -> [Float]? { nil }
}
