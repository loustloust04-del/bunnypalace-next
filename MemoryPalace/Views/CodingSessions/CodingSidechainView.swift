#if os(macOS)
import SwiftUI

/// 工具调用派出的子代理对话（plan-wake-native-n1 §2.5 / N1-j）：点开才读 `<会话>/subagents/<id>.jsonl`，
/// 左侧细线缩进，与主线同一套消息行
struct CodingSidechainView: View {
    let sidechainId: String
    /// 子代理消息的署名也写这家 agent（跟主线同一条规则）
    var agent: CodingAgent? = nil
    var onPreviewImage: (CodingImage) -> Void = { _ in }

    private enum LoadState {
        case idle
        case loading
        case loaded([CodingMessage])
        case failed(String)
    }

    @State private var isOpen = false
    @State private var state: LoadState = .idle

    private var library: CodingSessionLibrary { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Image(systemName: "person.2")
                        .font(.system(size: 10))
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: Theme.F.caption))
                .foregroundColor(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                content
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Theme.branchIndicator.opacity(0.35))
                            .frame(width: 2)
                    }
            }
        }
    }

    private var title: String {
        let info = library.sidechainInfo(sidechainId)
        return (["子代理对话", info?.agentType, info?.description] as [String?])
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            Text("读不出子代理对话：\(message)")
                .font(.system(size: Theme.F.caption))
                .foregroundColor(.red)
        case .loaded(let messages):
            let visible = messages.filter { !CodingSessionDetailView.isThinkingOnly($0) }
            if visible.isEmpty {
                Text("子代理对话文件不见了或是空的")
                    .font(.system(size: Theme.F.caption))
                    .foregroundColor(Theme.textMuted)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(visible.enumerated()), id: \.element.seq) { index, message in
                        CodingMessageRow(message: message, agent: agent,
                                         showsHeader: CodingSessionDetailView.showsHeader(visible, index),
                                         onPreviewImage: onPreviewImage)
                    }
                }
            }
        }
    }

    private func toggle() {
        isOpen.toggle()
        guard isOpen, case .idle = state else { return }
        state = .loading
        Task {
            switch await library.loadSidechain(id: sidechainId) {
            case .success(let messages): state = .loaded(messages)
            case .failure(let error): state = .failed(error.text)
            }
        }
    }
}
#endif
