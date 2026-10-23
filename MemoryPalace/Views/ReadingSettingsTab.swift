import SwiftUI

/// 设置 · 读书（CR-4.5 R6，粟粟拍的第三模型槽）：
/// AI 自主读书 / 共读用的模型——独立于聊天主副模型。
/// 模型列表 = 各 API 卡 /models 端点拉取的**全量**（粟粟纠偏：不是卡上已存的那几个），
/// 拉取失败回退卡上已存模型。几百个模型配搜索框。
/// macOS 直写 agent/config.json；iOS 经 cc-bridge WS 补丁。
struct ReadingSettingsTab: View {
    /// iOS：false = 「书房」总页（书房 / 书摘设置 + AI 读书一行）；true = 点进去的模型列表二级页（plan-reading-study-3 §3）
    var modelListOnly = false
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m

    /// 当前读书模型（macOS 直读 config；iOS 从 agent_status 快照填）
    @State private var currentModelId: String = ""
    @State private var currentModelName: String = ""

    /// credentialId → /models 拉取的全量列表（失败/未拉取回退 credential.models）
    @State private var fetchedModels: [String: [ProviderModel]] = [:]
    @State private var fetching = false
    @State private var search = ""
    #if os(macOS)
    var macModelSession: MacReadingModelSession? = nil
    @State private var localModelSession = MacReadingModelSession()
    @State private var macLoadGeneration = UUID()
    @State private var macSelectionGeneration = 0
    #endif

    var body: some View {
        content
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle(modelListOnly ? "AI 读书模型" : "书房")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .task(id: eligibleCredentials.map { "\($0.id)|\($0.type.rawValue)|\($0.baseURL)" }) {
            let token = UUID()
            macLoadGeneration = token
            let selectionGeneration = macSelectionGeneration
            let work = Task.detached(priority: .utility) { AgentBridge.currentModelInfo() }
            let info = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, macLoadGeneration == token else { return }
            if macSelectionGeneration == selectionGeneration {
                currentModelId = info?.id ?? ""
                currentModelName = info?.name ?? ""
            }
            guard let manager = providerManager else { return }
            let session = macModelSession ?? localModelSession
            fetching = true
            defer { if macLoadGeneration == token { fetching = false } }
            var results: [String: [ProviderModel]] = [:]
            for credential in eligibleCredentials {
                guard !Task.isCancelled else { return }
                if let models = await session.models(for: credential, manager: manager) {
                    results[credential.id] = models
                }
            }
            guard !Task.isCancelled, macLoadGeneration == token else { return }
            fetchedModels = results
        }
        #else
        .onAppear {
            loadCurrent()
            // 总页只显示当前模型；几百个模型的列表进二级页才拉
            if modelListOnly { fetchAllModels() }
        }
        #endif
        #if os(iOS)
        .onDisappear {
            CCBridgeWebSocketClient.shared.onAgentStatusResult = nil
        }
        #endif
    }

    /// B8：mac「卡 1 固定 + 卡 2 独立滚动」的壳是第 5 类例外，两端只有壳不同；行内容全部走下面的共用子视图
    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macContent
        #else
        if !modelListOnly {
            // 搜索锚点（书房布局 / 书摘样式 / 底图 / 我的图片）：命中时滚到那一行
            ScrollViewReader { anchorProxy in
            SettingsSectionList(.list) {
                StudySettingsSections()
                Section {
                    NavigationLink {
                        ReadingSettingsTab(modelListOnly: true)
                    } label: {
                        currentModelRow
                    }
                    .searchAnchor("leaf-reading-model")
                } header: {
                    Text("AI 读书")
                } footer: {
                    modelFooterText
                }
                .listRowBackground(Theme.mainBg)
            }
            .settingsAnchorScroll(anchorProxy)
            }
        } else {
        SettingsSectionList(.list) {
            Section {
                currentModelRow
            } footer: {
                modelFooterText
            }

            Section {
                searchField
            }

            let cards = eligibleCredentials
            if cards.isEmpty {
                Section {
                    noCardsText
                }
            } else {
                ForEach(cards, id: \.id) { cred in
                    let models = visibleModels(for: cred)
                    if !models.isEmpty {
                        Section {
                            ForEach(models, id: \.id) { model in
                                modelRow(credential: cred, model: model)
                            }
                        } header: {
                            Text("\(cred.emoji) \(cred.name)（\(models.count)）")
                        }
                    }
                }
            }
        }
        }
        #endif
    }

    // MARK: - 两端共用的行内容（B8：只有壳分平台，行只留一份）

    private var currentModelRow: some View {
        HStack {
            Text("当前读书模型")
            Spacer()
            Text(currentModelName.isEmpty ? "—" : currentModelName)
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
    }

    private var modelFooterText: some View {
        Text("AI 自主读书和共读批注用这个模型，独立于聊天模型。用量按 API 返回的费用计入 Agent 预算，部分渠道不返回费用时记 0。")
            .font(m.caption)
            .foregroundColor(Theme.textMuted)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.textMuted)
            TextField("搜模型", text: $search)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if fetching {
                ProgressView().scaleEffect(0.7)
            }
        }
    }

    private var noCardsText: some View {
        Text("没有可用的 API 卡（去 设置 → API 添加）")
            .foregroundColor(Theme.textMuted)
            .font(m.caption)
    }


    #if os(macOS)
    private var macContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacSettingsCard {
                currentModelRow
                modelFooterText
                searchField
            }
            MacSettingsCard {
                List {
                    let cards = eligibleCredentials
                    if cards.isEmpty {
                        noCardsText
                    } else {
                        ForEach(cards, id: \.id) { cred in
                            let models = visibleModels(for: cred)
                            if !models.isEmpty {
                                Section {
                                    ForEach(models, id: \.id) { model in
                                        modelRow(credential: cred, model: model)
                                            .listRowBackground(Color.clear)
                                            .listRowSeparatorTint(ShellStyle.hairline)
                                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                                    }
                                } header: {
                                    Text("\(cred.emoji) \(cred.name)（\(models.count)）")
                                        .font(m.sectionHeader)
                                        .foregroundStyle(m.sectionHeaderColor)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    private func modelRow(credential: APICredential, model: ProviderModel) -> some View {
        Button {
            select(credential: credential, model: model)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(model.modelId)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if model.modelId == currentModelId {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.branchIndicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// hub 只支持 anthropic-messages / openai-completions 两个 family
    private var eligibleCredentials: [APICredential] {
        (providerManager?.credentials ?? []).filter {
            $0.type == .anthropic || $0.type == .openaiCompatible
        }
    }

    /// 该卡可见模型：拉取的全量优先，回退卡上已存；套搜索过滤
    private func visibleModels(for cred: APICredential) -> [ProviderModel] {
        let base = fetchedModels[cred.id] ?? cred.models
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.modelId.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
    }

    /// 进页面把各卡 /models 全量拉一遍（学模型池；失败静默回退已存列表）
    private func fetchAllModels() {
        guard let pm = providerManager, !fetching else { return }
        let creds = eligibleCredentials
        guard !creds.isEmpty else { return }
        fetching = true
        Task {
            for cred in creds {
                if case .success(let models) = await pm.fetchModels(credentialId: cred.id), !models.isEmpty {
                    fetchedModels[cred.id] = models
                }
            }
            fetching = false
        }
    }

    private func loadCurrent() {
        #if os(iOS)
        CCBridgeWebSocketClient.shared.onAgentStatusResult = { payload in
            if let c = payload["config"] as? [String: Any],
               let m = c["model"] as? [String: Any] {
                currentModelId = m["id"] as? String ?? ""
                currentModelName = m["name"] as? String ?? currentModelId
            }
        }
        CCBridgeWebSocketClient.shared.send(["type": "agent_status"]) { _ in }
        #else
        if let info = AgentBridge.currentModelInfo() {
            currentModelId = info.id
            currentModelName = info.name
        }
        #endif
    }

    private func select(credential: APICredential, model: ProviderModel) {
        let dict = AgentBridge.hubModelDict(credential: credential, model: model)
        #if os(iOS)
        // key 随设置同步：iPhone 的卡 key 不在 Mac Keychain（两台不同 iCloud
        // 钥匙串不互通），daemon 在 Mac 上跑会读不到 → 补丁带上 key，hub 写进
        // 本机 Keychain（不落 config 明文）
        var patch: [String: Any] = ["model": dict, "apiKeyAccount": credential.id]
        if let key = providerManager?.apiKey(for: credential.id), !key.isEmpty {
            patch["apiKey"] = key
        }
        CCBridgeWebSocketClient.shared.send([
            "type": "agent_config_set",
            "patch": patch,
        ]) { _ in }
        #else
        AgentBridge.saveModelSelection(model: dict, apiKeyAccount: credential.id)
        macSelectionGeneration += 1
        #endif
        currentModelId = model.modelId
        currentModelName = model.name
    }
}
