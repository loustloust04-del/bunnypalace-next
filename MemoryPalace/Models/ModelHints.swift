import Foundation

/// 拉 /models 时顺手拿到的模型元数据（plan-provider-presets Q5 = A：旁表，不进 ProviderModel）。
/// 按「卡 / 模型」存；消费方（上下文窗口、看图拦截）归兼容线。
struct ModelHint: Codable, Equatable, Sendable {
    var contextTokens: Int?
    var inputModalities: [String]?
}

final class ModelHints: @unchecked Sendable {
    static let shared: ModelHints = {
        if TestHostIsolation.active || NSClassFromString("XCTestCase") != nil {
            let dir = AppPaths.temporaryDirectory
                .appendingPathComponent("MemoryPalaceTests-hints-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            return ModelHints(fileURL: dir.appendingPathComponent("model-hints.json"))
        }
        let dir = AppPaths.applicationSupport.appendingPathComponent("MemoryPalace", isDirectory: true)
        return ModelHints(fileURL: AppPaths.checked(dir.appendingPathComponent("model-hints.json")))
    }()

    let fileURL: URL
    private let lock = NSLock()
    private var byCard: [String: [String: ModelHint]]?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func hint(credentialId: String, modelId: String) -> ModelHint? {
        lock.withLock { loaded()[credentialId]?[modelId] }
    }

    /// 一张卡拉一次就整份替换：上游不再给的模型 / 字段不留旧值
    func replace(credentialId: String, with hints: [String: ModelHint]) {
        lock.withLock {
            var all = loaded()
            guard all[credentialId] ?? [:] != hints else { return }
            all[credentialId] = hints.isEmpty ? nil : hints
            byCard = all
            guard let data = try? JSONEncoder().encode(all) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loaded() -> [String: [String: ModelHint]] {
        if let byCard { return byCard }
        let read = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String: [String: ModelHint]].self, from: $0) } ?? [:]
        byCard = read
        return read
    }
}

/// 模型能不能看图（plan-model-vision-check §1.1）：卡上 /models 旁表 > models.dev 目录 > 不知道。
/// 只有明确 `.no` 才拦图；不知道照发（没收录的模型不能突然看不到图）
enum VisionCapability: Equatable {
    case yes, no, unknown

    static func of(_ model: ProviderModel, providerType: ProviderType?,
                   hints: ModelHints = .shared, catalog: ModelCatalog = .shared) -> VisionCapability {
        if providerType == .ccBridge { return .yes }   // CC 后端自己收附件
        let modalities = hints.hint(credentialId: model.credentialId, modelId: model.modelId)?.inputModalities
            ?? catalog.model(for: model.modelId)?.inputModalities
        guard let modalities else { return .unknown }
        return modalities.contains("image") ? .yes : .no
    }
}
