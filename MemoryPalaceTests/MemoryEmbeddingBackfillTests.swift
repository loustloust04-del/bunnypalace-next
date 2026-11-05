import XCTest
import SwiftData
@testable import 记忆花园

private final class CallbackMemoryEmbedder: MemoryEmbedding, @unchecked Sendable {
    let isReady = true
    let revision = 7
    private let callback: (String) throws -> [Float]?
    private let lock = NSLock()
    private var texts: [String] = []
    private var errors: [String] = []

    init(_ callback: @escaping (String) throws -> [Float]?) {
        self.callback = callback
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }

    func embed(_ text: String) -> [Float]? {
        lock.lock()
        texts.append(text)
        lock.unlock()
        do { return try callback(text) }
        catch {
            lock.lock()
            errors.append(error.localizedDescription)
            lock.unlock()
            return nil
        }
    }
}

@MainActor
final class MemoryEmbeddingBackfillTests: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema([Memory.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func insert(_ text: String, context: ModelContext, fragment: Bool = true) -> Memory {
        let row = Memory(content: text, category: "fact", keywords: [text], profileId: "backfill-floor")
        if fragment {
            row.occurredDay = "2026-10-12"
            row.reviewedAt = Date(timeIntervalSince1970: 1)
        }
        context.insert(row)
        return row
    }

    func testC3SnapshotRefetchesEditedBodyAndDoesNotCommitOldVector() async throws {
        let container = try container()
        let context = ModelContext(container)
        let row = insert("old orbit", context: context)
        let id = row.id
        try context.save()
        let sweepBefore = MemoryEmbeddingBackfill.edgesSweepDone
        let embedder = CallbackMemoryEmbedder { _ in
            let editor = ModelContext(container)
            let row = try XCTUnwrap(editor.fetch(FetchDescriptor<Memory>()).first { $0.id == id })
            row.content = "new lantern"
            row.keywords = ["new"]
            try editor.save()
            return [1, 0]
        }

        let snapshot = await CatalogMaterial.snapshot(profileId: "backfill-floor", container: container, embedder: embedder)

        XCTAssertEqual(embedder.failures, [])
        XCTAssertEqual(embedder.calls, ["old orbit"])
        XCTAssertEqual(snapshot.map(\.id), [id])
        XCTAssertEqual(snapshot.first?.content, "new lantern")
        XCTAssertEqual(snapshot.first?.keywords, ["new"])
        XCTAssertNil(snapshot.first?.embeddingData)
        XCTAssertNil(snapshot.first?.embeddingRevision)
        let fresh = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Memory>()).first)
        XCTAssertEqual(fresh.content, "new lantern")
        XCTAssertNil(fresh.embeddingData)
        XCTAssertNil(fresh.embeddingRevision)
        XCTAssertTrue(fresh.relatedIds.isEmpty)
        XCTAssertEqual(MemoryEmbeddingBackfill.edgesSweepDone, sweepBefore)
    }

    func testC3BackfillSkipsMovedDeletedAndNewlyIneligibleRows() async throws {
        let container = try container()
        let context = ModelContext(container)
        let mutations = ["moved", "deleted", "unreviewed", "superseded", "early", "archive"]
        for text in mutations + ["retained"] { _ = insert(text, context: context) }
        try context.save()
        let embedder = CallbackMemoryEmbedder { text in
            let editor = ModelContext(container)
            let row = try XCTUnwrap(editor.fetch(FetchDescriptor<Memory>()).first { $0.content == text })
            switch text {
            case "moved": row.profileId = "another-floor"
            case "deleted": editor.delete(row)
            case "unreviewed": row.reviewedAt = nil
            case "superseded": row.supersededAt = Date(timeIntervalSince1970: 2)
            case "early": row.occurredDay = "2026-09-30"
            case "archive": row.occurredDay = nil
            default: break
            }
            try editor.save()
            return [1, 0]
        }

        let snapshot = await CatalogMaterial.snapshot(profileId: "backfill-floor", container: container, embedder: embedder)

        XCTAssertEqual(embedder.failures, [])
        XCTAssertEqual(Set(embedder.calls), Set(mutations + ["retained"]))
        XCTAssertEqual(embedder.calls.count, 7)
        XCTAssertEqual(snapshot.map(\.content), ["retained"])
        XCTAssertEqual(snapshot.first?.embeddingRevision, 7)
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(fresh.count, 6)
        XCTAssertFalse(fresh.contains { $0.content == "deleted" })
        XCTAssertEqual(fresh.first { $0.content == "moved" }?.profileId, "another-floor")
        XCTAssertTrue(fresh.filter { $0.content != "retained" }.allSatisfy { $0.embeddingData == nil && $0.embeddingRevision == nil })
        XCTAssertTrue(fresh.allSatisfy { $0.relatedIds.isEmpty })
    }

    func testChatPersistenceUsesSameContentFloorAndAliveGuardWithoutC3Cutoff() throws {
        let container = try container()
        let staleContext = ModelContext(container)
        let names = ["edited", "moved", "deleted", "superseded", "legacy"]
        let rows = names.map { insert($0, context: staleContext, fragment: false) }
        try staleContext.save()
        let snapshots = rows.map(MemoryRetrievalDocument.init)
        let embedder = CallbackMemoryEmbedder { text in
            let editor = ModelContext(container)
            let row = try XCTUnwrap(editor.fetch(FetchDescriptor<Memory>()).first { $0.content == text })
            switch text {
            case "edited": row.content = "replacement"
            case "moved": row.profileId = "another-floor"
            case "deleted": editor.delete(row)
            case "superseded": row.supersededAt = Date(timeIntervalSince1970: 2)
            default: break
            }
            try editor.save()
            return [1, 0]
        }
        let filled = MemoryEmbeddingBackfill.fill(snapshots, embedder: embedder)
        let written = try MemoryEmbeddingBackfill.persist(filled.documents, container: container, revision: 7)

        XCTAssertEqual(embedder.failures, [])
        XCTAssertEqual(embedder.calls, names)
        XCTAssertEqual(written, [rows[4].id])
        let fresh = try ModelContext(container).fetch(FetchDescriptor<Memory>())
        XCTAssertEqual(fresh.count, 4)
        XCTAssertTrue(fresh.filter { $0.content != "legacy" }.allSatisfy { $0.embeddingData == nil && $0.embeddingRevision == nil })
        XCTAssertEqual(fresh.first { $0.content == "replacement" }?.id, rows[0].id)
        XCTAssertEqual(fresh.first { $0.content == "moved" }?.profileId, "another-floor")
        let legacy = try XCTUnwrap(fresh.first { $0.content == "legacy" })
        XCTAssertNil(legacy.occurredDay)
        XCTAssertNil(legacy.reviewedAt)
        XCTAssertEqual(legacy.embeddingData, MemoryVector.data(from: [1, 0]))
        XCTAssertEqual(legacy.embeddingRevision, 7)
    }

    func testAllDocumentEncodingFailuresRemainUnavailableWithLexicalFallbackAndNoRetry() {
        let document = MemoryRetrievalDocument(id: UUID(), content: "orbit marble", keywords: [])
        let embedder = CallbackMemoryEmbedder { $0 == "orbit" ? [1, 0] : nil }
        let filled = MemoryEmbeddingBackfill.fill([document, document], embedder: embedder)
        XCTAssertEqual(filled.documents.map(\.id), [document.id, document.id])
        XCTAssertEqual(filled.failedCount, 1)
        XCTAssertEqual(filled.validVectorCount, 0)
        let result = MemoryRetrieval.search(query: "orbit", documents: filled.documents, embedder: embedder)
        XCTAssertEqual(result.ids, [document.id])
        XCTAssertEqual(result.vectorStatus, "向量不可用（1 条没算出来）")
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.validVectorCount, 0)
        XCTAssertEqual(embedder.calls, [document.content, "orbit"])
    }

    func testPartialDocumentEncodingFailuresReportUniqueCoverageAndPreserveLexicalHits() {
        let failed = MemoryRetrievalDocument(id: UUID(), content: "orbit marble", keywords: [])
        let stale = MemoryRetrievalDocument(id: UUID(), content: "orbit stale", keywords: [],
                                            embeddingData: MemoryVector.data(from: [1, 0]), embeddingRevision: 6)
        let valid = MemoryRetrievalDocument(id: UUID(), content: "velvet lantern", keywords: [])
        let embedder = CallbackMemoryEmbedder { ["velvet lantern", "orbit"].contains($0) ? [1, 0] : nil }
        let filled = MemoryEmbeddingBackfill.fill([failed, stale, valid, failed], embedder: embedder)
        XCTAssertEqual(filled.failedCount, 2)
        XCTAssertEqual(filled.validVectorCount, 1)
        XCTAssertEqual(filled.documents.count, 4)
        XCTAssertEqual(filled.documents[1].embeddingRevision, 6)
        let result = MemoryRetrieval.search(query: "orbit", documents: filled.documents, embedder: embedder)
        XCTAssertEqual(Set(result.ids), Set([failed.id, stale.id, valid.id]))
        XCTAssertEqual(result.ids.count, 3)
        XCTAssertEqual(result.vectorStatus, "向量部分不可用（2 条没算出来），命中 1 条")
        XCTAssertEqual(result.failedCount, 2)
        XCTAssertEqual(result.validVectorCount, 1)
        XCTAssertEqual(embedder.calls, [failed.content, stale.content, valid.content, "orbit"])
    }
}
