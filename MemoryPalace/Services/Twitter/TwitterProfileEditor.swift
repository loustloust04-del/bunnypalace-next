import Foundation
import SwiftData

/// 「编辑个人资料」表单的值。推特的编辑页就这几样，照着来。
struct TwitterProfileDraft: Equatable {
    var displayName: String
    var screenName: String
    var bio: String
    var location: String
    var website: String
}

enum TwitterProfileEditorError: Error, Equatable {
    /// 推特不允许名字为空
    case emptyName
}

/// 在应用里改自己的资料。
///
/// 改过就打 `editedAt` 标记：重新导入存档时导入器看到它就**不碰资料面**，
/// 不然粟粟换的头像、改的简介会被存档里的旧值冲掉。
enum TwitterProfileEditor {

    /// 推特自己的字数上限。超了截断，界面上另有计数提示。
    enum Limit {
        static let name = 50
        static let bio = 160
        static let location = 30
        static let website = 100
    }

    /// 读当前值给表单；本楼层还没有账号就给空表。
    static func load(profileId: String, context: ModelContext) -> TwitterProfileDraft {
        guard let acc = TwitterAccounts.active(profileId: profileId, context: context) else {
            return TwitterProfileDraft(displayName: "", screenName: "", bio: "", location: "", website: "")
        }
        return TwitterProfileDraft(displayName: acc.displayName, screenName: acc.screenName,
                                   bio: acc.bio, location: acc.location, website: acc.website)
    }

    /// 保存。`avatar`/`banner` 传 nil = 不动；`removeBanner` 把横幅退回纯色。
    /// 图片按原样写盘（调用方负责压缩），每次都用新文件名——图片视图按 URL 缓存，
    /// 同名覆盖会让界面看起来像没换成。
    @discardableResult
    static func save(_ draft: TwitterProfileDraft, avatar: Data? = nil, banner: Data? = nil,
                     removeBanner: Bool = false, profileId: String, context: ModelContext,
                     mediaDir: URL) throws -> TwitterArchiveAccount {
        let name = clamp(draft.displayName, Limit.name)
        guard !name.isEmpty else { throw TwitterProfileEditorError.emptyName }

        // 先写文件再动库：写盘失败时库里不留指向不存在文件的名字
        let fm = FileManager.default
        func write(_ data: Data?, kind: String) throws -> String? {
            guard let data else { return nil }
            try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            let fileName = "edited-\(kind)-\(UUID().uuidString).jpg"
            try data.write(to: mediaDir.appendingPathComponent(fileName), options: .atomic)
            return fileName
        }
        let newAvatar = try write(avatar, kind: "avatar")
        let newBanner = try write(banner, kind: "banner")

        let acc: TwitterArchiveAccount
        if let existing = TwitterAccounts.active(profileId: profileId, context: context) {
            acc = existing
        } else {
            // 没导过存档、只自己发推的楼层：新建一条本地账号
            acc = TwitterArchiveAccount(profileId: profileId, accountId: "local-" + UUID().uuidString,
                                        screenName: "", displayName: name)
            context.insert(acc)
        }

        var handle = draft.screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        while handle.hasPrefix("@") { handle.removeFirst() }

        acc.displayName = name
        acc.screenName = handle
        acc.bio = clamp(draft.bio, Limit.bio)
        acc.location = clamp(draft.location, Limit.location)
        acc.website = clamp(draft.website, Limit.website)
        if let newAvatar { acc.avatarFileName = newAvatar }
        if let newBanner { acc.bannerFileName = newBanner } else if removeBanner { acc.bannerFileName = nil }
        acc.editedAt = Date()

        // 显式 save：规则写明主 ctx 不 save，后台 ctx 会读到旧值
        try context.save()
        return acc
    }

    private static func clamp(_ s: String, _ limit: Int) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    /// 导过存档才有东西可恢复。
    static func canRestoreFromArchive(profileId: String, context: ModelContext) -> Bool {
        TwitterAccounts.active(profileId: profileId, context: context)?.archiveDisplayName != nil
    }

    /// 把资料换回最近一次导入的存档原样，并清掉手改标记。
    static func restoreFromArchive(profileId: String, context: ModelContext) throws {
        guard let acc = TwitterAccounts.active(profileId: profileId, context: context),
              acc.archiveDisplayName != nil else { return }
        applyArchiveProfile(to: acc)
        try context.save()
    }

    /// 存档另存的那份 → 当前资料。导入器和「恢复」共用。
    static func applyArchiveProfile(to acc: TwitterArchiveAccount) {
        acc.screenName = acc.archiveScreenName ?? acc.screenName
        acc.displayName = acc.archiveDisplayName ?? acc.displayName
        acc.bio = acc.archiveBio ?? ""
        acc.location = acc.archiveLocation ?? ""
        acc.website = acc.archiveWebsite ?? ""
        acc.avatarFileName = acc.archiveAvatarFileName
        acc.bannerFileName = acc.archiveBannerFileName
        acc.editedAt = nil
    }
}
