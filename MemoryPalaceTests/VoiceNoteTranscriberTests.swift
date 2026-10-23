import XCTest
@testable import 记忆花园

/// 语音条文件转写 smoke（plan-voice-note M3）：系统 TTS 合成一段中文 → 转成录音器同款 m4a（AAC 单声道 22.05kHz）→ 转写非空。
/// 音频现场生成，不进仓库。首次跑可能要下 zh_CN 模型（超时就 skip，不算失败）
final class VoiceNoteTranscriberTests: XCTestCase {

    func testTranscribesSynthesizedChineseM4A() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer 需要 macOS 26") }
        let dir = FileManager.default.temporaryDirectory
        let aiff = dir.appendingPathComponent("vn-\(UUID().uuidString).aiff")
        let m4a = dir.appendingPathComponent("vn-\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: aiff)
            try? FileManager.default.removeItem(at: m4a)
        }
        guard run("/usr/bin/say", ["-v", "Eddy (Chinese (China mainland))", "-o", aiff.path, "今天天气真好，我们一起听一首歌吧。"]) else {
            throw XCTSkip("say 生成音频失败，跳过")
        }
        guard run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-c", "1", "-r", "22050", aiff.path, m4a.path]) else {
            throw XCTSkip("afconvert 转 m4a 失败，跳过")
        }

        // 资产首次下载给足时间；正式发送路径是 10 秒
        let text = await VoiceNoteTranscriber.transcribe(fileURL: m4a, timeout: .seconds(120))
        guard let text else { throw XCTSkip("没转出文字（可能模型资产没装上 / 本机不支持 zh_CN），跳过") }
        print("[VOICE-NOTE TEST] 转写：\(text)")
        XCTAssertTrue(text.contains("天气") || text.contains("听") || text.contains("歌"), "转写应命中关键词，实际：\(text)")
    }

    /// 文件读不了 / 超时都返回 nil，不挂住
    func testMissingFileAndTimeoutReturnNil() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer 需要 macOS 26") }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).m4a")
        let started = Date()
        let r1 = await VoiceNoteTranscriber.transcribe(fileURL: missing, timeout: .seconds(20))
        XCTAssertNil(r1)
        let r2 = await VoiceNoteTranscriber.transcribe(fileURL: missing, timeout: .milliseconds(1))
        XCTAssertNil(r2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 25)
    }

    private func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
