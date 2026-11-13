import XCTest
import SwiftData
@testable import 记忆花园

/// 11-07 live：真打 API，把输出上限压到 5 token，确认「到输出上限」判成 ReplyOutcome.length 并落进节点两列。
/// 默认跳过：MP_OUTCOME_LIVE=1 才跑。key 只在内存里经 SeedLabAuthProtocol 换进请求头（占位符给 ProviderManager），
/// 不进钥匙串 / 文件 / 日志；日志只打结局和正文前 20 字。
@MainActor
final class ReplyOutcomeLiveTests: XCTestCase {
    private struct Relay: Decodable { var name: String; var url: String; var key: String }

    /// 5 个 token 不够数完 1–100，上游必然 finish_reason=length / stop_reason=max_tokens
    private static let capTokens = 5
    private static let longPrompt = "从 1 数到 100，用中文数字，一个一个写出来"

    func testLiveHaikuLengthTruncation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MP_OUTCOME_LIVE"] == "1" else { throw XCTSkip("未设置 MP_OUTCOME_LIVE=1，不访问网络") }
        let relay = try Self.officialRelay()
        SeedLabAuthProtocol.key = relay.key
        SeedLabAuthProtocol.host = URL(string: relay.url)?.host
        try SeedLabAuthProtocol.install()
        defer { SeedLabAuthProtocol.uninstall(); SeedLabAuthProtocol.key = nil; SeedLabAuthProtocol.host = nil }

        let h = try await makeHarness("outcome-live-anthropic")
        let modelName = "claude-haiku-5-5"
        let id = "xctest-outcome-live-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
        h.providerManager.addCredential(APICredential(id: id, name: "Outcome Live", emoji: "", type: .anthropic, baseURL: relay.url,
                                                      extraHeaders: ["anthropic-version": "2023-06-01"], models: [model],
                                                      toolsSupported: false))
        defer { h.providerManager.removeCredential(id: id) }
        h.providerManager.setApiKey(SeedLabAuthProtocol.placeholder, for: id)
        h.viewModel.selectedConversation?.selectedModelId = model.id

        // haiku 5.5 默认会想（adaptive）且「默认」档要留 4096 余量：那一档会把实发 max_tokens 抬到 5 + 4096，
        // 压不到 5。把「不收思考参数」学进 ParamAdaptStore（生产里有这条学习路径，设置页能清），实发才是 5。
        let base = h.providerManager.provider(for: model)?.baseURL ?? relay.url
        let adaptKey = ParamAdaptStore.key(providerType: .anthropic, baseURL: base, modelId: modelName)
        ParamAdaptStore.shared.learn(providerType: .anthropic, baseURL: base, modelId: modelName,
                                     adding: ParamCompat.Learned(groups: [ParamCompat.Group.reasoning]),
                                     rawError: "xctest: 把实发输出上限钉在 5 token")
        defer { ParamAdaptStore.shared.remove(key: adaptKey) }

        let node = try await send(h, model: model)
        print("[OUTCOME-LIVE] anthropic/\(modelName): outcome=\(node.replyOutcome ?? "nil") finish=\(node.finishReason ?? "nil") content前20字=\(String(node.content.prefix(20)))")
        try assertTruncated(node, vm: h.viewModel, expectedFinish: "max_tokens")
    }

    func testLiveDeepSeekLengthTruncation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MP_OUTCOME_LIVE"] == "1" else { throw XCTSkip("未设置 MP_OUTCOME_LIVE=1，不访问网络") }
        let key = try Self.deepSeekKey()
        SeedLabAuthProtocol.key = key
        SeedLabAuthProtocol.host = "api.deepseek.com"
        try SeedLabAuthProtocol.install()
        defer { SeedLabAuthProtocol.uninstall(); SeedLabAuthProtocol.key = nil; SeedLabAuthProtocol.host = nil }

        let h = try await makeHarness("outcome-live-deepseek")
        let modelName = "deepseek-flash"
        let id = "xctest-outcome-live-\(UUID().uuidString)"
        let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
        // DeepSeek 预设的地址（Models/APIProviderTable.swift:231）
        h.providerManager.addCredential(APICredential(id: id, name: "Outcome Live", emoji: "", type: .openaiCompatible,
                                                      baseURL: "https://api.deepseek.com/v1", models: [model],
                                                      toolsSupported: false))
        defer { h.providerManager.removeCredential(id: id) }
        h.providerManager.setApiKey(SeedLabAuthProtocol.placeholder, for: id)
        h.viewModel.selectedConversation?.selectedModelId = model.id

        let node = try await send(h, model: model)
        print("[OUTCOME-LIVE] deepseek/\(modelName): outcome=\(node.replyOutcome ?? "nil") finish=\(node.finishReason ?? "nil") content前20字=\(String(node.content.prefix(20)))")
        try assertTruncated(node, vm: h.viewModel, expectedFinish: "length")
    }

    // MARK: - 夹具

    private func makeHarness(_ name: String) async throws -> PromptRealPathHarness {
        let h = try await PromptRealPathHarness.make(.init(name: name, memoryEnabled: false, voiceHint: false,
                                                           memoryFixtures: false))
        h.overrideDefault("imageTranscriptionEnabled", false)
        h.overrideDefault(PermissionDomain.fileLibrary.storageKey, PermissionLevel.notAllowed.rawValue)
        // 夹具第一条带的是 7 字节假 jpeg，真 API 会 400：历史里不发图
        h.overrideDefault(PermissionDomain.images.storageKey, PermissionLevel.notAllowed.rawValue)
        return h
    }

    /// 预设副本把可见上限改成 5 token（生产机制：OutputTokenCap 按 preset.sampling 解析，手动档直接用 maxTokens）
    private func send(_ h: PromptRealPathHarness, model: ProviderModel) async throws -> MessageNode {
        var preset = h.preset
        preset.sampling.maxTokens = Self.capTokens
        preset.sampling.maxTokensAuto = false
        XCTAssertTrue(h.viewModel.sendMessage(Self.longPrompt, model: model, profile: h.profile, preset: preset,
                                             providerManager: h.providerManager, context: h.context))
        try await waitIdle(h.viewModel)
        let node = try XCTUnwrap(h.viewModel.currentPath.last)
        XCTAssertEqual(node.role, "assistant")
        return node
    }

    private func assertTruncated(_ node: MessageNode, vm: ConversationViewModel, expectedFinish: String) throws {
        XCTAssertEqual(node.replyOutcome, ReplyOutcome.truncatedLength.rawValue)
        XCTAssertEqual(node.finishReason, expectedFinish)
        XCTAssertFalse(node.content.contains("截断"), "提示文字不能进正文：\(node.content)")
        XCTAssertFalse(node.content.contains("⚠️"), "这一轮不能报错：\(node.content)")
        XCTAssertEqual(vm.providerRouter.lastReplyOutcome, .truncatedLength)
        XCTAssertEqual(vm.providerRouter.lastFinishReason, expectedFinish)
    }

    private func waitIdle(_ vm: ConversationViewModel) async throws {
        let deadline = Date().addingTimeInterval(90)
        try await Task.sleep(for: .milliseconds(100))
        while vm.assistantTurnInFlight, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(vm.assistantTurnInFlight, "90 秒没回完")
    }

    private static func officialRelay() throws -> Relay {
        guard let user = getpwuid(getuid()) else { throw URLError(.fileDoesNotExist) }
        let home = URL(fileURLWithPath: String(cString: user.pointee.pw_dir), isDirectory: true)
        let rows = try JSONDecoder().decode([Relay].self, from: Data(contentsOf: home.appendingPathComponent(".mp-test-keys/relays.json")))
        guard let relay = rows.first(where: { $0.name == "anthropic-official" }), !relay.key.isEmpty,
              let endpoint = URL(string: relay.url), endpoint.scheme == "https", endpoint.host == "api.anthropic.com" else {
            throw XCTSkip("缺少 anthropic-official 官方凭据（不使用其他 key）")
        }
        return relay
    }

    /// `~/.mp-test-keys/deepseek.env`：一行 `export DEEPSEEK_API_KEY=…`，值可能带引号。只把值给了内存。
    private static func deepSeekKey() throws -> String {
        guard let user = getpwuid(getuid()) else { throw URLError(.fileDoesNotExist) }
        let home = URL(fileURLWithPath: String(cString: user.pointee.pw_dir), isDirectory: true)
        let file = home.appendingPathComponent(".mp-test-keys/deepseek.env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("缺少 ~/.mp-test-keys/deepseek.env")
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("export ") else { continue }
            let rest = line.dropFirst("export ".count)
            guard let eq = rest.firstIndex(of: "="),
                  rest[..<eq].trimmingCharacters(in: .whitespaces) == "DEEPSEEK_API_KEY" else { continue }
            var value = rest[rest.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { break }
            return value
        }
        throw XCTSkip("deepseek.env 里没有 DEEPSEEK_API_KEY")
    }
}
