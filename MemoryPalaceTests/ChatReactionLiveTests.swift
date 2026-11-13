import XCTest
import SwiftData
@testable import 记忆花园

/// 10-29 贴表情 live：真 Haiku（只用 ~/.mp-test-keys/relays.json 里的 anthropic-official，key 只在内存里经
/// SeedLabAuthProtocol 换进请求头，不进钥匙串 / 文件 / 日志）。默认跳过：TEST_RUNNER_MP_REACTION_LIVE=1 才跑。
@MainActor
final class ChatReactionLiveTests: XCTestCase {
    private struct Relay: Decodable { var name: String; var url: String; var key: String }

    func testLiveHaikuReactionTurnAndAssistantReact() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MP_REACTION_LIVE"] == "1" else { throw XCTSkip("未设置 MP_REACTION_LIVE=1，不访问网络") }
        let relay = try Self.officialRelay()
        SeedLabAuthProtocol.key = relay.key
        SeedLabAuthProtocol.host = URL(string: relay.url)?.host
        try SeedLabAuthProtocol.install()
        defer { SeedLabAuthProtocol.uninstall(); SeedLabAuthProtocol.key = nil; SeedLabAuthProtocol.host = nil }

        let h = try await PromptRealPathHarness.make(.init(name: "reaction-live", memoryEnabled: false, voiceHint: false,
                                                          memoryFixtures: false, bubbleMode: true))
        h.overrideDefault("imageTranscriptionEnabled", false)
        h.overrideDefault(PermissionDomain.fileLibrary.storageKey, PermissionLevel.notAllowed.rawValue)
        // 夹具第一条带的是 7 字节假 jpeg，真 API 会 400：不发图
        h.overrideDefault(PermissionDomain.images.storageKey, PermissionLevel.notAllowed.rawValue)
        let suite = "ChatReactionLiveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let outbox = ChatCardEventOutbox(defaults: defaults)
        let store = ChatReactionStore(defaults: defaults)
        let vm = h.viewModel
        vm.cardEventOutbox = outbox
        vm.reactionStore = store
        let id = "xctest-reaction-live-\(UUID().uuidString)"
        let modelName = env["MP_REACTION_LIVE_MODEL"] ?? "claude-haiku-5-5"
        let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
        h.providerManager.addCredential(APICredential(id: id, name: "Reaction Live", emoji: "", type: .anthropic, baseURL: relay.url,
                                                      extraHeaders: ["anthropic-version": "2023-06-01"], models: [model],
                                                      toolsSupported: false))
        h.providerManager.setApiKey(SeedLabAuthProtocol.placeholder, for: id)
        defer { h.providerManager.removeCredential(id: id) }
        vm.selectedConversation?.selectedModelId = model.id

        let a2 = try XCTUnwrap(vm.currentPath.last)
        a2.content = "我给你做了你最爱的番茄炒蛋，放在桌上了。"
        try h.context.save()

        // ① 只贴表情不打字：立刻跑一轮
        store.toggle("❤️", on: ChatReactionTarget(node: a2), outbox: outbox, trigger: nil)
        XCTAssertEqual(vm.triggerReactionReply(model: model, profile: h.profile, preset: h.preset,
                                               providerManager: h.providerManager, context: h.context), .sent)
        try await waitIdle(vm)
        let afterReact = vm.currentPath.last
        let silent = afterReact?.id == a2.id
        let first = silent ? "（AI 选择不回，空泡已撤）" : (afterReact?.content ?? "")
        print("[REACTION-LIVE] ① 贴❤️ 后：\(first)")
        print("[REACTION-LIVE] ① AI 贴在她消息上：\(vm.currentPath.filter { $0.role == "user" }.flatMap { store.aiReactions(for: ChatReactionTarget(node: $0, blockIndex: 0, blockText: $0.content)) })")
        XCTAssertFalse(first.contains("```react"), "react 块不能留在正文")
        XCTAssertFalse(first.hasPrefix("⚠️") || first.contains("请求失败"), "这一轮不能报错：\(first)")

        // ② 让它主动给她这条贴表情
        XCTAssertTrue(vm.sendMessage("我今天面试通过啦！！你给我这条贴个表情庆祝一下吧", model: model, profile: h.profile, preset: h.preset,
                                     providerManager: h.providerManager, context: h.context))
        try await waitIdle(vm)
        let user = try XCTUnwrap(vm.currentPath.last { $0.role == "user" })
        let reply = vm.currentPath.last.map { $0.role == "assistant" ? $0.content : "（没有回复泡）" } ?? ""
        let placed = store.aiReactions(for: ChatReactionTarget(node: user, blockIndex: 0, blockText: user.content))
        print("[REACTION-LIVE] ② 回复：\(reply)")
        print("[REACTION-LIVE] ② AI 贴在「\(user.content.prefix(12))」上：\(placed)")
        print("[REACTION-LIVE] ② 箱里记的：\(outbox.events(for: user.conversationId).map(\.text))")
        XCTAssertFalse(reply.contains("```react"), "react 块不能留在正文")
        XCTAssertFalse(placed.isEmpty, "点名要表情时应该贴上")

        vm.cancelAssistantTurn(context: h.context)
        await h.tearDown()
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
}
