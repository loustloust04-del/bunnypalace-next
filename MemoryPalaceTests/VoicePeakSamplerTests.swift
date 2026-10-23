import XCTest
@testable import 记忆花园

/// 录音声纹采样（plan-voice-note M2）：≤200 峰值，满了两两取 max 合并、之后每格攒的个数翻倍
final class VoicePeakSamplerTests: XCTestCase {
    func testMergedTakesPairwiseMax() {
        XCTAssertEqual(VoicePeakSampler.merged([0.1, 0.5, 0.3, 0.2]), [0.5, 0.3])
        XCTAssertEqual(VoicePeakSampler.merged([0.1, 0.5, 0.9]), [0.5, 0.9])   // 奇数个：最后一个单独成格
        XCTAssertEqual(VoicePeakSampler.merged([]), [])
    }

    func testBelowCapacityKeepsEverySample() {
        var s = VoicePeakSampler()
        for i in 0..<10 { s.push(Double(i) / 10) }
        XCTAssertEqual(s.peaks.count, 10)
        XCTAssertEqual(s.compress, 1)
        XCTAssertEqual(s.peaks.last ?? -1, 0.9, accuracy: 1e-9)
    }

    func testFullCapacityHalvesAndDoublesCompress() {
        var s = VoicePeakSampler()
        for i in 0..<VoicePeakSampler.capacity { s.push(i == 7 ? 1 : 0.1) }
        XCTAssertEqual(s.peaks.count, VoicePeakSampler.capacity / 2)
        XCTAssertEqual(s.compress, 2)
        XCTAssertEqual(s.peaks[3], 1)                       // 第 7 个的尖峰合并进第 3 格，没丢
        // 之后每两个出一格
        s.push(0.4)
        XCTAssertEqual(s.peaks.count, 100)
        s.push(0.2)
        XCTAssertEqual(s.peaks.count, 101)
        XCTAssertEqual(s.peaks.last ?? -1, 0.4, accuracy: 1e-9)
    }

    func testLongRecordingStaysBounded() {
        var s = VoicePeakSampler()
        for _ in 0..<(60 * 600) { s.push(0.5) }             // 10 分钟 × 60 帧
        XCTAssertLessThan(s.peaks.count, VoicePeakSampler.capacity)
        XCTAssertGreaterThanOrEqual(s.peaks.count, VoicePeakSampler.capacity / 2 - 1)
    }

    func testLevelFromDecibels() {
        XCTAssertEqual(VoiceWave.level(decibels: -160), 0)
        XCTAssertEqual(VoiceWave.level(decibels: -50), 0)
        XCTAssertEqual(VoiceWave.level(decibels: -25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(VoiceWave.level(decibels: 0), 1)
        XCTAssertEqual(VoiceWave.level(decibels: 3), 1)
        XCTAssertEqual(VoiceWave.level(decibels: -.infinity), 0)
    }

    func testResampledPeaksTakesBucketMax() {
        XCTAssertEqual(VoiceWave.resampledPeaks([0.1, 0.9, 0.2, 0.3], count: 2), [0.9, 0.3])
        XCTAssertEqual(VoiceWave.resampledPeaks([0.4], count: 3), [0.4, 0.4, 0.4])
        XCTAssertEqual(VoiceWave.resampledPeaks([], count: 2), [0, 0])
    }

    func testLevelNormalizationUsesLevelFloor() {
        // 几乎没出声：参考值落到下限 0.12，不放大成满格
        let quiet = VoiceWave.normalized([0.01, 0.02], floor: VoiceWave.levelFloor)
        XCTAssertTrue(quiet.allSatisfy { $0 < 0.3 })
    }
}
