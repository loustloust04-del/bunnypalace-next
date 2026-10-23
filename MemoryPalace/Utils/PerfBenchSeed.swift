#if DEBUG && os(iOS)
import Foundation
import SwiftData

/// [PERF bench seed] L1（roadmap-lody-adoptions）：3000 条混合消息对话，
/// 给 ChatPerfBench 深翻连滚基准当靶子。内容按真实渲染成本配比：
/// 每 10 条 1 条带代码块、2 条长段、其余短句（MarkdownUI 全走真实渲染路径）。
/// provider="api"（hub 测试隔离铁律，同 KeyboardProbeSeed）。
///
/// 触发：`xcrun simctl launch <udid> <bundle> -- --perf-bench`
enum PerfBenchSeed {
    static let markerKey = "perfBenchSeedDone_v4"
    static let convId = "perf-bench-conv-1"
    static let profileId = "perf-bench-profile"
    static let total = 3000

    static var isActive: Bool {
        // 真机 devicectl 传不进 -- 开头的 launch 参数（error 10002），走官方 env 通道：
        // DEVICECTL_CHILD_MP_PERF_BENCH=1 xcrun devicectl device process launch …
        CommandLine.arguments.contains("--perf-bench")
            || ProcessInfo.processInfo.environment["MP_PERF_BENCH"] == "1"
    }

    /// 粟粟 09-08：「新开一个测试楼层往里写入，不准动我的已有楼层」——seed 进专属楼层，
    /// 正常启动（无 --perf-bench）若落在测试楼层自动切走（guardNormalLaunch）。
    static func injectIfNeeded(pm: ProfileManager) {
        guard isActive else { return }
        let profileId = Self.profileId
        // 确保测试楼层存在并切入（addProfile 内部 switchTo）
        if let bench = pm.profiles.first(where: { $0.id == profileId }) {
            pm.switchTo(bench)
        } else {
            pm.addProfile(Profile(
                id: profileId, name: "[PERF] 基准楼层", emoji: "📊",
                description: "深翻基准测试专用，整层可删", userName: "你", assistantName: "助手",
                systemPrompt: "", preferredModel: "", createdAt: Date()
            ))
        }
        let ctx = ModelContext(pm.container)
        cleanupStray(ctx)
        if UserDefaults.standard.bool(forKey: markerKey) {
            PROBE("[PERF bench seed] already done, skip")
            return
        }
        let now = Date()
        let codeBlock = "看看这段实现：\n```swift\nfunc advance(_ current: Double, toward target: Double, elapsed: Double) -> Double {\n    let step = max(1, (target - current) * (1 - exp(-elapsed / 0.1)))\n    return min(target, current + step)\n}\n```\n指数逼近的关键在 response 常数。"
        let longPara = "这一条是长段落填充：为了让基准的渲染成本贴近真实使用，这里放一段有一定长度的中文正文，大约两百字。它会在气泡里换行成七八行，MarkdownUI 需要完整解析并排版这些文本。滚动经过它时的测量与布局成本，正是我们想量的东西。基准的目的不是好看的数字，而是暴露 LazyVStack 深翻时行高估算与真实渲染的差距，以及内存随可见行集合移动的增长曲线，为 L2 流式轻渲染的优先级提供依据。"
        for i in 0..<total {
            let kind = i % 10
            let body: String
            // v4：每条前缀唯一序号——固定模板会让 L2-T3 渲染缓存命中率虚高（真实对话文本不重复）
            if kind == 0 { body = "第 \(i) 条。" + codeBlock }
            else if kind <= 2 { body = "第 \(i) 条。" + longPara }
            else { body = "基准填充消息 \(i)：短句正文，一到两行的常规气泡。" }
            let node = MessageNode(
                id: "perf-bench-msg-\(i)",
                role: i % 2 == 0 ? "user" : "assistant",
                content: body,
                contentType: "text",
                createTime: now.addingTimeInterval(Double(i - total) * 30),
                parentId: i == 0 ? nil : "perf-bench-msg-\(i - 1)",
                childrenIds: i == total - 1 ? [] : ["perf-bench-msg-\(i + 1)"],
                conversationId: convId,
                profileId: profileId
            )
            ctx.insert(node)
        }
        let conv = Conversation(
            id: convId,
            title: "[PERF] 深翻基准对话",
            createTime: now,
            updateTime: now,
            currentNodeId: "perf-bench-msg-\(total - 1)",
            provider: "api",
            profileId: profileId
        )
        ctx.insert(conv)
        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: markerKey)
            let cid = convId
            let verify = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == cid })
            let count = (try? ctx.fetchCount(verify)) ?? -1
            PROBE("[PERF bench seed] injected conv=\(convId), store count=\(count)/\(total)")
            KBProbe.log("[PERFBENCH] seed count=\(count)/\(total)")
        } catch {
            PROBE("[PERF bench seed] FAILED: \(error)")
            KBProbe.log("[PERFBENCH] seed FAILED: \(error)")
        }
    }

    /// v2 时代 seed 误写进当前楼层的测试对话——搬进测试楼层前先清走（只删本工具自己的 id）
    private static func cleanupStray(_ ctx: ModelContext) {
        let cid = convId, pid = profileId
        let strayConvs = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid && $0.profileId != pid })
        let strayNodes = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.conversationId == cid && $0.profileId != pid })
        let convs = (try? ctx.fetch(strayConvs)) ?? []
        let nodes = (try? ctx.fetch(strayNodes)) ?? []
        guard !convs.isEmpty || !nodes.isEmpty else { return }
        convs.forEach { ctx.delete($0) }
        nodes.forEach { ctx.delete($0) }
        try? ctx.save()
        PROBE("[PERF bench seed] cleaned stray: \(convs.count) conv + \(nodes.count) nodes from non-bench profiles")
    }

    /// 正常启动防呆：上次 bench 后 lastProfileId 停在测试楼层，别让粟粟开 app 落进去
    /// （StreamSmokeSeed 与本工具共用测试楼层，冒烟启动也不能切走）
    static func guardNormalLaunch(pm: ProfileManager) {
        guard !isActive, !StreamSmokeSeed.isActive, !PerfHarness.anyRole,
              pm.currentProfile.id == profileId,
              let normal = pm.profiles.first(where: { $0.id != profileId }) else { return }
        pm.switchTo(normal)
        PROBE("[PERF bench seed] normal launch was on bench profile → switched back to \(normal.name)")
    }
}
#endif
