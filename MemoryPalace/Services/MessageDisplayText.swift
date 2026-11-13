import Foundation
import MemoryCore

/// 消息「显示副本」唯一口径：拆报错尾巴 → 清洗 → 展开 {{char}}/{{user}} → 剥思考 → 显示正则（整条跑）。
/// 只产出显示用文本，不改存储原文；「原文取哪段」（语音取打的字、分段取文字段）由调用方决定。
enum MessageDisplayText {
    struct Result: Equatable {
        let body: String
        let thinking: String?
    }

    /// 定稿消息。cacheKey 给 ContentCleaner 缓存用（内部拼上长度），nil = 不指定 key；
    /// splitsSystemTail = false：报错 / 提示尾巴留在正文里（页 2 网页皮肤没地方单独画它）
    static func make(_ raw: String, role: String, scripts: [RegexScript],
                     userName: String, charName: String, cacheKey: String? = nil,
                     splitsSystemTail: Bool = true, legacyErrorMarker: Bool) -> Result {
        let isUser = role == "user"
        let source = isUser || !splitsSystemTail ? raw : ChatSystemMessage.split(raw, legacy: legacyErrorMarker).body
        let cleaned = EffectiveCharacterContext(charName: charName, userName: userName)
            .expand(ContentCleaner.clean(source, cacheKey: cacheKey.map { "\($0)_\(source.count)" }))
        let extracted = isUser ? nil : ContentCleaner.extractThinking(from: cleaned)
        let body = RegexPipeline.run(scripts, text: extracted?.content ?? cleaned, phase: .display,
                                     placement: RegexPipeline.placement(forRole: role),
                                     userName: userName, charName: charName)
        return Result(body: body, thinking: extracted?.thinking)
    }

    /// 流式中的 AI 回复：清洗不走缓存，不拆报错尾巴、不展开名字（卡开场不走流式）
    static func streaming(_ raw: String, scripts: [RegexScript], userName: String, charName: String) -> Result {
        let extracted = ContentCleaner.extractThinking(from: ContentCleaner.clean(raw, cached: false))
        let body = RegexPipeline.run(scripts, text: extracted.content, phase: .display,
                                     placement: RegexPipeline.assistantPlacement,
                                     userName: userName, charName: charName)
        return Result(body: body, thinking: extracted.thinking)
    }
}
