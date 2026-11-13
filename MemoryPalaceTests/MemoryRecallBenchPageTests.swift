import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

final class MemoryRecallBenchPageTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func run(id: String, at: Double, writer: String = "recall", main: Double?) -> MemoryBenchRun {
        MemoryBenchRun(id: id, writer: writer, at: Date(timeIntervalSince1970: at), status: .done,
            set: .init(id: "fictional", name: "虚构测试集", revision: "r"), recipes: [], models: [], caseIds: [], cells: [], judgments: [],
            scores: [.init(scorer: "recall", version: 2, recipeId: "r", modelId: "m", main: main, mainName: "主分", parts: [:])], pinned: false)
    }

    func testPulseUsesNewestRecallRunAndDistinguishesUnscoredFromNeverRun() throws {
        let store = MemoryBenchStore(root: try root())
        XCTAssertEqual(AuditStation.recallPulse(store: store), .init(figure: nil, label: "还没跑"))
        try store.saveRun(run(id: "new", at: 20, main: 0.726))
        try store.saveRun(run(id: "old", at: 10, main: 0.11))
        try store.saveRun(run(id: "other-writer", at: 30, writer: "c2", main: 1))
        var cancelled = run(id: "cancelled", at: 31, main: 0.99)
        cancelled.status = .cancelled
        try store.saveRun(cancelled)
        var running = run(id: "running", at: 32, main: 1)
        running.status = .running
        try store.saveRun(running)
        XCTAssertEqual(AuditStation.recallPulse(store: store), .init(figure: "0.73", label: "最近一次"))
        try store.saveRun(run(id: "no-score", at: 40, main: nil))
        XCTAssertEqual(AuditStation.recallPulse(store: store), .init(figure: "—", label: "最近一次"))
    }

    func testComposerRejectsMissingAndStaleKeysWithoutAppendingCase() async throws {
        let root = try root()
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let page = wiki.root.appendingPathComponent("人/岚舟.md")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# 岚舟\n\n## 现在\n住在云桥城\n".utf8).write(to: page)
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let loaded = await Task.detached {
            MemoryRecallBenchSource.load(profileId: "fictional", memoryRoot: root, container: container)
        }.value
        let sources = loaded.sources
        let source = try XCTUnwrap(sources.first { $0.kind == .page })
        let store = MemoryBenchStore(root: root.appendingPathComponent("bench"))
        let names = MemoryBenchRecallInput.Names(userName: "岚舟", assistantName: "星砚", timeZone: Calendar.current.timeZone.identifier)
        var draft = MemoryRecallBenchDraft(text: "岚舟住在哪里？", second: "那旧住处呢？", selections: [.init(source: source, kind: "必须带", turn: 2)])
        XCTAssertThrowsError(try draft.save(names: names, availableKeys: [], store: store))
        XCTAssertTrue(store.floorSets().isEmpty)
        try draft.save(names: names, availableKeys: Set(sources.map(\.id)), store: store)
        let saved = try XCTUnwrap(store.floorSets().first)
        let testCase = try XCTUnwrap(saved.cases.first)
        let input = try testCase.input.decode(MemoryBenchRecallInput.self)
        XCTAssertEqual(saved.id, "recall-floor")
        XCTAssertEqual(input.turns.map(\.text), ["岚舟住在哪里？", "那旧住处呢？"])
        XCTAssertEqual(input.snapshot, "floor")
        XCTAssertEqual(testCase.labels.first?.keys, [source.id])
        XCTAssertEqual(testCase.labels.first?.from, "turn:2")
        try Data("# 岚舟\n\n## 现在\n搬到雾港\n".utf8).write(to: page)
        let fresh = await Task.detached {
            MemoryRecallBenchSource.load(profileId: "fictional", memoryRoot: root, container: container)
        }.value
        draft.text = "旧版本还在吗？"
        XCTAssertThrowsError(try draft.save(names: names, availableKeys: Set(fresh.sources.map(\.id)), store: store))
        XCTAssertEqual(store.floorSets().first?.cases, saved.cases)
    }

    func testComposerExcludesPrivateWikiPages() async throws {
        let root = try root()
        let wiki = root.appendingPathComponent("wiki/人")
        try FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
        try Data("# 虚构\n\n## 现在\n在云桥城画地图\n".utf8).write(to: wiki.appendingPathComponent("虚构.md"))
        try Data("# 私密虚构\n\n## 现在\n不应列出\n".utf8).write(to: wiki.appendingPathComponent("private_虚构.md"))
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let loaded = await Task.detached {
            MemoryRecallBenchSource.load(profileId: "fictional", memoryRoot: root, container: container)
        }.value
        XCTAssertEqual(loaded.sources.filter { $0.kind == .page }.map(\.detail), ["人/虚构"])
    }

    @MainActor
    func testComposerExcludesTrashedHiddenAndMemoryDisabledNodes() async throws {
        let root = try root()
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let at = Date(timeIntervalSince1970: 1_794_000_000)
        let window = Conversation(id: "visible-window", title: "虚构航图窗", createTime: at, updateTime: at,
                                  currentNodeId: "hidden", profileId: "fictional")
        let disabled = Conversation(id: "disabled-window", title: "虚构关闭窗", createTime: at, updateTime: at,
                                    currentNodeId: "disabled", profileId: "fictional")
        disabled.memoryEnabled = false
        context.insert(window)
        context.insert(disabled)
        let visible = MessageNode(id: "visible", role: "user", content: "虚构航图", contentType: "text", createTime: at,
                                  parentId: nil, childrenIds: ["trashed"], conversationId: window.id, profileId: "fictional")
        let trashed = MessageNode(id: "trashed", role: "assistant", content: "虚构删除句", contentType: "text", createTime: at,
                                  parentId: "visible", childrenIds: ["hidden"], conversationId: window.id, profileId: "fictional")
        trashed.isTrashed = true
        let hidden = MessageNode(id: "hidden", role: "user", content: "虚构隐藏句", contentType: "text", createTime: at,
                                 parentId: "trashed", childrenIds: [], conversationId: window.id, profileId: "fictional")
        hidden.sourceVisibility = "hidden"
        let off = MessageNode(id: "disabled", role: "user", content: "虚构关闭句", contentType: "text", createTime: at,
                              parentId: nil, childrenIds: [], conversationId: disabled.id, profileId: "fictional")
        for node in [visible, trashed, hidden, off] { context.insert(node) }
        try context.save()
        let items = [visible, trashed, hidden, off].map {
            TimelineDayRecord.Item(kind: .short, conversationId: $0.conversationId, window: "虚构航图窗",
                                   title: "虚构事件", start: at, end: at, from: $0.id, to: $0.id)
        }
        try TimelineStore.save(.init(days: [.init(date: "2026-11-05", headline: nil, items: items)]),
                               month: "2026-11", in: TimelineStore.dir(root: root))
        let loaded = await Task.detached {
            MemoryRecallBenchSource.load(profileId: "fictional", memoryRoot: root, container: container)
        }.value
        XCTAssertEqual(loaded.sources.filter { $0.kind == .node }.map(\.id),
                       [MemoryBenchRecallReader.key(node: visible.id, conversationId: window.id)])
        XCTAssertNil(loaded.errors[.node])
    }

    func testCorruptTimelineDoesNotBlockWikiOrCards() async throws {
        let root = try root()
        let wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        let page = wiki.root.appendingPathComponent("人/虚构.md")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# 虚构\n\n## 现在\n在云桥城画地图\n".utf8).write(to: page)
        try SeedNoteStore(wiki: wiki).save(.init(path: "cc/虚构.md", version: "v1", name: "虚构原料", layer: "CC",
            title: "虚构航图卡", gist: "在云桥城画图", mentions: [], aboutUser: false, group: "人", when: [],
            model: "offline", madeAt: Date(timeIntervalSince1970: 0), run: .init(path: "fictional", anchor: nil)))
        let dir = TimelineStore.dir(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<!-- day broken -->\n".utf8).write(to: dir.appendingPathComponent("2026-11.md"))
        let container = try ModelContainer(for: Conversation.self, MessageNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let loaded = await Task.detached {
            MemoryRecallBenchSource.load(profileId: "fictional", memoryRoot: root, container: container)
        }.value
        XCTAssertEqual(loaded.errors, [.node: "时间轴文件读不了"])
        XCTAssertEqual(loaded.sources.map(\.kind), [.page, .card])
        let source = try XCTUnwrap(loaded.sources.first { $0.kind == .page })
        let store = MemoryBenchStore(root: root.appendingPathComponent("bench"))
        try MemoryRecallBenchDraft(text: "虚构航图在哪里？", selections: [.init(source: source)]).save(
            names: .init(userName: "岚舟", assistantName: "星砚", timeZone: "UTC"),
            availableKeys: Set(loaded.sources.map(\.id)), store: store)
        XCTAssertEqual(store.floorSets().first?.cases.first?.labels.first?.keys, [source.id])
    }

    func testComposerRejectsUnlabelledAndContradictoryTurns() throws {
        let store = MemoryBenchStore(root: try root())
        let names = MemoryBenchRecallInput.Names(userName: "岚舟", assistantName: "星砚", timeZone: "UTC")
        var draft = MemoryRecallBenchDraft(text: "虚构航图在哪里？")
        XCTAssertThrowsError(try draft.save(names: names, availableKeys: [], store: store)) {
            XCTAssertEqual($0.localizedDescription, "至少选一个来源或打开『这句不该翻』")
        }
        let source = MemoryRecallBenchSource(id: "page:人/虚构|v1", title: "虚构", detail: "人/虚构", kind: .page)
        draft.selections = [.init(source: source, kind: "必须带", turn: 2)]
        draft.skip = true
        XCTAssertThrowsError(try draft.save(names: names, availableKeys: [source.id], store: store)) {
            XCTAssertEqual($0.localizedDescription, "不该翻的那句不能再要求必须带")
        }
        XCTAssertTrue(store.floorSets().isEmpty)
        draft.second = "再讲虚构航图"
        try draft.save(names: names, availableKeys: [source.id], store: store)
        XCTAssertEqual(store.floorSets().first?.cases.first?.labels.map(\.from), ["turn:2", "turn:1"])
    }

    func testConcurrentDraftAppendsPreserveEveryQuestion() async throws {
        let store = MemoryBenchStore(root: try root())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try MemoryRecallBenchDraft(text: "虚构句 \(index)", skip: true).save(
                        names: .init(userName: "岚舟", assistantName: "星砚", timeZone: "UTC"), availableKeys: [], store: store)
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(Set(store.floorSets().first?.cases.map(\.title) ?? []), Set((0..<12).map { "虚构句 \($0)" }))
    }

    func testFloorSnapshotIsExplicitlyRejectedBeforeReplay() async throws {
        let input = MemoryBenchRecallInput(snapshot: "floor", profile: .init(userName: "岚舟", assistantName: "星砚", timeZone: "UTC"), turns: [.init(text: "旧住处呢？")])
        let testCase = MemoryBenchCase(id: "floor-fictional", title: "虚构楼层题", input: try .from(input), labels: [])
        let recipe = try XCTUnwrap(MemoryBenchWriters.recallReader(profileId: "fictional").builtInRecipes(defaults: .standard).first)
        do {
            _ = try await MemoryBenchLocalExecutor.execute(testCase: testCase, recipe: recipe)
            XCTFail("不能把楼层题交给内置快照")
        } catch {
            XCTAssertEqual(error.localizedDescription, "本楼层快照还没接上，先用内置 24 题")
        }
    }

    func testOfflineRunnerAcceptsLocalReferenceWithoutRelaxingCloudWriterRule() async throws {
        guard Calendar.current.timeZone.identifier == "America/Los_Angeles" else { throw XCTSkip("内置快照要求 America/Los_Angeles") }
        let reader = MemoryBenchWriters.recallReader(profileId: "fictional")
        let recipe = try XCTUnwrap(reader.builtInRecipes(defaults: .standard).first)
        var set = try XCTUnwrap(MemoryBenchStore.builtInSets().first { $0.writer == "recall" })
        set.cases = [try XCTUnwrap(set.cases.first)]
        let model = MemoryBenchModelRef(credentialId: "local", modelId: "recall", name: "本地离线", local: true)
        XCTAssertThrowsError(try MemoryBenchRunner.jobs(cases: set.cases, recipes: [recipe], models: [model]))
        let result = try await MemoryBenchRunner.run(writer: reader, set: set, recipes: [recipe], models: [model],
            store: MemoryBenchStore(root: try root()), profileId: "fictional",
            caller: { _, _ in XCTFail("离线不应出站"); throw MemoryBenchLocalExecutor.Failure("出站") })
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.cells.map(\.caseId), set.cases.map(\.id))
        XCTAssertEqual(result.cells.compactMap(\.error), [])
        XCTAssertNil(result.cells.first?.usage)
        XCTAssertEqual(result.cells.first?.usd, 0)
    }
}
