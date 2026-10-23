import Foundation
import SwiftData
import AVFoundation

/// 发语音条：```voice 意向协议（零新窄工具，模式同 AgentBookNoteWriter 的 ```book-note）。
///
/// AI 在回复里输出 ```voice 块（内容 = 表演脚本，≠ 气泡正文），turn 收口时本类把块
/// 变成占位行、异步走楼层语音服务（`voiceServiceId + voiceId + messageModel`）合成、落文件库、往 node 挂 .audioRef segment。
/// 失败时占位行替换成灰字失败行（脚本原文保住）。流式期间块可见 = 「TA 在录语音」。
enum VoiceMessageWriter {

    static let placeholderLine = "🎤 语音条生成中…"
    /// 脚本长度上限（攻略纪律 60–120 字；超长截断防误写整篇）
    static let scriptCap = 1000

    private static let intentRegex = try! NSRegularExpression(
        pattern: "```voice\\s*\\n([\\s\\S]*?)```",
        options: []
    )

    // 测试注入点
    static var proactiveEnabledProvider: () -> Bool = { UserDefaults.standard.bool(forKey: VoiceTuning.proactiveKey) }
    /// 无 ProfileManager 引用的调用点（CC 主动消息 / 换一版）用；测试注入假楼层防污染真 UserDefaults
    static var profilesProvider: () -> [Profile] = { ProfileManager.loadProfiles() }
    /// 楼层 `voiceServiceId` → 服务配置
    static var serviceProvider: (String) -> VoiceService? = { VoiceServiceStore.shared.service(id: $0) }
    /// 服务的 key（钥匙串 `voice.<id>`）
    static var serviceKeyProvider: (String) -> String? = { VoiceServiceStore.shared.key(for: $0) }
    /// 服务 → 合成器（测试注入假合成器）
    static var synthesizerProvider: (VoiceService) -> any VoiceSynthesizer = { $0.makeSynthesizer() }

    /// 楼层发语音条用的那一套：服务 + 合成器 + 声音 + 语音条模型
    struct VoiceSetup {
        let service: VoiceService
        let synthesizer: any VoiceSynthesizer
        let voiceId: String
        let model: String?
        let profileID: String
        let effects: VoiceEffectConfiguration
    }

    /// 楼层能发语音条吗：有服务（认得的厂商）+ 要 key 的服务有 key（系统音不要）+ 选了声音。不看主动开关。
    static func voiceSetup(for profile: Profile?) -> VoiceSetup? {
        guard let profile,
              let serviceId = profile.voiceServiceId,
              let service = serviceProvider(serviceId), !service.kind.isUnknown,
              let voiceId = profile.voiceId?.trimmingCharacters(in: .whitespacesAndNewlines), !voiceId.isEmpty else { return nil }
        if service.kind.needsKey, (serviceKeyProvider(service.id) ?? "").isEmpty { return nil }
        let synth = synthesizerProvider(service)
        return VoiceSetup(service: service, synthesizer: synth, voiceId: voiceId,
                          model: synth.capabilities.resolvedModel(profile.messageModel),
                          profileID: profile.id, effects: profile.voiceEffects ?? VoiceEffectConfiguration())
    }

    /// 生成中的 node（占位/换一版共用，防重入）
    @MainActor static private(set) var inFlight = Set<String>()

    // MARK: - 收口入口

    /// assistant turn 收口时调（ContentView .assistantTurnDidFinish 订阅者）。
    /// 无块零成本；块被消费后不再匹配 = 天然幂等。
    @MainActor
    static func processChatIntents(nodeId: String, context: ModelContext, profiles: [Profile]) {
        // 语音通话中语音条整套让路（通话已用实时朗读覆盖；兜住 AI 无视 prompt 仍发 ```voice 的情况）
        if CallSession.activeSnapshot { return }
        let nodeDesc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        guard let node = (try? context.fetch(nodeDesc))?.first,
              node.role == "assistant" else { return }

        // 块可能在两个容器：content（普通消息）和 segments 的 .text 段（工具轮/segmented 消息
        // 正文副本——只消费 content 会让 segmented 渲染把残留块画成代码卡片，07-12 粟粟截图实锤）
        let segs = node.segments
        let blockInContent = node.content.contains("```voice")
        let blockInSegments = segs?.contains(where: {
            if case .text(let s) = $0 { return s.contains("```voice") }
            return false
        }) ?? false
        guard blockInContent || blockInSegments else { return }

        let script = firstScript(content: node.content, segments: segs) ?? ""
        let profile = profiles.first { $0.id == node.profileId }
        let setup = voiceSetup(for: profile)
        let canGenerate = proactiveEnabledProvider() && setup != nil && !script.isEmpty

        // 两容器同步消费（首块 → 占位/降级；多余块 → 脚本文字）
        node.content = consumeVoiceBlocks(in: node.content, canGenerate: canGenerate)
        if var segs, blockInSegments {
            for i in segs.indices {
                if case .text(let s) = segs[i], s.contains("```voice") {
                    segs[i] = .text(consumeVoiceBlocks(in: s, canGenerate: canGenerate))
                }
            }
            node.setSegments(segs)
        }
        try? context.save()

        guard canGenerate, let setup else { return }
        generate(script: script, nodeId: nodeId, setup: setup,
                 speaker: profile?.assistantName, voiceName: profile?.voiceName, context: context)
    }

    /// 首块脚本：content 优先，没有再扫 segments 的 .text（segmented 消息两容器是同一文本的两份副本）
    private static func firstScript(content: String, segments: [MessageSegment]?) -> String? {
        var candidates = [content]
        for seg in segments ?? [] {
            if case .text(let s) = seg { candidates.append(s) }
        }
        for text in candidates {
            let ns = text as NSString
            if let m = intentRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return String(ns.substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(scriptCap))
            }
        }
        return nil
    }

    /// 对一段文本消费全部 voice 块：首块 → 占位行（可生成）/脚本文字（降级）；多余块 → 脚本文字
    private static func consumeVoiceBlocks(in text: String, canGenerate: Bool) -> String {
        let ns = text as NSString
        let matches = intentRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var newText = text
        for (idx, m) in Array(matches.enumerated()).reversed() {
            let body = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = (idx == 0 && canGenerate) ? placeholderLine : body
            newText = (newText as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return newText
    }

    // MARK: - 换一版

    /// 语音条胶囊菜单「换一版」：拿 segment 里存的脚本重跑合成，原地换文件。
    @MainActor
    static func regenerate(nodeId: String, context: ModelContext) {
        guard !inFlight.contains(nodeId),
              let node = fetchNode(nodeId, context: context),
              let segs = node.segments,
              let audioIdx = segs.firstIndex(where: {
                  if case .audioRef = $0 { return true } else { return false }
              }),
              case .audioRef(_, _, let oldPath, _, let script?) = segs[audioIdx],
              !script.isEmpty else {
            ToastCenter.shared.show("换不了：脚本不在")
            return
        }
        // 服务 / 声音用 node 所在楼层当前配置（楼层可能换过声音——换一版跟新声音走）
        guard let profile = profilesProvider().first(where: { $0.id == node.profileId }),
              let setup = voiceSetup(for: profile) else {
            ToastCenter.shared.show("换不了：这个楼层的语音服务或声音没配好")
            return
        }

        inFlight.insert(nodeId)
        ToastCenter.shared.show("正在换一版…")
        Task { @MainActor in
            defer { inFlight.remove(nodeId) }
            do {
                let clip = try await synthesize(script, setup: setup)
                guard let node = fetchNode(nodeId, context: context), var segs = node.segments else { return }
                let (path, duration, mime) = try persistAudio(clip, node: node, context: context)
                // 旧的那条还在放 / 暂停着就停掉（终审 I-3），再删旧文件（失败不阻断——孤儿文件无害）
                VoiceMessagePlayer.shared.stop(id: oldPath)
                if let old = FileLibraryStore.absoluteURL(oldPath, profileId: node.profileId) {
                    try? FileManager.default.removeItem(at: old)
                }
                if let idx = segs.firstIndex(where: {
                    if case .audioRef = $0 { return true } else { return false }
                }) {
                    segs[idx] = .audioRef(
                        name: (path as NSString).lastPathComponent, mime: mime,
                        path: path, duration: duration, script: script
                    )
                    node.setSegments(segs)
                    try? context.save()
                    ToastCenter.shared.show("换好了")
                    reportVoiceNote(script: script, speaker: profile.assistantName,
                                    voiceName: profile.voiceName, duration: duration)
                }
            } catch {
                ToastCenter.shared.show("换一版没成功（\(shortPhrase(error, setup: setup))）")
            }
        }
    }

    // MARK: - 生成

    @MainActor
    private static func generate(script: String, nodeId: String, setup: VoiceSetup,
                                 speaker: String?, voiceName: String?, context: ModelContext) {
        guard !inFlight.contains(nodeId) else { return }
        inFlight.insert(nodeId)
        Task { @MainActor in
            defer { inFlight.remove(nodeId) }
            do {
                let clip = try await synthesize(script, setup: setup)
                // 收尾时 node 可能已被删/换楼层——fetch 不到就静默放弃（孤儿音频不落盘）
                guard let node = fetchNode(nodeId, context: context) else { return }
                let (path, duration, mime) = try persistAudio(clip, node: node, context: context)
                var segs = node.segments ?? []
                segs.append(.audioRef(
                    name: (path as NSString).lastPathComponent, mime: mime,
                    path: path, duration: duration, script: script
                ))
                node.setSegments(segs)
                removePlaceholderEverywhere(from: node)
                try? context.save()
                reportVoiceNote(script: script, speaker: speaker, voiceName: voiceName, duration: duration)
            } catch {
                guard let node = fetchNode(nodeId, context: context) else { return }
                let quoted = script.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
                let failLine = "> 🎤 语音条没成功（\(shortPhrase(error, setup: setup))）\n\(quoted)"
                replaceEverywhere(in: node, of: placeholderLine, with: failLine)
                try? context.save()
            }
        }
    }

    private static func synthesize(_ script: String, setup: VoiceSetup) async throws -> AudioClip {
        try await VoiceEffectsRenderer.render(script, configuration: setup.effects, profileID: setup.profileID) { text, context in
            try await setup.synthesizer.synthesize(text: text, voice: setup.voiceId, model: setup.model,
                                                  tuning: VoiceTuning.current(), context: context)
        }
    }

    /// 落盘用的 (数据, 扩展名, mime)：mp3 原样；wav 原样；裸 PCM 包成 wav
    static func fileInfo(for clip: AudioClip) -> (data: Data, ext: String, mime: String) {
        switch clip.format {
        case .mp3: (clip.data, "mp3", "audio/mpeg")
        case .wav: (clip.data, "wav", "audio/wav")
        case .pcm16: (clip.playableData, "wav", "audio/wav")
        }
    }

    /// 音频落文件库（attachments/{对话目录}/voice-*.mp3|wav），返回 (相对路径, 时长, mime)
    private static func persistAudio(_ clip: AudioClip, node: MessageNode, context: ModelContext) throws -> (String, Double?, String) {
        let stamp = Self.fileStampFormatter.string(from: Date())
        let file = fileInfo(for: clip)
        let path = try AttachmentStore.save(
            fileName: "voice-\(stamp).\(file.ext)", data: file.data,
            conversationId: node.conversationId,
            conversationTitle: conversationTitle(node: node, context: context),
            profileId: node.profileId
        )
        let duration: Double? = MainThreadIO.tolerated("#033 语音条落盘后主线程读时长") {
            guard let url = FileLibraryStore.absoluteURL(path, profileId: node.profileId),
                  let player = try? AVAudioPlayer(contentsOf: url),
                  player.duration.isFinite, player.duration > 0 else { return nil }
            return player.duration
        }
        return (path, duration, file.mime)
    }

    @MainActor
    private static func removePlaceholderEverywhere(from node: MessageNode) {
        node.content = strippingPlaceholder(node.content)
        if var segs = node.segments {
            var changed = false
            for i in segs.indices {
                if case .text(let s) = segs[i], s.contains(placeholderLine) {
                    segs[i] = .text(strippingPlaceholder(s))
                    changed = true
                }
            }
            if changed { node.setSegments(segs) }
        }
    }

    private static func strippingPlaceholder(_ text: String) -> String {
        var out = text.replacingOccurrences(of: placeholderLine, with: "")
        // 清占位行留下的连续空行
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 两容器（content + segments .text）同步替换——占位行→失败行这类收尾用
    @MainActor
    private static func replaceEverywhere(in node: MessageNode, of target: String, with replacement: String) {
        node.content = node.content.replacingOccurrences(of: target, with: replacement)
        if var segs = node.segments {
            var changed = false
            for i in segs.indices {
                if case .text(let s) = segs[i], s.contains(target) {
                    segs[i] = .text(s.replacingOccurrences(of: target, with: replacement))
                    changed = true
                }
            }
            if changed { node.setSegments(segs) }
        }
    }

    private static func fetchNode(_ nodeId: String, context: ModelContext) -> MessageNode? {
        let desc = FetchDescriptor<MessageNode>(predicate: #Predicate { $0.id == nodeId })
        return (try? context.fetch(desc))?.first
    }

    private static func conversationTitle(node: MessageNode, context: ModelContext) -> String? {
        let convId = node.conversationId
        let desc = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == convId })
        return (try? context.fetch(desc))?.first?.title
    }

    /// 失败短语：统一错误文案，抹掉这个服务的 key
    private static func shortPhrase(_ error: Error, setup: VoiceSetup) -> String {
        guard let e = error as? VoiceSynthError else { return "出了点问题" }
        let secrets = serviceKeyProvider(setup.service.id).map { [$0] } ?? []
        return VoiceServiceStore.redact(e.message, secrets: secrets)
    }

    /// 生成成功的语音条经 hub 记进 cc-rp「小克的语音条.md」（CC 能翻到"自己说过的话"）。
    /// best-effort：桥没连就丢，不重试不阻塞。测试注入 reporter 免真 WS。
    static var voiceNoteReporter: ([String: Any]) -> Void = { payload in
        CCBridgeWebSocketClient.shared.send(payload) { _ in }
    }

    private static func reportVoiceNote(script: String, speaker: String?, voiceName: String?, duration: Double?) {
        var note: [String: Any] = ["script": script]
        if let speaker, !speaker.isEmpty { note["speaker"] = speaker }
        if let voiceName, !voiceName.isEmpty { note["voice"] = voiceName }
        if let duration, duration > 0 { note["duration"] = duration }
        voiceNoteReporter(["type": "voice_note", "note": note])
    }

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
