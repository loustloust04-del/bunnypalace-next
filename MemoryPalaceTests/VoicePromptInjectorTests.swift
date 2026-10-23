import XCTest
@testable import 记忆花园

/// 发语音条注入段：条件矩阵 + 按服务出两种文案 + 固定段逐字锚 + 可选「嗓子补充说明」段（plan-voice-providers V3）。
final class VoicePromptInjectorTests: XCTestCase {

    private var kind: VoiceServiceKind = .elevenLabs
    private var key: String? = "k"

    override func setUp() {
        super.setUp()
        kind = .elevenLabs
        key = "k"
        VoiceMessageWriter.serviceProvider = { [unowned self] id in
            id == "svc" ? VoiceService(id: id, name: "服务", kind: self.kind) : nil
        }
        VoiceMessageWriter.serviceKeyProvider = { [unowned self] _ in self.key }
        // 用真工厂：capabilities 按厂商给（不发网络）
        VoiceMessageWriter.synthesizerProvider = { $0.makeSynthesizer() }
    }

    override func tearDown() {
        VoiceMessageWriter.serviceProvider = { VoiceServiceStore.shared.service(id: $0) }
        VoiceMessageWriter.serviceKeyProvider = { VoiceServiceStore.shared.key(for: $0) }
        VoiceMessageWriter.synthesizerProvider = { $0.makeSynthesizer() }
        VoiceMessageWriter.proactiveEnabledProvider = { UserDefaults.standard.bool(forKey: VoiceTuning.proactiveKey) }
        super.tearDown()
    }

    private func profile(service: String? = "svc", voiceId: String? = "v", note: String? = nil) -> Profile {
        var p = Profile(id: "p", name: "楼", emoji: "🌿", description: "", userName: "你", assistantName: "助手")
        p.voiceServiceId = service
        p.voiceId = voiceId
        p.voiceExtraNote = note
        return p
    }

    func testInjectsOnlyWhenAllConditionsTrue() {
        // (enabled, hasKey, hasVoice, hasService) 矩阵：只有全真注入
        for enabled in [true, false] {
            for k in [Optional("k"), nil] {
                for voice in [Optional("v"), nil] {
                    for service in [Optional("svc"), nil] {
                        VoiceMessageWriter.proactiveEnabledProvider = { enabled }
                        key = k
                        let hint = VoicePromptInjector.hint(profile: profile(service: service, voiceId: voice))
                        let expect = enabled && k != nil && voice != nil && service != nil
                        XCTAssertEqual(hint != nil, expect,
                                       "enabled=\(enabled) key=\(String(describing: k)) voice=\(String(describing: voice)) service=\(String(describing: service))")
                    }
                }
            }
        }
    }

    func testSystemVoiceNeedsNoKey() {
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        kind = .system
        key = nil
        XCTAssertEqual(VoicePromptInjector.hint(profile: profile()), VoicePromptInjector.plainHintText)
    }

    func testTextFollowsSupportsTags() {
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        kind = .elevenLabs
        XCTAssertEqual(VoicePromptInjector.hint(profile: profile()), VoicePromptInjector.tagsHintText)
        for plain in [VoiceServiceKind.openAICompatible, .miniMax] {
            kind = plain
            XCTAssertEqual(VoicePromptInjector.hint(profile: profile()), VoicePromptInjector.plainHintText, "\(plain)")
        }
    }

    /// CC 桥：平时原文一字不加（语音写法在 cc-rp CLAUDE.md）；通话中末尾只加一行 `<通话中/>`
    func testBridgeOutsideCallPreservesExactPayload() {
        let raw = "发一条语音\n<style>自然口语</style>"
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        XCTAssertEqual(VoicePromptInjector.bridgeContent(raw, inCall: false), raw)
        VoiceMessageWriter.proactiveEnabledProvider = { false }
        XCTAssertEqual(VoicePromptInjector.bridgeContent(raw, inCall: false), raw)
    }

    func testBridgeInCallAppendsOnlyCallMarker() {
        let wire = VoicePromptInjector.bridgeContent("[voice] 你好", inCall: true)
        XCTAssertEqual(wire, "[voice] 你好\n\n<通话中/>")
        XCTAssertFalse(wire.contains("mp_voice_instructions"))
    }

    /// cc-rp CLAUDE.md 标记块（plan-cc-terminal-mirror 二-b）：没配声音只一句
    func testCCBlockWithoutVoiceSetup() {
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        let block = VoicePromptInjector.ccInstructionsBlock(profile: profile(voiceId: nil))
        XCTAssertEqual(block, "当前楼层语音设置（记忆花园自动同步，别手改）：\n当前楼层没配声音，不要输出 voice 块。")
        key = nil
        XCTAssertEqual(VoicePromptInjector.ccInstructionsBlock(profile: profile()), block, "要 key 的服务没 key = 没配")
    }

    func testCCBlockTagsServiceCarriesModelsNoteAndEffects() {
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        var p = profile(note: "{{char}}用轻声对{{user}}说，{{date}}照写。")
        p.assistantName = "角色"; p.userName = "禾禾"
        p.messageModel = ElevenLabsSynthesizer.v4
        p.callModel = ElevenLabsSynthesizer.v4Turbo
        var effects = VoiceEffectConfiguration(); effects.enabled = true; effects.callEnabled = true; effects.waterID = "water"
        p.voiceEffects = effects
        let block = VoicePromptInjector.ccInstructionsBlock(profile: p)
        XCTAssertTrue(block.hasPrefix("当前楼层语音设置（记忆花园自动同步，别手改）："))
        XCTAssertTrue(block.contains("- 语音条模型：" + ElevenLabsSynthesizer.v4 + "\n"))
        XCTAssertTrue(block.contains("- 通话模型：" + ElevenLabsSynthesizer.v4Turbo + "\n"))
        XCTAssertTrue(block.contains("支持方括号表演标签"))
        XCTAssertTrue(block.contains("- 嗓子补充说明：\n角色用轻声对禾禾说，{{date}}照写。"), "只换名字宏，{{date}} 不展开免得内容每次变")
        XCTAssertTrue(block.contains("[sfx:water]")); XCTAssertTrue(block.contains("- 通话：本通电话支持本机音效"))
        XCTAssertFalse(block.contains("主动语音条已关闭"))
        XCTAssertFalse(block.contains("mp-voice"), "块内容不能带标记串，hub 会拒")
        XCTAssertEqual(block, VoicePromptInjector.ccInstructionsBlock(profile: p), "纯函数：同输入同输出，去重才有效")
    }

    func testCCBlockPlainServiceAndProactiveOff() {
        VoiceMessageWriter.proactiveEnabledProvider = { false }
        kind = .system; key = nil
        var p = profile(); p.userName = "禾禾"
        let block = VoicePromptInjector.ccInstructionsBlock(profile: p)
        XCTAssertTrue(block.contains("声音不支持表演标签"))
        XCTAssertFalse(block.contains("支持方括号表演标签"))
        XCTAssertTrue(block.contains("- 主动语音条已关闭，除非禾禾要求别发。"))
        XCTAssertFalse(block.contains("嗓子补充说明")); XCTAssertFalse(block.contains("sfx"))
    }

    /// 固定段逐字锚：注入串是缓存前缀的一部分，改动必须有意识（改了同步更新此锚 + 金样 + review 记账）
    func testTagsHintVerbatimAnchor() {
        XCTAssertEqual(VoicePromptInjector.tagsHintText, """
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
        """)
    }

    func testPlainHintVerbatimAnchor() {
        XCTAssertEqual(VoicePromptInjector.plainHintText, """
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
        """)
    }

    func testHintTextsShape() {
        for text in [VoicePromptInjector.tagsHintText, VoicePromptInjector.plainHintText] {
            XCTAssertTrue(text.hasPrefix("<语音条>"))
            XCTAssertTrue(text.hasSuffix("</语音条>"))
            XCTAssertTrue(text.contains("```voice"))
            XCTAssertTrue(text.contains("{{user}}"), "人称走宏不硬编码")
            XCTAssertFalse(text.contains("小岚"), "禁止硬编码名字")
            XCTAssertFalse(text.contains("她"), "禁止硬编码人称代词")
        }
        XCTAssertTrue(VoicePromptInjector.tagsHintText.contains("[whispering, fearful]"))
        XCTAssertFalse(VoicePromptInjector.plainHintText.contains("[whispering"), "不认标签的服务不教标签")
    }

    /// 补充段：固定段逐字保留 + `</语音条>` 前插入；空白说明不追加
    func testExtraNoteAppendedInsideShell() {
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        let hint = VoicePromptInjector.hint(profile: profile(note: "  声音偏低，爱说「嗯哼」\n"))
        let fixed = String(VoicePromptInjector.tagsHintText.dropLast("</语音条>".count))
        XCTAssertEqual(hint, fixed + "<嗓子补充说明>\n声音偏低，爱说「嗯哼」\n</嗓子补充说明>\n</语音条>")

        kind = .miniMax
        let plain = VoicePromptInjector.hint(profile: profile(note: "语速慢一点"))!
        XCTAssertTrue(plain.hasPrefix(String(VoicePromptInjector.plainHintText.dropLast("</语音条>".count))))
        XCTAssertTrue(plain.hasSuffix("<嗓子补充说明>\n语速慢一点\n</嗓子补充说明>\n</语音条>"))

        XCTAssertEqual(VoicePromptInjector.hint(profile: profile(note: " \n ")), VoicePromptInjector.plainHintText)
    }

    func testEffectsHintOnlyAppearsWhenEnabledAndInsideVoiceShell() {
        VoiceMessageWriter.proactiveEnabledProvider = { true }
        var p = profile()
        var effects = VoiceEffectConfiguration(); effects.kissIDs = [UUID().uuidString]
        p.voiceEffects = effects
        XCTAssertEqual(VoicePromptInjector.hint(profile: p), VoicePromptInjector.tagsHintText)
        effects.enabled = true; p.voiceEffects = effects
        let hint = VoicePromptInjector.hint(profile: p)!
        XCTAssertTrue(hint.contains("[sfx:kiss]"))
        XCTAssertTrue(hint.hasSuffix("</本机音效>\n</语音条>"))
        XCTAssertNil(effects.callHint)
        effects.callEnabled = true
        XCTAssertNotNil(effects.callHint)
    }
}
