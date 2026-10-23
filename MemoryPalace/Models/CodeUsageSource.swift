#if os(macOS)
import Foundation

/// 用量页「Code」筛选的数据源：Code 会话索引（`CodingSessionIndex`）里的会话级 token。
/// 口径限制：索引只存每个会话的**总 token**（拆不出输入 / 输出 / 缓存），按会话最后活动时刻记一条
/// → `tokensOnly`：只看 token，不计价，也不算进「未计价」。要逐次计价得等 adapter 解析出逐条 usage。
enum CodeUsageSource {
    static func records(indexURL: URL = CodingSessionIndex.defaultURL, since: Date?) -> [UsageRecord] {
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let index = try? CodingSessionIndex(url: indexURL, readOnly: true),
              let rows = try? index.tokenUsageRows(sinceMs: since.map { Int64($0.timeIntervalSince1970 * 1000) })
        else { return [] }
        return rows.map { row in
            UsageRecord(
                time: Date(timeIntervalSince1970: Double(row.updatedAtMs) / 1000),
                providerId: row.agentId,
                providerName: CodingAgent(rawValue: row.agentId)?.displayName ?? row.agentId,
                providerType: "code", model: row.model ?? "(未知模型)",
                input: Int(row.tokens), output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0, durationMs: 0,
                status: .ok, kind: .code, conversationId: nil, profileId: nil,
                subscription: false, tokensOnly: true
            )
        }
    }
}
#endif
