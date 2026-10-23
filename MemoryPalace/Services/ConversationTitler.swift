import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 对话标题 + 列表预览共用的文本清洗。
enum ConversationTitler {
    static let placeholderTitle = "新对话"

    private static let cardLabels = ["todo": "[待办]", "dice": "[骰子]", "timer": "[计时器]", "word": "[生词]", "timeline": "[时间线]"]

    /// 消息正文 → 一行纯文本：剥 thinking、卡片围栏换短标签、其余围栏只留代码、去 markdown 符号、压空白。
    static func plainText(_ raw: String) -> String {
        var text = ContentCleaner.extractThinking(from: raw).content
        text = replacingFences(in: text)
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "[图片]", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`~]+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 首条用户消息 → 立即可用的标题：清洗后按显示宽度截断（汉字算 2、其余算 1，预算 40 ≈ 20 个汉字）。
    static func sanitizedFallback(firstUser: String) -> String {
        let clean = plainText(firstUser)
        guard !clean.isEmpty else { return placeholderTitle }
        var width = 0
        var out = ""
        for ch in clean {
            let w = ch.unicodeScalars.contains { $0.value > 0x2E7F } ? 2 : 1
            if width + w > 40 { return out.trimmingCharacters(in: .whitespaces) + "…" }
            width += w
            out.append(ch)
        }
        return out
    }

    private static func replacingFences(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"```([^\n`]*)\n?([\s\S]*?)(```|$)"#) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let info = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let lang = info.split(separator: " ").first.map(String.init) ?? ""
            if lang.hasPrefix("card-") {
                result += " " + (cardLabels[String(lang.dropFirst(5))] ?? "[卡片]") + " "
            } else {
                result += " " + ns.substring(with: match.range(at: 2)) + " "
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}

extension ConversationTitler {
    private static let instructions = "你给一段对话起标题。只输出标题本身：中文，不超过 12 个字，不加引号、标点和解释。"
    @MainActor private static var inFlight: Set<String> = []

    /// 先写清洗后的首句（立刻不再是「新对话」），再异步用模型升级。
    /// 升级顺序：端上 Apple 模型 → 便宜 API 模型（排除 CC / codex 桥）→ 都没有就停在清洗首句。
    /// 写回守卫：标题仍是第一步写的那个才覆盖——期间手动改了名不动。
    /// `force`：长按「重新生成标题」，跳过「只给新对话起」的守卫，也不先写清洗首句。
    @MainActor
    static func autoTitle(_ conversation: Conversation, firstUser: String, firstAssistant: String,
                          providerManager: ProviderManager?, force: Bool = false) {
        guard force || conversation.title == placeholderTitle else { return }
        let convId = conversation.id
        guard !inFlight.contains(convId) else { return }
        if !force { conversation.title = sanitizedFallback(firstUser: firstUser.isEmpty ? firstAssistant : firstUser) }
        let expected = conversation.title
        let prompt = "用户：\(plainText(firstUser).prefix(500))\n助手：\(plainText(firstAssistant).prefix(500))"
        let model = providerManager.flatMap(titleModel)
        let profileId = conversation.profileId
        inFlight.insert(convId)
        Task { @MainActor in
            defer { inFlight.remove(convId) }
            guard let raw = await generate(prompt: prompt, instructions: instructions, kind: .title, model: model,
                                           providerManager: providerManager, conversationId: convId, profileId: profileId) else { return }
            let title = cleanModelTitle(raw)
            guard !title.isEmpty, conversation.title == expected else { return }
            conversation.title = title
            try? conversation.modelContext?.save()
        }
    }

    /// 长按「重新生成标题」：取这条对话最早的一问一答喂模型（各 fetchLimit 1，不全量取节点）
    @MainActor
    static func regenerate(_ conversation: Conversation, context: ModelContext, providerManager: ProviderManager?) {
        func first(_ role: String) -> String {
            let cid = conversation.id, pid = conversation.profileId
            var desc = FetchDescriptor<MessageNode>(
                predicate: #Predicate<MessageNode> { $0.conversationId == cid && $0.profileId == pid && $0.role == role },
                sortBy: [SortDescriptor(\MessageNode.createTime)]
            )
            desc.fetchLimit = 1
            return (try? context.fetch(desc).first?.content) ?? ""
        }
        let user = first("user"), assistant = first("assistant")
        guard !user.isEmpty || !assistant.isEmpty else { return }
        autoTitle(conversation, firstUser: user, firstAssistant: assistant, providerManager: providerManager, force: true)
    }

    /// 模型输出 → 标题：只留第一行，去「标题：」前缀、引号书名号、首尾标点
    static func cleanModelTitle(_ raw: String) -> String {
        var t = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        t = t.replacingOccurrences(of: #"^\s*(标题|Title)\s*[:：]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’「」『』《》*#。.！!？?，,"))
        return String(t.prefix(30))
    }

    /// 便宜 API 模型：只在普通 API 卡里挑（CC / codex 桥、ChatGPT 订阅都不碰），
    /// 先认用户选过的记忆提取模型，再按预设的便宜模型表；都没有返回 nil（不拿贵模型起标题）
    static func titleModel(_ providerManager: ProviderManager) -> ProviderModel? {
        let usable = providerManager.enabledProviders.filter { $0.type == .openaiCompatible || $0.type == .anthropic }
        let userChoice = UserDefaults.standard.string(forKey: "memoryExtractModelId") ?? ""
        if !userChoice.isEmpty, let m = usable.flatMap(\.models).first(where: { $0.id == userChoice }) { return m }
        for cred in usable {
            guard let preset = cred.presetId, let cheapId = ConversationViewModel.cheapModelIdByProvider[preset],
                  let m = cred.models.first(where: { $0.modelId == cheapId }) else { continue }
            return m
        }
        return nil
    }

    /// 小模型链（起标题 / 思考总结共用）：端上 Apple 模型 → 便宜 API 模型（`model` 为 nil = 不走 API）
    @MainActor
    static func generate(prompt: String, instructions: String, kind: UsageKind, model: ProviderModel?,
                         providerManager: ProviderManager?, conversationId: String, profileId: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let session = LanguageModelSession(instructions: instructions)
            if let r = try? await session.respond(to: prompt) { return r.content }
        }
        #endif
        guard let model, let providerManager else { return nil }
        let router = ProviderRouter(usageContext: UsageContext(kind: kind, conversationId: conversationId, profileId: profileId))
        guard let (text, usage) = try? await router.sendNonStreaming(
            model: model, messages: [(role: "user", content: prompt)],
            systemPrompt: instructions, providerManager: providerManager
        ) else { return nil }
        if let usage, let provider = providerManager.provider(for: model) {
            providerManager.commitSpend(providerId: provider.id,
                                        amount: BudgetCalculator.actualCost(provider: provider, modelId: model.modelId, usage: usage), usage: usage)
        }
        return text
    }
}
