import Foundation
import SwiftData

/// 推特存档的账号面。一个楼层一份（粟粟 2026-09-20 拍：算楼层的）。
@Model
final class TwitterArchiveAccount {
    var profileId: String = ""
    var accountId: String = ""
    var screenName: String = ""
    var displayName: String = ""
    var bio: String = ""
    var location: String = ""
    var website: String = ""
    /// 头像/横幅落盘后的文件名；存档里只有远端 URL，不联网就可能没有本地文件
    var avatarFileName: String?
    var bannerFileName: String?
    var accountCreatedAt: Date?
    var importedAt: Date = Date()
    /// 导入来源文件名，给「重新导入」和排错用
    var sourceName: String = ""
    /// 在应用里手动改过资料的时间。非 nil 时重新导入**不覆盖**资料面
    /// （名字/handle/简介/地点/网站/头像/横幅），只更新推文。
    var editedAt: Date?
    /// 当前在用的账号（一楼层多个账号时切换用）。都为 false 时按最早导入的算
    var isActive: Bool = false
    /// 谁的号：`user`（粟粟的）/ `ai`（楼层 AI 的）。AI 的号不进账号切换、不会成为当前账号
    var ownerKind: String = "user"
    /// 这个 AI 号跟楼层 AI 资料（名字、头像）同步——每层只有一个；AI 自己另开的号不同步
    var syncsWithAIProfile: Bool = false
    /// 同步过来的头像的指纹，头像没变就不重写文件
    var aiAvatarDigest: String?
    /// 最近一次导入时存档里的资料原样，给「恢复成存档里的资料」用——手改过之后不用再导一次也能回去。
    /// nil = 没导过存档（只自己发推的楼层）
    var archiveDisplayName: String?
    var archiveScreenName: String?
    var archiveBio: String?
    var archiveLocation: String?
    var archiveWebsite: String?
    var archiveAvatarFileName: String?
    var archiveBannerFileName: String?

    init(profileId: String, accountId: String, screenName: String, displayName: String,
         bio: String = "", location: String = "", website: String = "",
         avatarFileName: String? = nil, bannerFileName: String? = nil,
         accountCreatedAt: Date? = nil, importedAt: Date = Date(), sourceName: String = "") {
        self.profileId = profileId
        self.accountId = accountId
        self.screenName = screenName
        self.displayName = displayName
        self.bio = bio
        self.location = location
        self.website = website
        self.avatarFileName = avatarFileName
        self.bannerFileName = bannerFileName
        self.accountCreatedAt = accountCreatedAt
        self.importedAt = importedAt
        self.sourceName = sourceName
    }
}

/// 一条推文。
///
/// `hashtags`/`mentions`/`urls` 存**扁平字符串**而不是数组：`.claude/rules/swiftdata.md`
/// 要求关键词匹配落进 SQLite predicate，数组字段做不到。
/// `mediaCount` 冗余存一份，让「只看有图」也能走 predicate 而不是内存 filter。
/// 字段名避开 SwiftData 保留名（`isDeleted`/`isFault`/`isInserted`/`objectID`）——
/// 「已删除」语义用 `isRemoved`。
@Model
final class TweetEntry {
    var profileId: String = ""
    var tweetId: String = ""
    var text: String = ""
    var createdAt: Date = Date.distantPast
    var favoriteCount: Int = 0
    var retweetCount: Int = 0
    var inReplyToTweetId: String?
    var inReplyToScreenName: String?
    var hashtagsJoined: String = ""
    var mentionsJoined: String = ""
    var urlsJoined: String = ""
    var mediaCount: Int = 0
    var isRemoved: Bool = false
    /// 自己点过赞。存档不给这个位，只在应用里点才会有。
    var likedByMe: Bool = false
    /// 转推的原作者。非 nil = 这条是转推，`text` 是原文（存档里本来就是截断的）
    var retweetedScreenName: String?
    var retweetedName: String?
    /// 在应用里「转帖」生成的那一行指回原推；原推自己用 `retweetedByMe` 记已转
    var repostOfTweetId: String?
    var retweetedByMe: Bool = false
    /// 引用推文：被引用那条的 id
    var quotedTweetId: String?
    /// 属于哪个账号（`TwitterArchiveAccount.accountId`）。空 = 多账号之前的老数据，面板启动时归给当前账号
    var accountId: String = ""
    /// 加书签的时间；nil = 没加。书签页按它倒序
    var bookmarkedAt: Date?
    /// 这条推所在的书签文件夹，存成 `|id1|id2|`（扁平字符串，文件夹筛选能落进 predicate）
    var bookmarkFolderIds: String = ""
    /// 作者。nil = 自己的推；从 X 拉下来的书签/赞是别人的推，记作者，**不进自己的时间线**
    var authorScreenName: String?
    var authorName: String?
    /// X 上的原帖链接。从 X 拉的推自带；存档的推没有，用 `xURL(ownHandle:)` 拼
    var sourceURL: String?
    /// 在应用里改过正文的时间（粟粟 2026-09-27：推特可以编辑）。nil = 没改过。
    /// 改过的推，重新导入存档时不拿存档原文盖回去
    var editedAt: Date?

    init(profileId: String, tweetId: String, text: String, createdAt: Date,
         favoriteCount: Int = 0, retweetCount: Int = 0,
         inReplyToTweetId: String? = nil, inReplyToScreenName: String? = nil,
         hashtagsJoined: String = "", mentionsJoined: String = "", urlsJoined: String = "",
         mediaCount: Int = 0, isRemoved: Bool = false) {
        self.profileId = profileId
        self.tweetId = tweetId
        self.text = text
        self.createdAt = createdAt
        self.favoriteCount = favoriteCount
        self.retweetCount = retweetCount
        self.inReplyToTweetId = inReplyToTweetId
        self.inReplyToScreenName = inReplyToScreenName
        self.hashtagsJoined = hashtagsJoined
        self.mentionsJoined = mentionsJoined
        self.urlsJoined = urlsJoined
        self.mediaCount = mediaCount
        self.isRemoved = isRemoved
    }
}

extension TweetEntry {
    /// 这条推原本是谁的：从 X 拉下来的别人的推，或者转推的原作者。nil = 自己的。
    /// 显示、回复、转帖都认它，别各处自己拼。
    var originalAuthorHandle: String? { authorScreenName ?? retweetedScreenName }
    var originalAuthorName: String? { authorName ?? retweetedName }

    /// X 上的原帖链接（粟粟 2026-09-24：每条帖子带原帖链接）。
    /// 拉来的推用自带的；存档的推拼 `x.com/<作者>/status/<id>`，作者不知道就用 `i`（X 会自己跳到对的人）。
    /// 转帖那一行指向原推。App 里自己发的、示例的 id 不是纯数字——X 上没有，给 nil，不编假链接。
    func xURL(ownHandle: String?) -> URL? {
        if let s = sourceURL, let url = URL(string: s) { return url }
        let id = repostOfTweetId ?? tweetId
        guard !id.isEmpty, id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { return nil }
        let who = originalAuthorHandle ?? ownHandle
        return URL(string: "https://x.com/\((who?.isEmpty == false ? who : nil) ?? "i")/status/\(id)")
    }
}

/// 一条推文的一个媒体。按 `profileId + tweetId` 关联，不用 SwiftData 关系——
/// 导入是分批写的，关系会让批量插入变慢且难去重。
@Model
final class TweetMedia {
    var profileId: String = ""
    var tweetId: String = ""
    var mediaId: String = ""
    var kind: String = "photo"
    var fileName: String = ""
    var width: Int = 0
    var height: Int = 0

    init(profileId: String, tweetId: String, mediaId: String,
         kind: String = "photo", fileName: String = "", width: Int = 0, height: Int = 0) {
        self.profileId = profileId
        self.tweetId = tweetId
        self.mediaId = mediaId
        self.kind = kind
        self.fileName = fileName
        self.width = width
        self.height = height
    }
}

/// 书签文件夹（X 上自己建的书签分组）。从 X 拉下来的；官方导出里没有书签。
@Model
final class TwitterBookmarkFolder {
    var profileId: String = ""
    var accountId: String = ""
    var folderId: String = ""
    var name: String = ""
    /// X 上的排列顺序
    var order: Int = 0

    init(profileId: String, accountId: String, folderId: String, name: String, order: Int = 0) {
        self.profileId = profileId
        self.accountId = accountId
        self.folderId = folderId
        self.name = name
        self.order = order
    }
}

/// 关注关系：本楼层的一个号关注另一个号（Mastodon 的 follow，纯本地）。
@Model
final class TwitterFollow {
    var profileId: String = ""
    var followerAccountId: String = ""
    var followeeAccountId: String = ""
    var createdAt: Date = Date()

    init(profileId: String, followerAccountId: String, followeeAccountId: String, createdAt: Date = Date()) {
        self.profileId = profileId
        self.followerAccountId = followerAccountId
        self.followeeAccountId = followeeAccountId
        self.createdAt = createdAt
    }
}

/// 某个号点的赞（目前只记 AI 的号；粟粟自己的赞还在 `TweetEntry.likedByMe` 上）。
/// 一个号对一条推只能赞一次，赞数才不会被 AI 反复刷。
@Model
final class TwitterLike {
    var profileId: String = ""
    var accountId: String = ""
    var tweetId: String = ""
    var createdAt: Date = Date()

    init(profileId: String, accountId: String, tweetId: String, createdAt: Date = Date()) {
        self.profileId = profileId
        self.accountId = accountId
        self.tweetId = tweetId
        self.createdAt = createdAt
    }
}

/// 推文草稿（粟粟 2026-09-27：推特草稿箱）。按账号分；回复 / 引用的草稿记着对象，打开时带回去。
/// 图存在 `<媒体目录>/drafts/<draftId>-<i>.jpg`，这里只记文件名。
@Model
final class TwitterDraft {
    var profileId: String = ""
    var draftId: String = ""
    var accountId: String = ""
    var text: String = ""
    /// 图的文件名，`|` 分隔
    var imageFileNames: String = ""
    var replyToTweetId: String?
    var quotedTweetId: String?
    var updatedAt: Date = Date()

    init(profileId: String, draftId: String, accountId: String) {
        self.profileId = profileId
        self.draftId = draftId
        self.accountId = accountId
    }
}
