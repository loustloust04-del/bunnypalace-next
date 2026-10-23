#if os(macOS)
import XCTest
@testable import 记忆花园

/// N3-d 父子关系同步（Wake `sync_parent_links` 全链路）：Grok 子代理链扁平到根、子会话项目跟父、重解析不冲掉关系、边车删掉后解除并
/// 从子会话自己的文件恢复项目；Hermes 关系来自快照；监听把关系边车事件标给调用方。全在 tmp
final class CodingParentLinksTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-parent-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var sessions: URL { dir.appendingPathComponent(".grok/sessions") }

    @discardableResult
    private func grokSession(_ group: String, _ id: String, cwd: String, title: String) throws -> URL {
        let session = sessions.appendingPathComponent(group).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try #"{"timestamp":1786014300,"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"\#(title)"}}}}"#
            .appending("\n").write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        try #"{"info":{"cwd":"\#(cwd)"},"generated_title":"\#(title)","created_at":"2026-08-06T11:00:00Z","updated_at":"2026-08-06T11:20:00Z"}"#
            .write(to: session.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        return session
    }

    private func register(child: String, under parent: URL) throws {
        let meta = parent.appendingPathComponent("subagents").appendingPathComponent(child)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try #"{"parent_session_id":"\#(parent.lastPathComponent)","child_session_id":"\#(child)"}"#
            .write(to: meta.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    }

    func testGrokLinksFlattenFollowParentProjectSurviveReparseAndDetach() throws {
        let parent = try grokSession("%2FUsers%2Ftester%2Fproj", "p-1", cwd: "/Users/tester/proj", title: "父会话")
        let child = try grokSession("%2Ftmp%2Fwt-a", "c-1", cwd: "/tmp/wt-a", title: "子会话")
        try grokSession("%2Ftmp%2Fwt-b", "c-2", cwd: "/tmp/wt-b", title: "孙会话")
        try register(child: "c-1", under: parent)
        try register(child: "c-2", under: child)
        let grok = GrokAdapter(home: dir)
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("index.sqlite"))
        let scanner = CodingSessionScanner(index: index, adapters: [grok])

        let report = try scanner.run()
        XCTAssertTrue(report.linksChanged)
        XCTAssertEqual(try index.session(key: "grok:c-1")?.parentKey, "grok:p-1")
        XCTAssertEqual(try index.session(key: "grok:c-2")?.parentKey, "grok:p-1", "嵌套链扁平到根")
        XCTAssertEqual(try index.session(key: "grok:c-2")?.projectPath, "/Users/tester/proj", "子会话项目跟父")
        XCTAssertEqual(try index.session(key: "grok:p-1")?.parentKey, "")

        // 重解析子会话（监听增量）：upsert 不覆盖 parent_key，收尾同步再把项目覆写回父项目
        let childRef = try XCTUnwrap(grok.fileRef(child.appendingPathComponent("updates.jsonl")))
        _ = try scanner.scanFiles([childRef])
        XCTAssertEqual(try index.session(key: "grok:c-1")?.parentKey, "grok:p-1", "重解析不冲掉同步好的关系")
        XCTAssertEqual(try index.session(key: "grok:c-1")?.projectPath, "/Users/tester/proj")
        XCTAssertFalse(try scanner.run().linksChanged, "关系没变 = 没有行变")

        // 父会话的登记边车删掉：c-1 解除并从自己的文件恢复项目，c-2 改挂到新的根 c-1
        try FileManager.default.removeItem(at: parent.appendingPathComponent("subagents"))
        XCTAssertTrue(try scanner.refreshParentLinks([.grok]))
        XCTAssertEqual(try index.session(key: "grok:c-1")?.parentKey, "", "父子关系解除")
        XCTAssertEqual(try index.session(key: "grok:c-1")?.projectPath, "/tmp/wt-a", "从子会话自己的文件重解析，恢复它自己的项目")
        XCTAssertEqual(try index.session(key: "grok:c-2")?.parentKey, "grok:c-1", "孙会话改挂到新的根")
        XCTAssertEqual(try index.session(key: "grok:c-2")?.projectPath, "/tmp/wt-a")
        XCTAssertFalse(try scanner.refreshParentLinks([.claudeCode]), "不管父子关系的家不刷")
    }

    func testFlattenedParentStopsOnCycles() {
        XCTAssertEqual(CodingSessionScanner.flattenedParent("a", ["a": "b", "b": "c"]), "c")
        XCTAssertNil(CodingSessionScanner.flattenedParent("a", ["a": "b", "b": "a"]), "成环 = 无根")
    }

    func testHermesLinksComeFromSnapshot() throws {
        let hermes = dir.appendingPathComponent("h/.hermes")
        try FileManager.default.createDirectory(at: hermes, withIntermediateDirectories: true)
        CodingContract.execSQL(hermes.appendingPathComponent("state.db"), HermesAdapterContractTests.fixtureSQL)
        let index = try CodingSessionIndex(url: dir.appendingPathComponent("hermes-index.sqlite"))
        let scanner = CodingSessionScanner(index: index, adapters: [HermesAdapter.make(home: dir.appendingPathComponent("h"), environment: [:])])
        _ = try scanner.run()
        XCTAssertEqual(try index.session(key: "hermes:hs-0005")?.parentKey, "hermes:hs-0001")
        XCTAssertEqual(try index.session(key: "hermes:hs-0001")?.parentKey, "")
    }

    func testWatcherFlagsParentLinkEvents() throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let fired = expectation(description: "parent-link batch")
        let watcher = CodingSessionWatcher(adapters: [GrokAdapter(home: dir)]) { batch in
            if batch.parentLinkAgents == [.grok] { fired.fulfill() }
        }
        watcher.record([sessions.appendingPathComponent("g/p-1/subagents/c-1/meta.json").path], [0])
        wait(for: [fired], timeout: 5)
    }
}
#endif
