import MemoryCore
import XCTest
@testable import 记忆花园

final class ALineRewriteTests: XCTestCase {
    private let pid = "xctest-aline-rewrite"
    private let time = Date(timeIntervalSince1970: 1_790_000_000)
    private let speakers = SessionSegmentWriter.Speakers(userName: "岚舟", assistantName: "星砚")

    override func tearDown() {
        MemoryWriteLog.flush()
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        super.tearDown()
    }

    private func segment(format: Int = 2, kind: SessionSegment.Kind = .rolling) -> SessionSegment {
        SessionSegment(kind: kind, title: "定云桥城路线", start: time, end: time.addingTimeInterval(600), from: 0, to: 6,
                       lastNodeId: "n5", story: "岚舟选了云桥城。\n定下走北门。", quotes: "岚舟：「走北门。」\n我：「好。」",
                       pending: kind == .window ? "" : "取地图", keywords: format >= 2 ? ["云桥城", "北门"] : [], format: format)
    }

    private func summary(_ segments: [SessionSegment]) -> SessionSummary {
        SessionSummary(conversationId: "aline001-window", title: "云桥城", compressedCount: 6, segments: segments, updatedAt: time)
    }

    func testV2RoundTripAndMixedFilePreserveEveryField() throws {
        let old = segment(format: 1)
        let new = segment()
        let mixed = summary([old, new])
        let raw = SessionSummaryStore.render(mixed)
        let back = try XCTUnwrap(try SessionSummaryStore.parseStrict(raw, path: "fixture"))
        XCTAssertEqual(back, mixed)
        XCTAssertEqual(SessionSummaryStore.render(back), raw)
        let oldBody = SessionSummaryStore.render(summary([old])).components(separatedBy: "<!-- seg ").last!
        XCTAssertTrue(raw.contains(oldBody), "追加v2不能改变v1段正文或版本")
        XCTAssertEqual(back.segments.map(\.format), [1, 2])
    }

    func testLoadingV1DoesNotRewriteOrUpgradeFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = summary([segment(format: 1)])
        try SessionSummaryStore.save(old, in: dir)
        let file = try XCTUnwrap(SessionSummaryStore.fileURL(conversationId: old.conversationId, in: dir))
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try SessionSummaryStore.loadStrict(conversationId: old.conversationId, in: dir), old)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testFiveLayerAliasesMissingBlocksAndKeywordDeduplication() {
        for mark in ["【经过】", "【走向】"] {
            let layers = SessionSummaryStore.splitLayers(mark + "定云桥城路线\n【原话】岚舟：「北门。」\n【关键词】 云桥城, 北门，云桥城、星砚、 , \n【待续】取地图")
            XCTAssertEqual(layers.story, "定云桥城路线")
            XCTAssertEqual(layers.quotes, "岚舟：「北门。」")
            XCTAssertEqual(layers.keywords, ["云桥城", "北门", "星砚"])
            XCTAssertEqual(layers.pending, "取地图")
        }
        let missing = SessionSummaryStore.splitLayers("【原话】我：「好。」")
        XCTAssertEqual(missing.story, "")
        XCTAssertEqual(missing.pending, "")
        XCTAssertEqual(missing.keywords, [])
        XCTAssertEqual(SessionSummaryStore.splitLayers("旧累计摘要").story, "旧累计摘要")
        for empty in ["无", "（无）", " \n ", "无、（无）、 "] {
            XCTAssertEqual(SessionSummaryStore.splitLayers("【关键词】" + empty).keywords, [])
        }
        XCTAssertEqual(SessionSummaryStore.parseKeywords("无,云桥城,（无）,北门,云桥城"), ["云桥城", "北门"])
    }

    func testLineStartLayersPreserveInlineMarkersAndLegacyFallback() throws {
        let text = "【走向】从【原话】格式转到归档。\n【原话】岚舟：「按这个来。」\n【关键词】归档"
        let layers = SessionSummaryStore.splitLayers(text)
        XCTAssertEqual(layers.story, "从【原话】格式转到归档。")
        XCTAssertEqual(layers.quotes, "岚舟：「按这个来。」")
        XCTAssertEqual(layers.keywords, ["归档"])
        let indented = SessionSummaryStore.splitLayers("  【走向】从【原话】格式转到归档。\n\t【原话】岚舟：「按这个来。」\n  【关键词】归档")
        XCTAssertEqual(indented.story, layers.story)
        XCTAssertEqual(indented.quotes, layers.quotes)
        XCTAssertEqual(indented.keywords, layers.keywords)
        let legacy = SessionSummaryStore.splitLayers("旧怪文件【经过】改格式【原话】岚舟：「好。」【待续】取地图")
        XCTAssertEqual(legacy.story, "改格式")
        XCTAssertEqual(legacy.quotes, "岚舟：「好。」")
        XCTAssertEqual(legacy.pending, "取地图")
        for (format, kind) in [(1, SessionSegment.Kind.rolling), (2, .rolling), (2, .window)] {
            var part = segment(format: format, kind: kind)
            part.story = layers.story
            part.quotes = layers.quotes
            let file = SessionSummaryStore.render(summary([part]))
            XCTAssertEqual(try SessionSummaryStore.parseStrict(file, path: "fixture"), summary([part]))
        }
    }

    func testV2WindowAndEmptyKeywordsRenderWithoutSpuriousBlocks() throws {
        let window = summary([segment(kind: .window)])
        let raw = SessionSummaryStore.render(window)
        XCTAssertTrue(raw.contains("【走向】岚舟选了云桥城。"))
        XCTAssertFalse(raw.contains("【经过】"))
        XCTAssertFalse(raw.contains("【待续】"))
        XCTAssertEqual(SessionSummaryStore.parse(raw), window)
        var empty = segment()
        empty.keywords = []
        let noKeywords = SessionSummaryStore.render(summary([empty]))
        XCTAssertFalse(noKeywords.contains("【关键词】"))
        XCTAssertEqual(SessionSummaryStore.parse(noKeywords)?.segments.first?.keywords, [])
    }

    func testV2CatalogBodyPreservesStoryAndQuotes() {
        let new = segment()
        let body = CatalogALineReader.segmentParts(new).filter(\.isBody).map(\.text).joined()
        XCTAssertEqual(body, new.story + new.quotes)
    }

    private func raw(title: String = "定云桥城路线", story: String = "岚舟选了北门。", keywords: String? = "云桥城，北门") -> String {
        "标题：\(title)\n【经过】\(story)\n【原话】岚舟：「北门。」" + (keywords.map { "\n【关键词】\($0)" } ?? "") + "\n【待续】取地图"
    }

    func testSoftCheckBoundariesDoNotRejectOrRetryAndLogEachIssue() async throws {
        let cases: [(String, String)] = [
            (raw(title: String(repeating: "城", count: 16)), "标题超过"),
            (raw(title: "我们定云桥城路线"), "标题以代词"),
            (raw(title: "我定云桥城路线"), "标题以代词"),
            (raw(title: "你定云桥城路线"), "标题以代词"),
            (raw(keywords: nil), "没有【关键词】"),
            (raw(keywords: "甲,乙,丙,丁,戊,己"), "关键词超过"),
            (raw(story: "然后取地图，之后进北门。"), "连接词"),
        ]
        for (text, issue) in cases {
            let req = SessionSegmentWriter.Request(messages: [.init(id: "n0", role: "user", content: "走北门", date: time)], kind: .rolling,
                from: 0, persona: "", speakers: speakers, previous: nil, profileId: pid, windowTitle: "云桥城")
            var calls = 0
            let result = try await SessionSegmentWriter.write(req) { _, _ in calls += 1; return text }
            let written = try XCTUnwrap(result)
            XCTAssertEqual(calls, 1, issue)
            XCTAssertEqual(written.format, 2)
            XCTAssertLessThanOrEqual(written.keywords.count, 5)
            XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.note.hasPrefix("A2 软检查") && $0.note.contains(issue) && $0.note.contains("窗口「云桥城」") && $0.note.contains("段「\(written.title)」") })
        }
        XCTAssertEqual(SessionSegmentWriter.parse(raw(keywords: nil)).keywords, [])
        XCTAssertEqual(SessionSegmentWriter.softProblems(raw(title: String(repeating: "城", count: 15)), output: SessionSegmentWriter.parse(raw(title: String(repeating: "城", count: 15)))), [])
        for title in ["定云桥城路线", "现在改目的地", "在线地图"] {
            let text = raw(title: title, story: "中间取地图，然后进北门。", keywords: "甲,乙,丙,丁,戊")
            XCTAssertEqual(SessionSegmentWriter.softProblems(text, output: SessionSegmentWriter.parse(text)), [])
        }
        let text = raw(story: "然后" + String(repeating: "城", count: 596) + "最后")
        XCTAssertEqual(SessionSegmentWriter.softProblems(text, output: SessionSegmentWriter.parse(text)), [], "600字两次连接词不超密度")
    }

    func testKeywordTruncationPreservesFirstFiveUniqueWords() async throws {
        let req = SessionSegmentWriter.Request(messages: [.init(id: "n0", role: "user", content: "北门", date: time)], kind: .rolling,
            from: 0, persona: "", speakers: speakers, previous: nil)
        let result = try await SessionSegmentWriter.write(req) { _, _ in self.raw(keywords: "甲,乙，甲、丙,丁,戊,己") }
        XCTAssertEqual(result?.keywords, ["甲", "乙", "丙", "丁", "戊"])
        XCTAssertEqual(result?.pending, "取地图")
        XCTAssertEqual(result?.quotes, "岚舟：「北门。」")
    }

    func testUserAddressRejectsButQuotedAndNounUsesPass() async throws {
        for story in ["用户今天说走北门。", "我告诉用户走北门。", "用户说明天取地图。"] {
            let text = raw(story: story)
            XCTAssertNotNil(SessionSegmentWriter.a2FormatProblem(text), story)
            let req = SessionSegmentWriter.Request(messages: [.init(id: "n0", role: "user", content: "北门", date: time)], kind: .rolling,
                from: 0, persona: "", speakers: speakers, previous: nil)
            var calls = 0
            do {
                _ = try await SessionSegmentWriter.write(req) { _, _ in calls += 1; return text }
                XCTFail("不能存禁称呼")
            } catch MemoryWriterError.format {}
            XCTAssertEqual(calls, 2)
        }
        XCTAssertNotNil(SessionSegmentWriter.a2FormatProblem("标题：北门\n【经过】定路线\n【原话】用户：北门"))
        for story in ["岚舟说「用户今天说走北门」。", "整理用户说明和用户画像。", "改AI模型接口。", "新增助手功能。", "别的用户说走北门。", "整理AI说明书。", "整理助手说明。"] {
            XCTAssertNil(SessionSegmentWriter.a2FormatProblem(raw(story: story)), story)
            XCTAssertEqual(SessionSegmentWriter.softProblems(raw(story: story), output: SessionSegmentWriter.parse(raw(story: story))), [])
        }
        XCTAssertNotNil(SessionSegmentWriter.a2FormatProblem("说明\n" + raw()))
        XCTAssertNil(SessionSegmentWriter.a2FormatProblem(raw().replacingOccurrences(of: "标题：", with: "标题:")))
    }

    func testModelAddressesOnlyLogAndNeverRetry() async throws {
        for address in ["AI", "助手"] {
            for text in [raw(story: "\(address)今天说走北门。"), raw(story: "我告诉\(address)走北门。"),
                         raw(story: "\(address)说明天取地图。"), "标题：北门\n【经过】定路线\n【原话】\(address)：北门\n【关键词】北门"] {
                let req = SessionSegmentWriter.Request(messages: [.init(id: "n0", role: "user", content: "北门", date: time)], kind: .rolling,
                    from: 0, persona: "", speakers: speakers, previous: nil, profileId: pid, windowTitle: "云桥城")
                var calls = 0
                let written = try await SessionSegmentWriter.write(req) { _, _ in calls += 1; return text }
                XCTAssertEqual(written?.story, SessionSegmentWriter.parse(text).story)
                XCTAssertEqual(calls, 1)
                XCTAssertTrue(MemoryWriteLog.entries(memoryRoot: FileLibraryStore.memoryRoot(profileId: pid)).contains { $0.note.hasPrefix("A2 软检查") && $0.note.contains("不要用「\(address)」") })
            }
            let quoted = raw(story: "岚舟说「\(address)今天说走北门」。")
            XCTAssertEqual(SessionSegmentWriter.softProblems(quoted, output: SessionSegmentWriter.parse(quoted)), [])
        }
    }

    func testPreviousInputsDistinguishNewOldAndFirstWithoutPending() {
        let transcript = "这一段对话：\n\n岚舟：走北门"
        let messages = [SessionSegmentWriter.Message(id: "n6", role: "user", content: "走北门", date: time)]
        let new = segment()
        XCTAssertEqual(SessionSegmentWriter.userContent(messages: messages, speakers: speakers, previous: new, kind: .rolling),
            "上一段「定云桥城路线」全文：\n【经过】\(new.story)\n【原话】\(new.quotes)\n【关键词】云桥城，北门\n\n" + transcript)
        for old in [segment(format: 1), segment(format: 2, kind: .legacy)] {
            XCTAssertEqual(SessionSegmentWriter.userContent(messages: messages, speakers: speakers, previous: old, kind: .rolling),
                "之前的摘要（改造前写的）：\n\(SessionSummaryStore.segmentText(old))\n\n" + transcript)
        }
        XCTAssertEqual(SessionSegmentWriter.userContent(messages: messages, speakers: speakers, previous: nil, kind: .rolling),
            "（这是这个窗口记下的第一段。）\n\n" + transcript)
    }

    func testPromptContractsKeepPendingOmitTimelineAndMarkTail() {
        for kind in [SessionSegment.Kind.rolling, .closeout] {
            let sys = SessionSegmentWriter.systemPrompt(persona: "", speakers: speakers, kind: kind)
            XCTAssertTrue(sys.contains("【待续】") && sys.contains("真的没有就写「无」"))
            XCTAssertFalse(sys.contains("【时间轴】"))
            if kind == .closeout { XCTAssertTrue(sys.contains("尾段")) }
        }
    }

}
