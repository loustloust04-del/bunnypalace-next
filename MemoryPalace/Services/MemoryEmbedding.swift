import Foundation
import NaturalLanguage

// MARK: - Memory Embedding（M2：向量语义检索的嵌入引擎）

/// 嵌入引擎协议。A=Apple on-device 起步（粟粟拍板）；未来可加 API embedder 当"高质量向量"子开关。
protocol MemoryEmbedding {
    var isReady: Bool { get }
    /// 模型版本。系统升级模型后旧向量与新查询不在同一空间，比对前必须核对。
    var revision: Int { get }
    func embed(_ text: String) -> [Float]?
}

/// Apple NLContextualEmbedding（BERT 类，on-device，多语言含中文）。
/// 模型资产按需下载；未就绪时 embed 返回 nil，向量路静默退场（app 自包含铁律）。
@Observable
final class AppleMemoryEmbedder: MemoryEmbedding {
    static let shared = AppleMemoryEmbedder()

    /// 模型资产状态——设置-记忆页直接显示（粟粟：开开关必须看得见在干嘛）
    enum AssetState: String {
        case unsupported = "设备不支持"
        case notDownloaded = "未下载"
        case downloading = "下载中…"
        case ready = "就绪"
        case failed = "下载失败"
    }
    private(set) var assetState: AssetState

    @ObservationIgnored private let model: NLContextualEmbedding?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var assetRequestInFlight = false
    @ObservationIgnored private var loggedLoadError = false
    @ObservationIgnored private var loggedInferError = false
    /// 推理串行队列：NLContextualEmbedding 线程安全未文档化，自己串行保平安
    @ObservationIgnored private let queue = DispatchQueue(label: "memory.embedding")

    private init() {
        let m = NLContextualEmbedding(language: .simplifiedChinese)
        model = m
        if let m {
            assetState = m.hasAvailableAssets ? .ready : .notDownloaded
        } else {
            assetState = .unsupported
            CacheDiagLog.shared.log("🧠 向量模型初始化失败（NLContextualEmbedding 不可用）")
        }
    }

    var isReady: Bool { model?.hasAvailableAssets ?? false }
    var revision: Int { model?.revision ?? 0 }

    /// 资产没下好就发起下载（幂等）。状态进设置页 + 缓存诊断日志。
    func requestAssetsIfNeeded() {
        guard let model else { return }
        guard !model.hasAvailableAssets else {
            DispatchQueue.main.async { self.assetState = .ready }
            return
        }
        queue.async { [self] in
            guard !assetRequestInFlight else { return }
            assetRequestInFlight = true
            DispatchQueue.main.async { self.assetState = .downloading }
            CacheDiagLog.shared.log("🧠 向量模型资产下载中…")
            model.requestAssets { result, error in
                self.queue.async { self.assetRequestInFlight = false }
                let ok = result == .available
                DispatchQueue.main.async { self.assetState = ok ? .ready : .failed }
                CacheDiagLog.shared.log("🧠 向量模型资产: \(ok ? "就绪" : "不可用")\(error.map { " — \($0.localizedDescription)" } ?? "")")
            }
        }
    }

    /// 句向量 = token 向量 mean pooling + L2 归一化（余弦相似度退化为点积）。同步，毫秒级。
    func embed(_ text: String) -> [Float]? {
        guard let model, model.hasAvailableAssets else { return nil }
        let trimmed = String(text.prefix(1000))   // maximumSequenceLength 保险裁剪
        guard !trimmed.isEmpty else { return nil }

        return queue.sync {
            if !loaded {
                do { try model.load(); loaded = true }
                catch {
                    if !loggedLoadError {
                        loggedLoadError = true
                        CacheDiagLog.shared.log("🧠 embed: 模型 load 失败 — \(error.localizedDescription)")
                    }
                    return nil
                }
            }
            let result: NLContextualEmbeddingResult
            do { result = try model.embeddingResult(for: trimmed, language: .simplifiedChinese) }
            catch {
                if !loggedInferError {
                    loggedInferError = true
                    CacheDiagLog.shared.log("🧠 embed: 推理失败 — \(error.localizedDescription)")
                }
                return nil
            }
            var sum = [Float](repeating: 0, count: model.dimension)
            var count = 0
            result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
                for (i, v) in vector.enumerated() where i < sum.count { sum[i] += Float(v) }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            let inv = 1.0 / Float(count)
            var mean = sum.map { $0 * inv }
            let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { return nil }
            let invNorm = 1.0 / norm
            mean = mean.map { $0 * invNorm }
            return mean
        }
    }
}

// MARK: - 向量 <-> Data 序列化

enum MemoryVector {
    static func data(from floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// 点积（两边都已 L2 归一化 = 余弦相似度）
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var s: Float = 0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }
}
