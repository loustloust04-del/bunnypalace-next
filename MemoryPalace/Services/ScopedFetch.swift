import Foundation
import SwiftData

// MARK: - HasProfileId protocol
//
// 路线 B 单 ModelContainer + profileId filter 架构：所有 profile-scoped 的 @Model
// entity 必须 conform 此 protocol。用途是**编译期**保证 profileId 字段存在，避免
// 漏加 filter。实际 FetchDescriptor / @Query 的 predicate 还是各处手写 #Predicate
// （Swift macro 限制不能 runtime 组合 predicate）。
//
// 调用方 pattern：
// ```swift
// let desc = FetchDescriptor<Conversation>(
//     predicate: #Predicate { $0.profileId == currentProfileId && $0.isTrashed == false },
//     sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
// )
// ```
//
// grep review 时用 `grep -rn "FetchDescriptor<" MemoryPalace/` 逐行检查，对所有
// HasProfileId 类型必须有 profileId predicate。
//
// Plan: docs/plan-unified-container.md Step B
protocol HasProfileId: PersistentModel {
    var profileId: String { get }
}

// MARK: - Entity conformance

extension Conversation: HasProfileId {}
extension MessageNode: HasProfileId {}
extension UserCard: HasProfileId {}
extension ConversationTag: HasProfileId {}
extension FavoriteItem: HasProfileId {}
extension ImportRecord: HasProfileId {}
extension ImportConversationChange: HasProfileId {}
extension Memory: HasProfileId {}
extension MemoryNote: HasProfileId {}
extension PlacedSticker: HasProfileId {}
extension StickerAsset: HasProfileId {}
extension WorldBook: HasProfileId {}
