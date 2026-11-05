import SwiftUI
import Combine

/// 工具抽屉（#093 plan-tool-drawer §2.1）：Prompt 页进来，逐个工具「直接给 / 收进更多工具 / 关」。
/// 抽屉只能收窄：上游（权限、记忆开关、工具总开关、卡）关着的工具，这里开着也不发——行变灰写原因，抽屉自己的状态保留。
/// 顶部数字和实发同一个函数算（CVM.previewTools → toolInjection silent），只在这页开着时、改动后防抖 0.25 秒算一次。
struct ToolDrawerPage: View {
    /// 聊天里进来才有；设置页进来是 nil（能改，但不显示这一轮的数字）
    var viewModel: ConversationViewModel?

    @Environment(\.settingsMetrics) private var m
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @AppStorage("selectedChatModel") private var selectedChatModelId = ""
    @AppStorage("assistantName") private var assistantName = "助手"
    @AppStorage("userName") private var userName = "你"

    private enum Scope: String, Hashable { case global, floor }
    @State private var scope: Scope = .global
    @State private var preview: ToolDrawerPreview?
    /// 上游开关（权限档位 / 记忆 / 搜索服务）的快照：别处（或组头档位控件）改了才变，行状态和顶部数字跟着重算。
    /// 只比快照不数通知：页面自己算数字时碰到的 defaults 写入不会触发重算（不会自己绕圈）
    @State private var upstreamSnapshot: [String] = []
    @State private var confirmReset = false

    private var store: ToolDrawerStore { ToolDrawerStore.shared }

    private var profileId: String? {
        viewModel?.selectedConversation?.profileId ?? profileManager?.currentProfile.id
    }

    private var floorName: String {
        guard let profileId else { return "" }
        return profileManager?.profiles.first { $0.id == profileId }?.name ?? profileManager?.currentProfile.name ?? ""
    }

    private struct RefreshKey: Equatable {
        let version: Int
        let model: String
        let profileId: String?
        let conversationId: String?
        let upstream: [String]
        let mcpTools: Int
    }

    private static func upstreamSnapshotNow() -> [String] {
        PermissionDomain.allCases.map { "\($0.rawValue)=\(PermissionCenter.level($0).rawValue)" }
            + ["mem=\(SelfMemoryTool.enabled)", "recall=\(RecallTool.enabled)", "voice=\(InnerVoice.enabled)",
               "search=\(WebSearchSettings.shared.selected != nil)"]
    }

    var body: some View {
        let ctx = gateContext
        let upstream = Dictionary(ToolRegistry.all.map { ($0.definition.name, $0.enabledIf(ctx)) }, uniquingKeysWith: { a, b in a || b })
        SettingsSectionList(.list) {
            // 工具总开关（粟粟 10-15：抽屉页最上面也放一个，和设置 · 权限 / MCP 里的是同一个）
            Section {
                PermissionDomainRow(domain: .toolsMaster)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                summaryBlock
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            ForEach(ToolDrawerCatalog.Group.allCases) { group in
                let items = ToolDrawerCatalog.items.filter { $0.group == group }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            row(item, upstream: upstream, ctx: ctx)
                        }
                    } header: {
                        groupHeader(group)
                    }
                    .listRowBackground(Theme.mainBg)
                }
            }

            mcpSections

            Section {
                Button(scope == .global ? "全部恢复默认" : "本楼层全部恢复跟随全局") { confirmReset = true }
                    .font(m.body)
                    .foregroundColor(Theme.textSecondary)
                    .settingsActionButton()
            } footer: {
                Text(scope == .global ? "全局恢复成默认分法，不动各楼层自己改过的。" : "删掉本楼层自己的设置，全部跟着全局走。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        .navigationTitle("工具抽屉")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(scope == .global ? "全局全部恢复默认？" : "本楼层全部恢复跟随全局？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复", role: .destructive) { resetScope() }
            Button("取消", role: .cancel) {}
        }
        .onAppear { upstreamSnapshot = Self.upstreamSnapshotNow() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            let now = Self.upstreamSnapshotNow()
            if now != upstreamSnapshot { upstreamSnapshot = now }
        }
        .task(id: RefreshKey(version: store.version, model: selectedChatModelId, profileId: profileId,
                             conversationId: viewModel?.selectedConversation?.id, upstream: upstreamSnapshot,
                             mcpTools: MCPProvider.shared.enabledTools(for: MCPProvider.shared.activeServerIds).count)) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let pm = providerManager else { return }
            preview = viewModel?.previewTools(providerManager: pm, globalModelId: selectedChatModelId)
        }
    }

    // MARK: 顶部：范围 + 本轮数字 + 缓存提示

    @ViewBuilder
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("范围", selection: $scope) {
                Text("全局").tag(Scope.global)
                Text(floorName.isEmpty ? "本楼层" : "本楼层 · \(floorName)").tag(Scope.floor)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let preview {
                if let reason = preview.absentReason {
                    Text("当前不下发任何工具（\(PersonaSettingsTab.toolsAbsentText(reason))）。这里改的，下次能发工具时生效。")
                        .font(m.caption)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("本轮下发 \(preview.toolCount) 个工具 · 收起 \(preview.tuckedCount) 个 · 约 \(Self.tokenText(preview.definitionTokens + preview.hintTokens)) token")
                        .font(m.body)
                        .foregroundColor(Theme.textPrimary)
                    Text("按这个对话的模型「\(preview.modelName)」算：工具定义约 \(Self.tokenText(preview.definitionTokens)) + 工具说明约 \(Self.tokenText(preview.hintTokens))（粗估）")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let convId = viewModel?.selectedConversation?.id,
                       ToolDrawerStore.cacheBreaks(sent: store.sentSignature(conversationId: convId), next: preview.signature) {
                        Label("工具变了：下一轮整段缓存重写一次，之后恢复命中。改几个再发，也只断这一次。", systemImage: "info.circle")
                            .font(m.caption)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if viewModel?.selectedConversation == nil {
                Text("设置页没有绑定对话——到聊天右栏「Prompt 工具」看这一轮实发")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("聊到一半开关工具，下一条要整段重写缓存，会贵好几倍（只贵这一条）。最好开聊前设好，聊的过程中别来回切。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: 组头

    @ViewBuilder
    private func groupHeader(_ group: ToolDrawerCatalog.Group) -> some View {
        HStack {
            Text(group.title)
            Spacer()
            if let domain = group.permissionDomain {
                Text("权限")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                PermissionLevelPicker(domain: domain)
                    .fixedSize()
            }
        }
    }

    // MARK: 一行

    @ViewBuilder
    private func row(_ item: ToolDrawerCatalog.Item, upstream: [String: Bool], ctx: ToolGateContext) -> some View {
        let mode = currentMode(item.name)
        let up = upstreamStatus(item, upstream: upstream, ctx: ctx)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 8) {
                Text(item.name)
                    .font(.system(size: m.secondarySize, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if item.canTuck && mode != .off {
                    Picker("", selection: Binding(get: { mode }, set: { setMode($0, for: item.name) })) {
                        Text("直接给").tag(ToolDrawerMode.inline)
                        Text("收起").tag(ToolDrawerMode.tucked)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Theme.textSecondary)
                    .fixedSize()
                }
                if item.canToggle {
                    Toggle("", isOn: Binding(
                        get: { mode != .off },
                        set: { setMode($0 ? ToolRegistry.defaultMode(item.name) : .off, for: item.name) }
                    ))
                    .labelsHidden()
                    #if os(macOS)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    #endif
                    .tint(Theme.branchIndicator)
                }
            }
            Text(ToolDrawerCatalog.summary(item, assistantName: assistantName, userName: userName))
                .font(m.caption)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(statusText(item, mode: mode, upstream: up))
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .opacity(up.on && preview?.absentReason == nil ? 1 : 0.55)
        .contextMenu {
            if scope == .floor, let profileId, store.state.floorOverride(item.name, profileId: profileId) != nil {
                Button("恢复跟随全局") { store.update { $0.set(nil, for: item.name, profileId: profileId) } }
            }
        }
    }

    // MARK: MCP（Q3：只开关、只全局，直写 MCPProvider——和设置 · MCP 同一个真相源）

    @ViewBuilder
    private var mcpSections: some View {
        let mcp = MCPProvider.shared
        let reserved = Set(ToolRegistry.all.map(\.definition.name))
        let liveCount = mcp.enabledTools(for: mcp.activeServerIds).count
        ForEach(mcp.servers.filter { !$0.tools.isEmpty }) { server in
            Section {
                ForEach(server.tools) { tool in
                    mcpRow(server: server, tool: tool, reserved: reserved.contains(tool.name),
                           deferred: liveCount > ConversationViewModel.mcpDeferThreshold)
                }
            } header: {
                HStack {
                    Text("MCP · \(server.name)")
                    Spacer()
                    if scope == .floor {
                        Text("全局")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
            } footer: {
                Text("MCP 工具只能开关、不分楼层，和设置 · MCP 里的开关是同一个。超过 \(ConversationViewModel.mcpDeferThreshold) 个时整体收进目录（现在 \(liveCount) 个）。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Theme.mainBg)
        }
    }

    /// deferred = 这一轮 MCP 超过阈值整体收进目录（和注入同一个判定，astra #6）
    private func mcpRow(server: MCPServerConfig, tool: MCPToolConfig, reserved: Bool, deferred: Bool) -> some View {
        var status: [String] = []
        if !server.enabled { status.append("这个 server 没启用") }
        if reserved { status.append("和内建工具同名，不发") }
        status.append(tool.enabled ? (deferred ? "收进目录（经 tool_search 找）" : "直接给") : "关")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(tool.name)
                    .font(.system(size: m.secondarySize, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(
                    get: { tool.enabled },
                    set: { MCPProvider.shared.setToolEnabled(serverId: server.id, toolName: tool.name, enabled: $0) }
                ))
                .labelsHidden()
                #if os(macOS)
                .toggleStyle(.switch)
                .controlSize(.small)
                #endif
                .tint(Theme.branchIndicator)
            }
            if !tool.description.isEmpty {
                Text(ToolRegistry.firstSentence(tool.description))
                    .font(m.caption)
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(status.joined(separator: " · "))
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .padding(.vertical, 2)
        .opacity(server.enabled && !reserved ? 1 : 0.55)
    }

    // MARK: 状态

    private var gateContext: ToolGateContext {
        ToolGateContext(family: family, deferMCP: false, profileId: profileId, drawer: store.state)
    }

    /// 这一轮的卡是哪一家（决定 search_web / browse_url 和服务端 web_search 谁有份）
    private var family: ToolGateContext.Family {
        guard let pm = providerManager else { return .openAI }
        let model = pm.resolveModel(conversationModelId: viewModel?.selectedConversation?.selectedModelId, globalFallbackId: selectedChatModelId)
        return pm.provider(for: model)?.type == .anthropic ? .anthropic : .openAI
    }

    private func currentMode(_ name: String) -> ToolDrawerMode {
        switch scope {
        case .global: return store.state.global[name] ?? ToolRegistry.defaultMode(name)
        case .floor: return store.state.override(name, profileId: profileId) ?? ToolRegistry.defaultMode(name)
        }
    }

    private func setMode(_ mode: ToolDrawerMode, for name: String) {
        switch scope {
        case .global:
            // 全局只存和默认不同的
            store.update { $0.set(mode == ToolRegistry.defaultMode(name) ? nil : mode, for: name, profileId: nil) }
        case .floor:
            guard let profileId else { return }
            store.update { $0.set(mode, for: name, profileId: profileId) }
        }
    }

    private func resetScope() {
        switch scope {
        case .global: store.update { $0.global = [:] }
        case .floor:
            guard let profileId else { return }
            store.update { $0.floors[profileId] = nil }
        }
    }

    private struct Upstream {
        let on: Bool
        let reason: String?
    }

    private func upstreamStatus(_ item: ToolDrawerCatalog.Item, upstream: [String: Bool], ctx: ToolGateContext) -> Upstream {
        _ = upstreamSnapshot   // 权限 / 记忆开关改了跟着重算
        if item.gate == .auto { return Upstream(on: true, reason: nil) }
        if item.name == ToolRegistry.serverWebSearchName {
            if ctx.family != .anthropic { return Upstream(on: false, reason: "这一轮用不到（只有 Anthropic 卡用服务端搜索）") }
            return PermissionCenter.capabilityEnabled(.webSearch)
                ? Upstream(on: true, reason: nil) : Upstream(on: false, reason: "\(ToolDrawerCatalog.gateLabel(item.gate)) 关着")
        }
        if upstream[item.name] == true { return Upstream(on: true, reason: nil) }
        if [WebSearchToolService.toolName, BrowseURLTool.toolName].contains(item.name), ctx.family == .anthropic {
            return Upstream(on: false, reason: "这一轮用不到（Anthropic 卡用服务端搜索）")
        }
        if item.name == WebSearchToolService.toolName, PermissionCenter.capabilityEnabled(.webSearch) {
            return Upstream(on: false, reason: "没选搜索服务（设置 · 联网搜索）")
        }
        return Upstream(on: false, reason: "\(ToolDrawerCatalog.gateLabel(item.gate)) 关着，开了才按这里生效")
    }

    private func statusText(_ item: ToolDrawerCatalog.Item, mode: ToolDrawerMode, upstream: Upstream) -> String {
        if item.gate == .auto { return "自动：有收起的工具时才给（不能手动关）" }
        var parts: [String] = []
        if let reason = upstream.reason { parts.append(reason) }
        switch mode {
        case .inline: parts.append("直接给")
        case .tucked: parts.append("收在更多工具")
        case .off: parts.append("关")
        }
        if item.name == ToolRegistry.serverWebSearchName { parts.append("这个工具不能收起") }
        if case .permission(let domain) = item.gate, item.group.permissionDomain == nil {
            parts.append("权限：\(PermissionCenter.level(domain).displayName)")
        }
        if scope == .floor, let profileId, store.state.floorOverride(item.name, profileId: profileId) == nil {
            parts.append("跟随全局")
        }
        return parts.joined(separator: " · ")
    }

    static func tokenText(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}
