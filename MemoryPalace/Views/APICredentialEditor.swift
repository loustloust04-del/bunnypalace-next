import SwiftUI

// MARK: - API Credential Editor (M2 详情页 / D3 跨平台)
//
// 卡片心智下"加 key / 改 key / 测试 / 选提供商 / 选 emoji / 命名"的唯一入口。
// 一级页（APISettingsTab）只显示卡列表，点行进这里编辑。
//
// 模式：原生 List + Section（参考 PromptSlot 编辑器、CharacterCardEditor）。
// 用法：
//   navigationDestination(item: $editingCredentialId) { id in
//     APICredentialEditor(credentialId: id) ...
//   }
//   sheet { NavigationStack { APICredentialEditor(credentialId: nil) } }   // 新建

struct APICredentialEditor: View {
    /// nil = 新建模式；non-nil = 编辑已有卡
    let credentialId: String?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("selectedChatModel") private var selectedChatModelId = ""
    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""

    @State private var emoji: String = "🔑"
    @State private var nickname: String = ""
    @State private var presetSelection: String = "_custom_"        // "_custom_" 或 preset.id（如 "openrouter"）
    @State private var customType: ProviderType = .openaiCompatible
    @State private var customBaseURL: String = ""
    @State private var apiKey: String = ""
    @State private var revealKey: Bool = false
    @State private var isFetching: Bool = false
    @State private var fetchError: String? = nil
    @State private var isTesting: Bool = false
    @State private var testResult: Result<String, Error>? = nil
    @State private var savedFlash: Bool = false
    @State private var isSaving: Bool = false
    @State private var confirmDelete: Bool = false
    @State private var confirmSwitch: Bool = false
    @State private var confirmedSwitch: Bool = false
    /// 新卡保存时拉模型失败过：按钮变「仍然保存」，清单里至少有一个模型才能存
    @State private var saveFetchFailed: Bool = false
    @State private var loadedOnce: Bool = false
    @State private var pickingEmoji: Bool = false

    // 局域网发现（刀2/3/4）
    @State private var discovery = ProxyDiscovery()
    @State private var installingServiceId: String? = nil
    /// 实例名 → 上次添加失败的原因（探活失败/后端没配好/网络没被批准），行标灰用
    @State private var installFailures: [String: String] = [:]
    @State private var installedName: String? = nil

    // ccBridge 卡专用
    @State private var hubURLDraft: String = ""
    @State private var hubBackupDraft: String = ""
    @State private var toolsSupported: Bool = true   // 卡级工具调用通道（B 止血）
    @State private var showScanner: Bool = false
    @State private var pairResult: String? = nil
    @State private var connectionTick: Int = 0   // 触发 view 重读 CCBridgeWebSocketClient 状态

    // chatgptOAuth 卡专用
    @State private var oauthLoggedInAccountId: String = ""
    @State private var oauthIsLoggingIn: Bool = false
    @State private var oauthLoginError: String? = nil
    @State private var oauthAuthURL: URL? = nil       // 当前飞行中的授权 URL（inline 显示给用户复制/打开）
    @State private var oauthPasted: String = ""       // 用户粘贴的 callback URL
    private let oauthCoordinator = ChatGPTOAuthLoginCoordinator()

    private var ccBridgeIsConnected: Bool {
        _ = connectionTick   // 显式依赖，重连后 +1 强制刷新
        return CCBridgeWebSocketClient.shared.isConnected
    }

    private var isNew: Bool { credentialId == nil }

    private var resolvedCredential: APICredential? {
        guard let id = credentialId, let pm = providerManager else { return nil }
        return pm.credentials.first(where: { $0.id == id })
    }

    private var currentType: ProviderType {
        if presetSelection == "_custom_" { return customType }
        return APIProvider.presets.first(where: { $0.id == presetSelection })?.type ?? .openaiCompatible
    }

    /// Ollama 跑在用户自己的机器上：地址得能改（iOS 上 localhost 是手机自己，#092 零散雷）
    private var editsBaseURL: Bool {
        presetSelection == "_custom_" || presetSelection == APIProvider.ollama.id
    }

    private var currentBaseURL: String {
        if editsBaseURL { return customBaseURL }
        return APIProvider.presets.first(where: { $0.id == presetSelection })?.baseURL ?? ""
    }

    private var emojiTaken: Bool {
        providerManager?.isEmojiTaken(emoji, excluding: credentialId) ?? false
    }

    @State private var showManualModel = false
    @State private var manualModelId = ""
    @State private var manualModelName = ""

    /// #092 C：HTTP 两种卡的模型清单只改页面草稿，点「保存」才落盘；取消就全撤。
    @State private var draftModels: [ProviderModel] = []
    /// 打开页面时的样子（判断有没有改动：有改动就不许下滑关页）
    @State private var original: DraftSnapshot? = nil

    private struct DraftSnapshot: Equatable {
        var emoji, nickname, presetSelection, customBaseURL, apiKey: String
        var customType: ProviderType
        var toolsSupported: Bool
        var modelIds: [String]
    }

    private var snapshot: DraftSnapshot {
        DraftSnapshot(emoji: emoji, nickname: nickname, presetSelection: presetSelection, customBaseURL: customBaseURL,
                      apiKey: apiKey, customType: customType, toolsSupported: toolsSupported, modelIds: draftModels.map(\.modelId))
    }

    private var isDirty: Bool { original.map { $0 != snapshot } ?? false }

    /// 走 HTTP 的两种卡（测试 / 拉模型都用草稿）；桥卡、ChatGPT 账号、本机模型照旧
    private var isHTTPCard: Bool { currentType == .openaiCompatible || currentType == .anthropic }

    /// 模型区显示的清单：HTTP 卡看草稿，别的看已存的卡
    private var displayModels: [ProviderModel] {
        isHTTPCard ? draftModels : (resolvedCredential?.models ?? [])
    }

    /// 手填模型。清单是推荐不是白名单——服务端只认它收到的 id，不认我们这边列没列过。
    private func addManualModel() {
        let id = manualModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let name = manualModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHTTPCard {
            draftModels.removeAll { $0.modelId == id }
            draftModels.append(ProviderModel(credentialId: draftId, modelId: id, name: name.isEmpty ? id : name))
        } else if let cid = credentialId {
            providerManager?.addModel(to: cid, model: ProviderModel(credentialId: cid, modelId: id, name: name.isEmpty ? id : name))
        }
    }

    private var draftId: String { credentialId ?? "draft" }

    /// 当前页面上的草稿卡（不进卡表）：测试、拉模型、保存都从它出发
    private func makeDraft(id: String) -> APICredential {
        let useCustom = presetSelection == "_custom_"
        let preset = APIProvider.presets.first(where: { $0.id == presetSelection })
        return APICredential(
            id: id,
            name: nickname.trimmingCharacters(in: .whitespaces),
            emoji: emoji.trimmingCharacters(in: .whitespaces),
            presetId: useCustom ? nil : presetSelection,
            type: currentType,
            baseURL: BaseURLNormalizer.normalize(currentBaseURL, type: currentType),
            extraHeaders: useCustom
                ? (currentType == .anthropic ? ["anthropic-version": "2023-06-01"] : [:])
                : (preset?.extraHeaders ?? [:]),
            models: draftModels.map { ProviderModel(credentialId: id, modelId: $0.modelId, name: $0.name) },
            createdAt: resolvedCredential?.createdAt ?? Date(),
            lastUsedAt: resolvedCredential?.lastUsedAt,
            lastUsedModelId: resolvedCredential?.lastUsedModelId,
            toolsSupported: toolsSupported ? nil : false
        )
    }

    /// 拉到的并进草稿（只加不删，顺序：原有的在前）
    private func mergeIntoDraft(_ fetched: [ProviderModel]) -> Int {
        let have = Set(draftModels.map(\.modelId))
        let added = fetched.filter { !have.contains($0.modelId) }
        draftModels += added.map { ProviderModel(credentialId: draftId, modelId: $0.modelId, name: $0.name) }
        return added.count
    }

    /// 单例卡（同类全局只能一张）：新建时它已经存在 → 不许再存一张覆盖它
    private var isSingletonPreset: Bool {
        currentType == .chatgptOAuth || currentType == .ccBridge || currentType == .localMLX
    }

    private func singletonExists(_ presetId: String) -> Bool {
        let singleton = [APIProvider.ccBridge.id, APIProvider.codexBridge.id, APIProvider.chatgptOAuth.id, APICredential.localId]
        return singleton.contains(presetId) && (providerManager?.credentials.contains { $0.id == presetId } ?? false)
    }

    private var singletonTaken: Bool { isNew && singletonExists(presetSelection) }

    private var canSave: Bool {
        // claude-p 的地址靠发现填、且点条目就是整笔安装（探活→拉模型→收藏），不经保存按钮。
        // 放行会存下一张 baseURL 为空的废卡。
        if isNew && presetSelection == APIProvider.claudeP.id { return false }
        if emoji.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if emojiTaken { return false }
        if singletonTaken { return false }
        if nickname.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        // chatgptOAuth 卡：登录后 apiKey 是 OAuth JSON（保存按钮把卡基础信息落盘即可）
        if currentType == .chatgptOAuth || currentType == .localMLX { return true }
        // ccBridge 卡：Hub URL / token 都可以空（loopback 默认），扫码配对会自动填
        if currentType != .ccBridge && apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if isHTTPCard && currentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if saveFetchFailed && isHTTPCard && draftModels.isEmpty { return false }
        return true
    }

    var body: some View {
        List {
            identitySection
            providerSection
            if isNew && presetSelection == APIProvider.claudeP.id {
                discoverySection
            }
            keySection
            if currentType != .localMLX && (!isNew || (isHTTPCard && presetSelection != APIProvider.claudeP.id)) {
                modelsSection
            }
            if !isNew {
                deleteSection
            }
        }
        .alert("手动添加模型", isPresented: $showManualModel) {
            TextField("模型 ID（如 claude-opus-4-6）", text: $manualModelId)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("显示名（留空就用 ID）", text: $manualModelName)
            Button("取消", role: .cancel) {}
            Button("添加") { addManualModel() }
        } message: {
            Text("ID 会原样发给这家服务。填错了不会立刻报错，要到聊天时才会。")
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .interactiveDismissDisabled(isDirty)   // 填了一半，下滑一下别全丢；要走点「取消」
        .navigationTitle(isNew ? "新建 API" : "编辑 API")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(savedFlash ? "✓" : isSaving ? "保存中…" : saveFetchFailed ? "仍然保存" : "保存") { save() }
                    .disabled(!canSave || isSaving)
                    .foregroundColor(canSave ? Theme.branchIndicator : Theme.textMuted)
            }
        }
        .sheet(isPresented: $pickingEmoji) {
            EmojiPickerSheet(current: emoji, used: usedEmojisExcludingSelf()) { picked in
                emoji = picked
                pickingEmoji = false
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showScanner) {
            CCPairScannerSheet { payload in applyPairing(payload) }
        }
        #else
        .sheet(isPresented: $showScanner) {
            // mac 端弹"我是 hub"的二维码，给 iOS 扫
            CCPairingSheet()
        }
        #endif
        .onAppear {
            loadIfNeeded()
            if isNew { discovery.start() }
        }
        .confirmationDialog("换提供商？", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("换，清掉旧模型", role: .destructive) {
                confirmedSwitch = true
                save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            let name = APIProvider.presets.first(where: { $0.id == presetSelection })?.name ?? "自定义"
            Text("换成「\(name)」会清掉这张卡原来的 \(resolvedCredential?.models.count ?? 0) 个模型（收藏、主模型里指向它们的也一起清掉），改用新家的清单并重新拉一次。")
        }
        .onChange(of: presetSelection) { _, _ in resetDraftModelsForProvider() }
        .onChange(of: customType) { _, _ in resetDraftModelsForProvider() }
        .onChange(of: customBaseURL) { _, _ in saveFetchFailed = false }
        .onChange(of: apiKey) { _, _ in saveFetchFailed = false }
        .onDisappear { discovery.stop() }
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            HStack {
                Text("Emoji")
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button {
                    pickingEmoji = true
                } label: {
                    Text(emoji.isEmpty ? "选" : emoji)
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
            }
            if emojiTaken {
                Text("⚠️ 这个 emoji 被别的卡占用了，换一个")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(.red)
            }

            HStack {
                Text("昵称")
                    .foregroundColor(Theme.textSecondary)
                TextField("给这把 key 起个名字", text: $nickname)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
            }
        } header: {
            Text("身份")
        }
        .listRowBackground(Theme.mainBg)
    }

    private var providerSection: some View {
        Section {
            Picker("提供商", selection: $presetSelection) {
                ForEach(APIProvider.presets, id: \.id) { preset in
                    // .menu Picker 的行只吃 Text/Image/Label（自定义 SwiftUI 视图会被丢），
                    // 所以这里不能用 ProviderIconView：没品牌图的三家退回纯文字（原样），不画圆片。
                    let title = isNew && singletonExists(preset.id) ? preset.name + "（已添加）" : preset.name
                    if let asset = ProviderIcon.assetName(presetId: preset.id) {
                        Label { Text(title) } icon: { Image(asset) }.tag(preset.id)
                    } else {
                        Text(title).tag(preset.id)
                    }
                }
                Text("自定义").tag("_custom_")
            }
            .pickerStyle(.menu)
            .tint(Theme.branchIndicator)

            if singletonTaken {
                Text("这张卡已经在列表里了（同类只能有一张），回上一页点它编辑。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(.red)
            }

            if presetSelection == "_custom_" {
                Picker("协议", selection: $customType) {
                    Text("OpenAI 兼容").tag(ProviderType.openaiCompatible)
                    Text("Anthropic").tag(ProviderType.anthropic)
                }
                .pickerStyle(.menu)
                .tint(Theme.branchIndicator)
                .disabled(!isNew)  // 已存卡禁切协议（避免 baseURL/headers 错位）

                baseURLField(placeholder: "https://api.example.com/v1")
            } else if presetSelection == APIProvider.ollama.id {
                #if os(iOS)
                baseURLField(placeholder: "http://<Mac 的局域网 IP>:11434/v1")
                Text("Ollama 跑在你的电脑上。手机上要填那台电脑的局域网地址，localhost 指的是手机自己。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textSecondary)
                #else
                baseURLField(placeholder: APIProvider.ollama.baseURL)
                #endif
            } else if currentType == .localMLX {
                Text("模型直接在这台设备上跑：不联网、不用 key、不花钱。在下面下载要用的模型。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textSecondary)
            } else if presetSelection == APIProvider.claudeP.id {
                Text("在下面挑一台你的 Mac，地址会自动填好。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textSecondary)
            } else {
                HStack {
                    Text("Base URL")
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text(currentBaseURL.replacingOccurrences(of: "https://", with: ""))
                        .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let endpoint = BaseURLNormalizer.chatEndpoint(base: currentBaseURL, type: currentType) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实际请求")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                    Text(endpoint)
                        .font(.system(size: Theme.SettingsFont.caption, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isProxyCard {
                textOnlyNote
            }
        } header: {
            Text("提供商")
        }
        .listRowBackground(Theme.mainBg)
    }

    private func baseURLField(placeholder: String) -> some View {
        HStack {
            Text("Base URL")
                .foregroundColor(Theme.textSecondary)
            TextField(placeholder, text: $customBaseURL)
                .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    private var isProxyCard: Bool {
        guard let id = credentialId else { return false }
        return ProxyCardInstaller.isProxyCard(id: id)
    }

    /// 本地 proxy 只转发纯文本（它自己就把图片/工具内容块丢掉了），把边界写在卡上。
    private var textOnlyNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.alignleft")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted)
            Text("仅文字聊天：这张卡不转发图片，也不会调用工具。")
                .font(.system(size: Theme.SettingsFont.caption))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 发现的服务（刀3：常驻状态行 + 一键添加事务 + 刀4 去重）

    @ViewBuilder
    private var discoverySection: some View {
        Section {
            ForEach(discovery.services) { svc in
                discoveredRow(svc)
            }
            discoveryStatusRow
        } header: {
            Text("你的 Mac")
        } footer: {
            Text("同一个 Wi-Fi 下自动找正在跑 claude-p 的 Mac，点一下就配好，不用手填地址。用的是那台 Mac 上 Claude Code 的订阅额度，不走 API 计费。只走纯文字，不转发图片、不调用工具。")
                .font(.system(size: Theme.SettingsFont.caption))
        }
        .listRowBackground(Theme.mainBg)
    }

    @ViewBuilder
    private func discoveredRow(_ svc: DiscoveredProxy) -> some View {
        if let existing = existingCredential(for: svc) {
            NavigationLink {
                APICredentialEditor(credentialId: existing.id)
            } label: {
                discoveredRowBody(svc, failure: nil, trailing: {
                    Text("已添加 \(existing.emoji)")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                })
            }
        } else {
            let failure = installFailures[svc.id]
            Button {
                install(svc)
            } label: {
                discoveredRowBody(svc, failure: failure, trailing: {
                    if installingServiceId == svc.id {
                        ProgressView().controlSize(.mini)
                    } else if failure != nil {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16))
                            .foregroundColor(Theme.textMuted)
                    } else {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.branchIndicator)
                    }
                })
            }
            .buttonStyle(.plain)
            .disabled(installingServiceId != nil)
        }
    }

    private func discoveredRowBody<Trailing: View>(
        _ svc: DiscoveredProxy,
        failure: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let dimmed = (failure != nil)
        return HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 16))
                .foregroundColor(dimmed ? Theme.textMuted : Theme.branchIndicator)
            VStack(alignment: .leading, spacing: 3) {
                Text(svc.displayName)
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(dimmed ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(svc.displayHost)
                        .font(.system(size: Theme.SettingsFont.caption, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("仅文字")
                        .font(.system(size: Theme.SettingsFont.badge))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent))
                }
                if let failure {
                    Text(failure)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var discoveryStatusRow: some View {
        HStack(spacing: 6) {
            switch discovery.state {
            case .idle, .searching:
                ProgressView().controlSize(.mini)
                Text("正在找同一 Wi-Fi 下的服务…")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            case .found(let n):
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.branchIndicator)
                Text(installedName.map { "已添加「\($0)」· 找到 \(n) 个" } ?? "找到 \(n) 个")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            case .empty:
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                Text("没找到。要先在 Mac 上装好并启动 claude-proxy，再把两台设备连到同一个 Wi-Fi。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            case .permissionDenied:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(.red)
                Text("本地网络权限被拒，找不到任何服务。")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("去设置") { openLocalNetworkSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.branchIndicator)
            case .unavailable(let why):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(.red)
                Text("暂时搜不了：\(why)")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
    }

    /// 刀4：同一个规整后 baseURL 只允许一张卡。
    private func existingCredential(for svc: DiscoveredProxy) -> APICredential? {
        let key = ProxyBaseURL.normalize(svc.baseURL)
        guard !key.isEmpty else { return nil }
        return providerManager?.credentials.first { ProxyBaseURL.normalize($0.baseURL) == key }
    }

    private func install(_ svc: DiscoveredProxy) {
        guard let pm = providerManager, installingServiceId == nil else { return }
        installingServiceId = svc.id
        installFailures[svc.id] = nil
        Task {
            do {
                let card = try await ProxyCardInstaller.install(svc, into: pm)
                installingServiceId = nil
                installedName = card.name
            } catch {
                installingServiceId = nil
                installFailures[svc.id] = "\(error.localizedDescription)（点一下重试）"
            }
        }
    }

    private func openLocalNetworkSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    @ViewBuilder
    private var keySection: some View {
        if currentType == .chatgptOAuth {
            chatgptOAuthSections
        } else if currentType == .localMLX {
            LocalModelsSections()
        } else if currentType == .ccBridge {
            ccBridgeConnectionSections
        } else {
            Section {
                HStack {
                    if revealKey {
                        TextField("sk-...", text: $apiKey)
                            .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                            .autocorrectionDisabled(true)
                            #if os(iOS)

                            .textInputAutocapitalization(.never)

                            #endif
                    } else {
                        SecureField("sk-...", text: $apiKey)
                            .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                            .autocorrectionDisabled(true)
                            #if os(iOS)

                            .textInputAutocapitalization(.never)

                            #endif
                    }
                    Button { revealKey.toggle() } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    runTest()
                } label: {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text("测试连接")
                    }
                    .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
                .disabled(isTesting || apiKey.isEmpty)

                if let result = testResult {
                    switch result {
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(.green)
                    case .failure(let err):
                        // 全文 + 可复制：状态码、上游原因、实际请求地址都在里面
                        Label(err.localizedDescription, systemImage: "xmark.circle.fill")
                            .font(.system(size: Theme.SettingsFont.caption))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("API Key")
            } footer: {
                Text("保存后只显示前 4 后 4 位，真 key 进 Keychain。")
                    .font(.system(size: Theme.SettingsFont.caption))
            }
            .listRowBackground(Theme.mainBg)

            Section {
                Toggle("工具调用", isOn: $toolsSupported)
                    .tint(Theme.branchIndicator)
            } footer: {
                Text("关闭后，走这张卡的请求不携带任何工具，也不会告诉模型有工具可用。后端不支持 function calling 的中转请关掉。")
                    .font(.system(size: Theme.SettingsFont.caption))
            }
            .listRowBackground(Theme.mainBg)
        }
    }

    // MARK: - ChatGPT OAuth 登录（inline 引导，不弹 sheet）

    @ViewBuilder
    private var chatgptOAuthSections: some View {
        Section {
            if !oauthLoggedInAccountId.isEmpty {
                // 已登录态
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已登录")
                            .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                        Text("Account ID: \(oauthLoggedInAccountId.prefix(8))…")
                            .font(.system(size: Theme.SettingsFont.caption, design: .monospaced))
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                }
                Button {
                    startOAuthLogin()
                } label: {
                    Label("重新登录", systemImage: "arrow.clockwise")
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    logoutOAuth()
                } label: {
                    Label("登出", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            } else if oauthAuthURL == nil {
                // 未开始：显示登录按钮
                Button {
                    startOAuthLogin()
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.branchIndicator)
                        Text("用 ChatGPT 账号登录")
                            .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            } else {
                // 飞行中：显示 3 步引导（inline）
                oauthInlineSteps
            }

            if let err = oauthLoginError {
                Text(err)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("ChatGPT 账号")
        } footer: {
            Text("用你的 ChatGPT 账号（订阅）登录后可调 GPT-5.2 等模型，无需买 API key。\nToken 存本机 Keychain。\n实验性：codex backend 未公开，可能随时不可用。")
                .font(.system(size: Theme.SettingsFont.caption))
        }
        .listRowBackground(Theme.mainBg)
    }

    @ViewBuilder
    private var oauthInlineSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1
            VStack(alignment: .leading, spacing: 6) {
                stepHeader(1, "在 Safari 中登录")
                #if os(iOS)
                Button {
                    if let url = oauthAuthURL {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Image(systemName: "safari")
                        Text("在 Safari 中打开登录页")
                            .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.branchIndicator))
                }
                .buttonStyle(.plain)
                #else
                Button {
                    if let url = oauthAuthURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label("在浏览器中打开登录页", systemImage: "safari")
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
                #endif
                Button {
                    if let s = oauthAuthURL?.absoluteString {
                        #if os(iOS)
                        UIPasteboard.general.string = s
                        #else
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s, forType: .string)
                        #endif
                    }
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                        .font(.system(size: Theme.SettingsFont.secondary))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }

            // 2
            VStack(alignment: .leading, spacing: 6) {
                stepHeader(2, "登完之后")
                Text("Safari 会显示「无法连接到服务器」，这是正常的。从地址栏复制整段 URL（以 http://localhost:1455/... 开头，带 code= 和 state=）。")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 3
            VStack(alignment: .leading, spacing: 8) {
                stepHeader(3, "粘贴回来")
                TextField("http://localhost:1455/auth/callback?code=...&state=...", text: $oauthPasted, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.mainBg))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.textMuted.opacity(0.3), lineWidth: 0.5))
                HStack {
                    #if os(iOS)
                    Button {
                        if let s = UIPasteboard.general.string { oauthPasted = s }
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .foregroundColor(Theme.branchIndicator)
                    }
                    .buttonStyle(.plain)
                    #endif

                    Spacer()

                    Button {
                        cancelOAuth()
                    } label: {
                        Text("取消")
                            .font(.system(size: Theme.SettingsFont.secondary))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)

                    Button {
                        submitOAuthCallback()
                    } label: {
                        Text("完成登录")
                            .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(
                                oauthPasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Theme.textMuted.opacity(0.5)
                                    : Theme.branchIndicator
                            ))
                    }
                    .buttonStyle(.plain)
                    .disabled(oauthPasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || oauthIsLoggingIn)
                }
                if oauthIsLoggingIn {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("正在换 token…").font(.system(size: Theme.SettingsFont.caption)).foregroundColor(Theme.textMuted)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stepHeader(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.branchIndicator))
            Text(title)
                .font(.system(size: Theme.SettingsFont.body, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
        }
    }

    private func submitOAuthCallback() {
        let raw = oauthPasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else {
            oauthLoginError = "看着不是个合法 URL，再粘一次？"
            return
        }
        guard url.host == ChatGPTOAuthConfig.redirectHost,
              url.path == ChatGPTOAuthConfig.redirectPath else {
            oauthLoginError = "URL 不对，要以 http://localhost:1455/auth/callback 开头。"
            return
        }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard q.contains(where: { $0.name == "code" && !($0.value?.isEmpty ?? true) }) else {
            oauthLoginError = "URL 里没找到 code= 参数（可能只复制了一部分）。"
            return
        }
        oauthLoginError = nil
        oauthIsLoggingIn = true
        Task { await finishOAuthFromCallback(url) }
    }

    private func cancelOAuth() {
        ChatGPTOAuthLoginCoordinator.clearPending()
        oauthAuthURL = nil
        oauthPasted = ""
        oauthLoginError = nil
        oauthIsLoggingIn = false
    }

    private func startOAuthLogin() {
        oauthLoginError = nil
        oauthPasted = ""
        // 强制清旧 pending，buildAuthorizationURL 永远生新一组（避开老 state 残留导致回调 mismatch）
        ChatGPTOAuthLoginCoordinator.clearPending()
        #if os(iOS)
        guard let url = oauthCoordinator.buildAuthorizationURL() else {
            oauthLoginError = "构造授权 URL 失败"
            return
        }
        oauthAuthURL = url   // 触发 inline 引导 3 步
        #else
        // macOS 仍走系统浏览器 + NWListener 自动收回调
        oauthIsLoggingIn = true
        Task { @MainActor in
            do {
                let token = try await oauthCoordinator.startMacOSLogin()
                applyLoggedInToken(token)
            } catch {
                oauthIsLoggingIn = false
                oauthLoginError = error.localizedDescription
            }
        }
        #endif
    }

    private func finishOAuthFromCallback(_ url: URL) async {
        do {
            let token = try await oauthCoordinator.exchangeFromCallbackURL(url)
            await MainActor.run {
                applyLoggedInToken(token)
                oauthAuthURL = nil   // 完成登录后关闭引导
                oauthPasted = ""
            }
        } catch {
            await MainActor.run {
                oauthIsLoggingIn = false
                oauthLoginError = error.localizedDescription
            }
        }
    }

    private func applyLoggedInToken(_ token: OAuthTokenSet) {
        oauthIsLoggingIn = false
        oauthLoggedInAccountId = token.chatgptAccountId
        // 即时存入 ProviderManager（用当前 credentialId；新建场景下 save() 才生 cred id，
        // 这里临时用预设 id "chatgpt-oauth" 落盘，save() 时若粟粟改了 emoji/昵称会再写一次）
        let cardId = credentialId ?? "chatgpt-oauth"
        providerManager?.setOAuthToken(token, for: cardId)
        // 顺便拉一次 /models
        Task {
            _ = await providerManager?.fetchAndMergeModels(credentialId: cardId)
        }
    }

    private func logoutOAuth() {
        guard let pm = providerManager, let id = credentialId else { return }
        pm.clearOAuthToken(for: id)
        oauthLoggedInAccountId = ""
        oauthLoginError = nil
    }

    // MARK: - ccBridge 连接（扫码配对 + 手动 Hub）

    @ViewBuilder
    private var ccBridgeConnectionSections: some View {
        // 扫码配对（粟粟主路径：从 Mac 端扫码自动填 LAN/Tailscale + Token）
        Section {
            Button {
                showScanner = true
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.branchIndicator)
                    Text("扫码配对")
                        .font(.system(size: Theme.SettingsFont.body, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted.opacity(0.4))
                }
            }
            .buttonStyle(.plain)
            if let note = pairResult {
                Text(note)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
            }
        } header: {
            Text("配对")
        } footer: {
            Text("在 Mac 端记忆宫殿 设置 →「让手机连这台 Mac」打开配对二维码，扫一下自动填好 LAN + Tailscale + Token。家里走 LAN（直连快），出门自动切 Tailscale。")
                .font(.system(size: Theme.SettingsFont.caption))
        }
        .listRowBackground(Theme.mainBg)

        // 连接状态 + 重连
        Section {
            HStack(spacing: 8) {
                Circle()
                    .fill(ccBridgeIsConnected ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(ccBridgeIsConnected ? "已连接" : "未连接")
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(Theme.textPrimary)
                if !ccBridgeIsConnected,
                   let err = CCBridgeWebSocketClient.shared.lastError {
                    Text(err)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(.red.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                Button("重连") { reconnectCC() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.branchIndicator)
            }
        } header: {
            Text("连接状态")
        }
        .listRowBackground(Theme.mainBg)

        // 手动配置（高级）
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hub URL（主）")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textSecondary)
                TextField(APIProvider.ccBridge.baseURL, text: $hubURLDraft)
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    #if os(iOS)

                    .textInputAutocapitalization(.never)

                    #endif
                    .autocorrectionDisabled(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Hub URL（备）")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textSecondary)
                TextField("ws://xxx.ts.net:7890/cc（选填）", text: $hubBackupDraft)
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    #if os(iOS)

                    .textInputAutocapitalization(.never)

                    #endif
                    .autocorrectionDisabled(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Hub Token")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textSecondary)
                SecureField("LAN 模式必填，loopback 留空", text: $apiKey)
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    #if os(iOS)

                    .textInputAutocapitalization(.never)

                    #endif
                    .autocorrectionDisabled(true)
            }
        } header: {
            Text("手动配置（高级）")
        } footer: {
            Text("通常用扫码配对就够了。手动配置只在没法扫码时用——主 URL 连不上时自动 fallback 到备用 URL。保存这张卡同时落盘。")
                .font(.system(size: Theme.SettingsFont.caption))
        }
        .listRowBackground(Theme.mainBg)
    }

    @ViewBuilder
    private var modelsSection: some View {
        Section {
            HStack {
                Text("\(displayModels.count) 个模型")
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button {
                    refreshModels()
                } label: {
                    HStack(spacing: 4) {
                        if isFetching {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("刷新模型")
                    }
                    .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
                .disabled(isFetching || apiKey.isEmpty)
            }

            if let err = fetchError {
                Text(err)
                    .font(.system(size: Theme.SettingsFont.caption))
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !displayModels.isEmpty {
                let models = displayModels
                ForEach(models.prefix(8), id: \.id) { m in
                    HStack {
                        Text(m.name)
                            .font(.system(size: Theme.SettingsFont.secondary))
                        Spacer()
                        Text(m.modelId)
                            .font(.system(size: Theme.SettingsFont.caption, design: .monospaced))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if isHTTPCard {
                            Button(role: .destructive) {
                                draftModels.removeAll { $0.modelId == m.modelId }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                if models.count > 8 {
                    Text(isHTTPCard && isDirty
                         ? "…还有 \(models.count - 8) 个，保存后在「全部模型」页查看"
                         : "…还有 \(models.count - 8) 个，在「全部模型」页查看")
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                }
            }

            Button {
                manualModelId = ""
                manualModelName = ""
                showManualModel = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text("手动添加模型")
                }
                .font(.system(size: Theme.SettingsFont.secondary))
                .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
        } header: {
            Text("模型")
        } footer: {
            Text("刷新拉回来的是这家推荐的清单，不是全部。想用清单外的（比如上一代模型），手动填 ID 就能用。")
                .font(.system(size: Theme.SettingsFont.caption))
        }
        .listRowBackground(Theme.mainBg)
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "trash")
                    Text("删除这张 API 卡")
                    Spacer()
                }
                .foregroundColor(.red)
            }
            .confirmationDialog("删除「\(nickname)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { deleteCredential() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(APICredential.deleteWarning)
            }
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: - Load / Save

    private func loadIfNeeded() {
        guard !loadedOnce else { return }
        loadedOnce = true
        if let c = resolvedCredential, let pm = providerManager {
            emoji = c.emoji
            nickname = c.name
            presetSelection = c.presetId ?? "_custom_"
            customType = c.type
            customBaseURL = c.baseURL
            toolsSupported = c.toolsSupported ?? true
            apiKey = pm.apiKey(for: c.id) ?? ""
            draftModels = c.models
            // chatgptOAuth 卡：apiKey 是 JSON，解出已登录账号 id 显示
            if c.type == .chatgptOAuth, let token = pm.oauthToken(for: c.id) {
                oauthLoggedInAccountId = token.chatgptAccountId
            }
        } else if isNew, let pm = providerManager {
            emoji = pm.allocateUnusedEmoji()
        }
        // chatgptOAuth：未登录但有未过期 pending → 自动恢复 inline 引导（5 分钟内）
        // 解决 iOS 切后台被回收后用户找不到粘贴框的问题
        if currentType == .chatgptOAuth,
           oauthLoggedInAccountId.isEmpty,
           let pendingURL = ChatGPTOAuthLoginCoordinator.loadPendingURLIfFresh() {
            oauthAuthURL = pendingURL   // inline 步骤 2/3 自动显示
        }
        // ccBridge Hub override 永远从 UserDefaults 读（暂全局，M5 待绑卡）
        hubURLDraft = UserDefaults.standard.string(forKey: "ccBridgeBaseURLOverride") ?? ""
        hubBackupDraft = UserDefaults.standard.string(forKey: "ccBridgeBaseURLBackup") ?? ""
        original = snapshot
    }

    /// 换了提供商 / 协议：草稿清单换成新家的预设清单（换回原来的就还原原清单）；旧的测试结论作废
    private func resetDraftModelsForProvider() {
        guard loadedOnce else { return }
        testResult = nil
        fetchError = nil
        saveFetchFailed = false
        if isNew && presetSelection == APIProvider.ollama.id {
            #if os(iOS)
            customBaseURL = ""
            #else
            customBaseURL = APIProvider.ollama.baseURL
            #endif
        }
        if let c = resolvedCredential, presetSelection == (c.presetId ?? "_custom_"),
           presetSelection != "_custom_" || customType == c.type {
            draftModels = c.models
            return
        }
        let preset = APIProvider.presets.first(where: { $0.id == presetSelection })
        draftModels = (preset?.models ?? []).map { ProviderModel(credentialId: draftId, modelId: $0.modelId, name: $0.name) }
    }

    /// 扫码后写入：整体替换 Hub 地址（主 / 备 / 中继）+ Token → 立即重连（ccBridge 卡 id 固定 cc-bridge）
    private func applyPairing(_ p: CCPairPayload) {
        pairResult = CCPairingApply.apply(p, providerManager: providerManager)
        guard pairResult?.hasPrefix("已配对") == true else { return }
        hubURLDraft = p.u ?? ""
        hubBackupDraft = p.u2 ?? ""
        apiKey = p.t   // draft 里同步显示
        // 给 WS 一点时间握手，再刷新状态点
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { connectionTick &+= 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { connectionTick &+= 1 }
    }

    /// 手动重连（用当前 hubURLDraft + backup + apiKey）
    private func reconnectCC() {
        // 先把 draft 落盘；改了地址 = 换了电脑，扫码存的旧中继一起清掉
        CCBridgeEndpoints.saveManual(primary: hubURLDraft, backup: hubBackupDraft)
        let urls = CCBridgeEndpoints.configuredURLs()   // 刚落盘的主 / 备 + （没换目标时）扫码存的中继
        guard !urls.isEmpty else { return }
        let t = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        CCBridgeWebSocketClient.shared.disconnect()
        CCBridgeWebSocketClient.shared.connect(urls: urls, token: t.isEmpty ? nil : t)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { connectionTick &+= 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { connectionTick &+= 1 }
    }

    private func usedEmojisExcludingSelf() -> Set<String> {
        Set((providerManager?.credentials ?? []).filter { $0.id != credentialId }.map(\.emoji))
    }

    private func save() {
        guard let pm = providerManager else { return }
        // 已存卡换了家：先确认会清掉旧模型（粟粟 10-14 拍 K6）
        if !isNew && isHTTPCard && providerChanged && !confirmedSwitch {
            confirmSwitch = true
            return
        }
        // 新建 HTTP 卡（或换了家的卡）：先用草稿拉一次模型，拉到了才落盘（#092 D）；拉不到就留在页面上让人手填，再点「仍然保存」
        let fresh = isHTTPCard && (isNew || providerChanged)
        if fresh && !saveFetchFailed {
            fetchThenPersist(pm)
            return
        }
        persist(pm, adopt: fresh)
    }

    /// 已存卡的提供商 / 协议变了（只改地址不算：同一家换个中转地址，模型多半还能用）
    private var providerChanged: Bool {
        guard let c = resolvedCredential else { return false }
        return presetSelection != (c.presetId ?? "_custom_") || (presetSelection == "_custom_" && customType != c.type)
    }

    private func fetchThenPersist(_ pm: ProviderManager) {
        isSaving = true
        fetchError = nil
        let draft = makeDraft(id: draftId)
        let key = apiKey
        Task {
            let r = await ProviderProbe.fetchModels(draft: draft, key: key)
            await MainActor.run {
                isSaving = false
                switch r {
                case .success(let list) where !list.isEmpty:
                    _ = mergeIntoDraft(list)
                    persist(pm, adopt: true)
                case .success:
                    fetchError = "模型列表是空的。手填一个模型 ID，再点「仍然保存」。"
                    saveFetchFailed = true
                case .failure(let err):
                    fetchError = err.localizedDescription + "\n手填一个模型 ID（或用预设清单），再点「仍然保存」。"
                    saveFetchFailed = true
                }
            }
        }
    }

    /// 唯一落盘入口：卡 + key 一起写；adopt = 新卡（或换了家的卡）挑一个模型收藏、按 K3 接管主模型
    private func persist(_ pm: ProviderManager, adopt: Bool) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = APIProvider.presets.first(where: { $0.id == presetSelection })

        // 固定 id 的特例：Claude Code / Codex / ChatGPT 账号 / 本机模型都是单卡全局服务，id = 预设 id
        // （cc-bridge / codex-bridge / chatgpt-oauth / local-mlx）。以前 ccBridge 一律 "cc-bridge"，
        // 新建 Codex 会盖掉 Claude Code 卡、下次启动整张被删（#092 零散雷）
        let cardId: String
        if let existingId = credentialId {
            cardId = existingId
        } else if isSingletonPreset {
            cardId = presetSelection
        } else {
            cardId = "cred-\(UUID().uuidString)"
        }

        var cred = makeDraft(id: cardId)
        if cred.name.isEmpty { cred.name = "未命名" }
        if cred.emoji.isEmpty { cred.emoji = "🔑" }
        if !isHTTPCard {
            // 桥卡 / ChatGPT 账号 / 本机模型：模型清单不走草稿，沿用已存的（新建时用预设自带的）
            cred.models = resolvedCredential?.models
                ?? (preset?.models.map { ProviderModel(credentialId: cardId, modelId: $0.modelId, name: $0.name) } ?? [])
        }
        let dropped = Set((resolvedCredential?.models ?? []).map(\.id)).subtracting(cred.models.map(\.id))

        pm.addCredential(cred)
        pm.forgetModels(dropped)
        if currentType == .ccBridge {
            // ccBridge：Hub URL override + 备用 URL 写 UserDefaults（暂全局）
            CCBridgeEndpoints.saveManual(primary: hubURLDraft, backup: hubBackupDraft)
            // Token 可空（loopback）
            pm.setApiKey(trimmedKey, for: cardId)
        } else if currentType == .chatgptOAuth {
            // chatgptOAuth：登录时已即时存了 token；这里不动 keychain
            // 仅落卡（emoji/昵称/preset/baseURL/extraHeaders/models）
        } else if currentType == .localMLX {
            // 没有 key；已经装好的模型顺手收藏，选择器里马上能看见
            for model in cred.models where AssistantModelStore.installedDirectory(modelId: model.modelId) != nil
                && !pm.isFavoriteModel(id: model.id) {
                pm.toggleFavoriteModel(id: model.id)
            }
        } else {
            pm.setApiKey(trimmedKey, for: cardId)
        }
        if adopt, let pick = ProviderManager.autoPickModel(cred.models, presetFirst: preset?.models.first?.modelId) {
            pm.adoptNewModel(pick)
        }

        savedFlash = true
        original = snapshot
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            dismiss()
        }
    }

    /// 测试连接：只拿页面草稿发请求，卡表、钥匙串一样都不写（#092 C）
    private func runTest() {
        guard isHTTPCard else { return }
        let draft = makeDraft(id: draftId)
        let key = apiKey
        isTesting = true
        testResult = nil
        Task {
            let r = await ProviderProbe.test(draft: draft, key: key)
            await MainActor.run {
                isTesting = false
                if case .success(let ok) = r, draftModels.isEmpty, !ok.fetchedModels.isEmpty {
                    _ = mergeIntoDraft(ok.fetchedModels)   // 卡上没模型时测试顺手拉到了清单
                }
                testResult = r.map(\.summary)
            }
        }
    }

    private func refreshModels() {
        guard let pm = providerManager else { return }
        isFetching = true
        fetchError = nil
        if isHTTPCard {
            let draft = makeDraft(id: draftId)
            let key = apiKey
            Task {
                let r = await ProviderProbe.fetchModels(draft: draft, key: key)
                await MainActor.run {
                    isFetching = false
                    switch r {
                    case .success(let list):
                        if mergeIntoDraft(list) == 0 && draftModels.isEmpty { fetchError = "拉取成功但 0 个模型" }
                    case .failure(let err):
                        fetchError = err.localizedDescription
                    }
                }
            }
            return
        }
        // ChatGPT 账号卡：token 在钥匙串里，按已存卡拉（这类卡没有可改的地址 / key 草稿）
        guard let id = credentialId else { isFetching = false; return }
        Task {
            let r = await pm.fetchAndMergeModels(credentialId: id)
            await MainActor.run {
                isFetching = false
                if case .failure(let err) = r { fetchError = err.localizedDescription }
            }
        }
    }

    private func deleteCredential() {
        guard let pm = providerManager, let id = credentialId else { return }
        pm.removeCredential(id: id)
        pm.resolveStaleSelectedModel()
        pm.resolveStaleFavorites()
        dismiss()
    }
}

// MARK: - Emoji Picker Sheet（默认池 + 占用提示）

private struct EmojiPickerSheet: View {
    let current: String
    let used: Set<String>
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customInput: String = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("默认池")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textSecondary)

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(CredentialEmoji.pool, id: \.self) { e in
                            emojiCell(e)
                        }
                    }

                    Divider()

                    Text("或输入任意 emoji")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    HStack {
                        TextField("如 🍓", text: $customInput)
                            .font(.system(size: 28))
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
                        Button("使用") {
                            let t = customInput.trimmingCharacters(in: .whitespaces)
                            if !t.isEmpty { onPick(t) }
                        }
                        .disabled(customInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        .foregroundColor(Theme.branchIndicator)
                    }
                }
                .padding()
            }
            .background(Theme.sidebarBg)
            .navigationTitle("选 emoji")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func emojiCell(_ e: String) -> some View {
        let isCurrent = (e == current)
        let isUsed = used.contains(e) && !isCurrent
        Button {
            onPick(e)
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(e)
                    .font(.system(size: 32))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isCurrent ? Theme.branchIndicator.opacity(0.2) : Theme.mainBg)
                    )
                if isUsed {
                    Text("占")
                        .font(.system(size: 10))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.7)))
                        .foregroundColor(.white)
                        .padding(2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isUsed)
    }
}

// MARK: - Model Pool Page（M2.4：一级页"全部模型 N"行 → 这里）
//
// 汇总所有卡的模型；左侧带来源卡 emoji 溯源（D3：两行不合并）；
// 右侧 🌞 主对话 / 🌛 副记忆 / ☆ 收藏 三角色切换。
// M3 才加按卡筛选 chip / 搜索范围扩展。先把 M2 入口跑通。

struct ModelPoolPage: View {
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @AppStorage("selectedChatModel") private var selectedChatModelId = ""
    @AppStorage("memoryExtractModelId") private var memoryExtractModelId = ""
    @State private var search: String = ""
    /// nil = 全部；非 nil = 只看这张卡的模型
    @State private var filterCredentialId: String? = nil
    /// 仅显示已收藏（☆）的模型
    @State private var favoritesOnly: Bool = false

    private struct Row: Identifiable {
        let id: String        // combinedId
        let emoji: String
        let credentialName: String
        let typeKeyword: String   // provider type 关键词（让搜索能命中 "anthropic"/"openai"/"ccBridge"）
        let model: ProviderModel
    }

    private func allRowsByCredential() -> [(APICredential, [Row])] {
        guard let pm = providerManager else { return [] }
        var out: [(APICredential, [Row])] = []
        for c in pm.credentials {
            // 按筛选 chip 过滤
            if let f = filterCredentialId, c.id != f { continue }
            let typeKw: String = {
                switch c.type {
                case .openaiCompatible: return "openai compatible 兼容"
                case .anthropic: return "anthropic claude"
                case .ccBridge: return "ccbridge cc-bridge 本地"
                case .chatgptOAuth: return "chatgpt oauth gpt 账号登录"
                case .localMLX: return "local mlx 本机 本地 qwen"
                case .unsupported: return "unsupported 不支持"
                }
            }()
            let rows = c.models.map {
                Row(id: $0.id, emoji: c.emoji, credentialName: c.name, typeKeyword: typeKw, model: $0)
            }
            if !rows.isEmpty {
                out.append((c, rows))
            }
        }
        return out
    }

    private func applySearchAndFavorites(_ rows: [Row]) -> [Row] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var result = rows
        if favoritesOnly {
            let favIds = Set(providerManager?.favoriteModelIds ?? [])
            result = result.filter { favIds.contains($0.id) }
        }
        if !q.isEmpty {
            result = result.filter {
                $0.model.modelId.lowercased().contains(q) ||
                $0.model.name.lowercased().contains(q) ||
                $0.credentialName.lowercased().contains(q) ||
                $0.typeKeyword.lowercased().contains(q)
            }
        }
        return result
    }

    private var groups: [(APICredential, [Row])] {
        allRowsByCredential().compactMap { (c, rows) in
            let filtered = applySearchAndFavorites(rows)
            return filtered.isEmpty ? nil : (c, filtered)
        }
    }

    private var totalMatched: Int { groups.reduce(0) { $0 + $1.1.count } }
    private var totalAll: Int { providerManager?.credentials.reduce(0) { $0 + $1.models.count } ?? 0 }

    var body: some View {
        List {
            // 筛选 chip 行（在 List section 里横滚，selectionable）
            filterChipsSection

            // 搜索框
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(Theme.textMuted)
                    TextField("搜索 模型 / 卡 / openai / claude…", text: $search)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled(true)
                        #if os(iOS)

                        .textInputAutocapitalization(.never)

                        #endif
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                HStack {
                    Text("🌞 主对话  ·  🌛 副记忆  ·  ☆ 收藏")
                    Spacer()
                    let matched = totalMatched
                    let all = totalAll
                    if matched == all {
                        Text("\(all) 个模型")
                    } else {
                        Text("匹配 \(matched) / 共 \(all)")
                    }
                }
                .font(.system(size: Theme.SettingsFont.caption))
            }
            .listRowBackground(Theme.mainBg)

            // 按卡分组
            if groups.isEmpty {
                Section {
                    Text(emptyStateMessage)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
            } else {
                ForEach(groups, id: \.0.id) { (c, rows) in
                    Section {
                        ForEach(rows) { row in
                            poolRow(row)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { removeModel(row) } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                #if os(macOS)
                                .contextMenu {
                                    Button("从这张卡删掉这个模型", role: .destructive) { removeModel(row) }
                                }
                                #endif
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(c.emoji)
                            Text(c.name)
                                .font(.system(size: Theme.SettingsFont.label, weight: .semibold))
                            Spacer()
                            // emoji 是卡身份（保留），尾部小 logo 才是「这张卡连的哪家」
                            ProviderIconView(presetId: c.presetId, displayName: c.name,
                                             size: AppIconSize.mini, tint: Theme.textMuted)
                            Text("\(rows.count)")
                                .font(.system(size: Theme.SettingsFont.caption))
                                .foregroundColor(Theme.textMuted)
                        }
                        .textCase(nil)
                    }
                    .listRowBackground(Theme.mainBg)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("全部模型")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    favoritesOnly.toggle()
                } label: {
                    Image(systemName: favoritesOnly ? "star.fill" : "star")
                        .foregroundColor(favoritesOnly ? Theme.favorite : Theme.textMuted)
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                Button {
                    favoritesOnly.toggle()
                } label: {
                    Image(systemName: favoritesOnly ? "star.fill" : "star")
                        .foregroundColor(favoritesOnly ? Theme.favorite : Theme.textMuted)
                }
            }
            #endif
        }
    }

    private var emptyStateMessage: String {
        if providerManager?.credentials.isEmpty == true {
            return "还没有卡——回上一页加一张 API"
        }
        if favoritesOnly && search.isEmpty && filterCredentialId == nil {
            return "还没收藏过模型 —— 点行尾的 ☆ 收藏一些"
        }
        if !search.isEmpty || favoritesOnly || filterCredentialId != nil {
            return "没匹配的模型 —— 改下筛选 / 搜索词"
        }
        return "卡里没拉到模型 —— 进卡详情点「刷新模型」"
    }

    // MARK: - 筛选 chip

    @ViewBuilder
    private var filterChipsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: Theme.hScrollIndicators) {
                HStack(spacing: 8) {
                    chip(emoji: nil, label: "全部", id: nil)
                    ForEach(providerManager?.credentials ?? [], id: \.id) { c in
                        chip(emoji: c.emoji, label: c.name, id: c.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
        .listRowBackground(Theme.mainBg)
    }

    @ViewBuilder
    private func chip(emoji: String?, label: String, id: String?) -> some View {
        let selected = (filterCredentialId == id)
        // 按 feedback_horizontal_scrollview_button_swallowed：横向 ScrollView 里
        // 用 contentShape + onTapGesture 而不是 Button，否则 tap 被 ScrollView 吞
        HStack(spacing: 4) {
            if let e = emoji {
                Text(e).font(.system(size: 14))
            } else {
                Image(systemName: "circle.grid.2x2")
                    .font(.system(size: 12))
                    .foregroundColor(selected ? .white : Theme.textMuted)
            }
            Text(label)
                .font(.system(size: Theme.SettingsFont.caption, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(selected ? .white : Theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(selected ? Theme.branchIndicator : Theme.sidebarBg)
        )
        .contentShape(Capsule())
        .onTapGesture {
            filterCredentialId = id
        }
    }

    /// 从卡上删一个模型（#092：以前删不掉，换家后的死模型一直挂着），收藏 / 🌞 / 🌛 指向它的一起清
    private func removeModel(_ row: Row) {
        guard let pm = providerManager else { return }
        pm.removeModel(from: row.model.credentialId, modelId: row.model.modelId)
        pm.forgetModels([row.id])
    }

    @ViewBuilder
    private func poolRow(_ row: Row) -> some View {
        let pm = providerManager
        let isMain = (selectedChatModelId == row.id)
        let isMem = (memoryExtractModelId == row.id)
        let isFav = pm?.isFavoriteModel(id: row.id) ?? false

        HStack(spacing: 8) {
            Text(row.emoji).font(.system(size: 18))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.model.name)
                    .font(.system(size: Theme.SettingsFont.body))
                    .foregroundColor(isMain ? Theme.branchIndicator : Theme.textPrimary)
                    .lineLimit(1)
                if row.model.modelId != row.model.name {
                    Text(row.model.modelId)
                        .font(.system(size: Theme.SettingsFont.caption, design: .monospaced))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // models.dev 目录：上下文 / 推理档位 / 官方价（research-magpie 2.5）
                if let caption = ModelCatalog.shared.model(for: row.model.modelId)?.caption {
                    Text(caption)
                        .font(.system(size: Theme.SettingsFont.caption))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button { selectedChatModelId = row.id } label: {
                Text("🌞").font(.system(size: 18)).opacity(isMain ? 1 : 0.22)
            }
            .buttonStyle(.plain)

            Button { memoryExtractModelId = isMem ? "" : row.id } label: {
                Text("🌛").font(.system(size: 18)).opacity(isMem ? 1 : 0.22)
            }
            .buttonStyle(.plain)

            Button { pm?.toggleFavoriteModel(id: row.id) } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: Theme.SettingsFont.secondary))
                    .foregroundColor(isFav ? Theme.favorite : Theme.textMuted.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}
