import Foundation
import SwiftData

/// 草稿箱（粟粟 2026-09-27）。写了一半点取消 → 问要不要存；发新推的框里有「草稿」入口。
/// 图单独存成文件（`<媒体目录>/drafts/`），库里只记文件名；删草稿连图一起删。
enum TwitterDrafts {

    static let dirName = "drafts"

    /// 存草稿。给了 `existing` 就是更新那一份（从草稿打开再存，不另起一份）。
    @discardableResult
    static func save(text: String, images: [Data], replyingTo: String?, quoting: String?, accountId: String,
                     profileId: String, mediaDir: URL, context: ModelContext,
                     existing: TwitterDraft? = nil) throws -> TwitterDraft {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !images.isEmpty else { throw TwitterComposerError.emptyText }
        let draft = existing ?? TwitterDraft(profileId: profileId, draftId: UUID().uuidString, accountId: accountId)
        if existing == nil { context.insert(draft) }

        // 图整批重写：先删旧的，再写新的
        let dir = mediaDir.appendingPathComponent(dirName, isDirectory: true)
        removeImages(of: draft, mediaDir: mediaDir)
        var names: [String] = []
        if !images.isEmpty {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (i, data) in images.enumerated() {
                let name = "\(draft.draftId)-\(i).jpg"
                try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                names.append(name)
            }
        }
        draft.text = text
        draft.imageFileNames = names.joined(separator: "|")
        draft.replyToTweetId = replyingTo
        draft.quotedTweetId = quoting
        draft.updatedAt = Date()
        try context.save()
        return draft
    }

    /// 这个账号的草稿，最近改的在前。
    static func list(profileId: String, accountId: String, context: ModelContext) -> [TwitterDraft] {
        (try? context.fetch(FetchDescriptor<TwitterDraft>(
            predicate: #Predicate { $0.profileId == profileId && $0.accountId == accountId },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
    }

    static func images(of draft: TwitterDraft, mediaDir: URL) -> [Data] {
        imageURLs(of: draft, mediaDir: mediaDir).compactMap { try? Data(contentsOf: $0) }
    }

    static func delete(_ draft: TwitterDraft, mediaDir: URL, context: ModelContext) throws {
        removeImages(of: draft, mediaDir: mediaDir)
        context.delete(draft)
        try context.save()
    }

    private static func imageURLs(of draft: TwitterDraft, mediaDir: URL) -> [URL] {
        let dir = mediaDir.appendingPathComponent(dirName, isDirectory: true)
        return draft.imageFileNames.split(separator: "|").map { dir.appendingPathComponent(String($0)) }
    }

    private static func removeImages(of draft: TwitterDraft, mediaDir: URL) {
        for url in imageURLs(of: draft, mediaDir: mediaDir) { try? FileManager.default.removeItem(at: url) }
    }
}
