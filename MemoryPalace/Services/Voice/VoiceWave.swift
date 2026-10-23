import Foundation
import AVFoundation
import CoreGraphics

/// 语音条的声纹（research-chat-cards §11，照 HTML 小样）：柱数随时长、按文件本身的响度算；播放头附近跟着弹
enum VoiceWave {
    static let minBar = 0.12
    static let barWidth: CGFloat = 3
    static let gap: CGFloat = 2.5

    static func barCount(duration: Double?) -> Int {
        guard let d = duration, d.isFinite, d > 0 else { return 16 }
        return min(34, max(10, Int((8 + d * 0.9).rounded())))
    }

    static func width(barCount n: Int) -> CGFloat {
        CGFloat(n) * (barWidth + gap) - gap
    }

    /// 归一的参考值下限（RMS 尺度；TG 峰值尺度的 2500/32767 ≈ 0.076，语音峰值 / RMS 约 3 倍 → 0.025 一档）：
    /// 几乎静音的录音不会被放大成满格
    static let referenceFloor = 0.025

    /// 归一（TG 做法，research-voice-chat-v2 §6.3）：参考值 = 均值 × 1.8（有下限），超过的顶格。
    /// 不用最大值：一个尖峰不再把其他柱压扁。最矮 minBar（说话停顿处也留一点点）
    static func normalized(_ rms: [Double], floor: Double = referenceFloor) -> [Double] {
        guard !rms.isEmpty else { return [] }
        let mean = rms.reduce(0, +) / Double(rms.count)
        let reference = max(mean * 1.8, floor)
        return rms.map { min(1, max(minBar, $0 / reference)) }
    }

    /// 分段 RMS → 归一（normalized），最矮 minBar
    static func bars(fromSamples samples: [Float], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard !samples.isEmpty else { return [Double](repeating: minBar, count: count) }
        let chunk = Double(samples.count) / Double(count)
        let rms: [Double] = (0..<count).map { i in
            let lo = Int(Double(i) * chunk), hi = max(lo + 1, min(samples.count, Int(Double(i + 1) * chunk)))
            var sum = 0.0
            for j in lo..<hi { sum += Double(samples[j] * samples[j]) }
            return (sum / Double(hi - lo)).squareRoot()
        }
        return normalized(rms)
    }

    /// 读音频文件（录音 m4a / 合成 mp3 / wav 都行）的第一声道：固定 32k 帧的缓冲分块读、边读边按柱累加（内存恒定，终审 I-4）
    static func bars(forFile url: URL, count: Int) async -> [Double]? {
        await Task.detached(priority: .utility) { () -> [Double]? in
            guard count > 0, let file = try? AVAudioFile(forReading: url) else { return nil }
            let total = file.length
            let chunk: AVAudioFrameCount = 32_768
            guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
            var sums = [Double](repeating: 0, count: count)
            var counts = [Int](repeating: 0, count: count)
            var position: Int64 = 0
            while position < total {
                do { try file.read(into: buffer, frameCount: chunk) } catch { break }   // mp3 的长度是估算，读到头会提前结束
                let n = Int(buffer.frameLength)
                guard n > 0, let channel = buffer.floatChannelData?[0] else { break }
                for i in 0..<n {
                    let bar = min(count - 1, Int(Double(position + Int64(i)) / Double(total) * Double(count)))
                    let v = Double(channel[i])
                    sums[bar] += v * v
                    counts[bar] += 1
                }
                position += Int64(n)
            }
            guard counts.contains(where: { $0 > 0 }) else { return nil }
            let rms = (0..<count).map { counts[$0] > 0 ? (sums[$0] / Double(counts[$0])).squareRoot() : 0 }
            return normalized(rms)
        }.value
    }

    /// 播放头附近按当前那根柱的响度弹高（同小样），最高 1.45 倍
    static func bounced(_ bars: [Double], fraction: Double, playing: Bool) -> [Double] {
        guard playing, !bars.isEmpty else { return bars }
        let n = Double(bars.count)
        let level = bars[min(bars.count - 1, max(0, Int(fraction * n)))]
        return bars.enumerated().map { i, a in
            let near = max(0, 1 - abs((Double(i) + 0.5) / n - fraction) * n / 3)
            return a * (1 + level * near * 0.45)
        }
    }

    /// 第一次出现「长出来」的时长（TG）
    static let growDuration: Double = 0.8
    /// 声纹读出来之前的平柱高（也是「长出来」的起点）
    static let placeholderLevel = 0.3

    /// 从左往右长出来：progress 0…1；第 i 根在 [i/n×0.7, i/n×0.7+0.3] 这段里从 base 缓出长到目标高
    static func grown(_ bars: [Double], from base: Double, progress: Double) -> [Double] {
        guard progress < 1, !bars.isEmpty else { return bars }
        let n = Double(bars.count)
        return bars.enumerated().map { i, a in
            let local = min(1, max(0, (progress - Double(i) / n * 0.7) / 0.3))
            let eased = 1 - (1 - local) * (1 - local)
            return base + (a - base) * eased
        }
    }

    /// 播放进度按根插值（TG）：第 i 根被播放头扫过的比例 0…1，停在半根上就是半根的颜色
    static func playedFill(index i: Int, count n: Int, fraction: Double) -> Double {
        guard n > 0 else { return 0 }
        return min(1, max(0, fraction * Double(n) - Double(i)))
    }

    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func remaining(duration: Double, fraction: Double) -> String {
        "-" + clock(duration * (1 - min(max(fraction, 0), 1)))
    }

    /// 录音电平的静音线：-50dB 记 0，0dB 记 1（plan-voice-note M2）
    static let silenceDB = -50.0

    static func level(decibels db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return min(1, max(0, (db - silenceDB) / -silenceDB))
    }

    /// 电平（0…1，录音器 dB 换算）参考值下限（小样 0.12）：几乎没出声的录音不放大成满格
    static let levelFloor = 0.12

    /// 峰值序列按柱重采样：每根取它那段里的最大值（小样 resample）；源为空 = 全 0
    static func resampledPeaks(_ peaks: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard !peaks.isEmpty else { return [Double](repeating: 0, count: count) }
        return (0..<count).map { i in
            let lo = i * peaks.count / count
            let hi = max(lo + 1, (i + 1) * peaks.count / count)
            return peaks[lo..<min(hi, peaks.count)].max() ?? 0
        }
    }
}

/// 录音时的声纹采样（TG，plan-voice-note M2）：每个电平先攒进当前格取峰值，攒满 `compress` 个出一格；
/// 存满 `capacity` 格就两两取 max 合并成一半、之后每格攒的个数翻倍——长录音也只存 ≤200 个峰值，覆盖全程
struct VoicePeakSampler: Equatable {
    static let capacity = 200

    private(set) var peaks: [Double] = []
    private(set) var compress = 1
    private var acc = 0.0
    private var accCount = 0

    mutating func push(_ level: Double) {
        acc = max(acc, level)
        accCount += 1
        guard accCount >= compress else { return }
        peaks.append(acc)
        acc = 0
        accCount = 0
        if peaks.count >= Self.capacity {
            peaks = Self.merged(peaks)
            compress *= 2
        }
    }

    /// 两两取 max 合并（奇数个时最后一个单独成格）
    static func merged(_ peaks: [Double]) -> [Double] {
        stride(from: 0, to: peaks.count, by: 2).map { i in
            i + 1 < peaks.count ? max(peaks[i], peaks[i + 1]) : peaks[i]
        }
    }
}

/// 声纹缓存：同一条只读一次；同时来的请求合并；读失败缓存平柱，不反复重读（终审 I-4 / M-4）
@MainActor
final class VoiceWaveCache {
    static let shared = VoiceWaveCache(reader: { await VoiceWave.bars(forFile: $0, count: $1) })

    private let reader: (URL, Int) async -> [Double]?
    private var cache: [String: [Double]] = [:]
    private var inFlight: [String: Task<[Double], Never>] = [:]

    init(reader: @escaping (URL, Int) async -> [Double]?) {
        self.reader = reader
    }

    func cached(_ key: String) -> [Double]? { cache[key] }

    func bars(key: String, url: URL, count: Int) async -> [Double] {
        if let hit = cache[key] { return hit }
        if let running = inFlight[key] { return await running.value }
        let reader = self.reader
        let task = Task { await reader(url, count) ?? [Double](repeating: VoiceWave.minBar, count: count) }
        inFlight[key] = task
        let bars = await task.value
        inFlight[key] = nil
        cache[key] = bars
        return bars
    }
}
