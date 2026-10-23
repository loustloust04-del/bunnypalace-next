import SwiftUI
import SwiftStreamingMarkdown

/// 时间线卡（粟粟 10-03 选 A 竖排，先只读）：竖线 + 圆点，过去实心、将来空心，中间一条「现在」线；
/// 写了 quote 的项点了跳到最近一条含这句话的消息
struct TimelineCardView: View {
    let card: TimelineCard
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?

    private static let mint = Color(red: 0.498, green: 0.722, blue: 0.620)
    private static let nowColor = Color(red: 0.85, green: 0.55, blue: 0.37)

    var body: some View {
        // 一分钟重算一次过去 / 将来（今晚的事过了点自己变实心）
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let nowIndex = card.nowLineIndex(now: now)
            ChatCardShell(kindLabel: "时间线") {
                VStack(alignment: .leading, spacing: 10) {
                    if !card.title.isEmpty { Text(card.title).font(.headline) }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(card.items.enumerated()), id: \.offset) { i, item in
                            if nowIndex == i, i > 0 { nowLine }
                            row(item, past: item.isPast(now: now), last: i == card.items.count - 1 && nowIndex != card.items.count)
                        }
                        if nowIndex == card.items.count { nowLine }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var nowLine: some View {
        HStack(spacing: 6) {
            Capsule().fill(Self.nowColor).frame(width: 14, height: 2)
            Text("现在").font(.caption2.weight(.semibold)).foregroundStyle(Self.nowColor)
            Rectangle().fill(Self.nowColor.opacity(0.4)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityLabel("现在")
    }

    @ViewBuilder
    private func row(_ item: TimelineCard.Item, past: Bool, last: Bool) -> some View {
        let linked = !(item.quote ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        HStack(alignment: .top, spacing: 12) {
            // 圆点 + 往下接的竖线
            VStack(spacing: 0) {
                ZStack {
                    if past {
                        Circle().fill(Self.mint).frame(width: 12, height: 12)
                    } else {
                        Circle().strokeBorder(Self.mint, lineWidth: 2).frame(width: 12, height: 12)
                    }
                }
                .padding(.top, 3)
                if !last {
                    Rectangle().fill(CodeBlockStyle.stroke).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                if !item.time.isEmpty {
                    Text(item.time).font(.caption.monospacedDigit()).foregroundStyle(CodeBlockStyle.label)
                }
                Text(item.title).font(.subheadline).opacity(past ? 0.75 : 1)
                if let note = item.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(CodeBlockStyle.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if linked {
                    Label("跳到那条消息", systemImage: "arrow.up.forward").font(.caption2).foregroundStyle(Self.mint)
                }
            }
            .padding(.bottom, last ? 0 : 12)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if linked, let target = jumpTarget(item) { viewModel?.scrollToNodeId = target } }   // 点了才找（不在每次重画时扫整段对话）
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.time, item.title, item.note ?? "", past ? "已过去" : "还没到"].filter { !$0.isEmpty }.joined(separator: "，"))
        .accessibilityAddTraits(linked ? .isButton : [])
    }

    /// 点了跳哪条：当前路径里最近一条正文含 quote 的消息
    private func jumpTarget(_ item: TimelineCard.Item) -> String? {
        guard let viewModel, item.quote != nil else { return nil }
        return TimelineCard.jumpTarget(quote: item.quote, in: viewModel.currentPath.map { ($0.id, $0.content) })
    }
}
