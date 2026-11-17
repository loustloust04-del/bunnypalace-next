import MemoryCore
import SwiftUI

// MARK: - 「C2 整理」一次的记录：每张新卡的结论 + 发给模型的全文 + 模型原样的回复
// 从记忆日志里做梦那一行、或做梦的某一笔点进来。功能版：样子之后另修；Undo 在记忆日志那一笔上

/// 记忆日志页用它开记录：读盘在后台，读不到（过期清掉了）给一句话
enum FragmentDreamRecordReader {
    static let expiredMessage = "这次整理的记录已经清掉了（只留 \(FragmentDreamRecord.keepDays) 天）"

    static func load(id: String, profileId: String) async -> FragmentDreamRecord? {
        await Task.detached(priority: .userInitiated) {
            FragmentDreamRecord.load(id: id, memoryRoot: FileLibraryStore.memoryRoot(profileId: profileId))
        }.value
    }
}

struct FragmentDreamRecordSheet: View {
    let record: FragmentDreamRecord
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(Self.headline(record))
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text(Self.detail(record))
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                    if let failure = record.failure {
                        Text("没跑成：\(failure)。这批卡原样留在 Draft。")
                            .font(m.caption)
                            .foregroundColor(Theme.danger)
                    } else if record.skipped {
                        Text("没做（预算闸拦下、模型没回或开关关了）。这批卡原样留在 Draft。")
                            .font(m.caption)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .panelRowBackground()

                Section("每条新条目") {
                    ForEach(record.cards) { card in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.title(card))
                                .font(m.caption.weight(.semibold))
                                .foregroundColor(card.applied == FragmentDream.Applied.unsure.rawValue ? Theme.danger : Theme.textSecondary)
                            Text(card.content)
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                            ForEach(Self.lines(card), id: \.self) { line in
                                Text(line)
                                    .font(m.caption)
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                    }
                }
                .panelRowBackground()

                ForEach(Array(record.calls.enumerated()), id: \.offset) { index, call in
                    Section(record.calls.count > 1 ? "发给模型的 · 第 \(index + 1) 次" : "发给模型的") {
                        textLink("提示词和「聊天时本来就带着的内容」", call.system)
                        textLink("材料：已有的条目、原文、新条目", call.user)
                        if let reply = call.reply {
                            textLink("模型原样回的", reply)
                        } else {
                            Text(call.error.map { "没回：\($0)" } ?? "没回（被拦下了）")
                                .font(m.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .panelRowBackground()
                }
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .toolPageBackground()
            .panelSheetTitle(FragmentDream.actor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            #if os(macOS)
            .frame(minWidth: 440, idealWidth: 560, minHeight: 480, idealHeight: 640)
            #endif
        }
    }

    private func textLink(_ title: String, _ text: String) -> some View {
        NavigationLink {
            FragmentDreamTextPage(title: title, text: text)
                .environment(\.settingsMetrics, m)
        } label: {
            HStack {
                Text(title)
                    .font(m.body)
                    .foregroundColor(Theme.textPrimary)
                Spacer(minLength: 8)
                Text("\(text.count) 字")
                    .font(m.caption.monospaced())
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    // MARK: 纯函数（可测）

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    static func headline(_ record: FragmentDreamRecord) -> String {
        "\(stamp.string(from: record.at)) · 《\(record.windowTitle)》" + (record.label.map { " · \($0)" } ?? "")
    }

    /// 「模型 · $0.012 · 新卡 11 张 · 对着 8 张已有的卡 · 留下的要你批」
    static func detail(_ record: FragmentDreamRecord) -> String {
        var parts = [record.model]
        if let cost = record.costUSD { parts.append(String(format: "$%.3f", cost)) }
        parts.append("新条目 \(record.cards.count) 条")
        parts.append("对着 \(record.existing) 条已有的" + (record.existingWhole.map { $0 ? "（全部）" : "（挑出来的）" } ?? ""))
        if let deleted = record.deleted, deleted > 0 { parts.append("删过的 \(deleted) 条") }
        if let pages = record.wikiPages, pages > 0 { parts.append("wiki \(pages) 页") }
        parts.append(record.needsReview ? "留下的要你批" : "留下的直接算批过")
        if record.retried { parts.append("第一次格式不对，重问过一次") }
        if record.stray > 0 { parts.append("模型多交了 \(record.stray) 条对不上的") }
        if record.residentCut > 0 { parts.append("聊天时带着的内容太长，有 \(record.residentCut) 字没放进去") }
        if let cut = record.wikiCut, cut > 0 { parts.append("wiki 页太长，有 \(cut) 字没放进去") }
        return parts.joined(separator: " · ")
    }

    /// 「Merge」/「Unsure（模型交的是 merge）」
    static func title(_ card: FragmentDreamRecord.Card) -> String {
        guard let applied = card.applied.flatMap(FragmentDream.Applied.init(rawValue:)) else {
            return card.verdict.map { "没落库（模型交的是 \($0)）" } ?? "没有结论"
        }
        var title = applied.label
        if let reason = card.reason, applied == .dropped { title += "（\(reasonText(reason))）" }
        if applied == .unsure, let verdict = card.verdict, verdict != FragmentVerdict.Action.unsure.rawValue { title += "（模型交的是 \(verdict)）" }
        if applied == .approved || applied == .rewrittenApproved { title += " · Approved" }
        return title
    }

    static func reasonText(_ reason: String) -> String {
        switch FragmentVerdict.Reason(rawValue: reason) {
        case .unsupported: return "原文不支持"
        case .notFact: return "不值得长期记"
        case .inPrompt: return "聊天时本来就带着"
        case .inWiki: return "wiki 页里已经写了"
        case .inArchive: return "已有的条目说全了"
        case .deleted: return "删过"
        case nil: return reason
        }
    }

    static func lines(_ card: FragmentDreamRecord.Card) -> [String] {
        var out: [String] = []
        if let target = card.target {
            out.append((card.reason == FragmentVerdict.Reason.deleted.rawValue ? "删过的那条：" : "已有的那张：") + target)
        }
        if let text = card.text { out.append("模型写的：\(text)") }
        if let why = card.why { out.append("理由：\(why)") }
        if let problem = card.problem { out.append("没照做：\(problem)") }
        return out
    }
}

/// 一整段长文字（几万字的提示词 / 原文）：按行懒加载，能选中复制
struct FragmentDreamTextPage: View {
    let title: String
    let text: String
    @Environment(\.settingsMetrics) private var m
    @State private var lines: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(m.caption.monospaced())
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
        .toolPageBackground()
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .task { lines = text.components(separatedBy: "\n") }
    }
}
