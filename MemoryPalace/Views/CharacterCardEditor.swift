import SwiftUI

// MARK: - Character Card Editor

/// onSave 只管落盘（表单「保存」和长字段全屏编辑器的「保存」都走它）；关表单由编辑器在表单保存成功后调 onCancel
struct CharacterCardEditor: View {
    let card: CharacterCard
    let onSave: (CharacterCard) throws -> Void
    let onCancel: () -> Void

    @State private var exportingCard: CharacterCard?
    @State private var saveError: String?
    @State private var name: String
    @State private var description: String
    @State private var personality: String
    @State private var scenario: String
    @State private var firstMes: String
    @State private var mesExample: String
    @State private var systemPrompt: String
    @State private var postHistoryInstructions: String
    @State private var creatorNotes: String
    @State private var confirmingDiscard = false
    /// 最近一次落盘的卡：全屏编辑器存过之后，表单「有没有改动」跟它比
    @State private var savedCard: CharacterCard

    init(card: CharacterCard, onSave: @escaping (CharacterCard) throws -> Void, onCancel: @escaping () -> Void) {
        self.card = card
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: card.name)
        _description = State(initialValue: card.description)
        _personality = State(initialValue: card.personality)
        _scenario = State(initialValue: card.scenario)
        _firstMes = State(initialValue: card.firstMes)
        _mesExample = State(initialValue: card.mesExample)
        _systemPrompt = State(initialValue: card.systemPrompt)
        _postHistoryInstructions = State(initialValue: card.postHistoryInstructions)
        _creatorNotes = State(initialValue: card.creatorNotes)
        _savedCard = State(initialValue: card)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("基本信息") {
                    HStack {
                        Text("名称")
                            .font(.system(size: Theme.F.body))
                            .foregroundColor(Theme.textSecondary)
                        TextField("名称", text: $name)
                            .font(.system(size: Theme.F.body))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .listRowBackground(Theme.mainBg)

                Section("角色设定") {
                    longField("描述", field: "description", text: $description)
                    longField("性格", field: "personality", text: $personality)
                    longField("场景", field: "scenario", text: $scenario)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("对话") {
                    longField("开场白", field: "firstMes", text: $firstMes)
                    longField("示例对话", field: "mesExample", text: $mesExample)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("Prompt") {
                    longField("系统提示词", field: "systemPrompt", text: $systemPrompt)
                    longField("历史后指令", field: "postHistoryInstructions", text: $postHistoryInstructions)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("备注") {
                    longField("创作者注释", field: "creatorNotes", text: $creatorNotes)
                    Button("导出 JSON", systemImage: "square.and.arrow.up") { exportingCard = editedCard }
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.plain)
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.sidebarBg)
            .navigationTitle("编辑角色卡")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if isDirty { confirmingDiscard = true } else { onCancel() } }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .modifier(CharacterCardJSONExporter(card: $exportingCard))
        .discardChangesGuard(isDirty: isDirty, confirming: $confirmingDiscard, onDiscard: onCancel)
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好的") { saveError = nil }
        } message: { Text(saveError ?? "") }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
    }

    /// 全屏编辑器点保存 = 整张卡落盘（粟粟 10-15：原来要再回表单点一次保存）
    private func longField(_ label: String, field: String, text: Binding<String>) -> some View {
        LongTextField(title: label, text: text, editorTitle: "角色卡 · \(label)",
                      versionKey: .cardField(cardId: card.id, field: field),
                      onCommit: { _ in try persist() })
    }

    private var isDirty: Bool { editedCard != savedCard }

    private func save() {
        do {
            try persist()
            onCancel()
        } catch { saveError = error.localizedDescription }
    }

    private func persist() throws {
        let updated = editedCard
        try onSave(updated)
        savedCard = updated
        SaveFeedback.saved("已保存")
    }

    private var editedCard: CharacterCard {
        var updated = card
        updated.name = name
        updated.description = description
        updated.personality = personality
        updated.scenario = scenario
        updated.firstMes = firstMes
        updated.mesExample = mesExample
        updated.systemPrompt = systemPrompt
        updated.postHistoryInstructions = postHistoryInstructions
        updated.creatorNotes = creatorNotes
        return updated
    }
}
