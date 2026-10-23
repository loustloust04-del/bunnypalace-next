import XCTest
@testable import 记忆花园

final class VoiceProsodyTests: XCTestCase {
    func testKnownSilenceAndPhraseTiming() throws {
        // 1秒静音 + 1秒声音 + 0.5秒停顿 + 1秒声音 + 0.5秒尾部静音。
        let energies = Array(repeating: 0.0, count: 50) + Array(repeating: 0.2, count: 50)
            + Array(repeating: 0.0, count: 25) + Array(repeating: 0.2, count: 50)
            + Array(repeating: 0.0, count: 25)
        let m = try XCTUnwrap(VoiceProsody.measure(energies: energies, clippedFraction: 0))
        XCTAssertEqual(m.duration, 4, accuracy: 0.02)
        XCTAssertEqual(m.leadingQuiet, 1, accuracy: 0.02)
        XCTAssertEqual(m.speechSpan, 2.5, accuracy: 0.02)
        XCTAssertEqual(m.activeDuration, 2, accuracy: 0.02)
        XCTAssertEqual(m.pauseCount, 1)
        XCTAssertEqual(m.rms, 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(m.estimatedPace(transcript: "今天天气真的很好。")), 3.2, accuracy: 0.001)
    }

    func testRejectsSilenceInvalidInputAndClippingForLearning() throws {
        XCTAssertNil(VoiceProsody.measure(energies: Array(repeating: 0, count: 100), clippedFraction: 0))
        XCTAssertNil(VoiceProsody.measure(energies: [.nan], clippedFraction: 0))
        XCTAssertNil(VoiceProsody.measure(energies: [0.2], clippedFraction: -1))
        let clipped = try XCTUnwrap(VoiceProsody.measure(energies: Array(repeating: 0.8, count: 100), clippedFraction: 0.1))
        XCTAssertFalse(clipped.canLearn)
        let short = try XCTUnwrap(VoiceProsody.measure(energies: Array(repeating: 0.2, count: 20), clippedFraction: 0))
        XCTAssertFalse(short.canLearn)
    }

    func testAudioFileMeasurement() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prosody-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = (0..<24_000).map { i -> Float in
            i < 8_000 ? 0 : Float(sin(2 * .pi * 200 * Double(i) / 8_000)) * 0.2
        }
        try WAV.encode(samples, sampleRate: 8_000).write(to: url)
        // 测测量正确性，不用测试宿主启动 / 系统负载验证产品的时间预算。
        let result = await VoiceProsody.analyze(fileURL: url, budget: .seconds(10))
        let m = try XCTUnwrap(result)
        XCTAssertEqual(m.leadingQuiet, 1, accuracy: 0.04)
        XCTAssertEqual(m.duration, 3, accuracy: 0.04)
        XCTAssertTrue(m.canLearn)
        let skipped = await VoiceProsody.analyze(fileURL: url, budget: .zero)
        XCTAssertNil(skipped, "预算耗尽跳过分析，不给部分音频编造完整结果")
    }

    @MainActor
    func testBaselineUsesPreviousSamplesAndSeparatesDevices() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for i in 0..<8 { _ = store.finish(try XCTUnwrap(store.begin(bucket: "mic-a", source: "a\(i)")),
                                         measurement: measurement(rms: 0.3), transcript: "今天天气真的很好") }
        let quiet = store.finish(try XCTUnwrap(store.begin(bucket: "mic-a", source: "quiet")),
                                 measurement: measurement(rms: 0.1), transcript: "今天天气真的很好")
        XCTAssertTrue(try XCTUnwrap(quiet).hint.contains("比平时轻"))
        let other = store.finish(try XCTUnwrap(store.begin(bucket: "mic-b", source: "other")),
                                 measurement: measurement(rms: 0.1), transcript: "今天天气真的很好")
        XCTAssertFalse(try XCTUnwrap(other).hint.contains("比平时"))
        let reopened = VoiceProsodyStore(defaults: defaults)
        XCTAssertTrue(try XCTUnwrap(reopened.finish(try XCTUnwrap(reopened.begin(bucket: "mic-a", source: "quiet2")),
                                                   measurement: measurement(rms: 0.1), transcript: "今天天气真的很好")).hint.contains("比平时轻"))
    }

    @MainActor
    func testClearAndDisableDiscardPendingAndDeduplicateSources() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pending = try XCTUnwrap(store.begin(bucket: "mic", source: "old"))
        XCTAssertNil(store.finish(pending, measurement: measurement(), transcript: nil), "没有转写不能把背景声音当作用户声音训练")
        store.clear()
        XCTAssertNil(store.finish(pending, measurement: measurement(), transcript: "今天天气真的很好"))
        for _ in 0..<9 {
            _ = store.finish(try XCTUnwrap(store.begin(bucket: "mic", source: "same")),
                             measurement: measurement(rms: 0.3), transcript: "今天天气真的很好")
        }
        let next = store.finish(try XCTUnwrap(store.begin(bucket: "mic", source: "next")),
                                measurement: measurement(rms: 0.1), transcript: "今天天气真的很好")
        XCTAssertFalse(try XCTUnwrap(next).hint.contains("比平时"), "重发同一份音频不能凑够基线样本")
        let disabled = try XCTUnwrap(store.begin(bucket: "mic", source: "disabled"))
        defaults.set(false, forKey: VoiceProsodyStore.enabledKey)
        store.invalidatePending()
        defaults.set(true, forKey: VoiceProsodyStore.enabledKey)
        XCTAssertNil(store.finish(disabled, measurement: measurement(), transcript: "今天天气真的很好"))
    }

    @MainActor
    func testForgetRemovesSampleFromRelativeComparison() throws {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for i in 0..<8 { _ = store.finish(try XCTUnwrap(store.begin(bucket: "mic", source: "a\(i)")),
                                         measurement: measurement(rms: 0.3), transcript: "今天天气真的很好") }
        store.forget(source: "a0")
        let result = store.finish(try XCTUnwrap(store.begin(bucket: "mic", source: "next")),
                                  measurement: measurement(rms: 0.1), transcript: "今天天气真的很好")
        XCTAssertFalse(try XCTUnwrap(result).hint.contains("比平时"))
    }

    func testVoiceContextRoundTripDoesNotPolluteTranscriptAndCopy() throws {
        var attachment = PendingChatAttachment.voice(path: "v.m4a", duration: 3, transcript: "今天天气真的很好")
        attachment.voiceProsody = VoiceProsodyContext(version: 1, measurement: measurement(), hint: "[语气线索] 开口前静了约 1 秒")
        let restored = try JSONDecoder().decode(PendingChatAttachment.self, from: JSONEncoder().encode(attachment))
        XCTAssertEqual(restored, attachment)
        let parts = ChatAttachmentPromptBuilder.userMessage(displayBase: "", attachments: [restored])
        XCTAssertTrue(parts.modelText.contains("[语气线索]"))
        XCTAssertEqual(parts.segments?.userVoiceCopyText, "今天天气真的很好")
        XCTAssertEqual(parts.segments?.audioRefs.first?.script, "今天天气真的很好")
        let old = PendingChatAttachment.voice(path: "old.m4a", duration: 3, transcript: "嗯")
        XCTAssertEqual(ChatAttachmentPromptBuilder.voiceLine(old), "[语音 0:03] 嗯")
    }

    private func measurement(rms: Double = 0.2) -> VoiceProsody {
        VoiceProsody(duration: 4, leadingQuiet: 1, speechSpan: 3,
                     activeDuration: 2.5, pauseCount: 0, rms: rms, clippedFraction: 0)
    }

    @MainActor
    private func makeStore() -> (VoiceProsodyStore, UserDefaults, String) {
        let suite = "VoiceProsodyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: VoiceProsodyStore.enabledKey)
        return (VoiceProsodyStore(defaults: defaults), defaults, suite)
    }
}
