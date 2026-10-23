import XCTest
@testable import 记忆花园

/// #089 P0-c：发出去那一刻存的请求体（按对话最近一个回合、去 key、后台落盘、30 个对话上限）
@MainActor
final class SentRequestStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SentRequestStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func request(_ body: String, url: String = "https://api.example.com/v1/messages?key=sk-secret-123456") -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpBody = Data(body.utf8)
        r.setValue("sk-secret-123456", forHTTPHeaderField: "x-api-key")
        return r
    }

    func testRecordsEverySendInTurnAndRedacts() async {
        let store = SentRequestStore(directory: dir)
        store.record(conversationId: "c1", turnId: "a1", round: 0, model: "m", request: request(#"{"a":"sk-secret-123456"}"#), secrets: ["sk-secret-123456"])
        store.record(conversationId: "c1", turnId: "a1", round: 0, model: "m", request: request(#"{"retry":1}"#), secrets: [])
        store.record(conversationId: "c1", turnId: "a1", round: 1, model: "m", request: request(#"{"b":1}"#), secrets: [])
        XCTAssertEqual(store.version("c1"), 3, "每次存都刷新检查器")
        let turn = await store.latest(conversationId: "c1")
        XCTAssertEqual(turn?.requests.map(\.round), [0, 0, 1], "上限越界重试也留着（astra #7）")
        XCTAssertEqual(turn?.requests.first?.body, #"{"a":"<API key>"}"#)
        XCTAssertEqual(turn?.requests.first?.url, "https://api.example.com/v1/messages", "地址去掉 query")

        store.record(conversationId: "c1", turnId: "a2", round: 0, model: "m", request: request(#"{"c":0}"#), secrets: [])
        let next = await store.latest(conversationId: "c1")
        XCTAssertEqual(next?.requests.map(\.body), [#"{"c":0}"#], "换了 assistant 节点 = 新回合，旧回合清掉")
    }

    /// astra #1：JSON 序列化把 / 转成 \/，工具参数字符串里还会再转一次；短 key 也换
    func testRedactsEscapedForms() {
        let key = "proxy/abcdefgh"
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: [
            "text": "我的 key 是 \(key)",
            "arguments": String(decoding: try! JSONSerialization.data(withJSONObject: ["k": key]), as: UTF8.self),
        ]), as: UTF8.self)
        XCTAssertFalse(body.contains(key), "前提：序列化后原文已经被转义")
        let red = SentRequestStore.redact(body, secrets: [key])
        let decoded = try! JSONSerialization.jsonObject(with: Data(red.utf8)) as! [String: String]
        XCTAssertEqual(decoded["text"], "我的 key 是 <API key>")
        XCTAssertFalse(decoded["arguments"]!.contains("abcdefgh"), decoded["arguments"]!)
        XCTAssertEqual(SentRequestStore.redact("x abc y", secrets: ["", "abc"]), "x <API key> y", "只跳过空 key")
    }

    func testPersistsAndReloadsAfterRestart() async throws {
        let store = SentRequestStore(directory: dir)
        store.record(conversationId: "c2", turnId: "a", round: 0, model: "m", request: request(#"{"x":1}"#), secrets: [])
        try await waitForFile("c2.json")
        let fresh = SentRequestStore(directory: dir)
        let turn = await fresh.latest(conversationId: "c2")
        XCTAssertEqual(turn?.requests.first?.body, #"{"x":1}"#)
        let missing = await fresh.latest(conversationId: "nope")
        XCTAssertNil(missing)
    }

    /// astra #8：磁盘和内存都只留 30 个对话
    func testPrunesToLatestConversations() async throws {
        let store = SentRequestStore(directory: dir)
        for i in 0..<(SentRequestStore.keepConversations + 3) {
            store.record(conversationId: "p\(i)", turnId: "a", round: 0, model: "m", request: request("{}"), secrets: [])
        }
        try await waitForFile("p\(SentRequestStore.keepConversations + 2).json")
        try await Task.sleep(nanoseconds: 200_000_000)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, SentRequestStore.keepConversations)
        let evicted = await store.latest(conversationId: "p0")
        XCTAssertNil(evicted, "最早那个内存里也清了，盘上也没了")
        let kept = await store.latest(conversationId: "p\(SentRequestStore.keepConversations + 2)")
        XCTAssertNotNil(kept)
    }

    private func waitForFile(_ name: String) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
