import SwiftUI
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// 一轮对话的后台保活（docs/plan-phone-operate.md P1）：她点发送时申请系统的「持续处理任务」，
/// 这一轮说完就交还。开着时，回复写到一半切去别的 App，花园不会被立刻挂起。默认关。
/// 实测依据：research-phone-operate §9（😷 上后台带网络跑满 15 分钟；不申请则进后台当秒停）。
enum TurnKeepAlivePreference {
    static let key = "turnKeepAlive.enabled"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// 系统交过来的那个任务（测试里换假的）
protocol TurnKeepAliveTask: AnyObject {
    func update(subtitle: String, tick: Int)
    func finish(success: Bool)
}

/// 向系统申请 / 撤回（测试里换假的）
protocol TurnKeepAliveSystem: AnyObject {
    /// 系统规定只能在前台、响应人的操作时申请
    var isForeground: Bool { get }
    func submit() throws
    func cancelPending()
}

/// 只管状态：没申请 → 申请了系统还没给 → 系统给了正在保活。不碰系统接口，两端都能测。
@MainActor
final class TurnKeepAliveCore {
    enum State: Equatable { case idle, requested, running }

    private(set) var state: State = .idle
    private(set) var ticks = 0
    private let system: TurnKeepAliveSystem
    private let isEnabled: () -> Bool
    private var task: TurnKeepAliveTask?
    private var onExpire: (() -> Void)?

    init(system: TurnKeepAliveSystem, isEnabled: @escaping () -> Bool) {
        self.system = system
        self.isEnabled = isEnabled
    }

    /// 一轮开始：开关开着且在前台才申请；申请不到就当没这回事，对话照常
    func turnBegan(onExpire: @escaping () -> Void) {
        guard state == .idle, isEnabled(), system.isForeground else { return }
        do {
            try system.submit()
            state = .requested
            self.onExpire = onExpire
        } catch {
            state = .idle
        }
    }

    /// 一轮结束（说完 / 出错 / 她按了停）
    func turnEnded() {
        switch state {
        case .idle: return
        case .requested: system.cancelPending()
        case .running: task?.finish(success: true)
        }
        reset()
    }

    /// 系统把任务交过来了。这一轮要是已经结束，直接还回去
    func systemStarted(_ task: TurnKeepAliveTask) {
        guard state == .requested else {
            task.finish(success: true)
            return
        }
        self.task = task
        state = .running
        tick()
    }

    /// 每秒一次：告诉系统这一轮还活着（系统在资源紧张时优先收回进度不动的任务）
    func tick() {
        guard state == .running else { return }
        ticks += 1
        task?.update(subtitle: "已经 \(ticks) 秒", tick: ticks)
    }

    /// 系统收回了，或者她在系统的进度界面上点了取消：这一轮跟着停
    func systemExpired() {
        guard state == .running else { return }
        task?.finish(success: false)
        let expire = onExpire
        reset()
        expire?()
    }

    private func reset() {
        task = nil
        onExpire = nil
        ticks = 0
        state = .idle
    }
}

#if os(iOS)
/// 接系统的那一层：`BGContinuedProcessingTask`。标识要和 MemoryPalaceIOS-Info.plist 里登记的一致。
@MainActor
final class TurnKeepAlive: TurnKeepAliveSystem {
    static let shared = TurnKeepAlive()

    private static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".turn"
    private lazy var core = TurnKeepAliveCore(system: self, isEnabled: { TurnKeepAlivePreference.enabled })
    private var timer: Timer?

    /// App 启动时调一次（系统要求启动完成前登记好）
    nonisolated static func registerLaunchHandler() {
        let id = (Bundle.main.bundleIdentifier ?? "") + ".turn"
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                TurnKeepAlive.shared.started(task)
            }
        }
    }

    func turnChanged(inFlight: Bool, onExpire: @escaping () -> Void) {
        if inFlight {
            core.turnBegan(onExpire: onExpire)
        } else {
            core.turnEnded()
            stopTimer()
        }
    }

    private func started(_ task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = Int64(Handle.totalUnits)
        task.expirationHandler = {
            MainActor.assumeIsolated {
                TurnKeepAlive.shared.core.systemExpired()
                TurnKeepAlive.shared.stopTimer()
            }
        }
        core.systemStarted(Handle(task))
        guard core.state == .running else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { TurnKeepAlive.shared.core.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: TurnKeepAliveSystem

    var isForeground: Bool { UIApplication.shared.applicationState == .active }

    func submit() throws {
        let request = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier, title: "记忆花园在回你", subtitle: "刚开始")
        try BGTaskScheduler.shared.submit(request)
    }

    func cancelPending() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    private final class Handle: TurnKeepAliveTask {
        /// 一轮没有真实的总量；进度条按秒往上走、永远到不了头，只当「还活着」的信号
        static let totalUnits = 3600
        private let task: BGContinuedProcessingTask
        init(_ task: BGContinuedProcessingTask) { self.task = task }

        func update(subtitle: String, tick: Int) {
            task.progress.completedUnitCount = Int64(min(Self.totalUnits - 1, tick))
            task.updateTitle(task.title, subtitle: subtitle)
        }

        func finish(success: Bool) {
            task.setTaskCompleted(success: success)
        }
    }
}

/// 设置行（设置 › API › 回复方式）
struct TurnKeepAliveRow: View {
    let titleFont: Font
    let captionFont: Font
    @AppStorage(TurnKeepAlivePreference.key) private var enabled = false

    var body: some View {
        Toggle(isOn: $enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("后台保活")
                    .font(titleFont)
                    .foregroundColor(Theme.textPrimary)
                Text("回复写到一半切去别的 App，花园继续在后台把这一轮写完。系统会显示一个进度条，在上面点取消就停。把花园从多任务里划掉，这一轮直接没了。")
                    .font(captionFont)
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
