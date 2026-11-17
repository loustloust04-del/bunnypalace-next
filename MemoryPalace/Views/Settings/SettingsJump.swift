import SwiftUI

// MARK: - 从设置外面直达设置里的某页 / 某行 / 某张卡（plan-api-draft-and-fix-jump §3.1）

/// 只认枚举 case（`SettingsView.SettingsTab.api`），不写页名字面量——页名改了也不影响跳转
enum SettingsJumpTarget: Equatable {
    /// 模型和API 页（不开编辑页）
    case apiPage
    /// 模型和API 页 + 打开这张卡的编辑页
    case editCredential(String)
    /// 模型和API 页 + 新建卡的编辑页
    case newCredential
    /// 模型和API 页 → 全部模型页（nil = 不筛卡）
    case modelPool(credentialId: String?)
    /// 模型和API 页，滚到预算节
    case budget
    /// Prompt 页，滚到某一行
    case persona(anchor: String)

    var tab: SettingsView.SettingsTab {
        if case .persona = self { return .persona }
        return .api
    }
}

/// 一次性信箱（同 `SettingsSearchRouter` / `workspacePreferences.settingsRequested` 的套路）：
/// 发起方 `request`；ContentView 开设置，SettingsView 切页，目标页取走自己那一段
@MainActor @Observable
final class SettingsJump {
    static let shared = SettingsJump()

    static let budgetAnchor = "leaf-api-budget"
    static let prefillAnchor = "leaf-persona-prefill"
    static let samplingAnchor = "leaf-persona-sampling"
    static let contextDepthAnchor = "leaf-persona-context-depth"

    private(set) var pending: SettingsJumpTarget?
    /// 同一个目标连投两次也要能触发 onChange
    private(set) var serial = 0
    /// 冷启动回到草稿编辑页：一次进程只查一次（换楼层整树重建不再弹）
    @ObservationIgnored var resumeChecked = false
    /// 这次启动带了明确的去处（推送点进来的会话 / 来电）：不自动回草稿编辑页（astra #7）。草稿留着，她自己点进去照样带回
    @ObservationIgnored private(set) var launchHasExternalTarget = false

    func noteExternalNavigation() { launchHasExternalTarget = true }

    private init() {}

    /// `delay`：从 alert / sheet 里发起时等它收起，iOS 同一时刻只能 present 一个
    func request(_ target: SettingsJumpTarget, delay: TimeInterval = 0) {
        guard delay > 0 else {
            pending = target
            serial += 1
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.request(target)
        }
    }

    /// 目标页取走属于自己的那一段；取走即清
    func take(_ accepts: (SettingsJumpTarget) -> Bool) -> SettingsJumpTarget? {
        guard let pending, accepts(pending) else { return nil }
        self.pending = nil
        return pending
    }
}

// MARK: - ContentView 层：收信开设置 + 冷启动回到没存完的 API 卡

struct SettingsJumpHost: ViewModifier {
    let openSettings: () -> Void
    /// 冒烟 / perf / 引导 / 测试宿主这些闸由 ContentView 给
    let resumeAllowed: () -> Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: SettingsJump.shared.serial) { _, _ in
                if SettingsJump.shared.pending != nil { openSettings() }
            }
            .onAppear(perform: resumeDraftIfNeeded)
    }

    /// Q2-A：冷启动有新鲜的卡草稿 → 自动开「设置 → 模型和API → 那张卡」，一次性。
    /// 推送落点在 0.6s 消费：等 0.8s 后再查一遍闸（期间被推送 / 来电认领了就这次不弹，草稿不标「弹过」）
    private func resumeDraftIfNeeded() {
        let jump = SettingsJump.shared
        guard !jump.resumeChecked else { return }
        jump.resumeChecked = true
        guard resumeAllowed(), !jump.launchHasExternalTarget, APIDraftStore.peek() != nil else { return }
        let allowed = resumeAllowed
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard allowed(), !jump.launchHasExternalTarget, jump.pending == nil,
                  let draft = APIDraftStore.takePendingResume() else { return }
            BreadcrumbLog.shared.add("🔑", "冷启动有没存完的 API 卡草稿，回到编辑页")
            jump.request(draft.slot == APIDraft.newSlot ? .newCredential : .editCredential(draft.slot))
        }
    }
}

// MARK: - SettingsView 层：切到目标页

struct SettingsJumpTabConsumer: ViewModifier {
    #if os(iOS)
    @Binding var selectedTab: SettingsView.SettingsTab?
    /// 简洁版的 Prompt 页没有预填 / 采样参数那几行：跳进来这一次走完整页
    @Binding var forceFullPersona: Bool
    #else
    @Binding var selectedTab: SettingsView.SettingsTab
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear { route(delay: 0.45) }   // 设置 sheet 刚弹出：等它站稳再 push
            .onChange(of: SettingsJump.shared.serial) { _, _ in route(delay: 0.05) }
            #if os(iOS)
            .onChange(of: selectedTab) { _, tab in
                if let tab, tab != .persona { forceFullPersona = false }
            }
            #endif
    }

    private func route(delay: TimeInterval) {
        guard let target = SettingsJump.shared.pending else { return }
        let tab = target.tab
        #if os(iOS)
        if case .persona = target { forceFullPersona = true }
        guard selectedTab != tab else { return }   // 页面已经在了：它自己 onChange 取
        SettingsSearchEntry.expandFoldGroup(for: tab)
        let wasDeeper = selectedTab != nil
        if wasDeeper { selectedTab = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasDeeper ? 0.45 : delay)) { selectedTab = tab }
        #else
        selectedTab = tab
        #endif
    }
}

extension View {
    #if os(iOS)
    func settingsJumpTabs(_ selectedTab: Binding<SettingsView.SettingsTab?>, forceFullPersona: Binding<Bool>) -> some View {
        modifier(SettingsJumpTabConsumer(selectedTab: selectedTab, forceFullPersona: forceFullPersona))
    }
    #else
    func settingsJumpTabs(_ selectedTab: Binding<SettingsView.SettingsTab>) -> some View {
        modifier(SettingsJumpTabConsumer(selectedTab: selectedTab))
    }
    #endif

    /// 目标页挂这一条：上树 / 有新信时取走自己那一段
    func settingsJumpTarget(accepts: @escaping (SettingsJumpTarget) -> Bool,
                            perform: @escaping (SettingsJumpTarget) -> Void) -> some View {
        modifier(SettingsJumpPageConsumer(accepts: accepts, perform: perform))
    }
}

private struct SettingsJumpPageConsumer: ViewModifier {
    let accepts: (SettingsJumpTarget) -> Bool
    let perform: (SettingsJumpTarget) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: consume)
            .onChange(of: SettingsJump.shared.serial) { _, _ in consume() }
    }

    private func consume() {
        if let target = SettingsJump.shared.take(accepts) { perform(target) }
    }
}
