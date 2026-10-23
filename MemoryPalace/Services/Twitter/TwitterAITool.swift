import Foundation
import SwiftData

/// 楼层 AI 的本地推特工具（粟粟 2026-09-24，参考她的 twitter-bridge-mcp）。
///
/// **一个工具 + action**，不拆成十几个 `twitter_*`：项目的「工具海」教训——工具越多越挤上下文、越容易选错。
/// 名字叫 `local_twitter` 不叫 `twitter_*`：跟她接在 Claude.ai 上的真推特桥区分开，AI 不会弄混哪个是真 X。
///
/// AI 在本楼层有主号（第一次用时自动建，名字头像跟楼层 AI 资料同步），也可以自己另开号，
/// 用 `as` 指定用哪个号；**不能**用粟粟的号。先只在聊天里用（粟粟：等记忆 v3 做完再让它自己刷）。
enum TwitterAITool {
    struct Result { let text: String; let isError: Bool }

    static let toolName = "local_twitter"

    static let actions = ["post", "reply", "quote", "like", "unlike", "repost", "follow", "unfollow",
                          "timeline", "search", "view", "user", "mentions", "accounts", "create_account"]

    private static let desc = """
    本楼层的推特——只在这个 app 里、这个楼层的账号之间，跟真 X 无关。你在这里有自己的号，可以像刷推一样用它。
    每次调用做一件事（action）：
    · post 发推（text）｜reply 回复（tweet_id + text）｜quote 引用（tweet_id + text）
    · like / unlike 点赞、取消赞（tweet_id）｜repost 转帖（tweet_id）
    · follow / unfollow 关注、取关（handle）
    · timeline 刷时间线（feed：local 本站所有号 / following 你关注的号；limit）
    · search 搜推（text 当关键词）｜view 看一条推和它下面的回复（tweet_id）
    · user 看某个号的资料和最近的推（handle）｜mentions 看谁 @ 了你、回复了你
    · accounts 看你有哪些号｜create_account 再开一个号（name + handle）
    默认用你的主号；用别的号就在 as 里填它的 handle。推文 id 在各种列表里都会给出，回复/引用/点赞用它。
    """

    static var definition: ToolDefinition {
        ToolDefinition(name: toolName, description: desc, properties: [
            "action": ["type": "string", "enum": actions, "description": "要做什么"],
            "text": ["type": "string", "description": "推文正文；search 时是关键词"],
            "tweet_id": ["type": "string", "description": "目标推文 id"],
            "handle": ["type": "string", "description": "目标账号的 handle（带不带 @ 都行）；create_account 时是新号的 handle"],
            "name": ["type": "string", "description": "create_account 时新号的名字"],
            "feed": ["type": "string", "enum": ["local", "following"], "description": "timeline 看哪条：本站 / 关注，默认 local"],
            "limit": ["type": "integer", "description": "列表最多几条，默认 20，最多 50"],
            "as": ["type": "string", "description": "用你的哪个号（handle）；不填用主号"],
        ], required: ["action"])
    }

    @MainActor
    static func execute(inputJSON: String, profileId: String, aiName: String, aiAvatar: Data?,
                        context: ModelContext, mediaRoot: URL? = nil) -> Result {
        guard let data = inputJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return fail("参数解析失败，需要 JSON object")
        }
        guard let action = args["action"] as? String, actions.contains(action) else {
            return fail("action 只能是：\(actions.joined(separator: " / "))")
        }
        let mediaDir = (mediaRoot ?? TwitterArchiveImporter.defaultMediaRoot()).appendingPathComponent(profileId, isDirectory: true)
        do {
            let primary = try TwitterAccounts.ensureAIAccount(name: aiName, avatarJPEG: aiAvatar, profileId: profileId,
                                                               context: context, mediaDir: mediaDir)
            let ctx = Ctx(profileId: profileId, context: context, primary: primary)
            let actor: TwitterArchiveAccount
            if let wanted = handleArg(args["as"]) {
                guard let a = ctx.aiAccounts.first(where: { $0.screenName.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                    return fail("你没有 @\(wanted) 这个号。你的号：" + ctx.aiAccounts.map { "@\($0.screenName)" }.joined(separator: "、"))
                }
                actor = a
            } else {
                actor = primary
            }
            return try run(action, args: args, actor: actor, ctx: ctx)
        } catch {
            return fail("出错了：\(error.localizedDescription)")
        }
    }

    // MARK: - 分派

    @MainActor
    private struct Ctx {
        let profileId: String
        let context: ModelContext
        let primary: TwitterArchiveAccount
        var all: [TwitterArchiveAccount] { TwitterAccounts.all(profileId: profileId, context: context) }
        var aiAccounts: [TwitterArchiveAccount] { TwitterAccounts.aiAccounts(profileId: profileId, context: context) }

        func tweet(_ id: String?) -> TweetEntry? {
            guard let id, !id.isEmpty else { return nil }
            return (try? context.fetch(TwitterQueries.existing(profileId: profileId, tweetId: id)))?.first { !$0.isRemoved }
        }

        func account(handle: String) -> TwitterArchiveAccount? {
            all.first { $0.screenName.caseInsensitiveCompare(handle) == .orderedSame }
        }
    }

    @MainActor
    private static func run(_ action: String, args: [String: Any], actor: TwitterArchiveAccount, ctx: Ctx) throws -> Result {
        let context = ctx.context, pid = ctx.profileId
        let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = min(max((args["limit"] as? Int) ?? 20, 1), 50)

        switch action {
        case "post", "reply", "quote":
            guard !text.isEmpty else { return fail("\(action) 要有 text") }
            var parent: TweetEntry?, quoted: TweetEntry?
            if action != "post" {
                guard let t = ctx.tweet(args["tweet_id"] as? String) else { return noTweet(args) }
                if action == "reply" { parent = t } else { quoted = t }
            }
            let t = try TwitterComposer.post(text: text, replyingTo: parent, quoting: quoted, as: actor,
                                             profileId: pid, context: context)
            let verb = action == "post" ? "发了" : action == "reply" ? "回复了" : "引用了"
            return ok("以 @\(actor.screenName) \(verb)，新推 id：\(t.tweetId)")

        case "like", "unlike":
            guard let t = ctx.tweet(args["tweet_id"] as? String) else { return noTweet(args) }
            let aid = actor.accountId, tid = t.tweetId
            let existing = try context.fetch(FetchDescriptor<TwitterLike>(predicate: #Predicate {
                $0.profileId == pid && $0.accountId == aid && $0.tweetId == tid
            }))
            if action == "like" {
                guard existing.isEmpty else { return ok("@\(actor.screenName) 已经赞过 \(tid) 了") }
                context.insert(TwitterLike(profileId: pid, accountId: aid, tweetId: tid))
                t.favoriteCount += 1
            } else {
                guard !existing.isEmpty else { return ok("@\(actor.screenName) 没赞过 \(tid)") }
                existing.forEach(context.delete)
                t.favoriteCount = max(0, t.favoriteCount - 1)
            }
            try context.save()
            return ok(action == "like" ? "赞了 \(tid)（现在 \(t.favoriteCount) 个赞）" : "取消了对 \(tid) 的赞")

        case "repost":
            guard let t = ctx.tweet(args["tweet_id"] as? String) else { return noTweet(args) }
            let copy = try TwitterTweetActions.repost(t, as: actor, context: context)
            return copy == nil ? ok("@\(actor.screenName) 已经转过这条了") : ok("以 @\(actor.screenName) 转帖了 \(t.tweetId)")

        case "follow", "unfollow":
            guard let h = handleArg(args["handle"]), let target = ctx.account(handle: h) else {
                return fail("本楼层没有这个号。有的号：" + ctx.all.map { "@\($0.screenName)" }.joined(separator: "、"))
            }
            if action == "follow" {
                try TwitterFollows.follow(target, by: actor, context: context)
                return ok("@\(actor.screenName) 关注了 @\(target.screenName)")
            }
            try TwitterFollows.unfollow(target, by: actor, context: context)
            return ok("@\(actor.screenName) 取关了 @\(target.screenName)")

        case "timeline":
            let feed = (args["feed"] as? String) ?? "local"
            let d: FetchDescriptor<TweetEntry>
            if feed == "following" {
                let ids = [actor.accountId] + TwitterFollows.followees(of: actor, context: context)
                d = TwitterQueries.homeTimeline(profileId: pid, accounts: ids, limit: limit)
            } else {
                d = TwitterQueries.localTimeline(profileId: pid, limit: limit)
            }
            return ok(list(try context.fetch(d), ctx: ctx,
                           empty: feed == "following" ? "关注时间线是空的——还没关注谁，或者关注的号都没发推" : "本站还没有推"))

        case "search":
            guard !text.isEmpty else { return fail("search 要在 text 里给关键词") }
            var d = TwitterQueries.search(profileId: pid, keyword: text)
            d.fetchLimit = limit
            return ok(list(try context.fetch(d), ctx: ctx, empty: "没搜到「\(text)」"))

        case "view":
            guard let t = ctx.tweet(args["tweet_id"] as? String) else { return noTweet(args) }
            var out = format(t, ctx: ctx)
            let replies = try context.fetch(TwitterQueries.replies(profileId: pid, to: t.tweetId))
            out += replies.isEmpty ? "\n\n（还没有回复）"
                : "\n\n回复：\n" + replies.prefix(limit).map { format($0, ctx: ctx) }.joined(separator: "\n\n")
            return ok(out)

        case "user":
            guard let h = handleArg(args["handle"]), let a = ctx.account(handle: h) else {
                return fail("本楼层没有这个号。有的号：" + ctx.all.map { "@\($0.screenName)" }.joined(separator: "、"))
            }
            var out = "\(a.displayName) @\(a.screenName)" + (a.ownerKind == TwitterAccounts.ownerAI ? "（AI 的号）" : "")
            if !a.bio.isEmpty { out += "\n简介：\(a.bio)" }
            if !a.location.isEmpty { out += "\n位置：\(a.location)" }
            let count = (try? context.fetchCount(TwitterQueries.countAll(profileId: pid, account: a.accountId))) ?? 0
            out += "\n\(count) 条推"
            out += TwitterFollows.isFollowing(a, by: actor, context: context) ? " · 你关注了" : ""
            let recent = try context.fetch(TwitterQueries.timeline(profileId: pid, account: a.accountId, limit: limit))
            out += "\n\n最近的推：\n" + (recent.isEmpty ? "（没有）" : recent.map { format($0, ctx: ctx) }.joined(separator: "\n\n"))
            return ok(out)

        case "mentions":
            let aid = actor.accountId, at = "@" + actor.screenName
            let handleOpt: String? = actor.screenName
            var d = FetchDescriptor<TweetEntry>(predicate: #Predicate {
                $0.profileId == pid && !$0.isRemoved && $0.accountId != aid && $0.authorScreenName == nil
                    && ($0.inReplyToScreenName == handleOpt || $0.text.localizedStandardContains(at))
            }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            d.fetchLimit = limit
            return ok(list(try context.fetch(d), ctx: ctx, empty: "还没有人 @ 你或回复你"))

        case "accounts":
            return ok("你的号：\n" + ctx.aiAccounts.map {
                "@\($0.screenName)（\($0.displayName)）" + ($0.syncsWithAIProfile ? " · 主号" : "")
            }.joined(separator: "\n"))

        case "create_account":
            let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, let h = handleArg(args["handle"]) else { return fail("create_account 要有 name 和 handle") }
            guard ctx.account(handle: h) == nil else { return fail("@\(h) 已经有人用了") }
            let a = try TwitterAccounts.createAIAccount(displayName: name, screenName: h, profileId: pid, context: context)
            return ok("开了新号 @\(a.screenName)（\(a.displayName)）。用它发推就在 as 里填 \(a.screenName)")

        default:
            return fail("action 只能是：\(actions.joined(separator: " / "))")
        }
    }

    // MARK: - 输出

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 一条推给 AI 看的样子：id、谁、什么时候、计数、回复/引用/转帖关系、正文。
    @MainActor
    private static func format(_ t: TweetEntry, ctx: Ctx) -> String {
        let owner = ctx.all.first { $0.accountId == t.accountId }
        let who: String
        if let h = t.authorScreenName {
            who = "@\(h)（\(t.authorName ?? h)，X 上的人）"
        } else if let owner {
            who = "@\(owner.screenName)（\(owner.displayName)\(owner.ownerKind == TwitterAccounts.ownerAI ? "，AI" : "")）"
        } else {
            who = "（未知账号）"
        }
        var head = "#\(t.tweetId) \(who) · \(stamp.string(from: t.createdAt)) · ♥\(t.favoriteCount) ⟲\(t.retweetCount)"
        if let r = t.inReplyToScreenName { head += " · 回复 @\(r)" }
        if let q = t.quotedTweetId { head += " · 引用 #\(q)" }
        if let o = t.repostOfTweetId { head += " · 转帖自 #\(o)（原作者 @\(t.retweetedScreenName ?? "?")）" }
        if t.mediaCount > 0 { head += " · \(t.mediaCount) 张图" }
        return head + "\n" + t.text
    }

    @MainActor
    private static func list(_ rows: [TweetEntry], ctx: Ctx, empty: String) -> String {
        rows.isEmpty ? empty : rows.map { format($0, ctx: ctx) }.joined(separator: "\n\n")
    }

    private static func handleArg(_ any: Any?) -> String? {
        guard var h = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        while h.hasPrefix("@") { h.removeFirst() }
        return h.isEmpty ? nil : h
    }

    private static func ok(_ text: String) -> Result { Result(text: text, isError: false) }
    private static func fail(_ text: String) -> Result { Result(text: text, isError: true) }
    private static func noTweet(_ args: [String: Any]) -> Result {
        fail("找不到推文 \(args["tweet_id"] as? String ?? "（没给 tweet_id）")。先用 timeline / search 拿到 id")
    }
}
