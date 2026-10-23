#if os(macOS)
import AppKit
import Observation
import Sparkle

/// Mac 版自动更新（Sparkle 2，plan: docs/plan-mac-auto-update.md；调研 research-magpie §2.9）。
///
/// - 更新源 / 公钥读 Info.plist 的 `SUFeedURL` / `SUPublicEDKey`（project.yml 的 macOS target `info.properties`）。
///   **现在两项都是占位**：`placeholderMarker` 出现在任一值里、或公钥解不出 32 字节 = 未配置。未配置时**不启动**
///   Sparkle（占位公钥启动会弹「EdDSA key 无效」错误框），菜单「检查更新…」改弹一句友好说明。
///   粟粟跑完 `generate_keys` 把公钥 + 真实 appcast 地址填进 project.yml 即自动生效，代码不用动。
/// - 交互全交给 `SPUStandardUserDriver`：后台下载、进度百分比、「安装并重新启动」、失败原因（magpie 同款体验）。
/// - 启动后延迟 `launchDelay` 再 start，之后按 `SUScheduledCheckInterval`（6 小时）定时查。
/// - Debug 构建：启动不 start，后台定时检查一律拒（delegate `mayPerform`）；只有手点「检查更新…」才查。
///   Debug / Release 同 bundle id 共用一份 UserDefaults，所以不能靠改 `automaticallyChecksForUpdates` 来关。
/// - App 没开 App Sandbox（MemoryPalaceMac.entitlements），不需要 Sparkle 的 XPC 安装器服务。
@MainActor
@Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// 占位标记。project.yml 里 `SUFeedURL` / `SUPublicEDKey` 的占位值都含它；替换成真实值后自然不再命中。
    nonisolated static let placeholderMarker = "REPLACE-ME"
    /// 启动后等多久再开始第一次检查：让首屏、同步、CC 桥先跑起来
    private static let launchDelay: TimeInterval = 8

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    /// 公钥 + 更新源都填了真实值
    let isConfigured: Bool
    /// 未配置时缺了哪几项（给提示文案）
    let missingConfiguration: [String]

    private(set) var canCheckForUpdates = false
    private(set) var isStarted = false
    private(set) var lastCheckDate: Date?

    /// 设置页开关。存储属性（@Observable 能追踪），didSet 回写 Sparkle（它自己存 UserDefaults）
    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard oldValue != automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard oldValue != automaticallyDownloadsUpdates else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    @ObservationIgnored private let delegateProxy = UpdaterDelegateProxy()
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var launchScheduled = false

    private override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        var missing: [String] = []
        if !Self.isValidFeedURL(feed) { missing.append("更新源地址（SUFeedURL）") }
        if !Self.isValidPublicKey(key) { missing.append("签名公钥（SUPublicEDKey）") }
        missingConfiguration = missing
        isConfigured = missing.isEmpty
        // 默认值来自 Info.plist（SUEnableAutomaticChecks / SUAutomaticallyUpdate = YES），这里先占位，init 末尾读真值
        automaticallyChecksForUpdates = true
        automaticallyDownloadsUpdates = true
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: delegateProxy,
                                                  userDriverDelegate: nil)
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            let date = updater.lastUpdateCheckDate
            Task { @MainActor in
                self?.canCheckForUpdates = value
                self?.lastCheckDate = date
            }
        }
    }

    /// app 启动完调一次（MPAppDelegate）。Release 延迟后 start；Debug 不自动 start。
    func startAfterLaunch() {
        guard !launchScheduled, isConfigured, !Self.isDebugBuild else { return }
        launchScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            self?.startIfNeeded()
        }
    }

    /// 菜单「检查更新…」/ 设置页按钮
    func checkForUpdates() {
        guard isConfigured else {
            presentNotConfiguredAlert()
            return
        }
        guard startIfNeeded() else { return }
        controller.checkForUpdates(nil)
    }

    @discardableResult
    private func startIfNeeded() -> Bool {
        if isStarted { return true }
        do {
            try controller.updater.start()
            isStarted = true
            return true
        } catch {
            // 公钥格式对但 Sparkle 仍不认 / 包结构异常：写日志 + 友好提示，不崩
            NSLog("[AppUpdater] Sparkle 启动失败：\(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = "更新组件启动失败：\(error.localizedDescription)\n可以稍后再试，或到发布页手动下载新版。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return false
        }
    }

    private func presentNotConfiguredAlert() {
        let alert = NSAlert()
        alert.messageText = "这个版本还没有开启自动更新"
        alert.informativeText = "缺少：\(missingConfiguration.joined(separator: "、"))。\n"
            + "请到发布页手动下载新版；开发者见 docs/plan-mac-auto-update.md。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 配置校验（nonisolated 纯函数，便于测）

    nonisolated static func isValidFeedURL(_ string: String) -> Bool {
        guard !string.contains(placeholderMarker),
              let url = URL(string: string), url.scheme == "https", url.host?.isEmpty == false else { return false }
        return true
    }

    /// Sparkle EdDSA 公钥 = base64 的 32 字节 ed25519 公钥
    nonisolated static func isValidPublicKey(_ string: String) -> Bool {
        guard !string.contains(placeholderMarker),
              let data = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return data.count == 32
    }
}

/// Sparkle 的 delegate 是非隔离 ObjC 协议，单独放一个小对象，不和 @MainActor 的 AppUpdater 搅在一起
private final class UpdaterDelegateProxy: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
        // 开发版只允许手动检查：定时 / 启动后的后台检查一律拒，免得调试时乱弹
        if updateCheck == .updatesInBackground {
            throw NSError(domain: "MemoryPalace.AppUpdater", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Debug 构建不做后台自动检查"])
        }
        #endif
    }
}
#endif
