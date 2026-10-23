import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageProvider: TimelineProvider {
    private static var sample: UsageSnapshot {
        UsageSnapshot(
            sessionName: "cc",
            model: "Opus 5",
            ctx: 47,
            fiveHour: 20,
            sevenDay: 88,
            updatedUnix: Int(Date().timeIntervalSince1970) - 180
        )
    }

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        // 图库预览没有真数据也要好看；真桌面上一律读 App Group。
        let snapshot = context.isPreview ? Self.sample : UsageSnapshotStore.read()
        completion(UsageEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let entry = UsageEntry(date: now, snapshot: UsageSnapshotStore.read())
        // 新帧到达时 app 会主动 reloadTimelines；这条 15 分钟兜底只保证「x MIN AGO」不卡死。
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LiveActivityKinds.usageWidget, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("CC 用量")
        .description("Claude Code 的 ctx / 5h / 7d")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// 一份数据四种画法。锁屏三 accessory 是系统单色渲染——**用长度代替颜色**（环 / 横条 / 一行字）；
/// 桌面 systemSmall 才上马卡龙配色。
/// 数据来自 App Group 快照 = 「上次 app 开着时的数字」，所以每种形态都显式标 x MIN AGO。
struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    @ViewBuilder
    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: desktopSmall
        }
    }

    // MARK: - 锁屏（单色，长度代替颜色）

    private var circular: some View {
        Gauge(value: gaugeValue(entry.snapshot?.ctx), in: 0...100) {
            relativeText
                .font(PixelFont.font(.small))
        } currentValueLabel: {
            Text(digits(entry.snapshot?.ctx))
                .font(PixelFont.font(.body))
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityLabel(Text("CTX \(percent(entry.snapshot?.ctx))"))
        .containerBackground(.clear, for: .widget)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(modelText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                agoText
            }
            .font(PixelFont.font(.small))

            bar("CTX", entry.snapshot?.ctx)
            bar("5H", entry.snapshot?.fiveHour)
            bar("7D", entry.snapshot?.sevenDay)
        }
        .containerBackground(.clear, for: .widget)
    }

    private var inline: some View {
        Label {
            Text("CTX \(percent(entry.snapshot?.ctx)) · ") + agoText
        } icon: {
            Image(systemName: "terminal")
        }
        .containerBackground(.clear, for: .widget)
    }

    /// 长度 = 百分比；缺数据时只剩底槽，配上右侧 `--`。
    private func bar(_ label: String, _ value: Int?) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .frame(width: 24, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.primary.opacity(0.25))
                    Capsule()
                        .fill(.primary)
                        .frame(width: geo.size.width * gaugeValue(value) / 100)
                }
            }
            .frame(height: 5)
            Text(percent(value))
                .frame(width: 28, alignment: .trailing)
        }
        .font(PixelFont.font(.small))
        .accessibilityElement(children: .combine)
    }

    // MARK: - 桌面（彩色）

    private var desktopSmall: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(modelText)
                .font(PixelFont.font(.body))
                .foregroundStyle(Palette.model)
                .pixelGlow(Palette.model)
                .lineLimit(1)

            HStack(spacing: 5) {
                cell("CTX", entry.snapshot?.ctx)
                cell("5H", entry.snapshot?.fiveHour)
                cell("7D", entry.snapshot?.sevenDay)
            }

            Spacer(minLength: 0)

            agoText
                .font(PixelFont.font(.small))
                .foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            ZStack {
                Color.black
                PixelScanlines()
            }
        }
    }

    private func cell(_ label: String, _ value: Int?) -> some View {
        let color = value.map(Palette.usage) ?? Palette.dim
        return VStack(spacing: 3) {
            Text(label)
            Text(percent(value))
        }
        .font(PixelFont.font(.small))
        .foregroundStyle(color)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .overlay(Rectangle().stroke(color.opacity(0.45), lineWidth: 0.5))
    }

    // MARK: - 文本

    private var modelText: String {
        "[\(entry.snapshot?.model ?? "--")]"
    }

    /// 系统 `.relative` 自己走秒，widget 不用为了刷新时间戳排 timeline。
    private var relativeText: Text {
        guard let unix = entry.snapshot?.updatedUnix else { return Text("--") }
        return Text(Date(timeIntervalSince1970: TimeInterval(unix)), style: .relative)
    }

    private var agoText: Text {
        guard entry.snapshot != nil else { return Text("NO DATA") }
        return relativeText + Text(" AGO")
    }

    private func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "--"
    }

    private func digits(_ value: Int?) -> String {
        value.map(String.init) ?? "--"
    }

    private func gaugeValue(_ value: Int?) -> Double {
        min(max(Double(value ?? 0), 0), 100)
    }
}
