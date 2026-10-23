import Foundation

enum APIUsageParser {
    static func isOpenRouter(_ baseURL: String) -> Bool {
        let url = URL(string: baseURL)
        return url?.scheme?.lowercased() == "https" && url?.host?.lowercased() == "openrouter.ai"
    }

    static func openAI(_ obj: [String: Any], baseURL: String, cacheWriteIs1h: Bool = false) -> TokenUsage? {
        let u = obj["usage"] as? [String: Any]
        let rid = isOpenRouter(baseURL) ? obj["id"] as? String : nil
        guard let u else { return rid.map { TokenUsage(inputTokens: 0, outputTokens: 0, responseId: $0, completeness: .missing) } }
        let reported = isOpenRouter(baseURL) ? (u["cost"] as? NSNumber)?.doubleValue : nil
        guard let input = u["prompt_tokens"] as? Int, let output = u["completion_tokens"] as? Int else {
            guard rid != nil || reported != nil else { return nil }
            return TokenUsage(inputTokens: u["prompt_tokens"] as? Int ?? 0, outputTokens: u["completion_tokens"] as? Int ?? 0,
                              reportedCostUSD: reported, responseId: rid,
                              completeness: u["prompt_tokens"] is Int || u["completion_tokens"] is Int ? .snapshot : .missing)
        }
        let prompt = u["prompt_tokens_details"] as? [String: Any]
        let completion = u["completion_tokens_details"] as? [String: Any]
        var billedOutput = output
        var reasoning = completion?["reasoning_tokens"] as? Int
        if URL(string: baseURL)?.host?.lowercased() == "generativelanguage.googleapis.com" {
            // OAI 兼容口 completion_tokens 是否已含 thoughts 待实测；无明确分桶时保持原值，避免双计。
            if let native = obj["usageMetadata"] as? [String: Any],
               let candidates = native["candidatesTokenCount"] as? Int,
               let thoughts = native["thoughtsTokenCount"] as? Int {
                billedOutput = candidates + thoughts
                reasoning = thoughts
            }
        }
        // DeepSeek 官方 hit 字段优先；两字段同时返回是否一致待真实响应实测。
        let cached = u["prompt_cache_hit_tokens"] as? Int ?? prompt?["cached_tokens"] as? Int
        let write = prompt?["cache_write_tokens"] as? Int
        return TokenUsage(inputTokens: input, outputTokens: billedOutput,
                          cacheReadTokens: cached,
                          cacheWriteTokens: write, reasoningTokens: reasoning,
                          reportedCostUSD: reported,
                          cacheWrite1hTokens: cacheWriteIs1h ? write : nil, responseId: rid)
    }
    static func anthropic(_ u: [String: Any]) -> TokenUsage? {
        guard let input = u["input_tokens"] as? Int, let output = u["output_tokens"] as? Int else { return nil }
        let buckets = u["cache_creation"] as? [String: Any]
        let five = buckets?["ephemeral_5m_input_tokens"] as? Int
        let hour = buckets?["ephemeral_1h_input_tokens"] as? Int
        let write = u["cache_creation_input_tokens"] as? Int ?? (five != nil || hour != nil ? (five ?? 0) + (hour ?? 0) : nil)
        return TokenUsage(inputTokens: input, outputTokens: output,
                          cacheReadTokens: u["cache_read_input_tokens"] as? Int, cacheWriteTokens: write,
                          cacheWrite1hTokens: hour,
                          webSearches: (u["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int)
    }

}
