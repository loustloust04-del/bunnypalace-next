import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
import AVFoundation
import Photos
import UserNotifications
import EventKit

// MARK: - 档位控件（权限页与原 tab 共用同一 descriptor 渲染，两处天然同步）

/// 三档下拉（Minis 式）。写入走 PermissionCenter.setLevel（唯一合法入口，同步旧 key 投影 + 单例缓存）。
struct PermissionLevelPicker: View {
    let domain: PermissionDomain
    /// 隐藏 askOnce 的域（P1 取舍：memory/voiceProactive 两档，见 plan §2）
    var twoLevelsOnly: Bool = false
    @State private var level: PermissionLevel = .notAllowed

    var body: some View {
        Picker("", selection: $level) {
            ForEach(PermissionLevel.allCases.filter { !(twoLevelsOnly && $0 == .askOnce) }) { l in
                Label(l.displayName, systemImage: l.iconName).tag(l)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(Theme.textSecondary)
        .onAppear { level = PermissionCenter.level(domain) }
        .onChange(of: level) { _, new in
            if PermissionCenter.level(domain) != new { PermissionCenter.setLevel(new, for: domain) }
        }
    }
}

/// 权限页/子页里的一行：图标 + 域名 + 一句话说明 + 档位下拉。
struct PermissionDomainRow: View {
    let domain: PermissionDomain
    var twoLevelsOnly: Bool = false
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.displayName)
                    .font(m.body)
                Text(domain.summary)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PermissionLevelPicker(domain: domain, twoLevelsOnly: twoLevelsOnly)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 权限页

/// 设置 · 权限（plan-权限管理 §3）：AI 能看什么 / AI 能做什么 / 系统权限。
/// 引用层：行与原 tab 读写同一真相源（PermissionCenter），原 tab 的行由 T7 换成同款控件。
/// 一份 body 两端共用（plan-settings-merge 刀 1）：容器走 `SettingsSectionList`，字号走 `settingsMetrics`，
/// 二级页走 `SettingsNavRow`；只剩 iOS 独有的「本地模式」节与系统权限三行是平台例外。
struct PermissionsSettingsTab: View {
    @State private var sysStatus = SystemPermissionStatus()
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage(LocalMode.key) private var localModeEnabled = true
    @State private var secrets: [SecretVault.Entry] = []
    @State private var secretConversationTitles: [String: String] = [:]

    var body: some View {
        // 搜索锚点：命中某个权限域时滚到那一行
        ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            // 本地模式两端都在这页（合流刀 0.5a · A3 跟 iOS；mac 原来在通用页顶的裸卡已撤）
            Section {
                Toggle(isOn: $localModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地模式")
                        Text("网页预览等 Web 功能严格禁止联网；AI 对话与 Claude Code 不受影响")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                .tint(Theme.branchIndicator)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                SettingsNavRow(.healthPermissions) {
                    HealthPermissionSubpage()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("健康")
                        Text("苹果健康、体重、用药、月经、亲密五个子域")
                            .font(m.caption)
                            .foregroundColor(Theme.textMuted)
                    }
                }
                #if PERSONAL_APPS
                PermissionDomainRow(domain: .trading)
                    .searchAnchor("leaf-perm-trading")
                #endif
                PermissionDomainRow(domain: .memory, twoLevelsOnly: true)
                    .searchAnchor("leaf-perm-memory")
                PermissionDomainRow(domain: .images)
                    .searchAnchor("leaf-perm-images")
                PermissionDomainRow(domain: .fileLibrary)
                    .searchAnchor("leaf-perm-fileLibrary")
                #if PERSONAL_APPS
                #if DEBUG
                PermissionDomainRow(domain: .topicBox)
                    .searchAnchor("leaf-perm-topicBox")
                #endif
                #endif
                #if os(macOS)
                PermissionDomainRow(domain: .codingSessions)
                    .searchAnchor("leaf-perm-codingSessions")
                #endif
            } header: {
                Text("AI 能看什么")
            } footer: {
                Text("「每次询问」= 每个对话第一次用到时弹卡问一次；「不允许」= 不注入、工具调用会收到拒绝并可引导你来这里。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            Section {
                PermissionDomainRow(domain: .toolsMaster)
                    .searchAnchor("leaf-perm-toolsMaster")
                PermissionDomainRow(domain: .webSearch)
                    .searchAnchor("leaf-perm-webSearch")
                PermissionDomainRow(domain: .voiceProactive, twoLevelsOnly: true)
                    .searchAnchor("leaf-perm-voiceProactive")
                PermissionDomainRow(domain: .pocket, twoLevelsOnly: true)   // pocket_cmd 在 WS handler，askOnce 弹卡挂 P2
                    .searchAnchor("leaf-perm-pocket")
                PermissionDomainRow(domain: .calendar)
                    .searchAnchor("leaf-perm-calendar")
                PermissionDomainRow(domain: .reminders)
                    .searchAnchor("leaf-perm-reminders")
                PermissionDomainRow(domain: .clipboard)
                    .searchAnchor("leaf-perm-clipboard")
                PermissionDomainRow(domain: .shell)   // 两端都有 run_command（iOS = app 内沙箱）
                    .searchAnchor("leaf-perm-shell")
                PermissionDomainRow(domain: .twitter)   // local_twitter：本楼层推特，纯本地
                    .searchAnchor("leaf-perm-twitter")
            } header: {
                Text("AI 能做什么")
            }
            .listRowBackground(Theme.mainBg)

            autonomySection
            systemSection
            secretsSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
        .navigationTitle("权限")
        .settingsAnchorScroll(anchorProxy)
        .task { await sysStatus.refresh() }
        .onAppear { reloadSecrets() }
        }
    }

    /// 自主行为类：二值域。nudge/夜跑/agora 真适配器行；Agent/共读的写路径归设置-Agent（WS 快照守卫在那边），这里状态+跳转。
    @ViewBuilder private var autonomySection: some View {
        Section {
            AutonomyToggleRow(title: "主动找我", caption: "空闲时 Claude Code 会主动发消息",
                              key: "ccNudgeEnabled", defaultValue: false) {
                CCBridgeWebSocketClient.shared.sendCCConfig()
            }
            #if PERSONAL_APPS
            AutonomyToggleRow(title: "交易夜跑", caption: "每晚自动跑关注标的的研究",
                              key: TradingStore.nightlyEnabledKey, defaultValue: false) {
                if let pid = profileManager?.currentProfile.id {
                    TradingStore.reportWatchlist(context: modelContext, profileId: pid)
                }
            }
            #endif
            AutonomyToggleRow(title: "群聊（中庭）", caption: "开启群聊房间，改动后重启生效",
                              key: AgoraFeatureGate.key, defaultValue: false, sideEffect: nil)
            PermissionDomainRow(domain: .notifications, twoLevelsOnly: true)
                .searchAnchor("leaf-perm-notifications")
        } header: {
            Text("AI 自主行为")
        } footer: {
            Text("自主任务（含预算）与共读三项的开关在 设置→Agent。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
    }

    @ViewBuilder private var systemSection: some View {
        Section {
            SystemPermissionRow(name: "通知", status: sysStatus.notifications)
            SystemPermissionRow(name: "麦克风", status: sysStatus.microphone)
            SystemPermissionRow(name: "相机", status: sysStatus.camera)
            SystemPermissionRow(name: "照片", status: sysStatus.photos)
            SystemPermissionRow(name: "日历", status: SystemPermissionStatus.describe(EKEventStore.authorizationStatus(for: .event)))
            SystemPermissionRow(name: "提醒事项", status: SystemPermissionStatus.describe(EKEventStore.authorizationStatus(for: .reminder)))
            #if os(iOS)
            SystemPermissionRow(name: "苹果健康", status: HealthService.shared.authRequested ? "已请求" : "未请求")
            SystemPermissionRow(name: "本地网络", status: "由系统管理")
            SystemPermissionRow(name: "运动传感器", status: "由系统管理")
            #endif
            Button {
                openSystemSettings()
            } label: {
                Text("前往系统设置")
                    .font(m.body)
            }
        } header: {
            Text("系统权限")
        } footer: {
            Text("状态由系统记录，修改请前往系统设置。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
    }

    /// 加密值（plan-secure-ask §5）：只列、只删，不能看真值
    @ViewBuilder private var secretsSection: some View {
        Section {
            if secrets.isEmpty {
                Text("还没有加密值")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .searchAnchor("leaf-perm-secrets")
            } else {
                ForEach(secrets) { entry in
                    secretRow(entry)
                        .searchAnchor(entry.id == secrets.first?.id ? "leaf-perm-secrets" : "secret-\(entry.id)")
                }
            }
        } header: {
            Text("加密值")
        } footer: {
            Text("提问卡里加密填的值存在钥匙串，AI 只拿到占位，用到时每次问你。这里只能删、不能看；删对话时只属于它的一起删。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .listRowBackground(Theme.mainBg)
    }

    private func secretRow(_ entry: SecretVault.Entry) -> some View {
        let scope = entry.conversationId.map { "仅「\(secretConversationTitles[$0] ?? "已删除的对话")」" } ?? "所有对话"
        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.label.isEmpty ? entry.id : entry.label)
                .font(m.body)
            Text([scope, entry.synced ? "iCloud" : "仅本机", entry.created.formatted(date: .abbreviated, time: .shortened)].joined(separator: " · "))
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteSecret(entry) } label: { Label("删除", systemImage: "trash") }
        }
        .contextMenu {
            Button(role: .destructive) { deleteSecret(entry) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func deleteSecret(_ entry: SecretVault.Entry) {
        SecretVault.delete(entry.id)
        reloadSecrets()
    }

    private func reloadSecrets() {
        secrets = SecretVault.list()
        var titles: [String: String] = [:]
        for cid in Set(secrets.compactMap(\.conversationId)) {
            var d = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == cid })
            d.fetchLimit = 1
            if let conv = try? modelContext.fetch(d).first { titles[cid] = conv.title }
        }
        secretConversationTitles = titles
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}

/// 健康子页：五子域各一行（iOS 二级页；mac 走 `SettingsRoute.healthPermissions` → `MacHealthPermissionPage`）。
struct HealthPermissionSubpage: View {
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        List {
            Section {
                PermissionDomainRow(domain: .healthApple)
                PermissionDomainRow(domain: .healthWeight)
                PermissionDomainRow(domain: .healthMeds)
                PermissionDomainRow(domain: .healthCycle)
                PermissionDomainRow(domain: .healthIntimacy)
            } footer: {
                Text("与 设置→健康 里的开关是同一个值，两边改都一样。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
        .navigationTitle("健康")
    }
}

// MARK: - 自主行为行（真适配器：写 key + 触发副作用）

private struct AutonomyToggleRow: View {
    let title: String
    let caption: String
    let key: String
    let defaultValue: Bool
    var sideEffect: (() -> Void)?
    @State private var isOn = false
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(m.body)
                Text(caption).font(m.caption).foregroundColor(Theme.textMuted)
            }
        }
        .tint(Theme.branchIndicator)
        .onAppear { isOn = UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue }
        .onChange(of: isOn) { _, new in
            let cur = UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
            guard cur != new else { return }
            UserDefaults.standard.set(new, forKey: key)
            sideEffect?()
        }
    }
}

// MARK: - 系统权限状态

private struct SystemPermissionRow: View {
    let name: String
    let status: String
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        HStack {
            Text(name).font(m.body)
            Spacer()
            Text(status).font(m.caption).foregroundColor(Theme.textMuted)
        }
    }
}

@Observable
private final class SystemPermissionStatus {
    var notifications = "…"
    var microphone = "…"
    var camera = "…"
    var photos = "…"

    @MainActor
    func refresh() async {
        let ns = await UNUserNotificationCenter.current().notificationSettings()
        notifications = Self.describe(ns.authorizationStatus)
        #if os(iOS)
        microphone = Self.describe(AVAudioApplication.shared.recordPermission)
        #else
        microphone = Self.describe(AVCaptureDevice.authorizationStatus(for: .audio))
        #endif
        camera = Self.describe(AVCaptureDevice.authorizationStatus(for: .video))
        photos = Self.describe(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private static func describe(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized, .provisional, .ephemeral: return "已允许"
        case .denied: return "已拒绝"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }
    private static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "已允许"
        case .denied, .restricted: return "已拒绝"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }
    #if os(iOS)
    private static func describe(_ s: AVAudioApplication.recordPermission) -> String {
        switch s {
        case .granted: return "已允许"
        case .denied: return "已拒绝"
        case .undetermined: return "未请求"
        @unknown default: return "未知"
        }
    }
    #endif
    static func describe(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .fullAccess: return "已允许"
        case .writeOnly: return "仅写入"
        case .denied, .restricted: return "已拒绝"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }
    private static func describe(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .authorized, .limited: return "已允许"
        case .denied, .restricted: return "已拒绝"
        case .notDetermined: return "未请求"
        @unknown default: return "未知"
        }
    }
}
