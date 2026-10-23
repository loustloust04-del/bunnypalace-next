import XCTest
@testable import 记忆花园

/// 第二刀 B2：remember / edit_memory / forget_memory + 每日上限 + 正文字数上限。
final class SelfMemoryToolTests: XCTestCase {

    let pid = "xctest-self-memory-tool"
    private let keys = ["mem_self_daily_limit", "mem_self_body_limit"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        for k in keys { if let v = d.object(forKey: k) { saved[k] = v }; d.removeObject(forKey: k) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: FileLibraryStore.memoryRoot(profileId: pid).deletingLastPathComponent())
        let d = UserDefaults.standard
        for k in keys { d.removeObject(forKey: k) }
        for (k, v) in saved { d.set(v, forKey: k) }
        super.tearDown()
    }

    private func run(_ tool: String, _ args: [String: Any], now: Date = Date()) -> SelfMemoryTool.Result {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        return SelfMemoryTool.execute(name: tool, inputJSON: json, profileId: pid, conversationId: "conv-1", now: now)
    }

    func testToolsRegisteredWithRequiredFields() {
        let defs = Dictionary(uniqueKeysWithValues: SelfMemoryTool.definitions.map { ($0.name, $0) })
        XCTAssertEqual(Set(defs.keys), SelfMemoryTool.names)
        XCTAssertEqual(defs["remember"]?.required, ["name", "description", "body"])
        // #069：文件夹分工挪进系统提示〔我的记忆〕只说一次，三个工具说明不再各拼一遍
        XCTAssertFalse(defs.values.contains { $0.description.contains("memory/cc/") })
    }

    /// 返工（Air 验收：说「记住」只建了日历）：说明里写死「必须调」且日历不能代替；系统提示有固定一句
    func testRememberIsMandatoryWhenAsked() {
        let desc = SelfMemoryTool.definitions.first { $0.name == SelfMemoryTool.rememberName }?.description ?? ""
        XCTAssertTrue(desc.contains("必须调这个工具"))
        XCTAssertTrue(desc.contains("不能代替 remember"))
        let hint = SelfMemoryTool.systemHint(available: [SelfMemoryTool.rememberName])
        XCTAssertTrue(hint.contains("remember"))
        XCTAssertTrue(hint.contains("日程不算记住"))
        XCTAssertTrue(hint.contains("不要写成文件"))
    }

    /// #069：分工段只提这一轮下发了的工具（recall / fs_read 没发就不提）
    func testSystemHintMentionsOnlyAvailableTools() {
        let bare = SelfMemoryTool.systemHint(available: [SelfMemoryTool.rememberName])
        XCTAssertFalse(bare.contains("recall"))
        XCTAssertFalse(bare.contains("fs_read"))
        let full = SelfMemoryTool.systemHint(available: [SelfMemoryTool.rememberName, RecallTool.toolName, "fs_read"])
        XCTAssertTrue(full.contains("recall"))
        XCTAssertTrue(full.contains("fs_read"))
        XCTAssertFalse(full.contains("原子档案"))
    }

    func testRememberWritesFileAndIndex() {
        let r = run(SelfMemoryTool.rememberName, ["name": "复诊", "description": "她明天要去复诊", "body": "她说「明天要去复诊」", "asked_by_user": true, "importance": 4])
        XCTAssertFalse(r.isError, r.text)
        let list = SelfMemoryStore.list(profileId: pid)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].origin, "asked")
        XCTAssertEqual(list[0].importance, 4)
        XCTAssertEqual(list[0].source, "conv-1")
        XCTAssertTrue(SelfMemoryStore.indexText(list).contains("她明天要去复诊"))
    }

    func testMissingFieldsIsError() {
        XCTAssertTrue(run(SelfMemoryTool.rememberName, ["name": "a"]).isError)
    }

    func testDailyLimitCountsOnlySelf() {
        UserDefaults.standard.set(2, forKey: "mem_self_daily_limit")
        XCTAssertFalse(run(SelfMemoryTool.rememberName, ["name": "a", "description": "a", "body": "a"]).isError)
        XCTAssertFalse(run(SelfMemoryTool.rememberName, ["name": "b", "description": "b", "body": "b"]).isError)
        XCTAssertTrue(run(SelfMemoryTool.rememberName, ["name": "c", "description": "c", "body": "c"]).isError, "自己主动的第 3 条被拦")
        XCTAssertFalse(run(SelfMemoryTool.rememberName, ["name": "d", "description": "d", "body": "d", "asked_by_user": true]).isError, "她让记的不受限")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        XCTAssertFalse(run(SelfMemoryTool.rememberName, ["name": "e", "description": "e", "body": "e"], now: tomorrow).isError, "第二天清零")
    }

    func testBodyLimit() {
        UserDefaults.standard.set(10, forKey: "mem_self_body_limit")
        XCTAssertTrue(run(SelfMemoryTool.rememberName, ["name": "a", "description": "a", "body": String(repeating: "字", count: 11)]).isError)
    }

    func testEditAndForget() {
        _ = run(SelfMemoryTool.rememberName, ["name": "剧场", "description": "旧摘要", "body": "旧", "asked_by_user": true])
        XCTAssertFalse(run(SelfMemoryTool.editName, ["target": "剧场", "description": "新摘要", "importance": 5]).isError)
        var m = SelfMemoryStore.list(profileId: pid)[0]
        XCTAssertEqual(m.description, "新摘要")
        XCTAssertEqual(m.importance, 5)
        XCTAssertEqual(m.origin, "asked", "改不改变来源")
        XCTAssertFalse(run(SelfMemoryTool.forgetName, ["target": "剧场"]).isError)
        m = SelfMemoryStore.list(profileId: pid)[0]
        XCTAssertNotNil(m.superseded, "标失效不删文件")
        XCTAssertFalse(SelfMemoryStore.indexText(SelfMemoryStore.list(profileId: pid)).contains("新摘要"), "失效的出索引")
        XCTAssertTrue(run(SelfMemoryTool.editName, ["target": "不存在"]).isError)
    }
}
