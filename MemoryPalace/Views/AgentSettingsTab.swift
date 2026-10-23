import SwiftUI

/// 设置 · Agent（AUTONOMY Phase 1，N-D14）：总开关/楼层开关（默认全关 = D6）+ 预算（D4）+ 活动 log。
/// macOS：直读/写 agent/config.json（与 hub 同目录）。
/// iOS（R5）：沙盒读不到 Mac 文件（N-D9）——经 cc-bridge WS 拉快照 / 发配置补丁。
/// 一份 body 两端共用（plan-settings-merge 刀 2）：容器走 `SettingsSectionList(.list)`，字号走 `settingsMetrics`；
/// 剩下的 `#if` 全是数据来源 / 生命周期（mac 载入遮罩 vs iOS WS 订阅、`persistConfig` 守卫）与系统能力。
struct AgentSettingsTab: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    #if os(macOS)
    @State private var config = AgentBridge.HubConfig()
    @State private var configLoaded = false
    #else
    @State private var config = AgentBridge.loadConfig()
    #endif
    // 作息感知全局开关（09-11 粟粟拍板：全局一个，不按楼层；时区在楼层编辑页填）
    @AppStorage("timeAwareness.enabled") private var timeAwarenessEnabled = false
    @State private var activity: [AgentBridge.ActivityEntry] = []
    @State private var spentUSD: Double?
    #if os(iOS)
    @State private var wsLoaded = false
    #endif

    var body: some View {
        SettingsSectionList(.list) {
            Section {
                Toggle("作息感知（问候/作息按角色时区）", isOn: $timeAwarenessEnabled)
                    .tint(Theme.branchIndicator)
                Toggle("启用自主任务", isOn: bindingEnabled)
                    .tint(Theme.branchIndicator)
            } footer: {
                #if os(iOS)
                Text(wsLoaded
                     ? "开启后，Mac 端会按触发器在后台执行任务；产出会作为普通消息进入对应楼层的对话。"
                     : "数据来自 Mac（cc-bridge 连接后同步；当前未收到数据，改动可能不生效）。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                #else
                Text("开启后，Mac 端会按触发器在后台执行任务；产出会作为普通消息进入对应楼层的对话。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                #endif
            }

            Section {
                if let profiles = profileManager?.profiles, !profiles.isEmpty {
                    ForEach(profiles, id: \.id) { profile in
                        Toggle("\(profile.emoji) \(profile.name)", isOn: bindingFloor(profile.id))
                            .tint(Theme.branchIndicator)
                    }
                } else {
                    Text("暂无楼层")
                        .foregroundColor(Theme.textMuted)
                }
            } header: {
                Text("楼层")
            } footer: {
                Text("每层楼独立开启，关闭的楼层不会执行任何自主任务。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }

            Section {
                if let profiles = profileManager?.profiles, !profiles.isEmpty {
                    ForEach(profiles, id: \.id) { profile in
                        Toggle("\(profile.emoji) \(profile.name)", isOn: bindingFloor(profile.id))
                            .tint(Theme.branchIndicator)
                    }
                } else {
                    Text("暂无楼层")
                        .foregroundColor(Theme.textMuted)
                }
            } header: {
                Text("楼层")
            } footer: {
                Text("每层楼独立开启，关闭的楼层不会执行任何自主任务。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }

            Section {
                Toggle("Agent 自主共读", isOn: bindingCoReadDaemon)
                    .tint(Theme.branchIndicator)
                Toggle("CC 共读", isOn: bindingCoReadCC)
                    .tint(Theme.branchIndicator)
                Toggle("单词在场", isOn: bindingCoReadVocab)
                    .tint(Theme.branchIndicator)
            } header: {
                Text("共读批注")
            } footer: {
                Text("前两项开启后，对应一方可以在你读的书页边写批注：Agent 按时段自主共读，CC 在对话中写批注。「单词在场」开启后，会把单词学习状态（今天刷了什么词、复习情况、错词）上报给 Mac 端 Agent / CC。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }

            Section {
                HStack {
                    Text("每日预算上限")
                    Spacer()
                    Text("$")
                        .foregroundColor(Theme.textMuted)
                    TextField("0.50", value: bindingBudget, format: .number.precision(.fractionLength(2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
                HStack {
                    Text("今日用量")
                    Spacer()
                    Text(spentUSD.map { String(format: "$%.4f", $0) } ?? "—")
                        .foregroundColor(Theme.textMuted)
                }
                if let until = config.pausedUntil, until > Date() {
                    Button("恢复运行（已暂停至 \(until.formatted(date: .omitted, time: .shortened))）") {
                        config.pausedUntil = nil
                        persistConfig()
                    }
                    .foregroundColor(Theme.branchIndicator)
                } else {
                    Button("暂停 24 小时") {
                        config.pausedUntil = Date().addingTimeInterval(24 * 3600)
                        persistConfig()
                    }
                    .foregroundColor(Theme.textSecondary)
                }
            } header: {
                Text("预算")
            }

            Section {
                if activity.isEmpty {
                    Text("暂无活动")
                        .foregroundColor(Theme.textMuted)
                        .font(m.caption)
                } else {
                    ForEach(activity) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(statusMark(entry.status))
                                Text(entry.triggerId)
                                    .font(m.secondary.weight(.medium))
                                Spacer()
                                Text(entry.ts)
                                    .font(m.caption)
                                    .foregroundColor(Theme.textMuted)
                            }
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(m.caption)
                                    .foregroundColor(Theme.textMuted)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            } header: {
                Text("最近活动")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .opacity(configLoaded ? 1 : 0)
        .overlay {
            if !configLoaded { ProgressView("读取 Agent 设置").controlSize(.small) }
        }
        .disabled(!configLoaded)
        .task {
            configLoaded = false
            let work = Task.detached(priority: .utility) { try Self.readSnapshot() }
            do {
                let snapshot = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: { work.cancel() }
                try Task.checkCancellation()
                config = snapshot.0
                activity = snapshot.1
                spentUSD = snapshot.2
                configLoaded = true
            } catch { }
        }
        #else
        .onAppear {
            CCBridgeWebSocketClient.shared.onAgentStatusResult = { payload in
                applyStatusPayload(payload)
            }
            CCBridgeWebSocketClient.shared.send(["type": "agent_status"]) { _ in }
        }
        #endif
        #if os(iOS)
        .onDisappear {
            CCBridgeWebSocketClient.shared.onAgentStatusResult = nil
        }
        #endif
    }

    #if os(macOS)
    private nonisolated static func readSnapshot() throws -> (AgentBridge.HubConfig, [AgentBridge.ActivityEntry], Double?) {
        try Task.checkCancellation()
        let config = AgentBridge.loadConfig()
        try Task.checkCancellation()
        let activity = AgentBridge.recentActivity()
        try Task.checkCancellation()
        let spent = AgentBridge.todaySpentUSD()
        try Task.checkCancellation()
        return (config, activity, spent)
    }
    #endif

    #if os(iOS)
    /// hub 快照 → 本页状态（拉取和写配置后 hub 都回它）
    private func applyStatusPayload(_ payload: [String: Any]) {
        if let c = payload["config"] as? [String: Any] {
            config.enabled = c["enabled"] as? Bool ?? false
            config.floors = c["floors"] as? [String: Bool] ?? [:]
            config.dailyBudgetUSD = c["dailyBudgetUSD"] as? Double ?? 0.5
            if let cr = c["coRead"] as? [String: Any] {
                config.coRead = AgentBridge.CoRead(daemon: cr["daemon"] as? Bool == true, cc: cr["cc"] as? Bool == true, vocab: cr["vocab"] as? Bool == true)
            } else {
                config.coRead = nil
            }
            if let p = c["pausedUntil"] as? String {
                config.pausedUntil = ISO8601DateFormatter().date(from: p)
            } else {
                config.pausedUntil = nil
            }
        }
        spentUSD = payload["spentUSD"] as? Double
        if let acts = payload["activity"] as? [[String: Any]] {
            activity = acts.map { obj in
                AgentBridge.ActivityEntry(
                    ts: String((obj["ts"] as? String ?? "").prefix(16)).replacingOccurrences(of: "T", with: " "),
                    triggerId: obj["triggerId"] as? String ?? "?",
                    status: obj["status"] as? String ?? "?",
                    detail: (obj["preview"] as? String) ?? (obj["echo"] as? String) ?? (obj["error"] as? String) ?? ""
                )
            }
        }
        wsLoaded = true
    }

    /// iOS 写配置：发补丁给 hub（读-改-写保未知键在 hub 侧），hub 回快照刷新本页
    private func sendConfigPatch() {
        var patch: [String: Any] = [
            "enabled": config.enabled,
            "floors": config.floors,
            "dailyBudgetUSD": config.dailyBudgetUSD,
        ]
        if let coRead = config.coRead {
            patch["coRead"] = ["daemon": coRead.daemon, "cc": coRead.cc, "vocab": coRead.vocab]
        }
        if let until = config.pausedUntil {
            patch["pausedUntil"] = ISO8601DateFormatter().string(from: until)
        } else {
            patch["pausedUntil"] = NSNull() as Any
        }
        CCBridgeWebSocketClient.shared.send(["type": "agent_config_set", "patch": patch]) { _ in }
    }
    #endif

    /// 配置变更落地：macOS 直写文件；iOS 发 WS 补丁
    private func persistConfig() {
        #if os(iOS)
        // 快照没到就发补丁 = 拿本地默认值（enabled=false 等）盖掉 Mac 真实配置——
        // 07-16 总开关被静默关停两天的事故根因。快照未达时开关动作不落地（footer 已有提示）。
        guard wsLoaded else { return }
        sendConfigPatch()
        #else
        guard configLoaded else { return }
        AgentBridge.saveConfig(config)
        #endif
    }

    private var bindingEnabled: Binding<Bool> {
        Binding(get: { config.enabled }, set: {
            config.enabled = $0
            persistConfig()
        })
    }

    private func bindingFloor(_ id: String) -> Binding<Bool> {
        Binding(get: { config.floors[id] == true }, set: {
            config.floors[id] = $0
            persistConfig()
        })
    }

    private var bindingBudget: Binding<Double> {
        Binding(get: { config.dailyBudgetUSD }, set: {
            config.dailyBudgetUSD = max(0, $0)
            persistConfig()
        })
    }

    private var bindingCoReadDaemon: Binding<Bool> {
        Binding(get: { config.coRead?.daemon == true }, set: {
            var c = config.coRead ?? AgentBridge.CoRead()
            c.daemon = $0
            config.coRead = c
            persistConfig()
        })
    }

    private var bindingCoReadCC: Binding<Bool> {
        Binding(get: { config.coRead?.cc == true }, set: {
            var c = config.coRead ?? AgentBridge.CoRead()
            c.cc = $0
            config.coRead = c
            persistConfig()
        })
    }

    private var bindingCoReadVocab: Binding<Bool> {
        Binding(get: { config.coRead?.vocab == true }, set: {
            var c = config.coRead ?? AgentBridge.CoRead()
            c.vocab = $0
            config.coRead = c
            persistConfig()
        })
    }

    private func statusMark(_ status: String) -> String {
        switch status {
        case "ok": return "✓"
        case "error": return "✗"
        default: return "–"   // skipped-*
        }
    }
}
