import Foundation
import AVFoundation

/// 原始电平测量；只提供声学线索，不推断心情。时间分段基于能量，明确标为估计。
struct VoiceProsody: Codable, Hashable, Sendable {
    static let version = 1
    let duration: Double
    let leadingQuiet: Double
    let speechSpan: Double
    let activeDuration: Double
    let pauseCount: Int
    let rms: Double
    let clippedFraction: Double

    var canLearn: Bool {
        duration.isFinite && duration >= 1 && duration <= 601 && activeDuration >= 0.8
            && rms.isFinite && rms > 0 && clippedFraction < 0.01
            && leadingQuiet.isFinite && leadingQuiet >= 0 && leadingQuiet <= duration
            && speechSpan.isFinite && speechSpan >= activeDuration && speechSpan <= duration
            && activeDuration.isFinite && activeDuration <= duration
            && clippedFraction.isFinite && clippedFraction >= 0 && pauseCount >= 0
    }

    func estimatedPace(transcript: String) -> Double? {
        let count = transcript.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard count >= 4, speechSpan >= 1 else { return nil }
        return Double(count) / speechSpan
    }

    /// 每帧 20ms；保留未归一化 RMS。幅值不足只放弃分析，不影响原来的转写 / 发送。
    static func measure(energies: [Double], clippedFraction: Double,
                        frameDuration: Double = 0.02) -> VoiceProsody? {
        guard frameDuration.isFinite, frameDuration > 0, !energies.isEmpty,
              energies.allSatisfy({ $0.isFinite && $0 >= 0 }),
              clippedFraction.isFinite, (0...1).contains(clippedFraction),
              let peak = energies.max(), peak >= 0.008 else { return nil }
        // 只用明显低于主要声音的帧估计环境底，不把连续说话的 RMS 当成噪声。
        let quiet = energies.filter { $0 < peak * 0.25 }.sorted()
        let noise = quiet.isEmpty ? 0.001 : quiet[quiet.count / 2]
        let threshold = max(0.008, noise * 3)
        let active = energies.map { $0 >= threshold }
        guard let first = active.firstIndex(of: true), let last = active.lastIndex(of: true) else { return nil }
        let voiced = energies.enumerated().compactMap { active[$0.offset] ? $0.element : nil }
        var pauses = 0, quietRun = 0
        for index in first...last {
            if active[index] {
                if Double(quietRun) * frameDuration >= 0.3 { pauses += 1 }
                quietRun = 0
            } else { quietRun += 1 }
        }
        return VoiceProsody(duration: Double(energies.count) * frameDuration,
                            leadingQuiet: Double(first) * frameDuration,
                            speechSpan: Double(last - first + 1) * frameDuration,
                            activeDuration: Double(voiced.count) * frameDuration,
                            pauseCount: pauses,
                            rms: sqrt(voiced.reduce(0) { $0 + $1 * $1 } / Double(voiced.count)),
                            clippedFraction: clippedFraction)
    }

    /// 后台分块读，最多 601 秒；取消 / 读取不完整 / 时间预算耗尽都不产出片段的伪完整结果。
    static func analyze(fileURL: URL, budget: Duration = .seconds(2)) async -> VoiceProsody? {
        let work = Task.detached(priority: .utility) { () -> VoiceProsody? in
            guard let file = try? AVAudioFile(forReading: fileURL),
                  file.processingFormat.sampleRate > 0,
                  file.processingFormat.channelCount == 1,
                  Double(file.length) / file.processingFormat.sampleRate <= 601,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else { return nil }
            let frameSamples = max(1, Int(file.processingFormat.sampleRate * 0.02))
            let deadline = ContinuousClock.now + budget
            var energies: [Double] = [], sum = 0.0, frameCount = 0
            var total = 0, clipped = 0
            while file.framePosition < file.length {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
                let remaining = file.length - file.framePosition
                do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))) }
                catch { return nil }
                let n = Int(buffer.frameLength)
                guard n > 0 else { return nil }
                guard let channel = buffer.floatChannelData?[0] else { return nil }
                for i in 0..<n {
                    let value = Double(channel[i])
                    guard value.isFinite else { return nil }
                    total += 1
                    if abs(value) >= 0.99 { clipped += 1 }
                    sum += value * value
                    frameCount += 1
                    if frameCount == frameSamples {
                        energies.append(sqrt(sum / Double(frameCount)))
                        sum = 0; frameCount = 0
                    }
                }
            }
            // 零头不足 20ms 丢弃，最大时间误差 <20ms，不放大短尾为完整帧。
            guard total > 0 else { return nil }
            return measure(energies: energies, clippedFraction: Double(clipped) / Double(total),
                           frameDuration: Double(frameSamples) / file.processingFormat.sampleRate)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}

/// 附件里单独保存，不混进 audioRef.script；草稿转存时随同一条音频走。
struct VoiceProsodyContext: Codable, Hashable, Sendable {
    let version: Int
    let measurement: VoiceProsody
    let hint: String
}

@MainActor
final class VoiceProsodyStore {
    static let shared = VoiceProsodyStore(defaults: .standard)
    nonisolated static let enabledKey = "voiceProsody.enabled.v1"
    private static let recordsKey = "voiceProsody.baseline.v1"
    private static let epochKey = "voiceProsody.epoch.v1"
    private let defaults: UserDefaults

    struct Ticket: Sendable {
        let epoch: Int
        let bucket: String
        let source: String
    }
    struct Record: Codable {
        let bucket: String
        let source: String
        let measurement: VoiceProsody
        let pace: Double?
    }

    init(defaults: UserDefaults) { self.defaults = defaults }
    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    private var epoch: Int { defaults.integer(forKey: Self.epochKey) }
    private var records: [Record] {
        guard let data = defaults.data(forKey: Self.recordsKey) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    func begin(bucket: String, source: String) -> Ticket? {
        guard enabled else { return nil }
        return Ticket(epoch: epoch, bucket: bucket, source: source)
    }

    func clear() {
        invalidatePending()
        defaults.removeObject(forKey: Self.recordsKey)
    }

    func invalidatePending() { defaults.set(epoch &+ 1, forKey: Self.epochKey) }

    func forget(source: String) {
        forget(sources: [source])
    }

    func forget(sources: Set<String>) {
        guard !sources.isEmpty else { return }
        invalidatePending()
        save(records.filter { !sources.contains($0.source) })
    }

    /// 用旧记录比较后才入库；窗口按桶，去重按音频归属，迟到任务不复活清掉的基线。
    func finish(_ ticket: Ticket, measurement m: VoiceProsody?, transcript: String?) -> VoiceProsodyContext? {
        guard enabled, ticket.epoch == epoch, let m, m.canLearn,
              let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let all = records
        let history = all.filter { $0.bucket == ticket.bucket && $0.source != ticket.source }
        let pace = m.estimatedPace(transcript: transcript)
        var cues: [String] = []
        if m.leadingQuiet >= 0.6 {
            cues.append(String(format: "开口前静了约 %.1f 秒", m.leadingQuiet))
        }
        if m.pauseCount > 0 { cues.append("中间有 \(m.pauseCount) 次较长停顿") }
        if history.count >= 8 {
            if relative(m.rms, against: history.map { $0.measurement.rms }) < -1.5 {
                cues.append("同一录音设备下声音比平时轻")
            }
            let speeds = history.compactMap(\.pace)
            if let pace, speeds.count >= 8, relative(pace, against: speeds) < -1.5 {
                cues.append("语速比平时慢")
            }
        }
        if !all.contains(where: { $0.source == ticket.source }) {
            let updated = (history + [Record(bucket: ticket.bucket, source: ticket.source, measurement: m, pace: pace)]).suffix(100)
            // 最多 8 个设备桶的窗口；基线只存摘要，不额外保存音频和文字。
            save(Array((all.filter { $0.bucket != ticket.bucket } + updated).suffix(800)))
        }
        guard !cues.isEmpty else { return nil }
        return VoiceProsodyContext(version: VoiceProsody.version, measurement: m,
                                   hint: "[语气线索·本机电平估计] " + cues.joined(separator: "；") + "。仅作声学线索，不推断心情。")
    }

    private func save(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.recordsKey)
    }

    private func relative(_ value: Double, against history: [Double]) -> Double {
        let median = Self.median(history)
        let mad = Self.median(history.map { abs($0 - median) }) * 1.4826
        return (value - median) / max(mad, abs(median) * 0.1, 0.0001)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
