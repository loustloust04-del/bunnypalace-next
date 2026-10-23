import Foundation

// MARK: - 合成协议（plan-voice-providers V1b）
//
// 每家厂商一个文件实现 `VoiceSynthesizer`；工厂 `VoiceService.makeSynthesizer()` 是唯一按厂商分流的地方。

enum AudioFormat: String, Codable, Sendable {
    case mp3
    case wav
    /// 16-bit little-endian PCM（裸数据，需要 sampleRate）
    case pcm16
}

struct AudioClip: Equatable, Sendable {
    var data: Data
    var format: AudioFormat
    var sampleRate: Int?
    var channels: Int = 1

    /// AVAudioPlayer 能直接吃的数据：pcm16 包一层 WAV 头，其余原样
    var playableData: Data {
        guard format == .pcm16 else { return data }
        return Self.wavWrapped(pcm16: data, sampleRate: sampleRate ?? 24_000, channels: channels)
    }

    static func wavWrapped(pcm16: Data, sampleRate: Int, channels: Int) -> Data {
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        let byteRate = sampleRate * channels * 2
        var out = Data("RIFF".utf8)
        out += le32(36 + pcm16.count)
        out += Data("WAVEfmt ".utf8)
        out += le32(16) + le16(1) + le16(channels) + le32(sampleRate) + le32(byteRate) + le16(channels * 2) + le16(16)
        out += Data("data".utf8)
        out += le32(pcm16.count)
        out += pcm16
        return out
    }
}

/// 声音列表项（各家 voice 的统一外形）
struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    var previewURL: URL? = nil
    /// 小字补充（语言、性别、标签…）
    var detail: String? = nil
}

/// 设置页能调的参数
enum VoiceTunable: String, CaseIterable {
    case stability
    case similarity
    case style
    case speed
}

struct VoiceModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    /// nil = 跟服务级 `tunables`
    var tunables: [VoiceTunable]? = nil
    /// 这个模型能边收边播
    var streaming: Bool = false
}

struct VoiceCapabilities: Equatable {
    /// 认方括号表演标签（决定语音条提示词文案）
    var supportsTags = false
    /// 有 `openStream`
    var supportsStreaming = false
    /// 有 `fetchVoices`；false 时设置页让手填声音 id
    var canFetchVoices = false
    var tunables: [VoiceTunable] = []
    /// 可选模型（第一个是默认）；空 = 没有模型可选
    var models: [VoiceModelOption] = []

    func tunables(for modelId: String?) -> [VoiceTunable] {
        models.first { $0.id == modelId }?.tunables ?? tunables
    }

    /// 楼层存的模型不在列表里（厂商下线 / 换了服务）时回落默认
    func resolvedModel(_ modelId: String?) -> String? {
        if let modelId, models.contains(where: { $0.id == modelId }) { return modelId }
        return models.first?.id
    }
}

enum VoiceSynthError: Error, Equatable {
    case notSupported
    case missingKey
    case missingVoice
    case invalidKey
    case quotaOrRateLimited
    case server(Int, String?)
    case network
    case badAudio
    /// 文字超过这家单次请求上限（字数）
    case textTooLong(Int)

    var message: String {
        switch self {
        case .notSupported: "这个服务不支持该操作"
        case .missingKey: "没填 key"
        case .missingVoice: "没选声音"
        case .invalidKey: "key 无效"
        case .quotaOrRateLimited: "额度不够或请求太频繁"
        case .server(let code, let detail): detail.map { "服务端出错 \(code)：\($0)" } ?? "服务端出错 \(code)"
        case .network: "网络不行"
        case .badAudio: "没拿到能播的音频"
        case .textTooLong(let limit): "文字太长，这个服务一次最多 \(limit) 字"
        }
    }
}

/// 分段合成时前后段的台词（已去音效标记），给厂商接住语气；目前只有 ElevenLabs 用
struct VoiceSynthesisContext: Equatable, Sendable {
    var previous: String?
    var next: String?
}

protocol VoiceSynthesizer {
    var capabilities: VoiceCapabilities { get }
    /// 整段合成。voice / model 为 nil 时用厂商默认（能用的话）
    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip
    /// 带前后文的分段合成；不认上下文的厂商走默认实现（忽略 context）
    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings,
                    context: VoiceSynthesisContext?) async throws -> AudioClip
    func fetchVoices() async throws -> [VoiceOption]
    /// 能边收边播才返回；调用方拿到 nil 就走「分句 + synthesize」
    func openStream(voice: String?, model: String?) -> (any VoiceStream)?
    /// 整段路线的预连接：只把 DNS / TCP / TLS 走一遍让连接进池，不带 key、不计费、结果丢弃。默认什么都不做
    func prewarmConnection()
}

extension VoiceSynthesizer {
    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings,
                    context: VoiceSynthesisContext?) async throws -> AudioClip {
        try await synthesize(text: text, voice: voice, model: model, tuning: tuning)
    }
    func fetchVoices() async throws -> [VoiceOption] { throw VoiceSynthError.notSupported }
    func openStream(voice: String?, model: String?) -> (any VoiceStream)? { nil }
    func prewarmConnection() {}
}

/// 流式合成会话：一句一句推文字，音频块从 `chunks` 出来
protocol VoiceStream: AnyObject {
    var chunks: AsyncThrowingStream<AudioClip, Error> { get }
    func send(_ text: String) async throws
    /// 让已推的文字立刻出声（不关会话）
    func flush() async throws
    /// 推完了：等剩余音频出完后 `chunks` 结束
    func finish() async throws
    func cancel()
}

// MARK: - 工厂

extension VoiceService {
    func makeSynthesizer(store: VoiceServiceStore = .shared) -> any VoiceSynthesizer {
        let keyProvider: () -> String? = { [id] in store.key(for: id) }
        switch kind {
        case .system:
            return SystemSynthesizer()
        case .elevenLabs:
            return ElevenLabsSynthesizer(keyProvider: keyProvider)
        case .openAICompatible:
            return OpenAICompatibleSynthesizer(service: self, keyProvider: keyProvider)
        case .miniMax:
            return MiniMaxSynthesizer(service: self, keyProvider: keyProvider)
        case .unknown:
            return UnsupportedVoiceSynthesizer()
        }
    }
}

/// 不认识的厂商（新版本写的配置被旧版读到）：什么都不支持
struct UnsupportedVoiceSynthesizer: VoiceSynthesizer {
    var capabilities: VoiceCapabilities { VoiceCapabilities() }

    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip {
        throw VoiceSynthError.notSupported
    }
}
