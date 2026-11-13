import Foundation

public final class CatalogRecallIndexStore: @unchecked Sendable {
    public static let schemaVersion = "2"
    public static let fileName = ".recall-index.sqlite"

    public enum Kind: String, Sendable, CaseIterable { case page, card }
    public enum State: String, Sendable { case empty, building, ready }
    public struct Status: Equatable, Sendable {
        public let state: State
        public let epoch: Int64

        public init(state: State, epoch: Int64) {
            self.state = state
            self.epoch = epoch
        }
    }
    public struct Parent: Equatable, Sendable {
        public let path: String
        public let version: String

        public init(path: String, version: String) {
            self.path = path
            self.version = version
        }
    }
    public struct Hit: Equatable, Sendable {
        public let docId: String
        public let kind: Kind
        public let path: String
        public let version: String
        public let cardKey: String?
        public let parents: [Parent]
        public let terms: Set<String>
        public let identities: [String]
        public let updatedAt: Date
        public let card: RecallFullTextCandidates.Card?
        public let bm25: Double
        public var factDomain: SeedFactDomain? = nil

        public init(docId: String, kind: Kind, path: String, version: String, cardKey: String?, parents: [Parent], terms: Set<String>, identities: [String], updatedAt: Date, card: RecallFullTextCandidates.Card?, bm25: Double, factDomain: SeedFactDomain? = nil) {
            self.docId = docId
            self.kind = kind
            self.path = path
            self.version = version
            self.cardKey = cardKey
            self.parents = parents
            self.terms = terms
            self.identities = identities
            self.updatedAt = updatedAt
            self.card = card
            self.bm25 = bm25
            self.factDomain = factDomain
        }
    }
    public enum IndexError: Error { case versionMismatch, integrityFailed, retired, refused }

    public let url: URL
    public let profileId: String
    private let wiki: WikiStore
    private let writer: SQLiteDB
    private let writeQueue = DispatchQueue(label: "com.susu.MemoryPalace.catalog-recall.writer", qos: .utility)
    private let readerLock = NSCondition()
    private var idleReaders: [SQLiteDB] = []
    private var activeReaders = 0
    private var closing = false
    private var retired = false

    public static func indexURL(wiki: WikiStore) -> URL {
        wiki.root.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    public static func removeFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    public static func open(profileId: String, wiki: WikiStore) throws -> CatalogRecallIndexStore {
        MainThreadIO.assertOffMain(.write, "CatalogRecallIndexStore.open")
        let url = indexURL(wiki: wiki)
        guard (try? SafeWiki.itemType(wiki.root.deletingLastPathComponent())) == .typeDirectory,
              (try? SafeWiki.itemType(wiki.root)) == .typeDirectory else { throw IndexError.refused }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            if let type = try SafeWiki.itemType(URL(fileURLWithPath: url.path + suffix)), type != .typeRegular {
                throw IndexError.refused
            }
        }
        do { return try CatalogRecallIndexStore(profileId: profileId, wiki: wiki) }
        catch {
            removeFiles(at: url)
            return try CatalogRecallIndexStore(profileId: profileId, wiki: wiki)
        }
    }

    private init(profileId: String, wiki: WikiStore) throws {
        self.profileId = profileId
        self.wiki = wiki
        url = Self.indexURL(wiki: wiki)
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        writer = try SQLiteDB(url: url)
        try writer.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL")
        if !isNew {
            guard try writer.scalarText("PRAGMA quick_check") == "ok" else { throw IndexError.integrityFailed }
            guard try meta("version", db: writer) == Self.schemaVersion else { throw IndexError.versionMismatch }
            try writer.exec("INSERT INTO catalog_fts(catalog_fts, rank) VALUES('integrity-check', 1)")
        }
        try writer.exec("""
            CREATE TABLE IF NOT EXISTS meta(profileId TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
                PRIMARY KEY(profileId, key));
            CREATE TABLE IF NOT EXISTS catalog_doc(
                id INTEGER PRIMARY KEY, docId TEXT NOT NULL, profileId TEXT NOT NULL,
                kind TEXT NOT NULL CHECK(kind IN ('page','card')), sourcePath TEXT NOT NULL,
                sourceVersion TEXT NOT NULL, cardKey TEXT, pagePath TEXT,
                approved INTEGER NOT NULL, isCurrent INTEGER NOT NULL, updatedAt REAL NOT NULL, madeAt REAL,
                title TEXT NOT NULL, triggers TEXT NOT NULL, hook TEXT NOT NULL, now TEXT NOT NULL,
                records TEXT NOT NULL, gist TEXT NOT NULL, mentions TEXT NOT NULL,
                UNIQUE(profileId, docId));
            CREATE TABLE IF NOT EXISTS catalog_parent(
                profileId TEXT NOT NULL, pagePath TEXT NOT NULL, pageVersion TEXT NOT NULL,
                sourcePath TEXT NOT NULL, sourceVersion TEXT NOT NULL,
                PRIMARY KEY(profileId, pagePath, sourcePath, sourceVersion));
            CREATE INDEX IF NOT EXISTS catalog_parent_source ON catalog_parent(profileId, sourcePath, sourceVersion);
            CREATE VIRTUAL TABLE IF NOT EXISTS catalog_fts USING fts5(
                profileId UNINDEXED, title, triggers, hook, now, records, gist, mentions,
                content='catalog_doc', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS catalog_insert AFTER INSERT ON catalog_doc BEGIN
                INSERT INTO catalog_fts(rowid, profileId, title, triggers, hook, now, records, gist, mentions)
                VALUES(new.id, new.profileId, new.title, new.triggers, new.hook, new.now, new.records, new.gist, new.mentions);
            END;
            CREATE TRIGGER IF NOT EXISTS catalog_delete AFTER DELETE ON catalog_doc BEGIN
                INSERT INTO catalog_fts(catalog_fts, rowid, profileId, title, triggers, hook, now, records, gist, mentions)
                VALUES('delete', old.id, old.profileId, old.title, old.triggers, old.hook, old.now, old.records, old.gist, old.mentions);
            END;
            """)
        for (key, value) in [("version", Self.schemaVersion), ("epoch", "0"), ("state", State.empty.rawValue)] {
            let s = try writer.prepare("INSERT OR IGNORE INTO meta(profileId,key,value) VALUES(?,?,?)")
            s.bind(1, profileId); s.bind(2, key); s.bind(3, value)
            try s.run()
        }
    }

    private func meta(_ key: String, db: SQLiteDB) throws -> String? {
        let s = try db.prepare("SELECT value FROM meta WHERE profileId=? AND key=?")
        s.bind(1, profileId); s.bind(2, key)
        return try s.step() ? s.text(0) : nil
    }

    private func setMeta(_ key: String, _ value: String) throws {
        let s = try writer.prepare("UPDATE meta SET value=? WHERE profileId=? AND key=?")
        s.bind(1, value); s.bind(2, profileId); s.bind(3, key)
        try s.run()
    }

    public func status(profileId: String) throws -> Status {
        MainThreadIO.assertOffMain(.read, "CatalogRecallIndexStore.status")
        guard profileId == self.profileId else { return Status(state: .empty, epoch: 0) }
        do {
            return try withReader { db in
                try db.exec("BEGIN")
                defer { try? db.exec("ROLLBACK") }
                return Status(state: State(rawValue: try meta("state", db: db) ?? "") ?? .empty,
                              epoch: Int64(try meta("epoch", db: db) ?? "0") ?? 0)
            }
        } catch IndexError.retired {
            return Status(state: .empty, epoch: 0)
        }
    }

    public func rebuild(snapshot: SafeWiki? = nil) throws {
        MainThreadIO.assertOffMain(.enumerate, "CatalogRecallIndexStore.rebuild")
        try writeQueue.sync {
            guard !retired else { throw IndexError.retired }
            let previous = try meta("state", db: writer) ?? State.empty.rawValue
            try setMeta("state", State.building.rawValue)
            do {
                let safe = snapshot ?? SafeWiki.scan(wiki, memoryRoot: wiki.root.deletingLastPathComponent())
                guard safe.refused == nil else { throw IndexError.refused }
                try writer.transaction {
                    try deleteAll()
                    try replace(pages: safe.pages, removing: [])
                    let epoch = Int64(try meta("epoch", db: writer) ?? "0") ?? 0
                    try setMeta("epoch", String(epoch + 1))
                    try setMeta("state", State.ready.rawValue)
                }
            } catch {
                try? setMeta("state", previous)
                throw error
            }
        }
    }

    @discardableResult
    public func update(paths: Set<String>, epoch: Int64) throws -> Bool {
        MainThreadIO.assertOffMain(.write, "CatalogRecallIndexStore.update")
        return try writeQueue.sync {
            guard !retired, Int64(try meta("epoch", db: writer) ?? "0") == epoch else { return false }
            let pages = paths.compactMap { Self.readPage($0, wiki: wiki) }
            try writer.transaction { try replace(pages: pages, removing: paths.sorted()) }
            return true
        }
    }

    public func reconcile() throws {
        MainThreadIO.assertOffMain(.enumerate, "CatalogRecallIndexStore.reconcile")
        try writeQueue.sync {
            guard !retired else { throw IndexError.retired }
            let safe = SafeWiki.scan(wiki, memoryRoot: wiki.root.deletingLastPathComponent())
            let current = safe.refused == nil ? safe.pages : []
            var indexed: [String: String] = [:]
            let s = try writer.prepare("SELECT sourcePath,sourceVersion FROM catalog_doc WHERE profileId=? AND kind='page'")
            s.bind(1, profileId)
            while try s.step() { if let path = s.text(0) { indexed[path] = s.text(1) } }
            let changed = current.filter { indexed[$0.path] != $0.version }
            let removed = Set(indexed.keys).subtracting(current.map(\.path))
            try writer.transaction { try replace(pages: changed, removing: removed.sorted()) }
        }
    }

    public func invalidate() throws {
        MainThreadIO.assertOffMain(.write, "CatalogRecallIndexStore.invalidate")
        try writeQueue.sync {
            guard !retired else { return }
            retired = true
            readerLock.lock()
            closing = true
            while activeReaders > 0 { readerLock.wait() }
            let readers = idleReaders
            idleReaders.removeAll()
            readerLock.unlock()
            for reader in readers { try reader.close() }
            try writer.transaction {
                try deleteAll()
                let epoch = Int64(try meta("epoch", db: writer) ?? "0") ?? 0
                try setMeta("epoch", String(epoch + 1))
                try setMeta("state", State.empty.rawValue)
            }
            try writer.close()
        }
    }

    private func deleteAll() throws {
        for table in ["catalog_parent", "catalog_doc"] {
            let s = try writer.prepare("DELETE FROM \(table) WHERE profileId=?")
            s.bind(1, profileId); try s.run()
        }
    }

    private func replace(pages: [SafeWiki.Page], removing: [String]) throws {
        for path in Set(removing + pages.map(\.path)).sorted() {
            for sql in ["DELETE FROM catalog_parent WHERE profileId=? AND pagePath=?",
                        "DELETE FROM catalog_doc WHERE profileId=? AND kind='page' AND sourcePath=?"] {
                let s = try writer.prepare(sql)
                s.bind(1, profileId); s.bind(2, path); try s.run()
            }
        }
        let cards = SeedNoteStore(wiki: wiki)
        var indexedCards = Set<String>()
        for source in pages where Self.publicPath(source.path) {
            let page = source.page
            try insert(kind: .page, path: source.path, version: source.version, cardKey: nil, madeAt: nil,
                       texts: [page.title, page.triggers.joined(separator: "\n"), page.hook, page.now,
                               page.records.map(CatalogSeedTools.recordIndexText).joined(separator: "\n"), "", ""])
            for entry in Set(page.entries ?? []).sorted() {
                guard let ref = Self.reference(entry), Self.safeSource(ref.path, wiki: wiki) else { continue }
                if !indexedCards.contains(entry) {
                    guard let card = cards.load(path: ref.path, version: ref.version),
                          card.path == ref.path, card.version == ref.version else { continue }
                    let del = try writer.prepare("DELETE FROM catalog_doc WHERE profileId=? AND kind='card' AND sourcePath=? AND sourceVersion=?")
                    del.bind(1, profileId); del.bind(2, ref.path); del.bind(3, ref.version); try del.run()
                    try insert(kind: .card, path: ref.path, version: ref.version,
                               cardKey: SeedNoteStore.key(path: ref.path, version: ref.version), madeAt: card.madeAt,
                               texts: [card.title, "", "", "", "", card.gist,
                                       card.mentions.flatMap { [$0.name] + ($0.aliases ?? []) }.joined(separator: "\n")])
                    indexedCards.insert(entry)
                }
                let parent = try writer.prepare("INSERT INTO catalog_parent(profileId,pagePath,pageVersion,sourcePath,sourceVersion) VALUES(?,?,?,?,?)")
                parent.bind(1, profileId); parent.bind(2, source.path); parent.bind(3, source.version)
                parent.bind(4, ref.path); parent.bind(5, ref.version); try parent.run()
            }
        }
        let orphan = try writer.prepare("""
            DELETE FROM catalog_doc WHERE profileId=? AND kind='card' AND NOT EXISTS(
                SELECT 1 FROM catalog_parent p WHERE p.profileId=? AND p.profileId=catalog_doc.profileId
                AND p.sourcePath=catalog_doc.sourcePath AND p.sourceVersion=catalog_doc.sourceVersion)
            """)
        orphan.bind(1, profileId); orphan.bind(2, profileId); try orphan.run()
    }

    private func insert(kind: Kind, path: String, version: String, cardKey: String?, madeAt: Date?, texts: [String]) throws {
        let s = try writer.prepare("""
            INSERT INTO catalog_doc(docId,profileId,kind,sourcePath,sourceVersion,cardKey,pagePath,approved,isCurrent,updatedAt,madeAt,
                title,triggers,hook,now,records,gist,mentions) VALUES(?,?,?,?,?,?,?,1,1,?,?,?,?,?,?,?,?,?)
            """)
        let identity = kind == .page ? path : path + "|" + version
        s.bind(1, profileId + "|" + kind.rawValue + "|" + identity)
        s.bind(2, profileId); s.bind(3, kind.rawValue); s.bind(4, path); s.bind(5, version)
        s.bind(6, cardKey); s.bind(7, kind == .page ? path : nil)
        let modified = kind == .page ? wiki.modifiedAt(path) : madeAt
        s.bind(8, (modified ?? Date()).timeIntervalSince1970)
        s.bind(9, madeAt?.timeIntervalSince1970)
        for (offset, text) in texts.enumerated() {
            s.bind(Int32(offset + 10), SearchTextSegmenter.segment(WikiProposalSources.strippingPrivateLinks(text)))
        }
        try s.run()
    }

    public func search(terms: [String], profileId: String, kinds: Set<Kind> = Set(Kind.allCases),
                isFinished: @Sendable () -> Bool = { false }) throws -> [Hit] {
        MainThreadIO.assertOffMain(.read, "CatalogRecallIndexStore.search")
        guard profileId == self.profileId, !kinds.isEmpty,
              readerLock.withLock({ !closing }), !isFinished() else { return [] }
        let queries = terms.compactMap { term in
            SearchTextSegmenter.ftsQuery(for: term).map { (term: term, query: String($0.dropLast())) }
        }
        guard !queries.isEmpty else { return [] }
        return try withReader { db in
            try db.exec("BEGIN")
            defer { try? db.exec("ROLLBACK") }
            guard try meta("state", db: db) == State.ready.rawValue else { return [] }
            var evidence: [String: Set<String>] = [:]
            for (term, query) in queries {
                guard !isFinished() else { return [] }
                let s = try db.prepare("""
                    SELECT d.docId FROM catalog_fts JOIN catalog_doc d ON d.id=catalog_fts.rowid
                    WHERE catalog_fts MATCH ? AND d.profileId=? AND d.approved=1 AND d.isCurrent=1
                    """)
                s.bind(1, query); s.bind(2, profileId)
                var documents = Set<String>()
                while !isFinished(), try s.step() {
                    if let id = s.text(0) { documents.insert(id) }
                }
                evidence[term] = documents
            }
            let parents = try indexedParents(db: db, isFinished: isFinished)
            let s = try db.prepare("""
                SELECT d.docId,d.kind,d.sourcePath,d.sourceVersion,d.cardKey,bm25(catalog_fts),
                    CASE WHEN d.kind='card' THEN (
                        SELECT max(page.updatedAt) FROM catalog_parent p JOIN catalog_doc page
                        ON page.profileId=p.profileId AND page.kind='page' AND page.sourcePath=p.pagePath
                        AND page.sourceVersion=p.pageVersion
                        WHERE p.profileId=? AND p.sourcePath=d.sourcePath AND p.sourceVersion=d.sourceVersion
                    ) ELSE d.updatedAt END,d.title,d.triggers,d.gist,d.mentions
                FROM catalog_fts JOIN catalog_doc d ON d.id=catalog_fts.rowid
                WHERE catalog_fts MATCH ? AND d.profileId=? AND d.approved=1 AND d.isCurrent=1
                AND d.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))
                ORDER BY bm25(catalog_fts),d.docId
                """)
            s.bind(1, profileId); s.bind(2, queries.map(\.query).joined(separator: " OR ")); s.bind(3, profileId)
            for (offset, kind) in kinds.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
                s.bind(Int32(offset + 4), kind.rawValue)
            }
            var hits: [Hit] = []
            while !isFinished(), try s.step() {
                guard let docId = s.text(0), let kind = Kind(rawValue: s.text(1) ?? ""),
                      let path = s.text(2), let version = s.text(3), Self.publicPath(path) else { continue }
                let identities = [Self.identityText(s.text(7) ?? "")]
                    + Self.identityText(s.text(kind == .page ? 8 : 10) ?? "").components(separatedBy: "\n")
                hits.append(Hit(docId: docId, kind: kind, path: path, version: version, cardKey: s.text(4),
                                parents: parents[path + "|" + version] ?? [],
                                terms: Set(queries.compactMap { evidence[$0.term]?.contains(docId) == true ? $0.term : nil }),
                                identities: identities, updatedAt: Date(timeIntervalSince1970: s.optionalDouble(6) ?? 0),
                                card: nil, bm25: s.optionalDouble(5) ?? 0))
            }
            return hits
        }
    }

    // Undo only segment()'s inserted spaces; original identity whitespace remains significant.
    private static func identityText(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var afterSplit = false
        for scalar in text.unicodeScalars {
            if afterSplit, scalar == " " { afterSplit = false; continue }
            let value = scalar.value
            let split = value >= 0x3000 && (scalar.properties.isIdeographic
                || (0x3040...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value))
            if split, result.last == " " { result.removeLast() }
            result.append(scalar)
            afterSplit = split
        }
        return String(result)
    }

    private func indexedParents(db: SQLiteDB, isFinished: @Sendable () -> Bool) throws -> [String: [Parent]] {
        let s = try db.prepare("""
            SELECT sourcePath,sourceVersion,pagePath,pageVersion FROM catalog_parent WHERE profileId=? ORDER BY pagePath
            """)
        s.bind(1, profileId)
        var parents: [String: [Parent]] = [:]
        while !isFinished(), try s.step() {
            guard let path = s.text(0), let version = s.text(1), let page = s.text(2), let pageVersion = s.text(3),
                  Self.publicPath(path), Self.publicPath(page) else { continue }
            parents[path + "|" + version, default: []].append(.init(path: page, version: pageVersion))
        }
        return parents
    }

    public func retained(_ sources: [RecallSourceRef], snapshot: WikiInjectionSnapshot,
                  isFinished: @Sendable () -> Bool = { false }) throws -> [Hit] {
        MainThreadIO.assertOffMain(.read, "CatalogRecallIndexStore.retained")
        let parents = try withReader { try indexedParents(db: $0, isFinished: isFinished) }
        let hits = Set(sources).sorted { $0.path == $1.path ? $0.version < $1.version : $0.path < $1.path }.compactMap { ref -> Hit? in
            guard ref.profileId == profileId, ref.kind == .card, Self.publicPath(ref.path),
                  let parents = parents[ref.path + "|" + ref.version], !parents.isEmpty else { return nil }
            return Hit(docId: profileId + "|card|" + ref.path + "|" + ref.version, kind: .card,
                       path: ref.path, version: ref.version, cardKey: SeedNoteStore.key(path: ref.path, version: ref.version),
                       parents: parents, terms: [], identities: [], updatedAt: .distantPast, card: nil, bm25: 0)
        }
        return verified(hits, snapshot: snapshot, maximumCount: hits.count, isFinished: isFinished)
    }

    public func verified(_ hits: [Hit], snapshot: WikiInjectionSnapshot? = nil, maximumCount: Int,
                  isFinished: @Sendable () -> Bool = { false }, onRead: ((String) -> Void)? = nil) -> [Hit] {
        MainThreadIO.assertOffMain(.read, "CatalogRecallIndexStore.verified")
        let versions = snapshot.map { Dictionary($0.pages.map { ($0.path, $0.version) }, uniquingKeysWith: { first, _ in first }) }
        var pages: [String: SafeWiki.Page] = [:]
        var missing = Set<String>()
        func readPage(_ path: String) -> SafeWiki.Page? {
            if let page = pages[path] { return page }
            guard !isFinished(), !missing.contains(path) else { return nil }
            onRead?(path)
            guard let page = Self.readPage(path, wiki: wiki) else { missing.insert(path); return nil }
            pages[path] = page
            return page
        }
        var result: [Hit] = []
        for hit in hits {
            guard result.count < maximumCount, !isFinished() else { break }
            guard Self.publicPath(hit.path) else { continue }
            if hit.kind == .page {
                guard versions == nil || versions?[hit.path] == hit.version,
                      let page = readPage(hit.path), page.version == hit.version else { continue }
                result.append(Hit(docId: hit.docId, kind: hit.kind, path: hit.path, version: hit.version, cardKey: nil,
                                  parents: [], terms: hit.terms, identities: [page.page.title] + page.page.triggers,
                                  updatedAt: hit.updatedAt, card: nil, bm25: hit.bm25, factDomain: page.page.factDomain))
            } else {
                guard Self.safeSource(hit.path, wiki: wiki),
                      hit.cardKey == SeedNoteStore.key(path: hit.path, version: hit.version) else { continue }
                var parents: [Parent] = []
                var updatedAt = Date.distantPast
                for parent in hit.parents {
                    guard !isFinished() else { break }
                    guard versions == nil || versions?[parent.path] == parent.version,
                          let page = readPage(parent.path), page.version == parent.version,
                          page.page.entries?.contains(hit.path + "|" + hit.version) == true else { continue }
                    parents.append(parent)
                    updatedAt = max(updatedAt, wiki.modifiedAt(parent.path) ?? .distantPast)
                }
                guard !parents.isEmpty, !isFinished() else { continue }
                onRead?(SeedNoteStore.folderName + "/" + (hit.cardKey ?? ""))
                guard let card = SeedNoteStore(wiki: wiki).load(path: hit.path, version: hit.version),
                      card.path == hit.path, card.version == hit.version else { continue }
                let clean = WikiProposalSources.strippingPrivateLinks
                let mentions = card.mentions.flatMap { [$0.name] + ($0.aliases ?? []) }.map(clean).filter { !$0.isEmpty }
                result.append(Hit(docId: hit.docId, kind: hit.kind, path: hit.path, version: hit.version, cardKey: hit.cardKey,
                                  parents: parents, terms: hit.terms, identities: [clean(card.title)] + mentions,
                                  updatedAt: updatedAt, card: .init(title: clean(card.title), gist: clean(card.gist), mentions: mentions,
                                                                  factDomain: card.factDomain),
                                  bm25: hit.bm25, factDomain: card.factDomain))
            }
        }
        return result
    }

    public func queryWeights(terms: [String], profileId: String,
                      isFinished: @Sendable () -> Bool = { false }) throws -> [String: Double] {
        MainThreadIO.assertOffMain(.read, "CatalogRecallIndexStore.queryWeights")
        guard profileId == self.profileId else { return [:] }
        return try withReader { db in
            try db.exec("BEGIN")
            defer { try? db.exec("ROLLBACK") }
            guard try meta("state", db: db) == State.ready.rawValue else { return [:] }
            let count = try db.prepare("SELECT count(*) FROM catalog_doc WHERE profileId=? AND approved=1 AND isCurrent=1")
            count.bind(1, profileId)
            guard try count.step() else { return [:] }
            let total = count.optionalDouble(0) ?? 0
            var weights: [String: Double] = [:]
            for term in terms {
                guard !isFinished() else { return [:] }
                guard let query = SearchTextSegmenter.ftsQuery(for: term) else { continue }
                let frequency = try db.prepare("""
                    SELECT count(*) FROM catalog_fts JOIN catalog_doc d ON d.id=catalog_fts.rowid
                    WHERE catalog_fts MATCH ? AND d.profileId=? AND d.approved=1 AND d.isCurrent=1
                    """)
                frequency.bind(1, String(query.dropLast())); frequency.bind(2, profileId)
                if try frequency.step() {
                    weights[term] = log((total + 1) / ((frequency.optionalDouble(0) ?? 0) + 1)) + 1
                }
            }
            return weights
        }
    }

    public static func publicPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !WikiProposalSources.isPrivate(path)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    public static func reference(_ entry: String) -> (path: String, version: String)? {
        guard let sep = entry.lastIndex(of: "|") else { return nil }
        let path = String(entry[..<sep]), version = String(entry[entry.index(after: sep)...])
        guard publicPath(path), !version.isEmpty else { return nil }
        return (path, version)
    }

    public static func readPage(_ path: String, wiki: WikiStore) -> SafeWiki.Page? {
        guard publicPath(path), WikiStore.isValidPagePath(path) else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last,
              let data = SafeWiki.read(name + ".md", in: Array(parts.dropLast()), under: wiki.root) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return SafeWiki.Page(path: path, text: text, version: WikiStore.version(of: data), page: WikiPage.parse(text, path: path))
    }

    public static func safeSource(_ path: String, wiki: WikiStore) -> Bool {
        guard publicPath(path) else { return false }
        guard path.hasPrefix("memory/") else { return true }
        var url = wiki.root.deletingLastPathComponent()
        let parts = path.dropFirst("memory/".count).split(separator: "/")
        for (i, part) in parts.enumerated() {
            url.appendPathComponent(String(part))
            do {
                guard let type = try SafeWiki.itemType(url) else { return true }
                guard type == (i == parts.count - 1 ? .typeRegular : .typeDirectory) else { return false }
            } catch { return false }
        }
        return true
    }

    private func withReader<T>(_ body: (SQLiteDB) throws -> T) throws -> T {
        readerLock.lock()
        guard !closing else { readerLock.unlock(); throw IndexError.retired }
        let pooled = idleReaders.popLast()
        activeReaders += 1
        readerLock.unlock()
        var reader: SQLiteDB?
        defer {
            readerLock.lock()
            if let reader {
                if !closing && idleReaders.count < 4 { idleReaders.append(reader) }
                else { try? reader.close() }
            }
            activeReaders -= 1
            readerLock.broadcast()
            readerLock.unlock()
        }
        let db = try pooled ?? SQLiteDB(url: url, readOnly: true)
        reader = db
        return try body(db)
    }
}
