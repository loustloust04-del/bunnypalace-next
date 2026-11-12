#if os(iOS)
// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植的 Caelum's Console 页面（用户 11-12：先一比一还原，之后再美化）。
import SwiftUI

/// 留言板 · 你和 Caelum 的双人小纸条（帖子 + 回复串）。
/// 数据直连网关 /api/board（与 Caelum 的 board_* 工具同一份）。
/// 你发帖 = bunny，Caelum 发帖/回复 = caelum。长按可删。
struct MemoBoardView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var posts: [BoardClient.Post] = []
    @State private var loading = true
    @State private var sending = false
    @State private var draft = ""
    @State private var replyingTo: String? = nil
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        if loading {
                            ProgressView().padding(.vertical, 50)
                        } else if posts.isEmpty {
                            Text("还没有纸条\n给 Caelum 留句话吧，她也会回你 💌")
                                .font(.system(size: 13.5))
                                .foregroundColor(ConsoleView.textFaint)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 60)
                        } else {
                            ForEach(Array(posts.reversed())) { post in
                                postCard(post)
                            }
                        }
                        Color.clear.frame(height: 12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                composer
            }
            .background(Theme.sidebarBg.ignoresSafeArea())
            .navigationTitle("留言板")
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
        // 先亮出上次的（秒开），网关回来了再无声替换
        await BoardClient.fetchCached { list, _ in posts = list; loading = false }
        loading = false
    }

    // MARK: - 帖子卡

    private func postCard(_ post: BoardClient.Post) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                authorBadge(post.by)
                Text(timeText(post.ts)).font(.system(size: 10.5)).foregroundColor(ConsoleView.textFaint)
                Spacer()
            }
            Text(post.text)
                .font(.system(size: 14.5))
                .foregroundColor(ConsoleView.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button(role: .destructive) {
                    Task { _ = await BoardClient.deletePost(id: post.id); await reload() }
                } label: { Label("删除这条", systemImage: "trash") }
            }

            if !post.replies.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(post.replies) { r in
                        HStack(alignment: .top, spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(ConsoleView.line).frame(width: 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    authorBadge(r.by)
                                    Text(timeText(r.ts)).font(.system(size: 10)).foregroundColor(ConsoleView.textFaint)
                                }
                                Text(r.text).font(.system(size: 13.5)).foregroundColor(ConsoleView.textSub)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task { _ = await BoardClient.deleteReply(postId: post.id, replyId: r.id); await reload() }
                                } label: { Label("删除回复", systemImage: "trash") }
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.leading, 4)
            }

            Button {
                replyingTo = post.id
                composerFocused = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 11))
                    Text("回复").font(.system(size: 12))
                }
                .foregroundColor(ConsoleView.greenDeep)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.mainBg))
    }

    private func authorBadge(_ by: String) -> some View {
        let isC = by == "caelum"
        return Text(isC ? "Caelum" : "你")
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((isC ? ConsoleView.greenDeep : ConsoleView.gold).opacity(0.16)))
            .foregroundColor(isC ? ConsoleView.greenDeep : ConsoleView.gold)
    }

    // MARK: - 输入条

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().background(ConsoleView.line)
            if replyingTo != nil {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 10)).foregroundColor(ConsoleView.greenDeep)
                    Text("回复中…").font(.system(size: 12)).foregroundColor(ConsoleView.textMuted)
                    Spacer()
                    Button { replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(ConsoleView.textFaint)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            HStack(spacing: 10) {
                TextField(replyingTo == nil ? "写张小纸条…" : "回复…", text: $draft, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(ConsoleView.sink))
                Button {
                    Task { await send() }
                } label: {
                    if sending {
                        ProgressView().tint(ConsoleView.greenDeep)
                    } else {
                        Image(systemName: "paperplane.fill").font(.system(size: 18))
                            .foregroundColor(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ConsoleView.textFaint : ConsoleView.greenDeep)
                    }
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Theme.mainBg)
    }

    private func send() async {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sending = true
        if let pid = replyingTo {
            _ = await BoardClient.reply(postId: pid, text: t)
        } else {
            _ = await BoardClient.post(text: t)
        }
        draft = ""
        replyingTo = nil
        sending = false
        composerFocused = false
        await reload()
    }

    // MARK: - helpers

    private func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
    private func timeText(_ iso: String) -> String {
        guard let d = parseISO(iso) else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm" }
        else if cal.isDateInYesterday(d) { return "昨天 " + { let g = DateFormatter(); g.dateFormat = "HH:mm"; return g.string(from: d) }() }
        else { f.dateFormat = "M月d日 HH:mm" }
        return f.string(from: d)
    }
}
#endif
