import XCTest
import CryptoKit
@testable import 记忆花园

/// 小芽 v2 P4 本地大脑（plan-小芽-v2 §6，astra A7/B7）：一轮收集器 + 模型下载（假网络，不碰真 HF）
final class AssistantLocalTurnTests: XCTestCase {
    func testToolCallsWinAndTerminateOnce() {
        var turn = AssistantLocalTurn()
        turn.append(chunk: "我看看")
        turn.append(call: "read_world_book", argumentsJSON: #"{"bookName":"花园"}"#)
        turn.append(call: "read_current_preset", argumentsJSON: "{}")
        guard case .toolCalls(let calls) = turn.terminal else { return XCTFail() }
        XCTAssertEqual(calls.map(\.name), ["read_world_book", "read_current_preset"])
        XCTAssertNotEqual(calls[0].id, calls[1].id)
    }

    func testGarbledToolMarkupBecomesFailure() {
        var turn = AssistantLocalTurn()
        turn.append(chunk: #"<tool_call>{"name": "propose_update"#)
        guard case .failed(let message) = turn.terminal else { return XCTFail() }
        XCTAssertEqual(message, AssistantLocalTurn.garbledReply)
    }

    func testPlainText() {
        var turn = AssistantLocalTurn()
        turn.append(chunk: "  你好呀 ")
        guard case .finished(let text) = turn.terminal else { return XCTFail() }
        XCTAssertEqual(text, "你好呀")
    }

    func testToolSpecsBecomeSendableRecursively() {
        let spec = LocalLLMService.sendable(["type": "function", "function": ["name": "x", "parameters": ["required": ["a"]]]] as [String: Any])
        XCTAssertNotNil(spec as? [String: any Sendable])
    }

    /// 追的那一句插在它说谎的位置：之前的工具回合 → 假话 + 提醒 → 之后的工具回合
    func testNudgeSitsBetweenToolTurns() {
        let call = ToolCallBlock(id: "c1", name: "read_character", argumentsJSON: "{}")
        let turn = ToolTurn(calls: [call], results: [ToolResultBlock(toolUseId: "c1", text: "卡库空的", isError: false)])
        let request = AssistantBackendRequest(system: "s", history: [(role: "user", content: "写张卡")], tools: [],
                                              toolTurns: [turn, turn], nudge: AssistantNudge(afterTurns: 1, reply: "看看预览卡片～"))
        let roles = LocalLLMService.chat(for: request).map { "\($0.role)" }
        XCTAssertEqual(roles, ["system", "user", "assistant", "tool", "assistant", "user", "assistant", "tool"])
        let tail = AssistantBackendRequest(system: "s", history: [], tools: [], toolTurns: [],
                                           nudge: AssistantNudge(afterTurns: 0, reply: "看看预览卡片～"))
        XCTAssertEqual(LocalLLMService.chat(for: tail).last?.content, AssistantNudge.note)
    }
}

/// 假网络：按 host 决定行为，支持 Range
final class ModelStubProtocol: URLProtocol {
    nonisolated(unsafe) static var files: [String: Data] = [:]          // 文件名 → 内容
    nonisolated(unsafe) static var brokenHosts: Set<String> = []        // 这些 host 一律 500
    nonisolated(unsafe) static var ignoreRange = false                  // 服务器不理 Range，回 200 全量
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        let name = url.lastPathComponent
        func respond(_ code: Int, _ headers: [String: String], _ body: Data) {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if Self.brokenHosts.contains(url.host ?? "") { return respond(500, [:], Data()) }
        guard let data = Self.files[name] else { return respond(404, [:], Data()) }
        if !Self.ignoreRange, let range = request.value(forHTTPHeaderField: "Range"),
           let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            if start >= data.count { return respond(416, [:], Data()) }
            return respond(206, ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"], data.subdata(in: start..<data.count))
        }
        respond(200, [:], data)
    }
}

@MainActor
final class AssistantModelStoreTests: XCTestCase {
    private var root: URL!
    private let weights = Data((0..<200_000).map { UInt8($0 % 251) })
    private let config = Data(#"{"model_type":"qwen3"}"#.utf8)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xiaoya-models-\(UUID().uuidString)")
        ModelStubProtocol.files = ["config.json": config, "model.safetensors": weights]
        ModelStubProtocol.brokenHosts = []
        ModelStubProtocol.ignoreRange = false
        ModelStubProtocol.requests = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model(sha: String? = nil) -> AssistantLocalModel {
        let digest = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
        return AssistantLocalModel(id: "tiny", title: "t", detail: "", repo: "test/tiny", revision: "abc",
                                   files: [.init(name: "config.json", size: Int64(config.count)),
                                           .init(name: "model.safetensors", size: Int64(weights.count), sha256: sha ?? digest)])
    }

    private func store(_ m: AssistantLocalModel) -> AssistantModelStore {
        let conf = URLSessionConfiguration.ephemeral
        conf.protocolClasses = [ModelStubProtocol.self]
        return AssistantModelStore(root: root, catalog: [m], hosts: ["https://hf.test", "https://mirror.test"], sessionConfiguration: conf)
    }

    private func wait(_ store: AssistantModelStore, _ m: AssistantLocalModel, until done: (AssistantModelStore.State) -> Bool) async {
        for _ in 0..<200 {
            if done(store.state(m)) { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testDownloadVerifiesAndInstallsAtomically() async throws {
        let m = model()
        let s = store(m)
        s.download(m)
        await wait(s, m) { $0 == .installed }
        XCTAssertEqual(s.state(m), .installed)
        let installed = s.installedURL(m)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("model.safetensors")), weights)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tiny.partial").path), "partial 没换名")
        XCTAssertTrue(ModelStubProtocol.requests.allSatisfy { $0.url!.path.contains("/resolve/abc/") }, "没钉 revision")
    }

    func testFallsBackToMirror() async throws {
        ModelStubProtocol.brokenHosts = ["hf.test"]
        let m = model()
        let s = store(m)
        s.download(m)
        await wait(s, m) { $0 == .installed }
        XCTAssertEqual(s.state(m), .installed)
        XCTAssertTrue(ModelStubProtocol.requests.contains { $0.url?.host == "mirror.test" })
    }

    func testResumesWithRange() async throws {
        let m = model()
        let partial = root.appendingPathComponent("tiny.partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try weights.prefix(80_000).write(to: partial.appendingPathComponent("model.safetensors"))
        let s = store(m)
        if case .paused(let received, _) = s.state(m) { XCTAssertEqual(received, 80_000) } else { XCTFail("有半截文件应显示已暂停") }
        s.download(m)
        await wait(s, m) { $0 == .installed }
        XCTAssertEqual(s.state(m), .installed)
        XCTAssertTrue(ModelStubProtocol.requests.contains { $0.value(forHTTPHeaderField: "Range") == "bytes=80000-" })
        XCTAssertEqual(try Data(contentsOf: s.installedURL(m).appendingPathComponent("model.safetensors")), weights)
    }

    /// 服务器不理 Range（回 200）：从头写，不能把全量接在半截后面
    func testIgnoredRangeRewritesFromStart() async throws {
        ModelStubProtocol.ignoreRange = true
        let m = model()
        let partial = root.appendingPathComponent("tiny.partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try weights.prefix(50_000).write(to: partial.appendingPathComponent("model.safetensors"))
        let s = store(m)
        s.download(m)
        await wait(s, m) { $0 == .installed }
        XCTAssertEqual(try Data(contentsOf: s.installedURL(m).appendingPathComponent("model.safetensors")), weights)
    }

    func testChecksumMismatchFailsAndDeletes() async throws {
        let m = model(sha: String(repeating: "0", count: 64))
        let s = store(m)
        s.download(m)
        await wait(s, m) { if case .failed = $0 { return true }; return false }
        guard case .failed = s.state(m) else { return XCTFail("\(s.state(m))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.installedURL(m).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tiny.partial/model.safetensors").path))
    }

    func testDeleteRemovesEverything() async throws {
        let m = model()
        let s = store(m)
        s.download(m)
        await wait(s, m) { $0 == .installed }
        s.delete(m)
        XCTAssertEqual(s.state(m), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.installedURL(m).path))
    }
}


/// v3 §1 / §2：主聊天本机 provider 的上下文封顶 + 小芽模型选择迁移
final class LocalChatProviderTests: XCTestCase {
    func testTrimKeepsNewestWithinBudget() {
        let old = (role: "user", content: String(repeating: "旧", count: 4000))
        let mid = (role: "assistant", content: String(repeating: "中", count: 1500))
        let new = (role: "user", content: "最新一句")
        let result = LocalChatProvider.trimmed(system: String(repeating: "设", count: 5000), messages: [old, mid, new], hasImages: false)
        XCTAssertEqual(result.system.count, LocalChatProvider.systemBudget + 1)
        XCTAssertEqual(result.history.map(\.content), [mid.content, new.content])
    }

    func testOversizedLastMessageIsCutNotDropped() {
        let huge = (role: "user", content: String(repeating: "长", count: 9000))
        let result = LocalChatProvider.trimmed(system: "", messages: [huge], hasImages: true)
        XCTAssertEqual(result.history.count, 1)
        XCTAssertTrue(result.system.contains("看不到图片"))
        XCTAssertLessThanOrEqual(result.history[0].content.count, LocalChatProvider.totalBudget)
    }

    func testLegacyLocalToggleMigrates() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "xy-migrate-\(UUID())"))
        defaults.set(true, forKey: XiaoyaModelChoice.legacyUseLocalKey)
        defaults.set("qwen3-4b-4bit", forKey: XiaoyaModelChoice.legacyModelKey)
        XiaoyaModelChoice.migrateLegacy(defaults)
        XCTAssertEqual(defaults.string(forKey: XiaoyaModelChoice.key), "local-mlx/qwen3-4b-4bit")
        XCTAssertNil(defaults.object(forKey: XiaoyaModelChoice.legacyUseLocalKey))

        let off = try XCTUnwrap(UserDefaults(suiteName: "xy-migrate-\(UUID())"))
        off.set(false, forKey: XiaoyaModelChoice.legacyUseLocalKey)
        off.set("chat/model", forKey: "selectedChatModel")
        XiaoyaModelChoice.migrateLegacy(off)
        XCTAssertEqual(XiaoyaModelChoice.modelId(off), "chat/model")
    }
}
