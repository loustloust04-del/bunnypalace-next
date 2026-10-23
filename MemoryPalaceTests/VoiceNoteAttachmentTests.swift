import XCTest
@testable import 记忆花园

/// 她发语音条（plan-voice-note M1 / M7）：.voice 附件 → modelInput / segments、userVoiceNote 判定、老 JSON 兼容、
/// 气泡剥标记行、声纹均值归一
final class VoiceNoteAttachmentTests: XCTestCase {

    private let path = "attachments/abcd1234-对话/voice-20261004-120000.m4a"

    // MARK: - modelInput

    func testModelInputVoiceLineFormats() {
        let short = PendingChatAttachment.voice(path: path, duration: 6.2, transcript: "今天好累")
        XCTAssertEqual(ChatAttachmentPromptBuilder.modelInput(text: "", attachments: [short]), "[语音 0:07] 今天好累")

        let long = PendingChatAttachment.voice(path: path, duration: 65, transcript: "说了好长一段")
        XCTAssertEqual(ChatAttachmentPromptBuilder.modelInput(text: "", attachments: [long]), "[语音 1:05] 说了好长一段")

        let empty = PendingChatAttachment.voice(path: path, duration: 7, transcript: "  ")
        XCTAssertEqual(ChatAttachmentPromptBuilder.modelInput(text: "", attachments: [empty]), "[语音 0:07]（没转出文字）")

        let none = PendingChatAttachment.voice(path: path, duration: 7, transcript: nil)
        XCTAssertEqual(ChatAttachmentPromptBuilder.modelInput(text: "", attachments: [none]), "[语音 0:07]（没转出文字）")
    }

    /// 文字 + 语音一起发：文字在前，语音一行在后，不包 [附件] 壳；转写里的换行压成一行
    func testModelInputTextPlusVoice() {
        let v = PendingChatAttachment.voice(path: path, duration: 3, transcript: "第一句\n第二句")
        let out = ChatAttachmentPromptBuilder.modelInput(text: "你看这个", attachments: [v])
        XCTAssertEqual(out, "你看这个\n\n[语音 0:03] 第一句 第二句")
        XCTAssertFalse(out.contains("[附件"))
    }

    // MARK: - segments / userMessage

    func testSegmentsVoiceOnly() {
        let v = PendingChatAttachment.voice(path: path, duration: 7, transcript: "好")
        let parts = ChatAttachmentPromptBuilder.userMessage(displayBase: "", attachments: [v])
        XCTAssertEqual(parts.modelText, "[语音 0:07] 好")
        XCTAssertEqual(parts.contentType, "segmented")
        XCTAssertEqual(parts.segments, [.audioRef(name: "voice-20261004-120000.m4a", mime: "audio/mp4", path: path, duration: 7, script: "好")])
        XCTAssertTrue(parts.segments?.userVoiceNote ?? false)
        XCTAssertFalse(parts.segments?.hasRenderableSegments ?? true, "纯语音不走 segmented 渲染")
    }

    func testSegmentsTextThenVoiceThenFile() {
        let v = PendingChatAttachment.voice(path: path, duration: 2, transcript: "")
        let f = PendingChatAttachment.text(name: "a.txt", typeDescription: "文本", extractedText: "x", byteCount: 1)
        let segs = ChatAttachmentPromptBuilder.segments(text: "嗨", attachments: [f, v])
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0], .text("嗨"))
        XCTAssertEqual(segs[1], .audioRef(name: "voice-20261004-120000.m4a", mime: "audio/mp4", path: path, duration: 2, script: nil),
                       "空转写 script 存 nil")
        guard case .attachment(let name, _, _) = segs[2] else { return XCTFail("文件在后：\(segs)") }
        XCTAssertEqual(name, "a.txt")
        XCTAssertFalse(segs.userVoiceNote, "有文字就不是纯语音")
    }

    func testUserVoiceNoteJudgement() {
        let audio = MessageSegment.audioRef(name: "v.m4a", mime: "audio/mp4", path: "p", duration: 1, script: "s")
        XCTAssertTrue([audio].userVoiceNote)
        XCTAssertTrue([audio, audio].userVoiceNote)
        XCTAssertFalse([MessageSegment]().userVoiceNote)
        XCTAssertFalse([.text("hi"), audio].userVoiceNote)
        XCTAssertFalse([.imageRef(name: "a", type: nil, path: "x"), audio].userVoiceNote)
        XCTAssertEqual([.text("hi"), audio].audioRefs.map(\.path), ["p"])
        XCTAssertEqual([.text("hi"), audio].audioRefs.first?.script, "s")
    }

    /// 编辑恢复不把语音拆回附件（菜单里本来就没编辑），也不算「找不到」
    func testRestoreSkipsVoice() {
        let v = PendingChatAttachment.voice(path: path, duration: 3, transcript: "转写")
        let parts = ChatAttachmentPromptBuilder.userMessage(displayBase: "文字", attachments: [v])
        let restored = ChatAttachmentPromptBuilder.restore(
            content: parts.modelText, segments: parts.segments, replyToId: nil, replyQuote: nil,
            read: { _ in nil }, extract: { _ in nil })
        XCTAssertEqual(restored.text, "文字")
        XCTAssertTrue(restored.attachments.isEmpty)
        XCTAssertEqual(restored.missingCount, 0)
    }

    // MARK: - Codable

    func testVoiceAttachmentRoundTrip() throws {
        let v = PendingChatAttachment.voice(path: path, duration: 12.5, transcript: "嗯")
        let back = try JSONDecoder().decode(PendingChatAttachment.self, from: JSONEncoder().encode(v))
        XCTAssertEqual(back, v)
        XCTAssertEqual(back.kind, .voice)
        XCTAssertEqual(back.audioDuration, 12.5)
        XCTAssertEqual(back.storedRef, path)
    }

    /// 老草稿 / 老排队 JSON 没有 audioDuration（也可能没有 storedRef）——照样解
    func testOldDraftJSONWithoutDurationDecodes() throws {
        let old = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"a.txt","kind":"text","typeDescription":"文本",
          "extractedText":"hello","byteCount":5}]
        """
        let atts = try JSONDecoder().decode([PendingChatAttachment].self, from: Data(old.utf8))
        XCTAssertEqual(atts.count, 1)
        XCTAssertNil(atts[0].audioDuration)
        XCTAssertNil(atts[0].storedRef)
        XCTAssertEqual(atts[0].kind, .text)
    }

    // MARK: - 切走了：存进原对话草稿附件（M4）

    func testAppendingToDraftKeepsExistingAttachments() throws {
        let f = PendingChatAttachment.text(name: "a.txt", typeDescription: "文本", extractedText: "x", byteCount: 1)
        let v = PendingChatAttachment.voice(path: path, duration: 4, transcript: "嗨")
        let existing = try JSONEncoder().encode([f])
        let data = try XCTUnwrap(VoiceNoteSender.appendingToDraft(existing, v))
        let atts = try JSONDecoder().decode([PendingChatAttachment].self, from: data)
        XCTAssertEqual(atts, [f, v])

        let fromNil = try XCTUnwrap(VoiceNoteSender.appendingToDraft(nil, v))
        XCTAssertEqual(try JSONDecoder().decode([PendingChatAttachment].self, from: fromNil), [v])
        // 旧数据坏了：只留新语音，不丢
        let fromJunk = try XCTUnwrap(VoiceNoteSender.appendingToDraft(Data("junk".utf8), v))
        XCTAssertEqual(try JSONDecoder().decode([PendingChatAttachment].self, from: fromJunk), [v])
    }

    // MARK: - 显示 / 复制读段，不从 content 形状猜（sol P2-4 / P2-7）

    func testTypedAndCopyTextComeFromSegments() {
        let mixed: [MessageSegment] = [
            .text("你看这个\n[语音 0:07] 这行是她手打的"),
            .audioRef(name: "v.m4a", mime: "audio/mp4", path: "a/v.m4a", duration: 7, script: "今天好累"),
        ]
        // 打的字原样（同形状的手打行不剥）；复制 = 打的字 + 转写
        XCTAssertEqual(mixed.userTypedTextIfVoice, "你看这个\n[语音 0:07] 这行是她手打的")
        XCTAssertEqual(mixed.userVoiceCopyText, "你看这个\n[语音 0:07] 这行是她手打的\n\n今天好累")

        let pure: [MessageSegment] = [.audioRef(name: "v.m4a", mime: "audio/mp4", path: "a/v.m4a", duration: 3, script: "嗯")]
        XCTAssertEqual(pure.userTypedTextIfVoice, "")
        XCTAssertEqual(pure.userVoiceCopyText, "嗯")
        // 没转出文字：复制什么也不带
        let silent: [MessageSegment] = [.audioRef(name: "v.m4a", mime: "audio/mp4", path: "a/v.m4a", duration: 3, script: nil)]
        XCTAssertEqual(silent.userVoiceCopyText, "")
    }

    func testPlainMessageWithMarkerShapedLineIsUntouched() {
        // 没有 audioRef 的普通消息：手打一整行 `[语音 0:07] x` 原样保留（不走语音口径）
        let plain: [MessageSegment] = [.text("前\n[语音 0:07] x\n后")]
        XCTAssertNil(plain.userTypedTextIfVoice)
        XCTAssertNil(plain.userVoiceCopyText)
        XCTAssertEqual(ChatSelectionText.body(content: "前\n[语音 0:07] x\n后", segments: [], isUser: true, cacheKey: "t-plain"),
                       "前\n[语音 0:07] x\n后")
        XCTAssertEqual(ChatSelectionText.body(content: "x", segments: plain, isUser: true, cacheKey: "t-plain2"),
                       "前\n[语音 0:07] x\n后")
    }

    func testMultiSelectCopyCarriesTranscriptInOrder() {
        let segs: [MessageSegment] = [
            .text("你看这个"),
            .audioRef(name: "v.m4a", mime: "audio/mp4", path: "a/v.m4a", duration: 7, script: "今天好累"),
            .attachment(name: "a.txt", type: "txt", extractedContent: "x"),
        ]
        XCTAssertEqual(ChatSelectionText.body(content: "你看这个\n\n[语音 0:07] 今天好累", segments: segs, isUser: true, cacheKey: "t-mix"),
                       "你看这个\n\n今天好累[文件 a.txt]")
        // 纯语音没转出文字：留 [语音] 占位，不露内部标记
        let silent: [MessageSegment] = [.audioRef(name: "v.m4a", mime: "audio/mp4", path: "a/v.m4a", duration: 3, script: nil)]
        XCTAssertEqual(ChatSelectionText.body(content: "[语音 0:03]（没转出文字）", segments: silent, isUser: true, cacheKey: "t-silent"),
                       "[语音]")
    }

    // MARK: - 声纹均值归一（TG，research-voice-chat-v2 §6.3）

    /// 一个尖峰不再把其他柱压扁：参考 = 均值 × 1.8，尖峰顶格，其余保持可见高度
    func testNormalizedUsesMeanNotPeak() {
        var rms = [Double](repeating: 0.1, count: 10)
        rms[3] = 1.0
        let bars = VoiceWave.normalized(rms)
        // 均值 0.19 → 参考 0.342：普通柱 ≈ 0.29（按峰值归一只有 0.1）
        XCTAssertEqual(bars[0], 0.1 / (0.19 * 1.8), accuracy: 1e-9)
        XCTAssertGreaterThan(bars[0], 0.25)
        XCTAssertEqual(bars[3], 1)
    }

    /// 播放进度按根插值：停在半根上 = 那根一半
    func testPlayedFillInterpolatesPerBar() {
        XCTAssertEqual(VoiceWave.playedFill(index: 0, count: 10, fraction: 0), 0)
        XCTAssertEqual(VoiceWave.playedFill(index: 2, count: 10, fraction: 0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(VoiceWave.playedFill(index: 1, count: 10, fraction: 0.25), 1)
        XCTAssertEqual(VoiceWave.playedFill(index: 3, count: 10, fraction: 0.25), 0)
        XCTAssertEqual(VoiceWave.playedFill(index: 9, count: 10, fraction: 1), 1)
        XCTAssertEqual(VoiceWave.playedFill(index: 0, count: 0, fraction: 0.5), 0)
    }

    /// 长出来：开头全是起点高，左边先长，结束 = 原样
    func testGrownLeftToRight() {
        let bars = [Double](repeating: 1, count: 10)
        XCTAssertEqual(VoiceWave.grown(bars, from: 0.3, progress: 0), [Double](repeating: 0.3, count: 10))
        let mid = VoiceWave.grown(bars, from: 0.3, progress: 0.4)
        XCTAssertGreaterThan(mid[0], mid[5])
        XCTAssertEqual(mid[9], 0.3, accuracy: 1e-9)
        XCTAssertEqual(VoiceWave.grown(bars, from: 0.3, progress: 1), bars)
    }

    /// 下限：几乎静音的录音不被放大成满格
    func testNormalizedFloorKeepsSilenceLow() {
        let bars = VoiceWave.normalized([Double](repeating: 0.001, count: 8))
        XCTAssertEqual(bars, [Double](repeating: VoiceWave.minBar, count: 8))
        XCTAssertEqual(VoiceWave.normalized([]), [])
        XCTAssertEqual(VoiceWave.normalized([0, 0]), [VoiceWave.minBar, VoiceWave.minBar])
    }
}
