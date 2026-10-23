import SwiftUI

// MARK: - 小芽 v2 · 账本（plan-小芽-v2 §4.4；设计 design-小芽-v2.html §05）
// 她改过的每一笔，新的在上；能撤的给「撤销」，撤过的 / 撤销记录只显示状态。

struct AssistantLedgerView: View {
    let engine: AssistantEngine
    let skin: XiaoyaSkin
    let onUndo: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if engine.ledger.entries.isEmpty {
                    Text("还没有盖过章的改动")
                        .foregroundStyle(skin.inkMuted)
                        .listRowBackground(skin.card)
                }
                ForEach(engine.ledger.entries.reversed()) { entry in
                    row(entry).listRowBackground(skin.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(skin.paper)
            .navigationTitle("\(AssistantPrompts.assistantName)改过的东西")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }

    private func row(_ entry: AssistantLedgerEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.date.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))
                .font(.system(size: 11.5))
                .foregroundStyle(skin.inkMuted)
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: Theme.F.body)).foregroundStyle(skin.ink)
                Text(entry.category).font(.system(size: 12)).foregroundStyle(skin.inkMuted)
            }
            Spacer(minLength: 8)
            if entry.undoOf != nil {
                EmptyView()
            } else if entry.undone {
                Text("已撤销").font(.system(size: 12)).foregroundStyle(skin.inkMuted)
            } else {
                Button("撤销") { onUndo(entry.actionId) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(skin.inkSoft)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .overlay(Capsule().stroke(skin.line, lineWidth: 1))
            }
        }
        .padding(.vertical, 3)
    }
}
