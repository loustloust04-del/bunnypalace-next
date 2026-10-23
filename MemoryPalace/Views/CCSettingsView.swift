import SwiftUI
#if os(iOS) && DEBUG
import ActivityKit
#endif

/// Claude Code 设置：cc-bridge 特有的设置（推送、主动找我/nudge）。
/// 终端键位归「终端」页（通用、将来接 codex 也用），这里只放 CC 相关。
struct CCSettingsView: View {
    @Environment(\.settingsMetrics) private var m
    @AppStorage(CCBridgeWebSocketClient.pushPreviewKey) private var pushPreview = "full"
    @AppStorage("assistantName") private var assistantName = "助手"   // 推送标题用（在「通用」改）

    // 主动找我（nudge）—— 经 set_cc_config 同步给 hub
    @AppStorage("pocketEnabled") private var pocketEnabled = false
    @AppStorage("ccNudgeEnabled") private var nudgeEnabled = false   // §4 默认收紧（老装机由 perm 迁移写显式 true 保行为）
    @AppStorage("ccNewSessionStream") private var newSessionStream = false   // 新会话走 stream（无终端）传输
    @AppStorage("ccNudgeIdleMin") private var idleMin = 15
    @AppStorage("ccNudgeIdleMax") private var idleMax = 30
    @AppStorage("ccNudgeQuietStartMin") private var quietStartMin = 0      // 当天分钟数（按电脑时区）
    @AppStorage("ccNudgeQuietEndMin") private var quietEndMin = 360        // 06:00
    @AppStorage("ccNudgeCooldown") private var cooldown = 60
    @AppStorage("ccNudgeTemplate") private var template = ""               // 空 = 用默认（灰字 placeholder）

    // 思考与存档
    @AppStorage("ccShowThinking") private var showCCThinking = true
    #if os(macOS)
    @State private var cleanupDays: Int? = nil      // ~/.claude/settings.json 的 cleanupPeriodDays，nil=未设置
    @State private var retentionWriteFailed = false
    private static let retentionPresets = [30, 365, 3650, 36500]
    private static let claudeSettingsPath = NSString(string: "~/.claude/settings.json").expandingTildeInPath

    private func readCleanupDays() -> Int? {
        guard let data = FileManager.default.contents(atPath: Self.claudeSettingsPath),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (try? AgentConfigEditor.value(at: ["cleanupPeriodDays"], in: text)) as? Int
    }

    /// 只动 cleanupPeriodDays 这一个 key（AgentConfigEditor：保 key 顺序/注释、原子写、没变不写）。
    /// 文件存在但解析不了 → 拒绝写（绝不覆盖）。
    private func writeCleanupDays(_ days: Int) -> Bool {
        do {
            try AgentConfigEditor.update(fileAt: URL(fileURLWithPath: Self.claudeSettingsPath)) {
                try AgentConfigEditor.setting(days, at: ["cleanupPeriodDays"], in: $0)
            }
            return true
        } catch { return false }
    }
    #endif

    static let defaultTemplate = "[系统] {name} 已经 {idle} 分钟没说话了。如果你想，可以主动找 {name} 说点什么——用 reply 工具回复（chat_id 见本 channel）。也可以选择不打扰。"

    #if os(iOS)
    // 扫码配对：写 URL override + Keychain token → 立即重连
    @Environment(ProviderManager.self) private var providerManager: ProviderManager?
    @State private var showScanner = false
    @State private var pairResult: String?
    private var currentHubURL: String {
        let o = UserDefaults.standard.string(forKey: "ccBridgeBaseURLOverride") ?? ""
        return o.isEmpty ? "ws://127.0.0.1:7890/cc（默认）" : o
    }
    private func applyPairing(_ p: CCPairPayload) {
        pairResult = CCPairingApply.apply(p, providerManager: providerManager)
    }
    #endif

    private func sync() { CCBridgeWebSocketClient.shared.sendCCConfig() }

    #if os(iOS) && DEBUG
    private var liveActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private func startDebugActivity(
        phase: CCActivityPhase,
        ctx: Int? = nil,
        fiveHour: Int? = nil,
        sevenDay: Int? = nil,
        detail: String? = nil
    ) {
        let now = Int(Date().timeIntervalSince1970)
        let state = CCActivityState(
            phase: phase,
            model: "Opus 5",
            ctx: ctx,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            detail: detail,
            sinceUnix: phase == .working || phase == .waiting ? now : nil,
            updatedUnix: now,
            runId: "debug-\(now)"
        )
        Task { await CCLiveActivityDebug.start(state) }
    }
    #endif

    private func dateFromMin(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private func minFromDate(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        // 搜索锚点：命中叶子条目时滚到那一行（`.settingsAnchorScroll` 在 List 上）
        ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            // MARK: 连接（手机配对）
            Section {
                #if os(macOS)
                // hub 开关 / 依赖检查 / 配对手机 / LAN·Tailscale / Hub 日志整块搬去了「让手机连这台 Mac」页（#046），这里只留跳转
                Button {
                    NotificationCenter.default.post(name: .settingsOpenTab, object: SettingsView.SettingsTab.myComputer.rawValue)
                } label: {
                    HStack {
                        Text("去「\(SettingsView.SettingsTab.myComputer.rawValue)」")
                            .font(ShellStyle.bodyFont.weight(.regular))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #else
                NavigationLink {
                    MyComputerSettingsPage()
                } label: {
                    Text("去「我的电脑」配对")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
                HStack {
                    Text("Hub 地址").font(.system(size: Theme.SettingsFont.label, weight: .medium)).foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(currentHubURL).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Button {
                    showScanner = true
                } label: {
                    Label("扫码配对", systemImage: "qrcode.viewfinder")
                        .font(.system(size: Theme.SettingsFont.label, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
                if let note = pairResult {
                    Text(note).font(.system(size: 12)).foregroundColor(Theme.textMuted)
                }
                #endif
            } header: {
                Text("连接")
            } footer: {
                #if os(macOS)
                Text("启动 hub、配对手机、局域网 / Tailscale、依赖检查都在「让手机连这台 Mac」页。")
                #else
                Text("在 Mac 端记忆宫殿 设置 →「让手机连这台 Mac」打开配对二维码，扫一下自动填好地址和密钥（会同时存 LAN + Tailscale，家里走 LAN、出门自动切 Tailscale）。\n\n安全：LAN 那条是同网段明文，家里网可信再用；不可信网络（咖啡店 / 合租）建议走 Tailscale。")
                #endif
            }
            .listRowBackground(Theme.mainBg)

            // MARK: 推送（上架版灰 — 仅开发者 .p8 cert 可推）
            Section {
                Picker("推送内容", selection: $pushPreview) {
                    Text("完整预览").tag("full")
                    Text("不剧透").tag("hidden")
                }
                .font(m.rowLabel)
                .foregroundColor(Theme.textPrimary)
                .onChange(of: pushPreview) { _, mode in CCBridgeWebSocketClient.shared.updatePushPreview(mode) }
                .searchAnchor("leaf-cc-pushcontent")

                HStack {
                    Text("推送显示名").font(m.rowLabel).foregroundColor(Theme.textPrimary)
                    Spacer()
                    #if os(macOS)
                    Text(assistantName).font(ShellStyle.bodyFont.weight(.regular)).foregroundColor(Theme.textMuted)
                    #else
                    Text(assistantName).font(.system(size: Theme.SettingsFont.label)).foregroundColor(Theme.textMuted)
                    #endif
                }
            } header: {
                Text("推送通知")
            } footer: {
                Text("上架版未启用推送（hub 用的 APNs 证书属于开发者，不能给所有用户）。在 app 里看就够，主动找你直接显示在屏幕上。")
            }
            .listRowBackground(Theme.mainBg)
            .disabled(true)
            .opacity(0.5)

            // MARK: 主动找我（nudge）
            Section {
                Toggle("让 AI 主动找我", isOn: $nudgeEnabled)
                    .font(m.rowLabel)
                    .foregroundColor(Theme.textPrimary)
                    .onChange(of: nudgeEnabled) { _, _ in sync() }
                    .searchAnchor("leaf-cc-nudge")

                if nudgeEnabled {
                    ParameterRow(label: "沉默下限（分钟）",
                                 value: Binding(get: { Double(idleMin) },
                                                set: { idleMin = Int($0); if idleMax < idleMin { idleMax = idleMin }; sync() }),
                                 range: 1...180, step: 1, intMode: true)
                    ParameterRow(label: "沉默上限（分钟）",
                                 value: Binding(get: { Double(idleMax) },
                                                set: { idleMax = Int($0); if idleMax < idleMin { idleMin = idleMax }; sync() }),
                                 range: 1...240, step: 1, intMode: true)
                    ParameterRow(label: "冷却（分钟）",
                                 value: Binding(get: { Double(cooldown) },
                                                set: { cooldown = Int($0); sync() }),
                                 range: 0...720, step: 5, intMode: true)

                    DatePicker("休眠从", selection: Binding(get: { dateFromMin(quietStartMin) },
                                                          set: { quietStartMin = minFromDate($0); sync() }),
                               displayedComponents: .hourAndMinute)
                        #if os(macOS)
                        .font(ShellStyle.bodyFont.weight(.regular)).foregroundColor(Theme.textPrimary)
                        #else
                        .font(.system(size: Theme.SettingsFont.label)).foregroundColor(Theme.textPrimary)
                        #endif
                        .searchAnchor("leaf-cc-quiet")
                    DatePicker("休眠到", selection: Binding(get: { dateFromMin(quietEndMin) },
                                                          set: { quietEndMin = minFromDate($0); sync() }),
                               displayedComponents: .hourAndMinute)
                        #if os(macOS)
                        .font(ShellStyle.bodyFont.weight(.regular)).foregroundColor(Theme.textPrimary)
                        #else
                        .font(.system(size: Theme.SettingsFont.label)).foregroundColor(Theme.textPrimary)
                        #endif

                    VStack(alignment: .leading, spacing: 4) {
                        Text("系统提示文案").font(m.rowLabel).foregroundColor(Theme.textPrimary)
                        TextField(Self.defaultTemplate, text: $template, axis: .vertical)
                            .font(.system(size: 13))
                            .lineLimit(3...6)
                            .onChange(of: template) { _, _ in sync() }
                    }
                }
            } header: {
                Text("主动找我")
            } footer: {
                Text("你沉默够久（且非休眠时段、非冷却中）时，AI 会收到一条系统提示，自行决定要不要主动找你。文案留空用上面灰字默认；可用 {idle}=分钟数、{name}=你的名字。休眠时段按这台电脑的时区算。")
            }
            .listRowBackground(Theme.mainBg)

            // MARK: 会话传输（stream 无终端模式）
            Section {
                Toggle("新会话不带终端", isOn: $newSessionStream)
                    .font(m.rowLabel)
                    .foregroundColor(Theme.textPrimary)
                    .onChange(of: newSessionStream) { _, _ in sync() }
                    .searchAnchor("leaf-cc-stream")
            } footer: {
                Text("开了之后新建的 CC 会话不在终端里跑：消息直接送达、权限和提问在对话里答，终端页看不到它。已有会话不变。单个对话可在长按菜单「终端」里单独设，不带终端的会逐字流式显示。")
            }
            .listRowBackground(Theme.mainBg)

            // MARK: 思考与存档
            Section {
                Toggle("显示思考过程", isOn: $showCCThinking)
                    .font(m.rowLabel)
                    .foregroundColor(Theme.textPrimary)
                    .searchAnchor("leaf-cc-thinking")

                #if os(macOS)
                Picker("对话保留时长", selection: Binding(
                    get: { cleanupDays ?? -1 },
                    set: { v in
                        guard v > 0 else { return }
                        if writeCleanupDays(v) { cleanupDays = v; retentionWriteFailed = false }
                        else { retentionWriteFailed = true }
                    }
                )) {
                    if cleanupDays == nil {
                        Text("未设置（CC 默认 30 天）").tag(-1)
                    } else if let cur = cleanupDays, !Self.retentionPresets.contains(cur) {
                        Text("当前（\(cur) 天）").tag(cur)
                    }
                    Text("30 天").tag(30)
                    Text("1 年").tag(365)
                    Text("10 年").tag(3650)
                    Text("一百年").tag(36500)
                }
                .font(ShellStyle.bodyFont.weight(.regular))
                .foregroundColor(Theme.textPrimary)
                if retentionWriteFailed {
                    Text("写入 ~/.claude/settings.json 失败（文件解析不了时不会动它）")
                        .font(ShellStyle.secondaryFont).foregroundColor(.red.opacity(0.8))
                }
                #endif
            } header: {
                Text("思考与存档")
            } footer: {
                #if os(macOS)
                Text("思考过程是 CC 每轮的思考摘要（语言跟随对话），折叠显示在回复气泡里，关掉只是不显示、数据照存。\n\n保留时长写入 ~/.claude/settings.json 的 cleanupPeriodDays（只动这一个 key），决定 CC 本地对话记录保存多久；新开的 CC 会话生效。")
                #else
                Text("思考过程是 CC 每轮的思考摘要（语言跟随对话），折叠显示在回复气泡里，关掉只是不显示、数据照存。保留时长在 Mac 端设置。")
                #endif
            }
            .listRowBackground(Theme.mainBg)

            Section {
                HStack {
                    Text("允许 CC 遥控内置浏览器")
                        .font(m.rowLabel)
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 8)
                    PermissionLevelPicker(domain: .pocket, twoLevelsOnly: true)
                }
                .searchAnchor("leaf-cc-pocket")
            } header: {
                Text("遥控浏览器")
            } footer: {
                Text("开启后，Mac 上的 CC 可以通过 hub 操控 app 内置浏览器——打开页面、执行 JS、截图、读 DOM。使用与内置浏览器相同的登录态。")
            }
            .listRowBackground(Theme.mainBg)

            #if os(iOS) && DEBUG
            Section {
                if !liveActivitiesEnabled {
                    Text("实时活动已在系统设置里关闭")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.danger)
                }

                Button("idle") {
                    startDebugActivity(phase: .idle)
                }
                .disabled(!liveActivitiesEnabled)

                Button("working (ctx 22)") {
                    startDebugActivity(phase: .working, ctx: 22, fiveHour: 47, sevenDay: 75)
                }
                .disabled(!liveActivitiesEnabled)

                Button("waiting (ctx 47)") {
                    startDebugActivity(
                        phase: .waiting,
                        ctx: 47,
                        fiveHour: 22,
                        sevenDay: 75,
                        detail: "要不要把 M4 拆成两步？"
                    )
                }
                .disabled(!liveActivitiesEnabled)

                Button("done (ctx 75)") {
                    startDebugActivity(phase: .done, ctx: 75, fiveHour: 22, sevenDay: 47)
                }
                .disabled(!liveActivitiesEnabled)

                Button("写假快照（静态 widget）") {
                    UsageSnapshotWriter.write(
                        sessionName: "debug",
                        model: "Opus 5",
                        ctx: Int.random(in: 5...95),
                        fiveHour: Int.random(in: 5...95),
                        sevenDay: Int.random(in: 5...95)
                    )
                }

                Button("end", role: .destructive) {
                    Task { await CCLiveActivityDebug.end() }
                }
            } header: {
                Text("DEBUG")
            } footer: {
                Text("本地假数据只用于 Live Activity 五种形态验收和静态 widget 的快照链路，不连接 hub。")
            }
            .listRowBackground(Theme.mainBg)
            #endif
        }
        .navigationTitle("Claude Code")
        .settingsAnchorScroll(anchorProxy)
        #if os(macOS)
        .onAppear { cleanupDays = readCleanupDays() }
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScanner) {
            CCPairScannerSheet { payload in applyPairing(payload) }
        }
        #endif
        }
    }
}
