import MemoryCore
import SwiftUI

enum RecallCardPresentation: Equatable {
    case hidden
    case legacy
    case receipt(RecallReceiptCardModel)

    /// P1：旧视图只画 `decision.selected` 分组 + reads，所以这里只做 `ledgerGroups` 投影，
    /// 不跑 `RecallCardModel.make` 的全量计算（v2 分项等 P2 换视图后再用，并按回执版本缓存）。
    static func make(receipt: RecallTurnReceipt?, legacyHitsEmpty: Bool, mode: DisclosureMode) -> Self {
        guard mode != .hidden else { return .hidden }
        guard let receipt else { return .legacy }
        guard !receipt.decision.selected.isEmpty || !receipt.reads.isEmpty else {
            return legacyHitsEmpty ? .hidden : .legacy
        }
        let groups = RecallCardModel.ledgerGroups(receipt.decision.selected).map { ledger in
            RecallReceiptCardModel.Group(kind: ledger.kind,
                                         rows: ledger.rows.map { .init(title: $0.title, detail: $0.detail, text: $0.text) })
        }
        return .receipt(.init(groups: groups, reads: receipt.reads, injectionRecord: receipt.injectionRecord))
    }
}

struct RecallReceiptCardModel: Equatable {
    struct Row: Equatable {
        let title: String
        let detail: String?
        let text: String
    }

    struct Group: Equatable {
        let kind: RecallSourceRef.Kind
        let rows: [Row]

        var title: String {
            switch kind {
            case .page: "档案页"
            case .card: "要点卡"
            case .fragment: "碎片"
            }
        }
    }

    let groups: [Group]
    let reads: [RecallReadReceipt]
    let injectionRecord: MemoryInjectionRecord?
}

struct MessageRecallCardView: View {
    let node: MessageNode
    @AppStorage(DisclosureKind.recall.key) private var modeRaw = DisclosureKind.recall.migratedDefault.rawValue
    @Environment(ConversationViewModel.self) private var viewModel: ConversationViewModel?

    var body: some View {
        let mode = DisclosureMode(rawValue: modeRaw) ?? .inline
        Group {
            if mode != .hidden {
                let receipt = if let viewModel {
                    viewModel.cachedRecallReceipt(node)
                } else {
                    node.recallReceipt
                }
                switch RecallCardPresentation.make(receipt: receipt, legacyHitsEmpty: node.recallHits.isEmpty, mode: mode) {
                case .hidden:
                    EmptyView()
                case .legacy:
                    RecallCardView(node: node)
                case .receipt(let model):
                    if node.role == "assistant" {
                        RecallReceiptCardView(model: model, mode: mode)
                    }
                }
            }
        }
    }
}

struct RecallReceiptCardView: View {
    let model: RecallReceiptCardModel
    let mode: DisclosureMode
    @Environment(\.themeScope) private var themeScope
    @AppStorage("fontScale") private var fontScale = 1.2
    @State private var expanded = false
    @State private var showSheet = false
    private var palette: ThemePalette { themeScope.palette }
    private var labelSize: CGFloat { 13.5 * (fontScale > 0 ? fontScale : 1.2) * 0.95 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if mode == .sheet { showSheet = true } else { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    RecallPalaceMark()
                        .stroke(palette.textMuted, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: labelSize * 0.9, height: labelSize * 0.9)
                        .accessibilityHidden(true)
                    Text("想起来了")
                        .font(.system(size: labelSize))
                    Image(systemName: expanded && mode == .inline ? "chevron.down" : "chevron.right")
                        .font(.system(size: labelSize * 0.72, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundColor(palette.textMuted)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, mode == .inline {
                RecallReceiptCardContent(model: model, rowSpacing: 12, snippetSize: 14)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(palette.accent.opacity(0.4)))
            }
        }
        .sheet(isPresented: $showSheet) {
            DisclosureSheet(title: "想起来了", scope: .chat) {
                RecallReceiptCardContent(model: model, rowSpacing: 14, snippetSize: 15)
            }
        }
    }
}

struct RecallReceiptCardContent: View {
    let model: RecallReceiptCardModel
    let rowSpacing: CGFloat
    let snippetSize: CGFloat
    @Environment(\.themeScope) private var themeScope
    @State private var automaticExpanded = true
    @State private var readsExpanded = true
    private var palette: ThemePalette { themeScope.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            if !model.groups.isEmpty {
                sectionButton("自动带了什么", expanded: $automaticExpanded)
                if automaticExpanded {
                    if let record = model.injectionRecord {
                        Text("钉住 \(record.stableCount) 条 · 合计 \(record.tokens) token")
                            .font(.system(size: 11))
                            .foregroundColor(palette.textMuted)
                    }
                    ForEach(model.groups, id: \.kind.rawValue) { group in
                        VStack(alignment: .leading, spacing: rowSpacing) {
                            Text("\(group.title) \(group.rows.count)")
                                .font(.system(size: 11))
                                .foregroundColor(palette.textMuted)
                            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                                RecallReceiptItemRow(row: row, snippetSize: snippetSize)
                            }
                        }
                    }
                }
            }
            if !model.reads.isEmpty {
                sectionButton("翻了什么", expanded: $readsExpanded)
                if readsExpanded {
                    ForEach(Array(model.reads.enumerated()), id: \.offset) { _, read in
                        Text(verbatim: "\(read.layer) · \(read.target) · \(read.status)")
                            .font(.system(size: snippetSize))
                            .foregroundColor(palette.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func sectionButton(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: snippetSize * 0.72, weight: .medium))
                Spacer(minLength: 0)
            }
            .font(.system(size: snippetSize))
            .foregroundColor(palette.textMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RecallReceiptItemRow: View {
    let row: RecallReceiptCardModel.Row
    let snippetSize: CGFloat
    @Environment(\.themeScope) private var themeScope
    @State private var expanded = false
    private var palette: ThemePalette { themeScope.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: row.title)
                            .font(.system(size: snippetSize))
                            .foregroundColor(palette.textPrimary)
                        if let detail = row.detail {
                            Text(verbatim: detail)
                                .font(.system(size: 11))
                                .foregroundColor(palette.textMuted)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: snippetSize * 0.72, weight: .medium))
                        .foregroundColor(palette.textMuted)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(verbatim: row.text)
                    .font(.system(size: snippetSize))
                    .foregroundColor(palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
