import SwiftUI

/// 时间线的一行。仿推特：左头像 + 「名字 @handle · 时间」同一行 + 正文 + 媒体 + 互动行。
/// 形态是粟粟看过 HTML 仿版后定的（2026-09-21）。
struct TweetRowView: View {
    let tweet: TweetEntry
    let media: [TweetMedia]
    let account: TwitterArchiveAccount?
    let mediaDir: URL
    let accent: Color
    /// 引用推文里被引用的那条（面板按页批量取好传进来）
    var quoted: TweetEntry? = nil
    var quotedMedia: [TweetMedia] = []
    /// 转帖人不是当前账号时（本站里别的号、AI 的号转的）显示「某某 转帖了」，是自己就「你已转帖」
    var repostedBy: String? = nil
    /// 点头像 / 名字 → 进主页（推特就是这样）
    var onOpenProfile: () -> Void = {}
    var onReply: () -> Void = {}
    var onLike: () -> Void = {}
    var onRepost: () -> Void = {}
    var onQuote: () -> Void = {}
    var onBookmark: () -> Void = {}
    var onDelete: () -> Void = {}
    /// 非 nil = 这条能改（自己号的原创推），「…」菜单里出「编辑」
    var onEdit: (() -> Void)? = nil
    /// 直接回复有几条，显示在回复图标旁边（跟赞数一样）
    var replyCount = 0
    /// 回复串里的连线（粟粟 2026-09-25：多层回复要一根线串下来）：头像上方接上一条、下方接下一条
    var threadAbove = false
    var threadBelow = false

    static let threadColor = Theme.textMuted.opacity(0.35)

    /// 推特转帖用的绿
    static let repostGreen = Color(red: 0, green: 0.729, blue: 0.486)

    @State private var confirmingDelete = false
    @Environment(\.openURL) private var openURL

    /// X 上的原帖（粟粟 2026-09-24：每条帖子带原帖链接）。App 里自己发的没有
    private var xURL: URL? { tweet.xURL(ownHandle: account?.screenName) }

    /// 转推（存档里的 RT，或应用里点的转帖）：身份行显示原作者
    private var isRepost: Bool { tweet.retweetedScreenName != nil }
    /// 原作者是不是自己（自己的推、自己转自己的推）；别人的推（书签/赞拉下来的、转别人的）不是
    private var authorIsMe: Bool {
        guard let rt = tweet.originalAuthorHandle else { return true }
        return rt == account?.screenName
    }
    private var authorName: String {
        !authorIsMe ? (tweet.originalAuthorName ?? tweet.originalAuthorHandle ?? "") : (account?.displayName ?? "我")
    }
    private var authorHandle: String? {
        tweet.originalAuthorHandle ?? account?.screenName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isRepost {
                Label(repostedBy.map { "\($0) 转帖了" } ?? "你已转帖", systemImage: "arrow.2.squarepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.leading, 30)
            }
            HStack(alignment: .top, spacing: 10) {
                Button(action: onOpenProfile) {
                    TwitterAvatarView(account: account, mediaDir: mediaDir, size: 40, accent: accent,
                                      otherName: authorIsMe ? nil : authorName)
                }
                .buttonStyle(.plain)
                .disabled(!authorIsMe)   // 别人没有主页可进
                .accessibilityLabel("看主页")

                VStack(alignment: .leading, spacing: 0) {
                    identityLine
                    if let who = tweet.inReplyToScreenName, !who.isEmpty {
                        HStack(spacing: 3) {
                            Text("回复")
                            Text("@\(who)").foregroundStyle(accent)
                        }
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.top, 2)
                    }
                    if !tweet.text.isEmpty {
                        Text(tweet.text)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    if !media.isEmpty { TweetMediaGrid(media: media, mediaDir: mediaDir).padding(.top, 10) }
                    if let quoted { quoteCard(quoted).padding(.top, 10) }
                    actionRow.padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // 连线画在 overlay 里，不动行本身的布局：overlay 拿到的就是整行的高，线能一直接到行底
        .overlay(alignment: .topLeading) {
            if (threadAbove || threadBelow) && !isRepost {
                VStack(spacing: 0) {
                    Rectangle().fill(threadAbove ? Self.threadColor : .clear).frame(width: 2, height: 10)
                    Color.clear.frame(width: 2, height: 44)   // 头像 40，上下各让 2
                    Rectangle().fill(threadBelow ? Self.threadColor : .clear).frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
                .padding(.leading, 16 + 19)
                .allowsHitTesting(false)
            }
        }
        // VStack/HStack 默认无 hit shape，空白处会穿透到底下层（项目踩过）
        .contentShape(Rectangle())
        .confirmationDialog("删除这条推文？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive, action: onDelete)
        } message: {
            Text("删了就不在时间线上了。重新导入存档也不会再冒出来。")
        }
    }

    /// 「名字 @handle · 2h」挤在一行——这行是「像推特」最关键的一处。
    private var identityLine: some View {
        HStack(spacing: 4) {
            Button(action: onOpenProfile) {
                HStack(spacing: 4) {
                    Text(authorName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let handle = authorHandle, !handle.isEmpty {
                        Text("@\(handle)")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!authorIsMe)
            Text("·").font(.system(size: 15)).foregroundStyle(Theme.textMuted)
            Text(TwitterStamp.short(tweet.createdAt))
                .font(.system(size: 15))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
            if tweet.editedAt != nil {
                // 推特改过的推时间旁边有支笔
                Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .accessibilityLabel("已编辑")
            }
            Spacer(minLength: 0)
            Menu {
                if let xURL {
                    Button("在 X 上打开", systemImage: "arrow.up.right.square") { openURL(xURL) }
                    Button("复制链接", systemImage: "link") { TwitterClipboard.copy(xURL); TwitterHaptics.light() }
                }
                if let onEdit { Button("编辑", systemImage: "pencil", action: onEdit) }
                Button("删除", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 28, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多")
        }
    }

    /// 引用卡片：圆角描边框里放被引用那条的作者行 + 正文 + 第一张图。
    private func quoteCard(_ q: TweetEntry) -> some View {
        let qIsMe = q.originalAuthorHandle == nil || q.originalAuthorHandle == account?.screenName
        let qName = qIsMe ? (account?.displayName ?? "我") : (q.originalAuthorName ?? q.originalAuthorHandle ?? "")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TwitterAvatarView(account: account, mediaDir: mediaDir, size: 20, accent: accent,
                                  otherName: qIsMe ? nil : qName)
                Text(qName).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("· \(TwitterStamp.short(q.createdAt))").font(.system(size: 14))
                    .foregroundStyle(Theme.textMuted).fixedSize()
            }
            if !q.text.isEmpty {
                Text(q.text).font(.system(size: 14)).foregroundStyle(Theme.textPrimary).lineLimit(6)
            }
            if let first = quotedMedia.first {
                TwitterMediaImage(url: mediaDir.appendingPathComponent(first.fileName))
                    .frame(maxWidth: .infinity).frame(height: 140).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.textMuted.opacity(0.3)))
    }

    /// 互动行：回复 / 转发 / 赞。浏览量存档不给，不画——不编假数字。
    private var actionRow: some View {
        // 转帖行本身就代表「我转过」；原推看自己的 retweetedByMe
        let reposted = tweet.retweetedByMe || tweet.repostOfTweetId != nil
        return HStack(spacing: 0) {
            Button(action: onReply) { metric(system: "bubble.left", value: replyCount, tint: accent) }
                .buttonStyle(.plain)
                .accessibilityLabel("回复")
            // 推特点转推弹两个选项：转帖 / 引用
            Menu {
                Button(reposted ? "撤销转帖" : "转帖", systemImage: "arrow.2.squarepath", action: onRepost)
                Button("引用", systemImage: "square.and.pencil", action: onQuote)
            } label: {
                metric(system: "arrow.2.squarepath", value: tweet.retweetCount, tint: Self.repostGreen, lit: reposted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("转发")
            Button(action: onLike) {
                metric(system: tweet.likedByMe ? "heart.fill" : "heart", value: tweet.favoriteCount,
                       tint: Theme.favorite, lit: tweet.likedByMe)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tweet.likedByMe ? "取消赞" : "赞")
            Spacer(minLength: 0)
            // 书签在推特互动行的最右边
            Button(action: onBookmark) {
                Image(systemName: tweet.bookmarkedAt == nil ? "bookmark" : "bookmark.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(tweet.bookmarkedAt == nil ? Theme.textMuted : accent)
                    .frame(width: 32, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tweet.bookmarkedAt == nil ? "加书签" : "取消书签")
            // 分享：推特互动行最右边那个，分享的就是原帖链接
            if let xURL {
                ShareLink(item: xURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 32, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("分享原帖链接")
            }
        }
    }

    /// `lit`：自己点过的才上色；别人给的数只显示数字，图标保持灰（推特的样子）。
    private func metric(system: String, value: Int, tint: Color, lit: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: system).font(.system(size: 13))
            if value > 0 { Text("\(value)").font(.system(size: 12)) }
        }
        .foregroundStyle(lit ? tint : Theme.textMuted)
        .frame(width: 70, height: 24, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 一条推的图：一张给大图，多张走两列网格。点哪张就从哪张进全屏，能左右划（粟粟 2026-09-27）。
struct TweetMediaGrid: View {
    let media: [TweetMedia]
    let mediaDir: URL

    @State private var viewing: ViewerStart?

    var body: some View {
        grid
            .twitterMediaViewer(item: $viewing, media: media, mediaDir: mediaDir)
    }

    @ViewBuilder private var grid: some View {
        if media.count == 1 {
            TwitterMediaImage(url: mediaDir.appendingPathComponent(media[0].fileName))
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { viewing = ViewerStart(index: 0) }
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
                      spacing: 4) {
                ForEach(Array(media.enumerated()), id: \.element.mediaId) { i, m in
                    TwitterMediaImage(url: mediaDir.appendingPathComponent(m.fileName))
                        .frame(height: 110)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { viewing = ViewerStart(index: i) }
                }
            }
        }
    }
}

/// 从第几张开始看全屏。
struct ViewerStart: Identifiable {
    let index: Int
    var id: Int { index }
}

extension View {
    /// iOS 全屏盖上去；macOS 没有 fullScreenCover，用大 sheet。
    func twitterMediaViewer(item: Binding<ViewerStart?>, media: [TweetMedia], mediaDir: URL) -> some View {
        #if os(iOS)
        fullScreenCover(item: item) { start in
            TwitterMediaViewer(media: media, mediaDir: mediaDir, index: start.index) { item.wrappedValue = nil }
        }
        #else
        sheet(item: item) { start in
            TwitterMediaViewer(media: media, mediaDir: mediaDir, index: start.index) { item.wrappedValue = nil }
                .frame(minWidth: 720, minHeight: 540)
        }
        #endif
    }
}
