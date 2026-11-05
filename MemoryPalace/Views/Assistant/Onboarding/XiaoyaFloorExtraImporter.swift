import SwiftUI
import UniformTypeIdentifiers

// MARK: - 新楼层出口卡 · 追加导入（plan-onboarding-xiaoya-impl §4.3 tavern 行，H7）
// 世界书 / 预设固定落到出口卡那位 Ta 的楼层（按卡上的楼层 id，不读 currentProfile）。
// 预设导入前先问一句：Ta 楼层带着卡自带的系统指令，换预设会把它换掉。结果由剧本报一句。

struct XiaoyaFloorExtraRequest: Identifiable, Equatable {
    let extra: XiaoyaFloorExtra
    let taProfileId: String
    let taName: String
    var id: String { "\(extra.rawValue)-\(taProfileId)" }
}

struct XiaoyaFloorExtraImporter: ViewModifier {
    @Binding var request: XiaoyaFloorExtraRequest?
    let env: AssistantEnv?
    let script: XiaoyaScriptRunner

    @State private var picking = false
    @State private var confirmPreset = false

    private var factory: OnboardingFloorFactory? {
        env.map { OnboardingFloorFactory(profiles: $0.profileManager, presets: $0.presetManager, cards: $0.cardManager, defaults: $0.defaults) }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, new in
                guard let new else { return }
                if new.extra == .preset, factory?.presetReplacesCardPrompt(profileId: new.taProfileId) == true {
                    confirmPreset = true
                } else {
                    picking = true
                }
            }
            .confirmationDialog("换预设", isPresented: $confirmPreset, titleVisibility: .visible) {
                Button("导入预设") { picking = true }
                Button("算了", role: .cancel) { request = nil }
            } message: {
                Text("导入的预设会替换\(request?.taName ?? "Ta")这张卡自带的系统指令。只改\(request?.taName ?? "Ta")的楼层。")
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                defer { request = nil }
                guard let request, case .success(let urls) = result, let url = urls.first else { return }
                handle(url, request)
            }
    }

    private func handle(_ url: URL, _ request: XiaoyaFloorExtraRequest) {
        guard let factory else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            switch request.extra {
            case .worldBook:
                let name = try factory.importWorldBook(data, fallbackName: url.deletingPathExtension().lastPathComponent,
                                                       into: request.taProfileId)
                script.note(XiaoyaScriptLines.worldBookImported(name, ta: request.taName))
            case .preset:
                let imported = try factory.importPreset(data, into: request.taProfileId)
                // ④a：prompt_order 没按 100001 组导入时的提示跟在后面
                let notes = imported.notes.isEmpty ? "" : "\n" + imported.notes.joined(separator: "\n")
                script.note(XiaoyaScriptLines.presetImported(imported.name, ta: request.taName) + notes)
            case .chatHistory:
                break
            }
        } catch {
            script.note(XiaoyaScriptLines.importFailed(error.localizedDescription))
        }
    }
}
