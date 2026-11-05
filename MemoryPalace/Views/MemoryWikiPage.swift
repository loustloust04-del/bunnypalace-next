import SwiftUI

// MARK: - wiki 台（plan-memory-audit-home-trial 第二节）
// 顶上「页 | 整理提案 N」：页 = 工程 / 楼层两行，点进去一层层推 `WikiFolderPage`；整理提案 = 原样 `WikiProposalsView`
//（原来在审计台第四段，记忆格里的「wiki · N 页」也挪到这里）。数据一条不动，只换入口。

struct MemoryWikiPage: View {
    var viewState: MemoryAuditViewState
    let viewModel: ConversationViewModel?

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var branches: [WikiBranchCount] = []
    @State private var pending = 0
    @State private var unread = 0
    @State private var loaded = false
    @State private var runner = CatalogRunner.shared
    @State private var refresher = AuditRefreshQueue()

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var total: Int { branches.reduce(0) { $0 + $1.count } }

    var body: some View {
        Group {
            if viewState.wikiShowsProposals {
                WikiProposalsView(viewModel: viewModel)
            } else {
                pages
            }
        }
        .animation(nil, value: viewState.wikiShowsProposals)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        // 几路同时要的合成一次，旧的结果不回写（同首页）
        .task(id: profileId) { refresher.request(load) }
        .onDisappear { refresher.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in refresher.request(load) }
        .onChange(of: runner.lastFinishedAt) { _, _ in refresher.request(load) }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            refresher.invalidate()
            branches = []
            pending = 0
            unread = 0
            loaded = false
        }
    }

    private var header: some View {
        Picker("wiki", selection: Bindable(viewState).wikiShowsProposals) {
            Text("页").tag(false)
            Text(AuditStation.proposalsSegmentTitle(pending: pending, unread: unread)).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .toolPageBackground()
    }

    private var pages: some View {
        List {
            Section {
                if loaded && total == 0 {
                    Text("还没有页——在「整理提案」批了提案才会写进来")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                    Button("去整理提案 ›") { viewState.wikiShowsProposals = true }
                        .font(m.body)
                        .foregroundColor(Theme.branchIndicator)
                        .buttonStyle(.plain)
                }
                ForEach(branches) { b in
                    NavigationLink {
                        WikiFolderPage(folder: b.branch)
                    } label: {
                        HStack {
                            Text(b.branch)
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text("\(b.count) 页")
                                .font(m.caption)
                                .foregroundColor(Theme.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                Text("整理好的档案，一个点一页")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .textCase(nil)
            }
            .panelRowBackground()
        }
        .panelListStyle()
        .scrollContentBackground(.hidden)
    }

    private func load(_ ticket: Int) async {
        let pid = profileId
        guard !pid.isEmpty else { return }
        let (counts, tally) = await Task.detached(priority: .utility) {
            let wiki = WikiStore(profileId: pid)
            return (wiki.branchPageCounts(), AuditStation.proposalTally(WikiProposalStore(wiki: wiki).list()))
        }.value
        guard refresher.isCurrent(ticket), pid == profileId else { return }
        branches = counts
        pending = tally.pending
        unread = tally.unread
        loaded = true
    }
}
