import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

@MainActor
final class WikiDeletionTests: XCTestCase {
    private var root: URL!
    private var wiki: WikiStore!
    private var recallProfile: String?
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let path = "主题/纸舟城"
    private let text = "# 纸舟城\r\n\r\n## 现在\r\n虚构的夜航码头。\r\n"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-delete-\(UUID().uuidString)")
        wiki = WikiStore(root: root.appendingPathComponent("wiki"))
    }

    override func tearDown() async throws {
        if let recallProfile {
            CatalogRecallIndexer.shared.deleteProfile(recallProfile, wiki: wiki)
            try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: recallProfile)
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testConfirmationLoadsIncomingPagesBeforePresentation() async throws {
        let wiki = wiki!, path = path, text = text
        let target = try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            try wiki.save(WikiPage(path: "主题/虚构航图", kind: .topic, title: "虚构航图",
                links: [.init(target: path, relation: .citation, why: "虚构航路"),
                        .init(target: path, relation: .supplement, why: "同页第二条连线")]))
            try wiki.save(WikiPage(path: "主题/虚构灯塔", kind: .topic, title: "虚构灯塔",
                links: [.init(target: path, relation: .citation, why: "虚构灯火")]))
            return WikiDeletionTarget(profileId: "fictional-delete", store: wiki, path: path,
                title: "纸舟城", expectedVersion: version)
        }.value
        let confirmation = await WikiDeleteConfirmation.Confirmation.load(target)
        XCTAssertEqual(confirmation.incoming, 2, "按入链页计数，不按同一页的连线条数")
        XCTAssertEqual(confirmation.incomingMessage, "\n有 2 页连到这页，原文保留。")
        let unlinked = WikiDeletionTarget(profileId: target.profileId, store: wiki, path: "主题/虚构灯塔",
            title: "虚构灯塔", expectedVersion: try XCTUnwrap(wiki.version(of: "主题/虚构灯塔")))
        let empty = await WikiDeleteConfirmation.Confirmation.load(unlinked)
        XCTAssertEqual(empty.incoming, 0)
        XCTAssertEqual(empty.incomingMessage, "")
        XCTAssertEqual(wiki.readRaw(path), text, "统计不删页、不改入链原文")
        XCTAssertEqual(wiki.read("主题/虚构航图")?.links.map(\.target), [path, path])
    }

    func testDeleteConflictDoesNotTouchPageHistoryReceiptsOrIndexes() async throws {
        let wiki = wiki!, path = path, text = text
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            try wiki.rebuildIndexes(affecting: [path])
            let index = try Data(contentsOf: wiki.root.appendingPathComponent("INDEX.md"))
            for (target, expected) in [(path, "wrong"), ("主题/从未存在", version)] {
                XCTAssertThrowsError(try wiki.delete(target, expectedVersion: expected)) { error in
                    guard case WikiStore.WikiError.conflict = error else { return XCTFail("\(error)") }
                }
            }
            XCTAssertEqual(wiki.readRaw(path), text)
            XCTAssertEqual(wiki.history(path), [])
            XCTAssertEqual(wiki.deletions(), [])
            XCTAssertEqual(try Data(contentsOf: wiki.root.appendingPathComponent("INDEX.md")), index)
        }.value
    }

    func testBrowseRowVersionCannotDeletePageChangedSinceItWasShown() async throws {
        let wiki = wiki!, path = path, text = text
        try await Task.detached {
            try wiki.saveRaw(text, path: path)
            let row = try XCTUnwrap(wiki.browse("主题").first)
            try wiki.saveRaw("# 后来的人工稿", path: path)
            XCTAssertThrowsError(try wiki.delete(path, expectedVersion: try XCTUnwrap(row.version)))
            XCTAssertEqual(wiki.readRaw(path), "# 后来的人工稿")
            XCTAssertEqual(wiki.deletions(), [])
        }.value
    }

    func testDeletePreservesExactBytesCardsOtherPagesAndOldHistory() async throws {
        let wiki = wiki!, path = path, text = text, now = now
        try await Task.detached {
            try wiki.saveRaw("# 旧版本", path: path, now: now)
            let version = try wiki.saveRaw(text, path: path, now: now)
            let oldHistory = wiki.history(path)
            try wiki.saveRaw("# 远港\n不可改", path: "主题/远港")
            try SafeWiki.write(Data("虚构条目卡".utf8), name: "card.md", in: [".cards"], under: wiki.root)
            let receipt = try wiki.delete(path, expectedVersion: version, now: now).receipt
            XCTAssertEqual(receipt.phase, .deleted)
            XCTAssertEqual(receipt.path, path)
            XCTAssertEqual(receipt.deletedVersion, version)
            XCTAssertEqual(receipt.title, "纸舟城")
            XCTAssertFalse(wiki.pageExists(path))
            XCTAssertEqual(wiki.historyText(path, entry: receipt.historyEntry), text)
            XCTAssertEqual(wiki.history(path).filter { $0.name != receipt.historyEntry }, oldHistory)
            XCTAssertEqual(wiki.readRaw("主题/远港"), "# 远港\n不可改")
            XCTAssertEqual(SafeWiki.read("card.md", in: [".cards"], under: wiki.root), Data("虚构条目卡".utf8))
            let index = try String(contentsOf: wiki.root.appendingPathComponent("INDEX.md"), encoding: .utf8)
            XCTAssertFalse(index.contains(path))
            XCTAssertTrue(index.contains("主题/远港"))
            XCTAssertEqual(WikiStore(root: wiki.root).deletion(id: receipt.id), receipt)
        }.value
    }

    func testPreparedReceiptPrecedesRemovalAndCanResumeOrCancel() async throws {
        let wiki = wiki!, path = path, text = text, now = now
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            var preparedId = ""
            XCTAssertThrowsError(try wiki.delete(path, expectedVersion: version, now: now, beforeRemove: { url in
                let prepared = try XCTUnwrap(wiki.deletions().first)
                XCTAssertEqual(prepared.phase, .prepared)
                XCTAssertTrue(prepared.incomplete)
                XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
                throw CocoaError(.fileWriteNoPermission)
            }))
            let prepared = try XCTUnwrap(wiki.deletions().first)
            preparedId = prepared.id
            XCTAssertEqual(wiki.readRaw(path), text)
            XCTAssertEqual(wiki.history(path).map(\.name), [prepared.historyEntry])
            try wiki.continueDeletion(id: preparedId)
            XCTAssertFalse(wiki.pageExists(path))
            XCTAssertEqual(wiki.deletion(id: preparedId).phase, .deleted)
            XCTAssertEqual(wiki.history(path).map(\.name), [prepared.historyEntry])
            try wiki.restoreDeleted(id: preparedId, now: now)
            XCTAssertThrowsError(try wiki.delete(path, expectedVersion: version, now: now, beforeRemove: { _ in
                throw CocoaError(.fileWriteNoPermission)
            }))
            let next = try XCTUnwrap(wiki.deletions().first { $0.phase == .prepared })
            try SafeWiki.remove(next.historyEntry, in: [".history", "主题", "纸舟城"], under: wiki.root)
            let missingCopy = wiki.deletion(id: next.id)
            XCTAssertTrue(missingCopy.incomplete)
            XCTAssertThrowsError(try wiki.continueDeletion(id: next.id))
            try wiki.cancelDeletion(id: next.id)
            XCTAssertEqual(wiki.readRaw(path), text)
            XCTAssertEqual(wiki.deletions().map(\.id), [preparedId])
        }.value
    }

    func testPreparedWithMissingLivePageIsRecoverableButChangedLivePageIsNotDeleted() async throws {
        let wiki = wiki!, path = path, text = text
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            XCTAssertThrowsError(try wiki.delete(path, expectedVersion: version, beforeRemove: { _ in throw CocoaError(.fileWriteNoPermission) }))
            let receipt = try XCTUnwrap(wiki.deletions().first)
            try wiki.saveRaw("# 人工新页", path: path)
            let conflict = wiki.deletion(id: receipt.id)
            XCTAssertTrue(conflict.incomplete)
            XCTAssertEqual(conflict.phase, .prepared)
            XCTAssertThrowsError(try wiki.continueDeletion(id: receipt.id))
            XCTAssertThrowsError(try wiki.restoreDeleted(id: receipt.id))
            XCTAssertEqual(wiki.readRaw(path), "# 人工新页")
            try wiki.cancelDeletion(id: receipt.id)
            XCTAssertFalse(wiki.hasDeletionReceipt(for: path))
            XCTAssertEqual(wiki.historyText(path, entry: receipt.historyEntry), text)
            XCTAssertThrowsError(try wiki.delete(path, expectedVersion: wiki.version(of: path)!, beforeRemove: { _ in
                throw CocoaError(.fileWriteNoPermission)
            }))
            let missingLive = try XCTUnwrap(wiki.deletions().first)
            try FileManager.default.removeItem(at: wiki.checkedPageURL(path))
            XCTAssertEqual(wiki.deletion(id: missingLive.id).phase, .deleted)
            try wiki.restoreDeleted(id: missingLive.id)
            XCTAssertEqual(wiki.readRaw(path), "# 人工新页")
        }.value
    }

    func testRestoreExactCopyOnlyOnceAndRejectsEvenIdenticalNewPage() async throws {
        let wiki = wiki!, path = path, text = text, now = now
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            let receipt = try wiki.delete(path, expectedVersion: version).receipt
            try wiki.saveRaw(text, path: path)
            XCTAssertThrowsError(try wiki.restoreDeleted(id: receipt.id)) { XCTAssertEqual($0.localizedDescription, "已有同名页") }
            XCTAssertEqual(wiki.deletion(id: receipt.id).phase, .deleted)
            try FileManager.default.removeItem(at: wiki.checkedPageURL(path))
            try WikiStore(root: wiki.root).restoreDeleted(id: receipt.id, now: now)
            XCTAssertEqual(try Data(contentsOf: wiki.checkedPageURL(path)), Data(text.utf8))
            XCTAssertEqual(wiki.deletion(id: receipt.id).phase, .restored)
            XCTAssertEqual(wiki.deletion(id: receipt.id).restoredAt, now)
            try wiki.saveRaw("# 恢复后手改", path: path)
            XCTAssertThrowsError(try wiki.restoreDeleted(id: receipt.id))
            XCTAssertEqual(wiki.readRaw(path), "# 恢复后手改")
        }.value
    }

    func testMissingAlteredHistoryAndCorruptReceiptAreVisibleAndCannotRestore() async throws {
        let wiki = wiki!, path = path, text = text
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            let receipt = try wiki.delete(path, expectedVersion: version).receipt
            let history = try SafeWiki.folder([".history", "主题", "纸舟城"], under: wiki.root, create: false)
            let url = try SafeWiki.file(receipt.historyEntry, in: history)
            try Data("不匹配的副本".utf8).write(to: url)
            XCTAssertEqual(wiki.deletion(id: receipt.id).problem, "历史副本版本不符")
            XCTAssertThrowsError(try wiki.restoreDeleted(id: receipt.id))
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(wiki.deletion(id: receipt.id).problem, "历史副本缺失")
            XCTAssertThrowsError(try wiki.restoreDeleted(id: receipt.id)) { XCTAssertEqual($0.localizedDescription, "历史副本缺失") }
            try SafeWiki.write(Data("{broken".utf8), name: "bad.json", in: [".history", ".deleted"], under: wiki.root)
            XCTAssertEqual(Set(wiki.deletions().map(\.id)), [receipt.id, "bad"])
            XCTAssertTrue(wiki.deletion(id: "bad").problem?.hasPrefix("收据损坏") == true)
            XCTAssertFalse(wiki.pageExists(path))
        }.value
    }

    func testUnsafeReceiptAndHistorySymlinksCannotReadOrWriteOutsideWiki() async throws {
        let wiki = wiki!, path = path, text = text, root = root!
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            let receipt = try wiki.delete(path, expectedVersion: version).receipt
            let outside = root.appendingPathComponent("outside.md")
            try Data(text.utf8).write(to: outside)
            let url = wiki.historyURL(path).appendingPathComponent(receipt.historyEntry)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
            XCTAssertThrowsError(try wiki.restoreDeleted(id: receipt.id))
            XCTAssertFalse(wiki.pageExists(path))
            XCTAssertEqual(try Data(contentsOf: outside), Data(text.utf8))
            var unsafe = receipt
            unsafe.id = "unsafe"
            unsafe.historyEntry = "../../outside.md"
            try SafeWiki.write(JSONEncoder().encode(unsafe), name: "unsafe.json", in: [".history", ".deleted"], under: wiki.root)
            XCTAssertTrue(wiki.deletion(id: "unsafe").problem?.hasPrefix("收据损坏") == true)
            XCTAssertThrowsError(try wiki.restoreDeleted(id: "unsafe"))
        }.value
    }

    func testDeletionRejectsOldWindowSaveAndHistoryRestoreAndPreservesIncomingLinks() async throws {
        let wiki = wiki!, path = path, text = text
        let receipt = try await Task.detached {
            try wiki.saveRaw("# 更早版本", path: path)
            let version = try wiki.saveRaw(text, path: path)
            try wiki.save(WikiPage(path: "主题/远港", title: "远港", links: [.init(target: path, relation: .citation, why: "航线")]))
            XCTAssertEqual(wiki.incomingLinkCount(to: path), 1)
            let receipt = try wiki.delete(path, expectedVersion: version).receipt
            XCTAssertEqual(wiki.read("主题/远港")?.links.first?.target, path)
            XCTAssertTrue(wiki.hasDeletionReceipt(for: path))
            XCTAssertEqual(wiki.unavailablePageMessage(path), "原整理页已删除")
            XCTAssertEqual(wiki.unavailablePageMessage("主题/从未存在"), "目标页不可用")
            XCTAssertThrowsError(try wiki.restore(path, entry: receipt.historyEntry, expectedVersion: version))
            return receipt
        }.value
        do {
            try await WikiEditing.save("旧窗口新稿", baseline: text, store: wiki, path: path)
            XCTFail("旧窗口不得重建已删除页")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已被删除"))
        }
        try await Task.detached {
            XCTAssertFalse(wiki.pageExists(path))
            try wiki.restoreDeleted(id: receipt.id)
            XCTAssertEqual(wiki.read("主题/远港")?.links.first?.target, path)
            XCTAssertFalse(wiki.hasDeletionReceipt(for: path))
            XCTAssertNil(wiki.unavailablePageMessage(path))
        }.value
    }

    func testDeletionRefreshesInjectionAndRecallAndRestoreReturnsThem() async throws {
        let wiki = wiki!, path = path, text = text
        let pid = "xctest-delete-recall-\(UUID().uuidString)"
        recallProfile = pid
        let version = try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            try wiki.rebuildIndexes(affecting: [path])
            XCTAssertEqual(WikiInjection.load(wiki).pages.map(\.path), [path])
            return version
        }.value
        CatalogRecallIndexer.shared.ensure(profileId: pid, wiki: wiki)
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
        let index = try XCTUnwrap(CatalogRecallIndexer.shared.store(profileId: pid))
        let before = try await Task.detached { try index.search(terms: ["纸舟城"], profileId: pid).map(\.path) }.value
        XCTAssertEqual(before, [path])
        let receipt = try await Task.detached { try wiki.delete(path, expectedVersion: version).receipt }.value
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
        try await Task.detached {
            XCTAssertEqual(WikiInjection.load(wiki).pages, [])
            XCTAssertEqual(try index.search(terms: ["纸舟城"], profileId: pid).map(\.path), [])
            try wiki.restoreDeleted(id: receipt.id)
        }.value
        try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
        try await Task.detached {
            XCTAssertEqual(WikiInjection.load(wiki).pages.map(\.path), [path])
            XCTAssertEqual(try index.search(terms: ["纸舟城"], profileId: pid).map(\.path), [path])
        }.value
    }

    func testDeletedOrganizationStaysExcludedUntilOnlySelectedMarkIsReleased() async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let selected = Memory(content: "纸舟城夜航", category: "fact", profileId: "fictional")
        let other = Memory(content: "远港航线", category: "fact", profileId: "fictional")
        for memory in [selected, other] {
            memory.occurredDay = "2026-10-28"
            memory.reviewedAt = now
            memory.organizedPage = path
            memory.organizedAt = now
            context.insert(memory)
        }
        try context.save()
        XCTAssertFalse(CatalogMaterial.isCandidate(selected, excluding: []))
        XCTAssertThrowsError(try CatalogMaterial.releaseOrganization(selected, expectedPage: "主题/已变的页", profileId: "fictional", context: context))
        XCTAssertThrowsError(try CatalogMaterial.releaseOrganization(selected, expectedPage: path, profileId: "another-floor", context: context))
        let persisted = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Memory>()).first { $0.id == selected.id })
        XCTAssertEqual(persisted.organizedPage, path)
        XCTAssertEqual(persisted.organizedAt, now)
        XCTAssertEqual(selected.organizedPage, path)
        XCTAssertEqual(selected.organizedAt, now)
        try CatalogMaterial.releaseOrganization(selected, expectedPage: path, profileId: "fictional", context: context)
        XCTAssertNil(selected.organizedAt)
        XCTAssertNil(selected.organizedPage)
        XCTAssertEqual(selected.reviewedAt, now)
        XCTAssertEqual(other.organizedPage, path)
        XCTAssertEqual(other.organizedAt, now)
        XCTAssertTrue(CatalogMaterial.isCandidate(selected, excluding: []))
        XCTAssertFalse(CatalogMaterial.isCandidate(selected, excluding: [selected.id]))
        selected.organizeRejectedAt = now
        XCTAssertFalse(CatalogMaterial.isCandidate(selected, excluding: []))
    }

    func testReceiptCommitFailureAfterRemovalStillReturnsRecoverableDeletion() async throws {
        let wiki = wiki!, path = path, text = text
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            let outcome = try wiki.delete(path, expectedVersion: version, beforeRemove: { _ in
                let prepared = try XCTUnwrap(wiki.deletions().first)
                let url = wiki.root.appendingPathComponent(".history/.deleted/\(prepared.id).json")
                try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
            })
            let receipt = outcome.receipt
            let url = wiki.root.appendingPathComponent(".history/.deleted/\(receipt.id).json")
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
            XCTAssertFalse(wiki.pageExists(path))
            XCTAssertEqual(receipt.phase, .prepared)
            XCTAssertNotNil(receipt.problem)
            XCTAssertNil(outcome.indexError)
            let accounted = wiki.deletion(id: receipt.id)
            XCTAssertEqual(accounted.phase, .deleted)
            XCTAssertFalse(accounted.incomplete)
            XCTAssertNil(accounted.problem)
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            try wiki.restoreDeleted(id: receipt.id)
            XCTAssertEqual(wiki.readRaw(path), text)
        }.value
    }

    func testIndexFailureAfterRemovalReturnsReceiptAndInvalidatesLivePage() async throws {
        let wiki = wiki!, path = path, text = text
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            XCTAssertEqual(WikiInjection.load(wiki).pages.map(\.path), [path])
            try FileManager.default.createDirectory(at: wiki.folderURL("主题").appendingPathComponent("INDEX.md"), withIntermediateDirectories: false)
            let outcome = try wiki.delete(path, expectedVersion: version)
            XCTAssertNotNil(outcome.indexError)
            XCTAssertEqual(outcome.receipt.phase, .deleted)
            XCTAssertFalse(wiki.pageExists(path))
            XCTAssertEqual(wiki.deletion(id: outcome.receipt.id).deletedVersion, version)
            XCTAssertEqual(WikiInjection.load(wiki).pages, [])
        }.value
    }

    func testReceiptLookupDoesNotRequireReadableHistoryCopy() async throws {
        let wiki = wiki!, path = path, text = text
        try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            let receipt = try wiki.delete(path, expectedVersion: version).receipt
            try SafeWiki.remove(receipt.historyEntry, in: [".history", "主题", "纸舟城"], under: wiki.root)
            XCTAssertTrue(wiki.hasDeletionReceipt(for: path))
            XCTAssertEqual(wiki.unavailablePageMessage(path), "原整理页已删除")
            XCTAssertThrowsError(try wiki.restoreDeleted(id: receipt.id))
        }.value
    }

    func testActionSuccessLogsDeletionAndNotifiesBothConsumers() async throws {
        let wiki = wiki!, path = path, text = text
        let pid = "xctest-wiki-delete-action-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()) }
        let memory = expectation(description: "memory changed"), files = expectation(description: "files changed")
        let center = NotificationCenter.default
        let memoryToken = center.addObserver(forName: .memoryDidChange, object: nil, queue: nil) { _ in memory.fulfill() }
        let filesToken = center.addObserver(forName: .fileLibraryDidChange, object: nil, queue: nil) { _ in files.fulfill() }
        defer { center.removeObserver(memoryToken); center.removeObserver(filesToken) }
        let version = try await Task.detached { try wiki.saveRaw(text, path: path) }.value
        try await WikiDeletionAction.perform(.delete(path: path, version: version), store: wiki, profileId: pid)
        await fulfillment(of: [memory, files], timeout: 2)
        let entries = await Task.detached { MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) }.value
        XCTAssertFalse(wiki.pageExists(path))
        XCTAssertEqual(entries.map(\.ok), [true])
        XCTAssertTrue(try XCTUnwrap(entries.first).note.contains(path))
        let reason = await Task.detached { wiki.deletions().first?.reason }.value
        XCTAssertEqual(reason, "手动删除")
    }

    func testActionStoreFailureLogsPathAndNotifiesWithoutDeleting() async throws {
        let wiki = wiki!, path = path, text = text
        let pid = "xctest-wiki-delete-action-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()) }
        let memory = expectation(description: "memory changed"), files = expectation(description: "files changed")
        let center = NotificationCenter.default
        let memoryToken = center.addObserver(forName: .memoryDidChange, object: nil, queue: nil) { _ in memory.fulfill() }
        let filesToken = center.addObserver(forName: .fileLibraryDidChange, object: nil, queue: nil) { _ in files.fulfill() }
        defer { center.removeObserver(memoryToken); center.removeObserver(filesToken) }
        try await Task.detached { try wiki.saveRaw(text, path: path) }.value
        do {
            try await WikiDeletionAction.perform(.delete(path: path, version: "obsolete"), store: wiki, profileId: pid)
            XCTFail("版本冲突必须向调用方报错")
        } catch {
            guard case WikiStore.WikiError.conflict = error else { return XCTFail("\(error)") }
        }
        await fulfillment(of: [memory, files], timeout: 2)
        let entries = await Task.detached { MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) }.value
        XCTAssertEqual(wiki.readRaw(path), text)
        XCTAssertEqual(entries.map(\.ok), [false])
        XCTAssertTrue(try XCTUnwrap(entries.first).note.hasPrefix("删页 \(path)失败："))
    }

    func testActionIndexFailureReportsCommittedBodyAndReturnsToDeletionCaller() async throws {
        let wiki = wiki!, path = path, text = text
        let pid = "xctest-wiki-delete-action-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent()) }
        let memory = expectation(description: "memory changed"), files = expectation(description: "files changed")
        let center = NotificationCenter.default
        let memoryToken = center.addObserver(forName: .memoryDidChange, object: nil, queue: nil) { _ in memory.fulfill() }
        let filesToken = center.addObserver(forName: .fileLibraryDidChange, object: nil, queue: nil) { _ in files.fulfill() }
        defer { center.removeObserver(memoryToken); center.removeObserver(filesToken) }
        let version = try await Task.detached {
            let version = try wiki.saveRaw(text, path: path)
            try FileManager.default.createDirectory(at: wiki.folderURL("主题").appendingPathComponent("INDEX.md"), withIntermediateDirectories: false)
            return version
        }.value
        try await WikiDeletionAction.perform(.delete(path: path, version: version), store: wiki, profileId: pid)
        await fulfillment(of: [memory, files], timeout: 2)
        let entries = await Task.detached { MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)) }.value
        XCTAssertFalse(wiki.pageExists(path))
        XCTAssertEqual(entries.map(\.ok), [false])
        XCTAssertTrue(try XCTUnwrap(entries.first).note.contains(path))
        XCTAssertTrue(try XCTUnwrap(ToastCenter.shared.message).hasPrefix("正文已提交，索引更新失败："))
    }
}
