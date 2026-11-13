import Foundation
import SwiftData

// MARK: - 用户画像（M5 做梦聚合）——v5 Q4 下线
// 停写、停注入、藏界面；画像文件（memory/profile.md）和 mem_*_profile 键都留着不动。
// 这里只剩别处还在用的模型解析和毕业 helper。

enum DreamConsolidator {

    /// 设置页手动做梦用的模型解析：副模型优先，没有就用当前聊天模型
    static func resolveModel(providerManager: ProviderManager) -> ProviderModel? {
        let d = UserDefaults.standard
        return providerManager.sideModel(ids: [d.string(forKey: "memoryExtractModelId") ?? "",
                                               d.string(forKey: "selectedChatModel") ?? ""])
    }

    // MARK: - MV1+MV5 公共毕业 helper

    /// 从 hot+warm 候选里筛"将被消费"的 id（钉住免疫——MV1 决策2：钉住进画像但不毕业）。
    /// 值类型 [UUID] 快照，跨线程安全。
    static func consumedIdsFromCandidates(_ memories: [Memory]) -> [UUID] {
        memories.filter { !$0.isUserExplicit }.map(\.id)
    }

    /// 把消费碎片标毕业（钉住免疫已在 consumedIds 阶段保证）。
    /// `mem_supersede_soft` 关时跳过，与 SC-B2 守卫一致。返回毕业数。
    @discardableResult
    static func graduateConsumedMemories(
        consumedIds: [UUID],
        store: MemoryStore,
        context: ModelContext
    ) -> Int {
        guard MemoryFlags.dreamGraduationEnabled else { return 0 }
        var graduated = 0
        for id in consumedIds {
            do { try store.supersede(id: id, context: context); graduated += 1 }
            catch { CacheDiagLog.shared.log("🌙 画像: 毕业失败 id=\(id) — \(error.localizedDescription)") }
        }
        if graduated > 0 {
            CacheDiagLog.shared.log("🌙 画像: 毕业 \(graduated) 条消费碎片（钉住免疫）")
        }
        return graduated
    }
}
