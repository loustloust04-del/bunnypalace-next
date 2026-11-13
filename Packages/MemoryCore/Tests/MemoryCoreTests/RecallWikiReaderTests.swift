import XCTest
@testable import MemoryCore

final class RecallWikiReaderTests: XCTestCase {
    private var root: URL!
    private var wiki: WikiStore!
    private let pid = "fictional-y7"
    private var reader: RecallWikiReader { .init(profileId: pid, memoryRoot: root, userName: "岚舟") }
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

    func testIndexKeepsNineGroupsAndReadsOnlyRequestedFolderWithPagination() throws {
        for branch in WikiStore.branches { try page(branch + "/岚舟") }
        for n in 0..<31 { try page("主题/星砚\(n)") }
        try page("主题/写生/星砚")
        try SafeWiki.write(Data("---\n钩子: 星砚写生\n---\n".utf8), name: WikiStore.groupFileName, in: ["主题", "写生"], under: wiki.root)
        try wiki.save(WikiPage(path: "人/private_星砚", title: "星砚"))
        try wiki.save(WikiPage(path: "主题/private_云桥城/星砚", title: "星砚"))
        let hidden = wiki.root.appendingPathComponent("主题/.隐藏")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("# 不出现".utf8).write(to: hidden.appendingPathComponent("星砚.md"))
        try FileManager.default.createSymbolicLink(at: wiki.root.appendingPathComponent("人/链接.md"), withDestinationURL: wiki.pageURL("人/岚舟"))
        try FileManager.default.createSymbolicLink(at: wiki.root.appendingPathComponent("主题/链接"), withDestinationURL: wiki.root.appendingPathComponent("主题/写生"))
        let rootIndex = try value(reader.index(wiki: wiki))
        let groups = rootIndex.rows.compactMap { row -> RecallWikiFolderRow? in
            guard case .folder(let folder) = row else { return nil }
            return folder
        }
        XCTAssertEqual(groups.map(\.path), WikiStore.branches)
        XCTAssertEqual(groups.first?.title, "岚舟")
        XCTAssertEqual(groups.first { $0.path == "主题" }?.pageCount, 33)
        XCTAssertEqual(rootIndex.rows.count, 9)
        XCTAssertNil(rootIndex.next)
        let first = try value(reader.index(wiki: wiki, folder: "主题"))
        XCTAssertEqual(first.rows.count, 30)
        XCTAssertEqual(first.rows.first, .folder(.init(path: "主题/写生", title: "写生", hook: "星砚写生", pageCount: 1)))
        let second = try value(reader.index(wiki: wiki, folder: "主题", cursor: XCTUnwrap(first.next)))
        let pages = (first.rows + second.rows).compactMap { row -> RecallWikiPageRow? in
            guard case .page(let page) = row else { return nil }
            return page
        }
        XCTAssertEqual(Set(pages.map(\.target.path)), Set(["主题/岚舟"] + (0..<31).map { "主题/星砚\($0)" }))
        XCTAssertTrue(pages.allSatisfy { $0.title == "云桥城 [设定]" && $0.hook == "提到云桥城" })
        XCTAssertNil(second.next)
        let nested = try value(reader.index(wiki: wiki, folder: "主题/写生"))
        guard case .page(let nestedPage) = try XCTUnwrap(nested.rows.first) else { return XCTFail() }
        XCTAssertEqual(nestedPage.target.path, "主题/写生/星砚")
        XCTAssertEqual(reader.index(wiki: wiki, folder: "人", cursor: first.next), .stale)
        XCTAssertEqual(reader.index(wiki: wiki, folder: "主题/private_云桥城"), .unavailable)
        XCTAssertEqual(reader.index(wiki: wiki, folder: "主题/链接"), .unavailable)
        let people = try value(reader.index(wiki: wiki, folder: "人"))
        XCTAssertEqual(people.rows.count, 1)
        try page("主题/新增星砚")
        XCTAssertEqual(reader.index(wiki: wiki, folder: "主题", cursor: first.next), .stale)
    }

    func testPageTenRowsStableIDsAndVersionChangeInvalidatesRowsAndCursor() throws {
        let lines = (0..<21).map { "星砚第\($0)幅画（memory/cc/星砚（云桥城）.md）" }
        let first = try page(records: lines)
        XCTAssertEqual(first.records.map(\.target.ordinal), Array(0..<10))
        let again = try value(reader.page(wiki: wiki, target: first.target))
        XCTAssertEqual(first.records.map(\.target.id), again.records.map(\.target.id))
        XCTAssertEqual(first.records[0].target.lineHash, CatalogRecordLine.fingerprint(lines[0]))
        let second = try value(reader.page(wiki: wiki, target: first.target, cursor: XCTUnwrap(first.next)))
        XCTAssertEqual(second.records.map(\.target.ordinal), Array(10..<20))
        let third = try value(reader.page(wiki: wiki, target: first.target, cursor: XCTUnwrap(second.next)))
        XCTAssertEqual(third.records.map(\.target.ordinal), [20])
        XCTAssertNil(third.next)
        try page(records: lines + ["岚舟新画"])
        XCTAssertEqual(reader.page(wiki: wiki, target: first.target, cursor: first.next), .stale)
        XCTAssertEqual(reader.entry(wiki: wiki, target: first.records[0].target), .stale)
        try FileManager.default.removeItem(at: wiki.pageURL(first.target.path))
        XCTAssertEqual(reader.page(wiki: wiki, target: first.target), .unavailable)
    }

    func testLongNowAndRecordContinueWithoutLosingCharacters() throws {
        let now = String(repeating: "岚舟👩🏽‍🚀", count: 1800), body = String(repeating: "星砚", count: 1700)
        let first = try page(records: [body + "（memory/cc/星砚.md）"], hook: "", now: now)
        var output = first, collectedNow = "", collectedBody = "", offsets: [Int] = []
        repeat {
            if let part = output.now { collectedNow += part.text; offsets.append(part.offset) }
            collectedBody += output.records.map(\.body.text).joined()
            XCTAssertLessThanOrEqual((output.hook?.text.count ?? 0) + (output.now?.text.count ?? 0) + output.records.reduce(0) { $0 + $1.body.text.count }, 3000)
            guard let next = output.next else { break }
            output = try value(reader.page(wiki: wiki, target: first.target, cursor: next))
        } while true
        XCTAssertEqual(collectedNow, now)
        XCTAssertEqual(collectedBody, body)
        XCTAssertEqual(offsets, [0, 3000])
    }

    func testNewOldAndParenthesizedSourcesBecomeStructuredLocators() throws {
        let path = "memory/cc/星砚（云桥城）(岚舟).md"
        let cc = try card(path)
        let prompt = try card("memory/prompt/星砚#01", layer: "Prompt")
        let p = try page(records: ["画画（\(path)）", "同行（出处：CC \(path)；Prompt 星砚）", "旧碎片（出处：碎片 12345678）"],
                         entries: [cc.path + "|" + cc.version, prompt.path + "|" + prompt.version])
        XCTAssertEqual(p.records[0].body.text, "画画")
        XCTAssertEqual(p.records[0].sources, [.seed(path: path)])
        XCTAssertEqual(p.records[1].sources, [.legacy(label: "CC \(path)"), .legacy(label: "Prompt 星砚")])
        XCTAssertEqual(try value(reader.entry(wiki: wiki, target: p.records[1].target)), .sources(p.records[1].sources))
        XCTAssertEqual(try value(reader.entry(wiki: wiki, target: p.records[2].target)), .fragmentSource(.fragment(label: "碎片 12345678")))
    }

    func testNonCardSourcesAreFragmentsAndLegacyRequiresMatchingPageEntry() throws {
        let c = try card("memory/prompt/星砚#01", layer: "Prompt")
        let labels = ["A2《云桥城》第 1 段", "A3《云桥城》", "A4 day 2026-11-03", "用户编辑", "原文 星砚", "wiki 主题/云桥城"]
        let p = try page(records: (labels + ["Prompt 星砚"]).map { "写生（出处：\($0)）" }, entries: [c.path + "|v1"])
        for (record, label) in zip(p.records, labels) {
            XCTAssertEqual(record.sources, [.fragment(label: label)])
            XCTAssertEqual(try value(reader.entry(wiki: wiki, target: record.target)), .fragmentSource(.fragment(label: label)))
        }
        XCTAssertEqual(p.records.last?.sources, [.legacy(label: "Prompt 星砚")])
        let withoutEntry = try page("主题/岚舟", records: ["写生（出处：Prompt 星砚）"])
        XCTAssertEqual(withoutEntry.records[0].sources, [.fragment(label: "Prompt 星砚")])
        XCTAssertEqual(try value(reader.entry(wiki: wiki, target: withoutEntry.records[0].target)), .fragmentSource(.fragment(label: "Prompt 星砚")))
    }

    func testL1StripsPrivateLinksBeforePaginationAndCursorRevision() throws {
        var c = try card()
        c.title = "星砚\n[[private_岚舟]]"
        c.gist = String(repeating: "云桥城", count: 1100) + "\n[[private_岚舟]]"
        c.mentions = [.init(name: "星砚\n[[private_岚舟]]", group: "人", aliases: ["岚舟", "[[private_云桥城]]"])]
        try store.save(c)
        let p = try page(records: ["写生（\(c.path)）"], entries: [c.path + "|v1"])
        guard case .card(let first) = try value(reader.entry(wiki: wiki, target: p.records[0].target)) else { return XCTFail() }
        XCTAssertEqual(first.title, "星砚")
        XCTAssertFalse(first.gist.contains("private_"))
        c.gist = c.gist.replacingOccurrences(of: "[[private_岚舟]]", with: "[[private_星砚]]")
        try store.save(c)
        guard case .card(let second) = try value(reader.entry(wiki: wiki, target: p.records[0].target, cursor: XCTUnwrap(first.next))) else { return XCTFail() }
        XCTAssertEqual(first.gist + second.gist, String(repeating: "云桥城", count: 1100))
        XCTAssertEqual(second.mentions, [.init(name: "星砚", group: "人", aliases: ["岚舟"])])
        XCTAssertNil(second.next)
    }

    func testUniqueEntryReadsOnlyL1AndMissingCardIsExplicit() throws {
        let c = try card()
        let p = try page(records: ["写生（\(c.path)）"], entries: [c.path + "|" + c.version])
        guard case .card(let l1) = try value(reader.entry(wiki: wiki, target: p.records[0].target)) else { return XCTFail() }
        XCTAssertEqual(l1.gist, c.gist)
        XCTAssertEqual(l1.mentions, c.mentions)
        XCTAssertEqual(l1.factDomain, .inWorld)
        XCTAssertEqual(l1.target.version, c.version)
        try FileManager.default.removeItem(at: store.url(path: c.path, version: c.version))
        XCTAssertEqual(try value(reader.entry(wiki: wiki, target: p.records[0].target)), .missingCard(l1.target))
    }

    func testMultipleVersionsRequireExplicitSelectionAndNeverChooseLatest() throws {
        let old = try card(), new = try card(version: "v2")
        let p = try page(records: ["写生（\(old.path)）"], entries: [old.path + "|v1", old.path + "|v2"])
        guard case .versionUndetermined(let versions) = try value(reader.entry(wiki: wiki, target: p.records[0].target)) else { return XCTFail() }
        XCTAssertEqual(versions.map(\.target.version), ["v1", "v2"])
        XCTAssertEqual(versions.map(\.madeAt), [old.madeAt, new.madeAt])
        XCTAssertEqual(versions.map(\.title), [old.title, new.title])
        guard case .card(let selected) = try value(reader.entry(wiki: wiki, target: p.records[0].target, selection: versions[0].target)) else { return XCTFail() }
        XCTAssertEqual(selected.target.version, "v1")
        var unapproved = versions[0].target; unapproved.version = "v3"
        XCTAssertEqual(reader.original(wiki: wiki, target: unapproved), .unavailable)
    }

    func testLegacySourceOffersOnlyExplicitPublicApprovedReferences() throws {
        let c = try card()
        let legacy = try page("主题/岚舟", records: ["写生（\(c.path)）"])
        let approved = try page(entries: [c.path + "|v1"])
        guard case .legacySource(let source, let choices) = try value(reader.entry(wiki: wiki, target: legacy.records[0].target)) else { return XCTFail() }
        XCTAssertEqual(source, .seed(path: c.path))
        XCTAssertEqual(choices.map(\.target), [target(c, page: approved)])
        guard case .card(let selected) = try value(reader.entry(wiki: wiki, target: legacy.records[0].target, selection: choices[0].target)) else { return XCTFail() }
        XCTAssertEqual(selected.gist, c.gist)
        try FileManager.default.removeItem(at: wiki.pageURL(approved.target.path))
        XCTAssertEqual(try value(reader.entry(wiki: wiki, target: legacy.records[0].target)), .legacySource(source, approved: []))
        XCTAssertEqual(reader.original(wiki: wiki, target: choices[0].target), .unavailable)
    }

    func testL1LongGistContinuesAndChangedCardInvalidatesCursor() throws {
        var c = try card(); c.gist = String(repeating: "星砚", count: 3200)
        try store.save(c)
        let p = try page(records: ["写生（\(c.path)）"], entries: [c.path + "|v1"])
        var text = "", next: RecallWikiCursor?, firstCursor: RecallWikiCursor?
        repeat {
            guard case .card(let l1) = try value(reader.entry(wiki: wiki, target: p.records[0].target, cursor: next)) else { return XCTFail() }
            text += l1.gist
            next = l1.next
            if firstCursor == nil { firstCursor = next }
        } while next != nil
        XCTAssertEqual(text, c.gist)
        c.gist += "岚舟"; try store.save(c)
        XCTAssertEqual(reader.entry(wiki: wiki, target: p.records[0].target, cursor: firstCursor), .stale)
    }

    func testSavedOriginalContinuesAfterSourceAndTaskDisappear() throws {
        let c = try card(), text = String(repeating: "星砚👩🏽‍🚀", count: 1500) + "  \n"
        let context = SeedSourceContext(slotPath: "memory/prompt/云桥城", slotName: "云桥城", headingPath: ["星砚"])
        try store.saveOriginal(path: c.path, version: c.version, text: text, sourceContext: context)
        let p = try page(entries: [c.path + "|v1"]), t = target(c, page: p)
        let first = try value(reader.original(wiki: wiki, target: t))
        XCTAssertNil(first.missingOriginal)
        XCTAssertEqual(first.sourceContext, context)
        XCTAssertEqual(first.text?.text.count, 3000)
        let second = try value(reader.original(wiki: wiki, target: t, cursor: XCTUnwrap(first.next)))
        XCTAssertEqual((first.text?.text ?? "") + (second.text?.text ?? ""), text)
        XCTAssertNil(second.next)
        var foreign = t; foreign.page.profileId = "another-floor"
        XCTAssertEqual(reader.original(wiki: wiki, target: foreign), .unavailable)
        try page(entries: [])
        XCTAssertEqual(reader.original(wiki: wiki, target: t, cursor: first.next), .stale)
    }

    func testHistoricalCardRequiresExactPublicReferenceAndRejectsLinks() throws {
        let c = try card(), p = try page(records: ["写生（memory/cc/星砚（云桥城）.md）"], entries: ["memory/cc/星砚（云桥城）.md|v1"]), t = target(c, page: p)
        try store.saveOriginal(path: c.path, version: c.version, text: "旧原文", sourceContext: nil)
        _ = try card(version: "v2")
        XCTAssertEqual(try value(reader.original(wiki: wiki, target: t)).text?.text, "旧原文")
        var newer = t; newer.version = "v2"
        XCTAssertEqual(reader.original(wiki: wiki, target: newer), .unavailable)
        let file = root.appendingPathComponent("cc/星砚（云桥城）.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: wiki.pageURL(p.target.path))
        XCTAssertEqual(reader.original(wiki: wiki, target: t), .unavailable)
        XCTAssertEqual(reader.entry(wiki: wiki, target: p.records[0].target), .unavailable)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertEqual(reader.entry(wiki: wiki, target: p.records[0].target), .unavailable)
        XCTAssertEqual(reader.original(wiki: wiki, target: t), .unavailable)
        try FileManager.default.removeItem(at: file)
        let txt = store.folder.appendingPathComponent(SeedNoteStore.key(path: c.path, version: c.version) + ".txt")
        try FileManager.default.removeItem(at: txt)
        try FileManager.default.createSymbolicLink(at: txt, withDestinationURL: wiki.pageURL(p.target.path))
        XCTAssertEqual(reader.original(wiki: wiki, target: t), .unavailable)
        try FileManager.default.removeItem(at: wiki.pageURL(p.target.path))
        XCTAssertEqual(reader.original(wiki: wiki, target: t), .unavailable)
    }

    func testPrivateParentForeignFloorAndCrossLayerCursorsCannotAuthorizeReads() throws {
        let c = try card()
        let p = try page(records: (0..<11).map { "星砚\($0)（\(c.path)）" }, entries: [c.path + "|v1"])
        let t = target(c, page: p)
        let foreignWiki = WikiStore(root: root.appendingPathComponent("别楼/wiki"))
        XCTAssertEqual(reader.index(wiki: foreignWiki), .unavailable)
        XCTAssertEqual(reader.original(wiki: foreignWiki, target: t), .unavailable)
        XCTAssertEqual(reader.original(wiki: wiki, target: t, cursor: p.next), .stale)
        var privateTarget = t
        privateTarget.page.path = "主题/private_云桥城"
        try wiki.save(WikiPage(path: privateTarget.page.path, title: "云桥城", entries: [c.path + "|v1"]))
        XCTAssertEqual(reader.original(wiki: wiki, target: privateTarget), .unavailable)
        let linked = wiki.root.appendingPathComponent("主题/星砚.md")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: wiki.pageURL(p.target.path))
        var linkedTarget = t; linkedTarget.page.path = "主题/星砚"
        XCTAssertEqual(reader.original(wiki: wiki, target: linkedTarget), .unavailable)
    }

    func testIndexDomainTailsAndOldPromptLabelsUseExistingContracts() throws {
        for (path, domain) in [("主题/岚舟", SeedFactDomain.mixed), ("主题/星砚", .realWorld)] {
            try wiki.save(WikiPage(path: path, title: "云桥城", factDomain: domain))
        }
        let index = try value(reader.index(wiki: wiki, folder: "主题"))
        let titles = index.rows.compactMap { row -> String? in
            guard case .page(let page) = row else { return nil }
            return page.title
        }
        XCTAssertEqual(titles, ["云桥城 [待判域]", "云桥城"])
        let c = try card("memory/prompt/星砚#01", layer: "Prompt")
        let p = try page(records: ["写生（出处：Prompt 星砚）"], entries: [c.path + "|v1"])
        guard case .card(let l1) = try value(reader.entry(wiki: wiki, target: p.records[0].target)) else { return XCTFail() }
        XCTAssertEqual(l1.target.path, c.path)
        XCTAssertEqual(l1.gist, c.gist)
    }

    func testOldPromptLabelDoesNotGuessVersionAfterSourceRename() throws {
        let old = try card("memory/prompt/星砚#01", layer: "Prompt")
        var new = try card(old.path, version: "v2", layer: "Prompt")
        new.name = "岚舟"
        try store.save(new)
        let p = try page(records: ["写生（出处：Prompt 星砚）"], entries: [old.path + "|v1", old.path + "|v2"])
        guard case .versionUndetermined(let versions) = try value(reader.entry(wiki: wiki, target: p.records[0].target)) else {
            return XCTFail("旧名称不能证明记录行对应哪一版")
        }
        XCTAssertEqual(versions.map(\.target.version), ["v1", "v2"])
    }
}
