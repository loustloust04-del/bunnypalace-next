import Foundation
import AVFoundation
import SherpaOnnxC

// MARK: - [Bunny] 兔兔耳朵 · 本地工位（手机）
//
// 设计见 BunnyPalace-Next/audit/design-voice-ears.md：一副耳朵两个工位。本地用 CED-Tiny（int8，约 6 MB，随 App 打包），
// 经新兔已有的 sherpa-onnx（粟粟用于声纹）自带的 Audio Tagging C 接口运行，不加新依赖。
// 白名单 / 门槛 / 窗口与 hub 侧 bunny-ears 对齐；结果随录音交给 hub（send 帧 audio 项 local_ears）。
// 门槛可用 UserDefaults「bunny.ears.thresholds」（JSON：{"AudioSet 类名": 0.4}）覆盖，不用重编。
// 模型文件缺失（如上游原版工程未带资源）时安静返回空结果。

struct BunnyEarEvent: Codable, Hashable, Sendable {
    let label: String      // 中文
    let id: String         // AudioSet 类名
    let score: Double
    let times: Int
    var style: Bool = false
}

enum BunnyLocalEars {
    static let engine = "ced-tiny-int8@sherpa-onnx"

    /// AudioSet 类名 → (中文, 默认门槛, 是否「声音质感」类)。声音质感类的门槛取她本人日常语音的约 p90（10-28 校准）。
    static let whitelist: [String: (String, Double, Bool)] = [
        "Laughter": ("笑声", 0.30, false), "Giggle": ("咯咯笑", 0.30, false), "Chuckle, chortle": ("轻笑", 0.30, false),
        "Sigh": ("叹气", 0.35, false), "Gasp": ("倒吸气", 0.40, false), "Cough": ("咳嗽", 0.35, false),
        "Throat clearing": ("清嗓", 0.35, false), "Sneeze": ("喷嚏", 0.35, false), "Sniff": ("吸鼻子", 0.35, false),
        "Crying, sobbing": ("哭", 0.30, false), "Whimper": ("呜咽", 0.25, false), "Groan": ("呻吟", 0.30, false),
        "Snoring": ("打呼", 0.40, false),
        "Breathing": ("气声/呼吸声", 0.45, true), "Whispering": ("更像悄悄话", 0.73, true), "Humming": ("拖长音/哼唱感", 0.65, true),
        "Singing": ("唱歌", 0.30, false), "Music": ("音乐", 0.35, false),
        "Rain": ("雨声", 0.30, false), "Wind": ("风声", 0.35, false), "Thunder": ("雷声", 0.30, false),
        "Vehicle": ("车声", 0.35, false), "Traffic noise, roadway noise": ("车流声", 0.30, false), "Train": ("火车/地铁", 0.35, false),
        "Water tap, faucet": ("水龙头", 0.25, false), "Water": ("水声", 0.30, false), "Frying (food)": ("煎炒声", 0.30, false),
        "Dishes, pots, and pans": ("锅碗声", 0.30, false),
        "Dog": ("狗叫", 0.30, false), "Cat": ("猫叫", 0.30, false), "Purr": ("猫打呼噜", 0.08, false), "Bird": ("鸟叫", 0.30, false),
        "Television": ("电视声", 0.35, false), "Crowd": ("人群声", 0.35, false), "Typing": ("打字声", 0.35, false),
        "Door": ("关门声", 0.40, false), "Alarm": ("铃声/闹钟", 0.35, false), "Baby cry, infant cry": ("婴儿哭", 0.30, false),
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tagger: OpaquePointer?

    private static func threshold(_ id: String, _ fallback: Double) -> Double {
        guard let s = UserDefaults.standard.string(forKey: "bunny.ears.thresholds"),
              let d = s.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: d) as? [String: Double] else { return fallback }
        return map[id] ?? fallback
    }

    private static func makeTagger() -> OpaquePointer? {
        guard let model = Bundle.main.path(forResource: "bunny-ced-tiny.int8", ofType: "onnx"),
              let labels = Bundle.main.path(forResource: "bunny-ced-labels", ofType: "csv") else { return nil }
        let cModel = strdup(model), cLabels = strdup(labels), cProvider = strdup("cpu")
        defer { free(cModel); free(cLabels); free(cProvider) }
        var cfg = SherpaOnnxAudioTaggingConfig()
        cfg.model.ced = UnsafePointer(cModel)
        cfg.model.num_threads = 2
        cfg.model.debug = 0
        cfg.model.provider = UnsafePointer(cProvider)
        cfg.labels = UnsafePointer(cLabels)
        cfg.top_k = Int32(527)
        return SherpaOnnxCreateAudioTagging(&cfg)
    }

    /// 一段 16 kHz 单声道样本 → 全部类名的分数
    private static func scores(_ t: OpaquePointer, _ samples: ArraySlice<Float>) -> [String: Float] {
        guard let s = SherpaOnnxAudioTaggingCreateOfflineStream(t) else { return [:] }
        defer { SherpaOnnxDestroyOfflineStream(s) }
        let buf = Array(samples)
        buf.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(s, 16_000, $0.baseAddress, Int32($0.count)) }
        guard let res = SherpaOnnxAudioTaggingCompute(t, s, Int32(527)) else { return [:] }
        defer { SherpaOnnxAudioTaggingFreeResults(res) }
        var out: [String: Float] = [:]
        var i = 0
        while let p = res[i] {
            if let n = p.pointee.name { out[String(cString: n)] = p.pointee.prob }
            i += 1
        }
        return out
    }

    /// 读音频文件 → 16 kHz 单声道 Float（最多 120 秒）
    private static func load16k(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = file.processingFormat
        let frames = AVAudioFrameCount(min(file.length, AVAudioFramePosition(inFmt.sampleRate * 120)))
        guard frames > 0,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames) else { return nil }
        do { try file.read(into: inBuf, frameCount: frames) } catch { return nil }
        let outCap = AVAudioFrameCount(Double(frames) * 16_000 / inFmt.sampleRate) + 4_096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return nil }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true
            st.pointee = .haveData
            return inBuf
        }
        guard status != .error, let ch = outBuf.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }

    /// 分析一段音频文件（后台线程调用）；失败或没带模型时返回空数组
    static func analyze(url: URL) -> [BunnyEarEvent] {
        guard let a = load16k(url), a.count > 1_600 else { return [] }
        lock.lock(); defer { lock.unlock() }
        if tagger == nil { tagger = makeTagger() }
        guard let t = tagger else { return [] }

        // 整段：≤10 s 块（CED 位置编码上限约 10 s）、5 s 步长，逐类取最大
        let big = 160_000, bhop = 80_000
        var starts = a.count <= big ? [0] : Array(stride(from: 0, through: a.count - big, by: bhop))
        if a.count > big, starts.last != a.count - big { starts.append(a.count - big) }
        var best: [String: Float] = [:]
        for s0 in starts {
            for (k, v) in scores(t, a[s0..<min(s0 + big, a.count)]) where whitelist[k] != nil { best[k] = max(best[k] ?? 0, v) }
        }
        // 2 s 窗、1 s 步长：数「连续超门槛」出现了几段
        let win = 32_000, hop = 16_000
        let wstarts = a.count <= win ? [0] : Array(stride(from: 0, through: a.count - win, by: hop))
        var runs: [String: Int] = [:]
        var lastAbove: Set<String> = []
        for s0 in wstarts {
            let sc = scores(t, a[s0..<min(s0 + win, a.count)])
            var above: Set<String> = []
            for (k, entry) in whitelist {
                let v = sc[k] ?? 0
                best[k] = max(best[k] ?? 0, v)
                if Double(v) >= threshold(k, entry.1) { above.insert(k) }
            }
            for k in above where !lastAbove.contains(k) { runs[k, default: 0] += 1 }
            lastAbove = above
        }
        var out: [BunnyEarEvent] = []
        for (k, v) in best {
            guard let entry = whitelist[k], Double(v) >= threshold(k, entry.1) else { continue }
            out.append(BunnyEarEvent(label: entry.0, id: k, score: (Double(v) * 100).rounded() / 100,
                                     times: max(runs[k] ?? 1, 1), style: entry.2))
        }
        return out.sorted { $0.score > $1.score }
    }
}
