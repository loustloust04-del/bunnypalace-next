import XCTest
@testable import 记忆花园

/// 分享语音条的文件名（plan-voice-polish-1007 D）：<说话人>的语音条-yyyyMMdd-HHmm.<原扩展名>
final class VoiceNoteShareTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    /// 2026-10-07 09:05:42 +08:00
    private let date = Date(timeIntervalSince1970: 1_791_335_142)

    func testFileNameUsesSpeakerTimeAndOriginalExtension() {
        XCTAssertEqual(VoiceNoteShare.fileName(speaker: "小岚", date: date, ext: "m4a", timeZone: shanghai),
                       "小岚的语音条-20261007-0905.m4a")
        XCTAssertEqual(VoiceNoteShare.fileName(speaker: "你", date: date, ext: "mp3", timeZone: shanghai),
                       "你的语音条-20261007-0905.mp3")
    }

    func testFileNameFollowsTimeZone() {
        XCTAssertEqual(VoiceNoteShare.fileName(speaker: "小岚", date: date, ext: "m4a", timeZone: TimeZone(identifier: "UTC")!),
                       "小岚的语音条-20261007-0105.m4a")
    }

    func testFileNameSanitizesSpeakerAndHandlesEmptyParts() {
        XCTAssertEqual(VoiceNoteShare.fileName(speaker: " a/b:c ", date: date, ext: "wav", timeZone: shanghai),
                       "a-b-c的语音条-20261007-0905.wav")
        XCTAssertEqual(VoiceNoteShare.fileName(speaker: "  ", date: date, ext: "m4a", timeZone: shanghai),
                       "语音条-20261007-0905.m4a")
        XCTAssertEqual(VoiceNoteShare.fileName(speaker: "小岚", date: date, ext: "", timeZone: shanghai),
                       "小岚的语音条-20261007-0905")
    }
}
