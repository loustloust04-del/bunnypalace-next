import XCTest
@testable import 记忆花园

/// 发语音条 M1：.audioRef segment 的 Codable 兼容性。
final class VoiceSegmentTests: XCTestCase {

    func testAudioRefRoundtrip() throws {
        let seg = MessageSegment.audioRef(
            name: "voice-20260711-120000.mp3", mime: "audio/mpeg",
            path: "attachments/abc-对话/voice-20260711-120000.mp3",
            duration: 12.5, script: "[breathing heavily] 等一下……我来了。"
        )
        let data = try JSONEncoder().encode([seg])
        let back = try JSONDecoder().decode([MessageSegment].self, from: data)
        XCTAssertEqual(back, [seg])
    }

    func testAudioRefNilOptionalsRoundtrip() throws {
        let seg = MessageSegment.audioRef(
            name: "v.mp3", mime: "audio/mpeg", path: "attachments/x/v.mp3",
            duration: nil, script: nil
        )
        let data = try JSONEncoder().encode([seg])
        let back = try JSONDecoder().decode([MessageSegment].self, from: data)
        XCTAssertEqual(back, [seg])
    }

    func testLegacySegmentsStillDecode() throws {
        // 老数据（无 audioRef 的既有 kind）必须原样解码
        let legacy = """
        [{"kind":"text","text":"你好"},
         {"kind":"fileDataRef","name":"a.pdf","type":"application/pdf","path":"attachments/x/a.pdf"},
         {"kind":"imageRef","name":"p.jpg","type":"image/jpeg","path":"attachments/x/p.jpg"}]
        """
        let back = try JSONDecoder().decode([MessageSegment].self, from: Data(legacy.utf8))
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0], .text("你好"))
    }

    func testHasRenderableSegmentsExcludesAudioRef() {
        // 「字刚出来就不见了」bug 的锁：只挂语音条的消息不该切 segmented 渲染（正文在 content 里）
        let audio = MessageSegment.audioRef(name: "v.mp3", mime: "audio/mpeg", path: "p", duration: 1, script: "s")
        XCTAssertFalse([audio].hasRenderableSegments, "audioRef-only → 正文走纯文本分支")
        XCTAssertFalse([MessageSegment]().hasRenderableSegments)
        XCTAssertTrue([audio, .text("正文")].hasRenderableSegments, "混合段照走 segmented")
        XCTAssertTrue([MessageSegment.toolUse(id: "1", name: "t", inputJSON: "{}", integrationName: nil, iconName: nil)].hasRenderableSegments)
    }

    func testAudioRefHydratePassthrough() {
        // audioRef 不经 hydrate 变形：播放走文件 URL，不需要 inline Data
        let seg = MessageSegment.audioRef(
            name: "v.mp3", mime: "audio/mpeg", path: "attachments/x/v.mp3",
            duration: 3.0, script: "s"
        )
        XCTAssertEqual(seg.hydrated(profileId: "xctest-voice"), seg)
        XCTAssertEqual([seg].hydratedForDisplay(profileId: "xctest-voice"), [seg])
    }
}
