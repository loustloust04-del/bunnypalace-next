import SwiftUI

struct ChatToolGroupView: View {
    let node: MessageNode
    let steps: [ChatToolStep]
    let isStreaming: Bool

    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @AppStorage(DisclosureKind.tool.key) private var modeRaw = DisclosureKind.tool.migratedDefault.rawValue
    @State private var expanded = false
    @State private var showSheet = false
    @State private var selectedStep: ChatToolStep?

    private var mode: DisclosureMode { DisclosureMode(rawValue: modeRaw) ?? .inline }
    private var fingerprint: String { ChatToolTimeline.fingerprint(steps) }
    private var summary: String {
        let text = ChatSystemMessage.noticeText(node.toolSummaries[fingerprint] ?? ChatToolTimeline.fallback(steps))
        return text.isEmpty ? ChatToolTimeline.fallback(steps) : text
    }

    var body: some View {
        if mode != .hidden {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    if mode == .sheet { showSheet = true } else { expanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(summary)
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: expanded && mode == .inline ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summary)
                .accessibilityValue(expanded && mode == .inline ? "已展开" : "已收起")
                if expanded, mode == .inline { stepList }
            }
            .task(id: fingerprint + String(isStreaming)) {
                if !isStreaming {
                    ToolActivitySummarizer.request(node: node, steps: steps, providerManager: providerManager)
                }
            }
            .sheet(isPresented: $showSheet) {
                DisclosureSheet(title: "工具调用") { stepList }
            }
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                Button { selectedStep = step } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 4) {
                            Image(systemName: step.symbol)
                                .font(.system(size: 16))
                                .frame(width: 28, height: 28)
                            if index < steps.count - 1 {
                                Rectangle().fill(Theme.textMuted.opacity(0.18)).frame(width: 1, height: 18)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.action)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textPrimary)
                            Text(step.name + " · " + step.status)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(step.isError ? Theme.danger : Theme.textMuted)
                        }
                        .padding(.top, 4)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .padding(.top, 9)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看参数和完整结果")
            }
        }
        .sheet(item: $selectedStep) { step in
            let current = steps.first { $0.id == step.id } ?? step
            DisclosureSheet(title: current.action) {
                ToolCallCardView(name: current.name, inputJSON: current.inputJSON, resultText: current.result,
                                 isError: current.isError, integration: current.integration, icon: current.icon,
                                 profileId: node.profileId, forceDetail: true)
            }
        }
    }
}
