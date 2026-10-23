import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// page2「推特」子应用：导入官方导出包，离线还原自己的时间线。
///
/// 版面仿推特（粟粟 2026-09-21 看过 HTML 仿版后定的）：左头像的行、
/// 「名字 @handle · 时间」同一行、下划线 tab、右下角发推钮、底部导航。
struct TwitterPanelView: View {
    let profileId: String

    private enum Section: String { case home, search, notifications, media, profile, bookmarks }

    @Environment(\.modelContext) private var modelContext
    @Environment(RightPanelNavigator.self) private var navigator: RightPanelNavigator?
    /// 强调色默认推特蓝，**有意偏离项目「不要蓝色」的规则**，见 TwitterAccent 的注释。
    @AppStorage("twitter.accentHex") private var accentHex = TwitterAccent.defaultHex

    @State private var vm: TwitterPanelViewModel?
    @State private var section = Section.home
    @State private var picking = false
    @State private var phase: TwitterImportPhase?
    @State private var fraction: Double = 0
    @State private var lastResult: TwitterImportResult?
    @State private var errorText: String?
    @State private var keyword = ""
    @State private var detail: TweetEntry?
    @State private var composing = false
    @State private var quoting: TweetEntry?
    @State private var editingProfile = false
    @State private var demoInstalled = false
    @State private var tuningColor = false
    @State private var drawerOpen = false
    @State private var managingAccounts = false
    @State private var bookmarkFolders: [TwitterBookmarkFolder] = []
    /// 通知箱（粟粟 2026-09-25）：现算的列表 + 这次进通知页之前看到哪儿（新的那几条标底色）
    @State private var notifications: [TwitterNotifications.Item] = []
    @State private var notificationsSeen = Date.distantPast
    @State private var highlightSince = Date.distantFuture
    /// 主页点了「正在关注」(true) / 「关注者」(false)
    @State private var followList: FollowListKind?
    /// 草稿箱（粟粟 2026-09-27）
    @State private var showingDrafts = false
    /// 从草稿接着写：跟着打开的那个框（新推 / 引用 / 回复）一起用
    @State private var resumeDraft: TwitterDraft?
    /// 从回复草稿打开的回复框（平时回复在详情页里，这里只给草稿用）
    @State private var replyingFromDraft: TweetEntry?
    /// 在改哪条
    @State private var editingTweet: TweetEntry?

    private enum FollowListKind: String, Identifiable { case following, followers; var id: String { rawValue } }

    private var accent: Color { TwitterAccent.color(fromHex: accentHex) }
    private var mediaDir: URL {
        TwitterArchiveImporter.defaultMediaRoot().appendingPathComponent(profileId, isDirectory: true)
    }

    var body: some View {
        Group {
            if phase != nil {
                importingState
            } else if let vm, !vm.isEmpty || vm.account != nil {
                // 有账号就进时间线——新建的空白账号一条推都没有，也不该回到「导入存档」引导页
                loaded(vm)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // page2 的应用是满屏的（状态栏也藏了），底色必须铺进安全区，不然灵动岛那条和 Home 条那条是白的
        .toolPageBackground(Theme.mainBg)
        .task(id: profileId) {
            bootstrap()
            consumeSearchTarget()
        }
        .onChange(of: navigator?.pendingTarget) { _, _ in consumeSearchTarget() }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [.zip, .folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { runImport(url) }
            case .failure(let error): errorText = error.localizedDescription
            }
        }
        .sheet(isPresented: $composing, onDismiss: { resumeDraft = nil }) {
            TwitterComposeView(account: vm?.account, mediaDir: mediaDir, accent: accent,
                               profileId: profileId, resume: resumeDraft,
                               onOpenDrafts: {
                                   composing = false
                                   // 等这个框收起再弹草稿箱，两个同时弹会有一个弹不出来
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingDrafts = true }
                               },
                               onPost: { post($0, images: $1) }, onCancel: { composing = false })
        }
        .sheet(item: $quoting, onDismiss: { resumeDraft = nil }) { q in
            TwitterComposeView(account: vm?.account, mediaDir: mediaDir, accent: accent, quoting: q,
                               parentAuthor: vm?.author(of: q) ?? vm?.account,
                               profileId: profileId, resume: resumeDraft,
                               onPost: { post($0, images: $1, quoting: q) }, onCancel: { quoting = nil })
        }
        .sheet(item: $replyingFromDraft, onDismiss: { resumeDraft = nil }) { parent in
            TwitterComposeView(account: vm?.account, mediaDir: mediaDir, accent: accent, replyingTo: parent,
                               parentAuthor: vm?.author(of: parent) ?? vm?.account,
                               profileId: profileId, resume: resumeDraft,
                               onPost: { post($0, images: $1, replyingTo: parent) },
                               onCancel: { replyingFromDraft = nil })
        }
        .sheet(item: $editingTweet) { t in
            TwitterComposeView(account: vm?.author(of: t) ?? vm?.account, mediaDir: mediaDir, accent: accent,
                               editing: t,
                               onPost: { text, _ in saveEdit(t, text) }, onCancel: { editingTweet = nil })
        }
        .sheet(isPresented: $showingDrafts) {
            let me = vm?.account?.accountId ?? ""
            TwitterDraftsSheet(drafts: TwitterDrafts.list(profileId: profileId, accountId: me, context: modelContext),
                               accent: accent,
                               replyHandle: { id in
                                   (try? modelContext.fetch(TwitterQueries.tweets(profileId: profileId, ids: [id])))?
                                       .first.flatMap { $0.originalAuthorHandle ?? vm?.author(of: $0)?.screenName }
                               },
                               onPick: { d in
                                   showingDrafts = false
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { resume(d) }
                               },
                               onDelete: { d in
                                   try? TwitterDrafts.delete(d, mediaDir: mediaDir, context: modelContext)
                                   // 列表是现算的：关了再开刷新
                                   showingDrafts = false
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showingDrafts = true }
                               },
                               onClose: { showingDrafts = false })
        }
        .sheet(isPresented: $tuningColor) { colorSheet }
        .sheet(isPresented: $managingAccounts) {
            TwitterAccountsSheet(
                accounts: TwitterAccounts.userAccounts(profileId: profileId, context: modelContext),
                active: vm?.account, mediaDir: mediaDir, accent: accent,
                onSwitch: { switchTo($0) },
                onImport: {
                    managingAccounts = false
                    // 等 sheet 收起再弹文件选择器，两个同时弹会有一个弹不出来
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { picking = true }
                },
                onCreate: { name, handle in
                    try TwitterAccounts.createLocal(displayName: name, screenName: handle,
                                                    profileId: profileId, context: modelContext)
                    managingAccounts = false
                    TwitterHaptics.success()
                    goHome()
                },
                onClose: { managingAccounts = false })
        }
        .sheet(isPresented: $editingProfile) {
            TwitterProfileEditView(profileId: profileId, account: vm?.account, mediaDir: mediaDir,
                                   accent: accent) {
                editingProfile = false
                // 第一次编辑可能是新建的账号，面板缓存的 nil 要刷掉
                vm?.refreshAccount()
            }
        }
        .sheet(item: $detail) { tweet in
            // 串里点下去是一层层推进去的（每条都看得见上级和下级），外面套导航栈
            NavigationStack {
                TweetDetailView(tweet: tweet, media: vm?.media(for: tweet.tweetId) ?? [],
                                account: vm?.author(of: tweet) ?? vm?.account, mediaDir: mediaDir, accent: accent,
                                onOpenProfile: { openProfile(of: tweet.accountId) },
                                authorOf: { vm?.author(of: $0) ?? vm?.account },
                                onOpenProfileOf: { openProfile(of: $0.accountId) },
                                me: vm?.account,
                                closeAll: { detail = nil },
                                onSearch: searchTag,
                                onDelete: { vm?.remove(tweet); TwitterHaptics.medium() },
                                onChanged: { reloadKeepingSection() })
            }
        }
        .sheet(item: $followList) { kind in
            let who = vm?.viewedAccount
            let ids = who.map { kind == .following ? TwitterFollows.followees(of: $0, context: modelContext)
                                                   : TwitterFollows.followers(of: $0, context: modelContext) } ?? []
            let all = TwitterAccounts.all(profileId: profileId, context: modelContext)
            TwitterFollowListSheet(title: kind == .following ? "正在关注" : "关注者",
                                   accounts: ids.compactMap { id in all.first { $0.accountId == id } },
                                   mediaDir: mediaDir, accent: accent,
                                   onOpen: { a in followList = nil; openProfile(of: a.accountId) },
                                   onClose: { followList = nil })
        }
        .task(id: profileId) {
            // 小克 / 楼层 AI 在外面点赞回复，app 开着也要能冒出来：隔一会儿现算一次（都是本地小查询）
            while !Task.isCancelled {
                refreshNotifications()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// 全局搜索点了一条推文 → 打开那条的详情（S3-2）
    private func consumeSearchTarget() {
        guard let target = navigator?.pendingTarget, target.tool == "twitter" else { return }
        navigator?.pendingTarget = nil
        detail = (try? modelContext.fetch(TwitterQueries.tweets(profileId: profileId, ids: [target.id])))?.first
    }

    // MARK: - 已加载

    /// 满屏布局（粟粟 2026-09-24：「全屏救一下，安全区都是白屏；每页还欲盖弥彰搞个标题」）：
    /// 顶栏、底栏是半透明材质，**铺到屏幕边缘**，时间线从它们底下滚过去——推特就是这样。
    /// 顶栏不放文字标题：左头像、中间小鸟、右「…」。个人主页没有顶栏，横幅直接顶到屏幕上沿。
    private func loaded(_ vm: TwitterPanelViewModel) -> some View {
        feed(vm)
            // 主页让横幅顶进安全区；其它页由 safeAreaInset 的顶栏占位
            .ignoresSafeArea(.container, edges: section == .profile ? .top : [])
            .safeAreaInset(edge: .top, spacing: 0) {
                if section != .profile { header(vm) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .trailing, spacing: 14) {
                    composeButton.padding(.trailing, 18)
                    bottomNav
                }
            }
            .overlay { if drawerOpen { drawerLayer(vm) } }
            .overlay(alignment: .topTrailing) {
                // 主页没有顶栏，「…」浮在横幅上（推特主页右上角也是浮着的圆钮）
                if section == .profile {
                    moreMenu {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white).frame(width: 34, height: 34)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 6)
                }
            }
    }

    /// 抽屉 + 压暗的底。点暗处收起。
    private func drawerLayer(_ vm: TwitterPanelViewModel) -> some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { closeDrawer() }
                .transition(.opacity)
            TwitterDrawerView(
                accounts: TwitterAccounts.userAccounts(profileId: profileId, context: modelContext),
                active: vm.account, tweetCount: vm.totalCount, mediaDir: mediaDir, accent: accent,
                demoInstalled: demoInstalled,
                onProfile: { closeDrawer(); openProfile(of: nil) },
                onBookmarks: { closeDrawer(); openBookmarks() },
                onSwitch: { closeDrawer(); switchTo($0) },
                onManageAccounts: { closeDrawer(); managingAccounts = true },
                onEditProfile: { closeDrawer(); editingProfile = true },
                onAccent: { closeDrawer(); tuningColor = true },
                onImport: { closeDrawer(); picking = true },
                onRemoveDemo: { closeDrawer(); removeDemo() })
            .frame(width: 300)
            .frame(maxHeight: .infinity)
            .toolPageBackground(Theme.mainBg)
            .transition(.move(edge: .leading))
        }
    }

    private var composeButton: some View {
        Button { composing = true } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(accent, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("写一条")
    }

    /// 顶栏：左头像（去主页）· 中间小鸟 / 搜索框 · 右「…」。下面挂当前页的 tab。
    private func header(_ vm: TwitterPanelViewModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if section == .bookmarks {
                    // 书签页是从抽屉进的二级页：左边返回，标题是有信息量的（哪个账号的书签）
                    Button(action: goHome) {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary).frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                } else {
                    // 推特左上角的头像拉出抽屉（账号切换、书签都在里面）
                    Button(action: openDrawer) {
                        TwitterAvatarView(account: vm.account, mediaDir: mediaDir, size: 32, accent: accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开菜单")
                }

                if section == .bookmarks {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("书签").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        if let handle = vm.account?.screenName, !handle.isEmpty {
                            Text("@\(handle)").font(.system(size: 13)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    Spacer(minLength: 0)
                } else if section == .search {
                    searchField(vm)
                } else {
                    Spacer(minLength: 0)
                    Image(systemName: "bird.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                }

                moreMenu {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textMuted).frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            // 粟粟 2026-09-24 真机看过：整条往上提 15pt，贴近灵动岛
            .padding(.top, -15)
            if section == .home { tabStrip(vm) }
            if section == .bookmarks, !bookmarkFolders.isEmpty { folderStrip(vm) }
            Divider().opacity(0.4)
        }
        // 材质默认铺进安全区：灵动岛那条跟顶栏连成一片
        .background(.bar)
    }

    private func moreMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button("编辑个人资料") { editingProfile = true }
            Button("重新导入存档") { picking = true }
            Button("强调色…") { tuningColor = true }
            if demoInstalled { Button("清掉示例", role: .destructive) { removeDemo() } }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("更多")
    }

    /// 下划线 tab —— 推特就是这个形态，不是药丸按钮。
    private func tabStrip(_ vm: TwitterPanelViewModel) -> some View {
        HStack(spacing: 0) {
            // 本站：这层所有账号；关注：当前账号 + 它关注的（Mastodon 的 Local / Home）
            tab("本站", active: vm.filter == .local) { vm.apply(.local) }
            tab("关注", active: vm.filter == .following) { vm.apply(.following) }
        }
        .frame(height: 44)
    }

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if !active { TwitterHaptics.tap() }
            action()
        } label: {
            ZStack(alignment: .bottom) {
                Text(title)
                    .font(.system(size: 15, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if active {
                    Capsule().fill(accent).frame(width: 44, height: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 书签文件夹：全部 + X 上自己建的文件夹。文件夹多了横向滑。
    private func folderStrip(_ vm: TwitterPanelViewModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                folderTab("全部", active: vm.filter == .bookmarks) { vm.apply(.bookmarks) }
                ForEach(bookmarkFolders, id: \.folderId) { f in
                    folderTab(f.name, active: vm.filter == .bookmarkFolder(f.folderId)) {
                        vm.apply(.bookmarkFolder(f.folderId))
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: 44)
    }

    private func folderTab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if !active { TwitterHaptics.tap() }
            action()
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 15, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Capsule().fill(active ? accent : .clear).frame(height: 3)
            }
            .padding(.horizontal, 12)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 主页的 tab：帖子 / 回复 / 媒体 / 喜欢，跟推特一样。
    private func profileTabs(_ vm: TwitterPanelViewModel) -> some View {
        HStack(spacing: 0) {
            tab("帖子", active: vm.filter == .posts) { vm.apply(.posts) }
            tab("回复", active: vm.filter == .replies) { vm.apply(.replies) }
            tab("媒体", active: vm.filter == .withMedia) { vm.apply(.withMedia) }
            tab("喜欢", active: vm.filter == .liked) { vm.apply(.liked) }
        }
        .frame(height: 44)
    }

    private func searchField(_ vm: TwitterPanelViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.textMuted)
            TextField("搜索推文", text: $keyword)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .onSubmit { vm.apply(keyword.isEmpty ? .all : .search(keyword)) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.accent, in: Capsule())
    }

    private func feed(_ vm: TwitterPanelViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if section == .profile {
                    TwitterProfileHeaderView(account: vm.viewedAccount, tweetCount: vm.totalCount,
                                             span: vm.span, mediaDir: mediaDir, accent: accent,
                                             onEdit: { editingProfile = true },
                                             isOwn: vm.isViewingOwnAccount,
                                             isFollowing: isFollowingViewed(vm),
                                             onFollow: { toggleFollowViewed(vm) },
                                             followingCount: vm.viewedAccount.map { TwitterFollows.followees(of: $0, context: modelContext).count } ?? 0,
                                             followerCount: vm.viewedAccount.map { TwitterFollows.followers(of: $0, context: modelContext).count } ?? 0,
                                             onShowFollows: { followList = $0 ? .following : .followers })
                        .padding(.bottom, 8)
                    profileTabs(vm)
                    Divider().opacity(0.4)
                }

                if section == .notifications {
                    notificationList(vm)
                } else {
                ForEach(vm.tweets, id: \.persistentModelID) { tweet in
                    let quoted = vm.quoted(for: tweet)
                    // 每行显示发推的那个号（本站里有别的号、AI 的号），不是当前账号
                    TweetRowView(tweet: tweet, media: vm.media(for: tweet.tweetId),
                                 account: vm.author(of: tweet) ?? vm.account, mediaDir: mediaDir, accent: accent,
                                 quoted: quoted,
                                 quotedMedia: quoted.map { vm.media(for: $0.tweetId) } ?? [],
                                 repostedBy: vm.author(of: tweet).flatMap {
                                     $0.accountId == vm.account?.accountId ? nil : $0.displayName
                                 },
                                 onOpenProfile: { openProfile(of: tweet.accountId) },
                                 onReply: { detail = tweet },
                                 onLike: { like(tweet) },
                                 onRepost: { repost(tweet) },
                                 onQuote: { quoting = tweet },
                                 onBookmark: { bookmark(tweet) },
                                 onDelete: { vm.remove(tweet); TwitterHaptics.medium() },
                                 onEdit: TwitterTweetActions.canEdit(tweet, owner: vm.author(of: tweet))
                                     ? { editingTweet = tweet } : nil,
                                 replyCount: vm.replyCount(for: tweet))
                        .onTapGesture { detail = tweet }
                    Divider().opacity(0.4).padding(.leading, 66)
                }

                if vm.hasMore {
                    // LazyVStack 里 GeometryReader/onScrollGeometryChange 都不可靠（项目踩过），
                    // 用哨兵行的 onAppear 触发翻页
                    Color.clear.frame(height: 1).onAppear { vm.loadMore() }
                    ProgressView().padding(.vertical, 16).frame(maxWidth: .infinity)
                } else if vm.tweets.isEmpty {
                    Text(section == .search ? "没有匹配的推文" : "这里还没有内容")
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                }
                // 底栏由 safeAreaInset 让位，这里只留一点呼吸
                Color.clear.frame(height: 12)
            }
        }
        .scrollIndicators(Theme.hScrollIndicators ? .automatic : .hidden)
        // 换页 / 换人看主页 = 新的滚动视图从顶上开始。不然沿用上一页的滚动位置，
        // 懒加载的头部边量边挪，头像就「漂」过去了（粟粟 2026-09-25）
        .id("\(section.rawValue)|\(vm.viewedAccount?.accountId ?? "")")
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func notificationList(_ vm: TwitterPanelViewModel) -> some View {
        if notifications.isEmpty {
            Text("还没有通知。有人赞你、回你、@你、关注你，都会出现在这里。")
                .font(.footnote).foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
        }
        ForEach(notifications) { item in
            TwitterNotificationRow(item: item, actor: actorAccount(item.actorId, vm), mediaDir: mediaDir,
                                   accent: accent, unread: item.date > highlightSince)
                .onTapGesture {
                    TwitterHaptics.tap()
                    if let t = item.tweet { detail = t } else { openProfile(of: item.actorId) }
                }
            Divider().opacity(0.4)
        }
    }

    private func actorAccount(_ id: String, _ vm: TwitterPanelViewModel) -> TwitterArchiveAccount? {
        vm.accountsById[id]
            ?? TwitterAccounts.all(profileId: profileId, context: modelContext).first { $0.accountId == id }
    }

    private var unreadNotifications: Int {
        TwitterNotifications.unreadCount(notifications, since: notificationsSeen)
    }

    private func refreshNotifications() {
        guard let vm else { return }
        let me = vm.account?.accountId ?? ""
        notifications = TwitterNotifications.items(for: me, handle: vm.account?.screenName,
                                                   profileId: profileId, context: modelContext)
        if section == .notifications {
            // 正看着通知页：新来的直接算看过（底色保留到离开这页）
            TwitterNotifications.markSeen(profileId: profileId, me: me)
        }
        notificationsSeen = TwitterNotifications.lastSeen(profileId: profileId, me: me)
    }

    private func enterNotifications() {
        let me = vm?.account?.accountId ?? ""
        highlightSince = TwitterNotifications.lastSeen(profileId: profileId, me: me)
        refreshNotifications()
        TwitterNotifications.markSeen(profileId: profileId, me: me)
        notificationsSeen = Date()
    }

    /// 底部导航。四个都是真去处，不放假入口。
    private var bottomNav: some View {
        HStack(spacing: 0) {
            navItem(.home, "house.fill")
            navItem(.search, "magnifyingglass")
            navItem(.notifications, "bell", badge: unreadNotifications)
            navItem(.media, "photo.on.rectangle")
            navItem(.profile, "person.crop.circle")
        }
        .frame(height: 50)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
        // 材质默认铺进安全区：Home 条那条跟底栏连成一片
        .background(.bar)
    }

    private func navItem(_ target: Section, _ icon: String, badge: Int = 0) -> some View {
        Button {
            if section != target { TwitterHaptics.tap() }
            section = target
            switch target {
            case .home: vm?.apply(.local)
            // 底栏的资料、媒体总是回自己的号
            case .profile: vm?.viewAccount(nil); vm?.apply(.posts)
            case .media: vm?.viewAccount(nil); vm?.apply(.withMedia)
            case .search: vm?.apply(keyword.isEmpty ? .all : .search(keyword))
            case .notifications: enterNotifications()
            case .bookmarks: vm?.apply(.bookmarks)   // 底栏没有书签格，走不到；写全是为了 switch 穷尽
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 20, weight: section == target ? .semibold : .regular))
                .foregroundStyle(section == target ? Theme.textPrimary : Theme.textMuted)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        // 未读数：推特是强调色小圆
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(accent, in: Capsule())
                            .offset(x: 10, y: -6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(target.rawValue)，\(badge) 条未读" : target.rawValue)
    }

    // MARK: - 空态 / 导入中

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bird")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(accent)
            Text("还没有导入推特存档").font(.headline).foregroundStyle(Theme.textPrimary)
            Text("选官方导出的 .zip，或者已经解压好的文件夹。\n剩下的全自动，不用再选第二次。")
                .font(.subheadline).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
            Button("选择存档") { picking = true }
                .buttonStyle(.borderedProminent).tint(accent).padding(.top, 4)
            HStack(spacing: 18) {
                Button("看看样子") { installDemo() }
                Button("自己写一条") { composing = true }
            }
            .font(.footnote).buttonStyle(.plain).foregroundStyle(accent)
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .contentShape(Rectangle())
    }

    private var importingState: some View {
        VStack(spacing: 12) {
            ProgressView(value: fraction).tint(accent).frame(maxWidth: 260)
            Text(phaseText).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Text("存档大的话要等一会儿，别退出。").font(.footnote).foregroundStyle(Theme.textMuted)
        }
        .padding(32)
    }

    private var phaseText: String {
        switch phase {
        case .unzip:  return "正在解包…"
        case .parse:  return "正在读推文…"
        case .finish: return "收尾…"
        case nil:     return ""
        }
    }

    // MARK: - 写一条 / 换色

    private var colorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("强调色").font(.headline).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 14) {
                ForEach(TwitterAccent.presets) { preset in
                    Button {
                        accentHex = preset.hex
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(TwitterAccent.color(fromHex: preset.hex))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if accentHex == preset.hex {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            Text(preset.name).font(.caption2).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField("#RRGGBB", text: $accentHex)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(width: 130)
                    .onSubmit { accentHex = TwitterAccent.hexOrFallback(accentHex) }
                Text("自己填也行，填错会退回默认。")
                    .font(.footnote).foregroundStyle(Theme.textMuted)
            }
            HStack {
                Spacer()
                Button("好") { accentHex = TwitterAccent.hexOrFallback(accentHex); tuningColor = false }
                    .buttonStyle(.borderedProminent).tint(accent)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .toolPageBackground(Theme.mainBg)
    }

    // MARK: - 动作

    private func bootstrap() {
        let model = TwitterPanelViewModel(context: modelContext, profileId: profileId)
        model.apply(.local)   // 首页默认「本站」
        vm = model
        demoInstalled = (try? TwitterDemoSeed.isInstalled(profileId: profileId, context: modelContext)) ?? false
    }

    private func post(_ text: String, images: [Data], quoting q: TweetEntry? = nil,
                      replyingTo parent: TweetEntry? = nil) {
        do {
            try TwitterComposer.post(text: text, images: images, mediaDir: mediaDir, replyingTo: parent, quoting: q,
                                     profileId: profileId, context: modelContext)
            composing = false
            quoting = nil
            replyingFromDraft = nil
            reloadAll()
            TwitterHaptics.success()
        } catch { errorText = "发不出去：\(error.localizedDescription)"; TwitterHaptics.failure() }
    }

    /// 从草稿接着写：回复的开回复框、引用的开引用框（对象被删了就当新推）
    private func resume(_ d: TwitterDraft) {
        resumeDraft = d
        func find(_ id: String?) -> TweetEntry? {
            id.flatMap { try? modelContext.fetch(TwitterQueries.tweets(profileId: profileId, ids: [$0])).first }
        }
        if let parent = find(d.replyToTweetId) { replyingFromDraft = parent }
        else if let q = find(d.quotedTweetId) { quoting = q }
        else { composing = true }
    }

    private func saveEdit(_ t: TweetEntry, _ text: String) {
        do {
            try TwitterTweetActions.edit(t, text: text, context: modelContext)
            editingTweet = nil
            vm?.reload()
            TwitterHaptics.success()
        } catch { errorText = "改不了：\(error.localizedDescription)"; TwitterHaptics.failure() }
    }

    /// 转帖 / 撤销转帖。转帖是新的一行，要重载时间线才看得见（撤销同理）
    private func repost(_ tweet: TweetEntry) {
        do {
            try TwitterTweetActions.toggleRepost(tweet, context: modelContext)
            TwitterHaptics.medium()
            vm?.reload()
        } catch { errorText = "没转上：\(error.localizedDescription)" }
    }

    private func openDrawer() {
        TwitterHaptics.tap()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { drawerOpen = true }
    }

    private func closeDrawer() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { drawerOpen = false }
    }

    private func goHome() {
        if section != .home { TwitterHaptics.tap() }
        section = .home
        vm?.apply(.local)
    }

    private func openBookmarks() {
        bookmarkFolders = TwitterBookmarkFolders.all(profileId: profileId, context: modelContext)
        section = .bookmarks
        vm?.apply(.bookmarks)
    }

    /// 切账号：换当前账号、回首页从头加载（时间线、头像、总数都跟着换）
    private func switchTo(_ account: TwitterArchiveAccount) {
        do {
            try TwitterAccounts.activate(account, context: modelContext)
            managingAccounts = false
            TwitterHaptics.medium()
            section = .home
            vm?.apply(.local)
        } catch { errorText = "切不过去：\(error.localizedDescription)" }
    }

    private func bookmark(_ tweet: TweetEntry) {
        do {
            try TwitterTweetActions.toggleBookmark(tweet, context: modelContext)
            TwitterHaptics.light()
            // 在书签页取消书签，这一条要走掉
            if let vm, vm.isShowingBookmarks { vm.apply(vm.filter) }
        } catch { errorText = "没加上：\(error.localizedDescription)" }
    }

    /// 进某个号的主页。nil 或当前账号 = 自己的主页
    private func openProfile(of accountId: String? = nil) {
        TwitterHaptics.tap()
        vm?.viewAccount(accountId)
        section = .profile
        vm?.apply(.posts)
    }

    private func isFollowingViewed(_ vm: TwitterPanelViewModel) -> Bool {
        guard let me = vm.account, let other = vm.viewedAccount, !vm.isViewingOwnAccount else { return false }
        return TwitterFollows.isFollowing(other, by: me, context: modelContext)
    }

    private func toggleFollowViewed(_ vm: TwitterPanelViewModel) {
        guard let me = vm.account, let other = vm.viewedAccount, !vm.isViewingOwnAccount else { return }
        do {
            if TwitterFollows.isFollowing(other, by: me, context: modelContext) {
                try TwitterFollows.unfollow(other, by: me, context: modelContext)
            } else {
                try TwitterFollows.follow(other, by: me, context: modelContext)
            }
            TwitterHaptics.medium()
            vm.apply(vm.filter)   // 刷一下让按钮状态跟上
        } catch { errorText = "关注失败：\(error.localizedDescription)" }
    }

    /// 详情页点了话题标签：切到搜索并直接搜
    private func searchTag(_ tag: String) {
        keyword = tag
        section = .search
        vm?.apply(.search(tag))
    }

    private func like(_ tweet: TweetEntry) {
        do {
            try TwitterTweetActions.toggleLike(tweet, context: modelContext)
            TwitterHaptics.light()
            // 在「喜欢」tab 里取消赞，这一条要从列表里走掉
            if vm?.filter == .liked { vm?.apply(.liked) }
        } catch { errorText = "没点上：\(error.localizedDescription)" }
    }

    /// 详情页里回复/删回复之后刷新，筛选保持不变（`reload` 沿用当前 filter）
    private func reloadKeepingSection() {
        vm?.reload()
    }

    private func installDemo() {
        do { try TwitterDemoSeed.install(profileId: profileId, context: modelContext); reloadAll() }
        catch { errorText = "示例装不上：\(error.localizedDescription)" }
    }

    private func removeDemo() {
        do { try TwitterDemoSeed.remove(profileId: profileId, context: modelContext); reloadAll() }
        catch { errorText = "清不掉：\(error.localizedDescription)" }
    }

    private func reloadAll() {
        vm?.reload()
        demoInstalled = (try? TwitterDemoSeed.isInstalled(profileId: profileId, context: modelContext)) ?? false
    }

    private func runImport(_ url: URL) {
        errorText = nil
        phase = .unzip
        fraction = 0
        Task {
            do {
                let result = try await TwitterArchiveImporter.importArchive(
                    at: url, profileId: profileId, context: modelContext,
                    onProgress: { p, f in Task { @MainActor in phase = p; fraction = f } })
                await MainActor.run {
                    lastResult = result; phase = nil
                    section = .home; vm?.apply(.local)   // 导进来的可能是新账号，已经切过去了，回它的首页
                    reloadAll(); TwitterHaptics.success()
                }
            } catch {
                await MainActor.run { errorText = "导入失败：\(error.localizedDescription)"; phase = nil; TwitterHaptics.failure() }
            }
        }
    }
}
