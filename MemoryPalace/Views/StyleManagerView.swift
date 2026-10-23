import SwiftUI

/// 写作风格统一管理界面（仿 Prompt 插槽模式）：
/// 一行一个 style：Toggle(互斥,同时只能开一个) + 名字 + 内置/自建 badge。
/// tap 整行 → push 进编辑器。Toggle 全关 = 无风格。
/// 从 iOS StickerKeyboardPanel 的 sparkles 直接弹出,没有"选择 vs 管理"两层。
struct StyleManagerView: View {
    var viewModel: ConversationViewModel
    @Bindable var manager: StyleManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var editing: WritingStyle? = nil

    private var currentStyleId: String {
        viewModel.selectedConversation?.currentStyleId ?? ""
    }

    private var builtins: [WritingStyle] { manager.styles.filter(\.isBuiltin) }
    private var customs: [WritingStyle] { manager.styles.filter { !$0.isBuiltin } }

    var body: some View {
        NavigationStack {
            List {
                Section("内置") {
                    ForEach(builtins) { styleRow($0) }
                }
                Section("自建") {
                    ForEach(customs) { style in
                        styleRow(style)
                            .swipeActions { deleteStyleButton(style) }
                            // S1-3：mac 上横扫只有触控板能做、鼠标够不着，右键补同一条
                            #if os(macOS)
                            .contextMenu { deleteStyleButton(style) }
                            #endif
                    }
                    Button {
                        let new = WritingStyle(name: "新风格", content: "", isBuiltin: false)
                        manager.save(new)
                        editing = new
                    } label: {
                        Label("新建风格", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("写作风格")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { style in
                StyleEditorView(initial: style, manager: manager)
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
        #endif
    }

    /// 删除风格。横扫和右键共用同一份（S1-3）
    @ViewBuilder
    private func deleteStyleButton(_ style: WritingStyle) -> some View {
        Button(role: .destructive) {
            // 删的是当前选中的 → 同时清掉对话的 currentStyleId
            if style.id == currentStyleId {
                viewModel.selectedConversation?.currentStyleId = ""
                try? modelContext.save()
            }
            manager.delete(style)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func styleRow(_ style: WritingStyle) -> some View {
        let isOn = style.id == currentStyleId
        HStack(spacing: 12) {
            // 互斥 Toggle：开一个就成为当前选中，关掉则 currentStyleId = ""(无风格)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { val in
                    guard let conv = viewModel.selectedConversation else { return }
                    conv.currentStyleId = val ? style.id : ""
                    try? modelContext.save()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.branchIndicator)
            #if os(iOS)
            .scaleEffect(0.75)
            .frame(width: 50)
            #endif
            // Toggle 自己拦自己的点击,整行 tap 不会切 toggle
            .highPriorityGesture(TapGesture())

            VStack(alignment: .leading, spacing: 2) {
                Text(style.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Theme.textPrimary : Theme.textPrimary)
                if !style.content.isEmpty {
                    Text(style.content)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            if style.isBuiltin {
                Text("内置")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().stroke(Theme.textMuted, lineWidth: 0.5))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textMuted.opacity(0.5))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editing = style
        }
    }
}

/// 编辑器：name + content。内置只读，可"复制为自建再编辑"。
struct StyleEditorView: View {
    @State private var style: WritingStyle
    var manager: StyleManager
    @Environment(\.dismiss) private var dismiss

    init(initial: WritingStyle, manager: StyleManager) {
        _style = State(initialValue: initial)
        self.manager = manager
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("风格名", text: $style.name)
                        .disabled(style.isBuiltin)
                }
                Section("风格描述（贴在你每条消息末尾的 <style> 标签里）") {
                    TextEditor(text: $style.content)
                        .frame(minHeight: 180)
                        .disabled(style.isBuiltin)
                }
                if style.isBuiltin {
                    Section {
                        Button {
                            let copy = manager.duplicate(style)
                            style = copy
                        } label: {
                            Label("复制为自建风格再编辑", systemImage: "doc.on.doc")
                        }
                    } footer: {
                        Text("内置风格不可改，复制一份就可以随便编辑了。")
                    }
                }
            }
            .navigationTitle(style.isBuiltin ? "查看风格" : "编辑风格")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        manager.save(style)
                        dismiss()
                    }
                    .disabled(style.isBuiltin || style.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 560)
        #endif
    }
}

/// 气泡上的风格小标记：「· 风格名」。从 user node 的 styleIdSnapshot 取（快照保真，
/// 不随当前 style 切换变）。受 @AppStorage("showStyleChip") 总开关控制。
struct StyleChip: View {
    let styleId: String?

    @AppStorage("showStyleChip") private var showStyleChip = true
    @Bindable private var styleManager = StyleManager.shared

    var body: some View {
        if showStyleChip,
           let id = styleId, !id.isEmpty,
           let style = styleManager.find(id) {
            HStack(spacing: 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 8))
                Text(style.name)
                    .font(.caption2.weight(.medium))
            }
            .foregroundColor(Theme.textMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.accent.opacity(0.45)))
        }
    }
}
