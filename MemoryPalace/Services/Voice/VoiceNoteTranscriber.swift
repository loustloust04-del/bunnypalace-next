import Foundation
import AVFoundation
import Speech

/// 语音条文件转写（plan-voice-note M3）：录完的整段文件走 SpeechAnalyzer 文件模式，本地出字。
/// 写法照 SpeechAnalyzerSpikeTests 已验证的那套（zh_CN SpeechTranscriber + analyzeSequence(from: AVAudioFile)）。
/// 只在 iOS 录音，但两端都编：mac 单测宿主能跑转写 smoke（SpeechAnalyzer 要 macOS 26）。
enum VoiceNoteTranscriber {
    static let timeout: Duration = .seconds(10)

    /// 转写结果；空 / 失败 / 超时 / 调用方取消 → nil（调用方照发「没转出文字」）。
    /// 先到的那个收尾：取消另一边（结果先到 → 停掉计时；超时 / 调用方取消 → 取消转写任务，sol 观察项）。
    /// 超时不取消模型资产下载：下载在独立任务里继续，下次就快了
    @available(macOS 26.0, iOS 26.0, *)
    static func transcribe(fileURL: URL, timeout: Duration = timeout) async -> String? {
        let gate = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                gate.install(continuation)
                let work = Task { _ = gate.resume(await run(fileURL: fileURL)) }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    _ = gate.resume(nil)
                }
                gate.adopt([work, timer])
            }
        } onCancel: {
            gate.resume(nil)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func run(fileURL: URL) async -> String? {
        do {
            let transcriber = SpeechTranscriber(
                locale: Locale(identifier: "zh_CN"),
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: []
            )
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                // 不随超时取消：首次下模型可能慢，后台装完下一条就能转
                let download = Task.detached { try await request.downloadAndInstall() }
                try await download.value
            }
            try Task.checkCancellation()

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let audioFile = try AVAudioFile(forReading: fileURL)
            let collector = Task { () -> String in
                var finals: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    finals.append(String(result.text.characters))
                }
                return finals.joined()
            }
            do {
                try await withTaskCancellationHandler {
                    if let last = try await analyzer.analyzeSequence(from: audioFile) {
                        try await analyzer.finalizeAndFinish(through: last)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                } onCancel: {
                    collector.cancel()
                    Task { await analyzer.cancelAndFinishNow() }
                }
            } catch {
                // 分析半路失败：结果流可能没收尾，collector 会一直等——先停分析器、取消 collector 再往外抛
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
            let text = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            print("[VOICE-NOTE] 转写失败: \(error)")
            return nil
        }
    }
}

/// 结果 / 超时 / 调用方取消三方赛跑：先到的那个 resume 并取消挂着的任务，后到的什么都不做（continuation 只能 resume 一次）。
/// 调用方取消可能早于 continuation 装上：那时记下「已结束」，装上就立刻 nil
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    func install(_ c: CheckedContinuation<String?, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            c.resume(returning: nil)
            return
        }
        continuation = c
        lock.unlock()
    }

    /// 挂上要随收尾取消的任务；已经收尾了就当场取消
    func adopt(_ newTasks: [Task<Void, Never>]) {
        lock.lock()
        if finished {
            lock.unlock()
            newTasks.forEach { $0.cancel() }
            return
        }
        tasks = newTasks
        lock.unlock()
    }

    /// true = 这次真的收尾了
    @discardableResult
    func resume(_ value: String?) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let c = continuation
        continuation = nil
        let pending = tasks
        tasks = []
        lock.unlock()
        c?.resume(returning: value)
        pending.forEach { $0.cancel() }
        return true
    }
}
