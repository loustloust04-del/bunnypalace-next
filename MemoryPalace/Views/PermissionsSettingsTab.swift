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

/// 档位控件改谁（atrium P3⑤a）：`.defaults` =「我 › 权限」里的默认；`.floor` = 这个人单独设的（只全局的域不该出现在 `.floor`）
enum PermissionTarget: Equatable {
    case defaults
    case floor(String)

    var profileId: String? {
        if case .floor(let id) = self { return id }
        return nil
    }
}

/// 三档下拉（Minis 式）。默认写 `PermissionCenter.setDefaultLevel`（同步旧 key 投影 + 单例缓存）；这个人写 `setFloorLevel`。
/// `perm.*` / `perm.floors.v1` 都在 UserDefaults 里，变了跟着重读（同抽屉页）
struct PermissionLevelPicker: View {
    let domain: PermissionDomain
    /// 隐藏 askOnce 的域（P1 取舍：memory/voiceProactive 两档，见 plan §2）
    var twoLevelsOnly: Bool = false
    var target: PermissionTarget = .defaults
    @State private var tick = 0

    enum Choice: Hashable {
        /// 这个人没单独设，跟着默认
        case follow
        case level(PermissionLevel)
    }

    struct Option: Identifiable, Equatable {
        let choice: Choice
        let title: String
        let icon: String
        var id: Choice { choice }
    }

    static func followTitle(_ defaultLevel: PermissionLevel) -> String {
        "跟随默认 · \(defaultLevel.displayName)"
    }

    /// 下拉里有哪几项（纯函数，单测锁）：默认 = 档位；这个人 =「跟随默认」+ 档位，只能更严的域只列比默认严的，只全局的域没有
    static func options(domain: PermissionDomain, target: PermissionTarget, defaultLevel: PermissionLevel,
                        twoLevelsOnly: Bool = false) -> [Option] {
        let levels = PermissionLevel.allCases.filter { !(twoLevelsOnly && $0 == .askOnce) }
        let levelOptions = { (ls: [PermissionLevel]) in ls.map { Option(choice: .level($0), title: $0.displayName, icon: $0.iconName) } }
        guard target != .defaults else { return levelOptions(levels) }
        let follow = Option(choice: .follow, title: followTitle(defaultLevel), icon: "arrow.uturn.backward")
        switch domain.floorRule {
        case .globalOnly: return []
        case .stricterOnly: return [follow] + levelOptions(levels.filter { $0.rawValue > defaultLevel.rawValue })
        case .free: return [follow] + levelOptions(levels)
        }
    }

    /// 现在选中哪项。只能更严的域：层上存着但默认已经一样严或更严 → 生效的是默认，显示「跟随」（层值留着，plan §6-7）
    static func currentChoice(domain: PermissionDomain, target: PermissionTarget, defaultLevel: PermissionLevel) -> Choice {
        guard let profileId = target.profileId else { return .level(defaultLevel) }
        guard let stored = PermissionCenter.floors().stored(domain, profileId: profileId) else { return .follow }
        if domain.floorRule == .stricterOnly, stored.rawValue <= defaultLevel.rawValue { return .follow }
        return .level(stored)
    }

    /// 这个人被「主屏上没装」挡住时显示的值（atrium P3⑥a §3.3），代替下拉；默认目标不受门影响
    static func blockedTitle(domain: PermissionDomain, target: PermissionTarget) -> String? {
        guard let profileId = target.profileId,
              let app = PermissionCenter.blockingApp(domain, profileId: profileId) else { return nil }
        return "\(PermissionLevel.notAllowed.displayName) · \(PermissionCenter.notInstalledLabel(app))"
    }

    var body: some View {
        let _ = tick
        if let blocked = Self.blockedTitle(domain: domain, target: target) {
            Text(blocked)
                .font(.caption)
                .foregroundColor(Theme.textMuted)
                .multilineTextAlignment(.trailing)
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
                    tick += 1
                }
        } else {
            picker
        }
    }

    @ViewBuilder private var picker: some View {
        let def = PermissionCenter.defaultLevel(domain)
        let current = Self.currentChoice(domain: domain, target: target, defaultLevel: def)
        let options = Self.options(domain: domain, target: target, defaultLevel: def, twoLevelsOnly: twoLevelsOnly)
        // 存着两档域不给的档（老数据）也照样显示，不让下拉落空
        let shown: [Option] = {
            guard case .level(let l) = current, !options.contains(where: { $0.choice == current }) else { return options }
            return options + [Option(choice: current, title: l.displayName, icon: l.iconName)]
        }()
        let wider: Bool = {
            guard target != .defaults, case .level(let l) = current else { return false }
            return l.rawValue < def.rawValue
        }()
        HStack(spacing: 6) {
            if wider {
                Text("比默认宽")
                    .font(.caption2)
                    .foregroundColor(Theme.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().stroke(Theme.textMuted.opacity(0.5), lineWidth: 0.5))
                    .fixedSize()
            }
            Picker("", selection: Binding(get: { current }, set: { write($0) })) {
                ForEach(shown) { o in
                    Label(o.title, systemImage: o.icon).tag(o.choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(current == .follow ? Theme.textMuted : Theme.textSecondary)
        }
        .onAppear {
            assert(target == .defaults || domain.floorRule != .globalOnly, "\(domain.rawValue) 只在默认里改，不该出现在这个人的表里")
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            tick += 1
        }
    }

    private func write(_ choice: Choice) {
        switch (target, choice) {
        case (.defaults, .level(let l)):
            if PermissionCenter.defaultLevel(domain) != l { PermissionCenter.setDefaultLevel(l, for: domain) }
        case (.defaults, .follow):
            break
        case (.floor(let pid), .follow):
            PermissionCenter.setFloorLevel(nil, for: domain, profileId: pid)
        case (.floor(let pid), .level(let l)):
            PermissionCenter.setFloorLevel(l, for: domain, profileId: pid)
        }
        tick += 1
    }
}

/// 权限页/子页里的一行：图标 + 域名 + 一句话说明 + 档位下拉。
/// 默认目标下多一行「N 个人单独设了」（点开看是谁）；这个人的表里只全局的域灰掉写「只在默认里改」
struct PermissionDomainRow: View {
    let domain: PermissionDomain
    var twoLevelsOnly: Bool = false
    var target: PermissionTarget = .defaults
    @Environment(\.settingsMetrics) private var m
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    #if os(macOS)
    @Environment(\.settingsRoutePush) private var routePush
    #endif
    @State private var showOverrides = false
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let lockedOnFloor = target != .defaults && domain.floorRule == .globalOnly
        let overrideCount = target == .defaults && domain.floorRule != .globalOnly
            ? PermissionOverridesPage.entries(domain, profiles: profileManager?.profiles ?? []).count : 0
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.displayName)
                    .font(m.body)
                Text(domain.summary)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if overrideCount > 0 {
                    Button("\(overrideCount) 个人单独设了 ›") { openOverrides() }
                        .buttonStyle(.borderless)
                        .font(m.caption)
                        .foregroundColor(Theme.branchIndicator)
                }
                if lockedOnFloor {
                    Text("所有人共用，只在默认里改")
                        .font(m.caption)
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer(minLength: 8)
            if lockedOnFloor {
                Text(PermissionCenter.defaultLevel(domain).displayName)
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            } else {
                PermissionLevelPicker(domain: domain, twoLevelsOnly: twoLevelsOnly, target: target)
            }
        }
        .padding(.vertical, 2)
        .opacity(lockedOnFloor ? 0.55 : 1)
        .sheet(isPresented: $showOverrides) {
            NavigationStack {
                PermissionOverridesPage(domain: domain)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showOverrides = false }
                        }
                    }
            }
            .environment(profileManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            if target == .defaults { tick += 1 }
        }
    }

    private func openOverrides() {
        #if os(macOS)
        // mac 设置窗的 path 只存 SettingsRoute（不带域），先记下是哪个域
        if let routePush {
            PermissionOverridesSelection.shared.domain = domain
            routePush(.permissionOverrides)
            return
        }
        #endif
        showOverrides = true
    }
}

/// 「我 › 权限」某一行「N 个人单独设了」点开：谁单独设了、各自什么档 +〔都回到跟默认〕（atrium P3⑤a §3.3）
struct PermissionOverridesPage: View {
    let domain: PermissionDomain
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @State private var tick = 0
    @State private var confirmClear = false

    /// 只数还在的楼层（删过的层残留的设置不算，plan §3.3）
    static func entries(_ domain: PermissionDomain, profiles: [Profile]) -> [(profile: Profile, level: PermissionLevel)] {
        let stored = PermissionCenter.overrides(domain)
        return profiles.compactMap { p in stored[p.id].map { (p, $0) } }
    }

    var body: some View {
        let _ = tick
        let rows = Self.entries(domain, profiles: profileManager?.profiles ?? [])
        SettingsSectionList(.list) {
            Section {
                if rows.isEmpty {
                    Text("没有人单独设，都跟着默认")
                        .font(m.body)
                        .foregroundColor(Theme.textMuted)
                } else {
                    ForEach(rows, id: \.profile.id) { row in
                        HStack {
                            Text("\(row.profile.emoji) \(row.profile.name)")
                                .font(m.body)
                            Spacer()
                            Text(row.level.displayName)
                                .font(m.caption)
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
            } footer: {
                Text("默认现在是「\(PermissionCenter.defaultLevel(domain).displayName)」。这些人用自己单独设的，改默认不影响他们。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            if !rows.isEmpty {
                Section {
                    Button("都回到跟默认") { confirmClear = true }
                        .font(m.body)
                        .foregroundColor(Theme.textSecondary)
                        .settingsActionButton()
                }
                .listRowBackground(Theme.mainBg)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
        .navigationTitle(domain.displayName)
        .confirmationDialog("「\(domain.displayName)」所有人都回到跟默认？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("都回到跟默认", role: .destructive) {
                PermissionCenter.clearFloor(domain)
                tick += 1
            }
            Button("取消", role: .cancel) {}
        }
    }
}

/// mac 设置窗：`SettingsRoute.permissionOverrides` 打开的是哪个域
@MainActor
@Observable
final class PermissionOverridesSelection {
    static let shared = PermissionOverridesSelection()
    var domain: PermissionDomain?
}

/// 别的设置页里的档位（联网搜索 / 文件库 / 话题盒 / 图片 / 健康 / 交易 / 主动语音）：只显示这个人现在生效的值，
/// 点进去改这个人的（atrium P3⑤a §3.4）。iOS 推入同一份 `PersonPermissionSections`；mac 推入权限页并切到「这一层」。
/// 改默认只剩「我 › 权限」一个入口
struct PermissionLevelReadout: View {
    let domain: PermissionDomain
    /// 不在 List 里（卡片）时没有系统箭头，自己画一个
    var showsChevron = false
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @State private var tick = 0

    /// `blockingApp`：被「主屏上没装」挡住时带上原因（atrium P3⑥a）
    static func text(name: String, level: PermissionLevel, blockingApp: String? = nil) -> String {
        guard let blockingApp else { return "\(name)：\(level.displayName)" }
        return "\(name)：\(level.displayName) · \(PermissionCenter.notInstalledLabel(blockingApp))"
    }

    var body: some View {
        let _ = tick
        let profile = profileManager?.currentProfile
        SettingsNavRow(.floorPermissions) {
            #if os(iOS)
            PersonPermissionsPage(profileId: profile?.id ?? "")
            #else
            PermissionsSettingsTab(startsOnFloor: true)
            #endif
        } label: {
            HStack(spacing: 4) {
                Text(Self.text(name: profile?.name ?? "", level: PermissionCenter.level(domain, profileId: profile?.id),
                               blockingApp: PermissionCenter.blockingApp(domain, profileId: profile?.id)))
                    .font(.system(size: Theme.F.secondary))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                #if os(iOS)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Theme.F.caption, weight: .semibold))
                        .foregroundColor(Theme.textMuted.opacity(0.6))
                }
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            tick += 1
        }
    }
}

#if os(macOS)
/// mac 权限页顶上的「默认 / 这一层」（atrium P3⑤a §3.5）：健康子页走 route 拿不到页面状态，从这里读
@MainActor
@Observable
final class PermissionMacScope {
    static let shared = PermissionMacScope()
    var floor = false
}
#endif

// MARK: - 权限页

/// 设置 · 权限（plan-权限管理 §3）：AI 能看什么 / AI 能做什么 / 系统权限。
/// 引用层：行与原 tab 读写同一真相源（PermissionCenter），原 tab 的行由 T7 换成同款控件。
/// 一份 body 两端共用（plan-settings-merge 刀 1）：容器走 `SettingsSectionList`，字号走 `settingsMetrics`，
/// 二级页走 `SettingsNavRow`；只剩 iOS 独有的「本地模式」节与系统权限三行是平台例外。
/// atrium P3⑤a：这页是「默认」（没单独设过的人用的）；iOS 单独给某个人改在 TA 的人页，mac 没人页、页顶切「这一层」。
struct PermissionsSettingsTab: View {
    @State private var sysStatus = SystemPermissionStatus()
    @Environment(\.modelContext) private var modelContext
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.settingsMetrics) private var m
    @AppStorage(LocalMode.key) private var localModeEnabled = true
    @State private var secrets: [SecretVault.Entry] = []
    @State private var secretConversationTitles: [String: String] = [:]
    /// mac：别的设置页的档位点进来时直接停在「这一层」（iOS 不用）
    var startsOnFloor = false
    #if os(macOS)
    @State private var macScopeReady = false
    private var macScope: PermissionMacScope { PermissionMacScope.shared }
    #endif

    /// 各行改谁：iOS 永远是默认；mac 跟页顶分段
    private var rowTarget: PermissionTarget {
        #if os(macOS)
        if macScope.floor, let pid = profileManager?.currentProfile.id { return .floor(pid) }
        #endif
        return .defaults
    }

    var body: some View {
        // 搜索锚点：命中某个权限域时滚到那一行
        ScrollViewReader { anchorProxy in
        SettingsSectionList(.list) {
            scopeSection
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
                PermissionDomainRow(domain: .trading, target: rowTarget)
                    .searchAnchor("leaf-perm-trading")
                #endif
                PermissionDomainRow(domain: .memory, twoLevelsOnly: true, target: rowTarget)
                    .searchAnchor("leaf-perm-memory")
                PermissionDomainRow(domain: .images, target: rowTarget)
                    .searchAnchor("leaf-perm-images")
                PermissionDomainRow(domain: .fileLibrary, target: rowTarget)
                    .searchAnchor("leaf-perm-fileLibrary")
                #if PERSONAL_APPS
                #if DEBUG
                PermissionDomainRow(domain: .topicBox, target: rowTarget)
                    .searchAnchor("leaf-perm-topicBox")
                #endif
                #endif
                #if os(macOS)
                PermissionDomainRow(domain: .codingSessions, target: rowTarget)
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
                PermissionDomainRow(domain: .toolsMaster, target: rowTarget)
                    .searchAnchor("leaf-perm-toolsMaster")
                PermissionDomainRow(domain: .webSearch, target: rowTarget)
                    .searchAnchor("leaf-perm-webSearch")
                PermissionDomainRow(domain: .voiceProactive, twoLevelsOnly: true, target: rowTarget)
                    .searchAnchor("leaf-perm-voiceProactive")
                PermissionDomainRow(domain: .pocket, twoLevelsOnly: true, target: rowTarget)   // pocket_cmd 在 WS handler，askOnce 弹卡挂 P2
                    .searchAnchor("leaf-perm-pocket")
                PermissionDomainRow(domain: .calendar, target: rowTarget)
                    .searchAnchor("leaf-perm-calendar")
                PermissionDomainRow(domain: .reminders, target: rowTarget)
                    .searchAnchor("leaf-perm-reminders")
                PermissionDomainRow(domain: .clipboard, target: rowTarget)
                    .searchAnchor("leaf-perm-clipboard")
                PermissionDomainRow(domain: .shell, target: rowTarget)   // 两端都有 run_command（iOS = app 内沙箱）
                    .searchAnchor("leaf-perm-shell")
                PermissionDomainRow(domain: .twitter, target: rowTarget)   // local_twitter：本楼层推特，纯本地
                    .searchAnchor("leaf-perm-twitter")
            } header: {
                Text("AI 能做什么")
            } footer: {
                Text("单个工具的开关在 Prompt → 工具抽屉。")
                    .font(m.caption)
                    .foregroundColor(Theme.textMuted)
            }
            .listRowBackground(Theme.mainBg)

            autonomySection
            SystemPermissionsSection(status: sysStatus)
            secretsSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
        .navigationTitle("权限")
        .settingsAnchorScroll(anchorProxy)
        .task { await sysStatus.refresh() }
        .onAppear {
            reloadSecrets()
            #if os(macOS)
            // 第一次出现定一次（从健康子页退回来不重置）；搜索 / 侧栏进来是默认，别的设置页档位点进来是这一层
            if !macScopeReady {
                macScopeReady = true
                macScope.floor = startsOnFloor
            }
            #endif
        }
        }
    }

    /// 页顶：iOS 一句说明这页是默认；mac「默认 / 这一层」分段（照抽屉页）
    @ViewBuilder private var scopeSection: some View {
        Section {
            #if os(macOS)
            Picker("范围", selection: Binding(get: { macScope.floor }, set: { macScope.floor = $0 })) {
                Text("默认").tag(false)
                Text("这一层 · \(profileManager?.currentProfile.name ?? "")").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(macScope.floor
                 ? "只改这一层：没设的跟着默认走。工具总开关、遥控浏览器、记忆所有人共用，只在默认里改。"
                 : "这里是默认：没单独设过的层都用这一套。单独给某一层改，切到「这一层」。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("这里是默认：没单独设过的人都用这一套。单独给某个人改，去 TA 的人页 › 权限。")
                .font(m.caption)
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
        .listRowBackground(Theme.mainBg)
    }

    /// 自主行为类：二值域。nudge/夜跑/agora 真适配器行；Agent/共读的写路径归设置-Agent（WS 快照守卫在那边），这里状态+跳转。
    @ViewBuilder private var autonomySection: some View {
        Section {
            AutonomyToggleRow(title: "主动找我", caption: "空闲时 Claude Code 会主动发消息",
                              key: "ccNudgeEnabled", defaultValue: false) {
                CCConfigSync.edited("nudgeEnabled")
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
            PermissionDomainRow(domain: .notifications, twoLevelsOnly: true, target: rowTarget)
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
}

/// 权限页「系统权限」节：只读状态 + 前往系统设置。atrium「我 → 系统授权」单独开一页复用它（plan-atrium P2）
private struct SystemPermissionsSection: View {
    let status: SystemPermissionStatus
    @Environment(\.settingsMetrics) private var m

    var body: some View {
        Section {
            SystemPermissionRow(name: "通知", status: status.notifications)
            SystemPermissionRow(name: "麦克风", status: status.microphone)
            SystemPermissionRow(name: "相机", status: status.camera)
            SystemPermissionRow(name: "照片", status: status.photos)
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

/// atrium「我 → 系统授权」：系统给 App 的授权，按人分不了（research-atrium §1.4）
struct SystemAuthorizationPage: View {
    @State private var sysStatus = SystemPermissionStatus()

    var body: some View {
        SettingsSectionList(.list) {
            SystemPermissionsSection(status: sysStatus)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mainBg)
        .navigationTitle("系统授权")
        .task { await sysStatus.refresh() }
    }
}

/// 健康子页：五子域各一行（iOS 二级页；mac 走 `SettingsRoute.healthPermissions` → `MacHealthPermissionPage`）。
/// atrium P3⑤a：「我 › 权限」进来改默认，人页进来改这个人（同一份行，target 不同）
struct HealthPermissionSubpage: View {
    var target: PermissionTarget = .defaults
    @Environment(\.settingsMetrics) private var m

    /// 默认 / 这一层两种说明（iOS 子页、mac 子页共用）
    static func footer(_ target: PermissionTarget) -> String {
        #if os(macOS)
        target == .defaults
            ? "这里是默认：没单独设过的层都用这一档。设置 → 健康 里显示的是当前层生效的值。"
            : "只改这一层：「跟随默认」= 用默认那一档。"
        #else
        target == .defaults
            ? "这里是默认：没单独设过的人都用这一档。设置 → 健康 里显示的是当前这个人生效的值，点进去改的是这个人。"
            : "只改这个人：「跟随默认」= 用「我 › 权限 › 健康」那一档。"
        #endif
    }

    var body: some View {
        List {
            Section {
                PermissionDomainRow(domain: .healthApple, target: target)
                PermissionDomainRow(domain: .healthWeight, target: target)
                PermissionDomainRow(domain: .healthMeds, target: target)
                PermissionDomainRow(domain: .healthCycle, target: target)
                PermissionDomainRow(domain: .healthIntimacy, target: target)
            } footer: {
                Text(Self.footer(target))
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
