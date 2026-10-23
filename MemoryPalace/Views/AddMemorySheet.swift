import SwiftUI
import SwiftData

// MARK: - Add / Edit Memory Sheet（page2 添加记忆，学 SlotEditPage 样板；刀2 起兼编辑）

struct AddMemorySheet: View {
    let profileId: String
    var editing: Memory? = nil   // 刀2（plan-memory-usable）：非 nil = 编辑既有条目
    /// 编辑时「出处」节的「去原对话」；nil = 只显示原话
    var onJumpToSource: (() -> Void)? = nil
    let onAdded: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var content: String
    @State private var category: String

    init(profileId: String, editing: Memory? = nil, onJumpToSource: (() -> Void)? = nil, onAdded: @escaping () -> Void) {
        self.profileId = profileId
        self.editing = editing
        self.onJumpToSource = onJumpToSource
        self.onAdded = onAdded
        _content = State(initialValue: editing?.content ?? "")
        _category = State(initialValue: editing?.category ?? "fact")
    }

    private static let categories: [(key: String, label: String)] = [
        ("fact", "事实"), ("preference", "偏好"), ("relationship", "关系"),
        ("goal", "目标"), ("context", "近况")
    ]

    private var trimmed: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section("内容") {
                    TextEditor(text: $content)
                        .font(.system(size: Theme.F.body))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("比如：我不喜欢蓝色和黄色")
                                    .font(.system(size: Theme.F.body))
                                    .foregroundColor(Theme.textMuted)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .listRowBackground(Theme.mainBg)

                Section {
                    Picker("分类", selection: $category) {
                        ForEach(Self.categories, id: \.key) { c in
                            Text(c.label).tag(c.key)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.branchIndicator)
                } header: {
                    Text("分类")
                } footer: {
                    Text("加的、改过的记忆会被钉住，整理时不会动它")
                }
                .listRowBackground(Theme.mainBg)

                if let m = editing, m.sourceQuote?.isEmpty == false || onJumpToSource != nil {
                    Section("出处") {
                        if let quote = m.sourceQuote, !quote.isEmpty {
                            Text("「\(quote)」")
                                .font(.system(size: Theme.F.body))
                                .foregroundColor(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                        if let onJumpToSource {
                            Button {
                                dismiss()
                                onJumpToSource()
                            } label: {
                                HStack {
                                    Text("去原对话")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: Theme.F.caption))
                                }
                                .foregroundColor(Theme.branchIndicator)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Theme.mainBg)
                }
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle(editing == nil ? "加一条记忆" : "编辑记忆")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }
                        .foregroundColor(trimmed.isEmpty ? Theme.textMuted : Theme.branchIndicator)
                        .disabled(trimmed.isEmpty)
                }
            }
            #if os(macOS)
            .frame(width: 480, height: editing?.sourceConversationId == nil ? 380 : 500)
            #endif
        }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        if let m = editing {
            // ⧫① 已批：人工编辑过的条目自动钉住——你亲手改的话，园丁（做梦/合并）不该再动它
            m.content = trimmed
            m.category = category
            m.isUserExplicit = true
            m.decayWeight = 1.0
            m.embeddingData = nil   // 内容变了向量失效，MemoryEmbeddingBackfill 下轮自动重算
            m.updatedAt = Date()
            try? modelContext.save()
        } else {
            let store = SwiftDataMemoryStore()
            try? store.add(
                content: trimmed, category: category, keywords: [],
                profileId: profileId, isUserExplicit: true, extractedBy: "manual",
                sourceConversationId: nil, context: modelContext
            )
        }
        onAdded()
        dismiss()
    }
}
