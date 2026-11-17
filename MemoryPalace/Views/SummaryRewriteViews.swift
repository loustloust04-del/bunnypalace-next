import MemoryCore
import SwiftUI
import SwiftData

// MARK: - A2 / A3 的 Rewrite · Undo · History（窗口总结页、上下文摘要页、窗口列表共用；状态是同一份 `SummaryRewriteStatus`）

/// 等她确认的那一问
struct SummaryRewriteAsk: Identifiable, Equatable {
    let id = UUID()
    let target: SummaryRewrite.Target
    let conversationId: String
    let windowTitle: String
    /// 只重写一段时：那一段的标题
    var segmentTitle = ""
    /// 这个窗口能重写的 A2 段数（整个窗口重写时报给她）
    var segmentCount = 0

    /// 确认框的字（纯函数，可测）：重写什么、用哪个模型、会花钱、能 Undo
    static func text(_ ask: SummaryRewriteAsk, a2Model: String, a3Model: String) -> String {
        let window = ask.windowTitle.isEmpty ? "没有标题的窗口" : ask.windowTitle
        let tail = "会调模型、产生花费，不看写入预算。重写前的版本留着，不满意能 Undo；没写成的原样保留。"
        switch ask.target {
        case .window:
            let a2 = ask.segmentCount > 0 ? "已有的 \(ask.segmentCount) 段上下文摘要（A2 · \(a2Model)，每段调一次）和" : ""
            return "用现在的写手重写「\(window)」\(a2)窗口总结（A3 · \(a3Model)）。\(tail)"
        case .a3:
            return "用现在的写手和模型（\(a3Model)）把「\(window)」的窗口总结按现在的上下文摘要重写一遍。\(tail)"
        case .segment:
            return "用现在的写手和模型（\(a2Model)）只重写这一段「\(ask.segmentTitle.isEmpty ? "没有标题" : ask.segmentTitle)」。它记的那几条消息不变，别的段不动。\(tail)"
        }
    }
}

/// 确认框的宿主：她点 Rewrite 才跑
struct SummaryRewriteConfirm: ViewModifier {
    @Binding var ask: SummaryRewriteAsk?
    let profileId: String
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?

    private var profile: Profile? { profileManager?.profiles.first { $0.id == profileId } }

    func body(content: Content) -> some View {
        content.alert("Rewrite", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }), presenting: ask) { ask in
            Button("Cancel", role: .cancel) { }
            Button("Rewrite") {
                guard let profile, let providerManager else { return }
                SummaryRewriteStatus.shared.start(ask.target, conversationId: ask.conversationId, profile: profile,
                                                  providers: providerManager, container: modelContext.container)
            }
            .disabled(profile == nil || providerManager == nil)
        } message: { ask in
            Text(SummaryRewriteAsk.text(ask, a2Model: modelName(.a2), a3Model: modelName(.a3)))
        }
    }

    private func modelName(_ id: MemoryWriterID) -> String {
        providerManager.map { MemoryWriterModels.actual(id, providers: $0).name } ?? "现在选的模型"
    }
}

/// 列表最上面那一行：正在重写（能 Stop）、跑完那句结果才出现，平时没有
struct SummaryRewriteStatusSection: View {
    let conversationId: String
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        let status = SummaryRewriteStatus.shared
        if let running = status.running[conversationId] {
            row("Rewrite · \(running.text)") {
                Button("Stop") { status.stop(conversationId) }
                    .foregroundColor(Theme.danger)
                    .opacity(running.stopping ? 0 : 1)
                    .disabled(running.stopping)
            }
        } else if let result = status.results[conversationId] {
            row(result) {
                Button { status.dismissResult(conversationId) } label: { Image(systemName: "xmark") }
                    .foregroundColor(Theme.textMuted)
                    .accessibilityLabel("收起")
            }
        }
    }

    private func row<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
                    .buttonStyle(.borderless)
            }
            .font(m.caption)
        }
        .panelRowBackground()
    }
}

/// 一段下面那一小行：Rewrite（和可选的 Undo / History）。正在重写这个窗口时都点不了
struct SummaryRewriteActions: View {
    let conversationId: String
    let profileId: String
    let rewriteLabel: String
    let onRewrite: () -> Void
    /// 给了 = 这一行还管这份文件的 Undo / History（A2 整份或 A3）
    var writer: SessionCloseout.Writer? = nil

    @Environment(\.settingsMetrics) private var m
    @State private var canUndo = false
    @State private var history: HistoryItem? = nil

    private struct HistoryItem: Identifiable {
        let id = UUID()
        let current: String
    }

    var body: some View {
        let status = SummaryRewriteStatus.shared
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            if let writer {
                if canUndo {
                    Button("Undo") { status.undo(writer, conversationId: conversationId, profileId: profileId) }
                        .foregroundColor(Theme.textSecondary)
                }
                Button("History") { openHistory(writer) }
                    .foregroundColor(Theme.textSecondary)
            }
            Button(rewriteLabel, action: onRewrite)
                .foregroundColor(Theme.branchIndicator)
        }
        .font(m.caption)
        .buttonStyle(.borderless)
        .disabled(status.running[conversationId] != nil)
        .task(id: status.revision) {
            guard let writer else { return }
            canUndo = await SummaryRewrite.canUndo(writer, conversationId: conversationId, profileId: profileId)
        }
        .sheet(item: $history) { item in
            if let writer {
                FileVersionHistoryView(key: SummaryRewrite.versionKey(writer, conversationId: conversationId, profileId: profileId),
                                       currentContent: item.current) { restored in
                    status.undo(writer, versionText: restored.text, conversationId: conversationId, profileId: profileId)
                }
            }
        }
    }

    private func openHistory(_ writer: SessionCloseout.Writer) {
        let cid = conversationId, pid = profileId
        Task {
            let current = await Task.detached(priority: .userInitiated) { () -> String in
                let root = FileLibraryStore.memoryRoot(profileId: pid)
                let s = writer == .window ? WindowSummaryStore.load(conversationId: cid, memoryRoot: root)
                                          : SessionSummaryStore.load(conversationId: cid, memoryRoot: root)
                return s.map(SessionSummaryStore.render) ?? ""
            }.value
            history = HistoryItem(current: current)
        }
    }
}
