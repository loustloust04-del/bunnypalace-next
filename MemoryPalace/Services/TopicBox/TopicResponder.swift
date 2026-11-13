#if PERSONAL_APPS
#if DEBUG
import Foundation

/// 「听听 TA 怎么想」——问题卡上现场生成一段 AI 回应（不进主对话）。
/// VocabSentenceGrader 同款骨架：预算闸 + sendNonStreaming + commitSpend；
/// 任何失败返回 nil → UI toast 降级（App 自包含，AI 是增强）。
/// 模型 = 楼层当前聊天模型（粟粟拍的，不单独选槽）。
enum TopicResponder {

    static func buildRequest(card: TopicCard, userName: String, assistantName: String)
        -> (systemPrompt: String, messages: [(role: String, content: String)]) {
        let system = """
        你是\(assistantName)，在和\(userName)共用的「话题盒」里给一个问题写回应。\
        真诚、具体、可以有立场，不要套话，200 字上下。\
        已有回应仅供参考，不要复述，也不要逐条评价。直接输出回应正文，不要标题不要前缀。
        """
        var user = "问题：\(card.title)"
        let detail = card.body
            .replacingOccurrences(of: card.title, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            user += "\n\(detail)"
        }
        if !card.responses.isEmpty {
            user += "\n\n已有回应："
            for r in card.responses {
                user += "\n\n[\(r.author) · \(r.date)]\n\(r.text)"
            }
        }
        return (systemPrompt: system, messages: [(role: "user", content: user)])
    }

    /// 楼层当前聊天模型；没配、或者发不出非流式请求（没 key / 桥卡 / 本机卡）返回 nil。
    @MainActor
    static func resolveChatModel(providerManager: ProviderManager) -> ProviderModel? {
        providerManager.sideModel(ids: [UserDefaults.standard.string(forKey: "selectedChatModel") ?? ""])
    }

    @MainActor
    static func respond(card: TopicCard, providerManager: ProviderManager,
                        userName: String, assistantName: String) async -> String? {
        guard let model = resolveChatModel(providerManager: providerManager) else { return nil }

        let request = buildRequest(card: card, userName: userName, assistantName: assistantName)
        let router = ProviderRouter(usageContext: UsageContext(kind: .topic))
        guard let r = try? await router.sideCall(
            model: model, messages: request.messages,
            systemPrompt: request.systemPrompt, providerManager: providerManager
        ), !r.hitOutputLimit else { return nil }

        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
#endif
#endif
