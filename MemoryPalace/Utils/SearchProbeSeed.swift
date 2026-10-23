#if DEBUG && os(iOS)
import Foundation
import SwiftData

/// [PROBE 搜索 seed] Debug-only：往当前楼层塞 S3 新搜索类型的样本（全部含「薄荷」），给模拟器实拍用（plan-search-s3 Todo 10）。
/// 推特 130 条（够翻第二页）、交易（标的 + 成交）、健康（体重 / 用药 / 归档药 / 经期 / 亲密记录）、
/// 纸书（index + 章节 + 批注 + 书签）+ 有声书（含书签备注）、一条被单独删掉的气泡。
///
/// 触发：`xcrun simctl launch <udid> <bundle> -- --search-probe-seed`
enum SearchProbeSeed {
    static let markerKey = "probeSearchSeedDone_v1"
    static let bookSafeName = "probe-search-book"

    static func injectIfNeeded(container: ModelContainer, profileId pid: String) {
        guard CommandLine.arguments.contains("--search-probe-seed") else { return }
        if UserDefaults.standard.bool(forKey: markerKey) {
            PROBE("[PROBE 搜索 seed] already done, skip")
            return
        }
        let ctx = ModelContext(container)
        let now = Date()
        let day: (Int) -> Date = { Calendar.current.date(byAdding: .day, value: -$0, to: now) ?? now }

        for i in 0..<130 {
            ctx.insert(TweetEntry(profileId: pid, tweetId: "probe-search-tw-\(String(format: "%03d", i))",
                                  text: "探针推文 \(i)：今天泡了一壶薄荷茶。", createdAt: now.addingTimeInterval(Double(-i * 3600)),
                                  hashtagsJoined: i % 10 == 0 ? "薄荷" : ""))
        }


        ctx.insert(WeightEntry(profileId: pid, date: day(5), weightKg: 50, note: "喝完薄荷茶称的"))
        ctx.insert(Medication(profileId: pid, name: "薄荷片", dosage: "1 片", timesOfDay: [480], reminderEnabled: false))
        let archived = Medication(profileId: pid, name: "薄荷旧药（已停用）", dosage: "2 片", timesOfDay: [540], reminderEnabled: false)
        archived.isArchived = true
        ctx.insert(archived)
        let cycle = CycleDay(profileId: pid, date: day(6), flow: "light")
        cycle.note = "薄荷暖贴"
        ctx.insert(cycle)
        ctx.insert(IntimacyEntry(profileId: pid, date: day(7), note: "探针亲密记录：薄荷"))

        seedBook(pid: pid, now: now)
        ctx.insert(BookEntry(id: bookSafeName, profileId: pid, name: "薄荷之书", author: "探针作者", format: "txt", totalChapters: 1))
        let audio = AudiobookItem(profileId: pid, title: "薄荷有声书", fileName: "probe-search.m4a", fileSizeBytes: 0, totalDuration: 600)
        ctx.insert(audio)
        let mark = AudiobookBookmark(profileId: pid, bookId: audio.id, timestamp: 42, note: "探针书签：薄荷那段", bookTitleSnapshot: audio.title)
        mark.book = audio
        ctx.insert(mark)

        let convId = "probe-search-conv"
        ctx.insert(Conversation(id: convId, title: "[PROBE] 回收站气泡", createTime: now, updateTime: now,
                                currentNodeId: "probe-search-msg-0", provider: "api", profileId: pid))
        ctx.insert(MessageNode(id: "probe-search-msg-0", role: "user", content: "探针：留着的气泡", contentType: "text",
                               createTime: now.addingTimeInterval(-120), parentId: nil, childrenIds: ["probe-search-msg-1"],
                               conversationId: convId, profileId: pid))
        let trashed = MessageNode(id: "probe-search-msg-1", role: "assistant", content: "探针：被单独删掉的薄荷气泡", contentType: "text",
                                  createTime: now.addingTimeInterval(-60), parentId: "probe-search-msg-0", childrenIds: [],
                                  conversationId: convId, profileId: pid)
        trashed.isTrashed = true
        trashed.trashedAt = now
        ctx.insert(trashed)

        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: markerKey)
            PROBE("[PROBE 搜索 seed] injected pid=\(pid.prefix(8))")
        } catch {
            PROBE("[PROBE 搜索 seed] FAILED: \(error)")
        }
    }

    private static func seedBook(pid: String, now: Date) {
        let text = "第一章正文：窗台上的薄荷长得很好。"
        let index = BookStore.BookIndex(name: "薄荷之书", author: "探针作者", format: "txt", createdAt: now, updatedAt: now,
                                        currentChapter: 1, scrollRatio: 0, totalChapters: 1,
                                        chapters: [BookStore.ChapterMeta(no: 1, title: "第一章", chars: text.count)])
        let note = BookStore.Note(id: UUID().uuidString, chapter: 1, anchorText: "窗台上的薄荷", anchorStart: 6, anchorEnd: 12,
                                  kind: "note", content: "探针批注：薄荷要多晒太阳", role: "user", messageId: nil, createdAt: now)
        let bookmark = BookStore.Bookmark(id: UUID().uuidString, chapter: 1, scrollRatio: 0, title: "第一章 · 薄荷", createdAt: now)
        try? BookStore.saveIndex(index, safeName: bookSafeName, profileId: pid)
        try? BookStore.saveChapterText(text, safeName: bookSafeName, chapterNo: 1, profileId: pid)
        try? BookStore.saveNotes([note], safeName: bookSafeName, profileId: pid)
        try? BookStore.saveBookmarks([bookmark], safeName: bookSafeName, profileId: pid)
    }
}
#endif
