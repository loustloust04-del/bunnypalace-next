import Foundation
import SwiftData

// MARK: - AudiobookItem
// 一本电子书音频。文件本体走 filesystem（~/Library/Application Support/MemoryPalace/audiobooks/{profileId}/）
// currentTime 内部存 Double 精度，UI 渲染时 floor。

@Model
final class AudiobookItem {
    #if os(iOS)
    #Index<AudiobookItem>(
        [\.profileId],
        [\.profileId, \.lastPlayedAt]
    )
    #endif

    @Attribute(.unique) var id: UUID = UUID()

    var profileId: String
    var title: String
    var fileName: String           // 落盘文件名 {uuid}.{ext}
    var fileSizeBytes: Int64
    var totalDuration: Double      // 秒
    var currentTime: Double = 0    // 续播位置（秒）；double 精度内部存，UI floor
    var lastPlayedAt: Date?
    var importedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \AudiobookBookmark.book)
    var bookmarks: [AudiobookBookmark] = []

    init(
        profileId: String,
        title: String,
        fileName: String,
        fileSizeBytes: Int64,
        totalDuration: Double
    ) {
        self.profileId = profileId
        self.title = title
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.totalDuration = totalDuration
    }
}
