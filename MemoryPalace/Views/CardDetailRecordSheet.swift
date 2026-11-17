import MemoryCore
import SwiftUI

// MARK: - 「详细度」一次重写的记录：送去时的正文、重写成的、发给模型的全文、模型原样回的
// 从记忆日志里那一行、或那一笔的「看发给模型的全文」点进来

struct CardDetailRecordSheet: View {
    let record: CardDetailRecord
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
                        Text("没重写成：\(failure)。正文没动。")
                            .font(m.caption)
                            .foregroundColor(Theme.danger)
                    }
                }
                .panelRowBackground()

                Section("正文") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("送去时").font(m.caption.weight(.semibold)).foregroundColor(Theme.textSecondary)
                        Text(record.content).font(m.body).foregroundColor(Theme.textPrimary)
                        if let text = record.text {
                            Text("重写成「\(CardDetailRewrite.word(record.level))」").font(m.caption.weight(.semibold)).foregroundColor(Theme.textSecondary)
                                .padding(.top, 4)
                            Text(text).font(m.body).foregroundColor(Theme.textPrimary)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                }
                .panelRowBackground()

                ForEach(Array(record.calls.enumerated()), id: \.offset) { index, call in
                    Section(record.calls.count > 1 ? "发给模型的 · 第 \(index + 1) 次" : "发给模型的") {
                        textLink("提示词", call.system)
                        textLink("材料：原文和这条现在的样子", call.user)
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
            .panelSheetTitle(CardDetailRewrite.name)
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

    static func headline(_ record: CardDetailRecord) -> String {
        "\(stamp.string(from: record.at)) · 《\(record.windowTitle)》 · \(CardDetailRewrite.label(record.level))"
    }

    /// 「模型 · $0.004 · 上下文摘要那一段 12 条」
    static func detail(_ record: CardDetailRecord) -> String {
        var parts = [record.model]
        if let cost = record.costUSD { parts.append(String(format: "$%.3f", cost)) }
        switch record.source {
        case .segment: parts.append("上下文摘要那一段 \(record.lines) 条")
        case .span: parts.append("写手那一截 \(record.lines) 条" + (record.before > 0 ? " + 前文 \(record.before) 条" : ""))
        }
        if record.retried { parts.append("第一次格式不对，重问过一次") }
        return parts.joined(separator: " · ")
    }
}
