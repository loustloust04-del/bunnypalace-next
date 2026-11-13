import SwiftUI
import SwiftData

// MARK: - 审计台首页（plan-memory-audit-home-trial 第二节）
// 记忆 app 底栏「审计台」格 / mac 右栏：两列方块，一块一个台，照 `AuditStation.all` 画；点进去推那个台的页面。

struct MemoryAuditHome: View {
    /// 父级持有（mac 切格重建页面也不丢推到哪个台）
    var viewState: MemoryAuditViewState
    let viewModel: ConversationViewModel?

    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var pulses: [AuditStationID: AuditStationPulse] = [:]
    @State private var runner = CatalogRunner.shared
    @State private var refresher = AuditRefreshQueue()

    private var profileId: String { profileManager?.currentProfile.id ?? "" }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(AuditStation.all) { station in
                    tile(station)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .toolPageBackground()
        .tint(Theme.branchIndicator)
        .navigationDestination(item: Bindable(viewState).station) { id in
            AuditStationPage(id: id, viewState: viewState, viewModel: viewModel)
                .environment(viewModel)   // 推入页不一定继承得到环境：「跳到这条」要拿聊天 VM
                .modifier(AuditStationTitle(title: AuditStation.all.first { $0.id == id }?.name ?? ""))
        }
        // 每次回到首页都重算（从台里出来数字就是新的）；几路同时要的合成一次，旧的结果不回写
        .task(id: profileId) { refresher.request(load) }
        .onDisappear { refresher.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .memoryDidChange)) { _ in refresher.request(load) }
        .onChange(of: runner.lastFinishedAt) { _, _ in refresher.request(load) }
        .onReceive(NotificationCenter.default.publisher(for: .profileWillSwitch)) { _ in
            refresher.invalidate()
            pulses = [:]
        }
    }

    @ViewBuilder
    private func tile(_ station: AuditStation) -> some View {
        let face = AuditStationTile(station: station, pulse: pulses[station.id])
        if station.isOpen {
            Button { viewState.station = station.id } label: { face }
                .buttonStyle(.plain)
        } else {
            face.accessibilityHint("还没开放")
        }
    }

    /// 一张票算齐所有台再一起回写：票旧了 / 楼层变了就整份扔掉
    private func load(_ ticket: Int) async {
        let pid = profileId
        guard !pid.isEmpty else { return }
        let ctx = AuditStationContext(profileId: pid, modelContext: modelContext)
        var fresh: [AuditStationID: AuditStationPulse] = [:]
        for station in AuditStation.all {
            guard let pulse = station.pulse else { continue }
            fresh[station.id] = await pulse(ctx)
            guard refresher.isCurrent(ticket), pid == profileId else { return }
        }
        pulses = fresh
    }
}

/// 推进去的台：iOS 设 inline 标题；mac 右栏不带 navigationTitle（同记忆二级页）
private struct AuditStationTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

/// 一块方块：台名 / 现场数字（没事写一句状态）/ 一行小字 + 右下图标
private struct AuditStationTile: View {
    let station: AuditStation
    let pulse: AuditStationPulse?

    @Environment(\.settingsMetrics) private var m

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) { face }
            .background(background, in: shape)
            .overlay { shape.strokeBorder(border, lineWidth: borderWidth) }
            .contentShape(shape)
            .accessibilityElement(children: .combine)
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(station.name)
                .font(m.body.weight(.semibold))
                .foregroundColor(primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let figure = pulse?.figure {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(figure)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(pulse?.label ?? "")
                        .font(m.caption)
                        .lineLimit(1)
                }
                .foregroundColor(primary)
            } else {
                Text(pulse?.label ?? station.placeholder)
                    .font(m.body.weight(.medium))
                    .foregroundColor(primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            HStack(alignment: .bottom, spacing: 6) {
                Text(station.note)
                    .font(m.caption)
                    .foregroundColor(secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: station.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }

    // 灰着的台一律半透明 mainBg + 灰字；开着的照注册表的底色
    private var background: Color {
        guard station.isOpen else { return Theme.mainBg.opacity(0.5) }
        switch station.surface {
        case .userBubble: return Theme.userBubble
        case .assistantBubble: return Theme.assistantBubble
        case .outlined: return Theme.mainBg
        }
    }

    private var primary: Color {
        guard station.isOpen else { return Theme.textMuted }
        switch station.surface {
        case .userBubble: return Theme.userText
        case .assistantBubble: return Theme.assistantText
        case .outlined: return Theme.textPrimary
        }
    }

    private var secondary: Color { station.isOpen ? primary.opacity(0.7) : Theme.textMuted.opacity(0.8) }

    private var border: Color {
        station.isOpen && station.surface == .outlined ? Theme.branchIndicator : Theme.textMuted.opacity(0.15)
    }

    private var borderWidth: CGFloat { station.isOpen && station.surface == .outlined ? 1.5 : 0.5 }
}
