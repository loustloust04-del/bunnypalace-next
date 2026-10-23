import Foundation

// MARK: - 小芽 · 本机后端（plan-小芽-v2 §6 → v3 §1）
// 推理本体在全 app 共用的 LocalLLMService（排队、不互相掐断）；这里只是小芽这一侧的把手：记住用哪个模型、自己那一单。

@MainActor
final class AssistantLocalBackend: AssistantBackend {
    let modelId: String
    private var job: LocalLLMService.Job?

    init(modelId: String) {
        self.modelId = modelId
    }

    func run(_ request: AssistantBackendRequest, onEvent: @escaping @MainActor (AssistantBackendEvent) -> Void) {
        job?.cancel()
        job = LocalLLMService.shared.run(modelId: modelId, request: request, onEvent: onEvent)
    }

    func cancel() {
        job?.cancel()
        job = nil
    }
}
