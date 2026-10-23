import SwiftUI
import SwiftData

// MARK: - 整理记忆（#067 第 4 步）：「⋯ › 整理记忆…」和设置页「整理记忆…」开同一个弹层

/// 整理 / 重写画像的共用动作：记忆 app 的整理弹层、画像弹层都走这里。成功后发 `.memoryDidChange`
@MainActor
enum MemoryOrganizer {
    /// 整理 = 重写画像 + 把意思几乎一样的合并（合并掉的进「已删除」）
    static func organize(profileId: String, providerManager: ProviderManager?, context: ModelContext) async -> String {
        guard let pm = providerManager, let model = DreamConsolidator.resolveModel(providerManager: pm) else {
            return "整理没成功：没有可用模型（先在 API 设置选模型）"
        }
        do {
            let report = try await MemoryHygiene.sweep(profileId: profileId, model: model, providerManager: pm, context: context)
            NotificationCenter.default.post(name: .memoryDidChange, object: nil)
            return "整理好了：合并了 \(report.merged) 条，画像已更新"
        } catch {
            return "整理没成功：\(failureText(error))"
        }
    }

    /// 只重写画像，不合并、不删任何记忆
    static func rewriteProfile(profileId: String, providerManager: ProviderManager?,
                               context: ModelContext) async -> (dream: UserProfileDream?, message: String) {
        guard let pm = providerManager, let model = DreamConsolidator.resolveModel(providerManager: pm) else {
            return (nil, "没有可用模型（先在 API 设置选模型）")
        }
        let mems = SwiftDataMemoryStore().listHotAndWarm(profileId: profileId, context: context)
        guard !mems.isEmpty else { return (nil, "还没有记忆，先聊几轮") }
        let facts = mems.map { (content: $0.content, category: $0.category) }
        guard let result = try? await DreamConsolidator.dream(profileId: profileId, facts: facts, model: model, providerManager: pm) else {
            return (nil, "重写画像没成功，稍后再试")
        }
        NotificationCenter.default.post(name: .memoryDidChange, object: nil)
        return (result, "画像已重写")
    }

    static func failureText(_ error: Error) -> String {
        switch error as? MemoryHygiene.Failure {
        case .noEmbedder: return "要先打开「按意思找记忆」，等本地模型下载好"
        case .tooManyMemories(let n): return "记忆太多了（\(n) 条），一次整理不过来"
        case .dreamFailed: return "模型没回话，稍后再试"
        case .noMemories: return "还没有可以整理的记忆"
        case nil: return "稍后再试"
        }
    }
}

struct MemoryOrganizeSheet: View {
    let profileId: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage("mem_content_profile") private var memContentProfile = false

    /// 画像开关关着才给「同时打开」；打开那一刻定下来，开关翻了也不跳掉这一行
    @State private var offersProfileSwitch = !UserDefaults.standard.bool(forKey: "mem_content_profile")
    @State private var alsoEnableProfile = false
    @State private var running = false
    @State private var result: String? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("重写一遍画像，再把意思几乎一样的记忆合并。合并掉的会放进「已删除」，能恢复。")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                }
                .panelRowBackground()

                if offersProfileSwitch && result == nil {
                    Section {
                        Toggle(isOn: $alsoEnableProfile) {
                            Text("同时打开自动写画像")
                                .font(m.body)
                                .foregroundColor(Theme.textPrimary)
                        }
                        .disabled(running)
                    } footer: {
                        Text("打开后每天会自己重写一次画像，多一次模型调用")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .panelRowBackground()
                }

                Section {
                    if running {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在整理…")
                                .font(m.body)
                                .foregroundColor(Theme.textMuted)
                        }
                    } else if let result {
                        Text(result)
                            .font(m.body)
                            .foregroundColor(Theme.textPrimary)
                    } else {
                        Button("开始整理") { start() }
                            .buttonStyle(MemoryPrimaryButtonStyle(fullWidth: true))
                            .listRowBackground(Color.clear)
                    }
                }
                .panelRowBackground()
            }
            .panelListStyle()
            .scrollContentBackground(.hidden)
            .toolPageBackground()
            .tint(Theme.branchIndicator)
            .panelSheetTitle("整理记忆")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(result == nil ? "取消" : "完成") { dismiss() }
                        .foregroundColor(Theme.branchIndicator)
                        .disabled(running)
                }
            }
            #if os(macOS)
            .frame(width: 440, height: 340)
            #endif
        }
        .interactiveDismissDisabled(running)
    }

    private func start() {
        if alsoEnableProfile { memContentProfile = true }
        running = true
        Task {
            result = await MemoryOrganizer.organize(profileId: profileId, providerManager: providerManager, context: modelContext)
            running = false
        }
    }
}
