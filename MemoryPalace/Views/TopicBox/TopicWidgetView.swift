#if PERSONAL_APPS
#if DEBUG
import SwiftUI

/// 话题盒组件（page2 仪表盘）——今日掉落的问题。
///
/// 三档：
/// - 小方：今日第一个问题
/// - 长条：今日 1-2 个问题
/// - 大方：今日问题 + 署名/回应数
///
/// 整块 tap → 话题盒工具（VocabWidgetView 同款通知模式）。
struct TopicWidgetView: View {
    @Environment(\.isPage2Active) private var desktopActive
    @Environment(\.page2Date) private var desktopDate
    @Environment(\.usesSystemDesktop) private var systemDesktop
    var size: WidgetSize = .medium
    @Environment(\.pinnedOnDesktop) private var pinnedOnDesktop

    @Environment(ProfileManager.self) private var profileManager: ProfileManager?

    @State private var todayCards: [TopicCard] = []

    private var profileId: String { profileManager?.currentProfile.id ?? "" }

    private var dayOfEra: Int {
        Calendar.current.ordinality(of: .day, in: .era, for: systemDesktop ? desktopDate : Date()) ?? 0
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            #if os(macOS)
            .modifier(MacShellWidgetSurface())
            #else
            .modifier(Page2LegacySurface())
            #endif
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture {
                NotificationCenter.default.post(name: .openTopicBoxTool, object: nil)
            }
            .task(id: "\(profileId)-\(dayOfEra)-\(desktopActive)") { if desktopActive { reload() } }
    }

    private func reload() {
        guard !profileId.isEmpty else { return }
        let root = FileLibraryStore.libraryRoot(profileId: profileId)
        let paths = TopicBoxStore.ensureTodayDrops(
            rootURL: root,
            ledgerURL: TopicBoxStore.defaultLedgerURL(profileId: profileId)
        )
        todayCards = paths.compactMap { TopicBoxStore.loadCard(relPath: $0, rootURL: root) }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                PixelIcon(bitmap: PixelGlyph.lightbulb, size: 12, color: Theme.branchIndicator)
                Text("今日话题")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                Spacer()
            }

            if todayCards.isEmpty {
                Spacer(minLength: 0)
                Text("盒子空着——\n去写下第一个问题")
                    .font(.system(size: size == .small ? 11 : 12))
                    .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                ForEach(visibleCards) { card in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title)
                            .font(.system(size: titleSize, weight: .semibold))
                            .foregroundColor(systemDesktop ? .primary : Theme.textPrimary)
                            .lineLimit(size == .small ? 3 : 2)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.leading)
                        if size == .large {
                            Text(meta(card))
                                .font(.system(size: 10))
                                .foregroundColor(systemDesktop ? .secondary : Theme.textMuted)
                        }
                    }
                    .padding(.bottom, 2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }

    private var visibleCards: [TopicCard] {
        size == .small ? Array(todayCards.prefix(1)) : todayCards
    }

    private var titleSize: CGFloat {
        switch size {
        case .small:  return 13
        case .medium: return 14
        case .large:  return 15
        }
    }

    private func meta(_ card: TopicCard) -> String {
        var parts: [String] = []
        if let author = card.author, !author.isEmpty { parts.append("\(author) 存的") }
        parts.append(card.responses.isEmpty ? "还没有回应" : "\(card.responses.count) 条回应")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Notification key

extension Notification.Name {
    /// Widget tap / 词详情出处跳转 post。可在 userInfo["topicPath"] 传 relPath →
    /// TopicBoxPanelView 接收后直接开那张卡。
    static let openTopicBoxTool = Notification.Name("openTopicBoxTool")
}
#endif
#endif
