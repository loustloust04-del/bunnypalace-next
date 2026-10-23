import XCTest
@testable import 记忆花园

/// 语音条重做（research-chat-cards §11，照 HTML 小样 https://claude.ai/artifact/4Sy83skxbVpNnG2Vn4DpqG）
final class VoiceNoteTests: XCTestCase {

    func testBarCountAndWidthFollowDuration() {
        XCTAssertEqual(VoiceWave.barCount(duration: 1), 10)
        XCTAssertEqual(VoiceWave.barCount(duration: 13), 20)
        XCTAssertEqual(VoiceWave.barCount(duration: 300), 34)
        XCTAssertEqual(VoiceWave.barCount(duration: nil), 16)
        XCTAssertEqual(VoiceWave.width(barCount: 10), 52.5, accuracy: 1e-9)
    }

    func testBarsFromSamplesFollowLoudness() {
        // 前半静音、后半有声 → 前面的柱矮、后面的柱高；归一后最高 1
        var s = [Float](repeating: 0, count: 1000)
        for i in 500..<1000 { s[i] = i % 2 == 0 ? 0.3 : -0.3 }
        let bars = VoiceWave.bars(fromSamples: s, count: 10)
        XCTAssertEqual(bars.count, 10)
        XCTAssertEqual(bars.max() ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(bars[0], VoiceWave.minBar, accuracy: 1e-6)
        XCTAssertGreaterThan(bars[9], bars[0])
        XCTAssertEqual(VoiceWave.bars(fromSamples: [], count: 5), [Double](repeating: VoiceWave.minBar, count: 5))
    }

    /// 播放头附近按当前那根柱的响度弹高（同小样），远处不动；不在放不弹
    func testBounceNearPlayhead() {
        let bars = [Double](repeating: 0.5, count: 20)
        XCTAssertEqual(VoiceWave.bounced(bars, fraction: 0.5, playing: false), bars)
        let b = VoiceWave.bounced(bars, fraction: 0.5, playing: true)
        XCTAssertGreaterThan(b[10], 0.5)
        XCTAssertEqual(b[0], 0.5)
    }

    func testRemainingText() {
        XCTAssertEqual(VoiceWave.clock(13), "0:13")
        XCTAssertEqual(VoiceWave.remaining(duration: 13, fraction: 0.5), "-0:07")
        XCTAssertEqual(VoiceWave.remaining(duration: 65, fraction: 0), "-1:05")
    }

    func testBarsFromAudioFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).wav")
        var s = [Float](repeating: 0, count: 8000)
        for i in 4000..<8000 { s[i] = Float(sin(Double(i) * 0.3)) * 0.5 }
        try WAV.encode(s, sampleRate: 8000).write(to: url)
        let bars = await VoiceWave.bars(forFile: url, count: 12)
        XCTAssertEqual(bars?.count, 12)
        XCTAssertGreaterThan(bars?.last ?? 0, bars?.first ?? 1)
        try? FileManager.default.removeItem(at: url)
    }

    /// 同一条再点 = 暂停（保留位置），再点 = 继续；点别的 = 停掉这条
    @MainActor
    func testVoicePlayerPauseResume() throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("va-\(UUID().uuidString).wav")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("vb-\(UUID().uuidString).wav")
        try WAV.encode([Float](repeating: 0, count: 16000), sampleRate: 8000).write(to: a)
        try WAV.encode([Float](repeating: 0, count: 16000), sampleRate: 8000).write(to: b)
        let voice = VoiceMessagePlayer()
        voice.beforePlay = {}
        voice.toggle(url: a, id: "a")
        XCTAssertEqual(voice.state(for: "a"), .playing)
        voice.toggle(url: a, id: "a")
        XCTAssertEqual(voice.state(for: "a"), .paused)
        voice.toggle(url: a, id: "a")
        XCTAssertEqual(voice.state(for: "a"), .playing)
        voice.toggle(url: b, id: "b")
        XCTAssertEqual(voice.state(for: "a"), .idle)
        XCTAssertEqual(voice.state(for: "b"), .playing)
        XCTAssertNotNil(voice.fraction(for: "b"))
        XCTAssertNil(voice.fraction(for: "a"))
        voice.stop()
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.removeItem(at: b)
    }

    // MARK: 终审修复

    /// 同一条声纹同时请求只读一次；读失败缓存平柱，不反复重读（终审 I-4 / M-4）
    @MainActor
    func testWaveCacheDedupesAndCachesFailure() async {
        let counter = ReadCounter()
        let cache = VoiceWaveCache(reader: { _, count in counter.bump(); return count == 7 ? nil : [Double](repeating: 0.5, count: count) })
        let url = URL(fileURLWithPath: "/tmp/x.m4a")
        async let a = cache.bars(key: "k", url: url, count: 5)
        async let b = cache.bars(key: "k", url: url, count: 5)
        let (ra, rb) = await (a, b)
        XCTAssertEqual(ra, rb)
        XCTAssertEqual(counter.count, 1)
        let failed = await cache.bars(key: "bad", url: url, count: 7)
        XCTAssertEqual(failed, [Double](repeating: VoiceWave.minBar, count: 7))
        _ = await cache.bars(key: "bad", url: url, count: 7)
        XCTAssertEqual(counter.count, 2)
    }

    final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// 暂停时停掉计时器；按 id 停只停这一条（终审 I-3）
    @MainActor
    func testPauseStopsTickingAndStopById() throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("vt-\(UUID().uuidString).wav")
        try WAV.encode([Float](repeating: 0, count: 16000), sampleRate: 8000).write(to: a)
        let voice = VoiceMessagePlayer()
        voice.beforePlay = {}
        voice.toggle(url: a, id: "a")
        XCTAssertTrue(voice.isTicking)
        voice.toggle(url: a, id: "a")
        XCTAssertFalse(voice.isTicking)
        voice.stop(id: "b")
        XCTAssertEqual(voice.state(for: "a"), .paused)
        voice.stop(id: "a")
        XCTAssertEqual(voice.state(for: "a"), .idle)
        try? FileManager.default.removeItem(at: a)
    }
}
