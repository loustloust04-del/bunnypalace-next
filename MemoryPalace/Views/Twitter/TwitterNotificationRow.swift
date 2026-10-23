import SwiftUI

/// 通知箱的一行，仿推特：左边类型图标，右边「谁的头像 + 谁 干了什么」，下面是那条推。
/// 回复 / 引用 / @ 显示对方那条的正文（推特也是整条露出来）；赞 / 转帖显示被赞的我那条，灰字。
struct TwitterNotificationRow: View {
    let item: TwitterNotifications.Item
    let actor: TwitterArchiveAccount?
    let mediaDir: URL
    let accent: Color
    var unread = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 6) {
                TwitterAvatarView(account: actor, mediaDir: mediaDir, size: 32, accent: accent)
                (Text(actor?.displayName ?? "有人").bold() + Text(" \(verb)"))
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    + Text(" · \(TwitterStamp.short(item.date))").font(.system(size: 15)).foregroundStyle(Theme.textMuted)
                if let t = item.tweet, !t.text.isEmpty {
                    Text(t.text)
                        .font(.system(size: 15))
                        .foregroundStyle(showsTheirWords ? Theme.textPrimary : Theme.textMuted)
                        .lineLimit(showsTheirWords ? 8 : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(unread ? accent.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }

    private var showsTheirWords: Bool { [.reply, .quote, .mention].contains(item.kind) }

    private var verb: String {
        switch item.kind {
        case .like: "赞了你的帖子"
        case .reply: "回复了你"
        case .quote: "引用了你的帖子"
        case .repost: "转帖了你的帖子"
        case .mention: "提到了你"
        case .follow: "关注了你"
        }
    }

    private var icon: String {
        switch item.kind {
        case .like: "heart.fill"
        case .reply: "bubble.left.fill"
        case .quote: "quote.bubble.fill"
        case .repost: "arrow.2.squarepath"
        case .mention: "at"
        case .follow: "person.fill"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .like: Theme.favorite
        case .repost: TweetRowView.repostGreen
        default: accent
        }
    }
}
