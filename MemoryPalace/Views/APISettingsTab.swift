import SwiftUI

// MARK: - API Settings Tab (D5 重写后 / 卡片心智一级页)
//
// 一级页只显示已加的 API 卡列表（emoji + 昵称 + sk 前4后4 + 行尾 chevron）+ 全部模型入口 +
// 全局预算 + iCloud Keychain 同步。点卡 → sheet 弹 APICredentialEditor 详情页。
// 旧的提供商 picker / 当前使用 / 已保存 / 自定义配置 / per-provider 模型列表 五块结构
// 已全部删除（M2/D5 重构）。
//
// 一份 body 两端共用（plan-settings-merge 刀 3）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
// 四个二级页在 mac 仍走 sheet（plan-x §1-B10 她裁的），所以 label 里的 chevron 是自画的、不走 `SettingsNavRow`。

/// 把 String? credentialId 包成 Identifiable，给 .sheet(item:) 用。
private struct EditingCredential: Identifiable {
    /// nil = 新建模式（detail page credentialId 传 nil），non-nil = 编辑
    let credentialId: String?
    var id: String { credentialId ?? "__new__" }
}

struct APISettingsTab: View {
    @Environment(\.settingsMetrics) private var m
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @AppStorage("apiKeyCloudSync") private var apiKeyCloudSync = false
    @State private var editing: EditingCredential? = nil
    @State private var cloudSyncMessage: String? = nil
    /// 左滑 / 右键删卡先确认（#092：以前一点就连钥匙串里的 key 一起删了）
    @State private var pendingDelete: APICredential? = nil

    // 联网搜索（M7 webSearchSection）
    @AppStorage(WebSearchSettings.kEnabled) private var webSearchEnabled: Bool = false
    @AppStorage(WebSearchSettings.kResultSize) private var webSearchResultSize: Int = 10
    @AppStorage(WebSearchSettings.kTimeoutMs) private var webSearchTimeoutMs: Int = 5000
    @StateObject private var webSearchSettings = WebSearchSettings.shared
    #if os(macOS)
    @State private var showWebSearchServices: Bool = false
    @State private var showWebLoginStatus: Bool = false
    @State private var showBlockedDomains: Bool = false
    #endif

    var body: some View {
        listContent
            .scrollContentBackground(.hidden)
            #if os(macOS)
            .background(ShellStyle.windowBackground)
            #else
            .background(Theme.sidebarBg)
            #endif
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("API")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(item: $editing) { ec in
                NavigationStack {
                    APICredentialEditor(credentialId: ec.credentialId)
                }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 540)
                #endif
            }
            .onChange(of: apiKeyCloudSync) { _, newValue in
                handleCloudSyncToggled(newValue)
            }
            .confirmationDialog(
                "删除「\(pendingDelete?.name ?? "")」？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { c in
                Button("删除", role: .destructive) {
                    guard let pm = providerManager else { return }
                    pm.removeCredential(id: c.id)
                    pm.resolveStaleSelectedModel()
                    pm.resolveStaleFavorites()
                }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text(APICredential.deleteWarning)
            }
    }

    private var listContent: some View {
        SettingsSectionList(.list) {
            if let pm = providerManager {
                credentialsSection(pm: pm)
                modelPoolSection
                webSearchSection
                streamingSection
                budgetSectionBlock
                cloudSyncSectionBlock
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private func credentialsSection(pm: ProviderManager) -> some View {
        Section {
            if pm.credentials.isEmpty {
                emptyCredentialRow
            } else {
                ForEach(pm.credentials, id: \.id) { c in
                    credentialRow(c, pm: pm)
                }
            }
        } header: {
            HStack {
                Text("API Keys")
                Spacer()
                Button {
                    editing = EditingCredential(credentialId: nil)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        #if os(macOS)
                        .font(ShellStyle.bodyFont.weight(.regular))
                        #else
                        .font(.system(size: 22))
                        #endif
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    private var modelPoolSection: some View {
        Section {
            #if os(iOS)
            NavigationLink {
                ModelPoolPage()
            } label: {
                modelPoolRowLabel
            }
            #else
            // macOS 没 NavigationStack 包裹 → 用 sheet 弹模型池
            Button {
                showModelPool = true
            } label: {
                modelPoolRowLabel
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showModelPool) {
                NavigationStack {
                    ModelPoolPage()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showModelPool = false }
                            }
                        }
                }
                .frame(minWidth: 520, minHeight: 540)
            }
            #endif
        }
        .listRowBackground(Theme.mainBg)
    }

    #if os(macOS)
    @State private var showModelPool: Bool = false
    #endif

    private var modelPoolRowLabel: some View {
        HStack {
            Text("全部模型")
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            let count = providerManager?.credentials.flatMap(\.models).count ?? 0
            Text("\(count)")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
            #if os(macOS)
            Image(systemName: "chevron.right")
                .font(ShellStyle.secondaryFont)
                .foregroundColor(Theme.textMuted.opacity(0.4))
            #endif
        }
        .contentShape(Rectangle())
    }

    // MARK: - 联网搜索（M7）

    @ViewBuilder
    private var webSearchSection: some View {
        Section {
            HStack {
                Text("启用联网搜索")
                Spacer(minLength: 8)
                PermissionLevelPicker(domain: .webSearch)
            }
                .listRowBackground(Theme.mainBg)

            // 当前选中 provider + 进入管理页
            #if os(iOS)
            NavigationLink {
                WebSearchServicesPage()
            } label: {
                webSearchProviderRow
            }
            .listRowBackground(Theme.mainBg)
            #else
            Button {
                showWebSearchServices = true
            } label: {
                webSearchProviderRow
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.mainBg)
            .sheet(isPresented: $showWebSearchServices) {
                NavigationStack {
                    WebSearchServicesPage()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showWebSearchServices = false }
                            }
                        }
                }
                .frame(minWidth: 520, minHeight: 540)
            }
            #endif

            if webSearchEnabled {
                HStack {
                    Text("结果数")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Stepper("\(webSearchResultSize)", value: $webSearchResultSize, in: 1...20)
                        .labelsHidden()
                    Text("\(webSearchResultSize)")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .frame(minWidth: 24, alignment: .trailing)
                }
                .listRowBackground(Theme.mainBg)
                HStack {
                    Text("超时")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Stepper("\(webSearchTimeoutMs/1000)s", value: $webSearchTimeoutMs, in: 1000...30000, step: 1000)
                        .labelsHidden()
                    Text("\(webSearchTimeoutMs/1000)s")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .frame(minWidth: 30, alignment: .trailing)
                }
                .listRowBackground(Theme.mainBg)

                // v2 Phase 3：登录态 + 黑名单
                #if os(iOS)
                NavigationLink {
                    WebLoginStatusPage()
                } label: {
                    settingsRowLabel(title: "网页登录态", trailing: "AI 能用你登录的站")
                }
                .listRowBackground(Theme.mainBg)

                NavigationLink {
                    BlockedDomainsPage()
                } label: {
                    settingsRowLabel(title: "黑名单（AI 不读）",
                                     trailing: webSearchBlockedCountText)
                }
                .listRowBackground(Theme.mainBg)
                #else
                Button { showWebLoginStatus = true } label: {
                    settingsRowLabel(title: "网页登录态", trailing: "AI 能用你登录的站")
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)
                .sheet(isPresented: $showWebLoginStatus) {
                    NavigationStack {
                        WebLoginStatusPage()
                            .toolbar { ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showWebLoginStatus = false }
                            }}
                    }
                    .frame(minWidth: 520, minHeight: 540)
                }

                Button { showBlockedDomains = true } label: {
                    settingsRowLabel(title: "黑名单（AI 不读）", trailing: webSearchBlockedCountText)
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.mainBg)
                .sheet(isPresented: $showBlockedDomains) {
                    NavigationStack {
                        BlockedDomainsPage()
                            .toolbar { ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showBlockedDomains = false }
                            }}
                    }
                    .frame(minWidth: 520, minHeight: 540)
                }
                #endif
            }
        } header: {
            Text("联网搜索")
        } footer: {
            Text("开启后 AI 能调 search_web 搜索网络获取实时信息；Claude 直连用 Anthropic 内置搜索，其他模型用下方选中的服务。API key 走 Keychain。")
                .font(m.caption)
        }
    }

    private var webSearchBlockedCountText: String {
        let c = webSearchSettings.blockedDomains.count
        return c == 0 ? "未设置" : "\(c) 个域"
    }

    private func settingsRowLabel(title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Text(trailing)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
            #if os(macOS)
            Image(systemName: "chevron.right")
                .font(ShellStyle.secondaryFont)
                .foregroundColor(Theme.textMuted.opacity(0.4))
            #endif
        }
        .contentShape(Rectangle())
    }

    private var webSearchProviderRow: some View {
        HStack {
            Text("搜索服务")
                .font(m.body)
                .foregroundColor(Theme.textPrimary)
            Spacer()
            let label = webSearchSettings.selected?.displayLabel ?? "未配置"
            Text(label)
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
            #if os(macOS)
            Image(systemName: "chevron.right")
                .font(ShellStyle.secondaryFont)
                .foregroundColor(Theme.textMuted.opacity(0.4))
            #endif
        }
        .contentShape(Rectangle())
    }

    /// 流式输出（10-02 从 外观 › 对话样式 挪来：它决定请求是不是流式，不只是显示）
    private var streamingSection: some View {
        Section {
            StreamingModeRow(fontSize: m.bodySize, valueSize: m.secondarySize)
        } header: {
            Text("回复方式")
        } footer: {
            Text("流式：边生成边显示。假流式：整段生成完再按打字节奏显示。关闭流式：整段生成完一次显示。Prompt › 采样参数里的「流式输出」关着时，同样不走流式。")
                .font(m.caption)
        }
        .listRowBackground(Theme.mainBg)
    }

    private var budgetSectionBlock: some View {
        Section {
            BudgetSection()
        } header: {
            Text("预算（全局总闸）")
        } footer: {
            Text("所有 API 卡共用一个总预算 —— 不管哪张卡哪个模型，调用费用都汇进同一个保险闸。这不是精细账本，是「别让我吓死自己」的上限。")
                .font(m.caption)
        }
        .listRowBackground(Theme.mainBg)
    }

    private var cloudSyncSectionBlock: some View {
        Section {
            cloudSyncContent
        } header: {
            Text("iCloud Keychain 同步")
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: - Rows

    @ViewBuilder
    private var emptyCredentialRow: some View {
        HStack {
            Image(systemName: "key.slash")
                .foregroundColor(Theme.textMuted)
            Text("还没加 API。点右上 + 加一张")
                .font(m.secondary)
                .foregroundColor(Theme.textMuted)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func credentialRow(_ c: APICredential, pm: ProviderManager) -> some View {
        Button {
            editing = EditingCredential(credentialId: c.id)
        } label: {
            HStack(spacing: 10) {
                Text(c.emoji)
                    #if os(macOS)
                    .font(ShellStyle.bodyFont.weight(.regular))
                    #else
                    .font(.system(size: 24))
                    #endif
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name)
                        .font(m.action)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    keyLabel(for: c, pm: pm)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted.opacity(0.4))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = c
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        #if os(macOS)
        .contextMenu {
            Button(role: .destructive) {
                pendingDelete = c
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        #endif
    }

    @ViewBuilder
    private func keyLabel(for c: APICredential, pm: ProviderManager) -> some View {
        if c.type == .localMLX {
            let installed = c.models.filter { AssistantModelStore.installedDirectory(modelId: $0.modelId) != nil }.count
            Text(installed == 0 ? "还没下载模型" : "已装 \(installed) 个 · 不联网")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        } else if c.type == .ccBridge {
            HStack(spacing: 4) {
                Circle()
                    .fill(CCBridgeWebSocketClient.shared.isConnected ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(CCBridgeWebSocketClient.shared.isConnected ? "已连接" : "本地 WebSocket")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
        } else if c.type == .chatgptOAuth {
            if let token = pm.oauthToken(for: c.id) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("已连接 · \(token.chatgptAccountId.prefix(8))…")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            } else {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text("未登录 ChatGPT")
                        .font(m.caption)
                        .foregroundColor(.orange.opacity(0.8))
                }
            }
        } else if let key = pm.apiKey(for: c.id), !key.isEmpty {
            Text(Self.maskKey(key))
                .font(m.caption.monospaced())
                .foregroundColor(Theme.textMuted)
        } else {
            Text("未配 key")
                .font(m.caption)
                .foregroundColor(.orange.opacity(0.8))
        }
    }

    /// sk-abcd••••wxyz 形式遮罩
    static func maskKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8 { return String(repeating: "•", count: max(4, trimmed.count)) }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)••••\(suffix)"
    }

    // MARK: - iCloud Keychain 同步

    @ViewBuilder
    private var cloudSyncContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $apiKeyCloudSync) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Keychain 同步")
                        .font(m.label.weight(.medium))
                        .foregroundColor(Theme.textPrimary)
                    Text("开启后 API Key 在你登录同一 Apple ID 的设备间同步。对话数据不会同步。")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.branchIndicator)

            if let msg = cloudSyncMessage {
                Text(msg)
                    .font(m.caption)
                    .foregroundColor(msg.contains("失败") ? .red : Theme.textMuted)
            }
        }
    }

    private func handleCloudSyncToggled(_ enabled: Bool) {
        guard let pm = providerManager else { return }
        cloudSyncMessage = enabled ? "正在同步到 iCloud Keychain..." : "正在切回本机 Keychain..."
        let failures = pm.reencryptAllKeys(sync: enabled)
        if failures.isEmpty {
            cloudSyncMessage = enabled ? "已同步到 iCloud Keychain" : "已切回本机 Keychain"
        } else {
            cloudSyncMessage = "切换失败 \(failures.count) 个，请重试或重新输入 key"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            cloudSyncMessage = nil
        }
    }
}

// MARK: - BudgetSection (全局保险闸 — 粟粟决策 2026-04-23)
// 水库总闸门：所有 API 调用（无论 provider 无论主/副模型）汇总到 GlobalBudgetStore。

private struct BudgetSection: View {
    @Environment(\.settingsMetrics) private var m
    private let store = GlobalBudgetStore.shared
    @State private var budgetText: String
    @State private var showResetConfirm = false
    @State private var justSaved = false

    init() {
        _budgetText = State(initialValue: Self.text(for: GlobalBudgetStore.shared))
    }

    /// 从未拨款时显示**默认额度本身**（10），别显示 "0.00"——闸门真的按 10 在计，
    /// 显示 0.00 会让人以为额度是 0（BUG-1 的观感一半来自这里）
    private static func text(for store: GlobalBudgetStore) -> String {
        String(format: "%.2f", store.isBudgetSet ? store.budgetUSD : GlobalBudgetStore.defaultBudgetUSD)
    }

    private var hasUnsavedChanges: Bool {
        budgetText != Self.text(for: store)
    }

    /// 进度条按**有效额度**算：没拨款时有效额度是默认 10，不是 0（不然条永远空着，
    /// 跟「其实在按 10 计闸」对不上）
    private var effectiveBudget: Double {
        store.isBudgetSet ? store.budgetUSD : GlobalBudgetStore.defaultBudgetUSD
    }

    private var percent: Double {
        guard effectiveBudget > 0 else { return 0 }
        return min(store.spentUSD / effectiveBudget, 1.0)
    }

    private var progressTint: Color {
        if percent >= 1.0 { return .red }
        if percent >= 0.8 { return Color(red: 0.9, green: 0.7, blue: 0.35) }
        return Theme.branchIndicator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { store.enabled },
                set: { store.setEnabled($0) }
            )) {
                Text("启用预算限额")
                    .font(m.label.weight(.medium))
                    .foregroundColor(Theme.textPrimary)
            }
            .tint(Theme.branchIndicator)

            HStack {
                Text("预算（USD）")
                    .font(m.label)
                    .foregroundColor(Theme.textSecondary)
                if !store.isBudgetSet {
                    Text("默认")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent))
                }
                Spacer()
                TextField(String(format: "%.2f", GlobalBudgetStore.defaultBudgetUSD), text: $budgetText)
                    .textFieldStyle(.plain)
                    .font(m.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }

            HStack {
                Text("已使用")
                    .font(m.label)
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Text(String(format: "$ %.4f", store.spentUSD))
                    .font(m.body.monospaced())
                    .foregroundColor(Theme.textPrimary)
            }

            ProgressView(value: percent)
                .tint(progressTint)

            HStack {
                Text(String(format: "%.0f%%", percent * 100))
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button(action: { showResetConfirm = true }) {
                    Text("重置已用")
                        .font(m.secondary)
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            }

            Text(store.isBudgetSet
                 ? "含主对话、记忆提取、上下文总结、Dream/Timeline/InnerVoice 等所有后台 agent 的调用。"
                 : "未设置时按 10 美元计。填一个数字保存后按你填的算；清空再保存回到默认 10。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: commitBudget) {
                    Text(justSaved ? "已保存" : "保存")
                        .font(m.secondary.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(
                            justSaved ? Theme.textMuted
                                : (hasUnsavedChanges ? Theme.branchIndicator : Theme.textMuted.opacity(0.4))
                        ))
                }
                .buttonStyle(.plain)
                .disabled(!hasUnsavedChanges || justSaved)
            }
        }
        .opacity(store.enabled ? 1.0 : 0.55)
        .confirmationDialog(
            "清空已用花费？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("重置", role: .destructive) {
                store.resetSpent()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(String(format: "当前已用 $%.4f，预算上限保留。", store.spentUSD))
        }
    }

    private func commitBudget() {
        let raw = budgetText.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty {
            // 清空 = 回到**默认 10**，不是「额度 0」也不是「不限」
            store.clearBudget()
            budgetText = String(format: "%.2f", GlobalBudgetStore.defaultBudgetUSD)
        } else if let v = Double(raw) {
            store.setBudgetUSD(v)
            budgetText = String(format: "%.2f", max(0, v))
        }
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            justSaved = false
        }
    }
}
