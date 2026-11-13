#if os(iOS)
import SwiftUI

/// page2「状态」小组件（docs/design-status-widget.html 小号 / 中号）：按最差的那串决定样子；点按进状态面板那一串
struct StatusWidgetView: View {
    var size: WidgetSize = .small
    var onOpen: (_ strandID: String) -> Void

    @State private var snapshot = StatusSnapshot.shared
    @State private var bridge = CCBridgeWebSocketClient.shared
    @Environment(ProfileManager.self) private var profiles: ProfileManager?
    @Environment(\.isPage2Active) private var desktopActive
    @Environment(\.page2Date) private var desktopDate
    @Environment(\.colorScheme) private var scheme

    private var palette: StatusPalette { StatusPalette(scheme) }

    /// 分钟级刷新相对时间 + 花园自检缓存（不另开高频定时器；body 只读 StatusSnapshot 里的缓存）
    var body: some View {
        TimelineView(.everyMinute) { timeline in
            card(now: max(desktopDate, timeline.date))
                .onChange(of: timeline.date) { _, _ in if desktopActive { refreshGarden() } }
        }
        .task(id: desktopActive) {
            guard desktopActive else { return }
            refreshGarden()
            snapshot.refreshIfNeeded()
            await snapshot.refreshNotificationPermission()
        }
        .onChange(of: bridge.isConnected) { _, connected in
            guard desktopActive else { return }
            refreshGarden()
            if connected { snapshot.refreshIfNeeded() }
        }
        .onChange(of: bridge.lastError) { _, _ in if desktopActive { refreshGarden() } }
    }

    private func refreshGarden() {
        snapshot.refreshGarden(profileId: profiles?.currentProfile.id ?? "")
    }

    private func card(now: Date) -> some View {
        let strands = StatusModel.strands(sources: snapshot.sources, garden: snapshot.garden, now: now)
        let worst = StatusModel.worst(strands)
        return Group {
            if size == .small {
                small(strands: strands, worst: worst, now: now)
            } else {
                medium(strands: strands, worst: worst, now: now)
            }
        }
        .padding(.horizontal, 15).padding(.top, 14).padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { onOpen(worst?.id ?? StatusModel.gardenID) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("状态：\(StatusModel.headline(strands, now: now).title)")
    }

    // MARK: 小号：一串 + 结论

    @ViewBuilder
    private func small(strands: [StatusStrand], worst: StatusStrand?, now: Date) -> some View {
        let shown = snapshot.sources.isEmpty && worst?.verdict == .ok ? nil : worst
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(shown?.title ?? "状态")
                    .font(.system(size: 12)).tracking(3).foregroundStyle(palette.sub).lineLimit(1)
                Spacer(minLength: 4)
                Text(shown.map { smallTime($0, now: now) } ?? "")
                    .font(.custom("Georgia", size: 13).italic()).foregroundStyle(palette.faint)
            }
            StatusStrandView(beads: shown?.beads ?? [], look: shown?.look ?? .empty, beadR: 4.3, fallKey: shown?.isGarden == true ? nil : shown?.id)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, -4)
            verdict(shown, now: now)
        }
    }

    @ViewBuilder
    private func verdict(_ strand: StatusStrand?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch strand?.verdict {
            case .ok?:
                bigLine(number: strand?.lines.count ?? 0, text: strand?.isGarden == true ? "项都好" : "条都通", bad: false)
            case .bad(let n)?:
                bigLine(number: n, text: "条不通", bad: true)
                Text(StatusModel.namesPreview(strand?.badLines.map(\.name) ?? []))
                    .font(.system(size: 12)).foregroundStyle(palette.faint).lineLimit(1)
            case .stale?:
                Text("检修没跑").font(.system(size: 15, weight: .semibold)).tracking(1).foregroundStyle(palette.faint)
                Text("上次是 \(strand?.checkedAt.map { StatusTime.format($0, now: now) } ?? "很久以前")")
                    .font(.system(size: 12)).foregroundStyle(palette.faint).lineLimit(1)
            default:
                Text("还没有检修记录").font(.system(size: 14, weight: .medium)).foregroundStyle(palette.faint).lineLimit(1)
            }
        }
    }

    private func bigLine(number: Int, text: String, bad: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(number)").font(.custom("Georgia", size: 30)).tracking(-0.5)
            Text(text).font(.system(size: 15, weight: .semibold)).tracking(1)
        }
        .foregroundStyle(bad ? palette.badText : palette.ink)
        .lineLimit(1)
    }

    private func smallTime(_ strand: StatusStrand, now: Date) -> String {
        if strand.isGarden { return "刚刚" }
        guard let at = strand.checkedAt else { return "" }
        return strand.verdict == .stale ? StatusTime.ago(at, now: now) : StatusTime.format(at, now: now)
    }

    // MARK: 中号：最多三串，坏的排最上

    private func medium(strands: [StatusStrand], worst: StatusStrand?, now: Date) -> some View {
        let rows = Array(strands.enumerated().sorted { a, b in
            a.element.verdict.rank != b.element.verdict.rank ? a.element.verdict.rank > b.element.verdict.rank : a.offset < b.offset
        }.map(\.element).prefix(3))
        let latest = strands.filter { !$0.isGarden }.compactMap(\.checkedAt).max()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("状态").font(.system(size: 12)).tracking(3).foregroundStyle(palette.sub)
                Spacer(minLength: 4)
                Text(latest.map { StatusTime.format($0, now: now) } ?? "")
                    .font(.custom("Georgia", size: 13).italic()).foregroundStyle(palette.faint)
            }
            VStack(spacing: 6) {
                if snapshot.sources.isEmpty {
                    row(label: "检修", beads: [], look: .empty, status: "还没有记录", bad: false, key: nil)
                }
                ForEach(rows) { strand in
                    row(label: strand.title, beads: strand.beads, look: strand.look,
                        status: rowStatus(strand), bad: strand.look == .bad, key: strand.isGarden ? nil : strand.id)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.top, 4)
        }
    }

    private func row(label: String, beads: [StatusStrandDrawing.Bead], look: StatusStrandDrawing.Look,
                     status: String, bad: Bool, key: String?) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).tracking(2).foregroundStyle(palette.sub)
                .lineLimit(1).frame(width: 62, alignment: .leading)
            StatusStrandView(beads: beads, look: look, beadR: 3, star: false, fallKey: key)
                .frame(height: 38)
            Text(status).font(.system(size: 12, weight: bad ? .semibold : .regular))
                .foregroundStyle(bad ? palette.badText : palette.faint)
                .lineLimit(1).frame(width: 92, alignment: .trailing)
        }
    }

    private func rowStatus(_ strand: StatusStrand) -> String {
        switch strand.verdict {
        case .bad(let n): return "\(n) 条不通"
        case .stale: return "检修没跑"
        case .ok: return strand.isGarden ? "都好" : "\(strand.lines.count) 条都通"
        }
    }
}
#endif
