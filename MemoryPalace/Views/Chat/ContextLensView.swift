import SwiftUI
import SwiftData

/// 窗口透视：聊天页输入框左下角点开。上一轮实发的用量、这一轮会带什么（按来源分类）、原始请求。
struct ContextLensView: View {
    var viewModel: ConversationViewModel
    var modelContext: ModelContext
    var profileManager: ProfileManager?
    var providerManager: ProviderManager
    var presetManager: PresetManager?

    @AppStorage("selectedChatModel") private var selectedModelId = ""
    @State private var loaded = false
    @State private var rows: [ContextLensRow] = []
    @State private var absentText: String?
    @State private var isCodingSession = false
    @State private var previewJSON = ""
    @State private var requestSource = "sent"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("窗口透视")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                lastTurn
                nextTurn
                rawRequest
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.mainBg)
        .task(id: viewModel.selectedConversation?.id) { load() }
    }

    // MARK: 上一轮实发

    @ViewBuilder
    private var lastTurn: some View {
        section("上一轮实发", note: "模型返回的真数字") {
            if let usage = viewModel.lastTurnUsage {
                let cache = usage.cacheReadTokens.map { " · 缓存命中 \($0)" } ?? ""
                Text("输入 \(usage.inputTokens) · 输出 \(usage.outputTokens)\(cache)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(Theme.textPrimary)
            } else {
                muted("这个对话打开以后还没发过消息。")
            }
        }
    }

    // MARK: 这一轮会带什么

    @ViewBuilder
    private var nextTurn: some View {
        let total = rows.reduce(0) { $0 + $1.tokens }
        section("这一轮会带什么", note: loaded && !rows.isEmpty ? "现在点发送会发的 · 本地估算 ≈ \(total)" : nil) {
            if !loaded {
                muted("正在算…")
            } else if isCodingSession {
                muted("这个对话走编程会话，上下文由那边拼，这里看不到。")
            } else if rows.isEmpty {
                muted("还没有选中对话。")
            } else {
                ForEach(rows) { row in
                    ContextLensRowView(row: row, total: max(total, 1))
                }
                if let absentText {
                    muted("工具：没发——\(absentText)")
                }
            }
        }
    }

    // MARK: 原始请求

    @ViewBuilder
    private var rawRequest: some View {
        section("原始请求", note: nil) {
            Picker("", selection: $requestSource) {
                Text("上一次真实发出").tag("sent")
                Text("下一轮预览").tag("preview")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if requestSource == "sent" {
                SentRequestBodyView(conversationId: viewModel.selectedConversation?.id)
            } else if previewJSON.isEmpty {
                muted(isCodingSession ? "编程会话不走标准请求体，没有预览。" : "没有可预览的请求。")
            } else {
                HStack {
                    Spacer()
                    Button("复制") { copy(previewJSON) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.branchIndicator)
                }
                LongTextBox(text: previewJSON)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.assistantBubble.opacity(0.5)))
            }
        }
    }

    // MARK: 取数（只在打开时算一次，不放进 body）

    private func load() {
        defer { loaded = true }
        rows = []
        absentText = nil
        previewJSON = ""
        isCodingSession = false
        guard let pm = profileManager, let psm = presetManager else { return }
        let profile = pm.currentProfile
        let preset = psm.preset(byId: profile.presetId) ?? Preset.balanced
        guard let turn = viewModel.previewTurn(profile: profile, preset: preset, providerManager: providerManager,
                                               globalModelId: selectedModelId, context: modelContext) else { return }
        if turn.toolsAbsentReason == .ccBridge {
            isCodingSession = true
            return
        }
        rows = ContextLens.rows(segments: turn.segments, tools: turn.tools, tuckedTools: turn.tuckedTools)
        if (turn.tools ?? []).isEmpty { absentText = PersonaSettingsTab.toolsAbsentText(turn.toolsAbsentReason) }
        if let body = turn.requestBodyAndPlacementNote(providerManager: providerManager).body,
           let data = try? JSONSerialization.data(withJSONObject: PersonaSettingsTab.redactingImageData(body), options: [.prettyPrinted, .sortedKeys]) {
            previewJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        ToastCenter.shared.show("已复制")
    }

    private func section<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
            }
            content()
        }
    }

    private func muted(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContextLensRowView: View {
    let row: ContextLensRow
    let total: Int
    @State private var expanded = false
    @State private var openItem: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if !row.items.isEmpty { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .opacity(row.items.isEmpty ? 0 : 1)
                        Text(row.title)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textPrimary)
                        Text(row.countText)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                        Spacer()
                        Text("≈ \(row.tokens)")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(Theme.textSecondary)
                        Text("\(row.tokens * 100 / total)%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(Theme.textMuted)
                            .frame(width: 34, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        Capsule().fill(Theme.textMuted.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.branchIndicator)
                                    .frame(width: geo.size.width * CGFloat(row.tokens) / CGFloat(total))
                            }
                    }
                    .frame(height: 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(row.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            openItem = openItem == item.id ? nil : item.id
                        } label: {
                            HStack {
                                Text(item.title)
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("≈ \(item.tokens)")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundColor(Theme.textMuted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if openItem == item.id {
                            LongTextBox(text: item.text, maxHeight: 280)
                                .padding(.horizontal, 8)
                                .padding(.top, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.assistantBubble.opacity(0.5)))
                        }
                    }
                    .padding(.leading, 15)
                }
            }
        }
    }
}
