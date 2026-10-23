import Foundation

/// 内置曲（粟粟 09-26：音乐卡小样里那首也加进来）。音乐卡 `url` 写 `builtin:<名字>` 即播放本地合成的曲子，不联网。
enum BuiltinTrack: String, CaseIterable {
    case slowTide = "slowtide"

    static func parse(_ raw: String?) -> BuiltinTrack? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.hasPrefix("builtin:") else { return nil }
        return BuiltinTrack(rawValue: String(raw.dropFirst("builtin:".count)))
    }

    var title: String {
        switch self {
        case .slowTide: return "慢潮"
        }
    }

    var subtitle: String { "内置曲 · 本地合成" }
}

/// 「慢潮」：120 BPM、48 小节（1 分 36 秒），Am–F–C–G。前奏只有铺底和镲，主段加鼓 / 贝斯 / 拨弦回声，间奏落下，再起。
/// 与 HTML 小样（https://claude.ai/artifact/BFaRPeG2xQX8jJE3JiuTDh）同一份谱；离线逐样本合成，结果确定（噪声用固定种子）。
enum SlowTide {
    /// 谱或合成改了就加一（缓存文件名带它，旧文件不会被继续用）
    static let version = 1
    static let duration: Double = 96
    static let bpm: Double = 120
    static var step: Double { 60 / bpm / 4 }

    private static let chords: [[Int]] = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
    private static let melody = [0, 3, 5, 7, 10, 12, 10, 7]

    private enum Section { case intro, full, breakdown }
    private static func section(_ bar: Int) -> Section {
        bar < 8 ? .intro : bar < 32 ? .full : bar < 40 ? .breakdown : .full
    }
    private static func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    static func render(sampleRate: Int) -> [Float] {
        let sr = Double(sampleRate)
        let total = Int(duration * sr)
        var main = [Float](repeating: 0, count: total)
        var pad = [Float](repeating: 0, count: total)
        var bass = [Float](repeating: 0, count: total)
        var pluck = [Float](repeating: 0, count: total)
        var seed: UInt64 = 0x5EED_5EED

        /// 起音线性、之后指数衰减到 0.0001（同 WebAudio 的 linearRamp + exponentialRamp）；
        /// 衰减段逐样本乘常数，不每个样本调 pow（Debug 下快一个数量级，终审 I3）
        struct Envelope {
            let peak: Double, attackSamples: Int, ratio: Double
            var i = 0, value = 0.0
            init(peak: Double, attack: Double, decay: Double, sr: Double) {
                self.peak = peak
                attackSamples = max(1, Int(attack * sr))
                ratio = pow(0.0001 / peak, 1 / (decay * sr))
            }
            mutating func next() -> Double {
                defer { i += 1 }
                if i < attackSamples { value = peak * Double(i) / Double(attackSamples) }
                else if i == attackSamples { value = peak }
                else { value *= ratio }
                return value
            }
        }
        func triangle(_ phase: Double) -> Double { 1 - 4 * abs(phase - 0.5) }       // phase 0..<1
        func tone(into bus: inout [Float], at start: Double, freq: Double, peak: Double, attack: Double, decay: Double) {
            let first = Int(start * sr), count = Int((attack + decay + 0.05) * sr)
            var phase = 0.0
            var env = Envelope(peak: peak, attack: attack, decay: decay, sr: sr)
            for i in 0..<count where first + i < total {
                bus[first + i] += Float(triangle(phase) * env.next())
                phase += freq / sr
                if phase >= 1 { phase -= 1 }
            }
        }

        let steps = Int(duration / step)
        for s in 0..<steps {
            let t0 = Double(s) * step, bar = s / 16, k = s % 16, sec = section(bar), chord = chords[bar % 4]
            if k == 0 {                                                        // 铺底
                for n in chord { tone(into: &pad, at: t0, freq: hz(n), peak: sec == .breakdown ? 0.06 : 0.045, attack: 0.35, decay: 1.7) }
            }
            if sec == .full, k % 4 == 0 {                                       // 鼓：130 → 42 Hz 下滑
                let first = Int(t0 * sr), count = Int(0.3 * sr)
                var phase = 0.0, f = 130.0
                let sweep = pow(42.0 / 130, 1 / (0.14 * sr)), sweepEnd = Int(0.14 * sr)
                var env = Envelope(peak: 0.9, attack: 0.002, decay: 0.26, sr: sr)
                for i in 0..<count where first + i < total {
                    main[first + i] += Float(sin(2 * .pi * phase) * env.next())
                    phase += f / sr
                    if phase >= 1 { phase -= 1 }
                    if i < sweepEnd { f *= sweep }
                }
            }
            if sec != .breakdown, k % 4 == 2 {                                  // 镲：高通噪声
                let first = Int(t0 * sr), count = Int(0.1 * sr)
                let rc = 1 / (2 * Double.pi * 7200), a = rc / (rc + 1 / sr)
                var prevX = 0.0, y = 0.0
                var env = Envelope(peak: sec == .intro ? 0.06 : 0.12, attack: 0.001, decay: 0.05, sr: sr)
                for i in 0..<count where first + i < total {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let x = Double(seed >> 11) / Double(1 << 53) * 2 - 1
                    y = a * (y + x - prevX); prevX = x
                    main[first + i] += Float(y * env.next())
                }
            }
            if sec == .full, [0, 6, 8, 12].contains(k) {                        // 贝斯
                tone(into: &bass, at: t0, freq: hz(chord[0] - 24), peak: 0.32, attack: 0.005, decay: 0.22)
            }
            if sec != .intro, k % 2 == 0, (s * 7 + bar * 3) % 5 == 0 {          // 拨弦（只进回声）
                tone(into: &pluck, at: t0, freq: hz(chord[0] + 12 + melody[(s / 2 + bar) % melody.count]),
                     peak: 0.07, attack: 0.004, decay: 0.3)
            }
        }

        func lowpass(_ x: inout [Float], cutoff: Double) {
            let dt = 1 / sr, rc = 1 / (2 * Double.pi * cutoff), a = Float(dt / (rc + dt))
            var y: Float = 0
            for i in x.indices { y += a * (x[i] - y); x[i] = y }
        }
        lowpass(&pad, cutoff: 1400)
        lowpass(&bass, cutoff: 500)
        lowpass(&pluck, cutoff: 3000)

        // 回声：三个十六分音符延迟、反馈 0.32、出 0.35（干声不出，同小样）
        let delay = Int((3 * step * sr).rounded())
        var echo = [Float](repeating: 0, count: total)
        for i in delay..<total { echo[i] = pluck[i - delay] + 0.32 * echo[i - delay] }

        let drive: Float = 1.2, norm = tanh(drive)
        for i in 0..<total {                                                   // 就地混音，不另开数组
            let x = (main[i] + pad[i] + bass[i] + 0.35 * echo[i]) * 0.8
            main[i] = min(max(tanh(x * drive) / norm, -1), 1)                  // 软限幅
        }
        return main
    }
}

/// 16-bit PCM 单声道 WAV
enum WAV {
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func put(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        put("RIFF"); u32(36 + bytes); put("WAVE")
        put("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        put("data"); u32(bytes)
        let pcm = samples.map { Int16((min(max($0, -1), 1) * 32_767).rounded()).littleEndian }
        pcm.withUnsafeBufferPointer { data.append($0) }                       // 一次性写入（终审 I3）
        return data
    }
}

/// 内置曲落盘（缓存目录；首次播放时后台合成，之后直接用）。同一首同时只合成一份（终审 I2 / minor 5）
@MainActor
enum BuiltinMusic {
    nonisolated static let sampleRate = 32_000

    nonisolated static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryPalace/music", isDirectory: true)
    }

    nonisolated static func fileName(for track: BuiltinTrack) -> String {
        "\(track.rawValue)-v\(SlowTide.version).wav"
    }

    private static var inFlight: [URL: Task<URL?, Never>] = [:]
    private static var levelCache: [URL: [Float]] = [:]
    nonisolated static let levelsPerSecond = 60

    /// 整首的音量起伏（每秒 60 格 RMS，归一到 0...1）：波形跟着鼓点弹用（粟粟 09-26）
    nonisolated static func levels(fromWAV data: Data, perSecond: Int) -> [Float] {
        guard data.count > 44 else { return [] }
        let rate = data[24..<28].enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        let window = max(1, rate / perSecond)
        let pcm: [Int16] = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        var out: [Float] = []
        out.reserveCapacity(pcm.count / window + 1)
        var i = 0
        while i < pcm.count {
            let end = min(i + window, pcm.count)
            var sum: Float = 0
            for j in i..<end { let v = Float(Int16(littleEndian: pcm[j])) / 32_767; sum += v * v }
            out.append((sum / Float(end - i)).squareRoot())
            i = end
        }
        let peak = out.max() ?? 0
        return peak > 0 ? out.map { $0 / peak } : out
    }

    static func levels(forFile url: URL) async -> [Float]? {
        if let hit = levelCache[url] { return hit }
        let perSecond = levelsPerSecond
        let levels = await Task.detached(priority: .utility) { () -> [Float]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return BuiltinMusic.levels(fromWAV: data, perSecond: perSecond)
        }.value
        if let levels { levelCache[url] = levels }
        return levels
    }

    static func fileURL(for track: BuiltinTrack, directory: URL = cacheDirectory,
                        render: @escaping @Sendable (BuiltinTrack) -> [Float] = { track in
                            switch track {
                            case .slowTide: return SlowTide.render(sampleRate: BuiltinMusic.sampleRate)
                            }
                        }) async -> URL? {
        let url = directory.appendingPathComponent(fileName(for: track))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let running = inFlight[url] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { () -> URL? in
            let samples = render(track)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try WAV.encode(samples, sampleRate: sampleRate).write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }
}
