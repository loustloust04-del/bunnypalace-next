import XCTest
@testable import 记忆花园

/// 小芽历史有序写盘（sol #9）：同一个写入器排队 + 版本号，旧快照晚到不能盖掉已经落盘的新快照。临时目录，不碰真实 AssistantChat/
final class AssistantChatWriterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chat-writer-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func texts(_ store: AssistantChatStore) -> [String] { store.load().map(\.text) }

    func testStaleSnapshotNeverOverwritesNewer() async {
        let store = AssistantChatStore(fileURL: dir.appendingPathComponent("history.json"))
        let writer = AssistantChatWriter(store: store)
        let newer = await writer.save([AssistantChatMessage(isUser: true, text: "新")], version: 2)
        let stale = await writer.save([AssistantChatMessage(isUser: true, text: "旧")], version: 1)
        XCTAssertTrue(newer)
        XCTAssertFalse(stale, "旧版本晚到：丢掉")
        XCTAssertEqual(texts(store), ["新"])
        let repeated = await writer.save([AssistantChatMessage(isUser: true, text: "同版本")], version: 2)
        XCTAssertFalse(repeated)
        await writer.save([AssistantChatMessage(isUser: true, text: "更新")], version: 3)
        XCTAssertEqual(texts(store), ["更新"])
    }

    /// 乱序并发提交：最后落盘的一定是版本最大的那份
    func testConcurrentOutOfOrderSavesKeepHighestVersion() async {
        let store = AssistantChatStore(fileURL: dir.appendingPathComponent("history.json"))
        let writer = AssistantChatWriter(store: store)
        await withTaskGroup(of: Void.self) { group in
            for version in (1...40).shuffled() {
                group.addTask { await writer.save([AssistantChatMessage(isUser: true, text: "v\(version)")], version: version) }
            }
        }
        XCTAssertEqual(texts(store), ["v40"])
    }

    /// 引擎接线：连改几次只落最后一份
    @MainActor
    func testEngineSavesLatestSnapshot() async throws {
        let chat = dir.appendingPathComponent("AssistantChat", isDirectory: true)
        let suite = "AssistantChatWriterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AssistantChatStore(fileURL: chat.appendingPathComponent("history.json"))
        let engine = AssistantEngine(store: store, ledger: AssistantLedger(fileURL: chat.appendingPathComponent("ledger.json")),
                                     packDefaults: defaults, scriptPacing: .instant)
        engine.messages.append(AssistantChatMessage(isUser: true, text: "一"))
        try await Task.sleep(for: .milliseconds(700))
        engine.messages.append(AssistantChatMessage(isUser: true, text: "二"))
        engine.messages.append(AssistantChatMessage(isUser: true, text: "三"))
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(texts(store), ["一", "二", "三"])
    }
}
