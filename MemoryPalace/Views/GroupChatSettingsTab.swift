import SwiftUI

/// 设置 · 群聊（中庭）：总开关 + 发言模式 + 聊天外观（iOS，10-02 从 外观 › 群聊 挪来）+ 连接状态。开关原在开发调试页，转正挪家（07-20 粟粟点的）。
///
/// 一份 body 两端共用（plan-settings-merge 刀 2）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
/// 「AI 发言节奏」的标题 + Slider 同在一个 `VStack` 里（不拆成两行，否则 mac 卡里会多一条分隔线）。
struct GroupChatSettingsTab: View {
    @Environment(\.settingsMetrics) private var m
    @AppStorage(AgoraFeatureGate.key) private var agoraEnabled = false
    @State private var bridgeConnected = CCBridgeWebSocketClient.shared.isConnected
    @State private var speechMode: AgoraSpeechMode?
    @State private var speechModeError = false
    @State private var minSpeakIntervalMs: Int?
    @State private var intervalSeconds: Double = 0
    @State private var intervalDragging = false
    @State private var intervalError = false
    @State private var speechClient = AgoraClient()
    #if os(iOS)
    @AppStorage(GroupRoomStyle.backgroundKey) private var groupBackground = ""
    @AppStorage(GroupRoomStyle.othersKey) private var groupOthers = ""
    @AppStorage(GroupRoomStyle.mineKey) private var groupMine = ""
    #endif

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                Toggle("群聊（中庭）", isOn: $agoraEnabled)
                    .tint(Theme.branchIndicator)
            } footer: {
                Text("开启后，对话列表里会出现群聊房间（置顶分组下方），可以建多人房间和 CC 成员聊天。改动后重启 App 生效。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)

            if agoraEnabled {
                Section {
                    Picker("发言模式", selection: speechModeBinding) {
                        Text("仅 @ 发言").tag(AgoraSpeechMode.mentionOnly)
                        Text("@ 接力").tag(AgoraSpeechMode.relay)
                        Text("自由发言").tag(AgoraSpeechMode.free)
                        Text("轮流发言").tag(AgoraSpeechMode.roundRobin)
                    }
                    .disabled(speechMode == nil)
                } footer: {
                    Text(speechModeFooter)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("AI 发言节奏")
                            Spacer()
                            Text(intervalValueLabel)
                                .foregroundColor(Theme.textMuted)
                        }
                        Slider(value: $intervalSeconds, in: 0...60, step: 5) { editing in
                            intervalDragging = editing
                            if !editing { commitInterval() }
                        }
                        .tint(Theme.branchIndicator)
                    }
                    .disabled(minSpeakIntervalMs == nil)
                } footer: {
                    Text(intervalFooter)
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)

                #if os(iOS)
                Section {
                    GroupColorSwatchRow(title: "背景", options: GroupRoomStyle.backgrounds,
                                        selection: $groupBackground.storedHex, fallback: GroupRoomStyle.background(nil))
                    GroupColorSwatchRow(title: "对方气泡", options: GroupRoomStyle.others,
                                        selection: $groupOthers.storedHex, fallback: GroupRoomStyle.othersColor(nil))
                    GroupColorSwatchRow(title: "我的气泡", options: GroupRoomStyle.mine,
                                        selection: $groupMine.storedHex, fallback: GroupRoomStyle.mineColor(nil))
                } header: {
                    Text("聊天外观")
                } footer: {
                    Text("所有群聊的背景和气泡颜色。某个群想单独换，在那个群的「编辑群聊 › 聊天外观」里改。")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
                .listRowBackground(Theme.mainBg)
                .listRowSeparator(.hidden)
                #endif
            }

            Section {
                HStack {
                    Text("桥连接")
                    Spacer()
                    Text(bridgeConnected ? "已连接" : "未连接")
                        .foregroundColor(bridgeConnected ? Theme.branchIndicator : Theme.textMuted)
                }
            } footer: {
                Text("群聊经 CC 桥通信，与 Claude Code / Codex 共用同一条连接和配对。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
            .listRowSeparator(.hidden)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("群聊")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { bridgeConnected = CCBridgeWebSocketClient.shared.isConnected }
        .task {
            guard agoraEnabled else { return }
            speechClient.eventHandler = { event in
                guard case .settings(let updated) = event.data else { return }
                speechMode = updated.speechMode
                minSpeakIntervalMs = updated.minSpeakIntervalMs
                if !intervalDragging {
                    intervalSeconds = Double(updated.minSpeakIntervalMs / 1000)
                }
            }
            do {
                try await speechClient.connect()
                let settings = try await speechClient.getSettings()
                speechMode = settings.speechMode
                minSpeakIntervalMs = settings.minSpeakIntervalMs
                intervalSeconds = Double(settings.minSpeakIntervalMs / 1000)
                speechModeError = false
            } catch {
                speechModeError = true
            }
        }
        .onDisappear { speechClient.disconnect() }
    }

    private var speechModeBinding: Binding<AgoraSpeechMode> {
        Binding(
            get: { speechMode ?? .mentionOnly },
            set: { newMode in
                let previous = speechMode
                speechMode = newMode
                Task {
                    do {
                        _ = try await speechClient.setSpeechMode(newMode)
                        speechModeError = false
                    } catch {
                        speechMode = previous
                        speechModeError = true
                    }
                }
            }
        )
    }

    private var intervalValueLabel: String {
        let seconds = Int(intervalSeconds)
        return seconds == 0 ? "不限" : "\(seconds) 秒"
    }

    private var intervalFooter: String {
        if intervalError { return "保存发言节奏失败，检查桥连接后重试。" }
        let seconds = Int(intervalSeconds)
        if seconds == 0 { return "不限制 AI 发言频率。" }
        return "每 \(seconds) 秒最多一条 AI 发言（你直接 @ 的回复不受限）。"
    }

    private func commitInterval() {
        let ms = Int(intervalSeconds) * 1000
        guard ms != minSpeakIntervalMs else { return }
        Task {
            do {
                let updated = try await speechClient.setMinSpeakInterval(ms: ms)
                minSpeakIntervalMs = updated.minSpeakIntervalMs
                intervalError = false
            } catch {
                intervalSeconds = Double((minSpeakIntervalMs ?? 0) / 1000)
                intervalError = true
            }
        }
    }

    private var speechModeFooter: String {
        if speechModeError { return "读取/保存发言模式失败，检查桥连接后重进本页。" }
        switch speechMode {
        case .relay:
            return "成员回复里 @ 到谁，谁会接着发言（链条有深度上限，你发言即打断排队中的接力）。"
        case .free:
            return "有新消息时所有成员都会看到，自行决定插话或沉默；@ 到谁谁必答。"
        case .roundRobin:
            return "按进房顺序轮流发言，每人一条可跳过，一圈说完等你开口。你 @ 到谁谁必答。"
        default:
            return "只有你 @ 到的成员会发言。"
        }
    }
}
