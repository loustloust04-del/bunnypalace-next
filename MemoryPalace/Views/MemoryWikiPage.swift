import MemoryCore
import SwiftUI

// MARK: - 记忆 app「wiki」格（粟粟 10-24：底栏第三格直接放 wiki 正文）
// 根下各组（有页的才列），点进去一层层推 `WikiFolderPage`，页行点开编辑器。
// 原来是审计台 wiki 台顶上「页 | 整理提案」里的「页」那段；整理提案留在审计台 wiki 台。数据一条不动，只换入口。

struct MemoryWikiPage: View {
    /// 空页「去整理提案 ›」：父级切到审计台格并推 wiki 台
    let openProposals: () -> Void

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var branches: [WikiBranchCount] = []
    @State private var loaded = false
    @State private var deletedCount = 0
    @State private var wiki: WikiStore?
    @State private var runner = CatalogRunner.shared
    @State private var refresher = AuditRefreshQueue()

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var total: Int { branches.reduce(0) { $0 + $1.count } }

    var body: some View {
        List {
            Section {
                if loaded && total == 0 {
                    Text("还没有页——在审计台「整理提案」批了提案才会写进来")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                    Button("去整理提案 ›", action: openProposals)
                        .font(m.body)
                        .foregroundColor(Theme.branchIndicator)
                        .buttonStyle(.plain)
                }
                ForEach(branches.filter { $0.count > 0 }) { b in
                    NavigationLink {
                        WikiFolderPage(folder: b.branch)
                    } label: {
                        HStack {
                            Text(WikiStore.shown(b.branch, user: profileManager?.currentProfile.userName ?? ""))
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
                if let wiki {
                    NavigationLink {
                        WikiDeletedPage(profileId: profileId, store: wiki)
                    } label: {
                        Text("已删除 · \(deletedCount)")
                            .font(m.body)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .accessibilityLabel("已删除 C 档案，\(deletedCount) 页")
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
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        // 几路同时要的合成一次，旧的结果不回写（同审计台首页）
        .task(id: profileId) { refresher.request(load) }
        .onDisappear { refresher.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in refresher.request(load) }
        .onChange(of: runner.lastFinishedAt) { _, _ in refresher.request(load) }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            refresher.invalidate()
            branches = []
            wiki = nil
            deletedCount = 0
            loaded = false
        }
    }

    private func load(_ ticket: Int) async {
        let pid = profileId
        guard !pid.isEmpty else { return }
        let result = await Task.detached(priority: .utility) {
            let store = WikiStore(profileId: pid)
            return (store, store.branchPageCounts(), store.deletions().filter { $0.phase != .restored && $0.reason != "批准补偿" }.count)
        }.value
        guard refresher.isCurrent(ticket), pid == profileId else { return }
        wiki = result.0
        branches = result.1
        deletedCount = result.2
        loaded = true
    }
}
