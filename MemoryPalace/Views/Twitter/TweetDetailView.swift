import SwiftUI
import SwiftData
import AVKit

/// 单条推文详情。仿推特的会话页：上级链（一根线串下来）→ 这条（大字）→ 完整时间 → 计数 → 动作条
/// → 直接回复，每条回复下面挂它的第一条下级。点任何一条都推进它自己的详情，照样能看见上级和下级。
struct TweetDetailView: View {
    let tweet: TweetEntry
    let media: [TweetMedia]
    let account: TwitterArchiveAccount?
    let mediaDir: URL
    var accent: Color = TwitterAccent.color(fromHex: TwitterAccent.defaultHex)
    var onOpenProfile: () -> Void = {}
    /// 回复各有各的作者（粟粟回 AI 的推，不能显示成 AI 自己回自己）：按回复自己的 accountId 找号
    var authorOf: (TweetEntry) -> TwitterArchiveAccount? = { _ in nil }
    var onOpenProfileOf: (TweetEntry) -> Void = { _ in }
    /// 当前账号：回复/引用框里显示的是「我」，不是这条推的作者
    var me: TwitterArchiveAccount? = nil
    /// 关掉整个详情（推了几层也一起关）：去主页、去搜索时用
    var closeAll: (() -> Void)? = nil
    var onSearch: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    /// 回复 / 赞 / 删了回复之后通知外面刷新时间线
    var onChanged: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var ancestors: [TweetEntry] = []
    @State private var branches: [TwitterThread.Branch] = []
    @State private var rowMedia: [String: [TweetMedia]] = [:]
    @State private var replyCounts: [String: Int] = [:]
    /// 点了串里的某一条 → 推进它的详情
    @State private var pushed: TweetEntry?
    @State private var viewing: ViewerStart?
    /// 在改哪条（这条或串里自己的某条）
    @State private var editingTweet: TweetEntry?
    @State private var replyingTo: TweetEntry?
    @State private var quoting: TweetEntry?
    @State private var quoted: TweetEntry?
    @State private var quotedMedia: [TweetMedia] = []
    @State private var confirmingDelete = false
    @State private var errorText: String?

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "HH:mm · yyyy年M月d日"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 上级链：每条之间一根线，最后一根接到这条的头像上
                    ForEach(ancestors, id: \.persistentModelID) { a in
                        row(a, above: a.tweetId != ancestors.first?.tweetId, below: true)
                    }
                    main
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .padding(.top, ancestors.isEmpty ? 16 : 0)
                        .id("focal")
                    Divider().opacity(0.4)
                    ForEach(branches) { b in
                        row(b.reply, above: false, below: b.firstChild != nil)
                        if let c = b.firstChild {
                            row(c, above: true, below: false)
                            if b.moreCount > 0 {
                                Button("显示另外 \(b.moreCount) 条回复") { pushed = b.reply }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 15))
                                    .foregroundStyle(accent)
                                    .padding(.leading, 66)
                                    .padding(.bottom, 12)
                            }
                        }
                        Divider().opacity(0.4)
                    }
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(Theme.danger).padding(16)
                    }
                    // 上级链长的时候，也要能把这条滚到顶上
                    Color.clear.frame(height: ancestors.isEmpty ? 0 : 400)
                }
            }
            .onAppear {
                reload()
                // 推特进会话页是停在这条上，上级在上面，往上翻才看见
                if !ancestors.isEmpty { proxy.scrollTo("focal", anchor: .top) }
            }
        }
        .background(Theme.mainBg)
        #if os(iOS)
        .navigationTitle("帖子")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $pushed) { t in pushedDetail(t) }
        .twitterMediaViewer(item: $viewing, media: media, mediaDir: mediaDir)
        .sheet(item: $replyingTo) { parent in
            TwitterComposeView(account: me ?? account, mediaDir: mediaDir, accent: accent, replyingTo: parent,
                               parentAuthor: authorOf(parent), profileId: tweet.profileId,
                               onPost: { post($0, images: $1, replyingTo: parent) },
                               onCancel: { replyingTo = nil })
        }
        .sheet(item: $quoting) { q in
            TwitterComposeView(account: me ?? account, mediaDir: mediaDir, accent: accent, quoting: q,
                               parentAuthor: authorOf(q), profileId: tweet.profileId,
                               onPost: { post($0, images: $1, quoting: q) },
                               onCancel: { quoting = nil })
        }
        .sheet(item: $editingTweet) { t in
            TwitterComposeView(account: authorOf(t) ?? me, mediaDir: mediaDir, accent: accent, editing: t,
                               onPost: { text, _ in saveEdit(t, text) },
                               onCancel: { editingTweet = nil })
        }
        .confirmationDialog("删除这条推文？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { onDelete(); dismiss() }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !ancestors.isEmpty {
                // 上一条的线接到这条头像上。头像跟串里每行一样 40 宽，线的 x 跟行里的线完全一致
                // （粟粟 2026-09-25 真机：原来 44 宽，中心差 2pt，线接不上）
                Rectangle().fill(TweetRowView.threadColor).frame(width: 2, height: 10)
                    .padding(.leading, 19)
                    .padding(.bottom, -10)   // 跟行里一样，线到头像前留 2pt
            }
            HStack(spacing: 10) {
                Button(action: openProfile) {
                    HStack(spacing: 10) {
                        TwitterAvatarView(account: account, mediaDir: mediaDir, size: 40, accent: accent,
                                          otherName: authorIsMe ? nil : authorName)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(authorName)
                                .font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.textPrimary)
                            if let handle = tweet.originalAuthorHandle ?? account?.screenName, !handle.isEmpty {
                                Text("@\(handle)").font(.system(size: 15)).foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!authorIsMe)
                Spacer()
                Menu {
                    if TwitterTweetActions.canEdit(tweet, owner: account) {
                        Button("编辑", systemImage: "pencil") { editingTweet = tweet }
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15))
                        .foregroundStyle(Theme.textMuted).frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if let who = tweet.inReplyToScreenName, !who.isEmpty {
                HStack(spacing: 3) {
                    Text("回复")
                    Text("@\(who)").foregroundStyle(accent)
                }
                .font(.subheadline).foregroundStyle(Theme.textMuted)
            }

            Text(tweet.text)
                .font(.system(size: 19))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            ForEach(Array(media.enumerated()), id: \.element.mediaId) { i, m in
                let url = mediaDir.appendingPathComponent(m.fileName)
                Group {
                    if url.pathExtension.lowercased() == "mp4" {
                        // 视频 / 动图：详情页里能播
                        VideoPlayer(player: AVPlayer(url: url))
                            .aspectRatio(m.width > 0 && m.height > 0 ? CGFloat(m.width) / CGFloat(m.height) : 16 / 9,
                                         contentMode: .fit)
                    } else {
                        TwitterMediaImage(url: url, contentMode: .fit)
                            .contentShape(Rectangle())
                            .onTapGesture { viewing = ViewerStart(index: i) }
                    }
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let quoted {
                // 引用卡片点进去不做（sheet 里再套 sheet 太深），这里就完整展示
                VStack(alignment: .leading, spacing: 6) {
                    Text(quoted.originalAuthorName ?? account?.displayName ?? "我")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text(quoted.text).font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                    if !quotedMedia.isEmpty { TweetMediaGrid(media: quotedMedia, mediaDir: mediaDir) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.textMuted.opacity(0.3)))
            }

            // 话题标签点了去搜（推特点标签是进搜索结果）
            if !tweet.hashtagsJoined.isEmpty {
                HStack(spacing: 10) {
                    ForEach(tweet.hashtagsJoined.split(separator: " ").map(String.init), id: \.self) { tag in
                        Button("#\(tag)") { onSearch(tag); closeEverything() }
                            .buttonStyle(.plain).font(.subheadline).foregroundStyle(accent)
                    }
                }
            }

            HStack(spacing: 4) {
                Text(Self.stamp.string(from: tweet.createdAt))
                if let edited = tweet.editedAt {
                    Text("· 已编辑 \(Self.stamp.string(from: edited))")
                }
            }
            .font(.system(size: 15)).foregroundStyle(Theme.textMuted)

            // 原帖链接：X 上真有的推才有
            if let url = tweet.xURL(ownHandle: account?.screenName) {
                HStack(spacing: 14) {
                    Button { openURL(url) } label: {
                        Label("在 X 上查看原帖", systemImage: "arrow.up.right.square")
                    }
                    Button { TwitterClipboard.copy(url); TwitterHaptics.light() } label: {
                        Label("复制链接", systemImage: "link")
                    }
                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(accent)
            }

            Divider().opacity(0.4)
            HStack(spacing: 18) {
                stat(tweet.retweetCount, "转推")
                stat(tweet.favoriteCount, "喜欢")
                if !branches.isEmpty { stat(branches.count, "回复") }
            }
            Divider().opacity(0.4)

            HStack {
                Button { replyingTo = tweet } label: { barIcon("bubble.left", tint: Theme.textMuted) }
                    .accessibilityLabel("回复")
                Spacer()
                Menu {
                    Button(reposted ? "撤销转帖" : "转帖", systemImage: "arrow.2.squarepath") { repost(tweet) }
                    Button("引用", systemImage: "square.and.pencil") { quoting = tweet }
                } label: {
                    barIcon("arrow.2.squarepath", tint: reposted ? TweetRowView.repostGreen : Theme.textMuted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("转发")
                Spacer()
                Button { like(tweet) } label: {
                    barIcon(tweet.likedByMe ? "heart.fill" : "heart",
                            tint: tweet.likedByMe ? Theme.favorite : Theme.textMuted)
                }
                .accessibilityLabel(tweet.likedByMe ? "取消赞" : "赞")
                Spacer()
                Button { bookmark(tweet) } label: {
                    barIcon(tweet.bookmarkedAt == nil ? "bookmark" : "bookmark.fill",
                            tint: tweet.bookmarkedAt == nil ? Theme.textMuted : accent)
                }
                .accessibilityLabel(tweet.bookmarkedAt == nil ? "加书签" : "取消书签")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
    }

    private var reposted: Bool { tweet.retweetedByMe || tweet.repostOfTweetId != nil }
    private var authorIsMe: Bool {
        tweet.originalAuthorHandle == nil || tweet.originalAuthorHandle == account?.screenName
    }
    private var authorName: String {
        authorIsMe ? (account?.displayName ?? "我") : (tweet.originalAuthorName ?? tweet.originalAuthorHandle ?? "")
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text("\(n)").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(.system(size: 15)).foregroundStyle(Theme.textMuted)
        }
    }

    private func barIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name).font(.system(size: 19)).foregroundStyle(tint)
            .frame(width: 44, height: 36).contentShape(Rectangle())
    }

    // MARK: - 动作

    private func openProfile() {
        onOpenProfile()
        closeEverything()
    }

    private func closeEverything() {
        if let closeAll { closeAll() } else { dismiss() }
    }

    /// 串里的一行：点整行推进详情，点头像去那条作者的主页
    private func row(_ t: TweetEntry, above: Bool, below: Bool) -> some View {
        TweetRowView(tweet: t, media: rowMedia[t.tweetId] ?? [], account: authorOf(t),
                     mediaDir: mediaDir, accent: accent,
                     onOpenProfile: { onOpenProfileOf(t); closeEverything() },
                     onReply: { replyingTo = t },
                     onLike: { like(t) },
                     onRepost: { repost(t) },
                     onQuote: { quoting = t },
                     onBookmark: { bookmark(t) },
                     onDelete: { remove(t) },
                     onEdit: TwitterTweetActions.canEdit(t, owner: authorOf(t)) ? { editingTweet = t } : nil,
                     replyCount: replyCounts[t.tweetId] ?? 0,
                     threadAbove: above, threadBelow: below)
            .onTapGesture { pushed = t }
    }

    private func pushedDetail(_ t: TweetEntry) -> TweetDetailView {
        let media = (try? modelContext.fetch(TwitterQueries.media(profileId: t.profileId, tweetIds: [t.tweetId]))) ?? []
        return TweetDetailView(tweet: t, media: media, account: authorOf(t), mediaDir: mediaDir, accent: accent,
                               onOpenProfile: { onOpenProfileOf(t) },
                               authorOf: authorOf, onOpenProfileOf: onOpenProfileOf,
                               me: me, closeAll: closeAll ?? { dismiss() },
                               onSearch: onSearch,
                               onDelete: { remove(t) },
                               onChanged: { reload(); onChanged() })
    }

    private func reload() {
        ancestors = TwitterThread.ancestors(of: tweet, context: modelContext)
        branches = TwitterThread.branches(under: tweet, context: modelContext)
        var ids = ancestors.map(\.tweetId)
        for b in branches {
            ids.append(b.reply.tweetId)
            if let c = b.firstChild { ids.append(c.tweetId) }
        }
        replyCounts = TwitterThread.replyCounts(for: ids, profileId: tweet.profileId, context: modelContext)
        rowMedia = [:]
        if !ids.isEmpty {
            for m in (try? modelContext.fetch(TwitterQueries.media(profileId: tweet.profileId, tweetIds: ids))) ?? [] {
                rowMedia[m.tweetId, default: []].append(m)
            }
        }
        loadQuoted()
    }

    private func loadQuoted() {
        guard let qid = tweet.quotedTweetId else { return }
        let pid = tweet.profileId
        quoted = try? modelContext.fetch(TwitterQueries.tweets(profileId: pid, ids: [qid])).first
        quotedMedia = (try? modelContext.fetch(TwitterQueries.media(profileId: pid, tweetIds: [qid]))) ?? []
    }

    private func saveEdit(_ t: TweetEntry, _ text: String) {
        do {
            try TwitterTweetActions.edit(t, text: text, context: modelContext)
            editingTweet = nil
            TwitterHaptics.success()
            reload()
            onChanged()
        } catch { errorText = "改不了：\(error.localizedDescription)"; TwitterHaptics.failure() }
    }

    private func repost(_ t: TweetEntry) {
        do { try TwitterTweetActions.toggleRepost(t, context: modelContext); TwitterHaptics.medium(); onChanged() }
        catch { errorText = "没转上：\(error.localizedDescription)" }
    }

    private func bookmark(_ t: TweetEntry) {
        do { try TwitterTweetActions.toggleBookmark(t, context: modelContext); TwitterHaptics.light(); onChanged() }
        catch { errorText = "没加上：\(error.localizedDescription)" }
    }

    private func like(_ t: TweetEntry) {
        do { try TwitterTweetActions.toggleLike(t, context: modelContext); TwitterHaptics.light(); onChanged() }
        catch { errorText = "没点上：\(error.localizedDescription)" }
    }

    private func remove(_ t: TweetEntry) {
        do { try TwitterTweetActions.remove(t, context: modelContext); TwitterHaptics.medium(); reload(); onChanged() }
        catch { errorText = "删不掉：\(error.localizedDescription)" }
    }

    private func post(_ text: String, images: [Data], replyingTo parent: TweetEntry? = nil,
                      quoting q: TweetEntry? = nil) {
        do {
            try TwitterComposer.post(text: text, images: images, mediaDir: mediaDir,
                                     replyingTo: parent, quoting: q,
                                     profileId: tweet.profileId, context: modelContext)
            replyingTo = nil
            quoting = nil
            TwitterHaptics.success()
            reload()
            onChanged()
        } catch { errorText = "发不出去：\(error.localizedDescription)" }
    }
}
