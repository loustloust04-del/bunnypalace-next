import Foundation
import SwiftData

// MARK: - 用户画像（M5 做梦聚合）

struct UserProfileDream: Codable {
    let text: String
    let sourceCount: Int     // 参与聚合的记忆条数
    let updatedAt: Date
}

/// 画像文件存取：floors/{slug}/memory/profile.md（frontmatter 模式同 SummaryFileStore）。
/// 人可读、AI 经 fs_read 可照镜子（memory/ 只读挂载）；下次做梦覆盖。
enum ProfileFileStore {
    private static func fileURL(profileId: String) -> URL {
        let root = FileLibraryStore.memoryRoot(profileId: profileId)
        MainThreadIO.note(.mkdir, "ProfileFileStore.fileURL")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("profile.md")
    }

    static func load(profileId: String) -> UserProfileDream? {
        MainThreadIO.note(.read, "ProfileFileStore.load")
        guard let raw = try? String(contentsOf: fileURL(profileId: profileId), encoding: .utf8),
              let (meta, body) = FrontmatterCodec.parse(raw) else { return nil }
        return UserProfileDream(
            text: body,
            sourceCount: meta["sourceCount"].flatMap { Int($0) } ?? 0,
            updatedAt: meta["updatedAt"].flatMap { FrontmatterCodec.dateFormatter.date(from: $0) } ?? .distantPast
        )
    }

    static func save(_ dream: UserProfileDream, profileId: String) {
        let content = FrontmatterCodec.render(meta: [
            ("sourceCount", String(dream.sourceCount)),
            ("updatedAt", FrontmatterCodec.dateFormatter.string(from: dream.updatedAt)),
        ], body: dream.text)
        do {
            try Data(content.utf8).write(to: fileURL(profileId: profileId), options: .atomic)
        } catch {
            CacheDiagLog.shared.log("🌙 画像: ❌ 写盘失败 — \(error.localizedDescription)")
        }
    }
}

/// 做梦聚合：定期把零散原子事实凝成一段连贯画像，进常驻层。
enum DreamConsolidator {

    static var enabled: Bool {
        MemoryFlags.masterEnabled && UserDefaults.standard.bool(forKey: "mem_content_profile")
    }

    /// 自动做梦判定：开关开 + 有记忆 +（无画像 或 距上次 >24h 且记忆有新增）
    static func shouldDream(profileId: String, newestMemoryUpdate: Date?, memoryCount: Int) -> Bool {
        guard enabled, memoryCount > 0 else { return false }
        guard let existing = ProfileFileStore.load(profileId: profileId) else { return true }
        guard Date().timeIntervalSince(existing.updatedAt) > 86400 else { return false }
        return (newestMemoryUpdate ?? .distantPast) > existing.updatedAt
    }

    private static var personLine: String {
        MemoryFlags.firstPersonExtraction
            ? "- 第一人称视角（以「我」——陪伴者的视角写对方），允许有温度"
            : "- 第三人称（「用户…」）"
    }

    /// 用户自定义 prompt（设置-记忆面板"编辑画像"sheet 里可调）。
    /// 非空时优先使用；空时回落 dreamPrompt 默认模板。粟粟批：让用户自己调画像生成方式。
    static var customDreamPrompt: String {
        UserDefaults.standard.string(forKey: "customDreamPrompt") ?? ""
    }

    static var dreamPromptResolved: String {
        let custom = customDreamPrompt
        let base = custom.isEmpty ? dreamPrompt : custom
        return base.replacingOccurrences(of: "- 第三人称（\"用户…\"）", with: personLine)
    }

    /// 默认模板（暴露 public 让 UI 显示给用户作为起手提示）
    static let dreamPrompt = """
    你是记忆整理者。把下面这些零散的用户记忆事实，凝成一份连贯的用户画像——不是清单复读，而是回答"这个人是谁"。

    【按优先级写，没有内容的维度省略】：
    1. 身份与基本信息（姓名/年龄/地点/职业/当前阶段）
    2. 当前在做的事（项目、工作、近期目标）
    3. 偏好与品味（审美、习惯、喜好）
    4. 重要的人（家人、朋友、宠物——只写存在和身份，不写关系细节）

    【绝不写】：
    - 角色扮演 / 虚构剧本里的"事实"（看起来像幻想或剧情设定的）
    - 性偏好、亲密细节、暗黑想象、深处心理状态
    - 用户跟 AI 之间的称呼、宠溺互动、私密玩笑
    - 任何"看起来不是这个人对外的公开身份"的内容
    - 模棱两可的：宁可不写也不要瞎猜

    【写法纪律】：
    - 第三人称（"用户…"）
    - 覆盖式更新：继承旧画像中仍有效的认识；与新事实矛盾的直接改写；绝不保留两个冲突版本
    - 只基于给出的事实，不脑补、不拔高、不写评价
    - 控制在 1500 字以内。直接输出，不加标题、不加代码块
    """

    /// 做一次梦。facts 传纯值（@Model 不跨线程）。成功返回新画像，失败抛错/返回 nil（调用方报信）。
    static func dream(
        profileId: String,
        facts: [(content: String, category: String)],
        model: ProviderModel,
        providerManager: ProviderManager
    ) async throws -> UserProfileDream? {
        guard !facts.isEmpty else { return nil }
        CacheDiagLog.shared.log("🌙 画像: 做梦开始（\(facts.count) 条记忆）")

        let existing = ProfileFileStore.load(profileId: profileId)
        var user = ""
        if let existing {
            user += "已有画像：\n---\n\(existing.text)\n---\n\n"
        }
        user += "记忆事实：\n" + facts.map { "- \($0.content) [\($0.category)]" }.joined(separator: "\n")
        user += "\n\n请输出\(existing != nil ? "覆盖更新后的" : "")完整用户画像。"

        // 预算闸（同 ContextSummarizer）
        if let provider = providerManager.provider(for: model) {
            let inputTok = HeuristicEstimator().estimate(dreamPromptResolved + user)
            let estimated = BudgetCalculator.actualCost(
                provider: provider, modelId: model.modelId,
                usage: TokenUsage(inputTokens: inputTok, outputTokens: 2048)
            )
            if case .blocked = providerManager.budgetGate(providerId: provider.id, estimatedCost: estimated),
               !BudgetPreflight.mayDeferEarlyGate(provider: provider, estimated: estimated) {
                CacheDiagLog.shared.log("🌙 画像: 跳过（预算闸）")
                return nil
            }
        }

        let router = ProviderRouter(usageContext: UsageContext(kind: .dream, profileId: profileId))
        let response: String
        let usage: TokenUsage?
        do {
            (response, usage) = try await router.sendNonStreaming(
                model: model, messages: [(role: "user", content: user)],
                systemPrompt: dreamPromptResolved, providerManager: providerManager
            )
        } catch {
            CacheDiagLog.shared.log("🌙 画像: ❌ 失败 — \(error.localizedDescription)")
            throw error
        }

        if let usage, let provider = providerManager.provider(for: model) {
            let cost = BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage)
            await MainActor.run { providerManager.commitSpend(providerId: provider.id, amount: cost, usage: usage) }
        }

        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            CacheDiagLog.shared.log("🌙 画像: ⚠️ 模型返回空内容")
            return nil
        }
        let dreamResult = UserProfileDream(text: text, sourceCount: facts.count, updatedAt: Date())
        ProfileFileStore.save(dreamResult, profileId: profileId)
        CacheDiagLog.shared.log("🌙 画像: ✅ \(facts.count) 条记忆 → \(text.count) 字")
        return dreamResult
    }

    /// 设置页手动做梦用的模型解析：副模型优先，没有就用当前聊天模型
    static func resolveModel(providerManager: ProviderManager) -> ProviderModel? {
        let extractId = UserDefaults.standard.string(forKey: "memoryExtractModelId") ?? ""
        if !extractId.isEmpty, let m = providerManager.model(byId: extractId) { return m }
        let chatId = UserDefaults.standard.string(forKey: "selectedChatModel") ?? ""
        if !chatId.isEmpty, let m = providerManager.model(byId: chatId) { return m }
        return nil
    }

    // MARK: - MV1+MV5 公共毕业 helper

    /// 从 hot+warm 候选里筛"将被消费"的 id（钉住免疫——MV1 决策2：钉住进画像但不毕业）。
    /// 值类型 [UUID] 快照，跨线程安全。
    static func consumedIdsFromCandidates(_ memories: [Memory]) -> [UUID] {
        memories.filter { !$0.isUserExplicit }.map(\.id)
    }

    /// 把消费碎片标毕业（钉住免疫已在 consumedIds 阶段保证）。
    /// `mem_supersede_soft` 关时跳过，与 SC-B2 守卫一致。返回毕业数。
    @discardableResult
    static func graduateConsumedMemories(
        consumedIds: [UUID],
        store: MemoryStore,
        context: ModelContext
    ) -> Int {
        guard MemoryFlags.dreamGraduationEnabled else { return 0 }
        var graduated = 0
        for id in consumedIds {
            do { try store.supersede(id: id, context: context); graduated += 1 }
            catch { CacheDiagLog.shared.log("🌙 画像: 毕业失败 id=\(id) — \(error.localizedDescription)") }
        }
        if graduated > 0 {
            CacheDiagLog.shared.log("🌙 画像: 毕业 \(graduated) 条消费碎片（钉住免疫）")
        }
        return graduated
    }
}
