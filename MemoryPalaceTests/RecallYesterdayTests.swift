import XCTest
import SwiftData
@testable import 记忆花园

/// 修复第一刀·刀6 集成测试：复现 9/30「搜昨天的对话」——内存库造两场昨天的对话 + 当前对话，
/// 走真实 RecallTool.execute（SwiftData 检索路径）。
final class RecallYesterdayTests: XCTestCase {

    let pid = "xctest-recall-yesterday"
    var container: ModelContainer!
    var context: ModelContext!
    var yesterday: Date!
    var today: Date!
    var memoryRoot: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() {
        super.setUp()
        defaultsSuite = "RecallYesterdayTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        container = try! ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        today = Calendar.current.startOfDay(for: Date())
        yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        memoryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("recall-\(UUID().uuidString)", isDirectory: true)

        seedConversation(id: "conv-aaaa-theater", title: "剧场", day: yesterday, hour: 10,
                         lines: [("user", "我们去看了剧场《雷雨》"), ("assistant", "那场戏好看吗"), ("user", "周萍演得特别好")])
        seedConversation(id: "conv-bbbb-dinner", title: "晚饭", day: yesterday, hour: 21,
                         lines: [("user", "晚饭吃了焦糖布丁"), ("assistant", "听起来好甜")])
        seedConversation(id: "conv-cccc-current", title: "当前", day: today, hour: 0,
                         lines: [("user", "帮我搜一下昨天的对话")])
        let rel = Memory(content: "我们是彼此的恋人", category: "relationship", profileId: pid)
        context.insert(rel)
        try! context.save()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        defaultsSuite = nil
        container = nil
        try? FileManager.default.removeItem(at: memoryRoot)
        super.tearDown()
    }

    private func seedConversation(id: String, title: String, day: Date, hour: Int, lines: [(String, String)]) {
        let start = day.addingTimeInterval(TimeInterval(hour * 3600))
        var parent: String? = nil
        var lastId = ""
        for (i, (role, text)) in lines.enumerated() {
            let nid = "\(id)-n\(i)"
            let node = MessageNode(id: nid, role: role, content: text, contentType: "text",
                                   createTime: start.addingTimeInterval(TimeInterval(i * 60)), parentId: parent,
                                   childrenIds: i + 1 < lines.count ? ["\(id)-n\(i + 1)"] : [],
                                   conversationId: id, profileId: pid)
            context.insert(node)
            parent = nid
            lastId = nid
        }
        let conv = Conversation(id: id, title: title, createTime: start,
                                updateTime: start.addingTimeInterval(TimeInterval(lines.count * 60)),
                                currentNodeId: lastId, profileId: pid)
        context.insert(conv)
    }

    private func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    private func run(_ args: [String: Any], current: String? = "conv-cccc-current") async -> RecallTool.ExecResult {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return await RecallTool.execute(inputJSON: json, profileId: pid, currentConversationId: current,
                                        userName: "禾禾", assistantName: "小克", container: container,
                                        memoryRoot: memoryRoot, embedder: RecordingMemoryEmbedder(ready: false),
                                        defaults: defaults)
    }

    func testBrowseYesterdayListsOtherConversationsNotRequest() async {
        let r = await run(["date": dayString(yesterday)])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("翻到 2 个对话"), r.text)
        XCTAssertTrue(r.text.contains("剧场"), r.text)
        XCTAssertTrue(r.text.contains("晚饭"), r.text)
        XCTAssertFalse(r.text.contains("帮我搜一下昨天的对话"), "请求本身不能出现")
        XCTAssertLessThan(r.text.range(of: "剧场")!.lowerBound, r.text.range(of: "晚饭")!.lowerBound, "按时间先后")
    }

    func testOldStyleRangeNowMeansYesterdayOnly() async {
        // 9/30 小克实际填的参数：after=昨天 before=今天 —— 现在 before 不含当天，只看昨天
        let r = await run(["after": dayString(yesterday), "before": dayString(today)], current: nil)
        XCTAssertTrue(r.text.contains("翻到 2 个对话"), r.text)
        XCTAssertFalse(r.text.contains("帮我搜一下"), "当天的对话被 before 排除")
    }

    func testKeywordSearchExcludesCurrentConversation() async {
        let r = await run(["query": "昨天"])
        XCTAssertFalse(r.text.contains("帮我搜一下昨天的对话"), r.text)
    }

    func testExplicitConversationIdSearchesCurrent() async {
        let r = await run(["query": "昨天", "conversation_id": "conv-cccc-current"])
        XCTAssertTrue(r.text.contains("帮我搜一下昨天的对话"), r.text)
    }

    func testRelationshipMemorySearchable() async {
        let r = await run(["query": "恋人"])
        XCTAssertTrue(r.text.contains("记忆·关系"), r.text)
        XCTAssertEqual(r.hitMemoryIds.count, 1)
    }

    func testNoQueryNoDateIsError() async {
        let r = await run([:])
        XCTAssertTrue(r.isError)
    }

    private func seedA2(_ conversationId: String, story: String, day: Date? = nil) throws {
        let start = (day ?? yesterday).addingTimeInterval(12 * 3600)
        let segment = SessionSegment(kind: .rolling, title: "航线", start: start, end: start.addingTimeInterval(60),
                                     from: 0, to: 2, lastNodeId: nil, story: story, quotes: "", pending: "")
        try SessionSummaryStore.save(SessionSummary(conversationId: conversationId, title: "航线笔记",
                                                    compressedCount: 2, segments: [segment], updatedAt: start),
                                     in: SessionSummaryStore.dir(root: memoryRoot))
    }

    @MainActor
    func testRecallChineseSubstringFindsMemoryButExactStillSearchesOnlyOriginalText() async throws {
        let originalMarker = "original-only-cloudbridge"
        let memoryMarker = "l1-only-cloudbridge"
        seedConversation(id: "conv-cloudbridge-original", title: "合成原话", day: yesterday, hour: 14,
                         lines: [("user", "云桥城原话 \(originalMarker)")])
        let target = Memory(content: "云桥城地图画好了 \(memoryMarker)", category: "fact", profileId: pid)
        [target, Memory(content: "云", category: "fact", profileId: pid),
         Memory(content: "桥", category: "fact", profileId: pid)].forEach { context.insert($0) }
        try context.save()
        let recalled = await run(["query": "云桥城"])
        XCTAssertFalse(recalled.isError)
        XCTAssertEqual(recalled.hitMemoryIds, [target.id])
        XCTAssertTrue(recalled.text.contains(target.content))
        let exact = await run(["query": "云桥城", "exact": true])
        XCTAssertEqual(exact.hitMemoryIds, [])
        XCTAssertFalse(exact.isError, exact.text)
        XCTAssertTrue(exact.text.contains(originalMarker), exact.text)
        XCTAssertTrue(exact.text.contains("云桥城原话"), exact.text)
        XCTAssertFalse(exact.text.contains(memoryMarker), exact.text)
        XCTAssertFalse(exact.text.contains(target.content))
    }

    func testStructuredL1KeepsProfileValidityDatesAndPriority() throws {
        let low = Memory(content: "marble low", category: "fact", profileId: pid)
        low.importance = 1
        low.createdAt = yesterday
        let high = Memory(content: "marble high", category: "fact", profileId: pid, isUserExplicit: true)
        high.importance = 5
        high.createdAt = yesterday
        let invalid = Memory(content: "marble obsolete", category: "fact", profileId: pid)
        invalid.supersededAt = today
        invalid.createdAt = yesterday
        let foreign = Memory(content: "marble foreign", category: "fact", profileId: "other-floor")
        let outside = Memory(content: "marble future", category: "fact", profileId: pid)
        outside.createdAt = today
        [low, high, invalid, foreign, outside].forEach { context.insert($0) }
        try context.save()
        let embedder = RecordingMemoryEmbedder(ready: false)
        let result = RecallTool.searchL1(query: "marble", profileId: pid, includeInvalid: false,
                                         after: yesterday, beforeExclusive: today, context: context, embedder: embedder)
        XCTAssertEqual(result.hits.map(\.id), [high.id, low.id])
        XCTAssertTrue(result.vectorStatus?.contains("不可用") == true)
        let withInvalid = RecallTool.searchL1(query: "marble", profileId: pid, includeInvalid: true,
                                              after: yesterday, beforeExclusive: today, context: context, embedder: embedder)
        XCTAssertEqual(Set(withInvalid.hits.map(\.id)), Set([high.id, low.id, invalid.id]))
        XCTAssertEqual(withInvalid.hits.first { $0.id == invalid.id }?.invalid, true)
        XCTAssertTrue(embedder.embeddedTexts.isEmpty)
    }

    func testRecallALineUsesBM25AndConversationVisibilityBeforePresentation() async throws {
        let visible = "conv-aaaa-theater"
        let current = "conv-cccc-current"
        let deleted = Conversation(id: "deleted-0001", title: "回收站", createTime: yesterday, updateTime: yesterday, currentNodeId: "", profileId: pid)
        deleted.isTrashed = true
        let foreign = Conversation(id: "foreign-0001", title: "别层", createTime: yesterday, updateTime: yesterday, currentNodeId: "", profileId: "other-floor")
        context.insert(deleted)
        context.insert(foreign)
        try context.save()
        try seedA2(visible, story: "marble 铜铃航线")
        try seedA2(current, story: "marble 当前隐藏")
        try seedA2(deleted.id, story: "marble 回收隐藏")
        try seedA2(foreign.id, story: "marble 别层隐藏")
        try seedA2("orphan-0001", story: "marble 孤立隐藏")
        let structured = RecallTool.searchALine(terms: ["marble separate"], memoryRoot: memoryRoot,
                                                conversationIds: [visible])
        XCTAssertEqual(structured.hits.map(\.conversationId), [visible])
        XCTAssertEqual(structured.hits.first?.segment, 1)
        let result = await run(["query": "marble separate"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("铜铃航线"), result.text)
        XCTAssertFalse(result.text.contains("当前隐藏"), result.text)
        XCTAssertFalse(result.text.contains("回收隐藏"), result.text)
        XCTAssertFalse(result.text.contains("别层隐藏"), result.text)
        XCTAssertFalse(result.text.contains("孤立隐藏"), result.text)
        XCTAssertTrue(result.hitMemoryIds.isEmpty)
        let exact = await run(["query": "marble separate", "exact": true])
        XCTAssertFalse(exact.text.contains("铜铃航线"))
        let dated = RecallTool.searchALine(terms: ["marble"], in: DateInterval(start: today, end: today.addingTimeInterval(86400)),
                                           memoryRoot: memoryRoot, conversationIds: [visible])
        XCTAssertTrue(dated.hits.isEmpty)
    }

    @MainActor
    func testRecallMasterGateUsesPrivateDefaultsAndKeepsOriginalsSearchable() async throws {
        let marker = "master-gate-original"
        seedConversation(id: "conv-master-gate", title: "合成开关原话", day: yesterday, hour: 15,
                         lines: [("user", "铜鹤 \(marker)")])
        let memory = Memory(content: "铜鹤 memory-only-gate", category: "fact", profileId: pid)
        context.insert(memory)
        try context.save()

        XCTAssertNil(defaults.object(forKey: "mem_master"))
        let inheritedDefault = await run(["query": "铜鹤"])
        XCTAssertEqual(inheritedDefault.hitMemoryIds, [memory.id])

        defaults.set(false, forKey: "mem_master")
        let disabled = await run(["query": "铜鹤"])
        XCTAssertFalse(disabled.isError, disabled.text)
        XCTAssertTrue(disabled.text.contains(marker), disabled.text)
        XCTAssertTrue(disabled.hitMemoryIds.isEmpty)
        XCTAssertFalse(disabled.text.contains(memory.content), disabled.text)

        defaults.set(true, forKey: "mem_master")
        let enabled = await run(["query": "铜鹤"])
        XCTAssertEqual(enabled.hitMemoryIds, [memory.id])
    }

    @MainActor
    func testRecallL1DropsCommonBigramNoiseBeforePriorityAndFirstFourLimit() async throws {
        let target = Memory(content: "上次说的旅行计划：到海边看灯塔", category: "fact", profileId: pid)
        target.importance = 3
        context.insert(target)
        var noiseIds = Set<UUID>()
        for index in 0..<24 {
            let noise = Memory(content: "上次说的共同闲聊 noise-\(index)", category: "fact", profileId: pid)
            noise.importance = 5
            context.insert(noise)
            noiseIds.insert(noise.id)
        }
        try context.save()

        let result = await run(["query": "上次说的旅行计划"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.hitMemoryIds, [target.id], result.text)
        XCTAssertTrue(result.text.contains(target.content), result.text)
        XCTAssertTrue(Set(result.hitMemoryIds).isDisjoint(with: noiseIds))
        XCTAssertFalse(result.text.contains("noise-"), result.text)
    }

    @MainActor
    func testRecallL1ShortNameRequiresWholeNameRatherThanSharedSuffix() async throws {
        let target = Memory(content: "张小明在海边写生", category: "fact", profileId: pid)
        target.importance = 3
        let partial = Memory(content: "小明在山里散步", category: "fact", profileId: pid)
        partial.importance = 5
        context.insert(target)
        context.insert(partial)
        try context.save()

        let result = await run(["query": "张小明"])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.hitMemoryIds, [target.id], result.text)
        XCTAssertTrue(result.text.contains(target.content), result.text)
        XCTAssertFalse(result.text.contains(partial.content), result.text)
    }
}
