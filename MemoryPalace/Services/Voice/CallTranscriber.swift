#if os(iOS)
import AVFoundation
import Speech
import os

/// 通话 STT（plan-voice-call T2）：SpeechAnalyzer 实时转写封装。
/// start() → AVAudioEngine tap → AnalyzerInput 流 → volatile 进 onPartial（字幕）/
/// finalized 进 onFinal（CallSession.userFinalTranscript）。
/// 参照系统坑：连续识别流会自己结束——只要 wanted 仍为 true 就 ~450ms 后自动重启，否则"聋了"。
@MainActor
final class CallTranscriber {

    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    /// 权限被拒/资产不可用等不可恢复问题（CallScreen 显示后挂断）
    var onUnavailable: (String) -> Void = { _ in }

    /// 应该在听（自动重启判据；stop 后置 false 不再重启）
    private var wanted = false
    private var running = false
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var sessionTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    func start() {
        wanted = true
        guard !running else { return }
        running = true
        sessionTask = Task { @MainActor in
            await runOnce()
            running = false
            teardownAudio()
            // 自然结束（识别流自己停）→ 仍想听就重启
            guard wanted else { return }
            restartTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard wanted, !running else { return }
                start()
            }
        }
    }

    func stop() {
        wanted = false
        restartTask?.cancel()
        restartTask = nil
        inputContinuation?.finish()   // 输入流收口 → analyzer 结束 → runOnce 返回并 teardown
        sessionTask?.cancel()
    }

    // MARK: - 一轮识别

    private func runOnce() async {
        // 1. 麦克风权限
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            wanted = false
            onUnavailable("没有麦克风权限——设置里打开后再试")
            return
        }

        do {
            // 2. transcriber + 资产（首次要下模型）
            let transcriber = SpeechTranscriber(
                locale: Locale(identifier: "zh_CN"),
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                onPartial("正在下载语音模型…")
                try await req.downloadAndInstall()
                onPartial("")
            }
            guard wanted else { return }

            // 3. 音频引擎 → AnalyzerInput 流
            let engine = AVAudioEngine()
            self.engine = engine
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: inputFormat)
            let converter: AVAudioConverter? = {
                guard let target = targetFormat, target != inputFormat else { return nil }
                return AVAudioConverter(from: inputFormat, to: target)
            }()

            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            inputContinuation = continuation
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                if let converter, let target = targetFormat {
                    let ratio = target.sampleRate / buffer.format.sampleRate
                    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                    var err: NSError?
                    var fed = false
                    converter.convert(to: out, error: &err) { _, status in
                        if fed { status.pointee = .noDataNow; return nil }
                        fed = true; status.pointee = .haveData; return buffer
                    }
                    if err == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
                } else {
                    continuation.yield(AnalyzerInput(buffer: buffer))
                }
            }
            engine.prepare()
            try engine.start()

            // 4. 分析 + 消费结果（volatile 覆盖式字幕 / final 逐条上抛）
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            try await analyzer.start(inputSequence: stream)
            for try await result in transcriber.results {
                guard wanted, !Task.isCancelled else { break }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if result.isFinal { onPartial(""); onFinal(text) }
                else { onPartial(text) }
            }
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // 单轮失败不算不可用（网络抖/引擎中断），wanted 仍在就走自动重启
            callLog.error("transcriber 轮次结束：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func teardownAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        analyzer = nil
        inputContinuation = nil
    }
}
#endif
