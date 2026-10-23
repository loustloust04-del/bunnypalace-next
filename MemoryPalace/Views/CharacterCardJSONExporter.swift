import SwiftUI
import UniformTypeIdentifiers

/// 沿用系统文件导出，宿主持有状态，长按菜单关闭后仍能展示保存面板。
struct CharacterCardJSONExporter: ViewModifier {
    @Binding var card: CharacterCard?
    @State private var document: CardJSONDocument?
    @State private var isPresented = false
    @State private var exportError: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: card) { _, selected in
                guard let selected else { return }
                do {
                    document = CardJSONDocument(data: try selected.exportJSON())
                    isPresented = true
                } catch {
                    exportError = error.localizedDescription
                    card = nil
                }
            }
            .fileExporter(isPresented: $isPresented, document: document, contentType: .json,
                          defaultFilename: card?.name ?? "角色卡") { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
                card = nil
                document = nil
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { card = nil }
            }
            .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("好的") { exportError = nil }
            } message: { Text(exportError ?? "") }
    }
}

private struct CardJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw TavernCardError.invalidJSON }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
