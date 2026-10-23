#if PERSONAL_APPS
#if DEBUG
import SwiftUI

/// page2 tool「话题盒」💭——问题池的套壳呈现层（本体 = 文件库 topics/ 目录，
/// AI 用 fs 工具读写同一批文件）。今日掉落 + 全部列表 + archived 折叠 + 手写投题。
struct TopicBoxPanelView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var cards: [TopicCard] = []
    @State private var todayPaths: [String] = []
    @State private var showCompose = false
    @State private var showArchived = false
    @State private var openedCard: OpenedTopic? = nil

    private struct OpenedTopic: Identifiable {
        let relPath: String
        var id: String { relPath }
    }

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private var rootURL: URL { FileLibraryStore.libraryRoot(profileId: profileId) }

    private var todayCards: [TopicCard] {
        todayPaths.compactMap { path in cards.first { $0.relPath == path } }
    }

    private var activeCards: [TopicCard] {
        cards.filter { !$0.isArchived }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    private var archivedCards: [TopicCard] {
        cards.filter(\.isArchived)
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if cards.filter({ !$0.isArchived }).isEmpty {
                    emptyState
                } else {
                    todaySection
                    allSection
                }

                if !archivedCards.isEmpty {
                    archivedSection
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolPageBackground(Theme.mainBg)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 10)
        .padding(.bottom, 10)
        .onAppear {
            reload()
            if let pending = TopicBoxStore.pendingOpenRelPath {
                TopicBoxStore.pendingOpenRelPath = nil
                openedCard = OpenedTopic(relPath: pending)
            }
        }
        .onChange(of: profileId) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .openTopicBoxTool)) { notif in
            // 面板已在场时直接开卡；不在场的场景走 pendingOpenRelPath 交接
            if let path = notif.userInfo?["topicPath"] as? String {
                TopicBoxStore.pendingOpenRelPath = nil
                openedCard = OpenedTopic(relPath: path)
            }
        }
        .sheet(isPresented: $showCompose) {
            TopicComposeSheet(profileId: profileId) { reload() }
        }
        .sheet(item: $openedCard) { item in
            TopicCardSheet(relPath: item.relPath, profileId: profileId) { reload() }
        }
    }

    private func reload() {
        guard !profileId.isEmpty else { return }
        todayPaths = TopicBoxStore.ensureTodayDrops(
            rootURL: rootURL,
            ledgerURL: TopicBoxStore.defaultLedgerURL(profileId: profileId)
        )
        cards = TopicBoxStore.listCards(rootURL: rootURL)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            PixelIcon(bitmap: PixelGlyph.lightbulb, size: 18, color: Theme.textSecondary)
            Text("话题盒")
                .font(.system(size: Theme.F.sectionHeader, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button {
                showCompose = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.accent.opacity(0.6)))
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            PixelIcon(bitmap: PixelGlyph.lightbulb, size: 26, color: Theme.textMuted.opacity(0.6))
            Text("盒子还空着")
                .font(.system(size: Theme.F.body, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("写下第一个问题，或和 TA 聊出一个——\n每天会随机掉出一两个来陪你想")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var todaySection: some View {
        if !todayCards.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Today")
                    .font(.system(size: Theme.F.caption, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                ForEach(todayCards) { card in
                    todayCardView(card)
                }
            }
        }
    }

    private func todayCardView(_ card: TopicCard) -> some View {
        Button {
            openedCard = OpenedTopic(relPath: card.relPath)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    PixelIcon(bitmap: PixelGlyph.lightbulb, size: 14, color: Theme.branchIndicator)
                    Text("今天掉出来的")
                        .font(.system(size: Theme.F.caption))
                        .foregroundColor(Theme.branchIndicator)
                    Spacer()
                }
                Text(card.title)
                    .font(.system(size: Theme.F.body, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(cardMeta(card))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.branchIndicator.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.branchIndicator.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var allSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All")
                .font(.system(size: Theme.F.caption, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 4)
            ForEach(activeCards) { card in
                cardRow(card)
            }
        }
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showArchived.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Archived")
                        .font(.system(size: Theme.F.caption, weight: .semibold))
                    Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(Theme.textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            if showArchived {
                ForEach(archivedCards) { card in
                    cardRow(card)
                }
            }
        }
    }

    private func cardRow(_ card: TopicCard) -> some View {
        Button {
            openedCard = OpenedTopic(relPath: card.relPath)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.system(size: Theme.F.body, weight: .medium))
                    .foregroundColor(card.isArchived ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(cardMeta(card))
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.sidebarBg.opacity(0.7))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cardMeta(_ card: TopicCard) -> String {
        var parts: [String] = []
        if let author = card.author, !author.isEmpty { parts.append(author) }
        parts.append(card.responses.isEmpty ? "还没有回应" : "\(card.responses.count) 条回应")
        return parts.joined(separator: " · ")
    }
}
#endif
#endif
