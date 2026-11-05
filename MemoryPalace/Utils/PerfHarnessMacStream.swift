#if (DEBUG || PERF_BENCH) && os(macOS)
import Foundation
import Observation
import QuartzCore

/// Synthetic tokens are single Chinese characters, not a model tokenizer's tokens.
/// Open-loop deadlines never drop late tokens: delayed callbacks catch up in order.
@MainActor
@Observable
final class PerfHarnessMacStream {
    static let credentialID = "mac-perf-scripted"
    static let modelID = "synthetic-30chars-per-second"
    static let output = String(repeating: "测量本地流式文字", count: 375)
    static private(set) var active = false
    static private(set) var completedCharacters = 0
    static private(set) var maximumLateness = 0.0
    private(set) var isStreaming = false
    private(set) var content = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    func play(modelID: String, onToken: @escaping (String) -> Void,
              onComplete: @escaping (String, TokenUsage?) -> Void, onError: @escaping (String) -> Void) {
        guard PerfHarnessMac.streamEnabled, modelID == Self.modelID else { onError("invalid isolated mac synthetic stream request"); return }
        guard !isStreaming else { onError("synthetic stream already active"); return }
        stop()
        generation &+= 1
        let request = generation
        content = ""
        isStreaming = true
        Self.active = true
        Self.completedCharacters = 0
        Self.maximumLateness = 0
        task = Task { @MainActor [weak self] in
            let start = CACurrentMediaTime()
            for (index, character) in Self.output.enumerated() {
                let deadline = start + Double(index + 1) / 30
                let delay = deadline - CACurrentMediaTime()
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, let self, self.generation == request, PerfHarnessMac.streamEnabled else { return }
                Self.maximumLateness = max(Self.maximumLateness, CACurrentMediaTime() - deadline)
                self.content.append(character)
                Self.completedCharacters += 1
                onToken(String(character))
            }
            guard let self, self.generation == request, !Task.isCancelled else { return }
            self.isStreaming = false
            Self.active = false
            self.task = nil
            onComplete(self.content, nil)
        }
    }
    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        isStreaming = false
        Self.active = false
    }
}
#endif
