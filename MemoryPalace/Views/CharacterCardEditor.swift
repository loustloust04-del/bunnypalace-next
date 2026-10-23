import SwiftUI

// MARK: - Character Card Editor

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

                Section("基本设定") {
                    editorField("模板描述", text: $description)
                    editorField("背景设定", text: $scenario)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("对话") {
                    editorField("第一条消息", text: $firstMes)
                    editorField("对话示例", text: $mesExample)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("Prompt") {
                    editorField("系统指令", text: $systemPrompt)
                    editorField("后置提醒", text: $postHistoryInstructions)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section("备注") {
                    editorField("创作者注释", text: $creatorNotes)
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
            .navigationTitle("编辑自定义助手模板")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                        .foregroundColor(Theme.textMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .foregroundColor(Theme.branchIndicator)
                }
            }
        }
        .modifier(CharacterCardJSONExporter(card: $exportingCard))
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好的") { saveError = nil }
        } message: { Text(saveError ?? "") }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
    }

    @ViewBuilder
    private func editorField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: Theme.F.secondary))
                .foregroundColor(Theme.textMuted)
            TextEditor(text: text)
                .font(.system(size: Theme.F.body))
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
        }
    }

    private func save() {
        do { try onSave(editedCard) }
        catch { saveError = error.localizedDescription }
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
