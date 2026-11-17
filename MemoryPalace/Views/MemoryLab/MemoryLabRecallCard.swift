import MemoryCore
import SwiftUI

// MARK: - 记忆实验台：一句回复下面的「想起来了」（plan-memory-lab §4）
// 三节标题 = 设置里那三节的原名：每轮都带 / 自动推送 / {助手}主动翻。分项用真聊天那张卡的全量模型（`RecallCardModel.groups` / `read`），
// 不数 token。某一节是空的就写一句为什么空，不整节消失。

/// 三条路各放了什么（纯值，从一条记录算出来）
struct MemoryLabRecall: Equatable {
    struct Row: Equatable {
        let title: String
        /// 「聊到「…」」/ 没推送的原因
        let note: String?
        /// 点开看的全文（推送进去的那一块原样）
        let text: String?
    }

    struct Pushed: Equatable {
        let name: String
        let rows: [Row]
    }

    let everyRound: [RecallCardModel.Group]
    let pushed: [Pushed]
    let missed: [Row]
    let reads: [RecallCardModel.Read]
    /// 「想起来了 N」：推送的 + 翻到了的
    let count: Int
    /// 那一节空着时写的那句；nil = 有东西
    let everyRoundEmpty: String?
    let pushEmpty: String?
    let pullEmpty: String?

    typealias Kind = RecallDeliveryItem.Kind
    /// 自动推送的三种，按卡上的顺序
    static let pushKinds: [(kind: String, name: String)] = [
        (Kind.fragment, "C2 原子事实"), (Kind.page, "档案页"), (Kind.card, "要点卡"),
    ]

    static func make(_ record: MemoryLabRecord, assistant: String) -> MemoryLabRecall {
        let receipt = record.happened?.receipt
        let decision = receipt?.decision
        let items = receipt?.delivery?.items ?? []
        let selected = decision?.selected ?? []
        let candidates = decision?.candidates ?? []
        let params = record.params
        let tuning = params?.tuning ?? decision?.tuning ?? .defaults

        /// 那句话里点到了这一条的哪个名字
        func said(_ item: RecallItem?) -> String? {
            item?.identities.first { RecallLexical.names([$0], in: record.input.text, tuning: tuning) }
                .map { "聊到「\($0)」" }
        }

        let pushKindSet = Set(pushKinds.map(\.kind))
        let pushed = pushKinds.compactMap { kind, name -> Pushed? in
            let rows = items.filter { $0.kind == kind }.map { item in
                let source = selected.first { MemoryDelivery.key($0.source) == item.ref }
                return Row(title: item.shown, note: said(source), text: source?.text)
            }
            return rows.isEmpty ? nil : Pushed(name: name, rows: rows)
        }

        // 差一点：回执里有、没进 selected 的（有原因的在前）
        let chosen = Set(selected.map(\.source))
        var seen = Set<RecallSourceRef>()
        func title(_ source: RecallSourceRef) -> String {
            candidates.first { $0.source == source }.map(Self.title) ?? (source.kind == .fragment ? "一条原子事实" : source.path)
        }
        var missed: [Row] = []
        for suppression in decision?.suppressions ?? [] where !chosen.contains(suppression.source) {
            guard seen.insert(suppression.source).inserted else { continue }
            let item = candidates.first { $0.source == suppression.source }
            let note = [said(item), reason(suppression.reason)].compactMap { $0 }.joined(separator: " · ")
            missed.append(Row(title: title(suppression.source), note: note, text: item?.text))
        }
        for item in candidates where !chosen.contains(item.source) && seen.insert(item.source).inserted {
            missed.append(Row(title: title(item.source), note: said(item), text: item.text))
        }

        let everyRound = receipt?.delivery.map {
            RecallCardModel.groups(items: items.filter { !pushKindSet.contains($0.kind) }, selected: selected,
                                   gate: $0.gate, assistantName: assistant).map(renamed)
        } ?? []
        let reads = receipt?.reads ?? []
        let goodReads = RecallCardModel.tally(hitItems: 0, reads: reads, attempts: []).goodReads

        let anyChecked = (params?.items ?? [:]).values.contains(true) || params?.everyRound == true || params?.systemPush == true
        let push = params?.systemPush ?? tuning.archiveTriggerEnabled
        let asked = record.happened?.reply != nil || !(record.happened?.rounds ?? []).isEmpty
        return MemoryLabRecall(
            everyRound: everyRound,
            pushed: pushed,
            missed: missed,
            reads: reads.map(RecallCardModel.read),
            count: pushed.reduce(0) { $0 + $1.rows.count } + goodReads,
            everyRoundEmpty: everyRound.isEmpty ? (anyChecked ? "勾着的这时都是空的" : "都没勾") : nil,
            pushEmpty: !pushed.isEmpty ? nil
                : !push ? "关着"
                : decision?.gateReason == .shortInput ? "太短的不找"
                : "这句没推送什么",
            pullEmpty: !reads.isEmpty ? nil
                : params?.recallTool != true ? "关着"
                : asked ? "这句没去翻" : "没问成模型，没翻")
    }

    /// 一条推送的东西叫什么：同真聊天卡旧账的取法（页 = 那一行 [[…]]、卡 = 条目名、记忆条目 = 第一行），去掉 [[ ]]
    static func title(_ item: RecallItem) -> String {
        let title = RecallCardModel.ledgerGroups([item]).first?.rows.first?.title ?? item.source.path
        return title.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// 没推送的原因：同真聊天卡上的说法
    static func reason(_ reason: RecallSuppression.Reason) -> String {
        switch reason {
        case .cooldown: return "冷却"
        case .budget: return "超预算"
        case .pageLimit: return "页数上限"
        case .unavailable: return "不可用"
        }
    }

    /// 每轮都带那几项的名字跟参数卡上的 chip 一样（设置 › 开窗口带什么 的原名）
    private static func renamed(_ group: RecallCardModel.Group) -> RecallCardModel.Group {
        let names = [Kind.rootIndex: "wiki 目录", Kind.pinned: "钉住的", Kind.previousWindow: "上一个窗口最后几条",
                     Kind.legacyFragment: "C2 原子事实", Kind.cardIndex: "记忆条目的目录"]
        guard let name = names[group.kind] else { return group }
        return RecallCardModel.Group(kind: group.kind, name: name, unit: group.unit, isHit: group.isHit, tokens: group.tokens,
                                     count: group.count, rows: group.rows, note: group.note)
    }
}

struct MemoryLabRecallCard: View {
    let recall: MemoryLabRecall
    let assistant: String

    @Environment(\.settingsMetrics) private var m
    @State private var everyRoundOpen = false
    @State private var openRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            everyRoundSection
            gap
            section("自动推送", empty: recall.pushEmpty)
            ForEach(recall.pushed, id: \.name) { group in
                caption("\(group.name) \(group.rows.count)")
                ForEach(Array(group.rows.enumerated()), id: \.offset) { i, row in
                    rowView(row, id: "\(group.name)-\(i)", muted: false)
                }
            }
            if !recall.missed.isEmpty {
                caption("差一点，没推送")
                ForEach(Array(recall.missed.enumerated()), id: \.offset) { i, row in
                    rowView(row, id: "missed-\(i)", muted: true)
                }
            }
            gap
            section("\(assistant)主动翻", empty: recall.pullEmpty)
            ForEach(Array(recall.reads.enumerated()), id: \.offset) { _, read in
                VStack(alignment: .leading, spacing: 1) {
                    Text(read.title).font(m.body).foregroundColor(Theme.textPrimary)
                    Text(read.status).font(m.caption).foregroundColor(Theme.textMuted)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.mainBg, in: RoundedRectangle(cornerRadius: MemoryAuditStyle.corner, style: .continuous))
    }

    @ViewBuilder
    private var everyRoundSection: some View {
        if recall.everyRound.isEmpty {
            section("每轮都带", empty: recall.everyRoundEmpty)
        } else {
            Button {
                everyRoundOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("每轮都带").font(m.body).foregroundColor(Theme.textSecondary)
                    Text("\(recall.everyRound.count) 项").font(m.caption).foregroundColor(Theme.textMuted)
                    Spacer(minLength: 0)
                    Image(systemName: everyRoundOpen ? "chevron.down" : "chevron.right")
                        .font(m.caption).foregroundColor(Theme.textMuted)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if everyRoundOpen {
                // 一项一行：名字（同参数卡 chip）+ 数量；`row.title` 是回执里的短文（「根索引 4 行」），跟这一行重复，不再列
                ForEach(recall.everyRound, id: \.kind) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(group.name).font(m.body).foregroundColor(Theme.textPrimary)
                            Text("\(group.count) \(group.unit)").font(m.caption).foregroundColor(Theme.textMuted)
                        }
                        if let note = group.note {
                            Text(note).font(m.caption).foregroundColor(Theme.textMuted)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var gap: some View { Color.clear.frame(height: 10) }

    private func section(_ title: String, empty: String?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(m.body).foregroundColor(Theme.textSecondary)
            if let empty { Text(empty).font(m.caption).foregroundColor(Theme.textMuted) }
        }
        .padding(.vertical, 3)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(m.caption).foregroundColor(Theme.textMuted).padding(.top, 8).padding(.bottom, 2)
    }

    private func rowView(_ row: MemoryLabRecall.Row, id: String, muted: Bool) -> some View {
        let open = openRow == id
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                guard row.text != nil else { return }
                openRow = open ? nil : id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(m.body).foregroundColor(muted ? Theme.textMuted : Theme.textPrimary)
                            .lineLimit(open ? nil : 2)
                        if let note = row.note, !note.isEmpty {
                            Text(note).font(m.caption).foregroundColor(Theme.textMuted)
                        }
                    }
                    Spacer(minLength: 0)
                    if row.text != nil {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(m.caption).foregroundColor(Theme.textMuted)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, let text = row.text {
                Text(text).font(m.secondary).foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MemoryEntryChip.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}
