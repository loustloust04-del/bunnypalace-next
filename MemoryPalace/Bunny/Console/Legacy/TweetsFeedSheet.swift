#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI

/// 推文流 — 控制台「给世界的」卡点开进入。拉网关同步好的推文（含配图识别）。
struct TweetsFeedSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tweets: [TweetsClient.Tweet] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if loading {
                        ProgressView().padding(.top, 40)
                    } else if tweets.isEmpty {
                        Text("还没有同步到推文")
                            .font(.system(size: 13.5)).foregroundColor(ConsoleView.textFaint)
                            .padding(.top, 40)
                    } else {
                        ForEach(tweets) { t in tweetCard(t) }
                    }
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 16).padding(.top, 12)
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("给世界的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        tweets = await TweetsClient.fetch(limit: 40)
        loading = false
    }

    private func tweetCard(_ t: TweetsClient.Tweet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.text)
                .font(.system(size: 15))
                .foregroundColor(ConsoleView.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let desc = t.imageDesc, !desc.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 11)).foregroundColor(ConsoleView.green)
                    Text(desc)
                        .font(.system(size: 12)).foregroundColor(ConsoleView.textSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(ConsoleView.sink))
            }
            HStack(spacing: 8) {
                Text(String(t.ts.prefix(16)))
                    .font(.system(size: 11)).foregroundColor(ConsoleView.textMuted)
                ForEach(t.tags.prefix(3), id: \.self) { tag in
                    Text("#\(tag)").font(.system(size: 10.5)).foregroundColor(ConsoleView.greenDeep)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.mainBg))
    }
}
#endif
