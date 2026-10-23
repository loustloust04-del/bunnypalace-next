import ActivityKit
import SwiftUI
import WidgetKit

struct CCLiveActivityView: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CCActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(modelText(context.state))
                            .foregroundStyle(Palette.model)
                        Text(statusText(context))
                            .foregroundStyle(phaseColor(context.state.phase))
                    }
                    .font(PixelFont.font(.small))
                    .lineLimit(1)
                    .pixelGlow(Palette.model)
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    timerOrFrozenIcon(context)
                        .font(PixelFont.font(.body))
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        usageRow(context.state)
                        if let detail = detailText(context.state) {
                            Text(detail)
                                .font(PixelFont.font(.small))
                                .foregroundStyle(Palette.dim)
                                .lineLimit(2)
                        }
                    }
                    .overlay(PixelScanlines().allowsHitTesting(false))
                }
            } compactLeading: {
                PixelIcon(
                    bitmap: PixelGlyph.reload,
                    size: 16,
                    color: phaseColor(context.state.phase)
                )
                .accessibilityLabel(Text(statusText(context)))
            } compactTrailing: {
                Text(compactTrailingText(context.state))
                    .font(PixelFont.font(.body))
                    .foregroundStyle(
                        context.state.phase == .waiting
                            ? Palette.apricot
                            : usageColor(context.state.ctx)
                    )
                    .lineLimit(1)
            } minimal: {
                Circle()
                    .fill(phaseColor(context.state.phase))
                    .frame(width: 9, height: 9)
                    .accessibilityLabel(Text(statusText(context)))
            }
            .keylineTint(Palette.mint)
        }
    }

    private func lockScreen(
        _ context: ActivityViewContext<CCActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(modelText(context.state))
                    .foregroundStyle(Palette.model)
                    .lineLimit(1)
                Text(statusText(context))
                    .foregroundStyle(phaseColor(context.state.phase))
                    .lineLimit(1)
                Spacer(minLength: 8)
                timerOrFrozenIcon(context)
            }
            .font(PixelFont.font(.body))

            usageRow(context.state)

            if context.state.phase == .waiting,
               let detail = detailText(context.state) {
                Text(detail)
                    .font(PixelFont.font(.small))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black)
        .overlay(PixelScanlines().allowsHitTesting(false))
    }

    private func usageRow(_ state: CCActivityState) -> some View {
        HStack(spacing: 5) {
            usageCell("ctx", state.ctx)
            usageCell("5h", state.fiveHour)
            usageCell("7d", state.sevenDay)
        }
    }

    private func usageCell(_ label: String, _ value: Int?) -> some View {
        let color = usageColor(value)
        return Text("[\(label):\(value.map { "\($0)%" } ?? "--")]")
            .font(PixelFont.font(.small))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .overlay(Rectangle().stroke(color.opacity(0.45), lineWidth: 0.5))
            .lineLimit(1)
    }

    @ViewBuilder
    private func timerOrFrozenIcon(
        _ context: ActivityViewContext<CCActivityAttributes>
    ) -> some View {
        if context.isStale {
            Text("--:--")
                .foregroundStyle(Palette.dim)
        } else if context.state.phase == .working || context.state.phase == .waiting {
            if let sinceUnix = context.state.sinceUnix {
                Text(
                    timerInterval: Date(timeIntervalSince1970: TimeInterval(sinceUnix))...Date.distantFuture,
                    pauseTime: nil,
                    countsDown: false,
                    showsHours: false
                )
                .foregroundStyle(phaseColor(context.state.phase))
            } else {
                Text("--:--")
                    .foregroundStyle(Palette.dim)
            }
        } else {
            Image(systemName: context.state.phase == .done ? "checkmark" : "pause.fill")
                .foregroundStyle(phaseColor(context.state.phase))
                .accessibilityLabel(context.state.phase == .done ? "DONE" : "IDLE")
        }
    }

    private func statusText(
        _ context: ActivityViewContext<CCActivityAttributes>
    ) -> String {
        let status: String
        switch context.state.phase {
        case .idle: status = "IDLE"
        case .working: status = "WORKING"
        case .waiting: status = "等你"
        case .done: status = "DONE"
        }
        return context.isStale ? "\(status) · STALE" : status
    }

    private func compactTrailingText(_ state: CCActivityState) -> String {
        if state.phase == .waiting { return "等你" }
        return state.ctx.map { "\($0)%" } ?? "--"
    }

    private func modelText(_ state: CCActivityState) -> String {
        "[\(state.model ?? "--")]"
    }

    private func detailText(_ state: CCActivityState) -> String? {
        guard let detail = state.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else { return nil }
        return detail
    }

    private func usageColor(_ value: Int?) -> Color {
        value.map(Palette.usage) ?? Palette.dim
    }

    private func phaseColor(_ phase: CCActivityPhase) -> Color {
        switch phase {
        case .working: return Palette.mint
        case .waiting: return Palette.apricot
        case .done: return Palette.dim
        case .idle: return Palette.placeholder
        }
    }
}
