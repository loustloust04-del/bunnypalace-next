import MemoryCore
import XCTest
import SwiftData
@testable import 记忆花园

final class CatalogRecallIndexStoreTests: XCTestCase {
    private struct Fixture: Sendable {
        let root: URL
        let wiki: WikiStore
        let pid = "catalog-recall-" + UUID().uuidString
        var url: URL { CatalogRecallIndexStore.indexURL(wiki: wiki) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-recall-\(UUID().uuidString)")
            wiki = WikiStore(root: root.appendingPathComponent("memory/wiki"))
            try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
        }
        func card(_ path: String = "memory/cc/岚舟.md", version: String = "v1", title: String = "林栖",
                  gist: String = "岚舟", mentions: [SeedNoteCard.Mention] = []) throws -> SeedNoteCard {
            let card = SeedNoteCard(path: path, version: version, name: "林栖", layer: "CC", title: title, gist: gist,
                                    mentions: mentions, aboutUser: false, group: "人", when: [], model: "fixture",
                                    madeAt: Date(timeIntervalSince1970: 1000), run: .init(path: "fixture"))
            try SeedNoteStore(wiki: wiki).save(card)
            return card
        }
        func page(_ path: String = "人/林栖", now: String = "", records: [String] = [], cards: [SeedNoteCard] = []) throws {
            try wiki.saveRaw(WikiPage(path: path, title: "林栖", now: now, records: records,
                                     entries: cards.map { $0.path + "|" + $0.version }).markdown, path: path)
        }
        func ready() async throws -> CatalogRecallIndexStore {
            CatalogRecallIndexer.shared.ensure(profileId: pid, wiki: wiki)
            try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid)
            return try XCTUnwrap(CatalogRecallIndexer.shared.store(profileId: pid))
        }
        func idle() async throws { try await CatalogRecallIndexer.shared.waitUntilIdle(profileId: pid) }
        func clean() async {
            CatalogRecallIndexer.shared.deleteProfile(pid, wiki: wiki)
            try? await idle()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testRecordDomainMarkersDoNotBecomeSearchTerms() async throws {
        try await Task.detached {
            let f = try Fixture()
            try f.page(records: [
                "2026-10-09 · 设定 · 纸舟夜航（memory/cc/夜航.md）",
                "2026-10-09 · 收藏纸质海图（memory/cc/海图.md）"
            ])
            let store = try await f.ready()
            let hits = try store.search(terms: ["设定"], profileId: f.pid, kinds: [.page])
            XCTAssertTrue(hits.isEmpty, "机械域标记不能成为页面搜索词")
            XCTAssertEqual(try store.search(terms: ["夜航"], profileId: f.pid, kinds: [.page]).map(\.path), ["人/林栖"])
            XCTAssertEqual(try store.search(terms: ["海图"], profileId: f.pid, kinds: [.page]).map(\.path), ["人/林栖"])
            try f.page(records: [
                "2026-10-09 · 待判 · 纸舟夜航（memory/cc/夜航.md）",
                "2026-10-09 · 收藏设定图册（memory/cc/海图.md）"
            ])
            try await f.idle()
            XCTAssertTrue(try store.search(terms: ["待判"], profileId: f.pid, kinds: [.page]).isEmpty)
            XCTAssertEqual(try store.search(terms: ["设定"], profileId: f.pid, kinds: [.page]).map(\.path), ["人/林栖"],
                           "正文里的同词保留，不能把含标记字样的普通记录一并删掉")
            await f.clean()
        }.value
    }

    func testVerifiedPagesAndCardsProjectCurrentStoredDomains() async throws {
        try await Task.detached {
            let domains: [SeedFactDomain?] = [.realWorld, .inWorld, .mixed, .unspecified, nil]
            for domain in domains {
                let f = try Fixture()
                var card = try f.card(gist: "云桥城")
                card.factDomain = domain
                try SeedNoteStore(wiki: f.wiki).save(card)
                try f.wiki.saveRaw(WikiPage(path: "主题/云桥城", title: "云桥城", now: "云桥城",
                    entries: [card.path + "|" + card.version], factDomain: domain).markdown, path: "主题/云桥城")
                let store = try await f.ready()
                let snapshot = WikiInjection.load(f.wiki)
                let hits = store.verified(try store.search(terms: ["云桥城"], profileId: f.pid),
                                          snapshot: snapshot, maximumCount: 3)
                let pageHit = try XCTUnwrap(hits.first { $0.kind == .page })
                let cardHit = try XCTUnwrap(hits.first { $0.kind == .card })
                XCTAssertEqual(pageHit.factDomain, domain)
                XCTAssertEqual(cardHit.factDomain, domain)
                XCTAssertEqual(cardHit.card?.factDomain, domain)
                var replacement = card
                replacement.factDomain = domain == .inWorld ? .mixed : .inWorld
                try SeedNoteStore(wiki: f.wiki).save(replacement)
                let refreshed = try XCTUnwrap(store.verified([cardHit], snapshot: snapshot, maximumCount: 1).first)
                XCTAssertEqual(refreshed.factDomain, replacement.factDomain)
                XCTAssertEqual(refreshed.card?.factDomain, replacement.factDomain, "读卡时取 JSON 原值，不靠 SQL 或冻结上下文推断")
                await f.clean()
            }
        }.value
    }

    func testSeparateBodyAndCardFieldsReturnExactPublicParents() async throws {
        try await Task.detached {
            let f = try Fixture()
            let card = try f.card(gist: "云桥城", mentions: [.init(name: "星砚", group: "人", aliases: ["岚舟"])])
            try f.page(now: "星砚", records: ["云桥城"], cards: [card])
            let store = try await f.ready()
            let now = try XCTUnwrap(store.search(terms: ["星砚"], profileId: f.pid, kinds: [.page]).first)
            XCTAssertEqual(now.path, "人/林栖")
            XCTAssertEqual(now.terms, ["星砚"])
            XCTAssertEqual(now.identities.first, "林栖")
            XCTAssertEqual(try store.search(terms: ["云桥城"], profileId: f.pid, kinds: [.page]).first?.terms, ["云桥城"])
            for term in ["云桥城", "星砚", "岚舟"] {
                let hit = try XCTUnwrap(store.search(terms: [term], profileId: f.pid, kinds: [.card]).first)
                XCTAssertEqual(hit.path, card.path)
                XCTAssertEqual(hit.version, "v1")
                XCTAssertEqual(hit.cardKey, SeedNoteStore.key(path: card.path, version: "v1"))
                XCTAssertEqual(hit.terms, [term])
                XCTAssertTrue(hit.identities.contains("星砚"))
                XCTAssertTrue(hit.identities.contains("岚舟"))
                XCTAssertEqual(hit.parents, [.init(path: "人/林栖", version: try XCTUnwrap(f.wiki.version(of: "人/林栖")))])
            }
            XCTAssertEqual(try store.search(terms: ["岚"], profileId: f.pid, kinds: [.card]).count, 1)
            XCTAssertTrue(try store.search(terms: ["fixture", "1000"], profileId: f.pid).isEmpty)
            await f.clean()
        }.value
    }

    func testVerifiedCardsRejectDirectorySourcesAndNonDirectoryParents() async throws {
        try await Task.detached {
            let f = try Fixture()
            let directory = try f.card("memory/cc/星砚.md", gist: "云桥城")
            let blockedParent = try f.card("memory/cc/岚舟/星砚.md", gist: "云桥城")
            try f.page(cards: [directory, blockedParent])
            let store = try await f.ready()
            let hits = try store.search(terms: ["云桥城"], profileId: f.pid, kinds: [.card])
            XCTAssertEqual(Set(store.verified(hits, maximumCount: 2).map(\.path)), [directory.path, blockedParent.path])
            let cc = f.wiki.root.deletingLastPathComponent().appendingPathComponent("cc")
            try FileManager.default.createDirectory(at: cc.appendingPathComponent("星砚.md"), withIntermediateDirectories: true)
            try Data("不是文件夹".utf8).write(to: cc.appendingPathComponent("岚舟"))
            XCTAssertEqual(store.verified(hits, maximumCount: 2), [])
            await f.clean()
        }.value
    }

    func testUnapprovedOldCrossFloorPrivateLinkedAndEscapingSourcesNeverReturn() async throws {
        try await Task.detached {
            let f = try Fixture(), other = try Fixture()
            let current = try f.card(gist: "云桥城")
            _ = try f.card(version: "v0", gist: "星砚")
            _ = try f.card("memory/cc/孤卡.md", gist: "星砚")
            let privateCard = try f.card("memory/cc/PrIvAtE_岚舟/星砚.md", gist: "星砚")
            let escaping = try f.card("memory/../星砚.md", gist: "星砚")
            let linked = try f.card("memory/cc/星砚.md", gist: "星砚")
            let linkedJSON = try f.card("memory/cc/林栖.md", gist: "星砚")
            let linkedURL = SeedNoteStore(wiki: f.wiki).url(path: linkedJSON.path, version: linkedJSON.version)
            let outside = f.root.appendingPathComponent("outside.json")
            try FileManager.default.moveItem(at: linkedURL, to: outside)
            try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: outside)
            let cc = f.wiki.root.deletingLastPathComponent().appendingPathComponent("cc")
            try FileManager.default.createDirectory(at: cc, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: cc.appendingPathComponent("星砚.md"), withDestinationURL: outside)
            try f.page(now: "云桥城\n星砚 [[人/PRIVATE_岚舟]]", cards: [current, privateCard, escaping, linked, linkedJSON])
            try f.page("人/PrIvAtE_岚舟/星砚", now: "星砚")
            try FileManager.default.createSymbolicLink(at: f.wiki.root.appendingPathComponent("人/星砚.md"),
                                                     withDestinationURL: f.wiki.root.appendingPathComponent("人/林栖.md"))
            try other.page(now: "星砚", cards: [try other.card(gist: "星砚")])
            let store = try await f.ready(), otherStore = try await other.ready()
            XCTAssertEqual(Set(try store.search(terms: ["云桥城"], profileId: f.pid).map(\.kind)), [.page, .card])
            XCTAssertTrue(try store.search(terms: ["星砚"], profileId: f.pid).isEmpty)
            XCTAssertTrue(try store.search(terms: ["星砚"], profileId: other.pid).isEmpty)
            XCTAssertEqual(try otherStore.search(terms: ["星砚"], profileId: other.pid).count, 2)
            do {
                let db = try SQLiteDB(url: f.url)
                let insert = try db.prepare("""
                    INSERT INTO catalog_doc(docId,profileId,kind,sourcePath,sourceVersion,approved,isCurrent,updatedAt,
                        title,triggers,hook,now,records,gist,mentions)
                    VALUES('private-old',?,'page','人/PRIVATE_星砚','v1',1,1,1,?,'','','','','','')
                    """)
                insert.bind(1, f.pid); insert.bind(2, SearchTextSegmenter.segment("星砚")); try insert.run()
                XCTAssertTrue(try store.search(terms: ["星砚"], profileId: f.pid).isEmpty)
            }
            await f.clean(); await other.clean()
        }.value
    }

    func testApprovalAddsCardAndRevocationRemovesOnlyItsIndexDocument() async throws {
        try await Task.detached {
            let f = try Fixture()
            let card = try f.card(gist: "云桥城")
            try f.page()
            let store = try await f.ready()
            XCTAssertTrue(try store.search(terms: ["云桥城"], profileId: f.pid).isEmpty)
            var task = CatalogSeedTask(id: UUID().uuidString, profileId: f.pid, entry: .cc, modelName: "fixture",
                                       createdAt: Date(), run: .init(path: "fixture"))
            task.read = [card.path: card.version]; task.carded = task.read
            try CatalogSeedTaskStore(wiki: f.wiki).save(task)
            var proposal = WikiProposal(origin: .seed, createdAt: Date(), items: [
                .init(change: .appendRecords(path: "人/林栖", lines: ["岚舟（出处：\(card.path)）"]),
                      baseVersion: f.wiki.version(of: "人/林栖"))
            ])
            proposal.seedTask = task.id
            try WikiProposalStore(wiki: f.wiki).save(proposal)
            try await Self.approve(proposal.id, fixture: f)
            try await f.idle()
            let hit = try XCTUnwrap(store.search(terms: ["云桥城"], profileId: f.pid).first)
            XCTAssertEqual(hit.kind, .card)
            XCTAssertEqual(hit.parents.map(\.path), ["人/林栖"])
            try f.page()
            try await f.idle()
            XCTAssertTrue(try store.search(terms: ["云桥城"], profileId: f.pid).isEmpty)
            XCTAssertEqual(SeedNoteStore(wiki: f.wiki).load(path: card.path, version: card.version), card)
            await f.clean()
        }.value
    }

    @MainActor private static func approve(_ id: String, fixture: Fixture) async throws {
        let schema = ProfileManager.makeFullSchema()
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        try await WikiProposalReview.approve(id, store: WikiProposalStore(wiki: fixture.wiki), profileId: fixture.pid,
                                             context: ModelContext(container))
    }

    func testEditsMoveHistoryDeletionAndExternalReconcileReplaceCurrentIdentity() async throws {
        try await Task.detached {
            let f = try Fixture()
            try f.page(now: "岚舟")
            let store = try await f.ready()
            let original = try XCTUnwrap(store.search(terms: ["岚舟"], profileId: f.pid).first)
            try f.page(now: "星砚")
            try await f.idle()
            XCTAssertTrue(try store.search(terms: ["岚舟"], profileId: f.pid).isEmpty)
            XCTAssertNotEqual(try store.search(terms: ["星砚"], profileId: f.pid).first?.version, original.version)
            let history = try XCTUnwrap(f.wiki.history("人/林栖").last)
            try f.wiki.restore("人/林栖", entry: history.name, expectedVersion: f.wiki.version(of: "人/林栖"))
            try await f.idle()
            XCTAssertEqual(try store.search(terms: ["岚舟"], profileId: f.pid).first?.version, original.version)
            let proposal = WikiProposal(origin: .manual, createdAt: Date(), items: [
                .init(change: .regroup(layer: "人", groups: [], moves: [.init(from: "人/林栖", to: "人/云桥城")]), baseVersion: nil)
            ])
            try WikiProposalStore(wiki: f.wiki).save(proposal)
            try await Self.approve(proposal.id, fixture: f)
            try await f.idle()
            XCTAssertEqual(try store.search(terms: ["岚舟"], profileId: f.pid).map(\.path), ["人/云桥城"])
            let url = try f.wiki.pageURL("人/云桥城")
            try Data(WikiPage(path: "人/云桥城", title: "林栖", now: "星砚").markdown.utf8).write(to: url)
            let stale = try store.search(terms: ["岚舟"], profileId: f.pid)
            XCTAssertTrue(store.verified(stale, maximumCount: 1).isEmpty)
            try await CatalogRecallIndexer.shared.reconcile(profileId: f.pid)
            XCTAssertEqual(try store.search(terms: ["星砚"], profileId: f.pid).map(\.path), ["人/云桥城"])
            try FileManager.default.removeItem(at: url)
            try await CatalogRecallIndexer.shared.reconcile(profileId: f.pid)
            XCTAssertTrue(try store.search(terms: ["星砚"], profileId: f.pid).isEmpty)
            try f.page("人/云桥城", now: "岚舟")
            try await f.idle()
            let legacy = WikiProposal(origin: .seed, createdAt: Date(), items: [
                .init(state: .approved, change: .newPage(page: WikiPage(path: "人/云桥城", title: "林栖")))
            ])
            try WikiProposalStore(wiki: f.wiki).save(legacy)
            _ = try CatalogSeedCleanup.run(memoryRoot: f.wiki.root.deletingLastPathComponent(), wiki: f.wiki, now: Date())
            try await f.idle()
            XCTAssertTrue(try store.search(terms: ["岚舟"], profileId: f.pid).isEmpty)
            await f.clean()
        }.value
    }

    func testDeletingOneFloorPreservesOtherIndexAndAllCards() async throws {
        try await Task.detached {
            let f = try Fixture(), other = try Fixture()
            let card = try f.card(), otherCard = try other.card()
            try f.page(cards: [card]); try other.page(cards: [otherCard])
            let store = try await f.ready(), otherStore = try await other.ready()
            CatalogRecallIndexer.shared.deleteProfile(f.pid, wiki: f.wiki)
            try await f.idle()
            for suffix in ["", "-wal", "-shm"] { XCTAssertFalse(FileManager.default.fileExists(atPath: f.url.path + suffix)) }
            XCTAssertTrue(try store.search(terms: ["岚舟"], profileId: f.pid).isEmpty)
            XCTAssertEqual(try otherStore.search(terms: ["岚舟"], profileId: other.pid).map(\.path), [otherCard.path])
            XCTAssertEqual(SeedNoteStore(wiki: f.wiki).load(path: card.path, version: card.version), card)
            XCTAssertEqual(SeedNoteStore(wiki: other.wiki).load(path: otherCard.path, version: otherCard.version), otherCard)
            await f.clean(); await other.clean()
        }.value
    }

    func testFailedTransactionDoesNotPublishPartialParentSet() async throws {
        try await Task.detached {
            let f = try Fixture()
            let card = try f.card(gist: "岚舟")
            try f.page(cards: [card]); try f.page("人/星砚", cards: [card])
            let store = try await f.ready()
            let db = try SQLiteDB(url: f.url)
            try db.exec("CREATE TRIGGER fail_parent BEFORE INSERT ON catalog_parent WHEN new.pagePath='人/星砚' BEGIN SELECT RAISE(ABORT,'fixture'); END")
            let epoch = try store.status(profileId: f.pid).epoch
            XCTAssertThrowsError(try store.rebuild())
            XCTAssertEqual(try store.status(profileId: f.pid).epoch, epoch)
            XCTAssertThrowsError(try store.update(paths: ["人/林栖", "人/星砚"], epoch: epoch))
            let hit = try XCTUnwrap(store.search(terms: ["岚舟"], profileId: f.pid).first)
            XCTAssertEqual(hit.parents.map(\.path), ["人/星砚", "人/林栖"])
            XCTAssertEqual(try store.status(profileId: f.pid).state, .ready)
            try db.exec("DROP TRIGGER fail_parent")
            try db.close()
            await f.clean()
        }.value
    }

    func testVersionOneIndexIsDiscardedOnOpen() async throws {
        try await Task.detached {
            let f = try Fixture()
            try f.page(records: ["2026-10-09 · 设定 · 纸舟夜航（memory/cc/夜航.md）"])
            var store: CatalogRecallIndexStore? = try CatalogRecallIndexStore.open(profileId: f.pid, wiki: f.wiki)
            try store?.rebuild()
            store = nil
            do {
                let db = try SQLiteDB(url: f.url)
                let version = try db.prepare("UPDATE meta SET value='1' WHERE profileId=? AND key='version'")
                version.bind(1, f.pid); try version.run()
                try db.exec("UPDATE catalog_doc SET records='设定'")
                try db.exec("INSERT INTO catalog_fts(catalog_fts) VALUES('rebuild')")
                XCTAssertEqual(try db.scalarText("SELECT value FROM meta WHERE key='version'"), "1")
                XCTAssertEqual(try db.scalarText("SELECT records FROM catalog_doc"), "设定")
            }
            store = try CatalogRecallIndexStore.open(profileId: f.pid, wiki: f.wiki)
            do {
                let db = try SQLiteDB(url: f.url)
                XCTAssertEqual(try db.scalarText("SELECT value FROM meta WHERE key='version'"), "2")
                XCTAssertEqual(try db.scalarText("SELECT count(*) FROM catalog_doc"), "0", "旧索引的机械标记必须随整库丢弃")
            }
            XCTAssertEqual(try store?.status(profileId: f.pid), .init(state: .empty, epoch: 0))
            store = nil
            await f.clean()
        }.value
    }

    func testVersionMismatchAndCorruptionRebuildWithoutTouchingSourceFiles() async throws {
        try await Task.detached {
            for corrupt in [false, true] {
                let f = try Fixture()
                let card = try f.card(gist: "岚舟")
                try f.page(cards: [card])
                var store: CatalogRecallIndexStore? = try CatalogRecallIndexStore.open(profileId: f.pid, wiki: f.wiki)
                try store?.rebuild()
                store = nil
                if corrupt {
                    CatalogRecallIndexStore.removeFiles(at: f.url)
                    try Data("not sqlite".utf8).write(to: f.url)
                } else {
                    let db = try SQLiteDB(url: f.url)
                    let s = try db.prepare("UPDATE meta SET value='obsolete' WHERE profileId=? AND key='version'")
                    s.bind(1, f.pid); try s.run()
                }
                let recovered = try await f.ready()
                XCTAssertEqual(try recovered.search(terms: ["岚舟"], profileId: f.pid).map(\.path), [card.path])
                XCTAssertEqual(SeedNoteStore(wiki: f.wiki).load(path: card.path, version: card.version), card)
                XCTAssertEqual(f.wiki.read("人/林栖")?.entries, [card.path + "|" + card.version])
                await f.clean()
            }
        }.value
    }

    func testSharedCardReturnsOneDocumentWithBothCurrentParents() async throws {
        try await Task.detached {
            let f = try Fixture()
            let card = try f.card(gist: "岚舟")
            try f.page(cards: [card]); try f.page("人/星砚", cards: [card])
            let store = try await f.ready()
            let hits = try store.search(terms: ["岚舟"], profileId: f.pid)
            XCTAssertEqual(hits.map(\.path), [card.path])
            XCTAssertEqual(hits.first?.parents.map(\.path), ["人/星砚", "人/林栖"])
            try f.page()
            try await f.idle()
            XCTAssertEqual(try store.search(terms: ["岚舟"], profileId: f.pid).first?.parents.map(\.path), ["人/星砚"])
            await f.clean()
        }.value
    }

    func testLazyEnableAndEpochRejectStaleBatch() async throws {
        try await Task.detached {
            let f = try Fixture()
            try f.page(now: "岚舟")
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.url.path))
            XCTAssertEqual(CatalogRecallIndexer.shared.status(profileId: f.pid).state, .empty)
            CatalogRecallIndexer.shared.ensure(profileId: f.pid, wiki: f.wiki)
            CatalogRecallIndexer.shared.ensure(profileId: f.pid, wiki: f.wiki)
            let store = try await f.ready()
            let epoch = try store.status(profileId: f.pid).epoch
            XCTAssertEqual(epoch, 1)
            try store.rebuild()
            XCTAssertEqual(try store.status(profileId: f.pid).epoch, epoch + 1)
            XCTAssertFalse(try store.update(paths: ["人/林栖"], epoch: epoch))
            XCTAssertEqual(try store.search(terms: ["岚舟"], profileId: f.pid).map(\.path), ["人/林栖"])
            await f.clean()
        }.value
    }

    func testUntrustedWikiRootDoesNotCreateAnIndex() async throws {
        try await Task.detached {
            let f = try Fixture(), other = try Fixture()
            try other.page(now: "岚舟")
            try FileManager.default.removeItem(at: f.wiki.root)
            try FileManager.default.createSymbolicLink(at: f.wiki.root, withDestinationURL: other.wiki.root)
            CatalogRecallIndexer.shared.ensure(profileId: f.pid, wiki: f.wiki)
            do {
                try await f.idle()
                XCTFail("linked wiki must be refused")
            } catch CatalogRecallIndexStore.IndexError.refused {}
            XCTAssertEqual(CatalogRecallIndexer.shared.status(profileId: f.pid).state, .empty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.url.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: other.url.path))
            await f.clean(); await other.clean()
        }.value
    }
    func testBuildingIndexExposesStatusWithoutPublishingCommittedOldHits() async throws {
        try await Task.detached {
            let f = try Fixture()
            try f.page(now: "cedar maple")
            let store = try await f.ready()
            let db = try SQLiteDB(url: f.url)
            do {
                let update = try db.prepare("UPDATE meta SET value='building' WHERE profileId=? AND key='state'")
                update.bind(1, f.pid)
                try update.run()
            }
            XCTAssertEqual(try store.status(profileId: f.pid).state, .building)
            XCTAssertEqual(try store.search(terms: ["cedar", "maple"], profileId: f.pid), [])
            XCTAssertEqual(try store.queryWeights(terms: ["cedar"], profileId: f.pid), [:])
            try db.close()
            await f.clean()
        }.value
    }

}
