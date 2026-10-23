import Foundation

/// 发语音条：system prompt 注入段（教 AI ```voice 块格式 + 表演脚本写法）。
/// 条件：主动开关开 + 楼层有语音服务（要 key 的有 key）+ 楼层选了声音（`VoiceMessageWriter.voiceSetup`）。
/// 文案按服务 `capabilities.supportsTags` 二选一（固定段逐字稳定，prompt 缓存安全）；
/// 楼层有「嗓子补充说明」就追加在 `</语音条>` 前。人称走 {{user}}/{{char}} 宏——注入链上 fileLibrary 槽过 applyMacros。
enum VoicePromptInjector {

    /// nil = 不注入
    static func hint(profile: Profile) -> String? {
        guard VoiceMessageWriter.proactiveEnabledProvider(),
              let setup = VoiceMessageWriter.voiceSetup(for: profile) else { return nil }
        let base = setup.synthesizer.capabilities.supportsTags ? tagsHintText : plainHintText
        let composed = compose(base, extraNote: profile.voiceExtraNote)
        guard let effectHint = profile.voiceEffects?.promptHint, composed.hasSuffix(closeTag) else { return composed }
        return String(composed.dropLast(closeTag.count)) + effectHint + closeTag
    }

    /// CC 只发送 user 内容：语音写法在 cc-rp CLAUDE.md 里，这里只在通话中末尾加一行 `<通话中/>` 提示 CC 直接回可朗读的短句。
    /// 不看楼层有没有配声音——没配也是在通话（用系统音）。
    static func bridgeContent(_ text: String, inCall: Bool) -> String {
        inCall ? text + "\n\n<通话中/>" : text
    }

    /// cc-rp CLAUDE.md 里 `<!-- mp-voice:begin/end -->` 之间的块（docs/plan-cc-terminal-mirror.md 二-b）：当前楼层语音设置。
    /// 纯函数；名字只换 {{user}}/{{char}}（不走 MacroExpander，免得 {{date}} 让内容每次都变、去重失效）。
    static func ccInstructionsBlock(profile: Profile) -> String {
        var lines = ["当前楼层语音设置（记忆花园自动同步，别手改）："]
        if let setup = VoiceMessageWriter.voiceSetup(for: profile) {
            let caps = setup.synthesizer.capabilities
            lines.append("- 语音条模型：" + (setup.model ?? "服务默认"))
            lines.append("- 通话模型：" + (caps.resolvedModel(profile.callModel) ?? "服务默认"))
            lines.append(caps.supportsTags
                ? "- 声音支持方括号表演标签：英文自然语言描述声音状态、可组合，只写耳朵听得见的；不支持 SSML。"
                : "- 声音不支持表演标签：voice 块和通话都写纯口语，别写方括号标签、动作说明或 markdown，会被原样念出来。")
            if !VoiceMessageWriter.proactiveEnabledProvider() {
                lines.append("- 主动语音条已关闭，除非{{user}}要求别发。")
            }
            let note = (profile.voiceExtraNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { lines.append("- 嗓子补充说明：\n" + note) }
            if let hint = setup.effects.promptHint { lines.append(hint.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let hint = setup.effects.callHint { lines.append("- 通话：" + hint) }
        } else {
            lines.append("当前楼层没配声音，不要输出 voice 块。")
        }
        let user = profile.userName.isEmpty ? "你" : profile.userName
        let char = profile.assistantName.isEmpty ? "助手" : profile.assistantName
        return EffectiveCharacterContext.expandNames(lines.joined(separator: "\n"), charName: char, userName: user)
    }

    /// 固定段 + 可选补充段（补充段在外壳里、`</语音条>` 前）
    static func compose(_ base: String, extraNote: String?) -> String {
        let note = (extraNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty, base.hasSuffix(closeTag) else { return base }
        return String(base.dropLast(closeTag.count)) + "<嗓子补充说明>\n\(note)\n</嗓子补充说明>\n" + closeTag
    }

    static let closeTag = "</语音条>"

    /// 认表演标签的服务（ElevenLabs v4 写法：方括号自然语言标签、可组合；v3 也吃）
    static let tagsHintText = """
    <语音条>
    你可以给 {{user}} 发语音条。想让 ta 听见你的语气时（情绪浓、认真、悄悄话的时刻），在回复中输出：
    ```voice
    （表演脚本）
    ```
    系统会把它变成一条你声音的语音消息。每次回复最多一条，别每条都发——偶尔出现才珍贵。
    表演脚本是给声音演员的台本，不必和正文一字一样：
    - 方括号标签用英文自然语言描述声音状态，不限词表：[whispering] [softly] [breathless] [voice trembling] [holding back tears]；可以组合：[whispering, fearful]
    - 标签只写耳朵听得见的（气息、音量、语速、哭腔、笑意），画面动作类（[smiling] [standing]）无效
    - 标签少而准：一条通常 1–3 个，同一状态的几句共用一个，声音状态真变了才换；过渡靠省略号和语气词，别连排堆标签（标签太多每句都换腔，听着像拼接）
    - 省略号是呼吸切口，碎句比完整句更像活人（"等一下……我刚刚……嗯……"）
    - 拟声词要不规则：嗯……ha……啧……（"啧"自带口腔小动作，很贴耳）
    - 全长 60–120 字
    - 数字符号写成口语（"三十九块九"，不是"￥39.9"）
    - 不支持 SSML（<break> 这类标记没用），停顿用省略号和标点
    </语音条>
    """

    /// 不认标签的服务（OpenAI 兼容、MiniMax、系统音…）：只教口语写法
    static let plainHintText = """
    <语音条>
    你可以给 {{user}} 发语音条。想让 ta 听见你的语气时（情绪浓、认真、悄悄话的时刻），在回复中输出：
    ```voice
    （要念的话）
    ```
    系统会把它变成一条你声音的语音消息。每次回复最多一条，别每条都发——偶尔出现才珍贵。
    语音脚本是念出来的台词，不必和正文一字一样：
    - 写口语，用短句；碎句比完整句更像活人（"等一下……我刚刚……嗯……"）
    - 省略号就是停顿和换气的地方
    - 别写方括号标签、括号里的动作说明或 markdown，它们会被原样念出来
    - 全长 60–120 字
    - 数字符号写成口语（"三十九块九"，不是"￥39.9"）
    </语音条>
    """
}
