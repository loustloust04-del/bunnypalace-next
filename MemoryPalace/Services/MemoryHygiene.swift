import Foundation
import SwiftData

// MARK: - MV5 存量整理（一次性清洗）
//
// 编排流程（plan-MV5 二.刀2，决策 B：全量做梦 + 碎片间近似去重）：
//   ① 上限保护：listAll > maxScanCount → 抛 tooManyMemories
//   ② 向量补算：所有 Memory 缺向量/revision 失配的同步补；embedder 未就绪 → 抛 noEmbedder
//   ③ 全量做梦：listHotAndWarm 喂 DreamConsolidator.dream；空候选/失败抛错
//   ④（修复第一刀·刀2 停用）做梦后不再毕业消费碎片
//   ⑤ pair 配对去重：剩余 hot+warm 按 updatedAt 倒序 O(n²) 配对，sim>0.75 保新去旧
//   ⑥ 返回 Report

enum MemoryHygiene {

    /// 复用写时去重阈值（plan-MV5 决策一致）
    static let pairThreshold: Float = MemoryExtractor.dedupSimilarityThreshold   // 0.75

    /// O(n²) 上限保护：超过先提示用户做衰减再来（189 条 ≈ 17820 次点积是毫秒级；
    /// 1 万条 ≈ 1 亿次点积仍亚秒，但更大就请走 MV3 衰减）
    static let maxScanCount = 10000

    struct Report {
        let merged: Int         // 步骤⑤：pair 配对合并对数
        let remaining: Int      // 流程结束后 listHotAndWarm 总数
    }

    enum Failure: Error, LocalizedError {
        case noEmbedder
        case tooManyMemories(Int)
        case dreamFailed
        case noMemories

        var errorDescription: String? {
            switch self {
            case .noEmbedder:           return "向量模型未就绪（先到设置-记忆开「向量检索」让模型下载）"
            case .tooManyMemories(let n): return "记忆条数过多（\(n) > \(MemoryHygiene.maxScanCount)），先做衰减再整理"
            case .dreamFailed:          return "做梦失败（看「设置→调试」日志）"
            case .noMemories:           return "记忆库为空，无需整理"
            }
        }
    }

    /// 一次性清洗。详见文件顶部流程。失败抛错，调用方决定 UI 提示。
    /// - Parameter context: SwiftData 主 context（@MainActor 同款语义；helper 调用 supersede 需要）
    @MainActor
    static func sweep(
        profileId: String,
        model: ProviderModel,
        providerManager: ProviderManager,
        context: ModelContext
    ) async throws -> Report {
        let store = SwiftDataMemoryStore()

        // 步骤 ①：上限
        let all = store.listAll(profileId: profileId, context: context)
        guard !all.isEmpty else { throw Failure.noMemories }
        guard all.count <= maxScanCount else { throw Failure.tooManyMemories(all.count) }

        // 步骤 ②：向量补算（同步——pair 配对必须用现成向量）
        let embedder = AppleMemoryEmbedder.shared
        guard embedder.isReady else {
            embedder.requestAssetsIfNeeded()
            throw Failure.noEmbedder
        }
        let rev = embedder.revision
        var backfilled = 0
        for m in all where m.embeddingData == nil || m.embeddingRevision != rev {
            if let vec = embedder.embed(m.content) {
                m.embeddingData = MemoryVector.data(from: vec)
                m.embeddingRevision = rev
                backfilled += 1
            }
        }
        if backfilled > 0 {
            try? context.save()
            CacheDiagLog.shared.log("🧹 整理: 补算 \(backfilled) 条向量")
        }

        // 步骤 ③：全量做梦
        let candidates = store.listHotAndWarm(profileId: profileId, context: context)
        guard !candidates.isEmpty else { throw Failure.noMemories }
        let facts = candidates.map { (content: $0.content, category: $0.category) }
        guard let _ = try? await DreamConsolidator.dream(
            profileId: profileId, facts: facts, model: model, providerManager: providerManager
        ) else {
            throw Failure.dreamFailed
        }

        // 步骤 ⑤：pair 去重——抽纯函数 pairDedup 便于 XCTest
        let remaining = store.listHotAndWarm(profileId: profileId, context: context)
        let pairs = pairDedup(memories: remaining, threshold: pairThreshold)
        var merged = 0
        for pair in pairs {
            do {
                try store.supersede(id: pair.supersedeId, context: context)
                try? store.recordAccess(ids: [pair.keepId], context: context)
                merged += 1
                CacheDiagLog.shared.log("🧹 整理：sim=\(String(format: "%.2f", pair.sim)) → 保 \(pair.keepId.uuidString.prefix(8)) 毕业 \(pair.supersedeId.uuidString.prefix(8))")
            } catch {
                CacheDiagLog.shared.log("🧹 整理：合并失败 — \(error.localizedDescription)")
            }
        }

        let finalRemaining = store.listHotAndWarm(profileId: profileId, context: context).count
        CacheDiagLog.shared.log("🧹 整理完成：合并 \(merged) · 剩余 \(finalRemaining)")
        return Report(merged: merged, remaining: finalRemaining)
    }

    // MARK: - 纯函数层（XCTest 可直测）

    /// pair 配对去重结果：保留 keepId 毕业 supersedeId（保新去旧）
    struct DedupPair {
        let keepId: UUID
        let supersedeId: UUID
        let sim: Float
    }

    /// O(n²) pair 配对——按 updatedAt 倒序，外层是"新"内层是"旧"。
    /// 钉住免疫：m2.isUserExplicit 时跳过（钉住作为外层"新"可以毕业其它自动条，但作为内层"旧"永不被毕业）。
    /// revision 失配的不比对（跨模型向量空间不同）。
    /// alreadyMerged 防一条被毕业后再作为外层
    static func pairDedup(memories: [Memory], threshold: Float) -> [DedupPair] {
        let sorted = memories.sorted { $0.updatedAt > $1.updatedAt }
        var result: [DedupPair] = []
        var alreadyMerged = Set<UUID>()

        for i in 0..<sorted.count {
            let m1 = sorted[i]
            if alreadyMerged.contains(m1.id) { continue }
            guard let v1Data = m1.embeddingData else { continue }
            let v1 = MemoryVector.floats(from: v1Data)
            let m1Rev = m1.embeddingRevision

            for j in (i+1)..<sorted.count {
                let m2 = sorted[j]
                if alreadyMerged.contains(m2.id) || m2.isUserExplicit { continue }
                guard let v2Data = m2.embeddingData, m2.embeddingRevision == m1Rev else { continue }
                let v2 = MemoryVector.floats(from: v2Data)
                let sim = MemoryVector.dot(v1, v2)
                if sim > threshold {
                    result.append(DedupPair(keepId: m1.id, supersedeId: m2.id, sim: sim))
                    alreadyMerged.insert(m2.id)
                }
            }
        }
        return result
    }
}
