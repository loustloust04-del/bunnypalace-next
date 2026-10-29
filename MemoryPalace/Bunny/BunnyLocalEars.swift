import Foundation
import AVFoundation
import SoundAnalysis

// MARK: - [Bunny] 兔兔耳朵 · 本地工位（手机）
//
// 设计见 BunnyPalace-Next/audit/design-voice-ears.md：一副耳朵两个工位，白名单 / 门槛 / 输出格式与 hub 侧
// bunny-ears 对齐。本地先用苹果系统自带的声音分类器（SNClassifySoundRequest .version1，零下载），
// 结果随录音一起交给 hub（send 帧 audio 项的 local_ears 字段），影子期与 hub 双耳对比后再定门槛或换 CED。
// 门槛可用 UserDefaults「bunny.ears.thresholds」（JSON：{"苹果类名": 0.4}）覆盖，不用重编。

struct BunnyEarEvent: Codable, Hashable, Sendable {
    let label: String      // 中文
    let id: String         // 苹果分类器类名
    let score: Double      // 最高置信度
    let times: Int         // 连续超门槛的段数
    var style: Bool = false
}

enum BunnyLocalEars {
    /// 苹果类名 → (中文, 默认门槛, 是否「声音质感」类)。不在本机分类器里的类名会被自动忽略。
    static let whitelist: [String: (String, Double, Bool)] = [
        "laughter": ("笑声", 0.35, false), "giggling": ("咯咯笑", 0.35, false), "chuckle_chortle": ("轻笑", 0.35, false),
        "sigh": ("叹气", 0.35, false), "gasp": ("倒吸气", 0.40, false), "cough": ("咳嗽", 0.35, false),
        "throat_clearing": ("清嗓", 0.35, false), "sneeze": ("喷嚏", 0.35, false), "sniff": ("吸鼻子", 0.35, false),
        "crying_sobbing": ("哭", 0.30, false), "whimper": ("呜咽", 0.30, false), "snoring": ("打呼", 0.40, false),
        "yawn": ("哈欠", 0.35, false),
        "breathing": ("气声/呼吸声", 0.70, true), "whispering": ("更像悄悄话", 0.70, true), "humming": ("哼唱", 0.70, true),
        "singing": ("唱歌", 0.40, false), "music": ("音乐", 0.40, false),
        "rain": ("雨声", 0.30, false), "wind": ("风声", 0.35, false), "thunder": ("雷声", 0.30, false),
        "car_passing_by": ("车声", 0.35, false), "traffic_noise": ("车流声", 0.30, false), "train": ("火车/地铁", 0.35, false),
        "water_tap_faucet": ("水龙头", 0.30, false), "water": ("水声", 0.35, false), "frying_food": ("煎炒声", 0.30, false),
        "dishes_pots_pans": ("锅碗声", 0.30, false),
        "dog": ("狗叫", 0.35, false), "dog_bark": ("狗叫", 0.35, false), "cat": ("猫叫", 0.35, false),
        "cat_meow": ("猫叫", 0.35, false), "cat_purr": ("猫打呼噜", 0.20, false), "bird": ("鸟叫", 0.35, false),
        "television": ("电视声", 0.40, false), "crowd": ("人群声", 0.40, false), "typing": ("打字声", 0.40, false),
        "door_slam": ("关门声", 0.40, false), "alarm_clock": ("闹钟", 0.40, false), "baby_crying": ("婴儿哭", 0.30, false),
    ]

    private static func threshold(_ id: String, _ fallback: Double) -> Double {
        guard let s = UserDefaults.standard.string(forKey: "bunny.ears.thresholds"),
              let d = s.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: d) as? [String: Double] else { return fallback }
        return map[id] ?? fallback
    }

    /// 分析一段音频文件（后台线程调用）；失败返回空数组
    static func analyze(url: URL) -> [BunnyEarEvent] {
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        guard let analyzer = try? SNAudioFileAnalyzer(url: url) else { return [] }
        let observer = Collector()
        do { try analyzer.add(request, withObserver: observer) } catch { return [] }
        analyzer.analyze()   // 同步跑完
        return observer.events()
    }

    private final class Collector: NSObject, SNResultsObserving {
        private let lock = NSLock()
        private var best: [String: Double] = [:]
        private var runs: [String: Int] = [:]
        private var lastAbove: Set<String> = []

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            lock.lock(); defer { lock.unlock() }
            var above: Set<String> = []
            for c in r.classifications {
                guard let entry = BunnyLocalEars.whitelist[c.identifier] else { continue }
                best[c.identifier] = max(best[c.identifier] ?? 0, c.confidence)
                if c.confidence >= BunnyLocalEars.threshold(c.identifier, entry.1) { above.insert(c.identifier) }
            }
            for id in above where !lastAbove.contains(id) { runs[id, default: 0] += 1 }
            lastAbove = above
        }

        func events() -> [BunnyEarEvent] {
            lock.lock(); defer { lock.unlock() }
            var out: [BunnyEarEvent] = []
            for (id, score) in best {
                guard let entry = BunnyLocalEars.whitelist[id], score >= BunnyLocalEars.threshold(id, entry.1) else { continue }
                out.append(BunnyEarEvent(label: entry.0, id: id, score: (score * 100).rounded() / 100,
                                         times: max(runs[id] ?? 1, 1), style: entry.2))
            }
            return out.sorted { $0.score > $1.score }
        }
    }
}
