import XCTest
@testable import 记忆花园

/// A 线只读候选与按窗口 / 段全文读取。夹具只写临时根目录。
final class CatalogALineReaderTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("aline-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: mo, day: d, hour: h, minute: mi))!
    }

    private func entry(_ conv: String, _ mo: Int, _ d: Int, topics: [String], title: String? = nil) -> TimelineEntry {
        let start = date(mo, d, 20)
        return TimelineEntry(start: start, end: start.addingTimeInterval(1800), conversationId: conv, title: title ?? "窗\(conv)",
                             text: topics.map { "- \($0)" }.joined(separator: "\n"), pending: "", day: MemoryDay.key(start))
    }

    private func writeTimeline(_ list: [TimelineEntry]) throws {
        let dir = TimelineStore.dir(root: root)
        for (month, es) in Dictionary(grouping: list, by: { String($0.dayKey.prefix(7)) }) {
            try TimelineStore.write(es, month: month, in: dir)
        }
    }

    private func seg(_ title: String, _ story: String, at start: Date, kind: SessionSegment.Kind = .rolling, from: Int = 0, to: Int = 10,
                     quotes: String = "") -> SessionSegment {
        SessionSegment(kind: kind, title: title, start: start, end: start.addingTimeInterval(600), from: from, to: to,
                       lastNodeId: "n\(to)", story: story, quotes: quotes, pending: "")
    }

    private func summary(_ conv: String, _ segs: [SessionSegment], title: String? = nil, closed: String? = nil) -> SessionSummary {
        SessionSummary(conversationId: conv, title: title ?? "窗\(conv)", compressedCount: 0, segments: segs, updatedAt: date(10, 20, 12),
                       closedThrough: closed)
    }

    private func saveA2(_ s: SessionSummary) throws { try SessionSummaryStore.save(s, in: SessionSummaryStore.dir(root: root)) }
    private func saveA3(_ s: SessionSummary) throws { try WindowSummaryStore.save(s, in: root) }

    private func a3(_ conv: String, _ story: String, at start: Date) -> SessionSummary {
        summary(conv, [seg("整窗", story, at: start, kind: .closeout, from: 0, to: 30)], closed: "last")
    }

    private func saveFirstGeneration(_ conv: String, text: String, at updatedAt: Date, coveredCount: Int = 40) throws {
        let dir = root.appendingPathComponent(SummaryFileStore.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = FrontmatterCodec.render(meta: [("conversationId", conv), ("coveredCount", "\(coveredCount)"),
                                                 ("updatedAt", FrontmatterCodec.dateFormatter.string(from: updatedAt))],
                                          body: text)
        try Data(raw.utf8).write(to: dir.appendingPathComponent("\(conv.prefix(8))-old.md"))
    }

    func testCandidatesExposeStructuredSourcesWithoutQueryFiltering() throws {
        let conv = "0001aaaa-conv"
        try writeTimeline([entry(conv, 10, 12, topics: ["一起看了《云桥城》", "聊了晚饭"])])
        try saveA3(a3(conv, "那晚看电影，聊了晚饭。", at: date(10, 12, 20)))
        let dinner = seg("吃饭", "晚饭吃了面。", at: date(10, 12, 19), from: 0, to: 12)
        let movie = seg("看片", "选了一部电影，看到结尾。", at: date(10, 12, 20), from: 12, to: 30, quotes: "你：「好想去太空」")
        try saveA2(summary(conv, [dinner, movie]))

        let hits = CatalogALineReader.candidates(memoryRoot: root)

        XCTAssertEqual(hits.map(\.layer), [.a4, .a4, .a3, .a2, .a2])
        XCTAssertTrue(hits.allSatisfy { $0.conversationId == conv && $0.title == "窗\(conv)" })
        XCTAssertEqual(hits[0].day, "2026-10-12")
        XCTAssertEqual(hits[0].start, date(10, 12, 20))
        XCTAssertEqual(hits[0].end, date(10, 12, 20, 30))
        XCTAssertEqual(hits[0].text, "一起看了《云桥城》")
        XCTAssertEqual(hits[1].text, "聊了晚饭")
        XCTAssertNil(hits[0].segment)
        XCTAssertNil(hits[0].messages)
        XCTAssertEqual(hits[2].text, "整窗\n【经过】那晚看电影，聊了晚饭。")
        XCTAssertNil(hits[2].segment)
        XCTAssertEqual(hits[3].segment, 2)
        XCTAssertEqual(hits[3].messages, 12..<30)
        XCTAssertEqual(hits[3].start, movie.start)
        XCTAssertEqual(hits[3].end, movie.end)
        XCTAssertEqual(hits[3].text, "看片\n【经过】选了一部电影，看到结尾。\n【原话】你：「好想去太空」")
        XCTAssertEqual(hits[4].segment, 1)
        XCTAssertEqual(hits[4].messages, 0..<12)
        XCTAssertTrue(hits.filter { $0.layer != .a4 }.allSatisfy { $0.old == nil })
        XCTAssertTrue(hits.filter { $0.layer == .a4 }.allSatisfy { $0.old == "一天 × 一窗口的老时间轴" }, "第 7 段起 v2 条目是老格式")

        let result = CatalogALineReader.Result(terms: ["电影"], hits: hits, found: [.a4: 2, .a3: 1, .a2: 2])
        XCTAssertEqual(result.terms, ["电影"])
        XCTAssertEqual(result.given(.a2), 2)
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(result.render().contains("conv 0001aaaa"))
        XCTAssertTrue(result.render().contains("第 2 段"))
        XCTAssertTrue(result.render().contains("消息 12..<30"))
        XCTAssertTrue(result.render().contains(hits[3].text))
    }

    func testCandidatesKeepAllFullBodies() throws {
        let long = String(repeating: "👨‍👩‍👧‍👦长正文", count: 1800)
        try writeTimeline((1...12).map { entry("\(String(format: "%04d", $0))full", 10, $0, topics: [long]) })
        for i in 1...6 {
            var full = seg("整窗", long, at: date(10, i, 20), kind: .closeout, from: 0, to: 30, quotes: "完整原话")
            full.pending = "完整待续"
            try saveA3(summary("\(String(format: "%04d", i))a3xx", [full], closed: "last"))
        }
        var full = seg("整段", long, at: date(10, 1, 20), quotes: "完整原话")
        full.pending = "完整待续"
        try saveA2(summary("0001a2xx", (1...9).map { i in
            var copy = full
            copy.start = date(10, i, 20)
            copy.end = copy.start.addingTimeInterval(600)
            copy.from = (i - 1) * 10
            copy.to = i * 10
            return copy
        }))

        let hits = CatalogALineReader.candidates(memoryRoot: root)
        XCTAssertEqual(hits.filter { $0.layer == .a4 }.count, 12)
        XCTAssertEqual(hits.filter { $0.layer == .a3 }.count, 6)
        XCTAssertEqual(hits.filter { $0.layer == .a2 }.count, 9)
        XCTAssertTrue(hits.filter { $0.layer == .a4 }.allSatisfy { $0.text == long })
        // c2c3-v2 第 7 段：段里的【待续】不进 A 线（待续只有待续本子一份）
        let body = "【经过】\(long)\n【原话】完整原话"
        XCTAssertTrue(hits.filter { $0.layer == .a3 }.allSatisfy { $0.text == "整窗\n\(body)" })
        XCTAssertTrue(hits.filter { $0.layer == .a2 }.allSatisfy { $0.text == "整段\n\(body)" })
    }

    func testDateRangeFiltersAllLayersWithoutRenumberingSegments() throws {
        try writeTimeline([entry("0001g-conv", 9, 28, topics: ["九月"]), entry("0002g-conv", 10, 2, topics: ["十月"])])
        try saveA3(a3("0001g-conv", "九月", at: date(9, 28, 20)))
        try saveA3(a3("0002g-conv", "十月", at: date(10, 2, 20)))
        try saveA2(summary("0003g-conv", [seg("九", "九月", at: date(9, 29, 20), from: 0, to: 5),
                                           seg("十", "十月", at: date(10, 3, 20), from: 5, to: 9)]))

        let october = DateInterval(start: MemoryDay.boundary(of: date(10, 1, 0)), end: .distantFuture)
        let hits = CatalogALineReader.candidates(in: october, memoryRoot: root)
        XCTAssertEqual(hits.filter { $0.layer == .a4 }.map(\.conversationId), ["0002g-conv"])
        XCTAssertEqual(hits.filter { $0.layer == .a3 }.map(\.conversationId), ["0002g-conv"])
        XCTAssertEqual(hits.filter { $0.layer == .a2 }.map(\.segment), [2])
        XCTAssertEqual(hits.filter { $0.layer == .a2 }.first?.messages, 5..<9)
        XCTAssertEqual(CatalogALineReader.candidates(memoryRoot: root).count, 6)
    }

    func testDateRangeUsesHalfOpenIntersectionForEveryLayer() throws {
        let start = date(10, 2, 5)
        let end = date(10, 3, 5)
        let spans: [(String, Date, Date)] = [
            ("0001past", start.addingTimeInterval(-600), start),
            ("0002next", end, end.addingTimeInterval(600)),
            ("0003here", start, start.addingTimeInterval(600)),
            ("0004span", start.addingTimeInterval(-600), end.addingTimeInterval(600)),
        ]
        for (conv, lo, hi) in spans {
            let timeline = TimelineEntry(start: lo, end: hi, conversationId: conv, title: conv, text: "- \(conv)",
                                         pending: "", day: MemoryDay.key(lo))
            try TimelineStore.seedLegacy(timeline, in: TimelineStore.dir(root: root))
            var segment = seg(conv, conv, at: lo)
            segment.end = hi
            try saveA2(summary(conv, [segment]))
            try saveA3(summary(conv, [segment], closed: "last"))
        }

        let hits = CatalogALineReader.candidates(in: DateInterval(start: start, end: end), memoryRoot: root)
        for layer in [CatalogALineReader.Layer.a4, .a3, .a2] {
            XCTAssertEqual(Set(hits.filter { $0.layer == layer }.map(\.conversationId)), ["0003here", "0004span"])
        }
        XCTAssertEqual(CatalogALineReader.candidates(in: DateInterval(start: start, end: start), memoryRoot: root), [])
    }

    func testLegacyTimelineLinesAndPendingRemainWhole() throws {
        let old = TimelineEntry(start: date(10, 1, 9), end: date(10, 1, 10), conversationId: "0001old4", title: "老窗口",
                                text: "旧格式第一行\n旧格式第二行", pending: "下次继续")
        var current = entry("0002new4", 10, 2, topics: ["新话题"])
        current.pending = "- 新待续"
        try writeTimeline([old, current])

        let hits = CatalogALineReader.candidates(memoryRoot: root)
        let oldHits = hits.filter { $0.conversationId == old.conversationId }
        XCTAssertEqual(oldHits.map(\.text), ["旧格式第一行", "旧格式第二行", "待续：下次继续"])
        XCTAssertEqual(oldHits.map(\.bodyText), ["旧格式第一行", "旧格式第二行", "下次继续"])
        XCTAssertTrue(oldHits.allSatisfy { $0.old == "老时间轴大段" && $0.layer == .a4 })
        let currentHits = hits.filter { $0.conversationId == current.conversationId }
        XCTAssertEqual(currentHits.map(\.text), ["新话题", "待续：新待续"])
        XCTAssertEqual(currentHits.map(\.bodyText), ["新话题", "新待续"])
        XCTAssertTrue(currentHits.allSatisfy { $0.old == "一天 × 一窗口的老时间轴" })
    }

    /// 第 7 段：一天一条按日期出一个 A4 候选（不属于哪个窗口）：主调、话题、各项和时间轴页同一套字；看不见的窗口那几项不给
    func testDayRecordIsOneDateHitWithVisibleItemsOnly() throws {
        let dir = TimelineStore.dir(root: root)
        let item = { (conv: String, title: String, h: Int) in
            TimelineDayRecord.Item(kind: .segment, conversationId: conv, window: "窗\(conv)", title: title, start: self.date(10, 12, h),
                                   end: self.date(10, 12, h, 30), from: "a", to: "b")
        }
        try TimelineStore.save(.init(days: [TimelineDayRecord(date: "2026-10-12", headline: "白天修报错", topics: ["报错"],
                                                              items: [item("0001vis", "修设置页报错", 9), item("0002hid", "藏起来的窗口", 20)])]),
                               month: "2026-10", in: dir)
        let all = CatalogALineReader.candidates(memoryRoot: root).filter { $0.layer == .a4 }
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all[0].conversationId, "按日期引用，不伪造窗口")
        XCTAssertEqual(all[0].day, "2026-10-12")
        XCTAssertTrue(all[0].text.contains("白天修报错") && all[0].text.contains("话题：报错"))
        XCTAssertTrue(all[0].text.contains("上午 · " + TimelineStore.itemText(item("0001vis", "修设置页报错", 9))))
        let visible = CatalogALineReader.candidates(memoryRoot: root, conversationIds: ["0001vis"]).filter { $0.layer == .a4 }
        XCTAssertFalse(visible[0].text.contains("藏起来的窗口"))
        XCTAssertTrue(visible[0].text.contains("修设置页报错"))
        let receipt = CatalogALineReader.Result(terms: ["报错"], hits: all, found: [.a4: 1]).render()
        XCTAssertTrue(receipt.contains("- 2026-10-12 一天：白天修报错"), receipt)
    }

    func testLegacySegmentKindsAndWindowCopyKeepSourceIdentity() throws {
        var tail = seg("尾", "尾段正文", at: date(10, 1, 22), kind: .closeout, from: 20, to: 25)
        tail.isTail = true
        let duplicate = seg("老收尾", "老收尾正文", at: date(10, 1, 21), kind: .closeout, from: 10, to: 20)
        try saveA2(summary("0001old2", [
            seg("改造前的累计摘要", "早期正文", at: date(10, 1, 8), kind: .legacy, from: 0, to: 10),
            duplicate, tail,
        ]))
        let remainder = seg("最后那截", "抄本最后正文", at: date(10, 1, 23), kind: .closeout, from: 25, to: 30, quotes: "最后原话")
        try saveA3(summary("0001old2", [duplicate, remainder], closed: "last"))

        let hits = CatalogALineReader.candidates(memoryRoot: root)
        let copied = try XCTUnwrap(hits.first { $0.layer == .a3 })
        XCTAssertEqual(copied.old, "v4-1 窗口总结抄本")
        XCTAssertEqual(copied.text, "最后那截\n【经过】抄本最后正文\n【原话】最后原话")
        XCTAssertEqual(copied.start, remainder.start)
        XCTAssertEqual(copied.end, remainder.end)
        let contexts = hits.filter { $0.layer == .a2 }.sorted { $0.segment! < $1.segment! }
        XCTAssertEqual(contexts.map(\.segment), [0, 1, 2])
        XCTAssertEqual(contexts.map(\.messages), [0..<10, 10..<20, 20..<25])
        XCTAssertEqual(contexts.map(\.old), ["改造前累计摘要", "老收尾段", nil])
        XCTAssertEqual(contexts[0].text, "改造前的累计摘要\n早期正文")
    }

    func testLegacyWindowCopyFiltersSegmentsBeforeCombiningFullBodies() throws {
        let early = seg("早段", "较早正文", at: date(10, 1, 20), from: 10, to: 20)
        let late = seg("晚段", "较晚正文\n第二行", at: date(10, 3, 20), from: 20, to: 30, quotes: "完整原话")
        try saveA3(summary("0001copy", [early, late], closed: "last"))
        let interval = DateInterval(start: date(10, 2, 5), end: date(10, 4, 5))

        let hit = try XCTUnwrap(CatalogALineReader.candidates(in: interval, memoryRoot: root).first)
        XCTAssertEqual(hit.layer, .a3)
        XCTAssertEqual(hit.start, late.start)
        XCTAssertEqual(hit.end, late.end)
        XCTAssertEqual(hit.text, "晚段\n【经过】较晚正文\n第二行\n【原话】完整原话")
        let all = try XCTUnwrap(CatalogALineReader.candidates(memoryRoot: root).first)
        XCTAssertEqual(all.text, "早段\n【经过】较早正文\n\n晚段\n【经过】较晚正文\n第二行\n【原话】完整原话")
    }

    func testFirstGenerationSummaryIsPointDatedSegmentZeroAndFullyReadable() async throws {
        let conv = "0001old0-full"
        let timestamp = date(10, 1, 12)
        try saveFirstGeneration(conv, text: "第一代老摘要完整正文", at: timestamp)
        let hits = CatalogALineReader.candidates(memoryRoot: root)
        XCTAssertEqual(hits.map(\.segment), [0])
        XCTAssertEqual(hits.first?.conversationId, conv)
        XCTAssertEqual(hits.first?.old, "改造前累计摘要")
        XCTAssertEqual(hits.first?.messages, 0..<40)
        XCTAssertEqual(hits.first?.start, timestamp)
        XCTAssertEqual(hits.first?.end, timestamp)
        XCTAssertEqual(CatalogALineReader.candidates(in: DateInterval(start: timestamp, duration: 1), memoryRoot: root), hits)
        XCTAssertEqual(CatalogALineReader.candidates(in: DateInterval(start: timestamp.addingTimeInterval(-1), end: timestamp), memoryRoot: root), [])
        let window = await CatalogALineReader.readWindow(conv, memoryRoot: root)
        XCTAssertEqual(window?.segments.map(\.number), [0])
        let read = await CatalogALineReader.readSegment(conv, number: 0, memoryRoot: root)
        XCTAssertEqual(read?.conversationId, conv)
        XCTAssertEqual(read?.segment.text, hits.first?.text)
        XCTAssertEqual(read?.segment.messages, 0..<40)
    }

    func testSessionFileTakesPrecedenceOverFirstGenerationSummary() async throws {
        let conv = "0001both"
        try saveFirstGeneration(conv, text: "旧文件正文", at: date(10, 1, 12))
        try saveA2(summary(conv, [seg("正式段", "新文件正文", at: date(10, 2, 20))]))

        let hits = CatalogALineReader.candidates(memoryRoot: root)
        XCTAssertEqual(hits.map(\.segment), [1])
        XCTAssertEqual(hits.first?.text, "正式段\n【经过】新文件正文")
        let zero = await CatalogALineReader.readSegment(conv, number: 0, memoryRoot: root)
        XCTAssertNil(zero)
    }

    func testReadWindowAndExactNumberedSegmentPreserveFullBodies() async throws {
        let conv = "0001read-full"
        try saveA3(a3(conv, "整个窗口在聊电影和晚饭。", at: date(10, 5, 19)))
        let movie = seg("看片", "选了一部电影。看到结尾", at: date(10, 5, 20), from: 10, to: 30, quotes: "我：「下次还看」")
        try saveA2(summary(conv, [movie,
            seg("改造前的累计摘要", "更早的事", at: date(10, 5, 8), kind: .legacy, from: 0, to: 10),
        ], title: "周末"))

        let read = await CatalogALineReader.readWindow(String(conv.prefix(8)), memoryRoot: root)
        let window = try XCTUnwrap(read)
        XCTAssertEqual(window.conversationId, conv)
        XCTAssertEqual(window.title, "窗\(conv)")
        XCTAssertEqual(window.a3?.story, "整个窗口在聊电影和晚饭。")
        XCTAssertEqual(window.segments.map(\.number), [0, 1])
        XCTAssertEqual(window.segments[1].messages, 10..<30)
        XCTAssertEqual(window.segments[1].segment, movie)
        let segmentRead = await CatalogALineReader.readSegment(conv, number: 1, memoryRoot: root)
        let segment = try XCTUnwrap(segmentRead)
        XCTAssertEqual(segment.count, 2)
        XCTAssertEqual(segment.segment.segment, movie)
        XCTAssertEqual(segment.segment.text, "看片\n【经过】选了一部电影。看到结尾\n【原话】我：「下次还看」")
        XCTAssertTrue(segment.render().contains(segment.segment.text))
        XCTAssertTrue(segment.render().contains("conv \(conv.prefix(8))"))
        XCTAssertTrue(segment.render().contains("消息 10..<30"))
        XCTAssertTrue(window.render().contains("（旧·改造前累计摘要）"))
        let missing = await CatalogALineReader.readSegment(conv, number: 2, memoryRoot: root)
        let negative = await CatalogALineReader.readSegment(conv, number: -1, memoryRoot: root)
        XCTAssertNil(missing)
        XCTAssertNil(negative)
    }

    func testReadWindowWithOldA3Copy() async throws {
        let duplicate = seg("压缩", "压缩段", at: date(10, 6, 20), from: 0, to: 10)
        let remainder = seg("最后那截", "视野里那截", at: date(10, 6, 21), kind: .closeout, from: 10, to: 15)
        try saveA2(summary("0001old3", [duplicate]))
        try saveA3(summary("0001old3", [duplicate, remainder], closed: "last"))

        let read = await CatalogALineReader.readWindow("0001old3", memoryRoot: root)
        let window = try XCTUnwrap(read)
        XCTAssertNil(window.a3)
        XCTAssertEqual(window.oldA3, [remainder])
        XCTAssertEqual(window.segments.map(\.segment), [duplicate])
        XCTAssertTrue(window.render().contains(SessionSummaryStore.segmentText(remainder)))
    }

    func testReadsStayWithinRequestedRootWithoutCreatingDirectories() async throws {
        try writeTimeline([entry("0001root", 10, 1, topics: ["本楼层正文"])])
        try saveA2(summary("0001root", [seg("本楼层", "正文", at: date(10, 1, 20))]))
        let empty = root.appendingPathComponent("other-floor", isDirectory: true)

        XCTAssertEqual(CatalogALineReader.candidates(memoryRoot: empty), [])
        let window = await CatalogALineReader.readWindow("0001root", memoryRoot: empty)
        let segment = await CatalogALineReader.readSegment("0001root", number: 1, memoryRoot: empty)
        XCTAssertNil(window)
        XCTAssertNil(segment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(CatalogALineReader.candidates(memoryRoot: root).count, 2)
    }

    func testCandidateAndFullReadReceiptsShareRawBodyDefinition() async throws {
        let conv = "0001body"
        let title = "云桥城"
        var segment = seg(title, title, at: date(10, 12, 20), quotes: "实际原话")
        segment.pending = "实际待续"
        try saveA2(summary(conv, [segment], title: title))
        try saveA3(summary(conv, [segment], title: title, closed: "last"))
        try writeTimeline([entry(conv, 10, 12, topics: [title], title: title)])

        let hits = CatalogALineReader.candidates(memoryRoot: root)
        XCTAssertEqual(hits.map(\.layer), [.a4, .a3, .a2])
        let expectedBodies = [title, "实际原话"]  // 段里的【待续】不进 A 线（c2c3-v2 第 7 段）
        for hit in hits where hit.layer != .a4 {
            XCTAssertEqual(hit.bodyText, expectedBodies.joined())
            var receipt = CatalogSearchReceipt(vectorStatus: "未检索")
            receipt.appendALine(hit)
            XCTAssertEqual(receipt.evidence().aline, expectedBodies)
            XCTAssertEqual(receipt.evidence().searchedChars, expectedBodies.joined().count)
        }

        let read = await CatalogALineReader.readSegment(conv, number: 1, memoryRoot: root)
        let full = try XCTUnwrap(read)
        XCTAssertEqual(full.receipt().evidence().aline, expectedBodies)
        let windowRead = await CatalogALineReader.readWindow(conv, memoryRoot: root)
        let window = try XCTUnwrap(windowRead)
        XCTAssertEqual(window.receipt().evidence().aline, expectedBodies + [title])
    }

    func testDirectoryReceiptCountsOnlySuppliedGistWithoutSyntheticEllipsis() {
        let story = String(repeating: "正文", count: 30) + "。未给出的下一句"
        let segment = seg("目录标题", story, at: date(10, 12, 20), quotes: "目录不提供原话")
        let window = CatalogALineReader.Window(conversationId: "0001gist", title: "窗口标题", a3: nil, oldA3: [],
                                               segments: CatalogALineReader.numbered([segment]))
        let receipt = window.receipt()
        XCTAssertTrue(receipt.text.contains("目录标题"))
        XCTAssertTrue(receipt.text.contains(String(story.prefix(CatalogALineReader.gistLength)) + "…"))
        XCTAssertFalse(receipt.text.contains("未给出的下一句"))
        XCTAssertFalse(receipt.text.contains("目录不提供原话"))
        XCTAssertEqual(receipt.evidence().aline, [String(story.prefix(CatalogALineReader.gistLength))])
        XCTAssertEqual(receipt.evidence().searchedChars, CatalogALineReader.gistLength)
    }

    func testLegacySegmentZeroReceiptCountsStoryButNotLegacyTitle() async throws {
        let conv = "0001bodyzero"
        let body = "第一代老摘要完整正文"
        try saveFirstGeneration(conv, text: body, at: date(10, 1, 12))
        let read = await CatalogALineReader.readSegment(conv, number: 0, memoryRoot: root)
        let full = try XCTUnwrap(read)
        XCTAssertEqual(full.segment.number, 0)
        XCTAssertEqual(full.segment.parts, [
            CatalogSearchPart(text: "改造前的累计摘要\n", isBody: false),
            CatalogSearchPart(text: body, isBody: true),
        ])
        XCTAssertEqual(full.receipt().evidence().aline, [body])
        XCTAssertEqual(full.receipt().evidence().searchedChars, body.count)
        let windowRead = await CatalogALineReader.readWindow(conv, memoryRoot: root)
        let window = try XCTUnwrap(windowRead)
        XCTAssertEqual(window.receipt().evidence().aline, [body])
        XCTAssertTrue(window.render().contains("第 0 段"))
    }

    func testLegacyA3CopyReceiptExcludesCopiedTitlesAndLabels() async throws {
        let first = seg("第一段标题", "第一段经过", at: date(10, 12, 20), quotes: "第一段原话")
        let second = seg("第二段标题", "第二段经过", at: date(10, 12, 21), from: 10, to: 20, quotes: "第二段原话")
        try saveA3(summary("0001copybody", [first, second], closed: "last"))
        let hit = try XCTUnwrap(CatalogALineReader.candidates(memoryRoot: root).first)
        var receipt = CatalogSearchReceipt(vectorStatus: "未检索")
        receipt.appendALine(hit)
        let expected = ["第一段经过", "第一段原话", "第二段经过", "第二段原话"]
        XCTAssertEqual(receipt.evidence().aline, expected)
        let read = await CatalogALineReader.readWindow("0001copybody", memoryRoot: root)
        let window = try XCTUnwrap(read)
        XCTAssertEqual(window.receipt().evidence().aline, expected)
    }
}
