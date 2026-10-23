import SwiftUI
import SwiftData

struct MCPSettingsTab: View {
    var viewModel: ConversationViewModel?

    @Environment(\.modelContext) private var modelContext
    @Environment(MCPProvider.self) private var mcpProvider: MCPProvider?
    @Environment(\.settingsMetrics) private var m
    @State private var showingAddSheet = false
    @State private var editingServer: MCPServerConfig?
    @State private var showingJSONEditor = false
    /// D1 确认：mac 行内删除 + iOS 左滑共用一个 pending（存 server id），确认分支才调 `deleteServer`
    @State private var pendingDeleteServerId: String?

    private var provider: MCPProvider { mcpProvider ?? MCPProvider.shared }

    var body: some View {
        pageBody
        .confirmationDialog(
            "删除 Server？",
            isPresented: Binding(get: { pendingDeleteServerId != nil }, set: { if !$0 { pendingDeleteServerId = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { confirmDeleteServer() }
            Button("取消", role: .cancel) { pendingDeleteServerId = nil }
        }
        .sheet(isPresented: $showingAddSheet) {
            MCPServerEditorSheet(server: nil) { name, url, transport, enabled, headers, oauthClientId, oauthClientSecret, command, env in
                provider.addServer(
                    name: name,
                    url: url,
                    transport: transport,
                    enabled: enabled,
                    headers: headers,
                    oauthClientId: oauthClientId,
                    oauthClientSecret: oauthClientSecret,
                    command: command,
                    env: env
                )
            }
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditorSheet(server: server) { name, url, transport, enabled, headers, oauthClientId, oauthClientSecret, command, env in
                var updated = server
                updated.name = name
                updated.url = url
                updated.transport = transport
                updated.enabled = enabled
                updated.headers = headers
                updated.oauthClientId = oauthClientId
                updated.oauthClientSecret = oauthClientSecret
                updated.command = command
                updated.env = env
                provider.updateServer(updated)
            }
        }
        .sheet(isPresented: $showingJSONEditor) {
            MCPJSONEditorSheet(provider: provider)
        }
    }

    // MARK: - 两端共用的一份 body（刀 3 合流：主干取原 iOS 真身，mac 独有的入口按 §2.4 例外包回来）

    private var pageBody: some View {
        SettingsSectionList(.list) {
            #if os(macOS)
            // mac 没有 toolbar：JSON / 添加 收在页顶一行（第 1 类）。只有 header 的 Section 不画空卡
            Section {
                EmptyView()
            } header: {
                HStack {
                    Text("MCP")
                    Spacer()
                    Button {
                        showingJSONEditor = true
                    } label: {
                        Label("JSON", systemImage: "curlybraces")
                    }
                    .buttonStyle(MacSettingsButton())
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .buttonStyle(MacSettingsButton())
                    .tint(Theme.branchIndicator)
                }
            }
            #endif
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("发送请求时携带工具")
                            .font(m.body)
                        Text("「不允许」= 聊天请求不包含任何工具（含文件库/MCP/搜索），模型纯对话。不影响已有配置。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer(minLength: 8)
                    PermissionLevelPicker(domain: .toolsMaster)
                }
            }
            if provider.servers.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("暂无 MCP Server")
                            .font(m.action)
                            .foregroundColor(Theme.textPrimary)
                        Text("点右上「添加」配置远程 MCP server，连接成功的 tools 对所有对话生效。")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
            } else {
                ForEach(provider.servers) { server in
                    serverSection(server)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebarBg)
        #endif
        .navigationTitle("MCP")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showingJSONEditor = true
                } label: {
                    Image(systemName: "curlybraces")
                }
                .tint(Theme.textSecondary)
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(Theme.branchIndicator)
            }
        }
        #endif
    }

    @ViewBuilder
    private func serverSection(_ server: MCPServerConfig) -> some View {
        Section {
            // URL + transport → 点进编辑；iOS 左滑删除，mac 靠组头行内钮（第 7 类）
            Button {
                editingServer = server
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.transport == .stdio ? server.command : server.url)
                            .font(m.caption)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(server.transport.displayName)
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    pendingDeleteServerId = server.id
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            // S1-3：mac 上横扫只有触控板能做、鼠标够不着，右键补一条同样的路（动作同一份）
            #if os(macOS)
            .contextMenu {
                Button(role: .destructive) {
                    pendingDeleteServerId = server.id
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            #endif

            if let error = provider.error(for: server.id), provider.status(for: server.id) == .error {
                Text(error)
                    .font(m.caption)
                    .foregroundColor(.red)
            }

            if server.tools.isEmpty {
                Text(provider.status(for: server.id) == .connected ? "暂无 tools" : "连接后会显示 tools")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            } else {
                ForEach(server.tools) { tool in
                    Toggle(isOn: Binding(
                        get: { tool.enabled },
                        set: { provider.setToolEnabled(serverId: server.id, toolName: tool.name, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(m.action)
                                .foregroundColor(Theme.textPrimary)
                            if !tool.description.isEmpty {
                                Text(tool.description)
                                    .font(m.caption)
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .tint(Theme.branchIndicator)
                }
            }

            Button {
                Task { await provider.reconnect(server.id) }
            } label: {
                Label("重新连接", systemImage: "arrow.clockwise")
                    .font(m.secondary)
                    .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
        } header: {
            HStack(spacing: 6) {
                Text(server.name.isEmpty ? "未命名 Server" : server.name)
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                serverStatusLabel(server)
                #if os(macOS)
                // mac 没有 swipeActions：删除入口放组头（第 7 类）
                Button {
                    pendingDeleteServerId = server.id
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
                #endif
            }
            .textCase(nil)
        }
        .listRowBackground(Theme.mainBg)
    }

    private func serverStatusLabel(_ server: MCPServerConfig) -> some View {
        let status = provider.status(for: server.id)
        let text: String
        let color: Color
        switch status {
        case .idle:
            text = server.enabled ? "未连接" : "停用"
            color = Theme.textMuted
        case .connecting:
            text = "连接中"
            color = Theme.branchIndicator
        case .connected:
            text = "已连接"
            color = Theme.branchIndicator
        case .error:
            text = "错误"
            color = .red
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(m.caption.weight(.medium))
                .foregroundColor(color)
        }
    }

    /// 确认分支才写：按 pending 的 server id 在最新列表里重找（列表变了就不写），只调一次 `deleteServer`
    private func confirmDeleteServer() {
        guard let id = pendingDeleteServerId else { return }
        pendingDeleteServerId = nil
        guard provider.servers.contains(where: { $0.id == id }) else { return }
        provider.deleteServer(id)
    }
}

private struct MCPServerEditorSheet: View {
    let server: MCPServerConfig?
    let onSave: (String, String, MCPTransportType, Bool, [String: String], String, String, String, [String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var transport: MCPTransportType
    @State private var enabled: Bool
    @State private var oauthClientId: String
    @State private var oauthClientSecret: String
    @State private var headersJSON: String
    @State private var command: String
    @State private var envJSON: String
    @State private var errorText: String?
    @State private var advancedExpanded = false

    init(server: MCPServerConfig?, onSave: @escaping (String, String, MCPTransportType, Bool, [String: String], String, String, String, [String: String]) -> Void) {
        self.server = server
        self.onSave = onSave
        _name = State(initialValue: server?.name ?? "")
        _url = State(initialValue: server?.url ?? "")
        _transport = State(initialValue: server?.transport ?? .streamableHTTP)
        _enabled = State(initialValue: server?.enabled ?? true)
        _oauthClientId = State(initialValue: server?.oauthClientId ?? "")
        _oauthClientSecret = State(initialValue: server?.oauthClientSecret ?? "")
        _command = State(initialValue: server?.command ?? "")
        _envJSON = State(initialValue: Self.jsonText(server?.env ?? [:]))
        let headers = server?.headers ?? [:]
        if let data = try? JSONSerialization.data(withJSONObject: headers, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            _headersJSON = State(initialValue: text)
        } else {
            _headersJSON = State(initialValue: "{}")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                SettingsTextField(label: "名称", placeholder: "Memory Server", text: $name)
                #if os(macOS)
                if server == nil, FileManager.default.isExecutableFile(atPath: Self.wakeMCPPath) {
                    Button {
                        name = "Wake"
                        transport = .stdio
                        command = Self.wakeMCPPath
                    } label: {
                        Label("检测到 Wake · 填入", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(MacSettingsButton())
                }
                #endif
                if transport == .stdio {
                    SettingsTextField(label: "命令", placeholder: Self.wakeMCPPath, text: $command)
                    Text(Self.stdioHint)
                        #if os(macOS)
                        .font(ShellStyle.secondaryFont)
                        #else
                        .font(.system(size: Theme.F.caption))
                        #endif
                        .foregroundColor(Theme.textMuted)
                } else {
                    SettingsTextField(label: "远程 URL", placeholder: "https://example.com/mcp", text: $url)
                }
                Picker("连接方式", selection: $transport) {
                    ForEach(MCPTransportType.pickerCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("启用并自动连接", isOn: $enabled)
                    #if os(macOS)
                    .toggleStyle(MacSettingsToggleStyle())
                    #else
                    .toggleStyle(.switch)
                    #endif
                    .foregroundColor(Theme.textPrimary)

                DisclosureGroup(isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if transport != .stdio {
                        SettingsTextField(label: "OAuth ID", placeholder: "OAuth Client ID（可选）", text: $oauthClientId)
                        SettingsTextField(label: "OAuth Secret", placeholder: "OAuth Client Secret（可选）", text: $oauthClientSecret, secure: true)
                        Text("OAuth 暂未接入，以上两项填写后不会生效；连接只使用 URL 和 Headers。")
                            #if os(macOS)
                            .font(ShellStyle.secondaryFont)
                            #else
                            .font(.system(size: Theme.F.caption))
                            #endif
                            .foregroundColor(Theme.textMuted)
                        }
                        Text(transport == .stdio ? "环境变量 JSON" : "Headers JSON")
                            #if os(macOS)
                            .font(ShellStyle.bodyFont.weight(.regular))
                            #else
                            .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                            #endif
                            .foregroundColor(Theme.textSecondary)
                        TextEditor(text: transport == .stdio ? $envJSON : $headersJSON)
                            #if os(macOS)
                            .font(ShellStyle.secondaryFont.monospaced())
                            #else
                            .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                            #endif
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
                    }
                    .padding(.top, 8)
                } label: {
                    Text("高级设置")
                        #if os(macOS)
                        .font(ShellStyle.bodyFont.weight(.regular))
                        #else
                        .font(.system(size: Theme.F.body, weight: .medium))
                        #endif
                        .foregroundColor(Theme.textPrimary)
                }

                if let errorText {
                    Text(errorText)
                        #if os(macOS)
                        .font(ShellStyle.secondaryFont)
                        #else
                        .font(.system(size: Theme.SettingsFont.caption))
                        #endif
                        .foregroundColor(.red)
                }

                Spacer()
            }
            .padding(20)
            .background(Theme.sidebarBg)
            .navigationTitle(server == nil ? "添加自定义连接器" : "编辑自定义连接器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 520)
        #endif
    }

    /// Wake 随包的 stdio server（plan-wake-mcp F2）
    static let wakeMCPPath = "/Applications/Wake.app/Contents/MacOS/wake-mcp"

    private static var stdioHint: String {
        #if os(macOS)
        "从 Dock 打开的 app 不带终端里的 PATH，命令建议写绝对路径。"
        #else
        "本地命令型 MCP 只在 Mac 上可用。"
        #endif
    }

    private static func jsonText(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorText = "名称不能为空"
            return
        }
        if transport == .stdio {
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else {
                errorText = "命令不能为空"
                return
            }
            guard let env = parseEnv() else { return }
            onSave(trimmedName, "", .stdio, enabled, [:], "", "", trimmedCommand, env)
            dismiss()
            return
        }
        guard URL(string: trimmedURL) != nil else {
            errorText = "远程 MCP server URL 无效"
            return
        }
        guard let headers = parseHeaders() else { return }
        onSave(
            trimmedName,
            trimmedURL,
            transport,
            enabled,
            headers,
            oauthClientId.trimmingCharacters(in: .whitespacesAndNewlines),
            oauthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            [:]
        )
        dismiss()
    }

    private func parseEnv() -> [String: String]? {
        let trimmed = envJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errorText = "环境变量必须是 JSON object"
            return nil
        }
        return object.mapValues { "\($0)" }
    }

    private func parseHeaders() -> [String: String]? {
        let trimmed = headersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            errorText = "Headers 必须是 JSON object"
            return nil
        }
        return object.mapValues { "\($0)" }
    }
}

private struct MCPJSONEditorSheet: View {
    let provider: MCPProvider

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var errorText: String?

    init(provider: MCPProvider) {
        self.provider = provider
        _text = State(initialValue: provider.prettyJSON())
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    #if os(macOS)
                    .font(ShellStyle.secondaryFont.monospaced())
                    #else
                    .font(.system(size: Theme.SettingsFont.mono, design: .monospaced))
                    #endif
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.mainBg))
                if let errorText {
                    Text(errorText)
                        #if os(macOS)
                        .font(ShellStyle.secondaryFont)
                        #else
                        .font(.system(size: Theme.SettingsFont.caption))
                        #endif
                        .foregroundColor(.red)
                }
            }
            .padding(20)
            .background(Theme.sidebarBg)
            .navigationTitle("MCP JSON 配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 520)
        #endif
    }

    private func save() {
        do {
            let servers = try MCPProvider.decodeServersJSON(text)
            provider.replaceServers(servers)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
