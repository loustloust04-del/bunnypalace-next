import Foundation
import SwiftData

/// 读书功能的轻量索引——书的元数据/进度/封面缩略图存这里供 SwiftUI 反应式渲染。
/// **实际书数据（章节正文/笔记 JSON）落在文件库的 filesystem/books/{safeName}/ 下**，
/// 不进 SwiftData——书的章节正文可能几百 K 到几 M，不适合 SQLite 行。
///
/// 与文件库目录一一对应：
/// - id == safeName（书名经路径穿越防护后的目录名）
/// - 物理文件夹删了 → 启动期 BookStore.refreshEntries 会把 BookEntry 行也删了
///
/// 同步：走 SyncStore LWW 模式，跟 Conversation 同样语义。
@Model
final class BookEntry {
    @Attribute(.unique) var id: String        // safeName，同目录名
    var profileId: String = ""

    var name: String                          // 显示用书名（可能与 safeName 不同——safeName 防穿越；name 保留原始）
    var author: String = ""
    /// "txt" / "pdf" / "epub" / "docx" ...
    var format: String = "txt"

    var totalChapters: Int = 0
    /// 当前阅读到第几章（1-based）
    var currentChapter: Int = 1
    /// 章节内滚动比例（0-1），跨设备/重新打开恢复用
    var scrollRatio: Double = 0

    var addedAt: Date
    var lastReadAt: Date?
    var updateTime: Date                       // LWW 用，跟 Conversation 同义

    /// 列表卡片用的小封面（thumbnail，建议 < 50KB）。原图（如有）在文件库目录里。
    @Attribute(.externalStorage) var coverData: Data?

    init(
        id: String,
        profileId: String,
        name: String,
        author: String = "",
        format: String = "txt",
        totalChapters: Int = 0
    ) {
        self.id = id
        self.profileId = profileId
        self.name = name
        self.author = author
        self.format = format
        self.totalChapters = totalChapters
        self.addedAt = Date()
        self.updateTime = Date()
    }
}
