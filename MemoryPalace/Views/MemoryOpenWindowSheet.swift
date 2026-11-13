import SwiftUI
import SwiftData

/// 读侧段④ 纸条：新建或从对话菜单编辑这个窗口带哪几样可选记忆。
/// 每行写清是什么、约多少 token、占勾上的几项合计的百分之几（窗口透视）；人设、本窗口摘要不在这里
struct MemoryOpenWindowSheet: View {
    let request: ConversationViewModel.OpenWindowNoteRequest
    let viewModel: ConversationViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var choices = MemoryWindowChoices.allOff
    @State private var rows: [MemoryNotePreviewRow] = []
    @State private var loaded = false
    /// 行重算的代号：上个窗口冻结落定时再算一遍，旧结果不覆盖新结果
    @State private var rowGeneration = 0

    private var profile: Profile? {
        profileManager.flatMap { pm in pm.currentProfile.id == request.profileId ? pm.currentProfile : nil }
    }
    private var names: EffectiveCharacterContext? { profile.map { EffectiveCharacterContext(profile: $0) } }
    private var assistant: String { names?.charName ?? "助手" }

    var body: some View {
        let share = MemoryNotePreview.share(rows, choices: choices)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("这个窗口带什么")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text("勾上的每一轮都带进去，只管这一个窗口。人设、本窗口摘要和纪念日不在这里，全划掉也照常带。")
                            .font(.footnote)
                            .foregroundColor(Theme.textMuted)
                        if !MemoryFlags.masterEnabled {
                            Text("记忆总开关关着，这里勾了也不带。")
                                .font(.footnote)
                                .foregroundColor(Theme.textSecondary)
                        }
                        if !request.conversation.memoryEnabled {
                            Text("这个窗口关了记忆参与，勾了也不带。")
                                .font(.footnote)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            rowView(row, percent: share.percent[row.item])
                            if row.id != rows.last?.id { Divider().overlay(Theme.textMuted.opacity(0.2)) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.textMuted.opacity(0.06)))
                    HStack {
                        Text("合计约 \(share.total) token")
                            .font(.footnote.weight(.medium))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Button(choices == .allOff ? "按默认勾回来" : "全划掉") {
                            choices = choices == .allOff ? MemoryWindowChoices.defaults(profileId: request.profileId) : .allOff
                        }
                        .font(.footnote)
                        .foregroundColor(Theme.branchIndicator)
                        .buttonStyle(.plain)
                    }
                    Text("档案、钉住的、\(assistant)的记忆共用注入预算 \(MemoryInjector.tokenBudget) token；上一个窗口单独按这个上限带最后几条，放不下的最早几条不带。发送时还会按总上下文裁剪；档案里聊到哪页带哪页，不算在这里。")
                        .font(.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .padding(20)
            }
            HStack(spacing: 12) {
                Button(request.mode == .editChoices ? "取消" : "不开了") { viewModel.cancelOpenWindowNote(context: modelContext) }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                Button("就这样") { viewModel.confirmOpenWindowNote(choices, initialChoices: request.initialChoices) }
                    .buttonStyle(.plain)
                    .font(.body.weight(.semibold))
                    .foregroundColor(Theme.mainBg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Theme.branchIndicator))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(Theme.mainBg)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 520)
        #endif
        .onAppear(perform: load)
        // E2-7b：上个窗口还在后台抓（纸条先弹出来）→ 冻结落定后行重算一次
        .onChange(of: viewModel.isFreezing(request.conversationId)) { _, freezing in
            if !freezing, loaded { loadRows() }
        }
    }

    private func rowView(_ row: MemoryNotePreviewRow, percent: Int?) -> some View {
        let on = choices[row.item]
        return Button { choices[row.item].toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(on ? Theme.branchIndicator : Theme.textMuted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.item.title(assistant: assistant))
                        .font(.body)
                        .foregroundColor(on ? Theme.textPrimary : Theme.textMuted)
                    Text(row.summary)
                        .font(.footnote)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.available ? "约 \(row.tokens) token" : "—")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(on ? Theme.textSecondary : Theme.textMuted)
                    if on, let percent, row.available {
                        Text("占 \(percent)%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(Theme.textMuted)
                    } else if !on {
                        Text("不带")
                            .font(.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        choices = request.initialChoices
        loadRows()
    }

    private func loadRows() {
        guard let profile else { return }
        let snapshot = request.conversation.previousWindowSnapshot
        let pending = viewModel.isFreezing(request.conversationId)
        let container = modelContext.container
        let conversationId = request.conversationId
        let profileId = request.profileId
        let store = viewModel.memoryStore
        rowGeneration += 1
        let generation = rowGeneration
        Task {
            let next = await Task.detached(priority: .userInitiated) {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                return MemoryNotePreview.rows(profile: profile, conversationId: conversationId,
                                              snapshot: snapshot.map { PreviousWindowPicker.validate($0, profileId: profileId, context: context) },
                                              store: store, context: context,
                                              wiki: WikiInjectionCache.shared.snapshot(profileId: profileId, store: nil),
                                              previousPending: pending)
            }.value
            if rowGeneration == generation { rows = next }
        }
    }
}

/// 两端共用纸条宿主；下滑关闭时，新建保留冻结默认，编辑不改原选择
struct OpenWindowNoteHost: ViewModifier {
    let viewModel: ConversationViewModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { viewModel.openWindowNote },
                                    set: { if $0 == nil { viewModel.dismissOpenWindowNote() } })) { request in
            MemoryOpenWindowSheet(request: request, viewModel: viewModel)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationBackground(Theme.mainBg)
                #endif
        }
    }
}
