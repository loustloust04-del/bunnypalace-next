import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - 设置 · 导入导出（plan-settings-config.md）
//
// 入口：设置首页 → 本地模式底下「设置 · 导入导出」
// 导出：生成 JSON Data → ShareLink/NSSavePanel；同时写一份到文件库（C-D6）
// 导入：fileImporter/NSOpenPanel 选 .json → 二次确认 alert → 应用 → 提示重启
// 「包含 API key（需设口令）」（research-magpie 2.8）：导出前输两次口令 → 整份加密；
// 导入遇到加密文件先弹口令框 → 解开再走同一个二次确认。

/// 一份 body 两端共用（plan-settings-merge 刀 2）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
/// bullet 行的 `HStack` 不展平进卡，导入 / 导出按钮与「覆盖现有所有设置？」确认流程位置不动。
struct ConfigPage: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.settingsMetrics) private var m

    @State private var statusMessage: String? = nil
    @State private var statusIsError: Bool = false

    // 导入确认
    @State private var pendingImportData: Data? = nil
    @State private var pendingUnlocked: ConfigImporter.UnlockedConfig? = nil
    @State private var showImportConfirm = false

    // 导出含 API key：口令两次
    @State private var includeKeys = false
    @State private var exportPass = ""
    @State private var exportPassConfirm = ""
    @State private var isWorking = false

    // 导入加密文件：口令弹窗
    @State private var showPassphrasePrompt = false
    @State private var importPass = ""

    // 文件选择器
    @State private var showFileImporter = false

    // iOS 分享
    #if os(iOS)
    @State private var shareItem: ShareItem? = nil
    #endif

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                Toggle(isOn: $includeKeys) {
                    Text("包含 API key（需设口令）")
                        .font(m.action)
                        .foregroundColor(Theme.textPrimary)
                }
                if includeKeys {
                    SecureField("设置口令（至少 \(ConfigPassphraseStrength.minimumLength) 位）", text: $exportPass)
                        .font(m.body)
                    SecureField("再输一次口令", text: $exportPassConfirm)
                        .font(m.body)
                    passphraseHint
                }
                exportButton
                importButton
            } header: {
                Text("操作")
            } footer: {
                Text("**导出**：把所有设置打成一个 JSON 文件，可以保存到文件、AirDrop、或自动存进文件库的「Settings/」目录。\n**包含 API key**：整份文件用口令加密（AES-256-GCM）；口令忘了就打不开，app 不存口令。OAuth 登录态不打包，换机后重新登录。\n**导入**：从 JSON 文件恢复全部设置（覆盖现有）；加密文件会先要口令。")
                    .font(m.caption)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                bullet("✅ 含", "界面偏好、Prompt 模板、记忆开关、CC/朗读/文件库/右栏/MCP 等所有开关；API 卡 metadata（emoji / 昵称 / 提供商 / 收藏的模型）；主题纯色配置")
                bullet("🔐 可选", "API 卡 key / 联网搜索 key / ElevenLabs key —— 勾「包含 API key」才带，整份口令加密；导入时同一张卡替换，备份没带的保留本机 key")
                bullet("⛔️ 不含", "ChatGPT OAuth token / CC Hub Token / MCP 密钥（导入后需在本机重新登录）")
                bullet("⛔️ 不含", "角色卡库 / 世界书 / 楼层 — 是【内容】不是设置")
                bullet("⛔️ 不含", "每张卡的完整模型列表（点「刷新模型」一键重拉）；主题背景图文件")
                bullet("⛔️ 不含", "对话 / 消息 / 记忆库 / 贴纸（用「数据与备份」单独导出）")
            } header: {
                Text("范围")
            }
            .listRowBackground(Theme.mainBg)

            if let msg = statusMessage {
                Section {
                    Text(msg)
                        .font(m.body)
                        .foregroundColor(statusIsError ? .red : Theme.branchIndicator)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Theme.mainBg)
            }
        }
        // mac 侧不加 listStyle：宿主是 MacSettingsForm（自己排卡），合流前 mac body 也没有这一句
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        #if os(macOS)
        .background(ShellStyle.windowBackground)
        #else
        .background(Theme.sidebarBg)
        #endif
        .navigationTitle("config")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleFileImporterResult(result)
        }
        .alert("覆盖现有所有设置？", isPresented: $showImportConfirm) {
            Button("取消", role: .cancel) {
                pendingImportData = nil
            }
            Button("确认覆盖", role: .destructive) {
                applyPendingImport()
            }
        } message: {
            if pendingUnlocked != nil {
                Text("导入会替换全部设置，并写回文件里的 API key（同一张卡替换，文件没带的保留本机）。不含对话记录。建议先用「导出」把当前状态备份一份再继续。")
            } else {
                Text("导入会替换全部设置（不含 API key / 对话记录）。建议先用「导出」把当前状态备份一份再继续。")
            }
        }
        .alert("输入导出口令", isPresented: $showPassphrasePrompt) {
            SecureField("口令", text: $importPass)
            Button("取消", role: .cancel) {
                pendingImportData = nil
                importPass = ""
            }
            Button("解锁") {
                unlockPendingImport()
            }
        } message: {
            Text("这份设置文件含 API key，已用口令加密。")
        }
        #if os(iOS)
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
        #endif
    }

    // MARK: - 按钮

    @ViewBuilder
    private var exportButton: some View {
        Button {
            performExport()
        } label: {
            HStack {
                Image(systemName: includeKeys ? "lock.doc" : "square.and.arrow.up")
                    .foregroundColor(Theme.branchIndicator)
                Text(includeKeys ? "加密导出（含 API key）" : "导出全部设置")
                    .font(m.action)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.plain)
        .disabled(isWorking || (includeKeys && !exportPassReady))
        .opacity(isWorking || (includeKeys && !exportPassReady) ? 0.5 : 1)
    }

    private var exportPassReady: Bool {
        ConfigPassphraseStrength.evaluate(exportPass).isAcceptable && exportPass == exportPassConfirm
    }

    @ViewBuilder
    private var passphraseHint: some View {
        let strength = ConfigPassphraseStrength.evaluate(exportPass)
        let mismatch = !exportPassConfirm.isEmpty && exportPass != exportPassConfirm
        VStack(alignment: .leading, spacing: 2) {
            if !exportPass.isEmpty {
                Text("强度：\(strength.label)")
                    .foregroundColor(strength == .strong || strength == .fair ? Theme.branchIndicator : .orange)
            }
            if mismatch {
                Text("两次口令不一致").foregroundColor(.red)
            }
            Text("口令忘了文件就打不开，请另外记好。")
                .foregroundColor(Theme.textMuted)
        }
        .font(m.caption)
    }

    @ViewBuilder
    private var importButton: some View {
        Button {
            showFileImporter = true
        } label: {
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(Theme.branchIndicator)
                Text("从文件导入")
                    .font(m.action)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bullet(_ tag: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(tag)
                .font(m.caption.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            Text(text)
                .font(m.secondary)
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 导出

    private func performExport() {
        guard includeKeys else {
            deliverExport(ConfigExporter.exportAll(), filename: ConfigExporter.suggestedFilename())
            return
        }
        guard exportPassReady else { return }
        let pass = exportPass
        isWorking = true
        statusMessage = "🔐 正在加密…"
        statusIsError = false
        // PBKDF2 60 万次 + Keychain 读取挪出主线程
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ConfigExporter.exportWithKeys(passphrase: pass) }
            }.value
            isWorking = false
            switch result {
            case .success(let data):
                exportPass = ""
                exportPassConfirm = ""
                statusMessage = nil
                deliverExport(data, filename: ConfigExporter.suggestedFilename(encrypted: true))
            case .failure(let error):
                statusMessage = "❌ 加密导出失败：\(error.localizedDescription)"
                statusIsError = true
            }
        }
    }

    private func deliverExport(_ data: Data, filename: String) {

        // 1) 写一份到文件库（C-D6）—— Settings/ 目录下
        if let profileId = profileManager?.currentProfile.id {
            let libPath = "Settings/\(filename)"
            do {
                let s = String(data: data, encoding: .utf8) ?? ""
                try FileLibraryStore.write(libPath, content: s, profileId: profileId)
                statusMessage = "✅ 已导出 · 同时存进文件库 Settings/\(filename)"
                statusIsError = false
            } catch {
                statusMessage = "⚠️ 写入文件库失败：\(error.localizedDescription)（仍可走分享导出）"
                statusIsError = false
            }
        }

        // 2) 走系统分享/保存
        #if os(iOS)
        guard let url = writeToTempFile(data, filename: filename) else {
            statusMessage = "❌ 写临时文件失败"
            statusIsError = true
            return
        }
        shareItem = ShareItem(url: url)
        #else
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                statusMessage = (statusMessage ?? "") + "\n📄 已保存到 \(url.path)"
            } catch {
                statusMessage = "❌ 保存失败：\(error.localizedDescription)"
                statusIsError = true
            }
        }
        #endif
    }

    // MARK: - 导入

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pendingImportData = data
                pendingUnlocked = nil
                if ConfigImporter.isEncrypted(data) {
                    importPass = ""
                    showPassphrasePrompt = true
                } else {
                    showImportConfirm = true
                }
            } catch {
                statusMessage = "❌ 读取文件失败：\(error.localizedDescription)"
                statusIsError = true
            }
        case .failure(let error):
            statusMessage = "❌ 选文件失败：\(error.localizedDescription)"
            statusIsError = true
        }
    }

    /// 口令解开加密文件（PBKDF2 挪出主线程）；口令错 → 提示并重新弹口令框
    private func unlockPendingImport() {
        guard let data = pendingImportData else { return }
        let pass = importPass
        importPass = ""
        isWorking = true
        statusMessage = "🔐 正在解密…"
        statusIsError = false
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ConfigImporter.unlock(data, passphrase: pass) }
            }.value
            isWorking = false
            switch result {
            case .success(let unlocked):
                statusMessage = nil
                pendingUnlocked = unlocked
                showImportConfirm = true
            case .failure(let error):
                statusMessage = "❌ \(error.localizedDescription)"
                statusIsError = true
                if (error as? ConfigCrypto.CryptoError) == .wrongPassphrase {
                    showPassphrasePrompt = true   // 再给一次机会；取消即放弃
                } else {
                    pendingImportData = nil
                }
            }
        }
    }

    private func applyPendingImport() {
        guard let data = pendingImportData else { return }
        let unlocked = pendingUnlocked
        defer {
            pendingImportData = nil
            pendingUnlocked = nil
        }
        do {
            let result = try unlocked.map { try ConfigImporter.importAll($0) } ?? ConfigImporter.importAll(data)
            let keysNote = unlocked != nil ? " · 写回 \(result.restoredKeys) 个 API key" : ""
            statusMessage = "✅ 导入成功\(keysNote) · 请关闭设置并完全退出 app 重开，确保所有界面看到新设置。"
            statusIsError = false
        } catch {
            statusMessage = "❌ 导入失败：\(error.localizedDescription)"
            statusIsError = true
        }
    }

    // MARK: - helpers

    #if os(iOS)
    private func writeToTempFile(_ data: Data, filename: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
    #endif
}

#if os(iOS)
// MARK: - Share Sheet wrapper

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
