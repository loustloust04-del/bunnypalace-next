import SwiftUI

/// 设置 ·「我的电脑」（iOS）/「让手机连这台 Mac」（Mac）——#046 T3 / 审计 T42：配对、连接状态、干活目录收拢到一页。
///
/// iOS：连没连上、连的是哪台、断了为什么 + 重新连接；Agent 干活的目录（一级级点电脑上的文件夹选）；电脑上装没装 tmux / claude / codex；扫码配对。
/// Mac：内嵌 hub 开关 + 状态、依赖检查、配对手机二维码、LAN / Tailscale、干活目录（系统选文件夹窗口）、Hub 日志——
/// 这几节原来在 Claude Code 页（CCSettingsView），整块搬过来，那边只留一行跳转。
#if os(macOS)
import AppKit

struct MyComputerSettingsPage: View {
    @Environment(\.settingsMetrics) private var m
    @ObservedObject private var hub = CCHubProcess.shared
    @AppStorage(CCHubProcess.enabledKey) private var hubEnabledByUser = false
    @AppStorage("ccBindLan") private var bindLan = true
    @AppStorage("ccBindTailscale") private var bindTailscale = true
    @State private var depTmux: DepStatus = .checking
    @State private var depClaude: DepStatus = .checking
    @State private var depCodex: DepStatus = .checking
    @State private var depPython: DepStatus = .checking
    @State private var showHubLog = false
    @State private var showGuideSheet = false  // P5 连接说明文档
    @State private var showPairSheet = false
    /// 改干活目录的结果（hub 拒了的原因 / 已改成）
    @State private var workdirNote: String?

    private var client: CCBridgeWebSocketClient { .shared }

    enum DepStatus: Equatable, Sendable {
        case checking
        case ok(String)   // 版本字符串
        case missing
    }

    var body: some View {
        SettingsSectionList(.list) {
            hubSection
            dependencySection
            pairingSection
            workdirSection
            logSection
        }
        .onAppear {
            runDependencyChecks()
            Task { await hub.refreshExternalHub() }
            client.requestHubConfig()
        }
    }

    // MARK: Hub 服务

    private var hubSection: some View {
        Section {
            Toggle("启动 CC 桥接", isOn: $hubEnabledByUser)
                .font(ShellStyle.bodyFont.weight(.regular))
                .foregroundColor(Theme.textPrimary)
                .onChange(of: hubEnabledByUser) { _, on in
                    if on { hub.startUnlessExternal() } else { hub.stop() }
                }

            if depTmux == .missing {
                Text("没装 tmux：hub 开不了终端窗口。先在终端里跑 brew install tmux（下面「依赖检查」有复制按钮）")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
            }

            if hub.externalHub == true, hub.state == .idle || hub.state == .stopped {
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("这台 Mac 已有 hub 在跑，手机配它就行")
                        .font(ShellStyle.secondaryFont)
                        .foregroundColor(Theme.textMuted)
                }
            } else if hub.state != .idle {
                HStack(spacing: 8) {
                    Circle()
                        .fill(hubStateColor)
                        .frame(width: 8, height: 8)
                    Text(hubStateText)
                        .font(ShellStyle.secondaryFont.monospaced())
                        .foregroundColor(Theme.textMuted)
                }
                if hub.restartCount > 0 {
                    Text("已自动重启 \(hub.restartCount) 次（健康检查 3 次失败时触发）")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted.opacity(0.7))
                }
                if let err = hub.lastError {
                    Text("最近错误：\(err)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.danger)
                }
            }

            // P5 连接说明文档入口
            Button {
                showGuideSheet = true
            } label: {
                Label("连接说明文档", systemImage: "book")
                    .font(ShellStyle.bodyFont.weight(.regular))
                    .foregroundColor(Theme.branchIndicator)
            }
            .buttonStyle(.plain)
        } header: {
            Text("Hub 服务")
        } footer: {
            Text("打开开关后会在后台启动 hub（监听本地 WebSocket，手机和 Claude Code 都经它连这台 Mac），开着的话下次打开 App 自动启动，退出 App 时停止。这台 Mac 已经装了独立的 hub 时不会再起一个。\n\n第一次用？点上面「连接说明文档」，三步配好。")
        }
        .listRowBackground(Theme.mainBg)
        .sheet(isPresented: $showGuideSheet) { CCBridgeGuideSheet() }
    }

    private var hubStateColor: Color {
        switch hub.state {
        case .running: return .green
        case .starting: return .orange
        case .idle, .stopped: return Theme.textMuted
        case .crashed, .unhealthy: return Theme.danger
        }
    }

    private var hubStateText: String {
        switch hub.state {
        case .idle: return "未启动"
        case .starting: return "启动中…"
        case .running:
            let uptime = uptimeText
            if let p = hub.port { return "运行中 · \(uptime) · port \(p)" }
            return "运行中 · \(uptime)"
        case .stopped: return "已停止"
        case .crashed: return "崩溃，等待重启"
        case .unhealthy: return "健康检查失败（限频中）"
        }
    }

    private var uptimeText: String {
        guard let start = hub.startedAt else { return "0s" }
        let s = Int(Date().timeIntervalSince(start))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }

    // MARK: 依赖检查

    private var dependencySection: some View {
        Section {
            depRow(name: "Bun runtime", status: .ok("内置 1.3.11"), installCmd: nil)
            depRow(name: "tmux", status: depTmux, installCmd: "brew install tmux")
            depRow(name: "Claude Code CLI", status: depClaude, installCmd: "curl -fsSL https://claude.ai/install.sh | bash")
            depRow(name: "Codex CLI（可选）", status: depCodex, installCmd: "brew install codex")
            depRow(name: "python3（思考过程 / 提问卡要用）", status: depPython, installCmd: "xcode-select --install")
        } header: {
            Text("依赖检查")
        } footer: {
            Text("Bun 和 hub 已内置在 App 里。其余的自己装：缺哪个点旁边的复制按钮拿命令，粘进终端跑一行（没装 Homebrew 先装它：brew.sh）。Claude Code 装好后在终端里跑一次 claude 登录。Codex 不用可以不装。")
        }
        .listRowBackground(Theme.mainBg)
    }

    @ViewBuilder
    private func depRow(name: String, status: DepStatus, installCmd: String?) -> some View {
        HStack(spacing: 10) {
            switch status {
            case .checking:
                ProgressView().controlSize(.small)
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(ShellStyle.bodyFont.weight(.regular))
            case .missing:
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Theme.danger)
                    .font(ShellStyle.bodyFont.weight(.regular))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(ShellStyle.bodyFont.weight(.regular))
                    .foregroundColor(Theme.textPrimary)
                if case .ok(let ver) = status, !ver.isEmpty {
                    Text(ver)
                        .font(ShellStyle.secondaryFont.monospaced())
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer()
            if case .missing = status, let cmd = installCmd {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                } label: {
                    Label("复制命令", systemImage: "doc.on.clipboard")
                        .font(ShellStyle.secondaryFont)
                        .foregroundColor(Theme.branchIndicator)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func runDependencyChecks() {
        Task.detached(priority: .userInitiated) {
            async let tmux = Self.checkCmd("tmux", versionArgs: ["-V"])
            async let claude = Self.checkCmd("claude", versionArgs: ["--version"])
            async let codex = Self.checkCmd("codex", versionArgs: ["--version"])
            async let python = Self.checkPython()
            let (t, c, x, p) = await (tmux, claude, codex, python)
            await MainActor.run {
                depTmux = t
                depClaude = c
                depCodex = x
                depPython = p
            }
        }
    }

    /// GUI app PATH 不含 brew/npm 路径，手动 prepend（跟 CCHubProcess 同套路）
    private nonisolated static var augmentedEnvironment: [String: String] {
        let home = NSHomeDirectory()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home)/.bun/bin:\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }

    /// 跑一个命令，返回 (退出码, stdout 第一行)。起不来返回 nil
    private nonisolated static func run(_ args: [String]) -> (Int32, String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = args
        task.environment = augmentedEnvironment
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let first = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        return (task.terminationStatus, first)
    }

    private nonisolated static func checkCmd(_ name: String, versionArgs: [String]) async -> DepStatus {
        // 1) which；2) 跑 versionArgs 拿版本（失败也算 ok 无版本字符串）
        guard let which = run(["which", name]), which.0 == 0 else { return .missing }
        guard let ver = run([name] + versionArgs) else { return .ok("") }
        return .ok(ver.1)
    }

    /// 全新 macOS 上 /usr/bin/python3 只是个「装命令行工具」的桩：跑它会弹安装框。
    /// 所以只有 PATH 里找到的不是系统桩，或者命令行工具已经装了（xcode-select -p 成功）才算有，桩不去执行。
    private nonisolated static func checkPython() async -> DepStatus {
        guard let which = run(["which", "python3"]), which.0 == 0 else { return .missing }
        if which.1 == "/usr/bin/python3" {
            guard let clt = run(["xcode-select", "-p"]), clt.0 == 0 else { return .missing }
        }
        guard let ver = run(["python3", "--version"]) else { return .ok("") }
        return .ok(ver.1)
    }

    // MARK: 配对手机

    private var pairingSection: some View {
        Section {
            Button {
                showPairSheet = true
            } label: {
                Label("配对手机", systemImage: "qrcode")
                    .font(ShellStyle.bodyFont.weight(.regular))
                    .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showPairSheet) { CCPairingSheet() }

            Toggle("局域网直连（LAN）", isOn: $bindLan)
                .font(ShellStyle.bodyFont.weight(.regular))
                .foregroundColor(Theme.textPrimary)
                .onChange(of: bindLan) { _, _ in CCBridgeWebSocketClient.shared.sendBindConfig() }
            Toggle("Tailscale（远程 / 加密）", isOn: $bindTailscale)
                .font(ShellStyle.bodyFont.weight(.regular))
                .foregroundColor(Theme.textPrimary)
                .onChange(of: bindTailscale) { _, _ in CCBridgeWebSocketClient.shared.sendBindConfig() }
        } header: {
            Text("连接")
        } footer: {
            Text("点「配对手机」弹出二维码，手机上 设置 → 我的电脑 → 扫码配对，扫一下自动配好地址和密钥（60 秒或配对成功后销毁）。\n\n家里网可信就开 LAN（直连、快，但同网段明文）；不可信网络（咖啡店 / 合租）关掉 LAN、只留 Tailscale（WireGuard 加密）。关掉的接口 hub 真的不再监听。")
        }
        .listRowBackground(Theme.mainBg)
    }

    // MARK: Agent 干活的目录

    private var workdirSection: some View {
        let info = client.currentHubInfo
        return Section {
            HStack {
                Text("Agent 干活的目录")
                    .font(ShellStyle.bodyFont.weight(.regular))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(info.map { $0.dirs.agentWorkdir ?? "和 Agent 的家一样" } ?? (client.isConnected ? "hub 还不支持（要更新）" : "没连上 hub"))
                    .font(ShellStyle.secondaryFont.monospaced())
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 14) {
                Button("选择文件夹…") { chooseWorkdir() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.branchIndicator)
                Button("恢复默认") { applyWorkdir("") }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.branchIndicator)
                    .disabled(info?.dirs.agentWorkdir == nil)
            }
            .font(ShellStyle.bodyFont.weight(.regular))
            .disabled(info == nil)
            if let info {
                Text(homesText(info))
                    .font(ShellStyle.secondaryFont.monospaced())
                    .foregroundColor(Theme.textMuted)
                    .textSelection(.enabled)
            }
            if let workdirNote {
                Text(workdirNote)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
        } header: {
            Text("Agent 干活的目录")
        } footer: {
            Text("只管 [+] 开的「新 Claude Code」「新 Codex」窗口开在哪个文件夹；对话里的 Agent 一直住在家里（人设、收发的文件都在家里）。存在 hub 自己的配置里，手机上也能改。")
        }
        .listRowBackground(Theme.mainBg)
    }

    private func homesText(_ info: HubHello) -> String {
        [info.dirs.claudeHome.map { "Claude 的家：\($0)" }, info.dirs.codexHome.map { "Codex 的家：\($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func chooseWorkdir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "用这个目录"
        if let current = client.currentHubInfo?.dirs.agentWorkdir {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyWorkdir(url.path)
    }

    private func applyWorkdir(_ path: String) {
        workdirNote = nil
        client.setAgentWorkdir(path) { failure in
            workdirNote = failure ?? (path.isEmpty ? "已恢复成和家一样" : "已改成 \(path)，新开的窗口生效")
        }
    }

    // MARK: Hub 日志

    @ViewBuilder
    private var logSection: some View {
        if hub.state != .idle {
            Section {
                DisclosureGroup(isExpanded: $showHubLog) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(hub.logs) { line in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text(timeOnly(line.time))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(Theme.textMuted.opacity(0.7))
                                        Text(line.text)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(logColor(line.level))
                                            .textSelection(.enabled)
                                            .id(line.id)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 6)
                        }
                        .frame(height: 240)
                        .background(Theme.sidebarBg.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onChange(of: hub.logs.count) { _, _ in
                            if let last = hub.logs.last {
                                withAnimation(.easeOut(duration: 0.1)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                } label: {
                    Text("Hub 日志（最近 \(hub.logs.count) 条）")
                        .font(ShellStyle.bodyFont.weight(.regular))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            .listRowBackground(Theme.mainBg)
        }
    }

    private func timeOnly(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func logColor(_ level: CCHubProcess.LogLine.Level) -> Color {
        switch level {
        case .info: return Theme.textSecondary
        case .warn: return .orange
        case .error: return Theme.danger
        }
    }
}

#else

struct MyComputerSettingsPage: View {
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @Environment(\.settingsMetrics) private var m
    /// 扫码配对写的地址。空 = 从没配过对（iOS 上默认的 127.0.0.1 连不到任何东西）
    @AppStorage("ccBridgeBaseURLOverride") private var bridgeOverride = ""
    @State private var showScanner = false
    @State private var pairResult: String?
    @State private var showDirPicker = false
    /// 按了「重新连接」还没连上（T05）
    @State private var reconnecting = false
    /// 改干活目录的结果（hub 拒了的原因 / 已改成）
    @State private var workdirNote: String?

    private var client: CCBridgeWebSocketClient { .shared }
    private var connected: Bool { client.isConnected }
    private var paired: Bool { connected || !bridgeOverride.isEmpty }

    var body: some View {
        SettingsSectionList(.list) {
            statusSection
            workdirSection
            toolsSection
            pairingSection
        }
        .navigationTitle("我的电脑")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { client.requestHubConfig() }
        .onChange(of: connected) { _, now in
            if now {
                reconnecting = false
                client.requestHubConfig()
            }
        }
        .task(id: reconnecting) {
            guard reconnecting else { return }
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { reconnecting = false }
        }
        .fullScreenCover(isPresented: $showScanner) {
            CCPairScannerSheet { payload in pairResult = CCPairingApply.apply(payload, providerManager: providerManager) }
        }
        .sheet(isPresented: $showDirPicker) {
            HubDirectoryPickerSheet(start: client.currentHubInfo?.dirs.agentWorkdir) { path in applyWorkdir(path) }
        }
    }

    // MARK: 状态

    private var statusSection: some View {
        Section {
            HStack {
                Text("状态").font(m.rowLabel).foregroundColor(Theme.textPrimary)
                Spacer()
                Circle().fill(connected ? Theme.branchIndicator : Theme.textMuted.opacity(0.5)).frame(width: 7, height: 7)
                Text(connected ? "已连上" : (paired ? "连不上" : "还没配对"))
                    .font(m.secondary)
                    .foregroundColor(connected ? Theme.branchIndicator : Theme.textMuted)
            }
            if let info = client.hubInfo, let name = info.displayName {
                valueRow(client.currentHubInfo != nil ? "电脑" : "上次连的电脑", name)
            }
            if connected, let host = client.currentHost {
                valueRow("走的路", "\(NetworkRoute.classify(host).label) · \(host)")
            }
            if !connected, paired {
                if let reason = BridgeDisconnectWording.humanize(client.lastError) {
                    Text(reason).font(m.secondary).foregroundColor(Theme.textMuted)
                }
                if let hint = BridgeDisconnectWording.tailscaleHint(lastError: client.lastError, candidateHosts: client.candidateHosts) {
                    Text(hint).font(m.secondary).foregroundColor(Theme.danger.opacity(0.8))
                }
                Button {
                    reconnecting = true
                    client.reconnectNow()
                } label: {
                    Label(reconnecting ? "连接中…" : "重新连接", systemImage: "arrow.counterclockwise")
                        .font(m.rowLabel)
                        .foregroundColor(Theme.textPrimary)
                }
                .disabled(reconnecting)
            }
        } header: {
            Text("连接")
        }
        .listRowBackground(Theme.mainBg)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(m.rowLabel).foregroundColor(Theme.textPrimary)
            Spacer(minLength: 12)
            Text(value)
                .font(m.secondary)
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Agent 干活的目录

    private var workdirSection: some View {
        let info = client.currentHubInfo
        return Section {
            Button {
                showDirPicker = true
            } label: {
                HStack {
                    Text("Agent 干活的目录").font(m.rowLabel).foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 12)
                    Text(info.map { $0.dirs.agentWorkdir.map(Self.shortPath) ?? "和 Agent 的家一样" }
                         ?? (connected ? "电脑上的 hub 要更新" : "没连上"))
                        .font(m.secondary)
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted.opacity(0.5))
                }
            }
            .disabled(info == nil)
            if info?.dirs.agentWorkdir != nil {
                Button("恢复默认") { applyWorkdir("") }
                    .font(m.rowLabel)
                    .foregroundColor(Theme.branchIndicator)
            }
            if let info {
                let homes = [info.dirs.claudeHome.map { "Claude 的家：\($0)" }, info.dirs.codexHome.map { "Codex 的家：\($0)" }]
                    .compactMap { $0 }
                if !homes.isEmpty {
                    Text(homes.joined(separator: "\n"))
                        .font(m.caption.monospaced())
                        .foregroundColor(Theme.textMuted)
                }
            }
            if let workdirNote {
                Text(workdirNote).font(m.caption).foregroundColor(Theme.textMuted)
            }
        } header: {
            Text("Agent 干活的目录")
        } footer: {
            Text("[+] 开的「新 Claude Code」「新 Codex」窗口开在这个文件夹里。对话里的 Agent 一直住在家里（人设、收发的文件都在那），不受影响。")
        }
        .listRowBackground(Theme.mainBg)
    }

    /// /Users/<名字>/… → ~/…（手机屏幕窄）
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Users" else { return path }
        let rest = parts.dropFirst(2).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/\(rest)"
    }

    private func applyWorkdir(_ path: String) {
        workdirNote = nil
        client.setAgentWorkdir(path) { failure in
            workdirNote = failure ?? (path.isEmpty ? "已恢复成和家一样" : "已改好，新开的窗口生效")
        }
    }

    // MARK: 电脑上的工具

    private var toolsSection: some View {
        Section {
            if let tools = client.currentHubInfo?.tools {
                toolRow("tmux", tools.tmux)
                toolRow("Claude Code", tools.claude)
                toolRow("Codex（可选）", tools.codex)
            } else {
                Text(connected ? "电脑上的 hub 更新后这里会列出来" : "连上电脑后这里会列出来")
                    .font(m.secondary)
                    .foregroundColor(Theme.textMuted)
            }
        } header: {
            Text("电脑上的工具")
        } footer: {
            Text("缺哪个，到 Mac 上 设置 →「让手机连这台 Mac」→ 依赖检查，有一行复制命令。没装 Claude Code 时 [+] 里「新 Claude Code」是灰的。")
        }
        .listRowBackground(Theme.mainBg)
    }

    private func toolRow(_ name: String, _ installed: Bool?) -> some View {
        HStack {
            Text(name).font(m.rowLabel).foregroundColor(Theme.textPrimary)
            Spacer()
            switch installed {
            case true?:
                Label("装了", systemImage: "checkmark.circle.fill").foregroundColor(Theme.branchIndicator)
            case false?:
                Label("没装", systemImage: "xmark.circle.fill").foregroundColor(Theme.danger)
            case nil:
                Text("还不知道").foregroundColor(Theme.textMuted)
            }
        }
        .font(m.secondary)
    }

    // MARK: 配对

    private var pairingSection: some View {
        Section {
            valueRow("Hub 地址", bridgeOverride.isEmpty ? "还没配对" : bridgeOverride)
            Button {
                showScanner = true
            } label: {
                Label("扫码配对", systemImage: "qrcode.viewfinder")
                    .font(m.rowLabel)
                    .foregroundColor(Theme.textPrimary)
            }
            if let pairResult {
                Text(pairResult).font(m.caption).foregroundColor(Theme.textMuted)
            }
        } header: {
            Text("配对")
        } footer: {
            Text("第一次用，三步：\n① 在 Mac 上装记忆花园\n② Mac 上打开 设置 →「让手机连这台 Mac」，打开「启动 CC 桥接」，点「配对手机」\n③ 回到这里点「扫码配对」扫那个二维码\n\n扫一次会同时存局域网和 Tailscale 两个地址：在家走局域网，出门自动切 Tailscale（要开着 Tailscale）。局域网那条是同网段明文，家里网可信再用。")
        }
        .listRowBackground(Theme.mainBg)
    }
}

/// 一级一级点进电脑上的文件夹（hub `list_dirs`），「用这个目录」交回路径。自带 NavigationStack，选完整张收起。
struct HubDirectoryPickerSheet: View {
    let start: String?
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HubDirectoryBrowser(path: start) { path in
                onChoose(path)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

private struct HubDirectoryBrowser: View {
    /// nil = 电脑上的家目录（~）
    let path: String?
    let onChoose: (String) -> Void
    @Environment(\.settingsMetrics) private var m
    @State private var listing: HubDirListing?
    @State private var error: String?

    var body: some View {
        List {
            if let listing {
                if let parent = listing.parent {
                    NavigationLink {
                        HubDirectoryBrowser(path: parent, onChoose: onChoose)
                    } label: {
                        Label("上一级（\(Self.name(of: parent))）", systemImage: "arrow.turn.left.up")
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                ForEach(listing.dirs, id: \.self) { name in
                    NavigationLink {
                        HubDirectoryBrowser(path: Self.join(listing.path, name), onChoose: onChoose)
                    } label: {
                        Label(name, systemImage: "folder").foregroundColor(Theme.textPrimary)
                    }
                }
                if listing.dirs.isEmpty {
                    Text("这里面没有文件夹").foregroundColor(Theme.textMuted)
                }
                if listing.truncated {
                    Text("文件夹太多，只列了前 500 个").font(m.caption).foregroundColor(Theme.textMuted)
                }
            } else if let error {
                Text(error).foregroundColor(Theme.textMuted)
            } else {
                ProgressView()
            }
        }
        .font(m.rowLabel)
        .navigationTitle(listing.map { Self.name(of: $0.path) } ?? "电脑上的文件夹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("用这个目录") { if let listing { onChoose(listing.path) } }
                    .disabled(listing == nil)
            }
        }
        .task { load() }
    }

    private func load() {
        guard listing == nil else { return }
        CCBridgeWebSocketClient.shared.listDirs(path: path) { result in
            switch result {
            case .success(let l): listing = l
            case .failure(let e): error = e.reason
            }
        }
    }

    static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    static func name(of path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? "/" : last
    }
}
#endif
