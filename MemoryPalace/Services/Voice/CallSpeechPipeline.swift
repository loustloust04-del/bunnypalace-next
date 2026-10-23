import Foundation
import Security

// MARK: - 通话朗读管线（plan-voice-providers V4b）
//
// CallSession 把 StreamSpeechGate 放出的句子交进来，这里决定怎么念：
// - 楼层服务能 `openStream` → 第一句来了才开流，每句 `send`，段落 / 回复结束 `finish`，PCM 边收边播
// - 不能 → 每句一个 `synthesize`，最多同时预取 `prefetchWindow` 句，按顺序播
// - 任一出错 → 这句和本轮后面的句子改系统音念，通话不断（下一轮重新试楼层服务）
// 每次挂断 `generation` +1，过期的合成结果 / 回调一律丢弃。

/// 播放端（真机是 `CallSpeaker`：AVAudioEngine 播 PCM、AVAudioPlayer 播整段、AVSpeechSynthesizer 念系统音；测试注 mock）
@MainActor
protocol CallAudioOutput: AnyObject {
    /// 流式 PCM 块：排进播放队列立刻返回；播放引擎起不来时抛错
    func schedulePCM(_ clip: AudioClip) throws
    /// 等已排的 PCM 全部播完（没有就立刻返回）
    func waitPCMDrained() async
    /// 整段（mp3 / wav）播完才返回
    func play(_ clip: AudioClip) async throws
    /// 系统音念完才返回
    func speakSystem(_ text: String, voice: String?) async
    /// 急停：清掉排着的 PCM、停掉正在播的
    func stop()
}

/// 管线对 CallSession 暴露的面
@MainActor
protocol CallSpeechSink: AnyObject {
    /// AI 这一轮开始（她的话发出去了、还没出字）：能预建连的流先建好
    func prepareTurn()
    func speak(_ sentence: String)
    /// 工具调用边界：流式会话收口（下一句来了再开新的）
    func endSegment()
    /// 本轮回复结束：播完后回调「空了」
    func endTurn()
    /// 挂断：全部丢弃
    func cancel()
}

/// 流式会话能「只建连 / 保活、不发字」就实现它（V0 探针：首包 1.1–1.4s 里建连占大头）：
/// 管线在 AI 这一轮开始时就开流并立刻 `keepAlive()`（建好连接、注册声音、不计费），之后每 10 秒一次直到收口。
/// 不实现的流：第一句来了才建连；10 秒没新字就 `finish`，下一句再开新流。
protocol VoiceStreamKeepAlive {
    func keepAlive() async throws
}

@MainActor
final class CallSpeechPipeline: CallSpeechSink {

    struct Route {
        /// nil = 直接系统音
        var synthesizer: (any VoiceSynthesizer)?
        var voice: String?
        var model: String?
        /// 系统音用哪个声音（AVSpeech identifier）
        var systemVoice: String?
        /// 错误信息去 key 用
        var serviceId: String?
        var effects: VoiceEffectConfiguration?
        var profileID: String?
        /// 本该用楼层语音服务、却回落成系统音的原因（给通话页小字 + 日志）；服务本身就是系统音时 nil
        var fallbackReason: String?
        var usesEffects: Bool { effects?.callActive == true && profileID != nil }

        static let system = Route()
    }

    static let prefetchWindow = 3

    var onPlaybackStarted: @MainActor () -> Void = {}
    var onUtterance: @MainActor (String) -> Void = { _ in }
    /// 播放器空了且本轮已结束
    var onIdle: @MainActor () -> Void = {}
    var streamIdleTimeout: Duration = .seconds(10)
    /// 预建的流一个字都没等到、闲够这么久就收口（CC 回复永远不来时别保活到挂断）；之后来字按冷启动开新流
    var prewarmLimit: Duration = .seconds(60)
    var tuning: () -> VoiceTuning.Settings = { VoiceTuning.current() }
    var effectLibrary: VoiceEffectLibrary = .shared
    /// 出错文字（已去 key）；默认打日志
    var reportError: (String) -> Void = { print("[CALL] 合成失败，转系统音：\($0)") }

    private let route: Route
    private let output: any CallAudioOutput
    private var generation = 0
    private var degraded = false
    private var errorReported = false
    private var turnEnded = true
    private var streamUnavailable = false
    private var queue: [Entry] = []
    private var playTask: Task<Void, Never>?
    private var openStreamEntry: StreamEntry?
    /// 跨句：上一句念完时开着的是哪一组垫底
    private var activeBed: String?

    init(route: Route, output: any CallAudioOutput) {
        self.route = route
        self.output = output
    }

    // MARK: - CallSpeechSink

    func prepareTurn() {
        beginTurnIfNeeded()
        guard !degraded, route.synthesizer != nil, openStreamEntry == nil else { return }
        guard let stream = currentStream() else {
            // 整段路线（音效 / 非流式模型）：没有流可预建，先把 HTTPS 连接建进池
            if !degraded { route.synthesizer?.prewarmConnection() }
            return
        }
        stream.prewarm(every: streamIdleTimeout, limit: prewarmLimit) { [weak self, weak stream] in
            guard let self, let stream, self.openStreamEntry === stream else { return }
            self.closeOpenStream()
        }
        pump()
    }

    private func beginTurnIfNeeded() {
        guard turnEnded else { return }
        turnEnded = false
        degraded = false
        errorReported = false
        activeBed = nil
    }

    func speak(_ sentence: String) {
        let text = (route.usesEffects ? sentence : VoiceEffectScript.textOnly(sentence)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        beginTurnIfNeeded()
        if route.usesEffects, !degraded, let effects = route.effects {
            let script = activeBed.map { "[sfx:\($0)]" + text } ?? text
            activeBed = VoiceEffectScript.bedState(after: text, starting: activeBed, configuration: effects)
            queue.append(.clip(ClipEntry(text: script)))
            startPrefetch()
            pump()
            return
        }
        if !degraded, route.synthesizer != nil, let stream = currentStream() {
            stream.append(text, keepAliveAfter: streamIdleTimeout) { [weak self, weak stream] in
                guard let self, let stream, self.openStreamEntry === stream else { return }
                self.closeOpenStream()
            }
        } else if degraded || route.synthesizer == nil {
            queue.append(.system(text))
        } else {
            queue.append(.clip(ClipEntry(text: text)))
            startPrefetch()
        }
        pump()
    }

    /// 工具边界：这段收口；回复还没完，下一段的流先预建好
    func endSegment() {
        closeOpenStream()
        guard !turnEnded else { return }
        prepareTurn()
    }

    func endTurn() {
        closeOpenStream()
        turnEnded = true
        pump()
    }

    func cancel() {
        generation += 1
        playTask?.cancel()
        playTask = nil
        for entry in queue { entry.abandon() }
        queue.removeAll()
        openStreamEntry = nil
        turnEnded = true
        degraded = false
        errorReported = false
        activeBed = nil
        output.stop()
    }

    // MARK: - 流式会话

    /// 开着的流已经出错 → 本轮降级（它自己没念的句子轮到它时转系统音），返回 nil
    private func currentStream() -> StreamEntry? {
        guard !route.usesEffects else { return nil }  // 音效需插片段 / 混音，显式开启后走整段队列
        if let open = openStreamEntry {
            if open.failure == nil { return open }
            openStreamEntry = nil
            degraded = true
            return nil
        }
        guard !streamUnavailable, let synth = route.synthesizer else { return nil }
        guard let stream = synth.openStream(voice: route.voice, model: route.model) else {
            streamUnavailable = true
            return nil
        }
        let entry = StreamEntry(stream: stream)
        openStreamEntry = entry
        queue.append(.stream(entry))
        return entry
    }

    private func closeOpenStream() {
        openStreamEntry?.close()
        openStreamEntry = nil
    }

    // MARK: - 播放循环

    private func pump() {
        guard playTask == nil else { return }
        let gen = generation
        playTask = Task { [weak self] in await self?.runQueue(gen) }
    }

    private func runQueue(_ gen: Int) async {
        while gen == generation, let entry = queue.first {
            startPrefetch()
            await play(entry, gen: gen)
            guard gen == generation else { return }
            queue.removeFirst()
        }
        guard gen == generation else { return }
        playTask = nil
        guard turnEnded else { return }
        await output.waitPCMDrained()
        guard gen == generation, turnEnded, queue.isEmpty, playTask == nil else { return }
        onIdle()
    }

    private func play(_ entry: Entry, gen: Int) async {
        switch entry {
        case .system(let text):
            await speakSystem(text, gen: gen)
        case .clip(let clip):
            let task = clip.task ?? startSynthesis(clip)
            let result = await task.result
            guard gen == generation else { return }
            switch result {
            case .success(let audio):
                await output.waitPCMDrained()
                guard gen == generation, !Task.isCancelled else { return }
                onUtterance(VoiceEffectScript.textOnly(clip.text))
                onPlaybackStarted()
                do {
                    try await output.play(audio)
                } catch {
                    guard gen == generation else { return }
                    degrade(error)
                    await speakSystem(clip.text, gen: gen)
                }
            case .failure(let error):
                if route.usesEffects, error is VoiceEffectError,
                   VoiceEffectScript.textOnly(clip.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                degrade(error)
                await speakSystem(clip.text, gen: gen)
            }
        case .stream(let stream):
            await playStream(stream, gen: gen)
        }
    }

    private func playStream(_ stream: StreamEntry, gen: Int) async {
        var started = false
        for await (clip, sentCount) in stream.audio {
            guard gen == generation else { return }
            if !started {
                started = true
                onPlaybackStarted()
            }
            onUtterance(stream.caption(sentCount: sentCount))
            do {
                if clip.format == .pcm16 {
                    try output.schedulePCM(clip)
                } else {
                    try await output.play(clip)
                }
            } catch {
                stream.fail(error)
                break
            }
        }
        guard gen == generation else { return }
        // 保守确认：一段只有正常收尾（拿到 is_final、chunks 正常结束）才算整段念完；
        // 中途断了没有逐句对齐，没法知道念到哪 → 这段的句子全部用系统音补念（宁可重一句，不丢）
        if let error = stream.failure, !(error is CancellationError) {
            degrade(error)
            for text in stream.texts {
                await speakSystem(text, gen: gen)
                guard gen == generation else { return }
            }
        }
    }

    /// 等已排 PCM 播完再开口；等的时候挂断了（代际变了 / 任务取消）就绝不开口
    private func speakSystem(_ text: String, gen: Int) async {
        let text = VoiceEffectScript.textOnly(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await output.waitPCMDrained()
        guard gen == generation, !Task.isCancelled else { return }
        onUtterance(text)
        onPlaybackStarted()
        await output.speakSystem(text, voice: route.systemVoice)
    }

    // MARK: - 预取

    private func startPrefetch() {
        var budget = Self.prefetchWindow
        for entry in queue {
            guard budget > 0 else { return }
            budget -= 1
            if case .clip(let clip) = entry, clip.task == nil { _ = startSynthesis(clip) }
        }
    }

    @discardableResult
    private func startSynthesis(_ clip: ClipEntry) -> Task<AudioClip, Error> {
        if let task = clip.task { return task }
        guard let synth = route.synthesizer else {
            let task = Task<AudioClip, Error> { throw VoiceSynthError.notSupported }
            clip.task = task
            return task
        }
        let voice = route.voice, model = route.model, settings = self.tuning(), text = clip.text
        let effects = route.effects, profileID = route.profileID, library = effectLibrary, useEffects = route.usesEffects
        let task = Task<AudioClip, Error> {
            if useEffects, let effects, let profileID {
                return try await VoiceEffectsRenderer.render(text, configuration: effects, profileID: profileID, library: library) { words, context in
                    try await synth.synthesize(text: words, voice: voice, model: model, tuning: settings, context: context)
                }
            }
            return try await synth.synthesize(text: text, voice: voice, model: model, tuning: settings)
        }
        clip.task = task
        return task
    }

    // MARK: - 降级

    /// 本轮剩下的句子全改系统音
    private func degrade(_ error: Error) {
        if !errorReported {
            errorReported = true
            if (error as? VoiceSynthError) == .missingKey {
                // 区分「真没填」和「钥匙串读不到」（锁屏 -25308）
                let account = route.serviceId.map(VoiceServiceStore.keychainAccount(for:)) ?? VoiceTuning.keychainAccount
                let status = KeychainStore.readStatus(account: account)
                reportError(status == errSecSuccess || status == errSecItemNotFound ? VoiceSynthError.missingKey.message
                            : "读不到语音 key（钥匙串 \(status)\(status == errSecInteractionNotAllowed ? "，手机锁着" : "")）")
            } else {
                reportError(VoiceServiceStore.shared.errorMessage(error, serviceId: route.serviceId))
            }
        }
        degraded = true
        closeOpenStream()
        for i in queue.indices.dropFirst() {
            if case .clip(let clip) = queue[i] {
                clip.task?.cancel()
                queue[i] = .system(clip.text)
            }
        }
    }

    // MARK: - 条目

    private enum Entry {
        case system(String)
        case clip(ClipEntry)
        case stream(StreamEntry)

        @MainActor func abandon() {
            switch self {
            case .system: break
            case .clip(let clip): clip.task?.cancel()
            case .stream(let stream): stream.fail(CancellationError())
            }
        }
    }

    private final class ClipEntry {
        let text: String
        var task: Task<AudioClip, Error>?
        init(text: String) { self.text = text }
    }

    /// 一条流式会话：串行发字（send / finish 按顺序），音频块先进自己的缓冲，轮到它时播
    @MainActor
    private final class StreamEntry {
        let stream: any VoiceStream
        /// 音频块 + 收到它时已发出的句子数
        let audio: AsyncStream<(AudioClip, Int)>
        private let audioContinuation: AsyncStream<(AudioClip, Int)>.Continuation
        private(set) var texts: [String] = []
        private(set) var failure: Error?
        private var sendChain: Task<Void, Never>?
        private var idleTask: Task<Void, Never>?
        private var consumer: Task<Void, Never>?
        private var watchdog: Task<Void, Never>?
        private var closed = false
        private var ended = false
        private var lastActivity = Date()
        /// 收口后这么久没新音频也没结束 → 当它断了（防流卡死、麦永远不开）
        static let stallTimeout: TimeInterval = 15

        init(stream: any VoiceStream) {
            self.stream = stream
            let (audio, continuation) = AsyncStream<(AudioClip, Int)>.makeStream()
            self.audio = audio
            self.audioContinuation = continuation
            consumer = Task { [weak self] in
                do {
                    for try await clip in stream.chunks {
                        guard let self else { return }
                        self.lastActivity = Date()
                        self.audioContinuation.yield((clip, self.texts.count))
                    }
                } catch {
                    self?.fail(error)
                }
                self?.ended = true
                self?.watchdog?.cancel()
                self?.audioContinuation.finish()
            }
        }

        /// 字幕：收到这块时已入队的最后两句（没有逐字对齐，只是显示用；补念不靠它）
        func caption(sentCount: Int) -> String { texts.prefix(sentCount).suffix(2).joined() }

        func append(_ text: String, keepAliveAfter: Duration, onIdle: @escaping @MainActor () -> Void) {
            guard !closed, failure == nil else { return }
            texts.append(text)
            lastActivity = Date()
            enqueue { try await $0.send(text) }
            // 第一句可能不够厂商攒批的字数（ElevenLabs 约 40 字才出声），强制出声换首包延迟
            if texts.count == 1 { enqueue { try await $0.flush() } }
            armIdle(after: keepAliveAfter, onIdle: onIdle)
        }

        /// 预建连：能保活的流立刻 keepAlive（建连）并每 `interval` 一次；不能的什么都不做（第一句来了才建连）。
        /// 一个字都没来、闲够 `limit` → onIdle（管线收口）；`append` 过字就换回普通保活
        func prewarm(every interval: Duration, limit: Duration, onIdle: @escaping @MainActor () -> Void) {
            guard !closed, failure == nil, let keepAlive = stream as? VoiceStreamKeepAlive else { return }
            enqueue { _ in try await keepAlive.keepAlive() }
            armIdle(after: interval, limit: limit, onIdle: onIdle)
        }

        /// 闲 `after` 没新字：能保活就 keepAlive 并继续等，不能就 onIdle（管线收口）；
        /// 给了 `limit`（预热期）：到点还没字也 onIdle
        private func armIdle(after keepAliveAfter: Duration, limit: Duration? = nil,
                             onIdle: @escaping @MainActor () -> Void) {
            idleTask?.cancel()
            let stream = self.stream
            let deadline = limit.map { ContinuousClock.now + $0 }
            idleTask = Task { [weak self] in
                while true {
                    let step = deadline.map { max(.zero, min(keepAliveAfter, ContinuousClock.now.duration(to: $0))) } ?? keepAliveAfter
                    try? await Task.sleep(for: step)
                    guard !Task.isCancelled, let self, !self.closed else { return }
                    if let deadline, ContinuousClock.now >= deadline, self.texts.isEmpty {
                        onIdle()
                        return
                    }
                    guard let keepAlive = stream as? VoiceStreamKeepAlive else {
                        onIdle()
                        return
                    }
                    self.enqueue { _ in try await keepAlive.keepAlive() }
                }
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            idleTask?.cancel()
            lastActivity = Date()
            enqueue { try await $0.finish() }
            watchdog = Task { [weak self] in
                while true {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, self.failure == nil, !self.ended else { return }
                    if Date().timeIntervalSince(self.lastActivity) > Self.stallTimeout {
                        self.fail(VoiceSynthError.network)
                        return
                    }
                }
            }
        }

        func fail(_ error: Error) {
            guard failure == nil else { return }
            failure = error
            closed = true
            idleTask?.cancel()
            watchdog?.cancel()
            stream.cancel()
            consumer?.cancel()
            audioContinuation.finish()
        }

        private func enqueue(_ op: @escaping @MainActor (any VoiceStream) async throws -> Void) {
            let previous = sendChain
            let stream = self.stream
            sendChain = Task { [weak self] in
                await previous?.value
                guard let self, self.failure == nil else { return }
                do { try await op(stream) } catch { self.fail(error) }
            }
        }
    }
}

// MARK: - 楼层 → 路由

extension CallSpeechPipeline.Route {
    /// 楼层选了语音服务就用它（通话模型）；没迁移过的老楼层回退老 `elevenVoiceId` + 老 key；都没有走系统音
    @MainActor
    static func resolve(profile: Profile?, store: VoiceServiceStore = .shared,
                        legacyKey: @escaping () -> String? = { KeychainStore.get(account: VoiceTuning.keychainAccount) },
                        legacyKeyStatus: () -> OSStatus = { KeychainStore.readStatus(account: VoiceTuning.keychainAccount) }) -> Self {
        guard let profile else {
            var route = Self.system
            route.fallbackReason = "没找到楼层"
            return route
        }
        var route: Self
        if let service = store.service(id: profile.voiceServiceId), !service.kind.isUnknown {
            if service.kind == .system {
                route = Self(systemVoice: profile.voiceId)
            } else {
                let synth = service.makeSynthesizer(store: store)
                route = Self(synthesizer: synth, voice: profile.voiceId,
                             model: synth.capabilities.resolvedModel(profile.callModel), serviceId: service.id)
            }
        } else if let legacyVoice = profile.elevenVoiceId, !legacyVoice.isEmpty, !(legacyKey() ?? "").isEmpty {
            route = Self(synthesizer: LegacyElevenLabsCallSynthesizer(keyProvider: legacyKey), voice: legacyVoice)
        } else {
            route = .system
            if !(profile.voiceServiceId ?? "").isEmpty {
                route.fallbackReason = "语音服务已删或不认识"
            } else if !(profile.elevenVoiceId ?? "").isEmpty {
                let status = legacyKeyStatus()
                route.fallbackReason = status == errSecSuccess || status == errSecItemNotFound
                    ? "老楼层的 ElevenLabs key 没填" : "老楼层的 ElevenLabs key 读不到（钥匙串 \(status)）"
            } else {
                route.fallbackReason = "楼层没挂语音服务"
            }
        }
        route.effects = profile.voiceEffects
        route.profileID = profile.id
        if route.usesEffects, route.synthesizer == nil { route.synthesizer = SystemSynthesizer(); route.voice = route.systemVoice }
        return route
    }
}

/// 老楼层（没挂语音服务）的通话合成：老 key + v3 TTS 接口，跟原 CallSpeaker 同一条路
struct LegacyElevenLabsCallSynthesizer: VoiceSynthesizer {
    let keyProvider: () -> String?
    var client = ElevenLabsClient()

    var capabilities: VoiceCapabilities { VoiceCapabilities(supportsTags: true) }

    func synthesize(text: String, voice: String?, model: String?, tuning: VoiceTuning.Settings) async throws -> AudioClip {
        guard let key = keyProvider(), !key.isEmpty else { throw VoiceSynthError.missingKey }
        guard let voice, !voice.isEmpty else { throw VoiceSynthError.missingVoice }
        let data = try await client.synthesize(script: text, voiceId: voice, apiKey: key, settings: tuning)
        return AudioClip(data: data, format: .mp3, sampleRate: 44_100)
    }
}
