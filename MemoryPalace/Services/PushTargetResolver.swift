import Foundation
import SwiftData

/// 推送 chat_id 的落点解析（补洞批次 · 洞 7）。
///
/// `Conversation.id` 是**全库** `@Attribute(.unique)`，`profileId` 只是普通列——
/// 按 `id == chatId && profileId == 当前楼层` 查不到 **不等于** 对话不存在，
/// 它可能躺在别的楼层。解析先按 id 全库查，再看它属于谁。
///
/// 纯函数：不碰 UI、不读写 UserDefaults、不切楼层。调用方（ContentView）按结果动作，
/// 将来统一路由（AppRoute）直接复用这里。
enum PushTargetResolution: Equatable {
    /// 对话就在当前楼层，可以直接导航到 nodeId
    case navigate(conversationId: String, nodeId: String)
    /// 对话在别的楼层：调用方先切楼层，切完 subtree 重建后再消费一次
    case switchProfile(profileId: String, conversationId: String)
    /// terminal：全库都没有这个 id（对话已被永久删除）
    case conversationMissing
    /// terminal：对话还在，但它所属的楼层已经不在楼层表里
    case profileMissing(profileId: String)
    /// terminal：对话还在，但没有 currentNodeId（空壳对话，没有可落点的消息）
    case conversationEmpty(conversationId: String)
    /// 可恢复：这一刻查不了（SwiftData 还没就绪等）——调用方保留 pending key 下次再试
    case unavailable
}

enum PushTargetResolver {

    static func resolve(
        chatId: String,
        currentProfileId: String,
        knownProfileIds: Set<String>,
        in context: ModelContext
    ) -> PushTargetResolution {
        // 全库按 id 查（id 是全库 unique，最多一行），再看它属于谁。
        let targetId = chatId
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate<Conversation> { $0.id == targetId }
        )
        let hit: Conversation?
        do {
            hit = try context.fetch(descriptor).first
        } catch {
            // 查不了 ≠ 不存在：容器还没就绪时属于可恢复失败，调用方保留 pending key 下次再试。
            return .unavailable
        }
        guard let conv = hit else { return .conversationMissing }
        guard !conv.currentNodeId.isEmpty else { return .conversationEmpty(conversationId: conv.id) }
        if conv.profileId == currentProfileId {
            return .navigate(conversationId: conv.id, nodeId: conv.currentNodeId)
        }
        guard knownProfileIds.contains(conv.profileId) else {
            return .profileMissing(profileId: conv.profileId)
        }
        return .switchProfile(profileId: conv.profileId, conversationId: conv.id)
    }
}
