import Foundation

// MARK: - Context Summary Model

/// 注入 + 历史窗口锚定看到的样子。第三刀起由窗口摘要（memory/sessions/）拼出来：summary = 注入文本，coveredCount = 压缩锚点
struct ContextSummary: Codable {
    let summary: String
    let coveredCount: Int      // 摘要覆盖的旧消息条数
    let updatedAt: Date
}

// MARK: - Context Summarizer

/// 窗口内滚动摘要的入口（第三刀：分段追加，不重写；写手和存储见 SessionCloseout / SessionSegmentWriter / SessionSummaryStore）。
/// 改造前的累计摘要（memory/summaries/）只读，对话下次压缩时当第 0 段接上。
struct ContextSummarizer {

    // MARK: - 存取

    /// 没有新文件就退回改造前的累计摘要（当第 0 段），注入和锚定跟以前一样
    static func load(conversationId: String, profileId: String) -> ContextSummary? {
        let s = SessionSummaryStore.loadOrSeed(conversationId: conversationId, profileId: profileId, title: "")
        guard let text = SessionSummaryStore.injectionText(s, fullCount: SessionCloseout.fullSegmentCount) else { return nil }
        return ContextSummary(summary: text, coveredCount: s.compressedCount, updatedAt: s.updatedAt)
    }

    static func clear(conversationId: String, profileId: String) {
        SummaryFileStore.clear(conversationId: conversationId, profileId: profileId)
        SessionSummaryStore.clear(conversationId: conversationId, profileId: profileId)
    }

    // MARK: - 判断是否需要压缩

    /// 压缩频率（轮，一问一答=2条消息）。粟粟：不用每轮压，5-10 轮一次，可调。
    static var compressIntervalRounds: Int {
        let v = UserDefaults.standard.integer(forKey: "ctx_compress_interval")
        return v > 0 ? v : 5
    }

    /// 返回窗外的旧消息（需要压缩时）。force=手动压缩（无视滞后间隔）。
    static func messagesToSummarize<M>(
        allMessages: [M],
        contextDepth: Int,
        conversationId: String,
        profileId: String,
        force: Bool = false
    ) -> (oldMessages: [M], existingSummary: ContextSummary?)? {
        let totalCount = allMessages.count
        guard totalCount > contextDepth else { return nil }

        let oldCount = totalCount - contextDepth
        let existing = load(conversationId: conversationId, profileId: profileId)

        // 已压到这里 → 不需要
        if let existing, existing.coveredCount == oldCount {
            return nil
        }
        // 滞后压缩：窗外新增不足 N 轮就先不压（摘要稳定 → 可留在缓存前缀；也省小模型钱）
        if !force, let existing, oldCount - existing.coveredCount < compressIntervalRounds * 2 {
            return nil
        }
        return (oldMessages: Array(allMessages.prefix(oldCount)), existingSummary: existing)
    }

    // MARK: - 执行

    /// 判断 → 写一段压缩段追加上去（已被收尾段总结过的部分只推锚点不重写）
    static func summarize(
        messages: [SessionSegmentWriter.Message],
        contextDepth: Int,
        conversationId: String,
        conversationTitle: String,
        ctx: SessionCloseout.Context,
        providerManager: ProviderManager,
        force: Bool = false
    ) async throws {
        guard let needed = messagesToSummarize(
            allMessages: messages, contextDepth: contextDepth,
            conversationId: conversationId, profileId: ctx.profileId, force: force
        ) else { return }

        CacheDiagLog.shared.log("📝 窗口摘要: 压缩（窗外 \(needed.oldMessages.count) 条，已压 \(needed.existingSummary?.coveredCount ?? 0)）")
        do {
            if let to = try await SessionCloseout.shared.compress(
                messages: messages, oldCount: needed.oldMessages.count, conversationId: conversationId,
                title: conversationTitle, ctx: ctx,
                caller: SessionSegmentWriter.modelCaller(model: ctx.model, providerManager: providerManager,
                                                         conversationId: conversationId, profileId: ctx.profileId)) {
                CacheDiagLog.shared.log("📝 窗口摘要: ✅ 压到第 \(to) 条")
            }
        } catch {
            CacheDiagLog.shared.log("📝 窗口摘要: ❌ 失败 — \(error.localizedDescription)")
            throw error
        }
    }
}
