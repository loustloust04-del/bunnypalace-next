import XCTest
@testable import 记忆花园

/// 11-07 live（铲屎二期刀 4，Warden 要的真端点证据）：后台副调用 `router.sideCall` 撞到输出上限时带回截断标志。
/// 副调用的 Anthropic 上限是 min(8192, 目录上限)，没有压低的口子，所以让模型写一段远超 8192 token 的虚构内容。
/// 刀 4 返修：长的那条两种卡各跑一次——默认（后台任务用流式）和关掉流式，截断标志都要对。
/// 默认跳过：MP_SIDECALL_LIVE=1 才跑。key 只在内存里经 SeedLabAuthProtocol 换进请求头（占位符给 ProviderManager），
/// 不进钥匙串 / 文件 / 日志；日志只打标志、字数和输出 token。
@MainActor
final class SideCallLiveTests: XCTestCase {
    private struct Relay: Decodable { var name: String; var url: String; var key: String }

    func testLiveHaikuSideCallFlagsTruncation() async throws {
        guard ProcessInfo.processInfo.environment["MP_SIDECALL_LIVE"] == "1" else {
            throw XCTSkip("未设置 MP_SIDECALL_LIVE=1，不访问网络")
        }
        let relay = try Self.officialRelay()
        SeedLabAuthProtocol.key = relay.key
        SeedLabAuthProtocol.host = URL(string: relay.url)?.host
        try SeedLabAuthProtocol.install()
        defer { SeedLabAuthProtocol.uninstall(); SeedLabAuthProtocol.key = nil; SeedLabAuthProtocol.host = nil }

        let h = try await PromptRealPathHarness.make(.init(name: "sidecall-live", memoryEnabled: false, voiceHint: false,
                                                           memoryFixtures: false))
        let modelName = "claude-haiku-5-5"
        for streaming in [nil, false] as [Bool?] {
            let id = "xctest-sidecall-live-\(UUID().uuidString)"
            let model = ProviderModel(credentialId: id, modelId: modelName, name: modelName)
            h.providerManager.addCredential(APICredential(id: id, name: "SideCall Live", emoji: "", type: .anthropic, baseURL: relay.url,
                                                          extraHeaders: ["anthropic-version": "2023-06-01"], models: [model],
                                                          toolsSupported: false, sideCallStreaming: streaming))
            defer { h.providerManager.removeCredential(id: id) }
            h.providerManager.setApiKey(SeedLabAuthProtocol.placeholder, for: id)
            XCTAssertEqual(h.providerManager.sideModel(ids: [model.id])?.id, model.id, "有 key 的 Anthropic 卡应当被挑中")
            let mode = streaming == false ? "nonstream" : "stream"

            let router = ProviderRouter(usageContext: UsageContext(kind: .topic))
            let short = try await router.sideCall(model: model, messages: [(role: "user", content: "只回答两个字：你好")],
                                                  systemPrompt: nil, providerManager: h.providerManager)
            print("[SIDECALL-LIVE] short(\(mode)): hit=\(short.hitOutputLimit) chars=\(short.text.count) out=\(short.usage?.outputTokens ?? -1)")
            XCTAssertFalse(short.hitOutputLimit, "短回答不该标截断（\(mode)）")

            let long = try await router.sideCall(
                model: model,
                messages: [(role: "user", content: "写一部虚构的长篇游记，主角叫星砚，至少三万字，按章节一直写下去，中途不要总结、不要停、不要问我要不要继续。")],
                systemPrompt: "你是小说作者。只输出正文。",
                providerManager: h.providerManager)
            print("[SIDECALL-LIVE] long(\(mode)): hit=\(long.hitOutputLimit) chars=\(long.text.count) out=\(long.usage?.outputTokens ?? -1)")
            XCTAssertTrue(long.hitOutputLimit, "超过输出上限应当带回截断标志（\(mode)）")
        }
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
