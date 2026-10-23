#if (DEBUG || PERF_BENCH) && os(iOS)
import Foundation

/// UI 回归套件（plan-perf-watch §1.2）的统一开关：Debug 与 Release+PERF_BENCH 包里，
/// 启动参数带任一 UI 测试参数时为 true。上架 Release 不编。
enum UITestHooks {
    static let active: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return ["--ui-regression-seed", "--kb-probe-seed", "--sticker-probe-seed", "page2-ui-test"].contains { args.contains($0) }
    }()
}
#endif
