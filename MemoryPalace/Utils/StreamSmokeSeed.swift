#if DEBUG
import Foundation
import SwiftData

/// [STREAM smoke] L2-T2 冒烟：mock SSE provider（宿主 127.0.0.1:9876，脚本
/// scratchpad/stream-smoke-server.py）+ 测试楼层里一条选中 mock 模型的空对话。
/// 真实执行路径冒烟（发消息 → ProviderRouter → 流式 → ArticleStreamingBody），
/// 不动粟粟的楼层/不碰生产 hub。触发：`--stream-smoke` / env MP_STREAM_SMOKE=1。
enum StreamSmokeSeed {
    static let convId = "stream-smoke-conv-1"
    static let credId = "stream-smoke-mock"
    static let modelId = "mock-model"

    static var isActive: Bool {
        CommandLine.arguments.contains("--stream-smoke") || ChatSampleSeed.isActive
            || ProcessInfo.processInfo.environment["MP_STREAM_SMOKE"] == "1"
    }

    @MainActor
    static func injectIfNeeded(pm: ProfileManager, providers: ProviderManager) {
        guard isActive else { return }
        if ChatSampleSeed.isActive {
            ChatSampleSeed.inject(pm: pm, providers: providers)
            return
        }
        // mock 卡（同 id 重进=刷新配置）；key 只为过「未配 key」闸，server 不校验
        providers.addCredential(APICredential(
            id: credId, name: "StreamSmoke", emoji: "🧪",
            type: .openaiCompatible,
            baseURL: "http://127.0.0.1:9876/v1",
            models: [ProviderModel(credentialId: credId, modelId: modelId, name: "Mock")]
        ))
        providers.setApiKey("smoke", for: credId)

        // 测试楼层（与 PerfBenchSeed 同一层，guardNormalLaunch 防呆共用）
        #if os(iOS)
        let pid = PerfBenchSeed.profileId
        #else
        // L4：mac 放宽时 PerfBenchSeed 本体仍 iOS-only（它依赖同为 iOS-gated 的 PROBE），字面量同值
        let pid = "perf-bench-profile"
        #endif
        if let bench = pm.profiles.first(where: { $0.id == pid }) {
            pm.switchTo(bench)
        } else {
            pm.addProfile(Profile(
                id: pid, name: "[PERF] 基准楼层", emoji: "📊",
                description: "深翻基准测试专用，整层可删", userName: "你", assistantName: "助手",
                systemPrompt: "", preferredModel: "", createdAt: Date()
            ))
        }

        // smoke 对话每次清重建（选中 mock 模型；provider="api" 隔离铁律）
        let ctx = ModelContext(pm.container)
        let cid = convId
        ((try? ctx.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid }))) ?? [])
            .forEach { ctx.delete($0) }
        ((try? ctx.fetch(FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == cid }))) ?? [])
            .forEach { ctx.delete($0) }
        let conv = Conversation(
            id: convId, title: "[SMOKE] 流式冒烟",
            createTime: Date(), updateTime: Date(),
            currentNodeId: "", provider: "api", profileId: pid
        )
        conv.selectedModelId = "\(credId)/\(modelId)"
        ctx.insert(conv)
        do {
            try ctx.save()
            KBProbe.log("[SMOKE] seeded conv, model=\(credId)/\(modelId)")
        } catch {
            KBProbe.log("[SMOKE] seed FAILED: \(error)")
        }
    }
}
#endif
