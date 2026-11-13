import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

private final class ControlledCatalogEmbedder: MemoryEmbedding, @unchecked Sendable {
    let isReady = true
    let revision = 7
    private let lock = NSLock()
    private var texts: [String] = []
    var onEmbed: @Sendable (String) -> Void = { _ in }
    var calls: [String] { lock.withLock { texts } }

    func embed(_ text: String) -> [Float]? {
        lock.withLock { texts.append(text) }
        onEmbed(text)
        return [1, 0]
    }
}

@MainActor
final class CatalogRetrievalCancellationTests: XCTestCase {
    private var root: URL!
    private var container: ModelContainer!
    private var pid: String!

    override func setUp() async throws {
        pid = "catalog-cancel-synthetic-" + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(pid)
        let schema = Schema([Memory.self, Conversation.self, MessageNode.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: root)
    }

    private func insertFragments() throws {
        let context = ModelContext(container)
        for text in ["虚构第一份", "虚构第二份", "虚构第三份"] {
            let row = Memory(content: text, category: "fact", profileId: pid)
            row.occurredDay = "2026-10-12"
            row.reviewedAt = Date(timeIntervalSince1970: 1)
            context.insert(row)
        }
        try context.save()
    }

    func testBackfillCancellationDoesNotEncodeNextDocumentOrPersistPartialVector() async throws {
        try insertFragments()
        let token = CatalogCancel()
        let fake = ControlledCatalogEmbedder()
        fake.onEmbed = { _ in token.cancel() }
        let snapshot = await CatalogMaterial.snapshot(profileId: pid, container: container, embedder: fake, cancel: token)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(fake.calls.count, 1)
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).allSatisfy { $0.embeddingData == nil })
    }

    func testNativeTaskCancellationReachesDetachedQueryAndDiscardsSources() async {
        let entered = expectation(description: "查询编码已进入不可中断单元")
        let release = DispatchSemaphore(value: 0)
        let fake = ControlledCatalogEmbedder()
        fake.onEmbed = { _ in entered.fulfill(); release.wait() }
        var fragment = CatalogFragment(id: UUID(), content: "虚构云桥城", category: "fact", day: "2026-10-12")
        fragment.embeddingData = MemoryVector.data(from: [1, 0])
        fragment.embeddingRevision = 7
        let search = CatalogRetrieval(memoryRoot: root, fragments: [fragment], embedder: fake)
        let token = CatalogCancel()
        let task = Task { await search.search(["虚构云桥城"], fragmentsOnly: true, cancel: token) }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        release.signal()
        let result = await task.value
        XCTAssertTrue(token.isCancelled)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(result.fragments.isEmpty)
        XCTAssertTrue(result.receipt.bodies.isEmpty)
        XCTAssertEqual(result.vectorStatus, "已取消")
    }

    func testCancelledOriginalSearchDoesNotRegisterOrFuseReturnedNodes() async {
        let token = CatalogCancel()
        let node = SearchService.CatalogNode(profileId: pid, conversationId: "synthetic-window", nodeId: "synthetic-node",
                                              title: "虚构窗口", created: nil, role: "user", onMain: true, body: "虚构云桥城")
        let search = CatalogRetrieval(memoryRoot: root, fragments: [], embedder: CatalogFakeEmbedder.unavailable(),
                                      originalSearch: { _, _, shared in
                                          XCTAssertTrue(shared === token)
                                          shared.cancel()
                                          return [node]
                                      })
        let result = await search.search(["虚构云桥城"], cancel: token)
        XCTAssertTrue(result.originals.isEmpty)
        XCTAssertTrue(result.aline.hits.isEmpty)
        XCTAssertTrue(result.receipt.bodies.isEmpty)
    }

    func testAlreadyCancelledOriginalSkipsUnusableIndexAndScanFallback() async throws {
        let context = ModelContext(container)
        let nodeId = "cancelled-visible-node"
        let conversationId = "cancelled-visible-window"
        context.insert(Conversation(id: conversationId, title: "虚构窗口", createTime: Date(), updateTime: Date(),
                                    currentNodeId: nodeId, profileId: pid))
        context.insert(MessageNode(id: nodeId, role: "user", content: "虚构苹果 🍎", contentType: "text", createTime: Date(),
                                   parentId: nil, childrenIds: [], conversationId: conversationId, profileId: pid))
        try context.save()
        let index = try SearchIndexStore.open(at: root.appendingPathComponent("index.sqlite"))
        let visible = await SearchService.catalogContent(terms: ["🍎"], profileId: pid, container: container, index: index)
        XCTAssertEqual(visible.map(\.nodeId), [nodeId], "不可索引词正常回退时确实有原文")
        let token = CatalogCancel()
        token.cancel()
        let result = await SearchService.catalogContent(terms: ["🍎"], profileId: pid, container: container, index: index, cancel: token)
        XCTAssertTrue(result.isEmpty, "取消不能继续回退并交出已存在的原文")
    }

    func testAgentCancelDuringToolRetrievalStopsBeforeNextModelRequest() async {
        await agentCancellation(native: false)
    }

    func testAgentNativeTaskCancelDuringToolRetrievalStopsBeforeNextModelRequest() async {
        await agentCancellation(native: true)
    }

    private func agentCancellation(native: Bool) async {
        let entered = expectation(description: "Agent 工具已进入查询编码")
        let release = DispatchSemaphore(value: 0)
        let fake = ControlledCatalogEmbedder()
        fake.onEmbed = { _ in entered.fulfill(); release.wait() }
        let backend = FakeCatalogBackend { _, _ in
            .toolCalls([CatalogTestKit.call("search_aline", "{\"terms\":[\"虚构云桥城\"]}")])
        }
        let agent = CatalogAgent(deps: .init(makeBackend: { backend }, gate: { _ in nil }))
        var fragment = CatalogFragment(id: UUID(), content: "虚构云桥城", category: "fact", day: "2026-10-12")
        fragment.embeddingData = MemoryVector.data(from: [1, 0])
        fragment.embeddingRevision = 7
        let job = CatalogAgent.Job(topic: "虚构云桥城", profileId: pid, memoryRoot: root,
                                   names: CatalogTestKit.names, floorPrompt: "", snapshot: [fragment],
                                   modelName: "假模型", embedder: fake)
        let task = Task { await agent.run(job) }
        await fulfillment(of: [entered], timeout: 3)
        if native { task.cancel() } else { agent.cancel() }
        release.signal()
        let outcome = await task.value
        XCTAssertEqual(outcome.stop, .cancelled)
        XCTAssertEqual(outcome.searchedChars, 0)
        XCTAssertEqual(backend.requests.count, 1)
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(outcome.items.isEmpty)
    }

    func testRunnerStopDuringSnapshotReleasesFloorToWaitingSessionWithoutModelOrWriteback() async throws {
        try await runnerCancellation(native: false)
    }

    func testRunnerNativeTaskCancelDuringSnapshotReleasesFloorWithoutNextDocument() async throws {
        try await runnerCancellation(native: true)
    }

    private func runnerCancellation(native: Bool) async throws {
        try insertFragments()
        let entered = expectation(description: "第一份快照编码已开始")
        let successor = expectation(description: "同楼层下一会话取得锁")
        let release = DispatchSemaphore(value: 0)
        let fake = ControlledCatalogEmbedder()
        fake.onEmbed = { _ in entered.fulfill(); release.wait() }
        let backend = FakeCatalogBackend { _, _ in XCTFail("停止后不应调用模型"); return nil }
        var job = CatalogTestKit.job(pid: pid, root: root, container: container, caller: { _, _ in
            XCTFail("停止后不应调用写手")
            return nil
        }, backend: backend)
        job.embedder = fake
        let first = CatalogRunner()
        let second = CatalogRunner()
        let firstTask = Task { await first.start(job: job) { await $0.organizeTopic("虚构云桥城") } }
        await fulfillment(of: [entered], timeout: 3)
        let secondTask = Task {
            await second.start(job: job) { _ in
                successor.fulfill()
                return CatalogRunReport()
            }
        }
        // 等实际 Runner 已进入锁路径，而不是用 sleep 猜排队时机。
        while !second.isRunning { await Task.yield() }
        if native { firstTask.cancel() } else { first.cancel() }
        release.signal()
        await fulfillment(of: [successor], timeout: 3)
        await firstTask.value
        await secondTask.value
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertEqual(first.lastReport?.cancelled, true)
        let context = ModelContext(container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Memory>()).allSatisfy { $0.embeddingData == nil && $0.organizedAt == nil })
        XCTAssertTrue(WikiProposalStore(wiki: job.wiki).list().isEmpty)
    }
}
