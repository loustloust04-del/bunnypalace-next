import XCTest
@testable import 记忆花园

/// 第二刀 B1：AI 自己的记忆存储（memory/self/<slug>.md + INDEX.md），格式照 CC memory。
final class SelfMemoryStoreTests: XCTestCase {

    let pid = "xctest-self-memory-store"

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func mem(_ name: String, importance: Int = 3, origin: String = "self", created: Date = Date(), superseded: Date? = nil, body: String = "正文") -> SelfMemory {
        SelfMemory(slug: SelfMemoryStore.slugify(name), name: name, description: "关于\(name)", type: "user",
                   importance: importance, origin: origin, created: created, source: "conv-1", superseded: superseded, body: body)
    }

    func testRenderParseRoundTripCCStyle() {
        let m = mem("剧场要日常化", importance: 4, body: "她说「别一上来就高潮」，我记下了。")
        let text = SelfMemoryStore.render(m)
        XCTAssertTrue(text.hasPrefix("---\nname: 剧场要日常化\ndescription: "))
        XCTAssertTrue(text.contains("metadata:\n  type: user\n  importance: 4\n  origin: self\n  created: "))
        let back = SelfMemoryStore.parse(text, slug: m.slug)
        XCTAssertEqual(back?.name, m.name)
        XCTAssertEqual(back?.importance, 4)
        XCTAssertEqual(back?.body, m.body)
        XCTAssertEqual(back?.source, "conv-1")
        XCTAssertEqual(back.map { Int($0.created.timeIntervalSince1970) }, Int(m.created.timeIntervalSince1970))
        XCTAssertNil(back?.superseded)
    }

    func testSupersededRoundTrip() {
        let m = mem("a", superseded: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(SelfMemoryStore.parse(SelfMemoryStore.render(m), slug: "a")?.superseded?.timeIntervalSince1970, 1_790_000_000)
    }

    func testParseRejectsBrokenAndClampsFields() {
        XCTAssertNil(SelfMemoryStore.parse("没有头", slug: "x"))
        XCTAssertNil(SelfMemoryStore.parse("---\ndescription: 没名字\n---\n正文", slug: "x"))
        let p = SelfMemoryStore.parse("---\nname: a\nmetadata:\n  importance: 9\n  type: weird\n---\nb", slug: "a")
        XCTAssertEqual(p?.importance, 5)
        XCTAssertEqual(p?.type, "user")
    }

    func testSlugifyAndUnique() {
        XCTAssertEqual(SelfMemoryStore.slugify("剧场 要/日常化!"), "剧场-要-日常化")
        let existing = [mem("剧场"), mem("剧场-2")]
        XCTAssertEqual(SelfMemoryStore.uniqueSlug(for: "剧场", existing: existing), "剧场-3")
        XCTAssertEqual(SelfMemoryStore.uniqueSlug(for: "新的", existing: existing), "新的")
    }

    func testIndexSkipsSuperseded() {
        let idx = SelfMemoryStore.indexText([mem("a", importance: 5), mem("b", superseded: Date())])
        XCTAssertTrue(idx.contains("(a.md) — 5 级"))
        XCTAssertFalse(idx.contains("b.md"))
    }

    func testSaveListFindAndIndexFile() throws {
        try SelfMemoryStore.save(mem("旧", created: Date(timeIntervalSinceNow: -100)), profileId: pid)
        try SelfMemoryStore.save(mem("新"), profileId: pid)
        let list = SelfMemoryStore.list(profileId: pid)
        XCTAssertEqual(list.map(\.name), ["新", "旧"], "新的在前，INDEX.md 不算一条")
        XCTAssertEqual(SelfMemoryStore.find("旧", in: list)?.slug, "旧")
        let index = try String(contentsOf: SelfMemoryStore.directory(profileId: pid).appendingPathComponent("INDEX.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("关于新") && index.contains("关于旧"))
    }

    func testTodaySelfCountOnlyCountsSelfToday() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let list = [mem("a"), mem("b", origin: "asked"), mem("c", origin: "edited"), mem("d", created: yesterday)]
        XCTAssertEqual(SelfMemoryStore.todaySelfCount(list, now: now), 1)
    }

    /// #065 记忆面板那一组：有效在前、失效在后，各自保持原序；搜索词过滤摘要 / 名字 / 正文
    func testPanelRowsActiveFirstAndKeywordFilter() {
        let list = [mem("新的"), mem("失效的", superseded: Date()), mem("旧的", body: "她说「下周三复诊」")]
        XCTAssertEqual(SelfMemoryStore.panelRows(list, keyword: nil).map(\.name), ["新的", "旧的", "失效的"])
        XCTAssertEqual(SelfMemoryStore.panelRows(list, keyword: "复诊").map(\.name), ["旧的"])
        XCTAssertEqual(SelfMemoryStore.panelRows(list, keyword: "失效").map(\.name), ["失效的"])
        XCTAssertTrue(SelfMemoryStore.panelRows(list, keyword: "没有的词").isEmpty)
    }
}
