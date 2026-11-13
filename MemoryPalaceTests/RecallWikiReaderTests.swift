import MemoryCore
import XCTest
@testable import 记忆花园

/// 只剩三条需要 app 类型的用例（`WikiProposalSources.cc` / `CatalogSeedTask` / `CatalogFloorBase`）；
/// 其余 15 条在包 `Tests/MemoryCoreTests/RecallWikiReaderTests.swift`（断言未改）。
final class RecallWikiReaderTests: XCTestCase {
    private var root: URL!
    private var wiki: WikiStore!
    private let pid = "fictional-y7"
    private var reader: RecallWikiReader {
        .init(profileId: pid, memoryRoot: root, userName: "岚舟",
              resolveCurrent: RecallTool.wikiCurrentResolver(floorBase: nil))
    }
    private var store: SeedNoteStore { .init(wiki: wiki) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-wiki-\(UUID().uuidString)")
        wiki = WikiStore(root: root.appendingPathComponent("wiki"))
        try FileManager.default.createDirectory(at: wiki.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func value<T>(_ result: RecallWikiRead<T>, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        guard case .value(let value) = result else { XCTFail("unexpected \(result)", file: file, line: line); throw Failure.result }
        return value
    }
    private enum Failure: Error { case result }

    private func card(_ path: String = "memory/cc/星砚（云桥城）.md", version: String = "v1", layer: String = "CC", context: SeedSourceContext? = nil) throws -> SeedNoteCard {
        let card = SeedNoteCard(path: path, version: version, name: "星砚", layer: layer, title: "星砚画云桥城", gist: "星砚与岚舟在云桥城写生", mentions: [.init(name: "岚舟", group: "人")], aboutUser: false, group: "主题", when: [], model: "fictional", madeAt: Date(timeIntervalSince1970: version == "v1" ? 100 : 200), run: .init(path: ".runs/fictional.md"), sourceContext: context, factDomain: .inWorld)
        try store.save(card)
        return card
    }

    @discardableResult
    private func page(_ path: String = "主题/云桥城", records: [String] = [], entries: [String]? = nil, hook: String = "提到云桥城", now: String = "星砚在画画") throws -> RecallWikiPage {
        try wiki.save(WikiPage(path: path, hook: hook, title: "云桥城", now: now, records: records, entries: entries, factDomain: .inWorld))
        return try value(reader.page(wiki: wiki, target: .init(profileId: pid, path: path)))
    }

    private func target(_ card: SeedNoteCard, page: RecallWikiPage) -> RecallWikiCardTarget {
        .init(page: page.target, path: card.path, version: card.version)
    }

    func testMissingL2CCSameChangedEmptyAndMissingAreDistinct() throws {
        let path = "memory/cc/星砚.md", file = root.appendingPathComponent("cc/星砚.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# 星砚\n云桥城写生".utf8).write(to: file)
        guard case .present(let text, let version) = WikiProposalSources.cc(path, memoryRoot: root) else { return XCTFail() }
        let c = try card(path, version: version)
        let p = try page(entries: [path + "|" + version]), t = target(c, page: p)
        let same = try value(reader.original(wiki: wiki, target: t))
        XCTAssertEqual(same.missingOriginal, .currentSameVersion)
        XCTAssertEqual(same.text?.text, text)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let unreadable = try value(reader.original(wiki: wiki, target: t))
        if case .unreadable? = unreadable.missingOriginal {} else { XCTFail("应明确标为当前不可读") }
        XCTAssertNil(unreadable.text)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try Data("# 星砚\n岚舟同行".utf8).write(to: file)
        XCTAssertEqual(try value(reader.original(wiki: wiki, target: t)).missingOriginal, .changed)
        try Data("  \n".utf8).write(to: file)
        XCTAssertEqual(try value(reader.original(wiki: wiki, target: t)).missingOriginal, .empty)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try value(reader.original(wiki: wiki, target: t)).missingOriginal, .fileMissing)
    }

    func testMissingL2PromptUsesExistingResolverAndNeverReturnsWholeSlot() throws {
        let slot = "memory/prompt/云桥城", text = "# 星砚\n云桥城写生\n\n# 岚舟\n另一段"
        let items = CatalogSeedMaterials.personaItems(path: slot, name: "云桥城", text: text)
        let item = try XCTUnwrap(items.first)
        let c = try card(item.path, version: item.version, layer: "Prompt", context: item.sourceContext)
        var task = CatalogSeedTask(id: UUID().uuidString, profileId: pid, entry: .cc, modelName: "fictional", createdAt: Date(), run: c.run)
        task.materials = items.map { .init(path: $0.path, name: $0.name, layer: $0.layer, version: $0.version, sourceContext: $0.sourceContext) }
        task.read = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0.version) })
        try CatalogSeedTaskStore(wiki: wiki).save(task)
        let p = try page(entries: [c.path + "|" + c.version]), t = target(c, page: p)
        XCTAssertEqual(try value(reader.original(wiki: wiki, target: t)).missingOriginal, .currentUnavailable)
        var r = reader
        func floor(_ text: String, name: String = "云桥城") -> CatalogFloorBase { .init(sections: [.init(path: slot, name: name, text: text, isEnabled: true)]) }
        r.resolveCurrent = RecallTool.wikiCurrentResolver(floorBase: floor(text))
        let same = try value(r.original(wiki: wiki, target: t))
        XCTAssertEqual(same.missingOriginal, .currentSameVersion)
        XCTAssertEqual(same.text?.text, item.text)
        XCTAssertFalse(same.text?.text.contains("另一段") == true)
        r.resolveCurrent = RecallTool.wikiCurrentResolver(
            floorBase: floor(text.replacingOccurrences(of: "云桥城写生", with: "云桥城夜航")))
        XCTAssertEqual(try value(r.original(wiki: wiki, target: t)).missingOriginal, .changed)
        r.resolveCurrent = RecallTool.wikiCurrentResolver(floorBase: floor("# 岚舟\n另一段"))
        let cut = try value(r.original(wiki: wiki, target: t))
        XCTAssertEqual(cut.missingOriginal, .resegmented); XCTAssertNil(cut.text)
        r.resolveCurrent = RecallTool.wikiCurrentResolver(floorBase: floor(" "))
        XCTAssertEqual(try value(r.original(wiki: wiki, target: t)).missingOriginal, .empty)
        r.resolveCurrent = RecallTool.wikiCurrentResolver(floorBase: .init(sections: []))
        XCTAssertEqual(try value(r.original(wiki: wiki, target: t)).missingOriginal, .slotDeleted)
        r.resolveCurrent = RecallTool.wikiCurrentResolver(floorBase: floor(text, name: "岚舟"))
        XCTAssertEqual(try value(r.original(wiki: wiki, target: t)).missingOriginal, .contextChanged)
        CatalogSeedTaskStore(wiki: wiki).remove(task.id)
        r.resolveCurrent = RecallTool.wikiCurrentResolver(floorBase: floor(text))
        XCTAssertEqual(try value(r.original(wiki: wiki, target: t)).missingOriginal, .legacySegmentation)
    }

    func testCurrentSourceContinuationGoesStaleAfterEdit() throws {
        let path = "memory/cc/星砚.md", file = root.appendingPathComponent("cc/星砚.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("# 星砚\n" + String(repeating: "云桥城", count: 1200)).utf8).write(to: file)
        let c = try card(path), p = try page(entries: [path + "|v1"]), t = target(c, page: p)
        let first = try value(reader.original(wiki: wiki, target: t))
        XCTAssertEqual(first.missingOriginal, .changed)
        let second = try value(reader.original(wiki: wiki, target: t, cursor: XCTUnwrap(first.next)))
        guard case .present(let current, _) = WikiProposalSources.cc(path, memoryRoot: root) else { return XCTFail() }
        XCTAssertEqual((first.text?.text ?? "") + (second.text?.text ?? ""), current)
        try Data("# 星砚\n岚舟同行".utf8).write(to: file)
        XCTAssertEqual(reader.original(wiki: wiki, target: t, cursor: first.next), .stale)
    }
}
