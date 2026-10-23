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

    override func setUp() {
        super.setUp()
        container = try! ModelContainer(for: Conversation.self, MessageNode.self, Memory.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        today = Calendar.current.startOfDay(for: Date())
        yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!

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
        container = nil
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
                                        userName: "禾禾", assistantName: "小克", container: container)
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
}
