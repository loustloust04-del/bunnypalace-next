import Foundation
import SwiftData

// MARK: - AudiobookBookmark
// 一条书签 + 笔记。
//
// 设计意图：
// - timestamp 内部 Double，UI floor 显示 hh:mm:ss
// - bookTitleSnapshot: 创建/书改名时同步写，未来卡片化（插 md 编辑器）即使原书被删/改名也能独立显示
// - bookId 冗余：方便不 join 查 + 让未来 adapter 不需要持有 AudiobookItem 即可消费

@Model
final class AudiobookBookmark {
    #if os(iOS)
    #Index<AudiobookBookmark>(
        [\.profileId],
        [\.profileId, \.bookId]
    )
    #endif

    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String         // 楼层隔离（双保险）
    var bookId: UUID              // 冗余存，未来卡片化解耦
    var timestamp: Double         // 秒
    var note: String = ""
    var bookTitleSnapshot: String // 改书名时同步更新
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var book: AudiobookItem?      // 反向关系（cascade 在 AudiobookItem 那边声明）

    init(
        profileId: String,
        bookId: UUID,
        timestamp: Double,
        note: String = "",
        bookTitleSnapshot: String
    ) {
        self.profileId = profileId
        self.bookId = bookId
        self.timestamp = timestamp
        self.note = note
        self.bookTitleSnapshot = bookTitleSnapshot
    }
}
