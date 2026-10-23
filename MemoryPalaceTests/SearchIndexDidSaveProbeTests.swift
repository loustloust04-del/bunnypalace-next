import XCTest
import SwiftData
@testable import 记忆花园

/// S5 Todo 3 探针：ModelContext.didSave 覆盖面（结论见 docs/review-search-s5.md「探针结论」）
final class SearchIndexDidSaveProbeTests: XCTestCase {

    private var tokens: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var saves: [(inserted: [PersistentIdentifier], updated: [PersistentIdentifier], deleted: [PersistentIdentifier], keys: [String])] = []

    override func setUp() {
        super.setUp()
        tokens.append(NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { [weak self] n in
            guard let self else { return }
            let info = n.userInfo ?? [:]
            func ids(_ key: ModelContext.NotificationKey) -> [PersistentIdentifier] {
                (info[key.rawValue] as? [PersistentIdentifier] ?? []).filter { $0.entityName == "MessageNode" }
            }
            lock.lock()
            saves.append((ids(.insertedIdentifiers), ids(.updatedIdentifiers), ids(.deletedIdentifiers),
                          info.keys.map { "\($0)" }.sorted()))
            lock.unlock()
        })
    }

    override func tearDown() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        super.tearDown()
    }

    private func drain() -> [(inserted: [PersistentIdentifier], updated: [PersistentIdentifier], deleted: [PersistentIdentifier], keys: [String])] {
        lock.lock()
        defer { saves = []; lock.unlock() }
        return saves
    }

    private func key(_ id: PersistentIdentifier) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try! e.encode(id), as: UTF8.self)
    }

    func testUnsortedEncodingKeyOrderIsUnstable() throws {
        let container = try memoryContainer()
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let n = node("k1")
        ctx.insert(n)
        try ctx.save()
        let id = n.persistentModelID
        let variants = Set((0..<50).map { _ in String(decoding: try! JSONEncoder().encode(id), as: UTF8.self) })
        print("[PROBE] unsorted JSONEncoder distinct encodings of one identifier over 50 runs = \(variants.count)")
        XCTAssertEqual(Set((0..<50).map { _ in key(id) }).count, 1)
    }

    private func node(_ id: String, conv: String = "c1", pid: String = "p1", content: String = "x") -> MessageNode {
        MessageNode(id: id, role: "user", content: content, contentType: "text", createTime: Date(),
                    parentId: nil, childrenIds: [], conversationId: conv, profileId: pid)
    }

    private func memoryContainer() throws -> ModelContainer {
        try ModelContainer(for: Conversation.self, MessageNode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testPlainSaveInsertUpdateDelete() throws {
        let container = try memoryContainer()
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let n = node("n1")
        ctx.insert(n)
        try ctx.save()
        let afterInsert = drain()
        let savedKey = key(n.persistentModelID)
        n.content = "改了"
        try ctx.save()
        let afterUpdate = drain()
        ctx.delete(n)
        try ctx.save()
        let afterDelete = drain()
        print("[PROBE] plain insert=\(afterInsert.map { $0.inserted.count }) keys=\(afterInsert.first?.keys ?? [])")
        print("[PROBE] plain update=\(afterUpdate.map { $0.updated.count })")
        print("[PROBE] plain delete=\(afterDelete.map { $0.deleted.count }) keyMatch=\(afterDelete.first?.deleted.first.map { key($0) == savedKey } ?? false)")
        print("[PROBE] insertedKeyMatchesModelID=\(afterInsert.first?.inserted.first.map { key($0) == savedKey } ?? false)")
        XCTAssertEqual(afterInsert.first?.inserted.count, 1)
        XCTAssertEqual(afterUpdate.first?.updated.count, 1)
        XCTAssertEqual(afterDelete.first?.deleted.count, 1)
        XCTAssertEqual(afterDelete.first?.deleted.first.map(key), savedKey)
    }

    func testBackgroundThreadContextSave() throws {
        let container = try memoryContainer()
        let done = expectation(description: "bg")
        DispatchQueue.global(qos: .utility).async {
            let ctx = ModelContext(container)
            ctx.insert(self.node("bg1"))
            try? ctx.save()
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let got = drain()
        print("[PROBE] background insert saves=\(got.count) inserted=\(got.map { $0.inserted.count })")
        XCTAssertEqual(got.flatMap(\.inserted).count, 1)
    }

    func testCrossContextIdentifiersMatch() throws {
        let container = try memoryContainer()
        let a = ModelContext(container)
        a.autosaveEnabled = false
        let n = node("x1")
        a.insert(n)
        try a.save()
        let keyA = key(n.persistentModelID)
        _ = drain()
        let b = ModelContext(container)
        b.autosaveEnabled = false
        let nb = try XCTUnwrap(b.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "x1" })).first)
        nb.content = "b 改"
        try b.save()
        let got = drain()
        print("[PROBE] cross-context updated=\(got.map { $0.updated.count }) keyMatch=\(got.first?.updated.first.map { key($0) == keyA } ?? false) sameIDInB=\(key(nb.persistentModelID) == keyA)")
        XCTAssertEqual(got.first?.updated.first.map(key), keyA)
        b.delete(nb)
        try b.save()
        let del = drain()
        XCTAssertEqual(del.first?.deleted.first.map(key), keyA)
    }

    func testBatchDeleteModelWhere() throws {
        let container = try memoryContainer()
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        ctx.insert(node("b1", pid: "gone"))
        ctx.insert(node("b2", pid: "gone"))
        ctx.insert(node("k1", pid: "keep"))
        try ctx.save()
        _ = drain()
        let del = ModelContext(container)
        try del.delete(model: MessageNode.self, where: #Predicate { $0.profileId == "gone" })
        let beforeSave = drain()
        try del.save()
        let afterSave = drain()
        let remaining = try ModelContext(container).fetchCount(FetchDescriptor<MessageNode>())
        print("[PROBE] batch delete beforeSave=\(beforeSave.map { ($0.deleted.count, $0.keys) }) afterSave=\(afterSave.map { ($0.deleted.count, $0.keys) }) remaining=\(remaining)")
    }

    func testBatchDeleteOnDiskStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.store")
        let schema = Schema([Conversation.self, MessageNode.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        ctx.insert(node("b1", pid: "gone"))
        ctx.insert(node("k1", pid: "keep"))
        try ctx.save()
        _ = drain()
        let del = ModelContext(container)
        try del.delete(model: MessageNode.self, where: #Predicate { $0.profileId == "gone" })
        let beforeSave = drain()
        try? del.save()
        let afterSave = drain()
        let remaining = try ModelContext(container).fetchCount(FetchDescriptor<MessageNode>())
        print("[PROBE] disk batch delete beforeSave=\(beforeSave.map { ($0.deleted.count, $0.keys) }) afterSave=\(afterSave.map { ($0.deleted.count, $0.keys) }) remaining=\(remaining)")
    }

    func testIdentifierStableAcrossRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.store")
        let schema = Schema([Conversation.self, MessageNode.self])
        var keyBefore = ""
        var savedKey = ""
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let ctx = ModelContext(container)
            ctx.autosaveEnabled = false
            let n = node("r1")
            ctx.insert(n)
            keyBefore = key(n.persistentModelID)
            try ctx.save()
            savedKey = key(n.persistentModelID)
            _ = drain()
        }
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let ctx = ModelContext(container)
        let n = try XCTUnwrap(ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == "r1" })).first)
        let keyAfter = key(n.persistentModelID)
        print("[PROBE] relaunch tempBeforeSave==saved \(keyBefore == savedKey) saved==relaunch \(savedKey == keyAfter)")
        print("[PROBE] key sample \(keyAfter)")
        XCTAssertEqual(savedKey, keyAfter)
        let decoded = try JSONDecoder().decode(PersistentIdentifier.self, from: Data(savedKey.utf8))
        XCTAssertEqual(decoded, n.persistentModelID)
    }

    @MainActor
    func testMainContextAutosave() throws {
        let container = try memoryContainer()
        let ctx = container.mainContext
        ctx.insert(node("auto1"))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if !drainPeek().isEmpty { break }
        }
        let got = drain()
        print("[PROBE] mainContext autosave saves=\(got.count) inserted=\(got.map { $0.inserted.count })")
    }

    @MainActor
    func testMainContextAutosaveOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = Schema([Conversation.self, MessageNode.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: dir.appendingPathComponent("p.store")))
        let ctx = container.mainContext
        ctx.insert(node("auto2"))
        let deadline = Date().addingTimeInterval(5)
        var persisted = 0
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            persisted = (try? ModelContext(container).fetchCount(FetchDescriptor<MessageNode>())) ?? 0
            if persisted > 0 { break }
        }
        let got = drain()
        print("[PROBE] disk mainContext autosave persisted=\(persisted) didSave=\(got.count) inserted=\(got.map { $0.inserted.count })")
    }

    private func drainPeek() -> [PersistentIdentifier] {
        lock.lock()
        defer { lock.unlock() }
        return saves.flatMap(\.inserted)
    }
}
