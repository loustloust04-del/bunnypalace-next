import XCTest
import MemoryCore
@testable import memoryd

/// 电脑试写台：memoryd 接上模型后真跑 C2（用例 × 配方 × 模型）。这里的模型是假的传输层，全虚构。
final class MemorydModelBenchTests: XCTestCase {
    private var floor: URL!

    override func setUpWithError() throws {
        floor = try MemorydFixture.copiedFloor()
    }

    override func tearDown() {
        MemorydFixture.remove(floor)
    }

    private static let fakeKey = "sk-fake-not-a-real-key-0000"

    /// 记下每次送出去的请求体，回一张合格的卡
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [[String: Any]] = []
        private var headers: [[String: String]] = []

        func record(_ request: URLRequest) {
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            lock.withLock {
                bodies.append(body)
                headers.append(request.allHTTPHeaderFields ?? [:])
            }
        }

        var systems: [String] { lock.withLock { bodies.compactMap { $0["system"] as? String } } }
        var models: [String] { lock.withLock { bodies.compactMap { $0["model"] as? String } } }
        var keys: [String] { lock.withLock { headers.compactMap { $0["x-api-key"] } } }
        var count: Int { lock.withLock { bodies.count } }
    }

    private static let card = #"{"fragments":[{"msg":1,"content":"岚舟制作模型船时只用水性颜料。","tags":["模型船"],"importance":3,"emotion":0,"resolved":null,"category":"preference","subject":"岚舟","speaker":"用户自述"}]}"#

    private func model(_ recorder: Recorder, status: Int = 200, body: String? = nil) -> MemorydModel {
        let reply = body ?? #"{"content":[{"type":"text","text":\#(Self.quoted(Self.card))}],"usage":{"input_tokens":120,"output_tokens":40}}"#
        return MemorydModel(base: URL(string: "https://example.invalid")!, modelId: "fake-haiku", key: Self.fakeKey) { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(reply.utf8), response)
        }
    }

    private static func quoted(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [text]).dropFirst().dropLast(), as: UTF8.self)
    }

    private func service(model: MemorydModel?) throws -> MemorydService {
        let service = try MemorydService(
            config: .init(floor: floor, profileId: "memoryd-test", allowUnmounted: true, model: model),
            webRoot: MemorydResources.webRoot)
        service.bind(port: MemorydTestPort.value)
        return service
    }

    private func c2Set(_ service: MemorydService) async throws -> MemoryBenchSet {
        let response = await service.get("/api/bench/sets/c2-probe")
        return try MemoryBench.decoder.decode(MemoryBenchSet.self, from: response.body)
    }

    func testWithoutModelC2StaysUnmeasurable() async throws {
        let service = try service(model: nil)
        let sets = (await service.get("/api/bench/sets").jsonDictionary?["sets"] as? [[String: Any]]) ?? []
        let c2 = try XCTUnwrap(sets.first { $0["id"] as? String == "c2-probe" })
        XCTAssertEqual(c2["runnable"] as? Bool, false)
        XCTAssertEqual(c2["needsModel"] as? Bool, true)
        let run = try await service.runBench(try await c2Set(service))
        XCTAssertTrue(run.cells.isEmpty)
        XCTAssertTrue(run.note?.contains("没接模型") == true, run.note ?? "")
    }

    func testC2RunsCurrentRecipeWithProductionPromptAndParsesCards() async throws {
        let recorder = Recorder()
        let service = try service(model: model(recorder))
        let set = try await c2Set(service)
        let run = try await service.runBench(set)

        XCTAssertEqual(run.status, .done)
        XCTAssertEqual(run.cells.count, set.cases.count)
        XCTAssertEqual(recorder.count, set.cases.count)
        XCTAssertEqual(Set(recorder.models), ["fake-haiku"])
        XCTAssertEqual(Set(recorder.keys), [Self.fakeKey])
        // 「现行」= 正式 C2 的默认模板换完占位符，不另抄一份
        let first = try XCTUnwrap(set.cases.first)
        let input = try MemoryBenchC2Writer.input(first)
        let messages = try MemoryBenchC2Writer.messages(input, caseId: first.id)
        let expected = FragmentPool.systemPrompt(names: MemoryBenchC2Writer.names(input),
                                                 defaults: MemoryReadEnvironment.defaults,
                                                 day: try MemoryBenchC2Writer.day(input, messages: messages))
        XCTAssertTrue(recorder.systems.contains(expected))
        for cell in run.cells {
            XCTAssertNil(cell.error)
            XCTAssertEqual(cell.items.count, 1)
            XCTAssertEqual(cell.items.first?.fields["subject"], "岚舟")
            XCTAssertEqual(cell.usage, MemoryBenchUsage(input: 120, output: 40))
            XCTAssertNil(cell.usd)
            XCTAssertEqual(cell.costSource, .unpriced)
        }
        let status = await service.get("/api/status").jsonDictionary
        XCTAssertEqual(status?["model"] as? String, "fake-haiku")
    }

    func testTrialRecipeFromRequestRunsBesideCurrent() async throws {
        let recorder = Recorder()
        let service = try service(model: model(recorder))
        let set = try await c2Set(service)
        let body = #"{"setId":"c2-probe","recipes":[{"name":"试一版","system":"只记{{称呼}}的事实，这是试的一版。"}]}"#
        let response = await service.post("/api/bench/run", json: body)
        XCTAssertEqual(response.status, 200)
        let runId = try XCTUnwrap(response.jsonDictionary?["runId"] as? String)
        let detail = await service.get("/api/bench/runs/\(runId)")
        let run = try MemoryBench.decoder.decode(MemoryBenchRun.self, from: detail.body)

        XCTAssertEqual(run.recipes.map(\.id), [MemoryBenchC2Writer.currentRecipeId, "trial-1"])
        XCTAssertEqual(run.recipes.last?.name, "试一版")
        XCTAssertEqual(run.recipes.last?.parent, MemoryBenchC2Writer.currentRecipeId)
        XCTAssertEqual(run.cells.count, set.cases.count * 2)
        XCTAssertEqual(recorder.systems.filter { $0.hasSuffix("这是试的一版。") }.count, set.cases.count)
        XCTAssertFalse(recorder.systems.contains { $0.contains("{{称呼}}") })
    }

    func testRecipeWithoutSystemIs400() async throws {
        let service = try service(model: model(Recorder()))
        let response = await service.post("/api/bench/run", json: #"{"setId":"c2-probe","recipes":[{"name":"空"}]}"#)
        XCTAssertEqual(response.status, 400)
    }

    func testHTTPErrorIsRecordedPerCellWithKeyRedacted() async throws {
        let recorder = Recorder()
        let echo = #"{"error":{"message":"bad key \#(Self.fakeKey)"}}"#
        let service = try service(model: model(recorder, status: 401, body: echo))
        let run = try await service.runBench(try await c2Set(service))
        XCTAssertFalse(run.cells.isEmpty)
        for cell in run.cells {
            let error = try XCTUnwrap(cell.error)
            XCTAssertTrue(error.contains("401"), error)
            XCTAssertFalse(error.contains(Self.fakeKey), error)
        }
        let stored = try String(contentsOf: floor.appendingPathComponent("bench-runs"), encoding: .utf8, recursive: true)
        XCTAssertFalse(stored.contains(Self.fakeKey))
    }

    func testModelNeedsBothFlagAndEnvironmentKey() {
        XCTAssertNil(MemorydModel.fromEnvironment(modelId: nil, environment: [MemorydModel.keyVariable: "k"]))
        XCTAssertNil(MemorydModel.fromEnvironment(modelId: "m", environment: [:]))
        XCTAssertNil(MemorydModel.fromEnvironment(modelId: "m", environment: [MemorydModel.keyVariable: "  "]))
        let official = MemorydModel.fromEnvironment(modelId: "m", environment: [MemorydModel.keyVariable: "k"])
        XCTAssertEqual(official?.endpoint.absoluteString, "https://api.anthropic.com/v1/messages")
        let relay = MemorydModel.fromEnvironment(modelId: "m", environment: [MemorydModel.keyVariable: "k",
                                                                            MemorydModel.urlVariable: "https://example.invalid/v1"])
        XCTAssertEqual(relay?.endpoint.absoluteString, "https://example.invalid/v1/messages")
    }

    func testOpenAIWireBuildsChatCompletionsRequestAndReadsReply() async throws {
        let reply = #"{"choices":[{"message":{"content":"好的"},"finish_reason":"stop"}],"usage":{"prompt_tokens":11,"completion_tokens":3}}"#
        var model = MemorydModel(base: URL(string: "https://example.invalid/v1")!, modelId: "fake-flash", key: Self.fakeKey, wire: .openai) { request in
            (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        model.maxTokens = 1234
        XCTAssertEqual(model.endpoint.absoluteString, "https://example.invalid/v1/chat/completions")
        let request = try model.request(system: "系统", user: "用户")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Bearer " + Self.fakeKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 1234)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] ?? "" }, ["system", "user"])
        let result = try await model.complete(system: "系统", user: "用户")
        XCTAssertEqual(result.text, "好的")
        XCTAssertEqual(result.usage, MemoryBenchUsage(input: 11, output: 3))
    }

    func testEmptyReplyReportsStopReason() async {
        let reply = #"{"content":[],"stop_reason":"refusal","usage":{"input_tokens":5,"output_tokens":0}}"#
        let model = MemorydModel(base: URL(string: "https://example.invalid")!, modelId: "m", key: Self.fakeKey) { request in
            (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await model.complete(system: "", user: "x")
            XCTFail("没正文应该抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refusal"), error.localizedDescription)
        }
    }

    func testJudgeModelUsesItsOwnVariablesAndOpenAINeedsURL() {
        let env = ["MEMORYD_JUDGE_KEY": "j", "MEMORYD_MODEL_KEY": "m", "MEMORYD_MODEL_WIRE": "openai"]
        XCTAssertEqual(MemorydModel.fromEnvironment(modelId: "judge", variables: .judge, environment: env)?.key, "j")
        XCTAssertNil(MemorydModel.fromEnvironment(modelId: "flash", environment: env), "OpenAI 兼容接口没给地址不算接上")
        var withURL = env
        withURL["MEMORYD_MODEL_URL"] = "https://example.invalid/v1"
        XCTAssertEqual(MemorydModel.fromEnvironment(modelId: "flash", environment: withURL)?.wire, .openai)
    }

    func testModelOptionParses() throws {
        let options = try MemorydOptions.parse(["memoryd", "--floor", floor.path, "--model", "fake-haiku"])
        XCTAssertEqual(options.model, "fake-haiku")
        XCTAssertEqual(try MemorydOptions.parse(["memoryd", "--floor", floor.path, "--judge-model", "fake-opus"]).judgeModel, "fake-opus")
        XCTAssertThrowsError(try MemorydOptions.parse(["memoryd", "--floor", floor.path, "--model"]))
    }
}

private extension String {
    /// 目录下所有文件拼起来（只给「key 没落盘」这条断言用）
    init(contentsOf directory: URL, encoding: String.Encoding, recursive: Bool) throws {
        var all = ""
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if let text = try? String(contentsOf: url, encoding: encoding) { all += text }
        }
        self = all
    }
}
